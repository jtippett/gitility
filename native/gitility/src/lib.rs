//! Rustler NIF adapter for Gitility.
//!
//! This crate owns the BEAM boundary only: term encoding, resources, and the
//! provisional dirty-scheduler handoff. All Git semantics live in
//! `gitility-core`, which never depends on Rustler or Elixir concepts.

#![forbid(unsafe_code)]

use gitility_core::runtime::thread_budget;
use gitility_core::{
    list_tree as core_list_tree, peel as core_peel, read_file as core_read_file, Budget,
    BudgetLimits, BusyReason, Error, ErrorCode, FileKind, FileOptions, HashKind, Job as CoreJob,
    JobObserver, JobOutput, JobSpec, JobState, LocalOdb, LocalOdbOptions, ObjectDb, ObjectHeader,
    ObjectKind, Oid, PeelTarget, QueryStats, Runtime as CoreRuntime, RuntimeConfig, Snapshot,
    StaticOdb, SubmitError, TreeItemKind, TreeOptions, TypeFilter,
};
use rustler::{
    Atom, Binary, Encoder, Env, LocalPid, Monitor, NewBinary, NifMap, NifResult, OwnedEnv,
    Resource, ResourceArc, Term,
};
use std::collections::{BTreeMap, HashSet};
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex, MutexGuard};
use std::thread::{self, JoinHandle};
use std::time::Instant;

enum StoreImpl {
    Local(LocalOdb),
    Static(StaticStore),
}

struct StaticStore {
    hash: HashKind,
    addressed: StaticOdb,
    addressed_oids: HashSet<Oid>,
    derived: StaticOdb,
}

impl ObjectDb for StaticStore {
    fn hash_kind(&self) -> HashKind {
        self.hash
    }

    fn try_header(&self, oid: &Oid, budget: &Budget) -> Result<Option<ObjectHeader>, Error> {
        if self.addressed_oids.contains(oid) {
            self.addressed.try_header(oid, budget)
        } else {
            self.derived.try_header(oid, budget)
        }
    }

    fn try_find(
        &self,
        oid: &Oid,
        out: &mut Vec<u8>,
        budget: &Budget,
    ) -> Result<Option<ObjectKind>, Error> {
        if self.addressed_oids.contains(oid) {
            self.addressed.try_find(oid, out, budget)
        } else {
            self.derived.try_find(oid, out, budget)
        }
    }
}

impl StoreImpl {
    fn as_dyn(&self) -> &dyn ObjectDb {
        match self {
            Self::Local(store) => store,
            Self::Static(store) => store,
        }
    }
}

struct StoreResource(StoreImpl);

#[rustler::resource_impl]
impl Resource for StoreResource {}

#[derive(Clone, Copy, NifMap)]
struct RuntimeConfigMap {
    workers: usize,
    max_queue: usize,
    max_jobs_per_owner: usize,
}

#[derive(NifMap)]
struct RuntimeStatsMap {
    submitted: u64,
    completed: u64,
    failed: u64,
    cancelled: u64,
    rejected: u64,
    queue_len: u64,
    running_count: u64,
    active_jobs: u64,
    job_resources: u64,
    owner_count: u64,
    workers: u64,
    max_queue: u64,
    max_jobs_per_owner: u64,
    thread_budget_used: u64,
    thread_budget_limit: u64,
}

struct Notification {
    job_id: u64,
    waiters: Vec<LocalPid>,
    waiter_state: Arc<WaiterShared>,
}

#[derive(Default)]
struct NotificationSender {
    sender: Mutex<Option<mpsc::Sender<Notification>>>,
}

impl NotificationSender {
    fn enqueue(&self, notification: Notification) {
        if let Some(sender) = lock(&self.sender).as_ref() {
            let _ = sender.send(notification);
        }
    }

    fn close(&self) {
        lock(&self.sender).take();
    }
}

struct RuntimeResource {
    runtime: Arc<CoreRuntime>,
    notifications: Arc<NotificationSender>,
    owner_keys: Arc<Mutex<BTreeMap<LocalPid, u64>>>,
    owner_active: Arc<Mutex<BTreeMap<LocalPid, usize>>>,
    next_owner_key: AtomicU64,
    job_resources: AtomicU64,
    config: RuntimeConfigMap,
    pump: Mutex<Option<JoinHandle<()>>>,
    shutdown_started: AtomicBool,
}

#[rustler::resource_impl]
impl Resource for RuntimeResource {}

impl Drop for RuntimeResource {
    fn drop(&mut self) {
        if !self.shutdown_started.swap(true, Ordering::AcqRel) {
            // Resource destruction can run on a scheduler. The pump owns a
            // runtime Arc and performs the blocking shutdown on its Rust-owned
            // thread; dropping the JoinHandle deliberately detaches it.
            self.notifications.close();
        }
    }
}

#[derive(Default)]
struct WaiterState {
    waiters: Vec<LocalPid>,
    suppressed: Vec<LocalPid>,
    monitor: Option<Monitor>,
    detached: bool,
}

#[derive(Default)]
struct WaiterShared {
    state: Mutex<WaiterState>,
}

struct NifJobObserver {
    waiters: Arc<WaiterShared>,
    notifications: Arc<NotificationSender>,
    owner_keys: Arc<Mutex<BTreeMap<LocalPid, u64>>>,
    owner_active: Arc<Mutex<BTreeMap<LocalPid, usize>>>,
    owner: LocalPid,
}

impl JobObserver for NifJobObserver {
    fn completed(&self, job: &CoreJob) {
        let waiters = {
            let mut state = lock(&self.waiters.state);
            std::mem::take(&mut state.waiters)
        };
        owner_job_completed(&self.owner_keys, &self.owner_active, self.owner);
        self.notifications.enqueue(Notification {
            job_id: job.id(),
            waiters,
            waiter_state: Arc::clone(&self.waiters),
        });
    }
}

