# ISS-0446: throwaway-supervisor `on_exit` check-then-act teardown race — fix design

**Author:** CODE-DESIGNER, run WF03-ISS0446-20260904, Step 2
**Input:** `docs/issues/ISS-0446.yaml`, ISSUE-FIXER's Step 1 diagnosis
(`handoffs/WF03-ISS0446-20260904/step-01-issue-fixer-diagnosis.json`)
**Target file:** `test/letflow/engine/service_task_dispatcher_test.exs`, test at line 1113
("`service_task_dispatcher_children/0`'s child spec is independently startable as a
real GenServer under a throwaway supervisor"), specifically lines 1123-1141.

No production module is touched. No new public function, schema, or migration. This
document is scoped to a single test's fixture-teardown shape, per this role's mandate
that a design artefact exists even for a test-only WF-03 fix (`docs/agents/instructions/core-directives.md`'s
"File Placement Rules": design artefacts live in `lib/letflow/design/` regardless of
whether the change touches `lib/`).

---

## 1. Decision: adopt option (a) — drop the `on_exit` block entirely

**Change, stated as a diff of intent (not code):** delete the three-line `on_exit(fn ->
if Process.alive?(sup_pid), do: Supervisor.stop(sup_pid) end)` block currently at lines
1131-1133. Everything else in the test — the `Supervisor.start_link/2` call, the
`name: __MODULE__.ThrowawaySupervisor` registration, the `Supervisor.which_children/1`
call and its assertion, the `pid != Process.whereis(Letflow.Scheduler.Poller)` assertion
— is unchanged.

### 1.1 Why (a) and not (d) (`start_supervised!/1`)

This is the tradeoff the task requires being answered explicitly, not hedged.

**What (d) would buy:** structural immunity by a different mechanism than (a) — ExUnit's
own `terminate_supervisor/2` (`on_exit_handler.ex:59-70`, per ISSUE-FIXER's citation) uses
`Process.monitor/1` plus a blocking `receive {:DOWN, ...}`, so there is no
check-then-act window in *that* teardown path at all, by construction, independent of
timing.

**What (d) would cost:** `start_supervised!/2` starts the child spec under
`ExUnit.fetch_test_supervisor/0` — a supervisor process owned by the ExUnit framework,
not one this test creates or can name. It returns only the started child's pid. This
test's whole reason for existing is to prove `service_task_dispatcher_children/0`'s spec
is independently startable **under a throwaway supervisor this test owns**, and that
claim is currently discharged by `Supervisor.which_children(sup_pid)` asserting the
exact `{Letflow.Engine.ServiceTaskDispatcher.Poller, pid, :worker, _modules}` shape.
Adopting (d) verbatim removes the only supervisor handle this assertion needs — there
would be no `sup_pid` to call `which_children/1` on. Discharging (d) here requires
either (i) dropping the `which_children/1` assertion, which weakens this test from
proving "independently startable under a throwaway supervisor" down to merely "startable
by *some* means," directly undercutting the test's own stated purpose stated in its own
name and inline comment (lines 1113-1121), or (ii) inventing a second, unprecedented
construction — a manually-owned supervisor wrapping a `start_supervised!`-style
registration — that has no existing shape anywhere in this codebase and would need its
own design scrutiny.

**Why (a) is sufficient, not merely convenient:** ISSUE-FIXER's Step 1 diagnosis
empirically verified (§(2)(a) of that handoff), against real ExUnit 1.20.3 source, that
with no `on_exit` callback at all a named supervisor plus its named child receive a clean
`{:DOWN, ..., :shutdown}` from pure link-propagated teardown once the test process calls
`exit(:shutdown)` — 100% clean across the probe. This is not a timing-dependent
mitigation; it removes the second actor (the `on_exit` callback process) that the race
depended on entirely. Once the callback does not exist, there is no code left anywhere
that performs a check-then-act on `sup_pid` — not "less likely to race," structurally
**no race exists to have**, because a race requires two independent, unordered actors and
this leaves only one (the link-exit signal itself, which is a single unconditional event,
not a check followed by a conditional action).

**Verdict:** (a) achieves full structural safety — the property CHECK 6 below requires —
with a strictly smaller diff, no restructuring of the `which_children/1` assertion, and
no new pattern introduced into the suite. (d)'s structural-immunity mechanism is real and
stronger in the abstract, but it is not available to this test without weakening the
exact assertion the test exists to make. Given (a) already reaches "no race exists," the
marginal safety (d) would add is zero for this specific test, while its assertion cost is
non-zero. (a) wins outright, not by a narrow margin — this is not a coin flip between two
equally good options; it is a case where the theoretically-stronger mechanism cannot be
applied here without paying a coverage cost, and the theoretically-weaker-on-paper
mechanism turns out to be exactly as strong once you check what it actually removes.

### 1.2 What is explicitly given up by choosing (a)

State plainly, per the task's instruction not to hedge:

- **No fixture-level teardown of `sup_pid` remains in this test's own code.** Cleanup of
  the throwaway supervisor and its child becomes entirely implicit, driven by the
  supervisor's link to the test process (created by `Supervisor.start_link/2`, which
  links the caller) and ExUnit's own per-test process lifecycle. If a future edit to this
  test changes `Supervisor.start_link/2` to `Supervisor.start/2` (no link) or moves the
  `start_link` call into a helper process that outlives the test process, this implicit
  cleanup silently stops working and nothing in the test will detect it structurally —
  see Open Question 2 below for the mitigation TEST-DESIGNER should add.
- **No explicit assertion that the supervisor was successfully torn down.** The current
  `on_exit` never asserted this either (it discarded `Supervisor.stop/1`'s return value
  and only guarded whether to call it at all), so this is not a loss of an existing
  assertion — but it forecloses ever adding one at this exact point without reintroducing
  a form of the same hazard (any explicit post-hoc check of `sup_pid`'s liveness from a
  process other than the one whose exit drives the teardown re-creates a check-then-act
  window). This is accepted as a property of process-linked teardown generally, not
  specific to this fix.

### 1.3 Options (b) and (c): re-affirming ISSUE-FIXER's rejection, independently derived

Re-examined per the task's instruction to justify departing from (or affirming) (a)
rather than taking ISSUE-FIXER's recommendation on faith:

- **(b) race-tolerant explicit stop** (wrap `Supervisor.stop/1` in `try/catch :exit`,
  treat `:noproc`/`:shutdown` as success) does not remove the race, it silences its
  crash. The callback still performs a check-then-act with no synchronization; the
  three possible orderings ISSUE-FIXER identified (callback runs before / during / after
  the link-exit signal reaches `sup_pid`) still all occur, this option just makes two of
  the three orderings ("during," "after") not raise. That is strictly weaker than (a),
  which removes the second actor so there is no ordering to reason about at all. Also:
  confirmed independently (grep, matching Step 00's own finding) that `Supervisor.stop/1`
  appears nowhere else in `test/`, so adopting (b) would establish a brand-new
  try/catch-around-teardown idiom with zero in-suite precedent to justify its shape.
- **(c) unlinked/test-owned supervisor** (start_link then `Process.unlink/1`, or a
  supervised start under a test-owned supervisor) removes the automatic link-driven
  cleanup this test currently benefits from "for free," which means an explicit stop
  becomes **mandatory**, not optional — an unlinked `sup_pid` will never die on its own
  when the test process exits. That reintroduces exactly the explicit-stop step whose
  failure mode caused ISS-0446, unless that stop is itself written race-tolerant (i.e.,
  (c) collapses into (b)'s ceremony, with more code and a new manual-unlink idiom on top,
  for no additional safety over (a)).

Neither adds a capability (a) lacks; both add unprecedented ceremony. Confirmed rather
than assumed.

---

## 2. CHECK 6 (`docs/agents/ORCHESTRATOR.md` §10): does this change alter behaviour any
test asserts? — settled against the real file

This is the check ISSUE-FIXER flagged as unresolved at sufficient evidentiary weight
(its own probe was against a throwaway analog script, not the real shipped file). Settled
here directly against `test/letflow/engine/service_task_dispatcher_test.exs`:

**2.1 Does anything in this test's own body depend on the `on_exit` block?**
No. Read in full (lines 1113-1141): the test's assertions are
`assert [{Letflow.Engine.ServiceTaskDispatcher.Poller, pid, :worker, _modules}] = children`,
`assert is_pid(pid)`, `assert Process.alive?(pid)`, and
`assert pid != Process.whereis(Letflow.Scheduler.Poller)` — all four execute and complete
**before** `on_exit` is ever invoked (ExUnit registers `on_exit` callbacks to run after
the test body returns, per `on_exit_handler.ex`/`runner.ex` as cited in ISSUE-FIXER's
diagnosis). None of the four reads `sup_pid`'s liveness after the point the `on_exit`
block would have run. Removing the block cannot change any of these four assertions'
outcomes.

**2.2 Does anything else in this file depend on this test's teardown, ordering, or the
`__MODULE__.ThrowawaySupervisor` name?**
Checked directly (not inherited from ISSUE-FIXER's or Step 00's grep, independently
re-run against the current file):
- `grep -n "ThrowawaySupervisor" test/letflow/engine/service_task_dispatcher_test.exs`
  returns exactly one line: 1128, the `name:` option inside this test's own
  `Supervisor.start_link/2` call. No other line in the file references this name.
- The test at line 1113 is the **last test in its `describe "boot gating"` block and the
  last test in the file** — confirmed by reading to the file's end (line 1143, the
  closing `end`s of the test, describe block, and module immediately follow line 1141).
  There is no subsequent test in this file that could observe leftover state from this
  one, by simple absence of a "subsequent" anything.
- `grep -n "^  describe\|^  test"` across the file lists 13 `describe` blocks; none but
  "boot gating" (the one containing this test) mentions supervisors, throwaway fixtures,
  or `Letflow.Scheduler.Poller`/`Letflow.Engine.ServiceTaskDispatcher.Poller` process
  identity in a way that could be order-sensitive to this test.

**2.3 Does anything elsewhere in the suite depend on this teardown, this name, or
ordering relative to this test?**
`grep -rn "ThrowawaySupervisor" test/` (whole test tree, not just this file) returns only
the same single line 1128 in this same file. No other file references this name. This
test module runs `async: false` (line 35, confirmed present) under `Letflow.DataCase`,
and per Step 00's own established fact, `async: false` here means no *intra-file*
concurrency is the concern — the relevant question is *inter-test-module* ordering,
which ISSUE-FIXER's diagnosis already established is serialized by ExUnit's own runner
(the next test does not start until the current test's full lifecycle, including
`exec_on_exit`, completes) — so even if another file happened to register a process under
some colliding name, this test's ordering relative to it is unaffected by whether this
specific `on_exit` block exists, because ExUnit's serialization guarantee is what
provides ordering, not this callback.

**Verdict on CHECK 6:** No test — in this file or elsewhere in the suite — asserts on,
depends on, or is ordered relative to this `on_exit` block, the `sup_pid` it guards, or
the `__MODULE__.ThrowawaySupervisor` name, beyond the test's own four assertions which
all complete before the callback would run regardless of whether it exists. Dropping the
block alters no asserted behaviour anywhere in the suite. CHECK 6 is answered: **no**,
this change does not alter behaviour any test asserts.

---

## 3. What ELIXIR-DEV does (specification, not implementation)

1. In `test/letflow/engine/service_task_dispatcher_test.exs`, remove the `on_exit/1` call
   spanning the current lines 1131-1133 (the block reading
   `on_exit(fn -> if Process.alive?(sup_pid), do: Supervisor.stop(sup_pid) end)`).
2. Do not rename `sup_pid` — it is still bound and still used at line 1135
   (`Supervisor.which_children(sup_pid)`); only the `on_exit` call is removed, not the
   `{:ok, sup_pid} = Supervisor.start_link(...)` binding above it.
3. Do not touch the `which_children/1` assertion, the `Process.alive?(pid)` assertion, or
   the `pid != Process.whereis(Letflow.Scheduler.Poller)` assertion — all three are
   retained verbatim, per §1's decision.
4. No production code (`lib/`) changes. No migration. No other test file changes.
5. Add a one-line comment in place of the removed block explaining *why* no explicit
   teardown exists, so a future reader does not "helpfully" re-add the same race. Content
   ELIXIR-DEV should express (design intent, not literal wording mandated): the
   supervisor is `start_link`ed from this test process, so it is linked and torn down by
   ExUnit's own test-process exit; an explicit `Process.alive?`-then-`Supervisor.stop`
   guard here previously raced the same link-exit signal (ISS-0446) and was removed
   rather than made race-tolerant, since removing the second actor removes the race
   rather than narrowing its window.

---

## 4. Verification: what counts as evidence for a fix to a race that cannot be reliably
reproduced on demand

The task is explicit that a green rerun proves nothing (3192/3192 passed locally on the
very run that observed the CI failure), and that this design's safety argument must not
rest on a green run. It does not. §1.1's argument is structural: it identifies that a
race requires two independent, unordered actors (the exiting test process driving the
link signal, and the `on_exit` callback process performing the check-then-act), and shows
that removing the second actor removes the race by construction, not by narrowing its
timing window. That argument does not need a test run to be true, and is not
strengthened by one. Evidence obligations therefore split cleanly by what each kind of
run can and cannot show:

**4.1 What a normal (quiet, unloaded) local run can show, and its limit.** Running
`mix test test/letflow/engine/service_task_dispatcher_test.exs` after the edit and
observing the file's tests pass (expected: same 42 tests as ISSUE-FIXER's Step 00
baseline, still passing) shows the change did not break the test's own assertions — i.e.,
confirms §2's CHECK 6 conclusion empirically, not just by argument. It does **not** and
cannot demonstrate the race is gone, because the race did not reliably reproduce even
pre-fix under quiet local conditions (3192/3192 passed on the reporting run). A green run
here is necessary (it would be a genuine regression signal if it went red) but is not the
load-bearing evidence for "the race is fixed."

