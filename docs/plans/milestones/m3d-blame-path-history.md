# M3d — blame hunks + path history

You are implementing Milestone 3d of Gitility. READ FIRST, in this order:
1. docs/plans/2026-08-14-gitility-design.md — "Blame", "Commit graph and
   history" (history/3), the R2/R3 risk-register rows (blame divergence
   ~7% in rename-heavy history; path history is OUR algorithm with a
   documented rename-candidate deviation), "Cursors" (tag 0x04 history,
   payload = last emitted commit digest), "Limits and safety", "Error
   model", Milestone 3.
2. lib/gitility/types/blame.ex (DTO fully designed: Blame + Blame.Hunk,
   final/original 1-based inclusive ranges, boundary flag) and the
   history/3 stub in lib/gitility.ex — history returns
   {:ok, Page.t(Gitility.Commit.t())}; that contract is FROZEN.
3. crates/gitility-core/src/ — log.rs (commit walk you will reuse for
   history), diff.rs (tree-diff machinery, union reads NOT needed here),
   cursor.rs, budget.rs; crates/gitility-core/vendor/gix-diff (our
   vendored copy — read its Cargo.toml header comment).
4. sources/gitoxide/gix-blame — the vendored blame implementation you
   will bind (0.16.0).
5. test/differential/README.md + oracle.ex.

ABSOLUTE CONSTRAINT — NO BEAM: do NOT run mix test, mix compile, iex,
or anything that loads the NIF into a BEAM (docs/reports/
2026-08-14-kernel-panic-thread-leak.md). Rust-side verification only:
cargo test -p gitility-core; RUSTFLAGS="--cfg loom" cargo test -p
gitility-core --release; cargo check -p gitility; cargo clippy
--workspace --all-targets -- -D warnings (both cfgs); cargo fmt --all
--check; bash scripts/check-thread-spawns.sh (it scans vendor/ too).
Elixir files are EDITED but not executed; list every Elixir edit you
could not verify in your report.

Write surface: crates/gitility-core/, native/gitility/, lib/, test/,
fixtures/ (generation scripts only), root Cargo.toml + Cargo.lock (for
the [patch] section), mix.exs ONLY if the shipped file list needs the
root manifest additions. Do not commit. Decisions below are final.

