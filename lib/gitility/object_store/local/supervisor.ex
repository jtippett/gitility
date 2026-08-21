defmodule Gitility.ObjectStore.Local.Supervisor do
  @moduledoc false

  use DynamicSupervisor

  alias Gitility.ObjectStore.Local.Server

  @registry Gitility.ObjectStore.Local.Registry

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc false
  @spec server(Path.t()) :: {:ok, pid()} | {:error, term()}
  def server(root) when is_binary(root) do
    case Registry.lookup(@registry, root) do
      [{pid, _value}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(__MODULE__, {Server, root}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, {:already_present, _child}} -> lookup_after_race(root)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp lookup_after_race(root) do
    case Registry.lookup(@registry, root) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :server_start_race}
    end
  end
end
