# M6 — Mirror replication (`Gitility.Mirror`, `Gitility.ObjectStore`, `Repository.init_bare`)

Status: SPEC v2 (2026-08-21; v1 → v2 after codex review round 1: 12
blockers, 14 highs, 7 mediums, 2 lows). Design:
`docs/plans/2026-08-21-mirror-replication-design.md`. Bundle format is
FROZEN at 1.0 (`docs/format/bundle-v1.md`); this milestone does not
change it.

## Design amendments recorded by this spec (supersede the design doc)

- D1. Rust surface is TWO sync NIFs, not "init only": `repo_init_bare/2`
  and `repo_write_refs/3` (§3). Both filesystem-bound, both `DirtyIo`.
- D2. `req_s3` is DROPPED. The S3 adapter uses Req's built-in
  `aws_sigv4` step and builds URLs itself (§1.3). Only `req` is the
  optional dependency.
- D3. Zero-ref bundles restore fine (an empty mirror is a legal
  source; the frozen format gives zero refs no meaning). There is no
  "ODB-only refusal".
- D4. ObjectStore callbacks are `head/3`, `get/4`, `put/4` (all take
  `opts`), and `get` returns metadata. No `terminate/2`: adapter state
  must hold no resources needing cleanup (Req uses the shared Finch
  pool; Local uses a supervised server keyed by root).
- D5. `timeout` bounds the object-store phases plus the local wait;
  the local `Bundle.write`/`verify` and native ref write run to
  completion (they are bounded by the mirror's size and the TOC cap,
  not by the network). Stated in docs. §4.10/§5.9.
- D6. Lease: contended publish/restore return `:busy` IMMEDIATELY, like
  fetch. No waiting acquire. The consumer owns scheduling.

## 0. Ground rules (unchanged from M5a, load-bearing)

- NO BEAM on the dev Mac. All mix verification via
  `./scripts/remote-test.sh` on the sprite. Cargo tests run locally.
- Thread discipline: NO new thread-spawn sites. `scripts/check-thread-spawns.sh`
  must pass UNCHANGED. Object-store I/O is Elixir (Finch pools are
  BEAM-side).
- Credentials (S3 keys, session tokens, signatures) are radioactive:
  never in `Inspect`, error structs, result structs, `cause`, log
  lines, or crash reports. §6 has the tests.
- No new REQUIRED dependencies. `req ~> 0.5` is `optional: true`
  exactly like `postgrex`. `Gitility.ObjectStore.S3` contains NO
  `%Req.*{}` struct literals or pattern matches (they would not compile
  without the dep): it calls `Req.new/1`, `Req.request/2` via
  `apply/3`-free but fully-qualified dynamic calls guarded by
  `Code.ensure_loaded?(Req)` in `init/1` (→ `:unsupported_operation`
  "add {:req, \"~> 0.5\"} to deps"), and matches responses as plain maps
  (`%{status: s, headers: h, body: b}`), exceptions via
  `Exception.message/1` on `is_exception/1`. `@compile {:no_warn_undefined,
  Req}` on top. Test §7.4 compiles a scratch consumer WITHOUT req.
- Public validation NEVER raises (M5a rule): manual validation of
  option lists (proper list, known keys, types, ranges) returning
  `{:error, %Error{code: :invalid_argument}}`. No `Keyword.validate!`.
- gitility never runs gc/repack on any path. Fetch stays append-only
  (packs never rewritten or deleted; prune deletes refs only).
- `Error.cause` is SANITIZED: never an arbitrary adapter/provider term.
  §1.4 defines the allowed shapes.

## 1. Elixir API

### 1.1 `Gitility.ObjectStore` (behaviour)

```elixir
@type state :: term
@type key :: binary      # see key rules below
@type etag :: binary     # opaque, non-empty
@type metadata :: %{optional(binary) => binary}   # string keys and values
@type head :: %{etag: etag, size: non_neg_integer, metadata: metadata}

@callback init(init_arg :: term) :: {:ok, state} | {:error, reason}
@callback head(state, key, opts :: keyword) :: {:ok, head} | {:error, :not_found | reason}
@callback get(state, key, dest_path :: Path.t(), opts :: keyword) ::
            {:ok, %{etag: etag, bytes: non_neg_integer, metadata: metadata}} | {:error, :not_found | reason}
@callback put(state, src_path :: Path.t(), key, opts :: keyword) ::
            {:ok, %{etag: etag}} | {:error, :precondition_failed | reason}

@type reason ::
        {:unsupported_operation, binary}
      | {:invalid_key, binary}
      | {:transport, atom}                 # e.g. :timeout, :econnrefused, :closed
      | {:http, 100..599, binary | nil}     # status + provider error code string (e.g. "AccessDenied"), never body text
      | {:adapter, atom}                   # adapter-defined classification atom; no payload
```

Any other `{:error, term}`, a raise/throw/exit, or a malformed return
from a callback is classified by `Mirror` as `{:adapter, :bad_return}`
/ `{:adapter, :exception}`; the original term is DROPPED (not logged,
not retained — only the classification survives).

