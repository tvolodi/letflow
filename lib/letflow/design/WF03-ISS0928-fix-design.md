# WF-03 Fix Design -- ISS-0928 / Q-928

Run-id: WF03-Q928-20261001
Branch: fix/ISS-0928-parallel-fork-service-task-Q928
Type: backend bug fix (engine error routing) plus one QA fixture correction.
Source of truth for root cause: `handoffs/WF03-Q928-20261001/step-01-issue-fixer-diagnose.json`
(not re-derived here; code references below were re-read on this branch and confirmed).

## 0. Reframing (what the issue actually is)

The filed hypothesis ("a SERVICE_TASK inside a PARALLEL_GATEWAY fork is never dispatched")
is disproved. The fork-branch SERVICE_TASK is armed and dispatched correctly. The real
defect is independent of PARALLEL_GATEWAY:

* `Letflow.Engine.persist_service_task_advance/10` (`lib/letflow/engine.ex`, error arms at
  ~L3374-3379) returns a bare `{:error, {:transition_failed, reason}}` when the hop chain
  that follows a completed SERVICE_TASK hits `{:activation_failed, {:no_matching_edge,
  node_id, evaluated_conditions}}` (an EXCLUSIVE_GATEWAY with no matching condition and no
  default edge).
* `advance_after_service_task_outcome/4` runs `advance_service_task_dispatch/4` inside its
  own `repo.transaction/1` and turns that error into `repo.rollback/1`.
* The dispatch row was already committed `"advanced"` by `ServiceTaskDispatcher.handle_success/3`
  in a separate earlier transaction (documented, deliberate gap at engine.ex ~L3195-3205),
  so the poller never re-claims it.
* `ServiceTaskDispatcher.call_advance_after_service_task_outcome/3` (L614 catch-all arm)
  returns the error unchanged and `fold_attempt_result/2` drops it uncounted, with no log
  and no audit.

Net: token parked at the SERVICE_TASK node, instance ACTIVE forever, no task, no
SERVICE_TASK_COMPLETED, no EXECUTION_ERROR, no DLQ row. The human-task completion path
(`dispatch_task_completion_hop_chain/7`, engine.ex ~L3857 and ~L3876) already unwraps both
`{:activation_failed, {:no_matching_edge, ...}}` and `{:no_matching_edge, ...}` into
`{:ok, {:execution_error, error_args}}` with `error_type: :no_matching_gateway_edge`; the
service-task re-entry path never got that treatment.

A second, separate cause in the Meridian QA fixture makes the scenarios unable to complete
even after the engine fix (section 5).

ISS-0928's title/description should be reframed by ORCH to the real cause (ORCH-owned, not
part of this design's file list beyond the docs entries named in section 8).

## 1. Item 1 -- ExecutionError routing in `persist_service_task_advance/10`

### 1.1 Behavior change

In `persist_service_task_advance/10`, the two error arms must classify as follows:

| Hop-chain result | Today | After fix |
|---|---|---|
| `Transition.advance_off_completed_node` returns `{:error, {:no_matching_edge, node_id, evaluated}}` | `{:error, {:transition_failed, _}}` | execution-error path (below) |
| `advance_until_stable` returns `{:error, {:activation_failed, {:no_matching_edge, node_id, evaluated}}}` | `{:error, {:transition_failed, _}}` | execution-error path (below) |
| any other `{:error, reason}` (hop limit, unknown node, etc.) | `{:error, {:transition_failed, reason}}` | unchanged shape; now made non-silent by item 2 |

Both `no_matching_edge` shapes are handled (mirroring the two arms of
`dispatch_task_completion_hop_chain/7`), because `advance_off_completed_node/4` can itself
surface the immediate-successor case.

### 1.2 error_args shape (identical to the human-task path)

`ExecutionError.error_args()`:

