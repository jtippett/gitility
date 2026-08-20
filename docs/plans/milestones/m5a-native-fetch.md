# M5a — Native fetch (`Gitility.Fetch`)

Status: SPEC (2026-08-20). Scope + feasibility background:
`docs/plans/2026-08-20-native-fetch-scope.md` (all gitoxide claims there
are source-verified; this spec assumes them). James approved: fetch
ahead of the republisher; a dedicated fetch runtime.

Deliverable: `Gitility.Fetch.fetch/4` — client-side smart-HTTP git
fetch into a local bare repository, over gix 0.86.0, statically-linked
rustls, running as budgeted jobs on a dedicated 2-worker runtime.
This is gitility's first write path into a real git directory; the
query API stays read-only and the module docs must say so.

## 0. Ground rules (unchanged, load-bearing)

- NO BEAM on the dev Mac. All mix verification via
  `./scripts/remote-test.sh` on the sprite. Cargo tests run locally.
- Thread discipline: NO new thread-spawn sites. The fetch runtime is a
  second instance of the existing `Gitility.Runtime` — same
  `runtime_start()` NIF, same two allowlisted spawn sites
  (`crates/gitility-core/src/runtime/mod.rs` worker loop,
  `native/gitility/src/lib.rs` notification pump). Net new threads at
  steady state: 2 workers + 1 pump. `scripts/check-thread-spawns.sh`
  must pass UNCHANGED. If you find yourself needing `thread::spawn`
  anywhere, stop and flag it — that is a design escalation, not an
  implementation detail.
- gix MUST NOT spawn threads either. See §2 feature audit.
- The authorization value is radioactive: it must never appear in any
  `Debug`/`Display` impl, error message, log line, Elixir error struct,
  result struct, or crash report. See §6.

## 1. Elixir API

New module `lib/gitility/fetch.ex`:

```elixir
@spec fetch(Path.t(), String.t(), [String.t()], keyword()) ::
        {:ok, Gitility.Fetch.Result.t()} | {:error, Gitility.Error.t()}
def fetch(dest, url, refspecs, opts \\ [])
```

- `dest` — path to a bare repository directory. If it does not exist
  (or exists empty), fetch creates and initializes it as a bare SHA-1
  repository before fetching. If it exists and is not a git bare dir →
  `:invalid_argument`. If it is a repository with a different object
  hash than the remote → surface gix's incompatibility as
  `:unsupported_hash`.
- `url` — `https://` or `http://` only (http is required for the test
  fixture; document that production use is https). `file://`, `ssh://`,
  `git://`, scp-style → `:invalid_argument`, message naming the schemes
  we accept. Validate CALLER-SIDE before submitting (M4c lesson:
  error tuples, never exits/raises for bad input).
- `refspecs` — non-empty list of fetch refspec strings, e.g.
  `"+refs/heads/*:refs/heads/*"`, `"+refs/pull/7/head:refs/pull/7/head"`.
  Parse/validate in Rust at submit via gix-refspec; invalid →
  `:invalid_argument` naming the offending refspec.

Options:

| opt | default | meaning |
|---|---|---|
| `credentials:` | nil | provider fun/MFA, §5 |
| `authorization:` | nil | static header value; sugar for a constant provider. Mutually exclusive with `credentials:` (`:invalid_argument` if both). |
| `prune: bool` | false | §4 |
| `timeout_ms:` | 120_000 | whole-operation budget, enforced by the existing await→cancel semantics (§3) |
| `connect_timeout_ms:` | 10_000 | transport-level, §3 |
| `read_timeout_ms:` | 30_000 | per-read stall bound, §3 |
| `retry_unauthorized: bool` | false | §5 |
| `runtime:` | the fetch default | an explicit `Gitility.Runtime` name/pid for user-supervised runtimes |

Result struct `Gitility.Fetch.Result` (new file
`lib/gitility/types/fetch_result.ex`, follow the existing types
pattern — `@enforce_keys`, `@type t`):

```elixir
%Gitility.Fetch.Result{
  updated_refs: [%{name: String.t(), action: :created | :updated | :forced,
                   old_oid: String.t() | nil, new_oid: String.t()}],
  pruned_refs: [String.t()],
  remote_ref_count: non_neg_integer(),
  pack_received: boolean()
}
```

Behavioral contract (each row is a test):
- Empty remote + wildcard refspecs → `{:ok, %Result{remote_ref_count: 0,
  updated_refs: [], pack_received: false}}`. NOT an error. (Consumers
  key "empty repository" UX off `remote_ref_count == 0`.)
- Exact-name refspec with no matching remote ref → `:ref_not_found`
  (mapped from gix `Error::NoMapping`), message includes the refspec.
- Up-to-date re-fetch → `{:ok, ...}` with empty `updated_refs`,
  `pack_received: false`. Idempotent.
