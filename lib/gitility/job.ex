defmodule Gitility.Job do
  @moduledoc """
  A handle to one asynchronous query.

  Every synchronous Gitility call is implemented over a job; the `async_*`
  variants return the job directly.

      {:ok, job} = Gitility.async_search(snapshot, "def handle_call", [])

      case Gitility.Job.await(job, 30_000) do
        {:ok, page} -> page
        {:error, %Gitility.Error{code: :await_timeout}} -> # still running
        {:error, %Gitility.Error{code: :timeout}} -> # budget expired, cancelled
      end

  ## The two timeouts

  `await/2` timing out returns `:await_timeout` and **leaves the job
  running** — await again, cancel, or abandon it. The job's own
  `timeout_ms` budget expiring cancels the work and completes the job as
  `:timeout`. The synchronous wrappers pass the budget and await it plus a
  grace period; if that await expires, they cancel their internal job, wait
  once more for terminal delivery, and return `:timeout`. Sync callers never
  see `:await_timeout` and never abandon their internal work.

  A result rejected as `:result_too_large` has already been removed from its
  take-once native slot and discarded. It is intentionally unrecoverable: the
  result byte limit belongs to the job and cannot be raised by awaiting again.

  ## Ownership

  Jobs are owned by the calling process. Caller death cancels caller-owned
  jobs — abandonment is safe, nothing leaks — unless the job was started
  with `detach: true`. Cancellation sets an interrupt checked throughout
  walks, scans, diffs, blame, provider waits, and pack decoding.
  """

  alias Gitility.{Error, Native, NativeSupport}

  @typedoc "An opaque job handle."
  @opaque t :: %__MODULE__{
            ref: term(),
            id: pos_integer(),
            runtime: Gitility.Runtime.t()
          }

  @enforce_keys [:ref, :id, :runtime]
  defstruct [:ref, :id, :runtime]

  @typedoc "Job lifecycle states."
  @type status :: :queued | :running | :completed | :failed | :cancelled

  @doc """
  Waits for the job's result. `:await_timeout` leaves the job running
  (`retryable: true`); all other errors are the job's own outcome.
  """
  @spec await(t(), timeout()) :: {:ok, term()} | {:error, Error.t()}
  def await(job, timeout \\ 5_000)

  def await(%__MODULE__{} = job, timeout)
      when timeout == :infinity or (is_integer(timeout) and timeout >= 0) do
    case Native.job_register_waiter(job.ref) do
      :terminal ->
        take(job)

      :registered ->
        receive do
          {:gitility_job, id, :done} when id == job.id ->
            flush_notifications(job.id)
            take(job)
        after
          timeout ->
            :ok = Native.job_deregister_waiter(job.ref)
            flush_notifications(job.id)

            {:error,
             Error.new(:await_timeout, "timed out awaiting job",
               retryable: true,
               operation: :job_await
             )}
        end
    end
  end

  def await(%__MODULE__{}, _timeout), do: raise(ArgumentError, "timeout must be non-negative")

  @doc """
  Cancels the job. Idempotent; a completed job is unaffected. Cancellation
  latency is bounded — native work checks the interrupt at every loop.
  """
  @spec cancel(t()) :: :ok
  def cancel(%__MODULE__{ref: ref}), do: Native.job_cancel(ref)

  @doc "The job's current lifecycle state."
  @spec status(t()) :: status()
  def status(%__MODULE__{ref: ref}), do: Native.job_state(ref)

  # Taking a terminal result also demonitor its original owner in the NIF.
  # The monitor has completed its abandonment-safety job at that point.
  defp take(job) do
    case Native.job_take_result(job.ref) do
      {:ok, payload} ->
        {:ok, NativeSupport.job_payload(payload)}

      {:error, error} ->
        {:error, NativeSupport.nif_error(error, :job)}

      :already_taken ->
        {:error, Error.new(:invalid_argument, "result already taken", operation: :job_await)}

      :not_terminal ->
        {:error,
         Error.new(:invalid_argument, "job notification arrived before terminal state",
           operation: :job_await
         )}
    end
  end

  defp flush_notifications(id) do
    receive do
      {:gitility_job, ^id, :done} -> flush_notifications(id)
    after
      0 -> :ok
    end
  end
end
