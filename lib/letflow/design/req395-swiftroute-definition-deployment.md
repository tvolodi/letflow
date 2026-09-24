# REQ-395 — SwiftRoute ProcessDefinition Deployment on QA

**Requirement:** REQ-395  
**Stage:** S7  
**Design author:** CODE-DESIGNER  
**Status:** DRAFT — pending CODE-DESIGN-VALIDATOR sign-off

---

## §1 Deployment mechanism choice + rationale

### Chosen: shell script invoking the live QA HTTP API (two `curl` calls)

**Script location:** `scripts/seed_swiftroute_definition.sh` (new file, ELIXIR-DEV creates it).

**Steps the script performs:**

1. `POST /api/v1/definitions` with the payload in §2 → receives 201 with `id` in the response body.
2. Extract `id` from the response (via `jq .id`).
3. `POST /api/v1/definitions/{id}/activate` (no request body) → receives 200.

**Why not Option A (mix task)**

Would require an Elixir toolchain pointed at the QA runtime environment and a mechanism to pass a QA Keycloak token into a Mix task. Adds a dependency on Elixir being installed at deploy time for a one-shot seed operation. The API is the authoritative interface and bypassing it is a worse correctness story.

**Why not Option C (Ecto direct / DB insert)**

Requires knowing the tenant's Postgres schema name (which is derived from the tenant_id UUID, not the slug), bypasses graph validation (`Definitions.create/2`'s `validate_graph/1` / `validate_node_attributes/1` / `validate_edge_conditions/1` pipeline), and violates INV-RT-1 for any operation touching `lib/letflow/routers/`. DB-direct is strictly inferior here.

**Why not Option D (import endpoint)**

`POST /api/v1/definitions/import` works but requires `bpm_export_schema_version` and wraps an `ExportDocument` shape. `POST /api/v1/definitions` (plain create) is simpler and requires no envelope.

**Deployment trigger**

The script is a one-shot, idempotent-with-a-guard seed: it calls `GET /api/v1/definitions/active/Shipment%20Approval` first; if a 200 is returned the script exits with a message "already deployed, skipping." If 404, it proceeds with the two-step create+activate flow.

**Idempotency note**

`Definitions.create/2` enforces `UNIQUE(name, version, tenant_schema)`, so a duplicate `POST /api/v1/definitions` would return 409 anyway. The pre-flight check is a UX guard, not the only safety net.

---

## §2 ProcessDefinition payload

### 2.1 Create (DRAFT) — POST /api/v1/definitions

Request body (application/json):

```json
{
  "name": "Shipment Approval",
  "version": "1.0",
  "description": "Sequential approval chain for high-value or non-standard shipments. Dispatcher raises the request; Operations Manager reviews; if value exceeds 500 the CEO must co-sign. Exercises: sequential chain + CEL conditional branch.",
  "graph": {
    "nodes": [
      {
        "id": "start",
        "node_type": "START"
      },
      {
        "id": "ops-review",
        "node_type": "HUMAN_TASK",
        "attributes": {
          "role": "role-ops-manager",
          "escalation_timer_duration": "PT2H",
          "escalation_role": "role-ceo"
        }
      },
      {
        "id": "ceo-approval-gate",
        "node_type": "EXCLUSIVE_GATEWAY"
      },
      {
        "id": "ceo-approval",
        "node_type": "HUMAN_TASK",
        "attributes": {
          "role": "role-ceo"
        }
      },
      {
        "id": "release-shipment",
        "node_type": "SERVICE_TASK",
        "attributes": {
          "endpoint": "POST /internal/shipments/{shipment_id}/release",
          "timeout_ms": 300000
        }
      },
      {
        "id": "auto-reject",
        "node_type": "SERVICE_TASK",
        "attributes": {
          "endpoint": "POST /internal/shipments/{shipment_id}/reject",
          "timeout_ms": 300000
        }
      },
      {
        "id": "notify-requester",
        "node_type": "SERVICE_TASK",
        "attributes": {
          "endpoint": "POST /webhooks/notify",
          "timeout_ms": 300000
        }
      },
      {
        "id": "end-approved",
        "node_type": "END"
      },
      {
        "id": "end-rejected",
        "node_type": "END"
      }
    ],
    "edges": [
      { "id": "e0",                  "source": "start",              "target": "ops-review" },
      { "id": "e1",                  "source": "ops-review",         "target": "ceo-approval-gate", "condition": "variables.ops_decision == 'approve'" },
      { "id": "e2",                  "source": "ops-review",         "target": "notify-requester",  "condition": "variables.ops_decision == 'reject'" },
      { "id": "fallback-ops-review", "source": "ops-review",         "target": "ceo-approval" },
      { "id": "e3",                  "source": "ceo-approval-gate",  "target": "ceo-approval",      "condition": "variables.declared_value > 500" },
      { "id": "e4",                  "source": "ceo-approval-gate",  "target": "release-shipment",  "condition": "variables.declared_value <= 500" },
      { "id": "e5",                  "source": "ceo-approval",       "target": "release-shipment",  "condition": "variables.ceo_decision == 'approve'" },
      { "id": "e6",                  "source": "ceo-approval",       "target": "auto-reject",       "condition": "variables.ceo_decision == 'reject'" },
      { "id": "timeout-ceo-approval","source": "ceo-approval",       "target": "auto-reject" },
      { "id": "e7",                  "source": "release-shipment",   "target": "end-approved" },
      { "id": "e8",                  "source": "auto-reject",        "target": "end-rejected" },
      { "id": "e9",                  "source": "notify-requester",   "target": "end-rejected" }
    ]
  }
}
```

