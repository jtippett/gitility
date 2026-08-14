//! Core Git query engine for Gitility.
//!
//! This crate owns all Git semantics behind stable, engine-agnostic
//! contracts. Two hard rules, from the design document:
//!
//! * **No Rustler or Elixir concepts.** The NIF crate adapts this crate's
//!   DTOs to the BEAM; nothing here knows the BEAM exists.
//! * **No Gitoxide types in the public API.** The `gix` family is an
//!   internal engine pinned exactly (R5); every store — local, static,
//!   callback, layered, pack-range — presents the same [`ObjectDb`]
//!   contract to every algorithm.

#![forbid(unsafe_code)]

pub mod budget;
pub mod decode;
pub mod error;
pub mod local_odb;
pub mod object;
pub mod odb;
pub mod refs;
pub mod static_odb;
pub mod verify;

#[cfg(test)]
mod test_support;

pub use budget::{Budget, BudgetLimits};
pub use decode::{
    decode_commit, decode_tag, decode_tree, Commit, Identity, Tag, TreeEntry, TreeIter,
};
pub use error::{Error, ErrorCode};
pub use local_odb::{LocalOdb, LocalOdbOptions, RepositoryLayout};
pub use object::{HashKind, ObjectHeader, ObjectKind, Oid};
pub use odb::ObjectDb;
pub use refs::{RefDb, RefPage, RefQuery, RefTarget};
pub use static_odb::StaticOdb;
pub use verify::verify;
