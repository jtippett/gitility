//! Reusable O(1) weighted least-recently-used cache.
//!
//! Keys map to stable slab indices, while each occupied slab node participates
//! in an intrusive doubly-linked recency list. Lookups, touches, replacement,
//! and eviction therefore avoid scans even when the cache is full.

use std::collections::HashMap;
use std::hash::Hash;

#[derive(Debug)]
struct Node<K, V> {
    key: K,
    value: V,
    weight: u64,
    previous: Option<usize>,
    next: Option<usize>,
}

/// A weighted LRU cache with O(1) lookup, insertion, touch, and eviction.
///
/// `capacity` and insertion weights use caller-defined units, so the same
/// implementation can bound payload bytes, entry counts, or other resources.
#[derive(Debug)]
pub struct LruCache<K, V> {
    indices: HashMap<K, usize>,
    nodes: Vec<Option<Node<K, V>>>,
    free: Vec<usize>,
    least_recent: Option<usize>,
    most_recent: Option<usize>,
    used: u64,
    capacity: u64,
}

impl<K, V> LruCache<K, V>
where
    K: Clone + Eq + Hash,
{
    /// Creates a cache with the supplied total weight capacity. Zero disables
    /// insertion while preserving the normal lookup API.
    pub fn new(capacity: u64) -> Self {
        Self {
            indices: HashMap::new(),
            nodes: Vec::new(),
            free: Vec::new(),
            least_recent: None,
            most_recent: None,
            used: 0,
            capacity,
        }
    }

    /// Returns and promotes an entry to most-recently-used.
    pub fn get(&mut self, key: &K) -> Option<&V> {
        let index = *self.indices.get(key)?;
        self.touch(index);
        self.nodes[index].as_ref().map(|node| &node.value)
    }

    /// Returns a cloned value while promoting its entry.
    pub fn get_cloned(&mut self, key: &K) -> Option<V>
    where
        V: Clone,
    {
        self.get(key).cloned()
    }

    /// Inserts or replaces an entry. Entries heavier than the entire cache
    /// are not retained.
    pub fn insert(&mut self, key: K, value: V, weight: u64) {
        let _ = self.insert_counting_evictions(key, value, weight);
    }

    /// Inserts or replaces an entry and returns the number of resident
    /// entries evicted to satisfy the weight capacity. Replacing the same key
    /// is not an eviction, and an entry that bypasses because it is heavier
    /// than the cache returns zero.
    pub fn insert_counting_evictions(&mut self, key: K, value: V, weight: u64) -> u64 {
        if let Some(index) = self.indices.get(&key).copied() {
            self.remove_index(index);
        }
        if self.capacity == 0 || weight > self.capacity {
            return 0;
        }

        let mut evictions = 0u64;
        while self.used.saturating_add(weight) > self.capacity {
            let Some(index) = self.least_recent else {
                break;
            };
            self.remove_index(index);
            evictions = evictions.saturating_add(1);
        }

        let index = self.free.pop().unwrap_or_else(|| {
            self.nodes.push(None);
            self.nodes.len() - 1
        });
        let previous = self.most_recent;
        self.nodes[index] = Some(Node {
            key: key.clone(),
            value,
            weight,
            previous,
            next: None,
        });
        if let Some(previous) = previous {
            self.node_mut(previous).next = Some(index);
        } else {
            self.least_recent = Some(index);
        }
        self.most_recent = Some(index);
        self.used = self.used.saturating_add(weight);
        self.indices.insert(key, index);
        evictions
    }

    /// Evicts and returns the least-recently-used entry.
    pub fn pop_lru(&mut self) -> Option<(K, V)> {
        let index = self.least_recent?;
        self.remove_index(index).map(|node| (node.key, node.value))
    }

    /// Removes an entry and returns its value.
    pub fn remove(&mut self, key: &K) -> Option<V> {
        let index = *self.indices.get(key)?;
        self.remove_index(index).map(|node| node.value)
    }

    /// Removes all entries while retaining allocated slabs for reuse.
    pub fn clear(&mut self) {
        self.indices.clear();
        self.free.clear();
        for (index, node) in self.nodes.iter_mut().enumerate() {
            *node = None;
            self.free.push(index);
        }
        self.least_recent = None;
        self.most_recent = None;
        self.used = 0;
    }

    /// Number of resident entries.
    pub fn len(&self) -> usize {
        self.indices.len()
    }

    /// Whether the cache is empty.
    pub fn is_empty(&self) -> bool {
        self.indices.is_empty()
    }

    /// Current resident weight.
    pub fn used(&self) -> u64 {
        self.used
    }

    fn touch(&mut self, index: usize) {
        if self.most_recent == Some(index) {
            return;
        }
        let (previous, next) = {
            let node = self.node(index);
            (node.previous, node.next)
        };
        if let Some(previous) = previous {
            self.node_mut(previous).next = next;
        } else {
            self.least_recent = next;
        }
        if let Some(next) = next {
            self.node_mut(next).previous = previous;
        }

        let old_most_recent = self.most_recent;
        {
            let node = self.node_mut(index);
            node.previous = old_most_recent;
            node.next = None;
        }
        if let Some(old_most_recent) = old_most_recent {
            self.node_mut(old_most_recent).next = Some(index);
        } else {
            self.least_recent = Some(index);
        }
        self.most_recent = Some(index);
    }

    fn remove_index(&mut self, index: usize) -> Option<Node<K, V>> {
        let node = self.nodes.get_mut(index)?.take()?;
        if let Some(previous) = node.previous {
            self.node_mut(previous).next = node.next;
        } else {
            self.least_recent = node.next;
        }
        if let Some(next) = node.next {
            self.node_mut(next).previous = node.previous;
        } else {
            self.most_recent = node.previous;
        }
        self.indices.remove(&node.key);
        self.used = self.used.saturating_sub(node.weight);
        self.free.push(index);
        Some(node)
    }

    fn node(&self, index: usize) -> &Node<K, V> {
        self.nodes[index]
            .as_ref()
            .expect("linked LRU index must name an occupied node")
    }

    fn node_mut(&mut self, index: usize) -> &mut Node<K, V> {
        self.nodes[index]
            .as_mut()
            .expect("linked LRU index must name an occupied node")
    }
}

