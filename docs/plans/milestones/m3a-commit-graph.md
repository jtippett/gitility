# M3a — commit graph: log, merge_base, ancestor?

You are implementing Milestone 3a of Gitility. READ FIRST, in this order:
1. docs/plans/2026-08-14-gitility-design.md — "Commit graph and history"
   (log API), "Ancestry and plumbing", "Cursors" (wire format v1 —
   operation tag 0x03 is already reserved for log), "Limits and safety",
   "Error model", and the Milestone 3 section.
2. crates/gitility-core/src/ — snapshot.rs, decode.rs (commit decoding
   exists), cursor.rs (v1 codec exists; list_tree/search tags in use),
   odb.rs (the Odb trait every store implements), budget.rs.
3. lib/gitility.ex + lib/gitility/page.ex + test/milestone_1c_query_test.exs
   for the established query/Page/limits/job idioms.
4. test/differential/README.md + oracle.ex — the differential harness and
   allowlist policy.

ABSOLUTE CONSTRAINT — NO BEAM: do NOT run mix test, mix compile, iex, or
anything that loads the NIF into a BEAM (docs/reports/
2026-08-14-kernel-panic-thread-leak.md). Verification is Rust-side only:
cargo test -p gitility-core; RUSTFLAGS="--cfg loom" cargo test -p
gitility-core --release (existing models must stay green — this milestone
must not touch runtime internals); cargo check -p gitility; cargo clippy
--workspace --all-targets -- -D warnings (both cfgs); cargo fmt --all
--check; bash scripts/check-thread-spawns.sh. Elixir files are EDITED but
not executed; list every Elixir edit you could not verify in your report.

Write surface: crates/gitility-core/, native/gitility/, lib/, test/,
fixtures/ (generation scripts only — fixtures/generated self-builds),
root Cargo.lock. Do not commit. Decisions below are final.

R1 [dependencies — evidence from vendored sources]. Commit walking and
merge-base come from the gitoxide plumbing crates. READ sources/gitoxide
(house convention — the vendored checkout matches our exact pins; do not
guess from docs) to determine which crates provide the commit walk
(gix-traverse / gix-revwalk) and merge-base (gix-revision) at versions
consistent with the pinned gix-odb =0.83.0 workspace, and pin them
exactly with default-features = false plus only the features our code
needs. HARD CONSTRAINT: no new dependency may introduce threads or
thread-pool crates — after `cargo update -w` confirm rayon, crossbeam-*
gain no new paths into gitility-core's tree (dev-deps excluded), and
scripts/check-thread-spawns.sh must stay green. Record file:line
evidence for what each new crate contributes. Any public-API-affecting
pin change goes through scripts/check-public-api.sh as documented in
Cargo.toml.

R2 [core log walk]. New module (suggest crates/gitility-core/src/log.rs):
walk commits from a snapshot's commit, over any Odb implementation, with:
- order: Chronological (default; commit-time priority, newest first —
  matches `git log`), Topological (`git log --topo-order`), DateOrder
  (`git log --date-order`). Use the vendored traversal machinery where it
  fits; deterministic tie-breaking is REQUIRED for equal timestamps
  (break ties by descending OID bytes) so cursor resume and differential
  runs are reproducible.
- first_parent: bool — follow only first parents.
- since / until: Option<i64> Unix seconds filtering on COMMITTER time,
  matching `git log --since/--until` semantics as closely as the walk
  allows; divergences surface in the differential suite and are triaged,
  never silently absorbed.
- limit + cursor: page results through cursor wire v1, operation tag
  0x03, position payload = last emitted commit digest (already specified
  in the design doc). Resume re-runs the walk and skips until strictly
  after the position digest; document that resume cost is O(prefix).
  Fingerprint covers normalized order/first_parent/since/until.
- Budget::check per visited commit; deadline/cancel interrupts mid-walk
  (this is the M2 cooperative-deadline seam — no new mechanism).
- Limits: max_objects bounds commits VISITED (not just emitted);
  max_results bounds the page; exceeding a ceiling is a truncated
  successful page with a cursor, per the error-model section.
