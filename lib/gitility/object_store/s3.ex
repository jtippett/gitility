defmodule Gitility.ObjectStore.S3 do
  @moduledoc """
  S3-compatible object store with conditional, single-object writes.

  Req is optional. Applications using this adapter add it explicitly:

      {:req, "~> 0.5.8"}

  The adapter uses Req's AWS Signature Version 4 step and invokes a
  zero-arity credential provider for every request. A provider returns a map
  with non-empty `:access_key_id` and `:secret_access_key` binaries and an
  optional binary `:session_token`. Provider failures are sanitised to
  `:credentials_unavailable`; credentials and signed requests are never kept
  in adapter state or returned in errors.

  AWS uses virtual-host addressing by default. Most MinIO, Tigris, and R2
  endpoints use path addressing:

      Gitility.ObjectStore.S3.init(
        bucket: "mirrors",
        region: "auto",
        endpoint_url: "https://objects.example.com",
        addressing: :path,
        credentials: fn -> credentials_from_my_vault() end
      )

  The endpoint accepts only a scheme and host with an optional port. Redirects
  and retries are disabled. Correct publication requires a provider that
  implements conditional `If-Match` and `If-None-Match` writes; AWS S3,
  MinIO, R2, and Tigris provide that capability.

  PUT uses one streamed request and is limited to S3's 5 GiB single-PUT
  maximum. Multipart upload is not implemented.
  """

  @behaviour Gitility.ObjectStore

  @compile {:no_warn_undefined, Req}

  import Bitwise, only: [&&&: 2, >>>: 2]

  @content_type "application/vnd.gitility.bundle"
  @put_limit 5_368_709_120
  @upload_chunk_bytes 1_048_576
  @max_error_body_bytes 65_536

  @enforce_keys [
    :bucket,
    :region,
    :host,
    :scheme,
    :addressing,
    :finch,
    :credentials_fun
  ]
  defstruct [
    :bucket,
    :region,
    :host,
    :scheme,
    :port,
    :addressing,
    :finch,
    :credentials_fun
  ]

  @type t :: %__MODULE__{
          bucket: binary(),
          region: binary(),
          host: binary(),
          scheme: binary(),
          port: :inet.port_number() | nil,
          addressing: :virtual_host | :path,
          finch: atom(),
          credentials_fun: (-> map())
        }

  @impl true
  def init(opts) do
    if Code.ensure_loaded?(Req) do
      do_init(opts)
    else
      {:error, {:unsupported_operation, "add {:req, \"~> 0.5.8\"} to deps"}}
    end
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
           {:ok, timeout} <- timeout_options(opts),
           {:ok, reply} <-
             run_with_timeout(timeout, fn deadline ->
               do_get(state, key, part, deadline)
             end),
           :ok <- finish_download(part, dest_path) do
        {:ok, reply}
      end

    case result do
      {:ok, _reply} ->
        result

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
  @spec encode_key(binary()) :: binary()
  def encode_key(key) when is_binary(key) do
    for <<byte <- key>>, into: <<>> do
      if unescaped_byte?(byte) do
        <<byte>>
      else
        <<"%", hex_digit(byte >>> 4), hex_digit(byte &&& 0x0F)>>
      end
    end
  end

  @doc false
  @spec url_for(t(), binary()) :: {:ok, binary()} | {:error, {:invalid_key, binary()}}
  def url_for(%__MODULE__{} = state, key) do
    with :ok <- validate_key(key) do
      {:ok, build_url(state, key)}
    end
  end

  @doc false
  @spec build_url(t(), binary()) :: binary()
  def build_url(%__MODULE__{} = state, key) when is_binary(key) do
    authority = authority(state)
    encoded = encode_key(key)

    case state.addressing do
      :virtual_host ->
        "#{state.scheme}://#{state.bucket}.#{authority}/#{encoded}"

      :path ->
        "#{state.scheme}://#{authority}/#{state.bucket}/#{encoded}"
    end
  end

  defp do_init(opts) do
    with :ok <- keyword_options(opts, init_option_names()),
         {:ok, bucket} <- fetch_option(opts, :bucket),
         :ok <- validate_bucket(bucket),
         {:ok, region} <- fetch_option(opts, :region),
         true <- is_binary(region) and region != "" and String.valid?(region),
         {:ok, credentials} <- fetch_option(opts, :credentials),
         {:ok, credentials_fun} <- credentials_fun(credentials),
         {:ok, endpoint} <- endpoint(Keyword.get(opts, :endpoint_url)),
         addressing = Keyword.get(opts, :addressing, :virtual_host),
         true <- addressing in [:virtual_host, :path],
         :ok <- validate_bucket_addressing(bucket, addressing),
         {:ok, finch} <- finch_name(Keyword.get(opts, :finch)) do
      {:ok,
       %__MODULE__{
         bucket: bucket,
         region: region,
         host: endpoint.host || "s3.#{region}.amazonaws.com",
         scheme: endpoint.scheme || "https",
         port: endpoint.port,
         addressing: addressing,
         finch: finch,
         credentials_fun: credentials_fun
       }}
    else
      {:error, :dotted_virtual_host_bucket} -> {:error, :dotted_virtual_host_bucket}
      _other -> {:error, :invalid_options}
    end
  rescue
    _exception -> {:error, :invalid_options}
  catch
    _kind, _reason -> {:error, :invalid_options}
  end

  defp do_head(state, key, deadline) do
    with {:ok, credentials} <- credentials(state, deadline),
         :ok <- remaining_ok(deadline),
         result <-
           request(
             state,
             credentials,
             deadline,
             method: :head,
             url: build_url(state, key)
           ) do
      case result do
        {:ok, %{status: 200, headers: headers}} ->
          with {:ok, etag} <- response_etag(headers),
               {:ok, size} <- response_size(headers) do
            {:ok, %{etag: etag, size: size, metadata: response_metadata(headers)}}
          end

        {:ok, %{status: 404}} ->
          {:error, :not_found}

        {:ok, %{status: status, body: body}} when status in 100..599 ->
          {:error, http_reason(status, body, credentials)}

        {:ok, %{status: status}} when status in 100..599 ->
          {:error, http_reason(status, nil, credentials)}

        {:error, _reason} = error ->
          error

        _other ->
          {:error, {:adapter, :bad_return}}
      end
    end
  end

  defp do_get(state, key, part, deadline) do
    File.rm(part)

    with {:ok, credentials} <- credentials(state, deadline),
         :ok <- remaining_ok(deadline),
         {:ok, file} <- open_download(part),
         counter = :counters.new(1, [:write_concurrency]),
         into = download_into(file, counter),
         result <-
           request(
             state,
             credentials,
             deadline,
             method: :get,
             url: build_url(state, key),
             into: into
           ) do
      :file.close(file)
      finish_get(result, counter, credentials)
    else
      {:error, {:transport, _reason}} = error -> error
      {:error, {:adapter, _reason}} = error -> error
    end
  end

  defp finish_get({:ok, %{status: 200, headers: headers}}, counter, _credentials) do
    bytes = :counters.get(counter, 1)

    with {:ok, expected} <- response_size(headers),
         true <- bytes == expected,
         {:ok, etag} <- response_etag(headers) do
      {:ok, %{etag: etag, bytes: bytes, metadata: response_metadata(headers)}}
    else
      false -> {:error, {:adapter, :short_body}}
      {:error, {:adapter, _reason}} = error -> error
    end
  end

  defp finish_get({:ok, %{status: 404}}, _counter, _credentials),
    do: {:error, :not_found}

  defp finish_get({:ok, %{status: status, body: body}}, _counter, credentials)
       when status in 100..599,
       do: {:error, http_reason(status, body, credentials)}

  defp finish_get({:ok, %{status: status}}, _counter, credentials)
       when status in 100..599,
       do: {:error, http_reason(status, nil, credentials)}

  defp finish_get({:error, _reason} = error, _counter, _credentials), do: error

  defp finish_get(_other, _counter, _credentials),
    do: {:error, {:adapter, :bad_return}}

  defp finish_download(part, dest_path) do
    case File.rename(part, dest_path) do
      :ok -> :ok
      {:error, _reason} -> {:error, {:adapter, :io}}
    end
  end

  defp do_put(state, src_path, key, opts, deadline) do
    with {:ok, stat} <- File.stat(src_path),
         true <- stat.type == :regular,
         :ok <- within_put_limit(stat.size),
         {:ok, credentials} <- credentials(state, deadline),
         :ok <- remaining_ok(deadline),
         headers = put_headers(opts, stat.size),
         body = File.stream!(src_path, @upload_chunk_bytes),
         result <-
           request(
             state,
             credentials,
             deadline,
             method: :put,
             url: build_url(state, key),
             headers: headers,
             body: body
           ) do
      finish_put(result, credentials)
    else
      false -> {:error, {:adapter, :io}}
      {:error, {:unsupported_operation, _message}} = error -> error
      {:error, {:transport, _reason}} = error -> error
      {:error, {:adapter, _reason}} = error -> error
      {:error, _reason} -> {:error, {:adapter, :io}}
    end
  end

  defp finish_put({:ok, %{status: status, headers: headers}}, _credentials)
       when status in 200..299 do
    with {:ok, etag} <- response_etag(headers) do
      {:ok, %{etag: etag}}
    end
  end

  defp finish_put({:ok, %{status: 412}}, _credentials), do: {:error, :precondition_failed}

  defp finish_put({:ok, %{status: 409, body: body}}, credentials) do
    case provider_code(body, credentials) do
      "ConditionalRequestConflict" -> {:error, :precondition_failed}
      code -> {:error, {:http, 409, code}}
    end
  end

  defp finish_put({:ok, %{status: status, body: body}}, credentials)
       when status in 100..599,
       do: {:error, http_reason(status, body, credentials)}

  defp finish_put({:ok, %{status: status}}, credentials) when status in 100..599,
    do: {:error, http_reason(status, nil, credentials)}

  defp finish_put({:error, _reason} = error, _credentials), do: error
  defp finish_put(_other, _credentials), do: {:error, {:adapter, :bad_return}}

  defp request(state, credentials, deadline, request_options) do
    time_left = remaining(deadline)

    if time_left <= 0 do
      {:error, {:transport, :timeout}}
    else
      common = [
        redirect: false,
        retry: false,
        decode_body: false,
        compressed: false,
        receive_timeout: time_left,
        pool_timeout: min(time_left, 5_000),
        aws_sigv4: [
          service: "s3",
          region: state.region,
          access_key_id: credentials.access_key_id,
          secret_access_key: credentials.secret_access_key,
          token: credentials.session_token
        ],
        finch: state.finch
      ]

      try do
        request = Req.new([])

        case Req.request(request, request_options ++ common) do
          {:ok, %{status: _status} = response} -> {:ok, response}
          {:error, exception} when is_exception(exception) -> transport_exception(exception)
          {:error, reason} when is_atom(reason) -> {:error, {:transport, reason}}
          _other -> {:error, {:adapter, :bad_return}}
        end
      rescue
        _exception -> {:error, {:adapter, :exception}}
      catch
        _kind, _reason -> {:error, {:adapter, :exception}}
      end
    end
  end

  defp transport_exception(exception) do
    # Force the Exception protocol here rather than retaining or inspecting
    # provider-specific exception structs. The text is deliberately dropped.
    _message = Exception.message(exception)

    reason =
      case Map.get(exception, :reason) do
        reason when is_atom(reason) -> reason
        {reason, _detail} when is_atom(reason) -> reason
        _other -> :request_failed
      end

    {:error, {:transport, reason}}
  rescue
    _exception -> {:error, {:transport, :request_failed}}
  end

  defp credentials(state, deadline) do
    time_left = remaining(deadline)

    if time_left <= 0 do
      {:error, {:transport, :timeout}}
    else
      task =
        Task.async(fn ->
          try do
            {:returned, state.credentials_fun.()}
          rescue
            _exception -> :unavailable
          catch
            _kind, _reason -> :unavailable
          end
        end)

      case Task.yield(task, time_left) do
        {:ok, {:returned, credentials}} ->
          validate_credentials(credentials)

        {:ok, :unavailable} ->
          {:error, {:adapter, :credentials_unavailable}}

        {:exit, _reason} ->
          {:error, {:adapter, :credentials_unavailable}}

        nil ->
          Task.shutdown(task, :brutal_kill)
          {:error, {:transport, :timeout}}
      end
    end
  end

  defp validate_credentials(credentials) when is_map(credentials) do
    access_key_id = Map.get(credentials, :access_key_id)
    secret_access_key = Map.get(credentials, :secret_access_key)
    session_token = Map.get(credentials, :session_token)

    if is_binary(access_key_id) and byte_size(access_key_id) > 0 and
         is_binary(secret_access_key) and byte_size(secret_access_key) > 0 and
         (is_nil(session_token) or is_binary(session_token)) do
      {:ok,
       %{
         access_key_id: access_key_id,
         secret_access_key: secret_access_key,
         session_token: session_token
       }}
    else
      {:error, {:adapter, :credentials_unavailable}}
    end
  end

  defp validate_credentials(_credentials),
    do: {:error, {:adapter, :credentials_unavailable}}

  defp download_into(file, counter) do
    fn {:data, data}, {request, response} ->
      if Map.get(response, :status) == 200 do
        case :file.write(file, data) do
          :ok ->
            :counters.add(counter, 1, byte_size(data))
            {:cont, {request, response}}

          {:error, _reason} ->
            raise "object-store download write failed"
        end
      else
        body = append_error_body(Map.get(response, :body), data)
        {:cont, {request, %{response | body: body}}}
      end
    end
  end

  defp append_error_body(body, data) do
    body = if is_binary(body), do: body, else: <<>>
    room = max(@max_error_body_bytes - byte_size(body), 0)

    if room == 0 do
      body
    else
      body <> binary_part(data, 0, min(byte_size(data), room))
    end
  end

  defp open_download(path) do
    case open_raw(path, [:write, :exclusive]) do
      {:ok, file} ->
        case File.chmod(path, 0o600) do
          :ok ->
            {:ok, file}

          {:error, _reason} ->
            :file.close(file)
            {:error, {:adapter, :io}}
        end

      {:error, _reason} ->
        {:error, {:adapter, :io}}
    end
  end

  defp put_headers(opts, size) do
    precondition =
      case opts.if_match do
        :none -> {"if-none-match", "*"}
        etag -> {"if-match", "\"#{etag}\""}
      end

    metadata_headers =
      opts.metadata
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, value} -> {"x-amz-meta-#{key}", value} end)

    [
      {"content-length", Integer.to_string(size)},
      {"content-type", @content_type},
      precondition
      | metadata_headers
    ]
  end

  defp response_etag(headers) do
    case first_header(headers, "etag") do
      nil ->
        {:error, {:adapter, :bad_return}}

      etag ->
        etag = strip_quotes(etag)

        if etag == "",
          do: {:error, {:adapter, :bad_return}},
          else: {:ok, etag}
    end
  end

  defp response_size(headers) do
    case first_header(headers, "content-length") do
      nil ->
        {:error, {:adapter, :bad_return}}

      value ->
        case Integer.parse(value) do
          {size, ""} when size >= 0 -> {:ok, size}
          _other -> {:error, {:adapter, :bad_return}}
        end
    end
  end

  defp response_metadata(headers) do
    headers
    |> header_pairs()
    |> Enum.reduce(%{}, fn {name, value}, metadata ->
      case String.downcase(name, :ascii) do
        "x-amz-meta-" <> key when key != "" ->
          Map.put_new(metadata, String.downcase(key, :ascii), value)

        _other ->
          metadata
      end
    end)
  end

  defp first_header(headers, wanted) do
    headers
    |> header_pairs()
    |> Enum.find_value(fn {name, value} ->
      if String.downcase(name, :ascii) == wanted, do: value
    end)
  end

  defp header_pairs(headers) when is_map(headers) do
    Enum.flat_map(headers, fn
      {name, values} when is_binary(name) and is_list(values) ->
        Enum.flat_map(values, fn
          value when is_binary(value) -> [{name, value}]
          _other -> []
        end)

      {name, value} when is_binary(name) and is_binary(value) ->
        [{name, value}]

      _other ->
        []
    end)
  end

  defp header_pairs(headers) when is_list(headers) do
    Enum.flat_map(headers, fn
      {name, value} when is_binary(name) and is_binary(value) ->
        [{name, value}]

      {name, values} when is_binary(name) and is_list(values) ->
        Enum.flat_map(values, fn
          value when is_binary(value) -> [{name, value}]
          _other -> []
        end)

      _other ->
        []
    end)
  end

  defp header_pairs(_headers), do: []

  defp strip_quotes(<<"\"", rest::binary>>) do
    if byte_size(rest) > 0 and :binary.last(rest) == ?" do
      binary_part(rest, 0, byte_size(rest) - 1)
    else
      <<"\"", rest::binary>>
    end
  end

  defp strip_quotes(etag), do: etag

  defp http_reason(status, _body, _credentials) when status in 300..399,
    do: {:http, status, nil}

  defp http_reason(status, body, credentials),
    do: {:http, status, provider_code(body, credentials)}

  defp provider_code(body, credentials) when is_binary(body) do
    case Regex.run(~r/<Code>([A-Za-z0-9]+)<\/Code>/, body, capture: :all_but_first) do
      [code] -> if redact_provider_code?(code, credentials), do: "Redacted", else: code
      _other -> nil
    end
  end

  defp provider_code(_body, _credentials), do: nil

  defp redact_provider_code?(code, credentials) do
    byte_size(code) >= 40 or
      Enum.any?(
        [credentials.access_key_id, credentials.secret_access_key, credentials.session_token],
        &ascii_case_equal?(code, &1)
      )
  end

  defp ascii_case_equal?(left, right)
       when is_binary(right) and byte_size(left) == byte_size(right),
       do: ascii_case_equal_bytes?(left, right)

  defp ascii_case_equal?(_left, _right), do: false

  defp ascii_case_equal_bytes?(<<>>, <<>>), do: true

  defp ascii_case_equal_bytes?(<<left, left_rest::binary>>, <<right, right_rest::binary>>) do
    ascii_lower(left) == ascii_lower(right) and
      ascii_case_equal_bytes?(left_rest, right_rest)
  end

  defp ascii_lower(byte) when byte in ?A..?Z, do: byte + (?a - ?A)
  defp ascii_lower(byte), do: byte

  defp within_put_limit(size) when size <= @put_limit, do: :ok

  defp within_put_limit(_size) do
    {:error,
     {:unsupported_operation,
      "single PUT limit is 5 GiB (5368709120 bytes); multipart upload is not implemented"}}
  end

  defp endpoint(nil), do: {:ok, %{scheme: nil, host: nil, port: nil}}

  defp endpoint(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo) and uri.path in [nil, ""] and is_nil(uri.query) and
         is_nil(uri.fragment) do
      port =
        case {uri.scheme, uri.port} do
          {"http", 80} -> nil
          {"https", 443} -> nil
          {_scheme, port} -> port
        end

      {:ok, %{scheme: uri.scheme, host: uri.host, port: port}}
    else
      {:error, :invalid_endpoint}
    end
  end

  defp endpoint(_url), do: {:error, :invalid_endpoint}

  defp authority(state) do
    host =
      if String.contains?(state.host, ":") and not String.starts_with?(state.host, "[") do
        "[#{state.host}]"
      else
        state.host
      end

    if state.port, do: "#{host}:#{state.port}", else: host
  end

  defp validate_bucket(bucket) when is_binary(bucket) do
    valid =
      byte_size(bucket) in 3..63 and String.match?(bucket, ~r/\A[a-z0-9.-]+\z/) and
        not String.contains?(bucket, "..") and
        not String.starts_with?(bucket, [".", "-"]) and
        not String.ends_with?(bucket, [".", "-"])

    if valid, do: :ok, else: {:error, :invalid_bucket}
  end

  defp validate_bucket(_bucket), do: {:error, :invalid_bucket}

  defp validate_bucket_addressing(bucket, :virtual_host) do
    if String.contains?(bucket, "."),
      do: {:error, :dotted_virtual_host_bucket},
      else: :ok
  end

  defp validate_bucket_addressing(_bucket, :path), do: :ok

  defp credentials_fun(credentials) when is_map(credentials),
    do: {:ok, fn -> credentials end}

  defp credentials_fun(credentials) when is_function(credentials, 0), do: {:ok, credentials}
  defp credentials_fun(_credentials), do: {:error, :invalid_credentials}

  defp finch_name(nil), do: {:ok, Gitility.ObjectStore.S3.Finch}
  defp finch_name(name) when is_atom(name), do: {:ok, name}
  defp finch_name(_name), do: {:error, :invalid_finch}

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

  defp init_option_names,
    do: [:bucket, :region, :credentials, :endpoint_url, :addressing, :finch]

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
          _killed_or_exited -> {:error, {:transport, :timeout}}
        end
    end
  end

  defp remaining_ok(deadline) do
    if remaining(deadline) > 0,
      do: :ok,
      else: {:error, {:transport, :timeout}}
  end

  defp remaining(deadline),
    do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp open_raw(path, modes),
    do: :file.open(String.to_charlist(path), [:raw, :binary | modes])

  defp unescaped_byte?(byte),
    do:
      byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or
        byte in ~c"-_.~/"

  defp hex_digit(value) when value < 10, do: ?0 + value
  defp hex_digit(value), do: ?A + value - 10
end

defimpl Inspect, for: Gitility.ObjectStore.S3 do
  import Inspect.Algebra

  def inspect(state, opts) do
    safe = [
      bucket: state.bucket,
      region: state.region,
      endpoint_host: state.host,
      addressing: state.addressing
    ]

    concat(["#Gitility.ObjectStore.S3<", to_doc(safe, opts), ">"])
  end
end