- Ref updates and pack presence are atomic in gix's ordering (pack
  written + .keep, then ref transaction, then .keep removed). A failed
  fetch must leave refs untouched — test asserts pre/post ref parity
  after each induced failure.

## 2. Cargo wiring + gix feature audit

In `crates/gitility-core/Cargo.toml`:

```toml
gix = { version = "=0.86.0", default-features = false, features = [
  "blocking-network-client",
  "blocking-http-transport-reqwest-rust-tls",
] }
```

plus whatever minimal additional gix features compilation actually
requires (discover empirically; justify each in the commit message).
HARD CONSTRAINTS: the resolved feature set must not include gix's
`parallel`, `max-control`, `max-performance-safe`, or `max-performance`
(they forward `gix-pack/parallel`, which spawns indexing threads we
cannot see). The existing `[patch.crates-io] gix-diff` entry must keep
applying to gix's transitive gix-diff (same `=0.66.0` — verify in
Cargo.lock that exactly one gix-diff, the vendored one, exists).

New guard script `scripts/check-gix-features.sh`, wired into CI next to
the spawn-spawn check: uses `cargo metadata` (or `cargo tree -e
features`) to assert `gix-pack` is compiled WITHOUT its `parallel`
feature and that `crossbeam-deque` is absent from the dependency graph.
Rationale in a comment: the spawn guard scans our sources, not
dependencies; this is the dependency-side equivalent.

Precompiled artifact note: rustls/reqwest adds ~2–4 MB per target;
no release.yml changes expected (same 4 targets, same NIF ABI 2.15).

## 3. Runtime placement, cancellation, timeouts

- The default fetch runtime is a lazily-started second
  `Gitility.Runtime` named `Gitility.FetchRuntime`, `workers: 2`,
  `max_queue: 32`, `max_jobs_per_owner: 4` — created exactly like
  `Runtime.default/0` (Supervisor.start_child on `Gitility.Supervisor`
  + persistent_term), factored so the two don't copy-paste. Query jobs
  must never land on it and fetch jobs must never land on the query
  default: `job_submit_fetch` is only called by `Gitility.Fetch`, which
  resolves `opts[:runtime]` or the fetch default. Nothing in the NIF
  distinguishes runtime kinds — isolation is by construction on the
  Elixir side; document that an explicit `runtime:` shared with queries
  is allowed but self-inflicted.
- Whole-operation `timeout_ms` reuses the proven ownership semantics:
  `NativeSupport.await_sync` awaits with `timeout_ms + 500`, cancels the
  job on expiry, returns `:timeout`. No new deadline machinery.
- Cancellation reaches gix through `should_interrupt`: the fetch task
  must observe the job's existing cancel flag. Expose the core job's
  cancel `AtomicBool` (or an adapter Arc that the runtime flips on
  cancel) to the task closure so it can be passed as gix's
  `should_interrupt`. If the core Job's flag isn't currently reachable
  from task code, add an accessor on the job context — do NOT introduce
  a second flag that something must remember to flip, and do NOT poll
  with a helper thread.
- Transport timeouts: gix's reqwest backend ignores the shared
  `http::Options` timeouts (verified). Use the reqwest backend's
  `configure_request` hook (in `http::Options::backend`) to set a
  per-request timeout from `read_timeout_ms`/`connect_timeout_ms`.
  A stalled server must produce a typed `:network_error` (retryable)
  within the configured bound — there is a fixture mode for this (§7).
- On cancellation mid-transfer gix returns an interrupt error → map to
  `:cancelled`. Time-expiry cancellation surfaces as `:timeout` via the
  await_sync path, consistent with queries.

## 4. Fetch task semantics (Rust, `crates/gitility-core/src/fetch.rs` + NIF glue)

One new NIF: `job_submit_fetch(runtime, fetch_request_map)` returning
the standard job handle; result decoded by the standard
`job_take_result` path. `FetchRequestMap` (NifMap): `dest`, `url`,
`refspecs: Vec<String>`, `authorization: Option<String>`, `prune: bool`,
`connect_timeout_ms`, `read_timeout_ms`.

Task flow (all on the fetch worker thread, single-threaded):
1. Open-or-init dest: `gix::open` with isolated config
   (`open::Options::isolated()` — NEVER read user/system git config),
   else `gix::init_bare`. Init must not race a concurrent init to the
   same path into corruption — rely on gix's own init locking; a lost
   race that finds a valid bare repo proceeds.
2. `repo.remote_at(url)` → `with_refspecs(refspecs, Fetch)`.
3. `connect(Fetch)`, then in this exact order:
   `set_credentials(|_| Ok(None))` (MANDATORY — disarms the
   git-credential subprocess cascade; a 401 must become a typed error,
   never a helper invocation) and `set_transport_options(http::Options {
   extra_headers: [authorization header if provided], backend:
   reqwest configure_request setting timeouts, ..default })`.
