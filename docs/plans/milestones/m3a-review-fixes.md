# M3a review fixes — decisions and dispatch

Adversarial review of the uncommitted M3a work (spec:
docs/plans/milestones/m3a-commit-graph.md) produced the findings below,
each verified empirically against git 2.55.0. Decisions here are FINAL;
where they contradict the original spec (H2 explicitly does), this file
wins. Same constraints as the original spec: NO BEAM — Rust-side
verification only (cargo test / loom / clippy both cfgs / fmt / spawn
guard / fixture generation via plain shell+git); Elixir files edited but
never executed; do not commit.

H1 [merge_base single pick — weaken the oracle, not the engine].
`git merge-base` without `--all` picks an arbitrary member of the
best-common-ancestor set (git's own documentation declares the choice
unspecified), so pick-equality is not a valid oracle. DECISION: keep the
descending-OID single pick. Change the differential single-pick case to
assert our pick is a MEMBER of `git merge-base --all`'s set; keep the
`--all` full-set comparison strict (set AND our deterministic order —
compare sorted). Remove the `assert_ne!` in ancestry.rs that hard-codes
the divergence (it becomes meaningless under the member oracle). Add a
`@doc` note on `Gitility.merge_base/4`: with multiple best common
ancestors, canonical git's single result is unspecified; Gitility
deterministically returns the greatest OID; use `all: true` for the set.

H2 [equal-timestamp ties — match git; the original spec was
self-contradictory and the descending-OID tie-break is RESCINDED].
:chronological and :date order must match `git log` / `git log
--date-order` EXACTLY, including tie behavior among equal committer
timestamps: git breaks ties by priority-queue insertion order (a new
commit is inserted AFTER existing entries with equal keys — FIFO among
equals), which is fully deterministic for a given graph and tips, so
cursor resume determinism is preserved with no OID tie-break. Replace
the StableWalk descending-OID grouping with insertion-order semantics
mirroring git's, and verify empirically: extend fixtures/generate.sh's
sha1-graph.git with parallel branches whose commits share identical
committer timestamps (several commits per side with the same second,
spanning more than one page at small limits), regenerate, and add
differential log cases over the equal-time region for all three orders.
Rust-side, compare full sequences against `git rev-list` for default,
--topo-order, and --date-order on the new shapes. Cursor pagination
tests must include a page boundary inside an equal-time group.

H3 [since/until — match git's pruning]. Post-walk filtering diverges
from git under clock skew (ours emitted 10 extra commits on the
fixture's skew region). DECISION: implement git-parity pruning for
`since` — a commit older than `since` stops traversal into its parents
(UNINTERESTING propagation), reproducing git's observed behavior on the
skew fixture, with git 2.55.0 as the empirical oracle. `until` remains a
skip-while-walking filter (already parity-correct). Add a differential
case whose `since` boundary straddles the skew_child/resolved inversion
and Rust probes comparing against `git rev-list --since/--until` there.
If exact parity on some skew shape proves unreachable, DO NOT hack
around it or touch the allowlist — report the residual case for triage.
This also resolves M4 (narrow windows no longer walk the full graph and
must no longer hard-error: an empty window returns an empty untruncated
page).

H4 [shallow — match git: the graph is truncated at shallow roots].
`git rev-list` on a shallow clone stops at grafted commits (8 vs our
13 on sha1-history-shallow.git). DECISION: the ObjectDb trait gains
`shallow_roots(&self) -> Option<...>` (default None, so static/provider
/layered stores are untouched); the local adapter reads `$GIT_DIR/
shallow` at open (tolerating absence; malformed file → :malformed_ref
style error at open, name the file in details). Log, merge_base, and
ancestor? treat shallow roots as parentless — no error, matching git.
The :shallow_boundary error code stays reserved (do not emit it here).
Add sha1-history-shallow.git to the log parity matrix and a Rust unit
test asserting the 8-commit git-equal walk. Run scripts/
check-public-api.sh reasoning by hand as before (no gix types exposed).

H5 [topo/date pre-pass budget — clean refusal with an actionable
error]. Topological and date order inherently require visiting the full
reachable history before the first emit (git buffers the same way);
charging that against max_objects is CORRECT and stays. Make the
refusal actionable: when the pre-pass exhausts max_objects, the error
message and details must say that :topological/:date require
limits.max_objects at or above the reachable commit count and name the
order (details gains order: and the limit atom). Document the cost in
`Gitility.log/2`'s @doc (topo/date: O(history) per call including each
cursor resume; chronological: O(emitted + prefix)). No truncated-empty-
page mechanism — a pre-emit ceiling is a refusal, never a page.

H6 [pagination prefix must not recharge max_objects]. Commits visited
while skipping to a cursor's position (the already-emitted prefix under
:chronological, and the emit-phase prefix under topo/date) are NOT
charged against max_objects — they were paid for by earlier pages.
They remain bounded by timeout_ms and max_total_object_bytes (and, for
topo/date, the pre-pass max_objects charge per H5). Result: paging a
231-commit history with a constant %Limits{max_objects: 60} completes
in 4 pages instead of stalling. Add Rust tests: constant-budget paging
to completion in all three orders; a fresh (non-cursor) call still
truncates at max_objects exactly as today.

