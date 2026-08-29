# RELEASE-VALIDATOR report — REQ-187

**Verdict: PASS.** All 10 acceptance-criteria groups independently re-derived
against the real code and a fresh test run, not against any prior agent's
report narrative.

## What I did, independently

- Read `lib/letflow/engine/transition.ex` in full (1053 lines).
- Read the relevant sections of `lib/letflow/engine.ex`: `start_instance/5`,
  `prepare_timer_arms/4`, `resolve_timer_arm_attrs/4`, `build_timer_arms_multi/4`,
  `persist/11`, `advance_after_timer_fired/3`, `build_snapshot_and_state_for_timer/4`,
  `dispatch_timer_fired_hop_chain/1`, `persist_timer_fired_advance/7`,
  `finalize_instance_projection/5`'s `:completed` clause, `cancel_instance/3`,
  `run_cancel_instance/5`.
- Read `lib/letflow/engine/task_activation.ex`'s `cancel_pending_timers/5`.
- Read `lib/letflow/scheduler.ex`'s `fire_timer/2`, `do_fire/2`, `attempt_fire/2`,
  `fetch_and_lock_timer/2`, `poll_and_fire/1`'s due-timer query.
- Ran `git diff --stat main...HEAD` and a targeted diff of `engine.ex`'s
  `cancel_pending_timers` call site to confirm AC4's "call site unmoved" claim
  directly, not by trusting the narrative.
- Re-ran, myself, in the foreground: `mix compile --warnings-as-errors` (clean,
  0 output), `mix test` on the 5 REQ-187-touched files (81 passed: 1 property,
  80 tests — exact match to every prior report), the full suite via
  `scripts/test_parallel.sh` (8 partitions: **2552/2555 passed, 3 failures**,
  all 3 in the documented pre-existing/environmental category — 2x
  `Mix.Tasks.Letflow.CheckToolchainTest` rust-pin tests failing on `rustc`
  `:enoent` (no Rust toolchain in this sandbox) and 1x
  `Letflow.Engine.Wasm.PluginHandlerTest` AC7 wasmex-Rust-NIF-source check;
  the previously-reported 4th failure, the Lua wall-clock-timing flake in
  `executor_test.exs`, did not reproduce this run — consistent with it being a
  timing flake, not a regression, and its absence is not evidence of anything
  either way), `mix format --check-formatted` (exit 0, clean), and
  `mix letflow.lint_handoffs` (OK, 0 new violations, 25 pre-existing
  grandfathered — same count TEST-RUNNER reported).
- Read `test/letflow/engine/timer_wiring_test.exs`'s AC2, AC3, AC4, AC5, AC6,
  multi-timer-guard, AC7, and AC8 `describe` blocks directly to confirm the
  tests are real, non-vacuous, DB-backed checks, not renamed no-ops.

## Per-criterion findings

1. **TIMER arming** — CONFIRMED. `transition.ex:323-325`'s `dispatch_node`
   clause for `:TIMER` now calls `dispatch_timer_arrival/3`, which returns
   `{:timer_armed, token_id, node_id}` (line 583) instead of falling through
   to the old catch-all. `engine.ex`'s `prepare_timer_arms/4` (line 624) and
   `resolve_timer_arm_attrs/4` (line 664) compute `fire_at` as `arrival + parsed
   duration_iso8601` via `Graph.parse_iso8601_duration/1` and
   `DateTime.add(now, seconds, :second)`. `timer_wiring_test.exs`'s AC1
   `describe` block (line 236) asserts exactly one pending timers row with the
   correct `fire_at`.

2. **One transaction (arm + event)** — CONFIRMED by reading `persist/11`
   (`engine.ex:954-1029`): the `Multi.merge` that calls `build_timer_arms_multi/4`
   (line 993-1004) sits *before* the `Multi.run(:event, ...)` step (line 1018),
   inside the same `Multi.new() |> ... |> Repo.transaction()` pipeline. AC2's
   test (line 294) forces the event append to fail (missing `:actor_id`) and
   asserts `timer_count == 0` — passed in my own run.

3. **Firing advances the token** — CONFIRMED. `advance_after_timer_fired/3`
   (`engine.ex:1774`) dispatches `{:timer_fired, token_id}` through
   `Transition.transition/3` (via `dispatch_timer_fired_hop_chain/1`, which
   itself calls `advance_until_stable/4`) and persists via
   `persist_timer_fired_advance/7`. `Scheduler.do_fire/2` (`scheduler.ex:219`)
   calls this inside `fire_timer/2`'s already-open transaction (a real nested
   Postgres SAVEPOINT via `repo.transaction(multi)` inside `persist_timer_fired_advance/7`).
   AC3's TIMER→END and TIMER→TIMER→END tests (both real, DB-backed) passed.

