# REQ-187 — TEST-DESIGNER notes

**Artifacts produced:**
- `test/letflow/engine/timer_wiring_test.exs` (new, 18 tests) — DB-level
  integration coverage for AC1-AC6, AC8, REVIEWER's own multi-timer-guard
  regression item, and the Reconstruction/TIMER_FIRED replay-parity check.
- `test/specs/REQ-187.md` (new) — full AC-to-test traceability table,
  per-test rationale, and the mutation-testing evidence below.

**Deliberately not duplicated:** the pure-kernel half of AC1/AC3/AC6
(`transition.ex`'s own `:TIMER` dispatch clauses) is already covered by
`test/letflow/engine/transition_test.exs`'s `"transition/3 -- :TIMER
entry/fired"` describe block (ELIXIR-DEV's own mechanical update). Read that
file's relevant section, plus `task_activation_test.exs`'s
`"cancel_pending_timers/5"` block, `scheduler_test.exs`'s full moduledoc/AC9,
and `scheduler/poller_test.exs`, before writing anything new — confirmed no
overlap before adding tests.

**Mutation testing (4 mutations, all caught, all reverted):**
1. `task_activation.ex` `cancel_pending_timers/5` — removed the
   `t.status == "pending"` guard. Caught by the "fired timer untouched by a
   later cancellation" test.
2. `engine.ex` `persist/11` — skipped appending the timer row (`[]` in place
   of `prepared_timers`) in the create-path `Multi.merge`. Caught by 11/18
   tests (AC1's own "exactly one pending row" tests, most directly).
3. `engine.ex` `run_cancel_instance/5` — moved `:timer_cancellations` back to
   its pre-fix, topically-grouped position (after `:eligibility`). Caught
   ONLY by the dedicated structural lock-ordering test (source-position
   check) — no other test in the file distinguishes the two positions in a
   single Postgres connection, confirming that structural test earns its
   place rather than duplicating the rollback test.
4. `engine.ex` `prepare_timer_arms/4` — replaced the `length(timer_arms) > 1`
   guard with `false`. Caught by the multi-timer-guard test — `Engine.create/2`
   raised (`Ecto.Multi`'s own duplicate-step-name check) instead of
   returning the typed error.

After each mutation, `git diff --stat lib/` was confirmed clean following
`git checkout -- <file>` — the implementation files are byte-identical to
the committed tree TEST-DESIGNER started from.

**`mix test test/letflow/engine/timer_wiring_test.exs`: 18 passed.**
Full compile (`mix compile --warnings-as-errors`): clean, zero warnings.
Combined run with the 4 pre-existing REQ-187-touched test files
(transition_test.exs, task_activation_test.exs, scheduler_test.exs,
scheduler/poller_test.exs) plus this new file: 81 passed (1 property, 80
tests), zero failures, zero regressions.

**Forced known-scenario design note (AC4):** design doc §5.2 argues (and my
own analysis independently confirms) that `finalize_instance_projection/5`'s
`:completed` clause can never organically observe a pre-existing `'pending'`
timer for the same instance via any reachable `create/2` call — a
`:TIMER`-parked token always keeps `remaining_tokens` non-empty, so the
instance can never reach `:completed` in the same hop-chain a sibling timer
was armed in. Rather than manufacture a test with nothing real to fail
against, AC4 is covered by (a) a real-DB call into the exact production
`cancel_pending_timers/5` function with the exact params/reason string that
call site uses, and (b) a source-text structural check confirming the call
site itself is still there, unmoved, in the right clause. See test/specs
for the full rationale.
