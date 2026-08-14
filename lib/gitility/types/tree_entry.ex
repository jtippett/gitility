defmodule Gitility.TreeEntry do
  @moduledoc """
  One entry from a tree listing.

  `path` and `name` are raw bytes (see `Gitility.Path`). `type` is the
  entry's semantic kind; the original Git `mode` is preserved alongside it,
  so no information is discarded by the typing.

  `size` is populated only when the listing requested `include: [:size]` —
  packed object headers may cost work, so sizes are opt-in.

  Symlinks are never followed; gitlinks (submodule pointers) are returned
  as typed entries and never opened.
  """

  @enforce_keys [:path, :name, :oid, :type, :mode]
  defstruct [:path, :name, :oid, :type, :mode, :size]

  @typedoc "The semantic kind of a tree entry."
  @type entry_type :: :blob | :tree | :symlink | :gitlink

  @type t :: %__MODULE__{
          path: binary(),
          name: binary(),
          oid: Gitility.OID.t(),
          type: entry_type(),
          mode: non_neg_integer(),
          size: non_neg_integer() | nil
        }
end
