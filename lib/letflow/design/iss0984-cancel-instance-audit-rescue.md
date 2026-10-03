# ISS-0984 — rescue-harden `run_cancel_instance/5`'s audit raise

Design for closing ISS-0984: `Letflow.Engine.cancel_instance/3`'s private helper
`run_cancel_instance/5` folds `record_instance_cancel_audit/4`'s
`Audit.append_multi/4` call into its own `Ecto.Multi`, runs the whole thing via
`Repo.transaction/1`, and has no `try/rescue` anywhere in its call chain — the same
defect class ISS-0969/ISS-0980/ISS-0981/ISS-0983 have been closing site-by-site, missed
in all four prior rounds for this one site.

## 1. Call-chain tracing (acceptance criterion 1 — independent re-verification)

Re-derived directly against this session's own fresh `origin/main` checkout, same
rigor ISS-0981 §1 and ISS-0983 §1 applied, not taken on the issue filing's or
ISSUE-FIXER's word alone:

- `POST /instances/:id/cancel` → `lib/letflow/routers/instances.ex`'s `handle_cancel/2`
  (line 626) → `Engine.cancel_instance(instance_id, cancel_attrs, opts)` (line 635,
  confirmed by direct read) → `render_cancel(conn, result)`.
- `Letflow.Engine.cancel_instance/3` (`engine.ex:5350-5366`) is a `with`-chain of three
  pure/read-only guards (`cast_instance_id/1`, `fetch_actor_and_idempotency_key/1`,
  `TenantProvisioning.tenant_id_for_schema_name/1` — none of which touch the tables
  this issue is about) that tail-calls `run_cancel_instance/5` as its final `with`
  expression. Whatever `run_cancel_instance/5` returns (or raises) is
  `cancel_instance/3`'s own return (or raise) unchanged.
- `run_cancel_instance/5` (`engine.ex:5395-5465`) builds one `Ecto.Multi` — nine
  `Multi.run`/`Multi.merge` steps (`:open_tasks`, `:timer_cancellations`,
  `:service_task_dispatch_cancellations`, `:instance_projection`, `:eligibility`,
  `:task_cancellations`, `:live_tokens`, `:token_cancellations`, `:event`,
  `:projection`, then a final `Multi.merge` folding in `record_instance_cancel_audit/4`)
  — and runs it via `Repo.transaction()` at line 5463, piping the result into
  `interpret_cancel_result/3` at line 5464.
- `record_instance_cancel_audit/4` (line 5472-5489) calls `Audit.append_multi/4`
  (line 5476) — same shared sink every prior round's fix targets — as one more step
  *inside* this same `Ecto.Multi`, not its own separate transaction.
- `grep -n "rescue" lib/letflow/engine.ex` confirmed against this checkout: the nearest
  `rescue` clauses are the ISS-0981-hardened ones in `run_complete_task/6` (line 2362)
  and the other four ISS-0981 sites (lines 1733, 2899, 3177, 3743) — all textually and
  functionally distant from `cancel_instance/3`'s own line range (5345-5366) and
  `run_cancel_instance/5`'s (5395-5490). Reading both function bodies in full
  confirms neither has a `try` anywhere in its own text.
