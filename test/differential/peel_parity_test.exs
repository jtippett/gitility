defmodule Gitility.Differential.PeelParityTest do
  use ExUnit.Case, async: true

  alias Gitility.{OID, Repository}
  alias Gitility.Differential.{Allowlist, Oracle}

  @moduletag :gitility_engine

  @fixtures Path.expand("../../fixtures/generated", __DIR__)

  setup_all do
    basic_tags =
      "sha1-basic.git"
      |> discover_tags()
      |> Enum.filter(&(&1.type == "tag"))

    history_tags = discover_tags("sha1-history.git")

    assert basic_tags != [], "sha1-basic must retain its annotated tag fixture"
    assert length(history_tags) >= 9, "sha1-history must retain its known fixture tag corpus"

    {:ok, tags: basic_tags ++ history_tags}
  end

  test "tags peel to the same commit as git rev-parse tag^{commit}", %{tags: tags} do
    compare_target(tags, :commit)
  end

  test "tags peel to the same tree as git rev-parse tag^{tree}", %{tags: tags} do
    compare_target(tags, :tree)
  end

  defp compare_target(tags, target) do
    repositories =
      tags
      |> Enum.map(& &1.repository_name)
      |> Enum.uniq()
      |> Map.new(fn repository_name ->
        assert {:ok, repository} = Repository.open(fixture(repository_name))
        {repository_name, repository}
      end)

    for tag <- tags do
      repository_path = fixture(tag.repository_name)
      expression = tag.ref <> "^{#{target}}"
      assert {:ok, expected} = Oracle.rev_parse(repository_path, expression)

      repository = Map.fetch!(repositories, tag.repository_name)
      assert {:ok, actual} = Gitility.peel(repository, tag.oid, to: target)

      Allowlist.compare(
        "peel/#{tag.repository_name}/#{tag.ref}/#{target}",
        %{
          operation: :peel,
          fixture_repo: tag.repository_name,
          query: %{tag: tag.ref, tag_oid: tag.oid, to: target}
        },
        expected,
        OID.to_string(actual)
      )
    end
  end

  defp discover_tags(repository_name) do
    assert {:ok, tags} = Oracle.tag_refs(fixture(repository_name))

    Enum.map(tags, &Map.put(&1, :repository_name, repository_name))
  end

  defp fixture(name), do: Path.join(@fixtures, name)
end
