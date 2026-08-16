defmodule Gitility do
  @moduledoc """
  Snapshot-first Git object queries for Elixir.

  Gitility reads commits, trees, and blobs directly from Git object storage —
  local bare repositories, in-memory objects, Elixir-backed providers, or
  remote immutable pack stores — without a worktree, checkout, or shell.
  Every expensive operation is bounded, observable, and cancellable.

  ## The model in three steps

  1. **Get a store.** `Gitility.Repository.open/2` for a local repository;
     `Gitility.ODB.start_link/1` plus `Gitility.ODB.handle/1`, or
     `Gitility.ODB.from_objects/2`, for object storage with no filesystem at
     all. Refs (`Gitility.RefDB`) are optional and separate.
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

  @typedoc "A commit-graph source: an ODB or a snapshot using its ODB."
  @type graph_store :: ODB.t() | Snapshot.t()

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

  @doc """
  Returns `.gitmodules` declarations correlated with actual snapshot gitlinks.

  Results are ordered by raw path bytes. `:active` rows have both a declaration
  and gitlink, `:undeclared` rows are gitlinks missing from `.gitmodules`, and
  `:orphaned` rows are declarations with no tree entry.

  The only option is `:limits`. URLs are returned as inert bytes: Gitility
  never resolves them, never opens the pinned gitlink commits, and never
  traverses into submodules.
  """
  @spec submodules(Snapshot.t(), keyword()) ::
          {:ok, [Gitility.Submodule.t()]} | {:error, Error.t()}
  def submodules(snapshot, opts \\ [])

  def submodules(%Snapshot{} = snapshot, opts) do
    limits = submodules_options!(opts)

    NativeSupport.await_sync(
      fn -> submit_submodules(snapshot, limits, false) end,
      limits.timeout_ms,
      :submodules
    )
  end

  def submodules(_snapshot, _opts) do
    {:error, Error.new(:invalid_argument, "expected a Gitility.Snapshot", operation: :submodules)}
  end

  ## ————————————————————————————————————————————————————————————————
  ## Search
  ## ————————————————————————————————————————————————————————————————

  @doc """
  Searches blob contents across the snapshot.

  The scan walks the tree, deduplicates match spans by object ID, and scans
  within strict budgets. Duplicate paths may physically re-read a payload to
  materialize results without retaining blob-sized cache entries. (A
  persistent index may implement this same API later — results are keyed by
  blob ID to make that a drop-in.)

  Cursor resume replays the deterministic tree prefix and re-scans the cursor
  path, costing O(prefix paths + one blob re-scan); replayed prefix paths do
  not consume `limits.max_objects` again.

  Search checks cancellation between 64 KiB literal-search windows. Regex
  search checks each line and each yielded match; one matchless regex pass
  over a line is the cancellation-granularity floor and is bounded by
  `limits.max_object_bytes`.

  Context belongs to each match independently, so adjacent matches may repeat
  lines; unlike `git grep -C`, search does not merge context hunks. Options are
  cursor-fingerprinted, but `Gitility.Limits` values are not. Changing a limit
  such as `max_object_bytes` between pages can therefore change which later
  blobs are scanned.

  ## Options

    * `:mode` — `:literal` (default) or `:regex`. Regex patterns must be UTF-8
      and use a linear-time engine over bytes; arbitrary bytes can be matched
      with `\\xNN` escapes. Backreferences and lookaround return
      `{:error, %Gitility.Error{code: :unsupported_regex}}` — there is no
      backtracking fallback.
    * `:case_sensitive` — default `true`.
    * `:path` — restrict to a subtree (raw bytes).
    * `:pathspecs` — glob patterns filtering candidate files.
    * `:binary` — `:skip` (default) or `:text` to scan binary blobs as bytes.
    * `:context_lines` — context lines around each match (default `0`).
    * `:limit`, `:cursor` — pagination.
    * `:limits` — a `Gitility.Limits` override.
  """
  @spec search(Snapshot.t(), binary(), keyword()) ::
          {:ok, Page.t(Gitility.SearchMatch.t())} | {:error, Error.t()}
  def search(snapshot, query, opts \\ [])

  def search(%Snapshot{} = snapshot, query, opts) do
    {opts, limits} = search_options!(opts)

    NativeSupport.await_sync(
      fn -> submit_search(snapshot, query, opts, limits, false) end,
      limits.timeout_ms,
      :search
    )
  end

  def search(_snapshot, _query, _opts) do
    {:error, Error.new(:invalid_argument, "expected a Gitility.Snapshot", operation: :search)}
  end

  ## ————————————————————————————————————————————————————————————————
  ## History
  ## ————————————————————————————————————————————————————————————————

  @doc """
  Walks commit history from the snapshot's commit.

  `:chronological` matches plain `git log`: newest committer time first, with
  Git's priority-queue insertion order (FIFO) for equal timestamps.
  `:topological` and `:date` match `--topo-order` and `--date-order`, including
  the same equal-time insertion semantics. Shallow roots are treated as
  parentless.

  A `:since` bound uses Git's graph pruning: an older commit is excluded and
  traversal does not continue through its parents. `:until` excludes newer
  commits while continuing through their parents.

  Chronological calls cost O(emitted commits + any cursor prefix).
  Topological/date calls require an O(history) reachable-graph pre-pass on
  every call, including cursor resume. If `limits.max_objects` is below the
  reachable commit count, those orders refuse the call with an actionable
  `:budget_exceeded` error before emitting a page.

  ## Options

    * `:order` — `:chronological` (default), `:topological`, or `:date`.
    * `:first_parent` — follow only first parents (default `false`).
    * `:since` / `:until` — commit-time bounds (Unix seconds or `DateTime`).
    * `:limit`, `:cursor` — pagination.
    * `:limits` — a `Gitility.Limits` override.
  """
  @spec log(Snapshot.t(), keyword()) ::
          {:ok, Page.t(Gitility.Commit.t())} | {:error, Error.t()}
  def log(snapshot, opts \\ [])

  def log(%Snapshot{} = snapshot, opts) do
    {opts, limits} = log_options!(opts)

    NativeSupport.await_sync(
      fn -> submit_log(snapshot, opts, limits, false) end,
      limits.timeout_ms,
      :log
    )
  end

  def log(_snapshot, _opts) do
    {:error, Error.new(:invalid_argument, "expected a Gitility.Snapshot", operation: :log)}
  end

  @doc """
  Walks the history of one path — the commits that changed it.

  This is Gitility's own algorithm (upstream has no `log --follow`): a
  budgeted commit walk that tree-diffs each step for the path.
  `follow_renames: true` engages rename tracking to re-target the path
  across renames; its rename-candidate selection deviates from canonical
  Git in documented ways (see the design doc).

  Path history is budgeted separately from `log/2` because it may diff
  many parent trees. Its worst-case cost is O(history × path-depth), with an
  additional bounded change-set pass at each rename candidate.

  A merge is emitted exactly when the tracked path state differs from its first
  parent. Without rename following, no Git invocation reproduces this rule: the
  nearest oracle, `git log --full-history -- <path>`, additionally emits merges
  whose path changed only relative to a non-first parent; Gitility's
  design-sanctioned R3 rule deliberately produces fewer such noise merges. With
  `follow_renames: true`, `git log --full-history --diff-merges=first-parent
  --follow -- <path>` matches Gitility exactly on the pinned git 2.55.0.

  `path` is always one literal repository path; pathspec magic and wildmatch
  metacharacters are rejected. A path that never existed returns an empty page,
  matching `git log`; the corresponding blame query returns `:invalid_path`.

  ## Options

    * `:follow_renames` — follow the path across renames (default `true`).
    * `:limit`, `:cursor` — pagination.
    * `:limits` — a `Gitility.Limits` override.
  """
  @spec history(Snapshot.t(), binary(), keyword()) ::
          {:ok, Page.t(Gitility.Commit.t())} | {:error, Error.t()}
  def history(snapshot, path, opts \\ [])

  def history(%Snapshot{} = snapshot, path, opts) do
    {opts, limits} = history_options!(opts)

    NativeSupport.await_sync(
      fn -> submit_history(snapshot, path, opts, limits, false) end,
      limits.timeout_ms,
      :history
    )
  end

  def history(_snapshot, _path, _opts) do
    {:error, Error.new(:invalid_argument, "expected a Gitility.Snapshot", operation: :history)}
  end

  ## ————————————————————————————————————————————————————————————————
  ## Diff and blame
  ## ————————————————————————————————————————————————————————————————

  @doc """
  Diffs two snapshots as structured data.

  The snapshots may come from **different ODBs** — objects are
  content-addressed, so reads resolve through a union of the two stores
  (head's first). Both must share a hash algorithm (`:hash_mismatch`) and
  a runtime (`:runtime_mismatch`). A miss in the head store falls through to
  the base store; an object-read error in the head store is fail-fast and is
  not retried against the base store.

  At patch detail, a type change is represented by exactly two hunks: a pure
  deletion of the old content followed by a pure insertion of the new content.

  ## Options

    * `:format` — `:summary`, `:stats`, or `:patch` (default `:patch`).
    * `:pathspecs` — glob patterns limiting the diff.
    * `:context_lines` — context per hunk (default `3`).
    * `:renames` — `false` (default) or `:similarity`. Rename detection is
      opt-in because it reads candidate payloads. It buffers and scores
      `O(changes)` candidates before the first record; diff ceilings bound
      output, not this detection phase (timeouts and byte limits still apply).
    * `:copies` — retained in the API surface, but only `false` is accepted in
      0.x. `true` returns `:unsupported_operation` because the current upstream
      tracker can score a post-image blob and suppress the modified source
      record. It can return when upstream tracking is sound or the vendored
      tracker is patched after 1.0.
    * `:limits` — a `Gitility.Limits` override.
  """
  @spec diff(Snapshot.t(), Snapshot.t(), keyword()) :: {:ok, Diff.t()} | {:error, Error.t()}
  def diff(base_snapshot, head_snapshot, opts \\ [])

  def diff(%Snapshot{} = base_snapshot, %Snapshot{} = head_snapshot, opts) do
    {opts, limits} = diff_options!(opts)

    NativeSupport.await_sync(
      fn -> submit_diff(base_snapshot, head_snapshot, opts, limits, false) end,
      limits.timeout_ms,
      :diff
    )
  end

  def diff(_base_snapshot, _head_snapshot, _opts) do
    {:error,
     Error.new(:invalid_argument, "expected two Gitility.Snapshot values", operation: :diff)}
  end

  @doc """
  Attributes each line of a file to the commit that introduced it,
  returned as consecutive hunks (see `Gitility.Blame`).

  ## Options

    * `:lines` — a 1-based inclusive `Range` to blame (much cheaper than
      whole-file for large files).
    * `:follow_renames` — track the content across renames (default `true`).
    * `:limits` — a `Gitility.Limits` override.

  There is deliberately no `first_parent:` option in 0.x: upstream has no
  first-parent blame, and a silently-wrong emulation would be worse than
  the missing option.

  Blame never paginates or returns a partial attribution. A timeout or budget
  ceiling fails the whole call; narrow `:lines` to reduce work. Because the
  final file is mandatory input, a HEAD blob above `max_object_bytes` returns
  `:object_too_large` rather than a warning or truncated result.

  The path is literal, not a pathspec. Symlink and gitlink paths return
  `:invalid_argument` by design (R2); canonical Git instead blames a symlink's
  target text, which is an intentional capability difference.
  """
  @spec blame(Snapshot.t(), binary(), keyword()) :: {:ok, Blame.t()} | {:error, Error.t()}
  def blame(snapshot, path, opts \\ [])

  def blame(%Snapshot{} = snapshot, path, opts) do
    {opts, limits} = blame_options!(opts)

    NativeSupport.await_sync(
      fn -> submit_blame(snapshot, path, opts, limits, false) end,
      limits.timeout_ms,
      :blame
    )
  end

  def blame(_snapshot, _path, _opts) do
    {:error, Error.new(:invalid_argument, "expected a Gitility.Snapshot", operation: :blame)}
  end

  ## ————————————————————————————————————————————————————————————————
  ## Ancestry plumbing
  ## ————————————————————————————————————————————————————————————————

  @doc """
  The best common ancestor of two commits, or `nil` when the histories are
  unrelated. Pass `all: true` to return every best common ancestor.

  When there are multiple best common ancestors, canonical Git's single
  result is unspecified. Gitility deterministically returns the greatest
  object ID; use `all: true` when the full set matters. Local shallow roots
  are treated as parentless.
  """
  @spec merge_base(graph_store(), OID.t() | binary(), OID.t() | binary(), keyword()) ::
          {:ok, OID.t() | nil | [OID.t()]} | {:error, Error.t()}
  def merge_base(store, left_oid, right_oid, opts \\ []) do
    opts = Keyword.validate!(opts, all: false, limits: nil)
    all = NativeSupport.boolean_option!(opts, :all)
    limits = opts[:limits] || Limits.new()
    limits_map = NativeSupport.limits_map!(limits)

    with {:ok, resource, hash, runtime} <- graph_store_runtime(store),
         {:ok, left_oid} <- NativeSupport.parse_oid(left_oid),
         {:ok, right_oid} <- NativeSupport.parse_oid(right_oid),
         {:ok, bases} <-
           NativeSupport.await_sync(
             fn ->
               NativeSupport.submit_job(runtime, :merge_base, fn runtime_resource ->
                 Native.job_submit_merge_base(
                   runtime_resource,
                   resource,
                   left_oid.bytes,
                   right_oid.bytes,
                   limits_map
                 )
               end)
             end,
             limits.timeout_ms,
             :merge_base
           ) do
      bases = Enum.map(bases, &NativeSupport.oid_from_bytes(hash, &1))
      {:ok, if(all, do: bases, else: List.first(bases))}
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @doc """
  Whether `ancestor_oid` is an ancestor of `descendant_oid`.

  This is a short-circuiting reachability walk from the descendant and treats
  local shallow roots as parentless. It is wrapped in an ok-tuple like
  everything else: ancestry can fail on missing or malformed objects, and
  repository-data failures do not raise.
  """
  @spec ancestor?(graph_store(), OID.t() | binary(), OID.t() | binary(), keyword()) ::
          {:ok, boolean()} | {:error, Error.t()}
  def ancestor?(store, ancestor_oid, descendant_oid, opts \\ []) do
    opts = Keyword.validate!(opts, limits: nil)
    limits = opts[:limits] || Limits.new()
    limits_map = NativeSupport.limits_map!(limits)

    with {:ok, resource, _hash, runtime} <- graph_store_runtime(store),
         {:ok, ancestor_oid} <- NativeSupport.parse_oid(ancestor_oid),
         {:ok, descendant_oid} <- NativeSupport.parse_oid(descendant_oid),
         {:ok, result} <-
           NativeSupport.await_sync(
             fn ->
               NativeSupport.submit_job(runtime, :ancestor, fn runtime_resource ->
                 Native.job_submit_is_ancestor(
                   runtime_resource,
                   resource,
                   ancestor_oid.bytes,
                   descendant_oid.bytes,
                   limits_map
                 )
               end)
             end,
             limits.timeout_ms,
             :ancestor
           ) do
      {:ok, result}
    else
      {:error, %Error{} = error} -> {:error, error}
    end
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

  defp validate_blame_lines(nil), do: {:ok, nil}

  defp validate_blame_lines(%Range{first: first, last: last, step: step})
       when is_integer(first) and is_integer(last) and
              ((first <= last and step == 1) or (first > last and step == -1)) do
    validate_blame_line_pair(min(first, last), max(first, last))
  end

  defp validate_blame_lines(%Range{first: first, last: last})
       when is_integer(first) and is_integer(last),
       do: NativeSupport.invalid_argument(":lines Range step must be 1 or -1")

  defp validate_blame_lines({first, last})
       when is_integer(first) and is_integer(last) do
    validate_blame_line_pair(first, last)
  end

  defp validate_blame_lines(%Range{}),
    do: raise(ArgumentError, ":lines Range endpoints must be integers")

  defp validate_blame_lines({_first, _last}),
    do: raise(ArgumentError, ":lines tuple endpoints must be integers")

  defp validate_blame_lines(_value),
    do: raise(ArgumentError, ":lines must be a Range, {start, end}, or nil")

  defp validate_blame_line_pair(first, last)
       when first > 0 and first <= last and last <= 4_294_967_295,
       do: {:ok, {first, last}}

  defp validate_blame_line_pair(_first, _last),
    do: NativeSupport.invalid_argument(":lines must have positive 1-based ordered endpoints")

  defp effective_max_bytes(max_bytes, hard_limit)
       when is_integer(max_bytes) and max_bytes >= 0,
       do: {:ok, min(max_bytes, hard_limit)}

  defp effective_max_bytes(_max_bytes, _hard_limit),
    do: raise(ArgumentError, ":max_bytes must be an integer")

  defp validate_peel_target(target) when target in [:commit, :tree, :blob], do: {:ok, target}

  defp validate_peel_target(_target),
    do: NativeSupport.invalid_argument(":to must be :commit, :tree, or :blob")

  defp validate_log_order(order) when order in [:chronological, :topological, :date],
    do: {:ok, order}

  defp validate_log_order(order) when is_atom(order),
    do: NativeSupport.invalid_argument(":order must be :chronological, :topological, or :date")

  defp validate_log_order(_order), do: raise(ArgumentError, ":order must be an atom")

  defp validate_search_mode(mode) when mode in [:literal, :regex], do: {:ok, mode}

  defp validate_search_mode(mode) when is_atom(mode),
    do: NativeSupport.invalid_argument(":mode must be :literal or :regex")

  defp validate_search_mode(_mode), do: raise(ArgumentError, ":mode must be an atom")

  defp validate_search_binary_mode(mode) when mode in [:skip, :text], do: {:ok, mode}

  defp validate_search_binary_mode(mode) when is_atom(mode),
    do: NativeSupport.invalid_argument(":binary must be :skip or :text")

  defp validate_search_binary_mode(_mode),
    do: raise(ArgumentError, ":binary must be an atom")

  # Mirrors gitility_core::search::MAX_CONTEXT_LINES, the Rust source of truth.
  defp validate_search_context_lines(lines)
       when is_integer(lines) and lines >= 0 and lines <= 32,
       do: {:ok, lines}

  defp validate_search_context_lines(lines) when is_integer(lines),
    do: NativeSupport.invalid_argument(":context_lines must be between 0 and 32")

  defp validate_search_context_lines(_lines),
    do: raise(ArgumentError, ":context_lines must be an integer")

  defp validate_diff_format(format) when format in [:summary, :stats, :patch], do: {:ok, format}

  defp validate_diff_format(format) when is_atom(format),
    do: NativeSupport.invalid_argument(":format must be :summary, :stats, or :patch")

  defp validate_diff_format(_format), do: raise(ArgumentError, ":format must be an atom")

  defp validate_diff_renames(false), do: {:ok, false}
  defp validate_diff_renames(:similarity), do: {:ok, true}

  defp validate_diff_renames(value) when is_atom(value),
    do: NativeSupport.invalid_argument(":renames must be false or :similarity")

  defp validate_diff_renames(_value),
    do: raise(ArgumentError, ":renames must be false or :similarity")

  defp validate_log_time(nil, _key), do: {:ok, nil}
  defp validate_log_time(%DateTime{} = value, _key), do: {:ok, DateTime.to_unix(value)}
  defp validate_log_time(value, _key) when is_integer(value), do: {:ok, value}

  defp validate_log_time(_value, key),
    do: raise(ArgumentError, ":#{key} must be a DateTime, Unix integer seconds, or nil")

  defp graph_store_runtime(%Snapshot{odb: odb}), do: NativeSupport.store_runtime(odb)
  defp graph_store_runtime(%ODB{} = odb), do: NativeSupport.store_runtime(odb)

  defp graph_store_runtime(_value) do
    {:error, Error.new(:invalid_argument, "expected a Gitility.Snapshot or Gitility.ODB")}
  end

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

  @doc "Asynchronous `submodules/2`; returns the `Gitility.Job`."
  @spec async_submodules(Snapshot.t(), keyword()) ::
          {:ok, Job.t()} | {:error, Error.t()}
  def async_submodules(snapshot, opts \\ [])

  def async_submodules(%Snapshot{} = snapshot, opts) do
    opts = Keyword.validate!(opts, limits: nil, detach: false)
    detach = NativeSupport.boolean_option!(opts, :detach)
    limits = opts |> Keyword.delete(:detach) |> submodules_options!()
    submit_submodules(snapshot, limits, detach)
  end

  def async_submodules(_snapshot, _opts) do
    {:error, Error.new(:invalid_argument, "expected a Gitility.Snapshot", operation: :submodules)}
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

  defp log_options!(opts) do
    opts =
      Keyword.validate!(opts,
        order: :chronological,
        first_parent: false,
        since: nil,
        until: nil,
        limit: 1_000,
        cursor: nil,
        limits: nil
      )

    limits = opts[:limits] || Limits.new()
    _limits_map = NativeSupport.limits_map!(limits)
    {opts, limits}
  end

  defp history_options!(opts) do
    opts =
      Keyword.validate!(opts,
        follow_renames: true,
        limit: 1_000,
        cursor: nil,
        limits: nil
      )

    limits = opts[:limits] || Limits.new()
    _limits_map = NativeSupport.limits_map!(limits)
    {opts, limits}
  end

  defp blame_options!(opts) do
    opts = Keyword.validate!(opts, lines: nil, follow_renames: true, limits: nil)
    limits = opts[:limits] || Limits.new()
    _limits_map = NativeSupport.limits_map!(limits)
    {opts, limits}
  end

  defp search_options!(opts) do
    opts =
      Keyword.validate!(opts,
        mode: :literal,
        case_sensitive: true,
        path: "",
        pathspecs: [],
        binary: :skip,
        context_lines: 0,
        limit: 1_000,
        cursor: nil,
        limits: nil
      )

    limits = opts[:limits] || Limits.new()
    {opts, limits}
  end

  defp diff_options!(opts) do
    opts =
      Keyword.validate!(opts,
        format: :patch,
        pathspecs: [],
        context_lines: 3,
        renames: false,
        copies: false,
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

  defp submodules_options!(opts) do
    opts = Keyword.validate!(opts, limits: nil)
    limits = opts[:limits] || Limits.new()
    _limits_map = NativeSupport.limits_map!(limits)
    limits
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

  defp submit_log(
         %Snapshot{odb: %ODB{ref: resource, runtime: runtime}} = snapshot,
         opts,
         limits,
         detach
       ) do
    limits_map = NativeSupport.limits_map!(limits)
    first_parent = NativeSupport.boolean_option!(opts, :first_parent)

    with {:ok, order} <- validate_log_order(opts[:order]),
         {:ok, since} <- validate_log_time(opts[:since], :since),
         {:ok, until} <- validate_log_time(opts[:until], :until),
         {:ok, limit} <- effective_page_limit(opts[:limit], limits.max_results),
         {:ok, cursor} <- decode_cursor(opts[:cursor]) do
      NativeSupport.submit_job(runtime, :log, fn runtime_resource ->
        Native.job_submit_log(
          runtime_resource,
          resource,
          snapshot.commit_oid.bytes,
          snapshot.tree_oid.bytes,
          %{
            order: order,
            first_parent: first_parent,
            since: since,
            until: until,
            limit: limit,
            cursor: cursor
          },
          limits_map,
          detach
        )
      end)
    end
  end

  defp submit_history(
         %Snapshot{odb: %ODB{ref: resource, runtime: runtime}} = snapshot,
         path,
         opts,
         limits,
         detach
       ) do
    limits_map = NativeSupport.limits_map!(limits)
    follow_renames = NativeSupport.boolean_option!(opts, :follow_renames)

    with :ok <- validate_binary(path, "history path"),
         {:ok, limit} <- effective_page_limit(opts[:limit], limits.max_results),
         {:ok, cursor} <- decode_cursor(opts[:cursor]) do
      NativeSupport.submit_job(runtime, :history, fn runtime_resource ->
        Native.job_submit_history(
          runtime_resource,
          resource,
          snapshot.commit_oid.bytes,
          snapshot.tree_oid.bytes,
          path,
          %{follow_renames: follow_renames, limit: limit, cursor: cursor},
          limits_map,
          detach
        )
      end)
    end
  end

  defp submit_blame(
         %Snapshot{odb: %ODB{ref: resource, runtime: runtime}} = snapshot,
         path,
         opts,
         limits,
         detach
       ) do
    limits_map = NativeSupport.limits_map!(limits)
    follow_renames = NativeSupport.boolean_option!(opts, :follow_renames)

    with :ok <- validate_binary(path, "blame path"),
         {:ok, lines} <- validate_blame_lines(opts[:lines]) do
      NativeSupport.submit_job(runtime, :blame, fn runtime_resource ->
        Native.job_submit_blame(
          runtime_resource,
          resource,
          snapshot.commit_oid.bytes,
          snapshot.tree_oid.bytes,
          path,
          %{lines: lines, follow_renames: follow_renames},
          limits_map,
          detach
        )
      end)
    end
  end

  defp submit_search(
         %Snapshot{odb: %ODB{ref: resource, runtime: runtime}} = snapshot,
         query,
         opts,
         limits,
         detach
       ) do
    limits_map = NativeSupport.limits_map!(limits)
    case_sensitive = NativeSupport.boolean_option!(opts, :case_sensitive)

    with :ok <- validate_binary(query, "search query"),
         {:ok, mode} <- validate_search_mode(opts[:mode]),
         :ok <- validate_binary(opts[:path], ":path"),
         {:ok, pathspecs} <- validate_pathspecs(opts[:pathspecs]),
         {:ok, binary_mode} <- validate_search_binary_mode(opts[:binary]),
         {:ok, context_lines} <- validate_search_context_lines(opts[:context_lines]),
         {:ok, limit} <- effective_page_limit(opts[:limit], limits.max_results),
         {:ok, cursor} <- decode_cursor(opts[:cursor]) do
      NativeSupport.submit_job(runtime, :search, fn runtime_resource ->
        Native.job_submit_search(
          runtime_resource,
          resource,
          snapshot.commit_oid.bytes,
          snapshot.tree_oid.bytes,
          query,
          %{
            mode: mode,
            case_sensitive: case_sensitive,
            path: opts[:path],
            pathspecs: pathspecs,
            binary: binary_mode,
            context_lines: context_lines,
            limit: limit,
            cursor: cursor
          },
          limits_map,
          detach
        )
      end)
    end
  end

  defp submit_diff(
         %Snapshot{
           odb: %ODB{ref: base_resource, hash: base_hash, runtime: base_runtime}
         } = base,
         %Snapshot{
           odb: %ODB{ref: head_resource, hash: head_hash, runtime: head_runtime}
         } = head,
         opts,
         limits,
         detach
       ) do
    limits_map = NativeSupport.limits_map!(limits)
    copies = NativeSupport.boolean_option!(opts, :copies)

    with :ok <- validate_diff_runtime(base_runtime, head_runtime),
         :ok <- validate_diff_hash(base_hash, head_hash),
         {:ok, format} <- validate_diff_format(opts[:format]),
         {:ok, pathspecs} <- validate_pathspecs(opts[:pathspecs]),
         {:ok, context_lines} <- validate_search_context_lines(opts[:context_lines]),
         {:ok, renames} <- validate_diff_renames(opts[:renames]),
         :ok <- validate_diff_copies(copies, renames) do
      NativeSupport.submit_job(base_runtime, :diff, fn runtime_resource ->
        Native.job_submit_diff(
          runtime_resource,
          base_resource,
          base.commit_oid.bytes,
          base.tree_oid.bytes,
          head_resource,
          head.commit_oid.bytes,
          head.tree_oid.bytes,
          %{
            format: format,
            pathspecs: pathspecs,
            context_lines: context_lines,
            renames: renames,
            copies: copies
          },
          limits_map,
          detach
        )
      end)
    end
  end

  defp validate_diff_runtime(runtime, runtime), do: :ok

  defp validate_diff_runtime(_base, _head) do
    {:error, Error.new(:runtime_mismatch, "diff snapshots use different runtimes")}
  end

  defp validate_diff_hash(hash, hash), do: :ok

  defp validate_diff_hash(_base, _head) do
    {:error, Error.new(:hash_mismatch, "diff snapshots use different hash algorithms")}
  end

  defp validate_diff_copies(false, _renames), do: :ok

  defp validate_diff_copies(true, _renames) do
    {:error,
     Error.new(
       :unsupported_operation,
       "copy detection is disabled in 0.x because upstream copy tracking can score the post-image blob and suppress the modified source record",
       details: %{reason: "upstream_post_image_copy_tracking_source_suppression"}
     )}
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

  defp submit_submodules(
         %Snapshot{odb: %ODB{ref: resource, runtime: runtime}} = snapshot,
         limits,
         detach
       ) do
    limits_map = NativeSupport.limits_map!(limits)

    NativeSupport.submit_job(runtime, :submodules, fn runtime_resource ->
      Native.job_submit_submodules(
        runtime_resource,
        resource,
        snapshot.commit_oid.bytes,
        snapshot.tree_oid.bytes,
        limits_map,
        detach
      )
    end)
  end

  @doc "Asynchronous `search/3`; returns the `Gitility.Job`."
  @spec async_search(Snapshot.t(), binary(), keyword()) ::
          {:ok, Job.t()} | {:error, Error.t()}
  def async_search(snapshot, query, opts \\ [])

  def async_search(%Snapshot{} = snapshot, query, opts) do
    opts =
      Keyword.validate!(opts,
        mode: :literal,
        case_sensitive: true,
        path: "",
        pathspecs: [],
        binary: :skip,
        context_lines: 0,
        limit: 1_000,
        cursor: nil,
        limits: nil,
        detach: false
      )

    detach = NativeSupport.boolean_option!(opts, :detach)
    {opts, limits} = opts |> Keyword.delete(:detach) |> search_options!()
    submit_search(snapshot, query, opts, limits, detach)
  end

  def async_search(_snapshot, _query, _opts) do
    {:error, Error.new(:invalid_argument, "expected a Gitility.Snapshot", operation: :search)}
  end

  @doc "Asynchronous `log/2`; returns the `Gitility.Job`."
  @spec async_log(Snapshot.t(), keyword()) :: {:ok, Job.t()} | {:error, Error.t()}
  def async_log(%Snapshot{} = snapshot, opts \\ []) do
    opts =
      Keyword.validate!(opts,
        order: :chronological,
        first_parent: false,
        since: nil,
        until: nil,
        limit: 1_000,
        cursor: nil,
        limits: nil,
        detach: false
      )

    detach = NativeSupport.boolean_option!(opts, :detach)
    {opts, limits} = opts |> Keyword.delete(:detach) |> log_options!()
    submit_log(snapshot, opts, limits, detach)
  end

  @doc "Asynchronous `history/3`; returns the `Gitility.Job`."
  @spec async_history(Snapshot.t(), binary(), keyword()) ::
          {:ok, Job.t()} | {:error, Error.t()}
  def async_history(snapshot, path, opts \\ [])

  def async_history(%Snapshot{} = snapshot, path, opts) do
    opts =
      Keyword.validate!(opts,
        follow_renames: true,
        limit: 1_000,
        cursor: nil,
        limits: nil,
        detach: false
      )

    detach = NativeSupport.boolean_option!(opts, :detach)
    {opts, limits} = opts |> Keyword.delete(:detach) |> history_options!()
    submit_history(snapshot, path, opts, limits, detach)
  end

  def async_history(_snapshot, _path, _opts) do
    {:error, Error.new(:invalid_argument, "expected a Gitility.Snapshot", operation: :history)}
  end

  @doc "Asynchronous `diff/3`; returns the `Gitility.Job`."
  @spec async_diff(Snapshot.t(), Snapshot.t(), keyword()) ::
          {:ok, Job.t()} | {:error, Error.t()}
  def async_diff(base_snapshot, head_snapshot, opts \\ [])

  def async_diff(%Snapshot{} = base_snapshot, %Snapshot{} = head_snapshot, opts) do
    opts =
      Keyword.validate!(opts,
        format: :patch,
        pathspecs: [],
        context_lines: 3,
        renames: false,
        copies: false,
        limits: nil,
        detach: false
      )

    detach = NativeSupport.boolean_option!(opts, :detach)
    {opts, limits} = opts |> Keyword.delete(:detach) |> diff_options!()
    submit_diff(base_snapshot, head_snapshot, opts, limits, detach)
  end

  def async_diff(_base_snapshot, _head_snapshot, _opts) do
    {:error,
     Error.new(:invalid_argument, "expected two Gitility.Snapshot values", operation: :diff)}
  end

  @doc "Asynchronous `blame/3`; returns the `Gitility.Job`."
  @spec async_blame(Snapshot.t(), binary(), keyword()) ::
          {:ok, Job.t()} | {:error, Error.t()}
  def async_blame(snapshot, path, opts \\ [])

  def async_blame(%Snapshot{} = snapshot, path, opts) do
    opts =
      Keyword.validate!(opts,
        lines: nil,
        follow_renames: true,
        limits: nil,
        detach: false
      )

    detach = NativeSupport.boolean_option!(opts, :detach)
    {opts, limits} = opts |> Keyword.delete(:detach) |> blame_options!()
    submit_blame(snapshot, path, opts, limits, detach)
  end

  def async_blame(_snapshot, _path, _opts) do
    {:error, Error.new(:invalid_argument, "expected a Gitility.Snapshot", operation: :blame)}
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
