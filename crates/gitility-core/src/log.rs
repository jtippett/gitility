//! Deterministic, budgeted commit-log traversal and pagination.
//!
//! Cursor resume deliberately replays the walk from the snapshot commit and
//! skips through the recorded position, so its cost is O(prefix).

use crate::budget::Budget;
use crate::commit_graph::{from_gix_oid, to_gix_oid, GixFind};
use crate::cursor::{self, Cursor, CursorExpected, OPERATION_LOG};
use crate::decode::{decode_commit, Identity};
use crate::error::{Error, ErrorCode};
use crate::object::Oid;
use crate::odb::ObjectDb;
use crate::snapshot::Snapshot;
use crate::tree::QueryStats;
use gix_traverse::commit::{simple, topo, Info, Parents, Simple};
use std::collections::{BinaryHeap, HashMap, VecDeque};

const MAX_CURSOR_BYTES: usize = 4096;
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
    /// Parsed UTC offset in minutes. Both `+0000` and `-0000` map to zero.
    pub tz_offset_minutes: i32,
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

    let reader = GixFind::new(store, budget);
    reader.validate_commit(snapshot.commit_oid)?;
    let mut walk = StableWalk::new(snapshot.commit_oid, opts, reader.clone())?;
    let mut found_resume = resume.is_none();
    let mut commits = Vec::with_capacity(opts.limit.min(1_024));
    let mut stopped_by = None;

    loop {
        budget.check()?;
        let id = match walk.next() {
            Some(Ok(id)) => id,
            Some(Err(error)) if truncatable(&error) && !commits.is_empty() => {
                stopped_by = Some(error.limit.unwrap_or("budget"));
                break;
            }
            Some(Err(error)) => return Err(error),
            None => break,
        };

        if !found_resume {
            if Some(id) == resume {
                found_resume = true;
            }
            continue;
        }

        let decoded = decode_log_commit(id, &reader.commit_payload(id)?)?;
        if !within_time_bounds(decoded.committer.time, opts) {
            continue;
        }
        if commits.len() == opts.limit {
            stopped_by = Some("limit");
            break;
        }
        commits.push(decoded);
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
            stopped_by,
        },
    })
}

type RawWalk<'a> = Box<dyn Iterator<Item = Result<Info, Error>> + 'a>;

struct StableWalk<'a> {
    raw: RawWalk<'a>,
    reader: GixFind<'a>,
    pending: Option<(Info, i64)>,
    pending_error: Option<Error>,
    ready: VecDeque<Info>,
}

impl<'a> StableWalk<'a> {
    fn new(start: Oid, opts: &LogOptions, reader: GixFind<'a>) -> Result<Self, Error> {
        let start = to_gix_oid(start)?;
        let parents = if opts.first_parent {
            Parents::First
        } else {
            Parents::All
        };
        let errors = reader.clone();
        let raw: RawWalk<'a> = match opts.order {
            LogOrder::Chronological => {
                let walk = Simple::new([start], reader.clone())
                    .sorting(simple::Sorting::ByCommitTime(
                        simple::CommitTimeOrder::NewestFirst,
                    ))
                    .map_err(|_| {
                        errors.error_or(
                            ErrorCode::MalformedObject,
                            "commit traversal could not decode a commit",
                        )
                    })?
                    .parents(parents);
                let errors = errors.clone();
                Box::new(walk.map(move |item| {
                    item.map_err(|_| {
                        errors.error_or(
                            ErrorCode::MalformedObject,
                            "commit traversal could not decode a commit",
                        )
                    })
                }))
            }
            LogOrder::Topological | LogOrder::DateOrder => {
                let sorting = match opts.order {
                    LogOrder::Topological => topo::Sorting::TopoOrder,
                    LogOrder::DateOrder => topo::Sorting::DateOrder,
                    LogOrder::Chronological => unreachable!("matched above"),
                };
                let walk = topo::Builder::from_iters(
                    reader.clone(),
                    [start],
                    None::<[gix_hash::ObjectId; 0]>,
                )
                .sorting(sorting)
                .parents(parents)
                .build()
                .map_err(|_| {
                    errors.error_or(
                        ErrorCode::MalformedObject,
                        "topological traversal could not decode a commit",
                    )
                })?;
                let errors = errors.clone();
                Box::new(walk.map(move |item| {
                    item.map_err(|_| {
                        errors.error_or(
                            ErrorCode::MalformedObject,
                            "topological traversal could not decode a commit",
                        )
                    })
                }))
            }
        };
        Ok(Self {
            raw,
            reader,
            pending: None,
            pending_error: None,
            ready: VecDeque::new(),
        })
    }

    fn next(&mut self) -> Option<Result<Oid, Error>> {
        if let Some(info) = self.ready.pop_front() {
            return Some(from_gix_oid(info.id.as_ref()));
        }
        if let Some(error) = self.pending_error.take() {
            return Some(Err(error));
        }

        let (first, time) = match self.pending.take() {
            Some(value) => value,
            None => match self.next_timed()? {
                Ok(value) => value,
                Err(error) => return Some(Err(error)),
            },
        };
        let mut group = vec![first];
        loop {
            match self.next_timed() {
                Some(Ok((info, next_time))) if next_time == time => group.push(info),
                Some(Ok(value)) => {
                    self.pending = Some(value);
                    break;
                }
                Some(Err(error)) => {
                    self.pending_error = Some(error);
                    break;
                }
                None => break,
            }
        }
        self.ready = stable_topological_tie_order(group);
        self.ready
            .pop_front()
            .map(|info| from_gix_oid(info.id.as_ref()))
    }

    fn next_timed(&mut self) -> Option<Result<(Info, i64), Error>> {
        self.raw.next().map(|item| {
            let info = item?;
            let id = from_gix_oid(info.id.as_ref())?;
            let payload = self.reader.commit_payload(id)?;
            let time = decode_commit(&payload, id.kind())?.committer.time;
            Ok((info, time))
        })
    }
}

