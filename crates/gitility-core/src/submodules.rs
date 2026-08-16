//! Bounded `.gitmodules` parsing and gitlink correlation.
//!
//! The query reads only the snapshot's root `.gitmodules` blob and tree
//! objects needed to enumerate gitlinks. URLs remain inert metadata, and a
//! gitlink's commit object is never opened or traversed.

use crate::budget::Budget;
use crate::error::{Error, ErrorCode, ErrorFile};
use crate::object::{ObjectKind, Oid};
use crate::odb::ObjectDb;
use crate::snapshot::Snapshot;
use crate::tree::{
    ensure_query_compatible, join_path, read_tree_entries_for_walk, validate_path, OwnedTreeEntry,
    TreeItemKind,
};
use bstr::ByteSlice;
use std::collections::BTreeMap;

const GITMODULES_PATH: &[u8] = b".gitmodules";
const CONFIG_KEYS: [&str; 5] = ["path", "url", "branch", "update", "shallow"];

/// Correlation state between a `.gitmodules` declaration and the snapshot
/// tree.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SubmoduleStatus {
    /// A declaration and gitlink exist at the same path.
    Active,
    /// A gitlink exists without a declaration.
    Undeclared,
    /// A declaration exists without a gitlink.
    Orphaned,
}

/// One byte-preserving submodule metadata row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Submodule {
    pub name: Option<Vec<u8>>,
    pub path: Vec<u8>,
    pub url: Option<Vec<u8>>,
    pub branch: Option<Vec<u8>>,
    pub commit_oid: Option<Oid>,
    pub status: SubmoduleStatus,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct Declaration {
    name: Vec<u8>,
    path: Option<Vec<u8>>,
    url: Option<Vec<u8>>,
    branch: Option<Vec<u8>>,
    #[allow(dead_code)]
    update: Option<Vec<u8>>,
    #[allow(dead_code)]
    shallow: Option<Vec<u8>>,
}

/// Returns the snapshot's declared and actual submodules in ascending raw-path
/// order.
///
/// `.gitmodules` is parsed with `gix-config`'s Git-compatible byte grammar.
/// Includes are deliberately not followed: a blob has no filesystem context,
/// and the API never performs external I/O or URL resolution.
pub fn submodules(
    store: &dyn ObjectDb,
    snapshot: &Snapshot,
    budget: &Budget,
) -> Result<Vec<Submodule>, Error> {
    ensure_query_compatible(store, snapshot)?;
    let root_entries = read_tree_entries_for_walk(store, snapshot.tree_oid, budget, true)?;
    let declarations = read_declarations(store, &root_entries, budget)?;
    let mut gitlinks = collect_gitlinks(store, root_entries, budget)?;

    let mut rows = Vec::with_capacity(declarations.len().saturating_add(gitlinks.len()));
    for declaration in declarations {
        let path = declaration
            .path
            .expect("validated declarations always carry paths");
        let commit_oid = gitlinks.remove(&path);
        rows.push(Submodule {
            name: Some(declaration.name),
            path,
            url: declaration.url,
            branch: declaration.branch,
            status: if commit_oid.is_some() {
                SubmoduleStatus::Active
            } else {
                SubmoduleStatus::Orphaned
            },
            commit_oid,
        });
    }
    rows.extend(gitlinks.into_iter().map(|(path, commit_oid)| Submodule {
        name: None,
        path,
        url: None,
        branch: None,
        commit_oid: Some(commit_oid),
        status: SubmoduleStatus::Undeclared,
    }));
    rows.sort_by(|left, right| left.path.cmp(&right.path));
    Ok(rows)
}

fn read_declarations(
    store: &dyn ObjectDb,
    root_entries: &[OwnedTreeEntry],
    budget: &Budget,
) -> Result<Vec<Declaration>, Error> {
    let Some(entry) = root_entries
        .iter()
        .find(|entry| entry.name == GITMODULES_PATH)
    else {
        return Ok(Vec::new());
    };
    if entry.kind != TreeItemKind::Blob {
        return Err(malformed_gitmodules(
            "snapshot .gitmodules entry is not a regular blob",
        ));
    }

    let mut payload = Vec::new();
    let kind = store
        .try_find(&entry.oid, &mut payload, budget)
        .map_err(name_gitmodules_error)?
        .ok_or_else(|| {
            Error::retryable(
                ErrorCode::MissingObject,
                format!(
                    ".gitmodules blob {} is missing from the object store",
                    entry.oid
                ),
            )
            .with_oid(entry.oid)
        })?;
    if kind != ObjectKind::Blob {
        return Err(malformed_gitmodules(
            "snapshot .gitmodules object is not a blob",
        ));
    }
    parse_declarations(&payload)
}

