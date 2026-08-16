//! Line attribution backed by gix-blame 0.16.0.
//!
//! Blame is deliberately all-or-error: timeout, cancellation, and every
//! resource ceiling discard the incomplete result. Callers can reduce work by
//! selecting a line range; blame never exposes a continuation cursor.

use crate::budget::Budget;
use crate::commit_graph::{from_gix_oid, to_gix_oid};
use crate::error::{Error, ErrorCode};
use crate::log::{decode_log_commit, LogIdentity};
use crate::object::{HashKind, ObjectKind, Oid};
use crate::odb::ObjectDb;
use crate::snapshot::Snapshot;
use crate::tree::{ensure_query_compatible, resolve_path, QueryStats, ResolvedPath, TreeItemKind};
use bstr::ByteSlice;
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

const BUDGET_CHECK_BYTES: usize = 64 * 1_024;

/// Options for [`blame`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BlameOptions {
    /// One 1-based inclusive range.
    pub lines: Option<(u32, u32)>,
    /// Enable gix-diff rewrite tracking at its 50% similarity threshold.
    pub follow_renames: bool,
}

impl Default for BlameOptions {
    fn default() -> Self {
        Self {
            lines: None,
            follow_renames: true,
        }
    }
}

/// One consecutive line-attribution hunk.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlameHunk {
    pub final_start: u32,
    pub final_end: u32,
    pub original_start: u32,
    pub original_end: u32,
    pub commit_id: Oid,
    pub original_path: Vec<u8>,
    pub author: LogIdentity,
    pub committer: LogIdentity,
    /// Raw commit subject bytes, capped at 1 KiB by the M3a decoder.
    pub summary: Vec<u8>,
    pub boundary: bool,
}

/// A complete blame result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Blame {
    pub path: Vec<u8>,
    pub hunks: Vec<BlameHunk>,
    pub stats: QueryStats,
}

