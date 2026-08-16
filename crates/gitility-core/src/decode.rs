//! Engine-adapted decoding into Gitility-owned object DTOs.
//!
//! Parsing is byte-oriented. No identity, message, tag name, or tree entry
//! name is required to be UTF-8.

use crate::error::{Error, ErrorCode};
use crate::object::{HashKind, ObjectKind, Oid};

/// A commit author, committer, or tagger exactly as Git encoded it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Identity {
    /// Raw name bytes with all trailing ASCII whitespace removed, matching
    /// Git's identity splitting policy.
    pub name: Vec<u8>,
    /// Raw email bytes, without angle brackets.
    pub email: Vec<u8>,
    /// Seconds since the Unix epoch.
    pub time: i64,
    /// Raw timezone bytes, preserving encodings such as `-0000`.
    pub tz: Vec<u8>,
}

/// A decoded commit whose variable-width fields remain raw bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Commit {
    /// Root tree recorded by the commit.
    pub tree_oid: Oid,
    /// Parent commits in encoded order.
    pub parents: Vec<Oid>,
    /// The author identity.
    pub author: Identity,
    /// The committer identity.
    pub committer: Identity,
    /// The complete raw commit message.
    pub message: Vec<u8>,
    /// Signature-bearing headers, in encoded order within that group.
    pub signature_headers: Vec<(Vec<u8>, Vec<u8>)>,
    /// All non-signature extension headers. Continuation lines are joined with
    /// newlines after Git's continuation indentation is removed; values are
    /// therefore semantic header values, not raw header bytes.
    pub extra_headers: Vec<(Vec<u8>, Vec<u8>)>,
}

/// A decoded annotated tag.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tag {
    /// Object named by the tag.
    pub target_oid: Oid,
    /// Declared kind of the target object.
    pub target_kind: ObjectKind,
    /// Optional tagger identity.
    pub tagger: Option<Identity>,
    /// Raw tag name bytes.
    pub name: Vec<u8>,
    /// Complete raw tag message, including an embedded signature if present.
    pub message: Vec<u8>,
}

/// One borrowed entry from a raw tree payload.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TreeEntry<'a> {
    /// Git file mode as an integer.
    pub mode: u32,
    /// Raw entry name borrowed from the tree payload.
    pub name: &'a [u8],
    /// Addressed object.
    pub oid: Oid,
}

/// A zero-copy iterator over entries in Git's on-disk tree order.
///
/// Iteration is budget-free; the M1b query layer charges each emitted entry.
pub struct TreeIter<'a> {
    inner: gix_object::TreeRefIter<'a>,
    payload: &'a [u8],
    failed: bool,
}

impl std::fmt::Debug for TreeIter<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TreeIter").finish_non_exhaustive()
    }
}

impl<'a> Iterator for TreeIter<'a> {
    type Item = Result<TreeEntry<'a>, Error>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.failed {
            return None;
        }
        let offset = self.inner.offset_to_next_entry(self.payload);
        let remaining = &self.payload[offset..];
        if !remaining.is_empty() {
            let valid_mode = remaining
                .iter()
                .position(|byte| *byte == b' ')
                .map(|end| {
                    let mode = &remaining[..end];
                    !mode.is_empty() && mode.len() <= 6 && mode.iter().any(|byte| *byte != b'0')
                })
                .unwrap_or(false);
            if !valid_mode {
                self.failed = true;
                return Some(Err(malformed("tree entry mode is malformed")));
            }
        }
        self.inner.next().map(|entry| {
            let entry = entry.map_err(|_| malformed("tree payload is malformed"))?;
            let oid = Oid::new(from_gix_hash(entry.oid.kind())?, entry.oid.as_bytes())
                .map_err(|_| malformed("tree entry object ID is malformed"))?;
            Ok(TreeEntry {
                mode: u32::from(entry.mode.value()),
                name: entry.filename.as_ref(),
                oid,
            })
        })
    }
}