**Source of truth:** `test/fixtures/simulation/swiftroute/process_route_approval.yaml`, as updated by REQ-396 (`escalation_timer_duration`/`escalation_role` on `ops-review`; `fallback-ops-review` edge target changed to `ceo-approval`). ELIXIR-DEV must read that file immediately before writing the script and reconcile any later changes.

**Node-type strings** are SCREAMING_SNAKE_CASE as required by `Graph.@node_type_map` (`lib/letflow/definitions/graph.ex`).

**Edge `condition` single-quote syntax** (`'approve'`) is present in the simulation fixture and passes the `validate_edge_conditions/1` + `translate_cel_to_expr/1` strict grammar check (req206_swiftroute_test.exs passes with this exact YAML). ELIXIR-DEV must not convert single quotes to double quotes without confirming the CEL translator accepts both forms.

**Fallback edges** (`fallback-ops-review`, `timeout-ceo-approval`) have no `condition` key — this is correct; they satisfy CHK-HUMAN_TASK-FALLBACK (`human_task_no_fallback_edge` check in the graph validator).

### 2.2 Activate — POST /api/v1/definitions/{id}/activate

No request body. Route: `authz_post "/:id/activate", :DefinitionsActivate` in `lib/letflow/routers/definitions.ex`.

Expected response: 200 with a `definition_map/1` body (`id`, `name`, `version`, `status: "ACTIVE"`, …).

---

## §3 QA tenant prerequisites

### 3.1 Tenant existence

The `swiftroute` tenant must be provisioned on the QA instance at slug `swiftroute` before the definition can be deployed. All definition and instance API calls are tenant-scoped via the authenticated user's OIDC token; `Letflow.Api.Context.scoped_repo_opts/1` derives `prefix:` from `conn.assigns[:auth_context][:tenant_id]` only — there is no header or path parameter for tenant override.

**If the tenant does not exist on QA:** ELIXIR-DEV must provision it via `POST /api/v1/tenants` (PLATFORM_ADMIN token) with `slug: "swiftroute"`, `display_name: "SwiftRoute Ltd"`, and an appropriate admin email. This is a prerequisite step for the script, not a design change. Whether this tenant already exists on QA is **OQ-1** (see §6).

### 3.2 Bearer token source

The deploy script requires a Bearer token obtained from QA's Keycloak instance for a user who is a member of the `swiftroute` tenant and holds at minimum:

- `DefinitionsWrite` — required for `POST /api/v1/definitions` and `POST /api/v1/definitions/:id/activate`

For the AC2/AC3 verification procedure (§4.2 and §4.3), the verifying caller additionally requires:

- `InstancesStart` — required for `POST /api/v1/instances`
- `TasksList` — required for `GET /api/v1/tasks`
- `TasksComplete` — required for `POST /api/v1/tasks/:id/complete`

