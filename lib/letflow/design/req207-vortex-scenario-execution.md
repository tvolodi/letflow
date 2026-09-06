# REQ-207 — Run Vortex's 4 simulation scenarios through REQ-205's harness

**Requirement:** REQ-207. Third requirement of S7 (`docs/migration/stage-7-simulation-uat-parity.md`).
**Stage:** S7
**Owner (design):** CODE-DESIGNER — **Owner (implementation):** ELIXIR-DEV
**Depends on:** REQ-205 (`lib/letflow/design/req205-simulation-harness-foundation.md`,
`test/support/simulation/runner.ex`, `test/support/simulation/seed.ex`) and, for its
`:skip`/`:unbuilt_feature` vocabulary, REQ-206's own extension of the same two files
(`lib/letflow/design/req206-swiftroute-scenario-execution.md` §2 — read from
`origin/feature/WF02-REQ206-20260901`, since REQ-206 has not merged to `main` as of
this design session; see §0's branch-state note, this is the load-bearing open
question of this whole design).

**Scope discipline** (mirrors REQ-205/206's own): this requirement runs Vortex
scenario content through the existing harness. It does **not** build the
entity/entity-query subsystem (S5/S6 scope — see §4 for why AC4 is BLOCKED_ON_DEPENDENCY,
not built here), does not touch SwiftRoute/Meridian (REQ-206/REQ-208), and does not
extend `Runner`'s disposition vocabulary further than REQ-206 already has (no new
`via`/`disposition` value is needed for any of the 3 real Vortex scenarios — see §0).

---

## §0 — Verified source-of-truth facts (not assumed)

### §0.1 Branch state — REQ-206 is not yet merged, and this design depends on it

Checked this session: `git log --all --oneline | grep -i REQ206` shows REQ-206's work
exists only on `origin/feature/WF02-REQ206-20260901` (`HEAD` there:
`7bd75cb5 fix(REQ-206): implement SwiftRoute scenario execution...`), not as an
ancestor of `main` or of this branch (`feature/WF02-REQ207-20260901`, cut from `main`
before REQ-206 merged — `git merge-base --is-ancestor 7bd75cb5 HEAD` returns false).
`lib/letflow/design/req206-swiftroute-scenario-execution.md` and
`test/support/simulation/scenario_fixture.ex` (`Letflow.Simulation.ScenarioFixture`)
therefore do **not exist on this branch today** — they were read via
`git show origin/feature/WF02-REQ206-20260901:<path>` for this design, not from this
branch's own working tree.

**This is a real, load-bearing dependency, not a convenience.** REQ-207 needs three
things REQ-206 adds to `test/support/simulation/runner.ex`/`Scenario`/`RunReport`,
none of which exist in `Letflow.Simulation.Runner` as shipped by REQ-205 alone:

1. `Scenario.step().via :: :api | :gui | :skip` (REQ-205 has only `:api | :gui`) —
   not actually needed by this requirement's 3 real scenarios (see §0.2 — no Vortex
   scenario has a missing-endpoint step the way SwiftRoute's timeout-escalation did),
   listed here for completeness only.
2. `Letflow.Simulation.ScenarioFixture.load!/1` — the YAML-to-`Scenario`-struct
   parser REQ-206 built (REQ-205 §9 OQ-2 explicitly deferred writing this parser to
   "REQ-206/207/208's actual scenario content"). REQ-207 needs this function to exist;
   it does not re-design or re-implement it (see §1.3).
3. The `:custom` precondition registry pattern and the `produces`/template-substitution
   mechanism (both REQ-205-shipped, unchanged by REQ-206) — used as-is.

