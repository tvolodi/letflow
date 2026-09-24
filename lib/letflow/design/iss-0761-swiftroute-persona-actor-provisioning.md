# Design: SwiftRoute Persona Actor Provisioning (ISS-0761)

**Issue:** ISS-0739 / ISS-0761  
**Status:** Design  
**Parts in scope:** Part B (`scripts/seed_swiftroute_persona_actors.sh`), Part C
(`.claude/agents/uat-runner.md` update)  
**Part A out of scope:** Keycloak account creation lives in `ai-dala-infra/scripts/qa-login.sh`
— see §1.

---

## §1 Scope and Part A dependency

This script provisions the **letflow-side** of the SwiftRoute persona actors. The
tri-layer gap (ISS-0739) is:

| Layer | Owner | This run? |
|---|---|---|
| **A** — Keycloak accounts for `actor-swiftroute-lena/marco/alice` | `ai-dala-infra/scripts/qa-login.sh` | **No — EXTERNAL** |
| **B** — `tenant_role` rows (process-routing roles) + group memberships in letflow | `scripts/seed_swiftroute_persona_actors.sh` | **Yes** |
| **C** — UAT-RUNNER credential-resolution documentation | `.claude/agents/uat-runner.md` | **Yes** |

**Execution order dependency:** Part A must run before Part B. The script (Part B)
looks up user IDs via `GET /api/v1/identity/users?search=...` — if the Keycloak account
has not yet been provisioned and synced into letflow's `users` table, the lookup
returns an empty `items` array and the script must abort with a clear error message
naming the missing actor. It must NOT attempt to create the user itself.

---

## §2 API payload specifications

All endpoints are mounted under `/api/v1/identity/` (confirmed:
`lib/letflow/plugs/api_pipeline.ex` line 141 `forward("/identity", to:
Letflow.Routers.Identity)`). All calls require:

```
Authorization: Bearer ${QA_AUTH_TOKEN}
Content-Type: application/json
```

