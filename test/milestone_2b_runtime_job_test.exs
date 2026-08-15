defmodule Gitility.Milestone2bRuntimeJobTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Gitility.{Error, Job, Limits, Native, Object, ODB, OID, Runtime, Snapshot}

  @entry_count 80_000
  @shutdown_join_timeout_ms 5_000
  @supervisor_shutdown_margin_ms 2_000

  setup_all do
    {large_objects, large_commit} = repository_objects(@entry_count, "x")
    {small_objects, small_commit} = repository_objects(1, "small\n")

    %{
      large_objects: large_objects,
      large_commit: large_commit,
      small_objects: small_objects,
      small_commit: small_commit
    }
  end

  test "named runtimes execute attached-store queries and expose moving counters", context do
    _runtime =
      start_runtime(
        name: Gitility.Milestone2bNamedRuntime,
        workers: 1,
        max_queue: 8,
        max_jobs_per_owner: 4
      )

    snapshot =
      snapshot(context.small_objects, context.small_commit, Gitility.Milestone2bNamedRuntime)

    before = Runtime.stats(Gitility.Milestone2bNamedRuntime)

    assert {:ok, page} = Gitility.list_tree(snapshot)
    assert length(page.items) == 1

    after_query = Runtime.stats(Gitility.Milestone2bNamedRuntime)
    assert after_query.submitted == before.submitted + 1
    assert after_query.completed == before.completed + 1
    assert after_query.active_jobs == 0
  end

  test "two runtimes isolate their queues", context do
    runtime_a = start_runtime(workers: 1, max_queue: 4, max_jobs_per_owner: 4)
    runtime_b = start_runtime(workers: 1, max_queue: 4, max_jobs_per_owner: 4)
    large = snapshot(context.large_objects, context.large_commit, runtime_a)
    small = snapshot(context.small_objects, context.small_commit, runtime_b)
    limits = large_limits()

    assert {:ok, slow_job} =
             Gitility.async_list_tree(large, "", limit: @entry_count, limits: limits)

    assert eventually(fn -> Job.status(slow_job) == :running end)

    started = System.monotonic_time(:millisecond)
    assert {:ok, page} = Gitility.list_tree(small)
    elapsed = System.monotonic_time(:millisecond) - started

    assert length(page.items) == 1
    assert elapsed < 2_000
    assert Runtime.stats(runtime_a).submitted >= 1
    # Snapshot.open is itself a runtime job as of the callback ODB milestone;
    # the attached runtime therefore completed snapshot-open + list-tree.
    assert Runtime.stats(runtime_b).completed == 2

    :ok = Job.cancel(slow_job)
  end

  test "runtime shutdown terminalizes in-flight jobs and joins cleanly", context do
    runtime = start_runtime(workers: 1, max_queue: 8, max_jobs_per_owner: 8)
    large = snapshot(context.large_objects, context.large_commit, runtime)
    limits = large_limits()

    jobs =
      for _ <- 1..3 do
        {:ok, job} = Gitility.async_list_tree(large, "", limit: @entry_count, limits: limits)
        job
      end

    assert eventually(fn -> Enum.any?(jobs, &(Job.status(&1) == :running)) end)
    :ok = stop_runtime(runtime)

    assert Enum.all?(jobs, &(Job.status(&1) == :cancelled))

    assert Enum.all?(jobs, fn job ->
             match?({:error, %Error{code: :cancelled}}, Job.await(job, 5_000))
           end)
  end

  test "default runtime startup races resolve to one instance" do
    runtimes =
      1..10
      |> Enum.map(fn _ -> Task.async(&Runtime.default/0) end)
      |> Enum.map(&Task.await(&1, 5_000))

    assert [runtime] = Enum.uniq(runtimes)
    assert Process.alive?(runtime)
  end

  test "five fast default-runtime crashes stay within the library supervisor intensity" do
    supervisor = Process.whereis(Gitility.Supervisor)
    assert is_pid(supervisor)

    runtime = Runtime.default()
    assert is_pid(runtime)

    Enum.reduce(1..5, runtime, fn _iteration, previous ->
      monitor = Process.monitor(previous)
      Process.exit(previous, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^previous, :killed}, 5_000

      assert eventually(fn ->
               case Process.whereis(Gitility.DefaultRuntime) do
                 pid when is_pid(pid) -> pid != previous
                 nil -> false
               end
             end)

      Process.whereis(Gitility.DefaultRuntime)
    end)

    assert Process.alive?(supervisor)
    assert Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :gitility end)
  end

  test "child specs outlast the configured native shutdown join window" do
    assert %{shutdown: 7_000} = Runtime.child_spec([])
    assert %{shutdown: 2_250} = Runtime.child_spec(shutdown_join_timeout_ms: 250)

    assert %{id: first_id} = Runtime.child_spec([])
    assert %{id: second_id} = Runtime.child_spec([])
    assert first_id != second_id
    assert %{id: Gitility.NamedRuntime} = Runtime.child_spec(name: Gitility.NamedRuntime)
  end

  test "a stopped application turns dead handles and default startup into errors", context do
    snapshot = snapshot(context.small_objects, context.small_commit, Runtime.default())

    try do
      assert :ok = Application.stop(:gitility)

      assert {:error, %Error{code: :cancelled, message: "runtime shut down"}} =
               Gitility.list_tree(snapshot)

      assert {:error,
              %Error{
                code: :cancelled,
                message: "gitility runtime supervisor is not running",
                retryable: true
              }} = ODB.from_objects(context.small_objects)
    after
      assert {:ok, _started} = Application.ensure_all_started(:gitility)
    end
  end

  test "terminate warning formatting is covered without an uncooperative BEAM task" do
    assert capture_log(fn ->
             :ok = Runtime.warn_if_detached_workers(0, nil)
           end) == ""

    assert capture_log(fn ->
             :ok = Runtime.warn_if_detached_workers(2, "injected detach reason")
           end) =~
             "Gitility runtime shutdown detached 2 worker(s): injected detach reason"
  end

  test "async list_tree matches sync and results are take-once", context do
    runtime = start_runtime(workers: 1)
    snapshot = snapshot(context.small_objects, context.small_commit, runtime)

    assert {:ok, expected} = Gitility.list_tree(snapshot)
    assert {:ok, job} = Gitility.async_list_tree(snapshot)
    assert {:ok, ^expected} = Job.await(job)

    assert {:error, %Error{code: :invalid_argument, message: "result already taken"}} =
             Job.await(job)

    refute_receive {:gitility_job, _, :done}
  end

  test "await timeout leaves a job running and a later await succeeds without stale messages",
       context do
    runtime = start_runtime(workers: 1)
    snapshot = snapshot(context.large_objects, context.large_commit, runtime)
    limits = large_limits()

    assert {:ok, job} =
             Gitility.async_list_tree(snapshot, "", limit: @entry_count, limits: limits)

    assert {:error, %Error{code: :await_timeout, retryable: true}} = Job.await(job, 0)
    assert Job.status(job) in [:queued, :running, :completed]
    assert {:ok, page} = Job.await(job, 30_000)
    assert length(page.items) == @entry_count
    job_id = job.id
    refute_receive {:gitility_job, ^job_id, :done}
  end

  @tag timeout: 30_000
  test "sync wrapper times out and cancels its owned job behind a 150-job backlog", context do
    runtime = start_runtime(workers: 1, max_queue: 200, max_jobs_per_owner: 200)
    snapshot = snapshot(context.large_objects, context.large_commit, runtime)
    backlog_limits = large_limits()

    assert {:ok, running} =
             Gitility.async_list_tree(snapshot, "",
               limit: @entry_count,
               limits: backlog_limits
             )

    assert eventually(fn -> Job.status(running) == :running end)

    backlog =
      for _ <- 1..150 do
        assert {:ok, job} =
                 Gitility.async_list_tree(snapshot, "",
                   limit: @entry_count,
                   limits: backlog_limits
                 )

        job
      end

    started = System.monotonic_time(:millisecond)

    assert {:error, %Error{code: :timeout, operation: :list_tree}} =
             Gitility.list_tree(snapshot, "",
               limit: @entry_count,
               limits: large_limits(300)
             )

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed <= 1_800

    # Only the deliberately retained blocker/backlog may remain active. The
    # synchronous wrapper's private job was cancelled instead of abandoned.
    assert Runtime.stats(runtime).active_jobs <= length(backlog) + 1

    Enum.each([running | backlog], &Job.cancel/1)
    assert eventually(fn -> Runtime.stats(runtime).active_jobs == 0 end, 10_000)
  end

  test "one queue activity tick expires a queued deadline while the worker stays busy", context do
    runtime = start_runtime(workers: 1, max_queue: 8, max_jobs_per_owner: 8)
    snapshot = snapshot(context.large_objects, context.large_commit, runtime)

    assert {:ok, blocker} =
             Gitility.async_list_tree(snapshot, "",
               limit: @entry_count,
               limits: large_limits()
             )

    assert eventually(fn -> Job.status(blocker) == :running end)

    assert {:ok, expired} =
             Gitility.async_list_tree(snapshot, "",
               limit: @entry_count,
               limits: large_limits(1)
             )

    Process.sleep(5)
    assert Job.status(blocker) == :running
    assert Job.status(expired) == :queued

    # Submission touches the queue and sweeps the expired FIFO head before
    # admitting its neighbour; the sole worker never reaches `expired`.
    assert {:ok, neighbour} =
             Gitility.async_list_tree(snapshot, "",
               limit: @entry_count,
               limits: large_limits()
             )

    assert {:error, %Error{code: :timeout}} = Job.await(expired, 1_000)
    assert Job.status(expired) == :failed
    assert Job.status(blocker) == :running

    Job.cancel(blocker)
    Job.cancel(neighbour)
  end

  test "cancellation and the job deadline publish their distinct errors", context do
    runtime = start_runtime(workers: 1, max_queue: 8)
    snapshot = snapshot(context.large_objects, context.large_commit, runtime)

    assert {:ok, cancelled} =
             Gitility.async_list_tree(snapshot, "",
               limit: @entry_count,
               limits: large_limits()
             )

    assert eventually(fn -> Job.status(cancelled) == :running end)
    assert :ok = Job.cancel(cancelled)
    assert {:error, %Error{code: :cancelled}} = Job.await(cancelled, 5_000)
    assert Job.status(cancelled) == :cancelled

    assert {:ok, timed_out} =
             Gitility.async_list_tree(snapshot, "",
               limit: @entry_count,
               limits: large_limits(1)
             )

    assert {:error, %Error{code: :timeout}} = Job.await(timed_out, 5_000)
    assert Job.status(timed_out) == :failed
  end

  test "detached jobs survive owner exit while ordinary jobs are cancelled", context do
    runtime = start_runtime(workers: 1, max_queue: 8, max_jobs_per_owner: 4)
    snapshot = snapshot(context.large_objects, context.large_commit, runtime)
    limits = large_limits()

    detached = submit_then_exit(snapshot, limit: @entry_count, limits: limits, detach: true)
    assert eventually(fn -> Job.status(detached) == :completed end, 30_000)
    assert {:ok, page} = Job.await(detached, 30_000)
    assert length(page.items) == @entry_count

    {:ok, blocker} = Gitility.async_list_tree(snapshot, "", limit: @entry_count, limits: limits)
    assert eventually(fn -> Job.status(blocker) == :running end)
    owned = submit_then_exit(snapshot, limit: @entry_count, limits: limits)
    assert eventually(fn -> Job.status(owned) == :cancelled end)
    assert {:error, %Error{code: :cancelled}} = Job.await(owned, 5_000)
    Job.cancel(blocker)
  end

  test "queue and per-owner admission return structured busy errors", context do
    queue_runtime = start_runtime(workers: 1, max_queue: 1, max_jobs_per_owner: 8)
    queue_snapshot = snapshot(context.large_objects, context.large_commit, queue_runtime)
    limits = large_limits()

    {:ok, running} =
      Gitility.async_list_tree(queue_snapshot, "", limit: @entry_count, limits: limits)

    assert eventually(fn -> Job.status(running) == :running end)

    {:ok, queued} =
      Gitility.async_list_tree(queue_snapshot, "", limit: @entry_count, limits: limits)

    assert {:error,
            %Error{
              code: :busy,
              retryable: true,
              details: %{reason: :queue_full, retry_after_ms: retry_after_ms}
            }} = Gitility.async_list_tree(queue_snapshot, "", limit: @entry_count, limits: limits)

    assert is_integer(retry_after_ms)

    queue_stats = Runtime.stats(queue_runtime)
    rejected_before = queue_stats.rejected
    submitted_before_retry = queue_stats.submitted

    sync_query =
      Task.async(fn ->
        Gitility.list_tree(queue_snapshot, "", limit: @entry_count, limits: limits)
      end)

    assert eventually(fn -> Runtime.stats(queue_runtime).rejected > rejected_before end)
    Job.cancel(queued)
    assert Job.status(queued) == :cancelled

    # Wait until the synchronous wrapper's one retry has claimed the freed
    # queue slot before releasing the worker. This removes the old race where
    # cancelling both jobs could let the retry observe either queue state.
    assert eventually(fn -> Runtime.stats(queue_runtime).submitted > submitted_before_retry end)
    Job.cancel(running)
    assert {:ok, _page} = Task.await(sync_query, 30_000)

    owner_runtime = start_runtime(workers: 1, max_queue: 4, max_jobs_per_owner: 1)
    owner_snapshot = snapshot(context.large_objects, context.large_commit, owner_runtime)

    {:ok, held} =
      Gitility.async_list_tree(owner_snapshot, "", limit: @entry_count, limits: limits)

    assert {:error, %Error{code: :busy, details: %{reason: :owner_ceiling}}} =
             Gitility.async_list_tree(owner_snapshot, "", limit: @entry_count, limits: limits)

    other_owner =
      submit_from_process(owner_snapshot, limit: @entry_count, limits: limits, detach: true)

    assert %Job{} = other_owner
    Job.cancel(held)
    Job.cancel(other_owner)
  end

  test "result bytes are rejected before a large term is created" do
    runtime = start_runtime(workers: 1)
    data = :binary.copy("z", 4_096)
    {objects, commit} = repository_objects(1, data)
    snapshot = snapshot(objects, commit, runtime)
    limits = large_limits(30_000, 128)

    assert {:ok, job} =
             Gitility.async_read_file(snapshot, "f00000",
               max_bytes: byte_size(data),
               limits: limits
             )

    assert {:error,
            %Error{
              code: :result_too_large,
              message: "job result exceeds max_result_bytes and has been discarded",
              retryable: false,
              details: %{limit: :max_result_bytes}
            }} = Job.await(job, 5_000)

    assert {:error,
            %Error{
              code: :invalid_argument,
              message: "result already taken"
            }} = Job.await(job, 0)
  end

  test "raw ShuttingDown submission maps to cancelled runtime shut down", context do
    runtime = start_runtime(workers: 1)
    snapshot = snapshot(context.small_objects, context.small_commit, runtime)
    assert {:ok, resource} = Runtime.resource(runtime)

    # Public shutdown stops the GenServer, so it cannot normally serve a
    # submission in CoreRuntime::ShuttingDown. Raw shutdown creates that state
    # solely to exercise the NIF boundary mapping.
    assert %{detached_workers: 0} = Native.runtime_shutdown(resource)

    assert {:error, %Error{code: :cancelled, message: "runtime shut down"}} =
             Gitility.async_list_tree(snapshot)
  end

  test "raw zero-worker normalization and concurrent shutdown report live reality" do
    baseline = Runtime.stats().thread_budget_used
    resource = Native.runtime_start(raw_runtime_config(0))
    stats = Native.runtime_stats(resource)

    assert stats.workers == 1
    assert stats.pump_alive == true

    results =
      1..4
      |> Task.async_stream(fn _ -> Native.runtime_shutdown(resource) end,
        ordered: false,
        max_concurrency: 4,
        timeout: 10_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, %{detached_workers: 0}}, &1))
    assert eventually(fn -> Runtime.stats().thread_budget_used == baseline end)
  end

  test "thread-budget exhaustion fails Runtime.start_link before spawning" do
    baseline = Runtime.stats().thread_budget_used
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      # Trapping exits makes the linked init failure inspectable as the exact
      # Runtime.start_link/1 error tuple without terminating the ExUnit case.
      assert {:error, {message, _stack}} = Runtime.start_link(workers: 10_000)

      assert is_binary(message)
      assert message =~ "gitility thread budget exhausted"
      assert Runtime.stats().thread_budget_used == baseline
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  test "GC-only teardown of five raw runtimes returns the thread budget" do
    baseline = Runtime.stats().thread_budget_used
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        hold_raw_runtimes_until_released(parent, raw_runtime_config(1), 5)
        :erlang.garbage_collect()
        send(parent, {:raw_gc_complete, self()})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:raw_runtimes_started, ^pid}, 5_000
    assert eventually(fn -> Runtime.stats().thread_budget_used >= baseline + 10 end)
    send(pid, :release)
    assert_receive {:raw_gc_complete, ^pid}, 10_000
    assert eventually(fn -> Runtime.stats().thread_budget_used == baseline end, 10_000)
    send(pid, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
  end

  test "completed job resources and owner keys return to zero outside the soak", context do
    runtime = start_runtime(workers: 1)
    snapshot = snapshot(context.small_objects, context.small_commit, runtime)
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          with {:ok, job} <- Gitility.async_list_tree(snapshot),
               {:ok, _page} <- Job.await(job, 5_000) do
            :ok
          end

        send(parent, {:one_job_finished, self(), result})
      end)

    assert_receive {:one_job_finished, ^pid, :ok}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000

    assert eventually(fn ->
             stats = Runtime.stats(runtime)
             stats.job_resources == 0 and stats.owner_count == 0
           end)
  end

  @tag :soak
  @tag timeout: 45_000
  # Incident regression contract: see
  # docs/reports/2026-08-14-kernel-panic-thread-leak.md. This remains excluded
  # until its first NIF-loading run is protected by the host thread watchdog;
  # when enabled, every stop uses the bounded assertion helper and the global
  # thread budget must return exactly to its pre-soak value.
  test "30 second mixed job soak reconciles counters across two runtimes", context do
    thread_budget_before_soak = Runtime.stats().thread_budget_used
    runtimes = [start_runtime(workers: 2), start_runtime(workers: 2)]

    snapshots =
      Enum.map(runtimes, &snapshot(context.large_objects, context.large_commit, &1))

    deadline = System.monotonic_time(:millisecond) + 30_000

    soak_loop(snapshots, deadline, 0)

    Enum.each(runtimes, fn runtime ->
      assert eventually(fn -> Runtime.stats(runtime).active_jobs == 0 end, 10_000)
      :erlang.garbage_collect()
      assert eventually(fn -> Runtime.stats(runtime).job_resources == 0 end, 10_000)
      stats = Runtime.stats(runtime)
      assert stats.queue_len == 0
      assert stats.running_count == 0
      assert stats.owner_count == 0
      assert stats.submitted == stats.completed + stats.failed + stats.cancelled
    end)

    Enum.each(runtimes, &stop_runtime/1)

    assert eventually(
             fn -> Runtime.stats().thread_budget_used == thread_budget_before_soak end,
             @shutdown_join_timeout_ms + @supervisor_shutdown_margin_ms
           ),
           "thread budget did not return to its pre-soak value: before=#{thread_budget_before_soak} " <>
             "after=#{Runtime.stats().thread_budget_used} " <>
             "(runtimes alive? #{inspect(Enum.map(runtimes, &Process.alive?/1))})"
  end

  defp soak_loop(snapshots, deadline, iteration) do
    if System.monotonic_time(:millisecond) >= deadline do
      :ok
    else
      jobs =
        for offset <- 0..7 do
          sequence = iteration + offset
          snapshot = Enum.at(snapshots, rem(sequence, length(snapshots)))

          submit_from_process(snapshot,
            limit: @entry_count,
            limits: large_limits(),
            detach: rem(sequence, 3) == 0
          )
        end

      jobs
      |> Enum.with_index(iteration)
      |> Enum.each(fn {job, sequence} ->
        if rem(sequence, 2) == 0, do: Job.cancel(job)
      end)

      Enum.each(jobs, fn job ->
        case Job.await(job, 30_000) do
          {:ok, _page} -> :ok
          {:error, %Error{code: code}} when code in [:cancelled, :timeout] -> :ok
        end

        assert Job.status(job) in [:completed, :failed, :cancelled]
      end)

      soak_loop(snapshots, deadline, iteration + length(jobs))
    end
  end

  defp submit_then_exit(snapshot, opts) do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        result = Gitility.async_list_tree(snapshot, "", opts)
        send(parent, {:submitted, self(), result})
      end)

    assert_receive {:submitted, ^pid, {:ok, job}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
    job
  end

  defp submit_from_process(snapshot, opts), do: submit_then_exit(snapshot, opts)

  # Runtimes are started under the ExUnit test supervisor, never linked to
  # the test process: a linked runtime cannot be stopped cleanly from
  # `on_exit` (the test process has already exited and its exit signal
  # reaches the runtime first, so `GenServer.stop` sees `:shutdown`) — the
  # old helper's `catch :exit` was hiding exactly that.
  #
  # Stopping goes through the supervisor too. `GenServer.stop` on a
  # `:permanent` supervised child is a RESTART, not a stop — the first Linux
  # soak run "leaked" exactly one restarted runtime's worth of thread-budget
  # slots that way (see docs/reports/2026-08-14-kernel-panic-thread-leak.md
  # for why the budget assertion exists). `stop_supervised!` terminates and
  # deletes the child through the real `child_spec/1` shutdown window from
  # the incident hardening — a wedged shutdown surfaces as an ExUnit failure
  # here instead of being swallowed.
  defp start_runtime(opts) do
    id = {Runtime, System.unique_integer([:positive])}
    pid = start_supervised!(Supervisor.child_spec({Runtime, opts}, id: id))
    Process.put({:runtime_child_id, pid}, id)
    pid
  end

  defp stop_runtime(runtime, _shutdown_join_timeout_ms \\ @shutdown_join_timeout_ms) do
    if Process.alive?(runtime) do
      id =
        Process.get({:runtime_child_id, runtime}) ||
          raise "runtime #{inspect(runtime)} was not started via start_runtime/1"

      ref = Process.monitor(runtime)
      :ok = stop_supervised!(id)
      assert_receive {:DOWN, ^ref, :process, ^runtime, _reason}, @supervisor_shutdown_margin_ms
    end

    :ok
  end

  defp snapshot(objects, commit_oid, runtime) do
    {:ok, odb} = ODB.from_objects(objects, runtime: runtime)
    {:ok, snapshot} = Snapshot.open(odb, commit_oid)
    snapshot
  end

  defp large_limits(timeout_ms \\ 30_000, max_result_bytes \\ 16 * 1024 * 1024) do
    Limits.new(
      timeout_ms: timeout_ms,
      max_tree_entries: @entry_count + 1,
      max_results: @entry_count + 1,
      max_result_bytes: max_result_bytes
    )
  end

  defp raw_runtime_config(workers) do
    %{
      workers: workers,
      max_queue: 8,
      max_jobs_per_owner: 8,
      shutdown_join_timeout_ms: @shutdown_join_timeout_ms
    }
  end

  defp hold_raw_runtimes_until_released(parent, config, count) do
    resources = for _ <- 1..count, do: Native.runtime_start(config)
    send(parent, {:raw_runtimes_started, self()})

    receive do
      :release -> length(resources)
    end
  end

  defp repository_objects(entry_count, blob_data) do
    blob_oid = object_oid(:blob, blob_data)

    tree_data =
      for index <- 0..(entry_count - 1), into: <<>> do
        name = "f" <> String.pad_leading(Integer.to_string(index), 5, "0")
        <<"100644 ", name::binary, 0, blob_oid.bytes::binary>>
      end

    tree_oid = object_oid(:tree, tree_data)

    commit_data =
      "tree #{OID.to_string(tree_oid)}\n" <>
        "author Gitility <gitility@example.invalid> 0 +0000\n" <>
        "committer Gitility <gitility@example.invalid> 0 +0000\n\n" <>
        "runtime fixture\n"

    commit_oid = object_oid(:commit, commit_data)

    objects = [
      %Object{oid: blob_oid, type: :blob, data: blob_data},
      %Object{oid: tree_oid, type: :tree, data: tree_data},
      %Object{oid: commit_oid, type: :commit, data: commit_data}
    ]

    {objects, commit_oid}
  end

  defp object_oid(type, data) do
    OID.new!(:sha1, :crypto.hash(:sha, "#{type} #{byte_size(data)}\0" <> data))
  end

  defp eventually(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    eventually_until(fun, deadline)
  end

  defp eventually_until(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(1)
        eventually_until(fun, deadline)
    end
  end
end
