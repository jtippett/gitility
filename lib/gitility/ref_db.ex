defmodule Gitility.RefDB do
  @moduledoc """
  Reference databases: mutable names for immutable objects.

  Refs are deliberately separate from object storage. An ODB plus a commit
  ID answers every snapshot query; a RefDB exists only to turn names into
  object IDs at snapshot time.

  Provider stores have the same two-shape lifecycle as `Gitility.ODB`:
  `start_link/1` returns the provider supervisor and `handle/1` obtains the
  immutable query handle bound to that provider process.
  """

  alias Gitility.{Error, Limits, Native, NativeSupport, Page, Ref, RefQuery, RefTarget}
  alias Gitility.RefDB.Provider

  @typedoc "An opaque handle to a reference store."
  @opaque t :: %__MODULE__{
            kind: :local | :provider,
            ref: term(),
            runtime: Gitility.Runtime.t()
          }

  @enforce_keys [:kind, :ref, :runtime]
  defstruct [:kind, :ref, :runtime, :provider, :supervisor]

  @doc """
  Starts a supervised provider-backed RefDB.

  Backend `init/1` runs in the caller before the supervision tree starts.
  Callbacks run concurrently under the configured cap, have independent
  request deadlines, and are sanitized before failures cross the boundary.

  ## Options

    * `:backend` (required) — `{module, init_arg}`.
    * `:name` — optional provider-supervisor registered name.
    * `:runtime` — attached runtime (default: shared).
    * `:concurrency` — max concurrent callbacks (default `8`).
    * `:request_timeout` — callback deadline in milliseconds (default `15_000`).
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    opts =
      Keyword.validate!(opts,
        backend: nil,
        name: nil,
        runtime: :default,
        concurrency: 8,
        request_timeout: 15_000
      )

    name = opts[:name] || {:global, {Gitility.RefDB.Provider.Supervisor, make_ref()}}

    with :ok <- validate_backend(opts[:backend]),
         :ok <- validate_name(name),
         {:ok, concurrency} <- positive_option(opts[:concurrency], :concurrency),
         {:ok, request_timeout} <-
           positive_option(opts[:request_timeout], :request_timeout),
         {:ok, runtime, _runtime_resource} <- NativeSupport.runtime_and_resource(opts[:runtime]),
         {:ok, supervisor} <-
           Gitility.RefDB.Provider.Supervisor.start_link(
             backend: opts[:backend],
             name: name,
             concurrency: concurrency,
             request_timeout: request_timeout,
             runtime: runtime
           ) do
      {:ok, supervisor}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> provider_start_error(reason)
    end
  end

  @doc "Returns the query handle owned by a running provider supervisor."
  @spec handle(pid() | GenServer.name()) :: {:ok, t()} | {:error, Error.t()}
  def handle(pid_or_name) do
    with {:ok, supervisor} <- resolve_provider_supervisor(pid_or_name),
         {:ok, {resource, provider, runtime, _request_timeout}} <-
           provider_handle(supervisor) do
      {:ok,
       %__MODULE__{
         kind: :provider,
         ref: resource,
         runtime: runtime,
         provider: provider,
         supervisor: supervisor
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
      type: :supervisor
    }
  end

  @doc """
  Resolves a full raw-byte reference name. Symbolic chains are followed with
  a hard 16-hop limit. A missing name returns `{:ok, :not_found}`; it is not
  a backend error.

  Local resolution is one logical store call and retains one packed-refs
  snapshot across the entire chain. Provider resolution is deliberately
  per-hop atomic: each symbolic hop is a separate backend `resolve/2` call.
  A provider that requires a chain-coherent answer must resolve symbolics
  internally and return a direct target, which is also the recommended shape
  for API-backed providers. An optional provider `resolve_following/2`
  callback may be considered after 1.0; it is not part of the 0.x contract.
  """
  @spec resolve(t(), binary(), keyword()) ::
          {:ok, RefTarget.t() | :not_found} | {:error, Error.t()}
  def resolve(ref_db, name, opts \\ [])

  def resolve(%__MODULE__{ref: resource, runtime: runtime}, name, opts)
      when is_binary(name) do
    opts = Keyword.validate!(opts, limits: nil)
    limits = opts[:limits] || Limits.new()
    limits_map = NativeSupport.limits_map!(limits)

    NativeSupport.await_sync(
      fn ->
        NativeSupport.submit_job(runtime, :ref_resolve, fn runtime_resource ->
          Native.job_submit_ref_resolve(runtime_resource, resource, name, limits_map)
        end)
      end,
      limits.timeout_ms,
      :ref_resolve
    )
  end

  def resolve(%__MODULE__{}, _name, _opts) do
    raise ArgumentError, "reference name must be a binary"
  end

  @doc """
  Starts an asynchronous reference resolution job.

  This has the same per-hop provider semantics and options as `resolve/3`.
  """
  @spec async_resolve(t(), binary(), keyword()) ::
          {:ok, Gitility.Job.t()} | {:error, Error.t()}
  def async_resolve(ref_db, name, opts \\ [])

  def async_resolve(%__MODULE__{ref: resource, runtime: runtime}, name, opts)
      when is_binary(name) do
    opts = Keyword.validate!(opts, limits: nil)
    limits = opts[:limits] || Limits.new()
    limits_map = NativeSupport.limits_map!(limits)

    NativeSupport.submit_job(runtime, :ref_resolve, fn runtime_resource ->
      Native.job_submit_ref_resolve(runtime_resource, resource, name, limits_map)
    end)
  end

  def async_resolve(%__MODULE__{}, _name, _opts) do
    raise ArgumentError, "reference name must be a binary"
  end

  @doc """
  Lists refs in deterministic byte order as one `Gitility.Page`.

  Local cursors store the raw full name of the last emitted ref and resume at
  names strictly greater in byte order. Ref mutation between pages therefore
  cannot tear either individual page: newly inserted earlier names are simply
  behind the continuation, while later names remain eligible. Provider
  backends own their continuation state and must provide the same page-level
  ordering guarantee.

  Local cursors are intentionally repository-agnostic: their identity digest
  is all zeroes, so a cursor can resume the same prefix and hash algorithm in
  another repository. This is useful for caller-controlled repository swaps;
  Gitility does not claim the two namespaces contain the same refs.

  A prefix uses the local store's prefixed iterator. Cursor resume still skips
  refs up to the last emitted name within that prefix on every page, so the
  per-page resume cost is linear in the already-consumed prefix.

  Listing deliberately returns unfollowed targets: a symbolic ref remains
  symbolic. This differs from `git for-each-ref`, which resolves symbolic
  targets. Call `resolve/3` when a resolved identity is required.

  Full ref names are capped at 4096 bytes on both local and provider paths.
  Longer local entries are skipped with a warning. This deliberately differs
  from Git, which accepts larger names; names over 4 KiB are treated as hostile
  input.

  Resolve-only providers return `:unsupported_operation`.
  """
  @spec list(t(), RefQuery.t() | keyword(), keyword()) ::
          {:ok, Page.t(Ref.t())} | {:error, Error.t()}
  def list(ref_db, query \\ %RefQuery{}, opts \\ [])

  def list(%__MODULE__{ref: resource, runtime: runtime}, query, opts) do
    opts = Keyword.validate!(opts, limits: nil)
    limits = opts[:limits] || Limits.new()
    limits_map = NativeSupport.limits_map!(limits)
    query = normalize_query!(query)

    with {:ok, cursor} <- decode_cursor(query.cursor) do
      NativeSupport.await_sync(
        fn ->
          NativeSupport.submit_job(runtime, :ref_list, fn runtime_resource ->
            Native.job_submit_ref_list(
              runtime_resource,
              resource,
              query.prefix,
              query.limit,
              cursor,
              limits_map
            )
          end)
        end,
        limits.timeout_ms,
        :ref_list
      )
    end
  end

  @doc """
  Starts an asynchronous reference-listing job.

  Query normalization, cursor validation, and limits match `list/3`.
  """
  @spec async_list(t(), RefQuery.t() | keyword(), keyword()) ::
          {:ok, Gitility.Job.t()} | {:error, Error.t()}
  def async_list(ref_db, query \\ %RefQuery{}, opts \\ [])

  def async_list(%__MODULE__{ref: resource, runtime: runtime}, query, opts) do
    opts = Keyword.validate!(opts, limits: nil)
    limits = opts[:limits] || Limits.new()
    limits_map = NativeSupport.limits_map!(limits)
    query = normalize_query!(query)

    with {:ok, cursor} <- decode_cursor(query.cursor) do
      NativeSupport.submit_job(runtime, :ref_list, fn runtime_resource ->
        Native.job_submit_ref_list(
          runtime_resource,
          resource,
          query.prefix,
          query.limit,
          cursor,
          limits_map
        )
      end)
    end
  end

  @doc "Refreshes a provider backend. Missing optional refresh is a no-op."
  @spec refresh(t()) :: :ok | {:error, Error.t()}
  def refresh(%__MODULE__{kind: :provider, provider: provider}) do
    try do
      case GenServer.call(provider, :refresh, 30_000) do
        :ok ->
          :ok

        {:error, :provider_timeout} ->
          {:error,
           Error.new(:provider_timeout, "ref provider refresh deadline expired",
             retryable: true,
             operation: :ref_refresh
           )}

        {:error, _reason} ->
          {:error,
           Error.new(:backend_error, "ref provider refresh failed",
             retryable: true,
             operation: :ref_refresh
           )}
      end
    catch
      :exit, _reason -> provider_down(:ref_refresh)
    end
  end

  def refresh(%__MODULE__{kind: :local}), do: :ok

  defp normalize_query!(%RefQuery{} = query) do
    validate_query!(query)
    query
  end

  defp normalize_query!(query) when is_list(query) do
    query
    |> Keyword.validate!(prefix: nil, limit: 100, cursor: nil)
    |> then(&struct!(RefQuery, &1))
    |> validate_query!()
  end

  defp normalize_query!(_query) do
    raise ArgumentError, "reference query must be a Gitility.RefQuery struct or keyword list"
  end

  defp validate_query!(%RefQuery{prefix: prefix, limit: limit, cursor: cursor} = query) do
    unless is_nil(prefix) or is_binary(prefix) do
      raise ArgumentError, "reference query prefix must be a binary or nil"
    end

    unless is_integer(limit) and limit > 0 do
      raise ArgumentError, "reference query limit must be a positive integer"
    end

    unless is_nil(cursor) or is_binary(cursor) do
      raise ArgumentError, "reference query cursor must be a binary or nil"
    end

    query
  end

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(cursor) do
    case Base.url_decode64(cursor, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, Error.new(:invalid_cursor, "cursor is not valid unpadded base64url")}
    end
  end

  defp validate_backend({module, _init_arg}) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :init, 1) and
         function_exported?(module, :resolve, 2) do
      :ok
    else
      NativeSupport.invalid_argument(
        ":backend module must implement Gitility.RefDB.Backend init/1 and resolve/2"
      )
    end
  end

  defp validate_backend(_backend) do
    NativeSupport.invalid_argument(":backend must be a {module, init_arg} tuple")
  end

  defp validate_name(name) when is_atom(name), do: :ok
  defp validate_name({:global, _term}), do: :ok
  defp validate_name({:via, module, _term}) when is_atom(module), do: :ok

  defp validate_name(_name) do
    NativeSupport.invalid_argument(
      ":name must be an atom, {:global, term}, or {:via, module, term}"
    )
  end

  defp positive_option(value, _name) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp positive_option(_value, name) do
    NativeSupport.invalid_argument(":#{name} must be a positive integer")
  end

  defp provider_handle(supervisor) do
    provider =
      supervisor
      |> Supervisor.which_children()
      |> Enum.find_value(fn
        {Provider, pid, :worker, _modules} when is_pid(pid) -> pid
        _child -> nil
      end)

    if provider, do: GenServer.call(provider, :handle), else: {:error, :provider_not_started}
  catch
    :exit, reason -> {:error, reason}
  end

  defp resolve_provider_supervisor(pid) when is_pid(pid) do
    if Process.alive?(pid), do: {:ok, pid}, else: {:error, :provider_down}
  end

  defp resolve_provider_supervisor(name) do
    with :ok <- validate_name(name),
         pid when is_pid(pid) <- GenServer.whereis(name) do
      {:ok, pid}
    else
      {:error, %Error{} = error} -> {:error, error}
      _missing -> {:error, :provider_down}
    end
  catch
    :exit, _reason -> {:error, :provider_down}
  end

  defp provider_handle_error, do: provider_down(:ref_handle)

  defp provider_down(operation) do
    {:error,
     Error.new(:provider_down, "ref provider process is down",
       retryable: true,
       operation: operation
     )}
  end

  defp provider_start_error({:backend_init, reason}), do: {:error, reason}

  defp provider_start_error({:backend_init_raised, message}),
    do: {:error, {:backend_init_raised, message}}

  defp provider_start_error(reason) do
    {:error,
     Error.new(:backend_error, "ref provider failed to start",
       operation: :ref_provider_start,
       cause: inspect(reason, limit: 20, printable_limit: 256)
     )}
  end
end
