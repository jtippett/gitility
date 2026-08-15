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
    pub max_bytes: Option<u64>,
    pub cleanup_destination: bool,
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
        Ok(())
    }
}

impl Default for PackFetchOptions {
    fn default() -> Self {
        Self {
            destination: PathBuf::new(),
            chunk_bytes: DEFAULT_CHUNK_BYTES,
            concurrency: 8,
            max_bytes: None,
            cleanup_destination: false,
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
        let described_bytes = manifest.described_bytes()?;
        let provider_remaining = budget
            .limits()
            .max_provider_bytes
            .saturating_sub(budget.spent().3);
        if described_bytes > provider_remaining {
            return Err(Error::new(
                ErrorCode::BudgetExceeded,
                "pack manifest exceeds max_provider_bytes before hydration",
            )
            .with_limit("max_provider_bytes"));
        }
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
        for descriptor in &manifest.packs {
            budget.check()?;
            let id = Oid::parse_hex(&descriptor.id)
                .map_err(|_| protocol_error("validated pack ID could not be parsed"))?;
            let stem = format!("pack-{}", id.to_hex());
            let pack_path = pack_dir.join(format!("{stem}.pack"));
            let index_path = pack_dir.join(format!("{stem}.idx"));
            let pack_exists = pack_path.is_file();
            let index_exists = index_path.is_file();

            if pack_exists && index_exists {
                let verify_started = Instant::now();
                match verify_pair_paths(&pack_path, &index_path, descriptor, self.hash, budget) {
                    Ok(bytes) => {
                        stats.bytes_verified = stats.bytes_verified.saturating_add(bytes);
                        stats.verify_ms =
                            stats.verify_ms.saturating_add(elapsed_ms(verify_started));
                        stats.packs_skipped += 1;
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
                    }
                    Err(error) => return Err(error),
                }
            } else if pack_exists || index_exists {
                stats.replaced_corrupt += 1;
            }

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

impl<T: RangeTransport> Drop for PackFetchOdb<T> {
    fn drop(&mut self) {
        if self.options.cleanup_destination {
            if let Err(error) = std::fs::remove_dir_all(&self.options.destination) {
                if error.kind() != std::io::ErrorKind::NotFound {
                    eprintln!(
                        "gitility: could not clean memory PackFetch destination {}: {error}",
                        self.options.destination.display()
                    );
                }
            }
        }
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
}
