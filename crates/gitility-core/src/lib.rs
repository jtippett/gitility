//! Gitility's engine-independent query core.
//!
//! This crate owns the stable `ObjectDb`/`RefDb`/`Budget` contracts, DTOs,
//! and query algorithms. It must not depend on Rustler or Elixir concepts,
//! and no Gitoxide type may appear in its public API. See
//! `docs/plans/2026-08-14-gitility-design.md`, Milestone 0.

#![forbid(unsafe_code)]

/// Scaffold marker proving the NIF crate links against the core crate.
/// Removed when Milestone 0 lands the real contracts.
pub const CORE_PRESENT: bool = true;
