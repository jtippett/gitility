//! BEAM-free callback reference database.
//!
//! [`ProviderRefDb`] owns request rendezvous, timeouts, liveness, and reply
//! validation. The NIF crate supplies only a transport that sends requests
//! to the supervised Elixir provider process.

use crate::budget::Budget;
use crate::cursor::MAX_CURSOR_BYTES;
use crate::error::{Error, ErrorCode};
use crate::refs::{validate_full_ref_name, RefDb, RefPage, RefQuery, RefTarget};
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

const WAIT_SLICE: Duration = Duration::from_millis(50);

/// Callback operation sent to a ref provider.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RefProviderKind {
    Resolve,
    List,
}

/// A complete decoded provider reply. Backend errors deliberately carry no
/// backend term or configuration across the core boundary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RefProviderPayload {
    Resolve(Option<RefTarget>),
    List(RefPage),
    UnsupportedOperation,
    BackendError,
}

type ReplySender = mpsc::SyncSender<Result<RefProviderPayload, Error>>;

/// Receiving half of one ref-provider rendezvous.
#[derive(Clone)]
pub struct RefReplySlot {
    receiver: Arc<Mutex<mpsc::Receiver<Result<RefProviderPayload, Error>>>>,
}

impl std::fmt::Debug for RefReplySlot {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("RefReplySlot")
            .finish_non_exhaustive()
    }
}

impl RefReplySlot {
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
    ) -> Result<Result<RefProviderPayload, Error>, mpsc::RecvTimeoutError> {
        lock(&self.receiver).recv_timeout(timeout)
    }
}

/// Request handed to a transport implementation.
#[derive(Debug, Clone)]
pub struct RefProviderRequest {
    pub id: u64,
    pub kind: RefProviderKind,
    pub name: Option<Vec<u8>>,
    pub query: Option<RefQuery>,
    pub reply: RefReplySlot,
    pub deadline: Instant,
    pub max_reply_bytes: u64,
}

/// Sends a ref-provider request without waiting for its reply.
pub trait RefProviderTransport: Send + Sync + 'static {
    fn request(&self, request: RefProviderRequest) -> Result<(), Error>;
}

/// Take-once table shared with request resources at the transport boundary.
#[derive(Default)]
pub struct RefPendingTable {
    senders: Mutex<BTreeMap<u64, ReplySender>>,
}

impl std::fmt::Debug for RefPendingTable {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("RefPendingTable")
            .field("len", &lock(&self.senders).len())
            .finish()
    }
}

impl RefPendingTable {
    fn insert(&self, id: u64, sender: ReplySender) {
        lock(&self.senders).insert(id, sender);
    }

    /// Delivers at most one reply. Late and duplicate replies are harmless.
    pub fn reply(&self, id: u64, payload: RefProviderPayload) -> bool {
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

    /// Wakes every current waiter with one sanitized terminal failure.
    pub fn fail_all(&self, error: Error) {
        let senders = std::mem::take(&mut *lock(&self.senders));
        for (_, sender) in senders {
            let _ = sender.send(Err(error.clone()));
        }
    }
}

/// Provider construction options.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RefProviderOptions {
    pub request_timeout: Duration,
}

impl Default for RefProviderOptions {
    fn default() -> Self {
        Self {
            request_timeout: Duration::from_secs(15),
        }
    }
}

/// Reference store whose results arrive through a callback transport.
pub struct ProviderRefDb<T: RefProviderTransport> {
    transport: T,
    options: RefProviderOptions,
    pending: Arc<RefPendingTable>,
    next_id: AtomicU64,
    alive: AtomicBool,
}

impl<T: RefProviderTransport> std::fmt::Debug for ProviderRefDb<T> {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ProviderRefDb")
            .field("options", &self.options)
            .field("alive", &self.alive.load(Ordering::Acquire))
            .finish_non_exhaustive()
    }
}

impl<T: RefProviderTransport> ProviderRefDb<T> {
    pub fn new(options: RefProviderOptions, transport: T) -> Self {
        Self::new_with_pending(options, transport, Arc::new(RefPendingTable::default()))
    }

    pub fn new_with_pending(
        options: RefProviderOptions,
        transport: T,
        pending: Arc<RefPendingTable>,
    ) -> Self {
        Self {
            transport,
            options,
            pending,
            next_id: AtomicU64::new(1),
            alive: AtomicBool::new(true),
        }
    }

    pub fn pending_table(&self) -> &Arc<RefPendingTable> {
        &self.pending
    }