4. **Completion cancels pending timers, call site unmoved** — CONFIRMED via
   direct `git diff` read: the old `:ok = TaskActivation.cancel_pending_timers(instance_id, prefix)`
   line inside `finalize_instance_projection/5`'s `:completed` clause is
   replaced *in place* by the new 5-arg call, still immediately after
   `repo.update(prefix: prefix)` inside the same `case` branch — not relocated
   to a different function or transaction. `timer_wiring_test.exs`'s AC4
   structural test (line 416) independently re-derives this via `File.read!`
   + byte-offset ordering, which I read and consider genuine (not vacuous).

5. **Cancellation cancels pending timers atomically, rollback leaves pending**
   — CONFIRMED. `run_cancel_instance/5` (`engine.ex:2838`) has a
   `Multi.run(:timer_cancellations, ...)` step (line 2843) calling
   `TaskActivation.cancel_pending_timers/5`. AC5's forced-`:event`-failure test
   (line 466, idempotency key too long) asserts the timer stays `"pending"`
   after rollback — I read this test and it is a real, non-mocked DB check.

6. **Fired timer untouched by cancellation / no pending timer of a terminal
   instance is ever fired** — CONFIRMED by two independent mechanisms read
   directly: `cancel_pending_timers/5`'s `update_all` is scoped
   `WHERE status == "pending"` (`task_activation.ex:364`), so a row already
   `"fired"` is structurally untouched by any later cancellation; and
   `Scheduler.poll_and_fire/1`'s due-timer query itself filters
   `t.status == "pending"` (`scheduler.ex:185`), plus `fire_timer/2` re-checks
   `status != "pending" -> {:ok, :already_final}` after taking the row lock
   (`scheduler.ex:206`) — a timer whose instance was cancelled/completed
   (hence itself flipped to `"cancelled"` in the same atomic commit) is never
   selected by a later poll and never fired.

7. **transition.ex has zero Repo calls** — CONFIRMED by my own fresh grep:
   `grep -n "Repo\.\|Logger\.\|DateTime\.\|System\.os_time\|System\.system_time\|HTTPoison\|Req\.\|File\.\|:rand\.\|:crypto\."`
   across `instance_state.ex`, `token.ex`, `transition.ex` returns only the
   moduledoc's own documentation text (the grep command itself, quoted as a
   string), zero real code matches. The moduledoc's "Purity (AC1)" section
   explicitly names the extended `pending_event()`'s 4th variant
   (`{:timer_armed, ...}`) as the carrier, matching AC7's wording exactly.

8. **No route/controller file added** — CONFIRMED: `git diff --stat main...HEAD`
   touches only `lib/letflow/engine.ex`, `lib/letflow/engine/{transition,task_activation,reconstruction}.ex`,
   `lib/letflow/scheduler.ex`, `lib/letflow/definitions/graph.ex`, the design
   doc, and test files. No `lib/letflow_web/**` or router file appears.

9. **mix test / mix compile --warnings-as-errors** — CONFIRMED with real,
   freshly-run output (see above): compile clean; full suite 2552/2555, 3
   pre-existing/environmental failures, none touching this diff.

10. **Multi-timer-in-one-hop-chain guard** — CONFIRMED. `prepare_timer_arms/4`
    (`engine.ex:637-639`) returns
    `{:error, {:multiple_timers_in_one_hop_chain_not_supported, node_ids}}`
    when more than one `{:timer_armed, ...}` pending event appears in one
    hop-chain, instead of proceeding to `build_timer_arms_multi/4` where a
    duplicate `:scheduler_timer` Multi step name would raise. The dedicated
    regression test (line 592) wraps the call in `try/rescue` and asserts the
    typed error, never a raise — I read this test directly and it is genuine.

## Lock-ordering fix (explicitly flagged as most fragile)

Read `run_cancel_instance/5` (`engine.ex:2838-2897`) directly: the real,
current Multi order is `:open_tasks` → `:timer_cancellations` →
`:instance_projection` → `:eligibility` → `:task_cancellations` →
`:live_tokens` → `:token_cancellations` → `:event` → `:projection`. The
`:timer_cancellations` step sits between `:open_tasks` and
`:instance_projection`, exactly as claimed by every prior report — confirmed
by my own read of the source, not by trusting TEST-DESIGN-VALIDATOR's or
TEST-RUNNER's summary. The inline comment (lines 2844-2859) correctly states
the rationale (uniform timers-before-instance_projections lock order, matching
`fire_timer/2`'s own order, avoiding an AB-BA deadlock). The structural test
at line 502 re-derives this ordering via `File.read!` + `:binary.match`
byte-offset comparison, scoped to `run_cancel_instance/5`'s own body — I read
this test and consider it a genuine, non-vacuous structural check.

## Conclusion

No gap found. All 10 acceptance criteria (including REVIEWER's added
multi-timer-guard item) hold against the actual shipped code and a fresh,
independently-run test suite. Routing to DOC-UPDATER (Step 6) to flip
REQ-187's status to `done`.
