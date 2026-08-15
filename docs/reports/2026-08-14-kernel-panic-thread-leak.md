# Incident report: 2026-08-14 kernel panics traced to runtime thread growth

Two macOS kernel panics on James's dev machine (black-lagoon), both triggered
by a BEAM process that had accumulated ~10,000 native threads. This report
records the evidence, the analysis of this repo's runtime code, and the
mitigation now in the tree. Written by Claude (Fable) during the incident
session of 2026-08-14/15; James asked for the fix and this report to be left
in the repo.

## The incident

| | Panic 1 | Panic 2 |
|---|---|---|
| Time | 21:32 | 22:36 (booted 21:33, slept 21:53–22:31) |
| Panic | XNU spinlock timeout, `locks.c:798`, pthread kext | identical |
| Panicked task | `beam.smp` pid 43410, **10,142 threads** | `beam.smp` pid 29649, **10,405 threads** |

A healthy BEAM on this machine runs ~36 OS threads. The BEAM VM never grows
OS threads unboundedly on its own; only NIF-spawned threads can. The panic
itself is an XNU weakness (a spinlock hold that scales with thread count),
but the trigger was a process at ~10k threads. `kern.num_taskthreads` is
16384 and read-only on modern macOS, so there is no OS-level per-process
cap to lean on.

## Why this repo

- Gitility's NIF is the only actively developed code on the machine that
  spawns raw OS threads: `workers` per `Runtime` (named `gitility-worker-N`)
  plus one `gitility-notify` pump.
- Timing: the NIF (`priv/native/gitility.so`) was rebuilt at 21:21, eleven
  minutes before panic 1. At 19:55 a `gitility_core` loom test binary
  aborted with SIGABRT — `panic_in_cleanup` inside `Runtime::shutdown`, in
  a test named `loom_audit_two_workers_two_jobs_no_lost_wakeup` — direct
  evidence the shutdown path was misbehaving that evening.
- Both abnormal beams lived under the Zed session, like all dev beams here.

**The honest caveats.** At the M2a commit (`0a57d08`, 20:36) the Elixir
`Runtime` was entirely stubs and `lib.rs` had no runtime bindings at all:
every line of working runtime code was uncommitted, written in exactly the
crash windows, and the intermediate drafts were overwritten in place. The
aborting loom test (`counted_model` audit) is not in the committed file
either — also a draft. So the crash-era defect itself is unrecoverable. A
bounded live experiment against the surviving 21:21 binary (20 runtimes
clean-stopped, 20 brutally killed, in an owned beam) cleaned up perfectly
both ways (36 → 136 → 36 threads), and the checked-in test suite creates
only ~14 runtimes — nowhere near the ~1,600 needed for 10k threads. The
leak therefore needed either a draft-only bug or a jobs-in-flight
interleaving that experiment did not exercise. Attribution to this repo is
high-confidence; attribution to a specific line is not possible.

## Defects identified in the surviving code

1. **Wedgeable shutdown.** `Runtime::finish_shutdown`
   (`crates/gitility-core/src/runtime/mod.rs:744`) joins every worker
   unconditionally. A task that blocks without reaching a `Budget::check`
   point wedges the join forever. Because `runtime_shutdown`
   (`native/gitility/src/lib.rs:528`) is a DirtyIo NIF, a wedged join
   permanently occupies one of the BEAM's ~10 dirty IO schedulers and can
   never be killed.
2. **Kill-during-join strands threads.** `Gitility.Runtime.terminate/2`
   (`lib/gitility/runtime.ex:151`) calls that blocking NIF; a supervisor's
   default 5s shutdown then `:kill`s the GenServer mid-join, silently
   stranding workers and pump. The soak helper's `catch :exit, _ -> :ok`
   in `stop_runtime` swallows exactly this evidence.
3. **Silent teardown-by-detachment.** `RuntimeResource::Drop`
   (`native/gitility/src/lib.rs:147`) cannot join from a scheduler, so it
   delegates shutdown to the detached pump
   (`notification_pump`, `lib.rs:268`). Correct when it works; invisible
   when it does not — no error, no log.
