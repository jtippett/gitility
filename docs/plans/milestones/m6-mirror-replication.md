# M6 — Mirror replication (`Gitility.Mirror`, `Gitility.ObjectStore`, `Repository.init_bare`)

Status: SPEC v1 (2026-08-21, draft for codex review). Design and the
decisions behind it: `docs/plans/2026-08-21-mirror-replication-design.md`.
Bundle format is FROZEN at 1.0 (`docs/format/bundle-v1.md`); this
milestone does not change it.

## 0. Ground rules (unchanged from M5a, load-bearing)

- NO BEAM on the dev Mac. All mix verification via
  `./scripts/remote-test.sh` on the sprite. Cargo tests run locally.
- Thread discipline: NO new thread-spawn sites. `scripts/check-thread-spawns.sh`
  must pass UNCHANGED. Object-store I/O is Elixir (Req/Finch pools are
  BEAM-side, not native threads).
- Credentials (S3 keys, session tokens, any `Authorization`) are
  radioactive: never in `Debug`/`Display`/`inspect`, error structs,
  result structs, log lines, or crash reports. §7 has the tests.
- No new required dependencies. `req` and `req_s3` are `optional: true`
  exactly like `postgrex`; `Gitility.ObjectStore.S3` carries
  `@compile {:no_warn_undefined, [Req, ReqS3]}` and returns a typed
  `:unsupported_operation` ("add :req and :req_s3 to deps") from
  `init/1` when they are not loaded.
- gitility never runs gc/repack/prune-packs on any path. Fetch stays
  append-only (packs never rewritten or deleted; prune deletes refs
  only).

## 1. Elixir API

### 1.1 `Gitility.ObjectStore` (behaviour)

```elixir
@type state :: term
@type key :: binary          # opaque, consumer-chosen, non-empty, valid UTF-8, no leading "/"
@type etag :: binary
@type metadata :: %{optional(binary) => binary}   # string keys AND values
@type head :: %{etag: etag, size: non_neg_integer, metadata: metadata}

@callback init(init_arg :: term) :: {:ok, state} | {:error, term}
@callback head(state, key, opts :: keyword) :: {:ok, head} | {:error, :not_found | term}
@callback get(state, key, dest_path :: Path.t(), opts :: keyword) ::
            {:ok, %{etag: etag, bytes: non_neg_integer, metadata: metadata}} | {:error, :not_found | term}
@callback put(state, src_path :: Path.t(), key, opts :: keyword) ::
            {:ok, %{etag: etag}} | {:error, :precondition_failed | term}
```

`opts` for every callback contains `timeout: non_neg_integer` (ms,
remaining budget — MUST be honoured; a callback exceeding it by more
than a grace of 1 s is a conformance failure) and, for `put`,
`if_match: etag | :none` (`:none` = create-only), `metadata: metadata`,
`content_type: binary` (always `"application/vnd.gitility.bundle"`).
`get` MUST stream to `dest_path` (no full body in memory; conformance
asserts a process-heap delta < 16 MiB on a 64 MiB object) and MUST
write through a sibling temp file + rename so a partial download never
occupies `dest_path`. `put` MUST be atomic from the reader's view: a
concurrent `get` sees the old object or the new one, never a mix. Any
`{:error, term}` other than the typed atoms is opaque to `Mirror` and
is wrapped (§1.4).

### 1.2 `Gitility.ObjectStore.Local`

`init_arg = [root: Path.t()]`. Objects at `root/<key>` (keys containing
`..` segments → `{:error, :invalid_key}` from every callback);
metadata in `root/<key>.meta` (Erlang term file, string map); etag =
lowercase hex sha256 of content. `put`: write `root/<key>.tmp-<random>`,
then under a per-key `:global`-free file lock (`File.open(lock, [:write,
:exclusive])` with bounded retry within `timeout`) check the
precondition against the current etag, then rename data and meta.
`if_match: :none` with an existing key → `:precondition_failed`.
Stale-etag `if_match` → `:precondition_failed`. Used by the normal test
suite; also a supported adapter.

### 1.3 `Gitility.ObjectStore.S3`

`init_arg` keys: `bucket` (required), `region` (required),
`access_key_id`, `secret_access_key` (required unless `credentials:`
0-arity fun returning `%{access_key_id, secret_access_key, session_token}`
— called per request, same shape as fetch providers), `session_token`
(optional), `endpoint_url` (optional; minio/Tigris/R2),
`path_style: boolean` (default false; minio needs true),
`req_options: keyword` (merged last, documented as escape hatch).
`init/1` validates, stores credentials in a closure inside `state`, and
`state` implements `Inspect` printing only bucket/region/endpoint.

