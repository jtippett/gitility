defmodule Gitility.Differential.SearchParityTest do
  # Regex search is intentionally absent here: Git's regex dialect and
  # regex::bytes accept different engine classes. Rust unit tests own regex
  # correctness, compile ceilings, and unsupported-construct coverage.
  use ExUnit.Case, async: true

  alias Gitility.{OID, Repository}
  alias Gitility.Differential.{Allowlist, Oracle}

  @moduletag :gitility_engine

  @repository_name "sha1-search.git"
  @fixtures Path.expand("../../fixtures/generated", __DIR__)

  setup_all do
    repository_path = Path.join(@fixtures, @repository_name)
    assert {:ok, [commit | _]} = Oracle.rev_list(repository_path, ["main"])
    assert {:ok, repository} = Repository.open(repository_path)
    assert {:ok, snapshot} = Repository.snapshot(repository, {:oid, commit})

    {:ok, repository_path: repository_path, commit: commit, snapshot: snapshot}
  end

  test "literal case-sensitive and ASCII-insensitive searches match git grep", context do
    for {case_id, query, options} <- [
          {:sensitive, "needle", []},
          {:insensitive, "needle", [case_sensitive: false]},
          {:pathspec, "needle", [pathspecs: ["deep/**", "dedup/**"]]}
        ] do
      oracle_options = [
        ignore_case: !Keyword.get(options, :case_sensitive, true),
        pathspecs: Keyword.get(options, :pathspecs, [])
      ]

      assert {:ok, expected} =
               Oracle.grep(context.repository_path, context.commit, query, oracle_options)

      assert {:ok, actual} = Gitility.search(context.snapshot, query, options)

      compare(
        "search/#{case_id}",
        %{query: query, options: options},
        positions(expected),
        engine_positions(actual.items)
      )

      compare(
        "search/#{case_id}/counts",
        %{query: query, options: options, property: :match_counts_per_path},
        counts(expected),
        counts(actual.items)
      )
    end
  end

  test "binary text mode matches git grep -a and text previews retain oracle bytes", context do
    assert {:ok, expected_binary} =
             Oracle.grep(context.repository_path, context.commit, "needle",
               binary: :text,
               pathspecs: ["binary-with-needle.dat"]
             )

    assert {:ok, actual_binary} =
             Gitility.search(context.snapshot, "needle",
               binary: :text,
               pathspecs: ["binary-with-needle.dat"]
             )

    compare(
      "search/binary-text",
      %{query: "needle", binary: :text, pathspecs: ["binary-with-needle.dat"]},
      positions(expected_binary),
      engine_positions(actual_binary.items)
    )

    assert {:ok, expected_text} =
             Oracle.grep(context.repository_path, context.commit, "needle",
               pathspecs: ["crlf.txt", "latin1.txt", "final-no-newline.txt"]
             )

    assert {:ok, actual_text} =
             Gitility.search(context.snapshot, "needle",
               pathspecs: ["crlf.txt", "latin1.txt", "final-no-newline.txt"]
             )

    compare(
      "search/text-preview-bytes",
      %{query: "needle", property: :preview_bytes},
      Enum.map(expected_text, &{&1.path, &1.line_bytes}),
      Enum.map(actual_text.items, &{&1.path, &1.preview})
    )
  end

  test "cursor pages reconstruct the full stream at file and grouped-line boundaries", context do
    for {pathspecs, limit} <- [
          {["pages/**"], 7},
          {["dedup/**", "many-on-one-line.txt", "pages/**"], 4},
          {["many-on-one-line.txt", "pages/**"], 1}
        ] do
      opts = [pathspecs: pathspecs, limit: limit]
      assert {:ok, full} =
               Gitility.search(context.snapshot, "needle", pathspecs: pathspecs, limit: 1_000)

      actual = collect_pages(context.snapshot, "needle", opts)

      compare(
        "search/pagination/#{limit}/#{Base.encode16(:erlang.term_to_binary(pathspecs))}",
        %{query: "needle", pathspecs: pathspecs, limit: limit},
        engine_positions(full.items),
        engine_positions(actual)
      )
    end
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

  defp positions(rows), do: Enum.map(rows, &{&1.path, &1.line, &1.column})
  defp engine_positions(rows), do: Enum.map(rows, &{&1.path, &1.line, &1.column})
  defp counts(rows), do: Enum.frequencies_by(rows, & &1.path)

  defp compare(case_id, query, expected, actual) do
    Allowlist.compare(
      case_id,
      %{operation: :search, fixture_repo: @repository_name, query: query},
      expected,
      actual
    )
  end
end