/// Attribute the selected lines of `path` to commits reachable from snapshot.
pub fn blame(
    store: &dyn ObjectDb,
    snapshot: &Snapshot,
    path: &[u8],
    opts: &BlameOptions,
    budget: &Budget,
) -> Result<Blame, Error> {
    ensure_query_compatible(store, snapshot)?;
    budget.check()?;
    let resolved = resolve_path(store, snapshot, path, budget)?;
    let entry = match resolved {
        ResolvedPath::RootTree(_) => {
            return Err(kind_error("tree"));
        }
        ResolvedPath::Entry(entry) if entry.kind != TreeItemKind::Blob => {
            return Err(kind_error(match entry.kind {
                TreeItemKind::Tree => "tree",
                TreeItemKind::Symlink => "symlink",
                TreeItemKind::Gitlink => "gitlink",
                TreeItemKind::Blob => unreachable!("blob was excluded by the guard"),
            }));
        }
        ResolvedPath::Entry(entry) => entry,
    };

    // The blamed image is a mandatory subject, not a skippable candidate.
    let header = store
        .try_header(&entry.oid, budget)?
        .ok_or_else(|| missing(entry.oid, "blamed blob header"))?;
    if header.kind != ObjectKind::Blob {
        return Err(Error::new(
            ErrorCode::MalformedObject,
            "blamed tree entry addresses a non-blob object",
        )
        .with_oid(entry.oid));
    }
    if header.size > budget.limits().max_object_bytes {
        return Err(Error::new(
            ErrorCode::ObjectTooLarge,
            format!(
                "blamed file is {} bytes and exceeds max_object_bytes {}",
                header.size,
                budget.limits().max_object_bytes
            ),
        )
        .with_limit("max_object_bytes")
        .with_oid(entry.oid));
    }
    let mut head_blob = Vec::new();
    // The header lookup already charged the mandatory blob visit. Inflate it
    // without charging the same object a second time.
    let kind = budget
        .without_object_charge(entry.oid, || {
            store.try_find(&entry.oid, &mut head_blob, budget)
        })?
        .ok_or_else(|| missing(entry.oid, "blamed blob"))?;
    if kind != ObjectKind::Blob {
        return Err(Error::new(
            ErrorCode::MalformedObject,
            "blamed tree entry addresses a non-blob object",
        )
        .with_oid(entry.oid));
    }
    check_bytes(&head_blob, budget)?;
    let line_count = line_count(&head_blob)?;
    validate_range(opts.lines, line_count)?;

    let adapter = BlameObjectStore::new(store, budget, entry.oid, head_blob);
    let ranges = match opts.lines {
        Some((start, end)) => gix_blame::BlameRanges::from_one_based_inclusive_range(start..=end)
            .map_err(|_| range_error(line_count))?,
        None => gix_blame::BlameRanges::WholeFile,
    };
    let rewrites = opts.follow_renames.then(gix_diff::Rewrites::default);
    let mut platform = rewrite_platform(budget.limits().max_object_bytes);
    let result = gix_blame::file(
        adapter.clone(),
        to_gix_oid(snapshot.commit_oid)?,
        None,
        &mut platform,
        path.as_bstr(),
        gix_blame::Options {
            diff_algorithm: gix_diff::blob::Algorithm::Histogram,
            ranges,
            since: None,
            rewrites,
            debug_track_path: false,
        },
    );
    budget.check()?;
    let outcome = match result {
        Ok(outcome) => outcome,
        Err(_error) => {
            return Err(adapter.take_error().unwrap_or_else(|| {
                Error::new(
                    ErrorCode::MalformedObject,
                    "blame traversal failed on malformed repository data",
                )
            }));
        }
    };

    let mut metadata = HashMap::new();
    let mut hunks = Vec::with_capacity(outcome.entries.len());
    for blame_entry in outcome.entries {
        budget.check()?;
        let commit_id = from_gix_oid(blame_entry.commit_id.as_ref())?;
        if let std::collections::hash_map::Entry::Vacant(entry) = metadata.entry(commit_id) {
            let payload = adapter.commit_payload(commit_id)?;
            let shallow = store
                .shallow_roots()
                .is_some_and(|roots| roots.contains(&commit_id));
            entry.insert(decode_log_commit(commit_id, &payload, shallow)?);
        }
        let commit = &metadata[&commit_id];
        let length = blame_entry.len.get();
        let final_start = blame_entry.start_in_blamed_file.saturating_add(1);
        let original_start = blame_entry.start_in_source_file.saturating_add(1);
        hunks.push(BlameHunk {
            final_start,
            final_end: final_start.saturating_add(length).saturating_sub(1),
            original_start,
            original_end: original_start.saturating_add(length).saturating_sub(1),
            commit_id,
            original_path: blame_entry
                .source_file_name
                .map_or_else(|| path.to_vec(), |name| name.into()),
            author: commit.author.clone(),
            committer: commit.committer.clone(),
            summary: commit.subject.clone(),
            boundary: commit.parents.is_empty(),
        });
    }
    budget.check()?;

    let (objects_read, bytes_read, _, _) = budget.spent();
    let (cache_hits, cache_misses) = budget.cache_spent();
    let cache = store.cache_stats();
    Ok(Blame {
        path: path.to_vec(),
        stats: QueryStats {
            objects_read,
            bytes_read,
            entries_emitted: hunks.len() as u64,
            cache_hits,
            cache_misses,
            cache_bytes: cache.bytes,
            cache_entries: cache.entries,
            cache_evictions: cache.evictions,
            files_scanned: 1,
            blobs_deduped: 0,
            binary_skipped: 0,
            oversize_skipped: 0,
            payload_rereads: 0,
            stopped_by: None,
        },
        hunks,
    })
}

fn kind_error(kind: &str) -> Error {
    Error::new(
        ErrorCode::InvalidArgument,
        format!("blame path resolves to {kind}, not a blob"),
    )
    .with_reason(format!("path_kind:{kind}"))
}

