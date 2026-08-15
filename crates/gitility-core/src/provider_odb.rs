//! BEAM-free callback object database.
//!
//! [`ProviderOdb`] owns request rendezvous, validation, verification, and
//! bounded per-store caches. The NIF crate supplies only a transport that
//! sends [`ProviderRequest`] values to an Elixir provider process.

use crate::budget::Budget;
use crate::error::{Error, ErrorCode};
use crate::lru::LruCache;
use crate::object::{HashKind, ObjectHeader, ObjectKind, Oid};
use crate::odb::{
    enforce_read_many_budget, HeaderProvenance, HeaderRead, ObjectDb, ObjectReadResult,
    ReadManyBudget,
};
use crate::verify::verify;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

const WAIT_SLICE: Duration = Duration::from_millis(50);
const DEFAULT_NEGATIVE_ENTRIES: usize = 4_096;

/// Direct provider header metadata above one tebibyte is rejected as an
/// implausible protocol value. This does not use a job's payload ceiling:
/// metadata for a legitimate object larger than that job may still be useful.
pub const PROVIDER_HEADER_SIZE_CEILING: u64 = 1 << 40;

/// Callback operation sent to the provider.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProviderKind {
    Header,
    Object,
    Prefetch,
}

/// One decoded result supplied by the NIF transport.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProviderReplyValue {
    NotFound,
    Header(ObjectHeader),
    Object {
        kind: ObjectKind,
        data: Arc<Vec<u8>>,
    },
}

/// A complete callback reply. Backend errors deliberately carry no backend
/// term or message across the core boundary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProviderPayload {
    Results(Vec<(Oid, ProviderReplyValue)>),
    BackendError,
}

type ReplySender = mpsc::SyncSender<Result<ProviderPayload, Error>>;

/// Receiving half of one provider rendezvous.
///
/// It is cloneable so the transport can own the request DTO while the store
/// retains a handle on which to wait.
#[derive(Clone)]
pub struct ReplySlot {
    receiver: Arc<Mutex<mpsc::Receiver<Result<ProviderPayload, Error>>>>,
}

impl std::fmt::Debug for ReplySlot {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("ReplySlot").finish_non_exhaustive()
    }
}

impl ReplySlot {
    fn pair() -> (Self, ReplySender) {
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
    ) -> Result<Result<ProviderPayload, Error>, mpsc::RecvTimeoutError> {
        lock(&self.receiver).recv_timeout(timeout)
    }
}

/// Request handed to a transport implementation.
#[derive(Debug, Clone)]
pub struct ProviderRequest {
    pub id: u64,
    pub kind: ProviderKind,
    pub oids: Vec<Oid>,
    pub reply: ReplySlot,
    pub deadline: Instant,
    /// Cheap boundary checks use these ceilings before allocating owned
    /// payload buffers; core validation repeats them after decoding.
    pub max_object_bytes: u64,
    pub max_reply_bytes: u64,
    /// Optional public `read_many` result ceiling, independent of provider
    /// bandwidth accounting.
    pub max_result_bytes: Option<u64>,
}

/// Sends a provider request without waiting for its reply.
pub trait ProviderTransport: Send + Sync + 'static {
    fn request(&self, request: ProviderRequest) -> Result<(), Error>;
}

/// Take-once table shared with request resources at the transport boundary.
#[derive(Default)]
pub struct PendingTable {
    senders: Mutex<BTreeMap<u64, ReplySender>>,
}

impl std::fmt::Debug for PendingTable {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("PendingTable")
            .field("len", &lock(&self.senders).len())
            .finish()
    }
}

impl PendingTable {
    fn insert(&self, id: u64, sender: ReplySender) {
        lock(&self.senders).insert(id, sender);
    }

    /// Delivers at most one reply. Late and duplicate replies are harmless
    /// no-ops and return `false`.
    pub fn reply(&self, id: u64, payload: ProviderPayload) -> bool {
        let sender = lock(&self.senders).remove(&id);
        sender.is_some_and(|sender| sender.send(Ok(payload)).is_ok())
    }

    /// Fails one request during boundary decoding. This is also take-once.
    pub fn reply_error(&self, id: u64, error: Error) -> bool {
        let sender = lock(&self.senders).remove(&id);
        sender.is_some_and(|sender| sender.send(Err(error)).is_ok())
    }

    /// Removes a timed-out or cancelled request, making later replies no-ops.
    pub fn cancel(&self, id: u64) -> bool {
        lock(&self.senders).remove(&id).is_some()
    }

