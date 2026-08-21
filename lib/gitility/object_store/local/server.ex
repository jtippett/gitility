defmodule Gitility.ObjectStore.Local.Server do
  @moduledoc false

  use GenServer

  @registry Gitility.ObjectStore.Local.Registry
  @idle_timeout 60_000
  @version_age_seconds 60 * 60
  @pointer_regex ~r/\A[0-9a-f]{64}\z/
  @current_temp_regex ~r/\Acurrent\.tmp-[0-9a-f]{32}\z/
  @key_temp_regex ~r/\Akey\.tmp-[0-9a-f]{32}\z/

  def start_link(root) when is_binary(root) do
    start_link({root, []})
  end

  def start_link({root, opts}) when is_binary(root) and is_list(opts) do
    GenServer.start_link(__MODULE__, {root, opts}, name: name(root))
  end

  @doc false
  @spec name(Path.t()) :: {:via, Registry, {module(), Path.t()}}
  def name(root), do: {:via, Registry, {@registry, root}}

  def child_spec(root) when is_binary(root), do: child_spec({root, []})

  def child_spec({root, _opts} = start_arg) when is_binary(root) do
    %{
      id: {__MODULE__, root},
      start: {__MODULE__, :start_link, [start_arg]},
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
  def init(root) when is_binary(root), do: init({root, []})

  def init({root, opts}) do
    objects = Path.join(root, "objects")

    with {:ok, idle_timeout} <- idle_timeout(opts),
         :ok <- ensure_objects_directory(objects) do
      state = %{
        root: root,
        objects: objects,
        pins: %{},
        holds: %{},
        monitors: %{},
        idle_timeout: idle_timeout
      }

      {:ok, state, idle_timeout}
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
          {:reply, {:ok, {version, meta}}, state, state.idle_timeout}

        {:error, reason} ->
          {:reply, {:error, reason}, state, state.idle_timeout}
      end
    else
      {:reply, {:error, {:adapter, :bad_return}}, state, state.idle_timeout}
    end
  end

  def handle_call({:unpin, version}, {holder, _tag}, state) do
    {:reply, :ok, remove_pin(state, version, holder), state.idle_timeout}
  end

  def handle_call({:hold, ref}, {holder, _tag}, state) when is_reference(ref) do
    if Map.has_key?(state.holds, ref) do
      {:reply, {:error, {:adapter, :bad_return}}, state, state.idle_timeout}
    else
      state = add_hold(state, ref, holder)
      {:reply, :ok, state, state.idle_timeout}
    end
  end

  def handle_call({:hold, _ref}, _from, state) do
    {:reply, {:error, {:adapter, :bad_return}}, state, state.idle_timeout}
  end

  def handle_call({:release, ref}, {holder, _tag}, state) when is_reference(ref) do
    {:reply, :ok, remove_hold(state, ref, holder), state.idle_timeout}
  end

  def handle_call({:release, _ref}, _from, state) do
    {:reply, :ok, state, state.idle_timeout}
  end

  def handle_call({:commit, hash, if_match, version, after_commit}, _from, state) do
    case commit(state.objects, hash, if_match, version) do
      :ok ->
        reply = run_after_commit_hook(after_commit)
        {:reply, reply, state, {:continue, {:sweep, hash}}}

      {:error, reason} ->
        {:reply, {:error, reason}, state, state.idle_timeout}
    end
  end

  def handle_call({:force_sweep, :all}, _from, state) do
    state.objects
    |> object_hashes()
    |> Enum.each(&sweep_hash(state, &1))

    {:reply, :ok, state, state.idle_timeout}
  end

  def handle_call({:force_sweep, hash}, _from, state)
      when is_binary(hash) do
    if valid_pointer?(hash) do
      sweep_hash(state, hash)
      {:reply, :ok, state, state.idle_timeout}
    else
      {:reply, {:error, {:adapter, :bad_return}}, state, state.idle_timeout}
    end
  end

  def handle_call(:debug_state, _from, state) do
    pins =
      Map.new(state.pins, fn {version, holders} ->
        {version, %{count: Enum.sum(Map.values(holders)), holders: holders}}
      end)

    debug = %{
      pins: pins,
      pin_count: total_pins(state),
      hold_count: map_size(state.holds),
      monitored_pids: Map.keys(state.monitors)
    }

    {:reply, debug, state, state.idle_timeout}
  end

  def handle_call(:pin_count, _from, state),
    do: {:reply, total_pins(state), state, state.idle_timeout}

  @impl GenServer
  def handle_continue({:sweep, hash}, state) do
    sweep_hash(state, hash)
    {:noreply, state, state.idle_timeout}
  end

  @impl GenServer
  def handle_info(:timeout, state) do
    if map_size(state.pins) == 0 and map_size(state.holds) == 0 do
      {:stop, :normal, state}
    else
      {:noreply, state, state.idle_timeout}
    end
  end

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

        holds =
          Map.reject(state.holds, fn {_ref, hold_holder} -> hold_holder == holder end)

        state = %{
          state
          | pins: pins,
            holds: holds,
            monitors: Map.delete(state.monitors, holder)
        }

        {:noreply, state, state.idle_timeout}

      _other ->
        {:noreply, state, state.idle_timeout}
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
    current = Path.join(directory, "current")

    case create_current_temp(directory, version, 3) do
      {:ok, temp} ->
        case File.rename(temp, current) do
          :ok ->
            :ok

          {:error, _reason} ->
            File.rm(temp)
            {:error, {:adapter, :io}}
        end

      {:error, _reason} ->
        {:error, {:adapter, :io}}
    end
  end

  defp create_current_temp(_directory, _version, 0), do: {:error, :collision}

  defp create_current_temp(directory, version, attempts) do
    temp = Path.join(directory, "current.tmp-#{random_hex(16)}")

    case File.write(temp, version, [:binary, :exclusive]) do
      :ok ->
        case File.chmod(temp, 0o600) do
          :ok ->
            {:ok, temp}

          {:error, reason} ->
            File.rm(temp)
            {:error, reason}
        end

      {:error, :eexist} ->
        create_current_temp(directory, version, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_current(objects, hash) do
    directory = Path.join(objects, hash)
    current = Path.join(directory, "current")

    case File.lstat(directory) do
      {:ok, %{type: :directory}} ->
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

      {:error, :enoent} ->
        {:error, :not_found}

      _other ->
        {:error, {:adapter, :io}}
    end
  end

  defp read_meta(objects, hash, version) do
    directory = Path.join([objects, hash, "v-#{version}"])
    path = Path.join(directory, "meta")

    with {:ok, %{type: :directory}} <- File.lstat(directory),
         {:ok, stat} <- File.stat(path),
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
    state |> Map.put(:pins, pins) |> monitor_holder(holder)
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

    state |> Map.put(:pins, pins) |> demonitor_inactive_holder(holder)
  end

  defp add_hold(state, ref, holder) do
    state
    |> Map.put(:holds, Map.put(state.holds, ref, holder))
    |> monitor_holder(holder)
  end

  defp remove_hold(state, ref, holder) do
    state =
      case state.holds do
        %{^ref => ^holder} -> Map.put(state, :holds, Map.delete(state.holds, ref))
        _other -> state
      end

    demonitor_inactive_holder(state, holder)
  end

  defp monitor_holder(state, holder) do
    if Map.has_key?(state.monitors, holder) do
      state
    else
      %{state | monitors: Map.put(state.monitors, holder, Process.monitor(holder))}
    end
  end

  defp demonitor_inactive_holder(state, holder) do
    if holder_active?(state, holder) do
      state
    else
      case Map.pop(state.monitors, holder) do
        {nil, _monitors} ->
          state

        {monitor, monitors} ->
          Process.demonitor(monitor, [:flush])
          %{state | monitors: monitors}
      end
    end
  end

  defp holder_active?(state, holder) do
    Enum.any?(state.pins, fn {_version, holders} -> Map.has_key?(holders, holder) end) or
      Enum.any?(state.holds, fn {_ref, hold_holder} -> hold_holder == holder end)
  end

  defp total_pins(state) do
    Enum.reduce(state.pins, 0, fn {_version, holders}, total ->
      total + Enum.sum(Map.values(holders))
    end)
  end

  defp sweep_hash(state, hash) do
    directory = Path.join(state.objects, hash)

    with {:ok, %{type: :directory}} <- File.lstat(directory),
         {:ok, current} <- current_for_sweep(directory),
         {:ok, entries} <- File.ls(directory) do
      Enum.each(entries, &sweep_entry(state, directory, current, &1))
    else
      _error -> :ok
    end
  end

  defp sweep_entry(state, directory, current, "v-" <> version = entry) do
    with true <- valid_pointer?(version),
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
  end

  defp sweep_entry(_state, directory, _current, entry) do
    with true <- random_temp?(entry),
         path = Path.join(directory, entry),
         {:ok, stat} <- File.lstat(path, time: :posix),
         true <- stat.type == :regular,
         true <- old_enough?(stat.mtime) do
      File.rm(path)
    else
      _other -> :ok
    end
  end

  defp random_temp?(entry) do
    Regex.match?(@current_temp_regex, entry) or Regex.match?(@key_temp_regex, entry)
  end

  defp current_for_sweep(directory) do
    case File.read(Path.join(directory, "current")) do
      {:ok, version} ->
        if valid_pointer?(version), do: {:ok, version}, else: {:error, :invalid_pointer}

      {:error, :enoent} ->
        {:ok, nil}

      {:error, _reason} ->
        {:error, :unreadable_pointer}
    end
  end

  defp object_hashes(objects) do
    with {:ok, %{type: :directory}} <- File.lstat(objects),
         {:ok, entries} <- File.ls(objects) do
      Enum.filter(entries, fn entry ->
        path = Path.join(objects, entry)

        valid_pointer?(entry) and
          match?({:ok, %{type: :directory}}, File.lstat(path))
      end)
    else
      _error -> []
    end
  end

  defp old_enough?(mtime) when is_integer(mtime) do
    System.system_time(:second) - mtime > @version_age_seconds
  end

  defp old_enough?(_mtime), do: false

  defp idle_timeout([]), do: {:ok, @idle_timeout}

  defp idle_timeout(idle_timeout: timeout) when is_integer(timeout) and timeout > 0,
    do: {:ok, timeout}

  defp idle_timeout(_opts), do: {:error, :invalid_options}

  defp validate_hash_and_version(hash, version) do
    if valid_pointer?(hash) and valid_pointer?(version) do
      :ok
    else
      {:error, {:adapter, :bad_return}}
    end
  end

  defp valid_pointer?(value),
    do: is_binary(value) and Regex.match?(@pointer_regex, value)

  defp ensure_objects_directory(objects) do
    case File.lstat(objects) do
      {:ok, %{type: :directory}} ->
        :ok

      {:ok, _stat} ->
        {:error, :unsafe_directory_type}

      {:error, :enoent} ->
        case File.mkdir(objects) do
          :ok ->
            case File.chmod(objects, 0o700) do
              :ok ->
                :ok

              {:error, reason} ->
                File.rmdir(objects)
                {:error, reason}
            end

          {:error, :eexist} ->
            ensure_objects_directory(objects)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_after_commit_hook(nil), do: :ok

  defp run_after_commit_hook(hook) when is_function(hook, 0) do
    try do
      case hook.() do
        :ok -> :ok
        _other -> {:error, {:transport, :closed}}
      end
    rescue
      _exception -> {:error, {:transport, :closed}}
    catch
      _kind, _reason -> {:error, {:transport, :closed}}
    end
  end

  defp random_hex(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
