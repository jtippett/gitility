# M6 mirror replication implementation notes

Implementation date: 2026-08-21  
Frozen specification: `m6-mirror-replication.md`, SPEC v7

## Implementer choices

- `Gitility.ObjectStore.Local` serialises current-version changes in one
  supervised server per expanded root. Its blocking callbacks and Mirror's
  outer callback boundary each use the specified task deadline, so killing a
  caller also releases server pins through the holder monitor.
- Restore constructs the repository only in a sibling stage, installs each
  pack before its matching index, writes all refs and HEAD in one native
  transaction, and performs the pair/checksum/ref/peel checks before the final
  rename.
- Bare repository creation is shared by explicit `Repository.init_bare/2`,
  fetch auto-initialisation, and restore. The three gc-safe config values are
  written in the staging repository before it is renamed into place.

## Review round 1

- A1: Local's `key` debug aid is now written through an exclusive random temp
  and rename. A damaged/mismatching debug file is replaced; `:hash_collision`
  remains only when hashing the complete stored key proves a real collision.
- A2: a Local sweep treats only `:enoent` as a missing `current`; other read
  failures and non-64-byte pointers abort that key's sweep.
- A3: Local follows root symlinks and chmods only a root it created. Owned
  directories retain `lstat` type checks, and `current` temps are random and
  exclusive.
- A4: restore's ancestor walk uses `File.stat/1`, while destination validation
  keeps `lstat/1`, so symlinked ancestors work without permitting a symlinked
  destination.
- A5: Mirror no longer sweeps `objects/.gitility-publish-*`; public
  `Bundle.write` is not lease-covered and `objects` can point at shared data.
  PackInventory continues to clean only its own scratch in `after`.
- A6: Bundle staging and Writer temp paths use random 32-hex suffixes and are
  cleaned only after this invocation successfully created them.
- A7: resolved and unborn HEAD symrefs must name a branch under
  `refs/heads/` on both sides of the NIF boundary.
- A8: HEAD symrefs use the same full 4096-byte ref validator as ref rows on
  both sides; the Elixir validator also mirrors gix's one-level-name rule.
- A9: the symmetric-rejection fallback was chosen. gix 0.86 packed-ref
  transactions still acquire a loose lock per update, so strict publication
  rejects components over 255 bytes with `details.reason:
  :component_too_long`, and restore rejects the same bundle shape.
- A10: bundle open/pread failures are `:backend_error`; only structural short
  reads and digest failures remain `:malformed_object`.
- A11: Local and S3 workers produce only `.part`; caller-side wrappers perform
  the final rename and honor a successful late `Task.shutdown/2` result.
- A12: provider codes at least 40 bytes long or equal case-insensitively to an
  S3 credential are replaced by `"Redacted"`; Mirror also caps arbitrary
  adapter HTTP codes at the same boundary.
- A13: `Repository.init_bare/2` now holds the shared expanded-path Fetch lease
  and reports retryable `:busy` on contention.
- A14: Mirror passes the remaining time to callbacks and waits that value plus
  the documented 1,000 ms adapter grace.
- A15: native init cleanup remembers a pre-existing empty destination and
  recreates it if the post-rename reopen fails.
- A16: deadline expiry before PUT invocation is explicitly
  `indeterminate: false`; only a killed in-flight PUT is indeterminate.
- A17: the native ref-count guard is derived as `64 MiB / 27` minimum ref-row
  bytes instead of treating the TOC byte ceiling as a row count.
- A18: an unpinned Local root server exits after 60 idle seconds and revives on
  demand without losing stored objects; lookup and pin retry the brief
  supervisor/registry cleanup race.
- A19: remote mix and rehearsal stages are written to remote temp files before
  `capped bash` starts, so the sampler and commands cannot consume script text
  through shared stdin. Successful wrappers reach EOF naturally so sampler
  teardown cannot be misreported by the sprite transport as a failed stage.
- B1: direct `Mirror.validate_metadata/1` coverage exercises the exact 1 KiB
  boundary and every required rejecting shape.
- B2: all invalid key vectors pass through both Mirror entry points before any
  adapter init call.
- B3: pure S3 tests cover init validation and exact assembled path,
  virtual-host, custom-port, IPv6, and encoded-key URLs.
- B4: the HTTP stub responds per method, consumes streamed PUT bodies, and
  drives PUT precondition/redirect plus GET redirect and credential-reflection
  paths with debug-level, case-insensitive hygiene assertions.
