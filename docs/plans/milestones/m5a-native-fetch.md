# M5a — Native fetch (`Gitility.Fetch`)

Status: SPEC v8 (2026-08-20; v7 froze after codex review rounds 1–6;
v8 adds three rulings from first sprite contact). Scope + feasibility
background: `docs/plans/2026-08-20-native-fetch-scope.md`.

## v8 rulings (first-BEAM-contact findings, 2026-08-20)

1. **Implicit tag auto-following is DISABLED** (`Tags::None` on the
   remote). gix defaults to git's tag auto-following, which made an
   exact PR-refspec fetch also create `refs/tags/*` — wrong for
   mirror semantics. Tags fetch only via explicit refspecs; moduledoc
   states it.
2. **Refspec destination conflicts are `:invalid_argument`.** Two
   refspecs mapping different sources to the SAME destination (e.g.
   `refs/heads/*:refs/remotes/origin/*` + `refs/archive/*:refs/
   remotes/origin/*` with `shared` in both) are refused by gix (and by
   git itself) at ref-map validation. Classify that refusal as
   `:invalid_argument` naming the conflicting destination — it is
   caller input, not the network. Matrix's "overlapping destinations"
   rows must use NON-conflicting overlaps (exact-under-wildcard),
   plus one row asserting the typed conflict error.
3. **SHA-256 destinations**: gix 0.86 cannot open
   `extensions.objectFormat=sha256` repositories at all
   (`open::Error::Config` on that key). Classify that exact failure as
   `:unsupported_hash` (honest message: the destination's object
   format is unsupported by native fetch), never "not a Git
   repository".

Also binding (root cause of the 401 failures): gix's `prepare::Error`
and `ref_map::Error` wrap inner errors with `#[error(transparent)]`,
which forwards BOTH Display and `source()` — the inner
`handshake::Error`/transport types are UNREACHABLE by
source-chain downcasting. All error classification in fetch.rs must
match gix's typed variants STRUCTURALLY (chain-walk downcasts only as
a fallback), and the 401 regression test must exercise a REAL 401 HTTP
response, not a synthetic error chain.

Deliverable: `Gitility.Fetch.fetch/4` — client-side smart-HTTP git
fetch into a local bare repository, over gix 0.86.0, statically-linked
rustls, running as budgeted jobs on a dedicated 2-worker runtime.
This is gitility's first write path into a real git directory; the
query API stays read-only and the module docs must say so.

## 0. Ground rules (unchanged, load-bearing)

- NO BEAM on the dev Mac. All mix verification via
  `./scripts/remote-test.sh` on the sprite. Cargo tests run locally.
- Thread discipline: NO new thread-spawn sites in OUR code. The fetch
  runtime is a second instance of the existing `Gitility.Runtime` —
  same `runtime_start()` NIF, same two allowlisted spawn sites.
  `scripts/check-thread-spawns.sh` must pass UNCHANGED.
- KNOWN AND BUDGETED dependency threads (codex round 2, verified in
  gix-transport AND the reqwest/hyper-util sources): each in-flight
  fetch connection carries up to THREE short-lived dependency threads —
  gix's transport worker (`.../http/reqwest/remote.rs:50`), reqwest's
  blocking-client internal runtime thread
  (`reqwest .../blocking/client.rs:1408`), and possibly a tokio
  blocking-pool DNS thread (hyper-util getaddrinfo). Teardown is
  ASYNCHRONOUS: gix does not join its worker on drop (its only join is
  failure recovery), and pool threads linger briefly. Therefore the
  budget accounting is honest, not exact: the fetch task reserves
  THREE slots from `thread_budget::global()` before constructing the
  connection and releases them when the connection is dropped, with a
  documented caveat that release is advisory (the threads exit shortly
  after, not provably before — the budget bounds steady state, and at
  512 total the slack is irrelevant). Reservation failure → `Busy`
  (retryable). Numbers for §9: 3 resident (2 workers + pump); during 2
  concurrent fetches up to ~9 briefly (3 resident + 2×3 transient),
  draining back to 3 within a grace window after completion. The curl
  backend is NOT an escape (it spawns a worker too, and drags libcurl
  into the static build). If you find yourself needing `thread::spawn`
  anywhere in OUR code, stop and flag it — that is a design
  escalation.
- gix must not spawn any OTHER threads. See §2 feature audit
  (single-threaded pack indexing).
- The authorization value is radioactive: it must never appear in any
  `Debug`/`Display` impl, error message, log line, native panic/stderr
  output, Elixir error struct, result struct, or crash report. See §6.

## 1. Elixir API

New module `lib/gitility/fetch.ex`:

```elixir
@spec fetch(Path.t(), String.t(), [String.t()], keyword()) ::
        {:ok, Gitility.Fetch.Result.t()} | {:error, Gitility.Error.t()}
def fetch(dest, url, refspecs, opts \\ [])
```

