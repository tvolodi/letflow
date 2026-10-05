# Design: REQ-455 -- Definition validator gaps (reachability, default route, data-before-collected, unbound task roles)

**Requirement:** REQ-455 (approved by the user 2026-10-06). **Run:** `WF02-REQ455-20261006`, WF-02 Step 1.
**Owner of the build:** ELIXIR-DEV. **Stage:** S3. **Design-only:** signatures, type shapes, algorithm
descriptions in prose. No implementation code anywhere in this document.

Evidence conventions: `file:line` references were read in the current tree on branch
`feature/WF02-REQ455-20261006` (HEAD `cb14ff09`). Two empirical probes were also run (a scratch script
outside the repo, `mix run --no-start`, MIX_ENV=dev) -- their output is quoted where it backs a
classification.

---

## 0. FIRST STEP result -- classification of the four candidate checks

| # | Candidate check | Classification | Evidence |
|---|---|---|---|
| 1a | Every node reachable from the start node | **MISSING** | `Graph.validate_graph/1` runs exactly 8 checks (`graph.ex:384-399`). The only connectivity check, `check_isolated_nodes/1` (`graph.ex:613-652`), tests each node's own in/out degree (START needs an out-edge, END an in-edge, others both). `check_cycles/1` (`graph.ex:660-680`) deliberately visits every node, not just those reachable from START (its comment at `graph.ex:654-657` says so), and exempts any cycle that touches a gateway. Probe: an island `x <-> y` of two EXCLUSIVE_GATEWAY nodes beside a valid `start -> end` returned `[]` from `validate_graph/1`, `validate_node_attributes/1` and `validate_edge_conditions/1`. |
| 1b | From every node an end node is reachable (trap with no way out) | **MISSING** | Same functions as 1a. Probe: `start -> g`, `g -> end (conditional)`, `g -> h (default)`, with `h <-> k` a SERVICE_TASK/gateway loop that never reaches an END returned `[]` from all three validators. No existing check computes reverse reachability. |
| 2 | Decision without a default route | **PARTLY EXISTS** | HUMAN_TASK: exists as CHK-19 `:human_task_no_fallback_edge` (`check_human_task_fallback_edge/1`, `graph.ex:1338-1357`, wired at `graph.ex:453`). EXCLUSIVE_GATEWAY: **missing** -- CHK-13 (`graph.ex:1196-1211`) requires every non-default gateway edge to carry a condition, CHK-15 (`graph.ex:1242-1251`) forbids default+condition, CHK-16 (`graph.ex:1258-1279`) forbids a second default; nothing requires that one default exists. Probe: gateway `g` with two conditional edges and no default returned `[]` everywhere. SERVICE_TASK / TIMER / SUB_PROCESS / START / PARALLEL_GATEWAY: a conditional outgoing edge is already refused by CHK-14 `:unexpected_edge_condition` (`graph.ex:1220-1236`, which permits a condition only on a non-default EXCLUSIVE_GATEWAY edge or a HUMAN_TASK edge). Probe: the literal ISS-0928 service-task shape (service task, two conditional edges, no default) returned two `:unexpected_edge_condition` violations from `validate_edge_conditions/1`, and nothing from the other two. See section 2 for the consequence. |
| 3 | Data used before it is collected | **PARTLY EXISTS** | `SemanticValidation.validate/2` (`semantic_validation.ex:173-188`) flags an undeclared variable root (`:undeclared_variable_reference`) -- but only on EXCLUSIVE_GATEWAY edges with a non-blank condition (`qualifying_edge?/3`, `semantic_validation.ex:267-271`; the moduledoc at `:93-110` states HUMAN_TASK is out of scope), only against `variable_schemas`, and it is skipped entirely when no schema is registered (`semantic_validation.ex:174-176`). It never looks at which node on the path writes what. Form expressions: `FormSchemaExpressions` scope rule (`form_schema_expressions.ex:40-45`, CHK-20 at `graph.ex:887-896`) already restricts `x-ui.visible_when/computed/cross_field_validation` to the SAME form's own `properties` keys, with `:form_schema_expression_out_of_scope` -- so a form expression cannot read a process variable at all; that half of the candidate **EXISTS** by construction. The remaining gap is HUMAN_TASK-sourced edge conditions and path-based writers. |
| 4 | Unbound task roles at install | **MISSING** | `SolutionPack.install/3` (`solution_pack.ex:474-481`, `run_install/5` `:1362-1392`) builds only `role_mapping_checklist` from `manifest.required_roles` via `role_mapping_checklist/1` (`solution_pack.ex:1659-1666`), which compares those names against `Authorization.roles()` (six static platform-role atoms), **not** against `tenant_role` rows and **not** against the roles human tasks actually route to. CHK-09 `check_human_task_role/1` (`graph.ex:785-795`) only requires `attributes["role"]` to be a non-blank string. Nothing reads `Letflow.Identity.RoleRegistry.list_roles/1` (`role_registry.ex:44-47`) from the definitions path. Decision 0029 section 2 (`docs/migration/decisions/0029-...md:334-387`) keeps role seeding out of the pack and the checklist advisory; this design does not touch that. |

Existing tests that do not cover the gaps (so no test already pins a contrary expectation): the
EXCLUSIVE_GATEWAY-without-default shape appears in many fixtures and test graphs and is accepted today
(section 7 lists them).

---

## 1. Where validation runs today (and where the new checks plug in)

