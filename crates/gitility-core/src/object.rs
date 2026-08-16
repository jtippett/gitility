//! Object identity and header DTOs — hash-agnostic from day one.

use crate::error::{Error, ErrorCode};
use std::fmt;

/// A Git object hash algorithm. Everything that *represents* an ID
/// supports both; query *execution* refuses SHA-256 cleanly until the
/// engine supports it (design R1).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum HashKind {
    Sha1,
    Sha256,
}

impl HashKind {
    pub const fn digest_len(self) -> usize {
        match self {
            Self::Sha1 => 20,
            Self::Sha256 => 32,
        }
    }
}

/// The longest supported digest, used for inline OID storage.
const MAX_DIGEST_LEN: usize = 32;

/// A typed object ID: algorithm plus digest bytes, stored inline
/// (no allocation — OIDs are copied pervasively).
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Oid {
    kind: HashKind,
    bytes: [u8; MAX_DIGEST_LEN],
}

impl Oid {
    /// Builds an OID from raw digest bytes of exactly the algorithm's
    /// digest length.
    pub fn new(kind: HashKind, digest: &[u8]) -> Result<Self, Error> {
        if digest.len() != kind.digest_len() {
            return Err(Error::new(
                ErrorCode::InvalidOid,
                format!(
                    "{:?} digest must be {} bytes, got {}",
                    kind,
                    kind.digest_len(),
                    digest.len()
                ),
            ));
        }
        let mut bytes = [0u8; MAX_DIGEST_LEN];
        bytes[..digest.len()].copy_from_slice(digest);
        Ok(Self { kind, bytes })
    }

    /// Parses a full lowercase-or-uppercase hex ID, inferring the
    /// algorithm from its length (40 → SHA-1, 64 → SHA-256).
    pub fn parse_hex(hex: &str) -> Result<Self, Error> {
        let kind = match hex.len() {
            40 => HashKind::Sha1,
            64 => HashKind::Sha256,
            _ => {
                return Err(Error::new(
                    ErrorCode::InvalidOid,
                    "expected a full 40- or 64-character hex object ID",
                ))
            }
        };
        let mut digest = [0u8; MAX_DIGEST_LEN];
        for (i, chunk) in hex.as_bytes().chunks_exact(2).enumerate() {
            let hi = hex_val(chunk[0])?;
            let lo = hex_val(chunk[1])?;
            digest[i] = (hi << 4) | lo;
        }
        Self::new(kind, &digest[..kind.digest_len()])
    }

    pub fn kind(&self) -> HashKind {
        self.kind
    }

    /// The digest bytes, exactly `kind().digest_len()` long.
    pub fn as_bytes(&self) -> &[u8] {
        &self.bytes[..self.kind.digest_len()]
    }

    /// Lowercase hex.
    pub fn to_hex(&self) -> String {
        let mut out = String::with_capacity(self.kind.digest_len() * 2);
        for byte in self.as_bytes() {
            out.push(char::from_digit((byte >> 4) as u32, 16).expect("nibble < 16"));
            out.push(char::from_digit((byte & 0xF) as u32, 16).expect("nibble < 16"));
        }
        out
    }
}

fn hex_val(c: u8) -> Result<u8, Error> {
    match c {
        b'0'..=b'9' => Ok(c - b'0'),
        b'a'..=b'f' => Ok(c - b'a' + 10),
        b'A'..=b'F' => Ok(c - b'A' + 10),
        _ => Err(Error::new(
            ErrorCode::InvalidOid,
            "object ID contains a non-hex character",
        )),
    }
}

impl fmt::Debug for Oid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Oid({:?}:{})", self.kind, self.to_hex())
    }
}

impl fmt::Display for Oid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.to_hex())
    }
}

/// The four Git object types.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ObjectKind {
    Commit,
    Tree,
    Blob,
    Tag,
}

impl ObjectKind {
    /// The type name as it appears in a Git object header.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Commit => "commit",
            Self::Tree => "tree",
            Self::Blob => "blob",
            Self::Tag => "tag",
        }
    }
}

/// An object's type and size, without its payload.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ObjectHeader {
    pub kind: ObjectKind,
    pub size: u64,
}

#[cfg(test)]
mod tests {
    use super::*;

    const SHA1_HEX: &str = "da39a3ee5e6b4b0d3255bfef95601890afd80709";

    #[test]
    fn parse_and_format_round_trip() {
        let oid = Oid::parse_hex(SHA1_HEX).unwrap();
        assert_eq!(oid.kind(), HashKind::Sha1);
        assert_eq!(oid.as_bytes().len(), 20);
        assert_eq!(oid.to_hex(), SHA1_HEX);
    }

    #[test]
    fn uppercase_hex_parses_to_lowercase() {
        let oid = Oid::parse_hex(&SHA1_HEX.to_uppercase()).unwrap();
        assert_eq!(oid.to_hex(), SHA1_HEX);
    }

    #[test]
    fn rejects_bad_lengths_and_non_hex() {
        assert!(Oid::parse_hex("da39a3ee").is_err());
        assert!(Oid::parse_hex(&"z".repeat(40)).is_err());
        assert!(Oid::new(HashKind::Sha1, &[0u8; 32]).is_err());
        assert!(Oid::new(HashKind::Sha256, &[0u8; 20]).is_err());
    }

    #[test]
    fn sha256_oids_are_distinct_from_sha1() {
        let sha1 = Oid::new(HashKind::Sha1, &[0u8; 20]).unwrap();
        let sha256 = Oid::new(HashKind::Sha256, &[0u8; 32]).unwrap();
        assert_ne!(sha1, sha256);
    }
}
