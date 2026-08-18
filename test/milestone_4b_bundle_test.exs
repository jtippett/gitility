defmodule Gitility.M4b.BundleTestSupport do
  alias Gitility.{Bundle.Format, OID}

  @magic <<"GITBNDL", 0>>

  def temp_path(label) do
    Path.join(
      System.tmp_dir!(),
      "gitility-m4b-#{label}-#{System.unique_integer([:positive, :monotonic])}"
    )
  end

  def write_bundle(path, opts \\ []) do
    hash = Keyword.get(opts, :hash, :sha1)
    generation = Keyword.get(opts, :generation, 1)
    metadata = Keyword.get(opts, :metadata, %{"source_identity" => "m4b:test"})
    sections = Keyword.get(opts, :sections, [])
    refs = Keyword.get(opts, :refs, default_refs(hash))
    tail = Keyword.get(opts, :tail, <<>>)

    {file_entries, section_bytes, toc_offset} = section_entries(sections)

    toc =
      Format.encode_toc(%{
        hash_algorithm: hash,
        generation: generation,
        metadata: metadata,
        files: file_entries,
        refs: refs
      }) <> tail

    bytes =
      Format.encode_header() <>
        section_bytes <>
        toc <>
        Format.encode_trailer(toc_offset, byte_size(toc), :crypto.hash(:sha256, toc))

    File.write!(path, bytes)
    path
  end

  def write_raw_toc(path, toc, sections \\ <<>>) do
    toc_offset = 16 + byte_size(sections)

    bytes =
      Format.encode_header() <>
        sections <>
        toc <>
        Format.encode_trailer(toc_offset, byte_size(toc), :crypto.hash(:sha256, toc))

    File.write!(path, bytes)
    path
  end

  def raw_toc(opts \\ []) do
    hash = Keyword.get(opts, :hash, :sha1)
    generation = Keyword.get(opts, :generation, 1)
    metadata = Keyword.get(opts, :metadata, [{"source_identity", "m4b:test"}])
    files = Keyword.get(opts, :files, [])
    refs = Keyword.get(opts, :refs, [])
    tail = Keyword.get(opts, :tail, <<>>)

    IO.iodata_to_binary([
      <<hash_code(hash), generation::little-64, length(metadata)::little-32>>,
      Enum.map(metadata, fn {key, value} -> [lp(key), lp(value)] end),
      <<length(files)::little-32>>,
      Enum.map(files, fn file ->
        [
          <<kind_code(file.kind)>>,
          lp(file.name),
          <<file.offset::little-64, file.length::little-64, file.sha256::binary-size(32)>>
        ]
      end),
      <<length(refs)::little-32>>,
      Enum.map(refs, fn ref ->
        peeled = Map.get(ref, :peeled)

        [
          lp(ref.name),
          oid_bytes(ref.target),
          <<kind_code(ref.kind)>>,
          if(peeled, do: [<<1>>, oid_bytes(peeled)], else: <<0>>)
        ]
      end),
      tail
    ])
  end

  def rewrite_toc(path, fun) do
    bytes = File.read!(path)
    {toc_offset, toc_len, _toc_sha256} = trailer_fields(bytes)
    toc = binary_part(bytes, toc_offset, toc_len)
    prefix = binary_part(bytes, 0, toc_offset)
    new_toc = fun.(toc)

    File.write!(
      path,
      prefix <>
        new_toc <>
        Format.encode_trailer(
          toc_offset,
          byte_size(new_toc),
          :crypto.hash(:sha256, new_toc)
        )
    )
  end

  def mutate_toc(path, offset, length, replacement) do
    rewrite_toc(path, fn toc -> replace(toc, offset, length, replacement) end)
  end

  def replace(binary, offset, length, replacement) do
    prefix = binary_part(binary, 0, offset)
    suffix_offset = offset + length
    suffix = binary_part(binary, suffix_offset, byte_size(binary) - suffix_offset)
    prefix <> replacement <> suffix
  end

  def trailer_fields(bytes) do
    offset = byte_size(bytes) - 64

    <<_prefix::binary-size(offset), toc_offset::little-64, toc_len::little-64,
      toc_sha256::binary-size(32), _reserved::binary-size(8), @magic>> = bytes

    {toc_offset, toc_len, toc_sha256}
  end

  def toc_bytes(path) do
    bytes = File.read!(path)
    {toc_offset, toc_len, _sha} = trailer_fields(bytes)
    binary_part(bytes, toc_offset, toc_len)
  end

  def locate_file_field(toc, name) do
    encoded_name = IO.iodata_to_binary(lp(name))
    {name_offset, _length} = :binary.match(toc, encoded_name)
    %{kind: name_offset - 1, offset: name_offset + byte_size(encoded_name)}
  end

  def locate_ref_kind(toc, ref, hash) do
    encoded_name = IO.iodata_to_binary(lp(ref))
    {name_offset, _length} = :binary.match(toc, encoded_name)
    name_offset + byte_size(encoded_name) + OID.digest_size(hash)
  end

  def section_bytes(path) do
    {:ok, toc} = Format.parse(path)
    bytes = File.read!(path)

    Map.new(toc.sections, fn entry ->
      {entry.name, binary_part(bytes, entry.offset, entry.length)}
    end)
  end

  def default_refs(hash) do
    [
      %{name: "refs/heads/main", target: oid(hash, 1), kind: :commit, peeled: nil},
      %{name: "refs/heads/next", target: oid(hash, 2), kind: :commit, peeled: nil}
    ]
  end

  def oid(hash, byte), do: OID.new!(hash, :binary.copy(<<byte>>, OID.digest_size(hash)))

  def lp(bytes), do: [<<byte_size(bytes)::little-32>>, bytes]

  defp section_entries(sections) do
    {entries, bytes, offset} =
      Enum.reduce(sections, {[], [], 16}, fn {kind, name, contents}, {entries, bytes, offset} ->
        entry = %{
          kind: kind,
          name: name,
          offset: offset,
          length: byte_size(contents),
          sha256: :crypto.hash(:sha256, contents)
        }

        {[entry | entries], [bytes, contents], offset + byte_size(contents)}
      end)

    {Enum.reverse(entries), IO.iodata_to_binary(bytes), offset}
  end

  defp oid_bytes(%OID{bytes: bytes}), do: bytes
  defp oid_bytes(bytes), do: bytes
  defp hash_code(:sha1), do: 1
  defp hash_code(:sha256), do: 2
  defp kind_code(:pack), do: 1
  defp kind_code(:idx), do: 2
  defp kind_code(:commit), do: 1
  defp kind_code(:tag), do: 2
  defp kind_code(:tree), do: 3
  defp kind_code(:blob), do: 4
  defp kind_code({:unknown, value}), do: value
