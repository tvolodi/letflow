# WF-03 Fix Design -- ISS-0929 / Q-929 (Vortex critical deviation: SUB_PROCESS has no definition_name, no 8D child exists, and the parent cannot continue past the sub-process into a SERVICE_TASK)

Run-id: WF03-Q929-20261001
Type: fixture + seed-script + test change, PLUS one minimal `lib/` fix in
`Letflow.Engine.SubProcess` (empirically proven necessary, section 2). No decision record
needed (engine contract unchanged; a dropped side effect is restored).
Issue: `docs/issues/ISS-0929.yaml` (queue Q-929, GH-2115). Diagnosis:
`handoffs/WF03-Q929-20261001/step-01-issue-fixer-diagnose.json`.
Design author: CODE-DESIGNER. Not self-reviewed; CODE-DESIGN-VALIDATOR gates this file.
Design only: this file contains JSON fixture-shape snippets and signatures, no function bodies.

## 0. Scope boundaries

- IN: repo fixtures, seed scripts, drift test, new tests, one engine fix in `sub_process.ex`
  (+ minimal public exposure of existing private Engine helpers).
- OUT: any QA data / DB change (ORCH/UAT re-seeds QA after merge, section 9), the unrelated
  SERVICE_TASK `body_template` rendering gap (Q-926), the stale HUMAN_TASK escalation timer
  defect (ISS-0925 follow-up), SUB_PROCESS spawned *after* a completed SUB_PROCESS (section 3.4),
  the production/UAT scenario YAMLs (byte-identical ported corpus, not edited).

## 1. Root causes (diagnosis re-verified)

| # | Claim | Evidence | Result |
|---|---|---|---|
| R1 | `corrective-action-subprocess` has no `attributes`, so `resolve_child_definition/2` returns `missing_definition_name_attribute` -> ERROR `SUB_PROCESS_DEFINITION_NOT_FOUND` | fixture v1.1 read; `sub_process.ex` ~351-363 | confirmed (static) |
| R2 | No 8D child definition exists anywhere | `test/fixtures/qa/` (9 files), `seed_vortex_definition.sh` (2 units), `test/fixtures/simulation/vortex/*` | confirmed |
| R3 | `role-procurement-manager` deliberately unseeded | `seed_vortex_persona_actors.sh` lines 28-29; drift test lines 163-164 and M2 | confirmed |
| R4 | Parent cannot advance from SUB_PROCESS into SERVICE_TASK `close-deviation` | EMPIRICAL, section 2 | **CONFIRMED by execution** |

## 2. The critical open question: RESOLVED EMPIRICALLY (R4 is a real engine defect)

Question: after the child 8D instance completes, does the parent advance through SERVICE_TASK
`close-deviation` to `end-closed` and COMPLETED?

Method: a throwaway ExUnit probe (`Letflow.DataCase`, `async: false`, real Postgres on
`LETFLOW_DB_PORT=51929`, `MIX_ENV=test`; the file was written under `test/letflow/engine/`,
run once, and DELETED; `git status` afterwards shows no `test/` or `lib/` change). It loaded the
REAL parent fixture JSON (only `corrective-action-subprocess.attributes.definition_name` set to
`"8D Corrective Action"`) plus the proposed child graph (START -> HUMAN_TASK
`corrective-action-8d` role `role-procurement-manager` -> END, v1.0), activated both in a
provisioned tenant, and drove the harness exactly as `regulatory_review_timer_path_test.exs`
does for service tasks (no HTTP; the dispatcher is not run; the test marks the dispatch row
`"advanced"` and calls `Engine.advance_after_service_task_outcome(row.id, {:advance, %{}}, Repo, schema)`).

Observed output (verbatim lines from the run):

