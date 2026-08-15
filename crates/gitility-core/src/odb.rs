//! The object database contract — the seam the whole architecture
//! stands on (design F1).
//!
//! Every store — local Git storage, static memory, the Elixir callback
//! provider, layered caches, the pack-range reader — implements
//! [`ObjectDb`], and every algorithm consumes it. Adapters to the
//! engine's own find-traits are implemented over this contract where
//! algorithms require them; no store is ever special.

use crate::budget::Budget;
use crate::error::Error;
use crate::object::{HashKind, ObjectHeader, ObjectKind, Oid};

/// One owned payload result in a batch, retaining misses as `None`.
pub type ObjectReadResult = Option<(ObjectKind, Vec<u8>)>;

/// A content-addressed, read-only object store.
///
/// The trait is deliberately `dyn`-compatible: stores are composed and
/// swapped at runtime. Implementations must be thread-safe — one store
/// serves many concurrent jobs.
pub trait ObjectDb: Send + Sync + 'static {
    /// The hash algorithm every object in this store is addressed by.
    fn hash_kind(&self) -> HashKind;

    /// Reads an object's type and size without its payload, or `None` if
    /// the store does not have it. Charged against the budget by the
    /// implementation.
    fn try_header(&self, oid: &Oid, budget: &Budget) -> Result<Option<ObjectHeader>, Error>;

    /// Reads an object's payload into `out` (cleared first), returning
    /// its kind, or `None` if the store does not have it.
    fn try_find(
        &self,
        oid: &Oid,
        out: &mut Vec<u8>,
        budget: &Budget,
    ) -> Result<Option<ObjectKind>, Error>;

    /// Reads a batch of objects in input order. Providers override this to
    /// make one callback round trip; local stores keep the simple default.
    ///
    /// The public backend contract is batch-first even though many Git
    /// algorithms ask for one object at a time. Cross-job coalescing is not
    /// part of v1, but can be added without changing this contract.
    fn try_find_many(&self, oids: &[Oid], budget: &Budget) -> Result<Vec<ObjectReadResult>, Error> {
        let mut results = Vec::with_capacity(oids.len());
        for oid in oids {
            let mut data = Vec::new();
            let value = self
                .try_find(oid, &mut data, budget)?
                .map(|kind| (kind, data));
            results.push(value);
        }
        Ok(results)
    }

    /// A hint that these OIDs will likely be read soon. Batching stores
    /// (remote providers, pack ranges) use it to coalesce round trips;
    /// the default does nothing.
    fn prefetch(&self, oids: &[Oid], budget: &Budget) -> Result<(), Error> {
        let _ = (oids, budget);
        Ok(())
    }

    /// Invalidates availability knowledge — a missing object may have
    /// arrived in a shallow or incrementally populated store. The default
    /// does nothing.
    fn refresh(&self, budget: &Budget) -> Result<(), Error> {
        let _ = budget;
        Ok(())
    }
}

/// Compile-time proof the contract stays `dyn`-compatible; algorithms
/// take `&dyn ObjectDb` when generics would bloat or prevent composition.
const _: fn(&dyn ObjectDb) = |_| {};

#[cfg(test)]
mod tests {
    use super::*;
    use crate::budget::BudgetLimits;
    use crate::error::ErrorCode;
    use crate::static_odb::StaticOdb;
    use crate::verify::object_id;
    use std::sync::atomic::AtomicBool;
    use std::sync::Arc;

    /// The M0→M1 gate: the real static store drives the contract through
    /// a `&dyn ObjectDb`, no engine and no filesystem.
    #[test]
    fn static_odb_drives_the_contract() {
        let blob = b"hello".to_vec();
        let commit = b"tree ...".to_vec();
        let blob_oid =
            object_id(HashKind::Sha1, ObjectKind::Blob, &blob).expect("blob object ID computes");
        let commit_oid = object_id(HashKind::Sha1, ObjectKind::Commit, &commit)
            .expect("commit object ID computes");
        let missing = Oid::new(HashKind::Sha1, &[9; 20]).expect("valid missing ID");
        let store = StaticOdb::from_objects(
            HashKind::Sha1,
            [(ObjectKind::Blob, blob), (ObjectKind::Commit, commit)],
        )
        .expect("static objects load");
        let db: &dyn ObjectDb = &store;
        let budget = Budget::unlimited();

        let header = db
            .try_header(&blob_oid, &budget)
            .expect("header read succeeds")
            .expect("blob exists");
        assert_eq!(header.kind, ObjectKind::Blob);
        assert_eq!(header.size, 5);

        let mut out = Vec::new();
        let kind = db
            .try_find(&commit_oid, &mut out, &budget)
            .expect("payload read succeeds")
            .expect("commit exists");
        assert_eq!(kind, ObjectKind::Commit);
        assert_eq!(out, b"tree ...");

        assert!(db
            .try_header(&missing, &budget)
            .expect("missing header lookup succeeds")
            .is_none());
        assert!(db
            .try_find(&missing, &mut out, &budget)
            .expect("missing payload lookup succeeds")
            .is_none());

        // Defaults are usable through the trait object.
        db.prefetch(&[blob_oid, commit_oid], &budget)
            .expect("prefetch default succeeds");
        db.refresh(&budget).expect("refresh default succeeds");
    }

    #[test]
    fn reads_respect_the_budget() {
        let payload = vec![0u8; 64];
        let oid =
            object_id(HashKind::Sha1, ObjectKind::Blob, &payload).expect("blob object ID computes");
        let store = StaticOdb::from_objects(HashKind::Sha1, [(ObjectKind::Blob, payload)])
            .expect("static object loads");
        let limits = BudgetLimits {
            max_object_bytes: 10,
            ..BudgetLimits::default()
        };
        let budget = Budget::new(limits, None, Arc::new(AtomicBool::new(false)));

        let mut out = Vec::new();
        let err = store
            .try_find(&oid, &mut out, &budget)
            .expect_err("object size budget stops read");
        assert_eq!(err.code, ErrorCode::ObjectTooLarge);
    }
}
