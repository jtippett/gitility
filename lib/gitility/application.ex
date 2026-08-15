defmodule Gitility.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    Supervisor.start_link([],
      strategy: :one_for_one,
      name: Gitility.Supervisor,
      max_restarts: 10,
      max_seconds: 60
    )
  end
end
