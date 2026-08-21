defmodule Gitility.ObjectStore.Local.Server do
  @moduledoc false

  use GenServer

  @registry Gitility.ObjectStore.Local.Registry
  @version_age_seconds 60 * 60
  @pointer_regex ~r/\A[0-9a-f]{64}\z/

  def start_link(root) when is_binary(root) do
    GenServer.start_link(__MODULE__, root, name: name(root))
  end

  @doc false
  @spec name(Path.t()) :: {:via, Registry, {module(), Path.t()}}
  def name(root), do: {:via, Registry, {@registry, root}}

  def child_spec(root) do
    %{
      id: {__MODULE__, root},
      start: {__MODULE__, :start_link, [root]},
      restart: :transient,
      type: :worker
    }
  end

  @doc false
  @spec force_sweep(pid(), binary() | :all) :: :ok | {:error, term()}
  def force_sweep(server, hash \\ :all) do
    GenServer.call(server, {:force_sweep, hash})
  end

  @doc false
  @spec debug_state(pid()) :: map()
  def debug_state(server), do: GenServer.call(server, :debug_state)

  @doc false
  @spec pin_count(pid()) :: non_neg_integer()
  def pin_count(server), do: GenServer.call(server, :pin_count)

  @doc false
  @spec pin(pid(), binary()) :: {:ok, {binary(), map()}} | {:error, term()}
  def pin(server, hash), do: GenServer.call(server, {:pin, hash})

  @doc false
  @spec unpin(pid(), binary()) :: :ok
  def unpin(server, version), do: GenServer.call(server, {:unpin, version})

  @impl GenServer
  def init(root) do
    objects = Path.join(root, "objects")

    with :ok <- File.mkdir_p(objects),
         :ok <- File.chmod(objects, 0o700) do
      {:ok, %{root: root, objects: objects, pins: %{}, monitors: %{}}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:pin, hash}, {holder, _tag}, state) do
    if valid_pointer?(hash) do
      case read_current(state.objects, hash) do
        {:ok, version, meta} ->
          state = add_pin(state, version, holder)
          {:reply, {:ok, {version, meta}}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, {:adapter, :bad_return}}, state}
    end
  end

  def handle_call({:unpin, version}, {holder, _tag}, state) do
    {:reply, :ok, remove_pin(state, version, holder)}
  end

  def handle_call({:commit, hash, if_match, version}, _from, state) do
    case commit(state.objects, hash, if_match, version) do
      :ok ->
        {:reply, :ok, state, {:continue, {:sweep, hash}}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:force_sweep, :all}, _from, state) do
    state.objects
    |> object_hashes()
    |> Enum.each(&sweep_hash(state, &1))

    {:reply, :ok, state}
  end

  def handle_call({:force_sweep, hash}, _from, state)
      when is_binary(hash) do
    if valid_pointer?(hash) do
      sweep_hash(state, hash)
      {:reply, :ok, state}
    else
      {:reply, {:error, {:adapter, :bad_return}}, state}
    end
  end

  def handle_call(:debug_state, _from, state) do
    pins =
      Map.new(state.pins, fn {version, holders} ->
        {version, %{count: Enum.sum(Map.values(holders)), holders: holders}}
      end)

    {:reply,
     %{pins: pins, pin_count: total_pins(state), monitored_pids: Map.keys(state.monitors)}, state}
  end

  def handle_call(:pin_count, _from, state), do: {:reply, total_pins(state), state}

  @impl GenServer
  def handle_continue({:sweep, hash}, state) do
    sweep_hash(state, hash)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, holder, _reason}, state) do
    case state.monitors do
      %{^holder => ^monitor} ->
        pins =
          state.pins
          |> Enum.reduce(%{}, fn {version, holders}, acc ->
            case Map.delete(holders, holder) do
              empty when map_size(empty) == 0 -> acc
              remaining -> Map.put(acc, version, remaining)
            end
          end)

        {:noreply, %{state | pins: pins, monitors: Map.delete(state.monitors, holder)}}

      _other ->
        {:noreply, state}
    end
  end

  defp commit(objects, hash, if_match, version) do
    with :ok <- validate_hash_and_version(hash, version),
         {:ok, _new_meta} <- read_meta(objects, hash, version),
         {:ok, current} <- current_for_commit(objects, hash),
         :ok <- check_precondition(current, if_match),
         :ok <- write_current(objects, hash, version) do
      :ok
    end
  end

  defp current_for_commit(objects, hash) do
    case read_current(objects, hash) do
      {:ok, version, meta} -> {:ok, {:present, version, meta}}
      {:error, :not_found} -> {:ok, :missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_precondition(:missing, :none), do: :ok

  defp check_precondition({:present, _version, _meta}, :none),
    do: {:error, :precondition_failed}

  defp check_precondition({:present, _version, %{"etag" => etag}}, etag), do: :ok
  defp check_precondition(_current, _if_match), do: {:error, :precondition_failed}

  defp write_current(objects, hash, version) do
    directory = Path.join(objects, hash)
    temp = Path.join(directory, "current.tmp")
    current = Path.join(directory, "current")

    with :ok <- write_file(temp, version, 0o600),
         :ok <- File.rename(temp, current) do
      :ok
    else
      {:error, _reason} -> {:error, {:adapter, :io}}
    end
  end

  defp read_current(objects, hash) do
    current = Path.join([objects, hash, "current"])

    case File.read(current) do
      {:ok, version} ->
        if valid_pointer?(version) do
          case read_meta(objects, hash, version) do
            {:ok, meta} -> {:ok, version, meta}
            {:error, reason} -> {:error, reason}
          end
        else
          {:error, {:adapter, :corrupt_meta}}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, _reason} ->
        {:error, {:adapter, :io}}
    end
  end

  defp read_meta(objects, hash, version) do
    path = Path.join([objects, hash, "v-#{version}", "meta"])

    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular and stat.size <= 65_536,
         {:ok, bytes} <- File.read(path),
         {:ok, meta} <- decode_meta(bytes) do
      {:ok, meta}
    else
      _other -> {:error, {:adapter, :corrupt_meta}}
    end
  end

  defp decode_meta(bytes) do
    try do
      case :erlang.binary_to_term(bytes, [:safe]) do
        %{"etag" => etag, "size" => size, "metadata" => metadata} = meta
        when map_size(meta) == 3 and is_binary(etag) and byte_size(etag) > 0 and
               is_integer(size) and size >= 0 and is_map(metadata) ->
          if Enum.all?(metadata, fn {key, value} ->
               is_binary(key) and is_binary(value)
             end) do
            {:ok, meta}
          else
            {:error, :invalid}
          end

        _other ->
          {:error, :invalid}
      end
    rescue
      _exception -> {:error, :invalid}
    catch
      _kind, _reason -> {:error, :invalid}
    end
  end

  defp add_pin(state, version, holder) do
    holders = Map.get(state.pins, version, %{})
    pins = Map.put(state.pins, version, Map.update(holders, holder, 1, &(&1 + 1)))

    monitors =
      if Map.has_key?(state.monitors, holder) do
        state.monitors
      else
        Map.put(state.monitors, holder, Process.monitor(holder))
      end

    %{state | pins: pins, monitors: monitors}
  end

  defp remove_pin(state, version, holder) do
    pins =
      case state.pins do
        %{^version => %{^holder => count} = holders} ->
          holders =
            if count == 1,
              do: Map.delete(holders, holder),
              else: Map.put(holders, holder, count - 1)

          if map_size(holders) == 0,
            do: Map.delete(state.pins, version),
            else: Map.put(state.pins, version, holders)

        _other ->
          state.pins
      end

    monitors =
      if holder_pinned?(pins, holder) do
        state.monitors
      else
        case Map.pop(state.monitors, holder) do
          {nil, monitors} ->
            monitors

          {monitor, monitors} ->
            Process.demonitor(monitor, [:flush])
            monitors
        end
      end

    %{state | pins: pins, monitors: monitors}
  end

  defp holder_pinned?(pins, holder) do
    Enum.any?(pins, fn {_version, holders} -> Map.has_key?(holders, holder) end)
  end

  defp total_pins(state) do
    Enum.reduce(state.pins, 0, fn {_version, holders}, total ->
      total + Enum.sum(Map.values(holders))
    end)
  end

  defp sweep_hash(state, hash) do
    directory = Path.join(state.objects, hash)

    current =
      case File.read(Path.join(directory, "current")) do
        {:ok, version} when byte_size(version) == 64 -> version
        _other -> nil
      end

    case File.ls(directory) do
      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          with "v-" <> version <- entry,
               true <- valid_pointer?(version),
               false <- version == current,
               false <- Map.has_key?(state.pins, version),
               path = Path.join(directory, entry),
               {:ok, stat} <- File.lstat(path, time: :posix),
               true <- stat.type == :directory,
               true <- old_enough?(stat.mtime) do
            File.rm_rf(path)
          else
            _other -> :ok
          end
        end)

      {:error, _reason} ->
        :ok
    end
  end

  defp object_hashes(objects) do
    case File.ls(objects) do
      {:ok, entries} ->
        Enum.filter(entries, fn entry ->
          path = Path.join(objects, entry)

          valid_pointer?(entry) and
            match?({:ok, %{type: :directory}}, File.lstat(path))
        end)

      {:error, _reason} ->
        []
    end
  end

  defp old_enough?(mtime) when is_integer(mtime) do
    System.system_time(:second) - mtime > @version_age_seconds
  end

  defp old_enough?(_mtime), do: false

  defp validate_hash_and_version(hash, version) do
    if valid_pointer?(hash) and valid_pointer?(version) do
      :ok
    else
      {:error, {:adapter, :bad_return}}
    end
  end

  defp valid_pointer?(value),
    do: is_binary(value) and Regex.match?(@pointer_regex, value)

  defp write_file(path, bytes, mode) do
    with :ok <- File.write(path, bytes, [:binary]),
         :ok <- File.chmod(path, mode) do
      :ok
    end
  end
end
