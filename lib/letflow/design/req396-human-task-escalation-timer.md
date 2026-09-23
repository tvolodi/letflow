# Design: HUMAN_TASK Escalation Timer (REQ-396)

**Owner:** CODE-DESIGNER  
**Validator:** CODE-DESIGN-VALIDATOR (sign-off required before ELIXIR-DEV proceeds)  
**REVIEWER flag:** Approach decision (Option A vs B) is flagged for REVIEWER sign-off per WF-02 protocol.

---

## 1. Existing State

### 1.1 `:HUMAN_TASK` validation in `graph.ex` today

`validate_node_attributes/1` runs six checks, each producing zero or more
`%Violation{}` values. Two apply to `:HUMAN_TASK` nodes:

- **CHK-09** (`check_human_task_role/1`): every `:HUMAN_TASK` node must carry a
  non-blank `"role"` string attribute. Returns `%Violation{code: :missing_role, ...}`.
- **CHK-20** (`check_form_schema_expressions/1`): optional `form_schema` attribute's
  `x-ui.*` logic keys, if present, must be well-formed Expr expressions with no
  computed-field cycle. Delegated to `Letflow.Definitions.FormSchemaExpressions`.

No attribute named `escalation_timer_duration` or `escalation_role` exists on
`:HUMAN_TASK` anywhere in the codebase. No validator for either exists.

`graph.ex` already has `valid_iso8601_duration?/1` and the public
`parse_iso8601_duration/1` (returns `{:ok, seconds}` or `:error`), both currently
used only for `:TIMER`'s `"duration_iso8601"` attribute (CHK-12). Both are reusable
for escalation attribute validation.

### 1.2 `scheduler.ex` `fire_timer/2` today

`fire_timer/2` opens one `Repo.transaction/1` and:

1. Fetches the timer row with `FOR UPDATE` lock.
2. Marks it `status: "fired"`, `fired_at: now`.
3. Appends a `"TIMER_FIRED"` event via `EventStore.append/2`.
4. Calls `Letflow.Engine.advance_after_timer_fired/3` — which dispatches
   `{:timer_fired, token_id}` via `Transition.transition/3`, advances the token off
   the `:TIMER` node it is parked on, and persists the resulting state changes via a
   nested Ecto.Multi (SAVEPOINT).
5. Calls `maybe_rearm_timer/3` for recurring timers.

`do_fire/2` does **not** branch on `timer.timer_type` today — it routes every timer
through `advance_after_timer_fired/3` unconditionally. An escalation timer fires
against a `:HUMAN_TASK` node, not a `:TIMER` node; `dispatch_timer_fired/4` in
`transition.ex` guards `{:timer_not_at_timer, node_type, node_id}` for exactly this
mismatch. Therefore, escalation timer firing **must** enter through a separate path.

`@timer_types` in `Letflow.Scheduler.Timer` already includes `"escalation"` as a
validated timer type. No new timer-type value is needed.

`Task.status` (in `Letflow.Engine.Task`) has three values: `:pending`, `:completed`,
`:cancelled`. `:cancelled` is the existing non-actionable status — no new atom is
needed. The `task.ex` schema already has `cancelled_at` and a `cancel_reason` field
is **not** currently in the schema; see §4.1 for how the escalation reason is recorded
via the audit trail instead.

---

## 2. Chosen Approach: Option A — New Attributes on `:HUMAN_TASK`

### 2.1 Decision

**Option A is chosen.** New optional attributes `escalation_timer_duration` and
`escalation_role` are added to `:HUMAN_TASK` nodes. No new node type is introduced.

### 2.2 Trade-off analysis (flagged for REVIEWER sign-off)

**Option A — attributes on `:HUMAN_TASK`:**

- Follows the existing CHK-09/CHK-12 pattern exactly: one new `check_*` function
  added to the `validate_node_attributes/1` list, reusing `valid_iso8601_duration?/1`
  already in `graph.ex`.
- `@timer_types` already includes `"escalation"` — the arming call requires only a
  new pending_event variant and a new Engine function.
- Timer arming follows the same `{:timer_armed, token_id, node_id}` pending_event
  pattern established by REQ-187; ELIXIR-DEV has a direct precedent to follow.
- The graph topology change (fallback edge → `ceo-approval`) is small and explicit in
  the YAML.
- **Drawback:** the escalation timer is "invisible" in the graph definition — it is a
  shadow timer armed at runtime, not a visible TIMER node an author can inspect in the
  graph diagram. Authors must read the HUMAN_TASK attribute to know a timer exists.

