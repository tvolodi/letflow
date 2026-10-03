# ISS-0981 — rescue-hardening six same-transaction `Audit.insert_entry/3` call paths

Design for closing ISS-0981: `Letflow.Definitions.Promotion.write_target_definition/5`
and five `Letflow.Engine` private functions each call `Letflow.Audit.insert_entry/3`
*inside* their own already-open `Repo.transaction/1` (or nested
`repo.transaction(multi)` SAVEPOINT), the same "rolls back cleanly on a typed
`{:error, reason}`" shape `Letflow.Definitions.activate/2`'s
`record_definition_audit/5` call already uses safely — except none of these six call
sites sits inside a function-level `try/rescue`, unlike every one of
`definitions.ex`'s ~10 lifecycle functions. A genuine raise from
`Audit.insert_entry/3` (the same `Postgrex.Error`/`undefined_table` class
ISS-0969's, ISS-0980's, and `audit_capture_test.exs`'s own regression tests already
reproduce via `DROP TABLE audit_entries`) propagates uncaught through
`Repo.transaction/1`, out of the owning context function, out of its router-reachable
caller, to `Plug.ErrorHandler`'s cleanup-only passthrough boundary
(`lib/letflow/plugs/api_pipeline.ex`, same boundary iss0980's design already traced —
it releases an admission ref and re-raises, it does not translate), producing a raw,
unstructured 500 instead of the typed `{:error, {:transaction_failed, exception}}`
every comparable `definitions.ex` lifecycle function already returns in this exact
situation.

## 1. Call-chain tracing (acceptance criteria 1 and 2)

### 1a. `promotion.ex` — both router entry points confirmed live

- `lib/letflow/routers/promotions.ex:614` `handle_apply/2` → `Promotion.apply_review/4`
  → `do_apply_review/3` → `promote_definition/3` → `do_promote_definition/7` →
  `write_target_definition/5`.
- `lib/letflow/routers/tenants.ex:401` `handle_promote/3` → `Promotion.promote_active_definition/5`
  → `do_promote_definition/7` → `write_target_definition/5` (same shared core).

`write_target_definition/5`'s entire body (`lib/letflow/definitions/promotion.ex:386-418`)
is one `Repo.transaction(fn -> ... end)` call with the `Audit.insert_entry/3` call for
`"definition.promote"` inside it (step 8c). `grep -n "rescue" lib/letflow/definitions/promotion.ex`
returns nothing — confirmed, no `try/rescue` anywhere in this file, and neither
`lib/letflow/routers/promotions.ex` nor `lib/letflow/routers/tenants.ex` has one either.
A raise here is genuinely uncaught today. **Live gap, confirmed both paths.**

### 1b. `task_activation.ex`'s `record_task_create_audit/3` — traced to FIVE distinct
`Repo`/`repo.transaction` boundaries, THREE confirmed router-reachable, two more
addressed for defence-in-depth/consistency