**4.2 What would constitute real evidence the race is fixed — the widened-timing analog,
per ISSUE-FIXER's own forward-recommendation.** ISSUE-FIXER's diagnosis (§(2)(a) and §(4)
of its handoff) already produced and empirically validated a technique for this exact
situation: a **scratch/throwaway probe script** (not committed to `test/`) that starts a
`Supervisor` whose child's `terminate/2` does measurable work (e.g. `Process.sleep(5)`),
which widens the link-teardown window enough to reproduce the CI failure's exact shape
deterministically (5/5 in ISSUE-FIXER's own run) *against the pre-fix code*. The
symmetric post-fix version of that same probe — same widened-timing child, but with the
`on_exit` block removed as this design specifies — passing cleanly across multiple runs
(ISSUE-FIXER's own precedent used 5/5 and 10/10 as its evidentiary bar) is the actual
regression proof: it exercises the exact timing condition CI's contended hardware
supplies, deliberately, on demand, rather than hoping ordinary local execution happens to
hit it. This is TEST-DESIGNER's Step 4 obligation, not ELIXIR-DEV's, per WF-03's normal
division of labor — flagged here so it is not lost between steps: **the fail-then-pass
proof for this fix must use a widened-timing analog of this shape, run against the
pre-fix and post-fix code respectively, because an ordinary run of the real (narrow-window)
test on either side of the fix is not informative** (it may pass on both sides, which
would be mistaken for "nothing to fix" rather than correctly read as "the window was
never forced open").
Do not commit this analog probe into `test/` as a permanent test — per ISSUE-FIXER's own
handling, it is a scratch verification artifact (`scratch/`, git-ignored, deleted after
use), not a new permanent test file, unless TEST-DESIGNER independently determines a
permanent widened-timing regression test is warranted, which is TEST-DESIGNER's call to
make and justify at Step 4, not decided here.

**4.3 What does NOT count as evidence, stated so TEST-RUNNER/RELEASE-VALIDATOR do not
mistake it for some:** repeated ordinary local runs of the real test file, however many
times green, do not demonstrate the race is fixed — the race's absence under quiet local
conditions was already true before the fix (that is precisely why it shipped and reached
CI before being caught). Nor does a single green CI run post-merge — CI is where the race
manifests *more* often, not deterministically, so one green CI run is consistent with
either "fixed" or "didn't happen to trigger this time." The only informative evidence is
§4.2's widened-timing analog run under both pre-fix and post-fix code, plus §1.1's
structural argument that the fix removes an actor rather than narrows a window.

---

## 5. Acceptance-criteria mapping

ISS-0446 is a MINOR bug-fix issue, not a `docs/requirements.yaml` REQ entry, so it
carries no formal `acceptance_criteria` list — its "SCOPE" section enumerates options
(a)/(b)/(c) and its body implicitly requires: the race is removed, no coverage is lost,
and the decision is justified. Mapped explicitly:

| Implicit requirement | Design element |
|---|---|
| Root cause verified, not assumed | §0 (via ISSUE-FIXER's cited source lines, independently spot-checked in §2) |
| One option chosen and justified against alternatives, including (d) | §1.1, §1.3 |
| What is given up stated plainly | §1.2 |
| CHECK 6 (behaviour-alteration) settled against the real file | §2 |
| Concrete instructions for ELIXIR-DEV | §3 |
| Verification strategy for a non-reproducible race | §4 |
| No implementation code in this design | This document contains no `.ex`/`.exs` code blocks — verified by inspection: all code-shaped text above is prose description or fenced only as inline text, no `elixir`/`ex` fenced code blocks appear in this file. |

---

## 6. Open questions (not silently resolved)

1. **Should a permanent widened-timing regression test be added to the suite**, so this
   race class is guarded going forward rather than only verified once at fix time? This
   design does not resolve it — TEST-DESIGNER should decide at Step 4 whether the value
   of a permanent CI-reproducible-race test (this would be a novel pattern in this suite;
   no existing test deliberately widens a termination timing window) outweighs the
   maintenance cost and runtime cost (a deliberate `Process.sleep` in a supervised
   child's `terminate/2`) of carrying it permanently.
2. **No structural guard exists against a future edit silently reintroducing the same
   hazard** (e.g., someone adds an explicit teardown assertion back, or changes
   `start_link` to an unlinked start without re-deriving §1.1's reasoning). This design
   does not propose a lint rule or code comment enforcement mechanism beyond the
   explanatory comment specified in §3 step 5 — flagged as accepted residual risk, not
   engineered around, since building an automated guard for this narrow a pattern was
   judged (not verified) to be disproportionate to a single three-line deletion. If a
   reviewer disagrees, that is a legitimate REVIEWER-stage escalation, not a silent
   design gap.
