defmodule Gitility.Diff do
  @moduledoc """
  A structured diff between two snapshots (or trees).

  Nothing here requires parsing unified diff text: files, hunks, and lines
  are data. A formatter may render this as unified diff, but the structured
  result is the API.

  `format: :summary` populates only file-level fields; `:stats` adds
  per-file line counts; `:patch` adds hunks and lines.
  """

  @enforce_keys [:files]
  defstruct [:files, stats: %Gitility.Stats{}, warnings: [], truncated: false]

  @type t :: %__MODULE__{
          files: [Gitility.Diff.File.t()],
          stats: Gitility.Stats.t(),
          warnings: [Gitility.Page.warning()],
          truncated: boolean()
        }

  defmodule File do
    @moduledoc """
    One changed file in a diff.

    `status` follows Git's classification. For renames and copies,
    `old_path`/`new_path` differ and `similarity` is the match score in
    basis points of 100 (`90` = 90% similar). Binary files carry
    `binary: true` and no hunks.
    """

    @enforce_keys [:status]
    defstruct [
      :status,
      :old_path,
      :new_path,
      :old_oid,
      :new_oid,
      :old_mode,
      :new_mode,
      :similarity,
      :additions,
      :deletions,
      binary: false,
      hunks: []
    ]

    @type status :: :added | :deleted | :modified | :renamed | :copied | :type_changed

    @type t :: %__MODULE__{
            status: status(),
            old_path: binary() | nil,
            new_path: binary() | nil,
            old_oid: Gitility.OID.t() | nil,
            new_oid: Gitility.OID.t() | nil,
            old_mode: non_neg_integer() | nil,
            new_mode: non_neg_integer() | nil,
            similarity: 0..100 | nil,
            additions: non_neg_integer() | nil,
            deletions: non_neg_integer() | nil,
            binary: boolean(),
            hunks: [Gitility.Diff.Hunk.t()]
          }
  end

  defmodule Hunk do
    @moduledoc "One hunk of a patch-format diff."

    @enforce_keys [:old_start, :old_lines, :new_start, :new_lines]
    defstruct [:old_start, :old_lines, :new_start, :new_lines, :header, lines: []]

    @type t :: %__MODULE__{
            old_start: non_neg_integer(),
            old_lines: non_neg_integer(),
            new_start: non_neg_integer(),
            new_lines: non_neg_integer(),
            header: binary() | nil,
            lines: [Gitility.Diff.Line.t()]
          }
  end

  defmodule Line do
    @moduledoc """
    One line of a hunk. `content` is raw bytes without the leading
    origin marker; `old_line`/`new_line` are 1-based, `nil` on the side
    where the line does not exist.
    """

    @enforce_keys [:origin, :content]
    defstruct [:origin, :content, :old_line, :new_line]

    @type origin :: :context | :addition | :deletion

    @type t :: %__MODULE__{
            origin: origin(),
            content: binary(),
            old_line: pos_integer() | nil,
            new_line: pos_integer() | nil
          }
  end
end
