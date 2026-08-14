//! The reference database contract.
//!
//! Refs are mutable names for immutable objects and live behind their own
//! seam: an ODB plus a commit ID answers every snapshot query, so a
//! [`RefDb`] is only consulted at snapshot-creation time. Names are raw
//! bytes; symbolic chains are followed by the *caller* with a hop limit —
//! a store only reports what one name points at.

use crate::budget::Budget;
use crate::error::Error;
use crate::object::Oid;

/// What a reference points at.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RefTarget {
    /// A direct ref; `peeled` carries the fully-peeled object ID when the
    /// store already knows it (annotated tags).
    Direct { oid: Oid, peeled: Option<Oid> },
    /// A symbolic ref naming another ref (raw bytes).
    Symbolic(Vec<u8>),
}

/// A reference listing query.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RefQuery {
    /// Raw-byte name prefix filter (e.g. `refs/heads/`).
    pub prefix: Option<Vec<u8>>,
    /// Page size ceiling; the store may return fewer.
    pub limit: usize,
    /// Opaque continuation from a previous page.
    pub cursor: Option<Vec<u8>>,
}

/// One page of references.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RefPage {
    /// `(raw name, target)` pairs.
    pub refs: Vec<(Vec<u8>, RefTarget)>,
    pub next_cursor: Option<Vec<u8>>,
    pub truncated: bool,
}

/// A read-only reference store.
pub trait RefDb: Send + Sync + 'static {
    /// Resolves one full reference name (raw bytes), or `None`.
    fn resolve(&self, name: &[u8], budget: &Budget) -> Result<Option<RefTarget>, Error>;

    /// Lists references matching a query.
    fn list(&self, query: RefQuery, budget: &Budget) -> Result<RefPage, Error>;

    /// Invalidates cached ref state. The default does nothing.
    fn refresh(&self, budget: &Budget) -> Result<(), Error> {
        let _ = budget;
        Ok(())
    }
}

/// Compile-time proof the contract stays `dyn`-compatible.
const _: fn(&dyn RefDb) = |_| {};

#[cfg(test)]
mod tests {
    use super::*;
    use crate::object::HashKind;
    use std::collections::BTreeMap;

    /// Minimal in-memory double, mirroring the ODB gate: the contract
    /// must be drivable with no engine and no filesystem.
    struct InMemoryRefDb {
        refs: BTreeMap<Vec<u8>, RefTarget>,
    }

    impl RefDb for InMemoryRefDb {
        fn resolve(&self, name: &[u8], budget: &Budget) -> Result<Option<RefTarget>, Error> {
            budget.check()?;
            Ok(self.refs.get(name).cloned())
        }

        fn list(&self, query: RefQuery, budget: &Budget) -> Result<RefPage, Error> {
            budget.check()?;
            let refs: Vec<_> = self
                .refs
                .iter()
                .filter(|(name, _)| match &query.prefix {
                    Some(prefix) => name.starts_with(&prefix[..]),
                    None => true,
                })
                .map(|(name, target)| (name.clone(), target.clone()))
                .collect();
            Ok(RefPage {
                refs,
                next_cursor: None,
                truncated: false,
            })
        }
    }

    #[test]
    fn in_memory_double_drives_the_contract() {
        let oid = Oid::new(HashKind::Sha1, &[7u8; 20]).unwrap();
        let mut refs = BTreeMap::new();
        refs.insert(
            b"refs/heads/main".to_vec(),
            RefTarget::Direct { oid, peeled: None },
        );
        refs.insert(
            b"HEAD".to_vec(),
            RefTarget::Symbolic(b"refs/heads/main".to_vec()),
        );
        let store = InMemoryRefDb { refs };
        let db: &dyn RefDb = &store;
        let budget = Budget::unlimited();

        match db.resolve(b"HEAD", &budget).unwrap().unwrap() {
            RefTarget::Symbolic(target) => assert_eq!(target, b"refs/heads/main"),
            other => panic!("expected symbolic, got {other:?}"),
        }

        let page = db
            .list(
                RefQuery {
                    prefix: Some(b"refs/heads/".to_vec()),
                    limit: 10,
                    cursor: None,
                },
                &budget,
            )
            .unwrap();
        assert_eq!(page.refs.len(), 1);
        assert!(db.resolve(b"refs/tags/none", &budget).unwrap().is_none());
    }
}
