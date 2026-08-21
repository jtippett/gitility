defmodule Gitility.Bundle do
  @moduledoc """
  Deterministic single-file, read-only Git repositories.

  A full-repository bundle contains raw pack/index pairs plus a direct
  reference snapshot. PackFetch hydration bundles are ODB-only artifacts with
  zero reference rows; use `write/2` when the reference snapshot is required.
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

  alias Gitility.{
    Bundle.Format,
    Bundle.Receipt,
    Bundle.Writer,
    Error,
    Limits,
    ODB,
    OID,
    RefDB,
    RefName,
    Repository
  }

  alias Gitility.ODB.PackInventory

  @copy_chunk_bytes 8 * 1024 * 1024
  @default_hydration_bytes 4 * 1024 * 1024 * 1024
  @default_memory_bytes 256 * 1024 * 1024
  @maximum_generation 18_446_744_073_709_551_615
  @strict_peel_object_bytes 64 * 1024 * 1024
  @strict_peel_total_bytes 256 * 1024 * 1024

  @doc """
  Publishes a complete local repository as one deterministic bundle file.

  `:source` must be `{:repository, directory}`. Optional metadata is supplied
  with `:source_identity`, `:publisher`, and `:created_at`; timestamps are
  never synthesized. `:git_executable` selects the executable used to pack
  loose objects and to peel SHA-256 tags while the engine cannot do so.

  `:generation` may explicitly select a value from 1 through `2^64 - 1`; when
  replacing a bundle it must be greater than the existing generation.
  `strict_refs: true` turns every degraded reference snapshot into an error
  and guarantees an empty warning list on success. `:mode` applies Unix
  permission bits to the writer's temporary file before any bundle bytes are
  written; `nil` retains the process umask behavior.
  """
  @spec write(Path.t(), keyword()) :: {:ok, Receipt.t()} | {:error, Error.t()}
  def write(path, opts) do
    with :ok <- validate_write_path(path),
         {:ok, validated} <- validate_write_options(opts) do
      write_validated(path, validated)
    end
  end

  @doc false
  @spec classify_destination(Path.t(), atom()) ::
          :missing | {:ok, Format.toc()} | {:error, Error.t()}
  def classify_destination(path, operation) when is_binary(path) and is_atom(operation) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :missing

      {:ok, _stat} ->
        case Format.parse(path) do
          {:ok, toc} ->
            {:ok, toc}

          {:error, %Error{code: code}} when code in [:invalid_argument, :malformed_object] ->
            {:error,
             Error.new(:invalid_argument, "refusing to overwrite an existing non-bundle file",
               operation: operation,
               details: %{path: path, parse_code: code}
             )}

          {:error, %Error{} = error} ->
            {:error, error}
        end

      {:error, reason} ->
        destination_io_error("could not inspect the bundle destination", path, reason, operation)
    end
  end

  defp write_validated(path, opts) do
    path = Path.expand(path)

    with {:ok, source} <- source_path(opts[:source]),
         :ok <- refuse_shallow_source(source),
         {:ok, generation} <- next_generation(path, opts[:generation]),
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
         :ok <- validate_into(opts[:into]),
         {:ok, toc} <- Format.parse(path) do
      configured =
        opts
        |> Keyword.put(:path, path)
        |> Keyword.put(:toc, toc)

      Gitility.Bundle.Supervisor.start_link(configured)
    end
  end

  # Validated in the caller: an invalid destination failing inside the
  # supervisor's child start would exit the linked caller instead of
  # returning the documented error tuple.
  defp validate_into(:memory) do
    if Gitility.ODB.PackFetch.memory_supported?() do
      :ok
    else
      {:error,
       Error.new(
         :unsupported_operation,
         "into: :memory requires Linux /dev/shm; use into: {:dir, path}",
         operation: :bundle_start_link
       )}
    end
  end

  defp validate_into({:dir, path}) when is_binary(path) and byte_size(path) > 0, do: :ok
  defp validate_into({:bundle, path}) when is_binary(path) and byte_size(path) > 0, do: :ok

  defp validate_into(_other) do
    {:error,
     Error.new(
       :invalid_argument,
       ":into must be :memory, {:dir, path}, or {:bundle, path}",
       operation: :bundle_start_link
     )}
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
    suffix = random_hex(16)
    staging = Path.join(directory, ".#{Path.basename(path)}.staging-#{suffix}")

    with :ok <- mkdir_destination(directory),
         :ok <- mkdir_staging(staging) do
      try do
        with {:ok, pairs} <-
               PackInventory.collect(source, staging,
                 allow_empty: true,
                 git_executable: opts[:git_executable]
               ),
             :ok <- validate_inventory(pairs, repository.odb.hash),
             {:ok, refs, ref_metadata, warnings} <- snapshot_refs(repository, source, opts),
             {:ok, receipt} <-
               Writer.write(
                 path,
                 pairs: pairs,
                 hash_algorithm: repository.odb.hash,
                 generation: generation,
                 metadata: Map.merge(metadata, ref_metadata),
                 refs: refs,
                 warnings: warnings,
                 mode: opts[:mode]
               ) do
          {:ok, receipt}
        else
          {:error, %Error{} = error} -> {:error, error}
          {:error, reason} -> write_error(reason)
        end
      after
        File.rm_rf(staging)
      end
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> write_error(reason)
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

  defp snapshot_refs(%Repository{refs: nil}, source, %{strict_refs: true}) do
    strict_ref_error("source reference store is unavailable for #{source}")
  end

  defp snapshot_refs(%Repository{refs: nil, ref_error: ref_error}, source, _opts) do
    warning =
      warning("source reference store is unavailable for #{source}: #{inspect(ref_error)}")

    {:ok, [], %{}, [warning]}
  end

  defp snapshot_refs(%Repository{} = repository, source, opts) do
    git = opts[:git_executable] || Application.get_env(:gitility, :git_executable, "git")
    strict? = opts[:strict_refs]

    with {:ok, listed, warnings} <- collect_ref_pages(repository.refs, nil, [], []),
         :ok <- reject_snapshot_warnings(warnings, strict?),
         {:ok, rows, warnings} <-
           snapshot_listed_refs(
             Enum.reject(listed, &(&1.name == "HEAD")),
             repository,
             source,
             git,
             warnings,
             strict?
           ),
         {:ok, head, head_metadata, warnings} <-
           snapshot_head(
             repository,
             source,
             git,
             Enum.reject(listed, &(&1.name == "HEAD")),
             rows,
             warnings,
             strict?
           ) do
      rows =
        rows
        |> maybe_add_head(head)
        |> Enum.uniq_by(& &1.name)
        |> Enum.sort_by(& &1.name)

      {:ok, rows, head_metadata, warnings}
    end
  end

  defp reject_snapshot_warnings([], _strict?), do: :ok
  defp reject_snapshot_warnings(_warnings, false), do: :ok

  defp reject_snapshot_warnings([first | _rest], true) do
    strict_ref_error("reference listing produced a degraded snapshot",
      snapshot_warning: Map.get(first, :code, :malformed_ref)
    )
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

  defp snapshot_listed_refs(refs, repository, source, git, warnings, strict?) do
    Enum.reduce_while(refs, {:ok, [], warnings}, fn ref, {:ok, rows, accumulated_warnings} ->
      case maybe_validate_strict_ref_name(ref.name, strict?) do
        :ok ->
          case RefDB.resolve(repository.refs, ref.name) do
            {:ok, target} when target != :not_found ->
              case ref_row(ref.name, target, repository.odb, source, git, strict?) do
                {:ok, row, row_warnings} ->
                  {:cont, {:ok, [row | rows], accumulated_warnings ++ row_warnings}}

                {:skip, message} ->
                  {:cont, {:ok, rows, accumulated_warnings ++ [warning(message)]}}

                {:error, %Error{} = error} ->
                  {:halt, {:error, error}}
              end

            {:ok, :not_found} when strict? ->
              {:halt, strict_ref_error("ref #{inspect(ref.name)} became unresolved")}

            {:ok, :not_found} ->
              {:cont,
               {:ok, rows,
                accumulated_warnings ++ [warning("ref #{inspect(ref.name)} became unresolved")]}}

            {:error, %Error{} = error} when strict? ->
              {:halt,
               strict_ref_error("ref #{inspect(ref.name)} could not be resolved",
                 resolve_error: error.code
               )}

            {:error, %Error{} = error} ->
              {:cont,
               {:ok, rows,
                accumulated_warnings ++ [warning("ref #{inspect(ref.name)}: #{error.message}")]}}
          end

        {:error, %Error{} = error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp maybe_validate_strict_ref_name(name, true), do: validate_strict_ref_name(name)
  defp maybe_validate_strict_ref_name(_name, false), do: :ok

  defp snapshot_head(repository, source, git, _listed, _rows, warnings, false) do
    case RefDB.resolve(repository.refs, "HEAD") do
      {:ok, target} when target != :not_found ->
        case ref_row("HEAD", target, repository.odb, source, git, false) do
          {:ok, row, row_warnings} ->
            warnings = warnings ++ row_warnings

            case head_symref(source) do
              {:ok, nil} -> {:ok, row, %{}, warnings}
              {:ok, symref} -> {:ok, row, %{"head_symref" => symref}, warnings}
              {:error, message} -> {:ok, row, %{}, warnings ++ [warning(message)]}
            end

          {:skip, message} ->
            {:ok, nil, %{}, warnings ++ [warning("HEAD: #{message}")]}

          {:error, %Error{} = error} ->
            {:ok, nil, %{}, warnings ++ [warning("HEAD: #{error.message}")]}
        end

      {:ok, :not_found} ->
        {:ok, nil, %{}, warnings ++ [warning("HEAD is unresolved and was omitted")]}

      {:error, %Error{} = error} ->
        {:ok, nil, %{}, warnings ++ [warning("HEAD is unresolved: #{error.message}")]}
    end
  end

  defp snapshot_head(repository, source, git, listed, rows, warnings, true) do
    with {:ok, symref} <- strict_head_symref(source) do
      case RefDB.resolve(repository.refs, "HEAD") do
        {:ok, target} when target != :not_found ->
          with :ok <- validate_strict_head_symref(symref),
               {:ok, row, []} <- ref_row("HEAD", target, repository.odb, source, git, true),
               :ok <- validate_resolved_head(row, symref, rows) do
            metadata = if is_binary(symref), do: %{"head_symref" => symref}, else: %{}
            {:ok, row, metadata, warnings}
          end

        {:ok, :not_found} ->
          validate_unborn_head(symref, listed, warnings)

        {:error, %Error{} = error} ->
          strict_ref_error("HEAD could not be resolved", resolve_error: error.code)
      end
    end
  end

  defp strict_head_symref(source) do
    case head_symref(source) do
      {:ok, symref} -> {:ok, symref}
      {:error, _message} -> strict_ref_error("HEAD symbolic target could not be read")
    end
  end

  defp validate_strict_head_symref(nil), do: :ok

  defp validate_strict_head_symref(symref) do
    case RefName.validate(symref) do
      :ok ->
        if RefName.valid_branch?(symref) do
          :ok
        else
          strict_ref_error("HEAD symbolic target must be a valid name under refs/heads/",
            reason: :not_a_branch
          )
        end

      {:error, reason} ->
        strict_ref_error("HEAD symbolic target must be a valid name under refs/heads/",
          reason: reason
        )
    end
  end

  defp validate_resolved_head(_head, nil, _rows), do: :ok

  defp validate_resolved_head(head, symref, rows) do
    case Enum.find(rows, &(&1.name == symref)) do
      %{target: target} when target == head.target ->
        :ok

      %{target: _other} ->
        strict_ref_error("HEAD symbolic target disagrees with the resolved HEAD row")

      nil ->
        strict_ref_error("HEAD symbolic target is absent from the source refs")
    end
  end

  defp validate_unborn_head(symref, listed, warnings) when is_binary(symref) do
    with :ok <- validate_strict_head_symref(symref),
         false <- Enum.any?(listed, &(&1.name == symref)) do
      {:ok, nil, %{"head_symref" => symref}, warnings}
    else
      true -> strict_ref_error("unborn HEAD symbolic target is present in the source refs")
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp validate_unborn_head(nil, _listed, _warnings) do
    strict_ref_error("HEAD is unresolved and has no symbolic branch target")
  end

  defp ref_row(name, target, odb, source, git, true) do
    with :ok <- validate_strict_ref_name(name) do
      do_ref_row(name, target, odb, source, git, true)
    end
  end

  defp ref_row(name, target, odb, source, git, false) do
    do_ref_row(name, target, odb, source, git, false)
  end

  defp do_ref_row(name, target, odb, source, git, strict?) do
    case object_kind(odb, target.oid) do
      {:ok, header} ->
        with {:ok, peeled, peel_warnings} <-
               peeled_commit(odb, target, header.type, source, git, name, strict?) do
          {:ok,
           %{
             name: name,
             target: target.oid,
             kind: header.type,
             peeled: peeled
           }, peel_warnings}
        end

      {:error, %Error{code: :missing_object}} when strict? ->
        {:error,
         Error.new(
           :missing_object,
           "ref #{inspect(name)} targets an object missing from the source ODB",
           operation: :bundle_write,
           details: %{ref: name}
         )}

      {:error, %Error{code: :missing_object}} ->
        {:skip, "ref #{inspect(name)} targets an object missing from the source ODB"}

      {:error, %Error{} = error} when strict? ->
        strict_ref_error("ref #{inspect(name)} targets an unreadable object",
          ref: name,
          object_error: error.code
        )

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp validate_strict_ref_name(name) do
    case RefName.validate(name) do
      :ok ->
        :ok

      {:error, reason} ->
        strict_ref_error("ref #{inspect(name)} is not a portable full reference name",
          ref: name,
          reason: reason
        )
    end
  end

  defp peeled_commit(odb, target, :tag, source, git, name, true) do
    peel_commit_with_policy(odb, target.oid, source, git, name, true)
  end

  defp peeled_commit(odb, target, :tag, source, git, name, false) do
    with nil <- existing_commit_peel(odb, target.peeled, source, git),
         {:ok, peeled, warnings} <-
           peel_commit_with_policy(odb, target.oid, source, git, name, false) do
      {:ok, peeled, warnings}
    else
      %OID{} = peeled -> {:ok, peeled, []}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp peeled_commit(odb, target, _kind, source, git, _name, _strict?),
    do: {:ok, existing_commit_peel(odb, target.peeled, source, git), []}

  defp peel_commit_with_policy(odb, oid, source, git, name, strict?) do
    with {:ok, peeled} <- peel_to_commit(odb, oid, source, git, strict?),
         {:ok, %{type: :commit}} <- object_kind(odb, peeled) do
      {:ok, peeled, []}
    else
      {:ok, %{type: type}} -> peel_failure(name, {:kind, type}, strict?)
      {:error, reason} -> peel_failure(name, reason, strict?)
    end
  end

  defp peel_failure(name, reason, true) do
    peel_error = if match?(%Error{}, reason), do: reason.code, else: reason

    {:error,
     Error.new(:malformed_ref, "ref #{inspect(name)} could not be peeled to a commit",
       operation: :bundle_write,
       details: %{ref: name, peel_error: peel_error}
     )}
  end

  defp peel_failure(name, _reason, false) do
    {:ok, nil, [warning("ref #{inspect(name)} could not be peeled to a commit")]}
  end

  defp existing_commit_peel(_odb, nil, _source, _git), do: nil

  defp existing_commit_peel(odb, peeled, _source, _git) do
    case object_kind(odb, peeled) do
      {:ok, %{type: :commit}} -> peeled
      _unavailable -> nil
    end
  end

  defp object_kind(odb, oid), do: ODB.header(odb, oid)

  defp peel_to_commit(odb, oid, source, git, strict?) do
    opts =
      if strict? do
        [
          limits: %Limits{
            timeout_ms: Limits.new().timeout_ms,
            max_object_bytes: @strict_peel_object_bytes,
            max_total_object_bytes: @strict_peel_total_bytes
          }
        ]
      else
        []
      end

    case Gitility.peel(odb, oid, opts) do
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

  defp validate_write_path(path) when is_binary(path) and byte_size(path) > 0 do
    if String.valid?(path) and not String.contains?(path, <<0>>) do
      :ok
    else
      invalid_write("bundle path must be valid UTF-8 without NUL bytes")
    end
  end

  defp validate_write_path(_path),
    do: invalid_write("bundle path must be a non-empty binary")

  defp validate_write_options(opts) when is_list(opts) do
    defaults = %{
      source: nil,
      source_identity: nil,
      publisher: nil,
      created_at: nil,
      git_executable: nil,
      generation: nil,
      strict_refs: false,
      mode: nil
    }

    if proper_list?(opts) do
      Enum.reduce_while(opts, {:ok, defaults}, fn
        {:source, value}, {:ok, options} ->
          {:cont, {:ok, %{options | source: value}}}

        {key, value}, {:ok, options}
        when key in [:source_identity, :publisher, :created_at, :git_executable] ->
          if is_nil(value) or (is_binary(value) and String.valid?(value)) do
            {:cont, {:ok, Map.put(options, key, value)}}
          else
            {:halt, invalid_write("unknown or invalid bundle write option: #{inspect(key)}")}
          end

        {:generation, value}, {:ok, options}
        when is_nil(value) or
               (is_integer(value) and value >= 1 and value <= @maximum_generation) ->
          {:cont, {:ok, %{options | generation: value}}}

        {:strict_refs, value}, {:ok, options} when is_boolean(value) ->
          {:cont, {:ok, %{options | strict_refs: value}}}

        {:mode, value}, {:ok, options}
        when is_nil(value) or (is_integer(value) and value >= 0 and value <= 0o777) ->
          {:cont, {:ok, %{options | mode: value}}}

        {key, _value}, _acc when is_atom(key) ->
          {:halt, invalid_write("unknown or invalid bundle write option: #{inspect(key)}")}

        _malformed, _acc ->
          {:halt, invalid_write("bundle write options must be a keyword list")}
      end)
    else
      invalid_write("bundle write options must be a keyword list")
    end
  end

  defp validate_write_options(_opts),
    do: invalid_write("bundle write options must be a keyword list")

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_tail), do: false

  defp source_path({:repository, source}) when is_binary(source) and byte_size(source) > 0 do
    if String.valid?(source) and not String.contains?(source, <<0>>) do
      {:ok, Path.expand(source)}
    else
      invalid_write(":source path must be valid UTF-8 without NUL bytes")
    end
  end

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

  defp next_generation(path, requested) do
    case classify_destination(path, :bundle_write) do
      :missing ->
        {:ok, requested || 1}

      {:ok, %{generation: @maximum_generation}} when is_nil(requested) ->
        {:error,
         Error.new(:unsupported_operation, "bundle generation space exhausted",
           operation: :bundle_write
         )}

      {:ok, toc} ->
        cond do
          is_nil(requested) ->
            {:ok, toc.generation + 1}

          requested > toc.generation ->
            {:ok, requested}

          true ->
            invalid_write(":generation must be greater than the existing bundle generation")
        end

      {:error, %Error{} = error} ->
        {:error, error}
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
      {:error, reason} -> verify_io_error("could not open bundle", reason)
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
        verify_io_error("could not verify #{name}", reason)
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

  defp strict_ref_error(message, details \\ []) do
    {:error,
     Error.new(:malformed_ref, message,
       operation: :bundle_write,
       details: Map.new(details)
     )}
  end

  defp destination_io_error(message, path, reason, operation) do
    {:error,
     Error.new(:backend_error, message,
       retryable: reason in [:eagain, :eintr, :eio, :emfile, :enfile, :estale],
       operation: operation,
       details: %{path: path, reason: reason}
     )}
  end

  defp write_error({:toc_too_large, size, max}) do
    {:error,
     Error.new(
       :unsupported_operation,
       "bundle table of contents exceeds the v1 format ceiling",
       operation: :bundle_write,
       details: %{toc_bytes: size, max_toc_bytes: max}
     )}
  end

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

  defp verify_io_error(message, reason) do
    {:error,
     Error.new(:backend_error, message,
       retryable: reason in [:eagain, :eintr, :eio, :emfile, :enfile, :estale],
       operation: :bundle_verify,
       details: %{reason: reason}
     )}
  end

  defp random_hex(bytes), do: :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)
end
