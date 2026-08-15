# M2e review fixes

Standing rules as `m2c-provider-odb.md` (no BEAM on the Mac — sprite only;
LocalDirectory may be probed locally via bare `elixir -r ...` since it is
NIF-free; no new native threads; orchestrator commits). Findings CONFIRMED
by review of b6df4bd. Decisions final. Write surface: crates/gitility-core,
native/gitility, lib, test, docs (design doc for H2/M6/M7 decision records
+ backend behaviour docs for M4), root Cargo.lock.

## H1 [HIGH] LocalDirectory.publish drops loose objects from a mixed repo
`source_pairs` packs loose objects only when the repo has NO packs; a mixed
repo (sha1-basic-mixed: 28 packed + 1 loose) publishes a valid manifest
that silently lacks the loose object. Also `--all` drops unreachable
objects. DECISION: publish/2 must produce a COMPLETE inventory:
 - if the repo has loose objects (any file under objects/xx/), pack them
   ALL — reachable or not — via `git pack-objects` fed the loose object
   list on stdin (`find objects/?? -type f` → oids → stdin; this is
   git's own idiom and needs no reachability): the loose pack joins the
   existing packs in the manifest;
 - existing packs are copied as-is (never repacked by publish);
 - document the semantics: "publish captures every object the
   repository stores — packed and loose, reachable or not; it never
   garbage-collects".
Tests: sha1-basic-mixed publishes 2 packs and PackFetch reads the loose
object; an unreachable loose object (write one with `git hash-object -w`
in a temp copy) survives publish.

## H2 [HIGH] Warm volumes pay the full manifest against max_provider_bytes;
default 256 MiB refuses any larger repo, cold or warm.
DECISION (two parts, both required):
 (a) budget what will actually be FETCHED: compute the plan first (which
     packs are missing/corrupt on disk — verifying pre-existing pairs
     as today), then charge only the to-fetch bytes against
     max_provider_bytes. A fully-warm volume charges ~manifest bytes.
 (b) the ceiling itself: `Gitility.Limits.max_provider_bytes` (256 MiB)
     is a per-JOB safety ceiling for query-time provider work; a
     hydration is a different animal (a one-time bulk load the caller
     explicitly asked for). DECISION: PackFetch.start_link gets its own
     `max_hydration_bytes` option, default 4 GiB (a manifest above it →
     :budget_exceeded naming :max_hydration_bytes BEFORE any read), and
     hydration jobs run with limits whose max_provider_bytes =
     max_hydration_bytes. Query-time limits are unchanged. Document
     the two ceilings and why. Add a decision paragraph to the design
     doc's "Eager hydration" section.
Tests: warm restart with max_hydration_bytes < manifest total but >
missing bytes → succeeds, 0 bytes fetched; cold with a manifest above
the ceiling → refused before any range read; the default admits a
synthetic manifest of 300 MiB (no need to fetch — refusal check only).

## M3 [MED] PackFetch.child_spec omits type: :supervisor
FIX: add it (mirror ODB.child_spec). Test: PackFetch under a supervision
tree, `which_children` reports :supervisor, stop_supervised! prompt.

## M4 [MED] backend.init/1 now runs in the CALLER's process
Backend-owned processes (a Postgrex pool) end up linked to the caller,
outside the tree. DECISION: keep the design (correct parentage beats it)
and make it explicit and safe: (a) document in BOTH behaviours
(ODB.Backend, RangeBackend) under init/1: "runs in the process calling
start_link, before the provider tree exists; processes it starts are
linked to that caller unless the backend supervises them itself — start
long-lived resources under your own supervisor and pass a name/pid";
(b) the Postgres reference backend follows its own advice: init/1
starts its pool via `Postgrex.start_link` ONLY when given a URL/opts
(and documents that a production caller should pass an existing
supervised pool pid instead) — plus terminate/2 stops an owned pool
(already does). No code shape change beyond docs + the Postgres doc.

## M5 [MED] PackFetch swallows the backend-init reason
FIX: mirror ODB.start_link — `{:backend_init, reason}` → `{:error, reason}`
verbatim (the caller supplied the backend; its own error term is not a
secret). Raised exceptions → `{:error, {:backend_init_raised, message}}`.
Test the three modes are distinguishable.

## M6 [MED] Hydration success does not prove the store can serve
A forged-but-self-consistent .idx passes acquisition, then every query
errors. DECISION: add an open-time SANITY PROBE after hydration: open the
store and `try_header` ONE object per pack (the first oid in each idx —
cheap, no payload) — failure → hydration fails `:pack_checksum_mismatch`?
NO — use `:malformed_object` with message "hydrated pack <id> failed the
open-time probe" and clean the destination pair (treat as corrupt →
removed so the next run re-fetches). Decision record in the design doc
(one sentence under Eager hydration: "hydration ends with an open-time
probe; acquisition checksums prove bytes, the probe proves gix can read
them"). Test: the reviewer's forged-idx backend → start_link errors.

## M7 [MED] refresh re-hashes the whole store
DECISION: refresh verifies pre-existing pairs by SIZE + a cached
verified-marker, not a full re-hash: after a pair verifies (at hydrate
or a previous refresh), record `pack-<id>.verified` containing the pack
size + mtime? NO — mtimes are unreliable; DECISION: record the verified
pack ids IN MEMORY for the store's lifetime (a HashSet in the store
resource) — a pair verified once by THIS store instance is skipped on
refresh with a size check only; a NEW store instance (restart) re-verifies
everything once (that is the reused-volume path, which is correct to
re-hash: the disk is not trusted across restarts). Document: "refresh is
O(new packs) within a store's lifetime; open is O(store) — the disk is
re-verified once per process". Test: second refresh bytes_verified == 0.

