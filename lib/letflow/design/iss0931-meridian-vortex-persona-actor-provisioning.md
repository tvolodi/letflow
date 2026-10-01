# Design: Meridian / Vortex Persona Actor Provisioning (ISS-0931)

**Issue:** ISS-0931 (queue Q-914, GH #2065). Follow-on to ISS-0739/ISS-0761
(`lib/letflow/design/iss-0761-swiftroute-persona-actor-provisioning.md`).
**Run:** WF03-ISS0931-20261001. **Type:** scripts + test + docs. No `lib/`, no migration.
**Model script:** `scripts/seed_swiftroute_persona_actors.sh` (behavior unchanged).

## 1. Scope and non-goals

Root cause (see diagnosis): meridian/vortex definitions route HUMAN_TASKs to
`role-*` names; no `tenant_roles` (kind `process_routing_role`) rows or group
memberships exist for them, so inbox is empty and claim returns 409
(`lib/letflow/tasks.ex` `resolve_principal_scope/2`, `apply_claim`). Fix = provisioning
scripts only, using existing identity endpoints (`POST /groups`, `POST /roles`,
`GET /users?search=`, `POST /groups/:id/members`, `GET /roles`, `GET /groups`) exactly as
ISS-0761 sections 2-3 specify. Payload/idempotency semantics are inherited, not redefined.

Out of scope: D1 (ISS-0930), D4, D5 (complete does not enforce ROLE; separate security
triage), Keycloak account creation (Part A), the role-procurement-manager scenario
mismatch (no definition references it; do NOT seed it; flag to BA-VORTEX). Nothing is run
against QA by the pipeline; QA execution is a post-merge ops step and the QA symptom is
not claimed cleared until UAT-RUNNER re-runs the scenarios.

## 2. Files

| File | Change |
|---|---|
| `scripts/lib/seed_persona_actors_base.sh` | NEW. Sourced helper (functions only, no top-level side effects, no `set -e` of its own beyond what callers set). |
| `scripts/seed_meridian_persona_actors.sh` | NEW. |
| `scripts/seed_vortex_persona_actors.sh` | NEW. |
| `scripts/seed_swiftroute_persona_actors.sh` | UNCHANGED (its behavior and tests are frozen; do not refactor it onto the shared lib in this issue). |
| `test/scripts/persona_actor_seed_drift_test.exs` | NEW ExUnit test (section 6). |
| `.claude/agents/uat-runner.md` | Doc note (section 7). |

### Structure decision: shared helper, not duplication

Two new scripts would otherwise copy ~150 lines of helpers a second and third time.
`scripts/lib/seed_service_task_base.sh` is the precedent for a sourced lib. Decision:
one new lib `scripts/lib/seed_persona_actors_base.sh`, sourced by both scripts via
`source "$(dirname "${BASH_SOURCE[0]}")/lib/seed_persona_actors_base.sh"`.
The swiftroute script keeps its inline copies (changing proven, already-QA-run code is
unrelated risk). Open follow-up (not this issue): migrate swiftroute onto the lib.

#### Lib function signatures (bash; bodies are a straight port of the swiftroute helpers)

All read globals `API`, `AUTH_HEADER` set by the caller. All errors go to stderr and `exit 1`.

- `persona_require_env()` : verifies `QA_AUTH_TOKEN`; sets `QA_URL` default
  `https://qa.bizdala.com`, `API`, `AUTH_HEADER`. Error text identical to swiftroute.
- `lookup_user_id <username>` -> stdout user UUID; aborts naming the actor and "Complete
  Part A (ai-dala-infra Keycloak provisioning)". Must require an EXACT username match
  (`jq select(.username==$u)` over `.items[]`), not `items[0]` (substring search such as
  `actor-vortex-claudia` vs other tenants' names makes `[0]` unsafe). This is a deliberate
  hardening over the swiftroute helper.
- `find_group_id <name>` -> stdout id or empty.
- `ensure_group <name> <display_name> <description>` -> stdout id (idempotent via find).
- `upsert_role <name> <group_id>` -> POST `/roles` kind `process_routing_role` (upsert).
- `add_group_member <group_id> <user_id> <label>` -> 200/201 success, else abort.
- `resolve_task_worker_group_id()` -> stdout id; aborts if `TASK_WORKER` not seeded.
- `persona_run <tenant_label>` : the driver. Reads the caller's `ROLES` and `PERSONAS`
  arrays, then: resolve TASK_WORKER; for each role `ensure_group` + `upsert_role`
  (display_name derived by the lib from the role name, description generic
  `"Process-routing role <name> (<tenant_label>)."`); resolve ALL persona user ids FIRST
  (so a missing Part A actor aborts before any membership write); then add TASK_WORKER
  membership for every persona and each listed role membership; print summary and a
  verification echo block in the swiftroute style.

Idempotency: re-running yields only "already exists" / 200 outputs. No step depends on a 409.

## 3. Machine-parsable table format (contract with the drift test)

Each script declares, at top level before sourcing/running the driver, EXACTLY these two
shell constructs (one entry per line, double-quoted, no variable expansion, no
continuation tricks, no comments on entry lines):

```
ROLES=(
  "role-credit-manager"
  "role-risk-manager"
)
PERSONAS=(
  "actor-meridian-ben|role-credit-manager"
  "actor-meridian-julia|role-credit-director,role-committee-member"
  "actor-meridian-lars|"
)
```

Rules:
- `ROLES=(` opens on its own line; entries are one quoted string per line; `)` closes on its
  own line. Same for `PERSONAS=(`.
- PERSONAS entry = `<username>|<comma-separated roles>`; the roles field is empty for
  TASK_WORKER-only personas (entry ends with `|`). TASK_WORKER is IMPLICIT for every
  persona and never appears in either table.
- Every role in a PERSONAS entry must be in the same script's `ROLES`.
- Parser regexes for the test: array body = lines between `^ROLES=\($` / `^PERSONAS=\($`
  and the next `^\)$`; entry = `^\s*"([^"]*)"\s*$`.

## 4. Seeded tables (acceptance: must equal fixtures)

Source of role sets: `role` attributes of HUMAN_TASK nodes in
`test/fixtures/qa/{meridian_loan_origination,meridian_regulatory_compliance_review,vortex_production_order_release,vortex_supplier_quality_deviation}_process_definition.json`
(verified by grep of `"role":` above).

### Meridian `ROLES` (8, exact)
`role-credit-manager`, `role-risk-manager`, `role-compliance-officer`,
`role-credit-director`, `role-committee-member`, `role-loan-ops`, `role-cro`, `role-ceo`.

### Vortex `ROLES` (4, exact)
`role-production-manager`, `role-controller`, `role-quality-manager`, `role-ceo`.
`role-procurement-manager` is NOT in the list.

### Meridian `PERSONAS`
| Username | Roles (plus implicit TASK_WORKER) |
|---|---|
| actor-meridian-ben | role-credit-manager |
| actor-meridian-miriam | role-risk-manager |
| actor-meridian-claudia | role-compliance-officer |
| actor-meridian-julia | role-credit-director, role-committee-member |
| actor-meridian-thomas | role-committee-member, role-cro |
| actor-meridian-eva | role-committee-member, role-ceo |
| actor-meridian-marcus | role-loan-ops |
| actor-meridian-lars | (none) |
| actor-meridian-sophie | (none) |
| actor-meridian-oliver | (none; decision: TASK_WORKER only, unused by any scenario) |

### Vortex `PERSONAS`
| Username | Roles (plus implicit TASK_WORKER) |
|---|---|
| actor-vortex-sabine | role-production-manager |
| actor-vortex-stefan | role-controller |
| actor-vortex-karl | role-quality-manager |
| actor-vortex-dirk | role-ceo |
| actor-vortex-anna, -nina, -felix, -max, -claudia | (none) |

Assumption (state in script header comment): mapping is from scenario `actors:` blocks
(`test/fixtures/uat/scenarios/{meridian,vortex}/*.yaml`) and
`test/fixtures/simulation/{meridian,vortex}/org_structure.yaml`; thomas->role-cro and
dirk->role-ceo are inferred from org structure/department, not stated verbatim in a
scenario. Role groups are the authoritative part; persona->group is a QA-convenience mapping
that a BA may amend by editing the PERSONAS table only.

## 5. Script behavior (each of the two scripts)

Header comment mirrors swiftroute (prerequisites: curl, jq, `QA_AUTH_TOKEN` of a tenant
PLATFORM_ADMIN with GroupsManage+RolesManage+UsersManage, `QA_URL`, Part A done). Body:
`set -euo pipefail`; define `ROLES`, `PERSONAS`; `source` lib; `persona_require_env`;
`persona_run meridian|vortex`. Missing actor user => abort, exit 1, message names the actor
and Part A. Missing TASK_WORKER => abort with onboarding message. No script
creates users. Token is tenant-scoped by the auth pipeline (no cross-tenant risk).

Edge: a user in several role groups gets one membership call per group; all idempotent.
Edge: `role-ceo` exists in both tenants as separate per-tenant rows (tenant-scoped DB prefix);
no cross-tenant collision.

## 6. Drift-guard test (CI-safe, no QA, no network)

File: `test/scripts/persona_actor_seed_drift_test.exs`
Module: `Letflow.Scripts.PersonaActorSeedDriftTest` (`use ExUnit.Case, async: true`).
Pure file reads plus `System.cmd("bash", ["-n", path])`. Tag `@tag :bash` is not needed
if `uat_preflight_bare_jwt_test.exs` already runs unconditionally; match its convention for
skipping when `bash` is absent (`System.find_executable("bash")`).

Public helpers inside the test module (private functions; signatures only):
- `parse_array(script_source :: String.t(), name :: "ROLES" | "PERSONAS") :: [String.t()]`
  per the section 3 regexes; raises with a clear message if the array is not found (so
  a format break fails loudly, not vacuously).
- `parse_personas(entries :: [String.t()]) :: [{username :: String.t(), roles :: [String.t()]}]`
- `fixture_roles(paths :: [Path.t()]) :: MapSet.t(String.t())` : `Jason.decode!` each
  fixture and recursively collect every value of key `"role"` that is a binary starting with
  `"role-"` anywhere in the document (walk maps/lists), so structural nesting changes do not
  break it.
- `@meridian_fixtures`, `@vortex_fixtures` : the two files each under `test/fixtures/qa/`.

Tests (all four for each tenant, generated via `for tenant <- [...]`):
1. `"<tenant>: seeded ROLES set equals the roles referenced by the QA definitions"`:
   `MapSet.new(parse_array(ROLES)) == fixture_roles(fixtures)`; on mismatch the failure
   message prints both `missing_in_script` and `extra_in_script`. Also asserts ROLES has
   no duplicates and (meridian) has 8, (vortex) has 4 elements (sanity pin).
2. `"<tenant>: every persona role is a seeded role"`: union of PERSONAS roles is a subset
   of ROLES; every persona username matches `~r/^actor-<tenant>-[a-z]+$/` (catches wrong
   tenant prefix); usernames unique; every ROLES entry is held by at least one persona
   (a role nobody holds would leave tasks unclaimable); `"TASK_WORKER"` appears in neither
   table.
3. `"<tenant>: script passes bash -n"`: `System.cmd("bash", ["-n", script])` exit 0; same
   for `scripts/lib/seed_persona_actors_base.sh`.
4. `"<tenant>: script sources the shared lib and calls persona_run"`: regex presence
   check, plus `role-procurement-manager` absent from the vortex script (explicit pin
   with the reason in the assertion message).
5. `"swiftroute script untouched contract"` is NOT added (out of scope).

### Mutation targets for TEST-DESIGNER (each must make the guard FAIL; pre-fix state = files
absent so tests also fail by `File.read!` on a missing path, which counts as the
fail-first)
Tests must apply mutations to an in-memory/temp copy of the script text (via the
`parse_*` helpers taking source strings), never edit repo files:
- M1: remove `"role-loan-ops"` from meridian ROLES -> test 1 fails (missing_in_script).
- M2: add `"role-procurement-manager"` to vortex ROLES -> test 1 fails (extra_in_script)
  and test 4 fails.
- M3: persona entry references a role not in ROLES (e.g. `actor-vortex-karl|role-qa-lead`)
  -> test 2 fails.
- M4: wrong-tenant actor (`actor-meridian-ben` in the vortex PERSONAS) -> test 2 fails
  (prefix regex).
- M5: drop `role-cro` from every meridian persona -> test 2 fails (role held by nobody).
- M6: fixture gains a new role (synthetic temp fixture JSON with an extra `role` node
  passed to `fixture_roles/1`) -> test 1 fails for the unchanged ROLES.
- M7: break shell syntax in a temp copy (`if` without `fi`) -> `bash -n` check fails.
- M8: ROLES array opener renamed (`ROLE=(`) -> `parse_array` raises (format contract).

## 7. `.claude/agents/uat-runner.md` note

Insert after the SwiftRoute persona-actors paragraph (ends line ~225, before
`## Forbidden`):

> **Meridian and Vortex persona actors — run the persona seed scripts after the definition
> seeds.** Process-routing role groups and group memberships for these tenants are NOT
> created by `scripts/seed_meridian_definition.sh` / `scripts/seed_vortex_definition.sh`.
> Before executing any scenario under `test/fixtures/uat/scenarios/meridian/` or
> `.../vortex/`, the target QA instance must have had, in order: (1) the definition seed
> (`seed_<tenant>_definition.sh`), (2) Keycloak accounts for the `actor-<tenant>-*` personas
> (Part A, `ai-dala-infra`), (3) `scripts/seed_<tenant>_persona_actors.sh` with a tenant
> PLATFORM_ADMIN `QA_AUTH_TOKEN`. Detect a missing step 3 with `GET /api/v1/identity/roles`:
> no `role-*` rows of kind `process_routing_role` (e.g. `role-credit-manager` /
> `role-production-manager`), or an empty inbox plus 409 "caller does not hold the assigned
> role" on claim. Record the affected steps BLOCKED/PRECONDITION_MISSING; do not substitute
> actors (ISS-0931).

Add the same one-line precondition to the preflight documentation if it lists seed
scripts (ELIXIR-DEV to grep `docs/` for `seed_swiftroute_persona_actors` and add
the meridian/vortex siblings next to each hit).

## 8. Acceptance-criteria mapping

| Diagnosis item | Element |
|---|---|
| Two new scripts mirroring swiftroute | sections 2, 5 |
| Exact roles = fixtures (8 / 4; no procurement) | section 4, tests 1 and 4 |
| TASK_WORKER for all, idempotent, abort if actor missing | section 2 (`persona_run`, `lookup_user_id`), 5 |
| Shared helper vs duplicate | section 2 decision |
| Machine-parsable tables + drift test | sections 3, 6, mutations M1-M8 |
| uat-runner doc note | section 7 |
| No QA execution, no lib/ change | section 1 |

## 9. Open questions (none blocking)

- OQ-1: Persona-to-group mapping for thomas/eva/dirk is inferred (section 4); BA may amend the
  PERSONAS table; the drift test still holds.
- OQ-2: Keycloak usernames assumed `actor-<tenant>-<name>` per scenario `actors:` blocks and
  ISS-0761 OQ-1; if Part A differs the script aborts cleanly naming the actor.
- OQ-3: Follow-up (separate issue, not filed here): migrate the swiftroute script onto the
  shared lib and extend the same drift guard to it.
- OQ-4: Should CI guarantee `bash`/`jq` presence? Test uses only `bash -n`; skip when bash
  is missing, matching existing script-test convention.

## 10. owned_modules (final)

`scripts/lib/seed_persona_actors_base.sh` (new), `scripts/seed_meridian_persona_actors.sh` (new),
`scripts/seed_vortex_persona_actors.sh` (new), `test/scripts/persona_actor_seed_drift_test.exs`
(new), `.claude/agents/uat-runner.md`, and any `docs/` preflight listing found by grep.