```
first dispatch: "quarantine-batch"
advance quarantine: {:ok, :advanced}
complete severity-classification: {:ok, ...
parent after classification: {:active, ["corrective-action-subprocess"]}
children: [{"ebae61a3-...", :active, ["corrective-action-8d"]}]
complete corrective-action-8d: {:ok, ...
parent after child complete: {:active, ["close-deviation"]}
parent dispatches: [{"quarantine-batch", "advanced"}]
parent tokens: [{"close-deviation", :active}]
Result: 1 passed
```

Reading it:

- With `definition_name` set and the child present, the sub-process spawn works (R1, R2 are
  fully cured by fixture changes: the child instance is created `:active` at `corrective-action-8d`).
- Completing the child task succeeds, the parent token moves to `close-deviation`, BUT the
  parent has exactly ONE `service_task_dispatches` row (the earlier `quarantine-batch`, already
  `"advanced"`) and NO row for `close-deviation`. The parent is stuck `:active` at
  `close-deviation` forever (the poller has nothing to pick up). EO-003 (COMPLETED at
  `end-closed`) can never pass with fixture/seed changes alone.

Cause (code): `Letflow.Engine.SubProcess.build_completion_multi_from_merge/12`
(`lib/letflow/engine/sub_process.ex` ~824-905) calls `Engine.advance_until_stable/4`, which
returns the hop chain's accumulated `pending_events` (this is where
`{:service_task_dispatch_requested, token_id, node_id}`,
`{:timer_armed, ...}`, `{:escalation_timer_armed, ...}` appear), and binds them to
`_more_pending`, i.e. discards them. `build_completion_write_steps/12` (~949-1000) only writes
task activation, token reconciliation, the `SUB_PROCESS_COMPLETED` event, the parent
projection, and the grandparent cascade. Every other completion path (`Engine.create/2`,
`complete_task/3`, timer-fire, service-task-outcome advance) turns those pending events into
`service_task_dispatches` / `timers` Multi steps; this path does not.

## 3. `lib/` change (minimal, required)

Authorization/tenant impact: none. No route, no authz decision, no response shaping, no new
input surface; tenant id is derived from the schema `prefix` exactly as `complete_task/3`
already does (`TenantProvisioning.tenant_id_for_schema_name/1`, INV-PD-7). SECURITY-REVIEWER
may be skipped ONLY on that basis (it touches the same insert shape and the same tenant
derivation as existing code, no new tenant-data path); REVIEWER (OTP idiom, scope) is still
required. If ELIXIR-DEV finds it must change any authz/tenant derivation, stop and escalate to ORCH.

### 3.1 Behavior

In `build_completion_multi_from_merge/12`, the success branch must stop discarding the pending
events. Keep BOTH lists: the events returned by the `{:sub_process_completed, parent_token_id}`
`Transition.transition/3` call (currently `_pending_events`, line ~867) and the events returned
by `advance_until_stable/4` (`_more_pending`, ~894). Their concatenation (transition events
first, then hop-chain events, preserving order) is `completion_pending_events`.
`advance_until_stable/4` does not re-include the first transition's events (it only accumulates
its own hops), so no deduplication is expected; ELIXIR-DEV must assert in the fail-first test
that exactly one dispatch row results (no duplicate) and may dedupe by `{tag, token_id, node_id}`
if the regression shows duplication.

Pass `completion_pending_events` to `build_completion_write_steps/12` (gaining one parameter),
which, AFTER the `reconciliation_key` step (so the parent TokenRecord row is current and
`token_id` strings equal real TokenRecord ids -- the same identity `id_map` that
`complete_task/3` uses) and BEFORE the grandparent cascade, appends two `Multi.merge` steps:

1. Timer arms: resolve `{:timer_armed, ...}` and `{:escalation_timer_armed, ...}` events and
   insert `Scheduler` timer rows (same semantics as `prepare_timer_arms/4` +
   `build_timer_arms_multi/4`; `now` = the existing `completed_at` instant used in the function).
