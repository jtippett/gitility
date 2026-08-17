defmodule Gitility.Differential.RefsParityTest do
  use ExUnit.Case, async: true

  alias Gitility.{OID, RefDB, Repository}
  alias Gitility.Differential.Oracle

  @moduletag :gitility_engine
  @fixtures Path.expand("../../fixtures/generated", __DIR__)

  setup do
    path = Path.join(@fixtures, "sha1-refs.git")
    {:ok, repository} = Repository.open(path)
    %{path: path, repository: repository, refs: repository.refs}
  end

  test "direct, symbolic, HEAD, and annotated tag-chain resolution match git", context do
    for name <- [
          "refs/heads/main",
          "refs/heads/packed-only",
          "refs/heads/loose-only",
          "refs/heads/both",
          "refs/heads/a/b/c",
          "refs/heads/@"
        ] do
      assert {:ok, expected} = Oracle.rev_parse(context.path, name)
      assert {:ok, target} = RefDB.resolve(context.refs, name)
      assert OID.to_string(target.oid) == expected
    end

    assert {:ok, "refs/heads/main"} =
             Oracle.symbolic_ref(context.path, "refs/heads/symbolic-main")

    assert {:ok, symbolic} = RefDB.resolve(context.refs, "refs/heads/symbolic-main")
    assert {:ok, main} = RefDB.resolve(context.refs, "refs/heads/main")
    assert symbolic == main

    assert {:ok, expected_head} = Oracle.rev_parse(context.path, "HEAD")
    assert {:ok, head} = RefDB.resolve(context.refs, "HEAD")
    assert OID.to_string(head.oid) == expected_head

    assert {:ok, expected_commit} = Oracle.rev_parse(context.path, "refs-chain^{commit}")
    assert {:ok, snapshot} = Repository.snapshot(context.repository, {:tag, "refs-chain"})
    assert OID.to_string(snapshot.commit_oid) == expected_commit
  end

  test "NUL-safe listing parity and cursor reconstruction span at least three pages", context do
    assert {:ok, expected} = Oracle.refs(context.path)
    actual = collect_pages(context.refs, nil, 17)

    assert Enum.map(actual, fn ref ->
             target =
               if ref.target.kind == :symbolic do
                 {:ok, resolved} = RefDB.resolve(context.refs, ref.name)
                 resolved
               else
                 ref.target
               end

             {ref.name, OID.to_string(target.oid)}
           end) ==
             Enum.map(expected, &{&1.name, &1.object})

    assert length(actual) >= 60
    assert {:ok, expected_heads} = Oracle.refs(context.path, "refs/heads/page/")
    assert Enum.map(collect_pages(context.refs, "refs/heads/page/", 13), & &1.name) ==
             Enum.map(expected_heads, & &1.name)
  end

  test "detached HEAD parity", _context do
    path = Path.join(@fixtures, "sha1-refs-detached.git")
    assert {:ok, repository} = Repository.open(path)
    assert {:ok, expected} = Oracle.rev_parse(path, "HEAD")
    assert {:ok, snapshot} = Repository.snapshot(repository, :head)
    assert OID.to_string(snapshot.commit_oid) == expected
    assert {:error, _} = Oracle.symbolic_ref(path, "HEAD")
  end

  test "check-ref-format acceptance probes match provider-name validation", context do
    names = [
      "refs/heads/main",
      "refs/heads/a/b/c",
      "refs/heads/@",
      "refs/heads/@foo",
      "refs/heads/dot.hidden",
      <<"refs/heads/raw-", 255>>,
      "refs/heads/.leading-dot",
      "refs/heads/dot..dot",
      "refs/heads/trailing.",
      "refs/heads/name.lock",
      "refs/heads/a@{b",
      "refs/heads/a b",
      "refs/heads/a//b",
      "refs/heads/",
      "/refs/heads/main",
      "refs/heads/back\\slash",
      "refs/heads/tilde~name",
      "refs/heads/caret^name",
      "refs/heads/colon:name",
      "refs/heads/bracket[name",
      "refs/heads/question?name",
      "refs/heads/star*name"
    ]

    Enum.each(names, fn name ->
      git_accepts =
        case Oracle.check_ref_format(name) do
          {:ok, normalized} -> normalized == name
          {:error, _} -> false
        end

      gitility_accepts =
        case RefDB.resolve(context.refs, name) do
          {:ok, _target_or_missing} -> true
          {:error, error} -> error.code != :malformed_ref
        end

      assert gitility_accepts == git_accepts, inspect(name)
    end)
  end

  defp collect_pages(refs, prefix, limit) do
    Stream.unfold(nil, fn
      :done ->
        nil

      cursor ->
        {:ok, page} = RefDB.list(refs, prefix: prefix, limit: limit, cursor: cursor)
        {page.items, page.next_cursor || :done}
    end)
    |> Enum.to_list()
    |> List.flatten()
  end
end
