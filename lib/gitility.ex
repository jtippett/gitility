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
  def list_tree(snapshot, path \\ "", opts \\ []) do
    _ = {snapshot, path, opts}
    NotImplementedError.stub!(:"list_tree/3", "Milestone 1")
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
  def read_file(snapshot, path, opts \\ []) do
    _ = {snapshot, path, opts}
    NotImplementedError.stub!(:"read_file/3", "Milestone 1")
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
  @spec peel(store(), OID.t(), keyword()) :: {:ok, OID.t()} | {:error, Error.t()}
  def peel(store, oid, opts \\ []) do
    _ = {store, oid, opts}
    NotImplementedError.stub!(:"peel/3", "Milestone 1")
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
  def async_list_tree(snapshot, path \\ "", opts \\ []) do
    _ = {snapshot, path, opts}
    NotImplementedError.stub!(:"async_list_tree/3", "Milestone 2")
  end

  @doc "Asynchronous `read_file/3`; returns the `Gitility.Job`."
  @spec async_read_file(Snapshot.t(), binary(), keyword()) ::
          {:ok, Job.t()} | {:error, Error.t()}
  def async_read_file(snapshot, path, opts \\ []) do
    _ = {snapshot, path, opts}
    NotImplementedError.stub!(:"async_read_file/3", "Milestone 2")
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
