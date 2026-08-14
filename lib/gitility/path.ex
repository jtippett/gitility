defmodule Gitility.Path do
  @moduledoc """
  Helpers for Git path bytes.

  Git paths are raw binaries — arbitrary bytes with no encoding guarantee.
  Gitility never normalizes or re-encodes them; the raw binary is always
  authoritative. These helpers exist for the boundary where paths must
  become text:

    * `display/1` — a lossy, human-readable UTF-8 string for UIs and logs.
    * `encode/1` / `decode/1` — a reversible, JSON-safe representation for
      protocols and cursors.

  The reversible encoding is percent-based: `%`, control bytes, and bytes
  that are not part of a valid UTF-8 sequence are emitted as `%XX`; valid
  printable UTF-8 passes through untouched. Any valid UTF-8 path without a
  `%` therefore encodes to itself.

      iex> Gitility.Path.encode("lib/widget.ex")
      "lib/widget.ex"

      iex> encoded = Gitility.Path.encode(<<"caf", 0xE9, ".txt">>)
      iex> Gitility.Path.decode(encoded)
      <<"caf", 0xE9, ".txt">>
  """

  @doc """
  A lossy, printable representation of a Git path for humans.

  Invalid UTF-8 byte sequences are replaced with `�` (U+FFFD). Never feed
  the result back into a query — use the raw binary or `encode/1`.
  """
  @spec display(binary()) :: String.t()
  def display(path) when is_binary(path) do
    path |> do_display([]) |> IO.iodata_to_binary()
  end

  @doc """
  A reversible, JSON-safe (valid UTF-8) representation of a Git path.

  `decode/1` restores the exact original bytes.
  """
  @spec encode(binary()) :: String.t()
  def encode(path) when is_binary(path) do
    path |> do_encode([]) |> IO.iodata_to_binary()
  end

  @doc """
  Restores the exact original path bytes from `encode/1` output.
  """
  @spec decode(String.t()) :: binary()
  def decode(encoded) when is_binary(encoded), do: do_decode(encoded, <<>>)

  defp do_display(<<grapheme::utf8, rest::binary>>, acc),
    do: do_display(rest, [acc, <<grapheme::utf8>>])

  defp do_display(<<_byte, rest::binary>>, acc), do: do_display(rest, [acc, "�"])
  defp do_display(<<>>, acc), do: acc

  defp do_encode(<<?%, rest::binary>>, acc), do: do_encode(rest, [acc, "%25"])

  defp do_encode(<<grapheme::utf8, rest::binary>>, acc) when grapheme >= 0x20,
    do: do_encode(rest, [acc, <<grapheme::utf8>>])

  defp do_encode(<<byte, rest::binary>>, acc), do: do_encode(rest, [acc, percent(byte)])
  defp do_encode(<<>>, acc), do: acc

  defp do_decode(<<?%, hi, lo, rest::binary>>, acc) do
    byte = String.to_integer(<<hi, lo>>, 16)
    do_decode(rest, <<acc::binary, byte>>)
  end

  defp do_decode(<<byte, rest::binary>>, acc), do: do_decode(rest, <<acc::binary, byte>>)
  defp do_decode(<<>>, acc), do: acc

  defp percent(byte) do
    hex = byte |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.upcase()
    "%" <> hex
  end
end
