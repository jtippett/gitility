defmodule Gitility.ODB.RangeBackend.LocalDirectory do
  @moduledoc """
  Reference range backend for an atomically published local directory.

  A store contains immutable `packs/pack-<checksum>.pack` and `.idx` files
  plus `manifest.json`. The manifest is replaced atomically only after all
  content-addressed artifacts are present. `read_ranges/2` uses positional
  reads and never shares or advances a mutable file offset.

  `publish/2` copies existing pack/index pairs from a bare or normal local
  repository. If the repository contains only loose objects, it invokes the
  configured Git executable's `pack-objects` plumbing against a temporary
  staging directory without modifying the source repository.

      :ok =
        Gitility.ODB.RangeBackend.LocalDirectory.publish(
          "/srv/git/project.git",
          "/srv/gitility/project-packs"
        )

      {:ok, supervisor} =
        Gitility.ODB.PackFetch.start_link(
          backend: {Gitility.ODB.RangeBackend.LocalDirectory,
                    "/srv/gitility/project-packs"},
          into: {:dir, "/var/cache/gitility/project"}
        )
  """

  @behaviour Gitility.ODB.RangeBackend

  alias Gitility.{ByteRange, PackDescriptor, PackManifest}

  @impl true
  def init(dir) when is_binary(dir) do
    dir = Path.expand(dir)

    if File.dir?(dir) do
      case read_manifest(dir) do
        {:ok, _manifest} -> {:ok, dir}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_a_directory}
    end
  end

  def init(_dir), do: {:error, :invalid_directory}

  @impl true
  def manifest(dir), do: read_manifest(dir)

  @impl true
  def read_ranges(ranges, dir) when is_list(ranges) do
    Enum.reduce_while(ranges, {:ok, %{}}, fn
      %ByteRange{} = range, {:ok, replies} ->
        case read_range(dir, range) do
          {:ok, bytes} -> {:cont, {:ok, Map.put(replies, range, bytes)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _range, _acc ->
        {:halt, {:error, :invalid_range}}
    end)
  end

  @doc """
  Publishes the pack inventory of a local repository into `destination`.

  Pack and index files are written through same-directory temporary files;
  `manifest.json` is the final atomic rename. The optional `:git_executable` application
  environment setting (`Application.put_env(:gitility, :git_executable, …)`)
  selects the Git executable used only when loose objects need packing.
  """
  @spec publish(Path.t(), Path.t()) :: :ok | {:error, term()}
  def publish(repository, destination)
      when is_binary(repository) and is_binary(destination) do
    repository = Path.expand(repository)
    destination = Path.expand(destination)
    pack_destination = Path.join(destination, "packs")
    staging = Path.join(destination, ".publish-#{System.unique_integer([:positive, :monotonic])}")

    # `staging` must be bound outside the try so `after` can always clean it
    # up (a `rescue` on the def head cannot see body variables).
    try do
      with :ok <- File.mkdir_p(pack_destination),
           :ok <- File.mkdir_p(staging),
           {:ok, source_pairs} <- source_pairs(repository, staging),
           {:ok, descriptors, hash} <- publish_pairs(source_pairs, pack_destination),
           :ok <- publish_manifest(destination, descriptors, hash) do
        :ok
      else
        {:error, reason} = error ->
          if is_exception(reason), do: {:error, Exception.message(reason)}, else: error
      end
    rescue
      exception -> {:error, Exception.message(exception)}
    after
      File.rm_rf(staging)
    end
  end

  def publish(_repository, _destination), do: {:error, :invalid_directory}

  defp source_pairs(repository, staging) do
    with {:ok, objects} <- objects_directory(repository) do
      pack_dir = Path.join(objects, "pack")

      pairs =
        pack_dir
        |> Path.join("pack-*.pack")
        |> Path.wildcard()
        |> Enum.sort()
        |> Enum.map(&{&1, Path.rootname(&1) <> ".idx"})
        |> Enum.filter(fn {_pack, index} -> File.regular?(index) end)

      if pairs == [], do: pack_loose_repository(repository, objects, staging), else: {:ok, pairs}
    end
  end

  defp pack_loose_repository(repository, objects, staging) do
    git = Application.get_env(:gitility, :git_executable, "git")

    # git pack-objects builds its temp file under the repository's objects
    # directory and rename(2)s it to the requested prefix. If `staging` (which
    # lives under the DESTINATION) is on another filesystem that rename fails
    # with EXDEV ("Invalid cross-device link" — the sprite's /tmp is tmpfs;
    # macOS never showed it). So git writes beside its own objects dir, on
    # its own filesystem, and our atomic_copy (File.cp — cross-device safe)
    # carries the result to the destination. The git-side staging dir is
    # removed as soon as the pairs are copied into `staging`.
    git_staging =
      Path.join(objects, ".gitility-publish-#{System.unique_integer([:positive, :monotonic])}")

    prefix = Path.join(git_staging, "pack")

    git_args =
      if File.dir?(Path.join(repository, ".git")) do
        ["-C", repository, "pack-objects", "--all", prefix]
      else
        ["--git-dir", repository, "pack-objects", "--all", prefix]
      end

    # `git pack-objects` reads an object list from stdin until EOF even with
    # `--all`. An Erlang port never closes the child's stdin, so a plain
    # System.cmd hangs forever (the first M2e BEAM run sat 10+ minutes in
    # setup_all). Redirecting stdin from /dev/null through the shell delivers
    # the EOF; `exec` keeps git as the process the port owns.
    shell_command =
      Enum.map_join(["exec", git | git_args], " ", &shell_escape/1) <> " < /dev/null"

    result =
      with :ok <- File.mkdir_p(git_staging),
           {_output, 0} <- System.cmd("/bin/sh", ["-c", shell_command], stderr_to_stdout: true) do
        git_staging
        |> Path.join("pack-*.pack")
        |> Path.wildcard()
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, fn pack, {:ok, acc} ->
          index = Path.rootname(pack) <> ".idx"
          staged_pack = Path.join(staging, Path.basename(pack))
          staged_index = Path.join(staging, Path.basename(index))

          with :ok <- File.cp(pack, staged_pack),
               :ok <- File.cp(index, staged_index) do
            {:cont, {:ok, [{staged_pack, staged_index} | acc]}}
          else
            {:error, reason} -> {:halt, {:error, {:stage_copy_failed, reason}}}
          end
        end)
        |> case do
          {:ok, []} -> {:error, :repository_has_no_objects}
          {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
          error -> error
        end
      end

    File.rm_rf(git_staging)

    case result do
      {:ok, pairs} ->
        {:ok, pairs}

      {:error, _reason} = error ->
        error

      {output, status} when is_binary(output) and is_integer(status) ->
        {:error, {:git_pack_objects_failed, status, String.slice(output, 0, 512)}}
    end
  end

  defp publish_pairs(pairs, destination) do
    Enum.reduce_while(pairs, {:ok, [], nil}, fn {pack, index}, {:ok, descriptors, hash} ->
      with {:ok, id, pair_hash} <- pack_identity(pack),
           :ok <- compatible_hash(hash, pair_hash),
           {:ok, pack_size} <- file_size(pack),
           {:ok, index_size} <- file_size(index),
           pack_name = "pack-#{id}.pack",
           index_name = "pack-#{id}.idx",
           :ok <- atomic_copy(pack, Path.join(destination, pack_name)),
           :ok <- atomic_copy(index, Path.join(destination, index_name)) do
        descriptor = %PackDescriptor{
          id: id,
          pack_key: "packs/#{pack_name}",
          index_key: "packs/#{index_name}",
          pack_size: pack_size,
          index_size: index_size
        }

        {:cont, {:ok, [descriptor | descriptors], hash || pair_hash}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, descriptors, hash} -> {:ok, Enum.reverse(descriptors), hash}
      error -> error
    end
  end

  defp publish_manifest(destination, descriptors, hash) do
    manifest = %{
      "version" => 1,
      "generation" => generation(),
      "hash" => Atom.to_string(hash),
      "packs" =>
        Enum.map(descriptors, fn descriptor ->
          descriptor
          |> Map.from_struct()
          |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
        end),
      "loose" => []
    }

    bytes = Jason.encode_to_iodata!(manifest)
    atomic_write(Path.join(destination, "manifest.json"), bytes)
  end

  defp read_manifest(dir) do
    with {:ok, bytes} <- File.read(Path.join(dir, "manifest.json")),
         {:ok, json} <- Jason.decode(bytes),
         {:ok, hash} <- decode_hash(json["hash"]),
         {:ok, packs} <- decode_descriptors(json["packs"]) do
      {:ok,
       %PackManifest{
         version: json["version"],
         generation: json["generation"],
         hash: hash,
         packs: packs,
         loose: json["loose"] || []
       }}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:invalid_manifest_json, Exception.message(error)}}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :invalid_manifest}
    end
  end

  defp decode_descriptors(packs) when is_list(packs) do
    try do
      {:ok,
       Enum.map(packs, fn pack ->
         %PackDescriptor{
           id: Map.fetch!(pack, "id"),
           pack_key: Map.fetch!(pack, "pack_key"),
           index_key: Map.fetch!(pack, "index_key"),
           pack_size: Map.fetch!(pack, "pack_size"),
           index_size: Map.fetch!(pack, "index_size"),
           etag: Map.get(pack, "etag")
         }
       end)}
    rescue
      KeyError -> {:error, :invalid_manifest}
    end
  end

  defp decode_descriptors(_packs), do: {:error, :invalid_manifest}
  defp decode_hash("sha1"), do: {:ok, :sha1}
  defp decode_hash("sha256"), do: {:ok, :sha256}
  defp decode_hash(_hash), do: {:error, :invalid_hash}

  defp read_range(dir, %ByteRange{key: key, offset: offset, length: length})
       when is_binary(key) and is_integer(offset) and offset >= 0 and is_integer(length) and
              length >= 0 do
    with {:ok, path} <- artifact_path(dir, key),
         {:ok, file} <- :file.open(String.to_charlist(path), [:raw, :binary, :read]) do
      result =
        case :file.pread(file, offset, length) do
          {:ok, bytes} when byte_size(bytes) == length -> {:ok, bytes}
          {:ok, _bytes} -> {:error, :short_read}
          :eof when length == 0 -> {:ok, <<>>}
          :eof -> {:error, :short_read}
          {:error, reason} -> {:error, reason}
        end

      :ok = :file.close(file)
      result
    end
  end

  defp read_range(_dir, _range), do: {:error, :invalid_range}

  defp artifact_path(dir, key) do
    root = Path.expand(dir)
    path = Path.expand(key, root)

    if String.starts_with?(path, root <> "/") and File.regular?(path) do
      {:ok, path}
    else
      {:error, :invalid_key}
    end
  end

  defp objects_directory(repository) do
    candidates = [Path.join(repository, "objects"), Path.join([repository, ".git", "objects"])]

    case Enum.find(candidates, &File.dir?/1) do
      nil -> {:error, :repository_has_no_objects_directory}
      path -> {:ok, path}
    end
  end

  defp pack_identity(path) do
    case Regex.run(~r/^pack-([0-9a-fA-F]{40}|[0-9a-fA-F]{64})\.pack$/, Path.basename(path)) do
      [_, id] when byte_size(id) == 40 -> {:ok, String.downcase(id), :sha1}
      [_, id] when byte_size(id) == 64 -> {:ok, String.downcase(id), :sha256}
      _other -> {:error, :invalid_pack_name}
    end
  end

  defp compatible_hash(nil, _hash), do: :ok
  defp compatible_hash(hash, hash), do: :ok
  defp compatible_hash(_left, _right), do: {:error, :mixed_hash_algorithms}

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 -> {:ok, size}
      {:ok, _stat} -> {:error, :empty_pack_artifact}
      {:error, reason} -> {:error, reason}
    end
  end

  defp atomic_copy(source, destination) do
    temp = destination <> ".tmp-#{System.unique_integer([:positive, :monotonic])}"

    # `git pack-objects` writes its output read-only (0444) and File.cp keeps
    # that mode, so opening the copy for write fails with :eacces. Give the
    # published copy owner-writable permissions, then fsync through a read
    # handle (sync needs no write access).
    with :ok <- File.cp(source, temp),
         :ok <- File.chmod(temp, 0o644),
         {:ok, io} <- File.open(temp, [:read, :binary]),
         :ok <- :file.sync(io),
         :ok <- File.close(io),
         :ok <- File.rename(temp, destination) do
      :ok
    else
      {:error, reason} = error ->
        File.rm(temp)
        if is_exception(reason), do: {:error, Exception.message(reason)}, else: error
    end
  end

  defp atomic_write(destination, iodata) do
    temp = destination <> ".tmp-#{System.unique_integer([:positive, :monotonic])}"

    with {:ok, io} <- File.open(temp, [:write, :binary, :exclusive]),
         :ok <- IO.binwrite(io, iodata),
         :ok <- :file.sync(io),
         :ok <- File.close(io),
         :ok <- File.rename(temp, destination) do
      :ok
    else
      {:error, reason} = error ->
        File.rm(temp)
        if is_exception(reason), do: {:error, Exception.message(reason)}, else: error
    end
  end

  defp generation do
    "#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp shell_escape(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end
end