| Entry point | Location | Runs today | New checks added here |
|---|---|---|---|
| `Definitions.create/2` (also reached by `SolutionPack.install/3` via `create_packed_definitions`, `solution_pack.ex:~1418-1440`, and by `ExportImport.import/3` / `import_with_variable_schemas/4`, `export_import.ex:133,182`) | `definitions.ex:547-562` | `validate_graph`, `validate_node_attributes`, `validate_edge_conditions`, first failing phase returns `{:error, {:graph_validation_failed, violations}}` | `Graph.validate_flow/1` as a 4th phase (checks 1, 2) |
| `Definitions.update/2` via `validate_update_graph/1` | `definitions.ex:1664-1672` | same three phases | `Graph.validate_flow/1` as a 4th phase |
| `Definitions.validate_definition_graph/2` (`POST /definitions/:id/validate`) | `definitions.ex:1266-1285` | all three Graph validators + `SemanticValidation.validate/2`, concatenated | `Graph.validate_flow/1` concatenated before the semantic list; `SemanticValidation.validate/2` itself gains check 3; result gains `warnings` (check 4) |
| `Definitions.activate/2` via `run_semantic_validation/2` | `definitions.ex:2360-2385` (comment `:2343-2352` says the three Graph validators are "deliberately NOT newly wired" here) | `SemanticValidation.validate/2` only | `Graph.validate_flow/1` added to that function so a DRAFT stored before this change cannot be activated with a dead end or missing default. Check 3 arrives through `SemanticValidation.validate/2` with no extra wiring. |

Consequences the build must respect:

* "Same as the existing codes" is met in the sense that a graph that violates 1-3 cannot become a
  DRAFT (create/update/import/install all go through the phases above) and a previously stored DRAFT
  cannot be activated (the activate wiring). Activation of an already ACTIVE definition is a no-op
  (`activate/2` returns `already_active: true`) and is not re-validated -- this is the open-question
  default: nothing already active is deactivated (OQ-1 below).
* The two failure shapes at activate are reused, not added: `{:error, {:semantic_validation_failed,
  [Violation.t()]}}` (rendered by `render_activate/2`, `routers/definitions.ex:978-987`, through the
  generic `violation_map/1` at `:1244-1246`, which stringifies any code). No new error tuple, so the
  type-table-vs-error-map drift rule (`docs/anti-patterns.md`, referenced at `routers/solution_packs.ex` render_install, ~L340-360)
  is not triggered for activate. `create/2`'s error union is unchanged.
* `violation_map/1` is code-agnostic and no TypeScript file in `web/src` lists violation codes
  (grep for `human_task_no_fallback_edge`, `multiple_default_edges`, `cycle_without_gateway` finds no
  `web/` or `docs/` consumer other than `docs/status/requirement_status.yaml` history), so new codes
  need no client change.

---

## 2. Node kinds that can carry conditional outgoing edges (check 2)

Derived from CHK-13/14/15 (`graph.ex:1196-1251`) and from the engine, which routes completion of
HUMAN_TASK, SUB_PROCESS, TIMER and SERVICE_TASK through the same `advance_off_completed_node/4`
(`engine/transition.ex:538-558`, "really conditioned" = not `is_default` and non-empty condition) and
EXCLUSIVE_GATEWAY through `dispatch_exclusive_gateway/4` (`transition.ex:769-790`, conditioned = not
`is_default`):

| Node kind | May a validated graph carry a condition on its outgoing edge? | "No default" failure today | After this change |
|---|---|---|---|
| EXCLUSIVE_GATEWAY | yes (non-default edges require one, CHK-13) | **not caught** (instance errors with `no_matching_edge`; ISS-0928) | `:no_default_route` when it has outgoing edges and none has `is_default == true` |
| HUMAN_TASK | yes (CHK-14 permits) | caught, CHK-19 `:human_task_no_fallback_edge` | unchanged; excluded from the new check so it is not double-reported |
| SERVICE_TASK, TIMER, SUB_PROCESS | no -- CHK-14 refuses any condition (`:unexpected_edge_condition`) | refused at the source of the problem | refused as before; additionally `:no_default_route` when every outgoing edge is "really conditioned" (defence in depth, covers the literal ISS-0928 wording; co-fires with CHK-14 by design, checks never short-circuit) |
| START, END, PARALLEL_GATEWAY | no (CHK-14) | refused | same defence-in-depth rule applies to any kind other than the two above |

**Requirement-text correction to flag to ORCH (not a design deviation):** REQ-455 says "ISS-0928 was a
service task". `docs/issues/ISS-0928.yaml` records the actual defect as an EXCLUSIVE_GATEWAY
(`kyc-routing`) with only conditioned edges and no default, reached after a service task; the engine
re-entry then failed with `no_matching_edge`. The literal "service task with only conditional edges"
shape is already rejected today (CHK-14) and stays rejected. The acceptance test for the ISS-0928 shape
therefore covers BOTH: the gateway shape (new `:no_default_route`, the real ISS-0928 defect) and the
service-task shape (still rejected, now by two codes).

---

## 3. Check 1 and Check 2 -- `Graph.validate_flow/1` (new public function, `graph.ex`)

A fourth top-level validator beside `validate_graph/1`, `validate_node_attributes/1`,
`validate_edge_conditions/1`. Chosen over appending to existing lists because it leaves every existing
check's output, and every existing test asserting an exact code list, unchanged.

* `validate_flow(graph :: t()) :: result()` -- same `result()` shape (`%{valid: boolean(), violations:
  [Violation.t()]}`), same never-short-circuit concatenation, pure (stdlib only), total (never raises on a
  dangling edge, duplicate id, missing START/END). Same ordering contract as the siblings: assumes, does
  not verify, that `validate_graph/1` ran first.

