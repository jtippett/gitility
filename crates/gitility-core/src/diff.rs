//! Sequential structured tree and blob diffs.
//!
//! Tree change discovery and rewrite tracking are delegated to `gix-diff`.
//! The adapter below deliberately presents a head-first, base-second object
//! union: a miss falls through while any actual store error fails the query.
//! This is the same ordered-authority rule used by [`crate::layered_odb`], but
//! borrows the two snapshot stores instead of constructing a persistent layer.

use crate::budget::Budget;
use crate::error::{Error, ErrorCode};
use crate::object::{HashKind, ObjectHeader, ObjectKind, Oid};
use crate::odb::{CacheStats, HeaderProvenance, HeaderRead, ObjectDb};
use crate::pathspec::PathspecMatcher;
use crate::search::{is_binary_payload, MAX_CONTEXT_LINES};
use crate::snapshot::Snapshot;
use crate::tree::{ensure_query_compatible, QueryStats};
use gix_diff::blob::unified_diff::{ConsumeHunk, ContextSize, DiffLineKind, HunkHeader};
use gix_diff::blob::{Algorithm, InternedInput, UnifiedDiff};
use gix_diff::rewrites::{Copies, CopySource};
use gix_diff::tree::recorder::Location;
use gix_diff::tree_with_rewrites::{Action, ChangeRef};
use gix_object::TreeRefIter;
use std::cell::RefCell;
use std::io;
use std::path::PathBuf;

const DIFF_CHECK_BYTES: usize = 64 * 1_024;

/// Amount of structured detail to compute.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum DiffFormat {
    Summary,
    Stats,
    #[default]
    Patch,
}

/// Rename tracking policy. Similarity uses gix-diff's default 50% threshold.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum RenameTracking {
    #[default]
    Disabled,
    Similarity,
}

/// Bounds and behavior for one diff operation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiffOptions {
    pub format: DiffFormat,
    pub pathspecs: Vec<Vec<u8>>,
    pub context_lines: u32,
    pub renames: RenameTracking,
    pub copies: bool,
    pub max_diff_files: usize,
    pub max_diff_hunks: usize,
    pub max_diff_lines: usize,
    /// The semantic oversize threshold. The NIF lets the object store inflate
    /// past this value so a provider that understated a header is still
    /// detected and converted into a warning rather than a hard error.
    pub max_object_bytes: u64,
}

impl Default for DiffOptions {
    fn default() -> Self {
        Self {
            format: DiffFormat::Patch,
            pathspecs: Vec::new(),
            context_lines: 3,
            renames: RenameTracking::Disabled,
            copies: false,
            max_diff_files: 1_000,
            max_diff_hunks: 10_000,
            max_diff_lines: 100_000,
            max_object_bytes: 4 * 1_024 * 1_024,
        }
    }
}

/// Git's file-level change classification.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiffStatus {
    Added,
    Deleted,
    Modified,
    Renamed,
    Copied,
    TypeChanged,
}

/// One structured file change.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiffFile {
    pub status: DiffStatus,
    pub old_path: Option<Vec<u8>>,
    pub new_path: Option<Vec<u8>>,
    pub old_oid: Option<Oid>,
    pub new_oid: Option<Oid>,
    pub old_mode: Option<u32>,
    pub new_mode: Option<u32>,
    pub similarity: Option<u8>,
    pub additions: Option<u32>,
    pub deletions: Option<u32>,
    pub binary: bool,
    pub hunks: Vec<DiffHunk>,
}

/// One structured patch hunk.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiffHunk {
    pub old_start: u32,
    pub old_lines: u32,
    pub new_start: u32,
    pub new_lines: u32,
    pub header: Option<Vec<u8>>,
    pub lines: Vec<DiffLine>,
}

/// Origin of one patch line.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiffLineOrigin {
    Context,
    Addition,
    Deletion,
}

/// One raw-byte patch line, without the unified-diff origin marker.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiffLine {
    pub origin: DiffLineOrigin,
    pub content: Vec<u8>,
    pub old_line: Option<u32>,
    pub new_line: Option<u32>,
}

/// A successful-result warning.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiffWarning {
    pub code: DiffWarningCode,
    pub message: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiffWarningCode {
    Truncated,
    OversizeSkipped,
}

/// The complete, non-pageable structured result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Diff {
    pub files: Vec<DiffFile>,
    pub stats: QueryStats,
    pub warnings: Vec<DiffWarning>,
    pub truncated: bool,
}

#[derive(Debug, Clone)]
struct RawChange {
    status: DiffStatus,
    old_path: Option<Vec<u8>>,
    new_path: Option<Vec<u8>>,
    old_oid: Option<Oid>,
    new_oid: Option<Oid>,
    old_mode: Option<u32>,
    new_mode: Option<u32>,
    similarity: Option<u8>,
}

impl RawChange {
    fn sort_path(&self) -> &[u8] {
        self.new_path
            .as_deref()
            .or(self.old_path.as_deref())
            .unwrap_or_default()
    }

    fn into_file(self) -> DiffFile {
        DiffFile {
            status: self.status,
            old_path: self.old_path,
            new_path: self.new_path,
            old_oid: self.old_oid,
            new_oid: self.new_oid,
            old_mode: self.old_mode,
            new_mode: self.new_mode,
            similarity: self.similarity,
            additions: None,
            deletions: None,
            binary: false,
            hunks: Vec::new(),
        }
    }
}

