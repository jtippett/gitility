defmodule Gitility.ODB.PackFetch do
  @moduledoc """
  Eagerly hydrates an immutable pack manifest into a local gix object store.

  `start_link/1` uses the same callback supervision and request-resource
  protocol as `Gitility.ODB.start_link/1`, but the backend implements
  `Gitility.ODB.RangeBackend`. Startup deliberately blocks until the initial
  manifest has been fetched, every pack/index pair has been verified and
  atomically published, and the resulting objects directory is open. A handle
  is never exposed in a half-hydrated state.

      {:ok, supervisor} =
        Gitility.ODB.PackFetch.start_link(
          backend: {MyApp.PackStore, backend_options},
          into: {:dir, "/var/cache/gitility"},
          concurrency: 8,
          verify: :always
        )

      {:ok, odb} = Gitility.ODB.handle(supervisor)

  `into: {:dir, path}` writes only beneath the explicit path, using
  `objects/pack/pack-<checksum>.{pack,idx}`. Existing valid pairs are reused;
  corrupt pairs are replaced. Removed manifest entries are retained in 0.2 —
  refresh never deletes packs during the publisher's grace period. If a
  later pack fails, earlier verified pairs remain for the next attempt; no
  unverified file is left under a final name. Within one store lifetime,
  refresh size-checks already verified pairs and is O(new packs). A restart
  re-hashes the whole reused volume once because trust is never persisted to
  disk.

  `into: :memory` is available only on Linux. It uses a caller-invisible
  directory below `/dev/shm`, which is a RAM-backed tmpfs, enforces
  `max_bytes`, and removes the directory during orderly provider shutdown.
  Native resource destruction never performs filesystem work on a BEAM
  scheduler. An abnormal death can leave this bounded tmpfs directory; the
  next `start_link/1` with the same `:name` sweeps it before starting. This is
  not a bytes-in-Rust gix store: stock gix-pack is path-only and mmap-based
  (design finding F7). macOS and other platforms return
  `:unsupported_operation`; use an explicit directory there.

  `into: {:bundle, path}` remains reserved for the M4c hydration writer and
  currently returns `:unsupported_operation`. Use `Gitility.Bundle.write/2`
  to build a bundle from a local repository today.

  ## Options

    * `:backend` (required) — `{module, init_arg}` implementing
      `Gitility.ODB.RangeBackend`.
    * `:into` — `{:dir, path}` or `:memory` (default `:memory`); bundle
      destinations are reserved as described above.
    * `:name` — supervisor registered name; omitted starts privately.
    * `:hash` — `:sha1` (default) or `:sha256`; must match the manifest.
    * `:concurrency` — maximum outstanding `read_ranges` callbacks per pack
      (default `8`).
    * `:chunk_bytes` — fixed pack range size (default 8 MiB).
    * `:request_timeout` — per-callback timeout in milliseconds (default
      `15_000`).
    * `:verify` — only `:always` is accepted.
    * `:runtime` — query runtime (default shared).
    * `:max_hydration_bytes` — bytes the hydration plan may actually fetch
      (default 4 GiB). This one-time bulk-load ceiling is distinct from
      query-time `Gitility.Limits.max_provider_bytes` (default 256 MiB).
      Existing pairs are verified before planning, so a warm volume is
      charged only for manifest metadata plus missing or corrupt pairs.
    * `:limits` — the other hydration-job ceilings and timeout. Hydration
      always replaces this struct's `max_provider_bytes` with
      `max_hydration_bytes`; query-time limits are unchanged.
    * `:max_bytes` — RAM destination ceiling (default 256 MiB); used only by
      `into: :memory`.
  """

  alias Gitility.{Error, Limits, Native, NativeSupport, ODB}

  @default_chunk_bytes 8 * 1024 * 1024
  @default_memory_bytes 256 * 1024 * 1024
  @default_hydration_bytes 4 * 1024 * 1024 * 1024

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    opts =
      Keyword.validate!(opts,
        backend: nil,
        into: :memory,
        name: nil,
        hash: :sha1,
        concurrency: 8,
        chunk_bytes: @default_chunk_bytes,
        request_timeout: 15_000,
        verify: :always,
        runtime: :default,
        limits: nil,
        max_hydration_bytes: @default_hydration_bytes,
        max_bytes: @default_memory_bytes
      )

    name = opts[:name] || {:global, {Gitility.ODB.PackFetch.Supervisor, make_ref()}}

    with :ok <- validate_backend(opts[:backend]),
         :ok <- validate_name(name),
         :ok <- validate_hash(opts[:hash]),
         :ok <- validate_verify(opts[:verify]),
         {:ok, concurrency} <- positive(opts[:concurrency], :concurrency),
         {:ok, chunk_bytes} <- positive(opts[:chunk_bytes], :chunk_bytes),
         {:ok, request_timeout} <- positive(opts[:request_timeout], :request_timeout),
         {:ok, max_hydration_bytes} <-
           positive(opts[:max_hydration_bytes], :max_hydration_bytes),
         {:ok, destination, cleanup?, max_bytes} <-
           destination(opts[:into], opts[:max_bytes], name),
         {:ok, limits} <- hydration_limits(opts[:limits], max_hydration_bytes),
         {:ok, runtime, _runtime_resource} <- NativeSupport.runtime_and_resource(opts[:runtime]),
         {:ok, supervisor} <-
           Gitility.ODB.Provider.Supervisor.start_link(
             backend: opts[:backend],
             callback_kind: :range,
             name: name,
             hash: opts[:hash],
             concurrency: concurrency,
             request_timeout: request_timeout,
             runtime: runtime,
             packfetch_limits: limits,
             packfetch_cleanup_destination: if(cleanup?, do: destination),
             packfetch_options: %{
               request_timeout_ms: request_timeout,
               destination: destination,
               chunk_bytes: chunk_bytes,
               concurrency: concurrency,
               max_hydration_bytes: max_hydration_bytes,
               max_bytes: max_bytes
             }
           ),
         {:ok, _stats} <- hydrate_supervisor(supervisor, limits) do
      {:ok, supervisor}
    else
      {:hydrate_error, supervisor, %Error{} = error} ->
        stop_failed_start(supervisor)
        {:error, error}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, {:backend_init, reason}} ->
        {:error, reason}

      {:error, {:backend_init_raised, message}} ->
        {:error, {:backend_init_raised, message}}

      {:error, reason} ->
        {:error,
         Error.new(:backend_error, "PackFetch provider failed to start",
           retryable: true,
           operation: :packfetch_start_link,
           details: %{reason: sanitize_reason(reason)}
         )}
    end
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name) || {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc "Returns whether `into: :memory` is supported on this platform."
  @spec memory_supported?() :: boolean()
  def memory_supported?, do: :os.type() == {:unix, :linux} and File.dir?("/dev/shm")

  defp hydrate_supervisor(supervisor, limits) do
    case ODB.handle(supervisor) do
      {:ok, odb} -> hydrate(odb, limits)
      {:error, %Error{} = error} -> {:hydrate_error, supervisor, error}
    end
  end

  defp hydrate(%ODB{} = odb, limits) do
    limits_map = NativeSupport.limits_map!(limits)

    case NativeSupport.await_sync(
           fn ->
             NativeSupport.submit_job(odb.runtime, :packfetch_hydrate, fn runtime_resource ->
               Native.packfetch_hydrate(runtime_resource, odb.ref, limits_map)
             end)
           end,
           limits.timeout_ms,
           :packfetch_hydrate
         ) do
      {:ok, stats} -> {:ok, stats}
      {:error, %Error{} = error} -> {:hydrate_error, odb.supervisor, error}
    end
  end

  defp destination({:dir, path}, _max_bytes, _name)
       when is_binary(path) and byte_size(path) > 0 do
    {:ok, Path.expand(path), false, nil}
  end

  defp destination(:memory, max_bytes, name) when is_integer(max_bytes) and max_bytes > 0 do
    if memory_supported?() do
      key = memory_destination_key(name)

      with :ok <- sweep_memory_leftovers(name, key) do
        unique = System.unique_integer([:positive, :monotonic])
        {:ok, "/dev/shm/gitility-packfetch-#{key}-#{unique}", true, max_bytes}
      end
    else
      {:error,
       Error.new(
         :unsupported_operation,
         "into: :memory requires Linux /dev/shm; use into: {:dir, path}",
         operation: :packfetch_start_link
       )}
    end
  end

  defp destination(:memory, _max_bytes, _name),
    do: NativeSupport.invalid_argument(":max_bytes must be a positive integer for into: :memory")

  defp destination({:bundle, path}, _max_bytes, _name) when is_binary(path) do
    {:error,
     Error.new(
       :unsupported_operation,
       "into: {:bundle, path} is not a hydration destination yet; use Gitility.Bundle.write/2",
       operation: :packfetch_start_link
     )}
  end

  defp destination(_into, _max_bytes, _name) do
    NativeSupport.invalid_argument(":into must be :memory, {:dir, path}, or {:bundle, path}")
  end

  defp hydration_limits(nil, max_hydration_bytes) do
    {:ok, Limits.new(max_provider_bytes: max_hydration_bytes)}
  end

  defp hydration_limits(%Limits{} = limits, max_hydration_bytes) do
    NativeSupport.limits_map!(limits)
    {:ok, %{limits | max_provider_bytes: max_hydration_bytes}}
  end

  defp hydration_limits(_limits, _max_hydration_bytes) do
    NativeSupport.invalid_argument(":limits must be a Gitility.Limits struct")
  end

  defp memory_destination_key(name) do
    name
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp sweep_memory_leftovers(name, key) do
    if registered?(name) do
      :ok
    else
      "/dev/shm/gitility-packfetch-#{key}-*"
      |> Path.wildcard()
      |> Enum.reduce_while(:ok, fn path, :ok ->
        case File.rm_rf(path) do
          {:ok, _removed} -> {:cont, :ok}
          {:error, _reason, _file} -> {:halt, {:error, :memory_cleanup_failed}}
        end
      end)
    end
  end

  defp registered?(name) do
    is_pid(GenServer.whereis(name))
  catch
    :exit, _reason -> false
  end

  defp validate_backend({module, _arg}) when is_atom(module) do
    if function_exported?(module, :init, 1) and function_exported?(module, :manifest, 1) and
         function_exported?(module, :read_ranges, 2) do
      :ok
    else
      NativeSupport.invalid_argument(
        ":backend module must implement RangeBackend init/1, manifest/1, and read_ranges/2"
      )
    end
  end

  defp validate_backend(_backend),
    do: NativeSupport.invalid_argument(":backend must be a {module, init_arg} tuple")

  defp validate_name(name) when is_atom(name), do: :ok
  defp validate_name({:global, _term}), do: :ok
  defp validate_name({:via, module, _term}) when is_atom(module), do: :ok

  defp validate_name(_name),
    do:
      NativeSupport.invalid_argument(
        ":name must be an atom, {:global, term}, or {:via, module, term}"
      )

  defp validate_hash(hash) when hash in [:sha1, :sha256], do: :ok
  defp validate_hash(_hash), do: NativeSupport.invalid_argument(":hash must be :sha1 or :sha256")
  defp validate_verify(:always), do: :ok

  defp validate_verify(_verify),
    do: NativeSupport.invalid_argument("only verify: :always is supported")

  defp positive(value, _name) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive(_value, name),
    do: NativeSupport.invalid_argument(":#{name} must be a positive integer")

  defp stop_failed_start(supervisor) do
    Process.unlink(supervisor)

    try do
      Supervisor.stop(supervisor)
    catch
      :exit, _reason -> :ok
    end
  end

  defp sanitize_reason(_reason), do: :packfetch_provider_start_failed
end
