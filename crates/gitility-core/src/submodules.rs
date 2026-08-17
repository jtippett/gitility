//! Bounded `.gitmodules` parsing and gitlink correlation.
//!
//! The query reads only the snapshot's root `.gitmodules` blob and tree
//! objects needed to enumerate gitlinks. Declaration paths and URLs remain
//! inert correlation bytes: they are never resolved against a filesystem or
//! network. A gitlink's commit object is never opened or traversed.

use crate::budget::Budget;
use crate::error::{Error, ErrorCode, ErrorFile};
use crate::git_config;
use crate::object::{ObjectKind, Oid};
use crate::odb::ObjectDb;
use crate::snapshot::Snapshot;
use crate::tree::{
    ensure_query_compatible, join_path, read_tree_entries_for_walk, OwnedTreeEntry, TreeItemKind,
};
use std::collections::BTreeMap;

const GITMODULES_PATH: &[u8] = b".gitmodules";
const MAX_GITMODULES_BYTES: usize = 1024 * 1024;

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

#[derive(Debug, Clone, PartialEq, Eq)]
struct Declaration {
    name: Vec<u8>,
    path: Vec<u8>,
    url: Option<Vec<u8>>,
    branch: Option<Vec<u8>>,
}

#[derive(Debug, Default)]
struct PendingDeclaration {
    path: Option<Vec<u8>>,
    url: Option<Vec<u8>>,
    branch: Option<Vec<u8>>,
}

/// Returns the snapshot's declared and actual submodules in ascending raw-path
/// order.
///
/// `.gitmodules` is parsed with the byte grammar of Git 2.55.0's config blob
/// reader. Includes are deliberately not followed. Declarations with no
/// valued `path` are ignored; all valued paths, including empty, absolute,
/// parent-relative, and trailing-slash forms, remain inert bytes. A non-blob
/// root `.gitmodules` entry is treated as absent. (Git separately refuses a
/// symlinked `.gitmodules` in a working tree after CVE-2018-11235.)
///
/// Correlation walks the full snapshot without pagination and is bounded by
/// the caller's object/tree-entry limits. When names collide on a path, raw
/// name order decides ownership: the first name claims the gitlink and later
/// declarations are orphaned. Empty paths sort before non-empty paths.
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
        let path = declaration.path;
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
        return Ok(Vec::new());
    }

    let header = store
        .try_header(&entry.oid, budget)
        .map_err(name_gitmodules_error)?
        .ok_or_else(|| missing_gitmodules(entry.oid))?;
    if header.kind != ObjectKind::Blob {
        return Ok(Vec::new());
    }
    if header.size > MAX_GITMODULES_BYTES as u64 {
        return Err(gitmodules_too_large());
    }

    let mut payload = Vec::new();
    let kind = store
        .try_find(&entry.oid, &mut payload, budget)
        .map_err(name_gitmodules_error)?
        .ok_or_else(|| missing_gitmodules(entry.oid))?;
    if kind != ObjectKind::Blob {
        return Ok(Vec::new());
    }
    if payload.len() > MAX_GITMODULES_BYTES {
        return Err(gitmodules_too_large());
    }
    parse_declarations(&payload)
}

fn parse_declarations(payload: &[u8]) -> Result<Vec<Declaration>, Error> {
    let mut declarations = BTreeMap::<Vec<u8>, PendingDeclaration>::new();
    git_config::parse(payload, |key, value| {
        let Some((name, field)) = submodule_key(key) else {
            return;
        };
        let declaration = declarations.entry(name.to_vec()).or_default();
        let value = value.map(<[u8]>::to_vec);
        match field {
            b"path" => declaration.path = value,
            b"url" => declaration.url = value,
            b"branch" => declaration.branch = value,
            _ => unreachable!("submodule_key returns only retained fields"),
        }
    })
    .map_err(|error| {
        malformed_gitmodules("snapshot .gitmodules is malformed")
            .with_reason("git_config_parse_error")
            .with_line(error.line)
    })?;

    Ok(declarations
        .into_iter()
        .filter_map(|(name, declaration)| {
            declaration.path.map(|path| Declaration {
                name,
                path,
                url: declaration.url,
                branch: declaration.branch,
            })
        })
        .collect())
}

