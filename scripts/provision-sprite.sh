#!/usr/bin/env bash
# Provision a FRESH gitility test sprite from the base image to the state
# scripts/remote-test.sh expects. Run from the repo root on the local
# machine after `sprite create <name>` + `sprite use <name>`:
#
#   scripts/provision-sprite.sh
#
# Idempotent: safe to re-run on a partially provisioned sprite. The sprite
# image already provides OTP/Elixir; this script adds the Rust toolchain
# and builds the pinned canonical git (same recipe as .github/workflows/
# ci.yml — the differential oracle refuses to run on any other version).
# PostgreSQL and fixtures are provisioned by remote-test.sh itself.
#
# After provisioning, optional extras some workflows expect (recorded in
# the project memory, NOT done here):
#   - benchmarks want /dev/shm remounted:  sudo mount -o remount,size=2G /dev/shm
#   - the C1 benchmark corpus:             git clone --bare https://github.com/git/git ~/bench/git.git
set -euo pipefail

SPRITE_NAME="${SPRITE:-gitility-test}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
GIT_VERSION="$(cat "$repo_root/test/differential/GIT_VERSION")"

rexec() { sprite exec -s "$SPRITE_NAME" -- bash -lc "$1"; }

echo "==> provision: verifying base image (OTP/Elixir expected preinstalled)"
rexec 'elixir --version | tail -2 && erl -noshell -eval "io:format(\"OTP ~s~n\", [erlang:system_info(otp_release)]), halt()."'

echo "==> provision: rustup (stable toolchain)"
rexec 'command -v cargo >/dev/null 2>&1 || {
  curl --proto "=https" --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
}
. "$HOME/.cargo/env" 2>/dev/null || true
export PATH="$HOME/.cargo/bin:$PATH"
rustc --version && cargo --version'

echo "==> provision: build deps for canonical git"
rexec 'sudo -n apt-get update -qq && sudo -n apt-get install -y --no-install-recommends \
  build-essential curl ca-certificates libcurl4-openssl-dev libexpat1-dev zlib1g-dev xz-utils'

echo "==> provision: pinned canonical git ${GIT_VERSION} at ~/pinned-git"
rexec "if ! \"\$HOME/pinned-git/bin/git\" --version 2>/dev/null | grep -q \"git version ${GIT_VERSION}\"; then
  cd \"\$(mktemp -d)\"
  curl -fsSL \"https://mirrors.edge.kernel.org/pub/software/scm/git/git-${GIT_VERSION}.tar.gz\" | tar -xz
  make -C \"git-${GIT_VERSION}\" -j\"\$(nproc)\" prefix=\"\$HOME/pinned-git\" \
    NO_TCLTK=1 NO_GETTEXT=1 INSTALL_SYMLINKS=1 install >/dev/null
fi
\"\$HOME/pinned-git/bin/git\" --version"

echo "==> provision: hex + rebar"
rexec 'export PATH="$HOME/.cargo/bin:$HOME/pinned-git/bin:$PATH"
mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && echo hex/rebar ok'

echo "==> provision: done — next: scripts/remote-test.sh sync rust loom postgres mix soak"