- `dest` — path to a bare repository directory. Nonexistent (or
  existing-but-empty) → created and initialized bare SHA-1 before
  fetching. Existing non-repository or non-bare repository (`is_bare()`
  checked after open) → `:invalid_argument`. Object-hash mismatch with
  the remote → `:unsupported_hash` (test: SHA-256 local dest vs SHA-1
  remote).
- `url` — `https://` or `http://` only (http exists for the test
  fixture; docs say production is https). Everything else →
  `:invalid_argument` naming accepted schemes. Validated caller-side.
  Rust-side backstop: see §4 step 2 (insteadOf rewrites must not be
  able to smuggle in another transport).
- `refspecs` — non-empty list of fetch refspec strings. Parsed at
  submit via gix-refspec; invalid → `:invalid_argument` naming the
  refspec. Every refspec MUST have a destination side (source-only
  refspecs like `"refs/heads/main"` → `:invalid_argument`; rationale:
  gix leaves the pack `.keep` in place when no ref edit occurs, and a
  destination-less fetch has no observable result in our model).

Options:

| opt | default | meaning |
|---|---|---|
| `credentials:` | nil | provider fun/MFA, §5 |
| `authorization:` | nil | static header value; sugar for a constant provider. Mutually exclusive with `credentials:`. |
| `prune: bool` | false | §4 step 6 |
| `timeout_ms:` | 120_000 | THE single user-facing time bound, §3 |
| `retry_unauthorized: bool` | false | §5; `:invalid_argument` without `credentials:` |
| `runtime:` | the fetch default | an explicit `Gitility.Runtime` pid/name for user-supervised runtimes. No `:default` atom — pid/name or absent. |

There are NO separate connect/read timeout options (codex round 1:
gix hardcodes a 20s connect timeout before any configuration hook runs,
and reqwest's request timeout is a total deadline, not per-read — so
independent knobs would be a lie). Document the fixed 20s connect
timeout in the moduledoc.

Caller-side validation must be raise-free end to end: no
`Keyword.validate!`; unknown opts, wrong types, non-positive or
> 2^32 timeouts, empty refspec list, oversized refspecs (>4096 bytes),
non-UTF-8 strings, and invalid authorization header values (any CR/LF
or non-visible-ASCII byte → `:invalid_argument`; gix silently DROPS
malformed extra headers, which would otherwise masquerade as an
authentication failure) all return error tuples before any lock,
provider call, or NIF submission.

Result struct `Gitility.Fetch.Result`
(`lib/gitility/types/fetch_result.ex`, existing types pattern):

```elixir
%Gitility.Fetch.Result{
  updated_refs: [%{name: String.t(), action: :created | :fast_forward | :forced,
                   old_oid: String.t() | nil, new_oid: String.t()}],
  rejected_refs: [%{name: String.t(), reason: atom()}],  # e.g. :non_fast_forward, :tag_update
  pruned_refs: [String.t()],
  remote_ref_count: non_neg_integer(),
  pack_received: boolean()
}
```

All lists sorted by ref name (byte order); OIDs lowercase hex.
`updated_refs` derives from ZIPPING the ref-map mappings with the
update outcomes and filtering by edit `Mode` — ONLY `New`,
`FastForward`, `Forced` count (gix emits a no-change assertion edit for
up-to-date refs; mapping raw edits would report them as updates and
break idempotence — codex round 1). Rejections
(`RejectedNonFastForward`, `RejectedTagUpdate`, etc.) do NOT fail the
fetch; they land in `rejected_refs` with a mapped reason atom so a
non-forced fetch that couldn't apply is visible, never silent.

Behavioral contract (each row is a test):
- Empty remote + wildcard refspecs → `{:ok, %Result{remote_ref_count: 0,
  updated_refs: [], pack_received: false}}`. NOT an error.
- Exact-name refspec with no matching remote ref → `:ref_not_found`,
  message includes the refspec — INCLUDING in mixed requests. gix's
  `Error::NoMapping` fires only when NO refspec matched at all (codex
  round 2: one wildcard match + one missing exact ref would silently
  succeed), so the task must check the prepared ref map itself: after
  `prepare_fetch`, every exact (non-glob) refspec source must appear in
  the mappings; a missing one aborts with `RefNotFound` BEFORE any
  transfer. Test: mixed wildcard + missing exact refspec →
  `:ref_not_found`, no ref updates applied.
- Up-to-date re-fetch → ok, empty `updated_refs`, `pack_received:
  false`. Idempotent.
- Non-forced refspec against a rewound remote branch → ok with the ref
  in `rejected_refs`, local ref unchanged (parity: git refuses the same
  update).
