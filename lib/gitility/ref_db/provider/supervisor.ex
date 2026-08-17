defmodule Gitility.RefDB.Provider.Supervisor do
  @moduledoc """
  Internal reference-provider supervision tree.

  Child order is an invariant: the watchdog starts before the provider, so
  reverse-order shutdown stops the provider (and wakes native waiters) while
  the watchdog is still alive. The provider synchronously installs its watch
  during `init/1`, closing the corresponding startup window.
  """

  use Supervisor

  alias Gitility.RefDB.Provider

  def start_link(opts) do
    id = make_ref()
    supervisor_name = Keyword.fetch!(opts, :name)
    provider_name = {:global, {Provider, id}}
    task_name = {:global, {Provider, id, TaskSupervisor}}
    watchdog_name = {:global, {Provider, id, Gitility.RefDB.Watchdog}}
    {backend, init_arg} = Keyword.fetch!(opts, :backend)

    # Run backend init/1 HERE, in the caller, before any process exists. A
    # backend init failure must return as {:error, reason} without killing the
    # caller, but the caller must still be the actual OTP parent of the
    # supervisor. A bootstrap starter process breaks orderly parent shutdown:
    # the tree sees the real caller's exit as an unrelated linked-process
    # death and may never stop. Up-front init preserves both contracts.
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
    exception -> {:error, {:backend_init_raised, Exception.message(exception)}}
  catch
    kind, value -> {:error, {:backend_init_raised, "#{kind}: #{safe_inspect(value)}"}}
  end

  defp safe_inspect(term), do: inspect(term, limit: 20, printable_limit: 256)

  @impl Supervisor
  def init(opts) do
    provider_name = Keyword.fetch!(opts, :provider_name)
    task_name = Keyword.fetch!(opts, :task_supervisor)
    watchdog_name = Keyword.fetch!(opts, :watchdog)

    children = [
      Supervisor.child_spec({Task.Supervisor, name: task_name}, id: TaskSupervisor),
      Supervisor.child_spec(
        {Gitility.RefDB.Watchdog,
         name: watchdog_name, provider: provider_name, task_supervisor: task_name},
        id: Gitility.RefDB.Watchdog
      ),
      Supervisor.child_spec({Provider, opts}, id: Provider)
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