#[derive(Clone, Copy)]
enum JobResultKind {
    Tree { stopped_by_max_results: bool },
    Other,
}

struct JobResource {
    job: Arc<CoreJob>,
    waiters: Arc<WaiterShared>,
    runtime: ResourceArc<RuntimeResource>,
    owner: LocalPid,
    max_result_bytes: u64,
    result_kind: JobResultKind,
    elapsed_ms: Arc<AtomicU64>,
}

#[rustler::resource_impl]
impl Resource for JobResource {
    fn down<'a>(&'a self, _env: Env<'a>, pid: LocalPid, monitor: Monitor) {
        let should_cancel = {
            let mut state = lock(&self.waiters.state);
            if pid != self.owner || state.detached || state.monitor.as_ref() != Some(&monitor) {
                false
            } else {
                state.monitor = None;
                true
            }
        };
        if should_cancel {
            self.job.cancel();
            remove_owner(&self.runtime.owner_keys, &self.runtime.owner_active, pid);
        }
    }
}

impl Drop for JobResource {
    fn drop(&mut self) {
        self.runtime.job_resources.fetch_sub(1, Ordering::AcqRel);
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn owner_job_completed(
    owner_keys: &Mutex<BTreeMap<LocalPid, u64>>,
    owner_active: &Mutex<BTreeMap<LocalPid, usize>>,
    owner: LocalPid,
) {
    let mut keys = lock(owner_keys);
    let mut active = lock(owner_active);
    if let Some(count) = active.get_mut(&owner) {
        *count = count.saturating_sub(1);
        if *count == 0 {
            active.remove(&owner);
            keys.remove(&owner);
        }
    }
}

fn remove_owner(
    owner_keys: &Mutex<BTreeMap<LocalPid, u64>>,
    owner_active: &Mutex<BTreeMap<LocalPid, usize>>,
    owner: LocalPid,
) {
    let mut keys = lock(owner_keys);
    let mut active = lock(owner_active);
    active.remove(&owner);
    keys.remove(&owner);
}

fn notification_pump(runtime: Arc<CoreRuntime>, receiver: mpsc::Receiver<Notification>) {
    let mut env = OwnedEnv::new();
    while let Ok(notification) = receiver.recv() {
        notify_waiters(
            &mut env,
            notification.job_id,
            notification.waiters,
            &notification.waiter_state,
        );
    }
    runtime.shutdown();
}

fn notify_waiters(
    env: &mut OwnedEnv,
    job_id: u64,
    waiters: Vec<LocalPid>,
    waiter_state: &WaiterShared,
) {
    // Holding this lock through each fire-and-forget send closes the timeout
    // race: deregistration either suppresses delivery first, or runs after
    // the send and the Elixir-side zero-timeout flush observes the message.
    let mut state = lock(&waiter_state.state);
    for waiter in waiters {
        if !state.suppressed.contains(&waiter) {
            let _ = env.send_and_clear(&waiter, |send_env| {
                (atoms::gitility_job(), job_id, atoms::done()).encode(send_env)
            });
        }
    }
    state.suppressed.clear();
}

#[derive(NifMap)]
struct OpenLocalOptions {
    require_bare: bool,
    verify_pack_checksums: bool,
}

#[derive(Clone, Copy, NifMap)]
struct LimitsMap {
    timeout_ms: u64,
    max_objects: u64,
    max_object_bytes: u64,
    max_total_object_bytes: u64,
    max_provider_requests: u64,
    max_provider_bytes: u64,
    max_tree_entries: u64,
    max_results: u64,
    max_diff_files: u64,
    max_diff_hunks: u64,
    max_diff_lines: u64,
    max_result_bytes: u64,
    max_delta_depth: u32,
}

#[derive(NifMap)]
struct ListTreeOptions<'a> {
    path: Binary<'a>,
    recursive: bool,
    depth: Option<u32>,
    types: Vec<Atom>,
    pathspecs: Vec<Binary<'a>>,
    include_size: bool,
    limit: u64,
    cursor: Option<Binary<'a>>,
}

#[derive(NifMap)]
struct ReadFileOptions {
    lines: Option<(u32, u32)>,
    max_bytes: u64,
}

#[derive(NifMap)]
struct ErrorMap {
    code: Atom,
    message: String,
    retryable: bool,
    limit: Option<String>,
}

#[derive(NifMap)]
struct SubmitErrorMap {
    code: Atom,
    message: String,
    retryable: bool,
    limit: Option<String>,
    retry_after_ms: Option<u64>,
    reason: Option<Atom>,
}

#[derive(NifMap)]
struct SnapshotMap<'a> {
    commit_oid: Binary<'a>,
    tree_oid: Binary<'a>,
}

#[derive(NifMap)]
struct HeaderMap {
    kind: Atom,
    size: u64,
}

#[derive(NifMap)]
struct ObjectMap<'a> {
    kind: Atom,
    size: u64,
    data: Binary<'a>,
}

#[derive(NifMap)]
struct TreeEntryMap<'a> {
    path: Binary<'a>,
    name: Binary<'a>,
    oid: Binary<'a>,
    kind: Atom,
    mode: u32,
    size: Option<u64>,
}

#[derive(NifMap)]
struct StatsMap {
    objects_requested: u64,
    objects_read: u64,
    entries_emitted: u64,
    cache_hits: u64,
    cache_misses: u64,
    provider_requests: u64,
    provider_bytes: u64,
    decompressed_bytes: u64,
    scanned_blobs: u64,
    elapsed_ms: u64,
    stopped_by: Option<Atom>,
}

