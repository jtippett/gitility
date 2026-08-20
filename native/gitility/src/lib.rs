//! Rustler NIF adapter for Gitility.
//!
//! This crate owns the BEAM boundary only: term encoding, resources, and the
//! provisional dirty-scheduler handoff. All Git semantics live in
//! `gitility-core`, which never depends on Rustler or Elixir concepts.

#![forbid(unsafe_code)]

use gitility_core::runtime::thread_budget;
use gitility_core::{
    blame as core_blame, diff as core_diff, fetch as core_fetch, history as core_history,
    is_ancestor as core_is_ancestor, list_tree as core_list_tree, log as core_log,
    merge_base as core_merge_base, peel as core_peel, read_file as core_read_file,
    search as core_search, submodules as core_submodules, BlameOptions, Budget, BudgetLimits,
    BusyReason, ByteRange as CoreByteRange, CacheOptions, CacheStats, CallbackRangeTransport,
    DiffFormat, DiffLineOrigin, DiffOptions, DiffStatus, DiffWarningCode, Error, ErrorCode,
    FetchAction, FetchRejection, FetchRequest, FileKind, FileOptions, HashKind, HistoryOptions,
    HydrationStats, Job as CoreJob, JobObserver, JobOutput, JobSpec, JobState, LayeredOdb,
    LocalOdb, LocalOdbOptions, LocalRefDb, LogIdentity, LogOptions, LogOrder, ObjectDb,
    ObjectHeader, ObjectKind, ObjectReadResult, Oid, PackDescriptor, PackFetchOdb,
    PackFetchOptions, PackManifest, PeelTarget, PendingTable, ProviderCacheOptions, ProviderKind,
    ProviderOdb, ProviderOptions, ProviderPayload, ProviderRefDb, ProviderReplyValue,
    ProviderRequest, ProviderTransport, QueryStats, RangePayload, RangePendingTable, RangeRequest,
    RangeRequestKind, RangeRequestSender, ReadManyBudget, RefDb, RefPage, RefPendingTable,
    RefProviderKind, RefProviderOptions, RefProviderPayload, RefProviderRequest,
    RefProviderTransport, RefQuery as CoreRefQuery, RefTarget as CoreRefTarget, RenameTracking,
    Runtime as CoreRuntime, RuntimeConfig, SearchBinaryMode, SearchMode, SearchOptions, Snapshot,
    StaticOdb, SubmitError, SubmoduleStatus, TreeItemKind, TreeOptions, TypeFilter,
    PROVIDER_HEADER_SIZE_CEILING,
};
use rustler::{
    types::{map::MapIterator, tuple::get_tuple},
    Atom, Binary, Decoder, Encoder, Env, LocalPid, Monitor, NewBinary, NifMap, NifResult, OwnedEnv,
    Resource, ResourceArc, Term,
};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex, MutexGuard, Weak};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

enum StoreImpl {
    Local(Arc<LocalOdb>),
    Static(StaticStore),
    Provider(Box<ProviderOdb<NifProviderTransport>>),
    PackFetch(Box<NifPackFetch>),
    Layered(LayeredOdb),
}

type NifPackFetch = PackFetchOdb<CallbackRangeTransport<NifRangeRequestSender>>;

const MAX_PACK_MANIFEST_ENTRIES: usize = 100_000;

#[derive(Clone)]
struct NifProviderTransport {
    provider: LocalPid,
    pending: Weak<PendingTable>,
    hash: HashKind,
}

impl ProviderTransport for NifProviderTransport {
    fn request(&self, request: ProviderRequest) -> Result<(), Error> {
        // Provider callbacks are emitted only from Rust-owned runtime workers.
        // OwnedEnv::send_and_clear is forbidden on BEAM-managed scheduler
        // threads, hence this direct send does not use the M2b notification
        // pump and must never be called by a scheduler NIF.
        if rustler::thread::is_scheduler_thread() {
            return Err(Error::new(
                ErrorCode::BackendError,
                "provider request from a scheduler thread — Gitility bug",
            ));
        }
        let request_resource = ResourceArc::new(RequestResource {
            id: request.id,
            pending: self.pending.clone(),
            kind: request.kind,
            expected: request.oids.iter().copied().collect(),
            hash: self.hash,
            max_object_bytes: request.max_object_bytes,
            max_reply_bytes: request.max_reply_bytes,
            max_result_bytes: request.max_result_bytes,
        });
        let provider = self.provider;
        let kind = provider_kind_atom(request.kind);
        let oids = request.oids;
        let mut env = OwnedEnv::new();
        env.send_and_clear(&provider, move |send_env| {
            let oid_terms = oids
                .iter()
                .map(|oid| binary(send_env, oid.as_bytes()))
                .collect::<Vec<_>>();
            (
                atoms::gitility_provider_request(),
                request_resource,
                kind,
                oid_terms,
            )
                .encode(send_env)
        })
        .map_err(|_| Error::retryable(ErrorCode::ProviderDown, "provider process is down"))
    }
}

struct RequestResource {
    id: u64,
    pending: Weak<PendingTable>,
    kind: ProviderKind,
    expected: HashSet<Oid>,
    hash: HashKind,
    max_object_bytes: u64,
    max_reply_bytes: u64,
    max_result_bytes: Option<u64>,
}

#[rustler::resource_impl]
impl Resource for RequestResource {}

#[derive(Clone)]
struct NifRefProviderTransport {
    provider: LocalPid,
    pending: Weak<RefPendingTable>,
}

impl RefProviderTransport for NifRefProviderTransport {
    fn request(&self, request: RefProviderRequest) -> Result<(), Error> {
        if rustler::thread::is_scheduler_thread() {
            return Err(Error::new(
                ErrorCode::BackendError,
                "ref provider request from a scheduler thread — Gitility bug",
            ));
        }
        let request_resource = ResourceArc::new(RefRequestResource {
            id: request.id,
            pending: self.pending.clone(),
            kind: request.kind,
            expected_limit: request.query.as_ref().map_or(1, |query| query.limit),
            expected_prefix: request
                .query
                .as_ref()
                .and_then(|query| query.prefix.clone()),
            max_reply_bytes: request.max_reply_bytes,
        });
        let provider = self.provider;
        let kind = ref_provider_kind_atom(request.kind);
        let name = request.name;
        let query = request.query;
        let mut env = OwnedEnv::new();
        env.send_and_clear(&provider, move |send_env| {
            let payload = match (name, query) {
                (Some(name), None) => RefRequestPayload::Name(binary(send_env, &name)),
                (None, Some(query)) => RefRequestPayload::Query(RefQueryMap {
                    prefix: query.prefix.map(|prefix| binary(send_env, &prefix)),
                    limit: query.limit as u64,
                    cursor: query.cursor.map(|cursor| binary(send_env, &cursor)),
                }),
                _ => RefRequestPayload::Invalid,
            };
            (
                atoms::gitility_ref_request(),
                request_resource,
                kind,
                payload,
            )
                .encode(send_env)
        })
        .map_err(|_| Error::retryable(ErrorCode::ProviderDown, "ref provider process is down"))
    }
}

struct RefRequestResource {
    id: u64,
    pending: Weak<RefPendingTable>,
    kind: RefProviderKind,
    expected_limit: usize,
    expected_prefix: Option<Vec<u8>>,
    max_reply_bytes: u64,
}

#[rustler::resource_impl]
impl Resource for RefRequestResource {}

#[derive(Clone)]
struct NifRangeRequestSender {
    provider: LocalPid,
    pending: Weak<RangePendingTable>,
}

impl RangeRequestSender for NifRangeRequestSender {
    fn request(&self, request: RangeRequest) -> Result<(), Error> {
        // As with object-provider callbacks, PackFetch requests originate only
        // on existing Gitility runtime workers. No scheduler send and no new
        // native thread is involved.
        if rustler::thread::is_scheduler_thread() {
            return Err(Error::new(
                ErrorCode::BackendError,
                "range request from a scheduler thread — Gitility bug",
            ));
        }
        let request_resource = ResourceArc::new(RangeRequestResource {
            id: request.id,
            pending: self.pending.clone(),
            expected: request.kind.clone(),
            max_reply_bytes: request.max_reply_bytes,
        });
        let provider = self.provider;
        let kind = request.kind;
        let mut env = OwnedEnv::new();
        env.send_and_clear(&provider, move |send_env| match kind {
            RangeRequestKind::Manifest => (
                atoms::gitility_range_request(),
                request_resource,
                atoms::manifest(),
                Vec::<ByteRangeMap<'_>>::new(),
            )
                .encode(send_env),
            RangeRequestKind::ReadRanges(ranges) => {
                let ranges = ranges
                    .iter()
                    .map(|range| ByteRangeMap {
                        key: binary(send_env, range.key.as_bytes()),
                        offset: range.offset,
                        length: range.length,
                    })
                    .collect::<Vec<_>>();
                (
                    atoms::gitility_range_request(),
                    request_resource,
                    atoms::read_ranges(),
                    ranges,
                )
                    .encode(send_env)
            }
        })
        .map_err(|_| Error::retryable(ErrorCode::ProviderDown, "range provider is down"))
    }
}

struct RangeRequestResource {
    id: u64,
    pending: Weak<RangePendingTable>,
    expected: RangeRequestKind,
    max_reply_bytes: u64,
}

#[rustler::resource_impl]
impl Resource for RangeRequestResource {}

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
            Self::Local(store) => store.as_ref(),
            Self::Static(store) => store,
            Self::Provider(store) => store.as_ref(),
            Self::PackFetch(store) => store.as_ref(),
            Self::Layered(store) => store,
        }
    }

    fn as_provider(&self) -> Option<&ProviderOdb<NifProviderTransport>> {
        match self {
            Self::Provider(store) => Some(store.as_ref()),
            Self::Local(_) | Self::Static(_) | Self::PackFetch(_) | Self::Layered(_) => None,
        }
    }

    fn as_packfetch(&self) -> Option<&NifPackFetch> {
        match self {
            Self::PackFetch(store) => Some(store.as_ref()),
            Self::Local(_) | Self::Static(_) | Self::Provider(_) | Self::Layered(_) => None,
        }
    }

    fn is_layered_with_cache(&self) -> bool {
        matches!(self, Self::Layered(store) if store.has_cache())
    }
}

struct StoreResource(StoreImpl);

#[rustler::resource_impl]
impl Resource for StoreResource {}

enum RefStoreImpl {
    Local(LocalRefDb),
    Provider(Box<ProviderRefDb<NifRefProviderTransport>>),
}

impl RefStoreImpl {
    fn as_dyn(&self) -> &dyn RefDb {
        match self {
            Self::Local(store) => store,
            Self::Provider(store) => store.as_ref(),
        }
    }

    fn as_provider(&self) -> Option<&ProviderRefDb<NifRefProviderTransport>> {
        match self {
            Self::Provider(store) => Some(store.as_ref()),
            Self::Local(_) => None,
        }
    }
}

struct RefStoreResource(RefStoreImpl);

#[rustler::resource_impl]
impl Resource for RefStoreResource {}

/// Keeps an existing resource alive while presenting it through the core's
/// shared `ObjectDb` composition seam. Providers and caches therefore remain
/// the same instances when a handle is layered.
struct SharedStore(ResourceArc<StoreResource>);

impl SharedStore {
    fn as_dyn(&self) -> &dyn ObjectDb {
        self.0 .0.as_dyn()
    }
}

impl ObjectDb for SharedStore {
    fn hash_kind(&self) -> HashKind {
        self.as_dyn().hash_kind()
    }

    fn shallow_roots(&self) -> Option<&HashSet<Oid>> {
        self.as_dyn().shallow_roots()
    }

    fn try_header(&self, oid: &Oid, budget: &Budget) -> Result<Option<ObjectHeader>, Error> {
        self.as_dyn().try_header(oid, budget)
    }

    fn try_header_with_provenance(
        &self,
        oid: &Oid,
        budget: &Budget,
    ) -> Result<Option<gitility_core::HeaderRead>, Error> {
        self.as_dyn().try_header_with_provenance(oid, budget)
    }

    fn try_find(
        &self,
        oid: &Oid,
        out: &mut Vec<u8>,
        budget: &Budget,
    ) -> Result<Option<ObjectKind>, Error> {
        self.as_dyn().try_find(oid, out, budget)
    }

    fn try_find_many(&self, oids: &[Oid], budget: &Budget) -> Result<Vec<ObjectReadResult>, Error> {
        self.as_dyn().try_find_many(oids, budget)
    }

    fn try_find_many_bounded(
        &self,
        oids: &[Oid],
        budget: &Budget,
        read_budget: ReadManyBudget,
    ) -> Result<Vec<ObjectReadResult>, Error> {
        self.as_dyn()
            .try_find_many_bounded(oids, budget, read_budget)
    }

    fn prefetch(&self, oids: &[Oid], budget: &Budget) -> Result<(), Error> {
        self.as_dyn().prefetch(oids, budget)
    }

    fn supports_prefetch(&self) -> bool {
        self.as_dyn().supports_prefetch()
    }

    fn cache_stats(&self) -> CacheStats {
        self.as_dyn().cache_stats()
    }

    fn refresh(&self, budget: &Budget) -> Result<(), Error> {
        match &self.0 .0 {
            StoreImpl::Provider(_) | StoreImpl::Layered(_) => self.as_dyn().refresh(budget),
            StoreImpl::Local(_) | StoreImpl::Static(_) | StoreImpl::PackFetch(_) => {
                Err(Error::new(
                    ErrorCode::UnsupportedOperation,
                    "object store does not support refresh",
                ))
            }
        }
    }
}

#[derive(Clone, Copy, NifMap)]
struct RuntimeConfigMap {
    workers: usize,
    max_queue: usize,
    max_jobs_per_owner: usize,
    shutdown_join_timeout_ms: u64,
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
    pump_alive: bool,
    workers: u64,
    max_queue: u64,
    max_jobs_per_owner: u64,
    shutdown_join_timeout_ms: u64,
    detached_workers: u64,
    last_detach_reason: Option<String>,
    thread_budget_used: u64,
    thread_budget_limit: u64,
}