fn parse_config(payload: &[u8]) -> Result<gix_config::File, Error> {
    gix_config::File::try_from(payload.as_bstr()).map_err(|_| {
        malformed_gitmodules("snapshot .gitmodules is malformed")
            .with_reason("git_config_parse_error")
    })
}

fn parse_declarations(payload: &[u8]) -> Result<Vec<Declaration>, Error> {
    let config = parse_config(payload)?;
    let mut declarations = BTreeMap::<Vec<u8>, Declaration>::new();
    for section in config.sections() {
        let header = section.header();
        if !header.name().eq_ignore_ascii_case(b"submodule") {
            continue;
        }
        let Some(name) = header.subsection_name() else {
            continue;
        };
        let declaration = declarations
            .entry(name.to_vec())
            .or_insert_with(|| Declaration {
                name: name.to_vec(),
                ..Declaration::default()
            });
        for key in CONFIG_KEYS {
            let Some(value) = section.value_implicit(key) else {
                continue;
            };
            // Git config's implicit value is the boolean string "true".
            let value = value.map_or_else(|| b"true".to_vec(), |value| value.to_vec());
            match key {
                "path" => declaration.path = Some(value),
                "url" => declaration.url = Some(value),
                "branch" => declaration.branch = Some(value),
                "update" => declaration.update = Some(value),
                "shallow" => declaration.shallow = Some(value),
                _ => unreachable!("CONFIG_KEYS contains only supported keys"),
            }
        }
    }

    declarations
        .into_values()
        .map(|declaration| {
            let Some(path) = declaration.path.as_deref() else {
                return Err(
                    malformed_gitmodules("submodule declaration is missing its path")
                        .with_reason("submodule_path_missing"),
                );
            };
            validate_path(path).map_err(|_| {
                malformed_gitmodules("submodule declaration path is malformed")
                    .with_reason("submodule_path_invalid")
            })?;
            Ok(declaration)
        })
        .collect()
}

fn collect_gitlinks(
    store: &dyn ObjectDb,
    root_entries: Vec<OwnedTreeEntry>,
    budget: &Budget,
) -> Result<BTreeMap<Vec<u8>, Oid>, Error> {
    struct Frame {
        entries: std::vec::IntoIter<OwnedTreeEntry>,
        prefix: Vec<u8>,
    }

    let mut gitlinks = BTreeMap::new();
    let mut stack = vec![Frame {
        entries: root_entries.into_iter(),
        prefix: Vec::new(),
    }];
    while !stack.is_empty() {
        budget.check()?;
        let next = stack.last_mut().and_then(|frame| {
            frame
                .entries
                .next()
                .map(|entry| (join_path(&frame.prefix, &entry.name), entry))
        });
        let Some((path, entry)) = next else {
            stack.pop();
            continue;
        };
        match entry.kind {
            TreeItemKind::Tree => {
                let entries = read_tree_entries_for_walk(store, entry.oid, budget, true)?;
                stack.push(Frame {
                    entries: entries.into_iter(),
                    prefix: path,
                });
            }
            TreeItemKind::Gitlink => {
                budget.charge_tree_entry()?;
                gitlinks.insert(path, entry.oid);
            }
            TreeItemKind::Blob | TreeItemKind::Symlink => {}
        }
    }
    Ok(gitlinks)
}

fn name_gitmodules_error(error: Error) -> Error {
    if matches!(
        error.code,
        ErrorCode::MalformedObject | ErrorCode::ObjectTooLarge
    ) {
        error.with_file(ErrorFile::Gitmodules)
    } else {
        error
    }
}