Key rules (validated by `Mirror` BEFORE any callback, and re-validated
by adapters): non-empty, valid UTF-8, ≤ 1024 bytes, no NUL, no leading
`/`, no `.` or `..` path segments, no empty segments (`//`), no
trailing `/`. Violations → `:invalid_argument` from Mirror;
`{:invalid_key, _}` from adapters.

`opts` for every callback: `timeout: pos_integer` (ms remaining —
adapters MUST bound the call; `Mirror` additionally hard-bounds it,
§4.10) and, for `put`: `if_match: etag | :none` (`:none` = create-only),
`metadata: metadata` (keys `[a-z0-9_-]+`, ≤ 32 keys, values ≤ 256
bytes, header-safe: no CR/LF/control bytes), `content_type: binary`
(always `"application/vnd.gitility.bundle"`).

MUSTs: `get` streams to `dest_path` through a sibling temp + rename (a
partial download never occupies `dest_path`); `put` is old-or-new from
any reader's view; `head`/`get` metadata is exactly what `put` stored.

### 1.2 `Gitility.ObjectStore.Local`

`init_arg = [root: Path.t()]` (`root` created if missing, 0700).
Single-VM adapter: correctness relies on a per-root server, not on
filesystem locks.

Layout (collision-free, keys never touch the filesystem namespace):

```
root/objects/<sha256hex(key)>/current          # 64-hex pointer → a version dir name
root/objects/<sha256hex(key)>/v-<64 random hex>/data
root/objects/<sha256hex(key)>/v-<64 random hex>/meta   # see encoding below
root/objects/<sha256hex(key)>/key                # the original key bytes (debug aid only)
```

`meta` = `:erlang.term_to_binary(%{"etag" => etag, "size" => n,
"metadata" => map})`; decoded with `binary_to_term(bytes, [:safe])`
after a ≤ 64 KiB size check, then shape-validated (binary→binary map,
integer size); anything else → `{:adapter, :corrupt_meta}`.
`etag` = lowercase hex sha256 of `data`.

Serialisation: `Gitility.ObjectStore.Local.Server`, one GenServer per
expanded root, started on demand under
`Gitility.ObjectStore.Local.Supervisor` (a `DynamicSupervisor` added to
the application tree) and registered in a `Registry` keyed by root.
`put`: (1) outside the server, write `v-<rand>/data` (from `src_path`,
0600) and `meta`; (2) `GenServer.call(server, {:commit, hash,
if_match, version})` — the server reads `current`, checks the
precondition, writes `current.tmp` + `rename` → `current`, replies;
(3) on `:precondition_failed` the caller deletes its version dir.
`get`/`head`: read `current` (absent → `:not_found`), then the version
files — immutable versions give old-or-new. Sweep: every commit deletes
version dirs not referenced by `current` and older than 1 h. Calls
carry `opts[:timeout]` as the `GenServer.call` timeout; a timeout →
`{:transport, :timeout}`. Keys in test mode: the adapter supports a
`test_hooks: %{before_commit: (-> :ok)}` init option (used by §7.2.10).

### 1.3 `Gitility.ObjectStore.S3`

`init_arg`:

```elixir
[
  bucket: binary,                  # required; 3..63 chars, [a-z0-9.-], no "..", no leading/trailing "." or "-"
  region: binary,                  # required
  credentials: map | (-> map),     # required; %{access_key_id, secret_access_key, session_token (optional)}
  endpoint_url: binary | nil,      # optional; scheme+host[:port] ONLY — userinfo/path/query/fragment → :invalid_argument
  addressing: :virtual_host | :path,   # default :virtual_host; :path required for minio/most self-hosted
  finch: atom | nil                # optional Finch pool name
]
```

No `req_options` escape hatch (rejected by review: it let a caller
re-enable redirects or logging). `state` = `%S3{bucket, region, host,
scheme, port, addressing, finch, credentials_fun}` where
`credentials_fun` is a 0-arity closure; `Inspect` prints only bucket,
region, endpoint host, addressing.

Credential provider boundary (copied from `Fetch.authorization_for/3`,
`lib/gitility/fetch.ex:126`): a map is wrapped in a fun; the fun is
invoked per request in a `Task` with `rescue`/`catch`, awaited under
the remaining timeout; exception/throw/exit/bad shape →
`{:adapter, :credentials_unavailable}` (no payload); timeout →
`{:transport, :timeout}`. Returned map must have non-empty binary
`access_key_id` and `secret_access_key`, optional binary
`session_token`.

URL construction (explicit, no library):
- virtual-host: `https://<bucket>.s3.<region>.amazonaws.com/<enc(key)>`
  (or `<scheme>://<bucket>.<host>[:port]/<enc(key)>` with endpoint_url;
  dotted bucket names with `:virtual_host` → `:invalid_argument`,
  "use addressing: :path");
- path: `<scheme>://<host>[:port]/<bucket>/<enc(key)>`.
- `enc/1` percent-encodes every byte outside `A-Za-z0-9-_.~/` (RFC 3986
  unreserved plus `/`), so spaces, `%`, `?`, `#`, `+`, Unicode are
  escaped; `/` is kept as a separator. Test vectors in §7.1.