A `PLATFORM_ADMIN` token satisfies all four (the `PLATFORM_ADMIN` role's permission catch-all covers every route). A `PROCESS_OPERATOR` token satisfies `DefinitionsWrite`, `InstancesStart`, `TasksList`, and `TasksComplete` and is an equally valid choice.

**OQ-2 (see §6):** What QA Keycloak account holds `DefinitionsWrite` (and, for AC2/AC3, also `InstancesStart`/`TasksList`/`TasksComplete`) in the `swiftroute` tenant? No seeded QA personas exist for Lena/Marco/Alice (ISS-0739). ELIXIR-DEV must confirm which account to use before running the script.

### 3.3 API base URL

`https://qa.bizdala.com/api/v1` — as documented for the QA instance in `deploy/redeploy-qa.sh` (nginx proxy, Cloudflare TLS, app container at `127.0.0.1:3201`). All curl calls in the script use this base.

---

## §4 Verification procedure per AC

### 4.1 AC1 — definition exists and is reachable via list API

**Pre-condition:** Script in §1 completed without error (definition created DRAFT, then activated).

**Call:**
```
GET /api/v1/definitions?name=Shipment+Approval&status=active
Authorization: Bearer <QA_TOKEN>
```

**Expected response** (200):
```json
{
  "items": [
    {
      "id": "<uuid>",
      "name": "Shipment Approval",
      "version": "1.0",
      "status": "ACTIVE",
      ...
    }
  ],
  "next_cursor": null
}
```

**Pass condition:** `items` array has exactly one entry; `items[0].name == "Shipment Approval"`, `items[0].version == "1.0"`, `items[0].status == "ACTIVE"`. ELIXIR-DEV must quote the actual response body (not summarize it) in the verification report.

### 4.2 AC2 — declared_value: 750 → ops-review task then ceo-approval task

All calls use the same QA tenant Bearer token. `<DEFINITION_ID>` is the id returned in AC1.

**Step 1 — submit instance:**
```
POST /api/v1/instances
Authorization: Bearer <QA_TOKEN>
Content-Type: application/json

{
  "definition_id": "<DEFINITION_ID>",
  "initial_variables": { "declared_value": 750 }
}
```
Expected response: 201 `{ "instance_id": "<INSTANCE_ID>", "status": "ACTIVE", "created_at": "..." }`.

**Step 2 — verify pending ops-review task:**
```
GET /api/v1/tasks?instance_id=<INSTANCE_ID>&status=PENDING
Authorization: Bearer <QA_TOKEN>
```
Pass condition: `items` has exactly 1 entry; `items[0].node_id == "ops-review"`.

**Step 3 — complete ops-review (approve):**
```
POST /api/v1/tasks/<OPS_REVIEW_TASK_ID>/complete
Authorization: Bearer <QA_TOKEN>
Content-Type: application/json

{ "ops_decision": "approve" }
```
Expected response: 200 (task completed, engine advances token through e1 → ceo-approval-gate → e3 because declared_value 750 > 500 → ceo-approval HUMAN_TASK activated).

**Step 4 — verify pending ceo-approval task:**
```
GET /api/v1/tasks?instance_id=<INSTANCE_ID>&status=PENDING
Authorization: Bearer <QA_TOKEN>
```
Pass condition: `items` has exactly 1 entry; `items[0].node_id == "ceo-approval"`.

**AC2 PASS** when all four steps return the expected responses and ELIXIR-DEV quotes actual response bodies.

### 4.3 AC3 — declared_value: 400 → no ceo-approval task

**Step 1 — submit instance (new instance; do not reuse AC2's):**
```
POST /api/v1/instances
Authorization: Bearer <QA_TOKEN>
Content-Type: application/json

{
  "definition_id": "<DEFINITION_ID>",
  "initial_variables": { "declared_value": 400 }
}
```
Expected response: 201 `{ "instance_id": "<INSTANCE_ID_B>", "status": "ACTIVE", ... }`.

**Step 2 — verify pending ops-review task:**
```
GET /api/v1/tasks?instance_id=<INSTANCE_ID_B>&status=PENDING
Authorization: Bearer <QA_TOKEN>
```
Pass condition: `items` has exactly 1 entry; `items[0].node_id == "ops-review"`.

**Step 3 — complete ops-review (approve):**
```
POST /api/v1/tasks/<OPS_REVIEW_TASK_ID_B>/complete
Authorization: Bearer <QA_TOKEN>
Content-Type: application/json

{ "ops_decision": "approve" }
```
Expected response: 200 (token advances through e1 → ceo-approval-gate → e4 because declared_value 400 ≤ 500 → release-shipment SERVICE_TASK; no HUMAN_TASK activation).

**Step 4 — confirm no ceo-approval task exists:**
```
GET /api/v1/tasks?instance_id=<INSTANCE_ID_B>&status=PENDING
Authorization: Bearer <QA_TOKEN>
```
Pass condition: `items` is empty (`[]`) — no ceo-approval task was ever activated.

**AC3 PASS** when all four steps return the expected responses and ELIXIR-DEV quotes actual response bodies.

---

## §5 AC traceability table

| AC | Requirement text (summary) | Design element that satisfies it |
|----|---------------------------|----------------------------------|
| AC1 | ProcessDefinition "Shipment Approval" v1.0 is live and ACTIVE on QA swiftroute tenant, confirmed via `GET /api/v1/definitions` (not direct DB) | §1 deployment script creates + activates the definition; §4.1 specifies the exact GET call and pass condition |
| AC2 | Instance with `declared_value: 750` → PENDING ops-review task, then PENDING ceo-approval task | §2 payload (e3: declared_value > 500 routes to ceo-approval); §4.2 four-step procedure with exact API calls |
| AC3 | Instance with `declared_value: 400` → no ceo-approval task | §2 payload (e4: declared_value ≤ 500 routes to release-shipment, bypasses ceo-approval); §4.3 four-step procedure |
| AC4 | [DEFERRED] UAT-RUNNER re-runs scenario with real Lena/Marco/Alice logins | Out of scope until ISS-0739 closes; not designed here |

---

## §6 Open questions

**OQ-1 — swiftroute tenant existence on QA**  
Whether a tenant with slug `swiftroute` already exists on `qa.bizdala.com`. If not, ELIXIR-DEV must provision it (via `POST /api/v1/tenants` as PLATFORM_ADMIN) before running the seed script. The simulation fixture specifies `slug: swiftroute, display_name: SwiftRoute Ltd` (`test/fixtures/simulation/swiftroute/company.yaml`); the QA tenant should match. ELIXIR-DEV must confirm actual QA state (e.g. `GET /api/v1/tenants?slug=swiftroute`) before proceeding.

**OQ-2 — QA Keycloak account for swiftroute DefinitionsWrite + TasksComplete**  
No seeded QA logins exist for the SwiftRoute personas (Lena/Marco/Alice) — that is ISS-0739's scope. ELIXIR-DEV must identify which QA account holds `DefinitionsWrite` (for the deployment step) and `InstancesStart`/`TasksList`/`TasksComplete` (for the AC2/AC3 verification steps) in the swiftroute tenant. Candidates: a platform-admin service account, or a PROCESS_OPERATOR account seeded separately from the persona accounts. If no such account exists, ELIXIR-DEV must create one (via Keycloak admin or `POST /api/v1/identity/users` if that route exists) as a prerequisite and document it in the verification report.

**OQ-3 — CEL single-quote string compatibility on QA**  
The conditions in the payload use single-quoted string literals (e.g. `variables.ops_decision == 'approve'`), matching the fixture YAML exactly. This passes `validate_edge_conditions/1`'s strict grammar check (`translate_cel_to_expr/1`) in the local test environment (req206_swiftroute_test.exs passes). ELIXIR-DEV must confirm the same behaviour on QA at activation time (HTTP 200 from `/activate`, not a 422 graph-validation error) and, if a 422 is returned, report which CEL violation is raised and file a new issue rather than silently substituting double quotes.

**OQ-4 — escalation_timer_duration validation on QA code version**  
REQ-396 (done, merged 2026-09-23) adds `escalation_timer_duration`/`escalation_role` attribute validation to `HUMAN_TASK` nodes. If QA is running a pre-REQ-396 image, the activation call will either (a) succeed silently (attributes stored but unvalidated) or (b) fail with an unexpected violation. ELIXIR-DEV must confirm the QA deployment includes REQ-396's changes; if not, redeploy first.
