defmodule Gitility.Blame do
  @moduledoc """
  A blame result: consecutive hunks, not one record per line.

  Hunk form is substantially more compact for agents — a 200-line file
  last touched by three commits is three hunks, not two hundred rows.
  """

  @enforce_keys [:path, :hunks]
  defstruct [:path, :hunks, stats: %Gitility.Stats{}, warnings: []]

  @type t :: %__MODULE__{
          path: binary(),
          hunks: [Gitility.Blame.Hunk.t()],
          stats: Gitility.Stats.t(),
          warnings: [Gitility.Page.warning()]
        }

  defmodule Hunk do
    @moduledoc """
    One blame hunk: a consecutive run of final lines attributed to a single
    commit.

    `final_range` is the 1-based inclusive line range in the blamed (final)
    file; `original_range` is the corresponding range in `original_path` as
    it existed in `commit_oid`. `boundary` marks hunks attributed to a
    boundary commit (the walk stopped there, e.g. at a `since:` bound —
    attribution is "at least this old", not exact).
    """

    @enforce_keys [:final_range, :original_range, :commit_oid, :original_path]
    defstruct [
      :final_range,
      :original_range,
      :commit_oid,
      :original_path,
      :author,
      :committer,
      :summary,
      boundary: false
    ]

    @type line_range :: Range.t()

    @type t :: %__MODULE__{
            final_range: line_range(),
            original_range: line_range(),
            commit_oid: Gitility.OID.t(),
            original_path: binary(),
            author: Gitility.Identity.t() | nil,
            committer: Gitility.Identity.t() | nil,
            summary: String.t() | nil,
            boundary: boolean()
          }
  end
end
