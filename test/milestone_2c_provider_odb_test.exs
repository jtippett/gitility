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

  alias Gitility.Object

  @impl true
  def init(:conformance) do
    {:ok, :persistent_term.get({__MODULE__, :conformance_agent})}
  end

  def init({:error_init, reason}), do: {:error, reason}
  def init(agent) when is_pid(agent), do: {:ok, agent}

  @impl true
  def read_many(oids, agent) do
    config = enter(agent)

    try do
      maybe_notify(config)

      case config.mode do
        :normal ->
          results(oids, config.objects)

        {:sleep, milliseconds} ->
          Process.sleep(milliseconds)
          results(oids, config.objects)

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
  def prefetch(_oids, _agent), do: :ok

  defp results(oids, objects) do
    {:ok, Map.new(oids, fn oid -> {oid, Map.get(objects, oid, :not_found)} end)}
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
    %{objects: objects, mode: :normal, observer: nil, current: 0, max: 0, calls: 0}
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
      assert actual == expected
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
        mode: {:sleep, 150}
      )

    assert {:ok, concurrent_snapshot} = Snapshot.open(concurrent, fixture.head)
    reset_probe(concurrent_agent, {:sleep, 150})

    jobs =
      for _ <- 1..4 do
        {:ok, job} = Gitility.async_list_tree(concurrent_snapshot)
        job
      end

    Enum.each(jobs, fn job -> assert {:ok, _page} = Job.await(job, 5_000) end)
    assert Agent.get(concurrent_agent, & &1.max) > 1

    {serial, serial_agent} =
      start_provider(fixture.object_map,
        runtime: runtime,
        concurrency: 1,
        mode: {:sleep, 75}
      )

    assert {:ok, serial_snapshot} = Snapshot.open(serial, fixture.head)
    reset_probe(serial_agent, {:sleep, 75})

    jobs =
      for _ <- 1..4 do
        {:ok, job} = Gitility.async_list_tree(serial_snapshot)
        job
      end

    Enum.each(jobs, fn job -> assert {:ok, _page} = Job.await(job, 5_000) end)
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
    assert {:error, %Error{code: :hash_mismatch}} = ODB.header(tampered, fixture.head)

    extra = OID.new!(:sha1, <<7::160>>)
    {unexpected, _agent} = start_provider(fixture.object_map, mode: {:extra, extra})

    # Malformed batches are atomic: even expected objects in the same reply
    # are rejected and none are cached.
    assert {:error, %Error{code: :provider_protocol_error}} =
             ODB.read(unexpected, fixture.head)
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

  defp start_provider(objects, opts \\ []) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          objects: objects,
          mode: Keyword.get(opts, :mode, :normal),
          observer: Keyword.get(opts, :observer),
          current: 0,
          max: 0,
          calls: 0
        }
      end)

    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    provider_opts =
      [backend: {Backend, agent}]
      |> Keyword.merge(Keyword.drop(opts, [:mode, :observer]))

    assert {:ok, odb} = ODB.start_link(provider_opts)

    {odb, agent}
  end

  defp start_runtime(opts) do
    start_supervised!({Runtime, opts})
  end

  defp reset_probe(agent, mode, observer \\ nil) do
    Agent.update(agent, fn state ->
      %{state | mode: mode, observer: observer, current: 0, max: 0, calls: 0}
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