    pub fn fail_all(&self, error: Error) {
        self.alive.store(false, Ordering::Release);
        self.pending.fail_all(error);
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

    fn send_and_wait(
        &self,
        kind: RefProviderKind,
        name: Option<Vec<u8>>,
        query: Option<RefQuery>,
        budget: &Budget,
    ) -> Result<RefProviderPayload, Error> {
        budget.charge_provider_request()?;
        let now = Instant::now();
        let request_deadline = now.checked_add(self.options.request_timeout).unwrap_or(now);
        let deadline = budget
            .deadline()
            .map_or(request_deadline, |budget_deadline| {
                request_deadline.min(budget_deadline)
            });
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (reply, sender) = RefReplySlot::pair();
        self.pending.insert(id, sender);
        if let Err(error) = self.ensure_alive() {
            self.pending.cancel(id);
            return Err(error);
        }
        let max_reply_bytes = budget
            .limits()
            .max_provider_bytes
            .saturating_sub(budget.spent().3);
        if let Err(error) = self.transport.request(RefProviderRequest {
            id,
            kind,
            name,
            query,
            reply: reply.clone(),
            deadline,
            max_reply_bytes,
        }) {
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
}

impl<T: RefProviderTransport> RefDb for ProviderRefDb<T> {
    fn resolve(&self, name: &[u8], budget: &Budget) -> Result<Option<RefTarget>, Error> {
        validate_full_ref_name(name).map_err(|_| {
            Error::new(
                ErrorCode::InvalidArgument,
                "reference lookup requires a valid full ref name",
            )
        })?;
        match self.send_and_wait(RefProviderKind::Resolve, Some(name.to_vec()), None, budget)? {
            RefProviderPayload::Resolve(target) => {
                if let Some(target) = &target {
                    validate_target(target)?;
                    budget.charge_provider_bytes(target_size(target))?;
                }
                Ok(target)
            }
            RefProviderPayload::BackendError => Err(Error::retryable(
                ErrorCode::BackendError,
                "ref provider callback failed",
            )),
            RefProviderPayload::UnsupportedOperation | RefProviderPayload::List(_) => Err(
                protocol_error("ref provider resolve reply has the wrong shape"),
            ),
        }
    }

    fn list(&self, query: RefQuery, budget: &Budget) -> Result<RefPage, Error> {
        if query.limit == 0 {
            return Err(Error::new(
                ErrorCode::InvalidArgument,
                "reference page limit must be positive",
            ));
        }
        if query
            .cursor
            .as_ref()
            .is_some_and(|cursor| cursor.len() > MAX_CURSOR_BYTES)
        {
            return Err(protocol_error(
                "ref provider received a cursor larger than 4096 bytes",
            ));
        }
        match self.send_and_wait(RefProviderKind::List, None, Some(query.clone()), budget)? {
            RefProviderPayload::UnsupportedOperation => Err(Error::new(
                ErrorCode::UnsupportedOperation,
                "ref provider does not support listing references",
            )),
            RefProviderPayload::BackendError => Err(Error::retryable(
                ErrorCode::BackendError,
                "ref provider callback failed",
            )),
            RefProviderPayload::List(page) => {
                validate_page(&page, &query)?;
                let bytes = page_size(&page);
                if bytes
                    > budget
                        .limits()
                        .max_provider_bytes
                        .saturating_sub(budget.spent().3)
                {
                    return Err(Error::new(
                        ErrorCode::BudgetExceeded,
                        "max_provider_bytes exceeded",
                    )
                    .with_limit("max_provider_bytes"));
                }
                budget.charge_provider_bytes(bytes)?;
                Ok(page)
            }
            RefProviderPayload::Resolve(_) => Err(protocol_error(
                "ref provider list reply has the wrong shape",
            )),
        }
    }
}

fn validate_target(target: &RefTarget) -> Result<(), Error> {
    match target {
        RefTarget::Symbolic(name) => validate_full_ref_name(name)
            .map_err(|_| protocol_error("ref provider returned an invalid symbolic target name")),
        RefTarget::Direct {
            oid,
            peeled: Some(peeled),
        } if oid.kind() != peeled.kind() => Err(protocol_error(
            "ref provider returned direct and peeled IDs with different hash algorithms",
        )),
        RefTarget::Direct { .. } => Ok(()),
    }
}

fn validate_page(page: &RefPage, query: &RefQuery) -> Result<(), Error> {
    if page.refs.len() > query.limit {
        return Err(protocol_error(
            "ref provider returned more references than the requested limit",
        ));
    }
    if page
        .next_cursor
        .as_ref()
        .is_some_and(|cursor| cursor.len() > MAX_CURSOR_BYTES)
    {
        return Err(protocol_error(
            "ref provider returned a cursor larger than 4096 bytes",
        ));
    }
    if page.truncated != page.next_cursor.is_some() {
        return Err(protocol_error(
            "ref provider page truncation and cursor fields disagree",
        ));
    }
    if page.refs.is_empty() && page.truncated {
        return Err(protocol_error(
            "ref provider returned an empty truncated page",
        ));
    }
    let mut previous: Option<&[u8]> = None;
    for (name, target) in &page.refs {
        validate_full_ref_name(name)
            .map_err(|_| protocol_error("ref provider returned an invalid full ref name"))?;
        if query
            .prefix
            .as_deref()
            .is_some_and(|prefix| !name.starts_with(prefix))
        {
            return Err(protocol_error(
                "ref provider returned a name outside the requested prefix",
            ));
        }
        if previous.is_some_and(|previous| previous >= name.as_slice()) {
            return Err(protocol_error(
                "ref provider returned names outside strict byte order",
            ));
        }
        validate_target(target)?;
        previous = Some(name);
    }
    Ok(())
}

fn target_size(target: &RefTarget) -> u64 {
    match target {
        RefTarget::Symbolic(name) => name.len() as u64,
        RefTarget::Direct { oid, peeled } => {
            oid.as_bytes().len() as u64
                + peeled
                    .as_ref()
                    .map_or(0, |peeled| peeled.as_bytes().len() as u64)
        }
    }
}

fn page_size(page: &RefPage) -> u64 {
    page.refs.iter().fold(
        page.next_cursor
            .as_ref()
            .map_or(0, |cursor| cursor.len() as u64),
        |total, (name, target)| {
            total
                .saturating_add(name.len() as u64)
                .saturating_add(target_size(target))
        },
    )
}

fn provider_down() -> Error {
    Error::retryable(ErrorCode::ProviderDown, "ref provider process is down")
}

fn provider_timeout() -> Error {
    Error::retryable(
        ErrorCode::ProviderTimeout,
        "ref provider request deadline expired",
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::object::{HashKind, Oid};
    use std::sync::atomic::AtomicUsize;
    use std::sync::Weak;

    #[derive(Clone)]
    struct TestTransport {
        pending: Weak<RefPendingTable>,
        responder: Arc<dyn Fn(&RefProviderRequest) -> RefProviderPayload + Send + Sync>,
    }

    impl RefProviderTransport for TestTransport {
        fn request(&self, request: RefProviderRequest) -> Result<(), Error> {
            let payload = (self.responder)(&request);
            self.pending
                .upgrade()
                .expect("pending table remains alive")
                .reply(request.id, payload);
            Ok(())
        }
    }

    fn provider(
        responder: impl Fn(&RefProviderRequest) -> RefProviderPayload + Send + Sync + 'static,
    ) -> ProviderRefDb<TestTransport> {
        let pending = Arc::new(RefPendingTable::default());
        let transport = TestTransport {
            pending: Arc::downgrade(&pending),
            responder: Arc::new(responder),
        };
        ProviderRefDb::new_with_pending(RefProviderOptions::default(), transport, pending)
    }

    fn oid(byte: u8) -> Oid {
        Oid::new(HashKind::Sha1, &[byte; 20]).unwrap()
    }

    #[test]
    fn resolve_preserves_missing_and_validates_symbolic_targets() {
        let store = provider(|request| {
            if request.name.as_deref() == Some(b"refs/heads/main") {
                RefProviderPayload::Resolve(Some(RefTarget::Direct {
                    oid: oid(1),
                    peeled: None,
                }))
            } else {
                RefProviderPayload::Resolve(None)
            }
        });
        assert!(store
            .resolve(b"refs/heads/main", &Budget::unlimited())
            .unwrap()
            .is_some());
        assert!(store
            .resolve(b"refs/heads/missing", &Budget::unlimited())
            .unwrap()
            .is_none());

        let broken = provider(|_| {
            RefProviderPayload::Resolve(Some(RefTarget::Symbolic(b"heads/not-full".to_vec())))
        });
        assert_eq!(
            broken
                .resolve(b"refs/heads/main", &Budget::unlimited())
                .unwrap_err()
                .code,
            ErrorCode::ProviderProtocolError
        );
    }

    #[test]
    fn symbolic_resolution_observes_independent_provider_hops_and_directs_use_one_call() {
        let calls = Arc::new(AtomicUsize::new(0));
        let responder_calls = Arc::clone(&calls);
        let moving = provider(move |request| {
            let generation = responder_calls.fetch_add(1, Ordering::SeqCst);
            match (generation, request.name.as_deref()) {
                (0, Some(b"refs/heads/moving")) => RefProviderPayload::Resolve(Some(
                    RefTarget::Symbolic(b"refs/heads/target".to_vec()),
                )),
                (1, Some(b"refs/heads/target")) => {
                    RefProviderPayload::Resolve(Some(RefTarget::Direct {
                        oid: oid(2),
                        peeled: None,
                    }))
                }
                _ => RefProviderPayload::Resolve(None),
            }
        });
        assert_eq!(
            crate::refs::resolve_symbolic(&moving, b"refs/heads/moving", &Budget::unlimited())
                .unwrap(),
            Some(RefTarget::Direct {
                oid: oid(2),
                peeled: None,
            })
        );
        assert_eq!(calls.load(Ordering::SeqCst), 2);

        let direct_calls = Arc::new(AtomicUsize::new(0));
        let responder_calls = Arc::clone(&direct_calls);
        let direct = provider(move |_| {
            responder_calls.fetch_add(1, Ordering::SeqCst);
            RefProviderPayload::Resolve(Some(RefTarget::Direct {
                oid: oid(1),
                peeled: None,
            }))
        });
        assert_eq!(
            crate::refs::resolve_symbolic(&direct, b"refs/heads/direct", &Budget::unlimited())
                .unwrap(),
            Some(RefTarget::Direct {
                oid: oid(1),
                peeled: None,
            })
        );
        assert_eq!(direct_calls.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn list_requires_order_prefix_limit_and_cursor_consistency() {
        let good = provider(|request| {
            assert_eq!(request.kind, RefProviderKind::List);
            RefProviderPayload::List(RefPage {
                refs: vec![
                    (
                        b"refs/heads/a".to_vec(),
                        RefTarget::Direct {
                            oid: oid(1),
                            peeled: None,
                        },
                    ),
                    (
                        b"refs/heads/b".to_vec(),
                        RefTarget::Direct {
                            oid: oid(2),
                            peeled: None,
                        },
                    ),
                ],
                next_cursor: None,
                truncated: false,
                warnings: Vec::new(),
            })
        });
        assert_eq!(
            good.list(
                RefQuery {
                    prefix: Some(b"refs/heads/".to_vec()),
                    limit: 2,
                    cursor: None,
                },
                &Budget::unlimited()
            )
            .unwrap()
            .refs
            .len(),
            2
        );

        let broken = provider(|_| {
            RefProviderPayload::List(RefPage {
                refs: Vec::new(),
                next_cursor: Some(b"loop".to_vec()),
                truncated: true,
                warnings: Vec::new(),
            })
        });
        assert_eq!(
            broken
                .list(
                    RefQuery {
                        limit: 1,
                        ..RefQuery::default()
                    },
                    &Budget::unlimited()
                )
                .unwrap_err()
                .code,
            ErrorCode::ProviderProtocolError
        );
    }

    #[test]
    fn inbound_provider_cursor_is_capped_before_callback_dispatch() {
        let calls = Arc::new(AtomicUsize::new(0));
        let responder_calls = Arc::clone(&calls);
        let store = provider(move |_| {
            responder_calls.fetch_add(1, Ordering::SeqCst);
            RefProviderPayload::List(RefPage {
                refs: Vec::new(),
                next_cursor: None,
                truncated: false,
                warnings: Vec::new(),
            })
        });
        let error = store
            .list(
                RefQuery {
                    prefix: None,
                    limit: 1,
                    cursor: Some(vec![0; MAX_CURSOR_BYTES + 1]),
                },
                &Budget::unlimited(),
            )
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::ProviderProtocolError);
        assert_eq!(calls.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn provider_down_wakes_and_poisons_the_handle() {
        let store = provider(|_| RefProviderPayload::Resolve(None));
        store.provider_down();
        let error = store
            .resolve(b"refs/heads/main", &Budget::unlimited())
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::ProviderDown);
        assert!(error.retryable);
    }

    #[test]
    fn request_timeout_is_independent_and_retryable() {
        #[derive(Clone)]
        struct SilentTransport;

        impl RefProviderTransport for SilentTransport {
            fn request(&self, _request: RefProviderRequest) -> Result<(), Error> {
                Ok(())
            }
        }

        let store = ProviderRefDb::new(
            RefProviderOptions {
                request_timeout: Duration::from_millis(1),
            },
            SilentTransport,
        );
        let error = store
            .resolve(b"refs/heads/main", &Budget::unlimited())
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::ProviderTimeout);
        assert!(error.retryable);
        assert_eq!(lock(&store.pending_table().senders).len(), 0);
    }
}
