defmodule Gitility.ODB.PackFetch do
  @moduledoc """
  Eagerly hydrates an immutable pack manifest into a local gix object store.

  `start_link/1` uses the same callback supervision and request-resource
  protocol as `Gitility.ODB.start_link/1`, but the backend implements
  `Gitility.ODB.RangeBackend`. Startup deliberately blocks until the initial
  manifest has been fetched, every pack/index pair has been verified and
  atomically published, and the resulting objects directory is open. A handle
  is never exposed in a half-hydrated state.

      {:ok, supervisor} =
        Gitility.ODB.PackFetch.start_link(
          backend: {MyApp.PackStore, backend_options},
          into: {:dir, "/var/cache/gitility"},
          concurrency: 8,
          verify: :always
        )

      {:ok, odb} = Gitility.ODB.handle(supervisor)

  `into: {:dir, path}` writes only beneath the explicit path, using
  `objects/pack/pack-<checksum>.{pack,idx}`. Existing valid pairs are reused;
  corrupt pairs are replaced. Removed manifest entries are retained in 0.2 —
  refresh never deletes packs during the publisher's grace period. If a
  later pack fails, earlier verified pairs remain for the next attempt; no
  unverified file is left under a final name. Within one store lifetime,
  refresh size-checks already verified pairs and is O(new packs). A restart
  re-hashes the whole reused volume once because trust is never persisted to
  disk.

  `into: :memory` is available only on Linux. It uses a caller-invisible
  directory below `/dev/shm`, which is a RAM-backed tmpfs, enforces
  `max_bytes`, and removes the directory during orderly provider shutdown.
  Native resource destruction never performs filesystem work on a BEAM
  scheduler. An abnormal death can leave this bounded tmpfs directory; the
  next `start_link/1` with the same `:name` sweeps it before starting. This is
  not a bytes-in-Rust gix store: stock gix-pack is path-only and mmap-based
  (design finding F7). macOS and other platforms return
  `:unsupported_operation`; use an explicit directory there.

  `into: {:bundle, path}` serves from a caller-invisible private scratch
  directory below `System.tmp_dir!/0` while maintaining `path` as the durable
  artifact. A valid existing bundle is checksum-extracted into that scratch
  directory before hydration, so warm starts reuse its verified pairs without
  remote reads; corrupt sections are omitted and fetched again. The scratch
  directory is always removed during orderly provider shutdown, while the
  bundle is never cleaned up by the provider. An abnormal death can leave the
  scratch directory, including full pack copies, on real disk; the next
  `start_link/1` for the same expanded bundle path sweeps it before starting.

  Hydration bundles contain the current manifest's pack/index pairs and zero
  reference rows: they are ODB-only snapshots. Use `Gitility.Bundle.write/2`
  for a full repository bundle with refs. The file is atomically replaced only
  when the would-be snapshot changes. It records the manifest from the last
  completed `start_link/1` hydration. `Gitility.ODB.refresh/1` serves new packs
  from the scratch store without rewriting the bundle; restarting re-publishes
  the latest manifest. Packs removed from that manifest remain in scratch for
  the process lifetime, but the rewritten bundle omits them, so the grace
  period does not survive a bundle-destination restart. Exactly one store may
  own a bundle path at a time; concurrent writers to one path are outside the
  contract. Correct concurrent refresh publication requires a future
  single-owner publisher design. A non-bundle file at `path` is never
  clobbered; remove it explicitly before starting PackFetch.

  ## Options

    * `:backend` (required) — `{module, init_arg}` implementing
      `Gitility.ODB.RangeBackend`.
    * `:into` — `{:dir, path}`, `{:bundle, path}`, or `:memory` (default
      `:memory`).
    * `:name` — supervisor registered name; omitted starts privately.
    * `:hash` — `:sha1` (default) or `:sha256`; must match the manifest.
    * `:concurrency` — maximum outstanding `read_ranges` callbacks per pack
      (default `8`).
    * `:chunk_bytes` — fixed pack range size (default 8 MiB).
    * `:request_timeout` — per-callback timeout in milliseconds (default
      `15_000`).
    * `:verify` — only `:always` is accepted.
    * `:runtime` — query runtime (default shared).
    * `:max_hydration_bytes` — bytes the hydration plan may actually fetch
      (default 4 GiB). This one-time bulk-load ceiling is distinct from
      query-time `Gitility.Limits.max_provider_bytes` (default 256 MiB).
      Existing pairs are verified before planning, so a warm volume is
      charged only for manifest metadata plus missing or corrupt pairs. Local
      pre-extraction from a bundle is never charged to this backend-read
      budget.
    * `:limits` — the other hydration-job ceilings and timeout. Hydration
      always replaces this struct's `max_provider_bytes` with
      `max_hydration_bytes`; query-time limits are unchanged.
    * `:max_bytes` — RAM destination ceiling (default 256 MiB); used only by
      `into: :memory`.
    * `:bundle_source_identity` — deterministic `source_identity` metadata for
      `into: {:bundle, path}`. Defaults to
      `"packfetch:generation:" <> manifest.generation`.
  """

  alias Gitility.{Bundle, Bundle.Writer, Error, Limits, Native, NativeSupport, ODB}
  alias Gitility.PackManifest

  @default_chunk_bytes 8 * 1024 * 1024
  @default_memory_bytes 256 * 1024 * 1024
  @default_hydration_bytes 4 * 1024 * 1024 * 1024
  @copy_chunk_bytes 8 * 1024 * 1024

  @doc """
  Starts a PackFetch store over a range backend.

  `:backend` (`{module, init_arg}`) and `:limits` are required; `:into`
  selects the hydration destination (`:memory` by default, `{:dir, path}`,
  or `{:bundle, path}`). See the moduledoc for the full option set and the
  semantics of each destination.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    opts =
      Keyword.validate!(opts,
        backend: nil,
        into: :memory,
        name: nil,
        hash: :sha1,
        concurrency: 8,
        chunk_bytes: @default_chunk_bytes,
        request_timeout: 15_000,
        verify: :always,
        runtime: :default,
        limits: nil,
        max_hydration_bytes: @default_hydration_bytes,
        max_bytes: @default_memory_bytes,
        bundle_source_identity: nil
      )

    name = opts[:name] || {:global, {Gitility.ODB.PackFetch.Supervisor, make_ref()}}

    with :ok <- validate_backend(opts[:backend]),
         :ok <- validate_name(name),
         :ok <- validate_hash(opts[:hash]),
         :ok <- validate_verify(opts[:verify]),
         {:ok, concurrency} <- positive(opts[:concurrency], :concurrency),
         {:ok, chunk_bytes} <- positive(opts[:chunk_bytes], :chunk_bytes),
         {:ok, request_timeout} <- positive(opts[:request_timeout], :request_timeout),
         {:ok, max_hydration_bytes} <-
           positive(opts[:max_hydration_bytes], :max_hydration_bytes),
         :ok <-
           validate_bundle_source_identity(opts[:into], opts[:bundle_source_identity]),
         {:ok, limits} <- hydration_limits(opts[:limits], max_hydration_bytes),
         {:ok, runtime, _runtime_resource} <- NativeSupport.runtime_and_resource(opts[:runtime]),
         {:ok, destination} <-
           destination(
             opts[:into],
             opts[:max_bytes],
             name,
             opts[:bundle_source_identity],
             opts[:hash]
           ) do
      start_provider(
        opts,
        name,
        runtime,
        limits,
        destination,
        concurrency,
        chunk_bytes,
        request_timeout,
        max_hydration_bytes
      )
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, {:backend_init, reason}} ->
        {:error, reason}

      {:error, {:backend_init_raised, message}} ->
        {:error, {:backend_init_raised, message}}

      {:error, reason} ->
        {:error,
         Error.new(:backend_error, "PackFetch provider failed to start",
           retryable: true,
           operation: :packfetch_start_link,
           details: %{reason: sanitize_reason(reason)}
         )}
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

  @doc "Returns whether `into: :memory` is supported on this platform."
  @spec memory_supported?() :: boolean()
  def memory_supported?, do: :os.type() == {:unix, :linux} and File.dir?("/dev/shm")

  defp start_provider(
         opts,
         name,
         runtime,
         limits,
         destination,
         concurrency,
         chunk_bytes,
         request_timeout,
         max_hydration_bytes
       ) do
    result =
      Gitility.ODB.Provider.Supervisor.start_link(
        backend: opts[:backend],
        callback_kind: :range,
        name: name,
        hash: opts[:hash],
        concurrency: concurrency,
        request_timeout: request_timeout,
        runtime: runtime,
        packfetch_limits: limits,
        packfetch_cleanup_destination: if(destination.cleanup?, do: destination.path),
        packfetch_options: %{
          request_timeout_ms: request_timeout,
          destination: destination.path,
          chunk_bytes: chunk_bytes,
          concurrency: concurrency,
          max_hydration_bytes: max_hydration_bytes,
          max_bytes: destination.max_bytes
        }
      )

    case result do
      {:ok, supervisor} ->
        case hydrate_and_persist(supervisor, limits, destination) do
          :ok ->
            {:ok, supervisor}

          {:error, %Error{} = error} ->
            stop_failed_start(supervisor)
            cleanup_destination(destination)
            {:error, error}
        end

      {:error, reason} ->
        cleanup_destination(destination)
        normalize_provider_start_error(reason)
    end
  end

  defp hydrate_and_persist(supervisor, limits, %{bundle: nil}) do
    with {:ok, odb} <- ODB.handle(supervisor),
         {:ok, _stats} <- hydrate(odb, limits) do
      :ok
    end
  end

  defp hydrate_and_persist(
         supervisor,
         limits,
         %{bundle: context, damaged?: force_rewrite?}
       )
       when is_map(context) do
    with {:ok, odb} <- ODB.handle(supervisor),
         {:ok, _stats} <- hydrate(odb, limits),
         :ok <- persist_bundle(odb, context, force_rewrite?) do
      :ok
    end
  end

  defp hydrate(%ODB{} = odb, limits) do
    limits_map = NativeSupport.limits_map!(limits)

    case NativeSupport.await_sync(
           fn ->
             NativeSupport.submit_job(odb.runtime, :packfetch_hydrate, fn runtime_resource ->
               Native.packfetch_hydrate(runtime_resource, odb.ref, limits_map)
             end)
           end,
           limits.timeout_ms,
           :packfetch_hydrate
         ) do
      {:ok, stats} -> {:ok, stats}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp destination({:dir, path}, _max_bytes, _name, _source_identity, _hash)
       when is_binary(path) and byte_size(path) > 0 do
    {:ok,
     %{path: Path.expand(path), cleanup?: false, max_bytes: nil, bundle: nil, damaged?: false}}
  end

  defp destination(:memory, max_bytes, name, _source_identity, _hash)
       when is_integer(max_bytes) and max_bytes > 0 do
    if memory_supported?() do
      key = memory_destination_key(name)

      with :ok <- sweep_memory_leftovers(name, key) do
        unique = System.unique_integer([:positive, :monotonic])

        {:ok,
         %{
           path: "/dev/shm/gitility-packfetch-#{key}-#{unique}",
           cleanup?: true,
           max_bytes: max_bytes,
           bundle: nil,
           damaged?: false
         }}
      end
    else
      {:error,
       Error.new(
         :unsupported_operation,
         "into: :memory requires Linux /dev/shm; use into: {:dir, path}",
         operation: :packfetch_start_link
       )}
    end
  end

  defp destination(:memory, _max_bytes, _name, _source_identity, _hash),
    do: NativeSupport.invalid_argument(":max_bytes must be a positive integer for into: :memory")

  defp destination({:bundle, path}, _max_bytes, name, source_identity, hash)
       when is_binary(path) and byte_size(path) > 0 do
    prepare_bundle_destination(Path.expand(path), name, source_identity, hash)
  end

  defp destination(_into, _max_bytes, _name, _source_identity, _hash) do
    NativeSupport.invalid_argument(":into must be :memory, {:dir, path}, or {:bundle, path}")
  end

  defp prepare_bundle_destination(path, name, source_identity, hash) do
    with {:ok, toc} <- existing_bundle(path),
         :ok <- validate_existing_bundle(toc, hash, path),
         {:ok, scratch} <- create_bundle_scratch(path, name) do
      case extract_bundle(toc, path, scratch) do
        {:ok, damaged?} ->
          {:ok,
           %{
             path: scratch,
             cleanup?: true,
             max_bytes: nil,
             bundle: %{path: path, destination: scratch, source_identity: source_identity},
             damaged?: damaged?
           }}

        {:error, %Error{} = error} ->
          File.rm_rf(scratch)
          {:error, error}
      end
    end
  end

  defp existing_bundle(path) do
    case Bundle.classify_destination(path, :packfetch_start_link) do
      :missing -> {:ok, nil}
      {:ok, toc} -> {:ok, toc}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp validate_existing_bundle(nil, _hash, _path), do: :ok

  defp validate_existing_bundle(%{hash_algorithm: hash, refs: refs}, hash, path) do
    validate_existing_bundle_refs(path, length(refs))
  end

  defp validate_existing_bundle(%{hash_algorithm: actual}, expected, path) do
    {:error,
     Error.new(
       :invalid_argument,
       "bundle destination hash algorithm #{actual} does not match configured PackFetch hash #{expected}",
       operation: :packfetch_start_link,
       details: %{path: path, bundle_hash: actual, configured_hash: expected}
     )}
  end

  defp validate_existing_bundle_refs(path, ref_count) when ref_count > 0 do
    {:error,
     Error.new(
       :invalid_argument,
       "bundle destination contains #{ref_count} refs; hydration bundles are ODB-only; use Gitility.Bundle.write/2 for full repository bundles",
       operation: :packfetch_start_link,
       details: %{path: path, ref_count: ref_count}
     )}
  end

  defp validate_existing_bundle_refs(_path, 0), do: :ok

  defp create_bundle_scratch(path, name) do
    key = bundle_destination_key(path)
    root = System.tmp_dir!()
    prefix = "gitility-packfetch-bundle-#{key}"

    with :ok <- sweep_bundle_leftovers(name, root, prefix) do
      unique = System.unique_integer([:positive, :monotonic])
      scratch = Path.join(root, "#{prefix}-#{unique}")

      case File.mkdir(scratch) do
        :ok -> set_bundle_scratch_mode(scratch)
        {:error, reason} -> bundle_io_error("could not create bundle scratch directory", reason)
      end
    end
  end

  defp set_bundle_scratch_mode(scratch) do
    case File.chmod(scratch, 0o700) do
      :ok ->
        {:ok, scratch}

      {:error, reason} ->
        File.rmdir(scratch)
        bundle_io_error("could not make bundle scratch directory private", reason)
    end
  end

  defp sweep_bundle_leftovers(name, root, prefix) do
    if registered?(name) do
      :ok
    else
      root
      |> Path.join("#{prefix}-*")
      |> Path.wildcard()
      |> Enum.reduce_while(:ok, fn path, :ok ->
        case File.rm_rf(path) do
          {:ok, _removed} ->
            {:cont, :ok}

          {:error, reason, failed} ->
            {:halt, bundle_io_error("could not sweep bundle scratch directory #{failed}", reason)}
        end
      end)
    end
  end

  defp extract_bundle(nil, _path, scratch) do
    case File.mkdir_p(pack_directory(scratch)) do
      :ok -> {:ok, false}
      {:error, reason} -> bundle_io_error("could not create bundle extraction directory", reason)
    end
  end

  defp extract_bundle(toc, path, scratch) do
    pack_dir = pack_directory(scratch)

    with :ok <- mkdir_pack_directory(pack_dir),
         {:ok, source} <- open_bundle_source(path) do
      try do
        Enum.reduce_while(toc.files, {:ok, false}, fn entry, {:ok, damaged?} ->
          case extract_section(source, entry, pack_dir) do
            {:ok, section_damaged?} -> {:cont, {:ok, damaged? or section_damaged?}}
            {:error, %Error{} = error} -> {:halt, {:error, error}}
          end
        end)
      after
        :file.close(source)
      end
    end
  end

  defp mkdir_pack_directory(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> bundle_io_error("could not create bundle extraction directory", reason)
    end
  end

  defp open_bundle_source(path) do
    case :file.open(String.to_charlist(path), [:read, :raw, :binary]) do
      {:ok, source} -> {:ok, source}
      {:error, reason} -> bundle_io_error("could not open bundle for extraction", reason)
    end
  end

  defp extract_section(source, entry, pack_dir) do
    destination = Path.join(pack_dir, entry.name)
    unique = System.unique_integer([:positive, :monotonic])
    temp = Path.join(pack_dir, ".#{entry.name}.extract-#{unique}")

    try do
      case :file.open(String.to_charlist(temp), [:write, :raw, :binary, :exclusive]) do
        {:ok, output} ->
          result =
            try do
              context = :crypto.hash_init(:sha256)

              with {:ok, context} <-
                     extract_chunks(
                       source,
                       output,
                       entry.offset,
                       entry.length,
                       context,
                       entry.name
                     ) do
                {:ok, :crypto.hash_final(context) == entry.sha256}
              end
            after
              :file.close(output)
            end

          case result do
            {:ok, true} ->
              case File.rename(temp, destination) do
                :ok -> {:ok, false}
                {:error, reason} -> bundle_io_error("could not publish extracted section", reason)
              end

            {:ok, false} ->
              {:ok, true}

            {:error, %Error{} = error} ->
              {:error, error}
          end

        {:error, reason} ->
          bundle_io_error("could not create extracted section", reason)
      end
    after
      File.rm(temp)
    end
  end

  defp extract_chunks(_source, _output, _offset, 0, context, _name), do: {:ok, context}

  defp extract_chunks(source, output, offset, remaining, context, name) do
    length = min(remaining, @copy_chunk_bytes)

    case :file.pread(source, offset, length) do
      {:ok, bytes} when byte_size(bytes) == length ->
        with :ok <- :file.write(output, bytes) do
          extract_chunks(
            source,
            output,
            offset + length,
            remaining - length,
            :crypto.hash_update(context, bytes),
            name
          )
        else
          {:error, reason} -> bundle_io_error("could not write extracted section #{name}", reason)
        end

      {:ok, _bytes} ->
        bundle_io_error("short read while extracting section #{name}", :short_read)

      :eof ->
        bundle_io_error("unexpected EOF while extracting section #{name}", :eof)

      {:error, reason} ->
        bundle_io_error("could not read bundle section #{name}", reason)
    end
  end

  defp persist_bundle(%ODB{provider: provider, hash: hash}, context, force?) do
    with {:ok, manifest} <- current_manifest(provider),
         :ok <- validate_snapshot_manifest(manifest, hash),
         {:ok, metadata} <- snapshot_metadata(context, manifest),
         {:ok, pairs} <- snapshot_pairs(manifest, context.destination),
         {:ok, toc} <- existing_bundle(context.path),
         {:ok, changed?} <- snapshot_changed?(toc, pairs, metadata, force?),
         :ok <- maybe_write_snapshot(context, manifest, metadata, pairs, toc, changed?) do
      :ok
    end
  end

  defp current_manifest(provider) do
    case GenServer.call(provider, :packfetch_manifest, :infinity) do
      {:ok, %PackManifest{} = manifest} ->
        {:ok, manifest}

      {:error, reason} ->
        bundle_write_error("current PackFetch manifest is unavailable", reason)

      other ->
        bundle_write_error("current PackFetch manifest is invalid", other)
    end
  catch
    :exit, reason ->
      {:error,
       Error.new(:provider_down, "PackFetch provider stopped before bundle publication",
         retryable: true,
         operation: :packfetch_bundle_write,
         details: %{reason: sanitize_reason(reason)}
       )}
  end

  # Native hydration already rejects non-empty loose; this is a belt-and-braces invariant.
  defp validate_snapshot_manifest(
         %PackManifest{hash: hash, generation: generation, packs: packs, loose: []},
         hash
       )
       when is_binary(generation) and is_list(packs) do
    if String.valid?(generation) do
      :ok
    else
      bundle_write_error("PackFetch manifest generation is not valid UTF-8", :invalid_generation)
    end
  end

  defp validate_snapshot_manifest(_manifest, _hash) do
    bundle_write_error(
      "PackFetch manifest cannot be represented as a hydration bundle",
      :manifest
    )
  end

  defp snapshot_metadata(context, manifest) do
    source_identity =
      context.source_identity || "packfetch:generation:" <> manifest.generation

    with :ok <- validate_snapshot_source_identity(source_identity) do
      {:ok, %{"source_identity" => source_identity}}
    end
  end

  defp snapshot_pairs(%PackManifest{packs: descriptors}, destination) do
    descriptors
    |> Enum.reduce_while({:ok, []}, fn descriptor, {:ok, pairs} ->
      case snapshot_pair(descriptor, destination) do
        {:ok, pair} -> {:cont, {:ok, [pair | pairs]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.sort_by(pairs, fn pair -> pair.pack_name end)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp snapshot_pair(
         %Gitility.PackDescriptor{
           id: id,
           pack_size: pack_size,
           index_size: index_size
         },
         destination
       )
       when is_binary(id) and is_integer(pack_size) and pack_size > 0 and
              is_integer(index_size) and index_size > 0 do
    stem = "pack-#{String.downcase(id)}"
    pack_name = stem <> ".pack"
    index_name = stem <> ".idx"
    pack_path = Path.join(pack_directory(destination), pack_name)
    index_path = Path.join(pack_directory(destination), index_name)

    with :ok <- validate_snapshot_artifact(pack_path, pack_size),
         :ok <- validate_snapshot_artifact(index_path, index_size) do
      {:ok,
       %{
         pack_path: pack_path,
         pack_name: pack_name,
         pack_length: pack_size,
         index_path: index_path,
         index_name: index_name,
         index_length: index_size
       }}
    end
  end

  defp snapshot_pair(_descriptor, _destination) do
    bundle_write_error("PackFetch manifest contains an invalid pair", :invalid_descriptor)
  end

  defp validate_snapshot_artifact(path, expected_size) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: ^expected_size}} ->
        :ok

      {:ok, %{type: :regular, size: actual_size}} ->
        bundle_write_error("hydrated artifact size changed before bundle publication", %{
          path: path,
          expected_size: expected_size,
          actual_size: actual_size
        })

      {:ok, _stat} ->
        bundle_write_error("hydrated artifact is not a regular file", path)

      {:error, reason} ->
        bundle_write_error("could not inspect hydrated artifact", %{path: path, reason: reason})
    end
  end

  defp snapshot_changed?(nil, _pairs, _metadata, _force?), do: {:ok, true}
  defp snapshot_changed?(_toc, _pairs, _metadata, true), do: {:ok, true}

  defp snapshot_changed?(toc, pairs, metadata, false) do
    if toc.metadata == metadata do
      recorded = Enum.map(toc.files, &{&1.name, &1.length})

      expected =
        Enum.flat_map(pairs, fn pair ->
          [{pair.pack_name, pair.pack_length}, {pair.index_name, pair.index_length}]
        end)

      if recorded == expected do
        snapshot_hashes_changed?(toc.files, pairs)
      else
        {:ok, true}
      end
    else
      {:ok, true}
    end
  end

  defp snapshot_hashes_changed?(entries, pairs) do
    paths = Enum.flat_map(pairs, fn pair -> [pair.pack_path, pair.index_path] end)

    entries
    |> Enum.zip(paths)
    |> Enum.reduce_while({:ok, false}, fn {entry, path}, {:ok, false} ->
      case hash_file(path) do
        {:ok, hash} when hash == entry.sha256 -> {:cont, {:ok, false}}
        {:ok, _hash} -> {:halt, {:ok, true}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp hash_file(path) do
    case :file.open(String.to_charlist(path), [:read, :raw, :binary]) do
      {:ok, file} ->
        try do
          hash_file_chunks(file, :crypto.hash_init(:sha256), path)
        after
          :file.close(file)
        end

      {:error, reason} ->
        bundle_write_error("could not open hydrated artifact for hashing", %{
          path: path,
          reason: reason
        })
    end
  end

  defp hash_file_chunks(file, context, path) do
    case :file.read(file, @copy_chunk_bytes) do
      {:ok, bytes} ->
        hash_file_chunks(file, :crypto.hash_update(context, bytes), path)

      :eof ->
        {:ok, :crypto.hash_final(context)}

      {:error, reason} ->
        bundle_write_error("could not hash hydrated artifact", %{path: path, reason: reason})
    end
  end

  defp maybe_write_snapshot(_context, _manifest, _metadata, _pairs, _toc, false), do: :ok

  defp maybe_write_snapshot(context, manifest, metadata, pairs, toc, true) do
    generation = if toc, do: toc.generation + 1, else: 1
    writer_pairs = Enum.map(pairs, &{&1.pack_path, &1.index_path})

    case Writer.write(
           context.path,
           pairs: writer_pairs,
           hash_algorithm: manifest.hash,
           generation: generation,
           metadata: metadata,
           refs: []
         ) do
      {:ok, _receipt} ->
        :ok

      {:error, {:toc_too_large, size, max}} ->
        {:error,
         Error.new(
           :unsupported_operation,
           "bundle table of contents exceeds the v1 format ceiling",
           operation: :packfetch_bundle_write,
           details: %{toc_bytes: size, max_toc_bytes: max}
         )}

      {:error, reason} ->
        bundle_write_error("bundle snapshot publication failed", reason)
    end
  end

  defp validate_snapshot_source_identity(value)
       when is_binary(value) and byte_size(value) <= 65_536 do
    :ok
  end

  defp validate_snapshot_source_identity(_value) do
    bundle_write_error(
      "bundle source identity exceeds the format metadata ceiling",
      :source_identity
    )
  end

  defp pack_directory(destination), do: Path.join(destination, "objects/pack")

  defp bundle_io_error(message, reason) do
    {:error,
     Error.new(:backend_error, message,
       operation: :packfetch_bundle_extract,
       details: %{reason: reason}
     )}
  end

  defp bundle_write_error(message, reason) do
    {:error,
     Error.new(:backend_error, message,
       operation: :packfetch_bundle_write,
       details: %{reason: inspect(reason, limit: 20, printable_limit: 256)}
     )}
  end

  defp hydration_limits(nil, max_hydration_bytes) do
    {:ok, Limits.new(max_provider_bytes: max_hydration_bytes)}
  end

  defp hydration_limits(%Limits{} = limits, max_hydration_bytes) do
    NativeSupport.limits_map!(limits)
    {:ok, %{limits | max_provider_bytes: max_hydration_bytes}}
  end

  defp hydration_limits(_limits, _max_hydration_bytes) do
    NativeSupport.invalid_argument(":limits must be a Gitility.Limits struct")
  end

  defp memory_destination_key(name) do
    name
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp bundle_destination_key(path) do
    :sha256
    |> :crypto.hash(path)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp sweep_memory_leftovers(name, key) do
    if registered?(name) do
      :ok
    else
      "/dev/shm/gitility-packfetch-#{key}-*"
      |> Path.wildcard()
      |> Enum.reduce_while(:ok, fn path, :ok ->
        case File.rm_rf(path) do
          {:ok, _removed} -> {:cont, :ok}
          {:error, _reason, _file} -> {:halt, {:error, :memory_cleanup_failed}}
        end
      end)
    end
  end

  defp registered?(name) do
    is_pid(GenServer.whereis(name))
  catch
    :exit, _reason -> false
  end

  defp validate_backend({module, _arg}) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :init, 1) and
         function_exported?(module, :manifest, 1) and
         function_exported?(module, :read_ranges, 2) do
      :ok
    else
      NativeSupport.invalid_argument(
        ":backend module must implement RangeBackend init/1, manifest/1, and read_ranges/2"
      )
    end
  end

  defp validate_backend(_backend),
    do: NativeSupport.invalid_argument(":backend must be a {module, init_arg} tuple")

  defp validate_name(name) when is_atom(name), do: :ok
  defp validate_name({:global, _term}), do: :ok
  defp validate_name({:via, module, _term}) when is_atom(module), do: :ok

  defp validate_name(_name),
    do:
      NativeSupport.invalid_argument(
        ":name must be an atom, {:global, term}, or {:via, module, term}"
      )

  defp validate_hash(hash) when hash in [:sha1, :sha256], do: :ok
  defp validate_hash(_hash), do: NativeSupport.invalid_argument(":hash must be :sha1 or :sha256")
  defp validate_verify(:always), do: :ok

  defp validate_verify(_verify),
    do: NativeSupport.invalid_argument("only verify: :always is supported")

  defp validate_bundle_source_identity(_into, nil), do: :ok

  defp validate_bundle_source_identity({:bundle, _path}, value) do
    validate_bundle_source_identity_value(value)
  end

  defp validate_bundle_source_identity(_into, _value) do
    NativeSupport.invalid_argument(
      ":bundle_source_identity is only valid with into: {:bundle, path}"
    )
  end

  defp validate_bundle_source_identity_value(value)
       when is_binary(value) and byte_size(value) <= 65_536 do
    if String.valid?(value) do
      :ok
    else
      NativeSupport.invalid_argument(":bundle_source_identity must be valid UTF-8")
    end
  end

  defp validate_bundle_source_identity_value(_value) do
    NativeSupport.invalid_argument(
      ":bundle_source_identity must be valid UTF-8 within the bundle metadata ceiling"
    )
  end

  defp positive(value, _name) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive(_value, name),
    do: NativeSupport.invalid_argument(":#{name} must be a positive integer")

  defp stop_failed_start(supervisor) do
    Process.unlink(supervisor)

    try do
      Supervisor.stop(supervisor)
    catch
      :exit, _reason -> :ok
    end
  end

  defp cleanup_destination(%{cleanup?: true, path: path}) do
    File.rm_rf(path)
    :ok
  end

  defp cleanup_destination(_destination), do: :ok

  defp normalize_provider_start_error({:backend_init, reason}), do: {:error, reason}

  defp normalize_provider_start_error({:backend_init_raised, message}),
    do: {:error, {:backend_init_raised, message}}

  defp normalize_provider_start_error(%Error{} = error), do: {:error, error}

  defp normalize_provider_start_error(reason) do
    {:error,
     Error.new(:backend_error, "PackFetch provider failed to start",
       retryable: true,
       operation: :packfetch_start_link,
       details: %{reason: sanitize_reason(reason)}
     )}
  end

  defp sanitize_reason(_reason), do: :packfetch_provider_start_failed
end
