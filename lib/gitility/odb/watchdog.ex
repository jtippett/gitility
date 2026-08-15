defmodule Gitility.ODB.Watchdog do
  @moduledoc false

  use GenServer

  alias Gitility.Native

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def init(opts) do
    base = %{
      provider: Keyword.fetch!(opts, :provider),
      task_supervisor: Keyword.fetch!(opts, :task_supervisor),
      monitor: nil,
      pid: nil,
      store: nil
    }

    # The provider child starts before the watchdog. Establish the monitor
    # synchronously so Supervisor.start_link cannot return a handle with an
    # uncovered provider-death window.
    case fetch_handle(base.provider) do
      {:ok, {store, _hash, pid}} ->
        {:ok, %{base | store: store, pid: pid, monitor: Process.monitor(pid)}}

      :error ->
        {:stop, :provider_not_started}
    end
  end

  @impl GenServer
  def handle_info(:rewatch, state) do
    case fetch_handle(state.provider) do
      {:ok, {store, _hash, pid}} ->
        {:noreply, %{state | store: store, pid: pid, monitor: Process.monitor(pid)}}

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
