# M4c review fixes — decided outcomes of the adversarial review

Applies on top of commit 255680d ("Checkpoint: M4c into: {:bundle, path}
implementation"). Where this document conflicts with
`docs/plans/milestones/m4c-bundle-destination.md`, THIS document wins.

Hard constraints unchanged: NO BEAM on this machine (plain `mix format`
is the single allowed mix invocation), NO Rust changes, no new deps, no
commits, never pattern-kill. The sprite suite currently shows 21
failures, ALL from R1's crash; after your fixes the expectation is ZERO
failures.

## R1 — DE-SCOPE refresh-time bundle publication (decided; subsumes the HIGH crash)

The stretch item is withdrawn. The refresh-rewrite path reads a
provider-recorded manifest AFTER the native hydration lock is released,
so under concurrent refreshes it can publish another refresh's
manifest (whose packs are not on disk yet → spurious `{:error, …}`
from a refresh that succeeded), and two racing publications can both
write generation N+1, violating the format spec's monotonicity
contract. Correct refresh publication needs a single-owner publisher
design — a follow-up, not a patch. Changes:

1. Remove the refresh persist hook in `lib/gitility/odb.ex` (refresh
   for `kind: :pack_fetch` returns to its pre-M4c body), the
   `packfetch_bundle` field on `%ODB{}`, and the handle-tuple widening
   — `lib/gitility/odb/provider.ex`, `lib/gitility/odb.ex`, and
   `lib/gitility/odb/watchdog.ex` revert to the pre-M4c handle shape.
2. `persist_bundle` runs ONLY inside `start_provider` and ONLY for
   bundle destinations — an explicit guard, so non-bundle destinations
   can never reach it (this is the sprite's 21-failure BadMapError at
   `pack_fetch.ex:518`: the arity-2 clause had no nil-context guard,
   killing every `:memory`/`{:dir}` start including `Bundle.open/2`).
3. Keep the provider's record-manifest-before-reply mechanism — it is
   the channel `start_provider`'s publication uses.
4. PackFetch moduledoc documents the contract: the bundle snapshots the
   manifest as of the LAST COMPLETED `start_link` hydration; refresh
   serves new packs from the scratch store WITHOUT rewriting the
   bundle; a restart re-publishes; exactly ONE store may own a bundle
   path at a time (concurrent writers to one path are out of contract).
5. Update the M4c refresh test to the documented behavior: grow the
   source, `ODB.refresh/1`, assert new objects are served AND the
   bundle file is byte-unchanged; then stop, restart on the same path,
   assert the bundle now covers the growth with generation 2.

## R2 — hash-family gate on warm adoption (silent-destruction bug)

`destination/4` never sees `opts[:hash]`; extraction adopts any valid
bundle. A sha256 bundle at `path` + a (default) `hash: :sha1` store =
foreign 64-hex pairs planted in scratch, then `persist_bundle` rewrites
`path` from the sha1 manifest — generation+1, every sha256 section
silently dropped. Fix: thread the configured hash into the destination
setup and REFUSE a bundle whose `toc.hash_algorithm` differs:
`:invalid_argument` naming both algorithms, file untouched. Test:
sha256 bundle at the destination + sha1 store → refused, bundle
byte-unchanged.

## R3 — foreign-artifact refusal + honest rewrite suppression

1. REFUSE a destination bundle with `ref_count > 0`
   (`:invalid_argument`, message naming the ref count and pointing at
   `Bundle.write/2`): hydration bundles are ODB-only by contract; a
   bundle carrying refs is someone's repository artifact and must never
   be silently stripped to zero refs by adoption+rewrite. File
   untouched. Test: `Bundle.write/2` a full bundle whose packs match
   the published store, point `into: {:bundle, path}` at it → refused.
2. `snapshot_changed?` currently compares only pairs
   (names/lengths/sha256s), so a warm restart with a DIFFERENT
   `:bundle_source_identity` silently keeps the old identity forever.
   Fix: the suppression comparison is "the would-be output equals the
   existing bundle modulo generation" — pair set identical AND the
   existing TOC's metadata map equals exactly the metadata this
   publication would write (refs are already guaranteed empty by item
   1). Test: warm restart with a new `:bundle_source_identity` →
   rewritten, generation+1, `info/1` shows the new identity.

## R4 — scratch-directory lifecycle: reclaimable key + documented caveat

The leftover sweep keys on `memory_destination_key(name)`; anonymous
supervisors get a per-start unique key, so a brutally-killed run's
scratch directory (full pack copies in `System.tmp_dir!()`) is NEVER
reclaimed. Fix: derive the scratch key for bundle destinations from a
hash of the EXPANDED bundle path (stable across restarts of the same
destination; two stores on one path are already out of contract per
R1.4). Sweep leftovers for that key at start, as today. Moduledoc: add
the abnormal-termination caveat exactly as the `:memory` paragraph does
for `/dev/shm`, noting this one lands on real disk.

## R5 — scratch directory is documented "private": make it 0700

`File.mkdir` yields umask-default (usually 0755) in a shared tmp dir —
any local user can read the hydrated repository. Create the scratch
directory with mode 0700 (and keep the existing `:eexist`-refusal
behavior).

## R6 — stop masking parse errors as "non-bundle file" (shared helper)

`existing_bundle/1` (pack_fetch) and `next_generation/1` (bundle.ex)
both collapse EVERY `Format.parse/1` error into the `:invalid_argument`
never-clobber refusal. Two wrong outcomes: a reserved-`shallow_roots`
bundle (correctly `:unsupported_operation` from the parser, per the
format spec's feature gate) reads as "not a bundle"; an `:eacces`/`:eio`
on a perfectly good bundle reads the same, non-retryably. Fix: ONE
shared classification helper (put it in `Gitility.Bundle` or `Format`;
both call sites use it): valid → `{:ok, toc}`; `:enoent` → missing;
parse `:invalid_argument`/`:malformed_object` → the non-bundle refusal;
`:unsupported_operation` → propagated AS-IS; file-read POSIX errors →
propagated as their own error, never "not a bundle". Tests: a
`shallow_roots`-carrying bundle at (a) a `Bundle.write/2` destination
and (b) a PackFetch bundle destination → `:unsupported_operation`
naming the key, file untouched.

## R7 — smaller items (all in scope)

1. `:bundle_source_identity` passed with a non-bundle `into:` →
   `:invalid_argument` (an accepted-but-ignored option is a footgun).
   Test both `:memory`… actually `{:dir, path}` suffices.
2. Moduledoc sentence (bundle paragraph): manifest-REMOVED packs are
   retained only in the scratch store for the process lifetime; the
   rewritten bundle omits them, so the grace period does not survive a
   restart for bundle destinations.
3. Design doc `docs/plans/2026-08-14-gitility-design.md` ~line 957:
   the sentence "`into: {:bundle, path}` arrives with `Gitility.Bundle`
   (0.2, later milestone) and returns `:unsupported_operation` for
   now" is stale — rewrite to state it shipped (M4c) with a pointer to
   the PackFetch moduledoc semantics.
4. `test/milestone_4c_bundle_destination_test.exs:22`:
   `Code.ensure_loaded?(config.delegate) and function_exported?(…)`
   (the house trap; benign here but the pattern must not spread).
5. `add_one_pair/2` unused second parameter.
6. `validate_snapshot_manifest/2`'s `loose: []` check: KEEP as
   defense-in-depth, but add a one-line comment that native already
   rejects non-empty loose, so this is a belt-and-braces invariant.

## Explicitly NOT in scope (decided)

- The provider handle-reply positional tuple → map refactor (reverts to
  its old shape under R1 anyway; the refactor is deferred).
- Refresh-time publication redesign (single-owner publisher) — recorded
  as a follow-up in the PackFetch moduledoc note, not built now.

## Done criteria

- Plain `mix format` clean; no Rust, no new deps.
- Every finding addressed or explicitly flagged with reasoning — never
  silently skipped.
- Final summary: what changed per finding, plus anything you believe
  this triage got wrong (say so with evidence rather than complying
  silently).
