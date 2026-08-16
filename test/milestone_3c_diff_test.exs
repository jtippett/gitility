defmodule Gitility.M3cObjectBackend do
  @behaviour Gitility.ODB.Backend

  alias Gitility.ObjectHeader

  @impl true
  def init({objects, observer, mode}), do: {:ok, {objects, observer, mode}}

  @impl true
  def read_many(oids, {objects, observer, mode}) do
    if mode == :block_blobs and Enum.any?(oids, &blob?(objects, &1)) do
      send(observer, {:m3c_blob_read_blocked, self()})

      receive do
        :release_m3c_blob_read -> :ok
      end
    end

    {:ok, Map.new(oids, &{&1, Map.get(objects, &1, :not_found)})}
  end

  @impl true
  def read_headers(oids, {objects, _observer, mode}) do
    {:ok,
     Map.new(oids, fn oid ->
       case Map.get(objects, oid) do
         nil ->
           {oid, :not_found}

         object ->
           size = if mode == :lying_headers, do: 1, else: byte_size(object.data)
           {oid, %ObjectHeader{oid: oid, type: object.type, size: size}}
       end
     end)}
  end

  defp blob?(objects, oid) do
    match?(%Gitility.Object{type: :blob}, Map.get(objects, oid))
  end
end

defmodule Gitility.Milestone3cDiffTest do
  use ExUnit.Case, async: true

  alias Gitility.{Diff, Error, Job, Limits, ODB, OID, Repository, Runtime, Snapshot}

  @fixtures Path.expand("../fixtures/generated", __DIR__)

  setup do
    runtime =
      start_supervised!(
        Supervisor.child_spec(
          {Runtime, workers: 1},
          id: {Runtime, System.unique_integer([:positive])}
        )
      )

    assert {:ok, repository} =
             Repository.open(fixture("sha1-diff.git"), runtime: runtime)

    assert {:ok, base} =
             Repository.snapshot(repository, {:oid, fixture_oid(:sha1_diff_base)})

    assert {:ok, head} =
             Repository.snapshot(repository, {:oid, fixture_oid(:sha1_diff_head)})

    %{runtime: runtime, repository: repository, base: base, head: head}
  end

  test "summary, stats, patch, and equal-snapshot tiers have their exact shapes", context do
    assert {:ok, %Diff{} = summary} =
             Gitility.diff(context.base, context.head, format: :summary)

    assert summary.files != []
    assert Enum.all?(summary.files, &is_nil(&1.additions))
    assert Enum.all?(summary.files, &(&1.hunks == []))

    assert {:ok, %Diff{} = stats} = Gitility.diff(context.base, context.head, format: :stats)
    assert Enum.any?(stats.files, &is_integer(&1.additions))
    assert Enum.all?(stats.files, &(&1.hunks == []))

    assert {:ok, %Diff{} = patch} = Gitility.diff(context.base, context.head)
    assert Enum.any?(patch.files, &(&1.hunks != []))
    assert patch.stats.files_scanned == length(patch.files)

    assert {:ok, %Diff{files: [], truncated: false}} =
             Gitility.diff(context.head, context.head)
  end

  test "typed options raise and semantic invalids return normalized errors", context do
    for options <- [
          [format: "patch"],
          [pathspecs: [:bad]],
          [context_lines: 1.5],
          [renames: "similarity"],
          [copies: "true"],
          [unknown: true]
        ] do
      assert_raise ArgumentError, fn -> Gitility.diff(context.base, context.head, options) end
    end

    assert {:error, %Error{code: :invalid_argument}} =
             Gitility.diff(context.base, context.head, format: :unknown)

    assert {:error, %Error{code: :invalid_argument}} =
             Gitility.diff(context.base, context.head, renames: true)

    assert {:error, %Error{code: :invalid_argument}} =
             Gitility.diff(context.base, context.head, context_lines: 33)

    assert {:error, %Error{code: :invalid_argument}} =
             Gitility.diff(context.base, context.head, copies: true)

    assert {:error, %Error{code: :invalid_argument}} = Gitility.diff(%{}, context.head)
  end

  test "rename, copy, type-change, mode-only, and gitlink records cross the API", context do
    assert {:ok, diff} =
             Gitility.diff(context.base, context.head,
               format: :summary,
               renames: :similarity,
               copies: true
             )

    assert %Diff.File{status: :renamed, similarity: 100} =
             find_new!(diff, "rename-clean-new.txt")

    assert %Diff.File{status: :renamed, similarity: similarity} =
             find_new!(diff, "rename-edit-new.txt")

    assert similarity in 50..99

    assert %Diff.File{status: :copied} = find_new!(diff, "copy-near.txt")

    assert %Diff.File{status: :type_changed, old_mode: 0o100644, new_mode: 0o120000} =
             find_new!(diff, "type-change")

    assert %Diff.File{
             status: :modified,
             old_oid: oid,
             new_oid: oid,
             old_mode: 0o100644,
             new_mode: 0o100755
           } = find_new!(diff, "mode-only.sh")

    for path <- ["submodule-added", "submodule-bumped"] do
      assert %Diff.File{new_mode: 0o160000, binary: false, hunks: []} = find_new!(diff, path)
    end
  end

  test "binary and oversize pairs suppress content, including a lying header", context do
    assert {:ok, binary} =
             Gitility.diff(context.base, context.head,
               format: :stats,
               pathspecs: ["binary.dat", "text-to-binary.dat"]
             )

    assert Enum.all?(binary.files, fn file ->
             file.binary and is_nil(file.additions) and is_nil(file.deletions) and
               file.hunks == []
           end)

    limits = Limits.new(max_object_bytes: 8)

    assert {:ok, oversize} =
             Gitility.diff(context.base, context.head,
               pathspecs: ["modify.txt"],
               limits: limits
             )

    assert [%Diff.File{binary: false, additions: nil, deletions: nil, hunks: []}] =
             oversize.files

    assert oversize.stats.oversize_skipped == 1
    assert Enum.any?(oversize.warnings, &(&1.code == :oversize_skipped))

    objects = merged_repository_objects(context)

    provider =
      start_supervised!(
        {ODB,
         backend: {Gitility.M3cObjectBackend, {objects, self(), :lying_headers}},
         runtime: context.runtime,
         concurrency: 1}
      )

    assert {:ok, provider_odb} = ODB.handle(provider)
    assert {:ok, base} = Snapshot.open(provider_odb, context.base.commit_oid)
    assert {:ok, head} = Snapshot.open(provider_odb, context.head.commit_oid)

    assert {:ok, lying} =
             Gitility.diff(base, head,
               pathspecs: ["modify.txt"],
               limits: limits
             )

    assert [%Diff.File{additions: nil, deletions: nil, hunks: []}] = lying.files
    assert Enum.any?(lying.warnings, &(&1.code == :oversize_skipped))
  end

  test "each structured diff ceiling truncates work and names stopped_by", context do
    for {limit_name, limits} <- [
          {:max_diff_files, Limits.new(max_diff_files: 1)},
          {:max_diff_hunks, Limits.new(max_diff_hunks: 1)},
          {:max_diff_lines, Limits.new(max_diff_lines: 1)}
        ] do
      assert {:ok, %Diff{truncated: true} = diff} =
               Gitility.diff(context.base, context.head, limits: limits)

      assert diff.stats.stopped_by == limit_name
      assert Enum.any?(diff.warnings, &(&1.code == :truncated))
    end
  end

  test "different static ODBs form a head-first union and validate compatibility", context do
    base_objects = repository_objects(context.repository, context.base)
    head_objects = repository_objects(context.repository, context.head)

    assert {:ok, base_odb} =
             ODB.from_objects(Map.values(base_objects), runtime: context.runtime)

    assert {:ok, head_odb} =
             ODB.from_objects(Map.values(head_objects), runtime: context.runtime)

    assert {:ok, base} = Snapshot.open(base_odb, context.base.commit_oid)
    assert {:ok, head} = Snapshot.open(head_odb, context.head.commit_oid)
    assert {:ok, expected} = Gitility.diff(context.base, context.head)
    assert {:ok, actual} = Gitility.diff(base, head)
    assert actual.files == expected.files

    assert {:ok, sha256_odb} =
             ODB.from_objects([], hash: :sha256, runtime: context.runtime)

    sha256_oid = OID.new!(:sha256, <<0::256>>)
    fake_sha256 = %Snapshot{odb: sha256_odb, commit_oid: sha256_oid, tree_oid: sha256_oid}

    assert {:error, %Error{code: :hash_mismatch}} = Gitility.diff(base, fake_sha256)

    other_runtime =
      start_supervised!(
        Supervisor.child_spec(
          {Runtime, workers: 1},
          id: {Runtime, System.unique_integer([:positive])}
        )
      )

    assert {:ok, other_odb} = ODB.from_objects(Map.values(head_objects), runtime: other_runtime)
    assert {:ok, other_head} = Snapshot.open(other_odb, context.head.commit_oid)
    assert {:error, %Error{code: :runtime_mismatch}} = Gitility.diff(base, other_head)
  end

  test "raw Latin-1 path and content survive through structured hunks", context do
    path = <<"latin-", 0xE9, "-path.txt">>
    assert {:ok, diff} = Gitility.diff(context.base, context.head, pathspecs: [path])
    assert [%Diff.File{old_path: ^path, new_path: ^path, hunks: hunks}] = diff.files

    assert Enum.any?(hunks, fn hunk ->
             Enum.any?(hunk.lines, &(:binary.match(&1.content, <<0xE9>>) != :nomatch))
           end)
  end

  test "a provider blocked on the first blob read makes cancellation deterministic", context do
    objects = merged_repository_objects(context)

    provider =
      start_supervised!(
        {ODB,
         backend: {Gitility.M3cObjectBackend, {objects, self(), :block_blobs}},
         runtime: context.runtime,
         concurrency: 1,
         request_timeout: 5_000}
      )

    assert {:ok, provider_odb} = ODB.handle(provider)
    assert {:ok, base} = Snapshot.open(provider_odb, context.base.commit_oid)
    assert {:ok, head} = Snapshot.open(provider_odb, context.head.commit_oid)

    task =
      Task.async(fn ->
        Gitility.diff(base, head, limits: Limits.new(timeout_ms: 50))
      end)

    assert_receive {:m3c_blob_read_blocked, callback}, 1_000
    assert {:error, %Error{code: :timeout}} = Task.await(task, 1_000)
    send(callback, :release_m3c_blob_read)
  end

  test "async_diff mirrors the synchronous result", context do
    assert {:ok, %Job{} = job} =
             Gitility.async_diff(context.base, context.head,
               format: :stats,
               pathspecs: ["dir/sub/**"]
             )

    assert {:ok, async_result} = Job.await(job, 1_000)

    assert {:ok, sync_result} =
             Gitility.diff(context.base, context.head,
               format: :stats,
               pathspecs: ["dir/sub/**"]
             )

    assert async_result.files == sync_result.files
  end

  defp merged_repository_objects(context) do
    context.repository
    |> repository_objects(context.base)
    |> Map.merge(repository_objects(context.repository, context.head))
  end

  defp repository_objects(repository, snapshot) do
    assert {:ok, tree_page} =
             Gitility.list_tree(snapshot, "",
               recursive: true,
               types: [:blob, :tree, :symlink, :gitlink],
               limit: 10_000
             )

    oids =
      [snapshot.commit_oid, snapshot.tree_oid | Enum.map(tree_page.items, & &1.oid)]
      |> Enum.uniq()

    assert {:ok, values} = ODB.read_many(repository.odb, oids)
    Map.reject(values, fn {_oid, value} -> value == :not_found end)
  end

  defp find_new!(diff, path), do: Enum.find(diff.files, &(&1.new_path == path))

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