- Ref-atomicity contract, stated honestly: transport, negotiation, and
  pack-verification failures leave refs untouched (they precede gix's
  ref transaction inside `receive()`). `:timeout`/`:cancelled` returns
  MAY leave the fetch committed (cancellation is cooperative; the
  commit point is inside `receive()`) — the operation is idempotent and
  a rerun converges; the moduledoc says exactly this. POST-COMMIT
  cleanup failures return the dedicated code `:cleanup_failed` — the
  code ITSELF means exactly "the fetch portion committed; only
  post-fetch cleanup failed" (no structured-detail plumbing; the core
  Error has nowhere to carry a free-form flag — codex round 2; whether
  a rerun converges is per-case, below — codex round 5).
  It covers exactly three cases, distinguished in the message: the
  prune transaction failing (§4 step 6), OUR keep-file deletion
  failing (below), and gix's OWN `RemovePackKeepFile` error — gix
  commits refs BEFORE its automatic keep removal, so that error too
  arrives post-commit (codex round 3). Retryability is per-case
  (codex round 4: a rerun does NOT converge for keep failures — the
  rerun receives no new pack, so there is no keep path to re-delete):
  prune failure → retryable: true (rerun with prune converges);
  either keep-deletion failure → retryable: false, the message names
  the leftover `.keep` path, and the moduledoc tells the caller the
  file is safe to delete manually.
- `.keep` cleanup, exact condition (codex round 2): gix removes the
  keep file ITSELF whenever ref edits exist or the pack was empty — a
  keep path still present in the outcome therefore means a nonempty
  pack with NO ref edits (e.g. an all-rejected fetch), exactly the case
  that would otherwise leave a permanent GC-blocking `.keep`. Whenever
  the outcome carries a keep path, delete it unconditionally before
  returning; deletion failure → `:cleanup_failed`. Test (codex round
  3: a rewind to an already-local ancestor transfers no pack and
  vacuously passes): the all-rejected fetch must receive a DIVERGENT,
  previously-unseen remote commit — assert `pack_received: true` FIRST,
  then that no `.keep` remains in `objects/pack`.

## 2. Cargo wiring + gix feature audit + MSRV

In `crates/gitility-core/Cargo.toml`:

```toml
gix = { version = "=0.86.0", default-features = false, features = [
  "blocking-network-client",
  "blocking-http-transport-reqwest-rust-tls",
  "sha1",                     # REQUIRED: gix::create reaches unreachable!() without a
                              # top-level hash feature (create.rs:140); transitive
                              # gix-hash/sha1 does NOT set cfg(feature="sha1") on gix
] }
```

plus whatever minimal additional gix features compilation requires
(justify each in the commit message). HARD CONSTRAINTS: resolved
features must NOT include gix's `parallel`, `max-control`,
`max-performance-safe`, or `max-performance` (they forward
`gix-pack/parallel` = invisible indexing threads). The existing
`[patch.crates-io] gix-diff` entry must keep applying to gix's
transitive gix-diff — verify Cargo.lock holds exactly one gix-diff,
the vendored one.

MSRV: gix 0.86/gix-refspec require Rust 1.85; the workspace declares
1.82 (root Cargo.toml `rust-version`). Bump to 1.85 and mention in the
CHANGELOG (source-build consumers).

New guard `scripts/check-gix-features.sh`, run in CI AFTER Rust setup
and dependency resolution (the existing spawn guard runs pre-setup and
stays where it is) and added to the sprite's rust stage in
`scripts/remote-test.sh`: assert via `cargo tree -e normal,build
--target all` (NOT an unqualified graph — criterion, a dev-dep,
already pulls crossbeam-deque) that `gix-pack` is compiled WITHOUT its
`parallel` feature and that `crossbeam-deque` does not appear on
normal/build edges. Comment the rationale: the spawn guard scans our
sources, not dependencies.

Precompiled artifact note: rustls/reqwest adds ~2–4 MB per target; no
release.yml changes expected.

## 3. Runtime placement, cancellation, timeouts

- Default fetch runtime: lazily-started second `Gitility.Runtime`
  named `Gitility.FetchRuntime`, `workers: 2`, `max_queue: 32`,
  `max_jobs_per_owner: 4` — same Supervisor.start_child +
  persistent_term mechanics as `Runtime.default/0`, factored to share
  code. Isolation is by construction: only `Gitility.Fetch` submits
  fetch jobs, and it resolves `opts[:runtime]` or the fetch default.
  Sharing a runtime with queries via an explicit `runtime:` is allowed
  and documented as self-inflicted.
- `job_submit_fetch(runtime, request_map, limits_map)` — THREE
  arguments. The standard submission helper requires a `LimitsMap`
  (admission deadline + max_result_bytes come from it; `await_sync`
  only awaits, it does not create the native deadline — codex round 1).
  `Gitility.Fetch` builds a full limits map from `timeout_ms` +
  defaulted result-size limits, same encoding path as queries
  (`NativeSupport.limits_map!`).
