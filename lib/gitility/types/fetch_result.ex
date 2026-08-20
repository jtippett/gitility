defmodule Gitility.Fetch.Result do
  @moduledoc "The normalized outcome of a native smart-HTTP fetch."

  @type updated_ref :: %{
          name: String.t(),
          action: :created | :fast_forward | :forced,
          old_oid: String.t() | nil,
          new_oid: String.t()
        }
  @type rejected_ref :: %{name: String.t(), reason: atom()}

  @type t :: %__MODULE__{
          updated_refs: [updated_ref()],
          rejected_refs: [rejected_ref()],
          pruned_refs: [String.t()],
          remote_ref_count: non_neg_integer(),
          pack_received: boolean()
        }

  @enforce_keys [
    :updated_refs,
    :rejected_refs,
    :pruned_refs,
    :remote_ref_count,
    :pack_received
  ]
  defstruct @enforce_keys
end
