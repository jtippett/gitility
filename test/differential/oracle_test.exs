defmodule Gitility.Differential.OracleTest do
  use ExUnit.Case, async: true

  alias Gitility.Differential.Oracle

  @project_root Path.expand("../..", __DIR__)
  @fixtures Path.join(@project_root, "fixtures/generated")
  @pinned_version_file Path.join(__DIR__, "GIT_VERSION")

  defp fixture(name), do: Path.join(@fixtures, name)

  test "runtime canonical Git matches the pinned major/minor" do
    pinned = @pinned_version_file |> File.read!() |> String.trim()
    runtime = Oracle.git_version()
    pinned_major_minor = major_minor(pinned)
    runtime_major_minor = major_minor(runtime)

    if runtime_major_minor == pinned_major_minor do
      assert runtime_major_minor == pinned_major_minor
    else
      message = """
      canonical Git version mismatch: runtime #{runtime}, pinned #{pinned}.
      Oracle upgrades require differential triage and an updated GIT_VERSION.
      For an intentional one-off local run, set
      GITILITY_ORACLE_ALLOW_VERSION_MISMATCH=1 (never set it in CI).
      """

      if System.get_env("GITILITY_ORACLE_ALLOW_VERSION_MISMATCH") == "1" do
        IO.warn(message)
        assert true
      else
        flunk(message)
      end
    end
  end

  test "ls-tree preserves the complete basic shape and unusual path bytes" do
    assert {:ok, entries} = Oracle.ls_tree(fixture("sha1-basic.git"), "main")
    assert length(entries) == 15

    assert %{
             mode: "100644",
             type: "blob",
             path: <<"invalid-", 0xFF, "-name.txt">>
           } = Enum.find(entries, &(&1.path == <<"invalid-", 0xFF, "-name.txt">>))

    quoted_path = <<"quoted-\"", 0x01, "-name.txt">>

    assert %{mode: "100644", type: "blob", path: ^quoted_path} =
             Enum.find(entries, &(&1.path == quoted_path))

    assert %{mode: "100755", path: "run-fixture"} =
             Enum.find(entries, &(&1.path == "run-fixture"))

    assert %{mode: "120000", path: "link-to-nested"} =
             Enum.find(entries, &(&1.path == "link-to-nested"))

    assert %{mode: "160000", type: "commit", path: "modules/example"} =
             Enum.find(entries, &(&1.path == "modules/example"))
  end

  test "cat-file returns exact type, size, and arbitrary blob bytes" do
    assert {:ok, %{type: "blob", size: 0, content: <<>>}} =
             Oracle.cat_file(fixture("sha1-basic.git"), "main:empty.bin")

    binary = <<0, 0xFF, 0xFE, "binary", 0x80, "payload\n">>
    binary_size = byte_size(binary)

    assert {:ok, %{type: "blob", size: ^binary_size, content: ^binary}} =
             Oracle.cat_file(fixture("sha1-basic.git"), "main:binary.dat")

    assert {:ok, %{type: "tree", size: 0, content: <<>>}} =
             Oracle.cat_file(fixture("sha1-basic.git"), "main:empty-dir")

    assert {:ok, %{type: "tag"}} =
             Oracle.cat_file(fixture("sha1-basic.git"), "refs/tags/v1.0.0")
  end

  test "SHA-256 fixtures have the same tree shape with 32-byte object IDs" do
    repository = fixture("sha256-basic.git")

    assert {:ok, entries} = Oracle.ls_tree(repository, "main")
    assert length(entries) == 15
    assert Enum.all?(entries, &(byte_size(&1.oid) == 64))

    assert Enum.any?(entries, &(&1.path == <<"invalid-", 0xFF, "-name.txt">>))
    assert {:ok, %{type: "blob", content: <<>>}} = Oracle.cat_file(repository, "main:empty.bin")
  end

  test "revision walking and merge-base expose the criss-cross graph" do
    repository = fixture("sha1-history.git")
    head = git_oid("sha1_history_head")

    assert {:ok, [^head | commits]} = Oracle.rev_list(repository, ["main"])
    assert length(commits) >= 10

    assert {:ok, merge_bases} =
             Oracle.merge_base(repository, "fixture/criss-left", "fixture/criss-right")

    assert length(merge_bases) == 2
    assert Enum.all?(merge_bases, &(byte_size(&1) == 40))
  end

  test "raw and patch diffs normalize exact and similarity renames" do
    repository = fixture("sha1-history.git")

    assert {:ok, changes} =
             Oracle.diff_raw(
               repository,
               "fixture/pre-renames",
               "fixture/post-renames",
               ["--find-renames"]
             )

    assert [
             %{
               status: "R",
               similarity: 100,
               path: "docs/exact-old.txt",
               destination: "docs/exact-new.txt"
             },
             %{
               status: "R",
               similarity: similarity,
               path: "docs/guide.txt",
               destination: "docs/manual.txt"
             }
           ] = changes

    assert similarity in 85..95

    assert {:ok, patch} =
             Oracle.diff_patch(
               repository,
               "fixture/pre-renames",
               "fixture/post-renames",
               ["--find-renames"]
             )

    assert :binary.match(patch, "rename from docs/guide.txt") != :nomatch
    assert :binary.match(patch, "guide line 10, lightly revised") != :nomatch
  end

  test "blame porcelain is parsed into contiguous byte-path hunks" do
    repository = fixture("sha1-history.git")

    assert {:ok, hunks} = Oracle.blame(repository, "main", "src/tale.txt")

    assert Enum.map(hunks, & &1.final_range) == [{1, 1}, {2, 2}, {3, 4}, {5, 5}]
    assert Enum.all?(hunks, &(&1.original_path == "src/story.txt"))
    assert Enum.all?(hunks, &(byte_size(&1.commit) == 40))

    assert {:ok, %{content: content}} = Oracle.cat_file(repository, "main:src/tale.txt")
    assert hunk_line_count(hunks) == content_line_count(content)
  end

  test "log --follow keeps NUL-delimited rename and path history" do
    assert {:ok, records} =
             Oracle.log_follow(fixture("sha1-history.git"), "main", "src/tale.txt")

    assert length(records) == 3

    assert %{
             changes: [
               %{
                 status: "R",
                 similarity: 100,
                 path: "src/story.txt",
                 destination: "src/tale.txt"
               }
             ]
           } = hd(records)

    assert Enum.map(records, fn %{changes: [change]} -> change.status end) == ["R", "M", "A"]
  end

  test "blame and follow return an invalid-UTF-8 path byte-for-byte" do
    repository = fixture("sha1-basic.git")
    path = <<"invalid-", 0xFF, "-name.txt">>

    assert {:ok, [%{original_path: ^path, final_range: {1, 1}}]} =
             Oracle.blame(repository, "main", path)

    assert {:ok, [%{changes: [%{status: "A", path: ^path}]}]} =
             Oracle.log_follow(repository, "main", path)
  end

  test "blame unescapes a quoted path to its exact original bytes" do
    repository = fixture("sha1-basic.git")
    path = <<"quoted-\"", 0x01, "-name.txt">>

    assert {:ok, [%{original_path: ^path, final_range: {1, 1}}]} =
             Oracle.blame(repository, "main", path)
  end

  test "alternate, missing, packed, mixed, and multi-pack-index layouts are live" do
    readme_oid = git_oid("sha1_basic_readme")

    assert {:ok, %{type: "blob"}} =
             Oracle.cat_file(fixture("sha1-alternate.git"), readme_oid)

    assert {:error, _error} = Oracle.cat_file(fixture("sha1-missing.git"), readme_oid)

    assert Path.wildcard(fixture("sha1-basic-packed.git/objects/pack/*.pack")) != []
    assert Path.wildcard(fixture("sha1-basic-mixed.git/objects/??/*")) != []

    assert length(Path.wildcard(fixture("sha1-history-midx.git/objects/pack/*.pack"))) >= 2
    assert File.regular?(fixture("sha1-history-midx.git/objects/pack/multi-pack-index"))
    assert File.regular?(fixture("sha1-history-shallow.git/shallow"))

    assert Path.wildcard(fixture("sha1-history-replace.git/refs/replace/*")) != []
  end

  test "LFS pointer stays ordinary, exact blob content" do
    expected =
      "version https://git-lfs.github.com/spec/v1\n" <>
        "oid sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n" <>
        "size 12345\n"

    assert {:ok, %{type: "blob", size: size, content: ^expected}} =
             Oracle.cat_file(fixture("lfs-pointer.git"), "main:model.bin")

    assert size == byte_size(expected)
  end

  test "canonical Git rejects every surgical corruption" do
    corrupt_repositories = [
      "loose-bad-hash.git",
      "loose-malformed-header.git",
      "pack-truncated.git",
      "pack-bad-checksum.git",
      "idx-bad-checksum.git"
    ]

    for repository <- corrupt_repositories do
      assert {:error, %{status: status}} = Oracle.fsck(fixture("corrupt/#{repository}"))
      assert status > 0
    end

    readme_oid = git_oid("sha1_basic_readme")

    for repository <- ["loose-malformed-header.git", "pack-truncated.git"] do
      assert {:error, %{status: status}} =
               Oracle.cat_file(fixture("corrupt/#{repository}"), readme_oid)

      assert status > 0
    end
  end

  defp major_minor(version) do
    [major, minor | _rest] = :binary.split(version, <<".">>, [:global])
    major <> "." <> minor
  end

  defp git_oid(key) do
    @fixtures
    |> Path.join("OIDS")
    |> File.read!()
    |> :binary.split(<<"\n">>, [:global])
    |> Enum.find_value(fn line ->
      prefix = key <> "="
      prefix_size = byte_size(prefix)

      case line do
        <<candidate::binary-size(^prefix_size), value::binary>> when candidate == prefix -> value
        _other -> nil
      end
    end)
  end

  defp hunk_line_count(hunks) do
    Enum.reduce(hunks, 0, fn %{final_range: {first, last}}, count ->
      count + last - first + 1
    end)
  end

  defp content_line_count(content) do
    fields = :binary.split(content, <<"\n">>, [:global])

    case Enum.reverse(fields) do
      [<<>> | _rest] -> length(fields) - 1
      _other -> length(fields)
    end
  end
end