M1 [timezone tolerance]. tz_offset_minutes becomes optional (None on
any unparseable/out-of-range tz; -0000 stays Some(0)); raw tz bytes
remain; a bad timezone NEVER fails the page. Mirror git's tolerance —
the probe shapes (+0099, "0000", +051800) must all decode with
tz_offset_minutes = None/nil. Elixir type/doc updated.

M2 [traversal errors name the OID and don't go stale]. The GixFind
adapter records the failing OID with the error; first_error is scoped
so a stale early error cannot mask a later real one; every decode-
failure path surfaces object_oid. Extend the existing hostile/missing
tests to assert the OID appears.

M3 [memory + triple decode]. Stop retaining full commit payloads for
the life of the walk: cache only what the walk needs (committer time,
parents — small fixed-size entries), bound the cache, and hand each
commit's payload to the DTO decode once instead of re-fetching and
re-decoding (currently up to three decodes per commit). Add a test
asserting bytes-read accounting does not multiply per commit.

M5 [no silent drops in release]. The debug_assert-guarded residue in
the tie-order grouping (reachable only via a parent cycle from a lying
ODB) must emit the residue deterministically (descending OID) instead
of dropping it — never fewer commits than the walk produced, never a
silent debug/release divergence. (This code may be superseded by H2's
rewrite; the invariant stands regardless: no silent drops.)

M6 [ancestor? short-circuits]. Implement ancestor? as a genuine
reachability walk from the descendant that stops on finding the
ancestor (budget-checked per visited commit), not a full merge-base
computation. Check sources/gitoxide for reusable machinery first
(house convention; cite file:line either way). Parity: `git merge-base
--is-ancestor` across the existing cases plus a deep case where the
ancestor is near the tip (short-circuit visibly cheaper: assert
objects_read well below history size).

M7 [deterministic cancellation test]. Replace the timeout_ms: 1 race in
milestone_3a_commit_graph_test.exs with a deterministic construction
(e.g. an Elixir-backed ODB whose read blocks until the test releases it,
or a walk long enough that a sub-deadline cannot complete — justify the
choice); assert :timeout without flakiness.

M8 + L6 [documentation of decided semantics]. Update: @doc for log/2
(order semantics incl. git-parity ties, topo/date cost and the H5
refusal, since/until git-parity pruning, shallow truncation), @doc for
merge_base/4 (H1 note) and ancestor?/4; design doc "Commit graph and
history" example gains order: :chronological default mention, and
"Ancestry and plumbing" notes %Repository{} acceptance arrives with
Milestone 4. Record H2/H3/H4 outcomes as one short decision-record
paragraph in the design doc's M3 section (cite this file).

LOW batch (all in scope):
- L1: key fixture regeneration on a hash of generate.sh (stale
  fixtures/generated regenerates automatically instead of panicking on
  a missing OIDS key); document `rm -rf fixtures/generated` as the
  manual reset.
- L2: exercise the annotated tag on the octopus merge in at least one
  test (peel through it into a log walk).
- L3: subject gains a truncated flag symmetric with message_raw.
- L4: single source of truth for MAX_CURSOR_BYTES.
- L5: Gitility.log/2 returns {:error, :invalid_argument} Error on a
  non-Snapshot first argument like merge_base/ancestor? (no
  FunctionClauseError).
- L7: don't materialize gpgsig payloads the log DTO discards.

Report at the end: per-finding summary with the empirical evidence
(git-parity probe outputs for H2/H3/H4, paging runs for H6), test
counts (plain + loom), any residual divergence for triage, the list of
Elixir edits not verified without a BEAM, and any deviation from this
file.
