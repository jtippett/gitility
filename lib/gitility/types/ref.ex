defmodule Gitility.Ref do
  @moduledoc """
  One reference: a full raw name and its target.

  Names are raw bytes (`refs/heads/main`, `refs/tags/v1.0`, …). Convenience
  branch/tag selectors are expanded by Gitility before reaching any backend.
  """

  @enforce_keys [:name, :target]
  defstruct [:name, :target]

  @type t :: %__MODULE__{
          name: binary(),
          target: Gitility.RefTarget.t()
        }
end
