defmodule Gitility.RefDB do
  @moduledoc """
  Reference databases: mutable names for immutable objects.

  Refs are deliberately separate from object storage. An ODB plus a commit
  ID answers every snapshot query; a RefDB exists only to turn names —
  branches, tags, PR heads — into commit IDs at snapshot time. That
  separation is what lets refs come from GitHub's API or a database while
  objects come from somewhere else entirely, and what makes "pin a moving
  branch atomically before a long agent run" a one-call operation.

  A provider-backed RefDB serves a `Gitility.RefDB.Backend` implementation
  with the same stateless-concurrent provider model as `Gitility.ODB`.
  """

  alias Gitility.{Error, NotImplementedError, Page, Ref, RefQuery, RefTarget}

  @typedoc "An opaque handle to a reference store."
  @opaque t :: %__MODULE__{
            kind: :local | :provider,
            ref: term(),
            runtime: Gitility.Runtime.t()
          }

  @enforce_keys [:kind, :ref, :runtime]
  defstruct [:kind, :ref, :runtime]

  @doc """
  Starts a provider-backed RefDB.

  ## Options

    * `:backend` (required) — `{module, init_arg}`.
    * `:name` — optional registered name.
    * `:runtime` — the `Gitility.Runtime` to attach to (default: shared).

  ## Example

      {:ok, refs} =
        Gitility.RefDB.start_link(backend: {MyCompany.GitRefBackend, opts})

      {:ok, repo} = Gitility.Repository.from_stores(odb: odb, refs: refs)
  """
  @spec start_link(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def start_link(opts) do
    _ = opts
    NotImplementedError.stub!(:"RefDB.start_link/1", "Milestone 4")
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc """
  Resolves a full reference name (raw bytes, e.g. `"refs/pull/481/head"`)
  to its target. Symbolic chains are followed with a hard hop limit;
  cycles return `:malformed_ref`.
  """
  @spec resolve(t(), binary()) :: {:ok, RefTarget.t()} | {:error, Error.t()}
  def resolve(ref_db, name) do
    _ = {ref_db, name}
    NotImplementedError.stub!(:"RefDB.resolve/2", "Milestone 4")
  end

  @doc """
  Lists references as a page. Returns `:unsupported_operation` for
  resolve-only backends.
  """
  @spec list(t(), RefQuery.t() | keyword()) ::
          {:ok, Page.t(Ref.t())} | {:error, Error.t()}
  def list(ref_db, query \\ %RefQuery{}) do
    _ = {ref_db, query}
    NotImplementedError.stub!(:"RefDB.list/2", "Milestone 4")
  end
end
