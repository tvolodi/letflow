# REQ-187 — SECURITY-REVIEWER report (Step 2c)

**Verdict: PASS**

Reviewed `git diff main...HEAD` for commit `04bb846` (branch
`feature/WF02-REQ187-20260829`) against
`docs/agents/instructions/security-invariants.md` INV-1..INV-8. Read in full:
`lib/letflow/engine/transition.ex`, `lib/letflow/definitions/graph.ex`,
`lib/letflow/engine.ex` (diff + surrounding unchanged helpers it now calls:
`fetch_and_lock_instance_projection/3`, `fetch_graph/2`, `load_active_tokens/3`,
`load_pending_task_tokens/3`, `reconcile_token_records/5`, `reconcile_projection/5`),
`lib/letflow/engine/task_activation.ex`, `lib/letflow/scheduler.ex`,
`lib/letflow/engine/reconstruction.ex`, and
`lib/letflow/design/req187-timer-engine-wiring.md`.

## Scope test

Applies — this diff adds new Repo-touching data-access paths on tenant-scoped
tables (`timers`, `instance_projections`, `tokens`, `tasks`) via
`TaskActivation.cancel_pending_timers/5`, `Letflow.Engine.advance_after_timer_fired/3`,
and `run_cancel_instance/5`'s new `:timer_cancellations` step.

## INV-1 — Tenant data isolation — APPLIES — PASS

- **Cancellation UPDATE** (`TaskActivation.cancel_pending_timers/5`,
  `lib/letflow/engine/task_activation.ex`): `Letflow.Scheduler.Timer |> where(instance_id ==
  ^instance_id and status == "pending") |> repo.update_all(..., prefix: prefix)`. Both call
  sites (`finalize_instance_projection/5` in `engine.ex`, and `run_cancel_instance/5`'s new
  `:timer_cancellations` step) pass `repo`/`prefix` straight through from their own
  already-validated `Multi.run` closures — never `Letflow.Repo` directly. No cross-tenant
  reach possible.
- **Firing path** (`advance_after_timer_fired/3` and its private helpers
  `build_snapshot_and_state_for_timer/4`, `persist_timer_fired_advance/7`): every query in
  the call graph — `fetch_and_lock_instance_projection/3`, `fetch_graph/2` (via
  `SnapshotStore.get_by_instance_id/2`), `load_active_tokens/3`, `load_pending_task_tokens/3`,
  and the nested `Multi`'s own `reconcile_token_records/5`, `TaskActivation.append_multi_from_existing_records/6`,
  `build_timer_arms_multi/4` → `Scheduler.create/2`, `append_sub_process_children_creation_multi/6`,
  `reconcile_projection/5` — is a verbatim reuse of the exact same helper functions
  `complete_task/3`'s already-reviewed path uses, all taking `prefix` as an explicit argument
  and threading it into every `repo.*(..., prefix: prefix)` call. `Scheduler.do_fire/2` passes
  `tenant_schema` through unchanged as `prefix` on every hop. No query is missing a prefix.
- **Tenant-id provenance** (`Scheduler.create/2`'s `build_arm_changeset/2`, reused
  unmodified by the new `build_timer_arms_multi/4`): `tenant_id` is derived via
  `TenantProvisioning.tenant_id_for_schema_name(prefix)` — resolved from the caller's
  `:prefix`, never accepted as a separate caller-supplied field. Satisfies 0003's addendum.
- (a)/(b)/(c) of INV-1's verify procedure: all three confirmed as above.

## INV-2/INV-3/INV-5 — NOT APPLICABLE

S4 (API/lookup-by-ID surface) and S5 (scripting sandbox) have not started; this diff adds
no route, controller, or scripting host function.

## INV-4 — Secrets by reference only — NOT APPLICABLE

No config/env/secret-resolving code touched by this diff.

## INV-6 — New data-access paths prove their scoping — APPLIES — PASS

This report is that proof.

## INV-7 — No SQL string interpolation — APPLIES — PASS

`grep -rn "Repo.query" lib/ priv/repo/migrations/` shows no hit inside any file this diff
touches; all new/changed queries use `Ecto.Query`/`Ecto.Multi`/`update_all` with bound
params.

## INV-8 — No unhandled crashes on realistic failure paths — APPLIES — PASS

