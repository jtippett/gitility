defmodule Gitility.Milestone5aFetchTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Gitility.Differential.Oracle
  alias Gitility.Fetch
  alias Gitility.Fetch.Result
  alias Gitility.TestSupport.SmartHTTPServer
  alias Gitility.{Error, Repository, Runtime}

  @fixtures Path.expand("../fixtures/generated", __DIR__)
  @wildcard "+refs/heads/*:refs/remotes/origin/*"
  @maximum_timeout_ms 4_294_967_296

  setup do
    scratch =
      Path.join(
        System.tmp_dir!(),
        "gitility-m5a-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(scratch)
    on_exit(fn -> File.rm_rf!(scratch) end)
    %{scratch: scratch}
  end

  test "fresh and existing-empty destinations fetch wildcard refs with oracle parity", %{
    scratch: scratch
  } do
    {remote, url} = remote_fixture(scratch, "sha1-basic.git")
    destination = Path.join(scratch, "native.git")
    oracle_destination = Path.join(scratch, "oracle.git")

    assert {:ok, %Result{} = result} = Fetch.fetch(destination, url, [@wildcard])
    assert result.pack_received
    assert result.updated_refs == Enum.sort_by(result.updated_refs, & &1.name)
    assert File.regular?(Path.join(destination, "HEAD"))
    assert refs(destination) == oracle_refs(oracle_destination, url, [@wildcard])

    assert {:ok, repository} = Repository.open(destination)
    assert {:ok, snapshot} = Repository.snapshot(repository, {:ref, "refs/remotes/origin/main"})
    assert {:ok, _page} = Gitility.list_tree(snapshot, "")

    empty = Path.join(scratch, "empty.git")
    File.mkdir_p!(empty)
    assert {:ok, %Result{pack_received: true}} = Fetch.fetch(empty, url, [@wildcard])
    assert refs(empty) == refs(destination)
    assert File.dir?(remote)
  end

  test "non-repository non-empty and non-bare destinations are rejected", %{scratch: scratch} do
    {_remote, url} = remote_fixture(scratch, "sha1-basic.git")
    non_repository = Path.join(scratch, "not-a-repo")
    File.mkdir_p!(non_repository)
    File.write!(Path.join(non_repository, "payload"), "not git")

    assert {:error, %Error{code: :invalid_argument}} =
             Fetch.fetch(non_repository, url, [@wildcard])

    non_bare = Path.join(scratch, "worktree")
    git_command!(nil, ["init", non_bare])

    assert {:error, %Error{code: :invalid_argument}} =
             Fetch.fetch(non_bare, url, [@wildcard])
  end

  test "incremental fetch reports exact updates and an identical re-fetch is a clean no-op", %{
    scratch: scratch
  } do
    {remote, url} = remote_fixture(scratch, "sha1-basic.git")
    destination = Path.join(scratch, "incremental.git")
    assert {:ok, first} = Fetch.fetch(destination, url, [@wildcard])
    old = refs(destination)["refs/remotes/origin/main"]
    new = advance(remote, "refs/heads/main", "incremental")

    assert {:ok, %Result{pack_received: true, updated_refs: updated}} =
             Fetch.fetch(destination, url, [@wildcard])

    assert [
             %{
               name: "refs/remotes/origin/main",
               action: :fast_forward,
               old_oid: ^old,
               new_oid: ^new
             }
           ] =
             Enum.filter(updated, &(&1.name == "refs/remotes/origin/main"))

    assert {:ok, %Result{updated_refs: [], pack_received: false}} =
             Fetch.fetch(destination, url, [@wildcard])

    assert first.remote_ref_count > 0
  end

  test "prune uses reverse refspec matching and protects exact destinations", %{scratch: scratch} do
    {remote, url} = remote_fixture(scratch, "sha1-basic.git")
    oid = git!(remote, ["rev-parse", "refs/heads/main"])

    Enum.each(
      [
        "refs/heads/stale",
        "refs/heads/shared",
        "refs/archive/shared",
        "refs/heads/pinned",
        "refs/pull/17/head"
      ],
      &git!(remote, ["update-ref", &1, oid])
    )

    refspecs = [
      "+refs/heads/*:refs/remotes/origin/heads/*",
      "+refs/archive/*:refs/remotes/origin/archive/*",
      "+refs/pull/*/head:refs/pull/*",
      "+refs/heads/pinned:refs/remotes/origin/heads/stale/pinned"
    ]

    destination = Path.join(scratch, "prune.git")
    oracle_destination = Path.join(scratch, "prune-oracle.git")
    assert {:ok, _result} = Fetch.fetch(destination, url, refspecs)
    assert {:ok, _result} = Oracle.fetch(oracle_destination, url, refspecs)

    git!(remote, ["update-ref", "-d", "refs/heads/stale"])
    git!(remote, ["update-ref", "-d", "refs/heads/shared"])
    git!(remote, ["update-ref", "-d", "refs/pull/17/head"])

    assert {:ok, %Result{pruned_refs: pruned}} =
             Fetch.fetch(destination, url, refspecs, prune: true)

    assert {:ok, _result} = Oracle.fetch(oracle_destination, url, refspecs, prune: true)
    assert refs(destination) == refs(oracle_destination)
    assert "refs/remotes/origin/heads/stale" in pruned
    assert "refs/pull/17" in pruned
    assert refs(destination)["refs/remotes/origin/archive/shared"] == oid
    assert refs(destination)["refs/remotes/origin/heads/stale/pinned"] == oid

    no_prune = Path.join(scratch, "no-prune.git")
    git!(remote, ["update-ref", "refs/heads/transient", oid])
    assert {:ok, _result} = Fetch.fetch(no_prune, url, [@wildcard])
    git!(remote, ["update-ref", "-d", "refs/heads/transient"])
    assert {:ok, %Result{pruned_refs: []}} = Fetch.fetch(no_prune, url, [@wildcard])
    assert Map.has_key?(refs(no_prune), "refs/remotes/origin/transient")
  end

  test "conflicting refspec destinations are invalid arguments", %{scratch: scratch} do
    {remote, url} = remote_fixture(scratch, "sha1-basic.git")
    oid = git!(remote, ["rev-parse", "refs/heads/main"])
    git!(remote, ["update-ref", "refs/heads/shared", oid])
    git!(remote, ["update-ref", "refs/archive/shared", oid])

    conflicting = [
      "+refs/heads/*:refs/remotes/conflict/*",
      "+refs/archive/*:refs/remotes/conflict/*"
    ]

    assert {:error, %Error{code: :invalid_argument, message: message}} =
             Fetch.fetch(Path.join(scratch, "conflict.git"), url, conflicting)

    assert message =~ "refs/remotes/conflict/shared"
  end

  test "exact PR refspecs work and missing exact refs abort mixed requests before transfer", %{
    scratch: scratch
  } do
    {remote, url} = remote_fixture(scratch, "sha1-basic.git")
    oid = git!(remote, ["rev-parse", "refs/heads/main"])
    git!(remote, ["update-ref", "refs/pull/42/head", oid])
    destination = Path.join(scratch, "pull.git")
    pull = "+refs/pull/42/head:refs/pull/42"

    assert {:ok, %Result{updated_refs: [%{name: "refs/pull/42"}]}} =
             Fetch.fetch(destination, url, [pull])

    missing = "+refs/pull/404/head:refs/pull/404"

    assert {:error, %Error{code: :ref_not_found, message: message}} =
             Fetch.fetch(destination, url, [missing])

    assert message =~ missing
    before = refs(destination)
    _new = advance(remote, "refs/heads/main", "mixed-must-not-apply")

    assert {:error, %Error{code: :ref_not_found}} =
             Fetch.fetch(destination, url, [@wildcard, missing])

    assert refs(destination) == before
  end

  test "an empty remote is a successful no-pack result", %{scratch: scratch} do
    root = Path.join(scratch, "empty-root")
    remote = Path.join(root, "empty.git")
    File.mkdir_p!(root)
    git_command!(nil, ["init", "--bare", remote])
    url = start_server(root, "empty.git")

    assert {:ok,
            %Result{
              remote_ref_count: 0,
              updated_refs: [],
              rejected_refs: [],
              pack_received: false
            }} = Fetch.fetch(Path.join(scratch, "empty-destination.git"), url, [@wildcard])
  end

  test "non-fast-forward is reported, preserves the ref, receives a divergent pack, and removes keep",
       %{
         scratch: scratch
       } do
    {remote, url} = remote_fixture(scratch, "sha1-basic.git")
    destination = Path.join(scratch, "rejected.git")
    assert {:ok, _result} = Fetch.fetch(destination, url, [@wildcard])
    old = refs(destination)["refs/remotes/origin/main"]
    oracle_destination = Path.join(scratch, "rejected-oracle.git")
    File.cp_r!(destination, oracle_destination)
    divergent = divergent_commit(remote, "refs/heads/main")

    assert {:ok,
            %Result{
              pack_received: true,
              rejected_refs: [%{name: "refs/remotes/origin/main", reason: :non_fast_forward}]
            }} = Fetch.fetch(destination, url, ["refs/heads/main:refs/remotes/origin/main"])

    assert refs(destination)["refs/remotes/origin/main"] == old
    assert divergent != old
    assert Path.wildcard(Path.join(destination, "objects/pack/*.keep")) == []

    assert {:error, _git_rejection} =
             Oracle.fetch(
               oracle_destination,
               url,
               ["refs/heads/main:refs/remotes/origin/main"]
             )

    assert refs(oracle_destination)["refs/remotes/origin/main"] == old
  end

  test "static and provider authorization, bounded provider failures, retry, 403, and redirects",
       %{
         scratch: scratch
       } do
    root = copy_remote_root(scratch, "sha1-basic.git")
    protected = start_server(root, "sha1-basic.git", require_authorization: "Basic good")

    assert {:ok, %Result{}} =
             Fetch.fetch(Path.join(scratch, "static-good.git"), protected, [@wildcard],
               authorization: "Basic good"
             )

    assert {:error, %Error{code: :authentication_failed}} =
             Fetch.fetch(Path.join(scratch, "static-bad.git"), protected, [@wildcard],
               authorization: "Basic bad"
             )

    parent = self()

    provider = fn context ->
      send(parent, {:provider_context, context})
      {:ok, %{authorization: "Basic good"}}
    end

    assert {:ok, _result} =
             Fetch.fetch(Path.join(scratch, "provider.git"), protected, [@wildcard],
               credentials: provider
             )

    assert_receive {:provider_context, %{url: ^protected, host: "127.0.0.1", attempt: 1}}

    secret_error_provider = fn _context -> raise ArgumentError, "sekrit-provider-token" end

    assert {:error, %Error{code: :credentials_unavailable, cause: ArgumentError} = provider_error} =
             Fetch.fetch(Path.join(scratch, "provider-error.git"), protected, [@wildcard],
               credentials: secret_error_provider
             )

    refute inspect(provider_error, limit: :infinity) =~ "sekrit-provider-token"

    started = System.monotonic_time(:millisecond)

    provider_timeout_destination = Path.join(scratch, "provider-timeout.git")

    assert {:error, %Error{code: :credentials_unavailable, cause: :timeout}} =
             Fetch.fetch(provider_timeout_destination, protected, [@wildcard],
               credentials: fn _ -> Process.sleep(:infinity) end,
               timeout_ms: 100
             )

    assert System.monotonic_time(:millisecond) - started < 1_000

    assert {:ok, _result} =
             Fetch.fetch(provider_timeout_destination, protected, [@wildcard],
               authorization: "Basic good"
             )

    attempts = Agent.start_link(fn -> [] end) |> elem(1)

    retry_provider = fn %{attempt: attempt} ->
      Agent.update(attempts, &[attempt | &1])
      value = if attempt == 1, do: "Basic bad", else: "Basic good"
      {:ok, %{authorization: value}}
    end

    retry_dest = Path.join(scratch, "retry.git")
    retry_started = System.monotonic_time(:millisecond)

    assert {:ok, _result} =
             Fetch.fetch(retry_dest, protected, [@wildcard],
               credentials: retry_provider,
               retry_unauthorized: true,
               timeout_ms: 2_000
             )

    assert Agent.get(attempts, &Enum.reverse/1) == [1, 2]
    assert System.monotonic_time(:millisecond) - retry_started < 3_000

    forbidden = start_server(root, "sha1-basic.git", respond_status: 403)

    assert {:error, %Error{code: :network_error}} =
             Fetch.fetch(Path.join(scratch, "forbidden.git"), forbidden, [@wildcard])

    redirect = start_server(root, "sha1-basic.git", redirect: protected)

    assert {:error, %Error{code: :network_error, message: redirect_message}} =
             Fetch.fetch(Path.join(scratch, "redirect.git"), redirect, [@wildcard])

    assert redirect_message =~ "redirect"
  end

  test "one lease remains held throughout the authentication retry", %{scratch: scratch} do
    root = copy_remote_root(scratch, "sha1-basic.git")
    url = start_server(root, "sha1-basic.git", require_authorization: "Basic good")
    destination = Path.join(scratch, "retry-lease.git")
    parent = self()

    provider = fn
      %{attempt: 1} ->
        {:ok, %{authorization: "Basic bad"}}

      %{attempt: 2} ->
        send(parent, {:retry_provider_entered, self()})
        receive do: (:continue_retry -> {:ok, %{authorization: "Basic good"}})
    end

    task =
      Task.async(fn ->
        Fetch.fetch(destination, url, [@wildcard],
          credentials: provider,
          retry_unauthorized: true,
          timeout_ms: 2_000
        )
      end)

    assert_receive {:retry_provider_entered, provider_pid}, 1_500

    assert {:error, %Error{code: :busy}} =
             Fetch.fetch(destination, url, [@wildcard], authorization: "Basic good")

    send(provider_pid, :continue_retry)
    assert {:ok, _result} = Task.await(task, 2_500)
  end

  test "authorization never appears in errors, Logger output, or captured stderr", %{
    scratch: scratch
  } do
    root = copy_remote_root(scratch, "sha1-basic.git")
    secret = "sekrit123"
    authorization = "Basic " <> secret

    cases = [
      {start_server(root, "sha1-basic.git", require_authorization: "Basic good"), []},
      {"http://127.0.0.1:1/missing.git", []},
      {start_server(root, "sha1-basic.git", stall: :after_headers), [timeout_ms: 100]}
    ]

    cases
    |> Enum.with_index()
    |> Enum.each(fn {{url, extra}, index} ->
      parent = self()

      logger_output =
        capture_log(fn ->
          stderr =
            capture_io(:stderr, fn ->
              result =
                Fetch.fetch(
                  Path.join(scratch, "hygiene-#{index}.git"),
                  url,
                  [@wildcard],
                  Keyword.put(extra, :authorization, authorization)
                )

              send(parent, {:hygiene_result, result})
            end)

          send(parent, {:hygiene_stderr, stderr})
        end)

      assert_receive {:hygiene_result, {:error, %Error{} = error}}, 2_000
      assert_receive {:hygiene_stderr, stderr}, 2_000
      refute inspect(error, limit: :infinity) =~ secret
      refute logger_output =~ secret
      refute stderr =~ secret
    end)

    provider = fn _ -> {:error, %{authorization: authorization}} end

    assert {:error, %Error{} = provider_error} =
             Fetch.fetch(
               Path.join(scratch, "hygiene-provider.git"),
               hd(cases) |> elem(0),
               [@wildcard],
               credentials: provider
             )

    refute inspect(provider_error, limit: :infinity) =~ secret
  end

  test "a stalled socket respects the deadline and the worker remains reusable", %{
    scratch: scratch
  } do
    root = copy_remote_root(scratch, "sha1-basic.git")
    stalled = start_server(root, "sha1-basic.git", stall: :after_headers)
    plain = start_server(root, "sha1-basic.git")
    runtime = start_supervised!({Runtime, workers: 1, max_queue: 4})
    destination = Path.join(scratch, "stalled.git")
    started = System.monotonic_time(:millisecond)

    assert {:error, %Error{code: code}} =
             Fetch.fetch(destination, stalled, [@wildcard], runtime: runtime, timeout_ms: 150)

    assert code in [:network_error, :timeout]
    assert System.monotonic_time(:millisecond) - started < 1_500

    assert {:ok, _result} =
             eventually(fn -> Fetch.fetch(destination, plain, [@wildcard], runtime: runtime) end)
  end

  test "a truncated pack leaves refs untouched and the destination openable", %{scratch: scratch} do
    root = copy_remote_root(scratch, "sha1-history.git")
    plain = start_server(root, "sha1-history.git")
    truncated = start_server(root, "sha1-history.git", truncate_pack: 64)
    destination = Path.join(scratch, "truncated.git")
    assert {:ok, _result} = Fetch.fetch(destination, plain, [@wildcard])
    before = refs(destination)
    remote = Path.join(root, "sha1-history.git")
    _new = advance(remote, "refs/heads/main", "will-truncate")

    assert {:error, %Error{code: code}} = Fetch.fetch(destination, truncated, [@wildcard])
    assert code in [:network_error, :pack_checksum_mismatch, :malformed_object]
    assert refs(destination) == before
    assert {:ok, _repository} = Repository.open(destination)
  end

  test "timeout during a slow transfer is coherent and never tears a multi-ref transaction", %{
    scratch: scratch
  } do
    root = copy_remote_root(scratch, "sha1-history.git")
    remote = Path.join(root, "sha1-history.git")
    oid = git!(remote, ["rev-parse", "refs/heads/main"])
    git!(remote, ["update-ref", "refs/heads/second", oid])
    plain = start_server(root, "sha1-history.git")
    destination = Path.join(scratch, "cancel.git")
    assert {:ok, _result} = Fetch.fetch(destination, plain, [@wildcard])
    old = refs(destination)
    new = advance(remote, "refs/heads/main", "slow-new")
    git!(remote, ["update-ref", "refs/heads/second", new])
    slow = start_server(root, "sha1-history.git", delay_body: {32, 20})

    assert {:error, %Error{code: code}} =
             Fetch.fetch(destination, slow, [@wildcard], timeout_ms: 100)

    assert code in [:timeout, :cancelled, :network_error]
    after_timeout = refs(destination)
    old_pair = {old["refs/remotes/origin/main"], old["refs/remotes/origin/second"]}
    new_pair = {new, new}

    assert {after_timeout["refs/remotes/origin/main"],
            after_timeout["refs/remotes/origin/second"]} in [old_pair, new_pair]
  end

  test "single-flight survives timeout, caller death, submit failure, and seam raise", %{
    scratch: scratch
  } do
    root = copy_remote_root(scratch, "sha1-history.git")
    stalled = start_server(root, "sha1-history.git", stall: :after_headers)
    plain = start_server(root, "sha1-history.git")
    destination = Path.join(scratch, "single-flight.git")

    first = Task.async(fn -> Fetch.fetch(destination, stalled, [@wildcard], timeout_ms: 250) end)
    assert {:error, %Error{code: :busy}} = eventually_busy(destination, plain)
    assert {:error, %Error{code: code}} = Task.await(first, 1_500)
    assert code in [:timeout, :network_error]
    assert {:ok, _result} = eventually(fn -> Fetch.fetch(destination, plain, [@wildcard]) end)

    dying_destination = Path.join(scratch, "caller-death.git")

    caller =
      spawn(fn -> Fetch.fetch(dying_destination, stalled, [@wildcard], timeout_ms: 300) end)

    assert {:error, %Error{code: :busy}} = eventually_busy(dying_destination, plain)
    Process.exit(caller, :kill)
    assert {:error, %Error{code: :busy}} = Fetch.fetch(dying_destination, plain, [@wildcard])

    assert {:ok, _result} =
             eventually(fn -> Fetch.fetch(dying_destination, plain, [@wildcard]) end)

    {:ok, stopped_runtime} = Runtime.start_link(workers: 1)
    :ok = GenServer.stop(stopped_runtime)
    failed_destination = Path.join(scratch, "submit-failed.git")

    assert {:error, %Error{code: :cancelled}} =
             Fetch.fetch(failed_destination, plain, [@wildcard], runtime: stopped_runtime)

    assert {:ok, _result} = Fetch.fetch(failed_destination, plain, [@wildcard])

    seam_destination = Path.join(scratch, "seam-raise.git")

    assert_raise RuntimeError, "seam exploded", fn ->
      Fetch.fetch(seam_destination, stalled, [@wildcard],
        timeout_ms: 250,
        __after_submit__: fn -> raise "seam exploded" end
      )
    end

    assert {:error, %Error{code: :busy}} =
             Fetch.fetch(seam_destination, plain, [@wildcard])

    assert {:ok, _result} =
             eventually(fn -> Fetch.fetch(seam_destination, plain, [@wildcard]) end)
  end

  test "attempt-two submit/attach death window holds the lease for its grace period", %{
    scratch: scratch
  } do
    root = copy_remote_root(scratch, "sha1-basic.git")
    protected = start_server(root, "sha1-basic.git", require_authorization: "Basic good")
    plain = start_server(root, "sha1-basic.git")
    destination = Path.join(scratch, "death-window.git")
    parent = self()
    counter = Agent.start_link(fn -> 0 end) |> elem(1)

    seam = fn ->
      attempt = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

      if attempt == 2 do
        send(parent, :inside_attempt_two_window)
        receive do: (:never -> :ok)
      end
    end

    provider = fn %{attempt: attempt} ->
      value = if attempt == 1, do: "Basic bad", else: "Basic good"
      {:ok, %{authorization: value}}
    end

    caller =
      spawn(fn ->
        Fetch.fetch(destination, protected, [@wildcard],
          credentials: provider,
          retry_unauthorized: true,
          timeout_ms: 200,
          __after_submit__: seam
        )
      end)

    assert_receive :inside_attempt_two_window, 1_500
    Process.exit(caller, :kill)
    assert {:error, %Error{code: :busy}} = Fetch.fetch(destination, plain, [@wildcard])

    receive do
    after
      250 -> :ok
    end

    assert {:error, %Error{code: :busy}} = Fetch.fetch(destination, plain, [@wildcard])

    assert {:ok, _result} =
             eventually(fn -> Fetch.fetch(destination, plain, [@wildcard]) end, 2_000)
  end

  test "a Locks restart loses leases as documented", %{scratch: scratch} do
    root = copy_remote_root(scratch, "sha1-basic.git")
    stalled = start_server(root, "sha1-basic.git", stall: :after_headers)
    plain = start_server(root, "sha1-basic.git")
    destination = Path.join(scratch, "locks-restart.git")
    task = Task.async(fn -> Fetch.fetch(destination, stalled, [@wildcard], timeout_ms: 300) end)
    assert {:error, %Error{code: :busy}} = eventually_busy(destination, plain)
    old_locks = Process.whereis(Gitility.Fetch.Locks)
    Process.exit(old_locks, :kill)
    assert :ok = eventually(fn -> Process.whereis(Gitility.Fetch.Locks) != old_locks end)

    assert result = Fetch.fetch(Path.join(scratch, "post-restart.git"), plain, [@wildcard])
    assert match?({:ok, _}, result)
    _ = Task.await(task, 1_500)
  end

  test "fetch runtime isolation and explicit runtime selection", %{scratch: scratch} do
    root = copy_remote_root(scratch, "sha1-history.git")
    slow = start_server(root, "sha1-history.git", delay_body: {16, 20})
    destination = Path.join(scratch, "isolation.git")

    fetch_task =
      Task.async(fn -> Fetch.fetch(destination, slow, [@wildcard], timeout_ms: 400) end)

    assert {:error, %Error{code: :busy}} = eventually_busy(destination, slow)

    assert {:ok, repository} = Repository.open(Path.join(@fixtures, "sha1-basic.git"))
    assert {:ok, snapshot} = Repository.snapshot(repository, :head)
    started = System.monotonic_time(:millisecond)
    assert {:ok, _page} = Gitility.list_tree(snapshot, "")
    assert System.monotonic_time(:millisecond) - started < 300
    _ = Task.await(fetch_task, 1_500)

    remove_fetch_default()
    assert Process.whereis(Gitility.FetchRuntime) == nil
    explicit = start_supervised!({Runtime, workers: 1, max_queue: 4})

    assert {:ok, _result} =
             Fetch.fetch(
               Path.join(scratch, "explicit.git"),
               start_server(root, "sha1-history.git"),
               [@wildcard],
               runtime: explicit
             )

    assert Process.whereis(Gitility.FetchRuntime) == nil
  end

  test "fetch runtime thread budget has three residents and a two-fetch ceiling of nine", %{
    scratch: scratch
  } do
    remove_fetch_default()
    baseline = settled_thread_count(5_000)
    assert is_pid(Runtime.fetch_default())
    assert :ok = eventually(fn -> thread_count() == baseline + 3 end, 5_000)

    root = copy_remote_root(scratch, "sha1-history.git")
    slow = start_server(root, "sha1-history.git", delay_body: {16, 5})

    tasks =
      for index <- 1..2 do
        Task.async(fn ->
          Fetch.fetch(Path.join(scratch, "thread-budget-#{index}.git"), slow, [@wildcard],
            timeout_ms: 5_000
          )
        end)
      end

    peak = sample_thread_peak(tasks, baseline + 3, 5_000)
    assert peak <= baseline + 9

    assert Enum.all?(tasks, fn task ->
             match?({:ok, %Result{}}, Task.await(task, 6_000))
           end)

    assert :ok = eventually(fn -> thread_count() == baseline + 3 end, 5_000)
  end

  test "SHA-256 destinations reject SHA-1 remotes", %{scratch: scratch} do
    {_remote, url} = remote_fixture(scratch, "sha1-basic.git")
    destination = Path.join(scratch, "sha256.git")
    git_command!(nil, ["init", "--bare", "--object-format=sha256", destination])

    assert {:error, %Error{code: :unsupported_hash}} =
             Fetch.fetch(destination, url, [@wildcard])
  end

  test "validation is raise-free and rejects every specified invalid row", %{scratch: scratch} do
    valid = "https://example.invalid/repo.git"
    destination = Path.join(scratch, "validation.git")

    invalid_calls = [
      fn -> Fetch.fetch(destination, "ssh://example.invalid/repo", [@wildcard]) end,
      fn -> Fetch.fetch(destination, "file:///tmp/repo", [@wildcard]) end,
      fn -> Fetch.fetch(destination, valid, []) end,
      fn -> Fetch.fetch(destination, valid, ["refs/heads/main"]) end,
      fn -> Fetch.fetch(destination, valid, [String.duplicate("x", 4097) <> ":refs/x"]) end,
      fn -> Fetch.fetch(destination, valid, [<<255>>]) end,
      fn -> Fetch.fetch(<<255>>, valid, [@wildcard]) end,
      fn -> Fetch.fetch(destination, <<255>>, [@wildcard]) end,
      fn -> Fetch.fetch(destination, valid, [42]) end,
      fn -> Fetch.fetch(destination, valid, [@wildcard | :improper]) end,
      fn -> Fetch.fetch(destination, valid, ["::bad:refspec"]) end,
      fn -> Fetch.fetch(destination, valid, [@wildcard], unknown: true) end,
      fn -> Fetch.fetch(destination, valid, [@wildcard], %{}) end,
      fn -> Fetch.fetch(destination, valid, [@wildcard], [{:prune, true} | :improper]) end,
      fn -> Fetch.fetch(destination, valid, [@wildcard], timeout_ms: 0) end,
      fn -> Fetch.fetch(destination, valid, [@wildcard], timeout_ms: @maximum_timeout_ms + 1) end,
      fn -> Fetch.fetch(destination, valid, [@wildcard], authorization: "Basic x\r\ny") end,
      fn -> Fetch.fetch(destination, valid, [@wildcard], authorization: <<255>>) end,
      fn ->
        Fetch.fetch(destination, valid, [@wildcard],
          authorization: "Basic x",
          credentials: fn _ -> {:ok, %{authorization: "Basic y"}} end
        )
      end,
      fn -> Fetch.fetch(destination, valid, [@wildcard], retry_unauthorized: true) end,
      fn -> Fetch.fetch(destination, valid, [@wildcard], runtime: :default) end
    ]

    Enum.each(invalid_calls, fn call ->
      assert {:error, %Error{code: :invalid_argument}} = call.()
    end)
  end

  @tag :network
  test "env-gated real HTTPS smoke", %{scratch: scratch} do
    if System.get_env("GITILITY_TEST_NETWORK") == "1" do
      assert {:ok, %Result{remote_ref_count: count}} =
               Fetch.fetch(
                 Path.join(scratch, "https-smoke.git"),
                 "https://github.com/octocat/Hello-World.git",
                 [@wildcard],
                 timeout_ms: 120_000
               )

      assert count > 0
    else
      assert true
    end
  end

  defp remote_fixture(scratch, fixture) do
    root = copy_remote_root(scratch, fixture)
    {Path.join(root, fixture), start_server(root, fixture)}
  end

  defp copy_remote_root(scratch, fixture) do
    root = Path.join(scratch, "remote-root-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.cp_r!(Path.join(@fixtures, fixture), Path.join(root, fixture))
    root
  end

  defp start_server(root, repository, opts \\ []) do
    server =
      start_supervised!({SmartHTTPServer, Keyword.merge([project_root: root], opts)})

    SmartHTTPServer.url(server, repository)
  end

  defp oracle_refs(destination, url, refspecs) do
    assert {:ok, _output} = Oracle.fetch(destination, url, refspecs)
    refs(destination)
  end

  defp refs(repository) do
    assert {:ok, rows} = Oracle.refs(repository)
    Map.new(rows, &{&1.name, &1.object})
  end

  defp advance(repository, reference, message) do
    parent = git!(repository, ["rev-parse", reference])
    tree = git!(repository, ["rev-parse", "#{parent}^{tree}"])
    commit = git!(repository, ["commit-tree", tree, "-p", parent, "-m", message])
    git!(repository, ["update-ref", reference, commit])
    commit
  end

  defp divergent_commit(repository, reference) do
    old = git!(repository, ["rev-parse", reference])
    parent = git!(repository, ["rev-parse", "#{old}~1"])
    tree = git!(repository, ["rev-parse", "#{old}^{tree}"])
    commit = git!(repository, ["commit-tree", tree, "-p", parent, "-m", "divergent unseen"])
    git!(repository, ["update-ref", reference, commit])
    commit
  end

  defp git!(repository, arguments) do
    prefix = if repository, do: ["--git-dir", repository], else: []
    git_command!(repository, prefix ++ arguments)
  end

  defp git_command!(_repository, arguments) do
    environment =
      Oracle.git_environment() ++
        [
          {"GIT_AUTHOR_NAME", "Gitility Test"},
          {"GIT_AUTHOR_EMAIL", "gitility@example.invalid"},
          {"GIT_COMMITTER_NAME", "Gitility Test"},
          {"GIT_COMMITTER_EMAIL", "gitility@example.invalid"}
        ]

    case System.cmd("git", arguments, env: environment, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> raise "git #{Enum.join(arguments, " ")} failed #{status}: #{output}"
    end
  end

  defp eventually(fun, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    eventually_until(fun, deadline)
  end

  defp eventually_until(fun, deadline) do
    case fun.() do
      :ok ->
        :ok

      true ->
        :ok

      {:ok, _value} = success ->
        success

      result ->
        if System.monotonic_time(:millisecond) >= deadline do
          result
        else
          receive do
          after
            10 -> eventually_until(fun, deadline)
          end
        end
    end
  end

  defp eventually_busy(destination, url) do
    key = Path.expand(destination)

    case eventually(fn -> Map.has_key?(:sys.get_state(Gitility.Fetch.Locks), key) end) do
      :ok -> Fetch.fetch(destination, url, [@wildcard], timeout_ms: 100)
      other -> other
    end
  end

  defp remove_fetch_default do
    case Supervisor.terminate_child(Gitility.Supervisor, Gitility.FetchRuntime) do
      :ok ->
        :ok = Supervisor.delete_child(Gitility.Supervisor, Gitility.FetchRuntime)

      {:error, :not_found} ->
        :ok
    end
  end

  defp thread_count do
    {output, 0} = System.cmd("ps", ["-o", "nlwp=", "-p", System.pid()])
    output |> String.trim() |> String.to_integer()
  end

  defp settled_thread_count(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    settle_thread_count_until(thread_count(), 0, deadline)
  end

  defp settle_thread_count_until(count, stable_samples, deadline) do
    if stable_samples >= 20 or System.monotonic_time(:millisecond) >= deadline do
      count
    else
      receive do
      after
        50 ->
          next = thread_count()
          samples = if next == count, do: stable_samples + 1, else: 0
          settle_thread_count_until(next, samples, deadline)
      end
    end
  end

  defp sample_thread_peak(tasks, peak, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    sample_thread_peak_until(tasks, peak, deadline)
  end

  defp sample_thread_peak_until(tasks, peak, deadline) do
    peak = max(peak, thread_count())

    if Enum.all?(tasks, fn task -> not Process.alive?(task.pid) end) or
         System.monotonic_time(:millisecond) >= deadline do
      peak
    else
      receive do
      after
        10 -> sample_thread_peak_until(tasks, peak, deadline)
      end
    end
  end
end
