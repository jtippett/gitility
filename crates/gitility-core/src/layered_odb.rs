//! Read-through object-store composition and its verified payload cache.
//!
//! [`CacheLayer`] deliberately stores only inflated payloads returned by an
//! [`ObjectDb`]. Every concrete Gitility store verifies those bytes under the
//! only supported policy (`verify: always`) before returning them. Memory is
//! not a later trust boundary, so cache hits are re-served without re-hashing;
//! a debug-build verification assertion remains as a tripwire for violations
//! of that store contract.

use crate::budget::Budget;
use crate::error::{Error, ErrorCode};
use crate::lru::LruCache;
use crate::object::{HashKind, ObjectHeader, ObjectKind, Oid};
use crate::odb::{
    enforce_read_many_budget, CacheStats, HeaderProvenance, HeaderRead, ObjectDb, ObjectReadResult,
    ReadManyBudget,
};
#[cfg(debug_assertions)]
use crate::verify::verify;
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, MutexGuard};

/// Bounds for one writable in-memory cache layer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CacheOptions {
    pub max_bytes: u64,
    pub max_entries: u64,
    pub max_object_bytes: u64,
}

/// A bounded LRU of post-verification, inflated Git object payloads.
pub struct CacheLayer {
    options: CacheOptions,
    state: Mutex<CacheState>,
}

impl std::fmt::Debug for CacheLayer {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CacheLayer")
            .field("options", &self.options)
            .field("stats", &self.stats())
            .finish()
    }
}

impl CacheLayer {
    pub fn new(options: CacheOptions) -> Result<Self, Error> {
        if options.max_bytes == 0 {
            return Err(invalid_argument(
                "cache max_bytes must be greater than zero",
            ));
        }
        if options.max_entries == 0 {
            return Err(invalid_argument(
                "cache max_entries must be greater than zero",
            ));
        }
        if options.max_object_bytes == 0 {
            return Err(invalid_argument(
                "cache max_object_bytes must be greater than zero",
            ));
        }
        Ok(Self {
            options,
            state: Mutex::new(CacheState {
                objects: LruCache::new(options.max_bytes),
                evictions: 0,
            }),
        })
    }

    fn get(&self, oid: &Oid, budget: &Budget) -> Option<CachedObject> {
        let value = lock(&self.state).objects.get_cloned(&(oid.kind(), *oid));
        if value.is_some() {
            budget.record_cache_hit();
        } else {
            budget.record_cache_miss();
        }
        value
    }

    fn insert(&self, oid: Oid, kind: ObjectKind, data: Arc<Vec<u8>>) {
        let bytes = data.len() as u64;
        if bytes > self.options.max_object_bytes || bytes > self.options.max_bytes {
            return;
        }

        // Bytes enter this layer only after a concrete lower store has run its
        // verify:always path. Rehashing every cache hit would erase the value
        // of a process-local cache; debug builds retain a cheap correctness
        // tripwire at insertion instead.
        #[cfg(debug_assertions)]
        debug_assert!(
            verify(&oid, kind, data.as_slice()).is_ok(),
            "CacheLayer received bytes that do not match their object ID"
        );

        let key = (oid.kind(), oid);
        let mut state = lock(&self.state);
        let replaced = state.objects.remove(&key).is_some();
        if !replaced {
            while state.objects.len() as u64 >= self.options.max_entries {
                if state.objects.pop_lru().is_none() {
                    break;
                }
                state.evictions = state.evictions.saturating_add(1);
            }
        }
        let evictions =
            state
                .objects
                .insert_counting_evictions(key, CachedObject { kind, data }, bytes);
        state.evictions = state.evictions.saturating_add(evictions);
    }

    pub fn stats(&self) -> CacheStats {
        let state = lock(&self.state);
        CacheStats {
            bytes: state.objects.used(),
            entries: state.objects.len() as u64,
            evictions: state.evictions,
        }
    }
}

#[derive(Clone)]
struct CachedObject {
    kind: ObjectKind,
    data: Arc<Vec<u8>>,
}

struct CacheState {
    objects: LruCache<(HashKind, Oid), CachedObject>,
    evictions: u64,
}

/// An ordered union of object stores with at most one writable cache at a
/// specific position in that order.
pub struct LayeredOdb {
    hash: HashKind,
    layers: Vec<Arc<dyn ObjectDb>>,
    cache: Option<(usize, CacheLayer)>,
}

