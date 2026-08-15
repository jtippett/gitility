defmodule Gitility.ODB.Provider do
  @moduledoc false

  use GenServer

  require Logger

  alias Gitility.{Native, OID}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :provider_name))
  end

  @impl GenServer
  def init(opts) do
    {backend, init_arg} = Keyword.fetch!(opts, :backend)

    case backend.init(init_arg) do
      {:ok, backend_state} ->
        native_options = %{
          request_timeout_ms: Keyword.fetch!(opts, :request_timeout),
          object_cache_bytes: Keyword.fetch!(opts, :object_cache_bytes),
          header_cache_entries: Keyword.fetch!(opts, :header_cache_entries),
          negative_ttl_ms: Keyword.fetch!(opts, :negative_ttl)
        }

        case Native.provider_store_new(Keyword.fetch!(opts, :hash), native_options) do
          {:ok, {store, hash}} ->
            {:ok,
             %{
               backend: backend,
               backend_state: backend_state,
               task_supervisor: Keyword.fetch!(opts, :task_supervisor),
               concurrency: Keyword.fetch!(opts, :concurrency),
               request_timeout: Keyword.fetch!(opts, :request_timeout),
               hash: hash,
               store: store,
               queue: :queue.new(),
               running: %{}
             }}

          {:error, error} ->
            {:stop, {:native_provider_store, error}}
        end

      {:error, reason} ->
        {:stop, {:backend_init, reason}}

      other ->
        {:stop, {:backend_init, {:invalid_return, other}}}
    end
  end

  @impl GenServer
  def handle_call(:handle, _from, state) do
    {:reply, {:ok, {state.store, state.hash, self()}}, state}
  end

  def handle_call(:refresh, from, state) do
    if function_exported?(state.backend, :refresh, 1) do
      provider = self()
      backend = state.backend
      backend_state = state.backend_state

      case Task.Supervisor.start_child(state.task_supervisor, fn ->
             result = invoke_refresh(backend, backend_state)
             send(provider, {:gitility_provider_refresh, from, result})
           end) do
        {:ok, _pid} -> {:noreply, state}
        {:error, _reason} -> {:reply, {:error, :task_start_failed}, state}
      end
    else
      {:reply, :ok, state}
    end
  end

  @impl GenServer
  def handle_info({:gitility_provider_request, request, kind, oid_bytes}, state)
      when kind in [:header, :object, :prefetch] and is_list(oid_bytes) do
    oids = Enum.map(oid_bytes, &%OID{algorithm: state.hash, bytes: &1})
    item = {make_ref(), request, kind, oids, System.monotonic_time(:millisecond)}
    {:noreply, dispatch_or_queue(item, state)}
  end

  def handle_info({:gitility_provider_task_done, token}, state) do
    case Enum.find(state.running, fn {_monitor, entry} -> entry.token == token end) do
      nil ->
        {:noreply, state}

      {monitor, entry} ->
        Process.demonitor(monitor, [:flush])
        Process.cancel_timer(entry.timer)
        {:noreply, state |> remove_running(monitor) |> drain_queue()}
    end
  end

  def handle_info({:gitility_provider_task_timeout, token}, state) do
    case Enum.find(state.running, fn {_monitor, entry} -> entry.token == token end) do
      nil -> :ok
      {_monitor, entry} -> Process.exit(entry.pid, :kill)
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.running, monitor) do
      {nil, _running} ->
        {:noreply, state}

      {entry, running} ->
        Process.cancel_timer(entry.timer)
        {:noreply, %{state | running: running} |> drain_queue()}
    end
  end

  def handle_info({:gitility_provider_refresh, from, result}, state) do
    GenServer.reply(from, result)
    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    if function_exported?(state.backend, :terminate, 2) do
      try do
        state.backend.terminate(reason, state.backend_state)
      rescue
        exception ->
          Logger.error(
            "Gitility provider terminate callback raised: #{Exception.message(exception)}"
          )
      catch
        kind, value ->
          Logger.error("Gitility provider terminate callback #{kind}: #{inspect(value)}")
      end
    end

    :ok
  end

  defp dispatch_or_queue(item, state) when map_size(state.running) < state.concurrency do
    start_request(item, state)
  end

  defp dispatch_or_queue(item, state) do
    %{state | queue: :queue.in(item, state.queue)}
  end

  defp start_request({token, request, kind, oids, _received_at}, state) do
    provider = self()
    backend = state.backend
    backend_state = state.backend_state

    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           execute_request(request, kind, oids, backend, backend_state)
           send(provider, {:gitility_provider_task_done, token})
         end) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)

        timer =
          Process.send_after(
            self(),
            {:gitility_provider_task_timeout, token},
            state.request_timeout
          )

        entry = %{token: token, pid: pid, timer: timer}
        %{state | running: Map.put(state.running, monitor, entry)}

      {:error, reason} ->
        Logger.error("Gitility provider could not start callback task: #{inspect(reason)}")
        Native.provider_reply(request, {:error, :task_start_failed})
        state
    end
  end

  defp drain_queue(state) when map_size(state.running) >= state.concurrency, do: state

  defp drain_queue(state) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        state

      {{:value, {_token, _request, _kind, _oids, received_at} = item}, queue} ->
        state = %{state | queue: queue}

        if System.monotonic_time(:millisecond) - received_at >= state.request_timeout do
          drain_queue(state)
        else
          item |> start_request(state) |> drain_queue()
        end
    end
  end

  defp remove_running(state, monitor), do: %{state | running: Map.delete(state.running, monitor)}

  defp execute_request(request, kind, oids, backend, backend_state) do
    case invoke_callback(kind, oids, backend, backend_state) do
      {:reply, {:ok, results}} ->
        Native.provider_reply(request, {:ok, results})

      {:reply, {:error, reason}} ->
        log_backend_error(kind, reason)
        Native.provider_reply(request, {:error, :backend_error})

      :prefetch_ok ->
        :ok

      {:prefetch_error, reason} ->
        log_backend_error(:prefetch, reason)
        :ok
    end
  rescue
    exception ->
      log_backend_error(kind, {:exception, Exception.message(exception)})
      unless kind == :prefetch, do: Native.provider_reply(request, {:error, :callback_crashed})
  catch
    caught_kind, value ->
      log_backend_error(kind, {caught_kind, value})
      unless kind == :prefetch, do: Native.provider_reply(request, {:error, :callback_crashed})
  end

  defp invoke_callback(:object, oids, backend, state) do
    {:reply, backend.read_many(oids, state)}
  end

  defp invoke_callback(:header, oids, backend, state) do
    result =
      if function_exported?(backend, :read_headers, 2) do
        backend.read_headers(oids, state)
      else
        # Keep full objects intact across the native boundary. Core verifies
        # their hashes before deriving headers or populating either cache.
        backend.read_many(oids, state)
      end

    {:reply, result}
  end

  defp invoke_callback(:prefetch, oids, backend, state) do
    if function_exported?(backend, :prefetch, 2) do
      case backend.prefetch(oids, state) do
        :ok -> :prefetch_ok
        {:error, reason} -> {:prefetch_error, reason}
        other -> {:prefetch_error, {:invalid_return, other}}
      end
    else
      :prefetch_ok
    end
  end

  defp invoke_refresh(backend, state) do
    case backend.refresh(state) do
      :ok ->
        :ok

      {:error, reason} ->
        log_backend_error(:refresh, reason)
        {:error, :backend_error}

      other ->
        log_backend_error(:refresh, {:invalid_return, other})
        {:error, :backend_error}
    end
  rescue
    exception ->
      log_backend_error(:refresh, {:exception, Exception.message(exception)})
      {:error, :backend_error}
  catch
    kind, value ->
      log_backend_error(:refresh, {kind, value})
      {:error, :backend_error}
  end

  defp log_backend_error(kind, reason) do
    # The real callback reason is useful locally, but is never handed to core
    # or exposed in a Gitility.Error returned to the query caller.
    Logger.error("Gitility provider #{kind} callback failed: #{inspect(reason)}")
  end
end