- **Confirmed live gap.** A genuine Postgres-level audit-write failure (the
  `Postgrex.Error`/`undefined_table` class every prior round's `DROP TABLE
  audit_entries` fault-injection test reproduces) raises straight out of
  `Repo.transaction/1`, out of `run_cancel_instance/5`, out of `cancel_instance/3`'s
  own `with`-tail-call, to `Plug.ErrorHandler`'s cleanup-only passthrough boundary —
  never reaching `render_cancel/2`'s catch-all, because that clause only ever sees a
  *returned* `{:error, _}` tuple.

### Router-side re-verification (independently confirmed, not just restated)

`lib/letflow/routers/instances.ex`'s `render_cancel/2` clauses, read in full
(lines ~639-666):

```
defp render_cancel(conn, {:ok, result}) ...
defp render_cancel(conn, {:error, :invalid_instance_id}) ...
defp render_cancel(conn, {:error, :instance_not_found}) ...
defp render_cancel(conn, {:error, {:instance_already_terminal, :completed}}) ...
defp render_cancel(conn, {:error, {:instance_already_terminal, :cancelled}}) ...
defp render_cancel(conn, {:error, _internal}), do: Response.internal_error(conn)
```

The final clause is a true catch-all — it pattern-matches any `{:error, _}` two-tuple
not already matched above, which structurally includes
`{:error, {:transaction_failed, exception}}` (a two-tuple whose second element is a
three-way-irrelevant term to this clause's own match). **Confirmed: no router change
needed.** This matches ISS-0984's filing note and ISS-0981's `persist/14`/
`run_complete_task/6` precedent (zero router diff) rather than ISS-0983's (seven router
diffs) — because, unlike every ISS-0983 site, this router file already has a catch-all
for this specific handler.

## 2. Fix shape (acceptance criterion 2)

Same shape as ISS-0981 §2's five `engine.ex` sites and `run_complete_task/6` in
particular (closest structural match — a `with`-tail-call delegating to a private
`Multi`-builder, not `cancel_instance/3` itself):

Wrap `run_cancel_instance/5`'s **entire existing body** — the
`Multi.new() |> ... |> Repo.transaction() |> interpret_cancel_result(instance_id,
cancelled_at)` pipe, `engine.ex:5395-5465`, unmodified — in a `try` block, with a
single `rescue exception -> {:error, {:transaction_failed, exception}}` clause. No
line inside the wrapped body changes. `cancel_instance/3` itself is **not** touched —
its own `with`-tail-call to `run_cancel_instance/5` already passes through whatever
2-tuple (or now-never-a-raise) `run_cancel_instance/5` returns, unchanged, exactly as
it does today for every other typed error this function already returns
(`:instance_not_found`, `{:instance_already_terminal, _}`, etc.). This is the ISS-0984
filing's own stated rationale for preferring `run_cancel_instance/5` as the wrap site
over `cancel_instance/3`: the `Multi`/`Repo.transaction` call lives in the private
function, not the public tail-call wrapper.

Because `Repo.transaction()` is not the pipe's final stage — `interpret_cancel_result/3`
runs after it — wrapping the whole body (not just the `Repo.transaction()` call) is the
correct scope: a raise inside `Repo.transaction/1` (whether from a Multi step's own
callback or, here, from `Audit.append_multi/4`'s folded-in `:audit` step) must never
reach `interpret_cancel_result/3` at all. Wrapping only the `Repo.transaction()` call
and leaving `interpret_cancel_result/3` outside the `try` would be equivalent in
practice (a raise still short-circuits before `interpret_cancel_result/3` runs either
way, since `|>` is strict left-to-right), but `try do ... end rescue ... end` reads
most unambiguously when it brackets the function's one and only pipe expression in
full, matching `run_complete_task/6`'s own precedent of wrapping the *entire* body
rather than carving out a sub-expression.

## 3. `@spec` changes (acceptance criterion "cancel_instance/3's and
   run_cancel_instance/5's return unions")

- `cancel_instance/3` already has a `@spec` (line 5345-5349) ending
  `:: {:ok, cancel_result()} | cancel_error()`, and `cancel_error()` (line 5297-5306)
  already ends `| {:error, term()}` — a catch-all that already structurally covers
  `{:error, {:transaction_failed, exception}}` today, so **no `@spec` change is
  strictly required** for correctness. Matching ISS-0981 §2b's own precedent
  (`persist/14`'s `create_error()`), this design still recommends adding an explicit
  `{:error, {:transaction_failed, Exception.t()}}` member to `cancel_error()`'s union,
  for documentation parity with every other hardened site in this arc — not a
  behavior change, a readability one.
- `run_cancel_instance/5` is a private (`defp`) function and, confirmed by direct
  read, has **no existing `@spec` today** — same as every one of ISS-0981's five
  `engine.ex` sites (`persist/14`, `run_complete_task/6`,
  `persist_timer_fired_advance/7`, `persist_escalation_timer_fired_advance/7`,
  `do_persist_service_task_advance/10`), none of which gained a new `@spec` as part
  of that fix (ISS-0981 §5 OQ-2, explicit). Per that same precedent, ELIXIR-DEV must
  **not** add a new `@spec` to `run_cancel_instance/5` as part of this fix — that
  would be a stylistic change outside this issue's scope, same reasoning ISS-0981
  already settled.

## 4. Clean-sweep confirmation (acceptance criterion 4 — for DOC-UPDATER's closure record)

ISSUE-FIXER independently re-ran the full sweep (`grep -n "Audit.append_multi\|
Audit.insert_entry" lib/`) over this checkout and traced every call site other than
this one back to an already-live `rescue` from a prior round:

- ISS-0969's best-effort non-transactional sites (own rescue-and-log shape, not
  `try/rescue` around a `Repo.transaction` — different mechanism, same defect class,
  already closed).