#[derive(NifMap)]
struct RuntimeShutdownMap {
    detached_workers: u64,
    last_detach_reason: Option<String>,
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
    pump_alive: Arc<AtomicBool>,
    shutdown_lock: Mutex<()>,
    shutdown_started: AtomicBool,
}

#[rustler::resource_impl]
impl Resource for RuntimeResource {}

impl Drop for RuntimeResource {
    fn drop(&mut self) {
        if !self.shutdown_started.swap(true, Ordering::AcqRel) {
            self.notifications.close();
            if !self.pump_alive.load(Ordering::Acquire) {
                // Last-resort teardown after the notification pump died.
                // Resource destruction can run on a scheduler, so it must not
                // join or delegate by spawning another thread. The core
                // request path wakes and drains the workers; their own RAII
                // guards return the process-wide thread-budget slots.
                self.runtime.request_shutdown();
            }
            // With a live pump, closing the channel delegates the explicit
            // bounded shutdown to that Rust-owned thread. Dropping the handle
            // here deliberately detaches it from this scheduler thread.
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
    Page { stopped_by_max_results: bool },
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
        // A malformed notification or Rustler panic must cost at most that
        // notification. Keeping this boundary inside the receive loop
        // preserves liveness for every later job.
        let _ = catch_unwind(AssertUnwindSafe(|| {
            notify_waiters(
                &mut env,
                notification.job_id,
                notification.waiters,
                &notification.waiter_state,
            );
        }));
    }
    let detached_before = runtime.counters().detached_workers;
    runtime.shutdown();
    let detached_after = runtime.counters().detached_workers;
    if detached_after > detached_before {
        let detached_delta = detached_after - detached_before;
        let reason = runtime
            .last_detach_reason()
            .unwrap_or_else(|| "reason unavailable".to_owned());
        eprintln!(
            "gitility: delegated runtime shutdown detached {detached_delta} worker(s): {reason}"
        );
    }
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
struct ProviderStoreOptions {
    request_timeout_ms: u64,
    object_cache_bytes: u64,
    header_cache_entries: u64,
    negative_ttl_ms: u64,
}

#[derive(Clone, Copy, NifMap)]
struct RefProviderStoreOptions {
    request_timeout_ms: u64,
}

#[derive(NifMap)]
struct PackFetchStoreOptions<'a> {
    request_timeout_ms: u64,
    destination: Binary<'a>,
    chunk_bytes: u64,
    concurrency: u64,
    max_hydration_bytes: u64,
    max_bytes: Option<u64>,
}

#[derive(Clone, Copy, NifMap)]
struct LayeredCacheOptions {
    max_bytes: u64,
    max_entries: u64,
    max_object_bytes: u64,
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

/// An authorization value decoded from the BEAM. Formatting this wrapper can
/// never reveal the value, including in Rustler decode diagnostics or panics.
struct Redacted(String);

impl Redacted {
    fn into_inner(self) -> String {
        self.0
    }
}

impl std::fmt::Debug for Redacted {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("[REDACTED]")
    }
}

impl std::fmt::Display for Redacted {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("[REDACTED]")
    }
}

impl<'a> Decoder<'a> for Redacted {
    fn decode(term: Term<'a>) -> NifResult<Self> {
        String::decode(term).map(Self)
    }
}

impl Encoder for Redacted {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        "[REDACTED]".encode(env)
    }
}

// Intentionally no Debug derive: the authorization field is radioactive.
#[derive(NifMap)]
struct FetchRequestMap {
    dest: String,
    url: String,
    refspecs: Vec<String>,
    authorization: Option<Redacted>,
    prune: bool,
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
struct RefQueryMap<'a> {
    prefix: Option<Binary<'a>>,
    limit: u64,
    cursor: Option<Binary<'a>>,
}

#[derive(NifMap)]
struct ReadFileOptions {
    lines: Option<(u32, u32)>,
    max_bytes: u64,
}

#[derive(NifMap)]
struct LogOptionsMap<'a> {
    order: Atom,
    first_parent: bool,
    since: Option<i64>,
    until: Option<i64>,
    limit: u64,
    cursor: Option<Binary<'a>>,
}

#[derive(NifMap)]
struct HistoryOptionsMap<'a> {
    follow_renames: bool,
    limit: u64,
    cursor: Option<Binary<'a>>,
}

#[derive(NifMap)]
struct BlameOptionsMap {
    lines: Option<(u32, u32)>,
    follow_renames: bool,
}

#[derive(NifMap)]
struct SearchOptionsMap<'a> {
    mode: Atom,
    case_sensitive: bool,
    path: Binary<'a>,
    pathspecs: Vec<Binary<'a>>,
    binary: Atom,
    context_lines: u32,
    limit: u64,
    cursor: Option<Binary<'a>>,
}

#[derive(NifMap)]
struct DiffOptionsMap<'a> {
    format: Atom,
    pathspecs: Vec<Binary<'a>>,
    context_lines: u32,
    renames: bool,
    copies: bool,
}

#[derive(NifMap)]
struct ErrorMap<'a> {
    code: Atom,
    message: String,
    retryable: bool,
    limit: Option<String>,
    layer: Option<u64>,
    oid: Option<Binary<'a>>,
    order: Option<String>,
    file: Option<String>,
    reason: Option<String>,
    line_count: Option<u32>,
    line: Option<u32>,
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
struct IdentityMap<'a> {
    name: Binary<'a>,
    email: Binary<'a>,
    time: i64,
    tz: Binary<'a>,
    tz_offset_minutes: Option<i32>,
}

#[derive(NifMap)]
struct CommitMap<'a> {
    id: Binary<'a>,
    parents: Vec<Binary<'a>>,
    tree_id: Binary<'a>,
    author: IdentityMap<'a>,
    committer: IdentityMap<'a>,
    subject: Binary<'a>,
    subject_truncated: bool,
    message_raw: Binary<'a>,
    message_truncated: bool,
    signature_headers: Vec<Binary<'a>>,
    encoding: Option<Binary<'a>>,
}

#[derive(NifMap)]
struct SearchSubmatchMap {
    start: u32,
    length: u32,
}

#[derive(NifMap)]
struct SearchMatchMap<'a> {
    commit_oid: Binary<'a>,
    blob_oid: Binary<'a>,
    path: Binary<'a>,
    line: u32,
    column: u32,
    preview: Binary<'a>,
    preview_truncated: bool,
    submatches: Vec<SearchSubmatchMap>,
    submatches_truncated: bool,
    context_before: Vec<Binary<'a>>,
    context_after: Vec<Binary<'a>>,
}

#[derive(NifMap)]
struct DiffLineMap<'a> {
    origin: Atom,
    content: Binary<'a>,
    old_line: Option<u32>,
    new_line: Option<u32>,
    no_newline: bool,
}

#[derive(NifMap)]
struct DiffHunkMap<'a> {
    old_start: u32,
    old_lines: u32,
    new_start: u32,
    new_lines: u32,
    header: Option<Binary<'a>>,
    lines: Vec<DiffLineMap<'a>>,
}

#[derive(NifMap)]
struct DiffFileMap<'a> {
    status: Atom,
    old_path: Option<Binary<'a>>,
    new_path: Option<Binary<'a>>,
    old_oid: Option<Binary<'a>>,
    new_oid: Option<Binary<'a>>,
    old_mode: Option<u32>,
    new_mode: Option<u32>,
    similarity: Option<u8>,
    additions: Option<u32>,
    deletions: Option<u32>,
    binary: bool,
    hunks: Vec<DiffHunkMap<'a>>,
}

#[derive(NifMap)]
struct DiffWarningMap {
    code: Atom,
    message: String,
}

#[derive(NifMap)]
struct StatsMap {
    objects_requested: u64,
    objects_read: u64,
    entries_emitted: u64,
    cache_hits: u64,
    cache_misses: u64,
    cache_bytes: u64,
    cache_entries: u64,
    cache_evictions: u64,
    provider_requests: u64,
    provider_bytes: u64,
    decompressed_bytes: u64,
    scanned_blobs: u64,
    files_scanned: u64,
    blobs_deduped: u64,
    binary_skipped: u64,
    oversize_skipped: u64,
    payload_rereads: u64,
    elapsed_ms: u64,
    stopped_by: Option<Atom>,
}

#[derive(NifMap)]
struct ByteRangeMap<'a> {
    key: Binary<'a>,
    offset: u64,
    length: u64,
}

#[derive(NifMap)]
struct HydrationStatsMap {
    generation: String,
    packs_hydrated: u64,
    bytes_fetched: u64,
    bytes_verified: u64,
    packs_skipped: u64,
    replaced_corrupt: u64,
    manifest_ms: u64,
    fetch_ms: u64,
    verify_ms: u64,
    write_ms: u64,
    open_ms: u64,
    elapsed_ms: u64,
}

#[derive(NifMap)]
struct FetchUpdatedRefMap {
    name: String,
    action: Atom,
    old_oid: Option<String>,
    new_oid: String,
}

#[derive(NifMap)]
struct FetchRejectedRefMap {
    name: String,
    reason: Atom,
}

#[derive(NifMap)]
struct FetchResultMap {
    updated_refs: Vec<FetchUpdatedRefMap>,
    rejected_refs: Vec<FetchRejectedRefMap>,
    pruned_refs: Vec<String>,
    remote_ref_count: u64,
    pack_received: bool,
}

#[derive(NifMap)]
struct TreePageMap<'a> {
    entries: Vec<TreeEntryMap<'a>>,
    next_cursor: Option<Binary<'a>>,
    truncated: bool,
    stats: StatsMap,
}

#[derive(NifMap)]
struct OidMap<'a> {
    algorithm: Atom,
    bytes: Binary<'a>,
}

#[derive(NifMap)]
struct RefTargetMap<'a> {
    kind: Atom,
    oid: Option<OidMap<'a>>,
    symbolic_target: Option<Binary<'a>>,
    peeled: Option<OidMap<'a>>,
}

#[derive(NifMap)]
struct RefEntryMap<'a> {
    name: Binary<'a>,
    target: RefTargetMap<'a>,
}

#[derive(NifMap)]
struct RefPageMap<'a> {
    refs: Vec<RefEntryMap<'a>>,
    next_cursor: Option<Binary<'a>>,
    truncated: bool,
    stats: StatsMap,
    warnings: Vec<DiffWarningMap>,
}

#[derive(NifMap)]
struct LogPageMap<'a> {
    commits: Vec<CommitMap<'a>>,
    next_cursor: Option<Binary<'a>>,
    truncated: bool,
    stats: StatsMap,
}

#[derive(NifMap)]
struct BlameHunkMap<'a> {
    final_start: u32,
    final_end: u32,
    original_start: u32,
    original_end: u32,
    commit_oid: Binary<'a>,
    original_path: Binary<'a>,
    author: IdentityMap<'a>,
    committer: IdentityMap<'a>,
    summary: Binary<'a>,
    boundary: bool,
}

#[derive(NifMap)]
struct BlameMap<'a> {
    path: Binary<'a>,
    hunks: Vec<BlameHunkMap<'a>>,
    stats: StatsMap,
    warnings: Vec<DiffWarningMap>,
}

#[derive(NifMap)]
struct SearchPageMap<'a> {
    matches: Vec<SearchMatchMap<'a>>,
    next_cursor: Option<Binary<'a>>,
    truncated: bool,
    stats: StatsMap,
}

#[derive(NifMap)]
struct DiffMap<'a> {
    files: Vec<DiffFileMap<'a>>,
    stats: StatsMap,
    warnings: Vec<DiffWarningMap>,
    truncated: bool,
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
    stats: StatsMap,
}

#[derive(NifMap)]
struct SubmoduleMap<'a> {
    name: Option<Binary<'a>>,
    path: Binary<'a>,
    url: Option<Binary<'a>>,
    branch: Option<Binary<'a>>,
    commit_oid: Option<Binary<'a>>,
    status: Atom,
}

#[derive(NifMap)]
struct SubmodulesMap<'a> {
    submodules: Vec<SubmoduleMap<'a>>,
}

enum ObjectOrNotFound<'a> {
    Object(ObjectMap<'a>),
    NotFound,
}

enum RefRequestPayload<'a> {
    Name(Binary<'a>),
    Query(RefQueryMap<'a>),
    Invalid,
}

impl Encoder for RefRequestPayload<'_> {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            Self::Name(name) => name.encode(env),
            Self::Query(query) => query.encode(env),
            Self::Invalid => atoms::nil().encode(env),
        }
    }
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

#[rustler::nif]
fn runtime_start(config: RuntimeConfigMap) -> NifResult<ResourceArc<RuntimeResource>> {
    let core_config = RuntimeConfig {
        workers: config.workers,
        max_queue: config.max_queue,
        max_jobs_per_owner: config.max_jobs_per_owner,
        retry_after_ms: 100,
        shutdown_join_timeout_ms: config.shutdown_join_timeout_ms,
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
    let pump_alive = Arc::new(AtomicBool::new(true));
    let pump_runtime = Arc::clone(&runtime);
    let pump_liveness = Arc::clone(&pump_alive);
    let pump = thread::Builder::new()
        .name("gitility-notify".to_owned())
        .spawn(move || {
            let _budget_reservation = pump_reservation;
            if catch_unwind(AssertUnwindSafe(|| {
                notification_pump(pump_runtime, notify_rx)
            }))
            .is_err()
                && pump_liveness.swap(false, Ordering::AcqRel)
            {
                eprintln!("gitility: notification pump died");
            }
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
        pump_alive,
        shutdown_lock: Mutex::new(()),
        shutdown_started: AtomicBool::new(false),
    }))
}

fn thread_budget_error(error: thread_budget::BudgetExhausted) -> rustler::Error {
    rustler::Error::RaiseTerm(Box::new(format!(
        "gitility thread budget exhausted: {error}"
    )))
}

