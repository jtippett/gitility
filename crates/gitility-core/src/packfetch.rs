//! Eager, verified hydration of immutable remote pack manifests.
//!
//! The core owns planning, request windows, checksums, crash-safe file
//! publication, and the local object-store swap. Boundary crates only carry
//! requests and replies; this module has no BEAM concepts and starts no
//! threads.

use crate::budget::Budget;
use crate::error::{Error, ErrorCode};
use crate::local_odb::{LocalOdb, LocalOdbOptions};
use crate::object::{HashKind, ObjectHeader, ObjectKind, Oid};
use crate::odb::{CacheStats, ObjectDb, ObjectReadResult, ReadManyBudget};
use crate::verify::ContentHasher;
use std::collections::{BTreeMap, HashSet};
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex, MutexGuard, RwLock};
use std::time::{Duration, Instant};

const WAIT_SLICE: Duration = Duration::from_millis(50);
const DEFAULT_CHUNK_BYTES: u64 = 8 * 1024 * 1024;
static NEXT_TEMP_ID: AtomicU64 = AtomicU64::new(1);

/// One immutable pack and index pair in a published manifest.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PackDescriptor {
    pub id: String,
    pub pack_key: String,
    pub index_key: String,
    pub pack_size: u64,
    pub index_size: u64,
    pub etag: Option<String>,
}

/// A versioned, atomic inventory of immutable packs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PackManifest {
    pub version: u32,
    pub generation: String,
    pub hash: HashKind,
    pub packs: Vec<PackDescriptor>,
    pub loose: Vec<String>,
}

impl PackManifest {
    /// Validates all protocol invariants before hydration trusts sizes or keys.
    pub fn validate(&self, expected_hash: HashKind) -> Result<(), Error> {
        if self.version != 1 {
            return Err(protocol_error("pack manifest version must be 1"));
        }
        if self.hash != expected_hash {
            return Err(protocol_error(
                "pack manifest hash does not match the PackFetch store",
            ));
        }
        if self.generation.is_empty() {
            return Err(protocol_error("pack manifest generation must not be empty"));
        }
        if !self.loose.is_empty() {
            return Err(protocol_error(
                "PackFetch 0.2 manifests must not contain loose objects",
            ));
        }

        let mut ids = HashSet::with_capacity(self.packs.len());
        for pack in &self.packs {
            if pack.pack_key.is_empty() || pack.index_key.is_empty() {
                return Err(protocol_error("pack manifest keys must not be empty"));
            }
            if pack.pack_size == 0 || pack.index_size == 0 {
                return Err(protocol_error(
                    "pack manifest sizes must be greater than zero",
                ));
            }
            let id = Oid::parse_hex(&pack.id)
                .map_err(|_| protocol_error("pack manifest ID is not a full hex digest"))?;
            if id.kind() != self.hash {
                return Err(protocol_error(
                    "pack manifest ID length does not match its hash kind",
                ));
            }
            if !ids.insert(id) {
                return Err(protocol_error("pack manifest contains a duplicate pack ID"));
            }
        }
        Ok(())
    }

    fn described_bytes(&self) -> Result<u64, Error> {
        self.packs.iter().try_fold(0u64, |total, pack| {
            total
                .checked_add(pack.pack_size)
                .and_then(|value| value.checked_add(pack.index_size))
                .ok_or_else(|| protocol_error("pack manifest byte total overflows u64"))
        })
    }

    fn reply_bytes(&self) -> Result<u64, Error> {
        let mut total = 16u64
            .checked_add(self.generation.len() as u64)
            .ok_or_else(|| protocol_error("pack manifest reply byte total overflows u64"))?;
        for pack in &self.packs {
            total = total
                .checked_add(pack.id.len() as u64)
                .and_then(|value| value.checked_add(pack.pack_key.len() as u64))
                .and_then(|value| value.checked_add(pack.index_key.len() as u64))
                .and_then(|value| {
                    value.checked_add(pack.etag.as_ref().map_or(0, |etag| etag.len()) as u64)
                })
                .and_then(|value| value.checked_add(32))
                .ok_or_else(|| protocol_error("pack manifest reply byte total overflows u64"))?;
        }
        for key in &self.loose {
            total = total
                .checked_add(key.len() as u64)
                .ok_or_else(|| protocol_error("pack manifest reply byte total overflows u64"))?;
        }
        Ok(total)
    }
}

/// One exact byte range in a manifest artifact. Zero-length ranges are valid
/// and must receive an empty reply.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ByteRange {
    pub key: String,
    pub offset: u64,
    pub length: u64,
}

/// Callback request kind carried by a boundary transport.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RangeRequestKind {
    Manifest,
    ReadRanges(Vec<ByteRange>),
}

/// Decoded callback reply. Backend failures intentionally retain no backend
/// reason or term.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RangePayload {
    Manifest(PackManifest),
    Ranges(Vec<Vec<u8>>),
    BackendError,
}

type RangeReplySender = mpsc::SyncSender<Result<RangePayload, Error>>;

/// Receiving half of one range-backend rendezvous.
#[derive(Clone)]
pub struct RangeReplySlot {
    receiver: Arc<Mutex<mpsc::Receiver<Result<RangePayload, Error>>>>,
}

impl std::fmt::Debug for RangeReplySlot {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("RangeReplySlot")
            .finish_non_exhaustive()
    }
}

impl RangeReplySlot {
    fn pair() -> (Self, RangeReplySender) {
        let (sender, receiver) = mpsc::sync_channel(1);
        (
            Self {
                receiver: Arc::new(Mutex::new(receiver)),
            },
            sender,
        )
    }

    fn recv_timeout(
        &self,
        timeout: Duration,
    ) -> Result<Result<RangePayload, Error>, mpsc::RecvTimeoutError> {
        lock(&self.receiver).recv_timeout(timeout)
    }
}

/// Split-phase request passed to the NIF boundary. Sending is non-blocking;
/// the hydration worker waits on `reply` after opening its request window.
#[derive(Debug, Clone)]
pub struct RangeRequest {
    pub id: u64,
    pub kind: RangeRequestKind,
    pub reply: RangeReplySlot,
    pub deadline: Instant,
    pub max_reply_bytes: u64,
}

/// Sends a request toward a range backend without waiting for its reply.
pub trait RangeRequestSender: Send + Sync + 'static {
    fn request(&self, request: RangeRequest) -> Result<(), Error>;
}

/// Take-once range request table shared with boundary request resources.
#[derive(Default)]
pub struct RangePendingTable {
    senders: Mutex<BTreeMap<u64, RangeReplySender>>,
}

impl RangePendingTable {
    fn insert(&self, id: u64, sender: RangeReplySender) {
        lock(&self.senders).insert(id, sender);
    }

    pub fn reply(&self, id: u64, payload: RangePayload) -> bool {
        lock(&self.senders)
            .remove(&id)
            .is_some_and(|sender| sender.send(Ok(payload)).is_ok())
    }

