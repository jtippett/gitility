defmodule Gitility.Stats do
  @moduledoc """
  Work accounting attached to every query result.

  Stats make cost visible: how many objects a query touched, what the caches
  saved, how many provider round trips remote storage cost, and — when work
  stopped early — which limit stopped it (`stopped_by`, one of the field
  names of `Gitility.Limits`, or `nil` when the operation ran to
  completion).
  """

  defstruct objects_requested: 0,
            objects_read: 0,
            cache_hits: 0,
            cache_misses: 0,
            provider_requests: 0,
            provider_bytes: 0,
            decompressed_bytes: 0,
            scanned_blobs: 0,
            elapsed_ms: 0,
            stopped_by: nil

  @type t :: %__MODULE__{
          objects_requested: non_neg_integer(),
          objects_read: non_neg_integer(),
          cache_hits: non_neg_integer(),
          cache_misses: non_neg_integer(),
          provider_requests: non_neg_integer(),
          provider_bytes: non_neg_integer(),
          decompressed_bytes: non_neg_integer(),
          scanned_blobs: non_neg_integer(),
          elapsed_ms: non_neg_integer(),
          stopped_by: atom() | nil
        }
end
