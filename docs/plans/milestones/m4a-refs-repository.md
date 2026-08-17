# M4a — refs: RefDB.Backend, local refs, selectors, Repository composition

You are implementing Milestone 4a of Gitility. READ FIRST:
1. docs/plans/2026-08-14-gitility-design.md — "Composing refs with an
   ODB" (safe selectors), the RefDB.Backend behaviour section (the
   callback contract is PRE-DESIGNED — implement it exactly), "Refs
   are optional and independently pluggable", "Cursors" (tag 0x05 refs
   — reserved; position payload not yet specified: define it as the
   raw full ref name of the last emitted ref, resumed strictly-greater
   in byte order, and AMEND the design doc's wire-format table the way
   the search amendment was recorded), "Limits and safety", "Error
   model", Milestone 4 items 1–4.
2. lib/gitility/{ref_db.ex,types/ref.ex,types/ref_target.ex,
   types/ref_query.ex,repository.ex,snapshot.ex} — stubs and DTOs
   exist from M0; honor their shapes (one Gitility.Page everywhere —
   there is NO separate RefPage type in Elixir, per the recorded API
   deviation).
3. crates/gitility-core/src/refs.rs (existing skeleton), snapshot.rs,
   local_odb.rs; sources/gitoxide/gix-ref for the local ref store
   machinery (vendored evidence convention — pin what you need,
   default-features = false, NO thread/rayon/crossbeam paths, spawn
   guard green; any tempfile-class default gets the vendored-gix-diff
   treatment ONLY if truly needed — prefer read-only paths that never
   need it; record evidence file:line).
4. M2c provider ODB (provider_odb.rs + lib/gitility/odb.ex) — the
   RefDB provider mirrors its supervision/watchdog/conformance
   patterns; M3 milestone tests for job idioms.

ABSOLUTE CONSTRAINT — NO BEAM (docs/reports/2026-08-14-kernel-panic-
thread-leak.md): cargo/loom (existing models stay green — runtime
internals untouched)/clippy both cfgs/fmt/spawn-guard only; Elixir
edited, never executed; list unverified edits. Write surface:
crates/gitility-core/, native/gitility/, lib/, test/, fixtures/
(generation scripts only), root Cargo.toml/Cargo.lock. Do not commit.

R1 [local ref store — read-only]. Core reads a local repository's
refs: loose refs, packed-refs, and reftable if gix-ref supports it at
our pins (record which formats are covered; if reftable is not
covered, :unsupported_operation naming the format — never silent).
- resolve(name): full ref names only at core level; symbolic refs
  followed with a hard hop limit (reuse the design's :malformed_ref
  on cycles; name the cycle in details); missing → :not_found shape
  per the behaviour contract (not an Error).
- HEAD resolution (symbolic or detached).
- Annotated tag peeling: {:tag, name} resolves to the tag ref then
  peels to the commit (bounded hops, reuse the M1c peel machinery);
  {:ref,...}/{:branch,...} never peel implicitly; RefTarget carries
  both the ref's direct target and the peeled commit where applicable
  (honor the existing RefTarget DTO shape).
- list(query): deterministic byte-order by full ref name, prefix
  filtering per RefQuery's existing shape, paged via cursor tag 0x05
  (fingerprint covers the normalized query), Budget::check per ref
  visited, max_results bounds the page.
- ALL reads snapshot-consistent per CALL (a call sees one coherent
  packed-refs read; concurrent repository mutation between calls is
  fine — document; but one list call must never interleave two
  packed-refs generations).

R2 [RefDB provider — Elixir-backed refs]. Mirror the M2c ODB provider
architecture exactly (caller-runs-init, supervision tree, watchdog,
sanitized errors, :provider_down on exit, request timeout,
concurrency): Gitility.RefDB.start_link(backend: {module, opts}, ...)
+ RefDB.handle/1 two-shape pattern. The behaviour callbacks are the
design doc's (init/resolve/list/refresh/terminate; list+refresh+
terminate optional — absent list → :unsupported_operation for ref
pages; absent refresh → no-op :ok). Replies validated in core:
RefTarget shapes, full-ref-name byte rules (no NUL, no "..", no
leading/trailing "/", no "@{"; follow git check-ref-format's
component rules — probe git 2.55.0 and encode its acceptance set;
malformed provider reply → :provider_protocol_error naming the
provider, M2c convention). A public conformance kit
Gitility.RefDB.Backend.Conformance mirroring the ODB one.

R3 [Repository composition]. Gitility.Repository.from_stores(odb:,
refs: nil) — refs optional; Repository.open/2 gains its local RefDB
automatically (same dir). Snapshot resolution through selectors:
{:oid,...} (works with or without refs), {:ref,...}, {:tag,...},
{:branch,...}, :head — the four ref-based selectors require refs
(:unsupported_operation naming the missing capability otherwise).
{:revspec,...} stays REJECTED as :unsupported_operation in 0.x
(advanced selector; document). SNAPSHOT PINNING IS THE INVARIANT:
resolution happens exactly once at snapshot/2; the returned Snapshot
carries the resolved commit OID and never re-reads refs. Hash
compatibility: a ref resolving to an OID whose algorithm differs from
the ODB's → :hash_mismatch. Runtime rules follow the ODB's
(:runtime_mismatch conventions).

R4 [atomicity under moving refs — M4 item 4]. Tests proving: a
snapshot taken while refs move never changes (pin, then move the ref
via the backend/fixture, re-query — identical results); a provider
that returns DIFFERENT targets across two resolve calls for one
snapshot/2 invocation cannot produce a torn snapshot (resolution is
single-shot); ref listing pages under mutation either resume cleanly
or return :invalid_cursor — never a torn page (decide by mechanism:
the cursor's strictly-greater rule makes resumed pages coherent even
if refs moved; state this in @doc).

R5 [fixtures + differential]. Extend fixtures/generate.sh: a repo
with loose refs, packed-refs (some refs ONLY packed, some only loose,
one BOTH with loose winning), annotated tag chains (tag→tag→commit),
a symbolic ref beyond HEAD, deeply nested ref names (refs/heads/a/b/c),
a ref name at git's component-rule edges, detached HEAD variant,
plus ≥60 refs for pagination. Differential vs pinned git 2.55.0:
resolve parity (`git rev-parse` / `git symbolic-ref`), peel parity
(`git rev-parse tag^{commit}`), list parity (`git for-each-ref
--format='%(refname)%00%(objectname)%00%(objecttype)' [prefix]` —
NUL-safe), HEAD parity, cursor reconstruction across ≥3 pages.
check-ref-format acceptance probes (`git check-ref-format --normalize`)
for the R2 validation set. Empty allowlist discipline; report
divergences for triage.

R6 [Elixir tests — written, not run]. test/milestone_4a_refs_test.exs:
every selector happy path; selectors without refs →
:unsupported_operation; peeling incl. tag→tag chains; :malformed_ref
on symbolic cycles; provider conformance via the kit; provider crash
→ :provider_down; moving-refs atomicity (R4); pagination round-trip +
fingerprint invalidation; non-UTF-8 ref names round-trip (git allows
non-UTF-8 bytes in ref names — verify and cover); async where the
established API surface has async variants. ALL M3-series authoring
lessons apply (OIDS+{:oid,...} for non-ref setup, conversion-site
end-to-end assertions for every new DTO field — list them in the
report, guard-safe helpers, no struct literals in quoted generators).

Report: per-requirement summary; Rust test counts (plain + loom); pin
evidence (gix-ref version, features, no-thread proof); the ref-name
acceptance set vs git probes; every divergence with its exact case;
conversion-site field list; unverified Elixir edits; deviations.