/// Diff two pinned snapshots. All work is strictly sequential.
pub fn diff(
    base_store: &dyn ObjectDb,
    base: &Snapshot,
    head_store: &dyn ObjectDb,
    head: &Snapshot,
    opts: &DiffOptions,
    budget: &Budget,
) -> Result<Diff, Error> {
    validate(base_store, base, head_store, head, opts)?;
    budget.check()?;

    let union = UnionObjectDb::new(head_store, base_store)?;
    if base.tree_oid == head.tree_oid {
        return Ok(finish(
            Vec::new(),
            Vec::new(),
            false,
            None,
            &union,
            budget,
            0,
        ));
    }

    let adapter = GixObjectStore::new(&union, budget, opts.max_object_bytes);
    let base_tree = read_required_tree(&union, base.tree_oid, budget)?;
    let head_tree = read_required_tree(&union, head.tree_oid, budget)?;
    let matcher = PathspecMatcher::new(&opts.pathspecs);
    let mut changes = Vec::with_capacity(opts.max_diff_files.min(1_024));
    let mut stopped_by = None;
    let mut platform = rewrite_platform(opts.max_object_bytes);
    let rewrite_options = match opts.renames {
        RenameTracking::Disabled => None,
        RenameTracking::Similarity => Some(gix_diff::Rewrites {
            copies: opts.copies.then_some(Copies {
                source: CopySource::FromSetOfModifiedFiles,
                percentage: Some(0.5),
            }),
            percentage: Some(0.5),
            // Tracker compares `sources * destinations` with this field. The
            // square keeps all candidates admitted by max_diff_files while
            // retaining a finite work ceiling.
            limit: opts.max_diff_files.saturating_mul(opts.max_diff_files),
            track_empty: false,
        }),
    };

    let result = gix_diff::tree_with_rewrites(
        TreeRefIter::from_bytes(&base_tree, gix_hash_kind(base.tree_oid.kind())),
        TreeRefIter::from_bytes(&head_tree, gix_hash_kind(head.tree_oid.kind())),
        &mut platform,
        &mut Default::default(),
        &adapter,
        |change| -> Result<Action, Error> {
            budget.check()?;
            let Some(change) = normalize_change(change)? else {
                return Ok(std::ops::ControlFlow::Continue(()));
            };
            if !matcher.matches(change.sort_path()) {
                return Ok(std::ops::ControlFlow::Continue(()));
            }
            if changes.len() == opts.max_diff_files {
                stopped_by = Some("max_diff_files");
                return Ok(std::ops::ControlFlow::Break(()));
            }
            changes.push(change);
            Ok(std::ops::ControlFlow::Continue(()))
        },
        gix_diff::tree_with_rewrites::Options {
            location: Some(Location::Path),
            rewrites: rewrite_options,
        },
    );
    if let Err(error) = result {
        if let Some(core_error) = adapter.take_error() {
            return Err(core_error);
        }
        // Breaking the callback is how the tree walker is stopped at the
        // file ceiling. gitoxide reports that control-flow break as
        // `Cancelled`; it is a successful, explicitly truncated diff here.
        if stopped_by.is_none() {
            return Err(map_tree_diff_error(error));
        }
    }

    // Rewrite tracking emits deterministically, but sorting also normalizes
    // the breadth-first tree traversal into repository path byte order.
    changes.sort_by(|left, right| {
        left.sort_path()
            .cmp(right.sort_path())
            .then_with(|| left.old_path.cmp(&right.old_path))
    });

    let rewrite_oversize = if opts.format == DiffFormat::Summary {
        adapter.oversize_count() as u64
    } else {
        0
    };
    let mut files = Vec::with_capacity(changes.len());
    let mut warnings = if rewrite_oversize == 0 {
        Vec::new()
    } else {
        vec![DiffWarning {
            code: DiffWarningCode::OversizeSkipped,
            message: "rename candidate content suppressed by max_object_bytes".to_owned(),
        }]
    };
    let mut hunks_used = 0usize;
    let mut lines_used = 0usize;
    let mut oversize_skipped = rewrite_oversize;

    for change in changes {
        budget.check()?;
        let mut file = change.into_file();
        if opts.format != DiffFormat::Summary {
            if needs_content(&file) {
                match populate_content(
                    &union,
                    &mut file,
                    opts,
                    budget,
                    &mut hunks_used,
                    &mut lines_used,
                )? {
                    PopulateOutcome::Complete => {}
                    PopulateOutcome::Oversize => {
                        oversize_skipped = oversize_skipped.saturating_add(1);
                        if !warnings.iter().any(|warning: &DiffWarning| {
                            warning.code == DiffWarningCode::OversizeSkipped
                        }) {
                            warnings.push(DiffWarning {
                                code: DiffWarningCode::OversizeSkipped,
                                message: "diff content suppressed by max_object_bytes".to_owned(),
                            });
                        }
                    }
                    PopulateOutcome::Stopped(limit) => {
                        stopped_by = Some(limit);
                    }
                }
            } else {
                populate_gitlink_stats(&mut file);
            }
        }
        files.push(file);
        if stopped_by.is_some() {
            break;
        }
    }

    let truncated = stopped_by.is_some();
    if let Some(limit) = stopped_by {
        warnings.insert(
            0,
            DiffWarning {
                code: DiffWarningCode::Truncated,
                message: format!("diff truncated by {limit}"),
            },
        );
    }
    Ok(finish(
        files,
        warnings,
        truncated,
        stopped_by,
        &union,
        budget,
        oversize_skipped,
    ))
}

