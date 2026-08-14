defmodule Gitility.Snapshot do
  @moduledoc """
  An immutable view of one commit — the unit every semantic query takes.

  Creating a snapshot peels and validates the commit once and records its
  commit and root tree IDs. From then on the snapshot cannot change:
  branches may move, refs may vanish, and every query against this
  snapshot still answers about exactly this commit. `commit_oid` is the
  stable citation for "what code is this answer about".

  A snapshot needs only an ODB — refs are for resolving names, and by the
  time a snapshot exists the name is resolved. See
  `Gitility.Repository.snapshot/3` for selector-based creation.
  """

  alias Gitility.{Error, Limits, Native, NativeSupport, ODB, OID}

  @typedoc "A pinned snapshot: the store it reads from plus its identity."
  @type t :: %__MODULE__{
          odb: ODB.t(),
          commit_oid: OID.t(),
          tree_oid: OID.t()
        }

  @enforce_keys [:odb, :commit_oid, :tree_oid]
  defstruct [:odb, :commit_oid, :tree_oid]

  @doc """
  Opens a snapshot directly from an ODB and a commit ID.

  The commit is read and validated (`:not_a_commit` for other object
  types; annotated tags are peeled to their commit). Opening a SHA-256
  snapshot returns `{:error, %Gitility.Error{code: :unsupported_hash}}`
  until engine support lands — a clean refusal, never a wrong answer.
  """
  @spec open(ODB.t(), OID.t() | String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def open(%ODB{ref: resource, hash: hash} = odb, commit_oid, opts \\ []) do
    opts = Keyword.validate!(opts, limits: nil)
    limits = opts[:limits] || Limits.new()
    limits_map = NativeSupport.limits_map!(limits)

    with {:ok, oid} <- NativeSupport.parse_oid(commit_oid),
         {:ok, result} <- Native.snapshot_open(resource, oid.bytes, limits_map) do
      {:ok,
       %__MODULE__{
         odb: odb,
         commit_oid: NativeSupport.oid_from_bytes(hash, result.commit_oid),
         tree_oid: NativeSupport.oid_from_bytes(hash, result.tree_oid)
       }}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, error} -> {:error, NativeSupport.nif_error(error, :snapshot_open)}
    end
  end
end
