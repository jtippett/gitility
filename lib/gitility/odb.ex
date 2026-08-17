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
    * **PackFetch** — immutable packs eagerly hydrated through a
      `Gitility.ODB.RangeBackend` (`Gitility.ODB.PackFetch.start_link/1`).
    * **Layered** — read-through composition (`layer/1`), typically a
      `cache/1` layer in front of a remote store.

  Layers are queried in order and must share a runtime and hash algorithm.
  A successful remote read populates earlier writable cache layers. Disk
  caching is never implicit — there is no disk anywhere in this module.

  Process-backed stores have a two-shape API: `start_link/1` starts and
  returns the provider supervisor pid, and `handle/1` obtains the opaque ODB
  handle used by queries. Value stores such as `from_objects/2` start no
  process and return their handle directly.
  """

  alias Gitility.{
    Error,
    Limits,
    Native,
    NativeSupport,
    Object,
    ObjectHeader,
    OID
  }

  alias Gitility.ODB.Provider

  @typedoc """
  An opaque handle to an object store.

  Carries the store's kind, its native or process reference, its hash
  algorithm, and its runtime affiliation (used to enforce
  `:runtime_mismatch` at composition time). Match on it only via this
  module's functions.
  """
  @opaque t :: %__MODULE__{
            kind: :local | :static | :provider | :pack_fetch | :layered,
            ref: term(),
            hash: OID.algorithm(),
            runtime: Gitility.Runtime.t()
          }

  @enforce_keys [:kind, :ref, :hash, :runtime]
  defstruct [
    :kind,
    :ref,
    :hash,
    :runtime,
    :provider,
    :supervisor,
    :limits,
    providers: [],
    contains_cache: false
  ]

  @default_layer_cache_entries 100_000

  @doc """
  Starts a provider-backed ODB serving objects through a
  `Gitility.ODB.Backend` implementation.

  Returns the provider supervisor pid. Obtain the query handle with
  `handle/1`. The provider is a valid child — use `{Gitility.ODB, opts}` in a
  supervision tree. Pass a stable `name:` when supervised so other processes
  can call `handle(name)`; direct starts without a name receive an internal
  generated name. Gitility monitors provider exit, fails pending requests
  with `:provider_down`, and cancels jobs that cannot progress.

  A provider handle is permanently bound to the exact provider process that
  created it. If that process dies, pending and future reads through the old
  handle fail with retryable `:provider_down`; a restarted provider owns a new
  native handle, so callers must obtain a fresh ODB by calling `start_link/1`
  again.

  ## Options

    * `:backend` (required) — `{module, init_arg}`.
    * `:name` — provider-supervisor registered name (supports via tuples).
      When omitted, Gitility generates a private global name.
    * `:hash` — `:sha1` (default) or `:sha256`.
    * `:verify` — `:always` (default): recompute and check every object ID.
    * `:concurrency` — max concurrent backend callbacks (default `8`).
    * `:request_timeout` — per-batch deadline in ms (default `15_000`).
      Expiry returns retryable `:provider_timeout`; the job's overall deadline
      remains `:timeout` and wins when both expire together.
    * `:runtime` — the `Gitility.Runtime` to attach to (default: shared).
    * `:cache` — provider-side cache: `object_bytes:`, `header_entries:`,
      `negative_ttl:` (ms; missing objects may arrive later in shallow or
      incrementally populated stores, so negatives expire fast).

  ## Example

      {:ok, provider} =
        Gitility.ODB.start_link(
          name: MyApp.GitObjects,
          backend: {MyCompany.GitObjectBackend, backend_options},
          concurrency: 8,
          cache: [object_bytes: 128 * 1024 * 1024]
        )

      {:ok, odb} = Gitility.ODB.handle(provider)
      {:ok, snapshot} = Gitility.Snapshot.open(odb, commit_oid)

  In a supervision tree, retrieve the same handle by its stable name:

      children = [
        {Gitility.ODB,
         name: MyApp.GitObjects,
         backend: {MyCompany.GitObjectBackend, backend_options}}
      ]

      {:ok, _supervisor} = Supervisor.start_link(children, strategy: :one_for_one)
      {:ok, odb} = Gitility.ODB.handle(MyApp.GitObjects)
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    opts =
      Keyword.validate!(opts,
        backend: nil,
        name: nil,
        hash: :sha1,
        verify: :always,
        concurrency: 8,
        request_timeout: 15_000,
        runtime: :default,
        cache: []
      )

    name = opts[:name] || {:global, {Gitility.ODB.Provider.Supervisor, make_ref()}}

    with :ok <- validate_provider_backend(opts[:backend]),
         :ok <- validate_provider_name(name),
         :ok <- validate_provider_hash(opts[:hash]),
         :ok <- validate_provider_verify(opts[:verify]),
         {:ok, concurrency} <- positive_provider_option(opts[:concurrency], :concurrency),
         {:ok, request_timeout} <-
           positive_provider_option(opts[:request_timeout], :request_timeout),
         {:ok, cache} <- validate_provider_cache(opts[:cache]),
         {:ok, runtime, _runtime_resource} <- NativeSupport.runtime_and_resource(opts[:runtime]),
         {:ok, supervisor} <-
           Gitility.ODB.Provider.Supervisor.start_link(
             backend: opts[:backend],
             name: name,
             hash: opts[:hash],
             concurrency: concurrency,
             request_timeout: request_timeout,
             runtime: runtime,
             object_cache_bytes: cache[:object_bytes],
             header_cache_entries: cache[:header_entries],
             negative_ttl: cache[:negative_ttl]
           ) do
      {:ok, supervisor}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> provider_start_error(reason)
    end
  end

  @doc """
  Returns the opaque ODB handle owned by a running provider supervisor.

  Accepts either the pid returned by `start_link/1` or its configured `:name`.
  A handle is permanently bound to the current provider process; obtain a new
  handle after a provider restart.
  """
  @spec handle(pid() | GenServer.name()) :: {:ok, t()} | {:error, Error.t()}
  def handle(pid_or_name) do
    with {:ok, supervisor} <- resolve_provider_supervisor(pid_or_name),
         {:ok,
          {resource, hash, provider, runtime, _request_timeout, callback_kind, packfetch_limits}} <-
           provider_handle(supervisor) do
      kind = if callback_kind == :range, do: :pack_fetch, else: :provider

      {:ok,
       %__MODULE__{
         kind: kind,
         ref: resource,
         hash: hash,
         runtime: runtime,
         provider: provider,
         supervisor: supervisor,
         limits: packfetch_limits,
         providers: [provider]
       }}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, _reason} -> provider_handle_error()
    end
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name) || {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [opts]},
      # start_link/1 returns a supervisor: declare it so a parent supervisor
      # gives the tree its own orderly shutdown (shutdown: :infinity) instead
      # of a worker's 5 s deadline.
      type: :supervisor
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

  Header queries are answered by the cache when the object is resident,
  otherwise by the first layer that has it, without fetching payloads.
  Header queries never populate the cache.

  A layer error fails the read and carries its zero-based position in
  `error.details.layer`; layers are not failover replicas. A hit before a
  failing layer still succeeds. Compose caches with one authoritative store;
  use supervision/retry at the store level for availability.

      {:ok, odb} =
        Gitility.ODB.layer([
          Gitility.ODB.cache(max_bytes: 128 * 1024 * 1024),
          remote_odb
        ])
  """
  @spec layer([t() | cache_spec()]) :: {:ok, t()} | {:error, Error.t()}
  def layer(layers) when is_list(layers) do
    with {:ok, stores, cache, cache_index} <- validate_layers(layers),
         :ok <- validate_layer_hashes(stores),
         :ok <- validate_layer_runtimes(stores),
         [%__MODULE__{hash: hash, runtime: runtime} | _] <- stores do
      case Native.layered_store_new(
             Enum.map(stores, & &1.ref),
             cache,
             cache_index
           ) do
        {:ok, {resource, ^hash}} ->
          {:ok,
           %__MODULE__{
             kind: :layered,
             ref: resource,
             hash: hash,
             runtime: runtime,
             providers: layer_providers(stores),
             contains_cache: cache != nil
           }}

        {:error, error} ->
          {:error, NativeSupport.nif_error(error, :odb_layer)}
      end
    end
  end

  def layer(_layers), do: raise(ArgumentError, "layers must be provided as a list")

  @typedoc """
  A cache layer descriptor produced by `cache/1`.

  The descriptor is opaque by convention, but Elixir cannot enforce the
  tuple boundary. Raw `{:cache, opts}` tuples are accepted and validated
  identically.
  """
  @opaque cache_spec :: {:cache, keyword()}

  @doc """
  A writable in-memory cache layer for `layer/1`: stores verified, inflated
  object payloads under byte, entry, and per-object caps. Bytes enter only
  after a lower store's `verify: :always` path. Because process memory is not
  a new trust boundary, release-build hits are served without re-hashing.
  Debug builds verify on insertion and serving as a tripwire, not as the
  cache's trust guarantee. Never disk.

  ## Options

    * `:max_bytes` (required) — total payload ceiling.
    * `:max_entries` — entry-count ceiling (default `100_000`).
    * `:max_object_bytes` — per-object cap (default: `max_bytes`); larger
      objects bypass the cache and remain readable from lower layers.
  """
  @spec cache(keyword()) :: cache_spec()
  def cache(opts) do
    validate_layer_cache_types!(opts)
    {:cache, opts}
  end

  @doc """
  Asks a provider backend to refresh availability state, bounded by its
  `request_timeout`, then clears the native negative cache only after the
  callback succeeds. A layered handle fans this out to every provider it
  contains, then refreshes every native layer. Verified positive cache entries
  remain valid because Git object IDs are immutable. A layered refresh returns
  `:ok` only when at least one layer accepts refresh; when every layer refuses,
  it returns `:unsupported_operation`.

  Local and static handles return `:unsupported_operation` in this milestone.
  """
  @spec refresh(t()) :: :ok | {:error, Error.t()}
  def refresh(%__MODULE__{kind: :pack_fetch, ref: resource, runtime: runtime, limits: limits}) do
    limits = limits || Limits.new()
    limits_map = NativeSupport.limits_map!(limits)

    case NativeSupport.await_sync(
           fn ->
             NativeSupport.submit_job(runtime, :packfetch_refresh, fn runtime_resource ->
               Native.packfetch_refresh(runtime_resource, resource, limits_map)
             end)
           end,
           limits.timeout_ms,
           :packfetch_refresh
         ) do
      {:ok, _stats} -> :ok
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def refresh(%__MODULE__{kind: :provider, ref: resource, provider: provider}) do
    with :ok <- provider_refresh(provider),
         {:ok, nil} <- native_provider_refresh(resource) do
      :ok
    end
  end

  def refresh(%__MODULE__{kind: :layered, ref: resource, providers: providers}) do
    with :ok <- refresh_layer_providers(providers),
         {:ok, nil} <- native_provider_refresh(resource) do
      :ok
    end
  end

  def refresh(%__MODULE__{}) do
    {:error,
     Error.new(
       :unsupported_operation,
       "refresh is supported only for provider, PackFetch, and layered object stores",
       operation: :odb_refresh
     )}
  end

  @doc "Returns the last completed PackFetch hydration or refresh statistics."
  @spec stats(t()) :: {:ok, map()} | {:error, Error.t()}
  def stats(%__MODULE__{kind: :pack_fetch, ref: resource}) do
    case Native.packfetch_stats(resource) do
      {:ok, stats} -> {:ok, stats}
      {:error, error} -> {:error, NativeSupport.nif_error(error, :odb_stats)}
    end
  end

  def stats(%__MODULE__{}) do
    {:error,
     Error.new(:unsupported_operation, "store does not expose hydration statistics",
       operation: :odb_stats
     )}
  end

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

  defp validate_layers(layers) do
    cache_specs = Enum.filter(layers, &match?({:cache, _opts}, &1))
    stores = Enum.filter(layers, &match?(%__MODULE__{}, &1))

    cond do
      Enum.any?(layers, fn layer ->
        not match?(%__MODULE__{}, layer) and not match?({:cache, _opts}, layer)
      end) ->
        raise ArgumentError, "each layer must be an ODB handle or cache descriptor"

      length(cache_specs) > 1 ->
        layer_error("one cache layer per composition in 0.x")

      Enum.any?(stores, &match?(%__MODULE__{kind: :layered, contains_cache: true}, &1)) ->
        layer_error("nested cache layers are not supported in 0.x")

      stores == [] ->
        layer_error("a layered object database requires at least one store")

      cache_specs == [] ->
        {:ok, stores, nil, nil}

      true ->
        cache_position = Enum.find_index(layers, &match?({:cache, _opts}, &1))

        stores_before =
          layers |> Enum.take(cache_position) |> Enum.count(&match?(%__MODULE__{}, &1))

        if stores_before >= length(stores) do
          layer_error("a cache layer must precede at least one object store")
        else
          [{:cache, opts}] = cache_specs

          case validate_layer_cache(opts) do
            {:ok, cache} -> {:ok, stores, cache, stores_before}
            {:error, %Error{} = error} -> {:error, error}
          end
        end
    end
  end

  defp validate_layer_cache(opts) when is_list(opts) do
    validate_layer_cache_types!(opts)

    if not Keyword.has_key?(opts, :max_bytes) do
      layer_error("cache :max_bytes is required")
    else
      max_bytes = Keyword.fetch!(opts, :max_bytes)

      max_entries =
        Keyword.get(opts, :max_entries, @default_layer_cache_entries)

      max_object_bytes =
        if Keyword.has_key?(opts, :max_object_bytes) do
          Keyword.fetch!(opts, :max_object_bytes)
        else
          max_bytes
        end

      with :ok <- validate_positive_cache_option(max_bytes, :max_bytes),
           :ok <- validate_positive_cache_option(max_entries, :max_entries),
           :ok <- validate_positive_cache_option(max_object_bytes, :max_object_bytes) do
        {:ok,
         %{
           max_bytes: max_bytes,
           max_entries: max_entries,
           max_object_bytes: max_object_bytes
         }}
      end
    end
  end

  defp validate_layer_cache(_opts),
    do: raise(ArgumentError, "cache options must be a keyword list")

  defp validate_layer_cache_types!(opts) when is_list(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "cache options must be a keyword list"
    end

    keys = Keyword.keys(opts)

    if length(keys) != MapSet.size(MapSet.new(keys)) do
      raise ArgumentError, "cache options must not contain duplicate keys"
    end

    Keyword.validate!(opts,
      max_bytes: nil,
      max_entries: @default_layer_cache_entries,
      max_object_bytes: nil
    )

    Enum.each(opts, fn {name, value} -> validate_cache_option!(value, name) end)
  end

  defp validate_layer_cache_types!(_opts),
    do: raise(ArgumentError, "cache options must be a keyword list")

  defp validate_cache_option!(value, _name) when is_integer(value), do: value

  defp validate_cache_option!(_value, name) do
    raise ArgumentError, "cache :#{name} must be an integer"
  end

  defp validate_positive_cache_option(value, _name) when is_integer(value) and value > 0,
    do: :ok

  defp validate_positive_cache_option(_value, name),
    do: layer_error("cache :#{name} must be a positive integer")

  defp validate_layer_hashes([%__MODULE__{hash: hash} | stores]) do
    if Enum.all?(stores, &(&1.hash == hash)) do
      :ok
    else
      {:error,
       Error.new(:hash_mismatch, "layered object stores use different hash algorithms",
         operation: :odb_layer
       )}
    end
  end

  defp validate_layer_runtimes([%__MODULE__{runtime: runtime} | stores]) do
    if Enum.all?(stores, &(&1.runtime == runtime)) do
      :ok
    else
      {:error,
       Error.new(:runtime_mismatch, "layered object stores use different runtimes",
         operation: :odb_layer
       )}
    end
  end

  defp layer_providers(stores) do
    stores
    |> Enum.flat_map(fn
      %__MODULE__{kind: :provider, provider: provider} when is_pid(provider) -> [provider]
      %__MODULE__{kind: :pack_fetch, provider: provider} when is_pid(provider) -> [provider]
      %__MODULE__{kind: :layered, providers: providers} when is_list(providers) -> providers
      %__MODULE__{} -> []
    end)
    |> Enum.uniq()
  end

  defp refresh_layer_providers(providers) do
    Enum.reduce(providers, :ok, fn provider, first_result ->
      case provider_refresh(provider) do
        :ok -> first_result
        {:error, %Error{} = error} when first_result == :ok -> {:error, error}
        {:error, %Error{}} -> first_result
      end
    end)
  end

  defp layer_error(message) do
    {:error, Error.new(:invalid_argument, message, operation: :odb_layer)}
  end

  defp validate_provider_backend({module, _init_arg}) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :init, 1) and
         function_exported?(module, :read_many, 2) do
      :ok
    else
      NativeSupport.invalid_argument(
        ":backend module must implement Gitility.ODB.Backend init/1 and read_many/2"
      )
    end
  end

  defp validate_provider_backend(_backend) do
    NativeSupport.invalid_argument(":backend must be a {module, init_arg} tuple")
  end

  defp validate_provider_name(nil), do: :ok
  defp validate_provider_name(name) when is_atom(name), do: :ok
  defp validate_provider_name({:global, _term}), do: :ok
  defp validate_provider_name({:via, module, _term}) when is_atom(module), do: :ok

  defp validate_provider_name(_name) do
    NativeSupport.invalid_argument(
      ":name must be an atom, {:global, term}, {:via, module, term}, or nil"
    )
  end

  defp validate_provider_hash(hash) when hash in [:sha1, :sha256], do: :ok

  defp validate_provider_hash(_hash) do
    NativeSupport.invalid_argument(":hash must be :sha1 or :sha256")
  end

  defp validate_provider_verify(:always), do: :ok

  defp validate_provider_verify(_verify) do
    NativeSupport.invalid_argument("only verify: :always is supported")
  end

  defp positive_provider_option(value, _name) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp positive_provider_option(_value, name) do
    NativeSupport.invalid_argument(":#{name} must be a positive integer")
  end

  defp validate_provider_cache(cache) when is_list(cache) do
    cache = Keyword.validate!(cache, object_bytes: 0, header_entries: 0, negative_ttl: 0)

    Enum.reduce_while([:object_bytes, :header_entries, :negative_ttl], {:ok, cache}, fn key,
                                                                                        result ->
      if is_integer(cache[key]) and cache[key] >= 0 do
        {:cont, result}
      else
        {:halt, NativeSupport.invalid_argument(":cache #{key}: must be a non-negative integer")}
      end
    end)
  end

  defp validate_provider_cache(_cache) do
    NativeSupport.invalid_argument(":cache must be a keyword list")
  end

  defp provider_handle(supervisor) do
    provider =
      supervisor
      |> Supervisor.which_children()
      |> Enum.find_value(fn
        {Provider, pid, :worker, _modules} when is_pid(pid) -> pid
        _child -> nil
      end)

    if provider do
      GenServer.call(provider, :handle)
    else
      {:error, :provider_not_started}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp resolve_provider_supervisor(pid) when is_pid(pid) do
    if Process.alive?(pid), do: {:ok, pid}, else: {:error, :provider_down}
  end

  defp resolve_provider_supervisor(name) do
    with :ok <- validate_provider_name(name),
         pid when is_pid(pid) <- GenServer.whereis(name) do
      {:ok, pid}
    else
      {:error, %Error{} = error} -> {:error, error}
      _missing -> {:error, :provider_down}
    end
  catch
    :exit, _reason -> {:error, :provider_down}
  end

  defp provider_handle_error do
    {:error,
     Error.new(:provider_down, "provider process is down",
       retryable: true,
       operation: :odb_handle
     )}
  end

  # backend.init/1 now runs in the caller before the tree starts, so its
  # failure arrives directly; the failed_to_start_child shape is kept for the
  # remaining in-child failures.
  defp provider_start_error({:backend_init, reason}), do: {:error, reason}

  defp provider_start_error({:backend_init_raised, message}),
    do: {:error, {:backend_init_raised, message}}

  defp provider_start_error(
         {:shutdown, {:failed_to_start_child, Provider, {:backend_init, reason}}}
       ),
       do: {:error, reason}

  defp provider_start_error(reason) do
    {:error,
     Error.new(
       :backend_error,
       "provider failed to start",
       retryable: true,
       operation: :odb_start_link,
       details: %{reason: sanitize_start_reason(reason)}
     )}
  end

  defp sanitize_start_reason(_reason), do: :provider_start_failed

  defp native_provider_refresh(resource) do
    case Native.provider_refresh(resource) do
      {:ok, {}} -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:error, error} -> {:error, NativeSupport.nif_error(error, :odb_refresh)}
    end
  end

  defp provider_refresh(provider) do
    try do
      case GenServer.call(provider, :refresh, :infinity) do
        :ok ->
          :ok

        {:error, :provider_timeout} ->
          {:error,
           Error.new(:provider_timeout, "provider request deadline expired",
             retryable: true,
             operation: :odb_refresh
           )}

        {:error, _reason} ->
          {:error,
           Error.new(:backend_error, "provider callback failed",
             retryable: true,
             operation: :odb_refresh
           )}
      end
    catch
      :exit, _reason ->
        {:error,
         Error.new(:provider_down, "provider process is down",
           retryable: true,
           operation: :odb_refresh
         )}
    end
  end
end
