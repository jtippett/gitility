# M3e review fixes — decisions and dispatch

Adversarial review of the M3e checkpoint (a4c5d33) fuzzed the
.gitmodules parser against git 2.55.0 (3,456-case value sweep, 70-case
curated corpus, 1M random inputs) and the LFS parser against the real
git-lfs 3.7.1 reader. Decisions FINAL. Same constraints: NO BEAM;
Rust-side verification only; Elixir edited, never executed; do not
commit.

H1+M3+M4+M5 [REPLACE gix-config with our own scoped parser]. gix-config
0.59.0 (latest; no upgrade fix) silently returns EMPTY values where git
returns real bytes (a value line ending in `\` before EOF/blank line —
198/3456 sweep cases), mangles `\b`-class escapes (24 more), accepts
files git rejects fatally (0xFF in subsection, BOM, bad config lines —
inventing submodules git never sees), does not lowercase dotted-form
`[submodule.Name]` subsections (splitting one git submodule into two of
ours), synthesizes `path = "true"` for valueless `path`, and carries
NUL-bearing subsection names git truncates. DECISION: write our own
minimal git-config parser in submodules.rs (or a sibling module),
scoped to what .gitmodules can contain, whose ONLY correctness target
is byte-parity with the pinned git 2.55.0 config reader:
  - acceptance set == git's (inputs git rejects with "bad config line
    N" → :malformed_object with the line number in details; inputs git
    accepts → we accept with identical section/key/value bytes);
  - semantics from the review's probe tables: case-insensitive section
    and key names, case-sensitive quoted subsection, dotted-form
    subsection LOWERCASED (git's get_base_var), NUL truncates the
    subsection name and the line, 0xFF treated as EOF where git does,
    valueless key = implicit bool (see H2 for how path uses it),
    last-wins duplicates, `\t \n \\ \"` + `\b`-class escapes exactly as
    git, continuations incl. the trailing-`\`-at-EOF/before-blank cases
    (value survives), comments, quoting, whitespace trim rules,
    lone-CR tolerance where git tolerates it;
  - allocation strictly O(input) with small constants (kills M6's 42x
    amplification), plus a dedicated 1 MiB cap on the .gitmodules blob
    itself (:object_too_large naming the cap in details — a config
    file larger than that is hostile; document).
Verification is the deliverable: port the review's probe corpus into
(a) an in-repo curated corpus (~100 cases incl. every minimal
reproduction from the review tables) run against `git config --blob
--list --null` in a Rust differential test, and (b) a randomized
mutation fuzz (bounded iterations, deterministic seed) asserting
accept-set and value equality vs the same oracle, and (c) an
EXHAUSTIVE 3,456-case sweep behind env var
GITILITY_EXHAUSTIVE_ORACLE=1 (documented; not run in normal CI). Fix
the oracle-record parser first (L1: `git config --list --null` emits
`key\0` with NO `\n` for valueless keys — current .expect panics; and
--null framing cannot carry NUL-bearing values, so NUL cases assert
through our API instead — comment this).

H2 [per-declaration degradation, git-parity acceptance]. One bad
declaration must not fail the query. DECISION:
  - a declaration WITHOUT a usable path is IGNORED (git's submodule
    machinery only resolves modules by path — probed: git lists the
    config key but maps no submodule). Document this in @doc.
  - path VALUE validation is REMOVED (validate_path deleted): paths
    are inert correlation bytes — "../evil", "/etc/passwd", trailing
    slash etc. are accepted exactly as git accepts them and simply
    correlate to nothing (:orphaned). We never touch a filesystem with
    them; say so in the moduledoc. NUL handling comes from the parser
    (git truncates the line at NUL — match it).
  - :malformed_object is reserved for files git itself rejects (H1
    acceptance set).
  - a .gitmodules tree entry that is NOT a blob (tree/symlink/gitlink)
    → treated as absent (git ignores it; the symlink refusal from the
    checkpoint is RESCINDED in favor of git parity — but note in the
    @doc that git itself refuses symlinked .gitmodules in the WORKING
    TREE post-CVE-2018-11235; from a bare snapshot the entry is simply
    not a blob and yields no declarations).
  - name/path collision (two names declaring one path): deterministic
    — the name that sorts first (BTreeMap order) claims the gitlink
    (:active), later ones are :orphaned; document (L4).

M2 [LFS — match the git-lfs READER exactly]. The M3e round accepted
four shapes the real reader rejects. DECISION: parse_lfs_pointer
matches git-lfs 3.7.1's DecodePointer semantics on every probed axis:
  - restore the key sort-order requirement (previous_key >= key was
    correct);
  - reject duplicate version lines;
  - reject unknown keys (update the "unknown-key" fixture + Elixir
    assertion to expect nil);
  - size cap at i64::MAX (reader parses int64);
  - ACCEPT leading whitespace/blank lines via TrimSpace-equivalent on
    the (≤1024-byte pre-trim) candidate, as the reader does;
  - keep: Hawser legacy URL, CRLF, missing final newline accepted;
    1024/1025 boundary (our pre-trim cap is stricter than the binary's
    read-first-1024 — keep, it matches the spec text; comment it).
Fix the wrong code comment; rename the "forward-compatible" fixture
to what it now is (not-a-pointer). Rust tests per axis.

M7+L6 [oracle hygiene]. Comment on the git-config oracle: `git config
--blob` FOLLOWS [include] paths (a local-file-read primitive) while
git's real .gitmodules reader does not — never point it at
include-bearing blobs; add an include-directive fixture asserted
through OUR API (ignored, matching `git submodule`'s behavior) and
NEVER through the --blob oracle. Loosen the brittle stderr-prefix
assertion to the "bad config line" substring + comment the pinned-git
mitigation.

LOW batch:
- L2: with validate_path gone, `path = ""` correlates to nothing →
  :orphaned; document empty-path sorting (first).
- L3: make Declaration.path non-optional post-parse (unrepresentable
  invalid state; the .expect goes away).
- L5: stop parsing/retaining update and shallow (dead fields dropped).
- L7: submodules/2 @doc documents: full unpaginated correlation walk
  bounded by max_objects (no cursor — narrow with limits if needed),
  sha256 stores unsupported via the existing compatibility check, and
  the H2 degradation rules.

Report: per-finding summary with the corpus/fuzz/sweep results vs git
(counts of match/reject-agree and ZERO silent value mismatches), the
git-lfs axis table after the fix, test counts (plain + loom), any
remaining divergence for triage, unverified Elixir edits, deviations.
