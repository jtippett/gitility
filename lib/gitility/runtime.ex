defmodule Gitility.Runtime do
  @moduledoc """
  An explicit, supervisable query runtime: one bounded native worker pool.

  Every expensive Gitility operation executes as a job on a runtime's
  Rust-owned worker threads — never on BEAM schedulers. A shared default
  runtime starts lazily with conservative defaults, so small callers need
  zero configuration:

    * `workers: max(System.schedulers_online() div 2, 1)`
    * `max_queue: 1_000`
    * `max_jobs_per_owner: 16`

  Tuning means starting a named runtime in your own supervision tree — the
  Finch/NimblePool convention, and the only shape that lets two subsystems
  with different latency profiles stop sharing a queue:

      children = [
        {Gitility.Runtime,
         name: MyApp.GitRuntime,
         workers: 8,
         max_queue: 500,
         max_jobs_per_owner: 16}
      ]

  Every root handle (`Gitility.Repository.open/2`, `Gitility.ODB.start_link/1`,
  `Gitility.ODB.from_objects/2`) accepts `runtime:` and defaults to the
  shared instance. Snapshots and jobs inherit the runtime of the store they
  came from; stores composed together must share one runtime, enforced at
  composition time with `:runtime_mismatch`.

  ## Backpressure

  Queue admission can refuse with `{:error, %Gitility.Error{code: :busy}}`
  carrying `retry_after_ms` in `details`. Per-owner ceilings keep one
  process from monopolizing a runtime; internal parallelism (search, diff)
  stays within a job's assigned permit count.
  """

  @typedoc "A runtime identifier: a registered name or pid."
  @type t :: atom() | pid()

  @typedoc false
  @type option ::
          {:name, atom()}
          | {:workers, pos_integer()}
          | {:max_queue, pos_integer()}
          | {:max_jobs_per_owner, pos_integer()}

  @doc """
  Starts a runtime instance. See the moduledoc for options.
  """
  @spec start_link([option()]) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    _ = opts
    Gitility.NotImplementedError.stub!(:"Runtime.start_link/1", "Milestone 2")
  end

  @doc false
  @spec child_spec([option()]) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc """
  The shared default runtime, started lazily on first use.
  """
  @spec default() :: t()
  def default do
    Gitility.NotImplementedError.stub!(:"Runtime.default/0", "Milestone 2")
  end
end
