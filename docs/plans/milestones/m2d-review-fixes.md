# M2d review fixes

Standing rules as `m2c-provider-odb.md`. Findings CONFIRMED by review of
checkpoint c943669. Decisions final. Write surface: crates/gitility-core,
native/gitility, lib, test, design doc (H2 doc only), root Cargo.lock.

## H1 [HIGH] Headers behind a cache become full payload downloads, forever
`try_header_with_provenance` on a cached layered store never uses the
lower layer's header path — it fetches the payload to derive a
verifiable header. Correct trust reasoning, but a `max_object_bytes`-
bypassing object re-downloads its whole payload on EVERY header query
(confirmed: 3 header calls on a 256 KiB blob → 3 full transfers, 0
header calls), which also makes `list_tree(include: [:size])` over
`[cache, provider]` download every blob one-by-one.
DECISION: two-tier header policy —
 (a) if the object is resident in the cache → derive the header from
     the verified payload (free, verified — current behaviour);
 (b) if NOT resident → call the lower layer's OWN `try_header` (its
     header path: local/static verified headers, provider header
     replies with their existing UnverifiedProvider provenance and
     ceiling), and do NOT fetch the payload. Header queries never
     populate the cache (only payload reads do). Provenance flows
     through unchanged, so a provider header behind a cache is
     `UnverifiedProvider` exactly as it is without a cache — the M2c
     carve-out applies uniformly and the docs already cover it.
 Document on ODB.layer/1: "header queries are answered by the cache
 when the object is resident, otherwise by the first layer that has
 it, without fetching payloads." Tests: the review's repro now shows
 header_calls=3, read_many_calls=0 for the bypassing blob; a resident
 object still answers from cache with backend calls frozen;
 `list_tree(include: [:size])` over `[cache, provider]` issues header
 batches, not payload reads (assert via backend call kinds).

## H2 [HIGH] A failing layer poisons the composition — undocumented
`[down_provider, static]` fails reads the static layer could serve;
`[static, down]` turns a genuine miss into :backend_error.
DECISION: fail-fast STAYS (falling through would mask outages and
could answer a false "not found" — the wrong kind of wrong for a
correctness-first library), but it becomes explicit and observable:
 - Document on ODB.layer/1 and in the design doc's "Layered ODBs"
   section: "A layer error fails the read; layers are not failover
   replicas. Compose caches with one authoritative store; use
   supervision/retry at the store level for availability."
 - The error carries `details: %{layer: index}` so callers can tell
   WHICH layer failed.
 - Short-circuit stays: a hit before the failing layer succeeds
   (already true — add the test).
 Tests: `[down, static]` → error with details.layer == 0; `[static,
 down]` on an object static holds → :ok (never touches down); on a
 missing oid → the error names layer 1 (not :missing_object — and
 the doc says so).

## M1 [MED] Nested caches bypass the one-cache rule and double-count stats
DECISION: reject nesting — `layer/1` refuses a `:layered` handle that
itself contains a cache with :invalid_argument "nested cache layers
are not supported in 0.x"; layered-without-cache handles may nest (a
pure composition is fine). Stats then never aggregate nested caches.
Test both.

## M2 [MED] Type errors return %Error{} where the convention says raise
Apply the M1c convention (bad option KEYS/TYPES raise ArgumentError;
semantic violations return %Error{}): non-list arg, non-ODB element,
non-keyword cache opts, unknown cache option, wrongly-typed cache
values → ArgumentError. Reuse Keyword.validate! like the sibling
provider validation. Test all 6 probed cases.

## M3/M4/M5 [MED, tests]
Add: populate-only-preceding-caches with the cache at index 1
(`[store_A, cache, store_B]`); LRU recency (touch A, insert past cap,
A survives, B evicted, evictions == expected); tripwire test that a
lying store panics on insertion in debug (cfg(debug_assertions)
test), AND add a serve-time debug_assert (free in release; document
it's a tripwire, not a guarantee) with a test that a corrupted
resident entry trips it in debug.

## M6 [MED] read_file's cache stats are dead (FileMap has no stats)
FIX: add `stats` to the read_file DTO map and `Gitility.File` — check
lib/gitility/types/file.ex: if the committed struct has no stats
field, ADD one (`stats: Gitility.Stats.t()`) — it is additive and the
design's "everything carries stats" principle wants it. Wire it. Test:
read_file over `[cache, provider]` twice → second call's stats show
cache_hits ≥ 1.

## M7 [MED] refresh/1 on an all-static layered handle returns :ok
FIX: layered refresh returns :ok only if at least one layer accepted
refresh; if EVERY layer refuses (`:unsupported_operation`), return that
error — consistent with the bare store. Document. Test.

## LOW batch
L1: replace `.expect("singleton layer read")` with a protocol error
(`:backend_error` "layer returned a short batch — ObjectDb contract
violation") and make the batch zip check lengths and error rather than
silently "not found". L2: cache_spec — validate the tuple shape and
reject raw `{:cache, kw}` tuples not produced by cache/1? They ARE what
cache/1 produces; instead validate contents identically regardless of
origin (which M2 already does after the fix). Document that the
"opaque" type is a soft contract. L3: header queries answered by a
cache should charge charge_header, not an object read — make
Stats.objects_read exclude cache-served headers.

## Missing hygiene from the review
Also run and report: loom suite, remote soak, remote `mix docs
--warnings-as-errors`.

## Verification
cargo fmt/clippy (both cfgs)/test; loom; spawn guard; REMOTE
sync/mix/soak; remote docs + format. No commit. Per-finding summary,
counts, remote summary lines.
