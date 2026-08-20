defmodule Gitility.Runtime do
  @moduledoc """
  An explicit, supervisable query runtime: one bounded native worker pool.

  Every expensive Gitility operation executes as a job on a runtime's
  Rust-owned worker threads — never on BEAM schedulers. A shared default
  runtime starts lazily with conservative defaults, so small callers need
  zero configuration:

    * `workers: max(System.schedulers_online() div 2, 1)`
    * `max_queue: 1_000`
    * `max_jobs_per_owner: 16`
    * `shutdown_join_timeout_ms: 5_000`

  The generated child spec gives shutdown `shutdown_join_timeout_ms + 2_000`
  milliseconds. That margin lets the bounded native worker-join phase finish
  before a supervisor is allowed to kill the GenServer running `terminate/2`.
  Unnamed runtimes receive unique child IDs, so more than one can be placed in
  the same supervision tree without an explicit `:name`.

  Gitility's library supervisor permits 10 restarts in 60 seconds. This gives
  its leaf runtime room to recover from a short crash burst; a persistently
  crashing runtime still stops the application according to normal OTP
  restart-intensity semantics.

  Tuning means starting a named runtime in your own supervision tree — the
  Finch/NimblePool convention, and the only shape that lets two subsystems
  with different latency profiles stop sharing a queue:

      children = [
        {Gitility.Runtime,
         name: MyApp.GitRuntime,
         workers: 8,
         max_queue: 500,
         max_jobs_per_owner: 16}
      ]

  Every root store (`Gitility.Repository.open/2`, the provider configured by
  `Gitility.ODB.start_link/1` and retrieved with `Gitility.ODB.handle/1`, or
  `Gitility.ODB.from_objects/2`) accepts `runtime:` and defaults to the shared
  instance. Snapshots and jobs inherit the runtime of the store they came
  from; stores composed together must share one runtime, enforced at
  composition time with `:runtime_mismatch`.

  ## Backpressure

  Queue admission can refuse with `{:error, %Gitility.Error{code: :busy}}`
  carrying `retry_after_ms` in `details`. Per-owner ceilings keep one
  process from monopolizing a runtime; internal parallelism (search, diff)
  stays within a job's assigned permit count. Asynchronous functions surface
  `:busy` immediately. Synchronous query wrappers wait `retry_after_ms` and
  retry admission once before returning `:busy`.
  """

  use GenServer

  require Logger

  alias Gitility.{Error, Native}

  @default_name Gitility.DefaultRuntime
  @default_key {__MODULE__, :default}
  @fetch_default_name Gitility.FetchRuntime
  @fetch_default_key {__MODULE__, :fetch_default}
  @default_shutdown_join_timeout_ms 5_000
  @supervisor_shutdown_margin_ms 2_000

  @typedoc "A runtime identifier: a registered name or pid."
  @type t :: atom() | pid()

  @typedoc false
  @type option ::
          {:name, atom()}
          | {:workers, pos_integer()}
          | {:max_queue, pos_integer()}
          | {:max_jobs_per_owner, pos_integer()}
          | {:shutdown_join_timeout_ms, pos_integer()}

  @doc """
  Starts a runtime instance. See the moduledoc for options.
  """
  @spec start_link([option()]) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    opts =
      Keyword.validate!(opts,
        name: nil,
        workers: default_workers(),
        max_queue: 1_000,
        max_jobs_per_owner: 16,
        shutdown_join_timeout_ms: @default_shutdown_join_timeout_ms
      )

    name = opts[:name]

    if not is_nil(name) and not is_atom(name) do
      raise ArgumentError, ":name must be an atom or nil"
    end

    config = %{
      workers: positive_option!(opts, :workers),
      max_queue: positive_option!(opts, :max_queue),
      max_jobs_per_owner: positive_option!(opts, :max_jobs_per_owner),
      shutdown_join_timeout_ms: positive_option!(opts, :shutdown_join_timeout_ms)
    }

    case name do
      nil -> GenServer.start_link(__MODULE__, {config, nil})
      name -> GenServer.start_link(__MODULE__, {config, name}, name: name)
    end
  end

  @doc false
  @spec child_spec([option()]) :: Supervisor.child_spec()
  def child_spec(opts) do
    shutdown_join_timeout_ms =
      opts
      |> Keyword.get(:shutdown_join_timeout_ms, @default_shutdown_join_timeout_ms)
      |> positive_value!(:shutdown_join_timeout_ms)

    %{
      id: Keyword.get(opts, :name) || {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [opts]},
      # The supervisor must outlast CoreRuntime's bounded worker-join phase.
      shutdown: shutdown_join_timeout_ms + @supervisor_shutdown_margin_ms
    }
  end

  @doc """
  The shared default runtime, started lazily on first use.
  """
  @spec default() :: t() | {:error, Error.t()}
  def default do
    named_default(@default_name, @default_key, [])
  end

  @doc false
  @spec fetch_default() :: t() | {:error, Error.t()}
  def fetch_default do
    named_default(
      @fetch_default_name,
      @fetch_default_key,
      workers: 2,
      max_queue: 32,
      max_jobs_per_owner: 4
    )
  end

  defp named_default(name, key, opts) do
    case :persistent_term.get(key, nil) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: pid, else: start_named_default(name, key, opts)

      _ ->
        start_named_default(name, key, opts)
    end
  end

  @doc "Returns a runtime's current native admission and lifecycle counters."
  @spec stats(t() | :default) :: map() | {:error, Error.t()}
  def stats(runtime \\ :default)

  def stats(:default) do
    case default() do
      runtime when is_pid(runtime) -> stats(runtime)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def stats(runtime) do
    with {:ok, resource} <- resource(runtime) do
      Native.runtime_stats(resource)
    end
  end

  @doc false
  @spec resource(t()) :: {:ok, term()} | {:error, Error.t()}
  def resource(runtime) when is_pid(runtime) or is_atom(runtime) do
    try do
      GenServer.call(runtime, :resource)
    catch
      :exit, _reason ->
        {:error, Error.new(:cancelled, "runtime shut down")}
    end
  end

  def resource(_runtime),
    do: {:error, Error.new(:invalid_argument, "expected a runtime name or pid")}

  @impl GenServer
  def init({config, name}) do
    Process.flag(:trap_exit, true)
    resource = Native.runtime_start(config)

    if key = default_key(name) do
      :persistent_term.put(key, self())
    end

    {:ok, %{resource: resource, default_key: default_key(name)}}
  end

  @impl GenServer
  def handle_call(:resource, _from, state), do: {:reply, {:ok, state.resource}, state}

  @impl GenServer
  def terminate(_reason, state) do
    if state.default_key && :persistent_term.get(state.default_key, nil) == self() do
      :persistent_term.erase(state.default_key)
    end

    %{detached_workers: detached_workers, last_detach_reason: reason} =
      Native.runtime_shutdown(state.resource)

    warn_if_detached_workers(detached_workers, reason)

    :ok
  end

  @doc false
  def warn_if_detached_workers(0, _reason), do: :ok

  def warn_if_detached_workers(detached_workers, reason)
      when is_integer(detached_workers) and detached_workers > 0 do
    suffix = if reason, do: ": #{reason}", else: ""

    Logger.warning("Gitility runtime shutdown detached #{detached_workers} worker(s)#{suffix}")
  end

  defp start_named_default(name, key, opts) do
    child = {__MODULE__, Keyword.put(opts, :name, name)}

    try do
      case Supervisor.start_child(Gitility.Supervisor, child) do
        {:ok, pid} ->
          pid

        {:error, {:already_started, pid}} ->
          pid

        {:error, :already_present} ->
          Process.whereis(name) || retry_named_default(name, key)

        {:error, {:already_present, _child}} ->
          Process.whereis(name) || retry_named_default(name, key)

        {:error, _reason} ->
          runtime_supervisor_error()
      end
    catch
      :exit, _reason -> runtime_supervisor_error()
    end
  end

  defp retry_named_default(name, key) do
    await_named_default(name, key, System.monotonic_time(:millisecond) + 5_000)
  end

  defp await_named_default(name, key, deadline) do
    case :persistent_term.get(key, nil) do
      pid when is_pid(pid) ->
        pid

      _ ->
        case Process.whereis(name) do
          pid when is_pid(pid) ->
            pid

          nil ->
            if System.monotonic_time(:millisecond) >= deadline do
              runtime_supervisor_error()
            else
              receive do
              after
                1 -> await_named_default(name, key, deadline)
              end
            end
        end
    end
  end

  defp default_workers, do: max(div(System.schedulers_online(), 2), 1)

  defp default_key(@default_name), do: @default_key
  defp default_key(@fetch_default_name), do: @fetch_default_key
  defp default_key(_name), do: nil

  defp runtime_supervisor_error do
    {:error, Error.new(:cancelled, "gitility runtime supervisor is not running", retryable: true)}
  end

  defp positive_option!(opts, key) do
    opts |> Keyword.fetch!(key) |> positive_value!(key)
  end

  defp positive_value!(value, _key) when is_integer(value) and value > 0, do: value

  defp positive_value!(_value, key) do
    raise ArgumentError, ":#{key} must be a positive integer"
  end
end