fn validate(
    base_store: &dyn ObjectDb,
    base: &Snapshot,
    head_store: &dyn ObjectDb,
    head: &Snapshot,
    opts: &DiffOptions,
) -> Result<(), Error> {
    if base_store.hash_kind() != head_store.hash_kind() {
        return Err(Error::new(
            ErrorCode::HashMismatch,
            "diff object stores use different hash algorithms",
        ));
    }
    ensure_query_compatible(base_store, base)?;
    ensure_query_compatible(head_store, head)?;
    if base.commit_oid.kind() != head.commit_oid.kind() {
        return Err(Error::new(
            ErrorCode::HashMismatch,
            "diff snapshots use different hash algorithms",
        ));
    }
    if opts.context_lines > MAX_CONTEXT_LINES {
        return Err(Error::new(
            ErrorCode::InvalidArgument,
            "diff context_lines must be between 0 and 32",
        ));
    }
    if opts.copies && opts.renames == RenameTracking::Disabled {
        return Err(Error::new(
            ErrorCode::InvalidArgument,
            "copy detection requires rename detection",
        ));
    }
    if opts.max_diff_files == 0 || opts.max_diff_hunks == 0 || opts.max_diff_lines == 0 {
        return Err(Error::new(
            ErrorCode::InvalidArgument,
            "diff limits must be greater than zero",
        ));
    }
    Ok(())
}

fn normalize_change(change: ChangeRef<'_>) -> Result<Option<RawChange>, Error> {
    use ChangeRef::*;
    let raw = match change {
        Addition {
            location,
            entry_mode,
            id,
            ..
        } => {
            if entry_mode.is_tree() {
                return Ok(None);
            }
            RawChange {
                status: DiffStatus::Added,
                old_path: None,
                new_path: Some(location.to_vec()),
                old_oid: None,
                new_oid: Some(core_oid(id)?),
                old_mode: None,
                new_mode: Some(u32::from(entry_mode.value())),
                similarity: None,
            }
        }
        Deletion {
            location,
            entry_mode,
            id,
            ..
        } => {
            if entry_mode.is_tree() {
                return Ok(None);
            }
            RawChange {
                status: DiffStatus::Deleted,
                old_path: Some(location.to_vec()),
                new_path: None,
                old_oid: Some(core_oid(id)?),
                new_oid: None,
                old_mode: Some(u32::from(entry_mode.value())),
                new_mode: None,
                similarity: None,
            }
        }
        Modification {
            location,
            previous_entry_mode,
            previous_id,
            entry_mode,
            id,
        } => {
            if previous_entry_mode.is_tree() && entry_mode.is_tree() {
                return Ok(None);
            }
            let old_mode = u32::from(previous_entry_mode.value());
            let new_mode = u32::from(entry_mode.value());
            RawChange {
                status: if mode_type(old_mode) == mode_type(new_mode) {
                    DiffStatus::Modified
                } else {
                    DiffStatus::TypeChanged
                },
                old_path: Some(location.to_vec()),
                new_path: Some(location.to_vec()),
                old_oid: Some(core_oid(previous_id)?),
                new_oid: Some(core_oid(id)?),
                old_mode: Some(old_mode),
                new_mode: Some(new_mode),
                similarity: None,
            }
        }
        Rewrite {
            source_location,
            source_entry_mode,
            source_id,
            diff,
            entry_mode,
            id,
            location,
            copy,
            ..
        } => {
            if source_entry_mode.is_tree() || entry_mode.is_tree() {
                return Ok(None);
            }
            let similarity = diff
                .map(|stats| (stats.similarity * 100.0).round().clamp(0.0, 100.0) as u8)
                .unwrap_or(100);
            RawChange {
                status: if copy {
                    DiffStatus::Copied
                } else {
                    DiffStatus::Renamed
                },
                old_path: Some(source_location.to_vec()),
                new_path: Some(location.to_vec()),
                old_oid: Some(core_oid(source_id)?),
                new_oid: Some(core_oid(id)?),
                old_mode: Some(u32::from(source_entry_mode.value())),
                new_mode: Some(u32::from(entry_mode.value())),
                similarity: Some(similarity),
            }
        }
    };
    Ok(Some(raw))
}

fn needs_content(file: &DiffFile) -> bool {
    let old_gitlink = file.old_mode.is_some_and(is_gitlink);
    let new_gitlink = file.new_mode.is_some_and(is_gitlink);
    !old_gitlink && !new_gitlink
}

fn populate_gitlink_stats(file: &mut DiffFile) {
    file.additions = Some(u32::from(file.new_oid.is_some()));
    file.deletions = Some(u32::from(file.old_oid.is_some()));
}

enum PopulateOutcome {
    Complete,
    Oversize,
    Stopped(&'static str),
}

#[allow(clippy::too_many_arguments)]
fn populate_content(
    store: &UnionObjectDb<'_>,
    file: &mut DiffFile,
    opts: &DiffOptions,
    budget: &Budget,
    hunks_used: &mut usize,
    lines_used: &mut usize,
) -> Result<PopulateOutcome, Error> {
    if file.old_oid == file.new_oid {
        file.additions = Some(0);
        file.deletions = Some(0);
        return Ok(PopulateOutcome::Complete);
    }

    let old = read_diff_blob(store, file.old_oid, opts.max_object_bytes, budget)?;
    let new = read_diff_blob(store, file.new_oid, opts.max_object_bytes, budget)?;
    let (old, new) = match (old, new) {
        (BlobRead::Oversize, _) | (_, BlobRead::Oversize) => return Ok(PopulateOutcome::Oversize),
        (BlobRead::Data(old), BlobRead::Data(new)) => (old, new),
    };
    if is_binary_payload(&old) || is_binary_payload(&new) {
        file.binary = true;
        return Ok(PopulateOutcome::Complete);
    }

    check_comparison_cadence(&old, &new, budget)?;
    let input = InternedInput::new(LinesWithoutLf::new(&old), LinesWithoutLf::new(&new));
    let computed = gix_diff::blob::diff_with_slider_heuristics(Algorithm::Histogram, &input);
    file.additions = Some(computed.count_additions());
    file.deletions = Some(computed.count_removals());
    if opts.format == DiffFormat::Stats {
        return Ok(PopulateOutcome::Complete);
    }

    let shared = RefCell::new(HunkCollectorState::default());
    let collector = HunkCollector {
        state: &shared,
        budget,
        hunks_used,
        lines_used,
        max_hunks: opts.max_diff_hunks,
        max_lines: opts.max_diff_lines,
    };
    let consumed = UnifiedDiff::new(
        &computed,
        &input,
        collector,
        ContextSize::symmetrical(opts.context_lines),
    )
    .consume();
    let state = shared.into_inner();
    file.hunks = state.hunks;
    if consumed.is_err() {
        if let Some(error) = state.error {
            return Err(error);
        }
        return match state.stopped_by {
            Some(limit) => Ok(PopulateOutcome::Stopped(limit)),
            None => Err(Error::new(
                ErrorCode::InternalError,
                "structured hunk assembly failed",
            )),
        };
    }
    Ok(PopulateOutcome::Complete)
}

#[derive(Default)]
struct HunkCollectorState {
    hunks: Vec<DiffHunk>,
    stopped_by: Option<&'static str>,
    error: Option<Error>,
}

struct HunkCollector<'a> {
    state: &'a RefCell<HunkCollectorState>,
    budget: &'a Budget,
    hunks_used: &'a mut usize,
    lines_used: &'a mut usize,
    max_hunks: usize,
    max_lines: usize,
}