#[rustler::nif(schedule = "DirtyIo")]
fn runtime_shutdown(runtime: ResourceArc<RuntimeResource>) -> RuntimeShutdownMap {
    // Keep the winner's core shutdown, channel close, and pump take/join in
    // one section. Concurrent callers wait here instead of stealing the pump
    // handle before the winner closes its channel.
    let _shutdown = lock(&runtime.shutdown_lock);
    if !runtime.shutdown_started.swap(true, Ordering::AcqRel) {
        runtime.runtime.shutdown();
        runtime.notifications.close();
        if let Some(pump) = lock(&runtime.pump).take() {
            let _ = pump.join();
        }
    }
    RuntimeShutdownMap {
        detached_workers: runtime.runtime.counters().detached_workers,
        last_detach_reason: runtime.runtime.last_detach_reason(),
    }
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
        pump_alive: runtime.pump_alive.load(Ordering::Acquire),
        workers: runtime.runtime.worker_count() as u64,
        max_queue: runtime.config.max_queue as u64,
        max_jobs_per_owner: runtime.config.max_jobs_per_owner as u64,
        shutdown_join_timeout_ms: runtime.config.shutdown_join_timeout_ms,
        detached_workers: counters.detached_workers,
        last_detach_reason: runtime.runtime.last_detach_reason(),
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
        Ok((store, hash)) => {
            let store = Arc::new(store);
            let (refs, refs_error) = match LocalRefDb::open(path, Arc::clone(&store)) {
                Ok(refs) => (
                    Some(ResourceArc::new(RefStoreResource(RefStoreImpl::Local(
                        refs,
                    )))),
                    None,
                ),
                Err(error) => (None, Some(error_map(env, error)?)),
            };
            Ok(Result::<_, ErrorMap>::Ok((
                ResourceArc::new(StoreResource(StoreImpl::Local(store))),
                refs,
                hash_atom(hash),
                refs_error,
            ))
            .encode(env))
        }
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

#[rustler::nif]
fn provider_store_new<'a>(
    env: Env<'a>,
    hash: Atom,
    opts: ProviderStoreOptions,
) -> NifResult<Term<'a>> {
    let hash = match parse_hash(hash) {
        Ok(hash) => hash,
        Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    };
    let header_cache_entries = match usize::try_from(opts.header_cache_entries) {
        Ok(value) => value,
        Err(_) => {
            let error = Error::new(
                ErrorCode::InvalidArgument,
                "provider header cache entry cap is too large",
            );
            return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env));
        }
    };
    let pending = Arc::new(PendingTable::default());
    let transport = NifProviderTransport {
        provider: env.pid(),
        pending: Arc::downgrade(&pending),
        hash,
    };
    let provider = ProviderOdb::new_with_pending(
        hash,
        ProviderOptions {
            request_timeout: Duration::from_millis(opts.request_timeout_ms),
            cache: ProviderCacheOptions {
                object_bytes: opts.object_cache_bytes,
                header_entries: header_cache_entries,
                negative_ttl: Duration::from_millis(opts.negative_ttl_ms),
            },
        },
        transport,
        pending,
    );
    Ok(Result::<_, ErrorMap>::Ok((
        ResourceArc::new(StoreResource(StoreImpl::Provider(Box::new(provider)))),
        hash_atom(hash),
    ))
    .encode(env))
}

#[rustler::nif]
fn ref_provider_store_new<'a>(env: Env<'a>, opts: RefProviderStoreOptions) -> NifResult<Term<'a>> {
    let pending = Arc::new(RefPendingTable::default());
    let transport = NifRefProviderTransport {
        provider: env.pid(),
        pending: Arc::downgrade(&pending),
    };
    let provider = ProviderRefDb::new_with_pending(
        RefProviderOptions {
            request_timeout: Duration::from_millis(opts.request_timeout_ms),
        },
        transport,
        pending,
    );
    Ok(
        Result::<_, ErrorMap>::Ok(ResourceArc::new(RefStoreResource(RefStoreImpl::Provider(
            Box::new(provider),
        ))))
        .encode(env),
    )
}

#[rustler::nif]
fn packfetch_store_new<'a>(
    env: Env<'a>,
    hash: Atom,
    opts: PackFetchStoreOptions<'a>,
) -> NifResult<Term<'a>> {
    let hash = match parse_hash(hash) {
        Ok(hash) => hash,
        Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    };
    let concurrency = match usize::try_from(opts.concurrency) {
        Ok(value) if value > 0 => value,
        _ => {
            let error = Error::new(
                ErrorCode::InvalidArgument,
                "PackFetch concurrency must be a positive platform-sized integer",
            );
            return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env));
        }
    };
    let pending = Arc::new(RangePendingTable::default());
    let sender = NifRangeRequestSender {
        provider: env.pid(),
        pending: Arc::downgrade(&pending),
    };
    let transport = CallbackRangeTransport::new_with_pending(
        sender,
        pending,
        Duration::from_millis(opts.request_timeout_ms),
    );
    let options = PackFetchOptions {
        destination: Path::new(OsStr::from_bytes(opts.destination.as_slice())).to_path_buf(),
        chunk_bytes: opts.chunk_bytes,
        concurrency,
        max_hydration_bytes: opts.max_hydration_bytes,
        max_bytes: opts.max_bytes,
    };
    match PackFetchOdb::new(hash, options, transport) {
        Ok(store) => Ok(Result::<_, ErrorMap>::Ok((
            ResourceArc::new(StoreResource(StoreImpl::PackFetch(Box::new(store)))),
            hash_atom(hash),
        ))
        .encode(env)),
        Err(error) => Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    }
}

#[rustler::nif]
fn layered_store_new<'a>(
    env: Env<'a>,
    stores: Vec<ResourceArc<StoreResource>>,
    cache: Option<LayeredCacheOptions>,
    cache_index: Option<u64>,
) -> NifResult<Term<'a>> {
    if stores.iter().any(|store| store.0.is_layered_with_cache()) {
        let error = Error::new(
            ErrorCode::InvalidArgument,
            "nested cache layers are not supported in 0.x",
        );
        return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env));
    }
    let cache = match (cache, cache_index) {
        (Some(options), Some(index)) => match usize::try_from(index) {
            Ok(index) => Some((
                index,
                CacheOptions {
                    max_bytes: options.max_bytes,
                    max_entries: options.max_entries,
                    max_object_bytes: options.max_object_bytes,
                },
            )),
            Err(_) => {
                let error = Error::new(
                    ErrorCode::InvalidArgument,
                    "cache layer position is too large",
                );
                return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env));
            }
        },
        (None, None) => None,
        _ => {
            let error = Error::new(
                ErrorCode::InvalidArgument,
                "cache options and position must be supplied together",
            );
            return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env));
        }
    };
    let layers = stores
        .into_iter()
        .map(|store| Arc::new(SharedStore(store)) as Arc<dyn ObjectDb>)
        .collect();
    match LayeredOdb::new(layers, cache) {
        Ok(store) => {
            let hash = store.hash_kind();
            Ok(Result::<_, ErrorMap>::Ok((
                ResourceArc::new(StoreResource(StoreImpl::Layered(store))),
                hash_atom(hash),
            ))
            .encode(env))
        }
        Err(error) => Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    }
}

/// Copies a provider reply on a dirty CPU scheduler. Binary sizes and object
/// IDs are checked while still borrowed from the BEAM term, before any
/// payload is copied into a Rust-owned `Vec`.
#[rustler::nif(schedule = "DirtyCpu")]
fn provider_reply(request: ResourceArc<RequestResource>, reply: Term<'_>) -> Atom {
    let Some(pending) = request.pending.upgrade() else {
        return atoms::ok();
    };
    match decode_provider_reply(&request, reply) {
        Ok(payload) => {
            pending.reply(request.id, payload);
        }
        Err(error) => {
            pending.reply_error(request.id, error);
        }
    }
    atoms::ok()
}

/// Validates and copies a reference-provider reply on a dirty CPU scheduler.
#[rustler::nif(schedule = "DirtyCpu")]
fn ref_provider_reply(request: ResourceArc<RefRequestResource>, reply: Term<'_>) -> Atom {
    let Some(pending) = request.pending.upgrade() else {
        return atoms::ok();
    };
    match decode_ref_provider_reply(&request, reply) {
        Ok(payload) => {
            pending.reply(request.id, payload);
        }
        Err(error) => {
            pending.reply_error(request.id, error);
        }
    }
    atoms::ok()
}

/// Copies range replies on a dirty CPU scheduler after exact byte-count
/// preflight. The ordered vector handed to core follows request order even
/// though the public backend contract returns a map.
#[rustler::nif(schedule = "DirtyCpu")]
fn range_reply(request: ResourceArc<RangeRequestResource>, reply: Term<'_>) -> Atom {
    let Some(pending) = request.pending.upgrade() else {
        return atoms::ok();
    };
    match decode_range_reply(&request, reply) {
        Ok(payload) => {
            pending.reply(request.id, payload);
        }
        Err(error) => {
            pending.reply_error(request.id, error);
        }
    }
    atoms::ok()
}

#[rustler::nif]
fn provider_failed(store: ResourceArc<StoreResource>) -> Atom {
    if let Some(provider) = store.0.as_provider() {
        provider.provider_down();
    } else if let Some(packfetch) = store.0.as_packfetch() {
        packfetch.provider_down();
    }
    atoms::ok()
}

#[rustler::nif]
fn ref_provider_failed(store: ResourceArc<RefStoreResource>) -> Atom {
    if let Some(provider) = store.0.as_provider() {
        provider.provider_down();
    }
    atoms::ok()
}

#[rustler::nif]
fn provider_refresh<'a>(env: Env<'a>, store: ResourceArc<StoreResource>) -> NifResult<Term<'a>> {
    let result = match &store.0 {
        StoreImpl::Provider(_) | StoreImpl::Layered(_) => {
            store.0.as_dyn().refresh(&Budget::unlimited())
        }
        StoreImpl::Local(_) | StoreImpl::Static(_) | StoreImpl::PackFetch(_) => Err(Error::new(
            ErrorCode::UnsupportedOperation,
            "refresh is supported only for provider and layered stores",
        )),
    };
    Ok(match result {
        Ok(()) => Result::<(), ErrorMap>::Ok(()).encode(env),
        Err(error) => Result::<(), _>::Err(error_map(env, error)?).encode(env),
    })
}

#[rustler::nif]
fn packfetch_stats<'a>(env: Env<'a>, store: ResourceArc<StoreResource>) -> NifResult<Term<'a>> {
    let Some(packfetch) = store.0.as_packfetch() else {
        let error = Error::new(
            ErrorCode::UnsupportedOperation,
            "hydration stats are available only for PackFetch stores",
        );
        return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env));
    };
    Ok(Result::<_, ErrorMap>::Ok(hydration_stats_map(packfetch.stats())).encode(env))
}

fn decode_ref_provider_reply(
    request: &RefRequestResource,
    reply: Term<'_>,
) -> Result<RefProviderPayload, Error> {
    let tuple = get_tuple(reply).map_err(|_| ref_protocol_error("invalid reply envelope"))?;
    if tuple.len() != 2 {
        return Err(ref_protocol_error("invalid reply envelope"));
    }
    let tag = tuple[0]
        .decode::<Atom>()
        .map_err(|_| ref_protocol_error("invalid reply envelope"))?;
    if tag == atoms::error() {
        if tuple[1]
            .decode::<Atom>()
            .is_ok_and(|reason| reason == atoms::provider_protocol_error())
        {
            return Err(ref_protocol_error(
                "ref provider returned an invalid continuation cursor",
            ));
        }
        return Ok(
            if tuple[1]
                .decode::<Atom>()
                .is_ok_and(|reason| reason == atoms::unsupported_operation())
            {
                RefProviderPayload::UnsupportedOperation
            } else {
                RefProviderPayload::BackendError
            },
        );
    }
    if tag != atoms::ok() {
        return Err(ref_protocol_error("invalid reply envelope"));
    }

    match request.kind {
        RefProviderKind::Resolve => {
            if tuple[1]
                .decode::<Atom>()
                .is_ok_and(|value| value == atoms::not_found())
            {
                Ok(RefProviderPayload::Resolve(None))
            } else {
                let target = decode_ref_target(tuple[1])?;
                if ref_target_bytes(&target) > request.max_reply_bytes {
                    return Err(ref_reply_too_large());
                }
                Ok(RefProviderPayload::Resolve(Some(target)))
            }
        }
        RefProviderKind::List => decode_ref_page(request, tuple[1]).map(RefProviderPayload::List),
    }
}

fn decode_ref_page(request: &RefRequestResource, term: Term<'_>) -> Result<RefPage, Error> {
    let items_term = term
        .map_get(atoms::items())
        .map_err(|_| ref_protocol_error("ref provider page items are missing"))?;
    let count = items_term
        .list_length()
        .map_err(|_| ref_protocol_error("ref provider page items must be a list"))?;
    if count > request.expected_limit {
        return Err(ref_protocol_error(
            "ref provider returned more references than the requested limit",
        ));
    }
    let next_cursor = decode_optional_binary_field(term, atoms::next_cursor(), "next_cursor")?;
    if next_cursor
        .as_ref()
        .is_some_and(|cursor| cursor.len() > gitility_core::cursor::MAX_CURSOR_BYTES)
    {
        return Err(ref_protocol_error("ref provider cursor exceeds 4096 bytes"));
    }
    let truncated = term
        .map_get(atoms::truncated())
        .and_then(bool::decode)
        .map_err(|_| ref_protocol_error("ref provider page truncated flag is invalid"))?;
    let item_terms = Vec::<Term<'_>>::decode(items_term)
        .map_err(|_| ref_protocol_error("ref provider page items must be a list"))?;
    let mut refs = Vec::with_capacity(item_terms.len());
    let mut total = next_cursor
        .as_ref()
        .map_or(0u64, |cursor| cursor.len() as u64);
    for item in item_terms {
        let name = decode_ref_name_field(item, atoms::name(), "ref name")?;
        if request
            .expected_prefix
            .as_deref()
            .is_some_and(|prefix| !name.starts_with(prefix))
        {
            return Err(ref_protocol_error(
                "ref provider returned a name outside the requested prefix",
            ));
        }
        let target_term = item
            .map_get(atoms::target())
            .map_err(|_| ref_protocol_error("ref provider item target is missing"))?;
        let target = decode_ref_target(target_term)?;
        total = total
            .saturating_add(name.len() as u64)
            .saturating_add(ref_target_bytes(&target));
        if total > request.max_reply_bytes {
            return Err(ref_reply_too_large());
        }
        refs.push((name, target));
    }
    Ok(RefPage {
        refs,
        next_cursor,
        truncated,
        warnings: Vec::new(),
    })
}

