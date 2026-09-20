# GUI review: platform-definition-type-error-blocked

**Date:** 2026-09-20
**Agent:** ORCH
**Scenario:** `test/fixtures/uat/scenarios/platform/definition-type-error-blocked.yaml` (PW-02)
**Outcome:** BLOCKED / UNBUILT_FEATURE (backend leg — feature does not exist, in whole or in
part). Fourth scenario in today's systematic GUI-review sweep (see the earlier
`gui-review-2026-09-20-*.md` reports for prior findings: REQ-371, ISS-0732/0733/0734/0735,
and the definition-promotion-rollback precedent this report follows the same shape as).

## Process followed

Per this run's instruction, the scenario's own stale `NOTE (ISS-0527)` — which already
predicts BLOCKED/UNBUILT_FEATURE — was **not** trusted at face value. Verified independently
by reading current source before concluding anything:

- `lib/letflow/design/req028-graph-structural-validator.md`,
  `req029-node-attribute-edge-condition-validators.md` — structural graph/edge/node-attribute
  checks (`Letflow.Definitions.Graph.validate_graph/1`, `validate_node_attributes/1`,
  `validate_edge_conditions/1`). All purely structural/syntactic; `valid_cel_syntax?/1`'s own
  docstring (superseded by REQ-288) states it "performs no evaluation... never resolves
  variable names."
- `docs/requirements.yaml` REQ-288 (done) — routes edge-condition checking through
  `Letflow.Engine.Expr.parse_strict/1` for real CEL **grammar** validity. Explicitly scoped
  to syntax only, not name resolution.
- `docs/requirements.yaml` REQ-291 (done) — the only place in the repo that checks an
  authored expression's variable references against declared fields. Scoped to the **x-ui
  form-field vocabulary only** (`visible_when`/`computed`/cross-field validation on rendered
  form fields), not to `EXCLUSIVE_GATEWAY` edge conditions or any task-routing/assignment
  rule.
- `lib/letflow/engine/variable_schema.ex` (REQ-109) — declared process fields exist and are
  typed, but grepping `lib/` for any caller that cross-references an edge-condition or
  routing-rule expression's variable names against `VariableSchema` returns zero hits outside
  REQ-291's form-field path.
- `lib/letflow/definitions/graph.ex` CHK-09 (`check_human_task_role/1`) — a `HUMAN_TASK`'s
  `"role"` attribute must be a non-blank **string**, not an expression. There is no code path
  today for a human-task assignment rule to reference a process field at all, so the
  scenario's "routes to a reviewer using a field the process does not hold" case cannot occur
  in the current model.
- `lib/letflow/engine/expr.ex` — the CEL-subset grammar is untyped; nothing anywhere compares
  the declared types of two expression operands (the scenario's "compares the money amount
  against the customer's name" case).
- `web/src/pages/definitions/DefinitionEditorPage.tsx`,
  `web/src/components/canvas/ValidationSummaryBar.tsx` — the presentation plumbing is real
  and generic (`{nodeId|edgeId, message, severity}` renders correctly; per-node canvas
  annotations already exist for `SUB_PROCESS` interface errors, REQ-032), but nothing feeds
  it a field-existence or type-mismatch violation today.
- Grepped `lib/` and `web/src` for "did you mean"/Levenshtein/nearest-field suggestion logic
  (EO-003's requirement) — no hits anywhere.
- Confirmed `web/tests/e2e/pipelines/platform-definition-type-error-blocked.pipeline.e2e.spec.ts`
  does not exist on disk, matching the scenario's own NOTE.

**No qa.bizdala.com session was driven** — per the process rules, live-driving the scenario
only applies once the feature is confirmed to exist at least partially. It does not: there is
no field-existence check, no type-compatibility check, no misspelling suggestion, and no
mechanism for a human-task rule to reference a field at all. This is a legitimate BLOCKED
outcome, not a shortcut — a large, genuinely unbuilt semantic-validation feature, not a UI
gap on top of an existing backend (contrast with the definition-promotion-rollback scenario
reviewed earlier today, where the backend was fully built and only the frontend was missing).

## Screens reviewed

None — no build to exercise. The process editor (`DefinitionEditorPage.tsx`) and its
validation summary bar were read as source, not screenshotted, since there is no semantic
violation this feature could ever produce today to screenshot.

## Filed

`docs/requirements.yaml` **REQ-372** (owner ELIXIR-DEV, stage S8, status `pending`,
`depends_on: [REQ-109, REQ-288, REQ-291]`) — backend semantic decision-rule validation:
field-existence checking with a real string-distance suggestion, and type-compatibility
checking between two expression operands' declared `VariableSchema` types, both re-run in
full at release/promotion submission time. Explicitly scoped as the backend half; a follow-on
FRONTEND-DEV requirement (canvas problem markers, problem-list UI, release-submission
re-check screen) is named as a deliberate next step once REQ-372 lands — same two-step shape
`REQ-288` → `REQ-291` already established for this exact validate-at-authoring-time pattern.
REQ-372 also explicitly flags, for its own CODE-DESIGNER, the open question of whether a
HUMAN_TASK routing/assignment-by-field mechanism is in scope or is its own prerequisite gap,
rather than silently assuming either way.

## Fixed

Nothing — no real small defect was found; the finding is an entire missing feature, correctly
routed to REQ-ANALYST-quality filing rather than an ad hoc fix.

## Spec

Not authored. `pipeline_test` remains unimplementable until REQ-372 (and its frontend
follow-on) land; the scenario's stale `NOTE (ISS-0527)` should be revisited once REQ-372's
follow-on frontend requirement is filed and closed, at which point the correct action is to
update the NOTE to point at whichever requirement finally closes this gap, author the named
Playwright spec against the real feature, and run it for real — not before.
