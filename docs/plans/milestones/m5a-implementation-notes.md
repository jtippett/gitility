# M5a native fetch implementation notes

Implementation date: 2026-08-20  
Frozen specification: `m5a-native-fetch.md`, SPEC v8

## Fix round 1

- Error classification now unwraps `prepare::Error::RefMap` and the nested
  `ref_map::Error` variants structurally. This makes real HTTP 401 responses
  reach the handshake credential variants and maps them to
  `AuthenticationFailed`; source-chain inspection remains only a fallback for
  boxed IO/backend errors. Redirect classification follows the same rule and
  structurally reaches transport errors before checking the boxed reqwest
  cause through `std::io::Error::get_ref()` (whose `source()` skips that
  directly wrapped error). A direct, featureless `reqwest 0.13.4` edge names
  that typed cause without enabling anything beyond gix's resolved backend.
  Real loopback 401, 301, and 403 responders cover the three status
  classifications in Cargo integration tests.
- Remotes use `Tags::None`, so only explicit tag refspecs fetch tags. The
  `Gitility.Fetch` moduledoc now states that policy.
- Opening an existing destination now recognizes the typed
  `open::Error::Config(ConfigTypedString(...))` error whose public key is
  `extensions.objectFormat` and returns `UnsupportedHash` with a destination
  object-format message. A real `git init --bare --object-format=sha256` unit
  fixture covers it and skips only when the installed Git lacks SHA-256.
- Ref-map `MappingValidation` conflicts now return `InvalidArgument` and name
  the conflicting destination. The prune parity row uses disjoint wildcard
  destination namespaces plus an exact destination nested under a wildcard;
  a separate no-oracle row retains the genuinely conflicting pair.
- The lease-held retry and attempt-two death-window assertions were reread and
  left unchanged: both were downstream of the incorrect 401 classification.

## Implementer choices

- The smart-HTTP fixture delivers CGI stdin EOF with a fixed `/bin/sh`
  wrapper: `dd bs=1 count="$CONTENT_LENGTH"` consumes exactly the request
  body and pipes it to the pinned `git http-backend`. The Erlang port retains
  stdout and exit-status ownership, so no temporary request file is needed.
- Fixture-mode precedence is fixed status, redirect, authorization, then
  plain CGI. Pack truncation and delayed-body behavior apply only to the
  upload-pack POST response.
- Every gix rejected update mode has a stable result atom:
  `:source_object_not_found`, `:tag_update`, `:non_fast_forward`,
  `:replace_with_unborn`, or `:currently_checked_out`.
- Network errors use phase-specific static messages. Redirects are detected
  by structurally unwrapping public gix error variants, then inspecting only
  boxed backend/IO causes for reqwest's typed redirect error; upstream errors
  are never formatted. This keeps the authorization value outside all
  formatting paths.
- Locks disambiguates equal numeric job IDs from different runtime instances
  by checking each matching job resource's terminal state when a notification
  arrives. Late transitions from holders whose lease was lost in a documented
  Locks restart are ignored, so they cannot mutate or crash a newly admitted
  lease for the same destination.
- Provider waits, job awaits, and the pending-submission grace timer are
  chained in chunks no larger than OTP's maximum timer interval. This keeps
  the allowed `2^32` millisecond boundary raise-free while preserving the
  original absolute provider/job deadline and the grace deadline of exactly
  twice the declared fetch timeout.
- The Linux thread assertion reads the BEAM process's `nlwp` value from `ps`,
  waits for a stable no-fetch baseline, checks the fetch runtime's three
  resident threads, samples two in-flight fetches against the nine-thread
  ceiling, and condition-polls until the count drains back to three.
- Caller validation treats duplicate keyword options with normal Elixir
  last-value-wins semantics. Improper lists are rejected as invalid arguments
  instead of reaching `Enum` and raising.

## Cargo and feature choices

The top-level `gix` dependency enables exactly the three features prescribed
by SPEC v8:

- `blocking-network-client`
- `blocking-http-transport-reqwest-rust-tls`
- `sha1`

No additional top-level gix feature was required. Exact direct dependencies
on `gix-refspec 0.44.0`, `gix-transport 0.58.1`, `gix-protocol 0.64.0`,
`gix-pack 0.73.0`, and `reqwest 0.13.4` were added because the implementation
must name their public ref-map, transport-option, refspec-matching, pack-error,
and redirect-error types. These direct edges use `default-features = false`;
they do not enable parallel indexing. `Cargo.lock` contains exactly one
`gix-diff` package, and it resolves through the existing vendored patch.

The workspace Rust version is 1.85. No release-workflow change was needed for
the expected rustls/reqwest artifact-size increase.

## Deviations

None. All prescriptive SPEC v8 API calls, lease transitions, stable error
registry changes, feature exclusions, thread-budget reservations, and test
matrix rows were implemented literally. The Elixir suite, twelve-run M5a
loop, docs warning check, Linux thread assertions, network smoke, and dress
rehearsal were intentionally not executed on this Mac; the frozen spec and
dispatch prohibit loading the project NIF into a local BEAM. They are wired
for the remote Linux sprite.

## Local verification evidence

Only the permitted plain `mix format` command was run on the Elixir side.
No Elixir tests, compilation, docs, or rehearsal command was run locally.

```text
$ cargo build
Finished `dev` profile [unoptimized + debuginfo] target(s) in 7.99s

$ cargo test --workspace --lib --bins --tests
gitility:                         1 passed; 0 failed
gitility-core unit tests:       256 passed; 0 failed
gitility-core integration tests: 3 passed; 0 failed
gix-diff:                         4 passed; 0 failed

$ ./scripts/check-thread-spawns.sh
Verified exactly two allowlisted, budgeted native thread spawn sites.

$ ./scripts/check-gix-features.sh
check-gix-features: gix-pack is single-threaded on normal/build edges

$ rg -c '^name = "gix-diff"$' Cargo.lock
1

$ cargo fmt --all -- --check
(success; no output)

$ mix format
(success; no output)

$ git diff --check
(success; no output)
```
