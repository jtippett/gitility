defmodule Gitility.M3dBlockingBackend do
  @behaviour Gitility.ODB.Backend

  @impl true
  def init({objects, observer}), do: {:ok, {objects, observer}}

  @impl true
  def read_many(oids, {objects, observer}) do
    blob_read? =
      Enum.any?(oids, fn oid ->
        match?(%Gitility.Object{type: :blob}, Map.get(objects, oid))
      end)

    if blob_read? do
      send(observer, {:m3d_blob_read_blocked, self()})

      receive do
        :release_m3d_blob_read -> :ok
      end
    end

    {:ok, Map.new(oids, &{&1, Map.get(objects, &1, :not_found)})}
  end
end

defmodule Gitility.Milestone3dBlameHistoryTest do
  use ExUnit.Case, async: true

  alias Gitility.{Blame, Commit, Error, Job, Limits, ODB, OID, Page, Repository, Runtime}

  @fixtures Path.expand("../fixtures/generated", __DIR__)

  setup do
    runtime =
      start_supervised!(
        Supervisor.child_spec(
          {Runtime, workers: 1},
          id: {Runtime, System.unique_integer([:positive])}
        )
      )

    assert {:ok, repository} = Repository.open(fixture("sha1-blame.git"), runtime: runtime)

    assert {:ok, snapshot} =
             Repository.snapshot(repository, {:oid, fixture_oid(:sha1_blame_head)})

    %{runtime: runtime, repository: repository, snapshot: snapshot}
  end

  test "blame converts every result and hunk field through the full Elixir path", context do
    assert {:ok,
            %Blame{
              path: "docs/final.txt",
              hunks: hunks,
              stats: %Gitility.Stats{} = stats,
              warnings: []
            }} = Gitility.blame(context.snapshot, "docs/final.txt")

    assert hunks != []
    assert stats.entries_emitted == length(hunks)

    assert %Blame.Hunk{
             final_range: %Range{first: 7, last: 7, step: 1},
             original_range: %Range{first: 7, last: 7, step: 1},
             commit_oid: %OID{} = commit_oid,
             original_path: "docs/final.txt",
             author: %Gitility.Identity{
               name: <<"B", 0xE9, "b Bytes">>,
               email: "bob@gitility.invalid",
               time: 996_624_600,
               tz: "+0000",
               tz_offset_minutes: 0
             },
             committer: %Gitility.Identity{
               name: <<"B", 0xE9, "b Bytes">>,
               email: "bob@gitility.invalid",
               time: 996_624_600,
               tz: "+0000",
               tz_offset_minutes: 0
             },
             summary: "Add Latin-1 without a trailing newline",
             boundary: false
           } = Enum.find(hunks, &(&1.final_range == 7..7))

    assert OID.to_string(commit_oid) == fixture_oid(:sha1_blame_final)
  end

  test "contiguous same-commit lines coalesce and exact range boundaries work", context do
    assert {:ok, root} =
             Repository.snapshot(context.repository, {:oid, fixture_oid(:sha1_blame_root)})

    assert {:ok,
            %Blame{
              hunks: [
                %Blame.Hunk{
                  final_range: %Range{first: 1, last: 5, step: 1},
                  boundary: true
                }
              ]
            }} =
             Gitility.blame(root, "docs/legacy.txt")

    assert {:ok, %Blame{hunks: [%Blame.Hunk{final_range: %Range{first: 1, last: 1, step: 1}}]}} =
             Gitility.blame(root, "docs/legacy.txt", lines: 1..1)

    assert {:ok, %Blame{hunks: [%Blame.Hunk{final_range: %Range{first: 5, last: 5, step: 1}}]}} =
             Gitility.blame(root, "docs/legacy.txt", lines: {5, 5})

    assert {:ok, %Blame{hunks: [%Blame.Hunk{final_range: %Range{first: 2, last: 4, step: 1}}]}} =
             Gitility.blame(root, "docs/legacy.txt", lines: 4..2//-1)
  end

  test "out-of-range, missing, tree, budget, and option errors keep conventions", context do
    assert {:error, %Error{code: :invalid_argument, details: %{line_count: 7}}} =
             Gitility.blame(context.snapshot, "docs/final.txt", lines: 1..8)

    assert {:error, %Error{code: :invalid_argument}} =
             Gitility.blame(context.snapshot, "docs/final.txt", lines: 1..7//2)

    assert {:error, %Error{code: :invalid_path}} =
             Gitility.blame(context.snapshot, "docs/missing.txt")

    assert {:error, %Error{code: :invalid_argument, details: %{reason: "path_kind:tree"}}} =
             Gitility.blame(context.snapshot, "docs")

    assert {:error, %Error{code: :object_too_large, details: %{limit: :max_object_bytes}}} =
             Gitility.blame(context.snapshot, "docs/final.txt",
               limits: Limits.new(max_object_bytes: 80)
             )

    assert {:error, %Error{code: :budget_exceeded}} =
             Gitility.blame(context.snapshot, "docs/final.txt",
               limits: Limits.new(max_objects: 2)
             )

    assert {:error, %Error{code: :invalid_argument}} = Gitility.blame(%{}, "docs/final.txt")
    assert_raise ArgumentError, fn -> Gitility.blame(context.snapshot, :path) end

    assert_raise ArgumentError, fn ->
      Gitility.blame(context.snapshot, "docs/final.txt", lines: "1,2")
    end

    assert_raise ArgumentError, fn ->
      Gitility.blame(context.snapshot, "docs/final.txt", first_parent: true)
    end
  end

  test "rename following changes original paths and shallow roots are boundary hunks", context do
    assert {:ok, followed} = Gitility.blame(context.snapshot, "docs/final.txt")

    assert Enum.any?(followed.hunks, fn hunk ->
             hunk.original_path in ["docs/legacy.txt", "docs/story.txt"]
           end)

    assert {:ok, unfollowed} =
             Gitility.blame(context.snapshot, "docs/final.txt", follow_renames: false)

    assert Enum.all?(unfollowed.hunks, &(&1.original_path == "docs/final.txt"))

    assert {:ok, shallow_repository} =
             Repository.open(fixture("sha1-history-shallow.git"), runtime: context.runtime)

    assert {:ok, shallow} =
             Repository.snapshot(shallow_repository, {:oid, fixture_oid(:sha1_history_head)})

    assert {:ok, blame} = Gitility.blame(shallow, "src/tale.txt")
    assert Enum.any?(blame.hunks, & &1.boundary)
  end

  test "history paginates, binds fingerprints, and re-targets before both renames", context do
    {items, pages} = collect_history(context.snapshot, "docs/final.txt", nil, [], 0)
    assert pages >= 3
    assert Enum.all?(items, &match?(%Commit{}, &1))

    ids = MapSet.new(items, &OID.to_string(&1.id))
    assert fixture_oid(:sha1_blame_root) in ids
    assert fixture_oid(:sha1_blame_rewrite) in ids
    assert fixture_oid(:sha1_blame_rename) in ids

    assert %Commit{
             id: %OID{} = root_id,
             parents: [],
             tree_id: %OID{},
             author: %Gitility.Identity{
               name: "Alice Attribution",
               email: "alice@gitility.invalid",
               time: 996_624_000,
               tz: "+0000",
               tz_offset_minutes: 0
             },
             committer: %Gitility.Identity{
               name: "Alice Attribution",
               email: "alice@gitility.invalid",
               time: 996_624_000,
               tz: "+0000",
               tz_offset_minutes: 0
             },
             subject: "Blame root with CRLF lines",
             subject_truncated: false,
             message_raw: "Blame root with CRLF lines\n",
             message_truncated: false,
             signature_headers: [],
             encoding: nil
           } = Enum.find(items, &(OID.to_string(&1.id) == fixture_oid(:sha1_blame_root)))

    assert OID.to_string(root_id) == fixture_oid(:sha1_blame_root)

    assert {:ok, first} = Gitility.history(context.snapshot, "docs/final.txt", limit: 2)
    assert first.truncated
    assert is_binary(first.next_cursor)

    assert {:error, %Error{code: :invalid_cursor}} =
             Gitility.history(context.snapshot, "independent.txt",
               limit: 2,
               cursor: first.next_cursor
             )

    assert {:error, %Error{code: :invalid_cursor}} =
             Gitility.history(context.snapshot, "docs/final.txt",
               follow_renames: false,
               limit: 2,
               cursor: first.next_cursor
             )

    assert_raise ArgumentError, fn ->
      Gitility.history(context.snapshot, "docs/final.txt", first_parent: true)
    end

    for path <- ["*.txt", ":(glob)docs/**"] do
      assert {:error,
              %Error{
                code: :invalid_argument,
                details: %{reason: "pathspec_not_literal"}
              }} = Gitility.history(context.snapshot, path)
    end
  end

  test "async blame and history mirror synchronous results", context do
    assert {:ok, %Job{} = blame_job} =
             Gitility.async_blame(context.snapshot, "docs/final.txt", lines: 2..4)

    assert {:ok, %Blame{} = async_blame} = Job.await(blame_job, 1_000)
    assert {:ok, sync_blame} = Gitility.blame(context.snapshot, "docs/final.txt", lines: 2..4)
    assert async_blame.path == sync_blame.path
    assert async_blame.hunks == sync_blame.hunks
    assert async_blame.warnings == sync_blame.warnings

    assert {:ok, %Job{} = history_job} =
             Gitility.async_history(context.snapshot, "docs/final.txt", limit: 2)

    assert {:ok, %Page{} = async_page} = Job.await(history_job, 1_000)
    assert {:ok, sync_page} = Gitility.history(context.snapshot, "docs/final.txt", limit: 2)
    assert async_page.items == sync_page.items
    assert async_page.next_cursor == sync_page.next_cursor
    assert async_page.truncated == sync_page.truncated
  end

  test "the mandatory HEAD-blob read blocks long enough for deterministic blame cancellation",
       context do
    objects = repository_objects(context.repository, fixture_oid(:sha1_blame_head))

    provider =
      start_supervised!(
        {ODB,
         backend: {Gitility.M3dBlockingBackend, {objects, self()}},
         runtime: context.runtime,
         concurrency: 1,
         request_timeout: 5_000}
      )

    assert {:ok, provider_odb} = ODB.handle(provider)
    blocked_snapshot = %{context.snapshot | odb: provider_odb}

    task =
      Task.async(fn ->
        Gitility.blame(blocked_snapshot, "docs/final.txt", limits: Limits.new(timeout_ms: 50))
      end)

    assert_receive {:m3d_blob_read_blocked, callback}, 1_000
    assert {:error, %Error{code: :timeout}} = Task.await(task, 1_000)
    send(callback, :release_m3d_blob_read)
  end

  defp collect_history(snapshot, path, cursor, accumulated, pages) do
    assert {:ok, page} = Gitility.history(snapshot, path, limit: 3, cursor: cursor)
    accumulated = accumulated ++ page.items

    case page.next_cursor do
      nil -> {accumulated, pages + 1}
      next -> collect_history(snapshot, path, next, accumulated, pages + 1)
    end
  end

  defp repository_objects(repository, head) do
    {output, 0} =
      System.cmd("git", ["-C", fixture("sha1-blame.git"), "rev-list", "--objects", head])

    oids =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        line |> String.split(" ", parts: 2) |> hd() |> OID.parse!()
      end)
      |> Enum.uniq()

    assert {:ok, values} = ODB.read_many(repository.odb, oids)
    Map.reject(values, fn {_oid, value} -> value == :not_found end)
  end

  defp fixture_oid(name) do
    @fixtures
    |> Path.join("OIDS")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> if key == Atom.to_string(name), do: value
        _ -> nil
      end
    end) || raise "missing OIDS key #{name}"
  end

  defp fixture(name), do: Path.join(@fixtures, name)
end