fn decode_ref_target(term: Term<'_>) -> Result<CoreRefTarget, Error> {
    let kind = term
        .map_get(atoms::kind())
        .and_then(Atom::decode)
        .map_err(|_| ref_protocol_error("ref provider target kind is invalid"))?;
    if kind == atoms::direct() {
        let oid_term = term
            .map_get(atoms::oid())
            .map_err(|_| ref_protocol_error("direct ref provider target has no object ID"))?;
        let oid = decode_ref_oid(oid_term)?;
        let peeled = decode_optional_oid_field(term, atoms::peeled(), "peeled")?;
        if peeled.is_some_and(|peeled| peeled.kind() != oid.kind()) {
            return Err(ref_protocol_error(
                "direct and peeled ref provider IDs use different hash algorithms",
            ));
        }
        let symbolic = term
            .map_get(atoms::symbolic_target())
            .map_err(|_| ref_protocol_error("direct ref provider target shape is incomplete"))?;
        if !is_nil(symbolic) {
            return Err(ref_protocol_error(
                "direct ref provider target has a symbolic target",
            ));
        }
        Ok(CoreRefTarget::Direct { oid, peeled })
    } else if kind == atoms::symbolic() {
        for field in [atoms::oid(), atoms::peeled()] {
            let value = term.map_get(field).map_err(|_| {
                ref_protocol_error("symbolic ref provider target shape is incomplete")
            })?;
            if !is_nil(value) {
                return Err(ref_protocol_error(
                    "symbolic ref provider target contains an object ID",
                ));
            }
        }
        let target = decode_ref_name_field(term, atoms::symbolic_target(), "symbolic target")?;
        Ok(CoreRefTarget::Symbolic(target))
    } else {
        Err(ref_protocol_error("ref provider target kind is unknown"))
    }
}

fn decode_ref_oid(term: Term<'_>) -> Result<Oid, Error> {
    let algorithm = term
        .map_get(atoms::algorithm())
        .and_then(Atom::decode)
        .map_err(|_| ref_protocol_error("ref provider object ID algorithm is invalid"))?;
    let hash = if algorithm == atoms::sha1() {
        HashKind::Sha1
    } else if algorithm == atoms::sha256() {
        HashKind::Sha256
    } else {
        return Err(ref_protocol_error(
            "ref provider object ID algorithm is unknown",
        ));
    };
    let bytes = term
        .map_get(atoms::bytes())
        .and_then(Binary::decode)
        .map_err(|_| ref_protocol_error("ref provider object ID bytes are invalid"))?;
    Oid::new(hash, bytes.as_slice())
        .map_err(|_| ref_protocol_error("ref provider object ID length is invalid"))
}

fn decode_optional_oid_field(
    term: Term<'_>,
    key: Atom,
    name: &'static str,
) -> Result<Option<Oid>, Error> {
    let value = term
        .map_get(key)
        .map_err(|_| ref_protocol_error("ref provider target is missing a field"))?;
    if is_nil(value) {
        Ok(None)
    } else {
        decode_ref_oid(value).map(Some).map_err(|_| {
            Error::new(
                ErrorCode::ProviderProtocolError,
                format!("ref provider {name} object ID is invalid"),
            )
        })
    }
}

fn decode_ref_name_field(term: Term<'_>, key: Atom, name: &'static str) -> Result<Vec<u8>, Error> {
    let bytes = term
        .map_get(key)
        .and_then(Binary::decode)
        .map_err(|_| ref_protocol_error("ref provider name field is not a binary"))?;
    if bytes.len() > gitility_core::cursor::MAX_CURSOR_BYTES {
        return Err(ref_protocol_error(
            "ref provider name exceeds the 4096-byte protocol ceiling",
        ));
    }
    gitility_core::validate_full_ref_name(bytes.as_slice()).map_err(|_| {
        Error::new(
            ErrorCode::ProviderProtocolError,
            format!("ref provider {name} is not a valid full ref name"),
        )
    })?;
    Ok(bytes.as_slice().to_vec())
}

fn decode_optional_binary_field(
    term: Term<'_>,
    key: Atom,
    name: &'static str,
) -> Result<Option<Vec<u8>>, Error> {
    let value = term
        .map_get(key)
        .map_err(|_| ref_protocol_error("ref provider page is missing a field"))?;
    if is_nil(value) {
        Ok(None)
    } else {
        Binary::decode(value)
            .map(|binary| Some(binary.as_slice().to_vec()))
            .map_err(|_| {
                Error::new(
                    ErrorCode::ProviderProtocolError,
                    format!("ref provider {name} must be a binary or nil"),
                )
            })
    }
}

fn is_nil(term: Term<'_>) -> bool {
    term.decode::<Atom>().is_ok_and(|atom| atom == atoms::nil())
}

fn ref_target_bytes(target: &CoreRefTarget) -> u64 {
    match target {
        CoreRefTarget::Symbolic(name) => name.len() as u64,
        CoreRefTarget::Direct { oid, peeled } => {
            oid.as_bytes().len() as u64
                + peeled
                    .as_ref()
                    .map_or(0, |peeled| peeled.as_bytes().len() as u64)
        }
    }
}

fn ref_reply_too_large() -> Error {
    Error::new(
        ErrorCode::BudgetExceeded,
        "ref provider reply exceeds max_provider_bytes",
    )
    .with_limit("max_provider_bytes")
}

fn ref_protocol_error(message: &'static str) -> Error {
    Error::new(ErrorCode::ProviderProtocolError, message)
}

fn decode_range_reply(
    request: &RangeRequestResource,
    reply: Term<'_>,
) -> Result<RangePayload, Error> {
    let tuple = get_tuple(reply).map_err(|_| range_protocol_error("invalid reply envelope"))?;
    if tuple.len() != 2 {
        return Err(range_protocol_error("invalid reply envelope"));
    }
    let tag = tuple[0]
        .decode::<Atom>()
        .map_err(|_| range_protocol_error("invalid reply envelope"))?;
    if tag == atoms::error() {
        return Ok(RangePayload::BackendError);
    }
    if tag != atoms::ok() {
        return Err(range_protocol_error("invalid reply envelope"));
    }

    match &request.expected {
        RangeRequestKind::Manifest => decode_pack_manifest(tuple[1]).map(RangePayload::Manifest),
        RangeRequestKind::ReadRanges(expected) => {
            let iterator = MapIterator::new(tuple[1])
                .ok_or_else(|| range_protocol_error("read_ranges reply must be a map"))?;
            let expected_set = expected.iter().cloned().collect::<HashSet<_>>();
            let mut seen = HashSet::with_capacity(expected.len());
            let mut total = 0u64;
            for (range_term, bytes_term) in iterator {
                let range = decode_byte_range(range_term)?;
                if !expected_set.contains(&range) || !seen.insert(range.clone()) {
                    return Err(range_protocol_error(
                        "read_ranges reply contains an unexpected or duplicate range",
                    ));
                }
                let bytes = Binary::decode(bytes_term).map_err(|_| {
                    range_protocol_error("read_ranges reply values must be binaries")
                })?;
                if bytes.len() as u64 != range.length {
                    return Err(range_protocol_error(
                        "read_ranges reply contains a short or over-long binary",
                    ));
                }
                total = total.checked_add(bytes.len() as u64).ok_or_else(|| {
                    range_protocol_error("read_ranges reply byte total overflows u64")
                })?;
                if total > request.max_reply_bytes {
                    return Err(range_protocol_error(
                        "read_ranges reply exceeds the requested byte total",
                    ));
                }
            }
            if seen.len() != expected_set.len() || total != request.max_reply_bytes {
                return Err(range_protocol_error(
                    "read_ranges reply is incomplete or has the wrong byte total",
                ));
            }

            // Only after the complete map has passed the exact size/key
            // preflight do we copy BEAM binaries into Rust-owned storage.
            let iterator = MapIterator::new(tuple[1])
                .ok_or_else(|| range_protocol_error("read_ranges reply must be a map"))?;
            let mut decoded = HashMap::with_capacity(expected.len());
            for (range_term, bytes_term) in iterator {
                let range = decode_byte_range(range_term)?;
                let bytes = Binary::decode(bytes_term).map_err(|_| {
                    range_protocol_error("read_ranges reply values must be binaries")
                })?;
                decoded.insert(range, bytes.as_slice().to_vec());
            }
            let ordered = expected
                .iter()
                .map(|range| {
                    decoded.remove(range).ok_or_else(|| {
                        range_protocol_error("read_ranges reply omitted a requested range")
                    })
                })
                .collect::<Result<Vec<_>, _>>()?;
            Ok(RangePayload::Ranges(ordered))
        }
    }
}

fn decode_pack_manifest(term: Term<'_>) -> Result<PackManifest, Error> {
    let version = term
        .map_get(atoms::version())
        .and_then(u32::decode)
        .map_err(|_| range_protocol_error("pack manifest version is invalid"))?;
    let generation = decode_utf8_map_binary(term, atoms::generation(), "generation")?;
    let hash = term
        .map_get(atoms::hash())
        .and_then(Atom::decode)
        .map_err(|_| range_protocol_error("pack manifest hash is invalid"))?;
    let hash = if hash == atoms::sha1() {
        HashKind::Sha1
    } else if hash == atoms::sha256() {
        HashKind::Sha256
    } else {
        return Err(range_protocol_error("pack manifest hash kind is unknown"));
    };
    let pack_list = term
        .map_get(atoms::packs())
        .map_err(|_| range_protocol_error("pack manifest packs must be a list"))?;
    let loose_list = term
        .map_get(atoms::loose())
        .map_err(|_| range_protocol_error("pack manifest loose must be a list"))?;
    let pack_count = pack_list
        .list_length()
        .map_err(|_| range_protocol_error("pack manifest packs must be a list"))?;
    let loose_count = loose_list
        .list_length()
        .map_err(|_| range_protocol_error("pack manifest loose must be a list"))?;
    if pack_count
        .checked_add(loose_count)
        .is_none_or(|count| count > MAX_PACK_MANIFEST_ENTRIES)
    {
        return Err(range_protocol_error(
            "pack manifest exceeds the 100000-entry protocol ceiling",
        ));
    }
    let pack_terms = Vec::<Term<'_>>::decode(pack_list)
        .map_err(|_| range_protocol_error("pack manifest packs must be a list"))?;
    let mut packs = Vec::with_capacity(pack_terms.len());
    for pack in pack_terms {
        packs.push(PackDescriptor {
            id: decode_utf8_map_binary(pack, atoms::id(), "id")?,
            pack_key: decode_utf8_map_binary(pack, atoms::pack_key(), "pack_key")?,
            index_key: decode_utf8_map_binary(pack, atoms::index_key(), "index_key")?,
            pack_size: pack
                .map_get(atoms::pack_size())
                .and_then(u64::decode)
                .map_err(|_| range_protocol_error("pack_size is invalid"))?,
            index_size: pack
                .map_get(atoms::index_size())
                .and_then(u64::decode)
                .map_err(|_| range_protocol_error("index_size is invalid"))?,
            etag: decode_optional_utf8_map_binary(pack, atoms::etag(), "etag")?,
        });
    }
    let loose_terms = Vec::<Term<'_>>::decode(loose_list)
        .map_err(|_| range_protocol_error("pack manifest loose must be a list"))?;
    let loose = loose_terms
        .into_iter()
        .map(|value| decode_utf8_binary(value, "loose key"))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(PackManifest {
        version,
        generation,
        hash,
        packs,
        loose,
    })
}

fn decode_byte_range(term: Term<'_>) -> Result<CoreByteRange, Error> {
    Ok(CoreByteRange {
        key: decode_utf8_map_binary(term, atoms::key(), "range key")?,
        offset: term
            .map_get(atoms::offset())
            .and_then(u64::decode)
            .map_err(|_| range_protocol_error("range offset is invalid"))?,
        length: term
            .map_get(atoms::length())
            .and_then(u64::decode)
            .map_err(|_| range_protocol_error("range length is invalid"))?,
    })
}

fn decode_utf8_map_binary(term: Term<'_>, key: Atom, name: &'static str) -> Result<String, Error> {
    let value = term
        .map_get(key)
        .map_err(|_| range_protocol_error("pack manifest map is missing a field"))?;
    decode_utf8_binary(value, name)
}

fn decode_optional_utf8_map_binary(
    term: Term<'_>,
    key: Atom,
    name: &'static str,
) -> Result<Option<String>, Error> {
    let value = term
        .map_get(key)
        .map_err(|_| range_protocol_error("pack descriptor is missing etag"))?;
    if value.is_atom()
        && value
            .decode::<Atom>()
            .is_ok_and(|atom| atom == atoms::nil())
    {
        Ok(None)
    } else {
        decode_utf8_binary(value, name).map(Some)
    }
}

fn decode_utf8_binary(term: Term<'_>, name: &'static str) -> Result<String, Error> {
    let bytes = Binary::decode(term)
        .map_err(|_| range_protocol_error("pack manifest strings must be binaries"))?;
    std::str::from_utf8(bytes.as_slice())
        .map(str::to_owned)
        .map_err(|_| {
            Error::new(
                ErrorCode::ProviderProtocolError,
                format!("{name} is not UTF-8"),
            )
        })
}

