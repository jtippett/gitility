# M3b review fixes — decisions and dispatch

Adversarial review of the M3b checkpoint (63236c4; spec:
docs/plans/milestones/m3b-content-search.md) produced the findings
below, each verified empirically. Decisions here are FINAL; where they
refine the original spec, this file wins. Same constraints: NO BEAM —
Rust-side verification only (cargo test / loom / clippy both cfgs / fmt
/ spawn guard / fixture generation via plain shell+git); Elixir files
edited but never executed; do not commit.

H1 [a single unsplittable match must never jam the stream].
`SearchMatch::payload_bytes` charges unbounded submatches; a 2 MiB
single-line file (an ordinary minified bundle, under the default
max_object_bytes) produces one match whose accounting exceeds
max_result_bytes, `fit_cursor` pops it to an empty page, and every
subsequent resume returns :budget_exceeded — the stream is permanently
stuck. DECISION, three parts:
  a. submatches include ONLY occurrences that intersect the emitted
     preview (start < preview cap) — occurrences wholly past the cap
     are DROPPED, not clamped to degenerate `{1024, 0}` ranges (this
     also resolves finding 8; restore `pos_integer()` length in the
     submatch typespec if nothing else needs zero). Additionally cap
     submatches at 256 entries. Either form of dropping sets a new
     `submatches_truncated: boolean` flag on SearchMatch (type module +
     typedoc updated).
  b. charge 32 bytes per submatch (approximating the BEAM map cost —
     finding 7), so accounting tracks what actually lands in the VM.
     With (a) a single SearchMatch now has a hard structural byte
     ceiling; state it in a comment.
  c. PROGRESS GUARANTEE: if the FIRST item of a page alone exceeds
     max_result_bytes, emit that single item as a one-item truncated
     page with a warning naming max_result_bytes — never an empty
     :budget_exceeded page when a valid match exists. Rust test: the
     P12 shape (2 MiB single line + one normal file, limit 1, then
     resume) pages to completion.

