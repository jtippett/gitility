//! The normalized error contract.
//!
//! Codes mirror the stable set in `Gitility.Error` one-for-one; the NIF
//! layer maps them to atoms mechanically. Messages must already be
//! sanitized here — no backend configuration, credentials, or remote URLs
//! ever enter an `Error`.

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

/// A normalized failure. Construct via [`Error::new`] or the focused
/// helpers; `retryable` follows the same semantics as the Elixir struct.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    pub code: ErrorCode,
    pub message: String,
    pub retryable: bool,
    /// The stable name of the resource limit that caused this failure.
    pub limit: Option<&'static str>,
}

impl Error {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            retryable: false,
            limit: None,
        }
    }

    pub fn retryable(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            retryable: true,
            limit: None,
        }
    }

    /// Associates this failure with the stable name of an exceeded limit.
    pub fn with_limit(mut self, limit: &'static str) -> Self {
        self.limit = Some(limit);
        self
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} ({})", self.message, self.code.as_str())
    }
}

impl std::error::Error for Error {}
