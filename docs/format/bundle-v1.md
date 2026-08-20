# Gitility bundle format v1 — specification (FROZEN)

Status: FROZEN with the 0.2.0 release (2026-08-20). This document is a
compatibility promise: any Gitility 0.2+ reader opens any v1 bundle, v1
fields are never reinterpreted, and format changes bump the version per the
compatibility rule below. Normative statements here change only to correct
a demonstrable error, never to track implementation drift.

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
the spike crate is preserved in git history (removed from the working
tree after the 0.2.0 release).

## Design rules inherited from the design doc

- Packs stay packs: objects are NEVER stored row-per-object (delta
  compression survives; the file stays proportional to a clone).
- Readers see the old repository or the new one, never a torn state.
- One file, no sidecars, ever: a read-only open MUST work on an
  immutable file (S3 download, chmod 444, ro mount) — no locks, no
  journals, no temp files created by opening.
- No threads, no signal handlers, no engine: reader and writer use plain
  synchronous file I/O only. Implementation note (non-normative): v1
  implements the store Elixir-side on the existing proven seams —
  `Gitility.ODB.RangeBackend` (`:file.pread` over section ranges, hydrated
  by the M2e PackFetch machinery like every range backend) plus
  `Gitility.RefDB.Backend` (TOC parsed once at init) — adding NO new
  native surface. A native fast path is post-1.0 headroom if profiling
  ever demands it; the format is identical either way.

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
versions. Major = 0 → `:malformed_object`. Refusal is possible without
parsing anything further.

Reserved fields (here and in the trailer) are MAJOR-version space: writers
MUST emit zero, and readers MUST reject nonzero with `:malformed_object`.
(Additive minor-version space lives elsewhere: optional metadata keys, new
FILE kinds, and the reserved TOC tail.)

### Sections

The raw, unmodified bytes of each contained file (`.pack` and `.idx`),
concatenated starting at offset 16 in exactly TOC entry order. Entries
MUST tile `[16, toc_offset)` exactly: entry 0 starts at 16, each entry
starts where the previous ended, the last ends at `toc_offset`. No
padding, no gaps, no overlaps — any violation is `:malformed_object`
naming the entry.

### TOC (at `toc_offset`, `toc_len` bytes)

`toc_len` MUST NOT exceed 64 MiB (67,108,864 bytes) — readers reject a
larger value with `:malformed_object` before reading the TOC, and writers
MUST refuse to produce one with `:unsupported_operation` (the limit bounds
reader allocation; at ~56 bytes per ref row it admits on the order of a
million refs).

Parsed strictly within `toc_len`; every length prefix is bounds-checked
against the remaining buffer before use (counts are never trusted). All
UTF-8 fields (metadata keys and values, file names) MUST be valid UTF-8;
violations are `:malformed_object`.

