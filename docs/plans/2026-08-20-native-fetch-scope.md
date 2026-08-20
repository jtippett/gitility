# Native fetch (`Gitility.Fetch`) — scope and feasibility

Status: SCOPED, awaiting James's go (2026-08-20). Requested by the first
consumer (gentility CodeExplorer): promote native fetch from post-1.0 to
an active milestone, likely ahead of the single-owner bundle republisher.

All feasibility claims below were verified by reading the vendored
gitoxide checkout (`sources/gitoxide`, gix 0.86.0 / gix-transport
0.58.1) — file:line citations in the investigation notes; the summary
here records the conclusions.

## Verdict

Feasible with zero hard blockers. gix's client fetch is the mature,
cargo-proven leg of gitoxide, and every requirement the consumer listed
maps onto verified machinery. Four findings are load-bearing:

1. **Static TLS is real.** `gix` with `default-features = false` +
   `blocking-network-client` + `blocking-http-transport-reqwest-rust-tls`
   is pure Rust (rustls), no OpenSSL/libcurl. Every gix-* plumbing pin in
   gitility-core (`=0.26.0` hash, `=0.63.0` object, `=0.83.0` odb,
   `=0.66.0` diff/ref, …) exactly matches what gix 0.86.0 itself
   requires — adding the facade crate resolves to the versions we
   already lock, no duplicate trees. The vendored gix-diff continues to
   apply via the existing `[patch.crates-io]` mechanics.
2. **Header auth is first-class, but the credential-helper fallback must
   be explicitly disarmed.** `Connection.with_transport_options`
   carries `http::Options{extra_headers}` — the `Authorization` value
   goes straight into the HTTP client, never argv/env/shell. HOWEVER:
   on a 401, gix's default `authenticate: None` silently falls back to
   the `git credential` cascade, which SHELLS OUT to helper programs.
   `set_credentials(|_| Ok(None))` is MANDATORY in our wiring so a bad
   token is a clean typed error and no subprocess ever runs. This is
   the whole security story; it goes in the module docs.
3. **Threading needs explicit feature control.** gix's default feature
   set pulls `parallel` (via max-performance-safe → max-control), and
   gitility-core's existing "gix-odb without parallel" does NOT reach
   gix-pack — separate feature, never forwarded. Building gix with
   default-features off gives fully single-threaded pack indexing
   (`resolve_serial`) on the calling thread: one fetch = one thread,
   no pool spawned by gix at all.
4. **Cancellation is cooperative and fits our model.** `receive(...,
   should_interrupt: &AtomicBool)` is threaded through negotiation
   rounds, the HTTP read chunk loop, and index building — same shape
   as our existing job deadlines. Caveat: it cannot preempt a stalled
   blocking socket read, and the reqwest backend ignores the shared
   timeout options (hardcodes 20s connect, no read timeout). Mitigation:
   the `configure_request` backend hook sets a per-request reqwest
   timeout; belt-and-braces on top of the interrupt flag.

## API (v1)

```elixir
Gitility.Fetch.fetch(dest, url, refspecs, opts)
# dest      — bare git dir; created + initialized if absent (no separate
#             init_bare/1: a half-step primitive is a footgun, and the
#             consumer loop is "fetch into possibly-fresh mirror dir")
# url       — https:// (http:// accepted for tests; file/ssh refused)
# refspecs  — list of strings, e.g. ["+refs/heads/*:refs/heads/*"]
# opts:
#   authorization: "Basic ..." | "Bearer ..."  # raw header value
#   prune: true | false (default false)
#   timeout_ms: ...            # whole-operation budget → interrupt flag
#   connect_timeout_ms/read_timeout_ms         # transport-level
# returns {:ok, %Gitility.Fetch.Result{}} | {:error, %Gitility.Error{}}
```

`Result` carries `updated_refs` (name, old/new oid, action), `pruned_refs`,
`remote_ref_count`, `pack_received?`. Behavior decisions:

- **Empty remote**: wildcard refspecs against a zero-ref remote are a
  verified clean no-op in gix (`Status::NoPackReceived`, no error). We
  return `{:ok, %Result{remote_ref_count: 0, updated_refs: []}}` — the
  consumer distinguishes "empty repository" from failure by
  `remote_ref_count == 0`, and auth/network failures are typed errors
  (401 → `:authentication_failed`, transport → `:network_error`,
  retryable flagged). Exact-name refspecs (e.g. a PR ref) that don't
  match remotely surface gix's `Error::NoMapping` as `:ref_not_found`.
- **Prune**: gix has NO prune implementation (verified — config
  persistence only). We implement it: diff the received RefMap's
  remote-advertised refs against local refs inside the refspec-mapped
  namespace, delete via a gix-ref transaction. Scoped exactly like
  `git fetch --prune` — only namespaces covered by the given wildcard
  refspecs, exact-name refspecs never prune.
- **Token hygiene**: the authorization value never appears in any error,
  result, log, or inspect output — errors are constructed from scratch,
  never by embedding opts.
- **Fetch-into-bundle**: v2, not in this scope (composes later with the
  single-owner republisher: fetch → bare dir → Bundle.write).

## Runtime placement (JAMES REVIEW EVENT — thread budget)

A fetch is minutes-long blocking I/O; putting it on the query worker
pool (schedulers/2) would let one mirror sync starve queries.
Recommendation: a second, tiny runtime instance dedicated to fetch —
reuse the proven M2a bounded runtime verbatim, `fetch_workers: 2`,
own queue. Net new native threads: +2 (+ nothing from gix, per finding
3). This changes the spawn-guard allowlist and therefore needs James's
sign-off per the standing thread-budget rule. Fallback if declined:
run fetches on the existing pool and document worker occupancy.

## Testing

- Differential oracle vs pinned git 2.55.0 `git fetch` over smart HTTP:
  serve fixture repos through `git http-backend` (CGI behind a trivial
  local HTTP server) on the sprite/CI — pure-local, deterministic.
  Parity on: ref update sets, prune sets, object reachability
  post-fetch, pack dir contents queryable by the existing API.
- Fault matrix: 401/403, truncated pack stream, mid-fetch interrupt,
  stalled server (read-timeout path), empty remote, exact-ref miss,
  re-fetch no-op idempotence, concurrent fetch to same dest (single
  in-flight fetch per dest, second call queues or refuses — design says
  refuses with `:busy` in v1).
- One real-HTTPS smoke against a public GitHub repo, env-gated
  (`GITILITY_TEST_NETWORK=1`), never in default CI.

## Estimate

M5a-scale, the standard pipeline (design → codex implementation → opus
review → sprite verification): **roughly 2 focused days**. Cost drivers:
the http-backend test fixture (new), prune correctness, and the reqwest
timeout hardening. Binary size: +2–4 MB per precompiled target
(rustls + reqwest + http2). Risk register: reqwest backend is labeled
"experimental" in gix's own docs (it honors extra_headers +
follow_redirects, ignores proxy/TLS-verify/timeout options — acceptable
for v1, `configure_request` covers the gap); curl backend is the
escape hatch if it disappoints, at the cost of static-build simplicity.

## Positioning note

This is gitility's first write-path into a real git directory (pack
files + ref transactions). Docs frame it explicitly: the query API
remains read-only over snapshots; `Gitility.Fetch` is the ingestion
module that feeds it, and the only writer.
