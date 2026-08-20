defmodule Gitility.RangeTestSupport do
  import ExUnit.Assertions

  alias Gitility.{Limits, ODB, OID, Repository, Snapshot}
  alias Gitility.ODB.RangeBackend.LocalDirectory

  @fixtures Path.expand("../fixtures/generated", __DIR__)

  def fixture(name), do: Path.join(@fixtures, name)

  def fixture_oid(name) do
    @fixtures
    |> Path.join("OIDS")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> if key == Atom.to_string(name), do: OID.parse!(value)
        _other -> nil
      end
    end)
  end

  def temp_dir(label) do
    Path.join(
      System.tmp_dir!(),
      "gitility-m2e-#{label}-#{System.unique_integer([:positive, :monotonic])}"
    )
  end

  def publish(fixture_name, label) do
    directory = temp_dir("published-#{label}")
    :ok = LocalDirectory.publish(fixture(fixture_name), directory)
    directory
  end

  def artifacts(directory) do
    {:ok, state} = LocalDirectory.init(directory)
    {:ok, manifest} = LocalDirectory.manifest(state)

    manifest.packs
    |> Enum.flat_map(fn descriptor ->
      [
        {descriptor.pack_key, File.read!(Path.join(directory, descriptor.pack_key))},
        {descriptor.index_key, File.read!(Path.join(directory, descriptor.index_key))}
      ]
    end)
    |> Map.new()
  end

  def start_packfetch(published, destination, opts \\ []) do
    limits =
      Keyword.get(
        opts,
        :limits,
        Limits.new(
          timeout_ms: 30_000,
          max_provider_requests: 100_000,
          max_provider_bytes: 512 * 1024 * 1024,
          max_result_bytes: 32 * 1024 * 1024
        )
      )

    options =
      [
        backend: {LocalDirectory, published},
        into: destination,
        limits: limits
      ]
      |> Keyword.merge(Keyword.delete(opts, :limits))

    with {:ok, supervisor} <- Gitility.ODB.PackFetch.start_link(options),
         {:ok, odb} <- ODB.handle(supervisor) do
      {:ok, supervisor, odb}
    end
  end

  def parity!(local, remote, head, paths) do
    {:ok, local_snapshot} = Snapshot.open(local.odb, head)
    {:ok, remote_snapshot} = Snapshot.open(remote, head)
    assert local_snapshot.commit_oid == remote_snapshot.commit_oid
    assert local_snapshot.tree_oid == remote_snapshot.tree_oid

    {:ok, local_tree} = Gitility.list_tree(local_snapshot, "", recursive: true)
    {:ok, remote_tree} = Gitility.list_tree(remote_snapshot, "", recursive: true)
    assert remote_tree.items == local_tree.items

    Enum.each(paths, fn path ->
      {:ok, remote_file} = Gitility.read_file(remote_snapshot, path)
      {:ok, local_file} = Gitility.read_file(local_snapshot, path)

      assert Map.drop(Map.from_struct(remote_file), [:stats]) ==
               Map.drop(Map.from_struct(local_file), [:stats])
    end)

    sample_oids =
      [head, local_snapshot.tree_oid | Enum.map(local_tree.items, & &1.oid)]
      |> Enum.uniq()
      |> Enum.take(12)

    Enum.each(sample_oids, fn oid ->
      assert ODB.header(remote, oid) == ODB.header(local.odb, oid)
      assert ODB.read(remote, oid) == ODB.read(local.odb, oid)
    end)

    assert ODB.read_many(remote, sample_oids) == ODB.read_many(local.odb, sample_oids)
    assert Gitility.peel(remote, head) == Gitility.peel(local.odb, head)
  end

  def stop(supervisor) when is_pid(supervisor) do
    Process.unlink(supervisor)
    ref = Process.monitor(supervisor)

    # The supervisor may already be shutting down on its own (it is linked
    # to whichever process ran start_link, often a finished Task), so stop
    # can race a concurrent normal exit. Any exit here is fine as long as
    # the process is confirmed down before returning.
    try do
      Supervisor.stop(supervisor)
    catch
      :exit, _ -> :ok
    end

    receive do
      {:DOWN, ^ref, :process, ^supervisor, _reason} -> :ok
    after
      5_000 -> raise "supervisor #{inspect(supervisor)} did not stop"
    end
  end
end