Requests, all via `Req.new/1` + `Req.request/2` with EXACTLY these
options, applied by us last so nothing can override them:
`redirect: false`, `retry: false`, `decode_body: false`,
`compressed: false`, `receive_timeout: remaining`, `pool_timeout:
min(remaining, 5_000)`, `connect_options: [timeout: min(remaining,
20_000)]`, `aws_sigv4: [service: "s3", region:, access_key_id:,
secret_access_key:, token: session_token]` (Req's key for the session
token is `token`), `finch:` when given, and the `x-amz-content-sha256`
header Req computes for sigv4 (unsigned payload for streamed PUT is
NOT used — we pass `body: File.stream!(src, 1_048_576)` and Req sigv4
signs with `UNSIGNED-PAYLOAD` for enumerable bodies; the implementer
verifies in `deps/req/lib/req/steps.ex` `put_aws_sigv4` that streaming
bodies are supported by the pinned version and, if not, falls back to
reading the file in 8 MiB chunks via `Req`'s `body: {:stream, ...}`
equivalent or documents the limit — this is the ONE open
implementation check; record the answer in the implementation notes).
A 3xx response is an error `{:http, status, nil}` (never followed).
Every call is additionally wrapped in the deadline task of §4.10, so a
slow-drip server cannot exceed the budget.

- `head` → `HEAD`; 404 → `:not_found`; 200 → etag (quotes stripped),
  size from `content-length`, metadata from `x-amz-meta-*` (prefix
  removed, keys lowercased).
- `get` → `GET` with `into: fn` collecting into an open 0600 temp
  file (sibling of `dest_path`), then `rename`; 404 → `:not_found`;
  byte count ≠ `content-length` → `{:adapter, :short_body}`; returns
  metadata from the response headers.
- `put` → `PUT` with `Content-Length` (file size), `Content-Type`,
  `x-amz-meta-<k>: v` per metadata entry, and `If-Match: "<etag>"` or
  `If-None-Match: *`. 412 → `:precondition_failed`; 409 with body code
  `ConditionalRequestConflict` → `:precondition_failed`; other 409 →
  `{:http, 409, code}`. Size > `5_368_709_120` bytes (5 GiB, AWS's
  single-PUT maximum) → `{:unsupported_operation, "single PUT limit is
  5 GiB (5368709120 bytes); multipart upload is not implemented"}`
  before any network I/O.
- Error mapping: transport exceptions → `{:transport, reason_atom}`
  (`Exception.message/1` NEVER retained); non-2xx → `{:http, status,
  code}` where `code` is the `<Code>` element parsed from the XML body
  with a tolerant regex (`~r/<Code>([A-Za-z0-9]+)<\/Code>/`) or nil.
  Response headers and URLs are never placed in any error.

### 1.4 `Gitility.Mirror`

```elixir
@spec publish(Path.t(), {module, term}, binary, keyword) ::
        {:ok, Gitility.Mirror.Receipt.t()} | {:ok, :not_newer} | {:error, Gitility.Error.t()}
@spec restore({module, term}, binary, Path.t(), keyword) ::
        {:ok, Gitility.Mirror.Restore.t()} | {:error, Gitility.Error.t()}
```

Options, validated manually (§0):
- both: `timeout` — integer 1..86_400_000 ms, default 600_000.
- publish: `source_identity` (binary, ≤ 1024 bytes, default
  `"mirror:" <> Path.basename(expanded_mirror_dir)`), `created_at`
  (binary, forwarded; omitted by default), `git_executable` (binary,
  forwarded to `Bundle.write`).

Structs:

```elixir
%Gitility.Mirror.Receipt{generation, etag, bytes, tips_digest, ref_count, file_count}
%Gitility.Mirror.Restore{generation, etag, bytes, tips_digest, ref_count, file_count}
```

Error codes (new: `not_found`, `conflict`, `malformed_bundle`). Adding
a code means ALL of: `lib/gitility/error.ex` `@codes` + moduledoc
table; `crates/gitility-core/src/error.rs` `ErrorCode` variant,
`all()`, `as_str()` (+ any `from_str`), and the exhaustive
`all_contains_every_variant_once` test; `test/error_test.exs`
documented list; the native/Elixir equality assertion in
`test/milestone_1c_query_test.exs:431`. Messages: `not_found` "no
object at key"; `conflict` "object at key changed during publish";
`malformed_bundle` "downloaded object is not a valid bundle".

Normalisation table (phase → adapter reason → `%Error{}`):

