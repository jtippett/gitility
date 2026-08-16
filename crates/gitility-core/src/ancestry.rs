//! Budgeted merge-base and ancestry queries over any object database.

use crate::budget::Budget;
use crate::commit_graph::{ensure_sha1, from_gix_oid, to_gix_oid, GixFind};
use crate::error::{Error, ErrorCode};
use crate::object::Oid;
use crate::odb::ObjectDb;

/// Returns every best common ancestor of `left` and `right`.
///
/// The result is sorted by descending object-ID bytes so callers and
/// differential tests never inherit hash-table or heap tie behavior.
pub fn merge_base(
    store: &dyn ObjectDb,
    left: Oid,
    right: Oid,
    budget: &Budget,
) -> Result<Vec<Oid>, Error> {
    ensure_sha1(store, &[left, right])?;
    budget.check()?;
    let reader = GixFind::new(store, budget);
    reader.validate_commit(left)?;
    reader.validate_commit(right)?;

    let mut graph = gix_revision::Graph::<
        gix_revision::graph::Commit<gix_revision::merge_base::Flags>,
    >::new(reader.clone(), None);
    let bases = gix_revision::merge_base(to_gix_oid(left)?, &[to_gix_oid(right)?], &mut graph)
        .map_err(|_| {
            reader.error_or(
                ErrorCode::MalformedObject,
                "merge-base traversal could not decode a commit",
            )
        })?;
    budget.check()?;
    let mut bases = bases
        .map(Vec::from)
        .unwrap_or_default()
        .into_iter()
        .map(|oid| from_gix_oid(oid.as_ref()))
        .collect::<Result<Vec<_>, _>>()?;
    bases.sort_unstable_by(|left, right| right.cmp(left));
    Ok(bases)
}