fn range_protocol_error(message: &'static str) -> Error {
    Error::new(ErrorCode::ProviderProtocolError, message)
}

fn decode_provider_reply(
    request: &RequestResource,
    reply: Term<'_>,
) -> Result<ProviderPayload, Error> {
    let tuple = get_tuple(reply).map_err(|_| provider_protocol_error("invalid reply envelope"))?;
    if tuple.len() != 2 {
        return Err(provider_protocol_error("invalid reply envelope"));
    }
    let tag = tuple[0]
        .decode::<Atom>()
        .map_err(|_| provider_protocol_error("invalid reply envelope"))?;
    if tag == atoms::error() {
        return Ok(ProviderPayload::BackendError);
    }
    if tag != atoms::ok() {
        return Err(provider_protocol_error("invalid reply envelope"));
    }
    if request.kind == ProviderKind::Prefetch {
        return Ok(ProviderPayload::Results(Vec::new()));
    }

    preflight_provider_results(request, tuple[1])?;
    let iterator = MapIterator::new(tuple[1]).expect("preflight proved the result is a map");
    let mut results = Vec::with_capacity(request.expected.len());
    for (oid_term, value_term) in iterator {
        let oid = decode_provider_oid(request.hash, oid_term)?;
        results.push((oid, decode_provider_value(request, oid, value_term)?));
    }
    Ok(ProviderPayload::Results(results))
}

/// Validates the complete reply, including cumulative caps, before the
/// decode pass copies the first payload byte into Rust-owned memory.
fn preflight_provider_results(
    request: &RequestResource,
    results_term: Term<'_>,
) -> Result<(), Error> {
    let iterator = MapIterator::new(results_term)
        .ok_or_else(|| provider_protocol_error("provider results must be a map"))?;
    let mut seen = HashSet::with_capacity(request.expected.len());
    let mut total_bytes = 0u64;
    for (oid_term, value_term) in iterator {
        let oid = decode_provider_oid(request.hash, oid_term)?;
        if !request.expected.contains(&oid) || !seen.insert(oid) {
            return Err(provider_protocol_error(
                "provider reply contains an unexpected or duplicate object ID",
            ));
        }
        total_bytes =
            total_bytes.saturating_add(preflight_provider_value(request, oid, value_term)?);
        if total_bytes > request.max_reply_bytes {
            return Err(
                Error::new(ErrorCode::BudgetExceeded, "max_provider_bytes exceeded")
                    .with_limit("max_provider_bytes"),
            );
        }
        if request
            .max_result_bytes
            .is_some_and(|maximum| total_bytes > maximum)
        {
            return Err(Error::new(
                ErrorCode::ResultTooLarge,
                "object batch exceeds max_total_bytes",
            )
            .with_limit("max_total_bytes"));
        }
    }
    if seen.len() != request.expected.len() {
        return Err(provider_protocol_error(
            "provider reply omitted a requested object ID",
        ));
    }
    Ok(())
}

fn preflight_provider_value(
    request: &RequestResource,
    oid: Oid,
    value: Term<'_>,
) -> Result<u64, Error> {
    if value.decode::<Atom>().ok() == Some(atoms::not_found()) {
        return Ok(0);
    }
    validate_embedded_oid(request.hash, oid, value)?;
    decode_provider_kind(value)?;
    match request.kind {
        ProviderKind::Object => provider_data_size(request, value),
        ProviderKind::Header => {
            if value.map_get(atoms::data()).is_ok() {
                provider_data_size(request, value)
            } else {
                let size = value
                    .map_get(atoms::size())
                    .and_then(u64::decode)
                    .map_err(|_| provider_protocol_error("provider header size is invalid"))?;
                if size > PROVIDER_HEADER_SIZE_CEILING {
                    return Err(provider_protocol_error(
                        "provider header size exceeds the 2^40 sanity ceiling",
                    ));
                }
                Ok(0)
            }
        }
        ProviderKind::Prefetch => unreachable!("prefetch returned before preflight"),
    }
}

fn provider_data_size(request: &RequestResource, value: Term<'_>) -> Result<u64, Error> {
    let data = value
        .map_get(atoms::data())
        .and_then(Binary::decode)
        .map_err(|_| provider_protocol_error("provider object data is invalid"))?;
    let bytes = data.len() as u64;
    if bytes > request.max_object_bytes {
        return Err(Error::new(
            ErrorCode::ObjectTooLarge,
            "provider object exceeds max_object_bytes",
        )
        .with_limit("max_object_bytes"));
    }
    Ok(bytes)
}

fn decode_provider_value(
    request: &RequestResource,
    oid: Oid,
    value: Term<'_>,
) -> Result<ProviderReplyValue, Error> {
    if value.decode::<Atom>().ok() == Some(atoms::not_found()) {
        return Ok(ProviderReplyValue::NotFound);
    }
    validate_embedded_oid(request.hash, oid, value)?;
    let kind = decode_provider_kind(value)?;
    match request.kind {
        ProviderKind::Object => Ok(ProviderReplyValue::Object {
            kind,
            data: Arc::new(
                value
                    .map_get(atoms::data())
                    .and_then(Binary::decode)
                    .expect("preflight proved provider object data")
                    .as_slice()
                    .to_vec(),
            ),
        }),
        ProviderKind::Header => match value.map_get(atoms::data()).and_then(Binary::decode) {
            Ok(data) => Ok(ProviderReplyValue::Object {
                kind,
                data: Arc::new(data.as_slice().to_vec()),
            }),
            Err(_) => Ok(ProviderReplyValue::Header(ObjectHeader {
                kind,
                size: value
                    .map_get(atoms::size())
                    .and_then(u64::decode)
                    .expect("preflight proved provider header size"),
            })),
        },
        ProviderKind::Prefetch => unreachable!("prefetch returned before decode"),
    }
}

fn decode_provider_oid(hash: HashKind, term: Term<'_>) -> Result<Oid, Error> {
    let algorithm = term
        .map_get(atoms::algorithm())
        .and_then(Atom::decode)
        .map_err(|_| provider_protocol_error("provider object ID is invalid"))?;
    if algorithm != hash_atom(hash) {
        return Err(provider_protocol_error(
            "provider object ID uses the wrong hash algorithm",
        ));
    }
    let bytes = term
        .map_get(atoms::bytes())
        .and_then(Binary::decode)
        .map_err(|_| provider_protocol_error("provider object ID is invalid"))?;
    Oid::new(hash, bytes.as_slice())
        .map_err(|_| provider_protocol_error("provider object ID is invalid"))
}

fn validate_embedded_oid(hash: HashKind, expected: Oid, term: Term<'_>) -> Result<(), Error> {
    let oid_term = term
        .map_get(atoms::oid())
        .map_err(|_| provider_protocol_error("provider result object ID is missing"))?;
    if decode_provider_oid(hash, oid_term)? == expected {
        Ok(())
    } else {
        Err(provider_protocol_error(
            "provider result object ID does not match its map key",
        ))
    }
}

fn decode_provider_kind(term: Term<'_>) -> Result<ObjectKind, Error> {
    let kind = term
        .map_get(atoms::type_atom())
        .and_then(Atom::decode)
        .map_err(|_| provider_protocol_error("provider object type is invalid"))?;
    parse_object_kind(kind).map_err(|_| provider_protocol_error("provider object type is invalid"))
}

fn provider_protocol_error(message: &'static str) -> Error {
    Error::new(ErrorCode::ProviderProtocolError, message)
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
fn job_submit_fetch<'a>(
    env: Env<'a>,
    runtime: ResourceArc<RuntimeResource>,
    request: FetchRequestMap,
    limits: LimitsMap,
) -> NifResult<Term<'a>> {
    let FetchRequestMap {
        dest,
        url,
        refspecs,
        authorization,
        prune,
    } = request;
    let request = FetchRequest {
        dest: dest.into(),
        url,
        refspecs,
        authorization: authorization.map(Redacted::into_inner),
        prune,
    };
    if let Err(error) = gitility_core::validate_fetch_request(&request) {
        return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env));
    }

    let task = Box::new(move |budget: &Budget| core_fetch(request, budget).map(JobOutput::Fetch));
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
    let mut seen = HashSet::with_capacity(raw_oids.len());
    for raw_oid in raw_oids {
        match oid_for_store(&store, raw_oid.as_slice()) {
            Ok(oid) if seen.insert(oid) => oids.push(oid),
            Ok(_duplicate) => {}
            Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
        }
    }
    let task_store = store.clone();
    let task = Box::new(move |budget: &Budget| {
        let mut results = Vec::with_capacity(oids.len());
        let values = task_store.0.as_dyn().try_find_many_bounded(
            &oids,
            budget,
            ReadManyBudget { max_total_bytes },
        )?;
        for (oid, value) in oids.into_iter().zip(values) {
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
fn packfetch_hydrate<'a>(
    env: Env<'a>,
    runtime: ResourceArc<RuntimeResource>,
    store: ResourceArc<StoreResource>,
    limits: LimitsMap,
) -> NifResult<Term<'a>> {
    submit_packfetch_job(env, runtime, store, limits)
}

#[rustler::nif]
fn packfetch_refresh<'a>(
    env: Env<'a>,
    runtime: ResourceArc<RuntimeResource>,
    store: ResourceArc<StoreResource>,
    limits: LimitsMap,
) -> NifResult<Term<'a>> {
    submit_packfetch_job(env, runtime, store, limits)
}

fn submit_packfetch_job<'a>(
    env: Env<'a>,
    runtime: ResourceArc<RuntimeResource>,
    store: ResourceArc<StoreResource>,
    limits: LimitsMap,
) -> NifResult<Term<'a>> {
    if store.0.as_packfetch().is_none() {
        let error = Error::new(
            ErrorCode::InvalidArgument,
            "expected a PackFetch object store",
        );
        return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env));
    }
    let task_store = store.clone();
    let task = Box::new(move |budget: &Budget| {
        task_store
            .0
            .as_packfetch()
            .expect("store kind checked before submission")
            .hydrate(budget)
            .map(JobOutput::Hydration)
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
fn job_submit_snapshot_open<'a>(
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
    let task = Box::new(move |budget: &Budget| {
        Snapshot::open(task_store.0.as_dyn(), oid, budget).map(JobOutput::Snapshot)
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
fn job_submit_snapshot_open_direct<'a>(
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
    let task = Box::new(move |budget: &Budget| {
        Snapshot::open_direct(task_store.0.as_dyn(), oid, budget).map(JobOutput::Snapshot)
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
fn job_submit_ref_resolve<'a>(
    env: Env<'a>,
    runtime: ResourceArc<RuntimeResource>,
    refs: ResourceArc<RefStoreResource>,
    name: Binary<'a>,
    limits: LimitsMap,
) -> NifResult<Term<'a>> {
    if let Err(error) = gitility_core::validate_full_ref_name(name.as_slice()) {
        return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env));
    }
    let name = name.as_slice().to_vec();
    let task_refs = refs.clone();
    let task = Box::new(move |budget: &Budget| {
        task_refs
            .0
            .as_dyn()
            .resolve_following(&name, budget)
            .map(JobOutput::RefTarget)
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
fn job_submit_ref_list<'a>(
    env: Env<'a>,
    runtime: ResourceArc<RuntimeResource>,
    refs: ResourceArc<RefStoreResource>,
    prefix: Option<Binary<'a>>,
    limit: u64,
    cursor: Option<Binary<'a>>,
    limits: LimitsMap,
) -> NifResult<Term<'a>> {
    if limit == 0 {
        let error = Error::new(
            ErrorCode::InvalidArgument,
            "reference page limit must be positive",
        );
        return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env));
    }
    let stopped_by_max_results = limits.max_results < limit;
    let effective_limit = limit.min(limits.max_results);
    let limit = match usize::try_from(effective_limit) {
        Ok(limit) => limit,
        Err(_) => {
            let error = Error::new(
                ErrorCode::InvalidArgument,
                "reference page limit is too large",
            );
            return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env));
        }
    };
    let query = CoreRefQuery {
        prefix: prefix.map(|prefix| prefix.as_slice().to_vec()),
        limit,
        cursor: cursor.map(|cursor| cursor.as_slice().to_vec()),
    };
    let task_refs = refs.clone();
    let task = Box::new(move |budget: &Budget| {
        task_refs
            .0
            .as_dyn()
            .list(query, budget)
            .map(JobOutput::Refs)
    });
    submit_job(
        env,
        runtime,
        false,
        limits,
        budget_limits(limits),
        JobResultKind::Page {
            stopped_by_max_results,
        },
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
        JobResultKind::Page {
            stopped_by_max_results,
        },
        task,
    )
}

#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn job_submit_search<'a>(
    env: Env<'a>,
    runtime: ResourceArc<RuntimeResource>,
    store: ResourceArc<StoreResource>,
    raw_commit_oid: Binary<'a>,
    raw_tree_oid: Binary<'a>,
    query: Binary<'a>,
    opts: SearchOptionsMap<'a>,
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
    let mode = match parse_search_mode(opts.mode) {
        Ok(mode) => mode,
        Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    };
    let binary_mode = match parse_search_binary_mode(opts.binary) {
        Ok(mode) => mode,
        Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    };
    let stopped_by_max_results = limits.max_results < opts.limit;
    let effective_limit = opts.limit.min(limits.max_results);
    let limit = match usize::try_from(effective_limit) {
        Ok(limit) => limit,
        Err(_) => {
            let error = Error::new(ErrorCode::InvalidArgument, "search page limit is too large");
            return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env));
        }
    };
    let query = query.as_slice().to_vec();
    let options = SearchOptions {
        mode,
        case_sensitive: opts.case_sensitive,
        path: opts.path.as_slice().to_vec(),
        pathspecs: opts
            .pathspecs
            .iter()
            .map(|pathspec| pathspec.as_slice().to_vec())
            .collect(),
        binary: binary_mode,
        context_lines: opts.context_lines,
        limit,
        max_result_bytes: limits.max_result_bytes,
        cursor: opts.cursor.map(|cursor| cursor.as_slice().to_vec()),
    };
    let task_store = store.clone();
    let task = Box::new(move |budget: &Budget| {
        core_search(
            task_store.0.as_dyn(),
            &Snapshot {
                commit_oid,
                tree_oid,
            },
            &query,
            &options,
            budget,
        )
        .map(JobOutput::Search)
    });
    submit_job(
        env,
        runtime,
        detach,
        limits,
        budget_limits(limits),
        JobResultKind::Page {
            stopped_by_max_results,
        },
        task,
    )
}