impl ConsumeHunk for HunkCollector<'_> {
    type Out = ();

    fn consume_hunk(
        &mut self,
        header: HunkHeader,
        lines: &[(DiffLineKind, &[u8])],
    ) -> io::Result<()> {
        if let Err(error) = self.budget.check() {
            self.state.borrow_mut().error = Some(error.clone());
            return Err(io::Error::other(error));
        }
        if *self.hunks_used == self.max_hunks {
            self.state.borrow_mut().stopped_by = Some("max_diff_hunks");
            return Err(io::Error::other("max_diff_hunks reached"));
        }
        if self.lines_used.saturating_add(lines.len()) > self.max_lines {
            self.state.borrow_mut().stopped_by = Some("max_diff_lines");
            return Err(io::Error::other("max_diff_lines reached"));
        }

        let mut old_line = header.before_hunk_start;
        let mut new_line = header.after_hunk_start;
        let mut output = Vec::with_capacity(lines.len());
        for &(kind, content) in lines {
            if let Err(error) = self.budget.check() {
                self.state.borrow_mut().error = Some(error.clone());
                return Err(io::Error::other(error));
            }
            let content = content.strip_suffix(b"\n").unwrap_or(content).to_vec();
            let line = match kind {
                DiffLineKind::Context => {
                    let line = DiffLine {
                        origin: DiffLineOrigin::Context,
                        content,
                        old_line: Some(old_line),
                        new_line: Some(new_line),
                    };
                    old_line = old_line.saturating_add(1);
                    new_line = new_line.saturating_add(1);
                    line
                }
                DiffLineKind::Add => {
                    let line = DiffLine {
                        origin: DiffLineOrigin::Addition,
                        content,
                        old_line: None,
                        new_line: Some(new_line),
                    };
                    new_line = new_line.saturating_add(1);
                    line
                }
                DiffLineKind::Remove => {
                    let line = DiffLine {
                        origin: DiffLineOrigin::Deletion,
                        content,
                        old_line: Some(old_line),
                        new_line: None,
                    };
                    old_line = old_line.saturating_add(1);
                    line
                }
            };
            output.push(line);
        }
        self.state.borrow_mut().hunks.push(DiffHunk {
            old_start: header.before_hunk_start,
            old_lines: header.before_hunk_len,
            new_start: header.after_hunk_start,
            new_lines: header.after_hunk_len,
            header: None,
            lines: output,
        });
        *self.hunks_used = self.hunks_used.saturating_add(1);
        *self.lines_used = self.lines_used.saturating_add(lines.len());
        Ok(())
    }

    fn finish(self) -> Self::Out {}
}

#[derive(Clone, Copy)]
struct LinesWithoutLf<'a>(&'a [u8]);

impl<'a> LinesWithoutLf<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self(data)
    }
}

impl<'a> Iterator for LinesWithoutLf<'a> {
    type Item = &'a [u8];

    fn next(&mut self) -> Option<Self::Item> {
        if self.0.is_empty() {
            return None;
        }
        let split = self
            .0
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(self.0.len(), |position| position.saturating_add(1));
        let (line, rest) = self.0.split_at(split);
        self.0 = rest;
        Some(line.strip_suffix(b"\n").unwrap_or(line))
    }
}

impl<'a> gix_diff::blob::TokenSource for LinesWithoutLf<'a> {
    type Token = &'a [u8];
    type Tokenizer = Self;

    fn tokenize(&self) -> Self::Tokenizer {
        *self
    }

    fn estimate_tokens(&self) -> u32 {
        let sample_bytes = self.take(20).map(<[u8]>::len).sum::<usize>();
        u32::try_from(
            self.0
                .len()
                .saturating_mul(20)
                .checked_div(sample_bytes)
                .unwrap_or(100),
        )
        .unwrap_or(u32::MAX)
    }
}

enum BlobRead {
    Data(Vec<u8>),
    Oversize,
}

