//! Per-operation resource budgets.
//!
//! A [`Budget`] is threaded through every algorithm and store call. It
//! answers two questions continuously: *may I keep going?* ([`Budget::check`],
//! covering cancellation and the deadline) and *may I spend this?* (the
//! `charge_*` methods, covering the countable ceilings). Charges use
//! atomics so one budget can be shared across a job's internal
//! parallelism.
//!
//! Exceeding a ceiling is not necessarily fatal to a query: callers that
//! can truncate catch `BudgetExceeded` and return a partial result with
//! `truncated: true` and a cursor. The budget only enforces; policy lives
//! with the operation.

use crate::error::{Error, ErrorCode};
use crate::object::Oid;
use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

/// The countable ceilings, mirroring `Gitility.Limits` (the timeout is
/// carried separately by [`Budget`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BudgetLimits {
    pub max_objects: u64,
    pub max_object_bytes: u64,
    pub max_total_object_bytes: u64,
    pub max_provider_requests: u64,
    pub max_provider_bytes: u64,
    pub max_tree_entries: u64,
    pub max_delta_depth: u32,
}

impl Default for BudgetLimits {
    fn default() -> Self {
        // Keep in sync with the defaults documented on `Gitility.Limits`.
        Self {
            max_objects: 100_000,
            max_object_bytes: 4 << 20,
            max_total_object_bytes: 256 << 20,
            max_provider_requests: 500,
            max_provider_bytes: 256 << 20,
            max_tree_entries: 20_000,
            max_delta_depth: 128,
        }
    }
}

/// A live budget: limits plus spend counters, a deadline, and the job's
/// cancellation flag.
#[derive(Debug)]
pub struct Budget {
    limits: BudgetLimits,
    deadline: Option<Instant>,
    cancelled: Arc<AtomicBool>,
    /// Charges against `max_objects`, including header lookups.
    objects: AtomicU64,
    /// Nesting depth for graph reads whose distinct-visit charge is managed by
    /// the traversal rather than by the object-store call.
    object_charge_suspensions: AtomicU64,
    /// Nesting depth for a repeated graph payload whose first read was already
    /// charged in this job.
    duplicate_graph_read_suspensions: AtomicU64,
    /// Object IDs whose graph payload bytes were already accounted once.
    graph_reads: Mutex<HashSet<Oid>>,
    /// Payload reads exposed through query stats; headers are not reads.
    objects_read: AtomicU64,
    object_bytes: AtomicU64,
    provider_requests: AtomicU64,
    provider_bytes: AtomicU64,
    tree_entries: AtomicU64,
    cache_hits: AtomicU64,
    cache_misses: AtomicU64,
}

impl Budget {
    pub fn new(
        limits: BudgetLimits,
        deadline: Option<Instant>,
        cancelled: Arc<AtomicBool>,
    ) -> Self {
        Self {
            limits,
            deadline,
            cancelled,
            objects: AtomicU64::new(0),
            object_charge_suspensions: AtomicU64::new(0),
            duplicate_graph_read_suspensions: AtomicU64::new(0),
            graph_reads: Mutex::new(HashSet::new()),
            objects_read: AtomicU64::new(0),
            object_bytes: AtomicU64::new(0),
            provider_requests: AtomicU64::new(0),
            provider_bytes: AtomicU64::new(0),
            tree_entries: AtomicU64::new(0),
            cache_hits: AtomicU64::new(0),
            cache_misses: AtomicU64::new(0),
        }
    }

    /// An unbounded budget that can still be cancelled — for tests and
    /// internal work that is bounded elsewhere.
    pub fn unlimited() -> Self {
        Self::new(
            BudgetLimits {
                max_objects: u64::MAX,
                max_object_bytes: u64::MAX,
                max_total_object_bytes: u64::MAX,
                max_provider_requests: u64::MAX,
                max_provider_bytes: u64::MAX,
                max_tree_entries: u64::MAX,
                max_delta_depth: u32::MAX,
            },
            None,
            Arc::new(AtomicBool::new(false)),
        )
    }

    pub fn limits(&self) -> &BudgetLimits {
        &self.limits
    }

    /// The wall-clock deadline carried by this operation, when one exists.
    ///
    /// Provider waits use this to bound their own per-request timeout by the
    /// job deadline without sleeping past the next cancellation check.
    pub fn deadline(&self) -> Option<Instant> {
        self.deadline
    }

    /// The cancellation flag, shared with the job that owns this budget.
    pub fn cancel_flag(&self) -> &Arc<AtomicBool> {
        &self.cancelled
    }

