# M4a review fixes — decisions and dispatch

Adversarial review of the M4a checkpoint (356f790) mechanically proved
local snapshot pinning (one packed-refs generation held across resolve
chains and full listings, mutation probes included) and found the
findings below. Decisions FINAL. Same constraints: NO BEAM; Rust-side
verification only; Elixir edited, never executed; do not commit.

H2 FIRST [likely CompileError]. RefDB.resolve/3 declares a default in a
multi-clause def (lib/gitility/ref_db.ex:113) — Elixir requires a
bodiless head (RefDB.list/3 right below does it correctly). FIX with a
bodiless head. Sweep the M4a diff for any other instance.

H1 [per-ref fault isolation — one bad ref must not kill the repo].
git 2.55.0 lists 76 refs with a warning where we return zero refs and
an error, for BOTH a dangling tag (target object missing) and a
broken/empty loose ref file. FIX:
  - peel failures of ANY kind → peeled: None (peel is best-effort
    metadata; never the ref's identity);
  - list(): a ref whose decode fails is SKIPPED and surfaced as a page
    warning naming the ref (git's model — never fewer honest refs, and
    never zero);
  - resolve() on a ref whose TARGET OBJECT is missing still returns
    the direct OID (a RefDB maps names to IDs; object availability is
    the ODB's business);
  - every such error path carries the ref name in details (the current
    .map_err discards it).
Fixtures: add a dangling packed tag, a dangling loose ref, an empty
loose ref file, and a garbage loose ref file to the refs fixture;
differential asserts our list == git's for-each-ref output on that
repo (modulo the skipped brokens, asserted via warnings).

H3 [provider symbolic chains — contract decided: per-hop atomicity,
documented]. ProviderRefDb inherits the default resolve_following
(one provider call per hop) — a moving backend can mix generations
across a symbolic chain. DECISION: this is the documented contract:
  - RefDB.Backend @doc + RefDB.resolve/3 @doc state plainly: each
    symbolic hop is an independent, per-hop-atomic backend call; a
    backend that needs chain-coherent answers must resolve symbolics
    internally and return direct targets (the recommended shape —
    typical API-backed providers return direct SHAs anyway);
  - the local store IS single-shot (packed snapshot held across hops —
    keep the review's probe as a Rust regression test if not already
    present);
  - replace the false-assurance R4 test: the alternating-backend test
    must use a SYMBOLIC target and assert the observed per-hop
    behavior (two calls, second generation's value wins), plus keep a
    direct-target single-call assertion.
No new callback in 0.x (resolve_following/2 as an optional callback is
noted as a post-1.0 option in the @doc).

M1 [Repository.open must survive an unopenable ref store]. A reftable
repo currently cannot be opened AT ALL, though {:oid,...} needs no
refs. FIX: LocalRefDb::open failure → Repository opens with refs
absent, the failure reason STORED; the four ref selectors return
:unsupported_operation carrying that stored reason (machinery exists
at repository.ex:181-189). Test with the reftable fixture: open
succeeds, {:oid,...} works, {:branch,...} refuses naming reftable.

M2 [uniform ref-name ceiling]. A >4057-byte ref name at a page
boundary makes list() permanently fail ResultTooLarge; meanwhile the
provider path caps names at 4096. DECISION: uniform 4096-byte full-ref
-name ceiling across local + provider: local resolve/list treat an
over-limit name as :malformed_ref naming the length (documented
divergence from git, which accepts them; a >4KiB ref name is hostile).
Generate.sh appends one to packed-refs (git tools accept it) and the
Rust test asserts the skip-with-warning path (H1 machinery) rather
than a dead listing.

M3 [prefixed iteration]. list() walks the whole namespace per page and
filters in Rust; gix-ref exposes Platform::prefixed (verified in
vendored source). FIX: use prefixed iteration when a prefix is set
(resume-skip stays within the prefix); document the per-page skip cost
in RefDB.list/3 @doc. Budget::check per visited ref already exists.

M4 [peel semantics = git for-each-ref]. Peel by TARGET OBJECT KIND,
not namespace: lightweight tags (direct commit target) → peeled nil
(git's *objectname is empty there — we currently emit peeled=self);
any ref whose direct target is a TAG OBJECT peels, regardless of
namespace. TRUST packed-refs ^{} peel records where present (git
does; kills the per-tag ODB read and half of H1a's exposure);
recompute only for entries without one. Differential parity test now
compares objecttype AND peeled columns (%(objecttype), %(*objectname))
— the review proved today's test cannot see this class.

M5 [honest ref-page stats]. Wire objects_read/objects_requested/
decompressed_bytes from the budget into ref-page stats (currently
hardcoded zeros while annotated-tag peels do ODB reads).

M6 [declare the symbolic-list divergence]. list() reports UNFOLLOWED
targets (symbolic stays symbolic) where git for-each-ref resolves —
deliberate; document in RefDB.list/3 @doc AND state it in the parity
test where the re-resolution workaround lives (comment naming it a
documented divergence, not an absorbed one).

M7 [async parity]. Add RefDB.async_resolve/3 + RefDB.async_list/3
following the established async conventions (provider-backed refs
with a 15s request timeout are exactly the case for a job handle).

M8 [provider cursor hygiene]. Reject refs == [] && truncated == true
as :provider_protocol_error (infinite-loop bait); cap INBOUND cursor
length at MAX_CURSOR_BYTES on the provider path (outbound already is).

M9 [conformance kit = core strictness]. validate_target enforces full
-ref-name validity for symbolic targets (core does; the kit passing a
backend core will reject defeats the kit's purpose). Add kit sections:
optional-list absent → :unsupported_operation; refresh contract;
terminate/2 invoked on stop; provider crash → :provider_down.

M10 [restore the survival knowledge]. The ref provider tree is a
comment-stripped copy of the ODB provider. Restore the M2d trap_exit
rationale ("without this, terminate/2 never runs on clean stop —
0/100 in a direct probe"), the watchdog-before-provider child-order
invariant moduledoc, and the caller-runs-init rationale, adapted to
refs; real @moduledoc on the supervisor. The comments ARE the
regression guard for the next refactor.

LOW batch:
- L1: document + test repo-agnostic ref cursors (identity digest is
  all-zeros by design — cursors resume coherently across repos; add
  the cross-repo acceptance test the review ran by hand, plus a
  forged-cursor and near-limit-cursor test).
- L2: normalize_reply's {:invalid_cursor, binary} smuggling → an
  explicit error path a reader can follow.
- L3: remove (or correct) the unreachable :symbolic → protocol-error
  clause in repository.ex.
- L4: drop Snapshot.open_with's unused _resource; distinct operation
  atoms for peel-allowed vs peel-forbidden snapshot opens.
- L5: Oracle.check_ref_format guards non-UTF-8 argv (skip that probe
  name on platforms whose System.cmd rejects it, assert on Linux —
  comment why).
- L6: Code.ensure_loaded? before function_exported? in RefDB AND ODB
  validate_backend (fix the inherited instance too).
- L7: from_stores @doc states cross-repository composition (ODB from
  one repo, refs from another) is the caller's responsibility and is
  not detected.
Test-gap batch (from the fixture-blindness audit): local symbolic
cycle ON DISK (fixture), HEAD→missing (unborn) fixture, tag→tree
end-to-end selector test, stale-packed-after-loose-delete pin,
lightweight {:tag,...} selector test, {:branch, "../..."} traversal
assertion, component-edge names the review probed (trail./x, a.b.c,
bracket]name) into the fixture corpus.

Report: per-finding summary with evidence (the H1 repo listing 76 refs
with warnings, the M4 objecttype/peeled parity run, the H3 symbolic
alternating-backend observation), test counts (plain + loom), any new
divergence for triage, conversion-site list for any new field,
unverified Elixir edits, deviations.
