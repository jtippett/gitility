defmodule Gitility.Differential.Sha256RefusalTest do
  use ExUnit.Case, async: true

  alias Gitility.{Error, OID, Repository, Snapshot}
  alias Gitility.Differential.Allowlist

  @moduletag :gitility_engine

  @fixtures Path.expand("../../fixtures/generated", __DIR__)
  @repository_name "sha256-basic.git"

  test "SHA-256 repositories open but snapshot execution refuses cleanly" do
    # The public API cannot expose read accounting. The core Rust test
    # crates/gitility-core/src/snapshot.rs::sha256_refusal_precedes_any_read
    # asserts budget.spent() == (0, 0, 0, 0) before this refusal.
    assert {:ok, repository} = Repository.open(fixture(@repository_name))
    head = fixture_oid("sha256_basic_head")

    actual =
      case Repository.snapshot(repository, {:oid, head}) do
        {:error, %Error{code: code}} ->
          {:error, code}

        {:ok, %Snapshot{} = snapshot} ->
          {:ok,
           %{
             commit_oid: OID.to_string(snapshot.commit_oid),
             tree_oid: OID.to_string(snapshot.tree_oid)
           }}

        other ->
          {:unexpected, other}
      end

    Allowlist.compare(
      "sha256/#{@repository_name}/snapshot-refusal",
      %{
        operation: :snapshot_open,
        fixture_repo: @repository_name,
        query: %{commit_oid: OID.to_string(head), hash: :sha256}
      },
      {:error, :unsupported_hash},
      actual
    )
  end

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

    OID.parse!(value)
  end

  defp fixture(name), do: Path.join(@fixtures, name)
end
