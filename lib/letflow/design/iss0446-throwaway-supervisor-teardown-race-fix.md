# ISS-0446: throwaway-supervisor `on_exit` check-then-act teardown race — fix design

**Author:** CODE-DESIGNER, run WF03-ISS0446-20260904, Step 2 (rework 1 of 3)
**Input:** `docs/issues/ISS-0446.yaml`, ISSUE-FIXER's Step 1 diagnosis
(`handoffs/WF03-ISS0446-20260904/step-01-issue-fixer-diagnosis.json`), and
CODE-DESIGN-VALIDATOR's Step 2b FAIL verdict
(`handoffs/WF03-ISS0446-20260904/step-02b-code-design-validator.json`), which found a
BLOCKER false premise in the original §1.1. See §0 below for the correction.
**Target file:** `test/letflow/engine/service_task_dispatcher_test.exs`, test at line 1113
("`service_task_dispatcher_children/0`'s child spec is independently startable as a
real GenServer under a throwaway supervisor"), specifically lines 1123-1141.

No production module is touched. No new public function, schema, or migration. This
document is scoped to a single test's fixture-teardown shape, per this role's mandate
that a design artefact exists even for a test-only WF-03 fix (`docs/agents/instructions/core-directives.md`'s
"File Placement Rules": design artefacts live in `lib/letflow/design/` regardless of
whether the change touches `lib/`).

---

## 0. Rework note: the corrected premise, and how the decision changed

The original (rework-0) version of this document rejected option (d)
(`start_supervised!/1`) on the claim that it "returns only the started child's pid" with
"no `sup_pid` to call `Supervisor.which_children/1` on." **That premise was false**, and
CODE-DESIGN-VALIDATOR was right to block on it. Independently re-verified here, not taken
on the validator's word or ISSUE-FIXER's:

- Read `/c/Program Files/Elixir/lib/ex_unit/lib/ex_unit.ex` directly: `fetch_test_supervisor/0`
  is public, `@doc since: "1.11.0"`, `@spec fetch_test_supervisor() :: {:ok, pid()} | :error`,
  and its body returns the pid of the same supervisor `ExUnit.Callbacks.start_supervised/2`
  registers children under (confirmed by reading `callbacks.ex:568-580`:
  `start_supervised/2` itself calls `ExUnit.fetch_test_supervisor()` to obtain `sup`, then
  `Supervisor.start_child(sup, child_spec)`).
- Read `/c/Program Files/Elixir/lib/ex_unit/lib/ex_unit/on_exit_handler.ex:59-70`: the
  framework's own teardown of that supervisor (`terminate_supervisor/2`) is
  `ref = Process.monitor(sup)` followed by a blocking `receive do {:DOWN, ^ref, _, _, _} -> nil after timeout -> ... end`
  — a monitor-and-wait, with **no `Process.alive?` check anywhere in that path**. This is
  the structural-immunity mechanism ISSUE-FIXER originally cited; independently confirmed
  present, verbatim, at those line numbers.
- Ran my own empirical probe (not reused from the validator's report), a throwaway ExUnit
  script (`scratch/iss0446_probe_d.exs`, deleted after use, `git status --porcelain
  scratch/` confirmed clean afterward) with a supervised `GenServer` child whose
  `terminate/2` sleeps 30ms (deliberately slow, to make any race-shaped false pass
  implausible):
  ```
  {:ok, sup} = ExUnit.fetch_test_supervisor()
  pid = ExUnit.Callbacks.start_supervised!({SlowChild, []})
  children = Supervisor.which_children(sup)
  assert [{SlowChild, ^pid, :worker, [SlowChild]}] = children
  ```
  Ran 5/5: passed every time, returning exactly the `{module, pid, :worker, modules}`
  4-tuple shape this test's own assertion already checks.

**Conclusion: the premise was false, and correcting it changes the decision.** Option (d),
refined to use `ExUnit.fetch_test_supervisor/0` for the `which_children/1` handle, gives
full assertion coverage AND the framework's structural monitor-based teardown, with a
diff no larger than option (a)'s. Re-running the comparison honestly (§1 below) rather
than defending the original pick: **(d) is adopted.** This is a reversal of the rework-0
decision, not a patch to its wording — §1 is rewritten in full below, and §1.2's
previously-accepted residual risk is retired, not merely reworded, because the mechanism
that produced that risk (link-hygiene-dependent implicit cleanup) is no longer part of
the design.

---

## 1. Decision: adopt option (d), refined — `ExUnit.fetch_test_supervisor/0` +
`start_supervised!/1`, replacing the ad-hoc throwaway supervisor entirely

**Change, stated as an intent-level diff (not code):**
1. Replace the `{:ok, sup_pid} = Supervisor.start_link([{Letflow.Engine.ServiceTaskDispatcher.Poller, []}], strategy: :one_for_one, name: __MODULE__.ThrowawaySupervisor)`
   call (lines 1124-1129) with two calls: `{:ok, sup} = ExUnit.fetch_test_supervisor()`,
   then `pid = ExUnit.Callbacks.start_supervised!({Letflow.Engine.ServiceTaskDispatcher.Poller, []})`.
2. Delete the `on_exit(fn -> if Process.alive?(sup_pid), do: Supervisor.stop(sup_pid) end)`
   block (lines 1131-1133) entirely — no replacement teardown code of any kind, since
   teardown is now the framework's responsibility via `terminate_supervisor/2`.
3. Replace `children = Supervisor.which_children(sup_pid)` (line 1135) with
   `children = Supervisor.which_children(sup)`, using the fetched supervisor pid instead
   of the deleted ad-hoc one.
4. All four assertions are retained verbatim: the `which_children/1` tuple-shape match,
   `is_pid(pid)`, `Process.alive?(pid)`, and `pid != Process.whereis(Letflow.Scheduler.Poller)`.
   `pid` now comes directly from `start_supervised!/1`'s return value rather than being
   destructured out of the `which_children/1` list first — full detail in §3.

This removes the `__MODULE__.ThrowawaySupervisor` name registration and the
`Supervisor.start_link/2` call entirely, not just the `on_exit` block — the ad-hoc
supervisor construction is replaced wholesale by ExUnit's own test-supervisor mechanism.

### 1.1 Why (d) and not (a) — re-run honestly against the corrected premise

**What (a) would buy:** the smallest possible diff against the *original* code (delete
three lines, touch nothing else), and a safety argument already independently confirmed
by both ISSUE-FIXER and CODE-DESIGN-VALIDATOR — including the validator's own adversarial
20-iteration probe (trap-exit child, 50ms `terminate/2` sleep, no `on_exit` at all): 20/20
clean teardown with no supervisor outliving the test process's exit signal. That
finding is not in question and is not being relitigated; it correctly shows (a) *would*
remove the race.

**What (a) would still leave, now that (d)'s real cost is known:** §1.2 of the rework-0
design accepted a residual risk under (a) — "no fixture-level teardown of `sup_pid`
remains... cleanup becomes entirely implicit, driven by the supervisor's link to the test
process... if a future edit to this test changes `Supervisor.start_link/2` to
`Supervisor.start/2` (no link)... this implicit cleanup silently stops working and
nothing in the test will detect it structurally." That risk is real under (a) and remains
real under (a) regardless of how well-verified the *current* code's safety is, because
it is a claim about future edits, not about the code as written today.

**What (d) costs, now correctly assessed:** nothing above (a)'s cost, on every axis this
design already uses to judge sufficiency:
- **Diff size:** equal or smaller. (a) deletes 3 lines and keeps the
  `Supervisor.start_link`/`name:` plumbing (5 lines) and the `which_children(sup_pid)`
  call. (d) deletes the `on_exit` block (3 lines) **and** the `Supervisor.start_link`/
  `name:` plumbing (replaced by two single-line calls to well-documented, versioned
  public ExUnit functions), and adjusts one line (`which_children(sup)` instead of
  `which_children(sup_pid)`). Net line count is comparable; complexity is lower, because
  two ExUnit-framework calls replace a hand-rolled supervisor construction plus a
  hand-rolled name.
- **Coverage:** identical. §0's probe (5/5) and the validator's own independent probe
  both confirm `Supervisor.which_children/1` on the fetched test supervisor returns the
  exact `{module, pid, :worker, modules}` shape this test already asserts. No assertion
  is weakened, dropped, or restructured beyond the mechanical `sup_pid` → `sup` rename in
  the `which_children/1` call target (§3 spells this out for ELIXIR-DEV).
- **Precedent:** `fetch_test_supervisor/0` and `start_supervised!/1` are not new or
  invented — they are existing, `since: 1.11.0`/`1.6.0` public ExUnit API, already used
  in this exact suite in spirit (`test/letflow/admission_test.exs:19`,
  `test/letflow/scheduler/poller_test.exs:148,400` already use
  `start_supervised!`/`start_supervised`, per ISSUE-FIXER's Step 1 citation, for the
  *underlying need* this test also has). Adopting (d) is *joining* an established
  in-suite pattern, not introducing a new one — reversing (a)'s earlier framing that (d)
  required "an unprecedented construction," which was itself downstream of the same false
  premise being corrected here.
- **Structural safety:** strictly stronger, not merely equal. (a)'s safety rests on the
  test's own `Supervisor.start_link/2` call remaining linked, forever, to a test process
  whose own exit is what drives teardown — a property of *this test's code as currently
  written*, which a future edit could quietly change (§1.2 of rework-0, now retired as a
  live risk under (d) — see §1.2 below). (d)'s safety rests on `terminate_supervisor/2`'s
  monitor-and-block teardown, which is **framework-guaranteed by construction for any
  code using `start_supervised!`**, independent of what this specific test's own code
  looks like — there is no supervisor-ownership pattern this test's future author could
  introduce that would defeat it, because the ad-hoc `Supervisor.start_link`/`name:` call
  this risk depended on no longer exists in the test at all.

**Verdict, stated without hedging:** (d) is strictly better than (a) on every axis this
design uses to judge sufficiency — equal-or-smaller diff, identical coverage, in-suite
precedent, and additionally removes a residual risk (a) could only accept, not eliminate.
There is no genuine tradeoff left once the premise is corrected; this is not "two
equivalent options, pick one," it is "one option turned out to dominate the other once
its real cost was measured instead of assumed." Adopted.

### 1.2 What is given up by choosing (d) — stated plainly, not silently dropped

Per the task's original instruction (still binding on rework) to state what is given up
rather than presenting (d) as a free win:

- **This test's supervisor is no longer named or independently addressable outside the
  test's own `sup`/`pid` bindings.** The original `__MODULE__.ThrowawaySupervisor` name
  is gone; nothing in the test or the wider suite referenced it besides the test's own
  `name:` option (confirmed in §2.2 below, re-verified against the current file), so this
  costs nothing observable, but it is a real removal of a symbol that existed before.
- **The test's supervisor is no longer exclusively owned by this test's own code path.**
  `ExUnit.fetch_test_supervisor/0` returns a supervisor the ExUnit framework itself
  manages and could in principle be shared with other `start_supervised!`/`start_supervised`
  calls within the *same* test process (this test makes only one such call, so this is
  inert here, but it is a real semantic difference from a bespoke, single-purpose
  supervisor). This does not weaken the test's own assertion (the `which_children/1` list
  returned is scoped to whatever this test itself started, confirmed by the probe
  returning exactly one entry), but it is a loss of the "this supervisor exists for
  nothing but this test" framing the original code had.
- **Residual risk retired, not merely reworded:** rework-0's §1.2 "Open Question 2"-style
  residual risk (a future edit silently breaking link-based cleanup) no longer applies
  under (d), because there is no ad-hoc `Supervisor.start_link/2` call left for such an
  edit to target. This is recorded as removed, not carried forward — see §6 (Open
  Questions), which drops the corresponding entry from rework-0.

### 1.3 Options (b) and (c): unchanged from rework-0, still correctly rejected

Re-confirmed, not re-derived from scratch, since neither of these was touched by the
validator's blocker and both remain applicable to comparing against a
`Supervisor.start_link`-based approach in the abstract — but they are now compared
against a decision (d) that no longer even uses `Supervisor.start_link/2`, which makes
their rejection more clear-cut, not less:

- **(b) race-tolerant explicit stop** (wrap `Supervisor.stop/1` in `try/catch :exit`,
  treating `:noproc`/`:shutdown` as success) silences the crash without removing the
  race's cause, and has zero in-suite precedent (`Supervisor.stop/1` appears nowhere else
  in `test/`, confirmed by grep in the original diagnosis and not re-contradicted here).
  Under (d) there is no `Supervisor.stop/1` call anywhere in this test at all, so (b) is
  not merely weaker than (d), it targets a call site (d) removes entirely.
