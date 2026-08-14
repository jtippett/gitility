# Update procedure

Two maintenance contracts: **Part A** — bumping the pinned Gitoxide (`gix`)
crate family; **Part B** — cutting a release. Keep the ordering exact.

## Part A — bumping the pinned `gix` family

Gitoxide is pre-1.0 and pinned exactly in `crates/gitility-core/Cargo.toml`
(design doc, R5). An upgrade is a deliberate event, never a drive-by
`cargo update`:

1. Read the upstream changelogs for every `gix-*` crate crossing versions.
   Pay special attention to `gix-blame`, `gix-diff` (rename tracking), and
   any movement on SHA-256 (`etc/plan/sha256-support.md` upstream — an
   engine-support flip is the highest-value upgrade available; design doc R1).
2. Bump the pins in `crates/gitility-core/Cargo.toml`, run `cargo update`
   inside `native/gitility` to refresh the committed `Cargo.lock`.
3. `just test` and the Rust suites must pass, **including the differential
   suite** — it is the gate for engine upgrades. Any new divergence from
   canonical git must be triaged into the known-divergence allowlist or fixed
   before the bump merges (design doc, testing strategy).
4. Record behavior-visible changes in `CHANGELOG.md` under `[Unreleased]`.
   Engine bumps with no documented behavior change are internal (semver
   patch/minor at most).

## Part B — cutting a release

The flow, end to end:

```
bump version + CHANGELOG  →  tag vX.Y.Z  →  release.yml builds 4 NIF artifacts
   →  GitHub release created  →  checksum file regenerated from those artifacts
   →  hex.publish (gated by `hex` environment approval)  →  verify clean install
```

1. `just release` (runs `scripts/release.exs`): refuses a dirty tree, prompts
   patch/minor/major, rewrites `@version` in `mix.exs`, rolls the
   `## [Unreleased]` CHANGELOG section into a dated release heading, commits,
   tags `vX.Y.Z`, and pushes branch + tag. The tag push triggers
   `.github/workflows/release.yml`.
2. The workflow builds the NIF for all four targets
   (`aarch64-apple-darwin`, `x86_64-apple-darwin`,
   `x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu`), attaches the
   tarballs to a GitHub release, then pauses at the `publish` job for
   approval on the **`hex` environment**.
3. Before approving, eyeball the release artifacts. On approval the job
   regenerates `checksum-Elixir.Gitility.Native.exs` **from the published
   release artifacts** via
   `mix rustler_precompiled.download Gitility.Native --all --print`, commits
   it back to `master`, and runs `mix hex.publish`.
4. Verify: on a machine (or clean `_build`) **with no Rust toolchain**, add
   `{:gitility, "~> X.Y"}`, run `mix deps.get && mix compile`, and confirm
   the precompiled NIF downloads (no build) and `Gitility` functions work.

Hard rules:

- **The checksum file is always generated after the release artifacts exist —
  never hand-edited, never generated from a local build before publish.**
- The `hex` environment (repo Settings → Environments) must have a required
  reviewer and hold the `HEX_API_KEY` secret. That gate is the only thing
  between a tag push and a published package.
- Cursor and callback protocol versions (design doc) are independent of the
  package version and explicitly encoded; bumping them is an API change and
  must appear in the CHANGELOG.

## One-time repo setup (first release prerequisites)

- Create the GitHub repo (`jtippett/gitility`), push `master`.
- Settings → Environments → new environment `hex`: add yourself as required
  reviewer; add `HEX_API_KEY` (a Hex API key with publish rights) as an
  environment secret.
- First tag push exercises the whole pipeline; the checksum file does not
  exist until that first release completes (it is deliberately absent from
  the scaffold).

## TODO (aspirational hardening, per ex_pdfium)

- Pin GitHub Actions `uses:` refs to full commit SHAs and add a
  release-invariants test asserting checksum-file shape, SHA-pinned actions,
  and Rust-NIF-export ↔ `Gitility.Native` stub parity.
