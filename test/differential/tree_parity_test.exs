defmodule Gitility.Differential.TreeParityTest do
  use ExUnit.Case, async: true

  alias Gitility.{OID, Repository}
  alias Gitility.Differential.{Allowlist, Oracle}

  @moduletag :gitility_engine

  @fixtures Path.expand("../../fixtures/generated", __DIR__)
  @repositories [
    "sha1-basic.git",
    "sha1-history.git",
    "sha1-nested.git",
    "sha1-basic-packed.git",
    "sha1-basic-mixed.git",
    "sha1-history-midx.git",
    "sha1-alternate.git",
    "sha1-history-replace.git",
    "sha1-history-shallow.git"
  ]

  @pathspec_cases [
    %{repository_name: "sha1-basic.git", scope: "subdir", pattern: "nested*"},
    %{repository_name: "sha1-basic.git", scope: "", pattern: "*.txt"},
    %{repository_name: "sha1-basic.git", scope: "", pattern: "assets"},
    %{repository_name: "sha1-nested.git", scope: "", pattern: "**/*.txt"},
    %{repository_name: "sha1-nested.git", scope: "", pattern: "lib/**/b.txt"}
  ]

  test "recursive default listings match git ls-tree -r -t -z for every commit" do
    each_snapshot(fn repository_name, repository_path, commit, snapshot ->
      assert {:ok, expected} =
               Oracle.ls_tree(repository_path, commit, include_trees: true)

      assert {:ok, actual} = Gitility.list_tree(snapshot, "", recursive: true)

      compare(
        "tree/#{repository_name}/#{commit}/recursive-all",
        repository_name,
        %{revision: commit, path: <<>>, recursive: true, types: :all},
        normalize_oracle(expected),
        normalize_engine(actual.items)
      )
    end)
  end

  test "recursive listings without trees match git ls-tree -r -z for every commit" do
    each_snapshot(fn repository_name, repository_path, commit, snapshot ->
      assert {:ok, expected} = Oracle.ls_tree(repository_path, commit)

      assert {:ok, actual} =
               Gitility.list_tree(snapshot, "",
                 recursive: true,
                 types: [:blob, :symlink, :gitlink]
               )

      compare(
        "tree/#{repository_name}/#{commit}/recursive-no-trees",
        repository_name,
        %{
          revision: commit,
          path: <<>>,
          recursive: true,
          types: [:blob, :symlink, :gitlink]
        },
        normalize_oracle(expected),
        normalize_engine(actual.items)
      )
    end)
  end

  test "non-recursive root and subtree listings match git ls-tree -z for every commit" do
    each_snapshot(fn repository_name, repository_path, commit, snapshot ->
      assert {:ok, root_expected} =
               Oracle.ls_tree(repository_path, commit, recursive: false)

      assert {:ok, root_actual} = Gitility.list_tree(snapshot)

      compare(
        "tree/#{repository_name}/#{commit}/non-recursive-root",
        repository_name,
        %{revision: commit, path: <<>>, recursive: false},
        normalize_oracle(root_expected),
        normalize_engine(root_actual.items)
      )

      subtree =
        Enum.find(root_expected, &(&1.type == "tree")) ||
          flunk("fixture commit #{commit} in #{repository_name} has no root subtree")

      assert {:ok, subtree_expected} =
               Oracle.ls_tree(repository_path, commit,
                 recursive: false,
                 path: subtree.path <> "/"
               )

      assert {:ok, subtree_actual} = Gitility.list_tree(snapshot, subtree.path)

      compare(
        "tree/#{repository_name}/#{commit}/non-recursive-subtree/#{hex(subtree.path)}",
        repository_name,
        %{revision: commit, path: subtree.path, recursive: false},
        normalize_oracle(subtree_expected),
        normalize_engine(subtree_actual.items)
      )
    end)
  end

  test "opt-in sizes match git ls-tree -l for every commit" do
    each_snapshot(fn repository_name, repository_path, commit, snapshot ->
      assert {:ok, no_tree_expected} =
               Oracle.ls_tree(repository_path, commit, include_size: true)

      assert {:ok, no_tree_actual} =
               Gitility.list_tree(snapshot, "",
                 recursive: true,
                 types: [:blob, :symlink, :gitlink],
                 include: [:size]
               )

      compare(
        "tree/#{repository_name}/#{commit}/sizes-no-trees",
        repository_name,
        %{
          revision: commit,
          path: <<>>,
          recursive: true,
          types: [:blob, :symlink, :gitlink],
          include: [:size]
        },
        normalize_oracle(no_tree_expected, size: true),
        normalize_engine(no_tree_actual.items, size: true)
      )

      assert {:ok, all_expected} =
               Oracle.ls_tree(repository_path, commit,
                 include_trees: true,
                 include_size: true
               )

      assert {:ok, all_actual} =
               Gitility.list_tree(snapshot, "",
                 recursive: true,
                 include: [:size]
               )

      compare(
        "tree/#{repository_name}/#{commit}/sizes-all",
        repository_name,
        %{
          revision: commit,
          path: <<>>,
          recursive: true,
          types: :all,
          include: [:size]
        },
        normalize_oracle(all_expected, size: true),
        normalize_engine(all_actual.items, size: true)
      )
    end)
  end

  test "scope-relative pathspecs select strict, non-empty oracle-derived partitions" do
    for %{repository_name: repository_name, scope: scope, pattern: pattern} <- @pathspec_cases do
      repository_path = fixture(repository_name)
      assert {:ok, [commit | _]} = Oracle.rev_list(repository_path, ["main"])
      assert {:ok, repository} = Repository.open(repository_path)
      assert {:ok, snapshot} = Repository.snapshot(repository, {:oid, commit})

      query = %{revision: commit, path: scope, recursive: true, pathspecs: [pattern]}

      assert {:ok, oracle_root} =
               Oracle.ls_tree(repository_path, commit, include_trees: true)

      oracle_scoped = scoped_listing(oracle_root, scope)

      expected_subset =
        Enum.filter(oracle_scoped, fn entry ->
          relative = relative_to_scope(entry.path, scope)
          reference_pathspec_match?(pattern, relative)
        end)

      assert expected_subset != [],
             "pathspec #{inspect(pattern)} must select at least one entry in #{repository_name}"

      assert expected_subset != oracle_scoped,
             "pathspec #{inspect(pattern)} must partition its scope in #{repository_name}"

      assert {:ok, engine_unfiltered} = Gitility.list_tree(snapshot, scope, recursive: true)

      compare(
        "tree/#{repository_name}/#{commit}/pathspec-unfiltered-scope/#{hex(pattern)}",
        repository_name,
        Map.put(query, :pathspecs, []),
        normalize_oracle(oracle_scoped),
        normalize_engine(engine_unfiltered.items)
      )

      # Mutation guard: dropping pathspecs cannot accidentally produce the expected partition.
      refute normalize_engine(engine_unfiltered.items) == normalize_oracle(expected_subset)

      assert {:ok, actual_subset} =
               Gitility.list_tree(snapshot, scope,
                 recursive: true,
                 pathspecs: [pattern]
               )

      oracle_paths = MapSet.new(oracle_scoped, & &1.path)
      actual_paths = MapSet.new(actual_subset.items, & &1.path)

      compare(
        "tree/#{repository_name}/#{commit}/pathspec-subset-proof/#{hex(pattern)}",
        repository_name,
        Map.put(query, :property, :strict_subset_of_oracle_listing),
        true,
        MapSet.subset?(actual_paths, oracle_paths) and actual_paths != oracle_paths and
          MapSet.size(actual_paths) > 0
      )

      compare(
        "tree/#{repository_name}/#{commit}/pathspec-expected-subset/#{hex(pattern)}",
        repository_name,
        query,
        normalize_oracle(expected_subset),
        normalize_engine(actual_subset.items)
      )
    end
  end

  test "reference matcher gives double-star slash-crossing and zero-component semantics" do
    paths = ["root.txt", "src/nested.txt", "src/deeper/leaf.txt", "src/not-text.ex"]

    assert Enum.filter(paths, &reference_pathspec_match?("**/*.txt", &1)) ==
             ["root.txt", "src/nested.txt", "src/deeper/leaf.txt"]
  end

  test "reference matcher refuses unsupported character classes" do
    assert_raise ArgumentError,
                 ~r/reference matcher does not support character classes.*— extend it deliberately/,
                 fn -> reference_pathspec_match?("[ab].txt", "a.txt") end
  end

  defp each_snapshot(fun) do
    for repository_name <- @repositories do
      repository_path = fixture(repository_name)
      assert {:ok, commits} = Oracle.rev_list(repository_path, ["--all"])
      assert commits != []
      assert {:ok, repository} = Repository.open(repository_path)

      for commit <- commits do
        assert {:ok, snapshot} = Repository.snapshot(repository, {:oid, commit})
        fun.(repository_name, repository_path, commit, snapshot)
      end
    end
  end

  defp normalize_oracle(entries, options \\ []) do
    include_size = Keyword.get(options, :size, false)

    Enum.map(entries, fn entry ->
      normalized = %{
        path: entry.path,
        oid: entry.oid,
        mode: parse_mode(entry.mode),
        kind: oracle_kind(entry)
      }

      if include_size, do: Map.put(normalized, :size, Map.get(entry, :size)), else: normalized
    end)
  end

  defp normalize_engine(entries, options \\ []) do
    include_size = Keyword.get(options, :size, false)

    Enum.map(entries, fn entry ->
      normalized = %{
        path: entry.path,
        oid: OID.to_string(entry.oid),
        mode: entry.mode,
        kind: entry.type
      }

      if include_size, do: Map.put(normalized, :size, entry.size), else: normalized
    end)
  end

  defp oracle_kind(%{type: "tree"}), do: :tree
  defp oracle_kind(%{type: "commit"}), do: :gitlink
  defp oracle_kind(%{type: "blob", mode: "120000"}), do: :symlink
  defp oracle_kind(%{type: "blob"}), do: :blob

  defp parse_mode(mode) do
    {value, ""} = Integer.parse(mode, 8)
    value
  end

  defp scoped_listing(entries, ""), do: entries
  defp scoped_listing(entries, scope), do: Enum.filter(entries, &prefix_path?(&1.path, scope))

  defp prefix_path?(path, scope) do
    prefix = scope <> "/"
    byte_size(path) > byte_size(prefix) and binary_part(path, 0, byte_size(prefix)) == prefix
  end

  defp relative_to_scope(path, ""), do: path

  defp relative_to_scope(path, scope) do
    prefix_size = byte_size(scope) + 1
    binary_part(path, prefix_size, byte_size(path) - prefix_size)
  end

  defp reference_pathspec_match?(pattern, path) do
    reject_unsupported_reference_pattern!(pattern)

    if :binary.match(pattern, ["*", "?", "["]) == :nomatch do
      path == pattern or prefix_path?(path, pattern)
    else
      reference_wildmatch?(pattern, path)
    end
  end

  defp reject_unsupported_reference_pattern!(pattern) do
    construct =
      cond do
        :binary.match(pattern, "[") != :nomatch -> "character classes (`[...]`)"
        :binary.match(pattern, "\\") != :nomatch -> "backslash escaping"
        match?(<<":", _rest::binary>>, pattern) -> "pathspec magic"
        true -> nil
      end

    if construct do
      raise ArgumentError,
            "reference matcher does not support #{construct} — extend it deliberately"
    end
  end

  defp reference_wildmatch?(<<>>, <<>>), do: true
  defp reference_wildmatch?(<<>>, _path), do: false

  defp reference_wildmatch?(<<"**/", rest::binary>> = pattern, path) do
    reference_wildmatch?(rest, path) or
      case :binary.match(path, "/") do
        {slash_offset, 1} ->
          tail_offset = slash_offset + 1
          tail = binary_part(path, tail_offset, byte_size(path) - tail_offset)
          reference_wildmatch?(pattern, tail)

        :nomatch ->
          false
      end
  end

  defp reference_wildmatch?(<<"**", rest::binary>> = pattern, path) do
    reference_wildmatch?(rest, path) or
      case path do
        <<_byte, tail::binary>> -> reference_wildmatch?(pattern, tail)
        _other -> false
      end
  end

  defp reference_wildmatch?(<<"*", rest::binary>> = pattern, path) do
    reference_wildmatch?(rest, path) or
      case path do
        <<byte, tail::binary>> when byte != ?/ -> reference_wildmatch?(pattern, tail)
        _other -> false
      end
  end

  defp reference_wildmatch?(<<"?", rest::binary>>, <<byte, tail::binary>>) when byte != ?/,
    do: reference_wildmatch?(rest, tail)

  defp reference_wildmatch?(<<byte, rest::binary>>, <<byte, tail::binary>>),
    do: reference_wildmatch?(rest, tail)

  defp reference_wildmatch?(_pattern, _path), do: false

  defp compare(case_id, repository_name, query, expected, actual) do
    Allowlist.compare(
      case_id,
      %{operation: :list_tree, fixture_repo: repository_name, query: query},
      expected,
      actual
    )
  end

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
  defp fixture(name), do: Path.join(@fixtures, name)
end
