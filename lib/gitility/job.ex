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
  grace period, so sync callers only ever see `:timeout`.

  ## Ownership

  Jobs are owned by the calling process. Caller death cancels caller-owned
  jobs — abandonment is safe, nothing leaks — unless the job was started
  with `detach: true`. Cancellation sets an interrupt checked throughout
  walks, scans, diffs, blame, provider waits, and pack decoding.
  """

  alias Gitility.{Error, NotImplementedError}

  @typedoc "An opaque job handle."
  @opaque t :: %__MODULE__{ref: term(), owner: pid()}

  @enforce_keys [:ref, :owner]
  defstruct [:ref, :owner]

  @typedoc "Job lifecycle states."
  @type status :: :queued | :running | :completed | :failed | :cancelled

  @doc """
  Waits for the job's result. `:await_timeout` leaves the job running
  (`retryable: true`); all other errors are the job's own outcome.
  """
  @spec await(t(), timeout()) :: {:ok, term()} | {:error, Error.t()}
  def await(job, timeout \\ 30_000) do
    _ = {job, timeout}
    NotImplementedError.stub!(:"Job.await/2", "Milestone 2")
  end

  @doc """
  Cancels the job. Idempotent; a completed job is unaffected. Cancellation
  latency is bounded — native work checks the interrupt at every loop.
  """
  @spec cancel(t()) :: :ok
  def cancel(job) do
    _ = job
    NotImplementedError.stub!(:"Job.cancel/1", "Milestone 2")
  end

  @doc "The job's current lifecycle state."
  @spec status(t()) :: status()
  def status(job) do
    _ = job
    NotImplementedError.stub!(:"Job.status/1", "Milestone 2")
  end
end