    /// Wakes every current waiter with the same sanitized terminal failure.
    pub fn fail_all(&self, error: Error) {
        let senders = std::mem::take(&mut *lock(&self.senders));
        for (_, sender) in senders {
            let _ = sender.send(Err(error.clone()));
        }
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        lock(&self.senders).len()
    }
}

/// Optional bounded provider caches. Zero disables the corresponding cache.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ProviderCacheOptions {
    pub object_bytes: u64,
    pub header_entries: usize,
    pub negative_ttl: Duration,
}

/// Provider store construction options.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProviderOptions {
    pub request_timeout: Duration,
    pub cache: ProviderCacheOptions,
}

impl Default for ProviderOptions {
    fn default() -> Self {
        Self {
            request_timeout: Duration::from_secs(15),
            cache: ProviderCacheOptions::default(),
        }
    }
}

/// Object store whose bytes arrive through a callback transport.
pub struct ProviderOdb<T: ProviderTransport> {
    hash: HashKind,
    transport: T,
    options: ProviderOptions,
    pending: Arc<PendingTable>,
    next_id: AtomicU64,
    alive: AtomicBool,
    caches: Mutex<ProviderCaches>,
}

impl<T: ProviderTransport> std::fmt::Debug for ProviderOdb<T> {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ProviderOdb")
            .field("hash", &self.hash)
            .field("options", &self.options)
            .field("alive", &self.alive.load(Ordering::Acquire))
            .finish_non_exhaustive()
    }
}

impl<T: ProviderTransport> ProviderOdb<T> {
    pub fn new(hash: HashKind, options: ProviderOptions, transport: T) -> Self {
        Self::new_with_pending(hash, options, transport, Arc::new(PendingTable::default()))
    }

    /// Constructs a store around a table that a transport has already weakly
    /// referenced while setting up a boundary resource.
    pub fn new_with_pending(
        hash: HashKind,
        options: ProviderOptions,
        transport: T,
        pending: Arc<PendingTable>,
    ) -> Self {
        Self {
            hash,
            transport,
            options,
            pending,
            next_id: AtomicU64::new(1),
            alive: AtomicBool::new(true),
            caches: Mutex::new(ProviderCaches::new(options.cache)),
        }
    }

    pub fn pending_table(&self) -> &Arc<PendingTable> {
        &self.pending
    }

    /// Permanently binds this handle to provider death and wakes all waiters.
    pub fn fail_all(&self, error: Error) {
        self.alive.store(false, Ordering::Release);
        self.pending.fail_all(error);
    }

    pub fn provider_down(&self) {
        self.fail_all(provider_down());
    }

    fn ensure_oid(&self, oid: &Oid) -> Result<(), Error> {
        if oid.kind() == self.hash {
            Ok(())
        } else {
            Err(Error::new(
                ErrorCode::InvalidOid,
                "object ID hash does not match the provider store",
            ))
        }
    }

    fn ensure_alive(&self) -> Result<(), Error> {
        if self.alive.load(Ordering::Acquire) {
            Ok(())
        } else {
            Err(provider_down())
        }
    }

