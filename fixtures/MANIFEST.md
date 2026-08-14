# Fixture corpus

`generate.sh` deterministically rebuilds `generated/` with Git identity,
timestamps, locale, configuration sources, object format, initial branch, and
umask fixed explicitly. It records stable refs in `generated/OIDS` and a byte/mode
inventory in `generated/CHECKSUMS`; on later runs both are compared with the
previous generation. The generated repositories are intentionally ignored.

The corpus contains:

- `sha1-basic.git` and `sha256-basic.git`: bare repositories with the same
  logical shape. They include ordinary and nested files, an executable,
  symlink, empty and repeated blobs, an invalid-UTF-8 path, a quote/control-byte
  path that Git always quotes, binary data, a 12,050-byte line, a 256 KiB blob,
  a reachable empty tree, a gitlink, and annotated and lightweight tags.
- `sha1-history.git`: a criss-cross merge, exact and similarity renames,
  blame/follow history, delete/re-add history, an exact copy, and a
  four-candidate rename input. Stable `fixture/*` tags name useful queries.
- `sha1-basic-packed.git`, `sha1-basic-mixed.git`, and
  `sha1-history-midx.git`: fully packed, mixed loose/packed, and two-pack
  multi-pack-index layouts.
- `sha1-alternate.git`, `sha1-missing.git`, `sha1-history-shallow.git`, and
  `sha1-history-replace.git`: relative alternate storage, an intentionally
  absent blob, a shallow/graft-like boundary, and a replace-ref edge case.
- `lfs-pointer.git`: a well-formed LFS pointer stored as an ordinary blob; no
  LFS client or filter is involved.

## Corrupt repositories

Every repository under `generated/corrupt/` starts from a clean basic fixture
and receives exactly one mutation:

- `loose-bad-hash.git`: the first payload byte of the README loose object is
  flipped after inflation, then the object is recompressed under its original
  path. The stream and header remain valid, but its content hash is wrong.
- `loose-malformed-header.git`: the README loose object's type header is
  changed from `blob` to an invalid type without changing its payload.
- `pack-truncated.git`: exactly 17 bytes are removed from the end of its sole
  pack, truncating the pack checksum.
- `pack-bad-checksum.git`: one byte immediately before the pack checksum is
  flipped. The index remains untouched, so pack verification reports the
  damaged pack entry/checksum (the source pack includes delta-compressible
  story revisions).
- `idx-bad-checksum.git`: the final byte of the index checksum is flipped;
  the pack remains untouched.
- `pack-body-corrupt-valid-checksums.git`: a compressed byte in the README
  blob's pack entry is flipped. Its entry CRC, pack trailer, embedded pack
  checksum, and index trailer are recomputed, leaving only the addressed entry
  data inconsistent so per-object decoding and verification are exercised.

Git 2.42 or newer is required because SHA-256 repository generation is part
of every run. `test/test_helper.exs` runs the generator automatically when the
`generated/OIDS` completion marker is absent.
