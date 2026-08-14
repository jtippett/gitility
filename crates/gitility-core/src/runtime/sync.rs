//! Synchronization types used by the runtime.
//!
//! Production builds use `std`; `--cfg loom` swaps only the runtime's
//! concurrency primitives for loom's modeled equivalents.

#[cfg(all(loom, test))]
pub(crate) use loom::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};
#[cfg(all(loom, test))]
pub(crate) use loom::sync::{Arc, Condvar, Mutex, MutexGuard};
#[cfg(all(loom, test))]
pub(crate) use loom::thread;

#[cfg(not(all(loom, test)))]
pub(crate) use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};
#[cfg(not(all(loom, test)))]
pub(crate) use std::sync::{Arc, Condvar, Mutex, MutexGuard};
#[cfg(not(all(loom, test)))]
pub(crate) use std::thread;

pub(crate) fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

pub(crate) fn wait<'a, T>(condvar: &Condvar, guard: MutexGuard<'a, T>) -> MutexGuard<'a, T> {
    condvar
        .wait(guard)
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}
