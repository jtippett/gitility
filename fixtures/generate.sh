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

for command in awk cat chmod cmp cp dd env find git ln mkdir mktemp mv python3 rm seq; do
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

if [[ -f "$output_dir/OIDS" ]]; then
  cp "$output_dir/OIDS" "$previous_oids"
fi
if [[ -f "$output_dir/CHECKSUMS" ]]; then
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

sha1_work="$scratch_dir/sha1-basic-work"
sha256_work="$scratch_dir/sha256-basic-work"
history_work="$scratch_dir/sha1-history-work"
graph_work="$scratch_dir/sha1-graph-work"
lfs_work="$scratch_dir/lfs-pointer-work"
nested_work="$scratch_dir/sha1-nested-work"

make_basic sha1 "$sha1_work" "$output_dir/sha1-basic.git"
make_basic sha256 "$sha256_work" "$output_dir/sha256-basic.git"
make_history "$history_work" "$output_dir/sha1-history.git"
make_graph "$graph_work" "$output_dir/sha1-graph.git"
make_lfs_pointer "$lfs_work" "$output_dir/lfs-pointer.git"
make_nested "$nested_work" "$output_dir/sha1-nested.git"

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
graph_head="$(git -C "$output_dir/sha1-graph.git" rev-parse HEAD)"
lfs_head="$(git -C "$output_dir/lfs-pointer.git" rev-parse HEAD)"
nested_head="$(git -C "$output_dir/sha1-nested.git" rev-parse HEAD)"

{
  printf 'git_version=%s\n' "$git_version"
  printf 'sha1_basic_head=%s\n' "$sha1_head"
  printf 'sha1_basic_readme=%s\n' "$missing_oid"
  printf 'sha256_basic_head=%s\n' "$sha256_head"
  printf 'sha1_history_head=%s\n' "$history_head"
  printf 'sha1_history_criss_left=%s\n' \
    "$(git -C "$output_dir/sha1-history.git" rev-parse fixture/criss-left)"
  printf 'sha1_history_criss_right=%s\n' \
    "$(git -C "$output_dir/sha1-history.git" rev-parse fixture/criss-right)"
  printf 'sha1_graph_head=%s\n' "$graph_head"
  printf 'sha1_graph_octopus=%s\n' \
    "$(git -C "$output_dir/sha1-graph.git" rev-parse fixture/octopus)"
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
  printf 'lfs_pointer_head=%s\n' "$lfs_head"
  printf 'sha1_nested_head=%s\n' "$nested_head"
  printf 'sha1_nested_root_txt=%s\n' \
    "$(git -C "$output_dir/sha1-nested.git" rev-parse HEAD:root.txt)"
  printf 'sha1_nested_deep_txt=%s\n' \
    "$(git -C "$output_dir/sha1-nested.git" rev-parse HEAD:lib/gitility/core/b.txt)"
  printf 'sha1_basic_pack_last_object=%s\n' "$basic_pack_last_object"
  printf 'midx_probe=%s\n' "$midx_probe_oid"
  printf 'replace_target=%s\n' "$replace_target"
  printf 'replace_with=%s\n' "$replace_oid"
  printf 'pack_body_corrupt_oid=%s\n' "$pack_body_corrupt_oid"
} >"$output_dir/OIDS"

python3 "$checksum_helper" "$output_dir" >"$output_dir/CHECKSUMS"

if [[ -s "$previous_oids" ]]; then
  cmp "$previous_oids" "$output_dir/OIDS"
  printf 'Verified stable object IDs against the previous generation.\n'
fi
if [[ -s "$previous_checksums" ]]; then
  cmp "$previous_checksums" "$output_dir/CHECKSUMS"
  printf 'Verified byte-identical repository contents against the previous generation.\n'
fi

printf 'Generated fixtures with git %s:\n' "$git_version"
cat "$output_dir/OIDS"
