# Milestone 2d — layered ODBs and the verified cache layer

Implementation spec, dispatched verbatim. Same standing rules as
`m2c-provider-odb.md` (no BEAM on the Mac — remote sprite only; no new
native threads; orchestrator commits).

## The task

Implement `Gitility.ODB.layer/1` and `Gitility.ODB.cache/1` per
`docs/plans/2026-08-14-gitility-design.md` "Layered ODBs" and the
`lib/gitility/odb.ex` docs (the option names/semantics there are the
contract). Read the committed M2c provider ODB first
(`crates/gitility-core/src/provider_odb.rs`'s bounded LRU + verify path)
— the cache layer reuses that machinery, it does not duplicate it.

Write surface: `crates/gitility-core/`, `native/gitility/`, `lib/`,
`test/`, root `Cargo.lock`.

### Architecture (final)

**Core: `LayeredOdb`** — an `ObjectDb` over `Vec<Arc<dyn ObjectDb>>`
plus zero or one `CacheLayer`. Read-through: `try_find`/`try_header`
query layers in order, first hit wins; on a hit from layer *i*, populate
every writable cache layer *before* *i* (in 0.x that means the single
`CacheLayer` if it precedes the hit). `prefetch` fans out to all layers;
`refresh` fans out too. Hash algorithm agreement is checked at
construction (`:hash_mismatch`), and the runtime affiliation check
happens Elixir-side at composition (`:runtime_mismatch`) — this is the
milestone where that error finally goes live: `layer/1` compares every
handle's `runtime` field; mismatch → `{:error, %Error{code:
:runtime_mismatch}}` and NO native construction.

**`CacheLayer`** — a writable, in-memory, verified-payload cache: stores
inflated payloads keyed by `(hash_kind, oid)`, under `max_bytes`
(required), `max_entries`, `max_object_bytes` (larger objects bypass:
never cached, still served through). Only *verified* payloads are ever
inserted (they arrive from lower layers which already verify:always —
document that the cache stores post-verification bytes and re-serves
them WITHOUT re-hashing; the trust argument: bytes entered under
verify:always and memory is not a trust boundary — but keep a
`debug_assert` verify behind cfg(debug_assertions) as a tripwire).
Eviction: LRU. Stats: hits/misses/bytes/entries/evictions, surfaced
through the existing stats path (`Gitility.Stats` has `cache_hits`/
`cache_misses` fields that M1c hardcoded to 0 — wire them for layered
handles; document the semantics: counts for THIS job's reads).

**NIF/Elixir.** `StoreImpl::Layered(LayeredOdb)`; `ODB.layer/1` accepts a
list of `t()` handles and `cache_spec`s (`{:cache, opts}` from
`cache/1`), validates (≥1 non-cache layer; at most one cache in 0.x —
more than one → `:invalid_argument` "one cache layer per composition in
0.x"; cache must precede at least one store; all stores same hash + same
runtime), builds native `Arc`s from each handle's resource, returns a
`kind: :layered` handle carrying the shared runtime. Queries need no
changes (ObjectDb seam). Layered handles' `refresh/1` fans out.

### Tests (BEAM tests remote)

- Composition validation: hash mismatch (sha1 static + sha256 static) →
  `:hash_mismatch`; runtime mismatch (two stores on two named runtimes)
  → `:runtime_mismatch`; two cache specs → `:invalid_argument`; empty
  list / cache-only → `:invalid_argument`.
- Read-through semantics: `[cache, static_A(objects X), provider_B(objects
  Y)]` — X objects served from A without touching B (backend call count
  0); Y objects reach B once, then are cache hits (backend call count
  stays 1 across repeated reads; stats.cache_hits increments).
- Cache bounds: `max_object_bytes` bypass (large blob served but backend
  call count grows on repeat); `max_bytes` eviction (fill past the cap,
  earliest evicted, evictions stat > 0, everything still readable).
- Parity: full recursive `list_tree` + `read_file` on ≥5 paths (0xFF
  included) over `[cache, provider(sha1-basic)]` equal the local store.
- Layer order matters: `[static_A_stale, static_A_fresh]` where the same
  oid... NO — content-addressed objects can't differ; instead assert
  first-hit-wins via backend call counts with two providers holding the
  same objects.
- `refresh/1` on a layered handle reaches every provider backend's
  refresh (call counts) and clears the negative caches.
- Existing suites unchanged and green; soak green.

### Hygiene
Same as M2c: cargo fmt/clippy (both cfgs)/test; loom; spawn guard;
remote sync/mix/soak; remote `mix docs --warnings-as-errors`; `mix
format`. No commit. Print change summary, counts, remote summary lines,
ambiguities resolved.