#[cfg(test)]
mod tests {
    use super::LruCache;
    use std::time::{Duration, Instant};

    #[test]
    fn weighted_eviction_and_touch_are_least_recently_used() {
        let mut cache = LruCache::new(3);
        cache.insert("first", 1, 1);
        cache.insert("second", 2, 1);
        cache.insert("third", 3, 1);
        assert_eq!(cache.get(&"first"), Some(&1));

        assert_eq!(cache.insert_counting_evictions("fourth", 4, 1), 1);
        assert_eq!(cache.get(&"second"), None);
        assert_eq!(cache.get(&"first"), Some(&1));
        assert_eq!(cache.used(), 3);

        assert_eq!(cache.insert_counting_evictions("heavy", 5, 3), 3);
        assert_eq!(cache.len(), 1);
        assert_eq!(cache.get(&"heavy"), Some(&5));
    }

    #[test]
    fn pop_lru_preserves_recency_links_and_weight() {
        let mut cache = LruCache::new(10);
        cache.insert("first", 1, 2);
        cache.insert("second", 2, 3);
        cache.insert("third", 3, 4);
        assert_eq!(cache.get(&"first"), Some(&1));

        assert_eq!(cache.pop_lru(), Some(("second", 2)));
        assert_eq!(cache.used(), 6);
        assert_eq!(cache.len(), 2);
        assert_eq!(cache.pop_lru(), Some(("third", 3)));
        assert_eq!(cache.pop_lru(), Some(("first", 1)));
        assert!(cache.is_empty());
        assert_eq!(cache.used(), 0);
    }

    #[test]
    fn one_hundred_thousand_inserts_and_gets_stay_bounded() {
        let started = Instant::now();
        let mut cache = LruCache::new(100_000);
        for key in 0..100_000u64 {
            cache.insert(key, key, 1);
        }
        for key in 0..100_000u64 {
            assert_eq!(cache.get(&key), Some(&key));
        }
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "O(1) LRU workload took {:?}",
            started.elapsed()
        );
    }
}
