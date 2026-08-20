//! Bounded asynchronous execution for core Git queries.
//!
//! Each [`Runtime`] owns its worker threads and one hand-rolled bounded FIFO
//! queue. There is no ambient global runtime or configuration.
//!
//! # Cooperative deadlines
//!
//! The runtime deliberately has no timer thread and cannot interrupt arbitrary
//! Rust code. Queue activity (submission or dequeue) sweeps the expired run at
//! the FIFO head and fails those jobs with [`ErrorCode::Timeout`] without
//! invoking their tasks. A totally idle runtime still observes an expired
//! queued job only on its next queue touch; synchronous callers cover that
//! honest gap by cancelling their owned job when their await grace expires.
//! Once running, the task observes cancellation and its deadline at
//! [`Budget::check`] and charge points. Timeout latency is therefore bounded by
//! the longest gap between budget checks, not by a wall-clock interrupt.
//! Provider waits use the same deadline when callback-backed stores are added.

mod observer;
mod sync;
pub mod thread_budget;

use crate::blame::Blame;
use crate::budget::{Budget, BudgetLimits};
use crate::diff::Diff;
use crate::error::{Error, ErrorCode};
use crate::fetch::FetchResult;
use crate::file::FileRead;
use crate::log::LogPage;
use crate::object::{ObjectHeader, ObjectKind, Oid};
use crate::packfetch::HydrationStats;
use crate::refs::{RefPage, RefTarget};
use crate::search::SearchPage;
use crate::snapshot::Snapshot;
use crate::submodules::Submodule;
use crate::tree::TreePage;
pub use observer::TestObserver;
use std::collections::{BTreeMap, VecDeque};
use std::fmt;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool as StdAtomicBool, Ordering as StdOrdering};
use std::sync::Arc as StdArc;
use std::time::{Duration, Instant};
use sync::{Arc, AtomicBool, AtomicU64, AtomicU8, Condvar, Mutex, Ordering};
pub use thread_budget::BudgetExhausted;

/// Opaque identity assigned by the eventual NIF layer to a job owner.
pub type OwnerKey = u64;

/// Runtime worker and admission limits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RuntimeConfig {
    pub workers: usize,
    pub max_queue: usize,
    pub max_jobs_per_owner: usize,
    pub retry_after_ms: u64,
    /// Maximum wall-clock time given to all workers to exit during the join
    /// phase. A handle still running at the deadline is detached.
    pub shutdown_join_timeout_ms: u64,
}

impl Default for RuntimeConfig {
    fn default() -> Self {
        Self {
            workers: 4,
            max_queue: 1_000,
            max_jobs_per_owner: 16,
            retry_after_ms: 100,
            shutdown_join_timeout_ms: 5_000,
        }
    }
}

/// Stable result shapes retained by a completed job until result encoding.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum JobOutput {
    Diff(Diff),
    Tree(TreePage),
    Search(SearchPage),
    Log(LogPage),
    History(LogPage),
    Blame(Blame),
    File(FileRead),
    Submodules(Vec<Submodule>),
    Header(Option<ObjectHeader>),
    Object { kind: ObjectKind, data: Vec<u8> },
    ReadMany(ReadManyOutput),
    RefTarget(Option<RefTarget>),
    Refs(RefPage),
    Oid(Oid),
    Oids(Vec<Oid>),
    Boolean(bool),
    Snapshot(Snapshot),
    Hydration(HydrationStats),
    Fetch(FetchResult),
}

/// One ordered batch of object reads, retaining missing entries as `None` and
/// sharing immutable payload allocations with store caches until encoding.
pub type ReadManyOutput = Vec<(Oid, Option<(ObjectKind, StdArc<Vec<u8>>)>)>;

/// Consumed operation body stored by a job until a worker starts it.
pub type JobTask = Box<dyn FnOnce(&Budget) -> Result<JobOutput, Error> + Send + 'static>;

/// One consumed operation submitted to a [`Runtime`].
///
/// After the task returns, the runtime performs one final budget check before
/// publishing its output. If cancellation or the deadline trips after the
/// task's last internal check, the produced result is discarded and the job
/// publishes the corresponding error instead. A caller that successfully
/// cancels work does not receive the task's otherwise completed result.
pub struct JobSpec {
    pub task: JobTask,
    pub limits: BudgetLimits,
    pub timeout_ms: Option<u64>,
    pub observer: Arc<dyn JobObserver>,
}