R1 [dependencies — gix-blame via the vendored gix-diff]. Pin
gix-blame = =0.16.0 (default-features = false unless a feature is
needed — record evidence). CRITICAL: crates.io gix-blame depends on
crates.io gix-diff ^0.66.0, whose blob feature enables gix-tempfile
WITH defaults (DashMap + signal handlers — forbidden in the NIF).
DECISION: add a workspace [patch.crates-io] entry pointing gix-diff at
crates/gitility-core/vendor/gix-diff so every dependent (ours AND
gix-blame's) resolves to the single vendored, thread-free copy — this
also restores type identity between our diff usage and gix-blame's.
After `cargo update -w`: verify exactly ONE gix-diff in the tree (the
vendor path), no dashmap/rayon/crossbeam-*/signal-hook anywhere in
gitility-core's normal tree, spawn guard green. Verify the Hex package
still builds conceptually: mix.exs files: must ship the root Cargo.toml
(which now carries the [patch]) — check and fix files: if absent.
Record file:line evidence for what gix-blame provides (file/function
level: the blame entry point, range support, rewrite tracking).

R2 [core blame]. New module (suggest crates/gitility-core/src/blame.rs)
binding gix-blame over any ObjectDb + our commit-graph adapter:
- blame(snapshot, path, opts) → ordered hunks: final_range and
  original_range (1-based inclusive), commit id, original path (raw
  bytes; differs from the queried path across renames),
  boundary flag, plus author/committer identities and the commit
  subject (reuse the M3a commit DTO decode — caps and raw-bytes rules
  apply; summary = subject, 1 KiB cap).
- lines: Option<Range> maps to gix-blame's range support — validate
  1-based, start <= end, in-file (out-of-range → :invalid_argument
  naming the file's line count in details).
- follow_renames: bool (default true, matching gix-blame's rewrite
  tracking through our vendored gix-diff) — false disables rewrite
  tracking entirely.
- NO first_parent option (design R7 — upstream has none; a wrong
  emulation is worse than absence). Reject it as an unknown option.
- Shallow repositories: shallow roots (M3a H4 seam) blame as boundary
  commits — verify against git blame on the shallow fixture.
- Budget::check per visited commit and per blob comparison (M3b H3
  cadence discipline); Limits: max_objects bounds commits+blobs
  visited. BLAME DOES NOT PAGINATE: there is no cursor; if a ceiling
  or deadline trips before completion the call FAILS with
  :budget_exceeded/:timeout (an incomplete blame is a wrong blame —
  document that callers narrow lines: instead). The path must resolve
  to a blob in the snapshot (:invalid_path otherwise; tree →
  :invalid_argument naming the kind).
- The blamed file's bytes at HEAD exceeding max_object_bytes →
  :object_too_large refusal (blame cannot skip its subject); document.

R3 [core path history — OUR algorithm, R3/F5]. New module (suggest
crates/gitility-core/src/path_history.rs):
- Walk commits from the snapshot in CHRONOLOGICAL order (reuse log.rs
  machinery incl. its git-parity tie handling and shallow semantics);
  for each commit, tree-diff it against its first parent FOR THE
  TRACKED PATH ONLY (use the diff tree walk with a pathspec pruned to
  the single path — never a full-tree diff; merge commits: a commit is
  emitted iff the path's blob/mode at the commit differs from its
  FIRST parent (matching git log's default simplify-history view of
  --first-parent=false? NO — decide simply and document: we emit a
  commit when the path state differs from first parent; git's default
  history simplification (TREESAME pruning across ANY parent) is NOT
  replicated — this is a DOCUMENTED DEVIATION, differential-tested
  with git log --full-history --first-parent OFF? Use the closest git
  invocation: `git log --full-history -- <path>` emits commits where
  the path changed relative to any parent... EMPIRICALLY probe git
  2.55.0 on the fixtures and pick the invocation that matches our
  emission rule best; document the exact correspondence and report
  residual divergences for triage — do NOT silently absorb).
- Root commits: path present at root → emitted (added).
- follow_renames: true engages rename re-targeting: when the tracked
  path first appears as ADDED in a commit (walking backwards it
  vanishes), run the rename detection from diff.rs (renames:
  :similarity, sources limited to that commit's change set, 50%
  threshold, floor scoring) between the commit and its first parent;
  if the added path is a rename destination, re-target the walk to
  the source path and CONTINUE (like git log --follow). The
  rename-candidate deviation from git is EXPECTED (design R3);
  divergences vs git log --follow get reported for triage.
- Emission: %Gitility.Commit{} DTOs (M3a decode reuse), newest-first,
  paged via cursor wire v1 operation tag 0x04, position payload = last
  emitted commit digest (frozen). Fingerprint covers path (raw bytes) +
  follow_renames + normalized options. Resume follows M3a H6: prefix
  visits not recharged; the walk itself is budgeted per visited commit
  AND per tree-diff (each parent-tree read charged).
- History is budgeted separately per the design: tree-diffing many
  steps is the cost driver; max_objects bounds commits visited + tree
  objects read; document O(history × path-depth) worst case in @doc.

R4 [NIF + Elixir API]. M3a/M3b/M3c job idioms exactly (job_submit, two
new JobOutput variants: Blame and History — History may reuse the Log
page shape if identical; decide and record):
- Gitility.blame(snapshot, path, opts) → {:ok, %Gitility.Blame{}}.
  opts: lines: (Range or {start, end} — Elixir Range normalizes),
  follow_renames: true, limits:. Typed errors raise ArgumentError,
  semantic → :invalid_argument (M1c convention); non-Snapshot →
  :invalid_argument (L5).
- Gitility.history(snapshot, path, opts) →
  {:ok, %Gitility.Page{items: [%Gitility.Commit{}]}} per the frozen
  stub. opts: follow_renames: true, first_parent: false? NO — history
  has NO first_parent in 0.x (same R7 logic; reject unknown), limit:,
  cursor:, limits:.
- async_blame/3 + async_history/3 mirror the existing async idioms.
- Blame.Hunk identities/summary encode as raw binaries; ranges as
  Elixir Range structs (first..last//1, 1-based inclusive).

R5 [fixtures]. Extend fixtures/generate.sh with "sha1-blame.git":
deterministic linear history (≥8 commits) over one file with
interleaved authorship (≥3 distinct authors, distinct timestamps),
including: a commit that only APPENDS; one that only DELETES lines;
one that rewrites a middle region; a RENAME of the file (content
≥90% similar) followed by further edits under the new name; a rename
WITH simultaneous edit; a second independent file to keep trees
non-trivial; a merge commit where both parents touched the file
(blame attribution across a merge); CRLF lines; a non-UTF-8 (Latin-1)
line; a final commit leaving the file WITHOUT trailing newline. Also
reuse sha1-history-shallow.git for boundary blame and sha1-graph.git
for history over merges. OIDS keys for head + every interesting
commit. Deterministic, self-verifying, regenerated twice.

R6 [differential].
- blame parity: `git blame --porcelain [-L start,end] [--no-follow]
  <rev> -- <path>` parsed NUL/porcelain-safely into hunks; compare
  hunk boundaries, commit attribution, original paths, boundary
  flags, on sha1-blame.git (full file, ranges, no-follow variant,
  post-rename file) and shallow fixture. Expect divergences in
  rename-heavy shapes (design R2 ~7%): report each with its exact
  case for triage — allowlist stays UNTOUCHED by you.
- history parity: our emission vs the empirically-chosen git
  invocation (R3) on sha1-blame.git and sha1-graph.git, with and
  without --follow; full ordered commit-id sequences; cursor
  pagination reconstruction across ≥3 pages; report divergences.
- Rust-side probes for both BEFORE the Elixir differential files, so
  your report carries git-parity evidence the reviewer can check.

R7 [Elixir tests — written, not run].
test/milestone_3d_blame_history_test.exs: blame happy path (hunk
compactness: contiguous same-commit lines produce ONE hunk); lines:
ranges incl. exact-boundary and out-of-range :invalid_argument;
follow_renames false vs true across the rename (original_path
differs); boundary flag on shallow; :invalid_path / tree-path
:invalid_argument; budget refusal is :budget_exceeded (no partial
blame); non-UTF-8 identity bytes round-trip; history: pagination
round-trip + fingerprint invalidation on path/follow_renames change;
rename re-target emits the pre-rename commits; deterministic
cancellation via the M3b blocking-backend pattern (block a BLOB read
mid-blame); async mirrors; setup via OIDS keys + {:oid, ...} — ref
selectors are M4 and MUST NOT appear; start_supervised! throughout.
CONVERSION-SITE DISCIPLINE (M3c lesson): every new DTO field must be
asserted through the FULL Elixir path in at least one test (the
native_support conversion is where no-BEAM rounds go blind) — list in
your report each new field and the test that exercises it end-to-end.

Report at the end: per-requirement summary; Rust test counts (plain +
loom); the [patch.crates-io] tree evidence (one gix-diff, no thread
crates); gix-blame binding evidence (file:line); the chosen git
history oracle invocation and its empirical correspondence; EVERY
blame/history divergence with its exact case; the conversion-site
field list; Elixir edits not BEAM-verified; deviations from this file.
