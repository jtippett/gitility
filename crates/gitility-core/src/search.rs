//! Sequential, byte-oriented snapshot content search.
//!
//! Search reuses tree resolution, decoding, ordering, pathspec matching, and
//! provider prefetch from [`crate::tree`]. A live walk charges tree reads and
//! blob visits normally. Cursor resume alone replays its already-paid prefix
//! through the graph seam, then charges the cursor-path re-scan and all later
//! work. Its cost is O(prefix paths + one blob re-scan).

use crate::budget::Budget;
use crate::cursor::{self, Cursor, CursorExpected, MAX_CURSOR_BYTES, OPERATION_SEARCH};
use crate::error::{Error, ErrorCode};
use crate::lru::LruCache;
use crate::object::{ObjectKind, Oid};
use crate::odb::{HeaderProvenance, ObjectDb};
use crate::pathspec::PathspecMatcher;
use crate::snapshot::Snapshot;
use crate::tree::{
    ensure_query_compatible, join_path, read_tree_entries_for_graph_walk,
    read_tree_entries_for_walk, relative_to_scope, resolve_path, resolve_path_for_graph_walk,
    validate_path, QueryStats, ResolvedPath, TreeItemKind,
};
use bstr::ByteSlice;
use regex::bytes::{Regex, RegexBuilder};
use std::collections::HashSet;

const BINARY_PROBE_BYTES: usize = 8_000;
const PREVIEW_BYTES: usize = 1_024;
const SCAN_CHECK_BYTES: usize = 64 * 1_024;
const MAX_SUBMATCHES: usize = 256;
const BLOB_PREFETCH_WINDOW: usize = 64;
// Cache weight is matching-line span count, not payload bytes. At 64K fixed-
// size entries the retained scan metadata stays bounded even when context is
// maximal or one blob contains millions of occurrences.
const SCAN_CACHE_MATCH_CAP: u64 = 64 * 1_024;
// Compilation is capped independently from result/object budgets: one MiB of
// compiled regex state and two MiB for the optional lazy DFA cache. With only
// regex's `std` feature enabled the PikeVM remains the guaranteed fallback.
const REGEX_SIZE_LIMIT: usize = 1_024 * 1_024;
const REGEX_DFA_SIZE_LIMIT: usize = 2 * 1_024 * 1_024;
pub const MAX_CONTEXT_LINES: u32 = 32;

/// Search pattern interpretation.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub enum SearchMode {
    #[default]
    Literal,
    Regex,
}

/// Binary-blob policy for search.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub enum SearchBinaryMode {
    #[default]
    Skip,
    Text,
}

/// Options for [`search`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchOptions {
    pub mode: SearchMode,
    pub case_sensitive: bool,
    pub path: Vec<u8>,
    pub pathspecs: Vec<Vec<u8>>,
    pub binary: SearchBinaryMode,
    pub context_lines: u32,
    pub limit: usize,
    /// Total raw result payload, including a continuation cursor when one is
    /// needed. Numeric/map encoding overhead is conservatively represented by
    /// fixed byte charges in [`SearchMatch::payload_bytes`].
    pub max_result_bytes: u64,
    pub cursor: Option<Vec<u8>>,
}

impl Default for SearchOptions {
    fn default() -> Self {
        Self {
            mode: SearchMode::Literal,
            case_sensitive: true,
            path: Vec::new(),
            pathspecs: Vec::new(),
            binary: SearchBinaryMode::Skip,
            context_lines: 0,
            limit: 1_000,
            max_result_bytes: 8 * 1_024 * 1_024,
            cursor: None,
        }
    }
}

/// One byte range that begins within the emitted preview. A range crossing the
/// preview boundary is clamped; ranges beginning after it are omitted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SearchSubmatch {
    pub start: u32,
    pub length: u32,
}

/// One matching line. Multiple occurrences on the line are grouped here.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchMatch {
    pub commit_oid: Oid,
    pub blob_oid: Oid,
    pub path: Vec<u8>,
    pub line: u32,
    pub column: u32,
    pub preview: Vec<u8>,
    pub preview_truncated: bool,
    pub submatches: Vec<SearchSubmatch>,
    pub submatches_truncated: bool,
    pub context_before: Vec<Vec<u8>>,
    pub context_after: Vec<Vec<u8>>,
}

impl SearchMatch {
    fn payload_bytes(&self) -> u64 {
        let byte_vectors = self
            .preview
            .len()
            .saturating_add(self.path.len())
            .saturating_add(
                self.context_before
                    .iter()
                    .chain(&self.context_after)
                    .map(Vec::len)
                    .sum::<usize>(),
            );
        // Match-derived payload has a hard structural ceiling: 1 KiB preview,
        // 64 capped context lines, and 256 submatch maps charged at 32 bytes
        // each. Identity and the repository path are charged separately.
        let fixed = self
            .commit_oid
            .as_bytes()
            .len()
            .saturating_add(self.blob_oid.as_bytes().len())
            .saturating_add(16)
            .saturating_add(self.submatches.len().saturating_mul(32));
        u64::try_from(byte_vectors.saturating_add(fixed)).unwrap_or(u64::MAX)
    }
}

/// One deterministic page of matching lines.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchPage {
    pub matches: Vec<SearchMatch>,
    pub next_cursor: Option<Vec<u8>>,
    pub truncated: bool,
    pub stats: QueryStats,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct ByteSpan {
    start: u32,
    end: u32,
}

impl ByteSpan {
    fn new(start: usize, end: usize) -> Result<Self, Error> {
        Ok(Self {
            start: u32::try_from(start).map_err(|_| result_too_large())?,
            end: u32::try_from(end).map_err(|_| result_too_large())?,
        })
    }

