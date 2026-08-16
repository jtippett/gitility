//! Bounded, byte-oriented file reads from snapshots.

use crate::budget::Budget;
use crate::error::{Error, ErrorCode};
use crate::object::{ObjectKind, Oid};
use crate::odb::ObjectDb;
use crate::snapshot::Snapshot;
use crate::tree::{ensure_query_compatible, resolve_path, QueryStats, ResolvedPath, TreeItemKind};

const BINARY_PROBE_BYTES: usize = 8_000;

/// Options for [`read_file`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FileOptions {
    /// A 1-based inclusive line range.
    pub lines: Option<(u32, u32)>,
    /// Maximum payload bytes semantically scanned and returned.
    pub max_bytes: usize,
}

impl Default for FileOptions {
    fn default() -> Self {
        Self {
            lines: None,
            max_bytes: 256_000,
        }
    }
}

/// Content classification under Gitility's configured default policy.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FileKind {
    Text,
    Binary,
    Symlink,
    Gitlink,
}

/// Metadata parsed from a well-formed Git LFS pointer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LfsPointer {
    pub oid: String,
    pub size: u64,
}

/// A file read result whose path and payload remain raw bytes.
///
/// `truncated: true`, `total_lines: None`, and
/// `stats.stopped_by: Some("max_bytes")` together mean the byte cap prevented
/// reaching or completing the requested content. A completed line range is
/// not truncated even when `total_lines` remains unknown because the rest of
/// the blob was not scanned.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileRead {
    pub path: Vec<u8>,
    pub blob_oid: Oid,
    pub mode: u32,
    pub kind: FileKind,
    pub data: Vec<u8>,
    pub start_line: Option<u32>,
    pub end_line: Option<u32>,
    pub total_lines: Option<u32>,
    pub truncated: bool,
    pub lfs_pointer: Option<LfsPointer>,
    pub stats: QueryStats,
}

/// Reads one non-tree path without following symlinks or gitlinks.
///
/// Current local and static ODB implementations inflate whole objects. Their
/// `try_find` implementations therefore charge the blob's full inflated size
/// even when `max_bytes` makes the semantic read expose only a prefix.
pub fn read_file(
    store: &dyn ObjectDb,
    snapshot: &Snapshot,
    path: &[u8],
    opts: &FileOptions,
    budget: &Budget,
) -> Result<FileRead, Error> {
    ensure_query_compatible(store, snapshot)?;
    if let Some((start, end)) = opts.lines {
        if start == 0 || end == 0 || start > end {
            return Err(Error::new(
                ErrorCode::InvalidArgument,
                "line range must be 1-based and ordered",
            ));
        }
    }

    let resolved = resolve_path(store, snapshot, path, budget)?;
    let entry = match resolved {
        ResolvedPath::RootTree(_) => {
            return Err(Error::new(
                ErrorCode::NotABlob,
                "path resolves to a tree, not a blob",
            ))
        }
        ResolvedPath::Entry(entry) if entry.kind == TreeItemKind::Tree => {
            return Err(Error::new(
                ErrorCode::NotABlob,
                "path resolves to a tree, not a blob",
            ))
        }
        ResolvedPath::Entry(entry) => entry,
    };

    if entry.kind == TreeItemKind::Gitlink {
        let (objects_read, bytes_read, _, _) = budget.spent();
        let (cache_hits, cache_misses) = budget.cache_spent();
        let cache_stats = store.cache_stats();
        return Ok(FileRead {
            path: path.to_vec(),
            blob_oid: entry.oid,
            mode: entry.mode,
            kind: FileKind::Gitlink,
            data: Vec::new(),
            start_line: None,
            end_line: None,
            total_lines: None,
            truncated: false,
            lfs_pointer: None,
            stats: QueryStats {
                objects_read,
                bytes_read,
                entries_emitted: 0,
                cache_hits,
                cache_misses,
                cache_bytes: cache_stats.bytes,
                cache_entries: cache_stats.entries,
                cache_evictions: cache_stats.evictions,
                files_scanned: 0,
                blobs_deduped: 0,
                binary_skipped: 0,
                oversize_skipped: 0,
                stopped_by: None,
            },
        });
    }

    let mut payload = Vec::new();
    let object_kind = store
        .try_find(&entry.oid, &mut payload, budget)?
        .ok_or_else(|| missing_blob(entry.oid))?;
    if object_kind != ObjectKind::Blob {
        return Err(Error::new(
            ErrorCode::NotABlob,
            format!("file object {} is not a blob", entry.oid),
        ));
    }

    // Configured default: a NUL in the first 8000 bytes is binary; without
    // that marker the complete payload must be valid UTF-8 to be text.
    let kind = if entry.kind == TreeItemKind::Symlink {
        FileKind::Symlink
    } else if payload[..payload.len().min(BINARY_PROBE_BYTES)].contains(&0)
        || std::str::from_utf8(&payload).is_err()
    {
        FileKind::Binary
    } else {
        FileKind::Text
    };
    let lfs_pointer = parse_lfs_pointer(&payload);
    let sliced = slice_payload(&payload, opts)?;
    let (objects_read, bytes_read, _, _) = budget.spent();
    let (cache_hits, cache_misses) = budget.cache_spent();
    let cache_stats = store.cache_stats();
    Ok(FileRead {
        path: path.to_vec(),
        blob_oid: entry.oid,
        mode: entry.mode,
        kind,
        data: sliced.data,
        start_line: sliced.start_line,
        end_line: sliced.end_line,
        total_lines: sliced.total_lines,
        truncated: sliced.truncated,
        lfs_pointer,
        stats: QueryStats {
            objects_read,
            bytes_read,
            entries_emitted: 0,
            cache_hits,
            cache_misses,
            cache_bytes: cache_stats.bytes,
            cache_entries: cache_stats.entries,
            cache_evictions: cache_stats.evictions,
            files_scanned: 0,
            blobs_deduped: 0,
            binary_skipped: 0,
            oversize_skipped: 0,
            stopped_by: sliced.stopped_by,
        },
    })
}