    fn send_and_wait(
        &self,
        kind: ProviderKind,
        oids: Vec<Oid>,
        budget: &Budget,
        read_budget: ReadManyBudget,
    ) -> Result<ProviderPayload, Error> {
        budget.charge_provider_request()?;

        let now = Instant::now();
        let request_deadline = now.checked_add(self.options.request_timeout).unwrap_or(now);
        let deadline = budget
            .deadline()
            .map_or(request_deadline, |budget_deadline| {
                request_deadline.min(budget_deadline)
            });
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (reply, sender) = ReplySlot::pair();
        self.pending.insert(id, sender);
        // Insert first, then inspect liveness. If provider death raced the
        // insertion, either fail_all drained this sender or the false flag
        // makes us remove it and fail immediately.
        if let Err(error) = self.ensure_alive() {
            self.pending.cancel(id);
            return Err(error);
        }
        let provider_bytes_remaining = budget
            .limits()
            .max_provider_bytes
            .saturating_sub(budget.spent().3);
        let request = ProviderRequest {
            id,
            kind,
            oids,
            reply: reply.clone(),
            deadline,
            max_object_bytes: budget.limits().max_object_bytes,
            max_reply_bytes: provider_bytes_remaining,
            max_result_bytes: read_budget.max_total_bytes,
        };
        if let Err(error) = self.transport.request(request) {
            self.pending.cancel(id);
            return Err(error);
        }

        loop {
            if let Err(error) = budget.check() {
                self.pending.cancel(id);
                return Err(error);
            }
            let now = Instant::now();
            if now >= deadline {
                self.pending.cancel(id);
                // A job deadline wins over the narrower provider mapping.
                if budget.deadline().is_some_and(|value| now >= value) {
                    return budget.check().and(Err(Error::new(
                        ErrorCode::Timeout,
                        "operation budget expired",
                    )));
                }
                return Err(provider_timeout());
            }
            let slice = WAIT_SLICE.min(deadline.saturating_duration_since(now));
            match reply.recv_timeout(slice) {
                Ok(result) => return result,
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    self.pending.cancel(id);
                    return Err(provider_down());
                }
            }
        }
    }

    fn request_results(
        &self,
        kind: ProviderKind,
        expected: &[Oid],
        budget: &Budget,
        read_budget: ReadManyBudget,
    ) -> Result<HashMap<Oid, ProviderReplyValue>, Error> {
        let payload = self.send_and_wait(kind, expected.to_vec(), budget, read_budget)?;
        let ProviderPayload::Results(results) = payload else {
            return Err(Error::retryable(
                ErrorCode::BackendError,
                "provider callback failed",
            ));
        };

        let expected_set: HashSet<Oid> = expected.iter().copied().collect();
        let mut decoded = HashMap::with_capacity(results.len());
        let mut reply_bytes = 0u64;
        for (oid, value) in results {
            if !expected_set.contains(&oid) || decoded.contains_key(&oid) {
                return Err(protocol_error(
                    "provider reply contains an unexpected or duplicate object ID",
                ));
            }
            match (&kind, &value) {
                (ProviderKind::Header, ProviderReplyValue::Header(_))
                | (ProviderKind::Header, ProviderReplyValue::Object { .. })
                | (ProviderKind::Header, ProviderReplyValue::NotFound)
                | (ProviderKind::Object, ProviderReplyValue::Object { .. })
                | (ProviderKind::Object, ProviderReplyValue::NotFound) => {}
                _ => return Err(protocol_error("provider reply result has the wrong shape")),
            }
            if let ProviderReplyValue::Object { data, .. } = &value {
                let bytes = data.len() as u64;
                if bytes > budget.limits().max_object_bytes {
                    return Err(Error::new(
                        ErrorCode::ObjectTooLarge,
                        format!(
                            "provider object of {bytes} bytes exceeds max_object_bytes {}",
                            budget.limits().max_object_bytes
                        ),
                    )
                    .with_limit("max_object_bytes"));
                }
                reply_bytes = reply_bytes.saturating_add(bytes);
                if reply_bytes > budget.limits().max_provider_bytes {
                    return Err(Error::new(
                        ErrorCode::BudgetExceeded,
                        "max_provider_bytes exceeded",
                    )
                    .with_limit("max_provider_bytes"));
                }
                enforce_read_many_budget(reply_bytes, read_budget)?;
            } else if let ProviderReplyValue::Header(header) = &value {
                if header.size > PROVIDER_HEADER_SIZE_CEILING {
                    return Err(protocol_error(
                        "provider header size exceeds the 2^40 sanity ceiling",
                    ));
                }
            }
            decoded.insert(oid, value);
        }
        if decoded.len() != expected_set.len() {
            return Err(protocol_error(
                "provider reply omitted a requested object ID",
            ));
        }

        // Charge before verification or cache insertion: even a malformed or
        // hash-mismatched reply consumed provider bandwidth.
        budget.charge_provider_bytes(reply_bytes)?;
        for (oid, value) in &decoded {
            if let ProviderReplyValue::Object { kind, data } = value {
                verify(oid, *kind, data)?;
            }
        }
        Ok(decoded)
    }

    fn clear_negative_cache(&self) {
        lock(&self.caches).negative.clear();
    }

    fn try_header_read(&self, oid: &Oid, budget: &Budget) -> Result<Option<HeaderRead>, Error> {
        self.ensure_oid(oid)?;
        self.ensure_alive()?;
        {
            let mut caches = lock(&self.caches);
            if let Some(header) = caches.headers.get_cloned(oid) {
                budget.charge_header()?;
                return Ok(Some(header));
            }
            if let Some((kind, data)) = caches.objects.get_cloned(oid) {
                budget.charge_header()?;
                return Ok(Some(HeaderRead {
                    header: ObjectHeader {
                        kind,
                        size: data.len() as u64,
                    },
                    provenance: HeaderProvenance::Verified,
                }));
            }
            if caches.negative.contains_fresh(oid) {
                budget.check()?;
                return Ok(None);
            }
        }

        let mut results = self.request_results(
            ProviderKind::Header,
            &[*oid],
            budget,
            ReadManyBudget::default(),
        )?;
        match results.remove(oid).expect("validated singleton reply") {
            ProviderReplyValue::NotFound => {
                lock(&self.caches).negative.insert(*oid);
                budget.check()?;
                Ok(None)
            }
            ProviderReplyValue::Header(header) => {
                let read = HeaderRead {
                    header,
                    provenance: HeaderProvenance::UnverifiedProvider,
                };
                lock(&self.caches).headers.insert(*oid, read, 1);
                budget.charge_header()?;
                Ok(Some(read))
            }
            ProviderReplyValue::Object { kind, data } => {
                let read = HeaderRead {
                    header: ObjectHeader {
                        kind,
                        size: data.len() as u64,
                    },
                    provenance: HeaderProvenance::Verified,
                };
                let mut caches = lock(&self.caches);
                caches
                    .objects
                    .insert(*oid, (kind, Arc::clone(&data)), data.len() as u64);
                caches.headers.insert(*oid, read, 1);
                budget.charge_header()?;
                Ok(Some(read))
            }
        }
    }

    fn try_find_many_with_budget(
        &self,
        oids: &[Oid],
        budget: &Budget,
        read_budget: ReadManyBudget,
    ) -> Result<Vec<ObjectReadResult>, Error> {
        self.ensure_alive()?;
        for oid in oids {
            self.ensure_oid(oid)?;
        }

        let mut found = HashMap::<Oid, Option<(ObjectKind, Arc<Vec<u8>>)>>::new();
        let mut misses = Vec::new();
        let mut resident_bytes = 0u64;
        {
            let mut caches = lock(&self.caches);
            for oid in oids {
                if found.contains_key(oid) {
                    continue;
                }
                if let Some(value) = caches.objects.get_cloned(oid) {
                    resident_bytes = resident_bytes.saturating_add(value.1.len() as u64);
                    enforce_read_many_budget(resident_bytes, read_budget)?;
                    found.insert(*oid, Some(value));
                } else if caches.negative.contains_fresh(oid) {
                    found.insert(*oid, None);
                } else {
                    misses.push(*oid);
                }
            }
        }

        if !misses.is_empty() {
            let remaining = ReadManyBudget {
                max_total_bytes: read_budget
                    .max_total_bytes
                    .map(|maximum| maximum.saturating_sub(resident_bytes)),
            };
            let results = self.request_results(ProviderKind::Object, &misses, budget, remaining)?;
            let mut caches = lock(&self.caches);
            for oid in misses {
                match results.get(&oid).expect("validated complete reply") {
                    ProviderReplyValue::NotFound => {
                        caches.negative.insert(oid);
                        found.insert(oid, None);
                    }
                    ProviderReplyValue::Object { kind, data } => {
                        let value = (*kind, Arc::clone(data));
                        caches.objects.insert(oid, value.clone(), data.len() as u64);
                        caches.headers.insert(
                            oid,
                            HeaderRead {
                                header: ObjectHeader {
                                    kind: *kind,
                                    size: data.len() as u64,
                                },
                                provenance: HeaderProvenance::Verified,
                            },
                            1,
                        );
                        found.insert(oid, Some(value));
                    }
                    ProviderReplyValue::Header(_) => unreachable!("reply shape validated"),
                }
            }
        }

        let mut output = Vec::with_capacity(oids.len());
        for oid in oids {
            match found.get(oid).expect("every input was resolved") {
                Some((kind, data)) => {
                    budget.charge_object(data.len() as u64)?;
                    output.push(Some((*kind, Arc::clone(data))));
                }
                None => {
                    budget.check()?;
                    output.push(None);
                }
            }
        }
        Ok(output)
    }
}