fn validate_range(range: Option<(u32, u32)>, line_count: u32) -> Result<(), Error> {
    let Some((start, end)) = range else {
        return Ok(());
    };
    if start == 0 || end == 0 || start > end || end > line_count {
        return Err(range_error(line_count));
    }
    Ok(())
}

fn range_error(line_count: u32) -> Error {
    Error::new(
        ErrorCode::InvalidArgument,
        format!(
            "blame line range must be 1-based, ordered, and within the file's {line_count} lines"
        ),
    )
    .with_line_count(line_count)
}

fn line_count(bytes: &[u8]) -> Result<u32, Error> {
    let count = if bytes.is_empty() {
        0usize
    } else {
        bytes.iter().filter(|byte| **byte == b'\n').count() + usize::from(!bytes.ends_with(b"\n"))
    };
    u32::try_from(count).map_err(|_| {
        Error::new(
            ErrorCode::ObjectTooLarge,
            "blamed file has more lines than the blame engine can represent",
        )
        .with_limit("max_object_bytes")
    })
}

fn check_bytes(bytes: &[u8], budget: &Budget) -> Result<(), Error> {
    for _ in bytes.chunks(BUDGET_CHECK_BYTES) {
        budget.check()?;
    }
    budget.check()
}

fn missing(oid: Oid, role: &str) -> Error {
    Error::retryable(
        ErrorCode::MissingObject,
        format!("{role} object {oid} is missing from the object store"),
    )
    .with_oid(oid)
}

fn rewrite_platform(max_object_bytes: u64) -> gix_diff::blob::Platform {
    let pipeline = gix_diff::blob::Pipeline::new(
        Default::default(),
        Default::default(),
        Vec::new(),
        gix_diff::blob::pipeline::Options {
            large_file_threshold_bytes: max_object_bytes,
            ..Default::default()
        },
    );
    let attributes = gix_worktree::Stack::new(
        PathBuf::new(),
        gix_worktree::stack::State::AttributesStack(Default::default()),
        Default::default(),
        Vec::new(),
        Vec::new(),
    );
    gix_diff::blob::Platform::new(
        gix_diff::blob::platform::Options {
            algorithm: Some(gix_diff::blob::Algorithm::Histogram),
            ..Default::default()
        },
        pipeline,
        gix_diff::blob::pipeline::Mode::ToGit,
        attributes,
    )
}

#[derive(Clone)]
struct BlameObjectStore<'a> {
    state: std::rc::Rc<RefCell<AdapterState<'a>>>,
}

struct AdapterState<'a> {
    store: &'a dyn ObjectDb,
    budget: &'a Budget,
    objects: HashMap<Oid, (ObjectKind, Vec<u8>)>,
    counted: HashSet<Oid>,
    first_error: Option<Error>,
}

impl<'a> BlameObjectStore<'a> {
    fn new(
        store: &'a dyn ObjectDb,
        budget: &'a Budget,
        head_blob_id: Oid,
        head_blob: Vec<u8>,
    ) -> Self {
        Self {
            state: std::rc::Rc::new(RefCell::new(AdapterState {
                store,
                budget,
                objects: HashMap::from([(head_blob_id, (ObjectKind::Blob, head_blob))]),
                counted: HashSet::from([head_blob_id]),
                first_error: None,
            })),
        }
    }

    fn take_error(&self) -> Option<Error> {
        self.state.borrow_mut().first_error.take()
    }

    fn commit_payload(&self, oid: Oid) -> Result<Vec<u8>, Error> {
        let (kind, payload) = self.object(oid)?;
        if kind != ObjectKind::Commit {
            return Err(Error::new(
                ErrorCode::MalformedObject,
                "blame attribution references a non-commit object",
            )
            .with_oid(oid));
        }
        Ok(payload)
    }

