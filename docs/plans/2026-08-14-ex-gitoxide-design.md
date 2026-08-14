# ExGitoxide — object-native Git queries for Elixir

Date: 2026-08-14

Status: proposed; implementation-ready

## Executive decision

Build `ex_gitoxide` as a new standalone Hex library with a pure-Rust query
core based on Gitoxide and a thin Rustler adapter. Do not fork `egit` and do
not make a repository path, worktree, VFS, shell, or Git command the root
abstraction.

The library is **snapshot-first** and **read-first**:

- An immutable commit identifies the code being queried.
- An object database (ODB) supplies Git objects by object ID.
- An optional reference database resolves mutable names to object IDs.
- Queries operate on commits, trees, and blobs without checking anything out.
- Local bare repositories are one ODB adapter, not the architecture.
- Elixir-backed and remote pack-backed ODBs are first-class.
- No operation silently writes a checkout, temporary repository, or disk cache.

The initial public promise is bounded, cancellable, structured inspection:
object lookup, tree traversal, file reads, search, commit history, path history,
diffs, blame, ancestry, and reference resolution. Mutation, checkout, hooks,
filters, and arbitrary command execution are deliberately outside the first
release.

## Why a new library

The current Gentility runtime has `egit 0.2.0` over `libgit2 1.9.6`. It proves
that direct ODB reads work in the BEAM, but its boundary is shaped like a thin
set of Git commands:

- manual C++ NIF term encoding;
- full blobs and directories returned as single unbounded terms;
- inconsistent legacy result shapes;
- no pagination, budgets, cancellation, or stable query DTOs;
- a broad mutable Git surface despite the agent use case being read-only;
- repository paths and libgit2 resources embedded into the public model.

Those are API and runtime concerns, not a short list of missing functions. A
new library lets limits, snapshots, ODB composition, cancellation, and remote
access be load-bearing from the first release.

Gitoxide is the preferred engine because its lower-level crates are already
organized around object lookup traits, pack access, revision traversal, tree
and blob diffs, and blame. The high-level `gix::Repository` remains useful for
local repositories, but the remote-ODB path will use the lower-level crates so
the query engine is generic over our own object source.

## Goals

1. Query any immutable Git snapshot without a worktree.
2. Read objects from local Git storage, memory, an Elixir provider, or a remote
   immutable pack store.
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
- Automatically traversing submodules. Gitlinks are returned as typed entries;
  callers may resolve them through another repository.
- Perfect emulation of every Git revision expression. Safe selectors are the
  default; raw revspec parsing is an explicit advanced option.
- A persistent code-search service. The first search implementation scans
  snapshot blobs with strict budgets; a content-addressed index is a separate
  accelerator.

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

Every semantic query takes `%ExGitoxide.Snapshot{}`. Creating a snapshot peels
and validates a commit once and records its commit and root tree IDs. A branch,
tag, or PR selector is resolved before the snapshot is returned.

### Storage never leaks into query semantics

`read_file/3` has the same result whether the blob came from a local pack,
Elixir callback, memory, or remote range read. Provider-specific errors are
normalized at the ODB boundary.

### The NIF is asynchronous internally

Long queries do not execute on a normal or dirty BEAM scheduler. A fast NIF
enqueues work onto a bounded Rust-owned worker pool and returns a job resource.
The public synchronous API awaits that job; an asynchronous API exposes it
directly.

This is required for callback ODBs. Rustler's `OwnedEnv` can send messages from
a Rust-owned thread, while sending that way from a BEAM-managed scheduler
thread is forbidden. It also gives us real cancellation, queue bounds, and a
single place to enforce concurrency limits.

### No hidden materialization

No adapter may silently create a checkout, clone, temp directory, or disk
cache. The remote adapters use bounded memory caches by default. An optional
disk cache is an explicit caller-supplied adapter and path.

## Package and crate layout

Create a standalone repository, expected to be published as `ex_gitoxide`:

```text
ex_gitoxide/
  lib/
    ex_gitoxide.ex
    ex_gitoxide/application.ex
    ex_gitoxide/repository.ex
    ex_gitoxide/snapshot.ex
    ex_gitoxide/odb.ex
    ex_gitoxide/odb/backend.ex
    ex_gitoxide/odb/provider.ex
    ex_gitoxide/odb/local.ex
    ex_gitoxide/odb/memory.ex
    ex_gitoxide/odb/pack_range.ex
    ex_gitoxide/ref_db.ex
    ex_gitoxide/ref_db/backend.ex
    ex_gitoxide/job.ex
    ex_gitoxide/limits.ex
    ex_gitoxide/error.ex
    ex_gitoxide/page.ex
    ex_gitoxide/types/*.ex
    ex_gitoxide/native.ex
  native/
    ex_gitoxide/
      Cargo.toml
      Cargo.lock
      src/lib.rs
  crates/
    ex-gitoxide-core/
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
        limits.rs
        error.rs
  test/
  native/ex_gitoxide/tests/
  fixtures/repos/
  fuzz/
```