    pub fn reply_error(&self, id: u64, error: Error) -> bool {
        lock(&self.senders)
            .remove(&id)
            .is_some_and(|sender| sender.send(Err(error)).is_ok())
    }

    pub fn cancel(&self, id: u64) -> bool {
        lock(&self.senders).remove(&id).is_some()
    }

    pub fn fail_all(&self, error: Error) {
        let senders = std::mem::take(&mut *lock(&self.senders));
        for (_, sender) in senders {
            let _ = sender.send(Err(error.clone()));
        }
    }
}

/// BEAM-free pack-range transport. The window method has a safe sequential
/// default; callback transports override it to issue all requests before
/// awaiting replies, achieving concurrency without spawning native threads.
pub trait RangeTransport: Send + Sync + 'static {
    fn manifest(&self, budget: &Budget) -> Result<PackManifest, Error>;

    fn read_ranges(&self, ranges: &[ByteRange], budget: &Budget) -> Result<Vec<Vec<u8>>, Error>;

    fn read_ranges_window(
        &self,
        batches: &[Vec<ByteRange>],
        budget: &Budget,
    ) -> Result<Vec<Vec<Vec<u8>>>, Error> {
        batches
            .iter()
            .map(|ranges| self.read_ranges(ranges, budget))
            .collect()
    }

    fn fail_all(&self, error: Error);
}

/// Request-resource implementation of [`RangeTransport`].
pub struct CallbackRangeTransport<S: RangeRequestSender> {
    sender: S,
    pending: Arc<RangePendingTable>,
    next_id: AtomicU64,
    alive: AtomicBool,
    request_timeout: Duration,
}

impl<S: RangeRequestSender> CallbackRangeTransport<S> {
    pub fn new_with_pending(
        sender: S,
        pending: Arc<RangePendingTable>,
        request_timeout: Duration,
    ) -> Self {
        Self {
            sender,
            pending,
            next_id: AtomicU64::new(1),
            alive: AtomicBool::new(true),
            request_timeout,
        }
    }

    pub fn provider_down(&self) {
        self.fail_all(provider_down());
    }

    fn ensure_alive(&self) -> Result<(), Error> {
        if self.alive.load(Ordering::Acquire) {
            Ok(())
        } else {
            Err(provider_down())
        }
    }

    fn begin(&self, kind: RangeRequestKind, budget: &Budget) -> Result<PendingRange, Error> {
        let now = Instant::now();
        let request_deadline = now.checked_add(self.request_timeout).unwrap_or(now);
        let deadline = budget
            .deadline()
            .map_or(request_deadline, |value| value.min(request_deadline));
        let max_reply_bytes = match &kind {
            RangeRequestKind::Manifest => budget
                .limits()
                .max_provider_bytes
                .saturating_sub(budget.spent().3),
            RangeRequestKind::ReadRanges(ranges) => {
                ranges.iter().try_fold(0u64, |total, range| {
                    total
                        .checked_add(range.length)
                        .ok_or_else(|| protocol_error("range reply byte total overflows u64"))
                })?
            }
        };
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (reply, sender) = RangeReplySlot::pair();
        self.pending.insert(id, sender);
        if let Err(error) = self.ensure_alive() {
            self.pending.cancel(id);
            return Err(error);
        }
        if let Err(error) = self.sender.request(RangeRequest {
            id,
            kind,
            reply: reply.clone(),
            deadline,
            max_reply_bytes,
        }) {
            self.pending.cancel(id);
            return Err(error);
        }
        Ok(PendingRange {
            id,
            reply,
            deadline,
        })
    }

    fn wait(&self, pending: &PendingRange, budget: &Budget) -> Result<RangePayload, Error> {
        loop {
            if let Err(error) = budget.check() {
                self.pending.cancel(pending.id);
                return Err(error);
            }
            let now = Instant::now();
            if now >= pending.deadline {
                self.pending.cancel(pending.id);
                if budget.deadline().is_some_and(|value| now >= value) {
                    return Err(Error::new(ErrorCode::Timeout, "operation budget expired"));
                }
                return Err(provider_timeout());
            }
            let slice = WAIT_SLICE.min(pending.deadline.saturating_duration_since(now));
            match pending.reply.recv_timeout(slice) {
                Ok(result) => return result,
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    self.pending.cancel(pending.id);
                    return Err(provider_down());
                }
            }
        }
    }
}

struct PendingRange {
    id: u64,
    reply: RangeReplySlot,
    deadline: Instant,
}

impl<S: RangeRequestSender> RangeTransport for CallbackRangeTransport<S> {
    fn manifest(&self, budget: &Budget) -> Result<PackManifest, Error> {
        match self.wait(&self.begin(RangeRequestKind::Manifest, budget)?, budget)? {
            RangePayload::Manifest(manifest) => Ok(manifest),
            RangePayload::BackendError => Err(backend_error()),
            RangePayload::Ranges(_) => Err(protocol_error(
                "range backend manifest reply has the wrong shape",
            )),
        }
    }

    fn read_ranges(&self, ranges: &[ByteRange], budget: &Budget) -> Result<Vec<Vec<u8>>, Error> {
        match self.wait(
            &self.begin(RangeRequestKind::ReadRanges(ranges.to_vec()), budget)?,
            budget,
        )? {
            RangePayload::Ranges(bytes) => Ok(bytes),
            RangePayload::BackendError => Err(backend_error()),
            RangePayload::Manifest(_) => Err(protocol_error(
                "range backend read_ranges reply has the wrong shape",
            )),
        }
    }

    fn read_ranges_window(
        &self,
        batches: &[Vec<ByteRange>],
        budget: &Budget,
    ) -> Result<Vec<Vec<Vec<u8>>>, Error> {
        let mut pending = Vec::with_capacity(batches.len());
        for ranges in batches {
            match self.begin(RangeRequestKind::ReadRanges(ranges.clone()), budget) {
                Ok(request) => pending.push(request),
                Err(error) => {
                    for request in &pending {
                        self.pending.cancel(request.id);
                    }
                    return Err(error);
                }
            }
        }
        let mut replies = Vec::with_capacity(pending.len());
        for (index, request) in pending.iter().enumerate() {
            match self.wait(request, budget) {
                Ok(RangePayload::Ranges(bytes)) => replies.push(bytes),
                Ok(RangePayload::BackendError) => {
                    for remaining in &pending[index + 1..] {
                        self.pending.cancel(remaining.id);
                    }
                    return Err(backend_error());
                }
                Ok(RangePayload::Manifest(_)) => {
                    for remaining in &pending[index + 1..] {
                        self.pending.cancel(remaining.id);
                    }
                    return Err(protocol_error(
                        "range backend read_ranges reply has the wrong shape",
                    ));
                }
                Err(error) => {
                    for remaining in &pending[index + 1..] {
                        self.pending.cancel(remaining.id);
                    }
                    return Err(error);
                }
            }
        }
        Ok(replies)
    }

    fn fail_all(&self, error: Error) {
        self.alive.store(false, Ordering::Release);
        self.pending.fail_all(error);
    }
}