New checks (private, appended after CHK-21; numbering CHK-22..CHK-24 -- confirmed unused, `grep CHK-2[2-9]`
returns nothing):

* **CHK-22 `check_reachable_from_start/1`** -- `[Violation.t()]`. Sources = every START node (zero START:
  the check returns `[]`, CHK-01 owns that report; several START: all are sources). Forward breadth-first
  walk over edges whose both endpoints resolve (dangling edges contribute nothing, as in
  `build_adjacency/2`, `graph.ex:702-713`). One violation per node id not visited, in node-list order,
  duplicate ids collapsed to the first occurrence. Code `:unreachable_node`. Message names the node id and
  type: "Node '<id>' (<TYPE>) is not reachable from any START node".
* **CHK-23 `check_reaches_end/1`** -- `[Violation.t()]`. Sources = every END node (zero END: `[]`, CHK-02
  owns it). Reverse walk over the same resolved edge set. One violation per node id from which no END is
  reachable, node-list order. Code `:no_path_to_end`. Message: "Node '<id>' (<TYPE>) has no path to any END
  node". An END node trivially reaches itself.
* **CHK-24 `check_default_route/1`** -- `[Violation.t()]`. Per node that has at least one outgoing edge
  (an outgoing-edge-less node is `:isolated_node`'s concern):
  * EXCLUSIVE_GATEWAY: violation iff no outgoing edge has `is_default == true` (mirrors
    `dispatch_exclusive_gateway`'s partition, which looks at `is_default` only).
  * HUMAN_TASK: skipped (CHK-19).
  * any other kind: violation iff every outgoing edge is "really conditioned" -- not `is_default` AND
    `condition` a non-empty binary, compared **without trim**, exactly as the engine's `really_conditioned?`
    and CHK-19's `human_task_edge_really_conditioned?/1` (`graph.ex:1366-1368`) do. (The blank-vs-whitespace
    inconsistency is already disclosed in the ISS-0056 design; not reconciled here.)
  One violation per offending node. Code `:no_default_route`. Message names the node id and kind:
  "Node '<id>' (EXCLUSIVE_GATEWAY) has no default outgoing edge (is_default: true); an instance whose
  conditions all evaluate false would stop with no matching route".

`validate_flow/1` list order: CHK-22, CHK-23, CHK-24.

`Violation.code()` union (`graph.ex:207-241`) gains three members: `:unreachable_node`,
`:no_path_to_end`, `:no_default_route`, plus the moduledoc section listing checks gains a "Flow checks
(CHK-22..CHK-24, REQ-455)" paragraph and the `validate_graph` moduledoc "Ordering contract" sentence names
`validate_flow/1`.

Interaction notes the build must not get wrong:

* A cycle that passes CHK-06 because it touches a gateway can still be a trap -- CHK-23 is what catches it.
* An island with no START reachability but with an END path is reported by CHK-22 only; an island with
  neither is reported by both. A node isolated per CHK-04 is also unreachable/unable-to-end and will be
  reported by CHK-22/23 as well -- accepted double report (checks are independent by the module's own
  invariant 5, `graph.ex:34-37`).
* Parallel fork/join graphs are plain graph reachability; no token semantics are modelled.
* SUB_PROCESS child graphs are separate definitions and are validated on their own create.

---

## 4. Check 3 -- data used before it is collected (`semantic_validation.ex`)

`SemanticValidation.validate/2` (`semantic_validation.ex:173-188`) keeps its signature
`validate(graph :: Graph.t(), declared_fields :: declared_fields()) :: Graph.result()` and gains a third
violation class, computed in the same pass and concatenated after the existing two. Because
`activate/2` and `validate_definition_graph/2` already call `validate/2`, no new wiring is needed for this
check. The existing empty-`declared_fields` early return (`semantic_validation.ex:174-176`) also silences
this class -- required for soundness, see below.

**What is and is not certain (the load-bearing definition).** Engine facts that bound the design:
* A SERVICE_TASK merges its entire decoded response body into the instance variables
  (`engine.ex:3394` `VariableMerge.merge(seed_state.variables, decoded_body, nil)`); a service
  node declares no output keys, so statically it can set any variable.
* A completing HUMAN_TASK merges the caller-supplied `output_variables` map unconstrained by its form
  (`engine.ex:2262-2335`); `form_schema` is "a rendering payload only" (`task_activation.ex:45`). The
  design-time intent of a form is its `properties` keys.
* A SUB_PROCESS with an `interface` merges only `interface.outputs` names to the parent
  (`engine/sub_process.ex:154-167` `build_parent_merge_variables/2`); without an `interface` it merges
  the whole child map.
* Instance start variables are an arbitrary map (`Engine.create/2`, `engine.ex:451-458`), validated only
  against a registered JSON Schema if one exists (`pin_resolver.ex:504-520`).

Therefore a variable is **certainly never set** at a given edge only under these three conjuncts, all of
which the new class requires:

1. `declared_fields` is non-empty (a registered `variable_schemas` contract exists; with no contract any
   start input is possible, so nothing is certain), AND the variable's root segment (`hd(path)`, same
   root-only rule as `field_existence_violations/3`) is **not** a key of `declared_fields` (declared
   variables are treated as possible start inputs).
2. The edge's source node is a HUMAN_TASK and the edge has a non-blank condition. (EXCLUSIVE_GATEWAY edges
   keep the existing, stricter `:undeclared_variable_reference`, which already fires regardless of
   writers; running the new class on them would double-report the same root cause.)
