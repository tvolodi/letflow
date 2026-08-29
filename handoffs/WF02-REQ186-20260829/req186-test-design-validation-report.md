# TEST-DESIGN-VALIDATOR report — REQ-186, Step 3b

**Verdict: PASS**

## What was checked

Read directly, in full: `test/letflow/scheduler_test.exs` (17 tests),
`test/letflow/scheduler/poller_test.exs` (1 test), `test/specs/REQ-186.md`,
`handoffs/WF02-REQ186-20260829/step-01-code-designer.json` (original acceptance
criteria), `handoffs/WF02-REQ186-20260829/step-03-test-designer.json`,
`handoffs/WF02-REQ186-20260829/step-03b-test-design-validator.json`,
`handoffs/WF02-REQ186-20260829/req186-test-designer-mutation-notes.md`, and
`lib/letflow/scheduler.ex` / `lib/letflow/scheduler/timer.ex` /
`lib/letflow/scheduler/poller.ex`.

## Acceptance-criterion coverage (independently re-derived against
`step-01-code-designer.json`'s AC list, not copied from the spec's own checklist)

- **AC1** (tenant-scoped table, `tenant_id` retained, partial index on
  `(fire_at) WHERE status = 'pending'`) — `AC1` describe block queries
  `information_schema.columns`/`information_schema.tables` and `pg_indexes`
  directly against a real provisioned tenant schema, confirming the table is
  absent from `public` and the index predicate text. Structural claim checked
  structurally, not via a passing function call. Real coverage.
- **AC2** (status CHECK admits exactly the 4 values) — raw SQL insert with
  `status = 'expired'` asserted to fail with `Postgrex.Error{postgres: %{code:
  :check_violation}}`, bypassing the changeset layer entirely (confirmed
  `Timer.arm_changeset/2` never casts `status`, so this is a genuine DB-level
  test); a second test inserts each of the four admitted values. Real coverage.
- **AC3** (recurrence CHECK all-or-nothing) — raw insert with
  `repeat_expression` alone rejected with `check_violation`; raw insert with
  all four columns populated succeeds. Both halves the AC's own text calls for.
  Real coverage.
- **AC4** (past `fire_at` fires with `fired_late: true` + both timestamps;
  future `fire_at` does not fire) — two explicit tests, exactly as required.
  The past-fire test asserts on `poll_result` counts, reloaded row status,
  and the appended `TIMER_FIRED` event's payload (`fired_late`,
  `scheduled_fire_at`, `actual_fired_at`, `timer_id`). Real coverage.
- **AC5** (double-poll idempotency) — two `poll_and_fire/1` calls, second
  asserted to claim/fire zero and leave `fired_at` byte-identical
  (`DateTime.compare/2 == :eq`), plus an event-count assertion of exactly 1.
  Real coverage.