/// Eager hydration configuration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PackFetchOptions {
    pub destination: PathBuf,
    pub chunk_bytes: u64,
    pub concurrency: usize,
    pub max_hydration_bytes: u64,
    pub max_bytes: Option<u64>,
}

impl PackFetchOptions {
    pub fn validate(&self) -> Result<(), Error> {
        if self.chunk_bytes == 0 {
            return Err(Error::new(
                ErrorCode::InvalidArgument,
                "chunk_bytes must be greater than zero",
            ));
        }
        if self.concurrency == 0 {
            return Err(Error::new(
                ErrorCode::InvalidArgument,
                "concurrency must be greater than zero",
            ));
        }
        if self.destination.as_os_str().is_empty() {
            return Err(Error::new(
                ErrorCode::InvalidArgument,
                "PackFetch destination must not be empty",
            ));
        }
        if self.max_hydration_bytes == 0 {
            return Err(Error::new(
                ErrorCode::InvalidArgument,
                "max_hydration_bytes must be greater than zero",
            ));
        }
        Ok(())
    }
}

impl Default for PackFetchOptions {
    fn default() -> Self {
        Self {
            destination: PathBuf::new(),
            chunk_bytes: DEFAULT_CHUNK_BYTES,
            concurrency: 8,
            max_hydration_bytes: 4 * 1024 * 1024 * 1024,
            max_bytes: None,
        }
    }
}

/// Last completed hydration or refresh accounting.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HydrationStats {
    pub generation: String,
    pub packs_hydrated: u64,
    pub bytes_fetched: u64,
    pub bytes_verified: u64,
    pub packs_skipped: u64,
    pub replaced_corrupt: u64,
    pub manifest_ms: u64,
    pub fetch_ms: u64,
    pub verify_ms: u64,
    pub write_ms: u64,
    pub open_ms: u64,
    pub elapsed_ms: u64,
}

/// An ObjectDb that becomes usable after eager hydration.
pub struct PackFetchOdb<T: RangeTransport> {
    hash: HashKind,
    transport: T,
    options: PackFetchOptions,
    local: RwLock<Option<Arc<LocalOdb>>>,
    stats: Mutex<HydrationStats>,
    hydration: Mutex<()>,
    verified_packs: Mutex<HashSet<String>>,
}

struct HydrationPlanItem<'a> {
    descriptor: &'a PackDescriptor,
    fetch: bool,
}

impl<T: RangeTransport> PackFetchOdb<T> {
    pub fn new(hash: HashKind, options: PackFetchOptions, transport: T) -> Result<Self, Error> {
        options.validate()?;
        Ok(Self {
            hash,
            transport,
            options,
            local: RwLock::new(None),
            stats: Mutex::new(HydrationStats::default()),
            hydration: Mutex::new(()),
            verified_packs: Mutex::new(HashSet::new()),
        })
    }

    pub fn hydrate(&self, budget: &Budget) -> Result<HydrationStats, Error> {
        let _hydration = lock(&self.hydration);
        let total_started = Instant::now();
        budget.charge_provider_request()?;
        let manifest_started = Instant::now();
        let manifest = self.transport.manifest(budget)?;
        let manifest_ms = elapsed_ms(manifest_started);
        manifest.validate(self.hash)?;
        manifest.described_bytes()?;
        let manifest_bytes = manifest.reply_bytes()?;
        if manifest_bytes > self.options.max_hydration_bytes {
            return Err(hydration_budget_error(
                "pack manifest reply exceeds max_hydration_bytes",
            ));
        }
        budget
            .charge_provider_bytes(manifest_bytes)
            .map_err(|error| remap_hydration_budget(error, "pack manifest reply"))?;
        let object_dir = self.options.destination.join("objects");
        let pack_dir = object_dir.join("pack");
        std::fs::create_dir_all(&pack_dir).map_err(|_| {
            Error::new(
                ErrorCode::BackendError,
                "could not create PackFetch destination directory",
            )
        })?;
        if let Some(maximum) = self.options.max_bytes {
            let projected = projected_destination_bytes(&pack_dir, &manifest)?;
            if projected > maximum {
                return Err(Error::new(
                    ErrorCode::BudgetExceeded,
                    "hydrated memory destination exceeds max_bytes",
                )
                .with_limit("max_bytes"));
            }
        }

        let mut stats = HydrationStats {
            generation: manifest.generation.clone(),
            manifest_ms,
            ..HydrationStats::default()
        };
        let plan = self.plan_hydration(&manifest, &pack_dir, budget, &mut stats)?;
        let bytes_to_fetch = plan.iter().try_fold(0u64, |total, item| {
            if item.fetch {
                total
                    .checked_add(item.descriptor.pack_size)
                    .and_then(|value| value.checked_add(item.descriptor.index_size))
                    .ok_or_else(|| protocol_error("pack hydration byte total overflows u64"))
            } else {
                Ok(total)
            }
        })?;
        if bytes_to_fetch
            > self
                .options
                .max_hydration_bytes
                .saturating_sub(manifest_bytes)
        {
            return Err(hydration_budget_error(
                "pack hydration plan exceeds max_hydration_bytes before fetching",
            ));
        }

        for item in &plan {
            let descriptor = item.descriptor;
            if !item.fetch {
                continue;
            }
            budget.check()?;
            let id = Oid::parse_hex(&descriptor.id)
                .map_err(|_| protocol_error("validated pack ID could not be parsed"))?;
            let stem = format!("pack-{}", id.to_hex());
            let pack_path = pack_dir.join(format!("{stem}.pack"));
            let index_path = pack_dir.join(format!("{stem}.idx"));
            let fetch_started = Instant::now();
            let index = self.fetch_artifact(
                &descriptor.index_key,
                descriptor.index_size,
                descriptor.index_size,
                budget,
            )?;
            let pack = self.fetch_artifact(
                &descriptor.pack_key,
                descriptor.pack_size,
                self.options.chunk_bytes,
                budget,
            )?;
            stats.fetch_ms = stats.fetch_ms.saturating_add(elapsed_ms(fetch_started));
            stats.bytes_fetched = stats
                .bytes_fetched
                .saturating_add(index.len() as u64)
                .saturating_add(pack.len() as u64);

            let verify_started = Instant::now();
            verify_pair_bytes(&pack, &index, descriptor, self.hash)?;
            let verified = pack.len() as u64 + index.len() as u64;
            budget.check()?;
            stats.bytes_verified = stats.bytes_verified.saturating_add(verified);
            stats.verify_ms = stats.verify_ms.saturating_add(elapsed_ms(verify_started));

            let write_started = Instant::now();
            write_pair_atomically(&pack_path, &index_path, &pack, &index)?;
            stats.write_ms = stats.write_ms.saturating_add(elapsed_ms(write_started));
            stats.packs_hydrated += 1;
            lock(&self.verified_packs).insert(descriptor.id.clone());
        }

        let open_started = Instant::now();
        let local = LocalOdb::open_objects_dir(
            &object_dir,
            self.hash,
            LocalOdbOptions {
                // Acquisition above is the unconditional trust boundary; a
                // second full scan before the first query would duplicate it.
                verify_pack_checksums: false,
            },
        )?;
        self.probe_hydrated_packs(&local, &manifest, &pack_dir, budget)?;
        *write_lock(&self.local) = Some(Arc::new(local));
        stats.open_ms = elapsed_ms(open_started);
        stats.elapsed_ms = elapsed_ms(total_started);
        *lock(&self.stats) = stats.clone();
        Ok(stats)
    }

