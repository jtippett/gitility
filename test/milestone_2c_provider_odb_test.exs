defmodule Gitility.ProviderTestFixtures do
  alias Gitility.{ODB, OID, Repository, Snapshot}

  @fixtures Path.expand("../fixtures/generated", __DIR__)

  def load_objects do
    {:ok, repository} = Repository.open(Path.join(@fixtures, "sha1-basic.git"))
    head = fixture_oid(:sha1_basic_head)
    {:ok, snapshot} = Snapshot.open(repository.odb, head)
    {:ok, page} = Gitility.list_tree(snapshot, "", recursive: true)

    tag =
      @fixtures
      |> Path.join("sha1-basic.git/refs/tags/v1.0.0")
      |> File.read!()
      |> String.trim()
      |> OID.parse!()

    oids =
      [head, snapshot.tree_oid, tag | Enum.map(page.items, & &1.oid)]
      |> Enum.uniq()

    {:ok, results} = ODB.read_many(repository.odb, oids)
    objects = results |> Map.values() |> Enum.reject(&(&1 == :not_found))

    %{
      repository: repository,
      local_snapshot: snapshot,
      head: head,
      tag: tag,
      objects: objects,
      object_map: Map.new(objects, &{&1.oid, &1})
    }
  end

  def fixture_oid(name) do
    value =
      @fixtures
      |> Path.join("OIDS")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.find_value(fn line ->
        case String.split(line, "=", parts: 2) do
          [key, value] -> if key == Atom.to_string(name), do: value
          _ -> nil
        end
      end)

    OID.parse!(value)
  end
end

defmodule Gitility.ProviderTestBackend do
  @behaviour Gitility.ODB.Backend

  alias Gitility.{Object, ObjectHeader}

  @impl true
  def init(:conformance) do
    {:ok, :persistent_term.get({__MODULE__, :conformance_agent})}
  end

  def init({:error_init, reason}), do: {:error, reason}
  def init(agent) when is_pid(agent), do: {:ok, agent}

  @impl true
  def read_many(oids, agent) do
    config = enter(agent)
    Agent.update(agent, &%{&1 | batches: [oids | &1.batches]})

    try do
      maybe_notify(config)

      case config.mode do
        :normal ->
          results(oids, config.objects)

        {:sleep, milliseconds} ->
          Process.sleep(milliseconds)
          results(oids, config.objects)

        {:latch, observer} ->
          send(observer, {:provider_latch_entered, self()})

          receive do
            :release_provider_latch -> results(oids, config.objects)
          end

        :hang ->
          receive do
            :never -> {:error, :impossible}
          end

        {:error, reason} ->
          {:error, reason}

        {:tamper, target} ->
          {:ok,
           Map.new(oids, fn oid ->
             case config.objects[oid] do
               nil ->
                 {oid, :not_found}

               %Object{} = object when oid == target ->
                 {oid, %{object | data: object.data <> "!"}}

               %Object{} = object ->
                 {oid, object}
             end
           end)}

        {:extra, extra_oid} ->
          {:ok, Map.put(elem(results(oids, config.objects), 1), extra_oid, :not_found)}
      end
    after
      leave(agent)
    end
  end

  @impl true
  def read_headers(oids, agent) do
    config = enter(agent)

    try do
      {:ok,
       Map.new(oids, fn oid ->
         case config.objects[oid] do
           nil ->
             {oid, :not_found}

           %Object{} = object ->
             type = if config.header_kind, do: config.header_kind, else: object.type
             size = if config.header_size, do: config.header_size, else: byte_size(object.data)
             {oid, %ObjectHeader{oid: oid, type: type, size: size}}
         end
       end)}
    after
      leave(agent)
    end
  end

  @impl true
  def prefetch(oids, agent) do
    observer =
      Agent.get_and_update(agent, fn state ->
        {state.observer, %{state | prefetches: [oids | state.prefetches]}}
      end)

    if is_pid(observer), do: send(observer, {:provider_prefetch, oids})
    :ok
  end

  @impl true
  def refresh(agent) do
    config =
      Agent.get_and_update(agent, fn state ->
        next = %{state | refresh_calls: state.refresh_calls + 1}
        {next, next}
      end)

    case config.refresh_mode do
      :normal ->
        :ok

      {:error, reason} ->
        {:error, reason}

      {:latch, observer} ->
        send(observer, {:provider_refresh_entered, self()})

        receive do
          :release_provider_refresh -> :ok
        end

      :hang ->
        receive do
          :never -> :ok
        end
    end
  end

  defp results(oids, objects) do
    {:ok, Map.new(oids, fn oid -> {oid, Map.get(objects, oid, :not_found)} end)}
  end

  @impl true
  def terminate(_reason, agent) do
    # Only the tests that pass `terminate_observer:` have that key; the
    # conformance agent's state (provider_state/1) does not — and terminate/2
    # genuinely runs now (Provider traps exits), so be tolerant.
    if is_pid(agent) and Process.alive?(agent) do
      case Agent.get(agent, &Map.get(&1, :terminate_observer)) do
        nil -> :ok
        observer -> send(observer, :provider_backend_terminated)
      end
    end

    :ok
  end

  defp enter(agent) do
    Agent.get_and_update(agent, fn state ->
      current = state.current + 1
      next = %{state | current: current, max: max(state.max, current), calls: state.calls + 1}
      {next, next}
    end)
  end

  defp leave(agent), do: Agent.update(agent, &%{&1 | current: max(&1.current - 1, 0)})

  defp maybe_notify(%{observer: pid}) when is_pid(pid), do: send(pid, :provider_callback_entered)
  defp maybe_notify(_config), do: :ok