#[derive(NifMap)]
struct TreePageMap<'a> {
    entries: Vec<TreeEntryMap<'a>>,
    next_cursor: Option<Binary<'a>>,
    truncated: bool,
    stats: StatsMap,
}

#[derive(NifMap)]
struct LfsPointerMap {
    oid: String,
    size: u64,
}

#[derive(NifMap)]
struct FileMap<'a> {
    path: Binary<'a>,
    blob_oid: Binary<'a>,
    mode: u32,
    kind: Atom,
    data: Binary<'a>,
    start_line: Option<u32>,
    end_line: Option<u32>,
    total_lines: Option<u32>,
    truncated: bool,
    lfs_pointer: Option<LfsPointerMap>,
}

enum ObjectOrNotFound<'a> {
    Object(ObjectMap<'a>),
    NotFound,
}

impl Encoder for ObjectOrNotFound<'_> {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            Self::Object(object) => object.encode(env),
            Self::NotFound => atoms::not_found().encode(env),
        }
    }
}

fn budget_limits(limits: LimitsMap) -> BudgetLimits {
    let LimitsMap {
        timeout_ms: _,
        max_objects,
        max_object_bytes,
        max_total_object_bytes,
        max_provider_requests,
        max_provider_bytes,
        max_tree_entries,
        max_results,
        max_diff_files,
        max_diff_hunks,
        max_diff_lines,
        max_result_bytes: _,
        max_delta_depth,
    } = limits;
    let _future_limits = (max_results, max_diff_files, max_diff_hunks, max_diff_lines);
    BudgetLimits {
        max_objects,
        max_object_bytes,
        max_total_object_bytes,
        max_provider_requests,
        max_provider_bytes,
        max_tree_entries,
        max_delta_depth,
    }
}

fn budget(limits: LimitsMap) -> Budget {
    Budget::new(budget_limits(limits), None, Default::default())
}

#[rustler::nif]
fn runtime_start(config: RuntimeConfigMap) -> NifResult<ResourceArc<RuntimeResource>> {
    let core_config = RuntimeConfig {
        workers: config.workers,
        max_queue: config.max_queue,
        max_jobs_per_owner: config.max_jobs_per_owner,
        retry_after_ms: 100,
    };
    // The pump thread draws on the same process-wide budget as the core
    // workers; reserving it first means a failed core start releases it on
    // the way out. Exhaustion raises in Elixir rather than spawning: the
    // budget exists so runtime leaks fail loudly here instead of growing
    // until the host machine panics (2026-08-14).
    let pump_reservation = thread_budget::global()
        .try_reserve(1)
        .map_err(thread_budget_error)?;
    let runtime = CoreRuntime::try_start(core_config).map_err(thread_budget_error)?;
    let (notify_tx, notify_rx) = mpsc::channel();
    let notifications = Arc::new(NotificationSender {
        sender: Mutex::new(Some(notify_tx)),
    });
    let pump_runtime = Arc::clone(&runtime);
    let pump = thread::Builder::new()
        .name("gitility-notify".to_owned())
        .spawn(move || {
            let _budget_reservation = pump_reservation;
            notification_pump(pump_runtime, notify_rx)
        })
        .expect("gitility notification pump must start");

    Ok(ResourceArc::new(RuntimeResource {
        runtime,
        notifications,
        owner_keys: Arc::new(Mutex::new(BTreeMap::new())),
        owner_active: Arc::new(Mutex::new(BTreeMap::new())),
        next_owner_key: AtomicU64::new(1),
        job_resources: AtomicU64::new(0),
        config,
        pump: Mutex::new(Some(pump)),
        shutdown_started: AtomicBool::new(false),
    }))
}

fn thread_budget_error(error: thread_budget::BudgetExhausted) -> rustler::Error {
    rustler::Error::RaiseTerm(Box::new(format!(
        "gitility thread budget exhausted: {error}"
    )))
}

#[rustler::nif(schedule = "DirtyIo")]
fn runtime_shutdown(runtime: ResourceArc<RuntimeResource>) -> Atom {
    if !runtime.shutdown_started.swap(true, Ordering::AcqRel) {
        runtime.runtime.shutdown();
        runtime.notifications.close();
    }
    if let Some(pump) = lock(&runtime.pump).take() {
        let _ = pump.join();
    }
    atoms::ok()
}