- `head` → `HeadObject`; 404 → `:not_found`; returns quoted-etag
  stripped of quotes; metadata from `x-amz-meta-*` (prefix removed,
  keys lowercased).
- `get` → `GetObject` streamed (`into: File.stream!(tmp)` via Req's
  `into:` collectable); size mismatch vs `Content-Length` → error.
- `put` → single `PutObject` from `File.stream!(src_path, 1 MiB)` with
  `Content-Length`, `Content-Type`, `x-amz-meta-*`, and `If-Match: "<etag>"`
  or `If-None-Match: *`. HTTP 412 → `:precondition_failed`. 409 (S3
  returns 409 ConditionalRequestConflict under concurrent conditional
  writes) → `:precondition_failed` too. Object > 5 GiB →
  `{:error, {:unsupported_operation, "single PUT limit is 5 GiB"}}`
  before any network I/O (multipart is a documented follow-up).
- Every request: `receive_timeout` and `pool_timeout` derived from
  `opts[:timeout]`; `retry: false` (Mirror/caller owns retry policy).
- Errors are `{:error, {:http, status, code_string_from_body | nil}}` or
  `{:error, {:transport, reason}}`; NEVER include request headers or
  the URL query string (presigned or not) in the reason.

### 1.4 `Gitility.Mirror`

```elixir
@spec publish(Path.t(), {module, term}, binary, keyword) ::
        {:ok, Gitility.Mirror.Receipt.t()} | {:ok, :not_newer} | {:error, Gitility.Error.t()}
@spec restore({module, term}, binary, Path.t(), keyword) ::
        {:ok, Gitility.Mirror.Restore.t()} | {:error, Gitility.Error.t()}
```

