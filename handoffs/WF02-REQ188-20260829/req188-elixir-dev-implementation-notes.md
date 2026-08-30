# REQ-188 — ELIXIR-DEV implementation notes (Step 2a)

Implemented exactly per `lib/letflow/design/req188-recurring-timers-and-retention.md`,
no scope beyond it.

## Files changed

- `lib/letflow/scheduler.ex`
  - Added `maybe_rearm_timer/3` (public, per the design's `@spec`) and the
    private `build_rearm_attrs/2` helper.
  - Extended `do_fire/2`'s existing `with` chain with one more step, calling
    `maybe_rearm_timer(timer, now, tenant_schema)` immediately after
    `Letflow.Engine.advance_after_timer_fired/3` succeeds and before
    `do_fire/2` returns `{:ok, :fired}` — still inside `fire_timer/2`'s one
    `Repo.transaction/1`.
  - Added `retention_enabled?/0` (defaults `false`), `retention_interval_ms/0`
    (defaults 86_400_000 = 24h), `retention_days/0` (defaults 90),
    `run_retention_sweep/1` (thin wrapper around `EventStore.archive/1`,
    unconditional — the enable gate lives in the caller), and
    `retention_due?/1` (pure predicate, no DB access).
  - Extended the moduledoc with the two mandated deferral statements (§0 of
    the design): partition_maintenance.zig/partition_retention.zig NOT
    ported (decision 0003 Decision C, ISS-0014 adopted option (a) / rejected
    option (c)), and SCH-04 escalation timers deferred (no
    `escalation_timer_duration` attribute on `:HUMAN_TASK` in
    `lib/letflow/definitions/graph.ex` today).
- `lib/letflow/scheduler/timer.ex`
  - Widened `rearm_changeset/2` to cast the full new-row field set
    (`[:id, :tenant_id, :instance_id, :token_id, :timer_type, :node_id,
    :created_at, :status, :fire_at, :repeat_expression,
    :repeat_interval_us, :repeat_total, :fired_count]`) and added
    `validate_required/2` per the design's exact list (`repeat_total` stays
    optional).
- `lib/letflow/scheduler/poller.ex`
  - Widened `state` from `%{}` to `%{last_retention_run_at: DateTime.t() |
    nil}`, initialized to `nil` in `start_link/1`.
  - `handle_info(:tick, state)` now computes `schemas` once, runs the
    existing timer-poll loop over it, then calls the new private
    `maybe_run_retention_sweep/2` (guarded by `retention_enabled?/0` AND
    `retention_due?/1`, iterating the SAME `schemas` list, calling
    `run_retention_sweep/1` once per schema, updating
    `last_retention_run_at` only when the sweep actually ran) before
    `schedule_next_tick/0`.
  - Moduledoc corrected: the old "no meaningful state carried between
    ticks" sentence is now scoped to the timer-poll loop, with an explicit
    new section documenting the REQ-188 state addition and why it exists.

## Not touched (confirmed by `git diff --stat` / `git status`)

- `lib/letflow/application.ex` — no new child, no changes at all.
- `lib/letflow/definitions/graph.ex` — untouched, escalation timers out of
  scope.
- No route or controller file added or modified.
- No migration added — no schema changes (design §3).

## Verification run this step

- `mix compile --warnings-as-errors` (forced recompile of all 146 `.ex`
  files after touching the three changed files): exit 0, no warnings.
- `mix format --check-formatted` on the three changed files: exit 0.
- `mix test test/letflow/scheduler_test.exs test/letflow/scheduler`: 18
  passed, 0 failed — all pre-existing scheduler tests still pass unchanged
  against the new code (no REQ-188-specific tests exist yet; TEST-DESIGNER
  writes those in a later step per this design's AC list).
- A full `mix test` run was attempted but exceeded the available time
  budget in this environment and was terminated before completion; it was
  not used as evidence of anything and is not being claimed as a pass.

## Flags for SECURITY-REVIEWER / REVIEWER

- `run_retention_sweep/1` passes `prefix: tenant_schema` straight through
  to `EventStore.archive/1` for exactly one schema per call — no
  cross-schema parameter is ever passed, and the `Poller`'s new sweep step
  iterates tenant schemas one at a time, calling `run_retention_sweep/1`
  once per schema (never a single call spanning multiple schemas).
- `retention_enabled?/0`'s default-false path was verified structurally
  (code review) and by the existing scheduler test suite passing
  unaffected; a dedicated "zero `archive/1` calls when disabled" test is
  TEST-DESIGNER's job (design AC 5), not built in this step.