#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn job_submit_log<'a>(
    env: Env<'a>,
    runtime: ResourceArc<RuntimeResource>,
    store: ResourceArc<StoreResource>,
    raw_commit_oid: Binary<'a>,
    raw_tree_oid: Binary<'a>,
    opts: LogOptionsMap<'a>,
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
    let order = match parse_log_order(opts.order) {
        Ok(order) => order,
        Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    };
    let stopped_by_max_results = limits.max_results < opts.limit;
    let effective_limit = opts.limit.min(limits.max_results);
    let limit = match usize::try_from(effective_limit) {
        Ok(limit) => limit,
        Err(_) => {
            let error = Error::new(
                ErrorCode::InvalidArgument,
                "commit log page limit is too large",
            );
            return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env));
        }
    };
    let options = LogOptions {
        order,
        first_parent: opts.first_parent,
        since: opts.since,
        until: opts.until,
        limit,
        cursor: opts.cursor.map(|cursor| cursor.as_slice().to_vec()),
    };
    let task_store = store.clone();
    let task = Box::new(move |budget: &Budget| {
        core_log(
            task_store.0.as_dyn(),
            &Snapshot {
                commit_oid,
                tree_oid,
            },
            &options,
            budget,
        )
        .map(JobOutput::Log)
    });
    submit_job(
        env,
        runtime,
        detach,
        limits,
        budget_limits(limits),
        JobResultKind::Page {
            stopped_by_max_results,
        },
        task,
    )
}

#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn job_submit_history<'a>(
    env: Env<'a>,
    runtime: ResourceArc<RuntimeResource>,
    store: ResourceArc<StoreResource>,
    raw_commit_oid: Binary<'a>,
    raw_tree_oid: Binary<'a>,
    path: Binary<'a>,
    opts: HistoryOptionsMap<'a>,
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
    let stopped_by_max_results = limits.max_results < opts.limit;
    let effective_limit = opts.limit.min(limits.max_results);
    let limit = match usize::try_from(effective_limit) {
        Ok(limit) => limit,
        Err(_) => {
            let error = Error::new(
                ErrorCode::InvalidArgument,
                "history page limit is too large",
            );
            return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env));
        }
    };
    let path = path.as_slice().to_vec();
    let options = HistoryOptions {
        follow_renames: opts.follow_renames,
        limit,
        cursor: opts.cursor.map(|cursor| cursor.as_slice().to_vec()),
    };
    let task_store = store.clone();
    let task = Box::new(move |budget: &Budget| {
        core_history(
            task_store.0.as_dyn(),
            &Snapshot {
                commit_oid,
                tree_oid,
            },
            &path,
            &options,
            budget,
        )
        .map(JobOutput::History)
    });
    submit_job(
        env,
        runtime,
        detach,
        limits,
        budget_limits(limits),
        JobResultKind::Page {
            stopped_by_max_results,
        },
        task,
    )
}

#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn job_submit_blame<'a>(
    env: Env<'a>,
    runtime: ResourceArc<RuntimeResource>,
    store: ResourceArc<StoreResource>,
    raw_commit_oid: Binary<'a>,
    raw_tree_oid: Binary<'a>,
    path: Binary<'a>,
    opts: BlameOptionsMap,
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
    let path = path.as_slice().to_vec();
    let options = BlameOptions {
        lines: opts.lines,
        follow_renames: opts.follow_renames,
    };
    let task_store = store.clone();
    let task = Box::new(move |budget: &Budget| {
        core_blame(
            task_store.0.as_dyn(),
            &Snapshot {
                commit_oid,
                tree_oid,
            },
            &path,
            &options,
            budget,
        )
        .map(JobOutput::Blame)
    });
    submit_job(
        env,
        runtime,
        detach,
        limits,
        budget_limits(limits),
        JobResultKind::Other,
        task,
    )
}

