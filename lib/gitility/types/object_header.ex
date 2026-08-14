defmodule Gitility.ObjectHeader do
  @moduledoc """
  An object's type and size without its payload.

  Headers answer "what is this and how big" cheaply — for packed objects
  even the size may require some work, which is why tree listings omit blob
  sizes unless asked (`include: [:size]`).
  """

  @enforce_keys [:oid, :type, :size]
  defstruct [:oid, :type, :size]

  @type t :: %__MODULE__{
          oid: Gitility.OID.t(),
          type: Gitility.Object.object_type(),
          size: non_neg_integer()
        }
end
