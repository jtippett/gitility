//! Snapshot tree resolution, traversal, filtering, and pagination.
//!
//! Recursive traversal emits selected trees in pre-order and descends into
//! every tree independently of the type and pathspec filters. Consequently,
//! [`TypeFilter::ALL`] has the shape of `git ls-tree -r -t`, while excluding
//! [`TypeFilter::TREE`] has the shape of plain `git ls-tree -r`. Pathspecs are
//! resolved relative to [`TreeOptions::path`]; wildcard patterns use Git
//! wildmatch and literal patterns select both an exact path and its contents.

use crate::budget::Budget;
use crate::cursor::{self, Cursor, CursorExpected, MAX_CURSOR_BYTES, OPERATION_LIST_TREE};
use crate::decode::decode_tree;
use crate::error::{Error, ErrorCode};
use crate::object::{HashKind, ObjectKind, Oid};
use crate::odb::{HeaderProvenance, ObjectDb};
use crate::pathspec::PathspecMatcher;
use crate::snapshot::Snapshot;

/// The semantic kind derived from a Git tree entry's mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TreeItemKind {
    Blob,
    Tree,
    Symlink,
    Gitlink,
}

/// A compact set of tree item kinds accepted by a query.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TypeFilter(u8);

impl TypeFilter {
    pub const NONE: Self = Self(0);
    pub const BLOB: Self = Self(1 << 0);
    pub const TREE: Self = Self(1 << 1);
    pub const SYMLINK: Self = Self(1 << 2);
    pub const GITLINK: Self = Self(1 << 3);
    pub const ALL: Self = Self(0b1111);

    pub const fn contains(self, kind: TreeItemKind) -> bool {
        let flag = match kind {
            TreeItemKind::Blob => Self::BLOB.0,
            TreeItemKind::Tree => Self::TREE.0,
            TreeItemKind::Symlink => Self::SYMLINK.0,
            TreeItemKind::Gitlink => Self::GITLINK.0,
        };
        self.0 & flag != 0
    }

    const fn bits(self) -> u8 {
        self.0
    }
}

impl Default for TypeFilter {
    fn default() -> Self {
        Self::ALL
    }
}

impl std::ops::BitOr for TypeFilter {
    type Output = Self;

    fn bitor(self, rhs: Self) -> Self::Output {
        Self(self.0 | rhs.0)
    }
}

impl std::ops::BitOrAssign for TypeFilter {
    fn bitor_assign(&mut self, rhs: Self) {
        self.0 |= rhs.0;
    }
}

/// Options for [`list_tree`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TreeOptions {
    pub path: Vec<u8>,
    pub recursive: bool,
    pub depth: Option<u32>,
    /// Kinds to emit. With recursive traversal, `ALL` corresponds to
    /// `git ls-tree -r -t`; excluding `TREE` corresponds to `git ls-tree -r`.
    pub types: TypeFilter,
    /// Git pathspecs resolved relative to `path`. Patterns without `*`, `?`,
    /// or `[` select the exact relative path and everything beneath it.
    pub pathspecs: Vec<Vec<u8>>,
    pub include_size: bool,
    pub limit: usize,
    pub cursor: Option<Vec<u8>>,
}

impl Default for TreeOptions {
    fn default() -> Self {
        Self {
            path: Vec::new(),
            recursive: false,
            depth: None,
            types: TypeFilter::ALL,
            pathspecs: Vec::new(),
            include_size: false,
            limit: 1_000,
            cursor: None,
        }
    }
}

/// One byte-preserving item in a tree page.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TreeItem {
    pub path: Vec<u8>,
    pub name: Vec<u8>,
    pub oid: Oid,
    pub kind: TreeItemKind,
    pub mode: u32,
    pub size: Option<u64>,
}

/// Resource accounting shared by query results.
///
/// Stats are derived from the [`Budget`] handed to the query, so reusing one
/// budget across calls accumulates spend; one budget per job is intended.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct QueryStats {
    pub objects_read: u64,
    pub bytes_read: u64,
    pub entries_emitted: u64,
    pub cache_hits: u64,
    pub cache_misses: u64,
    pub cache_bytes: u64,
    pub cache_entries: u64,
    pub cache_evictions: u64,
    pub files_scanned: u64,
    pub blobs_deduped: u64,
    pub binary_skipped: u64,
    pub oversize_skipped: u64,
    pub payload_rereads: u64,
    pub stopped_by: Option<&'static str>,
}

/// One page from a deterministic tree walk.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TreePage {
    pub entries: Vec<TreeItem>,
    pub next_cursor: Option<Vec<u8>>,
    pub truncated: bool,
    pub stats: QueryStats,
}

