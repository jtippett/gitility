defmodule Gitility.ODB.PackInventory do
  @moduledoc false

  @type pair :: {Path.t(), Path.t()}

  @spec collect(Path.t(), Path.t(), keyword()) :: {:ok, [pair()]} | {:error, term()}
  def collect(repository, staging, opts \\ [])
      when is_binary(repository) and is_binary(staging) do
    opts = Keyword.validate!(opts, allow_empty: false, git_executable: nil)
    repository = Path.expand(repository)

    with {:ok, object_directories} <- object_directories(repository),
         pairs <- packed_pairs(object_directories),
         loose_ids <- loose_object_ids(object_directories),
         {:ok, loose_pairs} <-
           maybe_pack_loose(
             repository,
             hd(object_directories),
             staging,
             loose_ids,
             opts[:git_executable]
           ) do
      pairs =
        (pairs ++ loose_pairs)
        |> Enum.uniq_by(fn {pack, _index} -> Path.basename(pack) end)
        |> Enum.sort_by(fn {pack, _index} -> Path.basename(pack) end)

      if pairs == [] and not opts[:allow_empty] do
        {:error, :repository_has_no_objects}
      else
        {:ok, pairs}
      end
    end
  end

  def collect(_repository, _staging, _opts), do: {:error, :invalid_directory}

  @spec git_directory(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def git_directory(repository) when is_binary(repository) do
    repository = Path.expand(repository)

    cond do
      File.dir?(Path.join(repository, "objects")) ->
        {:ok, repository}

      File.dir?(Path.join(repository, ".git")) ->
        {:ok, Path.join(repository, ".git")}

      File.regular?(Path.join(repository, ".git")) ->
        parse_git_file(repository, Path.join(repository, ".git"))

      true ->
        {:error, :repository_has_no_objects_directory}
    end
  end

  def git_directory(_repository), do: {:error, :invalid_directory}

  defp object_directories(repository) do
    with {:ok, git_directory} <- git_directory(repository) do
      collect_object_directories([Path.join(git_directory, "objects")], MapSet.new(), [])
    end
  end

  defp collect_object_directories([], _seen, directories),
    do: {:ok, Enum.reverse(directories)}

  defp collect_object_directories([directory | rest], seen, directories) do
    directory = Path.expand(directory)

    cond do
      MapSet.member?(seen, directory) ->
        collect_object_directories(rest, seen, directories)

      not File.dir?(directory) ->
        {:error, {:alternate_objects_directory_missing, directory}}

      true ->
        alternates = read_alternates(directory)

        case alternates do
          {:ok, alternate_directories} ->
            collect_object_directories(
              rest ++ alternate_directories,
              MapSet.put(seen, directory),
              [directory | directories]
            )

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp read_alternates(objects) do
    path = Path.join([objects, "info", "alternates"])

    case File.read(path) do
      {:ok, bytes} ->
        directories =
          bytes
          |> :binary.split("\n", [:global])
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == <<>>))
          |> Enum.map(fn path -> Path.expand(path, objects) end)

        {:ok, directories}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:alternates_read_failed, reason}}
    end
  end

  defp packed_pairs(object_directories) do
    object_directories
    |> Enum.flat_map(fn objects ->
      objects
      |> Path.join("pack/pack-*.pack")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(&{&1, Path.rootname(&1) <> ".idx"})
      |> Enum.filter(fn {_pack, index} -> File.regular?(index) end)
    end)
  end

  defp loose_object_ids(object_directories) do
    object_directories
    |> Enum.flat_map(fn objects ->
      objects
      |> Path.join("??/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(fn path -> Path.basename(Path.dirname(path)) <> Path.basename(path) end)
    end)
    |> Enum.filter(&String.match?(&1, ~r/\A(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\z/))
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp maybe_pack_loose(_repository, _objects, _staging, [], _git), do: {:ok, []}

  defp maybe_pack_loose(repository, objects, staging, loose_ids, git) do
    pack_loose_objects(repository, objects, staging, loose_ids, git)
  end

  defp pack_loose_objects(repository, objects, staging, loose_ids, configured_git) do
    git = configured_git || Application.get_env(:gitility, :git_executable, "git")

    git_staging =
      Path.join(objects, ".gitility-publish-#{System.unique_integer([:positive, :monotonic])}")

    prefix = Path.join(git_staging, "pack")
    object_list = Path.join(git_staging, "loose-object-ids")

    git_args =
      if File.dir?(Path.join(repository, ".git")) or
           File.regular?(Path.join(repository, ".git")) do
        ["-C", repository, "pack-objects", prefix]
      else
        ["--git-dir", repository, "pack-objects", prefix]
      end

    shell_command =
      Enum.map_join(["exec", git | git_args], " ", &shell_escape/1) <>
        " < " <> shell_escape(object_list)

    result =
      try do
        with :ok <- ensure_source_writable(objects),
             :ok <- create_source_staging(git_staging),
             :ok <- write_loose_object_list(object_list, loose_ids),
             {_output, 0} <-
               System.cmd("/bin/sh", ["-c", shell_command], stderr_to_stdout: true) do
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
      after
        File.rm_rf(git_staging)
      end

    case result do
      {:ok, pairs} ->
        {:ok, pairs}

      {:error, _reason} = error ->
        error

      {output, status} when is_binary(output) and is_integer(status) ->
        {:error, {:git_pack_objects_failed, status, String.slice(output, 0, 512)}}
    end
  end

  defp ensure_source_writable(objects) do
    case File.stat(objects) do
      {:ok, %{mode: mode}} ->
        if Bitwise.band(mode, 0o222) == 0,
          do: {:error, :source_repository_read_only},
          else: :ok

      {:error, reason} ->
        {:error, {:source_staging_failed, reason}}
    end
  end

  defp create_source_staging(path) do
    case File.mkdir(path) do
      :ok ->
        :ok

      {:error, reason} when reason in [:eacces, :erofs] ->
        {:error, :source_repository_read_only}

      {:error, reason} ->
        {:error, {:source_staging_failed, reason}}
    end
  end

  defp write_loose_object_list(path, loose_ids) do
    case File.write(path, Enum.join(loose_ids, "\n") <> "\n") do
      :ok ->
        :ok

      {:error, reason} when reason in [:eacces, :erofs] ->
        {:error, :source_repository_read_only}

      {:error, reason} ->
        {:error, {:source_staging_failed, reason}}
    end
  end

  defp parse_git_file(repository, path) do
    with {:ok, bytes} <- File.read(path),
         <<"gitdir: ", value::binary>> <- String.trim(bytes),
         git_directory <- Path.expand(value, repository),
         true <- File.dir?(Path.join(git_directory, "objects")) do
      {:ok, git_directory}
    else
      _other -> {:error, :repository_has_no_objects_directory}
    end
  end

  defp shell_escape(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end
end
