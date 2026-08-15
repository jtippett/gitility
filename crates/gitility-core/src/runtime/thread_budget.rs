//! Process-wide budget for runtime-owned OS threads.
//!
//! Every native thread the runtime layer spawns — workers here, the
//! notification pump in the NIF crate — must hold a [`ThreadReservation`]
//! against the process-global budget. When the budget is exhausted,
//! [`super::Runtime::try_start`] fails with [`BudgetExhausted`] instead of
//! spawning. This is the backstop that turns an orchestration bug (runtimes
//! created faster than they are shut down) into a loud, recoverable error
//! instead of unbounded thread growth: on 2026-08-14 a BEAM process
//! accumulated ~10,000 native threads and took the kernel down with it
//! (XNU spinlock timeout in the pthread kext), twice.
//!
//! The budget deliberately uses `std` atomics rather than the loom-swapped
//! [`super::sync`] types: it is process-global bookkeeping, and a `static`
//! cannot participate in loom's per-model state space. Loom models still
//! exercise reserve/release balance; they just don't explore its
//! interleavings, which is fine for a saturating counter with no ordering
//! dependencies on other state.

use std::fmt;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::OnceLock;

/// Default process-wide ceiling on runtime-owned threads.
///
/// Far above any sane configuration (a runtime holds `workers + 1` threads,
/// so this admits ~100 default-sized runtimes) and far below the point where
/// thread count endangers the host.
pub const DEFAULT_LIMIT: usize = 512;

/// Environment variable that overrides [`DEFAULT_LIMIT`], read once at first
/// use. Values that fail to parse as a positive integer fall back to the
/// default.
pub const LIMIT_ENV_VAR: &str = "GITILITY_THREAD_BUDGET";

/// A saturating counter of live runtime-owned threads against a fixed limit.
#[derive(Debug)]
pub struct ThreadBudget {
    limit: usize,
    used: AtomicUsize,
}

/// A reservation request exceeded the remaining budget. Carries the state
/// observed at rejection time for error messages and telemetry.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BudgetExhausted {
    pub requested: usize,
    pub used: usize,
    pub limit: usize,
}

impl fmt::Display for BudgetExhausted {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "requested {} thread(s) with {}/{} in use; \
             a leak of runtime handles is the usual cause \
             (override with {})",
            self.requested, self.used, self.limit, LIMIT_ENV_VAR
        )
    }
}

impl std::error::Error for BudgetExhausted {}

impl ThreadBudget {
    pub const fn new(limit: usize) -> Self {
        Self {
            limit,
            used: AtomicUsize::new(0),
        }
    }

    pub fn limit(&self) -> usize {
        self.limit
    }

    pub fn used(&self) -> usize {
        self.used.load(Ordering::Acquire)
    }

    /// Reserves capacity for `count` threads, or reports the observed state.
    ///
    /// The reservation is released by dropping the returned guard (or the
    /// guards split off it), so a panicking thread still returns its slot.
    pub fn try_reserve(&'static self, count: usize) -> Result<ThreadReservation, BudgetExhausted> {
        let mut used = self.used.load(Ordering::Acquire);
        loop {
            if count > self.limit.saturating_sub(used) {
                return Err(BudgetExhausted {
                    requested: count,
                    used,
                    limit: self.limit,
                });
            }
            match self.used.compare_exchange_weak(
                used,
                used + count,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => {
                    return Ok(ThreadReservation {
                        budget: self,
                        count,
                    })
                }
                Err(observed) => used = observed,
            }
        }
    }
}

/// Owned budget capacity. Dropping it returns the capacity.
#[must_use = "dropping a reservation immediately returns its capacity"]
#[derive(Debug)]
pub struct ThreadReservation {
    budget: &'static ThreadBudget,
    count: usize,
}

impl ThreadReservation {
    pub fn count(&self) -> usize {
        self.count
    }

    /// Splits a single-thread reservation off this one, so each spawned
    /// thread can own (and release) exactly its own slot.
    ///
    /// # Panics
    ///
    /// Panics if this reservation is empty; callers split at most
    /// [`ThreadReservation::count`] times.
    pub fn split_one(&mut self) -> ThreadReservation {
        assert!(self.count > 0, "cannot split an empty thread reservation");
        self.count -= 1;
        ThreadReservation {
            budget: self.budget,
            count: 1,
        }
    }
}

impl Drop for ThreadReservation {
    fn drop(&mut self) {
        if self.count > 0 {
            self.budget.used.fetch_sub(self.count, Ordering::AcqRel);
        }
    }
}

/// The process-global budget used by [`super::Runtime::try_start`] and the
/// NIF layer's notification pump.
pub fn global() -> &'static ThreadBudget {
    static GLOBAL: OnceLock<ThreadBudget> = OnceLock::new();
    GLOBAL.get_or_init(|| ThreadBudget::new(limit_from_env()))
}

fn limit_from_env() -> usize {
    std::env::var(LIMIT_ENV_VAR)
        .ok()
        .and_then(|value| value.trim().parse::<usize>().ok())
        .filter(|&limit| limit > 0)
        .unwrap_or(DEFAULT_LIMIT)
}
