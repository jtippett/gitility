defmodule Gitility.ODB.RangeBackend.LocalDirectory do
  @moduledoc """
  Reference range backend for an atomically published local directory.

  A store contains immutable `packs/pack-<checksum>.pack` and `.idx` files
  plus `manifest.json`. The manifest is replaced atomically only after all
  content-addressed artifacts are present. `read_ranges/2` uses positional
  reads and never shares or advances a mutable file offset.

  `publish/2` captures every object the repository stores — packed and
  loose, reachable or not; it never garbage-collects. Existing packs are
  copied as-is. When loose objects exist, it feeds their complete object-ID
  list to the configured Git executable's `pack-objects` plumbing, adding
  that new pack beside the existing packs in the published manifest.

  Packing loose objects briefly stages a temporary directory below the
  source repository's `objects/` directory so Git can rename its output on
  the same filesystem; the directory is always removed afterward. A source
  that cannot create this staging directory returns
  `{:error, :source_repository_read_only}`.

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
  alias Gitility.ODB.PackInventory

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
  `manifest.json` is the final atomic rename. Existing source packs are never
  repacked. The optional `:git_executable` application environment setting
  (`Application.put_env(:gitility, :git_executable, …)`) selects the Git
  executable used only when loose objects need packing.
  """
  @spec publish(Path.t(), Path.t()) :: :ok | {:error, term()}
  @spec publish(Path.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def publish(repository, destination, opts \\ [])

  def publish(repository, destination, opts)
      when is_binary(repository) and is_binary(destination) and is_list(opts) do
    opts = Keyword.validate!(opts, git_executable: nil)
    repository = Path.expand(repository)
    destination = Path.expand(destination)
    pack_destination = Path.join(destination, "packs")
    staging = Path.join(destination, ".publish-#{System.unique_integer([:positive, :monotonic])}")

    # `staging` must be bound outside the try so `after` can always clean it
    # up (a `rescue` on the def head cannot see body variables).
    try do
      with :ok <- File.mkdir_p(pack_destination),
           :ok <- File.mkdir_p(staging),
           {:ok, source_pairs} <-
             PackInventory.collect(repository, staging, git_executable: opts[:git_executable]),
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

  def publish(_repository, _destination, _opts), do: {:error, :invalid_directory}

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
end
