defmodule Gitility.Commit do
  @moduledoc """
  A decoded commit.

  Every byte field remains exactly as Git encoded it. `subject` is the first
  message line capped at 1 KiB, and `message_raw` is capped at 64 KiB with
  `message_truncated` making that cap explicit. `signature_headers` contains
  header names only (`"gpgsig"`, …), never signature payloads.
  """

  @enforce_keys [
    :id,
    :parents,
    :tree_id,
    :author,
    :committer,
    :subject,
    :message_raw,
    :message_truncated
  ]
  defstruct [
    :id,
    :parents,
    :tree_id,
    :subject,
    :author,
    :committer,
    :message_raw,
    :message_truncated,
    signature_headers: [],
    encoding: nil
  ]

  @type t :: %__MODULE__{
          id: Gitility.OID.t(),
          parents: [Gitility.OID.t()],
          tree_id: Gitility.OID.t(),
          author: Gitility.Identity.t(),
          committer: Gitility.Identity.t(),
          subject: binary(),
          message_raw: binary(),
          message_truncated: boolean(),
          signature_headers: [binary()],
          encoding: binary() | nil
        }
end
