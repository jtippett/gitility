defmodule Gitility.Fetch.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl Supervisor
  def init(:ok) do
    Supervisor.init([Gitility.Fetch.Locks],
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 5
    )
  end
end
