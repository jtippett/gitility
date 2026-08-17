#!/usr/bin/env bash
set -euo pipefail

case "${BASH_SOURCE[0]}" in
  */*) script_parent="${BASH_SOURCE[0]%/*}" ;;
  *) script_parent=. ;;
esac
script_dir="$(cd "$script_parent" && pwd)"
output_dir="$script_dir/generated"
corrupt_helper="$script_dir/corrupt.py"
checksum_helper="$script_dir/checksums.py"
generator_hash="$(git hash-object "$script_dir/generate.sh")"

for command in awk cat chmod cmp cp dd env find git grep ln mkdir mktemp mv python3 rm seq wc; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'error: fixture generation requires %s\n' "$command" >&2
    exit 1
  fi
done

scratch_root="${TMPDIR:-/tmp}"
scratch_dir="$(mktemp -d "$scratch_root/gitility-fixtures.XXXXXX")"
previous_oids="$scratch_dir/previous-oids"
previous_checksums="$scratch_dir/previous-checksums"
output_started=false

cleanup() {
  local status=$?

  trap - EXIT

  if ((status != 0)) && [[ "$output_started" == true ]]; then
    case "$output_dir" in
      "$script_dir/generated") rm -rf -- "$output_dir" ;;
      *) printf 'error: refusing to remove unexpected output path: %s\n' "$output_dir" >&2 ;;
    esac
  fi

  case "$scratch_dir" in
    "$scratch_root"/gitility-fixtures.*) rm -rf -- "$scratch_dir" ;;
    *) printf 'error: refusing to remove unexpected scratch path: %s\n' "$scratch_dir" >&2 ;;
  esac

  exit "$status"
}
trap cleanup EXIT

git_version="$(git version | awk '{print $3}')"
version_core="${git_version%%[^0-9.]*}"
version_major="${version_core%%.*}"
version_tail="${version_core#*.}"
version_minor="${version_tail%%.*}"

if [[ ! "$version_major" =~ ^[0-9]+$ || ! "$version_minor" =~ ^[0-9]+$ ]] ||
  ((version_major < 2 || (version_major == 2 && version_minor < 42))); then
  printf 'error: SHA-256 fixtures require Git >= 2.42; found %s\n' "$git_version" >&2
  exit 1
fi

if [[ -f "$output_dir/GENERATOR_HASH" ]] &&
  [[ "$(cat "$output_dir/GENERATOR_HASH")" == "$generator_hash" ]] &&
  [[ -f "$output_dir/OIDS" ]]; then
  cp "$output_dir/OIDS" "$previous_oids"
fi
if [[ -s "$previous_oids" ]] && [[ -f "$output_dir/CHECKSUMS" ]]; then
  cp "$output_dir/CHECKSUMS" "$previous_checksums"
fi

output_started=true
case "$output_dir" in
  "$script_dir/generated") rm -rf -- "$output_dir" ;;
  *)
    printf 'error: refusing to replace unexpected output path: %s\n' "$output_dir" >&2
    exit 1
    ;;
esac
mkdir -p "$output_dir"

export GIT_AUTHOR_NAME='Gitility Fixture'
export GIT_AUTHOR_EMAIL='fixtures@gitility.invalid'
export GIT_AUTHOR_DATE='2001-01-01T00:00:00+0000'
export GIT_COMMITTER_NAME='Gitility Fixture'
export GIT_COMMITTER_EMAIL='fixtures@gitility.invalid'
export GIT_COMMITTER_DATE='2001-01-01T00:00:00+0000'
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_TERMINAL_PROMPT=0
export LC_ALL=C
export TZ=UTC
umask 022

init_work_repo() {
  local repository=$1
  local object_format=$2

  git init --quiet --initial-branch=main --object-format="$object_format" --template= "$repository"
  git -C "$repository" config core.autocrlf false
  git -C "$repository" config core.filemode true
  git -C "$repository" config commit.gpgSign false
  git -C "$repository" config tag.gpgSign false
}

init_bare_repo() {
  local repository=$1
  local object_format=$2

  git init --quiet --bare --initial-branch=main --object-format="$object_format" --template= \
    "$repository"
  git -C "$repository" config receive.unpackLimit 1000
}

commit_all_at() {
  local repository=$1
  local timestamp=$2
  local message=$3

  git -C "$repository" add --all
  env GIT_AUTHOR_DATE="$timestamp" GIT_COMMITTER_DATE="$timestamp" \
    git -C "$repository" commit --quiet -m "$message"
}

commit_as_at() {
  local repository=$1
  local timestamp=$2
  local author_name=$3
  local author_email=$4
  local message=$5

  git -C "$repository" add --all
  env GIT_AUTHOR_NAME="$author_name" GIT_AUTHOR_EMAIL="$author_email" \
    GIT_AUTHOR_DATE="$timestamp" GIT_COMMITTER_NAME="$author_name" \
    GIT_COMMITTER_EMAIL="$author_email" GIT_COMMITTER_DATE="$timestamp" \
    git -C "$repository" commit --quiet -m "$message"
}

merge_at() {
  local repository=$1
  local timestamp=$2
  local other=$3
  local message=$4

  env GIT_AUTHOR_DATE="$timestamp" GIT_COMMITTER_DATE="$timestamp" GIT_MERGE_AUTOEDIT=no \
    git -C "$repository" merge --quiet --no-ff --no-edit -m "$message" "$other"
}

tag_at() {
  local repository=$1
  local timestamp=$2
  local name=$3
  local target=$4

  env GIT_AUTHOR_DATE="$timestamp" GIT_COMMITTER_DATE="$timestamp" \
    git -C "$repository" tag --annotate -m "Fixture tag $name" "$name" "$target"
}

export_bare() {
  local work_repository=$1
  local bare_repository=$2
  local object_format=$3

  init_bare_repo "$bare_repository" "$object_format"
  git -C "$work_repository" push --quiet "$bare_repository" \
    'refs/heads/main:refs/heads/main' 'refs/tags/*:refs/tags/*'
  git -C "$bare_repository" symbolic-ref HEAD refs/heads/main
}

make_basic() {
  local object_format=$1
  local work_repository=$2
  local bare_repository=$3
  local invalid_blob
  local parent_commit
  local base_tree
  local empty_tree
  local modules_tree
  local augmented_tree
  local tree_input
  local final_commit

  init_work_repo "$work_repository" "$object_format"
  mkdir -p "$work_repository/assets" "$work_repository/repeated" \
    "$work_repository/src" "$work_repository/subdir"

  printf '# Gitility fixture\n\nCanonical object-query input.\n' >"$work_repository/README.md"
  : >"$work_repository/empty.bin"
  printf '\000\377\376binary\200payload\n' >"$work_repository/binary.dat"
  awk 'BEGIN { for (i = 0; i < 12050; i++) printf "x"; printf "\n" }' \
    >"$work_repository/long-line.txt"
  dd if=/dev/zero of="$work_repository/assets/large.bin" bs=1024 count=256 2>/dev/null
  printf 'same object, two paths\n' >"$work_repository/repeated/one.txt"
  cp "$work_repository/repeated/one.txt" "$work_repository/repeated/two.txt"
  printf 'first line\nsecond line\nthird line\n' >"$work_repository/src/story.txt"
  printf 'nested fixture\n' >"$work_repository/subdir/nested.txt"
  printf '#!/bin/sh\nprintf "fixture executable\\n"\n' >"$work_repository/run-fixture"
  chmod 755 "$work_repository/run-fixture"
  ln -s subdir/nested.txt "$work_repository/link-to-nested"
  commit_all_at "$work_repository" '2001-01-01T00:00:00+0000' 'Initial byte-oriented tree'

  printf 'fourth line\n' >>"$work_repository/src/story.txt"
  printf 'second commit\n' >"$work_repository/subdir/second.txt"
  commit_all_at "$work_repository" '2001-01-01T00:01:00+0000' 'Extend the basic tree'

  parent_commit="$(git -C "$work_repository" rev-parse HEAD)"
  base_tree="$(git -C "$work_repository" write-tree)"
  empty_tree="$(git -C "$work_repository" mktree </dev/null)"
  modules_tree="$(
    printf '160000 commit %s\texample\000' "$parent_commit" |
      git -C "$work_repository" mktree -z
  )"
  invalid_blob="$(
    printf 'raw path bytes\n' | git -C "$work_repository" hash-object -w --stdin
  )"
  tree_input="$scratch_dir/basic-tree-$object_format"
  git -C "$work_repository" ls-tree -z "$base_tree" >"$tree_input"
  printf '040000 tree %s\tempty-dir\000' "$empty_tree" >>"$tree_input"
  # macOS rejects invalid UTF-8 at the filesystem boundary, so insert the raw
  # paths directly into the tree. printf's octal escapes supply the non-text
  # bytes, and the quote/control path forces Git's quoted-path output parser.
  printf '100644 blob %s\tinvalid-\377-name.txt\000' "$invalid_blob" >>"$tree_input"
  printf '100644 blob %s\tquoted-"\001-name.txt\000' "$invalid_blob" >>"$tree_input"
  printf '040000 tree %s\tmodules\000' "$modules_tree" >>"$tree_input"
  augmented_tree="$(git -C "$work_repository" mktree -z <"$tree_input")"
  final_commit="$(
    env GIT_AUTHOR_DATE='2001-01-01T00:02:00+0000' \
      GIT_COMMITTER_DATE='2001-01-01T00:02:00+0000' \
      git -C "$work_repository" commit-tree "$augmented_tree" -p "$parent_commit" \
      -m 'Add an empty tree and gitlink'
  )"
  git -C "$work_repository" update-ref refs/heads/main "$final_commit" "$parent_commit"

  tag_at "$work_repository" '2001-01-01T00:03:00+0000' v1.0.0 "$final_commit"
  git -C "$work_repository" tag basic-lightweight "$parent_commit"
  export_bare "$work_repository" "$bare_repository" "$object_format"
}

make_history() {
  local work_repository=$1
  local bare_repository=$2
  local root_commit
  local criss_left
  local criss_right
  local candidate

  init_work_repo "$work_repository" sha1
  mkdir -p "$work_repository/docs" "$work_repository/src"
  printf 'exact rename payload\n' >"$work_repository/docs/exact-old.txt"
  : >"$work_repository/docs/guide.txt"
  for line_number in $(seq 1 20); do
    printf 'guide line %02d\n' "$line_number" >>"$work_repository/docs/guide.txt"
  done
  printf 'deleted and restored verbatim\n' >"$work_repository/resurrect.txt"
  printf 'alpha\nbeta\ngamma\ndelta\n' >"$work_repository/src/story.txt"
  commit_all_at "$work_repository" '2001-02-01T00:00:00+0000' 'History root'
  root_commit="$(git -C "$work_repository" rev-parse HEAD)"
  git -C "$work_repository" tag fixture/root "$root_commit"

  git -C "$work_repository" switch --quiet -c left-tip
  mkdir -p "$work_repository/branches"
  printf 'left side\n' >"$work_repository/branches/left.txt"
  commit_all_at "$work_repository" '2001-02-01T00:01:00+0000' 'Left side of criss-cross'

  git -C "$work_repository" switch --quiet -c right-tip "$root_commit"
  mkdir -p "$work_repository/branches"
  printf 'right side\n' >"$work_repository/branches/right.txt"
  commit_all_at "$work_repository" '2001-02-01T00:02:00+0000' 'Right side of criss-cross'

  git -C "$work_repository" switch --quiet -c merge-left left-tip
  merge_at "$work_repository" '2001-02-01T00:03:00+0000' right-tip \
    'Criss-cross merge from the left'
  criss_left="$(git -C "$work_repository" rev-parse HEAD)"
  git -C "$work_repository" tag fixture/criss-left "$criss_left"

  git -C "$work_repository" switch --quiet -c merge-right right-tip
  merge_at "$work_repository" '2001-02-01T00:04:00+0000' left-tip \
    'Criss-cross merge from the right'
  criss_right="$(git -C "$work_repository" rev-parse HEAD)"
  git -C "$work_repository" tag fixture/criss-right "$criss_right"

  git -C "$work_repository" switch --quiet main
  git -C "$work_repository" merge --quiet --ff-only merge-left
  merge_at "$work_repository" '2001-02-01T00:05:00+0000' merge-right \
    'Resolve the criss-cross histories'
  git -C "$work_repository" tag fixture/criss-cross HEAD
  git -C "$work_repository" tag fixture/pre-renames HEAD

  git -C "$work_repository" mv docs/exact-old.txt docs/exact-new.txt
  git -C "$work_repository" mv docs/guide.txt docs/manual.txt
  awk '{ if (NR == 10) print "guide line 10, lightly revised"; else print }' \
    "$work_repository/docs/manual.txt" >"$scratch_dir/manual.txt"
  mv "$scratch_dir/manual.txt" "$work_repository/docs/manual.txt"
  commit_all_at "$work_repository" '2001-02-01T00:06:00+0000' \
    'Apply exact and similarity renames'
  git -C "$work_repository" tag fixture/post-renames HEAD

  printf 'alpha\nbeta revised\ngamma\ndelta\nepsilon\n' >"$work_repository/src/story.txt"
  commit_all_at "$work_repository" '2001-02-01T00:07:00+0000' 'Revise the blamed story'
  git -C "$work_repository" mv src/story.txt src/tale.txt
  commit_all_at "$work_repository" '2001-02-01T00:08:00+0000' 'Rename the blamed story exactly'

  git -C "$work_repository" rm --quiet resurrect.txt
  commit_all_at "$work_repository" '2001-02-01T00:09:00+0000' 'Delete a path'
  git -C "$work_repository" tag fixture/path-deleted HEAD
  printf 'deleted and restored verbatim\n' >"$work_repository/resurrect.txt"
  commit_all_at "$work_repository" '2001-02-01T00:10:00+0000' 'Re-add the deleted path'

  mkdir -p "$work_repository/candidates"
  for candidate in a b c d; do
    cp "$work_repository/docs/manual.txt" "$work_repository/candidates/$candidate.txt"
    printf 'candidate %s distinction\n' "$candidate" \
      >>"$work_repository/candidates/$candidate.txt"
  done
  cp "$work_repository/docs/manual.txt" "$work_repository/docs/manual-copy.txt"
  commit_all_at "$work_repository" '2001-02-01T00:11:00+0000' \
    'Add exact-copy and four-candidate inputs'
  git -C "$work_repository" tag fixture/candidates-before HEAD

  rm "$work_repository/candidates/"*.txt
  printf 'candidate destination\n' >"$work_repository/candidates/selected.txt"
  cat "$work_repository/docs/manual.txt" >>"$work_repository/candidates/selected.txt"
  commit_all_at "$work_repository" '2001-02-01T00:12:00+0000' \
    'Collapse the rename candidate set'
  git -C "$work_repository" tag fixture/candidates-after HEAD

  export_bare "$work_repository" "$bare_repository" sha1
}

make_blame() {
  local work_repository=$1
  local bare_repository=$2
  local root_commit
  local append_commit
  local delete_commit
  local rewrite_commit
  local rename_commit
  local post_rename_commit
  local edited_rename_commit
  local branch_base
  local feature_commit
  local main_commit
  local merge_commit
  local final_commit
  local final_tree
  local final_payload
  local pagination_index
  local pagination_minute

  init_work_repo "$work_repository" sha1
  mkdir -p "$work_repository/docs"
  printf 'alpha\r\nbravo\r\ncharlie\ndelta\necho\n' >"$work_repository/docs/legacy.txt"
  printf 'independent root\n' >"$work_repository/independent.txt"
  commit_as_at "$work_repository" '2001-08-01T00:00:00+0000' \
    'Alice Attribution' 'alice@gitility.invalid' 'Blame root with CRLF lines'
  root_commit="$(git -C "$work_repository" rev-parse HEAD)"
  git -C "$work_repository" tag fixture/blame-root "$root_commit"

  printf 'foxtrot\n' >>"$work_repository/docs/legacy.txt"
  commit_as_at "$work_repository" '2001-08-01T00:01:00+0000' \
    'Bob Bytes' 'bob@gitility.invalid' 'Append one blamed line'
  append_commit="$(git -C "$work_repository" rev-parse HEAD)"
  git -C "$work_repository" tag fixture/blame-append "$append_commit"

  printf 'alpha\r\ncharlie\ndelta\necho\nfoxtrot\n' >"$work_repository/docs/legacy.txt"
  commit_as_at "$work_repository" '2001-08-01T00:02:00+0000' \
    'Cara Committer' 'cara@gitility.invalid' 'Delete one blamed line'
  delete_commit="$(git -C "$work_repository" rev-parse HEAD)"
  git -C "$work_repository" tag fixture/blame-delete "$delete_commit"

  printf 'alpha\r\ncharlie rewritten\ndelta\necho\nfoxtrot\n' \
    >"$work_repository/docs/legacy.txt"
  printf 'independent rewrite marker\n' >>"$work_repository/independent.txt"
  commit_as_at "$work_repository" '2001-08-01T00:03:00+0000' \
    'Alice Attribution' 'alice@gitility.invalid' 'Rewrite the blamed middle'
  rewrite_commit="$(git -C "$work_repository" rev-parse HEAD)"
  git -C "$work_repository" tag fixture/blame-rewrite "$rewrite_commit"

  git -C "$work_repository" mv docs/legacy.txt docs/story.txt
  commit_as_at "$work_repository" '2001-08-01T00:04:00+0000' \
    'Bob Bytes' 'bob@gitility.invalid' 'Rename the blamed file exactly'
  rename_commit="$(git -C "$work_repository" rev-parse HEAD)"
  git -C "$work_repository" tag fixture/blame-rename "$rename_commit"

  printf 'alpha\r\ncharlie rewritten\ndelta\necho revised\nfoxtrot\n' \
    >"$work_repository/docs/story.txt"
  commit_as_at "$work_repository" '2001-08-01T00:05:00+0000' \
    'Cara Committer' 'cara@gitility.invalid' 'Edit after the exact rename'
  post_rename_commit="$(git -C "$work_repository" rev-parse HEAD)"
  git -C "$work_repository" tag fixture/blame-post-rename "$post_rename_commit"

  git -C "$work_repository" mv docs/story.txt docs/final.txt
  printf 'golf\n' >>"$work_repository/docs/final.txt"
  commit_as_at "$work_repository" '2001-08-01T00:06:00+0000' \
    'Alice Attribution' 'alice@gitility.invalid' 'Rename while editing the blamed file'
  edited_rename_commit="$(git -C "$work_repository" rev-parse HEAD)"
  git -C "$work_repository" tag fixture/blame-edited-rename "$edited_rename_commit"
  branch_base="$edited_rename_commit"

  git -C "$work_repository" switch --quiet -c blame-feature
  printf 'alpha feature\r\ncharlie rewritten\ndelta\necho revised\nfoxtrot\ngolf\n' \
    >"$work_repository/docs/final.txt"
  commit_as_at "$work_repository" '2001-08-01T00:07:00+0000' \
    'Bob Bytes' 'bob@gitility.invalid' 'Feature parent touches blamed file'
  feature_commit="$(git -C "$work_repository" rev-parse HEAD)"
  git -C "$work_repository" tag fixture/blame-feature "$feature_commit"

  git -C "$work_repository" switch --quiet main
  test "$(git -C "$work_repository" rev-parse HEAD)" = "$branch_base"
  printf 'alpha\r\ncharlie rewritten\ndelta main\necho revised\nfoxtrot\ngolf\n' \
    >"$work_repository/docs/final.txt"
  commit_as_at "$work_repository" '2001-08-01T00:08:00+0000' \
    'Cara Committer' 'cara@gitility.invalid' 'Main parent touches blamed file'
  main_commit="$(git -C "$work_repository" rev-parse HEAD)"
  git -C "$work_repository" tag fixture/blame-main "$main_commit"

  env GIT_AUTHOR_NAME='Alice Attribution' GIT_AUTHOR_EMAIL='alice@gitility.invalid' \
    GIT_AUTHOR_DATE='2001-08-01T00:09:00+0000' \
    GIT_COMMITTER_NAME='Alice Attribution' GIT_COMMITTER_EMAIL='alice@gitility.invalid' \
    GIT_COMMITTER_DATE='2001-08-01T00:09:00+0000' GIT_MERGE_AUTOEDIT=no \
    git -C "$work_repository" merge --quiet --no-ff --no-edit \
      -m 'Merge both blamed-file edits' blame-feature
  merge_commit="$(git -C "$work_repository" rev-parse HEAD)"
  git -C "$work_repository" tag fixture/blame-merge "$merge_commit"

  printf 'latin-1 ol\351' >>"$work_repository/docs/final.txt"
  git -C "$work_repository" add --all
  final_tree="$(git -C "$work_repository" write-tree)"
  final_payload="$scratch_dir/blame-final-commit"
  printf 'tree %s\nparent %s\nauthor B\351b Bytes <bob@gitility.invalid> 996624600 +0000\ncommitter B\351b Bytes <bob@gitility.invalid> 996624600 +0000\n\nAdd Latin-1 without a trailing newline\n' \
    "$final_tree" "$merge_commit" >"$final_payload"
  final_commit="$(git -C "$work_repository" hash-object -t commit -w --stdin <"$final_payload")"
  git -C "$work_repository" update-ref refs/heads/main "$final_commit" "$merge_commit"
  git -C "$work_repository" tag fixture/blame-final "$final_commit"

  # A separate tagged history keeps the established main/blame OIDs stable
  # while exercising line attribution when every image is classified as
  # binary by the usual first-8-KiB NUL heuristic.
  git -C "$work_repository" switch --quiet -c blame-binary-history
  printf 'alpha\n' >"$work_repository/bin1"
  commit_as_at "$work_repository" '2001-08-01T00:10:00+0000' \
    'Alice Attribution' 'alice@gitility.invalid' 'Add binary-history alpha'
  git -C "$work_repository" tag fixture/blame-bin1-alpha HEAD
  printf 'alpha\nbeta\000nul\n' >"$work_repository/bin1"
  commit_as_at "$work_repository" '2001-08-01T00:11:00+0000' \
    'Bob Bytes' 'bob@gitility.invalid' 'Add binary-history beta'
  git -C "$work_repository" tag fixture/blame-bin1-beta HEAD
  printf 'alpha\nbeta\000nul\ngamma\n' >"$work_repository/bin1"
  commit_as_at "$work_repository" '2001-08-01T00:12:00+0000' \
    'Cara Committer' 'cara@gitility.invalid' 'Add binary-history gamma'
  git -C "$work_repository" tag fixture/blame-bin1-gamma HEAD
  git -C "$work_repository" switch --quiet main

  # Forty-plus emitted commits make late-page replay costs measurable without
  # moving the stable main ref or its OIDS entries.
  git -C "$work_repository" switch --quiet -c blame-history-pagination
  for pagination_index in $(seq 1 45); do
    printf 'pagination revision %02d\n' "$pagination_index" \
      >"$work_repository/page-cost.txt"
    pagination_minute="$(printf '%02d' "$pagination_index")"
    commit_all_at "$work_repository" "2001-08-01T01:${pagination_minute}:00+0000" \
      "Path-history pagination revision $pagination_index"
  done
  git -C "$work_repository" tag fixture/blame-history-pagination-tip HEAD
  git -C "$work_repository" switch --quiet main

  export_bare "$work_repository" "$bare_repository" sha1
  git -C "$bare_repository" fsck --full --strict --no-dangling >/dev/null
  test "$(git -C "$bare_repository" rev-list --count HEAD)" = 11
  test "$(git -C "$bare_repository" rev-list --parents -n 1 fixture/blame-merge | awk '{ print NF }')" = 3
  test "$(git -C "$bare_repository" show fixture/blame-final:docs/final.txt | tail -c 1 | wc -l | awk '{ print $1 }')" = 0
}

make_graph() {
  local work_repository=$1
  local bare_repository=$2
  local root_commit
  local branch_a
  local branch_b
  local branch_c
  local octopus
  local left_side
  local right_side
  local criss_left
  local criss_right
  local resolved
  local skew_child
  local equal_left
  local equal_right
  local equal_merge
  local equal_index
  local disjoint
  local tail_tree
  local tail_parent
  local tail_start
  local tail_middle
  local tail_index
  local tail_epoch

  init_work_repo "$work_repository" sha1
  printf 'commit graph fixture\n' >"$work_repository/graph.txt"
  commit_all_at "$work_repository" '2001-05-01T00:00:00+0000' 'Graph root'
  root_commit="$(git -C "$work_repository" rev-parse HEAD)"
  git -C "$work_repository" tag fixture/graph-root "$root_commit"

  git -C "$work_repository" switch --quiet -c graph-a "$root_commit"
  printf 'branch a\n' >"$work_repository/branch-a.txt"
  commit_all_at "$work_repository" '2001-05-01T00:01:00+0000' 'Graph branch A'
  branch_a="$(git -C "$work_repository" rev-parse HEAD)"
  git -C "$work_repository" tag fixture/branch-a "$branch_a"

  git -C "$work_repository" switch --quiet -c graph-b "$root_commit"
  printf 'branch b\n' >"$work_repository/branch-b.txt"
  commit_all_at "$work_repository" '2001-05-01T00:02:00+0000' 'Graph branch B'
  branch_b="$(git -C "$work_repository" rev-parse HEAD)"
  git -C "$work_repository" tag fixture/branch-b "$branch_b"

  git -C "$work_repository" switch --quiet -c graph-c "$root_commit"
  printf 'branch c\n' >"$work_repository/branch-c.txt"
  commit_all_at "$work_repository" '2001-05-01T00:03:00+0000' 'Graph branch C'
  branch_c="$(git -C "$work_repository" rev-parse HEAD)"
  git -C "$work_repository" tag fixture/branch-c "$branch_c"

  git -C "$work_repository" switch --quiet main
  env GIT_AUTHOR_DATE='2001-05-01T00:04:00+0000' \
    GIT_COMMITTER_DATE='2001-05-01T00:04:00+0000' GIT_MERGE_AUTOEDIT=no \
    git -C "$work_repository" merge --quiet --no-ff --no-edit \
    -m 'Octopus merge of three branches' graph-a graph-b graph-c
  octopus="$(git -C "$work_repository" rev-parse HEAD)"
  git -C "$work_repository" tag fixture/octopus "$octopus"
  tag_at "$work_repository" '2001-05-01T00:05:00+0000' graph-octopus "$octopus"

  git -C "$work_repository" switch --quiet -c criss-left-side "$octopus"
  printf 'criss left\n' >"$work_repository/criss-left.txt"
  commit_all_at "$work_repository" '2001-05-01T00:06:00+0000' 'Criss-cross left side'
  left_side="$(git -C "$work_repository" rev-parse HEAD)"
  git -C "$work_repository" tag fixture/criss-base-left "$left_side"

  git -C "$work_repository" switch --quiet -c criss-right-side "$octopus"
  printf 'criss right\n' >"$work_repository/criss-right.txt"
  commit_all_at "$work_repository" '2001-05-01T00:07:00+0000' 'Criss-cross right side'
  right_side="$(git -C "$work_repository" rev-parse HEAD)"
  git -C "$work_repository" tag fixture/criss-base-right "$right_side"

  git -C "$work_repository" switch --quiet -c criss-left "$left_side"
  merge_at "$work_repository" '2001-05-01T00:08:00+0000' criss-right-side \
    'Criss-cross merge from the left'
  criss_left="$(git -C "$work_repository" rev-parse HEAD)"
  git -C "$work_repository" tag fixture/criss-left "$criss_left"

  git -C "$work_repository" switch --quiet -c criss-right "$right_side"
  merge_at "$work_repository" '2001-05-01T00:09:00+0000' criss-left-side \
    'Criss-cross merge from the right'
  criss_right="$(git -C "$work_repository" rev-parse HEAD)"
  git -C "$work_repository" tag fixture/criss-right "$criss_right"

  git -C "$work_repository" switch --quiet main
  git -C "$work_repository" merge --quiet --ff-only criss-left
  merge_at "$work_repository" '2001-05-01T00:10:00+0000' criss-right \
    'Resolve the criss-cross graph'
  resolved="$(git -C "$work_repository" rev-parse HEAD)"
  git -C "$work_repository" tag fixture/criss-resolved "$resolved"

  printf 'clock skew child\n' >"$work_repository/skew.txt"
  commit_all_at "$work_repository" '2001-04-30T23:00:00+0000' \
    'Clock-skew child earlier than its parent'
  skew_child="$(git -C "$work_repository" rev-parse HEAD)"
  git -C "$work_repository" tag fixture/skew-child "$skew_child"

  git -C "$work_repository" switch --quiet -c equal-left "$skew_child"
  for equal_index in $(seq 1 4); do
    printf 'equal left %s\n' "$equal_index" >>"$work_repository/equal-left.txt"
    commit_all_at "$work_repository" '2001-05-01T00:12:00+0000' \
      "Equal-time left $equal_index"
  done
  equal_left="$(git -C "$work_repository" rev-parse HEAD)"
  git -C "$work_repository" tag fixture/equal-left "$equal_left"

  git -C "$work_repository" switch --quiet -c equal-right "$skew_child"
  for equal_index in $(seq 1 4); do
    printf 'equal right %s\n' "$equal_index" >>"$work_repository/equal-right.txt"
    commit_all_at "$work_repository" '2001-05-01T00:12:00+0000' \
      "Equal-time right $equal_index"
  done
  equal_right="$(git -C "$work_repository" rev-parse HEAD)"
  git -C "$work_repository" tag fixture/equal-right "$equal_right"

  git -C "$work_repository" switch --quiet -c equal-merge "$equal_left"
  merge_at "$work_repository" '2001-05-01T00:13:00+0000' equal-right \
    'Merge the equal-time branches'
  equal_merge="$(git -C "$work_repository" rev-parse HEAD)"
  git -C "$work_repository" tag fixture/equal-merge "$equal_merge"

  git -C "$work_repository" switch --quiet main

  tail_tree="$(git -C "$work_repository" rev-parse HEAD^{tree})"
  disjoint="$(
    env GIT_AUTHOR_DATE='2001-05-01T00:11:00+0000' \
      GIT_COMMITTER_DATE='2001-05-01T00:11:00+0000' \
      git -C "$work_repository" commit-tree "$tail_tree" -m 'Disjoint graph root'
  )"
  git -C "$work_repository" tag fixture/disjoint "$disjoint"

  tail_parent="$skew_child"
  tail_start=''
  tail_middle=''
  tail_epoch=988761600
  for tail_index in $(seq 1 220); do
    tail_parent="$(
      env GIT_AUTHOR_DATE="@$((tail_epoch + tail_index)) +0000" \
        GIT_COMMITTER_DATE="@$((tail_epoch + tail_index)) +0000" \
        git -C "$work_repository" commit-tree "$tail_tree" -p "$tail_parent" \
        -m "Linear tail $tail_index"
    )"
    if ((tail_index == 1)); then
      tail_start="$tail_parent"
    fi
    if ((tail_index == 110)); then
      tail_middle="$tail_parent"
    fi
  done
  git -C "$work_repository" update-ref refs/heads/main "$tail_parent" "$skew_child"
  git -C "$work_repository" tag fixture/tail-start "$tail_start"
  git -C "$work_repository" tag fixture/tail-middle "$tail_middle"
  git -C "$work_repository" tag fixture/tail-tip "$tail_parent"

  export_bare "$work_repository" "$bare_repository" sha1
}

make_lfs_pointer() {
  local work_repository=$1
  local bare_repository=$2

  init_work_repo "$work_repository" sha1
  printf '%s\n%s\n%s\n' \
    'version https://git-lfs.github.com/spec/v1' \
    'oid sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
    'size 12345' >"$work_repository/model.bin"
  commit_all_at "$work_repository" '2001-03-01T00:00:00+0000' 'Add an LFS pointer blob'
  export_bare "$work_repository" "$bare_repository" sha1
}

make_submodules() {
  local work_repository=$1
  local bare_repository=$2
  local base_tree
  local tree_input
  local dir_tree
  local sub_tree
  local augmented_tree
  local head_commit
  local malformed_blob
  local malformed_tree
  local malformed_commit

  init_work_repo "$work_repository" sha1
  mkdir -p "$work_repository/lfs"

  # Exercise Git config's byte-oriented parser rather than a line-oriented
  # approximation: odd case, both comment forms, quoted comment markers and
  # escapes, and a continuation with no indentation (so no whitespace is
  # introduced into the value).
  printf '%s\n' \
    '# leading comment' \
    '[SuBmOdUlE "normal"]' \
    '  PaTh = normal' \
    '  URL = "https://example.invalid/normal.git#fragment" ; trailing comment' \
    '  UpDaTe = checkout' \
    '  ShAlLoW = false' \
    '' \
    '[submodule "Different Name"]' \
    '  path = different' \
    '  url = "../relative path.git"' \
    '' \
    '[submodule "remote"]' \
    '  path = with-url' \
    '  url = "ssh://example.invalid/repo\\path.git"' \
    '  branch = release/\' \
    'v1' \
    '' \
    '; nested gitlink declaration' \
    '[submodule "Nested Name"]' \
    '  path = "sub/dir/mod"' \
    '  url = "https://example.invalid/nested.git"' \
    '' \
    '[submodule "orphaned"]' \
    '  path = orphaned' \
    '  url = "https://example.invalid/orphaned.git"' \
    '' \
    '# Git submodule ignores includes in .gitmodules. This path must never be read.' \
    '[include]' \
    '  path = /definitely/not-read-by-gitility' \
    >"$work_repository/.gitmodules"

  printf '%s\n%s\n%s\n' \
    'version https://git-lfs.github.com/spec/v1' \
    'oid sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
    'size 12345' >"$work_repository/lfs/valid.bin"
  printf '%s\n%s\n%s\n%s\n' \
    'version https://git-lfs.github.com/spec/v1' \
    'x-extra rejected-by-git-lfs-reader' \
    'size 54321' \
    'oid sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789' \
    >"$work_repository/lfs/not-a-pointer.bin"
  printf '%s\n%s\n%s\n' \
    'version https://git-lfs.github.com/spec/v1' \
    'oid sha256:not-a-64-byte-lowercase-hex-digest' \
    'size 7' >"$work_repository/lfs/almost-pointer.bin"
  {
    printf '%s\n%s\n%s\n' \
      'version https://git-lfs.github.com/spec/v1' \
      'oid sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
      'size 12345'
    awk 'BEGIN { printf "x-padding "; for (i = 0; i < 1024; i++) printf "x"; printf "\n" }'
  } >"$work_repository/lfs/over-1024.bin"

  commit_all_at "$work_repository" '2001-08-01T00:00:00+0000' \
    'Add submodule metadata and LFS recognition corpus'
  base_tree="$(git -C "$work_repository" write-tree)"

  dir_tree="$(
    printf '160000 commit %040d\tmod\000' 4 |
      git -C "$work_repository" mktree --missing -z
  )"
  sub_tree="$(
    printf '040000 tree %s\tdir\000' "$dir_tree" |
      git -C "$work_repository" mktree --missing -z
  )"
  tree_input="$scratch_dir/submodules-root-tree"
  git -C "$work_repository" ls-tree -z "$base_tree" >"$tree_input"
  printf '160000 commit %040d\tdifferent\000' 2 >>"$tree_input"
  printf '160000 commit %040d\tnormal\000' 1 >>"$tree_input"
  printf '040000 tree %s\tsub\000' "$sub_tree" >>"$tree_input"
  printf '160000 commit %040d\tundeclared\000' 5 >>"$tree_input"
  printf '160000 commit %040d\twith-url\000' 3 >>"$tree_input"
  augmented_tree="$(git -C "$work_repository" mktree --missing -z <"$tree_input")"
  head_commit="$(
    env GIT_AUTHOR_DATE='2001-08-01T00:01:00+0000' \
      GIT_COMMITTER_DATE='2001-08-01T00:01:00+0000' \
      git -C "$work_repository" commit-tree "$augmented_tree" \
      -m 'Pin active, nested, and undeclared gitlinks'
  )"
  git -C "$work_repository" update-ref refs/heads/main "$head_commit"
  git -C "$work_repository" tag fixture/submodules-head "$head_commit"

  # Keep the same gitlink tree while replacing only .gitmodules with invalid
  # Git config. The oracle below must reject this exact blob.
  git -C "$work_repository" read-tree "$augmented_tree"
  printf '[submodule "broken]\npath = broken\n' >"$work_repository/.gitmodules"
  git -C "$work_repository" add .gitmodules
  malformed_blob="$(git -C "$work_repository" rev-parse :'.gitmodules')"
  malformed_tree="$(git -C "$work_repository" write-tree)"
  malformed_commit="$(
    env GIT_AUTHOR_DATE='2001-08-01T00:02:00+0000' \
      GIT_COMMITTER_DATE='2001-08-01T00:02:00+0000' \
      git -C "$work_repository" commit-tree "$malformed_tree" -p "$head_commit" \
      -m 'Malformed gitmodules probe'
  )"
  git -C "$work_repository" tag fixture/submodules-malformed "$malformed_commit"

  export_bare "$work_repository" "$bare_repository" sha1
  test "$(git -C "$bare_repository" ls-tree -r main | awk '$1 == "160000" { count++ } END { print count + 0 }')" = 5
  test "$(git -C "$bare_repository" rev-parse main:sub/dir/mod)" = "$(printf '%040d' 4)"
  test "$(git -C "$bare_repository" cat-file -s main:lfs/over-1024.bin)" -gt 1024
  test "$(git -C "$bare_repository" config --blob main:.gitmodules --get submodule.remote.branch)" = release/v1
  test "$(git -C "$bare_repository" config --blob main:.gitmodules --get submodule.remote.url)" = 'ssh://example.invalid/repo\path.git'
  if git -C "$bare_repository" config --blob "$malformed_blob" --list >/dev/null 2>&1; then
    printf 'error: canonical Git accepted malformed .gitmodules fixture\n' >&2
    exit 1
  fi
}

make_nested() {
  local work_repository=$1
  local bare_repository=$2

  init_work_repo "$work_repository" sha1
  mkdir -p "$work_repository/lib/gitility/core" \
    "$work_repository/lib/gitility/helpers" \
    "$work_repository/docs/guides" \
    "$work_repository/docs/reference"
  printf 'defmodule Gitility.Core.A do\nend\n' \
    >"$work_repository/lib/gitility/core/a.ex"
  printf 'deep text fixture\n' >"$work_repository/lib/gitility/core/b.txt"
  printf '# Helper notes\n' >"$work_repository/lib/gitility/helpers/notes.md"
  printf 'defmodule Gitility.Util do\nend\n' >"$work_repository/lib/gitility/util.ex"
  printf 'library top-level text\n' >"$work_repository/lib/top.txt"
  printf '# Nested fixture guide\n' >"$work_repository/docs/guides/intro.md"
  printf 'reference text fixture\n' >"$work_repository/docs/reference/api.txt"
  printf '# Nested fixture docs\n' >"$work_repository/docs/README.md"
  printf 'root text fixture\n' >"$work_repository/root.txt"
  commit_all_at "$work_repository" '2001-04-01T00:00:00+0000' \
    'Add a deeply nested mixed-extension tree'
  export_bare "$work_repository" "$bare_repository" sha1
}

make_search() {
  local work_repository=$1
  local bare_repository=$2
  local page_line

  init_work_repo "$work_repository" sha1
  mkdir -p "$work_repository/deep/level/three" \
    "$work_repository/dedup/a" "$work_repository/dedup/b" \
    "$work_repository/dedup/c" "$work_repository/pages"

  printf 'shared needle payload\nsecond line\n' >"$work_repository/dedup/a/shared.txt"
  cp "$work_repository/dedup/a/shared.txt" "$work_repository/dedup/b/shared.txt"
  cp "$work_repository/dedup/a/shared.txt" "$work_repository/dedup/c/shared.txt"
  printf 'deep Needle and needle\n' >"$work_repository/deep/level/three/hit.txt"
  printf '\000binary payload containing needle\n' >"$work_repository/binary-with-needle.dat"
  {
    awk 'BEGIN { for (i = 0; i < 7999; i++) printf "b" }'
    printf '\000needle after binary boundary\n'
  } >"$work_repository/nul-at-7999.dat"
  {
    awk 'BEGIN { for (i = 0; i < 8000; i++) printf "t" }'
    printf '\000needle after text boundary\n'
  } >"$work_repository/nul-at-8000.dat"
  awk 'BEGIN { for (i = 0; i < 8100; i++) printf "x"; printf "\nneedle after byte 8000\n" }' \
    >"$work_repository/after-8000.txt"
  printf 'caf\351 needle latin-1\n' >"$work_repository/latin1.txt"
  printf 'first\r\nneedle on crlf\r\nlast\r\n' >"$work_repository/crlf.txt"
  printf 'needle needle needle needle needle\n' >"$work_repository/many-on-one-line.txt"
  printf 'root pages needle\n' >"$work_repository/pages.txt"
  printf 'caf\303\251 needle utf-8\n' >"$work_repository/utf8-column.txt"
  printf '\tneedle after tab\n' >"$work_repository/tab-column.txt"
  ln -s 'needle-target.txt' "$work_repository/needle-link"
  : >"$work_repository/empty.txt"
  printf 'last line only needle' >"$work_repository/final-no-newline.txt"
  : >"$work_repository/pages/many-lines.txt"
  for page_line in $(seq 1 40); do
    printf 'page %02d needle\n' "$page_line" >>"$work_repository/pages/many-lines.txt"
  done

  commit_all_at "$work_repository" '2001-06-01T00:00:00+0000' \
    'Add deterministic content-search corpus'
  export_bare "$work_repository" "$bare_repository" sha1
  git -C "$bare_repository" fsck --full --strict --no-dangling >/dev/null
}

make_diff() {
  local work_repository=$1
  local bare_repository=$2
  local base_normal
  local head_normal
  local base_tree
  local head_tree
  local base_tree_input
  local head_tree_input
  local raw_base_blob
  local raw_head_blob
  local augmented_base_tree
  local augmented_head_tree
  local base_commit
  local head_commit
  local line_number
  local borderline_score

  init_work_repo "$work_repository" sha1
  mkdir -p "$work_repository/dir/sub" "$work_repository/outside/deep"

  printf 'deleted in head\n' >"$work_repository/delete.txt"
  : >"$work_repository/modify.txt"
  for line_number in $(seq 1 32); do
    printf 'stable middle line %02d\n' "$line_number" >>"$work_repository/modify.txt"
  done
  printf 'identical clean rename payload\n' >"$work_repository/rename-clean-old.txt"
  : >"$work_repository/rename-edit-old.txt"
  for line_number in $(seq 1 30); do
    printf 'rename edit line %02d\n' "$line_number" >>"$work_repository/rename-edit-old.txt"
  done
  : >"$work_repository/rename-borderline-old.txt"
  for line_number in $(seq 1 20); do
    printf 'borderline original %02d\n' "$line_number" \
      >>"$work_repository/rename-borderline-old.txt"
  done
  : >"$work_repository/copy-source.txt"
  for line_number in $(seq 1 20); do
    printf 'copy source line %02d\n' "$line_number" >>"$work_repository/copy-source.txt"
  done
  printf 'mode-only payload\n' >"$work_repository/mode-only.sh"
  printf 'old regular-file target\n' >"$work_repository/type-change"
  printf 'binary-before\000tail\n' >"$work_repository/binary.dat"
  printf 'text before transition\n' >"$work_repository/text-to-binary.dat"
  printf 'first\r\nsecond\r\nthird\r\n' >"$work_repository/crlf.txt"
  printf 'first line\nold eof' >"$work_repository/eof-no-newline.txt"
  printf 'trailing newline toggle' >"$work_repository/trailing-newline.txt"
  printf 'insertion line 1\ninsertion line 2\ninsertion line 3\n' \
    >"$work_repository/mid-insertion.txt"
  ln -s 'old-stable-target' "$work_repository/symlink-stable"
  printf 'pathspec rename payload\n' >"$work_repository/rename-outside-old.txt"
  printf 'scoped old\n' >"$work_repository/dir/sub/modified.txt"
  printf 'scoped delete\n' >"$work_repository/dir/sub/deleted.txt"
  printf 'unscoped tree old\n' >"$work_repository/outside/deep/modified.txt"
  commit_all_at "$work_repository" '2001-07-01T00:00:00+0000' \
    'Structured diff base'
  base_normal="$(git -C "$work_repository" rev-parse HEAD)"

  printf 'added in head\n' >"$work_repository/add.txt"
  rm "$work_repository/delete.txt"
  awk '{ if (NR == 5) print "first separated replacement"; else if (NR == 27) print "second separated replacement"; else print }' \
    "$work_repository/modify.txt" >"$scratch_dir/diff-modify.txt"
  mv "$scratch_dir/diff-modify.txt" "$work_repository/modify.txt"
  git -C "$work_repository" mv rename-clean-old.txt rename-clean-new.txt
  git -C "$work_repository" mv rename-edit-old.txt rename-edit-new.txt
  awk '{ if (NR == 5 || NR == 10 || NR == 15 || NR == 20) printf "rename EDIT line %02d\n", NR; else print }' \
    "$work_repository/rename-edit-new.txt" >"$scratch_dir/diff-rename-edit.txt"
  mv "$scratch_dir/diff-rename-edit.txt" "$work_repository/rename-edit-new.txt"
  git -C "$work_repository" mv rename-borderline-old.txt rename-borderline-new.txt
  awk '{ if (NR <= 10) print; else printf "borderline replaced %02d\n", NR }' \
    "$work_repository/rename-borderline-new.txt" >"$scratch_dir/diff-borderline.txt"
  mv "$scratch_dir/diff-borderline.txt" "$work_repository/rename-borderline-new.txt"
  # Deliberately retain this changed-source copy shape even though copies:true
  # is unsupported in 0.x; it is the regression corpus for a post-1.0 tracker.
  cp "$work_repository/copy-source.txt" "$work_repository/copy-near.txt"
  printf 'copy source changed in place\n' >>"$work_repository/copy-source.txt"
  chmod 755 "$work_repository/mode-only.sh"
  rm "$work_repository/type-change"
  ln -s 'new-symlink-target' "$work_repository/type-change"
  printf 'binary-after\000tail\n' >"$work_repository/binary.dat"
  printf 'now binary\000transition\n' >"$work_repository/text-to-binary.dat"
  printf 'first\r\nSECOND\r\nthird\r\n' >"$work_repository/crlf.txt"
  printf 'first line\nnew eof' >"$work_repository/eof-no-newline.txt"
  printf 'trailing newline toggle\n' >"$work_repository/trailing-newline.txt"
  awk '{ print; if (NR == 2) print "inserted between 2 and 3" }' \
    "$work_repository/mid-insertion.txt" >"$scratch_dir/diff-mid-insertion.txt"
  mv "$scratch_dir/diff-mid-insertion.txt" "$work_repository/mid-insertion.txt"
  rm "$work_repository/symlink-stable"
  ln -s 'new-stable-target' "$work_repository/symlink-stable"
  # The source intentionally lies outside the scoped destination pathspec.
  git -C "$work_repository" mv rename-outside-old.txt dir/sub/rename-inside-new.txt
  : >"$work_repository/empty-added.txt"
  printf 'scoped new\n' >"$work_repository/dir/sub/modified.txt"
  rm "$work_repository/dir/sub/deleted.txt"
  printf 'scoped add\n' >"$work_repository/dir/sub/added.txt"
  printf 'unscoped tree new\n' >"$work_repository/outside/deep/modified.txt"
  commit_all_at "$work_repository" '2001-07-01T00:01:00+0000' \
    'Structured diff head'
  head_normal="$(git -C "$work_repository" rev-parse HEAD)"

  base_tree="$(git -C "$work_repository" rev-parse "$base_normal^{tree}")"
  head_tree="$(git -C "$work_repository" rev-parse "$head_normal^{tree}")"
  raw_base_blob="$(printf 'latin-1 base caf\351\n' | git -C "$work_repository" hash-object -w --stdin)"
  raw_head_blob="$(printf 'latin-1 head ol\351\n' | git -C "$work_repository" hash-object -w --stdin)"
  base_tree_input="$scratch_dir/diff-base-tree"
  head_tree_input="$scratch_dir/diff-head-tree"
  git -C "$work_repository" ls-tree -z "$base_tree" >"$base_tree_input"
  git -C "$work_repository" ls-tree -z "$head_tree" >"$head_tree_input"
  printf '100644 blob %s\tlatin-\351-path.txt\000' "$raw_base_blob" >>"$base_tree_input"
  printf '160000 commit %040d\tsubmodule-bumped\000' 1 >>"$base_tree_input"
  printf '100644 blob %s\tlatin-\351-path.txt\000' "$raw_head_blob" >>"$head_tree_input"
  printf '160000 commit %040d\tsubmodule-added\000' 2 >>"$head_tree_input"
  printf '160000 commit %040d\tsubmodule-bumped\000' 3 >>"$head_tree_input"
  augmented_base_tree="$(git -C "$work_repository" mktree --missing -z <"$base_tree_input")"
  augmented_head_tree="$(git -C "$work_repository" mktree --missing -z <"$head_tree_input")"
  base_commit="$(
    env GIT_AUTHOR_DATE='2001-07-01T00:02:00+0000' \
      GIT_COMMITTER_DATE='2001-07-01T00:02:00+0000' \
      git -C "$work_repository" commit-tree "$augmented_base_tree" \
      -m 'Augment structured diff base with raw and gitlink entries'
  )"
  head_commit="$(
    env GIT_AUTHOR_DATE='2001-07-01T00:03:00+0000' \
      GIT_COMMITTER_DATE='2001-07-01T00:03:00+0000' \
      git -C "$work_repository" commit-tree "$augmented_head_tree" -p "$base_commit" \
      -m 'Augment structured diff head with raw and gitlink entries'
  )"
  git -C "$work_repository" update-ref refs/heads/main "$head_commit" "$head_normal"
  git -C "$work_repository" tag fixture/diff-base "$base_commit"
  git -C "$work_repository" tag fixture/diff-head "$head_commit"

  export_bare "$work_repository" "$bare_repository" sha1
  git -C "$bare_repository" fsck --full --strict --no-dangling >/dev/null
  test "$(git -C "$bare_repository" rev-parse fixture/diff-base)" = "$base_commit"
  test "$(git -C "$bare_repository" rev-parse fixture/diff-head)" = "$head_commit"
  test "$(git -C "$bare_repository" diff-tree -r --no-commit-id --name-only "$base_commit" "$head_commit" -- dir/sub | wc -l | awk '{ print $1 }')" = 4
  borderline_score="$(
    git -C "$bare_repository" diff-tree -r --no-commit-id --name-status -M \
      "$base_commit" "$head_commit" |
      awk '$2 == "rename-borderline-old.txt" && $3 == "rename-borderline-new.txt" { print substr($1, 2) + 0 }'
  )"
  test "$borderline_score" = 50
  test "$(
    git -C "$bare_repository" diff-tree -r --no-commit-id --name-status \
      "$base_commit" "$head_commit" -- symlink-stable |
      awk 'NR == 1 { print $1 }'
  )" = M
}

sha1_work="$scratch_dir/sha1-basic-work"
sha256_work="$scratch_dir/sha256-basic-work"
history_work="$scratch_dir/sha1-history-work"
blame_work="$scratch_dir/sha1-blame-work"
graph_work="$scratch_dir/sha1-graph-work"
lfs_work="$scratch_dir/lfs-pointer-work"
nested_work="$scratch_dir/sha1-nested-work"
search_work="$scratch_dir/sha1-search-work"
diff_work="$scratch_dir/sha1-diff-work"
submodules_work="$scratch_dir/sha1-submodules-work"

make_basic sha1 "$sha1_work" "$output_dir/sha1-basic.git"
make_basic sha256 "$sha256_work" "$output_dir/sha256-basic.git"
make_history "$history_work" "$output_dir/sha1-history.git"
make_blame "$blame_work" "$output_dir/sha1-blame.git"
make_graph "$graph_work" "$output_dir/sha1-graph.git"
make_lfs_pointer "$lfs_work" "$output_dir/lfs-pointer.git"
make_nested "$nested_work" "$output_dir/sha1-nested.git"
make_search "$search_work" "$output_dir/sha1-search.git"
make_diff "$diff_work" "$output_dir/sha1-diff.git"
make_submodules "$submodules_work" "$output_dir/sha1-submodules.git"

# Reference-store fixture: loose/packed overlay precedence, symbolic refs,
# annotated tag-to-tag peeling, raw-byte names, and multi-page enumeration.
cp -R "$output_dir/sha1-basic.git" "$output_dir/sha1-refs.git"
refs_head="$(git -C "$output_dir/sha1-refs.git" rev-parse HEAD)"
refs_parent="$(git -C "$output_dir/sha1-refs.git" rev-parse HEAD^)"
git -C "$output_dir/sha1-refs.git" update-ref refs/heads/packed-only "$refs_head"
git -C "$output_dir/sha1-refs.git" update-ref refs/heads/both "$refs_head"
git -C "$output_dir/sha1-refs.git" update-ref refs/heads/a/b/c "$refs_parent"
git -C "$output_dir/sha1-refs.git" update-ref refs/heads/@ "$refs_head"
for ref_number in $(seq 0 63); do
  git -C "$output_dir/sha1-refs.git" update-ref \
    "refs/heads/page/$(printf '%03d' "$ref_number")" "$refs_head"
done
tag_at "$output_dir/sha1-refs.git" '2001-08-01T00:00:00+0000' refs-base "$refs_head"
tag_at "$output_dir/sha1-refs.git" '2001-08-01T00:01:00+0000' refs-chain refs-base
git -C "$output_dir/sha1-refs.git" pack-refs --all

# Recreate loose entries after packing: packed-only remains only packed;
# loose-only remains only loose; both retains a packed old value shadowed by
# its loose new value.
git -C "$output_dir/sha1-refs.git" update-ref refs/heads/loose-only "$refs_parent"
git -C "$output_dir/sha1-refs.git" update-ref refs/heads/both "$refs_parent"
git -C "$output_dir/sha1-refs.git" symbolic-ref \
  refs/heads/symbolic-main refs/heads/main
raw_ref_name="$(printf 'refs/heads/raw-\377')"
git check-ref-format "$raw_ref_name"
# APFS cannot represent this otherwise-valid name as a loose-ref filename.
# Keep it packed-only and preserve packed-refs byte ordering plus tag peel
# records while inserting it before the first refs/tags entry.
packed_refs="$output_dir/sha1-refs.git/packed-refs"
packed_refs_tmp="$output_dir/sha1-refs.git/packed-refs.gitility-tmp"
raw_ref_inserted=false
: >"$packed_refs_tmp"
while IFS= read -r packed_line; do
  if ! $raw_ref_inserted && [[ "$packed_line" == *" refs/tags/"* ]]; then
    printf '%s %s\n' "$refs_head" "$raw_ref_name" >>"$packed_refs_tmp"
    raw_ref_inserted=true
  fi
  printf '%s\n' "$packed_line" >>"$packed_refs_tmp"
done <"$packed_refs"
if ! $raw_ref_inserted; then
  printf '%s %s\n' "$refs_head" "$raw_ref_name" >>"$packed_refs_tmp"
fi
mv "$packed_refs_tmp" "$packed_refs"

cp -R "$output_dir/sha1-refs.git" "$output_dir/sha1-refs-detached.git"
git -C "$output_dir/sha1-refs-detached.git" update-ref --no-deref HEAD "$refs_parent"
test "$(git -C "$output_dir/sha1-refs.git" rev-parse refs/heads/both)" = "$refs_parent"
test "$(git -C "$output_dir/sha1-refs.git" rev-parse refs-chain^{commit})" = "$refs_head"
test "$(git -C "$output_dir/sha1-refs.git" symbolic-ref refs/heads/symbolic-main)" = \
  refs/heads/main
test "$(git -C "$output_dir/sha1-refs-detached.git" rev-parse HEAD)" = "$refs_parent"

# Fully packed and deliberately mixed object layouts.
cp -R "$output_dir/sha1-basic.git" "$output_dir/sha1-basic-packed.git"
git -C "$output_dir/sha1-basic-packed.git" -c gc.writeCommitGraph=false \
  gc --quiet --prune=now
basic_pack_index="$(find "$output_dir/sha1-basic-packed.git/objects/pack" -name '*.idx' -print -quit)"
basic_pack_last_object="$(
  git verify-pack -v "$basic_pack_index" |
    awk 'length($1) == 40 && $5 ~ /^[0-9]+$/ { if ($5 > max) { max = $5; oid = $1 } } END { print oid }'
)"
if [[ ! "$basic_pack_last_object" =~ ^[0-9a-f]{40}$ ]]; then
  printf 'error: could not identify the last object in the basic pack\n' >&2
  exit 1
fi
cp -R "$output_dir/sha1-basic-packed.git" "$output_dir/sha1-basic-mixed.git"
printf 'intentionally loose after gc\n' |
  git -C "$output_dir/sha1-basic-mixed.git" hash-object -w --stdin >/dev/null

# A multi-pack index over two packs. The second pack holds a deterministic,
# unreachable probe object so repacking cannot coalesce the packs first.
cp -R "$output_dir/sha1-history.git" "$output_dir/sha1-history-midx.git"
git -C "$output_dir/sha1-history-midx.git" -c gc.writeCommitGraph=false repack -a -d --quiet
midx_probe_oid="$(
  printf 'multi-pack-index probe\n' |
    git -C "$output_dir/sha1-history-midx.git" hash-object -w --stdin
)"
printf '%s\n' "$midx_probe_oid" |
  git --git-dir="$output_dir/sha1-history-midx.git" pack-objects \
    "$output_dir/sha1-history-midx.git/objects/pack/pack" >/dev/null
rm -f -- "$output_dir/sha1-history-midx.git/objects/${midx_probe_oid:0:2}/${midx_probe_oid:2}"
git -C "$output_dir/sha1-history-midx.git" multi-pack-index write

# Alternate ODB, shallow-boundary, intentionally missing-object, and replace-ref
# variants cover repository composition and graft-like traversal edges.
cp -R "$output_dir/sha1-basic.git" "$output_dir/sha1-alternate.git"
find "$output_dir/sha1-alternate.git/objects" -type f -delete
mkdir -p "$output_dir/sha1-alternate.git/objects/info"
printf '../../sha1-basic.git/objects\n' \
  >"$output_dir/sha1-alternate.git/objects/info/alternates"

cp -R "$output_dir/sha1-basic.git" "$output_dir/sha1-missing.git"
missing_oid="$(git -C "$output_dir/sha1-basic.git" rev-parse HEAD:README.md)"
rm -f -- "$output_dir/sha1-missing.git/objects/${missing_oid:0:2}/${missing_oid:2}"

cp -R "$output_dir/sha1-history.git" "$output_dir/sha1-history-shallow.git"
shallow_oid="$(git -C "$output_dir/sha1-history.git" rev-parse fixture/criss-cross)"
printf '%s\n' "$shallow_oid" >"$output_dir/sha1-history-shallow.git/shallow"

cp -R "$output_dir/sha1-history.git" "$output_dir/sha1-history-replace.git"
replace_target="$(git -C "$output_dir/sha1-history.git" rev-parse fixture/root)"
replace_tree="$(git -C "$output_dir/sha1-history.git" rev-parse fixture/root^{tree})"
replace_oid="$(
  env GIT_AUTHOR_DATE='2001-02-01T00:13:00+0000' \
    GIT_COMMITTER_DATE='2001-02-01T00:13:00+0000' \
    git -C "$output_dir/sha1-history-replace.git" commit-tree "$replace_tree" \
    -m 'Replacement root without parents'
)"
git -C "$output_dir/sha1-history-replace.git" update-ref \
  "refs/replace/$replace_target" "$replace_oid"

# Each corruption copy receives exactly one surgical mutation.
mkdir -p "$output_dir/corrupt"
cp -R "$output_dir/sha1-basic.git" "$output_dir/corrupt/loose-bad-hash.git"
cp -R "$output_dir/sha1-basic.git" "$output_dir/corrupt/loose-malformed-header.git"
loose_object="$missing_oid"
python3 "$corrupt_helper" flip-payload \
  "$output_dir/corrupt/loose-bad-hash.git/objects/${loose_object:0:2}/${loose_object:2}"
python3 "$corrupt_helper" malform-header \
  "$output_dir/corrupt/loose-malformed-header.git/objects/${loose_object:0:2}/${loose_object:2}"

cp -R "$output_dir/sha1-basic-packed.git" "$output_dir/corrupt/pack-truncated.git"
cp -R "$output_dir/sha1-basic-packed.git" "$output_dir/corrupt/pack-bad-checksum.git"
cp -R "$output_dir/sha1-basic-packed.git" "$output_dir/corrupt/idx-bad-checksum.git"
cp -R "$output_dir/sha1-basic-packed.git" \
  "$output_dir/corrupt/pack-body-corrupt-valid-checksums.git"
truncated_pack="$(find "$output_dir/corrupt/pack-truncated.git/objects/pack" -name '*.pack' -print -quit)"
bad_pack="$(find "$output_dir/corrupt/pack-bad-checksum.git/objects/pack" -name '*.pack' -print -quit)"
bad_idx="$(find "$output_dir/corrupt/idx-bad-checksum.git/objects/pack" -name '*.idx' -print -quit)"
body_pack="$(find "$output_dir/corrupt/pack-body-corrupt-valid-checksums.git/objects/pack" -name '*.pack' -print -quit)"
body_idx="${body_pack%.pack}.idx"
python3 "$corrupt_helper" truncate "$truncated_pack" 17
python3 "$corrupt_helper" flip "$bad_pack" -21
python3 "$corrupt_helper" flip "$bad_idx" -1

# Damage the compressed body of one known entry while keeping the pack and
# index structurally self-consistent. The old object ID stays in the index so
# a lookup must reach pack decoding and then reject the damaged payload.
pack_body_corrupt_oid="$missing_oid"
body_entry_offset="$(
  git verify-pack -v "$body_idx" |
    awk -v oid="$pack_body_corrupt_oid" '$1 == oid { offset = $5 } END { print offset }'
)"
body_next_offset="$(
  git verify-pack -v "$body_idx" |
    awk -v offset="$body_entry_offset" \
      '$5 ~ /^[0-9]+$/ && $5 > offset && (candidate == "" || $5 < candidate) { candidate = $5 } END { print candidate }'
)"
if [[ ! "$body_entry_offset" =~ ^[0-9]+$ || ! "$body_next_offset" =~ ^[0-9]+$ ]]; then
  printf 'error: could not locate packed fixture entry boundaries\n' >&2
  exit 1
fi
python3 - "$body_pack" "$body_idx" "$body_entry_offset" \
  "$body_next_offset" "$pack_body_corrupt_oid" <<'PY'
import hashlib
import os
import stat
import struct
import sys
import zlib

pack_path, idx_path, start_text, end_text, oid_text = sys.argv[1:]
start = int(start_text)
end = int(end_text)
oid = bytes.fromhex(oid_text)

with open(pack_path, "rb") as stream:
    pack = bytearray(stream.read())
if not (12 <= start < end <= len(pack) - 20):
    raise SystemExit("packed fixture entry boundaries are invalid")

# The selected non-delta blob has a two-byte entry header, so its midpoint is
# safely inside the zlib body rather than the pack or entry header.
body_offset = start + (end - start) // 2
pack[body_offset] ^= 0x01
pack_digest = hashlib.sha1(pack[:-20]).digest()
pack[-20:] = pack_digest

with open(idx_path, "rb") as stream:
    index = bytearray(stream.read())
if index[:4] != b"\xfftOc" or struct.unpack(">I", index[4:8])[0] != 2:
    raise SystemExit("packed fixture index is not version 2")
object_count = struct.unpack(">I", index[8 + 255 * 4 : 8 + 256 * 4])[0]
oids_start = 8 + 256 * 4
oids = [
    bytes(index[oids_start + position * 20 : oids_start + (position + 1) * 20])
    for position in range(object_count)
]
try:
    oid_position = oids.index(oid)
except ValueError as error:
    raise SystemExit("damaged fixture object ID is absent from its index") from error

crc_start = oids_start + object_count * 20
offsets_start = crc_start + object_count * 4
indexed_offset = struct.unpack(
    ">I", index[offsets_start + oid_position * 4 : offsets_start + (oid_position + 1) * 4]
)[0]
if indexed_offset != start:
    raise SystemExit("damaged fixture object offset does not match its index")

# Update the entry CRC, the index's embedded pack checksum, and finally the
# index checksum. Thus the entry data itself is the sole inconsistency.
entry_crc = zlib.crc32(pack[start:end])
index[crc_start + oid_position * 4 : crc_start + (oid_position + 1) * 4] = \
    struct.pack(">I", entry_crc)
index[-40:-20] = pack_digest
index[-20:] = hashlib.sha1(index[:-20]).digest()

for path, contents in [(pack_path, pack), (idx_path, index)]:
    mode = stat.S_IMODE(os.stat(path).st_mode)
    os.chmod(path, mode | stat.S_IWUSR)
    try:
        with open(path, "wb") as stream:
            stream.write(contents)
    finally:
        os.chmod(path, mode)
PY

sha1_head="$(git -C "$output_dir/sha1-basic.git" rev-parse HEAD)"
sha256_head="$(git -C "$output_dir/sha256-basic.git" rev-parse HEAD)"
history_head="$(git -C "$output_dir/sha1-history.git" rev-parse HEAD)"
blame_head="$(git -C "$output_dir/sha1-blame.git" rev-parse HEAD)"
graph_head="$(git -C "$output_dir/sha1-graph.git" rev-parse HEAD)"
lfs_head="$(git -C "$output_dir/lfs-pointer.git" rev-parse HEAD)"
nested_head="$(git -C "$output_dir/sha1-nested.git" rev-parse HEAD)"
search_head="$(git -C "$output_dir/sha1-search.git" rev-parse HEAD)"
diff_base="$(git -C "$output_dir/sha1-diff.git" rev-parse fixture/diff-base)"
diff_head="$(git -C "$output_dir/sha1-diff.git" rev-parse fixture/diff-head)"
submodules_head="$(git -C "$output_dir/sha1-submodules.git" rev-parse fixture/submodules-head)"
submodules_malformed="$(git -C "$output_dir/sha1-submodules.git" rev-parse fixture/submodules-malformed)"

{
  printf 'git_version=%s\n' "$git_version"
  printf 'sha1_basic_head=%s\n' "$sha1_head"
  printf 'sha1_basic_readme=%s\n' "$missing_oid"
  printf 'sha256_basic_head=%s\n' "$sha256_head"
  printf 'sha1_history_head=%s\n' "$history_head"
  printf 'sha1_blame_head=%s\n' "$blame_head"
  for blame_key in root append delete rewrite rename post-rename edited-rename feature main merge final; do
    printf 'sha1_blame_%s=%s\n' "${blame_key//-/_}" \
      "$(git -C "$output_dir/sha1-blame.git" rev-parse "fixture/blame-$blame_key")"
  done
  printf 'sha1_history_criss_left=%s\n' \
    "$(git -C "$output_dir/sha1-history.git" rev-parse fixture/criss-left)"
  printf 'sha1_history_criss_right=%s\n' \
    "$(git -C "$output_dir/sha1-history.git" rev-parse fixture/criss-right)"
  printf 'sha1_graph_head=%s\n' "$graph_head"
  printf 'sha1_graph_octopus=%s\n' \
    "$(git -C "$output_dir/sha1-graph.git" rev-parse fixture/octopus)"
  printf 'sha1_graph_octopus_tag=%s\n' \
    "$(git -C "$output_dir/sha1-graph.git" rev-parse graph-octopus)"
  printf 'sha1_graph_criss_left=%s\n' \
    "$(git -C "$output_dir/sha1-graph.git" rev-parse fixture/criss-left)"
  printf 'sha1_graph_criss_right=%s\n' \
    "$(git -C "$output_dir/sha1-graph.git" rev-parse fixture/criss-right)"
  printf 'sha1_graph_criss_base_left=%s\n' \
    "$(git -C "$output_dir/sha1-graph.git" rev-parse fixture/criss-base-left)"
  printf 'sha1_graph_criss_base_right=%s\n' \
    "$(git -C "$output_dir/sha1-graph.git" rev-parse fixture/criss-base-right)"
  printf 'sha1_graph_disjoint=%s\n' \
    "$(git -C "$output_dir/sha1-graph.git" rev-parse fixture/disjoint)"
  printf 'sha1_graph_skew_child=%s\n' \
    "$(git -C "$output_dir/sha1-graph.git" rev-parse fixture/skew-child)"
  printf 'sha1_graph_equal_merge=%s\n' \
    "$(git -C "$output_dir/sha1-graph.git" rev-parse fixture/equal-merge)"
  printf 'lfs_pointer_head=%s\n' "$lfs_head"
  printf 'sha1_nested_head=%s\n' "$nested_head"
  printf 'sha1_search_head=%s\n' "$search_head"
  printf 'sha1_diff_base=%s\n' "$diff_base"
  printf 'sha1_diff_head=%s\n' "$diff_head"
  printf 'sha1_submodules_head=%s\n' "$submodules_head"
  printf 'sha1_submodules_malformed=%s\n' "$submodules_malformed"
  printf 'sha1_refs_head=%s\n' "$refs_head"
  printf 'sha1_refs_parent=%s\n' "$refs_parent"
  printf 'sha1_refs_chain_tag=%s\n' \
    "$(git -C "$output_dir/sha1-refs.git" rev-parse refs/tags/refs-chain)"
  printf 'sha1_nested_root_txt=%s\n' \
    "$(git -C "$output_dir/sha1-nested.git" rev-parse HEAD:root.txt)"
  printf 'sha1_nested_deep_txt=%s\n' \
    "$(git -C "$output_dir/sha1-nested.git" rev-parse HEAD:lib/gitility/core/b.txt)"
  printf 'sha1_basic_pack_last_object=%s\n' "$basic_pack_last_object"
  printf 'midx_probe=%s\n' "$midx_probe_oid"
  printf 'replace_target=%s\n' "$replace_target"
  printf 'replace_with=%s\n' "$replace_oid"
  printf 'pack_body_corrupt_oid=%s\n' "$pack_body_corrupt_oid"
  printf 'sha1_blame_bin1_alpha=%s\n' \
    "$(git -C "$output_dir/sha1-blame.git" rev-parse fixture/blame-bin1-alpha)"
  printf 'sha1_blame_bin1_beta=%s\n' \
    "$(git -C "$output_dir/sha1-blame.git" rev-parse fixture/blame-bin1-beta)"
  printf 'sha1_blame_bin1_gamma=%s\n' \
    "$(git -C "$output_dir/sha1-blame.git" rev-parse fixture/blame-bin1-gamma)"
  printf 'sha1_blame_pagination_head=%s\n' \
    "$(git -C "$output_dir/sha1-blame.git" rev-parse fixture/blame-history-pagination-tip)"
} >"$output_dir/OIDS"

printf '%s\n' "$generator_hash" >"$output_dir/GENERATOR_HASH"
python3 "$checksum_helper" "$output_dir" >"$output_dir/CHECKSUMS"

if [[ -s "$previous_oids" ]]; then
  previous_oid_lines="$(wc -l <"$previous_oids")"
  awk -v lines="$previous_oid_lines" 'NR <= lines' "$output_dir/OIDS" \
    >"$scratch_dir/current-oids-prefix"
  if ! cmp -s "$previous_oids" "$scratch_dir/current-oids-prefix"; then
    printf 'error: generated OIDS changed or were reordered\n' >&2
    exit 1
  fi
  printf 'Verified byte-identical pre-existing deterministic OIDS.\n'
fi
if [[ -s "$previous_checksums" ]]; then
  # Extending the generated corpus legitimately adds inventory records and
  # changes the OIDS/generator markers. Every other pre-existing path must
  # remain byte-identical.
  while IFS= read -r previous_checksum; do
    case "$previous_checksum" in
      *' R0VORVJBVE9SX0hBU0g=' | *' T0lEUw==') continue ;;
    esac
    if ! grep -Fqx -- "$previous_checksum" "$output_dir/CHECKSUMS"; then
      printf 'error: generated fixture changed or disappeared: %s\n' \
        "$previous_checksum" >&2
      exit 1
    fi
  done <"$previous_checksums"
  printf 'Verified byte-identical pre-existing repository contents.\n'
fi

printf 'Generated fixtures with git %s:\n' "$git_version"
cat "$output_dir/OIDS"
