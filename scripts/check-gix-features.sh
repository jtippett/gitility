#!/usr/bin/env bash
# The source spawn guard sees only our workspace. This normal/build-edge
# dependency audit prevents gix-pack's invisible parallel index workers from
# entering through feature unification (dev-only criterion edges are excluded).
set -euo pipefail

tree="$(cargo tree -e normal,build --target all -f '{p} features=[{f}]')"

if ! grep -Eq 'gix-pack v0\.73\.0 .*features=' <<<"$tree"; then
  echo "check-gix-features: gix-pack v0.73.0 is missing from the normal/build graph" >&2
  exit 1
fi

if grep -E 'gix v0\.86\.0 .*features=\[[^]]*(parallel|max-control|max-performance)' <<<"$tree"; then
  echo "check-gix-features: a forbidden top-level gix performance feature is enabled" >&2
  exit 1
fi

if grep -E 'gix-pack .*features=\[[^]]*parallel' <<<"$tree"; then
  echo "check-gix-features: forbidden gix-pack parallel feature is enabled" >&2
  exit 1
fi

if grep -Eq 'crossbeam-deque v' <<<"$tree"; then
  echo "check-gix-features: crossbeam-deque appears on normal/build edges" >&2
  exit 1
fi

echo "check-gix-features: gix-pack is single-threaded on normal/build edges"