    fn range(self) -> std::ops::Range<usize> {
        self.start as usize..self.end as usize
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct CachedLineMatch {
    line: u32,
    column: u32,
    preview: ByteSpan,
    line_end: u32,
    context_before: Option<ByteSpan>,
    context_after: Option<ByteSpan>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum CachedScan {
    Matches(Vec<CachedLineMatch>),
    BinarySkipped,
    OversizeSkipped,
}

impl CachedScan {
    fn cache_weight(&self) -> u64 {
        match self {
            Self::Matches(matches) => u64::try_from(matches.len()).unwrap_or(u64::MAX).max(1),
            Self::BinarySkipped | Self::OversizeSkipped => 1,
        }
    }
}

struct ScannedBlob {
    scan: CachedScan,
    payload: Option<Vec<u8>>,
}

enum CompiledMatcher {
    Literal(Vec<u8>),
    Regex(Regex),
}

impl CompiledMatcher {
    fn compile(query: &[u8], opts: &SearchOptions) -> Result<Self, Error> {
        if opts.mode == SearchMode::Literal && opts.case_sensitive {
            return Ok(Self::Literal(query.to_vec()));
        }

        let pattern = match opts.mode {
            SearchMode::Literal => escaped_literal(query),
            SearchMode::Regex => {
                std::str::from_utf8(query)
                    .map(str::to_owned)
                    .map_err(|error| {
                        unsupported_regex(format!("regex pattern is not UTF-8: {error}"))
                    })?
            }
        };
        let mut builder = RegexBuilder::new(&pattern);
        // Raw-byte search deliberately uses ASCII folding only. Keeping
        // Unicode mode off avoids encoding assumptions and lets the exact pin
        // omit regex's `unicode-case` tables; literal non-ASCII bytes remain
        // exact under case-insensitive mode.
        builder
            .unicode(false)
            .case_insensitive(!opts.case_sensitive)
            .size_limit(REGEX_SIZE_LIMIT)
            .dfa_size_limit(REGEX_DFA_SIZE_LIMIT);
        builder
            .build()
            .map(Self::Regex)
            .map_err(|error| unsupported_regex(error.to_string()))
    }

    fn first_occurrence(
        &self,
        line: &[u8],
        budget: &Budget,
    ) -> Result<Option<(usize, usize)>, Error> {
        match self {
            Self::Literal(query) if query.is_empty() => Ok(Some((0, 0))),
            Self::Literal(query) => literal_occurrences(line, query, budget, |found| {
                std::ops::ControlFlow::Break(found)
            }),
            Self::Regex(regex) => {
                // A matchless regex search performs one engine pass over the
                // line. That is the cancellation-granularity floor, bounded by
                // max_object_bytes; every line and every yielded find is
                // checked, so matching regexes regain fine-grained cadence.
                budget.check()?;
                Ok(regex.find(line).map(|found| (found.start(), found.end())))
            }
        }
    }

    fn preview_submatches(
        &self,
        line: &[u8],
        preview_len: usize,
        budget: &Budget,
    ) -> Result<(Vec<SearchSubmatch>, bool), Error> {
        let mut submatches = Vec::with_capacity(MAX_SUBMATCHES.min(16));
        let mut truncated = false;
        let mut retain = |(start, end): (usize, usize)| {
            if start >= preview_len || submatches.len() == MAX_SUBMATCHES {
                truncated = true;
                return std::ops::ControlFlow::Break(());
            }
            submatches.push(SearchSubmatch {
                start: u32::try_from(start).unwrap_or(u32::MAX),
                length: u32::try_from(end.min(preview_len).saturating_sub(start))
                    .unwrap_or(u32::MAX),
            });
            std::ops::ControlFlow::Continue(())
        };

        match self {
            Self::Literal(query) if query.is_empty() => {
                let retained = preview_len.min(MAX_SUBMATCHES);
                submatches.extend((0..retained).map(|start| SearchSubmatch {
                    start: start as u32,
                    length: 0,
                }));
                truncated = line.len().saturating_add(1) > retained;
            }
            Self::Literal(query) => {
                let _: Option<()> = literal_occurrences(line, query, budget, &mut retain)?;
            }
            Self::Regex(regex) => {
                budget.check()?;
                for found in regex.find_iter(line) {
                    budget.check()?;
                    if retain((found.start(), found.end())).is_break() {
                        break;
                    }
                }
            }
        }
        Ok((submatches, truncated))
    }
}

fn literal_occurrences<B>(
    line: &[u8],
    query: &[u8],
    budget: &Budget,
    mut visit: impl FnMut((usize, usize)) -> std::ops::ControlFlow<B>,
) -> Result<Option<B>, Error> {
    if query.is_empty() || query.len() > line.len() {
        budget.check()?;
        return Ok(None);
    }

    let overlap = query.len().saturating_sub(1);
    let mut core_start = 0usize;
    let mut next_allowed = 0usize;
    while core_start < line.len() {
        budget.check()?;
        let core_end = core_start.saturating_add(SCAN_CHECK_BYTES).min(line.len());
        let window_end = core_end.saturating_add(overlap).min(line.len());
        let mut offset = next_allowed.max(core_start);
        while offset <= window_end.saturating_sub(query.len()) {
            let Some(relative) = line[offset..window_end].find(query) else {
                break;
            };
            let start = offset.saturating_add(relative);
            if start >= core_end && core_end < line.len() {
                break;
            }
            let end = start.saturating_add(query.len());
            if let std::ops::ControlFlow::Break(value) = visit((start, end)) {
                return Ok(Some(value));
            }
            next_allowed = end;
            offset = end;
        }
        core_start = core_end;
    }
    Ok(None)
}

/// Searches the blobs reachable through one pinned snapshot.
///
/// The LRU scan cache is bounded by matching-line entry count and retains only
/// fixed-size byte spans. Preview/context bytes are materialized from the
/// payload in hand and dropped; duplicate paths may therefore perform an
/// uncharged physical payload reread while logical bytes remain charged once.
///
/// Literal lines are searched in overlapped 64 KiB windows. Regex checks each
/// line and yielded find; one matchless engine pass over a line is the
/// cancellation-granularity floor, bounded by `max_object_bytes`.
pub fn search(
    store: &dyn ObjectDb,
    snapshot: &Snapshot,
    query: &[u8],
    opts: &SearchOptions,
    budget: &Budget,
) -> Result<SearchPage, Error> {
    search_with_cache_capacity(store, snapshot, query, opts, budget, SCAN_CACHE_MATCH_CAP)
}

fn search_with_cache_capacity(
    store: &dyn ObjectDb,
    snapshot: &Snapshot,
    query: &[u8],
    opts: &SearchOptions,
    budget: &Budget,
    scan_cache_capacity: u64,
) -> Result<SearchPage, Error> {
    ensure_query_compatible(store, snapshot)?;
    validate_options(opts)?;
    budget.check()?;
    let matcher = CompiledMatcher::compile(query, opts)?;
    let fingerprint = option_fingerprint(query, opts);
    let resume = decode_resume(snapshot, opts, fingerprint)?;

    let resolved = if resume.is_some() {
        resolve_path_for_graph_walk(store, snapshot, &opts.path, budget)
    } else {
        resolve_path(store, snapshot, &opts.path, budget)
    }?;
    let tree_oid = match resolved {
        ResolvedPath::RootTree(oid) => oid,
        ResolvedPath::Entry(entry) if entry.kind == TreeItemKind::Tree => entry.oid,
        ResolvedPath::Entry(_) => {
            return Err(Error::new(
                ErrorCode::NotATree,
                "path does not resolve to a tree",
            ))
        }
    };
    let mut walk = BlobWalk::new(
        store,
        tree_oid,
        &opts.path,
        &opts.pathspecs,
        resume.as_ref().map(|(path, _)| path.as_slice()),
        budget,
    )?;
    let mut cache = LruCache::<Oid, CachedScan>::new(scan_cache_capacity);
    let mut matches = Vec::with_capacity(opts.limit.min(1_024));
    let mut positions = Vec::<(Vec<u8>, u32)>::with_capacity(opts.limit.min(1_024));
    let mut payload_bytes = 0u64;
    let mut found_resume = resume.is_none();
    let mut stopped_by = None;
    let mut files_scanned = 0u64;
    let mut blobs_deduped = 0u64;
    let mut binary_skipped = 0u64;
    let mut oversize_skipped = 0u64;
    let mut payload_rereads = 0u64;
    let mut visited_blobs = HashSet::new();
    let mut payload_reads = HashSet::new();

    'walk: loop {
        budget.check()?;
        let candidate = match walk.next() {
            Ok(Some(candidate)) => candidate,
            Ok(None) => break,
            Err(error) if truncatable(&error) && !matches.is_empty() => {
                stopped_by = Some(error.limit.unwrap_or("budget"));
                break;
            }
            Err(error) => return Err(error),
        };

        let start_ordinal = match &resume {
            Some((resume_path, resume_ordinal)) if !found_resume => {
                match candidate.path.as_slice().cmp(resume_path.as_slice()) {
                    std::cmp::Ordering::Less => continue,
                    std::cmp::Ordering::Greater => {
                        return Err(invalid_cursor(
                            "position check failed: path is not in this traversal",
                        ))
                    }
                    std::cmp::Ordering::Equal => {
                        found_resume = true;
                        Some(resume_ordinal.saturating_add(1))
                    }
                }
            }
            _ => None,
        };

        let first_blob_visit = visited_blobs.insert(candidate.oid);
        if !first_blob_visit {
            blobs_deduped = blobs_deduped.saturating_add(1);
        }

        if let Some(scan) = cache.get(&candidate.oid) {
            match budget.charge_object_visit() {
                Ok(()) => {}
                Err(error) if truncatable(&error) && !matches.is_empty() => {
                    stopped_by = Some(error.limit.unwrap_or("budget"));
                    break;
                }
                Err(error) => return Err(error),
            }
            match scan {
                CachedScan::Matches(line_matches) => {
                    let payload = match read_blob_payload(store, candidate.oid, budget)? {
                        Some(payload) => payload,
                        None => {
                            if first_blob_visit {
                                oversize_skipped = oversize_skipped.saturating_add(1);
                            }
                            continue;
                        }
                    };
                    if !payload_reads.insert(candidate.oid) {
                        payload_rereads = payload_rereads.saturating_add(1);
                    }
                    match emit_matches(
                        snapshot,
                        &candidate,
                        line_matches,
                        &payload,
                        &matcher,
                        start_ordinal,
                        opts,
                        budget,
                        &mut matches,
                        &mut positions,
                        &mut payload_bytes,
                    )? {
                        EmitOutcome::Complete => {}
                        EmitOutcome::Stopped(limit) => {
                            stopped_by = Some(limit);
                            break 'walk;
                        }
                    }
                }
                CachedScan::BinarySkipped | CachedScan::OversizeSkipped => {
                    if start_ordinal.is_some() {
                        return Err(invalid_cursor(
                            "position check failed: cursor path has no emitted matches",
                        ));
                    }
                }
            }
        } else {
            let scanned = match scan_blob(store, candidate.oid, &matcher, opts, budget) {
                Ok(scan) => scan,
                Err(error) if truncatable(&error) && !matches.is_empty() => {
                    stopped_by = Some(error.limit.unwrap_or("budget"));
                    break;
                }
                Err(error) => return Err(error),
            };
            if scanned.payload.is_some() && !payload_reads.insert(candidate.oid) {
                payload_rereads = payload_rereads.saturating_add(1);
            }
            match &scanned.scan {
                CachedScan::Matches(_) if first_blob_visit => {
                    files_scanned = files_scanned.saturating_add(1)
                }
                CachedScan::Matches(_) => {}
                CachedScan::BinarySkipped if first_blob_visit => {
                    binary_skipped = binary_skipped.saturating_add(1)
                }
                CachedScan::BinarySkipped => {}
                CachedScan::OversizeSkipped if first_blob_visit => {
                    oversize_skipped = oversize_skipped.saturating_add(1)
                }
                CachedScan::OversizeSkipped => {}
            }
            if let CachedScan::Matches(line_matches) = &scanned.scan {
                let payload = scanned
                    .payload
                    .as_deref()
                    .expect("matching scans retain their payload until emission");
                match emit_matches(
                    snapshot,
                    &candidate,
                    line_matches,
                    payload,
                    &matcher,
                    start_ordinal,
                    opts,
                    budget,
                    &mut matches,
                    &mut positions,
                    &mut payload_bytes,
                )? {
                    EmitOutcome::Complete => {}
                    EmitOutcome::Stopped(limit) => {
                        stopped_by = Some(limit);
                        break 'walk;
                    }
                }
            } else if start_ordinal.is_some() {
                return Err(invalid_cursor(
                    "position check failed: cursor path has no emitted matches",
                ));
            }
            let weight = scanned.scan.cache_weight();
            cache.insert(candidate.oid, scanned.scan, weight);
        }
    }

    if !found_resume {
        return Err(invalid_cursor(
            "position check failed: path is not in this traversal",
        ));
    }

    let next_cursor = if stopped_by.is_some() {
        fit_cursor(
            snapshot,
            fingerprint,
            opts.max_result_bytes,
            &mut matches,
            &mut positions,
            &mut payload_bytes,
            &mut stopped_by,
        )?
    } else {
        None
    };

    let truncated = stopped_by.is_some();
    let (objects_read, bytes_read, _, _) = budget.spent();
    let (cache_hits, cache_misses) = budget.cache_spent();
    let cache_stats = store.cache_stats();
    let entries_emitted = matches.len() as u64;
    Ok(SearchPage {
        matches,
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
            files_scanned,
            blobs_deduped,
            binary_skipped,
            oversize_skipped,
            payload_rereads,
            stopped_by,
        },
    })
}

#[derive(Debug)]
struct BlobCandidate {
    path: Vec<u8>,
    oid: Oid,
}

struct BlobWalk<'a> {
    store: &'a dyn ObjectDb,
    budget: &'a Budget,
    scope: &'a [u8],
    matcher: PathspecMatcher,
    stack: Vec<WalkFrame>,
    replaying: bool,
    resume_path: Option<&'a [u8]>,
    prefetched_blobs: HashSet<Oid>,
}

