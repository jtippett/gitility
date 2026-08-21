defmodule Gitility.RefName do
  @moduledoc false

  @maximum_bytes 4_096
  @maximum_component_bytes 255
  @forbidden_bytes [0x7E, 0x5E, 0x3A, 0x3F, 0x2A, 0x5B, 0x5C]

  @spec validate(term()) :: :ok | {:error, atom()}
  def validate(name) when is_binary(name) do
    components = :binary.split(name, "/", [:global])

    cond do
      byte_size(name) == 0 ->
        {:error, :empty}

      byte_size(name) > @maximum_bytes ->
        {:error, :too_long}

      name == "@" ->
        {:error, :invalid_name}

      String.contains?(name, "@{") ->
        {:error, :invalid_sequence}

      String.ends_with?(name, ".") ->
        {:error, :invalid_component}

      Enum.any?(components, &(byte_size(&1) > @maximum_component_bytes)) ->
        {:error, :component_too_long}

      not valid_full_name?(name) ->
        {:error, :invalid_name}

      Enum.all?(components, &valid_component?/1) ->
        :ok

      true ->
        {:error, :invalid_component}
    end
  end

  def validate(_name), do: {:error, :invalid_type}

  @spec valid?(term()) :: boolean()
  def valid?(name), do: validate(name) == :ok

  @spec valid_branch?(term()) :: boolean()
  def valid_branch?(<<"refs/heads/", suffix::binary>> = name) when byte_size(suffix) > 0 do
    String.valid?(name) and valid?(name)
  end

  def valid_branch?(_name), do: false

  defp valid_full_name?(name) do
    :binary.match(name, "/") != :nomatch or
      Enum.all?(:binary.bin_to_list(name), fn byte -> byte in ?A..?Z or byte == ?_ end)
  end

  defp valid_component?(component) do
    component != "" and component != "." and component != ".." and
      not String.starts_with?(component, ".") and
      not String.ends_with?(component, ".lock") and
      not String.contains?(component, "..") and
      Enum.all?(:binary.bin_to_list(component), fn byte ->
        byte > 0x20 and byte != 0x7F and byte not in @forbidden_bytes
      end)
  end
end
