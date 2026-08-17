//! Reference database contracts and the read-only local reference store.
//!
//! Refs are mutable names for immutable objects and live behind their own
//! seam. A [`RefDb`] is consulted only while creating a snapshot. Names are
//! raw bytes, and public resolution follows symbolic chains with a bounded,
//! cycle-detecting traversal.

use crate::budget::Budget;
use crate::cursor::{self, Cursor, CursorExpected, MAX_CURSOR_BYTES, OPERATION_REFS};
use crate::error::{Error, ErrorCode};
use crate::local_odb::{load_config, locate_git_dir, to_gix_hash, LocalOdb};
use crate::object::{HashKind, ObjectKind, Oid};
use crate::odb::ObjectDb;
use crate::snapshot::{peel, PeelTarget};
use gix_ref::bstr::ByteSlice;
use std::collections::HashSet;
use std::path::Path;
use std::sync::Arc;

/// Maximum number of symbolic-reference edges followed by one resolution.
pub const MAX_SYMBOLIC_REF_HOPS: usize = 16;

/// Maximum accepted length of a complete reference name.
///
/// Git itself accepts larger names, but provider and local stores share this
/// hostile-input ceiling so one oversized name cannot poison pagination.
pub const MAX_REF_NAME_BYTES: usize = 4096;
const COMPACT_CURSOR_GENERATION: &[u8] = b"\x01";
const COMPACT_REF_BLOCK_SYMBOLS: usize = 32;
const COMPACT_REF_BLOCK_BYTES: usize = 31;
const REF_NAME_ALPHABET_LEN: u16 = 215;

/// What a reference points at.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RefTarget {
    /// A direct ref. `peeled` is a commit when a tag target could be peeled
    /// without changing the direct target recorded in `oid`.
    Direct { oid: Oid, peeled: Option<Oid> },
    /// A symbolic ref naming another full ref (raw bytes).
    Symbolic(Vec<u8>),
}

/// A reference listing query.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RefQuery {
    /// Raw-byte name prefix filter (for example `refs/heads/`).
    pub prefix: Option<Vec<u8>>,
    /// Page size ceiling; the store may return fewer.
    pub limit: usize,
    /// Raw decoded cursor bytes from a previous page.
    pub cursor: Option<Vec<u8>>,
}

/// One page of references.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RefPage {
    /// `(raw full name, target)` pairs in byte order.
    pub refs: Vec<(Vec<u8>, RefTarget)>,
    pub next_cursor: Option<Vec<u8>>,
    pub truncated: bool,
    /// Per-reference failures skipped while producing this successful page.
    pub warnings: Vec<RefWarning>,
}

/// A reference-specific warning attached to a successful listing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RefWarning {
    /// Raw full name when the iterator could recover it.
    pub name: Vec<u8>,
    pub message: String,
}

/// A read-only reference store.
pub trait RefDb: Send + Sync + 'static {
    /// Resolves exactly one full reference name, without following a symbolic
    /// target. Missing refs are `None`, not errors.
    fn resolve(&self, name: &[u8], budget: &Budget) -> Result<Option<RefTarget>, Error>;

    /// Lists references matching a query.
    fn list(&self, query: RefQuery, budget: &Budget) -> Result<RefPage, Error>;

    /// Follows symbolic targets within one logical store call. Stores with
    /// call-scoped snapshots override this to retain one snapshot across all
    /// hops. The default intentionally performs an independent, per-hop-atomic
    /// `resolve()` call; providers requiring chain coherence should resolve
    /// symbolics internally and return direct targets.
    fn resolve_following(&self, name: &[u8], budget: &Budget) -> Result<Option<RefTarget>, Error> {
        resolve_with(name, budget, |current, budget| {
            self.resolve(current, budget)
        })
    }

    /// Invalidates cached ref state. The default does nothing.
    fn refresh(&self, budget: &Budget) -> Result<(), Error> {
        budget.check()
    }
}

/// Compile-time proof the contract stays `dyn`-compatible.
const _: fn(&dyn RefDb) = |_| {};

/// Follows symbolic references with a hard hop limit and explicit cycle
/// detection. The final direct target retains its direct and peeled IDs.
pub fn resolve_symbolic(
    store: &dyn RefDb,
    name: &[u8],
    budget: &Budget,
) -> Result<Option<RefTarget>, Error> {
    store.resolve_following(name, budget)
}

fn resolve_with(
    name: &[u8],
    budget: &Budget,
    mut resolve_one: impl FnMut(&[u8], &Budget) -> Result<Option<RefTarget>, Error>,
) -> Result<Option<RefTarget>, Error> {
    validate_full_ref_name(name)?;
    let mut current = name.to_vec();
    let mut seen = HashSet::new();
    let mut chain = Vec::new();

    for _ in 0..MAX_SYMBOLIC_REF_HOPS {
        budget.check()?;
        if !seen.insert(current.clone()) {
            chain.push(current);
            return Err(symbolic_cycle(&chain));
        }
        chain.push(current.clone());
        match resolve_one(&current, budget)? {
            None => return Ok(None),
            Some(RefTarget::Direct { oid, peeled }) => {
                return Ok(Some(RefTarget::Direct { oid, peeled }));
            }
            Some(RefTarget::Symbolic(next)) => {
                validate_full_ref_name(&next).map_err(|_| {
                    Error::new(
                        ErrorCode::MalformedRef,
                        "symbolic reference points to an invalid full ref name",
                    )
                    .with_reason(format!("symbolic target {}", display_ref(&next)))
                })?;
                current = next;
            }
        }
    }

    Err(Error::new(
        ErrorCode::MalformedRef,
        "symbolic reference exceeds the 16-hop limit",
    )
    .with_reason(format!("symbolic chain {}", display_chain(&chain))))
}

/// Validates the exact full-reference acceptance set used at provider and
/// local boundaries. `HEAD` is admitted for the safe `:head` selector;
/// every other accepted value must be below `refs/`. Git's component rules
/// are delegated to the same pinned `gix-validate` implementation used by
/// `gix-ref`.
pub fn validate_full_ref_name(name: &[u8]) -> Result<(), Error> {
    if name.len() > MAX_REF_NAME_BYTES {
        return Err(Error::new(
            ErrorCode::MalformedRef,
            "reference name exceeds the 4096-byte limit",
        )
        .with_reason(format!(
            "ref {} has length {} bytes (limit {MAX_REF_NAME_BYTES})",
            display_ref(name),
            name.len()
        )));
    }
    let valid_scope = name == b"HEAD" || name.starts_with(b"refs/");
    if !valid_scope || gix_ref::FullName::try_from(name.as_bstr()).is_err() {
        return Err(Error::new(
            ErrorCode::MalformedRef,
            "reference name is not a valid full ref name",
        )
        .with_reason(format!("ref {}", display_ref(name))));
    }
    Ok(())
}