```
hash_algorithm   u8      1 = sha1 (20-byte oids), 2 = sha256 (32-byte oids)
                         any other value: :malformed_object
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
  `idx` (same stem), evaluated over the subsequence of KNOWN-kind entries
  — unknown-kind entries may sit between a pack and its idx without
  breaking the pair. Names MUST be `pack-<hex>.pack` / `pack-<hex>.idx`
  where `<hex>` is lowercase and exactly 40 (sha1) or 64 (sha256) hex
  characters per `hash_algorithm`. Unpaired or mis-ordered entries are
  `:malformed_object`. Zero pairs is legal (empty repository).
- Unknown `kind` values in FILE entries: the reader MUST skip the entry
  in the pack/idx pairing and the object-store view, but the entry still
  occupies its section bytes — it participates fully in the tiling rule
  and in whole-file verification (minor-additive space — writers never
  require a minor feature to read the core repository). Unknown REF kind
  or peeled_flag values: `:malformed_object` (that space is not
  additive).
- Duplicate or unsorted metadata keys / ref names: `:malformed_object`.
- Strictly-ascending ref names permit binary-search resolution and make
  prefix iteration a contiguous scan — same shape the cursor/paging
  machinery already assumes (readers may resolve however they like).
- `ref_count` = 0 is legal: an object-store-only bundle (no refs
  snapshot, so no `:head` or named-ref resolution). Gitility's PackFetch
  hydration destination writes such bundles; a full-repository bundle
  from `Bundle.write/2` always carries its refs snapshot. Zero ref rows
  carries no further format-level meaning.
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

RESERVED key (a feature gate, not ignorable):

- `shallow_roots` — reserved for future shallow-repository support.
  v1 writers MUST refuse shallow sources (`$GIT_DIR/shallow` present)
  with `:unsupported_operation` — a bundle without the boundary would
  silently answer history queries wrongly (walk past the boundary on
  partial-shallow sources) or abort with `:missing_object` (true
  depth-N clones). v1 readers MUST refuse any bundle carrying this key
  with `:unsupported_operation` naming it. Because old readers refuse
  loudly instead of misreading, a future writer+reader pair can
  introduce shallow bundles as a MINOR bump.

### Trailer (final 64 bytes; ends exactly at EOF)

| bytes | field      | value                                  |
|-------|------------|----------------------------------------|
| 0–7   | toc_offset | u64                                    |
| 8–15  | toc_len    | u64                                    |
| 16–47 | toc_sha256 | sha256 of the TOC bytes                |
| 48–55 | reserved   | zero                                   |
| 56–63 | magic      | `"GITBNDL\0"` (the last 8 bytes)      |

The trailer MUST end exactly at EOF: a reader reads the final 64 bytes of
the file as the trailer and validates the magic and the bounds equation
below — appending anything after a valid trailer shifts that window, so
the magic or bounds check fails and the file is rejected (`:malformed_object`).
This is what makes "the trailer is at EOF" a safe place to look. Minimum
legal file size is 80 bytes (header + trailer). Bounds: `16 <= toc_offset`,
`toc_offset + toc_len + 64 == file size`. The reserved field follows the
header's reserved rule: writers emit zero, readers reject nonzero.

## Writer contract (`Gitility.Bundle.write/2` and `into: {:bundle, path}`)

- A publish (and every update, and repack) builds a COMPLETE new file:
  write to a temp file in the destination directory, fsync the file, and
  atomically rename over the destination — the artifact is always
  complete-or-absent. The writer SHOULD also fsync the directory where
  the platform allows; the reference Elixir writer cannot (Erlang exposes
  no portable directory-fsync), so rename durability across sudden power
  loss is platform-dependent there. Readers holding the old file keep a
  coherent old repository (their fd pins the old inode); new opens see
  the new one. On S3 the equivalent is the whole-object PUT, atomic by
  construction. In-place append is NOT in v1 (see headroom note below).
- Single streaming pass: header, then each pack/idx streamed through
  sha256 while being copied, then the TOC, then the trailer. The writer
  never seeks backward.
- Byte determinism (stronger than the SQLite draft's "logical"
  determinism): identical input (packs, refs, metadata) yields an
  IDENTICAL file. Ordering is normative: file pairs sorted ascending by
  pack name (idx after its pack), metadata sorted by key, refs sorted by
  name bytes; `created_at` omitted by default. Tests MAY compare file
  hashes. Implementation note: loose-object packing must pin
  `git pack-objects --threads=1` — multi-threaded delta search is not
  byte-stable, and the loose pack's content-derived NAME feeds the TOC.
- `generation` increases by at least 1 over the file being replaced
  (fresh bundles start at 1). A bundle open is pinned to ONE generation
  for its lifetime: the stores' `refresh()` callbacks are no-ops, and a
  replaced file makes in-flight reads fail loudly (the pinned-identity
  check) rather than serve mixed generations. Moving to the new
  generation = open the bundle again; an open holding the old inode
  keeps a coherent old repository meanwhile. Snapshots already taken
  keep their pinned commits, per the global invariant.
- Fetch packs arrive thin; pipelines complete them (`index-pack
  --fix-thin`) before they reach the bundle — unchanged from the design
  doc.

## Reader contract (the native bundle store)

- Open: sniff header magic + major → read trailer (magic, bounds) →
  read TOC and verify `toc_sha256` (mismatch: `:malformed_object`) →
  parse strictly per the rules above → pin `generation`.
- The store serves PackFetch from the section byte ranges via plain
  `pread`. Hydration integrity is the M2e machinery's unconditional
  pack/idx checksum verification (git's own trailing hashes), exactly as
  for every range backend. The container's per-file sha256s are computed
  by the writer and verified by `Gitility.Bundle.verify/1`, which streams
  the whole file (structure + every checksum). The TOC sha256 is always
  verified at open.
- The refs table implements `RefDB.Backend` from the pinned snapshot
  (the sorted rows permit binary-search resolution and contiguous prefix
  scans; how a reader indexes them is its own business). Per-hop
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

## Open questions — all RESOLVED (James delegated 2 and 3, 2026-08-18)

1. RESOLVED twice over: first by the M4b spike (rowid table + rusqlite
   fallback), then mooted 2026-08-18 by dropping SQLite for this flat
   container (James's call). Chunking no longer exists; offset reads are
   native `pread`.
2. RESOLVED: yes — kind=tag rows point at the tag OBJECT and `peeled`
   carries the fully-peeled commit (packed-refs `^{}` shape), so RefDB
   peeling needs no ODB read. Cost is one oid per annotated tag.
3. RESOLVED: `source_identity` stays a free-form string; structured
   identity (url, tip commit, ...) can arrive later as new optional
   metadata keys under the MINOR rule without reinterpreting this field.
