# Gitility

Snapshot-first Git object queries for Elixir, built on
[Gitoxide](https://github.com/GitoxideLabs/gitoxide)'s plumbing crates and
shipped as a **precompiled NIF** with
[`rustler_precompiled`](https://hexdocs.pm/rustler_precompiled) — no Rust
toolchain needed to install, add the dep and go.

> Read commits, trees, and blobs from local bare repositories, memory,
> Elixir-backed providers, or remote immutable pack stores — tree listing,
> file reads, content search, log, path history, diff, and blame — with no
> worktree, checkout, or shell, and every operation bounded, cancellable,
> and paginated.

**Status: pre-implementation.** This repository is a scaffold carrying the
complete design; the public API described below does not exist yet.
Implementation follows
[`docs/plans/2026-08-14-gitility-design.md`](https://github.com/jtippett/gitility/blob/master/docs/plans/2026-08-14-gitility-design.md),
starting at Milestone 0.

## Why

Existing Elixir options wrap the git CLI, bind libgit2 command-by-command, or
assume a repository directory on local disk. None offers what agentic and
server-side code exploration actually needs: queries pinned to an immutable
commit, over pluggable object storage (including object stores with no
filesystem at all), returning structured, budgeted, citable results. Gitility
is that layer — the engine supplies the algorithms; you supply the storage
through small behaviours.

## Installation

Once published:

```elixir
def deps do
  [
    {:gitility, "~> 0.1"}
  ]
end
```

## Usage

See the design document for the full intended API. The flavor:

```elixir
{:ok, repo} = Gitility.Repository.open("/srv/git/acme/widgets.git", require_bare: true)
{:ok, snapshot} = Gitility.Repository.snapshot(repo, {:branch, "main"})

{:ok, page} = Gitility.list_tree(snapshot, "lib", recursive: true, limit: 500)
{:ok, file} = Gitility.read_file(snapshot, "lib/acme/widget.ex", lines: 120..220)
{:ok, hits} = Gitility.search(snapshot, "def handle_call", pathspecs: ["**/*.ex"])
{:ok, blame} = Gitility.blame(snapshot, "lib/acme/widget.ex", lines: 120..220)
```

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
