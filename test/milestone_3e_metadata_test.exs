defmodule Gitility.M3eBlockingBackend do
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
      send(observer, {:m3e_gitmodules_read_blocked, self()})

      receive do
        :release_m3e_gitmodules_read -> :ok
      end
    end

    {:ok, Map.new(oids, &{&1, Map.get(objects, &1, :not_found)})}
  end
end

defmodule Gitility.Milestone3eMetadataTest do
  use ExUnit.Case, async: true

  alias Gitility.{Error, Job, Limits, ODB, OID, Repository, Runtime, Submodule}

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
             Repository.open(fixture("sha1-submodules.git"), runtime: runtime)

    assert {:ok, snapshot} =
             Repository.snapshot(repository, {:oid, fixture_oid(:sha1_submodules_head)})

    %{runtime: runtime, repository: repository, snapshot: snapshot}
  end

  test "submodules converts every field and all statuses in raw-path order", context do
    assert {:ok, submodules} = Gitility.submodules(context.snapshot)

    assert Enum.map(submodules, & &1.path) == [
             "different",
             "normal",
             "orphaned",
             "sub/dir/mod",
             "undeclared",
             "with-url"
           ]

    assert %Submodule{
             name: "remote",
             path: "with-url",
             url: <<"ssh://example.invalid/repo", ?\\, "path.git">>,
             branch: "release/v1",
             commit_oid: %OID{} = remote_oid,
             status: :active
           } = find!(submodules, "with-url")

    assert OID.to_string(remote_oid) == gitlink_oid(3)

    assert %Submodule{
             name: "orphaned",
             path: "orphaned",
             url: "https://example.invalid/orphaned.git",
             branch: nil,
             commit_oid: nil,
             status: :orphaned
           } = find!(submodules, "orphaned")

    assert %Submodule{
             name: nil,
             path: "undeclared",
             url: nil,
             branch: nil,
             commit_oid: %OID{} = undeclared_oid,
             status: :undeclared
           } = find!(submodules, "undeclared")

    assert OID.to_string(undeclared_oid) == gitlink_oid(5)

    assert %Submodule{
             name: "Nested Name",
             path: "sub/dir/mod",
             commit_oid: %OID{} = nested_oid,
             status: :active
           } = find!(submodules, "sub/dir/mod")

    assert OID.to_string(nested_oid) == gitlink_oid(4)
  end

  test "subsection name is independent from the declared path", context do
    assert {:ok, submodules} = Gitility.submodules(context.snapshot)

    assert %Submodule{
             name: "Different Name",
             path: "different",
             url: "../relative path.git",
             branch: nil,
             commit_oid: %OID{} = commit_oid,
             status: :active
           } = find!(submodules, "different")

    assert OID.to_string(commit_oid) == gitlink_oid(2)
  end

  test "a snapshot with neither metadata nor gitlinks returns an empty list", context do
    assert {:ok, repository} =
             Repository.open(fixture("sha1-nested.git"), runtime: context.runtime)

    assert {:ok, snapshot} =
             Repository.snapshot(repository, {:oid, fixture_oid(:sha1_nested_head)})

    assert {:ok, []} = Gitility.submodules(snapshot)
  end

  test "malformed and oversize gitmodules errors retain M1c details", context do
    assert {:ok, malformed} =
             Repository.snapshot(
               context.repository,
               {:oid, fixture_oid(:sha1_submodules_malformed)}
             )

    assert {:error,
            %Error{
              code: :malformed_object,
              operation: :submodules,
              details: %{file: ".gitmodules", reason: "git_config_parse_error", line: 1}
            }} = Gitility.submodules(malformed)

    assert {:error,
            %Error{
              code: :object_too_large,
              operation: :submodules,
              details: %{file: ".gitmodules", limit: :max_object_bytes}
            }} =
             Gitility.submodules(context.snapshot,
               limits: Limits.new(max_object_bytes: 512)
             )
  end

  test "LFS recognition crosses the full file conversion path", context do
    assert {:ok, valid} = Gitility.read_file(context.snapshot, "lfs/valid.bin")

    assert valid.lfs_pointer == %{
             oid: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
             size: 12_345
           }

    for path <- [
          "lfs/not-a-pointer.bin",
          "lfs/almost-pointer.bin",
          "lfs/over-1024.bin"
        ] do
      assert {:ok, file} = Gitility.read_file(context.snapshot, path)
      assert file.lfs_pointer == nil
    end
  end

  test "budgets and explicit cancellation stop submodule metadata work", context do
    assert {:error, %Error{code: :budget_exceeded, details: %{limit: :max_objects}}} =
             Gitility.submodules(context.snapshot, limits: Limits.new(max_objects: 1))

    objects = repository_objects(context.repository, fixture_oid(:sha1_submodules_head))

    provider =
      start_supervised!(
        {ODB,
         backend: {Gitility.M3eBlockingBackend, {objects, self()}},
         runtime: context.runtime,
         concurrency: 1,
         request_timeout: 5_000}
      )

    assert {:ok, provider_odb} = ODB.handle(provider)
    blocked_snapshot = %{context.snapshot | odb: provider_odb}
    assert {:ok, %Job{} = job} = Gitility.async_submodules(blocked_snapshot)
    assert_receive {:m3e_gitmodules_read_blocked, callback}, 1_000
    assert :ok = Job.cancel(job)
    send(callback, :release_m3e_gitmodules_read)
    assert {:error, %Error{code: :cancelled}} = Job.await(job, 1_000)
  end

  test "async_submodules mirrors the synchronous list", context do
    assert {:ok, expected} = Gitility.submodules(context.snapshot)
    assert {:ok, %Job{} = job} = Gitility.async_submodules(context.snapshot)
    assert {:ok, actual} = Job.await(job, 1_000)
    assert actual == expected
  end

  test "only limits and detach are accepted options", context do
    assert {:error, %Error{code: :invalid_argument, operation: :submodules}} =
             Gitility.submodules(%{})

    assert_raise ArgumentError, fn -> Gitility.submodules(context.snapshot, limit: 1) end
    assert_raise ArgumentError, fn -> Gitility.async_submodules(context.snapshot, limit: 1) end
  end

  defp repository_objects(repository, head) do
    {output, 0} =
      System.cmd("git", ["-C", fixture("sha1-submodules.git"), "rev-list", "--objects", head])

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

  defp find!(submodules, path), do: Enum.find(submodules, &(&1.path == path))

  defp gitlink_oid(number) do
    number
    |> Integer.to_string()
    |> String.pad_leading(40, "0")
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