**Design-time resolution, stated explicitly, not silently assumed:** this design is
authored *as if* REQ-206 has already merged to `main` by the time REQ-207's Step 2a
(ELIXIR-DEV implementation) begins — i.e. it specifies `ScenarioFixture.load!/1` as an
already-existing dependency to import and call, the same way REQ-206's own design
specified `Seed`/`Runner` as already-existing REQ-205 output. **Open question OQ-1
(§7) states the fallback plan explicitly** if REQ-206 has *still* not merged when
ELIXIR-DEV starts Step 2a: ELIXIR-DEV must not silently reimplement
`ScenarioFixture.load!/1` from scratch (parallel-structure duplication is exactly the
anti-pattern REQ-206's own design §1.3 called out) — instead it stops and asks ORCH to
either land REQ-206 first or explicitly authorize a duplicate/inlined YAML-load helper
scoped to this requirement only, flagged for REVIEWER's idiom review.

### §0.2 Vortex scenario content — self-authored synthetic, same disposition as REQ-206

Same R-Co-unreachability finding as REQ-205/206's own sessions:

```
ls "c:\Users\tvolo\dev\ai-dala\R-Co" -> No such file or directory (this session)
find / -maxdepth 3 -iname "*R-Co*" -o -iname "*ai-dala*" -> no checkout found
```

`test/fixtures/simulation/vortex/{company,org_structure,process_quality_check,
process_work_order}.yaml` are **real**, ISS-0388-ported R-Co content (each file's own
header comment states this; independently re-read this session, confirmed real
`display_name`/9 real `actor_id`s/2 real process graphs — see §0.3 below for the two
process graphs' actual shape). R-Co's real `tests/simulation/scenarios/*.yaml`
corpus — the 4 Vortex *scenario* files this requirement needs — remains unreachable
from this sandbox, same class of gap ISS-0388 fixed for the company/org/process
fixtures but has not yet fixed for scenario files (a fresh follow-up in the same
family, not a re-opening of ISS-0388 itself — REQ-206's design recommended a sibling
issue for its own 4 SwiftRoute scenario files; this design recommends the equivalent
for Vortex's, see §7's issue-filing note).

The 4 Vortex scenario YAMLs this requirement authors are therefore
**self-authored synthetic fixtures**, structurally faithful to REQ-207's own
requirement-text field-by-field account (step counts, `via` values, the EUR 10,000
threshold, the CRITICAL/false-positive branches, the entity-list scenario's step
count and `pipeline_test` path) — same disposition REQ-205/206 already established
and disclosed, not a new compromise. Every authored file carries the same header
comment convention:

```
# Synthetic — R-Co's tests/simulation/scenarios/<name>.yaml is unreachable from this
# sandbox (see lib/letflow/design/req207-vortex-scenario-execution.md §0.2);
# structurally faithful to REQ-207's own requirement-text field-by-field account,
# not a byte-for-byte port.
```

### §0.3 Existing process fixtures already model 2 of the 3 real scenarios' processes

Read this session, both under `test/fixtures/simulation/vortex/`:

- **`process_quality_check.yaml`** (filename kept for backward compat; its own
  header comment says it was ported from R-Co's
  `process_production_order_release.yaml`) — `name: "Production Order Release"`.
  Graph: `start -> capacity-review (HUMAN_TASK, role-production-manager) ->
  [budget-gate (EXCLUSIVE_GATEWAY) if capacity_decision == approve, else
  notify-planner] -> [budget-approval (HUMAN_TASK, role-controller) if
  order_value_eur > 10000, else assign-line (SERVICE_TASK)] -> ... ->
  end-released / end-rejected`. This is **exactly**
  `vortex-production-order-above-threshold`'s process: edge `e5`
  (`order_value_eur > 10000`) is the literal EUR 10,000 budget-threshold condition
  REQ-050's exclusive-gateway CEL/expr dispatch evaluates (same mechanism REQ-206's
  `process_route_approval.yaml`/`e3` exercises on a different process definition,
  per this requirement's own text) — but note `assign-line` (the requirement's
  "service-task-equivalent line-assignment step") and `auto-reject-order`/
  `notify-planner` are `SERVICE_TASK` nodes, and `Letflow.Engine`'s
  `dispatch_node/4` (`lib/letflow/engine/transition.ex:334-339`, catch-all clause,
  confirmed by reading this session) returns
  `{:error, {:node_type_not_yet_implemented, :SERVICE_TASK, node_id}}` for **every**
  `SERVICE_TASK` node — this is a platform-wide Engine gap, not scenario-specific
  (REQ-206's own design hit the identical wall on `process_route_approval.yaml`'s
  `release-shipment`/`auto-reject` `SERVICE_TASK`s and worked around it with a
  test-local simplified graph — §2 below does the same).
- **`process_work_order.yaml`** (filename kept for backward compat; header comment
  says it was ported from R-Co's `process_supplier_quality_deviation.yaml`) —
  `name: "Supplier Quality Deviation"`. Graph: `start -> quarantine-batch
  (SERVICE_TASK) -> severity-classification (HUMAN_TASK, role-quality-manager) ->
  false-positive-check (EXCLUSIVE_GATEWAY) -> [release-quarantine (SERVICE_TASK) ->
  end-false-positive, if false_positive == true] / [severity-routing
  (EXCLUSIVE_GATEWAY) -> corrective-action-subprocess (SUB_PROCESS) if severity ==
  'critical', else supplier-warning/supplier-notification (SERVICE_TASK) -> ... ->
  close-deviation (SERVICE_TASK) -> end-closed, if false_positive == false]`. This
  is **exactly** both `vortex-supplier-quality-deviation-critical`'s and
  `vortex-supplier-quality-deviation-false-positive`'s shared process — same
  definition, two different `false_positive`/`severity` variable combinations
  driving two different terminal states (`end-closed` via the SUB_PROCESS branch
  vs. `end-false-positive` via the compensation branch), exactly matching the
  requirement text's framing that both scenarios exercise the same process
  definition on different branches. `quarantine-batch` and `release-quarantine`/
  `supplier-warning`/`supplier-notification`/`close-deviation` are all `SERVICE_TASK`
  — the same Engine gap applies; §2 below designs the test-local workaround.

**`corrective-action-subprocess` (`SUB_PROCESS` node) is real and dispatchable**,
confirmed by reading `lib/letflow/engine/transition.ex:511-530`
(`dispatch_sub_process_entry/4`): a token arriving at a `SUB_PROCESS` node produces
a `{:sub_process_start, token_id, node_id}` pending event (when no child instance is
already in flight) which the impure caller (`Letflow.Engine`, outside `transition.ex`'s
pure core) turns into a real child-instance row. This is the one node type EO-001's
"sub-process spawn on CRITICAL classification" claim can be verified against for
real — see §3.2.

### §0.4 Real routes and context functions — same set REQ-206 already confirmed, reused as-is

No new route/context-function discovery is needed; REQ-206's §0 table (paths under
`/instances`, `/tasks`, `/definitions`, `/onboarding`, `/audit`, `/identity`, all
mounted by `Letflow.Plugs.ApiPipeline`) applies unchanged, since this is the same
running application. Re-confirmed this session that `GET /api/v1/tasks?
instance_id=<uuid>&status=PENDING` (REQ-206's settled-OQ-2, `lib/letflow/routers/tasks.ex`'s
`handle_list/3`) is the mechanism for resolving a task id from an instance id — used
identically here.

**Claim-before-complete — not required**, same finding REQ-206's §0 already settled
by reading `lib/letflow/api/authorization.ex`'s `evaluate_access/2`
(`:TasksComplete` always yields unconditional `:Allow`) and
`Letflow.Engine.complete_task/3` (no assignee precondition). Reused as-is, not
re-derived.

**Role-attributed task assignee resolution — same settled fact REQ-206 found**, by
reading `lib/letflow/engine/task_activation.ex`'s `resolve_assignee/1`: a
role-attributed `HUMAN_TASK`'s `assignee_type` is `nil` and `assignee_ref` is the
literal `role` attribute string (e.g. `"role-quality-manager"`). **This directly
affects EO-1-style `task_assigned` verifications below** (§3.2/§3.3): exactly as
REQ-206's own `req206_swiftroute_test.exs` found (`assignee_type == "user"` never
matches a role-attributed task, so `Runner`'s `task_assigned` verifier necessarily
returns `:fail` even though the assignment is semantically correct), this design's
`task_assigned` outcome checks assert `outcome in [:pass, :fail]` with the `observed`
map carrying the real `assignee_ref` value as the evidence — never asserting
`:pass` outright — for any expected outcome scoped to a role-attributed task. This is
not a new limitation this design introduces; it is `Letflow.Simulation.Runner`'s
existing `task_assigned` method (REQ-205 §6, unchanged by REQ-206), applied to the
same role-attribution shape REQ-206 already hit.

### §0.5 Entity/entity-query subsystem — confirmed NOT landed (settles AC4)

Checked this session, two independent ways:

1. PROVENANCE (historical, not current decision authority):
   `lib/letflow/router.ex`'s own router-inventory table (read directly):
   ```
   | `Letflow.Routers.Entities`    | `entities.zig`     | S5/S6 (entity/data-model subsystem)   |
   | `Letflow.Routers.EntityQuery` | `entity_query.zig` | S5/S6 (same, plus query compiler)     |
   ```
   Both rows are in the **reserved, unbuilt** section of that table (same section
   REQ-205 §0 already confirmed contains `Letflow.Routers.SimulationTest`) — not
   mounted.
2. PROVENANCE (historical, not current decision authority):
   `grep -n -i "entit" docs/requirements.yaml` — every match is either an unrelated
   word (`identity`) or a *mention* of `entities.zig`/`entity_query.zig` inside S5's
   scope-survey comment block (`docs/requirements.yaml:3673-3674`, `:4004-4005`) and
   inside REQ-207's own requirement text (`:11749`). **No `docs/requirements.yaml`
   entry has a `title:` naming an entity/entity-query requirement at all** — unlike
   `entities.zig`/`entity_query.zig`'s sibling deferred subsystems
   (`process_modules.zig`, `webhooks.zig`, `simulation_test.zig`), none of which are
   expanded into their own `REQ-NNN` id yet either (S5/S6 have not reached that part
   of their own scope survey).

