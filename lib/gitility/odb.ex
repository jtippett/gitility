defmodule Gitility.ODB do
  @moduledoc """
  Object databases: where Git objects come from.

  An ODB is content-addressed and immutable-by-ID — it has no notion of
  branches or names (that is `Gitility.RefDB`). A caller that already knows
  a commit ID needs only an ODB; `Gitility.Snapshot.open/2` takes one
  directly.

  All stores yield the same opaque `t:t/0` handle, and every store answers
  the same query API identically — storage never leaks into query
  semantics. Stores:

    * **Local** — a bare or normal repository directory, opened via
      `Gitility.Repository.open/2` (worktree files are never read).
    * **Static** — a fixed in-memory object set (`from_objects/2`): tests,
      generated repos, callers already holding objects.
    * **Provider** — objects served by your `Gitility.ODB.Backend`
      implementation (`start_link/1`): any storage, no filesystem.
    * **Layered** — read-through composition (`layer/1`), typically a
      `cache/1` layer in front of a remote store.

  Layers are queried in order and must share a runtime and hash algorithm.
  A successful remote read populates earlier writable cache layers. Disk
  caching is never implicit — there is no disk anywhere in this module.
  """

  alias Gitility.{Error, NotImplementedError, Object, ObjectHeader, OID}

  @typedoc """
  An opaque handle to an object store.

  Carries the store's kind, its native or process reference, its hash
  algorithm, and its runtime affiliation (used to enforce
  `:runtime_mismatch` at composition time). Match on it only via this
  module's functions.
  """
  @opaque t :: %__MODULE__{
            kind: :local | :static | :provider | :layered,
            ref: term(),
            hash: OID.algorithm(),
            runtime: Gitility.Runtime.t()
          }

  @enforce_keys [:kind, :ref, :hash, :runtime]
  defstruct [:kind, :ref, :hash, :runtime]

  @doc """
  Starts a provider-backed ODB serving objects through a
  `Gitility.ODB.Backend` implementation.

  The provider is a supervised process — use `{Gitility.ODB, opts}` in a
  supervision tree. Gitility monitors it: provider exit fails pending
  requests with `:provider_down` and cancels jobs that cannot progress.

  ## Options

    * `:backend` (required) — `{module, init_arg}`.
    * `:name` — optional registered name (supports via tuples).
    * `:hash` — `:sha1` (default) or `:sha256`.
    * `:verify` — `:always` (default): recompute and check every object ID.
    * `:concurrency` — max concurrent backend callbacks (default `8`).
    * `:request_timeout` — per-batch deadline in ms (default `15_000`).
    * `:runtime` — the `Gitility.Runtime` to attach to (default: shared).
    * `:cache` — provider-side cache: `object_bytes:`, `header_entries:`,
      `negative_ttl:` (ms; missing objects may arrive later in shallow or
      incrementally populated stores, so negatives expire fast).

  ## Example

      {:ok, odb} =
        Gitility.ODB.start_link(
          backend: {MyCompany.GitObjectBackend, backend_options},
          concurrency: 8,
          cache: [object_bytes: 128 * 1024 * 1024]
        )

      {:ok, snapshot} = Gitility.Snapshot.open(odb, commit_oid)
  """
  @spec start_link(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def start_link(opts) do
    _ = opts
    NotImplementedError.stub!(:"ODB.start_link/1", "Milestone 2")
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc """
  Builds a static in-memory ODB from an enumerable of `Gitility.Object`
  structs — a fixed store for tests, small generated repositories, and
  callers that already hold object data.

  Distinct from `cache/1`, which is a writable cache *layer*; the two are
  deliberately not both called "memory".

  ## Options

    * `:hash` — `:sha1` (default) or `:sha256`.
    * `:verify` — `:always` (default) verifies every object at load.
    * `:runtime` — the `Gitility.Runtime` to attach to (default: shared).
  """
  @spec from_objects(Enumerable.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_objects(objects, opts \\ []) do
    _ = {objects, opts}
    NotImplementedError.stub!(:"ODB.from_objects/2", "Milestone 1")
  end

  @doc """
  Composes stores into one read-through ODB. Layers are queried in order;
  a hit in a later layer populates earlier writable cache layers when
  allowed. All layers must share a hash algorithm (`:hash_mismatch`) and
  runtime (`:runtime_mismatch`).

      {:ok, odb} =
        Gitility.ODB.layer([
          Gitility.ODB.cache(max_bytes: 128 * 1024 * 1024),
          remote_odb
        ])
  """
  @spec layer([t() | cache_spec()]) :: {:ok, t()} | {:error, Error.t()}
  def layer(layers) do
    _ = layers
    NotImplementedError.stub!(:"ODB.layer/1", "Milestone 2")
  end

  @typedoc "A cache layer descriptor produced by `cache/1`."
  @opaque cache_spec :: {:cache, keyword()}

  @doc """
  A writable in-memory cache layer for `layer/1`: stores verified, inflated
  object payloads under byte, entry, and per-object caps. Never disk.

  ## Options

    * `:max_bytes` (required) — total payload ceiling.
    * `:max_entries` — entry-count ceiling.
    * `:max_object_bytes` — per-object cap; larger objects bypass the cache.
  """
  @spec cache(keyword()) :: cache_spec()
  def cache(opts), do: {:cache, opts}

  @doc """
  Reads one object's header (type and size) without its payload.
  """
  @spec header(t(), OID.t(), keyword()) ::
          {:ok, ObjectHeader.t()} | {:error, Error.t()}
  def header(odb, oid, opts \\ []) do
    _ = {odb, oid, opts}
    NotImplementedError.stub!(:"ODB.header/3", "Milestone 1")
  end

  @doc """
  Reads one object, bounded. `max_bytes:` caps the inflated payload;
  exceeding it returns `:object_too_large` rather than a partial object.
  """
  @spec read(t(), OID.t(), keyword()) :: {:ok, Object.t()} | {:error, Error.t()}
  def read(odb, oid, opts \\ []) do
    _ = {odb, oid, opts}
    NotImplementedError.stub!(:"ODB.read/3", "Milestone 1")
  end

  @doc """
  Reads a batch of objects, bounded by `max_total_bytes:`. Returns a map of
  OID to object or `:not_found` — per-object misses are results, not
  errors.
  """
  @spec read_many(t(), [OID.t()], keyword()) ::
          {:ok, %{OID.t() => Object.t() | :not_found}} | {:error, Error.t()}
  def read_many(odb, oids, opts \\ []) do
    _ = {odb, oids, opts}
    NotImplementedError.stub!(:"ODB.read_many/3", "Milestone 1")
  end
end