**Option B — explicit `:BOUNDARY_TIMER` node type:**

- More visible in the graph: the boundary timer is a separate named node.
- **Drawback:** requires a new entry in `@node_type_map`, a new `dispatch_node/4`
  clause in `transition.ex`, and a new "racing" concept (two tokens would need to
  coexist for the same logical activity — one at the HUMAN_TASK, one at the
  BOUNDARY_TIMER). The current engine has no parallel-token-per-activity mechanism;
  the only multi-token mechanism is PARALLEL_GATEWAY split/join (REQ-051), which
  is structurally unrelated.
- **Drawback:** the "racing" semantics would require cancelling one token when the
  other fires — a fundamentally new engine primitive with no precedent in the current
  codebase.
- Adds a new `node_type()` union variant to every downstream consumer
  (`@valid_node_types`, `from_map/1`, `dispatch_node/4`, CHK-04 connectivity rules).
- Higher implementation complexity with no acceptance-criterion-driven payoff for this
  requirement's scope.

**Conclusion:** Option A is correct for this requirement's scope. Option B would be
appropriate if boundary timers needed to be first-class graph primitives reusable across
many node types, or if a graphical BPMN-notation requirement drove it. No such
requirement exists today.

---

## 3. New Attributes and Schema Changes

### 3.1 Attributes on `:HUMAN_TASK` nodes

Both attributes are **optional**. Both must be present or both absent (co-required).

| Attribute | Type | Constraint |
|---|---|---|
| `"escalation_timer_duration"` | string | Valid ISO-8601 duration (same parser as CHK-12); no fractional component; `"P0D"` is valid but semantically useless (should be flagged as an open question for ELIXIR-DEV). |
| `"escalation_role"` | string | Non-blank after trim; must not be an empty string. No cross-graph role-existence check at definition validation time (see §3.3 OQ-1). |

### 3.2 New CHK-21: `check_human_task_escalation/1`

**Function name:** `check_human_task_escalation/1`  
**Signature:** `@spec check_human_task_escalation(t()) :: [Violation.t()]`  
**Location:** added to the check list inside `validate_node_attributes/1`, after
`check_form_schema_expressions/1`.

**Logic:**

For each `:HUMAN_TASK` node, read `attributes["escalation_timer_duration"]` and
`attributes["escalation_role"]`:

1. If neither is present → no violation (no-op).
2. If `escalation_timer_duration` is present but not a valid ISO-8601 duration string
   → `%Violation{code: :invalid_escalation_timer, message: "Node '#{id}' (HUMAN_TASK) has an invalid 'escalation_timer_duration' attribute (#{inspect(value)}); must be a valid ISO-8601 duration string"}`.
3. If `escalation_timer_duration` is present (and valid) but `escalation_role` is
   absent or blank → `%Violation{code: :missing_escalation_role, message: "Node '#{id}' (HUMAN_TASK) has 'escalation_timer_duration' but is missing a non-empty 'escalation_role' attribute"}`.
4. If `escalation_role` is present and non-blank but `escalation_timer_duration` is
   absent → `%Violation{code: :missing_escalation_timer_duration, message: "Node '#{id}' (HUMAN_TASK) has 'escalation_role' but is missing 'escalation_timer_duration'"}`.
5. If both are present and valid → no violation.

**New `Violation.code()` variants to add:**

```
| :invalid_escalation_timer
| :missing_escalation_role
| :missing_escalation_timer_duration
```

These are appended to the `Violation.code()` closed union `@type` in `graph.ex`.

### 3.3 New `pending_event()` variant

A new variant is added to `Transition.pending_event()` in `transition.ex`:

```
{:escalation_timer_armed, token_id :: String.t(), node_id :: String.t()}
```

This follows the exact same shape and rationale as `{:timer_armed, token_id, node_id}`
(REQ-187): the pure transition layer emits the signal; the impure Engine layer resolves
the `escalation_timer_duration` attribute from the graph and calls
`Letflow.Scheduler.create/2`.

### 3.4 New `transition_event()` variant

A new variant is added to `Transition.transition_event()` in `transition.ex`:

```
{:escalation_timer_fired, token_id :: String.t()}
```

Mirrors `{:timer_fired, token_id}` (REQ-187). Used by the new
`Letflow.Engine.advance_after_escalation_timer_fired/3` to enter the pure dispatch
layer.

