//! Immutable commit snapshots.

use crate::budget::Budget;
use crate::decode::{decode_commit, decode_tag};
use crate::error::{Error, ErrorCode};
use crate::object::{HashKind, ObjectKind, Oid};
use crate::odb::ObjectDb;

const MAX_TAG_HOPS: usize = 16;

/// The object kind requested from [`peel`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PeelTarget {
    Commit,
    Tree,
    Blob,
}

/// A commit and its pinned root tree.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Snapshot {
    pub commit_oid: Oid,
    pub tree_oid: Oid,
}

/// Opens `oid`, peeling annotated tags to a commit without consulting refs.
pub fn open(store: &dyn ObjectDb, oid: Oid, budget: &Budget) -> Result<Snapshot, Error> {
    Snapshot::open(store, oid, budget)
}

/// Opens `oid` only when it is itself a commit. Unlike [`open`], this never
/// peels an annotated tag and is used by `:ref`, `:branch`, and `:head`
/// selectors, whose safe semantics forbid implicit tag peeling.
pub fn open_direct(store: &dyn ObjectDb, oid: Oid, budget: &Budget) -> Result<Snapshot, Error> {
    Snapshot::open_direct(store, oid, budget)
}

/// Peels an object through at most 16 annotated tags to a supported target.
///
/// Tree peeling also accepts a commit and returns its pinned root tree. Blob
/// peeling never treats a tree entry as an implicit path lookup.
pub fn peel(
    store: &dyn ObjectDb,
    oid: Oid,
    target: PeelTarget,
    budget: &Budget,
) -> Result<Oid, Error> {
    ensure_compatible(store, oid, "peel")?;
    let (current, kind, payload) = peel_tag_chain(store, oid, budget)?;
    match kind {
        ObjectKind::Commit if target == PeelTarget::Commit => Ok(current),
        ObjectKind::Commit if target == PeelTarget::Tree => {
            Ok(decode_commit(&payload, store.hash_kind())?.tree_oid)
        }
        ObjectKind::Tree if target == PeelTarget::Tree => Ok(current),
        ObjectKind::Blob if target == PeelTarget::Blob => Ok(current),
        _ => Err(wrong_peel_target(target)),
    }
}

impl Snapshot {
    /// Opens `oid`, peeling annotated tags to a commit without consulting refs.
    pub fn open(store: &dyn ObjectDb, oid: Oid, budget: &Budget) -> Result<Self, Error> {
        ensure_compatible(store, oid, "snapshot")?;
        let (commit_oid, kind, payload) = peel_tag_chain(store, oid, budget)?;
        if kind != ObjectKind::Commit {
            return Err(Error::new(
                ErrorCode::NotACommit,
                "snapshot target is not a commit",
            ));
        }
        let commit = decode_commit(&payload, store.hash_kind())?;
        Ok(Self {
            commit_oid,
            tree_oid: commit.tree_oid,
        })
    }

    /// Opens a direct commit without tag peeling.
    pub fn open_direct(store: &dyn ObjectDb, oid: Oid, budget: &Budget) -> Result<Self, Error> {
        ensure_compatible(store, oid, "snapshot")?;
        let mut payload = Vec::new();
        let kind = store
            .try_find(&oid, &mut payload, budget)?
            .ok_or_else(|| missing(oid))?;
        if kind != ObjectKind::Commit {
            return Err(Error::new(
                ErrorCode::NotACommit,
                "snapshot target is not a direct commit",
            ));
        }
        let commit = decode_commit(&payload, store.hash_kind())?;
        Ok(Self {
            commit_oid: oid,
            tree_oid: commit.tree_oid,
        })
    }
}

fn peel_tag_chain(
    store: &dyn ObjectDb,
    oid: Oid,
    budget: &Budget,
) -> Result<(Oid, ObjectKind, Vec<u8>), Error> {
    let mut current = oid;
    let mut payload = Vec::new();
    let mut declared_kind = None;
    for hop in 0..=MAX_TAG_HOPS {
        let kind = store
            .try_find(&current, &mut payload, budget)?
            .ok_or_else(|| missing(current))?;
        if declared_kind.is_some_and(|expected| expected != kind) {
            return Err(Error::new(
                ErrorCode::MalformedObject,
                "annotated tag target kind does not match its object",
            ));
        }
        if kind != ObjectKind::Tag {
            return Ok((current, kind, payload));
        }
        if hop == MAX_TAG_HOPS {
            return Err(tag_hop_error());
        }
        let tag = decode_tag(&payload, store.hash_kind())?;
        current = tag.target_oid;
        declared_kind = Some(tag.target_kind);
    }
    Err(tag_hop_error())
}