* `instance_id`: `projection.instance_id` (the dispatch row's instance; never caller input)
* `error_type`: `:no_matching_gateway_edge`
* `affected`: `{:node, node_id}` where `node_id` is the GATEWAY node reported by the error
  (e.g. `"kyc-routing"`), not the SERVICE_TASK node
* `reason`: the same literal sentence the human path uses: "no outgoing edge matched
  conditions and no default edge configured for gateway node '<node_id>'"
* `variables`: `state_with_merged_variables.variables` (the VariableMerge output that
  includes the HTTP response body keys, so the error record shows why the gateway failed)
* `details`: `%{evaluated_conditions: evaluated_conditions}`
* `actor_id`: `EventStore.platform_actor_id()`
* `idempotency_key`: `"service_task_dispatch:<dispatch.id>"` (the same key
  `do_persist_service_task_advance/10` uses; see 1.5 for why this cannot collide)

The three call sites that build this map (two in `dispatch_task_completion_hop_chain/7`,
one new) must share one private builder so the shape cannot drift:

    build_no_matching_gateway_edge_error_args(
      instance_id :: Ecto.UUID.t(),
      node_id :: String.t(),
      evaluated_conditions :: term(),
      variables :: map(),
      actor_id :: Ecto.UUID.t() | nil,
      idempotency_key :: String.t()
    ) :: ExecutionError.error_args()

ELIXIR-DEV extracts the existing two inline maps into it with no behavior change to the
human path (verified by the existing human-path tests).

### 1.3 Internal return type of `persist_service_task_advance/10`

Widened from `{:ok, :advanced} | {:error, term()}` to additionally return
`{:ok, :error_set}` (instance moved to `:error`). `advance_service_task_dispatch/4`
passes it through. No new public type is needed: `advance_after_service_task_outcome/4`'s
existing `@spec` already lists `{:ok, :error_set}`, which today only the `:give_up` clause
returns.

### 1.4 Transaction semantics (decided explicitly)

The whole re-entry runs inside the ONE `repo.transaction/1` opened by
`advance_after_service_task_outcome/4`'s `:advance` clause. `persist_service_task_advance/10`
must NOT roll back on a `no_matching_edge`; it must write the error records inside that
same transaction and let it COMMIT. Mechanism: build an `Ecto.Multi` containing only
`ExecutionError.append_multi(error_args, prefix: prefix, locked_projection: projection)`
(the projection is already `FOR UPDATE`-locked by `fetch_and_lock_instance_projection/3`
earlier in the same transaction, so the lock is reused, no second lock) and execute it with
`repo.transaction(multi)`; because it runs inside the already-open outer transaction it
joins it (same nesting behavior `do_persist_service_task_advance/10` already relies on).
If the nested multi returns `{:error, _step, reason, _}`, return `{:error, reason}` so the
outer function rolls back and the failure is surfaced by item 2 (this is the only rollback
case).

State committed on the `no_matching_edge` path (all in the one transaction, atomic):

1. One `EXECUTION_ERROR` event (idempotency key above).
2. One `dlq_entries` row, written by `ExecutionError.append_multi/3`'s generic
   `:execution_error_dlq_landing` step (Hook B). `dlq_landed_externally` stays `false`.
3. `instance_projections` row updated to `status: :error` with `error_detail`.

State explicitly NOT written on this path:

* No `SERVICE_TASK_COMPLETED` event (the node's outcome did not complete a transition).
* No token reconciliation, no new token rows, no task activation, no timer arms, no new
  dispatch rows, no sub-process children. The SERVICE_TASK token stays parked at its node,
  exactly as the human path leaves its task `:pending` and tokens unmodified.
* No persisted variable merge. The merged variables appear only inside the
  `EXECUTION_ERROR` payload (`error_args.variables`), same as the human path.
* The `service_task_dispatches` row is NOT touched: it stays `"advanced"`. This is the
  truthful state (the HTTP call succeeded and its outcome was accepted); the dispatch row
  records the call, the instance row records the downstream routing failure. It must never
  be reverted to a claimable status (that would re-issue the HTTP call, violating
  at-most-once dispatch).

Invariant: after `advance_after_service_task_outcome/4` returns `{:ok, :error_set}` for an
`:advance` outcome, there is always exactly one `EXECUTION_ERROR` event for the instance
carrying key `service_task_dispatch:<id>` AND the projection status is `:error`; never one
without the other (guaranteed by the single transaction).

Snapshot: no `SnapshotWriter` call is made on this path (decision, see open question OQ-1).
Replay from the log remains correct (INV-ISS-1); the snapshot is only an optimization.

### 1.5 Idempotency / redelivery

Only one of `SERVICE_TASK_COMPLETED` or `EXECUTION_ERROR` is ever written for a given
`dispatch.id`, so reusing the key `"service_task_dispatch:<id>"` cannot conflict. If the
re-entry were somehow invoked twice, the second call's
`fetch_and_lock_instance_projection/3` returns `{:error, {:instance_not_active, :error}}`
(projection is `:error`), which is the existing, already-handled error return and does not
write anything.

### 1.6 Dispatcher-side mapping of the new return value

`ServiceTaskDispatcher.call_advance_after_service_task_outcome/3` already maps
`{:ok, :error_set}` to `{:ok, {:give_up, :applied}}`, which `fold_attempt_result/2` counts
under `:given_up`. This design REUSES that mapping with no dispatcher type change: the
poller summary's `given_up` counter will include "advance produced an execution error". This
is accepted as the smallest correct change (decision, OQ-2 records the alternative of a
dedicated counter).

## 2. Item 2 -- no silent swallow at `service_task_dispatcher.ex` L614

The catch-all `{:error, reason} -> {:error, reason}` arm of
`call_advance_after_service_task_outcome/3` must become observable. Behavior:

* Add `require Logger` to the module (it currently has none).
* On any `{:error, reason}` that is not the existing `{:invalid_form_schema, ...}` arm,
  and not `{:instance_not_active, _}` (an already-terminal/errored/cancelled instance is a
  benign race, log at `:debug` only), do both of:
  1. `Logger.error` with a message containing ONLY: dispatch_id, tenant_schema, and a
     classified reason tag (see below). Never `inspect(reason)` raw: `reason` can contain
     instance variables and the HTTP response body.
  2. Best-effort audit entry via a new `@doc false` function
     `Letflow.Engine.record_service_task_advance_failure_audit/5`, called here strictly
     after `advance_after_service_task_outcome/4` has returned (same post-return rule and
     same log-and-swallow, never-raise contract as `record_task_activation_rejection_audit/5`):

         record_service_task_advance_failure_audit(
           instance_id :: Ecto.UUID.t(),
           node_id :: String.t() | nil,
           reason_tag :: atom(),
           actor_id :: Ecto.UUID.t() | nil,
           prefix :: String.t()
         ) :: :ok

     Audit attributes: `action: "service_task.advance_failed"`, `resource_type: "instance"`,
     `resource_id: instance_id`, `after_state: %{"node_id" => node_id, "reason" => reason_tag
     as string}`, `actor_id: EventStore.platform_actor_id()`. Written in its own
     `Repo.transaction/1` (independent commit).
* `instance_id` and `node_id` are recovered by re-fetching the dispatch row with `Repo.get`
  (no lock) exactly as `maybe_audit_task_activation_rejection/4` does; nil row is a no-op.
* Reason classification is an exhaustive private mapping to atoms:
  `:transition_failed`, `:variable_merge_rejected`, `:unknown_token_id`,
  `:event_append_failed`, `:execution_error_not_supported`, `:other`. The `:other` tag is the
  fallback so an unrecognized shape still produces a log and an audit row rather than a
  crash. No reason payload is stored (INV: no variables/response body in logs or audit).
* Return value of the arm is unchanged (`{:error, reason}`), so
  `fold_attempt_result/2` and `poll_and_dispatch/1`'s "never raises" contract are untouched.

After item 1, the remaining residue reaching this arm is genuinely exceptional (hop limit,
unknown token, variable-merge rejection, DB failure); it is now loud instead of silent. This
design deliberately does NOT revert the dispatch row to retry for those (would risk duplicate
HTTP side effects); see OQ-3.

## 3. Item 3 -- timer re-entry path (~L2949) check

Checked, no change required. `dispatch_timer_fired_hop_chain/1` and
`dispatch_escalation_timer_fired_hop_chain/1` have the same bare
`{:error, {:transition_failed, reason}}` shape and the same SERVICE_TASK/EXCLUSIVE_GATEWAY
topologies could reach it, but the consequence differs: the timer row is NOT committed to a
terminal state before re-entry. `fire_timer/2` is a single transaction, so a failure rolls
the timer row back, `attempt_fire/2` increments `fire_error_count`, and on exhaustion
(`max_fire_retries`) lands an ExecutionError plus a DLQ row (ISS-303/ISS-0618, scheduler.ex
~L489-623). It is bounded and terminal, not a silent stall. No engine change; no scope
creep. A regression test pinning "timer fire into an unmatched gateway is bounded and ends
in an error" is optional and listed in the test plan (T7) only as a characterization test,
to be dropped if it proves heavy; it must not drive any production change.

## 4. Item 4 -- fixture change (Meridian Loan Origination)

File: `test/fixtures/qa/meridian_loan_origination_process_definition.json` (graph key
`graph`).

Changes:

1. Add one new edge: `id: "e9-default"`, `source: "kyc-routing"`, `target:
   "assessment-join"`, `is_default: true`, NO `condition` key. (CHK-13 requires every
   non-default edge out of an EXCLUSIVE_GATEWAY to carry a condition; CHK-15 forbids
   `is_default` together with a condition; at most one default edge per gateway.)
2. Keep e9 (`kyc_status == 'clear'` -> assessment-join), e10 (`'hit'` -> kyc-manual-review)
   and e11 (`'inconclusive'` -> kyc-manual-review) unchanged. Semantics: explicit clear and
   no/other kyc_status both reach the join; hit/inconclusive route to manual review.
   (Business rationale: an absent `kyc_status` from the QA stub endpoint, which echoes JSON
   without that key, is treated as "no adverse finding". This is a QA-fixture decision, see
   OQ-4.)
3. Bump top-level `version` from `"1.1"` to `"1.2"`. `scripts/seed_meridian_definition.sh` is
   version-aware (creates + activates a newer fixture version; 409 means bump, never delete),
   so a new version is mandatory for QA to pick up the change. Update the header comment
   line 5 of that script ("Loan Origination v1.1") to v1.2.
4. Update the `description` only if it states the version (it does not); leave it.

Mirror check: `test/fixtures/simulation/meridian/` contains no loan-origination copy (only
`company.yaml`, `org_structure.yaml`, `process_claim_intake.yaml`, `process_policy_binding.yaml`),
and `test/letflow/simulation/req208_meridian_test.exs` builds its own simplified inline graph
(documented at its L147-183) that bypasses kyc-aml-check. Nothing to mirror.
`test/fixtures/uat/process-definition-aliases/proc-meridian-loan-origination.yaml` resolves by
definition NAME ("Loan Origination"), not version: no edit.

Scenario impact: `loan-origination-above-threshold.yaml` and `-below-threshold.yaml` supply
no `kyc_status`, so with the default edge they route kyc-routing -> assessment-join and
proceed to committee/L1 routing. Their `expected_outcomes` need no edit (the manual-review
branch is not asserted). No scenario file change is required; the next UAT run against QA
must run after the QA re-seed of v1.2 (operational step for UAT-RUNNER/ORCH, not code).

Does the fixture change alone fix the issue? No. It removes the trigger for these two
scenarios; the engine fix (items 1-2) is required so that ANY future unmatched gateway after
a SERVICE_TASK errors loudly instead of stalling.

## 5. Item 5 -- fail-first test plan

Location: `test/letflow/engine/service_task_wiring_test.exs`, new describe block "ISS-0928:
no_matching_edge after SERVICE_TASK" using the existing helpers (`provisioned_tenant`,
`active_definition!`, `enable_ssrf_bypass`, local `WebhookTestServer` returning a JSON object
without `kyc_status`, `ServiceTaskDispatcher.attempt_dispatch/2`,
`advance_after_service_task_outcome/4`, `dispatches_for/2`). New graph builders (test-local):
`graph_svc_xg_end_no_default`, `graph_fork_human_and_svc_xg_join`, and a `_with_default`
variant. Each test is FAIL-FIRST: written and shown red against current `main` behavior before
the production change.

* T1 (top-level, headline regression): START -> svc -> EXCLUSIVE_GATEWAY (condition
  `variables.kyc_status == 'clear'` only, no default) -> END. After dispatch + advance:
  `advance_after_service_task_outcome/4` returns `{:ok, :error_set}`; instance projection
  status is `:error`; exactly one `EXECUTION_ERROR` event with `error_type`
  `no_matching_gateway_edge`, `affected` = the gateway node id, key
  `service_task_dispatch:<id>`; exactly one `dlq_entries` row for the instance; zero
  `SERVICE_TASK_COMPLETED` events; dispatch row still `"advanced"`; token still at the svc
  node. Fails today (returns `{:error, _}`, no events, status `:active`).
* T2 (fork branch, the reported topology): START -> PARALLEL fork -> {h1 HUMAN_TASK, svc} ->
  svc -> EXCLUSIVE_GATEWAY (no default) -> join. Same assertions as T1, plus: the h1 task
  remains `:pending` and untouched, and the fork-branch dispatch row had been created
  `pending` at `Engine.create` (pins that dispatch itself was never the bug).
* T3 (default edge, happy path): same fork graph as T2 plus an unconditioned `is_default`
  edge gateway -> join. After the svc advance: instance still `:active`; exactly one
  `SERVICE_TASK_COMPLETED`; zero `EXECUTION_ERROR`; then completing h1 fires the join and
  the instance reaches the node after the join (assert `current_nodes`).
* T4 (explicit match still wins): response containing `kyc_status: "hit"` routes to the
  conditioned HUMAN_TASK edge, not the default (guards default-edge precedence).
* T5 (no tx residue on error): in T1/T2 assert no `tokens` row changes, no `tasks`, `timers`
  or new `service_task_dispatches` rows were created by the failed advance, and that the
  merged variables are not persisted to the projection.
* T6 (item 2): drive `ServiceTaskDispatcher.poll_and_dispatch/1` for a case that still
  yields `{:error, _}` from re-entry (e.g. a seeded dispatch whose token row has been
  removed to force `{:unknown_token_id, _}`); use `ExUnit.CaptureLog` to assert exactly one
  error-level log containing dispatch id and tag `unknown_token_id` and NOT containing any
  variable value or response-body text; assert one `service_task.advance_failed` audit row
  with `after_state` holding only `node_id` and `reason`; assert the poll summary and
  never-raises contract are unchanged.
* T7 (item 3, optional characterization): timer fire into an unmatched gateway leaves the
  timer row unfired with `fire_error_count` incremented (bounded retry), not a silent
  success. Drop if it requires disproportionate scaffolding.
* T8 (fixture): a pure-JSON test (new, in `test/letflow/definitions/` or next to existing
  fixture tests) loads `test/fixtures/qa/meridian_loan_origination_process_definition.json`,
  asserts `version == "1.2"`, asserts `kyc-routing` has exactly one `is_default: true`
  outgoing edge with no `condition`, and that the graph validates through the same
  `Letflow.Definitions.Graph` validation the API uses (CHK-13..16 clean).
* Human-path non-regression: the existing `complete_task` no_matching_edge tests must stay
  green unchanged after the shared-builder extraction (1.2).

Scoped commands for ELIXIR-DEV/TEST-RUNNER: `mix test test/letflow/engine/service_task_wiring_test.exs`
and the file holding T8; plus the existing human-path file(s) that cover
`:no_matching_gateway_edge` via `complete_task`.

## 6. Item 6 -- tenant isolation and security notes

* Every new write takes the tenant `prefix` already threaded through the call chain
  (`tenant_schema` from `poll_and_dispatch/1`); tenant is resolved from the schema prefix
  via `TenantProvisioning.tenant_id_for_schema_name(prefix)`, never from caller input
  (INV-PD-7 precedent). No new route, no migration, no response shaping, no secret handling.
* `ExecutionError.append_multi/3`, `EventStore.append/2` and `Audit.insert_entry/3` are
  prefix-aware existing sinks; no raw SQL, no new `Repo` calls without `prefix:`. The
  dispatcher re-fetch for the audit uses `Repo.get(..., prefix: tenant_schema)` like the
  existing helper.
* Information disclosure: logs and the new audit row carry only dispatch id, instance id,
  node id and an atom tag; never variables, HTTP response bodies, or `inspect(reason)`. The
  `EXECUTION_ERROR` event does contain merged variables (identical to the human path today),
  and is subject to the same visibility rules as any existing execution error.
* Actor attribution: `EventStore.platform_actor_id()` (no human actor), consistent with
  `SERVICE_TASK_COMPLETED` and the ISS-0784 site-4 precedent.
* At-most-once: the design never reverts or re-arms a dispatch row, so no duplicate outbound
  HTTP call can result from the fix.
* Reviewer routing: the change adds new audit and EXECUTION_ERROR writes on a tenant data
  path (event store, audit log, DLQ). Per `docs/anti-patterns.md` (ISS-0926 lesson: a design's
  named risk raises, not lowers, the bar), this design marks SECURITY-REVIEWER as REQUIRED
  (not skippable) for the implementation PR, scoped to: prefix handling on the new audit
  function, log content, and the single-transaction commit semantics. REVIEWER and
  CODE-DESIGN-VALIDATOR also apply.

## 7. Acceptance-criteria mapping

| Criterion | Where satisfied |
|---|---|
| Design covers each of the six items | Sections 1-6 (items 1, 2, 3, 4, 5, 6 in order) |
| No implementation code | Signatures and prose only; no function bodies |
| Unambiguous transaction semantics | Section 1.4 (single txn, commit, exact write/non-write list), 1.5, 2 (audit is an independent post-return commit) |
| Files-to-change list with owned_modules | Section 8 |
| Issue AC: SERVICE_TASK on a PARALLEL_GATEWAY branch dispatched and recorded | Already true (section 0); pinned by T2 |
| Issue AC: Meridian scenarios reach committee/L1 routing | Section 4 + T3 |
| Issue AC: fail-first engine-level regression for the stall | T1, T2 |

## 8. Files to change / owned_modules

owned_modules for ELIXIR-DEV:

* `Letflow.Engine` -- `lib/letflow/engine.ex`:
  `persist_service_task_advance/10` error arms (execution-error branch, new return
  `{:ok, :error_set}`), shared private `build_no_matching_gateway_edge_error_args/6`
  (extracted from `dispatch_task_completion_hop_chain/7`, no behavior change there), new
  `@doc false` `record_service_task_advance_failure_audit/5`, `@spec`/doc updates for
  `advance_service_task_dispatch/4`.
* `Letflow.Engine.ServiceTaskDispatcher` -- `lib/letflow/engine/service_task_dispatcher.ex`:
  `require Logger`, catch-all arm of `call_advance_after_service_task_outcome/3`, private
  reason-classifier, update the explanatory comment above `maybe_advance_after_outcome/3`.

Other files:

* `test/fixtures/qa/meridian_loan_origination_process_definition.json` (edge + version 1.2)
* `scripts/seed_meridian_definition.sh` (header comment v1.1 -> v1.2 only)
* `test/letflow/engine/service_task_wiring_test.exs` (T1-T7)
* one new or existing definitions/fixture test file for T8
* `docs/anti-patterns.md` (entry: a committed-terminal row followed by a rolled-back
  re-entry is a silent stall; every post-commit re-entry error arm must route to an
  ExecutionError or be logged/audited)
* `docs/issues/ISS-0928.yaml` (reframe; file exists only on `origin/pr2129`, ORCH decides how
  to land it; do not touch PR #2129)

No migrations, no new tables or columns, no API/route changes, no frontend changes.

## 9. Open questions (none block implementation; each has a stated default)

* OQ-1: Snapshot after the execution-error commit. Default: do NOT snapshot (log replay is
  authoritative; the human path snapshots only because it already holds the state). Alternative:
  call the post-commit `maybe_snapshot_after_set_instance_error`-style reconstruction from
  `advance_after_service_task_outcome/4` after its transaction returns. Not required by any AC.
* OQ-2: Reusing `:given_up` for execution errors on the `:advance` outcome makes the poller
  summary slightly misleading. Default: accept. Alternative: add an `:errored` counter,
  which widens `poll_and_dispatch/1`'s summary type and its consumers.
* OQ-3: Residual `{:error, _}` re-entry failures (hop limit, unknown token, merge rejection)
  are logged and audited but leave the instance ACTIVE with an `"advanced"` row. Default:
  accept for this fix (making them terminal needs a decision on error types and on whether a
  merge-rejection should become an ExecutionError, as the human path does). Recommend ORCH
  queue a follow-up issue; not in scope here.
* OQ-4: Treating an absent `kyc_status` as pass-through to `assessment-join` is a QA-fixture
  business assumption. Default: accepted for the QA stub only. Production Meridian definitions
  with a real KYC service should route absent status to manual review instead; confirm with
  the BA-MERIDIAN owner. The version bump to 1.2 keeps this reversible.
