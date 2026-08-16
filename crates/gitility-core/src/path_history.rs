//! Budgeted history for one raw-byte repository path.
//!
//! This is intentionally Gitility's algorithm, not an emulation of Git's
//! simplify-history machinery. Commits are visited in the same chronological
//! order as [`crate::log`], and a commit is emitted when the path's blob or
//! mode differs from its first parent. A root is emitted when the path exists.
//! Without `--follow`, no Git invocation reproduces that merge rule:
//! `git log --full-history` is the nearest oracle, but also emits a merge
//! when the path differs only from a non-first parent (Gitility's
//! design-sanctioned R3 rule omits those noise merges). WITH `--follow`,
//! `--diff-merges=first-parent` empirically switches git 2.55.0's merge
//! selection to first-parent comparison and matches Gitility exactly.
//! Rename following is attempted only when that comparison reports an added
//! destination; the walk then re-targets to the detected source path.
//!
//! Each ordinary comparison projects both trees onto the single tracked path,
//! so its worst-case cost is O(history × path-depth). Rename detection is the
//! exceptional step: it considers only additions/deletions in that commit's
//! first-parent change set, as required by gix-diff's rewrite tracker.

use crate::budget::Budget;
use crate::cursor::{self, Cursor, CursorExpected, MAX_CURSOR_BYTES, OPERATION_HISTORY};
use crate::diff::{diff, DiffOptions, DiffStatus, RenameTracking};
use crate::error::{Error, ErrorCode};
use crate::log::{decode_log_commit, read_payload, LogCommit, LogOptions, LogOrder, LogPage, Walk};
use crate::object::Oid;
use crate::odb::ObjectDb;
use crate::snapshot::Snapshot;
use crate::tree::{resolve_path, validate_literal_path, QueryStats, ResolvedPath};

/// Options for [`history`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryOptions {
    /// Re-target an added path to a first-parent rename source.
    pub follow_renames: bool,
    pub limit: usize,
    pub cursor: Option<Vec<u8>>,
}

impl Default for HistoryOptions {
    fn default() -> Self {
        Self {
            follow_renames: true,
            limit: 1_000,
            cursor: None,
        }
    }
}

