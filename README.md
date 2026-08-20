# Gitility

Snapshot-first Git object queries for Elixir, built on
[Gitoxide](https://github.com/GitoxideLabs/gitoxide)'s plumbing crates and
shipped as a **precompiled NIF** with
[`rustler_precompiled`](https://hexdocs.pm/rustler_precompiled) — no Rust
toolchain needed to install, add the dep and go.

> Read commits, trees, and blobs from local bare repositories, memory,
> Elixir-backed providers, remote immutable pack stores, or single-file
> bundles — tree listing, file reads, content search, log, path history,
> diff, and blame — with no worktree, checkout, or shell, and every
> operation bounded, cancellable, and paginated.

## Why

Existing Elixir options wrap the git CLI, bind libgit2 command-by-command, or
assume a repository directory on local disk. None offers what agentic and
server-side code exploration actually needs: queries pinned to an immutable
commit, over pluggable object storage (including object stores with no
filesystem at all), returning structured, budgeted, citable results. Gitility
is that layer — the engine supplies the algorithms; you supply the storage
through small behaviours.

## Installation

```elixir
def deps do
  [
    {:gitility, "~> 0.2"}
  ]
end
```

Precompiled NIFs cover macOS (Apple Silicon and Intel) and Linux glibc
(x86_64 and arm64). On any other target set `GITILITY_BUILD=1` to compile
from source with a stable Rust toolchain. Windows is not supported.

## Usage

Open a repository, pin a snapshot, query it. Every query takes a snapshot —
an immutable commit — so results are stable and citable no matter what the
underlying storage does afterwards.

```elixir
{:ok, repo} = Gitility.Repository.open("/srv/git/acme/widgets.git", require_bare: true)
{:ok, snapshot} = Gitility.Repository.snapshot(repo, {:branch, "main"})

{:ok, page}  = Gitility.list_tree(snapshot, "lib", recursive: true, limit: 500)
{:ok, file}  = Gitility.read_file(snapshot, "lib/acme/widget.ex", lines: 120..220)
{:ok, hits}  = Gitility.search(snapshot, "def handle_call", pathspecs: ["**/*.ex"])
{:ok, blame} = Gitility.blame(snapshot, "lib/acme/widget.ex", lines: 120..220)
{:ok, log}   = Gitility.log(snapshot, limit: 30)
{:ok, edits} = Gitility.history(snapshot, "lib/acme/widget.ex", limit: 10)
{:ok, diff}  = Gitility.diff(base_snapshot, snapshot, format: :summary)
```

Results are structured pages with cursors; byte, entry, and time budgets are
explicit options with conservative defaults. SHA-1 and SHA-256 repositories
are both supported.

## Fetching

`Gitility.Fetch` performs client-side smart-HTTP fetches into local bare
repositories without invoking Git or a credential helper. Production callers
should use HTTPS; authorization headers go directly to the in-process
rustls client and are never stored or logged. Redirects are refused, and one
absolute timeout covers credential-provider work, queue residence, HTTP, and
the optional single 401 retry.

```elixir
{:ok, result} =
  Gitility.Fetch.fetch(
    "/srv/git/widgets.git",
    "https://github.com/acme/widgets.git",
    ["+refs/heads/*:refs/remotes/origin/*"],
    prune: true,
    credentials: fn %{attempt: attempt} ->
      {:ok, %{authorization: MyApp.GitToken.header(attempt)}}
    end,
    retry_unauthorized: true
  )
```

Fetches are single-flight per expanded destination path and use a dedicated
two-worker runtime by default. Query APIs remain snapshot-pinned and read-only;
fetch is the sole path that writes refs and objects in a real Git directory.

## Bundles: a repository in one file

`Gitility.Bundle` clones a repository into **one flat file** — packs,
indexes, a refs snapshot, and metadata — that opens as a complete read-only
repository with no other infrastructure. Put it on S3, download it, query it:

```elixir
# Publish: byte-deterministic, complete-or-absent (atomic rename)
{:ok, receipt} =
  Gitility.Bundle.write("widgets.bundle",
    source: {:repository, "/srv/git/acme/widgets.git"},
    source_identity: "git@github.com:acme/widgets.git"
  )

# ...ship the file anywhere; later, open it as a repository
{:ok, repo} = Gitility.Bundle.open("widgets.bundle", into: :memory)
{:ok, snapshot} = Gitility.Repository.snapshot(repo, :head)
{:ok, file} = Gitility.read_file(snapshot, "README.md")
```

`Bundle.verify/1` streams the whole file and checks every recorded checksum;
`Bundle.info/1` reads its metadata without opening it. Identical input
produces an identical file, byte for byte. Bundles are only ever opened
read-only — an immutable, mode-0444 file on a read-only mount works.

Bundles are also a hydration destination: `Gitility.ODB.PackFetch` can fetch
from a remote immutable pack store straight into a bundle file
(`into: {:bundle, path}`), so a warm restart serves everything locally
without touching the network.

The container format is specified and **frozen** as
[bundle format v1](https://github.com/jtippett/gitility/blob/master/docs/format/bundle-v1.md):
any Gitility 0.2+ reader opens any v1 bundle, and future format changes bump
the version rather than reinterpret v1 fields.

## Pluggable storage

The engine is storage-agnostic. Implement small behaviours to serve objects
from wherever they live:

- **Local** — bare or normal repository directories (queries never read the
  worktree).
- **Memory** — static in-memory object sets built from Elixir terms.
- **Provider** — objects served object-by-object by your Elixir callbacks.
- **Range backends** — immutable pack stores addressed by byte range (a
  directory published by `LocalDirectory.publish/2`, or your own S3/HTTP
  backend), hydrated on demand by PackFetch under explicit byte and request
  budgets.
- **Bundle** — the single-file container above.

## Guarantees

- **Snapshot-pinned**: a snapshot is an immutable commit; queries against it
  never see concurrent updates.
- **Bounded**: every operation carries explicit limits (bytes, entries,
  time) and returns structured errors when exceeded — no unbounded scans.
- **Cancellable**: long operations run as jobs that can be cancelled from
  Elixir.
- **Read-only queries**: snapshot and object queries never mutate a repository
  or shell out. `Gitility.Fetch` is the explicit, isolated write path into a
  local bare repository.

## Development

Requires Elixir ≥ 1.17 and a Rust toolchain (from-source builds only; consumers
of the published package need neither Rust nor a C compiler).

```bash
just test        # run the suite with a locally built NIF
just build       # force a from-source NIF build
just fmt         # format Elixir + both Rust crates
just release     # interactive release: bump, tag, push (see UPDATE_PROCEDURE.md)
```

Releases are cut by pushing a `v*` tag; `.github/workflows/release.yml` builds
NIFs for all supported targets, attaches them to a GitHub release, regenerates
the checksum file from those artifacts, and publishes to Hex behind a
required-reviewer approval gate. The full contract is in
[`UPDATE_PROCEDURE.md`](https://github.com/jtippett/gitility/blob/master/UPDATE_PROCEDURE.md).

## License

MIT — see [LICENSE](https://github.com/jtippett/gitility/blob/master/LICENSE).
