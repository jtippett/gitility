defmodule Gitility.TestSupport.SmartHTTPServer do
  @moduledoc false

  use GenServer

  @type option ::
          {:project_root, Path.t()}
          | {:require_authorization, binary()}
          | {:respond_status, 403}
          | {:redirect, binary()}
          | {:stall, :after_headers}
          | {:truncate_pack, non_neg_integer()}
          | {:delay_body, {pos_integer(), non_neg_integer()}}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def child_spec(opts) do
    %{id: {__MODULE__, make_ref()}, start: {__MODULE__, :start_link, [opts]}}
  end

  @spec url(pid(), String.t()) :: String.t()
  def url(server, repository \\ "") do
    base = GenServer.call(server, :url)
    if repository == "", do: base, else: base <> "/" <> repository
  end

  @impl GenServer
  def init(opts) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        ip: {127, 0, 0, 1},
        active: false,
        packet: :raw,
        reuseaddr: true
      ])

    {:ok, {_address, port}} = :inet.sockname(listener)
    state = %{listener: listener, opts: Map.new(opts), url: "http://127.0.0.1:#{port}"}
    server = self()
    acceptor = spawn_link(fn -> accept_loop(server, listener, state.opts) end)
    {:ok, Map.put(state, :acceptor, acceptor)}
  end

  @impl GenServer
  def handle_call(:url, _from, state), do: {:reply, state.url, state}

  @impl GenServer
  def terminate(_reason, state) do
    :gen_tcp.close(state.listener)
    :ok
  end

  defp accept_loop(server, listener, opts) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spawn_link(fn -> serve(server, socket, opts) end)
        accept_loop(server, listener, opts)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        accept_loop(server, listener, opts)
    end
  end

  defp serve(server, socket, opts) do
    with {:ok, request} <- read_request(socket) do
      cond do
        opts[:respond_status] == 403 ->
          send_response(socket, 403, [{"Content-Type", "text/plain"}], "forbidden")

        location = opts[:redirect] ->
          send_response(socket, 301, [{"Location", location}], "")

        required = opts[:require_authorization] ->
          if request.headers["authorization"] == required do
            serve_authorized(server, socket, request, opts)
          else
            send_response(
              socket,
              401,
              [{"WWW-Authenticate", "Basic realm=gitility"}],
              "unauthorized"
            )
          end

        true ->
          serve_authorized(server, socket, request, opts)
      end
    end

    :gen_tcp.close(socket)
  end

  defp serve_authorized(server, socket, _request, %{stall: :after_headers}) do
    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\nContent-Type: application/x-git-upload-pack-result\r\nConnection: close\r\n\r\n"
      )

    monitor = Process.monitor(server)

    receive do
      {:DOWN, ^monitor, :process, ^server, _reason} -> :ok
    end
  end

  defp serve_authorized(_server, socket, request, opts) do
    case cgi(request, opts) do
      {:ok, status, headers, body} ->
        send_cgi_response(socket, request, status, headers, body, opts)

      {:error, status, body} ->
        send_response(socket, status, [{"Content-Type", "text/plain"}], body)
    end
  end

  defp read_request(socket) do
    with {:ok, head, rest} <- recv_until(socket, "\r\n\r\n", <<>>),
         {:ok, method, target, headers} <- parse_head(head),
         {:ok, content_length} <- content_length(headers),
         {:ok, body} <- recv_body(socket, rest, content_length) do
      uri = URI.parse(target)

      {:ok,
       %{
         method: method,
         path: uri.path,
         query: uri.query || "",
         headers: headers,
         body: body
       }}
    end
  end

  defp recv_until(socket, marker, data) do
    case :binary.match(data, marker) do
      {offset, size} ->
        head = binary_part(data, 0, offset)
        rest_offset = offset + size
        rest = binary_part(data, rest_offset, byte_size(data) - rest_offset)
        {:ok, head, rest}

      :nomatch ->
        case :gen_tcp.recv(socket, 0, 10_000) do
          {:ok, chunk} -> recv_until(socket, marker, data <> chunk)
          error -> error
        end
    end
  end

  defp parse_head(head) do
    case :binary.split(head, "\r\n", [:global]) do
      [request_line | header_lines] ->
        with [method, target, _version] <- String.split(request_line, " ", parts: 3) do
          headers =
            Enum.reduce(header_lines, %{}, fn line, acc ->
              case :binary.split(line, ":") do
                [name, value] ->
                  Map.put(acc, String.downcase(name), String.trim_leading(value))

                _ ->
                  acc
              end
            end)

          {:ok, method, target, headers}
        else
          _ -> {:error, :malformed_request}
        end

      _ ->
        {:error, :malformed_request}
    end
  end

  defp content_length(headers) do
    case Map.get(headers, "content-length", "0") |> Integer.parse() do
      {length, ""} when length >= 0 -> {:ok, length}
      _ -> {:error, :invalid_content_length}
    end
  end

  defp recv_body(_socket, rest, length) when byte_size(rest) >= length do
    {:ok, binary_part(rest, 0, length)}
  end

  defp recv_body(socket, rest, length) do
    case :gen_tcp.recv(socket, length - byte_size(rest), 10_000) do
      {:ok, chunk} -> recv_body(socket, rest <> chunk, length)
      error -> error
    end
  end

  # Implementer choice: a tiny shell wrapper uses `dd count=CONTENT_LENGTH`
  # to give git-http-backend a real EOF without closing the Erlang port. This
  # keeps stdout and exit-status collection on the port while supporting a
  # binary POST body with no temporary file.
  defp cgi(request, opts) do
    project_root = Map.fetch!(opts, :project_root)
    git = System.find_executable("git") || "git"

    environment = [
      {"GIT_PROJECT_ROOT", project_root},
      {"GIT_HTTP_EXPORT_ALL", "1"},
      {"PATH_INFO", request.path},
      {"REQUEST_METHOD", request.method},
      {"QUERY_STRING", request.query},
      {"CONTENT_TYPE", Map.get(request.headers, "content-type", "")},
      {"CONTENT_LENGTH", Integer.to_string(byte_size(request.body))},
      {"GITILITY_GIT", git},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_SYSTEM", "/dev/null"},
      {"GIT_TERMINAL_PROMPT", "0"},
      {"LC_ALL", "C"}
    ]

    command =
      "dd bs=1 count=\"$CONTENT_LENGTH\" 2>/dev/null | \"$GITILITY_GIT\" http-backend"

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :use_stdio,
        :stderr_to_stdout,
        :exit_status,
        :eof,
        args: ["-c", command],
        env: Enum.map(environment, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)
      ])

    if request.body != <<>>, do: Port.command(port, request.body)

    case collect_port(port, <<>>, nil, false) do
      {:ok, output} -> parse_cgi(output)
      {:error, status, output} -> {:error, 500, "git http-backend exited #{status}: #{output}"}
    end
  end

  defp collect_port(port, output, status, eof?) do
    if not is_nil(status) and eof? do
      if status == 0, do: {:ok, output}, else: {:error, status, output}
    else
      receive do
        {^port, {:data, data}} -> collect_port(port, output <> data, status, eof?)
        {^port, {:exit_status, next_status}} -> collect_port(port, output, next_status, eof?)
        {^port, :eof} -> collect_port(port, output, status, true)
      after
        30_000 ->
          Port.close(port)
          {:error, :timeout, output}
      end
    end
  end

  defp parse_cgi(output) do
    case split_headers(output) do
      {:ok, raw_headers, body} ->
        {status, headers} =
          raw_headers
          |> :binary.split("\n", [:global, :trim_all])
          |> Enum.reduce({200, []}, fn raw_line, {status, headers} ->
            line = String.trim_trailing(raw_line, "\r")

            case :binary.split(line, ":") do
              ["Status", value] ->
                {code, _rest} = value |> String.trim() |> Integer.parse()
                {code, headers}

              [name, value] ->
                {status, [{name, String.trim(value)} | headers]}

              _ ->
                {status, headers}
            end
          end)

        {:ok, status, Enum.reverse(headers), body}

      :error ->
        {:error, 500, "git http-backend returned malformed CGI output"}
    end
  end

  defp split_headers(output) do
    case :binary.match(output, "\r\n\r\n") do
      {offset, 4} ->
        {:ok, binary_part(output, 0, offset),
         binary_part(output, offset + 4, byte_size(output) - offset - 4)}

      :nomatch ->
        case :binary.match(output, "\n\n") do
          {offset, 2} ->
            {:ok, binary_part(output, 0, offset),
             binary_part(output, offset + 2, byte_size(output) - offset - 2)}

          :nomatch ->
            :error
        end
    end
  end

  defp send_cgi_response(socket, request, status, headers, body, opts) do
    pack_request? = String.ends_with?(request.path, "/git-upload-pack")

    cond do
      pack_request? and is_integer(opts[:truncate_pack]) ->
        count = min(opts[:truncate_pack], byte_size(body))
        send_response_head(socket, status, headers, byte_size(body))
        :gen_tcp.send(socket, binary_part(body, 0, count))

      pack_request? and match?({_, _}, opts[:delay_body]) ->
        {chunk_bytes, delay_ms} = opts[:delay_body]
        send_response_head(socket, status, headers, byte_size(body))
        send_chunks(socket, body, chunk_bytes, delay_ms)

      true ->
        send_response(socket, status, headers, body)
    end
  end

  defp send_chunks(_socket, <<>>, _chunk_bytes, _delay_ms), do: :ok

  defp send_chunks(socket, body, chunk_bytes, delay_ms) do
    size = min(chunk_bytes, byte_size(body))
    <<chunk::binary-size(size), rest::binary>> = body

    case :gen_tcp.send(socket, chunk) do
      :ok ->
        Process.sleep(delay_ms)
        send_chunks(socket, rest, chunk_bytes, delay_ms)

      {:error, _reason} ->
        :ok
    end
  end

  defp send_response(socket, status, headers, body) do
    send_response_head(socket, status, headers, byte_size(body))
    :gen_tcp.send(socket, body)
  end

  defp send_response_head(socket, status, headers, content_length) do
    reason =
      %{
        200 => "OK",
        301 => "Moved Permanently",
        401 => "Unauthorized",
        403 => "Forbidden",
        500 => "Internal Server Error"
      }[status] || "Response"

    encoded_headers =
      headers
      |> Enum.reject(fn {name, _value} ->
        String.downcase(name) in ["content-length", "connection"]
      end)
      |> Enum.map_join("", fn {name, value} -> "#{name}: #{value}\r\n" end)

    :gen_tcp.send(
      socket,
      "HTTP/1.1 #{status} #{reason}\r\n#{encoded_headers}Content-Length: #{content_length}\r\nConnection: close\r\n\r\n"
    )
  end
end
