defmodule Gitility.RefTarget do
  @moduledoc """
  What a reference points at.

  A direct ref carries an `oid`; a symbolic ref carries the raw name of the
  ref it points to. `peeled` is the fully-peeled commit/object ID when the
  store already knows it (annotated tags), sparing a peel round trip.

  Symbolic chains are followed with a hard hop limit; a cycle returns
  `{:error, %Gitility.Error{code: :malformed_ref}}`.
  """

  @enforce_keys [:kind]
  defstruct [:kind, :oid, :symbolic_target, :peeled]

  @type t :: %__MODULE__{
          kind: :direct | :symbolic,
          oid: Gitility.OID.t() | nil,
          symbolic_target: binary() | nil,
          peeled: Gitility.OID.t() | nil
        }
end
