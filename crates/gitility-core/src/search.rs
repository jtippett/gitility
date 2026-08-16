//! Sequential, byte-oriented snapshot content search.
//!
//! Search reuses tree resolution, decoding, ordering, pathspec matching, and
//! provider child-prefetch from [`crate::tree`]. Cursor resume deliberately
//! replays the prefix without charging blob visits, then re-scans the cursor
//! path and continues with strictly greater paths. Its cost is therefore
//! O(prefix paths + one blob re-scan).

use crate::budget::Budget;
use crate::cursor::{self, Cursor, CursorExpected, MAX_CURSOR_BYTES, OPERATION_SEARCH};
use crate::error::{Error, ErrorCode};
use crate::object::{ObjectKind, Oid};
use crate::odb::{HeaderProvenance, ObjectDb};
use crate::pathspec::PathspecMatcher;
use crate::snapshot::Snapshot;
use crate::tree::{
    ensure_query_compatible, join_path, read_tree_entries_for_graph_walk, relative_to_scope,
    resolve_path_for_graph_walk, validate_path, QueryStats, ResolvedPath, TreeItemKind,
};
use bstr::ByteSlice;
use regex::bytes::{Regex, RegexBuilder};
use std::collections::HashMap;

const BINARY_PROBE_BYTES: usize = 8_000;
const PREVIEW_BYTES: usize = 1_024;
const SCAN_CHECK_BYTES: usize = 64 * 1_024;
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

/// One byte range within an uncapped matching line, clamped to the emitted
/// preview. Zero-length regular-expression matches are retained.
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
        let fixed = self
            .commit_oid
            .as_bytes()
            .len()
            .saturating_add(self.blob_oid.as_bytes().len())
            .saturating_add(16)
            .saturating_add(self.submatches.len().saturating_mul(8));
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