2. Service-task dispatch rows: resolve `{:service_task_dispatch_requested, ...}` events and
   insert `ServiceTaskDispatch` rows (same semantics as
   `prepare_service_task_dispatch_abort_on_empty_url/6` + `build_service_task_dispatch_multi/5`),
   with `catalog_ctx = %{pin_source: {:reconstruct, parent_instance_id, prefix}, tenant_id: {:schema_prefix, prefix}}`
   as `prepare_service_task_dispatch_for_completion/8` builds it.

Identity id_map (`%{token_id => token_id}`) is correct because `reconcile_parent_tokens/5`
already rejects any token not present in the original records
(`{:new_token_during_resume_not_supported, ...}`), so every token in `final_instance_state` is
a persisted TokenRecord id.

> **CORRECTION (CODE-DESIGNER, 2026-10-03, ISS-0975):** the paragraph above is now stale and
> superseded. ISS-0975 (`lib/letflow/design/iss0975-subprocess-join-reentry-id-map.md`) found
> that `reconcile_parent_tokens/5`'s own rejection guard is exactly the same
> `do_reconcile_token_records/5`-style guard ISS-0408 had already shown needs a prior insert
> step, not a bare rejection, for the one case this reasoning doesn't cover: a
> `PARALLEL_GATEWAY` join firing within the SAME hop chain this function's own
> `advance_until_stable/4` call advances through, whose own outgoing edge leads directly into
> a SERVICE_TASK/TIMER node. For that case, the join-merged token is genuinely **not yet** a
> persisted `TokenRecord` id when `append_pending_event_arms_multi/7`'s own identity id_map
> runs — the rejection this paragraph relies on to make that id_map "correct" fires *before*
> reaching it instead (with `{:new_token_during_resume_not_supported, token_id}}`), which is
> itself the bug ISS-0975 fixes, not a safety net that made the identity id_map actually
> correct. ISS-0975's own design widens `reconcile_parent_tokens/5`'s known-token set (by
> prepending newly-inserted hop-chain-local-new `TokenRecord` rows, mirroring ISS-0408's own
> `build_task_activation_and_reconciliation_multi/4` treatment) and replaces
> `append_pending_event_arms_multi/7`'s identity id_map with a real one read back from the
> transaction's own `changes`, exactly as ISS-0974 already did for `Letflow.Engine`'s own 4
> sibling sites. This correction note does not change anything else in this design doc —
> the vortex 8D fixture/seed/test changes below are unaffected; they simply never happened to
> exercise a same-hop-chain join in their own child graph.

Error handling: any `{:error, _}` from the prepare step (unknown node, empty rendered URL,
catalog unresolved, invalid timer duration, multiple deadline timers) must be returned from
`build_completion_multi_from_merge/12` as the existing
`{:error, to_error_args({:definition_not_found, {:activation_failed, reason}}, parent_token.instance_id, parent_token.node_id, state_with_merged.variables, actor_id, error_idempotency_key)}`
shape, so the existing `ExecutionError.append_multi` fallback in the two callers
(`Engine.append_sub_process_completion_cascade_multi/6`, `SubProcess.maybe_cascade_to_grandparent/7`,
and the synchronous-child chain) records an ERROR transition rather than crashing. (Reusing
`:activation_failed` is the established channel for hop-chain failures here; a new error type
is not introduced.)

### 3.2 Signatures (shapes only)

New in `Letflow.Engine` (public, `@doc false`, like `advance_until_stable/4` and
`tokens_needing_dispatch/3`, because `SubProcess` is a sibling module and the helpers are
currently `defp`): ONE entry point, so `SubProcess` need not call six private helpers:

```
@doc false
@spec append_pending_event_arms_multi(
        Multi.t(),
        pending_events :: [Transition.pending_event()],
        graph :: Graph.t(),
        instance_id :: Ecto.UUID.t(),
        variables :: map(),
        now :: DateTime.t(),
        prefix :: String.t()
      ) :: {:ok, Multi.t()} | {:error, term()}
```