PROVENANCE (historical, not current decision authority):
**Conclusion, stated explicitly per the requirement's own instruction:** the
entity/entity-query subsystem **has not landed** — no REQ id builds it, no router
mounts it, no context module exists under `lib/letflow/` for it (also independently
grepped: no `lib/letflow/entities.ex`/`entity_query.ex` file exists). Per the
requirement text's own disposition rule, this settles
`vortex-entity-list-filter-and-page` as **BLOCKED_ON_DEPENDENCY**, naming
`Letflow.Routers.Entities` / `Letflow.Routers.EntityQuery` (`entities.zig` /
`entity_query.zig`, S5/S6) as the specific missing subsystem — **not**
`UNBUILT_FEATURE`, since R-Co plainly has this capability (`entities.zig`/
`entity_query.zig` are real, cited R-Co source files) and Letflow's own migration
sequence has simply not reached S5/S6's entity work yet. See §4 for the full
disposition design and report format.

---

## §1 — Scenario YAML corpus: authoring and parsing

### 1.1 File layout

```
test/fixtures/simulation/vortex/scenarios/production-order-above-threshold.yaml
test/fixtures/simulation/vortex/scenarios/supplier-quality-deviation-critical.yaml
test/fixtures/simulation/vortex/scenarios/supplier-quality-deviation-false-positive.yaml
test/fixtures/simulation/vortex/scenarios/entity-list-filter-and-page.yaml
```

New `scenarios/` subdirectory under the existing `test/fixtures/simulation/vortex/`
tree (parallel to REQ-205's `company.yaml`/`org_structure.yaml`/`process_*.yaml`,
which stay untouched, and parallel to REQ-206's own `swiftroute/scenarios/` layout).
Each file carries the §0.2 header-comment convention.

### 1.2 YAML shape — reuses `Letflow.Simulation.Scenario`'s fields, REQ-206's extension included

Each scenario YAML's top-level keys map 1:1 onto `Scenario`'s struct fields as shipped
by REQ-205 + REQ-206 (`id`, `company_id`, `process_id`, `actors`, `preconditions`,
`steps`, `expected_outcomes`, `unbuilt_feature`). **No further struct extension is
needed by this requirement** — every one of the 3 real Vortex scenarios' steps is
`via: api` (no `:gui`/`:skip` step exists in any of them; see §3), and none of the 3
carries a top-level `unbuilt_feature` key (that disposition, per §0.5, applies to the
4th scenario at a level `Runner.run/1` never even sees — see §4.2, the
BLOCKED_ON_DEPENDENCY disposition is decided and reported *before* `ScenarioFixture.load!/1`
or `Runner.run/1` are ever called for that scenario, since calling them on a scenario
whose backing subsystem doesn't exist would either raise on unresolvable actions or
require inventing fictional endpoints — neither is acceptable).

`vortex-entity-list-filter-and-page.yaml` is still authored (§4.3) with a `via: gui`
value on every one of its 6 steps and a `pipeline_test` key
(`web/tests/e2e/pipelines/entity-list-query.pipeline.e2e.spec.ts`) matching the
requirement text's literal field-by-field account — for record-keeping/future
re-execution once S5/S6 lands, structurally complete but never loaded/run by this
requirement's own test module (§4.3).

### 1.3 Parsing — `Letflow.Simulation.ScenarioFixture.load!/1`, REQ-206's module, reused as-is

**This requirement does not write a new parser.** REQ-206's design (§1.3, that
document) already builds `test/support/simulation/scenario_fixture.ex`
(`Letflow.Simulation.ScenarioFixture.load!/1`) as the one YAML-to-`Scenario`-struct
parser REQ-205 §9 OQ-2 anticipated for "REQ-206/207/208's actual scenario content."
REQ-207 imports and calls it exactly as REQ-206's own test module does — same
`@spec load!(path :: String.t()) :: Letflow.Simulation.Scenario.t()`, same
closed-vocabulary atomization discipline (`String.to_existing_atom/1` against the
struct's own declared atom sets for `via`/`check`/`method`, raising `ArgumentError` on
an unrecognized value). See §0.1 for what happens if this module does not yet exist
on `main` when implementation starts.

---

## §2 — Test-local simplified process graphs (SERVICE_TASK workaround)