#[derive(Debug, Clone, PartialEq, Eq)]
struct CachedLineMatch {
    line: u32,
    column: u32,
    preview: Vec<u8>,
    preview_truncated: bool,
    submatches: Vec<SearchSubmatch>,
    context_before: Vec<Vec<u8>>,
    context_after: Vec<Vec<u8>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum CachedScan {
    Matches(Vec<CachedLineMatch>),
    BinarySkipped,
    OversizeSkipped,
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

    fn occurrences(&self, line: &[u8], budget: &Budget) -> Result<Vec<(usize, usize)>, Error> {
        check_scan_progress(line.len(), budget)?;
        match self {
            Self::Literal(query) if query.is_empty() => {
                Ok((0..=line.len()).map(|offset| (offset, offset)).collect())
            }
            Self::Literal(query) => {
                let mut occurrences = Vec::new();
                let mut offset = 0usize;
                while offset <= line.len().saturating_sub(query.len()) {
                    budget.check()?;
                    let Some(relative) = line[offset..].find(query.as_slice()) else {
                        break;
                    };
                    let start = offset.saturating_add(relative);
                    let end = start.saturating_add(query.len());
                    occurrences.push((start, end));
                    offset = end;
                }
                Ok(occurrences)
            }
            Self::Regex(regex) => {
                let mut occurrences = Vec::new();
                for found in regex.find_iter(line) {
                    budget.check()?;
                    occurrences.push((found.start(), found.end()));
                }
                Ok(occurrences)
            }
        }
    }
}

/// Searches the blobs reachable through one pinned snapshot.
///
/// The scan cache has one entry per unique candidate blob visited in this
/// job. `max_objects` bounds that cardinality, while `max_object_bytes` and
/// `max_total_object_bytes` bound retained match metadata. Cache values retain
/// match positions and capped excerpts only; full blob payloads are dropped
/// immediately after their one sequential scan.
pub fn search(
    store: &dyn ObjectDb,
    snapshot: &Snapshot,
    query: &[u8],
    opts: &SearchOptions,
    budget: &Budget,
) -> Result<SearchPage, Error> {
    ensure_query_compatible(store, snapshot)?;
    validate_options(opts)?;
    budget.check()?;
    let matcher = CompiledMatcher::compile(query, opts)?;
    let fingerprint = option_fingerprint(query, opts);
    let resume = decode_resume(snapshot, opts, fingerprint)?;

    let tree_oid = match resolve_path_for_graph_walk(store, snapshot, &opts.path, budget)? {
        ResolvedPath::RootTree(oid) => oid,
        ResolvedPath::Entry(entry) if entry.kind == TreeItemKind::Tree => entry.oid,
        ResolvedPath::Entry(_) => {
            return Err(Error::new(
                ErrorCode::NotATree,
                "path does not resolve to a tree",
            ))
        }
    };
    let mut walk = BlobWalk::new(store, tree_oid, &opts.path, &opts.pathspecs, budget)?;
    let mut cache = HashMap::<Oid, CachedScan>::new();
    let mut matches = Vec::with_capacity(opts.limit.min(1_024));
    let mut positions = Vec::<(Vec<u8>, u32)>::with_capacity(opts.limit.min(1_024));
    let mut payload_bytes = 0u64;
    let mut found_resume = resume.is_none();
    let mut stopped_by = None;
    let mut files_scanned = 0u64;
    let mut blobs_deduped = 0u64;
    let mut binary_skipped = 0u64;
    let mut oversize_skipped = 0u64;

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

        let scan = if let Some(scan) = cache.get(&candidate.oid) {
            match budget.charge_object_visit() {
                Ok(()) => {}
                Err(error) if truncatable(&error) && !matches.is_empty() => {
                    stopped_by = Some(error.limit.unwrap_or("budget"));
                    break;
                }
                Err(error) => return Err(error),
            }
            blobs_deduped = blobs_deduped.saturating_add(1);
            scan.clone()
        } else {
            let scan = match scan_blob(store, candidate.oid, &matcher, opts, budget) {
                Ok(scan) => scan,
                Err(error) if truncatable(&error) && !matches.is_empty() => {
                    stopped_by = Some(error.limit.unwrap_or("budget"));
                    break;
                }
                Err(error) => return Err(error),
            };
            match &scan {
                CachedScan::Matches(_) => files_scanned = files_scanned.saturating_add(1),
                CachedScan::BinarySkipped => binary_skipped = binary_skipped.saturating_add(1),
                CachedScan::OversizeSkipped => {
                    oversize_skipped = oversize_skipped.saturating_add(1)
                }
            }
            cache.insert(candidate.oid, scan.clone());
            scan
        };

        let CachedScan::Matches(line_matches) = scan else {
            if start_ordinal.is_some() {
                return Err(invalid_cursor(
                    "position check failed: cursor path has no emitted matches",
                ));
            }
            continue;
        };
        let start = match start_ordinal {
            Some(start) => {
                let prior = start.saturating_sub(1);
                if usize::try_from(prior)
                    .ok()
                    .is_none_or(|ordinal| ordinal >= line_matches.len())
                {
                    return Err(invalid_cursor(
                        "position check failed: match ordinal is outside the file",
                    ));
                }
                usize::try_from(start).unwrap_or(usize::MAX)
            }
            None => 0,
        };

        for (ordinal, cached) in line_matches.iter().enumerate().skip(start) {
            budget.check()?;
            let item = SearchMatch {
                commit_oid: snapshot.commit_oid,
                blob_oid: candidate.oid,
                path: candidate.path.clone(),
                line: cached.line,
                column: cached.column,
                preview: cached.preview.clone(),
                preview_truncated: cached.preview_truncated,
                submatches: cached.submatches.clone(),
                context_before: cached.context_before.clone(),
                context_after: cached.context_after.clone(),
            };
            let item_bytes = item.payload_bytes();
            if matches.len() == opts.limit {
                stopped_by = Some("limit");
                break 'walk;
            }
            if payload_bytes.saturating_add(item_bytes) > opts.max_result_bytes {
                stopped_by = Some("max_result_bytes");
                break 'walk;
            }
            let ordinal = u32::try_from(ordinal).map_err(|_| {
                Error::new(
                    ErrorCode::ResultTooLarge,
                    "one file has too many matching lines for a search cursor",
                )
                .with_limit("max_result_bytes")
            })?;
            payload_bytes = payload_bytes.saturating_add(item_bytes);
            matches.push(item);
            positions.push((candidate.path.clone(), ordinal));
        }
    }