struct WalkFrame {
    entries: std::vec::IntoIter<crate::tree::OwnedTreeEntry>,
    prefix: Vec<u8>,
}

impl<'a> BlobWalk<'a> {
    fn new(
        store: &'a dyn ObjectDb,
        tree_oid: Oid,
        scope: &'a [u8],
        pathspecs: &[Vec<u8>],
        resume_path: Option<&'a [u8]>,
        budget: &'a Budget,
    ) -> Result<Self, Error> {
        let mut walk = Self {
            store,
            budget,
            scope,
            matcher: PathspecMatcher::new(pathspecs),
            stack: Vec::new(),
            replaying: resume_path.is_some(),
            resume_path,
            prefetched_blobs: HashSet::new(),
        };
        let entries = walk.read_entries(tree_oid, scope)?;
        walk.stack.push(WalkFrame {
            entries: entries.into_iter(),
            prefix: scope.to_vec(),
        });
        Ok(walk)
    }

    fn next(&mut self) -> Result<Option<BlobCandidate>, Error> {
        loop {
            self.budget.check()?;
            let Some(frame) = self.stack.last_mut() else {
                return Ok(None);
            };
            let Some(entry) = frame.entries.next() else {
                self.stack.pop();
                continue;
            };
            let path = join_path(&frame.prefix, &entry.name);
            if entry.kind == TreeItemKind::Tree {
                let entries = self.read_entries(entry.oid, &path)?;
                self.stack.push(WalkFrame {
                    entries: entries.into_iter(),
                    prefix: path,
                });
                continue;
            }
            // Canonical git grep does not search a tree entry whose mode is a
            // symlink; following it would violate snapshot-only traversal,
            // while searching the link target bytes would diverge from Git.
            if entry.kind != TreeItemKind::Blob
                || !self.matcher.matches(relative_to_scope(&path, self.scope))
            {
                continue;
            }
            if self
                .resume_path
                .is_some_and(|resume_path| path.as_slice() >= resume_path)
            {
                self.replaying = false;
            }
            return Ok(Some(BlobCandidate {
                path,
                oid: entry.oid,
            }));
        }
    }

    fn read_entries(
        &mut self,
        oid: Oid,
        prefix: &[u8],
    ) -> Result<Vec<crate::tree::OwnedTreeEntry>, Error> {
        let entries = if self.replaying {
            read_tree_entries_for_graph_walk(self.store, oid, self.budget)?
        } else {
            read_tree_entries_for_walk(self.store, oid, self.budget, true)?
        };
        if self.store.supports_prefetch() {
            let pending = entries
                .iter()
                .filter(|entry| entry.kind == TreeItemKind::Blob)
                .filter(|entry| {
                    let path = join_path(prefix, &entry.name);
                    self.matcher.matches(relative_to_scope(&path, self.scope))
                        && self
                            .resume_path
                            .is_none_or(|resume_path| path.as_slice() >= resume_path)
                })
                .map(|entry| entry.oid)
                .filter(|oid| self.prefetched_blobs.insert(*oid))
                .collect::<Vec<_>>();
            for window in pending.chunks(BLOB_PREFETCH_WINDOW) {
                self.store.prefetch(window, self.budget)?;
            }
        }
        Ok(entries)
    }
}

fn scan_blob(
    store: &dyn ObjectDb,
    oid: Oid,
    matcher: &CompiledMatcher,
    opts: &SearchOptions,
    budget: &Budget,
) -> Result<ScannedBlob, Error> {
    budget.check()?;
    let header = store
        .try_header_with_provenance(&oid, budget)?
        .ok_or_else(|| missing_blob(oid))?;
    if header.header.kind != ObjectKind::Blob {
        return Err(match header.provenance {
            HeaderProvenance::UnverifiedProvider => Error::new(
                ErrorCode::ProviderProtocolError,
                "provider header contradicts tree entry kind",
            ),
            HeaderProvenance::Verified => Error::new(
                ErrorCode::MalformedObject,
                format!("tree blob {oid} addresses a non-blob object"),
            ),
        }
        .with_oid(oid));
    }
    if header.header.size > budget.limits().max_object_bytes {
        return Ok(ScannedBlob {
            scan: CachedScan::OversizeSkipped,
            payload: None,
        });
    }

    let Some(payload) = read_blob_payload(store, oid, budget)? else {
        return Ok(ScannedBlob {
            scan: CachedScan::OversizeSkipped,
            payload: None,
        });
    };
    budget.check()?;
    if opts.binary == SearchBinaryMode::Skip
        && payload[..payload.len().min(BINARY_PROBE_BYTES)].contains(&0)
    {
        return Ok(ScannedBlob {
            scan: CachedScan::BinarySkipped,
            // Retained only until this candidate is accounted; the cache
            // receives `scan` alone and never owns payload bytes.
            payload: Some(payload),
        });
    }
    let matches = scan_payload(&payload, matcher, opts.context_lines, budget)?;
    Ok(ScannedBlob {
        scan: CachedScan::Matches(matches),
        payload: Some(payload),
    })
}

/// Reads one blob payload through the graph seam. `ObjectTooLarge` is a skip
/// only here: all non-search callers and all other error sites preserve the
/// normal hard-error semantics.
fn read_blob_payload(
    store: &dyn ObjectDb,
    oid: Oid,
    budget: &Budget,
) -> Result<Option<Vec<u8>>, Error> {
    let mut payload = Vec::new();
    let kind = match store.try_find_graph(&oid, &mut payload, budget) {
        Ok(kind) => kind.ok_or_else(|| missing_blob(oid))?,
        Err(error) if error.code == ErrorCode::ObjectTooLarge => return Ok(None),
        Err(error) => return Err(error),
    };
    if kind != ObjectKind::Blob {
        return Err(Error::new(
            ErrorCode::MalformedObject,
            format!("tree blob {oid} addresses a non-blob object"),
        )
        .with_oid(oid));
    }
    Ok(Some(payload))
}

fn scan_payload(
    payload: &[u8],
    matcher: &CompiledMatcher,
    context_lines: u32,
    budget: &Budget,
) -> Result<Vec<CachedLineMatch>, Error> {
    let spans = line_spans(payload, budget)?;
    let mut results = Vec::new();
    for (index, &(start, end)) in spans.iter().enumerate() {
        budget.check()?;
        let line = &payload[start..end];
        let Some((first_start, _)) = matcher.first_occurrence(line, budget)? else {
            continue;
        };
        let preview_end = line.len().min(PREVIEW_BYTES);
        let context = usize::try_from(context_lines).unwrap_or(usize::MAX);
        let before_start = index.saturating_sub(context);
        let after_end = index
            .saturating_add(1)
            .saturating_add(context)
            .min(spans.len());
        results.push(CachedLineMatch {
            line: u32::try_from(index.saturating_add(1)).map_err(|_| result_too_large())?,
            column: u32::try_from(first_start).map_err(|_| result_too_large())?,
            preview: ByteSpan::new(start, start.saturating_add(preview_end))?,
            line_end: u32::try_from(end).map_err(|_| result_too_large())?,
            context_before: (before_start < index)
                .then(|| ByteSpan::new(spans[before_start].0, spans[index - 1].1))
                .transpose()?,
            context_after: (index.saturating_add(1) < after_end)
                .then(|| ByteSpan::new(spans[index + 1].0, spans[after_end - 1].1))
                .transpose()?,
        });
    }
    Ok(results)
}

fn line_spans(payload: &[u8], budget: &Budget) -> Result<Vec<(usize, usize)>, Error> {
    let mut spans = Vec::new();
    let mut start = 0usize;
    let mut chunk_start = 0usize;
    while chunk_start < payload.len() {
        budget.check()?;
        let chunk_end = chunk_start
            .saturating_add(SCAN_CHECK_BYTES)
            .min(payload.len());
        for (relative, byte) in payload[chunk_start..chunk_end].iter().enumerate() {
            if *byte == b'\n' {
                let index = chunk_start.saturating_add(relative);
                spans.push((start, index));
                start = index.saturating_add(1);
            }
        }
        chunk_start = chunk_end;
    }
    if start < payload.len() {
        spans.push((start, payload.len()));
    }
    Ok(spans)
}

fn materialize_lines(payload: &[u8], span: Option<ByteSpan>) -> Vec<Vec<u8>> {
    span.map_or_else(Vec::new, |span| {
        payload[span.range()]
            .split(|byte| *byte == b'\n')
            .map(|line| line[..line.len().min(PREVIEW_BYTES)].to_vec())
            .collect()
    })
}

