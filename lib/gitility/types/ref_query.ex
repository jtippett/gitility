defmodule Gitility.RefQuery do
  @moduledoc """
  A reference listing query: an optional raw-byte name prefix, a page
  limit, and an opaque continuation cursor.
  """

  defstruct prefix: nil, limit: 100, cursor: nil

  @type t :: %__MODULE__{
          prefix: binary() | nil,
          limit: pos_integer(),
          cursor: Gitility.Page.cursor() | nil
        }
end
