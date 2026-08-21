defmodule Gitility.TestSupport.MinioHelper do
  @moduledoc false

  @region "us-east-1"

  @doc false
  def create_bucket_from_env! do
    case create_bucket_from_env() do
      :ok ->
        :ok

      {:error, reason} ->
        raise "unable to prepare the MinIO conformance bucket: #{format_reason(reason)}"
    end
  end

  @doc false
  def create_bucket_from_env do
    with {:ok, endpoint} <- fetch_env("GITILITY_MINIO_URL"),
         {:ok, access_key_id} <- fetch_env("GITILITY_MINIO_KEY"),
         {:ok, secret_access_key} <- fetch_env("GITILITY_MINIO_SECRET"),
         {:ok, bucket} <- fetch_env("GITILITY_MINIO_BUCKET") do
      options = [
        method: :put,
        url: String.trim_trailing(endpoint, "/") <> "/" <> bucket,
        body: "",
        redirect: false,
        retry: false,
        decode_body: false,
        aws_sigv4: [
          service: "s3",
          region: @region,
          access_key_id: access_key_id,
          secret_access_key: secret_access_key
        ]
      ]

      request = Req.new([])

      case Req.request(request, options) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: 409, body: body}} when is_binary(body) ->
          if String.contains?(body, ["BucketAlreadyOwnedByYou", "BucketAlreadyExists"]) do
            :ok
          else
            {:error, {:http, 409}}
          end

        {:ok, %{status: status}} when status in 100..599 ->
          {:error, {:http, status}}

        {:error, _reason} ->
          {:error, :request_failed}

        _other ->
          {:error, :bad_return}
      end
    end
  rescue
    _exception -> {:error, :request_failed}
  catch
    _kind, _reason -> {:error, :request_failed}
  end

  defp fetch_env(name) do
    case System.get_env(name) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _other -> {:error, {:missing_env, name}}
    end
  end

  defp format_reason({:missing_env, name}), do: "#{name} is not set"
  defp format_reason({:http, status}), do: "HTTP #{status}"
  defp format_reason(:request_failed), do: "request failed"
  defp format_reason(:bad_return), do: "adapter returned an invalid response"
end