| phase | reason | code | retryable | cause |
|---|---|---|---|---|
| init | `{:unsupported_operation, m}` | `:unsupported_operation` (message m) | false | nil |
| init | anything else | `:invalid_argument` "object store init failed" | false | `{:adapter, :init}` |
| any | `{:invalid_key, _}` | `:invalid_argument` | false | nil |
| any | `{:transport, a}` | `:backend_error` | true | `{:transport, a}` |
| any | `{:http, s, c}` 5xx/429/408 | `:backend_error` | true | `{:http, s, c}` |
| any | `{:http, 401/403, c}` | `:authentication_failed` | false | `{:http, s, c}` |
| any | `{:http, other, c}` | `:backend_error` | false | `{:http, s, c}` |
| any | `{:adapter, :credentials_unavailable}` | `:credentials_unavailable` | false | nil |
| any | `{:adapter, a}` | `:backend_error` | false | `{:adapter, a}` |
| get | `:not_found` | `:not_found` | false | nil |
| put | `:precondition_failed` | handled (§4.8) | | |

`cause` is therefore always one of: nil, `{:transport, atom}`,
`{:http, int, binary | nil}`, `{:adapter, atom}`. Nothing else, ever.

### 1.5 `Gitility.Repository.init_bare/2`

`@spec init_bare(Path.t(), keyword) :: :ok | {:error, Gitility.Error.t()}`.
Options: `hash: :sha1` (default; `:sha256` → `:unsupported_hash`
before touching the filesystem). `path` must not exist or must be an
empty directory (else `:invalid_argument`); the parent is created
(`mkdir_p`). Not idempotent. Runs the §3 NIF on a dirty IO scheduler.

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

Written natively: open the repository's local config as
`gix::config::File` (`repo.config_snapshot_mut()` / or load the
`config` file with `gix::config::File::from_path_no_includes`),
`set_raw_value` ×3, serialise with `write_to` into `config.tmp`, then
rename over `config`. gitility never touches the config of a directory
it did not create; the `Fetch` moduledoc states both halves. Test: on
each of the three creation paths `git config --get gc.auto` == `0`,
`maintenance.auto` == `false`, `receive.autogc` == `false`, and `git
gc --auto` exits 0 with the pack count unchanged.

## 3. Native surface (Rust, `crates/gitility-core` + NIF crate)

Two synchronous NIFs, both `#[rustler::nif(schedule = "DirtyIo")]`
(pattern: the existing blocking NIFs in the NIF crate `lib.rs`), both
behind `#[cfg(feature = "fetch")]` in core because they use gix (loom
builds are `--no-default-features`); the Elixir side returns
`:unsupported_operation` "native fetch feature disabled" when the NIF
is absent (same mechanism fetch uses). Raw NIF error maps go through
`NativeSupport.nif_error/2` (`lib/gitility/native_support.ex:105`).
Core helpers are `pub(crate)` where they return `gix` types (the core
boundary rule in `core/lib.rs`).

- `repo_init_bare(path: String, hash: Atom) -> Result<(), Error>`:
  core `repo_init::init_bare(path) -> Result<gix::Repository, Error>`
  (`pub(crate)`) = the initialise branch currently inline in
  `fetch.rs::open_or_init_bare` (`gix::ThreadSafeRepository::init_opts(
  path, Kind::Bare, create::Options::default(), open::Options::isolated())`)
  followed by the §2 config write. `open_or_init_bare` calls it, so
  fetch auto-init gets the config. `hash != sha1` → `UnsupportedHash`.
  Non-empty/non-dir path → `InvalidArgument`.
