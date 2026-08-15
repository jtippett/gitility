defmodule Gitility.Milestone2bRuntimeJobTest do
  use ExUnit.Case, async: false

  alias Gitility.{Error, Job, Limits, Object, ODB, OID, Runtime, Snapshot}

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
    {:ok, runtime} =
      Runtime.start_link(
        name: Gitility.Milestone2bNamedRuntime,
        workers: 1,
        max_queue: 8,
        max_jobs_per_owner: 4
      )

    on_exit(fn -> stop_runtime(runtime) end)

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
    assert Runtime.stats(runtime_b).completed == 1

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

  test "child specs outlast the configured native shutdown join window" do
    assert %{shutdown: 7_000} = Runtime.child_spec([])
    assert %{shutdown: 2_250} = Runtime.child_spec(shutdown_join_timeout_ms: 250)
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

    rejected_before = Runtime.stats(queue_runtime).rejected

    sync_query =
      Task.async(fn ->
        Gitility.list_tree(queue_snapshot, "", limit: @entry_count, limits: limits)
      end)

    assert eventually(fn -> Runtime.stats(queue_runtime).rejected > rejected_before end)
    Job.cancel(running)
    Job.cancel(queued)
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

    assert {:error, %Error{code: :result_too_large, details: %{limit: :max_result_bytes}}} =
             Job.await(job, 5_000)
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
           )
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

  defp start_runtime(opts) do
    {:ok, runtime} = Runtime.start_link(opts)
    shutdown_join_timeout_ms =
      Keyword.get(opts, :shutdown_join_timeout_ms, @shutdown_join_timeout_ms)

    on_exit(fn -> stop_runtime(runtime, shutdown_join_timeout_ms) end)
    runtime
  end

  defp stop_runtime(runtime, shutdown_join_timeout_ms \\ @shutdown_join_timeout_ms) do
    if Process.alive?(runtime) do
      stopper = Task.async(fn -> GenServer.stop(runtime) end)

      assert :ok =
               Task.await(
                 stopper,
                 shutdown_join_timeout_ms + @supervisor_shutdown_margin_ms
               )
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