impl<T: ProviderTransport> ObjectDb for ProviderOdb<T> {
    fn hash_kind(&self) -> HashKind {
        self.hash
    }

    fn try_header(&self, oid: &Oid, budget: &Budget) -> Result<Option<ObjectHeader>, Error> {
        Ok(self.try_header_read(oid, budget)?.map(|read| read.header))
    }

    fn try_header_with_provenance(
        &self,
        oid: &Oid,
        budget: &Budget,
    ) -> Result<Option<HeaderRead>, Error> {
        self.try_header_read(oid, budget)
    }

    fn try_find(
        &self,
        oid: &Oid,
        out: &mut Vec<u8>,
        budget: &Budget,
    ) -> Result<Option<ObjectKind>, Error> {
        out.clear();
        let mut values =
            self.try_find_many_with_budget(&[*oid], budget, ReadManyBudget::default())?;
        match values.pop().expect("singleton read result") {
            Some((kind, data)) => {
                out.extend_from_slice(&data);
                Ok(Some(kind))
            }
            None => Ok(None),
        }
    }

    fn try_find_many(&self, oids: &[Oid], budget: &Budget) -> Result<Vec<ObjectReadResult>, Error> {
        self.try_find_many_with_budget(oids, budget, ReadManyBudget::default())
    }

