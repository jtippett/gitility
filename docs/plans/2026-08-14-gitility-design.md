# Gitility — snapshot-first Git object queries for Elixir

Date: 2026-08-14

Status: proposed; implementation-ready. Supersedes
`2026-08-14-ex-gitoxide-design.md` (full rewrite; the architecture survives,
the feasibility claims, naming, runtime configuration, and provider contracts
are revised against verified upstream evidence).

## Executive decision

Build `gitility`, a new standalone Hex library: a pure-Rust query core built on
Gitoxide's plumbing crates behind our own storage seam, exposed through a thin
Rustler adapter. Do not fork `egit`, and do not make a repository path,
worktree, VFS, shell, or Git command the root abstraction.

The library is **snapshot-first** and **read-only**:

- An immutable commit identifies the code being queried.
- An object database (ODB) supplies Git objects by object ID.
- An optional reference database resolves mutable names to object IDs.
- Queries operate on commits, trees, and blobs without checking anything out.
- Local bare repositories are one ODB adapter, not the architecture.
- Elixir-backed and remote pack-backed ODBs are first-class.
- No operation silently writes a checkout, temporary repository, or disk cache.

The initial public promise is bounded, cancellable, structured inspection:
object lookup, tree traversal, file reads, search, commit history, path
history, diffs, blame, ancestry, and reference resolution. Mutation, checkout,
hooks, filters, and arbitrary command execution are deliberately outside the
first release.

### Why "Gitility"

The engine must never leak into the public API, so it must not leak into the
name either — a thin binding named `ex_gix` already exists on Hex, and
Milestone 5 hand-rolls enough of the pack layer that "the Gitoxide library"
would be half-true. **Gitility** reads as Git + utility — a utility layer
over Git's object model, which is the product — and carries a nod to its
origins in the Gentility platform, whose agent code-exploration needs drove
the design. The top-level module is `Gitility`; the `gitility` package name
is unclaimed on Hex as of 2026-08-14.

## Why a new library

### Prior art on Hex (checked 2026-08-14)

- `xgit` — pure-Elixir Git, abandoned 2020.
- `gitex` — Git object storage experiment, abandoned 2015.
- `egit` — command-shaped NIF over libgit2; in Gentility it serves only
  `Gentility.Sync` (per-org bare repos for agent file sync), not exploration.
- `ex_gix` — thin Gitoxide binding, 0.1.x, no query model.
- `exgit` — brand-new pure-Elixir smart-HTTP client with a path-oriented FS
  API; transport-first, not an object-query engine.
- `ex_git_engine` — libgit2 wrapper behind a GenServer.

None offers snapshot-pinned, budgeted, cancellable semantic queries over
pluggable object storage. That combination — not any single missing function —
is the reason to build.

### What Gentility actually does today

Gentility's read-only exploration path (`Gentility.CodeExplorer`) does not use
Git objects at all: `Hydrator` downloads a GitHub **tarball** for one ref,
unpacks it into a Sprite sandbox, and `Operations` shells into that sandbox
(`fs_read`, `fs_list`, ripgrep over exec). Consequences:

- every ref/branch/PR needs a full re-hydration;
- there is no history, so `code_history`, `code_diff`, and `code_blame`
  cannot exist;
- reads cost a sandbox round-trip and a live Sprite;
- "what code is this answer about" is a workspace row, not a commit ID.

