defmodule Gitility.Differential.CommitGraphParityTest do
  use ExUnit.Case, async: true

  alias Gitility.Differential.{Allowlist, Oracle}
  alias Gitility.{OID, Repository, Snapshot}

  @fixtures Path.expand("../../fixtures/generated", __DIR__)

  for repository_name <- ["sha1-graph.git", "sha1-history.git", "sha1-basic.git"] do
    for {case_name, git_options, gitility_options} <- [
          {:default, [], []},
          {:topological, [order: :topological], [order: :topological]},
          {:date_order, [order: :date], [order: :date]},
          {:first_parent, [first_parent: true], [first_parent: true]}
        ] do
      @tag :gitility_engine
      test "log parity #{repository_name} #{case_name}" do
        repository_name = unquote(repository_name)
        repository_path = fixture(repository_name)
        assert {:ok, expected} = Oracle.log(repository_path, "main", unquote(git_options))
        assert {:ok, repository} = Repository.open(repository_path)
        assert {:ok, head} = Oracle.rev_parse(repository_path, "main")
        assert {:ok, snapshot} = Snapshot.open(repository.odb, head)
        assert {:ok, page} = Gitility.log(snapshot, unquote(gitility_options))
        actual = Enum.map(page.items, &OID.to_string(&1.id))

        assert :ok =
                 Allowlist.compare(
                   {unquote(repository_name), unquote(case_name)},
                   %{
                     operation: :log,
                     fixture_repo: repository_name,
                     query: %{revision: "main", options: unquote(git_options)}
                   },
                   expected,
                   actual
                 )
      end
    end
  end

  for {repository_name, since, until} <- [
        {"sha1-graph.git", 988_761_700, 988_761_760},
        {"sha1-history.git", 980_985_720, 980_986_200},
        {"sha1-basic.git", 978_307_260, 978_307_260}
      ] do
    @tag :gitility_engine
    test "log since and until parity #{repository_name}" do
      repository_name = unquote(repository_name)
      since = unquote(since)
      until = unquote(until)
      repository_path = fixture(repository_name)
      git_options = [since: "@#{since}", until: "@#{until}"]
      gitility_options = [since: since, until: until]
      assert {:ok, expected} = Oracle.log(repository_path, "main", git_options)
      assert {:ok, repository} = Repository.open(repository_path)
      assert {:ok, head} = Oracle.rev_parse(repository_path, "main")
      assert {:ok, snapshot} = Snapshot.open(repository.odb, head)
      assert {:ok, page} = Gitility.log(snapshot, gitility_options)
      actual = Enum.map(page.items, &OID.to_string(&1.id))

      assert :ok =
               Allowlist.compare(
                 {repository_name, :since_until},
                 %{
                   operation: :log,
                   fixture_repo: repository_name,
                   query: %{revision: "main", options: git_options}
                 },
                 expected,
                 actual
               )
    end
  end

  for {case_name, left, right} <- [
        {:criss_cross, "fixture/criss-left", "fixture/criss-right"},
        {:octopus_sides, "fixture/branch-a", "fixture/branch-c"},
        {:disjoint, "fixture/tail-tip", "fixture/disjoint"},
        {:identical, "fixture/octopus", "fixture/octopus"}
      ] do
    @tag :gitility_engine
    test "merge-base and ancestor parity #{case_name}" do
      repository_name = "sha1-graph.git"
      repository_path = fixture(repository_name)
      left_name = unquote(left)
      right_name = unquote(right)
      assert {:ok, repository} = Repository.open(repository_path)
      assert {:ok, left_hex} = Oracle.rev_parse(repository_path, left_name)
      assert {:ok, right_hex} = Oracle.rev_parse(repository_path, right_name)

      assert {:ok, expected_all} = Oracle.merge_base(repository_path, left_name, right_name)
      expected_all = Enum.sort(expected_all, :desc)
      assert {:ok, actual_all} = Gitility.merge_base(repository.odb, left_hex, right_hex, all: true)
      actual_all = Enum.map(actual_all, &OID.to_string/1)

      assert :ok =
               Allowlist.compare(
                 {unquote(case_name), :all},
                 %{
                   operation: :merge_base_all,
                   fixture_repo: repository_name,
                   query: %{left: left_name, right: right_name}
                 },
                 expected_all,
                 actual_all
               )

      assert {:ok, expected_one} =
               Oracle.merge_base(repository_path, left_name, right_name, all: false)

      assert {:ok, actual_one} = Gitility.merge_base(repository.odb, left_hex, right_hex)
      actual_one = if actual_one, do: [OID.to_string(actual_one)], else: []

      assert :ok =
               Allowlist.compare(
                 {unquote(case_name), :default},
                 %{
                   operation: :merge_base,
                   fixture_repo: repository_name,
                   query: %{left: left_name, right: right_name}
                 },
                 expected_one,
                 actual_one
               )

      assert {:ok, expected_ancestor} = Oracle.is_ancestor(repository_path, left_name, right_name)
      assert {:ok, actual_ancestor} = Gitility.ancestor?(repository.odb, left_hex, right_hex)

      assert :ok =
               Allowlist.compare(
                 {unquote(case_name), :ancestor},
                 %{
                   operation: :ancestor,
                   fixture_repo: repository_name,
                   query: %{ancestor: left_name, descendant: right_name}
                 },
                 expected_ancestor,
                 actual_ancestor
               )
    end
  end

  defp fixture(name), do: Path.join(@fixtures, name)
end