- `repo_write_refs(path: String, refs: Vec<(String, Binary)>, head: Option<(Binary /*oid*/, Option<String> /*symref*/)>) -> Result<u64, Error>`:
  NEW helper `refs::write_refs` (there is no existing create/update
  transaction to factor — fetch's updates happen inside gix's
  `prepared.receive`; only prune's delete transaction is ours).
  Validates every name with `gix::validate::reference::name` (gix
  re-exports gix-validate; do NOT add a direct dep) → `MalformedRef`;
  oid length must match the repo's hash → `InvalidOid`; duplicate names
  → `InvalidArgument`; D/F conflicts surface from gix-ref as
  `MalformedRef`. Builds ONE `gix_ref::transaction` via
  `repo.edit_references(edits)`: each non-HEAD ref
  `Change::Update{ expected: PreviousValue::MustNotExist, new:
  Target::Object(oid), log: only-if-ref-exists-off }`; `HEAD` (gix init
  ALWAYS writes a symbolic HEAD, so `MustNotExist` would fail):
  `expected: PreviousValue::Any`, `new: Target::Symbolic(symref)` when
  `symref` is `Some` AND that name is among `refs`, else
  `Target::Object(oid)`. Returns the number of edits committed. Reflogs
  disabled (bare mirror; `core.logAllRefUpdates` is false by default for
  bare repos — assert in a test). Bound: `refs.len()` ≤ the frozen TOC
  cap; the NIF is DirtyIo and not cancellable (D5).
- `Bundle.write` gains `generation: pos_integer` (Elixir-side option,
  no native change): must be `1..(2^64 - 1)`; when a file exists at
  `path`, must be ≥ existing + 1 → else `:invalid_argument`. Default
  unchanged (next generation of any file at `path`).

## 4. publish/4 algorithm (Elixir, `lib/gitility/mirror.ex`)

1. Validate (§0 style): `mirror_dir` is an existing directory; `key`
   per §1.1; `store = {module, init_arg}` with `module` loaded and
   exporting `init/1, head/3, get/4, put/4`; opts. `deadline = now +
   timeout`. `expanded = Path.expand(mirror_dir)`.
2. `Locks.acquire(expanded, timeout)` — the SAME `Gitility.Fetch.Locks`
   instance and key shape fetch uses, so fetch and publish on one
   mirror serialise. Contended → `:busy` immediately (D6); Mirror
   rewrites `operation:` to `:publish`. The lease is released in
   `after`; Locks already monitors the holder, and since Mirror attaches
   no `Gitility.Job`, holder death releases the lease at once (the only
   in-flight native work is `Bundle.write` into a temp file, which is
   never uploaded if the caller died; documented).
3. Sweep `#{expanded}.publish-*.tmp` older than 1 h (crash leftovers).
4. `module.init(init_arg)` → state (normalise per §1.4 table).
5. `head(state, key, timeout: remaining)`:
   - `{:ok, h}`: metadata MUST contain `"generation"` parsing as an
     integer `1..2^64-1` and `"tips_digest"` as 64 lowercase hex; if
     either is missing/malformed → `{:error, %Error{code:
     :backend_error, retryable: false, message: "object at key is not
     a gitility mirror bundle (missing or malformed metadata)", cause:
     {:adapter, :foreign_object}}}` — we never overwrite something we
     don't understand. `remote_gen`, `remote_digest`, `if_match = h.etag`.
   - `:not_found` → `remote_gen = 0`, `remote_digest = nil`, `if_match = :none`.
   - `remote_gen == 2^64 - 1` → `:unsupported_operation` "generation
     space exhausted for key".
6. `tmp = "#{expanded}.publish-#{random_hex(16)}.tmp"`: `File.touch!`
   then `File.chmod!(tmp, 0o600)` BEFORE `Bundle.write(tmp, source:
   {:repository, mirror_dir}, generation: remote_gen + 1,
   source_identity:, publisher: "gitility #{vsn}", created_at:,
   git_executable:)` (Writer opens with `File.open/2` which keeps the
   mode of an existing file). Write errors propagate unchanged
   (`:unsupported_operation` for shallow sources, etc.), with
   `operation: :publish`.
7. `{:ok, toc} = Bundle.Format.parse(tmp)`; `tips_digest =
   Mirror.tips_digest(toc.refs, toc.metadata["head_symref"])` =
   lowercase hex sha256 over the concatenation of the sorted lines
   `"<refname> <hex oid>\n"` for every row PLUS, when `head_symref` is
   present, the line `"HEAD -> <symref>\n"` (sorted with the rest; `->`
   cannot appear in a ref name, so it cannot collide). Pure, unit-tested
   against a fixed vector, and the symbolic-HEAD-change case (§7.2.16).
8. `tips_digest == remote_digest` → `{:ok, :not_newer}`.
9. `put(state, tmp, key, if_match:, metadata: %{"generation" =>
   Integer.to_string(gen), "tips_digest" => digest, "format" =>
   "gitility-bundle/1.0", "ref_count" => ..., "file_count" => ...},
   content_type: ..., timeout: remaining)`:
   - `{:ok, %{etag}}` → `{:ok, %Receipt{...}}`.
   - `:precondition_failed` → ONE re-`head`: `{:ok, h2}` with
     `h2.metadata["tips_digest"] == digest` → `{:ok, :not_newer}`;
     anything else → `:conflict` (retryable: true).
   - `{:transport, :timeout}` / `{:transport, :closed}` AFTER the body
     started streaming (the PUT may have committed): ONE bounded
     re-`head` (5 s, outside the main budget): etag changed AND digest
     == ours → `{:ok, %Receipt{etag: h.etag, ...}}` (it committed);
     etag unchanged → `:backend_error` retryable (`{:transport,
     :timeout}`); head fails → `:backend_error` retryable with cause
     `{:adapter, :indeterminate}`. Documented as "publish may report
     indeterminate; re-running is safe because the next run's HEAD
     reconciles".
   - other errors → table.
10. Deadline: every adapter call runs inside `Task.async` + `Task.yield(
    task, remaining) || Task.shutdown(task, :brutal_kill)` so a
    callback that ignores `opts[:timeout]` is still hard-bounded;
    kill → `:timeout` naming the phase in `details`. The local phases
    (`Bundle.write`, `Format.parse`) are not bounded (D5) — the
    deadline is re-checked after them and the upload is skipped with
    `:timeout` if already exceeded.
11. `after`: `File.rm(tmp)`; release lease.

## 5. restore/4 algorithm

1. Validate as §4.1 except `mirror_dir` must NOT exist or must be an
   empty directory (else `:invalid_argument`). Parent directory is
   created with `mkdir_p` up front (so a later rename cannot fail on a
   missing parent). `expanded`, lease, sweep of `#{expanded}.restore-*`
   (both `.tmp` files and `.stage` dirs) older than 1 h.
2. `init`; `tmp = "#{expanded}.restore-#{rand}.tmp"` (adapter creates
   it 0600 via sibling temp + rename); `get(state, key, tmp, timeout:)`.
   `:not_found` → `{:error, %Error{code: :not_found}}`; nothing created.
3. `Bundle.verify(tmp)`; map its error: code in
   `[:unsupported_operation, :backend_error]` → propagated unchanged
   (the frozen `shallow_roots` gate and I/O errors keep their
   meaning); any other code (structural/integrity: `:malformed_object`,
   `:hash_mismatch`, `:pack_checksum_mismatch`,
   `:index_checksum_mismatch`, …) → `:malformed_bundle` with the
   original code as `details.verify_code`. Then `Format.parse(tmp)` →
   `toc`. `toc.hash_algorithm != :sha1` → `:unsupported_hash`. If the
   `get` metadata carries `"generation"`/`"tips_digest"`, they MUST
   equal `toc.generation` / `tips_digest(toc)` → else
   `:malformed_bundle` (`details.verify_code: :metadata_mismatch`);
   absent metadata is accepted (a bundle copied into the store by
   hand is still a valid restore source).
4. `stage = "#{expanded}.restore-#{rand}.stage"`:
   `Repository.init_bare(stage)`. From here every failure path removes
   `stage` (best-effort `File.rm_rf/1`; the ORIGINAL error is returned,
   rm_rf failure added to `details.cleanup`) and never touches
   `mirror_dir`.
5. For each `file` in `toc.files`: stream the section bytes
   (`Bundle.Format` section offset/length → `:file.pread` in 8 MiB
   chunks) into `stage/objects/pack/<basename>.tmp` (0600) then rename
   to `<basename>`; idx after pack within a pair. Deadline checked per
   chunk (this phase IS bounded — it's local but large; `:timeout` →
   cleanup).
6. `Native.repo_write_refs(stage, rows, head)` where `rows` = every
   `toc.refs` row except `HEAD` as `{name, oid_binary}` and `head` =
   `{head_oid, toc.metadata["head_symref"]}` when a `HEAD` row exists,
   `nil` otherwise (then HEAD stays as gix init left it — symbolic to
   the init default — which is the correct representation of a source
   whose HEAD was unborn). Zero rows is fine (D3).
7. Deep check: `Repository.open(stage, require_bare: true,
   verify_pack_checksums: true)`; then for every restored ref, resolve
   via `Gitility.RefDB.resolve(repo.refs, name)` and read the target
   object's header through the snapshot/ODB API (`Gitility.ODB`
   header read — type + size, no payload) → missing object or wrong
   type for `HEAD`/`refs/heads/*` (must be commit) → `:malformed_bundle`
   (`details.verify_code: :dangling_ref`). Bounded by ref count.