#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn job_submit_diff<'a>(
    env: Env<'a>,
    runtime: ResourceArc<RuntimeResource>,
    base_store: ResourceArc<StoreResource>,
    base_commit_oid: Binary<'a>,
    base_tree_oid: Binary<'a>,
    head_store: ResourceArc<StoreResource>,
    head_commit_oid: Binary<'a>,
    head_tree_oid: Binary<'a>,
    opts: DiffOptionsMap<'a>,
    limits: LimitsMap,
    detach: bool,
) -> NifResult<Term<'a>> {
    if base_store.0.as_dyn().hash_kind() != head_store.0.as_dyn().hash_kind() {
        let error = Error::new(
            ErrorCode::HashMismatch,
            "diff object stores use different hash algorithms",
        );
        return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env));
    }
    let base_commit_oid = match oid_for_store(&base_store, base_commit_oid.as_slice()) {
        Ok(oid) => oid,
        Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    };
    let base_tree_oid = match oid_for_store(&base_store, base_tree_oid.as_slice()) {
        Ok(oid) => oid,
        Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    };
    let head_commit_oid = match oid_for_store(&head_store, head_commit_oid.as_slice()) {
        Ok(oid) => oid,
        Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    };
    let head_tree_oid = match oid_for_store(&head_store, head_tree_oid.as_slice()) {
        Ok(oid) => oid,
        Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    };
    let format = match parse_diff_format(opts.format) {
        Ok(format) => format,
        Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    };
    let max_diff_files = match usize::try_from(limits.max_diff_files) {
        Ok(value) => value,
        Err(_) => {
            let error = Error::new(ErrorCode::InvalidArgument, "max_diff_files is too large");
            return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env));
        }
    };
    let max_diff_hunks = match usize::try_from(limits.max_diff_hunks) {
        Ok(value) => value,
        Err(_) => {
            let error = Error::new(ErrorCode::InvalidArgument, "max_diff_hunks is too large");
            return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env));
        }
    };
    let max_diff_lines = match usize::try_from(limits.max_diff_lines) {
        Ok(value) => value,
        Err(_) => {
            let error = Error::new(ErrorCode::InvalidArgument, "max_diff_lines is too large");
            return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env));
        }
    };
    let options = DiffOptions {
        format,
        pathspecs: opts
            .pathspecs
            .iter()
            .map(|pathspec| pathspec.as_slice().to_vec())
            .collect(),
        context_lines: opts.context_lines,
        renames: if opts.renames {
            RenameTracking::Similarity
        } else {
            RenameTracking::Disabled
        },
        copies: opts.copies,
        max_diff_files,
        max_diff_hunks,
        max_diff_lines,
        max_object_bytes: limits.max_object_bytes,
    };
    let task_base_store = base_store.clone();
    let task_head_store = head_store.clone();
    let task = Box::new(move |budget: &Budget| {
        core_diff(
            task_base_store.0.as_dyn(),
            &Snapshot {
                commit_oid: base_commit_oid,
                tree_oid: base_tree_oid,
            },
            task_head_store.0.as_dyn(),
            &Snapshot {
                commit_oid: head_commit_oid,
                tree_oid: head_tree_oid,
            },
            &options,
            budget,
        )
        .map(JobOutput::Diff)
    });
    // Diff turns max_object_bytes into a successful suppression warning. A
    // provider may understate its header, so payload reads must reach core for
    // a second check against the semantic value retained in `options`.
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
fn job_submit_merge_base<'a>(
    env: Env<'a>,
    runtime: ResourceArc<RuntimeResource>,
    store: ResourceArc<StoreResource>,
    raw_left: Binary<'a>,
    raw_right: Binary<'a>,
    limits: LimitsMap,
) -> NifResult<Term<'a>> {
    let left = match oid_for_store(&store, raw_left.as_slice()) {
        Ok(oid) => oid,
        Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    };
    let right = match oid_for_store(&store, raw_right.as_slice()) {
        Ok(oid) => oid,
        Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    };
    let task_store = store.clone();
    let task = Box::new(move |budget: &Budget| {
        core_merge_base(task_store.0.as_dyn(), left, right, budget).map(JobOutput::Oids)
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
fn job_submit_is_ancestor<'a>(
    env: Env<'a>,
    runtime: ResourceArc<RuntimeResource>,
    store: ResourceArc<StoreResource>,
    raw_ancestor: Binary<'a>,
    raw_descendant: Binary<'a>,
    limits: LimitsMap,
) -> NifResult<Term<'a>> {
    let ancestor = match oid_for_store(&store, raw_ancestor.as_slice()) {
        Ok(oid) => oid,
        Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    };
    let descendant = match oid_for_store(&store, raw_descendant.as_slice()) {
        Ok(oid) => oid,
        Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    };
    let task_store = store.clone();
    let task = Box::new(move |budget: &Budget| {
        core_is_ancestor(task_store.0.as_dyn(), ancestor, descendant, budget)
            .map(JobOutput::Boolean)
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
#[allow(clippy::too_many_arguments)]
fn job_submit_submodules<'a>(
    env: Env<'a>,
    runtime: ResourceArc<RuntimeResource>,
    store: ResourceArc<StoreResource>,
    raw_commit_oid: Binary<'a>,
    raw_tree_oid: Binary<'a>,
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
    let task_store = store.clone();
    let task = Box::new(move |budget: &Budget| {
        core_submodules(
            task_store.0.as_dyn(),
            &Snapshot {
                commit_oid,
                tree_oid,
            },
            budget,
        )
        .map(JobOutput::Submodules)
    });
    submit_job(
        env,
        runtime,
        detach,
        limits,
        budget_limits(limits),
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
    let provider_spend = resource.job.spent();
    match result {
        Ok(output)
            if !allows_oversized_search_progress(&output)
                && output_payload_bytes(&output) > resource.max_result_bytes =>
        {
            let error = Error::new(
                ErrorCode::ResultTooLarge,
                "job result exceeds max_result_bytes and has been discarded",
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
                provider_spend,
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
    provider_spend: (u64, u64, u64, u64),
) -> NifResult<Term<'a>> {
    let term = match output {
        JobOutput::Diff(diff) => DiffMap {
            files: diff
                .files
                .into_iter()
                .map(|file| DiffFileMap {
                    status: diff_status_atom(file.status),
                    old_path: file.old_path.map(|path| binary(env, &path)),
                    new_path: file.new_path.map(|path| binary(env, &path)),
                    old_oid: file.old_oid.map(|oid| binary(env, oid.as_bytes())),
                    new_oid: file.new_oid.map(|oid| binary(env, oid.as_bytes())),
                    old_mode: file.old_mode,
                    new_mode: file.new_mode,
                    similarity: file.similarity,
                    additions: file.additions,
                    deletions: file.deletions,
                    binary: file.binary,
                    hunks: file
                        .hunks
                        .into_iter()
                        .map(|hunk| DiffHunkMap {
                            old_start: hunk.old_start,
                            old_lines: hunk.old_lines,
                            new_start: hunk.new_start,
                            new_lines: hunk.new_lines,
                            header: hunk.header.map(|header| binary(env, &header)),
                            lines: hunk
                                .lines
                                .into_iter()
                                .map(|line| DiffLineMap {
                                    origin: diff_line_origin_atom(line.origin),
                                    content: binary(env, &line.content),
                                    old_line: line.old_line,
                                    new_line: line.new_line,
                                    no_newline: line.no_newline,
                                })
                                .collect(),
                        })
                        .collect(),
                })
                .collect(),
            stats: stats_map(diff.stats, elapsed_ms, atoms::limit(), provider_spend),
            warnings: diff
                .warnings
                .into_iter()
                .map(|warning| DiffWarningMap {
                    code: diff_warning_atom(warning.code),
                    message: warning.message,
                })
                .collect(),
            truncated: diff.truncated,
        }
        .encode(env),
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
                JobResultKind::Page {
                    stopped_by_max_results: true,
                } => atoms::max_results(),
                JobResultKind::Page {
                    stopped_by_max_results: false,
                }
                | JobResultKind::Other => atoms::limit(),
            };
            TreePageMap {
                entries,
                next_cursor: page.next_cursor.map(|cursor| binary(env, &cursor)),
                truncated: page.truncated,
                stats: stats_map(page.stats, elapsed_ms, stopped_by, provider_spend),
            }
            .encode(env)
        }
        JobOutput::Search(page) => {
            let stopped_by = match result_kind {
                JobResultKind::Page {
                    stopped_by_max_results: true,
                } => atoms::max_results(),
                JobResultKind::Page {
                    stopped_by_max_results: false,
                }
                | JobResultKind::Other => atoms::limit(),
            };
            SearchPageMap {
                matches: page
                    .matches
                    .into_iter()
                    .map(|item| SearchMatchMap {
                        commit_oid: binary(env, item.commit_oid.as_bytes()),
                        blob_oid: binary(env, item.blob_oid.as_bytes()),
                        path: binary(env, &item.path),
                        line: item.line,
                        column: item.column,
                        preview: binary(env, &item.preview),
                        preview_truncated: item.preview_truncated,
                        submatches: item
                            .submatches
                            .into_iter()
                            .map(|range| SearchSubmatchMap {
                                start: range.start,
                                length: range.length,
                            })
                            .collect(),
                        submatches_truncated: item.submatches_truncated,
                        context_before: item
                            .context_before
                            .iter()
                            .map(|line| binary(env, line))
                            .collect(),
                        context_after: item
                            .context_after
                            .iter()
                            .map(|line| binary(env, line))
                            .collect(),
                    })
                    .collect(),
                next_cursor: page.next_cursor.map(|cursor| binary(env, &cursor)),
                truncated: page.truncated,
                stats: stats_map(page.stats, elapsed_ms, stopped_by, provider_spend),
            }
            .encode(env)
        }
        JobOutput::Log(page) => {
            let stopped_by = match result_kind {
                JobResultKind::Page {
                    stopped_by_max_results: true,
                } => atoms::max_results(),
                JobResultKind::Page {
                    stopped_by_max_results: false,
                }
                | JobResultKind::Other => atoms::limit(),
            };
            LogPageMap {
                commits: page
                    .commits
                    .into_iter()
                    .map(|commit| CommitMap {
                        id: binary(env, commit.id.as_bytes()),
                        parents: commit
                            .parents
                            .iter()
                            .map(|parent| binary(env, parent.as_bytes()))
                            .collect(),
                        tree_id: binary(env, commit.tree_id.as_bytes()),
                        author: identity_map(env, commit.author),
                        committer: identity_map(env, commit.committer),
                        subject: binary(env, &commit.subject),
                        subject_truncated: commit.subject_truncated,
                        message_raw: binary(env, &commit.message_raw),
                        message_truncated: commit.message_truncated,
                        signature_headers: commit
                            .signature_headers
                            .iter()
                            .map(|name| binary(env, name))
                            .collect(),
                        encoding: commit.encoding.map(|encoding| binary(env, &encoding)),
                    })
                    .collect(),
                next_cursor: page.next_cursor.map(|cursor| binary(env, &cursor)),
                truncated: page.truncated,
                stats: stats_map(page.stats, elapsed_ms, stopped_by, provider_spend),
            }
            .encode(env)
        }
        JobOutput::History(page) => {
            let stopped_by = match result_kind {
                JobResultKind::Page {
                    stopped_by_max_results: true,
                } => atoms::max_results(),
                JobResultKind::Page {
                    stopped_by_max_results: false,
                }
                | JobResultKind::Other => atoms::limit(),
            };
            LogPageMap {
                commits: page
                    .commits
                    .into_iter()
                    .map(|commit| CommitMap {
                        id: binary(env, commit.id.as_bytes()),
                        parents: commit
                            .parents
                            .iter()
                            .map(|parent| binary(env, parent.as_bytes()))
                            .collect(),
                        tree_id: binary(env, commit.tree_id.as_bytes()),
                        author: identity_map(env, commit.author),
                        committer: identity_map(env, commit.committer),
                        subject: binary(env, &commit.subject),
                        subject_truncated: commit.subject_truncated,
                        message_raw: binary(env, &commit.message_raw),
                        message_truncated: commit.message_truncated,
                        signature_headers: commit
                            .signature_headers
                            .iter()
                            .map(|name| binary(env, name))
                            .collect(),
                        encoding: commit.encoding.map(|encoding| binary(env, &encoding)),
                    })
                    .collect(),
                next_cursor: page.next_cursor.map(|cursor| binary(env, &cursor)),
                truncated: page.truncated,
                stats: stats_map(page.stats, elapsed_ms, stopped_by, provider_spend),
            }
            .encode(env)
        }
        JobOutput::Blame(blame) => BlameMap {
            path: binary(env, &blame.path),
            hunks: blame
                .hunks
                .into_iter()
                .map(|hunk| BlameHunkMap {
                    final_start: hunk.final_start,
                    final_end: hunk.final_end,
                    original_start: hunk.original_start,
                    original_end: hunk.original_end,
                    commit_oid: binary(env, hunk.commit_id.as_bytes()),
                    original_path: binary(env, &hunk.original_path),
                    author: identity_map(env, hunk.author),
                    committer: identity_map(env, hunk.committer),
                    summary: binary(env, &hunk.summary),
                    boundary: hunk.boundary,
                })
                .collect(),
            stats: stats_map(blame.stats, elapsed_ms, atoms::limit(), provider_spend),
            warnings: blame
                .warnings
                .into_iter()
                .map(|warning| DiffWarningMap {
                    code: diff_warning_atom(warning.code),
                    message: warning.message,
                })
                .collect(),
        }
        .encode(env),
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
            stats: stats_map(file.stats, elapsed_ms, atoms::limit(), provider_spend),
        }
        .encode(env),
        JobOutput::RefTarget(Some(target)) => ref_target_map(env, target).encode(env),
        JobOutput::RefTarget(None) => atoms::not_found().encode(env),
        JobOutput::Refs(page) => {
            let stopped_by = match result_kind {
                JobResultKind::Page {
                    stopped_by_max_results: true,
                } => atoms::max_results(),
                JobResultKind::Page {
                    stopped_by_max_results: false,
                }
                | JobResultKind::Other => atoms::limit(),
            };
            let mut stats = QueryStats {
                objects_read: provider_spend.0,
                bytes_read: provider_spend.1,
                entries_emitted: page.refs.len() as u64,
                ..QueryStats::default()
            };
            if page.truncated {
                stats.stopped_by = Some("limit");
            }
            RefPageMap {
                refs: page
                    .refs
                    .into_iter()
                    .map(|(name, target)| RefEntryMap {
                        name: binary(env, &name),
                        target: ref_target_map(env, target),
                    })
                    .collect(),
                next_cursor: page.next_cursor.map(|cursor| binary(env, &cursor)),
                truncated: page.truncated,
                stats: stats_map(stats, elapsed_ms, stopped_by, provider_spend),
                warnings: page
                    .warnings
                    .into_iter()
                    .map(|warning| DiffWarningMap {
                        code: atoms::malformed_ref(),
                        message: warning.message,
                    })
                    .collect(),
            }
            .encode(env)
        }
        JobOutput::Submodules(submodules) => SubmodulesMap {
            submodules: submodules
                .into_iter()
                .map(|submodule| SubmoduleMap {
                    name: submodule.name.map(|name| binary(env, &name)),
                    path: binary(env, &submodule.path),
                    url: submodule.url.map(|url| binary(env, &url)),
                    branch: submodule.branch.map(|branch| binary(env, &branch)),
                    commit_oid: submodule.commit_oid.map(|oid| binary(env, oid.as_bytes())),
                    status: submodule_status_atom(submodule.status),
                })
                .collect(),
        }
        .encode(env),
        JobOutput::Header(Some(header)) => HeaderMap {
            kind: object_kind_atom(header.kind),
            size: header.size,
        }
        .encode(env),
        JobOutput::Header(None) => atoms::not_found().encode(env),
        JobOutput::Object { kind, data } => object_map(env, kind, &data).encode(env),
        JobOutput::ReadMany(results) => results
            .into_iter()
            .map(|(oid, object)| {
                let value = match object {
                    Some((kind, data)) => {
                        ObjectOrNotFound::Object(object_map(env, kind, data.as_slice()))
                    }
                    None => ObjectOrNotFound::NotFound,
                };
                (binary(env, oid.as_bytes()), value)
            })
            .collect::<Vec<_>>()
            .encode(env),
        JobOutput::Oid(oid) => binary(env, oid.as_bytes()).encode(env),
        JobOutput::Oids(oids) => oids
            .iter()
            .map(|oid| binary(env, oid.as_bytes()))
            .collect::<Vec<_>>()
            .encode(env),
        JobOutput::Boolean(value) => value.encode(env),
        JobOutput::Snapshot(snapshot) => SnapshotMap {
            commit_oid: binary(env, snapshot.commit_oid.as_bytes()),
            tree_oid: binary(env, snapshot.tree_oid.as_bytes()),
        }
        .encode(env),
        JobOutput::Fetch(result) => FetchResultMap {
            updated_refs: result
                .updated_refs
                .into_iter()
                .map(|updated| FetchUpdatedRefMap {
                    name: updated.name,
                    action: fetch_action_atom(updated.action),
                    old_oid: updated.old_oid,
                    new_oid: updated.new_oid,
                })
                .collect(),
            rejected_refs: result
                .rejected_refs
                .into_iter()
                .map(|rejected| FetchRejectedRefMap {
                    name: rejected.name,
                    reason: fetch_rejection_atom(rejected.reason),
                })
                .collect(),
            pruned_refs: result.pruned_refs,
            remote_ref_count: result.remote_ref_count as u64,
            pack_received: result.pack_received,
        }
        .encode(env),
        JobOutput::Hydration(stats) => hydration_stats_map(stats).encode(env),
    };
    Ok(term)
}

fn output_payload_bytes(output: &JobOutput) -> u64 {
    fn length(bytes: &[u8]) -> u64 {
        u64::try_from(bytes.len()).unwrap_or(u64::MAX)
    }

    match output {
        JobOutput::Diff(diff) => diff.files.iter().fold(0u64, |total, file| {
            let hunks = file.hunks.iter().fold(0u64, |hunk_total, hunk| {
                let lines = hunk.lines.iter().fold(0u64, |line_total, line| {
                    line_total.saturating_add(length(&line.content))
                });
                hunk_total
                    .saturating_add(hunk.header.as_deref().map(length).unwrap_or(0))
                    .saturating_add(lines)
            });
            total
                .saturating_add(file.old_path.as_deref().map(length).unwrap_or(0))
                .saturating_add(file.new_path.as_deref().map(length).unwrap_or(0))
                .saturating_add(
                    file.old_oid
                        .as_ref()
                        .map(|oid| length(oid.as_bytes()))
                        .unwrap_or(0),
                )
                .saturating_add(
                    file.new_oid
                        .as_ref()
                        .map(|oid| length(oid.as_bytes()))
                        .unwrap_or(0),
                )
                .saturating_add(hunks)
        }),
        JobOutput::Tree(page) => page.entries.iter().fold(
            page.next_cursor.as_deref().map(length).unwrap_or(0),
            |total, entry| {
                total
                    .saturating_add(length(&entry.path))
                    .saturating_add(length(&entry.name))
                    .saturating_add(length(entry.oid.as_bytes()))
            },
        ),
        JobOutput::Search(page) => page.matches.iter().fold(
            page.next_cursor.as_deref().map(length).unwrap_or(0),
            |total, item| {
                let context = item
                    .context_before
                    .iter()
                    .chain(&item.context_after)
                    .fold(0u64, |total, line| total.saturating_add(length(line)));
                total
                    .saturating_add(length(item.commit_oid.as_bytes()))
                    .saturating_add(length(item.blob_oid.as_bytes()))
                    .saturating_add(length(&item.path))
                    .saturating_add(length(&item.preview))
                    .saturating_add(context)
                    .saturating_add((item.submatches.len() as u64).saturating_mul(32))
                    .saturating_add(16)
            },
        ),
        JobOutput::Log(page) => page.commits.iter().fold(
            page.next_cursor.as_deref().map(length).unwrap_or(0),
            |total, commit| {
                let parents = commit.parents.iter().fold(0u64, |total, parent| {
                    total.saturating_add(length(parent.as_bytes()))
                });
                let signatures = commit
                    .signature_headers
                    .iter()
                    .fold(0u64, |total, name| total.saturating_add(length(name)));
                total
                    .saturating_add(length(commit.id.as_bytes()))
                    .saturating_add(length(commit.tree_id.as_bytes()))
                    .saturating_add(parents)
                    .saturating_add(length(&commit.author.name))
                    .saturating_add(length(&commit.author.email))
                    .saturating_add(length(&commit.author.tz))
                    .saturating_add(length(&commit.committer.name))
                    .saturating_add(length(&commit.committer.email))
                    .saturating_add(length(&commit.committer.tz))
                    .saturating_add(length(&commit.subject))
                    .saturating_add(length(&commit.message_raw))
                    .saturating_add(signatures)
                    .saturating_add(commit.encoding.as_deref().map(length).unwrap_or_default())
            },
        ),
        JobOutput::History(page) => page.commits.iter().fold(
            page.next_cursor.as_deref().map(length).unwrap_or(0),
            |total, commit| {
                let parents = commit.parents.iter().fold(0u64, |total, parent| {
                    total.saturating_add(length(parent.as_bytes()))
                });
                total
                    .saturating_add(length(commit.id.as_bytes()))
                    .saturating_add(length(commit.tree_id.as_bytes()))
                    .saturating_add(parents)
                    .saturating_add(length(&commit.author.name))
                    .saturating_add(length(&commit.author.email))
                    .saturating_add(length(&commit.author.tz))
                    .saturating_add(length(&commit.committer.name))
                    .saturating_add(length(&commit.committer.email))
                    .saturating_add(length(&commit.committer.tz))
                    .saturating_add(length(&commit.subject))
                    .saturating_add(length(&commit.message_raw))
            },
        ),
        JobOutput::Blame(blame) => blame.hunks.iter().fold(length(&blame.path), |total, hunk| {
            total
                .saturating_add(length(hunk.commit_id.as_bytes()))
                .saturating_add(length(&hunk.original_path))
                .saturating_add(length(&hunk.author.name))
                .saturating_add(length(&hunk.author.email))
                .saturating_add(length(&hunk.author.tz))
                .saturating_add(length(&hunk.committer.name))
                .saturating_add(length(&hunk.committer.email))
                .saturating_add(length(&hunk.committer.tz))
                .saturating_add(length(&hunk.summary))
                .saturating_add(40)
        }),
        JobOutput::File(file) => length(&file.path)
            .saturating_add(length(file.blob_oid.as_bytes()))
            .saturating_add(length(&file.data))
            .saturating_add(
                file.lfs_pointer
                    .as_ref()
                    .map(|pointer| length(pointer.oid.as_bytes()))
                    .unwrap_or(0),
            ),
        JobOutput::RefTarget(target) => target.as_ref().map_or(0, ref_target_size),
        JobOutput::Refs(page) => page
            .refs
            .iter()
            .fold(
                page.next_cursor.as_deref().map(length).unwrap_or(0),
                |total, (name, target)| {
                    total
                        .saturating_add(length(name))
                        .saturating_add(ref_target_size(target))
                },
            )
            .saturating_add(page.warnings.iter().fold(0, |total, warning| {
                total.saturating_add(length(warning.message.as_bytes()))
            })),
        JobOutput::Submodules(submodules) => submodules.iter().fold(0, |total, submodule| {
            total
                .saturating_add(submodule.name.as_deref().map(length).unwrap_or(0))
                .saturating_add(length(&submodule.path))
                .saturating_add(submodule.url.as_deref().map(length).unwrap_or(0))
                .saturating_add(submodule.branch.as_deref().map(length).unwrap_or(0))
                .saturating_add(
                    submodule
                        .commit_oid
                        .as_ref()
                        .map(|oid| length(oid.as_bytes()))
                        .unwrap_or(0),
                )
                .saturating_add(16)
        }),
        JobOutput::Header(_) => 16,
        JobOutput::Object { data, .. } => length(data),
        JobOutput::ReadMany(results) => results.iter().fold(0, |total, (oid, object)| {
            total
                .saturating_add(length(oid.as_bytes()))
                .saturating_add(object.as_ref().map(|(_, data)| length(data)).unwrap_or(0))
        }),
        JobOutput::Oid(oid) => length(oid.as_bytes()),
        JobOutput::Oids(oids) => oids
            .iter()
            .fold(0, |total, oid| total.saturating_add(length(oid.as_bytes()))),
        JobOutput::Boolean(_) => 1,
        JobOutput::Snapshot(snapshot) => length(snapshot.commit_oid.as_bytes())
            .saturating_add(length(snapshot.tree_oid.as_bytes())),
        JobOutput::Fetch(result) => result
            .updated_refs
            .iter()
            .fold(0u64, |total, updated| {
                total
                    .saturating_add(length(updated.name.as_bytes()))
                    .saturating_add(
                        updated
                            .old_oid
                            .as_ref()
                            .map(|oid| length(oid.as_bytes()))
                            .unwrap_or(0),
                    )
                    .saturating_add(length(updated.new_oid.as_bytes()))
                    .saturating_add(16)
            })
            .saturating_add(result.rejected_refs.iter().fold(0u64, |total, rejected| {
                total
                    .saturating_add(length(rejected.name.as_bytes()))
                    .saturating_add(16)
            }))
            .saturating_add(result.pruned_refs.iter().fold(0u64, |total, name| {
                total.saturating_add(length(name.as_bytes()))
            }))
            .saturating_add(16),
        JobOutput::Hydration(stats) => length(stats.generation.as_bytes()).saturating_add(96),
    }
}

fn ref_target_size(target: &CoreRefTarget) -> u64 {
    fn length(bytes: &[u8]) -> u64 {
        u64::try_from(bytes.len()).unwrap_or(u64::MAX)
    }

    match target {
        CoreRefTarget::Symbolic(name) => length(name),
        CoreRefTarget::Direct { oid, peeled } => length(oid.as_bytes()).saturating_add(
            peeled
                .as_ref()
                .map(|peeled| length(peeled.as_bytes()))
                .unwrap_or(0),
        ),
    }
}

fn allows_oversized_search_progress(output: &JobOutput) -> bool {
    matches!(
        output,
        JobOutput::Search(page)
            if page.truncated
                && page.matches.len() == 1
                && page.stats.stopped_by == Some("max_result_bytes")
    )
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

fn object_map<'a>(env: Env<'a>, kind: ObjectKind, data: &[u8]) -> ObjectMap<'a> {
    ObjectMap {
        kind: object_kind_atom(kind),
        size: data.len() as u64,
        data: binary(env, data),
    }
}

fn ref_target_map<'a>(env: Env<'a>, target: CoreRefTarget) -> RefTargetMap<'a> {
    match target {
        CoreRefTarget::Direct { oid, peeled } => RefTargetMap {
            kind: atoms::direct(),
            oid: Some(oid_map(env, oid)),
            symbolic_target: None,
            peeled: peeled.map(|peeled| oid_map(env, peeled)),
        },
        CoreRefTarget::Symbolic(target) => RefTargetMap {
            kind: atoms::symbolic(),
            oid: None,
            symbolic_target: Some(binary(env, &target)),
            peeled: None,
        },
    }
}