struct SlicedPayload {
    data: Vec<u8>,
    start_line: Option<u32>,
    end_line: Option<u32>,
    total_lines: Option<u32>,
    truncated: bool,
    stopped_by: Option<&'static str>,
}

fn slice_payload(payload: &[u8], opts: &FileOptions) -> Result<SlicedPayload, Error> {
    let scan_len = payload.len().min(opts.max_bytes);
    let capped = scan_len < payload.len();
    if opts.lines.is_none() {
        let scanned = &payload[..scan_len];
        let returned_len = if capped && !scanned.is_empty() && !scanned.ends_with(b"\n") {
            match scanned.iter().rposition(|byte| *byte == b'\n') {
                Some(last_newline) => last_newline + 1,
                None => scanned.len(),
            }
        } else {
            scanned.len()
        };
        let total_lines = if capped {
            None
        } else {
            Some(line_count(payload)?)
        };
        return Ok(SlicedPayload {
            data: scanned[..returned_len].to_vec(),
            start_line: None,
            end_line: None,
            total_lines,
            truncated: capped,
            stopped_by: capped.then_some("max_bytes"),
        });
    }

    let Some((requested_start, requested_end)) = opts.lines else {
        return Err(Error::new(
            ErrorCode::InternalError,
            "line slicing state is unavailable",
        ));
    };
    if !capped {
        let spans = line_spans(payload);
        if spans.is_empty() {
            return Ok(SlicedPayload {
                data: Vec::new(),
                start_line: None,
                end_line: None,
                total_lines: Some(0),
                truncated: false,
                stopped_by: None,
            });
        }
        let total = u32::try_from(spans.len()).map_err(|_| too_many_lines())?;
        if requested_start > total {
            return Ok(SlicedPayload {
                data: Vec::new(),
                start_line: None,
                end_line: None,
                total_lines: Some(total),
                truncated: false,
                stopped_by: None,
            });
        }
        let start = requested_start;
        let end = requested_end.min(total);
        let first = spans[(start - 1) as usize].0;
        let last = spans[(end - 1) as usize].1;
        let data = payload[first..last].to_vec();
        return Ok(SlicedPayload {
            truncated: false,
            data,
            start_line: Some(start),
            end_line: Some(end),
            total_lines: Some(total),
            stopped_by: None,
        });
    }

    let scanned = &payload[..scan_len];
    let spans = line_spans(scanned);
    let last_is_partial = !scanned.is_empty() && !scanned.ends_with(b"\n");
    let complete_lines = spans.len().saturating_sub(usize::from(last_is_partial));
    let range_completed =
        usize::try_from(requested_end).is_ok_and(|requested_end| requested_end <= complete_lines);
    let mut data = Vec::new();
    let mut start_line = None;
    let mut end_line = None;
    for (index, (start, end)) in spans.iter().copied().enumerate() {
        let line = u32::try_from(index + 1).map_err(|_| too_many_lines())?;
        if line < requested_start || line > requested_end {
            continue;
        }
        let incomplete = last_is_partial && index + 1 == spans.len();
        if incomplete && start_line.is_some() {
            break;
        }
        data.extend_from_slice(&scanned[start..end]);
        start_line.get_or_insert(line);
        end_line = Some(line);
        if incomplete {
            break;
        }
    }
    Ok(SlicedPayload {
        data,
        start_line,
        end_line,
        total_lines: None,
        truncated: !range_completed,
        stopped_by: (!range_completed).then_some("max_bytes"),
    })
}