### 3.5 New `transition_error()` variant

```
{:token_not_at_human_task_for_escalation, node_type :: atom(), node_id :: String.t()}
```

Defensive guard for `{:escalation_timer_fired, token_id}` dispatched against a token
not currently on a `:HUMAN_TASK` node. Separate atom from
`:token_not_at_human_task` (REQ-048's error) so diagnostics are unambiguous.

### 3.6 Open questions for ELIXIR-DEV

**OQ-1:** Should `escalation_timer_duration: "P0D"` (zero duration) be rejected by
CHK-21 at definition time, or accepted and left as a semantically useless edge case?
CHK-12 accepts `"P0D"` for `:TIMER` nodes (stated explicitly in design doc §4.3).
Recommend: accept, consistent with CHK-12. Document in CHK-21's own in-code comment.

**OQ-2:** The `tasks` table has no `cancel_reason` column today (verified from
`task.ex` schema). AC-3(c) requires an audit trail showing the cancellation ordered
before the new task's creation. This is satisfied by Ecto.Multi step ordering (§4.3),
not a `cancel_reason` column. ELIXIR-DEV must confirm no new column is needed, or
add a migration if a `cancel_reason` column is desired for operational clarity.

---

## 4. Engine Behavior on Escalation Timer Fire

### 4.1 Pure transition layer: `dispatch_escalation_timer_fired/4`

**Added to `dispatch_node/4`'s dispatch table via the new event handler in
`Transition.transition/3`:**

```
{:escalation_timer_fired, token_id} ->
  # Locate token, locate node, call dispatch_escalation_timer_fired/4
```

**`dispatch_escalation_timer_fired/4` logic (signatures only, no bodies):**

```
@spec dispatch_escalation_timer_fired(Graph.t(), InstanceState.t(), Token.t(), Node.t()) ::
        {:ok, InstanceState.t(), [pending_event()]}
        | {:error, {:token_not_at_human_task_for_escalation, atom(), String.t()}}
        | {:error, {:no_matching_edge, String.t(), []}}
```

**Behavior:**

1. Guard: `node.node_type` must be `:HUMAN_TASK`. If not, return
   `{:error, {:token_not_at_human_task_for_escalation, node.node_type, node.id}}`.
2. Collect the node's outgoing edges from `definition_snapshot.edges`.
3. Select only the **default/fallback candidate** edges — those where
   `really_conditioned?/1` returns `false` (no real, non-empty CEL condition and not
   explicitly `is_default: false`). This is the same partition used by
   `advance_off_completed_node/4`, but the conditioned-edge evaluation step is
   **skipped entirely** for escalation: the escalation path unconditionally follows
   the fallback edge regardless of instance variable state.
4. Take the first default candidate (`List.first/1`). If none, return
   `{:error, {:no_matching_edge, node.id, []}}`.
5. Call `advance_token/3` (private, already exists) to move the token to the fallback
   edge's target. Return `{:ok, new_state, []}`.

**Rationale for skipping conditioned edges:** the escalation timer fires because the
human did not act within the deadline — no `variables.ops_decision` value exists in
this scenario. Evaluating conditioned edges would yield `{:no_match, []}` and fall
through to the default anyway; skipping the evaluation is both correct and avoids
`Letflow.Engine.Expr.evaluate_condition/2` calls against a nil/absent variable.

**Interaction with `dispatch_human_task/3`:** the pure-layer `dispatch_human_task/3`
function is extended to check for `node.attributes["escalation_timer_duration"]`. If
present and non-nil, it appends `{:escalation_timer_armed, token.token_id, node.id}`
to the returned `pending_events` list. This function currently ignores `_node`; the
signature changes to use `node` (not `_node`).

### 4.2 `do_fire/2` routing in `scheduler.ex`

`do_fire/2` acquires the timer row before calling any Engine function. It must now
branch on `timer.timer_type`:

```
"escalation" -> Letflow.Engine.advance_after_escalation_timer_fired(timer, Repo, prefix)
_other       -> Letflow.Engine.advance_after_timer_fired(timer, Repo, prefix)
```

Both branches are still inside the same `Repo.transaction/1` that `fire_timer/2`
opened. The pattern is identical to REQ-187's `advance_after_timer_fired/3` call.

### 4.3 `advance_after_escalation_timer_fired/3` in `engine.ex`

**Signature (no body):**

```elixir
@doc false
@spec advance_after_escalation_timer_fired(Timer.t(), Ecto.Repo.t(), prefix :: String.t()) ::
        {:ok, :advanced} | {:error, {:instance_not_active, atom()}} | {:error, term()}
```

**Step sequence (all inside the caller's already-open `Repo.transaction/1`):**

1. `fetch_and_lock_instance_projection/3` — identical to `advance_after_timer_fired/3`.
2. `build_snapshot_and_state_for_timer/4` — identical to `advance_after_timer_fired/3`
   (escalation timer carries the same `token_id` and `node_id` fields).
3. `Transition.transition(graph, seed_state, {:escalation_timer_fired, own_token_id})` —
   dispatches `dispatch_escalation_timer_fired/4`, advances token to fallback target.
4. `advance_until_stable/4` — same worklist loop; if the fallback edge leads to
   another dispatch-needing node (e.g. the `ceo-approval` `:HUMAN_TASK`), it resolves
   fully in this call.
5. `persist_escalation_timer_fired_advance/7` — persists state changes via a nested
   Ecto.Multi (SAVEPOINT), with the following **ordered** steps:

   | Multi step | Operation |
   |---|---|
   | `:cancel_original_task` | `UPDATE tasks SET status='CANCELLED', cancelled_at=now WHERE token_id = timer.token_id AND status = 'PENDING'` |
   | `:reconcile_token_records` | `do_reconcile_token_records/4` (existing) |
   | `:task_activation` | `TaskActivation.append_multi_from_existing_records/6` — creates the new task at the fallback target `:HUMAN_TASK` node (if any), using that target node's own `role` attribute as `assignee_ref` |
   | `:timer_arms` | `build_timer_arms_multi/4` — arms any further timers produced by `pending_events` (e.g. if the escalation target itself has an escalation timer) |
   | `:projection` | `reconcile_projection/5` |

**Audit ordering (AC-3c):** Ecto.Multi executes steps sequentially in declaration
order. `:cancel_original_task` is Multi step index 1; `:task_activation` is step
index 3. Postgres executes both within the same SAVEPOINT transaction; the
`cancelled_at` timestamp on the original task is set before the new task's
`inserted_at`. Any audit log that reads `tasks` rows in `inserted_at`/`updated_at`
order will see the cancellation of the original task before the insertion of the new
task.

No separate `audit_entries` insert is designed here (no `audit_entries` table exists
in the current schema; the event store's `TIMER_FIRED` event already appended by
`append_timer_fired_event/4` in `do_fire/2` is the audit record for the escalation
fire itself). ELIXIR-DEV must confirm whether a separate domain event
(`"ESCALATION_TIMER_FIRED"` or `"TASK_ESCALATED"`) is desirable for operational
observability; if so, it is appended inside `do_fire/2` before calling
`advance_after_escalation_timer_fired/3`, same as `TIMER_FIRED` is appended before
`advance_after_timer_fired/3`. This is an open question (OQ-3) for ELIXIR-DEV.

**Original task's resulting status:** `:cancelled` (stored as `"CANCELLED"` by
`Ecto.Enum` per `task.ex` §status). This is the existing non-actionable terminal
status; no new atom is added.

---

## 5. `process_route_approval.yaml` Sketch

The `ops-review` node gains two new attributes. The `fallback-ops-review` edge is
retargeted from `notify-requester` to `ceo-approval`.

```yaml
# Updated ops-review node:
- id: ops-review
  node_type: HUMAN_TASK
  attributes:
    role: role-ops-manager
    escalation_timer_duration: "PT1H"    # NEW: 1-hour deadline
    escalation_role: role-ceo            # NEW: escalation goes to CEO

# Updated fallback edge (was: notify-requester):
- id: fallback-ops-review               # id unchanged; target changed
  source: ops-review
  target: ceo-approval                  # was: notify-requester
```

**Effect on existing edges:** `e1` (ops-review → ceo-approval-gate, condition
`ops_decision == 'approve'`) and `e2` (ops-review → notify-requester, condition
`ops_decision == 'reject'`) are **unchanged**. The fallback-ops-review edge (no
condition) is the escalation path and now leads to `ceo-approval` directly, bypassing
the `ceo-approval-gate` gateway (which only branches on `declared_value`).

**Resulting graph topology for ops-review:**

- Human completes within time, approves → `e1` → `ceo-approval-gate` → existing path
- Human completes within time, rejects → `e2` → `notify-requester` → `end-rejected`
- Timer fires first → `fallback-ops-review` → `ceo-approval` → CEO task created

**`ceo-approval` node** is unchanged; it already has `role: role-ceo`. The new task
created there has `assignee_ref: "role-ceo"`, matching `escalation_role: role-ceo` on
`ops-review`. AC-3(b) ("creates exactly one new task assigned to the escalation role")
is satisfied because `ceo-approval`'s own `role` attribute equals the `escalation_role`
declared on `ops-review`.

**`fallback-ops-review` edge and CHK-13:** CHK-13 (`check_gateway_condition_presence/1`)
requires every non-default edge from an `:EXCLUSIVE_GATEWAY` to carry a condition. The
source here is `ops-review` (`:HUMAN_TASK`), not a gateway — CHK-13 does not apply.
`fallback-ops-review` remains unconditioned (no CEL, `is_default` not set), acting as
the default candidate for `advance_off_completed_node/4` and
`dispatch_escalation_timer_fired/4` alike.

**Escalation cancellation of the `timeout-ceo-approval` edge:** once the escalation
fires and the CEO task is at `ceo-approval`, the CEO can complete it normally. The
existing `timeout-ceo-approval` edge (`source: ceo-approval, target: auto-reject`,
no condition) remains the fallback for `ceo-approval`, unchanged. No further escalation
timer is armed at `ceo-approval` (it carries no `escalation_timer_duration`).

---

## 6. AC Traceability

| AC | Design element |
|---|---|
| 1. Design artefact states chosen schema shape, cites REQ-185/REQ-188 blocker | This document §2 (Option A) and §7 (citations). CODE-DESIGN-VALIDATOR sign-off required. |
| 2. `Letflow.Definitions.Graph` validates new attributes; at least one test rejects malformed value | CHK-21 (`check_human_task_escalation/1`, §3.2). Test: a `:HUMAN_TASK` node with `escalation_timer_duration: "NOT-ISO"` must produce `%Violation{code: :invalid_escalation_timer, ...}` from `validate_node_attributes/1`. |
| 3. ExUnit proves: (a) original task non-actionable, (b) one new task to escalation role, (c) audit ordering | `advance_after_escalation_timer_fired/3` (§4.3): `:cancel_original_task` Multi step before `:task_activation` Multi step; test verifies task.status == :cancelled then new task with assignee_ref == escalation_role. |
| 4. `process_route_approval.yaml` updated; simulation test exercises escalation path end-to-end | §5 YAML sketch; ELIXIR-DEV adds or extends `test/letflow/simulation/req206_swiftroute_test.exs` to exercise the escalation path via `Engine.create/2` + `fire_timer/2`. |
| 5. UAT re-run (REQ-395 + ISS-0739 dependency) | Out of CODE-DESIGNER scope; ORCH gates on REQ-395 and ISS-0739 before UAT-RUNNER rerun. |
| 6. `mix test` and `mix compile --warnings-as-errors` pass | ELIXIR-DEV AC; no implementation code here. |

---

## 7. REQ-185 / REQ-188 Blocker Citation

This requirement directly closes the deferral named in two places:

**REQ-185 preamble** (`docs/requirements.yaml` ~L9736–9742):

> "SCH-04's escalation half (HUMAN_TASK escalation_timer_duration → reassignment) is
> scoped to REQ-188 only as far as firing an ESCALATION event. Blocker:
> Letflow's Graph validates duration_iso8601 on :TIMER nodes (CHK-12, graph.ex
> check_timer_duration/1 L738) but has no escalation_timer_duration attribute on
> :HUMAN_TASK at all, so the definition-side input REQ-188 would need does not exist.
> Named in REQ-188's own text."

**REQ-188 body** (`docs/requirements.yaml` ~L10113–10120):

> "ALSO OUT OF SCOPE, BLOCKER NAMED: SCH-04's escalation timers. SCH-04 requires a
> HUMAN_TASK node carrying an escalation_timer_duration attribute, and Letflow's
> Letflow.Definitions.Graph has no such attribute and no validator for one — CHK-12
> (graph.ex L738) validates duration_iso8601 on :TIMER nodes only. The definition-side
> input does not exist, so escalation timers need a definitions-side requirement first.
> Named here rather than silently dropped."

REQ-396 is that "definitions-side requirement first." CHK-21 and the
`escalation_timer_duration`/`escalation_role` attributes on `:HUMAN_TASK` are the
definition-side inputs both deferral notes named as missing.
