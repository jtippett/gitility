defmodule Gitility.PackDescriptor do
  @moduledoc """
  One pack in a `Gitility.PackManifest`: storage keys for the pack and its
  index, sizes for planning fetches, and the pack checksum as identity.
  """

  @enforce_keys [:id, :pack_key, :index_key, :pack_size, :index_size]
  defstruct [:id, :pack_key, :index_key, :pack_size, :index_size, :etag]

  @type t :: %__MODULE__{
          id: binary(),
          pack_key: binary(),
          index_key: binary(),
          pack_size: non_neg_integer(),
          index_size: non_neg_integer(),
          etag: binary() | nil
        }
end