- ISS-0981's five `Letflow.Engine` boundaries (`persist/14`, `run_complete_task/6`,
  `persist_timer_fired_advance/7`, `persist_escalation_timer_fired_advance/7`,
  `do_persist_service_task_advance/10`) plus `Letflow.Definitions.Promotion.
  write_target_definition/5` — all six carry the `try/rescue ->
  {:error, {:transaction_failed, exception}}` shape live today.
- ISS-0980's three best-effort non-transactional sites in
  `routers/tenant_settings.ex`/`routers/instances.ex`/
  `engine/service_task_dispatcher.ex` — already closed.
- ISS-0983's eight `Letflow.Identity`/`Letflow.Repository.Activation`/
  `Letflow.PublicRead` sites — already closed, each with its own router catch-all
  confirmed live.

`run_cancel_instance/5` is the only remaining gap *within this fix's own scope*. One
other gap remains outside this fix's scope, carried forward rather than silently
dropped: `lib/letflow/tasks.ex:639-640`'s `record_task_assign_audit/2` (called from
`assign_task/3` at line 608 and `reassign_task/4`) builds its own `Ecto.Multi` with an
`Audit.append_multi/4` step run via `Repo.transaction()`, and `grep -n "rescue"
lib/letflow/tasks.ex` confirms zero `rescue` clauses anywhere in that 826-line file.
This is not a new discovery — `docs/issues/ISS-0983.yaml` (lines 62-66) already named
and explicitly excluded this exact site as "deliberate... a standing, separate
decision," and `tasks.ex`'s own moduledoc (lines 120-132) says to "revisit as its own
issue if that asymmetry needs closing." ISS-0984 does not change that decision or that
site; it is out of scope for this fix (which is limited to `run_cancel_instance/5`).

**Accurate closure record for DOC-UPDATER:** once this fix lands, the sweep is clean
except for the `tasks.ex` asymmetry ISS-0983 already flagged, unchanged by this round.
This is not the first round in the ISS-0969→ISS-0980→ISS-0981→ISS-0983→ISS-0984 arc to
produce a fully clean sweep — the `tasks.ex` gap predates this fix and remains open,
by standing decision, after it. DOC-UPDATER should record this explicitly in the
closure note: no further same-class issue is expected from this arc's *in-scope* sites
without a *new* call site being added later (e.g. a future `Audit.append_multi/4` or
`Audit.insert_entry/3` call introduced by some later requirement), and the `tasks.ex`
asymmetry remains available to be picked up as its own issue per that file's moduledoc,
exactly as ISS-0983 already recorded.

## 5. Test design (acceptance criterion 3)

### 5.1 Target file and sandbox mode (independently verified, per ISSUE-FIXER's flag)

`test/letflow/engine_cancel_instance_test.exs` is the existing dedicated file
(`describe "AC1"` through `"AC7"` already present). Its own moduledoc states it
"Mirrors `engine_complete_task_test.exs`'s own `provisioned_tenant/0` + Sandbox `:auto`
+ `async: false` pattern exactly" and the file declares `use Letflow.DataCase,
async: false` with no `Letflow.Test.SandboxAutoMode` usage anywhere in it (confirmed:
no reference to that module in this file). This is the **same teardown family**
`test/letflow/engine_test.exs`'s own `"ISS-0969: record_task_activation_rejection_audit/5
is rescue-hardened"` describe block uses (lines 1090-1134 of that file) — that block
also runs under plain `Letflow.DataCase, async: false` with no `SandboxAutoMode`
machinery, and its teardown is a plain `Repo.query!(DROP TABLE ...)` at the start of the
test body, with `on_exit(fn -> Repo.query!(CREATE TABLE ...) end)` recreating the exact
same `audit_entries` DDL immediately after the `DROP TABLE` call. This is **not** the
`audit_capture_test.exs` family, which needs the extra `SandboxAutoMode.provision!/2` +
`SandboxAutoMode.exit_auto_mode!/1` dance specifically because that file's own tests
span more than one logical DB connection/process boundary within a single test
(its own moduledoc comment explains why) — `engine_cancel_instance_test.exs` has no
such need; every one of its existing AC1-AC7 tests runs single-process, single-connection,
exactly like `engine_test.exs`'s ISS-0969 block.

