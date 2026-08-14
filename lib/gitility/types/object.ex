defmodule Gitility.Object do
  @moduledoc """
  A raw Git object: ID, type, and full payload bytes.

  This is the currency of the ODB layer — what `Gitility.ODB.read/3`
  returns and what `Gitility.ODB.Backend.read_many/2` supplies. Payloads
  are the inflated object contents **without** the `<type> <size>\\0`
  header; Gitility recomputes and verifies the object ID from type + payload
  under `verify: :always`.
  """

  @enforce_keys [:oid, :type, :data]
  defstruct [:oid, :type, :data]

  @typedoc "The four Git object types."
  @type object_type :: :commit | :tree | :blob | :tag

  @type t :: %__MODULE__{
          oid: Gitility.OID.t(),
          type: object_type(),
          data: binary()
        }
end
