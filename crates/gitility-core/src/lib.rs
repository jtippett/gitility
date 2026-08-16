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

pub mod ancestry;
pub mod budget;
mod commit_graph;
pub mod cursor;
pub mod decode;
pub mod diff;
pub mod error;
pub mod file;
pub mod layered_odb;
pub mod local_odb;
pub mod log;
pub mod lru;
pub mod object;
pub mod odb;
pub mod packfetch;
pub mod pathspec;
pub mod provider_odb;
pub mod refs;
pub mod runtime;
pub mod search;
pub mod snapshot;
pub mod static_odb;
pub mod tree;
pub mod verify;

#[cfg(test)]
mod test_support;

pub use ancestry::{is_ancestor, merge_base};
pub use budget::{Budget, BudgetLimits};
pub use cursor::{decode as decode_cursor, encode as encode_cursor, Cursor, CursorExpected};
pub use decode::{
    decode_commit, decode_tag, decode_tree, Commit, Identity, Tag, TreeEntry, TreeIter,
};
pub use diff::{
    diff, Diff, DiffFile, DiffFormat, DiffHunk, DiffLine, DiffLineOrigin, DiffOptions, DiffStatus,
    DiffWarning, DiffWarningCode, RenameTracking,
};
pub use error::{Error, ErrorCode};
pub use file::{read_file, FileKind, FileOptions, FileRead, LfsPointer};
pub use layered_odb::{CacheLayer, CacheOptions, LayeredOdb};
pub use local_odb::{LocalOdb, LocalOdbOptions, RepositoryLayout};
pub use log::{log, LogCommit, LogIdentity, LogOptions, LogOrder, LogPage};
pub use object::{HashKind, ObjectHeader, ObjectKind, Oid};
pub use odb::{
    CacheStats, HeaderProvenance, HeaderRead, ObjectDb, ObjectReadResult, ReadManyBudget,
};
pub use packfetch::{
    ByteRange, CallbackRangeTransport, HydrationStats, PackDescriptor, PackFetchOdb,
    PackFetchOptions, PackManifest, RangePayload, RangePendingTable, RangeReplySlot, RangeRequest,
    RangeRequestKind, RangeRequestSender, RangeTransport,
};
pub use provider_odb::{
    PendingTable, ProviderCacheOptions, ProviderKind, ProviderOdb, ProviderOptions,
    ProviderPayload, ProviderReplyValue, ProviderRequest, ProviderTransport, ReplySlot,
    PROVIDER_HEADER_SIZE_CEILING,
};
pub use refs::{RefDb, RefPage, RefQuery, RefTarget};
pub use runtime::{
    BusyReason, Job, JobObserver, JobOutput, JobSpec, JobState, JobTask, OwnerKey, ReadManyOutput,
    Runtime, RuntimeConfig, RuntimeCounters, SubmitError, TestObserver,
};
pub use search::{
    search, SearchBinaryMode, SearchMatch, SearchMode, SearchOptions, SearchPage, SearchSubmatch,
    MAX_CONTEXT_LINES,
};
pub use snapshot::{open as open_snapshot, peel, PeelTarget, Snapshot};
pub use static_odb::StaticOdb;
pub use tree::{list_tree, QueryStats, TreeItem, TreeItemKind, TreeOptions, TreePage, TypeFilter};
pub use verify::verify;
