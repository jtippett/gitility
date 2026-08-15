#!/usr/bin/env bash
set -euo pipefail

# Native-thread guard: every production spawn in our Rust crates must be both
# budgeted and deliberately allowlisted here. Test-only modules/files are
# exempt because they do not enter the shipped NIF.

case "${BASH_SOURCE[0]}" in
  */*) script_parent="${BASH_SOURCE[0]%/*}" ;;
  *) script_parent=. ;;
esac
workspace_root="$(cd "$script_parent/.." && pwd)"

core_worker_file="crates/gitility-core/src/runtime/mod.rs"
core_worker_pattern="sync::thread::Builder::new"
nif_pump_file="native/gitility/src/lib.rs"
nif_pump_pattern="thread::Builder::new"

spawn_pattern='(^|[^[:alnum:]_])((std|sync|loom)::)?thread::(spawn|Builder::new)[[:space:]]*[(]'
bare_builder_pattern='(^|[^[:alnum:]_:])Builder::new[[:space:]]*[(]'
failed=0
core_worker_hits=0
nif_pump_hits=0

scan_file() {
  local relative_file="$1"
  local pattern="$spawn_pattern"

  # A bare Builder::new() is also a native-thread spawn when Builder was
  # imported from std::thread. Keep this contextual so unrelated builders do
  # not become false positives.
  if grep -Eq \
    'use[[:space:]]+std::thread(::Builder|::\{[^}]*Builder[^}]*\})' \
    "$workspace_root/$relative_file"; then
    pattern="$pattern|$bare_builder_pattern"
  fi

  # Suppress items guarded by #[cfg(test)] (including all()/any() forms).
  # Dedicated tests.rs and loom_tests.rs files are excluded by the caller.
  awk -v file="$relative_file" -v pattern="$pattern" '
    function brace_delta(line, copy, opens, closes) {
      copy = line
      opens = gsub(/\{/, "", copy)
      copy = line
      closes = gsub(/\}/, "", copy)
      return opens - closes
    }

    function starts_test_item(line) {
      return line ~ /#\[cfg\([[:space:]]*test[[:space:]]*\)\]/ ||
        line ~ /#\[cfg\([[:space:]]*(all|any)\([^]]*test[^]]*\)\)\]/
    }

    {
      if (skipping_test_item) {
        test_depth += brace_delta($0)
        if (test_depth <= 0) {
          skipping_test_item = 0
        }
        next
      }

      if (pending_test_item) {
        if ($0 ~ /\{/) {
          test_depth = brace_delta($0)
          skipping_test_item = test_depth > 0
          pending_test_item = 0
        } else if ($0 ~ /;/) {
          pending_test_item = 0
        }
        next
      }

      if (starts_test_item($0)) {
        pending_test_item = 1
        next
      }

      if ($0 ~ pattern) {
        print file ":" FNR ":" $0
      }
    }
  ' "$workspace_root/$relative_file"
}

while IFS= read -r absolute_file; do
  relative_file="${absolute_file#"$workspace_root/"}"
  case "${relative_file##*/}" in
    test_support.rs | tests.rs | loom_tests.rs) continue ;;
  esac

  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    source_line="${hit#*:*:}"
    case "$relative_file" in
      "$core_worker_file")
        if [[ "$source_line" == *"$core_worker_pattern"* ]]; then
          core_worker_hits=$((core_worker_hits + 1))
        else
          printf 'error: unallowlisted native thread spawn: %s\n' "$hit" >&2
          failed=1
        fi
        ;;
      "$nif_pump_file")
        if [[ "$source_line" == *"$nif_pump_pattern"* ]]; then
          nif_pump_hits=$((nif_pump_hits + 1))
        else
          printf 'error: unallowlisted native thread spawn: %s\n' "$hit" >&2
          failed=1
        fi
        ;;
      *)
        printf 'error: unallowlisted native thread spawn: %s\n' "$hit" >&2
        failed=1
        ;;
    esac
  done < <(scan_file "$relative_file")
done < <(
  find \
    "$workspace_root/crates/gitility-core/src" \
    "$workspace_root/native/gitility/src" \
    -type f -name '*.rs' -print | sort
)

if [[ "$core_worker_hits" -ne 1 ]]; then
  printf \
    'error: allowlisted worker spawn %s (%s) must occur exactly once; found %d\n' \
    "$core_worker_file" "$core_worker_pattern" "$core_worker_hits" >&2
  failed=1
fi

if [[ "$nif_pump_hits" -ne 1 ]]; then
  printf \
    'error: allowlisted notification-pump spawn %s (%s) must occur exactly once; found %d\n' \
    "$nif_pump_file" "$nif_pump_pattern" "$nif_pump_hits" >&2
  failed=1
fi

if [[ "$failed" -ne 0 ]]; then
  printf 'Thread spawn guard failed; budget or explicitly allowlist every production spawn.\n' >&2
  exit 1
fi

printf 'Verified exactly two allowlisted, budgeted native thread spawn sites.\n'