8. Commit: `File.rename(stage, expanded)`. POSIX `rename(2)` replaces
   an EMPTY target directory atomically, which covers the
   "pre-existing empty dir" case; if the target was created by
   someone else in the meantime and is non-empty, rename fails →
   `:invalid_argument`, stage removed. Caller/VM death before this
   point leaves only `*.restore-*` siblings, which the next call
   sweeps; `mirror_dir` is never half-built.
9. `{:ok, %Restore{generation: toc.generation, etag:, bytes:,
   tips_digest:, ref_count:, file_count:}}`. `after`: tmp removed,
   lease released. Timeout semantics as §4.10 (adapter calls
   hard-bounded; verify/open/ref-write unbounded, deadline re-checked
   between them).

The result is an ordinary bare repository: `Fetch.fetch` into it must
behave exactly as into a mirror fetched from scratch (§7.2.5).

## 6. Credential and key hygiene (tests required for each)

- `inspect(state)` of `ObjectStore.S3` shows no key material.
- With a sentinel secret (`"SENTINEL_SECRET_…"`) and sentinel session
  token: forced transport failure, 403, 412, 3xx, timeout, and
  credentials-fun raise: the `%Gitility.Error{}` (`inspect`,
  `message/1`, `details`, `cause`) contains neither sentinel nor any
  `X-Amz-` string.
- Hostile redirect test: a local HTTP stub answering `301 Location:
  http://127.0.0.1:<other>/...` to PUT/GET/HEAD; the second listener
  MUST receive no request, and the error is `:backend_error` with
  cause `{:http, 301, nil}`.
- Mirror never logs above `:debug`; debug lines carry only key + byte
  counts + phase.
- `key` validated before any adapter call; invalid → `:invalid_argument`.

## 7. Test infrastructure + matrix

All sprite-local, no external network. minio:
- sprite (`remote-test.sh` mix stage): download
  `https://dl.min.io/server/minio/release/linux-amd64/archive/minio.RELEASE.2025-07-23T15-54-02Z`
  (or the newest release the implementer pins; record the sha256 in
  `scripts/minio.sha256` and verify it), once, into `~/minio/`; start
  `minio server <scratch> --address 127.0.0.1:<free port>` with
  `MINIO_ROOT_USER/PASSWORD` random per run; create bucket
  `gitility-test` with a `PUT /gitility-test` request from the test
  helper (no `mc`); export `GITILITY_MINIO_URL/KEY/SECRET/BUCKET`; stop
  by PID at the end. On the sprite the minio stage is REQUIRED (fail
  the run if unavailable); only on a developer machine without the env
  do the S3 tests skip, and they skip with a printed line.
