defmodule Gitility.Mirror.Receipt do
  @moduledoc "The result of publishing a mirror bundle to an object store."

  @enforce_keys [:generation, :etag, :bytes, :tips_digest, :ref_count, :file_count]
  defstruct [:generation, :etag, :bytes, :tips_digest, :ref_count, :file_count]

  @type t :: %__MODULE__{
          generation: pos_integer(),
          etag: binary(),
          bytes: non_neg_integer(),
          tips_digest: binary(),
          ref_count: non_neg_integer(),
          file_count: non_neg_integer()
        }
end
