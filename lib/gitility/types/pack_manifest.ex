defmodule Gitility.PackManifest do
  @moduledoc """
  An atomic inventory of the packs in a remote (or bundled) pack store.

  Pack and index keys are immutable and content-addressed: publishing a new
  `generation` never rewrites an existing pack. On a missing pack, an
  adapter may refresh the manifest and retry a lookup once within the
  original budget; removed packs remain readable for a grace period so
  in-flight jobs can finish.
  """

  @enforce_keys [:version, :generation, :hash, :packs]
  defstruct [:version, :generation, :hash, packs: [], loose: []]

  @type t :: %__MODULE__{
          version: pos_integer(),
          generation: binary(),
          hash: Gitility.OID.algorithm(),
          packs: [Gitility.PackDescriptor.t()],
          loose: [binary()]
        }
end
