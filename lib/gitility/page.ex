defmodule Gitility.Page do
  @moduledoc """
  One page of a potentially large result.

  Every collection that can grow returns a page rather than an unbounded
  list. `truncated` says whether a limit stopped the page short of the full
  result; `next_cursor` (when non-nil) continues from exactly where this
  page stopped.

  Cursors are opaque, URL-safe binaries carrying a versioned, checksummed
  continuation state — the snapshot commit, the operation and its
  normalized options, and the traversal position. They contain no secrets
  and need no server-side session, but they are validated strictly on the
  way back in: a cursor replayed against a different snapshot, operation,
  or option set returns `{:error, %Gitility.Error{code: :invalid_cursor}}`.
  """

  @enforce_keys [:items]
  defstruct items: [],
            next_cursor: nil,
            truncated: false,
            stats: %Gitility.Stats{},
            warnings: []

  @typedoc "An opaque, URL-safe continuation token."
  @type cursor :: binary()

  @typedoc """
  A structured warning attached to a successful result. Truncated pages use
  `%{code: :truncated, message: "page truncated by <limit>"}`.
  """
  @type warning :: %{
          code: :truncated | :binary_skipped | :oversize_skipped,
          message: String.t()
        }

  @type t(item) :: %__MODULE__{
          items: [item],
          next_cursor: cursor() | nil,
          truncated: boolean(),
          stats: Gitility.Stats.t(),
          warnings: [warning()]
        }

  @type t :: t(term())
end