fn read_diff_blob(
    store: &UnionObjectDb<'_>,
    oid: Option<Oid>,
    max_bytes: u64,
    budget: &Budget,
) -> Result<BlobRead, Error> {
    let Some(oid) = oid else {
        return Ok(BlobRead::Data(Vec::new()));
    };
    let header = store
        .try_header_with_provenance(&oid, budget)?
        .ok_or_else(|| missing_object(oid, "blob header"))?;
    validate_blob_header(oid, header)?;
    if header.header.size > max_bytes {
        return Ok(BlobRead::Oversize);
    }
    let mut payload = Vec::new();
    let kind = store
        .try_find(&oid, &mut payload, budget)?
        .ok_or_else(|| missing_object(oid, "blob"))?;
    if kind != ObjectKind::Blob {
        return Err(Error::new(
            ErrorCode::MalformedObject,
            format!("tree blob {oid} addresses a non-blob object"),
        )
        .with_oid(oid));
    }
    if payload.len() as u64 > max_bytes {
        return Ok(BlobRead::Oversize);
    }
    Ok(BlobRead::Data(payload))
}

fn validate_blob_header(oid: Oid, header: HeaderRead) -> Result<(), Error> {
    if header.header.kind == ObjectKind::Blob {
        return Ok(());
    }
    Err(match header.provenance {
        HeaderProvenance::UnverifiedProvider => Error::new(
            ErrorCode::ProviderProtocolError,
            "provider header contradicts tree entry kind",
        ),
        HeaderProvenance::Verified => Error::new(
            ErrorCode::MalformedObject,
            format!("tree blob {oid} addresses a non-blob object"),
        ),
    }
    .with_oid(oid))
}

fn check_comparison_cadence(old: &[u8], new: &[u8], budget: &Budget) -> Result<(), Error> {
    for _ in old.chunks(DIFF_CHECK_BYTES) {
        budget.check()?;
    }
    for _ in new.chunks(DIFF_CHECK_BYTES) {
        budget.check()?;
    }
    budget.check()
}

fn read_required_tree(
    store: &UnionObjectDb<'_>,
    oid: Oid,
    budget: &Budget,
) -> Result<Vec<u8>, Error> {
    let mut payload = Vec::new();
    let kind = store
        .try_find(&oid, &mut payload, budget)?
        .ok_or_else(|| missing_object(oid, "tree"))?;
    if kind != ObjectKind::Tree {
        return Err(Error::new(
            ErrorCode::NotATree,
            format!("tree object {oid} is not a tree"),
        ));
    }
    Ok(payload)
}

fn finish(
    files: Vec<DiffFile>,
    warnings: Vec<DiffWarning>,
    truncated: bool,
    stopped_by: Option<&'static str>,
    store: &UnionObjectDb<'_>,
    budget: &Budget,
    oversize_skipped: u64,
) -> Diff {
    let (objects_read, bytes_read, _, _) = budget.spent();
    let (cache_hits, cache_misses) = budget.cache_spent();
    let cache = store.cache_stats();
    Diff {
        stats: QueryStats {
            objects_read,
            bytes_read,
            entries_emitted: files.len() as u64,
            cache_hits,
            cache_misses,
            cache_bytes: cache.bytes,
            cache_entries: cache.entries,
            cache_evictions: cache.evictions,
            files_scanned: files.len() as u64,
            blobs_deduped: 0,
            binary_skipped: files.iter().filter(|file| file.binary).count() as u64,
            oversize_skipped,
            payload_rereads: 0,
            stopped_by,
        },
        files,
        warnings,
        truncated,
    }
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
            algorithm: Some(Algorithm::Histogram),
            ..Default::default()
        },
        pipeline,
        gix_diff::blob::pipeline::Mode::ToGit,
        attributes,
    )
}

fn map_tree_diff_error(error: gix_diff::tree_with_rewrites::Error) -> Error {
    if let gix_diff::tree_with_rewrites::Error::ForEach(source) = error {
        if let Ok(error) = source.downcast::<Error>() {
            return *error;
        }
    }
    Error::new(
        ErrorCode::MalformedObject,
        "tree or rewrite diff failed on malformed object data",
    )
}

fn core_oid(id: gix_hash::ObjectId) -> Result<Oid, Error> {
    Oid::new(core_hash_kind(id.kind())?, id.as_slice())
}

fn gix_hash_kind(kind: HashKind) -> gix_hash::Kind {
    match kind {
        HashKind::Sha1 => gix_hash::Kind::Sha1,
        HashKind::Sha256 => gix_hash::Kind::Sha256,
    }
}

fn core_hash_kind(kind: gix_hash::Kind) -> Result<HashKind, Error> {
    match kind {
        gix_hash::Kind::Sha1 => Ok(HashKind::Sha1),
        gix_hash::Kind::Sha256 => Ok(HashKind::Sha256),
        _ => Err(Error::new(
            ErrorCode::UnsupportedHash,
            "gitoxide returned an unsupported hash algorithm",
        )),
    }
}

fn gix_object_kind(kind: ObjectKind) -> gix_object::Kind {
    match kind {
        ObjectKind::Commit => gix_object::Kind::Commit,
        ObjectKind::Tree => gix_object::Kind::Tree,
        ObjectKind::Blob => gix_object::Kind::Blob,
        ObjectKind::Tag => gix_object::Kind::Tag,
    }
}

fn mode_type(mode: u32) -> u32 {
    mode & 0o170000
}

fn is_gitlink(mode: u32) -> bool {
    mode_type(mode) == 0o160000
}

fn missing_object(oid: Oid, role: &str) -> Error {
    Error::new(
        ErrorCode::MissingObject,
        format!("{role} object {oid} is missing from the object store union"),
    )
    .with_oid(oid)
}

/// A borrowed, head-first object union. Like LayeredOdb, only `None` falls
/// through; errors from an authoritative store are never treated as misses.
struct UnionObjectDb<'a> {
    head: &'a dyn ObjectDb,
    base: &'a dyn ObjectDb,
}

impl<'a> UnionObjectDb<'a> {
    fn new(head: &'a dyn ObjectDb, base: &'a dyn ObjectDb) -> Result<Self, Error> {
        if head.hash_kind() != base.hash_kind() {
            return Err(Error::new(
                ErrorCode::HashMismatch,
                "diff object stores use different hash algorithms",
            ));
        }
        Ok(Self { head, base })
    }

