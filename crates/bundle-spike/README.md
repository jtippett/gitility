# M4b bundle blob-I/O spike

This throwaway-adjacent workspace crate answers bundle-format v1 open question
1. It is test-only, is not in the shipping NIF dependency tree, and uses no
BEAM tooling. It exact-pins `turso_core` 0.7.2 to match the F6 spike and uses
`rusqlite` 0.38.0 with its `blob` and `bundled` features.

The test writes one Turso database containing both candidate chunk shapes.
Each has 256 full 1 MiB chunks with identical content, plus a 64 KiB tail. It
then byte-verifies sequential reads, 512 deterministic random 64 KiB reads,
and the tail through Turso. The same Turso-authored file is opened through
rusqlite's documented incremental `Blob` API. Finally, the writer checkpoints
WAL with `TRUNCATE`, switches to `journal_mode=DELETE`, checks for sidecars,
copies the file read-only, and opens that copy through both engines.

Run the conformance test with:

```console
cargo test -p bundle-spike -- --nocapture
```

For throughput numbers, use a release build and an otherwise idle machine:

```console
cargo test --release -p bundle-spike -- --nocapture
```

## Result

**Use an ordinary rowid table for `gitility_chunks`. Keep the 1 MiB chunk
size. Trigger the bundled-rusqlite fallback for offset reads and single-file
finalization until Turso supplies the missing operations.**

Representative release-profile result on 2026-08-17 (Apple Silicon, warm OS
cache):

| engine | shape | pattern | useful MiB | source/materialized MiB | seconds | useful MiB/s |
|---|---|---|---:|---:|---:|---:|
| turso_core | WITHOUT ROWID | sequential | 256.1 | 256.1 | 0.365 | 701.9 |
| turso_core | WITHOUT ROWID | random 64 KiB | 32.0 | 512.0 | 41.447 | 0.8 |
| turso_core | WITHOUT ROWID | 64 KiB tail | 0.0625 | 0.0625 | 0.079 | 0.8 |
| turso_core | rowid | sequential | 256.1 | 256.1 | 0.095 | 2699.0 |
| turso_core | rowid | random 64 KiB | 32.0 | 512.0 | 0.172 | 185.9 |
| turso_core | rowid | 64 KiB tail | 0.0625 | 0.0625 | ~0.0001 | 650.5 |
| rusqlite Blob | rowid | sequential | 256.1 | 256.1 | 0.050 | 5097.9 |
| rusqlite Blob | rowid | random 64 KiB | 32.0 | 32.0 | 0.063 | 504.2 |
| rusqlite Blob | rowid | 64 KiB tail | 0.0625 | 0.0625 | ~0.00002 | 3978.9 |
| rusqlite Blob | WITHOUT ROWID | all | — | — | — | unsupported |

These are feasibility measurements, not stable performance thresholds. The
database page size is 4 KiB. “Source/materialized” records the logical bytes
the API must expose, not cold physical I/O at the VFS. The short-tail timings
are single operations and therefore only useful as a gross regression signal.

### What the APIs actually do

`turso_core` 0.7.2 has no public incremental/offset Blob handle for either
table shape. Its closest path is a keyed `SELECT bytes`, which decodes the
column into the statement's owned `Value::Blob(Vec<u8>)`; the caller can only
slice after that. Every 64 KiB probe observed a 1,048,576-byte-capacity row
buffer for both shapes (16x amplification), and the address was not
consistently reused across statement resets. The test therefore counts 512
MiB materialized for the 512 random reads that return 32 MiB of useful bytes.

Turso's `WITHOUT ROWID` implementation is also experimental and disabled
unless `DatabaseOpts::with_without_rowid(true)` is set. Even with that opt-in,
the measured random point path was about 241x slower than the rowid shape.

Rusqlite 0.38.0's documented `Blob::read_at_exact` path accepts the caller's
64 KiB destination and reads that range without creating a Rust 1 MiB row
value. It successfully read the rowid table from the Turso-written file. As
SQLite documents, `blob_open` rejects `WITHOUT ROWID`; the observed error was
`cannot open table without rowid: chunks_without_rowid`.

### Single-file result and format decision

The immutable-copy check passed through both engines after setting the copy
read-only; neither open made a lock or journal sidecar. Turso 0.7.2 did
successfully checkpoint WAL with `TRUNCATE`, but supports only WAL and MVCC
journal modes: its `journal_mode=DELETE` request returned `wal`, and close left
a zero-byte `-wal`. Opening that checkpointed file with bundled rusqlite,
switching to DELETE, and closing removed the sidecar. The artifact directory
then contained only the database.

The ordinary rowid shape is therefore the only v1 schema that preserves the
documented incremental fallback seam, and it is substantially faster in Turso
as well. One MiB remains a reasonable format chunk size: on the rowid shape,
Turso still delivered about 186 MiB/s of useful 64 KiB reads despite the 16x
materialization, while the fallback removes that amplification entirely. A
format-level chunk-size change would give up parity with the range backend for
a limitation that the already-recorded fallback handles.

The two Turso blockers that activate that fallback are:

- no public incremental Blob read API (use rusqlite for bundle offset reads);
- no DELETE journal mode (use rusqlite for final single-file handoff).

The experimental status and severe point-read cost make `WITHOUT ROWID` an
additional reason not to select that schema, rather than a separate fallback
case.