end

defmodule Gitility.M4b.BundleRangeConformanceTest do
  use Gitility.ODB.RangeBackend.Conformance,
    backend: Gitility.Bundle.RangeBackend,
    concurrency: 4,
    prepublished_synthetic: true

  alias Gitility.M4b.BundleTestSupport, as: Support

  setup_all do
    path = Support.temp_path("range-conformance.bundle")
    {pack_key, pack_bytes} = Gitility.ODB.RangeBackend.Conformance.synthetic_artifact()
    id = String.duplicate("e", 40)
    index_key = "pack-#{id}.idx"

    Support.write_bundle(path,
      refs: [],
      sections: [{:pack, Path.basename(pack_key), pack_bytes}, {:idx, index_key, "index"}]
    )

    :persistent_term.put({__MODULE__, :path}, path)

    on_exit(fn ->
      :persistent_term.erase({__MODULE__, :path})
      File.rm(path)
    end)

    :ok
  end

  def backend_init_arg, do: :persistent_term.get({__MODULE__, :path})
  def backend_artifacts, do: Support.section_bytes(backend_init_arg())
  def backend_publish_artifact(_state, _key, _bytes), do: :ok
end

defmodule Gitility.M4b.BundleRefConformanceTest do
  @bundle_path Path.join(
                 System.tmp_dir!(),
                 "gitility-m4b-ref-conformance-#{System.unique_integer([:positive, :monotonic])}.bundle"
               )

  use Gitility.RefDB.Backend.Conformance,
    backend: Gitility.Bundle.RefBackend,
    init_arg: @bundle_path,
    concurrency: 4,
    moduletag: :gitility_engine

  alias Gitility.{Ref, RefTarget}
  alias Gitility.M4b.BundleTestSupport, as: Support

  setup_all do
    Support.write_bundle(@bundle_path, refs: Support.default_refs(:sha1))

    on_exit(fn ->
      File.rm(@bundle_path)
    end)

    :ok
  end

  def backend_refs do
    Enum.map(Support.default_refs(:sha1), fn row ->
      %Ref{
        name: row.name,
        target: %RefTarget{
          kind: :direct,
          oid: row.target,
          symbolic_target: nil,
          peeled: nil
        }
      }
    end)
  end
