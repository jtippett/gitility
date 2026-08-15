# Milestone 2c — provider (callback) ODB

Implementation spec, dispatched to the implementing agent verbatim. Lives
in the repo (not scratch) so it survives sessions and is reviewable
alongside the code it produced.

## Standing rules (constrain HOW you work; the task follows)

- Incident context: `docs/reports/2026-08-14-kernel-panic-thread-leak.md`
  (read once). **Never load the NIF into a BEAM on this Mac** — no
  `mix test` / `iex` / `mix run` locally. All BEAM verification runs on
  the remote Linux sprite: `bash scripts/remote-test.sh sync` after
  edits, then `bash scripts/remote-test.sh mix` (and `soak`); ad-hoc
  probes via
  `sprite exec -- bash -lc 'export PATH="$HOME/.cargo/bin:$HOME/pinned-git/bin:$PATH" GITILITY_BUILD=1; cd ~/gitility && mix run -e "..."'`.
  `cargo` commands run locally.
- Any new native OS thread must go through the thread budget and be
  added deliberately to `scripts/check-thread-spawns.sh` (CI-enforced).
  This design needs **no** new threads: requests originate on existing
  worker threads; replies arrive as NIF calls.
- Do not commit; the orchestrator commits.

## The task

Implement the provider ODB: Git objects served by Elixir code with no
filesystem. Read first: `docs/plans/2026-08-14-gitility-design.md` —
"Elixir ODB backend behaviour", the provider protocol invariants list
("`Gitility.ODB.Provider` owns dispatch…" through the negative-cache
bullet), "Object verification", "Backpressure", Milestone 2 steps 3–4.
Then: `lib/gitility/odb/backend.ex` (the behaviour is FROZEN — implement
against it exactly), `lib/gitility/odb.ex` `start_link` docs (the
options are the contract), the committed M2a/M2b runtime + NIF layer
(`crates/gitility-core/src/runtime/`, `native/gitility/src/lib.rs` —
reuse its OwnedEnv/monitor patterns and DTO helpers), and
`crates/gitility-core/src/odb.rs` (`ObjectDb` is the seam `ProviderOdb`
implements — every query then works unchanged).

Write surface: `crates/gitility-core/`, `native/gitility/`, `lib/`,
`test/`, root `Cargo.lock`.

### Architecture (final — implement, don't re-litigate)

**Core: `ProviderOdb` (gitility-core, BEAM-free).** An `ObjectDb` impl
generic over a transport trait the NIF layer implements:

- `trait ProviderTransport: Send + Sync { fn request(&self, req:
  ProviderRequest) -> Result<(), Error>; }` — fires the request toward
  Elixir; the reply arrives via the request's channel. Core defines
  `ProviderRequest { id: u64, kind: Header | Object | Prefetch, oids:
  Vec<Oid>, reply: ReplySlot, deadline }` (cancel visibility via the
  `Budget` the caller passes).
- Each request owns a rendezvous: `ReplySlot` is the receiving half;
  the sending half lives in a `PendingTable`
  (`Mutex<BTreeMap<u64, ReplySender>>`) owned by the `ProviderOdb`, so
  late/duplicate replies and provider death are handled: `reply(id,
  payload)` takes the sender out of the table (take-once → duplicates
  are harmless no-ops); `fail_all(error)` drains the table waking every
  waiter (provider death). Channel: `std::sync::mpsc` (`SyncSender(1)`)
  or a Mutex+Condvar slot — but the WAIT must be sliced: `recv_timeout`
  in ≤50 ms slices, calling `budget.check()` each slice, so job
  cancellation and deadlines interrupt provider waits promptly (design
  safeguard: "make caller death and timeout interrupt native work").
  Total wait bounded by min(budget deadline remaining, `request_timeout`
  from the open options).
- `try_find`/`try_header`: consult caches first (below); on miss charge
  `Budget::charge_provider_request`, and on reply charge provider
  bytes; send ONE request per native lookup (a per-object query sends
  singleton batches; `read_many` jobs and prefetch send real batches).
  Cross-job coalescing is deliberately NOT in v1 — document that the
  batch-first BACKEND contract still holds (every callback receives a
  list) and coalescing is a compatible future optimisation.
