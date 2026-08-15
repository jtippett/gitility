defmodule Gitility.ByteRange do
  @moduledoc """
  A byte range within one stored artifact, addressed by its storage key
  (a `pack_key`/`index_key` from a `Gitility.PackDescriptor`).

  `c:Gitility.ODB.RangeBackend.read_ranges/2` receives coalesced lists of
  these and returns a map of range → bytes. A short read is a backend
  error, never silently padded.
  """

  @enforce_keys [:key, :offset, :length]
  defstruct [:key, :offset, :length]

  @type t :: %__MODULE__{
          key: binary(),
          offset: non_neg_integer(),
          length: non_neg_integer()
        }
end
