# TEST-DESIGN-VALIDATOR independent verification — ISS-0378

**Run:** WF03-ISS0378-20260830
**Verdict:** PASS — confirms TEST-DESIGNER's (and ISSUE-FIXER/CODE-DESIGN-VALIDATOR/
REVIEWER's) conclusion that the `poller_test.exs` deletion leaves no coverage gap,
reached independently rather than by trusting the chain of prior agreement.

## 1. REQ-186's 10 ACs and test/specs/REQ-186.md

Read `docs/requirements.yaml`'s REQ-186 entry directly (`acceptance_criteria:` block,
lines 9731-9740) — all 10 items quoted verbatim. None states or implies an
"application.ex has zero diff / untouched" property. AC9 reads: *"no route or
controller file is added or modified, confirmed by git diff --stat scoped to this
requirement's commits"* — this is about route/controller files, not application.ex,
and is unrelated to the deleted test's claim.

Read `test/specs/REQ-186.md` in full: its coverage checklist assigns AC7 and AC9 both
to `test/letflow/scheduler_test.exs` describe blocks; the deleted `poller_test.exs`
test was never part of the documented coverage matrix.

Confirmed: no AC maps to "application.ex has zero diff."

## 2. AC7/AC9 test bodies in scheduler_test.exs — read directly, run for real

Read the actual bodies (not just their existence) at:
- `describe "AC7: exhausting max_fire_retries transitions to failed with exactly one DLQ entry"` (line ~505): drives a timer through `max_fire_retries: 2` failed attempts, asserts `pending → pending(fire_error_count 1) → failed(fire_error_count 2, failed_at set)`, exactly one `dlq_timer_entries_for/2` row with `entry_type == "timer"`, and a third poll claims 0 / does not re-add a DLQ row.
- `describe "AC9: REQ-186 added no route or controller construct"` (line ~590): `File.read!`-based refutes of `Plug.Router`/controller/route patterns in `scheduler.ex`/`timer.ex`, plus a `Path.wildcard` sweep of `lib/letflow/api/**`, `lib/letflow/routers/**`, `web/src/**` asserting none reference `Letflow.Scheduler`/`"timers"`.

Ran for real:
```
mix test test/letflow/scheduler_test.exs
Result: 17 passed
```
AC7 and AC9 are genuine, currently-passing, DB/filesystem-backed tests — confirmed by
execution, not by reading the spec's claim that they exist.

## 3. Clean deletion — poller_test.exs

Read `git show cb9faa77 -- test/letflow/scheduler/poller_test.exs`: the diff removes
only `resolve_base_ref!/0` and the `"lib/letflow/application.ex has zero diff against
the base branch"` test, and renames the surviving describe block to
`"no second ticker -- lib/letflow/scheduler/ has exactly one GenServer module"`. Read
the current 343-line file in full: no dangling reference to `resolve_base_ref!` or the
deleted test remains; the surviving "no second ticker" test (line 329-342) is intact
and unaffected.

## 4. Mutation check — the actual regression this fix prevents

Since there is no traditional "bug to reproduce" here (this is a test deletion, not a
code fix), the falsifiable claim to check is the INVERSE of a normal regression test:
does the post-deletion suite still falsely fail on an inconsequential, legitimate
change to `application.ex`? Applied a real mutation myself:

```diff
--- a/lib/letflow/application.ex
+++ b/lib/letflow/application.ex
@@
-        {Task.Supervisor, name: Letflow.Engine.Wasm.ModuleRegistryTaskSupervisor},
         # REQ-167: ...
         {Task.Supervisor, name: Letflow.Engine.Wasm.CapabilityGateTaskSupervisor},
+        {Task.Supervisor, name: Letflow.Engine.Wasm.ModuleRegistryTaskSupervisor},
```
(swapped the order of two independent, order-independent Task.Supervisor children —
their own comments state "No other child depends on start order here.")

Ran `mix compile --warnings-as-errors` (clean) and
`mix test test/letflow/scheduler_test.exs test/letflow/scheduler/poller_test.exs`
with the mutation applied:
```
Result: 23 passed
```
Zero failures — the current suite does NOT falsely fail on this inconsequential
application.ex change. This is exactly the regression class the deletion prevents
(the deleted test would have failed here on a real diff, for a change with zero
behavioral consequence).

Reverted immediately: `git checkout -- lib/letflow/application.ex`. Confirmed clean:
```
git status --porcelain lib/ test/   ->  (empty)
git diff lib/letflow/application.ex ->  (empty)
```
Re-ran the suite post-revert to confirm still green:
```
mix test test/letflow/scheduler/poller_test.exs test/letflow/scheduler_test.exs
Result: 23 passed
```

## Conclusion

All four independent reads (ISSUE-FIXER, CODE-DESIGN-VALIDATOR, REVIEWER,
TEST-DESIGNER) and this fifth, TEST-DESIGN-VALIDATOR's own independent re-derivation,
agree: no AC maps to "application.ex has zero diff," AC7/AC9 are genuinely covered and
passing in `scheduler_test.exs`, the deletion in `poller_test.exs` is clean, and the
mutation check demonstrates the post-deletion suite no longer falsely fails on a
legitimate, inconsequential `application.ex` change. PASS — route to TEST-RUNNER.
