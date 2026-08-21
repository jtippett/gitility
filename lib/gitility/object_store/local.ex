defmodule Gitility.ObjectStore.Local do
  @moduledoc """
  Single-VM object store backed by a local directory.

  A supervised server serialises publication for each expanded root. The
  contract is intentionally per VM; this adapter does not use filesystem
  locks and is not a shared-filesystem coordination protocol.

  Keys never become path components. Each key is hashed and each successful
  write installs a new immutable version by replacing a small `current`
  pointer atomically:

      root/objects/<sha256(key)>/current
      root/objects/<sha256(key)>/v-<random>/data
      root/objects/<sha256(key)>/v-<random>/meta

  Reads pin their selected version in the per-root server. A commit therefore
  cannot invalidate an in-flight reader. After a commit, unpinned non-current
  versions older than one hour are swept. Caller or VM death can leave a
  young version directory, which a later sweep removes after the same grace
  period.
  """

  @behaviour Gitility.ObjectStore

  alias Gitility.ObjectStore.Local.{Server, Supervisor}

  @chunk_bytes 8 * 1024 * 1024
  @content_type "application/vnd.gitility.bundle"
  @hook_names [
    :after_commit,
    :before_chunk,
    :before_commit,
    :before_head,
    :before_get,
    :before_put
  ]

  @enforce_keys [:root, :server]
  defstruct [:root, :server, test_hooks: %{}]

  @type t :: %__MODULE__{root: Path.t(), server: GenServer.server(), test_hooks: map()}

  @impl true
  def init(opts) do
    with :ok <- validate_init_options(opts),
         root <- opts |> Keyword.fetch!(:root) |> Path.expand(),
         :ok <- ensure_root(root),
         {:ok, _server} <- start_server(root) do
      {:ok,
       %__MODULE__{
         root: root,
         server: Server.name(root),
         test_hooks: Keyword.get(opts, :test_hooks, %{})
       }}
    else
      {:error, {:unsupported_operation, _message}} = error -> error
      {:error, {:adapter, _reason}} = error -> error
      {:error, :invalid_options} -> {:error, :invalid_options}
      {:error, _reason} -> {:error, {:adapter, :io}}
      _other -> {:error, :invalid_options}
    end
  rescue
    _exception -> {:error, :invalid_options}
  catch
    _kind, _reason -> {:error, {:adapter, :server_unavailable}}
  end

  @impl true
  def head(%__MODULE__{} = state, key, opts) do
    with :ok <- validate_key(key),
         {:ok, timeout} <- timeout_options(opts) do
      run_with_timeout(timeout, fn deadline -> do_head(state, key, deadline) end)
    end
  end

  def head(_state, key, _opts) do
    case validate_key(key) do
      :ok -> {:error, {:adapter, :invalid_options}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def get(%__MODULE__{} = state, key, dest_path, opts) when is_binary(dest_path) do
    part = dest_path <> ".part"

    result =
      with :ok <- validate_key(key),
           {:ok, timeout} <- timeout_options(opts) do
        run_with_timeout(timeout, fn deadline ->
          do_get(state, key, part, deadline)
        end)
      end

    case result do
      {:ok, _reply} = ok ->
        case File.rename(part, dest_path) do
          :ok ->
            ok

          {:error, _reason} ->
            File.rm(part)
            {:error, {:adapter, :io}}
        end

      _error ->
        File.rm(part)
        result
    end
  end

  def get(_state, key, _dest_path, _opts) do
    case validate_key(key) do
      :ok -> {:error, {:adapter, :invalid_options}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def put(%__MODULE__{} = state, src_path, key, opts) when is_binary(src_path) do
    with :ok <- validate_key(key),
         {:ok, validated} <- put_options(opts) do
      run_with_timeout(validated.timeout, fn deadline ->
        do_put(state, src_path, key, validated, deadline)
      end)
    end
  end

  def put(_state, _src_path, key, _opts) do
    case validate_key(key) do
      :ok -> {:error, {:adapter, :invalid_options}}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec server(t()) :: GenServer.server()
  def server(%__MODULE__{server: server}), do: server

  @doc false
  @spec with_test_hooks(t(), map()) :: t()
  def with_test_hooks(%__MODULE__{} = state, hooks) when is_map(hooks) do
    case validate_hooks(hooks) do
      :ok -> %{state | test_hooks: hooks}
      {:error, _reason} -> state
    end
  end

  @doc false
  @spec force_sweep(t(), binary() | :all) :: :ok | {:error, term()}
  def force_sweep(%__MODULE__{} = state, :all), do: Server.force_sweep(state.server)

  def force_sweep(%__MODULE__{} = state, key) when is_binary(key) do
    with :ok <- validate_key(key) do
      Server.force_sweep(state.server, key_hash(key))
    end
  end

  @doc false
  @spec version_path(t(), binary(), binary()) :: Path.t()
  def version_path(%__MODULE__{} = state, key, version)
      when is_binary(key) and is_binary(version) do
    Path.join([state.root, "objects", key_hash(key), "v-#{version}"])
  end

  @doc false
  @spec key_hash(binary()) :: binary()
  def key_hash(key) when is_binary(key),
    do: :sha256 |> :crypto.hash(key) |> Base.encode16(case: :lower)

  defp do_head(state, key, deadline) do
    with {:ok, _server} <- start_server(state.root),
         :ok <- run_hook(state, :before_head),
         {:ok, {version, meta}} <- pin(state, key, deadline) do
      try do
        {:ok,
         %{
           etag: meta["etag"],
           size: meta["size"],
           metadata: meta["metadata"]
         }}
      after
        unpin(state.server, version, deadline)
      end
    end
  end

  defp do_get(state, key, part, deadline) do
    with {:ok, _server} <- start_server(state.root),
         {:ok, {version, meta}} <- pin(state, key, deadline) do
      try do
        source = version_path(state, key, version) |> Path.join("data")

        with :ok <- run_hook(state, :before_get),
             {:ok, bytes} <- copy_for_get(state, source, part, deadline),
             true <- bytes == meta["size"],
             :ok <- remaining_ok(deadline) do
          {:ok,
           %{
             etag: meta["etag"],
             bytes: bytes,
             metadata: meta["metadata"]
           }}
        else
          false -> {:error, {:adapter, :short_body}}
          {:error, {:transport, _reason}} = error -> error
          {:error, _reason} -> {:error, {:adapter, :io}}
        end
      after
        unpin(state.server, version, deadline)
      end
    end
  end

  defp do_put(state, src_path, key, opts, deadline) do
    with {:ok, _server} <- start_server(state.root),
         :ok <- run_hook(state, :before_put),
         :ok <- remaining_ok(deadline),
         {:ok, version, directory} <- create_version(state, key),
         result <- prepare_and_commit(state, src_path, key, version, directory, opts, deadline) do
      result
    end
  end

  defp prepare_and_commit(state, src_path, key, version, directory, opts, deadline) do
    case prepare_version(src_path, directory, opts.metadata, deadline) do
      {:ok, etag, size} ->
        case run_hook(state, :before_commit) do
          :ok ->
            commit_version(state, key, version, directory, opts.if_match, etag, size, deadline)

          {:error, _reason} = error ->
            remove_version_directory(directory)
            error
        end

      {:error, {:transport, :timeout}} = error ->
        remove_version_directory(directory)
        error

      {:error, _reason} = error ->
        remove_version_directory(directory)
        error
    end
  end

  defp commit_version(state, key, version, directory, if_match, etag, _size, deadline) do
    case server_call(
           state.server,
           {:commit, key_hash(key), if_match, version, Map.get(state.test_hooks, :after_commit)},
           remaining(deadline)
         ) do
      :ok ->
        {:ok, %{etag: etag}}

      {:error, :precondition_failed} = error ->
        remove_version_directory(directory)
        error

      {:error, {:transport, _reason}} = error ->
        # The server may have installed this version just before the call
        # became uncertain. Reconciliation belongs to Mirror; a later sweep
        # removes the directory if it did not become current.
        error

      {:error, _reason} = error ->
        remove_version_directory(directory)
        error
    end
  end

  defp prepare_version(src_path, directory, metadata, deadline) do
    data_path = Path.join(directory, "data")
    meta_path = Path.join(directory, "meta")

    with {:ok, etag, size} <- copy_for_put(src_path, data_path, deadline),
         :ok <- remaining_ok(deadline),
         bytes =
           :erlang.term_to_binary(%{
             "etag" => etag,
             "size" => size,
             "metadata" => metadata
           }),
         true <- byte_size(bytes) <= 65_536,
         :ok <- write_exclusive(meta_path, bytes, 0o600) do
      {:ok, etag, size}
    else
      false -> {:error, {:adapter, :corrupt_meta}}
      {:error, {:transport, _reason}} = error -> error
      {:error, _reason} -> {:error, {:adapter, :io}}
    end
  end

  defp create_version(state, key) do
    hash = key_hash(key)
    objects = Path.join(state.root, "objects")
    object_directory = Path.join(objects, hash)

    with :ok <- ensure_owned_directory(objects),
         :ok <- ensure_owned_directory(object_directory),
         :ok <- ensure_key_file(object_directory, key) do
      create_random_version(object_directory, 3)
    else
      {:error, {:adapter, _reason}} = error -> error
      {:error, _reason} -> {:error, {:adapter, :io}}
    end
  end

  defp create_random_version(_object_directory, 0),
    do: {:error, {:adapter, :version_collision}}

  defp create_random_version(object_directory, attempts) do
    version = random_hex(32)
    directory = Path.join(object_directory, "v-#{version}")

    case File.mkdir(directory) do
      :ok ->
        case {File.chmod(directory, 0o700), File.lstat(directory)} do
          {:ok, {:ok, %{type: :directory}}} ->
            {:ok, version, directory}

          _error ->
            remove_version_directory(directory)
            {:error, {:adapter, :io}}
        end

      {:error, :eexist} ->
        create_random_version(object_directory, attempts - 1)

      {:error, _reason} ->
        {:error, {:adapter, :io}}
    end
  end

  defp ensure_key_file(object_directory, key) do
    path = Path.join(object_directory, "key")

    case File.read(path) do
      {:ok, ^key} ->
        :ok

      {:ok, other} ->
        if other != key and key_hash(other) == Path.basename(object_directory) do
          {:error, {:adapter, :hash_collision}}
        else
          replace_key_file(path, key, 3)
        end

      {:error, _reason} ->
        # `key` is a debug aid. A missing, unreadable, or partially written
        # copy must never make the object itself permanently unpublishable.
        replace_key_file(path, key, 3)
    end
  end

  defp replace_key_file(_path, _key, 0), do: {:error, {:adapter, :io}}

  defp replace_key_file(path, key, attempts) do
    temp = path <> ".tmp-" <> random_hex(16)

    case open_raw(temp, [:write, :exclusive]) do
      {:ok, file} ->
        result =
          with :ok <- File.chmod(temp, 0o600),
               :ok <- :file.write(file, key) do
            :ok
          else
            {:error, _reason} -> {:error, {:adapter, :io}}
          end

        :file.close(file)

        case result do
          :ok ->
            case File.rename(temp, path) do
              :ok ->
                :ok

              {:error, _reason} ->
                File.rm(temp)
                {:error, {:adapter, :io}}
            end

          {:error, _reason} = error ->
            File.rm(temp)
            error
        end

      {:error, :eexist} ->
        replace_key_file(path, key, attempts - 1)

      {:error, _reason} ->
        {:error, {:adapter, :io}}
    end
  end

  defp copy_for_put(source, destination, deadline) do
    with {:ok, input} <- open_raw(source, [:read]),
         result <- copy_to_new_file(input, destination, deadline, true, nil) do
      :file.close(input)
      result
    else
      {:error, _reason} -> {:error, {:adapter, :io}}
    end
  end

  defp copy_for_get(state, source, destination, deadline) do
    File.rm(destination)

    with {:ok, input} <- open_raw(source, [:read]),
         result <- copy_to_new_file(input, destination, deadline, false, state) do
      :file.close(input)

      case result do
        {:ok, _etag, size} -> {:ok, size}
        {:error, _reason} = error -> error
      end
    else
      {:error, _reason} -> {:error, {:adapter, :io}}
    end
  end

  defp copy_to_new_file(input, destination, deadline, hash?, hook_state) do
    case open_raw(destination, [:write, :exclusive]) do
      {:ok, output} ->
        result =
          with :ok <- File.chmod(destination, 0o600) do
            context = if hash?, do: :crypto.hash_init(:sha256), else: nil
            copy_chunks(input, output, context, 0, deadline, hook_state)
          else
            {:error, _reason} -> {:error, {:adapter, :io}}
          end

        :file.close(output)
        result

      {:error, _reason} ->
        {:error, {:adapter, :io}}
    end
  end

  defp copy_chunks(input, output, context, bytes, deadline, hook_state) do
    if remaining(deadline) <= 0 do
      {:error, {:transport, :timeout}}
    else
      case :file.read(input, @chunk_bytes) do
        {:ok, chunk} ->
          with :ok <- run_chunk_hook(hook_state),
               :ok <- :file.write(output, chunk) do
            context = if context, do: :crypto.hash_update(context, chunk), else: nil
            copy_chunks(input, output, context, bytes + byte_size(chunk), deadline, hook_state)
          else
            {:error, {:adapter, _reason}} = error -> error
            {:error, _reason} -> {:error, {:adapter, :io}}
          end

        :eof ->
          etag =
            if context,
              do: context |> :crypto.hash_final() |> Base.encode16(case: :lower),
              else: nil

          {:ok, etag, bytes}

        {:error, _reason} ->
          {:error, {:adapter, :io}}
      end
    end
  end

  defp run_chunk_hook(nil), do: :ok
  defp run_chunk_hook(state), do: run_hook(state, :before_chunk)

  defp pin(state, key, deadline), do: pin(state, key, deadline, 3)

  defp pin(state, key, deadline, retries_left) do
    case server_call(state.server, {:pin, key_hash(key)}, remaining(deadline)) do
      {:error, {:transport, :closed}} when retries_left > 0 ->
        Process.sleep(1)

        case start_server(state.root) do
          {:ok, _server} -> pin(state, key, deadline, retries_left - 1)
          {:error, _reason} = error -> error
        end

      result ->
        result
    end
  end

  defp unpin(server, version, deadline) do
    _result = server_call(server, {:unpin, version}, remaining(deadline))
    :ok
  end

  defp server_call(_server, _message, time_left) when time_left <= 0,
    do: {:error, {:transport, :timeout}}

  defp server_call(server, message, time_left) do
    try do
      GenServer.call(server, message, time_left)
    catch
      :exit, {:timeout, _call} -> {:error, {:transport, :timeout}}
      # A server exit can race with the atomic current-pointer rename. Treat
      # the outcome as transport-uncertain so callers reconcile it and never
      # delete a version that may already be current.
      :exit, _reason -> {:error, {:transport, :closed}}
    end
  end

  defp run_hook(%__MODULE__{test_hooks: hooks}, name) do
    case Map.get(hooks, name) do
      nil ->
        :ok

      hook when is_function(hook, 0) ->
        case hook.() do
          :ok -> :ok
          _other -> {:error, {:adapter, :bad_hook}}
        end
    end
  end

  defp run_with_timeout(timeout, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout

    task =
      Task.async(fn ->
        try do
          fun.(deadline)
        rescue
          _exception -> {:error, {:adapter, :exception}}
        catch
          _kind, _reason -> {:error, {:adapter, :exception}}
        end
      end)

    case Task.yield(task, timeout) do
      {:ok, result} ->
        result

      {:exit, _reason} ->
        {:error, {:adapter, :exception}}

      nil ->
        case Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          _killed -> {:error, {:transport, :timeout}}
        end
    end
  end

  defp validate_init_options(opts) do
    with :ok <- keyword_options(opts, [:root, :test_hooks]),
         {:ok, root} <- fetch_option(opts, :root),
         true <- is_binary(root) and root != "" and String.valid?(root),
         hooks = Keyword.get(opts, :test_hooks, %{}),
         :ok <- validate_hooks(hooks) do
      :ok
    else
      _other -> {:error, :invalid_options}
    end
  end

  defp validate_hooks(hooks) when is_map(hooks) do
    if Enum.all?(hooks, fn {name, hook} ->
         name in @hook_names and is_function(hook, 0)
       end) do
      :ok
    else
      {:error, :invalid_hooks}
    end
  end

  defp validate_hooks(_hooks), do: {:error, :invalid_hooks}

  defp ensure_root(root) do
    case File.stat(root) do
      {:ok, %{type: :directory}} ->
        :ok

      {:ok, _stat} ->
        {:error, :not_a_directory}

      {:error, :enoent} ->
        with :ok <- File.mkdir_p(Path.dirname(root)) do
          case File.mkdir(root) do
            :ok ->
              case File.chmod(root, 0o700) do
                :ok ->
                  :ok

                {:error, reason} ->
                  File.rmdir(root)
                  {:error, reason}
              end

            {:error, :eexist} ->
              ensure_existing_root(root)

            {:error, reason} ->
              {:error, reason}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_existing_root(root) do
    case File.stat(root) do
      {:ok, %{type: :directory}} -> :ok
      {:ok, _stat} -> {:error, :not_a_directory}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_owned_directory(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        :ok

      {:ok, _stat} ->
        {:error, :unsafe_directory_type}

      {:error, :enoent} ->
        case File.mkdir(path) do
          :ok ->
            case File.chmod(path, 0o700) do
              :ok ->
                :ok

              {:error, reason} ->
                File.rmdir(path)
                {:error, reason}
            end

          {:error, :eexist} ->
            ensure_owned_directory(path)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remove_version_directory(directory) do
    case File.lstat(directory) do
      {:ok, %{type: :directory}} -> File.rm_rf(directory)
      _other -> :ok
    end
  end

  defp start_server(root) do
    try do
      case Supervisor.server(root) do
        {:ok, _server} = ok -> ok
        {:error, _reason} -> {:error, {:adapter, :server_unavailable}}
      end
    catch
      :exit, _reason -> {:error, {:adapter, :server_unavailable}}
    end
  end

  defp timeout_options(opts) do
    with :ok <- keyword_options(opts, [:timeout]),
         {:ok, timeout} <- fetch_option(opts, :timeout),
         true <- is_integer(timeout) and timeout > 0 do
      {:ok, timeout}
    else
      _other -> {:error, {:adapter, :invalid_options}}
    end
  end

  defp put_options(opts) do
    allowed = [:timeout, :if_match, :metadata, :content_type]

    with :ok <- keyword_options(opts, allowed),
         {:ok, timeout} <- fetch_option(opts, :timeout),
         true <- is_integer(timeout) and timeout > 0,
         {:ok, if_match} <- fetch_option(opts, :if_match),
         true <- if_match == :none or (is_binary(if_match) and byte_size(if_match) > 0),
         {:ok, metadata} <- fetch_option(opts, :metadata),
         :ok <- validate_metadata(metadata),
         {:ok, @content_type} <- fetch_option(opts, :content_type) do
      {:ok, %{timeout: timeout, if_match: if_match, metadata: metadata}}
    else
      _other -> {:error, {:adapter, :invalid_options}}
    end
  end

  defp validate_metadata(metadata) when is_map(metadata) and map_size(metadata) <= 8 do
    total =
      Enum.reduce_while(metadata, 0, fn
        {key, value}, bytes when is_binary(key) and is_binary(value) ->
          if valid_metadata_key?(key) and byte_size(value) <= 128 and printable_ascii?(value) do
            {:cont, bytes + byte_size(key) + byte_size(value)}
          else
            {:halt, :invalid}
          end

        _entry, _bytes ->
          {:halt, :invalid}
      end)

    if is_integer(total) and total <= 1_024,
      do: :ok,
      else: {:error, :invalid_metadata}
  end

  defp validate_metadata(_metadata), do: {:error, :invalid_metadata}

  defp valid_metadata_key?(key) do
    key != "" and String.match?(key, ~r/\A[a-z0-9_-]+\z/)
  end

  defp printable_ascii?(value) do
    for(<<byte <- value>>, do: byte)
    |> Enum.all?(&(&1 >= 0x20 and &1 <= 0x7E))
  end

  defp keyword_options(opts, allowed) do
    if is_list(opts) and Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      if Enum.all?(keys, &(&1 in allowed)) and length(keys) == length(Enum.uniq(keys)),
        do: :ok,
        else: {:error, :invalid_options}
    else
      {:error, :invalid_options}
    end
  end

  defp fetch_option(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :missing_option}
    end
  end

  defp validate_key(key) when is_binary(key) do
    segments = if String.valid?(key), do: String.split(key, "/", trim: false), else: []

    if key != "" and byte_size(key) <= 1_024 and String.valid?(key) and
         not String.starts_with?(key, "/") and not String.ends_with?(key, "/") and
         not String.contains?(key, <<0>>) and segments != [] and
         Enum.all?(segments, &(&1 not in ["", ".", ".."])) do
      :ok
    else
      invalid_key()
    end
  end

  defp validate_key(_key), do: invalid_key()

  defp invalid_key do
    {:error,
     {:invalid_key,
      "key must be non-empty UTF-8 without NUL, leading/trailing slash, or empty/dot segments"}}
  end

  defp random_hex(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp open_raw(path, modes),
    do: :file.open(String.to_charlist(path), [:raw, :binary | modes])

  defp write_exclusive(path, bytes, mode) do
    with {:ok, file} <- open_raw(path, [:write, :exclusive]) do
      result =
        with :ok <- File.chmod(path, mode),
             :ok <- :file.write(file, bytes) do
          :ok
        else
          {:error, _reason} -> {:error, {:adapter, :io}}
        end

      :file.close(file)
      result
    else
      {:error, _reason} -> {:error, {:adapter, :io}}
    end
  end

  defp remaining_ok(deadline) do
    if remaining(deadline) > 0,
      do: :ok,
      else: {:error, {:transport, :timeout}}
  end

  defp remaining(deadline),
    do: max(deadline - System.monotonic_time(:millisecond), 0)
end