    pub fn stats(&self) -> HydrationStats {
        lock(&self.stats).clone()
    }

    pub fn provider_down(&self) {
        self.transport.fail_all(provider_down());
    }

    fn plan_hydration<'a>(
        &self,
        manifest: &'a PackManifest,
        pack_dir: &Path,
        budget: &Budget,
        stats: &mut HydrationStats,
    ) -> Result<Vec<HydrationPlanItem<'a>>, Error> {
        let mut plan = Vec::with_capacity(manifest.packs.len());
        for descriptor in &manifest.packs {
            budget.check()?;
            let stem = format!("pack-{}", descriptor.id.to_ascii_lowercase());
            let pack_path = pack_dir.join(format!("{stem}.pack"));
            let index_path = pack_dir.join(format!("{stem}.idx"));
            let pack_exists = pack_path.is_file();
            let index_exists = index_path.is_file();
            let verified_here = lock(&self.verified_packs).contains(&descriptor.id);

            if pack_exists && index_exists {
                let verify_started = Instant::now();
                let verification = if verified_here {
                    verify_pair_sizes(&pack_path, &index_path, descriptor).map(|()| 0)
                } else {
                    verify_pair_paths(&pack_path, &index_path, descriptor, self.hash, budget)
                };
                match verification {
                    Ok(bytes) => {
                        stats.bytes_verified = stats.bytes_verified.saturating_add(bytes);
                        stats.verify_ms =
                            stats.verify_ms.saturating_add(elapsed_ms(verify_started));
                        stats.packs_skipped += 1;
                        lock(&self.verified_packs).insert(descriptor.id.clone());
                        plan.push(HydrationPlanItem {
                            descriptor,
                            fetch: false,
                        });
                        continue;
                    }
                    Err(error)
                        if matches!(
                            error.code,
                            ErrorCode::PackChecksumMismatch | ErrorCode::IndexChecksumMismatch
                        ) =>
                    {
                        stats.verify_ms =
                            stats.verify_ms.saturating_add(elapsed_ms(verify_started));
                        stats.replaced_corrupt += 1;
                        lock(&self.verified_packs).remove(&descriptor.id);
                        remove_destination_pair(pack_dir, &descriptor.id);
                    }
                    Err(error) => return Err(error),
                }
            } else if pack_exists || index_exists {
                stats.replaced_corrupt += 1;
                lock(&self.verified_packs).remove(&descriptor.id);
                remove_destination_pair(pack_dir, &descriptor.id);
            }

            plan.push(HydrationPlanItem {
                descriptor,
                fetch: true,
            });
        }
        Ok(plan)
    }

    fn probe_hydrated_packs(
        &self,
        local: &LocalOdb,
        manifest: &PackManifest,
        pack_dir: &Path,
        budget: &Budget,
    ) -> Result<(), Error> {
        for descriptor in &manifest.packs {
            budget.check()?;
            let index_path =
                pack_dir.join(format!("pack-{}.idx", descriptor.id.to_ascii_lowercase()));
            let probe = first_index_oid(&index_path, self.hash)
                .and_then(|oid| local.try_header(&oid, budget).map(|header| (oid, header)));
            if !matches!(probe, Ok((_oid, Some(_header)))) {
                remove_destination_pair(pack_dir, &descriptor.id);
                lock(&self.verified_packs).remove(&descriptor.id);
                return Err(Error::new(
                    ErrorCode::MalformedObject,
                    format!("hydrated pack {} failed the open-time probe", descriptor.id),
                ));
            }
        }
        Ok(())
    }

    fn fetch_artifact(
        &self,
        key: &str,
        size: u64,
        chunk_bytes: u64,
        budget: &Budget,
    ) -> Result<Vec<u8>, Error> {
        let mut ranges = Vec::new();
        let mut offset = 0u64;
        while offset < size {
            let length = chunk_bytes.min(size - offset);
            ranges.push(ByteRange {
                key: key.to_owned(),
                offset,
                length,
            });
            offset += length;
        }
        let capacity = usize::try_from(size).map_err(|_| {
            Error::new(
                ErrorCode::BudgetExceeded,
                "pack artifact is too large for this platform",
            )
            .with_limit("max_provider_bytes")
        })?;
        let mut output = Vec::with_capacity(capacity);
        for window in ranges.chunks(self.options.concurrency) {
            for _ in window {
                budget.charge_provider_request()?;
            }
            let batches = window
                .iter()
                .cloned()
                .map(|range| vec![range])
                .collect::<Vec<_>>();
            let replies = self.transport.read_ranges_window(&batches, budget)?;
            if replies.len() != batches.len() {
                return Err(protocol_error(
                    "range backend omitted a read_ranges callback reply",
                ));
            }
            for (batch, reply) in batches.iter().zip(replies) {
                if reply.len() != batch.len() {
                    return Err(protocol_error(
                        "range backend returned the wrong number of range replies",
                    ));
                }
                for (range, bytes) in batch.iter().zip(reply) {
                    if bytes.len() as u64 != range.length {
                        return Err(protocol_error(
                            "range backend returned a short or over-long range",
                        ));
                    }
                    budget.charge_provider_bytes(bytes.len() as u64)?;
                    output.extend_from_slice(&bytes);
                }
            }
        }
        if output.len() as u64 != size {
            return Err(protocol_error(
                "range backend artifact length does not match the manifest",
            ));
        }
        Ok(output)
    }

    fn local(&self) -> Result<Arc<LocalOdb>, Error> {
        read_lock(&self.local).clone().ok_or_else(|| {
            Error::new(
                ErrorCode::InvalidArgument,
                "PackFetch store has not completed hydration",
            )
        })
    }
}

impl<T: RangeTransport> ObjectDb for PackFetchOdb<T> {
    fn hash_kind(&self) -> HashKind {
        self.hash
    }

    fn try_header(&self, oid: &Oid, budget: &Budget) -> Result<Option<ObjectHeader>, Error> {
        self.local()?.try_header(oid, budget)
    }

    fn try_find(
        &self,
        oid: &Oid,
        out: &mut Vec<u8>,
        budget: &Budget,
    ) -> Result<Option<ObjectKind>, Error> {
        self.local()?.try_find(oid, out, budget)
    }

    fn try_find_many(&self, oids: &[Oid], budget: &Budget) -> Result<Vec<ObjectReadResult>, Error> {
        self.local()?.try_find_many(oids, budget)
    }