fn malformed_gitmodules(message: &str) -> Error {
    Error::new(ErrorCode::MalformedObject, message).with_file(ErrorFile::Gitmodules)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::budget::BudgetLimits;
    use crate::local_odb::LocalOdb;
    use crate::test_support::{fixture_oid, fixture_repo};
    use std::process::Command;
    use std::sync::atomic::AtomicBool;
    use std::sync::Arc;

    type ConfigEntry = (Vec<u8>, Vec<u8>);

    fn fixture(name: &str, oid_name: &str) -> (LocalOdb, Snapshot) {
        let (store, _) =
            LocalOdb::open(fixture_repo(name), Default::default()).expect("fixture opens");
        let snapshot = Snapshot::open(&store, fixture_oid(oid_name), &Budget::unlimited())
            .expect("snapshot opens");
        (store, snapshot)
    }

    #[test]
    fn correlates_active_orphaned_undeclared_and_nested_gitlinks_without_opening_commits() {
        let (store, snapshot) = fixture("sha1-submodules.git", "sha1_submodules_head");
        let rows = submodules(&store, &snapshot, &Budget::unlimited()).expect("metadata reads");
        assert_eq!(
            rows.iter()
                .map(|row| row.path.as_slice())
                .collect::<Vec<_>>(),
            [
                b"different".as_slice(),
                b"normal",
                b"orphaned",
                b"sub/dir/mod",
                b"undeclared",
                b"with-url",
            ]
        );

        let different = &rows[0];
        assert_eq!(
            different.name.as_deref(),
            Some(b"Different Name".as_slice())
        );
        assert_eq!(different.status, SubmoduleStatus::Active);
        assert_eq!(
            different.url.as_deref(),
            Some(b"../relative path.git".as_slice())
        );

        assert_eq!(rows[2].status, SubmoduleStatus::Orphaned);
        assert_eq!(rows[2].commit_oid, None);
        assert_eq!(rows[3].name.as_deref(), Some(b"Nested Name".as_slice()));
        assert_eq!(
            rows[3].commit_oid.expect("nested gitlink").to_hex(),
            format!("{:040}", 4)
        );
        assert_eq!(rows[4].status, SubmoduleStatus::Undeclared);
        assert_eq!(rows[4].name, None);
        assert_eq!(rows[4].url, None);
        assert_eq!(rows[5].branch.as_deref(), Some(b"release/v1".as_slice()));
        assert_eq!(
            rows[5].url.as_deref(),
            Some(b"ssh://example.invalid/repo\\path.git".as_slice())
        );
    }

    #[test]
    fn no_gitmodules_and_no_gitlinks_is_empty() {
        let (store, snapshot) = fixture("sha1-nested.git", "sha1_nested_head");
        assert_eq!(
            submodules(&store, &snapshot, &Budget::unlimited()).unwrap(),
            []
        );
    }

    #[test]
    fn parser_handles_case_comments_quotes_continuations_and_all_supported_keys() {
        let payload = br#"
            ; comment
            [SuBmOdUlE "CaseSensitive"]
              PaTh = "sub/space path"
              URL = "ssh://host/a\\b#kept" # comment
              BrAnCh = feature/\
v2
              UPDATE = rebase
              shallow = true
        "#;
        let declarations = parse_declarations(payload).expect("Git config parses");
        assert_eq!(declarations.len(), 1);
        let declaration = &declarations[0];
        assert_eq!(declaration.name, b"CaseSensitive");
        assert_eq!(
            declaration.path.as_deref(),
            Some(b"sub/space path".as_slice())
        );
        assert_eq!(
            declaration.url.as_deref(),
            Some(b"ssh://host/a\\b#kept".as_slice())
        );
        assert_eq!(
            declaration.branch.as_deref(),
            Some(b"feature/v2".as_slice())
        );
        assert_eq!(declaration.update.as_deref(), Some(b"rebase".as_slice()));
        assert_eq!(declaration.shallow.as_deref(), Some(b"true".as_slice()));
    }

    #[test]
    fn malformed_and_oversize_gitmodules_name_the_metadata_file() {
        let (store, malformed_snapshot) =
            fixture("sha1-submodules.git", "sha1_submodules_malformed");
        let malformed = submodules(&store, &malformed_snapshot, &Budget::unlimited())
            .expect_err("malformed config fails");
        assert_eq!(malformed.code, ErrorCode::MalformedObject);
        assert_eq!(malformed.file, Some(ErrorFile::Gitmodules));

        let (_, snapshot) = fixture("sha1-submodules.git", "sha1_submodules_head");
        let budget = Budget::new(
            BudgetLimits {
                max_object_bytes: 512,
                ..BudgetLimits::default()
            },
            None,
            Arc::new(AtomicBool::new(false)),
        );
        let oversized = submodules(&store, &snapshot, &budget)
            .expect_err("the 570-byte config exceeds its cap");
        assert_eq!(oversized.code, ErrorCode::ObjectTooLarge);
        assert_eq!(oversized.limit, Some("max_object_bytes"));
        assert_eq!(oversized.file, Some(ErrorFile::Gitmodules));
    }

    #[test]
    fn walk_obeys_object_tree_entry_and_cancellation_budgets() {
        let (store, snapshot) = fixture("sha1-submodules.git", "sha1_submodules_head");
        let object_budget = Budget::new(
            BudgetLimits {
                max_objects: 1,
                ..BudgetLimits::default()
            },
            None,
            Arc::new(AtomicBool::new(false)),
        );
        let error = submodules(&store, &snapshot, &object_budget)
            .expect_err("config read exceeds object budget");
        assert_eq!(error.code, ErrorCode::BudgetExceeded);
        assert_eq!(error.limit, Some("max_objects"));

        let entry_budget = Budget::new(
            BudgetLimits {
                max_tree_entries: 2,
                ..BudgetLimits::default()
            },
            None,
            Arc::new(AtomicBool::new(false)),
        );
        let error = submodules(&store, &snapshot, &entry_budget)
            .expect_err("gitlink emissions exceed tree-entry budget");
        assert_eq!(error.code, ErrorCode::BudgetExceeded);
        assert_eq!(error.limit, Some("max_tree_entries"));

        let cancelled = Arc::new(AtomicBool::new(true));
        let cancelled_budget = Budget::new(BudgetLimits::default(), None, cancelled);
        assert_eq!(
            submodules(&store, &snapshot, &cancelled_budget)
                .expect_err("pre-cancelled query fails")
                .code,
            ErrorCode::Cancelled
        );
    }

    #[test]
    fn fixture_parser_matches_git_config_blob_null_oracle() {
        let repository = fixture_repo("sha1-submodules.git");
        let (store, snapshot) = fixture("sha1-submodules.git", "sha1_submodules_head");
        let root =
            read_tree_entries_for_walk(&store, snapshot.tree_oid, &Budget::unlimited(), false)
                .unwrap();
        let entry = root
            .iter()
            .find(|entry| entry.name == GITMODULES_PATH)
            .expect("fixture has .gitmodules");
        let mut payload = Vec::new();
        assert_eq!(
            store
                .try_find(&entry.oid, &mut payload, &Budget::unlimited())
                .unwrap(),
            Some(ObjectKind::Blob)
        );

        let mut actual = config_entries(&payload).expect("our parser accepts fixture");
        let output = Command::new("git")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_SYSTEM", "/dev/null")
            .env("LC_ALL", "C")
            .args([
                "-C",
                repository.to_str().expect("fixture path is UTF-8"),
                "config",
                "--blob",
                &entry.oid.to_hex(),
                "--list",
                "--null",
            ])
            .output()
            .expect("git config oracle runs");
        assert!(
            output.status.success(),
            "git config failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let mut oracle = output
            .stdout
            .split(|byte| *byte == 0)
            .filter(|record| !record.is_empty())
            .map(|record| {
                let separator = record
                    .iter()
                    .position(|byte| *byte == b'\n')
                    .expect("--null --list record separates key and value");
                (
                    record[..separator].to_vec(),
                    record[separator + 1..].to_vec(),
                )
            })
            .collect::<Vec<_>>();
        actual.sort();
        oracle.sort();
        assert_eq!(actual, oracle);
    }

    #[test]
    fn malformed_fixture_matches_git_config_blob_rejection() {
        let repository = fixture_repo("sha1-submodules.git");
        let (store, snapshot) = fixture("sha1-submodules.git", "sha1_submodules_malformed");
        let root =
            read_tree_entries_for_walk(&store, snapshot.tree_oid, &Budget::unlimited(), false)
                .unwrap();
        let entry = root
            .iter()
            .find(|entry| entry.name == GITMODULES_PATH)
            .expect("fixture has .gitmodules");
        let mut payload = Vec::new();
        assert_eq!(
            store
                .try_find(&entry.oid, &mut payload, &Budget::unlimited())
                .unwrap(),
            Some(ObjectKind::Blob)
        );
        assert_eq!(
            parse_config(&payload)
                .expect_err("our parser rejects fixture")
                .code,
            ErrorCode::MalformedObject
        );

        let output = Command::new("git")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_SYSTEM", "/dev/null")
            .env("LC_ALL", "C")
            .args([
                "-C",
                repository.to_str().expect("fixture path is UTF-8"),
                "config",
                "--blob",
                &entry.oid.to_hex(),
                "--list",
                "--null",
            ])
            .output()
            .expect("git config oracle runs");
        assert!(
            !output.status.success(),
            "Git unexpectedly accepted fixture"
        );
        assert!(
            output
                .stderr
                .starts_with(b"error: bad config line 1 in blob "),
            "unexpected Git error: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    fn config_entries(payload: &[u8]) -> Result<Vec<ConfigEntry>, Error> {
        let config = parse_config(payload)?;
        let mut entries = Vec::new();
        for section in config.sections() {
            let header = section.header();
            if !header.name().eq_ignore_ascii_case(b"submodule") {
                continue;
            }
            let Some(name) = header.subsection_name() else {
                continue;
            };
            for key in CONFIG_KEYS {
                let Some(value) = section.value_implicit(key) else {
                    continue;
                };
                let mut full_key = b"submodule.".to_vec();
                full_key.extend_from_slice(name);
                full_key.push(b'.');
                full_key.extend_from_slice(key.as_bytes());
                entries.push((
                    full_key,
                    value.map_or_else(|| b"true".to_vec(), |value| value.to_vec()),
                ));
            }
        }
        Ok(entries)
    }
}