    if !found_resume {
        return Err(invalid_cursor(
            "position check failed: path is not in this traversal",
        ));
    }

    let truncated = stopped_by.is_some();
    let next_cursor = if truncated {
        fit_cursor(
            snapshot,
            fingerprint,
            opts.max_result_bytes,
            &mut matches,
            &mut positions,
            &mut payload_bytes,
            stopped_by.expect("a truncated search names its limit"),
        )?
    } else {
        None
    };

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
        budget: &'a Budget,
    ) -> Result<Self, Error> {
        Ok(Self {
            store,
            budget,
            scope,
            matcher: PathspecMatcher::new(pathspecs),
            stack: vec![WalkFrame {
                entries: read_tree_entries_for_graph_walk(store, tree_oid, budget)?.into_iter(),
                prefix: scope.to_vec(),
            }],
        })
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
                self.stack.push(WalkFrame {
                    entries: read_tree_entries_for_graph_walk(self.store, entry.oid, self.budget)?
                        .into_iter(),
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
            return Ok(Some(BlobCandidate {
                path,
                oid: entry.oid,
            }));
        }
    }
}

fn scan_blob(
    store: &dyn ObjectDb,
    oid: Oid,
    matcher: &CompiledMatcher,
    opts: &SearchOptions,
    budget: &Budget,
) -> Result<CachedScan, Error> {
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
        return Ok(CachedScan::OversizeSkipped);
    }

    let mut payload = Vec::new();
    let kind = store
        .try_find_graph(&oid, &mut payload, budget)?
        .ok_or_else(|| missing_blob(oid))?;
    if kind != ObjectKind::Blob {
        return Err(Error::new(
            ErrorCode::MalformedObject,
            format!("tree blob {oid} addresses a non-blob object"),
        )
        .with_oid(oid));
    }
    budget.check()?;
    if opts.binary == SearchBinaryMode::Skip
        && payload[..payload.len().min(BINARY_PROBE_BYTES)].contains(&0)
    {
        return Ok(CachedScan::BinarySkipped);
    }
    scan_payload(&payload, matcher, opts.context_lines, budget).map(CachedScan::Matches)
}

fn scan_payload(
    payload: &[u8],
    matcher: &CompiledMatcher,
    context_lines: u32,
    budget: &Budget,
) -> Result<Vec<CachedLineMatch>, Error> {
    check_scan_progress(payload.len(), budget)?;
    let spans = line_spans(payload);
    let mut results = Vec::new();
    for (index, &(start, end)) in spans.iter().enumerate() {
        budget.check()?;
        let line = &payload[start..end];
        let occurrences = matcher.occurrences(line, budget)?;
        let Some(&(first_start, _)) = occurrences.first() else {
            continue;
        };
        let preview_end = line.len().min(PREVIEW_BYTES);
        let submatches = occurrences
            .into_iter()
            .map(|(match_start, match_end)| {
                let clamped_start = match_start.min(preview_end);
                let clamped_end = match_end.min(preview_end).max(clamped_start);
                Ok(SearchSubmatch {
                    start: u32::try_from(clamped_start).map_err(|_| result_too_large())?,
                    length: u32::try_from(clamped_end - clamped_start)
                        .map_err(|_| result_too_large())?,
                })
            })
            .collect::<Result<Vec<_>, Error>>()?;
        let context = usize::try_from(context_lines).unwrap_or(usize::MAX);
        let before_start = index.saturating_sub(context);
        let after_end = index
            .saturating_add(1)
            .saturating_add(context)
            .min(spans.len());
        results.push(CachedLineMatch {
            line: u32::try_from(index.saturating_add(1)).map_err(|_| result_too_large())?,
            column: u32::try_from(first_start).map_err(|_| result_too_large())?,
            preview: line[..preview_end].to_vec(),
            preview_truncated: preview_end < line.len(),
            submatches,
            context_before: spans[before_start..index]
                .iter()
                .map(|&(start, end)| capped_line(payload, start, end))
                .collect(),
            context_after: spans[index.saturating_add(1)..after_end]
                .iter()
                .map(|&(start, end)| capped_line(payload, start, end))
                .collect(),
        });
    }
    Ok(results)
}