- Cancellation: the task passes `budget.cancel_flag().as_ref()` to gix
  as `should_interrupt` — the flag ALREADY EXISTS on the budget every
  `JobTask` receives (`crates/gitility-core/src/budget.rs:131`). Do NOT
  change the `JobTask` signature, do NOT add a second flag or context
  type.
- Single time bound: `timeout_ms` is ONE ABSOLUTE WHOLE-CALL deadline
  (codex round 3: per-stage budgets silently extend the bound across
  provider calls and the auth retry). `fetch/4` records a monotonic
  deadline at entry (`System.monotonic_time(:millisecond) + timeout_ms`)
  and every subsequent stage receives the REMAINING time: each provider
  invocation (§5), each attempt's limits map (native job deadline —
  which becomes the Budget's submission-time deadline, the SOLE
  deadline source on the native side), and each `await_sync` await.
  Native transport timeouts derive from that same Budget deadline: the
  reqwest `configure_request` hook — what unwedges a fetch worker from
  a fully stalled socket, since the cooperative flag can't preempt a
  blocked read — recomputes remaining time on EVERY invocation from
  the job BUDGET's submission-time deadline (the Budget computes it at
  submit, runtime/mod.rs ~689; add a read accessor if one doesn't
  exist). NOT a fresh `Instant` at task start (queue residence would
  extend the bound — codex round 5), NOT a captured fixed duration
  (each of the fetch's multiple HTTP requests — info/refs GET +
  upload-pack POST — would restart it — codex round 4), and NOT a
  request-map field (a second source is a route back to those bugs —
  codex round 6; FetchRequestMap carries no timeout). Remaining ≤ 0 BEFORE a stage starts →
  `:timeout` without running it; a PROVIDER that consumes the
  remaining time returns `:credentials_unavailable` (the provider was
  the stage that spent it — this is the one deliberate exception to
  the `:timeout` rule, stated here so §5 and the matrix don't
  contradict this section). Consequence to state in docs
  and assert in tests: a stalled server produces a typed error
  (`:network_error` or `:timeout`, both acceptable) within `timeout_ms`
  plus margin — including on the retry path — and the worker is
  reusable afterward.
- `configure_request` mechanics, spelled out because the types are
  fiddly: `gix::remote::Connection::set_transport_options(Box<dyn Any>)`
  receives a `Box<gix_transport::client::http::Options>`; that struct's
  `backend: Option<Arc<Mutex<dyn Any + Send + Sync>>>` field carries a
  `gix_transport::client::http::reqwest::Options { configure_request:
  Some(Box::new(|req: &mut reqwest::blocking::Request| { *req.timeout_mut() =
  Some(remaining); })) }`. Both the outer Options (with
  `extra_headers`) and the nested backend Options are needed.
- REDIRECT CONSEQUENCE, accepted for v1 (codex round 2): gix treats a
  configured request hook (and configured headers) as a reason to
  select `RejectConfiguredHeaders` redirect policy — HTTP redirects
  (renamed/moved repos) are REFUSED, for every fetch, since the hook is
  always installed. This is the right trade: authenticated fetches
  must not chase redirects with an Authorization header anyway, and
  the timeout guarantee matters more than anonymous redirect-following.
  Map the redirect refusal to `NetworkError` with a message stating
  that redirects are not followed (gix's refusal error is a constant —
  it DISCARDS the target URL, so do not promise to name it; codex
  round 3); document "redirects are not followed" in the moduledoc.
  Fixture gains a `redirect: location` mode (301 + Location header);
  matrix asserts `:network_error` on it.

## 4. Fetch task semantics (Rust, `crates/gitility-core/src/fetch.rs` + NIF glue)

`FetchRequestMap` (NifMap): `dest`, `url`, `refspecs: Vec<String>`,
`authorization: Option<String>`, `prune: bool`. NO timeout field —
the ONLY deadline source is the job Budget's submission-time deadline
(§3); the transport hook reads it from the budget, never from the
request (codex round 6: a second source is a route back to the
task-start-duration bug).

