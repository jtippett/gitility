defmodule Gitility.Bundle.RangeBackend do
  @moduledoc """
  Byte-range backend over pack and index sections in one immutable bundle.

  The parsed TOC hash is the pinned store identity. Every callback opens the
  path afresh, verifies that identity on the opened descriptor, and only then
  performs positional section reads. An atomic replacement can therefore
  never mix the old table with bytes from a new generation.
  """

  @behaviour Gitility.ODB.RangeBackend

  alias Gitility.{ByteRange, Bundle.Format, Error, PackDescriptor, PackManifest}

  @impl true
  def init(path) when is_binary(path) do
    path = Path.expand(path)

    with {:ok, toc} <- Format.parse(path) do
      pinned_state(path, toc)
    end
  end

  def init({:pinned, path, toc}) when is_binary(path) and is_map(toc),
    do: pinned_state(Path.expand(path), toc)

  def init(_path),
    do: {:error, Error.new(:invalid_argument, "bundle path must be a binary")}

  @impl true
  def manifest(%{toc: toc}) do
    packs =
      toc.files
      |> Enum.chunk_every(2)
      |> Enum.map(fn [pack, index] ->
        id = pack.name |> Path.rootname() |> String.replace_prefix("pack-", "")

        %PackDescriptor{
          id: id,
          pack_key: pack.name,
          index_key: index.name,
          pack_size: pack.length,
          index_size: index.length,
          etag: Base.encode16(pack.sha256, case: :lower)
        }
      end)

    {:ok,
     %PackManifest{
       version: 1,
       generation: Integer.to_string(toc.generation),
       hash: toc.hash_algorithm,
       loose: [],
       packs: packs
     }}
  end

  @impl true
  def read_ranges(ranges, state) when is_list(ranges) do
    case :file.open(String.to_charlist(state.path), [:read, :raw, :binary]) do
      {:ok, file} ->
        try do
          with :ok <- verify_identity(file, state),
               {:ok, replies} <- read_all(ranges, state.entries, file, %{}) do
            {:ok, replies}
          end
        after
          :file.close(file)
        end

      {:error, reason} ->
        backend_error("could not open pinned bundle generation", reason, state)
    end
  end

  def read_ranges(_ranges, state),
    do: backend_error("bundle ranges must be a list", :invalid_range, state)

  defp verify_identity(file, state) do
    case Format.read_trailer_identity(file) do
      {:ok, %{toc_sha256: pinned}} when pinned == state.toc_sha256 ->
        :ok

      {:ok, _identity} ->
        backend_error(
          "bundle generation moved after the backend was pinned",
          :generation_move,
          state
        )

      {:error, %Error{} = error} ->
        backend_error("bundle generation could not be revalidated", error.message, state)
    end
  end

  defp read_all([], _entries, _file, replies), do: {:ok, replies}

  defp read_all([%ByteRange{} = range | rest], entries, file, replies) do
    with {:ok, entry} <- fetch_entry(entries, range.key),
         :ok <- validate_range(range, entry),
         {:ok, bytes} <- pread_range(file, entry, range) do
      read_all(rest, entries, file, Map.put(replies, range, bytes))
    end
  end

  defp read_all([_invalid | _rest], _entries, _file, _replies),
    do: backend_error("bundle range is invalid", :invalid_range, nil)

  defp fetch_entry(entries, key) when is_binary(key) do
    case Map.fetch(entries, key) do
      {:ok, entry} -> {:ok, entry}
      :error -> backend_error("bundle range key is not in the pinned TOC", :invalid_key, nil)
    end
  end

  defp fetch_entry(_entries, _key),
    do: backend_error("bundle range key is invalid", :invalid_key, nil)

  defp validate_range(%ByteRange{offset: offset, length: length}, entry)
       when is_integer(offset) and offset >= 0 and is_integer(length) and length >= 0 do
    if offset + length <= entry.length do
      :ok
    else
      {:error, :short_read}
    end
  end

  defp validate_range(_range, _entry),
    do: backend_error("bundle range offset or length is invalid", :invalid_range, nil)

  defp pread_range(_file, _entry, %ByteRange{length: 0}), do: {:ok, <<>>}

  defp pread_range(file, entry, %ByteRange{offset: offset, length: length}) do
    case :file.pread(file, entry.offset + offset, length) do
      {:ok, bytes} when byte_size(bytes) == length -> {:ok, bytes}
      {:ok, _bytes} -> {:error, :short_read}
      :eof -> {:error, :short_read}
      {:error, reason} -> backend_error("bundle section read failed", reason, nil)
    end
  end

  defp pinned_state(path, toc) do
    entries = Map.new(toc.files, &{&1.name, &1})
    {:ok, %{path: path, toc: toc, entries: entries, toc_sha256: toc.toc_sha256}}
  end

  defp backend_error(message, reason, state) do
    generation = if state, do: state.toc.generation

    {:error,
     Error.new(:backend_error, message,
       operation: :bundle_read_ranges,
       retryable: reason in [:generation_move, :enoent],
       details: %{reason: reason, pinned_generation: generation}
     )}
  end
end