/// Lists a path in a pinned snapshot.
///
/// Size and count limits can produce partial pages. Timeout and cancellation
/// always produce errors and discard any entries accumulated by this call.
pub fn list_tree(
    store: &dyn ObjectDb,
    snapshot: &Snapshot,
    opts: &TreeOptions,
    budget: &Budget,
) -> Result<TreePage, Error> {
    ensure_query_compatible(store, snapshot)?;
    validate_path(&opts.path)?;
    if opts.limit == 0 {
        return Err(Error::new(
            ErrorCode::InvalidArgument,
            "tree page limit must be greater than zero",
        ));
    }

    let fingerprint = option_fingerprint(opts);
    let expected = CursorExpected {
        hash_kind: snapshot.commit_oid.kind(),
        snapshot_digest: snapshot.commit_oid.as_bytes(),
        operation_tag: OPERATION_LIST_TREE,
        option_fingerprint: fingerprint,
    };
    let resume = match opts.cursor.as_deref() {
        Some(bytes) => {
            let decoded = cursor::decode(bytes, expected)?;
            if !decoded.generation.is_empty() {
                return Err(invalid_cursor(
                    "generation check failed for this object store",
                ));
            }
            validate_cursor_position(&decoded.position, &opts.path)?;
            decoded.position
        }
        None => Vec::new(),
    };

    let tree_oid = match resolve_path(store, snapshot, &opts.path, budget)? {
        ResolvedPath::RootTree(oid) => oid,
        ResolvedPath::Entry(entry) if entry.kind == TreeItemKind::Tree => entry.oid,
        ResolvedPath::Entry(_) => {
            return Err(Error::new(
                ErrorCode::NotATree,
                "path does not resolve to a tree",
            ))
        }
    };

    let matcher = PathspecMatcher::new(&opts.pathspecs);
    let mut walker = Walker {
        store,
        budget,
        opts,
        matcher,
        resume: &resume,
        entries: Vec::with_capacity(opts.limit.min(1_024)),
    };
    let max_depth = if opts.recursive {
        opts.depth.unwrap_or(u32::MAX)
    } else {
        1
    };
    let outcome = if max_depth == 0 {
        WalkOutcome::Complete
    } else {
        match walker.walk_tree(tree_oid, &opts.path, max_depth) {
            Ok(outcome) => outcome,
            // Provider ceilings are transport backpressure, not stable
            // pagination boundaries: retrying a cursor could spend the same
            // remote budget again. Surface them as hard named failures.
            Err(error)
                if error.code == ErrorCode::BudgetExceeded
                    && matches!(
                        error.limit,
                        Some("max_provider_requests" | "max_provider_bytes")
                    ) =>
            {
                return Err(error);
            }
            Err(error) if error.code == ErrorCode::BudgetExceeded => {
                WalkOutcome::Stopped(error.limit.unwrap_or("budget"))
            }
            Err(error) => return Err(error),
        }
    };

    let (truncated, stopped_by) = match outcome {
        WalkOutcome::Complete => (false, None),
        WalkOutcome::Stopped(limit) => (true, Some(limit)),
    };
    if truncated && walker.entries.is_empty() {
        return Err(Error::new(
            ErrorCode::BudgetExceeded,
            "budget exhausted before any pagination progress",
        )
        .with_limit(stopped_by.expect("a stopped walk names its limit")));
    }
    let next_cursor = if truncated {
        let position = walker
            .entries
            .last()
            .expect("a truncated page made pagination progress")
            .path
            .clone();
        let encoded = cursor::encode(&Cursor {
            hash_kind: snapshot.commit_oid.kind(),
            snapshot_digest: snapshot.commit_oid.as_bytes().to_vec(),
            operation_tag: OPERATION_LIST_TREE,
            option_fingerprint: fingerprint,
            generation: Vec::new(),
            position,
        });
        if encoded.len() > MAX_CURSOR_BYTES {
            return Err(Error::new(
                ErrorCode::ResultTooLarge,
                "tree continuation path exceeds the cursor size limit",
            ));
        }
        Some(encoded)
    } else {
        None
    };

    let (objects_read, bytes_read, _, _) = budget.spent();
    let (cache_hits, cache_misses) = budget.cache_spent();
    let cache_stats = store.cache_stats();
    let entries_emitted = walker.entries.len() as u64;
    Ok(TreePage {
        entries: walker.entries,
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

struct Walker<'a> {
    store: &'a dyn ObjectDb,
    budget: &'a Budget,
    opts: &'a TreeOptions,
    matcher: PathspecMatcher,
    resume: &'a [u8],
    entries: Vec<TreeItem>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum WalkOutcome {
    Complete,
    Stopped(&'static str),
}

impl Walker<'_> {
    fn walk_tree(&mut self, oid: Oid, prefix: &[u8], max_depth: u32) -> Result<WalkOutcome, Error> {
        struct Frame {
            entries: std::vec::IntoIter<OwnedTreeEntry>,
            prefix: Vec<u8>,
            depth: u32,
        }

        let mut stack = vec![Frame {
            entries: read_tree_entries_for_walk(self.store, oid, self.budget, self.opts.recursive)?
                .into_iter(),
            prefix: prefix.to_vec(),
            depth: 1,
        }];
        while !stack.is_empty() {
            self.budget.check()?;
            let next = stack.last_mut().and_then(|frame| {
                frame.entries.next().map(|entry| {
                    let path = join_path(&frame.prefix, &entry.name);
                    (entry, path, frame.depth)
                })
            });
            let Some((entry, path, depth)) = next else {
                stack.pop();
                continue;
            };
            let relative_path = relative_to_scope(&path, &self.opts.path);
            let should_descend = entry.kind == TreeItemKind::Tree
                && self.opts.recursive
                && depth < max_depth
                && self.matcher.may_match_descendant(relative_path);
            let should_emit = self.opts.types.contains(entry.kind)
                && self.matcher.matches(relative_path)
                && (self.resume.is_empty() || path.as_slice() > self.resume);
            if should_emit {
                if self.entries.len() == self.opts.limit {
                    return Ok(WalkOutcome::Stopped("limit"));
                }

                self.budget.charge_tree_entry()?;
                let size = if self.opts.include_size
                    && matches!(entry.kind, TreeItemKind::Blob | TreeItemKind::Symlink)
                {
                    let header_read = self
                        .store
                        .try_header_with_provenance(&entry.oid, self.budget)?
                        .ok_or_else(|| missing_object(entry.oid, "listed entry"))?;
                    if header_read.header.kind != ObjectKind::Blob {
                        return Err(match header_read.provenance {
                            HeaderProvenance::UnverifiedProvider => Error::new(
                                ErrorCode::ProviderProtocolError,
                                "provider header contradicts tree entry kind",
                            ),
                            HeaderProvenance::Verified => Error::new(
                                ErrorCode::MalformedObject,
                                format!("listed blob {} addresses a non-blob object", entry.oid),
                            ),
                        });
                    }
                    Some(header_read.header.size)
                } else {
                    None
                };
                self.entries.push(TreeItem {
                    path: path.clone(),
                    name: entry.name,
                    oid: entry.oid,
                    kind: entry.kind,
                    mode: entry.mode,
                    size,
                });
            }

            if should_descend {
                let depth = depth.saturating_add(1);
                let entries = read_tree_entries_for_walk(
                    self.store,
                    entry.oid,
                    self.budget,
                    self.opts.recursive,
                )?;
                stack.push(Frame {
                    entries: entries.into_iter(),
                    prefix: path,
                    depth,
                });
            }
        }
        Ok(WalkOutcome::Complete)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedEntry {
    pub(crate) oid: Oid,
    pub(crate) mode: u32,
    pub(crate) kind: TreeItemKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ResolvedPath {
    RootTree(Oid),
    Entry(ResolvedEntry),
}

pub(crate) fn resolve_path(
    store: &dyn ObjectDb,
    snapshot: &Snapshot,
    path: &[u8],
    budget: &Budget,
) -> Result<ResolvedPath, Error> {
    validate_path(path)?;
    if path.is_empty() {
        return Ok(ResolvedPath::RootTree(snapshot.tree_oid));
    }

    let mut tree_oid = snapshot.tree_oid;
    let mut segments = path.split(|byte| *byte == b'/').peekable();
    while let Some(segment) = segments.next() {
        let entries = read_tree_entries(store, tree_oid, budget)?;
        let entry = entries
            .into_iter()
            .find(|entry| entry.name == segment)
            .ok_or_else(path_not_found)?;
        if segments.peek().is_none() {
            return Ok(ResolvedPath::Entry(ResolvedEntry {
                oid: entry.oid,
                mode: entry.mode,
                kind: entry.kind,
            }));
        }
        if entry.kind != TreeItemKind::Tree {
            return Err(path_not_found());
        }
        tree_oid = entry.oid;
    }
    Err(path_not_found())
}

#[derive(Debug)]
pub(crate) struct OwnedTreeEntry {
    pub(crate) mode: u32,
    pub(crate) name: Vec<u8>,
    pub(crate) oid: Oid,
    pub(crate) kind: TreeItemKind,
}

fn read_tree_entries(
    store: &dyn ObjectDb,
    oid: Oid,
    budget: &Budget,
) -> Result<Vec<OwnedTreeEntry>, Error> {
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
    decode_tree(&payload, store.hash_kind())
        .map(|entry| {
            let entry = entry?;
            validate_tree_name(entry.name)?;
            Ok(OwnedTreeEntry {
                mode: entry.mode,
                name: entry.name.to_vec(),
                oid: entry.oid,
                kind: kind_from_mode(entry.mode)?,
            })
        })
        .collect()
}

pub(crate) fn resolve_path_for_graph_walk(
    store: &dyn ObjectDb,
    snapshot: &Snapshot,
    path: &[u8],
    budget: &Budget,
) -> Result<ResolvedPath, Error> {
    validate_path(path)?;
    if path.is_empty() {
        return Ok(ResolvedPath::RootTree(snapshot.tree_oid));
    }

    let mut tree_oid = snapshot.tree_oid;
    let mut segments = path.split(|byte| *byte == b'/').peekable();
    while let Some(segment) = segments.next() {
        let entries = read_tree_entries_graph(store, tree_oid, budget)?;
        let entry = entries
            .into_iter()
            .find(|entry| entry.name == segment)
            .ok_or_else(path_not_found)?;
        if segments.peek().is_none() {
            return Ok(ResolvedPath::Entry(ResolvedEntry {
                oid: entry.oid,
                mode: entry.mode,
                kind: entry.kind,
            }));
        }
        if entry.kind != TreeItemKind::Tree {
            return Err(path_not_found());
        }
        tree_oid = entry.oid;
    }
    Err(path_not_found())
}

fn read_tree_entries_graph(
    store: &dyn ObjectDb,
    oid: Oid,
    budget: &Budget,
) -> Result<Vec<OwnedTreeEntry>, Error> {
    let mut payload = Vec::new();
    let kind = store
        .try_find_graph(&oid, &mut payload, budget)?
        .ok_or_else(|| missing_object(oid, "tree"))?;
    if kind != ObjectKind::Tree {
        return Err(Error::new(
            ErrorCode::NotATree,
            format!("tree object {oid} is not a tree"),
        ));
    }
    decode_owned_tree_entries(&payload, store.hash_kind())
}

fn decode_owned_tree_entries(
    payload: &[u8],
    hash_kind: HashKind,
) -> Result<Vec<OwnedTreeEntry>, Error> {
    decode_tree(payload, hash_kind)
        .map(|entry| {
            let entry = entry?;
            validate_tree_name(entry.name)?;
            Ok(OwnedTreeEntry {
                mode: entry.mode,
                name: entry.name.to_vec(),
                oid: entry.oid,
                kind: kind_from_mode(entry.mode)?,
            })
        })
        .collect()
}

pub(crate) fn read_tree_entries_for_walk(
    store: &dyn ObjectDb,
    oid: Oid,
    budget: &Budget,
    prefetch_children: bool,
) -> Result<Vec<OwnedTreeEntry>, Error> {
    let entries = read_tree_entries(store, oid, budget)?;
    if prefetch_children && store.supports_prefetch() {
        let child_trees = entries
            .iter()
            .filter(|entry| entry.kind == TreeItemKind::Tree)
            .map(|entry| entry.oid)
            .collect::<Vec<_>>();
        if !child_trees.is_empty() {
            store.prefetch(&child_trees, budget)?;
        }
    }
    Ok(entries)
}

pub(crate) fn read_tree_entries_for_graph_walk(
    store: &dyn ObjectDb,
    oid: Oid,
    budget: &Budget,
) -> Result<Vec<OwnedTreeEntry>, Error> {
    let entries = read_tree_entries_graph(store, oid, budget)?;
    if store.supports_prefetch() {
        let child_trees = entries
            .iter()
            .filter(|entry| entry.kind == TreeItemKind::Tree)
            .map(|entry| entry.oid)
            .collect::<Vec<_>>();
        if !child_trees.is_empty() {
            store.prefetch(&child_trees, budget)?;
        }
    }
    Ok(entries)
}

pub(crate) fn kind_from_mode(mode: u32) -> Result<TreeItemKind, Error> {
    match mode & 0o170000 {
        0o040000 => Ok(TreeItemKind::Tree),
        0o100000 => Ok(TreeItemKind::Blob),
        0o120000 => Ok(TreeItemKind::Symlink),
        0o160000 => Ok(TreeItemKind::Gitlink),
        _ => Err(Error::new(
            ErrorCode::MalformedObject,
            format!("tree entry has unsupported mode {mode:o}"),
        )),
    }
}

pub(crate) fn validate_path(path: &[u8]) -> Result<(), Error> {
    if path.contains(&0) {
        return Err(Error::new(
            ErrorCode::InvalidPath,
            "path contains a NUL byte",
        ));
    }
    if !path.is_empty() {
        for segment in path.split(|byte| *byte == b'/') {
            if segment == b"." || segment == b".." {
                return Err(Error::new(
                    ErrorCode::InvalidPath,
                    "path contains a semantic dot segment",
                ));
            }
            if segment.is_empty() {
                return Err(Error::new(
                    ErrorCode::InvalidPath,
                    "path contains an empty segment",
                ));
            }
        }
    }
    Ok(())
}

/// Validate a single literal path for operations whose internal diff must not
/// accidentally reinterpret user input as a pathspec.
pub(crate) fn validate_literal_path(path: &[u8], operation: &str) -> Result<(), Error> {
    validate_path(path)?;
    if path.starts_with(b":(") || path.iter().any(|byte| matches!(byte, b'*' | b'?' | b'[')) {
        return Err(Error::new(
            ErrorCode::InvalidArgument,
            format!("{operation} path must be literal, not a pathspec"),
        )
        .with_reason("pathspec_not_literal"));
    }
    Ok(())
}

pub(crate) fn ensure_query_compatible(
    store: &dyn ObjectDb,
    snapshot: &Snapshot,
) -> Result<(), Error> {
    if store.hash_kind() == HashKind::Sha256 {
        return Err(Error::new(
            ErrorCode::UnsupportedHash,
            "SHA-256 query execution not yet supported",
        ));
    }
    if snapshot.commit_oid.kind() != store.hash_kind()
        || snapshot.tree_oid.kind() != store.hash_kind()
    {
        return Err(Error::new(
            ErrorCode::InvalidOid,
            "snapshot object ID algorithm does not match the object store",
        ));
    }
    Ok(())
}

fn validate_tree_name(name: &[u8]) -> Result<(), Error> {
    if name.is_empty() || name.contains(&0) || name.contains(&b'/') || name == b"." || name == b".."
    {
        return Err(Error::new(
            ErrorCode::MalformedObject,
            "tree entry name is malformed",
        ));
    }
    Ok(())
}

fn validate_cursor_position(position: &[u8], base: &[u8]) -> Result<(), Error> {
    if position.is_empty() {
        return Ok(());
    }
    validate_path(position).map_err(|_| invalid_cursor("position path check failed"))?;
    if !base.is_empty()
        && !(position.starts_with(base)
            && position.get(base.len()) == Some(&b'/')
            && position.len() > base.len() + 1)
    {
        return Err(invalid_cursor("position path is outside the listed tree"));
    }
    Ok(())
}

pub(crate) fn join_path(prefix: &[u8], name: &[u8]) -> Vec<u8> {
    if prefix.is_empty() {
        return name.to_vec();
    }
    let mut path = Vec::with_capacity(prefix.len().saturating_add(1).saturating_add(name.len()));
    path.extend_from_slice(prefix);
    path.push(b'/');
    path.extend_from_slice(name);
    path
}

pub(crate) fn relative_to_scope<'a>(path: &'a [u8], scope: &[u8]) -> &'a [u8] {
    if scope.is_empty() {
        path
    } else {
        &path[scope.len() + 1..]
    }
}

/// Canonical list-tree option serialization (cursor v1): ASCII domain tag,
/// then path as u32-LE length + bytes; recursive as u8; depth as tag u8
/// (`0` none, `1` some) plus u32-LE when present; the type-filter bitset;
/// pathspec count u32-LE followed by each pattern's u32-LE length + bytes in
/// caller order; and include-size as u8. `limit` and `cursor` are omitted.
fn option_fingerprint(opts: &TreeOptions) -> u64 {
    let mut canonical = b"gitility:list_tree:options:v1\0".to_vec();
    push_bytes(&mut canonical, &opts.path);
    canonical.push(u8::from(opts.recursive));
    match opts.depth {
        Some(depth) => {
            canonical.push(1);
            canonical.extend_from_slice(&depth.to_le_bytes());
        }
        None => canonical.push(0),
    }
    canonical.push(opts.types.bits());
    canonical.extend_from_slice(
        &u32::try_from(opts.pathspecs.len())
            .unwrap_or(u32::MAX)
            .to_le_bytes(),
    );
    for pattern in &opts.pathspecs {
        push_bytes(&mut canonical, pattern);
    }
    canonical.push(u8::from(opts.include_size));
    cursor::fnv1a_64(&canonical)
}

fn push_bytes(out: &mut Vec<u8>, bytes: &[u8]) {
    out.extend_from_slice(&u32::try_from(bytes.len()).unwrap_or(u32::MAX).to_le_bytes());
    out.extend_from_slice(bytes);
}

fn missing_object(oid: Oid, role: &str) -> Error {
    Error::new(
        ErrorCode::MissingObject,
        format!("{role} object {oid} is missing from the object store"),
    )
}

fn path_not_found() -> Error {
    Error::new(
        ErrorCode::InvalidPath,
        "path does not exist in this snapshot",
    )
}

fn invalid_cursor(message: &'static str) -> Error {
    Error::new(ErrorCode::InvalidCursor, message)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::local_odb::LocalOdb;
    use crate::test_support::{fixture_oid, fixture_repo};
    use std::sync::atomic::AtomicBool;
    use std::sync::Arc;

    fn fixture() -> (LocalOdb, Snapshot) {
        let (store, _) = LocalOdb::open(fixture_repo("sha1-basic.git"), Default::default())
            .expect("fixture opens");
        let snapshot = Snapshot::open(&store, fixture_oid("sha1_basic_head"), &Budget::unlimited())
            .expect("snapshot opens");
        (store, snapshot)
    }

    fn recursive_options() -> TreeOptions {
        TreeOptions {
            recursive: true,
            limit: 100,
            ..TreeOptions::default()
        }
    }

    fn shape(entries: &[TreeItem]) -> Vec<(&[u8], TreeItemKind)> {
        entries
            .iter()
            .map(|entry| (entry.path.as_slice(), entry.kind))
            .collect()
    }

    fn recursive_all_shape() -> Vec<(&'static [u8], TreeItemKind)> {
        vec![
            (b"README.md", TreeItemKind::Blob),
            (b"assets", TreeItemKind::Tree),
            (b"assets/large.bin", TreeItemKind::Blob),
            (b"binary.dat", TreeItemKind::Blob),
            (b"empty-dir", TreeItemKind::Tree),
            (b"empty.bin", TreeItemKind::Blob),
            (b"invalid-\xff-name.txt", TreeItemKind::Blob),
            (b"link-to-nested", TreeItemKind::Symlink),
            (b"long-line.txt", TreeItemKind::Blob),
            (b"modules", TreeItemKind::Tree),
            (b"modules/example", TreeItemKind::Gitlink),
            (b"quoted-\"\x01-name.txt", TreeItemKind::Blob),
            (b"repeated", TreeItemKind::Tree),
            (b"repeated/one.txt", TreeItemKind::Blob),
            (b"repeated/two.txt", TreeItemKind::Blob),
            (b"run-fixture", TreeItemKind::Blob),
            (b"src", TreeItemKind::Tree),
            (b"src/story.txt", TreeItemKind::Blob),
            (b"subdir", TreeItemKind::Tree),
            (b"subdir/nested.txt", TreeItemKind::Blob),
            (b"subdir/second.txt", TreeItemKind::Blob),
        ]
    }

    #[test]
    fn recursive_listing_matches_the_fifteen_terminal_fixture_entries() {
        let (store, snapshot) = fixture();
        let page = list_tree(
            &store,
            &snapshot,
            &TreeOptions {
                types: TypeFilter::BLOB | TypeFilter::SYMLINK | TypeFilter::GITLINK,
                ..recursive_options()
            },
            &Budget::unlimited(),
        )
        .expect("tree lists");
        assert_eq!(
            shape(&page.entries),
            vec![
                (b"README.md".as_slice(), TreeItemKind::Blob),
                (b"assets/large.bin", TreeItemKind::Blob),
                (b"binary.dat", TreeItemKind::Blob),
                (b"empty.bin", TreeItemKind::Blob),
                (b"invalid-\xff-name.txt", TreeItemKind::Blob),
                (b"link-to-nested", TreeItemKind::Symlink),
                (b"long-line.txt", TreeItemKind::Blob),
                (b"modules/example", TreeItemKind::Gitlink),
                (b"quoted-\"\x01-name.txt", TreeItemKind::Blob),
                (b"repeated/one.txt", TreeItemKind::Blob),
                (b"repeated/two.txt", TreeItemKind::Blob),
                (b"run-fixture", TreeItemKind::Blob),
                (b"src/story.txt", TreeItemKind::Blob),
                (b"subdir/nested.txt", TreeItemKind::Blob),
                (b"subdir/second.txt", TreeItemKind::Blob),
            ]
        );
        assert!(!page.truncated);
        assert_eq!(page.stats.entries_emitted, 15);

        assert!(page.entries.iter().any(|entry| {
            entry.path == b"run-fixture"
                && entry.kind == TreeItemKind::Blob
                && entry.mode == 0o100755
        }));
        assert!(page.entries.iter().any(|entry| {
            entry.path == b"link-to-nested" && entry.kind == TreeItemKind::Symlink
        }));
        assert!(page.entries.iter().any(|entry| {
            entry.path == b"modules/example" && entry.kind == TreeItemKind::Gitlink
        }));
        assert!(page.entries.iter().any(|entry| entry.path == b"empty.bin"));
        assert!(page.entries.iter().any(|entry| entry.path == b"binary.dat"));
    }

    #[test]
    fn recursive_tree_emission_matches_git_r_t_preorder() {
        let (store, snapshot) = fixture();
        let trees = list_tree(
            &store,
            &snapshot,
            &TreeOptions {
                types: TypeFilter::TREE,
                ..recursive_options()
            },
            &Budget::unlimited(),
        )
        .expect("tree-only recursive listing succeeds");
        assert_eq!(
            shape(&trees.entries),
            vec![
                (b"assets".as_slice(), TreeItemKind::Tree),
                (b"empty-dir", TreeItemKind::Tree),
                (b"modules", TreeItemKind::Tree),
                (b"repeated", TreeItemKind::Tree),
                (b"src", TreeItemKind::Tree),
                (b"subdir", TreeItemKind::Tree),
            ]
        );

        let all = list_tree(
            &store,
            &snapshot,
            &recursive_options(),
            &Budget::unlimited(),
        )
        .expect("recursive all-types listing succeeds");
        assert_eq!(shape(&all.entries), recursive_all_shape());
        assert_eq!(all.stats.entries_emitted, 21);
        assert!(!all.truncated);
    }

    #[test]
    fn non_recursive_depth_and_type_filters_are_git_compatible() {
        let (store, snapshot) = fixture();
        let non_recursive = list_tree(
            &store,
            &snapshot,
            &TreeOptions {
                limit: 100,
                ..TreeOptions::default()
            },
            &Budget::unlimited(),
        )
        .expect("root lists");
        assert_eq!(non_recursive.entries.len(), 14);
        assert!(non_recursive
            .entries
            .iter()
            .any(|entry| entry.kind == TreeItemKind::Tree));

        let depth_one = list_tree(
            &store,
            &snapshot,
            &TreeOptions {
                recursive: true,
                depth: Some(1),
                limit: 100,
                ..TreeOptions::default()
            },
            &Budget::unlimited(),
        )
        .expect("depth-one tree lists");
        assert_eq!(depth_one.entries, non_recursive.entries);

        let blobs = list_tree(
            &store,
            &snapshot,
            &TreeOptions {
                types: TypeFilter::BLOB,
                ..recursive_options()
            },
            &Budget::unlimited(),
        )
        .expect("blob-filtered tree lists");
        assert_eq!(blobs.entries.len(), 13);
        assert!(blobs
            .entries
            .iter()
            .all(|entry| entry.kind == TreeItemKind::Blob));
    }

    #[test]
    fn pathspec_filters_have_exact_ordered_results() {
        let (store, snapshot) = fixture();
        let nested_txt = list_tree(
            &store,
            &snapshot,
            &TreeOptions {
                pathspecs: vec![b"**/*.txt".to_vec()],
                ..recursive_options()
            },
            &Budget::unlimited(),
        )
        .expect("double-star pathspec lists");
        assert_eq!(
            shape(&nested_txt.entries),
            vec![
                (b"invalid-\xff-name.txt".as_slice(), TreeItemKind::Blob),
                (b"long-line.txt", TreeItemKind::Blob),
                (b"quoted-\"\x01-name.txt", TreeItemKind::Blob),
                (b"repeated/one.txt", TreeItemKind::Blob),
                (b"repeated/two.txt", TreeItemKind::Blob),
                (b"src/story.txt", TreeItemKind::Blob),
                (b"subdir/nested.txt", TreeItemKind::Blob),
                (b"subdir/second.txt", TreeItemKind::Blob),
            ]
        );

        let root_txt = list_tree(
            &store,
            &snapshot,
            &TreeOptions {
                pathspecs: vec![b"*.txt".to_vec()],
                ..recursive_options()
            },
            &Budget::unlimited(),
        )
        .expect("single-star pathspec lists");
        assert_eq!(
            shape(&root_txt.entries),
            vec![
                (b"invalid-\xff-name.txt".as_slice(), TreeItemKind::Blob),
                (b"long-line.txt", TreeItemKind::Blob),
                (b"quoted-\"\x01-name.txt", TreeItemKind::Blob),
            ]
        );
    }

    #[test]
    fn pathspecs_are_relative_to_scope_and_literal_directories_include_descendants() {
        let (store, snapshot) = fixture();
        for (pattern, expected) in [
            (
                b"*.txt".as_slice(),
                vec![
                    (b"subdir/nested.txt".as_slice(), TreeItemKind::Blob),
                    (b"subdir/second.txt".as_slice(), TreeItemKind::Blob),
                ],
            ),
            (
                b"nested.txt".as_slice(),
                vec![(b"subdir/nested.txt".as_slice(), TreeItemKind::Blob)],
            ),
            (b"subdir/*.txt".as_slice(), vec![]),
        ] {
            let page = list_tree(
                &store,
                &snapshot,
                &TreeOptions {
                    path: b"subdir".to_vec(),
                    recursive: true,
                    pathspecs: vec![pattern.to_vec()],
                    limit: 100,
                    ..TreeOptions::default()
                },
                &Budget::unlimited(),
            )
            .expect("scoped pathspec lists");
            assert_eq!(shape(&page.entries), expected, "pattern {pattern:?}");
        }

        let root_anchored = list_tree(
            &store,
            &snapshot,
            &TreeOptions {
                recursive: true,
                pathspecs: vec![b"subdir/*.txt".to_vec()],
                limit: 100,
                ..TreeOptions::default()
            },
            &Budget::unlimited(),
        )
        .expect("root-relative wildcard lists");
        assert_eq!(
            shape(&root_anchored.entries),
            vec![
                (b"subdir/nested.txt".as_slice(), TreeItemKind::Blob),
                (b"subdir/second.txt", TreeItemKind::Blob),
            ]
        );

        let literal_directory = list_tree(
            &store,
            &snapshot,
            &TreeOptions {
                recursive: true,
                pathspecs: vec![b"subdir".to_vec()],
                limit: 100,
                ..TreeOptions::default()
            },
            &Budget::unlimited(),
        )
        .expect("literal directory pathspec lists");
        assert_eq!(
            shape(&literal_directory.entries),
            vec![
                (b"subdir".as_slice(), TreeItemKind::Tree),
                (b"subdir/nested.txt", TreeItemKind::Blob),
                (b"subdir/second.txt", TreeItemKind::Blob),
            ]
        );
    }

    #[test]
    fn scoped_pathspec_pagination_has_no_gaps_or_duplicates() {
        let (store, snapshot) = fixture();
        let expected = vec![
            (b"subdir/nested.txt".as_slice(), TreeItemKind::Blob),
            (b"subdir/second.txt".as_slice(), TreeItemKind::Blob),
        ];
        let mut cursor = None;
        let mut actual = Vec::new();
        loop {
            let page = list_tree(
                &store,
                &snapshot,
                &TreeOptions {
                    path: b"subdir".to_vec(),
                    recursive: true,
                    pathspecs: vec![b"*.txt".to_vec()],
                    limit: 1,
                    cursor,
                    ..TreeOptions::default()
                },
                &Budget::unlimited(),
            )
            .expect("scoped pathspec page lists");
            actual.extend(
                page.entries
                    .iter()
                    .map(|entry| (entry.path.clone(), entry.kind)),
            );
            cursor = page.next_cursor;
            if cursor.is_none() {
                break;
            }
        }
        assert_eq!(
            actual,
            expected
                .into_iter()
                .map(|(path, kind)| (path.to_vec(), kind))
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn subtree_paths_and_opt_in_sizes_are_preserved() {
        let (store, snapshot) = fixture();
        let page = list_tree(
            &store,
            &snapshot,
            &TreeOptions {
                path: b"src".to_vec(),
                include_size: true,
                limit: 100,
                ..TreeOptions::default()
            },
            &Budget::unlimited(),
        )
        .expect("subtree lists");
        assert_eq!(page.entries.len(), 1);
        assert_eq!(page.entries[0].path, b"src/story.txt");
        assert_eq!(page.entries[0].name, b"story.txt");
        assert_eq!(page.entries[0].size, Some(46));

        let root = list_tree(
            &store,
            &snapshot,
            &TreeOptions {
                include_size: true,
                limit: 100,
                ..TreeOptions::default()
            },
            &Budget::unlimited(),
        )
        .expect("sized root lists");
        assert_eq!(
            root.entries
                .iter()
                .find(|entry| entry.path == b"README.md")
                .and_then(|entry| entry.size),
            Some(50)
        );
        assert_eq!(
            root.entries
                .iter()
                .find(|entry| entry.path == b"empty.bin")
                .and_then(|entry| entry.size),
            Some(0)
        );
        assert!(root
            .entries
            .iter()
            .filter(|entry| matches!(entry.kind, TreeItemKind::Tree | TreeItemKind::Gitlink))
            .all(|entry| entry.size.is_none()));

        let recursive = list_tree(
            &store,
            &snapshot,
            &TreeOptions {
                include_size: true,
                ..recursive_options()
            },
            &Budget::unlimited(),
        )
        .expect("sized recursive tree lists");
        for (path, expected_size) in [
            (b"README.md".as_slice(), 50),
            (b"assets/large.bin", 262_144),
            (b"binary.dat", 18),
            (b"empty.bin", 0),
            (b"invalid-\xff-name.txt", 15),
            (b"link-to-nested", 17),
            (b"long-line.txt", 12_051),
            (b"quoted-\"\x01-name.txt", 15),
            (b"repeated/one.txt", 23),
            (b"repeated/two.txt", 23),
            (b"run-fixture", 40),
            (b"src/story.txt", 46),
            (b"subdir/nested.txt", 15),
            (b"subdir/second.txt", 14),
        ] {
            assert_eq!(
                recursive
                    .entries
                    .iter()
                    .find(|entry| entry.path == path)
                    .and_then(|entry| entry.size),
                Some(expected_size),
                "wrong size for {}",
                String::from_utf8_lossy(path)
            );
        }
    }

    #[test]
    fn cursor_pages_have_no_duplicates_or_gaps_and_bind_query_identity() {
        let (store, snapshot) = fixture();
        let expected = list_tree(
            &store,
            &snapshot,
            &recursive_options(),
            &Budget::unlimited(),
        )
        .expect("unpaginated tree lists")
        .entries;
        for limit in 1..=3 {
            let mut cursor = None;
            let mut actual = Vec::new();
            loop {
                let page = list_tree(
                    &store,
                    &snapshot,
                    &TreeOptions {
                        limit,
                        cursor: cursor.clone(),
                        ..recursive_options()
                    },
                    &Budget::unlimited(),
                )
                .expect("page lists");
                actual.extend(page.entries);
                cursor = page.next_cursor;
                if cursor.is_none() {
                    break;
                }
            }
            assert_eq!(actual, expected, "pagination mismatch at limit {limit}");
        }

        let tree_boundary = list_tree(
            &store,
            &snapshot,
            &TreeOptions {
                limit: 2,
                ..recursive_options()
            },
            &Budget::unlimited(),
        )
        .expect("tree-boundary page lists");
        assert_eq!(
            tree_boundary
                .entries
                .last()
                .map(|entry| entry.path.as_slice()),
            Some(b"assets".as_slice())
        );
        assert_eq!(
            tree_boundary.entries.last().map(|entry| entry.kind),
            Some(TreeItemKind::Tree)
        );
        let after_tree = list_tree(
            &store,
            &snapshot,
            &TreeOptions {
                limit: 2,
                cursor: tree_boundary.next_cursor,
                ..recursive_options()
            },
            &Budget::unlimited(),
        )
        .expect("page after a tree row lists its descendants");
        assert_eq!(
            after_tree
                .entries
                .first()
                .map(|entry| entry.path.as_slice()),
            Some(b"assets/large.bin".as_slice())
        );

        let cursor = list_tree(
            &store,
            &snapshot,
            &TreeOptions {
                limit: 3,
                ..recursive_options()
            },
            &Budget::unlimited(),
        )
        .expect("first page lists")
        .next_cursor
        .expect("first page continues");
        let mut tampered = cursor.clone();
        tampered[5] ^= 1;
        for options in [
            TreeOptions {
                limit: 3,
                cursor: Some(tampered),
                ..recursive_options()
            },
            TreeOptions {
                include_size: true,
                limit: 3,
                cursor: Some(cursor.clone()),
                ..recursive_options()
            },
        ] {
            assert_eq!(
                list_tree(&store, &snapshot, &options, &Budget::unlimited())
                    .expect_err("invalid cursor is rejected")
                    .code,
                ErrorCode::InvalidCursor
            );
        }

        let other = Snapshot {
            commit_oid: Oid::new(HashKind::Sha1, &[7; 20]).expect("valid oid"),
            ..snapshot
        };
        assert_eq!(
            list_tree(
                &store,
                &other,
                &TreeOptions {
                    limit: 3,
                    cursor: Some(cursor),
                    ..recursive_options()
                },
                &Budget::unlimited(),
            )
            .expect_err("cursor is bound to snapshot")
            .code,
            ErrorCode::InvalidCursor
        );
    }

    #[test]
    fn tree_entry_budget_returns_a_resumable_partial_page() {
        let (store, snapshot) = fixture();
        let budget = Budget::new(
            crate::budget::BudgetLimits {
                max_tree_entries: 2,
                ..crate::budget::BudgetLimits::default()
            },
            None,
            Arc::new(AtomicBool::new(false)),
        );
        let page = list_tree(&store, &snapshot, &recursive_options(), &budget)
            .expect("budget exhaustion truncates rather than failing");
        assert_eq!(page.entries.len(), 2);
        assert!(page.truncated);
        assert!(page.next_cursor.is_some());
        assert_eq!(page.stats.stopped_by, Some("max_tree_entries"));

        let resumed = list_tree(
            &store,
            &snapshot,
            &TreeOptions {
                cursor: page.next_cursor.clone(),
                ..recursive_options()
            },
            &Budget::unlimited(),
        )
        .expect("fresh budget resumes the partial page");
        let complete = list_tree(
            &store,
            &snapshot,
            &recursive_options(),
            &Budget::unlimited(),
        )
        .expect("complete listing succeeds");
        let mut combined = page.entries;
        combined.extend(resumed.entries);
        assert_eq!(combined, complete.entries);
    }

    #[test]
    fn object_budget_exhaustion_mid_walk_is_also_resumable() {
        let (store, snapshot) = fixture();
        let budget = Budget::new(
            crate::budget::BudgetLimits {
                max_objects: 1,
                ..crate::budget::BudgetLimits::default()
            },
            None,
            Arc::new(AtomicBool::new(false)),
        );
        let page = list_tree(&store, &snapshot, &recursive_options(), &budget)
            .expect("object budget exhaustion truncates");
        assert!(!page.entries.is_empty());
        assert!(page.truncated);
        let consumed_cursor = page.next_cursor.expect("partial page resumes");
        assert_eq!(page.stats.stopped_by, Some("max_objects"));

        let resumed_budget = Budget::new(
            crate::budget::BudgetLimits {
                max_objects: 2,
                ..crate::budget::BudgetLimits::default()
            },
            None,
            Arc::new(AtomicBool::new(false)),
        );
        let resumed = list_tree(
            &store,
            &snapshot,
            &TreeOptions {
                cursor: Some(consumed_cursor.clone()),
                ..recursive_options()
            },
            &resumed_budget,
        )
        .expect("a fresh object budget makes more progress");
        let resumed_cursor = resumed.next_cursor.expect("resumed page is partial");
        assert_ne!(resumed_cursor, consumed_cursor);
    }

    #[test]
    fn budget_exhaustion_before_any_pagination_progress_is_an_error() {
        let (store, snapshot) = fixture();
        let first_budget = Budget::new(
            crate::budget::BudgetLimits {
                max_objects: 1,
                ..crate::budget::BudgetLimits::default()
            },
            None,
            Arc::new(AtomicBool::new(false)),
        );
        let error = list_tree(
            &store,
            &snapshot,
            &TreeOptions {
                path: b"subdir".to_vec(),
                recursive: true,
                ..TreeOptions::default()
            },
            &first_budget,
        )
        .expect_err("a zero-progress first page is an error");
        assert_eq!(error.code, ErrorCode::BudgetExceeded);
        assert_eq!(
            error.message,
            "budget exhausted before any pagination progress"
        );
        assert_eq!(error.limit, Some("max_objects"));

        let first_page = list_tree(
            &store,
            &snapshot,
            &TreeOptions {
                limit: 2,
                ..recursive_options()
            },
            &Budget::unlimited(),
        )
        .expect("first page lists");
        let consumed_cursor = first_page.next_cursor.expect("first page resumes");
        let resumed_budget = Budget::new(
            crate::budget::BudgetLimits {
                max_objects: 1,
                ..crate::budget::BudgetLimits::default()
            },
            None,
            Arc::new(AtomicBool::new(false)),
        );
        let error = list_tree(
            &store,
            &snapshot,
            &TreeOptions {
                cursor: Some(consumed_cursor),
                ..recursive_options()
            },
            &resumed_budget,
        )
        .expect_err("a zero-progress resumed page is an error");
        assert_eq!(error.code, ErrorCode::BudgetExceeded);
        assert_eq!(
            error.message,
            "budget exhausted before any pagination progress"
        );
        assert_eq!(error.limit, Some("max_objects"));
    }

    #[test]
    fn include_size_reports_a_missing_listed_blob_as_a_missing_object() {
        let (store, _) = LocalOdb::open(fixture_repo("sha1-missing.git"), Default::default())
            .expect("missing-object fixture opens");
        let snapshot = Snapshot::open(&store, fixture_oid("sha1_basic_head"), &Budget::unlimited())
            .expect("unaffected commit opens");
        let error = list_tree(
            &store,
            &snapshot,
            &TreeOptions {
                include_size: true,
                limit: 100,
                ..TreeOptions::default()
            },
            &Budget::unlimited(),
        )
        .expect_err("missing listed blob header fails");
        assert_eq!(error.code, ErrorCode::MissingObject);
        assert!(error
            .message
            .contains(&fixture_oid("sha1_basic_readme").to_hex()));
    }

    #[test]
    fn invalid_and_missing_paths_are_distinct_from_missing_objects() {
        let (store, snapshot) = fixture();
        for path in [
            b"missing".as_slice(),
            b"src/./story.txt",
            b"src/../story.txt",
            b"nul\0path",
        ] {
            let err = list_tree(
                &store,
                &snapshot,
                &TreeOptions {
                    path: path.to_vec(),
                    ..TreeOptions::default()
                },
                &Budget::unlimited(),
            )
            .expect_err("invalid path fails");
            assert_eq!(err.code, ErrorCode::InvalidPath);
        }
        let err = list_tree(
            &store,
            &snapshot,
            &TreeOptions {
                path: b"README.md".to_vec(),
                ..TreeOptions::default()
            },
            &Budget::unlimited(),
        )
        .expect_err("blob is not a tree");
        assert_eq!(err.code, ErrorCode::NotATree);
    }
}
