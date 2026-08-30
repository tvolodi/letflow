# REQ-188 TEST-DESIGNER notes (Step 3)

Full rationale lives in `test/specs/REQ-188.md`. This file is the free-text
supplement for the Step 3b handoff (kept out of the handoff JSON per H6).

## Files

- `test/letflow/scheduler_req188_test.exs` (new) -- SCH-07 recurring re-arm
  ACs 1-4, the moduledoc-deferral-statement check, and the
  `transition.ex`-untouched structural check.
- `test/letflow/scheduler/poller_test.exs` (extended) -- retention runner
  ACs 5-7, alongside REQ-186's own existing `Poller` coverage.
- `test/specs/REQ-188.md` (new) -- full acceptance-criterion -> test-case map,
  including the "why this test, not just a restatement" column and the
  fixture-strategy writeup for the gateway/loop graph.

## Fixture note (read before touching these files again)

Firing a recurring timer more than once through the REAL engine requires the
token to return to a `:TIMER` node after every firing (`Engine.Transition`'s
`dispatch_timer_fired/4` errors `{:token_not_at_timer, ...}` otherwise). A
bare `:TIMER` self-loop is rejected by `Letflow.Definitions.Graph`'s CHK-06
cycle check (`:cycle_without_gateway`). `graph_gateway_loop/1` in both test
files uses a 2-node cycle through an `EXCLUSIVE_GATEWAY` instead, which CHK-06
permits, and which does NOT trigger REQ-187's own separate TIMER->TIMER
auto-rearm mechanism (verified empirically, not just reasoned about -- see
below).

## Mutation testing -- real output

Five mutations, applied one at a time to the committed
`lib/letflow/scheduler.ex` / `lib/letflow/scheduler/poller.ex`, each run
against the relevant new test file, then reverted via `git checkout --`
(confirmed clean via `git diff --stat` after each revert, and again after all
five, shown at the bottom).

### Mutation 1 -- anchor `fire_at` to the actual firing time instead of the scheduled one

```
-      fire_at: DateTime.add(fired_timer.fire_at, fired_timer.repeat_interval_us, :microsecond),
+      fire_at: DateTime.add(DateTime.utc_now(), fired_timer.repeat_interval_us, :microsecond),
```

`mix test test/letflow/scheduler_req188_test.exs` result: `6/8 passed`, 2
failures:
- `AC1: ... creates exactly one new pending timer with fire_at = fired timer's fire_at + 1 hour`
- `AC2: an R3/PT1H timer stops re-arming after its third firing ...` (also
  broke, since the drifted `fire_at` values land in the future and the 3
  cycles no longer complete within the test)

### Mutation 2 -- remove the `repeat_total` cap check

```
-    if fired_timer.repeat_total != nil and new_fired_count >= fired_timer.repeat_total do
+    if false do
```

`mix test test/letflow/scheduler_req188_test.exs` result: `7/8 passed`, 1
failure: `AC2: an R3/PT1H timer stops re-arming after its third firing ...`
(recurring-row count no longer stays at 3 after the 4th poll).

### Mutation 3 -- flip `retention_enabled?/0`'s default to `true`

```
-  @default_retention_enabled false
+  @default_retention_enabled true
```

`mix test test/letflow/scheduler/poller_test.exs` result: `5/7 passed`, 2
failures (both AC5 tests -- the old, otherwise-eligible seeded event no
longer survives a tick with no config set).

### Mutation 4 -- skip the `retention_due?/1` gate in `Poller.maybe_run_retention_sweep/2`

```
-    if Scheduler.retention_enabled?() and Scheduler.retention_due?(state.last_retention_run_at) do
+    if Scheduler.retention_enabled?() do
```

`mix test test/letflow/scheduler/poller_test.exs` result: `6/7 passed`, 1
failure: `AC6: ... retention_due?/1 gates a second tick from re-sweeping
before its own interval elapses` (a second event, seeded old enough to be
archived if the guard re-swept early, gets swept before the configured
24h interval elapses).

### Mutation 5 -- move the re-arm insert off the caller's transaction (fire-and-forget via `Task.async`/`Task.await`, a separate connection)

```
-      %Timer{}
-      |> Timer.rearm_changeset(attrs)
-      |> Repo.insert(prefix: tenant_schema)
-      |> case do
+      task =
+        Task.async(fn ->
+          %Timer{}
+          |> Timer.rearm_changeset(attrs)
+          |> Repo.insert(prefix: tenant_schema)
+        end)
+
+      case Task.await(task) do
```

`mix test test/letflow/scheduler_req188_test.exs` result: `7/8 passed`, 1
failure: `AC1: re-arm runs in the SAME transaction as the firing (INV-REARM-1)
forcing the firing transaction to roll back leaves neither the status change
nor the new timer persisted` -- this is the mutation the AC1b
outer-transaction-rollback test exists specifically to catch (a `Task`
running on its own process/connection is not nested inside the caller's
Sandbox-shared transaction the way a same-process `Repo.insert/2` call is,
so its effect is not reliably undone by the outer test's forced rollback).

## Post-mutation-testing clean state

```
$ git diff --stat -- lib/letflow/scheduler.ex lib/letflow/scheduler/timer.ex lib/letflow/scheduler/poller.ex
$ git status --porcelain
 M test/letflow/scheduler/poller_test.exs
?? test/letflow/scheduler_req188_test.exs
?? test/specs/REQ-188.md
```

(the two `git diff --stat`/`git status` outputs above were captured with zero
lines for the three implementation files -- clean.)

## Final verification (post-revert, before commit)

```
$ mix compile --warnings-as-errors
(no output -- clean)

$ mix test test/letflow/scheduler_test.exs test/letflow/scheduler/poller_test.exs test/letflow/scheduler_req188_test.exs
...
Finished in 17.6 seconds (0.00s async, 17.6s sync)
Result: 32 passed

$ mix format --check-formatted test/letflow/scheduler_req188_test.exs test/letflow/scheduler/poller_test.exs
(no output -- already formatted)
```