/// Receives a job's one terminal transition.
///
/// The NIF layer implements this trait with an `OwnedEnv` completion message.
/// Callbacks normally run on a Gitility worker thread; immediate cancellation
/// of a queued job invokes it on the cancelling thread. [`Runtime::shutdown`]
/// and `Runtime`'s `Drop` implementation invoke observers for drained jobs on
/// their caller's thread.
///
/// Implementations must never block for long and must not re-enter
/// [`Runtime::shutdown`] or [`Runtime::submit`]. In particular, drain callbacks
/// run inside the shutdown protocol. [`Runtime::request_shutdown`] and
/// `Runtime`'s `Drop` implementation can also invoke observers on their caller
/// thread. Observer panics are contained by the runtime.
pub trait JobObserver: Send + Sync + 'static {
    fn completed(&self, job: &Job);
}

/// A job's externally visible state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum JobState {
    Queued = 0,
    Running = 1,
    Completed = 2,
    Failed = 3,
    Cancelled = 4,
}

impl JobState {
    pub const fn is_terminal(self) -> bool {
        matches!(self, Self::Completed | Self::Failed | Self::Cancelled)
    }

    fn from_raw(raw: u8) -> Self {
        match raw {
            0 => Self::Queued,
            1 => Self::Running,
            2 => Self::Completed,
            3 => Self::Failed,
            4 => Self::Cancelled,
            // The atomic is private and every write uses a variant above. A
            // conservative terminal value avoids turning impossible memory
            // corruption into a public panic.
            _ => Self::Cancelled,
        }
    }
}

/// Why admission returned [`SubmitError::Busy`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BusyReason {
    QueueFull,
    OwnerCeiling,
}

/// A submission rejected before a job was created.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SubmitError {
    Busy {
        reason: BusyReason,
        retry_after_ms: u64,
    },
    ShuttingDown,
}

impl fmt::Display for SubmitError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Busy { reason, .. } => write!(formatter, "runtime busy ({reason:?})"),
            Self::ShuttingDown => formatter.write_str("runtime is shutting down"),
        }
    }
}

impl std::error::Error for SubmitError {}

/// Snapshot of the runtime's monotonic telemetry counters.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RuntimeCounters {
    pub submitted: u64,
    pub completed: u64,
    pub failed: u64,
    pub cancelled: u64,
    pub rejected: u64,
    pub detached_workers: u64,
}

struct Counters {
    submitted: AtomicU64,
    completed: AtomicU64,
    failed: AtomicU64,
    cancelled: AtomicU64,
    rejected: AtomicU64,
    running: AtomicU64,
    detached_workers: AtomicU64,
}

impl Counters {
    fn new() -> Self {
        Self {
            submitted: AtomicU64::new(0),
            completed: AtomicU64::new(0),
            failed: AtomicU64::new(0),
            cancelled: AtomicU64::new(0),
            rejected: AtomicU64::new(0),
            running: AtomicU64::new(0),
            detached_workers: AtomicU64::new(0),
        }
    }

    /// Reads each field independently. This telemetry-grade view can be
    /// transiently inconsistent while jobs are changing state concurrently.
    fn snapshot(&self) -> RuntimeCounters {
        RuntimeCounters {
            submitted: self.submitted.load(Ordering::Acquire),
            completed: self.completed.load(Ordering::Acquire),
            failed: self.failed.load(Ordering::Acquire),
            cancelled: self.cancelled.load(Ordering::Acquire),
            rejected: self.rejected.load(Ordering::Acquire),
            detached_workers: self.detached_workers.load(Ordering::Acquire),
        }
    }
}

struct QueueState {
    queue: VecDeque<Arc<Job>>,
    active: BTreeMap<u64, Arc<Job>>,
    owners: BTreeMap<OwnerKey, usize>,
    shutting_down: bool,
}

struct Shared {
    config: RuntimeConfig,
    queue: Mutex<QueueState>,
    wake: Condvar,
    counters: Counters,
    next_job_id: AtomicU64,
    last_detach_reason: Mutex<Option<String>>,
}

