defmodule Gitility.Differential.CorruptInputTest do
  use ExUnit.Case, async: true

  alias Gitility.{Error, ODB, Object, Repository}
  alias Gitility.Differential.{Allowlist, Oracle}

  @moduletag :gitility_engine

  @fixtures Path.expand("../../fixtures/generated", __DIR__)
  @repo_level_corruptions [
    {"idx-bad-checksum.git", :index_checksum_mismatch},
    {"pack-bad-checksum.git", :pack_checksum_mismatch},
    {"pack-truncated.git", :pack_checksum_mismatch}
  ]
  @object_corruptions [
    {"loose-bad-hash.git", :hash_mismatch},
    {"loose-malformed-header.git", :malformed_object},
    {"pack-body-corrupt-valid-checksums.git", :malformed_object}
  ]
  @query_corruptions [
    {"loose-bad-hash.git", :hash_mismatch},
    {"pack-body-corrupt-valid-checksums.git", :malformed_object}
  ]
  @corruption_codes [
    :hash_mismatch,
    :malformed_object,
    :pack_checksum_mismatch,
    :index_checksum_mismatch
  ]

  setup_all do
    intact_repository = fixture("sha1-basic-packed.git")
    assert {:ok, [head | _]} = Oracle.rev_list(intact_repository, ["main"])
    assert {:ok, entries} = Oracle.ls_tree(intact_repository, head)

    intact_entry =
      Enum.find(entries, &(&1.path == "binary.dat")) ||
        flunk("intact fixture has no binary.dat oracle entry")

    readme_oid = fixture_oid("sha1_basic_readme")

    # generate.sh records the greatest verify-pack offset, the object nearest
    # the trailer damage in pack-truncated.git and pack-bad-checksum.git.
    pack_last_oid = fixture_oid("sha1_basic_pack_last_object")

    oracle_content =
      [readme_oid, intact_entry.oid, pack_last_oid]
      |> Enum.uniq()
      |> Map.new(fn oid ->
        assert {:ok, object} = Oracle.cat_file(intact_repository, oid)
        {oid, object.content}
      end)

    {:ok,
     head: head,
     readme_oid: readme_oid,
     intact_oid: intact_entry.oid,
     pack_last_oid: pack_last_oid,
     oracle_content: oracle_content}
  end

  test "the expectation matrices cover every generated corrupt fixture" do
    generated_names =
      @fixtures
      |> Path.join("corrupt/*.git")
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()

    expected_names =
      (@repo_level_corruptions ++ @object_corruptions)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    assert generated_names == expected_names
  end

  test "repository-level checksum damage rejects reads before object selection", %{
    readme_oid: readme_oid,
    pack_last_oid: pack_last_oid
  } do
    for {repository_name, expected_code} <- @repo_level_corruptions,
        oid <- [readme_oid, pack_last_oid] do
      repository_path = fixture("corrupt/#{repository_name}")

      assert {:ok, repository} =
               Repository.open(repository_path, verify_pack_checksums: true)

      actual = normalize_read(ODB.read(repository.odb, oid))

      Allowlist.compare(
        "corrupt/#{repository_name}/repo-checksum/#{oid}",
        %{
          operation: :odb_read,
          fixture_repo: "corrupt/#{repository_name}",
          query: %{oid: oid, repo_level: true, verify_pack_checksums: true}
        },
        {:error, expected_code},
        actual
      )
    end
  end

  test "repository-level damage with checksum verification off never returns wrong bytes", %{
    readme_oid: readme_oid,
    pack_last_oid: pack_last_oid,
    oracle_content: oracle_content
  } do
    for {repository_name, _expected_code} <- @repo_level_corruptions do
      assert {:ok, repository} =
               Repository.open(fixture("corrupt/#{repository_name}"),
                 verify_pack_checksums: false
               )

      readme_result = normalize_read(ODB.read(repository.odb, readme_oid))

      compare_oracle_bytes(
        repository_name,
        readme_oid,
        "readme",
        Map.fetch!(oracle_content, readme_oid),
        readme_result
      )

      pack_last_result = normalize_read(ODB.read(repository.odb, pack_last_oid))
      expected_pack_last = Map.fetch!(oracle_content, pack_last_oid)

      if repository_name == "pack-bad-checksum.git" do
        assert_correct_bytes_or_corruption(
          repository_name,
          pack_last_oid,
          expected_pack_last,
          pack_last_result
        )
      else
        compare_oracle_bytes(
          repository_name,
          pack_last_oid,
          "pack-last",
          expected_pack_last,
          pack_last_result
        )
      end
    end
  end

  test "object-scoped damage errors while an unrelated object retains exact bytes", %{
    readme_oid: readme_oid,
    intact_oid: intact_oid,
    oracle_content: oracle_content
  } do
    for {repository_name, expected_code} <- @object_corruptions do
      repository_path = fixture("corrupt/#{repository_name}")

      assert {:ok, verified_repository} =
               Repository.open(repository_path, verify_pack_checksums: true)

      damaged_result = normalize_read(ODB.read(verified_repository.odb, readme_oid))

      Allowlist.compare(
        "corrupt/#{repository_name}/damaged-object",
        %{
          operation: :odb_read,
          fixture_repo: "corrupt/#{repository_name}",
          query: %{oid: readme_oid, repo_level: false, verify_pack_checksums: true}
        },
        {:error, expected_code},
        damaged_result
      )

      assert {:ok, per_object_repository} =
               Repository.open(repository_path, verify_pack_checksums: false)

      intact_result = normalize_read(ODB.read(per_object_repository.odb, intact_oid))

      Allowlist.compare(
        "corrupt/#{repository_name}/intact-object",
        %{
          operation: :odb_read,
          fixture_repo: "corrupt/#{repository_name}",
          query: %{
            oid: intact_oid,
            repo_level: false,
            source_fixture_repo: "sha1-basic-packed.git",
            verify_pack_checksums: false
          }
        },
        {:ok, Map.fetch!(oracle_content, intact_oid)},
        intact_result
      )
    end
  end

  test "query API propagates object corruption without raising or returning bytes", %{
    head: head,
    readme_oid: readme_oid
  } do
    for {repository_name, expected_code} <- @query_corruptions do
      assert {:ok, repository} =
               Repository.open(fixture("corrupt/#{repository_name}"),
                 verify_pack_checksums: true
               )

      actual =
        case Repository.snapshot(repository, {:oid, head}) do
          {:ok, snapshot} -> normalize_file_read(Gitility.read_file(snapshot, "README.md"))
          {:error, %Error{code: code}} -> {:error, code}
          other -> {:unexpected, other}
        end

      Allowlist.compare(
        "corrupt/#{repository_name}/query-readme",
        %{
          operation: :read_file,
          fixture_repo: "corrupt/#{repository_name}",
          query: %{
            oid: readme_oid,
            path: "README.md",
            repo_level: false,
            verify_pack_checksums: true
          }
        },
        {:error, expected_code},
        actual
      )
    end
  end

  defp compare_oracle_bytes(repository_name, oid, case_name, expected, actual) do
    Allowlist.compare(
      "corrupt/#{repository_name}/unchecked/#{case_name}",
      %{
        operation: :odb_read,
        fixture_repo: "corrupt/#{repository_name}",
        query: %{
          oid: oid,
          repo_level: true,
          source_fixture_repo: "sha1-basic-packed.git",
          verify_pack_checksums: false
        }
      },
      {:ok, expected},
      actual
    )
  end

  defp assert_correct_bytes_or_corruption(repository_name, oid, expected, {:ok, actual}) do
    compare_oracle_bytes(repository_name, oid, "pack-last", expected, {:ok, actual})
  end

  defp assert_correct_bytes_or_corruption(_repository_name, _oid, _expected, {:error, code}) do
    assert code in @corruption_codes
  end

  defp assert_correct_bytes_or_corruption(_repository_name, _oid, _expected, other) do
    flunk("expected oracle-equal bytes or a normalized corruption error, got: #{inspect(other)}")
  end

  defp normalize_read({:ok, %Object{data: data}}), do: {:ok, data}
  defp normalize_read({:error, %Error{code: code}}), do: {:error, code}
  defp normalize_read(other), do: {:unexpected, other}

  defp normalize_file_read({:ok, %{data: data}}), do: {:ok, data}
  defp normalize_file_read({:error, %Error{code: code}}), do: {:error, code}
  defp normalize_file_read(other), do: {:unexpected, other}

  defp fixture_oid(key) do
    value =
      @fixtures
      |> Path.join("OIDS")
      |> File.read!()
      |> :binary.split(<<"\n">>, [:global])
      |> Enum.find_value(fn line ->
        prefix = key <> "="
        prefix_size = byte_size(prefix)

        case line do
          <<candidate::binary-size(^prefix_size), value::binary>> when candidate == prefix ->
            value

          _other ->
            nil
        end
      end)

    value || flunk("fixture OIDS has no #{key} entry")
  end

  defp fixture(name), do: Path.join(@fixtures, name)
end