    fn try_find_many_bounded(
        &self,
        oids: &[Oid],
        budget: &Budget,
        read_budget: ReadManyBudget,
    ) -> Result<Vec<ObjectReadResult>, Error> {
        self.local()?
            .try_find_many_bounded(oids, budget, read_budget)
    }

    fn cache_stats(&self) -> CacheStats {
        read_lock(&self.local)
            .as_ref()
            .map_or_else(CacheStats::default, |local| local.cache_stats())
    }

    fn refresh(&self, budget: &Budget) -> Result<(), Error> {
        budget.check()?;
        Err(Error::new(
            ErrorCode::UnsupportedOperation,
            "PackFetch refresh must run as a runtime job",
        ))
    }
}

fn verify_pair_paths(
    pack_path: &Path,
    index_path: &Path,
    descriptor: &PackDescriptor,
    hash: HashKind,
    budget: &Budget,
) -> Result<u64, Error> {
    let pack = read_exact_file(
        pack_path,
        descriptor.pack_size,
        ErrorCode::PackChecksumMismatch,
    )?;
    let index = read_exact_file(
        index_path,
        descriptor.index_size,
        ErrorCode::IndexChecksumMismatch,
    )?;
    let bytes = pack.len() as u64 + index.len() as u64;
    budget.check()?;
    verify_pair_bytes(&pack, &index, descriptor, hash)?;
    Ok(bytes)
}

fn verify_pair_sizes(
    pack_path: &Path,
    index_path: &Path,
    descriptor: &PackDescriptor,
) -> Result<(), Error> {
    let pack_size = pack_path
        .metadata()
        .map_err(|_| checksum_error(ErrorCode::PackChecksumMismatch, "could not inspect"))?
        .len();
    if pack_size != descriptor.pack_size {
        return Err(checksum_error(
            ErrorCode::PackChecksumMismatch,
            "size does not match manifest",
        ));
    }
    let index_size = index_path
        .metadata()
        .map_err(|_| checksum_error(ErrorCode::IndexChecksumMismatch, "could not inspect"))?
        .len();
    if index_size != descriptor.index_size {
        return Err(checksum_error(
            ErrorCode::IndexChecksumMismatch,
            "size does not match manifest",
        ));
    }
    Ok(())
}

fn first_index_oid(index_path: &Path, hash: HashKind) -> Result<Oid, Error> {
    const FANOUT_BYTES: usize = 256 * 4;
    const V2_HEADER_BYTES: usize = 8;
    const V1_ENTRY_OFFSET_BYTES: usize = 4;

    let mut file = File::open(index_path).map_err(|_| {
        Error::new(
            ErrorCode::MalformedObject,
            "could not open hydrated index for its open-time probe",
        )
    })?;
    let mut prefix = vec![0u8; V2_HEADER_BYTES + FANOUT_BYTES + hash.digest_len()];
    file.read_exact(&mut prefix).map_err(|_| {
        Error::new(
            ErrorCode::MalformedObject,
            "hydrated index is too short for its open-time probe",
        )
    })?;

    let (fanout_start, oid_start) = if prefix.starts_with(b"\xfftOc") {
        if prefix[4..8] != [0, 0, 0, 2] {
            return Err(Error::new(
                ErrorCode::MalformedObject,
                "hydrated index version is unsupported",
            ));
        }
        (V2_HEADER_BYTES, V2_HEADER_BYTES + FANOUT_BYTES)
    } else {
        (0, FANOUT_BYTES + V1_ENTRY_OFFSET_BYTES)
    };
    let count_offset = fanout_start + FANOUT_BYTES - 4;
    let count = u32::from_be_bytes(
        prefix[count_offset..count_offset + 4]
            .try_into()
            .expect("fanout count has four bytes"),
    );
    if count == 0 {
        return Err(Error::new(
            ErrorCode::MalformedObject,
            "hydrated index contains no objects",
        ));
    }
    let oid_end = oid_start + hash.digest_len();
    Oid::new(hash, &prefix[oid_start..oid_end]).map_err(|_| {
        Error::new(
            ErrorCode::MalformedObject,
            "hydrated index contains an invalid first object ID",
        )
    })
}

fn remove_destination_pair(pack_dir: &Path, id: &str) {
    let stem = format!("pack-{}", id.to_ascii_lowercase());
    for extension in ["pack", "idx"] {
        let _ = std::fs::remove_file(pack_dir.join(format!("{stem}.{extension}")));
    }
}

fn projected_destination_bytes(pack_dir: &Path, manifest: &PackManifest) -> Result<u64, Error> {
    let mut total = 0u64;
    let entries = std::fs::read_dir(pack_dir).map_err(|_| {
        Error::new(
            ErrorCode::BackendError,
            "could not inspect PackFetch memory destination",
        )
    })?;
    for entry in entries {
        let entry = entry.map_err(|_| {
            Error::new(
                ErrorCode::BackendError,
                "could not inspect PackFetch memory destination",
            )
        })?;
        let path = entry.path();
        if matches!(
            path.extension().and_then(|extension| extension.to_str()),
            Some("pack" | "idx")
        ) {
            total = total
                .checked_add(
                    entry
                        .metadata()
                        .map_err(|_| {
                            Error::new(
                                ErrorCode::BackendError,
                                "could not inspect PackFetch memory destination",
                            )
                        })?
                        .len(),
                )
                .ok_or_else(|| {
                    Error::new(ErrorCode::BudgetExceeded, "max_bytes exceeded")
                        .with_limit("max_bytes")
                })?;
        }
    }

    for descriptor in &manifest.packs {
        let id = Oid::parse_hex(&descriptor.id)
            .map_err(|_| protocol_error("validated pack ID could not be parsed"))?;
        let stem = format!("pack-{}", id.to_hex());
        for (path, expected) in [
            (pack_dir.join(format!("{stem}.pack")), descriptor.pack_size),
            (pack_dir.join(format!("{stem}.idx")), descriptor.index_size),
        ] {
            let existing = path.metadata().map(|metadata| metadata.len()).unwrap_or(0);
            total = total
                .checked_sub(existing)
                .and_then(|value| value.checked_add(expected))
                .ok_or_else(|| {
                    Error::new(ErrorCode::BudgetExceeded, "max_bytes exceeded")
                        .with_limit("max_bytes")
                })?;
        }
    }
    Ok(total)
}

fn read_exact_file(path: &Path, expected: u64, code: ErrorCode) -> Result<Vec<u8>, Error> {
    let mut file = File::open(path).map_err(|_| checksum_error(code, "could not read"))?;
    let length = file
        .metadata()
        .map_err(|_| checksum_error(code, "could not inspect"))?
        .len();
    if length != expected {
        return Err(checksum_error(code, "size does not match manifest"));
    }
    let capacity = usize::try_from(length).map_err(|_| checksum_error(code, "is too large"))?;
    let mut bytes = Vec::with_capacity(capacity);
    file.read_to_end(&mut bytes)
        .map_err(|_| checksum_error(code, "could not read"))?;
    Ok(bytes)
}

