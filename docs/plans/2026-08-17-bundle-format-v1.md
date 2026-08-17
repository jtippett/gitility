# Gitility bundle format v1 — specification (DRAFT for James's review; freezes at 0.2)

Status: DRAFT. The design doc mandates this spec exist before the first
byte of `Gitility.Bundle` is written (M4 item 5). Format version 1 is
frozen when 0.2 ships; until then this document may change.

A bundle is one SQLite-format file (engine: turso_core; fallback seam:
rusqlite+bundled) holding a complete read-only Git repository: packs,
their indexes, a refs snapshot, and metadata. One file opens as ODB +
RefDB with no other infrastructure ("clone a repo to a single S3 file").

## Design rules inherited from the design doc

- Packs stay packs: objects are NEVER stored row-per-object (delta
  compression survives; the file stays proportional to a clone).
- Chunked blobs, 1 MiB rows — deliberately the same shape as the
  Postgres range backend, so the two backends share read plumbing.
- Updates are append + rewrite-refs + bump-generation in ONE
  transaction; existing pack blobs are never touched. Readers see the
  old repository or the new one, never a torn state.
- Repack is the only whole-file rewrite, followed by VACUUM.

## File identification

- SQLite `application_id` pragma = 0x47544259 ("GTBY").
- SQLite `user_version` pragma = the format MAJOR version (1).
A reader sniffs both before touching tables; wrong application_id →
:invalid_argument ("not a gitility bundle"); user_version greater than
the newest major the reader knows → :unsupported_operation naming both
versions. This makes refusal possible without schema assumptions.

## Tables (exact DDL, v1)

```sql
CREATE TABLE gitility_metadata (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
) WITHOUT ROWID;
-- Required keys:
--   format_version   'MAJOR.MINOR', e.g. '1.0'. MAJOR duplicates
--                    user_version (cross-check on open; mismatch is
--                    :malformed_object).
--   hash_algorithm   'sha1' | 'sha256'
--   current_generation  decimal integer >= 1
--   source_identity  free-form publisher string (e.g. origin URL @ tip)
-- Optional keys (v1 readers ignore unknown keys — minor-version space):
--   created_at       RFC3339, publisher-supplied (omitted by default:
--                    bundle logical content stays deterministic)
--   publisher        free-form tool identity

CREATE TABLE gitility_files (
  id        INTEGER PRIMARY KEY,
  name      TEXT NOT NULL,              -- e.g. 'pack-<hash>.pack'
  kind      TEXT NOT NULL CHECK (kind IN ('pack','idx')),
  byte_size INTEGER NOT NULL CHECK (byte_size >= 0),
  checksum  TEXT NOT NULL,              -- lowercase hex sha256 of the
                                        -- complete file bytes
  UNIQUE (name)
);

CREATE TABLE gitility_chunks (
  file_id INTEGER NOT NULL REFERENCES gitility_files(id),
  seq     INTEGER NOT NULL,             -- 0-based
  bytes   BLOB NOT NULL,
  PRIMARY KEY (file_id, seq)
) WITHOUT ROWID;
-- Chunk size: exactly 1 MiB (1_048_576 bytes) for every chunk except
-- the last of a file, which is 1..1_048_576 bytes. Readers MUST verify
-- chunk-count and byte-size consistency (byte_size vs sum of lengths)
-- before serving; mismatch is :malformed_object naming the file.

CREATE TABLE gitility_manifest (
  generation INTEGER NOT NULL,
  position   INTEGER NOT NULL,          -- 0-based order within the
                                        -- generation (index-open order)
  file_id    INTEGER NOT NULL REFERENCES gitility_files(id),
  PRIMARY KEY (generation, position)
) WITHOUT ROWID;
-- A generation lists BOTH the .pack and its .idx (adjacent positions,
-- idx immediately after its pack). A reader pins
-- current_generation at open and resolves exactly that set — the same
-- generation/grace contract as the range-backend manifest.

CREATE TABLE gitility_refs (
  generation INTEGER NOT NULL,
  name       BLOB NOT NULL,             -- full ref name, raw bytes
  target_hex TEXT NOT NULL,             -- direct target object id
  kind       TEXT NOT NULL CHECK (kind IN ('commit','tag','tree','blob')),
  peeled_hex TEXT,                      -- fully-peeled commit for
                                        -- annotated tags, else NULL
  PRIMARY KEY (generation, name)
) WITHOUT ROWID;
-- Symbolic refs are resolved at publish time; HEAD is stored as the
-- special row name = 'HEAD' with its RESOLVED target (plus optional
-- metadata key head_symref = 'refs/heads/main' preserving the symbolic
-- name for display). Refs are snapshotted per generation; a reader
-- serves the pinned generation's rows. Repack prunes generations
-- older than current.
```

