defmodule Gitility.Differential.BlameHistoryParityTest do
  use ExUnit.Case, async: true

  alias Gitility.Differential.{Allowlist, Oracle}
  alias Gitility.{OID, Repository}

  @moduletag :gitility_engine
  @fixtures Path.expand("../../fixtures/generated", __DIR__)

  for {case_name, repository_name, head_key, path, git_options, gitility_options} <- [
        {:full, "sha1-blame.git", :sha1_blame_head, "docs/final.txt", [], []},
        {:range, "sha1-blame.git", :sha1_blame_head, "docs/final.txt", ["-L2,5"],
         [lines: 2..5]},
        {:no_follow, "sha1-blame.git", :sha1_blame_head, "docs/final.txt", ["--no-follow"],
         [follow_renames: false]},
        {:post_rename, "sha1-blame.git", :sha1_blame_post_rename, "docs/story.txt", [], []},
        {:shallow_boundary, "sha1-history-shallow.git", :sha1_history_head, "src/tale.txt", [],
         []}
      ] do
    test "blame parity #{case_name}" do
      repository_name = unquote(repository_name)
      path = unquote(path)
      head = fixture_oid(unquote(head_key))
      repository_path = fixture(repository_name)
      assert {:ok, expected} = Oracle.blame(repository_path, head, path, unquote(git_options))
      assert {:ok, repository} = Repository.open(repository_path)
      assert {:ok, snapshot} = Repository.snapshot(repository, {:oid, head})
      assert {:ok, actual} = Gitility.blame(snapshot, path, unquote(gitility_options))

      normalized =
        Enum.map(actual.hunks, fn hunk ->
          %{
            commit: OID.to_string(hunk.commit_oid),
            original_path: hunk.original_path,
            original_range: {hunk.original_range.first, hunk.original_range.last},
            final_range: {hunk.final_range.first, hunk.final_range.last},
            boundary: hunk.boundary
          }
        end)

      assert :ok =
               Allowlist.compare(
                 {unquote(case_name), path},
                 %{
                   operation: :blame,
                   fixture_repo: repository_name,
                   query: %{revision: head, path: path, options: unquote(git_options)}
                 },
                 expected,
                 normalized
               )
    end
  end

  for {repository_name, head_key, path} <- [
        {"sha1-blame.git", :sha1_blame_head, "docs/final.txt"},
        {"sha1-graph.git", :sha1_graph_head, "graph.txt"}
      ],
      follow <- [false, true] do
    test "path history parity #{repository_name} follow=#{follow}" do
      repository_name = unquote(repository_name)
      path = unquote(path)
      follow = unquote(follow)
      head = fixture_oid(unquote(head_key))
      repository_path = fixture(repository_name)

      assert {:ok, expected} =
               Oracle.path_history(repository_path, head, path, follow_renames: follow)

      assert {:ok, repository} = Repository.open(repository_path)
      assert {:ok, snapshot} = Repository.snapshot(repository, {:oid, head})
      assert {:ok, page} = Gitility.history(snapshot, path, follow_renames: follow)
      actual = Enum.map(page.items, &OID.to_string(&1.id))

      assert :ok =
               Allowlist.compare(
                 {repository_name, path, follow},
                 %{
                   operation: :history,
                   fixture_repo: repository_name,
                   query: %{revision: head, path: path, follow_renames: follow}
                 },
                 expected,
                 actual
               )
    end
  end

  test "history cursor pagination reconstructs the oracle across at least three pages" do
    repository_name = "sha1-blame.git"
    path = "docs/final.txt"
    head = fixture_oid(:sha1_blame_head)
    repository_path = fixture(repository_name)
    assert {:ok, expected} = Oracle.path_history(repository_path, head, path)
    assert {:ok, repository} = Repository.open(repository_path)
    assert {:ok, snapshot} = Repository.snapshot(repository, {:oid, head})

    {actual, pages} = collect_history(snapshot, path, nil, [], 0)
    assert pages >= 3
    assert actual == expected
  end

  defp collect_history(snapshot, path, cursor, items, pages) do
    assert {:ok, page} = Gitility.history(snapshot, path, limit: 3, cursor: cursor)
    items = items ++ Enum.map(page.items, &OID.to_string(&1.id))

    case page.next_cursor do
      nil -> {items, pages + 1}
      next -> collect_history(snapshot, path, next, items, pages + 1)
    end
  end

  defp fixture(name), do: Path.join(@fixtures, name)

  defp fixture_oid(key) do
    @fixtures
    |> Path.join("OIDS")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case String.split(line, "=", parts: 2) do
        [name, oid] when name == Atom.to_string(key) -> oid
        _ -> nil
      end
    end)
  end
end