fn line_count(bytes: &[u8]) -> Result<u32, Error> {
    let count = bytes.iter().filter(|byte| **byte == b'\n').count()
        + usize::from(!bytes.is_empty() && !bytes.ends_with(b"\n"));
    u32::try_from(count).map_err(|_| too_many_lines())
}

/// Returns byte ranges for logical lines, retaining each newline in its line
/// and not inventing an extra empty line after a trailing newline.
fn line_spans(bytes: &[u8]) -> Vec<(usize, usize)> {
    let mut spans = Vec::new();
    let mut start = 0usize;
    for (index, byte) in bytes.iter().enumerate() {
        if *byte == b'\n' {
            spans.push((start, index + 1));
            start = index + 1;
        }
    }
    if start < bytes.len() {
        spans.push((start, bytes.len()));
    }
    spans
}

fn parse_lfs_pointer(payload: &[u8]) -> Option<LfsPointer> {
    const VERSION: &[u8] = b"version https://git-lfs.github.com/spec/v1";
    const OID_PREFIX: &[u8] = b"sha256:";

    if !payload.ends_with(b"\n") || std::str::from_utf8(payload).is_err() {
        return None;
    }
    let body = payload.strip_suffix(b"\n")?;
    let mut lines = body.split(|byte| *byte == b'\n');
    if lines.next()? != VERSION {
        return None;
    }

    let mut previous_key: Option<&[u8]> = None;
    let mut oid = None;
    let mut size = None;
    for line in lines {
        let separator = line.iter().position(|byte| *byte == b' ')?;
        let key = &line[..separator];
        let value = &line[separator + 1..];
        if key.is_empty()
            || value.is_empty()
            || !key
                .iter()
                .all(|byte| matches!(byte, b'a'..=b'z' | b'0'..=b'9' | b'.' | b'-'))
            || previous_key.is_some_and(|previous| previous >= key)
        {
            return None;
        }
        previous_key = Some(key);
        match key {
            b"oid" => {
                let digest = value.strip_prefix(OID_PREFIX)?;
                if digest.len() != 64
                    || !digest
                        .iter()
                        .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
                {
                    return None;
                }
                oid = Some(std::str::from_utf8(digest).ok()?.to_owned());
            }
            b"size" => {
                if !value.iter().all(u8::is_ascii_digit) {
                    return None;
                }
                size = Some(std::str::from_utf8(value).ok()?.parse().ok()?);
            }
            _ => {}
        }
    }
    Some(LfsPointer {
        oid: oid?,
        size: size?,
    })
}

fn missing_blob(oid: Oid) -> Error {
    Error::new(
        ErrorCode::MissingObject,
        format!("blob object {oid} is missing from the object store"),
    )
}

