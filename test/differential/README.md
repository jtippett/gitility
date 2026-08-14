# Differential oracle tests

Canonical Git is the primary behavioral oracle. `GIT_VERSION` pins the version
used to develop and triage this harness; CI should install that version. The
runtime test compares major/minor versions so patch-level security upgrades do
not create noise.

An intentional Git upgrade is a review event: run the full differential suite,
triage changed results, update every affected allowlist entry, and then update
`GIT_VERSION`. For a one-off local probe with another Git, set
`GITILITY_ORACLE_ALLOW_VERSION_MISMATCH=1`; the version test emits a warning
instead of failing. That escape hatch must not be set in CI.

Engine-backed comparisons carry `@tag :gitility_engine` and are excluded in
`test_helper.exs` during the pre-engine scaffold. Remove that exclusion only
when those comparisons have real Gitility implementations. Unknown mismatches
then fail; only cases whose id, operation, fixture repository, and query all
exactly match a record in `allowlist.exs` pass with a visible allowlist record.
