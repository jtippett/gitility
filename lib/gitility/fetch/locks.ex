defmodule Gitility.Fetch.Locks do
  @moduledoc false

  use GenServer

  alias Gitility.{Error, Job, Native}

  @max_timer_ms 4_294_967_295

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @spec acquire(String.t(), pos_integer()) :: :ok | {:error, Error.t()}
  def acquire(key, timeout_ms) do
    GenServer.call(__MODULE__, {:acquire, key, self(), timeout_ms})
  end

  @spec pending_submit(String.t()) :: :ok
  def pending_submit(key), do: GenServer.call(__MODULE__, {:pending_submit, key, self()})

  @spec submission_failed(String.t()) :: :ok
  def submission_failed(key), do: GenServer.call(__MODULE__, {:submission_failed, key, self()})

  @spec attach(String.t(), Job.t()) :: :ok
  def attach(key, %Job{} = job), do: GenServer.call(__MODULE__, {:attach, key, self(), job})

  @spec release(String.t()) :: :ok
  def release(key), do: GenServer.call(__MODULE__, {:release, key, self()})

  @impl GenServer
  def init(_state), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:acquire, key, holder, timeout_ms}, _from, leases) do
    if Map.has_key?(leases, key) do
      error =
        Error.new(:busy, "fetch destination is busy", retryable: true, operation: :fetch)

      {:reply, {:error, error}, leases}
    else
      monitor = Process.monitor(holder)

      lease = %{
        generation: make_ref(),
        holder: holder,
        monitor: monitor,
        timeout_ms: timeout_ms,
        released: false,
        pending: false,
        jobs: %{}
      }

      {:reply, :ok, Map.put(leases, key, lease)}
    end
  end

  def handle_call({:pending_submit, key, holder}, _from, leases) do
    case holder_lease(leases, key, holder) do
      {:ok, lease} -> {:reply, :ok, Map.put(leases, key, %{lease | pending: true})}
      :stale -> {:reply, :ok, leases}
    end
  end

  def handle_call({:submission_failed, key, holder}, _from, leases) do
    case holder_lease(leases, key, holder) do
      {:ok, lease} ->
        leases = put_or_finish(leases, key, %{lease | pending: false})
        {:reply, :ok, leases}

      :stale ->
        {:reply, :ok, leases}
    end
  end

  def handle_call({:attach, key, holder, job}, _from, leases) do
    case holder_lease(leases, key, holder) do
      {:ok, lease} ->
        terminal = waiter_already_terminal?(job)

        jobs = Map.put(lease.jobs, job.id, %{job: job, terminal: terminal})
        lease = %{lease | pending: false, jobs: jobs}
        {:reply, :ok, put_or_finish(leases, key, lease)}

      :stale ->
        # A Locks restart deliberately loses its old leases. Ignore a late
        # transition from an old holder instead of disturbing a newly
        # admitted lease for the same path.
        {:reply, :ok, leases}
    end
  end

  def handle_call({:release, key, holder}, _from, leases) do
    case Map.fetch(leases, key) do
      {:ok, %{holder: ^holder} = lease} ->
        {:reply, :ok, put_or_finish(leases, key, %{lease | released: true})}

      :error ->
        {:reply, :ok, leases}

      {:ok, _lease_for_another_holder} ->
        {:reply, :ok, leases}
    end
  end

  @impl GenServer
  def handle_info({:gitility_job, id, :done}, leases) do
    leases =
      Enum.reduce(leases, leases, fn {key, lease}, acc ->
        case lease.jobs do
          %{^id => job_state} ->
            terminal = job_state.terminal or Job.status(job_state.job) in terminal_states()
            jobs = Map.put(lease.jobs, id, %{job_state | terminal: terminal})
            put_or_finish(acc, key, %{lease | jobs: jobs})

          _ ->
            acc
        end
      end)

    {:noreply, leases}
  end

  def handle_info({:DOWN, monitor, :process, holder, _reason}, leases) do
    now = System.monotonic_time(:millisecond)

    leases =
      Enum.reduce(leases, leases, fn
        {key, %{monitor: ^monitor, holder: ^holder} = lease}, acc ->
          Enum.each(lease.jobs, fn {_id, %{job: job, terminal: terminal}} ->
            if not terminal, do: Job.cancel(job)
          end)

          lease = %{lease | released: true}

          if lease.pending do
            deadline = now + 2 * lease.timeout_ms
            schedule_grace(key, lease.generation, deadline)
            Map.put(acc, key, Map.put(lease, :grace_deadline, deadline))
          else
            put_or_finish(acc, key, lease)
          end

        _, acc ->
          acc
      end)

    {:noreply, leases}
  end

  def handle_info({:pending_grace, key, generation, deadline}, leases) do
    case Map.fetch(leases, key) do
      {:ok, %{generation: ^generation, pending: true, released: true}} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:noreply, drop_lease(leases, key)}
        else
          schedule_grace(key, generation, deadline)
          {:noreply, leases}
        end

      _ ->
        {:noreply, leases}
    end
  end

  defp holder_lease(leases, key, holder) do
    case Map.fetch(leases, key) do
      {:ok, %{holder: ^holder} = lease} -> {:ok, lease}
      _ -> :stale
    end
  end

  defp terminal_states, do: [:completed, :failed, :cancelled]

  # An unexpected NIF return or exception must not crash the global lock
  # manager and drop every lease in the VM. Conservatively retaining the job
  # as non-terminal leaves release to the normal notification/holder/grace
  # rules.
  defp waiter_already_terminal?(job) do
    try do
      case Native.job_register_waiter(job.ref) do
        :terminal -> true
        :registered -> false
        _unexpected -> false
      end
    rescue
      _exception -> false
    catch
      _kind, _reason -> false
    end
  end

  defp put_or_finish(leases, key, lease) do
    if releasable?(lease) do
      drop_lease(leases, key)
    else
      Map.put(leases, key, lease)
    end
  end

  defp releasable?(lease) do
    lease.released and not lease.pending and
      Enum.all?(lease.jobs, fn {_id, job} -> job.terminal end)
  end

  defp drop_lease(leases, key) do
    case Map.pop(leases, key) do
      {nil, leases} ->
        leases

      {lease, leases} ->
        Process.demonitor(lease.monitor, [:flush])
        leases
    end
  end

  defp schedule_grace(key, generation, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    Process.send_after(
      self(),
      {:pending_grace, key, generation, deadline},
      min(remaining, @max_timer_ms)
    )
  end
end