- CI: service `minio: image: quay.io/minio/minio:RELEASE.<same tag>`
  (digest-pinned), `command: server /data`, `ports: 9000:9000`, `env:
  MINIO_ROOT_USER/PASSWORD`, readiness via a loop on
  `http://127.0.0.1:9000/minio/health/live` before `mix test`; bucket
  created by the same helper. `addressing: :path`, `region: "us-east-1"`.

### 7.1 Conformance (`Gitility.ObjectStore.Conformance`, `use`-able)

Mirrors `RangeBackend.Conformance`: the using module defines
`store_init_arg/0` (fresh per test, e.g. a temp root or a unique key
prefix — the suite prefixes every key with a random segment so a
shared minio bucket is fine), optional `store_setup/0` /
`store_teardown/1` hooks. Rows:
1. head missing → `:not_found`; get missing → `:not_found`.
2. put create-only → `{:ok, %{etag}}`; head returns size + metadata
   round-trip + same etag; get returns identical bytes (sha256) +
   metadata.
3. create-only on existing → `:precondition_failed`.
4. if_match current etag → ok, etag changes (content differs).
5. if_match stale → `:precondition_failed`.
6. 64 MiB object put + get; during the transfer, a sampler process
   polls `Process.info(pid, :memory)` of the calling process every 10
   ms and asserts peak < 32 MiB above baseline (streaming proof, not
   before/after).
7. timeout 1 ms on get of the 64 MiB object → `{:transport, :timeout}`
   within 1 s; no file at `dest_path`, no leftover sibling temp.
8. timeout 1 ms on head and on put → `{:transport, :timeout}` within 1 s.
9. 8-process concurrent create-only race → exactly one `:ok`, seven
   `:precondition_failed`.
10. concurrent overwrite while a reader gets → reader's bytes are
    entirely old or entirely new (compare sha256 against both).
11. invalid keys (`""`, `"/a"`, `"a/../b"`, `"a//b"`, `"a/"`, `"a\0"`)
    → `{:invalid_key, _}` from every callback.
12. key encoding vectors (S3 only, via the URL builder): `"a b"`,
    `"a%b"`, `"a?b"`, `"a#b"`, `"a+b"`, `"ü/ß"`, `"x/y/z"` → expected
    percent-encoded paths; round-trip through put/head.
13. metadata with 32 keys/256-byte values round-trips; CR/LF value →
    rejected by Mirror validation (not an adapter row).
Run against `Local` (always) and `S3` (when env set).

### 7.2 `test/milestone_6_mirror_test.exs`

1. publish fresh (key absent) → Receipt gen 1; `adapter.head/3`
   metadata has `"generation" => "1"` and a 64-hex digest; the object
   fetched via `adapter.get/4` passes `Bundle.verify`.
2. publish again unchanged → `{:ok, :not_newer}`; Local test hook
   proves no commit occurred; etag unchanged.
3. remote gains commits → fetch → publish → gen 2, digest changed.
4. restore into a fresh path → `git fsck --strict` clean;
   `git for-each-ref` identical to the source; `HEAD` symbolic to the
   same target; §2 config keys; pack/idx byte-identical to the source.
5. restored mirror + incremental `Fetch.fetch` → result (refs,
   updated_refs, rejected_refs) equal to a from-scratch fetch at the
   same remote state.
6. restore into a non-empty dir → `:invalid_argument`, untouched; into
   an EXISTING EMPTY dir → succeeds (rename-over-empty).
7. restore missing key → `:not_found`, no dir, no siblings.
8. corrupt object (flip one byte in the stored data) →
   `:malformed_bundle`, no dir, no stage, no tmp.
9. object with `shallow_roots` metadata (craft via Format encoder) →
   `:unsupported_operation`, not `:malformed_bundle`.
10. CAS race: two DIVERGENT mirrors (different commits) publishing to
    the same key from two processes; Local `before_commit` hook holds
    both until both HEADs completed → exactly one Receipt and exactly
    one `:conflict`; stored generation increased by exactly 1.
11. publish while a fetch holds the lease → `:busy` immediately with
    `operation: :publish`; restore likewise.
12. init_bare: §2 keys on all three creation paths; `git gc --auto`
    leaves pack count unchanged; non-empty → `:invalid_argument`;
    `hash: :sha256` → `:unsupported_hash`; `core.logAllRefUpdates`
    unset/false and no reflogs after restore.
13. `Bundle.write(generation: n)`: respected on a fresh path; `0`,
    `2^64`, and ≤ existing → `:invalid_argument`.
14. tips_digest fixed vector (3 refs + HEAD symref) with the expected
    hex literal.
15. hygiene rows of §6 (sentinel secret, redirect stub).
16. symbolic HEAD moved `main` → `master` at the same commit → publish
    yields gen+1 (NOT `:not_newer`); restore reproduces the new HEAD.