Contract: pure of side effects until the returned Multi runs; calls the existing private
`prepare_timer_arms/4`, `prepare_service_task_dispatch_abort_on_empty_url/6`,
`build_timer_arms_multi/4`, `build_service_task_dispatch_multi/5` (identity id_map built from
the prepared token ids) and `TenantProvisioning.tenant_id_for_schema_name/1`; returns
`{:ok, multi}` unchanged when no relevant events exist; the existing private helpers are NOT
renamed or altered. Note `prepare_service_task_dispatch/6` touches the DB only for catalog
nodes (lazy pin reconstruction) and that read happens at Multi-build time inside the already-open
transaction, as in `complete_task/3`.

Changed private signatures in `Letflow.Engine.SubProcess`: `build_completion_write_steps` gains
`completion_pending_events :: [Transition.pending_event()]` (and the already-available
`variables`/`graph`/`prefix` it already receives). Public `append_completion_multi/5` and
`@spec` are unchanged.

### 3.3 Why not the alternatives

- Change `close-deviation` so it is not a SERVICE_TASK: diverges from the byte-identical
  ported scenario/EO-003 and hides an engine defect that affects every definition with a
  SERVICE_TASK/TIMER/escalation-HUMAN_TASK after a SUB_PROCESS.
- Unify all completion paths into one helper: larger blast radius, separate refactor.

### 3.4 Known remaining gap (explicitly out of scope, not an open question)

A `{:sub_process_start, ...}` event inside `completion_pending_events` (a second SUB_PROCESS
reached directly after the first) is still not spawned by this path. This design does not
change that; ELIXIR-DEV must NOT silently widen the fix. ORCH files a follow-up issue
("SUB_PROCESS directly after a completed SUB_PROCESS is not activated"). The vortex fixture
does not need it.

## 4. Fixture changes (exact)

### 4.1 NEW child: `test/fixtures/qa/vortex_8d_corrective_action_definition.json`

File name deliberately NOT `*_process_definition.json` (the
`qa_fixture_service_task_endpoints_test.exs` glob requires >= 1 SERVICE_TASK in every
`*_process_definition.json`, which a START -> HUMAN_TASK -> END child cannot satisfy).
Shape:

```
{ "name": "8D Corrective Action", "version": "1.0",
  "description": "<one sentence: 8D corrective-action child process spawned by Supplier Quality Deviation for CRITICAL severity; Procurement completes it.>",
  "graph": {
    "nodes": [
      {"id": "start", "node_type": "START"},
      {"id": "corrective-action-8d", "node_type": "HUMAN_TASK", "attributes": {"role": "role-procurement-manager"}},
      {"id": "end", "node_type": "END"} ],
    "edges": [
      {"id": "e0", "source": "start", "target": "corrective-action-8d"},
      {"id": "e1", "source": "corrective-action-8d", "target": "end"} ] } }
```

No `interface` attribute (optional: child gets a full copy of parent variables, full final
variable map merges back; verified in diagnosis and by the probe run). No SERVICE_TASK in the
child: a synchronously-completing child (START -> END) collides on a Multi step per
`engine_sub_process_test.exs`/REQ-207 note, so the HUMAN_TASK is required. The probe used this
exact graph shape and it validated and ran.

### 4.2 Parent: `test/fixtures/qa/vortex_supplier_quality_deviation_process_definition.json`

- `"version": "1.1"` -> `"1.2"` (seed rule is version-aware; same version would 409).
- Node `corrective-action-subprocess` gains `"attributes": {"definition_name": "8D Corrective Action"}`.
- Optional: extend `description` with one sentence naming the child. Nothing else changes
  (no node/edge/other-attribute change; all SERVICE_TASK nodes untouched so
  `qa_fixture_service_task_endpoints_test.exs` keeps passing).

## 5. Seed script changes

### 5.1 `scripts/seed_vortex_definition.sh`