    /// May work continue? Checked at every loop of every walk, scan,
    /// diff, and decode — this is what makes cancellation latency and
    /// timeouts real.
    pub fn check(&self) -> Result<(), Error> {
        if self.cancelled.load(Ordering::Acquire) {
            return Err(Error::new(ErrorCode::Cancelled, "operation cancelled"));
        }
        if let Some(deadline) = self.deadline {
            if Instant::now() >= deadline {
                return Err(Error::new(ErrorCode::Timeout, "operation budget expired"));
            }
        }
        Ok(())
    }

    /// Whether this budget's wall-clock deadline has passed.
    ///
    /// The runtime uses this while holding its admission queue lock to sweep
    /// expired queued jobs without confusing a separate cancellation request
    /// with deadline expiry.
    pub(crate) fn deadline_expired(&self) -> bool {
        self.deadline
            .is_some_and(|deadline| Instant::now() >= deadline)
    }

    /// Charges one object of `bytes` inflated size against the object
    /// count, the per-object cap, and the total-bytes ceiling.
    pub fn charge_object(&self, bytes: u64) -> Result<(), Error> {
        self.check()?;
        if bytes > self.limits.max_object_bytes {
            return Err(Error::new(
                ErrorCode::ObjectTooLarge,
                format!(
                    "object of {bytes} bytes exceeds max_object_bytes {}",
                    self.limits.max_object_bytes
                ),
            )
            .with_limit("max_object_bytes"));
        }
        if self.object_charge_suspensions.load(Ordering::Relaxed) == 0 {
            charge(&self.objects, 1, self.limits.max_objects, "max_objects")?;
        }
        if self
            .duplicate_graph_read_suspensions
            .load(Ordering::Relaxed)
            == 0
        {
            self.objects_read.fetch_add(1, Ordering::Relaxed);
            charge(
                &self.object_bytes,
                bytes,
                self.limits.max_total_object_bytes,
                "max_total_object_bytes",
            )?;
        }
        Ok(())
    }

    /// Charges one graph-visit against `max_objects` without claiming an
    /// additional payload read. Commit walks use this because `max_objects`
    /// governs distinct commits visited rather than payload fetch count.
    pub(crate) fn charge_object_visit(&self) -> Result<(), Error> {
        self.check()?;
        if self.object_charge_suspensions.load(Ordering::Relaxed) == 0 {
            charge(&self.objects, 1, self.limits.max_objects, "max_objects")?;
        }
        Ok(())
    }

