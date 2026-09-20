# GUI review: `swiftroute/shipment-high-value-happy` (PW-16)

**Date:** 2026-09-20
**Reviewer:** ORCH (this GUI-review sweep, 16th of 18 scenarios)
**Scenario:** `test/fixtures/uat/scenarios/swiftroute/shipment-high-value-happy.yaml`
**Result:** BLOCKED — two independent, real provisioning gaps prevent driving
this scenario against `https://qa.bizdala.com` today, even though the
backend engine capability it needs is genuinely built and already proven.
One real, small, unrelated frontend defect was found and fixed along the
way.

## Path taken

Per this sweep's standing rule ("check whether the feature exists before
assuming anything"), read the scenario in full (steps 1-3, EO-001 through
EO-004) and traced every claim against current source rather than the
scenario's own prose, before touching `qa.bizdala.com`.

## What the scenario needs vs. what exists today

### The engine capability — real and proven

`test/fixtures/simulation/swiftroute/process_route_approval.yaml` ("Shipment
Approval") is exactly the graph this scenario describes: `ops-review`
HUMAN_TASK (`role: role-ops-manager`) → `ceo-approval-gate` EXCLUSIVE_GATEWAY
with a CEL condition `declared_value > 500` → conditional `ceo-approval`
HUMAN_TASK (`role: role-ceo`) → `release-shipment`. `test/letflow/simulation/
req206_swiftroute_test.exs` (REQ-206, done 2026-09-01) already proves this
end-to-end against a real `Engine.create/2` call: a declared_value: 750
instance correctly reaches `ceo-approval`, not a direct auto-release. So
`Letflow.Engine`'s sequential-chain + CEL-gate capability is not the gap —
it is shipped and already regression-tested.

### Gap 1 — the definition is not deployed anywhere reachable

`process_route_approval.yaml` is consumed only as an in-memory fixture by
`Letflow.Simulation.Runner.run/1` during automated test/CI runs — it is
provisioned fresh and torn down inside that harness. It is not persisted as
a live `ProcessDefinition` row for any real `swiftroute` tenant that a
person (or an agent driving a real browser) could open in the
definition-list screen or submit an instance against through the ordinary
API/GUI on `qa.bizdala.com`. Grepped `priv/` for any swiftroute seed data —
zero hits.

### Gap 2 — no real login for this scenario's actors

`ai-dala-infra/scripts/qa-login.sh` (the credential source
`.claude/agents/uat-runner.md` names for resolving scenario actors) has
exactly six seeded usernames, all generic platform roles: `admin-user`
(PLATFORM_ADMIN), `designer-user` (PROCESS_DESIGNER), `operator-user`
(PROCESS_OPERATOR), `worker-user` (TASK_WORKER), `candidate-user`
(CANDIDATE), `bilimbaga-admin-user` (PLATFORM_ADMIN). None of these
correspond to this scenario's dispatcher (`actor-swiftroute-lena`), ops
manager (`actor-swiftroute-marco`), or CEO (`actor-swiftroute-alice`), and
none carry a `role-ops-manager`/`role-ceo` claim. This is not new to this
scenario — two earlier reviews in this same sweep
(`gui-review-2026-09-20-tenant-branding-applied.md`,
`gui-review-2026-09-20-renderer-permission-denied-surface.md`) each
independently hit "No live sign-in as `actor-swiftroute-alice` /
`actor-swiftroute-marco`" and noted it locally without filing it. This is
the first review to file it centrally (`ISS-0739`).

Between gaps 1 and 2, there is no way to drive step 1 (dispatcher submits
via API against a real, live definition), let alone steps 2-3 (ops
manager/CEO GUI approval), against `qa.bizdala.com` today. No browser
session was opened and no screenshots were taken — matching this sweep's
"don't drive a flow that can only demonstrate an already-conclusively-known
gap" precedent (`renderer-permission-denied-surface`,
`shipment-attach-delivery-note`).

### Gap 3 (found, and fixed) — the generic Task Inbox discarded form input

While reading `web/src/pages/tasks/TaskInboxPage.tsx` to check whether the
*generic* task-completion screen an ops manager/CEO would use could even in
principle submit a decision value (`ops_decision: approve`,
`ceo_decision: approve`) if gaps 1-2 were resolved, found a real, unrelated,
pre-existing defect: `TaskDetailPanel`'s "Complete Task" button called
`complete.mutate({ id: taskId, body: { output_variables: {} } })`
unconditionally — the rendered `form-field-<name>` inputs for a task's
`form_schema` had no `value`/`onChange` wiring at all. Every keystroke typed
into a task's form was silently discarded; Complete Task always submitted
an empty variables object regardless of what the form showed. This affects
every decision-bearing HUMAN_TASK completion platform-wide, not only
SwiftRoute's — confirmed by reading the code directly, not inferred.

This is exactly the kind of small, self-contained, already-shipped-screen
defect this sweep's "fix real small defects found along the way" rule
covers, so it was fixed in this same pass rather than filed:

- `web/src/pages/tasks/TaskInboxPage.tsx`: `TaskDetailPanel` now holds a
  `formValues` state object, each rendered `form-field-<name>` input is a
  controlled input wired to it (text/number/boolean handled distinctly),
  and Complete Task now sends `output_variables: formValues` instead of
  `{}`. `TaskInboxPage`'s `<TaskDetailPanel key={selectedTaskId} .../>` now
  carries an explicit `key` so switching between two tasks' detail panels
  gets a fresh `formValues` state rather than carrying over the previous
  task's typed values.
- Verified: `npx tsc --noEmit` clean. Existing `web/tests/e2e/
  f4-task-inbox.e2e.spec.ts` assertions around `form-field-*`/
  `task-complete-button` only check visibility and that a POST to
  `/complete` fires — none assert on the previous (wrong) empty-object
  payload, so none needed updating and none broke.
- This does not by itself unblock the SwiftRoute scenario (gaps 1-2 still
  block it), but it removes what would otherwise have been a *third*,
  independent blocker once gaps 1-2 are resolved.

## Requirements/issues filed

- **`ISS-0739`** (MAJOR) — the credential-provisioning gap (Gap 2), filed
  centrally for the first time despite being hit three times today.
- **`REQ-395`** (owner ELIXIR-DEV, stage S7) — deploy a live, browsable
  `ProcessDefinition` matching `process_route_approval.yaml`'s graph for a
  real tenant on QA (Gap 1), depends on `ISS-0739` for exercisability,
  explicitly scopes out inventing new Keycloak identities (that's
  `ISS-0739`'s job).

## Not done in this pass

- No live sign-in as any of this scenario's actors, no screenshots — gaps 1
  and 2 make any such attempt purely demonstrative of an already-established
  fact, not new evidence.
- No Playwright spec authored, and no `pipeline_test:` key added to the
  scenario YAML — the scenario file had no `pipeline_test:` key to begin
  with, and authoring one now would be exactly the blind/aspirational spec
  this review process exists to avoid. It should be authored once `REQ-395`
  and `ISS-0739` both land, driving the real submit → ops-approve →
  ceo-co-sign → release chain end to end.
- The scenario file itself was left completely untouched — its own header
  forbids editing the ported content below it except to keep it
  byte-identical to a re-pull of the upstream R-Co commit, and it never had
  a `pipeline_test:` key or stale NOTE to remove.

## Cleanup

No instance or shipment was created against `https://qa.bizdala.com` during
this review (there was no live, reachable definition to submit one
against), so the scenario's own cleanup step (`cancel_open_instances`) has
nothing to act on.
