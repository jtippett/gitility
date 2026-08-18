# M4b — `Gitility.Bundle`: flat-container single-file repositories

Implements the bundle format v1 spec. NORMATIVE FORMAT REFERENCE:
`docs/plans/2026-08-17-bundle-format-v1.md` — read it first and follow it
byte-for-byte; where this document and the format spec conflict, the
format spec wins on format, this document wins on API shape.

## Read these before writing code

- `docs/plans/2026-08-17-bundle-format-v1.md` (normative format)
- `lib/gitility/odb/range_backend.ex` + `range_backend/local_directory.ex`
  (the reference local backend AND the publisher whose inventory/loose-
  packing logic you will reuse) + `range_backend/conformance.ex`
- `lib/gitility/odb/pack_fetch.ex` (hydration consumer; `into:` handling)
- `lib/gitility/ref_db.ex`, `ref_db/backend.ex`, `ref_db/provider.ex`,
  `ref_db/backend/conformance.ex` (list/cursor/Page contract)
- `lib/gitility/repository.ex` (composition; M4a shapes)
- `lib/gitility/types/{pack_manifest,pack_descriptor,byte_range,ref,
  ref_target,ref_query}.ex`, `lib/gitility/page.ex`, `lib/gitility/error.ex`
- `test/differential/refs_parity_test.exs` + `test/differential/oracle.ex`
  (oracle patterns for refs parity)

## Hard constraints (standing project rules — non-negotiable)

- **NO BEAM on this machine.** Never run `mix test`, `mix compile`,
  `iex`, or `mix run`. `mix format` is allowed. All BEAM verification
  happens later on the remote sprite, not by you.