defmodule Gitility.TrackingRangeBackend do
  @behaviour Gitility.ODB.RangeBackend

  @impl true
  def init({delegate, arg, tracker, mode}) do
    with {:ok, state} <- delegate.init(arg),
         {:ok, manifest} <- delegate.manifest(state) do
      {:ok,
       %{
         delegate: delegate,
         state: state,
         tracker: tracker,
         mode: mode,
         second_pack_key: manifest.packs |> Enum.at(1) |> then(&if(&1, do: &1.pack_key))
       }}
    end
  end

  @impl true
  def manifest(config) do
    {:ok, manifest} = config.delegate.manifest(config.state)

    case config.mode do
      :bad_version ->
        {:ok, %{manifest | version: 2}}

      :duplicate_id ->
        {:ok, %{manifest | packs: [hd(manifest.packs) | manifest.packs]}}

      :wrong_length_id ->
        {:ok, %{manifest | packs: [%{hd(manifest.packs) | id: "00"}]}}

      :pair_mismatch ->
        [first, second | rest] = manifest.packs

        {:ok,
         %{
           manifest
           | packs: [
               %{first | index_key: second.index_key, index_size: second.index_size},
               second | rest
             ]
         }}

      :oversized_manifest ->
        pack = hd(manifest.packs)
        {:ok, %{manifest | packs: [%{pack | pack_size: 50 * 1024 * 1024 * 1024}]}}

      :synthetic_300m_manifest ->
        pack = hd(manifest.packs)
        {:ok, %{manifest | packs: [%{pack | pack_size: 300 * 1024 * 1024}]}}

      :non_empty_loose ->
        {:ok, %{manifest | loose: ["objects/00/not-supported"]}}

      :too_many_manifest_entries ->
        {:ok, %{manifest | loose: List.duplicate("x", 100_001)}}

      _other ->
        {:ok, manifest}
    end
  end

  @impl true
  def read_ranges(ranges, config) do
    tracking = enter(config.tracker)

    try do
      maybe_block(config.mode, tracking, ranges)
      result = config.delegate.read_ranges(ranges, config.state)
      mutate(result, ranges, config)
    after
      leave(config.tracker)
    end
  end

  @impl true
  def terminate(reason, config) do
    if function_exported?(config.delegate, :terminate, 2) do
      config.delegate.terminate(reason, config.state)
    else
      :ok
    end
  end

  defp enter(agent) do
    Agent.get_and_update(agent, fn state ->
      current = state.current + 1

      next = %{
        state
        | current: current,
          max: max(state.max, current),
          read_calls: state.read_calls + 1
      }

      {next, %{next | block_once: false}}
    end)
  end

  defp leave(agent), do: Agent.update(agent, &%{&1 | current: max(&1.current - 1, 0)})

  defp maybe_block({:latch, observer, window}, tracking, ranges) do
    pack_range? = Enum.any?(ranges, &String.ends_with?(&1.key, ".pack"))

    if pack_range? and tracking.read_calls <= window + 1 do
      send(observer, {:range_backend_waiting, self()})

      receive do
        :release -> :ok
      end
    end
  end

  defp maybe_block({:notify_and_hang, observer}, _tracking, _ranges) do
    send(observer, {:range_backend_entered, self()})

    receive do
      :never -> :ok
    end
  end

  defp maybe_block({:controlled_latch, observer}, %{block_once: true}, _ranges) do
    send(observer, {:range_backend_waiting, self()})

    receive do
      :release -> :ok
    end
  end

  defp maybe_block(_mode, _tracking, _ranges), do: :ok

  defp mutate({:ok, replies}, ranges, %{mode: :short}) do
    target = Enum.find(ranges, &(&1.length > 0))
    {:ok, Map.update!(replies, target, &binary_part(&1, 0, byte_size(&1) - 1))}
  end

  defp mutate({:ok, replies}, ranges, %{mode: :overlong}) do
    target = Enum.find(ranges, &(&1.length > 0))
    {:ok, Map.update!(replies, target, &(&1 <> <<0>>))}
  end

  defp mutate({:ok, replies}, ranges, %{mode: :corrupt_pack}) do
    corrupt_matching(replies, ranges, ".pack")
  end

  defp mutate({:ok, replies}, ranges, %{mode: :corrupt_index}) do
    corrupt_matching(replies, ranges, ".idx")
  end

  defp mutate({:ok, replies}, ranges, %{mode: :corrupt_second_pack} = config) do
    corrupt_key(replies, ranges, config.second_pack_key)
  end

  defp mutate({:ok, replies}, ranges, %{mode: :forged_index}) do
    case Enum.find(ranges, &String.ends_with?(&1.key, ".idx")) do
      nil -> {:ok, replies}
      range -> {:ok, Map.update!(replies, range, &forge_index_offsets/1)}
    end
  end

  defp mutate(result, _ranges, _config), do: result

  defp corrupt_matching(replies, ranges, suffix) do
    case Enum.find(ranges, &(&1.length > 0 and String.ends_with?(&1.key, suffix))) do
      nil -> {:ok, replies}
      range -> {:ok, Map.update!(replies, range, &flip_first/1)}
    end
  end

  defp flip_first(<<first, rest::binary>>), do: <<Bitwise.bxor(first, 1), rest::binary>>

  defp corrupt_key(replies, ranges, key) do
    case Enum.find(ranges, &(&1.length > 0 and &1.key == key)) do
      nil -> {:ok, replies}
      range -> {:ok, Map.update!(replies, range, &flip_first/1)}
    end
  end

  defp forge_index_offsets(bytes) do
    <<count::unsigned-big-32>> = binary_part(bytes, 8 + 255 * 4, 4)
    offset_table = 8 + 256 * 4 + count * 20 + count * 4
    prefix_size = byte_size(bytes) - 20

    forged = replace_binary_part(bytes, offset_table, <<0x7FFF_FFFF::unsigned-big-32>>)
    prefix = binary_part(forged, 0, prefix_size)
    prefix <> :crypto.hash(:sha, prefix)
  end

  defp replace_binary_part(bytes, offset, replacement) do
    replacement_size = byte_size(replacement)
    <<head::binary-size(offset), _old::binary-size(replacement_size), tail::binary>> = bytes
    head <> replacement <> tail
  end
end

defmodule Gitility.InitRangeBackend do
  @behaviour Gitility.ODB.RangeBackend

  @impl true
  def init({:error, reason}), do: {:error, reason}
  def init(:raise), do: raise("range init exploded")
  def init(:throw), do: throw(:range_init_thrown)
  def init(:exit), do: exit(:range_init_exited)
  def init(:invalid), do: :invalid_init_return

  @impl true
  def manifest(_state), do: {:error, :unused}

  @impl true
  def read_ranges(_ranges, _state), do: {:error, :unused}
end

