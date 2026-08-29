# REQ-187 implementation notes (ELIXIR-DEV, Step 2a)

Implemented exactly per `lib/letflow/design/req187-timer-engine-wiring.md`
and the Step 2a handoff's task description (including the CODE-DESIGN-VALIDATOR's
required defensive-guard addition). Commit `04bb846` on
`feature/WF02-REQ187-20260829`.

## Files changed

- `lib/letflow/engine/transition.ex` -- new `{:timer_armed, token_id, node_id}`
  `pending_event()` variant, new `{:timer_fired, token_id}` `transition_event()`,
  new `{:token_not_at_timer, ...}` `transition_error()`, new
  `dispatch_timer_arrival/3` (`:TIMER` dispatch clause) and
  `dispatch_timer_fired/4` (reuses `advance_off_completed_node/4` unchanged).
  Catch-all comment corrected to name only `:SERVICE_TASK`. Moduledoc's
  Purity section gained one sentence naming the extended shape. **Zero**
  `Repo`/clock calls added -- verified via the moduledoc's own documented
  grep.
- `lib/letflow/definitions/graph.ex` -- new public `parse_iso8601_duration/1`,
  sharing `valid_iso8601_duration?/1`'s grammar validation, with a parallel
  `scan_duration_seconds/3-4` accumulator pass using the fixed-length
  calendar convention the design flags (Y=365d, M(date)=30d, W=7d, D=1d,
  H=3600s, M(time)=60s, S=1s).