impl Shared {
    fn new(config: RuntimeConfig) -> Self {
        Self {
            config,
            queue: Mutex::new(QueueState {
                queue: VecDeque::new(),
                active: BTreeMap::new(),
                owners: BTreeMap::new(),
                shutting_down: false,
            }),
            wake: Condvar::new(),
            counters: Counters::new(),
            next_job_id: AtomicU64::new(1),
            last_detach_reason: Mutex::new(None),
        }
    }

    #[cfg(not(all(test, loom)))]
    fn record_detached_worker(&self, worker_name: &str) {
        let reason = format!(
            "worker {worker_name} did not exit within shutdown_join_timeout_ms={}; detached",
            self.config.shutdown_join_timeout_ms
        );
        *sync::lock(&self.last_detach_reason) = Some(reason);
        self.counters
            .detached_workers
            .fetch_add(1, Ordering::Release);
    }

    fn record_terminal(&self, job: &Job, from: JobState, terminal: JobState) {
        if from == JobState::Running {
            self.counters.running.fetch_sub(1, Ordering::AcqRel);
        }
        match terminal {
            JobState::Completed => {
                self.counters.completed.fetch_add(1, Ordering::Release);
            }
            JobState::Failed => {
                self.counters.failed.fetch_add(1, Ordering::Release);
            }
            JobState::Cancelled => {
                self.counters.cancelled.fetch_add(1, Ordering::Release);
            }
            JobState::Queued | JobState::Running => {}
        }

        let mut state = sync::lock(&self.queue);
        if state.active.remove(&job.id).is_some() {
            if let Some(owner_jobs) = state.owners.get_mut(&job.owner) {
                *owner_jobs = owner_jobs.saturating_sub(1);
                if *owner_jobs == 0 {
                    state.owners.remove(&job.owner);
                }
            }
        }
    }

    fn begin_shutdown(&self) -> Vec<Arc<Job>> {
        let mut state = sync::lock(&self.queue);
        state.shutting_down = true;
        state.queue.clear();
        state.active.values().cloned().collect()
    }
}

fn take_expired_queue_head(state: &mut QueueState) -> Vec<Arc<Job>> {
    let mut expired = Vec::new();
    while state
        .queue
        .front()
        .is_some_and(|job| job.deadline_expired())
    {
        if let Some(job) = state.queue.pop_front() {
            expired.push(job);
        }
    }
    expired
}

fn publish_expired_jobs(expired: Vec<Arc<Job>>) {
    for job in expired {
        job.expire();
    }
}

/// A submitted operation and its take-once result slot.
pub struct Job {
    id: u64,
    owner: OwnerKey,
    state: AtomicU8,
    budget: Budget,
    task: Mutex<Option<JobTask>>,
    output: Mutex<Option<Result<JobOutput, Error>>>,
    observer: Arc<dyn JobObserver>,
    shared: Arc<Shared>,
}

impl Job {
    /// Per-runtime monotonically assigned identifier. The first ID is one.
    pub fn id(&self) -> u64 {
        self.id
    }

    pub fn owner(&self) -> OwnerKey {
        self.owner
    }

    pub fn state(&self) -> JobState {
        JobState::from_raw(self.state.load(Ordering::Acquire))
    }

    pub fn is_terminal(&self) -> bool {
        self.state().is_terminal()
    }

    /// Requests cooperative cancellation.
    ///
    /// A queued job is removed from the admission queue and transitions to
    /// `Cancelled` synchronously. A running job sets the same interrupt flag
    /// read by its budget and completes when it reaches the next check or
    /// charge point. The runtime also checks once after the task returns, so a
    /// result produced after the task's last internal check is discarded when
    /// that final check observes cancellation or an expired deadline. In that
    /// case, the cancelling caller receives the cancellation error rather than
    /// the produced result even if the task's work had already finished.
    pub fn cancel(&self) {
        self.budget.cancel_flag().store(true, StdOrdering::Release);

        if self.state.load(Ordering::Acquire) == JobState::Queued as u8 {
            let mut state = sync::lock(&self.shared.queue);
            if self.state.load(Ordering::Acquire) == JobState::Queued as u8 {
                if let Some(position) = state.queue.iter().position(|job| job.id == self.id) {
                    state.queue.remove(position);
                }
            }
        }

        if self.publish_terminal(
            JobState::Queued,
            JobState::Cancelled,
            Err(cancelled_error()),
        ) {
            self.discard_task();
        }
    }