fn verify_pair_bytes(
    pack: &[u8],
    index: &[u8],
    descriptor: &PackDescriptor,
    hash: HashKind,
) -> Result<(), Error> {
    let id = Oid::parse_hex(&descriptor.id)
        .map_err(|_| protocol_error("validated pack ID could not be parsed"))?;
    let digest_len = hash.digest_len();
    if pack.len() < digest_len {
        return Err(checksum_error(
            ErrorCode::PackChecksumMismatch,
            "is shorter than its checksum",
        ));
    }
    let pack_trailer = &pack[pack.len() - digest_len..];
    let actual_pack = hash_bytes(
        hash,
        &pack[..pack.len() - digest_len],
        ErrorCode::PackChecksumMismatch,
    )?;
    if actual_pack.as_bytes() != pack_trailer || pack_trailer != id.as_bytes() {
        return Err(checksum_error(
            ErrorCode::PackChecksumMismatch,
            "checksum does not match its trailer or manifest ID",
        ));
    }

    if index.len() < digest_len * 2 {
        return Err(checksum_error(
            ErrorCode::IndexChecksumMismatch,
            "is shorter than its checksums",
        ));
    }
    let pack_checksum_start = index.len() - digest_len * 2;
    let index_checksum_start = index.len() - digest_len;
    if &index[pack_checksum_start..index_checksum_start] != id.as_bytes() {
        return Err(checksum_error(
            ErrorCode::PackChecksumMismatch,
            "index refers to a different pack checksum",
        ));
    }
    let actual_index = hash_bytes(
        hash,
        &index[..index_checksum_start],
        ErrorCode::IndexChecksumMismatch,
    )?;
    if actual_index.as_bytes() != &index[index_checksum_start..] {
        return Err(checksum_error(
            ErrorCode::IndexChecksumMismatch,
            "checksum does not match",
        ));
    }
    Ok(())
}

fn hash_bytes(hash: HashKind, bytes: &[u8], code: ErrorCode) -> Result<Oid, Error> {
    let mut hasher = ContentHasher::new(hash);
    hasher.update(bytes);
    hasher
        .finalize()
        .map_err(|_| checksum_error(code, "collision detected while hashing"))
}

fn write_pair_atomically(
    pack_path: &Path,
    index_path: &Path,
    pack: &[u8],
    index: &[u8],
) -> Result<(), Error> {
    let pack_temp = TempFile::write(pack_path, pack)?;
    let index_temp = TempFile::write(index_path, index)?;
    pack_temp.publish(pack_path)?;
    index_temp.publish(index_path)?;
    Ok(())
}

struct TempFile {
    path: Option<PathBuf>,
}

impl TempFile {
    fn write(final_path: &Path, bytes: &[u8]) -> Result<Self, Error> {
        let id = NEXT_TEMP_ID.fetch_add(1, Ordering::Relaxed);
        let file_name = final_path
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| Error::new(ErrorCode::InvalidArgument, "invalid pack file name"))?;
        let path =
            final_path.with_file_name(format!(".{file_name}.tmp-{}-{id}", std::process::id()));
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&path)
            .map_err(|_| {
                Error::new(
                    ErrorCode::BackendError,
                    "could not create PackFetch temporary file",
                )
            })?;
        if let Err(error) = file.write_all(bytes).and_then(|_| file.sync_all()) {
            let _ = std::fs::remove_file(&path);
            return Err(Error::new(
                ErrorCode::BackendError,
                format!("could not write PackFetch temporary file: {error}"),
            ));
        }
        Ok(Self { path: Some(path) })
    }

    fn publish(mut self, final_path: &Path) -> Result<(), Error> {
        let path = self.path.take().expect("temporary path is present");
        std::fs::rename(&path, final_path).map_err(|error| {
            let _ = std::fs::remove_file(&path);
            Error::new(
                ErrorCode::BackendError,
                format!("could not publish hydrated pack file: {error}"),
            )
        })
    }
}

impl Drop for TempFile {
    fn drop(&mut self) {
        if let Some(path) = self.path.take() {
            let _ = std::fs::remove_file(path);
        }
    }
}

fn checksum_error(code: ErrorCode, detail: &str) -> Error {
    let artifact = if code == ErrorCode::IndexChecksumMismatch {
        "index"
    } else {
        "pack"
    };
    Error::new(code, format!("hydrated {artifact} {detail}"))
}

fn protocol_error(message: &'static str) -> Error {
    Error::new(ErrorCode::ProviderProtocolError, message)
}

fn hydration_budget_error(message: &'static str) -> Error {
    Error::new(ErrorCode::BudgetExceeded, message).with_limit("max_hydration_bytes")
}

fn remap_hydration_budget(error: Error, context: &'static str) -> Error {
    if error.code == ErrorCode::BudgetExceeded && error.limit == Some("max_provider_bytes") {
        hydration_budget_error(match context {
            "pack manifest reply" => "pack manifest reply exceeds max_hydration_bytes",
            _ => "pack hydration exceeds max_hydration_bytes",
        })
    } else {
        error
    }
}

fn backend_error() -> Error {
    Error::retryable(ErrorCode::BackendError, "range backend callback failed")
}

fn provider_down() -> Error {
    Error::retryable(ErrorCode::ProviderDown, "range backend provider is down")
}

fn provider_timeout() -> Error {
    Error::retryable(
        ErrorCode::ProviderTimeout,
        "range backend request timed out",
    )
}

