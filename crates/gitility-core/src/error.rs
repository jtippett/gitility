//! The normalized error contract.
//!
//! Codes mirror the stable set in `Gitility.Error` one-for-one; the NIF
//! layer maps them to atoms mechanically. Messages must already be
//! sanitized here — no backend configuration, credentials, or remote URLs
//! ever enter an `Error`.

use crate::object::Oid;
use std::fmt;

/// The stable error codes. Keep in exact sync with `Gitility.Error.codes/0`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum ErrorCode {
    InvalidArgument,
    InvalidOid,
    InvalidPath,
    InvalidCursor,
    UnsupportedHash,
    UnsupportedOperation,
    UnsupportedRegex,
    NotACommit,
    NotATree,
    NotABlob,
    RefNotFound,
    AmbiguousPrefix,
    MissingObject,
    ShallowBoundary,
    MalformedObject,
    MalformedRef,
    HashMismatch,
    PackChecksumMismatch,
    IndexChecksumMismatch,
    ObjectTooLarge,
    BudgetExceeded,
    ResultTooLarge,
    Timeout,
    AwaitTimeout,
    Cancelled,
    Busy,
    ProviderDown,
    ProviderTimeout,
    ProviderProtocolError,
    BackendError,
    RuntimeMismatch,
    InternalError,
}

impl ErrorCode {
    /// Every stable error code, in the same order as the public Elixir list.
    pub const fn all() -> &'static [Self] {
        &[
            Self::InvalidArgument,
            Self::InvalidOid,
            Self::InvalidPath,
            Self::InvalidCursor,
            Self::UnsupportedHash,
            Self::UnsupportedOperation,
            Self::UnsupportedRegex,
            Self::NotACommit,
            Self::NotATree,
            Self::NotABlob,
            Self::RefNotFound,
            Self::AmbiguousPrefix,
            Self::MissingObject,
            Self::ShallowBoundary,
            Self::MalformedObject,
            Self::MalformedRef,
            Self::HashMismatch,
            Self::PackChecksumMismatch,
            Self::IndexChecksumMismatch,
            Self::ObjectTooLarge,
            Self::BudgetExceeded,
            Self::ResultTooLarge,
            Self::Timeout,
            Self::AwaitTimeout,
            Self::Cancelled,
            Self::Busy,
            Self::ProviderDown,
            Self::ProviderTimeout,
            Self::ProviderProtocolError,
            Self::BackendError,
            Self::RuntimeMismatch,
            Self::InternalError,
        ]
    }

    /// The snake_case name used on the Elixir side.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::InvalidArgument => "invalid_argument",
            Self::InvalidOid => "invalid_oid",
            Self::InvalidPath => "invalid_path",
            Self::InvalidCursor => "invalid_cursor",
            Self::UnsupportedHash => "unsupported_hash",
            Self::UnsupportedOperation => "unsupported_operation",
            Self::UnsupportedRegex => "unsupported_regex",
            Self::NotACommit => "not_a_commit",
            Self::NotATree => "not_a_tree",
            Self::NotABlob => "not_a_blob",
            Self::RefNotFound => "ref_not_found",
            Self::AmbiguousPrefix => "ambiguous_prefix",
            Self::MissingObject => "missing_object",
            Self::ShallowBoundary => "shallow_boundary",
            Self::MalformedObject => "malformed_object",
            Self::MalformedRef => "malformed_ref",
            Self::HashMismatch => "hash_mismatch",
            Self::PackChecksumMismatch => "pack_checksum_mismatch",
            Self::IndexChecksumMismatch => "index_checksum_mismatch",
            Self::ObjectTooLarge => "object_too_large",
            Self::BudgetExceeded => "budget_exceeded",
            Self::ResultTooLarge => "result_too_large",
            Self::Timeout => "timeout",
            Self::AwaitTimeout => "await_timeout",
            Self::Cancelled => "cancelled",
            Self::Busy => "busy",
            Self::ProviderDown => "provider_down",
            Self::ProviderTimeout => "provider_timeout",
            Self::ProviderProtocolError => "provider_protocol_error",
            Self::BackendError => "backend_error",
            Self::RuntimeMismatch => "runtime_mismatch",
            Self::InternalError => "internal_error",
        }
    }
}

/// Log orders that can require an order-specific budget refusal.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ErrorOrder {
    Topological,
    Date,
}

impl ErrorOrder {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Topological => "topological",
            Self::Date => "date",
        }
    }
}

/// Repository metadata files that can be named in normalized failures.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ErrorFile {
    Shallow,
}

impl ErrorFile {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Shallow => "shallow",
        }
    }
}

