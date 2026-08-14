defmodule Gitility.ODB.Backend do
  @moduledoc """
  The behaviour for Elixir-backed object storage.

  Implement this to serve Git objects from anywhere — a database, an HTTP
  API, an object store — and Gitility's full query API runs against it with
  no repository directory and no filesystem.

  ## Contract

  Two deliberate decisions shape the callbacks:

  **Batch retrieval is required.** `c:read_many/2` is the primitive; a
  single read is a one-element batch. A single-object callback would be an
  attractive but catastrophically chatty remote interface, so it does not
  exist.

  **Callbacks are stateless and concurrent.** `c:init/1` produces a state
  term passed to every callback read-only; callbacks do not return updated
  state. The provider dispatches callbacks to supervised tasks, up to the
  configured `concurrency`. A backend that needs mutable state — connection
  pools, rate limiters, metrics — owns it explicitly (an ETS table, an
  Agent, its own process) rather than inheriting serialization from a
  GenServer-shaped contract.

  Callbacks must be safe to run concurrently up to the configured
  concurrency. A callback must **not** call back into Gitility against the
  same provider: under pool exhaustion that deadlocks. `:not_found` is a
  normal per-object result, distinct from `{:error, reason}` which fails
  the whole batch; backend error reasons are sanitized before they reach
  query results.

  Objects returned are verified (`verify: :always` recomputes each object
  ID) before anything downstream trusts them; unexpected or duplicate IDs
  in a reply are rejected.

  ## Example

      defmodule MyApp.PostgresObjects do
        @behaviour Gitility.ODB.Backend

        @impl true
        def init(repo_id), do: {:ok, %{repo_id: repo_id}}

        @impl true
        def read_many(oids, %{repo_id: repo_id}) do
          rows = MyApp.Repo.fetch_objects(repo_id, Enum.map(oids, & &1.bytes))

          {:ok,
           Map.new(oids, fn oid ->
             case rows[oid.bytes] do
               nil -> {oid, :not_found}
               {type, data} -> {oid, %Gitility.Object{oid: oid, type: type, data: data}}
             end
           end)}
        end
      end
  """

  @typedoc "Opaque backend state, produced by `c:init/1`, passed read-only."
  @type state :: term()

  @doc """
  Builds the backend state from the configuration term given to
  `Gitility.ODB.start_link/1`.
  """
  @callback init(term()) :: {:ok, state()} | {:error, term()}

  @doc """
  Fetches a batch of objects. Every requested OID must appear in the result
  map, mapped to its object or `:not_found`.
  """
  @callback read_many([Gitility.OID.t()], state()) ::
              {:ok, %{Gitility.OID.t() => Gitility.Object.t() | :not_found}}
              | {:error, term()}

  @doc """
  Fetches type/size headers without payloads. Optional: when absent, the
  provider falls back to `c:read_many/2` and discards payloads (correct but
  wasteful — implement this when your storage can answer cheaply).
  """
  @callback read_headers([Gitility.OID.t()], state()) ::
              {:ok, %{Gitility.OID.t() => Gitility.ObjectHeader.t() | :not_found}}
              | {:error, term()}

  @doc """
  A hint that these OIDs are likely to be read soon. Optional; fire-and-
  forget — the provider never waits on it.
  """
  @callback prefetch([Gitility.OID.t()], state()) :: :ok | {:error, term()}

  @doc """
  Invalidates whatever the backend caches about object availability —
  called when a query hits a missing object that may since have arrived
  (shallow or incrementally populated stores). Optional.
  """
  @callback refresh(state()) :: :ok | {:error, term()}

  @doc "Cleanup on provider shutdown. Optional."
  @callback terminate(term(), state()) :: term()

  @optional_callbacks read_headers: 2, prefetch: 2, refresh: 1, terminate: 2
end