impl std::fmt::Debug for LayeredOdb {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("LayeredOdb")
            .field("hash", &self.hash)
            .field("store_layers", &self.layers.len())
            .field("cache", &self.cache)
            .finish()
    }
}

impl LayeredOdb {
    /// Builds a composition. `cache_index` is the cache's position among the
    /// conceptual sequence of stores and cache; it must precede a store.
    pub fn new(
        layers: Vec<Arc<dyn ObjectDb>>,
        cache: Option<(usize, CacheOptions)>,
    ) -> Result<Self, Error> {
        let Some(first) = layers.first() else {
            return Err(invalid_argument(
                "a layered object database requires at least one store",
            ));
        };
        let hash = first.hash_kind();
        if layers.iter().any(|layer| layer.hash_kind() != hash) {
            return Err(Error::new(
                ErrorCode::HashMismatch,
                "layered object stores use different hash algorithms",
            ));
        }
        let cache = match cache {
            Some((index, options)) if index < layers.len() => {
                Some((index, CacheLayer::new(options)?))
            }
            Some(_) => {
                return Err(invalid_argument(
                    "a cache layer must precede at least one object store",
                ))
            }
            None => None,
        };
        Ok(Self {
            hash,
            layers,
            cache,
        })
    }

    fn ensure_oid(&self, oid: &Oid) -> Result<(), Error> {
        if oid.kind() == self.hash {
            Ok(())
        } else {
            Err(Error::new(
                ErrorCode::InvalidOid,
                "object ID hash does not match the layered store",
            ))
        }
    }

    fn cache_at(&self, store_index: usize) -> Option<&CacheLayer> {
        self.cache
            .as_ref()
            .and_then(|(index, cache)| (*index == store_index).then_some(cache))
    }

    fn cache_before(&self, store_index: usize) -> Option<&CacheLayer> {
        self.cache
            .as_ref()
            .and_then(|(index, cache)| (*index <= store_index).then_some(cache))
    }
}

impl ObjectDb for LayeredOdb {
    fn hash_kind(&self) -> HashKind {
        self.hash
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
        self.ensure_oid(oid)?;
        for (index, layer) in self.layers.iter().enumerate() {
            if let Some(cache) = self.cache_at(index) {
                if let Some(cached) = cache.get(oid, budget) {
                    budget.charge_header()?;
                    return Ok(Some(verified_header(cached.kind, cached.data.len())));
                }
            }

            if let Some(cache) = self.cache_before(index) {
                // A payload cache cannot trust or retain header-only metadata.
                // Read the lower layer's verified payload once, derive its
                // header, and share that same allocation with the cache.
                let mut values = layer.try_find_many(&[*oid], budget)?;
                if let Some((kind, data)) = values.pop().expect("singleton layer read") {
                    cache.insert(*oid, kind, Arc::clone(&data));
                    return Ok(Some(verified_header(kind, data.len())));
                }
            } else if let Some(read) = layer.try_header_with_provenance(oid, budget)? {
                return Ok(Some(read));
            }
        }
        Ok(None)
    }

    fn try_find(
        &self,
        oid: &Oid,
        out: &mut Vec<u8>,
        budget: &Budget,
    ) -> Result<Option<ObjectKind>, Error> {
        out.clear();
        let mut values = self.try_find_many(&[*oid], budget)?;
        match values.pop().expect("singleton layered read") {
            Some((kind, data)) => {
                out.extend_from_slice(data.as_slice());
                Ok(Some(kind))
            }
            None => Ok(None),
        }
    }

    fn try_find_many(&self, oids: &[Oid], budget: &Budget) -> Result<Vec<ObjectReadResult>, Error> {
        self.try_find_many_bounded(oids, budget, ReadManyBudget::default())
    }

