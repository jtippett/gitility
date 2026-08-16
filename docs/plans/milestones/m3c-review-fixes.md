# M3c review fixes — decisions and dispatch

Adversarial review of the M3c checkpoint (edf703c; spec:
docs/plans/milestones/m3c-structured-diff.md) produced the findings
below, each empirically reproduced via a probe crate calling
gitility_core::diff::diff directly. Decisions here are FINAL; where
they refine the original spec, this file wins. Same constraints: NO
BEAM — Rust-side verification only; Elixir files edited but never
executed; do not commit.

H1 [max_diff_files drops every file after the first]. The walk
callback sets stopped_by at the ceiling and the content loop breaks
after pushing ONE file — max_diff_files: 5 returns 1 file. Both
existing tests used the single masking value (limit 1). FIX: separate
the walk-truncation flag from the populate-truncation flag; the emit
loop breaks only when populate itself stopped; fold the walk flag into
stopped_by afterwards. Tests (Rust + Elixir): max_diff_files: 3 emits
EXACTLY 3 files + truncated + stopped_by; hunk/line ceilings keep
their verified behavior.

H2 [newline-only changes must not vanish]. LinesWithoutLf strips the
trailing \n from every token before interning, so "y" == "y\n" — a
file whose only change is gaining/losing its trailing newline diffs as
NO change (0 hunks, +0 -0; git says 1 1). FIX: tokenize WITH the
newline; strip it only when materialising DiffLine.content. DTO gains
losslessness: Diff.Line gets `no_newline: boolean` (default false;
true when this line is its side's final line and that side lacks a
trailing newline) — mirrors git's "\ No newline at end of file" so a
formatter can reproduce git byte-for-byte. Elixir type module +
typedoc + NIF encoding updated. Fixtures: add a PURE trailing-newline
toggle (bytes otherwise identical). Oracle: parse the "\ No newline"
marker onto the preceding line's record instead of discarding it;
differential case compares the flag.

H3 [zero-length hunk sides are off by one]. gix's before_hunk_start is
passed through; git reports the line BEFORE the gap when a side has
zero lines (pure add: git @@ -0,0 +1 @@, ours @@ -1,0 +1,1 @@). FIX:
per side, if lines == 0 then start = start.saturating_sub(1). Rust
probes + differential patch cases at -U0 including a MID-FILE pure
insertion (where this is loudest) and pure add/delete files at -U0
and -U3.

H4 [Hex package cannot build — vendor missing from mix.exs]. files:
ships crates/gitility-core/Cargo.toml + src only; the manifest now
references vendor/gix-diff which would be absent from the tarball
(build failure at manifest resolution), and the vendored LICENSE files
would not ship (license compliance). FIX: add
"crates/gitility-core/vendor" to mix.exs files:.

M1 [copies: true is CUT from 0.x]. Upstream gix 0.66.0 copy tracking
(faithfully vendored) scores candidates against the POST-image blob,
reports old_oid as a blob that does not exist at old_path in the base
tree, and marks modification sources emitted — silently DROPPING the
source file's own M record from the diff (git: C100 + M, 22 records;
ours: one copied record, 21). Silent data loss is disqualifying for an
agent-facing diff. DECISION: copies: true now returns
{:error, :unsupported_operation} with details naming the upstream
defect class; the option stays in the API surface (copies: false is
the only accepted value). @doc explains why and that it returns when
upstream copy tracking is sound (or we patch our vendored tracker —
post-1.0 decision). Remove the -C differential case (leave the copy
fixture shape in place with a comment); milestone test asserts the
:unsupported_operation shape. Design doc M3 decision record gets a
paragraph (cite this file). Do NOT patch the vendored tracker in this
round.

M2 [similarity must truncate, not round]. git computes the percentage
by integer truncation; ours rounds (66.67% → git 66, ours 67). FIX:
floor. Fixture (see M4) adds a case whose score lands in 49–51% and a
case with fractional percentage ≠ .5 so floor-vs-round discriminates;
differential compares exact integer scores for ALL detected rename
pairs, not just the clean one.

