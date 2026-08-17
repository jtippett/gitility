defmodule Gitility.M4a.ConformingRefBackend do
  @behaviour Gitility.RefDB.Backend

  alias Gitility.{Page, RefQuery}

  @impl true
  def init(:from_fixture),
    do: {:ok, Gitility.M4a.RefBackendConformanceTest.backend_refs()}

  def init(refs), do: {:ok, refs}

  @impl true
  def resolve(name, refs) do
    case Enum.find(refs, &(&1.name == name)) do
      nil -> {:ok, :not_found}
      ref -> {:ok, ref.target}
    end
  end

  @impl true
  def list(%RefQuery{} = query, refs) do
    items =
      refs
      |> Enum.filter(
        &(is_nil(query.prefix) or
            :binary.longest_common_prefix([&1.name, query.prefix]) == byte_size(query.prefix))
      )
      |> Enum.sort_by(& &1.name)
      |> Enum.take(query.limit)

    {:ok, struct!(Page, items: items, next_cursor: nil, truncated: false)}
  end
end

defmodule Gitility.M4a.ResolveOnlyRefBackend do
  @behaviour Gitility.RefDB.Backend

  @impl true
  def init(target), do: {:ok, target}

  @impl true
  def resolve("refs/heads/main", target), do: {:ok, target}
  def resolve(_name, _target), do: {:ok, :not_found}
end

defmodule Gitility.M4a.RefBackendConformanceTest do
  use Gitility.RefDB.Backend.Conformance,
    backend: Gitility.M4a.ConformingRefBackend,
    init_arg: :from_fixture,
    concurrency: 4

  alias Gitility.{OID, Ref, RefTarget}

  @fixtures Path.expand("../fixtures/generated", __DIR__)

  def backend_objects, do: []

  def backend_refs do
    oids =
      @fixtures
      |> Path.join("OIDS")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        [key, value] = String.split(line, "=", parts: 2)
        {key, value}
      end)

    for {name, key} <- [
          {"refs/heads/main", "sha1_refs_head"},
          {"refs/heads/previous", "sha1_refs_parent"}
        ] do
      oid = OID.parse!(Map.fetch!(oids, key))
      target = struct!(RefTarget, kind: :direct, oid: oid, symbolic_target: nil, peeled: nil)
      struct!(Ref, name: name, target: target)
    end
  end

  # The conformance init argument is intentionally symbolic so the backend
  # proves caller-runs-init receives the exact supplied term.
  def init_arg, do: :from_fixture
end

defmodule Gitility.M4a.MutableRefBackend do
  @behaviour Gitility.RefDB.Backend

  alias Gitility.{Page, Ref, RefQuery, RefTarget}

  @impl true
  def init(opts) do
    case opts do
      %{init_refs: refs} = config ->
        {:ok, agent} = Agent.start_link(fn -> %{refs: refs, resolves: 0} end)
        {:ok, Map.put(config, :agent, agent)}

      refs when is_map(refs) ->
        {:ok, agent} = Agent.start_link(fn -> %{refs: refs, resolves: 0} end)
        {:ok, %{agent: agent}}
    end
  end

  @impl true
  def resolve(name, %{mode: :block, observer: observer}) do
    send(observer, {:m4a_ref_resolve_blocked, self()})

    receive do
      :release_m4a_ref_resolve -> {:ok, :not_found}
    end
  end

  def resolve(_name, %{mode: {:malformed, target}}), do: {:ok, target}

  def resolve(name, %{agent: agent, mode: :alternating}) do
    Agent.get_and_update(agent, fn state ->
      targets = Map.fetch!(state.refs, name)
      target = Enum.at(targets, rem(state.resolves, length(targets)))
      {{:ok, target}, %{state | resolves: state.resolves + 1}}
    end)
  end

  def resolve(name, %{agent: agent}) do
    Agent.get_and_update(agent, fn state ->
      result = Map.get(state.refs, name, :not_found)
      {{:ok, result}, %{state | resolves: state.resolves + 1}}
    end)
  end

  @impl true
  def list(%RefQuery{}, %{mode: :empty_truncated}) do
    {:ok,
     struct!(Page,
       items: [],
       next_cursor: Base.url_encode64("loop", padding: false),
       truncated: true
     )}
  end

  def list(%RefQuery{} = query, %{agent: agent}) do
    refs = Agent.get(agent, & &1.refs)
    resume = decode_cursor(query.cursor)

    eligible =
      refs
      |> Enum.map(fn {name, target} -> struct!(Ref, name: name, target: target) end)
      |> Enum.filter(fn ref ->
        (is_nil(query.prefix) or
           :binary.match(ref.name, query.prefix) == {0, byte_size(query.prefix)}) and
          (is_nil(resume) or ref.name > resume)
      end)
      |> Enum.sort_by(& &1.name)

    items = Enum.take(eligible, query.limit)
    truncated = length(eligible) > length(items)
    next_cursor = if truncated, do: items |> List.last() |> Map.fetch!(:name) |> encode_cursor()
    {:ok, struct!(Page, items: items, next_cursor: next_cursor, truncated: truncated)}
  end

  @impl true
  def refresh(_state), do: :ok

  defp decode_cursor(nil), do: nil
  defp decode_cursor(cursor), do: Base.url_decode64!(cursor, padding: false)
  defp encode_cursor(name), do: Base.url_encode64(name, padding: false)

  def direct(oid),
    do: struct!(RefTarget, kind: :direct, oid: oid, symbolic_target: nil, peeled: nil)

  def symbolic(name),
    do: struct!(RefTarget, kind: :symbolic, oid: nil, symbolic_target: name, peeled: nil)