    fn try_find_many_bounded(
        &self,
        oids: &[Oid],
        budget: &Budget,
        read_budget: ReadManyBudget,
    ) -> Result<Vec<ObjectReadResult>, Error> {
        for oid in oids {
            self.ensure_oid(oid)?;
        }

        // Public read_many already deduplicates at the NIF boundary. Keep the
        // core composition robust for direct callers while preserving the
        // first appearance order sent to batching providers.
        let mut seen = HashSet::with_capacity(oids.len());
        let mut unresolved = oids
            .iter()
            .copied()
            .filter(|oid| seen.insert(*oid))
            .collect::<Vec<_>>();
        let mut resolved = HashMap::<Oid, ObjectReadResult>::with_capacity(unresolved.len());
        let mut result_bytes = 0u64;

        for (index, layer) in self.layers.iter().enumerate() {
            if let Some(cache) = self.cache_at(index) {
                let mut still_unresolved = Vec::with_capacity(unresolved.len());
                for oid in unresolved {
                    if let Some(cached) = cache.get(&oid, budget) {
                        budget.charge_object(cached.data.len() as u64)?;
                        result_bytes = result_bytes.saturating_add(cached.data.len() as u64);
                        enforce_read_many_budget(result_bytes, read_budget)?;
                        resolved.insert(oid, Some((cached.kind, cached.data)));
                    } else {
                        still_unresolved.push(oid);
                    }
                }
                unresolved = still_unresolved;
            }
            if unresolved.is_empty() {
                break;
            }

            let remaining = ReadManyBudget {
                max_total_bytes: read_budget
                    .max_total_bytes
                    .map(|maximum| maximum.saturating_sub(result_bytes)),
            };
            let values = layer.try_find_many_bounded(&unresolved, budget, remaining)?;
            let mut still_unresolved = Vec::new();
            for (oid, value) in unresolved.into_iter().zip(values) {
                match value {
                    Some((kind, data)) => {
                        result_bytes = result_bytes.saturating_add(data.len() as u64);
                        enforce_read_many_budget(result_bytes, read_budget)?;
                        if let Some(cache) = self.cache_before(index) {
                            cache.insert(oid, kind, Arc::clone(&data));
                        }
                        resolved.insert(oid, Some((kind, data)));
                    }
                    None => still_unresolved.push(oid),
                }
            }
            unresolved = still_unresolved;
        }

        for oid in unresolved {
            resolved.insert(oid, None);
        }
        Ok(oids
            .iter()
            .map(|oid| resolved.get(oid).cloned().unwrap_or(None))
            .collect())
    }

    fn prefetch(&self, oids: &[Oid], budget: &Budget) -> Result<(), Error> {
        let mut first_error = None;
        for layer in &self.layers {
            if let Err(error) = layer.prefetch(oids, budget) {
                first_error.get_or_insert(error);
            }
        }
        first_error.map_or(Ok(()), Err)
    }

    fn supports_prefetch(&self) -> bool {
        self.layers.iter().any(|layer| layer.supports_prefetch())
    }

    fn cache_stats(&self) -> CacheStats {
        let mut stats = self
            .cache
            .as_ref()
            .map_or_else(CacheStats::default, |(_, cache)| cache.stats());
        for layer in &self.layers {
            let nested = layer.cache_stats();
            stats.bytes = stats.bytes.saturating_add(nested.bytes);
            stats.entries = stats.entries.saturating_add(nested.entries);
            stats.evictions = stats.evictions.saturating_add(nested.evictions);
        }
        stats
    }

    fn refresh(&self, budget: &Budget) -> Result<(), Error> {
        let mut first_error = None;
        for layer in &self.layers {
            if let Err(error) = layer.refresh(budget) {
                first_error.get_or_insert(error);
            }
        }
        first_error.map_or(Ok(()), Err)
    }
}

fn verified_header(kind: ObjectKind, bytes: usize) -> HeaderRead {
    HeaderRead {
        header: ObjectHeader {
            kind,
            size: bytes as u64,
        },
        provenance: HeaderProvenance::Verified,
    }
}

