# M4b review fixes — decided outcomes of the adversarial review

Applies on top of commit 28bf007 ("Checkpoint: M4b Gitility.Bundle
implementation"). Where this document conflicts with
`docs/plans/milestones/m4b-bundle.md`, THIS document wins. The format
spec `docs/plans/2026-08-17-bundle-format-v1.md` was amended alongside
this spec (shallow reserved key, no-op refresh, pack-objects threads) —
re-read its "Required metadata keys", writer-contract generation bullet,
and determinism bullet before starting.

Hard constraints unchanged: NO BEAM on this machine (no mix
test/compile/iex/run; `mix format` allowed), NO Rust changes, no
commits, never pattern-kill. The sprite suite currently shows 11
failures — 10 from H1, 1 from H2; after your fixes the expectation is
ZERO new-code failures.

## H1 — conformance kit `or` on non-boolean (BREAKS EXISTING M2e TESTS)

`lib/gitility/odb/range_backend/conformance.ex:58`:
`@range_expected_failure or @range_prepublished_synthetic` raises
`BadBooleanError` (`@range_expected_failure` is nil or an atom). Change
to `||`. This currently fails 10 sprite tests, including previously
green M2e suites (`LocalDirectoryRangeConformanceTest`,
`BrokenRangeConformanceTest`) AND all four bundle range-conformance
tests — the bundle backend has never actually been conformance-checked.

## H2 — `function_exported?/3` at macro-expansion picks the wrong branch

Both kits test `function_exported?(backend, fun, arity)` during macro
expansion; lib modules are compiled but not LOADED then, so the check
returns false for any backend defined outside the test file.
Consequence today: `Gitility.RefDB.Backend.Conformance` generated the
"cannot list" test for `Gitility.Bundle.RefBackend` (which lists —
sprite failure #11), and the real list-contract test never ran; the
range kit's `terminate` branch silently emitted its skip stub.

Fix in BOTH kits: `Code.ensure_loaded?(backend) and
function_exported?(backend, fun, arity)` —
`lib/gitility/ref_db/backend/conformance.ex:138` (list branch) and
`lib/gitility/odb/range_backend/conformance.ex:129` (terminate branch);
audit each kit for any other `function_exported?` at expansion time.

## H3 — shallow sources: REFUSE in v1 (decided)

Bundling a shallow source today yields silently wrong history (the
partial-shallow fixture would return 13 commits where the source
returns 8) or `:missing_object` aborts (true depth-N clones), because
the format carries no boundary and hydrated stores have no
`shallow_roots`. Decided policy, now in the format spec:

1. `Gitility.Bundle.write/2` MUST refuse a source whose resolved git
   dir contains a `shallow` file: `{:error, %Error{code:
   :unsupported_operation}}` with a message naming the shallow file and
   the v1 limitation. (`PackInventory`/the write path already resolves
   the git dir — check there.)
2. `Gitility.Bundle.Format` parse MUST refuse any bundle whose metadata
   carries the RESERVED key `shallow_roots` with
   `:unsupported_operation` naming the key (feature gate — see the
   spec's rationale). This is a KNOWN reserved key, distinct from the
   ignore-unknown-keys rule; keep that distinction clear in the parser
   and moduledoc.
3. Tests: (a) write/2 against `sha1-history-shallow.git` → refused with
   the right code/message; (b) a synthetic bundle carrying
   `shallow_roots` metadata → parse refused `:unsupported_operation`;
   (c) REMOVE `"sha1-history-shallow.git"` from the parity-test family
   list (it was named but never history-checked — false coverage).

## M1 — unknown FILE kinds must not break pack/idx pairing

`lib/gitility/bundle/format.ex:366-384`: `validate_pairs/2` only skips
an unknown-kind entry at the head of the list; `[pack, unknown, idx]`
is wrongly rejected as a missing idx partner, violating the spec's
minor-additive rule. Fix: run pair validation over `sections` filtered
to `kind in [:pack, :idx]` (tiling validation MUST keep using the
unfiltered list — that part is correct today). Add a hostile case:
`[pack, unknown-kind, idx]` parses successfully and the unknown entry
is ignored.

## M2 — alternates in `LocalDirectory.publish/2`: keep, make deliberate (decided)

`PackInventory.collect/3` follows `objects/info/alternates`
transitively; old LocalDirectory did not. DECISION: the inclusive
behavior is correct for BOTH callers — a publish that silently omits
alternate-borrowed packs produces an incomplete store, which is the
same disease the bundle exists to prevent. Actions:

1. Keep the behavior; document it in the `LocalDirectory` moduledoc
   ("publish follows alternates transitively; a missing alternate
   directory is a loud error") and in `PackInventory`'s moduledoc.
2. Add a publish test for `sha1-alternate.git` through LocalDirectory:
   the published manifest includes the alternate's pack(s), hydration
   serves an object that lives only in the alternate, and parity holds
   vs the directly opened repo.
3. Keep the loud `{:error, {:alternate_objects_directory_missing, dir}}`
   on broken alternates (test it with a doctored alternates file).

## M3 — refresh on a bundle is a NO-OP (decided; spec amended)

A bundle open is pinned to one generation for its lifetime; moving
generations = `Bundle.open/2` again. Changes:

1. `Gitility.Bundle.RefBackend.refresh/1` → `:ok` no-op. Delete the
   Agent (`pinned_state/2` machinery) entirely — state is the parsed
   snapshot from `init/1`, immutable. (This also removes review finding
   L8's unsupervised-Agent hazard.)
2. `Gitility.Bundle.RangeBackend`: no refresh callback exists in the
   behaviour — just confirm nothing re-pins.
3. Update the generation-move test: after an atomic replacement,
   read_ranges still fails loudly (unchanged), `RefDB.refresh(refs)`
   returns `:ok` and the refs STILL serve the ORIGINAL pinned
   generation, and a fresh `Bundle.open/2` on the path serves the new
   one. Also add: renaming an OLDER-generation bundle over the path
   never affects the pinned open (subsumes the rollback concern).
4. Moduledoc for `Gitility.Bundle`: state the pinned-for-lifetime
   contract explicitly.

## M4 — byte determinism must cover loose packing (+ threads pin)

1. In `PackInventory.pack_loose_objects/5`, pass `--threads=1` to
   `git pack-objects` (multi-threaded delta search is not byte-stable;
   the loose pack's content-derived NAME feeds the TOC). The format
   spec now records this.
2. Add a determinism test: write `sha1-basic-mixed.git` (loose +
   packed) twice → byte-identical files (hash compare). If this test
   fails on the sprite even with --threads=1, DO NOT normalize it away
   — flag it in your summary; the spec's determinism promise would need
   explicit narrowing, which is not your call.

## M5 — cursor paging tests

Add to the bundle ref tests: (a) list with `limit: 2` over the
generation-move fixture (or any bundle with ≥5 refs) — walk all pages,
assert the concatenation equals a single unlimited list (gapless,
duplicate-free) and `truncated ⟺ next_cursor` per page; (b) a garbage
cursor (non-base64url and valid-base64url-wrong-payload) is rejected
with the code the RefDB provider contract specifies (read the provider;
do not invent a code).

## M6 — sha256: delete the dead fallback, assert the live one

1. DELETE `git_object_kind/3` and `missing_git_object?/1`
   (`lib/gitility/bundle.ex:524-569` area): `ODB.header/3` has no hash
   gate (verified against the NIF), so the `:unsupported_hash` branch is
   unreachable, and the stderr-string-matching shell-out is a
   liability. `object_kind` uses `ODB.header` only; `:missing_object`
   remains the skip trigger.
2. KEEP `git_peel_to_commit/3` (live: `Gitility.peel` refuses sha256
   stores) with a comment stating exactly why it exists (core peel
   gates on sha256; remove when the engine peels sha256).
3. Add to the sha256 branch of the parity test: the bundle's
   `refs/tags/v1.0.0` row has `kind: :tag` and non-nil `peeled` equal
   to `git rev-parse v1.0.0^{commit}` from the oracle/pinned git.

## LOW fixes (all in scope)

- L2: `format.ex:416` unused `label` → `_label`.
- L3: replace the three same-shaped tiling mutations with genuinely
  distinct cases: a real gap (offset too high + trailing slack), a real
  overlap (two entries whose ranges intersect), and out-of-order
  entries that still tile (swap two pairs' offsets+lengths) — each
  asserting `:malformed_object`.
- L4: hostile cases for missing `source_identity` key and for
  `hash_algorithm` byte flipped 1→2 over 20-byte oids (both
  `:malformed_object`).
- L5: `bad_sha` mutation uses `Bitwise.bxor(byte, 1)` instead of
  `<<255>>` (match the corrupt-section test's approach).
- L6: `Bundle.info/1` final shape (0.2 freezes the API):
  `%{format_version: "MAJOR.MINOR", hash_algorithm:, generation:,
  source_identity:, metadata:, file_count:, ref_count:, bytes:}` —
  drop `files`/`refs`/`format_major`/`format_minor` duplicates; update
  its tests and any callers.

## Done criteria

- `mix format` clean; no Rust, no new deps; all findings above
  addressed or explicitly flagged (never silently skipped).
- Final summary: what changed per finding, plus anything you believe
  the review got wrong (say so with evidence rather than complying
  silently).
