# Gitility bundle format v1 — specification (DRAFT; freezes when 0.2 ships)

Status: DRAFT, revised 2026-08-18. The design doc mandates this spec exist
before the first byte of `Gitility.Bundle` is written (M4 item 5). Format
version 1 is frozen when 0.2 ships; until then this document may change.

A bundle is ONE flat container file holding a complete read-only Git
repository: packs, their indexes, a refs snapshot, and metadata. One file
opens as ODB + RefDB with no other infrastructure ("clone a repo to a
single S3 file").

## Why not SQLite (decision record, 2026-08-18)

The original draft specified a SQLite-format file (engine: turso_core,
fallback: rusqlite+bundled). The M4b conformance spike
(`crates/bundle-spike`, commit 7d0ad18) found turso_core 0.7.2 cannot
serve the read path (no public incremental Blob API — a 64 KiB request
materializes the full 1 MiB row; experimental WITHOUT ROWID point reads
41.4s vs 0.172s rowid) and cannot leave WAL mode, so it cannot produce the
single-file artifact alone. Activating the recorded rusqlite fallback
would have pulled the C amalgamation into an otherwise pure-Rust build to
keep features the bundle never uses: SQL, secondary indexes, concurrent
writers, in-place transactions. James's call (2026-08-18): drop SQLite
entirely. The bundle content is raw packs/idx bytes — themselves stable,
well-specified Git formats — plus a small refs/metadata snapshot; a flat
container with a table of contents serves every requirement with
`std::fs` alone: pure Rust, zero engine dependency, no background
threads, byte-deterministic output, offset reads via plain `pread`, and a
format whose longevity is governed by this spec rather than an engine's.
The 1 MiB chunk machinery (an artifact of SQL row storage) disappears;
the spike crate remains in-tree as evidence.

## Design rules inherited from the design doc

- Packs stay packs: objects are NEVER stored row-per-object (delta
  compression survives; the file stays proportional to a clone).
- Readers see the old repository or the new one, never a torn state.
- One file, no sidecars, ever: a read-only open MUST work on an
  immutable file (S3 download, chmod 444, ro mount) — no locks, no
  journals, no temp files created by opening.
- No threads, no signal handlers: reader and writer use plain
  synchronous `std::fs` I/O only (spawn guard applies as everywhere).

## File layout

```
+--------------------+  offset 0
| header  (16 bytes) |
+--------------------+  offset 16
| section 0 bytes    |  raw pack/idx file bytes, concatenated
| section 1 bytes    |  in TOC entry order, no padding, no gaps
| ...                |
+--------------------+  offset toc_offset
| TOC                |  toc_len bytes
+--------------------+
| trailer (64 bytes) |  ends exactly at EOF
+--------------------+
```

All integers little-endian, fixed width. All variable-length byte fields
are length-prefixed (`u32` length, then the bytes; no NUL terminators).

### Header (16 bytes, offset 0)

| bytes | field        | value                                    |
|-------|--------------|------------------------------------------|
| 0–7   | magic        | `"GITBNDL\0"` (47 49 54 42 4E 44 4C 00) |
| 8–9   | format major | u16, = 1                                 |
| 10–11 | format minor | u16, = 0                                 |
| 12–15 | reserved     | zero                                     |

A reader sniffs the magic before anything else; wrong magic →
`:invalid_argument` ("not a gitility bundle"). Major greater than the
newest major the reader knows → `:unsupported_operation` naming both
versions. Refusal is possible without parsing anything further.

### Sections

The raw, unmodified bytes of each contained file (`.pack` and `.idx`),
concatenated starting at offset 16 in exactly TOC entry order. Entries
MUST tile `[16, toc_offset)` exactly: entry 0 starts at 16, each entry
starts where the previous ended, the last ends at `toc_offset`. No
padding, no gaps, no overlaps — any violation is `:malformed_object`
naming the entry.

### TOC (at `toc_offset`, `toc_len` bytes)

Parsed strictly within `toc_len`; every length prefix is bounds-checked
against the remaining buffer before use (counts are never trusted).

```
hash_algorithm   u8      1 = sha1 (20-byte oids), 2 = sha256 (32-byte oids)
generation       u64     >= 1
metadata_count   u32
metadata entries × count, sorted strictly ascending by key bytes:
    key          u32 + bytes   UTF-8, 1..=4096 bytes
    value        u32 + bytes   UTF-8, 0..=65536 bytes
file_count       u32
file entries × count, in section order:
    kind         u8            1 = pack, 2 = idx
    name         u32 + bytes   UTF-8, 1..=4096 bytes, unique across entries
    offset       u64           absolute file offset of first byte
    length       u64           >= 1
    sha256       32 bytes      of the complete section bytes
ref_count        u32
ref entries × count, sorted strictly ascending by name bytes:
    name         u32 + bytes   raw ref-name bytes, 1..=4096
    target       oid           binary, 20 or 32 bytes per hash_algorithm
    kind         u8            1 = commit, 2 = tag, 3 = tree, 4 = blob
    peeled_flag  u8            0 = absent, 1 = present
    peeled       oid           only if peeled_flag = 1
(remaining bytes within toc_len: reserved minor-version space —
 v1 readers MUST ignore them)
```

Rules:

- File entries come in pairs: each `pack` immediately followed by its
  `idx` (same stem). Names follow git convention
  (`pack-<hash>.pack` / `.idx`). Unpaired or mis-ordered entries are
  `:malformed_object`. Zero pairs is legal (empty repository).
- Unknown `kind` values in FILE entries: the reader MUST skip the entry
  (minor-additive space — writers never require a minor feature to read
  the core repository). Unknown REF kind or peeled_flag values:
  `:malformed_object` (that space is not additive).
- Duplicate or unsorted metadata keys / ref names: `:malformed_object`.
- Strictly-ascending ref names give binary-search resolution and make
  prefix iteration a contiguous scan — same shape the cursor/paging
  machinery already assumes.
- `HEAD` is stored as a ref row named `HEAD` with its RESOLVED direct
  target (symbolic refs are resolved at publish time). The optional
  metadata key `head_symref` (e.g. `refs/heads/main`) preserves the
  symbolic name for display.
- Annotated tags: `kind = 2` rows point at the tag OBJECT; `peeled`
  carries the fully-peeled commit, so RefDB peeling needs no ODB read
  (open question 2, current answer). `peeled_flag = 0` for refs whose
  peel target is unavailable at publish (dangling) — readers degrade
  exactly as the local ref store does.

Required metadata keys:

- `source_identity` — free-form publisher string (e.g. origin URL @ tip;
  open question 3, current answer free-form).

Optional keys (v1 readers ignore unknown keys — minor-version space):

- `created_at` — RFC3339, publisher-supplied. Omitted by default so
  bundle output stays byte-deterministic.
- `publisher` — free-form tool identity.
- `head_symref` — see above.

### Trailer (final 64 bytes; ends exactly at EOF)

| bytes | field      | value                                  |
|-------|------------|----------------------------------------|
| 0–7   | toc_offset | u64                                    |
| 8–15  | toc_len    | u64                                    |
| 16–47 | toc_sha256 | sha256 of the TOC bytes                |
| 48–55 | reserved   | zero                                   |
| 56–63 | magic      | `"GITBNDL\0"` (the last 8 bytes)      |

The trailer MUST end exactly at EOF; trailing bytes after it are
`:malformed_object` (this is what makes "the trailer is at EOF" a safe
place to look). Minimum legal file size is 80 bytes (header + trailer).
Bounds: `16 <= toc_offset`, `toc_offset + toc_len + 64 == file size`.

## Writer contract (`Gitility.Bundle.write/2` and `into: {:bundle, path}`)

- A publish (and every update, and repack) builds a COMPLETE new file:
  write to a temp file in the destination directory, fsync the file,
  atomically rename over the destination, fsync the directory. Readers
  holding the old file keep a coherent old repository (their fd pins the
  old inode); new opens see the new one. On S3 the equivalent is the
  whole-object PUT, atomic by construction. In-place append is NOT in
  v1 (see headroom note below).
- Single streaming pass: header, then each pack/idx streamed through
  sha256 while being copied, then the TOC, then the trailer. The writer
  never seeks backward.
- Byte determinism (stronger than the SQLite draft's "logical"
  determinism): identical input (packs, refs, metadata) yields an
  IDENTICAL file. Ordering is normative: file pairs sorted ascending by
  pack name (idx after its pack), metadata sorted by key, refs sorted by
  name bytes; `created_at` omitted by default. Tests MAY compare file
  hashes.
- `generation` increases by at least 1 over the file being replaced
  (fresh bundles start at 1). A reader's `refresh()` reopens the path
  and re-pins; a generation move is an explicit, caller-visible event —
  snapshots already taken keep their pinned commits, per the global
  invariant.
- Fetch packs arrive thin; pipelines complete them (`index-pack
  --fix-thin`) before they reach the bundle — unchanged from the design
  doc.

## Reader contract (the native bundle store)

- Open: sniff header magic + major → read trailer (magic, bounds) →
  read TOC and verify `toc_sha256` (mismatch: `:malformed_object`) →
  parse strictly per the rules above → pin `generation`.
- The store serves PackFetch from the section byte ranges via plain
  `pread`; pack and idx sha256s are verified STREAMING during hydration,
  unconditionally, exactly as the M2e backends do (the pack machinery
  additionally verifies git's own trailing pack/idx hashes, as
  everywhere).
- The refs table implements `RefDB.Backend`: resolve by binary search,
  list/prefix by contiguous scan, from the pinned snapshot. Per-hop
  atomicity is trivial — all rows are direct targets by construction.
- Read-only open of an immutable 0444 file works by construction: the
  reader opens `O_RDONLY`, creates nothing, locks nothing.
- Unknown metadata keys, unknown FILE kinds, and reserved TOC tail
  bytes: ignored (minor-additive space). Missing required keys, any
  structural rule violation: `:malformed_object` naming what failed.

## Compatibility rule (frozen)

- MAJOR bump = any change a v-N reader could misread (field meaning,
  layout, checksum algorithm, generation semantics, trailer discipline).
  Readers refuse newer majors with `:unsupported_operation` naming both
  sides.
- MINOR bump = purely additive: new optional metadata keys, new FILE
  kinds (readers skip unknown kinds), new record types in the reserved
  TOC tail. Writers never require a minor feature for correct reading of
  the core repository.
- v1 fields are never reinterpreted (same append-only discipline as
  cursor wire v1).

Headroom note (non-normative): a future revision could support in-place
incremental update by appending new sections + a new TOC + a new trailer
at EOF. That revision owns the crash-recovery discipline it implies
(scan-back to the last valid trailer) and is therefore a MAJOR bump; v1
readers require the trailer exactly at EOF and reject trailing bytes.

## Open questions for James before freeze

1. RESOLVED twice over: first by the M4b spike (rowid table + rusqlite
   fallback), then mooted 2026-08-18 by dropping SQLite for this flat
   container (James's call). Chunking no longer exists; offset reads are
   native `pread`.
2. Should refs carry per-ref annotated-tag TARGETS (kind=tag rows point
   at the tag object; `peeled` gives the commit)? Current answer: yes,
   both, so RefDB peeling needs no ODB read.
3. `source_identity` semantics: free-form vs structured (url + tip
   commit)? Current: free-form string; structure can arrive as new
   optional metadata keys (minor).
