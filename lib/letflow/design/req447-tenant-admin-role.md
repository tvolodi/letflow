# REQ-447 / Q-964 / GH #2235 -- TENANT_ADMIN role, PLATFORM_ADMIN only in the platform tenant, migration of existing tenant admins and API tokens

Status: DESIGN (CODE-DESIGNER). Written against `origin/main` 256587a8 (worktree `wt964`, branch `feat/REQ-447-tenant-admin-role`). Design only: signatures, type shapes, algorithms in prose, tables, invariants. No implementation code, no tests, no lib edits.

Companion artefact (separate file, to be committed with PR 1): `lib/letflow/design/req447-infra-realm-mapping.md` (exact realm-side mapping contract for infra).

Authority: decision `docs/migration/decisions/0046-admin-scopes-and-role-charter.md` D2, D4, D5, D8 (REQ-445 wrote it; "the role-charter decision record" REQ-447 refers to) and its appended correction/closure sections; `docs/roles.md` (matrix, TARGET state); `lib/letflow/design/iss0993-platform-scope-separation.md` (platform tenant, scope facts, conflict C6, INV-10). Where this design departs from the REQ-447 text as written, the departure is listed in section 9 and is FLAGGED for ORCH/user acknowledgement. Nothing here silently re-decides a decision record.

---

## 0. Summary of what is proposed

1. REQ-447 lands as TWO pull requests, ordered by the "code first with backwards compatibility, then the infra migration, then removal of the legacy honouring" rule:
   * **PR 1 (additive + migration tooling).** The `TENANT_ADMIN` role and its grant rule; seeding of a `TENANT_ADMIN` group and binding in every tenant and NO seeding of `PLATFORM_ADMIN` outside the platform tenant; the idempotent migration (`mix letflow.migrate_tenant_admins`, run on a deployed container through the release `rpc`, NOT through Mix, section 5) which rewrites members AND API tokens carrying `PLATFORM_ADMIN`, and the fix of the existing backfill; the realm file; the widened `POST /roles` guard for every built-in role name (H2, an addition, section 3.6); the platform-escalation guards that stop a platform-tenant `TENANT_ADMIN` from becoming `PLATFORM_ADMIN` (3.6b, an addition); doc and test updates for "six roles" statements. PR 1 is merged only AFTER Q-1008 / ISS-1026 (gate G0, section 2.1). A legacy `PLATFORM_ADMIN` in a non-platform tenant is STILL honoured for tenant-scope permissions in its own tenant through the EXISTING C6 switch `Authorization.tenant_platform_admin_own_tenant_powers?/0` (default ON). No new switch is introduced.
   * **PR 2 (after the QA infra migration is verified).** Removal of the legacy honouring: PLATFORM_ADMIN is dropped when resolving a caller's roles outside the platform tenant; `RoleRegistry.upsert_role/4` rejects it; `Identity.create_token/3` rejects it; the C6 switch is deleted; the claim-sync resolver ignores it outside the platform tenant. Then the status flip of REQ-447.
2. The migration NEVER runs without a verified platform-tenant pin (a missing pin would turn the operator tenant into "an ordinary tenant" and strip its operator). It supports `--dry-run`, converts each tenant in its own transaction, continues past a failed tenant, and lists affected tenants with their realm ids so infra knows which realms to change.
3. BUILDS item 8 (investigation): the onboarding wizard's named administrator is granted NOTHING by the backend; the ISSUE is filed separately as Q-1012 / GH #2312 / ISS-1030 (section 7).
4. Findings beyond the REQ text that need an owner decision (sections 9 and 12): the widened `POST /roles` guard for every built-in name (H2, 3.6); the platform-escalation guards that stop a platform-tenant `TENANT_ADMIN` from becoming `PLATFORM_ADMIN` (3.6b, SECURITY-REVIEWER F1); the gate G0 on ISS-1026 / Q-1008 / GH #2305 (R10); the PR 2 entry gate G2 as dated evidence (5.6).

---

## 1. Facts established from the code (file:line, `origin/main` 256587a8)

| # | Fact | Evidence |
|---|---|---|
| F1 | Six roles today; role strings parsed by exact match, anything else drops to no role. | `lib/letflow/api/authorization.ex:376-383` (`@roles`), `597-603` (`role_from_string/1`), `568-577` (`roles_from_strings/1`) |
| F2 | The grant rule is a per-role clause; `PLATFORM_ADMIN` is an unconditional catch-all; `CANDIDATE` and `AGENT_RUNNER` fall through to the Catalog. `:MyModulesRead` is the first clause for every role. | `authorization.ex:1292-1296`, `1301`, `1303-1427` |
| F3 | Permission scope table: `@platform_permissions [:TenantsManage, :PlatformServicesManage]`; every other core permission and every Catalog permission is tenant scope; any other atom (including `:Unknown`) is `:platform` (fail closed). | `authorization.ex:434-442`, `501-512` |
| F4 | `evaluate_access/2` denies `:Unknown` for every role; the `:platform` branch needs `platform_tenant? == true` AND `PLATFORM_ADMIN`; the `:tenant` branch removes `PLATFORM_ADMIN` from the roles when `platform_tenant?` is false AND the C6 switch is off. | `authorization.ex:1060-1061`, `1087`, `1240-1254` |
| F5 | C6 switch: `Application.get_env(:letflow, :tenant_platform_admin_own_tenant_powers, true) != false`, default ON. | `authorization.ex:525-527` |
| F6 | `is_task_worker_only?/1` excludes `PLATFORM_ADMIN`, `PROCESS_DESIGNER`, `PROCESS_OPERATOR`; a `TENANT_ADMIN` + `TASK_WORKER` holder would be row-filtered to its own tasks unless this is extended. | `authorization.ex:1104-1109` |
| F7 | `TenantStatus` exempts the deactivated-tenant gate ONLY for `platform_scope?` (platform tenant AND `PLATFORM_ADMIN`). Nothing in it names any other role, so `TENANT_ADMIN` already has no exemption: BUILDS item 5 needs a test, not a code change. | `lib/letflow/plugs/tenant_status.ex:94-110` |
| F8 | `RoleRegistry.seed_default_platform_role_groups/1`, `upsert_role/4` and the claim-sync resolver take only `prefix:` (the tenant schema name). The tenant id is recoverable from a schema name purely, with no database access, by `TenantProvisioning.tenant_id_for_schema_name/1`. | `lib/letflow/identity/role_registry.ex:75-144`, `lib/letflow/tenant_provisioning.ex:243-256`; `Identity.resolve_group_ids_for_role_names/2` at `identity.ex:938` |
| F9 | `Identity.create_token/3` validates roles against `@issuable_token_roles`, a compile-time list from `Authorization.roles/0`, so adding the atom makes `TENANT_ADMIN` issuable automatically. It has no tenant parameter. | `identity.ex:1347`, `1394-1417` |
| F10 | OIDC callers' roles are database-derived on EVERY request: `group_members` joined to `tenant_role` (`kind == :platform_role`). The token's own role claims are copied into `group_members` ONCE (when `role_claims_synced_at` is nil), additive only, and only for names that have a `tenant_role` binding. API-token callers' roles are the strings stored on the token row. | `identity.ex:807-820`, `851-920`, `938-949`; `plugs/auth_pipeline.ex:361`, `146`, `1587-1625` (`verify_api_token`) |
| F11 | Both authentication branches converge on one point that stores the roles into `auth_context`: `attach_auth_context/4`. `Letflow.Plugs.Authorize` and `routers/entities.ex` re-parse `auth_context.roles` into an `AccessContext`. | `auth_pipeline.ex:370-383`; `plugs/authorize.ex:113-121`; `routers/entities.ex:2237-2240` (this one does not set `platform_tenant?`, default false) |
| F12 | `tenant_role.name` has a UNIQUE index per tenant schema across both kinds; `upsert_role/4` on conflict OVERWRITES `group_id` AND `kind`. A `:process_routing_role` row named `TENANT_ADMIN` would be converted silently by a naive seed. | `priv/repo/migrations/20260816000003_create_tenant_role.exs:31`; `role_registry.ex:313-318` |
| F13 | Existing backfill classifies a tenant as "seeded" when it held fewer than six platform roles (hard-coded 6) and then resets every user's `role_claims_synced_at`; it HALTS the sweep on the first failure. | `lib/letflow/identity/role_backfill.ex:171-173`, `128-163` |
| F14 | `POST /roles` guard H1 refuses the `PLATFORM_ADMIN` name unless the caller has platform scope; `PROCESS_DESIGNER` holds `:RolesManage`; `GET /roles` returns each binding's `group_id`; `upsert_role/4` has no caller-role check. Nothing equivalent protects the `TENANT_ADMIN` name. | `routers/identity.ex:718-733`, `852-860`, `226-231`; `authorization.ex:1311` |
| F15 | The realm test requires the realm file's role list to equal `Authorization.roles/0` exactly, both directions. The realm file defines only the `bpm-default` realm. | `test/letflow/api/authorization_role_realm_test.exs:46-72`; `priv/keycloak/realms/bpm-default.json:10-19,119` |
| F16 | `docs/roles.md` matrix has no row for `PlatformServicesManage` although `core_permissions/0` contains it. | `authorization.ex:422`; `docs/roles.md` matrix block |
| F17 | Tests: 164 files under `test/` mention `PLATFORM_ADMIN`; 75 contain the literal list `["PLATFORM_ADMIN"]`; fixtures that mean "the operator" pin the platform tenant (`Letflow.PlatformTenantFixture.operator_auth_context/3`, `test/support/platform_tenant_fixture.ex:108-117`). | `grep` on the worktree |

---

## 2. PR split

### 2.1 PR 1 -- "TENANT_ADMIN, seeding, migration tooling; legacy PLATFORM_ADMIN still honoured"

**Entry gate G0 (stated, not a suggestion):** PR 1 is merged only after ISS-1026 / Q-1008 / GH #2305 (approve and reject gated by the stored tenant ids, R10 of decision 0046) has merged. Reason: 0046 D3's binding condition for `:PromotionsManage` (and `:PromotionsRead`) being tenant scope requires the source-tenant ownership proof; PR 1 grants `:PromotionsManage` to `TENANT_ADMIN`, including the platform tenant's own `TENANT_ADMIN`, in whose schema operator-created reviews naming foreign tenants live. Q-1005 / ISS-1023 (PR #2309) is already merged. Q-1011 / ISS-1029 is NOT a gate: PR 1 does not wait for it.

Contains: sections 3.1, 3.2 (seeding half), 3.3 (helper), 3.6 (H2, widened), 3.6b (platform-escalation guards), 3.7 (TenantOnboarding), 3.8 (migration), 3.9 (backfill fix), 3.10 (realm file), 3.11 (docs/tests), and the one-line edit of `docs/requirements.yaml` (section 10). Does NOT contain: any rejection or dropping of `PLATFORM_ADMIN` in a non-platform tenant (3.4, 3.5) and does not touch the C6 default.

Behaviour of a legacy `PLATFORM_ADMIN` (stored group membership, stored API-token role, or first-login claim) in a non-platform tenant after PR 1, UNCHANGED from today: tenant-scope permissions in its own tenant only (the C6 interim, ratified 2026-10-06 as "not a departure from D4" in `iss0993-platform-scope-separation.md` section 19 C6 and P4); no platform-scope permission; no `:Unknown`; no deactivated-tenant exemption. PR 1 only STOPS MINTING new ones (not seeded) and provides the tool that converts the existing ones.

