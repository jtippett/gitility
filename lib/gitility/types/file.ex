defmodule Gitility.File do
  @moduledoc """
  The result of reading one file from a snapshot.

  `data` is raw bytes and always authoritative. `kind` classifies the
  content under the configured policy:

    * `:text` — valid UTF-8 with no binary marker;
    * `:binary` — everything else;
    * `:symlink` — the blob is a symlink target (never followed);
    * `:gitlink` — a submodule pointer (never opened).

  When the read was line-sliced (`lines:`), `start_line`/`end_line` describe
  the returned slice. `total_lines` is the whole blob's line count **when
  known** — it is `nil` when the byte budget stopped the read before the
  full blob could be scanned, because reporting it would require reading
  what the caller asked us not to.

  `lfs_pointer` carries parsed Git LFS pointer metadata when the blob is a
  well-formed LFS pointer; the pointer text itself is still in `data`.
  Gitility identifies pointers but never resolves them.
  """

  @enforce_keys [:path, :blob_oid, :mode, :kind, :data]
  defstruct [
    :path,
    :blob_oid,
    :mode,
    :kind,
    :data,
    :start_line,
    :end_line,
    :total_lines,
    :lfs_pointer,
    truncated: false
  ]

  @type kind :: :text | :binary | :symlink | :gitlink

  @typedoc "Parsed LFS pointer metadata."
  @type lfs_pointer :: %{oid: String.t(), size: non_neg_integer()}

  @type t :: %__MODULE__{
          path: binary(),
          blob_oid: Gitility.OID.t(),
          mode: non_neg_integer(),
          kind: kind(),
          data: binary(),
          start_line: pos_integer() | nil,
          end_line: pos_integer() | nil,
          total_lines: non_neg_integer() | nil,
          truncated: boolean(),
          lfs_pointer: lfs_pointer() | nil
        }
end
