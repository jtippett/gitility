defmodule Gitility.M4c.CountingRangeBackend do
  @behaviour Gitility.ODB.RangeBackend

  @impl true
  def init({delegate, arg, counter}) do
    with {:ok, state} <- delegate.init(arg) do
      {:ok, %{delegate: delegate, state: state, counter: counter}}
    end
  end

  @impl true
  def manifest(config), do: config.delegate.manifest(config.state)

  @impl true
  def read_ranges(ranges, config) do
    Agent.update(config.counter, fn count -> count + 1 end)
    config.delegate.read_ranges(ranges, config.state)
  end

  @impl true
  def terminate(reason, config) do
    if Code.ensure_loaded?(config.delegate) and function_exported?(config.delegate, :terminate, 2) do
      config.delegate.terminate(reason, config.state)
    else
      :ok
    end
  end
end

defmodule Gitility.M4c.EmptyRangeBackend do
  @behaviour Gitility.ODB.RangeBackend

  @impl true
  def init(generation), do: {:ok, generation}

  @impl true
  def manifest(generation) do
    {:ok,
     %Gitility.PackManifest{
       version: 1,
       generation: generation,
       hash: :sha1,
       packs: [],
       loose: []
     }}
  end

  @impl true
  def read_ranges(_ranges, _generation), do: {:error, :unexpected_range_read}
end