## M8 [MED] Conformance kit thin + a tautology
FIX: (a) terminate case: assert `:ok`-or-any-term BUT via a real
mechanism — call terminate, then assert the backend can still `manifest`
(terminate must not poison shared state) — or skip explicitly when not
exported (already); (b) probe_ranges → a real matrix: whole artifact,
first byte, last byte, zero-length at 0 and at EOF, a range crossing
1 MiB+ boundaries when the artifact is large enough — and the kit
PUBLISHES a synthetic ≥ 2 MiB + odd-length artifact for that case
(generate deterministically in setup, no fixture change) so the Postgres
chunk seam IS crossed; multi-key request; out-of-bounds → :short_read.
Also fix L4 (macro's unconditional terminate warning) and L5 (ByteRange
length typespec non_neg_integer).

## LOW batch (do all)
L1: moduledoc honesty — publish stages a temp dir under the source
repo's objects/ (removed after); a read-only source repo → clear
{:error, :source_repository_read_only} rather than a git failure.
L2: multi-pack hydration failure: earlier verified packs stay (document
as intended — verified content, skipped next run) and update the test
assertion + spec wording ("no UNVERIFIED file under a final name").
L3: PackFetchOdb::drop must not do FS work on a scheduler: move
remove_dir_all to a request the pump/worker performs (same discipline as
runtime Drop — request-only) — or, simplest correct: the Elixir side
removes the /dev/shm dir in Provider.terminate/2 (already on a BEAM
process, not a scheduler-blocking destructor) and Drop only cleans if
the dir still exists AND does it via a spawned std::thread? NO (spawn
guard). DECISION: Elixir-side removal in terminate; Drop leaves it (a
GC'd handle without terminate = abnormal death; the /dev/shm dir is
bounded by max_bytes and named by the store — document + a leftover-
sweep on next start_link with the same name).
L6: preflight manifest reply size (cap packs/loose list length at, say,
100_000 entries before decoding).
L7: run_backend_init catches throw/exit too.
L8: check each Postgres chunk row length, not just totals.
L9: catch-all handle_info for wrong-kind requests → log + ignore.

## Missing tests (all remote)
1-11 from the review: corrupt pre-existing .idx; :memory cleanup after
stop/kill; PackFetch under a supervision tree; bad init → clean error;
failed start_link leaves no orphans (app children + thread budget
unchanged); Postgres chunk-boundary crossing (via the kit's synthetic
artifact); mixed repo through publish (H1); :memory over midx; read
during refresh + removed packs readable; non-empty loose rejected; and
RUST-SIDE unit tests for the acquisition boundary in packfetch.rs
(fetch_artifact, verify_pair_bytes, skip/replace, temp+rename) — the
trust boundary must be tested in core, not only through the BEAM.

## Verification
cargo fmt/clippy (both cfgs)/test; loom; spawn guard; REMOTE sync/mix/
soak with Postgres; mix format must satisfy BOTH Elixir 1.19 (sprite)
and 1.20 (local) — run the sprite's formatter last; remote docs. No
commit. Per-finding summary, counts, remote lines, decision-record
edits made.
