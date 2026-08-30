# RELEASE-VALIDATOR report — REQ-188

Run: WF02-REQ188-20260829
Branch: feature/WF02-REQ188-20260829
Verdict: **PASS**

## What was independently re-derived (not trusted from prior reports)

Read `lib/letflow/scheduler.ex` in full (581 lines), `lib/letflow/scheduler/poller.ex`
in full (103 lines), `test/letflow/scheduler_req188_test.exs`,
`test/letflow/scheduler/poller_test.exs`, `docs/issues/ISS-0014.yaml`,
`docs/migration/decisions/0003-ecto-schema-strategy.md`, and REQ-188's own
`docs/requirements.yaml` entry (line 9818). Ran `mix compile --warnings-as-errors`,
`mix test` on the three named files, `mix format --check-formatted`,
`mix letflow.lint_handoffs`, and the full suite via `scripts/test_parallel.sh`
(8 partitions) myself, foreground/blocking.

## Acceptance criteria, one by one

1. **R/PT1H re-arm, same transaction, exactly one new pending timer at
   fire_at+1h.** `maybe_rearm_timer/3` (scheduler.ex) is the last step of
   `do_fire/2`'s `with` chain, called inside `fire_timer/2`'s own
   `Repo.transaction/1` — no new transaction opened. `build_rearm_attrs/2`
   anchors the new row's `fire_at` to `fired_timer.fire_at` (nominal,
   pre-fire schedule) + `repeat_interval_us`, not the actual firing clock
   time. `SchedulerReq188Test` "creates exactly one new pending timer..."
   asserts exactly this arithmetic, and the companion "INV-REARM-1" test
   wraps `fire_timer/2` in an outer transaction forced to roll back and
   asserts the reloaded timer is still `pending`/`fired_at: nil` and the
   recurring-timer count is back to 1 — i.e. neither the firing nor the
   re-arm insert survives. Both tests pass. **PASS**

2. **R3/PT1H stops after third firing.** `maybe_rearm_timer/3`'s
   `if fired_timer.repeat_total != nil and new_fired_count >= fired_timer.repeat_total`
   branch returns `{:ok, :series_complete}`, inserting nothing. Test polls
   3 times, asserts 3 recurring rows with `fired_count` `[0,1,2]` and all
   `status: "fired"`, then polls a 4th time and asserts `fired: 0` and the
   row count is still 3. Passes. **PASS**

3. **Cancelled instance's recurring timer does not re-arm.** Test cancels
   the instance (which per REQ-187's existing `cancel_pending_timers`
   machinery flips the timer to `"cancelled"`), confirms that, then polls
   and asserts `claimed: 0`, `fired: 0`, and the recurring-timer count
   stays at 1 (`fire_timer/2` never runs because `claim_due_timer_ids/2`
   only selects `status = "pending"`, so a cancelled timer is never
   claimed in the first place — no separate re-arm guard was needed).
   Passes. **PASS**

4. **Interval shorter than poll interval fires at most once per cycle.**
   Structural, not timing-based: `claim_due_timer_ids/2` fixes its claimed
   id list via one `SELECT ... FOR UPDATE SKIP LOCKED` query before any
   firing/re-arming happens in that cycle, so a newly-inserted re-armed row
   cannot be claimed by the same `poll_and_fire/1` call that created it,
   regardless of how short `repeat_interval_us` is. Test sets
   `repeat_interval_us: 1_000` (1ms, confirmed against the real
   `poll_interval_ms() == 5_000` default), calls `poll_and_fire/1` once,
   and asserts `claimed: 1`, `fired: 1`, exactly one new pending row created
   even though that new row's `fire_at` is already `<= now`. Passes. **PASS**

5. **Retention disabled by default.** `@default_retention_enabled false`;
   `retention_enabled?/0` is `scheduler_config()[:retention_enabled] || @default_retention_enabled`.
   `Poller.handle_info(:tick, ...)`'s `maybe_run_retention_sweep/2` guards
   `Scheduler.run_retention_sweep/1` (which wraps `EventStore.archive/1`)
   behind `retention_enabled?()`. `poller_test.exs`'s AC5 tests seed an old
   eligible event with **no** `:scheduler` config set at all
   (`Application.get_env(:letflow, :scheduler) == nil` asserted directly),
   call `handle_info(:tick, ...)` (once, and across 5 ticks), and assert
   the event row count is untouched and the archive table stays empty.
   Passes. **PASS**