/// Read-only local refs backed by the pinned `gix-ref` files store.
///
/// One `list` call obtains one overlay platform, which owns one immutable
/// packed-refs buffer snapshot for the duration of iteration. Loose refs may
/// change between calls; a call never interleaves two packed generations.
pub struct LocalRefDb {
    hash: HashKind,
    git_dir: std::path::PathBuf,
    objects: Arc<LocalOdb>,
}

impl std::fmt::Debug for LocalRefDb {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("LocalRefDb")
            .field("hash", &self.hash)
            .finish_non_exhaustive()
    }
}

impl LocalRefDb {
    /// Opens the file-format ref store belonging to `path`.
    ///
    /// `gix-ref` 0.66.0 covers loose and packed refs but has no reftable
    /// reader. Reftable repositories are detected from `extensions.refStorage`
    /// and refused explicitly instead of being read as an empty files store.
    pub fn open(path: impl AsRef<Path>, objects: Arc<LocalOdb>) -> Result<Self, Error> {
        let (git_dir, _) = locate_git_dir(path.as_ref())?;
        let config = load_config(&git_dir)?;
        if let Ok(value) = config.raw_value_by("extensions", None, "refStorage") {
            let value: &[u8] = value.as_ref();
            if !value.eq_ignore_ascii_case(b"files") {
                return Err(Error::new(
                    ErrorCode::UnsupportedOperation,
                    "local reference storage format is not supported",
                )
                .with_reason(format!(
                    "ref storage format {}",
                    String::from_utf8_lossy(value)
                )));
            }
        }
        let hash = objects.hash_kind();
        Ok(Self {
            hash,
            git_dir,
            objects,
        })
    }

    fn store(&self) -> gix_ref::file::Store {
        gix_ref::file::Store::at(
            self.git_dir.clone(),
            gix_ref::store::init::Options {
                write_reflog: gix_ref::store::WriteReflog::Disable,
                object_hash: to_gix_hash(self.hash),
                precompose_unicode: false,
                prohibit_windows_device_names: cfg!(windows),
            },
        )
    }

    fn target(&self, reference: gix_ref::Reference, budget: &Budget) -> Result<RefTarget, Error> {
        let name = reference.name.as_ref().as_bstr();
        match reference.target {
            gix_ref::Target::Symbolic(target) => {
                Ok(RefTarget::Symbolic(target.as_ref().as_bstr().to_vec()))
            }
            gix_ref::Target::Object(oid) => {
                let oid = Oid::new(self.hash, oid.as_bytes()).map_err(|_| {
                    Error::new(
                        ErrorCode::MalformedRef,
                        "local reference contains an invalid object ID",
                    )
                    .with_reason(format!("ref {}", display_ref(name)))
                })?;
                // A packed `^{}` line is authoritative, just as it is for
                // `git for-each-ref`, and avoids an ODB read. Otherwise peel
                // by target object kind, never by namespace. Every failure is
                // best-effort metadata loss: the direct OID is still the ref's
                // identity even when its target object is absent or corrupt.
                let peeled = reference
                    .peeled
                    .and_then(|peeled| Oid::new(self.hash, peeled.as_bytes()).ok())
                    .or_else(|| match self.objects.try_header(&oid, budget) {
                        Ok(Some(header)) if header.kind == ObjectKind::Tag => {
                            peel(self.objects.as_ref(), oid, PeelTarget::Commit, budget).ok()
                        }
                        Ok(_) | Err(_) => None,
                    });
                Ok(RefTarget::Direct { oid, peeled })
            }
        }
    }
}

impl RefDb for LocalRefDb {
    fn resolve(&self, name: &[u8], budget: &Budget) -> Result<Option<RefTarget>, Error> {
        budget.check()?;
        validate_full_ref_name(name)?;
        let full_name = gix_ref::FullName::try_from(name.as_bstr()).map_err(|_| {
            Error::new(ErrorCode::MalformedRef, "reference name is malformed")
                .with_reason(format!("ref {}", display_ref(name)))
        })?;
        let store = self.store();
        let reference = store
            .try_find(full_name.as_ref().as_partial_name())
            .map_err(|_| {
                Error::new(
                    ErrorCode::MalformedRef,
                    "local reference could not be decoded",
                )
                .with_reason(format!("ref {}", display_ref(name)))
            })?;
        reference
            .map(|reference| self.target(reference, budget))
            .transpose()
    }

    fn resolve_following(&self, name: &[u8], budget: &Budget) -> Result<Option<RefTarget>, Error> {
        // One store means one shared packed-refs snapshot is reused across
        // every symbolic hop in this public resolution call.
        let store = self.store();
        let packed = store.cached_packed_buffer().map_err(|_| {
            Error::new(
                ErrorCode::MalformedRef,
                "local packed-refs could not be snapshotted",
            )
            .with_reason(format!("ref {}", display_ref(name)))
        })?;
        let packed = packed.as_ref().map(|buffer| &***buffer);
        resolve_with(name, budget, |current, budget| {
            let full_name = gix_ref::FullName::try_from(current.as_bstr()).map_err(|_| {
                Error::new(ErrorCode::MalformedRef, "reference name is malformed")
                    .with_reason(format!("ref {}", display_ref(current)))
            })?;
            store
                .try_find_packed(full_name.as_ref().as_partial_name(), packed)
                .map_err(|_| {
                    Error::new(
                        ErrorCode::MalformedRef,
                        "local reference could not be decoded",
                    )
                    .with_reason(format!("ref {}", display_ref(current)))
                })?
                .map(|reference| self.target(reference, budget))
                .transpose()
        })
    }

