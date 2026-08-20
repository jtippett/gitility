# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

First functional release — the complete snapshot-first query library.

- **Query API** over immutable commit snapshots: `Gitility.list_tree/3`,
  `read_file/3`, `search/3`, `log/2`, `history/3`, `diff/3`, `blame/3`, and
  `ancestor?/4` — structured, paginated results with explicit byte/entry/time
  budgets (`Gitility.Limits`), cancellable jobs, SHA-1 and SHA-256
  repositories.
- **Repositories and snapshots**: `Gitility.Repository.open/2` for local
  bare/normal directories (worktree never read), selector resolution
  (`:head`, `{:branch, _}`, `{:tag, _}`, `{:ref, _}`, `{:oid, _}`) into
  pinned `Gitility.Snapshot`s.
- **Pluggable storage behaviours**: static in-memory object sets, Elixir
  provider callbacks (`Gitility.ODB.Backend`), immutable range-addressed
  pack stores (`Gitility.ODB.RangeBackend` with a `LocalDirectory`
  reference backend and `publish/2`), and pluggable ref stores
  (`Gitility.RefDB.Backend`).
- **PackFetch hydration** (`Gitility.ODB.PackFetch`): fetch from a remote
  immutable pack store under explicit request/byte budgets into a local
  scratch directory or straight into a bundle file
  (`into: {:bundle, path}`), with warm restarts served locally.
- **Bundles** (`Gitility.Bundle`): a complete read-only repository in one
  flat file — `write/2` (byte-deterministic, atomic-rename publication),
  `open/2` (`into: :memory` or `{:dir, path}`), `verify/1`, and `info/1`.
  Container format **frozen as bundle format v1**
  (`docs/format/bundle-v1.md`): 0.2+ readers open any v1 bundle; future
  changes bump the format version rather than reinterpret v1 fields.
- Precompiled NIF targets: macOS arm64/x86_64, Linux glibc x86_64/arm64
  (`GITILITY_BUILD=1` builds from source elsewhere; Windows unsupported).
