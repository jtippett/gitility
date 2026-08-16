# M3b — content search: literal and safe-regex snapshot search

You are implementing Milestone 3b of Gitility. READ FIRST, in this order:
1. docs/plans/2026-08-14-gitility-design.md — "Content search", "Cursors"
   (wire format v1: search tag 0x02; its position payload was AMENDED
   2026-08-16 to `u32 LE match ordinal + raw path bytes` — read the
   current text, not your memory of it), "Limits and safety", "Error
   model", and the Milestone 3 section.
2. crates/gitility-core/src/ — tree.rs (the paginated tree walk you will
   reuse), pathspec.rs, file.rs (bounded blob reads), cursor.rs, log.rs
   (M3a idioms: budget charging, cursor fingerprinting, page assembly),
   odb.rs (try_find / try_find_graph seams), budget.rs.
3. lib/gitility.ex (search/3 + async_search/3 stubs exist),
   lib/gitility/types/search_match.ex (the DTO — already designed),
   lib/gitility/page.ex, test/milestone_3a_commit_graph_test.exs for the
   established job/Page/limits idioms.
4. test/differential/README.md + oracle.ex — harness and allowlist policy.

ABSOLUTE CONSTRAINT — NO BEAM: do NOT run mix test, mix compile, iex, or
anything that loads the NIF into a BEAM (docs/reports/
2026-08-14-kernel-panic-thread-leak.md). Verification is Rust-side only:
cargo test -p gitility-core; RUSTFLAGS="--cfg loom" cargo test -p
gitility-core --release (existing models stay green — do not touch
runtime internals); cargo check -p gitility; cargo clippy --workspace
--all-targets -- -D warnings (both cfgs); cargo fmt --all --check; bash
scripts/check-thread-spawns.sh. Elixir files are EDITED but not executed;
list every Elixir edit you could not verify in your report.

Write surface: crates/gitility-core/, native/gitility/, lib/, test/,
fixtures/ (generation scripts only), root Cargo.lock. Do not commit.
Decisions below are final.

R1 [dependency — the regex crate, minimal features]. Matching uses the
`regex` crate's bytes API (`regex::bytes`) — linear-time guarantee, no
backtracking. Pin exactly (`=`), default-features = false, enabling only
the features the code needs (start from `std`; add `unicode-case` only
if R3's case folding requires it; add nothing else without recording
why). HARD CONSTRAINT: no new dependency may introduce threads or
thread-pool crates — after `cargo update -w` confirm rayon/crossbeam-*
gain no new paths into gitility-core's tree (dev-deps excluded), and
scripts/check-thread-spawns.sh stays green. The search scan itself is
STRICTLY SEQUENTIAL — no internal parallelism of any kind (the design
doc's "internal parallelism within the job's budget" allowance is NOT
taken up in 0.x; the thread budget forbids it). Record the pin and
feature evidence in your report. Any public-API-affecting change goes
through scripts/check-public-api.sh reasoning as documented in Cargo.toml.

R2 [core search — walk, dedup, scan]. New module (suggest
crates/gitility-core/src/search.rs): search a snapshot's tree for a
byte pattern.
- Traversal: reuse the tree-walk machinery (tree.rs) in its
  deterministic git ls-tree order, scoped by `path:` (a tree scope, same
  resolution rules as list_tree — nonexistent scope → :invalid_path)
  and filtered by `pathspecs:` (pathspec.rs semantics, resolved relative
  to the scope, exactly as list_tree does).
- Dedup: cache fixed-size matching-line spans by blob OID; matches are still
  REPORTED per path in traversal order. The entry-count-bounded LRU never
  retains payload/excerpt copies. Duplicate paths and evictions may physically
  re-read and deterministically re-scan a blob, recorded as payload_rereads,
  while logical bytes-read accounting charges each unique blob once.
- Prefetch: where the ODB exposes the existing prefetch seam, batch pending
  unique blob OIDs in windows of at most 64; scanning stays sequential.
- Literal search checks between overlapped 64 KiB windows. Regex checks per
  line and per yielded find; one matchless line pass is its cancellation floor,
  bounded by max_object_bytes.
- Limits: max_objects bounds blobs VISITED (scanned or cache-hit);
  max_results bounds emitted matches per page; max_result_bytes bounds
  the page's total payload; max_object_bytes bounds each blob —
  a blob LARGER than max_object_bytes is NOT read: it is skipped and
  counted (see R4 stats; never a silent drop, never an error).
  Exceeding a page ceiling mid-walk is a truncated successful page with
  a cursor, per the error model; zero-progress exhaustion is
  :budget_exceeded, except that an unsplittable first valid match is emitted as
  a one-item max_result_bytes-truncated page to guarantee stream progress.

R3 [match semantics]. Options: mode: :literal (default) | :regex;
case_sensitive: true (default).
- :literal — the query is raw bytes, matched verbatim. Case-insensitive
  literal matching compiles the escaped query through the regex engine
  with case folding enabled: ASCII folding ALWAYS works; enable Unicode
  simple case folding only if it does not drag in disproportionate
  features (record the decision either way — the differential oracle
  only certifies ASCII, see R7).
- :regex — regex::bytes syntax over raw bytes, size-limited compile
  (set an explicit compile size limit and dfa size limit; record the
  numbers). A pattern the engine cannot compile (backreferences,
  lookaround, oversized) → :unsupported_regex with the engine's reason
  in details. The regex is compiled ONCE per job.
- Matching is line-oriented, like git grep: a match never spans lines.
  Split on LF; a trailing CR is part of the line's bytes (raw bytes
  end-to-end — no encoding assumptions, non-UTF-8 must survive
  losslessly to the DTO).
