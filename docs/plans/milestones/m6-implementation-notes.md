# M6 mirror replication implementation notes

Implementation date: 2026-08-21  
Frozen specification: `m6-mirror-replication.md`, SPEC v6

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

No BEAM command was run on the development Mac.

### Local non-BEAM gate

```text
$ cargo test --workspace
gitility NIF tests:               2 passed; 0 failed
gitility-core unit tests (macOS): 265 passed; 0 failed
HTTP integration tests:          3 passed; 0 failed
doc tests:                        0 passed; 0 failed

$ cargo clippy --workspace --all-targets -- -D warnings
Finished `dev` profile [unoptimized + debuginfo] target(s) in 4.28s

$ cargo fmt --all -- --check
(success; no output)

$ scripts/check-thread-spawns.sh
Verified exactly two allowlisted, budgeted native thread spawn sites.

$ scripts/check-gix-features.sh
check-gix-features: gix-pack is single-threaded on normal/build edges

$ RUSTFLAGS="--cfg loom" cargo build -p gitility-core --no-default-features
Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.19s
```

### Linux sprite gate

The final command was `./scripts/remote-test.sh`, whose default stages are
`sync rust loom postgres mix rehearsal soak`. Summary lines:

```text
==> sync: done (content-verified 95c4abe3cd0f6b460f7b63fe8db8dfde86bde519)
gitility NIF tests:                 2 passed; 0 failed
gitility-core unit tests (Linux): 266 passed; 0 failed
HTTP integration tests:            3 passed; 0 failed
FMT-OK
Verified exactly two allowlisted, budgeted native thread spawn sites.
loom: 233 passed; 0 failed
[remote] PostgreSQL database=sprite_gitility_test role=sprite ready
3 doctests, 443 tests, 0 failures, 2 skipped (1 excluded)
M5a: 12 repetitions × 23 tests, 0 failures
M6: 12 repetitions × 33 tests, 0 failures
ObjectStore.Local: 12 repetitions × 12 tests, 0 failures
ObjectStore.S3/MinIO: 12 repetitions × 13 tests, 0 failures
consumer-smoke: COMPILE WITHOUT REQ + RESTORE -> FETCH -> PUBLISH PARITY OK
DRESS REHEARSAL: ALL CHECKS PASSED
soak: 1 test, 0 failures (434 excluded)
==> all requested stages finished
```

The required additional documentation/format checks also passed on the
sprite:

```text
$ mix format --check-formatted
(success; no output)

$ mix docs --warnings-as-errors
Generating docs...
View html docs at "doc/index.html"
View markdown docs at "doc/llms.txt"
View epub docs at "doc/Gitility.epub"
```
