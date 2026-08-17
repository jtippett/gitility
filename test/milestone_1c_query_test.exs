defmodule Gitility.Milestone1cQueryTest do
  use ExUnit.Case, async: true

  alias Gitility.{Error, Limits, NativeSupport, Object, ODB, OID, Repository, Snapshot}

  @fixtures Path.expand("../fixtures/generated", __DIR__)

  @recursive_paths [
    "README.md",
    "assets",
    "assets/large.bin",
    "binary.dat",
    "empty-dir",
    "empty.bin",
    <<"invalid-", 0xFF, "-name.txt">>,
    "link-to-nested",
    "long-line.txt",
    "modules",
    "modules/example",
    <<"quoted-\"", 0x01, "-name.txt">>,
    "repeated",
    "repeated/one.txt",
    "repeated/two.txt",
    "run-fixture",
    "src",
    "src/story.txt",
    "subdir",
    "subdir/nested.txt",
    "subdir/second.txt"
  ]

  setup do
    {:ok, repo} = Repository.open(fixture("sha1-basic.git"))
    head = fixture_oid(:sha1_basic_head)
    {:ok, snapshot} = Repository.snapshot(repo, {:oid, head})
    %{repo: repo, snapshot: snapshot, head: head}
  end

  test "opens bare and normal repository layouts and enforces require_bare", %{head: head} do
    {:ok, bare} = Repository.open(fixture("sha1-basic.git"), require_bare: true)
    assert {:ok, %Snapshot{commit_oid: ^head}} = Repository.snapshot(bare, {:oid, head})

    worktree =
      Path.join(
        System.tmp_dir!(),
        "gitility-m1c-worktree-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(worktree)
    File.ln_s!(fixture("sha1-basic.git"), Path.join(worktree, ".git"))
    File.write!(Path.join(worktree, "worktree-only"), "must not be read")
    on_exit(fn -> File.rm_rf!(worktree) end)

    # Since Milestone 4a, Repository.open composes the local ref store.
    assert {:ok, %Repository{refs: %Gitility.RefDB{}}} = Repository.open(worktree)

    assert {:error, %Error{code: :invalid_argument}} =
             Repository.open(worktree, require_bare: true)
  end

  test "snapshots accept hex and typed OIDs, peel annotated tags, and reject unsupported inputs",
       %{
         repo: repo,
         head: head
       } do
    assert {:ok, %Snapshot{commit_oid: ^head}} =
             Repository.snapshot(repo, {:oid, OID.to_string(head)})

    assert {:ok, %Snapshot{commit_oid: ^head} = snapshot} = Snapshot.open(repo.odb, head)

    tag = ref_oid("sha1-basic.git", "refs/tags/v1.0.0")
    assert {:ok, %Snapshot{commit_oid: ^head}} = Snapshot.open(repo.odb, tag)
    assert {:ok, ^head} = Gitility.peel(repo, tag)
    assert {:ok, tree_oid} = Gitility.peel(repo, tag, to: :tree)
    assert tree_oid == snapshot.tree_oid

    readme = fixture_oid(:sha1_basic_readme)
    assert {:ok, ^readme} = Gitility.peel(repo.odb, readme, to: :blob)
    assert {:error, %Error{code: :not_a_blob}} = Gitility.peel(repo, head, to: :blob)

    assert {:error, %Error{code: :not_a_commit}} =
             Snapshot.open(repo.odb, readme)

    {:ok, sha256_repo} = Repository.open(fixture("sha256-basic.git"))

    assert {:error, %Error{code: :unsupported_hash}} =
             Snapshot.open(sha256_repo.odb, fixture_oid(:sha256_basic_head))

    # Ref selectors went live in Milestone 4a: :head now resolves on a
    # local repository. The refs-absent refusal is covered in
    # milestone_4a_refs_test.exs against an ODB-only composition.
    assert {:ok, %Snapshot{commit_oid: ^head}} = Repository.snapshot(repo, :head)
  end

  test "recursive tree listing preserves every fixture path byte-for-byte", %{
    snapshot: snapshot
  } do
    assert {:ok, page} = Gitility.list_tree(snapshot, "", recursive: true)
    assert Enum.map(page.items, & &1.path) == @recursive_paths
    refute page.truncated
    assert page.warnings == []
    assert page.stats.objects_read > 0
    assert page.stats.objects_requested == page.stats.objects_read
    assert page.stats.entries_emitted == length(page.items)
    assert is_integer(page.stats.elapsed_ms) and page.stats.elapsed_ms >= 0
    assert page.stats.stopped_by == nil

    assert Enum.any?(page.items, &(&1.path == <<"invalid-", 0xFF, "-name.txt">>))
    assert Enum.any?(page.items, &(&1.path == <<"quoted-\"", 0x01, "-name.txt">>))
  end

  test "tree scope, depth, types, pathspecs, and opt-in sizes map to core options", %{
    snapshot: snapshot
  } do
    assert {:ok, non_recursive} = Gitility.list_tree(snapshot)
    assert length(non_recursive.items) == 14

    assert {:ok, depth_one} = Gitility.list_tree(snapshot, "", recursive: true, depth: 1)
    assert depth_one.items == non_recursive.items

    assert {:ok, blobs} =
             Gitility.list_tree(snapshot, "", recursive: true, types: [:blob])

    assert length(blobs.items) == 13
    assert Enum.all?(blobs.items, &(&1.type == :blob))

    assert {:ok, text_files} =
             Gitility.list_tree(snapshot, "",
               recursive: true,
               types: [:blob],
               pathspecs: ["**/*.txt"]
             )

    assert Enum.map(text_files.items, & &1.path) == [
             <<"invalid-", 0xFF, "-name.txt">>,
             "long-line.txt",
             <<"quoted-\"", 0x01, "-name.txt">>,
             "repeated/one.txt",
             "repeated/two.txt",
             "src/story.txt",
             "subdir/nested.txt",
             "subdir/second.txt"
           ]

    assert {:ok, sized} = Gitility.list_tree(snapshot, "", include: [:size])
    assert Enum.find(sized.items, &(&1.path == "README.md")).size == 50
    assert Enum.find(sized.items, &(&1.path == "assets")).size == nil
  end

  test "public cursor pagination has no gaps or duplicates and validates identity", %{
    snapshot: snapshot
  } do
    pages = collect_pages(snapshot, recursive: true, limit: 2)
    assert Enum.map(pages, & &1.path) == @recursive_paths
    assert length(Enum.uniq_by(pages, & &1.path)) == length(pages)

    {:ok, first} = Gitility.list_tree(snapshot, "", recursive: true, limit: 2)
    raw = Base.url_decode64!(first.next_cursor, padding: false)
    <<byte, rest::binary>> = raw
    tampered = Base.url_encode64(<<Bitwise.bxor(byte, 1), rest::binary>>, padding: false)

    assert {:error, %Error{code: :invalid_cursor}} =
             Gitility.list_tree(snapshot, "", recursive: true, limit: 2, cursor: tampered)

    assert {:error, %Error{code: :invalid_cursor}} =
             Gitility.list_tree(snapshot, "",
               recursive: true,
               include: [:size],
               limit: 2,
               cursor: first.next_cursor
             )

    assert_raise ArgumentError, ~r/:cursor.*binary/, fn ->
      Gitility.list_tree(snapshot, "", cursor: {:not, :a, :string})
    end
  end

  test "page truncation identifies the binding limit and resumes max_results pages", %{
    snapshot: snapshot
  } do
    assert {:ok, caller_limited} =
             Gitility.list_tree(snapshot, "", recursive: true, limit: 2)

    assert caller_limited.stats.stopped_by == :limit

    assert caller_limited.warnings == [
             %{code: :truncated, message: "page truncated by limit"}
           ]

    limits = Limits.new(max_results: 3)

    assert {:ok, page} =
             Gitility.list_tree(snapshot, "", recursive: true, limit: 5_000, limits: limits)

    assert length(page.items) == 3
    assert page.truncated
    assert is_binary(page.next_cursor)
    assert page.stats.stopped_by == :max_results

    assert page.warnings == [
             %{code: :truncated, message: "page truncated by max_results"}
           ]

    all_items =
      collect_pages(snapshot, recursive: true, limit: 5_000, limits: limits)

    assert Enum.map(all_items, & &1.path) == @recursive_paths
  end

  test "reads whole files, line ranges, truncation, binary blobs, and symlinks", %{
    snapshot: snapshot
  } do
    assert {:ok, readme} = Gitility.read_file(snapshot, "README.md")
    assert readme.data == "# Gitility fixture\n\nCanonical object-query input.\n"
    assert readme.kind == :text
    assert readme.total_lines == 3

    assert {:ok, range} = Gitility.read_file(snapshot, "src/story.txt", lines: 3..100)
    assert range.data == "third line\nfourth line\n"
    assert {range.start_line, range.end_line, range.total_lines} == {3, 4, 4}

    assert {:ok, long} = Gitility.read_file(snapshot, "long-line.txt", max_bytes: 32)
    assert long.data == :binary.copy("x", 32)
    assert long.truncated
    assert long.total_lines == nil

    assert {:ok, binary} = Gitility.read_file(snapshot, "binary.dat")
    assert binary.kind == :binary
    assert binary.data == <<0, 255, 254, "binary", 128, "payload\n">>

    assert {:ok, symlink} = Gitility.read_file(snapshot, "link-to-nested")
    assert symlink.kind == :symlink
    assert symlink.data == "subdir/nested.txt"
  end

  test "read_file accepts a raw non-UTF-8 path argument", %{snapshot: snapshot} do
    path = <<"invalid-", 0xFF, "-name.txt">>

    assert {:ok, file} = Gitility.read_file(snapshot, path)
    assert file.path == path
    assert file.data == "raw path bytes\n"
  end

  test "operation caps lower to Limits instead of raising them", %{
    repo: repo,
    snapshot: snapshot
  } do
    readme = fixture_oid(:sha1_basic_readme)
    limits = Limits.new(max_object_bytes: 10)

    assert {:ok, file} =
             Gitility.read_file(snapshot, "README.md", max_bytes: 100, limits: limits)

    assert byte_size(file.data) == 10
    assert file.truncated
    assert file.total_lines == nil

    assert {:error, %Error{code: :object_too_large, details: %{limit: :max_object_bytes}}} =
             ODB.read(repo.odb, readme, max_bytes: 100, limits: limits)
  end

  test "detects an LFS pointer without resolving it" do
    {:ok, repo} = Repository.open(fixture("lfs-pointer.git"))
    {:ok, snapshot} = Snapshot.open(repo.odb, fixture_oid(:lfs_pointer_head))
    assert {:ok, file} = Gitility.read_file(snapshot, "model.bin")

    assert file.lfs_pointer == %{
             oid: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
             size: 12_345
           }

    assert file.data =~ "version https://git-lfs.github.com/spec/v1"
  end

  test "file path and line errors are normalized", %{snapshot: snapshot} do
    for path <- ["missing", "src", "src/./story.txt", "src/../story.txt", "nul\0path"] do
      expected = if path == "src", do: :not_a_blob, else: :invalid_path
      assert {:error, %Error{code: ^expected}} = Gitility.read_file(snapshot, path)
    end

    for range <- [3..1//-1, 0..2, 1..0//-1] do
      assert {:error, %Error{code: :invalid_argument}} =
               Gitility.read_file(snapshot, "README.md", lines: range)
    end
  end

  test "ODB headers, bounded reads, and mixed batch misses use public DTOs", %{
    repo: repo,
    head: head
  } do
    readme = fixture_oid(:sha1_basic_readme)
    missing = OID.new!(:sha1, <<0::160>>)

    assert {:ok, %{type: :commit, size: 264, oid: ^head}} =
             ODB.header(repo.odb, OID.to_string(head))

    {:ok, snapshot} = Snapshot.open(repo.odb, head)

    assert {:ok, %{type: :tree, size: 527, oid: tree_oid}} =
             ODB.header(repo.odb, snapshot.tree_oid)

    assert tree_oid == snapshot.tree_oid

    assert {:ok, %{type: :blob, size: 50, oid: ^readme}} = ODB.header(repo.odb, readme)

    assert {:error, %Error{code: :object_too_large, details: %{limit: :max_bytes}}} =
             ODB.read(repo.odb, readme, max_bytes: 1)

    assert {:ok, %{type: :blob, data: data, oid: ^readme}} = ODB.read(repo.odb, readme)
    assert byte_size(data) == 50

    assert {:ok, %{oid: ^readme}} =
             ODB.read(repo.odb, readme, limits: Limits.new(max_objects: 1))

    assert {:ok, objects} = ODB.read_many(repo.odb, [head, missing, readme])
    assert objects[head].type == :commit
    assert objects[missing] == :not_found
    assert objects[readme].data == data

    assert {:error, %Error{code: :result_too_large}} =
             ODB.read_many(repo.odb, [head, readme], max_total_bytes: 100)
  end

  test "read_many handles empty and ten-object batches", %{repo: repo, snapshot: snapshot} do
    assert {:ok, %{}} = ODB.read_many(repo.odb, [])

    {:ok, listing} = Gitility.list_tree(snapshot, "", recursive: true)

    oids =
      [snapshot.commit_oid, snapshot.tree_oid | Enum.map(listing.items, & &1.oid)]
      |> Enum.uniq()
      |> Enum.take(10)

    assert length(oids) == 10
    assert {:ok, objects} = ODB.read_many(repo.odb, oids)
    assert map_size(objects) == 10
    assert MapSet.new(Map.keys(objects)) == MapSet.new(oids)
    assert Enum.all?(objects, fn {_oid, object} -> match?(%Object{}, object) end)
  end

  test "static ODB derives absent IDs and validates construction options" do
    empty = OID.parse!("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
    readme = fixture_oid(:sha1_basic_readme)
    readme_data = "# Gitility fixture\n\nCanonical object-query input.\n"

    assert {:ok, odb} =
             ODB.from_objects([
               %Object{oid: empty, type: :blob, data: <<>>},
               %Object{oid: nil, type: :blob, data: readme_data}
             ])

    assert {:ok, %{data: <<>>}} = ODB.read(odb, empty)
    assert {:ok, %{oid: ^readme, data: ^readme_data}} = ODB.read(odb, readme)

    wrong = OID.new!(:sha1, <<0::160>>)

    assert {:error, %Error{code: :hash_mismatch}} =
             ODB.from_objects([%Object{oid: wrong, type: :blob, data: "tampered"}])

    assert {:error, %Error{code: :invalid_argument}} = ODB.from_objects([], verify: :off)

    assert_raise ArgumentError, ~r/expected a Gitility.Object/, fn ->
      ODB.from_objects([:not_an_object])
    end

    assert {:ok, sha256_odb} = ODB.from_objects([], hash: :sha256)

    assert {:error, %Error{code: :unsupported_hash}} =
             Snapshot.open(sha256_odb, fixture_oid(:sha256_basic_head))
  end

  test "corrupt fixtures return their manifest-specific normalized codes" do
    readme = fixture_oid(:sha1_basic_readme)

    for {name, expected} <- [
          {"loose-bad-hash.git", :hash_mismatch},
          {"loose-malformed-header.git", :malformed_object},
          {"pack-truncated.git", :pack_checksum_mismatch},
          {"pack-bad-checksum.git", :pack_checksum_mismatch},
          {"idx-bad-checksum.git", :index_checksum_mismatch},
          {"pack-body-corrupt-valid-checksums.git", :malformed_object}
        ] do
      assert {:ok, repo} =
               Repository.open(fixture("corrupt/#{name}"), verify_pack_checksums: true)

      assert {:error, %Error{code: ^expected}} = ODB.read(repo.odb, readme)
    end

    for name <- ["pack-truncated.git", "pack-bad-checksum.git", "idx-bad-checksum.git"] do
      assert {:ok, repo} =
               Repository.open(fixture("corrupt/#{name}"), verify_pack_checksums: false)

      case ODB.read(repo.odb, readme) do
        {:ok, %Object{data: data}} ->
          assert data == "# Gitility fixture\n\nCanonical object-query input.\n"

        {:error, %Error{code: code}} ->
          assert code in [:hash_mismatch, :malformed_object, :backend_error]
      end
    end
  end

  test "peel enforces tag hops, target semantics, and missing objects", %{repo: repo, head: head} do
    {objects, outer_tag} = tag_chain(17)
    assert {:ok, odb} = ODB.from_objects(objects)

    assert {:error, %Error{code: :malformed_object}} =
             Gitility.peel(odb, outer_tag, to: :blob)

    assert {:error, %Error{code: :invalid_argument}} = Gitility.peel(repo, head, to: :tag)

    missing = OID.new!(:sha1, <<0::160>>)
    assert {:error, %Error{code: :missing_object}} = Gitility.peel(repo, missing)
  end

  test "known limit names survive the NIF error builder" do
    error =
      NativeSupport.nif_error(
        %{
          code: :budget_exceeded,
          message: "max_tree_entries exceeded",
          retryable: false,
          limit: "max_tree_entries"
        },
        :list_tree
      )

    assert error.details == %{limit: :max_tree_entries}
  end

  test "native error code atoms are non-empty and covered by Gitility.Error" do
    codes = Gitility.Native.error_codes()
    assert codes != []
    assert MapSet.subset?(MapSet.new(codes), MapSet.new(Error.codes()))
  end

  test "every wired public function rejects unknown option keys", %{
    repo: repo,
    snapshot: snapshot,
    head: head
  } do
    calls = [
      fn -> Repository.open(fixture("sha1-basic.git"), unknown: true) end,
      fn -> Repository.snapshot(repo, {:oid, head}, unknown: true) end,
      fn -> Snapshot.open(repo.odb, head, unknown: true) end,
      fn -> ODB.from_objects([], unknown: true) end,
      fn -> ODB.header(repo.odb, head, unknown: true) end,
      fn -> ODB.read(repo.odb, head, unknown: true) end,
      fn -> ODB.read_many(repo.odb, [head], unknown: true) end,
      fn -> Gitility.list_tree(snapshot, "", unknown: true) end,
      fn -> Gitility.read_file(snapshot, "README.md", unknown: true) end,
      fn -> Gitility.peel(repo, head, unknown: true) end
    ]

    Enum.each(calls, fn call -> assert_raise ArgumentError, call end)
  end

  test "wrongly typed option values raise and semantic violations return invalid_argument", %{
    repo: repo,
    snapshot: snapshot,
    head: head
  } do
    assert_raise ArgumentError, ~r/:require_bare.*boolean/, fn ->
      Repository.open(fixture("sha1-basic.git"), require_bare: "yes")
    end

    assert_raise ArgumentError, ~r/:verify_pack_checksums.*boolean/, fn ->
      Repository.open(fixture("sha1-basic.git"), verify_pack_checksums: 1)
    end

    assert_raise ArgumentError, ~r/:recursive.*boolean/, fn ->
      Gitility.list_tree(snapshot, "", recursive: 1)
    end

    assert_raise ArgumentError, ~r/:max_objects.*positive integer/, fn ->
      ODB.header(repo.odb, head, limits: Limits.new(max_objects: -1))
    end

    assert_raise ArgumentError, ~r/:timeout_ms.*positive integer/, fn ->
      ODB.header(repo.odb, head, limits: Limits.new(timeout_ms: :infinity))
    end

    assert_raise ArgumentError, ~r/:types.*atoms/, fn ->
      Gitility.list_tree(snapshot, "", types: ["blob"])
    end

    assert {:error, %Error{code: :invalid_argument}} =
             Gitility.list_tree(snapshot, "", types: [:commit])

    assert_raise ArgumentError, ~r/:include.*atoms/, fn ->
      Gitility.list_tree(snapshot, "", include: ["size"])
    end

    assert {:error, %Error{code: :invalid_argument}} =
             Gitility.list_tree(snapshot, "", include: [:oid])

    assert_raise ArgumentError, ~r/:pathspecs.*binaries/, fn ->
      Gitility.list_tree(snapshot, "", pathspecs: [123])
    end

    assert {:error, %Error{code: :invalid_argument}} =
             Gitility.list_tree(snapshot, "", depth: -1)

    assert_raise ArgumentError, ~r/tree path.*binary/, fn ->
      Gitility.list_tree(snapshot, :root)
    end

    assert_raise ArgumentError, ~r/file path.*binary/, fn ->
      Gitility.read_file(snapshot, [:README])
    end

    assert {:error, %Error{code: :invalid_argument}} =
             Gitility.list_tree(snapshot, "", limit: 0)
  end

  test "ref selectors resolve since M4a; revspec stays an explicit unsupported operation", %{
    repo: repo,
    head: head
  } do
    assert {:ok, %Snapshot{commit_oid: ^head}} = Repository.snapshot(repo, {:branch, "main"})

    # Nonexistent names are honest misses, not policy refusals.
    assert {:error, %Error{code: :ref_not_found}} =
             Repository.snapshot(repo, {:tag, "v1-missing"})

    # The advanced selector remains policy-refused in 0.x.
    assert {:error, %Error{code: :unsupported_operation}} =
             Repository.snapshot(repo, {:revspec, "HEAD~1"})
  end

  defp collect_pages(snapshot, opts, cursor \\ nil, acc \\ []) do
    {:ok, page} = Gitility.list_tree(snapshot, "", Keyword.put(opts, :cursor, cursor))

    acc = acc ++ page.items

    case page.next_cursor do
      nil -> acc
      next_cursor -> collect_pages(snapshot, opts, next_cursor, acc)
    end
  end

  defp tag_chain(length) do
    blob_data = "payload"
    blob_oid = object_oid(:blob, blob_data)

    {objects, outer_oid, _target_type} =
      Enum.reduce(
        0..(length - 1),
        {[%Object{oid: blob_oid, type: :blob, data: blob_data}], blob_oid, :blob},
        fn index, {objects, target_oid, target_type} ->
          data =
            "object #{OID.to_string(target_oid)}\n" <>
              "type #{target_type}\n" <>
              "tag hop-#{index}\n" <>
              "tagger Gitility <fixture@gitility.invalid> 0 +0000\n\n" <>
              "hop\n"

          oid = object_oid(:tag, data)
          {[%Object{oid: oid, type: :tag, data: data} | objects], oid, :tag}
        end
      )

    {objects, outer_oid}
  end

  defp object_oid(type, data) do
    header = "#{type} #{byte_size(data)}\0"
    OID.new!(:sha1, :crypto.hash(:sha, header <> data))
  end

  defp fixture(name), do: Path.join(@fixtures, name)

  defp fixture_oid(name) do
    value =
      @fixtures
      |> Path.join("OIDS")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.find_value(fn line ->
        case String.split(line, "=", parts: 2) do
          [key, value] -> if key == Atom.to_string(name), do: value
          _ -> nil
        end
      end)

    OID.parse!(value)
  end

  defp ref_oid(repository, ref) do
    repository
    |> fixture()
    |> Path.join(ref)
    |> File.read!()
    |> String.trim()
    |> OID.parse!()
  end
end
