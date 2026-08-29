# RELEASE-VALIDATOR report -- REQ-186

Run: WF02-REQ186-20260829. Branch: feature/WF02-REQ186-20260829.
Verdict: **PASS**.

Independently re-derived, not copied from prior reports. Read
`lib/letflow/scheduler.ex`, `lib/letflow/scheduler/timer.ex`,
`lib/letflow/scheduler/poller.ex`, and
`priv/repo/migrations/20260829020001_create_timers.exs` in full, and
re-ran everything myself.

## Commands run and results

- `mix compile --warnings-as-errors --force` (touched all three new
  scheduler files first to force a real recompile, not a cache hit):
  `Compiling 146 files (.ex)` / `Generated letflow app`, exit 0, no
  warnings.
- `mix test test/letflow/scheduler_test.exs test/letflow/scheduler/poller_test.exs --trace`:
  `Result: 18 passed`, 0 failures (17 in `scheduler_test.exs` + 1 in
  `poller_test.exs`).
- `scripts/test_parallel.sh` (8 partitions, run in foreground, blocking,
  matching TEST-RUNNER's own mechanism): `combined: 2530 tests, 5
  properties, 3 failures (2532/2535 passed)`. Opened the 3 failing
  partitions' logs directly: all 3 are the standing environmental
  category -- `Mix.Tasks.Letflow.CheckToolchainTest` "a matching/mismatched
  rust pin" (both `System.cmd("rustc", ...)` -> `:enoent`, rustc absent
  from this sandbox) and `Letflow.Engine.Wasm.PluginHandlerTest` AC7
  (wasmex Rust-NIF-source `external_resources` assertion, same rustc/cargo
  absence). None touch the scheduler/timer/poller diff.
- `mix format --check-formatted`: exit 0, clean.
- `mix letflow.lint_handoffs`: `OK -- 0 new violations across 1418
  handoff files (25 pre-existing grandfathered, traced to ISS-0190)`.
- `git diff --stat 747782e..HEAD`: no route, controller, or `web/`
  file touched; only `lib/letflow/scheduler*`, the migration, the two
  test files, `lib/letflow/application.ex` (Poller supervision child),
  `lib/letflow/tenant_provisioning.ex` (manifest registration), config,
  design doc, and handoff/report bookkeeping.

## Acceptance criteria re-verification (against real code, not history)

1. Migration's `if prefix() do` guard wraps `create table(:timers, ...)`
   with `tenant_id` retained as a plain column, plus
   `idx_timers_pending_fire_at` on `(fire_at) WHERE status = 'pending'`.
   Verified directly reading the migration file. MET.
2. `chk_timers_status` CHECK constraint: `status IN ('pending', 'fired',
   'cancelled', 'failed')`. AC2 tests raw-insert (bypassing the
   changeset, which never even casts `status`) and assert
   `%Postgrex.Error{postgres: %{code: :check_violation}}` for `'expired'`,
   and successful inserts for all four admitted values. Ran green. MET.
3. `chk_timers_recurrence_shape` CHECK constraint is the all-or-nothing
   SQL predicate. AC3 tests raw-insert `repeat_expression` alone (DB
   rejects) and all four columns together (DB accepts). Ran green. MET.
4. `do_fire/2` computes `fired_late = DateTime.compare(now, timer.fire_at)
   == :gt` and the `TIMER_FIRED` payload carries `fired_late`,
   `scheduled_fire_at`, `actual_fired_at`. Past-`fire_at` test fires with
   `fired_late: true` and both timestamps present; future-`fire_at` test
   stays pending, no event appended. Both ran green. MET.
5. `claim_due_timer_ids/2` filters `status == "pending"`, so a fired
   timer is never reclaimed. AC5 test: first poll fires once, second poll
   claims 0/fires 0, `fired_at` unchanged, exactly one `TIMER_FIRED`
   event. Ran green. MET.
6. `attempt_fire/2`'s outer try/rescue plus `record_fire_failure/2`
   increments `fire_error_count` and leaves the timer `"pending"`;
   `poll_and_fire/1`'s `Enum.reduce/3` never short-circuits. AC6's two
   tests (a returned-`{:error,_}` failure via a dangling instance_id, and
   a genuine raised `Ecto.Query.CastError` via a malformed UUID) both ran
   green, including the "second due timer still fires" assertion. MET.
7. `land_exhausted_timer/3` sets `status: "failed"` + `failed_at`, then
   calls `Dlq.enqueue(%{entry_type: "timer", ...}, prefix: tenant_schema)`
   inside the same transaction. AC7 test (config override
   `max_fire_retries: 2`) drives a timer through exactly 2 failures,
   asserts exactly one `dlq_entries` row with `entry_type == "timer"`,
   and a third poll no longer claims it. Ran green. MET.
8. `poll_interval_ms/0`, `jitter_ms/0`, `max_timers_per_cycle/0`,
   `max_fire_retries/0` all read `Application.get_env(:letflow,
   :scheduler, [])` with defaults 5000/0/64/3, confirmed by reading
   `scheduler.ex`'s config section directly. AC8's default-fallback test
   and override test (`scheduler_test.exs`) plus the Poller's own
   fresh-read-per-tick override test (`poller_test.exs`, 30ms interval
   vs. the 5000ms default) all ran green. MET.
9. `git diff --stat` against the pre-feature-branch merge base (747782e)
   confirms no route/controller/`web/` file in the diff; AC9's own two
   structural tests (grepping the new files for `Plug.Router`/controller/
   route macros, and grepping `lib/letflow/api/`, `lib/letflow/routers/`,
   `web/src/`) also ran green. MET.
10. `mix test` (targeted: 18/18; full suite: 2532/2535, 3 pre-existing
    environmental failures unrelated to this diff) and
    `mix compile --warnings-as-errors` (exit 0, clean) both pass, output
    quoted above. MET.

## Design-record consistency

Reviewed `handoffs/WF02-REQ186-20260829/step-02c-security-reviewer.json`
and `step-02d-reviewer.json`: the one flagged deviation (`TIMER_FIRED`'s
`actor_id` using `EventStore.platform_actor_id()` instead of the design
doc's literal `actor_id: nil`, because `EventStore.append/2` rejects a
literal `nil`) was resolved by REVIEWER editing
`lib/letflow/design/req186-scheduler-core.md` section 6 directly
(REQ-168/REQ-181 precedent) -- not a silent re-decision, not left
unresolved. No other `docs/migration/decisions/` record is contradicted
by the shipped code (Decision 0003 Decision B -- schema-per-tenant with
`tenant_id` retained -- verified directly against the migration).

This is a WF-02 single-requirement run, not a stage-gate check, so no
`docs/migration/stage-N-*.md` REVIEWER sign-off section applies here.

## Conclusion

All 10 acceptance criteria independently confirmed against real code and
a real, self-run test suite. No gap found. PASS -- routing to
DOC-UPDATER to flip REQ-186 to `done`.
