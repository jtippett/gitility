defmodule Gitility.Bundle.Receipt do
  @moduledoc "The deterministic publication summary returned by `Gitility.Bundle.write/2`."

  @enforce_keys [:path, :generation, :bytes, :files, :refs]
  defstruct [:path, :generation, :bytes, :files, :refs, warnings: []]

  @type t :: %__MODULE__{
          path: Path.t(),
          generation: pos_integer(),
          bytes: non_neg_integer(),
          files: non_neg_integer(),
          refs: non_neg_integer(),
          warnings: [Gitility.Page.warning()]
        }
end
