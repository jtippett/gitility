//! Bounded asynchronous execution for core Git queries.
//!
//! Each [`Runtime`] owns its worker threads and one hand-rolled bounded FIFO
//! queue. There is no ambient global runtime or configuration.
//!
//! # Cooperative deadlines
//!
//! The runtime deliberately has no timer thread and cannot interrupt arbitrary
//! Rust code. A job whose deadline has passed at dequeue fails with
//! [`ErrorCode::Timeout`] without invoking its task. Once running, the task
//! observes cancellation and its deadline at [`Budget::check`] and charge
//! points. Timeout latency is therefore bounded by the longest gap between
//! budget checks, not by a wall-clock interrupt. Provider waits use the same
//! deadline when callback-backed stores are added.

mod observer;
mod sync;

use crate::budget::{Budget, BudgetLimits};
use crate::error::{Error, ErrorCode};
use crate::file::FileRead;
use crate::object::{ObjectHeader, ObjectKind, Oid};
use crate::snapshot::Snapshot;
use crate::tree::TreePage;
pub use observer::TestObserver;
use std::collections::{BTreeMap, VecDeque};
use std::fmt;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool as StdAtomicBool, Ordering as StdOrdering};
use std::sync::Arc as StdArc;
use std::time::{Duration, Instant};
use sync::{Arc, AtomicBool, AtomicU64, AtomicU8, Condvar, Mutex, Ordering};

/// Opaque identity assigned by the eventual NIF layer to a job owner.
pub type OwnerKey = u64;

/// Runtime worker and admission limits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RuntimeConfig {
    pub workers: usize,
    pub max_queue: usize,
    pub max_jobs_per_owner: usize,
    pub retry_after_ms: u64,
}

impl Default for RuntimeConfig {
    fn default() -> Self {
        Self {
            workers: 4,
            max_queue: 1_000,
            max_jobs_per_owner: 16,
            retry_after_ms: 100,
        }
    }
}

/// Stable result shapes retained by a completed job until result encoding.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum JobOutput {
    Tree(TreePage),
    File(FileRead),
    Header(Option<ObjectHeader>),
    Object { kind: ObjectKind, data: Vec<u8> },
    ReadMany(ReadManyOutput),
    Oid(Oid),
    Snapshot(Snapshot),
}

/// One ordered batch of object reads, retaining missing entries as `None`.
pub type ReadManyOutput = Vec<(Oid, Option<(ObjectKind, Vec<u8>)>)>;

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
/// run inside the shutdown protocol. Observer panics are contained by the
/// runtime.
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
}

struct Counters {
    submitted: AtomicU64,
    completed: AtomicU64,
    failed: AtomicU64,
    cancelled: AtomicU64,
    rejected: AtomicU64,
    running: AtomicU64,
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
        }
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
/// Dropping the last runtime handle from outside the pool performs the same
/// cancellation and join sequence as [`Runtime::shutdown`]. If the last handle
/// is dropped by one of this runtime's workers, `Drop` can only request
/// shutdown: it detaches the handles rather than attempting to join itself.
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
    pub fn start(config: RuntimeConfig) -> Arc<Self> {
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
        for worker_index in 0..config.workers.max(1) {
            let shared = Arc::clone(&runtime.shared);
            let name = format!("gitility-worker-{worker_index}");
            match sync::thread::Builder::new()
                .name(name)
                .spawn(move || worker_loop(shared))
            {
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
        if spawn_failed {
            runtime.shutdown();
        }
        runtime
    }

    /// Admits one job or returns bounded-backpressure metadata.
    pub fn submit(&self, owner: OwnerKey, spec: JobSpec) -> Result<Arc<Job>, SubmitError> {
        let submitted_at = Instant::now();
        let mut state = sync::lock(&self.shared.queue);
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
    /// From a non-worker thread, this method returns only after every worker
    /// has been joined and every admitted job is terminal. Concurrent external
    /// callers wait for that same completion point. From one of this runtime's
    /// own workers, it is deliberately only a shutdown request and returns
    /// without joining; a later external call or `Drop` completes the joins.
    ///
    /// Observers for jobs drained from the queue run synchronously on this
    /// method's caller thread, inside the shutdown protocol. Observers must not
    /// re-enter this method or [`Runtime::submit`].
    pub fn shutdown(&self) {
        let called_from_worker = self.is_worker_thread();
        let won_request = self
            .shutdown_phase
            .compare_exchange(
                ShutdownPhase::NotStarted as u8,
                ShutdownPhase::InProgress as u8,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_ok();

        if won_request {
            if !called_from_worker {
                self.shutdown_join_claimed.store(true, Ordering::Release);
            }
            self.request_shutdown();
            self.publish_shutdown_request();

            if called_from_worker {
                return;
            }
            self.finish_shutdown();
            return;
        }

        if self.shutdown_phase.load(Ordering::Acquire) == ShutdownPhase::Complete as u8
            || called_from_worker
        {
            return;
        }
        self.wait_for_or_finish_shutdown();
    }

    pub fn queue_len(&self) -> usize {
        sync::lock(&self.shared.queue).queue.len()
    }

    pub fn running_count(&self) -> u64 {
        self.shared.counters.running.load(Ordering::Acquire)
    }

    pub fn counters(&self) -> RuntimeCounters {
        self.shared.counters.snapshot()
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

    fn request_shutdown(&self) {
        let jobs = self.shared.begin_shutdown();
        self.shared.wake.notify_all();
        for job in jobs {
            job.cancel();
        }
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
        for worker in workers {
            let _ = worker.join();
        }

        let _wait = sync::lock(&self.shutdown_wait);
        self.shutdown_phase
            .store(ShutdownPhase::Complete as u8, Ordering::Release);
        self.shutdown_wake.notify_all();
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
        // A last Arc can be released by a task closure on its own worker.
        // shutdown() recognizes that caller and only requests shutdown, after
        // which dropping JoinHandles detaches them and avoids a self-join.
        self.shutdown();
    }
}

fn worker_loop(shared: Arc<Shared>) {
    loop {
        let job = {
            let mut state = sync::lock(&shared.queue);
            loop {
                if let Some(job) = state.queue.pop_front() {
                    break Some(job);
                }
                if state.shutting_down {
                    break None;
                }
                state = sync::wait(&shared.wake, state);
            }
        };
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
