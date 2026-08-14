defmodule Gitility.OID do
  @moduledoc """
  A Git object identifier: a hash algorithm plus the raw digest bytes.

  Every OID in Gitility carries its algorithm explicitly — nothing in the
  library assumes 20-byte digests. Query execution is SHA-1-only until the
  engine's SHA-256 support lands, but every type, cursor, and protocol is
  hash-agnostic from day one.

  Public functions accept full lowercase or uppercase hex strings as a
  convenience, but Gitility always returns typed OIDs.

      iex> {:ok, oid} = Gitility.OID.parse("da39a3ee5e6b4b0d3255bfef95601890afd80709")
      iex> oid.algorithm
      :sha1
      iex> Gitility.OID.to_string(oid)
      "da39a3ee5e6b4b0d3255bfef95601890afd80709"
  """

  @enforce_keys [:algorithm, :bytes]
  defstruct [:algorithm, :bytes]

  @typedoc "Supported Git object hash algorithms."
  @type algorithm :: :sha1 | :sha256

  @typedoc "A typed object ID: algorithm plus raw digest bytes."
  @type t :: %__MODULE__{algorithm: algorithm(), bytes: binary()}

  @digest_bytes %{sha1: 20, sha256: 32}
  @hex_chars ~c"0123456789abcdefABCDEF"

  @doc """
  Builds an OID from an algorithm and raw digest bytes.

  Returns `{:error, %Gitility.Error{code: :invalid_oid}}` if the byte size
  does not match the algorithm's digest size.
  """
  @spec new(algorithm(), binary()) :: {:ok, t()} | {:error, Gitility.Error.t()}
  def new(algorithm, bytes) when algorithm in [:sha1, :sha256] and is_binary(bytes) do
    if byte_size(bytes) == @digest_bytes[algorithm] do
      {:ok, %__MODULE__{algorithm: algorithm, bytes: bytes}}
    else
      {:error,
       Gitility.Error.new(
         :invalid_oid,
         "#{algorithm} digest must be #{@digest_bytes[algorithm]} bytes, got #{byte_size(bytes)}"
       )}
    end
  end

  @doc "Like `new/2` but raises `Gitility.Error` on invalid input."
  @spec new!(algorithm(), binary()) :: t()
  def new!(algorithm, bytes) do
    case new(algorithm, bytes) do
      {:ok, oid} -> oid
      {:error, error} -> raise error
    end
  end

  @doc """
  Parses a full hex object ID string, inferring the algorithm from length
  (40 hex chars → SHA-1, 64 → SHA-256). Accepts upper or lower case.

  Abbreviated IDs are not accepted here; only stores that can prove
  uniqueness resolve prefixes (see `Gitility.ODB`).
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, Gitility.Error.t()}
  def parse(hex) when is_binary(hex) do
    algorithm =
      case byte_size(hex) do
        40 -> :sha1
        64 -> :sha256
        _ -> nil
      end

    with true <- algorithm != nil,
         {:ok, bytes} <- decode_hex(hex) do
      {:ok, %__MODULE__{algorithm: algorithm, bytes: bytes}}
    else
      _ ->
        {:error,
         Gitility.Error.new(:invalid_oid, "expected a full 40- or 64-character hex object ID")}
    end
  end

  @doc "Like `parse/1` but raises `Gitility.Error` on invalid input."
  @spec parse!(String.t()) :: t()
  def parse!(hex) do
    case parse(hex) do
      {:ok, oid} -> oid
      {:error, error} -> raise error
    end
  end

  @doc "Formats an OID as a lowercase hex string."
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{bytes: bytes}), do: Base.encode16(bytes, case: :lower)

  @doc "The digest size in bytes for `algorithm`."
  @spec digest_size(algorithm()) :: pos_integer()
  def digest_size(algorithm), do: Map.fetch!(@digest_bytes, algorithm)

  defp decode_hex(hex) do
    if hex |> String.to_charlist() |> Enum.all?(&(&1 in @hex_chars)) do
      Base.decode16(hex, case: :mixed)
    else
      :error
    end
  end

  defimpl String.Chars do
    def to_string(oid), do: Gitility.OID.to_string(oid)
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(oid, _opts) do
      concat([
        "#Gitility.OID<",
        Atom.to_string(oid.algorithm),
        ":",
        Gitility.OID.to_string(oid),
        ">"
      ])
    end
  end
end
