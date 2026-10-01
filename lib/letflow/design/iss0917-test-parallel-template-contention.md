# ISS-0917: `scripts/test_parallel.sh` template-build contention at high N + misleading aggregator + orphaned partition processes

Design for `docs/issues/ISS-0917.yaml`. No implementation code below — control
flow, conditions, and knobs only. Build from this design, don't invent a
different shape (per this repo's own `lib/letflow/design/` convention).

## 0. Scope and non-goals

Affects `scripts/test_parallel.sh` and `test/test_helper.exs` (a new sentinel
write, see §1.3) — **not** `test/support/tenant_template.ex`'s own build
logic, which is unchanged. Pure CI/dev tooling: no `lib/` change, no
migration, no tenant-data-path change, no API/response-shaping change.

**SECURITY-REVIEWER: not required.** Nothing here touches a tenant-data path
(security-invariants.md INV-1..INV-8 are about real tenant schema
provisioning/isolation; this design only changes *when* and *how many at
once* a test-only, already-reviewed template-build function is invoked, and
adds script-side process-lifecycle bookkeeping). REVIEWER (OTP/idiom/scope
gate) still applies as usual to whatever ELIXIR-DEV produces from this.

## 1. Fix 1 — root-cause the template-build contention (not a lower default N)

### 1.1 Diagnosis (read from the real current files, not assumed)

Each partition owns its **own, separate physical Postgres database**
(`letflow_test-partition-<i>` equivalent via `MIX_BUILD_PATH`/`ecto.create`
in Step 1.7) — `tenant_template.ex`'s advisory lock
(`pg_advisory_lock(hashtext(@advisory_lock_key))`, `ensure_template!/0`
line ~149) only ever serializes callers *within one database*. Since
ISS-0515, there is exactly one caller per partition (`test/test_helper.exs`
line 94, synchronous, before `ExUnit.start/1` dispatches anything) — so
**there is no intra-partition race left for a lock to resolve.** The
advisory lock is correct as-is and is not the thing to change.

The real contention is *inter-partition*, at the Postgres **server**
level, not at the connection-count level: Step 1.5 already clamps
`TEST_POOL_SIZE` so `N * TEST_POOL_SIZE` fits the connection budget
(decision 0009), and Step 1.7 (ISS-0698) already caps `ecto.create`/
`ecto.migrate`'s own launch-time connection burst. Neither of those
covers what happens next: Step 2 launches all N `mix test` processes
with **no stagger at all**, and each one's `test_helper.exs` immediately
(before any real test runs) calls `ensure_template!/0`, which — on a
partition database seeing it for the first time — runs `build_template!/0`:
`CREATE SCHEMA` + a full `replay_migrations/2` of every tenant-scoped
migration (53 on the branch this was measured on), pinned to ONE checked-
out connection for the whole build (`Repo.checkout/2`, ISS-0842).

At N=16, that is 16 full, CPU/IO-heavy migration replays hitting one
Postgres **server process** at the same wall-clock instant — a real
resource-contention burst (CPU, WAL, lock manager), not a connection-count
overflow (Step 1.5's clamp already prevents that part). Under that load,
individual statements inside a straggler partition's single pinned
connection can take long enough that `Repo.checkout/2`'s default 15000ms
client-side timeout (Ecto/DBConnection's own default) fires, and that
partition aborts before ever producing a `Result:` line. This is the same
*class* of problem Step 1.7 already fixed for `ecto.create`/`ecto.migrate`
(ISS-0698) — just one layer later in the startup sequence, for a burst
Step 1.7's own cap does not cover.

### 1.2 Why NOT "just cap N"

- `scripts/test_parallel.sh`'s own Step 0 comment (ISS-0219 note) and AC4
  (req113-parallel-test-runner.md) are explicit: N must derive from
  `TEST_PARALLEL_N`/`nproc`/`getconf` or hard-fail — **never a hardcoded
  fallback, and never silently capped** in the script's own derivation
  logic. Auto-capping N here would re-decide that acceptance criterion,
  which core-directives.md's "don't silently re-decide a settled decision"
  rule forbids without a REVIEWER sign-off this issue does not grant.
- The existing, already-documented mitigation for "this host's Postgres/
  CPU budget can't sustain `nproc`-derived N" is a **per-host**
  `TEST_PARALLEL_N` override (ISS-0219's own script comment, and the
  zombie-BEAM anti-pattern entry's "always set `TEST_PARALLEL_N=4` here").
  That stays exactly as-is — this design does not touch it, and does not
  contradict it.
- A lower default would also just move the cliff, not remove it: the
  underlying burst (N simultaneous full migration replays) exists at any
  N large enough relative to the host's Postgres/CPU budget; fixing the
  burst mechanism itself is the fix that scales, per the issue's own ask
  ("prefer fixing the root contention over just picking a lower default N").

**Decision: fix the burst at its source with a capped-concurrency stagger
on template-build launches (§1.3), not a lower/auto-capped N.**

### 1.3 Fix: capped-concurrency template-build stagger (new Step 1.8)

Same idiom Step 1.7 (ISS-0698) already established for the
`ecto.create`/`ecto.migrate` burst — capped in-flight concurrency via a
`wait -n -p`-style poll loop — applied one phase later, to the interval
during which a partition is *inside its own template build*, not to the
partition's entire run (which must stay fully parallel for N's whole
intended benefit).

**Mechanism, in order:**

1. **New per-run sentinel directory.** Alongside the existing `tmp_dir`
   (created once per invocation, already `trap`-cleaned — see Fix 3), add
   a subdirectory, e.g. `$tmp_dir/template-ready/`. Export its path as a
   new env var, e.g. `TEST_PARALLEL_TEMPLATE_READY_DIR`, shared by every
   partition (global-exported, same idiom as `TEST_PARALLEL_GROUP`).

2. **`test/test_helper.exs` signals completion, not `tenant_template.ex`.**
   Immediately after the existing `ensure_template!()` call (line 94),
   when `TEST_PARALLEL_TEMPLATE_READY_DIR` is set (i.e. only under
   `scripts/test_parallel.sh`; a bare `mix test` or
   `mix letflow.check.test` single-process run is unaffected), touch an
   empty marker file named after `MIX_TEST_PARTITION`, e.g.
   `<dir>/partition-<i>.ready`. Deliberately placed in `test_helper.exs`,
   not inside `ensure_template!/0` itself — `tenant_template.ex`'s own
   moduledoc scopes it as "not referenced from `lib/`, a plain module,"
   with no CI-signaling responsibility; keeping the sentinel write at the
   call site keeps that module's public contract unchanged and keeps this
   entirely a test-harness-level concern.

3. **Step 2's launch loop becomes launch-with-admission-control.** Track
   an in-flight-builders counter (partitions launched but whose ready-file
   has not yet appeared). Before launching partition `i`, if the counter
   is already at a new cap knob (e.g. `TEST_PARALLEL_MAX_CONCURRENT_TEMPLATE_BUILDS`,
   default reusing Step 1.7's precedent value of 4 — same reasoning:
   bound simultaneous heavy-DDL bursts without serializing the whole
   suite), poll the ready-dir (short fixed interval, e.g. every 200ms) for
   at least one new `partition-*.ready` file to appear; each one seen
   decrements the counter by one. Only once the counter is below the cap
   does partition `i` get launched (which increments the counter back up
   for `i`). Every partition still gets launched by the end of Step 2 —
   this only bounds *how many are simultaneously mid-build*, never the
   final total concurrency once builds are done (Step 1.5's steady-state
   pool-size clamp already covers post-build concurrency).
4. **Bounded wait, not an unbounded poll.** The ready-file poll in step 3
   is itself bounded by the same per-partition wall-clock deadline Fix 3
   introduces (§3.2) — if a partition's build is genuinely stuck (not just
   slow), that partition's own timeout/kill (Fix 3) fires and frees the
   admission-control slot (its absence from the ready-dir after the
   deadline is itself the signal to stop waiting on it and fail loudly,
   not spin forever).
5. **Failure path.** If a partition's own `mix test` process exits (crashes)
   before its ready-file ever appears, admission control must not hang
   waiting for a file that will never arrive — poll against the tracked
   PID's liveness too (`kill -0 $pid`), and treat "process exited without
   a ready-file" as an immediate, loud `ERROR` (this is functionally the
   ISS-0698-style "no partition launched past this failure" contract,
   adapted: a build-phase failure here should stop admitting NEW
   partitions and propagate as a script-level failure, consistent with
   Fix 2's aggregator hardening in §2).

**Open question (OQ-1, do not silently resolve):** the default value for
`TEST_PARALLEL_MAX_CONCURRENT_TEMPLATE_BUILDS`. §1.3 proposes reusing
`TEST_PARALLEL_MAX_CONCURRENT_CREATES`'s existing default of 4 as a
starting point (same class of burst, same host), but that default was
itself measured, not guessed (ISS-0698's own design doc) — ELIXIR-DEV/
TEST-RUNNER should re-measure against this specific burst (full-suite run
at N=16 with the stagger in place, watching for any partition still
aborting on the 15s checkout timeout) before locking in a final default,
rather than assuming the reused value is correct unverified.

**Open question (OQ-2, do not silently resolve):** whether
`Repo.checkout/2`'s default 15000ms timeout inside `ensure_template!/0`
should ALSO be raised/made configurable (e.g. a `TEST_TEMPLATE_BUILD_TIMEOUT_MS`
knob) as defense-in-depth, so a transient overload under the stagger
degrades to "slower" rather than "hard abort." This is a complementary,
NOT primary, mitigation — the stagger in §1.3 is the fix for the
contention itself; raising a timeout only widens the margin around
whatever residual contention the stagger doesn't fully absorb. Left
open rather than guessed at because a wrong (too-generous) value here
could mask a real regression by letting a script hang long past when a
human would want to know something is wrong — this needs REVIEWER/
ELIXIR-DEV judgment with real measurements, not an invented number.

## 2. Fix 2 — aggregator must hard-fail when fewer than N partitions report

### 2.1 What the current script already does (read from the real file)

`scripts/test_parallel.sh` Step 4 (the per-partition loop, `has_result`
check) already treats a partition with no `Result:` line in its log as
`partition_failed=1` → `any_failed=1` — so a partition that legitimately
aborts and its `mix test` process EXITS should already fail the run. The
reported incident ("1553 tests/0 failures" while only 5 of 16 partitions
had reported) is exactly the failure mode Step 3's *individual* `wait
"${pids[$i]}"` calls are supposed to prevent from ever reaching Step 4 in
a stale/incomplete state — each `wait` blocks until that specific PID
truly exits, so Step 4 cannot begin counting until every partition's
process has actually terminated one way or another.

### 2.2 The gap: no explicit, structural "did everyone report" invariant

The per-partition `has_result`/`partition_failed` logic (§2.1) is a
*per-item* anomaly check — correct, but it depends on every anomaly path
being individually correct, forever, across every future edit to Step 4.
It is not, on its own, an explicit assertion of the invariant the issue
names directly: **"count of reporting partitions != N" must itself be a
hard-fail condition**, independent of and in addition to the per-partition
checks — so a future bug in the per-partition logic (or an interruption
class not yet anticipated — e.g. Fix 3's own per-partition timeout path,
§3, producing a log file that exists but is truncated mid-write) cannot
silently slip back into a "0 failures" outcome the way this incident
describes.

**Fix:** add an explicit, separate tally alongside the existing
per-partition loop:

- Maintain `reporting_count` = number of partitions whose log had a
  `has_result=1` (a real `Result:` line found), incremented in the same
  loop that already computes `has_result` per partition (no new pass
  needed — just an additional accumulator).
- After the per-partition loop completes (still within Step 4, before
  the combined summary line is printed), explicitly compare
  `reporting_count` against `N`. If `reporting_count -ne N`, this is
  ALWAYS a hard failure (`any_failed=1`), **regardless of what
  `total_failures` parsed to** — printed as its own loud, unambiguous
  `ERROR` line naming exactly which partition indices never reported
  (e.g. list every `i` where `has_result` was 0), BEFORE the existing
  `echo "---"` / combined-summary block, so the failure signal is the
  first thing visible, not buried after a misleadingly-clean-looking
  totals line.
- The combined summary line itself (`echo "combined: ..."`) should be
  amended to also print `reporting_count/N partitions reported` inline,
  so even a casual read of that one line makes a partial run visually
  obvious rather than requiring a reader to scroll up for the per-
  partition warnings.

### 2.3 Exit-code contract (unchanged in spirit, strengthened in coverage)

Step 5's existing contract — "the parsed failure count is authoritative,
not the raw per-partition exit code" (design doc section 4.6, already
documented in the script) — is preserved. This fix does not replace that
authority; it adds one more structural precondition that must hold before
"0 failures" is allowed to mean "the run passed": `reporting_count == N`.
`any_failed` becomes the OR of (a) any parsed failure across reporting
partitions, (b) any individual partition anomaly already detected (§2.1),
and (c) this new `reporting_count != N` check. All three are already
combined into a single `any_failed` accumulator in the existing code
shape — (c) is simply one more condition that can set it, evaluated once,
after the per-partition loop, rather than per-partition.

## 3. Fix 3 — orphaned partition processes on abort/timeout

### 3.1 What already exists

The zombie-BEAM anti-pattern entry (`docs/anti-patterns.md`, "An
interrupted `mix letflow.check.test`/`scripts/test_parallel.sh` run leaves
zombie BEAM VMs...") already documents that this script's background
`mix test &` children are NOT reliably part of the invoking shell's own
job-control group in every shell invocation shape, and survive their
parent's own termination as orphans. The existing `trap cleanup_tmp_dir
EXIT` (line ~346) only cleans the tmp dir and the optional connection
sampler PID (`_test_parallel_sampler_pid`) — it does **not** currently
touch the `pids[]` array of partition PIDs at all.

### 3.2 Fix: per-partition wall-clock deadline + process-group-scoped kill

Two complementary mechanisms, both needed (one bounds a single stuck
partition without needing the whole script to be interrupted; the other
is the safety net for every other exit path, including an external
interruption of the script itself):

1. **Launch each partition in its own process group**, not just as a bare
   background job — e.g. via `setsid` (or equivalent job-control idiom)
   wrapping each partition's `mix test` invocation in Step 2, so the
   partition's own `mix`/`erl.exe`/`beam.smp` process tree shares one
   group id distinct from the script's own. This is what makes "kill the
   whole tree" possible with a single signal to `-$pgid`, rather than
   only ever being able to reach the immediate backgrounded child (the
   mechanism the anti-pattern entry's own root-cause analysis names as
   the actual gap: signals to the wrong process don't reach the real
   `erl.exe` grandchild).
2. **A per-partition wall-clock deadline**, a new overridable knob (e.g.
   `TEST_PARALLEL_PARTITION_TIMEOUT_S`), enforced by wrapping each
   partition's launch command with a timeout mechanism that signals the
   **whole process group** (not just its immediate child) on expiry —
   first TERM, then escalate to KILL after a short grace window if TERM
   is ignored (mirrors the `timeout --kill-after=<grace> <duration> <cmd>`
   shape, but scoped to the process-group formed in step 1, since a plain
   `timeout` only signals its own immediate child by default and would
   miss the grandchild `erl.exe` the same way the current bare background
   job does).
3. **Extend the existing EXIT trap** (`cleanup_tmp_dir`, already
   registered) to ALSO sweep `pids[]`: for every partition PID still
   alive at trap time (checked via `kill -0`), send the same
   group-scoped TERM-then-KILL sequence as step 2, before the trap's
   existing tmp-dir cleanup logic runs. This is the safety net for every
   exit path that is NOT a single partition's own timeout — an external
   interruption of `test_parallel.sh` itself (Ctrl-C, a Bash-tool-call
   timeout per the anti-pattern entry, the new Fix 2 hard-fail path, or
   any other early `exit`) now also reliably reaps every still-running
   partition's whole process tree, not just this script's own tmp dir
   and sampler.

**Open question (OQ-3, do not silently resolve):** the default value for
`TEST_PARALLEL_PARTITION_TIMEOUT_S`. Must be generous enough to never
false-positive on a genuinely slow-but-healthy full-suite partition run
(the issue's own re-run at `TEST_PARALLEL_N=6` passed 5079/5079 — but this
design doesn't have that run's wall-clock duration on hand to derive a
safe margin from). ELIXIR-DEV/TEST-RUNNER must measure a real full run's
slowest partition before picking a number here — left open rather than
guessed, per this role's own constraint against silently resolving an
open question.

## 4. Acceptance criteria

- **AC1 (Fix 1 — root contention, not a lower default N).** At
  `TEST_PARALLEL_N=16` (or any host's real `nproc`), no partition aborts
  with a `Repo.checkout/2` 15s-timeout failure during its own
  `ensure_template!/0` call, verified by a real full-suite run on a host
  that previously reproduced the failure. The script's own Step 0 N-
  derivation logic (AC4 of req113) is UNCHANGED — no auto-cap, no
  hardcoded fallback added anywhere in `scripts/test_parallel.sh`'s N
  derivation. A new, documented, overridable concurrency-cap knob
  (§1.3, OQ-1) exists and is honored.
- **AC2 (Fix 1 — mechanism, not band-aid).** The fix is a capped-
  concurrency stagger on template-build launches (§1.3), not merely a
  raised timeout. `tenant_template.ex`'s own advisory-lock mechanism is
  UNCHANGED (confirmed still correct for its actual, intra-partition-only
  scope per §1.1 — no unnecessary rework of code that was never the
  problem).
- **AC3 (Fix 2 — explicit reporting-count invariant).** When fewer than N
  partitions produce a `Result:` line (simulate by forcing one partition
  to abort before reaching ExUnit, e.g. via a deliberately-broken
  `MIX_BUILD_PATH` or an injected early exit), the script:
  - prints a loud, unambiguous `ERROR` naming exactly which partition
    index/indices never reported, appearing BEFORE the combined summary
    line;
  - exits non-zero;
  - the combined summary line itself states `reporting_count/N` inline.
  This must hold **even when every reporting partition's own parsed
  failure count is 0** (the exact "1553 tests/0 failures" shape this
  issue reports) — that is the specific gap this AC closes.
- **AC4 (Fix 2 — existing contract preserved).** Every currently-passing
  behavior of Step 4/5 (has-Result-line per-partition check, exit-code/
  parsed-count cross-check warnings, parsed-failure-count authority over
  raw exit codes) still holds unchanged when all N partitions report
  normally — this fix only ADDS the `reporting_count == N` gate, it does
  not alter the existing per-partition anomaly detection or the
  authoritative-parsed-count exit contract.
- **AC5 (Fix 3 — no orphaned process on a single partition timeout).**
  A partition that never completes within
  `TEST_PARALLEL_PARTITION_TIMEOUT_S` has its entire process group
  (mix + erl.exe/beam.smp) terminated by the script itself, verified by
  confirming no matching process remains in the OS process table after
  the script's own run (whether that run overall passes or fails) — not
  by a human having to find and kill it by hand, per this issue's own
  reported symptom.
- **AC6 (Fix 3 — no orphaned process on script-level interruption).**
  When the script itself exits early via ANY path (the new Fix 2
  hard-fail, an external interruption, or any pre-existing `exit 1` path
  already in the script), every partition PID still alive at that moment
  is also reaped (group-scoped TERM-then-KILL) by the extended EXIT trap
  — not just the tmp-dir/sampler cleanup the trap already performs.
- **AC7 (regression safety).** A full run at a known-good N (e.g.
  `TEST_PARALLEL_N=6`, the value confirmed clean in the issue) still
  passes with the same pass/fail totals as before this change, with the
  stagger/timeout/trap mechanisms adding no new false failures at that N.
- **AC8 (consistency with prior history).** Nothing in this design
  contradicts or silently re-decides ISS-0069/ISS-0219/ISS-0222/ISS-0287's
  host-connection-ceiling checks (Step 1.4/1.5 untouched), ISS-0453's
  PollerTest flake (unrelated subsystem), or ISS-0698/ISS-0699's own
  capped-concurrency and tmp-dir-cleanup mechanisms (this design reuses
  and extends both idioms rather than replacing them).

## 5. Cross-module / cross-file impact summary

- `scripts/test_parallel.sh`: new Step 1.8 (template-build admission
  control, §1.3), extended Step 4 (§2.2), extended EXIT trap + process-
  group-scoped launch and per-partition timeout (§3.2). New env knobs:
  `TEST_PARALLEL_TEMPLATE_READY_DIR` (internal, script-set),
  `TEST_PARALLEL_MAX_CONCURRENT_TEMPLATE_BUILDS` (overridable, OQ-1),
  `TEST_PARALLEL_PARTITION_TIMEOUT_S` (overridable, OQ-3).
- `test/test_helper.exs`: one new guarded side effect immediately after
  the existing `ensure_template!()` call (line 94) — write a ready-file
  sentinel when `TEST_PARALLEL_TEMPLATE_READY_DIR` is set. No change to
  `ExUnit.start/1`'s exclusion list or any other existing behavior in
  this file.
- `test/support/tenant_template.ex`: **no functional change.** Confirmed
  by §1.1's diagnosis that its advisory-lock/build logic is already
  correct for its actual (intra-partition) scope.
- No `lib/` change, no migration, no production/tenant-data-path change.

## 6. Invariants

- INV-A: `scripts/test_parallel.sh`'s N-derivation (Step 0) never
  hardcodes or auto-caps N — unchanged from AC4 of req113.
- INV-B: `tenant_template.ex`'s public API (`ensure_template!/0`,
  `template_ready?/0`, `template_schema_name/0`, `clone_tenant_schema!/1`,
  `assert_clone_parity!/3`) is unchanged — this design adds no new
  function there and changes no existing one's signature or behavior.
- INV-C: the combined run's exit code is 0 only if `reporting_count == N`
  AND every reporting partition's own parsed failure count is 0 AND no
  per-partition anomaly was flagged (§2.1) — a strict tightening of the
  existing contract, never a loosening.
- INV-D: every partition process this script itself launches is
  reachable for a group-scoped kill by this script, on every exit path
  (normal completion, per-partition timeout, or script-level early exit).

## 7. Open questions (summary — do not resolve by guessing)

- OQ-1: default for `TEST_PARALLEL_MAX_CONCURRENT_TEMPLATE_BUILDS` —
  needs real measurement against the reported N=16 failure, not assumed
  from ISS-0698's reused default.
- OQ-2: whether to also raise/make configurable `ensure_template!/0`'s
  `Repo.checkout/2` 15s timeout as defense-in-depth, and to what value.
- OQ-3: default for `TEST_PARALLEL_PARTITION_TIMEOUT_S` — needs a real
  full-suite run's slowest-partition wall-clock time as input.
