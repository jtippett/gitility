# M3e — LFS pointer + gitlink/submodule metadata

You are implementing Milestone 3e of Gitility — the LAST M3
sub-milestone, deliberately small. READ FIRST:
1. docs/plans/2026-08-14-gitility-design.md — "File reads" (lfs_pointer
   already ships), the non-goals (LFS never resolved; submodules never
   traversed; gitlinks never opened), "Limits and safety", "Error
   model", Milestone 3 item 6, and the 0.1 feature list lines
   ("LFS pointer recognition", "Submodule/gitlink metadata helpers").
2. crates/gitility-core/src/file.rs (parse_lfs_pointer — M1b),
   tree.rs, decode.rs; lib/gitility/types/{file.ex,tree_entry.ex}.
3. M3a–M3d milestone tests for the established idioms; the M3c/M3d
   lesson list (conversion sites; OIDS + {:oid,...} setup; no Range
   literals inside quoted test generators; guard-safe functions only).

ABSOLUTE CONSTRAINT — NO BEAM (docs/reports/2026-08-14-kernel-panic-
thread-leak.md): cargo/loom/clippy both cfgs/fmt/spawn-guard only;
Elixir edited, never executed; list unverified Elixir edits. Write
surface: crates/gitility-core/, native/gitility/, lib/, test/,
fixtures/ (generation scripts only), root Cargo.lock. Do not commit.
No new dependencies unless unavoidable (record evidence if so); no new
threads.

R1 [Gitility.submodules/2 — the new API]. New:
- Core (suggest crates/gitility-core/src/submodules.rs): read the
  snapshot root's `.gitmodules` blob if present (path is fixed by git;
  no search), parse it with GIT-CONFIG SEMANTICS for the subset git
  itself uses for submodules: `[submodule "name"]` sections with path/
  url/branch/update/shallow keys; case-insensitivity of section+key
  names (subsection name stays case-sensitive), whitespace, `#`/`;`
  comments, quoted values with backslash escapes, line continuations.
  Verify semantics against `git config --blob <oid> --list` as the
  oracle — never guess. Malformed .gitmodules → :malformed_object
  naming .gitmodules in details (git errors too — probe exact
  behavior). Size cap: .gitmodules over max_object_bytes →
  :object_too_large (it's a config file; a huge one is hostile).
- Correlate with the snapshot's ACTUAL gitlink tree entries (a bounded
  recursive walk charging the budget like list_tree): each result row
  carries name (or nil), path (raw bytes), url, branch (nil default),
  pinned commit OID (from the gitlink entry, nil if declared-but-
  absent), and a status: :active (declared + entry), :undeclared
  (gitlink entry with no .gitmodules section), :orphaned (declared
  with no entry). No .gitmodules AND no gitlinks → {:ok, []}.
- Deterministic order: by path bytes ascending.
- NEVER resolve URLs, NEVER open the gitlink commits (they are usually
  unreachable in the superproject ODB — must not error), NEVER
  traverse.
- Elixir: Gitility.submodules(snapshot, opts \\ []) →
  {:ok, [%Gitility.Submodule{}]} (new type module: name, path, url,
  branch, commit_oid, status; moduledoc states the never-resolve/
  never-traverse contract). opts: limits: only. async_submodules/2
  mirrors. M1c error conventions. New JobOutput variant, job idioms
  unchanged.

R2 [LFS recognition hardening — existing surface, edge coverage].
parse_lfs_pointer (file.rs) already ships. Verify it against the LFS
spec corpus and REAL git-lfs behavior (from your knowledge; no git-lfs
binary is pinned — document that the oracle is the spec): version line
must be first and exactly `version https://git-lfs.github.com/spec/v1`
(also accept the documented legacy alpha URL? — check what git-lfs
accepts and record the decision), oid sha256:<64 hex>, size <u64>;
keys in any order after version; trailing newline required?; a file
that merely STARTS with "version " but fails parsing is NOT a pointer
(plain blob, lfs_pointer: nil — never an error); pointers are ≤1024
bytes per the LFS spec — enforce (larger candidate → not a pointer).
Add Rust unit tests for each edge + an Elixir test asserting the
lfs_pointer map end-to-end (conversion-site discipline). If the
current parser already satisfies an edge, ASSERT it anyway (the tests
are the deliverable).

R3 [fixtures]. Extend fixtures/generate.sh sha1-diff.git (it already
has gitlinks) or a small new sha1-submodules.git — your call, record
it: a .gitmodules declaring: one normal submodule (name == path), one
with name != path, one with url + branch, one ORPHANED declaration
(no gitlink entry); plus one UNDECLARED gitlink entry; a nested-dir
gitlink (sub/dir/mod); a .gitmodules with comments, quoting, and odd
case in section/key names; LFS pointer fixtures: valid pointer,
pointer with extra unknown key, almost-pointer (bad oid line), >1024
bytes candidate. Deterministic, self-verifying, regenerate twice.

R4 [differential]. .gitmodules parsing parity: for each fixture
.gitmodules blob, compare our parsed sections/keys/values against
`git config --blob <oid> --list --null` (NUL-safe parsing — L16
lesson). Correlation logic (status classification) is OURS — cover it
with milestone tests, not differential. Any parsing divergence:
report for triage; allowlist untouched.

R5 [Elixir tests — written, not run]. test/milestone_3e_metadata_test.exs:
submodules happy path (all three statuses in one result, order by
path); name != path; nested gitlink; empty repo → []; malformed
.gitmodules error shape; oversize .gitmodules; LFS end-to-end
(read_file on each LFS fixture asserting lfs_pointer map or nil);
budget/cancellation via the established blocking-backend pattern;
async mirror; conversion-site checklist in your report (every new
field asserted through the full Elixir path). Follow ALL M3c/M3d
test-authoring lessons (OIDS + {:oid,...}; no ref selectors; no
struct literals in quoted generators; guard-safe only; explicit
range steps).

Report: per-requirement summary; Rust test counts (plain + loom); the
git-config oracle probes; the legacy-LFS-URL decision; any divergence;
conversion-site field list; unverified Elixir edits; deviations.