4. `prepare_fetch(...)` → `receive(progress, &should_interrupt)`.
   Progress: discard (v1 has no progress reporting; use the no-op
   progress type).
5. Map the outcome to the result struct: ref edits from
   `update_refs`, `remote_ref_count` from the ref map's remote refs,
   `pack_received` from `Status::Change` vs `NoPackReceived`.
6. Prune (only if `prune: true`): for each WILDCARD refspec, compute
   the local namespace its destination side covers; list local refs in
   that namespace; delete (single gix-ref transaction, previous-value
   asserted) every local ref whose mapped remote source is absent from
   the remote's advertised refs. Exact-name refspecs never prune.
   Symbolic refs (HEAD) are never touched. Deletions go into
   `pruned_refs`. Parity oracle: `git fetch --prune` (§7).

Error mapping (Rust → ErrorCode), new codes in **bold** (add to
`ErrorCode` enum + `all()` + `as_str()` + Elixir `@codes`, keeping the
existing sync test green):
- HTTP 401/403 (io PermissionDenied from the transport) →
  **AuthenticationFailed** (`:authentication_failed`), retryable: false.
  The message must NOT echo the header we sent.
- Connect/read/TLS/DNS failures, stalled-read timeout, truncated
  response → **NetworkError** (`:network_error`), retryable: true,
  details: %{phase: :connect | :read | :negotiate}.
- gix `Error::NoMapping` → existing `RefNotFound`.
- Hash mismatch dest vs remote → existing `UnsupportedHash`.
- Interrupt via cancel → existing `Cancelled`.
- Pack/index verification failures during receive → existing
  `PackChecksumMismatch` / `IndexChecksumMismatch` / `MalformedObject`
  as applicable.
- **CredentialsUnavailable** (`:credentials_unavailable`) is
  constructed ELIXIR-SIDE only (provider failure, §5) but lives in both
  registries so the cross-language sync test stays exact.

## 5. Credential provider (Elixir-side only; NIF sees a resolved string)

- `credentials:` accepts a 1-arity fun or `{module, function, args}`
  (called as `apply(m, f, args ++ [context])`). Context map v1:
  `%{url: url, host: host, attempt: 1 | 2}`. Return
  `{:ok, %{authorization: binary}}` or `{:error, term}`.
- Called in the CALLER's process immediately before job submission.
  Provider raise/bad return → `{:error, %Error{code:
  :credentials_unavailable}}` with the provider's error as `cause` —
  but SCRUB: if the provider's error term contains the word-shaped
  token (any binary in the term), do not embed the term; keep a
  formatted summary via `inspect(..., limit: ...)`? NO — simpler and
  safer: `cause` carries only the exception module/`:bad_return`, never
  the full term. Tests assert a token-bearing provider error does not
  leak the token into the Error struct.
- `retry_unauthorized: true`: on `:authentication_failed`, call the
  provider once more with `attempt: 2` and submit one fresh job;
  a second 401 returns the error. Never loops. Without a provider
  (static `authorization:`), `retry_unauthorized` is `:invalid_argument`
  (there is nothing new to try).
- Single-flight per destination: a lock keyed by the EXPANDED dest path
  (`Path.expand/1`). Implementation: `Gitility.Fetch.Locks`, a
  GenServer owning an ETS set, started as a `Gitility.Supervisor` child
  alongside the fetch runtime's lazy start; lock is monitor-based so a
  crashed caller releases it. Concurrent second fetch to the same dest
  → `{:error, %Error{code: :busy, retryable: true}}`. (Rationale: git
  tolerates concurrent fetches, but overlapping ref transactions and
  double pack downloads serve nobody; refusing is honest.)

## 6. Token hygiene (tests required for each)

- The NIF request struct's `Debug` must redact `authorization`
  (manual `impl Debug` or a newtype `Redacted(String)` whose
  Debug/Display prints `"[REDACTED]"`). No `format!` anywhere may
  interpolate it.
- Elixir: the opts keyword list must not be stored in any long-lived
  process state, Error struct, or telemetry. `Gitility.Fetch` extracts
  what it needs and drops the rest before any call that could raise.
- Test: induce every error class with `authorization: "Basic sekrit123"`
  and assert `"sekrit123"` appears nowhere in the returned error
  (message, details, cause, formatted via `inspect/1` recursively) nor
  in captured logs.

## 7. Test infrastructure + matrix

