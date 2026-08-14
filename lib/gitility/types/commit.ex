defmodule Gitility.Commit do
  @moduledoc """
  A decoded commit.

  `message` is the raw message bytes; `subject` is the decoded first line
  as a printable string (lossy convenience). `signature_headers` carries
  raw signature-bearing headers (`gpgsig`, …) when present — Gitility exposes
  them but does not verify signatures in 1.0.
  """

  @enforce_keys [:oid, :tree_oid, :parents, :message, :author, :committer]
  defstruct [
    :oid,
    :tree_oid,
    :parents,
    :message,
    :subject,
    :author,
    :committer,
    signature_headers: []
  ]

  @type t :: %__MODULE__{
          oid: Gitility.OID.t(),
          tree_oid: Gitility.OID.t(),
          parents: [Gitility.OID.t()],
          message: binary(),
          subject: String.t() | nil,
          author: Gitility.Identity.t(),
          committer: Gitility.Identity.t(),
          signature_headers: [{binary(), binary()}]
        }
end
