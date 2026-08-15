defmodule Gitility.ODB.Provider.Supervisor do
  @moduledoc """
  Internal provider supervision tree.

  Child order is an invariant: the watchdog starts before the provider, so
  reverse-order shutdown stops the provider (and wakes native waiters) while
  the watchdog is still alive. The provider synchronously installs its watch
  during `init/1`, closing the corresponding startup window.
  """

  use Supervisor

  alias Gitility.ODB.Provider

  def start_link(opts) do
    id = make_ref()
    supervisor_name = Keyword.fetch!(opts, :name)
    provider_name = {:global, {Provider, id}}
    task_name = {:global, {Provider, id, TaskSupervisor}}
    watchdog_name = {:global, {Provider, id, Gitility.ODB.Watchdog}}
    caller = self()
    handshake = make_ref()

    configured_opts =
      opts
      |> Keyword.put(:provider_name, provider_name)
      |> Keyword.put(:task_supervisor, task_name)
      |> Keyword.put(:watchdog, watchdog_name)

    # Isolate child-init exits until Supervisor.start_link has a result. On
    # success the caller links before this bootstrap process releases its own
    # link, preserving normal start_link semantics without letting a backend
    # init failure kill the caller instead of returning {:error, reason}.
    starter =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        case Supervisor.start_link(__MODULE__, configured_opts, name: supervisor_name) do
          {:ok, supervisor} ->
            send(caller, {handshake, {:ok, supervisor}, self()})

            receive do
              {^handshake, :caller_linked} -> Process.unlink(supervisor)
            after
              5_000 -> Supervisor.stop(supervisor)
            end

          {:error, reason} ->
            send(caller, {handshake, {:error, reason}, self()})
        end
      end)

    receive do
      {^handshake, {:ok, supervisor}, ^starter} ->
        Process.link(supervisor)
        send(starter, {handshake, :caller_linked})
        {:ok, supervisor}

      {^handshake, {:error, reason}, ^starter} ->
        {:error, reason}
    after
      5_000 ->
        Process.exit(starter, :kill)
        {:error, :timeout}
    end
  end

  @impl Supervisor
  def init(opts) do
    provider_name = Keyword.fetch!(opts, :provider_name)
    task_name = Keyword.fetch!(opts, :task_supervisor)
    watchdog_name = Keyword.fetch!(opts, :watchdog)

    children = [
      Supervisor.child_spec({Task.Supervisor, name: task_name}, id: TaskSupervisor),
      Supervisor.child_spec(
        {Gitility.ODB.Watchdog,
         name: watchdog_name, provider: provider_name, task_supervisor: task_name},
        id: Gitility.ODB.Watchdog
      ),
      Supervisor.child_spec({Provider, opts}, id: Provider)
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
