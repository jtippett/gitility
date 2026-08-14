#!/usr/bin/env bash
set -euo pipefail

# R5 guard: fail if any Gitoxide type leaks through gitility-core's public API.
# cargo-public-api still consumes nightly-only rustdoc JSON, so this remains a
# standalone CI-runnable check rather than an in-crate stable test.
#
# Prerequisite: `cargo install cargo-public-api`
# Usage: scripts/check-public-api.sh
# Override the toolchain with GITILITY_PUBLIC_API_TOOLCHAIN if necessary.

case "${BASH_SOURCE[0]}" in
  */*) script_parent="${BASH_SOURCE[0]%/*}" ;;
  *) script_parent=. ;;
esac
workspace_root="$(cd "$script_parent/.." && pwd)"
toolchain="${GITILITY_PUBLIC_API_TOOLCHAIN:-nightly}"

if ! cargo public-api --version >/dev/null 2>&1; then
  printf 'error: cargo-public-api is required; install it with `cargo install cargo-public-api`\n' >&2
  exit 1
fi

public_api="$(
  cargo "+$toolchain" public-api \
    --manifest-path "$workspace_root/Cargo.toml" \
    -p gitility-core
)"

if printf '%s\n' "$public_api" |
  grep -Eq '(^|[^[:alnum:]_])gix(_[[:alnum:]_]+)?::'; then
  printf '%s\n' "$public_api" >&2
  printf 'error: a Gitoxide type leaked into gitility-core public API\n' >&2
  exit 1
fi

printf 'Verified gitility-core public API contains no Gitoxide types.\n'
