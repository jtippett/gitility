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
    {backend, init_arg} = Keyword.fetch!(opts, :backend)

    # Run the backend's init/1 HERE, in the caller, before any process
    # exists. A backend init failure must come back as {:error, reason} and
    # must not kill the caller — but a child that fails init inside
    # Supervisor.start_link exits the (linked, non-trapping) caller with
    # {:shutdown, ...}, which is standard OTP. An earlier version isolated
    # that with a bootstrap "starter" process that started the tree and then
    # handed the link over. That broke a more fundamental contract: the tree's
    # OTP parent was the starter, not the caller, so a parent supervisor's
    # :shutdown exit signal (Supervisor.stop, stop_supervised!, orderly app
    # shutdown) was ignored as a mere linked-process death and the tree never
    # stopped — masked as a 5 s worker timeout until the child_spec was
    # correctly typed :supervisor (shutdown: :infinity), at which point every
    # supervised stop hung forever. Validating init up front keeps both
    # properties: the caller starts the tree directly and IS its parent.
    case run_backend_init(backend, init_arg) do
      {:ok, backend_state} ->
        configured_opts =
          opts
          |> Keyword.put(:provider_name, provider_name)
          |> Keyword.put(:task_supervisor, task_name)
          |> Keyword.put(:watchdog, watchdog_name)
          |> Keyword.put(:backend_state, backend_state)

        Supervisor.start_link(__MODULE__, configured_opts, name: supervisor_name)

      {:error, _reason} = error ->
        error
    end
  end

  defp run_backend_init(backend, init_arg) do
    case backend.init(init_arg) do
      {:ok, backend_state} -> {:ok, backend_state}
      {:error, reason} -> {:error, {:backend_init, reason}}
      other -> {:error, {:backend_init, {:invalid_return, other}}}
    end
  rescue
    exception -> {:error, {:backend_init, {:raised, Exception.message(exception)}}}
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