- B5: fsck assertions require exit status zero and reject integrity-failure
  lines instead of matching the empty string.
- B6: idx corruption touches only its trailing checksum and the rewritten
  container digest, reaching checksum-specific restore rejection.
- B7: the Local race test ages version A, identifies post-rename version C by
  set difference, and proves C remains current through an eligible sweep.
- B8: Local's timeout row blocks after reading a 64 MiB body chunk and proves
  both destination paths are absent.

## Req streamed SigV4 verification

The resolved and locked `req 0.5.18` implementation (satisfying `~> 0.5.8`)
was inspected in `deps/req/lib/req/steps.ex`. `put_aws_sigv4/1` classifies a
request body that is neither binary nor iodata as an enumerable at lines
1258–1272 and supplies `body_digest: "UNSIGNED-PAYLOAD"` at line 1271.
Therefore the S3 adapter keeps the prescribed
`File.stream!(src_path, 1_048_576)` body and explicit `Content-Length`; the
≤256 MiB full-buffer fallback is not needed. Req's streaming response callback
shape was also confirmed as
`fn {:data, data}, {request, response} -> {:cont, {request, response}} end`.

## Pinned MinIO

Sprite and CI use `RELEASE.2025-07-23T15-54-02Z`.

- Linux amd64 archive SHA-256:
  `eef6581f6509f43ece007a6f2eb4c5e3ce41498c8956e919a7ac7b4b170fa431`
- Quay OCI index digest:
  `sha256:d249d1fb6966de4d8ad26c04754b545205ff15a62e4fd19ebd0f26fa5baacbc0`

The sprite refuses an unavailable or checksum-mismatched binary. CI uses the
same release as a digest-pinned service and prepares the bucket through the
same signed helper path used by the tests.

## Deviations

- `lib/gitility/mirror.ex` adds one exact restore sweep shape beyond the list
  at `docs/plans/milestones/m6-mirror-replication.md:636-639`:
  `<base>.restore-<32hex>.stage.init-<32hex>`. Restore creates its bare stage
  through the shared failure-atomic initializer, so VM death during that
  DirtyIo call can leave precisely this nested sibling. The frozen §5.1 list
  omitted it even though §2 requires later init/restore to sweep VM-death
  orphans. The added pattern is fully anchored, requires `lstat` type
  `:directory`, and is covered by the missing-key restore row. No broader
  path is removed.

## Verification evidence

No `mix` command was run on the development Mac.

### Local non-BEAM gate

```text
$ cargo test --workspace
gitility NIF tests:               2 passed; 0 failed
gitility-core unit tests (macOS): 267 passed; 0 failed
HTTP integration tests:          3 passed; 0 failed
doc tests:                        0 passed; 0 failed

$ cargo clippy --workspace --all-targets -- -D warnings
Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.33s

$ cargo fmt --all -- --check
(success; no output)

$ bash scripts/check-thread-spawns.sh
Verified exactly two allowlisted, budgeted native thread spawn sites.

$ bash scripts/check-gix-features.sh
check-gix-features: gix-pack is single-threaded on normal/build edges

$ RUSTFLAGS="--cfg loom" cargo build -p gitility-core --no-default-features
Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.19s
```

### Linux sprite gate

The final command was `./scripts/remote-test.sh`, whose default stages are
`sync rust loom postgres mix rehearsal soak`. Summary lines:

```text
==> sync: done (content-verified b8c1ab71c2ca018e2ba9cd294c99f8270f5cb3f3)
gitility NIF tests:                 2 passed; 0 failed
gitility-core unit tests (Linux): 268 passed; 0 failed
HTTP integration tests:            3 passed; 0 failed
FMT-OK
Verified exactly two allowlisted, budgeted native thread spawn sites.
loom: 233 passed; 0 failed
[remote] PostgreSQL database=sprite_gitility_test role=sprite ready
3 doctests, 461 tests, 0 failures, 2 skipped (1 excluded)
M5a: 12 repetitions × 23 tests, 0 failures
M6: 12 repetitions × 36 tests, 0 failures
ObjectStore.Local: 12 repetitions × 16 tests, 0 failures
ObjectStore.S3/MinIO: 12 repetitions × 13 tests, 0 failures
consumer-smoke: COMPILE WITHOUT REQ + RESTORE -> FETCH -> PUBLISH PARITY OK
DRESS REHEARSAL: ALL CHECKS PASSED
soak: 1 test, 0 failures (452 excluded)
==> all requested stages finished
```
