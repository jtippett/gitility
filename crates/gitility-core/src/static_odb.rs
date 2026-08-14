//! Immutable in-memory object database.

use crate::budget::Budget;
use crate::error::{Error, ErrorCode};
use crate::object::{HashKind, ObjectHeader, ObjectKind, Oid};
use crate::odb::ObjectDb;
use crate::verify::{object_id, verify};
use std::collections::HashMap;

/// An immutable collection of inflated Git object payloads.
#[derive(Debug, Clone)]
pub struct StaticOdb {
    hash: HashKind,
    objects: HashMap<Oid, (ObjectKind, Vec<u8>)>,
}

impl StaticOdb {
    /// Builds a store from objects whose IDs are computed while loading.
    ///
    /// Each ID is derived from the object's kind and payload, then stored with
    /// that object. Use [`Self::from_addressed_objects`] when caller-supplied
    /// IDs must be verified.
    pub fn from_objects(
        hash: HashKind,
        objects: impl IntoIterator<Item = (ObjectKind, Vec<u8>)>,
    ) -> Result<Self, Error> {
        let mut addressed = Vec::new();
        for (kind, payload) in objects {
            let oid = object_id(hash, kind, &payload)?;
            addressed.push((oid, kind, payload));
        }
        Self::from_addressed_objects(hash, addressed)
    }

    /// Builds a store from caller-supplied IDs and verifies every object.
    ///
    /// An ID using a different algorithm from `hash` is rejected as
    /// [`ErrorCode::InvalidOid`]; a content mismatch is rejected as
    /// [`ErrorCode::HashMismatch`].
    pub fn from_addressed_objects(
        hash: HashKind,
        objects: impl IntoIterator<Item = (Oid, ObjectKind, Vec<u8>)>,
    ) -> Result<Self, Error> {
        let mut loaded = HashMap::new();
        for (oid, kind, payload) in objects {
            ensure_hash(hash, &oid)?;
            verify(&oid, kind, &payload)?;
            loaded.insert(oid, (kind, payload));
        }
        Ok(Self {
            hash,
            objects: loaded,
        })
    }

    /// Number of objects in the store.
    pub fn len(&self) -> usize {
        self.objects.len()
    }

    /// Whether the store contains no objects.
    pub fn is_empty(&self) -> bool {
        self.objects.is_empty()
    }
}

impl ObjectDb for StaticOdb {
    fn hash_kind(&self) -> HashKind {
        self.hash
    }

    fn try_header(&self, oid: &Oid, budget: &Budget) -> Result<Option<ObjectHeader>, Error> {
        budget.charge_header()?;
        ensure_hash(self.hash, oid)?;
        Ok(self.objects.get(oid).map(|(kind, payload)| ObjectHeader {
            kind: *kind,
            size: payload.len() as u64,
        }))
    }

    fn try_find(
        &self,
        oid: &Oid,
        out: &mut Vec<u8>,
        budget: &Budget,
    ) -> Result<Option<ObjectKind>, Error> {
        out.clear();
        ensure_hash(self.hash, oid)?;
        let Some((kind, payload)) = self.objects.get(oid) else {
            budget.check()?;
            return Ok(None);
        };
        budget.charge_object(payload.len() as u64)?;
        out.extend_from_slice(payload);
        Ok(Some(*kind))
    }
}

