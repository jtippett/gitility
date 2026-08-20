defmodule Gitility.Differential.BundleParityTest do
  use ExUnit.Case, async: false

  alias Gitility.{Bundle, OID, RefDB, Repository}
  alias Gitility.Differential.Oracle

  @moduletag :gitility_engine
  @fixtures Path.expand("../../fixtures/generated", __DIR__)

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "gitility-m4b-parity-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)
    %{directory: directory}
  end

  test "packed, mixed, nested, alternate, and sha256 families publish and verify",
       context do
    for fixture_name <- [
          "sha1-basic-packed.git",
          "sha1-basic-mixed.git",
          "sha1-nested.git",
          "sha1-alternate.git",
          "sha256-basic.git"
        ] do
      source = fixture(fixture_name)
      path = Path.join(context.directory, fixture_name <> ".bundle")

      assert {:ok, receipt} =
               Bundle.write(path,
                 source: {:repository, source},
                 source_identity: "fixture:#{fixture_name}"
               )

      assert receipt.files > 0
      assert :ok = Bundle.verify(path)
      expected_hash = if fixture_name == "sha256-basic.git", do: :sha256, else: :sha1

      assert {:ok, info} = Bundle.info(path)
      assert info.hash_algorithm == expected_hash
      assert info.source_identity == "fixture:#{fixture_name}"

      assert {:ok, state} = Bundle.RangeBackend.init(path)
      assert {:ok, manifest} = Bundle.RangeBackend.manifest(state)
      assert manifest.hash == expected_hash
      assert manifest.packs != []

      assert {:ok, ref_state} = Bundle.RefBackend.init(path)
      assert {:ok, head} = Bundle.RefBackend.resolve("HEAD", ref_state)
      assert head.oid.algorithm == expected_hash

      if expected_hash == :sha256 do
        assert {:ok, toc} = Bundle.Format.parse(path)
        tag = Enum.find(toc.refs, &(&1.name == "refs/tags/v1.0.0"))
        assert tag.kind == :tag
        assert is_binary(tag.peeled)
        assert {:ok, expected_peeled} = Oracle.rev_parse(source, "v1.0.0^{commit}")
        assert OID.to_string(OID.new!(:sha256, tag.peeled)) == expected_peeled
      end

      hydration = Path.join(context.directory, fixture_name <> "-hydrated")
      assert {:ok, bundle_repository} = Bundle.open(path, into: {:dir, hydration})
      assert bundle_repository.odb.hash == expected_hash
      assert {:ok, bundle_head} = RefDB.resolve(bundle_repository.refs, "HEAD")
      assert bundle_head.oid.algorithm == expected_hash

      if expected_hash == :sha1 do
        assert {:ok, source_repository} = Repository.open(source)
        assert {:ok, source_snapshot} = Repository.snapshot(source_repository, :head)
        assert {:ok, bundle_snapshot} = Repository.snapshot(bundle_repository, :head)
        assert bundle_snapshot.commit_oid == source_snapshot.commit_oid
        assert bundle_snapshot.tree_oid == source_snapshot.tree_oid
      end
    end
  end

  test "bundle refs match canonical Git modulo asserted publication skips", context do
    source = fixture("sha1-refs.git")
    path = Path.join(context.directory, "refs.bundle")
    hydration = Path.join(context.directory, "refs-hydrated")

    assert {:ok, receipt} = Bundle.write(path, source: {:repository, source})
    skip_warnings = Enum.filter(receipt.warnings, &(&1.code == :malformed_ref))
    assert skip_warnings != []
    assert Enum.any?(skip_warnings, &String.contains?(&1.message, "4096-byte limit"))
    assert Enum.any?(skip_warnings, &String.contains?(&1.message, "missing"))

    assert {:ok, expected} = Oracle.refs(source)
    expected_by_name = Map.new(expected, &{&1.name, &1})
    assert {:ok, bundle_repository} = Bundle.open(path, into: {:dir, hydration})
    actual = collect_refs(bundle_repository.refs)

    for ref <- actual, ref.name != "HEAD" do
      oracle = Map.fetch!(expected_by_name, ref.name)
      assert {:ok, target} = RefDB.resolve(bundle_repository.refs, ref.name)
      assert OID.to_string(target.oid) == oracle.object

      if oracle.peeled not in [nil, ""] and target.peeled do
        assert OID.to_string(target.peeled) == oracle.peeled
      end
    end

    assert {:ok, expected_head} = Oracle.rev_parse(source, "HEAD")
    assert {:ok, head} = RefDB.resolve(bundle_repository.refs, "HEAD")
    assert OID.to_string(head.oid) == expected_head

    assert {:ok, info} = Bundle.info(path)
    assert info.metadata["head_symref"] == "refs/heads/main"

    assert {:ok, source_repository} = Repository.open(source)

    for selector <- [{:branch, "main"}, {:tag, "refs-chain"}, :head] do
      assert {:ok, source_snapshot} = Repository.snapshot(source_repository, selector)
      assert {:ok, bundle_snapshot} = Repository.snapshot(bundle_repository, selector)
      assert bundle_snapshot.commit_oid == source_snapshot.commit_oid
      assert bundle_snapshot.tree_oid == source_snapshot.tree_oid
    end
  end

  test "log, tree, file, diff, and blame queries are storage-parity", context do
    for {fixture_name, file_path} <- [
          {"sha1-basic-packed.git", "README.md"},
          {"sha1-history.git", "src/tale.txt"}
        ] do
      source_path = fixture(fixture_name)
      bundle_path = Path.join(context.directory, fixture_name <> "-queries.bundle")
      hydration = Path.join(context.directory, fixture_name <> "-queries-hydrated")
      assert {:ok, _receipt} = Bundle.write(bundle_path, source: {:repository, source_path})
      assert {:ok, source} = Repository.open(source_path)
      assert {:ok, bundled} = Bundle.open(bundle_path, into: {:dir, hydration})
      assert {:ok, source_head} = Repository.snapshot(source, :head)
      assert {:ok, bundle_head} = Repository.snapshot(bundled, :head)

      assert {:ok, source_log} = Gitility.log(source_head, limit: 25)
      assert {:ok, bundle_log} = Gitility.log(bundle_head, limit: 25)
      assert Enum.map(bundle_log.items, & &1.oid) == Enum.map(source_log.items, & &1.oid)

      assert {:ok, source_tree} = Gitility.list_tree(source_head, "", recursive: true)
      assert {:ok, bundle_tree} = Gitility.list_tree(bundle_head, "", recursive: true)
      assert bundle_tree.items == source_tree.items

      assert {:ok, source_file} = Gitility.read_file(source_head, file_path)
      assert {:ok, bundle_file} = Gitility.read_file(bundle_head, file_path)
      assert bundle_file.data == source_file.data

      assert {:ok, parent} = Oracle.rev_parse(source_path, "HEAD^")
      assert {:ok, source_parent} = Repository.snapshot(source, {:oid, parent})
      assert {:ok, bundle_parent} = Repository.snapshot(bundled, {:oid, parent})
      assert {:ok, source_diff} = Gitility.diff(source_parent, source_head, format: :summary)
      assert {:ok, bundle_diff} = Gitility.diff(bundle_parent, bundle_head, format: :summary)
      assert bundle_diff.files == source_diff.files

      assert {:ok, source_blame} = Gitility.blame(source_head, file_path)
      assert {:ok, bundle_blame} = Gitility.blame(bundle_head, file_path)
      assert bundle_blame.path == source_blame.path
      assert bundle_blame.hunks == source_blame.hunks
    end
  end

  defp collect_refs(refs) do
    Stream.unfold(nil, fn
      :done ->
        nil

      cursor ->
        {:ok, page} = RefDB.list(refs, limit: 17, cursor: cursor)
        {page.items, page.next_cursor || :done}
    end)
    |> Enum.to_list()
    |> List.flatten()
  end

  defp fixture(name), do: Path.join(@fixtures, name)
end