end

defmodule Gitility.BrokenProviderTestBackend do
  @behaviour Gitility.ODB.Backend

  @impl true
  def init(:conformance) do
    {:ok, :persistent_term.get({__MODULE__, :conformance_objects})}
  end

  @impl true
  def read_many(oids, objects) do
    {:ok,
     oids
     |> Enum.drop(-1)
     |> Map.new(fn oid -> {oid, Map.get(objects, oid, :not_found)} end)}
  end
end

defmodule Gitility.ProviderBackendConformanceTest do
  use Gitility.ODB.Backend.Conformance,
    backend: Gitility.ProviderTestBackend,
    init_arg: :conformance,
    concurrency: 4

  setup_all do
    fixture = Gitility.ProviderTestFixtures.load_objects()
    {:ok, agent} = Agent.start_link(fn -> provider_state(fixture.object_map) end)
    :persistent_term.put({Gitility.ProviderTestBackend, :conformance_agent}, agent)

    on_exit(fn ->
      :persistent_term.erase({Gitility.ProviderTestBackend, :conformance_agent})
      if Process.alive?(agent), do: Agent.stop(agent)
    end)

    :ok
  end

  def backend_objects do
    agent = :persistent_term.get({Gitility.ProviderTestBackend, :conformance_agent})
    agent |> Agent.get(& &1.objects) |> Map.values()
  end

  defp provider_state(objects) do
    %{
      objects: objects,
      mode: :normal,
      observer: nil,
      current: 0,
      max: 0,
      calls: 0,
      header_kind: nil,
      header_size: nil,
      prefetches: [],
      refresh_mode: :normal,
      refresh_calls: 0,
      batches: []
    }
  end
end

defmodule Gitility.BrokenProviderBackendConformanceTest do
  use Gitility.ODB.Backend.Conformance,
    backend: Gitility.BrokenProviderTestBackend,
    init_arg: :conformance,
    concurrency: 2,
    expected_failure: :incomplete_batch

  setup_all do
    fixture = Gitility.ProviderTestFixtures.load_objects()

    :persistent_term.put(
      {Gitility.BrokenProviderTestBackend, :conformance_objects},
      fixture.object_map
    )

    on_exit(fn ->
      :persistent_term.erase({Gitility.BrokenProviderTestBackend, :conformance_objects})
    end)

    :ok
  end

  def backend_objects do
    :persistent_term.get({Gitility.BrokenProviderTestBackend, :conformance_objects})
    |> Map.values()
  end
end