3. No node in the **ancestor-or-self set** of the edge's source -- every node from which the source is
   reachable by following edges forward, plus the source itself, i.e. every node on any path
   START -> source -- "may write" the variable, where:
   * SERVICE_TASK: always may write (opaque response body).
   * HUMAN_TASK: may write iff it has no usable `form_schema` `properties` map (open) OR the root is one
     of the `properties` keys. The **source** HUMAN_TASK counts (its own completion writes before its
     edges are evaluated).
   * SUB_PROCESS: may write iff it has no parseable `interface` (open) OR the root is one of
     `interface.outputs` names (via `SubProcessInterface.parse_interface/2`,
     `sub_process_interface.ex:91-93`, outputs entries `%{name:, json_schema:, required:}`).
   * START, END, TIMER, EXCLUSIVE_GATEWAY, PARALLEL_GATEWAY: never write.

If all hold, the condition names a variable no declared start input, form field, service response (none on
the path) or sub-process output on any path can supply -> violation. If any path-node is an open writer,
or declares the variable, the case is **not** reported (that is the PROCESS-AUDITOR judgment of REQ-456,
by the requirement's own rule: "report only the case where no path sets it").

New violation code `:variable_never_collected`. One violation per (edge, variable root) occurrence,
mirroring `field_existence_violations/3` ("N occurrences -> N violations", `semantic_validation.ex:352-354`).
Message: "Edge '<edge id>' (from HUMAN_TASK node '<source id>') condition reads variable '<root>' that no
declared field, form, service step or sub-process output on any path from START can set; rule as authored:
\"<condition>\"". Defensive skip of an edge whose condition fails to parse stays as in `edge_violations/2`.

Private additions in `semantic_validation.ex` (names fixed so tests and reviewers can find them):
`data_flow_violations/3`, `ancestors_or_self/3` (pure reverse reachability over resolved edges),
`may_write?/3`. New dependency: `Letflow.Definitions.SubProcessInterface` (pure leaf, already used by
`graph.ex:872`), no cycle introduced. `SemanticValidation`'s moduledoc gains a "Data-flow class (REQ-455)"
section and its "HUMAN_TASK ... OUT OF SCOPE" section is amended to say HUMAN_TASK edge conditions are
covered by this class only.

Honest limit, recorded for ORCH (OQ-3): with the engine facts above, this class will fire rarely
(HUMAN_TASK-sourced conditions on an undeclared variable, with a schema registered, and no open writer
upstream). It is the strongest rule that stays "certain" on this engine. A stricter rule (forms/outputs
authoritative) would be unsound because the engine accepts extra keys.

---

## 5. Check 4 -- unbound task roles at install (new module `Letflow.Definitions.RoleBinding`)

New file `lib/letflow/definitions/role_binding.ex`, a small module with a pure core and one impure edge:

* `task_roles(graph :: Graph.t()) :: [task_role()]` -- pure. `task_role() :: %{role_name: String.t(),
  node_ids: [String.t()]}`. Collects, for every HUMAN_TASK node, `attributes["role"]` and
  `attributes["escalation_role"]` when each is a non-blank binary (used raw, **not** trimmed -- matches
  `TaskActivation` which reads `Map.get(attributes, "role")`, `task_activation.ex:158`, and the exact-name
  unique index on `tenant_role.name`). Grouped by role name; `role_name` sorted ascending, `node_ids`
  sorted ascending, deduplicated.
* `unbound(task_roles :: [task_role()], bound_names :: MapSet.t(String.t())) :: [task_role()]` -- pure
  filter, order preserved.
* `bound_role_names(opts :: [prefix: String.t()]) :: MapSet.t(String.t())` -- the only impure function: one
  `Letflow.Identity.RoleRegistry.list_roles/1` call (`role_registry.ex:44-47`, already prefix-scoped,
  `Repo.all(... prefix: prefix)`), projected to names. "Bound" = a `tenant_role` row exists with that exact
  name in this tenant's schema, **any `kind`** (platform or process-routing -- `resolve_role_in_tx/1`
  resolves by name only, `role_registry.ex:210-216`).
* `format_warning(definition_name :: String.t(), task_role :: task_role()) :: String.t()` -- the single
  place the wire text is built: `"unbound_task_role: <role_name> (definition '<definition_name>', nodes:
  <id1>, <id2>)"`. Stable `unbound_task_role:` prefix so callers can filter.
* `warnings_for_definitions(definitions :: [{definition_name :: String.t(), Graph.t()}], opts ::
  [prefix: String.t()]) :: [String.t()]` -- convenience that does the single `bound_role_names/1` read,
  then per definition (input order) `task_roles |> unbound |> format_warning`. Returns `[]` if no human
  task routes to an unbound role. Never raises on a graph that failed `from_map` -- the caller passes only
  parsed graphs.

**No binding is ever created.** The module imports no write function; the test asserts the
`tenant_role` row count is identical before and after (AC4). Decision 0029 section 2 and the existing
`role_mapping_checklist` are untouched and remain advisory.

**Warning shape (decision, additive only):**