fn ensure_compatible(store: &dyn ObjectDb, oid: Oid, operation: &str) -> Result<(), Error> {
    if store.hash_kind() == HashKind::Sha256 {
        return Err(Error::new(
            ErrorCode::UnsupportedHash,
            "SHA-256 query execution not yet supported",
        ));
    }
    if oid.kind() != store.hash_kind() {
        return Err(Error::new(
            ErrorCode::InvalidOid,
            format!("{operation} object ID algorithm does not match the object store"),
        ));
    }
    Ok(())
}

fn wrong_peel_target(target: PeelTarget) -> Error {
    let (code, message) = match target {
        PeelTarget::Commit => (ErrorCode::NotACommit, "object cannot be peeled to a commit"),
        PeelTarget::Tree => (ErrorCode::NotATree, "object cannot be peeled to a tree"),
        PeelTarget::Blob => (ErrorCode::NotABlob, "object cannot be peeled to a blob"),
    };
    Error::new(code, message)
}

fn tag_hop_error() -> Error {
    Error::new(
        ErrorCode::MalformedObject,
        "annotated tag chain exceeds 16 hops",
    )
}

fn missing(oid: Oid) -> Error {
    Error::new(
        ErrorCode::MissingObject,
        format!("object {oid} is missing from the object store"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::decode::{decode_commit, decode_tree};
    use crate::local_odb::LocalOdb;
    use crate::static_odb::StaticOdb;
    use crate::test_support::{fixture_oid, fixture_repo, read_ref_oid};
    use crate::verify::object_id;

    #[test]
    fn opens_a_commit_and_peels_an_annotated_tag() {
        let repo = fixture_repo("sha1-basic.git");
        let (store, _) = LocalOdb::open(&repo, Default::default()).expect("fixture opens");
        let head = fixture_oid("sha1_basic_head");
        let direct = Snapshot::open(&store, head, &Budget::unlimited()).expect("commit opens");
        assert_eq!(direct.commit_oid, head);

        let tag = read_ref_oid(&repo, "refs/tags/v1.0.0");
        let peeled = Snapshot::open(&store, tag, &Budget::unlimited()).expect("tag peels");
        assert_eq!(peeled, direct);
        assert_eq!(
            Snapshot::open_direct(&store, tag, &Budget::unlimited())
                .expect_err("direct ref selectors never peel tags")
                .code,
            ErrorCode::NotACommit
        );
    }

    #[test]
    fn rejects_blob_and_tree_targets_as_not_a_commit() {
        let (store, _) = LocalOdb::open(fixture_repo("sha1-basic.git"), Default::default())
            .expect("fixture opens");
        let budget = Budget::unlimited();
        let head = fixture_oid("sha1_basic_head");
        let mut payload = Vec::new();
        store
            .try_find(&head, &mut payload, &budget)
            .expect("commit reads")
            .expect("commit exists");
        let tree = decode_commit(&payload, HashKind::Sha1)
            .expect("commit decodes")
            .tree_oid;
        store
            .try_find(&tree, &mut payload, &budget)
            .expect("tree reads")
            .expect("tree exists");
        let blob = decode_tree(&payload, HashKind::Sha1)
            .find_map(|entry| {
                let entry = entry.ok()?;
                (entry.mode == 0o100644).then_some(entry.oid)
            })
            .expect("root contains a blob");

        for oid in [tree, blob] {
            assert_eq!(
                Snapshot::open(&store, oid, &Budget::unlimited())
                    .expect_err("non-commit is rejected")
                    .code,
                ErrorCode::NotACommit
            );
        }
    }

    #[test]
    fn sha256_refusal_precedes_any_read() {
        let (store, _) = LocalOdb::open(fixture_repo("sha256-basic.git"), Default::default())
            .expect("SHA-256 fixture opens");
        let budget = Budget::unlimited();
        let err = Snapshot::open(&store, fixture_oid("sha256_basic_head"), &budget)
            .expect_err("SHA-256 query execution is refused");
        assert_eq!(err.code, ErrorCode::UnsupportedHash);
        assert_eq!(err.message, "SHA-256 query execution not yet supported");
        assert!(!err.retryable);
        assert_eq!(budget.spent(), (0, 0, 0, 0));
    }

    #[test]
    fn peels_tags_to_commit_tree_and_blob() {
        let (store, _) = LocalOdb::open(fixture_repo("sha1-basic.git"), Default::default())
            .expect("fixture opens");
        let budget = Budget::unlimited();
        let head = fixture_oid("sha1_basic_head");
        let tag = read_ref_oid(&fixture_repo("sha1-basic.git"), "refs/tags/v1.0.0");

        assert_eq!(
            peel(&store, tag, PeelTarget::Commit, &budget).unwrap(),
            head
        );

        let snapshot = Snapshot::open(&store, head, &Budget::unlimited()).unwrap();
        assert_eq!(
            peel(&store, tag, PeelTarget::Tree, &Budget::unlimited()).unwrap(),
            snapshot.tree_oid
        );
        assert_eq!(
            peel(
                &store,
                snapshot.tree_oid,
                PeelTarget::Tree,
                &Budget::unlimited()
            )
            .unwrap(),
            snapshot.tree_oid
        );

        let mut tree_payload = Vec::new();
        store
            .try_find(&snapshot.tree_oid, &mut tree_payload, &Budget::unlimited())
            .unwrap();
        let blob = decode_tree(&tree_payload, HashKind::Sha1)
            .find_map(|entry| {
                let entry = entry.ok()?;
                (entry.mode == 0o100644).then_some(entry.oid)
            })
            .expect("root blob exists");
        assert_eq!(
            peel(&store, blob, PeelTarget::Blob, &Budget::unlimited()).unwrap(),
            blob
        );

        let tag_payload = format!(
            "object {}\ntype blob\ntag blob-tag\ntagger Gitility <fixture@gitility.invalid> 0 +0000\n\nblob\n",
            blob.to_hex()
        )
        .into_bytes();
        let tag_oid = object_id(HashKind::Sha1, ObjectKind::Tag, &tag_payload).unwrap();
        let mut blob_payload = Vec::new();
        store
            .try_find(&blob, &mut blob_payload, &Budget::unlimited())
            .unwrap();
        let static_store = StaticOdb::from_addressed_objects(
            HashKind::Sha1,
            [
                (blob, ObjectKind::Blob, blob_payload),
                (tag_oid, ObjectKind::Tag, tag_payload),
            ],
        )
        .unwrap();
        assert_eq!(
            peel(
                &static_store,
                tag_oid,
                PeelTarget::Blob,
                &Budget::unlimited()
            )
            .unwrap(),
            blob
        );
    }

    #[test]
    fn peel_reports_the_requested_target_kind() {
        let (store, _) = LocalOdb::open(fixture_repo("sha1-basic.git"), Default::default())
            .expect("fixture opens");
        let head = fixture_oid("sha1_basic_head");
        assert_eq!(
            peel(&store, head, PeelTarget::Blob, &Budget::unlimited())
                .unwrap_err()
                .code,
            ErrorCode::NotABlob
        );
    }

    #[test]
    fn peel_rejects_tag_chains_longer_than_sixteen_hops() {
        let blob_payload = b"payload".to_vec();
        let blob_oid = object_id(HashKind::Sha1, ObjectKind::Blob, &blob_payload).unwrap();
        let mut objects = vec![(blob_oid, ObjectKind::Blob, blob_payload)];
        let mut target = blob_oid;
        for index in 0..17 {
            let payload = format!(
                "object {}\ntype {}\ntag hop-{index}\ntagger Gitility <fixture@gitility.invalid> 0 +0000\n\nhop\n",
                target.to_hex(),
                if index == 0 { "blob" } else { "tag" }
            )
            .into_bytes();
            let oid = object_id(HashKind::Sha1, ObjectKind::Tag, &payload).unwrap();
            objects.push((oid, ObjectKind::Tag, payload));
            target = oid;
        }
        let store = StaticOdb::from_addressed_objects(HashKind::Sha1, objects).unwrap();
        let error = peel(&store, target, PeelTarget::Blob, &Budget::unlimited()).unwrap_err();
        assert_eq!(error.code, ErrorCode::MalformedObject);
        assert_eq!(error.message, "annotated tag chain exceeds 16 hops");
    }
}