Task flow (all on the fetch worker thread):
1. Open or init dest — EXACT APIs (codex round 1: the convenience fns
   don't take options): open with `gix::open_opts(path,
   gix::open::Options::isolated())`; if absent/empty, init with
   `gix::ThreadSafeRepository::init_opts(path, gix::create::Kind::Bare,
   gix::create::Options::default(), gix::open::Options::isolated())`.
   After open: `repo.is_bare()` must be true, else `InvalidArgument`.
   gix has NO init lock (emptiness check then file creation) —
   same-VM serialization is provided by the §5 single-flight lock;
   cross-process races on the same dest are documented out of scope.
2. `repo.remote_at_without_url_rewrite(url)` — NOT `remote_at`:
   isolated open still reads REPO-LOCAL config, and `url.*.insteadOf`
   rewrite rules in a hostile dest could rewrite our validated HTTPS
   URL to ssh/file transport (subprocesses). After construction, assert
   the effective URL scheme is Http/Https, else `InvalidArgument`.
   Then `.with_refspecs(refspecs, Direction::Fetch)`.
3. `connect(Fetch)`, then in this exact order:
   `set_credentials(|_| Ok(None))` (MANDATORY — disarms the
   git-credential subprocess cascade; a 401 becomes a typed error,
   never a helper invocation), then `set_transport_options(...)` per §3
   (extra_headers with the authorization value if present + backend
   timeout hook). Reserve the transport-thread budget slots (§0, three)
   before connect; release on connection drop via a guard.
4. `prepare_fetch(...)`; check the prepared ref map for the
   missing-exact-refspec rule (§1) BEFORE transfer; then
   `receive(NoProgress, should_interrupt)`.
5. Map outcome per §1: zip mappings×updates, filter Modes, collect
   rejections, `remote_ref_count` from the ref map's remote refs,
   `pack_received` from `Status::Change` vs `NoPackReceived`; delete
   any reported `.keep` unconditionally (§1 — a reported keep means
   pack-without-edits; gix already removed it in every other case).
6. Prune (only if `prune: true`): use gix-refspec's
   `MatchGroup::match_rhs()` reverse matching (NOT prefix
   approximation — wrong for wildcard suffixes, overlapping
   destinations, exact-under-wildcard) to map each local ref in the
   wildcard refspecs' destination space back to its remote name; delete
   (one gix-ref transaction, previous-value asserted) every local ref
   whose remote counterpart is absent from the advertised set. Exact
   refspec destinations are protected; symbolic refs never touched;
   dedup; output sorted. Failure here after a committed fetch →
   **CleanupFailed** (§1).

New `JobOutput::Fetch(...)` variant: handle EVERY exhaustive site —
result encoding AND result size accounting in the NIF
(`native/gitility/src/lib.rs` ~3450, ~3814) — Rust won't compile
otherwise, but the spec says it so nobody "fixes" it by weakening the
match. `NativeSupport.job_payload/1` gets an explicit
`%Gitility.Fetch.Result{}` construction (struct, not raw map, to the
caller). Add the `Gitility.Native.job_submit_fetch/3` stub.

Error mapping (Rust → ErrorCode). New codes in **bold** — for each:
enum variant + `all()` + `as_str()` + Elixir `@codes`, AND the three
tests that hard-code the registry: the Rust exhaustive-index test
(`error.rs` ~302), the Elixir list test (`test/error_test.exs` ~6), and
the cross-language comparison in `milestone_1c_query_test.exs` ~431 —
which currently asserts SUBSET equality and must be tightened to exact
set equality as part of this milestone.
- HTTP 401 → **AuthenticationFailed**, retryable: false. CORRECT
  DETECTION (codex round 2): with `set_credentials(|_| Ok(None))`, the
  transport's io `PermissionDenied` is CONSUMED by gix's handshake and
  resurfaces as `handshake::Error` credentials variants (e.g.
  `EmptyCredentials`) — match those in the fetch error chain as the
  primary 401 signal, with io PermissionDenied as fallback. Message
  must not echo the header. 403 and other statuses become opaque
  `Other` errors → **NetworkError**; do not promise 401/403
  equivalence anywhere.
- Connect/read/TLS/DNS/stall/truncation failures → **NetworkError**,
  retryable: true. Phase/context goes in the MESSAGE text (the core
  Error struct has no free-form details field; do not add one for
  this).
- gix `Error::NoMapping` → existing `RefNotFound`.
- Hash mismatch → existing `UnsupportedHash`.
- Interrupt via cancel → existing `Cancelled`.
- Pack/index verification failures → existing checksums/malformed
  codes.
- **CleanupFailed** — post-commit cleanup failed after a committed
  fetch: prune transaction, our keep-file deletion, or gix's own
  `RemovePackKeepFile` (§1); retryable per-case (§1: true for prune,
  false for keep); the message names which cleanup failed.
- **CredentialsUnavailable** — constructed Elixir-side only (§5) but
  present in both registries so exact-equality sync holds.

Four new codes total: AuthenticationFailed, NetworkError,
CleanupFailed, CredentialsUnavailable.

## 5. Credential provider + single-flight (Elixir-side)

Provider:
- `credentials:` accepts a 1-arity fun or `{m, f, args}` (called
  `apply(m, f, args ++ [context])`). Context v1: `%{url:, host:,
  attempt: 1 | 2}`. Returns `{:ok, %{authorization: binary}}` or
  `{:error, term}`.
- Invoked under a TIME BOUND (codex round 2: an unbounded provider
  would hold the destination lease forever and void the single
  time-bound promise): run in a `Task` whose BODY wraps the provider
  call in `try/rescue/catch` and returns a tagged tuple — the task
  itself must never exit abnormally (codex round 3: `Task.async` links,
  so an uncaught provider raise would kill the CALLER and trip the
  lease-death path instead of mapping to an error). The caller does
  `Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill)`
  with the whole-call remaining time (§3). Timeout, rescue/catch, or
  bad return → `{:error, %Error{code: :credentials_unavailable}}`
  whose `cause` carries ONLY the exception module, `:bad_return`, or
  `:timeout` — never the term itself (a provider error embedding the
  token must not leak; test this). The returned authorization value
  passes the same header validation as the static opt.
- `retry_unauthorized: true`: on `:authentication_failed`, invoke the
  provider once with `attempt: 2` (same remaining-time bound), submit
  ONE fresh job under the SAME lock lease. Second 401 → the error.
  Never loops.

Single-flight lock — `Gitility.Fetch.Locks`:
- An EAGER, permanent GenServer child of `Gitility.Supervisor`
  (application start — the supervisor's children list is currently
  empty; this is its first entry). Eager kills the whole class of
  lazy-start races codex flagged (explicit user runtime used before the
  default ever starts; persistent_term fast path skipping recreation).
  It owns a monitor-based lease table (state map is fine; ETS not
  required at this scale).
- Key: `Path.expand(dest)`. Known limitation, documented: symlinked
  aliases of the same directory defeat the key (we do not resolve
  symlinks; fix-forward if it ever bites — the failure mode is two
  concurrent fetches, which git itself tolerates).
- Lease lifecycle v3 (codex rounds 2–3). A lease has three components:
  the HOLDER (caller pid, monitored), a set of ATTACHED JOBS, and a
  PENDING-SUBMISSION flag. Release condition: (holder has released OR
  holder is DOWN) AND pending-submission is clear AND every attached
  job is terminal. Rules:
  - `acquire(key)` before provider/submit. Around EVERY submission
    (attempt 1 AND attempt 2), the caller brackets:
    `pending_submit(key)` → NIF submit → on submit ERROR (or raise
    from the submit call itself) `submission_failed(key)`; on
    `{:ok, job}` `attach(key, job)` IMMEDIATELY. The two clearing
    transitions are asymmetric BY DESIGN (codex round 5: a blanket
    `try/after` clear would, on a raise after `{:ok, job}` but before
    attach, leave a LIVE job neither pending nor attached — the lease
    could free under a running fetch). Once a job exists, attach is
    the only clearing transition: if anything raises between submit-ok
    and attach, the pending flag STAYS SET (holder-death grace covers
    a dead caller; a live caller's `fetch/4` rescues, attaches the
    job, RELEASES the lease, then propagates — without the release, an
    upstream caller catching the exception would leave a live holder
    and the lease pinned forever; the released-holder + attached-job
    lease then frees on job terminal — codex round 6). codex rounds
    3–4 context: the flag closes
    the submit/attach death window for both attempts; a failed submit
    must clear it or the destination stays `:busy` forever.
  - Test seam: `fetch/4` honors an undocumented internal opt
    `:__after_submit__` (a 0-arity fun invoked between submit and
    attach), existing solely so the matrix's death-window test can
    place a deterministic barrier in that window. Named with the
    dunder prefix, excluded from docs, validated like other opts but
    only in test envs — there is no other observable point between
    submit and attach (codex round 4). Its invocation sits under the
    rescue-then-attach rule above.
  - BOTH jobs of an auth retry attach under the one lease; a terminal
    attached job never releases anything while the holder holds or a
    submission is pending.
  - Locks registers ITSELF as a waiter on each attached job
    (`Native.job_register_waiter/1` from the Locks process; `:terminal`
    fast path counts as already-terminal) and marks jobs terminal on
    `{:gitility_job, id, :done}`.
  - Happy path: `fetch/4` calls `release(key)` after taking the result;
    with the flag clear and all attached jobs terminal, the lease frees
    immediately.
  - `await_sync` `:timeout` return: fetch/4 still calls release; the
    cancelled job is not yet terminal → lease holds until the native
    job actually ends. Correct by the release condition, no special
    case.
  - Holder DOWN with attached non-terminal jobs: `Job.cancel/1` them
    (cooperative); lease frees when they reach terminal (and no
    submission is pending).
  - Holder DOWN with pending-submission set (died between submit and
    attach — the native job may be running unobserved; owner-death
    only requests cooperative cancellation): hold the lease for a
    grace period of 2× the lease's declared `timeout_ms` (recorded at
    acquire), then free. The unobservable job self-terminates via
    owner-death cancellation + its own deadline well within that.
  - Holder DOWN with nothing pending and all attached terminal: free
    immediately.
- Contended acquire → `{:error, %Error{code: :busy, retryable: true}}`.

## 6. Token hygiene (tests required for each)

- NIF request decode: `authorization` lands in a newtype
  `Redacted(String)` whose `Debug`/`Display` print `"[REDACTED]"`;
  `FetchRequestMap` derives nothing that prints the inner value. Audit
  EVERY `format!`/`panic!`/error-construction path in fetch.rs and the
  NIF glue for interpolation of the request or the header (the value
  necessarily sits unredacted inside gix's `extra_headers: Vec<String>`
  once handed over — so the audit boundary is: nothing OF OURS formats
  the request struct or the options struct after construction).
- Elixir: `Gitility.Fetch` extracts needed opts and drops the rest
  before any raising call; opts never stored in named-process state,
  Error structs, or telemetry.
- Test: induce every reachable error class with
  `authorization: "Basic sekrit123"` and assert `"sekrit123"` appears
  in none of: the error struct (recursive inspect of all fields),
  captured Logger output, AND captured native stderr (run the
  triggering fetch under a captured port/stderr where feasible on the
  sprite; at minimum the 401, network, timeout, and provider-failure
  classes).

## 7. Test infrastructure + matrix

Compilation wiring FIRST (codex round 1 — the project has no
`elixirc_paths` for tests): add `elixirc_paths(:test)` including
`test/support` to mix.exs (keep `lib`-only otherwise), and require the
server from `test_helper.exs` if path-compilation is not used. The
dress rehearsal (`mix run` in dev on the sprite) must `Code.require_file`
the server explicitly — test/support is not on its path.

`test/support/smart_http_server.ex` — minimal `:gen_tcp` HTTP/1.1
server bridging to the pinned git's `http-backend` as CGI (same PATH
convention as the differential oracle). No new deps. Scope:
- `GET <base>/<repo>/info/refs?service=git-upload-pack` and
  `POST <base>/<repo>/git-upload-pack`. CGI env: `GIT_PROJECT_ROOT`,
  `GIT_HTTP_EXPORT_ALL=1`, `PATH_INFO`, `REQUEST_METHOD`,
  `QUERY_STRING`, `CONTENT_TYPE`, and `CONTENT_LENGTH` (mandatory for
  POST bodies). Body delivery via a PORT (System.cmd has no stdin
  option): open_port with the CGI env, write the body, close stdin
  (`:erlang.port_command` then... use `Port.close` semantics carefully
  — or `:stdin_eof`-capable wrapper; implementer picks the mechanism
  but MUST deliver EOF and collect full binary stdout + exit status).
  Parse CGI response headers, frame HTTP/1.1, `Connection: close`.
- Modes per server start: `require_authorization: value` (else 401 +
  `WWW-Authenticate: Basic`), `respond_status: 403` (fixed status for
  every request — the 403≠401 mapping test), `redirect: location`
  (301 + Location header — the redirects-not-followed test),
  `stall: :after_headers` (hold the socket silently),
  `truncate_pack: n_bytes` (close mid-body), `delay_body:
  {chunk_bytes, delay_ms}` (serve the response body slowly in chunks —
  gives cancellation/timeout a mid-transfer window to land in), plain.
- 127.0.0.1 ephemeral port; `start_supervised!`; URL returned.

Oracle extension (`test/differential/oracle.ex`): `fetch/4` shelling
pinned git; it must `git init --bare` its comparison dest first (the
helper cannot `-C` into a nonexistent path), then `git -C <dest> fetch
<url> <refspecs...>` (+ `--prune` variant).

Test matrix (`test/milestone_5a_fetch_test.exs`; all sprite-local, no
external network):
1. Fresh wildcard fetch into nonexistent dest: initialized bare, refs
   == oracle, fetched commits queryable via existing API.
2. Existing EMPTY dir dest: same as 1. Existing non-repo dir with
   files, and existing non-bare repo: `:invalid_argument`.
3. Incremental fetch after remote gains commits: exact updated_refs,
   `pack_received: true`; identical re-fetch → clean no-op (empty
   updated_refs — the Mode filter test).
4. Prune parity vs `git fetch --prune`, including: exact-name refspec's
   ref survives; overlapping wildcard destinations; exact destination
   nested under a wildcard destination. Plus `prune: false` leaves
   stale refs.
5. PR-style exact refspec fetch; missing exact ref → `:ref_not_found`;
   MIXED wildcard + missing exact refspec → `:ref_not_found`, no ref
   updates applied (the silent-omission trap, §1).
6. Empty remote → ok, `remote_ref_count: 0`.
7. Non-fast-forward without force → ok + `rejected_refs:
   [%{reason: :non_fast_forward}]`, local ref unchanged, oracle parity.
   Keep-cleanup variant (§1): the remote's rewound branch carries a
   DIVERGENT previously-unseen commit so a real pack transfers —
   assert `pack_received: true` FIRST, then NO `.keep` left in
   `objects/pack` (a rewind to an already-local ancestor transfers no
   pack and would pass vacuously — codex round 3).
8. Auth: correct static header succeeds; wrong → `:authentication_failed`;
   provider fun succeeds; provider raising → `:credentials_unavailable`
   (cause carries no token); provider that sleeps past `timeout_ms` →
   `:credentials_unavailable` within the bound, lease released;
   `retry_unauthorized: true` with attempt-keyed bad-then-good provider
   succeeds, provider saw attempts 1 and 2, SAME lock lease throughout
   (assert a concurrent fetch gets `:busy` during the retry window),
   and total wall time stays within `timeout_ms` + margin even on the
   retry path (the whole-call deadline, §3). `respond_status: 403`
   mode → `:network_error`, NOT `:authentication_failed`.
   `redirect: location` mode → `:network_error` (redirects not
   followed).
9. Token hygiene per §6.
10. Stalled server → typed error within `timeout_ms` + margin
    (condition-based waiting, no fixed sleeps), worker reusable after
    (a subsequent fetch on the same runtime succeeds).
11. Truncated pack → typed error, dest refs untouched, dest still opens.
12. Cancellation mid-transfer against the `delay_body` mode →
    `:timeout`/`:cancelled`; plus the coherence property: run a fetch
    with a timeout tuned to race completion and assert the outcome is
    coherent EITHER way — refs all-old or all-new, never torn. (The
    post-commit-timing branch cannot be forced deterministically; the
    load-bearing assertion is never-torn, stated as such — codex
    round 4.)
13. Single-flight: concurrent same-dest → one `:busy`; lock released
    after job terminal (poll until second fetch succeeds); caller
    killed mid-fetch → lease persists until job end, then a new fetch
    proceeds; holder killed inside attempt 2's submit/attach window
    (deterministic via the `:__after_submit__` test seam, §5 — the
    barrier blocks between submit and attach while the test kills the
    caller) → lease holds for the grace period, concurrent fetch gets
    `:busy` (the pending-submission flag, §5); submit that FAILS
    admission (e.g. runtime stopped) → pending flag cleared, dest not
    stuck `:busy` (codex round 4); seam RAISES with a live caller who
    catches the exception → job attached AND lease released before the
    re-raise, dest stays `:busy` only until the job is terminal, then
    a new fetch proceeds (codex round 6); Locks GenServer
    restart mid-lease documented behavior (leases die with it — a
    restarted Locks admits new fetches; note in moduledoc).
14. Runtime isolation: long fetch does not delay a default-runtime
    query. Explicit `runtime:` fetch works without the fetch default
    ever starting.
15. Validation rows: schemes, both auth opts set, bad refspec,
    source-only refspec, retry without provider, CR/LF in
    authorization, bad timeout values.
16. Env-gated real-HTTPS smoke (`GITILITY_TEST_NETWORK=1`): fetch a
    small public GitHub repo over https, assert refs arrive. Never in
    default CI.

Cargo-side: unit tests for prune reverse-matching (match_rhs cases
above), Mode filtering, error mapping; no cargo test touches the
network.

`bench/dress_rehearsal.exs` Flow C: fixture-server fetch of the
phoenix clone → open → spot queries (boot-time regression net for the
new path).

## 8. Docs, changelog, packaging

- `Gitility.Fetch` moduledoc: security story (header straight into the
  in-process HTTP client; credential cascade explicitly disarmed — a
  401 can never invoke a subprocess; token never stored/logged),
  provider contract, single-flight semantics + symlink caveat, prune
  scoping, the honest timeout/commit-point contract from §1 (including
  `:cleanup_failed` meaning fetch-committed), fixed 20s connect timeout,
  redirects-not-followed, and the read-only-queries positioning
  paragraph.
- README "Fetching" section mirroring the moduledoc opening.
- CHANGELOG [Unreleased]: Added (Gitility.Fetch), Changed (MSRV 1.85).
- `mix docs --warnings-as-errors` clean.

## 9. Definition of done

- `cargo test --workspace --lib --bins --tests` green locally.
- Spawn guard UNCHANGED and green; `check-gix-features.sh` green in CI
  (post-Rust-setup step) AND in the sprite rust stage
  (remote-test.sh updated).
- Sprite: full mix suite green (12x loop for the new file), rehearsal
  ALL CHECKS PASSED including Flow C.
- CI green.
- Sprite thread sampler: fetch runtime adds exactly 3 RESIDENT threads
  (2 workers + pump). During 2 concurrent fetches, transient
  dependency threads may briefly push the total up (~3 per in-flight
  connection, §0); the assertion is on the resident count RETURNING to
  3 within a grace window after fetches complete, plus an in-flight
  ceiling of 9 — teardown is asynchronous, so assert with
  condition-based polling, not an instant snapshot.
- Opus adversarial review of the diff, findings fixed, re-verified.