    fn try_find_many_bounded(
        &self,
        oids: &[Oid],
        budget: &Budget,
        read_budget: ReadManyBudget,
    ) -> Result<Vec<ObjectReadResult>, Error> {
        self.try_find_many_with_budget(oids, budget, read_budget)
    }

    fn prefetch(&self, oids: &[Oid], budget: &Budget) -> Result<(), Error> {
        if oids.is_empty() {
            return Ok(());
        }
        self.ensure_alive()?;
        for oid in oids {
            self.ensure_oid(oid)?;
        }
        budget.charge_provider_request()?;
        let now = Instant::now();
        let request_deadline = now.checked_add(self.options.request_timeout).unwrap_or(now);
        let deadline = budget
            .deadline()
            .map_or(request_deadline, |value| request_deadline.min(value));
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (reply, _sender) = ReplySlot::pair();
        self.transport.request(ProviderRequest {
            id,
            kind: ProviderKind::Prefetch,
            oids: oids.to_vec(),
            reply,
            deadline,
            max_object_bytes: 0,
            max_reply_bytes: 0,
            max_result_bytes: None,
        })
    }

    fn supports_prefetch(&self) -> bool {
        true
    }

    fn refresh(&self, budget: &Budget) -> Result<(), Error> {
        budget.check()?;
        self.clear_negative_cache();
        Ok(())
    }
}

fn provider_down() -> Error {
    Error::retryable(ErrorCode::ProviderDown, "provider process is down")
}

fn provider_timeout() -> Error {
    Error::retryable(
        ErrorCode::ProviderTimeout,
        "provider request deadline expired",
    )
}