`record_task_create_audit/3` (`lib/letflow/engine/task_activation.ex:433-469`) is
called from `do_insert/3`, the single shared insert point for both
`TaskActivation.append_multi/6` and `append_multi_from_existing_records/6`
(confirmed: `grep -n "def append_multi\b\|def do_insert"` — one `do_insert/3`, called
from both public functions' own `Multi.run` callbacks). Both public functions are
pure Multi-builders — "Zero `Repo` calls of its own" is this module's own stated
invariant (moduledoc) — so the actual transaction boundary that can let a raise
escape lives in whichever `lib/letflow/engine.ex` function builds the enclosing
`Ecto.Multi` and calls `Repo.transaction/1` (or `repo.transaction/1`) on it. There are
exactly five such boundaries in `engine.ex` that reach `do_insert/3`
(confirmed via `grep -n "Repo.transaction(\|TaskActivation.append_multi"` and reading
each enclosing function in full):

| # | Boundary function (defp, engine.ex) | Transaction call | Enclosing public fn | Router entry point |
|---|---|---|---|---|
| 1 | `persist/14` (line 1565; `TaskActivation.append_multi/6` call at 1695; `Repo.transaction()` at 1720) | top-level `Repo.transaction/1` | `start_instance/6` ← `create/2` | `POST /instances` (`lib/letflow/routers/instances.ex:545` `handle_create/1`) |
| 2 | `run_complete_task/6` (line 2259; reaches `TaskActivation.append_multi_from_existing_records/6` via `maybe_append_task_activation_multi/7` at line 4640, folded in via `build_task_activation_and_reconciliation_multi/4` at line 4549, merged into the Multi at line 2340ish; `Repo.transaction()` at 2353) | top-level `Repo.transaction/1` | `complete_task/3` | `POST /tasks/:id/complete` (`lib/letflow/routers/tasks.ex:337` `handle_complete/3`) |
| 3 | `persist_timer_fired_advance/7` (line 2722; `TaskActivation.append_multi_from_existing_records/6` call at line 2792; `case repo.transaction(multi) do ... end` at line ~2853) | **nested** `repo.transaction/1` (a real Postgres SAVEPOINT — this function is itself called with the caller's already-open `repo`) | `advance_after_timer_fired/3` ← `Letflow.Scheduler.do_fire/2` ← `Scheduler.fire_timer/2` (its own un-rescued outer `Repo.transaction(fn -> ... end)`, `lib/letflow/scheduler.ex:279`) | `POST /instances/:id/advance-timer` (`lib/letflow/routers/instances.ex:738` `handle_advance_timer/2`, calls `Scheduler.fire_timer/2` directly) — **also** reached from `Scheduler.poll_and_fire/1`'s periodic background tick, not router-driven |
| 4 | `persist_escalation_timer_fired_advance/7` (line 2971; `append_multi_from_existing_records/6` call at line 3091; `case repo.transaction(multi) do ... end` at line ~3153) | same nested-SAVEPOINT shape as #3 | `advance_after_escalation_timer_fired/3` ← same `Scheduler.do_fire/2`/`fire_timer/2` chain (escalation-type timers) | same as #3 |
| 5 | `do_persist_service_task_advance/10` (line 3569; `append_multi_from_existing_records/6` call at line 3629; `case repo.transaction(multi) do ... end` at line ~3690) | same nested-SAVEPOINT shape, this time inside `Letflow.Engine.ServiceTaskDispatcher`'s own already-open `repo.transaction/1` | `advance_service_task_dispatch/4` ← `advance_after_service_task_outcome/4` | **not** router-reachable — `grep -rln "ServiceTaskDispatcher" lib/letflow/routers/` finds no match; this path is driven entirely by `ServiceTaskDispatcher`'s own poll/dispatch-response handling (an internal HTTP client callback, not an inbound Plug route) |

None of these five functions has a `rescue` clause (`engine.ex`'s only two existing
`rescue` clauses, lines 4943/5006, are the unrelated ISS-0969 best-effort audit sites
— textually and functionally distant). **Boundaries #1, #2, #3, #4 are confirmed live
gaps reachable from a real router entry point** (two direct HTTP-request paths for
#1/#2, one shared HTTP-request path — `advance-timer` — plus the periodic scheduler
tick for #3/#4). **Boundary #5 is not confirmed router-reachable** — it is reached
only from `ServiceTaskDispatcher`'s own internal background/webhook-response
processing, so an uncaught raise there crashes whichever OTP process is running that
dispatch cycle (a supervised "let it crash" restart, not a raw HTTP 500) rather than
reaching `Plug.ErrorHandler`. This design still rescue-hardens #5, for the same
reason `definitions.ex` wraps every lifecycle function uniformly rather than only the
ones provably exercised by a given caller today: the defect class (an un-rescued
`Repo.transaction`/`repo.transaction` around a same-transaction `Audit.insert_entry/3`
call) is identical, the fix is the same three-line local wrap with zero blast radius
on any other call path, and leaving #5 as the one asymmetric exception would be the
kind of undocumented inconsistency this whole ISS-0946/ISS-0969/ISS-0980/ISS-0981
arc exists to close. Resolution note for ISS-0981 itself: boundary #5's
router-reachability is explicitly **not confirmed** — call it fixed-for-consistency,
not fixed-because-it-reaches-a-router.

## 2. Fix shape (acceptance criterion 3)

Exactly one shape, applied at six sites — the same function-level `try/rescue`
wrapping shape `Letflow.Definitions.activate/2` already establishes (see that
function, `lib/letflow/definitions.ex`): its entire existing body is wrapped,
unmodified, in a `try` block; a single `rescue exception ->` clause converts any
raised exception into `{:error, {:transaction_failed, exception}}`, reusing the
exact `{:transaction_failed, exception}` tuple shape `activate/2` and its ~9
sibling lifecycle functions already return today — never a new or differently-named
tag. No other line inside any of the six wrapped function bodies changes.

Because in every one of these six functions the `Repo.transaction`/`repo.transaction`
call is either the function's own final expression or the last step of a pipe/`case`
that becomes the function's return value, wrapping the *whole* body has the identical
effect as wrapping only the transaction call, and avoids touching anything
downstream: a raise converts straight into `{:error, {:transaction_failed, exception}}`
as this function's own return value, and no code past the `Repo.transaction` call in
the wrapped function ever runs (not a new branch to reconcile, just the same
short-circuit a raise already causes today, caught one frame earlier instead of
propagating further).

### 2a. `Letflow.Definitions.Promotion.write_target_definition/5`

Wrap the existing `Repo.transaction(fn -> ... end)` call (`promotion.ex:386-418`) in
`try/rescue` exactly as above. `@spec` gains a new error-union member,
`{:error, {:transaction_failed, Exception.t()}}`, alongside the existing
`:duplicate_version | Ecto.Changeset.t() | term()`. No change needed to
`do_promote_definition/7`'s `with` chain — a `{:error, _}` from
`write_target_definition/5` already passes through its final `with`-clause
unmodified, same as today for every other typed error this function can return.

**Propagation, confirmed already correctly handled, no router change needed:**
- `promote_definition/3`'s `case ... {:error, _} = error -> error end` passes it
  through unchanged → `apply_review/4`'s `do_apply_review/3` wraps it as
  `{:error, {:promotion_failed, {:transaction_failed, exception}}}` →
  `lib/letflow/routers/promotions.ex`'s `render_apply/2` already has a catch-all
  clause, `defp render_apply(conn, {:error, {:promotion_failed, _other}}), do:
  Response.internal_error(conn)` — matches as-is.
- `promote_active_definition/5`'s own `with` passes `{:error, {:transaction_failed,
  exception}}` straight through → `lib/letflow/routers/tenants.ex`'s `render_promote/2`
  already has `defp render_promote(conn, {:error, _other}), do: Response.internal_error(conn)`
  — matches as-is.

### 2b. `Letflow.Engine.persist/14` (boundary #1)

Wrap `persist/14`'s entire body (the `Multi.new() |> ... |> Repo.transaction() |>
maybe_snapshot_after_create(...) |> interpret_create_result(...)` pipe,
`engine.ex:1583-1730`) in `try/rescue`. On a raise, `maybe_snapshot_after_create/4`
and `interpret_create_result/8` never run (the raise happens inside
`Repo.transaction/1`, before the pipe can reach them) — `persist/14` returns
`{:error, {:transaction_failed, exception}}` directly. This propagates unchanged
through `start_instance/6`'s own `with`-tail-call and `create/2`'s own `with`-tail-call
to `handle_create/1`, where `render_create/2`'s existing catch-all,
`defp render_create(conn, {:error, _internal}), do: Response.internal_error(conn)`,
already matches it. `create_error()`'s type union already ends `| {:error, term()}`,
so no `@type` change is strictly required; this design recommends adding an explicit
`{:error, {:transaction_failed, Exception.t()}}` member for documentation parity with
`write_target_definition/5`'s own updated spec.

### 2c. `Letflow.Engine.run_complete_task/6` (boundary #2)

Same shape: wrap `run_complete_task/6`'s entire body (`engine.ex:2259-2353`'s
`Multi.new() |> ... |> Repo.transaction() |> maybe_snapshot_after_complete_task(...)
|> emit_task_completed_telemetry(...) |> interpret_complete_result(...)` pipe) in
`try/rescue`. Same reasoning: a raise short-circuits before any of the three
downstream pipe stages run, so `run_complete_task/6` returns
`{:error, {:transaction_failed, exception}}` directly, propagating unchanged through
`complete_task/3`'s own `with`-tail-call to `handle_complete/3`, where
`lib/letflow/routers/tasks.ex`'s existing catch-all,
`defp handle_complete_result({:error, _reason}, conn), do: Response.internal_error(conn)`,
already matches it. **This is the one site with an existing test whose assertion
encodes the pre-fix behavior as expected** — see §3 below, this must be updated, not
just supplemented.

### 2d. `Letflow.Engine.persist_timer_fired_advance/7` (boundary #3)

Wrap the entire function body (`engine.ex:2722-2884`) in `try/rescue`. The function
already returns a plain 2-tuple (`{:ok, changes}` or `{:error, reason}` — its own
`case repo.transaction(multi) do {:ok, changes} -> {:ok, changes}; {:error,
_failed_step, reason, _changes} -> {:error, reason} end`, plus the sibling
`{:execution_error, error_args}` branch), so
`{:error, {:transaction_failed, exception}}` fits its existing return contract
exactly — no caller anywhere up the chain (`advance_after_timer_fired/3`,
`Scheduler.do_fire/2`, `Scheduler.fire_timer/2`) pattern-matches on the *contents* of
the `reason` term, only on the outer `{:ok, _} | {:error, _}` tag. Propagates to
`Scheduler.fire_timer/2`'s own un-rescued `Repo.rollback(reason)` (still inside that
function's own outer `Repo.transaction/1`, which then returns `{:error, reason}` as
its own result, unaffected by this change) and from there to both call sites:
`lib/letflow/routers/instances.ex:738` (`render_advance_timer/4`'s existing catch-all,
`{:error, _reason} -> Response.internal_error(conn)`) and `Scheduler.poll_and_fire/1`'s
generic `{:error, _reason} -> safe_record_fire_failure/2` accounting path (unchanged
tallying behavior, same as any other typed error today).

### 2e. `Letflow.Engine.persist_escalation_timer_fired_advance/7` (boundary #4)

Identical treatment, same file (`engine.ex:2971-~3160`), same reasoning as 2d —
mirrors `persist_timer_fired_advance/7` structurally (per its own comment, "Mirrors
`persist_timer_fired_advance/7`").

### 2f. `Letflow.Engine.do_persist_service_task_advance/10` (boundary #5)

Identical treatment, same file (`engine.ex:3569-~3700`), same reasoning as 2d/2e —
not confirmed router-reachable (see §1b), fixed for defect-class consistency. No
caller up its own chain (`advance_service_task_dispatch/4`,
`advance_after_service_task_outcome/4`, `ServiceTaskDispatcher`'s own callers)
pattern-matches on `reason`'s contents either.

## 3. Existing test that must be UPDATED, not just supplemented

`test/letflow/audit_capture_test.exs`, `describe "AC3 -- an audit-write failure rolls
back the accompanying mutation"`, test `"task completion: a failed audit insert
leaves the task and instance unchanged"` (currently lines ~282-316) **currently
asserts the exact pre-fix bug as correct behavior** — it wraps its own
`Engine.complete_task(...)` call in `ExUnit.Assertions.assert_raise/3`, expecting a
`Postgrex.Error` matching `~r/audit_entries.*does not exist/` to be raised, with an
explanatory comment block stating "Unlike `Definitions.activate/2` ...
`Engine.complete_task/3` has no `try/rescue` of its own today -- an unexpected
DB-level failure ... already propagates as a raised exception, pre-existing behavior
this requirement does not change." That comment and assertion describe exactly the
defect this design fixes. Once `run_complete_task/6` is rescue-hardened (§2c), this
test must be changed to assert `{:error, {:transaction_failed, _exception}} =
Engine.complete_task(...)` instead of `assert_raise`, mirroring the sibling
"definition activation" test immediately above it in the same describe block
(which already asserts `{:error, {:transaction_failed, _exception}} =
Definitions.activate(...)`), and the stale comment explaining why `complete_task/3`
is different must be corrected or removed — it will no longer be true. The two
post-assertions already present (`reloaded_task.status == :pending`,
`projection.status == :active` — confirming nothing committed) stay unchanged;
`Repo.transaction/1`'s rollback-before-the-rescued-raise-propagates-out behavior is
unaffected by adding a `rescue` one frame up — the DB-level rollback already happens
inside `Repo.transaction/1` before the exception reaches this function's own
`rescue` clause, exactly like `activate/2`'s sibling test already demonstrates.

## 4. New regression tests, one per confirmed call path (acceptance criterion 3's
"add a DROP TABLE-style regression test per site"), exact files/describe blocks