/// Walk one path's history, newest first, in chronological commit order.
///
/// Unlike Git's path history, merge commits are compared only with their first
/// parent. Without `--follow`, no Git invocation reproduces that rule: the
/// nearest oracle is `git log --full-history -- <path>`, which additionally
/// emits merges whose path differs only from a non-first parent; Gitility
/// deliberately produces fewer such noise merges under design decision R3.
/// With `--follow`, adding `--diff-merges=first-parent` makes the pinned git
/// 2.55.0 match Gitility exactly (empirical; see the differential oracle).
pub fn history(
    store: &dyn ObjectDb,
    snapshot: &Snapshot,
    path: &[u8],
    opts: &HistoryOptions,
    budget: &Budget,
) -> Result<LogPage, Error> {
    crate::commit_graph::ensure_sha1(store, &[snapshot.commit_oid, snapshot.tree_oid])?;
    validate_literal_path(path, "history")?;
    if path.is_empty() {
        return Err(Error::new(
            ErrorCode::InvalidPath,
            "history path must name a repository entry",
        ));
    }
    if opts.limit == 0 {
        return Err(Error::new(
            ErrorCode::InvalidArgument,
            "history page limit must be greater than zero",
        ));
    }
    budget.check()?;

    let fingerprint = option_fingerprint(path, opts.follow_renames);
    let expected = CursorExpected {
        hash_kind: snapshot.commit_oid.kind(),
        snapshot_digest: snapshot.commit_oid.as_bytes(),
        operation_tag: OPERATION_HISTORY,
        option_fingerprint: fingerprint,
    };
    let resume = opts
        .cursor
        .as_deref()
        .map(|bytes| decode_resume(bytes, expected, snapshot.commit_oid.kind()))
        .transpose()?;

    let walk_options = LogOptions {
        order: LogOrder::Chronological,
        limit: usize::MAX,
        ..LogOptions::default()
    };
    let mut walk = if resume.is_some() {
        budget.without_object_recharge(|| {
            Walk::new(store, snapshot.commit_oid, &walk_options, budget)
        })?
    } else {
        Walk::new(store, snapshot.commit_oid, &walk_options, budget)?
    };
    let mut tracked_path = path.to_vec();
    let mut found_resume = resume.is_none();
    let mut commits = Vec::with_capacity(opts.limit.min(1_024));
    let mut stopped_by = None;

    loop {
        budget.check()?;
        let next = if found_resume {
            walk.next(true)
        } else {
            budget.without_object_recharge(|| walk.next(false))
        };
        let walked = match next {
            Some(Ok(walked)) => walked,
            Some(Err(error)) if truncatable(&error) && !commits.is_empty() => {
                stopped_by = Some(error.limit.unwrap_or("budget"));
                break;
            }
            Some(Err(error)) => return Err(error),
            None => break,
        };

        let replaying_prefix = !found_resume;
        let load_change = || {
            let shallow = store
                .shallow_roots()
                .is_some_and(|roots| roots.contains(&walked.id));
            let payload = read_payload(store, walked.id, budget, false)?;
            let commit = decode_log_commit(walked.id, &payload, shallow)?;
            let change = path_change(store, snapshot, &commit, &tracked_path, opts, budget)?;
            Ok::<_, Error>((commit, change))
        };
        let loaded = if replaying_prefix {
            budget.without_object_recharge(load_change)
        } else {
            load_change()
        };
        let (commit, change) = match loaded {
            Ok(loaded) => loaded,
            Err(error) if truncatable(&error) && !commits.is_empty() => {
                stopped_by = Some(error.limit.unwrap_or("budget"));
                break;
            }
            Err(error) => return Err(error),
        };
        if let Some(source_path) = change.rename_source {
            tracked_path = source_path;
        }

        if change.changed {
            if !found_resume {
                if Some(walked.id) == resume {
                    found_resume = true;
                }
                continue;
            }
            if commits.len() == opts.limit {
                stopped_by = Some("limit");
                break;
            }
            commits.push(commit);
        }

        if let Some(error) = walk.take_pending_error() {
            if truncatable(&error) && !commits.is_empty() {
                stopped_by = Some(error.limit.unwrap_or("budget"));
                break;
            }
            return Err(error);
        }
    }

    if !found_resume {
        return Err(invalid_cursor(
            "position check failed: commit is not an emitted history commit",
        ));
    }

    let truncated = stopped_by.is_some();
    if truncated && commits.is_empty() {
        return Err(Error::new(
            ErrorCode::BudgetExceeded,
            "budget exhausted before any path-history pagination progress",
        )
        .with_limit(stopped_by.expect("a stopped walk names its limit")));
    }
    let next_cursor = if truncated {
        let position = commits
            .last()
            .expect("a truncated page made pagination progress")
            .id
            .as_bytes()
            .to_vec();
        let encoded = cursor::encode(&Cursor {
            hash_kind: snapshot.commit_oid.kind(),
            snapshot_digest: snapshot.commit_oid.as_bytes().to_vec(),
            operation_tag: OPERATION_HISTORY,
            option_fingerprint: fingerprint,
            generation: Vec::new(),
            position,
        });
        if encoded.len() > MAX_CURSOR_BYTES {
            return Err(Error::new(
                ErrorCode::ResultTooLarge,
                "history cursor exceeds the cursor size limit",
            ));
        }
        Some(encoded)
    } else {
        None
    };

    let (objects_read, bytes_read, _, _) = budget.spent();
    let (cache_hits, cache_misses) = budget.cache_spent();
    let cache = store.cache_stats();
    Ok(LogPage {
        stats: QueryStats {
            objects_read,
            bytes_read,
            entries_emitted: commits.len() as u64,
            cache_hits,
            cache_misses,
            cache_bytes: cache.bytes,
            cache_entries: cache.entries,
            cache_evictions: cache.evictions,
            files_scanned: 0,
            blobs_deduped: 0,
            binary_skipped: 0,
            oversize_skipped: 0,
            payload_rereads: 0,
            stopped_by,
        },
        commits,
        next_cursor,
        truncated,
    })
}

struct PathChange {
    changed: bool,
    rename_source: Option<Vec<u8>>,
}

