# M2c review fixes

Standing rules: as `m2c-provider-odb.md` (no BEAM on the Mac — remote
sprite only; no new native threads; orchestrator commits). Findings were
CONFIRMED with reproductions by an adversarial review of checkpoint
03d1d64. Decisions are final. Write surface: crates/gitility-core,
native/gitility, lib, test, docs/plans/2026-08-14-gitility-design.md
(F3 doc only), root Cargo.lock.

## F1 [HIGH] `{Gitility.ODB, opts}` in a supervision tree is broken
`ODB.start_link/1` returns `{:ok, %ODB{}}` (a struct), so as a supervisor
child it fails with `{:EXIT, {:ok, %Gitility.ODB{}}}` and kills the
caller — the documented primary integration path.
DECISION — two-shape API, the established Elixir pattern (Finch,
Registry): `Gitility.ODB.start_link/1` returns `{:ok, pid}` (the
supervisor pid) so it is a valid child; the HANDLE is obtained by
`Gitility.ODB.handle/1` (`handle(pid_or_name)` → `{:ok, %ODB{}}` |
`{:error, ...}`), and `ODB.start_link` requires OR auto-generates a
`:name` (document: pass `name:` for supervised use). Update every doc
example and every test. `child_spec/1` stays; `ODB.from_objects/2`
(no process) keeps returning the struct directly — document the
distinction in the moduledoc ("process-backed stores start_link → pid +
handle/1; value stores return the handle directly").

## F2 [HIGH] Any stray message kills a provider — permanently
No catch-all `handle_info/2` / `handle_call/3`; a misrouted message is a
FunctionClauseError → provider dies → handle poisoned forever.
FIX: catch-all `handle_info` (Logger.debug + ignore) and catch-all
`handle_call` (reply `{:error, :unknown_call}`) — a library GenServer
must be robust to the mailbox. Test: send garbage; provider alive;
reads still work.

## F3 [MED-HIGH] `read_headers` replies trusted unverified/uncapped/cached
A `read_headers` reply is unverifiable by construction (no payload to
hash), yet it's cached and flows into `include: [:size]` listings, so a
lying backend injects arbitrary sizes and mis-attributes errors to
repository content.
DECISION: (a) CAP: reject header replies whose `size` exceeds the job's
`max_object_bytes`... NO — a header for a legitimately huge blob is
valid metadata; instead: header replies are validated for SHAPE (kind
∈ known kinds, size ≤ a sanity ceiling of 2^40 — document) and marked
UNVERIFIED in the header cache; (b) TRUTH IN DOCS: amend the frozen
behaviour's moduledoc (`lib/gitility/odb/backend.ex`) — one paragraph
under `read_headers`: "Header replies cannot be verified (there is no
payload to hash). Gitility trusts them for type/size metadata only;
they never influence which bytes are served (payload reads always
verify). A backend that cannot answer headers truthfully should not
export read_headers — the fallback verifies via full reads." Add the
same carve-out sentence to the design doc's Object verification
section; (c) HARDEN THE CONSUMER: where `include: [:size]` uses
`try_header` and the header kind contradicts the tree entry's kind
(the review's `:malformed_object` case), the error must name the
PROVIDER, not the repository: use `:provider_protocol_error` with
message "provider header contradicts tree entry kind" — never
`:malformed_object` for a provider-sourced header. Tests: lying size
→ served as metadata (documented behavior) but bounded by the sanity
ceiling (2^40+1 → :provider_protocol_error); lying kind →
:provider_protocol_error naming the provider; local/static stores
unaffected.

## F4 [MED-HIGH] Graceful shutdown doesn't wake waiters (hang = request_timeout)
Child order `[TaskSupervisor, Provider, Watchdog]` shuts the Watchdog
down FIRST, so its monitor is gone when the Provider exits; nobody
calls provider_failed. FIX: `Provider.terminate/2` calls
`Native.provider_failed` itself (idempotent — fail_all on an already
drained table is a no-op) AND reorder children so the Watchdog outlives
the Provider (`[TaskSupervisor, Watchdog, Provider]` with the Watchdog
told the Provider pid via a registered name/lookup, or start order
Provider first but `shutdown` order handles reverse — Elixir
supervisors stop in REVERSE start order, so start `[TaskSupervisor,
Watchdog?...]` — think it through: you want Provider to STOP before
Watchdog, so Provider must START after Watchdog; the Watchdog then
learns the Provider pid via a `:via`/name lookup or a message —
implement whichever is cleanest and document the ordering invariant in
the supervisor module). Test: request_timeout 10_000, in-flight read,
`Supervisor.stop(odb_pid, :normal)` → the job fails `:provider_down`
within ~100ms.

## F5 [MED] `ODB.refresh/1` unbounded + clears negative cache before backend refresh
FIX: refresh goes through the same timer as requests (request_timeout;
timeout → `:provider_timeout`); order: run the backend refresh FIRST,
then clear the native negative cache (so a concurrent read can't
repopulate stale negatives between the two). Test both.

## F6 [MED] Provider caches: O(n) LRU under one global mutex
FIX: replace the VecDeque-scan LRU with a proper O(1) LRU (intrusive
doubly-linked list over a HashMap of nodes, or the classic
HashMap<Key, index> + slab with prev/next indices — ~150 lines, no dep;
same for the negative cache's expiry order). Keep one mutex (fine at
O(1)); add a micro-benchmark-ish unit test asserting 10^5 inserts+gets
complete in bounded time (generous bound, e.g. < 2s debug) so a
regression to O(n) is caught. M2d's CacheLayer reuses this — make it a
reusable `LruCache<K, V>` in core (`crates/gitility-core/src/lru.rs`).

## F7 [MED] Payload copy amplification (≥4 copies per provider object)
FIX: use `Arc<[u8]>` (or `Arc<Vec<u8>>`) for cached payloads so cache
insert and serve share one allocation; the NIF's initial `to_vec` is
the one necessary copy (BEAM → Rust memory); `try_find`'s
`extend_from_slice` into the caller's buffer is the second (contract of
the ObjectDb trait). Target: exactly 2 copies per uncached read, 1
per cache hit. State the achieved counts.

