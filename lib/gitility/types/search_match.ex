defmodule Gitility.SearchMatch do
  @moduledoc """
  One match from a snapshot content search.

  Carries enough identity for a stable citation: the snapshot's commit, the
  matched blob, the path, and the position. `line` is 1-based; `column` is
  a 0-based **byte** offset into the line (content is bytes; a character
  column would presuppose an encoding).

  `preview` is the matched line (or its 1 KiB capped prefix) as raw bytes;
  `preview_truncated` explicitly records whether that cap was applied;
  `context_before`/`context_after` carry surrounding lines when
  `context_lines:` was requested. `submatches` gives the byte ranges of
  each match within the preview line.
  """

  @enforce_keys [:commit_oid, :blob_oid, :path, :line, :column, :preview]
  defstruct [
    :commit_oid,
    :blob_oid,
    :path,
    :line,
    :column,
    :preview,
    preview_truncated: false,
    submatches: [],
    context_before: [],
    context_after: []
  ]

  @typedoc "A byte range within the preview line: `{start, length}`."
  @type submatch :: {non_neg_integer(), non_neg_integer()}

  @type t :: %__MODULE__{
          commit_oid: Gitility.OID.t(),
          blob_oid: Gitility.OID.t(),
          path: binary(),
          line: pos_integer(),
          column: non_neg_integer(),
          preview: binary(),
          preview_truncated: boolean(),
          submatches: [submatch()],
          context_before: [binary()],
          context_after: [binary()]
        }
end