- **(c) unlinked/test-owned supervisor** (start_link then `Process.unlink/1`) makes an
  explicit stop mandatory rather than optional, reintroducing the exact failure mode
  unless that stop is itself race-tolerant — collapsing into (b)'s ceremony. (d) achieves
  what (c) was reaching for (unambiguous ownership and teardown ordering) without any
  manual link/unlink bookkeeping, using the framework's own supervisor instead.

---

## 2. CHECK 6 (`docs/agents/ORCHESTRATOR.md` §10): does this change alter behaviour any
test asserts? — settled against the real file, re-derived for the (d)-shaped diff

Re-derived for the actual shape of change now proposed (not merely re-asserting rework-0's
conclusion, since the diff shape changed from "delete 3 lines" to "replace the supervisor
construction and delete the `on_exit` block"):

**2.1 Does anything in this test's own body depend on the removed constructs?**
Read in full again (lines 1113-1141): the test's four assertions are
`assert [{Letflow.Engine.ServiceTaskDispatcher.Poller, pid, :worker, _modules}] = children`,
`assert is_pid(pid)`, `assert Process.alive?(pid)`, and
`assert pid != Process.whereis(Letflow.Scheduler.Poller)`. None of these assert on the
supervisor's *name* (`__MODULE__.ThrowawaySupervisor` is never referenced inside an
assertion — it exists only as the `name:` option passed to `start_link`, purely for the
supervisor's own registration, not observed by any `assert`). None assert on the
supervisor being the caller's own `Supervisor.start_link/2` result specifically, as
opposed to a supervisor obtained by any other means — the assertions are entirely about
the **child** (`pid`) and the **shape of `which_children/1`'s return value**, both of
which §0's probe confirms are identical under (d). Therefore no assertion in this test
depends on any construct being removed.

**2.2 Does anything else in this file, or the wider suite, depend on the
`__MODULE__.ThrowawaySupervisor` name or this test's specific supervisor-construction
mechanism?**
Re-run directly against the current file and the whole tree (not inherited from rework-0
or the validator's report):
- `grep -n "ThrowawaySupervisor" test/letflow/engine/service_task_dispatcher_test.exs`
  → exactly one line, 1128 (the `name:` option itself). No assertion, no other test,
  references it.
- `grep -rn "ThrowawaySupervisor" test/` (whole tree) → the same single hit. No other
  file in the suite references this name.
- The test at line 1113 is confirmed the **last test in the file** (module closes
  immediately after line 1141; file is 1143 lines total) — no subsequent test in this
  file can observe any difference in how the supervisor was constructed.
- `grep -rn "fetch_test_supervisor" test/` → no existing hits before this change, i.e.
  this is a new call site, but per §1.1 it uses existing, versioned, already-precedented
  ExUnit API (`start_supervised!`/`start_supervised` are already used elsewhere in this
  suite; `fetch_test_supervisor/0` is the same underlying mechanism those calls use
  internally), not a novel external dependency.

**Verdict on CHECK 6, unchanged in conclusion though re-derived for the new diff shape:**
No test, in this file or the wider suite, asserts on, depends on, or is ordered relative
to the `__MODULE__.ThrowawaySupervisor` name, the `Supervisor.start_link/2` call, or the
removed `on_exit` block. Replacing the supervisor-construction mechanism and removing the
`on_exit` block alters no behaviour any test asserts.

---

## 3. What ELIXIR-DEV does (specification, not implementation)

1. In `test/letflow/engine/service_task_dispatcher_test.exs`, replace the block currently
   at lines 1124-1133 —
   ```
   {:ok, sup_pid} =
     Supervisor.start_link(
       [{Letflow.Engine.ServiceTaskDispatcher.Poller, []}],
       strategy: :one_for_one,
       name: __MODULE__.ThrowawaySupervisor
     )

   on_exit(fn ->
     if Process.alive?(sup_pid), do: Supervisor.stop(sup_pid)
   end)
   ```
   — with two calls: first `{:ok, sup} = ExUnit.fetch_test_supervisor()`, then
   `pid = ExUnit.Callbacks.start_supervised!({Letflow.Engine.ServiceTaskDispatcher.Poller, []})`
   (note: `ExUnit.Callbacks.start_supervised!/1` is auto-imported into every `ExUnit.Case`
   module as `start_supervised!/1`, so ELIXIR-DEV should use the bare `start_supervised!/1`
   call, matching the existing in-suite style at
   `test/letflow/admission_test.exs:19`/`test/letflow/scheduler/poller_test.exs:148,400`,
   rather than the fully qualified form — the fully-qualified form above is written out
   here only for unambiguous specification).
2. No `on_exit/1` call of any kind remains for this test. This is intentional per §1 —
   teardown is entirely the framework's responsibility via
   `ExUnit.OnExitHandler`'s existing `terminate_supervisor/2` path, which runs
   unconditionally for every test process that has a fetched test supervisor, with no
   opt-in required.
3. Replace `children = Supervisor.which_children(sup_pid)` (current line 1135) with
   `children = Supervisor.which_children(sup)`, using the `sup` binding from step 1.
4. `pid` is now already bound directly from `start_supervised!/1`'s return value (a bare
   pid, since `start_supervised!/1` "returns the PID on success," confirmed at
   `callbacks.ex`'s own `@spec start_supervised!(...) :: pid`) — it does **not** need to
   be re-derived from destructuring `children`. Retain the existing assertion order for
   minimal diff, but the assertion `assert [{Letflow.Engine.ServiceTaskDispatcher.Poller, pid, :worker, _modules}] = children`
   changes shape slightly: since `pid` is already bound from step 1's `start_supervised!/1`
   call, this line should use the **pin operator** to assert the *same* pid appears in
   `which_children/1`'s output, i.e.
   `assert [{Letflow.Engine.ServiceTaskDispatcher.Poller, ^pid, :worker, _modules}] = children`
   (pinning `^pid` rather than rebinding it), matching the shape §0's probe used and
   verified passes. This is the one assertion-line wording change this design requires,
   and it strengthens the assertion (it now confirms `which_children/1`'s pid is the
   *same* pid `start_supervised!/1` returned, rather than merely establishing some pid via
   destructuring) rather than weakening it.
5. The remaining two assertions, `assert is_pid(pid)` and `assert Process.alive?(pid)`,
   and `assert pid != Process.whereis(Letflow.Scheduler.Poller)`, are unchanged.
6. No production code (`lib/`) changes. No migration. No other test file changes.
7. No replacement comment is needed explaining "why no on_exit" (unlike rework-0's
   instruction for option (a)) — there is no ad-hoc supervisor-ownership pattern here for
   a future reader to be tempted to "helpfully" re-guard, since `start_supervised!/1` is
   the suite's own established idiom for exactly this need. Optionally, ELIXIR-DEV may
   update the test's own inline comment (currently lines 1114-1122, referencing "an
   isolated, throwaway Supervisor this test fully owns and tears down itself") to reflect
   that teardown is now via ExUnit's own test-supervisor mechanism rather than a bespoke
   one — recommended for accuracy but not required for correctness, since the comment is
   documentation, not assertable behaviour, and is therefore outside this design's
   in-scope diff per §1's decision statement. Left to ELIXIR-DEV's judgement.

---

## 4. Verification: what counts as evidence for a fix to a race that cannot be reliably
reproduced on demand

Unchanged in method from rework-0 (CODE-DESIGN-VALIDATOR's Item 5 found this section
"provisionally sound" and asked only that it be restated for the new fixture shape, which
this section now does):

**4.1 What a normal (quiet, unloaded) local run can show, and its limit.** Running
`mix test test/letflow/engine/service_task_dispatcher_test.exs` after the edit and
observing the same ~42 tests in the file pass (per ISSUE-FIXER's Step 00 baseline) shows
the change did not break this test's own assertions — confirms §2's CHECK 6 conclusion
empirically. It does **not** demonstrate the race is gone, because the race did not
reliably reproduce even pre-fix under quiet local conditions (3192/3192 passed on the
reporting run). Necessary, not sufficient.

**4.2 What would constitute real evidence the race is fixed — restated for the (d)-shaped
fixture.** The widened-timing-analog technique ISSUE-FIXER validated (a supervised child
whose `terminate/2` does measurable work, e.g. `Process.sleep(5)` or more, widening the
teardown window enough to reproduce the CI failure's exact shape deterministically) still
applies, but the child is now registered via `start_supervised!/1` against a supervisor
obtained via `ExUnit.fetch_test_supervisor/0`, rather than via a bespoke
`Supervisor.start_link/2` call. §0's own probe (a `SlowChild` with a 30ms `terminate/2`,
registered exactly this way) is a direct instance of this same technique and already
confirms it transfers cleanly to the new fixture shape — the probe would have shown a
`{:shutdown, ...}`-style crash under the *old* on_exit-guarded pattern with a slow enough
child, and shows clean, silent teardown (no crash, no explicit code required) under the
new one. TEST-DESIGNER's Step 4 obligation is the same as rework-0 specified: construct a
pre-fix/post-fix pair using this widened-timing shape and confirm pre-fix reproduces a
failure (against the *original* `on_exit`-guarded code, with a slow enough child) while
post-fix passes cleanly across multiple runs (against the `start_supervised!`-based code
this design specifies) — not committed into `test/` as a permanent fixture unless
TEST-DESIGNER separately justifies one (§6, Open Question 1, unchanged from rework-0).

**4.3 What does NOT count as evidence — unchanged.** Repeated ordinary local runs of the
real test file, however many times green, do not demonstrate the race is fixed, since
the race's absence under quiet local conditions was already true before the fix. Nor does
a single green CI run post-merge. The only informative evidence is §4.2's widened-timing
analog run under both pre-fix and post-fix code, plus §1.1's structural argument
(`terminate_supervisor/2`'s monitor-and-block teardown has no `Process.alive?` check to
race in the first place).

---

## 5. Acceptance-criteria mapping

ISS-0446 is a MINOR bug-fix issue, not a `docs/requirements.yaml` REQ entry, so it
carries no formal `acceptance_criteria` list — its "SCOPE" section enumerates options
(a)/(b)/(c) (with (d) added by ORCH/ISSUE-FIXER) and its body implicitly requires: the
race is removed, no coverage is lost, and the decision is justified. Mapped explicitly,
updated for the rework:

| Implicit requirement | Design element |
|---|---|
| Root cause verified, not assumed | §0 (`fetch_test_supervisor/0`/`terminate_supervisor/2` re-verified against real source and a fresh empirical probe, independent of both prior agents' reports) |
| One option chosen and justified against alternatives, including (d), honestly re-examined after a corrected premise | §0, §1.1, §1.3 |
| What is given up stated plainly | §1.2 |
| CHECK 6 (behaviour-alteration) settled against the real file, re-derived for the new diff shape | §2 |
| Concrete instructions for ELIXIR-DEV | §3 |
| Verification strategy for a non-reproducible race | §4 |
| No implementation code in this design | This document contains no `.ex`/`.exs` **fenced code blocks** for the implementation itself; the two indented call/assertion snippets in §0 and §3 are quoted *specification text* (identical in kind to rework-0's approved practice of quoting the exact existing `on_exit` block to describe what is being removed/replaced), not code this design authors as a deliverable — they describe exactly what ELIXIR-DEV must write, in the same way §3 of rework-0 quoted the removed block verbatim. No function bodies, modules, or standalone implementation beyond call-shape specification appear anywhere in this file. |

---

## 6. Open questions (not silently resolved)

1. **Should a permanent widened-timing regression test be added to the suite**, so this
   race class is guarded going forward rather than only verified once at fix time?
   Unchanged from rework-0 — left to TEST-DESIGNER's Step 4 judgement, since this remains
   a novel pattern in this suite regardless of which option was chosen.
2. ~~Rework-0's Open Question 2 (no structural guard against a future edit silently
   reintroducing the same hazard by re-adding an explicit teardown or unlinking the
   supervisor) is RETIRED, not carried forward.~~ Per §1.1/§1.2, this risk was specific
   to option (a)'s reliance on the *test's own* `Supervisor.start_link/2` call staying
   linked — under (d) there is no such call left in the test for a future edit to
   silently break; teardown safety is now a property of ExUnit's own framework code,
   not of this test's code. Recorded here so a reader of the prior rework does not go
   looking for a mitigation to a risk that no longer exists under the adopted design.
3. **New, arising from adopting (d):** none identified. `ExUnit.fetch_test_supervisor/0`
   and `start_supervised!/1` are stable, versioned, already-used-in-spirit APIs in this
   suite; §0's probe found no surprising behavior. If ELIXIR-DEV encounters one while
   implementing (e.g. an interaction with `Letflow.DataCase`'s own sandbox setup this
   design did not anticipate), that is a new finding to report via the normal
   Unblock-Everything path, not evidence this design silently assumed something wrong —
   nothing in `Letflow.DataCase` was found (by inspection of this test module's `use`
   line and the surrounding file) to touch or override `ExUnit.fetch_test_supervisor/0`'s
   behavior.
