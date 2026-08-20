defmodule Gitility.M3aBlockingBackend do
  @behaviour Gitility.ODB.Backend

  @impl true
  def init({objects, observer}), do: {:ok, {objects, observer}}

  @impl true
  def read_many(oids, {objects, observer}) do
    send(observer, {:m3a_provider_read_blocked, self()})

    receive do
      :release_m3a_provider_read ->
        {:ok, Map.new(oids, &{&1, Map.get(objects, &1, :not_found)})}
    end
  end
end

defmodule Gitility.Milestone3aCommitGraphTest do
  use ExUnit.Case, async: true

  alias Gitility.{Commit, Error, Limits, Object, ODB, OID, Repository, Runtime, Snapshot}

  @fixtures Path.expand("../fixtures/generated", __DIR__)

  setup do
    child_id = {Runtime, System.unique_integer([:positive])}

    runtime =
      start_supervised!(Supervisor.child_spec({Runtime, workers: 1}, id: child_id))

    {:ok, repository} = Repository.open(fixture("sha1-graph.git"), runtime: runtime)
    head = fixture_oid(:sha1_graph_head)
    {:ok, snapshot} = Snapshot.open(repository.odb, head)
    %{runtime: runtime, repository: repository, snapshot: snapshot}
  end

  test "every log order, parent mode, and time-bound shape has a happy path", %{
    snapshot: snapshot
  } do
    datetime_since = DateTime.from_unix!(988_761_700)

    for order <- [:chronological, :topological, :date],
        first_parent <- [false, true],
        {since, until} <- [
          {nil, nil},
          {988_761_700, nil},
          {nil, 988_761_760},
          {datetime_since, 988_761_760}
        ] do
      assert {:ok, page} =
               Gitility.log(snapshot,
                 order: order,
                 first_parent: first_parent,
                 since: since,
                 until: until
               )

      assert Enum.all?(page.items, &match?(%Commit{}, &1))
      refute page.truncated
    end
  end

  test "commit DTO preserves raw fields and explicit caps", %{snapshot: snapshot} do
    assert {:ok, page} = Gitility.log(snapshot, limit: 1)
    assert [%Commit{} = commit] = page.items
    assert %OID{} = commit.oid
    assert %OID{} = commit.tree_oid
    assert Enum.all?(commit.parents, &match?(%OID{}, &1))
    assert is_binary(commit.author.name)
    assert is_binary(commit.author.email)
    assert is_integer(commit.author.time)
    assert is_binary(commit.author.tz)
    assert is_integer(commit.author.tz_offset_minutes)
    assert is_binary(commit.subject) and byte_size(commit.subject) <= 1_024
    assert is_boolean(commit.subject_truncated)
    assert is_binary(commit.message_raw) and byte_size(commit.message_raw) <= 64 * 1_024
    assert is_boolean(commit.message_truncated)
    assert Enum.all?(commit.signature_headers, &is_binary/1)
    assert is_nil(commit.encoding) or is_binary(commit.encoding)
  end

  test "cursor round-trip has no gaps and every normalized option is bound", %{
    snapshot: snapshot
  } do
    opts = [order: :date, first_parent: false, since: 988_675_200, until: nil, limit: 7]
    assert {:ok, first} = Gitility.log(snapshot, opts)
    assert first.truncated
    assert is_binary(first.next_cursor)
    assert {:ok, second} = Gitility.log(snapshot, Keyword.put(opts, :cursor, first.next_cursor))

    first_ids = Enum.map(first.items, & &1.oid)
    second_ids = Enum.map(second.items, & &1.oid)
    assert MapSet.disjoint?(MapSet.new(first_ids), MapSet.new(second_ids))
    assert {:ok, complete} = Gitility.log(snapshot, Keyword.put(opts, :limit, 1_000))
    assert paged_ids(snapshot, opts) == Enum.map(complete.items, & &1.oid)

    for changed <- [
          Keyword.put(opts, :order, :topological),
          Keyword.put(opts, :first_parent, true),
          Keyword.put(opts, :since, 988_675_201),
          Keyword.put(opts, :until, 988_761_800)
        ] do
      assert {:error, %Error{code: :invalid_cursor}} =
               Gitility.log(snapshot, Keyword.put(changed, :cursor, first.next_cursor))
    end

    raw = Base.url_decode64!(first.next_cursor, padding: false)
    <<first_byte, rest::binary>> = raw
    corrupt = Base.url_encode64(<<Bitwise.bxor(first_byte, 1), rest::binary>>, padding: false)
    assert {:error, %Error{code: :invalid_cursor}} = Gitility.log(snapshot, cursor: corrupt)
  end

  test "caller, max_results, and max_objects truncation return resumable warnings", %{
    snapshot: snapshot
  } do
    assert {:ok, caller_page} = Gitility.log(snapshot, limit: 5)
    assert length(caller_page.items) == 5
    assert caller_page.truncated
    assert caller_page.stats.stopped_by == :limit
    assert caller_page.warnings == [%{code: :truncated, message: "page truncated by limit"}]

    result_limits = Limits.new(max_results: 4)
    assert {:ok, result_page} = Gitility.log(snapshot, limit: 100, limits: result_limits)
    assert length(result_page.items) == 4
    assert result_page.truncated
    assert result_page.stats.stopped_by == :max_results

    object_limits = Limits.new(max_objects: 30)
    assert {:ok, object_page} = Gitility.log(snapshot, limit: 1_000, limits: object_limits)
    assert object_page.items != []
    assert object_page.truncated
    assert object_page.stats.stopped_by == :max_objects
    assert is_binary(object_page.next_cursor)

    assert object_page.warnings == [
             %{code: :truncated, message: "page truncated by max_objects"}
           ]
  end

  test "merge_base and ancestor? expose deterministic shapes through ODB and snapshot", %{
    repository: repository,
    snapshot: snapshot
  } do
    left = fixture_oid(:sha1_graph_criss_left)
    right = fixture_oid(:sha1_graph_criss_right)
    base_left = fixture_oid(:sha1_graph_criss_base_left)
    base_right = fixture_oid(:sha1_graph_criss_base_right)
    expected_all = Enum.sort([base_left, base_right], :desc)

    assert {:ok, ^expected_all} =
             Gitility.merge_base(repository.odb, left, OID.to_string(right), all: true)

    assert {:ok, first} = Gitility.merge_base(snapshot, OID.to_string(left), right)
    assert first == hd(expected_all)

    disjoint = fixture_oid(:sha1_graph_disjoint)
    assert {:ok, nil} = Gitility.merge_base(repository.odb, snapshot.commit_oid, disjoint)
    assert {:ok, []} = Gitility.merge_base(snapshot, snapshot.commit_oid, disjoint, all: true)
    assert {:ok, ^left} = Gitility.merge_base(repository.odb, left, left)

    octopus = fixture_oid(:sha1_graph_octopus)
    assert {:ok, true} = Gitility.ancestor?(snapshot, octopus, snapshot.commit_oid)
    assert {:ok, true} = Gitility.ancestor?(repository.odb, left, left)
    assert {:ok, false} = Gitility.ancestor?(repository.odb, disjoint, snapshot.commit_oid)
  end

  test "hole-punched static ODB reports the missing parent OID", %{runtime: runtime} do
    tree = OID.parse!("4b825dc642cb6eb9a060e54bf8d69288fbee4904")
    missing = OID.new!(:sha1, <<9::160>>)

    payload =
      "tree #{OID.to_string(tree)}\n" <>
        "parent #{OID.to_string(missing)}\n" <>
        "author A <a@example.invalid> 1 +0000\n" <>
        "committer C <c@example.invalid> 2 +0000\n\nchild\n"

    child = object_oid(:commit, payload)

    assert {:ok, odb} =
             ODB.from_objects(
               [%Object{oid: child, type: :commit, data: payload}],
               runtime: runtime
             )

    snapshot = %Snapshot{odb: odb, commit_oid: child, tree_oid: tree}

    assert {:error, %Error{code: :missing_object, details: %{oid: ^missing}}} =
             Gitility.log(snapshot)
  end

  test "a blocked provider makes cancellation timeout deterministic", %{
    repository: repository,
    runtime: runtime,
    snapshot: snapshot
  } do
    assert {:ok, complete} = Gitility.log(snapshot)
    commit_oids = Enum.map(complete.items, & &1.oid)
    assert {:ok, values} = ODB.read_many(repository.odb, commit_oids)
    objects = Map.reject(values, fn {_oid, value} -> value == :not_found end)

    provider =
      start_supervised!(
        {ODB,
         backend: {Gitility.M3aBlockingBackend, {objects, self()}},
         runtime: runtime,
         concurrency: 1,
         request_timeout: 5_000}
      )

    assert {:ok, provider_odb} = ODB.handle(provider)
    blocked_snapshot = %{snapshot | odb: provider_odb}

    task =
      Task.async(fn ->
        Gitility.log(blocked_snapshot, limits: Limits.new(timeout_ms: 50))
      end)

    assert_receive {:m3a_provider_read_blocked, callback}, 1_000
    assert {:error, %Error{code: :timeout}} = Task.await(task, 1_000)
    send(callback, :release_m3a_provider_read)
  end

  test "log, merge-base, and ancestor validate options and graph-store scope", %{
    repository: repository,
    snapshot: snapshot
  } do
    assert_raise ArgumentError, fn -> Gitility.log(snapshot, unknown: true) end

    assert_raise ArgumentError, ~r/:first_parent.*boolean/, fn ->
      Gitility.log(snapshot, first_parent: :yes)
    end

    assert {:error, %Error{code: :invalid_argument}} = Gitility.log(snapshot, order: :time)
    assert {:error, %Error{code: :invalid_argument}} = Gitility.log(repository)
    assert_raise ArgumentError, ~r/:since/, fn -> Gitility.log(snapshot, since: "yesterday") end

    left = fixture_oid(:sha1_graph_criss_left)
    right = fixture_oid(:sha1_graph_criss_right)

    assert_raise ArgumentError, fn ->
      Gitility.merge_base(snapshot, left, right, unknown: true)
    end

    assert_raise ArgumentError, ~r/:all.*boolean/, fn ->
      Gitility.merge_base(snapshot, left, right, all: :yes)
    end

    assert {:error, %Error{code: :invalid_argument}} =
             Gitility.merge_base(repository, left, right)
  end

  defp object_oid(type, data) do
    header = "#{type} #{byte_size(data)}\0"
    OID.new!(:sha1, :crypto.hash(:sha, header <> data))
  end

  defp fixture(name), do: Path.join(@fixtures, name)

  defp paged_ids(snapshot, opts, cursor \\ nil, accumulated \\ []) do
    assert {:ok, page} = Gitility.log(snapshot, Keyword.put(opts, :cursor, cursor))
    accumulated = accumulated ++ Enum.map(page.items, & &1.oid)

    if page.next_cursor do
      paged_ids(snapshot, opts, page.next_cursor, accumulated)
    else
      accumulated
    end
  end

  defp fixture_oid(name) do
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