M3 [type-change patch tier — deterministic two-phase hunks]. git's
patch splits a T record into delete+add file sections; our synthetic
hunk diffs old content against the symlink target as one file
(misleading context lines possible). DECISION: for :type_changed at
:patch, emit exactly two hunks — a pure deletion of the old content,
then a pure insertion of the new content (old/new numbering per side,
H3 start rule applies). Differential comparator maps git's two
sections onto our single record's hunk pair (bespoke, commented).
@doc documents the representation. Add a symlink→symlink content
change fixture (status :modified — verify against git) so type-stable
symlink diffs are also pinned.

M4 [fixture generator awk "\\n" bug]. Inside single-quoted awk
programs "\\n" is backslash+n, so the ~90% rename fixture is 28 merged
lines and the "borderline" rename is 11 lines that neither git nor gix
detects — the discriminating boundary shape never existed. FIX: use
proper \n in awk printf; regenerate; verify the borderline pair is
DETECTED by git at 50% with a score in 49–51, and assert our parity on
it (M2). Keep determinism (two byte-identical generations).

M5 [pathspecs must scope the walk and precede rename detection]. The
matcher runs in the emit callback: scoped and unscoped runs read the
same objects, ceilings cannot stop non-matching subtrees, rename
detection sees the unfiltered change set (a rename whose source lies
outside the pathspec reports :renamed where git reports an add), and
only the destination path is ever matched. FIX: prune the tree walk
with the pathspec exactly as list_tree does (literal-prefix fast path
included); apply the filter BEFORE the rewrite tracker so rename
detection operates on the filtered set (git parity: source outside
pathspec → :added). Differential case: rename with source outside the
pathspec scope. Stats: scoped run must read strictly fewer objects
than unscoped on the fixture (Rust assertion).

M6 [renames buffer the full change set — document the cost]. The
rewrite tracker inherently buffers all changes and scores before the
first emission, so max_diff_files cannot bound that phase (budget
timeout/byte ceilings still do; the cadence checks verified in review
still run). DECISION: document in diff/3 @doc (renames: :similarity is
O(changes) before the first record, ceilings bound output not
detection work) — M3a H5 precedent. No mechanism change.

M7 [spawn guard must scan the vendor]. scripts/check-thread-spawns.sh
only scans crates/gitility-core/src and native/gitility/src; the
vendored gix-diff is first-party NIF-linked source it never sees. FIX:
add crates/gitility-core/vendor to the scanned roots (the vendored
code is clean today; the guard must prove it stays clean across
re-vendors).

LOW batch (all in scope):
- L1: Diff.Hunk.header stays nil in 0.x — document it as reserved
  (moduledoc + typedoc), not silently absent.
- L2: rewrite the vendor Cargo.toml header comment to enumerate EVERY
  divergence from crates.io (manifest: exact = pins, path-dep removal,
  gix-tempfile default-features=false edge, [lints.clippy] allows,
  test=false; source: removed cfg(test) module) and a correct upgrade
  procedure (re-copy src/, re-apply manifest by diffing the OLD vendor
  manifest against upstream's, re-run the full gate).
- L3: don't read the root trees twice (or account the re-read in
  payload_rereads per the M3b convention) — pick the cheaper fix.
- L4: oversize rename-candidate reads are counted + warned at EVERY
  tier, not just :summary.
- L5: fixtures/MANIFEST.md gains sha1-diff.git AND the missing
  sha1-search.git entry.
- L7: one @doc sentence on union reads: an object read that ERRORS in
  the head store is fail-fast and is not retried against base (misses
  fall through; errors do not).
- L6 is REJECTED (do not trim the vendored blob pipeline): verified
  unreachable in our configuration; keeping the vendor verbatim
  minimizes re-vendor drift. Note it as a post-1.0 option in the
  vendor comment only.

Report at the end: per-finding summary with empirical evidence (the
max_diff_files: 3 run, the trailing-newline toggle diff, -U0 headers
vs git, the detected borderline rename score, scoped-vs-unscoped
objects_read), test counts (plain + loom), any residual divergence for
triage, the list of Elixir edits not verified without a BEAM, and any
deviation from this file.