fn submodule_key(key: &[u8]) -> Option<(&[u8], &[u8])> {
    let rest = key.strip_prefix(b"submodule.")?;
    for field in [b"path".as_slice(), b"url", b"branch"] {
        let suffix_len = field.len().checked_add(1)?;
        if rest.len() >= suffix_len
            && rest[rest.len() - suffix_len] == b'.'
            && &rest[rest.len() - field.len()..] == field
        {
            return Some((&rest[..rest.len() - suffix_len], field));
        }
    }
    None
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

fn missing_gitmodules(oid: Oid) -> Error {
    Error::retryable(
        ErrorCode::MissingObject,
        format!(".gitmodules blob {oid} is missing from the object store"),
    )
    .with_oid(oid)
}

fn gitmodules_too_large() -> Error {
    Error::new(
        ErrorCode::ObjectTooLarge,
        "snapshot .gitmodules exceeds the dedicated 1 MiB config limit",
    )
    .with_limit("max_gitmodules_bytes")
    .with_file(ErrorFile::Gitmodules)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::budget::BudgetLimits;
    use crate::local_odb::LocalOdb;
    use crate::object::HashKind;
    use crate::static_odb::StaticOdb;
    use crate::test_support::{fixture_oid, fixture_repo};
    use crate::verify::object_id;
    use std::sync::atomic::AtomicBool;
    use std::sync::Arc;

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
    fn parser_handles_case_comments_quotes_continuations_and_retained_keys() {
        let payload = br#"
            ; comment
            [SuBmOdUlE "CaseSensitive"]
              PaTh = "sub/space path"
              URL = "ssh://host/a\\b#kept" # comment
              BrAnCh = feature/\
v2
              ; update and shallow are valid config but intentionally dead
              UPDATE = rebase
              shallow = true
        "#;
        let declarations = parse_declarations(payload).expect("Git config parses");
        assert_eq!(declarations.len(), 1);
        let declaration = &declarations[0];
        assert_eq!(declaration.name, b"CaseSensitive");
        assert_eq!(declaration.path, b"sub/space path");
        assert_eq!(
            declaration.url.as_deref(),
            Some(b"ssh://host/a\\b#kept".as_slice())
        );
        assert_eq!(
            declaration.branch.as_deref(),
            Some(b"feature/v2".as_slice())
        );
    }

    #[test]
    fn declarations_degrade_independently_and_paths_are_inert_bytes() {
        let payload = br#"
            [submodule "missing"]
              url = ignored-without-path
            [submodule "valueless"]
              path
            [submodule "cleared"]
              path = first
              path
            [submodule "empty"]
              path = ""
            [submodule "parent"]
              path = ../evil
            [submodule "absolute"]
              path = /etc/passwd
            [submodule "slash"]
              path = trailing/
        "#;
        let declarations = parse_declarations(payload).expect("Git config accepts inert paths");
        assert_eq!(
            declarations
                .iter()
                .map(|declaration| (declaration.name.as_slice(), declaration.path.as_slice()))
                .collect::<Vec<_>>(),
            [
                (b"absolute".as_slice(), b"/etc/passwd".as_slice()),
                (b"empty".as_slice(), b"".as_slice()),
                (b"parent".as_slice(), b"../evil".as_slice()),
                (b"slash".as_slice(), b"trailing/".as_slice()),
            ]
        );
    }

    #[test]
    fn parser_matches_dotted_case_nul_and_last_wins_semantics() {
        // The oracle's `--null` framing cannot carry NUL-bearing values
        // unambiguously, so these cases are asserted only through our API.
        let payload = b"[submodule.Name]\npath=first\n\
            [submodule \"name\"]\npath=second\nurl=old\nurl=new\n\
            [submodule \"Name\"]\npath=upper\n\
            [submodule \"nul-name\0ignored\"]\npath=gone\n\
            [submodule \"nul-value\"]\npath=kept\0ignored\n";
        let declarations = parse_declarations(payload).expect("NUL-bearing config parses");
        assert_eq!(declarations.len(), 3);
        assert_eq!(declarations[0].name, b"Name");
        assert_eq!(declarations[0].path, b"upper");
        assert_eq!(declarations[1].name, b"name");
        assert_eq!(declarations[1].path, b"second");
        assert_eq!(declarations[1].url.as_deref(), Some(b"new".as_slice()));
        assert_eq!(declarations[2].name, b"nul-value");
        assert_eq!(declarations[2].path, b"kept");
    }

    #[test]
    fn malformed_config_reports_gits_one_based_line() {
        let error = parse_declarations(b"[core]\nkey=value\nnot a value\n")
            .expect_err("bad config line fails");
        assert_eq!(error.code, ErrorCode::MalformedObject);
        assert_eq!(error.file, Some(ErrorFile::Gitmodules));
        assert_eq!(error.line(), Some(3));
    }

    #[test]
    fn include_directives_are_ignored_without_external_io() {
        // Never send this fixture to `git config --blob`: that command follows
        // includes, unlike Git's real `.gitmodules` machinery and this API.
        let payload = b"[include]\npath=/definitely/not/read\n\
            [submodule \"safe\"]\npath=module\n";
        let declarations = parse_declarations(payload).expect("include syntax is valid config");
        assert_eq!(declarations.len(), 1);
        assert_eq!(declarations[0].name, b"safe");
        assert_eq!(declarations[0].path, b"module");
    }

    #[test]
    fn name_collision_uses_raw_name_order_to_claim_the_gitlink() {
        let config = b"[submodule \"zeta\"]\npath=module\n\
            [submodule \"alpha\"]\npath=module\n";
        let gitlink = Oid::new(HashKind::Sha1, &[7; 20]).expect("gitlink oid");
        let (store, snapshot) = snapshot_store(config, &[(0o160000, b"module", gitlink)]);
        let rows = submodules(&store, &snapshot, &Budget::unlimited()).expect("correlation works");
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].name.as_deref(), Some(b"alpha".as_slice()));
        assert_eq!(rows[0].status, SubmoduleStatus::Active);
        assert_eq!(rows[0].commit_oid, Some(gitlink));
        assert_eq!(rows[1].name.as_deref(), Some(b"zeta".as_slice()));
        assert_eq!(rows[1].status, SubmoduleStatus::Orphaned);
        assert_eq!(rows[1].commit_oid, None);
    }

    #[test]
    fn empty_path_is_an_orphan_sorted_before_undeclared_gitlinks() {
        let config = b"[submodule \"empty\"]\npath=\n";
        let gitlink = Oid::new(HashKind::Sha1, &[8; 20]).expect("gitlink oid");
        let (store, snapshot) = snapshot_store(config, &[(0o160000, b"module", gitlink)]);
        let rows = submodules(&store, &snapshot, &Budget::unlimited()).expect("correlation works");
        assert_eq!(rows.len(), 2);
        assert!(rows[0].path.is_empty());
        assert_eq!(rows[0].status, SubmoduleStatus::Orphaned);
        assert_eq!(rows[1].path, b"module");
        assert_eq!(rows[1].status, SubmoduleStatus::Undeclared);
    }

    #[test]
    fn non_blob_gitmodules_entries_and_objects_are_absent() {
        let oid = object_id(HashKind::Sha1, ObjectKind::Blob, b"target").expect("blob hashes");
        let store =
            StaticOdb::from_objects(HashKind::Sha1, [(ObjectKind::Blob, b"target".to_vec())])
                .expect("store loads");
        for kind in [
            TreeItemKind::Tree,
            TreeItemKind::Symlink,
            TreeItemKind::Gitlink,
        ] {
            let root = [OwnedTreeEntry {
                mode: 0,
                name: GITMODULES_PATH.to_vec(),
                oid,
                kind,
            }];
            assert_eq!(
                read_declarations(&store, &root, &Budget::unlimited()).unwrap(),
                []
            );
        }

        let tree_oid = object_id(HashKind::Sha1, ObjectKind::Tree, b"").expect("tree hashes");
        let store = StaticOdb::from_objects(HashKind::Sha1, [(ObjectKind::Tree, Vec::new())])
            .expect("tree store loads");
        let root = [OwnedTreeEntry {
            mode: 0o100644,
            name: GITMODULES_PATH.to_vec(),
            oid: tree_oid,
            kind: TreeItemKind::Blob,
        }];
        assert_eq!(
            read_declarations(&store, &root, &Budget::unlimited()).unwrap(),
            []
        );
    }

    #[test]
    fn malformed_and_oversize_gitmodules_name_the_metadata_file() {
        let (store, malformed_snapshot) =
            fixture("sha1-submodules.git", "sha1_submodules_malformed");
        let malformed = submodules(&store, &malformed_snapshot, &Budget::unlimited())
            .expect_err("malformed config fails");
        assert_eq!(malformed.code, ErrorCode::MalformedObject);
        assert_eq!(malformed.file, Some(ErrorFile::Gitmodules));
        assert_eq!(malformed.line(), Some(1));

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
    fn dedicated_gitmodules_cap_is_independent_of_the_object_budget() {
        let payload = vec![b'#'; MAX_GITMODULES_BYTES + 1];
        let oid = object_id(HashKind::Sha1, ObjectKind::Blob, &payload).expect("blob hashes");
        let store = StaticOdb::from_objects(HashKind::Sha1, [(ObjectKind::Blob, payload)])
            .expect("store loads");
        let root = [OwnedTreeEntry {
            mode: 0o100644,
            name: GITMODULES_PATH.to_vec(),
            oid,
            kind: TreeItemKind::Blob,
        }];
        let error = read_declarations(&store, &root, &Budget::unlimited())
            .expect_err("dedicated cap rejects hostile config");
        assert_eq!(error.code, ErrorCode::ObjectTooLarge);
        assert_eq!(error.limit, Some("max_gitmodules_bytes"));
        assert_eq!(error.file, Some(ErrorFile::Gitmodules));
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

    fn snapshot_store(config: &[u8], extra_entries: &[(u32, &[u8], Oid)]) -> (StaticOdb, Snapshot) {
        fn tree_payload(entries: &[(u32, &[u8], Oid)]) -> Vec<u8> {
            let mut payload = Vec::new();
            for (mode, name, oid) in entries {
                payload.extend_from_slice(format!("{mode:o} ").as_bytes());
                payload.extend_from_slice(name);
                payload.push(0);
                payload.extend_from_slice(oid.as_bytes());
            }
            payload
        }

        let config_oid =
            object_id(HashKind::Sha1, ObjectKind::Blob, config).expect("config hashes");
        let mut entries = vec![(0o100644, GITMODULES_PATH, config_oid)];
        entries.extend_from_slice(extra_entries);
        entries.sort_by(|left, right| left.1.cmp(right.1));
        let tree = tree_payload(&entries);
        let tree_oid = object_id(HashKind::Sha1, ObjectKind::Tree, &tree).expect("tree hashes");
        let store = StaticOdb::from_objects(
            HashKind::Sha1,
            [
                (ObjectKind::Blob, config.to_vec()),
                (ObjectKind::Tree, tree),
            ],
        )
        .expect("snapshot store loads");
        (
            store,
            Snapshot {
                commit_oid: tree_oid,
                tree_oid,
            },
        )
    }
}