fn too_many_lines() -> Error {
    Error::new(
        ErrorCode::ResultTooLarge,
        "file contains more lines than the result format can represent",
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::local_odb::{LocalOdb, LocalOdbOptions};
    use crate::test_support::{fixture_oid, fixture_repo};

    fn fixture(name: &str, oid_name: &str) -> (LocalOdb, Snapshot) {
        let (store, _) =
            LocalOdb::open(fixture_repo(name), Default::default()).expect("fixture opens");
        let snapshot = Snapshot::open(&store, fixture_oid(oid_name), &Budget::unlimited())
            .expect("snapshot opens");
        (store, snapshot)
    }

    #[test]
    fn reads_whole_text_file_and_line_ranges() {
        let (store, snapshot) = fixture("sha1-basic.git", "sha1_basic_head");
        let whole = read_file(
            &store,
            &snapshot,
            b"README.md",
            &FileOptions::default(),
            &Budget::unlimited(),
        )
        .expect("README reads");
        assert_eq!(whole.kind, FileKind::Text);
        assert_eq!(
            whole.data,
            b"# Gitility fixture\n\nCanonical object-query input.\n"
        );
        assert_eq!(whole.total_lines, Some(3));
        assert!(!whole.truncated);

        let range = read_file(
            &store,
            &snapshot,
            b"src/story.txt",
            &FileOptions {
                lines: Some((2, 3)),
                max_bytes: 1_000,
            },
            &Budget::unlimited(),
        )
        .expect("line range reads");
        assert_eq!(range.data, b"second line\nthird line\n");
        assert_eq!((range.start_line, range.end_line), (Some(2), Some(3)));
        assert_eq!(range.total_lines, Some(4));
        assert!(!range.truncated);
        assert_eq!(range.stats.stopped_by, None);

        let clamped = read_file(
            &store,
            &snapshot,
            b"src/story.txt",
            &FileOptions {
                lines: Some((3, 100)),
                max_bytes: 1_000,
            },
            &Budget::unlimited(),
        )
        .expect("past-EOF end clamps");
        assert_eq!(clamped.data, b"third line\nfourth line\n");
        assert_eq!((clamped.start_line, clamped.end_line), (Some(3), Some(4)));
        assert_eq!(clamped.total_lines, Some(4));
        assert!(!clamped.truncated);
        assert_eq!(clamped.stats.stopped_by, None);

        let past_eof = read_file(
            &store,
            &snapshot,
            b"src/story.txt",
            &FileOptions {
                lines: Some((100, 200)),
                max_bytes: 1_000,
            },
            &Budget::unlimited(),
        )
        .expect("past-EOF range is an empty terminal page");
        assert!(past_eof.data.is_empty());
        assert_eq!((past_eof.start_line, past_eof.end_line), (None, None));
        assert_eq!(past_eof.total_lines, Some(4));
        assert!(!past_eof.truncated);
        assert_eq!(past_eof.stats.stopped_by, None);
    }

    #[test]
    fn byte_cap_signals_only_when_it_prevents_the_requested_range() {
        let (store, snapshot) = fixture("sha1-basic.git", "sha1_basic_head");
        let before_start = read_file(
            &store,
            &snapshot,
            b"src/story.txt",
            &FileOptions {
                lines: Some((3, 3)),
                max_bytes: 11,
            },
            &Budget::unlimited(),
        )
        .expect("capped range returns an explicit empty result");
        assert!(before_start.data.is_empty());
        assert_eq!(
            (before_start.start_line, before_start.end_line),
            (None, None)
        );
        assert_eq!(before_start.total_lines, None);
        assert!(before_start.truncated);
        assert_eq!(before_start.stats.stopped_by, Some("max_bytes"));

        let completed = read_file(
            &store,
            &snapshot,
            b"src/story.txt",
            &FileOptions {
                lines: Some((1, 2)),
                max_bytes: 23,
            },
            &Budget::unlimited(),
        )
        .expect("range completed before the cap returns normally");
        assert_eq!(completed.data, b"first line\nsecond line\n");
        assert_eq!(
            (completed.start_line, completed.end_line),
            (Some(1), Some(2))
        );
        assert_eq!(completed.total_lines, None);
        assert!(!completed.truncated);
        assert_eq!(completed.stats.stopped_by, None);
    }

    #[test]
    fn a_long_first_line_is_returned_truncated_at_the_byte_cap() {
        let (store, snapshot) = fixture("sha1-basic.git", "sha1_basic_head");
        let file = read_file(
            &store,
            &snapshot,
            b"long-line.txt",
            &FileOptions {
                lines: Some((1, 1)),
                max_bytes: 32,
            },
            &Budget::unlimited(),
        )
        .expect("long line reads bounded");
        assert_eq!(file.data, vec![b'x'; 32]);
        assert_eq!((file.start_line, file.end_line), (Some(1), Some(1)));
        assert_eq!(file.total_lines, None);
        assert!(file.truncated);
        assert_eq!(file.stats.stopped_by, Some("max_bytes"));
        assert!(file.stats.bytes_read >= 12_051);
    }

    #[test]
    fn byte_caps_keep_whole_lines_after_the_first_line() {
        let options = FileOptions {
            lines: None,
            max_bytes: 8,
        };
        let sliced = slice_payload(b"one\nsecond line\nthird\n", &options)
            .expect("pure payload slicing succeeds");
        assert_eq!(sliced.data, b"one\n");
        assert!(sliced.truncated);
        assert_eq!(sliced.total_lines, None);

        let first_line = slice_payload(b"very long first line\nsecond\n", &options)
            .expect("first line may be truncated");
        assert_eq!(first_line.data, b"very lon");
        assert!(first_line.truncated);
    }

    #[test]
    fn classifies_binary_symlink_gitlink_and_empty_entries_without_following() {
        let (store, snapshot) = fixture("sha1-basic.git", "sha1_basic_head");
        let budget = Budget::unlimited();
        let binary = read_file(
            &store,
            &snapshot,
            b"binary.dat",
            &FileOptions::default(),
            &budget,
        )
        .expect("binary reads");
        assert_eq!(binary.kind, FileKind::Binary);
        assert!(binary.data.contains(&0));

        let symlink = read_file(
            &store,
            &snapshot,
            b"link-to-nested",
            &FileOptions::default(),
            &Budget::unlimited(),
        )
        .expect("symlink target reads");
        assert_eq!(symlink.kind, FileKind::Symlink);
        assert_eq!(symlink.data, b"subdir/nested.txt");

        let gitlink = read_file(
            &store,
            &snapshot,
            b"modules/example",
            &FileOptions::default(),
            &Budget::unlimited(),
        )
        .expect("gitlink returns without opening target");
        assert_eq!(gitlink.kind, FileKind::Gitlink);
        assert!(gitlink.data.is_empty());

        let empty = read_file(
            &store,
            &snapshot,
            b"empty.bin",
            &FileOptions::default(),
            &Budget::unlimited(),
        )
        .expect("empty blob reads");
        assert_eq!(empty.kind, FileKind::Text);
        assert!(empty.data.is_empty());
        assert_eq!(empty.total_lines, Some(0));
    }

    #[test]
    fn parses_a_well_formed_lfs_pointer_without_resolving_it() {
        let (store, snapshot) = fixture("lfs-pointer.git", "lfs_pointer_head");
        let file = read_file(
            &store,
            &snapshot,
            b"model.bin",
            &FileOptions::default(),
            &Budget::unlimited(),
        )
        .expect("LFS pointer reads");
        let pointer = file.lfs_pointer.expect("LFS metadata parses");
        assert_eq!(
            pointer.oid,
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        );
        assert_eq!(pointer.size, 12_345);
        assert!(file
            .data
            .starts_with(b"version https://git-lfs.github.com/spec/v1\n"));

        let extension = b"version https://git-lfs.github.com/spec/v1\noid sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nsize 12345\nx-foo preserved\n";
        assert_eq!(
            parse_lfs_pointer(extension),
            Some(LfsPointer {
                oid: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef".to_owned(),
                size: 12_345,
            })
        );
    }

    #[test]
    fn path_errors_and_tree_paths_are_normalized() {
        let (store, snapshot) = fixture("sha1-basic.git", "sha1_basic_head");
        for path in [
            b"missing".as_slice(),
            b"src/./story.txt",
            b"src/../story.txt",
            b"nul\0path",
        ] {
            assert_eq!(
                read_file(
                    &store,
                    &snapshot,
                    path,
                    &FileOptions::default(),
                    &Budget::unlimited()
                )
                .expect_err("invalid path fails")
                .code,
                ErrorCode::InvalidPath
            );
        }
        assert_eq!(
            read_file(
                &store,
                &snapshot,
                b"src",
                &FileOptions::default(),
                &Budget::unlimited()
            )
            .expect_err("tree path is not a blob")
            .code,
            ErrorCode::NotABlob
        );
    }

    #[test]
    fn missing_and_corrupt_blob_reads_surface_odb_errors() {
        let (missing_store, missing_snapshot) = fixture("sha1-missing.git", "sha1_basic_head");
        let missing = read_file(
            &missing_store,
            &missing_snapshot,
            b"README.md",
            &FileOptions::default(),
            &Budget::unlimited(),
        )
        .expect_err("missing blob fails");
        assert_eq!(missing.code, ErrorCode::MissingObject);
        assert!(missing
            .message
            .contains(&fixture_oid("sha1_basic_readme").to_hex()));

        for name in ["loose-bad-hash.git", "loose-malformed-header.git"] {
            let (store, _) = LocalOdb::open(
                fixture_repo(&format!("corrupt/{name}")),
                LocalOdbOptions::default(),
            )
            .expect("corrupt fixture opens");
            let snapshot =
                Snapshot::open(&store, fixture_oid("sha1_basic_head"), &Budget::unlimited())
                    .expect("unaffected commit opens");
            let error = read_file(
                &store,
                &snapshot,
                b"README.md",
                &FileOptions::default(),
                &Budget::unlimited(),
            )
            .expect_err("corrupt blob never returns data");
            assert!(matches!(
                error.code,
                ErrorCode::HashMismatch | ErrorCode::MalformedObject | ErrorCode::BackendError
            ));
        }
    }

    #[test]
    fn packed_corruption_surfaces_through_query_entry_points() {
        let (healthy, _) = LocalOdb::open(fixture_repo("sha1-basic.git"), Default::default())
            .expect("healthy fixture opens");
        let snapshot = Snapshot::open(
            &healthy,
            fixture_oid("sha1_basic_head"),
            &Budget::unlimited(),
        )
        .expect("healthy snapshot opens");

        for (name, expected) in [
            ("pack-truncated.git", ErrorCode::PackChecksumMismatch),
            ("pack-bad-checksum.git", ErrorCode::PackChecksumMismatch),
            ("idx-bad-checksum.git", ErrorCode::IndexChecksumMismatch),
        ] {
            let (store, _) = LocalOdb::open(
                fixture_repo(&format!("corrupt/{name}")),
                LocalOdbOptions {
                    verify_pack_checksums: true,
                },
            )
            .expect("corrupt fixture opens");
            let error = read_file(
                &store,
                &snapshot,
                b"README.md",
                &FileOptions::default(),
                &Budget::unlimited(),
            )
            .expect_err("checksum corruption stops the query");
            assert_eq!(error.code, expected, "wrong code for {name}");
        }

        let (body_store, _) = LocalOdb::open(
            fixture_repo("corrupt/pack-body-corrupt-valid-checksums.git"),
            LocalOdbOptions {
                verify_pack_checksums: true,
            },
        )
        .expect("body-corrupt fixture opens");
        let error = read_file(
            &body_store,
            &snapshot,
            b"README.md",
            &FileOptions::default(),
            &Budget::unlimited(),
        )
        .expect_err("corrupt packed blob never returns data");
        assert!(matches!(
            error.code,
            ErrorCode::HashMismatch | ErrorCode::MalformedObject
        ));
    }

    #[test]
    fn malformed_lfs_candidates_are_not_recognized() {
        for payload in [
            b"version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 1\n".as_slice(),
            b"version https://git-lfs.github.com/spec/v1\noid sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nsize nope\n",
            b"version https://git-lfs.github.com/spec/v1\noid sha256:0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef\nsize 1\n",
            b"version https://git-lfs.github.com/spec/v1\noid sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nsize 1",
        ] {
            assert_eq!(parse_lfs_pointer(payload), None);
        }
    }
}
