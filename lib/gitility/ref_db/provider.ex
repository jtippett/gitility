defmodule Gitility.RefDB.Provider do
  @moduledoc false

  use GenServer

  require Logger

  alias Gitility.{Native, Page, RefQuery}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :provider_name))
  end

  @impl GenServer
  def init(opts) do
    # Trap exits so orderly supervisor shutdown runs terminate/2. Without
    # this, the provider dies on the supervisor's exit signal without calling
    # terminate/2 at all: the ref adaptation reproduced the ODB provider's
    # direct probe at 0/100 clean stops. The watchdog remains the independent
    # waiter-wakeup path if the provider crashes instead of stopping cleanly.
    Process.flag(:trap_exit, true)
    {backend, _init_arg} = Keyword.fetch!(opts, :backend)
    # backend.init/1 already ran in the caller (see Provider.Supervisor).
    backend_state = Keyword.fetch!(opts, :backend_state)

    case Native.ref_provider_store_new(%{
           request_timeout_ms: Keyword.fetch!(opts, :request_timeout)
         }) do
      {:ok, store} ->
        state = %{
          backend: backend,
          backend_state: backend_state,
          task_supervisor: Keyword.fetch!(opts, :task_supervisor),
          concurrency: Keyword.fetch!(opts, :concurrency),
          request_timeout: Keyword.fetch!(opts, :request_timeout),
          runtime: Keyword.fetch!(opts, :runtime),
          store: store,
          queue: :queue.new(),
          running: %{},
          refreshes: %{}
        }

        case GenServer.call(
               Keyword.fetch!(opts, :watchdog),
               {:watch, self(), store},
               state.request_timeout
             ) do
          :ok -> {:ok, state}
          {:error, reason} -> {:stop, {:watchdog, reason}}
        end

      {:error, error} ->
        {:stop, {:native_ref_provider_store, error}}
    end
  end

  @impl GenServer
  def handle_call(:handle, _from, state) do
    {:reply, {:ok, {state.store, self(), state.runtime, state.request_timeout}}, state}
  end

  def handle_call(:refresh, from, state) do
    if function_exported?(state.backend, :refresh, 1) do
      provider = self()
      backend = state.backend
      backend_state = state.backend_state
      token = make_ref()

      case Task.Supervisor.start_child(
             state.task_supervisor,
             fn ->
               result = invoke_refresh(backend, backend_state)
               send(provider, {:gitility_ref_refresh_done, token, result})
             end,
             shutdown: :brutal_kill
           ) do
        {:ok, pid} ->
          monitor = Process.monitor(pid)

          timer =
            Process.send_after(
              self(),
              {:gitility_ref_refresh_timeout, token},
              state.request_timeout
            )

          entry = %{from: from, pid: pid, monitor: monitor, timer: timer}
          {:noreply, %{state | refreshes: Map.put(state.refreshes, token, entry)}}

        {:error, _reason} ->
          {:reply, {:error, :task_start_failed}, state}
      end
    else
      {:reply, :ok, state}
    end
  end

  def handle_call(message, _from, state) do
    Logger.debug("Gitility ref provider ignored unknown call: #{safe_inspect(message)}")
    {:reply, {:error, :unknown_call}, state}
  end

  @impl GenServer
  def handle_info({:gitility_ref_request, request, :resolve, name}, state)
      when is_binary(name) do
    item = {make_ref(), request, :resolve, name, System.monotonic_time(:millisecond)}
    {:noreply, dispatch_or_queue(item, state)}
  end

  def handle_info({:gitility_ref_request, request, :list, query}, state)
      when is_map(query) do
    query =
      struct!(RefQuery, %{
        prefix: Map.fetch!(query, :prefix),
        limit: Map.fetch!(query, :limit),
        cursor: encode_cursor(Map.fetch!(query, :cursor))
      })

    item = {make_ref(), request, :list, query, System.monotonic_time(:millisecond)}
    {:noreply, dispatch_or_queue(item, state)}
  end

  def handle_info({:gitility_ref_task_done, token}, state) do
    case Enum.find(state.running, fn {_monitor, entry} -> entry.token == token end) do
      nil ->
        {:noreply, state}

      {monitor, entry} ->
        Process.demonitor(monitor, [:flush])
        Process.cancel_timer(entry.timer)
        {:noreply, state |> remove_running(monitor) |> drain_queue()}
    end
  end

  def handle_info({:gitility_ref_task_timeout, token}, state) do
    case Enum.find(state.running, fn {_monitor, entry} -> entry.token == token end) do
      nil -> :ok
      {_monitor, entry} -> Process.exit(entry.pid, :kill)
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.running, monitor) do
      {nil, _running} ->
        handle_refresh_down(monitor, state)

      {entry, running} ->
        Process.cancel_timer(entry.timer)
        {:noreply, %{state | running: running} |> drain_queue()}
    end
  end

  def handle_info({:gitility_ref_refresh_done, token, result}, state) do
    case Map.pop(state.refreshes, token) do
      {nil, _refreshes} ->
        {:noreply, state}

      {entry, refreshes} ->
        Process.demonitor(entry.monitor, [:flush])
        Process.cancel_timer(entry.timer)
        GenServer.reply(entry.from, result)
        {:noreply, %{state | refreshes: refreshes}}
    end
  end

  def handle_info({:gitility_ref_refresh_timeout, token}, state) do
    case Map.pop(state.refreshes, token) do
      {nil, _refreshes} ->
        {:noreply, state}

      {entry, refreshes} ->
        Process.demonitor(entry.monitor, [:flush])
        Process.exit(entry.pid, :kill)
        GenServer.reply(entry.from, {:error, :provider_timeout})
        {:noreply, %{state | refreshes: refreshes}}
    end
  end

  def handle_info(message, state) do
    Logger.debug("Gitility ref provider ignored message: #{safe_inspect(message)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    Native.ref_provider_failed(state.store)

    if function_exported?(state.backend, :terminate, 2) do
      try do
        state.backend.terminate(reason, state.backend_state)
      rescue
        exception ->
          Logger.error(
            "Gitility ref provider terminate callback raised: #{Exception.message(exception)}"
          )
      catch
        kind, value ->
          Logger.error("Gitility ref provider terminate callback #{kind}: #{inspect(value)}")
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

  defp start_request({token, request, kind, payload, _received_at}, state) do
    provider = self()
    backend = state.backend
    backend_state = state.backend_state

    case Task.Supervisor.start_child(
           state.task_supervisor,
           fn ->
             execute_request(
               request,
               kind,
               payload,
               backend,
               backend_state
             )

             send(provider, {:gitility_ref_task_done, token})
           end,
           shutdown: :brutal_kill
         ) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)

        timer =
          Process.send_after(
            self(),
            {:gitility_ref_task_timeout, token},
            state.request_timeout
          )

        entry = %{token: token, pid: pid, timer: timer}
        %{state | running: Map.put(state.running, monitor, entry)}

      {:error, reason} ->
        Logger.error("Gitility ref provider could not start callback task: #{inspect(reason)}")
        Native.ref_provider_reply(request, {:error, :task_start_failed})
        state
    end
  end

  defp drain_queue(state) when map_size(state.running) >= state.concurrency, do: state

  defp drain_queue(state) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        state

      {{:value, {_token, _request, _kind, _payload, received_at} = item}, queue} ->
        state = %{state | queue: queue}

        if System.monotonic_time(:millisecond) - received_at >= state.request_timeout do
          drain_queue(state)
        else
          item |> start_request(state) |> drain_queue()
        end
    end
  end

  defp remove_running(state, monitor), do: %{state | running: Map.delete(state.running, monitor)}

  defp handle_refresh_down(monitor, state) do
    case Enum.find(state.refreshes, fn {_token, entry} -> entry.monitor == monitor end) do
      nil ->
        {:noreply, state}

      {token, entry} ->
        Process.cancel_timer(entry.timer)
        GenServer.reply(entry.from, {:error, :backend_error})
        {:noreply, %{state | refreshes: Map.delete(state.refreshes, token)}}
    end
  end

  defp execute_request(request, kind, payload, backend, state) do
    reply =
      case kind do
        :resolve -> backend.resolve(payload, state)
        :list -> invoke_list(backend, payload, state)
      end

    case normalize_reply(kind, reply) do
      {:ok, normalized} ->
        Native.ref_provider_reply(request, {:ok, normalized})

      {:error, :unsupported_operation} ->
        Native.ref_provider_reply(request, {:error, :unsupported_operation})

      {:error, {:invalid_cursor, cursor}} ->
        log_backend_error(kind, {:invalid_cursor, cursor})
        Native.ref_provider_reply(request, {:error, :provider_protocol_error})

      {:error, reason} ->
        log_backend_error(kind, reason)
        Native.ref_provider_reply(request, {:error, :backend_error})
    end
  rescue
    exception ->
      log_backend_error(kind, {:exception, Exception.message(exception)})
      Native.ref_provider_reply(request, {:error, :callback_crashed})
  catch
    caught_kind, value ->
      log_backend_error(kind, {caught_kind, value})
      Native.ref_provider_reply(request, {:error, :callback_crashed})
  end

  defp invoke_list(backend, query, state) do
    if function_exported?(backend, :list, 2) do
      backend.list(query, state)
    else
      {:error, :unsupported_operation}
    end
  end

  defp normalize_reply(:resolve, {:ok, target}), do: {:ok, target}

  defp normalize_reply(:list, {:ok, %Page{} = page}) do
    case decode_cursor(page.next_cursor) do
      {:ok, cursor} -> {:ok, %{page | next_cursor: cursor}}
      {:error, :invalid_cursor} -> {:error, {:invalid_cursor, page.next_cursor}}
    end
  end

  defp normalize_reply(_kind, {:error, reason}), do: {:error, reason}
  defp normalize_reply(_kind, other), do: {:error, {:invalid_return, other}}

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

  defp encode_cursor(nil), do: nil
  defp encode_cursor(cursor), do: Base.url_encode64(cursor, padding: false)

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(cursor) when is_binary(cursor) do
    case Base.url_decode64(cursor, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_cursor}
    end
  end

  defp decode_cursor(_cursor), do: {:error, :invalid_cursor}

  defp log_backend_error(kind, reason) do
    Logger.error("Gitility ref provider #{kind} callback failed: #{safe_inspect(reason)}")
  end

  defp safe_inspect(term), do: inspect(term, limit: 50, printable_limit: 256)
end
