# ISS-0581: `Poller.PollerTest` AC8 flake fix — design

## Status

Fix design for `WF03-ISS0581-20260910`, Step 2. Scope: **test-only**. No
production code (`lib/letflow/scheduler/poller.ex`) changes.

## Root cause (from ISSUE-FIXER's Step 1, restated for traceability)

`test/letflow/scheduler/poller_test.exs:136-182` (`describe "AC8: ..."`) arms a
timer, then does a single fixed `Process.sleep(300)` followed by one
assertion (`reloaded.status == "fired"`). The Poller's tick cadence is not a
fixed wall-clock interval — `schedule_next_tick/…` only re-arms after each
tick's full sequential sweep chain finishes, and each step in that chain
does real DB round trips (`poll_and_fire`, `maybe_refresh_active_instances`,
`maybe_run_retention_sweep`, `maybe_run_alert_detection`,
`maybe_run_ordering_cycle`, `maybe_run_ordering_sweeper`,
`maybe_run_ordering_metrics`). Under parallel-suite CPU/DB contention, tick
wall-clock duration inflates and fewer ticks complete inside the test's
fixed 300ms budget, so the timer can still be `"pending"` when the single
assertion fires. This is a test-side timing-margin defect, not a Poller
logic bug (config-read-freshness was independently confirmed correct).

## Chosen approach

**Add a local, file-scoped `wait_until/2` helper to `poller_test.exs`
itself** (option (a) from the task), not a shared `test/support/` helper.

Rationale: `test/support/` (checked via `Glob test/support/*.ex`) contains no
existing wait-until-shaped helper — every precedent in this codebase
(`invocation_lease_test.exs`'s `wait_until/2`, `sandbox_pool_test.exs`'s
`wait_until_pool_state/3` and `wait_until_schema_dropped/2`) is a **private,
file-scoped** `defp` pair, each duplicated per file rather than shared.
Introducing a shared `test/support/` helper now would be a scope-creep
refactor of an established (if repetitive) pattern, not something this fix
needs — WF-03 fixes should stay minimal and match existing convention, not
opportunistically consolidate it. Follow the same shape here rather than
invent a third one.

## Helper signature (illustrative — matches `invocation_lease_test.exs:150-167` exactly)

```elixir
# Added to test/letflow/scheduler/poller_test.exs, alongside this file's
# other private helpers (e.g. near live_token_id!/2 / put_scheduler_config/1).

@spec wait_until((-> boolean()), non_neg_integer()) :: boolean()
defp wait_until(fun, timeout_ms) do
  deadline = System.monotonic_time(:millisecond) + timeout_ms
  do_wait_until(fun, deadline)
end

@spec do_wait_until((-> boolean()), integer()) :: boolean()
defp do_wait_until(fun, deadline) do
  cond do
    fun.() ->
      true

    System.monotonic_time(:millisecond) >= deadline ->
      false

    true ->
      Process.sleep(20)
      do_wait_until(fun, deadline)
  end
end
```

This is the identical two-clause shape as the precedent: monotonic deadline
computed once up front, 20ms poll interval, boolean-returning predicate
function, no external dependency.

## Predicate AC8 should poll for

Replace the fixed `Process.sleep(300)` + single assertion
(`poller_test.exs:177-180`) with a poll loop over the same read the test
already performs — `Repo.get!(Timer, timer.id, prefix: schema_name).status
== "fired"` — via a closure capturing `timer.id` and `schema_name`:

```elixir
# Illustrative call-site replacement for poller_test.exs:170-180.
fired? =
  wait_until(
    fn -> Repo.get!(Timer, timer.id, prefix: schema_name).status == "fired" end,
    2_000
  )

assert fired?,
       "expected timer #{timer.id} to reach status \"fired\" within 2000ms " <>
         "of arming (poll_interval_ms override was 30ms); got status " <>
         "#{Repo.get!(Timer, timer.id, prefix: schema_name).status} instead — " <>
         "see ISS-0581 for the wall-clock-tick-cadence-under-contention rationale"
```

Design notes for TEST-DESIGNER:
- Keep the comment block at `poller_test.exs:170-176` (explaining *why* only
  a second tick can pick the timer up) — it's still accurate and load-bearing
  context; only the fixed-sleep-then-single-assert tail (lines ~177-180)
  changes.
