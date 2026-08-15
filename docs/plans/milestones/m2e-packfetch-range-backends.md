# Milestone 2e — pack manifest, RangeBackend, PackFetch, reference backends

Implementation spec, dispatched verbatim. Standing rules as
`m2c-provider-odb.md` (no BEAM on the Mac — remote sprite only; no new
native threads without budget + spawn-guard allowlist; orchestrator
commits).

## Design finding recorded here (F7 — verified from vendored source)

The design doc promises `PackFetch` `into: :memory` "holds pack bytes in
Rust-owned memory … hands the bytes to the standard gix-pack machinery".
Verified in `sources/gitoxide/gix-pack/src/{bundle,index}/init.rs`:
gix-pack's `Bundle::at` / `index::File::at` are **path-only and
mmap-based** — there is no in-memory constructor. Stock gix cannot serve
from Rust-owned bytes. Therefore, in 0.2:

- `into: {:dir, path}` is the primary destination and uses stock gix
  exactly as designed (fetch → verify → write `.pack`/`.idx` keyed by
  checksum → open the directory as a normal object store via the M1a
  `LocalOdb` machinery over an `objects/pack`-shaped layout).
- `into: :memory` is honoured **only when the platform gives us a
  memory-backed path**: on Linux, a caller-invisible directory under
  `/dev/shm` (documented; sized against `max_bytes`; cleaned on
  shutdown/GC — the no-hidden-materialization rule bans hidden *disk*
  writes; a RAM-backed tmpfs under an explicit ceiling honours the
  spirit and is documented plainly). On macOS/other, `into: :memory`
  returns `{:error, %Error{code: :unsupported_operation}}` with a
  message pointing at `{:dir, path}`. True bytes-in-Rust serving is
  the M5 `PackRange` reader's own pack machinery (checkpoint C1) — this
  finding is one more input to C1. Record it in the design doc's
  Feasibility findings as F7 (one paragraph, in the same style as
  F1–F6) and amend the "Eager hydration" section's `into: :memory`
  sentence to reference F7. Also add `into: {:bundle, path}` to the
  option docs as "arrives with Gitility.Bundle (0.2, later milestone)"
  → `:unsupported_operation` for now.

## The task

