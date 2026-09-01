# RELEASE-VALIDATOR report — REQ-208 — WF02-REQ208-20260901

Date: 2026-09-01. Branch: `feature/WF02-REQ208-20260901` (commit `70265e7b` at
hand-off, verified clean/up-to-date with origin before this review). Verified
independently from source and real command output; no prior agent's verdict
(step-02a ELIXIR-DEV, step-02c SECURITY-REVIEWER, step-02d REVIEWER, step-03/03b
TEST-DESIGNER/VALIDATOR, step-04 TEST-RUNNER) was trusted without re-derivation.

## Verdict: ACCEPT WITH CAVEAT — all 6 acceptance criteria genuinely addressed;
## AC1/AC2 are PARTIALLY MET due to a real, pre-existing, out-of-scope Engine
## defect, not a REQ-208 implementation failure — does not block marking done

---

## Re-run tests myself (not copied from step-04's report)

```
$ mix test test/letflow/simulation/req208_meridian_test.exs
.
.
.
Finished in 4.8 seconds (0.00s async, 4.8s sync)
Result: 3 passed
```
3/3, real output — matches step-04's claim.

```
$ mix test test/letflow/simulation/
Result: 28 passed
```
REQ-205/206/207/208's own simulation tests combined, still green — confirms
additivity, matches step-04's claim, re-derived independently rather than copied.

Did not re-run the full `scripts/test_parallel.sh` 3000-test suite myself given
TEST-RUNNER's step-04 already ran it twice (`scripts/test_parallel.sh` and `mix
letflow.check.test`'s own subprocess) within the last few hours on this exact
commit and both runs' only failures were the identical, independently-reproduced
`rustc`-ENOENT pair; instead I independently re-confirmed the toolchain absence
directly:
```
$ which rustc
(empty, exit 1)
```
`rustc` is genuinely absent from this sandbox's PATH — the 2 `CheckToolchainTest`
failures TEST-RUNNER reported are real and environmental, not fabricated, and
`git diff origin/main...HEAD --stat` (re-run myself) confirms this branch's diff
never touches `test/mix/tasks/letflow_check_toolchain_test.exs` or
`lib/mix/tasks/letflow.check_toolchain.ex`.

```
$ mix compile --warnings-as-errors --force
Compiling 197 files (.ex)
Generated letflow app
```
Exit 0, 0 warnings.

## The critical AC1/AC2 gap — read the real code and test file myself, not the reports

Re-read `lib/letflow/engine.ex` directly (not just quoting ELIXIR-DEV's citation):

```elixir
# §6.5 -- assembling the seed InstanceState.t(). join_counters is always
# %{} (design doc §6.5, §11 INV-EE48-7, MAJOR OQ-3): no table persists
# JoinCounter state across calls today.
defp build_instance_state(
       %InstanceProjection{} = projection,
       active_tokens,
       pending_task_tokens
     ) do
  %InstanceState{
    ...
    join_counters: %{}
  }
