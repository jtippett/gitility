defmodule Gitility.Stats do
  @moduledoc """
  Work accounting attached to every query result.

  Stats make cost visible: how many objects a query touched, what the caches
  saved, how many provider round trips remote storage cost, and — when work
  stopped early — which limit stopped it. `stopped_by` is either a field name
  from `Gitility.Limits`, `:limit` for the operation's own `limit:` option, or
  `nil` when the operation ran to completion.

  In Milestone 1, `objects_requested` equals `objects_read`; requests are
  measured separately from the Milestone 2 provider path onward.
  """

  defstruct objects_requested: 0,
            objects_read: 0,
            entries_emitted: 0,
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
          entries_emitted: non_neg_integer(),
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
