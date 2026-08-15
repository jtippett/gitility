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

  Every root handle (`Gitility.Repository.open/2`, `Gitility.ODB.start_link/1`,
  `Gitility.ODB.from_objects/2`) accepts `runtime:` and defaults to the
  shared instance. Snapshots and jobs inherit the runtime of the store they
  came from; stores composed together must share one runtime, enforced at
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
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      # The supervisor must outlast CoreRuntime's bounded worker-join phase.
      shutdown: shutdown_join_timeout_ms + @supervisor_shutdown_margin_ms
    }
  end

  @doc """
  The shared default runtime, started lazily on first use.
  """
  @spec default() :: t()
  def default do
    case :persistent_term.get(@default_key, nil) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: pid, else: start_default()

      _ ->
        start_default()
    end
  end

  @doc "Returns a runtime's current native admission and lifecycle counters."
  @spec stats(t()) :: map() | {:error, Error.t()}
  def stats(runtime \\ default()) do
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

    if name == @default_name do
      :persistent_term.put(@default_key, self())
    end

    {:ok, %{resource: resource, default?: name == @default_name}}
  end

  @impl GenServer
  def handle_call(:resource, _from, state), do: {:reply, {:ok, state.resource}, state}

  @impl GenServer
  def terminate(_reason, state) do
    if state.default? and :persistent_term.get(@default_key, nil) == self() do
      :persistent_term.erase(@default_key)
    end

    %{detached_workers: detached_workers, last_detach_reason: reason} =
      Native.runtime_shutdown(state.resource)

    if detached_workers > 0 do
      suffix = if reason, do: ": #{reason}", else: ""

      Logger.warning(
        "Gitility runtime shutdown detached #{detached_workers} worker(s)#{suffix}"
      )
    end

    :ok
  end

  defp start_default do
    child = {__MODULE__, name: @default_name}

    case Supervisor.start_child(Gitility.Supervisor, child) do
      {:ok, pid} ->
        pid

      {:error, {:already_started, pid}} ->
        pid

      {:error, :already_present} ->
        Process.whereis(@default_name) || retry_default()

      {:error, {:already_present, _child}} ->
        Process.whereis(@default_name) || retry_default()
    end
  end

  defp retry_default do
    await_default(System.monotonic_time(:millisecond) + 5_000)
  end

  defp await_default(deadline) do
    case :persistent_term.get(@default_key, nil) do
      pid when is_pid(pid) ->
        pid

      _ ->
        case Process.whereis(@default_name) do
          pid when is_pid(pid) ->
            pid

          nil ->
            if System.monotonic_time(:millisecond) >= deadline do
              raise "default Gitility runtime failed to start"
            else
              receive do
              after
                1 -> await_default(deadline)
              end
            end
        end
    end
  end

  defp default_workers, do: max(div(System.schedulers_online(), 2), 1)

  defp positive_option!(opts, key) do
    opts |> Keyword.fetch!(key) |> positive_value!(key)
  end

  defp positive_value!(value, _key) when is_integer(value) and value > 0, do: value

  defp positive_value!(_value, key) do
    raise ArgumentError, ":#{key} must be a positive integer"
  end
end
