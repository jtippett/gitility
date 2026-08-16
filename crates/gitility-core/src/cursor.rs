//! Versioned, checksummed continuation cursors.
//!
//! This module encodes raw bytes. URL-safe base64 belongs to the NIF layer.

use crate::error::{Error, ErrorCode};
use crate::object::HashKind;

const VERSION: u8 = 0x01;
/// Maximum encoded cursor size accepted or produced by any operation.
pub const MAX_CURSOR_BYTES: usize = 4096;
const CRC_BYTES: usize = 4;

/// Frozen v1 operation tag for tree listings.
pub const OPERATION_LIST_TREE: u8 = 0x01;
/// Frozen v1 operation tag for content search.
pub const OPERATION_SEARCH: u8 = 0x02;
/// Frozen v1 operation tag for commit logs.
pub const OPERATION_LOG: u8 = 0x03;
/// Frozen v1 operation tag for path history.
pub const OPERATION_HISTORY: u8 = 0x04;
/// Frozen v1 operation tag for reference listings.
pub const OPERATION_REFS: u8 = 0x05;

/// The fixed query identity a cursor must carry.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CursorExpected<'a> {
    pub hash_kind: HashKind,
    pub snapshot_digest: &'a [u8],
    pub operation_tag: u8,
    pub option_fingerprint: u64,
}

/// A decoded v1 continuation cursor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cursor {
    pub hash_kind: HashKind,
    pub snapshot_digest: Vec<u8>,
    pub operation_tag: u8,
    pub option_fingerprint: u64,
    pub generation: Vec<u8>,
    pub position: Vec<u8>,
}

/// Encodes the frozen v1 cursor wire format.
///
/// Generation and position lengths larger than `u16::MAX` deliberately
/// produce a cursor that decode rejects instead of panicking or silently
/// truncating caller-controlled bytes. Internally constructed cursors must
/// provide a snapshot digest whose length matches `hash_kind`.
pub fn encode(cursor: &Cursor) -> Vec<u8> {
    let digest_len = cursor.hash_kind.digest_len();
    debug_assert_eq!(cursor.snapshot_digest.len(), digest_len);
    let mut out = Vec::with_capacity(
        15usize
            .saturating_add(digest_len)
            .saturating_add(cursor.generation.len())
            .saturating_add(cursor.position.len())
            .saturating_add(CRC_BYTES),
    );
    out.push(VERSION);
    out.push(hash_tag(cursor.hash_kind));
    out.extend_from_slice(&cursor.snapshot_digest);
    out.push(cursor.operation_tag);
    out.extend_from_slice(&cursor.option_fingerprint.to_le_bytes());
    out.extend_from_slice(
        &u16::try_from(cursor.generation.len())
            .unwrap_or(u16::MAX)
            .to_le_bytes(),
    );
    out.extend_from_slice(&cursor.generation);
    out.extend_from_slice(
        &u16::try_from(cursor.position.len())
            .unwrap_or(u16::MAX)
            .to_le_bytes(),
    );
    out.extend_from_slice(&cursor.position);
    out.extend_from_slice(&crc32(&out).to_le_bytes());
    out
}