#[rustler::nif]
fn runtime_stats(runtime: ResourceArc<RuntimeResource>) -> RuntimeStatsMap {
    let counters = runtime.runtime.counters();
    RuntimeStatsMap {
        submitted: counters.submitted,
        completed: counters.completed,
        failed: counters.failed,
        cancelled: counters.cancelled,
        rejected: counters.rejected,
        queue_len: runtime.runtime.queue_len() as u64,
        running_count: runtime.runtime.running_count(),
        active_jobs: counters.submitted.saturating_sub(
            counters
                .completed
                .saturating_add(counters.failed)
                .saturating_add(counters.cancelled),
        ),
        job_resources: runtime.job_resources.load(Ordering::Acquire),
        owner_count: lock(&runtime.owner_keys).len() as u64,
        workers: runtime.config.workers as u64,
        max_queue: runtime.config.max_queue as u64,
        max_jobs_per_owner: runtime.config.max_jobs_per_owner as u64,
        thread_budget_used: thread_budget::global().used() as u64,
        thread_budget_limit: thread_budget::global().limit() as u64,
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn open_local<'a>(env: Env<'a>, path: Binary<'a>, opts: OpenLocalOptions) -> NifResult<Term<'a>> {
    let path = Path::new(OsStr::from_bytes(path.as_slice()));
    let result = LocalOdb::open(
        path,
        LocalOdbOptions {
            verify_pack_checksums: opts.verify_pack_checksums,
        },
    )
    .and_then(|(store, layout)| {
        if opts.require_bare && !layout.bare {
            Err(Error::new(
                ErrorCode::InvalidArgument,
                "repository is not bare",
            ))
        } else {
            Ok((store, layout.object_hash))
        }
    });

    match result {
        Ok((store, hash)) => Ok(Result::<_, ErrorMap>::Ok((
            ResourceArc::new(StoreResource(StoreImpl::Local(store))),
            hash_atom(hash),
        ))
        .encode(env)),
        Err(error) => Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn static_from_objects<'a>(
    env: Env<'a>,
    objects: Vec<(Option<Binary<'a>>, Atom, Binary<'a>)>,
    hash: Atom,
) -> NifResult<Term<'a>> {
    let hash = match parse_hash(hash) {
        Ok(hash) => hash,
        Err(error) => {
            return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env));
        }
    };
    let mut addressed = Vec::new();
    let mut addressed_oids = HashSet::new();
    let mut derived = Vec::new();
    for (address, kind, data) in objects {
        let kind = match parse_object_kind(kind) {
            Ok(kind) => kind,
            Err(error) => {
                return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env));
            }
        };
        let payload = data.as_slice().to_vec();
        if let Some(address) = address {
            let oid = match Oid::new(hash, address.as_slice()) {
                Ok(oid) => oid,
                Err(error) => {
                    return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env));
                }
            };
            addressed_oids.insert(oid);
            addressed.push((oid, kind, payload));
        } else {
            derived.push((kind, payload));
        }
    }

    let addressed = match StaticOdb::from_addressed_objects(hash, addressed) {
        Ok(store) => store,
        Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    };
    let derived = match StaticOdb::from_objects(hash, derived) {
        Ok(store) => store,
        Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    };
    let store = StaticStore {
        hash,
        addressed,
        addressed_oids,
        derived,
    };
    Ok(Result::<_, ErrorMap>::Ok((
        ResourceArc::new(StoreResource(StoreImpl::Static(store))),
        hash_atom(hash),
    ))
    .encode(env))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn snapshot_open<'a>(
    env: Env<'a>,
    store: ResourceArc<StoreResource>,
    oid: Binary<'a>,
    limits: LimitsMap,
) -> NifResult<Result<SnapshotMap<'a>, ErrorMap>> {
    let oid = match oid_for_store(&store, oid.as_slice()) {
        Ok(oid) => oid,
        Err(error) => return Ok(Err(error_map(env, error)?)),
    };
    match Snapshot::open(store.0.as_dyn(), oid, &budget(limits)) {
        Ok(snapshot) => Ok(Ok(SnapshotMap {
            commit_oid: binary(env, snapshot.commit_oid.as_bytes()),
            tree_oid: binary(env, snapshot.tree_oid.as_bytes()),
        })),
        Err(error) => Ok(Err(error_map(env, error)?)),
    }
}

fn submit_job<'a>(
    env: Env<'a>,
    runtime: ResourceArc<RuntimeResource>,
    detach: bool,
    limits: LimitsMap,
    core_limits: BudgetLimits,
    result_kind: JobResultKind,
    task: gitility_core::JobTask,
) -> NifResult<Term<'a>> {
    let owner = env.pid();
    let owner_key = {
        let mut owners = lock(&runtime.owner_keys);
        let key = *owners
            .entry(owner)
            .or_insert_with(|| runtime.next_owner_key.fetch_add(1, Ordering::Relaxed));
        *lock(&runtime.owner_active).entry(owner).or_insert(0) += 1;
        key
    };
    let waiters = Arc::new(WaiterShared {
        state: Mutex::new(WaiterState {
            detached: detach,
            ..WaiterState::default()
        }),
    });
    let observer: Arc<dyn JobObserver> = Arc::new(NifJobObserver {
        waiters: Arc::clone(&waiters),
        notifications: Arc::clone(&runtime.notifications),
        owner_keys: Arc::clone(&runtime.owner_keys),
        owner_active: Arc::clone(&runtime.owner_active),
        owner,
    });
    let elapsed_ms = Arc::new(AtomicU64::new(0));
    let task_elapsed_ms = Arc::clone(&elapsed_ms);
    let measured_task = Box::new(move |budget: &Budget| {
        let started = Instant::now();
        let result = task(budget);
        task_elapsed_ms.store(started.elapsed().as_millis() as u64, Ordering::Release);
        result
    });
    let spec = JobSpec {
        task: measured_task,
        limits: core_limits,
        timeout_ms: Some(limits.timeout_ms),
        observer,
    };

    match runtime.runtime.submit(owner_key, spec) {
        Ok(job) => {
            let id = job.id();
            runtime.job_resources.fetch_add(1, Ordering::AcqRel);
            let resource = ResourceArc::new(JobResource {
                job,
                waiters,
                runtime,
                owner,
                max_result_bytes: limits.max_result_bytes,
                result_kind,
                elapsed_ms,
            });
            if !detach {
                let monitor = resource.monitor(Some(env), &owner);
                lock(&resource.waiters.state).monitor = monitor;
            }
            Ok(Result::<_, SubmitErrorMap>::Ok((resource, id)).encode(env))
        }
        Err(error) => {
            owner_job_completed(&runtime.owner_keys, &runtime.owner_active, owner);
            Ok(Result::<(), _>::Err(submit_error_map(error)).encode(env))
        }
    }
}

#[rustler::nif]
fn job_submit_odb_header<'a>(
    env: Env<'a>,
    runtime: ResourceArc<RuntimeResource>,
    store: ResourceArc<StoreResource>,
    raw_oid: Binary<'a>,
    limits: LimitsMap,
) -> NifResult<Term<'a>> {
    let oid = match oid_for_store(&store, raw_oid.as_slice()) {
        Ok(oid) => oid,
        Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    };
    let task_store = store.clone();
    let task =
        Box::new(
            move |budget: &Budget| match task_store.0.as_dyn().try_header(&oid, budget)? {
                Some(header) => Ok(JobOutput::Header(Some(header))),
                None => Err(missing_object(oid)),
            },
        );
    submit_job(
        env,
        runtime,
        false,
        limits,
        budget_limits(limits),
        JobResultKind::Other,
        task,
    )
}