fn oid_map(env: Env<'_>, oid: Oid) -> OidMap<'_> {
    OidMap {
        algorithm: hash_atom(oid.kind()),
        bytes: binary(env, oid.as_bytes()),
    }
}

fn identity_map<'a>(env: Env<'a>, identity: LogIdentity) -> IdentityMap<'a> {
    IdentityMap {
        name: binary(env, &identity.name),
        email: binary(env, &identity.email),
        time: identity.time,
        tz: binary(env, &identity.tz),
        tz_offset_minutes: identity.tz_offset_minutes,
    }
}

fn stats_map(
    stats: QueryStats,
    elapsed_ms: u64,
    page_limit_stopped_by: Atom,
    provider_spend: (u64, u64, u64, u64),
) -> StatsMap {
    StatsMap {
        objects_requested: stats.objects_read,
        objects_read: stats.objects_read,
        entries_emitted: stats.entries_emitted,
        cache_hits: stats.cache_hits,
        cache_misses: stats.cache_misses,
        cache_bytes: stats.cache_bytes,
        cache_entries: stats.cache_entries,
        cache_evictions: stats.cache_evictions,
        provider_requests: provider_spend.2,
        provider_bytes: provider_spend.3,
        decompressed_bytes: stats.bytes_read,
        scanned_blobs: stats.files_scanned,
        files_scanned: stats.files_scanned,
        blobs_deduped: stats.blobs_deduped,
        binary_skipped: stats.binary_skipped,
        oversize_skipped: stats.oversize_skipped,
        payload_rereads: stats.payload_rereads,
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

fn hydration_stats_map(stats: HydrationStats) -> HydrationStatsMap {
    HydrationStatsMap {
        generation: stats.generation,
        packs_hydrated: stats.packs_hydrated,
        bytes_fetched: stats.bytes_fetched,
        bytes_verified: stats.bytes_verified,
        packs_skipped: stats.packs_skipped,
        replaced_corrupt: stats.replaced_corrupt,
        manifest_ms: stats.manifest_ms,
        fetch_ms: stats.fetch_ms,
        verify_ms: stats.verify_ms,
        write_ms: stats.write_ms,
        open_ms: stats.open_ms,
        elapsed_ms: stats.elapsed_ms,
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

fn parse_log_order(order: Atom) -> Result<LogOrder, Error> {
    if order == atoms::chronological() {
        Ok(LogOrder::Chronological)
    } else if order == atoms::topological() {
        Ok(LogOrder::Topological)
    } else if order == atoms::date() {
        Ok(LogOrder::DateOrder)
    } else {
        Err(Error::new(
            ErrorCode::InvalidArgument,
            "commit log order must be chronological, topological, or date",
        ))
    }
}

fn parse_search_mode(mode: Atom) -> Result<SearchMode, Error> {
    if mode == atoms::literal() {
        Ok(SearchMode::Literal)
    } else if mode == atoms::regex() {
        Ok(SearchMode::Regex)
    } else {
        Err(Error::new(
            ErrorCode::InvalidArgument,
            "search mode must be literal or regex",
        ))
    }
}

fn parse_search_binary_mode(mode: Atom) -> Result<SearchBinaryMode, Error> {
    if mode == atoms::skip() {
        Ok(SearchBinaryMode::Skip)
    } else if mode == atoms::text() {
        Ok(SearchBinaryMode::Text)
    } else {
        Err(Error::new(
            ErrorCode::InvalidArgument,
            "search binary mode must be skip or text",
        ))
    }
}

fn parse_diff_format(format: Atom) -> Result<DiffFormat, Error> {
    if format == atoms::summary() {
        Ok(DiffFormat::Summary)
    } else if format == atoms::stats() {
        Ok(DiffFormat::Stats)
    } else if format == atoms::patch() {
        Ok(DiffFormat::Patch)
    } else {
        Err(Error::new(
            ErrorCode::InvalidArgument,
            "diff format must be summary, stats, or patch",
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

fn provider_kind_atom(kind: ProviderKind) -> Atom {
    match kind {
        ProviderKind::Header => atoms::header(),
        ProviderKind::Object => atoms::object(),
        ProviderKind::Prefetch => atoms::prefetch(),
    }
}

fn ref_provider_kind_atom(kind: RefProviderKind) -> Atom {
    match kind {
        RefProviderKind::Resolve => atoms::resolve(),
        RefProviderKind::List => atoms::list(),
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

fn submodule_status_atom(status: SubmoduleStatus) -> Atom {
    match status {
        SubmoduleStatus::Active => atoms::active(),
        SubmoduleStatus::Undeclared => atoms::undeclared(),
        SubmoduleStatus::Orphaned => atoms::orphaned(),
    }
}

fn fetch_action_atom(action: FetchAction) -> Atom {
    match action {
        FetchAction::Created => atoms::created(),
        FetchAction::FastForward => atoms::fast_forward(),
        FetchAction::Forced => atoms::forced(),
    }
}

fn fetch_rejection_atom(reason: FetchRejection) -> Atom {
    match reason {
        FetchRejection::SourceObjectNotFound => atoms::source_object_not_found(),
        FetchRejection::TagUpdate => atoms::tag_update(),
        FetchRejection::NonFastForward => atoms::non_fast_forward(),
        FetchRejection::ReplaceWithUnborn => atoms::replace_with_unborn(),
        FetchRejection::CurrentlyCheckedOut => atoms::currently_checked_out(),
    }
}

fn diff_status_atom(status: DiffStatus) -> Atom {
    match status {
        DiffStatus::Added => atoms::added(),
        DiffStatus::Deleted => atoms::deleted(),
        DiffStatus::Modified => atoms::modified(),
        DiffStatus::Renamed => atoms::renamed(),
        DiffStatus::Copied => atoms::copied(),
        DiffStatus::TypeChanged => atoms::type_changed(),
    }
}

fn diff_line_origin_atom(origin: DiffLineOrigin) -> Atom {
    match origin {
        DiffLineOrigin::Context => atoms::context(),
        DiffLineOrigin::Addition => atoms::addition(),
        DiffLineOrigin::Deletion => atoms::deletion(),
    }
}

fn diff_warning_atom(code: DiffWarningCode) -> Atom {
    match code {
        DiffWarningCode::Truncated => atoms::truncated(),
        DiffWarningCode::OversizeSkipped => atoms::oversize_skipped(),
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

fn error_map<'a>(env: Env<'a>, error: Error) -> NifResult<ErrorMap<'a>> {
    let line_count = error.line_count();
    let line = error.line();
    Ok(ErrorMap {
        code: Atom::from_str(env, error.code.as_str())?,
        message: error.message,
        retryable: error.retryable,
        limit: error.limit.map(str::to_owned),
        layer: error.layer,
        oid: error.object_oid.map(|oid| binary(env, oid.as_bytes())),
        order: error.order.map(|order| order.as_str().to_owned()),
        file: error.file.map(|file| file.as_str().to_owned()),
        reason: error
            .reason
            .map(|reason| truncate_utf8(reason.into(), 1_024)),
        line_count,
        line,
    })
}

fn truncate_utf8(mut value: String, max_bytes: usize) -> String {
    if value.len() <= max_bytes {
        return value;
    }
    let mut end = max_bytes;
    while !value.is_char_boundary(end) {
        end = end.saturating_sub(1);
    }
    value.truncate(end);
    value
}

fn limit_atom(limit: &str) -> Option<Atom> {
    match limit {
        "timeout_ms" => Some(atoms::timeout_ms()),
        "max_objects" => Some(atoms::max_objects()),
        "max_object_bytes" => Some(atoms::max_object_bytes()),
        "max_total_object_bytes" => Some(atoms::max_total_object_bytes()),
        "max_provider_requests" => Some(atoms::max_provider_requests()),
        "max_provider_bytes" => Some(atoms::max_provider_bytes()),
        "max_hydration_bytes" => Some(atoms::max_hydration_bytes()),
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

#[cfg(test)]
mod tests {
    use super::truncate_utf8;

    #[test]
    fn nif_error_reasons_are_capped_at_one_kibibyte_on_utf8_boundaries() {
        let ascii = truncate_utf8("x".repeat(2_000), 1_024);
        assert_eq!(ascii.len(), 1_024);

        let multibyte = truncate_utf8("é".repeat(1_000), 1_025);
        assert!(multibyte.len() <= 1_024);
        assert!(std::str::from_utf8(multibyte.as_bytes()).is_ok());
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
        unsupported_operation,
        gitility_provider_request,
        gitility_range_request,
        gitility_ref_request,
        sha1,
        sha256,
        commit,
        tree,
        blob,
        tag,
        symlink,
        gitlink,
        chronological,
        topological,
        date,
        literal,
        regex,
        skip,
        text,
        summary,
        stats,
        patch,
        binary,
        added,
        deleted,
        modified,
        renamed,
        copied,
        type_changed,
        active,
        created,
        fast_forward,
        forced,
        source_object_not_found,
        tag_update,
        non_fast_forward,
        replace_with_unborn,
        currently_checked_out,
        undeclared,
        orphaned,
        context,
        addition,
        deletion,
        truncated,
        oversize_skipped,
        malformed_ref,
        provider_protocol_error,
        header,
        object,
        prefetch,
        resolve,
        list,
        direct,
        symbolic,
        manifest,
        read_ranges,
        version,
        generation,
        hash,
        packs,
        loose,
        id,
        pack_key,
        index_key,
        pack_size,
        index_size,
        etag,
        key,
        offset,
        length,
        nil,
        algorithm,
        bytes,
        oid,
        name,
        kind,
        target,
        symbolic_target,
        peeled,
        items,
        next_cursor,
        data,
        size,
        type_atom = "type",
        limit,
        timeout_ms,
        max_objects,
        max_object_bytes,
        max_total_object_bytes,
        max_provider_requests,
        max_provider_bytes,
        max_hydration_bytes,
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