    /// Runs one synchronous object-store read without its normal
    /// `max_objects` charge. All other limits, counters, cache statistics,
    /// cancellation, and timeout behavior remain active.
    pub(crate) fn without_object_charge<T>(&self, oid: Oid, read: impl FnOnce() -> T) -> T {
        struct Restore<'a> {
            object: &'a AtomicU64,
            duplicate: Option<&'a AtomicU64>,
        }
        impl Drop for Restore<'_> {
            fn drop(&mut self) {
                self.object.fetch_sub(1, Ordering::Relaxed);
                if let Some(duplicate) = self.duplicate {
                    duplicate.fetch_sub(1, Ordering::Relaxed);
                }
            }
        }

        let duplicate = !self
            .graph_reads
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(oid);
        self.object_charge_suspensions
            .fetch_add(1, Ordering::Relaxed);
        if duplicate {
            self.duplicate_graph_read_suspensions
                .fetch_add(1, Ordering::Relaxed);
        }
        let restore = Restore {
            object: &self.object_charge_suspensions,
            duplicate: duplicate.then_some(&self.duplicate_graph_read_suspensions),
        };
        let result = read();
        drop(restore);
        result
    }

    /// Replays cursor-prefix work without spending object-count or payload
    /// byte/read accounting a second time. The underlying reads and all
    /// decoding/diff work still happen, and cancellation, deadlines,
    /// per-object size checks, provider ceilings, and cache accounting remain
    /// active. Path history uses this while rebuilding rename-retarget state.
    pub(crate) fn without_object_recharge<T>(&self, replay: impl FnOnce() -> T) -> T {
        struct Restore<'a> {
            objects: &'a AtomicU64,
            payloads: &'a AtomicU64,
        }
        impl Drop for Restore<'_> {
            fn drop(&mut self) {
                self.objects.fetch_sub(1, Ordering::Relaxed);
                self.payloads.fetch_sub(1, Ordering::Relaxed);
            }
        }

        self.object_charge_suspensions
            .fetch_add(1, Ordering::Relaxed);
        self.duplicate_graph_read_suspensions
            .fetch_add(1, Ordering::Relaxed);
        let restore = Restore {
            objects: &self.object_charge_suspensions,
            payloads: &self.duplicate_graph_read_suspensions,
        };
        let result = replay();
        drop(restore);
        result
    }

    /// Charges a header lookup against the object-count ceiling only.
    ///
    /// Header reads intentionally do not spend byte budget because they do not
    /// return or retain an inflated payload.
    pub fn charge_header(&self) -> Result<(), Error> {
        self.check()?;
        if self.object_charge_suspensions.load(Ordering::Relaxed) == 0 {
            charge(&self.objects, 1, self.limits.max_objects, "max_objects")?;
        }
        Ok(())
    }

    /// Charges one tree entry that is about to be emitted.
    pub fn charge_tree_entry(&self) -> Result<(), Error> {
        self.check()?;
        charge(
            &self.tree_entries,
            1,
            self.limits.max_tree_entries,
            "max_tree_entries",
        )
    }

    /// Charges bytes read by an optional whole-file object-store integrity
    /// scan. These bytes count toward total object I/O, but not the per-object
    /// size cap or object count.
    pub(crate) fn charge_integrity_bytes(&self, bytes: u64) -> Result<(), Error> {
        self.check()?;
        charge(
            &self.object_bytes,
            bytes,
            self.limits.max_total_object_bytes,
            "max_total_object_bytes",
        )
    }

    /// Charges one provider round trip before it is dispatched.
    pub fn charge_provider_request(&self) -> Result<(), Error> {
        self.check()?;
        charge(
            &self.provider_requests,
            1,
            self.limits.max_provider_requests,
            "max_provider_requests",
        )
    }

    /// Charges bytes in a provider reply before they are trusted or cached.
    pub fn charge_provider_bytes(&self, bytes: u64) -> Result<(), Error> {
        self.check()?;
        charge(
            &self.provider_bytes,
            bytes,
            self.limits.max_provider_bytes,
            "max_provider_bytes",
        )
    }

    /// Records one lookup served by a writable layered cache. Cache counters
    /// are accounting only: they have no ceiling and never make work fail.
    pub fn record_cache_hit(&self) {
        self.cache_hits.fetch_add(1, Ordering::Relaxed);
    }

    /// Records one lookup that reached a writable layered cache but was not
    /// resident. Bypassed objects count as misses again on later jobs.
    pub fn record_cache_miss(&self) {
        self.cache_misses.fetch_add(1, Ordering::Relaxed);
    }

    /// Validates a delta-chain depth against the ceiling.
    ///
    /// # Pack-reader integration contract
    ///
    /// The pinned `gix-odb` lookup API does **not** expose the resolved
    /// delta-chain depth or inflated base sizes. Consequently local ODB reads
    /// cannot enforce this limit until the M5 pack reader owns delta traversal;
    /// callers that do know a depth must still enforce it here. Do not infer a
    /// depth from pack location or final object size.
    pub fn check_delta_depth(&self, depth: u32) -> Result<(), Error> {
        if depth > self.limits.max_delta_depth {
            return Err(Error::new(
                ErrorCode::BudgetExceeded,
                format!(
                    "delta chain depth {depth} exceeds max_delta_depth {}",
                    self.limits.max_delta_depth
                ),
            )
            .with_limit("max_delta_depth"));
        }
        Ok(())
    }

    /// Spend so far: `(payload_objects_read, object_bytes,
    /// provider_requests, provider_bytes)` — feeds result stats. Header
    /// lookups still charge `max_objects`, but are not payload reads.
    pub fn spent(&self) -> (u64, u64, u64, u64) {
        (
            self.objects_read.load(Ordering::Relaxed),
            self.object_bytes.load(Ordering::Relaxed),
            self.provider_requests.load(Ordering::Relaxed),
            self.provider_bytes.load(Ordering::Relaxed),
        )
    }

    /// Number of tree-entry emission charges attempted so far.
    pub fn tree_entries_spent(&self) -> u64 {
        self.tree_entries.load(Ordering::Relaxed)
    }

    /// Layered-cache lookup accounting for this budget/job: `(hits, misses)`.
    pub fn cache_spent(&self) -> (u64, u64) {
        (
            self.cache_hits.load(Ordering::Relaxed),
            self.cache_misses.load(Ordering::Relaxed),
        )
    }
}

