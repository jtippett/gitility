//! Independent, hash-agnostic Git object verification.
//!
//! The engine is intentionally not involved here. Gitility hashes the exact
//! bytes Git addresses: `<type> <size>\0<payload>`.

use crate::error::{Error, ErrorCode};
use crate::object::{HashKind, ObjectKind, Oid};
use sha1_checked::CollisionResult;

/// Verifies that `oid` addresses `payload` as an object of `kind`.
///
/// Both SHA-1 and SHA-256 are supported. SHA-1 uses the maintained
/// `sha1-checked` collision detector with the same fail-on-collision
/// configuration as gitoxide and Git.
pub fn verify(oid: &Oid, kind: ObjectKind, payload: &[u8]) -> Result<(), Error> {
    let actual = object_id(oid.kind(), kind, payload)?;
    if actual != *oid {
        return Err(Error::new(
            ErrorCode::HashMismatch,
            format!(
                "object hash mismatch: expected {}, computed {}",
                oid.to_hex(),
                actual.to_hex()
            ),
        ));
    }
    Ok(())
}

pub(crate) fn object_id(
    hash_kind: HashKind,
    object_kind: ObjectKind,
    payload: &[u8],
) -> Result<Oid, Error> {
    let mut hasher = ContentHasher::new(hash_kind);
    hasher.update(object_kind.as_str().as_bytes());
    hasher.update(b" ");
    hasher.update(payload.len().to_string().as_bytes());
    hasher.update(b"\0");
    hasher.update(payload);
    hasher.finalize()
}

pub(crate) enum ContentHasher {
    Sha1(Box<sha1_checked::Sha1>),
    Sha256(sha2::Sha256),
}

impl ContentHasher {
    pub(crate) fn new(kind: HashKind) -> Self {
        match kind {
            HashKind::Sha1 => Self::Sha1(Box::new(
                sha1_checked::Builder::default().safe_hash(false).build(),
            )),
            HashKind::Sha256 => Self::Sha256(sha2::Sha256::default()),
        }
    }

    pub(crate) fn update(&mut self, bytes: &[u8]) {
        match self {
            Self::Sha1(hasher) => sha1_checked::Digest::update(hasher.as_mut(), bytes),
            Self::Sha256(hasher) => sha2::Digest::update(hasher, bytes),
        }
    }

    pub(crate) fn finalize(self) -> Result<Oid, Error> {
        match self {
            Self::Sha1(hasher) => match (*hasher).try_finalize() {
                CollisionResult::Ok(digest) => Oid::new(HashKind::Sha1, digest.as_slice()),
                CollisionResult::Mitigated(_) | CollisionResult::Collision(_) => Err(Error::new(
                    ErrorCode::HashMismatch,
                    "SHA-1 collision attack detected while hashing object data",
                )),
            },
            Self::Sha256(hasher) => {
                let digest = sha2::Digest::finalize(hasher);
                Oid::new(HashKind::Sha256, digest.as_slice())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verifies_known_empty_blob_vectors_for_both_hashes() {
        let sha1 = Oid::parse_hex("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
            .expect("known SHA-1 vector is valid");
        let sha256 =
            Oid::parse_hex("473a0f4c3be8a93681a267e3b1e9a7dcda1185436fe141f7749120a303721813")
                .expect("known SHA-256 vector is valid");

        verify(&sha1, ObjectKind::Blob, b"").expect("SHA-1 vector verifies");
        verify(&sha256, ObjectKind::Blob, b"").expect("SHA-256 vector verifies");
    }

    #[test]
    fn rejects_mismatched_payload_without_echoing_it() {
        let oid = Oid::parse_hex("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
            .expect("known SHA-1 vector is valid");
        let err = verify(&oid, ObjectKind::Blob, b"secret payload")
            .expect_err("tampering must be rejected");
        assert_eq!(err.code, ErrorCode::HashMismatch);
        assert!(err.message.contains(&oid.to_hex()));
        assert!(!err.message.contains("secret payload"));
    }

    #[test]
    fn the_object_kind_is_part_of_the_hash() {
        let oid = Oid::parse_hex("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
            .expect("known SHA-1 vector is valid");
        assert_eq!(
            verify(&oid, ObjectKind::Tree, b"")
                .expect_err("kind mismatch must be rejected")
                .code,
            ErrorCode::HashMismatch
        );
    }
}