    fn object(&self, oid: Oid) -> Result<(ObjectKind, Vec<u8>), Error> {
        let mut state = self.state.borrow_mut();
        if let Err(error) = state.budget.check() {
            return Err(record(&mut state, error));
        }
        if let Some(object) = state.objects.get(&oid) {
            return Ok(object.clone());
        }
        let mut payload = Vec::new();
        let result = state.budget.without_object_charge(oid, || {
            state.store.try_find(&oid, &mut payload, state.budget)
        });
        let kind = match result {
            Ok(Some(kind)) => kind,
            Ok(None) => return Err(record(&mut state, missing(oid, "required"))),
            Err(error) => return Err(record(&mut state, error.with_oid_if_none(oid))),
        };
        check_bytes(&payload, state.budget).map_err(|error| record(&mut state, error))?;
        if matches!(kind, ObjectKind::Commit | ObjectKind::Blob) && state.counted.insert(oid) {
            state
                .budget
                .charge_object_visit()
                .map_err(|error| record(&mut state, error))?;
        }
        if kind == ObjectKind::Commit
            && state
                .store
                .shallow_roots()
                .is_some_and(|roots| roots.contains(&oid))
        {
            payload = without_parent_headers(&payload);
        }
        state.objects.insert(oid, (kind, payload.clone()));
        Ok((kind, payload))
    }
}

impl gix_object::Find for BlameObjectStore<'_> {
    fn try_find<'a>(
        &self,
        id: &gix_hash::oid,
        buffer: &'a mut Vec<u8>,
    ) -> Result<Option<gix_object::Data<'a>>, gix_object::find::Error> {
        let oid = from_gix_oid(id).map_err(|error| Box::new(error) as gix_object::find::Error)?;
        let (kind, payload) = self
            .object(oid)
            .map_err(|error| Box::new(error) as gix_object::find::Error)?;
        buffer.clear();
        buffer.extend_from_slice(&payload);
        Ok(Some(gix_object::Data::new(
            buffer,
            to_gix_object_kind(kind),
            to_gix_hash(oid.kind()),
        )))
    }
}

impl gix_object::FindHeader for BlameObjectStore<'_> {
    fn try_header(
        &self,
        id: &gix_hash::oid,
    ) -> Result<Option<gix_object::Header>, gix_object::find::Error> {
        let oid = from_gix_oid(id).map_err(|error| Box::new(error) as gix_object::find::Error)?;
        if let Some((kind, payload)) = self.state.borrow().objects.get(&oid) {
            return Ok(Some(gix_object::Header {
                kind: to_gix_object_kind(*kind),
                size: payload.len() as u64,
            }));
        }
        // Loading through `object()` keeps header probes and later payload
        // requests on one unique commit/blob visit, and makes an oversize
        // comparison object a hard blame failure instead of a silent skip.
        let (kind, payload) = self
            .object(oid)
            .map_err(|error| Box::new(error) as gix_object::find::Error)?;
        Ok(Some(gix_object::Header {
            kind: to_gix_object_kind(kind),
            size: payload.len() as u64,
        }))
    }
}

fn record(state: &mut AdapterState<'_>, error: Error) -> Error {
    state.first_error.get_or_insert_with(|| error.clone());
    error
}

fn without_parent_headers(payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(payload.len());
    let mut in_headers = true;
    for line in payload.split_inclusive(|byte| *byte == b'\n') {
        if in_headers && line == b"\n" {
            in_headers = false;
        }
        if in_headers && line.starts_with(b"parent ") {
            continue;
        }
        out.extend_from_slice(line);
    }
    out
}

fn to_gix_hash(kind: HashKind) -> gix_hash::Kind {
    match kind {
        HashKind::Sha1 => gix_hash::Kind::Sha1,
        HashKind::Sha256 => gix_hash::Kind::Sha256,
    }
}