### 2.2 PR 2 -- "remove the legacy honouring" (starts only after the dated entry gate G2 in section 5.6)

The gap between PR 1 and PR 2 is kept SHORT: PR 2 is prepared in parallel (its sweep of test fixtures does not depend on QA) and opened the moment gate G2 is evidenced. G2 is DATED EVIDENCE, in the style of A2's dated section 15 entry in the ISS-0993 design: infra's realm migration done, the DB migration verified by a second run, and an evidence window observed (5.6).

Contains: sections 3.4 (reject on write), 3.5 (drop on read and delete the C6 switch), the claim-sync resolver filter, tests that pin the removal, the mechanical test sweep of fixtures that used a tenant `PLATFORM_ADMIN` as an ordinary admin, and the status flip of REQ-447 (DOC-UPDATER, after RELEASE-VALIDATOR).

### 2.3 Acceptance criteria mapped to PRs

| AC | Text (short) | PR | Where in this design |
|---|---|---|---|
| AC1 | seven roles; `role_allows?(:TENANT_ADMIN, p)` exactly when `p` tenant scope for every `p` in `permissions/0`; `:Unknown` denied | PR 1 | 3.1 |
| AC2 | TENANT_ADMIN 2xx on users, groups, roles, tokens, audit, PATCH /tenant/settings, POST /tenant/modules, POST /tenant/solutions, promotions, definition rollback; 403 on /tenants, /onboarding, /platform-migrations, /event-retention | PR 1 | 3.1, 11 (test `tenant_admin_routes_test`) |
| AC3 | new non-platform tenant: TENANT_ADMIN binding, no PLATFORM_ADMIN binding; platform tenant has both | PR 1 | 3.2, 3.3, 3.7 |
| AC4 | non-platform: `upsert_role` PLATFORM_ADMIN rejected; `POST /tokens` PLATFORM_ADMIN refused (HTTP 403 from the router, 3.6b; the invalid-role-set error `{:error, :invalid_role_set}` is reachable only by a direct, internal call of `create_token/3`, asserted by a direct-call unit test); stored or claimed PLATFORM_ADMIN treated as not held (403 on platform route AND no catch-all on tenant routes) | PR 2 | 3.4, 3.5 |
| AC5 | migration test: two PLATFORM_ADMIN members + one token -> both in TENANT_ADMIN, no PLATFORM_ADMIN binding, token carries TENANT_ADMIN; second run no change; platform tenant untouched | PR 1 | 3.8 |
| AC6 | inactive tenant: TENANT_ADMIN halted by `TenantStatus` with 403 `tenant_inactive` | PR 1 (test only, F7) | 3.7a |
| AC7 | realm file contains TENANT_ADMIN; `authorization_role_realm_test.exs` passes unedited | PR 1 | 3.10 |
| AC8 | run report states, with evidence, the wizard administrator's role on first login | PR 1 (evidence in section 7; run report repeats it) | 7 |
| AC9 | `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix test`, `mix letflow.check_boundaries`; SECURITY-REVIEWER verdict | each PR | 11 |

BUILDS items mapped to PRs:

| BUILDS item | PR 1 | PR 2 |
|---|---|---|
| 1 role, grant rule, `:Unknown` denied | all | - |
| 2 PLATFORM_ADMIN outside the platform tenant: not seeded | yes (3.2) | - |
| 2 not accepted by `upsert_role/4` as a `:platform_role` binding | - | yes (3.4) |
| 2 not issuable by `create_token/3` (`{:error, :invalid_role_set}`) | partly: the router refuses a `PLATFORM_ADMIN` list without platform scope (3.6b); `create_token/3` itself unchanged | full rule (3.4) |
| 2 dropped when resolving a caller's roles | - | yes (3.5) |
| 3 seeding of TENANT_ADMIN in every tenant | yes | - |
| 4 data migration (a)-(d), including API tokens (d) | yes (3.8) | - |
| 5 TenantStatus, no exemption | test only | - |
| 6 realm file | yes | - |
| 7 "six roles" docs and tests | yes | residual updates found by the PR 2 audit |
| 8 onboarding investigation | report (section 7); issue filed separately (Q-1012) | - |

REQ-447 stays `pending` until PR 2 merges. PR 1's merge closes AC1, 2, 3, 5, 6, 7, 8 only; the requirement is not "done".

---

## 3. Module-level design

### 3.1 `Letflow.Api.Authorization` (PR 1)

Changes, all additive:

* `@roles` gains `:TENANT_ADMIN` as the SEVENTH and last element (order is `docs/roles.md`'s: the six existing roles, then TENANT_ADMIN, then TENANT_AUDITOR in REQ-448). The `role()` type union gains `:TENANT_ADMIN`.
* `role_from_string/1` gains the exact clause `"TENANT_ADMIN" -> :TENANT_ADMIN` (exact match, case-sensitive, like every other clause; `"tenant_admin"` still parses to nothing).
* Grant rule. New private clause of `core_role_allows?/2` for `:TENANT_ADMIN`: true iff `permission_scope(permission) == :tenant`. The `:tenant` answer already covers every core tenant permission and, through `permission_scope/1`, every `Letflow.Modules.Catalog.permissions/0` atom; every other atom (`:Unknown`, platform atoms, unclassified atoms) is `:platform` and therefore denied. The clause must be placed so it matches before the Catalog fallback is consulted; the Catalog `role_grants/1` fallback remains additive and can never remove a grant.
* `:Unknown` is already denied for every role before the matrix (F4); no change, a test pins it for `TENANT_ADMIN`.
* `is_task_worker_only?/1` (F6): add `not has_role?(roles, :TENANT_ADMIN)` so a `TENANT_ADMIN` + `TASK_WORKER` user (the swiftroute admin Alice will be exactly that after migration) gets `task_scope: :all`, not the own-tasks row filter. The same function governs the inbox: `Letflow.Routers.Tasks.build_inbox_assignee_scope/3` (`routers/tasks.ex:256-258`) re-parses `auth_context.roles` and calls `is_task_worker_only?/1`, so `GET /api/v1/tasks/inbox` is unfiltered for a `TENANT_ADMIN` + `TASK_WORKER` caller after this change; the PR 1 test names both `GET /tasks` and `GET /tasks/inbox`. REQ-448 will add `TENANT_AUDITOR` to the same exclusion list.
* `has_permission_in_scope?/3`: no change in PR 1. `TENANT_ADMIN` has no platform-scope grant, so the `:platform` branch (which also requires `PLATFORM_ADMIN` in the roles) can never allow it; the `:tenant` branch never removes it (it removes only `PLATFORM_ADMIN` when the C6 switch is off).
* Docs: moduledoc and `@doc` strings that enumerate six/five roles are updated to seven; the `roles/0` doc names TENANT_ADMIN.

Public surface added to the module: none besides the atom in `roles/0` and `role()`. New specs: none.

### 3.2 `Letflow.Identity.RoleRegistry` -- seeding (PR 1)

* `seed_default_platform_role_groups(opts :: [prefix: String.t()]) :: {:ok, [TenantRole.t()]} | {:error, term()}` keeps its name, arity and return shape. New behaviour: the roles seeded are `seedable_role_names(prefix)`, in `Authorization.roles/0` order.
* New public function `seedable_role_names(prefix :: String.t()) :: [String.t()]` (pure): every name of `Authorization.roles/0` for a platform-tenant schema; every name EXCEPT `"PLATFORM_ADMIN"` for any other schema, including an invalid schema name (fail closed). "Platform-tenant schema" is decided by `Letflow.PlatformTenant.platform_prefix?/1` (3.3).
* `get_or_create_group_by_name/2` and the per-name `upsert_role/4` call are unchanged. The name-collision hazard (F12) is handled by the seeder: if a `tenant_role` row named `TENANT_ADMIN` already exists with `kind == :process_routing_role`, the seed returns `{:error, {:role_name_taken_by_routing_role, "TENANT_ADMIN"}}` and writes nothing for that name (no silent kind conversion). `provision_and_migrate/1` already turns any seed error into `{:role_seeding_failed, reason}` and leaves the tenant `:migrating`; the migration reports it per tenant (3.8).
* `upsert_role/4` in PR 1 is unchanged (still accepts `PLATFORM_ADMIN`; legacy). PR 2 changes it (3.4).

### 3.3 `Letflow.PlatformTenant` -- helper (PR 1)

* New `platform_prefix?(prefix :: term()) :: boolean()`. True iff `TenantProvisioning.tenant_id_for_schema_name(prefix)` returns `{:ok, id}` and `platform_tenant?(id)` is true. Pure, no database access, fail closed (a non-binary, a malformed schema name, no configured pin: false). Same logging rule as the module: it never logs the id.
* No other change. The pin remains `config :letflow, Letflow.PlatformTenant, tenant_id:` filled by `LETFLOW_PLATFORM_TENANT_ID`; there is still no setter.

### 3.4 Rejecting PLATFORM_ADMIN on write outside the platform tenant (PR 2 ONLY)

* `RoleRegistry.upsert_role/4`: when `kind == :platform_role`, `name == "PLATFORM_ADMIN"` and `platform_prefix?(opts[:prefix])` is false, return `{:error, :platform_admin_outside_platform_tenant}` before any `Repo` call. The error joins the `upsert_error()` type. The HTTP mapping in `routers/identity.ex` `upsert_role/5` is exhaustive over the type, so it adds one clause answering 422 with the existing code `name_not_a_recognized_platform_role` (the wire contract of a closed role set does not gain a new public code; H1 at `routers/identity.ex:726` already answers 403 before this is reachable by any non-platform-scope caller, so this clause is defence in depth for non-HTTP callers).
* `Identity.create_token/3`: a roles list containing `"PLATFORM_ADMIN"` while `platform_prefix?(opts[:prefix])` is false returns `{:error, :invalid_role_set}` (the existing error; `POST /tokens` already maps it to 422 `roles_invalid`). `create_token/3` keeps its current behaviour in PR 1 (it has no platform-scope option, B4); the PR 1 scope check lives in the router (3.6b) and runs before this function is called. For an HTTP caller the result is 403 in PR 1 and in PR 2 alike (no caller in a non-platform tenant has platform scope, and in the platform tenant the PR 2 rule does not fire). From PR 2 `invalid_role_set` is therefore reachable only by a direct, internal call of `create_token/3` (the route's 422 `roles_invalid` mapping stays for its other uses); PR 2 asserts it with a direct-call unit test, not an HTTP test. The existing `@issuable_token_roles` stays derived from `Authorization.roles/0`.
* `seed_default_platform_role_groups/1` already stops seeding it in PR 1 (3.2), so PR 2 adds nothing there.
* Claim-sync resolver `Identity.resolve_group_ids_for_role_names/2` (private, `identity.ex:938`): when `platform_prefix?(prefix)` is false, `"PLATFORM_ADMIN"` is removed from the claimed names before the lookup. (A binding could still exist in a tenant the migration has not reached; D2 enforcement point 5 requires the path to refuse.)
* `Identity.add_group_member/3` is NOT given a role check (a group is not a role; the binding is). The binding is what makes a group confer a role, and PR 2 blocks the binding.

### 3.5 Dropping PLATFORM_ADMIN on read, deleting the C6 switch (PR 2 ONLY)

One shared pure function, so every consumer treats a stale row, a token claim and a hand-built context the same way:

* `Authorization.effective_roles(role_strings :: [String.t()] | term(), platform_tenant? :: boolean()) :: [role()]`. Parses with `roles_from_strings/1`; when `platform_tenant?` is not exactly `true`, removes `:PLATFORM_ADMIN`. A non-list input is `[]`.
* Consumers: `Letflow.Plugs.Authorize` (`authorize.ex:113-121`, where `platform_tenant?` is already recomputed per request), `routers/entities.ex` `check_unredacted_permission/2` (`entities.ex:2237`; it must also pass the recomputed `platform_tenant?`, closing the F11 gap), `Letflow.Routers.Tasks.build_inbox_assignee_scope/3` (`routers/tasks.ex:256-258`: it re-parses `auth_context.roles` and calls `is_task_worker_only?/1`; without the drop a non-platform context carrying `PLATFORM_ADMIN` + `TASK_WORKER` would get an UNFILTERED `GET /tasks/inbox`), and `AuthPipeline.attach_auth_context/4` through a string variant `PlatformTenant.effective_role_strings(tenant_id, role_strings) :: [String.t()]` so that `auth_context.roles`, `/me/memberships`, audit and logging also see the dropped list. After the drop, `platform_scope?` is computed from the dropped list (it is only true inside the platform tenant anyway).
* `has_permission_in_scope?/3`: the `:tenant` branch stops consulting `tenant_platform_admin_own_tenant_powers?/0`; the function `tenant_platform_admin_own_tenant_powers?/0` and its config key `:tenant_platform_admin_own_tenant_powers` are deleted; `Letflow.PlatformTenant`'s moduledoc "open decision points" line for C6 is deleted. The existing test "C6: with the interim own-tenant powers switched off ..." in `test/letflow/api/platform_scope_authorization_test.exs:182` is replaced by a test that the function no longer exists and that a non-platform `PLATFORM_ADMIN` is denied tenant-scope permissions.
* `evaluate_access/2` rule 1a for `:UnmatchedRoute` (`authorization.ex:1073-1076`, any `PLATFORM_ADMIN` reaches the router's 404): with the drop in place a non-platform caller no longer holds the role, so the rule needs no edit; a test pins "TENANT_ADMIN gets 403, not 404, on an unmatched ordinary path".

### 3.6 H2: binding any built-in role name on `POST /roles` (PR 1, an ADDITION to the REQ text; widened per letflow-9a and SECURITY-REVIEWER F4)

Finding (F14): a `PROCESS_DESIGNER` holds `:RolesManage`; `GET /roles` shows it the `group_id` of every binding including its own role's group; `POST /roles` (`kind: "platform_role"`, `name: "TENANT_ADMIN"`, `group_id: <the PROCESS_DESIGNER group>`) would re-point the `TENANT_ADMIN` binding at a group the designer belongs to and make every designer a tenant admin, with no `TokensManage`/`UsersGroupsRolesManage` needed. Before this requirement the highest binding target was `PLATFORM_ADMIN` and H1 already blocks it; adding the new top tenant role without the same guard would ship a privilege escalation.

Design: extend H1's predicate family, do not fork it.

* New `Authorization.builtin_role_name?(name :: term()) :: boolean()`: true when the trimmed, upcased name equals the name of ANY atom of `Authorization.roles/0` (so it also covers `TENANT_ADMIN`, `PLATFORM_ADMIN` and the future `TENANT_AUDITOR`), or when `platform_admin_name?/1` is true. Non-binary: false. The deliberately stricter fold is the same as H1's.
* Rule, in `routers/identity.ex` `handle_upsert_role/2`, evaluated BEFORE `RoleRegistry.upsert_role/4` and for ANY `kind` (`tenant_role.name` is unique across kinds and `upsert_role/4` overwrites `kind` and `group_id` on conflict, so a `process_routing_role` post with a built-in name would silently convert the binding): when `builtin_role_name?(name)` is true the caller must hold the permission `:UsersGroupsRolesManage` in this tenant, evaluated through `Authorization.has_permission_in_scope?/3` on the caller's recomputed context (that is `TENANT_ADMIN`, and a legacy tenant `PLATFORM_ADMIN` until PR 2, and a platform-scope operator). `:RolesManage` alone therefore covers only a `process_routing_role` whose name is NOT a built-in name. Failure answers the same fixed 403 body `insufficient permissions` (no role named).
* H1 stays in addition and is stricter for its name: the `PLATFORM_ADMIN` name still needs recomputed platform scope (not just `:UsersGroupsRolesManage`), so a `TENANT_ADMIN` or a legacy tenant `PLATFORM_ADMIN` cannot bind it.
* The migration (3.8) writes bindings through `RoleRegistry` directly, not through this route, so it is unaffected.
* Residual, still recorded as OQ-6: a holder of `:UsersGroupsRolesManage` can still point a built-in binding at any group (that is the permission's meaning for an owner role); the escalation from a lower role is closed.

### 3.6b Platform-escalation guards: a platform-tenant `TENANT_ADMIN` must not become `PLATFORM_ADMIN` (PR 1, REQUIRED by SECURITY-REVIEWER F1 / INV-10; an ADDITION to the REQ text)

Finding. Every tenant, the platform tenant included, gets a `TENANT_ADMIN` binding (AC3), and `TENANT_ADMIN` holds `:TokensManage` and `:UsersGroupsRolesManage`. In the platform tenant that opens two ways to the operator role: (i) `POST /tokens` with `roles: ["PLATFORM_ADMIN"]` (`routers/identity.ex:632`, `Identity.create_token/3`, `identity.ex:1394-1417`) never compares the issued roles with the caller's scope; (ii) `POST /groups/:id/members` (`:GroupsManage`) can add the caller to the group that the `PLATFORM_ADMIN` binding points to (its `group_id` is visible through `GET /roles`). The same two permissions also let a `TENANT_ADMIN` remove operators from that group or deactivate them through `POST /users/:id/status` (denial of service on the operator console). Today only `PLATFORM_ADMIN` holds these permissions in the platform tenant, so none of this was reachable.

Required in PR 1 (all decided by RECOMPUTED platform scope, `Letflow.PlatformTenant.scope_facts_for/1`, never by a stored flag):

* The check lives in the ROUTER, not in `Identity`: `Letflow.Routers.Identity` `handle_create_token/2` (`routers/identity.ex:632`), before it calls `Identity.create_token/3`, refuses a request whose `roles` contain `"PLATFORM_ADMIN"` unless the caller has RECOMPUTED platform scope (`PlatformTenant.scope_facts_for(conn.assigns.auth_context).platform_scope?`), answering the fixed 403 `insufficient permissions` (body names no role). `Identity.create_token/3` and its spec are UNCHANGED in PR 1: no new option, no new error (B4). Direct, internal callers of `create_token/3` (about 17 test files, `test/support/platform_tenant_fixture.ex`, `mix letflow.seed.exam_fixtures`) are therefore not guarded in PR 1; that is acceptable because they are not reachable from a request: the only HTTP path to the function is `POST /tokens`, which the router guards, and an internal caller already runs with the authority of the code that wrote it. PR 2 adds the `:invalid_role_set` rejection outside the platform tenant inside `create_token/3` (3.4) together with the fixture sweep. Consequence in PR 1: a legacy tenant `PLATFORM_ADMIN` can no longer mint a `PLATFORM_ADMIN` token through the route either (it never has platform scope), consistent with "stop minting legacy".
* Protected set, resolved by BINDING, not by group name: the group `G` whose id is the `group_id` of the `tenant_role` row named `PLATFORM_ADMIN` with `kind == :platform_role`, if any. New read functions (types only): `RoleRegistry.platform_admin_group_id(opts :: [prefix: String.t()]) :: {:ok, Ecto.UUID.t()} | :none` and `Identity.platform_admin_member?(user_id :: Ecto.UUID.t(), opts :: [prefix: String.t()]) :: boolean()` (true iff the user belongs to `G`).
* Routes guarded (each answers the fixed 403 `insufficient permissions` unless the caller has recomputed platform scope): `POST /groups/:id/members` and `DELETE /groups/:id/members/:user_id` when `:id` equals `G`; `DELETE /groups/:id` when `:id` equals `G`; `POST /users/:id/status` and `PATCH /users/:id` (the only user-update route; there is no `DELETE /users/:id`) when the target user is a member of `G`; and `DELETE /tokens/:id` when the stored roles of that token contain `PLATFORM_ADMIN` (revoking an operator's API token is the same denial-of-service class as removing a group member; M1). The check runs after the permission gate and before any write, so a denied caller changes nothing. A non-platform tenant's legacy `PLATFORM_ADMIN` group (until the migration deletes its binding) is protected the same way, which only prevents a legacy tenant admin from editing its OWN legacy admins during the PR 1 window; the migration does not use these routes (residual R-W, section 13).
* Reliance, stated: `G` is found through the `PLATFORM_ADMIN` binding. When `RoleRegistry.platform_admin_group_id/1` returns `:none` (no binding) nothing is protected beyond H1, because nothing then confers `PLATFORM_ADMIN`. The group-membership guard is a check followed by a write and is not atomic with it; a concurrent change between the two cannot widen the caller's authority (the permission gate already passed and the target set is fixed by the binding), so the race is accepted.
* Binding via `POST /roles`: a platform-tenant `TENANT_ADMIN` posting the `PLATFORM_ADMIN` name (kinds `platform_role` and `process_routing_role`) is refused 403 by H1 and the binding is unchanged (test below); H1 already requires recomputed platform scope for that name.
* Rejected alternative: "do not honour `TENANT_ADMIN` in the platform tenant". It removes the escalation but contradicts AC3 (the platform tenant has both bindings). Listed here as rejected unless ORCH decides otherwise.
* Tests with a PLATFORM-TENANT `TENANT_ADMIN` caller (section 11): mint a `PLATFORM_ADMIN` token -> 403; add self to the `PLATFORM_ADMIN` group -> 403; remove a platform operator from the group -> 403; deactivate a platform operator (`POST /users/:id/status`) -> 403; `PATCH /users/:id` on an operator -> 403; `DELETE /tokens/:id` of an operator's `PLATFORM_ADMIN` API token -> 403 and the token stays unrevoked; `POST /roles` for the `PLATFORM_ADMIN` name, both kinds -> 403 and the binding unchanged; each leaves the database unchanged. Positive control: the same calls by a platform-scope `PLATFORM_ADMIN` succeed.

### 3.7 `Letflow.TenantOnboarding` and `Letflow.Plugs.TenantStatus` (PR 1)

* `provision_and_migrate/1` and `recover_provisioning/1`: no signature change. `seed_platform_roles/1` calls the changed seeder (3.2), so every tenant, the platform tenant included, gets a `TENANT_ADMIN` group and binding; a non-platform tenant gets no `PLATFORM_ADMIN` group or binding; the platform tenant gets both. Moduledoc and `@doc` lines saying "six" are updated. `Letflow.Routers.Onboarding` is NOT changed (item 8 is report-only).
* (a) `Letflow.Plugs.TenantStatus`: no code change (F7). AC6 is proved by a test: a `TENANT_ADMIN` of an `:inactive` tenant is halted with 403 and body `{"error":"tenant_inactive","detail":"tenant is deactivated"}`; the same caller on an active tenant passes. The moduledoc paragraph that talks about `"PLATFORM_ADMIN"` is left as is except for one added sentence naming `TENANT_ADMIN` as having no exemption.

### 3.8 The migration (PR 1)

New module `Letflow.Identity.TenantAdminMigration`, new mix task `Mix.Tasks.Letflow.MigrateTenantAdmins` (`mix letflow.migrate_tenant_admins`), following the `RoleBackfill` / `mix letflow.backfill_platform_roles` pairing (module holds logic; the task is a thin CLI; on a deployed container, which has NO Mix, the same public function is called through the release `rpc`, see section 5.1 and the runbook in the infra artefact). The migration converts BOTH kinds of legacy holder: GROUP MEMBERS of the `PLATFORM_ADMIN` binding (BUILDS 4b) and API TOKENS whose stored roles carry `PLATFORM_ADMIN` (BUILDS 4d); it is not a members-only tool. The old backfill is NOT reused as the engine because it halts on first failure and resets claim markers; it is only fixed (3.9).

Public API (types only):

* `run(opts :: [dry_run: boolean(), platform_tenant_slug: String.t() | nil, expected_realm_id: String.t() | nil]) :: {:ok, report()} | {:error, {:precondition_failed, :platform_tenant_not_configured | :platform_tenant_not_registered | :platform_tenant_slug_required | :platform_tenant_slug_mismatch | :platform_tenant_realm_required | :platform_tenant_realm_mismatch | :platform_tenant_has_no_operator | :unexpected_error}}`. `run/1` and `verify/0` rescue and catch every exception and exit and map it to an atom tag (`:unexpected_error`); no Postgrex or Ecto message may reach stderr through the rpc wrapper. Under `dry_run: true` the function NEVER returns a precondition error: it returns the report with `preconditions` filled and `would_refuse` listing the reason tags that a real run would refuse with (so the operator sees the state instead of an opaque refusal).
* `report()` = map with keys `dry_run :: boolean()`, `platform_tenant_id :: String.t()`, `migrated :: [tenant_report()]`, `unchanged :: [String.t()]` (tenant ids), `failed :: [%{tenant_id: String.t(), schema_name: String.t(), reason: atom()}]`, `platform_tenant_binding_ensured :: boolean()`, `preconditions :: %{pin_configured: boolean(), realm_matches_expected: boolean() | nil, pin_is_uuid: boolean(), registered: boolean(), pinned_slug: String.t() | nil, pinned_idp_realm_id: String.t() | nil, operator_count: non_neg_integer()}`, `would_refuse :: [atom()]` (dry run only). `reason` is ALWAYS a plain reason tag from the closed set `:role_name_taken_by_routing_role | :platform_admin_name_is_routing_role | :tenant_schema_missing | :unexpected_error`; an exception or a changeset is mapped to `:unexpected_error` and is never stored in the report, never printed, never put in the task output (INV-2, INV-G); at most the logger records the exception MODULE name and the tenant id.
* `tenant_report()` = a map with EXACTLY these keys: `tenant_id :: String.t()`, `slug :: String.t()`, `idp_realm_id :: String.t() | nil`, `tenant_admin_binding_created :: boolean()`, `members_copied :: non_neg_integer()`, `platform_admin_binding_removed :: boolean()`, `tokens_rewritten :: non_neg_integer()`, `tenant_admin_member_count_after :: non_neg_integer()`. A dry run fills every key by the queries of step 8 and a real run by the writes of steps 2-5 (the values are identical on unchanged data); the runbook and the mix task read these keys and nothing else.
* Mix task output: one summary line, then one line per migrated tenant (`slug`, `idp_realm_id`, counts) so infra can see which realms still issue the legacy claim, then one line per failed tenant; exit status 1 when `failed != []` or a precondition fails, 0 otherwise. The failure line prints ONLY `tenant_id` and the reason TAG. Never prints a token, a role binding group id, an exception message or struct, or any user attribute (INV-4, INV-2): only tenant ids, slugs, realm ids, reason tags and counts. The `--dry-run` output starts, before any tenant line, with the pinned tenant's slug, its realm id, its operator count (members of its `PLATFORM_ADMIN` group) and the total number of members and tokens that a real run would convert. Mix task flags: `--dry-run`, `--platform-tenant=<slug>` (maps to `platform_tenant_slug`) and `--expected-realm-id=<id>` (maps to `expected_realm_id`). On a refusal (`{:error, {:precondition_failed, tag}}`) the task prints exactly one line `REFUSED <tag>` (the tag atom only, for example `REFUSED platform_tenant_realm_required` or `REFUSED platform_tenant_realm_mismatch`, likewise the slug, pin and operator tags), writes nothing and exits with status 1; an unexpected error prints `REFUSED unexpected_error` and exits 1. Under `--dry-run` it never refuses: it prints `would_refuse=<tags>` and exits 0.
* CLI note: the migration reads the platform-tenant pin from the environment of the node that runs it. `bin/letflow rpc` runs INSIDE the live release node, so it sees exactly the serving node's pin; the caveat that the environment may differ applies only to a Mix task or an `eval` started as a separate process. The slug and realm-id checks below confirm the pin in every case.
* `verify() :: {:ok, %{pin_configured: boolean(), tenants: [tenant_state()]}} | {:error, :unexpected_error}`: a read-only verification entry point for the runbook. `tenant_state()` = `%{tenant_id, slug, platform_tenant? :: boolean(), platform_admin_binding? :: boolean(), tenant_admin_binding? :: boolean(), tenant_admin_member_count :: non_neg_integer(), platform_admin_group_member_count :: non_neg_integer(), tokens_with_platform_admin :: non_neg_integer()}`, one per registered tenant; queries only, ids and counts only (no user id, no token, no email). It is what the infra runbook (infra artefact section 8) uses for the verification step and what gate G2 item 3 quotes.

Preconditions (checked first, zero writes on failure; this is the safety net for the whole requirement):

* `Letflow.PlatformTenant.configured_id/0` must be non-nil AND a hyphenated UUID (`PlatformTenant.uuid?/1`); a non-UUID pin counts as not configured; else `:platform_tenant_not_configured`. Without a pin NO tenant is the platform tenant (0046 D2), and the sweep would convert the operator's own `PLATFORM_ADMIN` into `TENANT_ADMIN`.
* A `tenants` row with that id must exist and have a `tenant_schemas` registration, else `:platform_tenant_not_registered`.
* NON-DRY-RUN ONLY: the option `platform_tenant_slug` (mix task flag `--platform-tenant=<slug>`; see the Mix task flags above) is required and must equal the slug of the pinned tenant, else `:platform_tenant_slug_required` (absent) or `:platform_tenant_slug_mismatch`. The operator types the slug the dry run printed; a wrong environment fails here.
* NON-DRY-RUN ONLY (M2): the option `expected_realm_id` is required and must equal the `idp_realm_id` of the pinned tenant, else `:platform_tenant_realm_required` (absent) or `:platform_tenant_realm_mismatch`. The value is supplied by INFRA (the realm of the platform operator's tenant, `bpm-default` on QA), not read back from the dry run by the tool; it is an explicit input of the real run, so a wrong pin that still has `PLATFORM_ADMIN` members (every legacy tenant has them) is refused. The dry-run output of the pinned slug and realm id is infra's input to the real run's two arguments.
* NON-DRY-RUN ONLY: the pinned tenant's own schema must currently have a `:platform_role` binding named `PLATFORM_ADMIN` whose group has at least one member, else `:platform_tenant_has_no_operator`. A pin that points at a tenant with no operator is the symptom of a wrong pin; the sweep must not proceed.

Per-tenant algorithm (every registration from `TenantProvisioning.list_registrations/0`; the platform tenant is skipped entirely except as stated below). One `Repo.transaction/2` per tenant schema, so a failing tenant rolls back completely and the sweep continues with the next. A `try/rescue` around each tenant converts an exception (for example a vanished schema) into a `failed` entry, the same convention as `RoleBackfill`.

1. Read the `tenant_role` row named `PLATFORM_ADMIN` and the row named `TENANT_ADMIN` (name is unique per schema, F12).
   * `TENANT_ADMIN` row exists with `kind == :process_routing_role` -> failed with tag `:role_name_taken_by_routing_role`; stop this tenant.
   * `PLATFORM_ADMIN` row exists with `kind == :process_routing_role` -> failed with tag `:platform_admin_name_is_routing_role`; stop this tenant (an anomaly, not a role binding; never touched).
2. (a) Ensure the `TENANT_ADMIN` group (`get_or_create_group_by_name/2`) and `:platform_role` binding exist (`upsert_role/4`; when a binding already exists, keep its `group_id`: the copy targets that group, whatever it is called).
3. (b) Only when a `:platform_role` binding named `PLATFORM_ADMIN` EXISTS: take the group that binding points to (by the binding's `group_id`, not by group name) and insert every one of its members into the `TENANT_ADMIN` binding's group (`insert_or_fetch_group_member`-style, on conflict do nothing). The copy is gated on the binding, because a group without a binding confers nothing; this is what makes a second run unable to promote someone who was added later to the now-inert legacy group.
4. (c) Delete the `PLATFORM_ADMIN` `tenant_role` row (the binding). The legacy group and its members are KEPT (inert without a binding; kept for audit and so a manual rebind remains possible). Audit: one `Audit.append_multi` entry for the binding delete (action `role_binding.removed`, `resource_type: "tenant_role"`, state limited to the role name) and one entry per member copy in step 3 (action `group_member.copied`, `resource_type: "group_member"`, user id only, no other user attribute), actor nil, all in the same transaction as the writes.
5. (d) For every `api_tokens` row whose `roles` array contains `"PLATFORM_ADMIN"` (all rows, revoked and expired included), replace that element by `"TENANT_ADMIN"`, keep the other elements and their order, de-duplicate (a token holding both ends with one `TENANT_ADMIN`). Written through a new narrow changeset `ApiToken.roles_rewrite_changeset(token, roles)` that casts only `roles` (the token hash, expiry, revocation and name are untouched, so the plaintext token keeps working). Each rewritten token writes one `Audit.append_multi` entry, action `token.roles_migrated`, `resource_type: "api_token"`, actor nil, `before_state` and `after_state` limited to the `roles` field (never the hash).
6. Count `tenant_admin_member_count_after` (members of the `TENANT_ADMIN` group). Zero is reported as such (the lockout risk of 0046 open risk 6 is surfaced, not fixed).
7. A tenant for which steps 2-5 changed nothing (binding present and no `PLATFORM_ADMIN` binding and no token to rewrite) is `unchanged`.
8. `dry_run: true` has exactly ONE mechanism: counts by read-only QUERIES, with no write statement and no transaction that is rolled back. For each tenant it derives the same report fields a real run would produce: `tenant_admin_binding_created` = no `TENANT_ADMIN` row exists; `platform_admin_binding_removed` = a `:platform_role` `PLATFORM_ADMIN` row exists; `members_copied` = the number of members of the group that `PLATFORM_ADMIN` binding points to that are NOT already members of the `TENANT_ADMIN` binding's group (all of them when the `TENANT_ADMIN` binding does not exist yet; 0 when there is no `PLATFORM_ADMIN` binding); `tokens_rewritten` = the number of `api_tokens` rows whose `roles` array contains `"PLATFORM_ADMIN"` (a query on the array, e.g. a membership test in SQL); `tenant_admin_member_count_after` = the current member count of the `TENANT_ADMIN` group plus `members_copied`. The step 1 kind-collision checks are reads and are reported as `failed` entries. A real run computes the same values from the same queries inside its transaction and then writes, so a dry run followed by a real run on unchanged data reports identical counts (a test asserts exactly this, together with "row counts of `groups`, `group_members`, `tenant_role`, `api_tokens` and `audit` are unchanged after a dry run").

Platform tenant: the migration does not touch it (AC5 says so). It gets its `TENANT_ADMIN` group and binding from seeding for new installs and from the fixed backfill (3.9) on an existing deployment, and its `PLATFORM_ADMIN` members are NOT copied into `TENANT_ADMIN` (open question OQ-2 default). `platform_tenant_binding_ensured` reports whether the platform tenant already has the binding, as information for the operator; the migration does not create it.

Idempotency invariant: after a successful pass every non-platform tenant has a `TENANT_ADMIN` binding, no `PLATFORM_ADMIN` binding and no token containing `PLATFORM_ADMIN`; a second `run/1` reports every such tenant `unchanged` and changes no row.

Claim markers: the migration does NOT reset `role_claims_synced_at` (the backfill in 3.9 may). Reasoning in section 5.2.

### 3.9 Fix of `RoleBackfill` and `mix letflow.backfill_platform_roles` (PR 1)

* `RoleBackfill.process_registration/2` and `classify/4` stop hard-coding six. A tenant is "seeded" (and gets its users' `role_claims_synced_at` reset, ISS-0910, unchanged behaviour) when at least one of `RoleRegistry.seedable_role_names(schema_name)` is missing before the call; otherwise "unchanged". `held_platform_role_names/1` stays a read-only query.
* The backfill now seeds `TENANT_ADMIN` everywhere (including the platform tenant, which is how an existing platform tenant obtains its binding) and stops seeding `PLATFORM_ADMIN` outside the platform tenant. It does NOT delete any existing `PLATFORM_ADMIN` binding (that is the migration's job, step 4 of 3.8).
* Moduledoc and mix-task `@moduledoc`/`@shortdoc` lines that say "six" are updated.
* Existing `test/letflow/identity/role_backfill_test.exs` expectations that count six roles are updated (listed in 3.11).

### 3.10 Realm file `priv/keycloak/realms/bpm-default.json` (PR 1)

* `roles.realm` gains `{ "name": "TENANT_ADMIN" }` as the seventh entry (same shape as the six). `authorization_role_realm_test.exs` then passes WITHOUT edits (F15); it must not be edited.
* `users` gains a seeded `tenant-admin-user` with `realmRoles: ["TENANT_ADMIN"]`, in the same shape as `designer-user` (email `tenant-admin@letflow.local`, a fixed development password following the file's existing convention; this file is a development seed, not a QA secret). `seedVersion` is bumped to the PR date.
* No other user changes. In particular `admin-user` stays `PLATFORM_ADMIN` (it is the platform operator in the realm `bpm-default`).
* Realms other than `bpm-default` are not in the repository; their role and user changes are the infra contract (companion file).

### 3.11 "Six roles" documentation and test updates, BUILDS item 7 (PR 1)

Source files whose docs state six/five roles or enumerate them (found by grep on the worktree; each is edited in prose only): `lib/letflow/api/authorization.ex` (roles/0 doc, the `role()` type, module doc), `lib/letflow/identity/role_registry.ex` (upsert_role doc line 63-72, seed doc 109-128), `lib/letflow/identity/tenant_role.ex` (line 39 "six recognized literals"), `lib/letflow/tenant_onboarding.ex` (lines 130-148), `lib/letflow/identity/role_backfill.ex`, `lib/mix/tasks/letflow.backfill_platform_roles.ex`, `lib/mix/tasks/letflow.seed.ex` (line 20), `lib/letflow/identity.ex` (create_token doc line 1357 "five literal role-name strings"), `lib/letflow/routers/identity.ex` (lines 60-80 "six recognized literals"). Statements that call the tenant-administration surface "PLATFORM_ADMIN-only" in `tenant_modules.ex`, `tenant_solutions.ex`, `tenant_settings.ex` are updated to say `TENANT_ADMIN` (own tenant) because the matrix now grants them to `TENANT_ADMIN`.

Tests that state six roles or enumerate them and must be updated (the implementer re-greps; list is a starting set): `test/letflow/api/authorization_test.exs` (role-by-permission grids gain a `TENANT_ADMIN` row), `test/letflow/identity/role_backfill_test.exs`, `test/letflow/role_registry_test.exs`, `test/letflow/identity_test.exs`, `test/letflow/routers/identity_test.exs`, `test/letflow/plugs/iss0778_platform_role_seeding_e2e_test.exs` (a freshly onboarded NON-platform tenant no longer has a `PLATFORM_ADMIN` binding; the test that proved a freshly onboarded admin reaches a platform-admin gated route must pin the tenant as the platform tenant or switch to a `TENANT_ADMIN` double), `test/letflow/api/platform_admin_role_binding_test.exs`, `test/letflow/routers/onboarding_test.exs`, `test/letflow/routers/me_test.exs`, `test/letflow/routers/tasks_test.exs`, `test/support/iss0778_platform_admin_token_verifier_double.ex`.

`docs/roles.md` is NOT edited by REQ-447 (it is the TARGET state already and already lists TENANT_ADMIN). Finding for REQ-448 (F16): the matrix lacks a `PlatformServicesManage` row (scope platform; `PLATFORM_ADMIN` yes, all others no) and REQ-448's parity test iterates `core_permissions/0`; REQ-448 or a docs fix must add the row. Reported, not fixed here.

---

## 4. How the legacy compatibility interacts with the C6 switch and INV-10

| Question | PR 1 | PR 2 |
|---|---|---|
| Mechanism that keeps legacy `PLATFORM_ADMIN` working in a tenant | the existing C6 switch, default ON (`authorization.ex:525-527`, `1246-1250`). No new switch, no new alias, no role translation in code (open-question default "no alias" kept) | the switch and the legacy path are deleted (3.5) |
| Can a tenant `PLATFORM_ADMIN` hold a platform-scope permission | NO (rule 3: `:platform` branch needs `platform_tenant?` AND the role) | NO |
| Can it use `:Unknown` / catch-alls | NO (denied for every role, A2) | NO |
| Can it ignore a deactivated tenant | NO (`TenantStatus` exemption is `platform_scope?` only, F7) | NO |
| Own-tenant tenant-scope powers | YES (C6 ON) | NO (dropped at resolution) |
| Where does a NEW legacy `PLATFORM_ADMIN` come from | nowhere through seeding (3.2); still possible through `POST /roles` by a platform operator only (H1), `POST /tokens` only by a caller with recomputed platform scope (3.6b; a tenant admin is refused 403 from PR 1 on), or a first-login claim in a tenant that still has the binding | rejected everywhere (3.4) |
| Does `TENANT_ADMIN` depend on the switch | NO; works the same ON or OFF | n/a |
| INV-10 ("a platform-scope permission is honoured only for a `PLATFORM_ADMIN` whose database-resolved tenant is the configured platform tenant") | unchanged and enforced as in A2; `TENANT_ADMIN` adds no path to a platform permission because `permission_scope/1` classifies every unknown atom as platform and the new clause grants only `:tenant` | unchanged; PR 2 makes the role itself disappear outside the platform tenant |

The C6 interim stays exactly as ratified on 2026-10-06 ("a tenant `PLATFORM_ADMIN` holds own-tenant powers only until REQ-447"). What PR 1 changes is its END DATE: it now ends at PR 2, after the infra migration, not at the merge of REQ-447 as a single unit. See departure D1 (section 9).

---

## 5. Run procedure on an existing deployment (QA), BUILDS item 4

Precondition facts (from `ai-dala-infra`, run `2026-10-06-qa-realm-platform-admin-roles-check-001`, step 06, and `scripts/qa-uat-env.sh`): PLATFORM_ADMIN is a plain direct realm role in all realms (not composite, no Keycloak groups). Holders in tenant realms: swiftroute `swiftroute-admin-user` and `actor-swiftroute-alice`; vortex `vortex-admin-user`; meridian `meridian-admin-user`; bilimbaga `bilimbaga-admin-user` and `promo-reader-uat`. Holders in `bpm-default` (the realm of the platform tenant IF QA pins it, see S0): `admin-user`, `promo-proposer-uat`, `uat-promo-conflict-proposer`.

### 5.1 Ordered steps

| Step | Owner | Action | Add/remove |
|---|---|---|---|
| S0 | infra + ORCH | VERIFY before anything: `LETFLOW_PLATFORM_TENANT_ID` on QA equals the tenant id of the realm `bpm-default` tenant (the operator). If unset or different: STOP, nothing below runs (the migration also refuses, 3.8). | read |
| S1 | infra | Create the realm role `TENANT_ADMIN` in `bilimbaga`, `meridian`, `swiftroute`, `vortex` and `bpm-default` (the realm file only seeds a fresh `bpm-default`; QA's existing realm needs the role created by hand). Add-only; safe before or after PR 1 (an unknown claim string is dropped by `role_from_string/1`, and `sync_role_claims_from_token/3` only writes memberships for names that have a binding). Detail in the companion file. | add |
| S2 | ELIXIR-DEV / ORCH | Merge PR 1 (after gate G0, Q-1008); deploy to QA. S3 and S4 are run by infra only AFTER PR 1 is deployed to QA. S3 stays BEFORE S4 (S3 gives every tenant its `TENANT_ADMIN` binding, which S4 step (a) would otherwise create itself). | n/a |
| S3 | whoever ran ISS-0886's backfill on QA (infra or ORCH, same means) | the fixed backfill (3.9), release `rpc` form, NO Mix on the container (exact one-line expressions in the infra artefact, section 8): every tenant, the platform tenant included, gets the `TENANT_ADMIN` group and binding; nothing is deleted. | DB add |
| S4 | same | the migration in dry-run form, then (with `platform_tenant_slug` equal to the slug the dry run printed) for real, release `rpc` form (infra artefact, section 8); read the report (tenants, realm ids, counts, any `failed`). Re-run once: every tenant must be `unchanged`. | DB change |
| S5 | infra | Add `TENANT_ADMIN` to the six tenant admin users (companion file, section 3), THEN verify a login of each, THEN remove `PLATFORM_ADMIN` from them. Add before remove, always. | realm |
| S6 | infra | Report back: per user, the role claims of a fresh token, and the HTTP checks of the companion file. | read |
| S7 | ORCH | Gate for PR 2 (5.6). | n/a |
| S8 | ELIXIR-DEV | PR 2 merged and deployed; infra re-runs the S6 checks. | n/a |

Both the add (S1, first half of S5) and the DB conversion (S3, S4) are idempotent and re-runnable. The run is recorded in the run report: the dry-run output, the real output, the second-run output (all tenants `unchanged`), and the S6 results.

### 5.2 Why this order (token rewrite and realm change)

* API tokens live in the tenant database, not the realm, so the token rewrite (3.8 step 5) is purely a DB action in S4. It keeps each plaintext token valid; it only swaps the stored role strings. A token rewritten while the code still honours the legacy role (PR 1) works either way, because `TENANT_ADMIN` is granted by the matrix and a legacy `PLATFORM_ADMIN` token (not yet rewritten) works through C6.
* OIDC users do not carry roles in a token that the server trusts: their effective roles are re-read from `group_members` on every request (F10). The migration moves THEM in the DB (steps 3-4 of 3.8). The realm change (S5) matters only for users who have never logged in, or whose `role_claims_synced_at` is nil, because only then are claims copied into `group_members`.
* Add-before-remove closes both windows: a never-synced user whose token carries only the legacy claim (binding deleted by S4) would resolve to no role; therefore S1 and the "add" half of S5 happen so that the token carries `TENANT_ADMIN` BEFORE the legacy claim is removed. The "add" half can be done any time after S1; only the "remove" half must wait for S4 verification.
* Existing users' server-side roles come from the DB migration (S4), NOT from the realm: the claim sync runs only at a user's first login. Adding `TENANT_ADMIN` in the realm changes nothing server-side for an existing user; it matters for new users and for the web app, which reads the token's roles until REQ-450. Removing a realm role does not demote an already-synced user either: revoking an admin means removing them from the `TENANT_ADMIN` group.
* Consequence of "not seeded" in PR 1: from PR 1 on a NEW tenant has no `PLATFORM_ADMIN` binding, so a realm that issues only the `PLATFORM_ADMIN` claim gives that tenant's first admin no role. Every realm created after PR 1 must issue `TENANT_ADMIN` (stated in the infra artefact, section 3b). Existing tenants keep their binding until S4.
* Marker reset caveat (F6): the backfill (S3) resets `role_claims_synced_at`; if the identity provider STILL claims a role for a user whose membership an administrator had removed, the next login re-adds it (the sync is additive). Check, before S3, that no realm claims an admin role for a user an administrator deliberately demoted.
* Fresh installs: pin the platform tenant FIRST, then provision or backfill; a backfill or seed run before the pin is set treats the operator tenant as an ordinary one and does not seed its `PLATFORM_ADMIN` binding.
* No QA script is known to mint `PLATFORM_ADMIN`-role API tokens in a tenant (`scripts/seed_*` use a Keycloak bearer token, not `POST /tokens`); infra confirms by search before S4 (open question OQ-12).
* The migration does not reset claim markers (3.8): resetting would make already-migrated users re-sync from a token that may still carry the legacy claim, which now resolves to nothing and logs `sync_role_claims_from_token/3: zero group_ids resolved ...`. It would not remove memberships (the sync is additive), so it is harmless but noisy; the backfill (S3) may reset markers (ISS-0910 semantics, kept) before the migration deletes the binding, which is harmless for the same reason.

### 5.3 Rollback

* Realm side: re-add `PLATFORM_ADMIN` to a user. After PR 1 this restores nothing on its own (the DB role is already `TENANT_ADMIN` and the binding is gone), but the user keeps working as tenant admin; the legacy claim is simply ignored.
* DB side: there is NO automated reverse (forward-only). The legacy group and its members are retained, so an operator with database access can re-create the `PLATFORM_ADMIN` binding by hand during the PR 1 window. After PR 2 that is rejected by design (3.4). State this in the run report so nobody expects a down-migration.

### 5.4 Environments

This design covers QA. Any other environment that holds non-platform tenants with `PLATFORM_ADMIN` (development databases, any later production) runs S3 and S4 before PR 2 reaches it. Open question OQ-7: is QA the only deployed environment today? (CLAUDE.md says no production deployment exists yet.)

### 5.5 Failure handling

A failed tenant in S4 is reported with its reason and exit status 1; its legacy state is unchanged (the per-tenant transaction rolled back), and the C6 switch (PR 1) keeps its admins working. PR 2 does not start until every tenant is `unchanged` or `migrated` on a re-run.

### 5.6 Gate for PR 2

Gate G2 is DATED EVIDENCE, recorded by ORCH in the run report as a dated entry (same style as A2's section 15 entry in `iss0993-platform-scope-separation.md`), each item with a UTC date/time from the clock and the quoted output:

0. G0 evidence: Q-1008 (ISS-1026) merged with its merge SHA, the PR 1 deployment merge SHA that QA runs, and the SECURITY-REVIEWER verdict recorded for PR 1.
1. The dry run and the real run of S4 and the second run (every non-platform tenant `unchanged`, `failed: []`), with the printed pinned slug.
2. Infra's S5/R4 completion report: per user of the infra artefact, the role claims of a fresh token (names only) and the HTTP checks; the infra section 4 negative controls (including the platform-realm control) QUOTED after R2 and again after R4.
3. The read-only verification query is `verify()` (infra artefact section 8, step G): no API token on QA contains `PLATFORM_ADMIN` outside the platform tenant (`tokens_pa=0` for every non-platform tenant), and the platform-tenant row shows `pa_binding=true` and an operator count equal to the one printed by the dry run (the operators were not demoted); with it, the quoted `admin-user` checks (`GET /tenants` 200, `GET /admin/services` 200).
4. Evidence window: at least one UAT run (or, if none is scheduled, 24 hours of normal QA use) after R4 with no `403` regression for the six migrated users and no `tenant_inactive` or empty-roles log line for them. The window is deliberately short; ORCH may close it earlier only by recording why.
5. ORCH records G2 with the date in the run report. Only then is PR 2 opened and merged; the gap between PR 1 and PR 2 is kept as short as these items allow.

---

## 6. Schemas, tables, indexes

No new table, column, index or constraint. No Ecto migration file. All persistent change is data change in the existing per-tenant `groups`, `group_members`, `tenant_role`, `api_tokens` and `audit` tables of each tenant schema, performed by the migration module. `Letflow.Identity.ApiToken` gains one changeset function only (3.8 step 5), no field. Cross-module dependencies: `TenantAdminMigration` -> `TenantProvisioning` (registrations), `PlatformTenant`, `RoleRegistry`, `Identity.Audit`; `RoleRegistry` -> `PlatformTenant`; `Identity` -> `PlatformTenant` (PR 2 only). `mix letflow.check_boundaries` must stay clean: none of these dependencies is new in direction (Identity and PlatformTenant already reference each other, `identity.ex:1232`).

---

## 7. BUILDS item 8: what happens to the onboarding wizard's named administrator on first login (investigation, evidence)

Question: `test/fixtures/uat/scenarios/swiftroute/tenant-onboarding-happy.yaml` has the operator enter `admin_email`, `admin_username`, `admin_display_name` (step 1 input, lines 66-68) and expects Alice Bauer to log in with "no additional setup" (step 4, line 110). How does she become an admin of the new tenant?

Finding (from code): NOTHING makes her an admin; the backend does not even create her.

1. The SPA sends the three admin fields (`web/src/api/onboarding.ts:97-101`, built from `RegisterTenantPage.tsx:289-291`).
2. The server route validates against `@create_schema` that declares only `slug`, `display_name`, `hostname` (`lib/letflow/routers/onboarding.ex:147-172`); `Validation.validate/2` returns `Map.take(body, declared_fields)` (`lib/letflow/api/validation.ex:234-235`), so the three admin fields are silently discarded before the handler runs.
3. `handle_create/1` builds the tenant attributes as `Map.take(["slug","display_name"])` plus `"status" => "migrating"` (`onboarding.ex:180-183`) and calls `Identity.create_tenant/1`, which casts only what it is given and passes `:disabled` OIDC mode (`identity.ex:994-996`). No `idp_realm_id` is set (the wizard never sends one, and the changeset does not require one in `:disabled` mode, `tenant.ex:402`), so the new tenant is bound to no realm.
4. `provision_and_bind/4` runs `TenantOnboarding.provision_and_migrate/1` (schema, migrations, role seeding; `tenant_onboarding.ex:168-175`) and records a hostname binding. It never calls `Identity.provision_oidc_user/4`, `add_group_member/3`, `create_user/2` or `create_token/3`. The moduledoc states the omission explicitly: "Keycloak realm/client provisioning, initial-admin-user creation ... are all absent here" (`onboarding.ex:104-108`).
5. First login of anyone into that tenant requires `resolve_tenant_by_realm/1` (`identity.ex:152-153`, `Repo.get_by(Tenant, idp_realm_id: ...)`): with no `idp_realm_id` no realm resolves to the tenant, so the token is rejected before any role logic. If an operator binds a realm out of band, the only role path is the claim sync (`identity.ex:851-920`, `1905-1910`): the user's token role claims are copied into `group_members` for names that have a binding. With REQ-447 seeding, the user becomes `TENANT_ADMIN` if and only if the realm issues the realm role `TENANT_ADMIN` (before REQ-447 the realm would have had to issue `PLATFORM_ADMIN`).

Conclusion for the run report: on first login the wizard's named administrator holds NO role (and cannot authenticate at all through the wizard alone). The scenario's expectation is not met by the backend. Roster evidence agrees: `test/fixtures/uat/actors.yaml:80-85` says "no seed grants her an admin role"; her QA realm account holds `PLATFORM_ADMIN` only because infra seeded it by hand (T-0150).

MUST an ISSUE be raised? YES, and it HAS been filed separately as Q-1012 / GH #2312 / ISS-1030 (letflow-9a direction: a pending `TENANT_ADMIN` keyed by the normalised e-mail address, bound at the first VERIFIED login; NOT part of PR 1 or PR 2, and PR 1 and PR 2 do not touch `routers/onboarding.ex`). The reasoning for raising it: Per `docs/agents/protocols/ISSUE_QUEUE.md` the item is a defect against a stated user-facing flow (scenario step 4 and the web form promise it) and is not covered by any requirement (REQ-447 says "report it to ORCH as an issue"). Suggested record: title "Onboarding wizard discards the named tenant administrator: no user, no realm binding, no TENANT_ADMIN membership"; evidence = the five points above; scope note that the fix needs a product decision (who creates the realm user: the server through a Keycloak admin client, or a documented infra step) and is therefore likely a design-level issue, not a one-line fix. This design does not propose the fix and PR 1 does not touch `routers/onboarding.ex`.

---

## 8. Invariants (the validator and SECURITY-REVIEWER check these)

* INV-A: `TENANT_ADMIN` is allowed a permission iff `permission_scope(permission) == :tenant`; never a platform-scope permission, never `:Unknown`.
* INV-B: no role other than `PLATFORM_ADMIN` gains or loses any grant (D7); the `TENANT_ADMIN` clause adds a role, it removes nothing.
* INV-C (INV-10): platform scope is conferred only to `PLATFORM_ADMIN` whose database-resolved tenant is the configured platform tenant. Unchanged in both PRs.
* INV-D: the deactivated-tenant gate has no exemption for `TENANT_ADMIN`.
* INV-E: a role binding is the only thing that makes a group confer a role; the migration deletes the `PLATFORM_ADMIN` binding and copies only from a bound group.
* INV-F: the migration is idempotent, per-tenant atomic, and refuses to run without a registered platform-tenant pin.
* INV-G (INV-2/INV-4): no user attribute, token value, hash or group id is logged or printed by the migration or its task.
* INV-H (INV-1): every new query is scoped by the tenant schema `prefix:`; no tenant identifier comes from a request. The migration is an operator CLI, not an HTTP route.
* INV-I: the `TENANT_ADMIN` and `PLATFORM_ADMIN` names cannot be bound through `POST /roles` by a caller that does not hold the corresponding authority (H1 existing, H2 new).
* INV-J (INV-10, SECURITY-REVIEWER F1): a caller without recomputed platform scope can neither mint a `PLATFORM_ADMIN` token nor change the membership, the existence or the status of members of the group bound to `PLATFORM_ADMIN` (3.6b); any built-in role name needs `:UsersGroupsRolesManage` to bind, for any kind (3.6).

---

## 9. Departures from the REQ-447 text as written (FLAGGED: need ORCH / user acknowledgement)

| # | Departure | Why | Needs ack from |
|---|---|---|---|
| D1 | REQ-447 is delivered in TWO PRs; BUILDS item 2's rejection and dropping rules and AC4 move to PR 2, so a legacy tenant `PLATFORM_ADMIN` keeps own-tenant powers (C6) until PR 2. The text reads as one unit and 0046 D8 says "REQ-447 must not ship alone" relative to ISS-0993, not relative to itself; D4's Transition ("takes full effect when REQ-447 merges") therefore completes at PR 2. | The supervisor brief orders: code with compat, then infra migration, then removal, so QA does not break. | ORCH and the user (it extends the C6 interim ratified 2026-10-06 in time) |
| D2 | REQ-447 flips to `done` only when PR 2 merges; PR 1 leaves it `pending`. The requirement's one-line `ordering:` addition is made in PR 1 (section 10). | Same. | ORCH |
| D3 | New safety rule not in the text: the migration aborts, with zero writes, when no platform tenant is configured and registered. | A missing pin would convert the operator's `PLATFORM_ADMIN` into `TENANT_ADMIN`. | ORCH |
| D4 | New `--dry-run`; per-tenant transactions; failure continues the sweep (this one IS in the text: "a tenant that fails is reported and the sweep continues", unlike the old backfill which halts); the copy is gated on the existing `PLATFORM_ADMIN` binding and uses the binding's group, not the group named `PLATFORM_ADMIN`. | idempotency and no resurrection of an inert group (3.8). | none beyond review |
| D5 | ADDITION: H2, the widened `POST /roles` guard: binding ANY built-in role name, of any kind, needs `:UsersGroupsRolesManage` (3.6). Not in the text. | Without it the new role is a privilege escalation for any `PROCESS_DESIGNER`, including by posting a `process_routing_role` named `TENANT_ADMIN` (kind overwrite). | ORCH and SECURITY-REVIEWER (security-relevant scope addition) |
| D10 | ADDITION: platform-escalation guards (3.6b): `POST /tokens` (the router, not `create_token/3`) refuses a `PLATFORM_ADMIN` roles list without recomputed platform scope; membership changes and group delete for the group bound to `PLATFORM_ADMIN`, `POST /users/:id/status` and `PATCH /users/:id` on its members, and `DELETE /tokens/:id` of a token carrying `PLATFORM_ADMIN` need platform scope. From PR 1 a legacy tenant admin can no longer mint a `PLATFORM_ADMIN` token (a behaviour change, intended). | Without them a platform-tenant `TENANT_ADMIN` (AC3 gives it `:TokensManage` and `:UsersGroupsRolesManage`) can become `PLATFORM_ADMIN` (INV-10). The alternative "do not honour `TENANT_ADMIN` in the platform tenant" conflicts with AC3 and is rejected unless ORCH decides. | ORCH and SECURITY-REVIEWER |
| D11 | PR 1 is gated on Q-1008 (G0) and PR 2 on dated evidence (G2); the `ordering:` line of section 10 names Q-1008 as well as Q-1005, which is wider than the supervisor brief that named only Q-1005. | 0046 D3 binding condition for `:PromotionsManage`; shortest safe gap. | ORCH |
| D6 | ADDITION: `is_task_worker_only?/1` also excludes `TENANT_ADMIN` (3.1). Implied by "a TENANT_ADMIN of a non-platform tenant gets 2xx on ..." for task routes but not stated. | avoids row-filtering an admin who also holds `TASK_WORKER` (Alice, after migration). | none beyond review |
| D7 | The seeding of `PLATFORM_ADMIN` stops in PR 1 (not in PR 2). The text lists "not seeded" with the other item-2 rules; the brief's split puts "seeding" in PR 1. | Otherwise the migration's binding delete can be undone by any later seed or backfill run. | ORCH |
| D8 | The existing `mix letflow.backfill_platform_roles` is changed (3.9) in addition to the new task; the REQ text names it only as a pattern. | the platform tenant's `TENANT_ADMIN` binding on an existing deployment, and the hard-coded `6`. | none beyond review |
| D9 | The text says the migration "is run on an existing deployment (QA) and the run is recorded in the run report"; this design makes the run a multi-actor procedure with infra owning the realm half (section 5 and the companion file). | brief constraint 2 and 3. | ORCH |

---

## 10. The `docs/requirements.yaml` edit (PR 1; no other text change; status flip only at the end, in PR 2)

Exactly ONE line is added to the REQ-447 entry, in the `description:` folded block scalar, directly after the existing line that ends `and REQ-446 to be merged.` (currently line 11 of the entry; file line 33790 on `origin/main` 256587a8), at the same 6-space indent, as the new next line (before the blank line that precedes `BUILDS:`):

`      ordering: requires Q-1005 / GH #2297 (ISS-1023) and Q-1008 / GH #2305 (ISS-1026) merged first: exposure is real once :PromotionsRead and :PromotionsManage are granted to TENANT_ADMIN/TENANT_AUDITOR`

The text after the 6 leading spaces is the supervisor's string extended, per SECURITY-REVIEWER F2 and the supervisor's answer (PR 1 after Q-1008), to name Q-1008 / GH #2305 / ISS-1026 as well as Q-1005 (this departs from the brief's literal string; ORCH must carry the same text into the PR; D11). In a folded scalar the line folds into the description paragraph; `git diff` shows exactly one added line (+1, -0) in `docs/requirements.yaml`. No other text of the entry changes in PR 1; the `status: pending` flip is made by DOC-UPDATER only after PR 2 merges and RELEASE-VALIDATOR passes. Note: Q-1005 (ISS-1023, PR #2309) is already merged in `origin/main` 256587a8, so that half of the line records an ordering already satisfied; Q-1008 is the open one and is gate G0 (2.1).

---

## 11. Test plan (names; real Postgres for router and migration tests)

PR 1 (new files unless "update"):

* `test/letflow/api/authorization_tenant_admin_test.exs`
  * "roles/0 returns seven atoms ending in TENANT_ADMIN"
  * "role_allows?(:TENANT_ADMIN, p) is true exactly when permission_scope(p) is :tenant, for every p in permissions/0" (AC1; includes Catalog permissions through a registered fixture module)
  * "evaluate_access denies :Unknown for TENANT_ADMIN" and "TENANT_ADMIN is never allowed a platform-scope permission with platform_tenant? true or false"
  * "roles_from_strings parses TENANT_ADMIN exactly; tenant_admin and Tenant_Admin parse to nothing"
  * "is_task_worker_only? is false for TENANT_ADMIN + TASK_WORKER; GET /tasks task_scope is :all and GET /tasks/inbox is unfiltered"
  * "legacy compat: a PLATFORM_ADMIN of a non-platform tenant still holds tenant-scope powers and no platform-scope permission (C6 ON)"
* `test/letflow/routers/tenant_admin_routes_test.exs` (AC2, table-driven, one named line per route): 2xx for users, groups, roles, tokens, audit, `PATCH /tenant/settings`, `POST /tenant/modules`, `POST /tenant/solutions`, promotions (list and a review read), `POST` definition rollback; 403 for every route under `/tenants`, `/onboarding`, `/platform-migrations`, `/event-retention`, and ALSO `/admin/services` (a superset of the AC, same permission class).
* `test/letflow/identity/tenant_admin_seeding_test.exs` (AC3): non-platform provisioned tenant has TENANT_ADMIN binding and no PLATFORM_ADMIN binding; platform-pinned tenant has both; `seedable_role_names/1` fails closed on a malformed schema name; a `:process_routing_role` named `TENANT_ADMIN` makes the seed return the collision error and changes nothing.
* `test/letflow/identity/tenant_admin_migration_test.exs` (AC5 and edges): two members + one token -> both in TENANT_ADMIN, no PLATFORM_ADMIN binding, token carries TENANT_ADMIN, token plaintext still verifies; second run `unchanged` and zero row changes; platform tenant untouched; a token holding both roles ends with one TENANT_ADMIN; a member added to the inert legacy group after run 1 is NOT promoted by run 2; one tenant failing (collision) does not stop the sweep and is listed in `failed`; `dry_run: true` is queries only: row counts of groups, group_members, tenant_role, api_tokens and audit are unchanged after it, and its counts (members_copied, tokens_rewritten, tenant_admin_member_count_after) equal those of a real run on the same data; the real run refuses without `platform_tenant_slug`, with a wrong slug, without `expected_realm_id`, with a wrong realm id, with a non-UUID pin, and when the pinned tenant has no PLATFORM_ADMIN member (writes nothing in each case); `run/1` and `verify/0` return an atom tag, not an exception message, when a tenant schema vanishes; each rewritten token and each copied member and the binding delete have an audit entry containing no hash and no user attribute beyond the user id; the failure report carries a reason tag atom only, never an exception message; precondition tests (no pin, pin not registered) write nothing; zero admin members is reported with `tenant_admin_member_count_after: 0`; audit entry `token.roles_migrated` exists and contains no hash.
* `test/mix/tasks/letflow_migrate_tenant_admins_test.exs`: exit status 0 on success and under `--dry-run`, 1 on any `failed` tenant; `REFUSED <tag>` line and exit 1 (nothing written) for each of: missing `--platform-tenant`, wrong slug, missing `--expected-realm-id` (`REFUSED platform_tenant_realm_required`), wrong realm id (`REFUSED platform_tenant_realm_mismatch`), no pin, no operator; output contains slug and realm id and no token, group id or exception text.
* `test/letflow/plugs/tenant_status_test.exs` (update, AC6): TENANT_ADMIN of an inactive tenant -> 403 `tenant_inactive`; platform-tenant PLATFORM_ADMIN still exempt.
* `test/letflow/routers/identity_test.exs` (update), H2 (3.6): a `PROCESS_DESIGNER` posting a `platform_role` with each built-in name (`TENANT_ADMIN`, `PLATFORM_ADMIN`, `PROCESS_OPERATOR`, `TASK_WORKER`, ...) gets 403 and the binding row is unchanged; a `PROCESS_DESIGNER` posting a `process_routing_role` named `TENANT_ADMIN` gets 403 and the binding (name, kind, group_id) is unchanged (kind-overwrite case); the same designer still gets 2xx for a `process_routing_role` with a non-built-in name; a `TENANT_ADMIN` caller and a platform-scope caller succeed for `TENANT_ADMIN`; a legacy tenant `PLATFORM_ADMIN` succeeds for built-in names except `PLATFORM_ADMIN` (403).
* `test/letflow/routers/platform_escalation_guard_test.exs` (new, PR 1, 3.6b, real Postgres, caller = a TENANT_ADMIN of the PLATFORM tenant): `POST /tokens` with `roles: ["PLATFORM_ADMIN"]` gives 403 (the check is in the router; the test also states that `Identity.create_token/3` called directly is unchanged in PR 1); `POST /groups/:id/members` adding the caller to the group bound to `PLATFORM_ADMIN` (resolved by binding id, with the group NOT named `PLATFORM_ADMIN` in one variant) gives 403; `DELETE /groups/:id/members/:user_id` removing a platform operator gives 403; `POST /users/:id/status` deactivating a platform operator gives 403; `DELETE /groups/:id` of that group gives 403; `PATCH /users/:id` on a platform operator gives 403; `DELETE /tokens/:id` of an operator's `PLATFORM_ADMIN` API token gives 403 and the token stays unrevoked; `POST /roles` with name `PLATFORM_ADMIN` (kinds `platform_role` and `process_routing_role`) gives 403 and the binding is unchanged; with no `PLATFORM_ADMIN` binding (`platform_admin_group_id` returns `:none`) nothing beyond H1 is protected (documented reliance); the database is unchanged after each; positive controls: a platform-scope `PLATFORM_ADMIN` succeeds for each; a `TENANT_ADMIN` can still manage members of an ordinary group and mint a `TENANT_ADMIN` token.
* `test/letflow/identity/role_backfill_test.exs` (update): seven-role aware `classify`; platform tenant gets TENANT_ADMIN; non-platform tenant gets no PLATFORM_ADMIN; existing PLATFORM_ADMIN binding is not deleted by the backfill.
* `test/letflow/api/authorization_role_realm_test.exs`: NOT edited; it must pass (AC7). Plus a check in the new realm assertions inside `tenant_admin_seeding_test.exs` or a sibling file that the realm file has a `tenant-admin-user` with exactly `["TENANT_ADMIN"]`.
* Updates listed in 3.11 (grids and "six" assertions).

PR 2:

* `test/letflow/api/platform_admin_outside_platform_test.exs` (AC4; the hand-assigned-context case below also covers `GET /tasks/inbox`: a non-platform context carrying `PLATFORM_ADMIN` + `TASK_WORKER` must NOT get an unfiltered inbox, `routers/tasks.ex:256-258`): "upsert_role PLATFORM_ADMIN is rejected in a non-platform tenant and accepted in the platform tenant"; "POST /tokens with PLATFORM_ADMIN returns 403 in a non-platform tenant (router check; unchanged from PR 1)" and a direct-call unit test "Identity.create_token/3 with roles [PLATFORM_ADMIN] and a non-platform prefix returns {:error, :invalid_role_set}; with the platform-tenant prefix it succeeds"; "a caller whose stored group roles contain PLATFORM_ADMIN is denied a platform route (403) and denied tenant routes (no catch-all)"; "a caller whose token claims PLATFORM_ADMIN is treated the same (claim sync ignores it)"; "an API token row carrying PLATFORM_ADMIN is dropped at resolution"; "hand-assigned auth_context carrying PLATFORM_ADMIN with a non-platform tenant is dropped by Authorize and by the unredacted-export check".
* `test/letflow/api/platform_scope_authorization_test.exs` (update): replace the C6 switch test; the function `tenant_platform_admin_own_tenant_powers?/0` no longer exists.
* The fixture sweep (section 12, size) so tests that used an ordinary-tenant `PLATFORM_ADMIN` as an admin use `TENANT_ADMIN`.

Gates (both PRs): CODE-DESIGN-VALIDATOR on this design; ELIXIR-DEV; SECURITY-REVIEWER MANDATORY (identity and authorization, role resolution, token issuance, tenant-data path; `docs/agents/instructions/security-invariants.md` INV-1..INV-10); REVIEWER (scope: the two PRs and D5/D6); TEST-DESIGNER and TEST-DESIGN-VALIDATOR; TEST-RUNNER; RELEASE-VALIDATOR; and, after PR 2 on QA, UAT-RUNNER re-runs the tenant-admin scenarios. `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix test`, `mix letflow.check_boundaries`, plus the CI-shaped local run (`core-directives.md` merge discipline).

---

## 12. Size estimate, risk, and what the supervisor must decide

### Size

| | PR 1 | PR 2 |
|---|---|---|
| lib files | about 14 touched: `authorization.ex`, `role_registry.ex`, `platform_tenant.ex`, `tenant_onboarding.ex`, `role_backfill.ex`, `identity.ex` (docs only), `identity/api_token.ex`, `identity/tenant_role.ex` (docs), `routers/identity.ex` (H2 + docs), `routers/tenant_modules.ex`, `tenant_solutions.ex`, `tenant_settings.ex` (docs), `mix/tasks/letflow.backfill_platform_roles.ex`, `letflow.seed.ex` (docs); 2 new: `identity/tenant_admin_migration.ex`, `mix/tasks/letflow.migrate_tenant_admins.ex` | about 7 touched: `authorization.ex`, `role_registry.ex`, `identity.ex`, `routers/identity.ex`, `plugs/auth_pipeline.ex`, `plugs/authorize.ex`, `routers/entities.ex`, plus `platform_tenant.ex` |
| non-lib | `priv/keycloak/realms/bpm-default.json`, `docs/requirements.yaml` (+1 line), 2 design files | `docs/requirements.yaml` status flip + status history (DOC-UPDATER) |
| tests | about 6 new files, about 10 updated | 1 new, 1 updated, plus a sweep: of the 164 test files that mention `PLATFORM_ADMIN`, those that use a non-platform tenant's `PLATFORM_ADMIN` as an ordinary admin (a subset of the 75 with the literal list `["PLATFORM_ADMIN"]`) must move to `TENANT_ADMIN`; the true count is established by a first-step audit of PR 2 (suite run with the legacy path deleted) and is expected to be several dozen files |
| risk | medium: authorization and identity data paths, but additive; the data-moving part is guarded by a dry-run, per-tenant transactions and the pin precondition | medium-high: a behaviour removal plus a wide mechanical test sweep; recommended to split the sweep into its own first commit so the production diff stays reviewable |

### What the supervisor needs to decide

1. Acknowledge the departures D1-D9 (section 9), above all D1/D2 (two PRs, REQ stays pending until PR 2), D5 (H2 scope addition) and D7.
2. SETTLED (supervisor answer, SECURITY-REVIEWER F2): PR 1 merges AFTER ISS-1026 / Q-1008 / GH #2305 (gate G0, 2.1); Q-1011 / ISS-1029 is not waited for. Nothing to decide except that ORCH carries the extended `ordering:` text of section 10 (D11).
3. Whether REQ-448 (Q-965) and REQ-449 (Q-966) may start after PR 1 merges rather than after REQ-447 is `done` (they list REQ-447 in `depends_on`; PR 1 already provides the role, the seeding and the migration pattern they build on).
4. SETTLED: the item-8 ISSUE is filed as Q-1012 / GH #2312 / ISS-1030 (section 7); not in PR 1 or PR 2.
5. Confirm the QA platform pin (S0). S3/S4 are run by infra AFTER PR 1 is deployed to QA, through the release `rpc` (no Mix on the QA container); the exact runbook is in the infra artefact, section 8.
6. Disposition of `bilimbaga/promo-reader-uat` (T-0169, awaiting the user) and of the three `PLATFORM_ADMIN` holders in `bpm-default` (`admin-user`, `promo-proposer-uat`, `uat-promo-conflict-proposer`: they stay as they are IF `bpm-default` is the pinned platform tenant; whether two promo accounts should be platform operators at all is a T-0166/T-0168 question, not REQ-447's).
7. The roster file `test/fixtures/uat/actors.yaml` (lines 80 and 157-165, `legacy_platform_admin` for `actor-swiftroute-alice`, `removed_by: REQ-454`) is REQ-454's to change; confirm REQ-447 does not edit it. After PR 1 `TENANT_ADMIN` is a valid `Authorization.roles/0` name for the schema checker (SCHEMA-8).

---

## 13. Open questions (none silently resolved; defaults stated)

* OQ-1 (REQ text) A tenant realm that still issues the claim `PLATFORM_ADMIN` resolves to no role for a NEW admin. DEFAULT KEPT: no alias in code. Handling: the migration report lists every migrated tenant with its `idp_realm_id` (3.8) and the companion file lists the realm changes; the run report names affected tenants.
* OQ-2 (REQ text) Platform tenant's `PLATFORM_ADMIN` members also added to `TENANT_ADMIN`? DEFAULT KEPT: no. The platform tenant gets the group and the binding, no members.
* OQ-3 Last-admin protection (0046 open risk 1/6): nothing built; the migration reports `tenant_admin_member_count_after`. DEFAULT: report only.
* OQ-4 Reset of `role_claims_synced_at` by the migration. DEFAULT: no (5.2).
* OQ-5 `kind` collision on `TENANT_ADMIN` (F12). DEFAULT: fail that tenant, never overwrite.
* OQ-6 Residual: a `PROCESS_DESIGNER` can re-point the bindings of lower roles through `POST /roles` (pre-existing). DEFAULT: out of scope; recorded here, candidate follow-up requirement (restrict `:RolesManage` to bindings of `kind: process_routing_role` for non-admin roles).
* OQ-7 Is QA the only deployed environment that needs S3/S4? DEFAULT: yes (CLAUDE.md: no production deployment).
* OQ-8 Audit entry per rewritten token (`token.roles_migrated`). DEFAULT: yes; the cost is one audit row per token and the benefit is a traceable permission change.
* OQ-9 `promo-reader-uat` target role: `TENANT_ADMIN` (per the brief) versus `TENANT_AUDITOR` (the name suggests a reader; REQ-448 not yet built). DEFAULT: `TENANT_ADMIN` now, review after REQ-448 and T-0169.
* OQ-10 The platform tenant `entities.ex:2237` context omits the platform flag (F11). DEFAULT: fixed in PR 2 through `effective_roles/2`; harmless in PR 1 because the permission is tenant scope.
* OQ-11 REQ-449 owner condition (recorded here, not built here): `GET /me/access` must call the SAME role-resolution function the request pipeline uses (`Authorization.effective_roles/2` through `attach_auth_context/4`, 3.5), never a second parse of the token or of `group_members`, or the client answer and the server decision will diverge. DEFAULT: required of REQ-449.
* OQ-12 Whether any QA script or operator habit mints `PLATFORM_ADMIN`-role API tokens in a tenant through `POST /tokens` (none found in this repository; infra confirms for its own scripts). DEFAULT: assume none; the migration rewrites any that exist.
* OQ-13 `docs/roles.md` lacks a `PlatformServicesManage` row (F16): fixed in REQ-448's PR (its parity test iterates `core_permissions/0`), not here. DEFAULT: as stated.
* OQ-14 Release-`rpc` invocation of `TenantAdminMigration.run/1` on QA: the runbook (infra artefact section 8) follows `docs/runbooks/login-directory-pepper-rotation.md` section 0; `bin/letflow rpc` runs inside the live node and sees the serving node's pin; the printed pinned slug, the mandatory `platform_tenant_slug` and the mandatory `expected_realm_id` (3.8) confirm it. DEFAULT: as stated.
* OQ-6 (restated as residual, 3.6): a holder of `:UsersGroupsRolesManage` can point a built-in binding at any group. ACCEPTED, not widened.
* R-W (residual, 3.6b): during the PR 1 window a non-platform tenant's own admins cannot edit the members of the legacy `PLATFORM_ADMIN` group (the guard needs platform scope); the migration (S4) removes the binding and with it the effect. ACCEPTED.
* R-LA (residual): no last-admin protection (decision 0046 open risk 6); the migration only reports `tenant_admin_member_count_after`. ACCEPTED.