/// Returns whether `ancestor` is reachable from `descendant`, using the same
/// best-common-ancestor machinery as [`merge_base`].
pub fn is_ancestor(
    store: &dyn ObjectDb,
    ancestor: Oid,
    descendant: Oid,
    budget: &Budget,
) -> Result<bool, Error> {
    Ok(merge_base(store, ancestor, descendant, budget)? == [ancestor])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::local_odb::LocalOdb;
    use crate::object::{HashKind, ObjectKind};
    use crate::static_odb::StaticOdb;
    use crate::test_support::{fixture_oid, fixture_repo};
    use crate::verify::object_id;
    use std::process::Command;

    fn commit(tree: Oid, parents: &[Oid], time: i64) -> (Oid, ObjectKind, Vec<u8>) {
        let mut payload = format!("tree {}\n", tree.to_hex()).into_bytes();
        for parent in parents {
            payload.extend_from_slice(format!("parent {}\n", parent.to_hex()).as_bytes());
        }
        payload.extend_from_slice(
            format!(
                "author A <a@example.invalid> {time} +0000\ncommitter C <c@example.invalid> {time} +0000\n\ncommit {time}\n"
            )
            .as_bytes(),
        );
        let oid =
            object_id(HashKind::Sha1, ObjectKind::Commit, &payload).expect("test commit hashes");
        (oid, ObjectKind::Commit, payload)
    }

    #[test]
    fn finds_both_criss_cross_bases_and_answers_ancestry_edges() {
        let tree = object_id(HashKind::Sha1, ObjectKind::Tree, &[]).expect("tree hashes");
        let root_object = commit(tree, &[], 1);
        let root = root_object.0;
        let left_object = commit(tree, &[root], 2);
        let left = left_object.0;
        let right_object = commit(tree, &[root], 3);
        let right = right_object.0;
        let merge_left_object = commit(tree, &[left, right], 4);
        let merge_left = merge_left_object.0;
        let merge_right_object = commit(tree, &[right, left], 5);
        let merge_right = merge_right_object.0;
        let store = StaticOdb::from_addressed_objects(
            HashKind::Sha1,
            [
                root_object,
                left_object,
                right_object,
                merge_left_object,
                merge_right_object,
            ],
        )
        .expect("graph loads");

        let mut expected = vec![left, right];
        expected.sort_unstable_by(|left, right| right.cmp(left));
        assert_eq!(
            merge_base(&store, merge_left, merge_right, &Budget::unlimited())
                .expect("merge bases resolve"),
            expected
        );
        assert!(is_ancestor(&store, root, merge_left, &Budget::unlimited())
            .expect("ancestor query succeeds"));
        assert!(
            !is_ancestor(&store, merge_left, merge_right, &Budget::unlimited())
                .expect("non-ancestor query succeeds")
        );
        assert!(is_ancestor(&store, left, left, &Budget::unlimited())
            .expect("identical commit is its own ancestor"));
    }

    #[test]
    fn disjoint_histories_are_empty_and_false() {
        let tree = object_id(HashKind::Sha1, ObjectKind::Tree, &[]).expect("tree hashes");
        let left_object = commit(tree, &[], 1);
        let left = left_object.0;
        let right_object = commit(tree, &[], 2);
        let right = right_object.0;
        let store = StaticOdb::from_addressed_objects(HashKind::Sha1, [left_object, right_object])
            .expect("disjoint graph loads");
        assert!(merge_base(&store, left, right, &Budget::unlimited())
            .expect("disjoint merge-base succeeds")
            .is_empty());
        assert!(!is_ancestor(&store, left, right, &Budget::unlimited())
            .expect("disjoint ancestor query succeeds"));
    }

    #[test]
    fn a_missing_parent_is_not_treated_as_disjoint_history() {
        let tree = object_id(HashKind::Sha1, ObjectKind::Tree, &[]).expect("tree hashes");
        let missing = Oid::new(HashKind::Sha1, &[7; 20]).expect("missing ID is valid");
        let left_object = commit(tree, &[missing], 2);
        let left = left_object.0;
        let right_object = commit(tree, &[], 3);
        let right = right_object.0;
        let store = StaticOdb::from_addressed_objects(HashKind::Sha1, [left_object, right_object])
            .expect("hole-punched graph loads");
        let error = merge_base(&store, left, right, &Budget::unlimited())
            .expect_err("missing parent fails");
        assert_eq!(error.code, ErrorCode::MissingObject);
        assert!(error.message.contains(&missing.to_hex()));
        assert_eq!(error.object_oid, Some(missing));
    }

    #[test]
    fn generated_graph_matches_git_merge_base_sets_and_ancestry() {
        let repository = fixture_repo("sha1-graph.git");
        let (store, _) =
            LocalOdb::open(&repository, Default::default()).expect("graph fixture opens");
        let cases = [
            (
                fixture_oid("sha1_graph_criss_left"),
                fixture_oid("sha1_graph_criss_right"),
            ),
            (
                fixture_oid("sha1_graph_octopus"),
                fixture_oid("sha1_graph_head"),
            ),
            (
                fixture_oid("sha1_graph_head"),
                fixture_oid("sha1_graph_disjoint"),
            ),
            (
                fixture_oid("sha1_graph_octopus"),
                fixture_oid("sha1_graph_octopus"),
            ),
        ];

        for (left, right) in cases {
            let mut expected = git_merge_bases(&repository, left, right);
            expected.sort_unstable_by(|left, right| right.cmp(left));
            assert_eq!(
                merge_base(&store, left, right, &Budget::unlimited())
                    .expect("core merge-base succeeds"),
                expected
            );

            let status = Command::new("git")
                .args(["-C"])
                .arg(&repository)
                .args([
                    "merge-base",
                    "--is-ancestor",
                    &left.to_hex(),
                    &right.to_hex(),
                ])
                .env("GIT_CONFIG_GLOBAL", "/dev/null")
                .env("GIT_CONFIG_SYSTEM", "/dev/null")
                .status()
                .expect("canonical Git ancestry runs");
            let expected_ancestor = match status.code() {
                Some(0) => true,
                Some(1) => false,
                code => panic!("canonical Git ancestry failed with {code:?}"),
            };
            assert_eq!(
                is_ancestor(&store, left, right, &Budget::unlimited())
                    .expect("core ancestry succeeds"),
                expected_ancestor
            );
        }

        let left = fixture_oid("sha1_graph_criss_left");
        let right = fixture_oid("sha1_graph_criss_right");
        let core_first = merge_base(&store, left, right, &Budget::unlimited())
            .expect("core criss-cross merge-base succeeds")[0];
        let git_first = git_merge_bases_default(&repository, left, right)[0];
        assert_ne!(
            core_first, git_first,
            "the required descending-OID default intentionally differs from Git's unspecified first criss-cross base"
        );
    }

    fn git_merge_bases(repository: &std::path::Path, left: Oid, right: Oid) -> Vec<Oid> {
        git_merge_bases_with_args(repository, &["merge-base", "--all"], left, right)
    }

    fn git_merge_bases_default(repository: &std::path::Path, left: Oid, right: Oid) -> Vec<Oid> {
        git_merge_bases_with_args(repository, &["merge-base"], left, right)
    }

    fn git_merge_bases_with_args(
        repository: &std::path::Path,
        arguments: &[&str],
        left: Oid,
        right: Oid,
    ) -> Vec<Oid> {
        let output = Command::new("git")
            .args(["-C"])
            .arg(repository)
            .args(arguments)
            .args([left.to_hex(), right.to_hex()])
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_SYSTEM", "/dev/null")
            .output()
            .expect("canonical Git merge-base runs");
        assert!(
            matches!(output.status.code(), Some(0 | 1)),
            "canonical Git merge-base completes normally"
        );
        String::from_utf8(output.stdout)
            .expect("Git object IDs are ASCII")
            .lines()
            .map(|line| Oid::parse_hex(line).expect("Git returned a full object ID"))
            .collect()
    }
}