- Missing parent object → :missing_object with the oid in details;
  a shallow boundary marker, if the ODB exposes one, → :shallow_boundary.

R3 [commit DTO]. Each emitted commit carries: id, parents (in stored
order), tree id, author and committer (name/email raw bytes, unix
seconds, tz offset minutes), subject (first line, capped at 1 KiB),
message_raw (capped at 64 KiB with an explicit truncated flag),
signature_headers (raw header names present, e.g. "gpgsig" — names only,
not payloads), and encoding header if present. All byte fields are
untrusted bytes end-to-end — no UTF-8 assumptions in core; Elixir side
exposes binaries.

R4 [merge_base + ancestor?]. Core functions over any Odb:
- merge_base(left, right) → all best common ancestors (the full set, as
  `git merge-base --all`), deterministic order (descending OID).
- ancestor?(a, d) → bool, implemented via the same machinery.
Both take Budget + Limits (max_objects bounds the traversal) and are
cancellable. Disjoint histories → Ok(empty) / Ok(false), not an error.

R5 [NIF + Elixir API]. Follow the existing job-submission idioms exactly
(NativeSupport.submit_job / await_sync; DirtyCpu where the established
pattern uses it):
- Gitility.log(snapshot, opts) → {:ok, %Gitility.Page{}} with
  %Gitility.Commit{} items. opts: order: :chronological (default) |
  :topological | :date, first_parent: false, since: nil, until: nil
  (DateTime or Unix integer seconds; DateTime converts in Elixir),
  limit:, cursor:, limits:.
- Gitility.merge_base(odb_or_snapshot, left, right, opts \\ []) —
  all: false (default) → {:ok, %OID{} | nil} (first of the deterministic
  set); all: true → {:ok, [%OID{}]}.
- Gitility.ancestor?(odb_or_snapshot, ancestor, descendant, opts \\ [])
  → {:ok, boolean()}.
- Accept %Snapshot{} (uses its ODB) or %ODB{} where the design says
  repo_or_odb; %Repository{} composition is Milestone 4.
- OIDs accepted as %OID{} or hex binaries, like Snapshot.open.

R6 [fixtures]. Add a generated fixture repo "sha1-graph.git" alongside
the existing generation scripts (fixtures self-generate; keep the
convention — nothing under fixtures/generated is committed or synced):
at least 3 merged branches; one octopus merge (3+ parents); a
criss-cross merge giving exactly two merge bases; deliberate clock skew
(a child with committer time EARLIER than its parent); an annotated tag
on a merge commit; and a ≥200-commit linear tail for cursor pagination
and cancellation tests. Commit timestamps must be fixed/deterministic so
differential runs are stable.

R7 [differential tests]. Extend test/differential/ following the
existing oracle/harness idioms and the empty-allowlist policy:
- log parity vs pinned git: default order, --topo-order, --date-order,
  --first-parent, --since/--until, on sha1-graph.git and the existing
  history fixtures; compare full ordered commit-id sequences.
- merge-base parity: `git merge-base`, `git merge-base --all`,
  `git merge-base --is-ancestor` across the criss-cross and octopus
  cases plus disjoint-history and identical-commit edges.
Any divergence you observe: do NOT add allowlist entries — report each
one with the exact case for triage (allowlist changes are a review
event per test/differential/README.md).

R8 [Elixir tests — written, not run]. test/milestone_3a_commit_graph_test.exs
covering: every option combination's happy path; cursor round-trip and
:invalid_cursor on option changes; truncation pages with warnings;
merge_base/ancestor? shapes; :missing_object on a hole-punched static
ODB; cancellation mid-walk (large fixture + tiny timeout → :timeout,
using the M2b sync-wrapper semantics); all via start_supervised!
fixtures, never start_link to the test process.

Report at the end: per-requirement summary; Rust test counts (plain +
loom); new dependency pins with vendored-source evidence; every
divergence observed against git with its exact case; the list of Elixir
edits not verified without a BEAM; any deviation from this spec.