6. **Retention enabled invokes archive/1 and moves rows.** AC6 test sets
   `retention_enabled: true, retention_interval_ms: 0, retention_days: 30`,
   seeds one 60-day-old event and one fresh one, ticks once, and asserts
   the old event moved to `events_archive` (count 1→0 in `events`, 0→1 in
   `events_archive`) while the recent one stays in `events`. A second test
   confirms `retention_due?/1` correctly gates a second sweep from
   re-running before its interval elapses. Both pass. **PASS**

7. **Runs on the existing scheduler process, no new ticker.**
   `git diff --stat` of `lib/letflow/application.ex` between `e034e2b`
   (REQ-187, pre-REQ-188) and `HEAD` (and against `origin/main`) is empty —
   confirmed directly by me, not just by the test. `poller_test.exs`'s AC7
   also asserts this via `git diff` at test-run time, plus a second test
   walking `lib/letflow/scheduler/**/*.ex` and asserting `Letflow.Scheduler.Poller`
   is the only module using `use GenServer`. Both pass. **PASS**

8. **Moduledoc citations.** `Letflow.Scheduler`'s moduledoc, "REQ-188 —
   recurring timers... and the periodic retention runner" section,
   explicitly names `partition_maintenance.zig`/`partition_retention.zig`
   as not-ported, cites `0003-ecto-schema-strategy.md`'s Dimension/Decision C
   point 2 (partitioning deferral) and `docs/issues/ISS-0014.yaml`'s
   resolution adopting option (a) and rejecting option (c) — verified this
   is not a stale or invented citation by reading ISS-0014.yaml directly:
   its `resolution:` field says exactly "Adopted option (a)... Rejected...
   (c) (port PAR-03's whole-partition retention now) because it would force
   partitioning early, contradicting 0003 Decision C's deliberate deferral"
   — third independent re-verification of this citation in this pipeline
   run, still holds. Note: the decision doc's own section header text says
   "Dimension C" while both ISS-0014's resolution and this moduledoc say
   "Decision C" — pre-existing terminology already used interchangeably
   inside 0003's own text ("Decision B" appears in its own Dimension C
   section) and by ISS-0014's already-resolved record, not something
   REQ-188 introduced. The moduledoc also states the SCH-04 deferral,
   naming `CHK-12`/`graph.ex` L738 and the missing
   `escalation_timer_duration` attribute on `:HUMAN_TASK`. **PASS**

9. **No route or controller file added.** `git diff --stat e034e2b..HEAD`
   (all of REQ-188's commits) touches no `router`/`controller`-named file
   at all — confirmed directly, and matches
   `scheduler_req188_test.exs`'s own dedicated AC9 tests. **PASS**

10. **mix test / mix compile --warnings-as-errors.** `mix compile --warnings-as-errors`:
    clean, zero output. `mix test test/letflow/scheduler_req188_test.exs
    test/letflow/scheduler/poller_test.exs test/letflow/scheduler_test.exs`:
    `Result: 32 passed`, 0 failures. Full suite via
    `scripts/test_parallel.sh` (8 partitions, run by me, foreground/blocking,
    not via TEST-RUNNER's report): `combined: 2564 tests, 5 properties, 3
    failures (2566/2569 passed)`. Inspected the 3 failures directly in the
    partition logs: `Letflow.Engine.Wasm.PluginHandlerTest` AC7 (wasmex Rust
    NIF source resolution) and two `Mix.Tasks.Letflow.CheckToolchainTest`
    rust-pin tests (`System.cmd("rustc", ...)` → `:enoent`) — all three are
    the same pre-existing rustc/wasmex-absent-from-sandbox environmental
    failures TEST-RUNNER's report names, confirmed unrelated to REQ-188's
    diff (none touch scheduler/timer code). `mix format --check-formatted`:
    clean. `mix letflow.lint_handoffs`: "0 new violations across 1438
    handoff files (25 pre-existing grandfathered)". **PASS**

## Other checks

- `depends_on: [REQ-186, REQ-187, REQ-026]` — all three `status: done` in
  `docs/requirements.yaml`, confirmed by direct grep.
- No `docs/migration/decisions/` record is contradicted: 0003 Decision C's
  partitioning deferral is respected (no partitioning added), and ISS-0014's
  adopted option (a) is exactly what REQ-188 schedules (row-level
  `archive/1`, no whole-partition mechanism).
- This is a WF-02 run, not a WF-04 stage-gate run, so no
  `docs/migration/stage-6-*.md` REVIEWER sign-off section applies here —
  noted for DOC-UPDATER that this is the LAST requirement of S6's scheduler
  half regardless, per the dispatching agent's own note.

## Conclusion

All 10 acceptance criteria independently re-derived and confirmed true
against the real shipped code and a fresh, self-run test pass. No gap
found. **PASS** — routing to DOC-UPDATER (Step 6).