- **AC6** (failing fire attempt increments `fire_error_count`, stays
  `pending`, cycle continues) — one test drives two due timers in the same
  poll, the first against an instance with no `instance_projections` row
  (a genuine, organic `{:error, :instance_not_started}` from
  `EventStore.append/2`'s own `active_instance_guard`, not a mock), asserting
  both the first timer's `fire_error_count == 1`/`status == "pending"` AND the
  second timer's `status == "fired"` in the same call — the AC's literal
  "one test asserts both" requirement is met, not split into two weaker
  tests. A second test independently forces a genuine raised
  `Ecto.Query.CastError` (invalid UUID) through `attempt_fire/2` and asserts
  the outer try/rescue converts it to `:errored` rather than letting it
  propagate — this is the raise-specific half of AC6's text ("a fire attempt
  that raises"), which the first test's organic-failure path does not itself
  exercise (that path is a returned `{:error, _}`, not a raise). Real,
  non-overlapping coverage of both AC6 sub-claims.
- **AC7** (max-retries exhaustion: `failed` + `failed_at` + exactly one
  `dlq_entries` row + no further reattempt) — one test overrides
  `max_fire_retries: 2`, drives two failing polls, asserts `failed`/
  `failed_at`/exactly one `entry_type == "timer"` DLQ row after the second,
  then polls a third time and asserts zero claims and the DLQ row count is
  still exactly 1. Every clause of the AC is asserted. Real coverage.
- **AC8** (config defaults + override, Poller reads live) — three tests in
  `scheduler_test.exs` (defaults with no config set, `poll_interval_ms`
  override with unrelated keys still defaulting, `max_timers_per_cycle`
  actually bounding `claim_due_timer_ids/2`'s `LIMIT`) plus one
  `poller_test.exs` test that starts a real `Poller` GenServer under
  `start_supervised!/1`, overrides `poll_interval_ms: 30`, and proves a timer
  armed *after* the first (zero-delay) tick is fired well within 300ms — a
  window that only a genuinely-overridden ~30ms tick interval could hit,
  falsifying both "override ignored" and "override cached at `init/1` instead
  of read per-tick" mutations. Real coverage, including the process-level
  claim the design makes explicit at §3.2.
- **AC9** (no route/controller) — structural source-grep on
  `lib/letflow/scheduler.ex`/`timer.ex` for `Plug.Router`/controller/route
  constructs, plus a working-tree walk of `lib/letflow/api/`,
  `lib/letflow/routers/`, `web/src/` for any reference to
  `Letflow.Scheduler`/`timers`. No git-history/SHA dependency, matching this
  project's own documented anti-pattern against that (cited correctly from
  `dlq_test.exs`'s own AC6 comment). Real coverage.

No `@tag :skip` anywhere in either file. No "TODO: implement" language. No test
depends on another test having run first — every test calls
`provisioned_tenant!/1` (or the file's own `provisioned_tenant/1` wrapper)
itself and arms its own timers via `Scheduler.create/2`; no shared mutable
fixture state across tests. No hardcoded secrets or connection strings — DB
connection comes from `Letflow.DataCase`/config.

## Fresh test run (this session, not copied from TEST-DESIGNER's report)

Environment: `asdf` shims on `PATH`, this workspace's own Postgres container
(port 5463 per `.env`), scratch `MIX_TEST_PARTITION=42` to avoid colliding with
any concurrent `mix test` run on this host. `mix ecto.create`/`mix
ecto.migrate` run clean against the scratch partition first.

```
$ MIX_TEST_PARTITION=42 mix test test/letflow/scheduler_test.exs test/letflow/scheduler/poller_test.exs
Finished in 11.5 seconds (0.00s async, 11.5s sync)
Result: 18 passed
```

Matches TEST-DESIGNER's reported `18 passed`.

## Independent mutation reproduction (mutation #3 from TEST-DESIGNER's report)

Applied, myself, the reported mutation flipping the max-retries comparison in
`record_fire_failure/2` from `new_count >= max_fire_retries()` to `new_count >
max_fire_retries()` in `lib/letflow/scheduler.ex`:

```
$ MIX_TEST_PARTITION=42 mix test test/letflow/scheduler_test.exs test/letflow/scheduler/poller_test.exs
  1) test AC7: exhausting max_fire_retries transitions to failed with exactly one DLQ entry after max_fire_retries failed attempts the timer is failed, DLQ-landed once, and never reattempted (Letflow.SchedulerTest)
     Assertion with == failed
     code:  assert second.exhausted == 1
     left:  0
     right: 1
Result: 17/18 passed
Failed: 1 test
```

Exactly matches TEST-DESIGNER's reported result for mutation #3 (17/18, AC7
test failed). Reverted via `git checkout -- lib/letflow/scheduler.ex`.
Confirmed clean:

```
$ git status --porcelain lib/ test/
(empty)
```

Re-ran the suite after revert: `Result: 18 passed` (back to green).

## The disclosed gap: `FOR UPDATE SKIP LOCKED` removal (mutation #1) not caught

TEST-DESIGNER disclosed that removing the row-lock clause from
`claim_due_timer_ids/2` leaves the suite at 18/18 — no test in either file
exercises concurrent claimers racing the same due timer.

**Precedent check** (as instructed): grepped `test/letflow/dlq_test.exs` and
`test/letflow/webhooks_test.exs` for a concurrent-lock test — neither exists.
`lib/letflow/dlq.ex:303` and `lib/letflow/webhooks.ex:307` both use
`lock("FOR UPDATE")`; `lib/letflow/scheduler.ex:189` uses the closely-related
`lock("FOR UPDATE SKIP LOCKED")` — the identical idiom class (row-lock a
claimed/mutated row to guard against a concurrent second worker). Read
`handoffs/WF02-REQ181-20260829/req181-test-design-validation-report.md` in
full: REQ-181's TEST-DESIGN-VALIDATOR faced this exact question for
`Letflow.Webhooks`' own `lock("FOR UPDATE")` reuse of `Letflow.Dlq`'s idiom,
and ruled: (1) none of the acceptance criteria in scope mention concurrent
behavior or lock contention; (2) REQ-176 (`Letflow.Dlq`, the idiom's origin)
shipped and passed TEST-DESIGN-VALIDATOR/TEST-RUNNER/RELEASE-VALIDATOR with
this identical gap, never closed, no issue ever filed against it; (3) this
codebase's established path for validating a row-lock's *correctness* is
SECURITY-REVIEWER/REVIEWER code-reading, not a TEST-DESIGNER concurrency
test — and REQ-186 already passed both of those gates
(`step-02c-security-reviewer.json`, `step-02d-reviewer.json`); (4) the
codebase has proven capacity to write genuine multi-process lock-contention
tests when an AC specifically calls for it
(`reconstruction_test.exs`'s `with_locked_projection/3`), which shows the gap
is closable on demand, not that it must be closed here.

None of REQ-186's nine acceptance criteria (`step-01-code-designer.json`)
mention concurrent claimers, multiple poller processes, or lock contention —
AC5's "polling twice" is sequential idempotency (single process, two calls),
a genuinely different claim from "two processes racing the same row," and is
covered. The row lock is the same internal robustness mechanism carried over
from REQ-185's architecture doc, not an acceptance criterion in its own
right.

**Decision: accept the gap as a disclosed, non-blocking follow-up**, applying
the REQ-181 precedent rather than inventing a stricter bar for REQ-186 alone.
The two cases do not differ in any way that would justify a different
outcome: same idiom (`lock("FOR UPDATE" [SKIP LOCKED])`), same absence of an
AC calling for concurrency testing, same prior SECURITY-REVIEWER/REVIEWER
code-level sign-off path, same codebase-wide precedent (REQ-176 also
unclosed). Recommend (non-blocking) that a follow-up issue eventually cover
`Letflow.Dlq`, `Letflow.Webhooks`, and `Letflow.Scheduler`'s three row-lock
paths together, since it is now the same gap in three modules — a
recommendation, not a condition of this PASS.

## Result

PASS. Route to TEST-RUNNER.
