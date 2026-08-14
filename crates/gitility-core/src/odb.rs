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
pub(crate) mod test_support {
    //! The in-memory `ObjectDb` double.
    //!
    //! This is the Milestone 0 exit gate made executable: the core's
    //! contracts must be drivable with no Gitoxide and no filesystem.
    //! Milestone 1 grows it into the static-ODB store.

    use super::*;
    use std::collections::HashMap;

    pub struct InMemoryOdb {
        hash: HashKind,
        objects: HashMap<Oid, (ObjectKind, Vec<u8>)>,
    }

    impl InMemoryOdb {
        pub fn new(hash: HashKind) -> Self {
            Self {
                hash,
                objects: HashMap::new(),
            }
        }

        pub fn insert(&mut self, oid: Oid, kind: ObjectKind, data: Vec<u8>) {
            self.objects.insert(oid, (kind, data));
        }
    }

    impl ObjectDb for InMemoryOdb {
        fn hash_kind(&self) -> HashKind {
            self.hash
        }

        fn try_header(&self, oid: &Oid, budget: &Budget) -> Result<Option<ObjectHeader>, Error> {
            budget.check()?;
            Ok(self.objects.get(oid).map(|(kind, data)| ObjectHeader {
                kind: *kind,
                size: data.len() as u64,
            }))
        }

        fn try_find(
            &self,
            oid: &Oid,
            out: &mut Vec<u8>,
            budget: &Budget,
        ) -> Result<Option<ObjectKind>, Error> {
            match self.objects.get(oid) {
                None => {
                    budget.check()?;
                    Ok(None)
                }
                Some((kind, data)) => {
                    budget.charge_object(data.len() as u64)?;
                    out.clear();
                    out.extend_from_slice(data);
                    Ok(Some(*kind))
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::InMemoryOdb;
    use super::*;
    use crate::budget::BudgetLimits;
    use crate::error::ErrorCode;
    use std::sync::atomic::AtomicBool;
    use std::sync::Arc;

    fn oid(byte: u8) -> Oid {
        Oid::new(HashKind::Sha1, &[byte; 20]).unwrap()
    }

    /// The M0→M1 gate: a test double drives the contract through a
    /// `&dyn ObjectDb`, no engine, no filesystem.
    #[test]
    fn in_memory_double_drives_the_contract() {
        let mut store = InMemoryOdb::new(HashKind::Sha1);
        store.insert(oid(1), ObjectKind::Blob, b"hello".to_vec());
        store.insert(oid(2), ObjectKind::Commit, b"tree ...".to_vec());
        let db: &dyn ObjectDb = &store;
        let budget = Budget::unlimited();

        let header = db.try_header(&oid(1), &budget).unwrap().unwrap();
        assert_eq!(header.kind, ObjectKind::Blob);
        assert_eq!(header.size, 5);

        let mut out = Vec::new();
        let kind = db.try_find(&oid(2), &mut out, &budget).unwrap().unwrap();
        assert_eq!(kind, ObjectKind::Commit);
        assert_eq!(out, b"tree ...");

        assert!(db.try_header(&oid(9), &budget).unwrap().is_none());
        assert!(db.try_find(&oid(9), &mut out, &budget).unwrap().is_none());

        // Defaults are usable through the trait object.
        db.prefetch(&[oid(1), oid(2)], &budget).unwrap();
        db.refresh(&budget).unwrap();
    }

    #[test]
    fn reads_respect_the_budget() {
        let mut store = InMemoryOdb::new(HashKind::Sha1);
        store.insert(oid(1), ObjectKind::Blob, vec![0u8; 64]);
        let limits = BudgetLimits {
            max_object_bytes: 10,
            ..BudgetLimits::default()
        };
        let budget = Budget::new(limits, None, Arc::new(AtomicBool::new(false)));

        let mut out = Vec::new();
        let err = store.try_find(&oid(1), &mut out, &budget).unwrap_err();
        assert_eq!(err.code, ErrorCode::ObjectTooLarge);
    }
}
