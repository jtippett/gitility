defmodule Gitility do
  @moduledoc """
  Snapshot-first Git object queries for Elixir.

  Gitility reads commits, trees, and blobs directly from Git object storage —
  local bare repositories, in-memory objects, Elixir-backed providers, or
  remote immutable pack stores — without a worktree, checkout, or shell.
  Every expensive operation is bounded, observable, and cancellable.

  ## The model in three steps

  1. **Get a store.** `Gitility.Repository.open/2` for a local repository;
     `Gitility.ODB.start_link/1` / `from_objects/2` for object storage with
     no filesystem at all. Refs (`Gitility.RefDB`) are optional and separate.
  2. **Pin a snapshot.** `Gitility.Repository.snapshot(repo, {:branch, "main"})`
     or `Gitility.Snapshot.open(odb, commit_oid)` resolves a name once and
     records an immutable commit + tree identity.
  3. **Query it.** Every function in this module takes that snapshot and
     answers about exactly that commit, forever.

  ```elixir
  {:ok, repo} = Gitility.Repository.open("/srv/git/acme/widgets.git", require_bare: true)
  {:ok, snapshot} = Gitility.Repository.snapshot(repo, {:branch, "main"})

  {:ok, page}  = Gitility.list_tree(snapshot, "lib", recursive: true, limit: 500)
  {:ok, file}  = Gitility.read_file(snapshot, "lib/acme/widget.ex", lines: 120..220)
  {:ok, hits}  = Gitility.search(snapshot, "def handle_call", pathspecs: ["**/*.ex"])
  {:ok, blame} = Gitility.blame(snapshot, "lib/acme/widget.ex", lines: 120..220)
  ```

  ## Conventions

    * Paths and file contents are **raw bytes** — Git makes no encoding
      promise and neither does Gitility (see `Gitility.Path`).
    * Normal failures return `{:error, %Gitility.Error{}}`; nothing here
      raises for repository data, missing objects, timeouts, or backend
      failures.
    * Unknown option keys and wrongly typed values for known keys raise
      `ArgumentError`; well-typed values that violate an option's semantic
      constraints return `%Gitility.Error{code: :invalid_argument}`.
    * Everything that can grow returns `%Gitility.Page{}` or carries
      `truncated`/`stats`/`warnings` — truncation is explicit, never silent.
    * All operations accept `limits: %Gitility.Limits{}` and run as
      cancellable jobs; each `async_*` variant returns the `Gitility.Job`
      directly.
  """

  alias Gitility.{
    Blame,
    Diff,
    Error,
    File,
    Job,
    Limits,
    Native,
    NativeSupport,
    NotImplementedError,
    ODB,
    OID,
    Page,
    Repository,
    Snapshot
  }

  @typedoc "Any handle that can answer plumbing queries: a repository or ODB."
  @type store :: Repository.t() | ODB.t()

  ## ————————————————————————————————————————————————————————————————
  ## Trees and files
  ## ————————————————————————————————————————————————————————————————

  @doc """
  Lists tree entries under `path` (raw bytes; `""` for the root).

  ## Options

    * `:recursive` — descend into subtrees (default `false`).
    * `:depth` — maximum descent depth when recursive.
    * `:types` — kinds to include, from `[:blob, :tree, :symlink, :gitlink]`
      (default: all).
    * `:pathspecs` — Patterns are resolved relative to `path`; a pattern without
      wildcards selects that path and everything under it.
    * `:include` — extra per-entry data: `[:size]` (blob sizes are opt-in
      because packed object headers may cost work).
    * `:limit`, `:cursor` — pagination (see `Gitility.Page`).
    * `:limits` — a `Gitility.Limits` override.

  Symlinks are never followed; gitlinks are returned as entries, never
  opened.
  """
  @spec list_tree(Snapshot.t(), binary(), keyword()) ::
          {:ok, Page.t(Gitility.TreeEntry.t())} | {:error, Error.t()}
  def list_tree(%Snapshot{} = snapshot, path \\ "", opts \\ []) do
    {opts, limits} = list_tree_options!(opts)

    NativeSupport.await_sync(
      fn -> submit_list_tree(snapshot, path, opts, limits, false) end,
      limits.timeout_ms,
      :list_tree
    )
  end

  @doc """
  Reads one file (blob) at `path`, bounded.

  ## Options

    * `:lines` — a 1-based inclusive `Range` to slice (e.g. `120..220`).
    * `:max_bytes` — payload cap; truncation is whole-line except when the first
      requested line alone exceeds the cap, in which case that line is returned
      truncated with `truncated: true`.
    * `:limits` — a `Gitility.Limits` override.

  The result's `total_lines` is `nil` when the byte budget stopped the
  read before the whole blob could be scanned. LFS pointers are identified
  (`lfs_pointer`) but never resolved.
  """
  @spec read_file(Snapshot.t(), binary(), keyword()) :: {:ok, File.t()} | {:error, Error.t()}
  def read_file(%Snapshot{} = snapshot, path, opts \\ []) do
    {opts, limits} = read_file_options!(opts)

    NativeSupport.await_sync(
      fn -> submit_read_file(snapshot, path, opts, limits, false) end,
      limits.timeout_ms,
      :read_file
    )
  end

  ## ————————————————————————————————————————————————————————————————
  ## Search
  ## ————————————————————————————————————————————————————————————————

  @doc """
  Searches blob contents across the snapshot.

  The scan walks the tree, deduplicates blobs by object ID, and scans each
  unique blob once, within strict budgets. (A persistent index may
  implement this same API later — results are keyed by blob ID to make
  that a drop-in.)

  ## Options

    * `:mode` — `:literal` (default) or `:regex`. Regex uses a linear-time
      engine over bytes; backreferences and lookaround return
      `{:error, %Gitility.Error{code: :unsupported_regex}}` — there is no
      backtracking fallback.
    * `:case_sensitive` — default `true`.
    * `:path` — restrict to a subtree (raw bytes).
    * `:pathspecs` — glob patterns filtering candidate files.
    * `:binary` — `:skip` (default) or `:match` binary blobs.
    * `:context_lines` — context lines around each match (default `0`).
    * `:limit`, `:cursor` — pagination.
    * `:limits` — a `Gitility.Limits` override.
  """
  @spec search(Snapshot.t(), binary(), keyword()) ::
          {:ok, Page.t(Gitility.SearchMatch.t())} | {:error, Error.t()}
  def search(snapshot, query, opts \\ []) do
    _ = {snapshot, query, opts}
    NotImplementedError.stub!(:"search/3", "Milestone 3")
  end

  ## ————————————————————————————————————————————————————————————————
  ## History
  ## ————————————————————————————————————————————————————————————————

  @doc """
  Walks commit history from the snapshot's commit.

  ## Options

    * `:order` — `:topological` (default) or `:time`.
    * `:first_parent` — follow only first parents (default `false`).
    * `:since` / `:until` — commit-time bounds (Unix seconds or `DateTime`).
    * `:limit`, `:cursor` — pagination.
    * `:limits` — a `Gitility.Limits` override.
  """
  @spec log(Snapshot.t(), keyword()) ::
          {:ok, Page.t(Gitility.Commit.t())} | {:error, Error.t()}
  def log(snapshot, opts \\ []) do
    _ = {snapshot, opts}
    NotImplementedError.stub!(:"log/2", "Milestone 3")
  end

  @doc """
  Walks the history of one path — the commits that changed it.

  This is Gitility's own algorithm (upstream has no `log --follow`): a
  budgeted commit walk that tree-diffs each step for the path.
  `follow_renames: true` engages rename tracking to re-target the path
  across renames; its rename-candidate selection deviates from canonical
  Git in documented ways (see the design doc), which is why it is opt-in.

  Path history is budgeted separately from `log/2` because it may diff
  many parent trees.

  ## Options

    * `:follow_renames` — follow the path across renames (default `false`).
    * `:first_parent` — default `false`.
    * `:limit`, `:cursor` — pagination.
    * `:limits` — a `Gitility.Limits` override.
  """
  @spec history(Snapshot.t(), binary(), keyword()) ::
          {:ok, Page.t(Gitility.Commit.t())} | {:error, Error.t()}
  def history(snapshot, path, opts \\ []) do
    _ = {snapshot, path, opts}
    NotImplementedError.stub!(:"history/3", "Milestone 3")
  end

  ## ————————————————————————————————————————————————————————————————
  ## Diff and blame
  ## ————————————————————————————————————————————————————————————————

  @doc """
  Diffs two snapshots as structured data.

  The snapshots may come from **different ODBs** — objects are
  content-addressed, so reads resolve through a union of the two stores
  (head's first). Both must share a hash algorithm (`:hash_mismatch`) and
  a runtime (`:runtime_mismatch`).

  ## Options

    * `:format` — `:summary`, `:stats`, or `:patch` (default `:patch`).
    * `:pathspecs` — glob patterns limiting the diff.
    * `:context_lines` — context per hunk (default `3`).
    * `:renames` — `:none` | `:exact` | `:similarity` (default `:similarity`).
    * `:copies` — also detect copies (default `false`).
    * `:limits` — a `Gitility.Limits` override.
  """
  @spec diff(Snapshot.t(), Snapshot.t(), keyword()) :: {:ok, Diff.t()} | {:error, Error.t()}
  def diff(base_snapshot, head_snapshot, opts \\ []) do
    _ = {base_snapshot, head_snapshot, opts}
    NotImplementedError.stub!(:"diff/3", "Milestone 3")
  end

  @doc """
  Attributes each line of a file to the commit that introduced it,
  returned as consecutive hunks (see `Gitility.Blame`).

  ## Options

    * `:lines` — a 1-based inclusive `Range` to blame (much cheaper than
      whole-file for large files).
    * `:follow_renames` — track the content across renames (default `true`).
    * `:since` — don't attribute past this bound; older lines land in
      boundary hunks.
    * `:limits` — a `Gitility.Limits` override.

  There is deliberately no `first_parent:` option in 0.x: upstream has no
  first-parent blame, and a silently-wrong emulation would be worse than
  the missing option.
  """
  @spec blame(Snapshot.t(), binary(), keyword()) :: {:ok, Blame.t()} | {:error, Error.t()}
  def blame(snapshot, path, opts \\ []) do
    _ = {snapshot, path, opts}
    NotImplementedError.stub!(:"blame/3", "Milestone 3")
  end

  ## ————————————————————————————————————————————————————————————————
  ## Ancestry plumbing
  ## ————————————————————————————————————————————————————————————————

  @doc """
  The best common ancestor of two commits, or `:none` when the histories
  are unrelated.
  """
  @spec merge_base(store(), OID.t(), OID.t()) ::
          {:ok, OID.t() | :none} | {:error, Error.t()}
  def merge_base(store, left_oid, right_oid) do
    _ = {store, left_oid, right_oid}
    NotImplementedError.stub!(:"merge_base/3", "Milestone 3")
  end

  @doc """
  Whether `ancestor_oid` is an ancestor of `descendant_oid`.

  Wrapped in an ok-tuple like everything else — ancestry can fail on
  missing objects, and the error model does not raise for repository data.
  """
  @spec ancestor?(store(), OID.t(), OID.t()) :: {:ok, boolean()} | {:error, Error.t()}
  def ancestor?(store, ancestor_oid, descendant_oid) do
    _ = {store, ancestor_oid, descendant_oid}
    NotImplementedError.stub!(:"ancestor?/3", "Milestone 3")
  end

  @doc """
  Peels an object to a target kind — e.g. an annotated tag chain to its
  commit (`to: :commit`, the default).
  """
  @spec peel(store(), OID.t() | String.t(), keyword()) ::
          {:ok, OID.t()} | {:error, Error.t()}
  def peel(store, oid, opts \\ []) do
    opts = Keyword.validate!(opts, to: :commit, limits: nil)
    limits = opts[:limits] || Limits.new()
    limits_map = NativeSupport.limits_map!(limits)

    with {:ok, resource, hash, runtime} <- NativeSupport.store_runtime(store),
         {:ok, oid} <- NativeSupport.parse_oid(oid),
         {:ok, target} <- validate_peel_target(opts[:to]),
         {:ok, peeled} <-
           NativeSupport.await_sync(
             fn ->
               NativeSupport.submit_job(runtime, :peel, fn runtime_resource ->
                 Native.job_submit_peel(
                   runtime_resource,
                   resource,
                   oid.bytes,
                   target,
                   limits_map
                 )
               end)
             end,
             limits.timeout_ms,
             :peel
           ) do
      {:ok, NativeSupport.oid_from_bytes(hash, peeled)}
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp validate_binary(value, _label) when is_binary(value), do: :ok

  defp validate_binary(_value, label), do: raise(ArgumentError, "#{label} must be a binary")

  defp validate_depth(nil), do: {:ok, nil}

  defp validate_depth(depth)
       when is_integer(depth) and depth >= 0 and depth <= 4_294_967_295,
       do: {:ok, depth}

  defp validate_depth(depth) when is_integer(depth),
    do: NativeSupport.invalid_argument(":depth must be a non-negative 32-bit integer or nil")

  defp validate_depth(_depth),
    do: raise(ArgumentError, ":depth must be an integer or nil")

  defp validate_tree_types(types) when is_list(types) do
    cond do
      not Enum.all?(types, &is_atom/1) ->
        raise ArgumentError, ":types entries must be atoms"

      Enum.all?(types, &(&1 in [:blob, :tree, :symlink, :gitlink])) ->
        {:ok, types}

      true ->
        NativeSupport.invalid_argument(
          ":types must contain only :blob, :tree, :symlink, and :gitlink"
        )
    end
  end

  defp validate_tree_types(_types),
    do: raise(ArgumentError, ":types must be a list of atoms")

  defp validate_pathspecs(pathspecs) when is_list(pathspecs) do
    if Enum.all?(pathspecs, &is_binary/1) do
      {:ok, pathspecs}
    else
      raise ArgumentError, ":pathspecs entries must be binaries"
    end
  end

  defp validate_pathspecs(_pathspecs),
    do: raise(ArgumentError, ":pathspecs must be a list of binaries")

  defp validate_include(include) when is_list(include) do
    cond do
      not Enum.all?(include, &is_atom/1) ->
        raise ArgumentError, ":include entries must be atoms"

      Enum.all?(include, &(&1 == :size)) ->
        {:ok, :size in include}

      true ->
        NativeSupport.invalid_argument(":include supports only :size")
    end
  end

  defp validate_include(_include),
    do: raise(ArgumentError, ":include must be a list of atoms")

  defp effective_page_limit(limit, _max_results) when is_integer(limit) and limit > 0,
    do: {:ok, limit}

  defp effective_page_limit(limit, _max_results) when is_integer(limit),
    do: NativeSupport.invalid_argument(":limit must be a positive integer")

  defp effective_page_limit(_limit, _max_results),
    do: raise(ArgumentError, ":limit must be an integer")

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(cursor) when is_binary(cursor) do
    case Base.url_decode64(cursor, padding: false) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, Error.new(:invalid_cursor, "cursor is not valid unpadded base64url")}
    end
  end

  defp decode_cursor(_cursor),
    do: raise(ArgumentError, ":cursor must be a binary or nil")

  defp validate_lines(nil), do: {:ok, nil}

  defp validate_lines(%Range{first: first, last: last, step: step})
       when first > 0 and last > 0 and first <= last and step > 0 and
              first <= 4_294_967_295 and last <= 4_294_967_295,
       do: {:ok, {first, last}}

  defp validate_lines(range) do
    case range do
      %Range{} ->
        NativeSupport.invalid_argument(
          ":lines must be an ascending Range with positive 1-based endpoints"
        )

      _ ->
        raise ArgumentError, ":lines must be a Range or nil"
    end
  end

  defp effective_max_bytes(max_bytes, hard_limit)
       when is_integer(max_bytes) and max_bytes >= 0,
       do: {:ok, min(max_bytes, hard_limit)}

  defp effective_max_bytes(_max_bytes, _hard_limit),
    do: raise(ArgumentError, ":max_bytes must be an integer")

  defp validate_peel_target(target) when target in [:commit, :tree, :blob], do: {:ok, target}

  defp validate_peel_target(_target),
    do: NativeSupport.invalid_argument(":to must be :commit, :tree, or :blob")

  ## ————————————————————————————————————————————————————————————————
  ## Async variants
  ## ————————————————————————————————————————————————————————————————

  # Every synchronous query above is implemented over a job; these return
  # the job directly. All take the same arguments as their synchronous
  # counterpart plus `detach: true` to let the job outlive the caller.
  # Results come from `Gitility.Job.await/2`.

  @doc "Asynchronous `list_tree/3`; returns the `Gitility.Job`."
  @spec async_list_tree(Snapshot.t(), binary(), keyword()) ::
          {:ok, Job.t()} | {:error, Error.t()}
  def async_list_tree(%Snapshot{} = snapshot, path \\ "", opts \\ []) do
    opts =
      Keyword.validate!(opts,
        recursive: false,
        depth: nil,
        types: [:blob, :tree, :symlink, :gitlink],
        pathspecs: [],
        include: [],
        limit: 1_000,
        cursor: nil,
        limits: nil,
        detach: false
      )

    detach = NativeSupport.boolean_option!(opts, :detach)
    {opts, limits} = opts |> Keyword.delete(:detach) |> list_tree_options!()
    submit_list_tree(snapshot, path, opts, limits, detach)
  end

  @doc "Asynchronous `read_file/3`; returns the `Gitility.Job`."
  @spec async_read_file(Snapshot.t(), binary(), keyword()) ::
          {:ok, Job.t()} | {:error, Error.t()}
  def async_read_file(%Snapshot{} = snapshot, path, opts \\ []) do
    opts = Keyword.validate!(opts, lines: nil, max_bytes: 256_000, limits: nil, detach: false)
    detach = NativeSupport.boolean_option!(opts, :detach)
    {opts, limits} = opts |> Keyword.delete(:detach) |> read_file_options!()
    submit_read_file(snapshot, path, opts, limits, detach)
  end

  defp list_tree_options!(opts) do
    opts =
      Keyword.validate!(opts,
        recursive: false,
        depth: nil,
        types: [:blob, :tree, :symlink, :gitlink],
        pathspecs: [],
        include: [],
        limit: 1_000,
        cursor: nil,
        limits: nil
      )

    limits = opts[:limits] || Limits.new()
    _limits_map = NativeSupport.limits_map!(limits)
    {opts, limits}
  end

  defp read_file_options!(opts) do
    opts = Keyword.validate!(opts, lines: nil, max_bytes: 256_000, limits: nil)
    limits = opts[:limits] || Limits.new()
    _limits_map = NativeSupport.limits_map!(limits)
    {opts, limits}
  end

  defp submit_list_tree(
         %Snapshot{odb: %ODB{ref: resource, runtime: runtime}} = snapshot,
         path,
         opts,
         limits,
         detach
       ) do
    limits_map = NativeSupport.limits_map!(limits)
    recursive = NativeSupport.boolean_option!(opts, :recursive)

    with :ok <- validate_binary(path, "tree path"),
         {:ok, depth} <- validate_depth(opts[:depth]),
         {:ok, types} <- validate_tree_types(opts[:types]),
         {:ok, pathspecs} <- validate_pathspecs(opts[:pathspecs]),
         {:ok, include_size} <- validate_include(opts[:include]),
         {:ok, limit} <- effective_page_limit(opts[:limit], limits.max_results),
         {:ok, cursor} <- decode_cursor(opts[:cursor]) do
      NativeSupport.submit_job(runtime, :list_tree, fn runtime_resource ->
        Native.job_submit_list_tree(
          runtime_resource,
          resource,
          snapshot.commit_oid.bytes,
          snapshot.tree_oid.bytes,
          %{
            path: path,
            recursive: recursive,
            depth: depth,
            types: types,
            pathspecs: pathspecs,
            include_size: include_size,
            limit: limit,
            cursor: cursor
          },
          limits_map,
          detach
        )
      end)
    end
  end

  defp submit_read_file(
         %Snapshot{odb: %ODB{ref: resource, runtime: runtime}} = snapshot,
         path,
         opts,
         limits,
         detach
       ) do
    limits_map = NativeSupport.limits_map!(limits)

    with :ok <- validate_binary(path, "file path"),
         {:ok, lines} <- validate_lines(opts[:lines]),
         {:ok, max_bytes} <- effective_max_bytes(opts[:max_bytes], limits.max_object_bytes) do
      NativeSupport.submit_job(runtime, :read_file, fn runtime_resource ->
        Native.job_submit_read_file(
          runtime_resource,
          resource,
          snapshot.commit_oid.bytes,
          snapshot.tree_oid.bytes,
          path,
          %{lines: lines, max_bytes: max_bytes},
          limits_map,
          detach
        )
      end)
    end
  end

  @doc "Asynchronous `search/3`; returns the `Gitility.Job`."
  @spec async_search(Snapshot.t(), binary(), keyword()) ::
          {:ok, Job.t()} | {:error, Error.t()}
  def async_search(snapshot, query, opts \\ []) do
    _ = {snapshot, query, opts}
    NotImplementedError.stub!(:"async_search/3", "Milestone 3")
  end

  @doc "Asynchronous `log/2`; returns the `Gitility.Job`."
  @spec async_log(Snapshot.t(), keyword()) :: {:ok, Job.t()} | {:error, Error.t()}
  def async_log(snapshot, opts \\ []) do
    _ = {snapshot, opts}
    NotImplementedError.stub!(:"async_log/2", "Milestone 3")
  end

  @doc "Asynchronous `history/3`; returns the `Gitility.Job`."
  @spec async_history(Snapshot.t(), binary(), keyword()) ::
          {:ok, Job.t()} | {:error, Error.t()}
  def async_history(snapshot, path, opts \\ []) do
    _ = {snapshot, path, opts}
    NotImplementedError.stub!(:"async_history/3", "Milestone 3")
  end

  @doc "Asynchronous `diff/3`; returns the `Gitility.Job`."
  @spec async_diff(Snapshot.t(), Snapshot.t(), keyword()) ::
          {:ok, Job.t()} | {:error, Error.t()}
  def async_diff(base_snapshot, head_snapshot, opts \\ []) do
    _ = {base_snapshot, head_snapshot, opts}
    NotImplementedError.stub!(:"async_diff/3", "Milestone 3")
  end

  @doc "Asynchronous `blame/3`; returns the `Gitility.Job`."
  @spec async_blame(Snapshot.t(), binary(), keyword()) ::
          {:ok, Job.t()} | {:error, Error.t()}
  def async_blame(snapshot, path, opts \\ []) do
    _ = {snapshot, path, opts}
    NotImplementedError.stub!(:"async_blame/3", "Milestone 3")
  end

  ## ————————————————————————————————————————————————————————————————
  ## Scaffold
  ## ————————————————————————————————————————————————————————————————

  @doc """
  Confirms the native library is loaded. Returns `:pong`.

  Scaffold-only smoke check; it will be removed once the real native
  surface lands.
  """
  @spec ping() :: :pong
  defdelegate ping(), to: Gitility.Native
end