enum EmitOutcome {
    Complete,
    Stopped(&'static str),
}

#[allow(clippy::too_many_arguments)]
fn emit_matches(
    snapshot: &Snapshot,
    candidate: &BlobCandidate,
    cached_matches: &[CachedLineMatch],
    payload: &[u8],
    matcher: &CompiledMatcher,
    start_ordinal: Option<u32>,
    opts: &SearchOptions,
    budget: &Budget,
    matches: &mut Vec<SearchMatch>,
    positions: &mut Vec<(Vec<u8>, u32)>,
    payload_bytes: &mut u64,
) -> Result<EmitOutcome, Error> {
    let start = match start_ordinal {
        Some(start) => {
            let prior = start.saturating_sub(1);
            if usize::try_from(prior)
                .ok()
                .is_none_or(|ordinal| ordinal >= cached_matches.len())
            {
                return Err(invalid_cursor(
                    "position check failed: match ordinal is outside the file",
                ));
            }
            usize::try_from(start).unwrap_or(usize::MAX)
        }
        None => 0,
    };

    for (ordinal, cached) in cached_matches.iter().enumerate().skip(start) {
        budget.check()?;
        if matches.len() == opts.limit {
            return Ok(EmitOutcome::Stopped("limit"));
        }
        let preview = &payload[cached.preview.range()];
        let line_start = cached.preview.start as usize;
        let line_end = cached.line_end as usize;
        let (submatches, submatches_truncated) =
            matcher.preview_submatches(&payload[line_start..line_end], preview.len(), budget)?;
        let item = SearchMatch {
            commit_oid: snapshot.commit_oid,
            blob_oid: candidate.oid,
            path: candidate.path.clone(),
            line: cached.line,
            column: cached.column,
            preview: preview.to_vec(),
            preview_truncated: cached.preview.end < cached.line_end,
            submatches,
            submatches_truncated,
            context_before: materialize_lines(payload, cached.context_before),
            context_after: materialize_lines(payload, cached.context_after),
        };
        let item_bytes = item.payload_bytes();
        let ordinal = u32::try_from(ordinal).map_err(|_| {
            Error::new(
                ErrorCode::ResultTooLarge,
                "one file has too many matching lines for a search cursor",
            )
            .with_limit("max_result_bytes")
        })?;
        if payload_bytes.saturating_add(item_bytes) > opts.max_result_bytes {
            if matches.is_empty() {
                // An unsplittable first item is progress even when the caller's
                // byte budget is smaller than the structurally bounded item.
                // The continuation prevents this path from jamming forever.
                *payload_bytes = payload_bytes.saturating_add(item_bytes);
                matches.push(item);
                positions.push((candidate.path.clone(), ordinal));
            }
            return Ok(EmitOutcome::Stopped("max_result_bytes"));
        }
        *payload_bytes = payload_bytes.saturating_add(item_bytes);
        matches.push(item);
        positions.push((candidate.path.clone(), ordinal));
    }
    Ok(EmitOutcome::Complete)
}

fn fit_cursor(
    snapshot: &Snapshot,
    fingerprint: u64,
    max_result_bytes: u64,
    matches: &mut Vec<SearchMatch>,
    positions: &mut Vec<(Vec<u8>, u32)>,
    payload_bytes: &mut u64,
    stopped_by: &mut Option<&'static str>,
) -> Result<Option<Vec<u8>>, Error> {
    loop {
        let Some((path, ordinal)) = positions.last() else {
            return Err(Error::new(
                ErrorCode::BudgetExceeded,
                "budget exhausted before any search pagination progress",
            )
            .with_limit(stopped_by.unwrap_or("budget")));
        };
        let mut position = ordinal.to_le_bytes().to_vec();
        position.extend_from_slice(path);
        let encoded = cursor::encode(&Cursor {
            hash_kind: snapshot.commit_oid.kind(),
            snapshot_digest: snapshot.commit_oid.as_bytes().to_vec(),
            operation_tag: OPERATION_SEARCH,
            option_fingerprint: fingerprint,
            generation: Vec::new(),
            position,
        });
        if encoded.len() > MAX_CURSOR_BYTES {
            if matches.len() == 1 {
                return Err(Error::new(
                    ErrorCode::ResultTooLarge,
                    "search continuation path exceeds the cursor size limit",
                ));
            }
            let removed = matches
                .pop()
                .expect("cursor positions and search matches have equal length");
            positions.pop();
            *payload_bytes = payload_bytes.saturating_sub(removed.payload_bytes());
            *stopped_by = Some("max_result_bytes");
            continue;
        }
        let first_item_alone_exceeds = matches.len() == 1 && *payload_bytes > max_result_bytes;
        if first_item_alone_exceeds
            || payload_bytes.saturating_add(encoded.len() as u64) <= max_result_bytes
        {
            return Ok(Some(encoded));
        }
        if matches.len() == 1 {
            return Err(Error::new(
                ErrorCode::BudgetExceeded,
                "budget exhausted before any search pagination progress",
            )
            .with_limit("max_result_bytes"));
        }
        let removed = matches
            .pop()
            .expect("cursor positions and search matches have equal length");
        positions.pop();
        *payload_bytes = payload_bytes.saturating_sub(removed.payload_bytes());
        *stopped_by = Some("max_result_bytes");
    }
}

fn decode_resume(
    snapshot: &Snapshot,
    opts: &SearchOptions,
    fingerprint: u64,
) -> Result<Option<(Vec<u8>, u32)>, Error> {
    let Some(bytes) = opts.cursor.as_deref() else {
        return Ok(None);
    };
    let decoded = cursor::decode(
        bytes,
        CursorExpected {
            hash_kind: snapshot.commit_oid.kind(),
            snapshot_digest: snapshot.commit_oid.as_bytes(),
            operation_tag: OPERATION_SEARCH,
            option_fingerprint: fingerprint,
        },
    )?;
    if !decoded.generation.is_empty() {
        return Err(invalid_cursor(
            "generation check failed for this object store",
        ));
    }
    let ordinal_bytes = decoded
        .position
        .get(..4)
        .ok_or_else(|| invalid_cursor("position is missing its match ordinal"))?;
    let path = decoded.position[4..].to_vec();
    if path.is_empty() {
        return Err(invalid_cursor("position is missing its path"));
    }
    validate_path(&path).map_err(|_| invalid_cursor("position path check failed"))?;
    if !opts.path.is_empty()
        && !(path.starts_with(&opts.path)
            && path.get(opts.path.len()) == Some(&b'/')
            && path.len() > opts.path.len() + 1)
    {
        return Err(invalid_cursor("position path is outside the searched tree"));
    }
    let ordinal = u32::from_le_bytes(
        ordinal_bytes
            .try_into()
            .expect("a four-byte cursor ordinal slice has fixed length"),
    );
    Ok(Some((path, ordinal)))
}

fn validate_options(opts: &SearchOptions) -> Result<(), Error> {
    validate_path(&opts.path)?;
    if opts.limit == 0 {
        return Err(Error::new(
            ErrorCode::InvalidArgument,
            "search page limit must be greater than zero",
        ));
    }
    if opts.max_result_bytes == 0 {
        return Err(Error::new(
            ErrorCode::InvalidArgument,
            "search max_result_bytes must be greater than zero",
        ));
    }
    if opts.context_lines > MAX_CONTEXT_LINES {
        return Err(Error::new(
            ErrorCode::InvalidArgument,
            format!("context_lines must not exceed {MAX_CONTEXT_LINES}"),
        ));
    }
    Ok(())
}

fn escaped_literal(query: &[u8]) -> String {
    let mut pattern = String::with_capacity(query.len().saturating_mul(4));
    for byte in query {
        use std::fmt::Write;
        let _ = write!(pattern, "\\x{byte:02X}");
    }
    pattern
}

fn option_fingerprint(query: &[u8], opts: &SearchOptions) -> u64 {
    let mut normalized = b"gitility:search:options:v1\0".to_vec();
    push_bytes(&mut normalized, query);
    normalized.push(match opts.mode {
        SearchMode::Literal => 0,
        SearchMode::Regex => 1,
    });
    normalized.push(u8::from(opts.case_sensitive));
    push_bytes(&mut normalized, &opts.path);
    normalized.extend_from_slice(
        &u32::try_from(opts.pathspecs.len())
            .unwrap_or(u32::MAX)
            .to_le_bytes(),
    );
    let mut pathspecs = opts.pathspecs.iter().collect::<Vec<_>>();
    pathspecs.sort_unstable();
    for pathspec in pathspecs {
        push_bytes(&mut normalized, pathspec);
    }
    normalized.push(match opts.binary {
        SearchBinaryMode::Skip => 0,
        SearchBinaryMode::Text => 1,
    });
    normalized.extend_from_slice(&opts.context_lines.to_le_bytes());
    cursor::fnv1a_64(&normalized)
}

fn push_bytes(out: &mut Vec<u8>, bytes: &[u8]) {
    out.extend_from_slice(&u32::try_from(bytes.len()).unwrap_or(u32::MAX).to_le_bytes());
    out.extend_from_slice(bytes);
}

fn truncatable(error: &Error) -> bool {
    error.code == ErrorCode::BudgetExceeded
        && !matches!(
            error.limit,
            Some("max_provider_requests" | "max_provider_bytes")
        )
}

fn unsupported_regex(reason: String) -> Error {
    Error::new(
        ErrorCode::UnsupportedRegex,
        "regular expression is unsupported",
    )
    .with_reason(reason)
}

fn missing_blob(oid: Oid) -> Error {
    Error::retryable(
        ErrorCode::MissingObject,
        format!("blob object {oid} is missing from the object store"),
    )
    .with_oid(oid)
}

fn invalid_cursor(message: &'static str) -> Error {
    Error::new(ErrorCode::InvalidCursor, message)
}

fn result_too_large() -> Error {
    Error::new(
        ErrorCode::ResultTooLarge,
        "search match position exceeds the supported result range",
    )
    .with_limit("max_result_bytes")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::budget::BudgetLimits;
    use crate::local_odb::LocalOdb;
    use crate::object::{HashKind, ObjectHeader};
    use crate::odb::HeaderRead;
    use crate::static_odb::StaticOdb;
    use crate::test_support::{fixture_oid, fixture_repo};
    use crate::tree::{list_tree, TreeOptions};
    use crate::verify::object_id;
    use std::collections::HashMap;
    use std::process::Command;
    use std::sync::atomic::AtomicBool;
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    fn fixture() -> (LocalOdb, Snapshot) {
        let (store, _) = LocalOdb::open(fixture_repo("sha1-search.git"), Default::default())
            .expect("search fixture opens");
        let snapshot = Snapshot::open(
            &store,
            fixture_oid("sha1_search_head"),
            &Budget::unlimited(),
        )
        .expect("search snapshot opens");
        (store, snapshot)
    }

    fn run(
        store: &dyn ObjectDb,
        snapshot: &Snapshot,
        query: &[u8],
        opts: SearchOptions,
    ) -> SearchPage {
        search(store, snapshot, query, &opts, &Budget::unlimited()).expect("search succeeds")
    }

    fn object(kind: ObjectKind, payload: Vec<u8>) -> (Oid, ObjectKind, Vec<u8>) {
        let oid = object_id(HashKind::Sha1, kind, &payload).expect("test object hashes");
        (oid, kind, payload)
    }

    fn tree_payload(entries: &[(u32, &[u8], Oid)]) -> Vec<u8> {
        let mut payload = Vec::new();
        for (mode, name, oid) in entries {
            payload.extend_from_slice(format!("{mode:o} ").as_bytes());
            payload.extend_from_slice(name);
            payload.push(0);
            payload.extend_from_slice(oid.as_bytes());
        }
        payload
    }

    fn snapshot_store(files: &[(&[u8], Vec<u8>)]) -> (StaticOdb, Snapshot, Vec<Oid>) {
        let mut addressed = HashMap::new();
        let mut entries = Vec::new();
        let mut blob_oids = Vec::new();
        for (name, payload) in files {
            let object = object(ObjectKind::Blob, payload.clone());
            blob_oids.push(object.0);
            entries.push((0o100644, *name, object.0));
            addressed.insert(object.0, object);
        }
        entries.sort_unstable_by(|left, right| left.1.cmp(right.1));
        let tree = object(ObjectKind::Tree, tree_payload(&entries));
        let commit_payload = format!(
            "tree {}\nauthor T <t@example.invalid> 1 +0000\ncommitter T <t@example.invalid> 1 +0000\n\ntest\n",
            tree.0.to_hex()
        )
        .into_bytes();
        let commit = object(ObjectKind::Commit, commit_payload);
        let snapshot = Snapshot {
            commit_oid: commit.0,
            tree_oid: tree.0,
        };
        addressed.insert(tree.0, tree);
        addressed.insert(commit.0, commit);
        let store = StaticOdb::from_addressed_objects(HashKind::Sha1, addressed.into_values())
            .expect("test store loads");
        (store, snapshot, blob_oids)
    }

    #[derive(Clone)]
    struct CountingProviderDouble {
        inner: StaticOdb,
        headers: Arc<Mutex<Vec<Oid>>>,
        finds: Arc<Mutex<Vec<Oid>>>,
        prefetches: Arc<Mutex<Vec<Vec<Oid>>>>,
    }

    impl CountingProviderDouble {
        fn new(inner: StaticOdb) -> Self {
            Self {
                inner,
                headers: Arc::new(Mutex::new(Vec::new())),
                finds: Arc::new(Mutex::new(Vec::new())),
                prefetches: Arc::new(Mutex::new(Vec::new())),
            }
        }
    }

    impl ObjectDb for CountingProviderDouble {
        fn hash_kind(&self) -> HashKind {
            self.inner.hash_kind()
        }

        fn try_header(&self, oid: &Oid, budget: &Budget) -> Result<Option<ObjectHeader>, Error> {
            self.headers.lock().expect("header probe locks").push(*oid);
            self.inner.try_header(oid, budget)
        }

        fn try_find(
            &self,
            oid: &Oid,
            out: &mut Vec<u8>,
            budget: &Budget,
        ) -> Result<Option<ObjectKind>, Error> {
            self.finds.lock().expect("find probe locks").push(*oid);
            self.inner.try_find(oid, out, budget)
        }

        fn prefetch(&self, oids: &[Oid], _budget: &Budget) -> Result<(), Error> {
            self.prefetches
                .lock()
                .expect("prefetch probe locks")
                .push(oids.to_vec());
            Ok(())
        }

        fn supports_prefetch(&self) -> bool {
            true
        }
    }

    struct LyingHeaderStore {
        inner: StaticOdb,
        blob_oid: Oid,
    }

    impl ObjectDb for LyingHeaderStore {
        fn hash_kind(&self) -> HashKind {
            self.inner.hash_kind()
        }

        fn try_header(&self, oid: &Oid, budget: &Budget) -> Result<Option<ObjectHeader>, Error> {
            self.try_header_with_provenance(oid, budget)
                .map(|header| header.map(|read| read.header))
        }

        fn try_header_with_provenance(
            &self,
            oid: &Oid,
            budget: &Budget,
        ) -> Result<Option<HeaderRead>, Error> {
            if *oid == self.blob_oid {
                budget.charge_header()?;
                return Ok(Some(HeaderRead {
                    header: ObjectHeader {
                        kind: ObjectKind::Blob,
                        size: 1,
                    },
                    provenance: HeaderProvenance::UnverifiedProvider,
                }));
            }
            self.inner.try_header_with_provenance(oid, budget)
        }

        fn try_find(
            &self,
            oid: &Oid,
            out: &mut Vec<u8>,
            budget: &Budget,
        ) -> Result<Option<ObjectKind>, Error> {
            self.inner.try_find(oid, out, budget)
        }
    }

    #[test]
    fn literal_search_is_line_oriented_byte_preserving_and_groups_occurrences() {
        let (store, snapshot) = fixture();
        let page = run(&store, &snapshot, b"needle", SearchOptions::default());
        assert!(!page.truncated);
        assert_eq!(page.stats.binary_skipped, 2);
        assert_eq!(page.stats.oversize_skipped, 0);
        assert_eq!(page.stats.blobs_deduped, 2);
        assert_eq!(page.matches.len(), 53);

        let crlf = page
            .matches
            .iter()
            .find(|item| item.path == b"crlf.txt")
            .expect("CRLF result exists");
        assert_eq!(crlf.line, 2);
        assert_eq!(crlf.column, 0);
        assert_eq!(crlf.preview, b"needle on crlf\r");

        let latin1 = page
            .matches
            .iter()
            .find(|item| item.path == b"latin1.txt")
            .expect("non-UTF-8 result exists");
        assert_eq!(latin1.preview, b"caf\xe9 needle latin-1");
        assert_eq!(latin1.column, 5);

        let last = page
            .matches
            .iter()
            .find(|item| item.path == b"final-no-newline.txt")
            .expect("unterminated final line result exists");
        assert_eq!((last.line, last.column), (1, 15));

        let grouped = page
            .matches
            .iter()
            .find(|item| item.path == b"many-on-one-line.txt")
            .expect("grouped result exists");
        assert_eq!(grouped.submatches.len(), 5);
        assert!(!grouped.submatches_truncated);
        assert_eq!(grouped.column, 0);
        assert_eq!(grouped.submatches[1].start, 7);
    }

    #[test]
    fn case_folding_is_ascii_and_regex_is_bounded_and_line_oriented() {
        let (store, snapshot) = fixture();
        let insensitive = run(
            &store,
            &snapshot,
            b"needle",
            SearchOptions {
                case_sensitive: false,
                pathspecs: vec![b"deep/**".to_vec()],
                ..SearchOptions::default()
            },
        );
        assert_eq!(insensitive.matches.len(), 1);
        assert_eq!(insensitive.matches[0].column, 5);
        assert_eq!(insensitive.matches[0].submatches.len(), 2);

        let regex = run(
            &store,
            &snapshot,
            br"needle on crlf\r$",
            SearchOptions {
                mode: SearchMode::Regex,
                ..SearchOptions::default()
            },
        );
        assert_eq!(regex.matches.len(), 1);
        assert_eq!(regex.matches[0].path, b"crlf.txt");

        for pattern in [br"(needle)\1".as_slice(), br"needle(?= on)".as_slice()] {
            let error = search(
                &store,
                &snapshot,
                pattern,
                &SearchOptions {
                    mode: SearchMode::Regex,
                    ..SearchOptions::default()
                },
                &Budget::unlimited(),
            )
            .expect_err("unsupported construct is rejected");
            assert_eq!(error.code, ErrorCode::UnsupportedRegex);
            assert!(error.reason.is_some());
        }

        let oversized = search(
            &store,
            &snapshot,
            b"a{1000000}",
            &SearchOptions {
                mode: SearchMode::Regex,
                ..SearchOptions::default()
            },
            &Budget::unlimited(),
        )
        .expect_err("compiled regex size ceiling is enforced");
        assert_eq!(oversized.code, ErrorCode::UnsupportedRegex);
        assert!(oversized.reason.is_some());
    }

    #[test]
    fn context_preview_binary_and_oversize_policies_are_explicit() {
        let (store, snapshot) = fixture();
        let contextual = run(
            &store,
            &snapshot,
            b"needle on crlf",
            SearchOptions {
                context_lines: 1,
                ..SearchOptions::default()
            },
        );
        assert_eq!(contextual.matches[0].context_before, [b"first\r"]);
        assert_eq!(contextual.matches[0].context_after, [b"last\r"]);

        let long_preview = run(
            &store,
            &snapshot,
            b"x",
            SearchOptions {
                pathspecs: vec![b"after-8000.txt".to_vec()],
                ..SearchOptions::default()
            },
        );
        assert_eq!(long_preview.matches.len(), 1);
        assert_eq!(long_preview.matches[0].preview.len(), PREVIEW_BYTES);
        assert!(long_preview.matches[0].preview_truncated);

        let binary = run(
            &store,
            &snapshot,
            b"needle",
            SearchOptions {
                binary: SearchBinaryMode::Text,
                pathspecs: vec![b"binary-with-needle.dat".to_vec()],
                ..SearchOptions::default()
            },
        );
        assert_eq!(binary.matches.len(), 1);
        assert_eq!(binary.matches[0].path, b"binary-with-needle.dat");
        assert_eq!(binary.matches[0].column, 27);

        let budget = Budget::new(
            BudgetLimits {
                max_object_bytes: 8_000,
                ..BudgetLimits::default()
            },
            None,
            Arc::new(AtomicBool::new(false)),
        );
        let oversize = search(
            &store,
            &snapshot,
            b"needle",
            &SearchOptions {
                pathspecs: vec![b"after-8000.txt".to_vec()],
                ..SearchOptions::default()
            },
            &budget,
        )
        .expect("oversize blob is skipped successfully");
        assert!(oversize.matches.is_empty());
        assert_eq!(oversize.stats.oversize_skipped, 1);
        assert_eq!(oversize.stats.files_scanned, 0);
    }

    #[test]
    fn binary_probe_boundary_symlink_and_byte_columns_are_pinned() {
        let (store, snapshot) = fixture();
        let boundary = run(
            &store,
            &snapshot,
            b"needle",
            SearchOptions {
                pathspecs: vec![b"nul-at-7999.dat".to_vec(), b"nul-at-8000.dat".to_vec()],
                ..SearchOptions::default()
            },
        );
        assert_eq!(boundary.stats.binary_skipped, 1);
        assert_eq!(boundary.matches.len(), 1);
        assert_eq!(boundary.matches[0].path, b"nul-at-8000.dat");
        assert_eq!(boundary.matches[0].column, 8_001);
        assert!(boundary.matches[0].submatches.is_empty());
        assert!(boundary.matches[0].submatches_truncated);

        let as_text = run(
            &store,
            &snapshot,
            b"needle",
            SearchOptions {
                binary: SearchBinaryMode::Text,
                pathspecs: vec![b"nul-at-7999.dat".to_vec(), b"nul-at-8000.dat".to_vec()],
                ..SearchOptions::default()
            },
        );
        assert_eq!(as_text.matches.len(), 2);

        let columns = run(
            &store,
            &snapshot,
            b"needle",
            SearchOptions {
                pathspecs: vec![b"utf8-column.txt".to_vec(), b"tab-column.txt".to_vec()],
                ..SearchOptions::default()
            },
        );
        assert_eq!(columns.matches[0].path, b"tab-column.txt");
        assert_eq!(columns.matches[0].column, 1);
        assert_eq!(columns.matches[1].path, b"utf8-column.txt");
        assert_eq!(columns.matches[1].column, 6);

        let symlink = run(
            &store,
            &snapshot,
            b"needle-target",
            SearchOptions::default(),
        );
        assert!(symlink.matches.is_empty());
    }

    #[test]
    fn dedup_scans_one_blob_but_reports_every_path() {
        let (store, snapshot) = fixture();
        let page = run(
            &store,
            &snapshot,
            b"needle",
            SearchOptions {
                path: b"dedup".to_vec(),
                ..SearchOptions::default()
            },
        );
        assert_eq!(page.matches.len(), 3);
        assert_eq!(page.stats.files_scanned, 1);
        assert_eq!(page.stats.blobs_deduped, 2);
        assert_eq!(page.stats.payload_rereads, 2);
    }

    #[test]
    fn p12_unsplittable_match_pages_to_completion() {
        let big = vec![b'x'; 2 * 1_024 * 1_024];
        let (store, snapshot, _) = snapshot_store(&[
            (b"a-bundle.js", big),
            (b"b-normal.txt", b"x normal\n".to_vec()),
        ]);
        let mut cursor = None;
        let mut reconstructed = Vec::new();
        let mut pages = 0;
        loop {
            let page = run(
                &store,
                &snapshot,
                b"x",
                SearchOptions {
                    limit: 1,
                    max_result_bytes: 500,
                    cursor,
                    ..SearchOptions::default()
                },
            );
            pages += 1;
            reconstructed.extend(page.matches.clone());
            cursor = page.next_cursor;
            if cursor.is_none() {
                break;
            }
            assert!(pages < 5, "pagination must make progress");
        }
        assert_eq!(pages, 2);
        assert_eq!(reconstructed.len(), 2);
        assert_eq!(reconstructed[0].path, b"a-bundle.js");
        assert_eq!(reconstructed[0].submatches.len(), MAX_SUBMATCHES);
        assert!(reconstructed[0].submatches_truncated);
        assert_eq!(reconstructed[1].path, b"b-normal.txt");
        eprintln!("P12 pagination: 2 MiB line completed in {pages} pages");
    }

    #[test]
    fn scan_cache_retains_fixed_spans_and_dedup_rereads_once_per_path() {
        let payload = (0..4_000)
            .flat_map(|line| format!("line {line:04} needle\n").into_bytes())
            .collect::<Vec<_>>();
        let matcher = CompiledMatcher::Literal(b"needle".to_vec());
        let no_context =
            scan_payload(&payload, &matcher, 0, &Budget::unlimited()).expect("span scan succeeds");
        let max_context = scan_payload(&payload, &matcher, MAX_CONTEXT_LINES, &Budget::unlimited())
            .expect("context span scan succeeds");
        let retained_without = no_context.len() * std::mem::size_of::<CachedLineMatch>();
        let retained_with = max_context.len() * std::mem::size_of::<CachedLineMatch>();
        assert_eq!(retained_with, retained_without);
        assert!(retained_with < payload.len().saturating_mul(4));
        eprintln!(
            "scan-cache spans: context0={retained_without} bytes context32={retained_with} bytes"
        );

        let shared = b"needle shared\n".to_vec();
        let (inner, snapshot, _) = snapshot_store(&[
            (b"a.txt", shared.clone()),
            (b"b.txt", shared.clone()),
            (b"c.txt", shared),
        ]);
        let store = CountingProviderDouble::new(inner);
        let page = run(&store, &snapshot, b"needle", SearchOptions::default());
        assert_eq!(page.matches.len(), 3);
        assert_eq!(page.stats.files_scanned, 1);
        assert_eq!(page.stats.blobs_deduped, 2);
        assert_eq!(page.stats.payload_rereads, 2);
        assert_eq!(page.stats.objects_read, 2);
    }

    #[test]
    fn lru_eviction_rescans_deterministically_without_cloning_results() {
        let shared = b"needle shared\n".to_vec();
        let other = b"needle other\n".to_vec();
        let (inner, snapshot, blob_oids) = snapshot_store(&[
            (b"a.txt", shared.clone()),
            (b"b.txt", other),
            (b"c.txt", shared),
        ]);
        let shared_oid = blob_oids[0];

        let baseline_store = CountingProviderDouble::new(inner.clone());
        let baseline = search_with_cache_capacity(
            &baseline_store,
            &snapshot,
            b"needle",
            &SearchOptions::default(),
            &Budget::unlimited(),
            8,
        )
        .expect("baseline search succeeds");
        let baseline_headers = baseline_store
            .headers
            .lock()
            .expect("header probe locks")
            .iter()
            .filter(|oid| **oid == shared_oid)
            .count();

        let evicting_store = CountingProviderDouble::new(inner);
        let evicted = search_with_cache_capacity(
            &evicting_store,
            &snapshot,
            b"needle",
            &SearchOptions::default(),
            &Budget::unlimited(),
            1,
        )
        .expect("evicting search succeeds");
        let evicted_headers = evicting_store
            .headers
            .lock()
            .expect("header probe locks")
            .iter()
            .filter(|oid| **oid == shared_oid)
            .count();

        assert_eq!(evicted.matches, baseline.matches);
        assert_eq!(baseline_headers, 1);
        assert_eq!(evicted_headers, 2);
        assert_eq!(evicted.stats.payload_rereads, 1);
    }

    #[test]
    fn cursor_pages_reconstruct_results_and_bind_every_stream_option() {
        let (store, snapshot) = fixture();
        let complete = run(
            &store,
            &snapshot,
            b"needle",
            SearchOptions {
                path: b"pages".to_vec(),
                ..SearchOptions::default()
            },
        );
        assert_eq!(complete.matches.len(), 40);

        let mut cursor = None;
        let mut reconstructed = Vec::new();
        loop {
            let page = run(
                &store,
                &snapshot,
                b"needle",
                SearchOptions {
                    path: b"pages".to_vec(),
                    limit: 7,
                    cursor,
                    ..SearchOptions::default()
                },
            );
            reconstructed.extend(page.matches);
            cursor = page.next_cursor;
            if cursor.is_none() {
                break;
            }
        }
        assert_eq!(reconstructed, complete.matches);

        let first = run(
            &store,
            &snapshot,
            b"needle",
            SearchOptions {
                path: b"pages".to_vec(),
                limit: 3,
                ..SearchOptions::default()
            },
        );
        let cursor = first.next_cursor.expect("small page has a cursor");
        let decoded = cursor::decode(
            &cursor,
            CursorExpected {
                hash_kind: snapshot.commit_oid.kind(),
                snapshot_digest: snapshot.commit_oid.as_bytes(),
                operation_tag: OPERATION_SEARCH,
                option_fingerprint: option_fingerprint(
                    b"needle",
                    &SearchOptions {
                        path: b"pages".to_vec(),
                        ..SearchOptions::default()
                    },
                ),
            },
        )
        .expect("cursor decodes");
        assert_eq!(&decoded.position[..4], &2u32.to_le_bytes());
        assert_eq!(&decoded.position[4..], b"pages/many-lines.txt");

        for changed in [
            SearchOptions {
                mode: SearchMode::Regex,
                path: b"pages".to_vec(),
                cursor: Some(cursor.clone()),
                ..SearchOptions::default()
            },
            SearchOptions {
                case_sensitive: false,
                path: b"pages".to_vec(),
                cursor: Some(cursor.clone()),
                ..SearchOptions::default()
            },
            SearchOptions {
                binary: SearchBinaryMode::Text,
                path: b"pages".to_vec(),
                cursor: Some(cursor.clone()),
                ..SearchOptions::default()
            },
            SearchOptions {
                context_lines: 1,
                path: b"pages".to_vec(),
                cursor: Some(cursor.clone()),
                ..SearchOptions::default()
            },
            SearchOptions {
                path: b"pages".to_vec(),
                pathspecs: vec![b"*.txt".to_vec()],
                cursor: Some(cursor.clone()),
                ..SearchOptions::default()
            },
        ] {
            let error = search(&store, &snapshot, b"needle", &changed, &Budget::unlimited())
                .expect_err("changed stream option invalidates the cursor");
            assert_eq!(error.code, ErrorCode::InvalidCursor);
        }
        let error = search(
            &store,
            &snapshot,
            b"needlE",
            &SearchOptions {
                path: b"pages".to_vec(),
                cursor: Some(cursor),
                ..SearchOptions::default()
            },
            &Budget::unlimited(),
        )
        .expect_err("changed query invalidates the cursor");
        assert_eq!(error.code, ErrorCode::InvalidCursor);
    }

    #[test]
    fn result_byte_and_object_limits_truncate_only_after_progress() {
        let (store, snapshot) = fixture();
        let byte_page = run(
            &store,
            &snapshot,
            b"needle",
            SearchOptions {
                path: b"pages".to_vec(),
                max_result_bytes: 500,
                ..SearchOptions::default()
            },
        );
        assert!(byte_page.truncated);
        assert_eq!(byte_page.stats.stopped_by, Some("max_result_bytes"));
        assert!(byte_page.next_cursor.is_some());

        let forced_progress = search(
            &store,
            &snapshot,
            b"needle",
            &SearchOptions {
                path: b"pages".to_vec(),
                max_result_bytes: 1,
                ..SearchOptions::default()
            },
            &Budget::unlimited(),
        )
        .expect("an unsplittable first result makes progress");
        assert_eq!(forced_progress.matches.len(), 1);
        assert!(forced_progress.truncated);
        assert_eq!(forced_progress.stats.stopped_by, Some("max_result_bytes"));

        let object_budget = Budget::new(
            BudgetLimits {
                max_objects: 1,
                ..BudgetLimits::default()
            },
            None,
            Arc::new(AtomicBool::new(false)),
        );
        let object_error = search(
            &store,
            &snapshot,
            b"needle",
            &SearchOptions {
                path: b"dedup".to_vec(),
                ..SearchOptions::default()
            },
            &object_budget,
        )
        .expect_err("live tree reads consume the object budget before a match");
        assert_eq!(object_error.code, ErrorCode::BudgetExceeded);
        assert_eq!(object_error.limit, Some("max_objects"));
    }

    #[test]
    fn literal_deadline_interrupts_between_overlapped_windows() {
        let line = vec![b'a'; 64 * 1_024 * 1_024];
        let query = vec![b'a'; 4_095]
            .into_iter()
            .chain(std::iter::once(b'b'))
            .collect::<Vec<_>>();
        let deadline = Instant::now() + Duration::from_millis(2);
        let budget = Budget::new(
            BudgetLimits {
                max_object_bytes: u64::MAX,
                max_total_object_bytes: u64::MAX,
                ..BudgetLimits::default()
            },
            Some(deadline),
            Arc::new(AtomicBool::new(false)),
        );
        let started = Instant::now();
        let error = CompiledMatcher::Literal(query)
            .first_occurrence(&line, &budget)
            .expect_err("deadline lands during a multi-window literal scan");
        assert_eq!(error.code, ErrorCode::Timeout);
        eprintln!(
            "literal window deadline observed after {:?}",
            started.elapsed()
        );
    }

    #[test]
    fn live_walk_and_list_tree_spend_the_same_tree_object_budget() {
        let blob = object(ObjectKind::Blob, b"needle\n".to_vec());
        let blob_oid = blob.0;
        let mut objects = vec![blob];
        let mut current = object(
            ObjectKind::Tree,
            tree_payload(&[(0o100644, b"hit.txt", blob_oid)]),
        );
        objects.push(current.clone());
        for _ in 0..300 {
            current = object(
                ObjectKind::Tree,
                tree_payload(&[(0o040000, b"d", current.0)]),
            );
            objects.push(current.clone());
        }
        let commit = object(
            ObjectKind::Commit,
            format!(
                "tree {}\nauthor T <t@example.invalid> 1 +0000\ncommitter T <t@example.invalid> 1 +0000\n\ntest\n",
                current.0.to_hex()
            )
            .into_bytes(),
        );
        let snapshot = Snapshot {
            commit_oid: commit.0,
            tree_oid: current.0,
        };
        objects.push(commit);
        let store =
            StaticOdb::from_addressed_objects(HashKind::Sha1, objects).expect("deep store loads");
        let limits = BudgetLimits {
            max_objects: 5,
            ..BudgetLimits::default()
        };
        let tree_budget = Budget::new(limits, None, Arc::new(AtomicBool::new(false)));
        let tree_page = list_tree(
            &store,
            &snapshot,
            &TreeOptions {
                recursive: true,
                ..TreeOptions::default()
            },
            &tree_budget,
        )
        .expect("list_tree truncates after progress");
        assert!(tree_page.truncated);
        assert_eq!(tree_page.stats.stopped_by, Some("max_objects"));

        let search_budget = Budget::new(limits, None, Arc::new(AtomicBool::new(false)));
        let error = search(
            &store,
            &snapshot,
            b"needle",
            &SearchOptions::default(),
            &search_budget,
        )
        .expect_err("search refuses before reaching the deeply nested blob");
        assert_eq!(error.code, ErrorCode::BudgetExceeded);
        assert_eq!(error.limit, Some("max_objects"));
        assert_eq!(tree_budget.spent().0, 5);
        assert_eq!(search_budget.spent().0, 5);
        eprintln!("P16 object reads: list_tree=5 search=5");
    }

    #[test]
    fn resume_prefix_is_uncharged_but_position_blob_is_charged() {
        let (store, snapshot) = fixture();
        let first = run(
            &store,
            &snapshot,
            b"needle",
            SearchOptions {
                path: b"pages".to_vec(),
                limit: 1,
                ..SearchOptions::default()
            },
        );
        let budget = Budget::new(
            BudgetLimits {
                max_objects: 1,
                ..BudgetLimits::default()
            },
            None,
            Arc::new(AtomicBool::new(false)),
        );
        let resumed = search(
            &store,
            &snapshot,
            b"needle",
            &SearchOptions {
                path: b"pages".to_vec(),
                limit: 1,
                cursor: first.next_cursor,
                ..SearchOptions::default()
            },
            &budget,
        )
        .expect("resume replay leaves one object visit for the position blob");
        assert_eq!(resumed.matches.len(), 1);
        assert_eq!(resumed.matches[0].line, 2);
    }

    #[test]
    fn lying_header_object_too_large_is_an_oversize_skip() {
        let payload = vec![b'x'; 256];
        let (inner, snapshot, blob_oids) = snapshot_store(&[(b"large.txt", payload)]);
        let store = LyingHeaderStore {
            inner,
            blob_oid: blob_oids[0],
        };
        let budget = Budget::new(
            BudgetLimits {
                max_object_bytes: 128,
                ..BudgetLimits::default()
            },
            None,
            Arc::new(AtomicBool::new(false)),
        );
        let page = search(&store, &snapshot, b"x", &SearchOptions::default(), &budget)
            .expect("lying provider size degrades to an oversize skip");
        assert!(page.matches.is_empty());
        assert_eq!(page.stats.oversize_skipped, 1);
    }

    #[test]
    fn unique_blob_prefetches_are_batched_in_windows_of_sixty_four() {
        let owned = (0..130)
            .map(|index| {
                (
                    format!("file-{index:03}.txt").into_bytes(),
                    format!("needle {index}\n").into_bytes(),
                )
            })
            .collect::<Vec<_>>();
        let borrowed = owned
            .iter()
            .map(|(name, payload)| (name.as_slice(), payload.clone()))
            .collect::<Vec<_>>();
        let (inner, snapshot, blob_oids) = snapshot_store(&borrowed);
        let store = CountingProviderDouble::new(inner);
        let page = run(&store, &snapshot, b"needle", SearchOptions::default());
        assert_eq!(page.matches.len(), 130);
        let batches = store.prefetches.lock().expect("prefetch probe locks");
        assert_eq!(batches.len(), 3);
        assert!(batches
            .iter()
            .all(|batch| !batch.is_empty() && batch.len() <= 64));
        let prefetched = batches.iter().flatten().copied().collect::<HashSet<_>>();
        assert_eq!(prefetched.len(), blob_oids.len());
        assert_eq!(prefetched, blob_oids.into_iter().collect());
        eprintln!(
            "blob prefetch: 130 unique blobs in {} batches",
            batches.len()
        );
    }

    #[test]
    fn cursor_fingerprint_sorts_or_pathspecs_and_context_cap_is_pinned() {
        assert_eq!(MAX_CONTEXT_LINES, 32);
        let (store, snapshot) = fixture();
        let first = run(
            &store,
            &snapshot,
            b"needle",
            SearchOptions {
                pathspecs: vec![b"pages/**".to_vec(), b"dedup/**".to_vec()],
                limit: 1,
                ..SearchOptions::default()
            },
        );
        let resumed = run(
            &store,
            &snapshot,
            b"needle",
            SearchOptions {
                pathspecs: vec![b"dedup/**".to_vec(), b"pages/**".to_vec()],
                limit: 1,
                cursor: first.next_cursor,
                ..SearchOptions::default()
            },
        );
        assert_eq!(resumed.matches.len(), 1);
    }

    #[test]
    fn cursor_fitting_reports_actual_result_shaping_and_uses_latest_fitting_path() {
        let (store, snapshot) = fixture();
        drop(store);
        let item = |path: &[u8]| SearchMatch {
            commit_oid: snapshot.commit_oid,
            blob_oid: snapshot.tree_oid,
            path: path.to_vec(),
            line: 1,
            column: 0,
            preview: vec![b'x'; 256],
            preview_truncated: false,
            submatches: vec![SearchSubmatch {
                start: 0,
                length: 1,
            }],
            submatches_truncated: false,
            context_before: Vec::new(),
            context_after: Vec::new(),
        };

        let first = item(b"a.txt");
        let second = item(b"b.txt");
        let mut matches = vec![first.clone(), second];
        let mut positions = vec![(b"a.txt".to_vec(), 0), (b"b.txt".to_vec(), 0)];
        let mut payload_bytes = matches.iter().map(SearchMatch::payload_bytes).sum();
        let max_result_bytes = first.payload_bytes().saturating_add(128);
        let mut stopped_by = Some("limit");
        let cursor = fit_cursor(
            &snapshot,
            7,
            max_result_bytes,
            &mut matches,
            &mut positions,
            &mut payload_bytes,
            &mut stopped_by,
        )
        .expect("an earlier item plus cursor fits");
        assert!(cursor.is_some());
        assert_eq!(matches.len(), 1);
        assert_eq!(stopped_by, Some("max_result_bytes"));

        let long_path = vec![b'p'; MAX_CURSOR_BYTES + 100];
        let mut matches = vec![item(b"short.txt"), item(&long_path)];
        let mut positions = vec![(b"short.txt".to_vec(), 0), (long_path.clone(), 0)];
        let mut payload_bytes = matches.iter().map(SearchMatch::payload_bytes).sum();
        let mut stopped_by = Some("limit");
        let cursor = fit_cursor(
            &snapshot,
            9,
            u64::MAX,
            &mut matches,
            &mut positions,
            &mut payload_bytes,
            &mut stopped_by,
        )
        .expect("latest fitting earlier path is selected");
        assert!(cursor.is_some());
        assert_eq!(matches.len(), 1);

        let mut matches = vec![item(&long_path)];
        let mut positions = vec![(long_path, 0)];
        let mut payload_bytes = matches[0].payload_bytes();
        let mut stopped_by = Some("limit");
        let error = fit_cursor(
            &snapshot,
            11,
            u64::MAX,
            &mut matches,
            &mut positions,
            &mut payload_bytes,
            &mut stopped_by,
        )
        .expect_err("no emitted cursor position fits");
        assert_eq!(error.code, ErrorCode::ResultTooLarge);
    }

    #[test]
    fn invalid_scope_context_and_cursor_position_are_rejected() {
        let (store, snapshot) = fixture();
        let missing = search(
            &store,
            &snapshot,
            b"needle",
            &SearchOptions {
                path: b"missing".to_vec(),
                ..SearchOptions::default()
            },
            &Budget::unlimited(),
        )
        .expect_err("missing scope is invalid");
        assert_eq!(missing.code, ErrorCode::InvalidPath);

        let context = search(
            &store,
            &snapshot,
            b"needle",
            &SearchOptions {
                context_lines: MAX_CONTEXT_LINES + 1,
                ..SearchOptions::default()
            },
            &Budget::unlimited(),
        )
        .expect_err("context cap is enforced");
        assert_eq!(context.code, ErrorCode::InvalidArgument);
    }

    #[test]
    fn literal_positions_match_pinned_git_grep_cases() {
        let (store, snapshot) = fixture();
        let repository = fixture_repo("sha1-search.git");
        let revision = snapshot.commit_oid.to_hex();
        let cases = [
            (false, SearchBinaryMode::Skip, Vec::<Vec<u8>>::new()),
            (true, SearchBinaryMode::Skip, Vec::<Vec<u8>>::new()),
            (
                false,
                SearchBinaryMode::Skip,
                vec![b"deep/**".to_vec(), b"dedup/**".to_vec()],
            ),
            (
                false,
                SearchBinaryMode::Skip,
                // Bare `*.txt` would cross `/` under Git's default dialect;
                // the oracle below prefixes `:(glob)` to match Gitility.
                vec![b"*.txt".to_vec()],
            ),
            (
                false,
                SearchBinaryMode::Skip,
                vec![b"nul-at-7999.dat".to_vec(), b"nul-at-8000.dat".to_vec()],
            ),
            (
                false,
                SearchBinaryMode::Text,
                vec![
                    b"binary-with-needle.dat".to_vec(),
                    b"nul-at-7999.dat".to_vec(),
                    b"nul-at-8000.dat".to_vec(),
                ],
            ),
        ];

        for (ignore_case, binary, pathspecs) in cases {
            let mut arguments = vec![
                "grep".to_owned(),
                "-F".to_owned(),
                if binary == SearchBinaryMode::Skip {
                    "-I".to_owned()
                } else {
                    "-a".to_owned()
                },
                "--line-number".to_owned(),
                "--column".to_owned(),
                "--full-name".to_owned(),
                "-e".to_owned(),
                "needle".to_owned(),
                revision.clone(),
            ];
            if ignore_case {
                arguments.insert(2, "-i".to_owned());
            }
            if !pathspecs.is_empty() {
                arguments.push("--".to_owned());
                arguments.extend(pathspecs.iter().map(|pathspec| {
                    format!(
                        ":(glob){}",
                        String::from_utf8(pathspec.clone()).expect("ASCII fixture")
                    )
                }));
            }
            let output = Command::new("git")
                .args(["-c", "color.ui=false", "-c", "core.quotePath=false", "-C"])
                .arg(&repository)
                .args(&arguments)
                .env("GIT_CONFIG_GLOBAL", "/dev/null")
                .env("GIT_CONFIG_SYSTEM", "/dev/null")
                .env("GIT_TERMINAL_PROMPT", "0")
                .env("LC_ALL", "C")
                .output()
                .expect("git grep starts");
            assert!(
                output.status.success(),
                "git grep failed: {}",
                String::from_utf8_lossy(&output.stderr)
            );
            let expected = parse_git_grep_positions(&output.stdout);
            let actual = run(
                &store,
                &snapshot,
                b"needle",
                SearchOptions {
                    case_sensitive: !ignore_case,
                    binary,
                    pathspecs,
                    ..SearchOptions::default()
                },
            )
            .matches
            .into_iter()
            .map(|item| (item.path, item.line, item.column))
            .collect::<Vec<_>>();
            assert_eq!(actual, expected);
        }
    }

    fn parse_git_grep_positions(output: &[u8]) -> Vec<(Vec<u8>, u32, u32)> {
        output
            .split(|byte| *byte == b'\n')
            .filter(|record| !record.is_empty())
            .map(|record| {
                let separators = record
                    .iter()
                    .enumerate()
                    .filter_map(|(index, byte)| (*byte == b':').then_some(index))
                    .take(4)
                    .collect::<Vec<_>>();
                let [revision, path_end, line_end, column_end] = separators.as_slice() else {
                    panic!("git grep record has four metadata separators");
                };
                let line = std::str::from_utf8(&record[path_end + 1..*line_end])
                    .expect("line is ASCII")
                    .parse::<u32>()
                    .expect("line parses");
                let column = std::str::from_utf8(&record[line_end + 1..*column_end])
                    .expect("column is ASCII")
                    .parse::<u32>()
                    .expect("column parses")
                    .saturating_sub(1);
                (record[revision + 1..*path_end].to_vec(), line, column)
            })
            .collect()
    }
}