## F8 [MED] read_many's `max_total_bytes` no longer short-circuits
`try_find_many` materialises the whole batch before the cap check.
FIX: pass the remaining cap into the batch path (a running total
checked as each object is decoded — a `ReadManyBudget` arg or reuse
Budget's charge path with a per-call ceiling) so the batch stops at
the first object that would exceed it and returns `:result_too_large`
without buffering the rest. Applies to local/static too via the
default. Test: six oids, `max_total_bytes: 1` → error, backend called
at most once, and (for the static store) fewer objects decoded than
requested — assert via a counting store double if needed.

## F9 [MED] Dead `snapshot_open` DirtyCpu NIF is a landmine
Unreachable from lib/ but on a provider store it would OwnedEnv-send
from a dirty scheduler → hard panic in release. FIX: DELETE the NIF and
its `Gitility.Native` stub; `job_submit_snapshot_open` is the only
path. Also promote the `debug_assert!(!is_scheduler_thread())` at the
transport send site to a runtime check that returns
`Err(:backend_error "provider request from a scheduler thread — Gitility
bug")` instead of proceeding — a wrong-thread send must never panic the
VM in release.

## F10 [MED] `prefetch/2` is public API nothing calls
DECISION: wire ONE real call site now so the contract isn't dead:
recursive `list_tree` walks issue a Prefetch for the child tree oids of
each visited tree (the classic tree-walk prefetch), and `read_many`
prefetches nothing (it already batches). Bounded: at most one prefetch
per visited tree, only when the store reports it supports prefetch
(provider), no-op for local/static. Test: recursive walk over a
provider backend records ≥1 prefetch callback with the child tree oids.

## LOW batch
- `provider/supervisor.ex` bare `receive` with no `after` → add a bounded
  timeout (start_link returns `{:error, :timeout}`).
- `ensure_alive → fail_all → insert` race: check the alive flag AFTER
  inserting into the pending table (insert-then-check, fail-fast if
  dead) — closes the window.
- Watchdog rewatch gap: on rewatch, if the Provider is already dead, call
  provider_failed immediately.
- Dedup oids in `try_find_many` before batching (backend never sees
  repeats).
- `log_backend_error`: `inspect(reason, limit: 50, printable_limit: 256)`.
- Conformance kit: make the `read_headers` case skip (with an explicit
  `:skipped` reason in the test name/log) rather than pass tautologically
  when the backend doesn't export it; same for prefetch — assert the
  callback is invoked when exported, skip when not.

## Missing tests to add (all remote)
Conformance kit runs a generated case suite against a broken backend
(not just validate_batch); duplicate reply end-to-end via a test hook;
provider death with 5 concurrent waiters → all fail :provider_down; the
negative-cache TTL expiry; `{Gitility.ODB, opts}` under a Supervisor +
`handle/1`; stray-message robustness; clean-shutdown wakeup;
`:object_too_large` for an oversized provider object; latch-based
(deterministic) concurrency proof replacing the sleep-based one; a loom
model for the provider rendezvous (reply vs cancel vs fail_all — one
terminal outcome, no lost wakeup, no double-take).

## Hygiene
cargo fmt/clippy (both cfgs)/test; loom (incl. the new model); spawn
guard (no new sites); REMOTE sync/mix/soak green; remote `mix docs
--warnings-as-errors`; `mix format`. No commit. Print per-finding
summary, copy counts (F7), remote summary lines.