fn invalid_argument(message: &'static str) -> Error {
    Error::new(ErrorCode::InvalidArgument, message)
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::static_odb::StaticOdb;
    use crate::verify::object_id;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct CountingStore {
        hash: HashKind,
        objects: HashMap<Oid, (ObjectKind, Arc<Vec<u8>>)>,
        object_calls: Arc<AtomicUsize>,
        header_calls: Arc<AtomicUsize>,
        prefetch_calls: Arc<AtomicUsize>,
        refresh_calls: Arc<AtomicUsize>,
    }

    impl CountingStore {
        fn blobs(payloads: &[&[u8]]) -> (Arc<Self>, Vec<Oid>) {
            let mut objects = HashMap::new();
            let mut oids = Vec::new();
            for payload in payloads {
                let data = payload.to_vec();
                let oid = object_id(HashKind::Sha1, ObjectKind::Blob, &data).unwrap();
                objects.insert(oid, (ObjectKind::Blob, Arc::new(data)));
                oids.push(oid);
            }
            (
                Arc::new(Self {
                    hash: HashKind::Sha1,
                    objects,
                    object_calls: Arc::new(AtomicUsize::new(0)),
                    header_calls: Arc::new(AtomicUsize::new(0)),
                    prefetch_calls: Arc::new(AtomicUsize::new(0)),
                    refresh_calls: Arc::new(AtomicUsize::new(0)),
                }),
                oids,
            )
        }
    }

    impl ObjectDb for CountingStore {
        fn hash_kind(&self) -> HashKind {
            self.hash
        }

        fn try_header(&self, oid: &Oid, budget: &Budget) -> Result<Option<ObjectHeader>, Error> {
            self.header_calls.fetch_add(1, Ordering::Relaxed);
            budget.charge_header()?;
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
            self.object_calls.fetch_add(1, Ordering::Relaxed);
            out.clear();
            let Some((kind, data)) = self.objects.get(oid) else {
                budget.check()?;
                return Ok(None);
            };
            budget.charge_object(data.len() as u64)?;
            out.extend_from_slice(data);
            Ok(Some(*kind))
        }

        fn prefetch(&self, _oids: &[Oid], _budget: &Budget) -> Result<(), Error> {
            self.prefetch_calls.fetch_add(1, Ordering::Relaxed);
            Ok(())
        }

        fn supports_prefetch(&self) -> bool {
            true
        }

        fn refresh(&self, _budget: &Budget) -> Result<(), Error> {
            self.refresh_calls.fetch_add(1, Ordering::Relaxed);
            Ok(())
        }
    }

    fn cache(max_bytes: u64) -> Option<(usize, CacheOptions)> {
        Some((
            0,
            CacheOptions {
                max_bytes,
                max_entries: 100,
                max_object_bytes: max_bytes,
            },
        ))
    }

    fn dyn_store(store: Arc<CountingStore>) -> Arc<dyn ObjectDb> {
        store
    }

    #[test]
    fn construction_rejects_empty_bad_cache_position_and_hash_mismatch() {
        assert_eq!(
            LayeredOdb::new(Vec::new(), None).unwrap_err().code,
            ErrorCode::InvalidArgument
        );
        let sha1: Arc<dyn ObjectDb> =
            Arc::new(StaticOdb::from_objects(HashKind::Sha1, std::iter::empty()).unwrap());
        let sha256: Arc<dyn ObjectDb> =
            Arc::new(StaticOdb::from_objects(HashKind::Sha256, std::iter::empty()).unwrap());
        assert_eq!(
            LayeredOdb::new(vec![Arc::clone(&sha1), sha256], None)
                .unwrap_err()
                .code,
            ErrorCode::HashMismatch
        );
        assert_eq!(
            LayeredOdb::new(
                vec![sha1],
                Some((
                    1,
                    CacheOptions {
                        max_bytes: 1,
                        max_entries: 1,
                        max_object_bytes: 1,
                    },
                )),
            )
            .unwrap_err()
            .code,
            ErrorCode::InvalidArgument
        );
    }

    #[test]
    fn first_hit_wins_and_later_layers_are_not_touched() {
        let (first, oids) = CountingStore::blobs(&[b"same"]);
        let (second, _) = CountingStore::blobs(&[b"same"]);
        let layered = LayeredOdb::new(
            vec![
                dyn_store(Arc::clone(&first)),
                dyn_store(Arc::clone(&second)),
            ],
            None,
        )
        .unwrap();

        let mut out = Vec::new();
        layered
            .try_find(&oids[0], &mut out, &Budget::unlimited())
            .unwrap();
        assert_eq!(out, b"same");
        assert_eq!(first.object_calls.load(Ordering::Relaxed), 1);
        assert_eq!(second.object_calls.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn verified_payloads_read_through_and_hits_are_per_budget() {
        let (lower, oids) = CountingStore::blobs(&[b"cached"]);
        let layered = LayeredOdb::new(vec![dyn_store(Arc::clone(&lower))], cache(64)).unwrap();
        let first = Budget::unlimited();
        let second = Budget::unlimited();
        let mut out = Vec::new();

        layered.try_find(&oids[0], &mut out, &first).unwrap();
        layered.try_find(&oids[0], &mut out, &second).unwrap();
        assert_eq!(lower.object_calls.load(Ordering::Relaxed), 1);
        assert_eq!(first.cache_spent(), (0, 1));
        assert_eq!(second.cache_spent(), (1, 0));
        assert_eq!(layered.cache_stats().entries, 1);
        assert_eq!(layered.cache_stats().bytes, 6);
    }

    #[test]
    fn header_reads_cache_verified_payloads_not_unverified_metadata() {
        let (lower, oids) = CountingStore::blobs(&[b"header payload"]);
        let layered = LayeredOdb::new(vec![dyn_store(Arc::clone(&lower))], cache(64)).unwrap();

        let first = layered
            .try_header_with_provenance(&oids[0], &Budget::unlimited())
            .unwrap()
            .unwrap();
        let second = layered
            .try_header_with_provenance(&oids[0], &Budget::unlimited())
            .unwrap()
            .unwrap();
        assert_eq!(first, second);
        assert_eq!(first.provenance, HeaderProvenance::Verified);
        assert_eq!(lower.header_calls.load(Ordering::Relaxed), 0);
        assert_eq!(lower.object_calls.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn per_object_bypass_and_byte_eviction_remain_readable() {
        let (lower, oids) = CountingStore::blobs(&[b"1234", b"56789"]);
        let bypass = LayeredOdb::new(
            vec![dyn_store(Arc::clone(&lower))],
            Some((
                0,
                CacheOptions {
                    max_bytes: 20,
                    max_entries: 10,
                    max_object_bytes: 3,
                },
            )),
        )
        .unwrap();
        let mut out = Vec::new();
        bypass
            .try_find(&oids[0], &mut out, &Budget::unlimited())
            .unwrap();
        bypass
            .try_find(&oids[0], &mut out, &Budget::unlimited())
            .unwrap();
        assert_eq!(lower.object_calls.load(Ordering::Relaxed), 2);
        assert_eq!(bypass.cache_stats().entries, 0);

        lower.object_calls.store(0, Ordering::Relaxed);
        let evicting = LayeredOdb::new(vec![dyn_store(Arc::clone(&lower))], cache(5)).unwrap();
        for oid in [oids[0], oids[1], oids[0]] {
            assert!(evicting
                .try_find(&oid, &mut out, &Budget::unlimited())
                .unwrap()
                .is_some());
        }
        assert_eq!(lower.object_calls.load(Ordering::Relaxed), 3);
        assert!(evicting.cache_stats().evictions >= 2);
        assert_eq!(evicting.cache_stats().entries, 1);
    }

    #[test]
    fn entry_cap_prefetch_and_refresh_fan_out() {
        let (first, oids) = CountingStore::blobs(&[b"a", b"bb"]);
        let (second, _) = CountingStore::blobs(&[]);
        let layered = LayeredOdb::new(
            vec![
                dyn_store(Arc::clone(&first)),
                dyn_store(Arc::clone(&second)),
            ],
            Some((
                0,
                CacheOptions {
                    max_bytes: 100,
                    max_entries: 1,
                    max_object_bytes: 100,
                },
            )),
        )
        .unwrap();
        let mut out = Vec::new();
        layered
            .try_find(&oids[0], &mut out, &Budget::unlimited())
            .unwrap();
        layered
            .try_find(&oids[1], &mut out, &Budget::unlimited())
            .unwrap();
        assert_eq!(layered.cache_stats().entries, 1);
        assert_eq!(layered.cache_stats().evictions, 1);

        layered
            .prefetch(&oids, &Budget::unlimited())
            .expect("prefetch fans out");
        layered
            .refresh(&Budget::unlimited())
            .expect("refresh fans out");
        assert_eq!(first.prefetch_calls.load(Ordering::Relaxed), 1);
        assert_eq!(second.prefetch_calls.load(Ordering::Relaxed), 1);
        assert_eq!(first.refresh_calls.load(Ordering::Relaxed), 1);
        assert_eq!(second.refresh_calls.load(Ordering::Relaxed), 1);
    }
}