| Surface | Change | Shape |
|---|---|---|
| `SolutionPack.install/3` result (`install_result()` type, `solution_pack.ex:264-273`) | **none to the type**: the existing `warnings: [String.t()]` list receives the new lines, appended after the variable-schema warnings produced by `register_packed_schemas/3` (`solution_pack.ex:1375`) | strings from `format_warning/2` |
| `POST /solution-packs/install` response | **none to the router**: `install_result_map/1` already emits `"warnings" => result.warnings` (`routers/solution_packs.ex:866`) | JSON array of strings |
| `Definitions.graph_validation_result()` (type at `definitions.ex:1207`) | additive key `warnings: [String.t()]` (always present, `[]` when none) | strings from `format_warning/2` |
| `POST /definitions/:id/validate` 200 (valid) body (`render_validation/2`, `routers/definitions.ex:356`) | additive key `"warnings"` next to `"findings"` | JSON array of strings |
| `POST /definitions/:id/validate` 422 (invalid) | none -- the RFC-style `Error` struct has no slot for it; violations take priority and warnings are not repeated | -- |
| `POST /definitions/:id/activate` response | **none** -- it returns `definition_map/1` (a stored-record allowlist); adding a field would change a record shape. Warnings are surfaced by validate and by pack install (OQ-4) | -- |

Install placement: inside `run_install/5`'s transaction after `create_packed_definitions/3` succeeds and
the schemas are registered, compute the warnings from each created definition's `graph` map
(`Graph.from_map/1`, skip the entry on `:error`, which cannot happen after a successful create) with
`opts` the install's own prefix-bearing `opts`; one `list_roles` query per install. It reads inside the
transaction, so a role bound by a concurrent request after the read is not seen -- acceptable for an
advisory list (stated, not hidden).

`Definitions.validate_definition_graph/2` adds a third query (`bound_role_names/1`); its docstring
("Issues exactly two queries", `definitions.ex:1256`) and the router moduledoc are updated to say three.
No test asserts the query count (grep of `test/` for query-count assertions on this function: none).

---

## 6. Schema / DB / state

No migration, no Ecto schema change, no new table, column, index or constraint. No gen_statem or process
state. `Violation` struct unchanged (`code` union extended only). The `tenant_role` table is read, never
written.

---

## 7. Shipped definitions -- inventory, discovery, and results

**Inventory (every process definition shipped in the repository or seeded by `scripts/`).** Searched
`priv/`, `scripts/`, `test/fixtures/`, `lib/` (`grep node_type|EXCLUSIVE_GATEWAY` over `lib/` and
`priv/` outside the engine/graph code finds no embedded graph) and the three seed-adjacent mix tasks
(`lib/mix/tasks/letflow.seed*.ex` seed no definition graphs).

| Group | Files | Count |
|---|---|---|
| QA fixtures POSTed by `scripts/seed_{meridian,swiftroute,vortex}_definition.sh` (`seed_meridian_definition.sh:161,167`, `seed_swiftroute_definition.sh:62`, `seed_vortex_definition.sh:167,173,179`) | `test/fixtures/qa/{meridian_loan_origination,meridian_regulatory_compliance_review,swiftroute,vortex_8d_corrective_action,vortex_production_order_release,vortex_supplier_quality_deviation}*_definition.json` | 6 |
| Simulation fixtures created through `Support.Simulation.Seed.seed_process/3` -> `Definitions.create/2` (`test/support/simulation/seed.ex:314-350`) | `test/fixtures/simulation/{meridian,swiftroute,vortex}/process_*.yaml` | 6 |
| Solution-pack documents with a `definitions` list | `priv/modules/exam/pack.json` (`definitions: []`, verified empty) | 0 graphs |
| Module solution manifests | `priv/solutions/bilimbaga.json`, `priv/solutions/fixture-bundle.json` (keys `id`, `modules` only, no graphs) | 0 graphs |
| Non-definition JSON that merely mentions node types | `test/fixtures/canonical_json/golden_cases.json`, `test/fixtures/simulation/differential_corpus.json` | excluded, not definitions |

Inline graphs in `test/**/*.exs` are test data, not shipped definitions; they are covered by running the
affected suites (section 8).

**How the all-shipped-definitions test finds them (must not be a hand list, or a new fixture is silently
missed).** Test file `test/letflow/definitions/shipped_definitions_validation_test.exs`:
discovery = `Path.wildcard` over `priv/**/*.json`, `test/fixtures/qa/*.json`, `test/fixtures/simulation/**/process_*.yaml`
(YAML via the already-present `yaml_elixir`, test/dev dep, `mix.exs:64`); a document is a definition iff its
decoded form has a `"graph"` map with `"nodes"` and `"edges"` lists (QA/simulation shape) or a
`"definitions"` list whose entries have such a `"graph"` (pack shape). A second assertion in the same
file greps every `scripts/seed_*_definition.sh` for `test/fixtures/...json` path literals and asserts each
referenced file was discovered (so a seeded fixture can never fall outside coverage), and asserts the
discovered count is at least 12 (guards against the wildcard silently matching nothing). Each discovered
graph goes through `Graph.from_map/1` then all four graph validators plus a hand-built empty-schema
`SemanticValidation.validate/2`, asserting `[]` violations per file with the file path in the failure
message.

**Result of running the existing validator (probe, `mix run --no-start`, dev):** all 12 graphs return
**0** violations from `validate_graph/1` + `validate_node_attributes/1` + `validate_edge_conditions/1`
today. HUMAN_TASK roles in them are `role-*` names (e.g. `role-ceo`, `role-ops-manager`), none of which
a freshly provisioned tenant has bound -> check 4 will list them (expected, advisory).

**Result against the new checks (prototype of the algorithms in section 3, run over the same 12 graphs):**
CHK-22 and CHK-23 -> 0 findings. Check 3 -> inert (no shipped definition registers `variable_schemas`:
grep of `scripts/`, QA fixtures and simulation YAML finds none; `declared_fields == %{}` is exempt).
**CHK-24 -> 11 of 12 graphs FAIL** (only `vortex_8d_corrective_action` has no EXCLUSIVE_GATEWAY).
Exact findings (definition / gateway, all `:no_default_route`):

