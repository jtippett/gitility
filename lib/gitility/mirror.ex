defmodule Gitility.Mirror do
  @moduledoc """
  Replicates ordinary bare mirrors through an object store.

  The intended scheduler loop is: restore when a local mirror is absent,
  fetch into the ordinary bare repository, then publish its new snapshot. A
  stored bundle is a transport artifact: restore it; do not try to open it as
  a shared filesystem repository. Replication deliberately does not provide
  shared-POSIX-filesystem reader/writer semantics.

  Publish and restore share `Gitility.Fetch`'s per-expanded-path lease. A
  contended call returns retryable `:busy` immediately. Conditional-write
  loss returns retryable `:conflict`, while matching tips return
  `:not_newer`. A transport failure during PUT can be indeterminate because
  the store may have committed before the connection failed; Gitility performs
  one HEAD reconciliation and marks an unresolved result with
  `details.indeterminate`. Re-running publish is always safe.

  The timeout bounds object-store callbacks, lock-manager interaction, staged
  section copying, and the restore deep-check loop. `Bundle.write/2`,
  `Bundle.verify/1`, repository open, and the native ref transaction run to
  completion; the deadline is checked immediately after each. Temporary
  files and restore stages are siblings of the mirror, so the final rename is
  on one filesystem. S3 publication is a single PUT and therefore has a 5 GiB
  limit.

  ## What restore verifies

  Restore verifies the container and every section sha256, associates every
  pack with its real index by the Git trailers and filename checksum, runs the
  local store's pack/index checksum scan, proves that every ref target exists
  with its recorded kind, validates supplied peels, and checks HEAD
  coherence. It does not perform a reachability walk like `git fsck`; closed
  packs are the publisher's responsibility, and the normal restore → fetch
  loop heals missing closure from an untrusted publisher.

  Gitility-owned errors, results, state, inspection, and log lines never retain
  adapter/provider terms or credentials. Req and Finch telemetry are outside
  that boundary; do not attach Finch telemetry handlers that log requests for
  the gitility pool.

  Strict publication and restore reject ref names containing a path component
  longer than 255 bytes. This keeps accepted bundles round-trippable on the
  filesystems used by gix's ref transaction.
  """

  alias Gitility.{
    Bundle,
    Error,
    Limits,
    Native,
    NativeSupport,
    ODB,
    OID,
    RefDB,
    RefName,
    RefTarget
  }

  alias Gitility.Bundle.Format
  alias Gitility.Fetch.Locks
  alias Gitility.Mirror.{Receipt, Restore}

  @default_timeout 600_000
  @maximum_timeout 86_400_000
  @maximum_generation 18_446_744_073_709_551_615
  @maximum_count 4_294_967_295
  @content_type "application/vnd.gitility.bundle"
  @format "gitility-bundle/1.0"
  @copy_chunk_bytes 8 * 1024 * 1024
  @probe_slack_bytes 16 * 1024 * 1024
  @peel_object_bytes 64 * 1024 * 1024
  @peel_total_bytes 256 * 1024 * 1024
  @adapter_grace_ms 1_000

  @type store :: {module(), term()}

  @doc "Publishes one consistent bare-mirror snapshot with a conditional write."
  @spec publish(Path.t(), store(), binary(), keyword()) ::
          {:ok, Receipt.t()} | {:ok, :not_newer} | {:error, Error.t()}
  def publish(mirror_dir, store, key, opts \\ []) do
    entered_at = System.monotonic_time(:millisecond)

    with {:ok, request} <- validate_publish(mirror_dir, store, key, opts) do
      request
      |> Map.put(:deadline, entered_at + request.timeout)
      |> publish_validated()
    end
  rescue
    _exception -> internal_failure(:publish)
  catch
    _kind, _reason -> internal_failure(:publish)
  end

  @doc "Restores an object-store bundle as an ordinary gc-safe bare repository."
  @spec restore(store(), binary(), Path.t(), keyword()) ::
          {:ok, Restore.t()} | {:error, Error.t()}
  def restore(store, key, mirror_dir, opts \\ []) do
    entered_at = System.monotonic_time(:millisecond)

    with {:ok, request} <- validate_restore(store, key, mirror_dir, opts) do
      request
      |> Map.put(:deadline, entered_at + request.timeout)
      |> restore_validated()
    end
  rescue
    _exception -> internal_failure(:restore)
  catch
    _kind, _reason -> internal_failure(:restore)
  end

  @doc false
  @spec validate_metadata(term()) :: :ok | {:error, Error.t()}
  def validate_metadata(metadata) when is_map(metadata) do
    entries = Map.to_list(metadata)

    valid =
      map_size(metadata) <= 8 and
        Enum.all?(entries, fn
          {key, value} when is_binary(key) and is_binary(value) ->
            valid_metadata_key?(key) and
              byte_size(value) <= 128 and printable_ascii?(value)

          _other ->
            false
        end) and
        Enum.reduce(entries, 0, fn {key, value}, total ->
          total + byte_size(key) + byte_size(value)
        end) <= 1024

    if valid do
      :ok
    else
      invalid(
        :mirror_metadata,
        "object metadata must use at most 8 lowercase keys and 1 KiB of printable ASCII"
      )
    end
  end

  def validate_metadata(_metadata) do
    invalid(:mirror_metadata, "object metadata must be a string-keyed map")
  end

  @doc false
  @spec validate_remote_metadata(term()) :: {:ok, map()} | {:error, Error.t()}
  def validate_remote_metadata(metadata) when is_map(metadata) do
    with true <- Map.get(metadata, "format") == @format,
         {:ok, generation} <-
           canonical_integer(Map.get(metadata, "generation"), false, @maximum_generation),
         true <- generation <= @maximum_generation,
         tips when is_binary(tips) <- Map.get(metadata, "tips_digest"),
         true <- lowercase_hex?(tips, 64),
         {:ok, ref_count} <-
           canonical_integer(Map.get(metadata, "ref_count"), true, @maximum_count),
         {:ok, file_count} <-
           canonical_integer(Map.get(metadata, "file_count"), true, @maximum_count) do
      {:ok,
       %{
         generation: generation,
         tips_digest: tips,
         ref_count: ref_count,
         file_count: file_count
       }}
    else
      _other -> {:error, foreign_object_error(:mirror_metadata)}
    end
  end

  def validate_remote_metadata(_metadata),
    do: {:error, foreign_object_error(:mirror_metadata)}

  @doc false
  @spec tips_digest([map()], binary() | nil) :: binary()
  def tips_digest(refs, head_symref) when is_list(refs) do
    ref_lines =
      Enum.map(refs, fn ref ->
        [ref.name, " ", Base.encode16(oid_bytes(ref.target), case: :lower), "\n"]
        |> IO.iodata_to_binary()
      end)

    lines =
      if is_binary(head_symref) do
        [IO.iodata_to_binary(["HEAD -> ", head_symref, "\n"]) | ref_lines]
      else
        ref_lines
      end

    :crypto.hash(:sha256, Enum.sort(lines))
    |> Base.encode16(case: :lower)
  end

  defp publish_validated(request) do
    case acquire_lease(request.expanded, request.timeout, :publish) do
      :ok ->
        try do
          do_publish(request)
        after
          release_lease(request.expanded)
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp do_publish(request) do
    tmp = publish_tmp(request.expanded)

    try do
      with :ok <- rewrite_result(sweep_publish(request.expanded), :publish),
           {:ok, state} <- init_store(request, :publish),
           {:ok, remote} <- publish_remote_head(request, state),
           :ok <- ensure_generation_available(remote.generation, :publish),
           {:ok, toc, digest} <- write_publish_bundle(request, tmp, remote.generation + 1),
           result <- maybe_publish_bundle(request, state, tmp, remote, toc, digest) do
        result
      end
    after
      _ = File.rm(tmp)
    end
  end

  defp publish_remote_head(request, state) do
    case adapter_head(request.module, state, request.key, request.deadline, :publish, :head) do
      {:ok, head} ->
        with {:ok, metadata} <- validate_publish_head(head) do
          {:ok,
           %{
             generation: metadata.generation,
             digest: metadata.tips_digest,
             etag: head.etag,
             size: head.size,
             metadata: metadata
           }}
        end

      {:error, :not_found} ->
        {:ok, %{generation: 0, digest: nil, etag: :none, size: 0, metadata: nil}}

      {:error, reason} ->
        adapter_error(reason, :head, :publish)

      :deadline_timeout ->
        timeout_error(:publish, :head, %{indeterminate: false})
    end
  end

  defp validate_publish_head(head) do
    case validate_remote_metadata(head.metadata) do
      {:ok, metadata} -> {:ok, metadata}
      {:error, %Error{} = error} -> {:error, %{error | operation: :publish}}
    end
  end

  defp ensure_generation_available(@maximum_generation, operation) do
    {:error,
     Error.new(
       :unsupported_operation,
       "generation space exhausted for key",
       operation: operation
     )}
  end

  defp ensure_generation_available(_generation, _operation), do: :ok

  defp write_publish_bundle(request, tmp, generation) do
    opts = [
      source: {:repository, request.expanded},
      generation: generation,
      strict_refs: true,
      mode: 0o600,
      source_identity: request.source_identity,
      publisher: publisher_identity()
    ]

    opts = maybe_keyword(opts, :created_at, request.created_at)
    opts = maybe_keyword(opts, :git_executable, request.git_executable)

    with :ok <-
           deadline_check(request.deadline, :publish, :bundle_write, %{
             indeterminate: false
           }),
         {:ok, receipt} <- rewrite_result(Bundle.write(tmp, opts), :publish),
         true <- receipt.warnings == [] || strict_warning_error(),
         :ok <-
           deadline_check(request.deadline, :publish, :bundle_write, %{
             indeterminate: false
           }),
         {:ok, toc} <- rewrite_result(Format.parse(tmp), :publish),
         :ok <-
           deadline_check(request.deadline, :publish, :bundle_parse, %{
             indeterminate: false
           }) do
      {:ok, toc, tips_digest(toc.refs, toc.metadata["head_symref"])}
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp strict_warning_error do
    {:error,
     Error.new(:internal_error, "strict bundle snapshot returned warnings", operation: :publish)}
  end

  defp maybe_publish_bundle(request, state, tmp, remote, toc, digest) do
    if digest == remote.digest do
      {:ok, :not_newer}
    else
      generation = toc.generation

      metadata = %{
        "generation" => Integer.to_string(generation),
        "tips_digest" => digest,
        "format" => @format,
        "ref_count" => Integer.to_string(length(toc.refs)),
        "file_count" => Integer.to_string(length(toc.files))
      }

      with :ok <- rewrite_result(validate_metadata(metadata), :publish),
           :ok <- deadline_check(request.deadline, :publish, :put, %{indeterminate: false}) do
        local = %{
          generation: generation,
          bytes: toc.file_size,
          digest: digest,
          ref_count: length(toc.refs),
          file_count: length(toc.files)
        }

        put_opts = [
          if_match: remote.etag,
          metadata: metadata,
          content_type: @content_type
        ]

        case adapter_put(
               request.module,
               state,
               tmp,
               request.key,
               put_opts,
               request.deadline,
               :publish,
               :put
             ) do
          {:ok, %{etag: etag}} ->
            {:ok, publish_receipt(local, etag)}

          {:error, :precondition_failed} ->
            reconcile_precondition(request, state, digest)

          {:error, {:transport, _reason} = transport} ->
            reconcile_transport(request, state, remote.etag, local, transport)

          {:error, reason} ->
            adapter_error(reason, :put, :publish)

          :deadline_timeout ->
            timeout_error(:publish, :put, %{indeterminate: true})

          :deadline_expired_before_call ->
            timeout_error(:publish, :put, %{indeterminate: false})
        end
      end
    end
  end

  defp reconcile_precondition(request, state, digest) do
    case adapter_head(
           request.module,
           state,
           request.key,
           request.deadline,
           :publish,
           :reconcile_head
         ) do
      {:ok, head} ->
        with {:ok, metadata} <- validate_publish_head(head) do
          if metadata.tips_digest == digest do
            {:ok, :not_newer}
          else
            conflict_error()
          end
        end

      {:error, :not_found} ->
        conflict_error()

      {:error, reason} ->
        adapter_error(reason, :head, :publish)

      :deadline_timeout ->
        timeout_error(:publish, :reconcile_head)
    end
  end

  defp reconcile_transport(request, state, if_match, local, transport) do
    case adapter_head(
           request.module,
           state,
           request.key,
           request.deadline,
           :publish,
           :reconcile_head
         ) do
      {:ok, head} ->
        case validate_publish_head(head) do
          {:ok, metadata} ->
            cond do
              metadata.tips_digest == local.digest and
                metadata.generation == local.generation and
                  (if_match == :none or head.etag != if_match) ->
                {:ok,
                 %Receipt{
                   generation: metadata.generation,
                   etag: head.etag,
                   bytes: head.size,
                   tips_digest: metadata.tips_digest,
                   ref_count: metadata.ref_count,
                   file_count: metadata.file_count
                 }}

              if_match != :none and head.etag == if_match ->
                transport_backend_error(transport)

              true ->
                conflict_error()
            end

          {:error, %Error{} = error} ->
            {:error, error}
        end

      {:error, :not_found} when if_match == :none ->
        transport_backend_error(transport)

      {:error, :not_found} ->
        conflict_error()

      {:error, _reason} ->
        indeterminate_error()

      :deadline_timeout ->
        timeout_error(:publish, :reconcile_head, %{indeterminate: true})
    end
  end

  defp publish_receipt(local, etag) do
    %Receipt{
      generation: local.generation,
      etag: etag,
      bytes: local.bytes,
      tips_digest: local.digest,
      ref_count: local.ref_count,
      file_count: local.file_count
    }
  end

  defp conflict_error do
    {:error,
     Error.new(:conflict, "object at key changed during publish",
       operation: :publish,
       retryable: true
     )}
  end

  defp transport_backend_error({:transport, reason}) do
    {:error,
     Error.new(:backend_error, "object-store PUT did not commit",
       operation: :publish,
       retryable: true,
       cause: {:transport, reason}
     )}
  end

  defp indeterminate_error do
    {:error,
     Error.new(:backend_error, "object-store PUT outcome is indeterminate",
       operation: :publish,
       retryable: true,
       cause: {:adapter, :indeterminate},
       details: %{indeterminate: true}
     )}
  end

  defp restore_validated(request) do
    case acquire_lease(request.expanded, request.timeout, :restore) do
      :ok ->
        try do
          with {:ok, created} <- create_parent_chain(Path.dirname(request.expanded)) do
            result = do_restore(request)
            maybe_cleanup_created_parents(result, created)
          end
        after
          release_lease(request.expanded)
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp do_restore(request) do
    tmp = restore_tmp(request.expanded)

    try do
      with :ok <- sweep_restore(request.expanded),
           {:ok, state} <- init_store(request, :restore),
           {:ok, downloaded} <- download_bundle(request, state, tmp),
           :ok <- verify_download(tmp),
           :ok <- deadline_check(request.deadline, :restore, :bundle_verify),
           {:ok, toc} <- parse_download(tmp),
           :ok <- deadline_check(request.deadline, :restore, :bundle_parse),
           :ok <- supported_restore_hash(toc.hash_algorithm),
           digest = tips_digest(toc.refs, toc.metadata["head_symref"]),
           :ok <- validate_download_metadata(downloaded.metadata, toc, digest),
           :ok <- restore_from_toc(request, tmp, toc),
           {:ok, result} <- restore_result(toc, downloaded, digest) do
        {:ok, result}
      end
    after
      _ = File.rm(tmp)
      _ = File.rm(tmp <> ".part")
    end
  end

  defp download_bundle(request, state, tmp) do
    case adapter_get(
           request.module,
           state,
           request.key,
           tmp,
           request.deadline,
           :restore,
           :get
         ) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> adapter_error(reason, :get, :restore)
      :deadline_timeout -> timeout_error(:restore, :get)
    end
  end

  defp verify_download(path) do
    case Bundle.verify(path) do
      :ok -> :ok
      {:error, %Error{} = error} -> map_initial_bundle_error(error)
    end
  end

  defp parse_download(path) do
    case Format.parse(path) do
      {:ok, toc} -> {:ok, toc}
      {:error, %Error{} = error} -> map_initial_bundle_error(error)
    end
  end

  defp map_initial_bundle_error(%Error{code: code} = error)
       when code in [:unsupported_operation, :backend_error] do
    {:error, %{error | operation: :restore}}
  end

  defp map_initial_bundle_error(%Error{} = error) do
    malformed_bundle(error.code)
  end

  defp supported_restore_hash(:sha1), do: :ok

  defp supported_restore_hash(_hash) do
    {:error,
     Error.new(:unsupported_hash, "mirror restore supports SHA-1 bundles only",
       operation: :restore
     )}
  end

  defp validate_download_metadata(metadata, toc, digest) do
    generation_matches =
      not Map.has_key?(metadata, "generation") or
        metadata["generation"] == Integer.to_string(toc.generation)

    digest_matches =
      not Map.has_key?(metadata, "tips_digest") or metadata["tips_digest"] == digest

    if generation_matches and digest_matches do
      :ok
    else
      malformed_bundle(:metadata_mismatch)
    end
  end

  defp restore_from_toc(request, bundle, toc) do
    stage = restore_stage(request.expanded)

    result =
      with :ok <- init_restore_stage(stage),
           :ok <- deadline_check(request.deadline, :restore, :init_bare),
           :ok <- extract_sections(bundle, stage, toc.files, request.deadline),
           :ok <- write_restored_refs(stage, toc),
           :ok <- deadline_check(request.deadline, :restore, :write_refs),
           :ok <- verify_pack_pairs(stage, toc, request.deadline),
           {:ok, repository} <- open_deep_check_repository(stage),
           :ok <- deadline_check(request.deadline, :restore, :repository_open),
           :ok <- force_store_integrity(repository, toc, request.deadline),
           :ok <- verify_restored_refs(repository, toc, request.deadline),
           :ok <- deadline_check(request.deadline, :restore, :commit),
           :ok <- commit_restore_stage(stage, request.expanded) do
        :ok
      end

    case result do
      :ok -> :ok
      {:error, %Error{} = error} -> cleanup_stage(stage, error)
    end
  end

  defp init_restore_stage(stage) do
    case Gitility.Repository.init_bare(stage) do
      :ok -> :ok
      {:error, %Error{} = error} -> {:error, %{error | operation: :restore}}
    end
  end

  defp extract_sections(bundle, stage, files, deadline) do
    pack_dir = Path.join([stage, "objects", "pack"])

    with :ok <- mkdir_pack_directory(pack_dir),
         {:ok, input} <- open_raw(bundle, [:read, :binary, :raw], "could not open bundle") do
      try do
        Enum.reduce_while(files, :ok, fn entry, :ok ->
          case extract_section(input, pack_dir, entry, deadline) do
            :ok -> {:cont, :ok}
            {:error, %Error{} = error} -> {:halt, {:error, error}}
          end
        end)
      after
        :file.close(input)
      end
    end
  end

  defp mkdir_pack_directory(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> restore_io_error("could not create restored pack directory", reason)
    end
  end

  defp extract_section(input, pack_dir, entry, deadline) do
    destination = Path.join(pack_dir, Path.basename(entry.name))
    temp = destination <> ".tmp"

    try do
      with :ok <- deadline_check(deadline, :restore, :copy_sections),
           {:ok, output} <-
             open_raw(temp, [:write, :binary, :raw, :exclusive], "could not create pack temp"),
           :ok <- chmod_file(temp, 0o600) do
        result =
          try do
            copy_section(input, output, entry.offset, entry.length, deadline)
          after
            :file.close(output)
          end

        with :ok <- result,
             :ok <- rename_file(temp, destination, "could not install restored pack file") do
          :ok
        end
      end
    after
      _ = File.rm(temp)
    end
  end

  defp copy_section(_input, _output, _offset, 0, _deadline), do: :ok

  defp copy_section(input, output, offset, bytes_left, deadline) do
    with :ok <- deadline_check(deadline, :restore, :copy_sections) do
      count = min(bytes_left, @copy_chunk_bytes)

      case :file.pread(input, offset, count) do
        {:ok, bytes} when byte_size(bytes) == count ->
          case :file.write(output, bytes) do
            :ok -> copy_section(input, output, offset + count, bytes_left - count, deadline)
            {:error, reason} -> restore_io_error("could not write restored pack section", reason)
          end

        {:ok, _short} ->
          malformed_bundle(:short_section)

        :eof ->
          malformed_bundle(:short_section)

        {:error, reason} ->
          restore_io_error("could not read bundle section", reason)
      end
    end
  end

  defp write_restored_refs(stage, toc) do
    {head_rows, rows} = Enum.split_with(toc.refs, &(&1.name == "HEAD"))
    head_symref = toc.metadata["head_symref"]

    with :ok <- validate_restore_ref_names(toc.refs, head_symref),
         {:ok, head} <- restored_head(head_rows, head_symref) do
      native_rows = Enum.map(rows, &{&1.name, &1.target})

      case Native.repo_write_refs(stage, native_rows, head) do
        {:ok, _count} ->
          :ok

        {:error, error} ->
          error
          |> NativeSupport.nif_error(:mirror_restore_refs)
          |> map_later_bundle_error()

        _bad_return ->
          {:error,
           Error.new(:internal_error, "native ref writer returned an invalid result",
             operation: :restore
           )}
      end
    end
  rescue
    _exception ->
      {:error, Error.new(:internal_error, "native ref writer failed safely", operation: :restore)}
  catch
    _kind, _reason ->
      {:error, Error.new(:internal_error, "native ref writer failed safely", operation: :restore)}
  end

  defp restored_head([head], head_symref), do: {:ok, {head.target, head_symref}}
  defp restored_head([], head_symref) when is_binary(head_symref), do: {:ok, {nil, head_symref}}
  defp restored_head([], nil), do: malformed_bundle(:missing_head)
  defp restored_head(_heads, _head_symref), do: malformed_bundle(:malformed_ref)

  defp validate_restore_ref_names(refs, head_symref) do
    with :ok <- validate_restore_rows(refs),
         :ok <- validate_restore_head_symref(head_symref) do
      :ok
    end
  end

  defp validate_restore_rows(refs) do
    Enum.reduce_while(refs, :ok, fn row, :ok ->
      case RefName.validate(row.name) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, malformed_bundle(:malformed_ref, %{reason: reason})}
      end
    end)
  end

  defp validate_restore_head_symref(nil), do: :ok

  defp validate_restore_head_symref(head_symref) do
    if RefName.valid_branch?(head_symref) do
      :ok
    else
      reason =
        case RefName.validate(head_symref) do
          :ok -> :not_a_branch
          {:error, ref_reason} -> ref_reason
        end

      malformed_bundle(:malformed_ref, %{reason: reason})
    end
  end

  defp verify_pack_pairs(stage, toc, deadline) do
    toc.files
    |> Enum.chunk_every(2)
    |> Enum.reduce_while(:ok, fn
      [%{kind: :pack} = pack, %{kind: :idx} = index], :ok ->
        case verify_pack_pair(stage, pack, index, toc.hash_algorithm, deadline) do
          :ok -> {:cont, :ok}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end

      _malformed, :ok ->
        {:halt, malformed_bundle(:pack_index_mismatch)}
    end)
  end

  defp verify_pack_pair(stage, pack, index, hash, deadline) do
    digest_size = OID.digest_size(hash)
    pack_path = Path.join([stage, "objects", "pack", pack.name])
    index_path = Path.join([stage, "objects", "pack", index.name])

    with :ok <- deadline_check(deadline, :restore, :deep_check),
         {:ok, pack_checksum} <- read_tail(pack_path, digest_size),
         {:ok, index_tail} <- read_tail(index_path, digest_size * 2),
         <<index_pack_checksum::binary-size(^digest_size),
           _index_checksum::binary-size(^digest_size)>> <-
           index_tail,
         {:ok, filename_checksum} <- checksum_from_pack_name(pack.name, digest_size),
         true <-
           (pack_checksum == index_pack_checksum and pack_checksum == filename_checksum) ||
             malformed_bundle(:pack_index_mismatch) do
      :ok
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> malformed_bundle(:pack_index_mismatch)
    end
  end

  defp checksum_from_pack_name(name, digest_size) do
    hex_size = digest_size * 2

    case name do
      <<"pack-", hex::binary-size(^hex_size), ".pack">> ->
        case Base.decode16(hex, case: :lower) do
          {:ok, checksum} -> {:ok, checksum}
          :error -> malformed_bundle(:pack_index_mismatch)
        end

      _other ->
        malformed_bundle(:pack_index_mismatch)
    end
  end

  defp read_tail(path, count) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.size >= count || malformed_bundle(:pack_index_mismatch),
         {:ok, file} <- open_raw(path, [:read, :binary, :raw], "could not open pack artifact") do
      try do
        case :file.pread(file, stat.size - count, count) do
          {:ok, bytes} when byte_size(bytes) == count -> {:ok, bytes}
          {:ok, _short} -> malformed_bundle(:pack_index_mismatch)
          :eof -> malformed_bundle(:pack_index_mismatch)
          {:error, reason} -> restore_io_error("could not read pack artifact trailer", reason)
        end
      after
        :file.close(file)
      end
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> restore_io_error("could not inspect pack artifact", reason)
    end
  end

  defp open_deep_check_repository(stage) do
    case Gitility.Repository.open(stage,
           require_bare: true,
           verify_pack_checksums: true
         ) do
      {:ok, repository} -> {:ok, repository}
      {:error, %Error{} = error} -> map_later_bundle_error(error)
    end
  rescue
    _exception ->
      {:error,
       Error.new(:internal_error, "deep-check repository open failed safely", operation: :restore)}
  end

  defp force_store_integrity(repository, toc, deadline) do
    with {:ok, time_left} <- time_left(deadline, :restore, :deep_check) do
      allowance = toc.file_size + @probe_slack_bytes

      limits = %Limits{
        timeout_ms: time_left,
        max_total_object_bytes: allowance,
        max_provider_bytes: allowance
      }

      sentinel = %OID{
        algorithm: toc.hash_algorithm,
        bytes: :binary.copy(<<0>>, OID.digest_size(toc.hash_algorithm))
      }

      case ODB.header(repository.odb, sentinel, limits: limits) do
        {:ok, _header} ->
          :ok

        {:error, %Error{code: :missing_object}} ->
          :ok

        {:error, %Error{code: :budget_exceeded}} ->
          {:error,
           Error.new(:internal_error, "restore integrity probe exhausted its own allowance",
             operation: :restore
           )}

        {:error, %Error{} = error} ->
          map_later_bundle_error(error)
      end
    end
  end

  defp verify_restored_refs(repository, toc, deadline) do
    Enum.reduce_while(toc.refs, :ok, fn row, :ok ->
      case verify_restored_ref(repository, toc.hash_algorithm, row, deadline) do
        :ok -> {:cont, :ok}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp verify_restored_ref(repository, hash, row, deadline) do
    target = %OID{algorithm: hash, bytes: row.target}

    with {:ok, resolve_left} <- time_left(deadline, :restore, :deep_check),
         {:ok, %RefTarget{oid: ^target}} <-
           RefDB.resolve(repository.refs, row.name, limits: %Limits{timeout_ms: resolve_left}),
         {:ok, header_left} <- time_left(deadline, :restore, :deep_check),
         {:ok, header} <-
           ODB.header(repository.odb, target, limits: %Limits{timeout_ms: header_left}),
         :ok <- verify_ref_kind(row, header.type),
         :ok <- verify_ref_peel(repository, hash, row, target, deadline) do
      :ok
    else
      {:ok, :not_found} ->
        malformed_bundle(:dangling_ref)

      {:ok, %RefTarget{}} ->
        malformed_bundle(:dangling_ref)

      {:error, %Error{code: code} = error}
      when code in [:timeout, :backend_error, :internal_error] ->
        {:error, %{error | operation: :restore}}

      {:error, %Error{code: :missing_object}} ->
        malformed_bundle(:dangling_ref)

      {:error, %Error{} = error} ->
        map_later_bundle_error(error)

      _other ->
        malformed_bundle(:dangling_ref)
    end
  end

  defp verify_ref_kind(row, actual) do
    branch_or_head = row.name == "HEAD" or branch_ref?(row.name)

    cond do
      actual != row.kind -> malformed_bundle(:kind_mismatch)
      branch_or_head and row.kind != :commit -> malformed_bundle(:kind_mismatch)
      true -> :ok
    end
  end

  defp branch_ref?(<<"refs/heads/", _suffix::binary>>), do: true
  defp branch_ref?(_name), do: false

  defp verify_ref_peel(_repository, _hash, %{peeled: nil}, _target, _deadline), do: :ok

  defp verify_ref_peel(repository, hash, row, target, deadline) do
    if row.kind != :tag do
      malformed_bundle(:peel_mismatch)
    else
      with {:ok, time_left} <- time_left(deadline, :restore, :deep_check) do
        limits = %Limits{
          timeout_ms: time_left,
          max_object_bytes: @peel_object_bytes,
          max_total_object_bytes: @peel_total_bytes
        }

        expected = %OID{algorithm: hash, bytes: row.peeled}

        case Gitility.peel(repository, target, limits: limits) do
          {:ok, ^expected} ->
            verify_peeled_commit(repository, expected, deadline)

          {:ok, _other} ->
            malformed_bundle(:peel_mismatch)

          {:error, %Error{code: code} = error}
          when code in [:timeout, :backend_error, :internal_error] ->
            {:error, %{error | operation: :restore}}

          {:error, %Error{} = error} ->
            malformed_bundle(:peel_mismatch, %{peel_error: error.code})
        end
      end
    end
  end

  defp verify_peeled_commit(repository, oid, deadline) do
    with {:ok, time_left} <- time_left(deadline, :restore, :deep_check) do
      case ODB.header(repository.odb, oid, limits: %Limits{timeout_ms: time_left}) do
        {:ok, %{type: :commit}} ->
          :ok

        {:ok, _header} ->
          malformed_bundle(:peel_mismatch)

        {:error, %Error{code: code} = error}
        when code in [:timeout, :backend_error, :internal_error] ->
          {:error, %{error | operation: :restore}}

        {:error, %Error{} = error} ->
          malformed_bundle(:peel_mismatch, %{peel_error: error.code})
      end
    end
  end

  defp map_later_bundle_error(%Error{code: code} = error)
       when code in [:timeout, :backend_error, :internal_error] do
    {:error, %{error | operation: :restore}}
  end

  defp map_later_bundle_error(%Error{code: code})
       when code in [:invalid_argument, :malformed_ref] do
    malformed_bundle(:malformed_ref)
  end

  defp map_later_bundle_error(%Error{code: :malformed_bundle} = error), do: {:error, error}
  defp map_later_bundle_error(%Error{code: code}), do: malformed_bundle(code)

  defp commit_restore_stage(stage, expanded) do
    case File.rename(stage, expanded) do
      :ok ->
        :ok

      {:error, reason} when reason in [:eexist, :enotempty, :enotdir, :eisdir] ->
        {:error,
         Error.new(:invalid_argument, "restore destination changed before commit",
           operation: :restore,
           details: %{reason: reason}
         )}

      {:error, reason} ->
        restore_io_error("could not commit restored repository", reason)
    end
  end

  defp restore_result(toc, downloaded, digest) do
    {:ok,
     %Restore{
       generation: toc.generation,
       etag: downloaded.etag,
       bytes: downloaded.bytes,
       tips_digest: digest,
       ref_count: length(toc.refs),
       file_count: length(toc.files)
     }}
  end

  defp cleanup_stage(stage, error) do
    case File.rm_rf(stage) do
      {:ok, _removed} ->
        {:error, error}

      {:error, _reason, _path} ->
        {:error, %{error | details: Map.put(error.details, :cleanup, :failed)}}
    end
  rescue
    _exception -> {:error, %{error | details: Map.put(error.details, :cleanup, :failed)}}
  end

  defp init_store(request, operation) do
    case adapter_init(request.module, request.init_arg, request.deadline, operation) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> adapter_error(reason, :init, operation)
      :deadline_timeout -> timeout_error(operation, :init, pre_put_timeout_details(operation))
    end
  end

  defp pre_put_timeout_details(:publish), do: %{indeterminate: false}
  defp pre_put_timeout_details(_operation), do: %{}

  defp adapter_init(module, init_arg, deadline, operation) do
    with {:ok, time_left} <- raw_time_left(deadline) do
      case run_adapter(module, :init, [init_arg], time_left) do
        {:ok, {:ok, state}} -> {:ok, state}
        {:ok, {:error, reason}} -> {:error, sanitize_init_reason(reason)}
        {:ok, _bad_return} -> {:error, {:adapter, :bad_return}}
        :adapter_exception -> {:error, {:adapter, :exception}}
        :deadline_timeout -> :deadline_timeout
      end
    else
      :expired -> deadline_marker(operation)
    end
  end

  defp adapter_head(module, state, key, deadline, operation, _phase) do
    with {:ok, time_left} <- raw_time_left(deadline) do
      case run_adapter(module, :head, [state, key, [timeout: time_left]], time_left) do
        {:ok, {:ok, head}} -> validate_head_return(head)
        {:ok, {:error, reason}} -> validate_adapter_reason(reason, :head)
        {:ok, _bad_return} -> {:error, {:adapter, :bad_return}}
        :adapter_exception -> {:error, {:adapter, :exception}}
        :deadline_timeout -> :deadline_timeout
      end
    else
      :expired -> deadline_marker(operation)
    end
  end

  defp adapter_get(module, state, key, dest, deadline, operation, _phase) do
    with {:ok, time_left} <- raw_time_left(deadline) do
      case run_adapter(module, :get, [state, key, dest, [timeout: time_left]], time_left) do
        {:ok, {:ok, result}} -> validate_get_return(result)
        {:ok, {:error, reason}} -> validate_adapter_reason(reason, :get)
        {:ok, _bad_return} -> {:error, {:adapter, :bad_return}}
        :adapter_exception -> {:error, {:adapter, :exception}}
        :deadline_timeout -> :deadline_timeout
      end
    else
      :expired -> deadline_marker(operation)
    end
  end

  defp adapter_put(module, state, source, key, opts, deadline, operation, _phase) do
    with {:ok, time_left} <- raw_time_left(deadline) do
      callback_opts = Keyword.put(opts, :timeout, time_left)

      case run_adapter(module, :put, [state, source, key, callback_opts], time_left) do
        {:ok, {:ok, result}} -> validate_put_return(result)
        {:ok, {:error, reason}} -> validate_adapter_reason(reason, :put)
        {:ok, _bad_return} -> {:error, {:adapter, :bad_return}}
        :adapter_exception -> {:error, {:adapter, :exception}}
        :deadline_timeout -> :deadline_timeout
      end
    else
      :expired -> deadline_expired_before_call(operation)
    end
  end

  defp run_adapter(module, function, args, timeout) do
    task =
      Task.async(fn ->
        try do
          {:adapter_return, apply(module, function, args)}
        rescue
          _exception -> :adapter_exception
        catch
          _kind, _reason -> :adapter_exception
        end
      end)

    result = Task.yield(task, timeout + @adapter_grace_ms) || Task.shutdown(task, :brutal_kill)

    case result do
      {:ok, {:adapter_return, value}} -> {:ok, value}
      {:ok, :adapter_exception} -> :adapter_exception
      {:exit, _reason} -> :adapter_exception
      nil -> :deadline_timeout
      _other -> :adapter_exception
    end
  end

  defp validate_head_return(%{etag: etag, size: size, metadata: metadata} = head)
       when is_binary(etag) and byte_size(etag) > 0 and is_integer(size) and size >= 0 do
    if string_map?(metadata), do: {:ok, head}, else: {:error, {:adapter, :bad_return}}
  end

  defp validate_head_return(_head), do: {:error, {:adapter, :bad_return}}

  defp validate_get_return(%{etag: etag, bytes: bytes, metadata: metadata} = result)
       when is_binary(etag) and byte_size(etag) > 0 and is_integer(bytes) and bytes >= 0 do
    if string_map?(metadata), do: {:ok, result}, else: {:error, {:adapter, :bad_return}}
  end

  defp validate_get_return(_result), do: {:error, {:adapter, :bad_return}}

  defp validate_put_return(%{etag: etag} = result)
       when is_binary(etag) and byte_size(etag) > 0,
       do: {:ok, result}

  defp validate_put_return(_result), do: {:error, {:adapter, :bad_return}}

  defp validate_adapter_reason(:not_found, phase) when phase in [:head, :get],
    do: {:error, :not_found}

  defp validate_adapter_reason(:precondition_failed, :put),
    do: {:error, :precondition_failed}

  defp validate_adapter_reason({:http, status, code}, _phase)
       when is_integer(status) and status in 100..599 and (is_nil(code) or is_binary(code)) do
    {:error, {:http, status, sanitize_provider_code(code)}}
  end

  defp validate_adapter_reason(reason, _phase) do
    if valid_general_reason?(reason) do
      {:error, reason}
    else
      {:error, {:adapter, :bad_return}}
    end
  end

  defp sanitize_init_reason({:http, status, code})
       when is_integer(status) and status in 100..599 and (is_nil(code) or is_binary(code)) do
    {:http, status, sanitize_provider_code(code)}
  end

  defp sanitize_init_reason(reason) do
    cond do
      reason == :dotted_virtual_host_bucket -> {:init, :dotted_virtual_host_bucket}
      valid_general_reason?(reason) -> reason
      true -> {:init, :failed}
    end
  end

  defp sanitize_provider_code(code) when is_binary(code) and byte_size(code) >= 40,
    do: "Redacted"

  defp sanitize_provider_code(code), do: code

  defp valid_general_reason?({:unsupported_operation, message}), do: is_binary(message)
  defp valid_general_reason?({:invalid_key, message}), do: is_binary(message)
  defp valid_general_reason?({:transport, reason}), do: is_atom(reason)

  defp valid_general_reason?({:http, status, code}),
    do: is_integer(status) and status in 100..599 and (is_nil(code) or is_binary(code))

  defp valid_general_reason?({:adapter, reason}), do: is_atom(reason)
  defp valid_general_reason?(_reason), do: false

  defp adapter_error({:unsupported_operation, message}, _phase, operation) do
    {:error, Error.new(:unsupported_operation, message, operation: operation)}
  end

  defp adapter_error({:init, :failed}, :init, operation) do
    {:error,
     Error.new(:invalid_argument, "object store init failed",
       operation: operation,
       cause: {:adapter, :init}
     )}
  end

  defp adapter_error({:init, :dotted_virtual_host_bucket}, :init, operation) do
    {:error,
     Error.new(
       :invalid_argument,
       "use addressing: :path",
       operation: operation,
       cause: {:adapter, :init}
     )}
  end

  defp adapter_error({:invalid_key, _message}, _phase, operation) do
    invalid(operation, "object store rejected the key")
  end

  defp adapter_error({:transport, reason}, _phase, operation) do
    {:error,
     Error.new(:backend_error, "object-store transport failed",
       operation: operation,
       retryable: true,
       cause: {:transport, reason}
     )}
  end

  defp adapter_error({:http, status, code}, _phase, operation)
       when status in [408, 429] or status >= 500 do
    {:error,
     Error.new(:backend_error, "object store returned a retryable HTTP error",
       operation: operation,
       retryable: true,
       cause: {:http, status, code}
     )}
  end

  defp adapter_error({:http, status, code}, _phase, operation) when status in [401, 403] do
    {:error,
     Error.new(:authentication_failed, "object-store authentication failed",
       operation: operation,
       cause: {:http, status, code}
     )}
  end

  defp adapter_error({:http, status, code}, _phase, operation) do
    {:error,
     Error.new(:backend_error, "object store returned an HTTP error",
       operation: operation,
       cause: {:http, status, code}
     )}
  end

  defp adapter_error({:adapter, :credentials_unavailable}, _phase, operation) do
    {:error,
     Error.new(:credentials_unavailable, "credential provider was unavailable",
       operation: operation
     )}
  end

  defp adapter_error({:adapter, reason}, _phase, operation) do
    {:error,
     Error.new(:backend_error, "object-store adapter failed",
       operation: operation,
       cause: {:adapter, reason}
     )}
  end

  defp adapter_error(:not_found, :get, operation) do
    {:error, Error.new(:not_found, "no object at key", operation: operation)}
  end

  defp adapter_error(_reason, :init, operation) do
    {:error,
     Error.new(:invalid_argument, "object store init failed",
       operation: operation,
       cause: {:adapter, :init}
     )}
  end

  defp adapter_error(_reason, _phase, operation) do
    {:error,
     Error.new(:backend_error, "object-store adapter returned an invalid result",
       operation: operation,
       cause: {:adapter, :bad_return}
     )}
  end

  defp validate_publish(mirror_dir, store, key, opts) do
    with {:ok, expanded} <- validate_publish_path(mirror_dir),
         {:ok, module, init_arg} <- validate_store(store, :publish),
         :ok <- validate_key(key, :publish),
         {:ok, options} <- validate_publish_options(opts, expanded) do
      {:ok,
       Map.merge(options, %{
         expanded: expanded,
         module: module,
         init_arg: init_arg,
         key: key
       })}
    end
  end

  defp validate_restore(store, key, mirror_dir, opts) do
    with {:ok, expanded, existed} <- validate_restore_path(mirror_dir),
         {:ok, module, init_arg} <- validate_store(store, :restore),
         :ok <- validate_key(key, :restore),
         {:ok, options} <- validate_restore_options(opts) do
      {:ok,
       Map.merge(options, %{
         expanded: expanded,
         destination_existed: existed,
         module: module,
         init_arg: init_arg,
         key: key
       })}
    end
  end

  defp validate_publish_path(path) do
    with :ok <- validate_path_binary(path, :publish),
         expanded = Path.expand(path),
         {:ok, %{type: :directory}} <- File.stat(expanded) do
      {:ok, expanded}
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> invalid(:publish, "mirror directory must be an existing directory")
    end
  end

  defp validate_restore_path(path) do
    with :ok <- validate_path_binary(path, :restore) do
      expanded = Path.expand(path)

      case File.lstat(expanded) do
        {:error, :enoent} ->
          {:ok, expanded, false}

        {:ok, %{type: :directory}} ->
          case File.ls(expanded) do
            {:ok, []} ->
              {:ok, expanded, true}

            _other ->
              invalid(:restore, "restore destination must be absent or an empty directory")
          end

        _other ->
          invalid(:restore, "restore destination must be absent or an empty directory")
      end
    end
  end

  defp validate_path_binary(path, operation)
       when is_binary(path) and byte_size(path) > 0 do
    if String.valid?(path) and not String.contains?(path, <<0>>) do
      :ok
    else
      invalid(operation, "mirror path must be a valid UTF-8 path")
    end
  end

  defp validate_path_binary(_path, operation),
    do: invalid(operation, "mirror path must be a non-empty binary")

  defp validate_store({module, init_arg}, operation) when is_atom(module) do
    callbacks = [init: 1, head: 3, get: 4, put: 4]

    if Code.ensure_loaded?(module) and
         Enum.all?(callbacks, fn {function, arity} ->
           function_exported?(module, function, arity)
         end) do
      {:ok, module, init_arg}
    else
      invalid(operation, "object store module must export init/1, head/3, get/4, and put/4")
    end
  end

  defp validate_store(_store, operation),
    do: invalid(operation, "object store must be {module, init_arg}")

  defp validate_key(key, operation) when is_binary(key) do
    segments = :binary.split(key, "/", [:global])

    valid =
      byte_size(key) in 1..1024 and String.valid?(key) and not String.contains?(key, <<0>>) and
        not String.starts_with?(key, "/") and not String.ends_with?(key, "/") and
        Enum.all?(segments, &(&1 not in ["", ".", ".."]))

    if valid, do: :ok, else: invalid(operation, "object-store key is invalid")
  end

  defp validate_key(_key, operation), do: invalid(operation, "object-store key must be a binary")

  defp validate_publish_options(opts, expanded) when is_list(opts) do
    defaults = %{
      timeout: @default_timeout,
      source_identity: "mirror:" <> Path.basename(expanded),
      created_at: nil,
      git_executable: nil
    }

    if proper_list?(opts) do
      Enum.reduce_while(opts, {:ok, defaults}, fn
        {:timeout, value}, {:ok, options}
        when is_integer(value) and value >= 1 and value <= @maximum_timeout ->
          {:cont, {:ok, %{options | timeout: value}}}

        {:source_identity, value}, {:ok, options}
        when is_binary(value) and byte_size(value) <= 1024 ->
          {:cont, {:ok, %{options | source_identity: value}}}

        {:created_at, value}, {:ok, options} when is_nil(value) or is_binary(value) ->
          {:cont, {:ok, %{options | created_at: value}}}

        {:git_executable, value}, {:ok, options} when is_nil(value) or is_binary(value) ->
          {:cont, {:ok, %{options | git_executable: value}}}

        {key, _value}, _acc when is_atom(key) ->
          {:halt, invalid(:publish, "unknown or invalid publish option: #{inspect(key)}")}

        _malformed, _acc ->
          {:halt, invalid(:publish, "publish options must be a keyword list")}
      end)
    else
      invalid(:publish, "publish options must be a keyword list")
    end
  end

  defp validate_publish_options(_opts, _expanded),
    do: invalid(:publish, "publish options must be a keyword list")

  defp validate_restore_options(opts) when is_list(opts) do
    defaults = %{timeout: @default_timeout}

    if proper_list?(opts) do
      Enum.reduce_while(opts, {:ok, defaults}, fn
        {:timeout, value}, {:ok, options}
        when is_integer(value) and value >= 1 and value <= @maximum_timeout ->
          {:cont, {:ok, %{options | timeout: value}}}

        {key, _value}, _acc when is_atom(key) ->
          {:halt, invalid(:restore, "unknown or invalid restore option: #{inspect(key)}")}

        _malformed, _acc ->
          {:halt, invalid(:restore, "restore options must be a keyword list")}
      end)
    else
      invalid(:restore, "restore options must be a keyword list")
    end
  end

  defp validate_restore_options(_opts),
    do: invalid(:restore, "restore options must be a keyword list")

  defp acquire_lease(path, timeout, operation) do
    try do
      case Locks.acquire(path, timeout) do
        :ok -> :ok
        {:error, %Error{} = error} -> {:error, %{error | operation: operation}}
        _bad_return -> lock_error(operation)
      end
    rescue
      _exception -> lock_error(operation)
    catch
      :exit, _reason -> lock_error(operation)
      _kind, _reason -> lock_error(operation)
    end
  end

  defp release_lease(path) do
    try do
      _ = Locks.release(path)
      :ok
    rescue
      _exception -> :ok
    catch
      _kind, _reason -> :ok
    end
  end

  defp lock_error(operation) do
    {:error,
     Error.new(:backend_error, "fetch lock manager is unavailable",
       operation: operation,
       retryable: true
     )}
  end

  defp sweep_publish(expanded) do
    parent = Path.dirname(expanded)
    basename = Regex.escape(Path.basename(expanded))

    sibling_patterns = [
      {Regex.compile!("\\A#{basename}\\.publish-[0-9a-f]{32}\\.tmp\\z"), :regular},
      {Regex.compile!("\\A\\.#{basename}\\.publish-[0-9a-f]{32}\\.tmp\\.tmp-[0-9a-f]{32}\\z"),
       :regular},
      {Regex.compile!("\\A\\.#{basename}\\.publish-[0-9a-f]{32}\\.tmp\\.staging-[0-9a-f]{32}\\z"),
       :directory}
    ]

    sweep_entries(parent, sibling_patterns)
  end

  defp sweep_restore(expanded) do
    parent = Path.dirname(expanded)
    basename = Regex.escape(Path.basename(expanded))

    sweep_entries(parent, [
      {Regex.compile!("\\A#{basename}\\.restore-[0-9a-f]{32}\\.tmp(?:\\.part)?\\z"), :regular},
      {Regex.compile!("\\A#{basename}\\.restore-[0-9a-f]{32}\\.stage\\.init-[0-9a-f]{32}\\z"),
       :directory},
      {Regex.compile!("\\A#{basename}\\.restore-[0-9a-f]{32}\\.stage\\z"), :directory},
      {Regex.compile!("\\A#{basename}\\.init-[0-9a-f]{32}\\z"), :directory}
    ])
  end

  defp sweep_entries(directory, patterns) do
    case File.ls(directory) do
      {:ok, entries} ->
        Enum.reduce_while(entries, :ok, fn entry, :ok ->
          case Enum.find(patterns, fn {pattern, _type} -> Regex.match?(pattern, entry) end) do
            {_, type} ->
              path = Path.join(directory, entry)

              case File.lstat(path) do
                {:ok, %{type: ^type}} ->
                  case remove_owned(path, type) do
                    :ok -> {:cont, :ok}
                    {:error, %Error{} = error} -> {:halt, {:error, error}}
                  end

                _not_owned_shape ->
                  {:cont, :ok}
              end

            nil ->
              {:cont, :ok}
          end
        end)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        restore_io_error("could not list mirror temporary directory", reason)
    end
  end

  defp remove_owned(path, :regular) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> restore_io_error("could not remove mirror temporary file", reason)
    end
  end

  defp remove_owned(path, :directory) do
    case File.rm_rf(path) do
      {:ok, _removed} ->
        :ok

      {:error, reason, _failed_path} ->
        restore_io_error("could not remove mirror temporary directory", reason)
    end
  end

  defp create_parent_chain(parent) do
    missing = missing_parent_chain(parent, [])

    case missing do
      {:error, %Error{} = error} ->
        {:error, error}

      paths ->
        case File.mkdir_p(parent) do
          :ok ->
            {:ok, paths}

          {:error, reason} ->
            {:error, error} =
              restore_io_error("could not create restore parent directory", reason)

            if cleanup_created_parents(Enum.reverse(paths)) do
              {:error, %{error | details: Map.put(error.details, :cleanup, :failed)}}
            else
              {:error, error}
            end
        end
    end
  end

  defp missing_parent_chain(path, acc) do
    case File.stat(path) do
      {:ok, %{type: :directory}} ->
        acc

      {:ok, _other} ->
        invalid(:restore, "restore parent is not a directory")

      {:error, :enoent} ->
        parent = Path.dirname(path)

        if parent == path do
          acc
        else
          missing_parent_chain(parent, [path | acc])
        end

      {:error, reason} ->
        restore_io_error("could not inspect restore parent directory", reason)
    end
  end

  defp maybe_cleanup_created_parents({:ok, _result} = result, _created), do: result

  defp maybe_cleanup_created_parents({:error, %Error{} = error}, created) do
    failed = cleanup_created_parents(Enum.reverse(created))

    if failed do
      {:error, %{error | details: Map.put(error.details, :cleanup, :failed)}}
    else
      {:error, error}
    end
  end

  defp cleanup_created_parents([]), do: false

  defp cleanup_created_parents([path | rest]) do
    case File.rmdir(path) do
      :ok -> cleanup_created_parents(rest)
      {:error, :enoent} -> cleanup_created_parents(rest)
      # Another actor populated the chain. Stop at the first non-empty
      # directory, as promised, and leave every ancestor intact.
      {:error, :enotempty} -> false
      {:error, :eexist} -> false
      {:error, _reason} -> true
    end
  end

  defp publish_tmp(expanded), do: unique_path(expanded, ".publish-", ".tmp")
  defp restore_tmp(expanded), do: unique_path(expanded, ".restore-", ".tmp")
  defp restore_stage(expanded), do: unique_path(expanded, ".restore-", ".stage")

  defp unique_path(base, middle, suffix) do
    candidate = base <> middle <> random_hex(16) <> suffix

    case File.lstat(candidate) do
      {:error, :enoent} -> candidate
      _exists -> unique_path(base, middle, suffix)
    end
  end

  defp random_hex(bytes), do: :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)

  defp canonical_integer(value, allow_zero, maximum) when is_binary(value) do
    maximum_digits = byte_size(Integer.to_string(maximum))

    valid_syntax =
      byte_size(value) <= maximum_digits and
        if allow_zero do
          value == "0" or canonical_positive_decimal?(value)
        else
          canonical_positive_decimal?(value)
        end

    if valid_syntax do
      case Integer.parse(value) do
        {integer, ""} when integer <= maximum -> {:ok, integer}
        _other -> :error
      end
    else
      :error
    end
  end

  defp canonical_integer(_value, _allow_zero, _maximum), do: :error

  defp canonical_positive_decimal?(<<first, rest::binary>>) when first in ?1..?9,
    do: ascii_digits?(rest)

  defp canonical_positive_decimal?(_value), do: false

  defp ascii_digits?(<<>>), do: true
  defp ascii_digits?(<<digit, rest::binary>>) when digit in ?0..?9, do: ascii_digits?(rest)
  defp ascii_digits?(_value), do: false

  defp valid_metadata_key?(key) when byte_size(key) > 0 do
    Enum.all?(:binary.bin_to_list(key), fn byte ->
      byte in ?a..?z or byte in ?0..?9 or byte in [?_, ?-]
    end)
  end

  defp valid_metadata_key?(_key), do: false

  defp lowercase_hex?(value, size) when byte_size(value) == size do
    Enum.all?(:binary.bin_to_list(value), fn byte -> byte in ?0..?9 or byte in ?a..?f end)
  end

  defp lowercase_hex?(_value, _size), do: false

  defp printable_ascii?(value) do
    value |> :binary.bin_to_list() |> Enum.all?(&(&1 >= 0x20 and &1 <= 0x7E))
  end

  defp string_map?(map) when is_map(map) do
    Enum.all?(map, fn {key, value} -> is_binary(key) and is_binary(value) end)
  end

  defp string_map?(_map), do: false

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_tail), do: false

  defp maybe_keyword(keyword, _key, nil), do: keyword
  defp maybe_keyword(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp publisher_identity do
    version = Application.spec(:gitility, :vsn) || "unknown"
    "gitility #{to_string(version)}"
  end

  defp oid_bytes(%OID{bytes: bytes}), do: bytes
  defp oid_bytes(bytes) when is_binary(bytes), do: bytes

  defp rewrite_result({:ok, value}, _operation), do: {:ok, value}
  defp rewrite_result(:ok, _operation), do: :ok

  defp rewrite_result({:error, %Error{} = error}, operation),
    do: {:error, %{error | operation: operation}}

  defp raw_time_left(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> {:ok, remaining}
      _expired -> :expired
    end
  end

  defp time_left(deadline, operation, phase) do
    case raw_time_left(deadline) do
      {:ok, remaining} -> {:ok, remaining}
      :expired -> timeout_error(operation, phase)
    end
  end

  defp deadline_check(deadline, operation, phase) do
    deadline_check(deadline, operation, phase, %{})
  end

  defp deadline_check(deadline, operation, phase, extra_details) do
    case raw_time_left(deadline) do
      {:ok, _remaining} -> :ok
      :expired -> timeout_error(operation, phase, extra_details)
    end
  end

  defp deadline_marker(_operation), do: :deadline_timeout
  defp deadline_expired_before_call(_operation), do: :deadline_expired_before_call

  defp timeout_error(operation, phase, extra_details \\ %{}) do
    {:error,
     Error.new(:timeout, "mirror #{operation} deadline expired",
       operation: operation,
       details: Map.put(extra_details, :phase, phase)
     )}
  end

  defp malformed_bundle(verify_code, extra_details \\ %{}) do
    {:error,
     Error.new(:malformed_bundle, "downloaded object is not a valid bundle",
       operation: :restore,
       details: Map.put(extra_details, :verify_code, verify_code)
     )}
  end

  defp foreign_object_error(operation) do
    Error.new(
      :backend_error,
      "object at key is not a gitility mirror bundle (missing or malformed metadata)",
      operation: operation,
      cause: {:adapter, :foreign_object}
    )
  end

  defp invalid(operation, message),
    do: {:error, Error.new(:invalid_argument, message, operation: operation)}

  defp internal_failure(operation) do
    {:error,
     Error.new(:internal_error, "mirror #{operation} failed safely", operation: operation)}
  end

  defp restore_io_error(message, reason) do
    {:error,
     Error.new(:backend_error, message,
       operation: :restore,
       retryable: reason in [:eagain, :eintr, :eio, :emfile, :enfile, :estale],
       details: %{reason: reason}
     )}
  end

  defp open_raw(path, modes, message) do
    case :file.open(String.to_charlist(path), modes) do
      {:ok, file} -> {:ok, file}
      {:error, reason} -> restore_io_error(message, reason)
    end
  end

  defp chmod_file(path, mode) do
    case File.chmod(path, mode) do
      :ok -> :ok
      {:error, reason} -> restore_io_error("could not set restored file mode", reason)
    end
  end

  defp rename_file(source, destination, message) do
    case File.rename(source, destination) do
      :ok -> :ok
      {:error, reason} -> restore_io_error(message, reason)
    end
  end
end
