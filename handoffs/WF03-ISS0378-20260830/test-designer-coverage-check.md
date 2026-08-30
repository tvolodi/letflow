# TEST-DESIGNER independent coverage check — ISS-0378

**Run:** WF03-ISS0378-20260830
**Conclusion:** No new test added. Confirmed independently: the deletion leaves no
coverage gap against any of REQ-186's 10 acceptance criteria.

## What I read myself (not taken on trust from ISSUE-FIXER/CODE-DESIGN-VALIDATOR/REVIEWER)

1. `docs/requirements.yaml`'s REQ-186 entry — all 10 acceptance criteria read in full.
   None of them states or implies an "application.ex has zero diff against main" or
   "application.ex untouched" property. The two ACs plausibly adjacent to
   `application.ex`/supervision are:
   - AC7: a timer reaching `max_fire_retries` transitions to `failed`, sets `failed_at`,
     produces exactly one `dlq_entries` row (`entry_type: "timer"`), and is not
     reattempted by later polls.
   - AC9: no route or controller file is added or modified for `timers`/`scheduler`.
   Neither is "the Poller's own module/file was never edited" — that specific claim
   maps to nothing in the requirement text.

2. `test/specs/REQ-186.md` — the existing coverage checklist enumerates AC1–AC9 (AC10 is
   TEST-RUNNER's own obligation) and explicitly assigns:
   - AC7 → `test/letflow/scheduler_test.exs`, describe block
     `"AC7: exhausting max_fire_retries transitions to failed with exactly one DLQ entry"`.
   - AC9 → `test/letflow/scheduler_test.exs`, describe block
     `"AC9: REQ-186 added no route or controller construct"`.
   No AC in this spec is assigned to the deleted `poller_test.exs` test at all — it was
   never part of the documented coverage matrix in the first place.

3. `test/letflow/scheduler_test.exs` — read the actual bodies of both describe blocks
   (lines ~506–541 for AC7, ~590–637 for AC9):
   - AC7's test drives a timer through two failed fire attempts with
     `max_fire_retries: 2`, asserts `status` progression `pending → pending
     (fire_error_count 1) → failed (fire_error_count 2, failed_at set)`, asserts
     exactly one `dlq_timer_entries_for/2` row with `entry_type == "timer"`, then polls
     a third time and asserts `claimed == 0` and the DLQ row count is still 1 (not
     reattempted, not double-enqueued). This is a real, currently-passing, DB-backed
     test of the actual AC7 property — nothing to do with `application.ex`.
   - AC9's tests are structural: they `File.read!` the actual scheduler/timer source
     files and refute `Plug.Router`/controller/route-macro patterns, then
     `Path.wildcard` over `lib/letflow/api/**`, `lib/letflow/routers/**`, and
     `web/src/**` and assert none reference `Letflow.Scheduler`/`"timers"`. No git
     history dependency — matches this project's own documented anti-pattern
     mitigation.
   Both are genuine, working, DB/filesystem-backed tests, independently verified by
   reading their bodies rather than trusting the spec's claim that they exist.

4. `test/letflow/scheduler/poller_test.exs` post-deletion (343 lines, read the tail in
   full, lines 290–343): the file now ends with the AC8 `retention_due?/1` tests and the
   single surviving structural test in the renamed describe block
   `"no second ticker -- lib/letflow/scheduler/ has exactly one GenServer module"`,
   asserting `Path.wildcard("lib/letflow/scheduler/**/*.ex")` filtered to files matching
   `use\s+GenServer` yields exactly `["lib/letflow/scheduler/poller.ex"]`. Confirmed by
   `grep -rn resolve_base_ref` across `test/` that no reference to the deleted helper or
   the deleted test's name survives anywhere in the test tree (the one hit, in
   `test/reports/report-20260830-WF02-REQ190-20260830.yaml`, is a historical run-report
   artifact recording a past `mix test` invocation's test name string, not a test file
   itself — it requires no edit).

## Independent finding

No real, currently-uncovered acceptance criterion or regression risk is left open by
this deletion. The deleted test's only structurally checkable claim — "no second ticker
was added" — survives verbatim in the sibling test that was kept (the GenServer-count
check over `lib/letflow/scheduler/**/*.ex`). The other half of its title ("application.ex
untouched") was never a real AC and is not a property any REQ-186 acceptance criterion
asks to be permanently true; freezing "this file's diff against a moving git ref is
empty" is exactly the anti-pattern class documented in `docs/anti-patterns.md` (test
scoped to git history rather than to the shipped artifact's structural state), not a
property worth re-encoding some other way.

I did not add a test. Adding one here would mean either (a) re-deriving a
git-history-based check under a different disguise, which the design doc and REVIEWER
both already correctly reject, or (b) exporting the currently-private
`Letflow.Application.scheduler_children/0` with no REQ/AC backing that decision, which
is scope creep beyond this issue's owned module (`test/letflow/scheduler/poller_test.exs`
only) and beyond what any current acceptance criterion requires. Concur with
ISSUE-FIXER, CODE-DESIGN-VALIDATOR, and REVIEWER's prior conclusion — reached here by
independently reading the requirement, the spec, and both the surviving and the AC7/AC9
test bodies myself, not by trusting their chain of handoffs.

## Acceptance criteria for this step (per the step-04 handoff)

- [x] States explicitly whether any new test is added and why, or explicitly why none is
      needed — see "Independent finding" above.
- [x] N/A — no test added, so nothing to check against the git-history anti-pattern.
- [x] Routes to TEST-DESIGN-VALIDATOR with findings stated explicitly (see
      `handoffs/WF03-ISS0378-20260830/step-04b-test-design-validator.json`).