- `lib/letflow/engine.ex` -- new `prepare_timer_arms/4` (shared by both
  `start_instance/5` and `complete_task/3`'s completion tail, and by
  `advance_after_timer_fired/3`'s own nested persist step), including the
  CODE-DESIGN-VALIDATOR's required guard: more than one `{:timer_armed,
  ...}` entry in one hop-chain returns
  `{:error, {:multiple_timers_in_one_hop_chain_not_supported, node_ids}}`
  instead of reaching `Scheduler.create/2` twice with its hardcoded
  `:scheduler_timer` Multi step name. New `build_timer_arms_multi/4`.
  `persist/11` -> `persist/12` (new `prepared_timers` param) gains a
  `Multi.merge/2` step after `:token_record`, before
  `TaskActivation.append_multi`. `dispatch_task_completion_hop_chain/6` ->
  `/7` (new `completed_at` param, reused as the timer-arm arrival
  timestamp) now also calls `prepare_timer_arms/4` alongside
  `prepare_sub_process_children_for_completion/7`, widening the
  `{:advanced, ...}` tuple to 4 elements; `build_complete_task_tail_multi/6`
  and `interpret_complete_result/1` updated to match the new 4-tuple shape.
  `finalize_instance_projection/5`'s `:completed` clause's
  `TaskActivation.cancel_pending_timers` call updated in place (line
  position unmoved) to the new `/5` arity. `run_cancel_instance/5` gains
  `:timer_cancellations` between `:open_tasks` and `:instance_projection`
  (the lock-ordering fix). New `advance_after_timer_fired/3` (`@doc false`)
  plus its own private helpers (`build_snapshot_and_state_for_timer/4`,
  `find_token_for_timer/2`, `dispatch_timer_fired_hop_chain/1`,
  `persist_timer_fired_advance/7`), reusing `fetch_and_lock_instance_projection/3`,
  `fetch_graph/2`, `load_active_tokens/3`, `to_pure_token/1`,
  `load_pending_task_tokens/3`, `build_instance_state/3`,
  `tokens_needing_dispatch/3`, `advance_until_stable/4`,
  `reconcile_token_records/5`, `TaskActivation.append_multi_from_existing_records/6`,
  `prepare_sub_process_children_for_completion/8`,
  `append_sub_process_children_creation_multi/6`, and `reconcile_projection/5`
  unchanged.
- `lib/letflow/engine/task_activation.ex` -- `cancel_pending_timers/2` (no-op)
  replaced by `cancel_pending_timers/5`, a real status-guarded
  `repo.update_all(WHERE status = 'pending', ...)`.
- `lib/letflow/scheduler.ex` -- `do_fire/2` gains a third `with` clause
  calling `Letflow.Engine.advance_after_timer_fired/3`, still inside
  `fire_timer/2`'s own open transaction. `attempt_fire/2` gains
  `{:error, {:instance_not_active, _}} -> :already_final`, matched before
  the generic `{:error, _reason}` catch-all.
- `lib/letflow/engine/reconstruction.ex` -- new `apply_event/3` clause for
  `"TIMER_FIRED"` (mirrors `"TASK_COMPLETED"`'s position-match shape), new
  `dispatch_timer_fired/3` private helper mirroring `dispatch_task_completion/3`.
  Moduledoc's "five event types" note updated to six.

No route, controller, or migration file was added or modified.
`lib/letflow/dlq.ex` was not touched. REQ-056's SERVICE_TASK HTTP-abort
deferral was not touched.

## Pre-existing tests updated (and why)

These are direct, mechanical consequences of REQ-187's own named scope
(closing the three stubs) -- not new-coverage authoring, which remains
TEST-DESIGNER's job at Step 3:

- `test/letflow/engine/transition_test.exs` -- the old catch-all test
  asserted `:TIMER` still returned `{:error, {:node_type_not_yet_implemented,
  ...}}`; updated to remove `:TIMER` from that list (mirroring the existing
  `:SUB_PROCESS`-left-the-catch-all precedent in the same file) and added a
  new `"-- :TIMER entry/fired"` describe block with 3 focused tests.
- `test/letflow/engine/task_activation_test.exs` -- the old
  `cancel_pending_timers/2` describe block asserted the removed function's
  no-op `:ok` return and its old `@doc` text; replaced with a doc-string
  assertion against the new `/5` function (full DB-level behavioral
  coverage of the real UPDATE already lives in `test/letflow/engine_test.exs`-style
  integration tests per this file's own moduledoc convention, and is
  TEST-DESIGNER's job to expand for REQ-187 specifically).
- `test/letflow/scheduler_test.exs` and `test/letflow/scheduler/poller_test.exs`
  -- both files' shared minimal fixture graph had its `task` node's type
  changed from `:HUMAN_TASK` to `:TIMER` (with a far-future
  `duration_iso8601` so each file's own automatic REQ-187 timer-arm never
  interferes with that file's own manually-armed test timers), and a new
  `live_token_id!/2` helper plus `token_id:` overrides were added to the
  handful of `arm_timer!`/`Scheduler.create` calls that need a timer to
  actually *fire* successfully -- REQ-187 wires firing through
  `Letflow.Engine.advance_after_timer_fired/3`, which needs a real live
  `TokenRecord` matching the timer's own `token_id` to find and advance;
  REQ-186's own pre-REQ-187 tests never needed this because firing used to
  stop at flipping the timer row's status and appending the event.

## Verification performed

- `mix compile --warnings-as-errors` -- clean (`Generated letflow app`, no
  warnings).
- `mix format --check-formatted` -- clean.
- `grep` for `Repo\.`/`Logger\.`/`DateTime\.`/etc. in
  `lib/letflow/engine/{instance_state,token,transition}.ex` -- zero matches
  outside `transition.ex`'s own moduledoc prose (which quotes the grep
  command itself).
- Full `mix test` suite (run in 3 sequential chunks due to sandbox time
  limits) -- all failures observed are pre-existing and confirmed via
  `git stash` to fail identically on the pre-REQ-187 baseline in this
  sandbox: one Wasm NIF-resolution test
  (`Letflow.Engine.Wasm.PluginHandlerTest` AC7) and two rustc-toolchain-pin
  tests (`Mix.Tasks.Letflow.CheckToolchainTest`, `rustc` binary not present
  in this sandbox). Every test touching REQ-187's own changed code paths
  passes.
