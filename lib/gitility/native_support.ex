defmodule Gitility.NativeSupport do
  @moduledoc false

  alias Gitility.{
    Blame,
    Commit,
    Diff,
    Error,
    File,
    Identity,
    Job,
    Limits,
    ODB,
    OID,
    Page,
    Repository,
    Runtime,
    SearchMatch,
    Stats,
    Submodule,
    TreeEntry
  }

  @known_limit_names %{
    "timeout_ms" => :timeout_ms,
    "max_objects" => :max_objects,
    "max_object_bytes" => :max_object_bytes,
    "max_total_object_bytes" => :max_total_object_bytes,
    "max_provider_requests" => :max_provider_requests,
    "max_provider_bytes" => :max_provider_bytes,
    "max_hydration_bytes" => :max_hydration_bytes,
    "max_tree_entries" => :max_tree_entries,
    "max_results" => :max_results,
    "max_diff_files" => :max_diff_files,
    "max_diff_hunks" => :max_diff_hunks,
    "max_diff_lines" => :max_diff_lines,
    "max_result_bytes" => :max_result_bytes,
    "max_delta_depth" => :max_delta_depth,
    "limit" => :limit,
    "max_bytes" => :max_bytes,
    "max_total_bytes" => :max_total_bytes
  }

  def limits_map!(%Limits{} = limits) do
    limits
    |> Map.from_struct()
    |> Enum.each(fn
      {_key, value} when is_integer(value) and value > 0 ->
        :ok

      {key, _value} ->
        raise ArgumentError,
              "expected :#{key} in :limits to be a positive integer"
    end)

    Map.from_struct(limits)
  end

  def limits_map!(value) do
    raise ArgumentError,
          "expected :limits to be a Gitility.Limits struct, got: #{inspect(value)}"
  end

  def parse_oid(%OID{} = oid), do: {:ok, oid}
  def parse_oid(hex) when is_binary(hex), do: OID.parse(hex)

  def parse_oid(_value) do
    {:error, Error.new(:invalid_oid, "expected a Gitility.OID or full hexadecimal object ID")}
  end

  def oid(%OID{} = oid), do: {oid.algorithm, oid.bytes}

  def oid_from_bytes(hash, bytes),
    do: %OID{algorithm: hash, bytes: bytes}

  def store(%Repository{odb: odb}), do: store(odb)
  def store(%ODB{ref: resource, hash: hash}), do: {:ok, resource, hash}

  def store(_value) do
    {:error, Error.new(:invalid_argument, "expected a Gitility.Repository or Gitility.ODB")}
  end

  def store_runtime(%Repository{odb: odb}), do: store_runtime(odb)

  def store_runtime(%ODB{ref: resource, hash: hash, runtime: runtime}),
    do: {:ok, resource, hash, runtime}

  def store_runtime(_value) do
    {:error, Error.new(:invalid_argument, "expected a Gitility.Repository or Gitility.ODB")}
  end

  def boolean_option!(opts, key) do
    value = Keyword.fetch!(opts, key)

    if is_boolean(value) do
      value
    else
      raise ArgumentError, ":#{key} must be a boolean"
    end
  end

  def nif_error(%{code: code, message: message, retryable: retryable} = error, operation) do
    details =
      %{}
      |> maybe_put(:limit, normalize_limit(Map.get(error, :limit)))
      |> maybe_put(:layer, Map.get(error, :layer))
      |> maybe_put(:oid, normalize_error_oid(Map.get(error, :oid)))
      |> maybe_put(:order, normalize_order(Map.get(error, :order)))
      |> maybe_put(:file, Map.get(error, :file))
      |> maybe_put(:retry_after_ms, Map.get(error, :retry_after_ms))
      |> maybe_put(:reason, Map.get(error, :reason))
      |> maybe_put(:line_count, Map.get(error, :line_count))
      |> maybe_put(:line, Map.get(error, :line))

    Error.new(code, message, retryable: retryable, operation: operation, details: details)
  end

  defp normalize_order("chronological"), do: :chronological
  defp normalize_order("topological"), do: :topological
  defp normalize_order("date"), do: :date
  defp normalize_order(_order), do: nil

  def runtime_and_resource(:default) do
    case Runtime.default() do
      runtime when is_pid(runtime) -> runtime_and_resource(runtime)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def runtime_and_resource(runtime) do
    case Runtime.resource(runtime) do
      {:ok, resource} -> {:ok, runtime, resource}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def submit_job(runtime, operation, submit) when is_function(submit, 1) do
    with {:ok, runtime, runtime_resource} <- runtime_and_resource(runtime) do
      case submit.(runtime_resource) do
        {:ok, {ref, id}} ->
          {:ok, %Job{ref: ref, id: id, runtime: runtime}}

        {:error, error} ->
          {:error, nif_error(error, operation)}
      end
    end
  end

  def await_sync(submit, timeout_ms, operation) when is_function(submit, 0) do
    result =
      case submit.() do
        {:error, %Error{code: :busy, details: %{retry_after_ms: retry_after_ms}}}
        when is_integer(retry_after_ms) ->
          Process.sleep(retry_after_ms)
          submit.()

        other ->
          other
      end

    case result do
      {:ok, job} ->
        case Job.await(job, timeout_ms + 500) do
          {:error, %Error{code: :await_timeout}} ->
            # A synchronous wrapper owns its internal job. Its admission-time
            # budget has now elapsed, so never abandon it or expose the async
            # await contract: request cancellation and give the terminal
            # notification one short bounded grace. A pathological running
            # task may not observe the interrupt until its next budget check,
            # but it is no longer unowned.
            :ok = Job.cancel(job)
            _terminal = Job.await(job, 1_000)

            {:error, Error.new(:timeout, "operation budget expired", operation: operation)}

          {:error, %Error{} = error} ->
            {:error, %{error | operation: operation}}

          success ->
            success
        end

      error ->
        error
    end
  end

  def job_payload(%{entries: entries, next_cursor: cursor, stats: stats} = page) do
    items =
      Enum.map(entries, fn entry ->
        %TreeEntry{
          path: entry.path,
          name: entry.name,
          oid: job_oid(entry.oid),
          type: entry.kind,
          mode: entry.mode,
          size: entry.size
        }
      end)

    %Page{
      items: items,
      next_cursor: if(cursor, do: Base.url_encode64(cursor, padding: false)),
      truncated: page.truncated,
      stats: struct!(Stats, Map.to_list(stats)),
      warnings: page_warnings(page.truncated, stats.stopped_by)
    }
  end

  def job_payload(%{path: path, hunks: hunks, stats: stats, warnings: warnings}) do
    %Blame{
      path: path,
      hunks:
        Enum.map(hunks, fn hunk ->
          %Blame.Hunk{
            final_range: %Range{first: hunk.final_start, last: hunk.final_end, step: 1},
            original_range: %Range{
              first: hunk.original_start,
              last: hunk.original_end,
              step: 1
            },
            commit_oid: job_oid(hunk.commit_oid),
            original_path: hunk.original_path,
            author: identity_payload(hunk.author),
            committer: identity_payload(hunk.committer),
            summary: hunk.summary,
            boundary: hunk.boundary
          }
        end),
      stats: struct!(Stats, Map.to_list(stats)),
      warnings: warnings
    }
  end

  def job_payload(%{commits: commits, next_cursor: cursor, stats: stats} = page) do
    items =
      Enum.map(commits, fn commit ->
        %Commit{
          id: job_oid(commit.id),
          parents: Enum.map(commit.parents, &job_oid/1),
          tree_id: job_oid(commit.tree_id),
          author: identity_payload(commit.author),
          committer: identity_payload(commit.committer),
          subject: commit.subject,
          subject_truncated: commit.subject_truncated,
          message_raw: commit.message_raw,
          message_truncated: commit.message_truncated,
          signature_headers: commit.signature_headers,
          encoding: commit.encoding
        }
      end)

    %Page{
      items: items,
      next_cursor: if(cursor, do: Base.url_encode64(cursor, padding: false)),
      truncated: page.truncated,
      stats: struct!(Stats, Map.to_list(stats)),
      warnings: page_warnings(page.truncated, stats.stopped_by)
    }
  end

  def job_payload(%{matches: matches, next_cursor: cursor, stats: stats} = page) do
    items =
      Enum.map(matches, fn item ->
        %SearchMatch{
          commit_oid: job_oid(item.commit_oid),
          blob_oid: job_oid(item.blob_oid),
          path: item.path,
          line: item.line,
          column: item.column,
          preview: item.preview,
          preview_truncated: item.preview_truncated,
          submatches: Enum.map(item.submatches, &{&1.start, &1.length}),
          submatches_truncated: item.submatches_truncated,
          context_before: item.context_before,
          context_after: item.context_after
        }
      end)

    %Page{
      items: items,
      next_cursor: if(cursor, do: Base.url_encode64(cursor, padding: false)),
      truncated: page.truncated,
      stats: struct!(Stats, Map.to_list(stats)),
      warnings: search_page_warnings(page.truncated, stats)
    }
  end

  def job_payload(%{blob_oid: blob_oid, path: path, data: data} = file)
      when is_binary(blob_oid) and is_binary(path) and is_binary(data) do
    %File{
      path: path,
      blob_oid: job_oid(blob_oid),
      mode: file.mode,
      kind: file.kind,
      data: data,
      start_line: file.start_line,
      end_line: file.end_line,
      total_lines: file.total_lines,
      truncated: file.truncated,
      lfs_pointer: file.lfs_pointer,
      stats: struct!(Stats, Map.to_list(file.stats))
    }
  end

  def job_payload(%{submodules: submodules}) do
    Enum.map(submodules, fn submodule ->
      %Submodule{
        name: submodule.name,
        path: submodule.path,
        url: submodule.url,
        branch: submodule.branch,
        commit_oid: if(submodule.commit_oid, do: job_oid(submodule.commit_oid)),
        status: submodule.status
      }
    end)
  end

  def job_payload(%{files: files, stats: stats, warnings: warnings, truncated: truncated}) do
    %Diff{
      files: Enum.map(files, &diff_file_payload/1),
      stats: struct!(Stats, Map.to_list(stats)),
      warnings: warnings,
      truncated: truncated
    }
  end

  def job_payload(payload), do: payload

  def invalid_argument(message), do: {:error, Error.new(:invalid_argument, message)}

  def unsupported_selector do
    {:error,
     Error.new(
       :unsupported_operation,
       "ref selectors arrive with the ref adapter milestone (0.2 / Milestone 4)"
     )}
  end

  defp job_oid(bytes) when byte_size(bytes) == 20, do: oid_from_bytes(:sha1, bytes)
  defp job_oid(bytes) when byte_size(bytes) == 32, do: oid_from_bytes(:sha256, bytes)

  defp identity_payload(identity) do
    %Identity{
      name: identity.name,
      email: identity.email,
      time: identity.time,
      tz: identity.tz,
      tz_offset_minutes: identity.tz_offset_minutes
    }
  end

  defp diff_file_payload(file) do
    %Diff.File{
      status: file.status,
      old_path: file.old_path,
      new_path: file.new_path,
      old_oid: if(file.old_oid, do: job_oid(file.old_oid)),
      new_oid: if(file.new_oid, do: job_oid(file.new_oid)),
      old_mode: file.old_mode,
      new_mode: file.new_mode,
      similarity: file.similarity,
      additions: file.additions,
      deletions: file.deletions,
      binary: file.binary,
      hunks: Enum.map(file.hunks, &diff_hunk_payload/1)
    }
  end

  defp diff_hunk_payload(hunk) do
    %Diff.Hunk{
      old_start: hunk.old_start,
      old_lines: hunk.old_lines,
      new_start: hunk.new_start,
      new_lines: hunk.new_lines,
      header: hunk.header,
      lines:
        Enum.map(hunk.lines, fn line ->
          %Diff.Line{
            origin: line.origin,
            content: line.content,
            old_line: line.old_line,
            new_line: line.new_line,
            no_newline: line.no_newline
          }
        end)
    }
  end

  defp page_warnings(false, _stopped_by), do: []

  defp page_warnings(true, stopped_by) do
    [%{code: :truncated, message: "page truncated by #{stopped_by || "an unknown limit"}"}]
  end

  defp search_page_warnings(truncated, stats) do
    page_warnings(truncated, stats.stopped_by)
    |> maybe_add_warning(
      stats.binary_skipped > 0,
      :binary_skipped,
      "binary blobs skipped by :binary policy (NUL in first 8000 bytes)"
    )
    |> maybe_add_warning(
      stats.oversize_skipped > 0,
      :oversize_skipped,
      "oversize blobs skipped by max_object_bytes"
    )
  end

  defp maybe_add_warning(warnings, true, code, message),
    do: warnings ++ [%{code: code, message: message}]

  defp maybe_add_warning(warnings, false, _code, _message), do: warnings

  defp normalize_limit(nil), do: nil
  defp normalize_limit(limit), do: Map.get(@known_limit_names, limit, limit)

  defp normalize_error_oid(nil), do: nil
  defp normalize_error_oid(bytes) when byte_size(bytes) in [20, 32], do: job_oid(bytes)
  defp normalize_error_oid(bytes), do: bytes

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