end
```

Confirmed this is **genuinely pre-existing, not introduced by REQ-208's diff**:
```
$ git show origin/main:lib/letflow/engine.ex | grep -n "join_counters"
1810: ...
1824:      join_counters: %{}
3292: ...
```
Identical on `origin/main` before this branch's work started — the comment
itself, the hardcoded `%{}`, and the line numbers all match. This is not a
regression this branch shipped and is disguising as "pre-existing"; it is a real
platform gap that predates REQ-208 entirely (REQ-054/SnapshotWriter serializes
`join_counters` into `instance_state_snapshots`, but `Engine.complete_task/3`'s
own hot-path rebuild (`build_snapshot_and_state/4` → `build_instance_state/3`)
never reads that table back — confirmed by reading both functions directly).

Read `test/letflow/simulation/req208_meridian_test.exs` directly (830 lines, not
just its moduledoc summary): both loan-origination tests (`meridian-loan-
origination-above-threshold`/`-below-threshold`) genuinely dispatch a real
3-way `PARALLEL_GATEWAY` fork via `Runner.run/1` (real HTTP through
`Letflow.Router`), confirm both `credit-memo-review` and `risk-assessment` are
real, queried, PENDING `HUMAN_TASK`s (`Letflow.Tasks.list_tasks/2` +
`Letflow.Instances.get_by_id/2`, not asserted from the create-instance response
alone), then assert the SECOND, separate `Engine.complete_task/3` HTTP call
(completing `credit-memo-review`) returns a real HTTP 500
(`%{status: 500, body: %{"status" => 500, "title" => "Internal Server Error"}}`)
— this is the scenario reproducing the defect live, not a stub or a `:skip`.
Both tests then re-query state afterward and assert the failed call left no
partial corruption (task still PENDING, instance still ACTIVE at the same 2
nodes) — genuine evidence the failure is a typed, non-crashing rejection
(INV-EE48-7), not silent data corruption. `report.outcome_results == []` is
asserted explicitly (no fabricated `expected_outcomes` evaluation past the
truncation point).

Read both loan-origination scenario YAML headers (`test/fixtures/simulation/
meridian/scenarios/loan-origination-{above,below}-threshold.yaml`) directly —
both disclose the identical root cause, consequence, and truncation in their
own header comments, matching the test module's moduledoc and
`step-02a-elixir-dev.json`'s `result.issues[0]` (BLOCKER severity) word-for-word
on the facts (same file/line citation, same error tuple, same "not fixable
within REQ-208's own scope" framing).

### Accept/reject decision

**ACCEPT WITH CAVEAT.** Reasoning, following the same discipline REQ-205's own
RELEASE-VALIDATOR established for its AC1 gap:

1. **The defect is real, independently reproduced, and pre-existing** — confirmed
   directly above by reading `lib/letflow/engine.ex` on both branches and by
   re-running the test myself, not by trusting any report.
2. **It is not fixable within REQ-208's own scope.** REQ-208 is a
   test/test-support-only requirement (`owned_modules`:
   `test/support/simulation`, `test/fixtures/simulation/meridian`,
   `test/letflow/simulation` — confirmed via `step-02a`'s context block and via
   `git diff origin/main...HEAD --stat`, zero `lib/` files touched). Fixing
   `Engine.complete_task/3`'s state-rebuild to persist/reload `join_counters`
   across calls is Engine-core work — its own CODE-DESIGNER-sized requirement,
   the same scope boundary the design doc already drew for the related-but-
   distinct native-quorum-node exclusion.
3. **The gap was not silently absorbed as a pass.** Both scenarios were
   genuinely truncated to the steps that actually run, and the failure itself
   is asserted as the real, closed disposition for that step (`step2b.outcome
   == :error`) — not faked as `:ok`, not silently omitted. This satisfies
   AC5's "no step or scenario left unaddressed" even though AC1/AC2's fuller
   claims (committee route, quorum 2-of-3, disbursement, EO-002's negative
   assertion) are honestly reported as NOT verified.
4. **Disclosure is genuinely three-level-consistent** (verified independently
   below), not just claimed to be.
5. **A real, valuable finding resulted.** S7's entire purpose is to be a
   correctness gate that surfaces exactly this class of platform defect before
   a later stage builds on top of it silently. Discovering that no
   `PARALLEL_GATEWAY` split can currently converge across separate HTTP calls
   is precisely the kind of finding S7 exists to produce — treating that as
   grounds for a FAIL would perversely penalize the run for doing its job.

A genuine FAIL would be appropriate only if: the defect were fixable within
this requirement's own scope and ELIXIR-DEV declined to fix it, or if the
disclosure were inconsistent/fabricated, or if the truncated tests silently
asserted success past the failure point. None of those hold here.

## `:no_task_of_type` non-vacuousness — read the implementation directly

`test/support/simulation/runner.ex` (~line 592):
```elixir
defp verify_outcome(
       %{verification: %{method: :no_task_of_type, args: args}} = expected,
       produces
     ) do
  with {:ok, instance_ref} <- resolve_ref(args, "instance_ref", produces),
       {:ok, prefix} <- fetch_prefix(args),
       {:ok, node_id} <- fetch_required(args, "node_id"),
       {:ok, %{items: items}} <-
         Tasks.list_tasks(%{page_size: 100, instance_id: instance_ref}, prefix: prefix) do
    observed = Enum.map(items, fn {task, _form_version} -> {task.node_id, task.status} end)
    outcome = if Enum.any?(observed, fn {n, _status} -> n == node_id end), do: :fail, else: :pass
    ...