Options (both): `timeout` (ms, default 600_000, absolute for the whole
call including local bundle write/verify), `runtime` (passed to
`Bundle.write`'s engine — see §3). `publish` only: `source_identity`
(binary; default `"mirror:" <> Path.basename(mirror_dir)` — the format
requires the key and a default that never embeds a URL/token is the
safe choice), `created_at` (RFC3339 or omitted), `git_executable`
(forwarded to `Bundle.write`; only used when loose objects exist).
`restore` only: none beyond the shared two.

Structs:

```elixir
%Gitility.Mirror.Receipt{generation, etag, bytes, tips_digest, ref_count, file_count}
%Gitility.Mirror.Restore{generation, etag, bytes, tips_digest, ref_count, file_count}
```

Error wrapping: adapter `{:error, term}` → `%Gitility.Error{code:
:backend_error, retryable: r, operation: :publish | :restore, cause:
term}` where `r = true` for `{:transport, _}` and 5xx/429, `false`
otherwise. Typed outcomes: `:not_found` (restore only; new error code —
add `not_found` to `@codes`, message "no object at key"), `:conflict`
(new code; "object at key changed during publish"), `:malformed_bundle`
(new code; used by restore when `Bundle.verify` fails — wraps the verify
error as `cause`), `:invalid_argument`, `:unsupported_operation`,
`:timeout`, `:busy`. New codes are appended to `@codes` and documented
in `Gitility.Error`.

### 1.5 `Gitility.Repository.init_bare/2`

`@spec init_bare(Path.t(), keyword) :: :ok | {:error, Gitility.Error.t()}`.
Options: `hash: :sha1` (default; `:sha256` → `:unsupported_hash`).
Creates `path` (mkdir_p the parent; directory itself must not exist or
must be empty — else `:invalid_argument`), native init (§3), then the
config keys of §2. Idempotency is NOT provided: a second call on the
now-non-empty dir is `:invalid_argument`.

## 2. gc-safe bare directories (contract)

Every bare directory gitility CREATES — via `init_bare/2`, via
`Fetch.fetch` auto-init of a missing/empty dest, and via
`Mirror.restore` — has these keys in `$GIT_DIR/config` on return:

```
[gc]
	auto = 0
[maintenance]
	auto = false
[receive]
	autogc = false
```

Written natively through `gix::config::File` (open the repo's local
config file, `set_raw_value` ×3, `write_to` the file with a temp+rename)
— NOT by shelling out, NOT by string-appending to the config. gitility
never touches the config of a directory it did not create; the `Fetch`
moduledoc states both halves. Test: `git config --get gc.auto` == `0`
on each of the three creation paths, and `git gc --auto` on the result
exits 0 having created no new pack (pack count unchanged).

## 3. Native surface (Rust, `crates/gitility-core`)

One new job/NIF, no new runtime, no new threads:

- `repo_init_bare(path, hash)`: extracted from `fetch.rs`'s
  `open_or_init_bare` initialise branch into `repo_init.rs`
  (`init_bare(path) -> Result<gix::Repository, Error>`) PLUS the §2
  config write; `open_or_init_bare` calls it so fetch auto-init gets
  the config for free. Exposed as a plain synchronous NIF (it is
  sub-millisecond filesystem work; no job/runtime involvement) named
  `repo_init_bare/2` in `Gitility.Native`, with the standard
  `NativeSupport` error mapping. SHA-256 requested → `UnsupportedHash`
  before touching the filesystem.
- Restore's ref writing uses the EXISTING ref-transaction path from
  fetch (`fetch.rs` ref update machinery) factored into a shared
  `refs::write_refs(repo, Vec<(name, target)>)` that performs ONE
  `gix_ref::transaction` with `PreviousValue::MustNotExist` for every
  edit (a restore target is always freshly initialised) and one
  symbolic edit for `HEAD` when `head_symref` is given. Exposed as
  `repo_write_refs/3` (sync NIF; bounded by the ref count the bundle
  TOC already validated against `max_toc_len`). Names are validated by
  `gix_validate::reference::name` → `:malformed_ref`.
- Pack/idx materialisation is Elixir file copying out of the verified
  bundle (streaming `:file.sendfile`/`IO.binstream` per section into
  `objects/pack/pack-<checksum>.{pack,idx}`), followed by
  `Repository.open(mirror_dir, require_bare: true)` as a smoke check
  that gix indexes the packs. No native involvement.
- `Bundle.write` gains an explicit `generation: pos_integer` option
  (default: current behaviour = next generation of any file at `path`).
  When given AND a file exists at `path` with generation ≥ the given
  one → `:invalid_argument` (format rule "generation increases by at
  least 1 over the file being replaced" is preserved).

## 4. publish/4 algorithm (Elixir, `lib/gitility/mirror.ex`)

1. Validate: `mirror_dir` is an existing directory; `key` per §1.1;
   `store = {module, init_arg}` with `module` exporting the four
   callbacks; opts via `Keyword.validate!`. `deadline = now + timeout`.
2. `Locks.acquire(Path.expand(mirror_dir), timeout)` — the SAME
   `Gitility.Fetch.Locks` instance and key shape fetch uses, so fetch
   and publish on one mirror serialise. `:busy`/`:timeout` per fetch's
   semantics. Release in `after` (held until terminal).
3. `module.init(init_arg)` → state (error → `:invalid_argument` with
   the adapter reason as `cause` unless it is `{:unsupported_operation,
   msg}` → that code).
4. `head(state, key, timeout: remaining)`: `{:ok, h}` → `remote_gen =
   parse_int(h.metadata["generation"])` (missing/unparsable → treat as
   `0` and log nothing; the etag still protects us), `remote_digest =
   h.metadata["tips_digest"]`, `if_match = h.etag`. `:not_found` →
   `remote_gen = 0`, `remote_digest = nil`, `if_match = :none`.
5. `tmp = "#{Path.expand(mirror_dir)}.publish-#{random_hex(8)}.tmp"`,
   created 0600 by `Bundle.write(tmp, source: {:repository, mirror_dir},
   generation: remote_gen + 1, source_identity:, publisher: "gitility
   #{vsn}", created_at:, git_executable:)`. A shallow source or any
   write error propagates unchanged (write's own typed errors).
6. `{:ok, toc} = Bundle.Format.parse(tmp)`; `tips_digest =
   sha256_hex(Enum.sort(for r <- toc.refs, do: "#{r.name} #{hex(r.target)}\n"))`.
   Pure function `Mirror.tips_digest/1` over the ref rows, unit-tested
   against a fixed vector.
7. `tips_digest == remote_digest` → `{:ok, :not_newer}` (tmp removed).
8. `put(state, tmp, key, if_match:, metadata: %{"generation" =>
   Integer.to_string(gen), "tips_digest" => digest, "format" =>
   "gitility-bundle/1.0"}, content_type:, timeout: remaining)`.
   `{:ok, %{etag}}` → `{:ok, %Receipt{...}}`. `:precondition_failed` →
   ONE re-`head`: `:not_found` or digest ≠ ours → `:conflict`; digest
   equal → `:not_newer`. Any other error → `:backend_error` wrap.
9. `after`: `File.rm(tmp)` always; on entry, sweep
   `#{Path.expand(mirror_dir)}.publish-*.tmp` older than 1 h (crash
   leftovers; same self-healing posture as PackFetch scratch).
10. Deadline checks between every step; exceeding → `:timeout` with the
   step named in `details`.

## 5. restore/4 algorithm

1. Validate as §4.1 except `mirror_dir` must NOT exist or must be an
   empty directory (`:invalid_argument` otherwise; NEVER clobber).
   `Path.expand` + lease exactly as publish.
2. `init`, then `tmp = "#{expanded}.restore-#{random_hex(8)}.tmp"`;
   `get(state, key, tmp, timeout:)`. `:not_found` → `{:error,
   %Error{code: :not_found}}`, no directory created.
3. `Bundle.verify(tmp)` — on error → `:malformed_bundle` (cause =
   verify's error), tmp removed. Then `Format.parse(tmp)` → `toc`.
   `toc.refs == []` → `:invalid_argument` ("restore requires a
   refs-carrying bundle; ODB-only bundles are PackFetch snapshots").
   `toc.hash_algorithm != :sha1` → `:unsupported_hash`.
   `toc.metadata["shallow_roots"]` present → `:unsupported_operation`
   (format rule).
4. `Repository.init_bare(mirror_dir)`; from here every failure runs
   `File.rm_rf!(mirror_dir)` before returning.
5. For each `file` in `toc.files`: stream the section bytes to
   `objects/pack/<basename>` via a sibling tmp + rename; pack and idx
   of one pair are both renamed before the next pair starts.
6. `Native.repo_write_refs(mirror_dir, [{name, oid} | ...],
   head_symref)`: every row of `toc.refs` except `HEAD` as a direct ref;
   `HEAD` symbolic to `toc.metadata["head_symref"]` when present AND
   that name is among the rows, direct to its recorded oid otherwise.
7. Smoke: `Repository.open(mirror_dir, require_bare: true)` +
   `Gitility.Repository.resolve(repo, "HEAD")` (or any ref if HEAD
   absent) must succeed → otherwise `:internal_error` and rm_rf.
8. `{:ok, %Restore{generation: toc.generation, etag:, bytes:,
   tips_digest: Mirror.tips_digest(toc.refs), ref_count:, file_count:}}`.
   `after`: tmp removed; sweep `*.restore-*.tmp` as in §4.9.

The result is an ordinary bare repository: `Fetch.fetch` into it must
behave exactly as into a mirror fetched from scratch (test §7.3).

## 6. Credential and key hygiene (tests required for each)

- `inspect(state)` of `ObjectStore.S3` shows no key material.
- Forced transport failure, 403, 412, and timeout paths: the
  `%Gitility.Error{}` (`inspect`, `message/1`, `details`, `cause`)
  contains neither the secret key, the session token, nor any
  `X-Amz-*` signature component. Assert with `refute =~` on a
  sentinel secret.
- Mirror never logs at any level above `:debug`, and debug lines carry
  only key + byte counts.
- `key` is validated before any adapter call; invalid → `:invalid_argument`.

## 7. Test infrastructure + matrix

All sprite-local. minio: add to `remote-test.sh` mix stage (download
the static binary once into `~/minio`, start on 127.0.0.1 with a random
port and scratch data dir, stop at the end; export
`GITILITY_MINIO_URL/KEY/SECRET` so S3 tests run; skip loudly when the
binary is unavailable). CI: `minio/minio` service container in the
test job with the same env.

### 7.1 Conformance (`Gitility.ObjectStore.Conformance`, `use`-able)

Rows: head missing → `:not_found`; put create-only then head returns
metadata round-trip + etag; create-only on existing → `:precondition_failed`;
if_match with current etag succeeds and changes etag; if_match stale →
`:precondition_failed`; get round-trip bytes identical (sha256) +
metadata; 64 MiB object get AND put with heap-delta assertion; timeout
of 1 ms on get of the 64 MiB object → error within 1 s + no partial
file at `dest_path`; concurrent 8-process create-only race → exactly
one `:ok`. Run against `Local` (always) and `S3` (when minio env set).

### 7.2 `test/milestone_6_mirror_test.exs`

1. publish fresh (key absent) → Receipt gen 1; `ObjectStore.head`
   metadata has generation "1" and a 64-hex digest; bundle at the key
   passes `Bundle.verify` after `get`.
2. publish again unchanged → `{:ok, :not_newer}`; no put occurred
   (Local adapter records call log in test mode / etag unchanged).
3. remote fetch gains commits → fetch → publish → gen 2, digest changed.
4. restore into fresh dir → `git fsck --strict` clean; `git for-each-ref`
   identical to the source mirror; `HEAD` symbolic to the same target;
   `git config gc.auto` == 0; pack files byte-identical to the source's.
5. restored mirror + incremental `Fetch.fetch` → result equal (refs,
   updated_refs) to a from-scratch fetch of the same remote state.
6. restore into non-empty dir → `:invalid_argument`, dir untouched.
7. restore missing key → `:not_found`, no dir.
8. corrupt object (flip one byte in the stored file) → `:malformed_bundle`,
   no dir, no tmp left.
9. ODB-only bundle (produce via PackFetch `into: {:bundle, _}`) →
   `:invalid_argument`.
10. two processes publish concurrently (Local) after divergent
    metadata → one Receipt, one `:conflict` or `:not_newer`, and the
    stored generation strictly increased by exactly 1.
11. publish while a fetch holds the lease → blocks, then proceeds;
    publish with a 1 ms timeout while held → `:timeout`.
12. init_bare on all three creation paths has the §2 keys; `git gc
    --auto` leaves pack count unchanged; init_bare on non-empty →
    `:invalid_argument`; `hash: :sha256` → `:unsupported_hash`.
13. `Bundle.write(generation: n)` explicit — respected on a fresh path,
    `:invalid_argument` when lower than or equal to the existing file's.
14. tips_digest fixed vector.
15. Hygiene tests of §6.

Oracle: pinned git 2.55 as in M5a.

### 7.3 Dress rehearsal

`bench/dress_rehearsal.exs` gains Flow D: fetch phoenix mirror →
publish to Local store → restore to a new dir → run the Flow A query
parity set against the restored mirror → incremental fetch → publish
again (`:not_newer` or gen+1, asserted by whether the remote moved).

## 8. Docs, changelog, packaging

- `Gitility.Mirror` moduledoc: the loop (restore → fetch → publish),
  the replication-not-shared-FS positioning, conditional-put
  semantics and what `:conflict`/`:not_newer` mean for a scheduler,
  the 5 GiB limit, tmp-file placement (sibling of the mirror, so same
  filesystem), lease sharing with fetch.
- `Gitility.ObjectStore` moduledoc: the contract of §1.1 incl. the
  atomicity and streaming MUSTs; how to run the conformance suite.
- `Gitility.ObjectStore.S3` moduledoc: deps to add, minio/Tigris/R2
  config examples, credential function, "conditional writes required".
- `Gitility.Fetch` moduledoc additions: append-only sentence; gc-safe
  auto-init contract; credential-helper-disarm as the headline
  paragraph; empty remote + wildcard → ok with `remote_ref_count: 0`.
- `Gitility.Repository` moduledoc: `init_bare/2`; ~700 ms first-query
  warmup note.
- Search docs: `**/glob` idiom example first. Diff docs: tiny-file
  rename threshold note. `history/…`: `since`/`until` → typed
  `:invalid_argument` naming the option (code change, small).
- README: "Replicating mirrors" section; live-fire numbers from the
  consumer (cold hydrate 2.65 s, list_tree/read_file < 1 ms, search 2 ms).
- CHANGELOG [Unreleased]: Added (Mirror, ObjectStore + S3 + Local,
  init_bare, `Bundle.write` `:generation`), Changed (gitility-created
  bare dirs are gc-safe; new error codes), Fixed (history typed error).
- `mix.exs`: `req ~> 0.5` and `req_s3 ~> 0.2` optional; hexdocs groups.
- `mix docs --warnings-as-errors` clean.

## 9. Definition of done

- `cargo test --workspace` green locally; `cargo clippy --workspace
  --all-targets` with zero warnings (CI denies them); spawn guard
  UNCHANGED; `--no-default-features` loom build still green.
- Sprite: full mix suite green, 12× loop on `milestone_6_mirror_test.exs`
  and the conformance files, minio conformance green, rehearsal ALL
  CHECKS PASSED including Flow D.
- CI green including the minio service.
- Opus adversarial review of the diff, findings fixed, re-verified on
  sprite.
- Consumer smoke: gentility session runs restore → fetch → publish
  against its own mirror with `ObjectStore.Local` and reports parity.
