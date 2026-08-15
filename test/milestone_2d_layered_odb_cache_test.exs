defmodule Gitility.LayeredTestBackend do
  @behaviour Gitility.ODB.Backend

  alias Gitility.Object

  @impl true
  def init(agent) when is_pid(agent), do: {:ok, agent}

  @impl true
  def read_many(oids, agent) do
    objects =
      Agent.get_and_update(agent, fn state ->
        {state.objects, %{state | calls: state.calls + 1, batches: [oids | state.batches]}}
      end)

    {:ok,
     Map.new(oids, fn oid ->
       case Map.get(objects, oid) do
         %Object{} = object -> {oid, object}
         nil -> {oid, :not_found}
       end
     end)}
  end

  @impl true
  def prefetch(_oids, _agent), do: :ok

  @impl true
  def refresh(agent) do
    Agent.update(agent, &%{&1 | refresh_calls: &1.refresh_calls + 1})
    :ok
  end
end

defmodule Gitility.Milestone2dLayeredOdbCacheTest do
  use ExUnit.Case, async: false

  alias Gitility.{Error, ODB, OID, Runtime, Snapshot}
  alias Gitility.LayeredTestBackend, as: Backend

  setup_all do
    {:ok, Gitility.ProviderTestFixtures.load_objects()}
  end

  test "composition validates hashes, runtimes, cache count, and non-empty stores" do
    assert {:ok, sha1} = ODB.from_objects([], hash: :sha1)
    assert {:ok, sha256} = ODB.from_objects([], hash: :sha256)

    assert {:error, %Error{code: :hash_mismatch}} = ODB.layer([sha1, sha256])

    first_runtime = start_supervised!({Runtime, workers: 1})
    second_runtime = start_supervised!({Runtime, workers: 1})
    assert {:ok, first} = ODB.from_objects([], runtime: first_runtime)
    assert {:ok, second} = ODB.from_objects([], runtime: second_runtime)

    assert {:error, %Error{code: :runtime_mismatch}} = ODB.layer([first, second])

    assert {:error, %Error{code: :invalid_argument, message: message}} =
             ODB.layer([
               ODB.cache(max_bytes: 10),
               ODB.cache(max_bytes: 10),
               sha1
             ])

    assert message == "one cache layer per composition in 0.x"
    assert {:error, %Error{code: :invalid_argument}} = ODB.layer([])
    assert {:error, %Error{code: :invalid_argument}} = ODB.layer([ODB.cache(max_bytes: 10)])

    assert {:error, %Error{code: :invalid_argument}} =
             ODB.layer([sha1, ODB.cache(max_bytes: 10)])

    assert {:error, %Error{code: :invalid_argument}} =
             ODB.layer([ODB.cache(max_entries: 10), sha1])
  end

  test "cache and static layers short-circuit lower providers", fixture do
    [static_object, provider_object | _] = fixture.objects
    assert {:ok, static} = ODB.from_objects([static_object])
    {provider, agent} = start_provider(%{provider_object.oid => provider_object})

    assert {:ok, layered} =
             ODB.layer([
               ODB.cache(max_bytes: 1_000_000),
               static,
               provider
             ])

    assert {:ok, ^static_object} = ODB.read(layered, static_object.oid)
    assert {:ok, ^static_object} = ODB.read(layered, static_object.oid)
    assert Agent.get(agent, & &1.calls) == 0

    assert {:ok, ^provider_object} = ODB.read(layered, provider_object.oid)
    assert Agent.get(agent, & &1.calls) == 1
    assert {:ok, ^provider_object} = ODB.read(layered, provider_object.oid)
    assert Agent.get(agent, & &1.calls) == 1
  end

  test "layered stats expose per-job hits and cache residency", fixture do
    total_bytes = Enum.reduce(fixture.objects, 1, &(&2 + byte_size(&1.data)))
    {provider, agent} = start_provider(fixture.object_map)

    assert {:ok, layered} =
             ODB.layer([ODB.cache(max_bytes: total_bytes), provider])

    assert {:ok, snapshot} = Snapshot.open(layered, fixture.head)
    assert {:ok, first} = Gitility.list_tree(snapshot, "", recursive: true)
    calls_after_first = Agent.get(agent, & &1.calls)
    assert first.stats.cache_misses > 0
    assert first.stats.cache_entries > 0
    assert first.stats.cache_bytes > 0

    assert {:ok, second} = Gitility.list_tree(snapshot, "", recursive: true)
    assert second.items == first.items
    assert second.stats.cache_hits > 0
    assert second.stats.cache_misses == 0
    assert Agent.get(agent, & &1.calls) == calls_after_first
  end

  test "max_object_bytes bypasses while max_bytes evicts without hiding objects", fixture do
    largest = Enum.max_by(fixture.objects, &byte_size(&1.data))
    {bypass_provider, bypass_agent} = start_provider(%{largest.oid => largest})

    assert {:ok, bypass} =
             ODB.layer([
               ODB.cache(max_bytes: byte_size(largest.data) + 1, max_object_bytes: 1),
               bypass_provider
             ])

    assert {:ok, ^largest} = ODB.read(bypass, largest.oid)
    assert {:ok, ^largest} = ODB.read(bypass, largest.oid)
    assert Agent.get(bypass_agent, & &1.calls) == 2

    cap = fixture.objects |> Enum.map(&byte_size(&1.data)) |> Enum.max()
    {evicting_provider, _agent} = start_provider(fixture.object_map)

    assert {:ok, evicting} = ODB.layer([ODB.cache(max_bytes: cap), evicting_provider])
    assert {:ok, snapshot} = Snapshot.open(evicting, fixture.head)

    assert {:ok, page} =
             Gitility.list_tree(snapshot, "",
               recursive: true,
               include: [:size]
             )

    assert page.items != []
    assert page.stats.cache_evictions > 0
    assert page.stats.cache_bytes <= cap
    assert {:ok, ^largest} = ODB.read(evicting, largest.oid)
  end

  test "provider order is first-hit-wins", fixture do
    object = hd(fixture.objects)
    {first, first_agent} = start_provider(%{object.oid => object})
    {second, second_agent} = start_provider(%{object.oid => object})
    assert {:ok, layered} = ODB.layer([first, second])

    assert {:ok, ^object} = ODB.read(layered, object.oid)
    assert Agent.get(first_agent, & &1.calls) == 1
    assert Agent.get(second_agent, & &1.calls) == 0
  end

  test "refresh reaches every provider and clears every negative cache" do
    missing = OID.new!(:sha1, <<9::160>>)
    {first, first_agent} = start_provider(%{}, cache: [negative_ttl: 60_000])
    {second, second_agent} = start_provider(%{}, cache: [negative_ttl: 60_000])
    assert {:ok, layered} = ODB.layer([first, second])

    for _ <- 1..2 do
      assert {:error, %Error{code: :missing_object}} = ODB.read(layered, missing)
    end

    assert Agent.get(first_agent, & &1.calls) == 1
    assert Agent.get(second_agent, & &1.calls) == 1
    assert :ok = ODB.refresh(layered)
    assert Agent.get(first_agent, & &1.refresh_calls) == 1
    assert Agent.get(second_agent, & &1.refresh_calls) == 1

    assert {:error, %Error{code: :missing_object}} = ODB.read(layered, missing)
    assert Agent.get(first_agent, & &1.calls) == 2
    assert Agent.get(second_agent, & &1.calls) == 2
  end

  test "cached provider parity matches the local oracle byte-for-byte", fixture do
    total_bytes = Enum.reduce(fixture.objects, 1, &(&2 + byte_size(&1.data)))
    {provider, _agent} = start_provider(fixture.object_map)
    assert {:ok, layered} = ODB.layer([ODB.cache(max_bytes: total_bytes), provider])
    assert {:ok, snapshot} = Snapshot.open(layered, fixture.head)

    assert {:ok, expected_tree} =
             Gitility.list_tree(fixture.local_snapshot, "", recursive: true)

    assert {:ok, actual_tree} = Gitility.list_tree(snapshot, "", recursive: true)
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
      assert {:ok, actual} = Gitility.read_file(snapshot, path)
      assert actual == expected
    end)
  end

  defp start_provider(objects, opts \\ []) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{objects: objects, calls: 0, batches: [], refresh_calls: 0}
      end)

    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)
    provider_opts = Keyword.put(opts, :backend, {Backend, agent})
    assert {:ok, supervisor} = ODB.start_link(provider_opts)
    assert {:ok, odb} = ODB.handle(supervisor)
    {odb, agent}
  end
end