**Conclusion: use `engine_test.exs`'s ISS-0969 teardown pattern** (plain `DROP TABLE` +
`on_exit` `CREATE TABLE` recreate, same DDL as that block's own — `audit_entries` has
one schema, not a per-file variant), **not** `audit_capture_test.exs`'s
`SandboxAutoMode` dance.

### 5.2 New describe block

Add `describe "ISS-0984: run_cancel_instance/5's audit raise is rescue-hardened"` to
`test/letflow/engine_cancel_instance_test.exs`, after the existing `"AC7"` block,
following this file's own established structure (one `provisioned_tenant/0` call,
reuse of this file's own existing `start_instance!/2` + `graph_parallel_split_two_tasks/0`
helpers — no new graph helper needed, matching this file's self-sufficiency convention
and ISS-0981 §4's own "reuse before inventing" discipline).

Scenario, by step (prose only — TEST-DESIGNER writes the actual code):

1. Provision a tenant (`provisioned_tenant/0`).
2. Start an instance via `start_instance!/2` using the file's own existing
   `graph_parallel_split_two_tasks/0` graph (2 concurrently open `HUMAN_TASK` nodes →
   2 `:pending` task rows, 2 live token rows) — the same fixture AC1 already uses, so
   this test's pre-state assertions can mirror AC1's own shape directly.
3. Capture the pre-cancel row state needed for the rollback proof: the 2 task ids and
   their `:pending` status, the 2 token ids and their live status, the
   `instance_projections` row's `:active` status, and the current count of
   `INSTANCE_CANCELLED` events for this instance (zero).
4. `Repo.query!(~s(DROP TABLE "#{schema_name}".audit_entries))`.
5. `on_exit(fn -> Repo.query!(<the same CREATE TABLE audit_entries DDL
   engine_test.exs's ISS-0969 block already uses>) end)` — registered immediately
   after the `DROP TABLE`, before the call under test, matching that block's own
   ordering.
6. Call `Engine.cancel_instance(instance_id, cancel_attrs(), prefix: schema_name)`.
7. Assert the typed return: `{:error, {:transaction_failed, %Postgrex.Error{}}} =`
   the call's result — not `assert_raise`, since the fix's entire point is that this
   no longer raises.
8. Assert full-transaction rollback, mirroring AC1's own post-cancel assertion shape
   but checking the *pre*-cancel state was preserved instead of the post-cancel state:
   - both task rows still `:pending` (not `:cancelled`), `cancelled_at` still `nil`;
   - both token rows still live (not `:cancelled`);
   - the `instance_projections` row still `:active`, `cancelled_at` still `nil`;
   - zero `INSTANCE_CANCELLED` events exist for this instance (the file's own
     `cancelled_events/2` helper, asserting `== []`).

Scope note on `timer_cancellations`/`service_task_dispatch_cancellations`: the
`graph_parallel_split_two_tasks/0` graph used here has no `TIMER` or `SERVICE_TASK`
nodes, so those two `Multi.run` steps execute as structural no-ops (`cancel_pending_timers/5`
and `cancel_pending_dispatches/4` both return `{:ok, 0}` against a `where` clause that
matches zero rows) — there is no `timers` or `service_task_dispatches` row to prove got
rolled back in this particular scenario, because none was ever going to be written
regardless of success or failure. This is a deliberate reuse-over-invention choice
(no existing TIMER/SERVICE_TASK graph helper exists in this file today, and adding one
is unnecessary machinery for a regression test whose only point is proving the audit-step
raise no longer escapes uncaught) — not a coverage gap in the sense ISS-0981 §4 test 1's
"whole version-pointer swap rolled back" proof was guarding against, since the
`:timer_cancellations`/`:service_task_dispatch_cancellations` steps here are genuinely
inert for this graph shape, with or without the fix. If a future reviewer wants explicit
timer/service-task-dispatch rollback proof for this same boundary, that is additional,
separable coverage, not something this regression test needs to carry.

## 6. Open questions

- **OQ-1**: this design does not propose changing `cancel_instance/3`'s own `@spec`
  text beyond the `cancel_error()` type's new documented member (§3) — the function
  signature line itself (`:: {:ok, cancel_result()} | cancel_error()`) is unchanged,
  since the new error shape flows through the existing `cancel_error()` union.
- **OQ-2**: per §3, `run_cancel_instance/5` gets no new `@spec`. If REVIEWER disagrees
  with carrying ISS-0981's OQ-2 precedent forward unchanged, that is a one-line
  correction to apply uniformly across this whole arc's sites, not specific to this
  issue.
