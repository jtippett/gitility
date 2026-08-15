defmodule Gitility.ODB.RangeBackend do
  @moduledoc """
  The behaviour for byte-range access to a published pack store.

  One backend module serves both access policies — eager hydration
  (`Gitility.ODB.PackFetch`) and lazy range reads (`Gitility.ODB.PackRange`)
  — because they differ in *policy*, not transport. The backend speaks
  whatever moves bytes: Req against S3-style signed URLs, database blob
  chunks, a local directory of published artifacts. Credentials stay inside
  the provider process unless a native transport is explicitly chosen.

  The provider model matches `Gitility.ODB.Backend`: read-only state from
  `c:init/1`, stateless callbacks dispatched concurrently.

  Ranges arrive coalesced (adjacent wanted ranges merged up to a configured
  request maximum). Every returned binary must be exactly `range.length`
  bytes — a short read is a backend error, never padded or truncated
  silently. All fetched pack data is checksum-verified downstream before
  use, so a corrupt or stale byte range fails loudly.
  """

  @typedoc "Opaque backend state, produced by `c:init/1`, passed read-only."
  @type state :: term()

  @doc """
  Builds the backend state from the configuration term given to the
  adapter (`Gitility.ODB.PackFetch.start_link/1` or
  `Gitility.ODB.PackRange.start_link/1`).

  This callback runs in the process calling `start_link/1`, before the
  provider tree exists. Processes it starts are linked to that caller unless
  the backend supervises them itself. Start long-lived resources under your
  own supervisor and pass their registered name or pid in the init argument.
  """
  @callback init(term()) :: {:ok, state()} | {:error, term()}

  @doc """
  Fetches the current pack inventory. Called at open and on refresh; a new
  manifest generation must never rewrite an existing pack's bytes.
  """
  @callback manifest(state()) :: {:ok, Gitility.PackManifest.t()} | {:error, term()}

  @doc """
  Reads the requested byte ranges. Every requested range must appear in
  the result map with exactly `length` bytes.
  """
  @callback read_ranges([Gitility.ByteRange.t()], state()) ::
              {:ok, %{Gitility.ByteRange.t() => binary()}} | {:error, term()}

  @doc "Cleanup on provider shutdown. Optional."
  @callback terminate(term(), state()) :: term()

  @optional_callbacks terminate: 2
end