defmodule Gitility.M4c.BundleDestinationTest do
  use ExUnit.Case, async: false

  alias Gitility.{Bundle, Bundle.Format, Error, Limits, ODB, RefDB, Repository}
  alias Gitility.ODB.PackFetch
  alias Gitility.ODB.RangeBackend.LocalDirectory

  @moduletag :gitility_engine
  @fixtures Path.expand("../fixtures/generated", __DIR__)

  setup do
    directory = Gitility.RangeTestSupport.temp_dir("m4c-case")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)
    %{directory: directory}
  end

  test "cold hydration writes a verified ODB-only bundle and cleans only scratch", context do
    published = publish("sha1-basic-packed.git", "cold")
    path = Path.join(context.directory, "cold.bundle")
    {:ok, state} = LocalDirectory.init(published)
    {:ok, manifest} = LocalDirectory.manifest(state)
    before = bundle_scratch_directories()

    assert {:ok, supervisor, odb} = start_bundle(published, path)
    [scratch] = MapSet.difference(bundle_scratch_directories(), before) |> MapSet.to_list()

    assert File.regular?(path)
    assert File.dir?(scratch)
    assert {:ok, %{mode: mode}} = File.stat(scratch)
    assert Bitwise.band(mode, 0o777) == 0o700
    assert :ok = Bundle.verify(path)

    assert {:ok, info} = Bundle.info(path)
    assert info.generation == 1
    assert info.ref_count == 0
    assert div(info.file_count, 2) == length(manifest.packs)
    assert info.source_identity == "packfetch:generation:" <> manifest.generation

    assert {:ok, source} = Repository.open(fixture("sha1-basic-packed.git"))
    head = Gitility.RangeTestSupport.fixture_oid(:sha1_basic_head)
    assert ODB.read(odb, head) == ODB.read(source.odb, head)

    stop(supervisor)
    refute File.exists?(scratch)
    assert File.regular?(path)
  end

  test "warm restart performs zero remote range reads and leaves bytes untouched", context do
    published = publish("sha1-basic-packed.git", "warm")
    path = Path.join(context.directory, "warm.bundle")
    assert {:ok, first, _odb} = start_bundle(published, path)
    stop(first)
    before = File.read!(path)
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    {:ok, state} = LocalDirectory.init(published)
    {:ok, manifest} = LocalDirectory.manifest(state)
    pair_bytes = Enum.sum(Enum.map(manifest.packs, &(&1.pack_size + &1.index_size)))

    assert {:ok, second, odb} =
             start_bundle(
               {Gitility.M4c.CountingRangeBackend, {LocalDirectory, published, counter}},
               path,
               max_hydration_bytes: pair_bytes - 1
             )

    assert Agent.get(counter, & &1) == 0
    assert File.read!(path) == before
    assert {:ok, %{generation: 1}} = Bundle.info(path)
    assert {:ok, stats} = ODB.stats(odb)
    assert stats.packs_hydrated == 0
    assert stats.packs_skipped == 1
    stop(second)
    Agent.stop(counter)
  end

  test "a partial warm start fetches only the new pair and advances generation", context do
    published = publish("sha1-basic-packed.git", "partial")
    path = Path.join(context.directory, "partial.bundle")
    assert {:ok, first, _odb} = start_bundle(published, path)
    stop(first)
    add_one_pair(published)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    assert {:ok, second, odb} =
             start_bundle(
               {Gitility.M4c.CountingRangeBackend, {LocalDirectory, published, counter}},
               path
             )

    assert Agent.get(counter, & &1) > 0
    assert {:ok, stats} = ODB.stats(odb)
    assert stats.packs_hydrated == 1
    assert stats.packs_skipped == 1
    assert :ok = Bundle.verify(path)
    assert {:ok, %{generation: 2, file_count: 4}} = Bundle.info(path)
    stop(second)
    Agent.stop(counter)
  end

  test "a corrupt bundle section is omitted, refetched, and repaired", context do
    published = publish("sha1-basic-packed.git", "self-heal")
    path = Path.join(context.directory, "self-heal.bundle")
    assert {:ok, first, _odb} = start_bundle(published, path)
    stop(first)
    {:ok, toc} = Format.parse(path)
    [section | _rest] = toc.files
    corrupt_byte(path, section.offset)
    assert {:error, %Error{code: :malformed_object}} = Bundle.verify(path)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    assert {:ok, second, _odb} =
             start_bundle(
               {Gitility.M4c.CountingRangeBackend, {LocalDirectory, published, counter}},
               path
             )

    assert Agent.get(counter, & &1) > 0
    assert :ok = Bundle.verify(path)
    assert {:ok, %{generation: 2}} = Bundle.info(path)
    stop(second)
    Agent.stop(counter)
  end

  test "a foreign destination is never clobbered", context do
    published = publish("sha1-basic-packed.git", "never-clobber")
    path = Path.join(context.directory, "foreign.bundle")
    File.write!(path, "leave me alone")

    assert {:error, %Error{code: :invalid_argument}} =
             PackFetch.start_link(
               backend: {LocalDirectory, published},
               into: {:bundle, path},
               limits: generous_limits()
             )

    assert File.read!(path) == "leave me alone"
  end

  test "a warm bundle with a different hash family is refused unchanged", context do
    published = publish("sha1-basic-packed.git", "hash-family")
    path = Path.join(context.directory, "sha256.bundle")
    write_empty_bundle(path, hash: :sha256)
    before = File.read!(path)

    assert {:error, %Error{code: :invalid_argument, message: message}} =
             PackFetch.start_link(
               backend: {LocalDirectory, published},
               into: {:bundle, path},
               limits: generous_limits()
             )

    assert message =~ "sha256"
    assert message =~ "sha1"
    assert File.read!(path) == before
  end

  test "a full-repository bundle with refs is refused unchanged", context do
    published = publish("sha1-basic-packed.git", "foreign-refs")
    path = Path.join(context.directory, "full-repository.bundle")

    assert {:ok, _receipt} =
             Bundle.write(path, source: {:repository, fixture("sha1-basic-packed.git")})

    assert {:ok, %{ref_count: ref_count}} = Bundle.info(path)
    assert ref_count > 0
    before = File.read!(path)

    assert {:error, %Error{code: :invalid_argument, message: message}} =
             PackFetch.start_link(
               backend: {LocalDirectory, published},
               into: {:bundle, path},
               limits: generous_limits()
             )

    assert message =~ Integer.to_string(ref_count)
    assert message =~ "Gitility.Bundle.write/2"
    assert File.read!(path) == before
  end

  test "cold outputs are deterministic and honor source identity", context do
    published = publish("sha1-basic-packed.git", "deterministic")
    first_path = Path.join(context.directory, "first.bundle")
    second_path = Path.join(context.directory, "second.bundle")
    override_path = Path.join(context.directory, "override.bundle")

    assert {:ok, first, _odb} = start_bundle(published, first_path)
    stop(first)
    assert {:ok, second, _odb} = start_bundle(published, second_path)
    stop(second)
    assert File.read!(first_path) == File.read!(second_path)

    assert {:ok, override, _odb} =
             start_bundle(published, override_path, bundle_source_identity: "m4c:override")

    stop(override)
    assert {:ok, %{source_identity: "m4c:override"}} = Bundle.info(override_path)
  end

  test "a metadata-only source identity change advances generation", context do
    published = publish("sha1-basic-packed.git", "metadata-rewrite")
    path = Path.join(context.directory, "metadata-rewrite.bundle")

    assert {:ok, first, _odb} =
             start_bundle(published, path, bundle_source_identity: "m4c:first")

    stop(first)
    first_bytes = File.read!(path)

    assert {:ok, second, _odb} =
             start_bundle(published, path, bundle_source_identity: "m4c:second")

    stop(second)
    refute File.read!(path) == first_bytes

    assert {:ok, %{generation: 2, source_identity: "m4c:second"}} = Bundle.info(path)
  end

  test "bundle scratch cleanup is stable by path across anonymous restarts", context do
    published = publish("sha1-basic-packed.git", "scratch-recovery")
    path = Path.join(context.directory, "scratch-recovery.bundle")

    stale =
      Path.join(System.tmp_dir!(), "gitility-packfetch-bundle-#{bundle_scratch_key(path)}-stale")

    File.mkdir!(stale)
    File.write!(Path.join(stale, "orphaned-pack-copy"), "stale")
    on_exit(fn -> File.rm_rf(stale) end)

    assert {:ok, supervisor, _odb} = start_bundle(published, path)
    refute File.exists?(stale)
    stop(supervisor)
  end

  test "hydration bundle composes through Bundle.open with OID-only selectors", context do
    published = publish("sha1-basic-packed.git", "round-trip")
    path = Path.join(context.directory, "round-trip.bundle")
    assert {:ok, supervisor, _odb} = start_bundle(published, path)
    stop(supervisor)

    assert {:ok, repository} =
             Bundle.open(path, into: {:dir, Path.join(context.directory, "opened")})

    head = Gitility.RangeTestSupport.fixture_oid(:sha1_basic_head)
    assert {:ok, snapshot} = Repository.snapshot(repository, {:oid, head})
    assert snapshot.commit_oid == head
    assert {:ok, %{items: []}} = RefDB.list(repository.refs)
    assert {:error, %Error{code: :ref_not_found}} = Repository.snapshot(repository, :head)
  end

  test "empty manifests produce legal empty bundles", context do
    path = Path.join(context.directory, "empty.bundle")

    assert {:ok, supervisor} =
             PackFetch.start_link(
               backend: {Gitility.M4c.EmptyRangeBackend, "empty-generation"},
               into: {:bundle, path},
               limits: generous_limits()
             )

    assert :ok = Bundle.verify(path)
    assert {:ok, %{generation: 1, file_count: 0, ref_count: 0}} = Bundle.info(path)
    stop(supervisor)
  end

  test "reserved shallow_roots destinations propagate unsupported errors unchanged", context do
    published = publish("sha1-basic-packed.git", "reserved-shallow-roots")
    write_path = Path.join(context.directory, "write-reserved.bundle")
    packfetch_path = Path.join(context.directory, "packfetch-reserved.bundle")

    for path <- [write_path, packfetch_path] do
      write_empty_bundle(path,
        metadata: %{"source_identity" => "m4c:test", "shallow_roots" => "deadbeef"}
      )
    end

    write_before = File.read!(write_path)

    assert {:error, %Error{code: :unsupported_operation, message: write_message}} =
             Bundle.write(write_path,
               source: {:repository, fixture("sha1-basic-packed.git")}
             )

    assert write_message =~ "shallow_roots"
    assert File.read!(write_path) == write_before
    packfetch_before = File.read!(packfetch_path)

    assert {:error, %Error{code: :unsupported_operation, message: packfetch_message}} =
             PackFetch.start_link(
               backend: {LocalDirectory, published},
               into: {:bundle, packfetch_path},
               limits: generous_limits()
             )

    assert packfetch_message =~ "shallow_roots"
    assert File.read!(packfetch_path) == packfetch_before
  end

  test "bundle source identity is rejected for a directory destination", context do
    published = publish("sha1-basic-packed.git", "source-identity-dir")

    assert {:error, %Error{code: :invalid_argument, message: message}} =
             PackFetch.start_link(
               backend: {LocalDirectory, published},
               into: {:dir, Path.join(context.directory, "dir-destination")},
               bundle_source_identity: "ignored-without-this-check",
               limits: generous_limits()
             )

    assert message =~ ":bundle_source_identity"
    assert message =~ "{:bundle, path}"
  end

  test "refresh serves growth without rewriting until restart", context do
    published = publish("sha1-basic-packed.git", "refresh")
    path = Path.join(context.directory, "refresh.bundle")
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    assert {:ok, supervisor, odb} =
             start_bundle(
               {Gitility.M4c.CountingRangeBackend, {LocalDirectory, published, counter}},
               path
             )

    assert {:ok, %{generation: 1, file_count: 2}} = Bundle.info(path)
    bundle_before = File.read!(path)
    new_oid = add_one_pair(published)
    reads_before = Agent.get(counter, & &1)
    assert :ok = ODB.refresh(odb)
    assert Agent.get(counter, & &1) > reads_before
    assert {:ok, _object} = ODB.read(odb, new_oid)
    assert :ok = Bundle.verify(path)
    assert File.read!(path) == bundle_before
    assert {:ok, %{generation: 1, file_count: 2}} = Bundle.info(path)
    stop(supervisor)

    assert {:ok, restarted, restarted_odb} =
             start_bundle(
               {Gitility.M4c.CountingRangeBackend, {LocalDirectory, published, counter}},
               path
             )

    assert {:ok, _object} = ODB.read(restarted_odb, new_oid)
    assert :ok = Bundle.verify(path)
    assert {:ok, %{generation: 2, file_count: 4}} = Bundle.info(path)
    stop(restarted)
    Agent.stop(counter)
  end

  defp start_bundle(published, path, opts \\ []) when is_binary(published) do
    start_bundle({LocalDirectory, published}, path, opts)
  end

  defp start_bundle({backend, init_arg}, path, opts) do
    options =
      [
        backend: {backend, init_arg},
        into: {:bundle, path},
        limits: generous_limits()
      ]
      |> Keyword.merge(opts)

    with {:ok, supervisor} <- PackFetch.start_link(options),
         {:ok, odb} <- ODB.handle(supervisor) do
      {:ok, supervisor, odb}
    end
  end

  defp publish(fixture_name, label) do
    published = Gitility.RangeTestSupport.publish(fixture_name, "m4c-#{label}")
    on_exit(fn -> File.rm_rf(published) end)
    published
  end

  defp add_one_pair(published) do
    extra = Gitility.RangeTestSupport.publish("sha1-history-midx.git", "m4c-growth")

    try do
      {:ok, published_state} = LocalDirectory.init(published)
      {:ok, original} = LocalDirectory.manifest(published_state)
      {:ok, extra_state} = LocalDirectory.init(extra)
      {:ok, extra_manifest} = LocalDirectory.manifest(extra_state)
      original_ids = MapSet.new(original.packs, & &1.id)
      descriptor = Enum.find(extra_manifest.packs, &(not MapSet.member?(original_ids, &1.id)))
      oid = first_pair_oid(Path.join(extra, descriptor.index_key))
      File.cp!(Path.join(extra, descriptor.pack_key), Path.join(published, descriptor.pack_key))
      File.cp!(Path.join(extra, descriptor.index_key), Path.join(published, descriptor.index_key))

      write_manifest(published, %{
        original
        | generation: "m4c-grown",
          packs: original.packs ++ [descriptor]
      })

      oid
    after
      File.rm_rf(extra)
    end
  end

  defp write_manifest(directory, manifest) do
    packs =
      Enum.map(manifest.packs, fn descriptor ->
        descriptor
        |> Map.from_struct()
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
      end)

    bytes =
      Jason.encode_to_iodata!(%{
        "version" => manifest.version,
        "generation" => manifest.generation,
        "hash" => Atom.to_string(manifest.hash),
        "packs" => packs,
        "loose" => []
      })

    File.write!(Path.join(directory, "manifest.json"), bytes)
  end

  defp write_empty_bundle(path, opts) do
    hash = Keyword.get(opts, :hash, :sha1)
    metadata = Keyword.get(opts, :metadata, %{"source_identity" => "m4c:test"})

    toc =
      Format.encode_toc(%{
        hash_algorithm: hash,
        generation: 1,
        metadata: metadata,
        files: [],
        refs: []
      })

    File.write!(
      path,
      Format.encode_header() <>
        toc <>
        Format.encode_trailer(16, byte_size(toc), :crypto.hash(:sha256, toc))
    )
  end

  defp first_pair_oid(index_path) do
    {output, 0} = System.cmd("git", ["verify-pack", "-v", index_path])

    hex =
      output
      |> String.split("\n", trim: true)
      |> Enum.find_value(fn line ->
        case String.split(line) do
          [oid, type | _rest] when type in ["commit", "tree", "blob", "tag"] -> oid
          _other -> nil
        end
      end)

    Gitility.OID.parse!(hex)
  end

  defp bundle_scratch_key(path) do
    :sha256
    |> :crypto.hash(Path.expand(path))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp corrupt_byte(path, offset) do
    bytes = File.read!(path)
    old = :binary.at(bytes, offset)
    prefix = binary_part(bytes, 0, offset)
    suffix = binary_part(bytes, offset + 1, byte_size(bytes) - offset - 1)
    File.write!(path, prefix <> <<Bitwise.bxor(old, 1)>> <> suffix)
  end

  defp bundle_scratch_directories do
    System.tmp_dir!()
    |> Path.join("gitility-packfetch-bundle-*")
    |> Path.wildcard()
    |> MapSet.new()
  end

  defp fixture(name), do: Path.join(@fixtures, name)

  defp stop(supervisor), do: Gitility.RangeTestSupport.stop(supervisor)

  defp generous_limits do
    Limits.new(
      timeout_ms: 30_000,
      max_provider_requests: 100_000,
      max_provider_bytes: 512 * 1024 * 1024,
      max_result_bytes: 32 * 1024 * 1024
    )
  end
end
