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

  alias Gitility.{
    Error,
    Limits,
    Native,
    NativeSupport,
    NotImplementedError,
    Object,
    ObjectHeader,
    OID
  }

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
    opts = Keyword.validate!(opts, hash: :sha1, verify: :always, runtime: :default)
    hash = opts[:hash]

    cond do
      hash not in [:sha1, :sha256] ->
        NativeSupport.invalid_argument(":hash must be :sha1 or :sha256")

      opts[:verify] != :always ->
        NativeSupport.invalid_argument("only verify: :always is supported")

      true ->
        native_objects = Enum.map(objects, &native_object!/1)

        with {:ok, runtime, _runtime_resource} <-
               NativeSupport.runtime_and_resource(opts[:runtime]) do
          case Native.static_from_objects(native_objects, hash) do
            {:ok, {resource, ^hash}} ->
              {:ok, %__MODULE__{kind: :static, ref: resource, hash: hash, runtime: runtime}}

            {:error, error} ->
              {:error, NativeSupport.nif_error(error, :odb_from_objects)}
          end
        end
    end
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
  @spec header(t(), OID.t() | String.t(), keyword()) ::
          {:ok, ObjectHeader.t()} | {:error, Error.t()}
  def header(%__MODULE__{ref: resource, runtime: runtime} = _odb, oid, opts \\ []) do
    opts = Keyword.validate!(opts, limits: nil)
    limits = opts[:limits] || Limits.new()
    limits_map = NativeSupport.limits_map!(limits)

    with {:ok, oid} <- NativeSupport.parse_oid(oid),
         {:ok, header} <-
           NativeSupport.await_sync(
             fn ->
               NativeSupport.submit_job(runtime, :odb_header, fn runtime_resource ->
                 Native.job_submit_odb_header(runtime_resource, resource, oid.bytes, limits_map)
               end)
             end,
             limits.timeout_ms,
             :odb_header
           ) do
      {:ok, %ObjectHeader{oid: oid, type: header.kind, size: header.size}}
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @doc """
  Reads one object, bounded. `max_bytes:` caps the inflated payload;
  exceeding it returns `:object_too_large` rather than a partial object. If
  `limits.max_object_bytes` is lower, that hard limit becomes the effective
  cap and an oversized object returns `:object_too_large` naming
  `:max_object_bytes` in the error details.
  """
  @spec read(t(), OID.t() | String.t(), keyword()) ::
          {:ok, Object.t()} | {:error, Error.t()}
  def read(%__MODULE__{ref: resource, runtime: runtime} = _odb, oid, opts \\ []) do
    opts = Keyword.validate!(opts, max_bytes: nil, limits: nil)
    limits = opts[:limits] || Limits.new()
    limits_map = NativeSupport.limits_map!(limits)

    with {:ok, max_bytes} <- effective_cap(opts[:max_bytes], limits.max_object_bytes, :max_bytes),
         {:ok, oid} <- NativeSupport.parse_oid(oid),
         {:ok, object} <-
           NativeSupport.await_sync(
             fn ->
               NativeSupport.submit_job(runtime, :odb_read, fn runtime_resource ->
                 Native.job_submit_odb_read(
                   runtime_resource,
                   resource,
                   oid.bytes,
                   max_bytes,
                   limits_map
                 )
               end)
             end,
             limits.timeout_ms,
             :odb_read
           ) do
      {:ok, %Object{oid: oid, type: object.kind, data: object.data}}
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @doc """
  Reads a batch of objects, bounded by `max_total_bytes:`. Returns a map of
  OID to object or `:not_found` — per-object misses are results, not
  errors. The batch cap (`max_total_bytes:`) returns `:result_too_large`;
  exhaustion of the overall `Limits.max_total_object_bytes` budget returns
  `:budget_exceeded`.
  """
  @spec read_many(t(), [OID.t() | String.t()], keyword()) ::
          {:ok, %{OID.t() => Object.t() | :not_found}} | {:error, Error.t()}
  def read_many(%__MODULE__{ref: resource, hash: hash, runtime: runtime} = _odb, oids, opts \\ []) do
    opts = Keyword.validate!(opts, max_total_bytes: nil, limits: nil)
    limits = opts[:limits] || Limits.new()
    limits_map = NativeSupport.limits_map!(limits)

    with {:ok, max_total_bytes} <-
           effective_cap(
             opts[:max_total_bytes],
             limits.max_total_object_bytes,
             :max_total_bytes
           ),
         {:ok, parsed_oids} <- parse_oids(oids),
         {:ok, objects} <-
           NativeSupport.await_sync(
             fn ->
               NativeSupport.submit_job(runtime, :odb_read_many, fn runtime_resource ->
                 Native.job_submit_odb_read_many(
                   runtime_resource,
                   resource,
                   Enum.map(parsed_oids, & &1.bytes),
                   max_total_bytes,
                   limits_map
                 )
               end)
             end,
             limits.timeout_ms,
             :odb_read_many
           ) do
      {:ok,
       Map.new(objects, fn
         {oid_bytes, :not_found} ->
           {NativeSupport.oid_from_bytes(hash, oid_bytes), :not_found}

         {oid_bytes, object} ->
           oid = NativeSupport.oid_from_bytes(hash, oid_bytes)
           {oid, %Object{oid: oid, type: object.kind, data: object.data}}
       end)}
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp native_object!(%Object{oid: oid, type: type, data: data})
       when type in [:commit, :tree, :blob, :tag] and is_binary(data) do
    oid_bytes =
      case oid do
        nil -> nil
        %OID{bytes: bytes} -> bytes
        _ -> raise ArgumentError, "object :oid must be a Gitility.OID or nil"
      end

    {oid_bytes, type, data}
  end

  defp native_object!(object) do
    raise ArgumentError,
          "expected a Gitility.Object with a valid type and binary data, got: #{inspect(object)}"
  end

  defp effective_cap(nil, hard_limit, _name), do: {:ok, hard_limit}

  defp effective_cap(value, hard_limit, _name)
       when is_integer(value) and value >= 0,
       do: {:ok, min(value, hard_limit)}

  defp effective_cap(_value, _hard_limit, name),
    do: raise(ArgumentError, ":#{name} must be an integer or nil")

  defp parse_oids(oids) when is_list(oids) do
    Enum.reduce_while(oids, {:ok, []}, fn oid, {:ok, parsed} ->
      case NativeSupport.parse_oid(oid) do
        {:ok, value} -> {:cont, {:ok, [value | parsed]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp parse_oids(_oids),
    do: NativeSupport.invalid_argument("object IDs must be provided as a list")
end