`ex-gitoxide-core` must not depend on Rustler or Elixir concepts. The NIF crate
adapts Rust DTOs and resources to the BEAM. Our Rust crates should use
`#![forbid(unsafe_code)]`; dependency internals remain outside that guarantee.

Pin the `gix` family exactly behind our core compatibility layer and ship the
`Cargo.lock`. Gitoxide is pre-1.0 and its public types must never cross the
Rust core or Elixir public boundaries.

## Public Elixir API

### Opening local repositories

```elixir
{:ok, repo} =
  ExGitoxide.Repository.open("/srv/git/acme/widgets.git",
    bare: true,
    object_cache_bytes: 64 * 1_024 * 1_024
  )

{:ok, snapshot} =
  ExGitoxide.Repository.snapshot(repo, {:ref, "refs/heads/main"})
```

`open/2` accepts normal or bare repositories, but queries never read worktree
files. `bare: true` rejects a non-bare repository when the caller wants that
invariant.

### Opening an ODB without a repository

```elixir
{:ok, odb} =
  ExGitoxide.ODB.from_objects(objects,
    hash: :sha1,
    verify: :always
  )

{:ok, snapshot} = ExGitoxide.Snapshot.open(odb, commit_oid)
```

`objects` is an enumerable of `%ExGitoxide.Object{oid:, type:, data:}`. This
adapter is intended for tests, small generated repositories, and callers that
already hold object data in memory.

### Opening an Elixir-backed ODB

```elixir
{:ok, odb} =
  ExGitoxide.ODB.start_link(
    backend: {MyCompany.GitObjectBackend, backend_options},
    hash: :sha1,
    verify: :always,
    request_timeout: 15_000,
    cache: [
      object_bytes: 128 * 1_024 * 1_024,
      header_entries: 100_000,
      negative_ttl: 5_000
    ]
  )

{:ok, snapshot} = ExGitoxide.Snapshot.open(odb, commit_oid)
```

The ODB provider is a supervised Elixir process. The native resource monitors
it; provider exit fails pending requests with `:provider_down` and cancels jobs
that cannot make progress.

### Composing refs with an ODB

```elixir
{:ok, refs} =
  ExGitoxide.RefDB.start_link(
    backend: {MyCompany.GitRefBackend, backend_options}
  )

{:ok, repo} = ExGitoxide.Repository.from_stores(odb: odb, refs: refs)

{:ok, snapshot} =
  ExGitoxide.Repository.snapshot(repo, {:ref, "refs/pull/481/head"})
```

Safe selectors are:

```elixir
{:oid, oid}
{:ref, full_ref_name}
{:tag, tag_name}
{:branch, branch_name}
{:head}
```

`{:revspec, string}` is an opt-in advanced selector and is unavailable when
the configured stores cannot support its required operations.

### Tree traversal

```elixir
{:ok, page} =
  ExGitoxide.list_tree(snapshot, "lib",
    recursive: true,
    depth: 4,
    types: [:tree, :blob, :symlink, :gitlink],
    pathspecs: ["**/*.ex"],
    limit: 500,
    cursor: nil
  )
```

Returns `%ExGitoxide.Page{items:, next_cursor:, truncated:, stats:, warnings:}`
whose entries are:

```elixir
%ExGitoxide.TreeEntry{
  path: raw_path_bytes,
  name: raw_name_bytes,
  oid: %ExGitoxide.OID{},
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
  ExGitoxide.read_file(snapshot, "lib/acme/widget.ex",
    lines: 120..220,
    max_bytes: 256_000
  )
```

Returns:

```elixir
%ExGitoxide.File{
  path: raw_path_bytes,
  blob_oid: %ExGitoxide.OID{},
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
`:gitlink`; text means valid UTF-8 without a binary marker under the configured
policy. The raw binary is always authoritative. `ExGitoxide.Path.display/1`
provides a lossy UI representation, and `ExGitoxide.Path.encode/1` provides a
reversible JSON-safe representation.

### Content search

```elixir
{:ok, page} =
  ExGitoxide.search(snapshot, "def handle_call",
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

`mode: :regex` uses Rust's linear-time `regex` engine. Unsupported constructs
such as backreferences and lookaround return `:unsupported_regex`; there is no
fallback to a backtracking engine.

Each `%ExGitoxide.SearchMatch{}` includes raw path, blob ID, line, byte column,
preview, submatches, and enough snapshot identity for a stable citation.

The first implementation walks the tree, deduplicates blobs by object ID,
prefetches object batches where the ODB supports it, and scans each unique blob
once. A persistent index may implement the same API later.

### Commit graph and history

```elixir
{:ok, page} =
  ExGitoxide.log(snapshot,
    order: :topological,
    first_parent: false,
    since: nil,
    until: nil,
    limit: 100,
    cursor: nil
  )

{:ok, page} =
  ExGitoxide.history(snapshot, "lib/acme/widget.ex",
    follow_renames: true,
    first_parent: false,
    limit: 50,
    cursor: nil
  )
```

Commit results include ID, parents, tree ID, raw and decoded message fields,
author, committer, time, timezone offset, optional signature headers, and
truncation metadata. Path history is budgeted separately because it may diff
many parent trees.

### Diff

```elixir
{:ok, diff} =
  ExGitoxide.diff(base_snapshot, head_snapshot,
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

### Blame

```elixir
{:ok, blame} =
  ExGitoxide.blame(snapshot, "lib/acme/widget.ex",
    lines: 120..220,
    follow_renames: true,
    first_parent: false
  )
```

Blame returns consecutive hunks rather than one result per line. Each hunk
contains final and original ranges, commit ID, original path, boundary status,
author, committer, and summary. This is substantially more compact for agents.

### Ancestry and plumbing

The supported lower-level API is deliberately small:

```elixir
ExGitoxide.merge_base(repo_or_odb, left_oid, right_oid)
ExGitoxide.ancestor?(repo_or_odb, ancestor_oid, descendant_oid)
ExGitoxide.peel(repo_or_odb, object_oid, to: :commit)

ExGitoxide.ODB.header(odb, oid)
ExGitoxide.ODB.read(odb, oid, max_bytes: 1_000_000)
ExGitoxide.ODB.read_many(odb, oids, max_total_bytes: 8_000_000)
```

Raw object access remains bounded and verifies type, declared size, and object
hash.

### Jobs and cancellation

Every synchronous call is implemented over a job:

```elixir
{:ok, job} = ExGitoxide.async_search(snapshot, query, options)

case ExGitoxide.Job.await(job, 30_000) do
  {:ok, result} -> result
  {:error, %ExGitoxide.Error{code: :timeout}} -> :retry_or_refine
end

:ok = ExGitoxide.Job.cancel(job)
```

Jobs have `queued`, `running`, `completed`, `failed`, and `cancelled` states.
Cancellation sets an atomic interrupt checked throughout walks, scans, diffs,
blame, provider waits, and pack decoding. Caller death cancels caller-owned jobs
unless `detach: true` was explicitly requested.

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

Adapters implement `gix_object::Find` and `FindHeader` over this contract where
Gitoxide algorithms require them. `prefetch/2` is intentionally part of our
contract even though the upstream `Find` trait is single-object: tree and
revision algorithms frequently know the next group of IDs and remote ODBs need
batching.

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

### Elixir ODB backend behavior

Batch retrieval is required; single reads are implemented as a one-element
batch. This avoids defining an attractive but catastrophically chatty remote
interface.

```elixir
defmodule ExGitoxide.ODB.Backend do
  @type state :: term()

  @callback init(term()) :: {:ok, state()} | {:error, term()}

  @callback read_many([ExGitoxide.OID.t()], state()) ::
              {:ok,
               %{ExGitoxide.OID.t() => ExGitoxide.Object.t() | :not_found},
               state()}
              | {:error, term(), state()}

  @callback read_headers([ExGitoxide.OID.t()], state()) ::
              {:ok,
               %{ExGitoxide.OID.t() => ExGitoxide.ObjectHeader.t() | :not_found},
               state()}
              | {:error, term(), state()}

  @callback prefetch([ExGitoxide.OID.t()], state()) ::
              {:ok, state()} | {:error, term(), state()}

  @callback refresh(state()) :: {:ok, state()} | {:error, term(), state()}

  @callback terminate(term(), state()) :: term()

  @optional_callbacks read_headers: 2, prefetch: 2, refresh: 1, terminate: 2
end
```

`ExGitoxide.ODB.Provider` owns backend state. Native worker threads send a
request resource to that process. The provider performs the callback and calls
`ExGitoxide.Native.odb_reply(request_resource, reply)`. The request resource,
not a global integer ID, owns the waiting channel and makes late or duplicate
replies harmless.

The protocol has these invariants:

- provider work never runs in the query caller process;
- every request has a deadline and cancellation token;
- provider exit wakes all waiters;
- replies are capped before copying into Rust-owned memory;
- unexpected or duplicate object IDs are rejected;
- `:not_found` is distinct from provider failure;
- backend errors are sanitized before crossing into query results;
- negative cache entries have a short TTL because missing objects may arrive
  later in shallow or incrementally populated stores.

### Elixir reference backend behavior

References use the same provider-process pattern but never share mutable state
with an ODB backend implicitly. A caller may choose one module for both roles,
but ExGitoxide treats them as independent capabilities.

```elixir
defmodule ExGitoxide.RefDB.Backend do
  @type state :: term()

  @callback init(term()) :: {:ok, state()} | {:error, term()}

  @callback resolve(binary(), state()) ::
              {:ok, ExGitoxide.RefTarget.t() | :not_found, state()}
              | {:error, term(), state()}

  @callback list(ExGitoxide.RefQuery.t(), state()) ::
              {:ok, ExGitoxide.RefPage.t(), state()}
              | {:error, term(), state()}

  @callback refresh(state()) :: {:ok, state()} | {:error, term(), state()}

  @callback terminate(term(), state()) :: term()

  @optional_callbacks list: 2, refresh: 1, terminate: 2
end
```

Full reference names are raw binaries. Convenience branch and tag selectors
are expanded by ExGitoxide before calling the backend. Symbolic refs are
followed with a hard hop limit, and cycles return `:malformed_ref`.

### Object verification

`verify: :always` is the default and the only mode used by Gentility. For each
object, ExGitoxide recomputes the Git object ID from:

```text
<type> <byte-size>\0<payload>
```

It rejects a mismatched ID, kind, or size. Cached objects are immutable and
keyed by hash algorithm plus full object ID. SHA-1 and SHA-256 are supported
from the first public release; abbreviated IDs are resolved only by stores that
can prove uniqueness.

### Layered ODBs

ODB composition supports read-through layers:

```elixir
{:ok, odb} =
  ExGitoxide.ODB.layer([
    ExGitoxide.ODB.memory(max_bytes: 128 * 1_024 * 1_024),
    remote_odb
  ])
```

Layers are queried in order. A successful remote read populates earlier
writable cache layers when allowed. The default memory cache stores verified,
inflated object payloads; it has byte, entry, and per-object caps. Disk caching
is never implicit.

## Remote pack ODB

The callback ODB solves remote access universally, but an object-at-a-time
service is not optimal for repositories already stored as normal Git packs.
`ExGitoxide.ODB.PackRange` is the efficient remote adapter required for 1.0.

### Immutable pack inventory

A pack source publishes an atomic manifest:

```elixir
%ExGitoxide.PackManifest{
  version: 1,
  generation: "01K...",
  hash: :sha1,
  packs: [
    %ExGitoxide.PackDescriptor{
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
a grace period so in-flight jobs can finish. On a missing pack, the adapter may
refresh the manifest and retry object lookup once within the original budget.

### Range backend behavior

```elixir
defmodule ExGitoxide.ODB.RangeBackend do
  @type state :: term()

  @callback init(term()) :: {:ok, state()} | {:error, term()}

  @callback manifest(state()) ::
              {:ok, ExGitoxide.PackManifest.t(), state()}
              | {:error, term(), state()}

  @callback read_ranges([ExGitoxide.ByteRange.t()], state()) ::
              {:ok, %{ExGitoxide.ByteRange.t() => binary()}, state()}
              | {:error, term(), state()}

  @callback terminate(term(), state()) :: term()

  @optional_callbacks terminate: 2
end
```

The backend can use Req, S3, a connector agent, signed URLs, database blobs, or
another transport. Credentials remain in the provider process unless a native
transport is explicitly chosen.

Index files are fetched and verified in full because they are relatively small
and needed for OID lookup. Pack data is fetched through coalesced fixed-size
blocks with an adaptive read-ahead cache. Delta bases are resolved through the
same cache and normal ODB lookup path.

### Required Gitoxide work

As of `gix-pack 0.72`, `FileData` is only a `Deref<Target = [u8]>`; it requires
the entire pack/index byte address space to be present. It is not a remote
range-reader abstraction. ExGitoxide must not hide a whole-pack download behind
that trait.

Implement one of these, in preference order:

1. Contribute a generic random-access `ReadAt`/`ByteStore` abstraction to
   `gix-pack`, including pack and index decoding over bounded range reads.
2. Maintain a narrow temporary patch against pinned Gitoxide crates while the
   upstream design lands.
3. Implement the range-aware pack reader in `ex-gitoxide-core` using
   Gitoxide's pack parsing and delta primitives.

The contract should resemble:

```rust
pub trait ReadAt: Send + Sync + 'static {
    fn len(&self) -> Result<u64, Error>;
    fn read_exact_at(&self, offset: u64, out: &mut [u8], budget: &Budget)
        -> Result<(), Error>;
    fn prefetch(&self, ranges: &[Range<u64>], budget: &Budget)
        -> Result<(), Error>;
}
```

Do not expose this experimental trait in the Elixir API. `PackRange` remains
stable while the Rust implementation evolves.

### Remote-pack cache policy

- Entire `.idx` files: memory cached by pack checksum.
- Pack bytes: block cache, default 256 KiB blocks, coalesced up to a configured
  request maximum.
- Inflated objects: shared verified object LRU.
- Delta bases: bounded per-worker cache plus shared object cache.
- No disk cache unless a caller explicitly supplies one.
- Every cache has byte and entry ceilings and exports hit/miss/eviction stats.

## Query runtime

### Rust-owned worker pool

The NIF loads one bounded runtime resource. Defaults are conservative and can
be configured before the first job:

```elixir
config :ex_gitoxide,
  workers: max(div(System.schedulers_online(), 2), 1),
  max_queue: 1_000,
  max_jobs_per_owner: 16
```

CPU-heavy Git operations use these native workers rather than dirty CPU
schedulers. Provider callbacks are messages from native worker threads via
Rustler `OwnedEnv`; final completion is also sent as a small notification.

The completed Rust DTO remains in the job resource until a bounded dirty-CPU
`take_result/1` NIF encodes it into Elixir structs. Large blob payloads use NIF
binaries. Result encoding limits are enforced before term creation. Provider
`odb_reply/2` calls are bounded and scheduled away from normal schedulers when
they must copy object bytes into Rust-owned memory.

### Backpressure

- Queue admission can return `:busy` with `retry_after_ms`.
- Per-owner job ceilings prevent one process from monopolizing the runtime.
- Provider calls have independent concurrency and byte ceilings.
- Search/diff/blame can use internal parallelism only within the job's assigned
  permit count.
- A job's full resource budget includes cache misses and provider work.

### Cursors

Pagination cursors are opaque URL-safe binaries containing a versioned,
checksummed continuation state:

- snapshot commit ID;
- operation and normalized option fingerprint;
- last traversal position;
- storage generation where required.

Cursors are untrusted input. They are parsed with strict size limits and must
match the operation, options, and snapshot. They contain no secrets and require
no server-side session.

## Limits and safety

All operations accept `%ExGitoxide.Limits{}` and merge it with package defaults:

```elixir
%ExGitoxide.Limits{
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

Operation-specific options may lower but never raise hard runtime ceilings
without an explicitly more permissive limit profile.

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
- fuzz every parser or adapter boundary that consumes remote-controlled bytes.

## Error model

Normal failures return `{:error, %ExGitoxide.Error{}}`; the public API does not
raise for repository data, missing objects, timeouts, or backend failures.

```elixir
%ExGitoxide.Error{
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
not_a_blob                ref_not_found             ambiguous_prefix
missing_object            shallow_boundary         malformed_object
malformed_ref             hash_mismatch             pack_checksum_mismatch
index_checksum_mismatch   object_too_large          budget_exceeded
result_too_large          timeout                   cancelled
busy                      provider_down             provider_timeout
provider_protocol_error   backend_error             internal_error
```

Backend-specific reasons may appear only in a sanitized `cause`; callers branch
on `code` and `retryable`.

Truncation is a successful result with `truncated: true`, a cursor where
continuation is possible, and a warning explaining which limit was reached.

## Feature inventory

### Required for 0.1

- SHA-1 and SHA-256 object IDs.
- Local bare/normal ODB adapter, never reading worktree files.
- In-memory ODB.
- Elixir callback ODB with required batch reads.
- ODB layering and verified memory cache.
- Snapshot creation from a commit ID.
- Commit, tree, tag, and blob decoding.
- Path lookup and bounded tree traversal.
- Bounded file reads and line slicing.
- Literal and safe-regex snapshot search.
- Commit graph traversal and merge base.
- Structured tree and blob diffs.
- Arbitrary-commit blame returning hunks.
- Async jobs, cancellation, timeouts, queue bounds, limits, errors, and
  telemetry.
- Differential tests against canonical Git.

### Required for 0.2

- Elixir reference backend and repository composition.
- Local reference adapter and safe branch/tag/ref selectors.
- Path history with optional rename following.
- Rename/copy detection and richer diff stats.
- Annotated tags and signature header exposure.
- LFS pointer recognition.
- Submodule/gitlink metadata helpers.
- ODB provider conformance test kit.

### Required for 1.0

- Remote immutable pack manifest and range ODB.
- Range coalescing, read-ahead, checksum verification, and cache telemetry.
- Storage-generation-aware cursors and refresh.
- Fault-injection and soak tests for remote providers.
- Stable serialized DTO and cursor versions.
- Precompiled NIFs for supported targets.
- Complete Hex docs, examples, migration policy, and changelog.
- Gentility integration proving CodeExplorer no longer requires a checkout or
  Sprite for read-only exploration.

### Post-1.0 candidates

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

- OIDs are `%ExGitoxide.OID{algorithm: :sha1 | :sha256, bytes: binary}`.
  `to_string/1` emits lowercase hex. Public functions accept full lowercase or
  uppercase hex strings as convenience but return typed OIDs.
- Git paths and object contents are raw binaries. No UTF-8 normalization occurs.
- Commit identity preserves raw name/email bytes plus decoded display helpers.
- Times preserve seconds, offset, and sign exactly as encoded by Git.
- File modes map to typed entry kinds without discarding the original mode.
- All collections that can grow return `%ExGitoxide.Page{}` or another result
  carrying `truncated`, `stats`, and `warnings`.
- Stats include objects requested/read, cache hits/misses, provider rounds,
  provider bytes, decompressed bytes, scanned blobs, elapsed time, and the
  limit that stopped work.
- DTOs are versioned Elixir structs, not arbitrary maps or Gitoxide structs.

## Telemetry

Emit:

```text
[:ex_gitoxide, :job, :queue]
[:ex_gitoxide, :query, :start]
[:ex_gitoxide, :query, :stop]
[:ex_gitoxide, :query, :exception]
[:ex_gitoxide, :odb, :request, :start]
[:ex_gitoxide, :odb, :request, :stop]
[:ex_gitoxide, :odb, :cache]
[:ex_gitoxide, :query, :truncated]
```

Measurements include duration, queue time, bytes, counts, and cache metrics.
Metadata includes operation, backend kind, hash algorithm, result status, and
limit code. It must not include query text, paths, remote URLs, headers,
credentials, commit messages, or object content by default.

## Testing strategy

### Differential oracle

Run the same fixture queries through:

1. ExGitoxide/Gitoxide;
2. canonical `git` plumbing commands;
3. an internal `git2-rs`/libgit2 oracle during early development.

Compare normalized object IDs, tree entries, revision walks, merge bases,
diffs, rename detection, blame hunks, and path history. The libgit2 oracle is a
test dependency or separate harness, not the production engine.

### Fixture corpus

Include:

- SHA-1 and SHA-256 repositories;
- loose, packed, multi-pack-index, and alternate ODBs;
- merge-heavy and criss-cross histories;
- annotated and lightweight tags;
- shallow boundaries and intentionally missing objects;
- weird and invalid-UTF-8 paths;
- symlinks, executable files, empty blobs/trees, and submodules;
- binary files, very long lines, huge blobs, and repeated blobs;
- rename/copy cases with exact and similarity matches;
- corrupt object headers, hashes, pack entries, delta chains, and indices;
- LFS pointers;
- replace refs and graft-like edge cases where supported.

### ODB conformance kit

Ship `ExGitoxide.ODB.BackendCase`, a reusable ExUnit contract suite. Backend
authors provide a fixture loader; the suite verifies:

- found, missing, and batched objects;
- exact byte/type preservation;
- hash mismatch rejection;
- provider timeout and crash behavior;
- duplicate, omitted, and unexpected reply IDs;
- cancellation and late replies;
- negative cache expiry;
- concurrent reads and refresh;
- byte and request caps.

Provide an equivalent RangeBackend contract suite for manifests, range bounds,
short reads, ETag/generation changes, corrupt data, and vanished packs.

### Rust tests and fuzzing

- Unit and property tests for all core algorithms and limits.
- `cargo-fuzz` targets for object, commit, tree, tag, pack, index, cursor, and
  provider reply decoding.
- Fault injection for allocation failure boundaries, cancellation points, and
  range-reader short/error responses.
- Loom or targeted concurrency tests for job completion, provider replies,
  cancellation, and resource teardown where practical.
- Sustained mixed-query soak tests under BEAM process churn.

### Benchmarks

Measure local and remote modes independently:

- open/snapshot latency;
- tree entries per second;
- cold and warm file reads;
- search throughput and deduplicated-blob savings;
- diff/blame/history throughput;
- callback provider round trips and batch efficiency;
- pack-range bytes fetched versus useful bytes;
- cache hit ratios and memory ceilings;
- cancellation latency;
- BEAM scheduler responsiveness under maximum native load.

## Packaging and releases

Follow the established ExBashkit pattern:

- `rustler ~> 0.38` optional for source builds;
- `rustler_precompiled ~> 0.9` required for consumers;
- force source build with `EX_GITOXIDE_BUILD=1`;
- publish checksummed NIFs from GitHub releases;
- initial targets:
  - `aarch64-apple-darwin`
  - `x86_64-apple-darwin`
  - `aarch64-unknown-linux-gnu`
  - `x86_64-unknown-linux-gnu`
- add musl only after the TLS and Gitoxide feature set is intentionally chosen;
- build with a pinned Rust toolchain and committed `Cargo.lock`;
- generate SBOMs and provenance attestations for release artifacts;
- run the complete ODB conformance suite against precompiled artifacts before
  publishing Hex.

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
5. Build the fixture corpus and initial fuzz targets.

Exit criterion: API documentation builds, fixture/oracle harnesses run, and no
Gitoxide or Rustler type appears in the public Elixir specs or core DTO API.

### Milestone 1 — local object-native core

1. Implement OID parsing, object verification, and object decoding.
2. Implement local bare/normal ODB adapter using Gitoxide, with no worktree
   reads.
3. Implement memory ODB.
4. Implement snapshots from commit IDs, path lookup, tree pages, and file reads.
5. Add budgets, truncation, cursors, and normalized errors.

Exit criterion: tree and file queries match Git across SHA-1/SHA-256 local
fixtures, including invalid UTF-8 paths and corrupt inputs.

### Milestone 2 — job runtime and callback ODB

1. Implement the bounded Rust-owned worker pool and job resources.
2. Implement await, cancellation, caller monitoring, queue bounds, and result
   handoff.
3. Implement the provider request-resource protocol.
4. Implement `ODB.Backend`, provider process, batching, prefetch, verification,
   negative caching, and provider conformance tests.
5. Implement layered ODBs and the verified memory LRU.

Exit criterion: all Milestone 1 queries work with an ODB whose objects arrive
through an Elixir process, with no local repository files and with bounded
provider request counts.

### Milestone 3 — semantic exploration

1. Implement literal and safe-regex search.
2. Implement commit log, ancestry, and merge base.
3. Implement structured summary/stats/patch diff and rename detection.
4. Implement arbitrary-commit blame hunks.
5. Implement path history and rename following.
6. Add LFS pointer and gitlink metadata.

Exit criterion: the full semantic API matches differential oracles on the
fixture corpus and every query can be cancelled within a documented latency.

### Milestone 4 — refs and repository composition

1. Implement `RefDB.Backend` and provider process.
2. Implement local refs, safe selectors, annotated tag peeling, and ref pages.
3. Compose ODB and refs into `Repository` without weakening snapshot pinning.
4. Add atomic ref-resolution tests where refs move during queries.

Exit criterion: moving branches never change an existing snapshot and remote
refs can be resolved without a local Git directory.

### Milestone 5 — remote pack/range ODB

1. Finalize the immutable manifest and RangeBackend contracts.
2. Prototype and benchmark the Gitoxide `ReadAt` extension.
3. Upstream the abstraction or maintain a narrow pinned patch.
4. Implement full index verification, OID lookup, coalesced range reads, delta
   resolution, manifest refresh, and memory caches.
5. Run chaos tests for latency, short reads, corruption, provider restarts,
   generation changes, and removed packs.

Exit criterion: all semantic queries operate against remote immutable packs
with no checkout, repository copy, temporary directory, or implicit disk cache.

### Milestone 6 — hardening and 1.0 release

1. Complete fuzzing, soak, concurrency, and allocation-limit audits.
2. Publish telemetry and operational guidance.
3. Produce precompiled artifacts and verify them in CI.
4. Publish backend authoring guides and conformance kits.
5. Integrate Gentility CodeExplorer behind a behavior and run both backends in
   shadow comparison.
6. Remove Sprite dependence from Gentility's read-only exploration path after
   parity and operational acceptance.

Exit criterion: the 1.0 done criteria below are satisfied.

## 1.0 done criteria

- No semantic read operation requires a worktree, VFS, shell, or checked-out
  file.
- Local, memory, callback, layered, and remote pack-range ODBs pass the same
  contract suite.
- An ODB plus commit ID is sufficient for every snapshot query.
- Refs are optional and independently pluggable.
- Remote packs are range-read with bounded caches; no whole repository or pack
  is silently copied to disk or memory.
- All large collections paginate or explicitly truncate.
- All jobs are bounded, cancellable, observable, and cleaned up on caller or
  provider death.
- Remote object and pack contents are verified and corrupt data is rejected.
- Search, history, diff, blame, and tree/file reads pass differential tests.
- The BEAM remains responsive and within configured memory ceilings under the
  documented concurrency limit.
- Precompiled NIFs install without a Rust toolchain on supported targets.
- Gentility can answer its current codebase search/read/list use cases from a
  non-filesystem ODB.

## Gentility integration shape

Do not make the new library aware of organizations, GitHub integrations,
Factory Cases, Sprites, or MCP. In Gentility, add a domain behavior such as:

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

The ExGitoxide implementation resolves the existing workspace selector to an
immutable SHA and supplies organization-authorized ODB/RefDB providers. Agent
tools remain semantic and structured. `/skills` and `/case` may continue using
ExBashkit's VFS; source code no longer does.

The intended agent-tool mapping is direct:

| Agent tool | ExGitoxide operation |
|---|---|
| `code_tree` | `list_tree/3` |
| `code_read` | `read_file/3` |
| `code_search` | `search/3` |
| `code_history` | `log/2` or `history/3` |
| `code_diff` | `diff/3` |
| `code_blame` | `blame/3` |

Tool results add the organization/codebase identity around ExGitoxide's commit,
tree, and blob provenance. The library itself remains tenant-agnostic.

The transition should shadow existing Sprite-backed operations, compare
normalized outputs, record latency/provider stats, and fall back only while the
new backend is explicitly in rollout. Do not let a fallback silently change
the resolved commit.

## Recommended first implementation session

Start with Milestone 0 only. The purpose of the first session is to make the
architecture difficult to accidentally erode, not to demonstrate a local Git
query as quickly as possible.

Use this scope:

1. Create the standalone Mix/Rust workspace and source-build NIF skeleton.
2. Encode the public modules, structs, behaviors, typespecs, and normalized
   errors from this document, with documented examples and unimplemented NIF
   stubs where necessary.
3. Define the Rust core traits and DTOs without depending on Rustler.
4. Commit tiny SHA-1 and SHA-256 fixtures, including invalid UTF-8 names,
   merges, renames, binary blobs, annotated tags, and corruption cases.
5. Build a differential harness that can ask canonical Git for expected object,
   tree, log, diff, and blame results. Add libgit2 as a secondary oracle where
   useful, never as the production engine.
6. Add CI for Elixir formatting/tests, Rust formatting/clippy/tests, API docs,
   and the differential fixtures.

Stop for an API review once that passes. In particular, do not let Milestone 0
grow a path-shaped `Repository` resource or expose a Gitoxide type merely to
make the first native call convenient. Milestone 1 begins only after an
in-memory `ObjectDb` test double can drive the Rust core without Gitoxide or a
filesystem.

## Explicit decisions and deferrals

- **Start fresh, do not fork egit.** Reuse lessons and differential fixtures,
  not its API boundary.
- **Use Gitoxide, not libgit2, in production.** Keep `git2-rs` as an early
  oracle/fallback harness.
- **Use Rustler with a Rust-owned worker pool.** Dirty NIFs alone do not satisfy
  callback ODB or cancellation requirements.
- **Make object-by-OID callback ODBs the universal remote escape hatch.** They
  ship before pack-range optimization.
- **Make remote immutable pack/range access a 1.0 requirement.** Do not disguise
  full-pack downloads as range support.
- **Keep refs separate.** ODB-only snapshots are a first-class use case.
- **Verify remote objects by default.** Gentility never disables verification.
- **No implicit disk.** Optional caches are explicit adapters.
- **No transport/fetch in the first milestones.** Acquisition is separate from
  querying; it may be added after the ODB/query contract is stable.
- **No persistent search index in 1.0.** Design results around blob IDs so an
  index can be added without changing the query API.

## Primary references verified for this design

- [Gitoxide repository and project goals](https://github.com/GitoxideLabs/gitoxide)
- [`gix::Repository` object, revision, diff, and blame API](https://docs.rs/gix/latest/gix/struct.Repository.html)
- [Gitoxide crate implementation status](https://github.com/GitoxideLabs/gitoxide/blob/main/crate-status.md)
- [`gix_object::Find`](https://docs.rs/gix-object/latest/gix_object/trait.Find.html)
- [`gix_object::FindHeader`](https://docs.rs/gix-object/latest/gix_object/trait.FindHeader.html)
- [`gix-pack` pack access and allocation limits](https://docs.rs/gix-pack/latest/gix_pack/)
- [Gitoxide documented shortcomings](https://github.com/GitoxideLabs/gitoxide/blob/main/SHORTCOMINGS.md)
- [Rustler project and resource model](https://github.com/rusterlium/rustler)
- [Rustler `OwnedEnv` messaging constraints](https://docs.rs/rustler/latest/rustler/env/struct.OwnedEnv.html)
- [RustlerPrecompiled](https://hexdocs.pm/rustler_precompiled/RustlerPrecompiled.html)
- [`git2-rs` credential callbacks used by the differential/fallback harness](https://docs.rs/git2/latest/git2/struct.RemoteCallbacks.html)
- [libgit2 custom ODB backend reference](https://libgit2.org/docs/reference/main/sys/odb_backend/git_odb_backend.html)
