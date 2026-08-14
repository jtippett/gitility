defmodule Gitility.RefDB.Backend do
  @moduledoc """
  The behaviour for Elixir-backed reference resolution.

  References are mutable names for immutable objects, so they live behind a
  separate contract from object storage: a caller that already knows a
  commit ID needs no RefDB at all, and a RefDB can be served by GitHub's
  API, a database, or a snapshot taken at publish time.

  The provider model is the same as `Gitility.ODB.Backend`: `c:init/1`
  builds a read-only state term, callbacks are stateless and dispatched
  concurrently, and mutable state is the backend's own explicit
  responsibility. One module may implement both behaviours, but Gitility
  treats the two roles as independent capabilities and never shares state
  between them implicitly.

  Reference names are full raw binaries (`refs/heads/main`); convenience
  branch/tag selectors are expanded by Gitility before the backend is
  called. Symbolic refs are followed by Gitility with a hard hop limit —
  the backend only reports what a name points at.
  """

  @typedoc "Opaque backend state, produced by `c:init/1`, passed read-only."
  @type state :: term()

  @doc """
  Builds the backend state from the configuration term given to
  `Gitility.RefDB.start_link/1`.
  """
  @callback init(term()) :: {:ok, state()} | {:error, term()}

  @doc """
  Resolves one full reference name to its target, or `:not_found`.
  """
  @callback resolve(binary(), state()) ::
              {:ok, Gitility.RefTarget.t() | :not_found} | {:error, term()}

  @doc """
  Lists references matching a query as a page of `Gitility.Ref` structs.
  Optional: a resolve-only backend (e.g. "ask GitHub for one branch head")
  simply cannot enumerate, and `Gitility.RefDB.list/2` returns
  `{:error, %Gitility.Error{code: :unsupported_operation}}` for it.
  """
  @callback list(Gitility.RefQuery.t(), state()) ::
              {:ok, Gitility.Page.t(Gitility.Ref.t())} | {:error, term()}

  @doc "Invalidates cached ref state. Optional."
  @callback refresh(state()) :: :ok | {:error, term()}

  @doc "Cleanup on provider shutdown. Optional."
  @callback terminate(term(), state()) :: term()

  @optional_callbacks list: 2, refresh: 1, terminate: 2
end
