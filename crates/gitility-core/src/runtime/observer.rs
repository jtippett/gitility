use super::{Job, JobObserver};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

/// A small observer useful to downstream and in-crate tests.
///
/// It records the number of callbacks and offers a bounded wait without
/// consuming job outputs.
#[derive(Debug, Default)]
pub struct TestObserver {
    completions: AtomicU64,
    gate: Mutex<()>,
    wake: Condvar,
}

impl TestObserver {
    /// Number of completion callbacks observed so far.
    pub fn completions(&self) -> u64 {
        self.completions.load(Ordering::Acquire)
    }

    /// Waits until at least `wanted` callbacks have arrived or `timeout`
    /// elapses.
    pub fn wait_for(&self, wanted: u64, timeout: Duration) -> bool {
        let deadline = Instant::now().checked_add(timeout);
        let mut guard = self
            .gate
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        loop {
            if self.completions() >= wanted {
                return true;
            }
            let remaining = deadline
                .and_then(|deadline| deadline.checked_duration_since(Instant::now()))
                .unwrap_or(Duration::ZERO);
            if remaining.is_zero() {
                return false;
            }
            let waited = self.wake.wait_timeout(guard, remaining);
            match waited {
                Ok((next, result)) => {
                    guard = next;
                    if result.timed_out() && self.completions() < wanted {
                        return false;
                    }
                }
                Err(poisoned) => {
                    let (next, _) = poisoned.into_inner();
                    guard = next;
                }
            }
        }
    }
}

impl JobObserver for TestObserver {
    fn completed(&self, _job: &Job) {
        let _guard = self
            .gate
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        self.completions.fetch_add(1, Ordering::Release);
        self.wake.notify_all();
    }
}
