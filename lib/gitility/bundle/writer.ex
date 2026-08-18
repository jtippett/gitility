defmodule Gitility.Bundle.Writer do
  @moduledoc false

  alias Gitility.Bundle.{Format, Receipt}

  @copy_chunk_bytes 8 * 1024 * 1024

  @spec write(Path.t(), keyword()) :: {:ok, Receipt.t()} | {:error, term()}
  def write(path, opts) when is_binary(path) and is_list(opts) do
    pairs = Keyword.fetch!(opts, :pairs) |> sort_pairs()
    hash = Keyword.fetch!(opts, :hash_algorithm)
    generation = Keyword.fetch!(opts, :generation)
    metadata = Keyword.fetch!(opts, :metadata)
    refs = Keyword.fetch!(opts, :refs)
    warnings = Keyword.get(opts, :warnings, [])
    directory = Path.dirname(path)
    suffix = System.unique_integer([:positive, :monotonic])
    temp = Path.join(directory, ".#{Path.basename(path)}.tmp-#{suffix}")

    try do
      with :ok <- mkdir_destination(directory),
           {:ok, output} <- File.open(temp, [:write, :binary, :exclusive]) do
        result =
          try do
            with :ok <- IO.binwrite(output, Format.encode_header()),
                 {:ok, files, toc_offset} <- stream_pairs(pairs, output, 16, []),
                 toc <-
                   Format.encode_toc(%{
                     hash_algorithm: hash,
                     generation: generation,
                     metadata: metadata,
                     files: files,
                     refs: refs
                   }),
                 toc_sha256 <- :crypto.hash(:sha256, toc),
                 :ok <- IO.binwrite(output, toc),
                 :ok <-
                   IO.binwrite(
                     output,
                     Format.encode_trailer(toc_offset, byte_size(toc), toc_sha256)
                   ),
                 :ok <- :file.sync(output) do
              bytes = toc_offset + byte_size(toc) + 64
              {:ok, files, bytes}
            end
          after
            File.close(output)
          end

        with {:ok, files, bytes} <- result,
             :ok <- File.rename(temp, path) do
          {:ok,
           %Receipt{
             path: path,
             generation: generation,
             bytes: bytes,
             files: length(files),
             refs: length(refs),
             warnings: warnings
           }}
        end
      end
    after
      File.rm(temp)
    end
  end

  defp sort_pairs(pairs) do
    Enum.sort_by(pairs, fn {pack, _index} -> Path.basename(pack) end)
  end

  defp mkdir_destination(directory) do
    case File.mkdir_p(directory) do
      :ok -> :ok
      {:error, reason} -> {:error, {:destination_directory_failed, reason}}
    end
  end

  defp stream_pairs([], _output, offset, files), do: {:ok, Enum.reverse(files), offset}

  defp stream_pairs([{pack, index} | rest], output, offset, files) do
    with {:ok, pack_entry, offset} <- stream_section(pack, :pack, output, offset),
         {:ok, index_entry, offset} <- stream_section(index, :idx, output, offset) do
      stream_pairs(rest, output, offset, [index_entry, pack_entry | files])
    end
  end

  defp stream_section(path, kind, output, offset) do
    case :file.open(String.to_charlist(path), [:read, :raw, :binary]) do
      {:ok, source} ->
        try do
          context = :crypto.hash_init(:sha256)

          with {:ok, length, context} <- copy_chunks(source, output, 0, context),
               true <- length > 0 || {:error, :empty_pack_artifact} do
            entry = %{
              kind: kind,
              name: Path.basename(path),
              offset: offset,
              length: length,
              sha256: :crypto.hash_final(context)
            }

            {:ok, entry, offset + length}
          end
        after
          :file.close(source)
        end

      {:error, reason} ->
        {:error, {:source_artifact_open_failed, reason}}
    end
  end

  defp copy_chunks(source, output, length, context) do
    case :file.read(source, @copy_chunk_bytes) do
      {:ok, bytes} ->
        with :ok <- IO.binwrite(output, bytes) do
          copy_chunks(
            source,
            output,
            length + byte_size(bytes),
            :crypto.hash_update(context, bytes)
          )
        end

      :eof ->
        {:ok, length, context}

      {:error, reason} ->
        {:error, {:source_artifact_read_failed, reason}}
    end
  end
end
