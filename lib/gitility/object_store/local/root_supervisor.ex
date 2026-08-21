defmodule Gitility.ObjectStore.Local.RootSupervisor do
  @moduledoc false

  use Supervisor

  def start_link(_opts), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl Supervisor
  def init(:ok) do
    Supervisor.init(
      [
        {Registry, keys: :unique, name: Gitility.ObjectStore.Local.Registry},
        Gitility.ObjectStore.Local.Supervisor
      ],
      strategy: :rest_for_one
    )
  end
end
