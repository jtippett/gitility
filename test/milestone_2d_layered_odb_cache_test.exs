defmodule Gitility.LayeredTestBackend do
  @behaviour Gitility.ODB.Backend

  alias Gitility.{Object, ObjectHeader}

  @impl true
  def init(agent) when is_pid(agent), do: {:ok, agent}

  @impl true
  def read_many(oids, agent) do
    {objects, error} =
      Agent.get_and_update(agent, fn state ->
        value = {state.objects, Map.get(state, :error)}

        {value,
         %{
           state
           | calls: state.calls + 1,
             batches: [oids | state.batches],
             call_kinds: [{:object, oids} | state.call_kinds]
         }}
      end)

    if error do
      {:error, error}
    else
      {:ok,
       Map.new(oids, fn oid ->
         case Map.get(objects, oid) do
           %Object{} = object -> {oid, object}
           nil -> {oid, :not_found}
         end
       end)}
    end
  end

  @impl true
  def read_headers(oids, agent) do
    objects =
      Agent.get_and_update(agent, fn state ->
        {state.objects,
         %{
           state
           | header_calls: state.header_calls + 1,
             call_kinds: [{:header, oids} | state.call_kinds]
         }}
      end)

    {:ok,
     Map.new(oids, fn oid ->
       case Map.get(objects, oid) do
         %Object{} = object ->
           {oid,
            %ObjectHeader{
              oid: oid,
              type: object.type,
              size: byte_size(object.data)
            }}

         nil ->
           {oid, :not_found}
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

  alias Gitility.{Error, ObjectHeader, ODB, OID, Runtime, Snapshot}
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

  test "layer and cache option type errors raise ArgumentError" do
    assert {:ok, store} = ODB.from_objects([])

    assert_raise ArgumentError, fn -> ODB.layer(:not_a_list) end
    assert_raise ArgumentError, fn -> ODB.layer([:not_an_odb]) end
    assert_raise ArgumentError, fn -> ODB.cache(%{}) end
    assert_raise ArgumentError, fn -> ODB.cache(max_bytes: 1, unknown: 2) end
    assert_raise ArgumentError, fn -> ODB.layer([{:cache, %{}}, store]) end

    assert_raise ArgumentError, fn ->
      ODB.layer([{:cache, [max_bytes: 1, unknown: 2]}, store])
    end

    for {key, value} <- [max_bytes: "1", max_entries: 1.0, max_object_bytes: :large] do
      opts = [max_bytes: 10] |> Keyword.delete(key) |> Keyword.put(key, value)
      assert_raise ArgumentError, fn -> ODB.cache(opts) end
      assert_raise ArgumentError, fn -> ODB.layer([{:cache, opts}, store]) end
    end
  end

  test "nested cached layers are rejected while pure compositions may nest" do
    assert {:ok, store} = ODB.from_objects([])
    assert {:ok, pure} = ODB.layer([store])
    assert {:ok, _nested_pure} = ODB.layer([pure])

    assert {:ok, cached} = ODB.layer([ODB.cache(max_bytes: 10), store])

    assert {:error, %Error{code: :invalid_argument, message: message}} =
             ODB.layer([cached])

    assert message == "nested cache layers are not supported in 0.x"
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

  test "a cache at index one populates only from following stores", fixture do
    [first_object, second_object | _] = fixture.objects
    assert {:ok, first} = ODB.from_objects([first_object])
    {second, agent} = start_provider(%{second_object.oid => second_object})

    assert {:ok, layered} =
             ODB.layer([first, ODB.cache(max_bytes: 1_000_000), second])

    assert {:ok, ^first_object} = ODB.read(layered, first_object.oid)
    assert {:ok, ^first_object} = ODB.read(layered, first_object.oid)

    assert {:ok, ^second_object} = ODB.read(layered, second_object.oid)
    assert {:ok, ^second_object} = ODB.read(layered, second_object.oid)
    assert Agent.get(agent, & &1.calls) == 1
  end

  test "nonresident and resident cache header policies avoid payload fetches" do
    size = 256 * 1024
    data = :binary.copy(<<0xA5>>, size)
    oid = object_oid(:blob, data)
    object = %Gitility.Object{oid: oid, type: :blob, data: data}
    {provider, agent} = start_provider(%{oid => object})

    assert {:ok, bypass} =
             ODB.layer([
               ODB.cache(max_bytes: 512 * 1024, max_object_bytes: 1024),
               provider
             ])

    for _ <- 1..3 do
      assert {:ok, %ObjectHeader{oid: ^oid, type: :blob, size: ^size}} =
               ODB.header(bypass, oid)
    end

    assert Agent.get(agent, & &1.header_calls) == 3
    assert Agent.get(agent, & &1.calls) == 0

    assert {:ok, resident} =
             ODB.layer([ODB.cache(max_bytes: 512 * 1024), provider])

    assert {:ok, ^object} = ODB.read(resident, oid)
    frozen = Agent.get(agent, &{&1.calls, &1.header_calls})
    assert {:ok, %ObjectHeader{oid: ^oid, size: ^size}} = ODB.header(resident, oid)
    assert Agent.get(agent, &{&1.calls, &1.header_calls}) == frozen
  end

  test "list_tree include size uses provider header batches for blobs", fixture do
    total_bytes = Enum.reduce(fixture.objects, 1, &(&2 + byte_size(&1.data)))
    {provider, agent} = start_provider(fixture.object_map)

    assert {:ok, layered} =
             ODB.layer([
               ODB.cache(max_bytes: total_bytes, max_object_bytes: 1),
               provider
             ])

    assert {:ok, snapshot} = Snapshot.open(layered, fixture.head)
    Agent.update(agent, &%{&1 | call_kinds: [], calls: 0, header_calls: 0})

    assert {:ok, page} =
             Gitility.list_tree(snapshot, "", recursive: true, include: [:size])

    blob_oids =
      page.items
      |> Enum.filter(&(&1.type in [:blob, :symlink]))
      |> Enum.map(& &1.oid)
      |> MapSet.new()

    call_kinds = Agent.get(agent, & &1.call_kinds)

    header_oids =
      call_kinds
      |> Enum.flat_map(fn
        {:header, oids} -> oids
        _other -> []
      end)
      |> MapSet.new()

    payload_oids =
      call_kinds
      |> Enum.flat_map(fn
        {:object, oids} -> oids
        _other -> []
      end)
      |> MapSet.new()

    assert MapSet.subset?(blob_oids, header_oids)
    assert MapSet.disjoint?(blob_oids, payload_oids)
    assert Agent.get(agent, & &1.header_calls) > 0
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

    Enum.each(fixture.objects, fn object ->
      assert {:ok, ^object} = ODB.read(evicting, object.oid)
    end)

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

  test "layer failures are fail-fast, indexed, and short-circuited by earlier hits", fixture do
    object = hd(fixture.objects)
    assert {:ok, static} = ODB.from_objects([object])
    {down, down_agent} = start_provider(%{})
    Agent.update(down_agent, &Map.put(&1, :error, :down))

    assert {:ok, down_first} = ODB.layer([down, static])

    assert {:error, %Error{code: :backend_error, details: %{layer: 0}}} =
             ODB.read(down_first, object.oid)

    Agent.update(down_agent, &%{&1 | calls: 0})
    assert {:ok, down_last} = ODB.layer([static, down])
    assert {:ok, ^object} = ODB.read(down_last, object.oid)
    assert Agent.get(down_agent, & &1.calls) == 0

    missing = OID.new!(:sha1, <<9::160>>)

    assert {:error, %Error{code: :backend_error, details: %{layer: 1}}} =
             ODB.read(down_last, missing)
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

  test "refresh refuses an all-static layered handle" do
    assert {:ok, first} = ODB.from_objects([])
    assert {:ok, second} = ODB.from_objects([])
    assert {:ok, layered} = ODB.layer([first, second])
    assert {:error, %Error{code: :unsupported_operation}} = ODB.refresh(layered)
  end

  test "read_file carries cache stats and reports a second-read hit", fixture do
    total_bytes = Enum.reduce(fixture.objects, 1, &(&2 + byte_size(&1.data)))
    {provider, _agent} = start_provider(fixture.object_map)
    assert {:ok, layered} = ODB.layer([ODB.cache(max_bytes: total_bytes), provider])
    assert {:ok, snapshot} = Snapshot.open(layered, fixture.head)

    assert {:ok, first} = Gitility.read_file(snapshot, "README.md")
    assert %Gitility.Stats{} = first.stats
    assert {:ok, second} = Gitility.read_file(snapshot, "README.md")
    assert second.stats.cache_hits >= 1
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
      assert %{actual | stats: expected.stats} == expected
    end)
  end

  defp start_provider(objects, opts \\ []) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          objects: objects,
          calls: 0,
          header_calls: 0,
          batches: [],
          call_kinds: [],
          refresh_calls: 0
        }
      end)

    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)
    provider_opts = Keyword.put(opts, :backend, {Backend, agent})
    assert {:ok, supervisor} = ODB.start_link(provider_opts)
    assert {:ok, odb} = ODB.handle(supervisor)
    {odb, agent}
  end

  defp object_oid(type, data) do
    OID.new!(:sha1, :crypto.hash(:sha, "#{type} #{byte_size(data)}\0" <> data))
  end
end