## Writer contract (`Gitility.Bundle.write/2` and `into: {:bundle, path}`)

- One transaction per logical publish/update: insert new files+chunks,
  insert the new generation's manifest+refs rows, then update
  current_generation last. Existing rows are never mutated.
- Chunks of one file are inserted in ascending seq; files fsync via
  SQLite's own durability (writer uses journal_mode=WAL during build,
  then `PRAGMA wal_checkpoint(TRUNCATE)` + journal_mode=DELETE before
  handing the file off, so the artifact is a SINGLE file with no -wal
  sidecar — an S3 upload is one object).
- page_size fixed at 4096 (recorded; changing it is a major bump).
- Logical determinism: identical input (packs, refs, metadata) yields
  identical LOGICAL content (row sets); byte-identical FILES are not
  promised (SQLite page allocation is not canonical) — tests compare
  dumps, not file hashes.
- Repack = build a fresh bundle from a repacked source next to the old
  file, then atomic rename; VACUUM applies when updating in place.

## Reader contract (the native bundle store)

- Open: sniff application_id/user_version → read gitility_metadata →
  cross-check format_version → pin current_generation → load the
  manifest set → serve PackFetch/RangeBackend-style chunk reads via
  incremental blob I/O. Pack and idx checksums verified on hydration
  exactly as the M2e backends do (unconditional).
- The refs table implements RefDB.Backend: resolve/list from the
  pinned generation's rows; refresh() re-reads current_generation and
  re-pins (an explicit, caller-visible generation move — snapshots
  already taken keep their pinned commits, per the global invariant).
- Read-only open MUST work on an immutable file (S3 download, ro
  mount): no WAL, no lock files (SQLite immutable=1 semantics).
- Unknown tables, columns, or metadata keys: ignored (minor-version
  additive space). Missing REQUIRED tables/keys: :malformed_object.

## Compatibility rule (frozen)

- MAJOR bump = any change a v-N reader could misread (table meaning,
  chunk size, checksum algorithm, generation semantics). Readers
  refuse newer majors with :unsupported_operation naming both sides.
- MINOR bump = purely additive (new optional tables/columns/keys).
  Readers ignore what they don't know; writers never require a minor
  feature for correct reading of the core repository.
- v1 fields are never reinterpreted (same append-only discipline as
  cursor wire v1).

## Open questions for James before freeze

1. `WITHOUT ROWID` on gitility_chunks keeps (file_id, seq) clustered —
   good locality for sequential hydration — but stores blob payloads
   in the primary B-tree. rusqlite/turso incremental blob I/O works on
   rowid tables' blob columns; if turso's incremental-read API needs a
   rowid table, chunks drops WITHOUT ROWID (the conformance spike in
   M4b settles this empirically before freeze — flagged, not assumed).
2. Should refs carry per-ref annotated-tag TARGETS (kind='tag' rows
   point at the tag object; peeled_hex gives the commit)? Current
   answer: yes, both, so RefDB peeling needs no ODB read.
3. source_identity semantics: free-form vs structured (url + tip
   commit)? Current: free-form string; structure can arrive as new
   optional keys (minor).
```
