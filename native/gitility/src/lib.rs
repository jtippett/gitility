//! Rustler NIF adapter for Gitility.
//!
//! This crate owns the BEAM boundary only: term encoding, resources, and the
//! job runtime handoff. All Git semantics live in `gitility-core`, which must
//! never depend on Rustler or Elixir concepts. See
//! `docs/plans/2026-08-14-gitility-design.md`.

#![forbid(unsafe_code)]

#[rustler::nif]
fn ping() -> rustler::Atom {
    // Touch the core so the scaffold proves the crates link end to end.
    let _ = gitility_core::HashKind::Sha1;
    atoms::pong()
}

mod atoms {
    rustler::atoms! {
        pong,
    }
}

rustler::init!("Elixir.Gitility.Native");