New test support: `test/support/smart_http_server.ex` — a minimal
`:gen_tcp` HTTP/1.1 server bridging to `git http-backend` as CGI.
This is deliberately NOT a new runtime dependency (no plug/bandit).
Scope: exactly what smart HTTP needs —
- `GET <base>/<repo>/info/refs?service=git-upload-pack` and
  `POST <base>/<repo>/git-upload-pack`, implemented by spawning the
  pinned git's `http-backend` via `System.cmd`/port with CGI env
  (`GIT_PROJECT_ROOT`, `GIT_HTTP_EXPORT_ALL=1`, `PATH_INFO`,
  `REQUEST_METHOD`, `CONTENT_TYPE`, `QUERY_STRING`) and the request
  body on stdin; parse the CGI response (headers, then raw body) and
  frame it as HTTP/1.1 with `Connection: close` (chunked encoding not
  required if we close). Uses the SAME pinned-git PATH convention as
  the differential oracle.
- Modes, set per-server-start: `require_authorization: "value"`
  (mismatch/absence → 401 + `WWW-Authenticate: Basic`), `stall: :after_headers`
  (send headers then hold the socket open silently — read-timeout test),
  `truncate_pack: n_bytes` (close mid-body), plain.
- Listens on 127.0.0.1 ephemeral port; returns its URL. Supervised by
  the test (start_supervised!), socket closed on exit.

Differential oracle extension (`test/differential/oracle.ex`): a
`fetch/4` helper shelling the pinned git (`git -C <dest> fetch <url>
<refspecs...>` with `--prune` variant), used to produce the expected
ref set / reachability for parity assertions against the same fixture
server.

Test matrix (new file `test/milestone_5a_fetch_test.exs`; every row
runs on the sprite, none require external network):
1. Fresh wildcard fetch into nonexistent dest: dest initialized bare,
   refs == oracle's, every fetched commit queryable via the existing
   API (`Repository.open` + `log` + `read_file` spot checks).
2. Incremental fetch after remote gains commits: only new objects
   transferred (assert pack_received true, updated_refs exact), second
   identical fetch is a clean no-op.
3. Prune parity: delete a remote branch, `prune: true` fetch; local ref
   set == oracle's `git fetch --prune` result. Exact-name refspec
   present alongside — its ref survives pruning.
4. PR-style exact refspec: fetch `+refs/pull/1/head:refs/pull/1/head`
   (fixture repo gets a ref named that way); missing exact ref →
   `:ref_not_found`.
5. Empty remote (init --bare, zero refs): wildcard fetch → ok with
   `remote_ref_count: 0`.
6. Auth: server requires a header. Correct static `authorization:`
   succeeds; wrong → `:authentication_failed`; provider fun succeeds;
   provider raising → `:credentials_unavailable`;
   `retry_unauthorized: true` with a provider returning bad-then-good
   (attempt-keyed) succeeds and the provider saw attempts 1 and 2.
7. Token hygiene per §6.
8. Stalled server → `:network_error` within ~read_timeout_ms (assert
   with generous margin, condition-based not sleep-based).
9. Truncated pack → typed error, dest refs untouched, dest still opens
   cleanly (or, for the fresh-dest case, contains no half-updated refs).
10. Cancellation: async submit (if `fetch/4` is sync-only, drive via a
    Task + `timeout_ms`), cancel mid-transfer against the stall/slow
    server → `:timeout`/`:cancelled`, worker returns to service (a
    subsequent fetch on the same runtime succeeds).
11. Single-flight: two concurrent fetches, same dest → one `:busy`.
12. URL/refspec/opt validation rows (schemes, both auth opts, bad
    refspec, retry without provider).
13. Runtime isolation: a long fetch does not delay a query on the
    default runtime (submit both; query completes while fetch runs).

Cargo-side: unit tests for prune namespace computation and error
mapping; NO cargo test may hit the network.

Also update `bench/dress_rehearsal.exs` with a Flow C: fixture-server
fetch of the phoenix clone → open → spot queries — keeps the rehearsal
as the boot-time regression net for the new path.

## 8. Docs, changelog, packaging

- `Gitility.Fetch` moduledoc: the security story (header straight into
  the in-process HTTP client; credential-helper cascade explicitly
  disarmed — a 401 can never invoke a subprocess; token never stored or
  logged), the provider contract, single-flight, prune scoping, and the
  positioning paragraph (queries stay read-only; Fetch is the one
  writer).
- README: short "Fetching" section mirroring the moduledoc's opening.
- CHANGELOG [Unreleased] → Added.
- `mix docs --warnings-as-errors` clean (CI enforces).

## 9. Definition of done

- `cargo test --workspace --lib --bins --tests` green locally.
- Spawn guard UNCHANGED and green; new gix feature-audit script green.
- Sprite: full mix suite green (12x loop for the new file), rehearsal
  ALL CHECKS PASSED including Flow C.
- CI green.
- No new thread-spawn sites; thread sampler on the sprite shows the
  fetch runtime adds exactly 3 threads (2 workers + pump) when started.
- Opus adversarial review of the diff, findings fixed, re-verified.
