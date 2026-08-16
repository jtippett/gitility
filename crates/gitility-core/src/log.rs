//! Deterministic, budgeted commit-log traversal and pagination.
//!
//! Cursor resume deliberately replays the walk from the snapshot commit and
//! skips through the recorded position, so its cost is O(prefix).

use crate::budget::Budget;
use crate::cursor::{self, Cursor, CursorExpected, MAX_CURSOR_BYTES, OPERATION_LOG};
use crate::decode::{decode_identity, Identity};
use crate::error::{Error, ErrorCode, ErrorOrder};
use crate::object::{HashKind, ObjectKind, Oid};
use crate::odb::ObjectDb;
use crate::snapshot::Snapshot;
use crate::tree::QueryStats;
use std::cmp::Ordering;
use std::collections::{BinaryHeap, HashMap, HashSet, VecDeque};

const SUBJECT_BYTES: usize = 1024;
const MESSAGE_BYTES: usize = 64 * 1024;

/// Ordering for a commit log.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum LogOrder {
    /// Committer-time priority, newest first, like plain `git log`.
    #[default]
    Chronological,
    /// Topological order, keeping parallel lines from being intermixed.
    Topological,
    /// Topological constraints with committer-time priority.
    DateOrder,
}

/// Options for [`log`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LogOptions {
    pub order: LogOrder,
    pub first_parent: bool,
    pub since: Option<i64>,
    pub until: Option<i64>,
    pub limit: usize,
    pub cursor: Option<Vec<u8>>,
}

impl Default for LogOptions {
    fn default() -> Self {
        Self {
            order: LogOrder::Chronological,
            first_parent: false,
            since: None,
            until: None,
            limit: 1_000,
            cursor: None,
        }
    }
}

/// An author or committer attached to an emitted log commit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LogIdentity {
    pub name: Vec<u8>,
    pub email: Vec<u8>,
    pub time: i64,
    /// The exact raw timezone header, retaining encodings such as `-0000`.
    pub tz: Vec<u8>,
    /// Parsed UTC offset in minutes. Malformed or out-of-range raw values are
    /// retained in `tz` and represented here as `None`.
    pub tz_offset_minutes: Option<i32>,
}

/// One bounded, byte-preserving commit result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LogCommit {
    pub id: Oid,
    pub parents: Vec<Oid>,
    pub tree_id: Oid,
    pub author: LogIdentity,
    pub committer: LogIdentity,
    pub subject: Vec<u8>,
    pub subject_truncated: bool,
    pub message_raw: Vec<u8>,
    pub message_truncated: bool,
    /// Raw signature-bearing header names only, never their payloads.
    pub signature_headers: Vec<Vec<u8>>,
    pub encoding: Option<Vec<u8>>,
}

/// One page from a deterministic commit walk.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LogPage {
    pub commits: Vec<LogCommit>,
    pub next_cursor: Option<Vec<u8>>,
    pub truncated: bool,
    pub stats: QueryStats,
}

