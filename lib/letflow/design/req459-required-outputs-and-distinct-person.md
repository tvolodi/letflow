# Design: REQ-459 -- Required decision outputs (rule C) and the distinct-person rule (rule A) on HUMAN_TASK completion

**Requirement:** REQ-459 (sources GH #2335 / ISS-1039 / Q-1021 for rule C; GH #2323 / ISS-1034 / Q-1016 for rule A).
**Run:** `WF02-REQ459-20261007`, WF-02 Step 1. **Owner of the design:** CODE-DESIGNER.
**Validator:** CODE-DESIGN-VALIDATOR (hard gate; re-derives section 2 from `lib/letflow/engine.ex` independently).
**Builds from this design:** REQ-460 (rule C engine), REQ-461 (rule C validator), REQ-462 (rule C adoption),
REQ-463 (rule A engine), REQ-464 (rule A validator), REQ-465 / REQ-466 (rule A adoption).
**Design-only:** signatures, type shapes, numbered check orders and literal wire examples. No function bodies.

Evidence conventions: every `file:line` below was read on branch `design/REQ-459-required-outputs-distinct-person`
(HEAD `b7fed67b`). The last section lists every citation again so CODE-DESIGN-VALIDATOR can re-grep each one.
Where this design found that a REQ text does not match the code, it says so under "Adjustments for REQ-460..466".

The binding constraints of the design-intent owner (letflow-9a, plus the two BA rulings of 2026-10-07) are implemented,
not re-decided. The traceability table after section 12 has one row per constraint.

---

## 0. Summary of what the code does today (the facts the design rests on)

| Fact | Evidence |
|---|---|
| `Letflow.Engine.complete_task/3` is the only production caller path for a HUMAN_TASK completion; the one production caller is `Letflow.Routers.Tasks.handle_complete/3`. | `lib/letflow/engine.ex:2212-2231`; `lib/letflow/routers/tasks.ex:325-346` (the only `Engine.complete_task` call in `lib/`, line 340). |
| The completion runs as ONE `Ecto.Multi` inside `run_complete_task/6`: steps `:task`, `:instance_projection`, `:snapshot_and_state`, `:form_expression_reevaluation`, `:merge`, `:transition`, then a `Multi.merge` tail. | `lib/letflow/engine.ex:2263-2365`. |
| Before the first write the Multi only locks and reads. All writes sit in the tail built by `build_complete_task_tail_multi/6`. | `engine.ex:4328-4506`; the only `repo.update` / insert calls between lines 2260 and 5260 outside the tail are in the unrelated escalation-timer function (3056) and the tail helpers (4900, 5112, 5245). |
| The task row is locked (`FOR UPDATE`) first, the instance projection second. No isolation level is configured, so Postgres runs at its default READ COMMITTED (each statement gets a fresh snapshot). | `engine.ex:2458-2468`, `2473-2483`; `grep isolation lib config` returns nothing relevant. |
| `merge_output_variables/7` has exactly one caller: the `:merge` step. `VariableSchema.variable_validations/5` runs inside it and its per-key outcomes are handed to `VariableMerge.merge/3`; the first rejected key (sorted order) aborts the whole batch and today routes to `{:execution_error, args}` which commits instance ERROR. | `engine.ex:2321`, `3875-3903`, `3916-3943`; `lib/letflow/engine/variable_merge.ex:205-250`; `lib/letflow/engine/variable_schema.ex:279-301`. |
| The router mints a fresh idempotency key per request; the client cannot supply one. The whole JSON body is the output map. | `lib/letflow/routers/tasks.ex:330-337` (`idempotency_key = Ecto.UUID.generate()`, `output_variables = conn.body_params`). |
| `tasks.completed_by` is written with the same `actor_id` at completion; `tasks.node_id`, `tasks.instance_id`, `tasks.status` (`PENDING/COMPLETED/CANCELLED`) exist; the only index on the table apart from the primary key is `idx_task_instance (instance_id)` and `idx_task_token (token_id)`. | `lib/letflow/engine/task.ex:57-77`; `engine.ex:5102-5113`; `priv/repo/migrations/20260818110003_create_tasks.exs:87-88`; `priv/repo/migrations/20260820000006_drop_tenant_id_tasks.exs:4-7`. |
| An existing, decided pattern writes an audit row for a rolled-back transaction: a separate `Repo.transaction/1`, opened only after the failed transaction has returned (ISS-0784). | `engine.ex:4930-5021` (`record_task_activation_rejection_audit/5`), called from `interpret_complete_result/3` at `engine.ex:5307-5325`; `lib/letflow/design/iss0784-task-activation-rollback-audit-signal.md` sections 3-6. |
| Precedent for a "same person may not do both steps" refusal: `self_approval_forbidden`, mapped to HTTP 403. | `lib/letflow/definitions/promotion_review_store.ex:429-436`; `lib/letflow/routers/promotions.ex:603-604`. |

---

## 1. Definition schema: where `required_outputs` and `distinct_from` live, their types, and the reserved validator codes

### 1.1 Home and types

Both are new OPTIONAL string-keyed entries of the `attributes` map of a `HUMAN_TASK` node, next to `role`,
`escalation_timer_duration`, `escalation_role` and `form_schema`. The node struct is `Letflow.Definitions.Graph.Node`
(`lib/letflow/definitions/graph.ex:171-186`, `attributes: map() | nil`, populated by `Map.get(node, "attributes")` at
`graph.ex:354`). Example, wire shape (JSON definition, same shape the QA fixtures use, e.g.
`test/fixtures/qa/meridian_loan_origination_process_definition.json` node `l2-approval`):

```json
{
  "id": "l2-approval",
  "node_type": "HUMAN_TASK",
  "attributes": {
    "role": "role-credit-director",
    "escalation_timer_duration": "P2D",
    "escalation_role": "role-ceo",
    "required_outputs": ["l2_decision"],
    "distinct_from": ["l1-approval"],
    "form_schema": { "type": "object", "properties": { "l2_decision": { "type": "string", "enum": ["approve", "reject"] } } }
  }
}
```

| Attribute | Type | Meaning | Absent / `null` / `[]` |
|---|---|---|---|
| `required_outputs` | list of non-empty strings, no duplicates; each string is ONE top-level variable key (flat, like `variable_schemas.variable_key`, `variable_schema.ex:162-168`; no nested paths) | keys that the SUBMITTED `output_variables` of a completion of this node must carry as non-null values | rule C is off for this node |
| `distinct_from` | list of non-empty strings, no duplicates, never the node's own id; each string is the id of another HUMAN_TASK node of the same definition | nodes whose most recent completion, in the same instance, must not have been made by the user who now completes this node | rule A is off for this node |

`null` is treated as absent, exactly as `human_task_escalation_violations/2` treats a `null` escalation attribute
(`graph.ex:1073-1078`). An empty list is legal and equals "off". The attributes are read at completion from the
instance's immutable definition snapshot (`fetch_graph/2`, `engine.ex:2512-2518`), the same graph that routes the
completion, so editing a definition never changes a running instance's guards. Neither attribute is copied onto the
`tasks` row (no migration; contrast `form_schema`, which is). Neither is added to the task-detail response allowlist
(`task_detail_map/3`, `routers/tasks.ex:626`, INV-2): the UI hint stays `form_schema.required` (REQ-273).

Runtime reading is total (INV-8): a value that is not a list of non-empty strings is read as "off" and one
`Logger.warning` naming only the node id is emitted. This is unreachable for any definition that passed the
validators below (the shape violations block `Definitions.create/2` and `update`, `definitions.ex:561`, `1682`) and exists
only so a snapshot written by a path that bypassed validation cannot crash a completion.

No Ecto schema, table, column, index or constraint is added. No gen_statem or process state is added.

### 1.2 Reserved validator codes

New members of the closed union `Letflow.Definitions.Graph.Violation.code()` (`graph.ex:222-260`). Checks are numbered
CHK-25..CHK-27 (CHK-22..CHK-24 are taken by REQ-455, `graph.ex:57-69`, `486-497`; `grep CHK-2[5-9]` finds none).
CHK-25..27 are appended, in this order, to the list inside `Graph.validate_node_attributes/1` after
`check_human_task_escalation/1` (`graph.ex:436-450`), so they run at every place that function runs: `create/2`
(`definitions.ex:557-561`), `update` (`definitions.ex:1675-1682`), `validate_definition_graph/2`
(`definitions.ex:1272-1297`), import and pack install (both reach `create/2`).

| Code | Severity | Reserved for | Where it is produced | Fires when |
|---|---|---|---|---|
| `:invalid_required_outputs` | VIOLATION | REQ-461 check 1 | CHK-25 `check_required_outputs/1`, `graph.ex` | on a HUMAN_TASK: value is not a list, an entry is not a non-empty string, or an entry is duplicated. Message names node id and (for entry errors) the offending entry; one violation per defect. |
| `:required_outputs_on_non_human_task` | VIOLATION | REQ-461 check 1 | CHK-25 | the attribute is present (non-null) on a node whose type is not HUMAN_TASK. |
| `:required_output_without_variable_schema` | VIOLATION | REQ-461 check 2 | `Letflow.Definitions.SemanticValidation.required_output_schema_violations/2` (new public function), called from BOTH clauses of `SemanticValidation.validate/2` | a key in a HUMAN_TASK's `required_outputs` has no entry in `declared_fields`. Message names node id and key. |
| `decision_key_not_required:` (string prefix, not an atom) | WARNING, permanent (section 1.4) | REQ-461 check 3 | `SemanticValidation.decision_key_warnings/2` (new public function, pure) | see 1.4. |
| `:invalid_distinct_from` | VIOLATION | REQ-464 check 1 | CHK-26 `check_distinct_from/1`, `graph.ex` | on a HUMAN_TASK: not a list, an entry is not a non-empty string, or an entry is duplicated. |
| `:distinct_from_on_non_human_task` | VIOLATION | REQ-464 check 1 | CHK-26 | attribute present (non-null) on a non-HUMAN_TASK node. |
| `:distinct_from_self_reference` | VIOLATION | REQ-464 check 1 | CHK-26 | the list contains the node's own id. |
| `:distinct_from_unknown_node` | VIOLATION | REQ-464 check 2 | CHK-26 | a listed id is not a node of the same definition. Message names node id and listed id. |
| `:distinct_from_not_human_task` | VIOLATION | REQ-464 check 2 | CHK-26 | a listed id exists but is not a HUMAN_TASK (only HUMAN_TASKs write `tasks.completed_by`, so such a constraint could never bind). |
| `:distinct_from_downstream_only` | VIOLATION | REQ-464 check 3 | CHK-27 `check_distinct_from_position/1`, `graph.ex` (uses `build_adjacency/2`, `graph.ex:856`) | this node has a path to the listed node and the listed node has NO path back to this node. Message names both ids. |
| `distinct_from_single_member_role:` (string prefix) | WARNING | REQ-464 check 4 | new functions in `Letflow.Definitions.RoleBinding`, section 1.5 | see 1.5. |

Each code has one defect per violation and the existing never-short-circuit concatenation applies; no check
suppresses another. Codes for violations are atoms that `violation_map/1` stringifies without change
(`lib/letflow/routers/definitions.ex:1244-1246`, per `req455-definition-validator-gaps.md` section 1); `web/src` lists no
violation code, so no client change.

Required message fragments (tests assert on code, node id and key/id; the fragments keep REQ-461/464 tests stable):
`"Node '<id>' (HUMAN_TASK) has required_outputs key '<key>' with no variable_schema"`,
`"Node '<id>' (HUMAN_TASK) lists '<other>' in distinct_from, but '<other>' is reachable only after '<id>'"`. Other texts are
ELIXIR-DEV's, mirroring the CHK-21 messages at `graph.ex:1085`, `1094`, `1103`.

### 1.3 Where check 2 runs, and the empty-schema trap

`SemanticValidation.validate/2` returns `%{valid: true, violations: []}` immediately when `declared_fields == %{}`
(`semantic_validation.ex:189-192`; moduledoc "Empty-declared_fields exemption", `128-141`). That exemption is correct for
the field-existence classes but WRONG for check 2: a definition that declares `required_outputs: ["decision"]` and
registers no `variable_schemas` at all is exactly the defect check 2 exists to report. Therefore
`required_output_schema_violations/2` is called from both clauses and its result is the only class the first clause
returns. It runs only where `SemanticValidation.validate/2` runs: `validate_definition_graph/2`
(`definitions.ex:1272-1284`) and `activate/2` via `run_semantic_validation/2` (`definitions.ex:2372-2385`). It cannot run
at `create/2`/`update`/import, because `variable_schemas` rows are registered after the definition row exists
(`variable_schema.ex` moduledoc, REQ-078). REQ-461's "validate, activate, import" is therefore met as: shape checks at
all of validate/create/update/import/install; check 2 at validate and activate (an imported definition is validated at
its next activation or validate call, same as every REQ-372 class).

### 1.4 Check 3 (decision reads): which keys count, and the severity

Decision readers are the conditional outgoing edges of the two node kinds CHK-14 allows a condition on:
EXCLUSIVE_GATEWAY and HUMAN_TASK (`graph.ex` CHK-14 `check_unpermitted_edge_condition/1`; see
`req455-definition-validator-gaps.md` section 2 table). For a reader edge `E` with source `S`, a **decision key** is the
root segment of any variable path in `E.condition`, extracted with the same translate-and-parse used by
`SemanticValidation` (`parse_condition/1`, `semantic_validation.ex:440`; `collect_var_paths/1`, `486-503`; root = `hd(path)`).
Let `U(S)` be `ancestors_or_self(S)` (`semantic_validation.ex:266-294`, every node on any path START -> S, S included
because its own completion writes before its edges are read).

* `producers(K, S)` = HUMAN_TASKs in `U(S)` whose `form_schema.properties` contains `K` (the output the form collects).
* `declarers(K, S)` = HUMAN_TASKs in `U(S)` whose `required_outputs` contains `K`.
* A warning is produced for `(E, K)` iff `producers(K, S)` is non-empty AND `declarers(K, S)` is empty. If no HUMAN_TASK
  produces `K` the key is not a human-task decision output (service responses, start variables, sub-process outputs): not
  this check's concern (`:variable_never_collected`, REQ-455, covers the never-set case). This is exactly REQ-461 item 3
  and the binding text "a decision reading a key that no upstream task declares in required_outputs"; it is NOT
  strengthened (see Open question OQ-3).
* Wire text (single place it is built): `"decision_key_not_required: <key> (definition '<definition name>', edge '<edge id>' from node '<S>' reads it; produced by: <producer ids sorted, comma separated>)"`. One warning per (edge, key). The stable prefix lets callers filter, as `unbound_task_role:` does
  (`role_binding.ex:57-60`).

**Severity decided here: WARNING, permanently, not a violation.** Reasons, each checkable:
1. REQ-462 explicitly leaves decision keys of meridian `credit_decision`, `risk_rating`, the three committee votes and
   the regulatory review UNADOPTED (REQ-462 BUILDS "Deliberately NOT in this list"), yet edges of those same definitions read
   them. A violation would make `validate_definition_graph/2` report those definitions invalid and `activate/2` refuse them
   (`SemanticValidation` runs there, `definitions.ex:1284`, `2372-2385`; it does NOT run in `create/2`, `definitions.ex:557-561`),
   so the seeded meridian definitions could no longer be activated, breaking the seed scripts and the QA suites in the same
   change that adopts the eleven listed nodes.
2. A violation would reject every tenant-authored definition that reads a form-sourced key without declaring it, with no BA
   ruling authorising that breaking change; the binding text says "flags", and the rule-A text that says "OFF by default"
   shows the owner knows how to say "reject".
3. The runtime control (sections 2-3) is what actually protects an instance; check 3 is the authoring lint that tells the
   author the control is not switched on.
4. Raising it to a violation later is a one-line severity change in the code table above plus a re-adoption sweep; it is
   reversible, a violation shipped now is not cheaply reversible.

Consequence stated for REQ-461/REQ-462: there is no later "severity switch" (REQ-461 open_questions default, REQ-462
BUILDS item 3). Warnings appear in the `warnings` list of the `POST /definitions/:id/validate` 200 body and of the pack
install result, NOT in the activate response (record-shaped, `req455-definition-validator-gaps.md` section 5 table).

Surfacing: a new aggregator `Letflow.Definitions.ValidationWarnings` (new module, created by REQ-461, extended by REQ-464):

```elixir
@spec for_definitions([{definition_name :: String.t(), Graph.t()}], opts :: [prefix: String.t()]) :: [String.t()]
```

It concatenates, in this order: `RoleBinding.warnings_for_definitions/2` output (`unbound_task_role:` lines,
`role_binding.ex:66-74`), `decision_key_warnings` lines, `distinct_from_single_member_role:` lines. The two existing call
sites switch to it: `Definitions.validate_definition_graph/2` (`definitions.ex:1286-1287`) and
`SolutionPack.unbound_role_warnings/2` (`solution_pack.ex:1397-1411`, merged at `1389`). The warnings type stays
`[String.t()]` (REQ-455 OQ-7), so no response-shape change.

### 1.5 Inputs REQ-464 consumes (and how the BA parallel-branch ruling shapes them)

Three pure inputs and one query.

1. **Reachability relation** between every ordered pair of HUMAN_TASKs, from the same forward adjacency the flow checks
   use (`build_adjacency/2`, `graph.ex:856`, resolved edges only, dangling edges contribute nothing). For this node `N` and
   a listed node `X`, with `reach(a,b)` meaning "a path from a to b exists":

   | Relation | Meaning | CHK-27 outcome |
   |---|---|---|
   | `reach(X,N)` and not `reach(N,X)` | `X` precedes `N` | pass |
   | `reach(X,N)` and `reach(N,X)` | rework loop (path both ways) | pass |
   | neither | parallel branch, or mutually exclusive branch | pass (BA 2026-10-07: strict precedence applies only when the nodes are on the same path) |
   | `reach(N,X)` and not `reach(X,N)` | `X` is reachable only after `N` | `:distinct_from_downstream_only` |

   Consequence of the ruling: three parallel nodes P1, P2, P3 may each name the other two with no violation; a node and its
   own downstream successor may NOT name each other (the earlier node's list would name a downstream-only node).
   A node that is itself unreachable from START has no path either way and passes CHK-27; CHK-22 reports it separately.
2. **Role attribute of both nodes**: `attributes["role"]` only (not `escalation_role`), per REQ-464's own open-question default.
3. **Node pair list**: the unordered pairs `{N, X}` taken from `N`'s `distinct_from`, deduplicated when both nodes name each
   other (one warning per unordered pair, ids sorted ascending).
4. **Member count of a role** in the installing tenant (the only query). A user holds a role iff a `group_members` row binds
   the user to the group bound to the `tenant_role` of that name; this is exactly how `Letflow.Tasks.resolve_principal_scope/2`
   resolves it (`tasks.ex:353-374`). New functions in `RoleBinding`:

```elixir
@spec single_member_pairs(Graph.t()) :: [%{role_name: String.t(), node_ids: [String.t()]}]   # pure: pairs sharing a non-blank role
@spec member_counts(role_names :: [String.t()], opts :: [prefix: String.t()]) :: %{optional(String.t()) => non_neg_integer()}
@spec format_single_member_warning(definition_name :: String.t(), %{role_name: String.t(), node_ids: [String.t()]}) :: String.t()
```

   Wire text: `"distinct_from_single_member_role: <role> (definition '<definition name>', nodes: <idA>, <idB>)"`. The query runs once per
   call and only when `single_member_pairs/1` is non-empty (zero extra queries for a definition with no `distinct_from`).
   The warning applies equally to preceding, parallel and loop pairs: two parallel nodes of one single-member role stall the
   join as surely as a straight path does. A warning is produced only for a role with exactly one member; zero members is the
   `unbound_task_role:` / empty-group case, not this one. Evaluated where tenant role membership is known (install, and
   `validate_definition_graph/2`, which already has the prefix); at `Graph` validation without a tenant it is not evaluated.

---

## 2. ONE check order inside `run_complete_task`

Notation: `[pure]` no I/O; `[read]` a SELECT; `[lock]` `SELECT ... FOR UPDATE`; `[write]` an INSERT/UPDATE;
`[REFUSE-x]` a refusal point. "Today" = already exists on `main`; "NEW" = added by this design. Steps are in execution
order; no step is reordered relative to today's code except by the insertion of the NEW steps.

### 2.1 Before the transaction opens

R1. Plug pipeline authenticates, resolves the tenant, authorizes `:TasksComplete` (`routers/tasks.ex:142`). Today.
R2. `Tasks.authorize_completion/3` `[read]` (`routers/tasks.ex:328`; `tasks.ex:539-547`: `Repo.get` of the task plus
    `resolve_principal_scope/2`, two reads) -> 403 for a wrong assignee. Today, unchanged by this design (rule A is NOT
    duplicated here: the authority must run under the instance lock, step 7).
R3. `idempotency_key = Ecto.UUID.generate()` `[pure]` (`routers/tasks.ex:331`); `attrs = %{output_variables, actor_id, idempotency_key}` (336).
P1. `cast_task_id/1` `[pure]` (`engine.ex:2245`) -> `:invalid_task_id`.
P2. `fetch_output_variables/1` `[pure]` (`engine.ex:2252`) -> `:invalid_output_variables` (422 today).
P3. `TenantProvisioning.tenant_id_for_schema_name/1` `[read]` (`engine.ex:2217`; `tenant_provisioning.ex:243`).
P4. `actor_id`, `idempotency_key` read with `Map.get/2`; `completed_at` clock read (`engine.ex:2218-2220`).

### 2.2 Inside `Repo.transaction/1` (`engine.ex:2358`)

1. `:task` `[lock]` `fetch_and_lock_task/3` (`engine.ex:2458-2468`): `FOR UPDATE` on the `tasks` row.
   -> `:task_not_found` | `{:task_not_pending, :completed | :cancelled}` (a replay of an accepted completion, and a task
   cancelled by an escalation timer, both end here; neither reaches any step below).
2. `:instance_projection` `[lock]` `fetch_and_lock_instance_projection/3` (`engine.ex:2473-2483`): `FOR UPDATE` on the
   `instance_projections` row. -> `:instance_not_found` | `{:instance_not_active, status}`.
3. `:snapshot_and_state` `[read]` `build_snapshot_and_state/4` (`engine.ex:2490-2508`): `SnapshotStore.get_by_instance_id/2`
   via `fetch_graph/2` (2512-2518) and `build_graph/1` (1538), `load_active_tokens/3` (2525), `find_token_for_task/2` (2549),
   `load_pending_task_tokens/3` (2572), `build_instance_state/3` (2591). -> `:snapshot_not_found` |
   `{:graph_structure_invalid, _}` | `{:missing_token_record, _}`.
4. **NEW `:completion_guards`** (a `Multi.run/3` step inserted between `:snapshot_and_state` (`engine.ex:2277`) and
   `:form_expression_reevaluation` (2280)). It finds the node `task.node_id` in `graph.nodes`, reads its two attributes
   (section 1.1) and runs, in this order:
   4a. `[pure]` if the node has neither a non-empty `distinct_from` nor a non-empty `required_outputs`: return `{:ok, :no_guards}`.
       No query is issued. For THIS step the default-off path is byte-identical in behaviour and query count to today. It is NOT
       true of the whole completion: step 6b-iv refuses a schema-rejected value on EVERY HUMAN_TASK completion, including nodes
       with neither attribute (that is why the five existing ERROR-on-rejection tests must change).
       On the pass path the step returns `{:ok, :guards_passed}` (any guard present and satisfied) or `{:ok, :no_guards}`; the
       payload is not read by any later step.
   4b. **Rule A** `[read]` (only if `distinct_from` is non-empty AND `actor_id` is a binary; a nil actor never equals a
       completer and the existing event-append requirement still rejects it later): ONE query inside the single entry point
       `SeparationOfDuties.check/5` (section 8.2; the private `blocking_nodes/5` it uses is not called by the engine step) -> on
       `{:error, {:separation_of_duties, blocking_node_ids}}`, **`[REFUSE-A]`** return
       `{:error, {:completion_refused, {:separation_of_duties, blocking_node_ids}}}`.
   4c. **Rule C, submitted check** `[pure]` (only if `required_outputs` is non-empty):
       `RequiredOutputs.missing_keys(required, output_variables)` with `required` = `RequiredOutputs.required_outputs(node)` and
       `output_variables` = the SUBMITTED map handed to `run_complete_task/6`, before correction. -> if non-empty, **`[REFUSE-C1]`** return
       `{:error, {:completion_refused, {:output_refused, missing_keys, []}}}`.
   Decision on COMPUTED fields: a key that a form field marks `x-ui.computed` MAY NOT usefully be named in `required_outputs`.
   Step 4c judges the submitted map, and step 5 recomputes computed fields server-side afterwards, so a client that omits a computed
   key is refused at 4c even though the server would have computed it (REQ-460 item 2 says SUBMITTED, literally). Authors must not list
   computed fields; the validator does not flag it (no check added); the corrected-map check 6b-ii applies to them as to any key.
   Why A before C: authorization-type decisions precede input validation (403 before 422), and a caller who can never
   complete the task is not told what a valid body would look like. Why both before step 5: see 2.5.
5. `:form_expression_reevaluation` `[pure]` `FormExpressionReevaluation.reevaluate/3` (`engine.ex:2280-2299`;
   `form_expression_reevaluation.ex:154-194`). Always `{:ok, _}` structurally; its domain error is carried inside.
6. `:merge` (`engine.ex:2300-2331`):
   6a. reevaluation domain error -> `build_reevaluation_execution_error_args/5` (`engine.ex:3960-3977`) -> `{:ok, {:execution_error, args}}`:
       **UNCHANGED** (BA 2026-10-07: definition defect, still EXECUTION_ERROR). Steps 6b* below do NOT run for it.
   6b. otherwise `merge_output_variables/7` (`engine.ex:3875-3903`), whose body is amended as follows (it is the only caller;
       `engine.ex:2321`):
       6b-i.   `[read]` `VariableSchema.variable_validations/5` (`variable_schema.ex:287-301`; one SELECT of
               `variable_schemas` for the definition, `fetch_schemas/3`, 336-348; zero queries when the corrected output is empty,
               line 293). Runs once; its result is reused below and by 6b-v (no second read).
       6b-ii.  `[pure]` **Rule C, corrected check**: `RequiredOutputs.missing_keys/2` over the CORRECTED output map
               (`corrected_output_variables` from step 5; computed fields forcibly recomputed, `visible_when: false` values
               dropped) for the same `required_outputs`. Catches a required key that step 5 dropped or computed to null, which 4c
               could not see.
       6b-iii. `[pure]` `RequiredOutputs.rejected_keys/3`: every key whose validation outcome is `{:rejected, _}`, excluding
               keys already in `missing_keys` (a null value on a required key is "missing", not "rejected", BA 2026-10-07), and
               RESTRICTED to the ALLOWED set (computed by `RequiredOutputs.allowed_keys/2`) = (keys of the task's own pinned `form_schema.properties`, `task.form_schema`) UNION
               (`required_outputs`). Sorted ascending. A rejected key outside the allowed set is still a rejection (the batch is
               refused, nothing is merged, whole-batch semantics preserved) but its NAME is not reported anywhere (body or audit):
               otherwise any task worker could probe which variable keys have a `variable_schema` in the definition (INV-2). Let
               `any_rejected?` = whether at least one key had `{:rejected, _}` (computed before restriction).
       6b-iv.  if `missing_keys` is non-empty, `rejected_keys` is non-empty, or `any_rejected?`: **`[REFUSE-C2]`** return
               `{:error, {:completion_refused, {:output_refused, missing_keys, rejected_keys}}}` from the step.
       6b-v.   else `apply_variable_merge/6` (`engine.ex:3916-3943`) -> `VariableMerge.merge/3` `[pure]` -> `{:merged, ...}`.
               Its `{:rejected, ...}` -> `{:execution_error, ...}` clause (3928-3941) becomes unreachable on this path (the
               same validations were just checked); it is retained as a last-resort guard with a comment, the same disposition
               `variable_schema.ex:417-433` documents for its own unreachable clause.
   `prepend_form_expression_events/2` (`engine.ex:3992-3999`) unchanged.
7. `:transition` `[read, pure]` `dispatch_task_completion_hop_chain/7` (`engine.ex:4020-4147`): `Transition.transition/3`,
   `advance_until_stable/4` (1474), `prepare_timer_arms/4` (692), `prepare_service_task_dispatch_for_completion/8` (4161; may read
   catalog pins), `prepare_sub_process_children_for_completion/8` (4238). No writes. Its own `{:execution_error, _}` outcomes
   (no matching gateway edge, empty URL, catalog resolution, sub-process interface) are UNCHANGED.
8. Tail `Multi.merge` (`engine.ex:2348-2357` -> `build_complete_task_tail_multi/6`, 4328 / 4343). First clause (4328-4341), taken
   when step 7 produced `{:execution_error, _}`: `ExecutionError.append_multi/3` (instance -> ERROR plus one EXECUTION_ERROR
   event) and the outcome marker; unchanged. Second clause (4343-4506), the success path, writes in this order:
   W1 `{:hop_chain_token_records, instance_id}` `[write]` join-minted token rows (4637 -> `insert_hop_chain_new_token_records/5`, 4755);
   W2 `{:task_records, instance_id}` `[write]` next HUMAN_TASK rows (`TaskActivation.append_multi_from_existing_records`, `task_activation.ex:358`; skipped when `skip_task_activation?`, 4377);
   W3 `:token_reconciliation` `[write]` (4838 -> 4849-4895);
   W4 timer arms `[write]` (`build_timer_arms_multi/4`, 825; called at 4413);
   W5 service-task dispatch inserts `[write]` (`build_service_task_dispatch_multi/5`, 1304; called at 4436);
   W6 `:task_complete` `[write]` `complete_task_row/6` (5102-5113): status COMPLETED, `completed_by = actor_id`, `completed_at`, `output_variables`;
   W7 `:cancel_escalation_timers` `[write]` (4458-4469 -> `TaskActivation.cancel_pending_escalation_timers/6`, `task_activation.ex:533-547`);
   W8 `:audit` `[write]` `record_task_complete_audit/4` (4470-4472; 4911-4928, action `"task.complete"`);
   W9 `:event` `[write]` `append_task_completed_event/5` (4473-4481; 5127-5158) -> `EventStore.append/2` (guard, sequence, idempotency claim `event_store.ex:649-676`, insert, projection seq);
   W10 `:projection` `[write]` `reconcile_projection/5` (4482-4490; 5222-5246);
   W11 sub-process children creation `[write]` (4491-4497; 4513-4532);
   W12 sub-process completion cascade `[write]` (4498-4504; 4542-4592);
   W13 `:complete_task_outcome` marker (4505).
8z. Exit path outside the order: `run_complete_task/6` is wrapped in a function-level `rescue` (`engine.ex:2362-2364`) that turns any
    raised exception in ANY step above (including the new step 4 and step 6b) into `{:error, {:transaction_failed, exception}}`,
    i.e. a 500 at the router (`routers/tasks.ex:425`); the transaction has rolled back, no refusal audit row is written for it,
    and no refusal body is produced.
9. COMMIT. Then, outside the transaction and still inside `run_complete_task/6`: `maybe_snapshot_after_complete_task/2` (2418-2454),
   `emit_task_completed_telemetry/2` (2384-2405), `interpret_complete_result/3` (5258-5325).

Locks: exactly the two already taken (steps 1 and 2). This design adds NO lock, no advisory lock and no new lock order.
(The escalation-timer path already locks instance then task, `engine.ex:2917`, 3033-3037; that pre-existing inversion is
not touched and not worsened.)

### 2.3 Per refusal path: what has happened, what is written

| Path | Reached after steps | Written before the refusal | State at refusal | After the refusal |
|---|---|---|---|---|
| **REFUSE-A** (4b) | P1-P4, 1, 2, 3, the single tasks read of 4b | NOTHING. Steps 1-2 take row locks (no column changes); 3 and 4b are SELECTs. | `Multi.run` returned `{:error, ...}`; no data write has occurred | transaction ROLLBACK (locks released); exactly one audit record is written in a separate transaction (2.4) |
| **REFUSE-C1** (4c) | P1-P4, 1, 2, 3, (4b if it passed) | NOTHING | same | same |
| **REFUSE-C2** (6b-iv) | P1-P4, 1, 2, 3, 4, 5, 6a-no, 6b-i..iii | NOTHING (steps 5, 6b-ii, 6b-iii are pure; 6b-i is a SELECT) | same | same |

For all three: no `tasks` row changed (still PENDING, assignment unchanged, so claimable), no `instance_projections` change
(status, `variables`, `current_nodes`, `join_counters`, `last_event_seq`), no token change, no timer change (an armed
escalation timer is NOT cancelled and NOT extended: only W7, which is on the success path, cancels it), no event
appended (no `instance_sequence` advance, no idempotency row), no `maybe_snapshot_after_complete_task` write (it matches only
`{:ok, ...}`, `engine.ex:2418-2454`), no `[:letflow, :task, :completed]` telemetry (2384-2405), no `EXECUTION_ERROR`, no
instance ERROR. The statement "nothing is written" counts row locks as not-a-write because they change no column value;
tests prove it by comparing the full rows (including `updated_at`) and event counts before and after.

### 2.4 How the one audit record survives a rolled-back Multi

The refusal is an `{:error, step, value, changes}` result of `Repo.transaction/1`; Postgres has rolled back. Any
`Audit.append_multi/4` step placed inside this Multi would roll back with it (ISS-0784 design section 3, `engine.ex:4930-4945`).
The record is therefore written by a NEW public `@doc false` function modelled on `record_task_activation_rejection_audit/5`
(`engine.ex:4971-5021`), called from `interpret_complete_result/3`'s error clause (`engine.ex:5307-5325`) strictly after
`Repo.transaction/1` has returned:

```elixir
@type completion_refusal ::
        {:separation_of_duties, blocking_node_ids :: [String.t()]}
        | {:output_refused, missing_keys :: [String.t()], rejected_keys :: [String.t()]}

@doc false
@spec record_completion_refusal_audit(
        instance_id :: Ecto.UUID.t(),
        task_id :: Ecto.UUID.t(),
        node_id :: String.t(),
        actor_id :: Ecto.UUID.t() | nil,
        refusal :: completion_refusal(),
        prefix :: String.t()
      ) :: :ok
```

Properties (each is a test): it opens its own `Repo.transaction(fn -> Audit.insert_entry(Repo, attrs, prefix) end)` run
synchronously (never backgrounded); it carries a function-level `rescue` that logs and returns `:ok` (the ISS-0946 /
ISS-0969 / ISS-0980 / ISS-0981 / ISS-0983 arc in `docs/anti-patterns.md:4474-4530` is exactly "a best-effort audit write
without a rescue", and its fifth round warns that the helper `append_multi/4` hides the same call: this design uses the
direct `insert_entry/3` shape and adds a DROP-TABLE regression test, section 12); it is called from exactly one clause, so
one refused request writes at most one record; it returns `:ok` whether the insert succeeded or not (a failed audit write
logs one warning and the refusal response is unchanged; with a healthy audit store the count is exactly one, with a
failing one it is zero and a warning is logged, never two). **The guarantee is therefore "at most one audit record per refused request, exactly one when the audit store is healthy"; it is NOT "exactly one always"** (D-3). The public result is built from `reason` (the `completion_refused` tuple), not from the audit
outcome.

Invariant the design adds: `Engine.complete_task/3` must not be called inside an enclosing `Repo.transaction`, or the audit
row would join (and roll back with) that outer transaction. Today the single caller is the router
(`routers/tasks.ex:340`), which opens none. A test calls the router end to end and counts the audit row after the refusal.

How the refusal leaves the Multi and reaches the caller: the two refusing steps return
`{:error, {:completion_refused, completion_refusal()}}`; `interpret_complete_result/3`'s catch-all error clause (5307) gets a new
leading branch for that tuple which calls `record_completion_refusal_audit/6` (instance id and task id and node id read from
`changes.task`, which is always present because step 1 ran) and returns the PUBLIC error:

```elixir
@type complete_error_additions ::
        {:error, :separation_of_duties}
        | {:error, {:output_refused, %{missing_keys: [String.t()], rejected_keys: [String.t()]}}}
```

(added to `complete_error` at `engine.ex:2141-2162`, immediately before the trailing `{:error, term()}`). The public
`:separation_of_duties` carries no detail at all; the blocking node ids reach only the audit record.

### 2.5 Why this order (the argument CODE-DESIGN-VALIDATOR should re-derive)

* **Guards after step 2 (instance lock held).** Rule A compares the actor with COMMITTED completions of the same instance. Two
  parallel nodes P1 and P2 completed concurrently by one user each lock their own task row, then queue on the instance row.
  The second to acquire it runs its guard SELECT after the first has committed; in READ COMMITTED that statement sees the first
  completion's row. Placing the read before step 2 would let both pass. This is the lock-ordering proof for the BA parallel-branch ruling.
* **Guards after step 3.** The node attributes live in the instance snapshot graph, which step 3 loads and decodes.
* **4b/4c before step 5.** Step 5's domain error ends in a COMMITTED state change (instance ERROR, step 8 first clause). A
  caller error (wrong person, missing key) must be refused before any path that can commit. 4c therefore judges the submitted map.
* **The schema check inside step 6b, not a separate step.** It needs `projection.definition_id` (step 2) and the corrected map
  (step 5), and `merge_output_variables/7` already performs the one `variable_schemas` read; a separate step would read twice.
* **6b-ii as well as 4c.** 4c literally implements "SUBMITTED output_variables lack a required key" and gives caller errors
  precedence over reevaluation errors. 6b-ii closes the one hole 4c leaves: a key that is submitted but then dropped by
  `visible_when: false` or recomputed to null by a `computed` field would otherwise merge as absent and recreate the silent
  fail-closed route. Only the submitted-and-surviving case counts as "provided".
* **A value already on the instance never counts**: both checks read only the submitted/corrected maps, never
  `seed_state.variables` or `projection.variables` (REQ-460 item 2, rework loop).
* **Precedence among outcomes**: existing steps 1-3 errors (not found / not pending / not active) first; then A; then C1;
  then (reevaluation error -> EXECUTION_ERROR unchanged, BA); then C2; then success. A submission with a missing required key
  AND a failing cross-field validation gets the 422 (C1 runs first); a submission whose required keys are present but fails a
  cross-field validation still ends in EXECUTION_ERROR exactly as today.

---

## 3. The 422 body for rule C, and the retry contract

### 3.1 Status and justification against the existing error contract

422. `handle_complete_result/2` already uses 422 for "the request body is not an acceptable output" (`:invalid_output_variables`
`routers/tasks.ex:356-358`; changeset `376-378`) and 409 for "resend cannot help until state changes" (`:task_not_pending`
364-366; `:instance_not_active` 372-374; the post-commit instance-ERROR mapping of ISS-0917, 401-411). A refused-and-unchanged
completion that the same caller can fix by resending a corrected body is the 422 class. REQ-460's open question asked the design to
report a conflict with the contract: **none found**. The 409 at 408-411 is the behaviour this design removes for this path.

### 3.2 Body

Built by a new constructor and sender (the extension mechanism already exists: `Letflow.Api.Error` `extensions`,
`error.ex:121-151`, used by `promotion_conflict/2`, `404-410`):

```elixir
@spec Letflow.Api.Error.output_refused(missing_keys :: [String.t()], rejected_keys :: [String.t()]) :: Letflow.Api.Error.t()
@spec Letflow.Api.Response.output_refused(Plug.Conn.t(), missing_keys :: [String.t()], rejected_keys :: [String.t()]) :: Plug.Conn.t()
```

Content-Type `application/problem+json`, status 422, literal example (default problems base URI, `error.ex:60-64`; `trace_id`
spliced by `Response.send_problem/2`, `response.ex:115-122`):

```json
{
  "type": "https://bpm.example.com/problems/output-refused",
  "title": "Output Refused",
  "status": 422,
  "detail": "the submitted output was refused; resend the complete output",
  "trace_id": "d0c6b8f0-5a41-4a52-9d3c-0e27b1b1a3f7",
  "code": "output_refused",
  "missing_keys": ["decision"],
  "rejected_keys": []
}
```

Second example (a value rejected by the key's `variable_schema`; the value and the enum are NOT in the body):

```json
{
  "type": "https://bpm.example.com/problems/output-refused",
  "title": "Output Refused",
  "status": 422,
  "detail": "the submitted output was refused; resend the complete output",
  "trace_id": "6b6f4b56-8d4f-4f0a-9a54-3a0c8b7d2e11",
  "code": "output_refused",
  "missing_keys": [],
  "rejected_keys": ["decision"]
}
```

Rules: `code` is the constant `"output_refused"`; `missing_keys` = required keys that are absent or null in the submitted (4c) or
corrected (6b-ii) map; `rejected_keys` = keys with a rejecting `variable_schema` outcome (6b-iii); both lists are sorted
ascending and deduplicated. Both lists may be empty only in one case: every rejected key lies outside the allowed set (the task's
own `form_schema.properties` plus `required_outputs`); the 422 is then returned with `"missing_keys": []` and `"rejected_keys": []`
and the same `detail`, so the response confirms a refusal but names nothing (SECURITY-REVIEWER finding F-1: refuse rather than drop, because silently
dropping a submitted value would merge a different output than the caller sent, and refusing keeps the existing whole-batch rule). Key
names come only from the task's own form and `required_outputs`, never from the caller's input or other keys' schemas, so no
caller-chosen string is echoed and no other key NAME is revealed (INV-2). Residual, accepted (SECURITY-REVIEWER R2-1): a caller who guesses a key name can infer from 422-versus-accept whether a rejecting schema exists for it; this needs one guess per task and is no wider than today's ERROR/409 behaviour. The body contains no submitted value, no
enum or schema text, no `ValidationFailure.field_path`/`message`, no instance id, no task id, no other-task data, no module
or SQL text (INV-4 style: the constructor has no parameter that could carry them). An empty-string value of a required key is "present": the schema's type and enum decide, so it appears under `rejected_keys` when the schema refuses it.

Retry note for the empty-lists case: the client cannot tell which key failed; it resends output limited to the task's own form fields.
A refusal reports every key of the check that failed: C1 (4c) can only report `missing_keys`; C2 (6b-iv) reports both lists in one
response. A client can therefore need two round trips (first missing, then rejected); this is stated, not hidden, because
validating schemas before reevaluation would compute them against uncorrected values.

### 3.3 Retry contract

The refusal wrote nothing, the task is still PENDING with the same assignee, so the client resends the SAME request:
`POST /tasks/:id/complete` with the ENTIRE corrected JSON body (the body IS the output map, `routers/tasks.ex:330`; there is no
merge with the refused attempt and no partial resend). The router mints a new idempotency key per request (`331`), so a retry
is never deduplicated against the refused one; the refusal consumed no idempotency row. Nothing else (no task id change, no
re-claim, no instance action) is needed. The refusal does not extend or reset an armed escalation timer.

Router change: two new clauses of `handle_complete_result/2`, placed before the catch-all at `routers/tasks.ex:425`
(`{:error, :separation_of_duties}` -> section 4; `{:error, {:output_refused, %{missing_keys: m, rejected_keys: r}}}` ->
`Response.output_refused(conn, m, r)`). Per `docs/anti-patterns.md:939-976` (type table vs error map drift) the `complete_error`
`@type`, the router moduledoc table and these clauses are edited together, and a test asserts each public refusal maps to its status.

---

## 4. The refusal body and status for rule A

### 4.1 Status: 403 Forbidden

Chosen among the 4xx codes against the existing contract of `Letflow.Routers.Tasks`:

* The same router already treats "this caller may not complete this task" as an authorization decision, 403
  (`handle_complete_result` for `:assigned_to_other_user`, `:assignee_group_not_member`, `:assignee_role_not_held`,
  `routers/tasks.ex:380-399`, whose comment states "complete is an authorization decision"). Separation of duties is an
  authorization decision about the caller's identity, not about the task's state.
* The repository's own precedent for the same kind of rule, `self_approval_forbidden`, is 403
  (`routers/promotions.ex:603-604`).
* 409 is reserved here for resource-state conflicts (`task is not pending`, `instance is <status>`, post-commit instance ERROR;
  `364-374`, `408-411`). Using 409 would make a client unable to tell a replay (`task is not pending`) from a separation refusal by
  status, and would suggest that a state change could let the SAME user succeed; it never can.
* 422 means "fix the body and resend"; no body can fix this.
* 404 would hide the task from a user who legitimately sees it in a list (INV-5 is about cross-tenant probing, not this).

### 4.2 Body: one fixed byte string

The same body and status for every node, every user, every instance, on both `POST /tasks/:id/complete` and
`POST /tasks/:id/claim` (section 6). Content-Type `application/problem+json`. The body is exactly:

```json
{"detail":"separation of duties","status":403}
```

That is the whole body: the phrase and a status, nothing else. It is a valid RFC 9457 problem document (every member is optional,
RFC 9457 section 3.1; `type` defaults to `about:blank`). It is a constant sent by a new function that bypasses
`Response.send_problem/2` (which always splices a per-request `trace_id`, `response.ex:115-122`, and serialises five members,
`error.ex:121-151`):

```elixir
@spec Letflow.Api.Response.separation_of_duties(Plug.Conn.t()) :: Plug.Conn.t()
```

Why not the standard five-member envelope: `type`, `title` and `trace_id` would add content beyond "the phrase and a status", and
`trace_id` differs per request, which would break REQ-463's acceptance line that bodies from two different triggers are
byte-identical. Correlation for support uses the audit record (actor, task, time), not a body member. This choice is listed
in "Decisions flagged for REVIEWER" (D-1).

`Letflow.Routers.Tasks` change: `handle_complete_result/2` gets `{:error, :separation_of_duties}` -> `Response.separation_of_duties(conn)`
(before the catch-all at 425); `handle_claim_result/3` gets the same clause (before the catch-all at `routers/tasks.ex:471`). No response
header carries detail.

---

## 5. The audit record of a refusal (both rules)

One `audit_entries` row per refused COMPLETION, written by `record_completion_refusal_audit/6` (section 2.4) through
`Letflow.Audit.insert_entry/3` (`lib/letflow/audit.ex:231-240`, `entry_attrs` type `121-129`). Claim refusals write NO audit row (section 6).

| Field | Value |
|---|---|
| `actor_id` | the completing user's id (UUID; the same value `task.complete` audits, `engine.ex:4916-4917`). No name, no email. |
| `action` | `"task.completion_refused"` (new, `<resource>.<verb>` convention) |
| `resource_type` | `"task"` |
| `resource_id` | the task id (the row exists, unlike ISS-0784) |
| `before_state` | `nil` |
| `after_state` (rule A) | `%{"rule" => "separation_of_duties", "instance_id" => ..., "node_id" => <the task's node>, "blocking_node_ids" => [<named node ids whose most recent completer is the actor>, sorted]}` |
| `after_state` (rule C) | `%{"rule" => "output_refused", "instance_id" => ..., "node_id" => <the task's node>, "missing_keys" => [...], "rejected_keys" => [...]}`; both lists carry only allowed-set keys (3.2, SECURITY-REVIEWER finding F-1), so a rejection on any other key leaves no trace of its name or of its schema |
| `trace_id` | `nil` (no trace id reaches `Engine.complete_task/3`; same as `task.complete`, `engine.ex:4924`) |

No submitted value, no enum or schema text, no `ValidationFailure` content, no user name, no email, no other user's id (for rule
A the earlier completer IS the actor, so it is not repeated). Node ids and variable keys are definition data the tenant
authored. Written: `audit_entries` in the tenant schema (`prefix` explicit, INV-1), hash-chained by `Audit` unchanged.
Failure semantics: best-effort, log-and-swallow, never raises (section 2.4). The 422 body (section 3) carries key names
only; the audit record carries the same key names plus node ids.

---

## 6. Claim path for rule A (`Letflow.Tasks.claim_task/3`)

Early feedback only; completion (section 2) is the authority. DECIDED (BA 2026-10-07), implemented: `assign_task/4`
(`tasks.ex:606-625`) and `reassign_task/4` (`676-694`) read no `distinct_from` and gain no check; an administrator may assign a
task to anyone, and the completion check still refuses a person who already completed a named node.
`Tasks.authorize_completion/3` (`539-547`) is unchanged.

Numbered order in `claim_task/3` (`tasks.ex:428-446`), the new steps marked:

1. `cast_task_id/1` (`tasks.ex:728`) `[pure]`.
2. `:task` `[lock]` `fetch_and_lock_task/3` (`tasks.ex:703-713`, `tasks.ex:436`) -> `:task_not_found` | `{:task_not_pending, _}`. Unchanged.
3. `:scope` `[read]` `resolve_principal_scope/2` (`tasks.ex:353-374`, two reads; step at 437-439). Unchanged.
4. `:apply` -> `apply_claim/5` (`tasks.ex:448-495`): the existing eligibility decision. Unchanged; its refusals
   (`:assigned_to_other_user`, `:assignee_group_not_member`, `:assignee_role_not_held`, `:not_claimable`) take precedence.
5. **NEW**, only when the caller is otherwise eligible, i.e. immediately before `write_assignment/4` (`tasks.ex:715-719`) in
   the clauses that write (unassigned, GROUP member, ROLE held) AND in the clause that returns the already-assigned caller's
   task unchanged (`tasks.ex:452-461`, the idempotent re-claim): `SeparationOfDuties.check_for_claim/3` `[read]`: one
   `SnapshotStore.get_by_instance_id/2` read, `Engine.build_graph/1` (`engine.ex:1538`, public `@doc false`), then if the node has a
   non-empty `distinct_from` and the actor is a binary, the same single tasks query as section 8.2. Refusal ->
   `{:error, :separation_of_duties}`; nothing written (the `Multi.run` error rolls back the lock only). Order matters for
   disclosure: a caller who is not eligible learns nothing about `distinct_from` because the existing refusals come first.
6. Otherwise the existing write (`tasks.ex:715`) or no-op success.

```elixir
@spec Letflow.Engine.SeparationOfDuties.check_for_claim(Letflow.Engine.Task.t(), actor_id :: Ecto.UUID.t() | String.t() | nil, prefix :: String.t()) ::
        :ok | {:error, :separation_of_duties}
```

`check_for_claim/3` is TOTAL (INV-8, SECURITY-REVIEWER finding F-2): any failure to obtain the graph (`{:error, :snapshot_not_found}`, a failing
`build_graph/1`, a raised exception, a DB error) is caught inside the function, logged with `Logger.warning` naming only the task id
and the failure tag, and the function returns `:ok`. Completion is the authority and re-checks under the locks, so failing open at
the advisory claim is safe; it also guarantees a definition without `distinct_from` never gains a new claim failure mode. Only a
successfully loaded graph whose node has a non-empty `distinct_from`, and a successful query, can produce `{:error, :separation_of_duties}`.

and `claim_error` (`tasks.ex:395-404`) gains `{:error, :separation_of_duties}`. Router: `handle_claim_result/3` clause -> section 4.
This DIVERGES from that handler's own mapping of eligibility refusals to 409 (`routers/tasks.ex:455-465`); it is deliberate:
the body and status must be byte-identical on both endpoints (REQ-463 AC), and 409 would be wrong for the reasons in 4.1.

Properties: claim does NOT lock `instance_projections` (the lock inventory comment at `tasks.ex:381-389` stays true: this adds
reads, not locks), so the early check may race a concurrent completion; that is acceptable because completion re-checks under
the instance lock. A claim refusal writes nothing and is NOT audited: claim is advisory, the authority decision (completion) is
the audited one, and auditing a claim attempt would put a hash-chain lock (`audit.ex` `ChainLock`) on a UI-driven path. Cost: one
extra snapshot read plus graph decode per claim, for every claim, because a claim cannot know whether the node has
`distinct_from` without reading the snapshot; claims are low-frequency human actions.

Visibility (carried open question, OQ-1): an unclaimable-by-me task stays visible in the user's inbox and in `GET /tasks`;
refusal happens only at claim and completion, so the list endpoints reveal nothing about who completed a named node.

---

## 7. API-token identity

The identity compared is `actor_id`, which for every request is the authenticated user's id, token or OIDC alike. Trace:

1. `Letflow.Plugs.AuthPipeline.call/2` dispatches `lf_tok_` bearer values to `authenticate_api_token/2`
   (`lib/letflow/plugs/auth_pipeline.ex:107-114`, `196`, `141-150`).
2. `verify_token_credential/2` (`auth_pipeline.ex:227-234`) -> `Letflow.Identity.verify_api_token/2`
   (`lib/letflow/identity.ex:1648`), which returns `{:ok, %{user_id: token.user_id, roles: token.roles}}` (`identity.ex:1686`).
3. `attach_auth_context(conn, tenant.id, verified.user_id, verified.roles)` (`auth_pipeline.ex:146`; function `370-388`) assigns
   `auth_context` with `user_id: user_id` (`auth_pipeline.ex:382`). The OIDC branch assigns the same key from
   `provisioned.user.id` (`auth_pipeline.ex:133`).
4. `Letflow.Routers.Tasks.handle_complete/3` reads `actor_id = conn.assigns.auth_context.user_id`
   (`routers/tasks.ex:326`) and passes it as `attrs.actor_id` (`336`); `handle_claim/3` does the same (`432`).
5. `Engine.complete_task/3` reads `actor_id = Map.get(attrs, :actor_id)` (`engine.ex:2218`) and passes it to `run_complete_task/6`
   (`2222-2229`); `completed_by` is later written from the same value (`engine.ex:5102-5108`).

Statement: the rule A comparison uses exactly this `actor_id`; for a token request it is the TOKEN OWNER's user id, never the
token id, never a role. Roles never enter the engine: `run_complete_task/6` and `claim_task/3` take no roles argument, so no
role (TENANT_ADMIN, which holds every tenant-scope permission per `lib/letflow/api/authorization.ex:1347-1352` (`core_role_allows?(:TENANT_ADMIN, ...)` at 1352), included) can be special-cased
without changing those signatures. Comparison is on canonical lowercase UUID strings: `tasks.completed_by` loads through
`Ecto.UUID` (`task.ex:72`), and `auth_context.user_id` is a database-sourced UUID; implementation compares after
`Ecto.UUID.cast/1` of both sides, and a nil or non-binary actor never matches.

---

## 8. Rework semantics: "most recent completion of a named node in this instance"

### 8.1 Source of truth

The `tasks` table, not the event log. A completion is a `tasks` row with `status = 'COMPLETED'` whose `completed_by` was
written in the same transaction as the completion (W6, `engine.ex:5102-5113`; changeset `task.ex:107-111`). Every pass through a
node (rework loop) creates a new task row (`TaskActivation`), so "the most recent completion of node N" is the COMPLETED row
of node N with the greatest `completed_at`. The `TASK_COMPLETED` event payload also carries `node_id` and the actor
(`engine.ex:5136-5152`) but reading it would mean filtering a JSON payload column; rejected. Rows with status `CANCELLED`
(escalated-past, cancelled by instance cancellation) and `PENDING` are never completions.

### 8.2 The query (one per guarded completion or claim, never more)

The module `Letflow.Engine.SeparationOfDuties` has exactly two PUBLIC entry points; the query function is private.

```elixir
# Called by the engine step :completion_guards (step 4b), inside the open transaction; `repo` is the Multi.run repo.
@spec check(
        repo :: module(),
        graph :: Letflow.Definitions.Graph.t(),
        task :: Letflow.Engine.Task.t(),
        actor_id :: Ecto.UUID.t() | String.t() | nil,
        prefix :: String.t()
      ) :: :ok | {:error, {:separation_of_duties, blocking_node_ids :: [String.t()]}}

# Called by Letflow.Tasks.claim_task/3 (section 6, step 5); loads the snapshot graph itself, then delegates to check/5 with Letflow.Repo.
@spec check_for_claim(task :: Letflow.Engine.Task.t(), actor_id :: Ecto.UUID.t() | String.t() | nil, prefix :: String.t()) ::
        :ok | {:error, :separation_of_duties}

# private, the single read: returns the named node ids (sorted) whose most recent completer equals actor_id
@spec blocking_nodes(repo :: module(), instance_id :: Ecto.UUID.t(), named_node_ids :: [String.t()], actor_id :: String.t(), prefix :: String.t()) ::
        [String.t()]
```

`check/5` returns `:ok` without any query when the node has no non-empty `distinct_from` or `actor_id` is not a binary; otherwise
it calls `blocking_nodes/5` once. The claim path maps `{:error, {:separation_of_duties, _}}` to the detail-free
`{:error, :separation_of_duties}`.

New module `Letflow.Engine.RequiredOutputs` (all pure, total):

```elixir
@spec required_outputs(node :: Letflow.Definitions.Graph.Node.t()) :: [String.t()]          # [] when absent/null/malformed
@spec missing_keys(required :: [String.t()], output_variables :: map()) :: [String.t()]       # sorted; keys absent from the map or with a nil value
@spec rejected_keys(validations :: Letflow.Engine.VariableMerge.variable_validations(), exclude :: [String.t()], allowed :: [String.t()]) :: [String.t()]  # sorted keys with {:rejected, _}, minus `exclude`, intersected with `allowed`
@spec any_rejected?(validations :: Letflow.Engine.VariableMerge.variable_validations()) :: boolean()
@spec allowed_keys(form_schema :: map() | nil, required :: [String.t()]) :: [String.t()]   # form_schema["properties"] keys union required
```

and in `Letflow.Definitions.SemanticValidation` (also added to its moduledoc):

```elixir
@spec required_output_schema_violations(graph :: Letflow.Definitions.Graph.t(), declared_fields :: declared_fields()) ::
        [Letflow.Definitions.Graph.Violation.t()]
@spec decision_key_warnings(graph :: Letflow.Definitions.Graph.t(), definition_name :: String.t()) :: [String.t()]
```

`decision_key_warnings/2` takes the definition name as its SECOND argument because the wire text embeds it; the caller is
`ValidationWarnings.for_definitions/2`, which already holds `{definition_name, graph}` pairs.

The `:completion_guards` step's own type: `@spec completion_guards_result() :: {:ok, :guards_passed | :no_guards} | {:error, {:completion_refused, completion_refusal()}}`.

Description of the single read: from `tasks` in the tenant schema (`prefix` explicit), `WHERE instance_id = ^instance_id AND
status = 'COMPLETED' AND node_id IN ^named_node_ids`, `DISTINCT ON (node_id)` ordered by `node_id ASC, completed_at DESC,
inserted_at DESC, id DESC`, selecting `{node_id, completed_by}`; the function returns, sorted, the node ids whose `completed_by`
equals `actor_id`. Composed with Ecto query bindings only (INV-7). The tie-break chain makes the result deterministic when two
completions share a microsecond. A named node with no row simply contributes nothing (no constraint, BA 2026-10-07).

### 8.3 Cost and index

Postgres can use `idx_task_instance` (`priv/repo/migrations/20260818110003_create_tasks.exs:87`), then filter `status` and
`node_id` and sort the survivors; the rows touched are the tasks of ONE instance (tens, or a few hundred in a heavy rework
loop). No new index and no migration are designed. `EXPLAIN` on a seeded instance is to be run by ELIXIR-DEV and quoted; this
design does not claim the plan. A composite partial index `(instance_id, node_id, completed_at DESC) WHERE status = 'COMPLETED'`
is NOT built; revisit only if a definition ever produces thousands of task rows per instance. A definition without
`distinct_from` runs no query at all (step 4a).

### 8.4 Rule semantics fixed here

* Compared per named node, independently: the actor is refused if ANY named node's most recent completer is the actor.
* Rework loop: U completes N1; V completes N1 on a second pass; then U attempts N2 (`distinct_from [N1]`): the latest N1 row is V's,
  so U is accepted. Reversed (V then U on the second pass): U's row is latest, U is refused.
* Parallel branches (BA 2026-10-07): the check compares with whatever completions exist at the moment it runs, in any order.
  P1, P2, P3 each naming the other two: whichever completes later must differ from every earlier completer. Concurrent
  completions are serialised by the instance row lock (2.5), so one of the two sees the other's committed row.
* A named node that has not completed in this instance (path skipped it, or a timer escalated past it) imposes no constraint.
* Same instance only: `instance_id` is part of the filter; a sub-process child instance has its own task rows and its own constraints.
* `distinct_from` never constrains a node against itself (validator `:distinct_from_self_reference`).

---

## 9. Interaction with D-ESC escalation tasks (REQ-396) and timer cancellation

Facts (read from the code, not assumed):

* An escalation task is an ordinary `HUMAN_TASK` node with its own id, its own `role`, and its own `attributes`; the timer's
  fallback edge routes the token there. Example: `l2-approval` -> edge `fallback-l2-approval` -> `escalate-l2-approval-to-ceo`
  (`test/fixtures/qa/meridian_loan_origination_process_definition.json`, node attributes `role: role-ceo`).
  The engine path: `Scheduler.do_fire/2` (`scheduler.ex:297-328`, escalation branch 310-317) ->
  `Engine.advance_after_escalation_timer_fired/3` (`engine.ex:2916`) -> `persist_escalation_timer_fired_advance/7`
  (`engine.ex:2983-3179`): the original task row is locked and set to `CANCELLED` with `cancelled_at` (3033-3061, status
  `:cancelled`, `completed_by` stays null), audited as `task.cancel` (3065-3086), then the next task is activated through
  `TaskActivation.append_multi_from_existing_records/6` (3105-3111). A stale timer (token no longer at the node) is consumed as a
  no-op (`escalation_timer_stale?`, 2920-2924).
* A normal completion cancels the node's pending escalation timers inside the same transaction (W7, `engine.ex:4458-4469`;
  `task_activation.ex:517-547`, `cancel_reason: "task_completed"`).

Decisions:

1. **No inheritance.** An escalation task does NOT inherit its source node's `distinct_from` or `required_outputs`. Both are
   per-node attributes read from the node being completed (section 2 step 4); the escalation node is a different node. Authors
   (REQ-462, REQ-465, REQ-466) declare them explicitly on the escalation node, as those requirements already list
   (`escalate-l2-approval-to-ceo`, `escalate-to-ceo`, `escalate-budget-approval-to-ceo`). This is the answer REQ-462's open
   question defers to this section: escalation nodes declare the same `required_outputs` as the node they replace, explicitly.
2. **Completing the escalation task is not a completion of the source node.** Its `tasks.node_id` is the escalation node's id;
   the source node's own row is `CANCELLED`, so the source node has NO completion. Another node's `distinct_from` that names
   the source node therefore imposes nothing after an escalation (a named node escalated past imposes no constraint, BA
   2026-10-07). To constrain against whoever finally decided, the later node must name the escalation node's id too; REQ-465's
   disbursement list already names `escalate-l2-approval-to-ceo`.
3. **A claim made before the timer fired** assigned the ORIGINAL task row (`write_assignment/4`, `tasks.ex:715`). When the timer
   fires, that row becomes `CANCELLED` and the claim dies with it; the new task at the escalation node starts with the
   assignment its own node's role gives it (`TaskActivation`), not the claimant. A completion attempt on the cancelled row ends
   at step 1 (`{:task_not_pending, :cancelled}`, 409), before any guard. The earlier claim never counted as a completion.
4. **A refusal does not touch the timer.** Rule A or C refusal rolls back before W7, so the armed escalation timer keeps its
   original `fire_at`. This is intended: escalation exists for a task nobody can or will complete (including the single-member-role
   case that check 4 warns about); a refusal is not progress and must not postpone it.
5. **Race: completion vs timer.** Unchanged and not worsened: the timer path locks the instance row first
   (`engine.ex:2917`) and the task row second (3033-3037); completion locks task then instance. Whichever commits first wins;
   the other sees `{:task_not_pending, ...}` or a stale timer. This design adds no lock to either path.

---

## 10. Interaction with the idempotency key and a replayed completion

* The router generates the idempotency key per request (`routers/tasks.ex:331`), so over HTTP there is no client-visible
  idempotency key and no deduplication by key; "replay" means re-POSTing the same completion.
* A replay of an already-accepted completion, by the same user or any other, stops at step 1: the task row is `COMPLETED`, so
  `fetch_and_lock_task/3` returns `{:task_not_pending, :completed}` (`engine.ex:2466`) and the router answers the EXISTING 409
  `"task is not pending"` (`routers/tasks.ex:364-366`). Step 4 (rule A and rule C) is never evaluated, so a replay by the user
  who completed the node is NOT refused by rule A (it receives today's 409, not the separation body); a test asserts the status
  is 409, the body is not the section 4 body, and that no audit row `task.completion_refused` is written.
* At engine level, `EventStore.append/2` also dedupes by key (`event_store.ex:218`, `claim_idempotency/3` 649-676,
  `resolve_duplicate/3` 678-692, `{:duplicate_idempotency_key, event}`); that path is only reachable by a caller reusing one key
  across different tasks, after the guards have already run, and surfaces as `{:event_append_failed, _}` (`engine.ex:5154-5157`) with
  a full rollback. Unchanged.
* A refusal appends no event and claims no idempotency row (W9 is on the success path), so an engine-level caller may resend
  the same key after a refusal.
* Each refused request writes its own audit row; two refused POSTs write two rows (one per refusal, not one per task).

---

## 11. Engine-internal merge paths stay unchanged; the amendments of REQ-061 and decision record 0007

### 11.1 Which merges are touched

Only the HUMAN_TASK completion merge changes (`merge_output_variables/7`, the `:merge` step). Verified call map of every
`VariableMerge.merge/3` call in `lib/`:

| Caller | Validations passed | After this design |
|---|---|---|
| `Engine.merge_output_variables/7` / `apply_variable_merge/6` (`engine.ex:3875`, `3916`) | real, from `VariableSchema.variable_validations/5` | schema rejection becomes a 422 refusal, no ERROR (changed) |
| `Engine.advance_service_task_dispatch/4` (`engine.ex:3394`) | `nil` | unchanged: it passes `nil`, so a service-task merge is NEVER schema-rejected today |
| `SubProcess.build_completion_multi_from_merge/12` (`engine/sub_process.ex:824-847`; rejection -> error args in its `else`, ~933) | real | unchanged: the parent still goes to ERROR (existing test `test/letflow/engine_sub_process_test.exs:777`) |
| `Reconstruction` (`engine/reconstruction.ex:594`, `678`), `Transition` (`engine/transition.ex:1345`) | `nil` | unchanged |

`VariableMerge.merge/3` and its whole-batch semantics are not edited (`variable_merge.ex:205-250`);
`VariableSchema.variable_validations/5` is not edited. The EXECUTION_ERROR sink (`ExecutionError.append_multi/3`,
`execution_error.ex:192`; `set_instance_error/2`) is not edited; REQ-050/056/057/062 callers keep using it.

**Finding reported to ORCH:** REQ-460's regression line "a service-task merge that violates a variable_schema still ends the
instance in ERROR with an EXECUTION_ERROR event" cannot be reproduced on today's code, because the service-task merge passes
`nil` validations (`engine.ex:3394`). The still-live engine-internal schema-rejection-to-ERROR path is the SUB_PROCESS completion
merge (`sub_process.ex:838-847`), which REQ-460's regression test must use instead (or the REQ text must be reworded). See Adjustments.

### 11.2 The exact amendment of REQ-061's text

REQ-061 (`docs/requirements.yaml:3463`, status `done`) lists the shared ERROR sink's callers at lines 3485-3490, including
"REQ-049's schema-violation-on-merge case" (3487-3488). DOC-UPDATER leaves a DATED AMENDMENT POINTER there; the original
sentence is not deleted. Proposed pointer text, to be appended to REQ-061's description:

> AMENDED 2026-10 (REQ-459/REQ-460): the "REQ-049 schema-violation-on-merge" caller above no longer applies to a HUMAN_TASK
> completion. A value that a `variable_schema` rejects on the task-completion path is refused with a retryable 422 before any
> state change and raises no EXECUTION_ERROR. The case still routes to this sink for the SUB_PROCESS completion merge
> (REQ-062). Other callers (REQ-050, REQ-056, REQ-057, REQ-062) are unchanged.

Code comments amended in the same REQ-460 change (they would otherwise be false): the moduledoc section "Output-variable
schema validation at the merge call site (REQ-109)" at `engine.ex:142-152` (the sentence "makes REQ-061's `{:rejected, ...}` ->
`ExecutionError.append_multi/3` branch reachable through the real completion path for the first time"), the comment above
`merge_output_variables/7` at `engine.ex:3829-3861`, and the "Dependency ordering" paragraph of
`lib/letflow/engine/variable_merge.ex:58-77` (the sentence "REQ-109 wired the caller so that its ERROR path is reachable
through `Letflow.Engine.complete_task/3`").

### 11.3 The 0007 passages (decision record NOT edited by REQ-460; flagged for REVIEWER)

`docs/migration/decisions/0007-variable-merge-validates-new-keys.md`:

* Passage 1, "What changes", first bullet, line 79: "the same whole-batch-abort-on-rejection semantics (§3.2) apply regardless of which
  key rejected." Still TRUE of `merge/3` itself; stale only in what the caller does with the rejection on the HUMAN_TASK path.
* Passage 2, "Open questions", line 108: "(validation errors surface only via `EXECUTION_ERROR` events today)". Becomes false for the
  HUMAN_TASK completion path.

Both are exactly the passages REQ-460's open_questions identified; this design confirms them and confirms nothing else in 0007
contradicts the change (the validate-every-key decision stands: step 6b-i still validates every incoming key). Proposed dated note, for
REVIEWER to write when it signs off (this design and REQ-460 do not edit the record): "2026-10 note (REQ-460): on the
HUMAN_TASK completion path a rejected output is now refused with a retryable 422 before any state change and no EXECUTION_ERROR is
raised; `merge/3` itself and its whole-batch semantics are unchanged; the EXECUTION_ERROR path remains for the SUB_PROCESS completion
merge and other engine-internal failures."

### 11.4 Why rule A leaves these paths untouched

Rule A and rule C live only in `:completion_guards` (step 4) and step 6b, both inside `run_complete_task/6` and
`claim_task/3`. Service-task outcomes, timer fires, sub-process completion, instance create, cancel and `set_instance_error/2` never
call them. Rule A reads task rows and node attributes; it does not touch `VariableMerge`.

---

## 12. Test plan skeleton

All DB-backed cases use real Postgres through the existing provisioned-tenant helpers (no mocks). "Unchanged" assertions compare
full rows (including `updated_at`), the event count for the instance, and the audit row count, read before and after.
Refusal tests also assert the response through the router (`test/letflow/routers/tasks_test.exs`) AND the engine return
(`test/letflow/engine_complete_task_test.exs` or a new sibling file).

### 12.1 Rule C (REQ-460, REQ-461, REQ-462)

| # | Case | Asserts |
|---|---|---|
| C-1 | `required_outputs ["decision"]`, key absent | 422, body = section 3 example with `missing_keys ["decision"]`, no submitted value; task PENDING and claimable; instance, tokens, variables, event count unchanged; exactly one `task.completion_refused` audit row |
| C-2 | key present with `null` | same 422 (null counts as missing) |
| C-3 | rework loop: instance already holds `decision`, resubmission omits it | still 422 (existing value does not count) |
| C-4a | a value rejected on a key that is NOT in the task's `form_schema.properties` nor `required_outputs` (but has a `variable_schema`) | 422 with BOTH lists empty, nothing merged, instance not in ERROR; the key's name never appears in the body or in the audit row (grep both) |
| C-4 | enum-rejected value (`"maybe"`) | 422 `rejected_keys ["decision"]`; no value and no enum in body; instance NOT in ERROR; no EXECUTION_ERROR event; immediate retry with a valid value completes and routes correctly |
| C-5 | wrong-type value on a typed key | same as C-4 |
| C-6 | empty string on a required key whose schema is an enum without `""` | 422 `rejected_keys` (empty string is judged by the schema, not "missing"); and with a schema that allows `""` it is accepted |
| C-7 | required key dropped by `visible_when: false`, or recomputed to null | 422 `missing_keys` (step 6b-ii) |
| C-8 | all required keys present and valid | behaves exactly as before; existing completion tests pass unchanged except the amended ERROR assertions |
| C-9 | default-off: node without `required_outputs`, key omitted | identical to today (completes; fail-closed route) |
| C-10 | reevaluation domain error (cross-field validation failing) with all required keys present | still EXECUTION_ERROR (unchanged, BA) |
| C-11 | missing key AND failing cross-field validation | 422, not EXECUTION_ERROR (4c precedes step 5) |
| C-12 | SUB_PROCESS completion whose output the parent's `variable_schema` rejects | parent still ends in ERROR with EXECUTION_ERROR (replaces REQ-460's unreproducible service-task line; `engine_sub_process_test.exs:777` stays green) |
| C-13 | API-token request (token owner has role X) | same refusals (token path, section 7) |
| C-14 | caller holds `TENANT_ADMIN` | same refusals (no role exempt) |
| C-15 | audit-write robustness | DROP-TABLE regression: with `audit_entries` unavailable the refusal still returns the 422 and does not raise; one warning logged |
| C-16 | body leakage | grep the 422 body and the audit row for the submitted value and the caller's email: neither found |
| C-17 (validator) | per REQ-461 acceptance: one test per code in 1.2 with a minimal violating definition and a passing neighbour; check 2 with `declared_fields == %{}`; check 3 warning present for an edge reading an undeclared form key and absent when `required_outputs` declares it; all shipped definitions run through the validator with per-definition counts quoted |

Tests that today assert instance ERROR after a HUMAN_TASK completion with a rejected output and must change (verified by grep;
see Adjustments for the corrected list): `test/letflow/engine_variable_schema_merge_test.exs:212,337,434`,
`test/letflow/engine/shipped_definition_variable_schemas_engine_test.exs:132`,
`test/letflow/scripts/swiftroute_decision_forms_fixture_test.exs:292`; each gets a comment citing REQ-459/REQ-460.

### 12.2 Rule A (REQ-463, REQ-464, REQ-465, REQ-466)

| # | Case | Asserts |
|---|---|---|
| A-1 | one user U holds role-a and role-b, completes N1 (role-a), attempts N2 (role-b, `distinct_from [N1]`) | 403, body is exactly the section 4 bytes; task PENDING; rows before/after equal; exactly one `task.completion_refused` row (`rule: "separation_of_duties"`, `blocking_node_ids ["N1"]`); a second user holding role-b completes N2 |
| A-2 | body identity | bodies and statuses from two different triggers (different node, different user) are byte-identical and contain no node id, user id, name or email |
| A-3a | claim fails open | with the snapshot row missing, or a graph that fails `build_graph/1`, `check_for_claim/3` returns `:ok` and logs one warning; the claim of an eligible user succeeds; a definition without `distinct_from` gains no new claim failure |
| A-3 | claim | U's `POST /tasks/:id/claim` on N2 -> same 403 body; no audit row; a different eligible user claims; an ineligible user still gets the existing 409 first |
| A-4 | API token | U's token completing N2 -> refused; a different user's token accepted; a claim with U's token refused |
| A-5 | `TENANT_ADMIN` | a TENANT_ADMIN user who completed N1 is refused at N2 (fails if any role is special-cased; requires REQ-447 PR2, merged as `ff944312`) |
| A-6 | rework loop | U completes N1; V completes N1 on a second pass; U attempts N2 -> accepted; reversed order (V then U) -> U refused |
| A-7 | parallel branches | P1, P2, P3 each name the other two: U completes P1 then attempting P2 is refused; U completing P2 first then P1 is refused; three distinct users all accepted in every order |
| A-8 | concurrency | two completions of P1 and P2 by the same user submitted concurrently: exactly one commits, the other is refused (instance lock, 2.5) |
| A-9 | named node never completed | N2 names N1, path skipped N1 -> U completes N2, no refusal |
| A-10 | named node escalated past | N1 timed out into its escalation node; N2 names N1 only -> no constraint; N2 naming the escalation node -> constraint |
| A-11 | assign / reassign | `assign_task`/`reassign_task` to a user who completed a named node succeed; that user's completion is then refused |
| A-12 | default-off | a definition with no `distinct_from` lets one user complete both steps, identical to today (regression on an existing shipped definition); no extra query (query count equals today's) |
| A-13 | replay | the same user re-POSTs an already-accepted completion -> existing 409 `task is not pending`, not the separation body, no refusal audit row |
| A-14 | refusal leaves timer armed | after an A refusal the escalation timer row is still `pending` with the same `fire_at` |
| A-15 | audit | one record, PII-free (grep for email and name), survives the rolled-back Multi; DROP-TABLE regression as C-15 |
| A-16 (validator, REQ-464) | per REQ-464 acceptance: each code in 1.2; five negative tests (self, unknown id, non-human id, duplicate, downstream-only); parallel P1/P2/P3 mutually naming passes; preceding node and rework-loop node pass; check 4 warning with a one-member role, none with two members, definition still installs, warning in the install and validate bodies |

---

## Requirement traceability (one row per binding constraint; none weakened or re-decided)

| # | Binding constraint (verbatim in substance from REQ-459) | Where the design states it | Mechanism |
|---|---|---|---|
| A1 | identity is the USER ID, never the role; for an API token the identity is the token's user | section 7; 8.4 | comparison on `actor_id` = `auth_context.user_id` (`auth_pipeline.ex:146,382`; `routers/tasks.ex:326`); `tasks.completed_by` |
| A2 | enforced at COMPLETION (the authority) and at CLAIM (early feedback only) | sections 2 (step 4b), 6 | guard under both row locks; claim check after eligibility, advisory, no audit |
| A3 | NO role is exempt, TENANT_ADMIN included | section 7; tests A-5 | roles never reach `run_complete_task/6` or `claim_task/3`; no signature carries them |
| A4 | compare against the MOST RECENT completion of each named node in the same instance | section 8 | `DISTINCT ON (node_id)` ordered `completed_at DESC`; rework case A-6 |
| A5 | attribute OPTIONAL and OFF by default; a definition without it behaves exactly as before | sections 1.1, 2 (4a) | absent/null/`[]` = off; no query issued; test A-12 |
| A6 | refusal is a clean 4xx with zero detail beyond "separation of duties" | section 4 | constant body `{"detail":"separation of duties","status":403}`, 403, identical on complete and claim |
| A7 | REQ-455 validator WARNS (not violation) when `distinct_from` names a node routing to the same single-member role; REQ-464's rule, the design specifies inputs | section 1.5 | inputs: reachability relation, role attribute, unordered pairs, member count; code `distinct_from_single_member_role:` |
| A8 | PROCESS-AUDITOR B1 may answer YES when the attribute is present; follow-up recorded in REQ-463's open_questions, no engine change | this table; Adjustments (REQ-463) | the design touches no agent file and adds no engine behaviour for it |
| A9 | (BA 2026-10-07, decided) `assign_task/4`, `reassign_task/4` do NOT check `distinct_from` | section 6 | no code change in `tasks.ex:606-694`; test A-11 |
| A10 | (BA 2026-10-07, decided) named nodes may be on PARALLEL branches; compare with completions existing at check time, in any order | sections 1.5, 2.5, 8.4 | CHK-27 passes no-path-either-way; instance row lock serialises concurrent parallel completions; tests A-7, A-8 |
| A11 | (BA 2026-10-07, decided) a named node that has not completed (skipped, escalated past) imposes no constraint | sections 8.4, 9 | only `COMPLETED` rows count; `CANCELLED` ignored; tests A-9, A-10 |
| C1 | the check runs on the SERVER BEFORE any state change | sections 2, 2.3 | steps 4c / 6b-iv return `{:error, ...}` from a `Multi.run` before W1; only locks and SELECTs precede |
| C2 | a form's `required` flag stays a UI hint (REQ-273) and is never the control | section 1.1 | `form_schema` untouched; the control reads only `required_outputs` |
| C3 | the validator also flags a decision (edge condition or gateway) reading a key no upstream task declares in `required_outputs` | section 1.4 | `decision_key_not_required:` warning, EXCLUSIVE_GATEWAY and HUMAN_TASK reader edges |
| C4 | an out-of-enum value (any value a `variable_schema` rejects on this path) is a retryable 422 and NO instance ERROR; refusal before anything is written, task stays open and claimable | sections 2 (6b), 3 | `rejected_keys` from the validations map; 422; task PENDING; test C-4 |
| C5 | (BA 2026-10-07, decided) a required key whose submitted value is null counts as missing; empty string is judged by the schema's own rules | sections 2 (6b-iii), 3.2; test C-2, C-6 | `missing_keys/2` treats absent and null alike; empty string passes to the schema |
| C6 | (BA 2026-10-07, decided) `FormExpressionReevaluation` errors unchanged, still EXECUTION_ERROR | sections 2 (6a), 12 (C-10) | step 6a untouched; steps 6b* do not run for it |
| C7 | (REQ-460) only SUBMITTED output counts; a value already on the instance does not | section 2.5 | checks read the submitted and corrected maps, never `seed_state.variables`; test C-3 |

Acceptance-criteria map for REQ-459 itself:

| AC | Design element |
|---|---|
| twelve numbered sections, each naming file and function, no implementation code beyond `@spec` and a numbered order | sections 1-12 above; code fences contain only JSON examples and `@spec`/`@type` lines |
| section 2: one total order, per refusal path nothing written except the one audit record | 2.2 (total order), 2.3 (per-path table), 2.4 (audit survives rollback) |
| each binding constraint a requirement-traceable row | the table above (A1-A11, C1-C7) |
| sections 3 and 4 literal bodies; rule A body is the phrase and a status only | 3.2 (two literal 422 examples), 4.2 (`{"detail":"separation of duties","status":403}`) |
| CODE-DESIGN-VALIDATOR re-greps every cited path/function | "Citations verified" below |

---

## Adjustments for REQ-460..466

**REQ-460 (engine, rule C)**
0. REQ-460 BUILDS item 3 and acceptance criterion 3 ("naming the rejected key(s)") apply to IN-FORM keys (the task's own `form_schema.properties`) and `required_outputs` keys only. A rejection on any other key returns the 422 with BOTH lists empty (test C-4a); REQ-460 must not name every rejected key. This deliberately relaxes REQ-459's BUILDS wording "rejected key names" because naming a key outside the form would let a task worker probe which variable keys have a `variable_schema` (SECURITY-REVIEWER finding F-1, INV-2).
1. Implement section 2 steps 4a/4c and 6b-i..iv; new module `Letflow.Engine.RequiredOutputs` (`required_outputs/1`, `missing_keys/2`, `rejected_keys/3`, `any_rejected?/1`, `allowed_keys/2`, all pure; specs in 8.2). The `:completion_guards` step (step 4) lives in `engine.ex` and calls `RequiredOutputs` (REQ-460) and `SeparationOfDuties` (REQ-463). REQ-460 introduces step 4 with only the 4a and 4c halves; REQ-463 adds 4b between them.
2. Add `Response.output_refused/3`, `Error.output_refused/2`, the router clause, the `complete_error` members, `record_completion_refusal_audit/6` and the `interpret_complete_result/3` branch (section 2.4). REQ-463 reuses all of them; REQ-460 creates them with the `{:output_refused, ...}` half of `completion_refusal()` and REQ-463 adds the `{:separation_of_duties, ...}` half.
3. **The test file list in REQ-460 is partly wrong.** `test/letflow/engine_complete_task_test.exs` has no assertion of an ERROR after a rejected output (grep). The tests that DO complete a HUMAN_TASK and assert instance ERROR from a schema rejection are `test/letflow/engine_variable_schema_merge_test.exs` lines 212, 337, 434; `test/letflow/engine/shipped_definition_variable_schemas_engine_test.exs` line 132; `test/letflow/scripts/swiftroute_decision_forms_fixture_test.exs` line 292 (header comment at 14). `test/letflow/engine/variable_schema_test.exs` is a unit test of the lookup and does not need to change. `engine_execution_error_test.exs`, `pin_rebind_test.exs` use `set_instance_error/2` directly and are unaffected; `engine_sub_process_test.exs:777` is the sub-process path and must stay green.
4. **The regression line "a service-task merge that violates a variable_schema still ends the instance in ERROR" is not reproducible** (section 11.1: the service-task merge passes `nil` validations, `engine.ex:3394`). Use the SUB_PROCESS completion merge (test C-12) and keep a unit test that `VariableMerge.merge/3` still returns `{:rejected, ...}` for non-nil validations.
5. REQ-460 item 4 ("engine-internal merges keep going through EXECUTION_ERROR") holds for sub-process and the other EXECUTION_ERROR callers; say so.
6. Amend the three code comments named in 11.2; DOC-UPDATER leaves the REQ-061 pointer text of 11.2; do not edit 0007.
7. Router tests (API-token, TENANT_ADMIN) per tests C-13/C-14; the API-token fixture precedent is `test/support/platform_tenant_fixture.ex:205` (`x-tenant-slug` header) and `test/letflow/routers/identity_test.exs`.

**REQ-461 (validator, rule C)**
1. Codes and checks exactly as 1.2: CHK-25 in `graph.ex`; check 2 as `SemanticValidation.required_output_schema_violations/2` called from both clauses of `validate/2` (the empty-schema early return at `semantic_validation.ex:189-192` must not hide it); check 3 as `SemanticValidation.decision_key_warnings/2`.
2. **Check 3 is a WARNING and stays one** (1.4). The "severity switch" REQ-461 open_questions and REQ-462 BUILDS item 3 mention is not performed. REQ-461 creates `Letflow.Definitions.ValidationWarnings` and switches the two call sites (`definitions.ex:1286-1287`, `solution_pack.ex:1397-1411`).
3. Update the moduledoc of `SemanticValidation` (its "Empty-declared_fields exemption" and class list) and of `Graph` (check list, `validate_node_attributes/1` doc "plus CHK-21", `graph.ex:420-434`) and extend the `Violation.code()` union (`graph.ex:222-260`).
4. REQ-461 item 4 / acceptance say checks run at "validate, activate, import"; actual surfaces are: shape violations at validate/create/update/import/install; check 2 violation at validate and activate; check 3 WARNING at validate and pack install only (not activate, not import response).
5. Tests per 12.1 C-17; run every definition under `test/fixtures/qa/*.json`, `test/fixtures/simulation/**` and `priv/` through the validator and quote the counts (REQ-455 precedent, `shipped_definitions_validation_test.exs`).

**REQ-462 (adoption, rule C)**
0. Because check 3 is a permanent warning, REQ-462 BUILDS item 3 ("switch severity") and acceptance line 4 MUST be reworded by ORCH before dispatch (see item 2 below); they cannot be built or satisfied as written.
1. Escalation tasks declare `required_outputs` explicitly (section 9 decision 1); no inheritance exists.
2. **Acceptance line 4 conflicts with the design:** it asks that "REQ-461 check 3 finds no unadopted decision key in any of" the changed definitions, but REQ-462 itself leaves meridian `credit_decision`, `risk_rating`, committee votes (and the regulatory review) unadopted while their edges read them, so check 3 WILL emit `decision_key_not_required:` warnings for those keys. Reword to: no warning for any of the eleven adopted keys; remaining warnings are listed per definition in the run report and reported to ORCH. BUILDS item 3's "switched to the severity the REQ-459 design states" is a no-op (warning remains).
3. The eleven nodes' keys must each have a `variable_schema` in the definition and the seed scripts (REQ-461 check 2 is a violation at activate/validate).

**REQ-463 (engine, rule A)**
1. Add step 4b and `{:separation_of_duties, ...}` to `completion_refusal()`; new module `Letflow.Engine.SeparationOfDuties` with the two public entry points `check/5` (the ONLY one the engine step 4b calls; it wraps the private `blocking_nodes/5` and the engine maps its error to `{:completion_refused, {:separation_of_duties, ids}}`) and `check_for_claim/3` (called by `claim_task/3`, section 6); specs in 8.2. Slot 4b before 4c, after `:snapshot_and_state`.
2. Add the claim step 5 in `tasks.ex`, the `claim_error` member, the router clauses for complete and claim, and `Response.separation_of_duties/1`.
3. Acceptance "replay is not refused" is satisfied by section 10: the replay gets the existing 409, so assert 409 and "not the separation body", not a 200.
4. Acceptance "TENANT_ADMIN is not exempt" depends on REQ-447 PR2, merged as `ff944312`.
5. Open-question follow-up for ORCH (A8): file a docs-only issue to edit PROCESS-AUDITOR checklist item B1 (`.claude/agents/process-auditor.md` and the docs that restate it) AFTER this entry is done; this entry and this design change no agent file.
6. Note for BA/ORCH: any existing UAT or simulation scenario in which one actor performs two gated steps will start failing once REQ-465/466 adopt the attribute; this is a scenario issue (REQ-465 open_questions), not an engine defect.

**REQ-464 (validator, rule A)**
1. Codes and checks exactly as 1.2 (CHK-26 shape/existence/type, CHK-27 position) plus section 1.5 inputs. The BA parallel ruling is implemented as the relation table in 1.5.
2. Check 4 warnings likewise surface at validate and pack install only, not in the activate response. Add `single_member_pairs/1`, `member_counts/2`, `format_single_member_warning/2` to `RoleBinding` and the third source to `ValidationWarnings.for_definitions/2`; surfaces are the validate 200 body and the pack-install `warnings` (activate response is record-shaped and carries none; the AC "activation with only a warning succeeds" is satisfied because warnings never block).
3. REQ-464's SECURITY-REVIEWER condition ("only if check 4 reads tenant role membership through a new query") IS met: `member_counts/2` is a new query over `group_members` and `tenant_role` and needs SECURITY-REVIEWER (INV-1, prefix explicit; INV-2, only counts leave the function).
4. `member_counts/2` stays prefix-scoped (explicit `prefix`, INV-1) and returns counts only (never user ids, names or emails, INV-2).
5. Members counted: distinct `group_members.user_id` of the role's bound group, regardless of user status (OQ-2).

**REQ-465 / REQ-466 (adoption, rule A)**
1. Escalation nodes carry their own `distinct_from` (section 9); a later approver names BOTH a node and its escalation node when either may have been the decider.
2. A node may not name a downstream node; mutual naming is legal only for parallel or loop pairs (1.5), so the committee votes naming each other pass and `l1-approval` naming `l2-approval` would fail CHK-27.
3. Each role in a shipped roster must have at least two members for a path to complete; check 4 will warn otherwise (REQ-465 open_questions, unchanged).

---

## Decisions flagged for REVIEWER (decided here from the binding text; each can be overturned)

* **D-1 Rule A body is two members.** Chosen to satisfy "the phrase and a status, nothing else" and byte-identity across triggers. Alternative: the standard five-member problem document with `detail: "separation of duties"` (then `type`, `title`, `trace_id` are extra, and the byte-identity test must normalise `trace_id`).
* **D-2 403 for rule A on both complete and claim**, diverging from claim's own 409 mapping of eligibility refusals (section 6).
* **D-3 Audit write is best-effort** (log and swallow, never raises), following the ISS-0784 / ISS-0928 precedent; a failing audit store yields a refusal with no audit row and one warning, not a 500.
* **D-4 Check 3 is a permanent warning** (1.4).
* **D-5 Two required-key checks (4c on submitted, 6b-ii on corrected)** instead of one (2.5).
* **D-6 Claim refusals are not audited, completion refusals are** (section 6). Claim is advisory and on a UI-driven path. Completion refusals can be repeated by one authenticated caller without bound, writing one hash-chained audit row each; this is accepted under decision 0040 (`docs/migration/decisions/0040-authenticated-route-rate-limiting.md`: no per-actor rate limit is added at this stage; authenticated, tenant-scoped callers are bounded by round-trip latency), and is not a new class of exposure (`task.complete` and `task.assign` rows are likewise caller-triggered). A refusal-specific limit, if ever wanted, belongs to that decision's follow-up, not here.

## Open questions (genuinely open; each has the default this design builds)

* **OQ-1 (carried from REQ-459).** Whether an unclaimed task is visible in a user's inbox when the user would be refused at claim. Default built: visibility unchanged; refusal only on claim and completion, so the rule does not leak who completed a named node.
* **OQ-2.** Whether the single-member role warning (REQ-464 check 4) counts inactive users. Default built: counts every distinct `group_members.user_id` of the role's bound group regardless of `users.status`, which can suppress a warning a stricter count would raise; the stricter count needs a join to `users` and is a REQ-464 decision.
* **OQ-3.** Whether check 3 should be per-producer rather than "no upstream task declares it" (1.4). With D-ESC, `escalate-l2-approval-to-ceo` produces `l2_decision` as well as `l2-approval`; if only the latter declares it, the literal binding rule is satisfied for both edge sets although the escalation task can still omit the decision. Default built: the literal rule (not strengthened, the binding text is not re-decided); REQ-462 declares both nodes so shipped definitions are covered; ORCH may file a follow-up that makes the lint per-producer.

---

## Security invariants assessment (INV-1..INV-10, `docs/agents/instructions/security-invariants.md`)

* **INV-1 (tenant isolation):** every new read (`tasks`, `instance_definition_snapshots`, `variable_schemas`, `group_members`/`tenant_role` for check 4) and the audit insert pass an explicit `prefix` derived from the authenticated tenant; no new table, no `public`-schema fallback.
* **INV-2 (server-side field authorisation):** the 422 body carries definition-owned key names only; the 403 body is a constant; the task-detail allowlist is not extended; the audit row holds ids and key names, no values, names or emails. Rejected-key names (body and audit) are restricted to the task's own `form_schema.properties` plus `required_outputs` (F-1), so a task worker cannot read other variable keys' names (a guessed name can still be probed by 422-versus-accept, residual accepted, R2-1); an out-of-form rejection still refuses but names nothing.
* **INV-4 (no secrets/exception text in responses):** both new constructors take no free-text parameter; no stack, module or SQL text can reach a body.
* **INV-5:** unchanged; the 403 reveals only that a separation rule applied to a task the caller already sees.
* **INV-6:** this document is the scoping statement for the new data-access paths (sections 6, 8, 1.5).
* **INV-7:** all queries use Ecto bindings; `IN` over the named node ids is a bound list.
* **INV-8:** `record_completion_refusal_audit/6` has a function-level `rescue` and typed results; attribute reading is total; a nil actor never matches.
* **INV-10:** no route, permission or platform-scope action is added; no tenant identifier is read from the request.
* SECURITY-REVIEWER sign-off is required for REQ-460, REQ-463 and REQ-464 (check 4 query), per their acceptance criteria.

---

## Citations verified (re-grep these)

`lib/letflow/engine.ex`: `complete_task/3` 2212; `cast_task_id` 2245; `fetch_output_variables` 2252; `run_complete_task` 2263; `:task` 2273; `:instance_projection` 2274; `:snapshot_and_state` 2277; `:form_expression_reevaluation` 2280; `:merge` 2300; `:transition` 2332; `Multi.merge` 2348; `Repo.transaction` 2358; `maybe_snapshot_after_complete_task` 2418; `emit_task_completed_telemetry` 2384; `fetch_and_lock_task` 2458; `fetch_and_lock_instance_projection` 2473; `build_snapshot_and_state` 2490; `fetch_graph` 2512; `load_active_tokens` 2525; `find_token_for_task` 2549; `load_pending_task_tokens` 2572; `build_instance_state` 2591; `advance_after_escalation_timer_fired` 2916; `persist_escalation_timer_fired_advance` 2983; `merge_output_variables` 3875; `apply_variable_merge` 3916; `build_reevaluation_execution_error_args` 3960; `prepend_form_expression_events` 3992; `dispatch_task_completion_hop_chain` 4020; `build_complete_task_tail_multi` 4328 / 4343; `record_task_complete_audit` 4911; `record_task_activation_rejection_audit` 4979; `complete_task_row` 5102; `append_task_completed_event` 5127; `reconcile_projection` 5222; `interpret_complete_result` 5258 / 5266 / 5307; `complete_error` type 2141; `build_graph` 1538; service-task merge call 3394.
`lib/letflow/tasks.ex`: `resolve_principal_scope` 353; `claim_task` def 430 (spec 428); `apply_claim` 448-495; `authorize_completion` def 539; `assign_task` def 608; `reassign_task` def 678; `fetch_and_lock_task` 703; `write_assignment` 715; `claim_error` 395.
`lib/letflow/routers/tasks.ex`: `handle_complete` 325; `handle_complete_result` 348-427; `handle_claim` 431; `handle_claim_result` 439-473; idempotency key 331; actor 326.
`lib/letflow/api/error.ex` and `lib/letflow/api/authorization.ex` (1347-1352): `serialise` 121-151; `forbidden` 182; `conflict` 233; `unprocessable` 293; `promotion_conflict` 404. `lib/letflow/api/response.ex`: `send_problem` 115; `forbidden` 136; `unprocessable` 178.
`lib/letflow/plugs/auth_pipeline.ex`: 107-114, 141-150, 196, 227-234, 370-388. `lib/letflow/identity.ex`: `verify_api_token` 1648, 1686.
`lib/letflow/engine/variable_merge.ex`: `merge` def 210 (spec 205). `lib/letflow/engine/variable_schema.ex`: `variable_validations` 279-301; `fetch_schemas` 336; `validations_for` 407; `outcome_for` 440. `lib/letflow/engine/form_expression_reevaluation.ex`: `reevaluate` def 161 (spec 154). `lib/letflow/engine/task.ex`: 57-77, 107. `lib/letflow/engine/task_activation.ex`: `append_multi_from_existing_records` 358; `cancel_pending_escalation_timers` 533. `lib/letflow/engine/sub_process.ex`: 824-847. `lib/letflow/scheduler.ex`: `do_fire` 297 (escalation arm at 312). `lib/letflow/event_store.ex`: `append` 218; `claim_idempotency` 649; `resolve_duplicate` 678. `lib/letflow/audit.ex`: `insert_entry` 231; `entry_attrs` 121.
`lib/letflow/definitions/graph.ex`: `Node` 171; `Violation.code` 222-260; `validate_node_attributes` 436; `validate_flow` 487; `check_reachable_from_start` 698; `build_adjacency` 856; `check_form_schema_expressions` 1041; `check_human_task_escalation` 1059. `lib/letflow/definitions/semantic_validation.ex`: `validate` 189-207; `ancestors_or_self` 266; `may_write?` 299-318; `parse_condition` 440; `collect_var_paths` 486. `lib/letflow/definitions/role_binding.ex`: 23-74. `lib/letflow/definitions.ex`: create phases 557-561; `validate_definition_graph` 1272-1297; `validate_update_graph` 1675-1682; `run_semantic_validation` 2372. `lib/letflow/definitions/solution_pack.ex`: 1389, 1397-1411. `lib/letflow/definitions/promotion_review_store.ex`: 429-436. `lib/letflow/routers/promotions.ex`: 603-604.
`priv/repo/migrations/20260818110003_create_tasks.exs`: 87-88. `docs/requirements.yaml`: REQ-061 at 3463 (caller list 3485-3490); REQ-459..466 at 34475-35044. `docs/migration/decisions/0007-variable-merge-validates-new-keys.md`: 79, 108. `docs/anti-patterns.md`: 939-976, 4474-4530. `lib/letflow/design/req396-human-task-escalation-timer.md`, `req455-definition-validator-gaps.md`, `iss0784-task-activation-rollback-audit-signal.md`.