#[rustler::nif]
fn job_submit_odb_read<'a>(
    env: Env<'a>,
    runtime: ResourceArc<RuntimeResource>,
    store: ResourceArc<StoreResource>,
    raw_oid: Binary<'a>,
    max_bytes: Option<u64>,
    limits: LimitsMap,
) -> NifResult<Term<'a>> {
    let oid = match oid_for_store(&store, raw_oid.as_slice()) {
        Ok(oid) => oid,
        Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    };
    let task_store = store.clone();
    let task = Box::new(move |budget: &Budget| {
        match read_object(task_store.0.as_dyn(), oid, max_bytes, budget)? {
            Some((kind, data)) => Ok(JobOutput::Object { kind, data }),
            None => Err(missing_object(oid)),
        }
    });
    submit_job(
        env,
        runtime,
        false,
        limits,
        budget_limits(limits),
        JobResultKind::Other,
        task,
    )
}

#[rustler::nif]
fn job_submit_odb_read_many<'a>(
    env: Env<'a>,
    runtime: ResourceArc<RuntimeResource>,
    store: ResourceArc<StoreResource>,
    raw_oids: Vec<Binary<'a>>,
    max_total_bytes: Option<u64>,
    limits: LimitsMap,
) -> NifResult<Term<'a>> {
    let mut oids = Vec::with_capacity(raw_oids.len());
    for raw_oid in raw_oids {
        match oid_for_store(&store, raw_oid.as_slice()) {
            Ok(oid) => oids.push(oid),
            Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
        }
    }
    let task_store = store.clone();
    let task = Box::new(move |budget: &Budget| {
        let mut total = 0u64;
        let mut results = Vec::with_capacity(oids.len());
        for oid in oids {
            let value = match read_object(task_store.0.as_dyn(), oid, None, budget)? {
                Some((kind, data)) => {
                    total = total.saturating_add(data.len() as u64);
                    if max_total_bytes.is_some_and(|maximum| total > maximum) {
                        return Err(Error::new(
                            ErrorCode::ResultTooLarge,
                            "object batch exceeds max_total_bytes",
                        )
                        .with_limit("max_total_bytes"));
                    }
                    Some((kind, data))
                }
                None => None,
            };
            results.push((oid, value));
        }
        Ok(JobOutput::ReadMany(results))
    });
    submit_job(
        env,
        runtime,
        false,
        limits,
        budget_limits(limits),
        JobResultKind::Other,
        task,
    )
}

#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn job_submit_list_tree<'a>(
    env: Env<'a>,
    runtime: ResourceArc<RuntimeResource>,
    store: ResourceArc<StoreResource>,
    raw_commit_oid: Binary<'a>,
    raw_tree_oid: Binary<'a>,
    opts: ListTreeOptions<'a>,
    limits: LimitsMap,
    detach: bool,
) -> NifResult<Term<'a>> {
    let commit_oid = match oid_for_store(&store, raw_commit_oid.as_slice()) {
        Ok(oid) => oid,
        Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    };
    let tree_oid = match oid_for_store(&store, raw_tree_oid.as_slice()) {
        Ok(oid) => oid,
        Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    };
    let types = match type_filter(&opts.types) {
        Ok(types) => types,
        Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    };
    let stopped_by_max_results = limits.max_results < opts.limit;
    let effective_limit = opts.limit.min(limits.max_results);
    let limit = match usize::try_from(effective_limit) {
        Ok(limit) => limit,
        Err(_) => {
            let error = Error::new(ErrorCode::InvalidArgument, "tree page limit is too large");
            return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env));
        }
    };
    let options = TreeOptions {
        path: opts.path.as_slice().to_vec(),
        recursive: opts.recursive,
        depth: opts.depth,
        types,
        pathspecs: opts
            .pathspecs
            .iter()
            .map(|pathspec| pathspec.as_slice().to_vec())
            .collect(),
        include_size: opts.include_size,
        limit,
        cursor: opts.cursor.map(|cursor| cursor.as_slice().to_vec()),
    };
    let task_store = store.clone();
    let task = Box::new(move |budget: &Budget| {
        core_list_tree(
            task_store.0.as_dyn(),
            &Snapshot {
                commit_oid,
                tree_oid,
            },
            &options,
            budget,
        )
        .map(JobOutput::Tree)
    });
    submit_job(
        env,
        runtime,
        detach,
        limits,
        budget_limits(limits),
        JobResultKind::Tree {
            stopped_by_max_results,
        },
        task,
    )
}

#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn job_submit_read_file<'a>(
    env: Env<'a>,
    runtime: ResourceArc<RuntimeResource>,
    store: ResourceArc<StoreResource>,
    raw_commit_oid: Binary<'a>,
    raw_tree_oid: Binary<'a>,
    path: Binary<'a>,
    opts: ReadFileOptions,
    limits: LimitsMap,
    detach: bool,
) -> NifResult<Term<'a>> {
    let commit_oid = match oid_for_store(&store, raw_commit_oid.as_slice()) {
        Ok(oid) => oid,
        Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    };
    let tree_oid = match oid_for_store(&store, raw_tree_oid.as_slice()) {
        Ok(oid) => oid,
        Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    };
    let max_bytes = match usize::try_from(opts.max_bytes) {
        Ok(max_bytes) => max_bytes,
        Err(_) => {
            let error = Error::new(ErrorCode::InvalidArgument, "max_bytes is too large");
            return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env));
        }
    };
    let path = path.as_slice().to_vec();
    let file_options = FileOptions {
        lines: opts.lines,
        max_bytes,
    };
    let task_store = store.clone();
    let task = Box::new(move |budget: &Budget| {
        core_read_file(
            task_store.0.as_dyn(),
            &Snapshot {
                commit_oid,
                tree_oid,
            },
            &path,
            &file_options,
            budget,
        )
        .map(JobOutput::File)
    });
    // Preserve the public file cap semantics: the store may inflate a blob
    // before read_file applies its truncating max_bytes option.
    let mut core_limits = budget_limits(limits);
    core_limits.max_object_bytes = u64::MAX;
    submit_job(
        env,
        runtime,
        detach,
        limits,
        core_limits,
        JobResultKind::Other,
        task,
    )
}