- Add a `seed_definition` call for the child BEFORE the parent: display name `"8D Corrective Action"`,
  URL-encoded `"8D+Corrective+Action"`, path `test/fixtures/qa/vortex_8d_corrective_action_definition.json`,
  alias `"proc-vortex-8d-corrective-action"`. (The child is late-bound by name at spawn time, so
  order is not functionally required; child-first is the safe/clear order.)
- Header comment: "two" -> "three" ProcessDefinitions; list item `3`/order; "Supplier Quality
  Deviation" version in the header comment `v1.1` -> `v1.2`; add `8D Corrective Action v1.0`;
  mention `ISS-0929`. The `Payload sources of truth` list is unchanged except noting the child
  has no simulation YAML counterpart.

### 5.2 `scripts/seed_vortex_persona_actors.sh`

- `ROLES`: add `"role-procurement-manager"` (4 -> 5 entries, keep existing ordering style).
- `PERSONAS`: `"actor-vortex-felix|"` -> `"actor-vortex-felix|role-procurement-manager"`.
- Header: "4 roles" -> "5 roles"; delete the "deliberately NOT seeded" comment (lines 28-29)
  and replace with one line stating it is seeded because the 8D child (ISS-0929) routes to it.
- Do not change `scripts/lib/seed_persona_actors_base.sh`.

## 6. Alias and simulation parity

- NEW `test/fixtures/uat/process-definition-aliases/proc-vortex-8d-corrective-action.yaml`,
  same keys as `proc-vortex-supplier-quality-deviation.yaml`: `process_id: proc-vortex-8d-corrective-action`,
  `definition_name: "8D Corrective Action"`, `company_id: vortex`,
  `seed_script: scripts/seed_vortex_definition.sh`,
  `fixture: test/fixtures/qa/vortex_8d_corrective_action_definition.json`, `issue_ref: ISS-0929`,
  `recorded_by: CODE-DESIGNER`, `recorded_at: "2026-10-02"`, `reason:` (the 8D id appears only in
  scenario EO-002 detail text and maps to this definition name; same rationale as the sibling sidecar).
- `scripts/uat_preflight.sh`: no change (it resolves only scenario `process_id` fields;
  confirmed in the diagnosis). `scripts/README.md`: one sentence optional (seed scripts are
  described generically).
- Simulation: `test/fixtures/simulation/vortex/` has NO binding for the 8D id and the vortex
  sim scenarios use `definition_name: DEFINITION_NAME` placeholders, so no scenario edit is
  needed. Parity (optional but recommended): mirror `definition_name: 8D Corrective Action`
  under `corrective-action-subprocess` in `test/fixtures/simulation/vortex/process_work_order.yaml`
  (the REQ-207 test builds its own graph and does not read that node's attributes; verified in
  the diagnosis). Not adding a child YAML under simulation: no simulation consumer.
- Doc sentence: `lib/letflow/design/iss0931-meridian-vortex-persona-actor-provisioning.md`
  says procurement is unseeded; update that one sentence (ISS-0929 reverses it).

## 7. Drift test flips: `test/scripts/persona_actor_seed_drift_test.exs`

- `@tenants["vortex"].fixtures`: append `"test/fixtures/qa/vortex_8d_corrective_action_definition.json"`;
  `count: 4` -> `5` (role set is derived from fixture HUMAN_TASK `role` values).
- Delete the `refute ... role-procurement-manager must not be seeded` assertion (~163-164).
- Rewrite M2 (currently "adding role-procurement-manager to vortex ROLES is detected", it is
  now a legitimate role): new M2 = removing `"role-procurement-manager"` from the vortex
  `ROLES` array is detected with message containing `missing_in_script=["role-procurement-manager"]`;
  keep the surrounding assertion style.
- Search the whole file (and M1, M3-M8) for every literal `4` / vortex role-count dependency
  and any assertion mentioning felix with empty roles; update to 5 / felix roles
  `["role-procurement-manager"]`. ELIXIR-DEV runs the file and the full suite for that
  directory to confirm none missed.