    fn list(&self, query: RefQuery, budget: &Budget) -> Result<RefPage, Error> {
        budget.check()?;
        if query.limit == 0 {
            return Err(Error::new(
                ErrorCode::InvalidArgument,
                "reference page limit must be positive",
            ));
        }
        let fingerprint = ref_query_fingerprint(query.prefix.as_deref());
        let resume = query
            .cursor
            .as_deref()
            .map(|encoded| decode_ref_cursor(encoded, self.hash, fingerprint))
            .transpose()?;

        // The platform retains exactly one SharedBufferSnapshot for
        // packed-refs. Every overlay item below is read against it.
        let store = self.store();
        let platform = store.iter().map_err(|_| {
            Error::new(
                ErrorCode::MalformedRef,
                "local packed-refs could not be snapshotted",
            )
        })?;
        let iterator = match query.prefix.as_deref() {
            Some(prefix) => {
                let relative: &gix_path::RelativePath =
                    prefix.as_bstr().try_into().map_err(|_| {
                        Error::new(
                            ErrorCode::MalformedRef,
                            "reference prefix is not a valid relative path",
                        )
                        .with_reason(format!("prefix {}", display_ref(prefix)))
                    })?;
                platform.prefixed(relative)
            }
            None => platform.all(),
        }
        .map_err(|_| {
            Error::new(
                ErrorCode::BackendError,
                "local references could not be enumerated",
            )
        })?;
        let mut refs = Vec::with_capacity(query.limit);
        let mut warnings = Vec::new();
        let mut has_more = false;
        for reference in iterator {
            budget.check()?;
            let reference = match reference {
                Ok(reference) => reference,
                Err(error) => {
                    warnings.push(iteration_warning(error, &self.git_dir));
                    continue;
                }
            };
            let name = reference.name.as_ref().as_bstr().to_vec();
            if resume
                .as_deref()
                .is_some_and(|last| name.as_slice() <= last)
            {
                continue;
            }
            if let Err(error) = validate_full_ref_name(&name) {
                warnings.push(RefWarning {
                    name: name.clone(),
                    message: format!(
                        "skipped malformed reference {}: {}{}",
                        display_ref(&name),
                        error.message,
                        error
                            .reason
                            .as_deref()
                            .map_or_else(String::new, |reason| format!(" ({reason})"))
                    ),
                });
                continue;
            }
            if refs.len() == query.limit {
                has_more = true;
                break;
            }
            match self.target(reference, budget) {
                Ok(target) => refs.push((name, target)),
                Err(error) => warnings.push(RefWarning {
                    name: name.clone(),
                    message: format!(
                        "skipped malformed reference {}: {}{}",
                        display_ref(&name),
                        error.message,
                        error
                            .reason
                            .as_deref()
                            .map_or_else(String::new, |reason| format!(" ({reason})"))
                    ),
                }),
            }
        }

        let next_cursor = if has_more {
            let position = refs
                .last()
                .expect("a positive full page has a last reference")
                .0
                .clone();
            Some(encode_ref_cursor(self.hash, fingerprint, position)?)
        } else {
            None
        };
        Ok(RefPage {
            refs,
            next_cursor,
            truncated: has_more,
            warnings,
        })
    }
}

fn iteration_warning(
    error: gix_ref::file::iter::loose_then_packed::Error,
    git_dir: &Path,
) -> RefWarning {
    use gix_ref::file::iter::loose_then_packed::Error as IterError;

    let name = match &error {
        IterError::ReferenceCreation { relative_path, .. } => {
            relative_path.to_string_lossy().as_bytes().to_vec()
        }
        IterError::ReadFileContents { path, .. } => path
            .strip_prefix(git_dir)
            .unwrap_or(path)
            .to_string_lossy()
            .as_bytes()
            .to_vec(),
        IterError::PackedReference { invalid_line, .. } => invalid_line
            .as_slice()
            .split_once_str(b" ")
            .map_or_else(|| b"<unknown>".to_vec(), |(_, name)| name.to_vec()),
        IterError::Traversal(_) => b"<unknown>".to_vec(),
    };
    RefWarning {
        message: format!(
            "skipped malformed reference {}: {error}",
            display_ref(&name)
        ),
        name,
    }
}

fn ref_query_fingerprint(prefix: Option<&[u8]>) -> u64 {
    let mut normalized = b"refs-v1\0".to_vec();
    match prefix {
        None => normalized.push(0),
        Some(prefix) => {
            normalized.push(1);
            normalized.extend_from_slice(&(prefix.len() as u64).to_le_bytes());
            normalized.extend_from_slice(prefix);
        }
    }
    cursor::fnv1a_64(&normalized)
}

fn cursor_identity(hash: HashKind) -> Vec<u8> {
    vec![0; hash.digest_len()]
}

fn decode_ref_cursor(encoded: &[u8], hash: HashKind, fingerprint: u64) -> Result<Vec<u8>, Error> {
    let identity = cursor_identity(hash);
    let decoded = cursor::decode(
        encoded,
        CursorExpected {
            hash_kind: hash,
            snapshot_digest: &identity,
            operation_tag: OPERATION_REFS,
            option_fingerprint: fingerprint,
        },
    )?;
    let position = match decoded.generation.as_slice() {
        [] => decoded.position,
        COMPACT_CURSOR_GENERATION => decode_compact_ref_position(&decoded.position)?,
        _ => {
            return Err(invalid_cursor(
                "reference cursor generation is not recognized",
            ));
        }
    };
    validate_full_ref_name(&position)
        .map_err(|_| invalid_cursor("reference cursor position is not a full ref name"))?;
    Ok(position)
}

fn encode_ref_cursor(
    hash: HashKind,
    fingerprint: u64,
    position: Vec<u8>,
) -> Result<Vec<u8>, Error> {
    let mut cursor = Cursor {
        hash_kind: hash,
        snapshot_digest: cursor_identity(hash),
        operation_tag: OPERATION_REFS,
        option_fingerprint: fingerprint,
        generation: Vec::new(),
        position,
    };
    let mut encoded = cursor::encode(&cursor);
    if encoded.len() > MAX_CURSOR_BYTES {
        cursor.generation = COMPACT_CURSOR_GENERATION.to_vec();
        cursor.position = encode_compact_ref_position(&cursor.position)?;
        encoded = cursor::encode(&cursor);
    }
    if encoded.len() > MAX_CURSOR_BYTES {
        return Err(Error::new(
            ErrorCode::ResultTooLarge,
            "reference continuation name exceeds the cursor size limit",
        ));
    }
    Ok(encoded)
}

