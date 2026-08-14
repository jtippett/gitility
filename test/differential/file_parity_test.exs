defmodule Gitility.Differential.FileParityTest do
  use ExUnit.Case, async: true

  alias Gitility.{ODB, Repository}
  alias Gitility.Differential.{Allowlist, Oracle}

  @moduletag :gitility_engine

  @fixtures Path.expand("../../fixtures/generated", __DIR__)
  @whole_file_limit 1_000_000
  @repositories [
    {"sha1-basic.git", "main"},
    {"sha1-history.git", "main"},
    {"sha1-nested.git", "main"},
    {"lfs-pointer.git", "main"},
    {"sha1-basic-packed.git", "main"},
    {"sha1-basic-mixed.git", "main"},
    {"sha1-history-midx.git", "main"},
    {"sha1-alternate.git", "main"},
    {"sha1-history-replace.git", "main"},
    {"sha1-history-shallow.git", "main"}
  ]

  setup_all do
    blob_cases =
      discover_blob_cases()
      |> Enum.map(fn blob_case ->
        assert {:ok, oracle_object} =
                 Oracle.cat_file(fixture(blob_case.repository_name), blob_case.oid)

        Map.put(blob_case, :oracle_object, oracle_object)
      end)

    # The original sha1-basic + LFS corpus alone is known to yield 15 blob cases.
    assert length(blob_cases) >= 10

    {:ok, cases: blob_cases}
  end

  test "read_file matches canonical HEAD blob bytes across every supported layout",
       %{cases: cases} do
    snapshots = open_snapshots(cases)

    for blob_case <- cases do
      snapshot = Map.fetch!(snapshots, {blob_case.repository_name, blob_case.revision})

      assert {:ok, file} =
               Gitility.read_file(snapshot, blob_case.path, max_bytes: @whole_file_limit)

      compare(
        "file/#{blob_case.repository_name}/#{path_id(blob_case.path)}/read-file",
        :read_file,
        blob_case,
        blob_case.oracle_object.content,
        file.data
      )
    end
  end

  test "ODB read and header match canonical blob data, kind, and size", %{cases: cases} do
    repositories = open_repositories(cases)

    for blob_case <- cases do
      repository = Map.fetch!(repositories, blob_case.repository_name)

      assert {:ok, object} = ODB.read(repository.odb, blob_case.oid)

      compare(
        "file/#{blob_case.repository_name}/#{path_id(blob_case.path)}/odb-read",
        :odb_read,
        blob_case,
        blob_case.oracle_object.content,
        object.data
      )

      assert {:ok, header} = ODB.header(repository.odb, blob_case.oid)

      compare(
        "file/#{blob_case.repository_name}/#{path_id(blob_case.path)}/odb-header",
        :odb_header,
        blob_case,
        %{type: oracle_type(blob_case.oracle_object.type), size: blob_case.oracle_object.size},
        %{type: header.type, size: header.size}
      )
    end
  end

  test "line slices equal byte slices computed from canonical payloads", %{cases: cases} do
    snapshots = open_snapshots(cases)

    for {path, range} <- [{"README.md", 1..2}, {"src/story.txt", 2..3}] do
      blob_case =
        Enum.find(cases, &(&1.repository_name == "sha1-basic.git" and &1.path == path)) ||
          flunk("oracle listing did not contain #{inspect(path)}")

      snapshot = Map.fetch!(snapshots, {blob_case.repository_name, blob_case.revision})
      assert {:ok, file} = Gitility.read_file(snapshot, path, lines: range)

      expected = oracle_line_slice(blob_case.oracle_object.content, range)

      compare(
        "file/#{blob_case.repository_name}/#{path_id(path)}/lines-#{range.first}-#{range.last}",
        :read_file_lines,
        Map.put(blob_case, :lines, {range.first, range.last}),
        expected,
        file.data
      )
    end
  end

  defp discover_blob_cases do
    Enum.flat_map(@repositories, fn {repository_name, revision} ->
      discover_repository_blobs(repository_name, revision)
    end)
  end

  defp discover_repository_blobs(repository_name, revision) do
    repository_path = fixture(repository_name)
    assert {:ok, [commit | _]} = Oracle.rev_list(repository_path, [revision])
    assert {:ok, entries} = Oracle.ls_tree(repository_path, commit)

    blob_cases =
      entries
      |> Enum.filter(&(&1.type == "blob"))
      |> Enum.map(fn entry ->
        %{
          repository_name: repository_name,
          revision: commit,
          path: entry.path,
          oid: entry.oid
        }
      end)

    assert blob_cases != [], "#{repository_name} must retain discoverable HEAD blobs"
    blob_cases
  end

  defp open_repositories(cases) do
    cases
    |> Enum.map(& &1.repository_name)
    |> Enum.uniq()
    |> Map.new(fn repository_name ->
      assert {:ok, repository} = Repository.open(fixture(repository_name))
      {repository_name, repository}
    end)
  end

  defp open_snapshots(cases) do
    repositories = open_repositories(cases)

    cases
    |> Enum.map(&{&1.repository_name, &1.revision})
    |> Enum.uniq()
    |> Map.new(fn {repository_name, revision} = key ->
      repository = Map.fetch!(repositories, repository_name)
      assert {:ok, snapshot} = Repository.snapshot(repository, {:oid, revision})
      {key, snapshot}
    end)
  end

  defp oracle_line_slice(content, %Range{first: first, last: last}) do
    fields = :binary.split(content, <<"\n">>, [:global])
    last_index = length(fields) - 1

    fields
    |> Enum.with_index()
    |> Enum.map(fn {field, index} ->
      if index < last_index, do: [field, <<"\n">>], else: field
    end)
    |> Enum.slice(first - 1, last - first + 1)
    |> IO.iodata_to_binary()
  end

  defp compare(case_id, operation, blob_case, expected, actual) do
    query =
      blob_case
      |> Map.take([:revision, :path, :oid, :lines])

    Allowlist.compare(
      case_id,
      %{
        operation: operation,
        fixture_repo: blob_case.repository_name,
        query: query
      },
      expected,
      actual
    )
  end

  defp oracle_type("blob"), do: :blob
  defp oracle_type("tree"), do: :tree
  defp oracle_type("commit"), do: :commit
  defp oracle_type("tag"), do: :tag

  defp path_id(path), do: Base.encode16(path, case: :lower)
  defp fixture(name), do: Path.join(@fixtures, name)
end
