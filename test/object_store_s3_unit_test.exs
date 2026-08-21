defmodule Gitility.ObjectStoreS3UnitTest.ErrorHTTPServer do
  @moduledoc false

  use GenServer

  def start_link(body), do: GenServer.start_link(__MODULE__, body)
  def url(server), do: GenServer.call(server, :url)

  @impl GenServer
  def init(body) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        ip: {127, 0, 0, 1},
        active: false,
        packet: :raw,
        reuseaddr: true
      ])

    {:ok, {_address, port}} = :inet.sockname(listener)
    acceptor = spawn_link(fn -> accept_loop(listener, body) end)

    {:ok, %{listener: listener, acceptor: acceptor, url: "http://127.0.0.1:#{port}"}}
  end

  @impl GenServer
  def handle_call(:url, _from, state), do: {:reply, state.url, state}

  @impl GenServer
  def terminate(_reason, state) do
    :gen_tcp.close(state.listener)
    :ok
  end

  defp accept_loop(listener, body) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        serve(socket, body)
        accept_loop(listener, body)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        accept_loop(listener, body)
    end
  end

  defp serve(socket, body) do
    _request = recv_headers(socket, <<>>)

    response =
      "HTTP/1.1 403 Forbidden\r\n" <>
        "Content-Type: application/xml\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n" <>
        "Connection: close\r\n\r\n" <>
        body

    :gen_tcp.send(socket, response)
    :gen_tcp.close(socket)
  end

  defp recv_headers(socket, bytes) when byte_size(bytes) <= 65_536 do
    if :binary.match(bytes, "\r\n\r\n") == :nomatch do
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, more} -> recv_headers(socket, bytes <> more)
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, bytes}
    end
  end

  defp recv_headers(_socket, _bytes), do: {:error, :headers_too_large}
end

