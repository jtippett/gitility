defmodule Gitility.Differential.DiffParityTest do
  use ExUnit.Case, async: true

  alias Gitility.Differential.{Allowlist, Oracle}
  alias Gitility.{OID, Repository}

  @moduletag :gitility_engine

  @fixtures Path.expand("../../fixtures/generated", __DIR__)
  @repository_name "sha1-diff.git"

  setup_all do
    repository_path = fixture(@repository_name)
    base_oid = fixture_oid(:sha1_diff_base)
    head_oid = fixture_oid(:sha1_diff_head)
    assert {:ok, repository} = Repository.open(repository_path)
    assert {:ok, base} = Repository.snapshot(repository, {:oid, base_oid})
    assert {:ok, head} = Repository.snapshot(repository, {:oid, head_oid})

    {:ok,
     repository_path: repository_path,
     repository: repository,
     base_oid: base_oid,
     head_oid: head_oid,
     base: base,
     head: head}
  end

  test "summary file records match diff-tree without rewrites", context do
    assert {:ok, expected} =
             Oracle.diff_tree_raw(
               context.repository_path,
               context.base_oid,
               context.head_oid,
               ["--no-renames"]
             )

    assert {:ok, actual} = Gitility.diff(context.base, context.head, format: :summary)

    compare(
      :diff_summary_no_renames,
      %{format: :summary, renames: false},
      raw_file_records(expected),
      engine_file_records(actual.files)
    )
  end

  test "rename and changed-source copy pairs match diff-tree", context do
    for {case_id, git_options, gitility_options} <- [
          {:renames, ["-M"], [renames: :similarity]},
          {:copies, ["-M", "-C"], [renames: :similarity, copies: true]}
        ] do
      assert {:ok, expected} =
               Oracle.diff_tree_raw(
                 context.repository_path,
                 context.base_oid,
                 context.head_oid,
                 git_options
               )

      assert {:ok, actual} =
               Gitility.diff(
                 context.base,
                 context.head,
                 Keyword.put(gitility_options, :format, :summary)
               )

      compare(
        {:diff_rewrites, case_id},
        %{format: :summary, git_options: git_options},
        rewrite_pairs(expected),
        engine_rewrite_pairs(actual.files)
      )

      compare_similarity_buckets(case_id, expected, actual.files)
    end
  end

  test "stats match NUL-safe numstat including binary markers", context do
    assert {:ok, expected} =
             Oracle.diff_numstat(
               context.repository_path,
               context.base_oid,
               context.head_oid,
               ["--no-renames"]
             )

    assert {:ok, actual} = Gitility.diff(context.base, context.head, format: :stats)

    compare(
      :diff_numstat,
      %{format: :stats, renames: false},
      Enum.map(expected, &{&1.path, &1.additions, &1.deletions}),
      Enum.map(actual.files, &{&1.new_path || &1.old_path, &1.additions, &1.deletions})
    )
  end

  test "histogram patch hunks match at zero and three context lines", context do
    for context_lines <- [0, 3] do
      assert {:ok, actual} =
               Gitility.diff(context.base, context.head,
                 format: :patch,
                 context_lines: context_lines
               )

      for file <- actual.files, not gitlink?(file) do
        path = file.new_path || file.old_path

        assert {:ok, expected_hunks} =
                 Oracle.diff_hunks(
                   context.repository_path,
                   context.base_oid,
                   context.head_oid,
                   path,
                   context_lines
                 )

        compare(
          {:diff_patch, context_lines, path},
          %{format: :patch, context_lines: context_lines, path: path},
          expected_hunks,
          engine_hunks(file.hunks)
        )
      end
    end
  end

  test "explicit glob-magic pathspec scopes both walkers to dir/sub", context do
    pathspecs = [":(glob)dir/sub/**"]

    assert {:ok, expected} =
             Oracle.diff_tree_raw(
               context.repository_path,
               context.base_oid,
               context.head_oid,
               ["--no-renames"],
               pathspecs
             )

    assert {:ok, actual} =
             Gitility.diff(context.base, context.head,
               format: :summary,
               pathspecs: pathspecs
             )

    compare(
      :diff_pathspec_glob,
      %{format: :summary, pathspecs: pathspecs},
      raw_file_records(expected),
      engine_file_records(actual.files)
    )
  end

  test "two real parent-child graph pairs match file-record parity" do
    repository_name = "sha1-graph.git"
    repository_path = fixture(repository_name)
    assert {:ok, repository} = Repository.open(repository_path)

    for child_expression <- ["fixture/branch-a", "fixture/branch-b"] do
      assert {:ok, child_oid} = Oracle.rev_parse(repository_path, child_expression)
      assert {:ok, base_oid} = Oracle.rev_parse(repository_path, child_oid <> "^")
      assert {:ok, base} = Repository.snapshot(repository, {:oid, base_oid})
      assert {:ok, head} = Repository.snapshot(repository, {:oid, child_oid})

      assert {:ok, expected} =
               Oracle.diff_tree_raw(repository_path, base_oid, child_oid, ["--no-renames"])

      assert {:ok, actual} = Gitility.diff(base, head, format: :summary)

      Allowlist.compare(
        {:diff_graph_pair, child_expression},
        %{
          operation: :diff,
          fixture_repo: repository_name,
          query: %{base: base_oid, head: child_oid, format: :summary, renames: false}
        },
        raw_file_records(expected),
        engine_file_records(actual.files)
      )
    end
  end

  defp raw_file_records(changes) do
    Enum.map(changes, fn change ->
      {
        git_status(change.status),
        change.path,
        Map.get(change, :destination, change.path),
        git_oid(change.old_oid),
        git_oid(change.new_oid),
        git_mode(change.old_mode),
        git_mode(change.new_mode)
      }
    end)
  end

  defp engine_file_records(files) do
    Enum.map(files, fn file ->
      {
        file.status,
        file.old_path || file.new_path,
        file.new_path || file.old_path,
        oid_string(file.old_oid),
        oid_string(file.new_oid),
        file.old_mode,
        file.new_mode
      }
    end)
  end

  defp rewrite_pairs(changes) do
    changes
    |> Enum.filter(&(&1.status in ["R", "C"]))
    |> Enum.map(&{git_status(&1.status), &1.path, &1.destination})
  end

  defp engine_rewrite_pairs(files) do
    files
    |> Enum.filter(&(&1.status in [:renamed, :copied]))
    |> Enum.map(&{&1.status, &1.old_path, &1.new_path})
  end

  defp compare_similarity_buckets(case_id, expected, actual) do
    git_scores =
      expected
      |> Enum.filter(&(&1.status in ["R", "C"]))
      |> Map.new(&{{&1.path, &1.destination}, &1.similarity})

    engine_scores =
      actual
      |> Enum.filter(&(&1.status in [:renamed, :copied]))
      |> Map.new(&{{&1.old_path, &1.new_path}, &1.similarity})

    for pair <- Map.keys(git_scores) |> Enum.sort() do
      score_case =
        if pair == {"rename-clean-old.txt", "rename-clean-new.txt"},
          do: :clean,
          else: {:candidate, pair}

      compare(
        {:diff_similarity, case_id, score_case},
        %{renames: :similarity, git_options: case_id, pair: pair},
        Map.fetch!(git_scores, pair),
        Map.get(engine_scores, pair)
      )
    end
  end

  defp engine_hunks(hunks) do
    Enum.map(hunks, fn hunk ->
      %{
        old_start: hunk.old_start,
        old_lines: hunk.old_lines,
        new_start: hunk.new_start,
        new_lines: hunk.new_lines,
        lines:
          Enum.map(hunk.lines, fn line ->
            %{
              origin: line.origin,
              content: line.content,
              old_line: line.old_line,
              new_line: line.new_line
            }
          end)
      }
    end)
  end

  defp gitlink?(file), do: mode_type(file.old_mode) == 0o160000 or mode_type(file.new_mode) == 0o160000
  defp mode_type(nil), do: nil
  defp mode_type(mode), do: Bitwise.band(mode, 0o170000)

  defp git_status("A"), do: :added
  defp git_status("D"), do: :deleted
  defp git_status("M"), do: :modified
  defp git_status("R"), do: :renamed
  defp git_status("C"), do: :copied
  defp git_status("T"), do: :type_changed

  defp git_mode(<<"000000">>), do: nil
  defp git_mode(mode), do: String.to_integer(mode, 8)

  defp git_oid("0000000000000000000000000000000000000000"), do: nil

  defp git_oid(
         "0000000000000000000000000000000000000000000000000000000000000000"
       ),
       do: nil

  defp git_oid(oid), do: oid

  defp oid_string(nil), do: nil
  defp oid_string(oid), do: OID.to_string(oid)

  defp compare(case_id, query, expected, actual) do
    Allowlist.compare(
      case_id,
      %{operation: :diff, fixture_repo: @repository_name, query: query},
      expected,
      actual
    )
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
