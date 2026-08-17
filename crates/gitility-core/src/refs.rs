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
use crate::object::{HashKind, Oid};
use crate::odb::ObjectDb;
use crate::snapshot::{peel, PeelTarget};
use gix_ref::bstr::ByteSlice;
use std::collections::HashSet;
use std::path::Path;
use std::sync::Arc;

/// Maximum number of symbolic-reference edges followed by one resolution.
pub const MAX_SYMBOLIC_REF_HOPS: usize = 16;

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
    /// hops; the default is suitable for atomic callback resolves.
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

    fn target(
        &self,
        name: &[u8],
        target: gix_ref::Target,
        budget: &Budget,
    ) -> Result<RefTarget, Error> {
        match target {
            gix_ref::Target::Symbolic(target) => {
                Ok(RefTarget::Symbolic(target.as_ref().as_bstr().to_vec()))
            }
            gix_ref::Target::Object(oid) => {
                let oid = Oid::new(self.hash, oid.as_bytes()).map_err(|_| {
                    Error::new(
                        ErrorCode::MalformedRef,
                        "local reference contains an invalid object ID",
                    )
                })?;
                let peeled = if name.starts_with(b"refs/tags/") {
                    match peel(self.objects.as_ref(), oid, PeelTarget::Commit, budget) {
                        Ok(commit) => Some(commit),
                        Err(error) if error.code == ErrorCode::NotACommit => None,
                        Err(error) => return Err(error),
                    }
                } else {
                    None
                };
                Ok(RefTarget::Direct { oid, peeled })
            }
        }
    }
}

impl RefDb for LocalRefDb {
    fn resolve(&self, name: &[u8], budget: &Budget) -> Result<Option<RefTarget>, Error> {
        budget.check()?;
        validate_full_ref_name(name)?;
        let full_name = gix_ref::FullName::try_from(name.as_bstr())
            .map_err(|_| Error::new(ErrorCode::MalformedRef, "reference name is malformed"))?;
        let store = self.store();
        let reference = store
            .try_find(full_name.as_ref().as_partial_name())
            .map_err(|_| {
                Error::new(
                    ErrorCode::MalformedRef,
                    "local reference could not be decoded",
                )
            })?;
        reference
            .map(|reference| self.target(name, reference.target, budget))
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
        })?;
        let packed = packed.as_ref().map(|buffer| &***buffer);
        resolve_with(name, budget, |current, budget| {
            let full_name = gix_ref::FullName::try_from(current.as_bstr())
                .map_err(|_| Error::new(ErrorCode::MalformedRef, "reference name is malformed"))?;
            store
                .try_find_packed(full_name.as_ref().as_partial_name(), packed)
                .map_err(|_| {
                    Error::new(
                        ErrorCode::MalformedRef,
                        "local reference could not be decoded",
                    )
                })?
                .map(|reference| self.target(current, reference.target, budget))
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
        let iterator = platform.all().map_err(|_| {
            Error::new(
                ErrorCode::BackendError,
                "local references could not be enumerated",
            )
        })?;
        let mut refs = Vec::with_capacity(query.limit);
        let mut has_more = false;
        for reference in iterator {
            budget.check()?;
            let reference = reference.map_err(|_| {
                Error::new(
                    ErrorCode::MalformedRef,
                    "local reference could not be decoded",
                )
            })?;
            let name = reference.name.as_ref().as_bstr().to_vec();
            if query
                .prefix
                .as_deref()
                .is_some_and(|prefix| !name.starts_with(prefix))
                || resume
                    .as_deref()
                    .is_some_and(|last| name.as_slice() <= last)
            {
                continue;
            }
            if refs.len() == query.limit {
                has_more = true;
                break;
            }
            let target = self.target(&name, reference.target, budget)?;
            refs.push((name, target));
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
        })
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
    if !decoded.generation.is_empty() {
        return Err(invalid_cursor("reference cursor generation must be empty"));
    }
    validate_full_ref_name(&decoded.position)
        .map_err(|_| invalid_cursor("reference cursor position is not a full ref name"))?;
    Ok(decoded.position)
}

fn encode_ref_cursor(
    hash: HashKind,
    fingerprint: u64,
    position: Vec<u8>,
) -> Result<Vec<u8>, Error> {
    let encoded = cursor::encode(&Cursor {
        hash_kind: hash,
        snapshot_digest: cursor_identity(hash),
        operation_tag: OPERATION_REFS,
        option_fingerprint: fingerprint,
        generation: Vec::new(),
        position,
    });
    if encoded.len() > MAX_CURSOR_BYTES {
        return Err(Error::new(
            ErrorCode::ResultTooLarge,
            "reference continuation name exceeds the cursor size limit",
        ));
    }
    Ok(encoded)
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
            })
        }
    }

    fn oid(byte: u8) -> Oid {
        Oid::new(HashKind::Sha1, &[byte; 20]).unwrap()
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
        assert_eq!(names.len(), 64);
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