    fn try_header(&self, oid: &Oid, budget: &Budget) -> Result<Option<ObjectHeader>, Error> {
        Ok(self
            .try_header_with_provenance(oid, budget)?
            .map(|read| read.header))
    }

    fn try_header_with_provenance(
        &self,
        oid: &Oid,
        budget: &Budget,
    ) -> Result<Option<HeaderRead>, Error> {
        if let Some(header) = self.head.try_header_with_provenance(oid, budget)? {
            return Ok(Some(header));
        }
        self.base.try_header_with_provenance(oid, budget)
    }

    fn try_find(
        &self,
        oid: &Oid,
        out: &mut Vec<u8>,
        budget: &Budget,
    ) -> Result<Option<ObjectKind>, Error> {
        if let Some(kind) = self.head.try_find(oid, out, budget)? {
            return Ok(Some(kind));
        }
        self.base.try_find(oid, out, budget)
    }

    fn cache_stats(&self) -> CacheStats {
        let head = self.head.cache_stats();
        let base = self.base.cache_stats();
        CacheStats {
            bytes: head.bytes.saturating_add(base.bytes),
            entries: head.entries.saturating_add(base.entries),
            evictions: head.evictions.saturating_add(base.evictions),
        }
    }
}

/// Bridges the byte-preserving Gitility store contract into gitoxide's
/// plumbing traits without exposing gitoxide types in the public core API.
struct GixObjectStore<'a> {
    store: &'a UnionObjectDb<'a>,
    budget: &'a Budget,
    max_object_bytes: u64,
    last_error: RefCell<Option<Error>>,
    oversize: RefCell<Vec<Oid>>,
}

impl<'a> GixObjectStore<'a> {
    fn new(store: &'a UnionObjectDb<'a>, budget: &'a Budget, max_object_bytes: u64) -> Self {
        Self {
            store,
            budget,
            max_object_bytes,
            last_error: RefCell::new(None),
            oversize: RefCell::new(Vec::new()),
        }
    }

    fn take_error(&self) -> Option<Error> {
        self.last_error.borrow_mut().take()
    }

    fn record(&self, error: Error) -> gix_object::find::Error {
        *self.last_error.borrow_mut() = Some(error.clone());
        Box::new(error)
    }

    fn record_oversize(&self, oid: Oid) {
        let mut oversize = self.oversize.borrow_mut();
        if !oversize.contains(&oid) {
            oversize.push(oid);
        }
    }

    fn oversize_count(&self) -> usize {
        self.oversize.borrow().len()
    }
}

impl gix_object::Find for GixObjectStore<'_> {
    fn try_find<'a>(
        &self,
        id: &gix_hash::oid,
        buffer: &'a mut Vec<u8>,
    ) -> Result<Option<gix_object::Data<'a>>, gix_object::find::Error> {
        let hash = core_hash_kind(id.kind()).map_err(|error| self.record(error))?;
        let oid = Oid::new(hash, id.as_bytes()).map_err(|error| self.record(error))?;
        let kind = self
            .store
            .try_find(&oid, buffer, self.budget)
            .map_err(|error| self.record(error))?;
        if kind == Some(ObjectKind::Blob) && buffer.len() as u64 > self.max_object_bytes {
            self.record_oversize(oid);
        }
        Ok(kind.map(|kind| {
            gix_object::Data::new(buffer, gix_object_kind(kind), gix_hash_kind(oid.kind()))
        }))
    }
}