/// Walks commits reachable from `snapshot.commit_oid`.
///
/// Timeout and cancellation are hard errors. Count ceilings become a
/// successful truncated page once at least one commit has been emitted.
pub fn log(
    store: &dyn ObjectDb,
    snapshot: &Snapshot,
    opts: &LogOptions,
    budget: &Budget,
) -> Result<LogPage, Error> {
    crate::commit_graph::ensure_sha1(store, &[snapshot.commit_oid, snapshot.tree_oid])?;
    if opts.limit == 0 {
        return Err(Error::new(
            ErrorCode::InvalidArgument,
            "commit log page limit must be greater than zero",
        ));
    }
    budget.check()?;

    let fingerprint = option_fingerprint(opts);
    let expected = CursorExpected {
        hash_kind: snapshot.commit_oid.kind(),
        snapshot_digest: snapshot.commit_oid.as_bytes(),
        operation_tag: OPERATION_LOG,
        option_fingerprint: fingerprint,
    };
    let resume = opts
        .cursor
        .as_deref()
        .map(|bytes| decode_resume(bytes, expected, snapshot.commit_oid.kind()))
        .transpose()?;

    let mut walk = Walk::new(store, snapshot.commit_oid, opts, budget)?;
    let mut found_resume = resume.is_none();
    let mut commits = Vec::with_capacity(opts.limit.min(1_024));
    let mut stopped_by = None;

    loop {
        budget.check()?;
        let walked = match walk.next(found_resume) {
            Some(Ok(walked)) => walked,
            Some(Err(error)) if truncatable(&error) && !commits.is_empty() => {
                stopped_by = Some(error.limit.unwrap_or("budget"));
                break;
            }
            Some(Err(error)) => return Err(error),
            None => break,
        };

        if !found_resume {
            if Some(walked.id) == resume {
                found_resume = true;
            }
            continue;
        }

        if !within_time_bounds(walked.time, opts) {
            continue;
        }
        if commits.len() == opts.limit {
            stopped_by = Some("limit");
            break;
        }
        let payload = match read_payload(store, walked.id, budget, false) {
            Ok(payload) => payload,
            Err(error) if truncatable(&error) && !commits.is_empty() => {
                stopped_by = Some(error.limit.unwrap_or("budget"));
                break;
            }
            Err(error) => return Err(error),
        };
        let shallow = store
            .shallow_roots()
            .is_some_and(|roots| roots.contains(&walked.id));
        let decoded = decode_log_commit(walked.id, &payload, shallow)?;
        commits.push(decoded);

        if let Some(error) = walk.take_pending_error() {
            if truncatable(&error) && !commits.is_empty() {
                stopped_by = Some(error.limit.unwrap_or("budget"));
                break;
            }
            return Err(error);
        }
        if commits.len() == opts.limit && walk.has_matching(opts) {
            stopped_by = Some("limit");
            break;
        }
    }

    if !found_resume {
        return Err(invalid_cursor(
            "position check failed: commit is not in this traversal",
        ));
    }

    let truncated = stopped_by.is_some();
    if truncated && commits.is_empty() {
        return Err(Error::new(
            ErrorCode::BudgetExceeded,
            "budget exhausted before any commit-log pagination progress",
        )
        .with_limit(stopped_by.expect("a stopped walk names its limit")));
    }
    let next_cursor = if truncated {
        let position = commits
            .last()
            .expect("a truncated page made pagination progress")
            .id
            .as_bytes()
            .to_vec();
        let encoded = cursor::encode(&Cursor {
            hash_kind: snapshot.commit_oid.kind(),
            snapshot_digest: snapshot.commit_oid.as_bytes().to_vec(),
            operation_tag: OPERATION_LOG,
            option_fingerprint: fingerprint,
            generation: Vec::new(),
            position,
        });
        if encoded.len() > MAX_CURSOR_BYTES {
            return Err(Error::new(
                ErrorCode::ResultTooLarge,
                "commit log cursor exceeds the cursor size limit",
            ));
        }
        Some(encoded)
    } else {
        None
    };

    let (objects_read, bytes_read, _, _) = budget.spent();
    let (cache_hits, cache_misses) = budget.cache_spent();
    let cache_stats = store.cache_stats();
    let entries_emitted = commits.len() as u64;
    Ok(LogPage {
        commits,
        next_cursor,
        truncated,
        stats: QueryStats {
            objects_read,
            bytes_read,
            entries_emitted,
            cache_hits,
            cache_misses,
            cache_bytes: cache_stats.bytes,
            cache_entries: cache_stats.entries,
            cache_evictions: cache_stats.evictions,
            files_scanned: 0,
            blobs_deduped: 0,
            binary_skipped: 0,
            oversize_skipped: 0,
            payload_rereads: 0,
            stopped_by,
        },
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct CommitMeta {
    parents: Vec<Oid>,
    time: i64,
}

#[derive(Debug, PartialEq, Eq)]
struct TimedCommit {
    id: Oid,
    meta: CommitMeta,
    sequence: u64,
}

impl Ord for TimedCommit {
    fn cmp(&self, other: &Self) -> Ordering {
        self.meta
            .time
            .cmp(&other.meta.time)
            .then_with(|| other.sequence.cmp(&self.sequence))
    }
}

impl PartialOrd for TimedCommit {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct WalkedCommit {
    pub(crate) id: Oid,
    pub(crate) time: i64,
}

pub(crate) enum Walk<'a> {
    Chronological(ChronologicalWalk<'a>),
    Ordered(OrderedWalk),
}

impl<'a> Walk<'a> {
    pub(crate) fn new(
        store: &'a dyn ObjectDb,
        start: Oid,
        opts: &'a LogOptions,
        budget: &'a Budget,
    ) -> Result<Self, Error> {
        match opts.order {
            LogOrder::Chronological => Ok(Self::Chronological(ChronologicalWalk::new(
                store, start, opts, budget,
            )?)),
            LogOrder::Topological | LogOrder::DateOrder => {
                Ok(Self::Ordered(OrderedWalk::new(store, start, opts, budget)?))
            }
        }
    }

    pub(crate) fn next(&mut self, charge_visit: bool) -> Option<Result<WalkedCommit, Error>> {
        match self {
            Self::Chronological(walk) => walk.next(charge_visit),
            Self::Ordered(walk) => walk.next(),
        }
    }

    pub(crate) fn take_pending_error(&mut self) -> Option<Error> {
        match self {
            Self::Chronological(walk) => walk.pending_error.take(),
            Self::Ordered(_) => None,
        }
    }

    fn has_matching(&self, opts: &LogOptions) -> bool {
        match self {
            Self::Chronological(walk) => {
                walk.pending_error.is_some()
                    || walk
                        .queue
                        .iter()
                        .any(|commit| within_time_bounds(commit.meta.time, opts))
            }
            Self::Ordered(walk) => walk.has_matching(opts),
        }
    }
}

pub(crate) struct ChronologicalWalk<'a> {
    store: &'a dyn ObjectDb,
    opts: &'a LogOptions,
    budget: &'a Budget,
    queue: BinaryHeap<TimedCommit>,
    seen: HashSet<Oid>,
    next_sequence: u64,
    pending_error: Option<Error>,
}

impl<'a> ChronologicalWalk<'a> {
    fn new(
        store: &'a dyn ObjectDb,
        start: Oid,
        opts: &'a LogOptions,
        budget: &'a Budget,
    ) -> Result<Self, Error> {
        let meta = read_meta(store, start, opts, budget, true)?;
        Ok(Self {
            store,
            opts,
            budget,
            queue: BinaryHeap::from([TimedCommit {
                id: start,
                meta,
                sequence: 0,
            }]),
            seen: HashSet::from([start]),
            next_sequence: 1,
            pending_error: None,
        })
    }

    fn next(&mut self, charge_visit: bool) -> Option<Result<WalkedCommit, Error>> {
        if let Some(error) = self.pending_error.take() {
            return Some(Err(error));
        }
        let current = self.queue.pop()?;
        if let Err(error) = if charge_visit {
            self.budget.charge_object_visit()
        } else {
            self.budget.check()
        } {
            return Some(Err(error));
        }

        for parent in &current.meta.parents {
            if !self.seen.insert(*parent) {
                continue;
            }
            match read_meta(self.store, *parent, self.opts, self.budget, false) {
                Ok(meta) => {
                    self.queue.push(TimedCommit {
                        id: *parent,
                        meta,
                        sequence: self.next_sequence,
                    });
                    self.next_sequence = self.next_sequence.saturating_add(1);
                }
                Err(error) => {
                    self.pending_error = Some(error);
                    break;
                }
            }
        }

        Some(Ok(WalkedCommit {
            id: current.id,
            time: current.meta.time,
        }))
    }
}

struct OrderedNode {
    meta: CommitMeta,
    discovery: u64,
}

enum OrderedQueue {
    Topological(Vec<Oid>),
    Date(BinaryHeap<TimedOid>),
}

#[derive(Debug, PartialEq, Eq)]
struct TimedOid {
    id: Oid,
    time: i64,
    sequence: u64,
}

impl Ord for TimedOid {
    fn cmp(&self, other: &Self) -> Ordering {
        self.time
            .cmp(&other.time)
            .then_with(|| other.sequence.cmp(&self.sequence))
    }
}

impl PartialOrd for TimedOid {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

pub(crate) struct OrderedWalk {
    nodes: HashMap<Oid, OrderedNode>,
    child_counts: HashMap<Oid, usize>,
    queue: OrderedQueue,
    next_sequence: u64,
    emitted: HashSet<Oid>,
    residue: VecDeque<Oid>,
}

impl OrderedWalk {
    fn new(
        store: &dyn ObjectDb,
        start: Oid,
        opts: &LogOptions,
        budget: &Budget,
    ) -> Result<Self, Error> {
        let mut pending = vec![start];
        let mut nodes = HashMap::new();
        let mut discovery = 0u64;
        while let Some(id) = pending.pop() {
            if nodes.contains_key(&id) {
                continue;
            }
            budget
                .charge_object_visit()
                .map_err(|error| ordered_prepass_error(error, opts.order))?;
            let meta = read_meta(store, id, opts, budget, id == start)?;
            for parent in meta.parents.iter().rev() {
                if !nodes.contains_key(parent) {
                    pending.push(*parent);
                }
            }
            nodes.insert(id, OrderedNode { meta, discovery });
            discovery = discovery.saturating_add(1);
        }

        let mut child_counts = nodes
            .keys()
            .copied()
            .map(|id| (id, 0usize))
            .collect::<HashMap<_, _>>();
        for node in nodes.values() {
            for parent in &node.meta.parents {
                if let Some(count) = child_counts.get_mut(parent) {
                    *count += 1;
                }
            }
        }
        let mut initial = child_counts
            .iter()
            .filter_map(|(id, count)| (*count == 0).then_some(*id))
            .collect::<Vec<_>>();
        initial.sort_by_key(|id| {
            let node = &nodes[id];
            (node.meta.time, node.discovery)
        });
        let mut next_sequence = 0u64;
        let queue = match opts.order {
            LogOrder::Topological => OrderedQueue::Topological(initial),
            LogOrder::DateOrder => {
                let mut queue = BinaryHeap::new();
                for id in initial.into_iter().rev() {
                    queue.push(TimedOid {
                        id,
                        time: nodes[&id].meta.time,
                        sequence: next_sequence,
                    });
                    next_sequence = next_sequence.saturating_add(1);
                }
                OrderedQueue::Date(queue)
            }
            LogOrder::Chronological => unreachable!("ordered walk excludes chronological"),
        };
        Ok(Self {
            nodes,
            child_counts,
            queue,
            next_sequence,
            emitted: HashSet::new(),
            residue: VecDeque::new(),
        })
    }

    fn next(&mut self) -> Option<Result<WalkedCommit, Error>> {
        let (id, is_residue) = match self.pop_ready() {
            Some(id) => (id, false),
            None => (self.pop_residue()?, true),
        };
        let node = &self.nodes[&id];
        let walked = WalkedCommit {
            id,
            time: node.meta.time,
        };
        let parents = node.meta.parents.clone();
        self.emitted.insert(id);
        if !is_residue {
            for parent in parents {
                let count = self
                    .child_counts
                    .get_mut(&parent)
                    .expect("reachable parents have pre-pass child counts");
                *count = count.saturating_sub(1);
                if *count == 0 {
                    self.push_ready(parent);
                }
            }
        }
        Some(Ok(walked))
    }

    fn pop_ready(&mut self) -> Option<Oid> {
        match &mut self.queue {
            OrderedQueue::Topological(queue) => queue.pop(),
            OrderedQueue::Date(queue) => queue.pop().map(|entry| entry.id),
        }
    }

    fn push_ready(&mut self, id: Oid) {
        match &mut self.queue {
            OrderedQueue::Topological(queue) => queue.push(id),
            OrderedQueue::Date(queue) => {
                queue.push(TimedOid {
                    id,
                    time: self.nodes[&id].meta.time,
                    sequence: self.next_sequence,
                });
                self.next_sequence = self.next_sequence.saturating_add(1);
            }
        }
    }

    fn pop_residue(&mut self) -> Option<Oid> {
        if self.residue.is_empty() && self.emitted.len() < self.nodes.len() {
            let mut residue = self
                .nodes
                .keys()
                .filter(|id| !self.emitted.contains(id))
                .copied()
                .collect::<Vec<_>>();
            residue.sort_unstable();
            self.residue = residue.into();
        }
        self.residue.pop_back()
    }

    fn has_matching(&self, opts: &LogOptions) -> bool {
        self.nodes.iter().any(|(id, node)| {
            !self.emitted.contains(id) && within_time_bounds(node.meta.time, opts)
        })
    }
}

fn ordered_prepass_error(error: Error, order: LogOrder) -> Error {
    if error.code == ErrorCode::BudgetExceeded && error.limit == Some("max_objects") {
        let error_order = match order {
            LogOrder::Topological => ErrorOrder::Topological,
            LogOrder::DateOrder => ErrorOrder::Date,
            LogOrder::Chronological => unreachable!("chronological order has no pre-pass"),
        };
        let order_name = error_order.as_str();
        Error::new(
            ErrorCode::BudgetExceeded,
            format!(
                ":{order_name} order requires limits.max_objects at or above the reachable commit count"
            ),
        )
        .with_limit("max_objects")
        .with_order(error_order)
    } else {
        error
    }
}

fn read_meta(
    store: &dyn ObjectDb,
    id: Oid,
    opts: &LogOptions,
    budget: &Budget,
    input: bool,
) -> Result<CommitMeta, Error> {
    let payload = read_payload(store, id, budget, input)?;
    let (headers, _) = split_commit(&payload).map_err(|error| error.with_oid_if_none(id))?;
    let mut parents = Vec::new();
    let mut time = None;
    for line in headers.split(|byte| *byte == b'\n') {
        if line.starts_with(b" ") {
            continue;
        }
        let (name, value) = split_header(line).map_err(|error| error.with_oid_if_none(id))?;
        match name {
            b"parent" => parents.push(parse_oid(value, id.kind(), "commit parent", id)?),
            b"committer" => {
                time = Some(identity_time(value).map_err(|error| error.with_oid_if_none(id))?)
            }
            _ => {}
        }
    }
    let time = time.ok_or_else(|| {
        Error::new(
            ErrorCode::MalformedObject,
            "commit payload is missing its committer header",
        )
        .with_oid(id)
    })?;
    if opts.first_parent {
        parents.truncate(1);
    }
    if opts.since.is_some_and(|since| time < since)
        || store
            .shallow_roots()
            .is_some_and(|roots| roots.contains(&id))
    {
        parents.clear();
    }
    Ok(CommitMeta { parents, time })
}

pub(crate) fn read_payload(
    store: &dyn ObjectDb,
    id: Oid,
    budget: &Budget,
    input: bool,
) -> Result<Vec<u8>, Error> {
    let mut payload = Vec::new();
    let kind = store
        .try_find_graph(&id, &mut payload, budget)
        .map_err(|error| error.with_oid_if_none(id))?
        .ok_or_else(|| {
            Error::retryable(
                ErrorCode::MissingObject,
                format!("commit object {id} is missing from the object store"),
            )
            .with_oid(id)
        })?;
    if kind != ObjectKind::Commit {
        return Err(Error::new(
            if input {
                ErrorCode::NotACommit
            } else {
                ErrorCode::MalformedObject
            },
            format!("object {id} reached by commit traversal is not a commit"),
        )
        .with_oid(id));
    }
    Ok(payload)
}

pub(crate) fn decode_log_commit(
    id: Oid,
    payload: &[u8],
    shallow: bool,
) -> Result<LogCommit, Error> {
    let (headers, message) = split_commit(payload).map_err(|error| error.with_oid_if_none(id))?;
    let message_len = message.len().min(MESSAGE_BYTES);
    let subject_len = message
        .iter()
        .position(|byte| *byte == b'\n')
        .unwrap_or(message.len());
    let subject_end = subject_len.min(SUBJECT_BYTES);
    let mut tree_id = None;
    let mut parents = Vec::new();
    let mut author = None;
    let mut committer = None;
    let mut signature_headers = Vec::new();
    let mut encoding = None;
    for line in headers.split(|byte| *byte == b'\n') {
        if line.starts_with(b" ") {
            continue;
        }
        let (name, value) = split_header(line).map_err(|error| error.with_oid_if_none(id))?;
        match name {
            b"tree" => tree_id = Some(parse_oid(value, id.kind(), "commit tree", id)?),
            b"parent" => parents.push(parse_oid(value, id.kind(), "commit parent", id)?),
            b"author" => {
                author = Some(decode_identity(value).map_err(|error| error.with_oid_if_none(id))?)
            }
            b"committer" => {
                committer =
                    Some(decode_identity(value).map_err(|error| error.with_oid_if_none(id))?)
            }
            b"encoding" => encoding = Some(value.to_vec()),
            name if is_signature_header(name) => signature_headers.push(name.to_vec()),
            _ => {}
        }
    }
    if shallow {
        parents.clear();
    }
    Ok(LogCommit {
        id,
        parents,
        tree_id: tree_id.ok_or_else(|| malformed_for(id, "commit payload is missing its tree"))?,
        author: log_identity(
            author.ok_or_else(|| malformed_for(id, "commit payload is missing its author"))?,
        ),
        committer: log_identity(
            committer
                .ok_or_else(|| malformed_for(id, "commit payload is missing its committer"))?,
        ),
        subject: message[..subject_end].to_vec(),
        subject_truncated: subject_len > SUBJECT_BYTES,
        message_raw: message[..message_len].to_vec(),
        message_truncated: message.len() > MESSAGE_BYTES,
        signature_headers,
        encoding,
    })
}

fn log_identity(identity: Identity) -> LogIdentity {
    let tz_offset_minutes = timezone_offset_minutes(&identity.tz);
    LogIdentity {
        name: identity.name,
        email: identity.email,
        time: identity.time,
        tz: identity.tz,
        tz_offset_minutes,
    }
}

fn timezone_offset_minutes(tz: &[u8]) -> Option<i32> {
    let [sign @ (b'+' | b'-'), h1, h2, m1, m2] = tz else {
        return None;
    };
    if ![h1, h2, m1, m2]
        .into_iter()
        .all(|digit| digit.is_ascii_digit())
    {
        return None;
    }
    let hours = i32::from(h1 - b'0') * 10 + i32::from(h2 - b'0');
    let minutes = i32::from(m1 - b'0') * 10 + i32::from(m2 - b'0');
    if hours >= 24 || minutes >= 60 {
        return None;
    }
    let offset = hours * 60 + minutes;
    Some(if *sign == b'-' { -offset } else { offset })
}

fn split_commit(payload: &[u8]) -> Result<(&[u8], &[u8]), Error> {
    let separator = payload
        .windows(2)
        .position(|window| window == b"\n\n")
        .ok_or_else(|| {
            Error::new(
                ErrorCode::MalformedObject,
                "commit payload has no message separator",
            )
        })?;
    Ok((&payload[..separator], &payload[separator + 2..]))
}

fn split_header(line: &[u8]) -> Result<(&[u8], &[u8]), Error> {
    let separator = line
        .iter()
        .position(|byte| *byte == b' ')
        .ok_or_else(|| Error::new(ErrorCode::MalformedObject, "commit header is malformed"))?;
    if separator == 0 || separator + 1 >= line.len() {
        return Err(Error::new(
            ErrorCode::MalformedObject,
            "commit header is malformed",
        ));
    }
    Ok((&line[..separator], &line[separator + 1..]))
}

fn identity_time(raw: &[u8]) -> Result<i64, Error> {
    let right = raw
        .iter()
        .rposition(|byte| *byte == b'>')
        .ok_or_else(|| Error::new(ErrorCode::MalformedObject, "commit identity is malformed"))?;
    let suffix = raw
        .get(right + 1..)
        .and_then(|rest| rest.strip_prefix(b" "))
        .ok_or_else(|| {
            Error::new(
                ErrorCode::MalformedObject,
                "commit identity is missing its timestamp",
            )
        })?;
    let timestamp = suffix
        .split(|byte| *byte == b' ')
        .next()
        .filter(|value| !value.is_empty())
        .and_then(|value| std::str::from_utf8(value).ok())
        .and_then(|value| value.parse::<i64>().ok())
        .ok_or_else(|| {
            Error::new(
                ErrorCode::MalformedObject,
                "commit identity timestamp is malformed",
            )
        })?;
    Ok(timestamp)
}

fn parse_oid(raw: &[u8], kind: HashKind, field: &str, object: Oid) -> Result<Oid, Error> {
    let text = std::str::from_utf8(raw).map_err(|_| malformed_for(object, field))?;
    let oid = Oid::parse_hex(text).map_err(|_| malformed_for(object, field))?;
    if oid.kind() != kind {
        return Err(malformed_for(object, field));
    }
    Ok(oid)
}

fn is_signature_header(name: &[u8]) -> bool {
    name == b"gpgsig" || name.starts_with(b"gpgsig-")
}

fn malformed_for(oid: Oid, message: &str) -> Error {
    Error::new(ErrorCode::MalformedObject, message).with_oid(oid)
}

fn within_time_bounds(time: i64, opts: &LogOptions) -> bool {
    opts.since.is_none_or(|since| time >= since) && opts.until.is_none_or(|until| time <= until)
}

fn decode_resume(
    bytes: &[u8],
    expected: CursorExpected<'_>,
    hash_kind: crate::object::HashKind,
) -> Result<Oid, Error> {
    let decoded = cursor::decode(bytes, expected)?;
    if !decoded.generation.is_empty() {
        return Err(invalid_cursor(
            "generation check failed for this object store",
        ));
    }
    Oid::new(hash_kind, &decoded.position)
        .map_err(|_| invalid_cursor("position check failed: commit digest has the wrong length"))
}

fn option_fingerprint(opts: &LogOptions) -> u64 {
    let mut normalized = Vec::with_capacity(20);
    normalized.extend_from_slice(b"log-v1\0");
    normalized.push(match opts.order {
        LogOrder::Chronological => 0,
        LogOrder::Topological => 1,
        LogOrder::DateOrder => 2,
    });
    normalized.push(u8::from(opts.first_parent));
    push_optional_i64(&mut normalized, opts.since);
    push_optional_i64(&mut normalized, opts.until);
    cursor::fnv1a_64(&normalized)
}

fn push_optional_i64(out: &mut Vec<u8>, value: Option<i64>) {
    match value {
        Some(value) => {
            out.push(1);
            out.extend_from_slice(&value.to_le_bytes());
        }
        None => out.push(0),
    }
}

fn truncatable(error: &Error) -> bool {
    error.code == ErrorCode::BudgetExceeded
        && !matches!(
            error.limit,
            Some("max_provider_requests" | "max_provider_bytes")
        )
}

fn invalid_cursor(message: &'static str) -> Error {
    Error::new(ErrorCode::InvalidCursor, message)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::budget::BudgetLimits;
    use crate::local_odb::LocalOdb;
    use crate::object::{HashKind, ObjectHeader, ObjectKind};
    use crate::snapshot::{peel, PeelTarget};
    use crate::static_odb::StaticOdb;
    use crate::test_support::{fixture_oid, fixture_repo};
    use crate::verify::object_id;
    use std::process::Command;
    use std::sync::atomic::AtomicBool;
    use std::sync::Arc;

    struct GraphFixture {
        store: StaticOdb,
        snapshot: Snapshot,
        root: Oid,
        left: Oid,
        right: Oid,
        merge: Oid,
        tip: Oid,
    }

    fn commit(tree: Oid, parents: &[Oid], time: i64, message: &[u8]) -> (Oid, ObjectKind, Vec<u8>) {
        let mut payload = format!("tree {}\n", tree.to_hex()).into_bytes();
        for parent in parents {
            payload.extend_from_slice(format!("parent {}\n", parent.to_hex()).as_bytes());
        }
        payload.extend_from_slice(
            format!(
                "author raw-\u{ff} <author@example.invalid> {time} +0130\ncommitter Committer <committer@example.invalid> {time} -0230\n\n"
            )
            .as_bytes(),
        );
        payload.extend_from_slice(message);
        let oid =
            object_id(HashKind::Sha1, ObjectKind::Commit, &payload).expect("test commit hashes");
        (oid, ObjectKind::Commit, payload)
    }

    fn fixture() -> GraphFixture {
        let tree_payload = Vec::new();
        let tree =
            object_id(HashKind::Sha1, ObjectKind::Tree, &tree_payload).expect("empty tree hashes");
        let root_object = commit(tree, &[], 1, b"root\n");
        let root = root_object.0;
        let left_object = commit(tree, &[root], 2, b"left\n");
        let left = left_object.0;
        let right_object = commit(tree, &[root], 2, b"right\n");
        let right = right_object.0;
        let merge_object = commit(tree, &[left, right], 3, b"merge\n");
        let merge = merge_object.0;
        let tip_object = commit(tree, &[merge], 4, b"tip\n");
        let tip = tip_object.0;
        let store = StaticOdb::from_addressed_objects(
            HashKind::Sha1,
            std::iter::once((tree, ObjectKind::Tree, tree_payload)).chain([
                root_object,
                left_object,
                right_object,
                merge_object,
                tip_object,
            ]),
        )
        .expect("graph fixture loads");
        GraphFixture {
            store,
            snapshot: Snapshot {
                commit_oid: tip,
                tree_oid: tree,
            },
            root,
            left,
            right,
            merge,
            tip,
        }
    }

    #[test]
    fn all_orders_are_deterministic_and_first_parent_preserves_stored_order() {
        let graph = fixture();
        for order in [
            LogOrder::Chronological,
            LogOrder::Topological,
            LogOrder::DateOrder,
        ] {
            let page = log(
                &graph.store,
                &graph.snapshot,
                &LogOptions {
                    order,
                    ..LogOptions::default()
                },
                &Budget::unlimited(),
            )
            .expect("walk succeeds");
            assert_eq!(page.commits[0].id, graph.tip);
            assert_eq!(page.commits[1].id, graph.merge);
            let tied = [page.commits[2].id, page.commits[3].id];
            assert_eq!(
                tied,
                match order {
                    LogOrder::Topological => [graph.right, graph.left],
                    LogOrder::Chronological | LogOrder::DateOrder => {
                        [graph.left, graph.right]
                    }
                }
            );
            assert_eq!(page.commits[4].id, graph.root);
        }

        let page = log(
            &graph.store,
            &graph.snapshot,
            &LogOptions {
                first_parent: true,
                ..LogOptions::default()
            },
            &Budget::unlimited(),
        )
        .expect("first-parent walk succeeds");
        assert_eq!(
            page.commits
                .iter()
                .map(|commit| commit.id)
                .collect::<Vec<_>>(),
            [graph.tip, graph.merge, graph.left, graph.root]
        );
    }

    #[test]
    fn filters_and_cursor_pages_round_trip_and_bind_options() {
        let graph = fixture();
        let options = LogOptions {
            since: Some(2),
            until: Some(4),
            limit: 2,
            ..LogOptions::default()
        };
        let first = log(
            &graph.store,
            &graph.snapshot,
            &options,
            &Budget::unlimited(),
        )
        .expect("first page succeeds");
        assert!(first.truncated);
        assert_eq!(first.commits.len(), 2);
        let second = log(
            &graph.store,
            &graph.snapshot,
            &LogOptions {
                cursor: first.next_cursor.clone(),
                ..options.clone()
            },
            &Budget::unlimited(),
        )
        .expect("second page succeeds");
        assert_eq!(second.commits.len(), 2);
        assert!(!second.truncated);

        let error = log(
            &graph.store,
            &graph.snapshot,
            &LogOptions {
                first_parent: true,
                cursor: first.next_cursor,
                ..options
            },
            &Budget::unlimited(),
        )
        .expect_err("changed options invalidate a cursor");
        assert_eq!(error.code, ErrorCode::InvalidCursor);
    }

    #[test]
    fn dto_caps_messages_and_exposes_raw_headers_and_offsets() {
        let tree = object_id(HashKind::Sha1, ObjectKind::Tree, &[]).expect("tree hashes");
        let mut message = vec![b's'; SUBJECT_BYTES + 20];
        message.push(b'\n');
        message.extend(std::iter::repeat_n(b'm', MESSAGE_BYTES + 20));
        let mut payload = format!(
            "tree {}\nauthor raw-\u{ff} <mail@example.invalid> 1 +0130\ncommitter C <c@example.invalid> 2 -0230\nencoding ISO-8859-1\ngpgsig payload\n continuation\ngpgsig-sha256 other\n\n",
            tree.to_hex()
        )
        .into_bytes();
        payload.extend_from_slice(&message);
        let id = object_id(HashKind::Sha1, ObjectKind::Commit, &payload).expect("commit hashes");
        let commit = decode_log_commit(id, &payload, false).expect("DTO decodes");
        assert_eq!(commit.subject.len(), SUBJECT_BYTES);
        assert!(commit.subject_truncated);
        assert_eq!(commit.message_raw.len(), MESSAGE_BYTES);
        assert!(commit.message_truncated);
        assert_eq!(commit.author.name, "raw-\u{ff}".as_bytes());
        assert_eq!(commit.author.tz_offset_minutes, Some(90));
        assert_eq!(commit.committer.tz_offset_minutes, Some(-150));
        assert_eq!(
            commit.signature_headers,
            [b"gpgsig".to_vec(), b"gpgsig-sha256".to_vec()]
        );
        assert_eq!(commit.encoding, Some(b"ISO-8859-1".to_vec()));
    }

    #[test]
    fn malformed_timezones_are_tolerated_and_negative_zero_is_numeric_zero() {
        let tree = object_id(HashKind::Sha1, ObjectKind::Tree, &[]).expect("tree hashes");
        for (timezone, expected) in [
            ("+0099", None),
            ("0000", None),
            ("+051800", None),
            ("-0000", Some(0)),
        ] {
            let payload = format!(
                "tree {}\nauthor A <a@example.invalid> 1 {timezone}\ncommitter C <c@example.invalid> 2 {timezone}\n\nmessage\n",
                tree.to_hex()
            )
            .into_bytes();
            let id = object_id(HashKind::Sha1, ObjectKind::Commit, &payload)
                .expect("timezone probe commit hashes");
            let commit = decode_log_commit(id, &payload, false).expect("timezone is tolerated");
            assert_eq!(commit.author.tz, timezone.as_bytes());
            assert_eq!(commit.author.tz_offset_minutes, expected);
            assert_eq!(commit.committer.tz_offset_minutes, expected);
        }
    }

    #[test]
    fn decode_failures_name_the_commit_and_payload_reads_are_bounded_to_metadata_plus_dto() {
        let tree = object_id(HashKind::Sha1, ObjectKind::Tree, &[]).expect("tree hashes");
        let malformed_payload = format!(
            "tree {}\nauthor malformed 1 +0000\ncommitter C <c@example.invalid> 2 +0000\n\nmessage\n",
            tree.to_hex()
        )
        .into_bytes();
        let malformed_id = object_id(HashKind::Sha1, ObjectKind::Commit, &malformed_payload)
            .expect("malformed probe hashes");
        let malformed_store = StaticOdb::from_addressed_objects(
            HashKind::Sha1,
            [(malformed_id, ObjectKind::Commit, malformed_payload)],
        )
        .expect("hostile addressed store loads");
        let error = log(
            &malformed_store,
            &Snapshot {
                commit_oid: malformed_id,
                tree_oid: tree,
            },
            &LogOptions::default(),
            &Budget::unlimited(),
        )
        .expect_err("malformed emitted DTO fails");
        assert_eq!(error.code, ErrorCode::MalformedObject);
        assert_eq!(error.object_oid, Some(malformed_id));

        let root_object = commit(tree, &[], 3, b"root\n");
        let root = root_object.0;
        let payload_bytes = root_object.2.len() as u64;
        let store = StaticOdb::from_addressed_objects(HashKind::Sha1, [root_object])
            .expect("single commit store loads");
        let page = log(
            &store,
            &Snapshot {
                commit_oid: root,
                tree_oid: tree,
            },
            &LogOptions::default(),
            &Budget::unlimited(),
        )
        .expect("single commit log succeeds");
        assert_eq!(page.stats.objects_read, 1);
        assert_eq!(page.stats.bytes_read, payload_bytes);
    }

    #[test]
    fn missing_parent_and_cancellation_are_normalized() {
        let tree = object_id(HashKind::Sha1, ObjectKind::Tree, &[]).expect("tree hashes");
        let missing = Oid::new(HashKind::Sha1, &[9; 20]).expect("missing ID is valid");
        let tip_object = commit(tree, &[missing], 2, b"hole\n");
        let tip = tip_object.0;
        let store = StaticOdb::from_addressed_objects(HashKind::Sha1, [tip_object])
            .expect("hole-punched store loads");
        let snapshot = Snapshot {
            commit_oid: tip,
            tree_oid: tree,
        };
        let error = log(
            &store,
            &snapshot,
            &LogOptions::default(),
            &Budget::unlimited(),
        )
        .expect_err("missing parent fails");
        assert_eq!(error.code, ErrorCode::MissingObject);
        assert!(error.message.contains(&missing.to_hex()));
        assert_eq!(error.object_oid, Some(missing));

        let budget = Budget::unlimited();
        budget
            .cancel_flag()
            .store(true, std::sync::atomic::Ordering::Release);
        assert_eq!(
            log(&store, &snapshot, &LogOptions::default(), &budget)
                .expect_err("cancelled walk fails")
                .code,
            ErrorCode::Cancelled
        );
    }

    #[test]
    fn max_objects_is_a_truncated_page_after_progress() {
        let graph = fixture();
        let budget = Budget::new(
            BudgetLimits {
                max_objects: 3,
                ..BudgetLimits::default()
            },
            None,
            Arc::new(AtomicBool::new(false)),
        );
        let page = log(
            &graph.store,
            &graph.snapshot,
            &LogOptions::default(),
            &budget,
        )
        .expect("object limit truncates after progress");
        assert!(page.truncated);
        assert_eq!(page.stats.stopped_by, Some("max_objects"));
        assert!(page.next_cursor.is_some());
    }

    #[test]
    fn generated_fixtures_match_git_for_every_log_mode_and_time_filter() {
        for (repository_name, head_name) in [
            ("sha1-graph.git", "sha1_graph_head"),
            ("sha1-history.git", "sha1_history_head"),
            ("sha1-history-shallow.git", "sha1_history_head"),
            ("sha1-basic.git", "sha1_basic_head"),
        ] {
            let repository = fixture_repo(repository_name);
            let (store, _) =
                LocalOdb::open(&repository, Default::default()).expect("fixture repository opens");
            let snapshot = Snapshot::open(&store, fixture_oid(head_name), &Budget::unlimited())
                .expect("fixture snapshot opens");

            for (order, git_flag) in [
                (LogOrder::Chronological, None),
                (LogOrder::Topological, Some("--topo-order")),
                (LogOrder::DateOrder, Some("--date-order")),
            ] {
                let mut arguments = vec!["rev-list"];
                arguments.extend(git_flag);
                arguments.push("main");
                assert_eq!(
                    log(
                        &store,
                        &snapshot,
                        &LogOptions {
                            order,
                            ..LogOptions::default()
                        },
                        &Budget::unlimited(),
                    )
                    .expect("core log succeeds")
                    .commits
                    .into_iter()
                    .map(|commit| commit.id.to_hex())
                    .collect::<Vec<_>>(),
                    git_oids(&repository, &arguments),
                    "{repository_name} {order:?}"
                );
            }

            assert_eq!(
                log(
                    &store,
                    &snapshot,
                    &LogOptions {
                        first_parent: true,
                        ..LogOptions::default()
                    },
                    &Budget::unlimited(),
                )
                .expect("first-parent core log succeeds")
                .commits
                .into_iter()
                .map(|commit| commit.id.to_hex())
                .collect::<Vec<_>>(),
                git_oids(&repository, &["rev-list", "--first-parent", "main"]),
                "{repository_name} first-parent"
            );
        }

        for (repository_name, head_key, since, until) in [
            (
                "sha1-graph.git",
                "sha1_graph_head",
                988_761_700,
                988_761_760,
            ),
            (
                "sha1-history.git",
                "sha1_history_head",
                980_985_720,
                980_986_200,
            ),
            (
                "sha1-basic.git",
                "sha1_basic_head",
                978_307_260,
                978_307_260,
            ),
        ] {
            let repository = fixture_repo(repository_name);
            let (store, _) =
                LocalOdb::open(&repository, Default::default()).expect("fixture opens");
            let snapshot = Snapshot::open(&store, fixture_oid(head_key), &Budget::unlimited())
                .expect("fixture snapshot opens");
            let since_arg = format!("--since=@{since}");
            let until_arg = format!("--until=@{until}");
            assert_eq!(
                log(
                    &store,
                    &snapshot,
                    &LogOptions {
                        since: Some(since),
                        until: Some(until),
                        ..LogOptions::default()
                    },
                    &Budget::unlimited(),
                )
                .expect("bounded core log succeeds")
                .commits
                .into_iter()
                .map(|commit| commit.id.to_hex())
                .collect::<Vec<_>>(),
                git_oids(&repository, &["rev-list", &since_arg, &until_arg, "main"],),
                "{repository_name} since/until"
            );
        }
    }

    #[test]
    fn equal_time_skew_shallow_and_annotated_tag_shapes_match_git() {
        let graph_repo = fixture_repo("sha1-graph.git");
        let (graph_store, _) =
            LocalOdb::open(&graph_repo, Default::default()).expect("graph fixture opens");
        let equal_tip = fixture_oid("sha1_graph_equal_merge");
        let equal_snapshot =
            Snapshot::open(&graph_store, equal_tip, &Budget::unlimited()).expect("snapshot opens");
        for (order, flag) in [
            (LogOrder::Chronological, None),
            (LogOrder::Topological, Some("--topo-order")),
            (LogOrder::DateOrder, Some("--date-order")),
        ] {
            let mut arguments = vec!["rev-list"];
            arguments.extend(flag);
            arguments.push("fixture/equal-merge");
            let expected = git_oids(&graph_repo, &arguments);
            let page = log(
                &graph_store,
                &equal_snapshot,
                &LogOptions {
                    order,
                    ..LogOptions::default()
                },
                &Budget::unlimited(),
            )
            .expect("equal-time walk succeeds");
            assert_eq!(
                page.commits
                    .iter()
                    .map(|commit| commit.id.to_hex())
                    .collect::<Vec<_>>(),
                expected,
                "equal-time {order:?}"
            );

            let mut cursor = None;
            let mut paged = Vec::new();
            loop {
                let page = log(
                    &graph_store,
                    &equal_snapshot,
                    &LogOptions {
                        order,
                        limit: 3,
                        cursor,
                        ..LogOptions::default()
                    },
                    &Budget::unlimited(),
                )
                .expect("equal-time cursor page succeeds");
                paged.extend(page.commits.into_iter().map(|commit| commit.id.to_hex()));
                cursor = page.next_cursor;
                if cursor.is_none() {
                    break;
                }
            }
            assert_eq!(paged, expected, "equal-time paged {order:?}");
        }

        let main_snapshot = Snapshot::open(
            &graph_store,
            fixture_oid("sha1_graph_head"),
            &Budget::unlimited(),
        )
        .expect("main snapshot opens");
        for (order, flag) in [
            (LogOrder::Chronological, None),
            (LogOrder::Topological, Some("--topo-order")),
            (LogOrder::DateOrder, Some("--date-order")),
        ] {
            for (since, until) in [(Some(988_675_800), None), (None, Some(988_675_800))] {
                let mut owned_arguments = vec!["rev-list".to_owned()];
                owned_arguments.extend(flag.map(str::to_owned));
                owned_arguments.extend(since.map(|value| format!("--since=@{value}")));
                owned_arguments.extend(until.map(|value| format!("--until=@{value}")));
                owned_arguments.push("main".to_owned());
                let arguments = owned_arguments
                    .iter()
                    .map(String::as_str)
                    .collect::<Vec<_>>();
                assert_eq!(
                    log(
                        &graph_store,
                        &main_snapshot,
                        &LogOptions {
                            order,
                            since,
                            until,
                            ..LogOptions::default()
                        },
                        &Budget::unlimited(),
                    )
                    .expect("skew time-bound walk succeeds")
                    .commits
                    .into_iter()
                    .map(|commit| commit.id.to_hex())
                    .collect::<Vec<_>>(),
                    git_oids(&graph_repo, &arguments),
                    "skew {order:?} since={since:?} until={until:?}"
                );
            }

            let empty = log(
                &graph_store,
                &main_snapshot,
                &LogOptions {
                    order,
                    since: Some(2_000_000_000),
                    ..LogOptions::default()
                },
                &Budget::unlimited(),
            )
            .expect("narrow empty window succeeds");
            assert!(empty.commits.is_empty());
            assert!(!empty.truncated);
            assert!(empty.next_cursor.is_none());
        }

        let shallow_repo = fixture_repo("sha1-history-shallow.git");
        let (shallow_store, _) =
            LocalOdb::open(&shallow_repo, Default::default()).expect("shallow fixture opens");
        let shallow_snapshot = Snapshot::open(
            &shallow_store,
            fixture_oid("sha1_history_head"),
            &Budget::unlimited(),
        )
        .expect("shallow snapshot opens");
        let shallow = log(
            &shallow_store,
            &shallow_snapshot,
            &LogOptions::default(),
            &Budget::unlimited(),
        )
        .expect("shallow walk succeeds");
        assert_eq!(shallow.commits.len(), 8);
        assert_eq!(
            shallow
                .commits
                .into_iter()
                .map(|commit| commit.id.to_hex())
                .collect::<Vec<_>>(),
            git_oids(&shallow_repo, &["rev-list", "main"])
        );

        let tag = fixture_oid("sha1_graph_octopus_tag");
        let octopus = peel(&graph_store, tag, PeelTarget::Commit, &Budget::unlimited())
            .expect("annotated octopus tag peels");
        let tagged_snapshot = Snapshot::open(&graph_store, octopus, &Budget::unlimited())
            .expect("tag snapshot opens");
        assert_eq!(
            log(
                &graph_store,
                &tagged_snapshot,
                &LogOptions::default(),
                &Budget::unlimited(),
            )
            .expect("peeled tag log succeeds")
            .commits[0]
                .id,
            fixture_oid("sha1_graph_octopus")
        );
    }

    #[test]
    fn cursor_prefixes_do_not_recharge_object_visits_and_ordered_refusals_are_actionable() {
        let repository = fixture_repo("sha1-graph.git");
        let (store, _) =
            LocalOdb::open(&repository, Default::default()).expect("graph fixture opens");
        let snapshot = Snapshot::open(&store, fixture_oid("sha1_graph_head"), &Budget::unlimited())
            .expect("snapshot opens");
        let expected = git_oids(&repository, &["rev-list", "main"]);
        assert_eq!(expected.len(), 231);

        for order in [
            LogOrder::Chronological,
            LogOrder::Topological,
            LogOrder::DateOrder,
        ] {
            let max_objects = if order == LogOrder::Chronological {
                60
            } else {
                231
            };
            let mut cursor = None;
            let mut actual = Vec::new();
            let mut page_sizes = Vec::new();
            loop {
                let budget = Budget::new(
                    BudgetLimits {
                        max_objects,
                        ..BudgetLimits::default()
                    },
                    None,
                    Arc::new(AtomicBool::new(false)),
                );
                let page = log(
                    &store,
                    &snapshot,
                    &LogOptions {
                        order,
                        limit: 60,
                        cursor,
                        ..LogOptions::default()
                    },
                    &budget,
                )
                .expect("constant-budget page succeeds");
                page_sizes.push(page.commits.len());
                actual.extend(page.commits.into_iter().map(|commit| commit.id.to_hex()));
                cursor = page.next_cursor;
                if cursor.is_none() {
                    break;
                }
            }
            assert_eq!(page_sizes, [60, 60, 60, 51], "{order:?}");
            assert_eq!(actual, expected, "{order:?}");
        }

        let fresh_budget = Budget::new(
            BudgetLimits {
                max_objects: 60,
                ..BudgetLimits::default()
            },
            None,
            Arc::new(AtomicBool::new(false)),
        );
        let fresh = log(&store, &snapshot, &LogOptions::default(), &fresh_budget)
            .expect("fresh chronological call truncates");
        assert_eq!(fresh.commits.len(), 60);
        assert!(fresh.truncated);
        assert_eq!(fresh.stats.stopped_by, Some("max_objects"));

        for order in [LogOrder::Topological, LogOrder::DateOrder] {
            let budget = Budget::new(
                BudgetLimits {
                    max_objects: 230,
                    ..BudgetLimits::default()
                },
                None,
                Arc::new(AtomicBool::new(false)),
            );
            let error = log(
                &store,
                &snapshot,
                &LogOptions {
                    order,
                    ..LogOptions::default()
                },
                &budget,
            )
            .expect_err("ordered pre-pass refuses an undersized object limit");
            assert_eq!(error.code, ErrorCode::BudgetExceeded);
            assert_eq!(error.limit, Some("max_objects"));
            let expected_order = match order {
                LogOrder::Topological => "topological",
                LogOrder::DateOrder => "date",
                LogOrder::Chronological => unreachable!(),
            };
            assert_eq!(error.order.map(ErrorOrder::as_str), Some(expected_order));
            assert!(error.message.contains("reachable commit count"));
        }
    }

    struct CyclicStore {
        objects: HashMap<Oid, Vec<u8>>,
    }

    impl ObjectDb for CyclicStore {
        fn hash_kind(&self) -> HashKind {
            HashKind::Sha1
        }

        fn try_header(&self, oid: &Oid, budget: &Budget) -> Result<Option<ObjectHeader>, Error> {
            budget.charge_header()?;
            Ok(self.objects.get(oid).map(|payload| ObjectHeader {
                kind: ObjectKind::Commit,
                size: payload.len() as u64,
            }))
        }

        fn try_find(
            &self,
            oid: &Oid,
            out: &mut Vec<u8>,
            budget: &Budget,
        ) -> Result<Option<ObjectKind>, Error> {
            out.clear();
            let Some(payload) = self.objects.get(oid) else {
                return Ok(None);
            };
            budget.charge_object(payload.len() as u64)?;
            out.extend_from_slice(payload);
            Ok(Some(ObjectKind::Commit))
        }
    }

    #[test]
    fn cyclic_lying_store_emits_ordered_residue_instead_of_dropping_it() {
        let tree = object_id(HashKind::Sha1, ObjectKind::Tree, &[]).expect("tree hashes");
        let first = Oid::new(HashKind::Sha1, &[1; 20]).expect("OID is valid");
        let second = Oid::new(HashKind::Sha1, &[2; 20]).expect("OID is valid");
        let payload = |parent: Oid, time| {
            format!(
                "tree {}\nparent {}\nauthor A <a@example.invalid> {time} +0000\ncommitter C <c@example.invalid> {time} +0000\n\ncycle\n",
                tree.to_hex(),
                parent.to_hex()
            )
            .into_bytes()
        };
        let store = CyclicStore {
            objects: HashMap::from([(first, payload(second, 2)), (second, payload(first, 1))]),
        };
        for order in [LogOrder::Topological, LogOrder::DateOrder] {
            let page = log(
                &store,
                &Snapshot {
                    commit_oid: first,
                    tree_oid: tree,
                },
                &LogOptions {
                    order,
                    ..LogOptions::default()
                },
                &Budget::unlimited(),
            )
            .expect("cyclic residue is still emitted");
            assert_eq!(
                page.commits
                    .into_iter()
                    .map(|commit| commit.id)
                    .collect::<Vec<_>>(),
                [second, first]
            );
        }
    }

    fn git_oids(repository: &std::path::Path, arguments: &[&str]) -> Vec<String> {
        let output = Command::new("git")
            .args(["-c", "color.ui=false", "-C"])
            .arg(repository)
            .args(arguments)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_SYSTEM", "/dev/null")
            .env("LC_ALL", "C")
            .output()
            .expect("canonical Git runs");
        assert!(output.status.success(), "canonical Git log succeeds");
        String::from_utf8(output.stdout)
            .expect("Git object IDs are ASCII")
            .lines()
            .map(str::to_owned)
            .collect()
    }
}
