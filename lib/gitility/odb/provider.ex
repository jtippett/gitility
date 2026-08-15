defmodule Gitility.ODB.Provider do
  @moduledoc false

  use GenServer

  require Logger

  alias Gitility.{ByteRange, Native, OID}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :provider_name))
  end

  @impl GenServer
  def init(opts) do
    # Trap exits so an orderly supervisor shutdown runs terminate/2. Without
    # this the provider dies on the supervisor's exit signal WITHOUT calling
    # terminate/2: provider_failed never fires from here (waiters hang for
    # the full request_timeout, ~10% of clean shutdowns in a 60x probe on
    # Linux — the watchdog's DOWN handler racing its own shutdown was the
    # only thing waking them) and the backend's documented terminate/2
    # never runs on clean stop (0/100 in a direct probe).
    Process.flag(:trap_exit, true)
    {backend, _init_arg} = Keyword.fetch!(opts, :backend)
    # backend.init/1 already ran in the caller (see Provider.Supervisor).
    backend_state = Keyword.fetch!(opts, :backend_state)

    callback_kind = Keyword.get(opts, :callback_kind, :odb)

    case native_store_new(callback_kind, opts) do
      {:ok, {store, hash}} ->
        state = %{
          backend: backend,
          backend_state: backend_state,
          task_supervisor: Keyword.fetch!(opts, :task_supervisor),
          concurrency: Keyword.fetch!(opts, :concurrency),
          request_timeout: Keyword.fetch!(opts, :request_timeout),
          runtime: Keyword.fetch!(opts, :runtime),
          hash: hash,
          store: store,
          callback_kind: callback_kind,
          packfetch_limits: Keyword.get(opts, :packfetch_limits),
          packfetch_cleanup_destination: Keyword.get(opts, :packfetch_cleanup_destination),
          queue: :queue.new(),
          running: %{},
          refreshes: %{}
        }

        case GenServer.call(
               Keyword.fetch!(opts, :watchdog),
               {:watch, self(), store},
               Keyword.fetch!(opts, :request_timeout)
             ) do
          :ok -> {:ok, state}
          {:error, reason} -> {:stop, {:watchdog, reason}}
        end

      {:error, error} ->
        {:stop, {:native_provider_store, error}}
    end
  end

  @impl GenServer
  def handle_call(:handle, _from, state) do
    {:reply,
     {:ok,
      {state.store, state.hash, self(), state.runtime, state.request_timeout, state.callback_kind,
       Map.get(state, :packfetch_limits)}}, state}
  end

  def handle_call(:refresh, from, state) do
    if state.callback_kind == :odb and function_exported?(state.backend, :refresh, 1) do
      provider = self()
      backend = state.backend
      backend_state = state.backend_state

      token = make_ref()

      # Callback tasks run backend code that may hang by design; waiters are
      # woken by provider_failed when the Provider stops, so at shutdown a
      # still-running callback holds nothing worth draining — kill it at once
      # instead of paying the default 5 s per hung task.
      case Task.Supervisor.start_child(
             state.task_supervisor,
             fn ->
               result = invoke_refresh(backend, backend_state)
               send(provider, {:gitility_provider_refresh_done, token, result})
             end,
             shutdown: :brutal_kill
           ) do
        {:ok, pid} ->
          monitor = Process.monitor(pid)

          timer =
            Process.send_after(
              self(),
              {:gitility_provider_refresh_timeout, token},
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
    Logger.debug("Gitility provider ignored unknown call: #{safe_inspect(message)}")
    {:reply, {:error, :unknown_call}, state}
  end

  @impl GenServer
  def handle_info({:gitility_provider_request, request, kind, oid_bytes}, state)
      when state.callback_kind == :odb and kind in [:header, :object, :prefetch] and
             is_list(oid_bytes) do
    oids = Enum.map(oid_bytes, &%OID{algorithm: state.hash, bytes: &1})
    item = {make_ref(), request, kind, oids, System.monotonic_time(:millisecond)}
    {:noreply, dispatch_or_queue(item, state)}
  end

  def handle_info({:gitility_range_request, request, :manifest, []}, state)
      when state.callback_kind == :range do
    item = {make_ref(), request, :manifest, nil, System.monotonic_time(:millisecond)}
    {:noreply, dispatch_or_queue(item, state)}
  end

  def handle_info({:gitility_range_request, request, :read_ranges, ranges}, state)
      when state.callback_kind == :range and is_list(ranges) do
    ranges = Enum.map(ranges, &struct!(ByteRange, &1))
    item = {make_ref(), request, :read_ranges, ranges, System.monotonic_time(:millisecond)}
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
        handle_refresh_down(monitor, state)

      {entry, running} ->
        Process.cancel_timer(entry.timer)
        {:noreply, %{state | running: running} |> drain_queue()}
    end
  end

  def handle_info({:gitility_provider_refresh_done, token, result}, state) do
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

  def handle_info({:gitility_provider_refresh_timeout, token}, state) do
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
    Logger.debug("Gitility provider ignored message: #{safe_inspect(message)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    # The provider starts after the watchdog and therefore stops first during
    # orderly supervisor shutdown. Wake waiters here; the watchdog remains the
    # kill/crash fallback when terminate/2 cannot run.
    Native.provider_failed(state.store)

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

    cleanup_packfetch_destination(state.packfetch_cleanup_destination)

    :ok
  end

  defp cleanup_packfetch_destination(nil), do: :ok

  defp cleanup_packfetch_destination(path) do
    case File.rm_rf(path) do
      {:ok, _removed} ->
        :ok

      {:error, reason, failed_path} ->
        Logger.error(
          "Gitility could not clean memory PackFetch destination #{inspect(failed_path)}: #{inspect(reason)}"
        )
    end
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

    # See the refresh dispatch above: hung callbacks are killed at shutdown.
    case Task.Supervisor.start_child(
           state.task_supervisor,
           fn ->
             execute_request(request, kind, payload, backend, backend_state)
             send(provider, {:gitility_provider_task_done, token})
           end,
           shutdown: :brutal_kill
         ) do
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
        provider_reply(request, kind, {:error, :task_start_failed})
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

  defp execute_request(request, kind, payload, backend, backend_state) do
    case invoke_callback(kind, payload, backend, backend_state) do
      {:reply, {:ok, results}} ->
        provider_reply(request, kind, {:ok, results})

      {:reply, {:error, reason}} ->
        log_backend_error(kind, reason)
        provider_reply(request, kind, {:error, :backend_error})

      :prefetch_ok ->
        :ok

      {:prefetch_error, reason} ->
        log_backend_error(:prefetch, reason)
        :ok
    end
  rescue
    exception ->
      log_backend_error(kind, {:exception, Exception.message(exception)})

      unless kind == :prefetch,
        do: provider_reply(request, kind, {:error, :callback_crashed})
  catch
    caught_kind, value ->
      log_backend_error(kind, {caught_kind, value})

      unless kind == :prefetch,
        do: provider_reply(request, kind, {:error, :callback_crashed})
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

  defp invoke_callback(:manifest, nil, backend, state) do
    {:reply, backend.manifest(state)}
  end

  defp invoke_callback(:read_ranges, ranges, backend, state) do
    {:reply, backend.read_ranges(ranges, state)}
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
    Logger.error("Gitility provider #{kind} callback failed: #{safe_inspect(reason)}")
  end

  defp provider_reply(request, kind, reply) when kind in [:manifest, :read_ranges] do
    Native.range_reply(request, reply)

    if Application.get_env(:gitility, :provider_test_hook) == :duplicate_reply do
      Native.range_reply(request, reply)
    end
  end

  defp provider_reply(request, _kind, reply) do
    Native.provider_reply(request, reply)

    if Application.get_env(:gitility, :provider_test_hook) == :duplicate_reply do
      Native.provider_reply(request, reply)
    end
  end

  defp native_store_new(:odb, opts) do
    native_options = %{
      request_timeout_ms: Keyword.fetch!(opts, :request_timeout),
      object_cache_bytes: Keyword.fetch!(opts, :object_cache_bytes),
      header_cache_entries: Keyword.fetch!(opts, :header_cache_entries),
      negative_ttl_ms: Keyword.fetch!(opts, :negative_ttl)
    }

    Native.provider_store_new(Keyword.fetch!(opts, :hash), native_options)
  end

  defp native_store_new(:range, opts) do
    Native.packfetch_store_new(
      Keyword.fetch!(opts, :hash),
      Keyword.fetch!(opts, :packfetch_options)
    )
  end

  defp safe_inspect(term), do: inspect(term, limit: 50, printable_limit: 256)
end