end

defmodule Gitility.Milestone4aRefsTest do
  use ExUnit.Case, async: false

  alias Gitility.{Error, OID, RefDB, RefQuery, Repository}
  alias Gitility.M4a.MutableRefBackend

  @fixtures Path.expand("../fixtures/generated", __DIR__)

  setup do
    {:ok, repository} = Repository.open(fixture("sha1-refs.git"))
    %{repository: repository, refs: repository.refs, oids: fixture_oids()}
  end

  test "every safe selector pins the expected commit", context do
    head = OID.parse!(context.oids.sha1_refs_head)

    for selector <- [
          {:oid, head},
          {:ref, "refs/heads/main"},
          {:branch, "main"},
          {:tag, "refs-chain"},
          :head
        ] do
      assert {:ok, snapshot} = Repository.snapshot(context.repository, selector)
      assert snapshot.commit_oid == head
    end

    assert {:error, %Error{code: :unsupported_operation, details: %{capability: :revspec}}} =
             Repository.snapshot(context.repository, {:revspec, "main~2"})
  end

  test "reftable ref-open failure preserves OID-only repository access", context do
    assert {:ok, repository} = Repository.open(fixture("sha1-reftable.git"))
    assert repository.refs == nil
    assert %Error{details: %{reason: stored_reason}} = repository.ref_error
    assert stored_reason =~ "reftable"

    assert {:ok, snapshot} =
             Repository.snapshot(repository, {:oid, context.oids.sha1_refs_head})

    assert snapshot.commit_oid == OID.parse!(context.oids.sha1_refs_head)

    for selector <- [
          {:ref, "refs/heads/main"},
          {:branch, "main"},
          {:tag, "v1.0.0"},
          :head
        ] do
      assert {:error,
              %Error{
                code: :unsupported_operation,
                details: %{capability: :refs, reason: reason}
              }} = Repository.snapshot(repository, selector)

      assert reason =~ "reftable"
    end
  end

  test "the four ref selectors name the missing refs capability", context do
    assert {:ok, odb_only} = Repository.from_stores(odb: context.repository.odb, refs: nil)

    for selector <- [
          {:ref, "refs/heads/main"},
          {:branch, "main"},
          {:tag, "refs-chain"},
          :head
        ] do
      assert {:error, %Error{code: :unsupported_operation, details: %{capability: :refs}}} =
               Repository.snapshot(odb_only, selector)
    end

    assert {:ok, snapshot} =
             Repository.snapshot(odb_only, {:oid, context.oids.sha1_refs_head})

    assert snapshot.commit_oid == OID.parse!(context.oids.sha1_refs_head)
  end

  test "annotated tag-to-tag chains peel only for the tag selector", context do
    assert {:ok, target} = RefDB.resolve(context.refs, "refs/tags/refs-chain")
    assert target.kind == :direct
    assert target.oid == OID.parse!(context.oids.sha1_refs_chain_tag)
    assert target.symbolic_target == nil
    assert target.peeled == OID.parse!(context.oids.sha1_refs_head)

    assert {:ok, snapshot} = Repository.snapshot(context.repository, {:tag, "refs-chain"})
    assert snapshot.commit_oid == target.peeled

    assert {:error, %Error{code: :not_a_commit}} =
             Repository.snapshot(context.repository, {:ref, "refs/tags/refs-chain"})
  end

  test "tag-to-tree, lightweight tag, unborn HEAD, traversal, and component edges", context do
    assert {:error, %Error{code: :not_a_commit}} =
             Repository.snapshot(context.repository, {:tag, "refs-tree"})

    assert {:ok, lightweight} =
             Repository.snapshot(context.repository, {:tag, "basic-lightweight"})

    assert lightweight.commit_oid == OID.parse!(context.oids.sha1_refs_parent)

    assert {:error, %Error{code: :malformed_ref}} =
             Repository.snapshot(context.repository, {:branch, "../main"})

    for name <- ["refs/heads/trail./x", "refs/heads/a.b.c", "refs/heads/bracket]name"] do
      assert {:ok, target} = RefDB.resolve(context.refs, name)
      assert target.kind == :direct
    end

    assert {:ok, unborn} = Repository.open(fixture("sha1-refs-unborn.git"))
    assert {:error, %Error{code: :ref_not_found}} = Repository.snapshot(unborn, :head)

    assert {:ok, cycle_repo} = Repository.open(fixture("sha1-refs-cycle.git"))

    assert {:error, %Error{code: :malformed_ref, details: %{reason: cycle}}} =
             Repository.snapshot(cycle_repo, {:branch, "cycle-a"})

    assert cycle =~ "refs/heads/cycle-a"
    assert cycle =~ "refs/heads/cycle-b"
  end

  test "symbolic cycles are malformed and name the cycle", context do
    refs = %{
      "refs/heads/a" => MutableRefBackend.symbolic("refs/heads/b"),
      "refs/heads/b" => MutableRefBackend.symbolic("refs/heads/a")
    }

    ref_db = start_ref_provider!(refs, runtime: context.repository.odb.runtime)
    assert {:ok, repository} = Repository.from_stores(odb: context.repository.odb, refs: ref_db)

    assert {:error, %Error{code: :malformed_ref, details: %{reason: reason}}} =
             Repository.snapshot(repository, {:branch, "a"})

    assert reason =~ "refs/heads/a"
    assert reason =~ "refs/heads/b"
  end

  test "provider crash wakes a blocked resolve with provider_down", context do
    ref_db =
      start_ref_provider!(
        %{init_refs: %{}, mode: :block, observer: self()},
        runtime: context.repository.odb.runtime,
        request_timeout: 10_000
      )

    waiter = Task.async(fn -> RefDB.resolve(ref_db, "refs/heads/main") end)
    assert_receive {:m4a_ref_resolve_blocked, _callback}, 1_000
    Process.exit(ref_db.provider, :kill)
    assert {:error, %Error{code: :provider_down, retryable: true}} = Task.await(waiter, 1_000)
  end

  test "provider symbolic chains are per-hop atomic while direct targets use one call", context do
    first = OID.parse!(context.oids.sha1_refs_head)
    second = OID.parse!(context.oids.sha1_refs_parent)

    symbolic_ref_db =
      start_ref_provider!(
        %{
          init_refs: %{
            "refs/heads/moving" => [MutableRefBackend.symbolic("refs/heads/target")],
            "refs/heads/target" => [direct(first), direct(second)]
          },
          mode: :alternating
        },
        runtime: context.repository.odb.runtime
      )

    assert {:ok, repository} =
             Repository.from_stores(odb: context.repository.odb, refs: symbolic_ref_db)

    assert {:ok, snapshot} = Repository.snapshot(repository, {:branch, "moving"})
    assert snapshot.commit_oid == second
    assert Agent.get(provider_agent(symbolic_ref_db), & &1.resolves) == 2

    direct_ref_db =
      start_ref_provider!(
        %{
          init_refs: %{"refs/heads/moving" => [direct(first), direct(second)]},
          mode: :alternating
        },
        runtime: context.repository.odb.runtime
      )

    assert {:ok, direct_repository} =
             Repository.from_stores(odb: context.repository.odb, refs: direct_ref_db)

    assert {:ok, direct_snapshot} = Repository.snapshot(direct_repository, {:branch, "moving"})
    assert direct_snapshot.commit_oid == first
    assert Agent.get(provider_agent(direct_ref_db), & &1.resolves) == 1
  end

  test "moving a ref never changes an existing snapshot, including async queries", context do
    first = OID.parse!(context.oids.sha1_refs_head)
    second = OID.parse!(context.oids.sha1_refs_parent)

    ref_db =
      start_ref_provider!(
        %{"refs/heads/moving" => direct(first)},
        runtime: context.repository.odb.runtime
      )

    assert {:ok, repository} = Repository.from_stores(odb: context.repository.odb, refs: ref_db)
    assert {:ok, snapshot} = Repository.snapshot(repository, {:branch, "moving"})
    assert {:ok, before} = Gitility.list_tree(snapshot, "", limit: 20)

    Agent.update(provider_agent(ref_db), fn state ->
      put_in(state.refs["refs/heads/moving"], direct(second))
    end)

    assert {:ok, job} = Gitility.async_list_tree(snapshot, "", limit: 20)
    assert {:ok, after_move} = Gitility.Job.await(job, 5_000)
    assert after_move.items == before.items
    assert after_move.next_cursor == before.next_cursor
    assert after_move.truncated == before.truncated
    assert snapshot.commit_oid == first

    assert {:ok, moved_snapshot} = Repository.snapshot(repository, {:branch, "moving"})
    assert moved_snapshot.commit_oid == second
  end

  test "local pagination reconstructs byte order and invalidates changed prefixes", context do
    {items, cursors} = collect_pages(context.refs, "refs/heads/page/", 17)
    assert length(items) == 55
    assert length(cursors) >= 3
    assert Enum.map(items, & &1.name) == Enum.sort(Enum.map(items, & &1.name))

    first_cursor = hd(cursors)

    assert {:error, %Error{code: :invalid_cursor}} =
             RefDB.list(context.refs,
               prefix: "refs/tags/",
               limit: 17,
               cursor: first_cursor
             )
  end

  test "local ref cursors cross repositories and reject forgery", context do
    assert {:ok, first} = RefDB.list(context.refs, prefix: "refs/heads/page/", limit: 10)
    assert first.next_cursor

    assert {:ok, detached} = Repository.open(fixture("sha1-refs-detached.git"))

    assert {:ok, resumed} =
             RefDB.list(detached.refs,
               prefix: "refs/heads/page/",
               limit: 10,
               cursor: first.next_cursor
             )

    assert hd(resumed.items).name > List.last(first.items).name

    decoded = Base.url_decode64!(first.next_cursor, padding: false)
    <<first_byte, rest::binary>> = decoded
    forged = Base.url_encode64(<<Bitwise.bxor(first_byte, 1), rest::binary>>, padding: false)

    assert {:error, %Error{code: :invalid_cursor}} =
             RefDB.list(context.refs,
               prefix: "refs/heads/page/",
               limit: 10,
               cursor: forged
             )
  end

  test "ref jobs have async parity and ref-page stats include peel reads", context do
    assert {:ok, resolve_job} = RefDB.async_resolve(context.refs, "refs/heads/main")
    assert {:ok, resolved} = Gitility.Job.await(resolve_job, 5_000)
    assert resolved.oid == OID.parse!(context.oids.sha1_refs_head)

    assert {:ok, list_job} =
             RefDB.async_list(context.refs, prefix: "refs/heads/page/", limit: 7)

    assert {:ok, page} = Gitility.Job.await(list_job, 5_000)
    assert length(page.items) == 7

    assert {:ok, loose_peel} =
             RefDB.list(context.refs, prefix: "refs/meta/loose-tag-object", limit: 5)

    assert loose_peel.stats.objects_read >= 2
    assert loose_peel.stats.objects_requested == loose_peel.stats.objects_read
    assert loose_peel.stats.decompressed_bytes > 0

    assert {:ok, packed_peel} =
             RefDB.list(context.refs, prefix: "refs/zz-tag-object", limit: 5)

    assert packed_peel.stats.objects_read == 0
    assert packed_peel.stats.decompressed_bytes == 0
  end

  test "strictly-greater provider pages stay coherent while refs mutate", context do
    first = OID.parse!(context.oids.sha1_refs_head)

    refs =
      for suffix <- ~w(a c e g), into: %{} do
        {"refs/heads/#{suffix}", direct(first)}
      end

    ref_db = start_ref_provider!(refs, runtime: context.repository.odb.runtime)
    assert {:ok, page1} = RefDB.list(ref_db, prefix: "refs/heads/", limit: 2)
    assert Enum.map(page1.items, & &1.name) == ~w(refs/heads/a refs/heads/c)

    Agent.update(provider_agent(ref_db), fn state ->
      state
      |> put_in([:refs, "refs/heads/b"], direct(first))
      |> put_in([:refs, "refs/heads/f"], direct(first))
    end)

    assert {:ok, page2} =
             RefDB.list(ref_db,
               prefix: "refs/heads/",
               limit: 3,
               cursor: page1.next_cursor
             )

    assert Enum.map(page2.items, & &1.name) ==
             ~w(refs/heads/e refs/heads/f refs/heads/g)
  end

  test "non-UTF-8 names round-trip in resolve, list, and DTO fields", context do
    name = <<"refs/heads/raw-", 255>>
    assert {:ok, target} = RefDB.resolve(context.refs, name)
    assert target.kind == :direct
    assert target.oid == OID.parse!(context.oids.sha1_refs_head)
    assert target.symbolic_target == nil
    assert target.peeled == nil

    assert {:ok, page} = RefDB.list(context.refs, prefix: <<"refs/heads/raw-">>, limit: 5)
    assert [ref] = page.items
    assert ref.name == name
    assert ref.target == target
    assert page.next_cursor == nil
    assert page.truncated == false

    assert {:ok, symbolic_page} =
             RefDB.list(context.refs, prefix: "refs/heads/symbolic-main", limit: 5)

    assert [symbolic_ref] = symbolic_page.items
    assert symbolic_ref.name == "refs/heads/symbolic-main"
    assert symbolic_ref.target.kind == :symbolic
    assert symbolic_ref.target.oid == nil
    assert symbolic_ref.target.symbolic_target == "refs/heads/main"
    assert symbolic_ref.target.peeled == nil
    assert symbolic_page.stats.entries_emitted == 1
    assert symbolic_page.warnings == []
  end

  test "malformed provider targets and hash-incompatible targets are rejected", context do
    invalid_symbolic =
      struct!(Gitility.RefTarget,
        kind: :symbolic,
        oid: nil,
        symbolic_target: "heads/not-full",
        peeled: nil
      )

    malformed =
      start_ref_provider!(
        %{init_refs: %{}, mode: {:malformed, invalid_symbolic}},
        runtime: context.repository.odb.runtime
      )

    assert {:error, %Error{code: :provider_protocol_error}} =
             RefDB.resolve(malformed, "refs/heads/main")

    sha256 = OID.new!(:sha256, :binary.copy(<<7>>, 32))

    incompatible =
      start_ref_provider!(
        %{"refs/heads/main" => direct(sha256)},
        runtime: context.repository.odb.runtime
      )

    assert {:ok, repository} =
             Repository.from_stores(odb: context.repository.odb, refs: incompatible)

    assert {:error, %Error{code: :hash_mismatch}} =
             Repository.snapshot(repository, {:branch, "main"})
  end

  test "resolve-only providers reject listing and treat missing refresh as a no-op", context do
    target = direct(OID.parse!(context.oids.sha1_refs_head))

    assert {:ok, supervisor} =
             RefDB.start_link(
               backend: {Gitility.M4a.ResolveOnlyRefBackend, target},
               runtime: context.repository.odb.runtime
             )

    assert {:ok, refs} = RefDB.handle(supervisor)
    assert {:error, %Error{code: :unsupported_operation}} = RefDB.list(refs)
    assert :ok = RefDB.refresh(refs)
  end

  test "provider listing rejects infinite-loop pages and oversized inbound cursors", context do
    empty =
      start_ref_provider!(
        %{init_refs: %{}, mode: :empty_truncated},
        runtime: context.repository.odb.runtime
      )

    assert {:error, %Error{code: :provider_protocol_error}} = RefDB.list(empty)

    ordinary = start_ref_provider!(%{}, runtime: context.repository.odb.runtime)
    oversized = :binary.copy(<<0>>, 4097) |> Base.url_encode64(padding: false)

    assert {:error, %Error{code: :provider_protocol_error}} =
             RefDB.list(ordinary, cursor: oversized)
  end

  defp collect_pages(refs, prefix, limit) do
    Stream.unfold({nil, []}, fn
      :done ->
        nil

      {cursor, previous_cursors} ->
        {:ok, page} =
          RefDB.list(refs, struct!(RefQuery, prefix: prefix, limit: limit, cursor: cursor))

        cursors =
          if page.next_cursor,
            do: previous_cursors ++ [page.next_cursor],
            else: previous_cursors

        {{page.items, cursors},
         if(page.next_cursor, do: {page.next_cursor, cursors}, else: :done)}
    end)
    |> Enum.to_list()
    |> Enum.reduce({[], []}, fn {items, cursors}, {all_items, _} ->
      {all_items ++ items, cursors}
    end)
  end

  defp start_ref_provider!(backend_opts, opts) do
    start_opts =
      [backend: {MutableRefBackend, backend_opts}]
      |> Keyword.merge(opts)

    {:ok, supervisor} = RefDB.start_link(start_opts)
    {:ok, refs} = RefDB.handle(supervisor)
    refs
  end

  defp provider_agent(ref_db) do
    :sys.get_state(ref_db.provider).backend_state.agent
  end

  defp direct(oid), do: MutableRefBackend.direct(oid)

  defp fixture(name), do: Path.join(@fixtures, name)

  defp fixture_oids do
    @fixtures
    |> Path.join("OIDS")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "git_version="))
    |> Map.new(fn line ->
      [key, value] = String.split(line, "=", parts: 2)
      {String.to_atom(key), value}
    end)
  end
end