defmodule Gitility.BrokenRangeBackend do
  @behaviour Gitility.ODB.RangeBackend

  @id String.duplicate("0", 40)

  @impl true
  def init(_arg), do: {:ok, :state}

  @impl true
  def manifest(:state) do
    {:ok,
     %Gitility.PackManifest{
       version: 1,
       generation: "broken",
       hash: :sha1,
       packs: [
         %Gitility.PackDescriptor{
           id: @id,
           pack_key: "packs/pack-#{@id}.pack",
           index_key: "packs/pack-#{@id}.idx",
           pack_size: 3,
           index_size: 3
         }
       ]
     }}
  end

  @impl true
  def read_ranges(ranges, :state) do
    {:ok, Map.new(ranges, fn range -> {range, :binary.copy(<<0>>, max(range.length - 1, 0))} end)}
  end
end

defmodule Gitility.LocalDirectoryRangeConformanceTest do
  use Gitility.ODB.RangeBackend.Conformance,
    backend: Gitility.ODB.RangeBackend.LocalDirectory,
    concurrency: 4

  setup_all do
    directory = Gitility.RangeTestSupport.publish("sha1-basic.git", "conformance")
    :persistent_term.put({__MODULE__, :directory}, directory)

    on_exit(fn ->
      :persistent_term.erase({__MODULE__, :directory})
      File.rm_rf(directory)
    end)

    :ok
  end

  def backend_init_arg, do: :persistent_term.get({__MODULE__, :directory})
  def backend_artifacts, do: Gitility.RangeTestSupport.artifacts(backend_init_arg())

  def backend_publish_artifact(directory, key, bytes) do
    path = Path.join(directory, key)
    :ok = File.mkdir_p(Path.dirname(path))
    File.write(path, bytes)
  end
end

defmodule Gitility.BrokenRangeConformanceTest do
  use Gitility.ODB.RangeBackend.Conformance,
    backend: Gitility.BrokenRangeBackend,
    expected_failure: :short_read

  def backend_init_arg, do: :broken

  def backend_artifacts do
    id = String.duplicate("0", 40)
    %{"packs/pack-#{id}.pack" => "abc", "packs/pack-#{id}.idx" => "abc"}
  end
end