#[rustler::nif]
fn job_submit_peel<'a>(
    env: Env<'a>,
    runtime: ResourceArc<RuntimeResource>,
    store: ResourceArc<StoreResource>,
    raw_oid: Binary<'a>,
    to: Atom,
    limits: LimitsMap,
) -> NifResult<Term<'a>> {
    let oid = match oid_for_store(&store, raw_oid.as_slice()) {
        Ok(oid) => oid,
        Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    };
    let target = match parse_peel_target(to) {
        Ok(target) => target,
        Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    };
    let task_store = store.clone();
    let task = Box::new(move |budget: &Budget| {
        core_peel(task_store.0.as_dyn(), oid, target, budget).map(JobOutput::Oid)
    });
    submit_job(
        env,
        runtime,
        false,
        limits,
        budget_limits(limits),
        JobResultKind::Other,
        task,
    )
}

#[rustler::nif]
fn job_register_waiter(env: Env<'_>, resource: ResourceArc<JobResource>) -> Atom {
    let pid = env.pid();
    let mut state = lock(&resource.waiters.state);
    if resource.job.is_terminal() {
        atoms::terminal()
    } else {
        state.suppressed.retain(|waiter| *waiter != pid);
        if !state.waiters.contains(&pid) {
            state.waiters.push(pid);
        }
        atoms::registered()
    }
}

#[rustler::nif]
fn job_deregister_waiter(env: Env<'_>, resource: ResourceArc<JobResource>) -> Atom {
    let pid = env.pid();
    let mut state = lock(&resource.waiters.state);
    state.waiters.retain(|waiter| *waiter != pid);
    if !state.suppressed.contains(&pid) {
        state.suppressed.push(pid);
    }
    atoms::ok()
}

#[rustler::nif]
fn job_cancel(resource: ResourceArc<JobResource>) -> Atom {
    resource.job.cancel();
    atoms::ok()
}

#[rustler::nif]
fn job_state(resource: ResourceArc<JobResource>) -> Atom {
    match resource.job.state() {
        JobState::Queued => atoms::queued(),
        JobState::Running => atoms::running(),
        JobState::Completed => atoms::completed(),
        JobState::Failed => atoms::failed(),
        JobState::Cancelled => atoms::cancelled(),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn job_take_result<'a>(env: Env<'a>, resource: ResourceArc<JobResource>) -> NifResult<Term<'a>> {
    if !resource.job.is_terminal() {
        return Ok(atoms::not_terminal().encode(env));
    }

    let monitor = lock(&resource.waiters.state).monitor.take();
    if let Some(monitor) = monitor {
        let _ = resource.demonitor(Some(env), &monitor);
    }

    let Some(result) = resource.job.take_output() else {
        return Ok(atoms::already_taken().encode(env));
    };
    match result {
        Ok(output) if output_payload_bytes(&output) > resource.max_result_bytes => {
            let error = Error::new(
                ErrorCode::ResultTooLarge,
                "job result exceeds max_result_bytes",
            )
            .with_limit("max_result_bytes");
            Ok((atoms::error(), error_map(env, error)?).encode(env))
        }
        Ok(output) => Ok((
            atoms::ok(),
            encode_job_output(
                env,
                output,
                resource.result_kind,
                resource.elapsed_ms.load(Ordering::Acquire),
            )?,
        )
            .encode(env)),
        Err(error) => Ok((atoms::error(), error_map(env, error)?).encode(env)),
    }
}

fn encode_job_output<'a>(
    env: Env<'a>,
    output: JobOutput,
    result_kind: JobResultKind,
    elapsed_ms: u64,
) -> NifResult<Term<'a>> {
    let term = match output {
        JobOutput::Tree(page) => {
            let entries = page
                .entries
                .into_iter()
                .map(|entry| TreeEntryMap {
                    path: binary(env, &entry.path),
                    name: binary(env, &entry.name),
                    oid: binary(env, entry.oid.as_bytes()),
                    kind: tree_kind_atom(entry.kind),
                    mode: entry.mode,
                    size: entry.size,
                })
                .collect();
            let stopped_by = match result_kind {
                JobResultKind::Tree {
                    stopped_by_max_results: true,
                } => atoms::max_results(),
                JobResultKind::Tree {
                    stopped_by_max_results: false,
                }
                | JobResultKind::Other => atoms::limit(),
            };
            TreePageMap {
                entries,
                next_cursor: page.next_cursor.map(|cursor| binary(env, &cursor)),
                truncated: page.truncated,
                stats: stats_map(page.stats, elapsed_ms, stopped_by),
            }
            .encode(env)
        }
        JobOutput::File(file) => FileMap {
            path: binary(env, &file.path),
            blob_oid: binary(env, file.blob_oid.as_bytes()),
            mode: file.mode,
            kind: file_kind_atom(file.kind),
            data: binary(env, &file.data),
            start_line: file.start_line,
            end_line: file.end_line,
            total_lines: file.total_lines,
            truncated: file.truncated,
            lfs_pointer: file.lfs_pointer.map(|pointer| LfsPointerMap {
                oid: pointer.oid,
                size: pointer.size,
            }),
        }
        .encode(env),
        JobOutput::Header(Some(header)) => HeaderMap {
            kind: object_kind_atom(header.kind),
            size: header.size,
        }
        .encode(env),
        JobOutput::Header(None) => atoms::not_found().encode(env),
        JobOutput::Object { kind, data } => object_map(env, kind, data).encode(env),
        JobOutput::ReadMany(results) => results
            .into_iter()
            .map(|(oid, object)| {
                let value = match object {
                    Some((kind, data)) => ObjectOrNotFound::Object(object_map(env, kind, data)),
                    None => ObjectOrNotFound::NotFound,
                };
                (binary(env, oid.as_bytes()), value)
            })
            .collect::<Vec<_>>()
            .encode(env),
        JobOutput::Oid(oid) => binary(env, oid.as_bytes()).encode(env),
        JobOutput::Snapshot(snapshot) => SnapshotMap {
            commit_oid: binary(env, snapshot.commit_oid.as_bytes()),
            tree_oid: binary(env, snapshot.tree_oid.as_bytes()),
        }
        .encode(env),
    };
    Ok(term)
}