/// Decodes a commit payload using `hash_kind` for every embedded object ID.
pub fn decode_commit(payload: &[u8], hash_kind: HashKind) -> Result<Commit, Error> {
    let parsed = gix_object::CommitRef::from_bytes(payload, to_gix_hash(hash_kind))
        .map_err(|_| malformed("commit payload is malformed"))?;

    let tree_oid = parse_embedded_oid(parsed.tree.as_ref(), hash_kind, "commit tree")?;
    let parents = parsed
        .parents
        .iter()
        .map(|parent| parse_embedded_oid(parent.as_ref(), hash_kind, "commit parent"))
        .collect::<Result<Vec<_>, _>>()?;
    let author = decode_identity(parsed.author.as_ref())?;
    let committer = decode_identity(parsed.committer.as_ref())?;

    let mut signature_headers = Vec::new();
    let mut extra_headers = Vec::new();
    if let Some(encoding) = parsed.encoding {
        extra_headers.push((b"encoding".to_vec(), encoding.to_vec()));
    }
    for (name, value) in parsed.extra_headers {
        let header = (name.to_vec(), value.to_vec());
        if is_signature_header(name) {
            signature_headers.push(header);
        } else {
            extra_headers.push(header);
        }
    }

    Ok(Commit {
        tree_oid,
        parents,
        author,
        committer,
        message: parsed.message.to_vec(),
        signature_headers,
        extra_headers,
    })
}

/// Decodes an annotated tag payload using `hash_kind` for its target ID.
pub fn decode_tag(payload: &[u8], hash_kind: HashKind) -> Result<Tag, Error> {
    let parsed = gix_object::TagRef::from_bytes(payload, to_gix_hash(hash_kind))
        .map_err(|_| malformed("tag payload is malformed"))?;
    let target_oid = parse_embedded_oid(parsed.target.as_ref(), hash_kind, "tag target")?;
    let tagger = parsed
        .tagger
        .map(|raw| decode_identity(raw.as_ref()))
        .transpose()?;
    let message = payload
        .windows(2)
        .position(|window| window == b"\n\n")
        .map(|separator| payload[separator + 2..].to_vec())
        .unwrap_or_default();

    Ok(Tag {
        target_oid,
        target_kind: from_gix_kind(parsed.target_kind),
        tagger,
        name: parsed.name.to_vec(),
        message,
    })
}

/// Begins decoding a tree payload in its existing on-disk order.
///
/// Malformation is reported by the yielded item at the point it is observed.
pub fn decode_tree(payload: &[u8], hash_kind: HashKind) -> TreeIter<'_> {
    TreeIter {
        inner: gix_object::TreeRefIter::from_bytes(payload, to_gix_hash(hash_kind)),
        payload,
        failed: false,
    }
}

pub(crate) fn decode_identity(raw: &[u8]) -> Result<Identity, Error> {
    let left = raw
        .iter()
        .position(|byte| *byte == b'<')
        .ok_or_else(|| malformed("identity is missing an opening angle bracket"))?;
    let right = raw[left + 1..]
        .iter()
        .position(|byte| *byte == b'>')
        .map(|offset| left + 1 + offset)
        .ok_or_else(|| malformed("identity is missing a closing angle bracket"))?;
    let name_end = raw[..left]
        .iter()
        .rposition(|byte| !byte.is_ascii_whitespace())
        .map_or(0, |position| position + 1);
    let suffix = raw
        .get(right + 1..)
        .and_then(|rest| rest.strip_prefix(b" "))
        .ok_or_else(|| malformed("identity is missing its timestamp"))?;
    let time_separator = suffix
        .iter()
        .position(|byte| *byte == b' ')
        .ok_or_else(|| malformed("identity is missing its timezone"))?;
    let time_bytes = &suffix[..time_separator];
    let tz = &suffix[time_separator + 1..];
    if time_bytes.is_empty() || tz.is_empty() || tz.contains(&b' ') || tz.contains(&b'\t') {
        return Err(malformed("identity timestamp or timezone is malformed"));
    }
    let time = std::str::from_utf8(time_bytes)
        .ok()
        .and_then(|value| value.parse::<i64>().ok())
        .ok_or_else(|| malformed("identity timestamp is malformed"))?;

    Ok(Identity {
        name: raw[..name_end].to_vec(),
        email: raw[left + 1..right].to_vec(),
        time,
        tz: tz.to_vec(),
    })
}

fn parse_embedded_oid(raw: &[u8], kind: HashKind, field: &str) -> Result<Oid, Error> {
    if raw.len() != kind.digest_len() * 2 {
        return Err(malformed(&format!("{field} object ID is malformed")));
    }
    let hex = std::str::from_utf8(raw)
        .map_err(|_| malformed(&format!("{field} object ID is malformed")))?;
    let oid =
        Oid::parse_hex(hex).map_err(|_| malformed(&format!("{field} object ID is malformed")))?;
    if oid.kind() != kind {
        return Err(malformed(&format!(
            "{field} object ID uses the wrong hash algorithm"
        )));
    }
    Ok(oid)
}