    fn deadline_expired(&self) -> bool {
        self.budget.deadline_expired()
    }

    fn expire(&self) {
        if self.publish_terminal(JobState::Queued, JobState::Failed, Err(timeout_error())) {
            self.discard_task();
        }
    }

    /// Takes the terminal result once. Non-terminal jobs and later callers
    /// receive `None`.
    pub fn take_output(&self) -> Option<Result<JobOutput, Error>> {
        if !self.is_terminal() {
            return None;
        }
        sync::lock(&self.output).take()
    }

    /// Resource spend accumulated by this job's runtime-owned budget.
    pub fn spent(&self) -> (u64, u64, u64, u64) {
        self.budget.spent()
    }

    fn try_start(&self) -> bool {
        self.state
            .compare_exchange(
                JobState::Queued as u8,
                JobState::Running as u8,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_ok()
    }

    fn run(&self) {
        if let Err(error) = self.budget.check() {
            self.discard_task();
            self.finish_running(Err(error));
            return;
        }

        let task = sync::lock(&self.task).take();
        let result = match task {
            Some(task) => {
                // The closure is consumed and all captured state is dropped
                // inside this boundary. Nothing captured is observed again
                // after an unwind, so AssertUnwindSafe is appropriate here.
                // catch_unwind contains the panic, but the host's configured
                // panic hook still reports it; libraries must not replace it.
                match catch_unwind(AssertUnwindSafe(|| task(&self.budget))) {
                    Ok(Ok(output)) => self.budget.check().map(|()| output),
                    Ok(Err(error)) => Err(error),
                    Err(_) => Err(panic_error()),
                }
            }
            None => Err(Error::new(
                ErrorCode::BackendError,
                "job task was unavailable",
            )),
        };
        self.finish_running(result);
    }

    fn finish_running(&self, result: Result<JobOutput, Error>) {
        let terminal = match &result {
            Ok(_) => JobState::Completed,
            Err(error) if error.code == ErrorCode::Cancelled => JobState::Cancelled,
            Err(_) => JobState::Failed,
        };
        let _ = self.publish_terminal(JobState::Running, terminal, result);
    }

    fn publish_terminal(
        &self,
        from: JobState,
        terminal: JobState,
        result: Result<JobOutput, Error>,
    ) -> bool {
        let mut output = sync::lock(&self.output);
        if self.state.load(Ordering::Acquire) != from as u8 {
            return false;
        }

        let previous = output.take();
        *output = Some(result);
        if self
            .state
            .compare_exchange(
                from as u8,
                terminal as u8,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_err()
        {
            *output = previous;
            return false;
        }
        drop(output);

        self.shared.record_terminal(self, from, terminal);
        let _ = catch_unwind(AssertUnwindSafe(|| self.observer.completed(self)));
        true
    }

    fn discard_task(&self) {
        let task = sync::lock(&self.task).take();
        let _ = catch_unwind(AssertUnwindSafe(|| drop(task)));
    }
}

impl fmt::Debug for Job {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("Job")
            .field("id", &self.id)
            .field("owner", &self.owner)
            .field("state", &self.state())
            .finish()
    }
}

fn cancelled_error() -> Error {
    Error::new(ErrorCode::Cancelled, "operation cancelled")
}

fn timeout_error() -> Error {
    Error::new(ErrorCode::Timeout, "operation budget expired")
}

fn panic_error() -> Error {
    Error::new(
        ErrorCode::BackendError,
        "internal engine panic — this is a Gitility bug",
    )
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
enum ShutdownPhase {
    NotStarted = 0,
    InProgress = 1,
    Complete = 2,
}

/// An explicit bounded worker pool.
///
/// Dropping the last runtime handle only requests shutdown and never blocks or
/// joins. Worker handles detach when the value is destroyed and their
/// process-wide budget reservations remain held until the threads actually
/// exit. Callers that require the bounded join guarantee must invoke
/// [`Runtime::shutdown`] explicitly.
pub struct Runtime {
    shared: Arc<Shared>,
    workers: Mutex<Vec<sync::thread::JoinHandle<()>>>,
    worker_ids: Mutex<Vec<sync::thread::ThreadId>>,
    shutdown_phase: AtomicU8,
    shutdown_request_complete: AtomicBool,
    shutdown_join_claimed: AtomicBool,
    shutdown_wait: Mutex<()>,
    shutdown_wake: Condvar,
}

impl Runtime {
    /// Starts an independent worker pool.
    ///
    /// Since the infallible API cannot report an invalid zero-worker
    /// configuration, `workers: 0` is normalized to one worker so accepted
    /// jobs can never be stranded.
    ///
    /// # Panics
    ///
    /// Panics if the process-wide [`thread_budget`] cannot admit the
    /// requested workers. Callers that must handle exhaustion gracefully —
    /// the NIF layer in particular — use [`Runtime::try_start`].
    pub fn start(config: RuntimeConfig) -> Arc<Self> {
        match Self::try_start(config) {
            Ok(runtime) => runtime,
            Err(error) => panic!("gitility thread budget exhausted: {error}"),
        }
    }

    /// Starts an independent worker pool if the process-wide
    /// [`thread_budget`] admits `config.workers` more threads; otherwise
    /// reports the budget state without spawning anything.
    pub fn try_start(config: RuntimeConfig) -> Result<Arc<Self>, BudgetExhausted> {
        Self::start_with_budget(config, thread_budget::global())
    }

    pub(crate) fn start_with_budget(
        config: RuntimeConfig,
        budget: &'static thread_budget::ThreadBudget,
    ) -> Result<Arc<Self>, BudgetExhausted> {
        let worker_count = config.workers.max(1);
        let mut reservation = budget.try_reserve(worker_count)?;

        let runtime = Arc::new(Self {
            shared: Arc::new(Shared::new(config)),
            workers: Mutex::new(Vec::new()),
            worker_ids: Mutex::new(Vec::new()),
            shutdown_phase: AtomicU8::new(ShutdownPhase::NotStarted as u8),
            shutdown_request_complete: AtomicBool::new(false),
            shutdown_join_claimed: AtomicBool::new(false),
            shutdown_wait: Mutex::new(()),
            shutdown_wake: Condvar::new(),
        });

        let mut spawn_failed = false;
        for worker_index in 0..worker_count {
            let shared = Arc::clone(&runtime.shared);
            // Each worker owns exactly its slot, releasing it when the loop
            // returns — including by unwind — so joins are never required
            // for the budget to recover.
            let worker_reservation = reservation.split_one();
            let name = format!("gitility-worker-{worker_index}");
            match sync::thread::Builder::new().name(name).spawn(move || {
                let _budget_reservation = worker_reservation;
                worker_loop(shared)
            }) {
                Ok(handle) => {
                    sync::lock(&runtime.worker_ids).push(handle.thread().id());
                    sync::lock(&runtime.workers).push(handle);
                }
                Err(_) => {
                    spawn_failed = true;
                    break;
                }
            }
        }
        drop(reservation);
        if spawn_failed {
            runtime.shutdown();
        }
        Ok(runtime)
    }

    /// Admits one job or returns bounded-backpressure metadata.
    pub fn submit(&self, owner: OwnerKey, spec: JobSpec) -> Result<Arc<Job>, SubmitError> {
        let submitted_at = Instant::now();
        let mut state = loop {
            let mut state = sync::lock(&self.shared.queue);
            let expired = take_expired_queue_head(&mut state);
            if expired.is_empty() {
                break state;
            }
            drop(state);
            publish_expired_jobs(expired);
        };
        if state.shutting_down {
            self.shared
                .counters
                .rejected
                .fetch_add(1, Ordering::Release);
            return Err(SubmitError::ShuttingDown);
        }

        if state.owners.get(&owner).copied().unwrap_or(0) >= self.shared.config.max_jobs_per_owner {
            self.shared
                .counters
                .rejected
                .fetch_add(1, Ordering::Release);
            return Err(SubmitError::Busy {
                reason: BusyReason::OwnerCeiling,
                retry_after_ms: self.shared.config.retry_after_ms,
            });
        }
        if state.queue.len() >= self.shared.config.max_queue {
            self.shared
                .counters
                .rejected
                .fetch_add(1, Ordering::Release);
            return Err(SubmitError::Busy {
                reason: BusyReason::QueueFull,
                retry_after_ms: self.shared.config.retry_after_ms,
            });
        }

        let JobSpec {
            task,
            limits,
            timeout_ms,
            observer,
        } = spec;
        // `Instant` cannot represent every `u64`-millisecond offset;
        // unrepresentable deadlines are deliberately treated as unbounded.
        let deadline = timeout_ms
            .and_then(|milliseconds| submitted_at.checked_add(Duration::from_millis(milliseconds)));
        let cancelled = StdArc::new(StdAtomicBool::new(false));
        let id = self.shared.next_job_id.fetch_add(1, Ordering::Relaxed);
        let job = Arc::new(Job {
            id,
            owner,
            state: AtomicU8::new(JobState::Queued as u8),
            budget: Budget::new(limits, deadline, cancelled),
            task: Mutex::new(Some(task)),
            output: Mutex::new(None),
            observer,
            shared: Arc::clone(&self.shared),
        });
        state.active.insert(id, Arc::clone(&job));
        *state.owners.entry(owner).or_insert(0) += 1;
        state.queue.push_back(Arc::clone(&job));
        self.shared
            .counters
            .submitted
            .fetch_add(1, Ordering::Release);
        drop(state);
        self.shared.wake.notify_one();
        Ok(job)
    }

    /// Requests cancellation of all queued and running jobs and wakes the pool.
    ///
    /// From a non-worker thread, this method gives workers up to
    /// [`RuntimeConfig::shutdown_join_timeout_ms`] to exit. Workers still
    /// running at that deadline are detached and counted in
    /// [`RuntimeCounters::detached_workers`], after which shutdown is marked
    /// complete so external callers cannot wedge. A detached worker retains
    /// its process-wide thread-budget reservation until its thread actually
    /// exits; that slot is the honest cost of uncooperative work. Concurrent
    /// external callers wait for the same bounded completion point. From one
    /// of this runtime's own workers, this is deliberately only a shutdown
    /// request; a later explicit external call completes the bounded phase.
    ///
    /// Observers for jobs drained from the queue run synchronously on this
    /// method's caller thread, inside the shutdown protocol. Observers must not
    /// re-enter this method or [`Runtime::submit`].
    pub fn shutdown(&self) {
        let called_from_worker = self.is_worker_thread();
        self.request_shutdown();

        if called_from_worker
            || self.shutdown_phase.load(Ordering::Acquire) == ShutdownPhase::Complete as u8
        {
            return;
        }
        self.wait_for_or_finish_shutdown();
    }

    /// Requests cancellation and draining without waiting for or joining any
    /// worker thread.
    ///
    /// This operation is idempotent and safe from every thread, including a
    /// runtime worker or host scheduler. Workers wake and exit on their own;
    /// their thread-budget reservations are released by the worker closures.
    /// Use [`Runtime::shutdown`] when the caller needs the bounded join
    /// guarantee.
    pub fn request_shutdown(&self) {
        if self
            .shutdown_phase
            .compare_exchange(
                ShutdownPhase::NotStarted as u8,
                ShutdownPhase::InProgress as u8,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_ok()
        {
            let jobs = self.shared.begin_shutdown();
            self.shared.wake.notify_all();
            for job in jobs {
                job.cancel();
            }
            self.publish_shutdown_request();
        }
    }

    pub fn queue_len(&self) -> usize {
        sync::lock(&self.shared.queue).queue.len()
    }

    /// Number of worker threads successfully spawned for this runtime.
    ///
    /// This reports the normalized one worker for a `workers: 0`
    /// configuration and remains stable after shutdown.
    pub fn worker_count(&self) -> usize {
        sync::lock(&self.worker_ids).len()
    }

    pub fn running_count(&self) -> u64 {
        self.shared.counters.running.load(Ordering::Acquire)
    }

    pub fn counters(&self) -> RuntimeCounters {
        self.shared.counters.snapshot()
    }

    /// The most recently recorded one-line reason for detaching a worker.
    pub fn last_detach_reason(&self) -> Option<String> {
        sync::lock(&self.shared.last_detach_reason).clone()
    }

    pub fn submitted_count(&self) -> u64 {
        self.shared.counters.submitted.load(Ordering::Acquire)
    }

    pub fn completed_count(&self) -> u64 {
        self.shared.counters.completed.load(Ordering::Acquire)
    }

    pub fn failed_count(&self) -> u64 {
        self.shared.counters.failed.load(Ordering::Acquire)
    }

    pub fn cancelled_count(&self) -> u64 {
        self.shared.counters.cancelled.load(Ordering::Acquire)
    }

    pub fn rejected_count(&self) -> u64 {
        self.shared.counters.rejected.load(Ordering::Acquire)
    }

    fn is_worker_thread(&self) -> bool {
        let current = sync::thread::current().id();
        sync::lock(&self.worker_ids).contains(&current)
    }

    fn publish_shutdown_request(&self) {
        let _wait = sync::lock(&self.shutdown_wait);
        self.shutdown_request_complete
            .store(true, Ordering::Release);
        self.shutdown_wake.notify_all();
    }

    fn wait_for_or_finish_shutdown(&self) {
        let mut wait = sync::lock(&self.shutdown_wait);
        loop {
            if self.shutdown_phase.load(Ordering::Acquire) == ShutdownPhase::Complete as u8 {
                return;
            }
            if self.shutdown_request_complete.load(Ordering::Acquire)
                && self
                    .shutdown_join_claimed
                    .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                    .is_ok()
            {
                drop(wait);
                self.finish_shutdown();
                return;
            }
            wait = sync::wait(&self.shutdown_wake, wait);
        }
    }

    fn finish_shutdown(&self) {
        let workers: Vec<_> = sync::lock(&self.workers).drain(..).collect();
        self.join_workers_bounded(workers);

        let _wait = sync::lock(&self.shutdown_wait);
        self.shutdown_phase
            .store(ShutdownPhase::Complete as u8, Ordering::Release);
        self.shutdown_wake.notify_all();
    }

    #[cfg(not(all(test, loom)))]
    fn join_workers_bounded(&self, workers: Vec<sync::thread::JoinHandle<()>>) {
        let timeout = Duration::from_millis(self.shared.config.shutdown_join_timeout_ms);
        let started = Instant::now();
        let mut pending = workers;

        loop {
            let mut still_running = Vec::with_capacity(pending.len());
            for worker in pending {
                if worker.is_finished() {
                    let _ = worker.join();
                } else {
                    still_running.push(worker);
                }
            }

            if still_running.is_empty() {
                return;
            }
            if started.elapsed() >= timeout {
                for worker in still_running {
                    let worker_name = worker.thread().name().unwrap_or("unnamed").to_owned();
                    self.shared.record_detached_worker(&worker_name);
                    drop(worker);
                }
                return;
            }

            pending = still_running;
            let remaining = timeout.saturating_sub(started.elapsed());
            std::thread::sleep(remaining.min(Duration::from_millis(1)));
        }
    }

    // Loom has no real-time model. Keep its shutdown join phase unchanged so
    // the existing concurrency models exercise only synchronization state.
    #[cfg(all(test, loom))]
    fn join_workers_bounded(&self, workers: Vec<sync::thread::JoinHandle<()>>) {
        for worker in workers {
            let _ = worker.join();
        }
    }
}

impl fmt::Debug for Runtime {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("Runtime")
            .field("config", &self.shared.config)
            .field("counters", &self.counters())
            .finish()
    }
}

impl Drop for Runtime {
    fn drop(&mut self) {
        // Drop can run on a host scheduler or on one of this runtime's own
        // workers. It must never block or join; dropping the JoinHandles below
        // detaches them after this request wakes the pool.
        self.request_shutdown();
    }
}

fn worker_loop(shared: Arc<Shared>) {
    loop {
        let (expired, job) = {
            let mut state = sync::lock(&shared.queue);
            loop {
                let expired = take_expired_queue_head(&mut state);
                if !expired.is_empty() {
                    break (expired, None);
                }
                if let Some(job) = state.queue.pop_front() {
                    break (Vec::new(), Some(job));
                }
                if state.shutting_down {
                    break (Vec::new(), None);
                }
                state = sync::wait(&shared.wake, state);
            }
        };
        if !expired.is_empty() {
            publish_expired_jobs(expired);
            continue;
        }
        let Some(job) = job else {
            return;
        };

        if job.try_start() {
            shared.counters.running.fetch_add(1, Ordering::AcqRel);
            job.run();
        } else {
            job.discard_task();
        }
    }
}

#[cfg(all(test, not(loom)))]
mod tests;

#[cfg(all(test, loom))]
mod loom_tests;
