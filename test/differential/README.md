# Differential oracle tests

Canonical Git is the primary behavioral oracle. `GIT_VERSION` pins the version
used to develop and triage this harness; CI should install that version. The
runtime test compares major/minor versions so patch-level security upgrades do
not create noise.

An intentional Git upgrade is a review event: run the full differential suite,
triage changed results, update every affected allowlist entry, and then update
`GIT_VERSION`. For a one-off local probe with another Git, set
`GITILITY_ORACLE_ALLOW_VERSION_MISMATCH=1`; the version test emits a warning
instead of failing. Results from such a run are non-authoritative, and that
escape hatch must not be set in CI.

The differential gate is enabled by default. Engine-backed comparisons carry
the `:gitility_engine` tag so developers can select that gate explicitly (for
example, `mix test --only gitility_engine`). Unknown mismatches fail; only
cases whose id, operation, fixture repository, and query all exactly match a
record in `allowlist.exs` pass with a visible allowlist record. Entries for
ordered history results also pin the exact Git and Gitility commit sequences,
so a different mismatch in the same context still fails.

The Rust `.gitmodules` parser has its own Git 2.55.0 blob-oracle tests. The
checked-in curated corpus and 512-case deterministic mutation test run under
normal `cargo test`. Its 3,456-case value sweep is intentionally opt-in:

```sh
GITILITY_EXHAUSTIVE_ORACLE=1 cargo test -p gitility-core \
  exhaustive_3456_value_sweep_matches_git_2_55_blob_reader -- --nocapture
```

That harness creates temporary bare repositories and never sends an
include-bearing blob to `git config --blob`, because that command follows
include paths while Git's `.gitmodules` consumer does not.

Content-search parity uses `git grep -F` for literal byte patterns, `-i` only
for the certified ASCII folding cases, `-I` for the default binary policy, and
`-a` for `binary: :text`. Regex search is intentionally Rust-unit-tested rather
than compared here because Git and `regex::bytes` accept different pattern
classes.

Structured-diff parity uses NUL-delimited `git diff-tree --raw -z` and
`git diff --numstat -z` streams for every file path. Patch comparisons first
obtain those raw paths and invoke one histogram diff per path, so patch headers
are never used as a path parser. Rename/copy candidate selection may differ
between Git and gitoxide; every exact differing case must be triaged rather
than normalized in the adapter.

Blame parity uses byte-oriented porcelain parsing and compares coalesced hunk
boundaries, commit IDs, original paths, and boundary flags. Path-history parity
uses `git log --format=%H --no-patch --full-history [--diff-merges=first-parent
--follow] -- <path>`. Without `--follow`, no Git invocation reproduces
Gitility's explicit first-parent comparison rule: the nearest oracle
additionally emits a merge when the path differs only from a non-first parent,
and Gitility deliberately produces fewer such noise merges under design R3.
With `--follow`, `--diff-merges=first-parent` is load-bearing on the pinned
git 2.55.0 — it switches merge selection to first-parent comparison and
matches Gitility exactly (a no-op without `--follow`). Exact sequence differences, including Git's copy detection
under `--follow`, remain asserted, tightly allowlisted divergences rather than
normalized output.
