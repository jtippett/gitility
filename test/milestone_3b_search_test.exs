defmodule Gitility.M3bObjectBackend do
  @behaviour Gitility.ODB.Backend

  @impl true
  def init(objects), do: {:ok, objects}

  @impl true
  def read_many(oids, objects) do
    {:ok, Map.new(oids, &{&1, Map.get(objects, &1, :not_found)})}
  end
end

defmodule Gitility.M3bBlockingBackend do
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
      send(observer, {:m3b_provider_read_blocked, self()})

      receive do
        :release_m3b_provider_read -> :ok
      end
    end

    {:ok, Map.new(oids, &{&1, Map.get(objects, &1, :not_found)})}
  end
end

defmodule Gitility.Milestone3bSearchTest do
  use ExUnit.Case, async: true

  alias Gitility.{Error, Job, Limits, ODB, Repository, Runtime, SearchMatch}

  @fixtures Path.expand("../fixtures/generated", __DIR__)

  setup do
    child_id = {Runtime, System.unique_integer([:positive])}

    runtime =
      start_supervised!(Supervisor.child_spec({Runtime, workers: 1}, id: child_id))

    {:ok, repository} = Repository.open(fixture("sha1-search.git"), runtime: runtime)
    {:ok, snapshot} = Repository.snapshot(repository, {:oid, fixture_oid(:sha1_search_head)})
    %{runtime: runtime, repository: repository, snapshot: snapshot}
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
    end) ||
      raise "missing OIDS key #{name}"
  end

  test "literal, regex, case, scope, pathspec, binary, and context options have happy paths", %{
    snapshot: snapshot
  } do
    assert {:ok, literal} = Gitility.search(snapshot, "needle")
    assert literal.items != []
    assert Enum.all?(literal.items, &match?(%SearchMatch{}, &1))
    assert literal.stats.binary_skipped == 2

    assert {:ok, insensitive} =
             Gitility.search(snapshot, "needle",
               case_sensitive: false,
               pathspecs: ["deep/**"]
             )

    assert [%SearchMatch{column: 5, submatches: [_, _], submatches_truncated: false}] =
             insensitive.items

    assert {:ok, regex} = Gitility.search(snapshot, "n[e]{2}dle", mode: :regex)
    assert length(regex.items) == length(literal.items)

    assert {:ok, scoped} = Gitility.search(snapshot, "needle", path: "dedup")
    assert length(scoped.items) == 3
    assert Enum.all?(scoped.items, &String.starts_with?(&1.path, "dedup/"))

    assert {:ok, pathspec} =
             Gitility.search(snapshot, "needle", pathspecs: ["pages/**"])

    assert length(pathspec.items) == 40

    assert {:ok, binary} =
             Gitility.search(snapshot, "needle",
               binary: :text,
               pathspecs: ["binary-with-needle.dat"]
             )

    assert [%SearchMatch{column: 27}] = binary.items

    assert {:ok, context} =
             Gitility.search(snapshot, "needle on crlf", context_lines: 1)

    assert [%SearchMatch{context_before: ["first\r"], context_after: ["last\r"]}] =
             context.items
  end

  test "DTO caps previews and non-UTF-8 content survives losslessly", %{snapshot: snapshot} do
    assert {:ok, latin1} =
             Gitility.search(snapshot, "needle", pathspecs: ["latin1.txt"])

    assert [%SearchMatch{preview: <<"caf", 0xE9, " needle latin-1">>}] = latin1.items

    assert {:ok, long} =
             Gitility.search(snapshot, "x", pathspecs: ["after-8000.txt"])

    assert [%SearchMatch{preview_truncated: true}] = long.items
    assert Enum.all?(long.items, &(byte_size(&1.preview) <= 1_024))

    assert Enum.all?(long.items, fn item ->
             Enum.all?(item.context_before ++ item.context_after, &(byte_size(&1) <= 1_024))
           end)
  end

  test "cursor pagination reconstructs files and grouped multi-match lines", %{
    snapshot: snapshot
  } do
    opts = [pathspecs: ["many-on-one-line.txt", "pages/**"], limit: 3]

    assert {:ok, complete} =
             Gitility.search(snapshot, "needle",
               pathspecs: ["many-on-one-line.txt", "pages/**"],
               limit: 1_000
             )

    paged = collect_pages(snapshot, "needle", opts)
    assert paged == complete.items

    grouped = Enum.find(paged, &(&1.path == "many-on-one-line.txt"))
    assert length(grouped.submatches) == 5
  end

  test "async_search mirrors the synchronous job result", %{snapshot: snapshot} do
    assert {:ok, %Job{} = job} =
             Gitility.async_search(snapshot, "needle", path: "dedup", limit: 2)

    assert {:ok, page} = Job.await(job, 1_000)
    assert length(page.items) == 2
    assert page.truncated
  end

  test "cursor fingerprint binds query and every stream-affecting option", %{snapshot: snapshot} do
    base = [path: "pages", limit: 2]
    assert {:ok, first} = Gitility.search(snapshot, "needle", base)
    assert is_binary(first.next_cursor)

    changed_calls = [
      {"needlE", base},
      {"needle", Keyword.put(base, :mode, :regex)},
      {"needle", Keyword.put(base, :case_sensitive, false)},
      {"needle", Keyword.put(base, :path, "dedup")},
      {"needle", Keyword.put(base, :pathspecs, ["*.txt"])},
      {"needle", Keyword.put(base, :binary, :text)},
      {"needle", Keyword.put(base, :context_lines, 1)}
    ]

    for {query, changed} <- changed_calls do
      assert {:error, %Error{code: :invalid_cursor}} =
               Gitility.search(
                 snapshot,
                 query,
                 Keyword.put(changed, :cursor, first.next_cursor)
               )
    end
  end

  test "result truncation and binary/oversize skips produce explicit warnings and stats", %{
    snapshot: snapshot
  } do
    assert {:ok, limited} =
             Gitility.search(snapshot, "needle", limit: 100, limits: Limits.new(max_results: 2))

    assert length(limited.items) == 2
    assert limited.truncated
    assert limited.stats.stopped_by == :max_results
    assert Enum.any?(limited.warnings, &(&1.code == :truncated))
    assert Enum.any?(limited.warnings, &(&1.code == :binary_skipped))

    assert {:ok, skipped} =
             Gitility.search(snapshot, "needle",
               pathspecs: ["after-8000.txt", "binary-with-needle.dat"],
               limits: Limits.new(max_object_bytes: 8_000)
             )

    assert skipped.items == []
    assert skipped.stats.binary_skipped == 1
    assert skipped.stats.oversize_skipped == 1
    assert Enum.any?(skipped.warnings, &(&1.code == :binary_skipped))

    assert Enum.any?(skipped.warnings, fn warning ->
             warning.code == :oversize_skipped and
               String.contains?(warning.message, "max_object_bytes")
           end)
  end

  test "dedup stats prove one scan for one blob at three paths", %{snapshot: snapshot} do
    assert {:ok, page} = Gitility.search(snapshot, "needle", path: "dedup")
    assert length(page.items) == 3
    assert page.stats.files_scanned == 1
    assert page.stats.blobs_deduped == 2
  end

  test "unsupported regex reason, invalid scope, and option conventions are normalized", %{
    snapshot: snapshot
  } do
    assert {:error,
            %Error{
              code: :unsupported_regex,
              details: %{reason: reason}
            }} = Gitility.search(snapshot, "(needle)\\1", mode: :regex)

    assert is_binary(reason) and reason != ""

    assert {:error, %Error{code: :invalid_path}} =
             Gitility.search(snapshot, "needle", path: "missing")

    assert {:error, %Error{code: :invalid_argument}} = Gitility.search(%{}, "needle")

    assert {:error, %Error{code: :invalid_argument}} =
             Gitility.search(snapshot, "needle", context_lines: 33)

    assert_raise ArgumentError, fn -> Gitility.search(snapshot, :needle) end
    assert_raise ArgumentError, fn -> Gitility.search(snapshot, "needle", mode: "literal") end
    assert_raise ArgumentError, fn -> Gitility.search(snapshot, "needle", pathspecs: [:bad]) end
    assert_raise ArgumentError, fn -> Gitility.search(snapshot, "needle", binary: "skip") end
    assert_raise ArgumentError, fn -> Gitility.search(snapshot, "needle", unknown: true) end
  end

  test "provider-backed ODB searches through the shared object seam", context do
    objects = repository_objects(context.repository, context.snapshot)

    provider =
      start_supervised!(
        {ODB,
         backend: {Gitility.M3bObjectBackend, objects}, runtime: context.runtime, concurrency: 1}
      )

    assert {:ok, provider_odb} = ODB.handle(provider)
    provider_snapshot = %{context.snapshot | odb: provider_odb}

    assert {:ok, local} = Gitility.search(context.snapshot, "needle", path: "dedup")
    assert {:ok, remote} = Gitility.search(provider_snapshot, "needle", path: "dedup")
    assert remote.items == local.items
    assert remote.stats.provider_requests > 0
  end

  test "a blocked provider makes mid-search cancellation deterministic", context do
    objects = repository_objects(context.repository, context.snapshot)

    provider =
      start_supervised!(
        {ODB,
         backend: {Gitility.M3bBlockingBackend, {objects, self()}},
         runtime: context.runtime,
         concurrency: 1,
         request_timeout: 5_000}
      )

    assert {:ok, provider_odb} = ODB.handle(provider)
    blocked_snapshot = %{context.snapshot | odb: provider_odb}

    task =
      Task.async(fn ->
        Gitility.search(blocked_snapshot, "needle", limits: Limits.new(timeout_ms: 50))
      end)

    assert_receive {:m3b_provider_read_blocked, callback}, 1_000
    assert {:error, %Error{code: :timeout}} = Task.await(task, 1_000)
    send(callback, :release_m3b_provider_read)
  end

  defp repository_objects(repository, snapshot) do
    assert {:ok, tree_page} = Gitility.list_tree(snapshot, "", recursive: true)

    oids =
      [snapshot.commit_oid, snapshot.tree_oid | Enum.map(tree_page.items, & &1.oid)]
      |> Enum.uniq()

    assert {:ok, values} = ODB.read_many(repository.odb, oids)
    Map.reject(values, fn {_oid, value} -> value == :not_found end)
  end

  defp collect_pages(snapshot, query, opts, cursor \\ nil, accumulated \\ []) do
    assert {:ok, page} = Gitility.search(snapshot, query, Keyword.put(opts, :cursor, cursor))
    accumulated = accumulated ++ page.items

    if page.next_cursor do
      collect_pages(snapshot, query, opts, page.next_cursor, accumulated)
    else
      accumulated
    end
  end

  defp fixture(name), do: Path.join(@fixtures, name)
end
