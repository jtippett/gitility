defmodule Gitility.ObjectStore.Local.Supervisor do
  @moduledoc false

  use DynamicSupervisor

  alias Gitility.ObjectStore.Local.Server

  @registry Gitility.ObjectStore.Local.Registry
  @start_race_attempts 20

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc false
  @spec server(Path.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def server(root, opts \\ []) when is_binary(root) and is_list(opts),
    do: server(root, opts, @start_race_attempts)

  defp server(root, opts, attempts_left) do
    case Registry.lookup(@registry, root) do
      [{pid, _value}] when is_pid(pid) ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(__MODULE__, {Server, {root, opts}}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} when is_pid(pid) -> {:ok, pid}
          {:error, {:already_present, _child}} -> retry_after_race(root, opts, attempts_left)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp retry_after_race(_root, _opts, 0), do: {:error, :server_start_race}

  defp retry_after_race(root, opts, attempts_left) do
    Process.sleep(1)
    server(root, opts, attempts_left - 1)
  end
end
