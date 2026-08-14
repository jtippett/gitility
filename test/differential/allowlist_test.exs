defmodule Gitility.Differential.AllowlistTest do
  use ExUnit.Case, async: true

  alias Gitility.Differential.Allowlist

  test "allowlist file is well-formed and every entry is fully triaged" do
    assert :ok = Allowlist.validate()

    for entry <- Allowlist.entries() do
      assert is_atom(entry.operation)
      assert is_binary(entry.fixture_repo) and byte_size(entry.fixture_repo) > 0
      refute is_nil(entry.query)
      assert is_binary(entry.explanation) and byte_size(entry.explanation) > 0
      assert is_binary(entry.git_version_triaged)
      assert Regex.match?(~r/^\d+\.\d+/, entry.git_version_triaged)
    end
  end

  test "validation rejects an entry without an explanation or Git version" do
    malformed = [
      %{
        id: :missing_triage,
        operation: :blame,
        fixture_repo: "sha1-history.git",
        query: %{revision: "main", path: "src/tale.txt"},
        classification: :known_engine_deviation,
        explanation: "",
        git_version_triaged: ""
      }
    ]

    assert {:error, reason} = Allowlist.validate_entries(malformed)
    assert reason =~ "explanation"
  end

  test "compare accepts exact agreement and rejects a new divergence" do
    context = %{operation: :ls_tree, fixture_repo: "sha1-basic.git", query: "main"}

    assert :ok = Allowlist.compare(:exact_case, context, %{value: 1}, %{value: 1})

    assert_raise ExUnit.AssertionError, ~r/unallowlisted differential divergence/, fn ->
      Allowlist.compare(:new_case, context, %{value: 1}, %{value: 2})
    end
  end
end