fn line_spans(payload: &[u8]) -> Vec<(usize, usize)> {
    let mut spans = Vec::new();
    let mut start = 0usize;
    for (index, byte) in payload.iter().enumerate() {
        if *byte == b'\n' {
            spans.push((start, index));
            start = index.saturating_add(1);
        }
    }
    if start < payload.len() {
        spans.push((start, payload.len()));
    }
    spans
}

fn capped_line(payload: &[u8], start: usize, end: usize) -> Vec<u8> {
    payload[start..end.min(start.saturating_add(PREVIEW_BYTES))].to_vec()
}

fn check_scan_progress(bytes: usize, budget: &Budget) -> Result<(), Error> {
    budget.check()?;
    let mut checked = SCAN_CHECK_BYTES;
    while checked < bytes {
        budget.check()?;
        checked = checked.saturating_add(SCAN_CHECK_BYTES);
    }
    Ok(())
}

fn fit_cursor(
    snapshot: &Snapshot,
    fingerprint: u64,
    max_result_bytes: u64,
    matches: &mut Vec<SearchMatch>,
    positions: &mut Vec<(Vec<u8>, u32)>,
    payload_bytes: &mut u64,
    stopped_by: &'static str,
) -> Result<Option<Vec<u8>>, Error> {
    loop {
        let Some((path, ordinal)) = positions.last() else {
            return Err(Error::new(
                ErrorCode::BudgetExceeded,
                "budget exhausted before any search pagination progress",
            )
            .with_limit(stopped_by));
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
            return Err(Error::new(
                ErrorCode::ResultTooLarge,
                "search continuation path exceeds the cursor size limit",
            ));
        }
        if payload_bytes.saturating_add(encoded.len() as u64) <= max_result_bytes {
            return Ok(Some(encoded));
        }
        let removed = matches
            .pop()
            .expect("cursor positions and search matches have equal length");
        positions.pop();
        *payload_bytes = payload_bytes.saturating_sub(removed.payload_bytes());
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
    for pathspec in &opts.pathspecs {
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
    use crate::test_support::{fixture_oid, fixture_repo};
    use std::process::Command;
    use std::sync::atomic::AtomicBool;
    use std::sync::Arc;

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

    #[test]
    fn literal_search_is_line_oriented_byte_preserving_and_groups_occurrences() {
        let (store, snapshot) = fixture();
        let page = run(&store, &snapshot, b"needle", SearchOptions::default());
        assert!(!page.truncated);
        assert_eq!(page.stats.binary_skipped, 1);
        assert_eq!(page.stats.oversize_skipped, 0);
        assert_eq!(page.stats.blobs_deduped, 2);
        assert_eq!(page.matches.len(), 49);

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

        let zero_progress = search(
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
        .expect_err("zero result-byte progress is an error");
        assert_eq!(zero_progress.code, ErrorCode::BudgetExceeded);
        assert_eq!(zero_progress.limit, Some("max_result_bytes"));

        let object_budget = Budget::new(
            BudgetLimits {
                max_objects: 1,
                ..BudgetLimits::default()
            },
            None,
            Arc::new(AtomicBool::new(false)),
        );
        let object_page = search(
            &store,
            &snapshot,
            b"needle",
            &SearchOptions {
                path: b"dedup".to_vec(),
                ..SearchOptions::default()
            },
            &object_budget,
        )
        .expect("one result permits object-budget truncation");
        assert!(object_page.truncated);
        assert_eq!(object_page.matches.len(), 1);
        assert_eq!(object_page.stats.stopped_by, Some("max_objects"));
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
                SearchBinaryMode::Text,
                vec![b"binary-with-needle.dat".to_vec()],
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
                arguments.extend(
                    pathspecs.iter().map(|pathspec| {
                        String::from_utf8(pathspec.clone()).expect("ASCII fixture")
                    }),
                );
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