Gitility replaces this with object-native queries pinned to a commit. The
`egit`-based `Gentility.Sync` feature is unrelated and out of scope (though its
bare repos become readable through Gitility's local adapter for free).

## Engine feasibility — verified 2026-08-14

These findings are load-bearing; the design references them by ID.

- **F1 — Pluggable object source is real.** `gix_object::Find` /
  `FindHeader` are dyn-compatible traits, and the algorithm crates consume
  them generically at every relevant entry point (`gix-traverse`
  `objects: &impl gix_object::Find`; same pattern in `gix-diff`, `gix-blame`,
  `gix-revwalk`, `gix-merge`). A custom object source can drive traversal,
  diff, blame, and revision walking without `gix::Repository`. This is the
  fact the whole architecture stands on.
- **F2 — gix-pack cannot range-read.** `gix_pack::FileData` is a marker trait
  requiring `Deref<Target = [u8]>`; pack and index files must be fully
  addressable in memory (mmap). There is no `ReadAt`-style abstraction, no
  upstream issue proposing one, and the maintainer has explicitly deferred
  custom storage backends (discussion #1281). Upstreaming a range reader is
  not a plannable dependency; Gitility implements its own range-aware pack/index
  reader behind F1.
- **F3 — SHA-256 is mid-transition upstream.** `gix_hash::Kind::Sha256`
  exists (feature-gated) and non-blob decoding is partially parameterized,
  but `gix-pack`, `gix-odb`, `gix-ref`, `gix-index`, `gix-diff`, and
  `gix-blame` all retain SHA-1-only assumptions per the maintainers' live
  checklist (`etc/plan/sha256-support.md`, discussion #2780), and
  `cargo check -p gix --features sha256 --no-default-features` does not
  compile. Git 3.0 (~September 2026) is expected to default `git init` to
  SHA-256, so the pressure is real but the engine support is not.
- **F4 — Blame is capable but imperfect.** `gix-blame` supports line ranges
  (`BlameRanges`, `-L` semantics) and rename-following (`rewrites`), but has
  **no first-parent mode**, only a `since` bound, and its own rename-tracking
  PR (#2022) benchmarked ~92.6% line-for-line agreement with canonical
  `git blame` across a real corpus. "Pass all blame corner cases" is
  unchecked in crate-status.
- **F5 — `log --follow` does not exist upstream.** There is no
  pathspec-scoped, rename-following history walk in gix. `gix_diff::Rewrites`
  is a per-diff (two-tree) rename detector with a documented deviation from
  Git (first-found candidate vs Git's four-candidate selection). Gitility builds
  path history itself on top of commit traversal plus tree diffs with
  rewrite tracking.
- **F6 — the bundle engine is Turso, keeping the project pure Rust.**
  Turso Database (v0.7.0, 2026-07) is a SQLite-compatible engine written in
  Rust, in production use per its maintainers. Verified against its COMPAT
  matrix and source: the SQLite file format is fully supported (bundles stay
  inspectable with any SQLite tool), as are transactions, blob storage,
  `integrity_check`, and `VACUUM INTO`; incremental blob I/O
  (`sqlite3_blob_*`) is stubbed, which is moot here — the 1 MiB chunked-row
  schema *is* the range-read mechanism (deliberately identical to the
  Postgres backend, which has no sub-value range reads either).
  `turso_core` is drivable synchronously (`Statement::step()` polling, as
  the Turso CLI does) — no tokio in the NIF. Risk containment is
  structural: Gitility's pack/index checksums and `verify: :always` object
  hashing turn any engine read bug into a loud error rather than a wrong
  answer; publish can run `integrity_check` plus full readback; and the
  bundle store sits behind the internal range-read seam, so swapping to
  C SQLite via `rusqlite` (verified: incremental blob I/O plus a `bundled`
  static amalgamation, the documented fallback if conformance/fuzz testing
  finds blockers) touches nothing above the seam. `exqlite` was rejected
  outright: no blob I/O, a second NIF, and an Elixir round-trip on a local
  read path. Turso is exact-pinned like gix (R5).
  **M0 spike result (2026-08-14, `crates/f6-spike`): PASS.** 16 concurrent
  reader threads over one 64 MiB bundle-shaped file via synchronous
  `Statement::step()` polling (`turso_core = "=0.7.2"`, `fs` feature, no
  tokio): ~47 GiB verified byte-correct at ~2.2 GiB/s, connection
  open/close churn clean, zero errors or deadlocks. The rusqlite fallback
  was not triggered.

## Goals

1. Query any immutable Git snapshot without a worktree.
2. Read objects from local Git storage, memory, an Elixir provider, or a
   remote immutable pack store.
3. Present an idiomatic, stable Elixir API independent of Gitoxide churn.
4. Make every expensive operation bounded, observable, and cancellable.
5. Preserve Git's byte-oriented paths and contents without assuming UTF-8.
6. Return structured data suitable for agent tools without parsing command
   output.
7. Verify all remotely supplied objects and pack data before trusting them.
8. Differentially test behavior against canonical Git and, during maturation,
   libgit2.
9. Ship precompiled NIFs using the same proven release pattern as ExBashkit.

## Non-goals for 1.0

- A porcelain Git client.
- A worktree, index, checkout, status, commit, merge, rebase, or push API.
- Running hooks, filters, textconv, credential helpers, or external programs.
- Transparently resolving Git LFS content. LFS pointers are identified and
  returned as such; an LFS resolver can be added separately.
- Automatically traversing submodules. Gitlinks are returned as typed
  entries; callers may resolve them through another repository.
- Perfect emulation of every Git revision expression. Safe selectors are the
  default; raw revspec parsing is an explicit advanced option.
- A persistent code-search service. The first search implementation scans
  snapshot blobs with strict budgets; a content-addressed index is a separate
  accelerator.
- SHA-256 **query execution** (see the hash policy below — the types, wire
  formats, and verification layer are SHA-256-ready from day one; the engine
  is not, per F3).

## Risk register

| ID | Risk | Posture |
|----|------|---------|
| R1 | SHA-256 engine support blocked on upstream (F3) while Git 3.0 makes SHA-256 repos common | Types/cursors/verification hash-agnostic from 0.1; engine returns `:unsupported_hash`; re-evaluate at every Gitoxide release; SHA-256 fixtures exercise the refusal path continuously |
| R2 | Blame diverges from canonical git on ~7% of lines in rename-heavy history (F4) | Differential testing uses a triaged known-divergence allowlist, not blanket tolerance; each divergence is reproduced, classified, and either fixed or documented; agreement ratio is tracked as a regression metric |
| R3 | Path history is our own algorithm (F5), including its rename-candidate deviation from Git | Ship behind explicit `follow_renames: true`; differential-test against `git log --follow` with the same allowlist discipline; document the deviation |
| R4 | The lazy remote pack reader is net-new Rust (F2): idx fan-out parsing, inflate-over-ranges, delta resolution | Eager `PackFetch` (stock gix-pack over explicitly fetched bytes) covers the driving ephemeral-node use case with no new Rust; the lazy reader is scoped as Milestone 5 behind checkpoint C1 for large/sparse repos and sits behind F1's trait seam so nothing above it changes |
| R5 | Gitoxide is pre-1.0 and churns | Exact-pin the `gix` family, commit `Cargo.lock`, forbid gix types in the core's public API and in Elixir; upgrades are deliberate events with the differential suite as the gate |
| R6 | The async NIF runtime (worker pool, `OwnedEnv` messaging, process monitors, cancellation) is the hardest correctness surface | Milestone 2 is dedicated to it; loom/concurrency tests, fault injection, and soak tests are required exit criteria, not stretch goals |
| R7 | First-parent blame is unsupported upstream (F4) and Gentility may want it | Omitted from the 0.x API rather than shipped broken; revisit post-1.0 (own implementation or upstream contribution) |

## Architectural principles

### ODB and refs are separate

A Git ODB contains immutable objects. Branches and tags are mutable names and
belong to a reference database. A caller that already knows a commit ID needs
only an ODB.

This separation is essential for remote storage. It permits:

- snapshot queries over an object service with no repository directory;
- references resolved through GitHub, a database, or another API;
- atomic pinning of a moving branch before a long agent run;
- one ODB shared by multiple independent ref namespaces;
- testing queries from a small object fixture with no repository scaffolding.

### Snapshots never move

Every semantic query takes `%Gitility.Snapshot{}`. Creating a snapshot peels and
validates a commit once and records its commit and root tree IDs. A branch,
tag, or PR selector is resolved before the snapshot is returned.

### Storage never leaks into query semantics

`read_file/3` returns the same result whether the blob came from a local pack,
an Elixir callback, memory, or a remote range read. Provider-specific errors
are normalized at the ODB boundary. Internally this seam is exactly F1: every
store — including our own pack-range reader — presents the same object-lookup
contract to the algorithms.

### The NIF is asynchronous internally

Long queries do not execute on a normal or dirty BEAM scheduler. A fast NIF
enqueues work onto a bounded Rust-owned worker pool and returns a job
resource. The public synchronous API awaits that job; an asynchronous API
exposes it directly.

This is required for callback ODBs. Rustler's `OwnedEnv` can send messages
from a Rust-owned thread, while sending that way from a BEAM-managed scheduler
thread is forbidden. It also gives us real cancellation, queue bounds, and a
single place to enforce concurrency limits.

### No hidden materialization

No adapter may silently create a checkout, clone, temp directory, or disk
cache. The remote adapters use bounded memory caches by default. An optional
disk cache is an explicit caller-supplied adapter and path.

### Explicit runtimes, not ambient global config

The worker pool is an explicit, supervisable runtime instance, not an
app-env-configured singleton. A default instance exists so small callers need
zero configuration, but tuning means starting a named `Gitility.Runtime` in your
own supervision tree — the modern library convention (Finch, NimblePool), and
the only shape that lets two subsystems with different latency profiles stop
sharing a queue.

## Package and crate layout

Create a standalone repository, published as `gitility`:

```text
gitility/
  lib/
    gitility.ex
    gitility/application.ex
    gitility/runtime.ex
    gitility/repository.ex
    gitility/snapshot.ex
    gitility/odb.ex
    gitility/odb/backend.ex
    gitility/odb/provider.ex
    gitility/odb/local.ex
    gitility/odb/static.ex
    gitility/odb/cache.ex
    gitility/odb/pack_fetch.ex
    gitility/odb/pack_range.ex
    gitility/odb/range_backend.ex
    gitility/ref_db.ex
    gitility/ref_db/backend.ex
    gitility/bundle.ex
    gitility/job.ex
    gitility/limits.ex
    gitility/error.ex
    gitility/page.ex
    gitility/oid.ex
    gitility/path.ex
    gitility/types/*.ex
    gitility/native.ex          # @moduledoc false — internal NIF surface
  native/
    gitility/
      Cargo.toml
      src/lib.rs
  crates/
    gitility-core/
      Cargo.toml
      src/
        odb.rs
        refs.rs
        snapshot.rs
        object.rs
        tree.rs
        search.rs
        revision.rs
        diff.rs
        blame.rs
        history.rs
        pack/            # the range-aware pack/index reader (M5)
        limits.rs
        error.rs
  test/
  native/gitility/tests/
  fixtures/repos/
  fuzz/
```

`gitility-core` must not depend on Rustler or Elixir concepts. The NIF crate
adapts Rust DTOs and resources to the BEAM. Our Rust crates use
`#![forbid(unsafe_code)]`; dependency internals remain outside that guarantee.

Pin the `gix` family exactly behind the core compatibility layer and commit
`Cargo.lock`. Gitoxide is pre-1.0 and its public types must never cross the
Rust core or Elixir public boundaries (R5). `Gitility.Native` is documented as
internal (`@moduledoc false`); the provider reply entry point is not public
API and may change without notice.

## Hash algorithm policy

Everything that *represents* an object ID is hash-agnostic from 0.1:

- `%Gitility.OID{algorithm: :sha1 | :sha256, bytes: binary}` everywhere; no
  20-byte assumptions in any DTO, cursor, error, or protocol.
- The verification layer hashes `<type> <size>\0<payload>` itself and
  supports both algorithms — it does not depend on Gitoxide for this.
- Cursors, manifests, and the callback protocol carry the algorithm
  explicitly.
- The fixture corpus includes SHA-256 repositories from Milestone 0.

Everything that *executes queries* is SHA-1-only until upstream completes its
transition (F3, R1). Opening a SHA-256 snapshot returns
`{:error, %Gitility.Error{code: :unsupported_hash}}` — a clean refusal, not a
wrong answer. The SHA-256 fixtures continuously exercise that refusal path so
enabling the engine later is a capability flip, not a redesign. We track
gitoxide discussion #2780 and re-evaluate at each pinned upgrade; given Git
3.0's timeline, this is the highest-priority external dependency to watch.

## Public Elixir API

### Runtimes

```elixir
# Zero configuration: the default runtime starts lazily with conservative
# defaults (workers: max(schedulers/2, 1), max_queue: 1_000,
# max_jobs_per_owner: 16).

# Tuned and isolated: a named runtime in your own supervision tree.
children = [
  {Gitility.Runtime,
   name: MyApp.GitRuntime,
   workers: 8,
   max_queue: 500,
   max_jobs_per_owner: 16}
]
```

Every root handle (`Repository.open/2`, `ODB.start_link/1`,
`ODB.from_objects/2`) accepts `runtime:` and defaults to the shared default
instance. Snapshots and jobs inherit the runtime of the store they were
created from; stores composed together (`ODB.layer/1`,
`Repository.from_stores/1`, cross-snapshot `diff/3`) must share one runtime,
enforced at composition time with `:runtime_mismatch`.

### Opening local repositories

```elixir
{:ok, repo} =
  Gitility.Repository.open("/srv/git/acme/widgets.git",
    require_bare: true,
    object_cache_bytes: 64 * 1_024 * 1_024
  )

{:ok, snapshot} = Gitility.Repository.snapshot(repo, {:ref, "refs/heads/main"})
```

`open/2` accepts normal or bare repositories, but queries never read worktree
files. `require_bare: true` rejects a non-bare repository when the caller
wants that invariant.

### Opening a static in-memory ODB

```elixir
{:ok, odb} = Gitility.ODB.from_objects(objects, hash: :sha1, verify: :always)

{:ok, snapshot} = Gitility.Snapshot.open(odb, commit_oid)
```

`objects` is an enumerable of `%Gitility.Object{oid:, type:, data:}`. This
adapter (`Gitility.ODB.Static`) is a fixed store for tests, small generated
repositories, and callers that already hold object data in memory. It is
distinct from `Gitility.ODB.cache/1`, which is a writable cache *layer* (below);
the two are deliberately not both called "memory".

### Opening an Elixir-backed ODB

```elixir
{:ok, odb} =
  Gitility.ODB.start_link(
    backend: {MyCompany.GitObjectBackend, backend_options},
    name: MyApp.ObjectStore,          # optional; supports child_spec/via
    hash: :sha1,
    verify: :always,
    concurrency: 8,
    request_timeout: 15_000,
    cache: [
      object_bytes: 128 * 1_024 * 1_024,
      header_entries: 100_000,
      negative_ttl: 5_000
    ]
  )

{:ok, snapshot} = Gitility.Snapshot.open(odb, commit_oid)
```

The ODB provider is a supervised Elixir process (use it directly in a
supervision tree via `{Gitility.ODB, opts}`). The native resource monitors it;
provider exit fails pending requests with `:provider_down` and cancels jobs
that cannot make progress.

### Composing refs with an ODB

```elixir
{:ok, refs} =
  Gitility.RefDB.start_link(backend: {MyCompany.GitRefBackend, backend_options})

{:ok, repo} = Gitility.Repository.from_stores(odb: odb, refs: refs)

{:ok, snapshot} = Gitility.Repository.snapshot(repo, {:ref, "refs/pull/481/head"})
```

Safe selectors are:

```elixir
{:oid, oid}
{:ref, full_ref_name}
{:tag, tag_name}
{:branch, branch_name}
:head
```

`{:revspec, string}` is an opt-in advanced selector and is unavailable when
the configured stores cannot support its required operations.

### Tree traversal

```elixir
{:ok, page} =
  Gitility.list_tree(snapshot, "lib",
    recursive: true,
    depth: 4,
    types: [:tree, :blob, :symlink, :gitlink],
    pathspecs: ["**/*.ex"],
    limit: 500,
    cursor: nil
  )
```

Returns `%Gitility.Page{items:, next_cursor:, truncated:, stats:, warnings:}`
whose entries are:

```elixir
%Gitility.TreeEntry{
  path: raw_path_bytes,
  name: raw_name_bytes,
  oid: %Gitility.OID{},
  type: :blob,
  mode: 0o100644,
  size: nil
}
```

Blob size is omitted unless `include: [:size]` is requested because packed
object headers may require work. Symlinks are not followed. Gitlinks are not
opened.

### File reads

```elixir
{:ok, file} =
  Gitility.read_file(snapshot, "lib/acme/widget.ex",
    lines: 120..220,
    max_bytes: 256_000
  )
```

Returns:

```elixir
%Gitility.File{
  path: raw_path_bytes,
  blob_oid: %Gitility.OID{},
  mode: 0o100644,
  kind: :text,
  data: binary,
  start_line: 120,
  end_line: 220,
  total_lines: 417,
  truncated: true,
  lfs_pointer: nil
}
```

Git contents and paths are bytes. `kind` is `:text`, `:binary`, `:symlink`, or
`:gitlink`; text means valid UTF-8 without a binary marker under the
configured policy. The raw binary is always authoritative. `Gitility.Path.display/1`
provides a lossy UI representation, and `Gitility.Path.encode/1` provides a
reversible JSON-safe representation.

### Content search

```elixir
{:ok, page} =
  Gitility.search(snapshot, "def handle_call",
    mode: :literal,
    case_sensitive: true,
    path: "lib",
    pathspecs: ["**/*.ex"],
    binary: :skip,
    context_lines: 1,
    limit: 100,
    cursor: nil
  )
```

`mode: :regex` uses Rust's linear-time `regex` engine over bytes. Unsupported
constructs such as backreferences and lookaround return `:unsupported_regex`;
there is no fallback to a backtracking engine.

Each `%Gitility.SearchMatch{}` includes raw path, blob ID, line, byte column,
preview, submatches, and enough snapshot identity for a stable citation.

The first implementation walks the tree, deduplicates blobs by object ID,
prefetches object batches where the ODB supports it, and scans each unique
blob once. A persistent index may implement the same API later.

### Commit graph and history

```elixir
{:ok, page} =
  Gitility.log(snapshot,
    order: :topological,
    first_parent: false,
    since: nil,
    until: nil,
    limit: 100,
    cursor: nil
  )

{:ok, page} =
  Gitility.history(snapshot, "lib/acme/widget.ex",
    follow_renames: true,
    first_parent: false,
    limit: 50,
    cursor: nil
  )
```

Commit results include ID, parents, tree ID, raw and decoded message fields,
author, committer, time, timezone offset, optional signature headers, and
truncation metadata.

`log/2` first-parent mode maps directly onto gix's revision walk. `history/3`
is Gitility's own algorithm (F5, R3): a budgeted commit walk that tree-diffs each
step for the path, with `follow_renames: true` engaging `gix-diff` rewrite
tracking to re-target the path across renames. Its rename-candidate selection
deviates from canonical Git in documented ways; path history is budgeted
separately because it may diff many parent trees.

### Diff

```elixir
{:ok, diff} =
  Gitility.diff(base_snapshot, head_snapshot,
    pathspecs: ["lib/**"],
    format: :patch,
    context_lines: 3,
    renames: :similarity,
    copies: false
  )
```

`format` is `:summary`, `:stats`, or `:patch`. Patch results are structured:
files, old/new paths and modes, old/new blob IDs, status, similarity, binary
metadata, hunks, and lines with origin and old/new line numbers. The library
does not make callers parse unified diff text, though a formatter may render
the structured result as unified diff.

The two snapshots may come from **different ODBs** — objects are
content-addressed, so Gitility resolves reads through a union of the two stores
(head's first, then base's). Both must share a hash algorithm
(`:hash_mismatch` otherwise) and a runtime (`:runtime_mismatch`).

### Blame

```elixir
{:ok, blame} =
  Gitility.blame(snapshot, "lib/acme/widget.ex",
    lines: 120..220,
    follow_renames: true
  )
```

Blame returns consecutive hunks rather than one result per line. Each hunk
contains final and original ranges, commit ID, original path, boundary status,
author, committer, and summary. This is substantially more compact for agents.

`lines:` maps to gix-blame's range support; `follow_renames:` maps to its
rewrite tracking (F4). There is **no `first_parent` option** in 0.x: upstream
has no first-parent blame and shipping a silently-wrong emulation is worse
than omitting the option (R7). Blame fidelity relative to canonical Git is
governed by the differential policy below (R2).

### Ancestry and plumbing

The supported lower-level API is deliberately small:

```elixir
Gitility.merge_base(repo_or_odb, left_oid, right_oid)
Gitility.ancestor?(repo_or_odb, ancestor_oid, descendant_oid)
Gitility.peel(repo_or_odb, object_oid, to: :commit)

Gitility.ODB.header(odb, oid)
Gitility.ODB.read(odb, oid, max_bytes: 1_000_000)
Gitility.ODB.read_many(odb, oids, max_total_bytes: 8_000_000)
```

Raw object access remains bounded and verifies type, declared size, and object
hash.

### Jobs, awaiting, and cancellation

Every synchronous call is implemented over a job:

```elixir
{:ok, job} = Gitility.async_search(snapshot, query, options)

case Gitility.Job.await(job, 30_000) do
  {:ok, result} -> result
  {:error, %Gitility.Error{code: :await_timeout}} -> still_running
  {:error, %Gitility.Error{code: :timeout}} -> job_budget_exhausted
end

:ok = Gitility.Job.cancel(job)
```

Await semantics are explicit, because the two timeouts are different things:

- `Job.await/2` timing out returns `:await_timeout` and **leaves the job
  running**; the caller may await again, cancel, or abandon it (abandonment
  is safe — see ownership below). `retryable: true`.
- The job's own `timeout_ms` budget expiring cancels the work and completes
  the job as `:timeout`.
- The synchronous wrappers pass `limits.timeout_ms` as the budget and await
  it plus a small grace period, so callers of the sync API only ever see
  `:timeout`.

Jobs have `queued`, `running`, `completed`, `failed`, and `cancelled` states.
Cancellation sets an atomic interrupt checked throughout walks, scans, diffs,
blame, provider waits, and pack decoding. Caller death cancels caller-owned
jobs unless `detach: true` was explicitly requested.

## ODB contracts

### Core Rust contract

The core owns a stable trait independent of Gitoxide's public API:

```rust
pub trait ObjectDb: Send + Sync + 'static {
    fn hash_kind(&self) -> HashKind;
    fn try_header(&self, oid: &Oid, budget: &Budget)
        -> Result<Option<ObjectHeader>, Error>;
    fn try_find(&self, oid: &Oid, out: &mut Vec<u8>, budget: &Budget)
        -> Result<Option<ObjectKind>, Error>;
    fn prefetch(&self, oids: &[Oid], budget: &Budget) -> Result<(), Error> {
        Ok(())
    }
    fn refresh(&self, budget: &Budget) -> Result<(), Error> {
        Ok(())
    }
}
```

Adapters implement `gix_object::Find` and `FindHeader` over this contract
where Gitoxide algorithms require them — F1 confirms this is exactly how the
algorithm crates are parameterized, so every store (local, static, callback,
layered, pack-range) drives every algorithm through one seam. `prefetch/2` is
intentionally part of our contract even though the upstream `Find` trait is
single-object: tree and revision algorithms frequently know the next group of
IDs, and remote ODBs need batching.

The ODB is content-addressed and has no ref methods. `RefDb` is separate:

```rust
pub trait RefDb: Send + Sync + 'static {
    fn resolve(&self, name: &[u8], budget: &Budget)
        -> Result<Option<RefTarget>, Error>;
    fn list(&self, query: RefQuery, budget: &Budget)
        -> Result<RefPage, Error>;
    fn refresh(&self, budget: &Budget) -> Result<(), Error>;
}
```

### Elixir ODB backend behaviour

Two deliberate contract decisions:

1. **Batch retrieval is required**; single reads are a one-element batch.
   This avoids defining an attractive but catastrophically chatty remote
   interface.
2. **Callbacks are stateless and concurrent.** `init/1` produces a state term
   that is passed to every callback *read-only*; callbacks do not return
   updated state. The provider dispatches callbacks to supervised tasks, up
   to the configured `concurrency`. A backend that needs mutable state
   (connection pools, rate limiters, metrics) owns it explicitly — an ETS
   table, an Agent, its own process — rather than inheriting serialization
   from a GenServer contract. This is what keeps one provider from becoming
   the bottleneck for every concurrent query.

```elixir
defmodule Gitility.ODB.Backend do
  @type state :: term()

  @callback init(term()) :: {:ok, state()} | {:error, term()}

  @callback read_many([Gitility.OID.t()], state()) ::
              {:ok, %{Gitility.OID.t() => Gitility.Object.t() | :not_found}}
              | {:error, term()}

  @callback read_headers([Gitility.OID.t()], state()) ::
              {:ok, %{Gitility.OID.t() => Gitility.ObjectHeader.t() | :not_found}}
              | {:error, term()}

  @callback prefetch([Gitility.OID.t()], state()) :: :ok | {:error, term()}

  @callback refresh(state()) :: :ok | {:error, term()}

  @callback terminate(term(), state()) :: term()

  @optional_callbacks read_headers: 2, prefetch: 2, refresh: 1, terminate: 2
end
```

Callbacks must be safe to run concurrently up to `concurrency`. A backend
callback must not call back into Gitility against the same provider — under pool
exhaustion that deadlocks, and it is documented as forbidden.

`Gitility.ODB.Provider` owns dispatch. Native worker threads send a request
resource to the provider; a task performs the callback and replies through the
internal native entry point. The request resource, not a global integer ID,
owns the waiting channel and makes late or duplicate replies harmless.

The protocol invariants:

- backend work never runs in the query caller process;
- every request has a deadline and cancellation token;
- provider exit wakes all waiters;
- replies are capped before copying into Rust-owned memory;
- unexpected or duplicate object IDs are rejected;
- `:not_found` is distinct from backend failure;
- backend errors are sanitized before crossing into query results;
- negative cache entries have a short TTL because missing objects may arrive
  later in shallow or incrementally populated stores.

### Elixir reference backend behaviour

References use the same provider pattern (stateless, concurrent callbacks)
but never share mutable state with an ODB backend implicitly. A caller may
choose one module for both roles, but Gitility treats them as independent
capabilities.

```elixir
defmodule Gitility.RefDB.Backend do
  @type state :: term()

  @callback init(term()) :: {:ok, state()} | {:error, term()}

  @callback resolve(binary(), state()) ::
              {:ok, Gitility.RefTarget.t() | :not_found}
              | {:error, term()}

  @callback list(Gitility.RefQuery.t(), state()) ::
              {:ok, Gitility.RefPage.t()} | {:error, term()}

  @callback refresh(state()) :: :ok | {:error, term()}

  @callback terminate(term(), state()) :: term()

  @optional_callbacks list: 2, refresh: 1, terminate: 2
end
```

Full reference names are raw binaries. Convenience branch and tag selectors
are expanded by Gitility before calling the backend. Symbolic refs are followed
with a hard hop limit, and cycles return `:malformed_ref`.

### Object verification

`verify: :always` is the default and the only mode used by Gentility. It is
also, deliberately, the only mode in 0.1 — but Milestone 1 must benchmark
its cost on the local adapter (a large tree walk pays one hash per object
that no other Git tooling pays for trusted local disk). Decision recorded
2026-08-14: if the data shows a material tax, add a relaxed mode for
trusted local stores (e.g. `verify: :packed` — trust pack checksums,
verify loose objects and everything remote); the lean is that a read-only
consumer over local disk does not need per-object hashing, but the
benchmark, not the lean, makes the call.

**Benchmark verdict (2026-08-14, M1 exit;
`crates/gitility-core/benches/RESULTS.md`):** verify's share of adapter
read time on a real corpus is 31% for tree walks and 35% for blob
sweeps, zero for headers — but the absolute cost at agent-query
granularity is microseconds (≈0.7 ms per thousand-entry recursive
listing). Decision: **`verify: :always` stays the universal default.**
The guarantee is the product's identity and the differential gate leans
on it; a relaxed opt-in mode for trusted local bulk workloads is
deferred until a real bulk path demands the ~35% back, and will be an
explicit per-open knob, never a changed default. For each object under
verification, Gitility recomputes the Git object ID from:

```text
<type> <byte-size>\0<payload>
```

It rejects a mismatched ID, kind, or size. Verification is Gitility's own code
and is hash-agnostic (both SHA-1 and SHA-256) independent of upstream (R1).
Cached objects are immutable and keyed by hash algorithm plus full object ID.
Abbreviated IDs are resolved only by stores that can prove uniqueness.
Header replies cannot be verified (there is no payload to hash). Gitility
trusts them for type/size metadata only; they never influence which bytes are
served (payload reads always verify). A backend that cannot answer headers
truthfully should not export `read_headers` — the fallback verifies via full
reads. Direct header sizes have a 2^40-byte sanity ceiling and cached direct
headers are marked unverified.

### Layered ODBs

ODB composition supports read-through layers:

```elixir
{:ok, odb} =
  Gitility.ODB.layer([
    Gitility.ODB.cache(max_bytes: 128 * 1_024 * 1_024),
    remote_odb
  ])
```

Layers are queried in order and must share a runtime and hash algorithm. A
successful remote read populates earlier writable cache layers when allowed.
`Gitility.ODB.cache/1` stores verified, inflated object payloads with byte,
entry, and per-object caps. Disk caching is never implicit.

## Remote pack storage

The callback ODB solves remote access universally, but an object-at-a-time
service is not optimal for repositories already stored as normal Git packs.
Two adapters share one storage model — an immutable pack manifest fetched
through a `RangeBackend` — and differ only in access policy:

- `Gitility.ODB.PackFetch` **eagerly materializes** whole packs into memory or
  an explicit directory, then serves queries through stock gix-pack at local
  speed. Thin and low-risk; ships in 0.2.
- `Gitility.ODB.PackRange` **lazily range-reads** pack bytes behind a block
  cache. This is the net-new reader (F2), scoped as Milestone 5 behind
  checkpoint C1, for repositories too large or too sparsely touched to
  hydrate.

### The driving scenario

An ephemeral node (Docker, no durable filesystem) must "load" a bare repo
published to S3 or Postgres, then answer many queries fast. Naive
object-at-a-time remote reads fail this: same-region S3 GETs cost 30–80 ms
to first byte, and delta chains serialize round trips. But packs at the
relevant scale (tens to a few hundred MB) hydrate in seconds over parallel
ranged reads, after which every query is indistinguishable from a local bare
repository — and once the bytes are local, gitoxide's whole-file access
model (F2) stops being an obstacle, so eager hydration needs none of the
lazy reader's new Rust.

Targets, tracked in CI benchmarks: load (manifest + index + pack fetch +
checksum verification) ≤ 3 s for a 100 MB pack on same-region S3; warm
queries within noise of the local ODB adapter. A Postgres-backed
`RangeBackend` (~1 ms same-VPC range reads) should make even lazy cold
queries feel interactive.

### Eager hydration — `Gitility.ODB.PackFetch`

```elixir
{:ok, odb} =
  Gitility.ODB.PackFetch.start_link(
    backend: {MyApp.PackStore, backend_options},
    into: :memory,                     # or {:dir, "/var/cache/gitility"}
    concurrency: 8,
    verify: :always
  )

{:ok, snapshot} = Gitility.Snapshot.open(odb, commit_oid)
```

Load fetches the manifest, then all index and pack files through coalesced
parallel range reads, verifies pack and index checksums, and hands the bytes
to the standard gix-pack machinery. `into: :memory` holds pack bytes in
Rust-owned memory, counted against explicit ceilings; `into: {:dir, path}`
writes them under the caller-supplied directory keyed by pack checksum, so a
reused volume makes restarts near-free while a fresh container re-pays a few
seconds. Both destinations are declared by the caller — the
no-implicit-materialization principle bans hidden writes, not explicit ones.
`refresh/1` re-reads the manifest and fetches only packs it has not seen.

### Single-file bundles — `Gitility.Bundle`

A repository published for querying is naturally several artifacts: packs,
indexes, a manifest, and a refs snapshot. `Gitility.Bundle` packages all of
them as **one SQLite file**. SQLite is a proven application file format —
Fossil SCM stores entire repositories this way — and a single file makes
publish, copy, and cache operations atomic by construction: no
manifest-points-at-missing-pack states, ever.

This is not a side feature. For the driving use case — an easy-to-deploy,
easy-to-manage Git browser for agents — "clone a repository to a single S3
object, open it anywhere" is the product's acquisition story, and the
bundle is core to it. It is designed inside the library, versioned with the
library, and exercised by the same conformance suites as every other store.

Mechanism (F6): bundle reading and writing are implemented **natively in
`gitility-core` via the `turso_core` crate** — Turso Database, the
SQLite-compatible engine written in Rust — keeping the project pure Rust
with no C toolchain anywhere in the build. Bundle files are standard
SQLite format, so they remain inspectable and repairable with any SQLite
tooling. The bundle store is a native store — local file access never
round-trips through an Elixir provider — and presents the same internal
range-read seam as the remote backends. Elixir-side implementations were
evaluated and rejected for the read path: `exqlite` lacks incremental blob
I/O entirely, and `ex_turso` (a DBConnection wrapper over the same `turso`
crate) would put an Elixir hop inside a local native read loop — though its
existence is useful prior art that the `turso` crate runs happily under
Rustler. If conformance or fuzz testing surfaces a Turso blocker, the
recorded fallback is `rusqlite` with the `bundled` static amalgamation
(verified: true incremental blob I/O), swapped behind the seam.

Schema: pack and index bytes as chunked blobs (1 MiB rows, deliberately the
same shape as the Postgres backend), a manifest table, a refs table
capturing the ref state at publish time, and a metadata table (hash
algorithm, bundle format version, source identity). Packs stay packs —
objects are **never** stored row-per-object, which would forfeit Git's delta
compression and balloon the file.

Consumption is symmetrical with everything else in this document:

- the native bundle store serves `PackFetch` (or `PackRange`) directly from
  a local bundle file through SQLite incremental blob I/O;
- it also implements `RefDB.Backend` from the refs table, so **one file
  opens as a complete repository** — ODB plus refs — with no other
  infrastructure;
- `into: {:bundle, path}` is a `PackFetch` hydration destination, so a
  remote store hydrates into a local bundle that survives restarts on a
  reused volume;
- `Gitility.Bundle.write/2` builds a bundle from any ODB + refs source (a
  local bare repository in the first release), giving the publish pipeline a
  one-file artifact: repack, write bundle, upload.

The refs table also answers "where do branch names live when the repo lives
in S3": they are snapshotted into the bundle at publish, and a fresher
answer is a `RefDB.Backend` call away when the caller wants live refs
instead.

### Updating a bundle

Updates are incremental by design, because the manifest-of-packs model is
Git's own accumulation model. An incremental `git fetch` produces one new
pack containing only missing objects; updating the bundle is appending that
pack's chunked blobs, rewriting the refs table, and bumping the manifest
generation in **one SQLite transaction** — readers see the old repository or
the new one, never a torn state, and existing pack blobs are never touched.
Update cost is proportional to what changed, not to repository size. (Fetch
packs arrive thin; a pipeline that runs real `git fetch` gets them completed
by `index-pack --fix-thin` before they reach the bundle.)

Periodic **repack** is the only whole-bundle rewrite and is a health
operation on git's own auto-gc-style cadence (pack count above ~20, or
garbage fraction from force-pushes and deleted branches too high), followed
by `VACUUM` to reclaim the file space of dropped packs. `Bundle.write/2`
performs it by rebuilding from a repacked source.

Native fetch-into-bundle — the library speaking smart HTTP and appending
with no git binary — is the acquisition feature this plan deliberately
defers (transport, negotiation, thin-pack completion, pack indexing); it
remains a post-1.0 candidate and the upstream pack-indexing plumbing it
needs exists.

### Lazy range reads — build, don't upstream

`PackRange` is the adapter for repositories that should not be fully
hydrated. Verified upstream reality (F2): `gix-pack` requires whole files
addressable in memory, no range abstraction exists, and the maintainer has
explicitly deferred pluggable storage. The original plan's "contribute a
`ReadAt` abstraction upstream first" would put our critical path behind an
upstream design process that is not underway. Instead:

- `gitility-core` implements its own range-aware pack/index reader in
  `crates/gitility-core/src/pack/`: `.idx` fan-out and offset-table lookups via
  targeted range reads, zlib inflation over fetched byte ranges, and delta
  resolution through the normal ODB lookup path.
- It reuses Gitoxide's low-level parsing primitives and formats where they
  are range-friendly, but owns the access model.
- It presents the same `ObjectDb`/`Find` seam as every other store (F1), so
  nothing above it is aware of packs.
- If upstream later grows a real range abstraction, swapping the internals is
  invisible to the Elixir API.

The internal Rust contract:

```rust
pub trait ReadAt: Send + Sync + 'static {
    fn len(&self) -> Result<u64, Error>;
    fn read_exact_at(&self, offset: u64, out: &mut [u8], budget: &Budget)
        -> Result<(), Error>;
    fn prefetch(&self, ranges: &[Range<u64>], budget: &Budget)
        -> Result<(), Error>;
}
```

This trait never appears in the Elixir API. `PackRange` remains stable while
the Rust implementation evolves.

### Immutable pack inventory

A pack source publishes an atomic manifest:

```elixir
%Gitility.PackManifest{
  version: 1,
  generation: "01K...",
  hash: :sha1,
  packs: [
    %Gitility.PackDescriptor{
      id: pack_checksum,
      pack_key: "packs/pack-<checksum>.pack",
      index_key: "packs/pack-<checksum>.idx",
      pack_size: 123_456_789,
      index_size: 3_456_789,
      etag: "..."
    }
  ],
  loose: []
}
```

Pack and index keys are immutable and content-addressed. Publishing a new
generation never rewrites an existing pack. Removed packs remain readable for
a grace period so in-flight jobs can finish. On a missing pack, the adapter
may refresh the manifest and retry object lookup once within the original
budget.

### Range backend behaviour

```elixir
defmodule Gitility.ODB.RangeBackend do
  @type state :: term()

  @callback init(term()) :: {:ok, state()} | {:error, term()}

  @callback manifest(state()) ::
              {:ok, Gitility.PackManifest.t()} | {:error, term()}

  @callback read_ranges([Gitility.ByteRange.t()], state()) ::
              {:ok, %{Gitility.ByteRange.t() => binary()}} | {:error, term()}

  @callback terminate(term(), state()) :: term()

  @optional_callbacks terminate: 2
end
```

Same stateless-concurrent contract as `ODB.Backend`. One backend module
serves both `PackFetch` and `PackRange` — the adapters differ in access
policy, not transport. The backend can use Req, S3, a connector agent,
signed URLs, database blobs, or another transport. Credentials remain in the
provider process unless a native transport is explicitly chosen.

Two reference backends ship with the library's docs and conformance tests:

- a local-directory backend (fixtures and development);
- a Postgres chunked-pack backend — pack and index files stored as 1 MiB
  `bytea` rows keyed by `(pack_id, chunk_index)`. Same-VPC reads cost about
  a millisecond, 30–80× lower latency than S3, and most deployments already
  run Postgres; for small and medium repositories this is often a better
  home than object storage. S3-style ranged HTTP is a documented example
  rather than a built-in (a native S3 adapter is post-1.0).

Index files are fetched and verified in full because they are relatively
small and needed for OID lookup. Pack data is fetched through coalesced
fixed-size blocks with an adaptive read-ahead cache. Delta bases are resolved
through the same cache and normal ODB lookup path.

### Remote-pack cache policy

- Entire `.idx` files: memory cached by pack checksum.
- Pack bytes: block cache, default 256 KiB blocks, coalesced up to a
  configured request maximum.
- Inflated objects: shared verified object LRU.
- Delta bases: bounded per-worker cache plus shared object cache.
- No disk cache unless a caller explicitly supplies one.
- Every cache has byte and entry ceilings and exports hit/miss/eviction
  stats.

### Operating many repositories per node

Hydrated packs and caches are per-ODB memory. The library enforces ceilings
per handle and exposes resident bytes (pack bytes, cache bytes) through
stats and telemetry; it deliberately does not decide eviction across
repositories. The application layer keeps an LRU of open ODB handles and
closes idle ones — closing a handle releases its native memory promptly, and
reopening later is one hydration away. Node budget arithmetic is therefore
explicit: open handles × (pack size + configured cache ceilings). This
guidance ships in the operational docs (Milestone 6).

## Query runtime

### Rust-owned worker pool

Each `Gitility.Runtime` owns one bounded native runtime resource. CPU-heavy Git
operations use these native workers rather than dirty CPU schedulers.
Provider callbacks are messages from native worker threads via Rustler
`OwnedEnv`; final completion is also sent as a small notification.

The completed Rust DTO remains in the job resource until a bounded dirty-CPU
`take_result/1` NIF encodes it into Elixir structs. Large blob payloads use
NIF binaries. Result encoding limits are enforced before term creation.
Provider replies are bounded and scheduled away from normal schedulers when
they must copy object bytes into Rust-owned memory.

### Backpressure

- Queue admission can return `:busy` with `retry_after_ms`.
- Per-owner job ceilings prevent one process from monopolizing a runtime.
- Provider calls have independent concurrency and byte ceilings.
- Search/diff/blame can use internal parallelism only within the job's
  assigned permit count.
- A job's full resource budget includes cache misses and provider work.

### Cursors

Pagination cursors are opaque URL-safe binaries containing a versioned,
checksummed continuation state:

- snapshot commit ID and hash algorithm;
- operation and normalized option fingerprint;
- last traversal position;
- storage generation where required.

Cursors are untrusted input. They are parsed with strict size limits and must
match the operation, options, and snapshot. They contain no secrets and
require no server-side session.

**Cursor wire format v1** (frozen 2026-08-14; implemented in
`gitility-core`'s cursor module, base64url-encoded without padding at the
NIF boundary):

```text
offset  size  field
0       1     format version        (0x01)
1       1     hash kind             (0x01 = sha1, 0x02 = sha256)
2       D     snapshot commit digest (D = 20 or 32, per hash kind)
2+D     1     operation tag          (0x01 list_tree, 0x02 search,
                                      0x03 log, 0x04 history, 0x05 refs)
3+D     8     option fingerprint     (FNV-1a 64 of the normalized
                                      options, little-endian)
11+D    2     generation length G    (u16 LE; 0 = no storage generation)
13+D    G     storage generation bytes
13+D+G  2     position length N      (u16 LE)
15+D+G  N     position payload       (operation-specific; list_tree and
                                      search: the raw path bytes of the
                                      last emitted item, resumed by
                                      strictly-greater traversal order;
                                      log/history: last emitted commit
                                      digest)
…       4     CRC32 (IEEE) of every preceding byte (LE)
```

Decoding enforces, in order: total length ≤ 4096 bytes, CRC, version,
then hash kind / digest / operation tag / fingerprint equality with the
query being resumed — any failure is `:invalid_cursor`, and a version
this build does not know is `:invalid_cursor` too (cursors are
short-lived continuations, not archival artifacts; new versions may be
added but v1 fields are never reinterpreted). Position payloads are
themselves untrusted and re-validated against the operation's own
bounds. The operation-tag and position-payload registries grow
append-only.

## Limits and safety

All operations accept `%Gitility.Limits{}` and merge it with package defaults:

```elixir
%Gitility.Limits{
  timeout_ms: 30_000,
  max_objects: 100_000,
  max_object_bytes: 4 * 1_024 * 1_024,
  max_total_object_bytes: 256 * 1_024 * 1_024,
  max_provider_requests: 500,
  max_provider_bytes: 256 * 1_024 * 1_024,
  max_tree_entries: 20_000,
  max_results: 1_000,
  max_diff_files: 1_000,
  max_diff_hunks: 10_000,
  max_diff_lines: 100_000,
  max_result_bytes: 8 * 1_024 * 1_024,
  max_delta_depth: 128
}
```

Operation-specific options (`limit:`, `max_bytes:`, …) may lower but never
raise hard runtime ceilings without an explicitly more permissive limit
profile.

Required safeguards:

- validate pack and object allocation sizes before allocation;
- verify object IDs and pack/index checksums;
- cap delta depth and total inflated bytes;
- reject NUL and semantic `.`/`..` path segments in path queries;
- never follow symlinks or gitlinks implicitly;
- never run checkout filters, textconv, hooks, or external diff drivers;
- use a linear-time regex engine;
- cap individual line and preview lengths;
- treat object contents, commit metadata, and paths as untrusted bytes;
- redact provider configuration and credentials from errors and telemetry;
- surface truncation explicitly rather than silently dropping data;
- make caller death and timeout interrupt native work;
- fuzz every parser or adapter boundary that consumes remote-controlled
  bytes.

## Error model

Normal failures return `{:error, %Gitility.Error{}}`; the public API does not
raise for repository data, missing objects, timeouts, or backend failures.

```elixir
%Gitility.Error{
  code: :missing_object,
  message: "required tree object is not available",
  operation: :list_tree,
  retryable: true,
  details: %{oid: oid, context: :commit_tree},
  cause: nil
}
```

Stable initial codes:

```text
invalid_argument          invalid_oid              invalid_path
invalid_cursor            unsupported_hash         unsupported_operation
unsupported_regex         not_a_commit             not_a_tree
not_a_blob                ref_not_found            ambiguous_prefix
missing_object            shallow_boundary         malformed_object
malformed_ref             hash_mismatch            pack_checksum_mismatch
index_checksum_mismatch   object_too_large         budget_exceeded
result_too_large          timeout                  await_timeout
cancelled                 busy                     provider_down
provider_timeout          provider_protocol_error  backend_error
runtime_mismatch          internal_error
```

Backend-specific reasons may appear only in a sanitized `cause`; callers
branch on `code` and `retryable`.

Truncation is a successful result with `truncated: true`, a cursor where
continuation is possible, and a warning explaining which limit was reached.

## Feature inventory

### Required for 0.1

- SHA-1 query execution; SHA-256-ready types, cursors, and verification with
  a clean `:unsupported_hash` refusal (R1).
- Local bare/normal ODB adapter, never reading worktree files.
- Static in-memory ODB.
- Elixir callback ODB with required batch reads and concurrent dispatch.
- ODB layering and the verified cache layer.
- Snapshot creation from a commit ID.
- Commit, tree, tag, and blob decoding.
- Path lookup and bounded tree traversal.
- Bounded file reads and line slicing.
- Literal and safe-regex snapshot search.
- Commit graph traversal and merge base.
- Structured tree and blob diffs.
- Arbitrary-commit blame returning hunks (ranges + rename following; no
  first-parent, R7).
- Async jobs, cancellation, timeouts, queue bounds, limits, errors, and
  telemetry.
- Explicit runtime instances plus the zero-config default.
- Differential tests against canonical Git with the divergence-allowlist
  policy.

### Required for 0.2

- Elixir reference backend and repository composition.
- Local reference adapter and safe branch/tag/ref selectors.
- Path history with optional rename following (own algorithm, R3).
- Rename/copy detection and richer diff stats.
- Annotated tags and signature header exposure.
- LFS pointer recognition.
- Submodule/gitlink metadata helpers.
- ODB provider conformance test kit.
- Pack manifest, `RangeBackend` contract, and eager `PackFetch` hydration
  (memory or explicit directory) meeting the ephemeral-node load targets.
- Local-directory and Postgres chunked-pack reference range backends.
- `Gitility.Bundle`: the single-file SQLite repository container — builder
  plus ODB and refs backends reading from one file.

### Required for 1.0

- Lazy pack-range ODB if checkpoint C1 confirms the need (the manifest,
  `PackFetch`, and bundles land in 0.2).
- Range coalescing, read-ahead, checksum verification, and cache telemetry.
- Storage-generation-aware cursors and refresh.
- Fault-injection and soak tests for remote providers.
- Stable serialized DTO and cursor versions.
- Precompiled NIFs for supported targets.
- Complete Hex docs, examples, migration policy, and changelog.
- Gentility integration proving CodeExplorer no longer requires a tarball
  hydration or Sprite for read-only exploration.

### Post-1.0 candidates

- SHA-256 query execution, once upstream lands (R1) — highest-priority
  candidate given Git 3.0.
- First-parent blame (R7).
- Streaming tar/archive creation directly from a tree.
- A content-addressed search index keyed by blob ID.
- Partial-clone/promisor acquisition and missing-object hydration.
- Built-in HTTP ODB client/server protocol.
- Built-in S3 pack-range adapter; the generic RangeBackend lands first.
- Commit signature verification.
- Pack ingestion and read-only fetch/clone helpers.
- Optional LFS object resolver.
- Repository resolver for recursive submodule queries.
- A separate write capability for object creation and ref transactions.

## Result and type conventions

- OIDs are `%Gitility.OID{algorithm: :sha1 | :sha256, bytes: binary}`.
  `to_string/1` emits lowercase hex. Public functions accept full lowercase
  or uppercase hex strings as convenience but return typed OIDs.
- Git paths and object contents are raw binaries. No UTF-8 normalization
  occurs.
- Commit identity preserves raw name/email bytes plus decoded display
  helpers.
- Times preserve seconds, offset, and sign exactly as encoded by Git.
- File modes map to typed entry kinds without discarding the original mode.
- All collections that can grow return `%Gitility.Page{}` or another result
  carrying `truncated`, `stats`, and `warnings`.
- Stats include objects requested/read, cache hits/misses, provider rounds,
  provider bytes, decompressed bytes, scanned blobs, elapsed time, and the
  limit that stopped work.
- DTOs are versioned Elixir structs, not arbitrary maps or Gitoxide structs.

## Telemetry

Emit:

```text
[:gitility, :job, :queue]
[:gitility, :query, :start]
[:gitility, :query, :stop]
[:gitility, :query, :exception]
[:gitility, :odb, :request, :start]
[:gitility, :odb, :request, :stop]
[:gitility, :odb, :cache]
[:gitility, :query, :truncated]
```

Measurements include duration, queue time, bytes, counts, and cache metrics.
Metadata includes operation, backend kind, hash algorithm, runtime name,
result status, and limit code. It must not include query text, paths, remote
URLs, headers, credentials, commit messages, or object content by default.

## Testing strategy

### Differential oracle and the divergence allowlist

Run the same fixture queries through:

1. Gitility/Gitoxide;
2. canonical `git` plumbing commands;
3. an internal `git2-rs`/libgit2 oracle during early development.

Compare normalized object IDs, tree entries, revision walks, merge bases,
diffs, rename detection, blame hunks, and path history. The libgit2 oracle is
a test dependency or separate harness, not the production engine.

CI pins the canonical `git` version (and the libgit2 version while that
oracle exists); each allowlist entry records the git version it was triaged
against. Oracle upgrades are deliberate events, like gix upgrades —
otherwise divergence triage silently chases upstream git behavior changes.

Exact agreement is required by default. Where the engine is known to deviate
from canonical Git — blame under rename tracking (F4, ~92.6% corpus line
agreement at the time of writing) and rename-candidate selection in path
history (F5) — the suite uses a **triaged known-divergence allowlist**: every
differing fixture case is reproduced, classified, and either fixed or
committed to the allowlist with a written explanation. A new divergence fails
CI. The aggregate agreement ratio is recorded per run and treated as a
regression metric. Blanket tolerances ("90% is fine") are not acceptable;
they hide new bugs behind old ones.

### Fixture corpus

Include:

- SHA-1 and SHA-256 repositories (the latter exercising the refusal path
  until the engine supports them, R1);
- loose, packed, multi-pack-index, and alternate ODBs;
- merge-heavy and criss-cross histories;
- annotated and lightweight tags;
- shallow boundaries and intentionally missing objects;
- weird and invalid-UTF-8 paths;
- symlinks, executable files, empty blobs/trees, and submodules;
- binary files, very long lines, huge blobs, and repeated blobs;
- rename/copy cases with exact and similarity matches, including cases known
  to exercise the four-candidate deviation (F5);
- corrupt object headers, hashes, pack entries, delta chains, and indices;
- LFS pointers;
- replace refs and graft-like edge cases where supported.

### ODB conformance kit

Ship `Gitility.ODB.BackendCase`, a reusable ExUnit contract suite. Backend
authors provide a fixture loader; the suite verifies:

- found, missing, and batched objects;
- exact byte/type preservation;
- hash mismatch rejection;
- concurrent callback dispatch up to the configured concurrency;
- provider timeout and crash behavior;
- duplicate, omitted, and unexpected reply IDs;
- cancellation and late replies;
- negative cache expiry;
- concurrent reads and refresh;
- byte and request caps.

Provide an equivalent RangeBackend contract suite for manifests, range
bounds, short reads, ETag/generation changes, corrupt data, and vanished
packs.

### Rust tests and fuzzing

- Unit and property tests for all core algorithms and limits.
- `cargo-fuzz` targets for object, commit, tree, tag, pack, index, cursor,
  and provider reply decoding.
- Fault injection for allocation failure boundaries, cancellation points,
  and range-reader short/error responses.
- Loom or targeted concurrency tests for job completion, provider replies,
  cancellation, and resource teardown where practical (R6).
- Sustained mixed-query soak tests under BEAM process churn.

### Benchmarks

Measure local and remote modes independently:

- open/snapshot latency;
- tree entries per second;
- cold and warm file reads;
- eager hydration and bundle-open time versus pack size and fetch
  parallelism;
- search throughput and deduplicated-blob savings;
- diff/blame/history throughput;
- callback provider round trips and batch efficiency;
- pack-range bytes fetched versus useful bytes;
- cache hit ratios and memory ceilings;
- cancellation latency;
- BEAM scheduler responsiveness under maximum native load.

## Packaging and releases

Follow the established ExBashkit pattern:

- `rustler ~> 0.38` optional for source builds (0.38.0 current);
- `rustler_precompiled ~> 0.9` required for consumers (0.9.0 current);
- force source build with `GITILITY_BUILD=1`;
- publish checksummed NIFs from GitHub releases;
- initial targets:
  - `aarch64-apple-darwin`
  - `x86_64-apple-darwin`
  - `aarch64-unknown-linux-gnu`
  - `x86_64-unknown-linux-gnu`
- add musl only after the TLS and Gitoxide feature set is intentionally
  chosen;
- **Windows is explicitly out of scope** — no targets, no CI, no
  source-build support claims. Elixir is not deployed on Windows in
  practice, and the agent-hosting use case is Linux/macOS only. Revisit
  only on demonstrated demand;
- build with a pinned Rust toolchain and committed `Cargo.lock`;
- generate SBOMs and provenance attestations for release artifacts;
- run the complete ODB conformance suite against precompiled artifacts
  before publishing Hex.

Use semantic versioning for the Elixir API. Changes to Gitoxide versions are
internal unless they change documented behavior. Cursor and callback protocol
versions are independent and explicitly encoded.

## Implementation sequence

### Milestone 0 — repository, contracts, and oracles

1. Create the standalone Mix/Rust workspace and precompiled-NIF skeleton.
2. Define all public Elixir structs, errors, limits, OID/path helpers, and
   function specs with NIF stubs.
3. Define Rust DTOs and the stable `ObjectDb`, `RefDb`, `Budget`, and error
   contracts.
4. Add canonical Git and libgit2 differential harnesses before implementing
   queries.
5. Build the fixture corpus (both hash algorithms) and initial fuzz targets.
6. Spike F6: many `turso_core` connections reading one SQLite file from
   concurrent native threads, verified correct under load. Expected to just
   work (read-only, immutable file); proven with a test, not assumed —
   this is the cheapest moment to trigger the rusqlite fallback if it ever
   triggers.

Exit criterion: API documentation builds, fixture/oracle harnesses run, and
no Gitoxide or Rustler type appears in the public Elixir specs or core DTO
API.

### Milestone 1 — local object-native core

1. Implement OID parsing, hash-agnostic object verification, and object
   decoding.
2. Implement the local bare/normal ODB adapter using Gitoxide, with no
   worktree reads.
3. Implement the static ODB.
4. Implement snapshots from commit IDs, path lookup, tree pages, and file
   reads.
5. Add budgets, truncation, cursors, and normalized errors.

Exit criterion: tree and file queries match Git across SHA-1 local fixtures,
including invalid UTF-8 paths and corrupt inputs; SHA-256 fixtures return
`:unsupported_hash` cleanly.

### Milestone 2 — job runtime and callback ODB

1. Implement `Gitility.Runtime` instances and the bounded Rust-owned worker
   pool with job resources.
2. Implement await (both timeout kinds), cancellation, caller monitoring,
   queue bounds, and result handoff.
3. Implement the provider request-resource protocol with concurrent
   stateless dispatch.
4. Implement `ODB.Backend`, the provider process, batching, prefetch,
   verification, negative caching, and provider conformance tests.
5. Implement layered ODBs and `ODB.cache`.
6. Implement the pack manifest, `RangeBackend` contract, eager `PackFetch`
   (memory and explicit-directory destinations), and the local-directory and
   Postgres reference backends.

Exit criterion: all Milestone 1 queries work with an ODB whose objects arrive
through Elixir callbacks, with no local repository files, bounded provider
request counts, and callbacks demonstrably executing concurrently. A pack
published to a remote store hydrates through `PackFetch` on a
filesystem-free node and serves Milestone 1 queries at local-adapter speed.

### Checkpoint C1 — lazy reader go/no-go

Benchmark eager `PackFetch` and the callback ODB against a representative
workload: a Gentility-scale repository published to same-region S3 and to
the Postgres reference backend, opened on an ephemeral filesystem-free node,
realistic query mix, cold and warm. Decide with data:

- If eager hydration meets the load-time targets and node memory budgets for
  the repositories that matter, **the lazy `PackRange` reader moves
  post-1.0** and 1.0's remote story is hydrate-then-query.
- If real repositories are too large to hydrate, or fleet density makes
  per-node hydration wasteful, the lazy reader proceeds as Milestone 5 with
  the measured targets to beat.

Either way the public API is unchanged — `PackRange` is one more ODB behind
the same manifest and backend contracts. The checkpoint changes schedule
risk, not architecture. Record the decision in this document.

### Milestone 3 — semantic exploration

1. Implement literal and safe-regex search.
2. Implement commit log (including first-parent), ancestry, and merge base.
3. Implement structured summary/stats/patch diff and rename detection,
   including cross-ODB union reads.
4. Implement blame hunks (ranges, rename following; no first-parent, R7).
5. Implement path history with rename following as Gitility's own walk (R3).
6. Add LFS pointer and gitlink metadata.

Exit criterion: the full semantic API passes the differential suite under the
allowlist policy, every divergence is triaged, and every query cancels within
a documented latency.

### Milestone 4 — refs and repository composition

1. Implement `RefDB.Backend` and its provider.
2. Implement local refs, safe selectors, annotated tag peeling, and ref
   pages.
3. Compose ODB and refs into `Repository` without weakening snapshot
   pinning.
4. Add atomic ref-resolution tests where refs move during queries.
5. Write the bundle format specification **before the first byte is
   written**: exact table DDL, chunk size, manifest-generation semantics,
   the format-version field in the metadata table, and the
   reader-compatibility rule (a reader refuses a newer major format
   version with `:unsupported_operation`; minor versions are additive).
   Format version 1 is frozen on 0.2 release.
6. Implement `Gitility.Bundle` to that spec: the native store (ODB + refs
   from one file), its builder (`Bundle.write/2` — load-bearing, decided
   2026-08-14: one dependency does it all; publish pipelines should not
   need SQLite tooling of their own), and the `into: {:bundle, path}`
   hydration destination.

Exit criterion: moving branches never change an existing snapshot and remote
refs can be resolved without a local Git directory.

### Milestone 5 — lazy pack-range ODB (scope per C1)

1. Revalidate the manifest and RangeBackend contracts against lazy access
   (block-sized reads, generation grace periods).
2. Implement the range-aware pack/index reader in `gitility-core` (F2): index
   verification, OID lookup via fan-out range reads, coalesced block
   fetches, delta resolution, manifest refresh, and memory caches.
3. Benchmark against C1's recorded targets.
4. Run chaos tests for latency, short reads, corruption, provider restarts,
   generation changes, and removed packs.

Exit criterion: all semantic queries operate against remote immutable packs
with no checkout, repository copy, temporary directory, or implicit disk
cache — at or above the C1 targets.

### Milestone 6 — hardening and 1.0 release

1. Complete fuzzing, soak, concurrency, and allocation-limit audits.
2. Publish telemetry and operational guidance.
3. Produce precompiled artifacts and verify them in CI.
4. Publish backend authoring guides and conformance kits.
5. Integrate Gentility CodeExplorer behind a behaviour and run both backends
   in shadow comparison.
6. Remove Sprite dependence from Gentility's read-only exploration path
   after parity and operational acceptance.

Exit criterion: the 1.0 done criteria below are satisfied.

## 1.0 done criteria

- No semantic read operation requires a worktree, VFS, shell, or checked-out
  file.
- Local, static, callback, layered, `PackFetch`, bundle, and (per C1) lazy
  pack-range ODBs pass the same contract suite.
- An ODB plus commit ID is sufficient for every snapshot query.
- Refs are optional and independently pluggable.
- Remote reads meet the C1-recorded performance targets with bounded caches;
  no pack or repository is copied to disk or memory except through an
  explicitly declared hydration destination.
- All large collections paginate or explicitly truncate.
- All jobs are bounded, cancellable, observable, and cleaned up on caller or
  provider death.
- Remote object and pack contents are verified and corrupt data is rejected.
- Search, history, diff, blame, and tree/file reads pass differential tests
  under the allowlist policy with zero untriaged divergences.
- The BEAM remains responsive and within configured memory ceilings under
  the documented concurrency limit.
- Precompiled NIFs install without a Rust toolchain on supported targets.
- Gentility can answer its current codebase search/read/list use cases from
  a non-filesystem ODB.

## Gentility integration shape

Gitility knows nothing about organizations, GitHub integrations, Factory Cases,
Sprites, or MCP. In Gentility, add a domain behaviour:

```elixir
defmodule Gentility.CodeExplorer.Backend do
  @callback snapshot(scope, selector) ::
              {:ok, backend_snapshot} | {:error, term()}

  @callback list_tree(backend_snapshot, args) :: {:ok, term()} | {:error, term()}
  @callback read_file(backend_snapshot, args) :: {:ok, term()} | {:error, term()}
  @callback search(backend_snapshot, args) :: {:ok, term()} | {:error, term()}
  @callback history(backend_snapshot, args) :: {:ok, term()} | {:error, term()}
  @callback diff(backend_snapshot, args) :: {:ok, term()} | {:error, term()}
  @callback blame(backend_snapshot, args) :: {:ok, term()} | {:error, term()}
end
```

with the current Sprite path (`Hydrator` + `Operations`) as one
implementation and the Gitility path as the other, run in shadow during rollout.

### Object acquisition — the part the tarball model never needed

Today Gentility holds **no Git objects at all** for explored repos: the
Sprite gets a tarball of one tree. Gitility queries need real objects, so the
integration must choose an acquisition strategy (all outside the library):

1. **Published bundles + `PackFetch`** — a server-side pipeline (an Oban
   worker running `git fetch`/`git repack` with the GitHub App installation
   auth, or a Sprite doing the same) publishes each repo as a
   `Gitility.Bundle` SQLite file to S3 or the Postgres pack store; ephemeral
   app hosts hydrate a repo in seconds at query time. Fits the Docker
   deployment (no durable local filesystem), gives full history (enabling
   `code_history`, `code_diff`, `code_blame`, which the tarball model
   structurally cannot), and snapshots refs at publish time. This is the
   recommended rollout path once `PackFetch` and bundles land (0.2).
2. **Per-repo bare mirrors on a persistent volume** — read through the local
   ODB adapter; works from 0.1 and is the quickest shadow-mode spike, but
   conflicts with ephemeral hosts. A stepping stone, not the destination.
3. **Callback ODB over the GitHub Data API** — blobs/trees/commits by SHA,
   batched via GraphQL, behind `Gitility.ODB.Backend`. Zero storage; bounded
   by rate limits; a good fit for first-touch exploration before a repo's
   bundle exists, and a natural second implementation to validate the
   backend contract.
4. **Lazy `PackRange`** — only if checkpoint C1 shows Gentility repos
   outgrow hydration.

`RefDB` note: branch/PR selectors resolve through a GitHub-backed
`RefDB.Backend` (or the mirror's refs in option 1); the snapshot pins the SHA
so agent runs are stable regardless of upstream pushes.

The intended agent-tool mapping is direct:

| Agent tool | Gitility operation |
|---|---|
| `code_tree` | `list_tree/3` |
| `code_read` | `read_file/3` |
| `code_search` | `search/3` |
| `code_history` | `log/2` or `history/3` |
| `code_diff` | `diff/3` |
| `code_blame` | `blame/3` |

`codebase_bash` cannot be object-native (arbitrary execution needs a real
filesystem) and stays Sprite-backed; it becomes the only tool that forces
hydration. Tool results add organization/codebase identity around Gitility's
commit, tree, and blob provenance; the library remains tenant-agnostic.

The transition shadows existing Sprite-backed operations, compares normalized
outputs, records latency/provider stats, and falls back only while the new
backend is explicitly in rollout. A fallback must never silently change the
resolved commit.

Separately: `Gentility.Sync`'s per-org bare repos become readable through
Gitility's local adapter, which may eventually retire `egit` — noted, not
scoped.

## Recommended first implementation session

Start with Milestone 0 only. The purpose of the first session is to make the
architecture difficult to accidentally erode, not to demonstrate a local Git
query as quickly as possible.

Use this scope:

1. Create the standalone Mix/Rust workspace and source-build NIF skeleton.
2. Encode the public modules, structs, behaviours, typespecs, and normalized
   errors from this document, with documented examples and unimplemented NIF
   stubs where necessary.
3. Define the Rust core traits and DTOs without depending on Rustler.
4. Commit tiny SHA-1 and SHA-256 fixtures, including invalid UTF-8 names,
   merges, renames, binary blobs, annotated tags, and corruption cases.
5. Build a differential harness that can ask canonical Git for expected
   object, tree, log, diff, and blame results, with the divergence-allowlist
   mechanism in place from the start. Add libgit2 as a secondary oracle
   where useful, never as the production engine.
6. Add CI for Elixir formatting/tests, Rust formatting/clippy/tests, API
   docs, and the differential fixtures.

Stop for an API review once that passes. In particular, do not let
Milestone 0 grow a path-shaped `Repository` resource or expose a Gitoxide
type merely to make the first native call convenient. Milestone 1 begins
only after an in-memory `ObjectDb` test double can drive the Rust core
without Gitoxide or a filesystem.

## Explicit decisions and deferrals

- **Name it `gitility`, not after the engine.** The engine is an internal
  detail by this document's own rules; Git + utility says what the library
  is, with a nod to its Gentility origins; `ex_gix` already occupies the
  binding-shaped name space. Easily changed before first publish; frozen
  after.
- **Start fresh; do not fork egit.** egit is command-shaped and serves
  `Gentility.Sync`, a different feature. Reuse lessons and fixtures, not its
  boundary.
- **Use Gitoxide, not libgit2, in production.** Keep `git2-rs` as an early
  oracle/fallback harness.
- **Use Rustler with explicit Rust-owned runtime instances.** Dirty NIFs
  alone satisfy neither callback ODBs nor cancellation; ambient global
  config satisfies neither isolation nor modern library convention.
- **Backend callbacks are stateless and concurrent.** GenServer-style state
  threading would make every provider a serialization point; backends that
  need mutable state own it explicitly.
- **Hydrate eagerly by default; range-read lazily only where proven
  needed.** `PackFetch` covers the ephemeral-node use case with stock
  gix-pack over explicitly fetched bytes; the lazy reader is our own Rust
  (F2 — upstreaming is not plannable), lives behind the `Find`-shaped seam,
  and is built only if checkpoint C1 shows hydration cannot serve the
  repositories that matter.
- **Explicit materialization is not hidden materialization.**
  `into: :memory`, `into: {:dir, path}`, and `into: {:bundle, path}` are
  caller-declared destinations with ceilings; the ban is on silent writes.
- **One file beats a directory of artifacts.** Published repositories travel
  as SQLite bundles — packs kept as packs (never row-per-object, which
  forfeits delta compression), with manifest and refs snapshot riding in the
  same atomic file.
- **Turso over C SQLite (F6).** The bundle engine is `turso_core`, keeping
  the build pure Rust; the file format stays standard SQLite. Gitility's own
  checksums and object verification convert engine bugs into loud errors,
  which is what makes a young engine acceptable for a convenience library.
  `rusqlite`+bundled is the recorded fallback behind the same seam.
- **Object-by-OID callback ODBs are the universal remote escape hatch.**
  They ship before pack-range optimization, and checkpoint C1 decides with
  data whether the lazy reader is a 1.0 requirement or a post-1.0
  accelerator.
- **SHA-256: ready types, honest refusal (F3).** No aspirational claims; the
  engine flips on when upstream completes, and fixtures keep the path warm.
- **No first-parent blame in 0.x (F4, R7).** Omitted rather than emulated
  wrongly.
- **Path history is our own algorithm (F5).** Upstream has no `--follow`;
  we build on rewrite tracking and differential-test the deviation.
- **Await timeout ≠ job timeout.** `:await_timeout` leaves the job running;
  `:timeout` means the budget cancelled it.
- **Keep refs separate.** ODB-only snapshots are a first-class use case.
- **Verify remote objects by default.** Gentility never disables
  verification.
- **No implicit disk.** Optional caches are explicit adapters.
- **No transport/fetch in the first milestones.** Acquisition is separate
  from querying; it may be added after the ODB/query contract is stable.
- **No persistent search index in 1.0.** Design results around blob IDs so
  an index can be added without changing the query API.

## Primary references verified for this design

Upstream evidence (all re-verified 2026-08-14):

- [Gitoxide repository and project goals](https://github.com/GitoxideLabs/gitoxide)
- [`gix_object::Find`](https://docs.rs/gix-object/latest/gix_object/trait.Find.html)
  and `FindHeader` — the pluggable seam (F1); generic consumption confirmed
  in `gix-traverse`, `gix-diff`, `gix-blame`, `gix-revwalk` call sites
- [`gix-pack` `FileData`](https://github.com/GitoxideLabs/gitoxide/blob/main/gix-pack/src/lib.rs)
  — `Deref<Target = [u8]>` marker trait; whole-file access model (F2)
- [Custom storage backends discussion #1281](https://github.com/GitoxideLabs/gitoxide/discussions/1281)
  — pluggable storage explicitly deferred upstream (F2)
- [SHA-256 support plan](https://github.com/GitoxideLabs/gitoxide/blob/main/etc/plan/sha256-support.md)
  and [tracking discussion #2780](https://github.com/GitoxideLabs/gitoxide/discussions/2780)
  (F3)
- [`gix-blame` `Options`/`BlameRanges`](https://docs.rs/gix-blame/latest/gix_blame/struct.Options.html)
  and [rename-tracking PR #2022](https://github.com/GitoxideLabs/gitoxide/pull/2022)
  with its ~92.6% agreement benchmark (F4)
- [`gix_diff::Rewrites`](https://docs.rs/gix-diff/latest/gix_diff/struct.Rewrites.html)
  and crate-status's documented rename-candidate deviation (F5)
- [Gitoxide crate implementation status](https://github.com/GitoxideLabs/gitoxide/blob/main/crate-status.md)
- [Partial clone / promisor discussion #1041](https://github.com/GitoxideLabs/gitoxide/discussions/1041)
  and [PR #2375](https://github.com/GitoxideLabs/gitoxide/pull/2375)
- [Rustler project and resource model](https://github.com/rusterlium/rustler)
  (0.38.0 current)
- [Rustler `OwnedEnv` messaging constraints](https://docs.rs/rustler/latest/rustler/env/struct.OwnedEnv.html)
- [RustlerPrecompiled](https://hexdocs.pm/rustler_precompiled/RustlerPrecompiled.html)
  (0.9.0 current)
- [libgit2 custom ODB backend reference](https://libgit2.org/docs/reference/main/sys/odb_backend/git_odb_backend.html)
  (oracle harness only)
- [Turso Database](https://github.com/tursodatabase/turso) v0.7.0 —
  SQLite-compatible engine in pure Rust (F6): COMPAT.md confirms full
  SQLite file-format support, transactions, `integrity_check`, and
  `VACUUM INTO`; `turso_core::Statement::step()` confirms synchronous
  drivability without tokio
- [`ex_turso`](https://hex.pm/packages/ex_turso) — DBConnection wrapper
  binding the `turso` crate via Rustler; prior art for Turso-under-Rustler,
  not a dependency (F6)
- [`rusqlite` incremental blob I/O](https://docs.rs/rusqlite/latest/rusqlite/blob/index.html)
  (`Blob::blob_open`, `read_at_exact`) and its `bundled` static-amalgamation
  feature — the recorded C fallback if Turso fails conformance (F6);
  `exqlite` verified to contain no `sqlite3_blob_*` usage

Upstream repositories are shallow-cloned under `sources/` (gitignored) —
gitoxide, rustler, turso, rusqlite, exqlite, concord (ex_turso) — so
findings can be re-verified by reading the code directly rather than
trusting docs or memory.

Ecosystem survey (Hex, 2026-08-14): `gitility` unclaimed; prior art `xgit`,
`gitex`, `egit`, `ex_gix`, `exgit`, `ex_git_engine`, `source` reviewed in
"Why a new library".