`grep -rn "^\s*{:ok, .*} = "` over the touched files shows one new occurrence introduced by
this diff (`engine.ex`'s `finalize_instance_projection/5`: `{:ok, _count} =
TaskActivation.cancel_pending_timers(...)`), replacing the prior bare `:ok = ...` match at
the same call site. `cancel_pending_timers/5`'s own `@spec` return shape is the single,
non-error tuple `{:ok, non_neg_integer()}` (an `update_all/3` call, which raises rather than
returning an `{:error, _}` tuple on failure) — matching this codebase's existing idiom for
internal calls with a single documented success shape (e.g. `{:ok, %Task{} = task} -> ...`
elsewhere in this same file). Not a new crash risk beyond what already exists.

Every genuine external-I/O/tenant-input boundary in the new code uses typed
`{:ok, _} | {:error, _}` returns threaded through `with`: `prepare_timer_arms/4`,
`advance_after_timer_fired/3`, `persist_timer_fired_advance/7`, `dispatch_timer_fired/4`
(transition.ex), and the new `Reconstruction` replay clause.

## Focused checks from the handoff

- **Nested-transaction (SAVEPOINT) correctness**: `advance_after_timer_fired/3`'s own
  `repo.transaction(multi)` (`persist_timer_fired_advance/7`) runs from inside
  `Scheduler.fire_timer/2`'s already-open `Repo.transaction(fn -> ... end)`, called as an
  ordinary sequential function call (not a `Multi.run/3` callback) with the literal `Repo`
  module. Ecto's SQL adapter nests same-process/same-repo transactions as a real Postgres
  `SAVEPOINT`: on the inner `Multi`'s failure, only the savepoint's work is undone
  (`{:error, failed_step, reason, changes}` → `{:error, reason}`), which propagates as
  `{:error, reason}` through `advance_after_timer_fired/3`'s outer `with` and `do_fire/2`'s
  `with`/`else`, reaching `fire_timer/2`'s outer `case` which calls `Repo.rollback(reason)` —
  rolling back the timer-row flip and the `TIMER_FIRED` event append too. No partial-commit
  path exists: either everything commits (timer flip + event + nested advance) or the
  outer transaction rolls back the whole attempt.
- **Lock-ordering fix**: confirmed in `run_cancel_instance/5` (`lib/letflow/engine.ex`,
  around L2838-2897) — `:timer_cancellations` sits between `:open_tasks` and
  `:instance_projection`, before `:eligibility`. `Scheduler.fire_timer/2` locks `timers`
  first (`fetch_and_lock_timer/2`) and reaches `instance_projections` second (via
  `advance_after_timer_fired/3`'s `fetch_and_lock_instance_projection/3`) — both paths now
  acquire `timers` before `instance_projections`, uniformly, closing the AB-BA deadlock
  hazard CODE-DESIGN-VALIDATOR flagged. `Ecto.Multi`'s all-or-nothing rollback undoes an
  ineligible cancel attempt's timer-cancellation effect when `:eligibility` later fails —
  confirmed by reading the actual step order, not just the design doc.
- **Status-guarded cancellation UPDATE**: `cancel_pending_timers/5`'s `update_all` is scoped
  `WHERE instance_id = ^instance_id AND status = 'pending'` — a row already `"fired"`
  (committed by a concurrent `fire_timer/2`) fails that predicate and is never touched,
  regardless of interleaving. Confirmed by reading the actual `where/3` clause, not the
  moduledoc's description of it.
- **Multiple-timers-per-hop-chain guard**: `prepare_timer_arms/4` (`engine.ex`) checks
  `length(timer_arms) > 1` and returns a typed
  `{:error, {:multiple_timers_in_one_hop_chain_not_supported, node_ids}}` instead of letting
  more than one `{:timer_armed, ...}` reach `build_timer_arms_multi/4` — which would
  otherwise collide on `Scheduler.create/2`'s hardcoded `:scheduler_timer` `Multi` step name
  and raise. All three call sites (`start_instance/5`, `complete_task/3`'s tail,
  `persist_timer_fired_advance/7`) route this through a `with` clause, so the guard's error
  is returned, not raised.
- **No data leakage**: no new response/serialization path is added (no route/controller
  touched, confirmed by `git diff --stat`); the only new payload is the `TIMER_FIRED` event's
  own `node_id`/timestamps (server-internal, unchanged shape from REQ-186's own
  `append_timer_fired_event/4`).

## Conclusion

No BLOCKER found. All applicable invariants (INV-1, INV-4 n/a, INV-6, INV-7, INV-8) pass;
INV-2/INV-3/INV-5 not applicable (stages not started). Routing to REVIEWER (Step 2d).