fn output_payload_bytes(output: &JobOutput) -> u64 {
    fn length(bytes: &[u8]) -> u64 {
        u64::try_from(bytes.len()).unwrap_or(u64::MAX)
    }

    match output {
        JobOutput::Tree(page) => page.entries.iter().fold(
            page.next_cursor.as_deref().map(length).unwrap_or(0),
            |total, entry| {
                total
                    .saturating_add(length(&entry.path))
                    .saturating_add(length(&entry.name))
                    .saturating_add(length(entry.oid.as_bytes()))
            },
        ),
        JobOutput::File(file) => length(&file.path)
            .saturating_add(length(file.blob_oid.as_bytes()))
            .saturating_add(length(&file.data))
            .saturating_add(
                file.lfs_pointer
                    .as_ref()
                    .map(|pointer| length(pointer.oid.as_bytes()))
                    .unwrap_or(0),
            ),
        JobOutput::Header(_) => 16,
        JobOutput::Object { data, .. } => length(data),
        JobOutput::ReadMany(results) => results.iter().fold(0, |total, (oid, object)| {
            total
                .saturating_add(length(oid.as_bytes()))
                .saturating_add(object.as_ref().map(|(_, data)| length(data)).unwrap_or(0))
        }),
        JobOutput::Oid(oid) => length(oid.as_bytes()),
        JobOutput::Snapshot(snapshot) => length(snapshot.commit_oid.as_bytes())
            .saturating_add(length(snapshot.tree_oid.as_bytes())),
    }
}

fn submit_error_map(error: SubmitError) -> SubmitErrorMap {
    match error {
        SubmitError::Busy {
            reason,
            retry_after_ms,
        } => SubmitErrorMap {
            code: atoms::busy(),
            message: "runtime is busy".to_owned(),
            retryable: true,
            limit: None,
            retry_after_ms: Some(retry_after_ms),
            reason: Some(match reason {
                BusyReason::QueueFull => atoms::queue_full(),
                BusyReason::OwnerCeiling => atoms::owner_ceiling(),
            }),
        },
        SubmitError::ShuttingDown => SubmitErrorMap {
            code: atoms::cancelled(),
            message: "runtime shut down".to_owned(),
            retryable: false,
            limit: None,
            retry_after_ms: None,
            reason: None,
        },
    }
}

#[rustler::nif]
fn error_codes(env: Env<'_>) -> NifResult<Vec<Atom>> {
    ErrorCode::all()
        .iter()
        .map(|code| Atom::from_str(env, code.as_str()))
        .collect()
}

#[rustler::nif]
fn ping() -> Atom {
    atoms::pong()
}

fn read_object(
    store: &dyn ObjectDb,
    oid: Oid,
    max_bytes: Option<u64>,
    budget: &Budget,
) -> Result<Option<(ObjectKind, Vec<u8>)>, Error> {
    let mut data = Vec::new();
    let Some(kind) = store.try_find(&oid, &mut data, budget)? else {
        return Ok(None);
    };
    if max_bytes.is_some_and(|maximum| data.len() as u64 > maximum) {
        return Err(
            Error::new(ErrorCode::ObjectTooLarge, "object exceeds max_bytes")
                .with_limit("max_bytes"),
        );
    }
    Ok(Some((kind, data)))
}

fn object_map<'a>(env: Env<'a>, kind: ObjectKind, data: Vec<u8>) -> ObjectMap<'a> {
    ObjectMap {
        kind: object_kind_atom(kind),
        size: data.len() as u64,
        data: binary(env, &data),
    }
}

fn stats_map(stats: QueryStats, elapsed_ms: u64, page_limit_stopped_by: Atom) -> StatsMap {
    StatsMap {
        objects_requested: stats.objects_read,
        objects_read: stats.objects_read,
        entries_emitted: stats.entries_emitted,
        cache_hits: 0,
        cache_misses: 0,
        provider_requests: 0,
        provider_bytes: 0,
        decompressed_bytes: stats.bytes_read,
        scanned_blobs: 0,
        elapsed_ms,
        stopped_by: stats.stopped_by.and_then(|limit| {
            if limit == "limit" {
                Some(page_limit_stopped_by)
            } else {
                limit_atom(limit)
            }
        }),
    }
}

fn oid_for_store(store: &StoreResource, bytes: &[u8]) -> Result<Oid, Error> {
    Oid::new(store.0.as_dyn().hash_kind(), bytes)
}