All six reuse the exact `Repo.query!(~s(DROP TABLE "#{schema_name}".audit_entries))`
fault-injection technique `test/letflow/audit_capture_test.exs`'s own `"AC3"` describe
block and `test/letflow/engine_test.exs`'s `"ISS-0969: ..."` describe block already
establish — confirmed present in both files by direct read, not assumed.

1. **`write_target_definition/5`** — `test/letflow/definitions/promotion_test.exs`.
   Add a new test to the existing `describe "ISS-0733 GAP A -- audit_entries row"`
   block (same file already builds the two-tenant fixture and the
   `%PromotionReview{}`/`plan` shape this needs, per the
   `"a successful promotion writes one definition.promote audit row"` test
   immediately above it): provision source+target tenants, insert an active source
   definition, `Repo.query!` a `DROP TABLE "#{target_schema}".audit_entries` (the
   TARGET schema — step 8c writes there, per the moduledoc), call
   `Promotion.promote_definition/3` with the same `allow()`/`event_appender`
   fixtures the sibling test uses, assert
   `{:error, {:transaction_failed, %Postgrex.Error{}}} = result`, and assert the
   target schema's `process_definitions` table still has **zero** rows with
   `status: :active` for `process_key` beyond the pre-existing state (i.e. the
   whole version-pointer swap rolled back, not just the audit insert) — mirroring
   `audit_capture_test.exs`'s own "definition activation" test's
   `reloaded.status == :draft` rollback assertion. **Do not** add any post-DROP read
   of `Letflow.Routers.Audit`'s `list_entries/1` — that query path has no rescue of
   its own and would itself raise against the dropped table (the exact mistake
   ISS-0980's design was FAILed for).

2. **`persist/14` (instance creation, boundary #1)** — `test/letflow/audit_capture_test.exs`,
   same `"AC3"` describe block. New test, sibling to the two already there:
   provision a tenant, `DROP TABLE audit_entries` in its own schema *before* calling
   `Engine.create/2` (a minimal single-node or `START -> END` definition is enough —
   `record_instance_create_audit/4`, the M-last step of `persist/14`'s own Multi,
   fires for every `create/2` call regardless of graph shape, so no HUMAN_TASK is
   required to exercise this particular boundary), assert
   `{:error, {:transaction_failed, %Postgrex.Error{}}} = Engine.create(...)`, and
   assert zero `instance_projections`/`tokens` rows exist afterward for that
   instance_id (the M1/M2 inserts rolled back along with the audit failure).

3. **`run_complete_task/6` (task completion, boundary #2)** — same file, same
   describe block: the existing third test (§3 above) already covers this exact
   boundary once its assertion is updated; no separate new test needed here beyond
   that update.

4. **`persist_timer_fired_advance/7` (non-escalation timer fire, boundary #3)** —
   `test/letflow/engine/timer_wiring_test.exs`. New describe block,
   `"ISS-0981: persist_timer_fired_advance/7's task-activation audit raise is
   rescue-hardened"`, following the exact naming convention the file's own
   `"ISS-0969: poll_and_fire/1 does not raise when the task-activation-rejection
   audit write itself fails"` describe block (lines ~956+) already establishes.
   Build the graph via the file's own existing `graph_timer_human_task_end/1`
   helper (TIMER → HUMAN_TASK → END, a *well-formed* `form_schema` — deliberately
   not `graph_timer_then_malformed_form_schema_task_end/2`, since this test needs
   the timer-fire cascade to reach `TaskActivation.append_multi_from_existing_records/6`'s
   own successful insert path, not the `{:invalid_form_schema, _}` rejection branch
   those sibling tests exercise), create the instance, confirm the timer is
   `"pending"`, `DROP TABLE audit_entries`, fire via `Scheduler.poll_and_fire/1`
   (same entry point the file's own `"ISS-0969"` describe block already uses),
   assert `%{errored: 1, fired: 0} = Scheduler.poll_and_fire(schema_name)` (the
   generic-error tally path, same as the sibling `"ISS-0784 site 3"` test two
   describe blocks above already asserts for its own different failure), and
   assert no `tasks` row exists for the HUMAN_TASK node afterward and the timer is
   still `"pending"`, not `"fired"` (the whole nested transaction rolled back).

5. **`persist_escalation_timer_fired_advance/7` (escalation timer fire, boundary
   #4)** — same file, sibling describe block,
   `"ISS-0981: persist_escalation_timer_fired_advance/7's task-activation audit
   raise is rescue-hardened"`. Same technique, built off whichever existing
   escalation-timer graph helper this file already uses for its own escalation
   coverage (an escalation-type TIMER arming a HUMAN_TASK with a well-formed
   `form_schema`) — TEST-DESIGNER must locate and reuse that existing helper
   rather than hand-building a new graph literal, matching this file's own
   stated self-sufficiency convention.

6. **`do_persist_service_task_advance/10` (service-task advance, boundary #5)** —
   `test/letflow/engine/service_task_wiring_test.exs`. New describe block,
   `"ISS-0981: do_persist_service_task_advance/10's task-activation audit raise is
   rescue-hardened"`, following the file's own `"ISS-0969: ..."` naming convention
   (lines ~1902+). Reuse `graph_service_task_then_malformed_form_schema_task_end/2`
   **with a well-formed `form_schema` argument** (the same "pass a valid schema to
   the parameterized malformed-schema helper" reuse this design recommends for
   boundary #4, now applied here) to get a SERVICE_TASK → HUMAN_TASK → END graph
   that reaches the success path, drive it through whichever existing test-server
   dispatch mechanism this file's own `"genuine :advance ... outcomes"` describe
   block already establishes, `DROP TABLE audit_entries` before the dispatch
   resolves, and assert the dispatch's own typed result surfaces
   `{:error, {:transaction_failed, %Postgrex.Error{}}}` (or whatever this file's
   own existing `poll_and_dispatch/1`-adjacent assertion idiom is for a generic
   `{:error, reason}` outcome — TEST-DESIGNER should match the file's own existing
   idiom for reporting a failed dispatch attempt, the same way test 4 above matches
   `timer_wiring_test.exs`'s own `%{errored: _, fired: _}` idiom instead of
   inventing a new one).

## 5. Open questions (explicitly unresolved, not guessed)

- **OQ-1**: boundary #5's router-unreachability (§1b) is this design's own read of
  the current call graph (`grep -rln "ServiceTaskDispatcher" lib/letflow/routers/`
  finds nothing); if ELIXIR-DEV or REVIEWER finds an HTTP-reachable path into
  `ServiceTaskDispatcher`'s poll/dispatch-response cycle this design missed, that
  would promote #5 from "fixed for consistency" to "confirmed live gap" — worth a
  one-line correction to this design's own resolution note, not a blocking issue.
- **OQ-2**: this design does not add a `@spec` to any of the five `engine.ex`
  `defp` functions (none have one today — `persist/14`, `run_complete_task/6`,
  `persist_timer_fired_advance/7`, `persist_escalation_timer_fired_advance/7`,
  `do_persist_service_task_advance/10` are all currently un-`@spec`'d private
  functions, consistent with this file's own existing style for internal Multi
  builders). Only `write_target_definition/5` (promotion.ex) gets an explicit
  `@spec` update, because it already has one. ELIXIR-DEV should not invent new
  `@spec` annotations for the five `engine.ex` functions as part of this fix — that
  would be a stylistic change outside this issue's scope.