/// Packs the 215-byte alphabet accepted by Git ref names densely enough that
/// every valid 4096-byte full name fits the frozen 4096-byte cursor envelope.
/// Each 32-symbol base-215 block occupies 31 bytes; the short tail stays raw.
fn encode_compact_ref_position(position: &[u8]) -> Result<Vec<u8>, Error> {
    let length = u16::try_from(position.len()).map_err(|_| {
        Error::new(
            ErrorCode::ResultTooLarge,
            "reference continuation name exceeds the compact cursor limit",
        )
    })?;
    let full_blocks = position.len() / COMPACT_REF_BLOCK_SYMBOLS;
    let tail_start = full_blocks * COMPACT_REF_BLOCK_SYMBOLS;
    let mut encoded =
        Vec::with_capacity(2 + full_blocks * COMPACT_REF_BLOCK_BYTES + position.len() - tail_start);
    encoded.extend_from_slice(&length.to_le_bytes());
    for block in position[..tail_start].chunks_exact(COMPACT_REF_BLOCK_SYMBOLS) {
        let mut packed = [0u8; COMPACT_REF_BLOCK_BYTES];
        for byte in block {
            let mut carry = u16::from(ref_name_alphabet_rank(*byte).ok_or_else(|| {
                invalid_cursor("reference cursor position contains a forbidden byte")
            })?);
            for slot in &mut packed {
                let value = u16::from(*slot) * REF_NAME_ALPHABET_LEN + carry;
                *slot = value as u8;
                carry = value >> 8;
            }
            debug_assert_eq!(carry, 0);
        }
        encoded.extend_from_slice(&packed);
    }
    encoded.extend_from_slice(&position[tail_start..]);
    Ok(encoded)
}

fn decode_compact_ref_position(encoded: &[u8]) -> Result<Vec<u8>, Error> {
    let length = encoded
        .get(..2)
        .and_then(|bytes| <[u8; 2]>::try_from(bytes).ok())
        .map(u16::from_le_bytes)
        .map(usize::from)
        .ok_or_else(|| invalid_cursor("compact reference cursor length is missing"))?;
    if length > MAX_REF_NAME_BYTES {
        return Err(invalid_cursor(
            "compact reference cursor name exceeds 4096 bytes",
        ));
    }
    let full_blocks = length / COMPACT_REF_BLOCK_SYMBOLS;
    let tail_len = length % COMPACT_REF_BLOCK_SYMBOLS;
    let expected_len = 2 + full_blocks * COMPACT_REF_BLOCK_BYTES + tail_len;
    if encoded.len() != expected_len {
        return Err(invalid_cursor(
            "compact reference cursor payload length is invalid",
        ));
    }

    let mut position = Vec::with_capacity(length);
    let mut offset = 2;
    for _ in 0..full_blocks {
        let mut value = [0u8; COMPACT_REF_BLOCK_BYTES];
        value.copy_from_slice(&encoded[offset..offset + COMPACT_REF_BLOCK_BYTES]);
        let mut ranks = [0u8; COMPACT_REF_BLOCK_SYMBOLS];
        for rank in ranks.iter_mut().rev() {
            let mut remainder = 0u16;
            for slot in value.iter_mut().rev() {
                let dividend = (remainder << 8) | u16::from(*slot);
                *slot = (dividend / REF_NAME_ALPHABET_LEN) as u8;
                remainder = dividend % REF_NAME_ALPHABET_LEN;
            }
            *rank = remainder as u8;
        }
        if value.iter().any(|byte| *byte != 0) {
            return Err(invalid_cursor(
                "compact reference cursor block is outside the ref-name alphabet",
            ));
        }
        for rank in ranks {
            position.push(
                ref_name_alphabet_byte(rank)
                    .ok_or_else(|| invalid_cursor("compact reference cursor rank is invalid"))?,
            );
        }
        offset += COMPACT_REF_BLOCK_BYTES;
    }
    position.extend_from_slice(&encoded[offset..]);
    Ok(position)
}

fn ref_name_alphabet_rank(byte: u8) -> Option<u8> {
    if byte >= 0x80 {
        return Some(87 + (byte - 0x80));
    }
    if !(0x21..=0x7e).contains(&byte) || is_forbidden_ref_byte(byte) {
        return None;
    }
    let skipped = b"*:?[\\^~"
        .iter()
        .filter(|forbidden| **forbidden < byte)
        .count() as u8;
    Some(byte - 0x21 - skipped)
}

fn ref_name_alphabet_byte(rank: u8) -> Option<u8> {
    if rank >= 87 {
        return (rank <= 214).then_some(0x80 + (rank - 87));
    }
    let mut seen = 0u8;
    for byte in 0x21..=0x7e {
        if is_forbidden_ref_byte(byte) {
            continue;
        }
        if seen == rank {
            return Some(byte);
        }
        seen += 1;
    }
    None
}

fn is_forbidden_ref_byte(byte: u8) -> bool {
    matches!(byte, b'*' | b':' | b'?' | b'[' | b'\\' | b'^' | b'~')
}

fn invalid_cursor(message: &'static str) -> Error {
    Error::new(ErrorCode::InvalidCursor, message)
}

fn symbolic_cycle(chain: &[Vec<u8>]) -> Error {
    Error::new(ErrorCode::MalformedRef, "symbolic reference cycle detected")
        .with_reason(format!("symbolic cycle {}", display_chain(chain)))
}

fn display_chain(chain: &[Vec<u8>]) -> String {
    chain
        .iter()
        .map(|name| display_ref(name))
        .collect::<Vec<_>>()
        .join(" -> ")
}