| Definition (file) | Gateway node(s) lacking a default |
|---|---|
| QA `meridian_loan_origination` v1.3 | `eligibility-gate`, `authority-routing` (`kyc-routing` and `committee-tally` already have defaults -- ISS-0928 fix) |
| QA `meridian_regulatory_compliance_review` v1.3 | `severity-routing`, `post-remediation-check` |
| QA `swiftroute` v1.1 | `ceo-approval-gate` |
| QA `vortex_production_order_release` v1.1 | `budget-gate` |
| QA `vortex_supplier_quality_deviation` v1.2 | `false-positive-check`, `severity-routing` |
| sim `meridian/process_claim_intake.yaml` | `kyc-routing`, `eligibility-gate`, `authority-routing` |
| sim `meridian/process_policy_binding.yaml` | `severity-routing`, `post-remediation-check` |
| sim `swiftroute/process_route_approval.yaml` | `ceo-approval-gate` |
| sim `swiftroute/process_shipment_dispatch.yaml` | `injury-check` |
| sim `vortex/process_quality_check.yaml` | `budget-gate` |
| sim `vortex/process_work_order.yaml` | `false-positive-check`, `severity-routing` |

**Disposition (the check is not weakened).** These fixtures are loaded through `Definitions.create/2`
(simulation seed, `scripts/seed_*_definition.sh` -> `POST /definitions`), which will start rejecting them
the moment `validate_flow/1` is wired in -- leaving them unfixed would break the seed scripts and the
simulation/QA test suites, so they are **fixed in the same change** following the ISS-0928 precedent
(`docs/issues/ISS-0928.yaml` resolution item 3: a new `...-default` edge, version bump): for each flagged
gateway add one edge `<gateway>-default` with `is_default: true`, no condition. Proposed targets
(business-safe, i.e. the more cautious branch; **business confirmation is required**, so ORCH files ONE
issue naming every row below, owner BA, in addition to the in-change fix):