defmodule Gitility.Milestone2ePackFetchTest do
  use ExUnit.Case, async: false

  alias Gitility.{Error, Limits, ODB, Repository, Snapshot}
  alias Gitility.ODB.PackFetch
  alias Gitility.ODB.RangeBackend.LocalDirectory

  import Gitility.RangeTestSupport

  @basic_paths [
    "README.md",
    "binary.dat",
    "empty.bin",
    "src/story.txt",
    "subdir/nested.txt",
    <<"invalid-", 0xFF, "-name.txt">>
  ]

  test "LocalDirectory publishes loose and multi-pack fixtures and PackFetch has full parity" do
    for {fixture_name, head_name} <- [
          {"sha1-basic.git", :sha1_basic_head},
          {"sha1-history-midx.git", :sha1_history_head}
        ] do
      published = publish(fixture_name, fixture_name)
      destination = temp_dir("hydrated-#{fixture_name}")

      on_exit(fn ->
        File.rm_rf(published)
        File.rm_rf(destination)
      end)

      {:ok, local} = Repository.open(fixture(fixture_name))
      {:ok, supervisor, remote} = start_packfetch(published, {:dir, destination})
      paths = if fixture_name == "sha1-basic.git", do: @basic_paths, else: []
      parity!(local, remote, fixture_oid(head_name), paths)

      if fixture_name == "sha1-basic.git" do
        tag =
          fixture(fixture_name)
          |> Path.join("refs/tags/v1.0.0")
          |> File.read!()
          |> String.trim()
          |> Gitility.OID.parse!()

        assert {:ok, peeled} = Gitility.peel(remote, tag)
        assert peeled == fixture_oid(:sha1_basic_head)
      end

      {:ok, stats} = ODB.stats(remote)
      assert stats.packs_hydrated > 0
      assert stats.bytes_fetched > 0
      assert stats.bytes_verified >= stats.bytes_fetched
      assert stats.elapsed_ms < 2_000
      IO.puts("[m2e-smoke] #{fixture_name} hydrate_ms=#{stats.elapsed_ms}")
      stop(supervisor)
    end
  end

  test "publish preserves packed plus loose inventory and unreachable loose objects" do
    published = publish("sha1-basic-mixed.git", "mixed")
    destination = temp_dir("mixed-hydrated")

    on_exit(fn ->
      File.rm_rf(published)
      File.rm_rf(destination)
    end)

    {:ok, state} = LocalDirectory.init(published)
    {:ok, manifest} = LocalDirectory.manifest(state)
    assert length(manifest.packs) == 2

    [loose_path] =
      fixture("sha1-basic-mixed.git")
      |> Path.join("objects/??/*")
      |> Path.wildcard()

    loose_oid =
      Path.basename(Path.dirname(loose_path)) <> Path.basename(loose_path)

    {:ok, supervisor, odb} = start_packfetch(published, {:dir, destination})
    assert {:ok, %Gitility.Object{oid: %Gitility.OID{} = oid}} = ODB.read(odb, loose_oid)
    assert Gitility.OID.to_string(oid) == loose_oid
    stop(supervisor)

    repository_copy = temp_dir("unreachable-source.git")
    payload = temp_dir("unreachable-payload")
    published_copy = temp_dir("unreachable-published")
    hydrated_copy = temp_dir("unreachable-hydrated")
    File.cp_r!(fixture("sha1-basic.git"), repository_copy)
    File.write!(payload, "unreachable but deliberately published\n")

    on_exit(fn ->
      File.rm_rf(repository_copy)
      File.rm(payload)
      File.rm_rf(published_copy)
      File.rm_rf(hydrated_copy)
    end)

    {oid_text, 0} =
      System.cmd("git", ["--git-dir", repository_copy, "hash-object", "-w", payload])

    unreachable_oid = String.trim(oid_text)
    :ok = LocalDirectory.publish(repository_copy, published_copy)

    {:ok, copy_supervisor, copy_odb} =
      start_packfetch(published_copy, {:dir, hydrated_copy})

    assert {:ok, %Gitility.Object{data: "unreachable but deliberately published\n"}} =
             ODB.read(copy_odb, unreachable_oid)

    stop(copy_supervisor)
  end

  test "LocalDirectory publishes alternate objects transitively and refuses broken alternates" do
    published = publish("sha1-alternate.git", "alternate")
    hydrated = temp_dir("alternate-hydrated")

    on_exit(fn ->
      File.rm_rf(published)
      File.rm_rf(hydrated)
    end)

    {:ok, state} = LocalDirectory.init(published)
    {:ok, manifest} = LocalDirectory.manifest(state)
    assert manifest.packs != []

    head = fixture_oid(:sha1_basic_head)
    alternate = fixture("sha1-alternate.git")
    oid = Gitility.OID.to_string(head)

    primary_object =
      Path.join([alternate, "objects", binary_part(oid, 0, 2), binary_part(oid, 2, 38)])

    refute File.exists?(primary_object)

    {:ok, direct} = Repository.open(alternate)
    {:ok, supervisor, remote} = start_packfetch(published, {:dir, hydrated})
    assert {:ok, %Gitility.Object{oid: ^head}} = ODB.read(remote, head)
    parity!(direct, remote, head, @basic_paths)
    stop(supervisor)

    broken_source = temp_dir("broken-alternate.git")
    broken_destination = temp_dir("broken-alternate-published")
    missing_alternate = Path.join(broken_source, "missing-objects")
    File.cp_r!(alternate, broken_source)

    File.write!(
      Path.join([broken_source, "objects", "info", "alternates"]),
      missing_alternate <> "\n"
    )

    on_exit(fn ->
      File.rm_rf(broken_source)
      File.rm_rf(broken_destination)
    end)

    assert {:error, {:alternate_objects_directory_missing, ^missing_alternate}} =
             LocalDirectory.publish(broken_source, broken_destination)
  end

  test "loose-object publishing reports a read-only source clearly" do
    repository_copy = temp_dir("readonly-source.git")
    destination = temp_dir("readonly-published")
    payload = temp_dir("readonly-loose-payload")
    File.cp_r!(fixture("sha1-basic.git"), repository_copy)
    File.write!(payload, "force one loose object\n")

    {_oid, 0} =
      System.cmd("git", ["--git-dir", repository_copy, "hash-object", "-w", payload])

    objects = Path.join(repository_copy, "objects")
    original_mode = File.stat!(objects).mode
    :ok = File.chmod(objects, 0o555)

    on_exit(fn ->
      File.chmod(objects, original_mode)
      File.rm_rf(repository_copy)
      File.rm_rf(destination)
      File.rm(payload)
    end)

    assert {:error, :source_repository_read_only} =
             LocalDirectory.publish(repository_copy, destination)
  end

  test "Linux memory destination works and other platforms refuse it explicitly" do
    if PackFetch.memory_supported?() do
      for {fixture_name, head, paths} <- [
            {"sha1-basic.git", :sha1_basic_head, @basic_paths},
            {"sha1-history-midx.git", :sha1_history_head, []}
          ] do
        published = publish(fixture_name, "memory-#{fixture_name}")
        on_exit(fn -> File.rm_rf(published) end)
        {:ok, local} = Repository.open(fixture(fixture_name))

        {:ok, supervisor, remote} =
          start_packfetch(published, :memory, max_bytes: 64 * 1024 * 1024)

        parity!(local, remote, fixture_oid(head), paths)
        stop(supervisor)
      end
    else
      published = publish("sha1-basic.git", "memory-unsupported")
      on_exit(fn -> File.rm_rf(published) end)

      assert {:error, %Error{code: :unsupported_operation, message: message}} =
               PackFetch.start_link(
                 backend: {LocalDirectory, published},
                 into: :memory
               )

      assert message =~ "{:dir, path}"
    end
  end

  test "memory destinations are removed after orderly stop and supervisor kill" do
    if PackFetch.memory_supported?() do
      published = publish("sha1-basic.git", "memory-cleanup")
      on_exit(fn -> File.rm_rf(published) end)

      for mode <- [:stop, :kill] do
        before = MapSet.new(Path.wildcard("/dev/shm/gitility-packfetch-*"))
        name = {:global, {__MODULE__, :memory_cleanup, mode, make_ref()}}

        {:ok, supervisor} =
          PackFetch.start_link(
            name: name,
            backend: {LocalDirectory, published},
            into: :memory,
            max_bytes: 64 * 1024 * 1024
          )

        [destination] =
          "/dev/shm/gitility-packfetch-*"
          |> Path.wildcard()
          |> MapSet.new()
          |> MapSet.difference(before)
          |> MapSet.to_list()

        case mode do
          :stop ->
            stop(supervisor)

          :kill ->
            Process.unlink(supervisor)
            monitor = Process.monitor(supervisor)
            Process.exit(supervisor, :kill)
            assert_receive {:DOWN, ^monitor, :process, ^supervisor, :killed}, 5_000
        end

        assert eventually(fn -> not File.exists?(destination) end, 5_000)
      end
    end
  end

  test "PackFetch is a supervisor child and stops promptly under a tree" do
    published = publish("sha1-basic.git", "supervised")
    destination = temp_dir("supervised")
    id = {PackFetch, System.unique_integer([:positive])}

    on_exit(fn ->
      File.rm_rf(published)
      File.rm_rf(destination)
    end)

    supervisor =
      start_supervised!(
        Supervisor.child_spec(
          {PackFetch, backend: {LocalDirectory, published}, into: {:dir, destination}},
          id: id
        )
      )

    {:ok, test_supervisor} = ExUnit.fetch_test_supervisor()

    assert {^id, ^supervisor, :supervisor, _modules} =
             Enum.find(Supervisor.which_children(test_supervisor), fn {child_id, _, _, _} ->
               child_id == id
             end)

    started = System.monotonic_time(:millisecond)
    assert :ok = stop_supervised!(id)
    assert System.monotonic_time(:millisecond) - started < 1_000
  end

  test "backend init errors, raises, throws, exits, and invalid returns stay distinguishable" do
    options = fn mode ->
      [
        backend: {Gitility.InitRangeBackend, mode},
        into: {:dir, temp_dir("init-#{inspect(mode)}")}
      ]
    end

    assert {:error, :init_refused} = PackFetch.start_link(options.({:error, :init_refused}))

    assert {:error, {:backend_init_raised, "range init exploded"}} =
             PackFetch.start_link(options.(:raise))

    assert {:error, {:backend_init_raised, throw_message}} =
             PackFetch.start_link(options.(:throw))

    assert throw_message =~ "throw"
    assert throw_message =~ "range_init_thrown"

    assert {:error, {:backend_init_raised, exit_message}} =
             PackFetch.start_link(options.(:exit))

    assert exit_message =~ "exit"
    assert exit_message =~ "range_init_exited"

    assert {:error, {:invalid_return, :invalid_init_return}} =
             PackFetch.start_link(options.(:invalid))
  end

  test "a reused destination verifies and skips every existing pack" do
    published = publish("sha1-history-midx.git", "reuse")
    destination = temp_dir("reuse")

    on_exit(fn ->
      File.rm_rf(published)
      File.rm_rf(destination)
    end)

    {:ok, first, first_odb} = start_packfetch(published, {:dir, destination})
    {:ok, first_stats} = ODB.stats(first_odb)
    stop(first)

    {:ok, backend_state} = LocalDirectory.init(published)
    {:ok, manifest} = LocalDirectory.manifest(backend_state)

    manifest_total =
      manifest.packs
      |> Enum.map(fn pack -> pack.pack_size + pack.index_size end)
      |> Enum.sum()

    warm_ceiling = manifest_total - 1

    {:ok, second, second_odb} =
      start_packfetch(published, {:dir, destination}, max_hydration_bytes: warm_ceiling)

    {:ok, second_stats} = ODB.stats(second_odb)
    assert second_stats.packs_hydrated == 0
    assert second_stats.packs_skipped == first_stats.packs_hydrated
    assert second_stats.bytes_fetched == 0
    stop(second)
  end

  test "a corrupt destination pack is replaced and remains query-equivalent" do
    published = publish("sha1-basic.git", "replace")
    destination = temp_dir("replace")

    on_exit(fn ->
      File.rm_rf(published)
      File.rm_rf(destination)
    end)

    {:ok, first, _odb} = start_packfetch(published, {:dir, destination})
    stop(first)
    [pack_path] = Path.wildcard(Path.join(destination, "objects/pack/*.pack"))
    bytes = File.read!(pack_path)
    <<first_byte, rest::binary>> = bytes
    File.write!(pack_path, <<Bitwise.bxor(first_byte, 1), rest::binary>>)

    {:ok, second, odb} = start_packfetch(published, {:dir, destination})
    {:ok, stats} = ODB.stats(odb)
    assert stats.replaced_corrupt == 1
    {:ok, local} = Repository.open(fixture("sha1-basic.git"))
    parity!(local, odb, fixture_oid(:sha1_basic_head), @basic_paths)
    stop(second)
  end

  test "a corrupt pre-existing destination index is replaced" do
    published = publish("sha1-basic.git", "replace-index")
    destination = temp_dir("replace-index")

    on_exit(fn ->
      File.rm_rf(published)
      File.rm_rf(destination)
    end)

    {:ok, first, _odb} = start_packfetch(published, {:dir, destination})
    stop(first)
    [index_path] = Path.wildcard(Path.join(destination, "objects/pack/*.idx"))
    bytes = File.read!(index_path)
    <<first_byte, rest::binary>> = bytes
    File.write!(index_path, <<Bitwise.bxor(first_byte, 1), rest::binary>>)

    {:ok, second, odb} = start_packfetch(published, {:dir, destination})
    {:ok, stats} = ODB.stats(odb)
    assert stats.replaced_corrupt == 1
    assert {:ok, %Snapshot{}} = Snapshot.open(odb, fixture_oid(:sha1_basic_head))
    stop(second)
  end

  test "a checksum-consistent forged index fails the open-time gix probe and is removed" do
    published = publish("sha1-basic.git", "forged-index")
    destination = temp_dir("forged-index")
    {:ok, tracker} = tracker()

    on_exit(fn ->
      File.rm_rf(published)
      File.rm_rf(destination)
      if Process.alive?(tracker), do: Agent.stop(tracker)
    end)

    assert {:error, %Error{code: :malformed_object, message: message}} =
             PackFetch.start_link(
               backend:
                 {Gitility.TrackingRangeBackend,
                  {LocalDirectory, published, tracker, :forged_index}},
               into: {:dir, destination}
             )

    assert message =~ "failed the open-time probe"
    assert Path.wildcard(Path.join(destination, "objects/pack/*.pack")) == []
    assert Path.wildcard(Path.join(destination, "objects/pack/*.idx")) == []
  end

  test "failed start_link leaves no registered tree, app child, or native thread budget change" do
    published = publish("sha1-basic.git", "failed-start-cleanup")
    destination = temp_dir("failed-start-cleanup")
    {:ok, tracker} = tracker()
    name = {:global, {__MODULE__, :failed_start_cleanup, make_ref()}}
    app_children = Supervisor.which_children(Gitility.Supervisor)
    thread_budget = Gitility.Runtime.stats().thread_budget_used

    on_exit(fn ->
      File.rm_rf(published)
      File.rm_rf(destination)
      if Process.alive?(tracker), do: Agent.stop(tracker)
    end)

    assert {:error, %Error{code: :malformed_object}} =
             PackFetch.start_link(
               name: name,
               backend:
                 {Gitility.TrackingRangeBackend,
                  {LocalDirectory, published, tracker, :forged_index}},
               into: {:dir, destination}
             )

    assert GenServer.whereis(name) == nil
    assert Supervisor.which_children(Gitility.Supervisor) == app_children

    assert eventually(
             fn -> Gitility.Runtime.stats().thread_budget_used == thread_budget end,
             5_000
           )
  end

  test "corrupt backend pack and index bytes fail without final-named files" do
    published = publish("sha1-basic.git", "backend-corrupt")
    on_exit(fn -> File.rm_rf(published) end)

    for {mode, expected} <- [
          {:corrupt_pack, :pack_checksum_mismatch},
          {:corrupt_index, :index_checksum_mismatch}
        ] do
      destination = temp_dir("#{mode}")
      {:ok, tracker} = tracker()

      assert {:error, %Error{code: ^expected}} =
               PackFetch.start_link(
                 backend:
                   {Gitility.TrackingRangeBackend, {LocalDirectory, published, tracker, mode}},
                 into: {:dir, destination},
                 limits: generous_limits()
               )

      assert Path.wildcard(Path.join(destination, "objects/pack/*.pack")) == []
      assert Path.wildcard(Path.join(destination, "objects/pack/*.idx")) == []
      assert Path.wildcard(Path.join(destination, "objects/pack/.*.tmp-*")) == []
      Agent.stop(tracker)
      File.rm_rf(destination)
    end
  end

  test "multi-pack failure retains only earlier verified pairs for retry" do
    published = publish("sha1-history-midx.git", "partial-multi-pack")
    destination = temp_dir("partial-multi-pack")
    {:ok, tracker} = tracker()

    on_exit(fn ->
      File.rm_rf(published)
      File.rm_rf(destination)
      if Process.alive?(tracker), do: Agent.stop(tracker)
    end)

    assert {:error, %Error{code: :pack_checksum_mismatch}} =
             PackFetch.start_link(
               backend:
                 {Gitility.TrackingRangeBackend,
                  {LocalDirectory, published, tracker, :corrupt_second_pack}},
               into: {:dir, destination},
               limits: generous_limits()
             )

    assert length(Path.wildcard(Path.join(destination, "objects/pack/*.pack"))) == 1
    assert length(Path.wildcard(Path.join(destination, "objects/pack/*.idx"))) == 1
    assert Path.wildcard(Path.join(destination, "objects/pack/.*.tmp-*")) == []

    {:ok, retry, odb} = start_packfetch(published, {:dir, destination})
    {:ok, stats} = ODB.stats(odb)
    assert stats.packs_skipped == 1
    assert stats.packs_hydrated == 1
    assert {:ok, %Snapshot{}} = Snapshot.open(odb, fixture_oid(:sha1_history_head))
    stop(retry)
  end

  test "an index paired with another pack fails at the pack checksum boundary" do
    published = publish("sha1-history-midx.git", "pair-mismatch")
    destination = temp_dir("pair-mismatch")
    {:ok, tracker} = tracker()

    on_exit(fn ->
      File.rm_rf(published)
      File.rm_rf(destination)
    end)

    assert {:error, %Error{code: :pack_checksum_mismatch}} =
             PackFetch.start_link(
               backend:
                 {Gitility.TrackingRangeBackend,
                  {LocalDirectory, published, tracker, :pair_mismatch}},
               into: {:dir, destination},
               limits: generous_limits()
             )

    assert Path.wildcard(Path.join(destination, "objects/pack/*.pack")) == []
    assert Path.wildcard(Path.join(destination, "objects/pack/*.idx")) == []
    Agent.stop(tracker)
  end

  test "short and over-long replies are provider protocol errors" do
    published = publish("sha1-basic.git", "bad-length")
    on_exit(fn -> File.rm_rf(published) end)

    for mode <- [:short, :overlong] do
      {:ok, tracker} = tracker()

      assert {:error, %Error{code: :provider_protocol_error}} =
               PackFetch.start_link(
                 backend:
                   {Gitility.TrackingRangeBackend, {LocalDirectory, published, tracker, mode}},
                 into: {:dir, temp_dir("#{mode}")},
                 limits: generous_limits()
               )

      Agent.stop(tracker)
    end
  end

  test "invalid manifests fail before trust and oversized plans make no range calls" do
    published = publish("sha1-basic.git", "manifest-errors")
    on_exit(fn -> File.rm_rf(published) end)

    for mode <- [:bad_version, :duplicate_id, :wrong_length_id, :non_empty_loose] do
      {:ok, tracker} = tracker()

      assert {:error, %Error{code: :provider_protocol_error}} =
               PackFetch.start_link(
                 backend:
                   {Gitility.TrackingRangeBackend, {LocalDirectory, published, tracker, mode}},
                 into: {:dir, temp_dir("manifest-#{mode}")},
                 limits: generous_limits()
               )

      assert Agent.get(tracker, & &1.read_calls) == 0
      Agent.stop(tracker)
    end

    {:ok, tracker} = tracker()

    assert {:error, %Error{code: :budget_exceeded, details: %{limit: :max_hydration_bytes}}} =
             PackFetch.start_link(
               backend:
                 {Gitility.TrackingRangeBackend,
                  {LocalDirectory, published, tracker, :oversized_manifest}},
               into: {:dir, temp_dir("oversized")},
               max_hydration_bytes: 1024
             )

    assert Agent.get(tracker, & &1.read_calls) == 0
    Agent.stop(tracker)

    {:ok, entry_tracker} = tracker()

    assert {:error, %Error{code: :provider_protocol_error, message: entry_message}} =
             PackFetch.start_link(
               backend:
                 {Gitility.TrackingRangeBackend,
                  {LocalDirectory, published, entry_tracker, :too_many_manifest_entries}},
               into: {:dir, temp_dir("too-many-manifest-entries")}
             )

    assert entry_message =~ "100000-entry"
    assert Agent.get(entry_tracker, & &1.read_calls) == 0
    Agent.stop(entry_tracker)
  end

  test "the default hydration ceiling admits a synthetic 300 MiB plan" do
    published = publish("sha1-basic.git", "default-hydration-ceiling")
    {:ok, tracker} = tracker()

    on_exit(fn ->
      File.rm_rf(published)
      if Process.alive?(tracker), do: Agent.stop(tracker)
    end)

    # The synthetic descriptor deliberately points at the small fixture pack:
    # the first range fails short, proving planning admitted 300 MiB without
    # allocating or fetching the advertised artifact.
    assert {:error, %Error{code: :backend_error}} =
             PackFetch.start_link(
               backend:
                 {Gitility.TrackingRangeBackend,
                  {LocalDirectory, published, tracker, :synthetic_300m_manifest}},
               into: {:dir, temp_dir("synthetic-300m")}
             )

    assert Agent.get(tracker, & &1.read_calls) > 0
  end

  test "range request window obeys concurrency" do
    published = publish("sha1-basic.git", "concurrency")
    on_exit(fn -> File.rm_rf(published) end)
    {:ok, backend_state} = LocalDirectory.init(published)
    {:ok, manifest} = LocalDirectory.manifest(backend_state)
    pack_size = hd(manifest.packs).pack_size
    chunk_bytes = max(div(pack_size + 3, 4), 1)
    observer = self()

    for concurrency <- [1, 4] do
      {:ok, tracker} = tracker()
      destination = temp_dir("concurrency-#{concurrency}")

      starter =
        Task.async(fn ->
          PackFetch.start_link(
            backend:
              {Gitility.TrackingRangeBackend,
               {LocalDirectory, published, tracker, {:latch, observer, concurrency}}},
            into: {:dir, destination},
            concurrency: concurrency,
            chunk_bytes: chunk_bytes,
            limits: generous_limits()
          )
        end)

      waiting =
        for _ <- 1..concurrency do
          assert_receive {:range_backend_waiting, callback}, 5_000
          callback
        end

      if concurrency == 1 do
        refute_receive {:range_backend_waiting, _callback}, 100
      end

      observed = Agent.get(tracker, & &1.max)
      if concurrency == 1, do: assert(observed == 1), else: assert(observed > 1)
      Enum.each(waiting, &send(&1, :release))
      {:ok, supervisor} = Task.await(starter, 30_000)
      stop(supervisor)
      Agent.stop(tracker)
      File.rm_rf(destination)
    end
  end

  test "provider death and request timeout unblock startup" do
    published = publish("sha1-basic.git", "lifecycle")
    on_exit(fn -> File.rm_rf(published) end)

    {:ok, tracker} = tracker()
    caller = self()

    starter =
      Task.async(fn ->
        PackFetch.start_link(
          backend:
            {Gitility.TrackingRangeBackend,
             {LocalDirectory, published, tracker, {:notify_and_hang, caller}}},
          into: {:dir, temp_dir("provider-down")},
          request_timeout: 5_000,
          limits: generous_limits()
        )
      end)

    assert_receive {:range_backend_entered, _callback}, 5_000

    supervisor =
      starter.pid
      |> Process.info(:links)
      |> elem(1)
      |> Enum.find(fn pid ->
        try do
          Enum.any?(Supervisor.which_children(pid), fn
            {Gitility.ODB.Provider, _child, :worker, _modules} -> true
            _other -> false
          end)
        catch
          :exit, _reason -> false
        end
      end)

    provider =
      Supervisor.which_children(supervisor)
      |> Enum.find_value(fn
        {Gitility.ODB.Provider, pid, :worker, _modules} -> pid
        _other -> nil
      end)

    Process.exit(provider, :kill)
    assert {:error, %Error{code: :provider_down}} = Task.await(starter, 5_000)
    Agent.stop(tracker)

    {:ok, timeout_tracker} = tracker()

    assert {:error, %Error{code: :provider_timeout}} =
             PackFetch.start_link(
               backend:
                 {Gitility.TrackingRangeBackend,
                  {LocalDirectory, published, timeout_tracker, {:notify_and_hang, self()}}},
               into: {:dir, temp_dir("provider-timeout")},
               request_timeout: 100,
               limits: generous_limits()
             )

    Agent.stop(timeout_tracker)
  end

  test "refresh fetches only the new generation and keeps old objects" do
    published = publish("sha1-basic.git", "refresh")
    destination = temp_dir("refresh")
    {:ok, tracker} = tracker()

    on_exit(fn ->
      File.rm_rf(published)
      File.rm_rf(destination)
      if Process.alive?(tracker), do: Agent.stop(tracker)
    end)

    {:ok, supervisor} =
      PackFetch.start_link(
        backend:
          {Gitility.TrackingRangeBackend,
           {LocalDirectory, published, tracker, {:controlled_latch, self()}}},
        into: {:dir, destination},
        concurrency: 1,
        limits: generous_limits()
      )

    {:ok, odb} = ODB.handle(supervisor)
    basic = fixture_oid(:sha1_basic_head)
    assert {:ok, %Snapshot{commit_oid: ^basic}} = Snapshot.open(odb, basic)

    :ok = LocalDirectory.publish(fixture("sha1-history-midx.git"), published)
    Agent.update(tracker, &%{&1 | block_once: true})
    refresh = Task.async(fn -> ODB.refresh(odb) end)
    assert_receive {:range_backend_waiting, callback}, 5_000

    # The old Arc<LocalOdb> remains live until the fully verified replacement
    # is swapped in, so reads continue throughout acquisition.
    assert {:ok, %Snapshot{commit_oid: ^basic}} = Snapshot.open(odb, basic)
    send(callback, :release)
    assert :ok = Task.await(refresh, 30_000)

    {:ok, stats} = ODB.stats(odb)
    assert stats.packs_hydrated > 0
    assert stats.packs_skipped == 0
    history = fixture_oid(:sha1_history_head)
    assert {:ok, %Snapshot{commit_oid: ^history}} = Snapshot.open(odb, history)
    assert {:ok, %Snapshot{commit_oid: ^basic}} = Snapshot.open(odb, basic)

    assert :ok = ODB.refresh(odb)
    {:ok, second_stats} = ODB.stats(odb)
    assert second_stats.bytes_verified == 0
    assert second_stats.packs_hydrated == 0
    assert second_stats.packs_skipped == 2
    stop(supervisor)
  end

  defp tracker do
    Agent.start_link(fn -> %{current: 0, max: 0, read_calls: 0, block_once: false} end)
  end

  defp eventually(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    eventually_until(fun, deadline)
  end

  defp eventually_until(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(20)
        eventually_until(fun, deadline)
      end
    end
  end

  defp generous_limits do
    Limits.new(
      timeout_ms: 30_000,
      max_provider_requests: 100_000,
      max_provider_bytes: 512 * 1024 * 1024,
      max_result_bytes: 32 * 1024 * 1024
    )
  end
end

if System.get_env("GITILITY_TEST_POSTGRES_URL") do
  defmodule Gitility.PostgresRangeConformanceBackend do
    @behaviour Gitility.ODB.RangeBackend

    def init(:conformance) do
      Gitility.ODB.RangeBackend.Postgres.init(
        connection: :persistent_term.get({Gitility.PostgresRangeConformanceTest, :connection}),
        prefix: "gitility_pack_conformance"
      )
    end

    defdelegate manifest(state), to: Gitility.ODB.RangeBackend.Postgres
    defdelegate read_ranges(ranges, state), to: Gitility.ODB.RangeBackend.Postgres
    defdelegate terminate(reason, state), to: Gitility.ODB.RangeBackend.Postgres

    defdelegate publish_conformance_artifact(state, key, bytes),
      to: Gitility.ODB.RangeBackend.Postgres
  end

  defmodule Gitility.PostgresRangeConformanceTest do
    use Gitility.ODB.RangeBackend.Conformance,
      backend: Gitility.PostgresRangeConformanceBackend,
      concurrency: 4

    setup_all do
      connection =
        start_supervised!(
          {Postgrex,
           Gitility.ODB.RangeBackend.Postgres.url_to_postgrex_options(
             System.fetch_env!("GITILITY_TEST_POSTGRES_URL")
           )}
        )

      directory = Gitility.RangeTestSupport.publish("sha1-basic.git", "postgres-conformance")

      :ok =
        Gitility.ODB.RangeBackend.Postgres.publish(
          Gitility.RangeTestSupport.fixture("sha1-basic.git"),
          connection,
          prefix: "gitility_pack_conformance"
        )

      :persistent_term.put({__MODULE__, :directory}, directory)
      :persistent_term.put({__MODULE__, :connection}, connection)

      on_exit(fn ->
        :persistent_term.erase({__MODULE__, :directory})
        :persistent_term.erase({__MODULE__, :connection})
        File.rm_rf(directory)
      end)

      :ok
    end

    def backend_init_arg, do: :conformance

    def backend_artifacts do
      Gitility.RangeTestSupport.artifacts(:persistent_term.get({__MODULE__, :directory}))
    end

    def backend_publish_artifact(state, key, bytes) do
      Gitility.PostgresRangeConformanceBackend.publish_conformance_artifact(
        state,
        key,
        bytes
      )
    end

    test "Postgres hydrates a query-equivalent PackFetch store" do
      destination = Gitility.RangeTestSupport.temp_dir("postgres-hydrated")
      on_exit(fn -> File.rm_rf(destination) end)

      assert {:ok, supervisor} =
               Gitility.ODB.PackFetch.start_link(
                 backend:
                   {Gitility.ODB.RangeBackend.Postgres,
                    [
                      url: System.fetch_env!("GITILITY_TEST_POSTGRES_URL"),
                      prefix: "gitility_pack_conformance"
                    ]},
                 into: {:dir, destination},
                 limits:
                   Gitility.Limits.new(
                     max_provider_requests: 100_000,
                     max_provider_bytes: 512 * 1024 * 1024
                   )
               )

      assert {:ok, odb} = Gitility.ODB.handle(supervisor)

      assert {:ok, local} =
               Gitility.Repository.open(Gitility.RangeTestSupport.fixture("sha1-basic.git"))

      Gitility.RangeTestSupport.parity!(
        local,
        odb,
        Gitility.RangeTestSupport.fixture_oid(:sha1_basic_head),
        ["README.md", "binary.dat", <<"invalid-", 0xFF, "-name.txt">>]
      )

      Gitility.RangeTestSupport.stop(supervisor)
    end
  end
else
  defmodule Gitility.PostgresRangeConformanceSkippedTest do
    use ExUnit.Case, async: false

    @tag skip: "GITILITY_TEST_POSTGRES_URL is unset — PostgreSQL conformance was not provisioned"
    test "PostgreSQL range backend conformance is skipped loudly", do: :ok
  end
end
