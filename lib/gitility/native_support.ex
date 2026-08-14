defmodule Gitility.NativeSupport do
  @moduledoc false

  alias Gitility.{Error, Limits, ODB, OID, Repository}

  @known_limit_names %{
    "timeout_ms" => :timeout_ms,
    "max_objects" => :max_objects,
    "max_object_bytes" => :max_object_bytes,
    "max_total_object_bytes" => :max_total_object_bytes,
    "max_provider_requests" => :max_provider_requests,
    "max_provider_bytes" => :max_provider_bytes,
    "max_tree_entries" => :max_tree_entries,
    "max_results" => :max_results,
    "max_diff_files" => :max_diff_files,
    "max_diff_hunks" => :max_diff_hunks,
    "max_diff_lines" => :max_diff_lines,
    "max_result_bytes" => :max_result_bytes,
    "max_delta_depth" => :max_delta_depth,
    "limit" => :limit,
    "max_bytes" => :max_bytes,
    "max_total_bytes" => :max_total_bytes
  }

  def limits_map!(%Limits{} = limits) do
    limits
    |> Map.from_struct()
    |> Enum.each(fn
      {_key, value} when is_integer(value) and value > 0 ->
        :ok

      {key, _value} ->
        raise ArgumentError,
              "expected :#{key} in :limits to be a positive integer"
    end)

    Map.from_struct(limits)
  end

  def limits_map!(value) do
    raise ArgumentError,
          "expected :limits to be a Gitility.Limits struct, got: #{inspect(value)}"
  end

  def parse_oid(%OID{} = oid), do: {:ok, oid}
  def parse_oid(hex) when is_binary(hex), do: OID.parse(hex)

  def parse_oid(_value) do
    {:error, Error.new(:invalid_oid, "expected a Gitility.OID or full hexadecimal object ID")}
  end

  def oid(%OID{} = oid), do: {oid.algorithm, oid.bytes}

  def oid_from_bytes(hash, bytes),
    do: %OID{algorithm: hash, bytes: bytes}

  def store(%Repository{odb: odb}), do: store(odb)
  def store(%ODB{ref: resource, hash: hash}), do: {:ok, resource, hash}

  def store(_value) do
    {:error, Error.new(:invalid_argument, "expected a Gitility.Repository or Gitility.ODB")}
  end

  def boolean_option!(opts, key) do
    value = Keyword.fetch!(opts, key)

    if is_boolean(value) do
      value
    else
      raise ArgumentError, ":#{key} must be a boolean"
    end
  end

  def nif_error(%{code: code, message: message, retryable: retryable} = error, operation) do
    details =
      case Map.get(error, :limit) do
        nil -> %{}
        limit -> %{limit: Map.get(@known_limit_names, limit, limit)}
      end

    Error.new(code, message, retryable: retryable, operation: operation, details: details)
  end

  def invalid_argument(message), do: {:error, Error.new(:invalid_argument, message)}

  def unsupported_selector do
    {:error,
     Error.new(
       :unsupported_operation,
       "ref selectors arrive with the ref adapter milestone (0.2 / Milestone 4)"
     )}
  end
end
