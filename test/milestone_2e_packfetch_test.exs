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
    if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
    :ok
  end
end

defmodule Gitility.TrackingRangeBackend do
  @behaviour Gitility.ODB.RangeBackend

  @impl true
  def init({delegate, arg, tracker, mode}) do
    with {:ok, state} <- delegate.init(arg) do
      {:ok, %{delegate: delegate, state: state, tracker: tracker, mode: mode}}
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
      mutate(result, ranges, config.mode)
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

      {next, next}
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

  defp maybe_block(_mode, _tracking, _ranges), do: :ok

  defp mutate({:ok, replies}, ranges, :short) do
    target = Enum.find(ranges, &(&1.length > 0))
    {:ok, Map.update!(replies, target, &binary_part(&1, 0, byte_size(&1) - 1))}
  end

  defp mutate({:ok, replies}, ranges, :overlong) do
    target = Enum.find(ranges, &(&1.length > 0))
    {:ok, Map.update!(replies, target, &(&1 <> <<0>>))}
  end

  defp mutate({:ok, replies}, ranges, :corrupt_pack) do
    corrupt_matching(replies, ranges, ".pack")
  end

  defp mutate({:ok, replies}, ranges, :corrupt_index) do
    corrupt_matching(replies, ranges, ".idx")
  end

  defp mutate(result, _ranges, _mode), do: result

  defp corrupt_matching(replies, ranges, suffix) do
    case Enum.find(ranges, &(&1.length > 0 and String.ends_with?(&1.key, suffix))) do
      nil -> {:ok, replies}
      range -> {:ok, Map.update!(replies, range, &flip_first/1)}
    end
  end

  defp flip_first(<<first, rest::binary>>), do: <<Bitwise.bxor(first, 1), rest::binary>>
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

  test "Linux memory destination works and other platforms refuse it explicitly" do
    published = publish("sha1-basic.git", "memory")
    on_exit(fn -> File.rm_rf(published) end)

    if PackFetch.memory_supported?() do
      {:ok, local} = Repository.open(fixture("sha1-basic.git"))

      {:ok, supervisor, remote} =
        start_packfetch(published, :memory, max_bytes: 64 * 1024 * 1024)

      parity!(local, remote, fixture_oid(:sha1_basic_head), @basic_paths)
      stop(supervisor)
    else
      assert {:error, %Error{code: :unsupported_operation, message: message}} =
               PackFetch.start_link(
                 backend: {LocalDirectory, published},
                 into: :memory
               )

      assert message =~ "{:dir, path}"
    end
  end

  test "bundle destination is reserved with a stable unsupported error" do
    published = publish("sha1-basic.git", "bundle")
    on_exit(fn -> File.rm_rf(published) end)

    assert {:error, %Error{code: :unsupported_operation, message: message}} =
             PackFetch.start_link(
               backend: {LocalDirectory, published},
               into: {:bundle, temp_dir("bundle")}
             )

    assert message =~ "Gitility.Bundle"
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

    {:ok, second, second_odb} = start_packfetch(published, {:dir, destination})
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

    for mode <- [:bad_version, :duplicate_id, :wrong_length_id] do
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

    assert {:error, %Error{code: :budget_exceeded, details: %{limit: :max_provider_bytes}}} =
             PackFetch.start_link(
               backend:
                 {Gitility.TrackingRangeBackend,
                  {LocalDirectory, published, tracker, :oversized_manifest}},
               into: {:dir, temp_dir("oversized")},
               limits: Limits.new(max_provider_bytes: 1024)
             )

    assert Agent.get(tracker, & &1.read_calls) == 0
    Agent.stop(tracker)
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

    on_exit(fn ->
      File.rm_rf(published)
      File.rm_rf(destination)
    end)

    {:ok, supervisor, odb} = start_packfetch(published, {:dir, destination})
    basic = fixture_oid(:sha1_basic_head)
    assert {:ok, %Snapshot{commit_oid: ^basic}} = Snapshot.open(odb, basic)

    :ok = LocalDirectory.publish(fixture("sha1-history-midx.git"), published)
    assert :ok = ODB.refresh(odb)
    {:ok, stats} = ODB.stats(odb)
    assert stats.packs_hydrated > 0
    assert stats.packs_skipped == 0
    history = fixture_oid(:sha1_history_head)
    assert {:ok, %Snapshot{commit_oid: ^history}} = Snapshot.open(odb, history)
    assert {:ok, %Snapshot{commit_oid: ^basic}} = Snapshot.open(odb, basic)
    stop(supervisor)
  end

  defp tracker do
    Agent.start_link(fn -> %{current: 0, max: 0, read_calls: 0} end)
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
        url: System.fetch_env!("GITILITY_TEST_POSTGRES_URL"),
        prefix: "gitility_pack_conformance"
      )
    end

    defdelegate manifest(state), to: Gitility.ODB.RangeBackend.Postgres
    defdelegate read_ranges(ranges, state), to: Gitility.ODB.RangeBackend.Postgres
    defdelegate terminate(reason, state), to: Gitility.ODB.RangeBackend.Postgres
  end

  defmodule Gitility.PostgresRangeConformanceTest do
    use Gitility.ODB.RangeBackend.Conformance,
      backend: Gitility.PostgresRangeConformanceBackend,
      concurrency: 4

    setup_all do
      directory = Gitility.RangeTestSupport.publish("sha1-basic.git", "postgres-conformance")

      :ok =
        Gitility.ODB.RangeBackend.Postgres.publish(
          Gitility.RangeTestSupport.fixture("sha1-basic.git"),
          System.fetch_env!("GITILITY_TEST_POSTGRES_URL"),
          prefix: "gitility_pack_conformance"
        )

      :persistent_term.put({__MODULE__, :directory}, directory)

      on_exit(fn ->
        :persistent_term.erase({__MODULE__, :directory})
        File.rm_rf(directory)
      end)

      :ok
    end

    def backend_init_arg, do: :conformance

    def backend_artifacts do
      Gitility.RangeTestSupport.artifacts(:persistent_term.get({__MODULE__, :directory}))
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
