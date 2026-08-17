# M4b spike — turso incremental blob I/O vs the bundle chunk schema

A SHORT, throwaway-adjacent spike (crates/bundle-spike, modeled on the
F6 spike crate) answering the bundle format spec's open question 1
(docs/plans/2026-08-17-bundle-format-v1.md) BEFORE the format freezes:

Q: Does the turso_core engine (pinned =0.7.2 like the F6 spike, or the
newest version compatible with our workspace — record which) support
INCREMENTAL (streaming/offset) blob reads against
  (a) a WITHOUT ROWID table with the blob in the primary B-tree, and
  (b) an ordinary rowid table with a blob column,
and at what read granularity/cost?

Method:
1. Build a test database with BOTH chunk-table shapes holding identical
   1 MiB chunks (256 MiB total), written through turso.
2. For each shape: read back (i) whole chunks sequentially, (ii) 64 KiB
   sub-ranges at random offsets within chunks, (iii) the tail chunk.
   Measure throughput and allocation behavior (does a sub-range read
   materialize the whole row?). If turso lacks a true incremental blob
   API, document exactly what the closest read path is (row
   materialization cost) and measure it.
3. Repeat (read-only) with the rusqlite+bundled fallback via its
   documented incremental Blob API on the SAME database files —
   confirming the fallback seam works on turso-written files and
   measuring the same three patterns.
4. Verify single-file discipline: after writer close + WAL checkpoint
   TRUNCATE + journal_mode=DELETE, no sidecar files remain and a
   read-only open works on a chmod-444 copy (immutable semantics).
5. Report: a table of results, the recommended chunk-table shape for
   format v1 (WITHOUT ROWID or rowid), whether 1 MiB chunks remain the
   right size given the measured row-materialization behavior, and any
   turso blocker that would trigger the recorded rusqlite fallback.

HARD CONSTRAINTS: NO BEAM. The spike crate is workspace-member but
excluded from the NIF dependency tree (like f6-spike); thread use inside
the spike is allowed ONLY within the spike (it never ships); spawn guard
must stay green for the SHIPPING crates (the guard's scope comment
covers this). No changes to gitility-core, native/, or lib/. Do not
commit. cargo test -p bundle-spike + cargo fmt/clippy for the spike
itself. Keep it under ~500 lines.