fn stable_topological_tie_order(group: Vec<Info>) -> VecDeque<Info> {
    if group.len() < 2 {
        return group.into();
    }

    let mut by_id = group
        .into_iter()
        .map(|info| (info.id, info))
        .collect::<HashMap<_, _>>();
    let mut child_count = by_id
        .keys()
        .copied()
        .map(|id| (id, 0usize))
        .collect::<HashMap<_, _>>();
    for info in by_id.values() {
        for parent in &info.parent_ids {
            if let Some(count) = child_count.get_mut(parent) {
                *count += 1;
            }
        }
    }
    let mut ready = child_count
        .iter()
        .filter_map(|(id, count)| (*count == 0).then_some(*id))
        .collect::<BinaryHeap<_>>();
    let mut ordered = VecDeque::with_capacity(by_id.len());
    while let Some(id) = ready.pop() {
        let info = by_id
            .remove(&id)
            .expect("ready IDs originate in the equal-time group");
        for parent in &info.parent_ids {
            if let Some(count) = child_count.get_mut(parent) {
                *count -= 1;
                if *count == 0 {
                    ready.push(*parent);
                }
            }
        }
        ordered.push_back(info);
    }
    debug_assert!(
        by_id.is_empty(),
        "commit parent links cannot contain cycles"
    );
    ordered
}

fn decode_log_commit(id: Oid, payload: &[u8]) -> Result<LogCommit, Error> {
    let decoded = decode_commit(payload, id.kind())?;
    let message_len = decoded.message.len().min(MESSAGE_BYTES);
    let subject_end = decoded
        .message
        .iter()
        .position(|byte| *byte == b'\n')
        .unwrap_or(decoded.message.len())
        .min(SUBJECT_BYTES);
    let encoding = decoded
        .extra_headers
        .iter()
        .find_map(|(name, value)| (name.as_slice() == b"encoding").then(|| value.clone()));
    Ok(LogCommit {
        id,
        parents: decoded.parents,
        tree_id: decoded.tree_oid,
        author: log_identity(decoded.author)?,
        committer: log_identity(decoded.committer)?,
        subject: decoded.message[..subject_end].to_vec(),
        message_raw: decoded.message[..message_len].to_vec(),
        message_truncated: decoded.message.len() > MESSAGE_BYTES,
        signature_headers: decoded
            .signature_headers
            .into_iter()
            .map(|(name, _payload)| name)
            .collect(),
        encoding,
    })
}

fn log_identity(identity: Identity) -> Result<LogIdentity, Error> {
    let tz_offset_minutes = timezone_offset_minutes(&identity.tz)?;
    Ok(LogIdentity {
        name: identity.name,
        email: identity.email,
        time: identity.time,
        tz: identity.tz,
        tz_offset_minutes,
    })
}

fn timezone_offset_minutes(tz: &[u8]) -> Result<i32, Error> {
    let [sign @ (b'+' | b'-'), h1, h2, m1, m2] = tz else {
        return Err(Error::new(
            ErrorCode::MalformedObject,
            "commit identity timezone is malformed",
        ));
    };
    if ![h1, h2, m1, m2]
        .into_iter()
        .all(|digit| digit.is_ascii_digit())
    {
        return Err(Error::new(
            ErrorCode::MalformedObject,
            "commit identity timezone is malformed",
        ));
    }
    let hours = i32::from(h1 - b'0') * 10 + i32::from(h2 - b'0');
    let minutes = i32::from(m1 - b'0') * 10 + i32::from(m2 - b'0');
    if minutes >= 60 {
        return Err(Error::new(
            ErrorCode::MalformedObject,
            "commit identity timezone has invalid minutes",
        ));
    }
    let offset = hours * 60 + minutes;
    Ok(if *sign == b'-' { -offset } else { offset })
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
    use crate::object::{HashKind, ObjectKind};
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
                if graph.left > graph.right {
                    [graph.left, graph.right]
                } else {
                    [graph.right, graph.left]
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
        let commit = decode_log_commit(id, &payload).expect("DTO decodes");
        assert_eq!(commit.subject.len(), SUBJECT_BYTES);
        assert_eq!(commit.message_raw.len(), MESSAGE_BYTES);
        assert!(commit.message_truncated);
        assert_eq!(commit.author.name, "raw-\u{ff}".as_bytes());
        assert_eq!(commit.author.tz_offset_minutes, 90);
        assert_eq!(commit.committer.tz_offset_minutes, -150);
        assert_eq!(
            commit.signature_headers,
            [b"gpgsig".to_vec(), b"gpgsig-sha256".to_vec()]
        );
        assert_eq!(commit.encoding, Some(b"ISO-8859-1".to_vec()));
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
