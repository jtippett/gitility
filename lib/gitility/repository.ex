defmodule Gitility.Repository do
  @moduledoc """
  A repository is just an ODB plus an optional RefDB.

  It exists to resolve *selectors* — names for commits — into pinned
  `Gitility.Snapshot`s. Nothing else in the library takes a repository:
  every query takes a snapshot, and a snapshot needs only an ODB and a
  commit ID.

  ## Selectors

  Safe selectors resolve a name through the repository's stores:

      {:oid, oid_or_hex}       # no refs needed
      {:ref, "refs/pull/481/head"}
      {:branch, "main"}        # expands to refs/heads/main
      {:tag, "v1.2.0"}         # expands to refs/tags/…, peels annotated tags
      :head

  `{:revspec, string}` is an opt-in advanced selector (arbitrary revision
  expressions) and is unavailable when the configured stores cannot support
  the operations it requires.
  """

  alias Gitility.{Error, NotImplementedError, ODB, OID, RefDB, Snapshot}

  @typedoc "A repository handle: object store plus optional ref store."
  @type t :: %__MODULE__{odb: ODB.t(), refs: RefDB.t() | nil}

  @enforce_keys [:odb]
  defstruct [:odb, :refs]

  @typedoc "A commit selector — see the moduledoc."
  @type selector ::
          {:oid, OID.t() | String.t()}
          | {:ref, binary()}
          | {:branch, binary()}
          | {:tag, binary()}
          | :head
          | {:revspec, String.t()}

  @doc """
  Opens a local repository directory — bare or normal, though queries never
  read worktree files either way.

  ## Options

    * `:require_bare` — reject a non-bare repository (default `false`).
    * `:object_cache_bytes` — native object cache ceiling (default 64 MiB).
    * `:runtime` — the `Gitility.Runtime` to attach to (default: shared).

  ## Example

      {:ok, repo} =
        Gitility.Repository.open("/srv/git/acme/widgets.git", require_bare: true)

      {:ok, snapshot} = Gitility.Repository.snapshot(repo, {:branch, "main"})
  """
  @spec open(Path.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def open(path, opts \\ []) do
    _ = {path, opts}
    NotImplementedError.stub!(:"Repository.open/2", "Milestone 1")
  end

  @doc """
  Composes independently-created stores into a repository. The stores must
  share a runtime (`:runtime_mismatch` otherwise).

  ## Options

    * `:odb` (required) — a `Gitility.ODB` handle.
    * `:refs` — a `Gitility.RefDB` handle; omit for an ODB-only repository
      (only `{:oid, _}` selectors will resolve).
  """
  @spec from_stores(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_stores(stores) do
    _ = stores
    NotImplementedError.stub!(:"Repository.from_stores/1", "Milestone 4")
  end

  @doc """
  Resolves a selector and pins it as an immutable snapshot.

  Resolution happens once, here: the returned snapshot records the commit
  and root tree IDs and never moves, no matter what the underlying refs do
  afterwards.
  """
  @spec snapshot(t(), selector(), keyword()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def snapshot(repo, selector, opts \\ []) do
    _ = {repo, selector, opts}
    NotImplementedError.stub!(:"Repository.snapshot/3", "Milestone 1")
  end
end
