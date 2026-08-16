# M3d review fixes — decisions and dispatch

Adversarial review of the M3d checkpoint (f1e8945; spec:
docs/plans/milestones/m3d-blame-path-history.md) ran 400 randomized
rename-heavy blame comparisons (0 divergences — gix-blame's rename
tracking beats the design's ~7% budget) plus a 549-path fixture sweep
and hand-built merge shapes. Findings below; decisions FINAL. Same
constraints: NO BEAM; Rust-side verification only; Elixir edited but
never executed; do not commit.

H1 [binary blame silently lies — fix to git parity, refuse only as
fallback]. A file whose first 8000 bytes contain NUL becomes
Data::Binary in the blob pipeline; gix-blame's blob_changes turns both
sides into empty slices, every step reports "no change", and the whole
file lands on the ROOT commit with a spurious boundary flag — no
error, no warning (reproduced on shipped fixtures binary.dat and
text-to-binary.dat, plus a 3-commit NUL file where git attributes each
line correctly). DECISION, in order of preference:
  a. PRIMARY: force text semantics so blame matches git — construct
     the rewrite/diff platform with a driver forcing is_binary =
     Some(false) (and the attribute stack that assigns it), applied to
     BLAME ONLY (diff/search keep their binary policy). Verify the
     bin1 shape (alpha/beta\0nul/gamma across 3 commits) attributes
     line-per-commit exactly as git blame does, and that binary.dat /
     text-to-binary.dat now match git.
  b. FALLBACK (only if the driver plumbing cannot be made sound):
     detect via the existing is_binary_payload on the HEAD blob right
     after the mandatory inflate and REFUSE with
     :unsupported_operation naming binary content in details. Never
     the current silent answer.
Either way: wire Blame.warnings for real (the NIF currently hardcodes
warnings: Vec::new() — L1), add the NUL-file shape to
fixtures/generate.sh sha1-blame.git (multi-commit binary history), and
add a differential blame case over it (under (a)) or a refusal test
(under (b)). State the chosen branch prominently in your report.

M1 [history oracle claim is false in five places]. --diff-merges=
first-parent affects only patch RENDERING; with --no-patch it is a
no-op — the real oracle is plain `git log --full-history -- <path>`,
whose merge rule ("not TREESAME to ANY parent") genuinely differs from
ours ("differs from FIRST parent"). FIX: drop the dead flag from
oracle.ex; rewrite all five claim sites (path_history.rs module doc,
history/3 @doc, test/differential/README.md paragraph, oracle.ex @doc,
the Rust test name) to state plainly: NO git invocation reproduces our
rule; `git log --full-history` is the nearest and additionally emits
merges whose path changed only relative to a non-first parent; ours is
the design-sanctioned deviation (design R3) and produces fewer noise
merges. Design doc M3 decision record gains a sentence.

M2 [assert the deviation — FIRST ALLOWLIST ENTRIES]. The differential
matrix picked the two paths that hide M1's divergence. FIX: add to the
history differential matrix, follow=false:
  - sha1-graph.git criss-left.txt (ours 2 vs git 3)
  - sha1-history.git branches/left.txt (ours 2 vs git 3)
and, follow=true (copy-detection class — git --follow enables copy
detection; our rename pass does not, per design R3):
  - sha1-history.git candidates/selected.txt
These WILL diverge. I (the reviewer of record) hereby approve the
first divergence-allowlist entries: one per case above, each with
context naming the class:
  - merge_rule: "gitility emits a merge iff the path differs from its
    FIRST parent; git --full-history emits when not TREESAME to ANY
    parent. Decision: m3d-review-fixes.md M1/M2 (2026-08-17)."
  - follow_copy_detection: "git log --follow enables copy detection
    when re-targeting across file creation; gitility's rename pass
    considers rename sources only (design R3). Decision: same."
Follow the allowlist's context-validation format exactly (see
test/differential/allowlist.ex and README); entries must be tight
(operation, fixture, path, follow flag) so any OTHER divergence still
fails. The differential test asserts the DIVERGENT result matches the
allowlisted expectation — the deviation is asserted, not avoided.

M3 [path-history resume prefix must not recharge]. The prefix loop
correctly avoids commit-visit recharges but then does read_payload +
decode + full tree-diff for EVERY prefix commit with real object
charges (measured: page N costs O(N) objects against a fresh budget —
quadratic total, and pages beyond ~22k commits can never succeed).
FIX: wrap the prefix-side payload reads and path_change tree-diffs in
the same charge-suspension seam log.rs uses (real reads, no
max_objects charge; retargeting still recomputed); add the mirror of
log.rs's cursor_prefixes_do_not_recharge regression test with a
page-cost measurement (page 40's objects_read within a small constant
of page 1's).

M4 [stepped ranges]. lines: 1..10//2 silently expands to 1..10. FIX:
accept only step 1 (and the descending normalization already tested);
any other step → :invalid_argument, consistent with validate_lines/1
eleven lines above. Add the test.

M5 [history pathspec surface]. path_change passes the raw path as a
pathspec (wildmatch + :(glob) magic honored) while the root-commit
branch is literal-only → "*.txt" silently loses the root commit;
blame/3 rejects the same input. FIX: history/3 rejects pathspec
metacharacters/magic with :invalid_argument exactly as blame does
(literal path only; document). Add tests for "*.txt" and ":(glob)…".

LOW batch (all in scope):
- L2: collapse check_bytes' per-64KiB Budget::check loop to a single
  check (the checks are consecutive with no work between — same
  theatre class as M3b H3; the real cadence lives in the object-store
  loads).
- L3: document in blame/3 @doc + Blame moduledoc: symlink/gitlink
  paths are :invalid_argument (deliberate, R2); git blames symlink
  target text — capability difference stated.
- L4: comment on BlameObjectStore documenting whole-call retention
  bounded by max_total_object_bytes.
- L5: extract the duplicated rewrite_platform construction (diff.rs +
  blame.rs) into one shared helper — H1 touches it anyway.
- L6: Blame.Hunk.summary and Commit.subject typespecs → binary()
  (raw bytes by design; String.t() lies).
- L7: rename the cancellation test to say what it blocks (the
  mandatory HEAD-blob read).
- L8: add a comment to scripts/check-thread-spawns.sh scoping its
  coverage (workspace + vendored sources; crates.io deps are audited
  manually at pin-bump time — gix-blame 0.16.0 audited 2026-08-17,
  clean).
- L9: document the asymmetry: history on a never-existed path is an
  empty page (matches git log); blame is :invalid_path.
- L10: design doc line ~192 reconciled: follow_renames defaults true
  (M3d decision), the "behind explicit follow_renames: true" wording
  updated.

Report at the end: per-finding summary with empirical evidence (H1
branch chosen + the bin1/binary.dat parity or refusal output, the M3
page-cost measurement before/after, the allowlisted differential runs
showing the asserted divergences), test counts (plain + loom), any NEW
divergence for triage, Elixir edits not BEAM-verified, deviations from
this file.
