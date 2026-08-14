defmodule Gitility do
  @moduledoc """
  Snapshot-first Git object queries for Elixir.

  Gitility reads commits, trees, and blobs directly from Git object storage —
  local bare repositories, in-memory objects, Elixir-backed providers, or
  remote immutable pack stores — without a worktree, checkout, or shell. Every
  expensive operation is bounded, observable, and cancellable.

  This package is a pre-implementation scaffold. The full design, including
  the public API this module will grow, lives in
  [`docs/plans/2026-08-14-gitility-design.md`](https://github.com/jtippett/gitility/blob/master/docs/plans/2026-08-14-gitility-design.md).
  Implementation starts at that document's Milestone 0.
  """

  @doc """
  Confirms the native library is loaded. Returns `:pong`.

  Scaffold-only smoke check; it will be removed once the real API lands.
  """
  @spec ping() :: :pong
  defdelegate ping(), to: Gitility.Native
end