fn is_signature_header(name: &[u8]) -> bool {
    name == b"gpgsig" || name.starts_with(b"gpgsig-")
}

fn malformed(message: &str) -> Error {
    Error::new(ErrorCode::MalformedObject, message)
}

fn to_gix_hash(kind: HashKind) -> gix_hash::Kind {
    match kind {
        HashKind::Sha1 => gix_hash::Kind::Sha1,
        HashKind::Sha256 => gix_hash::Kind::Sha256,
    }
}

fn from_gix_kind(kind: gix_object::Kind) -> ObjectKind {
    match kind {
        gix_object::Kind::Commit => ObjectKind::Commit,
        gix_object::Kind::Tree => ObjectKind::Tree,
        gix_object::Kind::Blob => ObjectKind::Blob,
        gix_object::Kind::Tag => ObjectKind::Tag,
    }
}

fn from_gix_hash(kind: gix_hash::Kind) -> Result<HashKind, Error> {
    match kind {
        gix_hash::Kind::Sha1 => Ok(HashKind::Sha1),
        gix_hash::Kind::Sha256 => Ok(HashKind::Sha256),
        _ => Err(malformed("tree entry uses an unsupported hash algorithm")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::budget::Budget;
    use crate::local_odb::LocalOdb;
    use crate::odb::ObjectDb;
    use crate::test_support::{fixture_oid, fixture_repo, read_ref_oid};

    #[test]
    fn decodes_real_commit_tree_and_tag_bytes() {
        let repo = fixture_repo("sha1-basic.git");
        let (store, layout) =
            LocalOdb::open(&repo, Default::default()).expect("fixture repository opens");
        assert_eq!(layout.object_hash, HashKind::Sha1);
        let budget = Budget::unlimited();
        let head = fixture_oid("sha1_basic_head");
        let mut payload = Vec::new();

        assert_eq!(
            store
                .try_find(&head, &mut payload, &budget)
                .expect("commit reads"),
            Some(ObjectKind::Commit)
        );
        let commit = decode_commit(&payload, HashKind::Sha1).expect("commit decodes");
        assert_eq!(
            commit.tree_oid.to_hex(),
            "4e686e595053a20fae26585a3eba16e159c0a9b5"
        );
        assert_eq!(commit.parents.len(), 1);
        assert_eq!(commit.author.name, b"Gitility Fixture");
        assert_eq!(commit.author.email, b"fixtures@gitility.invalid");
        assert_eq!(commit.author.time, 978_307_320);
        assert_eq!(commit.author.tz, b"+0000");
        assert_eq!(commit.committer, commit.author);
        assert_eq!(commit.message, b"Add an empty tree and gitlink\n");
        assert!(commit.signature_headers.is_empty());
        assert!(commit.extra_headers.is_empty());

        store
            .try_find(&commit.tree_oid, &mut payload, &budget)
            .expect("tree reads")
            .expect("tree exists");
        let entries = decode_tree(&payload, HashKind::Sha1)
            .collect::<Result<Vec<_>, _>>()
            .expect("tree decodes");
        let invalid = entries
            .iter()
            .find(|entry| entry.name.starts_with(b"invalid-"))
            .expect("invalid UTF-8 entry is present");
        assert_eq!(invalid.name, b"invalid-\xff-name.txt");
        assert_eq!(invalid.mode, 0o100644);

        let tag_oid = read_ref_oid(&repo, "refs/tags/v1.0.0");
        assert_eq!(
            store
                .try_find(&tag_oid, &mut payload, &budget)
                .expect("tag reads"),
            Some(ObjectKind::Tag)
        );
        let tag = decode_tag(&payload, HashKind::Sha1).expect("tag decodes");
        assert_eq!(tag.target_oid, head);
        assert_eq!(tag.target_kind, ObjectKind::Commit);
        assert_eq!(tag.name, b"v1.0.0");
        assert_eq!(tag.message, b"Fixture tag v1.0.0\n");
        let tagger = tag.tagger.expect("fixture tag has a tagger");
        assert_eq!(tagger.name, b"Gitility Fixture");
        assert_eq!(tagger.email, b"fixtures@gitility.invalid");
        assert_eq!(tagger.time, 978_307_380);
        assert_eq!(tagger.tz, b"+0000");
    }

    #[test]
    fn preserves_negative_zero_raw_bytes_and_extension_headers() {
        let payload = b"tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\nauthor raw-\xff <mail-\xfe@example.invalid> 1 -0000\ncommitter Committer <c@example.invalid> 2 +0015\nencoding ISO-8859-1\ngpgsig first line\n second line\nx-extra raw bytes\n\nmessage-\xff\n";
        let commit = decode_commit(payload, HashKind::Sha1).expect("commit decodes");
        assert_eq!(commit.author.name, b"raw-\xff");
        assert_eq!(commit.author.email, b"mail-\xfe@example.invalid");
        assert_eq!(commit.author.tz, b"-0000");
        assert_eq!(commit.message, b"message-\xff\n");
        assert_eq!(
            commit.signature_headers,
            vec![(b"gpgsig".to_vec(), b"first line\nsecond line\n".to_vec())]
        );
        assert_eq!(
            commit.extra_headers,
            vec![
                (b"encoding".to_vec(), b"ISO-8859-1".to_vec()),
                (b"x-extra".to_vec(), b"raw bytes".to_vec())
            ]
        );
    }

    #[test]
    fn malformed_inputs_return_normalized_errors() {
        for err in [
            decode_commit(b"tree 123", HashKind::Sha1).expect_err("truncated commit fails"),
            decode_tag(b"garbage", HashKind::Sha1).expect_err("garbage tag fails"),
        ] {
            assert_eq!(err.code, ErrorCode::MalformedObject);
        }

        let err = decode_tree(b"garbage", HashKind::Sha1)
            .next()
            .expect("garbage yields one error")
            .expect_err("garbage tree fails");
        assert_eq!(err.code, ErrorCode::MalformedObject);
    }

    #[test]
    fn tag_headers_without_a_message_decode_with_an_empty_message() {
        let payload = b"object e69de29bb2d1d6434b8b29ae775ad8c2e48c5391\ntype blob\ntag empty-message\ntagger Tagger <tagger@example.invalid> 1 +0000\n";
        let tag =
            decode_tag(payload, HashKind::Sha1).expect("fsck-clean empty-message tag decodes");
        assert!(tag.message.is_empty());
        assert_eq!(tag.name, b"empty-message");
        assert!(tag.tagger.is_some());
    }

    #[test]
    fn identity_splitting_matches_git_for_nested_angles_and_name_trimming() {
        let opening_inside = decode_identity(b"First <<first@example.invalid> 1 +0000")
            .expect("identity with a second opening angle decodes");
        assert_eq!(opening_inside.email, b"<first@example.invalid");

        let opening_at_end = decode_identity(b"Second <second@example.invalid<> 2 -0000")
            .expect("identity with an opening angle before the close decodes");
        assert_eq!(opening_at_end.email, b"second@example.invalid<");

        let spaced = decode_identity(b"Name with space   \t <mail@example.invalid> 3 +0015")
            .expect("identity with trailing name whitespace decodes");
        assert_eq!(spaced.name, b"Name with space");
    }

    #[test]
    fn rejects_zero_and_leading_space_tree_modes_but_normalizes_tree_modes() {
        fn tree_entry(mode_and_name: &[u8]) -> Vec<u8> {
            let mut payload = mode_and_name.to_vec();
            payload.push(0);
            payload.extend_from_slice(&[1; 20]);
            payload
        }

        for payload in [tree_entry(b"0000000 zero"), tree_entry(b" 100644 absorbed")] {
            let err = decode_tree(&payload, HashKind::Sha1)
                .next()
                .expect("malformed entry yields an error")
                .expect_err("invalid mode is rejected");
            assert_eq!(err.code, ErrorCode::MalformedObject);
        }

        for mode in [b"40000 tree".as_slice(), b"040000 tree".as_slice()] {
            let payload = tree_entry(mode);
            let entry = decode_tree(&payload, HashKind::Sha1)
                .next()
                .expect("tree entry exists")
                .expect("accepted tree mode decodes");
            assert_eq!(entry.mode, 0o40000);
            assert_eq!(entry.name, b"tree");
        }
    }
}