## 8. Tests (names; fail-first expectations; mutations)

### 8.1 `test/letflow/scripts/vortex_8d_subprocess_fixture_test.exs` (NEW, pure, `async: true`)

Reads the two fixtures and seed script; no DB.
- F1: parent `corrective-action-subprocess.attributes.definition_name` is a non-empty string.
- F2: it equals the child fixture `name` (`"8D Corrective Action"`).
- F3: child graph passes `Letflow.Graph` validation (same validators as the diagnosis cites).
- F4: child has exactly one HUMAN_TASK, role `role-procurement-manager`, and zero SERVICE_TASK,
  and no `interface` attribute on the parent SUB_PROCESS.
- F5: `seed_vortex_definition.sh` references the child fixture path and the alias, and the child
  `seed_definition` call precedes the parent call (string index comparison).
- F6: the alias YAML exists, `definition_name` equals the child fixture name, and its `fixture`
  path exists on disk.
- F7: parent fixture version is `1.2` and strictly greater (numeric segments) than `1.1`.
Fail-first: F1/F2/F4/F5/F6/F7 fail on the old tree (no attribute, no child file, v1.1).
Mutations that must fail it: M-a remove `definition_name`; M-b change child name by one char;
M-c remove the HUMAN_TASK role; M-d drop the seed call; M-e revert version to `1.1`.

### 8.2 `test/letflow/engine/sub_process_service_task_after_test.exs` (NEW, DB-backed, `async: false`,
`Letflow.DataCase`, `Sandbox.mode(:auto)`, helpers copied in style from
`regulatory_review_timer_path_test.exs`, no optional-argument defaults per anti-pattern ISS-0069)

- E1 (the engine regression): parent graph `START -> SUB_PROCESS(definition_name child) -> SERVICE_TASK
  -> END`, child `START -> HUMAN_TASK -> END`. Complete the child task. Assert: parent status
  `:active`, `current_nodes == [service node id]`, EXACTLY ONE `service_task_dispatches` row for
  that node with `status "pending"` and a rendered URL; then mark `"advanced"` and call
  `Engine.advance_after_service_task_outcome/4` with `{:advance, %{}}`; assert parent
  `:completed`, no pending dispatch, no `EXECUTION_ERROR` event, `SUB_PROCESS_COMPLETED` present.
  FAILS on the unfixed tree (zero dispatch rows; exactly the probe output in section 2).
- E2: same parent but the node after the SUB_PROCESS is a `:TIMER`
  (`duration_iso8601` e.g. `PT1H`): assert one pending timer row for the parent token after the
  child completes (guards the timer half of the fix).
- E3: same but the node after the SUB_PROCESS is a HUMAN_TASK with `escalation_timer_duration`:
  assert the task row (existing behavior, unchanged) AND one pending `escalation` timer.
- E4 (negative/regression): parent `SUB_PROCESS -> HUMAN_TASK -> END` still works unchanged
  (existing `engine_sub_process_test.exs` coverage must stay green; run the whole file).
- E5 (error channel): SERVICE_TASK after the SUB_PROCESS whose endpoint renders empty
  (`{{variables.missing}}`) -> parent ends in ERROR via `ExecutionError` (not a crash), asserting
  the `activation_failed` mapping from section 3.1.
- E6 (the real fixtures end to end): load BOTH real fixture JSONs (`vortex_8d_corrective_action_definition.json`
  as `8D Corrective Action`, parent v1.2), start with `batch_ref`/`deviation_id`, advance
  `quarantine-batch` via the dispatch-stub idiom, complete `severity-classification` with
  `severity=critical`, `false_positive=false`, find the child by `parent_instance_id`, complete
  its `corrective-action-8d` task, assert a `close-deviation` dispatch row, stub-advance it,
  assert parent `:completed`. This is the executable form of the section 2 probe plus the final step.

