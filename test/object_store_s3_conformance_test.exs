required_minio_env = ~w(
  GITILITY_MINIO_URL
  GITILITY_MINIO_KEY
  GITILITY_MINIO_SECRET
  GITILITY_MINIO_BUCKET
)

missing_minio_env = Enum.reject(required_minio_env, &System.get_env/1)

if missing_minio_env == [] do
  defmodule Gitility.ObjectStoreS3ConformanceTest.SlowHTTPServer do
    @moduledoc false

    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok)

    def url(server), do: GenServer.call(server, :url)

    @impl GenServer
    def init(:ok) do
      {:ok, listener} =
        :gen_tcp.listen(0, [
          :binary,
          ip: {127, 0, 0, 1},
          active: false,
          packet: :raw,
          reuseaddr: true
        ])

      {:ok, {_address, port}} = :inet.sockname(listener)
      owner = self()
      acceptor = spawn_link(fn -> accept_loop(owner, listener) end)

      {:ok,
       %{
         listener: listener,
         acceptor: acceptor,
         url: "http://127.0.0.1:#{port}"
       }}
    end

    @impl GenServer
    def handle_call(:url, _from, state), do: {:reply, state.url, state}

    @impl GenServer
    def terminate(_reason, state) do
      :gen_tcp.close(state.listener)
      :ok
    end

    defp accept_loop(owner, listener) do
      case :gen_tcp.accept(listener) do
        {:ok, socket} ->
          handler =
            spawn(fn ->
              receive do
                {:serve, ^socket} -> serve(owner, socket)
              end
            end)

          :ok = :gen_tcp.controlling_process(socket, handler)
          send(handler, {:serve, socket})
          accept_loop(owner, listener)

        {:error, :closed} ->
          :ok

        {:error, _reason} ->
          accept_loop(owner, listener)
      end
    end

    defp serve(owner, socket) do
      monitor = Process.monitor(owner)

      case read_headers(socket, <<>>) do
        {:ok, request} ->
          case request_method(request) do
            "GET" -> drip_get(owner, monitor, socket)
            "HEAD" -> wait_for_owner(owner, monitor)
            "PUT" -> wait_for_owner(owner, monitor)
            _other -> :ok
          end

        {:error, _reason} ->
          :ok
      end

      Process.demonitor(monitor, [:flush])
      :gen_tcp.close(socket)
    end

    defp read_headers(socket, bytes) when byte_size(bytes) <= 65_536 do
      if :binary.match(bytes, "\r\n\r\n") != :nomatch do
        {:ok, bytes}
      else
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, more} -> read_headers(socket, bytes <> more)
          {:error, reason} -> {:error, reason}
        end
      end
    end

    defp read_headers(_socket, _bytes), do: {:error, :headers_too_large}

    defp request_method(request) do
      case :binary.split(request, " ", [:global]) do
        [method | _rest] -> method
        _other -> ""
      end
    end

    defp drip_get(owner, monitor, socket) do
      response =
        "HTTP/1.1 200 OK\r\n" <>
          "Content-Length: 67108864\r\n" <>
          "ETag: \"slow-object\"\r\n" <>
          "Content-Type: application/vnd.gitility.bundle\r\n" <>
          "Connection: close\r\n\r\n"

      case :gen_tcp.send(socket, response <> "x") do
        :ok -> drip_byte(owner, monitor, socket)
        {:error, _reason} -> :ok
      end
    end

    defp drip_byte(owner, monitor, socket) do
      receive do
        {:DOWN, ^monitor, :process, ^owner, _reason} ->
          :ok
      after
        1_000 ->
          case :gen_tcp.send(socket, "x") do
            :ok -> drip_byte(owner, monitor, socket)
            {:error, _reason} -> :ok
          end
      end
    end

    defp wait_for_owner(owner, monitor) do
      receive do
        {:DOWN, ^monitor, :process, ^owner, _reason} -> :ok
      after
        60_000 -> :ok
      end
    end
  end

  defmodule Gitility.ObjectStoreS3ConformanceTest do
    use Gitility.ObjectStore.Conformance, store: Gitility.ObjectStore.S3

    alias Gitility.ObjectStoreS3ConformanceTest.SlowHTTPServer

    def store_setup do
      {:ok, server} = SlowHTTPServer.start_link([])
      Process.put({__MODULE__, :slow_url}, SlowHTTPServer.url(server))
      server
    end

    def store_teardown(server) do
      Process.delete({__MODULE__, :slow_url})
      if Process.alive?(server), do: GenServer.stop(server)
      :ok
    end

    def store_init_arg do
      [
        bucket: System.fetch_env!("GITILITY_MINIO_BUCKET"),
        region: "us-east-1",
        credentials: %{
          access_key_id: System.fetch_env!("GITILITY_MINIO_KEY"),
          secret_access_key: System.fetch_env!("GITILITY_MINIO_SECRET")
        },
        endpoint_url: System.fetch_env!("GITILITY_MINIO_URL"),
        addressing: :path
      ]
    end

    def slow_store_init_arg do
      [
        bucket: "gitility-slow",
        region: "us-east-1",
        credentials: %{
          access_key_id: "slow-access-key",
          secret_access_key: "slow-secret-key"
        },
        endpoint_url: Process.get({__MODULE__, :slow_url}),
        addressing: :path
      ]
    end
  end
else
  IO.puts(
    ":skipped — S3 object-store conformance requires " <>
      Enum.join(missing_minio_env, ", ")
  )

  defmodule Gitility.ObjectStoreS3ConformanceTest do
    use ExUnit.Case, async: false

    @moduletag skip: "GITILITY_MINIO_* environment is not configured"

    test "S3 conformance :skipped (minio environment unavailable)", do: :ok
  end
end
