defmodule Gitility.Fetch do
  @moduledoc """
  Fetches remote Git objects and refs into a local bare repository over smart
  HTTP. This is Gitility's only write path into a real Git directory; the
  snapshot and query APIs remain read-only.

  Production callers should use `https://`. The `http://` scheme exists for
  trusted local fixtures. Authorization values go straight to the in-process
  rustls HTTP client, are never stored or logged, and Git's credential-helper
  cascade is explicitly disabled. A 401 can therefore never invoke a
  subprocess. Redirects are not followed, so an authorization header cannot
  be replayed to a moved host. The underlying transport has a fixed 20-second
  connection timeout; `:timeout_ms` is the absolute deadline for the whole
  call, including credential providers, queue residence, HTTP requests, and a
  single authentication retry.

  `:credentials` accepts a one-argument function or `{module, function, args}`.
  It receives `%{url: url, host: host, attempt: 1 | 2}` and must return
  `{:ok, %{authorization: value}}`. Provider failures are sanitized as
  `:credentials_unavailable`; neither provider error terms nor returned
  secrets are copied into the error. `retry_unauthorized: true` invokes a
  provider once more after the first 401 and never loops. The static
  `:authorization` option is mutually exclusive with a provider.

  Fetches are single-flight per `Path.expand/1` destination within one VM.
  Symlink aliases are not resolved and can defeat that key; cross-process
  races are outside this contract. A lease remains held until every attached
  native job is terminal, even if its caller dies or times out. If the Locks
  process itself restarts, its in-memory leases are lost and new fetches can
  be admitted.

  Pruning is limited to destination spaces of wildcard fetch refspecs and uses
  reverse refspec matching. Exact destinations and symbolic refs are never
  pruned.

  Transport, negotiation, and pack-verification failures precede gix's ref
  transaction and leave refs untouched. Cancellation is cooperative, so a
  `:timeout` or `:cancelled` result may race with the internal commit point;
  rerunning the idempotent fetch converges. `:cleanup_failed` means the fetch
  committed and only post-fetch cleanup failed. Prune failures are retryable.
  Keep-file failures are not: the message names the leftover `.keep`, which is
  safe to delete manually.

  By default fetches use the isolated two-worker `Gitility.FetchRuntime`.
  Passing an explicit `runtime:` may intentionally share a query runtime and
  its queue.
  """

  alias Gitility.{Error, Job, Limits, Native, NativeSupport, Runtime}
  alias Gitility.Fetch.Locks

  @default_timeout_ms 120_000
  @maximum_timeout_ms 4_294_967_296
  @maximum_beam_timer_ms 4_294_967_295
  @test_env Mix.env() == :test

  @type credential_provider ::
          (map() -> {:ok, %{authorization: binary()}} | {:error, term()})
          | {module(), atom(), [term()]}

  @spec fetch(Path.t(), String.t(), [String.t()], keyword()) ::
          {:ok, Gitility.Fetch.Result.t()} | {:error, Error.t()}
  def fetch(dest, url, refspecs, opts \\ []) do
    entered_at = System.monotonic_time(:millisecond)

    case validate(dest, url, refspecs, opts) do
      {:ok, request} -> fetch_validated(request, entered_at)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  # This tail-call boundary drops the caller's original options container
  # before anything below can raise. Only the validated fields required by
  # the operation cross it, and none enter named-process state except the
  # non-secret destination lease key.
  defp fetch_validated(request, entered_at) do
    deadline = entered_at + request.timeout_ms
    key = Path.expand(request.dest)

    with :ok <- Locks.acquire(key, request.timeout_ms) do
      try do
        run_fetch(key, deadline, request)
      after
        Locks.release(key)
      end
    end
  end

  defp run_fetch(key, deadline, request) do
    with {:ok, runtime} <- resolve_runtime(request.runtime),
         {:ok, authorization} <- authorization_for(request, 1, deadline),
         result <- submit_and_await(key, runtime, request, authorization, deadline) do
      case result do
        {:error, %Error{code: :authentication_failed}}
        when request.retry_unauthorized and not is_nil(request.credentials) ->
          with {:ok, retry_authorization} <- authorization_for(request, 2, deadline) do
            submit_and_await(key, runtime, request, retry_authorization, deadline)
          end

        other ->
          other
      end
    end
  end

  defp resolve_runtime(nil) do
    case Runtime.fetch_default() do
      runtime when is_pid(runtime) -> {:ok, runtime}
      {:error, %Error{} = error} -> {:error, %{error | operation: :fetch}}
    end
  end

  defp resolve_runtime(runtime), do: {:ok, runtime}

  defp authorization_for(%{credentials: nil, authorization: authorization}, _attempt, deadline) do
    if remaining(deadline) > 0 do
      {:ok, authorization}
    else
      timeout_error()
    end
  end

  defp authorization_for(request, attempt, deadline) do
    time_left = remaining(deadline)

    if time_left <= 0 do
      timeout_error()
    else
      context = %{url: request.url, host: request.host, attempt: attempt}

      task =
        Task.async(fn ->
          try do
            {:provider_return, invoke_provider(request.credentials, context)}
          rescue
            exception -> {:provider_exception, exception.__struct__}
          catch
            _kind, _reason -> {:provider_bad_return, :bad_return}
          end
        end)

      provider_result = await_provider(task, deadline)

      if remaining(deadline) <= 0 do
        credentials_unavailable(:timeout)
      else
        case provider_result do
          {:ok, {:provider_return, {:ok, %{authorization: authorization}}}} ->
            if validate_authorization(authorization) == :ok do
              {:ok, authorization}
            else
              credentials_unavailable(:bad_return)
            end

          {:ok, {:provider_exception, module}} when is_atom(module) ->
            credentials_unavailable(module)

          {:ok, {:provider_bad_return, :bad_return}} ->
            credentials_unavailable(:bad_return)

          {:ok, {:provider_return, _bad_return}} ->
            credentials_unavailable(:bad_return)

          :provider_timeout ->
            credentials_unavailable(:timeout)

          _sanitized_exit ->
            credentials_unavailable(:bad_return)
        end
      end
    end
  end

  defp invoke_provider(provider, context) when is_function(provider, 1), do: provider.(context)

  defp invoke_provider({module, function, args}, context) do
    apply(module, function, args ++ [context])
  end

  defp await_provider(task, deadline) do
    time_left = remaining(deadline)

    cond do
      time_left <= 0 ->
        Task.shutdown(task, :brutal_kill) || :provider_timeout

      true ->
        case Task.yield(task, min(time_left, @maximum_beam_timer_ms)) do
          nil when time_left > @maximum_beam_timer_ms ->
            await_provider(task, deadline)

          nil ->
            Task.shutdown(task, :brutal_kill) || :provider_timeout

          result ->
            result
        end
    end
  end

  defp submit_and_await(key, runtime, request, authorization, deadline) do
    time_left = remaining(deadline)

    if time_left <= 0 do
      timeout_error()
    else
      limits = NativeSupport.limits_map!(%Limits{timeout_ms: time_left})

      native_request = %{
        dest: request.dest,
        url: request.url,
        refspecs: request.refspecs,
        authorization: authorization,
        prune: request.prune
      }

      :ok = Locks.pending_submit(key)

      submission =
        try do
          NativeSupport.submit_job(runtime, :fetch, fn runtime_resource ->
            Native.job_submit_fetch(runtime_resource, native_request, limits)
          end)
        rescue
          exception ->
            :ok = Locks.submission_failed(key)
            reraise exception, __STACKTRACE__
        catch
          kind, reason ->
            :ok = Locks.submission_failed(key)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      case submission do
        {:ok, job} ->
          attach_after_submit(key, job, request.after_submit)
          await_job(job, deadline)

        {:error, %Error{} = error} ->
          :ok = Locks.submission_failed(key)
          {:error, %{error | operation: :fetch}}
      end
    end
  end

  defp attach_after_submit(key, job, after_submit) do
    try do
      if after_submit, do: after_submit.()
    rescue
      exception ->
        :ok = Locks.attach(key, job)
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        :ok = Locks.attach(key, job)
        :erlang.raise(kind, reason, __STACKTRACE__)
    else
      _ -> Locks.attach(key, job)
    end
  end

  defp await_job(job, deadline) do
    time_left = remaining(deadline)

    if time_left <= 0 do
      :ok = Job.cancel(job)
      timeout_error()
    else
      case Job.await(job, min(time_left, @maximum_beam_timer_ms)) do
        {:error, %Error{code: :await_timeout}}
        when time_left > @maximum_beam_timer_ms ->
          await_job(job, deadline)

        {:error, %Error{code: :await_timeout}} ->
          :ok = Job.cancel(job)
          timeout_error()

        {:error, %Error{} = error} ->
          {:error, %{error | operation: :fetch}}

        result ->
          result
      end
    end
  end

  defp validate(dest, url, refspecs, opts) do
    with :ok <- validate_string(dest, "destination path"),
         :ok <- validate_url(url),
         :ok <- validate_refspecs(refspecs),
         {:ok, options} <- validate_options(opts),
         :ok <- validate_option_relationships(options),
         :ok <- validate_authorization(options.authorization) do
      {:ok,
       %{
         dest: dest,
         url: url,
         host: URI.parse(url).host,
         refspecs: refspecs,
         credentials: options.credentials,
         authorization: options.authorization,
         prune: options.prune,
         timeout_ms: options.timeout_ms,
         retry_unauthorized: options.retry_unauthorized,
         runtime: options.runtime,
         after_submit: options.after_submit
       }}
    end
  end

  defp validate_string(value, label) when is_binary(value) and byte_size(value) > 0 do
    if String.valid?(value), do: :ok, else: invalid("#{label} must be valid UTF-8")
  end

  defp validate_string(_value, label), do: invalid("#{label} must be a non-empty string")

  defp validate_url(url) do
    with :ok <- validate_string(url, "fetch URL") do
      try do
        case URI.parse(url) do
          %URI{scheme: scheme, host: host}
          when scheme in ["http", "https"] and is_binary(host) and host != "" ->
            :ok

          _ ->
            invalid("fetch URL must use http:// or https://")
        end
      rescue
        _error -> invalid("fetch URL must use http:// or https://")
      end
    end
  end

  defp validate_refspecs(refspecs) when is_list(refspecs) do
    if refspecs != [] and proper_list?(refspecs) do
      Enum.reduce_while(refspecs, :ok, fn refspec, :ok ->
        cond do
          not is_binary(refspec) or not String.valid?(refspec) ->
            {:halt, invalid("fetch refspecs must be valid UTF-8 strings")}

          byte_size(refspec) == 0 ->
            {:halt, invalid("fetch refspecs must not be empty")}

          byte_size(refspec) > 4096 ->
            {:halt, invalid("fetch refspecs must not exceed 4096 bytes")}

          not destination_refspec?(refspec) ->
            {:halt, invalid("fetch refspec must have a destination: #{refspec}")}

          true ->
            {:cont, :ok}
        end
      end)
    else
      invalid("fetch refspecs must be a non-empty list")
    end
  end

  defp validate_refspecs(_refspecs), do: invalid("fetch refspecs must be a non-empty list")

  defp destination_refspec?(refspec) do
    case :binary.split(refspec, ":") do
      [_source, destination] when byte_size(destination) > 0 -> true
      _ -> false
    end
  end

  defp validate_options(opts) when is_list(opts) do
    defaults = %{
      credentials: nil,
      authorization: nil,
      prune: false,
      timeout_ms: @default_timeout_ms,
      retry_unauthorized: false,
      runtime: nil,
      after_submit: nil
    }

    if proper_list?(opts) do
      Enum.reduce_while(opts, {:ok, defaults}, fn
        {:credentials, value}, {:ok, options} ->
          if credential_provider?(value) do
            {:cont, {:ok, %{options | credentials: value}}}
          else
            {:halt,
             invalid(":credentials must be a one-argument function or {module, function, args}")}
          end

        {:authorization, value}, {:ok, options} when is_nil(value) or is_binary(value) ->
          {:cont, {:ok, %{options | authorization: value}}}

        {:prune, value}, {:ok, options} when is_boolean(value) ->
          {:cont, {:ok, %{options | prune: value}}}

        {:timeout_ms, value}, {:ok, options}
        when is_integer(value) and value > 0 and value <= @maximum_timeout_ms ->
          {:cont, {:ok, %{options | timeout_ms: value}}}

        {:retry_unauthorized, value}, {:ok, options} when is_boolean(value) ->
          {:cont, {:ok, %{options | retry_unauthorized: value}}}

        {:runtime, value}, {:ok, options}
        when (is_pid(value) or is_atom(value)) and value not in [:default, nil] ->
          {:cont, {:ok, %{options | runtime: value}}}

        {:__after_submit__, value}, {:ok, options}
        when @test_env and (is_nil(value) or is_function(value, 0)) ->
          {:cont, {:ok, %{options | after_submit: value}}}

        {key, _value}, _acc when is_atom(key) ->
          {:halt, invalid("unknown or invalid fetch option: #{inspect(key)}")}

        _malformed, _acc ->
          {:halt, invalid("fetch options must be a keyword list")}
      end)
    else
      invalid("fetch options must be a keyword list")
    end
  end

  defp validate_options(_opts), do: invalid("fetch options must be a keyword list")

  defp credential_provider?(value) when is_function(value, 1), do: true

  defp credential_provider?({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args),
       do: true

  defp credential_provider?(_value), do: false

  defp validate_option_relationships(%{credentials: credentials, authorization: authorization})
       when not is_nil(credentials) and not is_nil(authorization),
       do: invalid(":credentials and :authorization are mutually exclusive")

  defp validate_option_relationships(%{retry_unauthorized: true, credentials: nil}),
    do: invalid(":retry_unauthorized requires :credentials")

  defp validate_option_relationships(_options), do: :ok

  defp validate_authorization(nil), do: :ok

  defp validate_authorization(value) when is_binary(value) do
    if String.valid?(value) and value != "" and visible_header_value?(value) do
      :ok
    else
      invalid(":authorization must contain only visible ASCII bytes and no CR/LF")
    end
  end

  defp validate_authorization(_value),
    do: invalid(":authorization must be a visible-ASCII string")

  defp visible_header_value?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(&(&1 >= 32 and &1 <= 126))
  end

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_tail), do: false

  defp credentials_unavailable(cause) do
    {:error,
     Error.new(:credentials_unavailable, "credential provider was unavailable",
       operation: :fetch,
       cause: cause
     )}
  end

  defp timeout_error do
    {:error, Error.new(:timeout, "fetch deadline expired", operation: :fetch)}
  end

  defp invalid(message), do: {:error, Error.new(:invalid_argument, message, operation: :fetch)}

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
