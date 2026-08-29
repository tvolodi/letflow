# REQ-187 — TEST-DESIGN-VALIDATOR report

**Verdict: PASS**

## Scope

Independent validation of `test/letflow/engine/timer_wiring_test.exs` (18
new tests) against every acceptance criterion in
`handoffs/WF02-REQ187-20260829/step-03-test-designer.json`, including
REVIEWER's own added multi-timer-guard item, per
`.claude/agents/test-design-validator.md`.

## Coverage check

Read the full test file and `test/specs/REQ-187.md`'s traceability table
line-by-line against the ten AC groups. All ten have real, runnable,
non-skipped tests:

- AC1/AC7 (arming, date-part/time-part/P0D): tests 1-3.
- AC2 (timer+event atomicity): test 4.
- AC3 (firing advances the token, incl. TIMER->TIMER chain): tests 5-6.
- AC4 (completion cancels pending timers via unmoved call site): tests 7-8
  (direct-mechanism call + source-text structural check).
- AC5 (cancel_instance/3 cancellation + rollback + lock-ordering): tests
  9-11.
- AC6/SCH-03 (fired-timer immutability, no-fire-after-terminal): tests
  12-13.
- Multi-timer guard (REVIEWER item): test 14.
- Purity regression (AC7): test 15.
- AC8 (no route/controller/migration/web touched): tests 16 (two
  assertions).
- Reconstruction/TIMER_FIRED replay parity: test 17.

No `@tag :skip`, no "TODO: implement test" left anywhere in the spec or
test file.

## Duplication check

Read `transition_test.exs`'s `"transition/3 -- :TIMER entry/fired"`
describe block and `task_activation_test.exs`'s `"cancel_pending_timers/5"`
describe block directly. Both are pure-kernel/doc-content checks
(no DB, no `Repo`), confirmed disjoint from `timer_wiring_test.exs`'s
DB-level integration coverage (real Postgres, real `Ecto.Multi`, real
`Scheduler.poll_and_fire/1`). No overlap found.

## Fixture isolation

Every test calls its own `provisioned_tenant()` (a fresh
`TenantFixture.provisioned_tenant!/1` schema per test) and
`unique_name/1` (`System.unique_integer/1`-based) for definition names
and idempotency keys. No shared/leaked state across tests, no test
depends on another having run first, no wall-clock-timing dependency
(the `P0D`/immediate-fire cases use a deterministic `fire_at <= now`
comparison, not `Process.sleep`). No hardcoded secrets or connection
strings.

## Fresh test run (this validator's own run, not copied from TEST-DESIGNER)

- `mix compile --warnings-as-errors`: clean.
- `mix test test/letflow/engine/timer_wiring_test.exs`: **18 passed**.
- Combined with the 4 pre-existing REQ-187-touched files
  (`transition_test.exs`, `task_activation_test.exs`, `scheduler_test.exs`,
  `scheduler/poller_test.exs`): **81 passed (1 property, 80 tests)** —
  matches TEST-DESIGNER's reported combined count exactly.

## Independent mutation reproduction (mutation 3 — lock-ordering)

Per the task's own instruction to re-derive at least one mutation rather
than trust the report, chose mutation 3 (the most novel/fragile — a
structural, not behavioral, regression):

1. Read `lib/letflow/engine.ex`'s `run_cancel_instance/5` (lines
   2838-2897) and confirmed the shipped `:timer_cancellations` `Multi.run`
   step sits between `:open_tasks` and `:instance_projection`, exactly
   matching test 11's asserted source-position ordering.
2. Edited the file, moving the `:timer_cancellations` step back to its
   pre-fix, topically-grouped position (after `:token_cancellations`,
   immediately before `:event`) — the same mutation TEST-DESIGNER's notes
   describe.
3. Re-ran `mix test test/letflow/engine/timer_wiring_test.exs`:
   **17/18 passed**. The sole failure was test 11
   (`"run_cancel_instance/5's own Multi places :timer_cancellations
   between :open_tasks and :instance_projection"`):
   `Assertion with < failed, code: assert timer_cancellations_index <
   instance_projection_index`. All other 17 tests, including test 10 (the
   rollback test), still passed — independently confirming TEST-DESIGNER's
   claim that only the dedicated structural test catches this regression.
4. Reverted with `git checkout -- lib/letflow/engine.ex`.
   `git status --porcelain lib/ test/` returned empty;
   `git diff --stat` returned empty.
5. Re-ran the suite post-revert: **18/18 passed**, confirming the tree is
   back to the committed, gate-passed state.

## Assessment of the lock-ordering structural test specifically

Genuine, non-vacuous structural check — not something that could pass
trivially. It reads the real `lib/letflow/engine.ex` source at test time
(`File.read!`), isolates `run_cancel_instance/5`'s own `Multi` body via
`String.split` on the function's own signature and the next function's
leading comment marker (`"\n  # M1 --"`), bounding the search so it
cannot accidentally match `:open_tasks`/`:timer_cancellations`/
`:instance_projection,` text anywhere else in the ~2900-line file, then
asserts the byte-offset ordering of the three step-name atoms via
`:binary.match/2`. This is exactly the shape of check needed for a
property (lock-ordering / deadlock avoidance) that is unobservable via
any single-process behavioral assertion. My own mutation reproduction
confirms it is the *only* test in the file sensitive to the step's
position, so it earns its place rather than duplicating test 10's
rollback-behavior coverage.

## Conclusion

No gaps found. Coverage is complete, non-duplicated, self-sufficient, and
the most novel test (the structural lock-ordering check) is verified
independently to be genuine and load-bearing. PASS — routing to
TEST-RUNNER.