H2 [bound the scan cache — spans, not bytes]. The per-blob cache
retains preview AND context copies for every match (65× blob-size at
context_lines: 32; ~16 GB reachable under stock limits) and is cloned
whole per path occurrence. DECISION: the cache stores MATCH SPANS ONLY
— per match: line number, byte column, and the byte ranges needed to
re-materialize preview/context from the blob payload (fixed-size
entries, no copied bytes). Bound the cache by entry count with LRU
eviction (reuse lru.rs); an evicted blob is deterministically
re-scanned on next need. Emission materializes preview/context by
slicing the payload in hand at scan time; a DUPLICATE-path cache hit
re-fetches the payload through the uncharged graph seam (logical bytes
stay charged once per unique blob — add a stats counter payload_rereads
so the physical re-read is visible, following M3a M3's precedent).
Never clone the scan result per path — borrow. Rust tests: retained
cache bytes stay flat while scanning a many-match blob at
context_lines: 32; dedup path still yields one logical charge; eviction
+ re-scan produces identical results.

H3 [real cancellation cadence — delete the theatre]
(finding 3). `check_scan_progress` burns ceil(bytes/64Ki) budget checks
up front with no work between them; a single huge line is then scanned
end-to-end uninterrupted. DECISION: delete the up-front loop. Literal
mode scans a long line in 64 KiB windows overlapped by
(query.len() - 1) bytes with Budget::check per window. Regex mode:
Budget::check per find iteration and per line; one matchless regex pass
over one line remains the cancellation-granularity floor, bounded by
max_object_bytes — document that floor in search.rs and in log/2-style
@doc wording for search/3. Rust test: a deadline interrupt lands inside
a multi-window literal scan of a single long line.

H4 [max_objects must bound the live walk] (finding 4). Search routes
ALL tree reads through the uncharged graph seam, so max_objects: 5
happily walks 301 trees (list_tree truncates at 3 under the same
limits). The H6-style exemption was meant for the cursor-resume prefix
ONLY. DECISION: during the live (non-resume) walk, tree reads and blob
visits are charged exactly as list_tree charges them; the uncharged
seam applies only while replaying a resume prefix (already-paid-for
work), and the position path's re-scan stays charged. Rust tests: the
P16 shape truncates/refuses comparably to list_tree; the existing H6
resume test stays green.

M5 [oracle pathspec dialect] (finding 5). The differential oracle
passes pathspecs to git grep raw, i.e. default wildmatch magic where
`*` crosses `/`; gitility implements `:(glob)` semantics. The shipped
cases agree by coincidence. DECISION: `pathspec_arguments/1` emits
`:(glob)<pattern>`; add a `*.txt`-style differential case that
DISAGREES between the two dialects (it must pass only with the magic
prefix — note this in a comment).

M6 [fixture blindness — add the discriminating shapes] (finding 6).
Extend sha1-search.git in fixtures/generate.sh:
  - binary-window boundary blobs: NUL at byte 7999 (binary), NUL at
    byte 8000 (text), both containing the needle after the NUL region;
    differential + Rust cases pin the 8000-byte window exactly.
  - a symlink whose TARGET STRING contains the needle (both engines
    skip it — the existing search.rs claim gets its fixture).
  - a name-prefix pair: file `pages.txt` alongside dir `pages/` (tree
    traversal-order parity now discriminated).
  - a multi-byte UTF-8 line (and a tab-indented line) with a match
    after the multi-byte char / tab; differential case proves byte
    columns match git grep --column.
  - a differential cursor case whose scope spans MULTIPLE files (the
    existing Rust P5-style coverage is fine; the differential
    pagination reconstruction must also cross a file boundary).
Regeneration stays deterministic; restore strictness per L17 below.

M9 [oversize-skip must not degrade into an error on a lying provider
header] (finding 9). An unverified provider header that understates a
blob's size passes the pre-check, then the real read hits ObjectTooLarge
and fails the whole search. DECISION: within blob scanning ONLY, an
ObjectTooLarge outcome is converted to oversize_skipped (counted +
warned, same as the pre-check path), never a job error. Other
ObjectTooLarge sites keep their semantics. Rust test with a
lying-header double.

M10 [prefetch the blobs] (finding 10). Search inherits child-tree
prefetch but never prefetches the objects it actually reads. DECISION:
batch-prefetch pending unique blob OIDs (window of up to 64) through
the EXISTING store prefetch seam where the ODB supports it — a hint
only; scanning stays strictly sequential; no new mechanism, no new
threads. Rust test with the counting provider double: N unique blobs
arrive in ≤ ceil(N/64) prefetch batches rather than 0.

LOW batch (all in scope):
- L12: a page that stopped at `limit` but then shed items in
  fit_cursor reports stopped_by: :max_result_bytes (name what actually
  shaped the page).
- L13: keep :unsupported_regex for non-UTF-8 patterns (it IS a pattern
  the engine cannot compile) but document in search/3 @doc: patterns
  are UTF-8; match ARBITRARY bytes via \xNN escapes.
- L14: cap error.reason strings crossing the NIF at 1 KiB.
- L15: fit_cursor pops to the latest emitted position whose cursor
  fits MAX_CURSOR_BYTES instead of returning ResultTooLarge outright;
  the error remains only when no emitted position fits.
- L16: oracle git grep calls use --null and parse NUL-separated
  fields (kills the 40/64-hex-filename ambiguity); git grep exit 1 =
  empty result set, not an error.
- L17: fixtures/generate.sh — remove the sha1_search_head OIDS
  exemption (the fixture IS deterministic; the exemption silences the
  stability check forever) and restore strict byte-identical OIDS
  comparison (the "each previous line still exists" relaxation no
  longer detects reordering).
- L18: context_lines cap lives in ONE Rust constant; add a Rust test
  pinning it to 32 and a comment in lib/gitility.ex noting the Elixir
  validation mirrors that constant.
- L19: sort pathspecs before fingerprinting (they are OR-ed;
  reordering must not invalidate a cursor). No search cursor has
  shipped, so no compatibility concern.
- L20: drop the dead `_limits_map` computation.
- L21: document (search/3 @doc + SearchMatch moduledoc) that context
  blocks are per-match and may repeat adjacent lines — unlike
  git grep -C, which merges hunks.
- L22: the deterministic cancellation test must block MID-SCAN: the
  blocking backend releases commit/tree reads and blocks on the FIRST
  BLOB read, so the timeout lands in the scan phase, per the original
  R8 intent.
- L11: add a @doc/design-doc line: Limits values (e.g.
  max_object_bytes) are NOT part of the cursor fingerprint — changing
  them between pages changes what later pages can scan; options are
  fingerprinted, limits are not (consistent with M3a).

Report at the end: per-finding summary with empirical evidence (the P12
jam shape paging to completion, cache-bytes-flat measurement, the
window-interrupt test, the P16 charge comparison, prefetch batch
counts), test counts (plain + loom), any residual divergence for
triage, the list of Elixir edits not verified without a BEAM, and any
deviation from this file.