4. **No process-wide thread cap** — nothing prevented any of the above, or
   any orchestration bug, from growing until the kernel died. **Fixed; see
   below.**

The amplifying workload was the M2b iteration loop (the 30s soak plus
parity tests hammering submit/cancel/detach against draft after draft);
`exclude: [soak: true]` was added to `test_helper.exs` during that session.

## The fix in this change (defect 4): a process-wide thread budget

New module `crates/gitility-core/src/runtime/thread_budget.rs`:

- A process-global budget (default **512** threads, override with
  `GITILITY_THREAD_BUDGET`, read once at first use). At ~6 threads per
  default runtime that admits ~100 concurrent runtimes — far above sane
  use, far below kernel danger.
- `Runtime::try_start` (`mod.rs:509`) reserves `workers` slots up front and
  returns `Err(BudgetExhausted { requested, used, limit })` instead of
  spawning when the budget is exhausted. `Runtime::start` keeps its
  infallible signature for internal callers and panics with the same
  message on exhaustion.
- Every spawned worker owns exactly its own reservation as an RAII guard
  moved into the thread closure; release happens when the loop returns —
  including by unwind — so joins are never required for the budget to
  recover. The failed-spawn path releases unspawned slots the same way.
- The NIF pump draws on the same budget: `runtime_start` (`lib.rs:479`)
  reserves the pump slot first, then calls `CoreRuntime::try_start`;
  exhaustion raises in Elixir
  (`** (ErlangError) ... "gitility thread budget exhausted: requested N
  thread(s) with U/L in use ..."`) rather than spawning, so
  `Runtime.start_link` fails loudly and a leak announces itself at the
  moment it begins.
- `Runtime.stats/1` now also reports `thread_budget_used` and
  `thread_budget_limit`, so tests and telemetry can watch the global count.

The budget intentionally uses `std` atomics, not the loom-swapped `sync`
types: it is process-global bookkeeping and cannot participate in loom's
per-model state space (rationale in the module doc).

### Verification

- `cargo test -p gitility-core`: **104 passed** (97 pre-existing + 7 new
  budget tests covering reserve/release accounting, exhaustion reporting,
  split-reservation ownership, refused starts reserving nothing, shutdown
  returning every slot, and zero-worker normalization).
- `cargo check -p gitility` (NIF crate) and
  `RUSTFLAGS="--cfg loom" cargo check -p gitility-core --tests`: clean.
- `cargo fmt --check`: clean.
- **Not run, deliberately:** the Elixir suite / anything loading the NIF in
  a BEAM (per James's instruction after the second panic). The 21:21
  `priv/native/gitility.so` is untouched; the new code enters a BEAM only
  after the next `GITILITY_BUILD=1 mix compile`. First `mix test` after
  rebuilding should be run with the watchdog below active.

## Recommended follow-ups (defects 1–3, in order)

1. Make shutdown joins bounded: join with a timeout, escalate to a loudly
   logged detach. A wedged worker should cost its budget slot and a log
   line, not a dirty IO scheduler.
2. Log when pump teardown or a shutdown join exceeds a threshold, so
   teardown failure stops being silent.
3. Keep the soak excluded until 1–2 land. When re-enabling it, add an
   assertion that `thread_budget_used` returns to its pre-suite value at
   the end of the run.

Also: commit working states frequently during native-thread work — the
actual crash-era bug is unrecoverable only because it never got committed.

## Incident tooling left on the machine (outside this repo)

`~/.local/bin/beam-thread-watchdog.sh` — polls every beam.smp's thread
count, logs to `~/Library/Logs/beam-thread-watchdog/counts.csv`, and above
300 threads captures forensics (ancestry, open files, a 2s `sample` whose
output includes thread names) and fires a macOS notification. It never
kills anything. Start it before the next NIF-loading test run:

```bash
nohup bash -c 'while true; do bash ~/.local/bin/beam-thread-watchdog.sh; sleep 20; done' >/dev/null 2>&1 &
```
