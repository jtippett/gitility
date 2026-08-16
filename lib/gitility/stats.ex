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

  For a layered ODB, `cache_hits` and `cache_misses` count cache lookups made
  by this job only. `cache_bytes` and `cache_entries` snapshot current
  residency when the result is built; `cache_evictions` is cumulative for the
  cache handle, so it remains observable after the job that caused eviction.

  Search additionally reports unique `files_scanned`, duplicate-path
  `blobs_deduped`, physical duplicate `payload_rereads`, and explicit
  `binary_skipped` / `oversize_skipped` counts.
  `scanned_blobs` is retained as the generic/native compatibility counter and
  equals `files_scanned` for search pages.
  """

  defstruct objects_requested: 0,
            objects_read: 0,
            entries_emitted: 0,
            cache_hits: 0,
            cache_misses: 0,
            cache_bytes: 0,
            cache_entries: 0,
            cache_evictions: 0,
            provider_requests: 0,
            provider_bytes: 0,
            decompressed_bytes: 0,
            scanned_blobs: 0,
            files_scanned: 0,
            blobs_deduped: 0,
            binary_skipped: 0,
            oversize_skipped: 0,
            payload_rereads: 0,
            elapsed_ms: 0,
            stopped_by: nil

  @type t :: %__MODULE__{
          objects_requested: non_neg_integer(),
          objects_read: non_neg_integer(),
          entries_emitted: non_neg_integer(),
          cache_hits: non_neg_integer(),
          cache_misses: non_neg_integer(),
          cache_bytes: non_neg_integer(),
          cache_entries: non_neg_integer(),
          cache_evictions: non_neg_integer(),
          provider_requests: non_neg_integer(),
          provider_bytes: non_neg_integer(),
          decompressed_bytes: non_neg_integer(),
          scanned_blobs: non_neg_integer(),
          files_scanned: non_neg_integer(),
          blobs_deduped: non_neg_integer(),
          binary_skipped: non_neg_integer(),
          oversize_skipped: non_neg_integer(),
          payload_rereads: non_neg_integer(),
          elapsed_ms: non_neg_integer(),
          stopped_by: atom() | nil
        }
end
