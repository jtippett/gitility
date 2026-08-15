defmodule Gitility.ODB.Watchdog do
  @moduledoc false

  use GenServer

  alias Gitility.Native

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @impl GenServer
  def init(opts) do
    base = %{
      provider: Keyword.fetch!(opts, :provider),
      task_supervisor: Keyword.fetch!(opts, :task_supervisor),
      monitor: nil,
      pid: nil,
      store: nil
    }

    {:ok, base}
  end

  @impl GenServer
  def handle_call({:watch, pid, store}, _from, state) when is_pid(pid) do
    if state.monitor, do: Process.demonitor(state.monitor, [:flush])
    monitor = Process.monitor(pid)

    if Process.alive?(pid) do
      {:reply, :ok, %{state | store: store, pid: pid, monitor: monitor}}
    else
      Process.demonitor(monitor, [:flush])
      Native.provider_failed(store)
      {:reply, {:error, :provider_down}, %{state | store: nil, pid: nil, monitor: nil}}
    end
  end

  @impl GenServer
  def handle_info(:rewatch, state) do
    case fetch_handle(state.provider) do
      {:ok, {store, _hash, pid, _runtime, _request_timeout, _callback_kind, _limits}} ->
        monitor = Process.monitor(pid)

        if Process.alive?(pid) do
          {:noreply, %{state | store: store, pid: pid, monitor: monitor}}
        else
          Process.demonitor(monitor, [:flush])
          Native.provider_failed(store)
          Process.send_after(self(), :rewatch, 10)
          {:noreply, %{state | store: nil, pid: nil, monitor: nil}}
        end

      :error ->
        Process.send_after(self(), :rewatch, 10)
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason}, %{monitor: monitor, pid: pid} = state) do
    Native.provider_failed(state.store)
    terminate_callback_tasks(state.task_supervisor)
    Process.send_after(self(), :rewatch, 10)
    {:noreply, %{state | monitor: nil, pid: nil, store: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp fetch_handle(provider) do
    try do
      GenServer.call(provider, :handle, 100)
    catch
      :exit, _reason -> :error
    end
  end

  defp terminate_callback_tasks(task_supervisor) do
    try do
      Enum.each(Task.Supervisor.children(task_supervisor), fn pid ->
        Task.Supervisor.terminate_child(task_supervisor, pid)
      end)
    catch
      :exit, _reason -> :ok
    end
  end
end