The token must be for a user with **PLATFORM_ADMIN** role in the `swiftroute` tenant
(grants `GroupsManage` + `RolesManage` + `UsersManage` — the three policy keys used
by this script's API calls). A PLATFORM_ADMIN token satisfies all three. The token is
tenant-scoped: `Letflow.Plugs.AuthPipeline` derives the DB prefix from the OIDC token's
own tenant claim, so a cross-tenant token cannot provision into the wrong schema.

### 2.1 Group creation — `POST /api/v1/identity/groups`

Request body (schema: `@create_group_schema` in `Letflow.Routers.Identity`):

```json
{
  "name": "role-ops-manager"
}
```

- `name` required, string, 1–255 characters. ELIXIR-DEV may add optional `display_name`
  (string, 1–255) and `description` (string, up to 1000) as human-readable labels — not
  required for function but good practice. Example with optional fields:

```json
{
  "name": "role-ops-manager",
  "display_name": "Ops Manager",
  "description": "Process-routing role for operations managers in the SwiftRoute shipment approval process."
}
```

Response: **201** with `group_map`:

```json
{
  "id": "<uuid>",
  "name": "role-ops-manager",
  "display_name": "Ops Manager",
  "description": "...",
  "created_at": "2026-09-24T07:00:00Z"
}
```

Returns **409** if a group with that `name` already exists
(`{:error, :duplicate_group_name}` → `Response.conflict/2`). The idempotency approach
(§3) pre-checks to skip creation; the script never relies on catching a 409.

### 2.2 Role creation (upsert) — `POST /api/v1/identity/roles`

Request body (schema: `@upsert_role_schema` in `Letflow.Routers.Identity`):

```json
{
  "name": "role-ops-manager",
  "kind": "process_routing_role",
  "group_id": "<group-uuid-from-step-2.1>"
}
```

- `name`: required, non-empty string. For `kind: "process_routing_role"`, no closed-set
  check is applied — only the format constraints (`validate_role_name/1`: non-empty,
  ≤128 Unicode codepoints, no ASCII control chars).
- `kind`: must be exactly `"process_routing_role"` — NOT `"platform_role"`.
- `group_id`: UUID of the group created/found in §2.1.

Response: **200** (upsert semantics — not 201; this is an idempotent write, not a strict
create). Shape: `role_map`:

```json
{
  "id": "<uuid>",
  "name": "role-ops-manager",
  "kind": "process_routing_role",
  "group_id": "<group-uuid>",
  "created_at": "2026-09-24T07:00:00Z"
}
```

`POST /roles` is an upsert (calls `RoleRegistry.upsert_role/4` with
`on_conflict: :nothing`-equivalent semantics): re-calling it with the same `name` and
`group_id` converges without error. **No pre-check is needed for the role step.**

### 2.3 User lookup — `GET /api/v1/identity/users?search=<username>`

```
GET /api/v1/identity/users?search=actor-swiftroute-lena
```

The `search` parameter is a substring match via `Identity.list_users/2`'s `search:`
field (confirmed: `handle_list/2` in `Letflow.Routers.Identity` reads
`Map.get(query, "search")`). Use the full username for precision, e.g.
`search=actor-swiftroute-lena`.

Response: paginated `page_response` shape:

```json
{
  "items": [
    {
      "id": "<user-uuid>",
      "username": "actor-swiftroute-lena",
      "display_name": "Lena (Dispatcher)",
      "email": "...",
      "status": "active",
      "auth_source": "...",
      "inserted_at": "...",
      "updated_at": "..."
    }
  ],
  "next_cursor": null
}
```

If `items` is empty (`[]`), the user has not yet been synced from Keycloak — script must
abort with: `ERROR: user <username> not found. Complete Part A (ai-dala-infra Keycloak provisioning) before running this script.`

Extract the user ID with: `jq -r '.items[0].id // empty'`

### 2.4 Group member addition — `POST /api/v1/identity/groups/:group_id/members`

```
POST /api/v1/identity/groups/<group-uuid>/members
```

Request body (dual-format preserved from R-Co per `handle_add_member/3`):

```json
{
  "user_id": "<user-uuid>"
}
```

Response: **201** if the membership was created; **200** if already a member
(`{:ok, %{member: _, created: false}}`). Both are success responses. The endpoint is
**naturally idempotent** — no pre-check is needed.

---

## §3 Idempotency approach per step

| Step | Idempotency mechanism |
|---|---|
| Create group `role-ops-manager` | `GET /api/v1/identity/groups` → `jq '.items[] \| select(.name=="role-ops-manager") \| .id'`; if non-empty, skip `POST`. Use the existing group's `id`. |
| Create group `role-ceo` | Same pattern: `GET /groups` → filter by `name=="role-ceo"`. |
| Upsert `role-ops-manager` tenant_role binding | `POST /roles` always succeeds (upsert); no pre-check needed. |
| Upsert `role-ceo` tenant_role binding | Same — `POST /roles` upsert. |
| Resolve TASK_WORKER group_id | `GET /api/v1/identity/roles` → `jq '.items[] \| select(.name=="TASK_WORKER") \| .group_id'`. If empty, abort: `ERROR: TASK_WORKER platform role not seeded. Run tenant onboarding (RoleRegistry.seed_default_platform_role_groups/1) for the swiftroute tenant before running this script.` |
| Add marco → role-ops-manager group | `POST /groups/<id>/members` is naturally idempotent (200 if already member). |
| Add alice → role-ceo group | Same. |
| Add lena → TASK_WORKER group | Same. |
| Add marco → TASK_WORKER group | Same. |
| Add alice → TASK_WORKER group | Same. |

`GET /api/v1/identity/groups` returns **all** groups as `{"items": [...], "total": N}` —
there is no `?name=` filter parameter (confirmed: `handle_list_groups/2` calls
`Identity.list_groups(opts)` with no query-param filtering). Use `jq .items[]` with a
`select(.name==...)` filter to find a group by name.

`GET /api/v1/identity/roles` returns **all** roles as `{"items": [...]}` — same
pattern (confirmed: `handle_list_roles/2` calls `RoleRegistry.list_roles(opts)` with no
filter).

---

## §4 Persona-to-role mapping

| Actor username | Persona | Groups to join | Rationale |
|---|---|---|---|
| `actor-swiftroute-lena` | Dispatcher | `TASK_WORKER` | Needs `InstancesStart` + `TasksRead` for API calls. Does not complete HUMAN_TASK ops-review (that is Marco's role); no process-routing role needed. |
| `actor-swiftroute-marco` | Ops Manager | `TASK_WORKER`, `role-ops-manager` | `TASK_WORKER` for API access; `role-ops-manager` process-routing role binds the `HUMAN_TASK ops-review` lane to Marco in the workflow engine transition lookup. |
| `actor-swiftroute-alice` | CEO | `TASK_WORKER`, `role-ceo` | `TASK_WORKER` for API access; `role-ceo` process-routing role binds the CEO co-sign lane. |

**TASK_WORKER** is a `kind: "platform_role"` binding, seeded at tenant-onboarding time
by `RoleRegistry.seed_default_platform_role_groups/1` (ISS-0778). Its group is named
`"TASK_WORKER"` (from `Atom.to_string(:TASK_WORKER)`). The script must NOT attempt to
create this group or role binding — it only reads the existing group's UUID (§3) and
adds memberships.

**role-ops-manager** and **role-ceo** are `kind: "process_routing_role"` bindings
created by this script. The workflow engine's `resolveRoleInTx` looks up these names at
transition time; the names must match the `role` literals in the process definition
exactly.

---

## §5 `.claude/agents/uat-runner.md` update

Add the following subsection immediately after the last paragraph of the **"Environment
target"** section (after the Bilimbaga `?realm=bilimbaga` note, before **"## Forbidden"**):

---

**SwiftRoute persona actors — three-layer credential setup required.** The SwiftRoute
narrative UAT corpus (`test/fixtures/uat/scenarios/swiftroute/*.yaml`) uses three named
persona actors — `actor-swiftroute-lena` (Dispatcher), `actor-swiftroute-marco` (Ops
Manager), `actor-swiftroute-alice` (CEO) — that are **not** present in
`ai-dala-infra/scripts/qa-login.sh`'s generic platform-role user set. Resolving these
actors to credentials requires **all three** of the following to have been completed
against the target QA instance, in order:

1. **Part A (external):** `ai-dala-infra/scripts/qa-login.sh` — Keycloak account
   creation for `actor-swiftroute-lena`, `actor-swiftroute-marco`,
   `actor-swiftroute-alice` in the `swiftroute` realm. This is owned by the
   `ai-dala-infra` repository; letflow has no control over it.

2. **Part B:** `scripts/seed_swiftroute_persona_actors.sh` — idempotent letflow-side
   provisioning: creates the `role-ops-manager` and `role-ceo` process-routing role
   groups and tenant_role bindings, then adds each actor to their appropriate group(s).
   Run this against the same QA instance (export `QA_AUTH_TOKEN` first — a PLATFORM_ADMIN
   token for the swiftroute tenant, same pattern as
   `scripts/seed_swiftroute_definition.sh`).

3. **Part C (this note):** documented here so UAT-RUNNER knows where to look.

If a WF-05 dispatch targets a SwiftRoute persona scenario and these steps have not all
been completed, record the affected `gui:` steps BLOCKED/CREDENTIALS_MISSING rather than
substituting a different actor or inventing a workaround — the gap is real and tracked
(ISS-0739/ISS-0761). Specifically: if
`GET /api/v1/identity/users?search=actor-swiftroute-lena` returns an empty `items`
array against the target instance, Part A is not done; if the actor is resolvable but
`GET /api/v1/identity/roles` has no `role-ops-manager` row, Part B has not been run.

---

*(End of text to insert into uat-runner.md)*

---

## §6 Verification step

After the script completes, run these calls to confirm the setup:

```bash
# 1. Confirm role-ops-manager and role-ceo tenant_role rows exist
curl -sf -H "Authorization: Bearer ${QA_AUTH_TOKEN}" \
  "${QA_URL}/api/v1/identity/roles" | \
  jq '[.items[] | select(.name == "role-ops-manager" or .name == "role-ceo")]'
# Expected: array of 2 items, each with kind == "process_routing_role"

# 2. Confirm marco is a member of role-ops-manager group
# (get group_id from step 1 output, then:)
curl -sf -H "Authorization: Bearer ${QA_AUTH_TOKEN}" \
  "${QA_URL}/api/v1/identity/groups/${OPS_MGR_GROUP_ID}/members" | \
  jq '[.items[] | select(.username == "actor-swiftroute-marco")]'
# Expected: 1 item

# 3. Confirm alice is a member of role-ceo group
curl -sf -H "Authorization: Bearer ${QA_AUTH_TOKEN}" \
  "${QA_URL}/api/v1/identity/groups/${CEO_GROUP_ID}/members" | \
  jq '[.items[] | select(.username == "actor-swiftroute-alice")]'
# Expected: 1 item

# 4. Confirm lena, marco, alice are all TASK_WORKER members
curl -sf -H "Authorization: Bearer ${QA_AUTH_TOKEN}" \
  "${QA_URL}/api/v1/identity/groups/${TASK_WORKER_GROUP_ID}/members" | \
  jq '[.items[] | select(.username | test("actor-swiftroute-(lena|marco|alice)"))]'
# Expected: 3 items
```

The script itself should emit these checks (or equivalent) as a "Verification" section
at the end, in the same style as `seed_swiftroute_definition.sh`'s AC1/AC2/AC3
verification echo lines.

---

## §7 Open questions

**OQ-1 (ELIXIR-DEV must resolve before implementing): Username format for Part A
actors.** This design assumes the usernames are exactly `actor-swiftroute-lena`,
`actor-swiftroute-marco`, `actor-swiftroute-alice` (read directly from the scenario
corpus: `test/fixtures/uat/scenarios/swiftroute/shipment-high-value-happy.yaml`
`actors:` section). ELIXIR-DEV must confirm that `ai-dala-infra/scripts/qa-login.sh`'s
Part A provisioning uses these exact usernames before implementing the `search=` queries.
If the Keycloak username format differs (e.g. `swiftroute-lena` without the `actor-`
prefix), update the `search=` parameter accordingly. The `search` param is a substring
match, so `search=swiftroute-lena` would find `actor-swiftroute-lena` if it exists — but
be precise enough to avoid false matches from other tenants' users in the same DB schema.

**OQ-2 (ELIXIR-DEV judgment call): `display_name` and `description` for the two
process-routing role groups.** The issue does not specify these. Suggested defaults:
`role-ops-manager` → `display_name: "Ops Manager"`, `role-ceo` → `display_name: "CEO"`.
ELIXIR-DEV may use these or omit the optional fields entirely (the API accepts a
name-only body).

**OQ-3 (non-blocking, for REVIEWER's awareness): TASK_WORKER group name casing.** The
group is seeded as `"TASK_WORKER"` (`Atom.to_string(:TASK_WORKER)`) by
`RoleRegistry.seed_default_platform_role_groups/1` (ISS-0778). If a QA instance was
seeded before ISS-0778 shipped and the TASK_WORKER group name differs, the `GET /roles`
lookup will fail and the script will abort cleanly (§3). This is a correct, safe failure
mode — not a silent mis-assignment.

**OQ-4 (non-blocking): Whether the script needs a dedicated `QA_PLATFORM_ADMIN_TOKEN`
variable or can reuse `QA_AUTH_TOKEN`.** The existing
`scripts/seed_swiftroute_definition.sh` uses `QA_AUTH_TOKEN` for a tenant-scoped
PLATFORM_ADMIN user. This script needs the same permissions (`GroupsManage`,
`RolesManage`, `UsersManage`) — all granted by PLATFORM_ADMIN. ELIXIR-DEV should use the
same `QA_AUTH_TOKEN` variable name for consistency with the sibling script, documenting
that a PLATFORM_ADMIN-role token is required.