impl gix_object::FindHeader for GixObjectStore<'_> {
    fn try_header(
        &self,
        id: &gix_hash::oid,
    ) -> Result<Option<gix_object::Header>, gix_object::find::Error> {
        let hash = core_hash_kind(id.kind()).map_err(|error| self.record(error))?;
        let oid = Oid::new(hash, id.as_bytes()).map_err(|error| self.record(error))?;
        self.store
            .try_header(&oid, self.budget)
            .map(|header| {
                header.map(|header| {
                    if header.kind == ObjectKind::Blob && header.size > self.max_object_bytes {
                        self.record_oversize(oid);
                    }
                    gix_object::Header {
                        kind: gix_object_kind(header.kind),
                        size: header.size,
                    }
                })
            })
            .map_err(|error| self.record(error))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::static_odb::StaticOdb;
    use crate::verify::object_id;

    fn tree(entries: &[(u32, &[u8], Oid)]) -> Vec<u8> {
        let mut out = Vec::new();
        for (mode, name, oid) in entries {
            out.extend_from_slice(format!("{mode:o} ").as_bytes());
            out.extend_from_slice(name);
            out.push(0);
            out.extend_from_slice(oid.as_bytes());
        }
        out
    }

    fn store(objects: Vec<(ObjectKind, Vec<u8>)>) -> StaticOdb {
        StaticOdb::from_objects(HashKind::Sha1, objects).expect("objects are valid")
    }

    #[test]
    fn same_tree_is_empty_without_blob_reads() {
        let empty_tree = Vec::new();
        let tree_oid = object_id(HashKind::Sha1, ObjectKind::Tree, &empty_tree).unwrap();
        let store = store(vec![(ObjectKind::Tree, empty_tree)]);
        let snapshot = Snapshot {
            commit_oid: Oid::new(HashKind::Sha1, &[1; 20]).unwrap(),
            tree_oid,
        };
        let result = diff(
            &store,
            &snapshot,
            &store,
            &snapshot,
            &DiffOptions::default(),
            &Budget::unlimited(),
        )
        .unwrap();
        assert!(result.files.is_empty());
        assert!(!result.truncated);
        assert_eq!(result.stats.objects_read, 0);
    }

    #[test]
    fn summary_mode_uses_cross_store_union_without_reading_blob_payloads() {
        let old = b"old\n".to_vec();
        let new = b"new\n".to_vec();
        let old_oid = object_id(HashKind::Sha1, ObjectKind::Blob, &old).unwrap();
        let new_oid = object_id(HashKind::Sha1, ObjectKind::Blob, &new).unwrap();
        let base_tree = tree(&[(0o100644, b"file", old_oid)]);
        let head_tree = tree(&[(0o100644, b"file", new_oid)]);
        let base_tree_oid = object_id(HashKind::Sha1, ObjectKind::Tree, &base_tree).unwrap();
        let head_tree_oid = object_id(HashKind::Sha1, ObjectKind::Tree, &head_tree).unwrap();
        let base_store = store(vec![(ObjectKind::Tree, base_tree), (ObjectKind::Blob, old)]);
        let head_store = store(vec![(ObjectKind::Tree, head_tree), (ObjectKind::Blob, new)]);
        let base = Snapshot {
            commit_oid: Oid::new(HashKind::Sha1, &[1; 20]).unwrap(),
            tree_oid: base_tree_oid,
        };
        let head = Snapshot {
            commit_oid: Oid::new(HashKind::Sha1, &[2; 20]).unwrap(),
            tree_oid: head_tree_oid,
        };
        let result = diff(
            &base_store,
            &base,
            &head_store,
            &head,
            &DiffOptions {
                format: DiffFormat::Summary,
                ..Default::default()
            },
            &Budget::unlimited(),
        )
        .unwrap();
        assert_eq!(result.files.len(), 1);
        assert_eq!(result.files[0].status, DiffStatus::Modified);
        assert_eq!(
            result.stats.objects_read, 2,
            "only the two root trees are read"
        );
    }

    #[test]
    fn patch_is_structured_and_binary_pairs_are_suppressed() {
        let old = b"one\ntwo\nthree\n".to_vec();
        let new = b"one\nTWO\nthree\nfour\n".to_vec();
        let binary = b"a\0b".to_vec();
        let binary_new = b"a\0c".to_vec();
        let old_oid = object_id(HashKind::Sha1, ObjectKind::Blob, &old).unwrap();
        let new_oid = object_id(HashKind::Sha1, ObjectKind::Blob, &new).unwrap();
        let binary_oid = object_id(HashKind::Sha1, ObjectKind::Blob, &binary).unwrap();
        let binary_new_oid = object_id(HashKind::Sha1, ObjectKind::Blob, &binary_new).unwrap();
        let base_tree = tree(&[
            (0o100644, b"binary", binary_oid),
            (0o100644, b"text", old_oid),
        ]);
        let head_tree = tree(&[
            (0o100644, b"binary", binary_new_oid),
            (0o100644, b"text", new_oid),
        ]);
        let base_tree_oid = object_id(HashKind::Sha1, ObjectKind::Tree, &base_tree).unwrap();
        let head_tree_oid = object_id(HashKind::Sha1, ObjectKind::Tree, &head_tree).unwrap();
        let all = store(vec![
            (ObjectKind::Tree, base_tree),
            (ObjectKind::Tree, head_tree),
            (ObjectKind::Blob, old),
            (ObjectKind::Blob, new),
            (ObjectKind::Blob, binary),
            (ObjectKind::Blob, binary_new),
        ]);
        let base = Snapshot {
            commit_oid: Oid::new(HashKind::Sha1, &[1; 20]).unwrap(),
            tree_oid: base_tree_oid,
        };
        let head = Snapshot {
            commit_oid: Oid::new(HashKind::Sha1, &[2; 20]).unwrap(),
            tree_oid: head_tree_oid,
        };
        let result = diff(
            &all,
            &base,
            &all,
            &head,
            &DiffOptions::default(),
            &Budget::unlimited(),
        )
        .unwrap();
        assert_eq!(result.files.len(), 2);
        assert!(result.files[0].binary);
        assert!(result.files[0].hunks.is_empty());
        assert!(!result.files[1].hunks.is_empty());
        assert_eq!(result.files[1].additions, Some(2));
        assert_eq!(result.files[1].deletions, Some(1));
    }

    #[test]
    fn clean_renames_and_gitlink_stats_have_public_shapes() {
        let payload = b"same\n".to_vec();
        let blob_oid = object_id(HashKind::Sha1, ObjectKind::Blob, &payload).unwrap();
        let submodule_old = Oid::new(HashKind::Sha1, &[3; 20]).unwrap();
        let submodule_new = Oid::new(HashKind::Sha1, &[4; 20]).unwrap();
        let base_tree = tree(&[
            (0o100644, b"old", blob_oid),
            (0o160000, b"submodule", submodule_old),
        ]);
        let head_tree = tree(&[
            (0o100644, b"new", blob_oid),
            (0o160000, b"submodule", submodule_new),
        ]);
        let base_tree_oid = object_id(HashKind::Sha1, ObjectKind::Tree, &base_tree).unwrap();
        let head_tree_oid = object_id(HashKind::Sha1, ObjectKind::Tree, &head_tree).unwrap();
        let all = store(vec![
            (ObjectKind::Tree, base_tree),
            (ObjectKind::Tree, head_tree),
            (ObjectKind::Blob, payload),
        ]);
        let base = Snapshot {
            commit_oid: Oid::new(HashKind::Sha1, &[1; 20]).unwrap(),
            tree_oid: base_tree_oid,
        };
        let head = Snapshot {
            commit_oid: Oid::new(HashKind::Sha1, &[2; 20]).unwrap(),
            tree_oid: head_tree_oid,
        };
        let result = diff(
            &all,
            &base,
            &all,
            &head,
            &DiffOptions {
                format: DiffFormat::Stats,
                renames: RenameTracking::Similarity,
                ..Default::default()
            },
            &Budget::unlimited(),
        )
        .unwrap();
        assert_eq!(result.files[0].status, DiffStatus::Renamed);
        assert_eq!(result.files[0].similarity, Some(100));
        assert_eq!(result.files[1].new_mode, Some(0o160000));
        assert_eq!(result.files[1].additions, Some(1));
        assert_eq!(result.files[1].deletions, Some(1));
        assert!(result.files[1].hunks.is_empty());
    }

    #[test]
    fn diff_ceilings_and_oversize_are_successful_warnings() {
        let old_a = b"old a\n".to_vec();
        let new_a = b"new a\n".to_vec();
        let old_b = b"old b\n".to_vec();
        let new_b = b"new b\n".to_vec();
        let old_a_oid = object_id(HashKind::Sha1, ObjectKind::Blob, &old_a).unwrap();
        let new_a_oid = object_id(HashKind::Sha1, ObjectKind::Blob, &new_a).unwrap();
        let old_b_oid = object_id(HashKind::Sha1, ObjectKind::Blob, &old_b).unwrap();
        let new_b_oid = object_id(HashKind::Sha1, ObjectKind::Blob, &new_b).unwrap();
        let base_tree = tree(&[(0o100644, b"a", old_a_oid), (0o100644, b"b", old_b_oid)]);
        let head_tree = tree(&[(0o100644, b"a", new_a_oid), (0o100644, b"b", new_b_oid)]);
        let base_tree_oid = object_id(HashKind::Sha1, ObjectKind::Tree, &base_tree).unwrap();
        let head_tree_oid = object_id(HashKind::Sha1, ObjectKind::Tree, &head_tree).unwrap();
        let all = store(vec![
            (ObjectKind::Tree, base_tree),
            (ObjectKind::Tree, head_tree),
            (ObjectKind::Blob, old_a),
            (ObjectKind::Blob, new_a),
            (ObjectKind::Blob, old_b),
            (ObjectKind::Blob, new_b),
        ]);
        let base = Snapshot {
            commit_oid: Oid::new(HashKind::Sha1, &[1; 20]).unwrap(),
            tree_oid: base_tree_oid,
        };
        let head = Snapshot {
            commit_oid: Oid::new(HashKind::Sha1, &[2; 20]).unwrap(),
            tree_oid: head_tree_oid,
        };

        for (limit, options) in [
            (
                "max_diff_files",
                DiffOptions {
                    format: DiffFormat::Summary,
                    max_diff_files: 1,
                    ..Default::default()
                },
            ),
            (
                "max_diff_hunks",
                DiffOptions {
                    max_diff_hunks: 1,
                    ..Default::default()
                },
            ),
            (
                "max_diff_lines",
                DiffOptions {
                    max_diff_lines: 1,
                    ..Default::default()
                },
            ),
        ] {
            let result = diff(&all, &base, &all, &head, &options, &Budget::unlimited()).unwrap();
            assert!(result.truncated, "{limit}");
            assert_eq!(result.stats.stopped_by, Some(limit));
            assert_eq!(result.warnings[0].code, DiffWarningCode::Truncated);
        }

        let result = diff(
            &all,
            &base,
            &all,
            &head,
            &DiffOptions {
                format: DiffFormat::Stats,
                max_object_bytes: 1,
                ..Default::default()
            },
            &Budget::unlimited(),
        )
        .unwrap();
        assert_eq!(result.stats.oversize_skipped, 2);
        assert!(!result.truncated);
        assert_eq!(result.warnings[0].code, DiffWarningCode::OversizeSkipped);
        assert!(result.files.iter().all(|file| file.additions.is_none()));
    }

    #[test]
    fn generated_diff_fixture_exercises_rewrite_candidates() {
        use crate::local_odb::LocalOdb;
        use crate::test_support::{fixture_oid, fixture_repo};

        let (store, _) = LocalOdb::open(fixture_repo("sha1-diff.git"), Default::default())
            .expect("diff fixture opens");
        let base = Snapshot::open(&store, fixture_oid("sha1_diff_base"), &Budget::unlimited())
            .expect("base snapshot opens");
        let head = Snapshot::open(&store, fixture_oid("sha1_diff_head"), &Budget::unlimited())
            .expect("head snapshot opens");
        let result = diff(
            &store,
            &base,
            &store,
            &head,
            &DiffOptions {
                format: DiffFormat::Summary,
                renames: RenameTracking::Similarity,
                copies: true,
                ..Default::default()
            },
            &Budget::unlimited(),
        )
        .expect("fixture diff succeeds");
        let rewrites = result
            .files
            .iter()
            .filter(|file| matches!(file.status, DiffStatus::Renamed | DiffStatus::Copied))
            .map(|file| {
                (
                    file.status,
                    file.old_path.as_deref().unwrap_or_default(),
                    file.new_path.as_deref().unwrap_or_default(),
                    file.similarity,
                )
            })
            .collect::<Vec<_>>();
        assert!(rewrites.iter().any(|record| {
            record.0 == DiffStatus::Renamed
                && record.1 == b"rename-clean-old.txt"
                && record.2 == b"rename-clean-new.txt"
                && record.3 == Some(100)
        }));
        assert!(rewrites.iter().any(|record| {
            record.0 == DiffStatus::Copied
                && record.1 == b"copy-source.txt"
                && record.2 == b"copy-near.txt"
                && record.3 == Some(93)
        }));
        assert!(rewrites.iter().any(|record| {
            record.0 == DiffStatus::Renamed
                && record.1 == b"rename-edit-old.txt"
                && record.2 == b"rename-edit-new.txt"
                && record.3 == Some(86)
        }));
    }
}
