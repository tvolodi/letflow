# REQ-186 TEST-DESIGNER mutation-testing notes

Free-text supplement to `handoffs/WF02-REQ186-20260829/step-03b-test-design-validator.json`.
Named to avoid the H6 handoff-lint rule (no leading "step").

## What was tested

- `test/letflow/scheduler_test.exs` -- `Letflow.Scheduler` context module (17 tests)
- `test/letflow/scheduler/poller_test.exs` -- `Letflow.Scheduler.Poller` GenServer (1 test)
- `test/specs/REQ-186.md` -- the acceptance-criterion -> test-case mapping

Real output, unmutated implementation:

```
$ MIX_ENV=test MIX_TEST_PARTITION=99 mix test test/letflow/scheduler_test.exs test/letflow/scheduler/poller_test.exs
....................
Result: 18 passed
```

## Mutations applied (one at a time, each reverted via `git checkout` before the next)

| # | File | Mutation | Result |
|---|---|---|---|
| 1 | `lib/letflow/scheduler.ex` | Removed `\|> lock("FOR UPDATE SKIP LOCKED")` from `claim_due_timer_ids/2` | **NOT caught** -- 18/18 still passed |
| 2 | `lib/letflow/scheduler.ex` | Hardcoded `fired_late = false` in `do_fire/2` (was `DateTime.compare(now, timer.fire_at) == :gt`) | Caught -- 17/18, AC4 test failed |
| 3 | `lib/letflow/scheduler.ex` | Flipped `new_count >= max_fire_retries()` to `>` in `record_fire_failure/2` | Caught -- 17/18, AC7 test failed |
| 4 | `lib/letflow/scheduler.ex` | Hardcoded `Dlq.enqueue(dlq_attrs, prefix: "public")` (was `prefix: tenant_schema`) | Caught -- 17/18, AC7 test failed (no dlq_entries row found in tenant schema) |
| 5 | `lib/letflow/scheduler.ex` | Removed the increment: `new_count = timer.fire_error_count` (was `+ 1`) | Caught -- 16/18, both AC6 and AC7 tests failed |
| 6 | `lib/letflow/scheduler/poller.ex` | Hardcoded `delay = 5_000 + jitter_extra_ms()` in `schedule_next_tick/0` (was `Scheduler.poll_interval_ms() + jitter_extra_ms()`) | Caught -- 17/18, poller AC8 test failed |

5 of 6 mutations caught. After each mutation and revert, `git diff lib/letflow/scheduler.ex
lib/letflow/scheduler/poller.ex lib/letflow/scheduler/timer.ex` was run and confirmed empty
(byte-identical to the committed state) before moving to the next mutation. Final state
confirmed clean immediately before this commit as well.

## Disclosed gap: mutation #1 (row-locking removal)

Removing `FOR UPDATE SKIP LOCKED` from the claim query is not caught by anything in this
suite. None of REQ-186's nine acceptance criteria (see
`handoffs/WF02-REQ186-20260829/step-03-test-designer.json`) require testing concurrent
claimers racing the same due timer -- every test here runs `poll_and_fire/1` from a single
process against a single connection (DIRECTIVE T-1's "real Postgres, not mocked" is
satisfied; a multi-connection concurrency test is a different, heavier kind of test this
requirement's own acceptance criteria don't call for). This is reported here rather than
silently omitted, per this pipeline's own "don't silently resolve a gap" discipline --
TEST-DESIGN-VALIDATOR should judge whether this gap is acceptable given AC1-AC9's literal
scope, or whether a follow-up concurrency test is warranted (out of this handoff's own
scope to decide unilaterally).

## Environment used

- Toolchain: `asdf` shims (`elixir 1.20.3-otp-29`, `erlang 29.0.5`) -- not on `PATH` by
  default in this session; `export PATH="$HOME/.asdf/shims:$PATH"` was required.
- Database: this workspace's own `letflow-1-postgres-1` container (host port 5463, per
  `.env`'s `LETFLOW_DB_PORT=5463`). Used `MIX_TEST_PARTITION=99` (a scratch partition, not
  this workspace's regular `mix test` partition) to avoid colliding with any concurrently
  running `mix test` invocation on this same host, and dropped that scratch database
  (`mix ecto.drop`) after the run.