- **NO Rust changes.** This milestone is Elixir-only by design (the
  format spec's implementation note). If you become convinced native
  code is required, STOP and write why in your final output instead of
  writing Rust. Do not touch `crates/`, `native/`, or the spawn-guard
  allowlist.
- Never pattern-kill processes. Do not commit. Do not modify
  gitignored `sources/`.

## Deliverables

New modules under `lib/gitility/bundle*`:

### 1. `Gitility.Bundle.Format` (pure parsing/encoding, shared)

Pure functions over binaries + positional reads; no processes.

- `parse/1`-style open: given a path, read the 16-byte header, the
  64-byte trailer, and the TOC; validate STRICTLY per the format spec
  (magic, major refusal naming both versions, bounds, TOC sha256, exact
  section tiling of `[16, toc_offset)`, sorted-unique metadata keys and
  ref names, pack/idx adjacency + pairing, name/value ceilings, oid
  lengths per hash_algorithm, kind values, trailer exactly at EOF).
  Sanity ceiling: `toc_len <= 64 MiB` → `:malformed_object` above.
  Every length prefix is bounds-checked against the remaining buffer —
  counts are never trusted. Unknown FILE kinds are skipped; bytes
  remaining in the TOC after the ref section are ignored (minor space).
  Errors are `%Gitility.Error{}` with the spec's codes:
  `:invalid_argument` (not a bundle), `:unsupported_operation` (future
  major, naming both versions), `:malformed_object` (everything
  structural, naming what failed).
- Encoding helpers for the writer (header, TOC, trailer), producing the
  spec's exact byte layout with normative ordering.

### 2. `Gitility.Bundle.RangeBackend` (`@behaviour Gitility.ODB.RangeBackend`)

- `init/1` takes the bundle path: parse + pin the TOC (including its
  sha256 as the PINNED IDENTITY). State is the path + parsed table +
  pinned toc_sha256. Do NOT hold a raw fd in state — raw files are
  usable only by the opening process, and callbacks run in supervised
  tasks (this is a known Erlang trap; follow LocalDirectory's
  open-per-callback pattern).
- `manifest/1`: `%Gitility.PackManifest{version: 1, generation:
  Integer.to_string(toc.generation), hash: ..., loose: [], packs:
  [%Gitility.PackDescriptor{id: pack stem, pack_key: pack name,
  index_key: idx name, pack_size:, index_size:, etag: sha256 hex}]}`.
- `read_ranges/2`: for each `%Gitility.ByteRange{}`, open the file
  `[:read, :raw, :binary]`, FIRST re-read the 64-byte trailer and
  compare toc_sha256 with the pinned identity — a mismatch means the
  file was atomically replaced under us; return a backend error naming
  the generation move (a torn mix of generations must be IMPOSSIBLE —
  same philosophy as M4a's single-shot pinned resolution). Then
  `:file.pread` at `section_offset + range.offset` after bounds-checking
  `range.offset + range.length <= entry.length` (out of bounds or short
  read = backend error, never padding). Batch ranges per open; close
  the fd before returning.
- No `terminate` state to clean.

### 3. `Gitility.Bundle.RefBackend` (`@behaviour Gitility.RefDB.Backend`)

- `init/1`: parse the bundle (same Format module), build a name→row map
  plus the sorted row list. All rows are DIRECT targets by construction
  (per-hop atomicity trivial).
- `resolve/2`: map lookup → `%Gitility.RefTarget{kind: :direct, oid:,
  peeled:}` (peeled from the row when flag=1); `HEAD` row resolves like
  any other; missing name → `:not_found`.
- `list/2`: honor `%Gitility.RefQuery{prefix, limit, cursor}` as a
  contiguous scan over the sorted list; Page + cursor semantics exactly
  per `Gitility.RefDB.Backend.Conformance` — read the kit and satisfy
  it. Listing returns raw rows (all direct; peeled populated).
- `refresh/1`: re-parse the file at path and re-pin (an explicit,
  caller-visible generation move; snapshots keep their pinned commits).

### 4. `Gitility.Bundle.write/2`

`write(path, opts)` → `{:ok, %Gitility.Bundle.Receipt{}} | {:error, %Error{}}`.

Options: `source: {:repository, dir}` (required; bare or normal —
resolve the actual git dir the way `Repository.open/2` does),
`source_identity: binary` (default: `"repository:" <> Path.expand(dir)`),
`publisher:`/`created_at:` optional metadata (created_at ONLY when the
caller passes it — determinism default), plus whatever git-executable
option the LocalDirectory publisher already takes for loose packing
(same default).

Behavior:

- **Inventory**: reuse the LocalDirectory publisher's enumeration —
  every stored object, packed + loose, reachable or not; loose objects
  are packed into an additional pair via the same pinned-git helper.
  REFACTOR, don't duplicate: extract the shared inventory/loose-packing
  logic into a common module both call. LocalDirectory's observable
  behavior and its existing tests must not change.
- **Refs snapshot**: dogfood M4a — `Repository.open(dir)`, list ALL
  refs (full pagination), resolve symbolic targets to direct via
  `RefDB.resolve`, determine `kind` via `ODB.header`, take `peeled`
  from the ref store or peel annotated tags via the ODB when absent;
  peel unavailable → flag 0. Resolve `:head`; symbolic HEAD adds the
  `head_symref` metadata key, detached stores the direct row only.
  SKIP-with-warning (carried into the receipt): refs whose direct
  target object is missing from the source ODB (a bundle must be
  self-complete), plus the ref-store's own malformed/skip warnings.
  Unresolvable HEAD → omit the row, warn.
- **Ordering** per the format spec's normative determinism rules.
- **Generation**: if `path` holds a VALID bundle → its generation + 1;
  no file → 1; an existing file that is NOT a valid bundle →
  `{:error, ...}` refusing to clobber (caller must remove it — never
  silently overwrite something we didn't write).
- **Write discipline**: temp file in the destination directory
  (random suffix), single streaming pass (8 MiB copy chunks through a
  running `:crypto` sha256 per file and for the TOC), `:file.sync`,
  `File.rename` over the destination. Erlang cannot fsync a directory —
  note that documented limitation in the moduledoc (artifact is always
  complete-or-absent; rename durability is the platform's).

`%Gitility.Bundle.Receipt{path:, generation:, bytes:, files:, refs:,
warnings: []}`.

### 5. `Gitility.Bundle.verify/1` and `Gitility.Bundle.info/1`

- `verify(path)`: streaming full check — structure (as open) PLUS every
  per-file sha256 over the section bytes. `:ok | {:error, %Error{}}`
  naming the first failure.
- `info(path)`: cheap, no hydration: `{:ok, map}` with format version,
  hash algorithm, generation, source_identity, metadata, file and ref
  counts, total bytes.

### 6. `Gitility.Bundle.start_link/1`, `repository/1`, `open/2`

- `start_link(opts)`: `path:` (required), `into:` (PackFetch
  passthrough; same defaults/platform rules), `name:`, `runtime:`,
  `limits:`, `concurrency:`, `max_hydration_bytes:` etc. passed
  through. Starts ONE supervisor owning a PackFetch (backend:
  `{Gitility.Bundle.RangeBackend, path}`) and a RefDB (backend:
  `{Gitility.Bundle.RefBackend, path}`).
- `repository(supervisor)`: `{:ok, %Gitility.Repository{odb:, refs:}}`
  (the two-shape pattern, like `ODB.start_link` + `ODB.handle/1`).
- `open(path, opts)`: sugar = start_link + repository, returns
  `{:ok, %Repository{}}` with the supervisor linked to the caller.

### 7. Explicitly OUT of M4b

`into: {:bundle, path}` as a PackFetch hydration destination stays
`:unsupported_operation` (it becomes M4c). Update its message to point
at `Gitility.Bundle.write/2` for building bundles today.

## Tests (author them all; you cannot run BEAM — make them right by reading)

Follow existing test idioms (`test/…`, differential suite patterns,
`@moduletag :gitility_engine` where the engine is exercised). Remember
the recurring traps: no Range/struct literals inside quoted generators;
guard-safe functions only in guards; ref selectors need real fixtures;
explicit range steps.

1. **Format round-trip + determinism**: write from a fixture repo twice
   → byte-identical files (hash compare — the format promises BYTE
   determinism). `info/1` and `verify/1` pass. Empty-repo bundle
   (0 packs, 0 refs) is legal and opens.
2. **Hostile-bundle matrix** (build corrupt files by surgically editing
   valid ones): wrong header/trailer magic; future major (assert
   `:unsupported_operation` naming both versions); truncation at each
   region boundary; file below 80 bytes; bad TOC sha256; tiling gap,
   overlap, and out-of-order sections; unsorted and duplicate refs and
   metadata keys; missing idx partner / mis-ordered pair; unknown REF
   kind → `:malformed_object`; unknown FILE kind entry is SKIPPED
   (still opens, file ignored); junk appended inside toc_len after the
   ref section is IGNORED (minor space); bytes after the trailer →
   `:malformed_object`; name > 4096; toc_len over the 64 MiB ceiling;
   length-prefix overruns. Parser must never crash and never read
   beyond declared bounds.
3. **Differential parity** (`test/differential/`): for fixture families
   sha1 packed/mixed/nested + alternates + shallow + sha256: write
   bundle → `Bundle.open(path, into: {:dir, tmp})` → (a) ref listing
   parity vs pinned-git `for-each-ref` on the SOURCE repo via the
   existing oracle (modulo the documented skips — assert the warnings);
   (b) snapshot parity for `{:branch, ...}`, `{:tag, ...}` (annotated →
   peeled commit), `:head`; (c) query parity vs the directly-opened
   source repo for a representative sample: log page, tree walk,
   read_file, diff between two commits, blame of one file.
4. **Conformance kits**: run
   `Gitility.ODB.RangeBackend.Conformance` and
   `Gitility.RefDB.Backend.Conformance` against the two bundle backends.
5. **Generation-move probe** (mutation-probe style, like M4a): open a
   bundle, atomically rename a DIFFERENT valid bundle over the path,
   then read ranges → loud backend error, never bytes from the new
   file at old offsets. `RefDB.refresh` then re-pins and serves the new
   generation.
6. **verify/1 catches corruption**: flip one byte inside a section of a
   valid bundle → `verify/1` fails naming the file; plain open still
   succeeds (TOC intact) — asserting the documented division of labor.
7. **Immutable open**: `chmod 0444` copy opens, hydrates, and serves a
   query; no sidecar files appear next to it at any point.
8. **write/2 edge policy**: destination holds a non-bundle file →
   refused; destination holds a valid bundle → replaced with
   generation+1 (assert via `info/1` before/after and a changed ref).

## Definition of done (your side)

- `mix format` clean. All new/changed files consistent with codebase
  idiom (moduledocs in the house style — read neighbors first).
- No Rust, no new deps in `mix.exs` (`:crypto` is already available).
- A short final summary: what you built, any spec ambiguities you
  resolved and HOW, anything you want flagged for review.
