defmodule Gitility.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children =
      [Gitility.ObjectStore.Local.RootSupervisor] ++
        s3_finch_children() ++ [Gitility.Fetch.Supervisor]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Gitility.Supervisor,
      max_restarts: 10,
      max_seconds: 60
    )
  end

  defp s3_finch_children do
    if Code.ensure_loaded?(Finch) do
      [
        {Finch,
         name: Gitility.ObjectStore.S3.Finch,
         pools: %{
           default: [conn_opts: [transport_opts: [timeout: 20_000]]]
         }}
      ]
    else
      []
    end
  end
end