defmodule Gitility.Milestone2cProviderOdbTest do
  use ExUnit.Case, async: false

  alias Gitility.{Error, Job, Limits, ODB, OID, Runtime, Snapshot}
  alias Gitility.ProviderTestBackend, as: Backend

  setup_all do
    {:ok, Gitility.ProviderTestFixtures.load_objects()}
  end

  test "provider matches the local-store oracle for trees, files, snapshots, and peel", fixture do
    {odb, _agent} = start_provider(fixture.object_map)
    assert {:ok, provider_snapshot} = Snapshot.open(odb, fixture.head)

    assert provider_snapshot.commit_oid == fixture.local_snapshot.commit_oid
    assert provider_snapshot.tree_oid == fixture.local_snapshot.tree_oid

    assert {:ok, expected_tree} =
             Gitility.list_tree(fixture.local_snapshot, "", recursive: true)

    assert {:ok, actual_tree} = Gitility.list_tree(provider_snapshot, "", recursive: true)

    # The local ODB is the parity oracle: storage transport must not alter a
    # single path byte or semantic tree entry.
    assert actual_tree.items == expected_tree.items

    paths = [
      "README.md",
      "src/story.txt",
      "subdir/nested.txt",
      "long-line.txt",
      "binary.dat",
      <<"invalid-", 0xFF, "-name.txt">>
    ]

    Enum.each(paths, fn path ->
      assert {:ok, expected} = Gitility.read_file(fixture.local_snapshot, path)
      assert {:ok, actual} = Gitility.read_file(provider_snapshot, path)
      assert %{actual | stats: expected.stats} == expected
    end)

    assert {:ok, peeled_commit} = Gitility.peel(odb, fixture.tag)
    assert peeled_commit == fixture.head
    assert {:ok, peeled_tree} = Gitility.peel(odb, fixture.tag, to: :tree)
    assert peeled_tree == fixture.local_snapshot.tree_oid
  end

  test "provider callbacks run concurrently up to the configured limit", fixture do
    runtime = start_runtime(workers: 4, max_queue: 16, max_jobs_per_owner: 8)

    {concurrent, concurrent_agent} =
      start_provider(fixture.object_map,
        runtime: runtime,
        concurrency: 4,
        mode: {:latch, self()}
      )

    tasks =
      for _ <- 1..4 do
        Task.async(fn -> ODB.read(concurrent, fixture.head) end)
      end

    callback_tasks =
      for _ <- 1..4 do
        assert_receive {:provider_latch_entered, callback_task}, 1_000
        callback_task
      end

    Enum.each(callback_tasks, &send(&1, :release_provider_latch))
    Enum.each(tasks, fn task -> assert {:ok, _object} = Task.await(task, 5_000) end)
    assert Agent.get(concurrent_agent, & &1.max) > 1

    {serial, serial_agent} =
      start_provider(fixture.object_map,
        runtime: runtime,
        concurrency: 1,
        mode: {:latch, self()}
      )

    tasks =
      for _ <- 1..4 do
        Task.async(fn -> ODB.read(serial, fixture.head) end)
      end

    for _ <- 1..4 do
      assert_receive {:provider_latch_entered, callback_task}, 1_000
      assert Agent.get(serial_agent, & &1.current) == 1
      send(callback_task, :release_provider_latch)
    end

    Enum.each(tasks, fn task -> assert {:ok, _object} = Task.await(task, 5_000) end)
    assert Agent.get(serial_agent, & &1.max) == 1
  end

  test "provider death wakes in-flight jobs and permanently poisons the old handle", fixture do
    {odb, agent} = start_provider(fixture.object_map, observer: self())
    assert {:ok, snapshot} = Snapshot.open(odb, fixture.head)
    reset_probe(agent, :hang, self())

    assert {:ok, job} = Gitility.async_list_tree(snapshot)
    assert_receive :provider_callback_entered, 1_000
    Process.exit(odb.provider, :kill)

    assert {:error, %Error{code: :provider_down, retryable: true}} = Job.await(job, 1_000)
    assert Job.status(job) == :failed

    assert {:error, %Error{code: :provider_down, retryable: true}} =
             ODB.read(odb, fixture.head)
  end

  test "provider death wakes five concurrent waiters", fixture do
    runtime = start_runtime(workers: 6, max_queue: 16, max_jobs_per_owner: 8)

    {odb, _agent} =
      start_provider(fixture.object_map,
        runtime: runtime,
        concurrency: 5,
        mode: :hang,
        observer: self()
      )

    waiters = for _ <- 1..5, do: Task.async(fn -> ODB.read(odb, fixture.head) end)

    for _ <- 1..5 do
      assert_receive :provider_callback_entered, 1_000
    end

    Process.exit(odb.provider, :kill)

    Enum.each(waiters, fn waiter ->
      assert {:error, %Error{code: :provider_down}} = Task.await(waiter, 1_000)
    end)
  end

  test "clean supervisor shutdown wakes an in-flight provider read promptly", fixture do
    {odb, agent} =
      start_provider(fixture.object_map, observer: self(), request_timeout: 10_000)

    assert {:ok, snapshot} = Snapshot.open(odb, fixture.head)
    reset_probe(agent, :hang, self())
    assert {:ok, job} = Gitility.async_list_tree(snapshot)
    assert_receive :provider_callback_entered, 1_000

    started = System.monotonic_time(:millisecond)
    assert :ok = stop_provider(odb)
    assert {:error, %Error{code: :provider_down}} = Job.await(job, 1_000)
    assert System.monotonic_time(:millisecond) - started < 250
  end

  # Regression: Provider must trap exits, or an orderly supervisor stop kills
  # it WITHOUT running terminate/2 — the backend's documented terminate/2
  # never fires and provider_failed is left to the watchdog racing its own
  # shutdown (~10% of clean stops hung waiters for the full request_timeout).
  # The clean-shutdown test above passed by winning that race; this one pins
  # the mechanism: 20 consecutive orderly stops must each run terminate/2
  # (asserted through the backend's terminate callback) and wake the waiter.
  test "orderly provider stop always runs terminate/2 and wakes waiters", fixture do
    for _ <- 1..20 do
      {odb, agent} =
        start_provider(fixture.object_map,
          observer: self(),
          request_timeout: 10_000,
          terminate_observer: self()
        )

      assert {:ok, snapshot} = Snapshot.open(odb, fixture.head)
      reset_probe(agent, :hang, self())
      assert {:ok, job} = Gitility.async_list_tree(snapshot)
      assert_receive :provider_callback_entered, 1_000
      assert :ok = stop_provider(odb)
      assert_receive :provider_backend_terminated, 500
      assert {:error, %Error{code: :provider_down}} = Job.await(job, 250)
    end
  end

  test "a provider ODB is a valid supervisor child and handle accepts pid or name", fixture do
    agent = start_backend_agent(fixture.object_map)
    name = {:global, {__MODULE__, make_ref()}}

    provider =
      start_supervised!(
        {ODB, name: name, backend: {Backend, agent}, cache: [object_bytes: 1_000_000]}
      )

    assert is_pid(provider)
    assert {:ok, by_pid} = ODB.handle(provider)
    assert {:ok, by_name} = ODB.handle(name)
    assert by_pid.ref == by_name.ref
    assert {:ok, object} = ODB.read(by_name, fixture.head)
    assert object.oid == fixture.head
  end

  test "stray messages and unknown calls do not kill or poison a provider", fixture do
    {odb, _agent} = start_provider(fixture.object_map)
    send(odb.provider, {:garbage, make_ref()})
    assert {:error, :unknown_call} = GenServer.call(odb.provider, {:garbage_call, make_ref()})
    assert Process.alive?(odb.provider)
    assert {:ok, object} = ODB.read(odb, fixture.head)
    assert object.oid == fixture.head
  end

  test "duplicate replies are harmless end to end", fixture do
    previous = Application.get_env(:gitility, :provider_test_hook)
    Application.put_env(:gitility, :provider_test_hook, :duplicate_reply)

    on_exit(fn ->
      if previous do
        Application.put_env(:gitility, :provider_test_hook, previous)
      else
        Application.delete_env(:gitility, :provider_test_hook)
      end
    end)

    {odb, _agent} = start_provider(fixture.object_map)
    assert {:ok, first} = ODB.read(odb, fixture.head)
    assert {:ok, second} = ODB.read(odb, fixture.head)
    assert first == second
  end

  test "oversized provider payloads fail as object_too_large", fixture do
    {odb, _agent} = start_provider(fixture.object_map)

    assert {:error, %Error{code: :object_too_large, details: %{limit: :max_object_bytes}}} =
             ODB.read(odb, fixture.head, limits: Limits.new(max_object_bytes: 1))
  end

  test "job timeout and cancellation interrupt a hung provider wait promptly", fixture do
    {odb, agent} = start_provider(fixture.object_map, observer: self())
    assert {:ok, snapshot} = Snapshot.open(odb, fixture.head)
    reset_probe(agent, :hang, self())

    started = System.monotonic_time(:millisecond)

    assert {:ok, timed_out} =
             Gitility.async_list_tree(snapshot, "", limits: Limits.new(timeout_ms: 200))

    assert {:error, %Error{code: :timeout}} = Job.await(timed_out, 1_000)
    assert System.monotonic_time(:millisecond) - started < 1_000

    flush_callback_messages()

    assert {:ok, cancelled} =
             Gitility.async_list_tree(snapshot, "", limits: Limits.new(timeout_ms: 5_000))

    assert_receive :provider_callback_entered, 1_000
    started = System.monotonic_time(:millisecond)
    assert :ok = Job.cancel(cancelled)
    assert {:error, %Error{code: :cancelled}} = Job.await(cancelled, 500)
    assert System.monotonic_time(:millisecond) - started < 500
  end

  test "request_timeout maps to retryable provider_timeout", fixture do
    {odb, agent} = start_provider(fixture.object_map, request_timeout: 100)
    reset_probe(agent, {:sleep, 400})
    started = System.monotonic_time(:millisecond)

    assert {:error, %Error{code: :provider_timeout, retryable: true}} =
             ODB.read(odb, fixture.head)

    assert System.monotonic_time(:millisecond) - started < 1_000
  end

  test "tampered and unexpected replies are rejected without cache pollution", fixture do
    {tampered, tampered_agent} =
      start_provider(fixture.object_map,
        cache: [object_bytes: 1_000_000],
        mode: {:tamper, fixture.head}
      )

    for _ <- 1..2 do
      assert {:error, %Error{code: :hash_mismatch}} = ODB.read(tampered, fixture.head)
    end

    assert Agent.get(tampered_agent, & &1.calls) == 2
    # Direct header metadata has no payload to verify; it remains independent
    # of the rejected object bytes and never makes those bytes cacheable.
    assert {:ok, _header} = ODB.header(tampered, fixture.head)
    assert {:error, %Error{code: :hash_mismatch}} = ODB.read(tampered, fixture.head)

    extra = OID.new!(:sha1, <<7::160>>)
    {unexpected, _agent} = start_provider(fixture.object_map, mode: {:extra, extra})

    # Malformed batches are atomic: even expected objects in the same reply
    # are rejected and none are cached.
    assert {:error, %Error{code: :provider_protocol_error}} =
             ODB.read(unexpected, fixture.head)
  end

  test "provider header metadata is bounded and kind contradictions name the provider", fixture do
    {sized, _agent} = start_provider(fixture.object_map, header_size: 123_456)
    assert {:ok, sized_snapshot} = Snapshot.open(sized, fixture.head)
    assert {:ok, sized_page} = Gitility.list_tree(sized_snapshot, "", include: [:size])

    assert sized_page.items
           |> Enum.filter(&(&1.type in [:blob, :symlink]))
           |> Enum.all?(&(&1.size == 123_456))

    {oversized, _agent} =
      start_provider(fixture.object_map, header_size: 1_099_511_627_777)

    assert {:ok, oversized_snapshot} = Snapshot.open(oversized, fixture.head)

    assert {:error, %Error{code: :provider_protocol_error}} =
             Gitility.list_tree(oversized_snapshot, "", include: [:size])

    {wrong_kind, _agent} = start_provider(fixture.object_map, header_kind: :tree)
    assert {:ok, wrong_kind_snapshot} = Snapshot.open(wrong_kind, fixture.head)

    assert {:error,
            %Error{
              code: :provider_protocol_error,
              message: "provider header contradicts tree entry kind"
            }} = Gitility.list_tree(wrong_kind_snapshot, "", include: [:size])
  end

  test "verified local and static headers remain unaffected", fixture do
    assert {:ok, expected} =
             Gitility.list_tree(fixture.local_snapshot, "", recursive: true, include: [:size])

    assert {:ok, static} = ODB.from_objects(fixture.objects)
    assert {:ok, static_snapshot} = Snapshot.open(static, fixture.head)

    assert {:ok, actual} =
             Gitility.list_tree(static_snapshot, "", recursive: true, include: [:size])

    assert actual.items == expected.items
  end

  test "provider request and byte budgets stop tree work with named limits", fixture do
    {odb, _agent} = start_provider(fixture.object_map)
    assert {:ok, snapshot} = Snapshot.open(odb, fixture.head)

    assert {:error, %Error{code: :budget_exceeded, details: %{limit: :max_provider_requests}}} =
             Gitility.list_tree(snapshot, "",
               recursive: true,
               limits: Limits.new(max_provider_requests: 2)
             )

    assert {:error, %Error{code: :budget_exceeded, details: %{limit: :max_provider_bytes}}} =
             Gitility.list_tree(snapshot, "", limits: Limits.new(max_provider_bytes: 10))
  end

  test "read_many enforces its cap during the batch and deduplicates backend oids", fixture do
    {odb, agent} = start_provider(fixture.object_map)
    oids = fixture.objects |> Enum.take(6) |> Enum.map(& &1.oid)
    reset_probe(agent, :normal)

    assert {:error, %Error{code: :result_too_large, details: %{limit: :max_total_bytes}}} =
             ODB.read_many(odb, oids, max_total_bytes: 1)

    assert Agent.get(agent, & &1.calls) <= 1

    reset_probe(agent, :normal)
    assert {:ok, returned} = ODB.read_many(odb, [fixture.head, fixture.head])
    assert map_size(returned) == 1
    assert [[only_oid]] = Agent.get(agent, & &1.batches)
    assert only_oid == fixture.head
  end

  test "recursive provider walks prefetch child tree batches", fixture do
    {odb, _agent} = start_provider(fixture.object_map, observer: self())
    assert {:ok, snapshot} = Snapshot.open(odb, fixture.head)
    assert {:ok, _page} = Gitility.list_tree(snapshot, "", recursive: true)

    assert_receive {:provider_prefetch, child_tree_oids}, 1_000
    assert child_tree_oids != []
    assert Enum.all?(child_tree_oids, &match?(%OID{}, &1))
  end

  test "negative cache suppresses misses until refresh", fixture do
    missing = OID.new!(:sha1, <<0::160>>)

    {odb, agent} =
      start_provider(fixture.object_map, cache: [negative_ttl: 60_000])

    reset_probe(agent, :normal)

    assert {:error, %Error{code: :missing_object}} = ODB.read(odb, missing)
    assert {:error, %Error{code: :missing_object}} = ODB.read(odb, missing)
    assert Agent.get(agent, & &1.calls) == 1

    assert :ok = ODB.refresh(odb)
    assert {:error, %Error{code: :missing_object}} = ODB.read(odb, missing)
    assert Agent.get(agent, & &1.calls) == 2

    assert {:error, %Error{code: :unsupported_operation}} = ODB.refresh(fixture.repository.odb)
  end

  test "negative cache entries expire by TTL", fixture do
    missing = OID.new!(:sha1, <<1::160>>)
    {odb, agent} = start_provider(fixture.object_map, cache: [negative_ttl: 40])
    reset_probe(agent, :normal)

    assert {:error, %Error{code: :missing_object}} = ODB.read(odb, missing)
    assert {:error, %Error{code: :missing_object}} = ODB.read(odb, missing)
    assert Agent.get(agent, & &1.calls) == 1

    Process.sleep(60)
    assert {:error, %Error{code: :missing_object}} = ODB.read(odb, missing)
    assert Agent.get(agent, & &1.calls) == 2
  end

  test "refresh is timed and clears negatives only after backend success", fixture do
    missing = OID.new!(:sha1, <<2::160>>)

    {odb, agent} =
      start_provider(fixture.object_map,
        cache: [negative_ttl: 60_000],
        request_timeout: 100
      )

    reset_probe(agent, :normal)
    assert {:error, %Error{code: :missing_object}} = ODB.read(odb, missing)
    assert Agent.get(agent, & &1.calls) == 1

    test_pid = self()
    Agent.update(agent, &%{&1 | refresh_mode: {:latch, test_pid}})
    refresh = Task.async(fn -> ODB.refresh(odb) end)
    assert_receive {:provider_refresh_entered, refresh_callback}, 1_000

    # The callback is still running, so the native negative remains visible.
    assert {:error, %Error{code: :missing_object}} = ODB.read(odb, missing)
    assert Agent.get(agent, & &1.calls) == 1

    send(refresh_callback, :release_provider_refresh)
    assert :ok = Task.await(refresh, 1_000)
    assert {:error, %Error{code: :missing_object}} = ODB.read(odb, missing)
    assert Agent.get(agent, & &1.calls) == 2

    Agent.update(agent, &%{&1 | refresh_mode: :hang})
    started = System.monotonic_time(:millisecond)

    assert {:error, %Error{code: :provider_timeout, retryable: true}} = ODB.refresh(odb)
    assert System.monotonic_time(:millisecond) - started < 1_000

    # A timed-out refresh did not clear the negative populated above.
    assert {:error, %Error{code: :missing_object}} = ODB.read(odb, missing)
    assert Agent.get(agent, & &1.calls) == 2
  end

  test "backend error terms are logged locally but sanitized from query errors", fixture do
    secret = %{password: "hunter2"}
    {odb, _agent} = start_provider(fixture.object_map, mode: {:error, secret})

    assert {:error, %Error{code: :backend_error, message: message} = error} =
             ODB.read(odb, fixture.head)

    refute message =~ "hunter2"
    refute inspect(error) =~ "hunter2"
    assert message == "provider callback failed"
  end

  test "provider options and backend init failures are normalized", fixture do
    assert {:error, %Error{code: :invalid_argument}} =
             ODB.start_link(backend: {Backend, self()}, verify: :never)

    assert {:error, :init_refused} =
             ODB.start_link(backend: {Backend, {:error_init, :init_refused}})

    {odb, _agent} = start_provider(fixture.object_map)
    assert odb.kind == :provider
  end

  test "the conformance validator catches a deliberately incomplete backend", fixture do
    [first, second | _] = fixture.objects
    broken_reply = {:ok, %{first.oid => first}}

    assert {:error, :incomplete_batch} =
             Gitility.ODB.Backend.Conformance.validate_batch(
               [first.oid, second.oid],
               broken_reply
             )
  end

  # Stops a supervised provider for real (a plain Supervisor.stop on a
  # :permanent test-supervisor child would RESTART it).
  defp stop_provider(%ODB{} = odb) do
    ref = Process.monitor(odb.supervisor)

    {:ok, test_supervisor} = ExUnit.fetch_test_supervisor()

    {id, _pid, _type, _modules} =
      Enum.find(
        Supervisor.which_children(test_supervisor),
        fn {_id, pid, _type, _modules} -> pid == odb.supervisor end
      )

    :ok = stop_supervised!(id)
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    :ok
  end

  defp start_provider(objects, opts \\ []) do
    agent = start_backend_agent(objects, opts)

    provider_opts =
      [backend: {Backend, agent}]
      |> Keyword.merge(
        Keyword.drop(opts, [
          :mode,
          :observer,
          :header_kind,
          :header_size,
          :refresh_mode,
          :terminate_observer
        ])
      )

    provider =
      start_supervised!(
        Supervisor.child_spec({ODB, provider_opts},
          id: {ODB, System.unique_integer([:positive])}
        )
      )

    assert {:ok, odb} = ODB.handle(provider)

    {odb, agent}
  end

  # Backend agents and provider supervisors are started under the ExUnit test
  # supervisor — never linked to the test process. A linked process's stop in
  # on_exit races the test process's own exit signal (GenServer.stop sees
  # :shutdown and the on_exit process exits) — ~1 in 12 full runs on Linux.
  defp start_backend_agent(objects, opts \\ []) do
    agent =
      start_supervised!(
        Supervisor.child_spec(
          {Agent,
           fn ->
             %{
               objects: objects,
               mode: Keyword.get(opts, :mode, :normal),
               observer: Keyword.get(opts, :observer),
               current: 0,
               max: 0,
               calls: 0,
               header_kind: Keyword.get(opts, :header_kind),
               header_size: Keyword.get(opts, :header_size),
               prefetches: [],
               refresh_mode: Keyword.get(opts, :refresh_mode, :normal),
               refresh_calls: 0,
               terminate_observer: Keyword.get(opts, :terminate_observer),
               batches: []
             }
           end},
          id: {Agent, System.unique_integer([:positive])}
        )
      )

    agent
  end

  defp start_runtime(opts) do
    start_supervised!({Runtime, opts})
  end

  defp reset_probe(agent, mode, observer \\ nil) do
    Agent.update(agent, fn state ->
      %{
        state
        | mode: mode,
          observer: observer,
          current: 0,
          max: 0,
          calls: 0,
          batches: [],
          prefetches: []
      }
    end)
  end

  defp flush_callback_messages do
    receive do
      :provider_callback_entered -> flush_callback_messages()
    after
      0 -> :ok
    end
  end
end
