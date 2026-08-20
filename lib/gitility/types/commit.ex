defmodule Gitility.Commit do
  @moduledoc """
  A decoded commit.

  Every byte field remains exactly as Git encoded it. `subject` is the first
  message line capped at 1 KiB with `subject_truncated` making that cap
  explicit, and `message_raw` is capped at 64 KiB with `message_truncated`
  doing the same. `signature_headers` contains header names only (`"gpgsig"`,
  …), never signature payloads.
  """

  @enforce_keys [
    :oid,
    :parents,
    :tree_oid,
    :author,
    :committer,
    :subject,
    :subject_truncated,
    :message_raw,
    :message_truncated
  ]
  defstruct [
    :oid,
    :parents,
    :tree_oid,
    :subject,
    :subject_truncated,
    :author,
    :committer,
    :message_raw,
    :message_truncated,
    signature_headers: [],
    encoding: nil
  ]

  @type t :: %__MODULE__{
          oid: Gitility.OID.t(),
          parents: [Gitility.OID.t()],
          tree_oid: Gitility.OID.t(),
          author: Gitility.Identity.t(),
          committer: Gitility.Identity.t(),
          subject: binary(),
          subject_truncated: boolean(),
          message_raw: binary(),
          message_truncated: boolean(),
          signature_headers: [binary()],
          encoding: binary() | nil
        }
end
