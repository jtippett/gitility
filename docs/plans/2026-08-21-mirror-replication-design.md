# M6 — Mirror replication through an object store (`Gitility.Mirror`)

Status: DESIGN APPROVED by James 2026-08-21 (forks decided by
AskUserQuestion; detail delegated to fable). Consumer-validated by the
gentility CodeExplorer session the same day ("restore → fetch tops up →
publish is the loop we'd run"). Next: milestone spec
`docs/plans/milestones/m6-mirror-replication.md` → codex review rounds →
codex implementation → opus review → sprite verification.

## Why this and not the bundle republisher

The single-owner bundle republisher (M4c de-scope follow-up) was queued
as "consumer-demanded". Asked directly, the consumer has no bundle loop:
CodeExplorer fetches from GitHub into a bare mirror on a local volume and
reads it in place with `Repository.open` + `snapshot({:oid, sha})`. Its
real gap is **multi-node and cold start**: a new container, a lost
volume, or a second host means refetching every mirror from GitHub.

Decision (James): drop the republisher (no consumer) and solve the gap by
**replication, not shared storage**. Shared-POSIX-FS semantics (NFS/EFS
readers during a writer's fetch) are explicitly out of scope.

## Shape

The bundle file (`docs/format/bundle-v1.md`) becomes the wire and backup
format for bare mirrors. Nothing in production opens it; it is
materialised back into an ordinary bare repository, after which the
consumer's existing open/snapshot/fetch code is untouched.

```
publish:  mirror_dir --Bundle.write--> tmp file --conditional put--> store[key]
restore:  store[key] --get--> tmp file --Bundle.verify--> init_bare + packs + refs
loop:     restore (or :not_found → nothing) → Fetch.fetch tops up → publish
```

Public API (all plain functions; no owner processes — the consumer's
deploy model has no cross-node registry and it already owns scheduling
and cross-process locking):

```elixir
Gitility.Mirror.publish(mirror_dir, store, key, opts)
  :: {:ok, Gitility.Mirror.Receipt.t()} | {:ok, :not_newer} | {:error, Gitility.Error.t()}

Gitility.Mirror.restore(store, key, mirror_dir, opts)
  :: {:ok, Gitility.Mirror.Restore.t()} | {:error, Gitility.Error.t()}

Gitility.Repository.init_bare(path, opts)
  :: :ok | {:error, Gitility.Error.t()}

Gitility.ObjectStore            # behaviour
Gitility.ObjectStore.S3         # in-tree adapter, optional deps req + req_s3
Gitility.ObjectStore.Local      # in-tree adapter over a directory (tests, simple consumers)
Gitility.ObjectStore.Conformance  # ExUnit case template, like RangeBackend.Conformance
```

`store` is `{module, init_arg}` exactly like `RangeBackend`. Credentials
live inside `init_arg`, are never logged, and never appear in errors.

No Rust changes except `init_bare` config writing (see below). The NIF
stays network-free beyond gix; object-store I/O is Elixir.

## publish/4

1. Acquire the per-`Path.expand(mirror_dir)` lease from the same `Locks`
   process `Fetch` uses, so a publish never overlaps a fetch into the
   same mirror and the bundle is a consistent snapshot. Lease semantics
   identical to fetch (per-VM, bounded by `:timeout`, held until the
   work is terminal).
2. `head(store, key)` → `{:ok, %{etag, size, metadata}}` or
   `{:error, :not_found}`. Metadata carries `generation` and
   `tips_digest`.
3. `Bundle.write(tmp, source: {:repository, mirror_dir}, generation: g,
   ...)` where `g = remote.generation + 1` (1 when absent). `tmp` is a
   sibling of `mirror_dir` (`<mirror_dir>.publish-<random>.tmp`), 0600,
   always removed. Metadata written: `tips_digest` = hex sha256 over the
   sorted `"<refname> <oid>\n"` lines of the bundle's own ref section
   (including `HEAD`), `source_identity` (caller-supplied or omitted),
   `publisher = "gitility <version>"`, `created_at` only if supplied
   (format rule: timestamps are never synthesised).
4. If the remote `tips_digest` equals ours → `{:ok, :not_newer}`; no
   upload. This is the steady-state outcome of a scheduled publish after
   a no-op fetch, and it costs one HEAD request plus one local bundle
   write.
5. `put(store, tmp, key, if_match: etag | :none, metadata: %{...})`.
   `if_match: :none` means "create only" (If-None-Match: *).
   `{:error, :precondition_failed}` → one re-`head`: digest equal →
   `{:ok, :not_newer}`; otherwise `{:error, %Error{code: :conflict}}`.
   No internal retry loop — the caller's scheduler decides.
6. Return `%Receipt{generation, etag, bytes, tips_digest, ref_count}`.

"Generation" here is the bundle header's u64 (`>= 1`, strictly
increasing per key); the format's own rule is preserved because every
publish reads the remote generation first under If-Match.

Loose objects: `Bundle.write` still shells out to git to pack loose
objects. A gix-fetched mirror contains none, so the replication loop is
git-binary-free. `publish` accepts `:git_executable` and forwards it for
mirrors that do have loose objects; that is the only place git can run.

## restore/4

1. Lease on `mirror_dir`. If `mirror_dir` exists and is non-empty →
   `:invalid_argument` (never clobber — same rule as fetch's auto-init).
2. `get(store, key, tmp)` streams the object to a sibling tmp file.
   `{:error, :not_found}` → `{:error, %Error{code: :not_found}}` with no
   filesystem side effects; the consumer falls through to a plain fetch.
3. `Bundle.verify(tmp)` — format parse plus every section's sha256.
   Corrupt → `:malformed_bundle`, tmp removed, mirror absent. Refs
   section required: an ODB-only bundle (PackFetch output) →
   `:invalid_argument` ("restore requires a refs-carrying bundle").
4. `init_bare(mirror_dir)` (below), then for each pack/idx pair: write
   `objects/pack/pack-<checksum>.{pack,idx}` by streaming the section
   out of the bundle; then one gix-ref transaction creating every ref
   from the ref section with `HEAD` as a symbolic ref to `head_symref`
   when present (direct otherwise). Annotated tags restore to the tag
   object oid (peeled value is not needed for a real ODB).
5. Any failure after step 4 starts → `rm -rf mirror_dir` (it was ours to
   create), tmp removed, error returned. Success → `%Restore{generation,
   ref_count, bytes, tips_digest}`. A restored mirror is byte-for-byte
   a valid input to `Fetch.fetch` and `Repository.open`.

Hash family: bundle hash family must be SHA-1 (gix 0.86 cannot open
SHA-256 repositories; same `:unsupported_hash` classification fetch
uses).

## init_bare/2 and gc-safe auto-init

`Repository.init_bare(path, opts)`: native gix init (Bare, isolated),
then write into the repository config:

```
[gc]          auto = 0
[maintenance] auto = false
[receive]     autogc = false
```

`Fetch.fetch`'s auto-init of a missing/empty dest writes the same three
keys. Documented contract: **a bare directory created by gitility is
gc-safe without further action**; gitility never mutates the config of a
directory it did not create, and never runs gc/repack itself. Snapshot
validity across fetches rests on "fetch is append-only: packs are never
rewritten or deleted, prune deletes refs only" — that sentence goes in
the `Fetch` moduledoc verbatim.

`path` exists and non-empty → `:invalid_argument`. Options: `:hash`
(`:sha1` only in this milestone; `:sha256` → `:unsupported_hash`).

## ObjectStore behaviour

```elixir
@callback init(init_arg) :: {:ok, state} | {:error, term}
@callback head(state, key) ::
  {:ok, %{etag: binary, size: non_neg_integer, metadata: %{optional(binary) => binary}}}
  | {:error, :not_found | term}
@callback get(state, key, dest_path, opts) :: {:ok, %{etag: binary, bytes: non_neg_integer}} | {:error, :not_found | term}
@callback put(state, src_path, key, opts) :: {:ok, %{etag: binary}} | {:error, :precondition_failed | term}
  # opts: if_match: etag | :none, metadata: map, content_type: binary
```

Keys are opaque binaries chosen by the consumer. Metadata values are
strings (S3 `x-amz-meta-*` constraint); `Mirror` only stores
`generation` and `tips_digest`. Adapter errors are wrapped into
`%Gitility.Error{code: :backend_error, retryable: bool}` by `Mirror`,
with the adapter's reason kept structured but never containing request
headers. Timeouts: `Mirror` passes the remaining budget of its single
absolute `:timeout` to each callback via `opts[:timeout]`; adapters
must honour it.

`ObjectStore.S3`: `init_arg` = `[bucket:, region:, endpoint_url:
(optional, for minio/Tigris/R2), access_key_id:, secret_access_key:,
session_token: (optional)]` → `ReqS3` with sigv4. `put` uses a single
`PutObject` with `If-Match` / `If-None-Match: *` and `x-amz-meta-*`
headers; conditional writes are available on AWS S3 (since 2024), minio,
R2, and Tigris. **Limit, stated honestly:** single PUT ≤ 5 GiB; a larger
bundle returns `:unsupported_operation` naming the limit. Multipart
upload is a follow-up, not v1 (the consumer's mirrors are tens of MB;
the M4 rehearsal corpus was 26 MB).

`ObjectStore.Local`: a directory; etag = sha256 of content; `put` is
write-tmp + rename with the conditional check under a per-key file lock.
Used by the conformance suite, by unit tests everywhere, and it is a
legitimate adapter for "restore from a file on a volume".

`ObjectStore.Conformance`: `use`-able ExUnit template (mirrors
`RangeBackend.Conformance`): head on missing key, put-create, put
create-only conflict, put If-Match success and `:precondition_failed`
on stale etag, get round-trip bytes + metadata, large-ish object
streaming (≥ 64 MiB, no full-body in memory — asserted via process
memory delta), timeout propagation. Runs against `Local` in the normal
suite and against minio on the sprite and in CI (docker service).

## Failure modes, in one table

| situation | publish | restore |
|---|---|---|
| key absent | create with If-None-Match | `:not_found`, no side effects |
| remote newer/equal tips | `:not_newer` | n/a |
| lost race on put | one re-head → `:not_newer` or `:conflict` | n/a |
| corrupt object | n/a (local write verified by format) | `:malformed_bundle`, mirror absent |
| ODB-only bundle | n/a | `:invalid_argument` |
| mirror dir non-empty | fine (it is the source) | `:invalid_argument` |
| timeout mid-transfer | tmp removed, remote unchanged (PUT is atomic) | tmp removed, mirror dir removed |
| caller dies | lease held until terminal, tmp swept by next publish on that path | same |
| adapter error | `:backend_error` with retryable flag | same |

## Testing

- `test/milestone_6_mirror_test.exs` (sprite-local, no external network):
  publish/restore round-trip vs `git fsck` + ref oracle on the restored
  mirror; restored mirror accepts an incremental `Fetch.fetch` and the
  result matches a mirror that was fetched from scratch; `:not_newer`
  steady state; concurrent publishers from two processes (Local store)
  → exactly one `:conflict`/`:not_newer`, generation strictly increasing;
  corrupt-object restore leaves no directory; restore refuses
  non-empty dir; init_bare config keys present and `git gc --auto` is a
  no-op on the result; publish under fetch lease waits.
- Conformance suite against Local (always) and minio (sprite + CI).
- Dress rehearsal flow D added to `bench/dress_rehearsal.exs`:
  fetch → publish → restore elsewhere → query parity.

## Out of scope (recorded)

Multipart upload (> 5 GiB bundles); shared-FS reader/writer semantics;
opening bundles directly in production; owner processes or schedulers;
GC/repack of mirrors; SHA-256 repositories (gix 0.86 limitation);
restore into a non-empty mirror (incremental restore).

## Docs pass bundled into M6

From the consumer's 2026-08-20/21 notes: credential-helper disarm as a
headline in `Fetch`; "fetch is append-only" sentence; ~700 ms first-query
warmup after `Repository.open`; the `**/glob` pathspec idiom
prominently in search docs; tiny-file rename detection falls below the
similarity threshold (matches git); wildcard refspec matching nothing
on an empty remote is `{:ok, remote_ref_count: 0}`; `history`
rejecting `since`/`until` becomes a lib-side typed `:invalid_argument`
naming the option.