Mutation targets for 8.2: M-f restore the `_more_pending` discard (E1/E2/E3/E6 fail);
M-g append the timer step but skip the dispatch step (E1/E6 fail, E2/E3 pass); M-h skip the
timer step (E2/E3 fail); M-i use `Ecto.UUID.generate()` instead of the persisted token id for the
dispatch `token_id` (FK/lookup failure, E1 fails).

### 8.3 Existing tests that must stay green
`test/letflow/engine_sub_process_test.exs`, `test/letflow/engine/sub_process_test.exs`,
`test/letflow/simulation/req207_vortex_test.exs`, `test/letflow/scripts/qa_fixture_service_task_endpoints_test.exs`,
`test/scripts/persona_actor_seed_drift_test.exs` (after section 7 flips),
`test/letflow/engine/regulatory_review_timer_path_test.exs`.

## 9. Ops / UAT note (not code)

After merge, QA needs a re-seed in this order: `seed_vortex_definition.sh` (creates
`8D Corrective Action` v1.0, deprecates Supplier Quality Deviation v1.1 -> v1.2 active; v1.1
in-flight instances keep their snapshot) then `seed_vortex_persona_actors.sh` (felix gains
`role-procurement-manager`). No QA data is changed by this PR. UAT-RUNNER finds the 8D task by
role (`GET /tasks` as `actor-vortex-felix`, or `?instance_id=<child instance id>`), NOT by the
parent instance id (the child is its own instance with `parent_instance_id` set).
EO-002's `definition_ref` text is a scenario-corpus id (resolved to the definition name by the new
alias sidecar), same situation as ISS-0897.

## 10. Files

Edit: `test/fixtures/qa/vortex_supplier_quality_deviation_process_definition.json`,
`scripts/seed_vortex_definition.sh`, `scripts/seed_vortex_persona_actors.sh`,
`test/scripts/persona_actor_seed_drift_test.exs`, `lib/letflow/engine/sub_process.ex`,
`lib/letflow/engine.ex` (add only the one `@doc false` public wrapper),
`test/fixtures/simulation/vortex/process_work_order.yaml` (optional parity),
`lib/letflow/design/iss0931-meridian-vortex-persona-actor-provisioning.md` (one sentence),
`docs/issues/ISS-0929.yaml` (status -> resolved by DOC-UPDATER, not here).
Create: the child fixture, the alias sidecar, `test/letflow/scripts/vortex_8d_subprocess_fixture_test.exs`,
`test/letflow/engine/sub_process_service_task_after_test.exs`, `test/specs/ISS-0929.md`
(TEST-DESIGNER).
Confirmed unaffected: scenario YAMLs (UAT and simulation), `scripts/uat_preflight.sh`,
`scripts/lib/seed_persona_actors_base.sh`, `seed_vortex_*` for production-order, all other QA fixtures.

## 11. Acceptance-criteria map

| Criterion (from the issue / diagnosis) | Design element |
|---|---|
| critical severity no longer ERRORs `SUB_PROCESS_DEFINITION_NOT_FOUND` | 4.1, 4.2, 5.1, F1-F2, E6 |
| 8D task assigned to `role-procurement-manager`, claimable by felix | 4.1, 5.2, 7, 9 |
| after the 8D completes the deviation closes (EO-003, COMPLETED at `end-closed`) | section 2 evidence, section 3, E1, E6 |
| no QA data change in this fix | section 0, 9 |
| drift guard stays consistent | section 7 |
| lib/ change justified; authz/tenant path untouched | section 2-3 |

## 12. Open questions

None blocking. Residual notes (decided, not open): reuse of the `:activation_failed` error
shape (3.1); possible event duplication is checked by E1's exactly-one-row assertion (3.1);
second-SUB_PROCESS-after-SUB_PROCESS follow-up issue is for ORCH (3.4). The one environment
caveat: the section 2 evidence is from a probe on the unfixed tree; the post-fix `COMPLETED`
outcome is asserted by E1/E6 and is not claimed as observed until ELIXIR-DEV runs them.