fn protocol_error(message: &'static str) -> Error {
    Error::new(ErrorCode::ProviderProtocolError, message)
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

struct ProviderCaches {
    objects: LruCache<Oid, (ObjectKind, Arc<Vec<u8>>)>,
    headers: LruCache<Oid, HeaderRead>,
    negative: NegativeCache,
}

impl ProviderCaches {
    fn new(options: ProviderCacheOptions) -> Self {
        Self {
            objects: LruCache::new(options.object_bytes),
            headers: LruCache::new(options.header_entries as u64),
            negative: NegativeCache::new(options.negative_ttl, DEFAULT_NEGATIVE_ENTRIES),
        }
    }
}

struct NegativeCache {
    values: LruCache<Oid, Instant>,
    ttl: Duration,
}

impl NegativeCache {
    fn new(ttl: Duration, capacity: usize) -> Self {
        Self {
            values: LruCache::new(capacity as u64),
            ttl,
        }
    }

    fn contains_fresh(&mut self, oid: &Oid) -> bool {
        if self.ttl.is_zero() {
            return false;
        }
        let fresh = self
            .values
            .get(oid)
            .is_some_and(|inserted| inserted.elapsed() < self.ttl);
        if !fresh {
            self.values.remove(oid);
        }
        fresh
    }

    fn insert(&mut self, oid: Oid) {
        if self.ttl.is_zero() {
            return;
        }
        self.values.insert(oid, Instant::now(), 1);
    }

    fn clear(&mut self) {
        self.values.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::budget::BudgetLimits;
    use crate::verify::object_id;
    use std::sync::atomic::{AtomicUsize, Ordering as AtomicOrdering};
    use std::sync::Weak;
    use std::thread;

    type Responder = dyn Fn(&ProviderRequest) -> Option<ProviderPayload> + Send + Sync;

    #[derive(Clone)]
    struct TestTransport {
        pending: Weak<PendingTable>,
        responder: Arc<Responder>,
    }

    impl ProviderTransport for TestTransport {
        fn request(&self, request: ProviderRequest) -> Result<(), Error> {
            if let Some(payload) = (self.responder)(&request) {
                self.pending
                    .upgrade()
                    .expect("test pending table remains alive")
                    .reply(request.id, payload);
            }
            Ok(())
        }
    }

    fn store(
        options: ProviderOptions,
        responder: impl Fn(&ProviderRequest) -> Option<ProviderPayload> + Send + Sync + 'static,
    ) -> ProviderOdb<TestTransport> {
        let pending = Arc::new(PendingTable::default());
        let transport = TestTransport {
            pending: Arc::downgrade(&pending),
            responder: Arc::new(responder),
        };
        ProviderOdb::new_with_pending(HashKind::Sha1, options, transport, pending)
    }

    fn blob() -> (Oid, Vec<u8>) {
        let data = b"verified provider bytes".to_vec();
        let oid = object_id(HashKind::Sha1, ObjectKind::Blob, &data).expect("object ID computes");
        (oid, data)
    }

    fn object_results(request: &ProviderRequest, data: &[u8]) -> ProviderPayload {
        ProviderPayload::Results(
            request
                .oids
                .iter()
                .map(|oid| {
                    (
                        *oid,
                        ProviderReplyValue::Object {
                            kind: ObjectKind::Blob,
                            data: Arc::new(data.to_vec()),
                        },
                    )
                })
                .collect(),
        )
    }

    #[test]
    fn verified_objects_are_cached_and_provider_spend_is_charged() {
        let (oid, data) = blob();
        let calls = Arc::new(AtomicUsize::new(0));
        let observed = Arc::clone(&calls);
        let reply_data = data.clone();
        let provider = store(
            ProviderOptions {
                cache: ProviderCacheOptions {
                    object_bytes: 1_024,
                    ..ProviderCacheOptions::default()
                },
                ..ProviderOptions::default()
            },
            move |request| {
                observed.fetch_add(1, AtomicOrdering::Relaxed);
                Some(object_results(request, &reply_data))
            },
        );
        let budget = Budget::unlimited();

        let mut out = Vec::new();
        assert_eq!(
            provider.try_find(&oid, &mut out, &budget).unwrap(),
            Some(ObjectKind::Blob)
        );
        assert_eq!(out, data);
        provider.try_find(&oid, &mut out, &budget).unwrap();

        assert_eq!(calls.load(AtomicOrdering::Relaxed), 1);
        let (_, object_bytes, requests, provider_bytes) = budget.spent();
        assert_eq!(object_bytes, (data.len() * 2) as u64);
        assert_eq!(requests, 1);
        assert_eq!(provider_bytes, data.len() as u64);
    }

    #[test]
    fn cache_hits_share_the_verified_payload_allocation() {
        let (oid, data) = blob();
        let reply_data = data.clone();
        let provider = store(
            ProviderOptions {
                cache: ProviderCacheOptions {
                    object_bytes: 1_024,
                    ..ProviderCacheOptions::default()
                },
                ..ProviderOptions::default()
            },
            move |request| Some(object_results(request, &reply_data)),
        );

        let first = provider
            .try_find_many(&[oid], &Budget::unlimited())
            .unwrap()
            .pop()
            .unwrap()
            .unwrap()
            .1;
        let second = provider
            .try_find_many(&[oid], &Budget::unlimited())
            .unwrap()
            .pop()
            .unwrap()
            .unwrap()
            .1;
        assert!(Arc::ptr_eq(&first, &second));
    }

    #[test]
    fn direct_headers_are_unverified_and_sanity_capped() {
        let (oid, _data) = blob();
        let provider = store(ProviderOptions::default(), move |_request| {
            Some(ProviderPayload::Results(vec![(
                oid,
                ProviderReplyValue::Header(ObjectHeader {
                    kind: ObjectKind::Blob,
                    size: PROVIDER_HEADER_SIZE_CEILING,
                }),
            )]))
        });
        let read = provider
            .try_header_with_provenance(&oid, &Budget::unlimited())
            .unwrap()
            .unwrap();
        assert_eq!(read.provenance, HeaderProvenance::UnverifiedProvider);
        assert_eq!(read.header.size, PROVIDER_HEADER_SIZE_CEILING);

        let provider = store(ProviderOptions::default(), move |_request| {
            Some(ProviderPayload::Results(vec![(
                oid,
                ProviderReplyValue::Header(ObjectHeader {
                    kind: ObjectKind::Blob,
                    size: PROVIDER_HEADER_SIZE_CEILING + 1,
                }),
            )]))
        });
        assert_eq!(
            provider
                .try_header(&oid, &Budget::unlimited())
                .unwrap_err()
                .code,
            ErrorCode::ProviderProtocolError
        );
    }

    #[test]
    fn read_many_uses_one_real_batch_and_preserves_input_order() {
        let first_data = b"first".to_vec();
        let second_data = b"second".to_vec();
        let first = object_id(HashKind::Sha1, ObjectKind::Blob, &first_data).unwrap();
        let second = object_id(HashKind::Sha1, ObjectKind::Blob, &second_data).unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        let observed = Arc::clone(&calls);
        let provider = store(ProviderOptions::default(), move |request| {
            observed.fetch_add(1, AtomicOrdering::Relaxed);
            assert_eq!(request.oids, vec![second, first]);
            Some(ProviderPayload::Results(vec![
                (
                    first,
                    ProviderReplyValue::Object {
                        kind: ObjectKind::Blob,
                        data: Arc::new(first_data.clone()),
                    },
                ),
                (
                    second,
                    ProviderReplyValue::Object {
                        kind: ObjectKind::Blob,
                        data: Arc::new(second_data.clone()),
                    },
                ),
            ]))
        });

        let results = provider
            .try_find_many(&[second, first], &Budget::unlimited())
            .unwrap();
        assert_eq!(calls.load(AtomicOrdering::Relaxed), 1);
        assert_eq!(results[0].as_ref().unwrap().1.as_slice(), b"second");
        assert_eq!(results[1].as_ref().unwrap().1.as_slice(), b"first");
    }

    #[test]
    fn bounded_read_many_rejects_before_retaining_the_batch() {
        let (oid, data) = blob();
        let calls = Arc::new(AtomicUsize::new(0));
        let observed = Arc::clone(&calls);
        let provider = store(ProviderOptions::default(), move |request| {
            observed.fetch_add(1, AtomicOrdering::Relaxed);
            assert_eq!(request.max_result_bytes, Some(1));
            Some(object_results(request, &data))
        });
        let error = provider
            .try_find_many_bounded(
                &[oid],
                &Budget::unlimited(),
                ReadManyBudget {
                    max_total_bytes: Some(1),
                },
            )
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::ResultTooLarge);
        assert_eq!(error.limit, Some("max_total_bytes"));
        assert_eq!(calls.load(AtomicOrdering::Relaxed), 1);
    }

    #[test]
    fn malformed_batches_are_rejected_as_a_whole() {
        let (oid, _data) = blob();
        let extra = Oid::new(HashKind::Sha1, &[7; 20]).unwrap();
        for results in [
            vec![],
            vec![
                (oid, ProviderReplyValue::NotFound),
                (extra, ProviderReplyValue::NotFound),
            ],
            vec![
                (oid, ProviderReplyValue::NotFound),
                (oid, ProviderReplyValue::NotFound),
            ],
        ] {
            let provider = store(ProviderOptions::default(), move |_request| {
                Some(ProviderPayload::Results(results.clone()))
            });
            let error = provider
                .try_find(&oid, &mut Vec::new(), &Budget::unlimited())
                .unwrap_err();
            assert_eq!(error.code, ErrorCode::ProviderProtocolError);
        }
    }

    #[test]
    fn hash_mismatch_is_not_cached() {
        let (oid, _data) = blob();
        let calls = Arc::new(AtomicUsize::new(0));
        let observed = Arc::clone(&calls);
        let provider = store(
            ProviderOptions {
                cache: ProviderCacheOptions {
                    object_bytes: 1_024,
                    ..ProviderCacheOptions::default()
                },
                ..ProviderOptions::default()
            },
            move |request| {
                observed.fetch_add(1, AtomicOrdering::Relaxed);
                Some(object_results(request, b"tampered"))
            },
        );
        for _ in 0..2 {
            assert_eq!(
                provider
                    .try_find(&oid, &mut Vec::new(), &Budget::unlimited())
                    .unwrap_err()
                    .code,
                ErrorCode::HashMismatch
            );
        }
        assert_eq!(calls.load(AtomicOrdering::Relaxed), 2);
    }

    #[test]
    fn backend_errors_are_sanitized_and_retryable() {
        let (oid, _data) = blob();
        let provider = store(ProviderOptions::default(), |_request| {
            Some(ProviderPayload::BackendError)
        });
        let error = provider
            .try_find(&oid, &mut Vec::new(), &Budget::unlimited())
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::BackendError);
        assert_eq!(error.message, "provider callback failed");
        assert!(error.retryable);
    }

    #[test]
    fn negative_cache_expires_and_refresh_clears_it() {
        let (oid, _data) = blob();
        let calls = Arc::new(AtomicUsize::new(0));
        let observed = Arc::clone(&calls);
        let provider = store(
            ProviderOptions {
                cache: ProviderCacheOptions {
                    negative_ttl: Duration::from_secs(60),
                    ..ProviderCacheOptions::default()
                },
                ..ProviderOptions::default()
            },
            move |request| {
                observed.fetch_add(1, AtomicOrdering::Relaxed);
                Some(ProviderPayload::Results(
                    request
                        .oids
                        .iter()
                        .map(|oid| (*oid, ProviderReplyValue::NotFound))
                        .collect(),
                ))
            },
        );
        assert_eq!(
            provider.try_find(&oid, &mut Vec::new(), &Budget::unlimited()),
            Ok(None)
        );
        assert_eq!(
            provider.try_find(&oid, &mut Vec::new(), &Budget::unlimited()),
            Ok(None)
        );
        assert_eq!(calls.load(AtomicOrdering::Relaxed), 1);
        provider.refresh(&Budget::unlimited()).unwrap();
        assert_eq!(
            provider.try_find(&oid, &mut Vec::new(), &Budget::unlimited()),
            Ok(None)
        );
        assert_eq!(calls.load(AtomicOrdering::Relaxed), 2);
    }

    #[test]
    fn provider_request_and_byte_budgets_name_the_limit() {
        let (oid, data) = blob();
        let reply_data = data.clone();
        let provider = store(ProviderOptions::default(), move |request| {
            Some(object_results(request, &reply_data))
        });
        let request_budget = Budget::new(
            BudgetLimits {
                max_provider_requests: 0,
                ..BudgetLimits::default()
            },
            None,
            Arc::new(AtomicBool::new(false)),
        );
        let error = provider
            .try_find(&oid, &mut Vec::new(), &request_budget)
            .unwrap_err();
        assert_eq!(error.limit, Some("max_provider_requests"));

        let byte_budget = Budget::new(
            BudgetLimits {
                max_provider_bytes: data.len() as u64 - 1,
                ..BudgetLimits::default()
            },
            None,
            Arc::new(AtomicBool::new(false)),
        );
        let error = provider
            .try_find(&oid, &mut Vec::new(), &byte_budget)
            .unwrap_err();
        assert_eq!(error.limit, Some("max_provider_bytes"));
    }

    #[test]
    fn request_timeout_has_its_own_retryable_mapping() {
        let (oid, _data) = blob();
        let provider = store(
            ProviderOptions {
                request_timeout: Duration::from_millis(5),
                ..ProviderOptions::default()
            },
            |_request| None,
        );
        let error = provider
            .try_find(&oid, &mut Vec::new(), &Budget::unlimited())
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::ProviderTimeout);
        assert!(error.retryable);
        assert_eq!(provider.pending.len(), 0);
    }

    #[test]
    fn cancellation_and_provider_death_wake_sliced_waits() {
        let (oid, _data) = blob();
        let provider = Arc::new(store(
            ProviderOptions {
                request_timeout: Duration::from_secs(5),
                ..ProviderOptions::default()
            },
            |_request| None,
        ));
        let budget = Arc::new(Budget::unlimited());
        let task_provider = Arc::clone(&provider);
        let task_budget = Arc::clone(&budget);
        let cancelled = thread::spawn(move || {
            task_provider
                .try_find(&oid, &mut Vec::new(), &task_budget)
                .unwrap_err()
        });
        while provider.pending.len() == 0 {
            thread::yield_now();
        }
        budget.cancel_flag().store(true, Ordering::Release);
        assert_eq!(cancelled.join().unwrap().code, ErrorCode::Cancelled);

        let budget = Arc::new(Budget::unlimited());
        let task_provider = Arc::clone(&provider);
        let task_budget = Arc::clone(&budget);
        let down = thread::spawn(move || {
            task_provider
                .try_find(&oid, &mut Vec::new(), &task_budget)
                .unwrap_err()
        });
        while provider.pending.len() == 0 {
            thread::yield_now();
        }
        provider.provider_down();
        let error = down.join().unwrap();
        assert_eq!(error.code, ErrorCode::ProviderDown);
        assert!(error.retryable);
        assert_eq!(
            provider
                .try_find(&oid, &mut Vec::new(), &Budget::unlimited())
                .unwrap_err()
                .code,
            ErrorCode::ProviderDown
        );
    }

    #[test]
    fn duplicate_replies_are_take_once_no_ops() {
        let table = PendingTable::default();
        let (slot, sender) = ReplySlot::pair();
        table.insert(7, sender);
        assert!(table.reply(7, ProviderPayload::Results(Vec::new())));
        assert!(!table.reply(7, ProviderPayload::BackendError));
        assert!(matches!(
            slot.recv_timeout(Duration::from_millis(1)),
            Ok(Ok(ProviderPayload::Results(results))) if results.is_empty()
        ));
    }
}