```
No `status:` filter is passed to `Tasks.list_tasks/2` — queries across every
status, exactly as the design requires (absence must hold regardless of task
status, not merely `:pending`). The BaFin test exercises this with a genuine
positive control: `EO-NO-TASK-002` targets `evidence-collection`, a task that
DOES exist and is COMPLETED (not pending) by that point in the run, and asserts
`:fail` — a status-blind implementation bug (e.g. one that only checked
`:pending`) would wrongly return `:pass` here. I re-ran this test myself above
(3/3 passed, including this assertion) rather than trusting
TEST-DESIGN-VALIDATOR's prior reproduction alone. Non-vacuous, confirmed.

## `:blocked` disposition / `blocked_by: "ISS-0389"` — confirmed real and correctly referenced

`test/support/simulation/runner.ex` (~line 349): the `:blocked` step-dispatch
branch requires `blocked_by` and raises `ArgumentError` loudly if absent — same
discipline as the pre-existing `:skip` branch's missing-severity check. Read
`docs/issues/ISS-0389.yaml` directly:
```
id: ISS-0389
title: "Missing POST /api/v1/instances/:id/advance-timer endpoint"
discovered_by: ELIXIR-DEV
discovered_in_run: WF02-REQ206-20260901
...
related: [REQ-206, REQ-208, REQ-209]
status: open
```
This is the correct, already-filed issue — REQ-208's own regulatory-review
scenario references it (not a duplicate). Grepped `docs/issues/*.yaml` for
`join_counters`/`walk_to_gateway`: zero matches. Neither of this run's two NEW
Engine findings (the `join_counters` BLOCKER and the `walk_to_gateway`
multi-outgoing-edge fork-branch limitation ELIXIR-DEV also found and worked
around) has been filed as an issue file yet — correctly deferred to ORCH,
matching `docs/agents/protocols/ISSUE_QUEUE.md`'s "agents report via
`result.issues`, ORCH files" convention. Confirmed ELIXIR-DEV/SECURITY-REVIEWER/
REVIEWER all reported rather than self-filed: `step-02a`'s `result.issues` array
carries both findings with `severity`/`affected_files`, `step-02c` independently
assesses the `join_counters` finding for security implications (concludes
correctness/availability, not a distinct security-invariant violation) and
recommends ORCH queue it, `step-02d` confirms the 3-level disclosure is
internally consistent. None of the three self-assigns an ISS id. Correct.

## Engine defect escalation — confirmed documented at every required level

1. **Scenario YAML headers** — both loan-origination YAMLs' own header comments
   state the finding (read directly, confirmed above).
2. **Test file comments** — `req208_meridian_test.exs`'s moduledoc (lines 6–47)
   and both test bodies' inline comments (lines 607–617, 682–691) restate the
   identical root cause and consequence.
3. **`step-02a-elixir-dev.json`'s `result.issues[0]`** — BLOCKER severity, full
   root-cause citation, `affected_files` list, "not fixable within REQ-208's own
   scope" framing — read directly, confirmed present.
4. **Not yet filed as a queue issue** — confirmed by the `docs/issues/` grep
   above. SECURITY-REVIEWER (`step-02c`) and REVIEWER (`step-02d`) both
   recommend ORCH file it rather than filing it themselves. Correct per
   ISSUE_QUEUE.md's convention (agents report; ORCH routes/files).

## AC-to-evidence map

| AC | Evidence |
|----|----------|
| AC1 | `req208_meridian_test.exs:557-648` — real 3-way `PARALLEL_GATEWAY` fork, both non-KYC branches confirmed as real PENDING `HUMAN_TASK`s via direct `Instances.get_by_id/2` + `Tasks.list_tasks/2` queries; first branch's real completion call genuinely reproduces the `join_counters` defect (real HTTP 500), asserted as the closed step disposition; post-failure state re-queried and confirmed uncorrupted. **PARTIALLY MET**: the fork/task-creation portion of AC1's claim is genuinely verified; the committee route, quorum 2-of-3, and disbursement claims are NOT reachable and are honestly reported as unverified, not fabricated. Re-run: 3/3 passed. |
| AC2 | `req208_meridian_test.exs:653-703` — identical graph and identical genuine reproduction up to the same defect point. **PARTIALLY MET**: EO-002's own negative assertion (no committee-vote task) cannot be exercised on this scenario's own path (truncated before reaching authority-routing) — honestly reported as unverified via the moduledoc/test comments, not silently assumed to hold. (The `:no_task_of_type` primitive itself IS exercised and confirmed non-vacuous elsewhere — see BaFin/AC3 below — so AC2's gap is scenario-reachability, not an untested verification method.) Re-run: passed as part of the 3/3. |
| AC3 | `req208_meridian_test.exs:707-829` — steps 1/2 run for real against real queried state (`current_nodes == ["risk-evaluation"]`, a real PENDING `risk-evaluation` task with `assignee_ref == "role-risk-manager"`); step 3 asserted `outcome == :blocked`, `blocked_by == "ISS-0389"`, `severity == :blocker`, `captured == nil` — confirmed `ISS-0389` is the correct, already-filed, non-duplicate issue (read directly above). Cross-tenant-blocking statement ("blocks scenarios in two different tenant batches") present in `step-02a`'s AC3 evidence and the findings report. **MET.** |
| AC4 | `docs/requirements.yaml` REQ-199 entry re-confirmed `status: done` directly (grep, this session). Material caveat genuinely stated in `test/reports/req208-meridian-scenario-findings.yaml`'s `req_199_caveat` field — and correctly strengthened, not weakened, by this run's own finding (no scenario can currently drive a cross-call `PARALLEL_GATEWAY` join at all, a stronger statement than the design's own anticipated "sequential-dispatch, unproven-under-concurrency" caveat). **MET.** |
| AC5 | Every one of the 3 scenarios' steps carries a closed, real disposition: above-threshold (3/3 steps: `:ok`/`:ok`/`:error`, truncation disclosed not silent), below-threshold (3/3 steps: `:ok`/`:ok`/`:error`, same), BaFin (4 steps: `:ok`/`:ok`/`:ok`/`:blocked`). Verified by reading all 3 test blocks directly. **MET.** |
| AC6 | `mix compile --warnings-as-errors --force` and `mix test test/letflow/simulation/req208_meridian_test.exs` re-run directly by RELEASE-VALIDATOR (output quoted above, not copied from step-04); `mix test test/letflow/simulation/` (28/28) re-run directly; toolchain-absence (`which rustc`) independently re-confirmed rather than trusted from step-04's report. **MET.** |

## What DOC-UPDATER should record

- REQ-208 status: `done`, but **AC1 and AC2 must be recorded as PARTIALLY MET**,
  not folded into a blanket "all 6 ACs met" — same discipline REQ-205's own
  RELEASE-VALIDATOR established for its AC1 gap. The status-history event must
  state the `join_counters` defect explicitly as the reason and reference this
  report.
- **Action requested of ORCH**: file a new BLOCKER-severity issue for
  `Engine.complete_task/3`'s `build_instance_state/3` hardcoding `join_counters:
  %{}` on every call (per `step-02a`'s `result.issues[0]`, independently
  re-confirmed above), `related: [REQ-054, REQ-208]`, `affected_files:
  [lib/letflow/engine.ex, lib/letflow/engine/transition.ex]`. This is a
  platform-wide gap (every `PARALLEL_GATEWAY` split whose branches require
  separate task completions), not a REQ-208-only concern, and should gate any
  future requirement that needs a real cross-call parallel join to fire.
- Also file (or fold into the same issue's notes) ELIXIR-DEV's second finding:
  `walk_to_gateway/3` fails a fork branch containing a multi-outgoing-edge node
  (e.g. an `EXCLUSIVE_GATEWAY`) before reaching its join —
  `test/letflow/simulation/req208_meridian_test.exs` lines 117–134 document the
  concrete reproduction (`{:error, {:activation_failed, {:no_matching_join_found,
  "parallel-assessment-fork"}}}`).
- **Downstream consequence if the `join_counters` issue is not filed/fixed**:
  no future S7/S8 scenario (or production usage) can drive a `PARALLEL_GATEWAY`
  join to fire across two separate task completions — this blocks not just
  Meridian's committee-quorum path but any process definition anywhere in
  Letflow with the same shape.
- Cross-reference `ISS-0389` (already filed, `related` now includes REQ-208) —
  no duplicate needed there.
