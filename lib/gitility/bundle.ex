defmodule Gitility.Bundle do
  @moduledoc """
  Deterministic single-file, read-only Git repositories.

  A bundle contains raw pack/index pairs plus a direct reference snapshot.
  Publishing writes a complete same-directory temporary file, syncs it, and
  atomically renames it over the destination. Erlang exposes no portable
  directory-fsync operation, so the artifact is always complete-or-absent but
  rename durability across sudden power loss remains platform-dependent.

  Opening starts one supervision tree containing an eager PackFetch object
  store and a pinned reference provider. Every open is pinned to one bundle
  generation for its lifetime: refresh is a no-op, and moving to a replacement
  generation requires opening the path again. The bundle itself is only ever
  opened read-only and no sidecar is created beside it.
  """

  alias Gitility.{Bundle.Format, Bundle.Receipt, Error, ODB, OID, RefDB, Repository}
  alias Gitility.ODB.PackInventory

  @copy_chunk_bytes 8 * 1024 * 1024
  @default_hydration_bytes 4 * 1024 * 1024 * 1024
  @default_memory_bytes 256 * 1024 * 1024

  @doc """
  Publishes a complete local repository as one deterministic bundle file.

  `:source` must be `{:repository, directory}`. Optional metadata is supplied
  with `:source_identity`, `:publisher`, and `:created_at`; timestamps are
  never synthesized. `:git_executable` selects the executable used to pack
  loose objects and to peel SHA-256 tags while the engine cannot do so.
  """
  @spec write(Path.t(), keyword()) :: {:ok, Receipt.t()} | {:error, Error.t()}
  def write(path, opts) when is_binary(path) and is_list(opts) do
    opts =
      Keyword.validate!(opts,
        source: nil,
        source_identity: nil,
        publisher: nil,
        created_at: nil,
        git_executable: nil
      )

    write_validated(path, opts)
  end

  def write(_path, _opts),
    do:
      {:error,
       Error.new(:invalid_argument, "bundle path and options are invalid",
         operation: :bundle_write
       )}

  defp write_validated(path, opts) do
    path = Path.expand(path)

    with {:ok, source} <- source_path(opts[:source]),
         :ok <- refuse_shallow_source(source),
         {:ok, generation} <- next_generation(path),
         {:ok, metadata} <- metadata(source, opts),
         {:ok, repository} <- Repository.open(source) do
      publish(path, source, repository, generation, metadata, opts)
    end
  rescue
    exception ->
      {:error,
       Error.new(:backend_error, "bundle publication failed",
         operation: :bundle_write,
         cause: Exception.message(exception)
       )}
  end

  @doc "Streams every contained section and verifies its recorded sha256."
  @spec verify(Path.t()) :: :ok | {:error, Error.t()}
  def verify(path) do
    with {:ok, toc} <- Format.parse(path),
         {:ok, file} <- open_read(path) do
      try do
        with {:ok, identity} <- Format.read_trailer_identity(file),
             true <-
               identity.toc_sha256 == toc.toc_sha256 ||
                 malformed_verify("bundle generation moved during verification"),
             :ok <- verify_sections(file, toc.sections) do
          :ok
        else
          {:error, %Error{} = error} -> {:error, error}
        end
      after
        :file.close(file)
      end
    end
  end

  @doc "Returns format, generation, metadata, counts, and size without hydrating objects."
  @spec info(Path.t()) :: {:ok, map()} | {:error, Error.t()}
  def info(path) do
    with {:ok, toc} <- Format.parse(path) do
      file_count = length(toc.files)
      ref_count = length(toc.refs)

      {:ok,
       %{
         format_version: "#{toc.format_major}.#{toc.format_minor}",
         hash_algorithm: toc.hash_algorithm,
         generation: toc.generation,
         source_identity: Map.fetch!(toc.metadata, "source_identity"),
         metadata: toc.metadata,
         file_count: file_count,
         ref_count: ref_count,
         bytes: toc.file_size
       }}
    end
  end

  @doc """
  Starts the bundle's PackFetch and RefDB under one supervisor.

  `:path` is required. PackFetch destination, runtime, limits, concurrency,
  request timeout, hydration ceiling, and memory ceiling options are passed
  through with their normal defaults.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) when is_list(opts) do
    opts =
      Keyword.validate!(opts,
        path: nil,
        into: :memory,
        name: nil,
        runtime: :default,
        limits: nil,
        concurrency: 8,
        request_timeout: 15_000,
        chunk_bytes: @copy_chunk_bytes,
        verify: :always,
        max_hydration_bytes: @default_hydration_bytes,
        max_bytes: @default_memory_bytes
      )

    with {:ok, path} <- required_path(opts[:path]),
         {:ok, toc} <- Format.parse(path) do
      configured =
        opts
        |> Keyword.put(:path, path)
        |> Keyword.put(:toc, toc)

      Gitility.Bundle.Supervisor.start_link(configured)
    end
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name) || {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc "Returns the repository handle owned by a running bundle supervisor."
  @spec repository(pid() | GenServer.name()) :: {:ok, Repository.t()} | {:error, Error.t()}
  def repository(supervisor) do
    {odb_id, refs_id} = Gitility.Bundle.Supervisor.child_ids()

    with {:ok, children} <- bundle_children(supervisor),
         {:ok, odb_supervisor} <- child_pid(children, odb_id),
         {:ok, refs_supervisor} <- child_pid(children, refs_id),
         {:ok, odb} <- ODB.handle(odb_supervisor),
         {:ok, refs} <- RefDB.handle(refs_supervisor),
         {:ok, repository} <- Repository.from_stores(odb: odb, refs: refs) do
      {:ok, repository}
    end
  end

  @doc "Starts a linked bundle supervisor and returns its repository handle."
  @spec open(Path.t(), keyword()) :: {:ok, Repository.t()} | {:error, Error.t()}
  def open(path, opts \\ []) do
    with {:ok, supervisor} <- start_link(Keyword.put(opts, :path, path)) do
      case repository(supervisor) do
        {:ok, repository} ->
          {:ok, repository}

        {:error, %Error{} = error} ->
          Process.unlink(supervisor)
          Supervisor.stop(supervisor)
          {:error, error}
      end
    end
  end

  defp publish(path, source, repository, generation, metadata, opts) do
    directory = Path.dirname(path)
    suffix = System.unique_integer([:positive, :monotonic])
    staging = Path.join(directory, ".#{Path.basename(path)}.staging-#{suffix}")
    temp = Path.join(directory, ".#{Path.basename(path)}.tmp-#{suffix}")

    try do
      with :ok <- mkdir_destination(directory),
           :ok <- mkdir_staging(staging),
           {:ok, pairs} <-
             PackInventory.collect(source, staging,
               allow_empty: true,
               git_executable: opts[:git_executable]
             ),
           :ok <- validate_inventory(pairs, repository.odb.hash),
           {:ok, refs, ref_metadata, warnings} <- snapshot_refs(repository, source, opts),
           {:ok, receipt} <-
             write_file(
               temp,
               path,
               pairs,
               repository.odb.hash,
               generation,
               Map.merge(metadata, ref_metadata),
               refs,
               warnings
             ) do
        {:ok, receipt}
      else
        {:error, %Error{} = error} -> {:error, error}
        {:error, reason} -> write_error(reason)
      end
    after
      File.rm_rf(staging)
      File.rm(temp)
    end
  end

  defp write_file(temp, path, pairs, hash, generation, metadata, refs, warnings) do
    case File.open(temp, [:write, :binary, :exclusive]) do
      {:ok, output} ->
        result =
          try do
            with :ok <- IO.binwrite(output, Format.encode_header()),
                 {:ok, files, toc_offset} <- stream_pairs(pairs, output, 16, []),
                 toc <-
                   Format.encode_toc(%{
                     hash_algorithm: hash,
                     generation: generation,
                     metadata: metadata,
                     files: files,
                     refs: refs
                   }),
                 toc_sha256 <-
                   :sha256
                   |> :crypto.hash_init()
                   |> :crypto.hash_update(toc)
                   |> :crypto.hash_final(),
                 :ok <- IO.binwrite(output, toc),
                 :ok <-
                   IO.binwrite(
                     output,
                     Format.encode_trailer(toc_offset, byte_size(toc), toc_sha256)
                   ),
                 :ok <- :file.sync(output) do
              bytes = toc_offset + byte_size(toc) + 64
              {:ok, files, bytes}
            end
          after
            File.close(output)
          end

        with {:ok, files, bytes} <- result,
             :ok <- File.rename(temp, path) do
          {:ok,
           %Receipt{
             path: path,
             generation: generation,
             bytes: bytes,
             files: length(files),
             refs: length(refs),
             warnings: warnings
           }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stream_pairs([], _output, offset, files), do: {:ok, Enum.reverse(files), offset}

  defp stream_pairs([{pack, index} | rest], output, offset, files) do
    with {:ok, pack_entry, offset} <- stream_section(pack, :pack, output, offset),
         {:ok, index_entry, offset} <- stream_section(index, :idx, output, offset) do
      stream_pairs(rest, output, offset, [index_entry, pack_entry | files])
    end
  end

  defp validate_inventory(pairs, hash) do
    digest_length = if hash == :sha1, do: 40, else: 64
    pattern = ~r/\Apack-[0-9a-f]{#{digest_length}}\z/

    if Enum.all?(pairs, fn {pack, index} ->
         pack_stem = pack |> Path.basename() |> Path.rootname()
         index_stem = index |> Path.basename() |> Path.rootname()
         pack_stem == index_stem and Regex.match?(pattern, pack_stem)
       end) do
      :ok
    else
      {:error, :invalid_pack_inventory}
    end
  end

  defp stream_section(path, kind, output, offset) do
    case :file.open(String.to_charlist(path), [:read, :raw, :binary]) do
      {:ok, source} ->
        try do
          context = :crypto.hash_init(:sha256)

          with {:ok, length, context} <- copy_chunks(source, output, 0, context),
               true <- length > 0 || {:error, :empty_pack_artifact} do
            entry = %{
              kind: kind,
              name: Path.basename(path),
              offset: offset,
              length: length,
              sha256: :crypto.hash_final(context)
            }

            {:ok, entry, offset + length}
          end
        after
          :file.close(source)
        end

      {:error, reason} ->
        {:error, {:source_artifact_open_failed, reason}}
    end
  end

  defp copy_chunks(source, output, length, context) do
    case :file.read(source, @copy_chunk_bytes) do
      {:ok, bytes} ->
        with :ok <- IO.binwrite(output, bytes) do
          copy_chunks(
            source,
            output,
            length + byte_size(bytes),
            :crypto.hash_update(context, bytes)
          )
        end

      :eof ->
        {:ok, length, context}

      {:error, reason} ->
        {:error, {:source_artifact_read_failed, reason}}
    end
  end

  defp snapshot_refs(%Repository{refs: nil, ref_error: ref_error}, source, _opts) do
    warning =
      warning("source reference store is unavailable for #{source}: #{inspect(ref_error)}")

    {:ok, [], %{}, [warning]}
  end

  defp snapshot_refs(%Repository{} = repository, source, opts) do
    git = opts[:git_executable] || Application.get_env(:gitility, :git_executable, "git")

    with {:ok, listed, warnings} <- collect_ref_pages(repository.refs, nil, [], []),
         {:ok, rows, warnings} <-
           snapshot_listed_refs(listed, repository, source, git, warnings),
         {head, head_metadata, warnings} <-
           snapshot_head(repository, source, git, warnings) do
      rows =
        rows
        |> maybe_add_head(head)
        |> Enum.uniq_by(& &1.name)
        |> Enum.sort_by(& &1.name)

      {:ok, rows, head_metadata, warnings}
    end
  end

  defp collect_ref_pages(refs, cursor, items, warnings) do
    case RefDB.list(refs, limit: 1_000, cursor: cursor) do
      {:ok, page} ->
        items = items ++ page.items
        warnings = warnings ++ Enum.reject(page.warnings, &(&1.code == :truncated))

        if page.truncated do
          if is_binary(page.next_cursor) do
            collect_ref_pages(refs, page.next_cursor, items, warnings)
          else
            {:error,
             Error.new(:backend_error, "ref listing truncated without a cursor",
               operation: :bundle_write
             )}
          end
        else
          {:ok, items, warnings}
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp snapshot_listed_refs(refs, repository, source, git, warnings) do
    Enum.reduce_while(refs, {:ok, [], warnings}, fn ref, {:ok, rows, accumulated_warnings} ->
      case RefDB.resolve(repository.refs, ref.name) do
        {:ok, target} when target != :not_found ->
          case ref_row(ref.name, target, repository.odb, source, git) do
            {:ok, row} ->
              {:cont, {:ok, [row | rows], accumulated_warnings}}

            {:skip, message} ->
              {:cont, {:ok, rows, accumulated_warnings ++ [warning(message)]}}

            {:error, %Error{} = error} ->
              {:halt, {:error, error}}
          end

        {:ok, :not_found} ->
          {:cont,
           {:ok, rows,
            accumulated_warnings ++ [warning("ref #{inspect(ref.name)} became unresolved")]}}

        {:error, %Error{} = error} ->
          {:cont,
           {:ok, rows,
            accumulated_warnings ++ [warning("ref #{inspect(ref.name)}: #{error.message}")]}}
      end
    end)
  end

  defp snapshot_head(repository, source, git, warnings) do
    case RefDB.resolve(repository.refs, "HEAD") do
      {:ok, target} when target != :not_found ->
        case ref_row("HEAD", target, repository.odb, source, git) do
          {:ok, row} ->
            case head_symref(source) do
              {:ok, nil} -> {row, %{}, warnings}
              {:ok, symref} -> {row, %{"head_symref" => symref}, warnings}
              {:error, message} -> {row, %{}, warnings ++ [warning(message)]}
            end

          {:skip, message} ->
            {nil, %{}, warnings ++ [warning("HEAD: #{message}")]}

          {:error, %Error{} = error} ->
            {nil, %{}, warnings ++ [warning("HEAD: #{error.message}")]}
        end

      {:ok, :not_found} ->
        {nil, %{}, warnings ++ [warning("HEAD is unresolved and was omitted")]}

      {:error, %Error{} = error} ->
        {nil, %{}, warnings ++ [warning("HEAD is unresolved: #{error.message}")]}
    end
  end

  defp ref_row(name, target, odb, source, git) do
    case object_kind(odb, target.oid) do
      {:ok, header} ->
        {:ok,
         %{
           name: name,
           target: target.oid,
           kind: header.type,
           peeled: peeled_commit(odb, target, header.type, source, git)
         }}

      {:error, %Error{code: :missing_object}} ->
        {:skip, "ref #{inspect(name)} targets an object missing from the source ODB"}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp peeled_commit(odb, target, :tag, source, git) do
    with nil <- existing_commit_peel(odb, target.peeled, source, git),
         {:ok, peeled} <- peel_to_commit(odb, target.oid, source, git),
         {:ok, %{type: :commit}} <- object_kind(odb, peeled) do
      peeled
    else
      %Gitility.OID{} = peeled -> peeled
      _unavailable -> nil
    end
  end

  defp peeled_commit(odb, target, _kind, source, git),
    do: existing_commit_peel(odb, target.peeled, source, git)

  defp existing_commit_peel(_odb, nil, _source, _git), do: nil

  defp existing_commit_peel(odb, peeled, _source, _git) do
    case object_kind(odb, peeled) do
      {:ok, %{type: :commit}} -> peeled
      _unavailable -> nil
    end
  end

  defp object_kind(odb, oid), do: ODB.header(odb, oid)

  defp peel_to_commit(odb, oid, source, git) do
    case Gitility.peel(odb, oid) do
      {:ok, peeled} ->
        {:ok, peeled}

      {:error, %Error{code: :unsupported_hash}} ->
        # Core peel still gates SHA-256 stores. Remove this Git fallback when
        # the engine can peel SHA-256 tag objects itself.
        git_peel_to_commit(source, git, oid)

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp git_peel_to_commit(source, git, oid) do
    expression = to_string(oid) <> "^{commit}"

    case System.cmd(git, ["-C", source, "rev-parse", "--verify", expression],
           stderr_to_stdout: true
         ) do
      {output, 0} -> OID.parse(String.trim(output))
      {_output, _status} -> {:error, :peel_unavailable}
    end
  rescue
    _exception -> {:error, :peel_unavailable}
  end

  defp head_symref(source) do
    with {:ok, git_directory} <- PackInventory.git_directory(source),
         {:ok, bytes} <- File.read(Path.join(git_directory, "HEAD")) do
      value = trim_line(bytes)

      case value do
        <<"ref: ", symref::binary>> when byte_size(symref) > 0 ->
          if String.valid?(symref), do: {:ok, symref}, else: {:error, "HEAD symref is not UTF-8"}

        _detached ->
          {:ok, nil}
      end
    else
      {:error, reason} -> {:error, "could not inspect HEAD symref: #{inspect(reason)}"}
    end
  end

  defp trim_line(bytes) do
    bytes
    |> String.trim_trailing("\n")
    |> String.trim_trailing("\r")
  end

  defp maybe_add_head(rows, nil), do: rows
  defp maybe_add_head(rows, head), do: [head | rows]

  defp metadata(source, opts) do
    source_identity = opts[:source_identity] || "repository:" <> Path.expand(source)

    entries =
      %{"source_identity" => source_identity}
      |> maybe_put("publisher", opts[:publisher])
      |> maybe_put("created_at", opts[:created_at])

    with :ok <- validate_created_at(opts[:created_at]),
         true <-
           Enum.all?(entries, fn {key, value} ->
             is_binary(value) and String.valid?(value) and byte_size(key) in 1..4096 and
               byte_size(value) <= 65_536
           end) || invalid_write("bundle metadata must be valid UTF-8 within format ceilings") do
      {:ok, entries}
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp validate_created_at(nil), do: :ok

  defp validate_created_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> :ok
      _other -> invalid_write(":created_at must be an RFC3339 timestamp")
    end
  end

  defp validate_created_at(_value), do: invalid_write(":created_at must be an RFC3339 timestamp")

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp source_path({:repository, source}) when is_binary(source), do: {:ok, Path.expand(source)}
  defp source_path(_source), do: invalid_write(":source must be {:repository, directory}")

  defp refuse_shallow_source(source) do
    with {:ok, git_directory} <- PackInventory.git_directory(source) do
      shallow = Path.join(git_directory, "shallow")

      case File.lstat(shallow) do
        {:error, :enoent} ->
          :ok

        {:ok, _stat} ->
          {:error,
           Error.new(
             :unsupported_operation,
             "bundle format v1 cannot publish shallow repository boundary file #{shallow}",
             operation: :bundle_write,
             details: %{shallow_file: shallow, format_version: "1.0"}
           )}

        {:error, reason} ->
          invalid_write("could not inspect shallow boundary file #{shallow}: #{inspect(reason)}")
      end
    else
      {:error, reason} ->
        invalid_write("could not resolve source git directory: #{inspect(reason)}")
    end
  end

  defp required_path(path) when is_binary(path) and byte_size(path) > 0,
    do: {:ok, Path.expand(path)}

  defp required_path(_path),
    do: invalid_argument(":path is required and must be a non-empty binary", :bundle_start_link)

  defp next_generation(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        {:ok, 1}

      {:ok, _stat} ->
        case Format.parse(path) do
          {:ok, toc} ->
            {:ok, toc.generation + 1}

          {:error, %Error{} = error} ->
            {:error,
             Error.new(:invalid_argument, "refusing to overwrite an existing non-bundle file",
               operation: :bundle_write,
               details: %{path: path, parse_code: error.code}
             )}
        end

      {:error, reason} ->
        {:error,
         Error.new(:invalid_argument, "could not inspect the bundle destination",
           operation: :bundle_write,
           details: %{path: path, reason: reason}
         )}
    end
  end

  defp mkdir_destination(directory) do
    case File.mkdir_p(directory) do
      :ok -> :ok
      {:error, reason} -> {:error, {:destination_directory_failed, reason}}
    end
  end

  defp mkdir_staging(staging) do
    case File.mkdir(staging) do
      :ok -> :ok
      {:error, reason} -> {:error, {:staging_directory_failed, reason}}
    end
  end

  defp open_read(path) when is_binary(path) do
    case :file.open(String.to_charlist(path), [:read, :raw, :binary]) do
      {:ok, file} -> {:ok, file}
      {:error, reason} -> malformed_verify("could not open bundle: #{inspect(reason)}")
    end
  end

  defp verify_sections(_file, []), do: :ok

  defp verify_sections(file, [entry | rest]) do
    context = :crypto.hash_init(:sha256)

    with {:ok, context} <- hash_section(file, entry.offset, entry.length, context, entry.name),
         true <-
           :crypto.hash_final(context) == entry.sha256 ||
             malformed_verify("section sha256 mismatch for #{entry.name}"),
         :ok <- verify_sections(file, rest) do
      :ok
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp hash_section(_file, _offset, 0, context, _name), do: {:ok, context}

  defp hash_section(file, offset, remaining, context, name) do
    length = min(remaining, @copy_chunk_bytes)

    case :file.pread(file, offset, length) do
      {:ok, bytes} when byte_size(bytes) == length ->
        hash_section(
          file,
          offset + length,
          remaining - length,
          :crypto.hash_update(context, bytes),
          name
        )

      {:ok, _bytes} ->
        malformed_verify("short read while verifying #{name}")

      :eof ->
        malformed_verify("unexpected EOF while verifying #{name}")

      {:error, reason} ->
        malformed_verify("could not verify #{name}: #{inspect(reason)}")
    end
  end

  defp bundle_children(supervisor) do
    {:ok, Supervisor.which_children(supervisor)}
  catch
    :exit, _reason ->
      {:error,
       Error.new(:provider_down, "bundle supervisor is down",
         retryable: true,
         operation: :bundle_repository
       )}
  end

  defp child_pid(children, id) do
    case List.keyfind(children, id, 0) do
      {^id, pid, :supervisor, _modules} when is_pid(pid) ->
        {:ok, pid}

      _missing ->
        {:error,
         Error.new(:provider_down, "bundle store child is down",
           retryable: true,
           operation: :bundle_repository,
           details: %{child: inspect(id)}
         )}
    end
  end

  defp warning(message), do: %{code: :malformed_ref, message: message}

  defp write_error(reason) do
    {:error,
     Error.new(:backend_error, "bundle publication failed",
       operation: :bundle_write,
       details: %{reason: inspect(reason, limit: 20, printable_limit: 256)}
     )}
  end

  defp invalid_write(message), do: invalid_argument(message, :bundle_write)

  defp invalid_argument(message, operation) do
    {:error, Error.new(:invalid_argument, message, operation: operation)}
  end

  defp malformed_verify(message) do
    {:error, Error.new(:malformed_object, message, operation: :bundle_verify)}
  end
end