fn path_change(
    store: &dyn ObjectDb,
    _snapshot: &Snapshot,
    commit: &LogCommit,
    path: &[u8],
    opts: &HistoryOptions,
    budget: &Budget,
) -> Result<PathChange, Error> {
    let Some(parent_id) = commit.parents.first().copied() else {
        let at_root = Snapshot {
            commit_oid: commit.id,
            tree_oid: commit.tree_id,
        };
        let present = match resolve_path(store, &at_root, path, budget) {
            Ok(ResolvedPath::Entry(_)) => true,
            Ok(ResolvedPath::RootTree(_)) => false,
            Err(error) if error.code == ErrorCode::InvalidPath => false,
            Err(error) => return Err(error),
        };
        return Ok(PathChange {
            changed: present,
            rename_source: None,
        });
    };

    let parent_payload = read_payload(store, parent_id, budget, false)?;
    let parent_shallow = store
        .shallow_roots()
        .is_some_and(|roots| roots.contains(&parent_id));
    let parent = decode_log_commit(parent_id, &parent_payload, parent_shallow)?;
    let base = Snapshot {
        commit_oid: parent.id,
        tree_oid: parent.tree_id,
    };
    let head = Snapshot {
        commit_oid: commit.id,
        tree_oid: commit.tree_id,
    };
    let focused = diff(
        store,
        &base,
        store,
        &head,
        &DiffOptions {
            pathspecs: vec![path.to_vec()],
            format: crate::diff::DiffFormat::Summary,
            max_diff_files: 2,
            max_diff_hunks: 1,
            max_diff_lines: 1,
            max_object_bytes: budget.limits().max_object_bytes,
            ..DiffOptions::default()
        },
        budget,
    )?;
    let Some(file) = focused.files.first() else {
        return Ok(PathChange {
            changed: false,
            rename_source: None,
        });
    };
    let added = file.status == DiffStatus::Added;
    if !added || !opts.follow_renames {
        return Ok(PathChange {
            changed: true,
            rename_source: None,
        });
    }

    // gix-diff's rewrite tracker must see the commit's complete deletion and
    // addition candidate set. This second pass runs only at an added tracked
    // destination and never enables copy sources outside that change set.
    let rewritten = diff(
        store,
        &base,
        store,
        &head,
        &DiffOptions {
            format: crate::diff::DiffFormat::Summary,
            renames: RenameTracking::Similarity,
            // Correctness cannot depend on an unrelated page-shaped diff
            // ceiling: the history budget and tree-entry ceiling bound this
            // exceptional candidate pass.
            max_diff_files: usize::MAX,
            max_diff_hunks: 1,
            max_diff_lines: 1,
            max_object_bytes: budget.limits().max_object_bytes,
            ..DiffOptions::default()
        },
        budget,
    )?;
    if rewritten.stats.oversize_skipped != 0 {
        return Err(Error::new(
            ErrorCode::ObjectTooLarge,
            "path-history rename candidates exceed max_object_bytes",
        )
        .with_limit("max_object_bytes"));
    }
    let source = rewritten
        .files
        .into_iter()
        .find(|file| file.status == DiffStatus::Renamed && file.new_path.as_deref() == Some(path))
        .and_then(|file| file.old_path);
    Ok(PathChange {
        changed: true,
        rename_source: source,
    })
}

fn option_fingerprint(path: &[u8], follow_renames: bool) -> u64 {
    let mut normalized = Vec::with_capacity(path.len().saturating_add(16));
    normalized.extend_from_slice(b"history-v1\0");
    normalized.extend_from_slice(&(path.len() as u64).to_le_bytes());
    normalized.extend_from_slice(path);
    normalized.push(u8::from(follow_renames));
    cursor::fnv1a_64(&normalized)
}

fn decode_resume(
    bytes: &[u8],
    expected: CursorExpected<'_>,
    hash_kind: crate::object::HashKind,
) -> Result<Oid, Error> {
    let decoded = cursor::decode(bytes, expected)?;
    if !decoded.generation.is_empty() {
        return Err(invalid_cursor(
            "generation check failed for this object store",
        ));
    }
    Oid::new(hash_kind, &decoded.position)
        .map_err(|_| invalid_cursor("position check failed: commit digest has the wrong length"))
}

fn truncatable(error: &Error) -> bool {
    error.code == ErrorCode::BudgetExceeded
        && !matches!(
            error.limit,
            Some("max_provider_requests" | "max_provider_bytes")
        )
}

