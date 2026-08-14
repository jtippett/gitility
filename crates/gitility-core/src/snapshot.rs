//! Immutable commit snapshots.

use crate::budget::Budget;
use crate::decode::{decode_commit, decode_tag};
use crate::error::{Error, ErrorCode};
use crate::object::{HashKind, ObjectKind, Oid};
use crate::odb::ObjectDb;

const MAX_TAG_HOPS: usize = 16;

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

impl Snapshot {
    /// Opens `oid`, peeling annotated tags to a commit without consulting refs.
    pub fn open(store: &dyn ObjectDb, oid: Oid, budget: &Budget) -> Result<Self, Error> {
        if store.hash_kind() == HashKind::Sha256 {
            return Err(Error::new(
                ErrorCode::UnsupportedHash,
                "SHA-256 query execution not yet supported",
            ));
        }
        if oid.kind() != store.hash_kind() {
            return Err(Error::new(
                ErrorCode::InvalidOid,
                "snapshot object ID algorithm does not match the object store",
            ));
        }

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
            match kind {
                ObjectKind::Commit => {
                    let commit = decode_commit(&payload, store.hash_kind())?;
                    return Ok(Self {
                        commit_oid: current,
                        tree_oid: commit.tree_oid,
                    });
                }
                ObjectKind::Tag if hop < MAX_TAG_HOPS => {
                    let tag = decode_tag(&payload, store.hash_kind())?;
                    current = tag.target_oid;
                    declared_kind = Some(tag.target_kind);
                }
                ObjectKind::Tag => {
                    return Err(Error::new(
                        ErrorCode::MalformedObject,
                        "annotated tag chain exceeds 16 hops",
                    ));
                }
                ObjectKind::Tree | ObjectKind::Blob => {
                    return Err(Error::new(
                        ErrorCode::NotACommit,
                        "snapshot target is not a commit",
                    ));
                }
            }
        }
        Err(Error::new(
            ErrorCode::MalformedObject,
            "annotated tag chain could not be peeled",
        ))
    }
}

fn missing(oid: Oid) -> Error {
    Error::new(
        ErrorCode::MissingObject,
        format!("snapshot object {oid} is missing from the object store"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::decode::{decode_commit, decode_tree};
    use crate::local_odb::LocalOdb;
    use crate::test_support::{fixture_oid, fixture_repo, read_ref_oid};

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
}