fn elapsed_ms(started: Instant) -> u64 {
    started.elapsed().as_millis() as u64
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn read_lock<T>(lock: &RwLock<T>) -> std::sync::RwLockReadGuard<'_, T> {
    lock.read().unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn write_lock<T>(lock: &RwLock<T>) -> std::sync::RwLockWriteGuard<'_, T> {
    lock.write()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;

    #[derive(Clone)]
    struct MemoryTransport {
        manifest: PackManifest,
        artifacts: Arc<BTreeMap<String, Vec<u8>>>,
        read_calls: Arc<AtomicUsize>,
        short_reply: bool,
    }

    impl RangeTransport for MemoryTransport {
        fn manifest(&self, _budget: &Budget) -> Result<PackManifest, Error> {
            Ok(self.manifest.clone())
        }

        fn read_ranges(
            &self,
            ranges: &[ByteRange],
            _budget: &Budget,
        ) -> Result<Vec<Vec<u8>>, Error> {
            self.read_calls.fetch_add(1, Ordering::Relaxed);
            ranges
                .iter()
                .map(|range| {
                    let source = self.artifacts.get(&range.key).ok_or_else(backend_error)?;
                    let start = usize::try_from(range.offset)
                        .map_err(|_| protocol_error("test range offset is too large"))?;
                    let length = usize::try_from(range.length)
                        .map_err(|_| protocol_error("test range length is too large"))?;
                    let end = start
                        .checked_add(length)
                        .ok_or_else(|| protocol_error("test range overflows"))?;
                    let mut bytes = source.get(start..end).ok_or_else(backend_error)?.to_vec();
                    if self.short_reply && !bytes.is_empty() {
                        bytes.pop();
                    }
                    Ok(bytes)
                })
                .collect()
        }

        fn fail_all(&self, _error: Error) {}
    }

    struct TestDir(PathBuf);

    impl TestDir {
        fn new(label: &str) -> Self {
            let id = NEXT_TEMP_ID.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "gitility-packfetch-{label}-{}-{id}",
                std::process::id()
            ));
            std::fs::create_dir_all(&path).expect("test directory is created");
            Self(path)
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn descriptor(id: &str) -> PackDescriptor {
        PackDescriptor {
            id: id.to_owned(),
            pack_key: format!("packs/pack-{id}.pack"),
            index_key: format!("packs/pack-{id}.idx"),
            pack_size: 100,
            index_size: 50,
            etag: None,
        }
    }

    fn manifest() -> PackManifest {
        PackManifest {
            version: 1,
            generation: "generation-1".to_owned(),
            hash: HashKind::Sha1,
            packs: vec![descriptor(&"1".repeat(40))],
            loose: Vec::new(),
        }
    }

    fn fixture_pair() -> (PackManifest, BTreeMap<String, Vec<u8>>) {
        let pack_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/generated/sha1-basic-mixed.git/objects/pack");
        let pack_path = std::fs::read_dir(&pack_dir)
            .expect("fixture pack directory exists")
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .find(|path| path.extension().and_then(|value| value.to_str()) == Some("pack"))
            .expect("fixture has a pack");
        let index_path = pack_path.with_extension("idx");
        let id = pack_path
            .file_stem()
            .and_then(|value| value.to_str())
            .and_then(|value| value.strip_prefix("pack-"))
            .expect("fixture pack is content-addressed")
            .to_owned();
        let pack = std::fs::read(&pack_path).expect("fixture pack is readable");
        let index = std::fs::read(&index_path).expect("fixture index is readable");
        let descriptor = PackDescriptor {
            id: id.clone(),
            pack_key: format!("packs/pack-{id}.pack"),
            index_key: format!("packs/pack-{id}.idx"),
            pack_size: pack.len() as u64,
            index_size: index.len() as u64,
            etag: None,
        };
        let artifacts = BTreeMap::from([
            (descriptor.pack_key.clone(), pack),
            (descriptor.index_key.clone(), index),
        ]);
        (
            PackManifest {
                version: 1,
                generation: "fixture-generation".to_owned(),
                hash: HashKind::Sha1,
                packs: vec![descriptor],
                loose: Vec::new(),
            },
            artifacts,
        )
    }

    fn transport(
        manifest: PackManifest,
        artifacts: BTreeMap<String, Vec<u8>>,
    ) -> (MemoryTransport, Arc<AtomicUsize>) {
        let read_calls = Arc::new(AtomicUsize::new(0));
        (
            MemoryTransport {
                manifest,
                artifacts: Arc::new(artifacts),
                read_calls: read_calls.clone(),
                short_reply: false,
            },
            read_calls,
        )
    }

    fn options(destination: &Path) -> PackFetchOptions {
        PackFetchOptions {
            destination: destination.to_path_buf(),
            chunk_bytes: 257,
            concurrency: 3,
            max_hydration_bytes: 4 * 1024 * 1024 * 1024,
            max_bytes: None,
        }
    }

    #[test]
    fn manifest_validation_rejects_each_trust_boundary_violation() {
        assert!(manifest().validate(HashKind::Sha1).is_ok());

        let mut value = manifest();
        value.version = 2;
        assert_eq!(
            value.validate(HashKind::Sha1).unwrap_err().code,
            ErrorCode::ProviderProtocolError
        );

        let mut value = manifest();
        value.packs.push(value.packs[0].clone());
        assert!(value
            .validate(HashKind::Sha1)
            .unwrap_err()
            .message
            .contains("duplicate"));

        let mut value = manifest();
        value.packs[0].id = "00".to_owned();
        assert_eq!(
            value.validate(HashKind::Sha1).unwrap_err().code,
            ErrorCode::ProviderProtocolError
        );

        let mut value = manifest();
        value.packs[0].pack_size = 0;
        assert_eq!(
            value.validate(HashKind::Sha1).unwrap_err().code,
            ErrorCode::ProviderProtocolError
        );

        let mut value = manifest();
        value.packs[0].pack_key.clear();
        assert_eq!(
            value.validate(HashKind::Sha1).unwrap_err().code,
            ErrorCode::ProviderProtocolError
        );
    }

    #[test]
    fn described_byte_plan_is_checked_for_overflow() {
        let mut value = manifest();
        value.packs[0].pack_size = u64::MAX;
        assert_eq!(
            value.described_bytes().unwrap_err().code,
            ErrorCode::ProviderProtocolError
        );
    }

    #[test]
    fn fetch_artifact_windows_exact_bytes_and_rejects_short_replies() {
        let directory = TestDir::new("fetch-artifact");
        let (manifest, artifacts) = fixture_pair();
        let expected = artifacts[&manifest.packs[0].pack_key].clone();
        let (exact_transport, _) = transport(manifest.clone(), artifacts.clone());
        let store = PackFetchOdb::new(HashKind::Sha1, options(&directory.0), exact_transport)
            .expect("store is valid");
        let actual = store
            .fetch_artifact(
                &manifest.packs[0].pack_key,
                expected.len() as u64,
                113,
                &Budget::unlimited(),
            )
            .expect("exact transport succeeds");
        assert_eq!(actual, expected);

        let (mut transport, _) = transport(manifest.clone(), artifacts);
        transport.short_reply = true;
        let store = PackFetchOdb::new(HashKind::Sha1, options(&directory.0), transport)
            .expect("store is valid");
        assert_eq!(
            store
                .fetch_artifact(
                    &manifest.packs[0].pack_key,
                    manifest.packs[0].pack_size,
                    113,
                    &Budget::unlimited(),
                )
                .unwrap_err()
                .code,
            ErrorCode::ProviderProtocolError
        );
    }

    #[test]
    fn verify_pair_bytes_checks_pack_index_and_pairing_boundaries() {
        let (manifest, artifacts) = fixture_pair();
        let descriptor = &manifest.packs[0];
        let pack = &artifacts[&descriptor.pack_key];
        let index = &artifacts[&descriptor.index_key];
        verify_pair_bytes(pack, index, descriptor, HashKind::Sha1).expect("fixture pair verifies");

        let mut bad_pack = pack.clone();
        bad_pack[0] ^= 1;
        assert_eq!(
            verify_pair_bytes(&bad_pack, index, descriptor, HashKind::Sha1)
                .unwrap_err()
                .code,
            ErrorCode::PackChecksumMismatch
        );

        let mut bad_index = index.clone();
        bad_index[0] ^= 1;
        assert_eq!(
            verify_pair_bytes(pack, &bad_index, descriptor, HashKind::Sha1)
                .unwrap_err()
                .code,
            ErrorCode::IndexChecksumMismatch
        );

        let mut wrong_pair = descriptor.clone();
        wrong_pair.id = "0".repeat(40);
        assert_eq!(
            verify_pair_bytes(pack, index, &wrong_pair, HashKind::Sha1)
                .unwrap_err()
                .code,
            ErrorCode::PackChecksumMismatch
        );
    }

    #[test]
    fn warm_open_skips_fetch_and_refresh_uses_in_memory_verification_marker() {
        let directory = TestDir::new("warm-skip");
        let (manifest, artifacts) = fixture_pair();
        let (first_transport, _) = transport(manifest.clone(), artifacts.clone());
        let first = PackFetchOdb::new(HashKind::Sha1, options(&directory.0), first_transport)
            .expect("store is valid");
        assert_eq!(
            first
                .hydrate(&Budget::unlimited())
                .expect("cold hydration succeeds")
                .packs_hydrated,
            1
        );
        let refresh = first
            .hydrate(&Budget::unlimited())
            .expect("warm refresh succeeds");
        assert_eq!(refresh.packs_skipped, 1);
        assert_eq!(refresh.bytes_fetched, 0);
        assert_eq!(refresh.bytes_verified, 0);

        assert!(manifest.described_bytes().unwrap() > 1024);
        let mut warm_options = options(&directory.0);
        warm_options.max_hydration_bytes = 1024;
        let (warm_transport, warm_reads) = transport(manifest, artifacts);
        let warm = PackFetchOdb::new(HashKind::Sha1, warm_options, warm_transport)
            .expect("store is valid");
        let warm_budget = Budget::unlimited();
        let stats = warm
            .hydrate(&warm_budget)
            .expect("restart re-verifies but fetches nothing");
        assert_eq!(stats.packs_skipped, 1);
        assert_eq!(stats.bytes_fetched, 0);
        assert!(stats.bytes_verified > 0);
        assert_eq!(warm_reads.load(Ordering::Relaxed), 0);
        assert!(warm_budget.spent().3 > 0);
    }

    #[test]
    fn corrupt_preexisting_pair_is_removed_replaced_and_reopened() {
        let directory = TestDir::new("replace-corrupt");
        let (manifest, artifacts) = fixture_pair();
        let (first_transport, _) = transport(manifest.clone(), artifacts.clone());
        PackFetchOdb::new(HashKind::Sha1, options(&directory.0), first_transport)
            .expect("store is valid")
            .hydrate(&Budget::unlimited())
            .expect("cold hydration succeeds");

        let descriptor = &manifest.packs[0];
        let index_path = directory
            .0
            .join("objects/pack")
            .join(format!("pack-{}.idx", descriptor.id));
        let mut corrupt = std::fs::read(&index_path).expect("hydrated index exists");
        corrupt[0] ^= 1;
        std::fs::write(&index_path, corrupt).expect("index is corrupted in place");

        let (replacement_transport, _) = transport(manifest.clone(), artifacts.clone());
        let replacement =
            PackFetchOdb::new(HashKind::Sha1, options(&directory.0), replacement_transport)
                .expect("store is valid");
        let stats = replacement
            .hydrate(&Budget::unlimited())
            .expect("corrupt pair is replaced");
        assert_eq!(stats.replaced_corrupt, 1);
        assert_eq!(stats.packs_hydrated, 1);
        assert_eq!(
            std::fs::read(index_path).expect("replacement index exists"),
            artifacts[&descriptor.index_key]
        );
    }

    #[test]
    fn hydration_ceiling_rejects_cold_plan_before_any_range_read() {
        let directory = TestDir::new("cold-ceiling");
        let (manifest, artifacts) = fixture_pair();
        let (transport, reads) = transport(manifest, artifacts);
        let mut options = options(&directory.0);
        options.max_hydration_bytes = 1;
        let error = PackFetchOdb::new(HashKind::Sha1, options, transport)
            .expect("store is valid")
            .hydrate(&Budget::unlimited())
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::BudgetExceeded);
        assert_eq!(error.limit, Some("max_hydration_bytes"));
        assert_eq!(reads.load(Ordering::Relaxed), 0);
        assert!(PackFetchOptions::default().max_hydration_bytes > 300 * 1024 * 1024);
    }

    #[test]
    fn checksum_consistent_forged_index_fails_probe_and_cleans_pair() {
        let directory = TestDir::new("forged-probe");
        let (manifest, mut artifacts) = fixture_pair();
        let descriptor = &manifest.packs[0];
        let mut index = artifacts[&descriptor.index_key].clone();
        let count = u32::from_be_bytes(index[8 + 255 * 4..8 + 256 * 4].try_into().unwrap());
        let offset_table = 8 + 256 * 4 + count as usize * 20 + count as usize * 4;
        index[offset_table..offset_table + 4].copy_from_slice(&0x7fff_ffffu32.to_be_bytes());
        let checksum_start = index.len() - HashKind::Sha1.digest_len();
        let checksum = hash_bytes(
            HashKind::Sha1,
            &index[..checksum_start],
            ErrorCode::IndexChecksumMismatch,
        )
        .expect("forged index checksum is computed");
        index[checksum_start..].copy_from_slice(checksum.as_bytes());
        verify_pair_bytes(
            &artifacts[&descriptor.pack_key],
            &index,
            descriptor,
            HashKind::Sha1,
        )
        .expect("acquisition checksums alone accept the forgery");
        artifacts.insert(descriptor.index_key.clone(), index);

        let (transport, _) = transport(manifest.clone(), artifacts);
        let error = PackFetchOdb::new(HashKind::Sha1, options(&directory.0), transport)
            .expect("store is valid")
            .hydrate(&Budget::unlimited())
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::MalformedObject);
        assert!(error.message.contains("failed the open-time probe"));
        let pack_dir = directory.0.join("objects/pack");
        assert!(!pack_dir
            .join(format!("pack-{}.pack", descriptor.id))
            .exists());
        assert!(!pack_dir
            .join(format!("pack-{}.idx", descriptor.id))
            .exists());
    }

    #[test]
    fn pair_publication_replaces_through_temp_files_and_leaves_no_temps() {
        let directory = TestDir::new("temp-rename");
        let pack_path = directory.0.join("pack-deadbeef.pack");
        let index_path = directory.0.join("pack-deadbeef.idx");
        std::fs::write(&pack_path, b"old-pack").unwrap();
        std::fs::write(&index_path, b"old-index").unwrap();

        write_pair_atomically(&pack_path, &index_path, b"new-pack", b"new-index")
            .expect("pair is atomically published");
        assert_eq!(std::fs::read(&pack_path).unwrap(), b"new-pack");
        assert_eq!(std::fs::read(&index_path).unwrap(), b"new-index");
        assert!(std::fs::read_dir(&directory.0).unwrap().all(|entry| {
            !entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .contains(".tmp-")
        }));

        let temp = TempFile::write(&pack_path, b"never-published").unwrap();
        let temp_path = temp.path.clone().expect("temp path exists");
        drop(temp);
        assert!(!temp_path.exists());
        assert_eq!(std::fs::read(pack_path).unwrap(), b"new-pack");
    }
}