fn to_gix_object_kind(kind: ObjectKind) -> gix_object::Kind {
    match kind {
        ObjectKind::Commit => gix_object::Kind::Commit,
        ObjectKind::Tree => gix_object::Kind::Tree,
        ObjectKind::Blob => gix_object::Kind::Blob,
        ObjectKind::Tag => gix_object::Kind::Tag,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::local_odb::LocalOdb;
    use crate::test_support::{fixture_oid, fixture_repo};
    use std::process::Command;

    #[derive(Debug, PartialEq, Eq)]
    struct OracleHunk {
        final_start: u32,
        final_end: u32,
        original_start: u32,
        original_end: u32,
        commit: String,
        path: Vec<u8>,
        boundary: bool,
    }

    #[test]
    fn generated_fixture_matches_git_for_full_ranges_no_follow_and_shallow_boundary() {
        for (repository_name, head_key, path, lines, follow) in [
            (
                "sha1-blame.git",
                "sha1_blame_head",
                b"docs/final.txt".as_slice(),
                None,
                true,
            ),
            (
                "sha1-blame.git",
                "sha1_blame_head",
                b"docs/final.txt".as_slice(),
                Some((2, 5)),
                true,
            ),
            (
                "sha1-blame.git",
                "sha1_blame_head",
                b"docs/final.txt".as_slice(),
                None,
                false,
            ),
            (
                "sha1-blame.git",
                "sha1_blame_post_rename",
                b"docs/story.txt".as_slice(),
                None,
                true,
            ),
            (
                "sha1-history-shallow.git",
                "sha1_history_head",
                b"src/tale.txt".as_slice(),
                None,
                true,
            ),
        ] {
            let repository = fixture_repo(repository_name);
            let (store, _) =
                LocalOdb::open(&repository, Default::default()).expect("fixture repository opens");
            let head = fixture_oid(head_key);
            let snapshot =
                Snapshot::open(&store, head, &Budget::unlimited()).expect("fixture snapshot opens");
            let actual = blame(
                &store,
                &snapshot,
                path,
                &BlameOptions {
                    lines,
                    follow_renames: follow,
                },
                &Budget::unlimited(),
            )
            .expect("core blame succeeds")
            .hunks
            .into_iter()
            .map(|hunk| OracleHunk {
                final_start: hunk.final_start,
                final_end: hunk.final_end,
                original_start: hunk.original_start,
                original_end: hunk.original_end,
                commit: hunk.commit_id.to_hex(),
                path: hunk.original_path,
                boundary: hunk.boundary,
            })
            .collect::<Vec<_>>();
            let expected = git_blame(&repository, head, path, lines, follow);
            assert_eq!(
                actual,
                expected,
                "blame divergence: repo={repository_name} path={} lines={lines:?} follow={follow}",
                String::from_utf8_lossy(path)
            );
        }
    }

    #[test]
    fn validates_ranges_kinds_and_hard_budget_refusal() {
        let repository = fixture_repo("sha1-blame.git");
        let (store, _) =
            LocalOdb::open(&repository, Default::default()).expect("fixture repository opens");
        let snapshot = Snapshot::open(&store, fixture_oid("sha1_blame_head"), &Budget::unlimited())
            .expect("fixture snapshot opens");
        let complete = blame(
            &store,
            &snapshot,
            b"docs/final.txt",
            &BlameOptions::default(),
            &Budget::unlimited(),
        )
        .expect("complete blame succeeds");
        let final_hunk = complete
            .hunks
            .iter()
            .find(|hunk| hunk.commit_id == fixture_oid("sha1_blame_final"))
            .expect("final line is attributed to the final commit");
        assert_eq!(final_hunk.author.name, b"B\xe9b Bytes");
        assert_eq!(
            final_hunk.summary,
            b"Add Latin-1 without a trailing newline"
        );

        let out_of_range = blame(
            &store,
            &snapshot,
            b"docs/final.txt",
            &BlameOptions {
                lines: Some((1, 8)),
                ..BlameOptions::default()
            },
            &Budget::unlimited(),
        )
        .expect_err("range beyond seven lines fails");
        assert_eq!(out_of_range.code, ErrorCode::InvalidArgument);
        assert_eq!(out_of_range.line_count(), Some(7));

        let tree = blame(
            &store,
            &snapshot,
            b"docs",
            &BlameOptions::default(),
            &Budget::unlimited(),
        )
        .expect_err("tree path fails semantically");
        assert_eq!(tree.code, ErrorCode::InvalidArgument);
        assert_eq!(tree.reason.as_deref(), Some("path_kind:tree"));

        let object_size_budget = Budget::new(
            crate::budget::BudgetLimits {
                // The fixture's root and `docs` trees are 74 and 37 bytes,
                // while the mandatory blamed blob is 81 bytes.
                max_object_bytes: 80,
                ..crate::budget::BudgetLimits::default()
            },
            None,
            std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
        );
        let oversized = blame(
            &store,
            &snapshot,
            b"docs/final.txt",
            &BlameOptions::default(),
            &object_size_budget,
        )
        .expect_err("the mandatory head blob cannot be skipped");
        assert_eq!(oversized.code, ErrorCode::ObjectTooLarge);
        assert_eq!(oversized.limit, Some("max_object_bytes"));

        let budget = Budget::new(
            crate::budget::BudgetLimits {
                max_objects: 2,
                ..crate::budget::BudgetLimits::default()
            },
            None,
            std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
        );
        let refusal = blame(
            &store,
            &snapshot,
            b"docs/final.txt",
            &BlameOptions::default(),
            &budget,
        )
        .expect_err("incomplete blame is never returned");
        assert_eq!(refusal.code, ErrorCode::BudgetExceeded);
    }

    fn git_blame(
        repository: &std::path::Path,
        head: Oid,
        path: &[u8],
        lines: Option<(u32, u32)>,
        follow: bool,
    ) -> Vec<OracleHunk> {
        let mut arguments = vec!["blame".to_owned(), "--line-porcelain".to_owned()];
        if let Some((start, end)) = lines {
            arguments.push(format!("-L{start},{end}"));
        }
        if !follow {
            arguments.push("--no-follow".to_owned());
        }
        arguments.extend([
            head.to_hex(),
            "--".to_owned(),
            String::from_utf8_lossy(path).into(),
        ]);
        let output = Command::new("git")
            .arg("-C")
            .arg(repository)
            .args(arguments)
            .output()
            .expect("git blame runs");
        assert!(output.status.success(), "git blame failed");
        let mut lines = output.stdout.split(|byte| *byte == b'\n').peekable();
        let mut per_line = Vec::new();
        while let Some(header) = lines.next() {
            if header.is_empty() {
                continue;
            }
            let fields = header.split(|byte| *byte == b' ').collect::<Vec<_>>();
            assert!(fields.len() >= 3, "porcelain header is complete");
            let commit = std::str::from_utf8(fields[0])
                .expect("commit is ASCII")
                .to_owned();
            let original = parse_u32(fields[1]);
            let final_line = parse_u32(fields[2]);
            let mut original_path = None;
            let mut boundary = false;
            for metadata in lines.by_ref() {
                if metadata.starts_with(b"filename ") {
                    original_path = Some(metadata[b"filename ".len()..].to_vec());
                } else if metadata == b"boundary" {
                    boundary = true;
                } else if metadata.starts_with(b"\t") {
                    break;
                }
            }
            per_line.push((
                commit,
                original,
                final_line,
                original_path.expect("line porcelain always carries filename"),
                boundary,
            ));
        }
        per_line.into_iter().fold(Vec::new(), |mut hunks, line| {
            if let Some(last) = hunks.last_mut() {
                if last.commit == line.0
                    && last.path == line.3
                    && last.boundary == line.4
                    && last.final_end.saturating_add(1) == line.2
                    && last.original_end.saturating_add(1) == line.1
                {
                    last.final_end = line.2;
                    last.original_end = line.1;
                    return hunks;
                }
            }
            hunks.push(OracleHunk {
                final_start: line.2,
                final_end: line.2,
                original_start: line.1,
                original_end: line.1,
                commit: line.0,
                path: line.3,
                boundary: line.4,
            });
            hunks
        })
    }

    fn parse_u32(bytes: &[u8]) -> u32 {
        std::str::from_utf8(bytes)
            .expect("line is ASCII")
            .parse()
            .expect("line is numeric")
    }
}