fn display_ref(name: &[u8]) -> String {
    format!("{:?}", name.as_bstr())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{fixture_oid, fixture_repo};
    use std::collections::BTreeMap;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::process::Command;
    use std::sync::Mutex;

    struct InMemoryRefDb {
        refs: Mutex<BTreeMap<Vec<u8>, RefTarget>>,
        hash: HashKind,
    }

    impl RefDb for InMemoryRefDb {
        fn resolve(&self, name: &[u8], budget: &Budget) -> Result<Option<RefTarget>, Error> {
            budget.check()?;
            Ok(self.refs.lock().unwrap().get(name).cloned())
        }

        fn list(&self, query: RefQuery, budget: &Budget) -> Result<RefPage, Error> {
            budget.check()?;
            let refs = self
                .refs
                .lock()
                .unwrap()
                .iter()
                .filter(|(name, _)| query.prefix.as_ref().is_none_or(|p| name.starts_with(p)))
                .take(query.limit)
                .map(|(name, target)| (name.clone(), target.clone()))
                .collect();
            Ok(RefPage {
                refs,
                next_cursor: None,
                truncated: false,
                warnings: Vec::new(),
            })
        }
    }

    fn oid(byte: u8) -> Oid {
        Oid::new(HashKind::Sha1, &[byte; 20]).unwrap()
    }

    fn dangling_oid(byte: u8) -> Oid {
        let mut bytes = [0; 20];
        bytes[19] = byte;
        Oid::new(HashKind::Sha1, &bytes).unwrap()
    }

    fn fixture_copy(name: &str, label: &str) -> PathBuf {
        let destination = std::env::temp_dir().join(format!(
            "gitility-{label}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = fs::remove_dir_all(&destination);
        copy_tree(&fixture_repo(name), &destination);
        destination
    }

    fn copy_tree(source: &Path, destination: &Path) {
        fs::create_dir_all(destination).unwrap();
        for entry in fs::read_dir(source).unwrap() {
            let entry = entry.unwrap();
            let target = destination.join(entry.file_name());
            if entry.file_type().unwrap().is_dir() {
                copy_tree(&entry.path(), &target);
            } else {
                fs::copy(entry.path(), target).unwrap();
            }
        }
    }

    #[test]
    fn follows_symbolic_refs_and_reports_missing_as_none() {
        let store = InMemoryRefDb {
            refs: Mutex::new(BTreeMap::from([
                (
                    b"HEAD".to_vec(),
                    RefTarget::Symbolic(b"refs/heads/main".to_vec()),
                ),
                (
                    b"refs/heads/main".to_vec(),
                    RefTarget::Direct {
                        oid: oid(7),
                        peeled: None,
                    },
                ),
            ])),
            hash: HashKind::Sha1,
        };
        assert_eq!(
            resolve_symbolic(&store, b"HEAD", &Budget::unlimited()).unwrap(),
            Some(RefTarget::Direct {
                oid: oid(7),
                peeled: None
            })
        );
        assert!(
            resolve_symbolic(&store, b"refs/tags/missing", &Budget::unlimited())
                .unwrap()
                .is_none()
        );
        assert_eq!(store.hash, HashKind::Sha1);
    }

    #[test]
    fn symbolic_cycles_and_hop_overflow_are_malformed_and_name_the_chain() {
        let refs = BTreeMap::from([
            (
                b"refs/heads/a".to_vec(),
                RefTarget::Symbolic(b"refs/heads/b".to_vec()),
            ),
            (
                b"refs/heads/b".to_vec(),
                RefTarget::Symbolic(b"refs/heads/a".to_vec()),
            ),
        ]);
        let store = InMemoryRefDb {
            refs: Mutex::new(refs),
            hash: HashKind::Sha1,
        };
        let error = resolve_symbolic(&store, b"refs/heads/a", &Budget::unlimited()).unwrap_err();
        assert_eq!(error.code, ErrorCode::MalformedRef);
        assert!(error.reason.unwrap().contains("refs/heads/a"));

        let refs = (0..=MAX_SYMBOLIC_REF_HOPS)
            .map(|index| {
                (
                    format!("refs/heads/{index}").into_bytes(),
                    RefTarget::Symbolic(format!("refs/heads/{}", index + 1).into_bytes()),
                )
            })
            .collect();
        let store = InMemoryRefDb {
            refs: Mutex::new(refs),
            hash: HashKind::Sha1,
        };
        assert_eq!(
            resolve_symbolic(&store, b"refs/heads/0", &Budget::unlimited())
                .unwrap_err()
                .code,
            ErrorCode::MalformedRef
        );
    }

    #[test]
    fn full_name_validation_matches_git_component_rules_and_keeps_raw_bytes() {
        for valid in [
            b"HEAD".as_slice(),
            b"refs/heads/main",
            b"refs/heads/a/b/c",
            b"refs/heads/non-utf8-\xff",
            b"refs/heads/@",
            b"refs/heads/dot.hidden",
            b"refs/heads/@foo",
            b"refs/heads/trail./x",
            b"refs/heads/a.b.c",
            b"refs/heads/bracket]name",
        ] {
            assert!(validate_full_ref_name(valid).is_ok(), "{valid:?}");
        }
        for invalid in [
            b"main".as_slice(),
            b"refs/heads/.hidden",
            b"refs/heads/dot..dot",
            b"refs/heads/trailing.",
            b"refs/heads/name.lock",
            b"refs/heads/a@{b",
            b"refs/heads/a b",
            b"refs/heads/a\0b",
            b"refs/heads/a//b",
            b"refs/heads/",
            b"/refs/heads/main",
            b"refs/heads/back\\slash",
            b"refs/heads/tilde~name",
            b"refs/heads/caret^name",
            b"refs/heads/colon:name",
            b"refs/heads/bracket[name",
            b"refs/heads/question?name",
            b"refs/heads/star*name",
        ] {
            assert!(validate_full_ref_name(invalid).is_err(), "{invalid:?}");
        }

        let over_limit = [b"refs/heads/".as_slice(), &vec![b'a'; 4086]].concat();
        let error = validate_full_ref_name(&over_limit).unwrap_err();
        assert_eq!(error.code, ErrorCode::MalformedRef);
        assert!(error.reason.unwrap().contains("4097 bytes"));
    }

    #[test]
    fn ref_cursor_round_trips_raw_position_and_binds_prefix() {
        let fingerprint = ref_query_fingerprint(Some(b"refs/heads/"));
        let encoded =
            encode_ref_cursor(HashKind::Sha1, fingerprint, b"refs/heads/raw-\xff".to_vec())
                .unwrap();
        assert_eq!(
            decode_ref_cursor(&encoded, HashKind::Sha1, fingerprint).unwrap(),
            b"refs/heads/raw-\xff"
        );
        assert_eq!(
            decode_ref_cursor(
                &encoded,
                HashKind::Sha1,
                ref_query_fingerprint(Some(b"refs/tags/"))
            )
            .unwrap_err()
            .code,
            ErrorCode::InvalidCursor
        );

        let near_limit = [b"refs/heads/".as_slice(), &vec![b'a'; 4046]].concat();
        assert_eq!(near_limit.len(), 4057);
        let encoded = encode_ref_cursor(HashKind::Sha1, fingerprint, near_limit.clone()).unwrap();
        assert_eq!(encoded.len(), MAX_CURSOR_BYTES);
        assert_eq!(
            decode_ref_cursor(&encoded, HashKind::Sha1, fingerprint).unwrap(),
            near_limit
        );

        for length in [4058, MAX_REF_NAME_BYTES] {
            let long_name = [
                b"refs/heads/".as_slice(),
                &vec![b'a'; length - b"refs/heads/".len()],
            ]
            .concat();
            let compact =
                encode_ref_cursor(HashKind::Sha1, fingerprint, long_name.clone()).unwrap();
            assert!(compact.len() <= MAX_CURSOR_BYTES);
            assert_eq!(
                decode_ref_cursor(&compact, HashKind::Sha1, fingerprint).unwrap(),
                long_name
            );
        }

        let alphabet: Vec<u8> = (0..REF_NAME_ALPHABET_LEN as u8)
            .map(|rank| ref_name_alphabet_byte(rank).unwrap())
            .cycle()
            .take(MAX_REF_NAME_BYTES)
            .collect();
        let compact = encode_compact_ref_position(&alphabet).unwrap();
        assert_eq!(decode_compact_ref_position(&compact).unwrap(), alphabet);

        let mut forged = encoded;
        forged[8] ^= 0x40;
        assert_eq!(
            decode_ref_cursor(&forged, HashKind::Sha1, fingerprint)
                .unwrap_err()
                .code,
            ErrorCode::InvalidCursor
        );
    }

    #[test]
    fn reference_cursors_are_repository_agnostic_for_the_same_hash_and_query() {
        let open = |fixture| {
            let path = fixture_repo(fixture);
            let (objects, _) = LocalOdb::open(&path, Default::default()).unwrap();
            LocalRefDb::open(&path, Arc::new(objects)).unwrap()
        };
        let first = open("sha1-basic.git");
        let second = open("sha1-basic-packed.git");
        let query = RefQuery {
            prefix: Some(b"refs/tags/".to_vec()),
            limit: 1,
            cursor: None,
        };
        let page = first.list(query.clone(), &Budget::unlimited()).unwrap();
        assert!(page.truncated);
        let resumed = second
            .list(
                RefQuery {
                    cursor: page.next_cursor,
                    ..query
                },
                &Budget::unlimited(),
            )
            .unwrap();
        assert_eq!(resumed.refs.len(), 1);
        assert_eq!(resumed.refs[0].0, b"refs/tags/v1.0.0");
    }

    #[test]
    fn a_4096_byte_ref_can_end_a_page_without_overflowing_its_cursor() {
        let repository = fixture_copy("sha1-basic.git", "long-ref-page");
        let prefix = b"refs/zz-boundary-";
        let long_name = [
            prefix.as_slice(),
            &vec![b'a'; MAX_REF_NAME_BYTES - prefix.len()],
        ]
        .concat();
        let after = b"refs/zz-boundary-z";
        let oid = fixture_oid("sha1_basic_head");
        fs::write(
            repository.join("packed-refs"),
            format!(
                "# pack-refs with: peeled fully-peeled sorted\n{} {}\n{} {}\n",
                oid,
                String::from_utf8(long_name.clone()).unwrap(),
                oid,
                String::from_utf8(after.to_vec()).unwrap()
            ),
        )
        .unwrap();

        let (objects, _) = LocalOdb::open(&repository, Default::default()).unwrap();
        let refs = LocalRefDb::open(&repository, Arc::new(objects)).unwrap();
        let first = refs
            .list(
                RefQuery {
                    prefix: Some(prefix.to_vec()),
                    limit: 1,
                    cursor: None,
                },
                &Budget::unlimited(),
            )
            .unwrap();
        assert_eq!(first.refs[0].0, long_name);
        assert!(first.truncated);
        assert!(first.next_cursor.as_ref().unwrap().len() <= MAX_CURSOR_BYTES);

        let second = refs
            .list(
                RefQuery {
                    prefix: Some(prefix.to_vec()),
                    limit: 1,
                    cursor: first.next_cursor,
                },
                &Budget::unlimited(),
            )
            .unwrap();
        assert_eq!(second.refs[0].0, after);
        assert!(!second.truncated);
        fs::remove_dir_all(repository).unwrap();
    }

    #[test]
    fn local_store_resolves_loose_head_and_packed_refs_and_peels_tags() {
        for fixture in ["sha1-basic.git", "sha1-basic-packed.git"] {
            let path = fixture_repo(fixture);
            let (objects, _) = LocalOdb::open(&path, Default::default()).unwrap();
            let refs = LocalRefDb::open(&path, Arc::new(objects)).unwrap();
            let head = resolve_symbolic(&refs, b"HEAD", &Budget::unlimited())
                .unwrap()
                .unwrap();
            assert_eq!(
                head,
                RefTarget::Direct {
                    oid: fixture_oid("sha1_basic_head"),
                    peeled: None
                },
                "{fixture}"
            );

            let tag = resolve_symbolic(&refs, b"refs/tags/v1.0.0", &Budget::unlimited())
                .unwrap()
                .unwrap();
            let RefTarget::Direct { oid, peeled } = tag else {
                panic!("tag is direct")
            };
            assert_ne!(oid, fixture_oid("sha1_basic_head"));
            assert_eq!(peeled, Some(fixture_oid("sha1_basic_head")));
        }
    }

    #[test]
    fn dedicated_ref_fixture_covers_overlay_symbolic_raw_bytes_detached_head_and_three_pages() {
        let path = fixture_repo("sha1-refs.git");
        let (objects, _) = LocalOdb::open(&path, Default::default()).unwrap();
        let refs = LocalRefDb::open(&path, Arc::new(objects)).unwrap();
        let head = fixture_oid("sha1_refs_head");
        let parent = fixture_oid("sha1_refs_parent");

        for (name, expected) in [
            (b"refs/heads/packed-only".as_slice(), head),
            (b"refs/heads/loose-only".as_slice(), parent),
            (b"refs/heads/both".as_slice(), parent),
            (b"refs/heads/a/b/c".as_slice(), parent),
            (b"refs/heads/@".as_slice(), head),
            (b"refs/heads/symbolic-main".as_slice(), head),
            (b"refs/heads/raw-\xff".as_slice(), head),
        ] {
            assert_eq!(
                resolve_symbolic(&refs, name, &Budget::unlimited()).unwrap(),
                Some(RefTarget::Direct {
                    oid: expected,
                    peeled: None,
                }),
                "{}",
                name.as_bstr()
            );
        }

        assert_eq!(
            resolve_symbolic(&refs, b"refs/tags/refs-chain", &Budget::unlimited()).unwrap(),
            Some(RefTarget::Direct {
                oid: fixture_oid("sha1_refs_chain_tag"),
                peeled: Some(head),
            })
        );

        let mut cursor = None;
        let mut names = Vec::new();
        let mut pages = 0;
        loop {
            let page = refs
                .list(
                    RefQuery {
                        prefix: Some(b"refs/heads/page/".to_vec()),
                        limit: 17,
                        cursor,
                    },
                    &Budget::unlimited(),
                )
                .unwrap();
            pages += 1;
            names.extend(page.refs.into_iter().map(|(name, _)| name));
            cursor = page.next_cursor;
            if cursor.is_none() {
                break;
            }
        }
        assert_eq!(names.len(), 55);
        assert!(pages >= 3);
        assert!(names.windows(2).all(|pair| pair[0] < pair[1]));

        let detached_path = fixture_repo("sha1-refs-detached.git");
        let (detached_objects, _) = LocalOdb::open(&detached_path, Default::default()).unwrap();
        let detached_refs = LocalRefDb::open(&detached_path, Arc::new(detached_objects)).unwrap();
        assert_eq!(
            resolve_symbolic(&detached_refs, b"HEAD", &Budget::unlimited()).unwrap(),
            Some(RefTarget::Direct {
                oid: parent,
                peeled: None,
            })
        );
    }

    #[test]
    fn local_listing_isolates_broken_refs_and_peeling_matches_target_kind() {
        let path = fixture_repo("sha1-refs.git");
        let (objects, _) = LocalOdb::open(&path, Default::default()).unwrap();
        let refs = LocalRefDb::open(&path, Arc::new(objects)).unwrap();
        let budget = Budget::unlimited();
        let page = refs
            .list(
                RefQuery {
                    prefix: None,
                    limit: 1_000,
                    cursor: None,
                },
                &budget,
            )
            .unwrap();

        assert_eq!(page.refs.len(), 75);
        assert!(!page.truncated);
        let warning_names = page
            .warnings
            .iter()
            .map(|warning| warning.name.as_slice())
            .collect::<Vec<_>>();
        assert!(warning_names.contains(&b"refs/heads/zz-empty".as_slice()));
        assert!(warning_names.contains(&b"refs/heads/zz-garbage".as_slice()));
        assert!(warning_names.iter().any(|name| name.len() == 4097));
        assert!(page
            .warnings
            .iter()
            .any(|warning| warning.message.contains("4097 bytes")));
        assert!(page
            .warnings
            .iter()
            .all(|warning| warning.message.contains(&display_ref(&warning.name))));

        let listed = page.refs.into_iter().collect::<BTreeMap<_, _>>();
        let loose_dangling = RefTarget::Direct {
            oid: dangling_oid(1),
            peeled: None,
        };
        assert_eq!(
            listed.get(b"refs/heads/zz-dangling-loose".as_slice()),
            Some(&loose_dangling)
        );
        assert_eq!(
            resolve_symbolic(&refs, b"refs/heads/zz-dangling-loose", &Budget::unlimited()).unwrap(),
            Some(loose_dangling)
        );

        let packed_dangling = listed
            .get(b"refs/tags/zz-dangling-packed".as_slice())
            .unwrap();
        let RefTarget::Direct {
            oid: dangling_tag_oid,
            peeled,
        } = packed_dangling
        else {
            panic!("dangling annotated tag is direct")
        };
        assert_eq!(*peeled, None);
        assert_eq!(
            refs.objects
                .try_header(dangling_tag_oid, &Budget::unlimited())
                .unwrap()
                .unwrap()
                .kind,
            ObjectKind::Tag
        );
        assert_eq!(
            resolve_symbolic(&refs, b"refs/tags/zz-dangling-packed", &Budget::unlimited()).unwrap(),
            Some(packed_dangling.clone())
        );

        let RefTarget::Direct {
            peeled: lightweight,
            ..
        } = listed
            .get(b"refs/tags/basic-lightweight".as_slice())
            .unwrap()
        else {
            panic!("lightweight tag is direct")
        };
        assert_eq!(*lightweight, None);
        for name in [
            b"refs/zz-tag-object".as_slice(),
            b"refs/meta/loose-tag-object",
        ] {
            let RefTarget::Direct { peeled, .. } = listed.get(name).unwrap() else {
                panic!("tag object ref is direct")
            };
            assert_eq!(*peeled, Some(fixture_oid("sha1_refs_head")));
        }

        let RefTarget::Direct { peeled, .. } =
            listed.get(b"refs/tags/refs-tree".as_slice()).unwrap()
        else {
            panic!("tree tag is direct")
        };
        assert!(peeled.is_some());
        assert!(
            budget.spent().0 > 0,
            "loose tag peeling reads object payloads"
        );

        for name in [b"refs/heads/zz-empty".as_slice(), b"refs/heads/zz-garbage"] {
            let error = refs.resolve(name, &Budget::unlimited()).unwrap_err();
            assert_eq!(error.code, ErrorCode::MalformedRef);
            assert!(error
                .reason
                .unwrap()
                .contains(std::str::from_utf8(name).unwrap()));
        }
    }

    #[test]
    fn trusted_packed_peels_need_no_payload_read_but_loose_tag_targets_do() {
        let path = fixture_repo("sha1-refs.git");
        let (objects, _) = LocalOdb::open(&path, Default::default()).unwrap();
        let refs = LocalRefDb::open(&path, Arc::new(objects)).unwrap();

        let packed_budget = Budget::unlimited();
        let packed = refs
            .list(
                RefQuery {
                    prefix: Some(b"refs/zz-tag-object".to_vec()),
                    limit: 10,
                    cursor: None,
                },
                &packed_budget,
            )
            .unwrap();
        assert_eq!(packed.refs.len(), 1);
        assert_eq!(packed_budget.spent().0, 0);

        let loose_budget = Budget::unlimited();
        let loose = refs
            .list(
                RefQuery {
                    prefix: Some(b"refs/meta/loose-tag-object".to_vec()),
                    limit: 10,
                    cursor: None,
                },
                &loose_budget,
            )
            .unwrap();
        assert_eq!(loose.refs.len(), 1);
        assert!(loose_budget.spent().0 >= 2);
        assert!(loose_budget.spent().1 > 0);
    }

    #[test]
    fn selected_ref_object_types_and_peels_match_git_for_each_ref() {
        let path = fixture_repo("sha1-refs.git");
        let (objects, _) = LocalOdb::open(&path, Default::default()).unwrap();
        let objects = Arc::new(objects);
        let refs = LocalRefDb::open(&path, Arc::clone(&objects)).unwrap();

        for name in [
            "refs/tags/basic-lightweight",
            "refs/tags/refs-base",
            "refs/tags/refs-chain",
            "refs/tags/refs-tree",
            "refs/zz-tag-object",
        ] {
            let output = Command::new("git")
                .args(["-C"])
                .arg(&path)
                .args([
                    "for-each-ref",
                    "--format=%(refname)%00%(objecttype)%00%(*objectname)",
                    name,
                ])
                .env("LC_ALL", "C")
                .output()
                .unwrap();
            assert!(output.status.success(), "git oracle failed for {name}");
            let fields = output
                .stdout
                .strip_suffix(b"\n")
                .unwrap_or(&output.stdout)
                .split(|byte| *byte == 0)
                .collect::<Vec<_>>();
            assert_eq!(fields.len(), 3);
            assert_eq!(fields[0], name.as_bytes());

            let RefTarget::Direct { oid, peeled } = refs
                .resolve(name.as_bytes(), &Budget::unlimited())
                .unwrap()
                .unwrap()
            else {
                panic!("selected oracle ref is direct")
            };
            let header = objects
                .try_header(&oid, &Budget::unlimited())
                .unwrap()
                .unwrap();
            assert_eq!(
                fields[1],
                header.kind.as_str().as_bytes(),
                "type for {name}"
            );
            assert_eq!(
                fields[2],
                peeled
                    .as_ref()
                    .map_or_else(Vec::new, |oid| oid.to_hex().into_bytes()),
                "peel for {name}"
            );
        }
    }

    #[test]
    fn on_disk_symbolic_cycle_is_malformed_and_names_the_chain() {
        let path = fixture_repo("sha1-refs-cycle.git");
        let (objects, _) = LocalOdb::open(&path, Default::default()).unwrap();
        let refs = LocalRefDb::open(&path, Arc::new(objects)).unwrap();
        let error =
            resolve_symbolic(&refs, b"refs/heads/cycle-a", &Budget::unlimited()).unwrap_err();
        assert_eq!(error.code, ErrorCode::MalformedRef);
        let reason = error.reason.unwrap();
        assert!(reason.contains("refs/heads/cycle-a"));
        assert!(reason.contains("refs/heads/cycle-b"));
    }

    #[test]
    fn loose_deletion_exposes_the_stale_packed_value_without_moving_the_pinned_result() {
        let path = fixture_copy("sha1-refs.git", "stale-packed");
        let (objects, _) = LocalOdb::open(&path, Default::default()).unwrap();
        let refs = LocalRefDb::open(&path, Arc::new(objects)).unwrap();
        let pinned = resolve_symbolic(&refs, b"refs/heads/both", &Budget::unlimited())
            .unwrap()
            .unwrap();
        fs::remove_file(path.join("refs/heads/both")).unwrap();
        let after_delete = resolve_symbolic(&refs, b"refs/heads/both", &Budget::unlimited())
            .unwrap()
            .unwrap();
        assert_eq!(
            pinned,
            RefTarget::Direct {
                oid: fixture_oid("sha1_refs_parent"),
                peeled: None,
            }
        );
        assert_eq!(
            after_delete,
            RefTarget::Direct {
                oid: fixture_oid("sha1_refs_head"),
                peeled: None,
            }
        );
        fs::remove_dir_all(path).unwrap();
    }

    #[test]
    fn one_packed_snapshot_is_held_across_every_local_symbolic_hop() {
        let path = fixture_copy("sha1-refs.git", "packed-chain-snapshot");
        let (objects, _) = LocalOdb::open(&path, Default::default()).unwrap();
        let refs = LocalRefDb::open(&path, Arc::new(objects)).unwrap();
        let store = refs.store();
        let packed = store.cached_packed_buffer().unwrap().unwrap();
        let mut calls = 0;
        let resolved = resolve_with(b"HEAD", &Budget::unlimited(), |current, budget| {
            let full_name = gix_ref::FullName::try_from(current.as_bstr()).unwrap();
            let reference = store
                .try_find_packed(full_name.as_ref().as_partial_name(), Some(&packed))
                .unwrap();
            if calls == 0 {
                let packed_path = path.join("packed-refs");
                let bytes = fs::read(&packed_path).unwrap();
                let old = format!("{} refs/heads/main", fixture_oid("sha1_refs_head"));
                let new = format!("{} refs/heads/main", fixture_oid("sha1_refs_parent"));
                let changed = bytes.as_bstr().replace(old.as_bytes(), new.as_bytes());
                fs::write(packed_path, changed).unwrap();
            }
            calls += 1;
            reference
                .map(|reference| refs.target(reference, budget))
                .transpose()
        })
        .unwrap();
        assert_eq!(calls, 2);
        assert_eq!(
            resolved,
            Some(RefTarget::Direct {
                oid: fixture_oid("sha1_refs_head"),
                peeled: None,
            })
        );
        assert_eq!(
            resolve_symbolic(&refs, b"HEAD", &Budget::unlimited()).unwrap(),
            Some(RefTarget::Direct {
                oid: fixture_oid("sha1_refs_parent"),
                peeled: None,
            })
        );
        fs::remove_dir_all(path).unwrap();
    }

    #[test]
    fn local_ref_pages_resume_strictly_after_the_last_raw_name() {
        let path = fixture_repo("sha1-basic-packed.git");
        let (objects, _) = LocalOdb::open(&path, Default::default()).unwrap();
        let refs = LocalRefDb::open(&path, Arc::new(objects)).unwrap();
        let mut cursor = None;
        let mut names = Vec::new();
        loop {
            let page = refs
                .list(
                    RefQuery {
                        prefix: Some(b"refs/tags/".to_vec()),
                        limit: 1,
                        cursor,
                    },
                    &Budget::unlimited(),
                )
                .unwrap();
            names.extend(page.refs.into_iter().map(|(name, _)| name));
            cursor = page.next_cursor;
            if cursor.is_none() {
                break;
            }
        }
        assert_eq!(
            names,
            vec![
                b"refs/tags/basic-lightweight".to_vec(),
                b"refs/tags/v1.0.0".to_vec()
            ]
        );
    }

    #[test]
    fn reftable_configuration_is_refused_explicitly() {
        let path =
            std::env::temp_dir().join(format!("gitility-reftable-refusal-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(path.join("objects")).unwrap();
        std::fs::write(path.join("HEAD"), b"ref: refs/heads/main\n").unwrap();
        std::fs::write(
            path.join("config"),
            b"[core]\n\tbare = true\n\trepositoryFormatVersion = 1\n[extensions]\n\trefStorage = reftable\n",
        )
        .unwrap();
        let (objects, _) = LocalOdb::open(&path, Default::default()).unwrap();
        let error = LocalRefDb::open(&path, Arc::new(objects)).unwrap_err();
        assert_eq!(error.code, ErrorCode::UnsupportedOperation);
        assert!(error.reason.unwrap().contains("reftable"));
        std::fs::remove_dir_all(path).unwrap();
    }
}