- Every match yields: path (raw bytes), blob OID, 1-based line, 0-based
  BYTE column, preview = the matched line's bytes capped at 1 KiB with
  an explicit truncated flag, submatches = at most 256 byte ranges whose starts
  fall within the emitted preview (crossing ranges are clamped; later ranges
  are dropped), plus an explicit submatches_truncated flag,
  and context_before/context_after = up to context_lines: (0 default,
  cap 32 — above the cap is :invalid_argument) neighbouring lines, each
  capped at 1 KiB. Multiple matches on ONE line produce ONE
  SearchMatch whose submatches list them all (column = first match).
  The commit_oid field carries the snapshot's commit.

R4 [binary handling + skip accounting]. binary: :skip (default) | :text.
- :skip — a blob whose FIRST 8000 bytes contain NUL is classified
  binary (git's heuristic; cite git's buffer_is_binary or equivalent
  from your knowledge of the pinned oracle behaviour) and not scanned.
- :text — scan everything as bytes.
Skips are never silent: page stats gain files_scanned, blobs_deduped,
payload_rereads, binary_skipped, oversize_skipped counts, and any page on whose walk a
skip occurred carries a warning naming the reason class and the limit
(oversize names max_object_bytes). Follow the M1c warning idioms.

R5 [cursor — tag 0x02, amended payload]. Wire format v1, operation tag
0x02 (already reserved). Position payload = u32 LE match ordinal within
the file (0-based index over the file's emitted matches in scan order)
followed by the raw path bytes, exactly as the design doc now specifies.
Resume re-runs the walk, skips completed paths, re-scans the position
path (blob scan is deterministic), emits its matches strictly AFTER the
ordinal, then continues with strictly-greater paths; document resume
cost O(prefix paths + one blob re-scan). Fingerprint covers the
normalized query bytes and every option that affects the result stream
(mode, case_sensitive, path scope, pathspecs, binary, context_lines) —
changing any of them with an old cursor → :invalid_cursor. Cursor-resume
prefix traversal follows M3a's H6 rule: skipped-path visits are NOT
recharged against max_objects (use the try_find_graph/without-charge
seam); the position path's re-scan IS charged (it does real work).
Limits values such as max_object_bytes are intentionally not cursor-
fingerprinted, so changing limits between pages can change which later blobs
are scanned; result-affecting search options remain fingerprinted.
MAX_CURSOR_BYTES stays the single cursor.rs constant.

R6 [NIF + Elixir API]. Follow the M3a job idioms exactly (job_submit,
plain-scheduled NIFs, one new JobOutput variant for search pages —
runtime internals untouched):
- Gitility.search(snapshot, query, opts) → {:ok, %Gitility.Page{}} with
  %Gitility.SearchMatch{} items. opts: mode:, case_sensitive:, path:,
  pathspecs:, binary:, context_lines:, limit:, cursor:, limits:.
  query and every pathspec are binaries; wrongly-TYPED option values
  raise ArgumentError, semantically invalid ones return
  {:error, :invalid_argument} (M1c convention). Non-Snapshot first
  argument → {:error, :invalid_argument} (M3a L5 convention).
- Gitility.async_search/3 mirrors async_log/2.
- SearchMatch gains preview_truncated: boolean (update the type module +
  its typedoc — the moduledoc already promises a capped preview).
- Page.stats carries the R4 counters following the existing stats map
  conventions (stats_map in native/gitility/src/lib.rs).

R7 [fixtures + differential]. Extend fixtures/generate.sh with a new
generated repo "sha1-search.git" (deterministic, self-verifying, same
conventions — nothing under fixtures/generated is committed): nested
directories ≥3 deep; the same blob reachable at ≥3 paths (dedup
evidence); a binary blob (NUL in first 8000 bytes) that ALSO contains
the literal needle; a >8000-byte text file with matches after byte
8000; non-UTF-8 (Latin-1) content containing the needle; CRLF line
endings; a file with many matches on one line; a file with enough
matches to span several pages at small limits; an empty file; a file
whose only match is on the last line without trailing newline.
Differential tests (test/differential/, empty-allowlist policy) against
pinned git 2.55.0 `git grep` on the snapshot commit:
- literal, case-sensitive and -insensitive (ASCII needles only):
  `git grep -F [-i] -I --line-number --column --full-name <needle>
  <commit> [-- <pathspec>]` — compare (path, line, column) sequences in
  traversal order, and match counts per path.
- binary: :text vs `git grep -a`. Text-file-only cases may additionally
  compare our preview bytes to the oracle line bytes.
- regex mode is NOT differential-tested against git (different engine
  classes — document this in the test file header); regex correctness
  is covered by Rust unit tests instead.
- cursor pagination reconstruction: full result == concatenation of
  pages at several limits, including a limit that splits one file's
  matches and one line's multi-match group.
Any divergence: do NOT touch the allowlist — report the exact case for
triage (allowlist changes are a review event).

R8 [Elixir tests — written, not run].
test/milestone_3b_search_test.exs: happy paths for every option;
option-fingerprint cursor invalidation; truncation with warnings; skip
accounting (binary + oversize); non-UTF-8 payload round-trip;
:unsupported_regex shape; :invalid_path scope; deterministic
cancellation mid-scan following M3a's M7 blocking-backend pattern;
dedup evidence via stats (same blob at 3 paths → blobs_deduped);
provider-ODB search via the conformance-style backend; all supervised
via start_supervised!.

Report at the end: per-requirement summary; Rust test counts (plain +
loom); the regex pin + feature evidence; every git-grep divergence with
its exact case; the R3 Unicode-folding decision; the list of Elixir
edits not verified without a BEAM; any deviation from this spec.