17. empty mirror (init_bare, no refs) → publish ok (zero refs) →
    restore ok → `Fetch.fetch` into it populates it.
18. detached/direct HEAD source → restore has direct HEAD with the
    same oid. Unborn HEAD (empty mirror) → restore HEAD symbolic to
    the init default.
19. hand-crafted bundle with a ref to a missing object →
    `:malformed_bundle` (`:dangling_ref`); with a bad idx checksum →
    `:malformed_bundle`; with conflicting names `refs/heads/a` +
    `refs/heads/a/b` → `:malformed_bundle` (D/F), stage removed.
20. foreign object at key (put by hand without metadata) → publish
    returns `:backend_error` `{:adapter, :foreign_object}`; remote
    untouched.
21. PUT commit-then-timeout (fake adapter commits then returns
    `{:transport, :timeout}`) → publish returns `{:ok, %Receipt{}}`
    after reconciliation; commit-not-happened + timeout →
    `:backend_error` retryable.
22. credentials fun raising / returning garbage →
    `:credentials_unavailable`, sentinel absent.
23. caller killed mid-publish (Task + `Process.exit(:kill)` while the
    fake adapter blocks in put) → lease released (a second publish is
    not `:busy`), tmp swept by the next call.
24. publish/restore option validation: unknown key, improper list,
    timeout out of range, store module missing a callback → typed
    `:invalid_argument`, nothing raised.

Oracle: pinned git 2.55 as in M5a.

### 7.3 Dress rehearsal

`bench/dress_rehearsal.exs` Flow D: fetch phoenix mirror → publish to
Local → restore elsewhere → Flow A query parity on the restored mirror
→ incremental fetch → publish again (asserts `:not_newer` vs gen+1 by
whether the remote moved).

### 7.4 Optional-dependency compile test

`scripts/consumer-smoke.sh` (sprite): create a scratch mix project
depending on the packaged gitility WITHOUT `req`; `mix compile
--warnings-as-errors` passes; `Gitility.ObjectStore.S3.init([...])`
returns `:unsupported_operation`; `Gitility.ObjectStore.Local` and
`Mirror` with Local work end to end.

## 8. Docs, changelog, packaging

- `Gitility.Mirror` moduledoc: the loop (restore → fetch → publish);
  replication-not-shared-FS; `:busy`/`:conflict`/`:not_newer`/
  indeterminate semantics for a scheduler; timeout scope (D5); 5 GiB
  limit; temp placement (siblings of the mirror, same filesystem);
  lease sharing with fetch; "a bundle in the store is a transport
  artifact — restore it, don't open it".
- `Gitility.ObjectStore` moduledoc: §1.1 contract incl. atomicity,
  streaming, reason shapes; how to `use` the conformance suite.
- `Gitility.ObjectStore.S3` moduledoc: add `{:req, "~> 0.5"}`;
  minio/Tigris/R2 examples (`addressing: :path`); credentials fun;
  "conditional writes required (AWS, minio, R2, Tigris)"; no redirects.
- `Gitility.ObjectStore.Local` moduledoc: single-VM, layout, sweep.
- `Gitility.Fetch` moduledoc: append-only sentence; gc-safe auto-init
  contract (§2); credential-helper-disarm as the headline; empty
  remote + wildcard → ok with `remote_ref_count: 0`.
- `Gitility.Repository` moduledoc: `init_bare/2`; ~700 ms first-query
  warmup note.
- Search docs: `**/glob` idiom first. Diff docs: tiny-file rename
  threshold note. `history`: `since`/`until` → typed `:invalid_argument`
  naming the option (code change).
- README: "Replicating mirrors" section; consumer live-fire numbers.
- CHANGELOG [Unreleased]: Added (Mirror, ObjectStore + S3 + Local +
  Conformance, `Repository.init_bare/2`, `Bundle.write` `:generation`),
  Changed (gitility-created bare dirs are gc-safe; new error codes
  `not_found`/`conflict`/`malformed_bundle`), Fixed (history typed
  error).
- `mix.exs`: `{:req, "~> 0.5", optional: true}`; hexdocs groups;
  `Gitility.ObjectStore.Local.Supervisor` + `Registry` in
  `application.ex`.
- `mix docs --warnings-as-errors` clean.

## 9. Definition of done

- `cargo test --workspace` green locally; `cargo clippy --workspace
  --all-targets` zero warnings; spawn guard UNCHANGED;
  `--no-default-features` loom build green (new modules are
  feature-gated).
- Sprite: full mix suite green; 12× loop on `milestone_6_mirror_test.exs`
  and both conformance files; minio conformance green (required);
  rehearsal ALL CHECKS PASSED incl. Flow D; consumer smoke (§7.4) green.
- CI green including the minio service.
- Opus adversarial review of the diff, findings fixed, re-verified on
  sprite.
- Consumer smoke: gentility session runs restore → fetch → publish
  against its own mirror with `ObjectStore.Local` and reports parity.
