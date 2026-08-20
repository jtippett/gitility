# M4c — `into: {:bundle, path}`: PackFetch hydration into a single-file bundle

Closes the last reserved `into:` mode (design doc: "a remote store
hydrates into a local bundle that survives restarts on a reused
volume"). NORMATIVE FORMAT REFERENCE:
`docs/format/bundle-v1.md` (all open questions now
resolved). Where this document and the format spec conflict, the format
spec wins on format.

## Read these before writing code

- `docs/format/bundle-v1.md`
- `lib/gitility/odb/pack_fetch.ex` (destination/3, start flow,
  `packfetch_cleanup_destination`), `lib/gitility/odb/provider.ex`
  (terminate cleanup at ~223)
- `lib/gitility/bundle.ex` + `lib/gitility/bundle/format.ex` (the
  writer you will refactor and reuse), `lib/gitility/bundle/range_backend.ex`
- The native hydrator READ-ONLY, to learn destination file naming and
  warm-pair behavior: start from `Native.packfetch_hydrate` and follow
  into `crates/` (you may read Rust; you may NOT change it)
- `test/milestone_2e_packfetch_test.exs`, `test/milestone_4b_bundle_test.exs`
  (idioms, helpers, counting/probing patterns)

## Hard constraints (standing project rules — non-negotiable)

- **NO BEAM on this machine.** Never run `mix test`, `mix compile`,
  `iex`, `mix run`, or ANY other mix task that boots mix —
  `mix format` (plain, no flags) is the single allowed exception.
  Verification happens later on the remote sprite, not by you.
- **NO Rust changes.** Elixir-only. If you become convinced native code
  is required, STOP and write why instead of writing Rust.
- No new deps. Do not commit. Never pattern-kill processes. Do not
  modify gitignored `sources/`.

## Design (decided — implement, don't re-litigate)

Architecture: hydration itself stays 100% native and untouched. The
bundle destination is an Elixir composition around it:

1. **Scratch serving directory.** `into: {:bundle, path}` creates a
   private scratch directory (under `System.tmp_dir!()`, keyed like
   `:memory`'s destination key) and passes THAT as the hydrator's
   destination. It is registered for the existing
   `packfetch_cleanup_destination` teardown (always cleaned; the bundle
   file at `path` is the durable artifact and is never cleaned).
   Works on every platform (no Linux gate; no `:max_bytes`).
2. **Warm start = pre-extraction.** If `path` holds a parseable bundle:
   extract each section into the scratch directory under the bundle's
   TOC file names, verifying the container per-file sha256 WHILE
   extracting; a mismatched section is skipped (not written) — the
   native hydrator then treats it as missing and re-fetches (self-
   healing, matches the "corrupt pairs are re-fetched" M2e behavior).
   The native warm-pair verification re-proves everything anyway; the
   sha256 check just avoids planting known-bad bytes. If `path` does
   not exist: cold start. If `path` holds a file that does NOT parse as
   a bundle (`:invalid_argument`/`:malformed_object`): REFUSE to start,
   same never-clobber policy as `Bundle.write/2` — the caller removes
   it. IMPORTANT: for warm extraction to be picked up, the extracted
   file names must be exactly what the hydrator expects in a reused
   destination — read the native code to confirm the naming (the TOC
   names were produced by a previous hydration into a scratch dir, so
   round-tripping should be identity; verify, don't assume).
3. **Bundle write after hydration.** When `start_link`'s hydration
   completes successfully, build the bundle: file pairs = the CURRENT
   manifest's pack/idx pairs as materialized in the scratch directory
   (TOC names = those destination file names), `hash_algorithm` = the
   manifest's hash, refs = ZERO rows (a hydration bundle is ODB-only;
   full repository bundles come from `Bundle.write/2` — document this
   in both moduledocs), metadata: `source_identity` defaulting to
   `"packfetch:generation:" <> manifest.generation` (deterministic;
   never a timestamp), overridable via a new `:bundle_source_identity`
   option. Write discipline and generation policy are the format
   spec's: temp file + fsync + atomic rename; fresh = 1, replacing a
   valid bundle = its generation + 1.
   **Rewrite-if-changed:** if the existing bundle already holds exactly
   the same pair set (same names, lengths, sha256s — you compute the
   sha256s while streaming the write, so compare names+lengths from
   the TOC first and hash scratch files only when they all match),
   leave the file byte-untouched (no generation churn). A failed
   bundle write is a LOUD start_link error (the caller declared this
   destination; do not degrade it to a warning).
4. **Refactor, don't duplicate.** Extract the streaming
   container-writer core from `Gitility.Bundle.write_bundle/…` into a
   shared function that takes explicit pair paths + metadata + refs;
   `Bundle.write/2`'s observable behavior and existing tests must not
   change.
5. **Refresh (stretch — attempt, flag if gnarly).** `ODB.refresh/1` for
   `kind: :pack_fetch` runs native refresh from the caller with no
   bundle context. If you can thread the bundle destination cleanly
   (e.g. a field on the ODB handle populated from `packfetch_options`)
   so a successful refresh re-runs step 3, do it. If that turns into
   surgery on the provider/native seam, STOP: leave refresh
   bundle-untouched, document in the PackFetch moduledoc that the
   bundle snapshots the manifest as of the last completed start_link
   hydration (refresh serves new packs from the scratch store without
   rewriting the bundle), and flag it in your summary as a de-scoped
   follow-up.
6. **Budget:** unchanged — `max_hydration_bytes` charges only backend
   (remote) reads. Local extraction from the bundle is never charged.
7. Update the `PackFetch` moduledoc (`into:` docs at lines ~42-51) —
   the reserved-mode paragraph becomes real documentation, including
   the scratch-directory materialization (explicitly documented
   private tmp usage, like `:memory`'s caller-invisible `/dev/shm`
   note), the durable-artifact contract, refs-are-empty, and the
   never-clobber refusal.

## Tests

Follow house idioms. `@moduletag :gitility_engine` where the engine is
exercised. Reuse M2e's publish helpers.

1. **Cold hydrate:** publish `sha1-basic-packed.git` via LocalDirectory
   → `PackFetch.start_link(backend: …, into: {:bundle, path})` → the
   bundle exists, `Bundle.verify(path)` passes, `Bundle.info(path)`
   shows generation 1 / zero refs / the manifest's pack count, and the
   ODB serves an `{:oid, …}` query with parity vs the directly opened
   source.
2. **Warm restart, zero remote reads:** stop the supervisor, start a
   second PackFetch on the same bundle path with a COUNTING wrapper
   backend (wrap LocalDirectory; count `read_ranges` calls) → hydration
   completes with zero `read_ranges` calls and the bundle file is
   byte-unchanged (hash before/after; no generation churn).
3. **Partial warm:** grow the source (add a pack: publish a second
   fixture pack or repack-with-additions into the published store, per
   M2e helper idioms), restart on the same bundle path → only the new
   pair fetches remotely (counting backend), the bundle is rewritten
   with generation 2 and now covers both pairs.
4. **Self-healing corruption:** flip one byte inside a section of the
   bundle between runs → warm start still succeeds (that pair
   re-fetched — assert via counting backend), bundle rewritten valid.
5. **Never-clobber:** destination path holds a non-bundle file →
   `start_link` refuses with the same error/code family as
   `Bundle.write/2`'s refusal; file untouched.
6. **Determinism:** two cold hydrations of the same published store
   into two paths → byte-identical bundles.
7. **Round-trip composition:** the hydration bundle opens via
   `Bundle.open(path, into: {:dir, tmp})` and serves `{:oid, …}`
   queries; ref listing is empty (selectors refuse as M4a specifies).
8. **Teardown:** after `Supervisor.stop`, the scratch directory is
   gone and the bundle file remains.
9. **Empty manifest:** a published empty store hydrates into a legal
   empty bundle (0 pairs) that verifies.
10. **Existing destinations untouched:** `:memory` and `{:dir, path}`
    suites still pass unmodified (do not edit their tests).
11. If refresh-rewrite (item 5) ships: refresh after source growth
    rewrites the bundle generation+1; if de-scoped, test the documented
    behavior instead (refresh serves, bundle untouched).

## Definition of done

- `mix format` clean (plain invocation only). No Rust, no new deps.
- Every deliverable addressed or explicitly flagged with reasoning —
  never silently skipped.
- Final summary: what you built, the native destination-naming facts
  you verified (with file/line refs), refresh outcome (shipped or
  de-scoped and why), anything you want flagged for review.