end

defmodule Gitility.M4b.BundleTest do
  use ExUnit.Case, async: false

  alias Gitility.{Bundle, Bundle.Format, ByteRange, Error, RefDB, Repository}
  alias Gitility.M4b.BundleTestSupport, as: Support

  @moduletag :gitility_engine
  @fixtures Path.expand("../fixtures/generated", __DIR__)

  setup do
    directory = Support.temp_path("case")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)
    %{directory: directory}
  end

  test "format round-trip, deterministic publication, info, verify, and open", context do
    source = fixture("sha1-basic-packed.git")
    first = Path.join(context.directory, "first.bundle")
    second = Path.join(context.directory, "second.bundle")

    assert {:ok, receipt1} =
             Bundle.write(first, source: {:repository, source}, source_identity: "fixture:basic")

    assert {:ok, receipt2} =
             Bundle.write(second, source: {:repository, source}, source_identity: "fixture:basic")

    assert receipt1.generation == 1
    assert receipt2.generation == 1
    assert File.read!(first) == File.read!(second)
    assert :ok = Bundle.verify(first)

    assert {:ok,
            %{
              format_version: {1, 0},
              hash_algorithm: :sha1,
              generation: 1,
              source_identity: "fixture:basic",
              total_bytes: bytes
            }} = Bundle.info(first)

    assert bytes == receipt1.bytes

    hydration = Path.join(context.directory, "hydrated")
    assert {:ok, repository} = Bundle.open(first, into: {:dir, hydration})
    assert {:ok, snapshot} = Repository.snapshot(repository, :head)
    assert {:ok, file} = Gitility.read_file(snapshot, "README.md")
    assert file.data != <<>>
  end

  test "empty repositories produce legal zero-pack zero-ref bundles", context do
    source = Path.join(context.directory, "empty.git")
    {_, 0} = System.cmd("git", ["init", "--bare", source], stderr_to_stdout: true)
    path = Path.join(context.directory, "empty.bundle")

    assert {:ok, receipt} = Bundle.write(path, source: {:repository, source})
    assert receipt.files == 0
    assert receipt.refs == 0
    assert Enum.any?(receipt.warnings, &String.contains?(&1.message, "HEAD"))
    assert :ok = Bundle.verify(path)
    assert {:ok, %{files: 0, refs: 0}} = Bundle.info(path)

    assert {:ok, repository} =
             Bundle.open(path, into: {:dir, Path.join(context.directory, "odb")})

    assert {:ok, :not_found} = RefDB.resolve(repository.refs, "HEAD")
  end

  test "hostile headers, trailers, truncations, checksums, and trailing bytes are refused",
       context do
    valid = synthetic_pair_bundle(context.directory, "hostile-base")
    bytes = File.read!(valid)
    {toc_offset, toc_len, _sha} = Support.trailer_fields(bytes)

    wrong_header = copy(valid, context.directory, "wrong-header")
    mutate_file(wrong_header, 0, 8, <<"NOTBNDL", 0>>)
    assert_error(wrong_header, :invalid_argument)

    future = copy(valid, context.directory, "future-major")
    mutate_file(future, 8, 2, <<2::little-16>>)
    assert {:error, %Error{code: :unsupported_operation, message: message}} = Format.parse(future)
    assert message =~ "2"
    assert message =~ "1"

    wrong_trailer = copy(valid, context.directory, "wrong-trailer")
    mutate_file(wrong_trailer, byte_size(bytes) - 8, 8, <<"NOTBNDL", 0>>)
    assert_error(wrong_trailer, :malformed_object)

    for {label, length} <- [
          {:inside_header, 12},
          {:after_header, 16},
          {:inside_sections, 17},
          {:at_toc, toc_offset},
          {:inside_toc, toc_offset + max(toc_len - 1, 0)},
          {:inside_trailer, byte_size(bytes) - 1}
        ] do
      path = Path.join(context.directory, "truncate-#{label}.bundle")
      File.write!(path, binary_part(bytes, 0, length))
      assert_error(path, :malformed_object)
    end

    tiny = Path.join(context.directory, "tiny.bundle")
    File.write!(tiny, Format.encode_header() <> :binary.copy(<<0>>, 63))
    assert_error(tiny, :malformed_object)

    bad_sha = copy(valid, context.directory, "bad-toc-sha")
    mutate_file(bad_sha, byte_size(bytes) - 48, 1, <<255>>)
    assert_error(bad_sha, :malformed_object)

    trailing = copy(valid, context.directory, "trailing")
    File.write!(trailing, File.read!(trailing) <> "junk")
    assert_error(trailing, :malformed_object)
  end

  test "hostile section tiling, pairing, kinds, and names are validated", context do
    valid = synthetic_pair_bundle(context.directory, "section-base")
    toc = Support.toc_bytes(valid)
    pack = "pack-#{String.duplicate("a", 40)}.pack"
    index = "pack-#{String.duplicate("a", 40)}.idx"
    pack_field = Support.locate_file_field(toc, pack)
    index_field = Support.locate_file_field(toc, index)

    for {label, offset, value} <- [
          {:gap, pack_field.offset, 17},
          {:overlap, index_field.offset, 16},
          {:out_of_order, index_field.offset, 15}
        ] do
      path = copy(valid, context.directory, label)
      Support.mutate_toc(path, offset, 8, <<value::little-64>>)
      assert_error(path, :malformed_object)
    end

    missing_index = copy(valid, context.directory, "missing-index")
    Support.mutate_toc(missing_index, index_field.kind, 1, <<1>>)
    assert_error(missing_index, :malformed_object)

    misordered = copy(valid, context.directory, "misordered")

    Support.rewrite_toc(misordered, fn bytes ->
      bytes
      |> Support.replace(pack_field.kind, 1, <<2>>)
      |> Support.replace(index_field.kind, 1, <<1>>)
    end)

    assert_error(misordered, :malformed_object)

    unknown = copy(valid, context.directory, "unknown-files")

    Support.rewrite_toc(unknown, fn bytes ->
      bytes
      |> Support.replace(pack_field.kind, 1, <<90>>)
      |> Support.replace(index_field.kind, 1, <<91>>)
    end)

    assert {:ok, parsed} = Format.parse(unknown)
    assert parsed.files == []
    assert length(parsed.sections) == 2

    too_long = Path.join(context.directory, "long-file-name.bundle")
    name = :binary.copy("n", 4097)

    raw =
      Support.raw_toc(
        files: [
          %{
            kind: {:unknown, 77},
            name: name,
            offset: 16,
            length: 1,
            sha256: :crypto.hash(:sha256, "x")
          }
        ]
      )

    Support.write_raw_toc(too_long, raw, "x")
    assert_error(too_long, :malformed_object)
  end

  test "hostile metadata/ref ordering, kinds, lengths, and minor tail follow v1 rules", context do
    target = Support.oid(:sha1, 1)

    for {label, metadata} <- [
          {:unsorted_metadata, [{"z", "1"}, {"source_identity", "x"}]},
          {:duplicate_metadata, [{"source_identity", "x"}, {"source_identity", "y"}]}
        ] do
      path = Path.join(context.directory, "#{label}.bundle")
      Support.write_raw_toc(path, Support.raw_toc(metadata: metadata))
      assert_error(path, :malformed_object)
    end

    for {label, refs} <- [
          {:unsorted_refs,
           [
             %{name: "refs/heads/z", target: target, kind: :commit},
             %{name: "refs/heads/a", target: target, kind: :commit}
           ]},
          {:duplicate_refs,
           [
             %{name: "refs/heads/a", target: target, kind: :commit},
             %{name: "refs/heads/a", target: target, kind: :commit}
           ]}
        ] do
      path = Path.join(context.directory, "#{label}.bundle")
      Support.write_raw_toc(path, Support.raw_toc(refs: refs))
      assert_error(path, :malformed_object)
    end

    unknown_ref = Support.temp_path("unknown-ref.bundle")

    Support.write_bundle(unknown_ref,
      refs: [%{name: "refs/heads/main", target: target, kind: :commit}]
    )

    on_exit(fn -> File.rm(unknown_ref) end)
    toc = Support.toc_bytes(unknown_ref)
    kind_offset = Support.locate_ref_kind(toc, "refs/heads/main", :sha1)
    Support.mutate_toc(unknown_ref, kind_offset, 1, <<99>>)
    assert_error(unknown_ref, :malformed_object)

    overrun = Path.join(context.directory, "length-overrun.bundle")
    toc = <<1, 1::little-64, 1::little-32, 100::little-32, "short">>
    Support.write_raw_toc(overrun, toc)
    assert_error(overrun, :malformed_object)

    tail = Path.join(context.directory, "minor-tail.bundle")
    Support.write_bundle(tail, refs: [], tail: <<222, 173, 190, 239>>)
    assert {:ok, _parsed} = Format.parse(tail)
  end

  test "TOC lengths above 64 MiB are rejected before allocation", context do
    path = Path.join(context.directory, "oversized-toc.bundle")
    toc_len = 64 * 1024 * 1024 + 1
    {:ok, file} = :file.open(String.to_charlist(path), [:write, :raw, :binary])

    try do
      :ok = :file.write(file, Format.encode_header())
      {:ok, _position} = :file.position(file, 16 + toc_len)
      sha = :binary.copy(<<0>>, 32)
      :ok = :file.write(file, Format.encode_trailer(16, toc_len, sha))
    after
      :file.close(file)
    end

    assert_error(path, :malformed_object)
  end

  test "verify catches section corruption while cheap open still accepts the TOC", context do
    path = synthetic_pair_bundle(context.directory, "corrupt-section")
    assert {:ok, toc} = Format.parse(path)
    [first | _rest] = toc.sections
    bytes = File.read!(path)
    old = :binary.at(bytes, first.offset)
    mutate_file(path, first.offset, 1, <<Bitwise.bxor(old, 1)>>)

    assert {:ok, _toc} = Format.parse(path)

    assert {:error, %Error{code: :malformed_object, message: message}} =
             Bundle.verify(path)

    assert message =~ first.name
  end

  test "range reads detect generation moves and ref refresh explicitly re-pins", context do
    path = Path.join(context.directory, "moving.bundle")
    replacement = Path.join(context.directory, "replacement.bundle")
    id = String.duplicate("a", 40)
    sections = [{:pack, "pack-#{id}.pack", "old-pack"}, {:idx, "pack-#{id}.idx", "old-index"}]

    Support.write_bundle(path,
      generation: 1,
      sections: sections,
      refs: [%{name: "refs/heads/main", target: Support.oid(:sha1, 1), kind: :commit}]
    )

    assert {:ok, range_state} = Bundle.RangeBackend.init(path)
    assert {:ok, ref_state} = Bundle.RefBackend.init(path)
    assert {:ok, old_target} = Bundle.RefBackend.resolve("refs/heads/main", ref_state)

    Support.write_bundle(replacement,
      generation: 2,
      sections: sections,
      refs: [%{name: "refs/heads/main", target: Support.oid(:sha1, 2), kind: :commit}]
    )

    :ok = File.rename(replacement, path)
    range = %ByteRange{key: "pack-#{id}.pack", offset: 0, length: 1}

    assert {:error, %Error{code: :backend_error, message: message}} =
             Bundle.RangeBackend.read_ranges([range], range_state)

    assert message =~ "generation moved"
    assert {:ok, ^old_target} = Bundle.RefBackend.resolve("refs/heads/main", ref_state)
    assert :ok = Bundle.RefBackend.refresh(ref_state)
    assert {:ok, new_target} = Bundle.RefBackend.resolve("refs/heads/main", ref_state)
    assert new_target.oid != old_target.oid
    Bundle.RefBackend.terminate(:normal, ref_state)
  end

  test "write refuses foreign destinations and increments valid bundle generations", context do
    source = Path.join(context.directory, "generation-source.git")
    File.cp_r!(fixture("sha1-basic-packed.git"), source)
    foreign = Path.join(context.directory, "foreign.bundle")
    File.write!(foreign, "do not clobber")

    assert {:error, %Error{code: :invalid_argument}} =
             Bundle.write(foreign, source: {:repository, source})

    assert File.read!(foreign) == "do not clobber"

    destination = Path.join(context.directory, "generation.bundle")
    assert {:ok, first} = Bundle.write(destination, source: {:repository, source})
    assert {:ok, first_toc} = Format.parse(destination)
    first_main = Enum.find(first_toc.refs, &(&1.name == "refs/heads/main"))
    assert {:ok, %{generation: 1}} = Bundle.info(destination)

    {parent, 0} =
      System.cmd("git", ["-C", source, "rev-parse", "HEAD^"], stderr_to_stdout: true)

    {_output, 0} =
      System.cmd(
        "git",
        ["-C", source, "update-ref", "refs/heads/main", String.trim(parent)],
        stderr_to_stdout: true
      )

    assert {:ok, second} = Bundle.write(destination, source: {:repository, source})
    assert {:ok, second_toc} = Format.parse(destination)
    second_main = Enum.find(second_toc.refs, &(&1.name == "refs/heads/main"))
    assert second.generation == first.generation + 1
    assert {:ok, %{generation: 2}} = Bundle.info(destination)
    assert second_main.target != first_main.target
  end

  test "immutable bundle open creates no sidecars beside the artifact", context do
    source = fixture("sha1-basic-packed.git")
    path = Path.join(context.directory, "immutable.bundle")
    hydration = Path.join(context.directory, "elsewhere/objects")
    assert {:ok, _receipt} = Bundle.write(path, source: {:repository, source})
    :ok = File.chmod(path, 0o444)
    before = MapSet.new(File.ls!(context.directory))

    assert {:ok, repository} = Bundle.open(path, into: {:dir, hydration})
    assert {:ok, snapshot} = Repository.snapshot(repository, :head)
    assert {:ok, _page} = Gitility.list_tree(snapshot, "", limit: 5)
    after_open = MapSet.new(File.ls!(context.directory))
    assert after_open == MapSet.put(before, "elsewhere")
  end

  defp synthetic_pair_bundle(directory, label) do
    path = Path.join(directory, "#{label}.bundle")
    id = String.duplicate("a", 40)

    Support.write_bundle(path,
      sections: [{:pack, "pack-#{id}.pack", "pack-bytes"}, {:idx, "pack-#{id}.idx", "idx"}],
      refs: [%{name: "refs/heads/main", target: Support.oid(:sha1, 1), kind: :commit}]
    )
  end

  defp copy(source, directory, label) do
    destination = Path.join(directory, "#{label}.bundle")
    File.cp!(source, destination)
    destination
  end

  defp mutate_file(path, offset, length, replacement) do
    File.write!(path, Support.replace(File.read!(path), offset, length, replacement))
  end

  defp assert_error(path, code) do
    assert {:error, %Error{code: ^code}} = Format.parse(path)
  end

  defp fixture(name), do: Path.join(@fixtures, name)
end