Read first: design doc "Remote pack storage" through "Range backend
behaviour" and "Remote-pack cache policy"; `lib/gitility/odb/
range_backend.ex` (frozen behaviour); `lib/gitility/types/
{pack_manifest,pack_descriptor,byte_range}.ex` (frozen structs); the M2c
provider (`crates/gitility-core/src/provider_odb.rs`, `lib/gitility/odb/
provider.ex`) — PackFetch's Elixir side reuses its supervision/dispatch
pattern and request-resource protocol wholesale (a `RangeBackend`
callback is dispatched exactly like an `ODB.Backend` callback); M1a
`local_odb.rs` (the store that serves the hydrated directory).

Write surface: `crates/gitility-core/`, `native/gitility/`, `lib/`,
`test/`, root `Cargo.lock`, and the two design-doc edits above (F7).

### Architecture (final)

**Core: `PackFetch` hydration (BEAM-free).**
- `PackManifest`/`PackDescriptor` Rust mirrors (validated on decode:
  version == 1, hash kind known, ids are hex digests of the right
  length, sizes > 0, keys non-empty, no duplicate ids).
- A `RangeTransport` trait (the NIF implements it, same shape as
  `ProviderTransport`): `manifest(&self, budget) -> Result<PackManifest,
  Error>` and `read_ranges(&self, ranges: &[ByteRange], budget) ->
  Result<Vec<Vec<u8>>, Error>` (reply per range, in order; a short read
  is an error).
- Hydration plan: fetch manifest → for each pack: fetch the WHOLE `.idx`
  (small, needed for lookup) and the WHOLE `.pack` as coalesced
  fixed-size range reads (`chunk_bytes` option, default 8 MiB;
  `concurrency` ranges in flight per pack — the concurrency is achieved
  by issuing N `read_ranges` requests concurrently from the hydration
  JOB's worker thread? NO — a job runs on ONE worker; instead the
  Elixir provider dispatches each `read_ranges` callback to a Task and
  the core issues up to `concurrency` outstanding requests before
  awaiting replies (a small in-core window over the request-resource
  protocol — same pending table, N ids in flight)). Every fetched byte
  is charged to the budget (`max_provider_bytes`); the plan is
  budgeted so a manifest describing 50 GB fails `:budget_exceeded`
  BEFORE fetching. Verify: pack trailer checksum and idx checksum
  (the M1a `verify_pack_checksums` machinery, unconditionally ON here —
  this IS the acquisition trust boundary the design doc names), and
  the idx ↔ pack pairing (idx's pack checksum matches). Write to the
  destination directory as `pack-<checksum>.pack`/`.idx` via
  write-temp-then-rename (a crashed hydration never leaves a
  half-file with the final name); a pack whose files already exist
  with the right names AND whose checksums verify is skipped (this is
  what makes a reused volume near-free); a pre-existing file that
  FAILS verification is replaced (log-worthy: return it in stats as
  `replaced_corrupt`).
- After hydration, open the destination as a `LocalOdb` (reuse M1a; the
  directory is laid out as `<dest>/objects/pack/` so LocalOdb's
  existing bare-layout detection works — construct the minimal bare
  skeleton: `objects/pack/`, `HEAD`? — do NOT fabricate refs; use the
  M1a "objects dir only" open path if it exists, else add a
  `LocalOdb::open_objects_dir(path)` that opens an objects directory
  without requiring a repository skeleton — report which). The
  resulting `ObjectDb` IS the PackFetch store; queries need no changes.
- `refresh`: re-fetch the manifest; hydrate only packs not present;
  keep serving throughout (LocalOdb refresh picks up new packs — verify
  the M1a store's `refresh()` does this; complete it if inert).
  Removed packs stay on disk (design: grace period; we never delete
  during refresh in 0.2 — document).
- Stats: packs hydrated, bytes fetched, bytes verified, packs skipped
  (already present), replaced_corrupt, elapsed per phase — surfaced
  through the ODB handle's stats.

**NIF.** `RangeTransport` impl mirroring the M2c provider transport
(request resources, worker-thread OwnedEnv sends, DirtyCpu reply copy
with size preflight — a `read_ranges` reply's total bytes must equal
the requested lengths exactly). `packfetch_store_new(hash, opts)`,
`packfetch_hydrate` runs AS A JOB on the runtime (it's long work — never
a synchronous NIF), `packfetch_refresh` likewise. `StoreImpl::PackFetch`.

**Elixir.** `Gitility.ODB.PackFetch.start_link/1` — same two-shape
pattern as M2c (`start_link` → supervisor pid; `Gitility.ODB.handle/1`
→ handle): options per the design doc example (`backend: {mod, arg}`,
`into: {:dir, path} | :memory | {:bundle, path}`, `concurrency`,
`verify: :always` only, `runtime`, `chunk_bytes`, `max_bytes` for
:memory). `start_link` runs `backend.init`, starts the provider-style
supervision tree (Task.Supervisor + Provider + Watchdog — reuse M2c's
modules parameterised by callback kind, don't fork them), then submits
the hydration job and **blocks `start_link` until hydration completes
or fails** (the store is unusable before; document; a
`hydrate: :async` option can come later — not now). Hydration failure
→ `start_link` returns `{:error, %Error{}}` and cleans the tree.
`Gitility.ODB.refresh/1` for PackFetch handles → refresh job.
`Gitility.ODB.RangeBackend.Conformance` — the range-backend twin of the
M2c kit: manifest shape validity, `read_ranges` exactness (byte counts,
order, arbitrary offsets incl. last-byte and zero-length), concurrent
safety, terminate tolerance.

**Reference backends (ship in the library, documented, conformance-
tested).**
- `Gitility.ODB.RangeBackend.LocalDirectory`: `init(dir)`; manifest
  built by scanning `<dir>/manifest.json`? NO — the manifest must be
  atomic and content-addressed: `init(dir)` reads
  `<dir>/manifest.<generation>.json`? DECISION: the directory holds
  `packs/pack-<checksum>.{pack,idx}` and a `manifest.json` written
  atomically (temp+rename) by the publisher; `read_ranges` = pread on
  the files. Ship `Gitility.ODB.RangeBackend.LocalDirectory.publish/2`
  (from a local bare repo dir: copies packs+idx, writes manifest) so
  tests and users can produce a valid store from any bare repository.
- `Gitility.ODB.RangeBackend.Postgres`: chunked-pack layout per design
  (1 MiB `bytea` rows keyed `(pack_id, chunk_index)`, a manifest table,
  generation column). Implemented against `Postgrex` as an OPTIONAL
  dependency (`optional: true` in mix.exs; module compiles only if
  Postgrex is present — `Code.ensure_loaded?` guard + clear error). Ship
  `publish/3` too. Tests: run only when `GITILITY_TEST_POSTGRES_URL` is
  set (skip otherwise, loudly in the log); on the sprite, install
  postgres (`sudo apt-get install -y postgresql`, start it, create a db,
  set the env var in the remote harness prelude when present) — do that
  provisioning as part of this task and record the steps in
  `scripts/remote-test.sh` comments; if it proves impossible in the
  sprite, say so and skip — do NOT weaken the tests to fake it.

### Tests (BEAM remote)

- LocalDirectory publish from sha1-basic AND sha1-history-midx (multi-
  pack) fixtures → PackFetch `into: {:dir, tmp}` → FULL parity with the
  local store: recursive list_tree, read_file on ≥5 paths incl. 0xFF,
  snapshot+peel, ODB.read/header/read_many. Same over `into: :memory`
  on Linux (the sprite IS Linux — assert it works there; assert
  `:unsupported_operation` on non-Linux via a platform check helper).
- Reused volume: second `start_link` against the same dir hydrates 0
  packs (stats.packs_skipped == N, bytes_fetched ≈ manifest only).
- Corrupt-on-disk: flip a byte in a pre-existing `.pack` in the dest
  dir → hydration replaces it (replaced_corrupt == 1) and parity holds.
- Corrupt-from-backend: a RangeBackend that flips a byte in a pack
  range → hydration FAILS `:pack_checksum_mismatch` (start_link
  errors), no partial final-named files in dest (only temps, cleaned).
  Same for a bad idx (`:index_checksum_mismatch`) and idx↔pack pairing
  mismatch (`:pack_checksum_mismatch` or a protocol error — document).
- Short/over-long range replies → `:provider_protocol_error`; manifest
  with a duplicate id / bad version / wrong-length checksum → protocol
  error; manifest describing more bytes than max_provider_bytes →
  `:budget_exceeded` before any range read (backend read_ranges call
  count == 0).
- Concurrency: with `concurrency: 4`, max in-flight `read_ranges` > 1
  (latch-based); `concurrency: 1` → never > 1.
- Cancellation/timeout: kill the backend mid-hydration → start_link
  returns `:provider_down`; a hung `read_ranges` with a small
  `request_timeout` → `:provider_timeout`.
- Refresh: publish sha1-basic, hydrate, publish an additional pack
  (e.g. run `git repack`-style: create a second pack from a second
  fixture with disjoint objects — simplest: publish sha1-history-midx's
  packs into the same dir with a new manifest), refresh → new objects
  readable, stats show only the new packs fetched.
- Conformance kits: LocalDirectory passes; a broken backend (short
  reads) fails; Postgres passes when the env var is set.
- Load-time target smoke (not a benchmark — a sanity ceiling): the
  midx fixture hydrates in < 2 s on the sprite (log the number).

### Hygiene
Same as M2c/M2d + `mix docs --warnings-as-errors` (both new modules
documented) + spawn guard (no new sites — hydration runs on existing
worker threads). No commit. Print change summary, counts, remote
summary lines, F7 doc edits made, Postgres provisioning outcome,
ambiguities resolved.