/// Decodes a cursor, enforcing the frozen validation order.
pub fn decode(bytes: &[u8], expected: CursorExpected<'_>) -> Result<Cursor, Error> {
    if bytes.len() > MAX_CURSOR_BYTES {
        return Err(invalid("length check failed: cursor exceeds 4096 bytes"));
    }

    let body_len = bytes
        .len()
        .checked_sub(CRC_BYTES)
        .ok_or_else(|| invalid("CRC check failed: cursor is too short"))?;
    let body = &bytes[..body_len];
    let encoded_crc = read_u32_le(&bytes[body_len..])
        .ok_or_else(|| invalid("CRC check failed: cursor checksum is truncated"))?;
    if crc32(body) != encoded_crc {
        return Err(invalid("CRC check failed: cursor checksum does not match"));
    }

    if body.first().copied() != Some(VERSION) {
        return Err(invalid("version check failed: unsupported cursor version"));
    }
    if body.get(1).copied() != Some(hash_tag(expected.hash_kind)) {
        return Err(invalid("hash kind check failed"));
    }

    let digest_len = expected.hash_kind.digest_len();
    if expected.snapshot_digest.len() != digest_len {
        return Err(invalid(
            "snapshot digest check failed: expected digest is invalid",
        ));
    }
    let mut offset = 2usize;
    let digest = take(body, &mut offset, digest_len)
        .ok_or_else(|| invalid("snapshot digest check failed: cursor is truncated"))?;
    if digest != expected.snapshot_digest {
        return Err(invalid("snapshot digest check failed"));
    }

    let operation_tag = take(body, &mut offset, 1)
        .and_then(|value| value.first().copied())
        .ok_or_else(|| invalid("operation tag check failed: cursor is truncated"))?;
    if operation_tag != expected.operation_tag {
        return Err(invalid("operation tag check failed"));
    }

    let fingerprint = take(body, &mut offset, 8)
        .and_then(read_u64_le)
        .ok_or_else(|| invalid("option fingerprint check failed: cursor is truncated"))?;
    if fingerprint != expected.option_fingerprint {
        return Err(invalid("option fingerprint check failed"));
    }

    let generation_len = take(body, &mut offset, 2)
        .and_then(read_u16_le)
        .map(usize::from)
        .ok_or_else(|| invalid("generation length check failed"))?;
    let generation = take(body, &mut offset, generation_len)
        .ok_or_else(|| invalid("generation length check failed"))?
        .to_vec();
    let position_len = take(body, &mut offset, 2)
        .and_then(read_u16_le)
        .map(usize::from)
        .ok_or_else(|| invalid("position length check failed"))?;
    let position = take(body, &mut offset, position_len)
        .ok_or_else(|| invalid("position length check failed"))?
        .to_vec();
    if offset != body.len() {
        return Err(invalid("trailing data check failed"));
    }

    Ok(Cursor {
        hash_kind: expected.hash_kind,
        snapshot_digest: digest.to_vec(),
        operation_tag,
        option_fingerprint: fingerprint,
        generation,
        position,
    })
}

/// Computes the FNV-1a 64-bit fingerprint used by cursor v1.
pub fn fnv1a_64(bytes: &[u8]) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325u64;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

fn hash_tag(kind: HashKind) -> u8 {
    match kind {
        HashKind::Sha1 => 0x01,
        HashKind::Sha256 => 0x02,
    }
}

fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = u32::MAX;
    for byte in bytes {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            let mask = 0u32.wrapping_sub(crc & 1);
            crc = (crc >> 1) ^ (0xedb8_8320 & mask);
        }
    }
    !crc
}

fn take<'a>(bytes: &'a [u8], offset: &mut usize, len: usize) -> Option<&'a [u8]> {
    let end = offset.checked_add(len)?;
    let value = bytes.get(*offset..end)?;
    *offset = end;
    Some(value)
}

fn read_u16_le(bytes: &[u8]) -> Option<u16> {
    Some(u16::from_le_bytes(bytes.try_into().ok()?))
}

fn read_u32_le(bytes: &[u8]) -> Option<u32> {
    Some(u32::from_le_bytes(bytes.try_into().ok()?))
}

fn read_u64_le(bytes: &[u8]) -> Option<u64> {
    Some(u64::from_le_bytes(bytes.try_into().ok()?))
}

