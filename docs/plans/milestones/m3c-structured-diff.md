# M3c — structured diff: summary/stats/patch, renames, cross-ODB union

You are implementing Milestone 3c of Gitility. READ FIRST, in this order:
1. docs/plans/2026-08-14-gitility-design.md — "Diff" (the API and the
   cross-ODB union paragraph), "Limits and safety" (max_diff_files /
   max_diff_hunks / max_diff_lines), "Error model", Milestone 3.
2. lib/gitility/types/diff.ex — the DTO is ALREADY DESIGNED (Diff /
   Diff.File / Diff.Hunk / Diff.Line, format tiers :summary → :stats →
   :patch). Implement to it exactly; diff/3 returns %Gitility.Diff{},
   NOT a Page, and has NO cursor — truncation is flag + warnings only.
3. crates/gitility-core/src/ — tree.rs, layered_odb.rs (union-read
   candidate machinery), search.rs + log.rs (M3a/M3b idioms: budget
   charging, page/DTO assembly, binary heuristic — REUSE the existing
   8000-byte NUL classifier, do not write a second one), odb.rs,
   budget.rs, snapshot.rs.
4. lib/gitility.ex (diff/3 + async_diff/3 stubs), test/differential/
   README.md + oracle.ex.

ABSOLUTE CONSTRAINT — NO BEAM: do NOT run mix test, mix compile, iex,
or anything that loads the NIF into a BEAM (docs/reports/
2026-08-14-kernel-panic-thread-leak.md). Verification is Rust-side only:
cargo test -p gitility-core; RUSTFLAGS="--cfg loom" cargo test -p
gitility-core --release (existing models stay green — runtime internals
untouched beyond one new JobOutput variant); cargo check -p gitility;
cargo clippy --workspace --all-targets -- -D warnings (both cfgs);
cargo fmt --all --check; bash scripts/check-thread-spawns.sh. Elixir
files are EDITED but not executed; list every Elixir edit you could not
verify in your report.

Write surface: crates/gitility-core/, native/gitility/, lib/, test/,
fixtures/ (generation scripts only), root Cargo.lock. Do not commit.
Decisions below are final.

R1 [dependencies — vendored evidence]. Tree and blob diffing come from
the gitoxide plumbing crates. READ sources/gitoxide (house convention;
the vendored checkout matches our pins — do not guess from docs) to
determine the gix-diff version consistent with the pinned gix-odb
=0.83.0 workspace, what it provides for (a) two-tree change streams,
(b) blob content diffing (imara-diff underneath), and (c) rename/copy
rewrite tracking; pin exactly with default-features = false plus only
needed features. HARD CONSTRAINT: no thread or thread-pool crates may
enter gitility-core's normal tree (rayon, crossbeam-*) — verify after
`cargo update -w`; spawn guard stays green. Record file:line evidence
for what each crate/feature contributes. Diffing is STRICTLY SEQUENTIAL.

R2 [core diff]. New module (suggest crates/gitility-core/src/diff.rs):
diff two snapshots' trees over one or two ODBs.
- UNION READS (design-doc contract): the two snapshots may come from
  DIFFERENT ODBs. Objects are content-addressed; resolve every read
  through head's store first, then base's (a miss falls through; a real
  error is fail-fast — reuse or mirror layered_odb's read semantics,
  citing what you reuse). Same hash algorithm required
  (:hash_mismatch), same runtime (:runtime_mismatch) — validate at the
  Elixir/NIF boundary where the existing checks live.
- Change stream: deterministic order (git diff-tree order — byte order
  of paths). pathspecs: scope the walk exactly as list_tree/search do.
- format tiers: :summary (file records only), :stats (adds per-file
  additions/deletions), :patch (adds hunks + lines). Costs scale with
  the tier: :summary must not read blob payloads at all (tree entries
  only — except rename detection when enabled, which reads candidate
  payloads; account it), :stats/:patch read only changed pairs.
- Statuses: :added, :deleted, :modified, :renamed, :copied,
  :type_changed, exactly as the DTO defines. Mode-only changes are
  :modified with equal OIDs and different modes (git parity). Gitlinks
  (mode 160000) appear as file records with modes+OIDs and NO hunks,
  binary: false. Symlink targets diff as content (git parity).
- renames: :similarity | false (default :similarity per the design
  example? NO — default false: rename detection costs payload reads;
  the design example passes it explicitly. Document the default).
  copies: false default; true detects copies among rename candidates
  (like git -C, sources limited to changed paths — document that we do
  NOT do --find-copies-harder). Similarity scoring uses the gix
  rewrites machinery; expose the score in the DTO's 0..100 scale.
  Where gix's candidate selection deviates from canonical git, do NOT
  hack toward git — the deviation is EXPECTED and documented (design
  R3/F5 language); differential divergences get reported for triage.
- Blob diffing: imara-diff HISTOGRAM algorithm (gix default). The
  differential oracle pins `git diff --diff-algorithm=histogram` for
  comparability; where the two histogram implementations still split
  hunks differently, report for triage — never absorb silently.
- Binary pairs: classified by the EXISTING 8000-byte NUL heuristic on
  either side → binary: true, no hunks, additions/deletions nil (stats
  tier) — git parity ("Bin" lines). No text fallback option in 0.x.