defmodule Gitility.ObjectStoreS3UnitTest do
  use ExUnit.Case, async: false

  if Code.ensure_loaded?(Req) do
    alias Gitility.ObjectStore.S3
    alias Gitility.ObjectStoreS3UnitTest.ErrorHTTPServer

    @credentials %{
      access_key_id: "test-access-key",
      secret_access_key: "test-secret-key"
    }

    test "init rejects endpoint URLs containing anything beyond scheme and authority" do
      for endpoint <- [
            "https://user@example.test",
            "https://example.test/path",
            "https://example.test?query=yes",
            "https://example.test#fragment"
          ] do
        assert {:error, :invalid_options} = S3.init(s3_options(endpoint_url: endpoint))
      end
    end

    test "init rejects invalid bucket names" do
      invalid_buckets = [
        "ab",
        String.duplicate("a", 64),
        "Uppercase",
        "under_score",
        "ab..cd",
        ".abc",
        "abc.",
        "-abc",
        "abc-"
      ]

      Enum.each(invalid_buckets, fn bucket ->
        assert {:error, :invalid_options} =
                 S3.init(s3_options(bucket: bucket, addressing: :path))
      end)
    end

    test "init gives dotted virtual-host buckets their distinct safe error" do
      assert {:error, :dotted_virtual_host_bucket} =
               S3.init(s3_options(bucket: "dotted.bucket", addressing: :virtual_host))

      assert {:ok, _state} = S3.init(s3_options(bucket: "dotted.bucket", addressing: :path))
    end

    test "init rejects a non-atom Finch pool name" do
      assert {:error, :invalid_options} = S3.init(s3_options(finch: "not-a-pool-name"))
    end

    test "build_url constructs exact path and virtual-host URLs" do
      assert {:ok, path} =
               S3.init(
                 s3_options(
                   endpoint_url: "https://objects.example.test",
                   addressing: :path
                 )
               )

      assert S3.build_url(path, "one/two") ==
               "https://objects.example.test/gitility-test/one/two"

      assert {:ok, path_with_port} =
               S3.init(
                 s3_options(
                   endpoint_url: "http://objects.example.test:9000",
                   addressing: :path
                 )
               )

      assert S3.build_url(path_with_port, "one/two") ==
               "http://objects.example.test:9000/gitility-test/one/two"

      assert {:ok, virtual_host} =
               S3.init(
                 s3_options(
                   endpoint_url: "https://objects.example.test",
                   addressing: :virtual_host
                 )
               )

      assert S3.build_url(virtual_host, "one/two") ==
               "https://gitility-test.objects.example.test/one/two"

      assert {:ok, virtual_host_with_port} =
               S3.init(
                 s3_options(
                   endpoint_url: "http://objects.example.test:9000",
                   addressing: :virtual_host
                 )
               )

      assert S3.build_url(virtual_host_with_port, "one/two") ==
               "http://gitility-test.objects.example.test:9000/one/two"

      assert {:ok, default_port} =
               S3.init(
                 s3_options(
                   endpoint_url: "https://objects.example.test:443",
                   addressing: :path
                 )
               )

      assert S3.build_url(default_port, "object") ==
               "https://objects.example.test/gitility-test/object"
    end

    test "build_url brackets an IPv6 literal authority" do
      assert {:ok, state} =
               S3.init(
                 s3_options(
                   endpoint_url: "http://[2001:db8::1]:9000",
                   addressing: :path
                 )
               )

      assert S3.build_url(state, "one/two") ==
               "http://[2001:db8::1]:9000/gitility-test/one/two"
    end

    test "S3 key encoding vectors are asserted through the assembled URL" do
      assert {:ok, state} =
               S3.init(
                 s3_options(
                   endpoint_url: "https://objects.example.test",
                   addressing: :path
                 )
               )

      vectors = [
        {"a b", "a%20b"},
        {"a%b", "a%25b"},
        {"a?b", "a%3Fb"},
        {"a#b", "a%23b"},
        {"a+b", "a%2Bb"},
        {"ü/ß", "%C3%BC/%C3%9F"},
        {"x/y/z", "x/y/z"}
      ]

      Enum.each(vectors, fn {key, encoded} ->
        assert S3.build_url(state, key) ==
                 "https://objects.example.test/gitility-test/#{encoded}"
      end)
    end

    test "provider codes reflecting credentials are redacted case-insensitively", context do
      credentials = %{
        access_key_id: "SentinelAccess123",
        secret_access_key: "SentinelSecret456",
        session_token: "SentinelSession789"
      }

      assert_provider_code(
        "sentinelaccess123",
        credentials,
        "Redacted",
        Path.join(context.tmp_dir, "reflected")
      )
    end

    test "long provider codes are redacted while short provider codes remain useful", context do
      assert_provider_code(
        String.duplicate("A", 40),
        @credentials,
        "Redacted",
        Path.join(context.tmp_dir, "long")
      )

      assert_provider_code(
        "NoSuchKey",
        @credentials,
        "NoSuchKey",
        Path.join(context.tmp_dir, "short")
      )
    end

    defp assert_provider_code(code, credentials, expected, destination) do
      {:ok, server} = ErrorHTTPServer.start_link("<Error><Code>#{code}</Code></Error>")

      try do
        assert {:ok, state} =
                 S3.init(
                   s3_options(
                     endpoint_url: ErrorHTTPServer.url(server),
                     addressing: :path,
                     credentials: credentials
                   )
                 )

        assert {:error, {:http, 403, ^expected}} =
                 S3.get(state, "object", destination, timeout: 2_000)

        refute File.exists?(destination)
        refute File.exists?(destination <> ".part")
      after
        if Process.alive?(server), do: GenServer.stop(server)
      end
    end

    defp s3_options(overrides) do
      Keyword.merge(
        [
          bucket: "gitility-test",
          region: "us-east-1",
          credentials: @credentials
        ],
        overrides
      )
    end
  else
    @tag skip: "Req is unavailable"
    test "S3 unit coverage requires the optional Req dependency", do: :ok
  end

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "gitility-s3-unit-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end
end
