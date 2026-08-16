#!/usr/bin/env bash
# Run gitility's test gauntlet on the dedicated Linux sprite under an
# OS-enforced thread cap.
#
# Why this exists: docs/reports/2026-08-14-kernel-panic-thread-leak.md.
# macOS has no per-process thread cap we can lean on, so runs that load a
# freshly built NIF — especially the runtime/soak suites — go to a Linux box
# where a cgroup pids.max turns a thread leak into a clean kill instead of a
# kernel panic. Gitility's own thread budget (default 512) stays the first
# line; the cgroup is the backstop behind it.
#
# Usage:
#   scripts/remote-test.sh [stage ...]
# Stages (default: all):
#   sync     git-archive HEAD + working tree to the sprite (sources/ and
#            fixtures/generated are never shipped — fixtures self-generate)
#   rust     cargo test --workspace, clippy -D warnings, fmt, spawn guard
#   loom     RUSTFLAGS="--cfg loom" release loom suite (9 models, exact names)
#   postgres install/start PostgreSQL, create the peer-auth test role/database
#            used by M2e's optional reference-backend conformance suite
#   mix      GITILITY_BUILD=1 mix test (differential gate included, needs
#            the pinned git 2.55.0 the provisioning step built)
#   soak     GITILITY_BUILD=1 mix test --only soak (the 30s runtime soak)
#   smoke    prove the thread cap wraps a trivial command (not in default set)
#
# Env:
#   GITILITY_REMOTE_PIDS_MAX   cgroup pids.max for the run (default 2000).
#                              A healthy suite uses < 200 threads; the
#                              budget caps ours at 512.
#   GITILITY_REMOTE_DIR        remote checkout dir (default ~/gitility)
#   GITILITY_TEST_POSTGRES_URL override the auto-detected sprite test database
#
# Requires: `sprite` CLI authenticated, `sprite use gitility-test` done in
# this directory (or SPRITE=<name>).
set -euo pipefail

