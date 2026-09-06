# REQ-206 — Run SwiftRoute's 4 simulation scenarios, extend Runner with SKIP/UNBUILT_FEATURE

**Requirement:** REQ-206. Second requirement of S7 (`docs/migration/stage-7-simulation-uat-parity.md`).
**Stage:** S7
**Owner (design):** CODE-DESIGNER — **Owner (implementation):** ELIXIR-DEV
**Depends on:** REQ-205 (`lib/letflow/design/req205-simulation-harness-foundation.md`,
`test/support/simulation/runner.ex`, `test/support/simulation/seed.ex`)

**Scope discipline** (mirrors REQ-205's own): this requirement runs scenario content
through the existing harness and extends the harness's disposition vocabulary by
exactly the two dispositions the four SwiftRoute scenarios force into existence. It
does **not** build `POST /api/v1/instances/:id/advance-timer`, does not build a
document/attachment subsystem, does not author `web/` Playwright specs, and does not
touch Vortex/Meridian (REQ-207/REQ-208).

---

## §0 — Verified source-of-truth facts (not assumed)

**R-Co access — genuinely unreachable, same as REQ-205's own session.**

```
ls "c:\Users\tvolo\dev\ai-dala\R-Co" -> No such file or directory (this session)
find / -maxdepth 3 -iname "*R-Co*" / "*ai-dala*" -> no checkout found (only an unrelated
  /app/ai-dala-news docker-compose tree, not the R-Co source repository)
```

**Correction (this rework, verified independently this session — see below):** an
earlier draft of this section claimed the company/org/process fixtures were *still*
synthetic and that no `ISS-0388` record existed in this repo. Both claims were wrong,
and this session re-verified the correction firsthand rather than taking ORCH's word
for it:

- `docs/issues/ISS-0388.yaml` **does exist** on this branch (present on `main` before
  this feature branch was even cut). Its `status` is `resolved`, and its `resolution`
  field states: fixed by a sibling session with genuine R-Co filesystem access
  (commit `f7ffbeb6`, PR #766, merged); all 12 fixture files under
  `test/fixtures/simulation/{swiftroute,vortex,meridian}/` were replaced with real
  content ported verbatim from R-Co's `tests/simulation/companies/` tree — real
  `display_name`s, all real people/`actor_id`s (7 swiftroute, 9 vortex, 10 meridian)
  matching R-Co's actual org structure, and real process graphs translated to
  Letflow-native format. `Letflow.Simulation.Seed`/`Runner` needed zero code changes.
- `git log -1 --format="%an <%ae>%n%s" f7ffbeb6` confirms the commit exists in this
  repo's history and is authored `Vladimir Titenko <tvolodi@gmail.com>` — the human
  user's own git identity (note "tvolo", the literal username in R-Co's own
  filesystem path `c:\Users\tvolo\dev\ai-dala\R-Co\` cited throughout this project),
  not any `Claude (letflow-workspace)` agent identity — a genuinely different signal
  from an agent fabricating provenance inside a sandbox, consistent with a sibling
  session running with real R-Co filesystem access.
- `git show f7ffbeb6 --stat` and the diff content of
  `test/fixtures/simulation/swiftroute/org_structure.yaml` confirm the commit message's
  specific, falsifiable claim: swiftroute's `org_structure.yaml` now lists exactly 7
  real-looking people (`actor-swiftroute-{alice,marco,lena,tobias,jan,petra,hans}`)
  under 4 groups, replacing what ISS-0388's own description calls a "2-person
  synthetic stub" — matching the "7 swiftroute, 9 vortex, 10 meridian" counts in both
  the commit message and ISS-0388's `resolution` field.

**Conclusion: REQ-205's company/org/process fixtures under
`test/fixtures/simulation/{swiftroute,vortex,meridian}/` are no longer synthetic —
ISS-0388 (a follow-up issue REQ-205's own RELEASE-VALIDATOR filed for exactly this
gap) got them replaced with real R-Co-ported content, on a different host/session
than the one that authored this design.** This does **not** extend to R-Co's real
`tests/simulation/scenarios/*.yaml` corpus — the 4 SwiftRoute *scenario* files this
requirement (REQ-206) itself needs are a different file set (scenario definitions,
not company/org/process fixtures) and remain independently verified unreachable from
*this* sandbox session:

```
ls "c:\Users\tvolo\dev\ai-dala\R-Co" -> No such file or directory (this session)
find / -maxdepth 3 -iname "*R-Co*" / "*ai-dala*" -> no checkout found (only an unrelated
  /app/ai-dala-news docker-compose tree, not the R-Co source repository)
```

**Conclusion for this requirement stands as before despite the §0 correction above:**
R-Co's real `tests/simulation/scenarios/*.yaml` corpus is unreachable from this
session. The 4 SwiftRoute scenario YAMLs this requirement needs must be
**self-authored synthetic fixtures**, structurally faithful to the requirement
description's own field-by-field account (step counts, `via` values, the EUR 750/500
threshold, the missing-endpoint note, the missing pipeline_test path) — the same
disposition REQ-205 originally established and disclosed for its own fixtures (before
ISS-0388 later fixed those), not a new compromise invented here. Every authored
scenario file carries a header comment stating this explicitly, matching the
company/org/process fixtures' original convention (now superseded for those files by
ISS-0388's real content, but still the right convention for content that is, in fact,
still synthetic).

**Recommendation — file a follow-up issue mirroring ISS-0388 exactly:** the same gap
ISS-0388 closed for the company/org/process fixtures still applies to this
requirement's 4 scenario YAML files. This design recommends ORCH file a follow-up
issue (same shape as `docs/issues/ISS-0388.yaml`: `discovered_by:
RELEASE-VALIDATOR`, `severity: BLOCKER` or `MAJOR`, `tags: [fixture-porting,
needs-r-co-access, s7]`, `affected_files` listing the 4 scenario YAMLs under
`test/fixtures/simulation/swiftroute/scenarios/`, `related: [REQ-206]`) at Step
6/Step Final of this run, so a future session/host with genuine R-Co filesystem
access can port the real
`tests/simulation/scenarios/{tenant-onboarding-happy,shipment-high-value-happy,
shipment-ops-timeout-escalation,shipment-attach-delivery-note}.yaml`-equivalent
content later, exactly as ISS-0388 did for the 12 company/org/process files.

**Real routes confirmed by reading `lib/letflow/plugs/api_pipeline.ex` and the routers
under `lib/letflow/routers/*.ex` this session** (mounted under `/api/v1` by
`Letflow.Plugs.ApiPipeline`):

| Path | Router | Relevant verbs |
|---|---|---|
| `/instances` | `Letflow.Routers.Instances` | `POST /` (start), `GET /:id`, `GET /:id/history`, `GET /` |
| `/tasks` | `Letflow.Routers.Tasks` | `GET /inbox`, `GET /:id`, `POST /:id/complete`, `POST /:id/claim`, `POST /:id/assign`, `POST /:id/reassign` |
| `/definitions` | `Letflow.Routers.Definitions` | (create/activate, per REQ-205 §0) |
| `/onboarding` | `Letflow.Routers.Onboarding` | `POST /`, `GET /:id`, `GET /?hostname=` |
| `/audit` | `Letflow.Routers.Audit` | (list entries, per REQ-205 §6) |
| `/identity` | `Letflow.Routers.Identity` | `POST /users`, `POST /groups`, `POST /groups/:id/members` |

**`advance-timer` endpoint — confirmed absent, independently, this session:**

```
grep -rn "advance-timer\|advance_timer" lib/letflow/router.ex lib/letflow/routers/*.ex
-> zero matches
```

This matches the requirement's own claim exactly. No `Letflow.Routers.Instances` route
of any name handles a timer-advance action, and no context function in
`lib/letflow/engine.ex`/`lib/letflow/instances.ex` (read this session) exposes one either.

PROVENANCE (historical, not current decision authority):
**Attachment/document-upload subsystem — confirmed absent, independently, this session:**
no route under any `lib/letflow/routers/*.ex` matches `attach`/`upload`/`document` in a
shipment or task context; `lib/letflow/router.ex`'s own reserved-slot inventory table
(§0 of REQ-205's design, reproduced above) lists no such slot either — this is not a
router awaiting a future stage's fill-in the way `Letflow.Routers.SimulationTest` is; it
is simply not on the platform's roadmap surface at all as of this session. R-Co's own
`src/` is unreachable (see above) so the requirement's `src/db/partition_attach.zig` /
`src/design/iss501_storage_mode_routing.md` citations cannot be independently re-checked
against R-Co's tree this session — they are taken as given from the requirement text
(both names are plainly storage/partition-routing concerns, not shipment-document
concerns, on their face) and restated, not re-verified byte-for-byte.

**Existing ported process fixtures already model two of these scenarios' processes,
confirmed by reading them this session** — no new process fixture is needed:

- `test/fixtures/simulation/swiftroute/process_route_approval.yaml` — "Shipment
  Approval": `start -> ops-review (HUMAN_TASK, role-ops-manager) ->
  ceo-approval-gate (EXCLUSIVE_GATEWAY) -> [ceo-approval (HUMAN_TASK, role-ceo) if
  declared_value > 500, else straight to release-shipment] -> release-shipment
  (SERVICE_TASK) -> end-approved`. This is **exactly**
  `swiftroute-shipment-high-value-happy`'s process — the EUR 500 CEO co-sign
  threshold is the literal condition on edge `e3`/`e4` (`variables.declared_value >
  500` / `<= 500`), REQ-050's exclusive-gateway CEL/expr dispatch (see §2 below).
- `test/fixtures/simulation/swiftroute/process_shipment_dispatch.yaml` — "Driver
  Incident Report" (filename kept for backward compat per its own header comment) —
  models a *different* process (parallel fork/join + timer escalation on an
  incident, not a shipment-document-attach flow) and is **not** reused by any of
  this requirement's four scenarios; it is REQ-205's own smoke-test fixture.
- No existing fixture models `swiftroute-shipment-ops-timeout-escalation`'s process
  or `swiftroute-shipment-attach-delivery-note`'s process — §1 below designs what
  each of those two scenarios actually needs (the former reuses
  `process_shipment_dispatch.yaml`'s existing timeout-escalation shape almost
  as-is; the latter has no possible real execution at all per §0's UNBUILT_FEATURE
  finding, so it needs no process fixture beyond a scenario YAML stub).
- No fixture models `swiftroute-tenant-onboarding-happy` as a *process* at all — it
  is a tenant-provisioning scenario, not a process-instance scenario; its
  api-equivalent steps map onto `Letflow.Simulation.Seed`/`Letflow.Routers.Onboarding`
  directly (§1.1), not `Letflow.Engine`.

PROVENANCE (historical, not current decision authority):
**REQ-050 confirmed** (`docs/requirements.yaml` REQ-050 entry, `status: done`): ports
`src/engine/transition.zig`'s `EXCLUSIVE_GATEWAY` branch — edges evaluated in declared
order, first true condition wins, `is_default` edge (none present on
`ceo-approval-gate`) evaluated last, a runtime condition error is treated as `false`
(not an instance error). `process_route_approval.yaml`'s `ceo-approval-gate` has
exactly two mutually-exclusive numeric conditions (`> 500` / `<= 500`, no default edge)
— evaluating `swiftroute-shipment-high-value-happy` (`declared_value: 750`) exercises
this exact mechanism: edge `e3` (`> 500`) must be the one taken, `e4` must not be, and
the CEO-approval `HUMAN_TASK` must actually be created (not silently released without a
co-sign) — see §2.2's expected outcomes.

**`Letflow.Engine.complete_task/3` (confirmed by reading `lib/letflow/engine.ex:1486`
this session)** does not require a prior `claim_task/3` call — it checks the task is
`:pending` and applies output variables directly, with `actor_id` recorded from
`attrs` for audit purposes only, not as an assignment precondition in the snippet read
this session.

**Settled (was OQ-1b) — claim is NOT required before complete, confirmed by reading
`lib/letflow/api/authorization.ex`'s `evaluate_access/2` this session:** its
`:AllowWithRowFilter` branch is reached only `if endpoint == :TasksList and
is_task_worker_only?(ctx.roles)`; every other endpoint that passes the permission
check (including `:TasksComplete`) falls through to
`%AccessDecision{kind: :Allow, task_scope: :all}` unconditionally — no row filter, no
assignee check, at the authorization layer. `POST /tasks/:id/complete` maps to the
`:TasksComplete` policy key (per `endpoint_policy_key/2`'s clause for that route), so
it is never subject to the row-filter branch at all. Combined with the
already-confirmed fact that `Engine.complete_task/3` itself applies no assignee
precondition either, this **definitively settles** the question: claim does **not**
need to precede complete under current code. Each of
`swiftroute-shipment-high-value-happy`'s "ops approve"/"CEO co-sign" scenario steps is
**exactly one** `POST /tasks/:id/complete` call (matching the scenario's own literal
3-step count: submit, ops-approve, ceo-co-sign — 3 business-level HTTP dispatches
total, not 5). §3.2 below is authored on this basis.

---

## §1 — Scenario YAML corpus: authoring and parsing

### 1.1 File layout

```
test/fixtures/simulation/swiftroute/scenarios/tenant-onboarding-happy.yaml
test/fixtures/simulation/swiftroute/scenarios/shipment-high-value-happy.yaml
test/fixtures/simulation/swiftroute/scenarios/shipment-ops-timeout-escalation.yaml
test/fixtures/simulation/swiftroute/scenarios/shipment-attach-delivery-note.yaml
```

New `scenarios/` subdirectory under the existing `test/fixtures/simulation/swiftroute/`
tree (parallel to REQ-205's `company.yaml`/`org_structure.yaml`/`process_*.yaml`,
which stay untouched). Each file carries the same synthetic-fixture header-comment
convention §0 restates (`# Synthetic — R-Co's tests/simulation/scenarios/<name>.yaml
is unreachable from this sandbox (see lib/letflow/design/req206-....md §0);
structurally faithful to REQ-206's own requirement-text field-by-field account,
not a byte-for-byte port`).

### 1.2 YAML shape — mirrors `Letflow.Simulation.Scenario`'s fields directly

Each scenario YAML's top-level keys map 1:1 onto `Scenario`'s struct fields
(`id`, `company_id`, `process_id`, `actors`, `preconditions`, `steps`,
`expected_outcomes`), plus **two new top-level keys this requirement adds**:

- `unbuilt_feature` (optional map, absent on 3 of 4 scenarios) — see §2.2.
- Each `steps[]` entry's existing `via` key gains one new legal value, `skip` (string
  form in YAML, atomized to `:skip` at parse time) — see §2.1. A `steps[]` entry with
  `via: skip` also carries a required `severity` key (`"MINOR"`/`"MAJOR"`/`"BLOCKER"`,
  atomized to `:minor`/`:major`/`:blocker`) and an optional `note` key (free-form
  string, e.g. the scenario's own documented fallback text) carried into the
  `step_result`'s `detail` field.

### 1.3 Parsing — `Letflow.Simulation.ScenarioFixture.load!/1` (new test-support module)

Location: `test/support/simulation/scenario_fixture.ex`. REQ-205's design (§9 OQ-2)
explicitly deferred "the exact HTTP method+path->context-function mapping... this
requirement only specifies the mechanism of dispatch, not an exhaustive action table,
since no scenario content exists yet in this requirement's scope" — REQ-206 is that
scope, so this requirement owns writing the one YAML->`Scenario`-struct parser REQ-205
anticipated, not a parallel structure.

```
@spec load!(path :: String.t()) :: Letflow.Simulation.Scenario.t()
```

- Reads and YAML-decodes the file (`YamlElixir.read_from_file!/1`, already a
  dependency per REQ-205 §4).
- Builds a `%Scenario{}` struct from the decoded map's top-level keys, atomizing only
  the closed enum fields the existing struct/step/precondition/expected_outcome shapes
  already declare as atoms (`step.via`, `step.severity` when present,
  `precondition.check`, `expected_outcome.verification.method`) via
  `String.to_existing_atom/1` against the fixed set those types already enumerate —
  never `String.to_atom/1` on arbitrary YAML content (closed-vocabulary parsing,
  same "no arbitrary code execution from YAML content" discipline Runner's own
  `:custom` precondition registry already applies, per REQ-205 §3.3). An unrecognized
  `via`/`check`/`method` value raises `ArgumentError` at load time (a fixture-authoring
  bug caught immediately, not a silently-mis-parsed scenario).
- All other keys (ids, action strings, params maps, actor names) pass through as
  plain strings/maps — YAML's own string/map/list decoding already matches the
  struct's `String.t()`/`map()` field types, no further transform needed (same as
  REQ-205's `seed.py`-fixture parsing convention).
- This function is intentionally **not** exhaustive against every YAML shape R-Co's
  real fixture format might one day use (there is no real corpus to validate against,
  per §0) — it parses exactly this requirement's synthetic corpus's shape. A later
  requirement that gains real R-Co scenario access re-validates/extends this parser
  against the real format then, per REQ-205's own precedent for the company/org/
  process fixtures (§9's OQ-3 flags the analogous risk for those).

---

## §2 — Runner extension: `:skip` and `:unbuilt_feature`

Both additions are **strictly additive** to the shipped `test/support/simulation/runner.ex`
(read in full this session) — no existing field is renamed, retyped, or removed, and
every existing REQ-205 test (`test/letflow/simulation/runner_test.exs`) keeps passing
unmodified, because every new field defaults to a value that reproduces today's exact
behavior when absent.

### 2.1 `:skip` — step-level, alongside `:ok`/`:error`/`:deferred_to_s8`

**Where it lives:** `Scenario`'s `step()` shape and `RunReport`'s `step_result()`
shape, both extended with one new field each:

| Struct | New field | Type | Default when absent |
|---|---|---|---|
| `Scenario.step()` | `via` | `:api \| :gui \| :skip` (was `:api \| :gui`) | n/a (required, existing field, one new legal value) |
| `Scenario.step()` | `severity` | `:minor \| :major \| :blocker \| nil` | `nil` (only meaningful when `via == :skip`; unused by `:api`/`:gui` steps) |
| `Scenario.step()` | `note` | `String.t() \| nil` | `nil` (optional free-form context, e.g. the scenario's own documented fallback text; folded into the step_result's `detail`) |
| `RunReport.step_result()` | `outcome` | `:ok \| :error \| :deferred_to_s8 \| :skip` (was three-valued) | n/a |
| `RunReport.step_result()` | `severity` | `:minor \| :major \| :blocker \| nil` | `nil` (echoes the step's `severity`; `nil` for every non-`:skip` outcome, so no existing assertion on `step_result.outcome` alone breaks) |

**Why a third `via` value, not a Runner-side 404-detection heuristic:** an earlier
candidate design had Runner dispatch the `advance-timer` step normally and reclassify
a `404` response as `:skip`. Rejected: a *real* routing bug (e.g. a typo'd path on an
endpoint that does exist) would be silently reclassified as an expected, benign SKIP
instead of surfacing as the `:error` it actually is — indistinguishable from the
intended case at the HTTP-status level alone. `via: :skip` instead makes the
disposition a **fact about the scenario fixture, decided once at authoring time**
(by whoever ports/authors the scenario YAML, informed by the same grep-confirmed
absence §0 records), exactly mirroring how `via: :gui` already makes "never dispatch
this, it's out of this lane's scope" a fixture-time decision rather than a runtime
inference — same mechanism, third value, not a parallel structure.

**Execution algorithm change (§3.3 step 3 of REQ-205's design, `run_steps/1` in the
real code):** the existing three-way dispatch on `step.via` (`:gui` vs. `:api`) in
`run_steps/1` gains a third branch for `:skip`, parallel in shape to the existing
`:gui` branch: it builds a `step_result` with `outcome: :skip`, `captured: nil`,
`detail` set from the step's `note` field (falling back to a fixed
"marked SKIP at scenario-authoring time" string when `note` is absent), and
`severity` copied from the step's `severity` field. A `:skip` step declared with no
`severity` is a fixture-authoring error and must raise loudly at run time (an
`ArgumentError`, or equivalent), never silently defaulting to a guessed severity —
same fail-loud discipline as REQ-205's `:custom` precondition dispatch. No HTTP dispatch occurs, same
non-negotiable rule `:gui`/`:deferred_to_s8` already enforces. A `:skip` step
declared with no `severity` is a fixture-authoring error, raised loudly at run time
rather than defaulting to a guessed severity — matching the closed-registry,
fail-loud discipline REQ-205's `:custom` precondition dispatch already established.

Template substitution's fail-closed rule (REQ-205 §3.3 step 3, `{{produces.X}}`
referencing a `:gui` step's nonexistent `captured`) extends verbatim to `:skip`
steps — a later `:api` step depending on a `:skip` step's `produces` output fails
closed identically, never substituting a placeholder.

**`swiftroute-shipment-ops-timeout-escalation` fixture authoring, concretely:** step
2 (the timer-advance step) is authored with `via: skip`, `severity: MINOR`, `note:
"POST /api/v1/instances/:id/advance-timer does not exist -- grep of lib/letflow/
router.ex and lib/letflow/routers/*.ex, zero matches, per lib/letflow/design/
req206-swiftroute-scenario-execution.md §0. Scenario's own documented fallback: 'If
not available, this scenario is marked SKIP with severity MINOR.'"` — steps 1 and 3
stay `via: api`, dispatched for real against `process_shipment_dispatch.yaml`'s
existing `ops-assessment`/`ops-auto-close` `HUMAN_TASK`/timeout-edge shape (§0 — that
fixture already models a `HUMAN_TASK` with an `on_timeout` fallback edge to a
`SERVICE_TASK`; the scenario's step 1 starts the instance, its step 3 verifies the
post-timeout-or-post-completion state, matching what "run steps 1 and 3 for real"
requires without inventing a new process shape).

### 2.2 `:unbuilt_feature` — scenario-level, not step-level

**Design question the task explicitly poses: does UNBUILT_FEATURE apply at the
whole-scenario level or the per-step level? Answer: whole-scenario, deliberately not
folded into `step_result.outcome`.** Rationale: `swiftroute-shipment-attach-delivery-
note` has "no possible real execution today on either lane" for **all 5** of its
steps, for the **same single root cause** (no attachment API exists anywhere) — five
identical `:skip` step results would both misrepresent the finding as five separate
facts instead of one, and violate the requirement's own explicit instruction ("zero
steps executed... do not attempt to execute any of its 5 steps"): `:skip` steps are
still *evaluated* by `run_steps/1` (their `note`/`severity` are read, a `step_result`
is constructed) even though no HTTP dispatch happens — UNBUILT_FEATURE requires that
`run_steps/1` never runs at all for this scenario, which only a scenario-level
short-circuit before Phase 2 (REQ-205 §3.3) achieves.

**Where it lives:**

| Struct | New field | Type | Default when absent |
|---|---|---|---|
| `Scenario` (top-level struct) | `unbuilt_feature` | `%{reason: String.t()} \| nil` | `nil` (every REQ-205-authored scenario, and 3 of this requirement's 4, carry no such field — `run/1`'s existing full algorithm runs unchanged) |
| `RunReport` (top-level struct) | `disposition` | `:executed \| :unbuilt_feature` | `:executed` (every existing `RunReport` value, including every one REQ-205's own tests construct and assert against, is implicitly `:executed` — no existing assertion on `precondition_results`/`step_results`/`outcome_results` breaks, since those fields' *types* are unchanged, only newly guaranteed to be `[]` when `disposition == :unbuilt_feature`) |
| `RunReport` | `notes` | `String.t() \| nil` | `nil` (carries `scenario.unbuilt_feature.reason` verbatim when `disposition == :unbuilt_feature`; unused otherwise) |

**`run/1`'s algorithm gains one new leading branch, before Phase 1 (preconditions):**
when the scenario given to `run/1` carries a non-`nil` `unbuilt_feature` field, the
function returns immediately with `{:ok, report}` where `report.disposition ==
:unbuilt_feature`, `report.notes` is set from `scenario.unbuilt_feature.reason`, and
`precondition_results`/`step_results`/`outcome_results` are all `[]` by construction
— none of REQ-205's existing preconditions/steps/outcomes machinery runs at all for
such a scenario. Every scenario whose `unbuilt_feature` field is `nil` (the struct's
default) falls through to REQ-205's existing algorithm unchanged, implicitly
producing `disposition: :executed`. This is ordinary function-clause pattern
matching on a struct field — the same mechanism the shipped code already uses
throughout this module (`check_precondition/3`'s multiple clauses dispatching on
`precondition.check`) — not a new kind of dispatch, and it is why every existing
`%Scenario{...}` literal in `runner_test.exs` (and every scenario REQ-207/REQ-208
build without this field) is unaffected.

**`swiftroute-shipment-attach-delivery-note` fixture authoring, concretely:** the
scenario YAML's `unbuilt_feature` key is populated:

PROVENANCE (historical, not current decision authority):

```
unbuilt_feature:
  reason: >
    No attachment/document-upload API exists in Letflow (no attachment-related route
    in any lib/letflow/routers/*.ex, verified) or in R-Co's own src/ (the only two
    "attach"/"storage" hits, src/db/partition_attach.zig and
    src/design/iss501_storage_mode_routing.md, are both unrelated to shipment
    document attachments, per REQ-206's own requirement text) -- this is a scenario
    describing a feature that does not exist as a real backend capability in either
    codebase yet, not a Letflow gap against an existing R-Co feature. See
    lib/letflow/design/req206-swiftroute-scenario-execution.md §0/§4.
```

`steps`, `preconditions`, and `expected_outcomes` are still present in the YAML file
(so `ScenarioFixture.load!/1` produces a structurally complete `%Scenario{}`, useful
for future re-execution once the feature exists) but are **never read** by `run/1`'s
short-circuit branch — this is the concrete mechanism satisfying "do not attempt to
execute any of its 5 steps."

### 2.3 Full extended type summary (for ELIXIR-DEV's direct reference)

```
Scenario.step().via              :: :api | :gui | :skip                    (was :api | :gui)
Scenario.step().severity         :: :minor | :major | :blocker | nil       (new, optional)
Scenario.step().note             :: String.t() | nil                       (new, optional)
Scenario.unbuilt_feature         :: %{reason: String.t()} | nil            (new, optional)

RunReport.disposition            :: :executed | :unbuilt_feature           (new, default :executed)
RunReport.notes                  :: String.t() | nil                       (new, optional)
RunReport.step_result().outcome  :: :ok | :error | :deferred_to_s8 | :skip (was three-valued)
RunReport.step_result().severity :: :minor | :major | :blocker | nil       (new, optional)
```

No change to `precondition_result()`, `outcome_result()`, or any `expected_outcome()`
shape — none of the four scenarios' findings implicate preconditions or verification
methods, only step dispatch and scenario-level gating.

---

## §3 — Per-scenario execution plan

### 3.1 `swiftroute-tenant-onboarding-happy` (AC1)

5 steps in the scenario's own terms (per the requirement text: "5 steps... steps 1-3
use `via: gui` explicitly, step 4-5 also gui" — i.e. **all 5 are `via: gui`** in this
scenario's actual current form; there is no `via: api` step to dispatch at all).
"api-equivalent provisioning" (AC1's wording) is therefore **not** a Runner
`via: api` dispatch — it is REQ-205's `Letflow.Simulation.Seed` module, called
directly by the scenario's own ExUnit test (mirroring `runner_test.exs`'s `setup`
block, which already calls `Seed.seed_company/1` + `Seed.seed_users/2` before
`Runner.run/1` even starts):

1. `Seed.seed_company(%{"slug" => ..., "display_name" => "SwiftRoute Ltd", "hostname"
   => ...})` — tenant + schema provisioning + onboarding record, the real
   `Letflow.Identity.create_tenant/1` -> `Letflow.TenantOnboarding.provision_and_migrate/1`
   -> `Letflow.Identity.create_onboarding/1` sequence (REQ-205 §2.1).
2. `Seed.seed_users/2` for the admin user (from `org_structure.yaml`'s people list —
   the fixture already ported in REQ-205, reused as-is per §0's "no new process
   fixture needed" — the admin actor is whichever `org_structure.yaml` person the
   scenario names, e.g. `actor-swiftroute-alice`, `dept-mgmt`'s member).

**Verification against real Letflow state (EO-001..EO-003-equivalent, per AC1):**

| R-Co EO (per requirement text) | Concrete Letflow verification |
|---|---|
| Onboarding completed | `Letflow.Identity.get_onboarding_by_hostname/1` returns `{:ok, record}` (real row read, not inferred from `Seed.seed_company/1`'s return tuple alone) |
| Slug/hostname registered | `Letflow.Identity.get_tenant_by_slug/1` returns `{:ok, tenant}` with `tenant.status == :active` (not `:migrating` — confirms `provision_and_migrate/1` actually completed, per REQ-076's `:migrating`-window design cited in §0) |
| Admin login-ready | `Letflow.Identity.get_by_username/2` (scoped to the tenant's schema prefix) returns the seeded admin user; optionally, `Letflow.Identity.create_token/3` for that user succeeds (proves the user is a real, authenticatable principal, not merely a row) |

This is a **direct ExUnit test** (`test/letflow/simulation/req206_swiftroute_test.exs`,
one `test` block per scenario, same file REQ-206 owns for all four), not a
`Runner.run/1` invocation — there is no `Scenario` struct for this scenario's
"api-equivalent" half at all, since Runner's `Scenario`/step abstraction is
HTTP-dispatch-shaped and Seed's calls are direct context-function calls (REQ-205 §2's
own "no HTTP client" contract). The scenario YAML file
(`scenarios/tenant-onboarding-happy.yaml`) still exists and still declares all 5
steps as `via: gui` (so `ScenarioFixture.load!/1` produces a structurally valid
`%Scenario{}` for record-keeping/future re-execution), but the test itself calls
`Seed` directly for the api-equivalent assertions and separately asserts each of the
5 `via: gui` steps' presence in the loaded fixture is recorded — never executed,
never silently dropped.

**The gui/DEFERRED_TO_S8 distinction (AC1's second half), stated explicitly in the
test module's own moduledoc and in this design, not left to inference:**

> `web/tests/e2e/pipelines/onboarding-wizard.pipeline.e2e.spec.ts` **exists** in this
> repo's `web/` tree (confirmed by `find` this session — see below). This is the one
> SwiftRoute scenario of the four where a real Playwright run against a live
> `web/`-plus-Letflow pair could in principle execute *some day*. It is still recorded
> `DEFERRED_TO_S8` today, identically to a scenario with no spec file at all, because
> **S8's integration work (pointing `web/` at Letflow's real API) has not started** —
> no live `web/`-plus-Letflow pair exists yet for the spec to run against, regardless
> of whether the spec file itself is present. "Spec exists" is not "integration
> exists." `Runner`'s own `:deferred_to_s8` `detail` string
> (`"S8 frontend integration not started; see
> docs/migration/stage-7-simulation-uat-parity.md"`) is already factually accurate
> for this case without modification — the *scenario-level* narrative distinction
> (spec-exists vs. spec-doesn't) is a fact this test module's own assertions/comments
> state about the fixture, not a new Runner code path.

```
find web/tests/e2e/pipelines/ -iname "onboarding-wizard*"
-> web/tests/e2e/pipelines/onboarding-wizard.pipeline.e2e.spec.ts  (confirmed present)
```

(ELIXIR-DEV re-runs this `find` at implementation time to re-confirm — not re-derived
here beyond restating the requirement's own already-cited fact, since this design
session did not itself execute a shell `find` against `web/`.)

### 3.2 `swiftroute-shipment-high-value-happy` (AC2)

Uses `process_route_approval.yaml` (already ported, §0). 3 `via: api` steps, all
dispatched for real through `Letflow.Router.call/2` exactly as `runner_test.exs`'s
existing AC4 smoke test already demonstrates the mechanism for:

**Settled (was OQ-2) — the instance-scoped task lookup, confirmed by reading
`lib/letflow/routers/tasks.ex`'s `handle_list/3` this session:** its `with` clause
parses an `instance_id` query param (`parse_instance_id_param(Map.get(query,
"instance_id"))`) and passes it straight through to `Tasks.list_tasks/2`'s filter
map, alongside an equally-supported `status` param. `GET /api/v1/tasks?
instance_id=<uuid>` (optionally combined with `&status=PENDING`) is therefore the
real, already-implemented mechanism for "the task currently pending on instance X."
Each of steps 2/3 below is an ordered pair of Scenario `step()` entries: a `GET
/api/v1/tasks?instance_id={{produces.instance.instance_id}}&status=PENDING` lookup
(`produces: "ops_task"` / `"ceo_task"`, captured field is the response's matching
task's `id`), followed by the `POST .../complete` dispatch shown below — both real
`via: api` steps, no `claim` dispatch needed (settled above).

**Settled (was OQ-3) — the `roles:` claim value each actor's token needs, confirmed
by reading `lib/letflow/engine/task_activation.ex`'s `resolve_assignee/1` this
session:** that function returns `{Map.get(attributes, "assignee_type"), Map.get(attributes,
"role")}` — for a `role:`-attributed `HUMAN_TASK` node, `assignee_ref` is
`node.attributes["role"]` verbatim, the literal role-attribute string written in the
process YAML (`process_route_approval.yaml`'s `ops-review` node carries `role:
role-ops-manager`, its `ceo-approval` node carries `role: role-ceo`). `Letflow.Tasks`'s
`assignee_type == "ROLE"` claim/complete-scope resolution matches an actor's granted
roles list against that identical string. This settles the exact token shape: each
scenario actor's `Letflow.Identity.create_token/3` call at test `setup` time must
include the process node's exact role string in its `roles:` list — the ops-approve
actor's token carries `roles: ["role-ops-manager"]`, the CEO-co-sign actor's token
carries `roles: ["role-ceo"]` — no other string authorizes claim/complete against
that `assignee_ref`.

**Settled (was OQ-1, should-fix) — no distinct CEO actor in `org_structure.yaml`:**
confirmed by reading `test/fixtures/simulation/swiftroute/org_structure.yaml` this
session — it lists exactly 4 groups (`dept-mgmt: [alice]`, `dept-ops: [marco, jan,
petra]`, `dept-dispatch: [lena, tobias]`, `dept-finance: [hans]`), no `role-ceo`
group or distinct CEO person. Per REQ-205's fixture-freeze convention (`org_structure.yaml`
is otherwise untouched by this requirement, §1.1), this design resolves the choice
rather than deferring it: `actor-swiftroute-alice` (dept-mgmt's sole member) is used
as the CEO-role actor, granted `roles: ["role-ceo"]` at token-creation time in
addition to (or instead of, since roles are per-token not per-org-fixture) whatever
`dept-mgmt` role she'd otherwise carry — this needs no `org_structure.yaml` change,
since role grants live in the scenario test's `create_token/3` call, not in the
fixture file itself.

| Step | Actor | `action` | `params` (post-template-substitution) | `produces` |
|---|---|---|---|---|
| 1 (dispatcher submit) | `actor-swiftroute-lena` (dept-dispatch, per `org_structure.yaml`) | `POST /api/v1/instances` | `{"definition_name": "<seeded name>", "initial_variables": {"declared_value": 750}}` | `"instance"` |
| 2a (ops task lookup) | `actor-swiftroute-marco` (dept-ops, token `roles: ["role-ops-manager"]`) | `GET /api/v1/tasks?instance_id={{produces.instance.instance_id}}&status=PENDING` | n/a | `"ops_task"` |
| 2b (ops approve) | `actor-swiftroute-marco` | `POST /api/v1/tasks/{{produces.ops_task.id}}/complete` | `{"output_variables": {"ops_decision": "approve"}}` | `"ops_task_result"` |
| 3a (CEO task lookup) | `actor-swiftroute-alice` (dept-mgmt, token `roles: ["role-ceo"]` — see settled-OQ-1 above) | `GET /api/v1/tasks?instance_id={{produces.instance.instance_id}}&status=PENDING` | n/a | `"ceo_task"` |
| 3b (CEO co-sign) | `actor-swiftroute-alice` | `POST /api/v1/tasks/{{produces.ceo_task.id}}/complete` | `{"output_variables": {"ceo_decision": "approve"}}` | `"ceo_task_result"` |

The scenario's own "3 steps" (submit, ops-approve, ceo-co-sign) still holds at the
scenario-YAML/business-narrative level — each business step is one `POST .../complete`
dispatch, exactly as settled above; the lookup dispatches (2a/3a) are Runner-level
plumbing to resolve a `task_id`, not additional business steps, matching REQ-205's own
`produces`/template-substitution mechanism for chaining dependent HTTP calls.

**All 4 `expected_outcomes` (AC2's literal count), each `PASS`/`FAIL` against real
queried state:**

1. `task_assigned` — the `ceo-approval` `HUMAN_TASK` (not `release-shipment`
   directly) was actually created and its `assignee_type`/`assignee_ref` names the
   CEO role/actor — the direct evidence that REQ-050's exclusive-gateway dispatch
   took edge `e3` (`declared_value > 500`), not `e4`. This is the load-bearing
   assertion for "exercises REQ-050's exclusive-gateway CEL/expr condition dispatch"
   — a `PASS` here is only meaningful because the alternative (`e4`, skip straight to
   `release-shipment`) is a real, reachable branch this scenario's declared value
   deliberately avoids.
2. `instance_state` — final instance `status == "COMPLETED"` (or R-Co's equivalent
   terminal status string) after both approvals, at `end-approved`, not
   `end-rejected`.
3. `instance_state` (second entry, distinct `args`) — the instance's persisted
   `variables` include `ops_decision: "approve"` and `ceo_decision: "approve"` (both
   output-variable merges actually landed, not just the final status).
4. `audit_event` — at least one audit entry exists for the CEO-approval task's
   `complete` action, scoped to that task/instance id (REQ-195/196's audit store,
   per REQ-205 §6's `audit_event` method) — "each recorded PASS or FAIL with the
   specific evidence" (AC2) is satisfied by `outcome_result.observed` carrying the
   matched audit row (or its absence).

### 3.3 `swiftroute-shipment-ops-timeout-escalation` (AC3)

Reuses `process_shipment_dispatch.yaml` ("Driver Incident Report," §0) — its
`ops-assessment` `HUMAN_TASK` with `timeout-ops-assessment` fallback edge to
`ops-auto-close` is structurally the "ops timeout escalation" shape this scenario
needs; no new process fixture is authored.

| Step | Disposition | Mechanism |
|---|---|---|
| 1 | Real (`via: api`) | `POST /api/v1/instances` — starts the instance, dispatcher/ops actor per `org_structure.yaml`. |
| 2 | `via: skip`, `severity: MINOR` | Per §2.1 — no HTTP dispatch. `note` cites the grep evidence verbatim. |
| 3 | Real (`via: api`) | A verification-oriented dispatch (e.g. `GET /api/v1/instances/{{produces.instance.instance_id}}`) confirming the instance is still `ACTIVE`, paused at `ops-assessment`, having neither auto-escalated (no timer-advance call was made) nor errored — i.e. step 3 proves the harness's own state is coherent *despite* step 2 being skipped, not that the scenario's original timeout-escalation business outcome was verified (that would require the missing endpoint). |

**Finding reported to ORCH (AC3's second half), per `docs/agents/protocols/
ISSUE_QUEUE.md`:** ELIXIR-DEV's WF-02 handoff (`step-02a-elixir-dev.json`) carries,
in `result.issues` (per ISSUE_QUEUE.md's step 2 — "the discovering agent reports the
finding to ORCH... it does not call `gh` or letflow-queue itself"):

```
title: "POST /api/v1/instances/:id/advance-timer does not exist"
description: >
  swiftroute-shipment-ops-timeout-escalation.yaml's step 2 requires a
  timer-advance endpoint that Letflow.Router does not expose. Confirmed by
  grep -rn "advance-timer|advance_timer" lib/letflow/router.ex
  lib/letflow/routers/*.ex -> zero matches (re-confirmed
  lib/letflow/design/req206-swiftroute-scenario-execution.md §0). The
  scenario's own note field already anticipates this ("If not available,
  this scenario is marked SKIP with severity MINOR") -- that exact
  disposition was applied; this finding requests the endpoint be built as
  new functionality in a future requirement, out of REQ-206's
  correctness-gate scope.
severity: MINOR
affected_files:
  - lib/letflow/router.ex
  - lib/letflow/routers/instances.ex
  - test/fixtures/simulation/swiftroute/scenarios/shipment-ops-timeout-escalation.yaml
```

ORCH files this via `register_task`/`docs/issues/<issue_ref>.yaml` per
ISSUE_QUEUE.md steps 2a/3 — ELIXIR-DEV does **not** call `register_task` itself
(matching this run's own explicit instruction and ISSUE_QUEUE.md's division of
labor).

### 3.4 `swiftroute-shipment-attach-delivery-note` (AC4)

Per §2.2: `scenarios/shipment-attach-delivery-note.yaml` carries a populated
`unbuilt_feature` key. `Runner.run/1`'s new leading branch returns
`disposition: :unbuilt_feature` with empty `precondition_results`/`step_results`/
`outcome_results` and `notes` carrying the reason — zero steps executed, exactly as
AC4 requires. The scenario's own `steps`/`preconditions`/`expected_outcomes` keys are
still authored in the YAML (5 `via: gui` steps, matching the requirement's own step
count) so the fixture is structurally complete for a future re-run once the feature
exists, but `run/1`'s short-circuit means none of that content is read this run.

**Finding reported to ORCH, per ISSUE_QUEUE.md, in the same handoff's `result.issues`:**

PROVENANCE (historical, not current decision authority):

```
title: "No document/attachment API exists in Letflow or in R-Co's own src/"
description: >
  swiftroute-shipment-attach-delivery-note.yaml (5 steps, all via: gui,
  pipeline_test: web/tests/e2e/pipelines/shipment-attach-delivery-note.
  pipeline.e2e.spec.ts) has no possible real execution on either lane.
  Confirmed: (1) no attachment-related route in any lib/letflow/routers/*.ex
  (grep for attach/upload/document, zero relevant matches); (2) that
  Playwright spec file does not exist under web/tests/e2e/pipelines/
  (re-confirm via find at implementation time); (3) R-Co's own src/ has no
  attachment/document-upload subsystem -- the two src/ hits for "attach"/
  "storage" are src/db/partition_attach.zig and
  src/design/iss501_storage_mode_routing.md, both unrelated to shipment
  document attachments (per this requirement's own text; R-Co's src/ is
  unreachable from this sandbox to re-verify directly, see
  lib/letflow/design/req206-swiftroute-scenario-execution.md §0). This is a
  scenario describing a feature absent from both codebases, not a Letflow
  gap against an existing R-Co feature -- filed as new-feature scope, not a
  regression.
severity: MINOR
affected_files:
  - test/fixtures/simulation/swiftroute/scenarios/shipment-attach-delivery-note.yaml
```

---

## §4 — Acceptance-criteria-to-design-element map

| AC | Design element |
|---|---|
| AC1 (onboarding-happy: api-equivalent provisioning exercised + EO-001..003-equivalent verified; gui steps DEFERRED_TO_S8 with spec-exists-not-integrated distinction stated) | §3.1 |
| AC2 (high-value-happy: 3 steps run end to end, all 4 expected_outcomes PASS/FAIL with evidence) | §3.2 (process fixture confirmed at §0), Runner's existing `:ok`/`instance_state`/`task_assigned`/`audit_event` mechanisms, unmodified |
| AC3 (ops-timeout-escalation: steps 1/3 real, step 2 SKIP/MINOR exactly, finding reported to ORCH with grep evidence) | §2.1 (`:skip`/`severity` extension) + §3.3 (fixture authoring + ISSUE_QUEUE.md-shaped finding text) |
| AC4 (attach-delivery-note: UNBUILT_FEATURE, zero steps executed, finding reported to ORCH with R-Co paths checked) | §2.2 (`unbuilt_feature`/`disposition` extension) + §3.4 |
| AC5 (report states a closed disposition set — PASS/FAIL/SKIP/DEFERRED_TO_S8/UNBUILT_FEATURE — for every one of the four scenarios' steps, none omitted) | §2.3's full type summary (closed enum, no other value possible) + §3.1-3.4 each accounting for every step of its scenario explicitly (5+3+3+5 = 16 steps total, every one assigned a disposition in this design) |
| AC6 (`mix test`/`mix compile --warnings-as-errors` pass, real output quoted) | Implementation-phase obligation (ELIXIR-DEV/TEST-RUNNER) — no design-time element; noted so it is not missed at handoff |

---

## §5 — Formerly-open questions, now settled (no open questions remain)

The prior draft of this design carried four open questions (OQ-1, OQ-1b, OQ-2, OQ-3),
deferring each to ELIXIR-DEV. This rework resolves all four from material already
read in the same session — no genuinely unknowable fact remained among them. Each is
now a settled design decision, stated in place at its point of use above; this
section is a pointer index, not a deferral list:

- **OQ-1b (claim-before-complete precondition) — settled in §0**, by reading
  `lib/letflow/api/authorization.ex`'s `evaluate_access/2`: `:AllowWithRowFilter`
  applies only to `:TasksList`; `:TasksComplete` always yields `%AccessDecision{kind:
  :Allow, task_scope: :all}`. Combined with the design's already-confirmed fact that
  `Engine.complete_task/3` has no assignee precondition, claim is **not** required
  before complete. §3.2's step table is authored as exactly one `POST .../complete`
  dispatch per business step (no `claim` dispatches).
- **OQ-2 (instance-scoped task lookup) — settled in §3.2**, by reading
  `lib/letflow/routers/tasks.ex`'s `handle_list/3`: `GET /api/v1/tasks?
  instance_id=<uuid>` (optionally `&status=PENDING`) is the real, shipped lookup
  mechanism. §3.2's step table specifies this exact call for steps 2a/3a.
- **OQ-3 (role-attributed task assignee resolution) — settled in §3.2**, by reading
  `lib/letflow/engine/task_activation.ex`'s `resolve_assignee/1`: a role-attributed
  `HUMAN_TASK`'s `assignee_ref` is the literal `role` attribute string
  (`"role-ops-manager"`, `"role-ceo"`). Each scenario actor's token `roles:` list must
  contain that exact string; §3.2's table states the concrete values.
- **OQ-1 (no distinct CEO actor in the swiftroute fixture) — settled in §3.2, as a
  should-fix**, by reading `test/fixtures/simulation/swiftroute/org_structure.yaml`
  directly: confirmed no `role-ceo` group/actor exists (4 groups: `dept-mgmt`,
  `dept-ops`, `dept-dispatch`, `dept-finance`). This design picks
  `actor-swiftroute-alice` (dept-mgmt's sole member) as the CEO-role actor, granted
  `roles: ["role-ceo"]` at scenario-test token-creation time — no `org_structure.yaml`
  change needed, since role grants are a per-token/per-test concern, not a fixture-file
  concern, keeping REQ-205's fixture frozen as intended.