fn parse_hash(hash: Atom) -> Result<HashKind, Error> {
    if hash == atoms::sha1() {
        Ok(HashKind::Sha1)
    } else if hash == atoms::sha256() {
        Ok(HashKind::Sha256)
    } else {
        Err(Error::new(
            ErrorCode::InvalidArgument,
            "unsupported hash atom",
        ))
    }
}

fn parse_object_kind(kind: Atom) -> Result<ObjectKind, Error> {
    if kind == atoms::commit() {
        Ok(ObjectKind::Commit)
    } else if kind == atoms::tree() {
        Ok(ObjectKind::Tree)
    } else if kind == atoms::blob() {
        Ok(ObjectKind::Blob)
    } else if kind == atoms::tag() {
        Ok(ObjectKind::Tag)
    } else {
        Err(Error::new(
            ErrorCode::InvalidArgument,
            "unsupported object kind atom",
        ))
    }
}

fn parse_peel_target(target: Atom) -> Result<PeelTarget, Error> {
    if target == atoms::commit() {
        Ok(PeelTarget::Commit)
    } else if target == atoms::tree() {
        Ok(PeelTarget::Tree)
    } else if target == atoms::blob() {
        Ok(PeelTarget::Blob)
    } else {
        Err(Error::new(
            ErrorCode::InvalidArgument,
            "peel target must be commit, tree, or blob",
        ))
    }
}

fn type_filter(types: &[Atom]) -> Result<TypeFilter, Error> {
    let mut filter = TypeFilter::NONE;
    for kind in types {
        if *kind == atoms::blob() {
            filter |= TypeFilter::BLOB;
        } else if *kind == atoms::tree() {
            filter |= TypeFilter::TREE;
        } else if *kind == atoms::symlink() {
            filter |= TypeFilter::SYMLINK;
        } else if *kind == atoms::gitlink() {
            filter |= TypeFilter::GITLINK;
        } else {
            return Err(Error::new(
                ErrorCode::InvalidArgument,
                "tree type filter contains an unsupported kind",
            ));
        }
    }
    Ok(filter)
}

fn hash_atom(hash: HashKind) -> Atom {
    match hash {
        HashKind::Sha1 => atoms::sha1(),
        HashKind::Sha256 => atoms::sha256(),
    }
}

fn object_kind_atom(kind: ObjectKind) -> Atom {
    match kind {
        ObjectKind::Commit => atoms::commit(),
        ObjectKind::Tree => atoms::tree(),
        ObjectKind::Blob => atoms::blob(),
        ObjectKind::Tag => atoms::tag(),
    }
}

fn tree_kind_atom(kind: TreeItemKind) -> Atom {
    match kind {
        TreeItemKind::Blob => atoms::blob(),
        TreeItemKind::Tree => atoms::tree(),
        TreeItemKind::Symlink => atoms::symlink(),
        TreeItemKind::Gitlink => atoms::gitlink(),
    }
}

fn file_kind_atom(kind: FileKind) -> Atom {
    match kind {
        FileKind::Text => atoms::text(),
        FileKind::Binary => atoms::binary(),
        FileKind::Symlink => atoms::symlink(),
        FileKind::Gitlink => atoms::gitlink(),
    }
}

fn binary<'a>(env: Env<'a>, bytes: &[u8]) -> Binary<'a> {
    let mut binary = NewBinary::new(env, bytes.len());
    binary.as_mut_slice().copy_from_slice(bytes);
    binary.into()
}

fn missing_object(oid: Oid) -> Error {
    Error::new(
        ErrorCode::MissingObject,
        format!("object {oid} is missing from the object store"),
    )
}

fn error_map(env: Env<'_>, error: Error) -> NifResult<ErrorMap> {
    Ok(ErrorMap {
        code: Atom::from_str(env, error.code.as_str())?,
        message: error.message,
        retryable: error.retryable,
        limit: error.limit.map(str::to_owned),
    })
}

fn limit_atom(limit: &str) -> Option<Atom> {
    match limit {
        "timeout_ms" => Some(atoms::timeout_ms()),
        "max_objects" => Some(atoms::max_objects()),
        "max_object_bytes" => Some(atoms::max_object_bytes()),
        "max_total_object_bytes" => Some(atoms::max_total_object_bytes()),
        "max_provider_requests" => Some(atoms::max_provider_requests()),
        "max_provider_bytes" => Some(atoms::max_provider_bytes()),
        "max_tree_entries" => Some(atoms::max_tree_entries()),
        "max_results" => Some(atoms::max_results()),
        "max_diff_files" => Some(atoms::max_diff_files()),
        "max_diff_hunks" => Some(atoms::max_diff_hunks()),
        "max_diff_lines" => Some(atoms::max_diff_lines()),
        "max_result_bytes" => Some(atoms::max_result_bytes()),
        "max_delta_depth" => Some(atoms::max_delta_depth()),
        "max_bytes" => Some(atoms::max_bytes()),
        "max_total_bytes" => Some(atoms::max_total_bytes()),
        _ => None,
    }
}

mod atoms {
    rustler::atoms! {
        pong,
        ok,
        error,
        gitility_job,
        done,
        registered,
        terminal,
        already_taken,
        not_terminal,
        queued,
        running,
        completed,
        failed,
        cancelled,
        busy,
        queue_full,
        owner_ceiling,
        not_found,
        sha1,
        sha256,
        commit,
        tree,
        blob,
        tag,
        symlink,
        gitlink,
        text,
        binary,
        limit,
        timeout_ms,
        max_objects,
        max_object_bytes,
        max_total_object_bytes,
        max_provider_requests,
        max_provider_bytes,
        max_tree_entries,
        max_results,
        max_diff_files,
        max_diff_hunks,
        max_diff_lines,
        max_result_bytes,
        max_delta_depth,
        max_bytes,
        max_total_bytes,
    }
}

rustler::init!("Elixir.Gitility.Native");
