# F6 Turso concurrency spike

This crate is a Milestone 0 feasibility spike. It is not shipped as part of
Gitility and may be deleted after the F6 decision has been absorbed into the
production bundle implementation.

The test builds a standard SQLite file through `turso_core` containing 64 MiB
of deterministic pseudo-random pack data in 1 MiB rows. It then exercises the
file from 16 native threads in two phases:

- 2,000 randomized operations per thread through one connection per thread,
  mixing point lookups with ordered `BETWEEN` scans of two to four chunks;
- eight long-lived readers running while eight other threads repeatedly create
  and tear down connections, alternating explicit `close()` with drop-based
  teardown.

Every returned byte is compared with the deterministic corpus used to build the
file. The corpus is generated once and shared read-only so verification uses a
fast byte-for-byte comparison rather than regenerating tens of GiB in debug
test builds.

The spike calls `turso_core::Statement::step()` directly and polls the
statement's database I/O on `IO` and `Yield`. This mirrors the
synchronous Turso CLI/NIF execution model and deliberately avoids the async
`turso` binding wrapper and an async runtime.

Run it with:

```console
cargo test -p f6-spike -- --nocapture
```

The test prints aggregate chunks/second and GiB/second for both phases. Success
means all reads are byte-correct and every worker terminates without a Turso
error, panic, or deadlock. Any such failure is an F6 blocker and should not be
weakened or retried away; Gitility's recorded response is to use its `rusqlite`
fallback.

## Result

**PASS with the exact-pinned `turso_core` 0.7.2 release.** A representative
debug-profile run on 2026-08-14 verified 48,070 chunks (46.94 GiB) in the main
phase at 2,231 chunks/second, then verified another 2,800 chunks while cycling
800 connections at 2,370 chunks/second. No incorrect bytes, errors, panics, or
deadlocks were observed. F6 is supported; the `rusqlite` fallback is not
triggered by this spike.