/// Adds `amount` to `counter`, failing with `BudgetExceeded` naming the
/// limit if the new total would pass `ceiling`. The add-then-check shape
/// is intentionally conservative under concurrency: two racing charges
/// may both fail at the boundary, never both succeed past it.
fn charge(
    counter: &AtomicU64,
    amount: u64,
    ceiling: u64,
    limit_name: &'static str,
) -> Result<(), Error> {
    let previous = counter.fetch_add(amount, Ordering::Relaxed);
    if previous.saturating_add(amount) > ceiling {
        return Err(
            Error::new(ErrorCode::BudgetExceeded, format!("{limit_name} exceeded"))
                .with_limit(limit_name),
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn cancellation_interrupts() {
        let budget = Budget::unlimited();
        assert!(budget.check().is_ok());
        budget.cancel_flag().store(true, Ordering::Relaxed);
        let err = budget.check().unwrap_err();
        assert_eq!(err.code, ErrorCode::Cancelled);
    }

    #[test]
    fn deadline_expires() {
        let budget = Budget::new(
            BudgetLimits::default(),
            Some(Instant::now() - Duration::from_millis(1)),
            Arc::new(AtomicBool::new(false)),
        );
        assert_eq!(budget.check().unwrap_err().code, ErrorCode::Timeout);
    }

    #[test]
    fn object_count_ceiling() {
        let limits = BudgetLimits {
            max_objects: 2,
            ..BudgetLimits::default()
        };
        let budget = Budget::new(limits, None, Arc::new(AtomicBool::new(false)));
        assert!(budget.charge_object(10).is_ok());
        assert!(budget.charge_object(10).is_ok());
        let err = budget.charge_object(10).unwrap_err();
        assert_eq!(err.code, ErrorCode::BudgetExceeded);
        assert_eq!(err.limit, Some("max_objects"));
    }

    #[test]
    fn header_charge_uses_the_object_ceiling_but_is_not_a_payload_read() {
        let budget = Budget::unlimited();
        budget.charge_header().expect("header charge succeeds");
        assert_eq!(budget.spent(), (0, 0, 0, 0));
    }

    #[test]
    fn per_object_size_cap() {
        let limits = BudgetLimits {
            max_object_bytes: 100,
            ..BudgetLimits::default()
        };
        let budget = Budget::new(limits, None, Arc::new(AtomicBool::new(false)));
        let error = budget.charge_object(101).unwrap_err();
        assert_eq!(error.code, ErrorCode::ObjectTooLarge);
        assert_eq!(error.limit, Some("max_object_bytes"));
    }

    #[test]
    fn provider_ceilings_and_spent_accounting() {
        let limits = BudgetLimits {
            max_provider_requests: 2,
            max_provider_bytes: 1000,
            ..BudgetLimits::default()
        };
        let budget = Budget::new(limits, None, Arc::new(AtomicBool::new(false)));
        assert!(budget.charge_provider_request().is_ok());
        assert!(budget.charge_provider_bytes(400).is_ok());
        assert!(budget.charge_provider_request().is_ok());
        assert!(budget.charge_provider_bytes(400).is_ok());
        assert!(budget.charge_provider_request().is_err());
        let (_, _, requests, bytes) = budget.spent();
        assert_eq!(requests, 3); // failed charge still recorded as attempted spend
        assert_eq!(bytes, 800);
    }

    #[test]
    fn delta_depth_ceiling() {
        let budget = Budget::unlimited();
        assert!(budget.check_delta_depth(1_000_000).is_ok());

        let limits = BudgetLimits {
            max_delta_depth: 4,
            ..BudgetLimits::default()
        };
        let bounded = Budget::new(limits, None, Arc::new(AtomicBool::new(false)));
        assert!(bounded.check_delta_depth(4).is_ok());
        assert_eq!(
            bounded.check_delta_depth(5).unwrap_err().limit,
            Some("max_delta_depth")
        );
    }

    #[test]
    fn tree_entry_ceiling_is_separate_from_object_spend() {
        let budget = Budget::new(
            BudgetLimits {
                max_tree_entries: 1,
                ..BudgetLimits::default()
            },
            None,
            Arc::new(AtomicBool::new(false)),
        );
        budget
            .charge_tree_entry()
            .expect("first tree entry is allowed");
        let err = budget
            .charge_tree_entry()
            .expect_err("second tree entry exceeds the limit");
        assert_eq!(err.code, ErrorCode::BudgetExceeded);
        assert!(err.message.contains("max_tree_entries"));
        assert_eq!(err.limit, Some("max_tree_entries"));
        assert_eq!(budget.spent(), (0, 0, 0, 0));
        assert_eq!(budget.tree_entries_spent(), 2);
    }

    #[test]
    fn cache_accounting_is_per_budget_and_unbounded() {
        let first = Budget::unlimited();
        first.record_cache_hit();
        first.record_cache_hit();
        first.record_cache_miss();
        assert_eq!(first.cache_spent(), (2, 1));
        assert_eq!(Budget::unlimited().cache_spent(), (0, 0));
    }
}
