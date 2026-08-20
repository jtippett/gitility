# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `Gitility.Fetch.fetch/4`: bounded, cancellable smart-HTTP fetch into local
  bare repositories using gix, reqwest, and statically linked rustls, with
  credential providers, optional prune, destination single-flight leases, and
  a dedicated two-worker runtime.

### Changed

- The Rust MSRV for from-source consumers is now 1.85, required by gix 0.86.

### Fixed

- Compile warning on Elixir 1.20: bound variables in binary-size matches
  are now pinned (`binary-size(^length)`).

## 0.3.0 - 2026-08-20

### Changed

- **Breaking**: `Gitility.Commit` fields renamed for consistency with every
  sibling type — `id` → `oid`, `tree_id` → `tree_oid` (matching `blob_oid`,
  `commit_oid`, `old_oid`/`new_oid` elsewhere).

### Fixed

- `Bundle.open/2`/`start_link/1` with an unsupported or invalid `:into`
  destination (e.g. `into: :memory` on macOS) now returns the documented
  error tuple instead of exiting the linked caller from inside the
  supervisor's child start.
- Consumers without the optional `postgrex` dependency no longer see
  `Postgrex.* is undefined` warnings on every compile.
- `Gitility.read_file/3` docs now name the result's `data` field.

## 0.2.0 - 2026-08-20

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