/// A normalized failure. Construct via [`Error::new`] or the focused
/// helpers; `retryable` follows the same semantics as the Elixir struct.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    pub code: ErrorCode,
    pub message: String,
    pub retryable: bool,
    /// The stable name of the resource limit that caused this failure.
    pub limit: Option<&'static str>,
    /// The zero-based layer whose operation failed, when composed.
    pub layer: Option<u64>,
    /// The object that caused an object-specific failure, when applicable.
    pub object_oid: Option<Oid>,
    /// Log order associated with an order-specific refusal.
    pub order: Option<ErrorOrder>,
    /// Stable repository metadata filename associated with a parse failure.
    pub file: Option<ErrorFile>,
    /// A sanitized machine-readable reason for failures whose underlying
    /// engine provides useful diagnostics (currently safe-regex compilation).
    pub reason: Option<String>,
}

impl Error {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            retryable: false,
            limit: None,
            layer: None,
            object_oid: None,
            order: None,
            file: None,
            reason: None,
        }
    }

    pub fn retryable(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            retryable: true,
            limit: None,
            layer: None,
            object_oid: None,
            order: None,
            file: None,
            reason: None,
        }
    }

    /// Associates this failure with the stable name of an exceeded limit.
    pub fn with_limit(mut self, limit: &'static str) -> Self {
        self.limit = Some(limit);
        self
    }

    /// Associates a lower-store failure with its zero-based composition
    /// position so callers can distinguish which authoritative layer failed.
    pub fn with_layer(mut self, layer: usize) -> Self {
        self.layer = Some(layer as u64);
        self
    }

    /// Associates an object-specific failure with its exact object ID.
    pub fn with_oid(mut self, oid: Oid) -> Self {
        self.object_oid = Some(oid);
        self
    }

    /// Associates an object-specific failure unless a lower layer already
    /// supplied a more precise object ID.
    pub fn with_oid_if_none(mut self, oid: Oid) -> Self {
        self.object_oid.get_or_insert(oid);
        self
    }

    /// Associates an order-specific graph refusal.
    pub fn with_order(mut self, order: ErrorOrder) -> Self {
        self.order = Some(order);
        self
    }

    /// Names stable repository metadata involved in a parse failure.
    pub fn with_file(mut self, file: ErrorFile) -> Self {
        self.file = Some(file);
        self
    }

    /// Attaches a sanitized engine reason to this failure.
    pub fn with_reason(mut self, reason: impl Into<String>) -> Self {
        self.reason = Some(reason.into());
        self
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} ({})", self.message, self.code.as_str())
    }
}

impl std::error::Error for Error {}

#[cfg(test)]
mod tests {
    use super::ErrorCode;

    #[test]
    fn all_contains_every_variant_once() {
        let mut seen = [false; 32];

        for code in ErrorCode::all() {
            let index = match code {
                ErrorCode::InvalidArgument => 0,
                ErrorCode::InvalidOid => 1,
                ErrorCode::InvalidPath => 2,
                ErrorCode::InvalidCursor => 3,
                ErrorCode::UnsupportedHash => 4,
                ErrorCode::UnsupportedOperation => 5,
                ErrorCode::UnsupportedRegex => 6,
                ErrorCode::NotACommit => 7,
                ErrorCode::NotATree => 8,
                ErrorCode::NotABlob => 9,
                ErrorCode::RefNotFound => 10,
                ErrorCode::AmbiguousPrefix => 11,
                ErrorCode::MissingObject => 12,
                ErrorCode::ShallowBoundary => 13,
                ErrorCode::MalformedObject => 14,
                ErrorCode::MalformedRef => 15,
                ErrorCode::HashMismatch => 16,
                ErrorCode::PackChecksumMismatch => 17,
                ErrorCode::IndexChecksumMismatch => 18,
                ErrorCode::ObjectTooLarge => 19,
                ErrorCode::BudgetExceeded => 20,
                ErrorCode::ResultTooLarge => 21,
                ErrorCode::Timeout => 22,
                ErrorCode::AwaitTimeout => 23,
                ErrorCode::Cancelled => 24,
                ErrorCode::Busy => 25,
                ErrorCode::ProviderDown => 26,
                ErrorCode::ProviderTimeout => 27,
                ErrorCode::ProviderProtocolError => 28,
                ErrorCode::BackendError => 29,
                ErrorCode::RuntimeMismatch => 30,
                ErrorCode::InternalError => 31,
            };

            assert!(!seen[index], "duplicate error code: {code:?}");
            seen[index] = true;
        }

        assert!(seen.into_iter().all(|present| present));
    }
}