Per §0.3, both real vortex process fixtures have `SERVICE_TASK` nodes on their
critical path, and `Letflow.Engine.dispatch_node/4` does not yet implement that node
type (platform-wide gap, not scenario-specific — REQ-206 already discovered and
worked around the identical gap on SwiftRoute's process). This requirement follows
the **same workaround REQ-206 used**: a test-local simplified process graph, defined
inline in the test module (not committed as a `process_*.yaml` fixture file, matching
REQ-206's `@simple_approval_graph` precedent exactly), that replaces every
`SERVICE_TASK` node with either a direct edge to the next real node or an `END` node,
preserving every `HUMAN_TASK`/`EXCLUSIVE_GATEWAY`/`SUB_PROCESS` node and every
condition string verbatim from the real fixture.

### 2.1 `@simple_production_order_graph` (for `vortex-production-order-above-threshold`)

Derived from `process_quality_check.yaml` (§0.3), with `SERVICE_TASK` nodes elided:

| Real fixture node | Simplified graph treatment |
|---|---|
| `start` (START) | Unchanged |
| `capacity-review` (HUMAN_TASK, `role-production-manager`) | Unchanged, same conditions on outgoing edges |
| `escalate-to-ceo` (HUMAN_TASK, `role-ceo`) | Unchanged (not exercised by this scenario's "budget threshold" path per se, but kept so the graph stays structurally valid — REQ-028's structural validator requires every node reachable from `start` to have a path to an `END` node; omitting it entirely would need re-deriving the whole edge set instead of a minimal SERVICE_TASK-only substitution) |
| `budget-gate` (EXCLUSIVE_GATEWAY) | Unchanged — `order_value_eur > 10000` / `<= 10000` conditions kept verbatim (this edge is the scenario's whole point) |
| `budget-approval` (HUMAN_TASK, `role-controller`) | Unchanged |
| `assign-line` (SERVICE_TASK) | **Replaced** by a direct edge from `budget-approval`'s `approve` branch (and from `budget-gate`'s `<= 10000` branch) straight to `end-released` (an END node) — this is what the requirement text calls "a service-task-equivalent line-assignment step": in the simplified graph it is represented as *reaching* `end-released`, not as a real service dispatch (Engine cannot do that yet), and the design states this substitution explicitly so a reader does not mistake "instance reached end-released" for "the line-assignment service call actually fired" |
| `auto-reject-order` (SERVICE_TASK) | **Replaced** by a direct edge to `end-rejected` (an END node), same substitution rationale |
| `notify-planner` (SERVICE_TASK) | **Elided** — its only real role in the fixture is a fan-in node between `assign-line`/`capacity-review`'s reject branch and the two END nodes; the simplified graph routes directly to `end-released`/`end-rejected` instead, so no separate notify step exists |
| `end-released`, `end-rejected` (END) | Unchanged |

**Concretely, the simplified edge set:**
```
start -> capacity-review
capacity-review -> budget-gate           [capacity_decision == 'approve']
capacity-review -> end-rejected          [capacity_decision == 'reject']
capacity-review -> escalate-to-ceo       [fallback/timeout edge, unused by this scenario]
escalate-to-ceo -> budget-gate           [capacity_decision == 'approve']
escalate-to-ceo -> end-rejected          [capacity_decision == 'reject']
budget-gate -> budget-approval           [order_value_eur > 10000]
budget-gate -> end-released              [order_value_eur <= 10000]
budget-approval -> end-released          [budget_decision == 'approve']
budget-approval -> end-rejected          [budget_decision == 'reject']
budget-approval -> end-rejected          [fallback/timeout edge]
```

`order_value_eur: 15000` (the requirement's literal EUR 15,000 above the EUR 10,000
threshold) forces edge `budget-gate -> budget-approval`, never
`budget-gate -> end-released` directly — this is the load-bearing assertion
(AC1's "routed to controller approval rather than skipping straight to line
assignment").

### 2.2 `@simple_supplier_deviation_graph` (for both critical and false-positive scenarios)

Derived from `process_work_order.yaml` (§0.3), with `SERVICE_TASK` nodes elided,
`SUB_PROCESS` and both `EXCLUSIVE_GATEWAY`s kept real:

| Real fixture node | Simplified graph treatment |
|---|---|
| `start` (START) | Unchanged |
| `quarantine-batch` (SERVICE_TASK) | **Elided as a distinct node.** Per the requirement text, "quarantine fires unconditionally" is this node's business meaning — in the real fixture it is a real MES call (`POST /mes/batches/{batch_ref}/quarantine`) Engine cannot yet dispatch. Rather than silently dropping the audit-event evidence EO-001 needs (a real `quarantine`-scoped audit entry with a real timestamp — see §3.2), the simplified graph keeps a **HUMAN_TASK** in `quarantine-batch`'s exact graph position, `role: role-quality-manager`, auto-completed by the scenario's own step 1 (see §3.2's step table) — this produces the same real, timestamped `task.create` **and** `task.complete` audit rows a SERVICE_TASK dispatch would have produced, satisfying EO-001's ordering requirement against real queried state without inventing a fictional SERVICE_TASK dispatch. This substitution is stated explicitly, not left implicit, since it changes "quarantine" from a service call to a task in the test topology — the state-machine *shape* (one node between `start` and `severity-classification`, unconditional) is preserved exactly. |
| `severity-classification` (HUMAN_TASK, `role-quality-manager`) | Unchanged |
| `false-positive-check` (EXCLUSIVE_GATEWAY) | Unchanged — `false_positive == true` / `== false` conditions kept verbatim |
| `release-quarantine` (SERVICE_TASK) | **Replaced** by a direct edge from `false-positive-check`'s `true` branch straight to `end-false-positive` |
| `severity-routing` (EXCLUSIVE_GATEWAY) | Unchanged — `severity == 'critical'` / `'major'` / `'minor'` conditions kept verbatim (only `'critical'` is exercised by this requirement's 2 scenarios, both of which set `false_positive: false`) |
| `corrective-action-subprocess` (SUB_PROCESS) | **Unchanged, real** — this is the one node §0.3 confirmed is dispatchable today; kept exactly as-is, since it is EO-001's actual subject |
| `supplier-warning`, `supplier-notification`, `close-deviation` (SERVICE_TASK) | **Elided.** The critical-severity scenario's only real path from `corrective-action-subprocess` needed is onward to `end-closed`; the simplified graph routes `corrective-action-subprocess -> end-closed` directly on child-instance completion (§3.2's step table item 4). `supplier-warning`/`supplier-notification` (the `'major'`/`'minor'` branches) are not exercised by either of this requirement's 2 scenarios and are omitted from the simplified graph entirely — REQ-028's structural validator only requires every node *present in the graph* to reach an END node, not that every real fixture's node be represented. |
| `default-to-major` (SERVICE_TASK, on-timeout fallback) | **Elided**, same rationale — not exercised (no scenario here relies on `severity-classification` timing out) |
| `end-closed`, `end-false-positive` (END) | Unchanged — **both** kept, since the false-positive scenario's whole point (AC3) is reaching `end-false-positive` specifically, distinct from `end-closed` |

**Concretely, the simplified edge set:**
```
start -> quarantine-batch                              [HUMAN_TASK substitute, unconditional]
quarantine-batch -> severity-classification
severity-classification -> false-positive-check
false-positive-check -> release-quarantine-substitute  [false_positive == true]   (direct to end-false-positive)
false-positive-check -> severity-routing               [false_positive == false]
severity-routing -> corrective-action-subprocess       [severity == 'critical']
corrective-action-subprocess -> end-closed
release-quarantine-substitute -> end-false-positive    (folded into the edge above: false-positive-check -[true]-> end-false-positive directly, since release-quarantine itself is elided per the table)
```

i.e. the actual edge list has `false-positive-check -> end-false-positive`
[`false_positive == true`] directly (folding the elided `release-quarantine`
SERVICE_TASK's pass-through into a single edge, since it had exactly one outgoing
edge in the real fixture and no branching logic of its own) and
`false-positive-check -> severity-routing` [`false_positive == false`] as the two
outgoing edges of the one real gateway both scenarios share.

### 2.3 Why elide rather than stub every SERVICE_TASK as a HUMAN_TASK

`quarantine-batch` is deliberately kept as a real graph node (substituted to
HUMAN_TASK) because EO-001 needs it to exist and produce real evidence.
`assign-line`/`auto-reject-order`/`notify-planner`/`release-quarantine`/
`supplier-warning`/`supplier-notification`/`close-deviation`/`default-to-major` are
elided entirely (folded into their neighboring edges) rather than also substituted to
HUMAN_TASK, because **no expected outcome in any of the 3 real scenarios needs
evidence of their execution** — the outcomes below verify gateway routing (which edge
was taken), sub-process spawn, terminal END node, and audit-event ordering, none of
which requires a task/audit row at those specific positions. Substituting only the
minimum needed keeps each simplified graph legible as "the same state machine, minus
what Engine cannot run yet" rather than a parallel invented process.

---

## §3 — Per-scenario execution plan

### 3.1 `vortex-production-order-above-threshold` (AC1)

3 steps, all `via: api`, using `@simple_production_order_graph` (§2.1) seeded under a
process definition name distinct from the real fixture's (matching REQ-206's
`SimpleShipmentApproval-<unique>` naming convention, e.g.
`SimpleProductionOrderRelease-<unique>`).

| Step | Actor | `action` | `params` (post-template-substitution) | `produces` |
|---|---|---|---|---|
| 1 (planner submits order) | `actor-vortex-anna` (dept-planning) | `POST /api/v1/instances` | `{"definition_name": "<seeded name>", "initial_variables": {"order_value_eur": 15000}}` | `"instance"` |
| 2a (capacity-review task lookup) | `actor-vortex-sabine` (dept-production, token `roles: ["role-production-manager"]`) | `GET /api/v1/tasks?instance_id={{produces.instance.instance_id}}&status=PENDING` | n/a | `"capacity_task"` |
| 2b (capacity-review approve) | `actor-vortex-sabine` | `POST /api/v1/tasks/{{produces.capacity_task.id}}/complete` | `{"output_variables": {"capacity_decision": "approve"}}` | `"capacity_task_result"` |
| 3a (budget-approval task lookup) | `actor-vortex-stefan` (dept-finance, token `roles: ["role-controller"]`) | `GET /api/v1/tasks?instance_id={{produces.instance.instance_id}}&status=PENDING` | n/a | `"budget_task"` |
| 3b (budget-approval approve) | `actor-vortex-stefan` | `POST /api/v1/tasks/{{produces.budget_task.id}}/complete` | `{"output_variables": {"budget_decision": "approve"}}` | `"budget_task_result"` |

Same shape as REQ-206's §3.2 table: the scenario's own "3 steps" (submit,
capacity-review, budget-approval) holds at the business-narrative/scenario-YAML level;
the lookup dispatches (2a/3a) are `Runner`-level plumbing to resolve a `task_id`, not
additional business steps.

**All 4 `expected_outcomes` (AC1's literal count):**

1. `task_assigned` — the `budget-approval` `HUMAN_TASK` (not a direct skip to
   `end-released`) was actually created, with `assignee_ref == "role-controller"` —
   the direct evidence that the budget-gate's `order_value_eur > 10000` edge was
   taken, not `<= 10000`. Per §0.4, this is a role-attributed task, so the assertion
   is `outcome in [:pass, :fail]` with `observed.assignee_ref == "role-controller"`
   as the evidence (`Runner`'s `task_assigned` method compares against
   `assignee_type == "user"`, which a role-attributed task never satisfies — same
   limitation REQ-206 already recorded, not new here).
2. `instance_state` — final instance `status == "COMPLETED"`, at `end-released`
   (verified via the instance's terminal state, not `end-rejected`).
3. `instance_state` (second entry) — persisted `variables` include
   `capacity_decision: "approve"` and `budget_decision: "approve"`.
4. `audit_event` — at least one audit entry exists for the budget-approval task's
   `complete` action (`action: "task.complete"`), scoped to that task/instance id
   (REQ-195/196's audit store, `Letflow.Audit.list_entries/1`, same as REQ-205 §6).

**AC1's "routed to controller approval rather than skipping straight to line
assignment" is outcome 1 above** — its whole evidentiary point is that the
budget-approval HUMAN_TASK (the simplified graph's stand-in for "the process did not
silently reach end-released via the <= 10000 branch") exists and was actually
assigned, not inferred from the instance's final COMPLETED status alone (which the
`<= 10000` branch would also produce, since both branches of `budget-gate` eventually
reach `end-released` in the simplified graph — outcome 1's task-existence check is
what actually distinguishes the two branches, not outcome 2's terminal-status check
by itself).

### 3.2 `vortex-supplier-quality-deviation-critical` (AC2, EO-001)

3 steps, all `via: api`, using `@simple_supplier_deviation_graph` (§2.2).

| Step | Actor | `action` | `params` | `produces` |
|---|---|---|---|---|
| 1 (batch quarantined — instance start) | `actor-vortex-karl` (dept-quality, token `roles: ["role-quality-manager"]`) | `POST /api/v1/instances` | `{"definition_name": "<seeded name>", "initial_variables": {"batch_ref": "BATCH-9911"}}` | `"instance"` |
| 2a (quarantine-batch task lookup) | `actor-vortex-karl` | `GET /api/v1/tasks?instance_id={{produces.instance.instance_id}}&status=PENDING` | n/a | `"quarantine_task"` |
| 2b (quarantine-batch complete — the HUMAN_TASK substitute for the elided SERVICE_TASK, §2.2) | `actor-vortex-karl` | `POST /api/v1/tasks/{{produces.quarantine_task.id}}/complete` | `{"output_variables": {}}` | `"quarantine_task_result"` |
| 3a (severity-classification task lookup) | `actor-vortex-nina` (dept-quality, token `roles: ["role-quality-manager"]`) | `GET /api/v1/tasks?instance_id={{produces.instance.instance_id}}&status=PENDING` | n/a | `"severity_task"` |
| 3b (severity-classification complete: CRITICAL, not false positive) | `actor-vortex-nina` | `POST /api/v1/tasks/{{produces.severity_task.id}}/complete` | `{"output_variables": {"false_positive": false, "severity": "critical"}}` | `"severity_task_result"` |

The scenario's own "3 steps" (quarantine, severity-classification, sub-process
verification) holds at the business-narrative level; 1/2a/2b/3a/3b are the same
lookup-plus-complete plumbing pattern as §3.1 and REQ-206's §3.2.

**Sub-process spawn verification (part of AC2's "exercises sub-process spawn on
CRITICAL classification"):** after step 3b, `corrective-action-subprocess` is the
token's next node (per §2.2's edge `severity-routing -[critical]->
corrective-action-subprocess`); `dispatch_sub_process_entry/4` (§0.3) produces a real
child-instance row. Verified via a 5th expected outcome (added beyond EO-001..003's
literal 3, since "exercises sub-process spawn" needs its own direct evidence, not
folded into EO-001's ordering claim): `instance_state` on the **child** instance
(resolved via `Letflow.Instances`'s parent-instance-id-scoped lookup, or — if no
by-parent lookup function exists, see OQ-2 — via the parent instance's own persisted
`waiting_child_instance_id`/equivalent field, confirmed present on `Token.t()` per
`transition.ex`'s own `waiting_child_instance_id` guard clause read in §0.3), asserting
the child instance's `status` is a real, non-nil value (i.e. a child instance row
genuinely exists) — this is the sub-process-spawn evidence, distinct from EO-001's
ordering claim below.

**EO-001's ordering claim, verified by real timestamp comparison (AC2's core
demonstration, not "both events occurred"):**

1. Query the `task.create` audit entry for the `quarantine-batch`-substitute task
   (`Audit.list_entries/1`, `resource_type: "task"`, `resource_id:
   {{produces.quarantine_task.id}}`, `action: "task.create"`) — real row, real
   `timestamp` field (`:utc_datetime_usec`, `lib/letflow/audit/entry.ex`).
2. Query the `task.create` audit entry for the `severity-classification` task
   (`resource_id: {{produces.severity_task.id}}`, `action: "task.create"`) — real
   row, real `timestamp`.
3. Assert `quarantine_entry.timestamp < severity_entry.timestamp` — a direct
   `DateTime.compare/2 == :lt` (or equivalent) comparison of two real, independently
   queried Postgres rows' `timestamp` columns, never inferred from "both entries
   exist" or from the scenario's own step ordering (the whole point per the
   requirement text: audit event **ordering**, not merely "both events occurred").

This is expressed as a 6th expected outcome with `verification.method` extended to
cover this case (see §5's open question OQ-1: `Runner`'s existing `audit_event`
method, as shipped by REQ-205, checks only "at least one matching row exists" — it
has no two-timestamps-compared verification method. This requirement needs one).

**New verification method — `audit_event_ordering` (extends `Runner`'s closed
`verification.method` enum, additively, same shape as REQ-206's `:skip`/
`unbuilt_feature` extensions):**

```
Scenario.expected_outcome().verification.method ::
  :task_assigned | :instance_state | :audit_event | :audit_event_ordering   (new 4th value)

args :: %{
  "first"  => %{"resource_id" => produces_template, "resource_type" => String.t(), "event_type" => String.t(), "prefix" => String.t()},
  "second" => %{"resource_id" => produces_template, "resource_type" => String.t(), "event_type" => String.t(), "prefix" => String.t()}
}
```

`verify_outcome/2`'s new clause: resolves `"first"` and `"second"` each via the
existing `audit_event` lookup logic (template-substituted `resource_id`, real
`Audit.list_entries/1` query, first matching row by `action`/`resource_id`/
`resource_type`), then compares `first_entry.timestamp` against
`second_entry.timestamp`. Returns `:pass` iff both entries were found **and**
`first.timestamp < second.timestamp`; `:fail` with `observed` carrying both entries
(or `nil` for whichever was not found) otherwise — the same "always carry real
queried state in `observed`, never infer PASS from absence of error" discipline
REQ-205 §6 established for the other three methods. This is the **one** design
addition to `Runner`/`Scenario`/`RunReport` REQ-207 makes on top of REQ-206's own
extension (§0.1 already established REQ-207 needs none of REQ-206's own
`:skip`/`unbuilt_feature` additions for its 3 real scenarios — this is a distinct,
new addition, additive in the same way, needed because none of REQ-205/206's three
existing verification methods can express a two-event ordering claim).

### 3.3 `vortex-supplier-quality-deviation-false-positive` (AC3)

2 steps, all `via: api`, same `@simple_supplier_deviation_graph` (§2.2), same seeded
definition as §3.2 (both scenarios run against the same process definition, per the
requirement text).

| Step | Actor | `action` | `params` | `produces` |
|---|---|---|---|---|
| 1 (batch quarantined — instance start) | `actor-vortex-karl` | `POST /api/v1/instances` | `{"definition_name": "<seeded name>", "initial_variables": {"batch_ref": "BATCH-9912"}}` | `"instance"` |
| 1b (quarantine-batch task lookup+complete — same pattern as §3.2 steps 2a/2b, folded here since the scenario's own literal count is 2, not more) | `actor-vortex-karl` | `GET .../tasks?...` then `POST .../complete` | n/a / `{"output_variables": {}}` | `"quarantine_task"` / `"quarantine_task_result"` |
| 2a (severity-classification task lookup) | `actor-vortex-nina` | `GET /api/v1/tasks?instance_id={{produces.instance.instance_id}}&status=PENDING` | n/a | `"severity_task"` |
| 2b (severity-classification complete: false positive) | `actor-vortex-nina` | `POST /api/v1/tasks/{{produces.severity_task.id}}/complete` | `{"output_variables": {"false_positive": true}}` | `"severity_task_result"` |

The scenario's literal "2 steps" (quarantine, then severity-classification marking
false-positive) holds at the business level; the lookup/complete pairs are the same
plumbing pattern used throughout.

**Note: `severity` is omitted from step 2b's `output_variables`** — per
`process_work_order.yaml`'s real condition set (§0.3), `false-positive-check`'s
routing depends only on `false_positive`, not `severity` (the `severity == 'critical'`
condition lives on the *downstream* `severity-routing` gateway, which this scenario's
token never reaches once `false_positive == true` routes it directly to
`end-false-positive`) — `severity` is simply not evaluated on this path, so no value
needs to be supplied for it.

**Terminal-state verification (AC3's core demonstration):**

- `instance_state` — final instance `status == "COMPLETED"`, at **`end-false-positive`
  specifically** — verified by querying the actual end node reached (the instance's
  persisted `variables`/state carries which `END` node the token's final transition
  landed on; if `Letflow.Instances.get_by_id/2`'s projection does not directly expose
  a "which END node" field distinct from `status`, the terminal node is resolved via
  the instance's transition history — `GET /api/v1/instances/:id/history`, per
  REQ-206's §0 route table — asserting the last transition's `to_node_id ==
  "end-false-positive"`; this exact mechanism is flagged as OQ-3, §7, since neither
  REQ-205 nor REQ-206's designs specify which of these two the `instance_state`
  verification method's `args` should use, and this design does not silently assume
  one without checking `Letflow.Instances`'s actual projection shape).
- A second `instance_state`-style check (or the same one, extended) confirms the
  instance did **not** reach `end-closed` — i.e. this is a genuinely distinct
  terminal state from the critical scenario's (§3.2), not the same COMPLETED status
  with an unchecked node identity. This is the "a distinct terminal state EO-003
  specifically checks is not conflated with the critical path's end-closed" claim
  from the requirement text, made concrete: the check must name the specific node id,
  not just assert `status == "COMPLETED"` (which both scenarios' instances share).

### 3.4 `vortex-entity-list-filter-and-page` (AC4) — see §4, not executed

Per §0.5, this scenario's disposition is BLOCKED_ON_DEPENDENCY. §4 designs the
disposition-check mechanism and report format; no `Runner.run/1` invocation, no
`Seed`/context-function call of any kind is designed for this scenario's content,
matching AC4's own framing ("the whole scenario is recorded BLOCKED_ON_DEPENDENCY").

---

## §4 — Disposition logic for `vortex-entity-list-filter-and-page` (AC4)

### 4.1 The check, as a concrete, re-runnable procedure (not a one-time finding)

Both the design session (§0.5) and ELIXIR-DEV's own implementation-time re-check
(this must be re-run at implementation time, not inherited from this design doc's own
finding without re-verification — `docs/anti-patterns.md`'s "inheriting a claim from a
record instead of re-deriving it from the source" applies here exactly, same as it
applies to REQ-206's own §0 having independently re-verified ISS-0388's resolution
rather than trusting ORCH's prior claim) run the same three-part check:

1. `grep -n "Entities\|EntityQuery" lib/letflow/router.ex` — confirm both remain in
   the reserved/unbuilt section of the router-inventory table (not merely present in
   a comment, but not mounted by an actual `forward`/route dispatch).
2. `grep -n -B1 -iE "title:.*\bentit(y|ies)\b" docs/requirements.yaml` — a
   word-bounded pattern (`\bentit(y|ies)\b`) that matches only the literal word
   "entity"/"entities" in a `title:` line, deliberately **not** the bare substring
   `entit` (which false-positives on "identity" — `grep -c "title:.*[Ee]ntit"
   docs/requirements.yaml` returns 7 today: 6 unrelated `identity`-subsystem
   requirement titles plus this line below, none an actual entity/entity-query
   claimant — that broader pattern must not be used as the re-runnable check).
   Run today: exactly **one** match,
   ```
   11714-  - id: REQ-207
   11715:    title: Run Vortex's 4 simulation scenarios against Letflow (production-order
   budget gate, supplier-deviation critical/false-positive compensation, entity list
   filter/page) and report per-scenario findings
   ```
   — the `-B1` line shows this sole match's `id:` is `REQ-207` itself
   (self-referential: this requirement's own title mentions "entity list
   filter/page" because AC4 is about entities, not because REQ-207 claims to build
   the subsystem). **Confirm the count is exactly 1 and that its preceding `id:`
   line is `REQ-207`** — that is the "no other requirement claims this subsystem"
   result. If a re-run ever shows a count greater than 1, or the same count of 1 but
   with a *different* `id:` on the `-B1` line (i.e. REQ-207's own title no longer
   the sole match, or an additional match appeared), name that other `REQ-NNN` id
   and check its `status:` field: `done` → the subsystem has landed, follow §4.2's
   "if landed" branch instead; any other status (`pending`/`in_progress`) → still
   not landed (a requirement existing but not `done` does not mean the capability
   exists yet), continue with BLOCKED_ON_DEPENDENCY, but now naming the specific
   in-flight `REQ-NNN` rather than "no requirement exists" — this refinement matters
   for ORCH's own tracking (a blocked-on-a-named-in-flight-requirement is different
   bookkeeping than blocked-on-nothing-scheduled-yet).
3. `find lib/letflow -iname "entities.ex" -o -iname "entity_query.ex"` (or
   equivalent `Glob`) — confirm no context module exists under `lib/letflow/`.

All three concurring (as they did in this design session, §0.5) is what licenses
BLOCKED_ON_DEPENDENCY. If any one of the three disagrees with the others (e.g. a
context module exists but no route is mounted yet), that is itself worth recording in
the report's disposition note rather than silently picking one signal — flagged as
OQ-4 below, since this design's own 3-way check is unanimous and the mismatch case
is therefore untested by this session, but ELIXIR-DEV's re-run might not be.

### 4.2 If landed (branch not taken by this design, per §0.5's finding, but designed for completeness per the requirement's own instruction)

Run the scenario's api-equivalent assertions for real: `entity-list-filter-and-page`
would need its own `Scenario`/step table (filter/sort/page query dispatches against
whatever `Letflow.Routers.EntityQuery` exposes, plus a field-level-authorization
check — a request from a role without cost-figure visibility must return the entity
list with the cost field either absent or nulled, verified as a real response-body
assertion, not inferred from a 200 status) — this table is **not designed here**,
since designing the concrete step/outcome shape against an API surface that does not
exist yet would be speculative (this design does not know `EntityQuery`'s actual
route paths/param names, since S5/S6 has not built them). The gui steps (however many
the real scenario turns out to have) are recorded `DEFERRED_TO_S8`, matching
REQ-206's own precedent for a scenario whose api-equivalent half runs for real but
whose gui half stays deferred. **This branch is flagged explicitly as future work,
picked up by whichever later requirement first finds the subsystem landed** — most
likely a rework of this same scenario once S5/S6's entity work reaches its own
REQ-id and lands, not a task for REQ-207's own implementation to speculatively
pre-build against an unstable/nonexistent API shape.

### 4.3 If not landed (the branch actually taken, per §0.5)

**Report format (RunReport-shaped, but a `Runner.run/1` value is never constructed
for this scenario — this is a hand-built report entry, not a harness output)**, to
keep this requirement's own report (§6) structurally uniform across all 4 scenarios
despite this one never touching `Runner`:

PROVENANCE (historical, not current decision authority):

```
%{
  scenario_id: "vortex-entity-list-filter-and-page",
  disposition: :blocked_on_dependency,
  missing_subsystem: "Letflow.Routers.Entities / Letflow.Routers.EntityQuery (entities.zig / entity_query.zig, S5/S6)",
  evidence: [
    "lib/letflow/router.ex: both Entities/EntityQuery rows in reserved/unbuilt section (not mounted)",
    "docs/requirements.yaml: the only title: match for word-bounded entity/entities is REQ-207's own self-referential title (grep -n -B1 -iE \"title:.*\\\\bentit(y|ies)\\\\b\" docs/requirements.yaml -> exactly 1 match, id: REQ-207)",
    "no lib/letflow/entities.ex or entity_query.ex context module exists"
  ],
  steps_executed: 0,
  note: "R-Co has this capability (entities.zig/entity_query.zig are real R-Co source files); Letflow's own migration sequence has not reached S5/S6's entity work yet. This is BLOCKED_ON_DEPENDENCY, not UNBUILT_FEATURE (contrast REQ-206's delivery-note-attachment finding, where neither codebase has the capability at all)."
}
```

This entry is asserted directly in the test module (a plain function returning this
map, or an ExUnit test asserting each evidence line is still true via the same three
greps/finds §4.1 lists — making the disposition **re-verifiable by running the test**,
not a static claim frozen at design time) — see §6's test-module structure.

The scenario YAML file itself (`entity-list-filter-and-page.yaml`, §1.1/§1.2) is still
authored and `ScenarioFixture.load!/1`-parseable (structurally complete, 6 `via: gui`
steps, `pipeline_test` field) for record-keeping, but **`Runner.run/1` is never
called on it** by this requirement's test module — calling it would either raise
(no `:api` step exists to route anywhere real) or require the harness itself to grow
BLOCKED_ON_DEPENDENCY-awareness it doesn't need for any other scenario in this stage,
which this design does not propose.

---

## §5 — Test module structure

`test/letflow/simulation/req207_vortex_test.exs` — one ExUnit module, `describe`
block per scenario, mirroring `test/letflow/simulation/req206_swiftroute_test.exs`'s
shape exactly (`use Letflow.DataCase, async: false`; `Sandbox.mode(Letflow.Repo,
:auto)`; a `setup` block seeding the vortex company/org/2 simplified process
definitions once per test, unique-slug-scoped via
`Letflow.TenantSlugFixture.unique_slug("req207")`; actor tokens created with the
literal `role-*` strings §0.4/§3 tables specify; a `teardown/1` private function
dropping the tenant's schema and identity/onboarding/registration rows, same shape as
REQ-206's).

```
describe "vortex-production-order-above-threshold" do
  test "..." — §3.1's 5 steps + 4 expected_outcomes
end

describe "vortex-supplier-quality-deviation-critical" do
  test "..." — §3.2's 5 steps + EO-001's ordering assertion + sub-process-spawn outcome
end

describe "vortex-supplier-quality-deviation-false-positive" do
  test "..." — §3.3's 4 steps + end-false-positive-specific terminal check
end

describe "vortex-entity-list-filter-and-page" do
  test "disposition is BLOCKED_ON_DEPENDENCY, re-verified against real source state" —
    §4.3's 3 greps/finds run live inside the test (via File.read!/File.exists?/
    System.cmd, not hardcoded booleans), asserting the same conclusion this design
    reached; fails loudly (not silently) if a later merge changes any of the 3 signals,
    which is the intended behavior — a landed entity subsystem should make this test
    fail, prompting a human/agent to update the disposition to :executed per §4.2
end
```

Per REQ-206's own precedent (`req206_swiftroute_test.exs`'s "UNIMPLEMENTED findings"
describe block), this module's disposition-evidence tests double as regression
detectors for the underlying facts, not just one-time assertions.

---

## §6 — Report format (AC5)

A single YAML report, `test/reports/req207-vortex-scenario-findings.yaml` (matching
this project's YAML-for-everything-except-handoffs convention,
`core-directives.md`'s "Output File Format Rules"), stating a closed disposition for
all 4 scenarios — no step or scenario left unaddressed (AC5's literal requirement):

PROVENANCE (historical, not current decision authority):

```yaml
requirement: REQ-207
scenarios:
  - id: vortex-production-order-above-threshold
    disposition: EXECUTED
    steps_total: 5
    steps_executed: 5
    expected_outcomes_total: 4
    expected_outcomes_pass: <filled at run time>
    expected_outcomes_fail: <filled at run time>
  - id: vortex-supplier-quality-deviation-critical
    disposition: EXECUTED
    steps_total: 5
    steps_executed: 5
    expected_outcomes_total: 6   # EO-001..003-equivalent (3) + sub-process-spawn (1) + EO-001 ordering (1, counted once as :audit_event_ordering) + terminal-state (1) -- exact count settled at implementation time against the real scenario YAML's own expected_outcomes list, not fixed here
    eo_001_ordering:
      quarantine_task_create_timestamp: <filled at run time>
      severity_classification_task_create_timestamp: <filled at run time>
      ordering_holds: <true|false, filled at run time>
  - id: vortex-supplier-quality-deviation-false-positive
    disposition: EXECUTED
    steps_total: 4
    steps_executed: 4
    terminal_node: <"end-false-positive", filled at run time -- must equal this literal, never "end-closed">
  - id: vortex-entity-list-filter-and-page
    disposition: BLOCKED_ON_DEPENDENCY
    missing_subsystem: "Letflow.Routers.Entities / Letflow.Routers.EntityQuery (entities.zig / entity_query.zig, S5/S6)"
    steps_total: 6
    steps_executed: 0
```

This report is written by ELIXIR-DEV/TEST-RUNNER at implementation/test-run time (the
design specifies its shape; populating the `<filled at run time>` placeholders with
real values is an implementation-phase obligation, same split as every other
design-doc-vs-implementation boundary in this project).

---

## §7 — Open questions (explicit, not silently resolved)

- **OQ-1 — RESOLVED/MOOT** (rework 1, this session): the question was whether
  REQ-206 has merged to `main` by the time REQ-207's Step 2a begins. Independently
  confirmed this session: REQ-206 **has merged** — commit `2d068c79` ("REQ-206:
  SwiftRoute scenario execution (S7 simulation harness) (#767)") is an ancestor of
  `main` and of this branch (`git log main --oneline | grep -i REQ206` shows it;
  `git merge-base --is-ancestor 2d068c79 HEAD` succeeds). Both of §0.1's
  load-bearing dependencies are confirmed present in the real, shipped code on this
  branch, read directly (no `git show` against another branch needed anymore):
  `test/support/simulation/scenario_fixture.ex:40-41` —
  `@spec load!(path :: String.t()) :: Scenario.t()` / `def load!(path) do`; and
  `test/support/simulation/runner.ex:45` —
  `required(:via) => :api | :gui | :skip` — the `:skip`/`:unbuilt_feature`
  vocabulary extension is real. **§0.1's fallback plan (ELIXIR-DEV stopping to ask
  ORCH for an inlined/duplicate YAML-load helper) is therefore not exercised and
  does not apply.** ELIXIR-DEV should import and call
  `Letflow.Simulation.ScenarioFixture.load!/1` and the `Runner`/`Scenario` module as
  normal REQ-205/206-shipped dependencies already on `main` — no fallback-plan
  branching, no re-derivation of this finding needed at implementation time.
- **OQ-2**: whether `Letflow.Instances` (or `Letflow.Engine`) exposes a
  parent-instance-id-scoped lookup for a spawned sub-process's child instance, or
  whether the child instance id must be resolved via the parent token's own
  `waiting_child_instance_id` field (confirmed present on `Token.t()`, §0.3, but its
  exact accessor path from a `Letflow.Instances.get_by_id/2` projection is not
  re-derived in this design session) — ELIXIR-DEV resolves this by reading
  `lib/letflow/instances.ex`/`lib/letflow/engine.ex` directly at implementation time,
  same "read the real function before calling it" discipline REQ-205/206 both
  followed for their own OQs.
- **OQ-3**: which real mechanism `Letflow.Instances.get_by_id/2`'s projection (or the
  `GET /:id/history` route) exposes for "which END node did this instance's token
  actually land on" — §3.3 names two candidate mechanisms without picking one,
  because this design session did not read `Letflow.Instances`'s actual projection
  struct/the history route's actual response shape. ELIXIR-DEV must resolve this
  before writing §3.3's terminal-state assertion.
- **OQ-4**: what to do if the three-part BLOCKED_ON_DEPENDENCY check (§4.1) disagrees
  with itself at implementation time (e.g. a context module exists but nothing routes
  to it) — §4.1 flags this as worth recording but does not fully specify the report
  shape for a disagreeing-signals case, since this design's own check was unanimous.
- **OQ-5**: R-Co source reachability for the 4 real Vortex scenario YAMLs (§0.2) — not
  resolved in this session; a follow-up issue (same shape as ISS-0388, per §0.2's
  recommendation) should be filed at Step Final naming
  `test/fixtures/simulation/vortex/scenarios/*.yaml` as the affected files, mirroring
  REQ-206's own recommended follow-up for SwiftRoute's scenario files.

---

## §8 — Acceptance-criteria-to-design-element map

| AC | Design element |
|---|---|
| AC1 (production-order-above-threshold: end-to-end, all 4 expected outcomes verified against real queried state, including controller-approval routing) | §2.1 (`@simple_production_order_graph`), §3.1 (step table + 4 expected outcomes, outcome 1's task-existence check as the load-bearing routing evidence) |
| AC2 (supplier-quality-deviation-critical: end-to-end, EO-001's ordering claim verified by real timestamp comparison, not final-status inference) | §2.2 (`@simple_supplier_deviation_graph`, `quarantine-batch`→HUMAN_TASK substitution rationale), §3.2 (step table, sub-process-spawn outcome, EO-001's timestamp-comparison mechanism), §3.2's new `:audit_event_ordering` verification method design |
| AC3 (supplier-quality-deviation-false-positive: end-to-end, reaches end-false-positive specifically, verified by querying the actual end node) | §3.3 (step table, terminal-node-identity verification, distinct-from-end-closed assertion) |
| AC4 (entity-list-filter-and-page: disposition determined by checking whether the entity/entity-query subsystem has landed, citing specific REQ id(s)/status; landed→real assertions+DEFERRED_TO_S8 gui steps; not landed→whole-scenario BLOCKED_ON_DEPENDENCY naming the missing subsystem, distinct from UNBUILT_FEATURE) | §0.5 (the landed/not-landed finding itself, with citations), §4.1 (re-runnable 3-part check), §4.2 (if-landed branch, deliberately not fully designed — future work), §4.3 (if-not-landed branch, the actually-taken one, full report shape) |
| AC5 (report states a closed disposition for every one of the 4 scenarios — no step or scenario left unaddressed) | §6 (report format, all 4 scenarios present, every scenario's own step count accounted for) |
| AC6 (`mix test`/`mix compile --warnings-as-errors` pass, real output quoted) | Implementation-phase obligation (ELIXIR-DEV/TEST-RUNNER) — no design-time element; noted so it is not missed at handoff |

No acceptance criterion is left with a "TBD" design element; every open question in
§7 is a genuinely deferred implementation-time fact-check (a `git log`, a source
read), not a silently-skipped design decision.
