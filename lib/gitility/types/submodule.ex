defmodule Gitility.Submodule do
  @moduledoc """
  Metadata correlating one snapshot gitlink with its `.gitmodules` declaration.

  Paths, names, URLs, and branches remain raw bytes. Declaration paths are inert
  correlation values and are never used for filesystem access. Gitility never
  resolves `url`, follows config includes, opens `commit_oid`, or traverses into
  a submodule. An `:undeclared` row has no declaration metadata; an `:orphaned`
  row has no pinned gitlink commit.
  """

  @enforce_keys [:path, :status]
  defstruct [:name, :path, :url, :branch, :commit_oid, :status]

  @typedoc "How the declaration and snapshot tree correlate."
  @type status :: :active | :undeclared | :orphaned

  @type t :: %__MODULE__{
          name: binary() | nil,
          path: binary(),
          url: binary() | nil,
          branch: binary() | nil,
          commit_oid: Gitility.OID.t() | nil,
          status: status()
        }
end