| Gateway | Proposed default target |
|---|---|
| meridian `eligibility-gate` | `decline-application` |
| meridian `authority-routing` | `committee-vote-fork` |
| meridian `kyc-routing` (sim yaml only) | `assessment-join` (identical to the QA fixture's existing ISS-0928 default `e9-default`, for parity) |
| meridian `severity-routing` | `remediation-subprocess` |
| meridian `post-remediation-check` | `remediation-unresolved-escalation` |
| swiftroute `ceo-approval-gate` | `ceo-approval` |
| swiftroute `injury-check` | `safety-notification` |
| vortex `budget-gate` | `budget-approval` |
| vortex `false-positive-check` | `severity-routing` |
| vortex `severity-routing` | `corrective-action-subprocess` |

QA JSON files get a version bump (patch, as ISS-0928 did 1.1 -> 1.2) because `(name, version)` is unique
(`uq_definition_version`) and a re-seed of an existing environment must create a new row; ELIXIR-DEV
greps for tests pinning those versions (e.g. `meridian_loan_origination_fixture_test.exs`) and updates
them in the same change. Simulation YAML versions are left alone unless a test pins them. Scenario YAML
under `test/fixtures/simulation/**/scenarios/` and `test/fixtures/uat/**` assert business outcomes, not
edge counts; ELIXIR-DEV runs the simulation and fixture suites (section 8) to confirm no scenario relied
on the old `no_matching_edge` error path.

No definition fails CHK-22, CHK-23, or check 3, so there is nothing to report to ORCH for those. If, while
building, a fixture turns out to need a *business* decision that the table above cannot supply
(ambiguous exhaustiveness), ELIXIR-DEV stops and reports it to ORCH as an issue naming the definition and
node, and does not weaken CHK-24.

---

## 8. Files to touch (complete list)

Production code:
1. `lib/letflow/definitions/graph.ex` -- `validate_flow/1`, CHK-22..24, 3 new `Violation.code` members, moduledoc.
2. `lib/letflow/definitions/semantic_validation.ex` -- data-flow class, `:variable_never_collected`, moduledoc. (The code union lives in `graph.ex`; add `:variable_never_collected` there too, file 1.)
3. `lib/letflow/definitions/role_binding.ex` -- **new**.
4. `lib/letflow/definitions.ex` -- `create/2` (`:557-559`), `validate_update_graph/1` (`:1664-1672`), `validate_definition_graph/2` (`:1266-1285`, type `:1207`), `run_semantic_validation/2` (`:2360-2385`) and the comment at `:2343-2352`; docstring query count.
5. `lib/letflow/definitions/solution_pack.ex` -- `run_install/5` appends role-binding warnings; moduledoc "install" step 8 sentence.
6. `lib/letflow/routers/definitions.ex` -- `render_validation/2` valid clause adds `"warnings"`; moduledoc table row.

Fixtures (section 7 dispositions): the 5 QA JSON files that fail, the 6 simulation YAML files that fail
(11 total; `vortex_8d_corrective_action_definition.json` unchanged); `scripts/seed_meridian_definition.sh`
header comment (version mention) only if it names a bumped version.

Tests:
7. `test/letflow/definitions/graph_test.exs` -- new `describe` blocks for CHK-22/23/24 (or a new sibling file `test/letflow/definitions/graph_flow_test.exs`, preferred to keep the 1,300-line file's existing tests untouched).
8. `test/letflow/definitions/semantic_validation_test.exs` -- data-flow class tests.
9. `test/letflow/definitions/role_binding_test.exs` -- **new**, pure-function tests.
10. `test/letflow/definitions/role_binding_install_test.exs` -- **new**, DB-backed (install + `tenant_role` count) using the same `provisioned_tenant` pattern as `semantic_validation_activation_test.exs`.
11. `test/letflow/definitions/semantic_validation_activation_test.exs` -- activate refuses a stored DRAFT with a dead end / missing default; validate result carries `warnings`.
12. `test/letflow/definitions/shipped_definitions_validation_test.exs` -- **new** (section 7).
13. Existing suites that build gateway graphs without a default and go through `Definitions.create/activate` or the simulation seed and must be run, and fixed where they fail (add a default edge to the test graph; never relax the check): `test/letflow/definitions/` (store_test, solution_pack_test, export_import_test, promotion*_test, rollback_test, search*_test, snapshot_store_test, semantic_validation_activation_test), `test/letflow/engine/` and `test/letflow/engine_*_test.exs` gateway tests (candidates found by `grep -l EXCLUSIVE_GATEWAY` with no `is_default`: `engine/parallel_gateway_test.exs`, `engine/variable_merge_test.exs`, `engine_execution_error_test.exs`; the other 49 files that mention EXCLUSIVE_GATEWAY must be checked, since a file that has *some* `is_default` can still hold a default-less gateway), `test/letflow/routers/definitions*_test.exs`, `test/letflow/simulation/` (req206/207/208 + runner), `test/letflow/scripts/*fixture*_test.exs`. ELIXIR-DEV runs these scoped, one directory at a time, with a unique `MIX_TEST_PARTITION` (RAM is tight).

Docs: `docs/anti-patterns.md` entry only if the build hits a new mistake; DOC-UPDATER handles `docs/requirements.yaml` -- not touched here.

**Overlap check (kept surgical).** Open PRs #2254 (REQ-444: `login_discovery`, `config/runtime.exs`, `docs/requirements.yaml`, status v26/index), #2228, #2249 (`ci.yml`) and the sibling worktrees (`login_directory`, identity, routers) touch none of files 1-12 above, **except** `lib/letflow/routers/definitions.ex` (file 6): the sibling worktrees' "routers" work is a possible overlap -- ELIXIR-DEV runs the overlap check from `docs/rules` against open PRs before editing it, and the edit is a single clause in `render_validation/2` plus one docs row. This design does not touch `docs/requirements.yaml`, `config/`, `ci.yml`, or any identity/login file.

---

## 9. Acceptance-criterion mapping

| AC | Design element | Test (name stem) |
|---|---|---|
| Each candidate listed exists / partly / missing with file:line, re-verifiable | Section 0 table; probe scripts are re-runnable (graph literals described in section 0) | CODE-DESIGN-VALIDATOR re-checks the cited lines |
| Per built check: one test with a minimal violating definition asserting code AND offending node/edge id; one valid-neighbour test | CHK-22 `:unreachable_node` (minimal graph: `start->end`, plus gateways `x`,`y` with `x->y`, `y->x`, `x->end` default so only unreachability fires; assert node ids `x`,`y`); CHK-23 `:no_path_to_end` (`start->g`, `g->end` conditional, `g->h` default, `h->k`, `k->h` default; assert `h`,`k`); CHK-24 `:no_default_route` (gateway with two conditional edges; assert gateway id); check 3 `:variable_never_collected` (declared `{a}`, HUMAN_TASK `t` with conditional edge reading `ghost`, no writer upstream; assert edge id and `ghost`); each with a valid neighbour (fully connected start->end; gateway with a default; same human-task condition reading a variable declared / written by the task's own form `properties` / written by an upstream SERVICE_TASK) | `graph_flow_test.exs`, `semantic_validation_test.exs` |
| ISS-0928 shape rejected at validation, with a test | Gateway shape: `Definitions.create/2` returns `{:error, {:graph_validation_failed, vs}}` containing `:no_default_route` naming the gateway (earlier phases pass, so the flow phase is the one that reports). Service-task shape: `Graph.validate_edge_conditions/1` -> `:unexpected_edge_condition` x2 and `Graph.validate_flow/1` -> `:no_default_route` naming the task; `Definitions.create/2` rejects it. | `graph_flow_test.exs`, `store_test.exs` or the new activation file |
| Check 4: unbound role named in the warning list; nothing bound (tenant_role count unchanged) | Section 5. Install a pack whose HUMAN_TASK routes to `role-unbound-x`; assert `"role-unbound-x"` appears in `result.warnings` (and the HTTP body's `"warnings"`), a bound role (pre-inserted via `RoleRegistry.upsert_role/4`) does not, and `Repo.aggregate(TenantRole, :count, prefix: ...)` is equal before and after. | `role_binding_install_test.exs` |
| Every shipped / seeded definition is run through the validator in a test; each failure fixed or filed and named | Section 7 (12 graphs; fixes in-change for the 11 failing; one BA-owned issue filed by ORCH naming the table rows) | `shipped_definitions_validation_test.exs` |
| `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix test`, `mix letflow.check_boundaries` pass with real output | New module `Letflow.Definitions.RoleBinding` references `Letflow.Identity.RoleRegistry`; `solution_pack.ex` already references `Letflow.Api.Authorization` and `Letflow.Identity.*`, and the boundary task checks only `lib/letflow/modules/<id>/` edges (rules 0-5), so no boundary rule is engaged. ELIXIR-DEV quotes the real output. | CI / TEST-RUNNER |

---

## 10. Security invariants assessment (INV-1..INV-10)

* **Routes / permissions / response shapes touched:** no new route, no new permission, no permission
  reclassification. One existing response gains an additive field: `POST /definitions/:id/validate` 200
  body (`:DefinitionsRead`) gains `"warnings"`. `POST /solution-packs/install` (`:DefinitionsCreate`)
  already returns `"warnings"` -- its content grows, its shape does not. `POST /definitions/:id/activate`
  response unchanged.
* **INV-1:** applies, satisfied -- `bound_role_names/1` reads through `RoleRegistry.list_roles/1`, which
  is `prefix`-scoped; `opts[:prefix]` is derived from the token's tenant by the existing routers
  (`Api.Context.scoped_repo_opts/1`), never caller-supplied. No new table.
* **INV-2:** applies, satisfied -- warnings are built from two inputs only: the caller's own definition
  graph (role names, node ids it already authored) and a membership test against the caller's own
  tenant's `tenant_role` names. No group id, member, user or other tenant's data is emitted. Disclosure
  note for SECURITY-REVIEWER: `validate` needs only `:DefinitionsRead`, while listing roles needs
  `:RolesManage` (`routers/identity.ex:219`); a read-only caller can learn "role X is/is not bound" only
  for names present in a definition it can already read. Judged low sensitivity, flagged (OQ-5).
* **INV-3, INV-4, INV-9:** not applicable (no Lua/WASM host function, no secret, no outbound URL).
* **INV-5:** unchanged -- not-found collapse in `validate_definition_graph/2` and `render_validation/2` is
  untouched; the new query runs only after `get_by_id/2` succeeded.
* **INV-6:** this design is the scoping statement for the one new data-access path (the `list_roles` read).
* **INV-7:** applies, satisfied -- no SQL string interpolation; Ecto query already composed with bound
  parameters in `list_roles/1`.
* **INV-8:** applies -- `task_roles/1`, `validate_flow/1` and the data-flow class are total on malformed
  attributes (non-map `attributes`, non-binary `role`, dangling edges); `warnings_for_definitions/2`
  skips a graph that fails `from_map`; a DB failure in `list_roles` raises as it does for every other
  context read in this module (same behaviour as `VariableSchema.fetch_schemas/3` at activate) -- not
  swallowed.
* **INV-10:** route group touched is tenant-scope only (definitions / solution packs); no platform-scope
  action added; no tenant identifier read from path/query/body.

Anti-patterns consulted (`docs/anti-patterns.md`): type-table-vs-error-map drift (no new error tuple
introduced, so no new `render_*` clause owed); "A conservative skip-and-warn branch can look like
complete coverage" (`:4604`) -- check 4 is deliberately a *warning* by the requirement and Decision 0029,
and the design states in OQ-4 which surfaces it does and does not reach so the warning is not mistaken
for enforcement; "A new tenant-scoped migration's tables..." (`:2186`) -- not applicable, no migration.

---

## 11. Open questions (none resolved silently; each has the default this design builds)

* **OQ-1 (from the requirement).** A definition already ACTIVE that fails a new check keeps running; the
  new checks apply at validate, create/update/import/install and activate-of-a-DRAFT time only; nothing is
  deactivated. **Default built: as stated.** Note `validate_definition_graph/2` on such a definition will
  now report the new violations (read-only).
* **OQ-2. CHK-24 on exclusive gateways whose conditions are exhaustive** (`x <= 500` / `x > 500`) forces a
  default edge anyway. **Default built: yes, violation** -- the requirement says "has no is_default edge"
  with no exhaustiveness exemption, and exhaustiveness is undecidable in general; this costs the 11
  fixture fixes in section 7.
* **OQ-3. Check 3 strength.** Built as the sound-but-narrow rule in section 4 (HUMAN_TASK-sourced edges
  only; declared fields treated as possible start inputs; forms/sub-process interfaces treated as the
  authoritative writers although the engine accepts extra keys). Alternative if ORCH wants more firing:
  extend to EXCLUSIVE_GATEWAY edges' *declared-but-never-written* variables, which is NOT sound (a
  declared field may be a start input). **Default built: narrow.**
* **OQ-4. Which surfaces carry the check-4 warning.** Built: `validate` 200 body and the pack-install
  response. Not built: `activate` response (record-shaped), `ExportImport.import` response, and the
  module-install wrapper `Modules.Installs.install/3` (`modules/installs.ex:73-88`), which runs
  `maybe_install_pack/3` inside its own transaction and returns only the `tenant_module` row -- the pack
  install result (and therefore its `warnings`) is discarded there, so a module-owned pack installed via
  the module route will compute but not show the check-4 warning. Reported, not extended: surfacing it
  needs a response-shape change on the modules route, which this requirement does not authorize.
* **OQ-5. Role-existence disclosure to `:DefinitionsRead`** (section 10). **Default built: disclose** (it
  is exactly the validation-result warning the requirement asks for). SECURITY-REVIEWER may require
  gating the warning on `:RolesManage`.
* **OQ-6. `escalation_role` counted as a routed role.** **Default built: yes** (a human task escalates to
  it; CHK-21 co-requires it). Drop it from `task_roles/1` if ORCH reads "role a human task routes to" as
  `attributes["role"]` only.
* **OQ-7. Warning text vs structured entries.** Built as strings (fits the existing
  `warnings: [String.t()]` without a type change). A structured `%{code, role_name, node_ids}` list would
  need a new additive key on both responses.
* **OQ-8. Existing `role_mapping_checklist.bound`** compares `manifest.required_roles` to the static
  platform-role atoms, not to `tenant_role` rows, so it reports `bound: false` for tenant-routing roles
  that are in fact bound. Pre-existing, outside REQ-455, **not changed**; recorded as a finding.
* **OQ-9. Fixture default targets** in section 7 are engineering proposals pending BA confirmation.