fn ensure_hash(expected: HashKind, oid: &Oid) -> Result<(), Error> {
    if oid.kind() != expected {
        return Err(Error::new(
            ErrorCode::InvalidOid,
            format!(
                "object ID uses {:?}, but the object store uses {:?}",
                oid.kind(),
                expected
            ),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::decode::decode_commit;
    use crate::local_odb::LocalOdb;
    use crate::test_support::{fixture_oid, fixture_repo};

    #[test]
    fn computes_ids_and_drives_the_object_db_contract() {
        let store = StaticOdb::from_objects(
            HashKind::Sha1,
            [
                (ObjectKind::Blob, Vec::new()),
                (ObjectKind::Blob, b"hello".to_vec()),
            ],
        )
        .expect("objects load");
        assert_eq!(store.len(), 2);
        let empty =
            Oid::parse_hex("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391").expect("known ID parses");
        let budget = Budget::unlimited();
        let db: &dyn ObjectDb = &store;
        let mut out = vec![1, 2, 3];
        assert_eq!(
            db.try_find(&empty, &mut out, &budget)
                .expect("read succeeds"),
            Some(ObjectKind::Blob)
        );
        assert!(out.is_empty());
        assert_eq!(
            db.try_header(&empty, &budget)
                .expect("header succeeds")
                .expect("object exists")
                .size,
            0
        );
    }

    #[test]
    fn loads_objects_extracted_from_a_fixture_repository() {
        let (local, _) = LocalOdb::open(fixture_repo("sha1-basic.git"), Default::default())
            .expect("fixture repository opens");
        let head = fixture_oid("sha1_basic_head");
        let budget = Budget::unlimited();
        let mut commit_payload = Vec::new();
        let kind = local
            .try_find(&head, &mut commit_payload, &budget)
            .expect("commit reads")
            .expect("commit exists");
        let tree_oid = decode_commit(&commit_payload, HashKind::Sha1)
            .expect("fixture commit decodes")
            .tree_oid;
        let mut tree_payload = Vec::new();
        let tree_kind = local
            .try_find(&tree_oid, &mut tree_payload, &budget)
            .expect("tree reads")
            .expect("tree exists");

        let store = StaticOdb::from_addressed_objects(
            HashKind::Sha1,
            [
                (head, kind, commit_payload.clone()),
                (tree_oid, tree_kind, tree_payload.clone()),
            ],
        )
        .expect("fixture object verifies while loading");
        assert_eq!(store.len(), 2);
        let mut actual = Vec::new();
        assert_eq!(
            store
                .try_find(&head, &mut actual, &Budget::unlimited())
                .expect("static read succeeds"),
            Some(ObjectKind::Commit)
        );
        assert_eq!(actual, commit_payload);
        assert_eq!(
            store
                .try_find(&tree_oid, &mut actual, &Budget::unlimited())
                .expect("static tree read succeeds"),
            Some(ObjectKind::Tree)
        );
        assert_eq!(actual, tree_payload);
    }

    #[test]
    fn rejects_tampering_and_wrong_algorithm_at_load() {
        let expected =
            Oid::parse_hex("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391").expect("known ID parses");
        let err = StaticOdb::from_addressed_objects(
            HashKind::Sha1,
            [(expected, ObjectKind::Blob, b"tampered".to_vec())],
        )
        .expect_err("tampering is rejected");
        assert_eq!(err.code, ErrorCode::HashMismatch);

        let sha256 = Oid::new(HashKind::Sha256, &[0; 32]).expect("valid SHA-256 ID");
        let err = StaticOdb::from_addressed_objects(
            HashKind::Sha1,
            [(sha256, ObjectKind::Blob, Vec::new())],
        )
        .expect_err("wrong algorithm is rejected");
        assert_eq!(err.code, ErrorCode::InvalidOid);
    }

    #[test]
    fn total_byte_budget_stops_a_read() {
        use crate::budget::BudgetLimits;
        use std::sync::atomic::AtomicBool;
        use std::sync::Arc;

        let payload = b"larger than one byte".to_vec();
        let oid =
            object_id(HashKind::Sha1, ObjectKind::Blob, &payload).expect("object ID computes");
        let store = StaticOdb::from_objects(HashKind::Sha1, [(ObjectKind::Blob, payload)])
            .expect("object loads");
        let budget = Budget::new(
            BudgetLimits {
                max_total_object_bytes: 1,
                ..BudgetLimits::default()
            },
            None,
            Arc::new(AtomicBool::new(false)),
        );
        let err = store
            .try_find(&oid, &mut Vec::new(), &budget)
            .expect_err("budget stops read");
        assert_eq!(err.code, ErrorCode::BudgetExceeded);
    }
}
