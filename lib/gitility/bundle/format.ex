defmodule Gitility.Bundle.Format do
  @moduledoc """
  Pure encoder and strict positional parser for Gitility bundle format v1.

  Opening verifies the header, EOF trailer, TOC identity, bounds, section
  tiling, pack/index pairing, and the complete metadata/ref grammar. Unknown
  metadata keys and FILE kinds remain minor-additive space, except for the
  reserved `shallow_roots` feature gate, which v1 readers refuse rather than
  silently misreading shallow history. Section payload hashes are
  intentionally deferred to `Gitility.Bundle.verify/1`.
  """

  alias Gitility.{Error, OID}

  @magic <<"GITBNDL", 0>>
  @major 1
  @minor 0
  @header_size 16
  @trailer_size 64
  @minimum_size @header_size + @trailer_size
  @max_toc_len 64 * 1024 * 1024

  @type file_kind :: :pack | :idx | {:unknown, 0..255}
  @type file_entry :: %{
          kind: file_kind(),
          name: binary(),
          offset: non_neg_integer(),
          length: pos_integer(),
          sha256: <<_::256>>
        }
  @type ref_entry :: %{
          name: binary(),
          target: binary(),
          kind: Gitility.Object.object_type(),
          peeled: binary() | nil
        }
  @type toc :: %{
          format_major: pos_integer(),
          format_minor: non_neg_integer(),
          hash_algorithm: OID.algorithm(),
          generation: pos_integer(),
          metadata: %{binary() => binary()},
          files: [file_entry()],
          sections: [file_entry()],
          refs: [ref_entry()],
          toc_offset: non_neg_integer(),
          toc_len: non_neg_integer(),
          toc_sha256: <<_::256>>,
          file_size: non_neg_integer()
        }

  @doc "Parses and structurally validates one bundle without hashing section payloads."
  @spec parse(Path.t()) :: {:ok, toc()} | {:error, Error.t()}
  def parse(path) when is_binary(path) do
    case :file.open(String.to_charlist(path), [:read, :raw, :binary]) do
      {:ok, file} ->
        try do
          parse_file(file)
        after
          :file.close(file)
        end

      {:error, reason} ->
        {:error,
         Error.new(:invalid_argument, "could not open gitility bundle",
           operation: :bundle_parse,
           details: %{reason: reason}
         )}
    end
  rescue
    exception -> malformed("bundle parser crashed safely", Exception.message(exception))
  catch
    kind, value -> malformed("bundle parser caught malformed input", "#{kind}: #{inspect(value)}")
  end

  def parse(_path),
    do:
      {:error,
       Error.new(:invalid_argument, "bundle path must be a binary", operation: :bundle_parse)}

  @doc false
  @spec read_trailer_identity(:file.io_device()) ::
          {:ok, %{file_size: non_neg_integer(), toc_sha256: binary()}} | {:error, Error.t()}
  def read_trailer_identity(file) do
    with {:ok, size} <- file_size(file),
         true <- size >= @minimum_size || malformed("bundle is smaller than 80 bytes"),
         {:ok, trailer} <- pread_exact(file, size - @trailer_size, @trailer_size, "trailer"),
         {:ok, decoded} <- decode_trailer(trailer, size) do
      {:ok, %{file_size: size, toc_sha256: decoded.toc_sha256}}
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @doc "Encodes the fixed bundle v1 header."
  @spec encode_header() :: binary()
  def encode_header, do: <<@magic, @major::little-16, @minor::little-16, 0::little-32>>

  @doc "Encodes a deterministically ordered bundle v1 table of contents."
  @spec encode_toc(map()) :: binary()
  def encode_toc(%{
        hash_algorithm: hash_algorithm,
        generation: generation,
        metadata: metadata,
        files: files,
        refs: refs
      }) do
    metadata = Enum.sort_by(metadata, &elem(&1, 0))
    refs = Enum.sort_by(refs, & &1.name)

    IO.iodata_to_binary([
      <<encode_hash(hash_algorithm), generation::little-64, length(metadata)::little-32>>,
      Enum.map(metadata, fn {key, value} -> [length_prefixed(key), length_prefixed(value)] end),
      <<length(files)::little-32>>,
      Enum.map(files, &encode_file/1),
      <<length(refs)::little-32>>,
      Enum.map(refs, &encode_ref/1)
    ])
  end

  @doc "Encodes the fixed bundle v1 trailer."
  @spec encode_trailer(non_neg_integer(), non_neg_integer(), <<_::256>>) :: binary()
  def encode_trailer(toc_offset, toc_len, <<toc_sha256::binary-size(32)>>) do
    <<toc_offset::little-64, toc_len::little-64, toc_sha256::binary, 0::little-64, @magic>>
  end

  defp parse_file(file) do
    with {:ok, size} <- file_size(file),
         {:ok, header} <- pread_header(file, size),
         {:ok, version} <- decode_header(header),
         true <- size >= @minimum_size || malformed("bundle is smaller than 80 bytes"),
         {:ok, trailer} <- pread_exact(file, size - @trailer_size, @trailer_size, "trailer"),
         {:ok, trailer} <- decode_trailer(trailer, size),
         true <-
           trailer.toc_len <= @max_toc_len ||
             malformed("TOC length exceeds the 64 MiB sanity ceiling"),
         {:ok, toc_bytes} <-
           pread_exact(file, trailer.toc_offset, trailer.toc_len, "table of contents"),
         true <-
           :crypto.hash(:sha256, toc_bytes) == trailer.toc_sha256 ||
             malformed("TOC sha256 does not match the trailer"),
         {:ok, toc} <- parse_toc(toc_bytes, trailer.toc_offset) do
      {:ok,
       Map.merge(toc, %{
         format_major: version.major,
         format_minor: version.minor,
         toc_offset: trailer.toc_offset,
         toc_len: trailer.toc_len,
         toc_sha256: trailer.toc_sha256,
         file_size: size
       })}
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp pread_header(file, size) do
    length = min(size, @header_size)

    case :file.pread(file, 0, length) do
      {:ok, bytes} -> {:ok, bytes}
      :eof -> {:ok, <<>>}
      {:error, reason} -> malformed("could not read bundle header", inspect(reason))
    end
  end

  defp decode_header(bytes) do
    cond do
      byte_size(bytes) < 8 or binary_part(bytes, 0, min(byte_size(bytes), 8)) != @magic ->
        {:error, Error.new(:invalid_argument, "not a gitility bundle", operation: :bundle_parse)}

      byte_size(bytes) != @header_size ->
        malformed("bundle header is truncated")

      true ->
        case bytes do
          <<@magic, major::little-16, minor::little-16, reserved::little-32>> ->
            cond do
              major > @major ->
                {:error,
                 Error.new(
                   :unsupported_operation,
                   "bundle format major #{major} is newer than reader major #{@major}",
                   operation: :bundle_parse,
                   details: %{bundle_major: major, reader_major: @major}
                 )}

              major != @major ->
                malformed("bundle format major #{major} is not version #{@major}")

              reserved != 0 ->
                malformed("bundle header reserved bytes are not zero")

              true ->
                {:ok, %{major: major, minor: minor}}
            end
        end
    end
  end

  defp decode_trailer(
         <<toc_offset::little-64, toc_len::little-64, toc_sha256::binary-size(32),
           reserved::little-64, magic::binary-size(8)>>,
         size
       ) do
    cond do
      magic != @magic ->
        malformed("bundle trailer magic is invalid")

      reserved != 0 ->
        malformed("bundle trailer reserved bytes are not zero")

      toc_offset < @header_size ->
        malformed("bundle TOC offset is before the section region")

      toc_offset + toc_len + @trailer_size != size ->
        malformed("bundle trailer bounds do not end exactly at EOF")

      true ->
        {:ok, %{toc_offset: toc_offset, toc_len: toc_len, toc_sha256: toc_sha256}}
    end
  end

  defp decode_trailer(_bytes, _size), do: malformed("bundle trailer is truncated")

  defp parse_toc(bytes, toc_offset) do
    with {:ok, hash_code, rest} <- take_u8(bytes, "hash algorithm"),
         {:ok, hash_algorithm} <- decode_hash(hash_code),
         {:ok, generation, rest} <- take_u64(rest, "generation"),
         true <- generation >= 1 || malformed("bundle generation must be at least 1"),
         {:ok, metadata_count, rest} <- take_u32(rest, "metadata count"),
         {:ok, metadata, rest} <- parse_metadata(metadata_count, rest, nil, []),
         :ok <- validate_metadata(metadata),
         {:ok, file_count, rest} <- take_u32(rest, "file count"),
         {:ok, sections, rest} <- parse_files(file_count, rest, MapSet.new(), []),
         :ok <- validate_tiling(sections, toc_offset),
         :ok <- validate_pairs(Enum.filter(sections, &(&1.kind in [:pack, :idx])), hash_algorithm),
         {:ok, ref_count, rest} <- take_u32(rest, "ref count"),
         {:ok, refs, _minor_tail} <-
           parse_refs(ref_count, rest, hash_algorithm, nil, []) do
      {:ok,
       %{
         hash_algorithm: hash_algorithm,
         generation: generation,
         metadata: Map.new(metadata),
         files: Enum.filter(sections, &(&1.kind in [:pack, :idx])),
         sections: sections,
         refs: refs
       }}
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp parse_metadata(count, bytes, previous, entries) do
    if count > div(byte_size(bytes), 9) do
      malformed("metadata count exceeds the remaining TOC bytes")
    else
      do_parse_metadata(count, bytes, previous, entries)
    end
  end

  defp do_parse_metadata(0, bytes, _previous, entries),
    do: {:ok, Enum.reverse(entries), bytes}

  defp do_parse_metadata(count, bytes, previous, entries) do
    with {:ok, key, rest} <- take_length_prefixed(bytes, 1, 4096, "metadata key"),
         true <- String.valid?(key) || malformed("metadata key is not UTF-8"),
         true <-
           (is_nil(previous) or key > previous) ||
             malformed("metadata keys are not strictly sorted and unique"),
         {:ok, value, rest} <- take_length_prefixed(rest, 0, 65_536, "metadata value"),
         true <- String.valid?(value) || malformed("metadata value is not UTF-8") do
      do_parse_metadata(count - 1, rest, key, [{key, value} | entries])
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp validate_metadata(metadata) do
    cond do
      Enum.any?(metadata, &(elem(&1, 0) == "shallow_roots")) ->
        {:error,
         Error.new(
           :unsupported_operation,
           "bundle metadata key shallow_roots is reserved and unsupported by format v1",
           operation: :bundle_parse,
           details: %{metadata_key: "shallow_roots"}
         )}

      Enum.any?(metadata, &(elem(&1, 0) == "source_identity")) ->
        :ok

      true ->
        malformed("required metadata key source_identity is missing")
    end
  end

  defp parse_files(count, bytes, names, entries) do
    if count > div(byte_size(bytes), 54) do
      malformed("file count exceeds the remaining TOC bytes")
    else
      do_parse_files(count, bytes, names, entries)
    end
  end

  defp do_parse_files(0, bytes, _names, entries), do: {:ok, Enum.reverse(entries), bytes}

  defp do_parse_files(count, bytes, names, entries) do
    with {:ok, kind_code, rest} <- take_u8(bytes, "file kind"),
         {:ok, name, rest} <- take_length_prefixed(rest, 1, 4096, "file name"),
         true <- String.valid?(name) || malformed("file name is not UTF-8"),
         true <-
           not MapSet.member?(names, name) || malformed("file names are not unique: #{name}"),
         {:ok, offset, rest} <- take_u64(rest, "file offset"),
         {:ok, length, rest} <- take_u64(rest, "file length"),
         true <- length >= 1 || malformed("file section #{name} has zero length"),
         {:ok, sha256, rest} <- take_bytes(rest, 32, "file sha256") do
      entry = %{
        kind: decode_file_kind(kind_code),
        name: name,
        offset: offset,
        length: length,
        sha256: sha256
      }

      do_parse_files(count - 1, rest, MapSet.put(names, name), [entry | entries])
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp parse_refs(count, bytes, hash, previous, refs) do
    minimum = 4 + 1 + OID.digest_size(hash) + 1 + 1

    if count > div(byte_size(bytes), minimum) do
      malformed("ref count exceeds the remaining TOC bytes")
    else
      do_parse_refs(count, bytes, hash, previous, refs)
    end
  end

  defp do_parse_refs(0, bytes, _hash, _previous, refs),
    do: {:ok, Enum.reverse(refs), bytes}

  defp do_parse_refs(count, bytes, hash, previous, refs) do
    oid_size = OID.digest_size(hash)

    with {:ok, name, rest} <- take_length_prefixed(bytes, 1, 4096, "ref name"),
         true <-
           (is_nil(previous) or name > previous) ||
             malformed("ref names are not strictly sorted and unique"),
         {:ok, target, rest} <- take_bytes(rest, oid_size, "ref target"),
         {:ok, kind_code, rest} <- take_u8(rest, "ref kind"),
         {:ok, kind} <- decode_ref_kind(kind_code),
         {:ok, peeled_flag, rest} <- take_u8(rest, "ref peeled flag"),
         {:ok, peeled, rest} <- take_peeled(peeled_flag, rest, oid_size) do
      ref = %{name: name, target: target, kind: kind, peeled: peeled}
      do_parse_refs(count - 1, rest, hash, name, [ref | refs])
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp take_peeled(0, bytes, _oid_size), do: {:ok, nil, bytes}
  defp take_peeled(1, bytes, oid_size), do: take_bytes(bytes, oid_size, "peeled ref target")
  defp take_peeled(flag, _bytes, _oid_size), do: malformed("unknown ref peeled flag #{flag}")

  defp validate_tiling(sections, toc_offset) do
    sections
    |> Enum.reduce_while({:ok, @header_size}, fn entry, {:ok, expected} ->
      if entry.offset == expected do
        {:cont, {:ok, expected + entry.length}}
      else
        {:halt,
         malformed("file section #{entry.name} starts at #{entry.offset}, expected #{expected}")}
      end
    end)
    |> case do
      {:ok, ^toc_offset} -> :ok
      {:ok, end_offset} -> malformed("file sections end at #{end_offset}, expected #{toc_offset}")
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp validate_pairs([], _hash), do: :ok

  defp validate_pairs([%{kind: :pack, name: pack}, %{kind: :idx, name: index} | rest], hash) do
    with {:ok, pack_stem} <- pack_stem(pack, ".pack", hash),
         {:ok, ^pack_stem} <- pack_stem(index, ".idx", hash) do
      validate_pairs(rest, hash)
    else
      _other -> malformed("pack/index pair #{pack} and #{index} does not share a valid stem")
    end
  end

  defp validate_pairs([%{kind: :pack, name: name} | _rest], _hash),
    do: malformed("pack file #{name} is missing its adjacent idx partner")

  defp validate_pairs([%{kind: :idx, name: name} | _rest], _hash),
    do: malformed("idx file #{name} is not preceded by its pack partner")

  defp pack_stem(name, extension, hash) do
    digest_length = if hash == :sha1, do: 40, else: 64
    pattern = ~r/\A(pack-[0-9a-f]{#{digest_length}})#{Regex.escape(extension)}\z/

    case Regex.run(pattern, name) do
      [_, stem] -> {:ok, stem}
      _other -> {:error, :invalid_pack_name}
    end
  end

  defp take_length_prefixed(bytes, minimum, maximum, label) do
    with {:ok, length, rest} <- take_u32(bytes, "#{label} length"),
         true <- length >= minimum || malformed("#{label} is shorter than #{minimum} bytes"),
         true <- length <= maximum || malformed("#{label} exceeds #{maximum} bytes"),
         {:ok, value, rest} <- take_bytes(rest, length, label) do
      {:ok, value, rest}
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp take_u8(<<value, rest::binary>>, _label), do: {:ok, value, rest}
  defp take_u8(_bytes, label), do: malformed("TOC ended while reading #{label}")

  defp take_u32(<<value::little-32, rest::binary>>, _label), do: {:ok, value, rest}
  defp take_u32(_bytes, label), do: malformed("TOC ended while reading #{label}")

  defp take_u64(<<value::little-64, rest::binary>>, _label), do: {:ok, value, rest}
  defp take_u64(_bytes, label), do: malformed("TOC ended while reading #{label}")

  defp take_bytes(bytes, length, _label) when byte_size(bytes) >= length do
    <<value::binary-size(length), rest::binary>> = bytes
    {:ok, value, rest}
  end

  defp take_bytes(_bytes, _length, label),
    do: malformed("TOC length prefix overruns while reading #{label}")

  defp pread_exact(_file, _offset, 0, _label), do: {:ok, <<>>}

  defp pread_exact(file, offset, length, label) do
    case :file.pread(file, offset, length) do
      {:ok, bytes} when byte_size(bytes) == length -> {:ok, bytes}
      {:ok, _bytes} -> malformed("short read while reading #{label}")
      :eof -> malformed("unexpected EOF while reading #{label}")
      {:error, reason} -> malformed("could not read #{label}", inspect(reason))
    end
  end

  defp file_size(file) do
    case :file.position(file, :eof) do
      {:ok, size} -> {:ok, size}
      {:error, reason} -> malformed("could not determine bundle size", inspect(reason))
    end
  end

  defp decode_hash(1), do: {:ok, :sha1}
  defp decode_hash(2), do: {:ok, :sha256}
  defp decode_hash(value), do: malformed("unknown bundle hash algorithm #{value}")

  defp encode_hash(:sha1), do: 1
  defp encode_hash(:sha256), do: 2

  defp decode_file_kind(1), do: :pack
  defp decode_file_kind(2), do: :idx
  defp decode_file_kind(value), do: {:unknown, value}

  defp decode_ref_kind(1), do: {:ok, :commit}
  defp decode_ref_kind(2), do: {:ok, :tag}
  defp decode_ref_kind(3), do: {:ok, :tree}
  defp decode_ref_kind(4), do: {:ok, :blob}
  defp decode_ref_kind(value), do: malformed("unknown ref kind #{value}")

  defp encode_file(entry) do
    [
      <<encode_file_kind(entry.kind)>>,
      length_prefixed(entry.name),
      <<entry.offset::little-64, entry.length::little-64, entry.sha256::binary-size(32)>>
    ]
  end

  defp encode_ref(ref) do
    target = oid_bytes(ref.target)
    peeled = Map.get(ref, :peeled)

    [
      length_prefixed(ref.name),
      target,
      <<encode_ref_kind(ref.kind)>>,
      if(peeled, do: [<<1>>, oid_bytes(peeled)], else: <<0>>)
    ]
  end

  defp encode_file_kind(:pack), do: 1
  defp encode_file_kind(:idx), do: 2
  defp encode_file_kind({:unknown, value}), do: value

  defp encode_ref_kind(:commit), do: 1
  defp encode_ref_kind(:tag), do: 2
  defp encode_ref_kind(:tree), do: 3
  defp encode_ref_kind(:blob), do: 4

  defp oid_bytes(%OID{bytes: bytes}), do: bytes
  defp oid_bytes(bytes) when is_binary(bytes), do: bytes

  defp length_prefixed(bytes), do: [<<byte_size(bytes)::little-32>>, bytes]

  defp malformed(message, cause \\ nil) do
    {:error,
     Error.new(:malformed_object, message,
       operation: :bundle_parse,
       cause: cause
     )}
  end
end