SPRITE_NAME="${SPRITE:-gitility-test}"
REMOTE_DIR="${GITILITY_REMOTE_DIR:-\$HOME/gitility}"
PIDS_MAX="${GITILITY_REMOTE_PIDS_MAX:-2000}"
STAGES=("$@")
[ ${#STAGES[@]} -eq 0 ] && STAGES=(sync rust loom postgres mix soak)

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

rexec() { sprite exec -s "$SPRITE_NAME" -- bash -lc "$1"; }

# Everything test-shaped runs through this wrapper on the remote side: a
# dedicated cgroup with pids.max, plus a thread-count sampler for every
# beam.smp so a leak is visible in the log even if the cap never trips.
# Falls back to prlimit --nproc when the cgroup can't be created.
REMOTE_PRELUDE=$(cat <<PRELUDE
set -euo pipefail
export PATH="\$HOME/.cargo/bin:\$HOME/pinned-git/bin:\$PATH"
export GITILITY_BUILD=1
export CARGO_TERM_COLOR=never
cd $REMOTE_DIR
# The postgres stage creates a login matching the sprite user, so peer auth
# over the local socket needs no embedded secret.
if command -v pg_isready >/dev/null 2>&1 && pg_isready -q; then
  export GITILITY_TEST_POSTGRES_URL="\${GITILITY_TEST_POSTGRES_URL:-postgresql:///\$(id -un)_gitility_test?host=/var/run/postgresql}"
  echo "[remote] PostgreSQL conformance enabled"
else
  echo "[remote] PostgreSQL unavailable; optional conformance will log a skip"
fi
capped() {
  local root=/sys/fs/cgroup cg=/sys/fs/cgroup/gitility-test
  # cgroup v2 "no internal processes" rule: the root can only delegate a
  # controller to children once its own member processes have moved into a
  # leaf. Do that dance idempotently, then cap this shell + descendants.
  if sudo -n sh -c "
       mkdir -p \$root/init \$cg
       for p in \\\$(cat \$root/cgroup.procs); do echo \\\$p > \$root/init/cgroup.procs 2>/dev/null; done
       grep -qw pids \$root/cgroup.subtree_control || echo +pids > \$root/cgroup.subtree_control
       echo $PIDS_MAX > \$cg/pids.max
       chmod 666 \$cg/cgroup.procs" 2>/dev/null \
     && echo \$\$ > "\$cg/cgroup.procs" 2>/dev/null; then
    echo "[remote] cgroup pids.max=\$(cat \$cg/pids.max) active (pids.current=\$(cat \$cg/pids.current))"
    local WRAP=()
  else
    echo "[remote] cgroup unavailable; falling back to prlimit --nproc=$PIDS_MAX"
    local WRAP=(prlimit --nproc=$PIDS_MAX)
  fi
  # thread sampler: max beam.smp thread count seen during the stage
  ( peak=0; while :; do
      cur=\$(ps -eo comm,nlwp | awk '\$1=="beam.smp"{s+=\$2} END{print s+0}')
      [ "\$cur" -gt "\$peak" ] && peak=\$cur && echo "[threads] beam.smp peak=\$peak"
      sleep 2
    done ) & SAMPLER=\$!
  trap 'kill \$SAMPLER 2>/dev/null || true' EXIT
  "\${WRAP[@]}" "\$@"
}
PRELUDE
)

stage_sync() {
  echo "==> sync: shipping working tree to $SPRITE_NAME:$REMOTE_DIR"
  # HEAD plus uncommitted changes, minus untracked junk: stash-free via
  # `git ls-files` (tracked + modified) and untracked-but-not-ignored.
  local manifest
  manifest="$(git ls-files --cached --others --exclude-standard)"
  rexec "mkdir -p $REMOTE_DIR && rm -rf $REMOTE_DIR/lib $REMOTE_DIR/test $REMOTE_DIR/crates $REMOTE_DIR/native $REMOTE_DIR/scripts $REMOTE_DIR/fixtures $REMOTE_DIR/docs"
  # tar over the exec channel; excludes keep the payload small.
  printf '%s\n' "$manifest" \
    | grep -v -E '^(sources/|fixtures/generated/|_build/|deps/|target/|priv/native/|doc/)' \
    | COPYFILE_DISABLE=1 tar --no-xattrs -czf - -T - \
    | sprite exec -s "$SPRITE_NAME" -- bash -lc "cd $REMOTE_DIR && tar -xzf -"
  # Reviewers/probes drop test/_scratch_*.exs files; a stale one on the remote
  # (deleted locally after the last sync) silently joins the next full run.
  rexec "cd $REMOTE_DIR && find test -name '_scratch_*' -delete 2>/dev/null; git init -q 2>/dev/null; true"
  # A sync that lands on a doomed instance (sprite mid-restore) can report
  # success while the persistent tree stays stale (observed 2026-08-17:
  # every stage then ran against the previous milestone's code). Verify
  # CONTENT, not exit codes: git-hash every shipped file on both sides and
  # compare the combined digest before any stage is allowed to run.
  local shipped expect actual
  shipped="$(printf '%s\n' "$manifest" \
    | grep -v -E '^(sources/|fixtures/generated/|_build/|deps/|target/|priv/native/|doc/)' \
    | sort)"
  expect="$(printf '%s\n' "$shipped" | tr '\n' '\0' \
    | xargs -0 git hash-object -- | git hash-object --stdin)"
  actual="$(printf '%s\n' "$shipped" \
    | sprite exec -s "$SPRITE_NAME" -- bash -lc "cd $REMOTE_DIR && tr '\n' '\0' | xargs -0 git hash-object -- 2>/dev/null | git hash-object --stdin" | tail -1)"
  if [ "$expect" != "$actual" ]; then
    echo "==> sync: VERIFY FAILED (local $expect != remote $actual) — remote tree is stale or incomplete, aborting" >&2
    exit 1
  fi
  echo "==> sync: done (content-verified $expect)"
}

stage_postgres() {
  echo "==> postgres: provisioning optional M2e conformance database"
  rexec 'set -euo pipefail
if ! command -v psql >/dev/null 2>&1; then
  sudo -n apt-get update -qq
  sudo -n apt-get install -y postgresql
fi
# Idempotent: `service postgresql start` exits 1 on an already-running
# server (port conflict), and an unclean sprite reboot can leave a stale
# empty postmaster.pid that blocks startup — clear it first.
if ! pg_isready -q; then
  sudo -n rm -f /var/lib/postgresql/*/main/postmaster.pid
  sudo -n service postgresql start
fi
pg_isready -q
role=$(id -un)
db="${role}_gitility_test"
sudo -n -u postgres createuser --login "$role" 2>/dev/null || true
sudo -n -u postgres createdb --owner "$role" "$db" 2>/dev/null || true
psql -d "$db" -tAc "SELECT 1" | grep -q 1
echo "[remote] PostgreSQL database=$db role=$role ready"'
}

run_stage() {
  local name="$1" cmd="$2"
  echo "==> $name"
  rexec "$REMOTE_PRELUDE
capped bash -c '$cmd'"
}

for s in "${STAGES[@]}"; do
  case "$s" in
    sync) stage_sync ;;
    postgres) stage_postgres ;;
    smoke) run_stage smoke "echo hello-from-cap; cat /proc/self/cgroup; cat /sys/fs/cgroup/gitility-test/pids.max 2>/dev/null; nproc" ;;
    rust) run_stage rust "cargo test --workspace 2>&1 | grep -E \"^test result|error|FAILED|panicked\"; cargo clippy --workspace --all-targets -- -D warnings 2>&1 | tail -2; cargo fmt --all --check && echo FMT-OK; bash scripts/check-thread-spawns.sh" ;;
    loom) run_stage loom "RUSTFLAGS=\"--cfg loom\" cargo test -p gitility-core --release 2>&1 | grep -E \"^test .*loom_|^test result\"" ;;
    # Failure blocks must survive the log: keep every ExUnit failure section
    # plus the tail summary (a bare tail -15 once swallowed the only failure
    # of a run — 2026-08-17).
    mix)  run_stage mix "mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get >/dev/null && out=\$(mix test 2>&1); echo \"\$out\" | grep -B 2 -A 25 '^  *[0-9][0-9]*) test' ; echo \"\$out\" | tail -15" ;;
    soak) run_stage soak "out=\$(mix test --only soak 2>&1); echo \"\$out\" | grep -B 2 -A 25 '^  *[0-9][0-9]*) test' ; echo \"\$out\" | tail -15" ;;
    *) echo "unknown stage: $s" >&2; exit 2 ;;
  esac
done
echo "==> all requested stages finished"