fn invalid(message: &'static str) -> Error {
    Error::new(ErrorCode::InvalidCursor, message)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Cursor {
        Cursor {
            hash_kind: HashKind::Sha1,
            snapshot_digest: (0..20).collect(),
            operation_tag: 0x01,
            option_fingerprint: 0x0123_4567_89ab_cdef,
            generation: b"pack-generation".to_vec(),
            position: b"src/lib.rs".to_vec(),
        }
    }

    fn expected(cursor: &Cursor) -> CursorExpected<'_> {
        CursorExpected {
            hash_kind: cursor.hash_kind,
            snapshot_digest: &cursor.snapshot_digest,
            operation_tag: cursor.operation_tag,
            option_fingerprint: cursor.option_fingerprint,
        }
    }

    #[test]
    fn round_trips_both_digest_widths_and_empty_tlvs() {
        for mut cursor in [
            sample(),
            Cursor {
                hash_kind: HashKind::Sha256,
                snapshot_digest: (0..32).collect(),
                operation_tag: 0x05,
                option_fingerprint: 0,
                generation: Vec::new(),
                position: Vec::new(),
            },
        ] {
            let encoded = encode(&cursor);
            assert_eq!(
                decode(&encoded, expected(&cursor)).expect("cursor decodes"),
                cursor
            );
            cursor.position.push(1);
        }
    }

    #[test]
    fn encoding_matches_the_frozen_v1_byte_vector() {
        let expected = [
            0x01, 0x01, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b,
            0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x01, 0xef, 0xcd, 0xab, 0x89, 0x67,
            0x45, 0x23, 0x01, 0x0f, 0x00, b'p', b'a', b'c', b'k', b'-', b'g', b'e', b'n', b'e',
            b'r', b'a', b't', b'i', b'o', b'n', 0x0a, 0x00, b's', b'r', b'c', b'/', b'l', b'i',
            b'b', b'.', b'r', b's', 0x5d, 0xd3, 0x97, 0x31,
        ];
        assert_eq!(encode(&sample()), expected);
    }

    #[test]
    fn every_single_byte_corruption_is_rejected() {
        let cursor = sample();
        let valid = encode(&cursor);
        for index in 0..valid.len() {
            let mut corrupt = valid.clone();
            corrupt[index] ^= 0x01;
            let err =
                decode(&corrupt, expected(&cursor)).expect_err("one-byte corruption must fail");
            assert_eq!(err.code, ErrorCode::InvalidCursor, "byte {index}");
        }
    }

    #[test]
    fn rejects_wrong_snapshot_operation_and_fingerprint() {
        let cursor = sample();
        let encoded = encode(&cursor);
        let mut wrong_digest = cursor.snapshot_digest.clone();
        wrong_digest[0] ^= 1;
        for expected in [
            CursorExpected {
                snapshot_digest: &wrong_digest,
                ..expected(&cursor)
            },
            CursorExpected {
                operation_tag: 2,
                ..expected(&cursor)
            },
            CursorExpected {
                option_fingerprint: cursor.option_fingerprint + 1,
                ..expected(&cursor)
            },
        ] {
            assert_eq!(
                decode(&encoded, expected)
                    .expect_err("identity mismatch must fail")
                    .code,
                ErrorCode::InvalidCursor
            );
        }
    }

    #[test]
    fn enforces_length_before_checksum_and_checksum_before_version() {
        let too_long = vec![0; MAX_CURSOR_BYTES + 1];
        let err = decode(
            &too_long,
            CursorExpected {
                hash_kind: HashKind::Sha1,
                snapshot_digest: &[0; 20],
                operation_tag: 1,
                option_fingerprint: 0,
            },
        )
        .expect_err("oversized cursor fails");
        assert!(err.message.contains("length"));

        let mut cursor = sample();
        let mut encoded = encode(&cursor);
        encoded[0] = 2;
        assert!(decode(&encoded, expected(&cursor))
            .expect_err("bad CRC masks bad version")
            .message
            .contains("CRC"));
        let body_len = encoded.len() - CRC_BYTES;
        let checksum = crc32(&encoded[..body_len]).to_le_bytes();
        encoded[body_len..].copy_from_slice(&checksum);
        assert!(decode(&encoded, expected(&cursor))
            .expect_err("valid CRC exposes bad version")
            .message
            .contains("version"));
        cursor.generation.clear();
    }

    #[test]
    fn fnv_matches_the_published_vector() {
        assert_eq!(fnv1a_64(b"hello"), 0xa430_d846_80aa_bd0b);
    }
}
