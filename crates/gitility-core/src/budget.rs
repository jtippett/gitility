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
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;

/// The countable ceilings, mirroring `Gitility.Limits` (the timeout
/// becomes [`Budget::deadline`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BudgetLimits {
    pub max_objects: u64,
    pub max_object_bytes: u64,
    pub max_total_object_bytes: u64,
    pub max_provider_requests: u64,
    pub max_provider_bytes: u64,
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
    objects: AtomicU64,
    object_bytes: AtomicU64,
    provider_requests: AtomicU64,
    provider_bytes: AtomicU64,
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
            object_bytes: AtomicU64::new(0),
            provider_requests: AtomicU64::new(0),
            provider_bytes: AtomicU64::new(0),
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
                max_delta_depth: u32::MAX,
            },
            None,
            Arc::new(AtomicBool::new(false)),
        )
    }

    pub fn limits(&self) -> &BudgetLimits {
        &self.limits
    }

    /// The cancellation flag, shared with the job that owns this budget.
    pub fn cancel_flag(&self) -> &Arc<AtomicBool> {
        &self.cancelled
    }

    /// May work continue? Checked at every loop of every walk, scan,
    /// diff, and decode — this is what makes cancellation latency and
    /// timeouts real.
    pub fn check(&self) -> Result<(), Error> {
        if self.cancelled.load(Ordering::Relaxed) {
            return Err(Error::new(ErrorCode::Cancelled, "operation cancelled"));
        }
        if let Some(deadline) = self.deadline {
            if Instant::now() >= deadline {
                return Err(Error::new(ErrorCode::Timeout, "operation budget expired"));
            }
        }
        Ok(())
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
            ));
        }
        charge(&self.objects, 1, self.limits.max_objects, "max_objects")?;
        charge(
            &self.object_bytes,
            bytes,
            self.limits.max_total_object_bytes,
            "max_total_object_bytes",
        )
    }

    /// Charges one provider round trip of `bytes` reply size.
    pub fn charge_provider_request(&self, bytes: u64) -> Result<(), Error> {
        self.check()?;
        charge(
            &self.provider_requests,
            1,
            self.limits.max_provider_requests,
            "max_provider_requests",
        )?;
        charge(
            &self.provider_bytes,
            bytes,
            self.limits.max_provider_bytes,
            "max_provider_bytes",
        )
    }

    /// Validates a delta-chain depth against the ceiling.
    pub fn check_delta_depth(&self, depth: u32) -> Result<(), Error> {
        if depth > self.limits.max_delta_depth {
            return Err(Error::new(
                ErrorCode::BudgetExceeded,
                format!(
                    "delta chain depth {depth} exceeds max_delta_depth {}",
                    self.limits.max_delta_depth
                ),
            ));
        }
        Ok(())
    }

    /// Spend so far: `(objects, object_bytes, provider_requests,
    /// provider_bytes)` — feeds result stats.
    pub fn spent(&self) -> (u64, u64, u64, u64) {
        (
            self.objects.load(Ordering::Relaxed),
            self.object_bytes.load(Ordering::Relaxed),
            self.provider_requests.load(Ordering::Relaxed),
            self.provider_bytes.load(Ordering::Relaxed),
        )
    }
}

/// Adds `amount` to `counter`, failing with `BudgetExceeded` naming the
/// limit if the new total would pass `ceiling`. The add-then-check shape
/// is intentionally conservative under concurrency: two racing charges
/// may both fail at the boundary, never both succeed past it.
fn charge(counter: &AtomicU64, amount: u64, ceiling: u64, limit_name: &str) -> Result<(), Error> {
    let previous = counter.fetch_add(amount, Ordering::Relaxed);
    if previous.saturating_add(amount) > ceiling {
        return Err(Error::new(
            ErrorCode::BudgetExceeded,
            format!("{limit_name} exceeded"),
        ));
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
    }

    #[test]
    fn per_object_size_cap() {
        let limits = BudgetLimits {
            max_object_bytes: 100,
            ..BudgetLimits::default()
        };
        let budget = Budget::new(limits, None, Arc::new(AtomicBool::new(false)));
        assert_eq!(
            budget.charge_object(101).unwrap_err().code,
            ErrorCode::ObjectTooLarge
        );
    }

    #[test]
    fn provider_ceilings_and_spent_accounting() {
        let limits = BudgetLimits {
            max_provider_requests: 2,
            max_provider_bytes: 1000,
            ..BudgetLimits::default()
        };
        let budget = Budget::new(limits, None, Arc::new(AtomicBool::new(false)));
        assert!(budget.charge_provider_request(400).is_ok());
        assert!(budget.charge_provider_request(400).is_ok());
        assert!(budget.charge_provider_request(400).is_err());
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
        assert!(bounded.check_delta_depth(5).is_err());
    }
}