- The failure-path `assert fired?, "..."` message should re-fetch and report
  the actual terminal status, mirroring `sandbox_pool_test.exs`'s
  `poll_until_schema_dropped/2` pattern of a descriptive `flunk`/assertion
  message on timeout (that file uses `flunk/1` directly inside the poll
  loop's timeout branch; either shape — `flunk` inside the loop, or `assert
  fired?, "..."` at the call site as sketched above — is acceptable, pick
  whichever reads more naturally once TEST-DESIGNER drafts it).

## Timeout ceiling: 2000ms

Calibration against existing precedents:
- `invocation_lease_test.exs`'s `wait_until/2` call sites use `1_000`ms for
  in-process message/state convergence (no DB round trips involved).
- `sandbox_pool_test.exs`'s pool-state polls use
  `SandboxPool.release_call_timeout()` (a configured constant, not a literal)
  because that suite is polling a GenServer's own internal timeout contract.
- AC8's own original margin reasoning (`poller_test.exs:170-176`) already
  states 300ms is "~10 ticks at the 30ms override" — i.e. the *unloaded*
  expectation is the timer fires within roughly one tick (~30-60ms) of the
  second tick running. 300ms already built in some contention margin;
  reproduction showed 300ms insufficient under 8-way parallel load.
- **2000ms** (2s) is chosen as a ceiling generous enough to absorb the
  contention observed in the reproduction (10 other contention-family
  failures alongside AC8's sibling REQ-218 AC1 mismatch in the same 8-way
  run) while still being fast in the common case — `wait_until/2` returns as
  soon as the predicate is true, so a healthy/unloaded run still completes
  in roughly the original ~300-400ms (first status check likely already
  true), never sleeping the full ceiling except on genuine contention. 2000ms
  is also small enough not to meaningfully slow the suite even if it were
  hit on every parallel run (this is a single test, not a loop of many).
  This is well above the 5000ms *documented default* `poll_interval_ms`
  mentioned in the surrounding comment, but that default is irrelevant here
  — the override is 30ms, so 2000ms is ~66 ticks' worth of margin at the
  overridden interval, not a comparison to the default.

## Explicitly NOT changing

- `lib/letflow/scheduler/poller.ex` — confirmed correct by ISSUE-FIXER's
  reproduction (config read fresh every tick); no edit.
- The `put_scheduler_config/1` override values (`poll_interval_ms: 30,
  jitter_ms: 0, max_timers_per_cycle: 64, max_fire_retries: 3`) — unchanged.
- The initial `Process.sleep(20)` at `poller_test.exs:152` (letting the
  Poller's own zero-delay first tick complete as a no-op before the timer
  exists) — unchanged; it is not part of the flaky assertion.

## Fail-then-pass proof (WF-03 requirement) — how it will actually be demonstrated

A plain revert-and-rerun will NOT reliably reproduce this flake — it is
load-dependent, and an isolated run of this single test already passes
cleanly pre-fix (confirmed by ISSUE-FIXER: "isolated run passes clean
(1/1)"). TEST-RUNNER must instead demonstrate the fail-then-pass property
under the SAME contention conditions that originally reproduced it:

1. **Fail proof (pre-fix code, i.e. current `main`/pre-fix `poller_test.exs`
   with the fixed `Process.sleep(300)`):** run the full suite under
   `TEST_PARALLEL_N=8 scripts/test_parallel.sh` (the exact invocation
   ISSUE-FIXER used to reproduce) enough times / or a large enough repeated
   run to observe the AC8 assertion (or a contention-family sibling failure
   in the same describe block) fail at least once. Because this is a timing
   flake, "fails every single time" is not the bar — the bar is
   **reproducing the failure signature under the same load conditions
   ISSUE-FIXER used**, matching what ISSUE-FIXER already did once. If it does
   not reproduce on the first attempt, retry the parallel run (a few
   attempts) rather than declaring the proof inconclusive after one clean
   pass — flakes by nature don't reproduce on every attempt.
2. **Pass proof (post-fix code, with `wait_until/2` in place):** run the
   same `TEST_PARALLEL_N=8 scripts/test_parallel.sh` invocation repeatedly
   (a handful of runs, not just one) and confirm AC8 passes every time. A
   single clean run is weaker evidence for a timing fix than for an
   ordinary logic fix — TEST-RUNNER should run it multiple times (e.g. 3-5
   parallel-suite runs) before reporting the fix as validated, and should
   also run the test in isolation once to confirm it still passes
   standalone (no regression to the non-contended path).
3. Document in the WF-03 handoff which of the two (isolated vs. parallel)
   runs were performed, how many attempts, and the pass/fail outcome of
   each — plain "tests pass" is not sufficient per core-directives' "no
   speculation" rule; the actual command and output must be quoted.

## Open questions

None — this is a small, fully-scoped test-only change. If TEST-RUNNER's
repeated parallel runs (per the fail-then-pass proof above) still show
occasional AC8 failures even with the 2000ms ceiling, that would indicate
contention deeper than what was reproduced during diagnosis and should go
back through ISSUE-FIXER rather than TEST-RUNNER unilaterally raising the
timeout further.