- Reply validation IN CORE before anything trusts it: only expected
  oids, duplicates rejected, per-object and total byte caps enforced
  (reply bytes charged and capped BEFORE buffering — "replies are
  capped before copying into Rust-owned memory"), then `verify()` every
  object (verify: :always — same path as every other store; hash
  mismatch → that object's read fails with `:hash_mismatch`).
  `:not_found` is a per-object result; a backend `{:error, reason}`
  fails the REQUEST with `:backend_error` retryable true and a
  SANITISED message ("provider callback failed" — never the backend's
  reason term; the Elixir side logs the real reason).
- Caches (native, per-store, all bounded, all optional per the `cache:`
  option): verified-object bytes LRU (`object_bytes` cap), header LRU
  (`header_entries` cap), negative cache with TTL (`negative_ttl` ms;
  an entry suppresses re-requests until expiry; `refresh` clears it).
  A small in-core LRU (~100 lines) behind a `Mutex` — no new dep.

**NIF layer.** `ProviderTransport` impl: `request()` builds a
`RequestResource` (rustler resource holding the request id + a weak
handle to the store's `PendingTable`) and OwnedEnv-sends
`{:gitility_provider_request, req_resource_term, kind_atom,
[oid_binaries]}` to the provider pid — from worker threads this is the
safe direct send (workers are Rust-owned; the M2b pump is NOT needed for
requests — document why: requests originate on worker threads only;
`debug_assert!(!is_scheduler_thread())`). NIFs: `provider_reply(
req_resource, reply_term)` — decodes `{:ok, results} | {:error, _}`,
validates sizes cheaply, hands to core `reply(id, …)`; DirtyCpu (copies
object bytes). `provider_failed(store_resource)` → core
`fail_all(provider_down)`. `provider_store_new(hash, opts)` → the store
resource the ODB handle carries. Reuse M1c/M2b DTO conventions.
`StoreImpl` gains a `Provider` variant; keep the enum + `as_dyn`
pattern.

**Elixir: `Gitility.ODB.Provider` + `ODB.start_link/1` go live.**
`ODB.start_link/1` starts a small supervision tree: a Supervisor owning
the Provider GenServer, a `Task.Supervisor`, and a `Gitility.ODB.Watchdog`
(monitors the Provider pid; calls `provider_failed` on DOWN — covers
kill -9 where `terminate` never runs). Provider GenServer: receives
`:gitility_provider_request` messages, dispatches each to a supervised
Task (up to `concurrency`; beyond it, requests queue FIFO in the
GenServer without blocking its loop), the task runs the backend callback
(`read_many` / `read_headers` with the documented fallback to
`read_many` when `read_headers` isn't exported / `prefetch`
fire-and-forget), then calls `provider_reply`. `backend.init/1` runs at
`start_link` (init error → `start_link` `{:error, …}`); `terminate`
calls `backend.terminate` if exported. The ODB handle (kind:
`:provider`) is bound to the process instance: after provider death the
handle's reads fail `:provider_down` permanently — supervision restarts
create a fresh handle via `start_link`; document this plainly.
- `verify:` option: `:always` only (anything else `:invalid_argument`,
  matching `from_objects`).
- Budget: `max_provider_requests` / `max_provider_bytes` enforced in
  core charging (`BudgetLimits` already has both — wire them; complete
  the provider charge paths in `budget.rs` if inert).
- `Gitility.ODB.refresh/1`: for provider stores clears the native
  negative cache AND calls the backend's `refresh` callback if exported;
  `:unsupported_operation` for non-provider stores in this milestone.
- Queries: NO new public query API — `Snapshot.open`/`list_tree`/
  `read_file`/`peel`/`ODB.read`/`header`/`read_many` all just work over a
  provider handle because `ProviderOdb` implements `ObjectDb` and jobs
  run on the M2b substrate unchanged.

**Conformance kit (public).** `Gitility.ODB.Backend.Conformance`: a
`__using__` macro generating an ExUnit case that exercises ANY backend
implementation against the behaviour contract: batch completeness (every
oid answered), `:not_found` vs error distinction, concurrent callback
safety (spawns `concurrency` parallel batches), `read_headers` fallback
equivalence, prefetch tolerance, object round-trip verification. Used by
our own test backend AND documented for consumers (moduledoc with a
usage example); `mix docs` must render it.

### Tests (all BEAM tests run remotely)

- Parity: a provider backend serving sha1-basic's objects (extracted
  once via the local store in setup); then the SAME shape assertions as
  the fixture suites — full recursive `list_tree` equals the local-store
  listing byte-for-byte; `read_file` byte parity on ≥5 files incl. the
  0xFF path and the binary blob; snapshot open + peel. (Local-store
  equality is the oracle here — say so in a comment.)
- Concurrency proof (design exit criterion): a backend recording
  in-flight callback count — `concurrency: 4` with ≥4 parallel jobs →
  max observed in-flight > 1; `concurrency: 1` → never > 1.
- Provider death: kill the provider mid-query → in-flight queries fail
  `:provider_down` (retryable), jobs terminal, no hang; subsequent reads
  on the handle fail `:provider_down`.
- Hung backend: a callback that sleeps forever → job `timeout_ms: 200`
  completes `:timeout` within ~1 s (the sliced wait works); cancel
  during a provider wait returns `:cancelled` promptly (< ~500 ms).
- `request_timeout`: backend slower than it → the mapping you implement
  (pick, document, test).
- Verification: tampered bytes → `:hash_mismatch`, not cached;
  unexpected extra oid in a reply → rejected (document whether the
  request still succeeds for expected oids); duplicate reply → no-op.
- Budgets: `max_provider_requests: 2` on a walk needing more →
  `:budget_exceeded` naming the limit; `max_provider_bytes` likewise.
- Negative cache: miss → backend called once; second read within TTL →
  no second callback; after `refresh/1` → backend called again.
- Conformance kit runs against the test backend; a deliberately broken
  backend (omits an oid) fails it.
- Sanitisation: backend `{:error, %{password: "hunter2"}}` → the query
  error message contains neither "hunter2" nor inspect artefacts.

### Hygiene

`cargo fmt`/`clippy -D warnings` (both cfgs)/`test --workspace`; loom
suite green; spawn guard green (no new sites); REMOTE:
`remote-test.sh sync mix soak` all green; `mix docs
--warnings-as-errors` (run remotely too). No commit. Print: core/NIF/
Elixir change summary, new pins (expect none), test counts, remote
summary lines, ambiguities resolved.