fn invalid_cursor(message: &'static str) -> Error {
    Error::new(ErrorCode::InvalidCursor, message)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::local_odb::LocalOdb;
    use crate::test_support::{fixture_oid, fixture_repo};
    use std::process::Command;
    use std::sync::atomic::AtomicBool;
    use std::sync::Arc;

    #[test]
    fn generated_non_deviation_cases_match_the_nearest_full_history_oracle() {
        for (repository_name, head_key, path, follow_options) in [
            (
                "sha1-blame.git",
                "sha1_blame_head",
                b"docs/final.txt".as_slice(),
                &[false, true][..],
            ),
            (
                "sha1-graph.git",
                "sha1_graph_head",
                b"graph.txt".as_slice(),
                &[false, true][..],
            ),
        ] {
            let repository = fixture_repo(repository_name);
            let (store, _) =
                LocalOdb::open(&repository, Default::default()).expect("fixture repository opens");
            let head = fixture_oid(head_key);
            let snapshot =
                Snapshot::open(&store, head, &Budget::unlimited()).expect("fixture snapshot opens");
            for &follow in follow_options {
                let actual = history(
                    &store,
                    &snapshot,
                    path,
                    &HistoryOptions {
                        follow_renames: follow,
                        ..HistoryOptions::default()
                    },
                    &Budget::unlimited(),
                )
                .expect("core history succeeds")
                .commits
                .into_iter()
                .map(|commit| commit.id.to_hex())
                .collect::<Vec<_>>();
                let expected = git_history(&repository, head, path, follow);
                assert_eq!(
                    actual,
                    expected,
                    "history divergence: repo={repository_name} path={} follow={follow}",
                    String::from_utf8_lossy(path)
                );
            }
        }
    }

    #[test]
    fn nearest_oracle_deviations_are_asserted_for_merge_rule_and_follow_copy_detection() {
        for (repository_name, head_key, path, follow, expected_counts, class) in [
            (
                "sha1-graph.git",
                "sha1_graph_head",
                b"criss-left.txt".as_slice(),
                false,
                Some((2, 3)),
                "merge_rule",
            ),
            (
                "sha1-history.git",
                "sha1_history_head",
                b"branches/left.txt".as_slice(),
                false,
                Some((2, 3)),
                "merge_rule",
            ),
            (
                "sha1-history.git",
                "sha1_history_head",
                b"candidates/selected.txt".as_slice(),
                true,
                None,
                "follow_copy_detection",
            ),
        ] {
            let repository = fixture_repo(repository_name);
            let (store, _) =
                LocalOdb::open(&repository, Default::default()).expect("fixture repository opens");
            let head = fixture_oid(head_key);
            let snapshot =
                Snapshot::open(&store, head, &Budget::unlimited()).expect("fixture snapshot opens");
            let actual = history(
                &store,
                &snapshot,
                path,
                &HistoryOptions {
                    follow_renames: follow,
                    ..HistoryOptions::default()
                },
                &Budget::unlimited(),
            )
            .expect("core history succeeds")
            .commits
            .into_iter()
            .map(|commit| commit.id.to_hex())
            .collect::<Vec<_>>();
            let expected = git_history(&repository, head, path, follow);
            eprintln!(
                "ALLOWLISTED {class}: repo={repository_name} path={} follow={follow} git={expected:?} gitility={actual:?}",
                String::from_utf8_lossy(path)
            );
            assert_ne!(
                actual, expected,
                "the approved divergence must stay exercised"
            );
            if let Some((gitility_count, git_count)) = expected_counts {
                assert_eq!(actual.len(), gitility_count);
                assert_eq!(expected.len(), git_count);
            }
        }
    }

    #[test]
    fn cursor_reconstructs_three_pages_and_binds_path_and_follow_option() {
        let repository = fixture_repo("sha1-blame.git");
        let (store, _) =
            LocalOdb::open(&repository, Default::default()).expect("fixture repository opens");
        let head = fixture_oid("sha1_blame_head");
        let snapshot =
            Snapshot::open(&store, head, &Budget::unlimited()).expect("fixture snapshot opens");
        let expected = history(
            &store,
            &snapshot,
            b"docs/final.txt",
            &HistoryOptions::default(),
            &Budget::unlimited(),
        )
        .expect("unpaged history succeeds")
        .commits
        .into_iter()
        .map(|commit| commit.id.to_hex())
        .collect::<Vec<_>>();
        let mut cursor = None;
        let mut reconstructed = Vec::new();
        let mut page_count = 0;
        loop {
            let page = history(
                &store,
                &snapshot,
                b"docs/final.txt",
                &HistoryOptions {
                    follow_renames: true,
                    limit: 3,
                    cursor: cursor.clone(),
                },
                &Budget::unlimited(),
            )
            .expect("history page succeeds");
            page_count += 1;
            reconstructed.extend(page.commits.into_iter().map(|commit| commit.id.to_hex()));
            cursor = page.next_cursor;
            if cursor.is_none() {
                break;
            }
        }
        assert!(page_count >= 3);
        assert_eq!(reconstructed, expected);

        let first = history(
            &store,
            &snapshot,
            b"docs/final.txt",
            &HistoryOptions {
                limit: 3,
                ..HistoryOptions::default()
            },
            &Budget::unlimited(),
        )
        .expect("first page succeeds");
        for (path, follow) in [
            (b"independent.txt".as_slice(), true),
            (b"docs/final.txt".as_slice(), false),
        ] {
            let error = history(
                &store,
                &snapshot,
                path,
                &HistoryOptions {
                    follow_renames: follow,
                    limit: 3,
                    cursor: first.next_cursor.clone(),
                },
                &Budget::unlimited(),
            )
            .expect_err("changed fingerprint rejects cursor");
            assert_eq!(error.code, ErrorCode::InvalidCursor);
        }

        for path in [b"*.txt".as_slice(), b":(glob)docs/**".as_slice()] {
            let error = history(
                &store,
                &snapshot,
                path,
                &HistoryOptions::default(),
                &Budget::unlimited(),
            )
            .expect_err("history accepts one literal path only");
            assert_eq!(error.code, ErrorCode::InvalidArgument);
            assert_eq!(error.reason.as_deref(), Some("pathspec_not_literal"));
        }
    }

    #[test]
    fn cursor_prefixes_recompute_retargeting_without_recharging_page_cost() {
        let repository = fixture_repo("sha1-blame.git");
        let head = fixture_oid("sha1_blame_pagination_head");
        let (store, _) =
            LocalOdb::open(&repository, Default::default()).expect("fixture repository opens");
        let snapshot =
            Snapshot::open(&store, head, &Budget::unlimited()).expect("fixture snapshot opens");
        let mut cursor = None;
        let mut page_one_objects = 0;
        let mut page_forty_objects = 0;

        for page_number in 1..=40 {
            let budget = Budget::new(
                crate::budget::BudgetLimits {
                    max_objects: 10,
                    ..crate::budget::BudgetLimits::default()
                },
                None,
                Arc::new(AtomicBool::new(false)),
            );
            let page = history(
                &store,
                &snapshot,
                b"page-cost.txt",
                &HistoryOptions {
                    follow_renames: true,
                    limit: 1,
                    cursor,
                },
                &budget,
            )
            .expect("fresh-budget history page succeeds");
            assert_eq!(page.commits.len(), 1);
            if page_number == 1 {
                page_one_objects = page.stats.objects_read;
            }
            if page_number == 40 {
                page_forty_objects = page.stats.objects_read;
            }
            cursor = page.next_cursor;
        }

        eprintln!(
            "M3 page-cost objects_read: page1={page_one_objects} page40={page_forty_objects}"
        );
        assert!(
            page_forty_objects.abs_diff(page_one_objects) <= 2,
            "late-page object spend must stay within a small constant of page one"
        );
    }

    fn git_history(
        repository: &std::path::Path,
        head: Oid,
        path: &[u8],
        follow: bool,
    ) -> Vec<String> {
        let mut arguments = vec![
            "log".to_owned(),
            "--format=%H".to_owned(),
            "--no-patch".to_owned(),
            "--full-history".to_owned(),
        ];
        if follow {
            // Load-bearing WITH --follow on the pinned git 2.55.0: switches
            // merge selection to first-parent comparison, matching Gitility
            // exactly (11 vs 10 commits on sha1-blame.git docs/final.txt).
            // A no-op without --follow.
            arguments.push("--diff-merges=first-parent".to_owned());
            arguments.push("--follow".to_owned());
        }
        arguments.extend([
            head.to_hex(),
            "--".to_owned(),
            String::from_utf8_lossy(path).into(),
        ]);
        let output = Command::new("git")
            .arg("-C")
            .arg(repository)
            .args(arguments)
            .output()
            .expect("git log runs");
        assert!(output.status.success(), "git log failed");
        std::str::from_utf8(&output.stdout)
            .expect("commit IDs are ASCII")
            .lines()
            .map(str::to_owned)
            .collect()
    }
}