- context_lines: 0..32 (default 3), :invalid_argument above the cap,
  same validation conventions as search.
- Limits: max_diff_files / max_diff_hunks / max_diff_lines ceilings —
  exceeding one yields truncated: true + a warning naming the limit
  (M1c idiom); ceilings bound WORK, so stop scanning when hit, do not
  post-filter. max_object_bytes: a blob pair with either side larger
  is emitted as a file record with binary:-style suppressed content
  (hunks omitted) + an oversize warning naming max_object_bytes —
  never an error, never silent (M3b M9 precedent, including the lying
  provider header case). max_objects bounds tree+blob visits;
  Budget::check per file pair and per 64 KiB of blob bytes compared
  (M3b H3 cadence discipline — no up-front check burning).
- Same-snapshot diff → empty files list, truncated: false. Disjoint
  roots are fine (two unrelated snapshots diff as full add/delete).

R3 [NIF + Elixir API]. M3a/M3b job idioms exactly (job_submit, one new
JobOutput variant):
- Gitility.diff(base_snapshot, head_snapshot, opts) → {:ok, %Diff{}}.
  opts: format: :patch default (the design example shows :patch;
  cheaper tiers are opt-in), pathspecs:, context_lines: 3, renames:
  false, copies: false, limits:. Wrongly-typed opts raise
  ArgumentError; semantic invalids → :invalid_argument; non-Snapshot
  args → :invalid_argument (L5 convention). copies: true with
  renames: false is :invalid_argument (copies are found by the rename
  machinery).
- async_diff/3 mirrors async_log/2. Stats: files_scanned, bytes_read,
  the usual counters; stopped_by names the diff limit that truncated.
- All byte fields (paths, line content, hunk header) are raw binaries
  end-to-end — non-UTF-8 paths and content survive losslessly.

R4 [fixtures]. Extend fixtures/generate.sh with "sha1-diff.git":
deterministic history with OIDS keys sha1_diff_base and sha1_diff_head
naming two commits whose tree pair covers: pure add; pure delete;
in-place modify (mid-file edit producing ≥2 hunks at context 3); a
CLEAN rename (100% similarity, content identical); a rename+edit
(~90%); a BORDERLINE rename (similarity near 50% — discriminates
scoring); a copy (original kept + near-copy added); mode-only change
(100644→100755, same blob); type change (file→symlink); binary→binary
change (NUL in first 8000 bytes both sides); text→binary transition;
a non-UTF-8 (Latin-1) path AND non-UTF-8 content change; CRLF file
edit; an empty-file add; a gitlink (submodule entry) add and bump
(commit OIDs may be synthetic/unreachable — diff must not need to read
them); a file whose edit is exactly at EOF without trailing newline.
Also a second, PATHSPEC-scoped region (dir sub/ with its own changes).
Deterministic timestamps; self-verifying like existing fixtures.

R5 [differential]. test/differential/diff_parity_test.exs against
pinned git 2.55.0, empty-allowlist policy, using -z/NUL-safe parsing
throughout (M3b L16 lesson — never parse unquoted paths):
- file records: `git diff-tree -r -z --no-renames base head` vs
  :summary with renames: false — status, paths, modes, OIDs.
- renames: `git diff-tree -r -z -M base head` (and -C for copies) vs
  renames: :similarity — compare pair sets and statuses; compare
  similarity scores as EQUAL-BUCKET (identical integer) only for the
  clean-rename case, report others for triage if they differ.
- stats: `git diff --numstat -z` vs :stats tier (additions/deletions,
  binary "-" handling).
- patch: `git diff --diff-algorithm=histogram -U<n> base head` for
  n in {0, 3} vs :patch — compare per-file hunk headers
  (old_start/old_lines/new_start/new_lines) and line
  origin+content sequences. Any hunk-split divergence: report, don't
  absorb.
- pathspec-scoped run over sub/ with :(glob) magic (M3b M5 lesson).
- also run the file-record comparison across TWO parent→child pairs of
  the existing sha1-graph.git (real-history shapes, not just the
  bespoke fixture).
Every divergence reported with its exact case for triage; allowlist
untouched.

R6 [Elixir tests — written, not run].
test/milestone_3c_diff_test.exs: happy path per format tier; option
validation (typed raise / semantic :invalid_argument, copies-without-
renames); rename + copy + type-change + gitlink shapes through the
API; binary + oversize suppression warnings; truncation by each
max_diff_* limit with stopped_by; CROSS-ODB union diff (two static
ODBs via from_objects — base objects in one, head in the other,
verify identical result to same-ODB diff and that :hash_mismatch /
:runtime_mismatch shapes fire); non-UTF-8 path/content round-trip;
deterministic mid-diff cancellation via the M3b blocking-backend
pattern (block on a BLOB read); async_diff mirror; start_supervised!
throughout. Follow M3b's setup idiom: resolve commits via OIDS keys +
{:oid, ...} — ref selectors are Milestone 4 and MUST NOT appear.

Report at the end: per-requirement summary; Rust test counts (plain +
loom); dependency pins with vendored-source evidence; every divergence
observed against git with its exact case; the similarity-score
comparison outcome; the list of Elixir edits not verified without a
BEAM; any deviation from this spec.
