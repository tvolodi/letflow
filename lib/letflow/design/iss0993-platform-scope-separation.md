# ISS-0993 / ISS-0994 -- Platform scope separation for tenant administration permissions

Status: DESIGN (CODE-DESIGNER), awaiting CODE-DESIGN-VALIDATOR, SECURITY-REVIEWER (mandatory), REVIEWER.
Branch: `design/ISS-0993-platform-scope-split` (local, cut from `main` b6eb492c).
Issues closed by this design: ISS-0993 (queue Q-960, GH #2229) and ISS-0994 (queue Q-961, GH #2231).
They describe one defect class and share one fix; ISS-0994's acceptance criteria are carried over in full (section 14).
Decision record: this design does NOT write one. Decision record 0046 (REQ-445, Q-962) is THE record and is written from REQ-445's ratified D1..D10.
This file carries the implementation notes for it (section 21, "Enforcement notes P1..P8"). Decision-like statements in this file are "per REQ-445 D2/D3/D4".

Wording rule for this file: generic. It states the rule and the verification, not a recipe.

Contents: 1 Problem, 2 Design rules, 3 Platform tenant configuration (3.1 marker is not API-writable), 4 Platform-scope fact, 5 Permission split and scope,
6 Evaluation rules, 7 Complete route scope table, 8 `authorize_target_tenant`, 9 Promotions, 10 Role-claim and escalation analysis,
11 Guard test, 12 Test list, 13 Files per PR, 14 Acceptance mapping (ISS-0993 / ISS-0994 checklist), 15 Rollout and seeding contract, 16 Break-glass, 17 PR B outline,
18 Security invariant INV-10 (cited; enforced and checked here), 19 Conflicts with REQ-445..447, 20 Open questions, 21 Enforcement notes P1..P8 (implementation notes for decision 0046),
22 Overlap with REQ-446 / Q-963 and PR B limits, 23 Gate record.

---

## 1. Problem (generic)

* `Letflow.Api.Authorization.core_role_allows?/2` answers `true` for `PLATFORM_ADMIN` for every permission (authorization.ex:1130).
  `PLATFORM_ADMIN` is a tenant role, present in every tenant, so every tenant's administrators hold every permission.
* One permission, `:TenantsManage`, means both "manage my own tenant" (`PATCH /tenant/settings`) and "act on the tenant registry /
  across tenants" (`/tenants*`, `/onboarding*`, `/platform-migrations*`, `/event-retention*`).
* Handlers that take a tenant from the path or body do not compare it with `conn.assigns.auth_context.tenant_id`.
* Twelve routes are declared with plain `get`/`post` macros, resolve to `:Unknown`, and `evaluate_access/2` allows `:Unknown` for
  `PLATFORM_ADMIN` (authorization.ex:934-939). `PromotionPlan.default_permission_checker/2` is always `true`.
* Invariants affected: INV-1, INV-2, INV-5, INV-6 (`docs/agents/instructions/security-invariants.md`).

## 2. Design rules (the fix in six lines)

1. Every permission has exactly one scope: `:platform` or `:tenant` (table in section 5).
2. A platform-scope permission is honoured only when the caller's tenant is the single configured platform tenant AND the caller holds
   `PLATFORM_ADMIN` there. The operator role is the EXISTING `PLATFORM_ADMIN`; no new role is added (user decision; REQ-445 D2/D4).
3. The platform tenant is identified by server configuration (one environment variable). No `/api/v1` route can read-modify it. Unset means
   nobody has platform scope (fail closed).
4. Tenant-scope behaviour is unchanged: the `PLATFORM_ADMIN` catch-all keeps covering tenant-scope permissions in every tenant until
   REQ-447 introduces `TENANT_ADMIN`. This fix does not rename or add roles.
5. `:Unknown` is denied for every role. Every route declares an explicit key. A guard test fails on a route without one. Router catch-alls (unmatched paths) are not routes; they carry one of two private marker keys (section 7.5), so a platform-tenant operator keeps the 404 on an unmatched path while every other caller gets a uniform 403 under the five platform prefixes.
6. Every handler that receives a tenant identifier from the request proves the target is the caller's own tenant, or that the caller has
   platform scope, before any lookup (404 per INV-5).

## 3. Platform tenant configuration

| Item | Decision |
|---|---|
| Source | environment variable `LETFLOW_PLATFORM_TENANT_ID` |
| Value form | the `tenants.id` UUID of the platform tenant, hyphenated; case-insensitive on input, stored canonical lower-case. Not a secret, but never echoed in errors or logs |
| Application config key | `config :letflow, Letflow.PlatformTenant, tenant_id: String.t() | nil` |
| Default | `nil` in `config/config.exs` for every environment (including test) |
| Parsed by | one pure function `Letflow.PlatformTenant.parse_env/1`, called from `config/runtime.exs` (same pattern as `LETFLOW_LOGIN_DISCOVERY_MODE`, runtime.exs:286-300) |
| Unset / empty / whitespace | `{:ok, nil}`; platform scope is unavailable to everyone. Boot continues; one stderr warning (text below). Not a boot failure: a crash would take every tenant down over an operator-console setting |
| Malformed | boot stops with a fixed message that does not echo the value: "environment variable LETFLOW_PLATFORM_TENANT_ID must be unset/blank or a UUID. The value is not echoed." |
| Registration check | after the repo is up, one non-fatal check that a row with that id exists in `tenants`; if not, one error log line ("configured platform tenant is not registered", no value). Never raises. Implemented as a temporary one-shot `Task` child started after `Letflow.Repo` in `Letflow.Application` (or a start-phase; ELIXIR-DEV picks, the check must not block boot) |
| Relation to the default tenant | none (per REQ-445 D2 the platform tenant is a configured pin, not a slug convention). `@default_tenant_slug "bpm-default"` (lib/letflow/identity/tenant.ex:85) pins the dev/default tenant's realm; it is not the platform tenant and is never used as a fallback. ISS-0994 floated the default tenant as the "natural default"; this design does not take it, because an implicit default would make an unset config silently grant platform scope to whichever tenant carries that slug |
| bpm-default on QA | independent decision of infra: QA MAY set `LETFLOW_PLATFORM_TENANT_ID` to the id of the existing `bpm-default` tenant (operator-owned realm, already holds the seeded `admin-user` with `PLATFORM_ADMIN`, and the existing platform UAT scenarios already run as that account). Production MUST use a dedicated platform tenant and realm. See seeding contract, section 15 |

Warning text on unset (A1): "LETFLOW_PLATFORM_TENANT_ID is unset: platform scope is not enforced yet (shadow mode)."
Warning text on unset (A2): "LETFLOW_PLATFORM_TENANT_ID is unset: platform-scope operations are denied for every caller."

Public API of the new module `Letflow.PlatformTenant` (pure except config read; `lib/letflow/platform_tenant.ex`):

```text
parse_env(raw :: String.t() | nil) :: {:ok, String.t() | nil} | {:error, :invalid_uuid}
configured_id() :: String.t() | nil
platform_tenant?(tenant_id :: String.t() | nil) :: boolean()      # false when unset, false for nil
scope_facts(tenant_id :: String.t() | nil, role_strings :: [String.t()]) ::
        %{platform_tenant?: boolean(), platform_scope?: boolean()}
```

Second public function (added): `scope_facts_for(auth_context :: map() | term()) :: %{platform_tenant?: boolean(), platform_scope?: boolean()}`. Recomputation entry points (all derive from the same `scope_facts/2` logic and never read the stored keys): `platform_tenant?/1` is called by `Letflow.Plugs.Authorize` (it needs only the tenant id; section 4); `scope_facts/2` is called by `Letflow.Plugs.TenantStatus` (it has the resolved tenant row id and the raw role strings, not an `auth_context`; section 6); `scope_facts_for/1` is called by `authorize_target_tenant/2` (section 8), the promotions checker (section 9), the `POST /roles` clause (section 10) and the `/me/memberships` flag (section 17). It reads `tenant_id` and `roles` from the passed context with `Map.get/3` (defaults `nil` and `[]`; a non-map input gives both facts `false`) and delegates to `scope_facts/2`. It never reads a stored `platform_scope?`/`platform_tenant?` key and no consumer reads those keys by dot access (a missing key must not raise; a hand-assigned test `auth_context` without them stays fail-closed). The `roles` it reads are the DB-resolved ones set by the pipeline (section 4).

`platform_scope?` is `platform_tenant?` AND `Authorization.roles_from_strings(role_strings)` contains `:PLATFORM_ADMIN` (per REQ-445 D4, `PLATFORM_ADMIN` is honoured only in the platform tenant).
`tenant_id` comes only from `conn.assigns.auth_context` (DB-resolved in `AuthPipeline`), never from a header, path, query, body or token claim.

### 3.1 The platform-tenant marker is not writable through any `/api/v1` route (ISS-0994 AC e)

Guarantee: the pin is deployment configuration read once at boot into application config. It is not a column, row, setting key or registry entry in any
table, so no request handler has anything to write. There is no "is_platform"-like field anywhere to protect.

Verified on this branch (read of the files named):
* `Tenant` changesets cast only these fields (lib/letflow/identity/tenant.ex): `create_changeset` `[:slug, :display_name, :status, :idp_realm_id]` (116-118; used by
  `POST /tenants` and onboarding); `update_changeset` `[:display_name, :status]` (136-138; verified DEAD CODE: no call site anywhere under `lib/`, the only references are two test files, `test/letflow/req442_tenant_mode_schema_test.exs` (line ~164) and `test/letflow/identity_test.exs` (lines ~607-640, the REQ-019 `idp_realm_id` immutability tests), plus comments; this design DELETES it and repoints both tests (section 13 A2), so no changeset reachable from a route casts `:status` except `status_changeset`, see below); `admin_patch_changeset` `[:display_name, :login_disclosure_mode]` (159-161);
  `status_changeset` `[:status]` (173-175); `settings_changeset` `[:settings]` (218-220). None names a platform marker.
* `PATCH /tenants/:slug` accepts only the `@patch_schema` allowlist `display_name`, `login_disclosure_mode` (routers/tenants.ex:322-337); unknown body keys (including `status`) are not cast and are ignored. `Tenant.update_changeset` casts `status` but has no caller under `lib/` (dead code, deleted; guard (0) below and test 17(0)); the sole writer of `:inactive` is `Identity.deactivate_tenant/1` -> `set_tenant_status/2`, which carries the platform-tenant guard (section 7.1). `PATCH /tenants/:slug` therefore has NO `status` key and cannot write `inactive`; a `status` in its body is ignored and the row is unchanged.
* The ONLY writers of `status: :inactive` are `Identity.deactivate_tenant/1` -> private `set_tenant_status/2` -> `Tenant.status_changeset/2` (identity.ex:1188, 1218-1228). The only other `status_changeset` caller is `TenantOnboarding` (tenant_onboarding.ex:204), which writes `:active`. The platform-tenant deactivation guard therefore lives in the domain function, not in a router handler (section 7.1 row 5, section 6 `TenantStatus`).
* `PATCH /tenant/settings` writes only keys in `TenantSettings.allowed_keys()` and `Tenant.brand_colors_allowed_keys()` (routers/tenant_settings.ex:97-108); unknown keys
  are rejected and audited. The `settings` map is a data bag: nothing in section 4 reads it, so a key placed there cannot influence `platform_tenant?`.
* `POST /tenants` and `POST /onboarding` create tenants through `Identity.create_tenant/1` and `TenantProvisioning`; neither reads the configuration key, and the new
  tenant's id is generated, so a new tenant cannot be created with the pinned id.
* `Letflow.PlatformTenant` exposes read functions only (section 3); there is no setter, and nothing under `lib/letflow/routers/` calls `Application.put_env` for it.

Residual (stated, not guarded by a route): an operator with database or deployment access can change the pin. That is deployment authority, outside the API trust boundary.

Guards (test 17, section 12): (0) (A2-only, separate test file, needs the deletion) a source scan asserts `Tenant.update_changeset` is not defined in `lib/letflow/identity/tenant.ex` and has no caller under `lib/` (deleted as dead code), and that every `Tenant.status_changeset` call under `lib/` sits in `identity.ex` `set_tenant_status/2` or `tenant_onboarding.ex`; (1) the cast-field lists of every remaining `Tenant` changeset and the `@patch_schema` field names are asserted by a test, so adding a platform-like
field to either fails the suite and forces a conscious decision; (2) a source scan fails when any file under `lib/letflow/routers/` or `lib/letflow/identity/` references
`PlatformTenant` other than through the read functions or `Application.put_env` with the config key; (3) request tests send a platform-like attribute to each tenant write route
and show no effect on scope.

## 4. The platform-scope fact in `auth_context`

Where computed: `Letflow.Plugs.AuthPipeline.attach_auth_context/4` (auth_pipeline.ex:370), the single place both the OIDC branch
(`live_roles` from `Identity.list_effective_role_names/2`) and the API-token branch (`verified.roles`) already converge, with
`tenant.id` resolved from the realm (`resolve_tenant_by_realm/1`) or, for API tokens, from the slug header whose token hash is looked up
in that tenant's own schema.

Shape (type documentation only):

```text
auth_context :: %{
  user_id: String.t(),
  tenant_id: String.t(),
  roles: [String.t()],
  platform_tenant?: boolean(),   # CACHE/assertion only (tests: equals recomputed value); never read for a decision, never by dot access
  platform_scope?: boolean()     # CACHE/assertion only; decisions recompute via platform_tenant?/1, scope_facts/2 or scope_facts_for/1 (section 3 lists who calls which)
}
```

Consumers:

* `Letflow.Plugs.Authorize` builds `AccessContext` with `platform_tenant?` RECOMPUTED by `PlatformTenant.platform_tenant?(tenant_id)`.
  It does not trust a value placed in `auth_context` (several router tests assign `auth_context` by hand; recomputation keeps them
  fail-closed and keeps one source of truth). A test asserts pipeline value == recomputed value for real requests.
* `Letflow.Plugs.TenantStatus` (section 6, A2).
* `authorize_target_tenant/2` (section 8) and the promotions checker (section 9) RECOMPUTE via `PlatformTenant.scope_facts_for(auth_context)` (section 3); they do not trust the stored `platform_scope?` flag. The stored `platform_tenant?`/`platform_scope?` keys in `auth_context` are informational (logging, tests comparing pipeline value to recomputed value); no authorization decision reads them.
* Later: REQ-449's `platform_tenant` key reads `platform_tenant?`.

`AccessContext` gains one field, `platform_tenant?: boolean()` (default `false`, not in `@enforce_keys`, so every existing construction
stays valid and fails closed). This name matches ISS-0994's suggestion.

## 5. Permission split and the permission scope table

New / changed permissions (names consistent with REQ-445/446 vocabulary; the user's suggested `:PlatformTenantsManage` was NOT adopted, see
conflict C1):

| Permission | Status | Scope | Meaning | Held by (this fix) |
|---|---|---|---|---|
| `:TenantsManage` | existing, narrowed | PLATFORM | the tenant registry and cross-tenant platform operations: `/tenants*`, `/onboarding*`, `/platform-migrations*`, `/event-retention*` | `PLATFORM_ADMIN` in the platform tenant only |
| `:PlatformServicesManage` | NEW | PLATFORM | the global service catalogue (`/admin/services*`); replaces the tenant permission `:UsersGroupsRolesManage` that these routes used by accident | `PLATFORM_ADMIN` in the platform tenant only |
| `:TenantSettingsManage` | NEW | TENANT | change the caller's OWN tenant settings/branding: `PATCH /tenant/settings` | `PLATFORM_ADMIN` catch-all (unchanged holder; REQ-447 grants to `TENANT_ADMIN`) |
| `:PromotionsRead` | NEW (REQ-446 name) | TENANT | read routes of the promotion pipeline in the caller's own tenant schema | `PLATFORM_ADMIN` catch-all |
| `:PromotionsManage` | NEW (REQ-446 name) | TENANT | create/plan/approve/reject/apply/run-assertions and the promote route; cross-tenant naming is separately limited by section 9 | `PLATFORM_ADMIN` catch-all |
| `:DefinitionsRollback` | NEW (REQ-446 name) | TENANT | `POST /definitions/:process_key/rollback`, own tenant only | `PLATFORM_ADMIN` catch-all |

Policy keys (`endpoint_policy_key/0`): add `:TenantSettingsManage`, `:PromotionsRead`, `:PromotionsManage`, `:DefinitionsRollback`.
`required_permission/1`: identity clauses for those four; `:AdminServicesRead` and `:AdminServicesManage` now map to `:PlatformServicesManage`
(they mapped to `:UsersGroupsRolesManage`; no non-`PLATFORM_ADMIN` role held it, so no grant changes). Remove the stale comment
"platform-admin enforced in handler" (authorization.ex:1013).
`core_permissions/0` grows from 35 to 40 (`:PlatformServicesManage`, `:TenantSettingsManage`, `:PromotionsRead`, `:PromotionsManage`,
`:DefinitionsRollback`). The count in `authorization_test.exs` stays computed, not hardcoded; the moduledoc wording "thirty-five/thirty-four" is
corrected to a statement that does not hardcode a number.

New function (pure, total): `permission_scope(permission :: permission() | atom()) :: :platform | :tenant`.
Rules: a core permission looks up the compile-time table below; an atom present in `Letflow.Modules.Catalog.permissions/0` is `:tenant`
(REQ-445 D3: every module permission is tenant scope); ANY OTHER atom is `:platform` (fail closed: an unclassified permission is never
honoured outside the platform tenant). Also `platform_permissions() :: [permission()]` derived from the table.

Scope table (every atom of `core_permissions/0` after this change; the validator re-derives the list by calling the function):

| Scope | Permissions |
|---|---|
| PLATFORM (2) | `TenantsManage`, `PlatformServicesManage` |
| TENANT (38) | `DefinitionsWrite`, `DefinitionsRead`, `DefinitionsRollback`, `InstancesStart`, `InstancesCancel`, `InstancesRead`, `InstancesAdvanceTimer`, `TasksRead`, `TasksComplete`, `TasksAssign`, `UsersGroupsRolesManage`, `TokensManage`, `RolesManage`, `AuditRead`, `DlqOperate`, `MetricsRead`, `WebhooksManage`, `AttachmentsManage`, `AttachmentsRead`, `EntitiesDefinitionsRead`, `EntitiesDefinitionsWrite`, `EntitiesRecordsWrite`, `EntitiesQuery`, `EntitiesAggregate`, `EntitiesRecordsExport`, `EntitiesRecordsExportUnredacted`, `EntitiesRecordsImport`, `EntitiesAttachmentsManage`, `EntitiesAttachmentsRead`, `EntitiesRestrictionsManage`, `PublicReadHandlesIssue`, `HelpRead`, `MembershipsRead`, `MyModulesRead`, `ModulesManage`, `TenantSettingsManage`, `PromotionsRead`, `PromotionsManage` |

Storage: a compile-time map `permission -> scope` in `authorization.ex`; a test asserts its key set equals `core_permissions/0` (a new permission
without a scope fails the suite, and also fails compilation of the test).

## 6. Evaluation rules

`evaluate_access/2` (pure; still no request data) after this change, in order:

1. `endpoint == :Unknown` -> `:Deny403` for EVERY role, `PLATFORM_ADMIN` included (A2; A1 keeps the legacy branch).
1a. (SHIPS IN A1, evaluated under the plug's legacy forcing, section 7.5.) Catch-all markers (`authz_unmatched(:platform_prefix | :ordinary)`, marker keys `:UnmatchedPlatformPath` / `:UnmatchedRoute`; section 7.5; endpoint keys, not permissions): `:UnmatchedPlatformPath` -> `:Allow` (the request then reaches the router's 404) iff `ctx.platform_tenant?` and `:PLATFORM_ADMIN in ctx.roles`, otherwise `:Deny403`; `:UnmatchedRoute` -> `:Allow` for `:PLATFORM_ADMIN` of any tenant (today's behaviour, unchanged), otherwise `:Deny403`. Neither reads a permission and neither is a route.
2. `endpoint == :MetricsRead` -> unchanged (`:Allow`, `task_scope: :all`; no route uses it today).
3. `required = required_permission(endpoint)`. If `permission_scope(required) == :platform` and NOT (`ctx.platform_tenant?` and `:PLATFORM_ADMIN in ctx.roles`)
   -> `:Deny403`. This is the explicit clause denying a platform permission to a `PLATFORM_ADMIN` of any other tenant. It is evaluated before the
   role matrix so it cannot be bypassed by the catch-all.
4. Otherwise unchanged (`has_permission?/2`, task row filter).

New public helper `has_permission_in_scope?(roles :: [role()], permission :: permission() | atom(), platform_tenant? :: boolean()) :: boolean()`
implementing rule 3 + `has_permission?/2`; REQ-449 reuses it. `role_allows?/2` is unchanged (it stays the role matrix; REQ-448's parity test reads
`PLATFORM_ADMIN` "as evaluated in the platform tenant").

`Letflow.Plugs.Authorize` (authorize.ex:97-126): builds `AccessContext` with `platform_tenant?` (section 4); resolves the key from
`conn.private[:policy_key]`, defaulting to `:Unknown` (kept: a handler path that sets no key evaluates `:Unknown` and denies everyone; router catch-alls set a marker key instead, rule 1a and section 7.5; OQ-4 resolved).

`Letflow.Plugs.TenantStatus` (tenant_status.ex ~:102, A2): the deactivated-tenant exemption applies only when
`PlatformTenant.scope_facts(tenant.id, raw_roles).platform_scope?` is true. Any other role, including a `PLATFORM_ADMIN` of the deactivated tenant,
gets 403 `tenant_inactive`. Reject deactivating the platform tenant INSIDE the domain function (guard in `Identity.set_tenant_status/2` for the `:inactive` target, section 7.1), not in a router handler, so EVERY caller of `Identity.deactivate_tenant/1` is covered and the exemption cannot lock the operator out. The guard compares the resolved ROW id (not the slug, not a request value) with `PlatformTenant.configured_id/0` and returns `{:error, :platform_tenant_protected}` before any write. Spec: `deactivate_tenant(slug) :: {:ok, Tenant.t()} | {:error, :not_found | :platform_tenant_protected}`. `PATCH /tenants/:slug` has no `status` key (section 3.1), so it needs no guard.

Shadow-log content (confirmed): the line carries ONLY the policy key and one boolean (`platform_tenant`), as in the form below; no tenant id, user id, role, slug or token data, and no other log statement is added in A1.

### A1 shadow mode (rollout support, deleted in A2)

In A1 `Authorize` enforces the LEGACY outcome by evaluating with `platform_tenant?` forced to `true` (identical to today's behaviour for the
platform permissions) and ALSO evaluates with the real value. When the two decisions differ it emits exactly one `Logger.warning` line of the fixed form
`platform_scope_shadow_deny key=<PolicyKey> platform_tenant=<true|false>` and nothing else (no ids, no roles, no tenant identifiers). The response is
unaffected. A2 deletes the forcing and the log line. Purpose: infra can prove from QA logs that the seeded operator account has platform scope and that
ordinary tenant admins would be denied, before enforcement is switched on.

## 7. Complete route scope table

Mount: everything below is under `/api/v1` and passes `Letflow.Plugs.ApiPipeline` (AuthPipeline -> Admission -> TenantStatus -> router -> Authorize),
except section 7.4. Counts (verified by walking `lib/letflow/routers/*.ex`, `lib/letflow/modules/exam/router.ex` and `api_pipeline.ex` on this branch):
137 declared routes under `ApiPipeline` = 125 `authz_*` + 12 plain-macro; plus 6 unauthenticated global routes.

| Scope class | Routes |
|---|---|
| PLATFORM | 21 |
| OWN-TENANT (re-keyed or newly keyed in this fix) | 13 |
| OWN-TENANT (unchanged keys) | 103 |
| GLOBAL-PUBLIC (not under `ApiPipeline`) | 6 |
| Route resolving to `:Unknown` after A2 | 0 (router-level `match _` catch-alls are not routes; they carry the private markers of section 7.5) |

### 7.1 PLATFORM scope (21 routes). Non-platform callers (including `PLATFORM_ADMIN` of any other tenant) -> 403 problem+json, no data, no side effect

| # | Method | Path | Current key -> permission | New key -> permission | Handler tenant check |
|---|---|---|---|---|---|
| 1 | POST | /tenants | `:TenantsManage` | `:TenantsManage` (platform) | platform gate; no tenant id from caller |
| 2 | GET | /tenants | same | same | platform gate |
| 3 | GET | /tenants/:slug | same | same | platform gate + `authorize_target_tenant` (defence in depth) |
| 4 | PATCH | /tenants/:slug | same | same | platform gate + `authorize_target_tenant`; also covers `login_disclosure_mode` (REQ-442, a platform-security attribute); `status` is NOT in the `@patch_schema` allowlist, so the body key `status` is ignored and the row is unchanged (no 409 path here; section 3.1) |
| 5 | POST | /tenants/:slug/deactivate | same | same | platform gate + `authorize_target_tenant`; target is the platform tenant -> 409, row unchanged; the guard lives in the context, see below the table (INV-10 item 5) |
| 6 | POST | /tenants/:slug/reactivate | same | same | platform gate + `authorize_target_tenant` |
| 7 | POST | /onboarding | same | same | platform gate (creates tenants; slug in body is a NEW tenant) |
| 8 | GET | /onboarding/:id | same | same | platform gate |
| 9 | GET | /onboarding | same | same | platform gate |
| 10 | POST | /platform-migrations/rollouts | same | same | platform gate (fans out over all tenants) |
| 11 | GET | /platform-migrations/rollouts/:id | same | same | platform gate |
| 12 | POST | /platform-migrations/rollouts/:id/resume | same | same | platform gate |
| 13 | GET | /event-retention/summary | same | same | platform gate (all tenants' partitions) |
| 14 | POST | /event-retention/retirements | same | same | platform gate |
| 15 | GET | /event-retention/retirements/:id | same | same | platform gate |
| 16 | GET | /admin/services | `:AdminServicesRead` -> `:UsersGroupsRolesManage` | `:AdminServicesRead` -> `:PlatformServicesManage` (platform) | platform gate |
| 17 | POST | /admin/services | `:AdminServicesManage` -> `:UsersGroupsRolesManage` | `:AdminServicesManage` -> `:PlatformServicesManage` | platform gate; body `owner_tenant_id` is platform-supplied |
| 18 | PATCH | /admin/services/:service_id | same | same | platform gate |
| 19 | DELETE | /admin/services/:service_id | same | same | platform gate |
| 20 | POST | /admin/services/:service_id/versions | same | same | platform gate |
| 21 | POST | /admin/services/:service_id/retire | same | same | platform gate |

Platform-tenant deactivation guard (covers every caller, not only this handler): the only writer of `status: :inactive` is `Identity.deactivate_tenant/1` -> `set_tenant_status/2` (identity.ex:1188, 1218; `Tenant.status_changeset/2`; `TenantOnboarding` writes only `:active`). The guard is INSIDE `set_tenant_status/2` for the `:inactive` target: after resolving the tenant by slug, compare `tenant.id` (the resolved row id, not the slug) with `PlatformTenant.configured_id/0`; equal returns `{:error, :platform_tenant_protected}` before any write. The router maps that error to 409 (problem+json, fixed message, no ids); `reactivate` is unaffected. With the pin unset nothing is protected (no platform tenant exists).

Classification of `/admin/services*` (explicit decision, justification): PLATFORM scope. `Letflow.ServiceCatalog.list_all/1` performs no tenant filtering
(admin_services.ex moduledoc "Cross-tenant-404"; every entry of every tenant, with `owner_tenant_id` and `scope`, is visible and writable); the table is
global, not in a tenant schema. The tenant-facing catalogue is the separate, tenant-filtered `GET /services` (own-tenant, row 7.3). Consequence:
`scripts/uat_preflight.sh` ~:603 (`actor-platform-admin` probes `/api/v1/admin/services`) cannot succeed with a tenant-realm account; see section 13 and
OQ-8.

`/onboarding*`, `/platform-migrations*`, `/event-retention*`: PLATFORM (create tenants, run migrations across all tenants, retire event partitions of all tenants).
`/promotions*` including `platform-events`: not platform scope, see 7.2/7.3 and section 9.

### 7.2 OWN-TENANT, re-keyed or newly keyed (13 routes)

| # | Method | Path | Current | New key -> permission | Handler tenant check |
|---|---|---|---|---|---|
| 22 | PATCH | /tenant/settings | `:TenantsManage` | `:TenantSettingsManage` -> `:TenantSettingsManage` (tenant) | target is `auth_context.tenant_id` only; no tenant parameter exists (tenant_settings.ex handle_patch) |
| 23 | POST | /promotions | `:Unknown` (plain `post`) | `:PromotionsManage` | `authorize_target_tenant` on body `source_tenant_id` AND `target_tenant_id` (section 9) |
| 24 | POST | /promotions/plan | `:Unknown` | `:PromotionsManage` | same as 23 |
| 25 | GET | /promotions/platform-events | `:Unknown` | `:PromotionsRead` | none needed: verified read-only; reads the sentinel event stream inside the caller's own tenant schema (`EventStore.list_platform_events/1`, event_store.ex:1110-1130, `prefix:` from `scoped_opts`); no other tenant's rows. Payload of promotion events carries source/target tenant UUIDs of promotions INTO the caller's tenant (platform_events.ex:66-98); residual note in OQ-2 |
| 26 | GET | /promotions/:id | `:Unknown` | `:PromotionsRead` | review looked up in own schema (INV-5 by construction, promotions.ex moduledoc) |
| 27 | GET | /promotions/:id/context | `:Unknown` | `:PromotionsRead` | same |
| 28 | POST | /promotions/:id/approve | `:Unknown` | `:PromotionsManage` | own schema |
| 29 | POST | /promotions/:id/reject | `:Unknown` | `:PromotionsManage` | own schema |
| 30 | POST | /promotions/:id/apply | `:Unknown` | `:PromotionsManage` | re-check stored `source_tenant_id`/`target_tenant_id` of the review with `authorize_target_tenant` before applying (a review row written before the fix must not be able to write elsewhere) |
| 31 | POST | /promotions/:review_id/run-assertions | `:Unknown` | `:PromotionsManage` | re-check stored ids as in 30 |
| 32 | GET | /promotions | `:Unknown` | `:PromotionsRead` | own schema |
| 33 | POST | /definitions/:process_key/rollback | `:Unknown` | `:DefinitionsRollback` | own schema (`scoped_opts`); checker replaced (section 9) |
| 34 | POST | /tenants/:test_tenant_id/promote/:process_key | `:Unknown` | `:PromotionsManage` | `authorize_target_tenant` on path `test_tenant_id` (source); target is `auth_context.tenant_id` (tenants.ex:196-198). Confirmed by letflow-9a (REQ-445 owner): a non-operator caller is accepted ONLY when `:test_tenant_id` equals its own DB-resolved tenant id (a tenant admin is NOT allowed "any test tenant" as source); another existing tenant's id, a nonexistent id and a malformed id all return the existing 404 with byte-identical bodies, never 403 (it would reveal existence) and never 200; the check runs BEFORE any lookup of the source tenant (no existence oracle, no read or touch of any source-tenant schema); only the platform-tenant operator may name a different source (OQ-2). Row 34 stays excluded from the uniform-403 rule (test 19); covered by test 20 |

Note: row 34 lives in `Letflow.Routers.Tenants`, mounted at `/tenants`. It is the ONLY non-platform route under that mount. After the key change the router's
other six routes are platform and this one is own-tenant; the guard test (section 11) pins both sets by name.
The 12 formerly-`:Unknown` routes are rows 23-34; row 22 is the sole re-key. 12 + 1 = 13.

Classification rule (ruling on OQ-2, REQ-445 owner): ONLY a request that reads or writes a tenant OTHER than the caller's is operator-only. That is decided per request by `authorize_target_tenant` (section 8): a foreign source/target id yields 404 for a non-platform caller and `:ok` for the platform operator. Own-tenant promotion review/approve/reject/apply/run-assertions/list/get and own-tenant definition rollback STAY TENANT scope under `:PromotionsRead`, `:PromotionsManage` and `:DefinitionsRollback` (rows 23-33 on the caller's own tenant); none of them is moved to a platform permission and `permission_scope/1` keeps all three `:tenant`. Row 34 follows the same rule: its source (`test_tenant_id`) is the only caller-supplied tenant and is checked by the helper, its target is the caller's own tenant.

### 7.3 OWN-TENANT, unchanged keys (103 routes). Handler tenant check: none needed, tenant derived only from `auth_context.tenant_id` via `scoped_opts` (INV-1); no tenant identifier is read from path/query/body

| Router (mount) | Count | Routes (method path -> key) |
|---|---|---|
| Identity (`/identity`) | 16 | POST,GET /users, GET,PATCH /users/:id, POST /users/:id/status -> `UsersManage`; POST,GET /groups, DELETE /groups/:id, POST,GET /groups/:id/members, DELETE /groups/:id/members/:user_id -> `GroupsManage`; POST,GET /tokens, DELETE /tokens/:id -> `TokensManage`; GET,POST /roles -> `RolesManage` (POST /roles gets an extra clause in A2, section 10) |
| Audit (`/audit`) | 1 | GET / -> `AuditRead` |
| Definitions (`/definitions`) | 15 | POST /import `DefinitionsImport`; POST / `DefinitionsCreate`; POST /:id/activate, /deprecate, /archive; PUT,PATCH,DELETE /:id; GET /active/:name, /search, /delta, /:id/export, /:id, /; POST /:id/validate (route-declared `:DefinitionsRead`, on the test allowlist) |
| Dlq (`/dlq`) | 4 | GET /, GET /:id, POST /:id/retry, POST /:id/discard -> `DlqReadRetryDiscard` |
| Entities (`/entities`) | 18 | definitions (6): POST /definitions, POST /definitions/:name/activate -> `EntitiesDefinitionsWrite`; GET /definitions, /definitions/:id, /definitions/active/:name, /definitions/by-name/:name -> `EntitiesDefinitionsRead`; records (3) POST,PUT,DELETE -> `EntitiesRecordsWrite`; POST /records/:t/import `EntitiesRecordsImport`; POST /records/:t/export `EntitiesRecordsExport`; POST /restrictions/import `EntitiesRestrictionsManage`; POST /query `EntitiesQuery`; POST /query/aggregate `EntitiesAggregate`; attachments (4) -> `EntitiesAttachmentsManage`/`Read` |
| Help (`/help`) | 1 | GET /resolved -> `HelpRead` |
| Instances (`/instances`) | 17 | POST /, /:id/cancel, /:id/rebind-pins (declared `InstancesCancel`), /:id/reconstruct (declared `InstancesCancel`), /:id/advance-timer; GET /, /:id, /:id/history, /:id/timeline, /:id/pins -> `Instances*`; attachments (6) + GET /storage-usage -> `AttachmentsManage`/`AttachmentsRead` |
| Me (`/me`) | 2 | GET /memberships `MembershipsRead`; GET /modules `MyModulesRead` |
| PublicReadHandles (`/public-read-handles`) | 1 | POST / -> `PublicReadHandlesIssue` |
| Services (`/services`) | 1 | GET / -> `ServicesRead` (tenant-filtered catalogue) |
| SolutionPacks (`/solution-packs`) | 4 | POST /export, /install, /:pack_id/update-review, /:pack_id/update-apply -> route-declared `DefinitionsRead`/`DefinitionsCreate` (test allowlist) |
| Tasks (`/tasks`) | 7 | GET /inbox, GET / `TasksList`; GET /:id `TasksGetById`; POST /:id/complete, /claim `TasksComplete`; POST /:id/assign `TasksAssign`; POST /:id/reassign `TasksReassign` |
| TenantModules (`/tenant/modules`) | 2 | POST /, PUT /:module_id/settings -> `ModulesManage` |
| TenantSolutions (`/tenant/solutions`) | 1 | POST / -> `ModulesManage` |
| Webhooks (`/webhooks`) | 5 | GET,POST /subscriptions, PATCH,DELETE /subscriptions/:id, GET /subscriptions/:id/deliveries -> `WebhookSubscriptionsManage` |
| Exam module (`/modules/exam`) | 8 | module-manifest permissions (`ExamSession*`, `ExamCertificateIssue`), scope TENANT by rule; reached only through `Letflow.Routers.Modules`, which 404s before authorization when the module is not installed |
| Total | 103 | |

Module routes of any other registered Catalog module resolve through `module_route_permission/3`; an unregistered module id or a path without a
`route_policies` entry resolves to `:Unknown` and is therefore denied (A2) for everyone.

### 7.4 GLOBAL-PUBLIC (6 routes, unauthenticated by design, outside `ApiPipeline`; unchanged)

`GET /health`; `GET /api/tenant-config`; `GET /api/mobile/tenant-config`; `GET /metrics`; `GET /api/public/:kind/:handle`; `POST /api/login-discovery`.
They never read `auth_context`; scope separation does not apply. The guard test lists them by name so a seventh must be added consciously.
`GET /health` and `GET /metrics` are among these six already (verified in `lib/letflow/router.ex`: `get "/health"` at ~line 106, `forward("/metrics", to: Letflow.Routers.MetricsExposition)` at ~line 125, both outside the `/api/v1` forward), so the count of 6 and every dependent count and table stay as they are. Per the REQ-194 decision they are GLOBAL-PUBLIC and are NOT put behind the platform pin (OQ-13 resolved). The permission atom `:MetricsRead` is TENANT scope in the scope table (section 5; existing grants stay valid; a future per-tenant metrics route would use it); no route uses it today.

### 7.5 Router catch-alls, the two markers, and the uniform 403 under the platform prefixes

28 routers end with `match _` (404). They carry no permission and today evaluate to `:Unknown`. Denying `:Unknown` for everyone (A2) must not turn the operator's 404 on an unmatched path into a 403 (a usability regression with no security gain). Design: a catch-all is declared through ONE `AuthorizedRouter` macro `authz_unmatched(kind :: :platform_prefix | :ordinary)` that sets `conn.private[:policy_key]` to a private marker and then returns the existing 404; evaluation is rule 1a of section 6.

* The five routers mounted at `/tenants`, `/onboarding`, `/platform-migrations`, `/event-retention`, `/admin/services` declare `:platform_prefix`, key `:UnmatchedPlatformPath`.
* Every other router declares `:ordinary`, key `:UnmatchedRoute` (today's outcome kept: `PLATFORM_ADMIN` reaches the 404, other roles get 403; no behaviour change outside the five prefixes).

ANSWER to the supervisor's question: does the design return 403 to the OPERATOR on unmatched paths? NO. A platform-tenant `PLATFORM_ADMIN` (`platform_scope?` true) is `:Allow` on `:UnmatchedPlatformPath` and so keeps today's 404 on an unmatched path under all five prefixes (and on `:UnmatchedRoute` everywhere else). The earlier draft of this section and OQ-4 ("uniform 403 for everyone") is superseded.

Uniform-403 rule (ruling on OQ-4, ACCEPTED, restated): for a caller who is NOT a platform-tenant operator, every request under `/tenants`, `/onboarding`, `/platform-migrations`, `/event-retention`, `/admin/services` returns the SAME 403 problem+json with a byte-identical body (and the same status and content type), whether the path matches a route or not and whether or not the addressed resource exists. Mechanism: matched platform routes deny at the platform permission (rule 3, before any handler runs, so no lookup and no existence signal); unmatched paths deny at `:UnmatchedPlatformPath`; both use the same `Authorize` denial response builder. Single stated exception: row 34 (`/tenants/:test_tenant_id/promote/:process_key`, own-tenant scope, section 7.2) is a tenant-scope route inside the `/tenants` mount; for it the foreign-source 404 of section 8 is byte-identical to a nonexistent source, and it is not subject to the uniform-403 rule (the other six `/tenants` routes and every unmatched `/tenants/...` path are). A1: both markers evaluate under the same legacy forcing as the platform permissions, so the outcome equals today's.

Verify: named test 19 (section 12); grep tests that assert 404 for an unknown sub-path with an admin caller: operator callers keep their expectation, ordinary-tenant admin callers under the five prefixes change to 403 (update the expectation, not the intent).

## 8. `authorize_target_tenant` helper contract

Module: `Letflow.Api.TenantTarget` (`lib/letflow/api/tenant_target.ex`), pure, no DB, no Repo.

```text
authorize_target_tenant(conn :: Plug.Conn.t(), target :: String.t() | nil) :: :ok | {:error, :not_found}
```

Rules, in order:
1. `PlatformTenant.scope_facts_for(Map.get(conn.assigns, :auth_context))` has `platform_scope?: true` -> `:ok` (platform operator may name any tenant). The stored flag is not read; a missing `auth_context` or missing keys yield false (no `KeyError`).
2. `target` is a canonical-UUID string equal (case-insensitively) to `Map.get(auth_context, :tenant_id)` (never dot access: a hand-assigned context cannot raise) -> `:ok`.
3. Anything else, including `nil`, a UUID of another tenant, a malformed id, and a slug -> `{:error, :not_found}`.

Error shape: the helper never builds a response. The handler maps `{:error, :not_found}` to `Letflow.Api.Response.not_found(conn)`, the SAME zero-argument
helper every existing 404 uses, so the bytes equal those of a nonexistent tenant (INV-5). The call happens BEFORE any lookup of the target (no extra DB
round trip on the denied path, so no timing difference from a nonexistent id).
Row 34 (promote route), explicitly: for a non-operator caller, rule 2 means `authorize_target_tenant` accepts ONLY the caller's own tenant id as `:test_tenant_id`; it does NOT accept "any test tenant" as the source for a tenant admin. Every other value (another EXISTING tenant's id, a nonexistent id, a malformed id) falls to rule 3 and the handler answers the same `Response.not_found(conn)` bytes, never 403 and never 200. Because the helper is pure and is called before any lookup, the source tenant's existence is not observable and its schema is never queried. Sections 8 and 9 already specify exactly this (rules 2-3 and the "before any lookup" sentence); this paragraph only makes it explicit (letflow-9a confirmation). If the promote handler later gains a tenant-pairing model (follow-up from letflow-9a), ONLY the equality rule (rule 2) in `authorize_target_tenant` changes; the call site, the 404 mapping and the ordering stay.
Where applied: rows 3, 4, 5, 6 (defence in depth; the platform gate already denies), 23, 24, 30, 31, 34. A slug argument is only ever accepted with platform
scope: a non-platform caller never has a legitimate path-supplied tenant slug, because its own tenant is implicit.
Handlers never read a stored `platform_scope?` by dot access; platform-scope decisions in handlers go through `scope_facts_for/1` (or the helper above). Unit test: an `auth_context` lacking both flag keys, and one carrying a forged `platform_scope?: true` with a non-platform tenant id, both yield `{:error, :not_found}` for a foreign target and do not raise.

## 9. Promotions: closing the cross-tenant read/write

Verified facts (file:line): `PromotionPlan.default_permission_checker/2` always returns `true` (promotion_plan.ex:179-180); `default_tenant_classifier/1` always
returns `:test` (promotion_plan.ex:189-190); `POST /promotions` and `/plan` take BOTH `source_tenant_id` and `target_tenant_id` from the body
(promotions.ex:261-288, 307-308); apply writes into the stored target; the promote route takes the source from the path (tenants.ex:204-205) and the target
from `auth_context`. There is no tenant pairing data (no column relating a test tenant to its production tenant), so ownership of the source cannot be
proven from data. Therefore:

* New module `Letflow.Definitions.PromotionAccess`: `checker_for(auth_context :: map()) :: (actor_id :: Ecto.UUID.t(), source_tenant_id :: Ecto.UUID.t() -> boolean())` returns a function
  (invoked as `checker.(actor_id, source_tenant_id)`, promotion.ex:171,236; promotion_plan.ex:131) that ignores the FIRST argument and compares the SECOND argument (`source_tenant_id`) with the caller's tenant id; it is `true` iff they are equal or `PlatformTenant.scope_facts_for(auth_context).platform_scope?` is true (recomputed when the closure is built; the stored flag is never read, no dot access; a missing key cannot raise). Every call site that today passes
  `&PromotionPlan.default_permission_checker/2` passes `PromotionAccess.checker_for(conn.assigns.auth_context)` instead (promotions.ex submit/plan/apply/rerun
  call sites, tenants.ex handle_promote, definitions.ex handle_rollback). `PromotionPlan.default_permission_checker/2` is deleted from `lib/`; tests that need
  an allow-all checker use a test-only support module. Post-condition: `grep -rn default_permission_checker lib/ --include=*.ex`, excluding `lib/letflow/design/`, has zero hits; the `promotions.ex` moduledoc mentions (~lines 147-165, the "permission_checker gap" section) are rewritten as part of this change.
  ELIXIR-DEV verifies which tenant id `rollback_definition_version/4` passes to the checker; if it is the caller's own tenant the closure returns `true`.
* `authorize_target_tenant` on both ids of R1/R2 and on stored ids of R7/R8 (rows 23, 24, 30, 31) and on the promote route's source (row 34).
* Interim effect, stated plainly: without a pairing model, a non-platform caller can only name its own tenant on both sides, i.e. cross-tenant promotion
  becomes an operator (platform tenant) action. Own-tenant review lifecycle (list, get, approve, reject, apply, run-assertions on an existing own review) and own-tenant definition rollback are unchanged and stay tenant scope (the rule is per request: only a foreign source/target is operator-only, section 7.2).
  PRODUCT LIMITATION, stated plainly (ruling OQ-2, ACCEPTED): a customer can no longer promote from its test tenant to its production tenant by itself; the operator does it. A tenant-pairing-model requirement will follow from letflow-9a. PR description sentence (copy into PR A1 and A2): "Product limitation: a customer can no longer promote from its test tenant to its production tenant by itself; the operator (platform tenant) does it until a tenant-pairing model is specified."
  The existing platform UAT scenario `definition-promotion-approved` runs as the seeded operator account (see section 15), so it keeps working when the
  operator account is in the platform tenant. A real tenant-pairing model is a follow-up (OQ-2).
* `tenant_classifier` stays as is (out of scope; REQ-446's open question).

## 10. Role-claim and escalation analysis (what platform scope depends on)

Platform scope depends on exactly three facts, none of which is a tenant-editable name:
1. `tenant_id` = `tenant.id` resolved by `Identity.resolve_tenant_by_realm/1` from the token's verified issuer realm (auth_pipeline.ex:271-290) or, for API tokens,
   from the slug header whose token hash must exist in that tenant's own schema (auth_pipeline.ex:141-150, 227-233). The realm-to-tenant binding is a 1:1
   bijection, immutable after creation (decision 0006 R5; unique partial index; `update_changeset` omitted `idp_realm_id`; after the A2 deletion the remaining changesets omit it, proven by the repointed REQ-019 tests in `identity_test.exs`, test 10(e) and test 17(a)).
2. `tenant_id == LETFLOW_PLATFORM_TENANT_ID` (server configuration; no route writes it).
3. `PLATFORM_ADMIN` in the effective roles read per request from that tenant's own schema (`Identity.list_effective_role_names/2`, kind `:platform_role`) or the
   token's stored roles. A claim in the bearer token alone is never read as a role for authorization.

Analysis of the ways a role named `PLATFORM_ADMIN` can appear in an ordinary tenant:
* Realm claim sync (`Identity.sync_role_claims_from_token/3`, identity.ex:846): a tenant realm may claim `PLATFORM_ADMIN`; it is synced into that tenant's
  `group_members`. Result: role present, `platform_tenant?` false, so no platform scope. Tenant-scope catch-all remains until REQ-447.
* `POST /roles` / `RoleRegistry.upsert_role/4` with name `PLATFORM_ADMIN`: allowed today for any `:RolesManage` holder (in particular `PROCESS_DESIGNER`) because the
  name is in `Authorization.roles/0` (role_registry.ex:94-104). Same result in another tenant (no platform scope). INSIDE the platform tenant it would let a
  `PROCESS_DESIGNER` rebind the operator role to its own group, an intra-platform escalation. Hardening H1 (A2): the `POST /roles` handler returns 403 when the submitted name is a `PLATFORM_ADMIN` name and `PlatformTenant.scope_facts_for(auth_context).platform_scope?` is false (recomputed, not the stored flag). The name predicate is ONE function, `Authorization.platform_admin_name?(name :: term()) :: boolean()`, defined as `:PLATFORM_ADMIN in roles_from_strings([name])` (the SAME parser that turns stored/token role strings into roles, authorization.ex:492-509) OR the defensive fold `String.upcase(String.trim(name))` equals `"PLATFORM_ADMIN"` for a binary name; a non-binary name is a 422 before this check. Verified on this branch: `roles_from_strings/1` and `RoleRegistry.upsert_role/4` (`name in platform_role_names()`) match EXACTLY (case-sensitive, no trim, no aliases), so today only the exact literal is a platform role and variants are rejected by `upsert_role/4` for `kind: platform_role`; the defensive fold is deliberately stricter than the parser so that a later loosening of the parser (case folding, aliases) cannot open a bypass, and any alias the parser later accepts must be added to the predicate by construction (it calls the parser). The check is independent of `kind`, runs before any `upsert_role/4` call, and the 403 body names no role. Test (item 10(g)): name variants (exact, lower, mixed case, leading/trailing whitespace, tab/newline padded, and every alias form `roles_from_strings/1` accepts at implementation time) by a non-platform-scope `PROCESS_DESIGNER`, for both kinds, return 403 and no `tenant_role` row changes; a unit test of `platform_admin_name?/1` pins the predicate to `roles_from_strings/1` (for each of the six role literals it agrees; any string the parser maps to `:PLATFORM_ADMIN` is true). REQ-447 later rejects the name outright in non-platform tenants.
  Justification for H1 (kept in A2, checked against the code): `POST /roles` is keyed `:RolesManage` (authorization.ex:712-713), which `PROCESS_DESIGNER` holds (authorization.ex:709-711 comment), and `RoleRegistry.upsert_role/4` accepts the name `PLATFORM_ADMIN` as a recognised platform role (role_registry.ex:94-104) with no caller-role check. Platform scope depends on the `PLATFORM_ADMIN` binding (fact 3 above), so without H1 a lesser role inside the platform tenant could rebind the operator role and gain platform authority. ISS-0993's aim (platform authority only for the platform operator) needs the binding to be changeable only by platform scope; the one-clause change is therefore part of the fix, not unrelated creep. It goes slightly beyond the literal ISS-0994 AC list and is called out so REVIEWER can overrule.
* Group membership in the group bound to `PLATFORM_ADMIN`: requires `:UsersGroupsRolesManage`, held only by `PLATFORM_ADMIN`; a tenant `PLATFORM_ADMIN` can add members to
  its own tenant's group, which yields no platform scope (fact 2 fails).
* API tokens: `POST /tokens` accepts `PLATFORM_ADMIN` in any tenant (`@issuable_token_roles`, identity.ex:1335). A token is verified against the tenant named in
  the slug header, so a token minted in tenant A is unknown in the platform tenant's schema (401) and, presented as tenant A, has no platform scope.
* Renaming a tenant, its display name, its group names, its slug, or setting settings keys never changes fact 1 or 2.
* Platform realm hygiene (operational, in the seeding contract): the platform realm must have no self-registration and no brokered IdP; whoever can obtain realm
  role `PLATFORM_ADMIN` in that realm is the operator.

## 11. Route-inventory guard test (extends `test/letflow/api/authorization_enforcement_test.exs`)

Why: the current test lists routers by hand (`@routers`, `@mount_prefix`); it omits Dlq, Webhooks, PlatformMigrations, EventRetention, TenantModules,
TenantSolutions and PublicReadHandles, and it treats plain-macro routes as invisible (it asserts Promotions declares zero `authz_*` routes). The new guard closes both.

Three layers (all in this PR; none depends on running the app):

* G0 compile-time: `Letflow.Api.AuthorizedRouter.__using__` re-imports `Plug.Router` WITHOUT the plain `get/post/put/patch/delete/head/options` macros (keeping
  `match/2` for the router catch-all and `forward/2`), so a plain-macro route no longer compiles. If ELIXIR-DEV finds the import restriction unworkable, G1 is
  the substitute and the reason is recorded in the PR.
* G1 source scan (precedent: `INV-RT-1`/T-19 in `req078_supporting_routes_test.exs`, a source scan over `lib/letflow/routers/`): scan `lib/letflow/routers/**/*.ex` and
  `lib/letflow/modules/**/router.ex` for route declarations that are not `authz_*`, not `match _`, not `forward`; fail with `file:line`. The public routers
  (`login_discovery`, `metrics_exposition`, `mobile_tenant_config`, `public_read`, `tenant_config`) are named on an explicit public allowlist of six `{file, method, path}` entries
  matching section 7.4. The scan function takes source text, so one test feeds it a literal bad snippet and asserts it is flagged (the REQ-446 "demonstrated once"
  requirement) without compiling a bad route.
* G2 route table: discover every module that exports `__authz_routes__/0` (via `Application.spec(:letflow, :modules)`), and derive `{router, mount prefix}` by parsing
  the `forward("<prefix>", to: <Module>)` lines of `api_pipeline.ex`. Fail when a mounted router is missing from the discovered set or when the manual `@mount_prefix` map
  disagrees. Then for every route: (a) resolved key is never `:Unknown`; (b) `required_permission(key)` is a core permission or a Catalog permission (never the identity
  fallback for an unknown atom); (c) ONE classification rule (same as section 5): a core permission is classified explicitly in the scope table; a Catalog (module) permission is classified by rule as `:tenant` (REQ-445 D3) and needs no table entry. The test asserts every permission atom reachable from a route, from `core_permissions/0` or from `Catalog.permissions/0` is in exactly one of those two sets; an atom in neither would hit the runtime fail-closed fallback (`:platform`) and therefore FAILS the test (an unclassified permission fails the build); (d) the resolved permission of every route is one of those classified atoms.
* G3 platform pinning: a snapshot `@platform_routes` list of the 21 rows of 7.1. Assert the set of routes whose permission scope is `:platform` equals the snapshot
  exactly (adding a platform route, or silently demoting one, requires editing the snapshot). Assert `platform_permissions/0 == [:TenantsManage, :PlatformServicesManage]`
  (order-insensitive). Assert pure `evaluate_access` for every platform key: `PLATFORM_ADMIN` with `platform_tenant?: false` -> `:Deny403`; with `true` -> `:Allow`;
  every other role with `platform_tenant?: true` -> `:Deny403`.
* G4 tenant-identifier scan (overlaps the handler-level tests 5, 7 and 11; G4 may be dropped if it proves brittle, without weakening G0-G3 and those handler tests): scan routers for tenant-bearing request parameters (`tenant_id` in a `FieldConstraint` name, `conn.params[...tenant...]`, `:slug`) and require each
  file on `@tenant_param_allowlist` (promotions, tenants, admin_services, onboarding), and each allowlisted router to reference `TenantTarget.authorize_target_tenant` or to
  be a platform-only router. A new router reading a tenant id without the helper fails.

What breaks when `:Unknown` is denied, and how to verify: (1) the 12 formerly-plain routes get keys (rows 23-34); (2) every `match _` catch-all is keyed by a marker (section 7.5): the operator keeps the 404 everywhere, and non-operator callers get 403 under the five platform prefixes (outside them nothing changes); (3) module routes without a
`route_policies` entry deny. Verify: run the full suite; run G1/G2; run the platform and own-tenant request matrix (section 12) on QA after A2.

## 12. Test list (real Postgres, ExUnit; names are file-level groups, each bullet is at least one test)

Fixtures: `TenantFixture.provisioned_tenant!` for tenants P (platform, configured), A (ordinary), B (victim). A new support helper
`Letflow.Support.PlatformTenantFixture.with_platform_tenant!(tenant_id, fun)` sets/clears the application config key around a test; modules using it are
`async: false` (precedent: `BpmDefaultRealmDisplacement`, iss0112b). Existing router tests that hand-assign `auth_context` for `PLATFORM_ADMIN` on platform routes switch their
tenant fixture to P and configure it; no assertion is weakened or deleted (ISS-0994 AC2). `tenants_test.exs:39-41` comment describing the old rule is rewritten.

1. `test/letflow/platform_tenant_test.exs` (async): `parse_env` (nil, blank, whitespace, upper-case -> canonical lower, braces/garbage -> `{:error, :invalid_uuid}`); `platform_tenant?` false when unset for every input including nil;
   equality when set; `scope_facts` with and without the role.
2. `test/letflow/runtime_config_platform_tenant_test.exs`: malformed value stops evaluation of the runtime config with the fixed message and the message does not contain the value (follow the REQ-439 runtime-config test pattern).
3. `test/letflow/api/authorization_test.exs` (extend): every core permission has a scope (key-set equality); platform list exact; Catalog atoms tenant; unknown atom -> platform; core count computed; `evaluate_access` grid roles x `platform_tenant?` x platform keys;
   `:Unknown` denied for all roles including `PLATFORM_ADMIN`; `has_permission_in_scope?`; `PATCH /tenant/settings` resolves to `:TenantSettingsManage`; the 12 former-`:Unknown` pairs resolve per 7.2 (table-driven over `(method, path)`).
4. `test/letflow/plugs/auth_pipeline_test.exs` (extend): `auth_context` carries both facts on the OIDC branch and the API-token branch; platform realm -> `platform_tenant?` true; ordinary realm -> false; config unset -> false for both; platform tenant but no `PLATFORM_ADMIN` group row -> `platform_scope?` false even if the token claims the role;
   pipeline value equals the recomputed value in `Authorize`.
5. Cross-tenant platform matrix, one test group per router (`tenants`, `onboarding`, `platform_migrations`, `event_retention`, `admin_services`), every one of the 21 routes: (a) A `PLATFORM_ADMIN` -> 403 problem+json, body contains no tenant data, target row/counts unchanged, including when the path slug is A's own slug; (b) P `PLATFORM_ADMIN` -> the existing success/err assertions unchanged;
   (c) P `PROCESS_DESIGNER` -> 403; (d) config unset: P `PLATFORM_ADMIN` -> 403 on every route (fail closed); (e) A `PLATFORM_ADMIN` token minted in A presented with slug P -> 401.
6. `tenant_settings_test.exs`: A `PLATFORM_ADMIN` 200 (key `:TenantSettingsManage`); A `PROCESS_DESIGNER` 403; P `PLATFORM_ADMIN` 200; the response affects only A's row.
7. Promotions: for each of rows 23-34: A `PLATFORM_ADMIN` happy path on own tenant unchanged; foreign `source_tenant_id` / `target_tenant_id` -> 404 byte-identical to a nonexistent uuid (compare full bodies and headers of both responses); stored foreign ids on apply and run-assertions -> 404 and no write in any schema;
   promote with a foreign `:test_tenant_id` -> 404 identical to nonexistent; P operator performs cross-tenant plan/submit/apply/promote successfully; roles other than `PLATFORM_ADMIN` -> 403 as before; `default_permission_checker` has no hits in `lib/**/*.ex` outside `lib/letflow/design/` (test over source text; promotions.ex moduledoc rewritten).
8. `GET /promotions/platform-events`: events inserted into B's schema are never returned to A; A sees its own sentinel events only.
9. `TenantStatus`: A inactive -> A's `PLATFORM_ADMIN` halted 403 `tenant_inactive`; P `PLATFORM_ADMIN` exempt; `POST /tenants/<P slug>/deactivate` -> 409 and row unchanged; `Identity.deactivate_tenant/1` called directly with P's slug -> `{:error, :platform_tenant_protected}`, row unchanged (guard is in the context); `PATCH /tenants/<P slug>` with `status: inactive` ignores `status` and leaves the row unchanged (not in `@patch_schema`); the A2-only source scan of test 17(0) (separate file `tenant_update_changeset_removed_test.exs`) asserts `Tenant.update_changeset` (which casts `status`) is not defined and has no caller under `lib/` (deleted per section 3.1 guard (0)), so no second status writer can appear unnoticed.
10. Role-escalation: (a) A: `POST /roles` name `PLATFORM_ADMIN` by `PROCESS_DESIGNER` -> 403 (A2); same by P `PROCESS_DESIGNER` -> 403; by P `PLATFORM_ADMIN` -> unchanged success;
    (b) `Identity.sync_role_claims_from_token/3` with claimed `PLATFORM_ADMIN` in A: role present, every platform route 403; (c) API token with role `PLATFORM_ADMIN` created in A: presented as A -> platform routes 403; presented with slug P -> 401;
    (d) editing A's display name/slug-adjacent settings or creating a group named `PLATFORM_ADMIN` in A confers no platform scope; (e) `PATCH /tenants/:slug` with an `idp_realm_id` field by the operator leaves `idp_realm_id` unchanged (immutability, decision 0006 R5); (f) a token verified for realm X resolves only to X's tenant; (g) H1 variants of the `PLATFORM_ADMIN` name (section 10) all 403 for a non-platform-scope caller, for both `kind` values, with no row change.
11. `authorize_target_tenant/2` unit tests: own id, other id, nil, malformed, slug with and without platform scope, upper-case own id; asserts no `Repo` interaction (runs with no DB sandbox checkout).
12. `PromotionAccess.checker_for/1` unit tests: own source true, foreign source false, platform true.
13. Guard tests G0..G4 (section 11), including the bad-snippet demonstration.
14. A1 only: shadow log test using `ExUnit.CaptureLog`: A `PLATFORM_ADMIN` on `GET /tenants` -> 200 AND exactly one `platform_scope_shadow_deny` line with no identifiers; P `PLATFORM_ADMIN` -> 200 and no such line.
15. Existing suites updated for fixtures only: `tenants_test.exs`, `onboarding_test.exs`, `onboarding_scope_extension_test.exs`, `platform_migrations_test.exs`, `event_retention_test.exs`, `admin_services_test.exs`, `admin_services_publish_retire_test.exs`, `req442_tenants_mode_test.exs`, `req442_mode_exposure_test.exs`,
    `promotions_test.exs`, `req077_promotion_pipeline_test.exs`, `tenant_settings_test.exs`, `tenant_onboarding_test.exs`, `service_catalog_delete_pinned_instances_test.exs`, `authorization_enforcement_test.exs`.
16. Full `mix test`, `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix letflow.check_boundaries`; real output quoted in the run report.
19. NAMED TEST `uniform_403_platform_prefixes_for_non_operators` (`test/letflow/api/platform_prefix_uniform_403_test.exs`, A2 enforcing; A1 variant asserts legacy): for each non-operator caller (A `PLATFORM_ADMIN`, A `PROCESS_DESIGNER`, P `PROCESS_DESIGNER`, config unset P `PLATFORM_ADMIN`) and each of the five prefixes, requests to (a) a matched platform route with an existing resource, (b) a matched platform route with a nonexistent resource id/slug, (c) an unmatched sub-path, (d) a bare unmatched path directly under the prefix return the same status 403 and byte-identical bodies (compare full body bytes and the content-type header; the request-id header is excluded) and no row changes; row 34 is excluded and covered by tests 7 and 20. Companion cases in the same file: a platform-tenant `PLATFORM_ADMIN` gets 404 on an unmatched path under each of the five prefixes (the operator is NOT given a 403, section 7.5) and on an unmatched path under an ordinary router (`:UnmatchedRoute`); the `:UnmatchedPlatformPath` / `:UnmatchedRoute` grid (roles x `platform_tenant?`) is in `authorization_test.exs`.
20. NAMED TEST `promote_route_source_tenant_equals_own` (`test/letflow/api/promote_source_tenant_test.exs`, real Postgres, `async: false`; A1 variant asserts the legacy outcome only for every case (no assertion on a shadow call or log line); A2 enforcing variant asserts the rules below), row 34 `POST /tenants/:test_tenant_id/promote/:process_key`: (a) A `PLATFORM_ADMIN` (tenant admin) with `:test_tenant_id` = A's own id passes authorization (reaches the existing handler logic; outcome assertions as today); (b) A with B's id (B an EXISTING tenant) and A with a random unused UUID return the SAME 404: full body bytes and content-type header identical (request-id header excluded), status 404, never 403, never 200, and the source tenant's schema is never queried: a telemetry/query-prefix capture (`[:letflow, :repo, :query]` or the Repo telemetry event, filtering on B's schema prefix and on any query issued for the source lookup) records zero queries against B's schema and no source-tenant lookup for both requests, and B's data is unchanged; (c) a malformed `:test_tenant_id` (non-UUID text, a slug, an over-long string) returns the same 404 bytes with the same no-query assertion; (d) P operator (platform tenant `PLATFORM_ADMIN`) with B's id proceeds (cross-tenant source allowed, OQ-2). A1 variant: (a) and (d) assert the legacy result; (b)/(c) assert only the LEGACY result (no shadow-position call to `tenant_target.ex`, which handlers do not call in A1, and no extra log line, since A1 adds no log statement beyond Authorize's shadow line); the denial rule is covered by unit test 11 of `tenant_target.ex`; A2 variant: (a)-(d) exactly as stated. Unit-level counterpart: test 11.
17. `test/letflow/api/platform_marker_not_writable_test.exs` (ISS-0994 AC e; section 3.1; A1, purely additive, passes with `update_changeset` still present): the `status_changeset` caller scan (callers under `lib/` are exactly `Identity.set_tenant_status/2` and `TenantOnboarding` (`:active`)); (0) is a SEPARATE A2-only file, `test/letflow/identity/tenant_update_changeset_removed_test.exs`: `Tenant.update_changeset` is not defined in `lib/letflow/identity/tenant.ex` and a source scan finds no `update_changeset` reference to `Tenant` under `lib/` (it needs the A2 deletion). Realm-binding immutability after the deletion: the two REQ-019 tests in `test/letflow/identity_test.exs` (lines ~607-640) are repointed from `update_changeset/2` to `Tenant.admin_patch_changeset/2` (it casts `display_name`, so the `display_name == "New Name"` assertions still hold; `idp_realm_id` is not in its cast list), in A2 together with the deletion; test 10(e) proves it end to end over HTTP;
    (a) the cast-field lists of `create_changeset`, `admin_patch_changeset`, `status_changeset`, `settings_changeset` equal a literal expected list (no platform-like field); `req442_tenant_mode_schema_test.exs` and `identity_test.exs` stop referencing the deleted function (A2, section 13);
    (b) the `@patch_schema` field names of `PATCH /tenants/:slug` equal `display_name`, `login_disclosure_mode`; (c) as P `PLATFORM_ADMIN`, `PATCH /tenants/<A slug>` with extra body keys (`is_platform`, `platform`, `platform_tenant`, `id`) returns the normal outcome and A still has `platform_tenant? == false` afterwards (a follow-up call as A's admin on a platform route is 403);
    (d) as A `PLATFORM_ADMIN`, `PATCH /tenant/settings` with the same keys is rejected as unrecognised and A stays non-platform; (e) `POST /tenants` and `POST /onboarding` with a body `id` equal to the configured pin create a tenant with a different id and the pin is unchanged (`PlatformTenant.configured_id/0` before == after);
    (f) source scan: no file under `lib/letflow/routers/` calls `Application.put_env` or `Application.put_all_env` for the `Letflow.PlatformTenant` key, and `Letflow.PlatformTenant` defines no function that writes configuration.
18. INV-10 check (section 18, cited not authored): the scope-table completeness test (item 3), G2, G3, G4 (item 13), tests 9 (deactivated-tenant exemption) and 5 (per-route-group negative tests with another tenant's admin) and item 17 are the named checks; their header comments cite INV-10 and the note "enforced from the merge of Q-960 PR A".

## 13. Files per PR

Backend is split in two merges that share this design. Nothing is merged to `main` by this design phase.

### PR A1 (additive; no caller that works today stops working)
* `lib/letflow/platform_tenant.ex` (new); `lib/letflow/application.ex` (registration check child)
* `config/config.exs` (default `nil`), `config/runtime.exs` (env parse, boot messages)
* `lib/letflow/api/authorization.ex` (new permissions, `permission_scope/1`, `platform_permissions/0`, `AccessContext.platform_tenant?`, `evaluate_access/2` platform clause (rule 3) and the catch-all marker clause (rule 1a, `:UnmatchedPlatformPath` / `:UnmatchedRoute`) active but neutralised for enforcement by the A1 legacy forcing in the plug; rule 1, the `:Unknown` denial, is NOT in A1 and the legacy `:Unknown` branch stays until A2; key/permission clauses for the 12 routes and `/tenant/settings`)
* `lib/letflow/plugs/auth_pipeline.ex` (`attach_auth_context/4` facts), `lib/letflow/plugs/authorize.ex` (recompute, shadow evaluation + log, legacy forcing)
* `lib/letflow/api/tenant_target.ex` (new, not yet called by handlers), `lib/letflow/definitions/promotion_access.ex` (new, not yet wired)
* `lib/letflow/api/authorized_router.ex` (G0; `authz_unmatched/1` catch-all macro and the two marker keys, section 7.5; every router's `match _` is replaced by it, `:platform_prefix` for the five platform routers)
* routers: `tenants.ex`, `promotions.ex`, `definitions.ex` (plain macros -> `authz_*` with the new keys; moduledocs rewritten), `tenant_settings.ex`, `admin_services.ex`, `onboarding.ex`, `platform_migrations.ex`, `event_retention.ex` (moduledocs state the new rule)
* tests: items 1-4, 6, 11-14, 17 (except 17(0), which is A2), 18 and the A1 variants of 5, 7, 8, 19, 20 (legacy behaviour asserted; plus shadow log where applicable, except 20: legacy result only), `test/support` fixture helper
* docs: `docs/guides/backend_developer_guide.md` (route declaration and scope rule). No edit to `docs/agents/instructions/security-invariants.md` (INV-10 is carried by the workflow-rules PR, section 18)

### PR A2 (enforcement; the BLOCKER closes here)
* `lib/letflow/plugs/authorize.ex` (delete forcing and shadow log), `lib/letflow/api/authorization.ex` (rule 1: `:Unknown` denied for all, replacing the legacy branch; documentation)
* `lib/letflow/plugs/tenant_status.ex` (platform-scope-only exemption)
* routers: `tenants.ex` (helper calls; maps `{:error, :platform_tenant_protected}` to 409), `lib/letflow/identity.ex` (`set_tenant_status/2` platform-tenant guard for `:inactive`, error variant `:platform_tenant_protected`, spec of `deactivate_tenant/1`), `lib/letflow/identity/tenant.ex` (delete dead `update_changeset/2`, section 3.1), `test/letflow/req442_tenant_mode_schema_test.exs` and `test/letflow/identity_test.exs` (REQ-019 tests, lines ~607-640: repoint from the deleted function to `Tenant.admin_patch_changeset/2`; drop the reference in the req442 test), `test/letflow/identity/tenant_update_changeset_removed_test.exs` (new, test 17(0)), `lib/letflow/api/authorization.ex` (`platform_admin_name?/1`), `promotions.ex`, `definitions.ex` (helper + `PromotionAccess.checker_for/1`), `lib/letflow/routers/identity.ex` (`POST /roles` `PLATFORM_ADMIN` clause)
* `lib/letflow/definitions/promotion_plan.ex`, `lib/letflow/definitions/promotion.ex` (delete the allow-all default; docs)
* `scripts/uat_preflight.sh` (~:603: the `actor-platform-admin` probe moves from `/api/v1/admin/services` to a tenant-scope admin-only route `GET /api/v1/identity/users`; add a separate, optional check "platform_operator" that probes `/api/v1/admin/services` with a PLATFORM-tenant account when one is configured)
* tests: items 5, 7-10, 19 and 20 enforcing variants; item 15 fixture updates; G1-G4 become hard failures

### PR B (UI) -- outline only, section 17.

## 14. Acceptance mapping

| Source criterion | Design element / test |
|---|---|
| ISS-0994 AC (a): a `PLATFORM_ADMIN` of a non-platform tenant gets 403 on `/tenants`, `/onboarding`, `/platform-migrations`, `/event-retention`, including its own slug; one test per route group; two provisioned tenants | sections 5-7.1; test 5(a) (all 21 routes), G3 |
| ISS-0994 AC (b): the `TenantStatus` exemption applies only to a platform-tenant `PLATFORM_ADMIN`; an inactive tenant's own `PLATFORM_ADMIN` is halted 403 `tenant_inactive`; platform-tenant admin exempt; no existing assertion weakened | section 6 (`TenantStatus`); tests 9, 5(b), 15 |
| ISS-0994 AC (c): deactivating the platform tenant -> 409, row unchanged (guard in `Identity.set_tenant_status/2`; `PATCH /tenants/:slug` has no `status` key, so it cannot deactivate; ISS-0994's "also PATCH" wording is met by that fact plus test 9) | 7.1 rows 4, 5; test 9 |
| ISS-0994 AC (d): `PATCH /tenant/settings` stays an own-tenant permission (`:TenantSettingsManage`, tenant scope, not `:TenantsManage`) and works for a non-platform `PLATFORM_ADMIN` | section 5, 7.2 row 22; test 6, test 3 |
| ISS-0994 AC (e): the platform-tenant marker is not writable through any `/api/v1` route | section 3.1 (pin is deployment config, no table, no route; changeset and PATCH allowlists verified); tests 17(a)-(f), 10(e) (realm binding immutable) |
| ISS-0994 AC (f): new invariant in security-invariants.md | MET BY CITATION: INV-10 "platform authority bound to the platform tenant" is carried by the workflow-rules PR (letflow-3, P8), "enforced from the merge of Q-960 PR A"; section 18 lists what PR A enforces and checks; test 18 |
| ISS-0994 AC: full `mix test` (ISS-0993 too) | test 16 |
| ISS-0993 `/admin/services` `owner_tenant_id` exposure classification | 7.1 rows 16-21 and the classification paragraph: PLATFORM scope (`:PlatformServicesManage`), non-platform callers get 403 and never see other tenants' `owner_tenant_id`; tests 5 (`admin_services` group), G3; tenant-facing catalogue stays `GET /services` (7.3) |
| ISS-0993 suggested direction: platform permission distinct from own-tenant permission; negative tests incl. /admin/services | sections 5, 7.1 (rows 16-21), tests 5 |
| ISS-0993 related UI finding (`AppShell.tsx:23-60`) | section 17 |
| ISS-0994 out-of-scope item ":Unknown-gated promotion routes" | brought in by ISS-0993/this task: rows 23-34, section 9 |
| letflow-9a condition on row 34 (non-operator source must equal own tenant id; else byte-identical 404 before any source read) | sections 7.2 row 34 and 8 (row 34 paragraph); tests 20(a)-(d), 7, 11 |

## 15. Rollout order and seeding contract

Order (each step has an exit check; nothing flips enforcement before the operator account is proven):

1. Validators and SECURITY-REVIEWER pass this design; decision 0046 (REQ-445, written by its own pipeline) is merged or its D1..D10 are ratified; this design is not a competing record.
2. Merge A1. QA deploys. Behaviour for every caller is unchanged; boot logs the A1 unset warning. Exit check: full suite green; `GET /api/v1/tenants` as before.
3. Infra seeds the platform tenant account and sets `LETFLOW_PLATFORM_TENANT_ID` on QA (contract below), restarts the backend.
4. Verify (status codes and counts only): (a) operator account `GET /api/v1/tenants` -> 200 and NO `platform_scope_shadow_deny` line for that request; (b) an ordinary tenant admin account on the same call -> 200 (legacy) and exactly one `platform_scope_shadow_deny` line;
   (c) operator account `GET /api/v1/admin/services` -> 200 and `GET /api/v1/promotions` -> 200; (d) the boot log shows no "not registered" line.
4a. A2 ENTRY GATE (all must hold before A2 is merged; infra records each as evidence in the A2 PR description): (i) the pin is verified set, and equal to the platform tenant id, on EACH backend instance (per-instance boot log shows no unset warning and no "not registered" line; not just one instance); (ii) the shadow logs collected from EVERY backend instance across one full UAT run executed as the operator account contain NO `platform_scope_shadow_deny` line attributable to an operator request (operator requests are the ones made with the operator account; count operator-run denials = 0); (iii) the operator/break-glass token rules of the seeding contract (item 6) are in place. If any item fails, A2 is not merged. DATED EVIDENCE (rollout remark): the BLOCKER stays exploitable between A1 and A2, so the gap is kept as short as the infra seeding allows, and the A2 PR description MUST record, each with a UTC date/time and who observed it: (1) the pin set on QA (per-instance boot log, no unset and no "not registered" line); (2) the operator account verified (step 4(a) and 4(c): 200 on the operator read calls); (3) the shadow-log window (start, end, instances covered) showing no legitimate caller would be denied, i.e. zero `platform_scope_shadow_deny` lines attributable to the operator account, the denials seen being only ordinary-tenant admins on platform routes. Undated or missing evidence fails the gate.
5. (Recommended) Land the PR B0 UI fix (AuthProvider tenant display from `/me/memberships`) so tenant admins keep the workspace name once step 6 lands.
6. Merge A2. QA deploys. Verify the deny matrix with a tenant admin account (403 on rows 1-21; 200 on `PATCH /tenant/settings` is NOT probed read-only; use a GET-only subset) and the operator account (200 on the read rows). Run the platform UAT scenario as the operator account.
7. RELEASE-VALIDATOR re-derives; DOC-UPDATER closes ISS-0993 and ISS-0994 (and records REQ-446 status per conflict C3).
Rollback: revert A2 (restores A1 shadow behaviour). Clearing the variable is safe and fails closed once A2 is live.
Time-box: A2 should follow within one working session after step 4/5; leaving shadow mode on is a known open exposure (OQ-7); from the merge of A1 until A2 the BLOCKER stays exploitable, so the A2 PR is opened as soon as the dated evidence of 4a exists.

Seeding contract for infra (copy into the PR A1 description):

```text
PLATFORM TENANT SEEDING CONTRACT (QA)
1. Realm        : an operator-owned Keycloak realm, bound 1:1 to exactly one Letflow tenant (tenants.idp_realm_id).
                  QA default: the existing realm "bpm-default" / tenant slug "bpm-default" (no new realm needed).
                  Production: a dedicated realm and tenant (slug "platform"), never a customer realm.
                  The realm has no self-registration and no brokered identity provider.
2. Tenant       : the tenants row for that realm exists and is active. Obtain its id from the database (select id from tenants where slug = '<slug>')
                  or, during A1 only, from GET /api/v1/tenants/<slug> with any existing PLATFORM_ADMIN account.
3. Account      : username "platform-admin-user" (QA bpm-default may keep its existing seeded "admin-user", which already holds the realm role);
                  holds the realm role PLATFORM_ADMIN. No other realm role is required for platform scope.
4. Group/role   : in the platform tenant's schema the group named "PLATFORM_ADMIN" is bound to the platform role PLATFORM_ADMIN. Provisioning seeds this
                  (RoleRegistry.seed_default_platform_role_groups); the account is added to the group on first login by claim sync (identity.ex:846) or
                  by an existing PLATFORM_ADMIN via POST /api/v1/identity/groups/:id/members. For an account that logged in before the binding existed, run
                  mix letflow.backfill_platform_roles (ISS-0886).
5. Config       : environment variable LETFLOW_PLATFORM_TENANT_ID = the tenant id from item 2, hyphenated UUID, no quotes, no whitespace. Set on every backend
                  instance; restart. Not a secret; do not put it in logs or tickets beyond the deployment config.
6. Break-glass  : optional, recommended: one API token with role PLATFORM_ADMIN created IN the platform tenant (POST /api/v1/identity/tokens), stored in the
                  operator secret store; used with header X-Tenant-Slug: <platform slug>. It authenticates without Keycloak (see section 16).
                  The token carries its roles as STORED at creation, not live roles: removing the operator from the PLATFORM_ADMIN group does NOT revoke it.
                  Therefore (INV-4): it MUST be created with an `expires_at` (short, at most 30 days), rotated before expiry, and explicitly revoked
                  (DELETE /api/v1/identity/tokens/:id) when its holder leaves or on any suspected exposure. Tokens without expiry are not permitted for operator use.
7. Proof        : see rollout step 4.
```

## 16. Break-glass when the platform realm is down (documented limitation, not built)

If the platform realm's identity provider is unavailable, no OIDC login succeeds for the platform tenant, so no one has platform scope. Tenant operations are unaffected (each tenant has its own realm).
Documented recovery paths that need no new code: (1) the platform-tenant API token of contract item 6 (verified against the database, no IdP involved; stored roles, so expiry, rotation and explicit revocation per item 6 are mandatory, group removal does not revoke it); (2) release console / database access by the operator.
A supervised, audited break-glass role is deliberately not built (REQ-445 open question defaults to "no such access exists", D9). Follow-up requirement to be filed by ORCH on ratification (OQ-1).

## 17. PR B (UI) outline

Goal: hide the PLATFORM navigation group from callers who do not have platform scope. Nothing else. This is a hide-only slice; REQ-449 (`GET /api/v1/me/access`, permissions list) and REQ-450 (capability-based AppShell gating) keep their own scope and ordering and will supersede it (conflict C7). No `/me/access`, no permissions list, no capability model, no authorization change.
* PR B0 (small, before A2): `web/src/auth/AuthProvider.tsx` obtains the workspace display name from `GET /api/v1/me/memberships` (home entry, `web/src/api/memberships.ts`) instead of `GET /api/v1/tenants/:slug`, which becomes platform-only. Without it, tenant admins see "Unknown workspace" after A2.
* PR B (hide-only), one boolean `platform_tenant` = the caller's tenant is the configured platform tenant AND the caller holds `PLATFORM_ADMIN` there (i.e. the recomputed `PlatformTenant.scope_facts_for(auth_context).platform_scope?`, sections 3 and 4; never the stored flag).
  * Source of the flag, chosen as the minimal option: ONE additive top-level boolean field `platform_tenant` on the existing `GET /api/v1/me/memberships` response (`lib/letflow/routers/me.ex` `handle_list_memberships`, value from `PlatformTenant.scope_facts_for(conn.assigns.auth_context).platform_scope?`, recomputed, not the stored flag). Justification: the SPA already calls this endpoint in PR B0 for the workspace name, so no extra request, no new route, no new permission, no new router; `AuthProvider.tsx` and `web/src/auth/*` do not read any other session/me endpoint that could carry it (the session roles come from the token). Rejected alternatives: a new `/me/access` (REQ-449 scope); a field on `GET /me/modules` (unrelated payload). The existing entry shape (`tenant_id, tenant_slug, tenant_display_name, display_label`) is unchanged; the new field is added next to `memberships`, so existing clients ignore it.
  * Limit: `GET /me/memberships` is keyed `:MembershipsRead`, which `CANDIDATE` does not hold; for that caller the call is 403 and the SPA treats the flag as false (fail closed; `CANDIDATE` has no platform navigation anyway). The flag is a UI hint only; every platform route stays denied server-side (A2).
  * `web/src/components/layout/AppShell.tsx`: the nav items the scope table classifies PLATFORM (Register Tenant `/admin/onboarding/new`, Tenants `/admin/tenants`, Services `/admin/services`, Platform Migrations `/admin/platform-migrations`, Event Retention `/admin/event-retention`, plus the two items named at the end of this bullet) are shown only when `platform_tenant` is true AND the existing role check passes. All other items keep their current role-based gating unchanged. Promotion Reviews (`/promotions`) is TENANT scope in section 7.2 (own-tenant review lifecycle works for tenant admins), so it is not hidden; only cross-tenant promotion naming is operator-only. The Health and Metrics pages (`/admin/health`, `/admin/metrics`, both present in `AppShell.tsx` lines 41-42) are Platform items for the UI (REQ-450 already lists them) and are ALSO hidden for non-platform tenants, so the hidden nav list is 7 items, not 5. Their backing endpoints `GET /health` and `GET /metrics` stay GLOBAL-PUBLIC (section 7.4; OQ-13 resolved); hiding is navigation only.
  * A direct URL to a hidden platform page: reuse the existing `PermissionDenied` component (`web/src/components/ui/PermissionDenied.tsx`, already used by `QueryStateBoundary`) on the API 403; no new behaviour is built. Login redirect rules are unchanged.
  * Files: `lib/letflow/routers/me.ex`, `web/src/api/memberships.ts` (type gains `platform_tenant: boolean`), `web/src/auth/AuthProvider.tsx`, `web/src/components/layout/AppShell.tsx`, tests for each (flag true shows the 7 items; false or missing hides them; non-platform items unchanged; `me_test` asserts the field is true only for a platform-tenant `PLATFORM_ADMIN`).
* No `depends_on` of REQ-449/450 changes.

## 18. Security invariant INV-10 (cited, not authored here)

Supervisor decision: the invariant is INV-10, "platform authority bound to the platform tenant", and it is carried by the workflow-rules PR (letflow-3, its P8) with the note
"enforced from the merge of Q-960 PR A". This design therefore PROPOSES NO text for `docs/agents/instructions/security-invariants.md` and PR A edits no invariant file.
ISS-0994 criterion (f) is met by that citation. What PR A owes INV-10 is enforcement and a check, which is exactly this section:

Substance enforced (per REQ-445 D1..D4, user-ratified):
1. Platform-scope actions run only when the caller's DATABASE-RESOLVED tenant (`auth_context.tenant_id`, section 4) is the config-pinned platform tenant AND the caller's role grants the permission.
2. No platform tenant configured: every platform-scope action is denied.
3. Every permission is classified platform or tenant. An UNCLASSIFIED permission fails the build (the scope-table key-set test, test 3, plus G2(c)); at runtime an unclassified atom is also treated as platform (fail closed).
4. Tenant-scope actions never take the target tenant from path, query or body (the documented exceptions are the allowlisted routers of G4: promotions, tenants, admin_services, onboarding; each uses `authorize_target_tenant` or is platform-only).
5. No role is exempt from the deactivated-tenant gate except a `PLATFORM_ADMIN` of the platform tenant (section 6, `TenantStatus`).
6. Negative tests per platform-scope route group use an admin of ANOTHER tenant (test 5).

Check (the route-inventory / guard test, section 11, checks EXACTLY this classification rule): (i) every permission atom is classified `:platform` or `:tenant`, unclassified fails; (ii) every route resolves to a classified permission, never `:Unknown`;
(iii) platform-classified permissions are granted only through the platform-tenant check (`evaluate_access` grid in G3: non-platform-tenant `PLATFORM_ADMIN` -> deny; no other role -> deny); (iv) tenant-scope handlers do not read a target tenant from path/query/body, except the documented
allowlist (G4); (v) no role is exempt from the deactivated-tenant gate except a platform-tenant `PLATFORM_ADMIN` (test 9); (vi) a negative test per platform-scope route group with an admin of ANOTHER tenant (test 5). Items 17 (marker not writable) and 18 (header comment cites INV-10 and the supervisor's note) complete the check.

If the workflow-rules PR numbers the invariant differently, only the citation in the test header comment (test 18) changes.

## 19. Conflicts with REQ-445..447 (text not yet implemented; also ISS-0994)

* C1 (REQ-445 D2/D3 vs this design, naming): D3 names `:TenantsManage` as the platform-scope permission. This design keeps that name and does NOT adopt the user-suggested `:PlatformTenantsManage`; renaming would force edits to REQ-445 D3 and REQ-446 text. Cheap to rename later if the user prefers (one clause table).
* C2 (REQ-445 D3 scope table): D3 lists "`:TenantsManage` and whatever REQ-446 classifies as platform". REQ-446 did not consider `/admin/services`; this design classifies it PLATFORM and mints `:PlatformServicesManage`, and also mints `:TenantSettingsManage`. REQ-445's table must include both; REQ-445 AC2 (every atom of `core_permissions/0`) is satisfied only if it is written after this change.
* C3 (REQ-446 scope and count): this fix gives the 12 routes explicit keys and the checks, which is REQ-446 builds 1, 2, 4 and most of its acceptance criteria. REQ-446 states "thirteen" routes; the router walk finds 12 (10 in promotions.ex, 1 in definitions.ex, 1 in tenants.ex). REQ-446 `depends_on [REQ-445]` while this fix is urgent and must not wait for a documentation requirement. Recommend ORCH re-scopes REQ-446 to the remainder (moduledoc and `authorization_test.exs` count updates if left, plus any tenant-pairing follow-up) or marks it satisfied by A1/A2.
* C4 (REQ-446 build 2, promotion scope "TENANT on condition"): the condition was verified false: the handler does not prove ownership and no pairing data exists (section 9). This design adds the check and thereby ends cross-tenant promotion for tenant admins (operator-only), which REQ-446 did not foresee. Ruled ACCEPTED (OQ-2); own-tenant promotion and rollback stay tenant scope (7.2).
* C5 (REQ-446 open question "leave `evaluate_access/2`'s `:Unknown` branch unchanged"): this fix DENIES `:Unknown` for every role in A2 (user instruction), and thereby changes `match _` catch-all behaviour only under the five platform prefixes for non-operators (uniform 403; the operator keeps the 404; section 7.5; OQ-4 resolved).
* C6 (REQ-447 item 2, "PLATFORM_ADMIN dropped when resolving roles outside the platform tenant"): this fix deliberately keeps the tenant-scope catch-all for `PLATFORM_ADMIN` in every tenant until REQ-447, so tenant admins keep working. This is NOT a departure from D4 and escalates no user: until REQ-447 a tenant `PLATFORM_ADMIN` holds own-tenant powers only (`PATCH /tenant/settings` keeps working; no platform-scope permission; no cross-tenant promotion). The one behaviour that ends in THIS fix (A2), not at REQ-447, is the `TenantStatus` deactivated-tenant exemption for tenant `PLATFORM_ADMIN`s (section 6). REQ-447 later drops the role outside the platform tenant.
* C7 (REQ-449/450 and PR B): REQ-449/450 keep their own scope and ordering (both still depend on REQ-447): `GET /me/access`, the capability/permission model and capability-based AppShell gating are theirs and are NOT pulled forward. PR B (section 17) is only the minimal hide-only slice (one boolean, `platform_tenant`, hiding the Platform navigation group) and will be superseded by REQ-449/450 when they land. No `depends_on` is reordered.
* C8 (REQ-445 ratification): this design's choices are implementation notes for REQ-445's D1..D10; where a choice is not covered by a ratified D-item (for example `:PlatformServicesManage`, the interim promotion rule, shadow mode), it stays an open question here and is not presented as ratified.
* C9 (numbering): decision 0046 is reserved for REQ-445 (Q-962). This design writes no decision record and consumes no number. (The earlier remark that 0045 was taken on `origin/main` was a false positive, see section 23.)
* C10 (ISS-0994 fix_direction 1): ISS-0994 says the pinned default tenant "is the natural default". This design chooses an explicit environment variable with no default. ISS-0994 items 5-6 and the invariant are included; item 7 moduledocs are in the PR A1 file list.
* C11 (REQ-448 parity test): "for `PLATFORM_ADMIN`: as evaluated in the platform tenant" is compatible with `role_allows?/2` unchanged plus `permission_scope/1`; the charter's scope column must equal `permission_scope/1`.

## 20. Open questions (not silently resolved; defaults stated)

* OQ-1 Break-glass (section 16). Default: documented limitation; API-token path and console only.
* OQ-2 RESOLVED (ACCEPTED, letflow-9a, 2026-10-06, with condition): only routes that read or write a tenant other than the caller's are operator-only (via the target-tenant check); own-tenant promotion review/approve/reject/apply and definition rollback stay tenant scope under `:PromotionsRead`/`:PromotionsManage`/`:DefinitionsRollback` (sections 7.2, 9). Product limitation: a customer can no longer promote test-to-production by itself; the operator does it; a tenant-pairing-model requirement will follow from letflow-9a. Residual: promotion event payloads in a tenant's schema carry source/target tenant UUIDs of promotions into it.
* OQ-3 Platform tenant on QA: reuse `bpm-default` (default) or a dedicated tenant. Production: dedicated, mandatory.
* OQ-4 RESOLVED (ACCEPTED, restated, letflow-9a, 2026-10-06): for callers who are not platform-tenant operators, every path under `/tenants`, `/onboarding`, `/platform-migrations`, `/event-retention`, `/admin/services` returns the same 403 with a byte-identical body, matched or unmatched, resource existing or not (named test 19); a platform-tenant `PLATFORM_ADMIN` keeps 404 on an unmatched path (marker keys, section 7.5). The earlier "uniform 403 for everyone" default is withdrawn. Detail for the validator: row 34 is the one own-tenant route in the `/tenants` mount and is excluded from the uniform-403 rule (section 7.5).
* OQ-5 Unset configuration in production: warn and deny (default) versus refuse to boot. Default chosen to avoid a tenant-wide outage over an operator setting.
* OQ-6 Test isolation for the config key: `async: false` plus config set/restore (default) versus a test-only process override (adds test code to a production path; rejected unless the user prefers).
* OQ-7 Length of shadow mode (A1 to A2). Default: shortest feasible; the BLOCKER stays open until A2.
* OQ-8 `scripts/uat_preflight.sh`: probe `actor-platform-admin` on a tenant-scope admin-only route (default) versus moving that actor to a platform-tenant realm. REQ-451 later maps scenario actors to roles.
* OQ-9 Own-slug `GET /tenants/:slug` stays 403 for non-platform callers (ISS-0994 AC1); the SPA lookup moves to `/me/memberships` (PR B0).
* OQ-10 `PATCH /tenants/:slug` with `status: migrating` on the platform tenant and rollouts that set `migrating`: unchanged behaviour (writes rejected during migration); no special handling here.
* OQ-11 Last-operator protection (removing the last `PLATFORM_ADMIN` member of the platform tenant): not built; same family as REQ-445's last-admin open question.
* OQ-12 INV-10 numbering/wording is owned by the workflow-rules PR (letflow-3, P8); if it changes, only the citations in test headers change.
* OQ-13 RESOLVED (letflow-9a, 2026-10-06): `GET /health` and `GET /metrics` are GLOBAL-PUBLIC (REQ-194), not behind the pin, and already among the six public routes (7.4, counts unchanged); `:MetricsRead` is TENANT scope; the UI pages `/admin/health` and `/admin/metrics` are Platform nav items hidden for non-platform tenants in PR B (7 items, section 17).

## 21. Enforcement notes P1..P8 (implementation notes for decision 0046; cross-references REQ-445 D2 platform tenant, D3 permission scope, D4 PLATFORM_ADMIN honoured only in the platform tenant)

These are implementation notes, not a decision record. Decision 0046 (REQ-445, Q-962) is the record; D-labels below are REQ-445's.

* P1 Two scopes, one per permission (per REQ-445 D3). Every permission is platform or tenant scope (section 5). Platform: `:TenantsManage`, `:PlatformServicesManage`.
  Everything else, including every module permission, is tenant scope. An unclassified permission is treated as platform scope (fail closed). The scope table extends D3 by two atoms (C2).
* P2 How the platform tenant is pinned (per REQ-445 D2). One environment variable, `LETFLOW_PLATFORM_TENANT_ID`, read at boot (section 3). Unset or blank: nobody holds platform scope (fail closed;
  boot continues with a warning). Malformed: boot stops with a message that does not echo the value. No `/api/v1` route can read-modify it (section 3.1). Independent of the default tenant (`bpm-default`).
  No new operator role: the operator is the existing `PLATFORM_ADMIN` (per REQ-445 D4).
* P3 Platform scope is a derived fact (per REQ-445 D4). `platform_scope?` = (authenticated tenant id equals the pin) AND (`PLATFORM_ADMIN` held in that tenant), computed once in the authentication
  pipeline from DB-resolved values and recomputed, not trusted, by the authorization plug (sections 4, 6). A platform-scope permission is denied to a `PLATFORM_ADMIN` of any other tenant by an explicit clause that runs before the role matrix.
* P4 Own-tenant settings get their own permission. `PATCH /tenant/settings` moves to `:TenantSettingsManage` (tenant scope). Tenant behaviour is otherwise unchanged: the `PLATFORM_ADMIN` catch-all keeps covering
  tenant-scope permissions in every tenant until REQ-447. This is not a departure from D4 and escalates no user (conflict C6): until REQ-447 a tenant `PLATFORM_ADMIN` holds own-tenant powers only, no platform-scope permission and no cross-tenant promotion; the `TenantStatus` deactivated-tenant exemption for tenant `PLATFORM_ADMIN`s ends in this fix (A2), not at REQ-447.
* P5 `:Unknown` is denied for every role. Every route declares an explicit key; the twelve plain-macro routes receive `:PromotionsRead`, `:PromotionsManage`, `:DefinitionsRollback` (tenant scope). A guard test fails on a route without a key (section 11). Same work as REQ-446, section 22.
* P6 `authorize_target_tenant` contract (section 8). A handler that receives a tenant identifier proves it is the caller's own tenant or that the caller has platform scope, before any lookup. Deny path: a mismatch is answered
  exactly like a nonexistent resource (404, INV-5), with no extra DB round trip.
* P7 Promotions (interim). The promotion permission check is no longer unconditionally true; a non-platform caller may name only its own tenant as source and target. Cross-tenant promotion is therefore an operator action until a
  tenant-pairing relation is decided (OQ-2, accepted). Plainly: a customer can no longer promote from its test tenant to its production tenant by itself; the operator does it. Only a foreign source/target is operator-only; own-tenant promotion review and definition rollback stay tenant scope.
* P8 Rollout (section 15). A1 (additive, shadow logging, no caller regresses), infra seeds the platform tenant account on QA (seeding contract), verification, then A2 (deny by default). Break-glass when the platform realm is down is a documented limitation (section 16).

Amendments to earlier records, by reference only (this design never edits the amended files; REQ-445's 0046 owns the formal amendment text):
* 0013 addendum (ISS-0646) wording that `PLATFORM_ADMIN` holds "full platform administration -- every admin route, every tenant": the catch-all continues to cover every tenant-scope permission in the caller's own tenant and covers a
  platform-scope permission only for a `PLATFORM_ADMIN` of the platform tenant (per REQ-445 D3, D4). The role set is untouched here.
* 0006 R5 (realm to tenant is a strict partial bijection; a binding cannot be reassigned): not changed in content, but now load-bearing for authorization (section 10). Any future change letting a realm re-bind or a tenant hold two realms must re-open the record.
* 0044 (hybrid identity model): "platform operator" becomes precise: a `PLATFORM_ADMIN` authenticated in the platform tenant. If a shared tier is later ratified, which tenant is the platform tenant and who owns its realm must be re-stated.
* Not amended: 0038 (membership lookup); `GET /me/memberships` is the SPA's replacement for the tenant lookup (section 17) and keeps 0038's conditions.

Unchanged: the six built-in roles and names; schema-per-tenant isolation and INV-1; `PLATFORM_ADMIN`'s allow-everything behaviour within tenant scope until REQ-447; the public unauthenticated surfaces (section 7.4); the module permission mechanism (decision 0039:
module permissions stay tenant scope, a module cannot create a role or a platform-scope permission); the `bpm-default` pinning in `Tenant.create_changeset/3`.

Consequences: ordinary tenant administrators lose reach to the tenant registry, onboarding, platform migrations, event retention, the global service catalogue and cross-tenant promotion, and keep every tenant-scope capability including their own
tenant's settings and promotion review lifecycle. QA needs a platform tenant account and one environment variable before enforcement; production needs a dedicated platform tenant and realm. The SPA tenant-name lookup needs the PR B0 follow-up.
Test fixtures that hand-build an `auth_context` for platform routes must name the platform tenant.

Open questions OQ-1..OQ-13 (listed in section 20; OQ-2, OQ-4, OQ-13 resolved by the 2026-10-06 rulings): section 20.

## 22. Overlap with REQ-446 / Q-963 and PR B limits

* The `:Unknown` classification is the SAME work as REQ-446 / Q-963. PR A names those permissions (`:PromotionsRead`, `:PromotionsManage`, `:DefinitionsRollback`, rows 23-34 of section 7.2) and denies `:Unknown`; Q-963 therefore shrinks to
  verification of that result (the 12 pairs resolve per 7.2, no route resolves to `:Unknown`, REQ-446 AC against the guard tests) plus any remainder (moduledoc and count wording, tenant-pairing follow-up). ORCH re-scopes REQ-446 accordingly (conflict C3).
* PR B (UI) is limited to hiding platform items for non-platform tenants (platform navigation entries driven by one `platform_tenant` boolean added to `GET /me/memberships`, plus the workspace-name lookup, section 17). Permission-based gating of the rest of the UI and `GET /me/access` stay with REQ-449 and REQ-450; PR B does not
  build a second mechanism and does not change authorization.

## 23. Gate record

Verdicts are recorded as the validators wrote them; this section does not alter any sign-off line text.

CODE-DESIGN-VALIDATOR: PASS (round 3, 2026-10-06): section 18 Check paragraph now binds substance items 5 and 6 as (v) test 9 and (vi) test 5, and test-18 citation set names tests 9 and 5; sections 11, 18, 23 consistent; tests 5 and 9 match their descriptions.
CODE-DESIGN-VALIDATOR: FAIL (round 4, 2026-10-06, consistency pass after concurrent rework): (1) section 3.1 and test 17(0) claim `Tenant.update_changeset/2` is referenced only by `req442_tenant_mode_schema_test.exs`; `test/letflow/identity_test.exs` 607-640 (REQ-019 idp_realm_id immutability) also calls it, and section 10 fact 1 cites it; (2) section 13 puts test item 17 in A1 but the deletion is in A2; (3) section 3 line 72 says Authorize/TenantStatus call `scope_facts_for/1` as the ONLY entry point while sections 4 and 6 use `platform_tenant?/1` and `scope_facts/2`; (4) section 7.1 table split by a blank line after row 5; (5) line 630 says OQ-1..OQ-12 but OQ-13 exists; (6) section 13 A2 bullet mixes router and domain `identity.ex`.
CODE-DESIGN-VALIDATOR: PASS (round 5, 2026-10-06): all six round-4 defects verified fixed; Tenant.update_changeset callers re-grepped (only identity_test.exs 607-640 and req442 test line 164, both covered; admin_patch_changeset casts display_name and not idp_realm_id; no remaining update-type cast list has idp_realm_id); sections 3, 4, 6, 8, 9, 13 entry points consistent; no broken tables; OQ range and routers/identity.ex explicit.
SECURITY-REVIEWER: FAIL (round 1, 2026-10-06): derivation, fail-closed, deny grid, 404 uniformity, TenantStatus and rollout are sound; four required design fixes before code: (1) 409 guard placed in the domain function that writes status, and row 4/test 9 PATCH-status contradiction with section 3.1 resolved; (2) TenantTarget/PromotionAccess recompute platform scope from tenant id plus roles, never read an assigned flag, and never KeyError; (3) H1 name check uses the same normalization as role parsing; (4) A2 entry gate and per-instance config verification plus break-glass token expiry/rotation added to section 15/16. Re-review after fix.
SECURITY-REVIEWER: PASS (round 2, 2026-10-06): all four round-1 fixes verified in the design and against code: (1) 409 guard in Identity.set_tenant_status/2 by resolved row id, PATCH ignores status, Tenant.update_changeset has no caller under lib/ (test callers identity_test.exs and req442 test are covered by the repoint); (2) target-tenant helper, promotions checker, H1 clause and /me/memberships flag recompute via scope_facts_for/1 with Map.get defaults, stored flags cache only; (3) platform_admin_name?/1 built on roles_from_strings/1 (exact match, verified) plus stricter fold, covers upsert_role/4 exact match, test 10(g) covers variants; (4) A2 entry gate, per-instance pin check, operator token expiry/rotation/revocation, shadow log key plus boolean only. PR B boolean and hide-only gating leak nothing and add no capability model; PR A does not edit security-invariants.md. Non-blocking: section 8 rule 2 should read tenant_id with Map.get, not dot access.
REVIEWER: FAIL (2026-10-06, one blocking defect: section 17 PR B pulls forward a `GET /me/access` slice and permission-gated AppShell navigation, which are REQ-449/REQ-450 scope and contradict section 22 ("PR B does not build `/me/access`") and the PR B limit of hiding platform navigation items only; fix section 17 and conflict C7 to a minimal platform-flag mechanism without `/me/access`, then re-review. All other sections accepted; non-blocking notes returned to CODE-DESIGNER.)
REVIEWER: PASS (round 2, 2026-10-06): PR B is hide-only (one `platform_tenant` boolean on the existing `GET /me/memberships`, recomputed via `scope_facts_for/1`, no `/me/access`, no permissions list, existing `PermissionDenied` reused); C7 and section 22 consistent; REQ-449/450 scope untouched; H1 justified against code (PROCESS_DESIGNER holds `:RolesManage`, `upsert_role/4` has no caller-role check); C6/P4 worded as an unratified departure from D4 until REQ-447; G4 droppable; counts 21/13/103/6, A1/A2 file lists, ISS-0994 AC (a)-(f), OQ-1..OQ-13 intact; no competition with 0046, INV-10 cited only.
User ratification of P1, P3..P8: PENDING (P2 ratified).

Note on defect 1 (stale 0045 fact): it was a false positive. Re-checked after `git fetch`: `origin/main` has no 0045 decision record, PR #2226 (mail library choice) is still open, and 0046 is reserved for REQ-445. Defects 2 (checker argument order, fixed in section 9) and 3 (grep postcondition scoped to `lib/**/*.ex` excluding `lib/letflow/design/`, fixed in section 9) were real and are addressed.
This rework (fold of the appendix into this design, section 3.1, INV-10 citation, AC checklist, section 22) requires CODE-DESIGN-VALIDATOR re-validation: round 2 verdict FAIL (2026-10-06, one mechanical gap: section 18 "Check" paragraph does not bind substance items 5 and 6 to named checks, test 9 and test 5; defect 1 withdrawn as false positive, defects 2 and 3 confirmed fixed; 3.1, INV-10 citation, AC table, section 21 D-labels, section 22 all verified). Re-validate after the fix.
Rulings applied 2026-10-06 (letflow-9a, REQ-445 owner): the design was amended per the rulings on OQ-2 (own-tenant promotion/rollback stay tenant scope; product limitation stated), OQ-4 (uniform 403 for non-operators under the five platform prefixes; operator keeps 404 via marker keys; named test 19), C6/P4 (not a departure from D4; TenantStatus exemption ends in A2), OQ-13 (health/metrics global-public; 7 hidden nav items) and the section 15 dated A2 entry evidence; needs a quick CODE-DESIGN-VALIDATOR consistency re-check. (The REVIEWER round-2 line above still quotes the superseded "unratified departure" wording for C6/P4; verdict lines were not edited.)
CODE-DESIGN-VALIDATOR: FAIL (round 6, 2026-10-06, consistency re-check after rulings): rulings on OQ-2, OQ-4, C6/P4, OQ-13, counts (137+6; 21/13/103/6), section 15 dated evidence, nav items (all 7 exist in AppShell.tsx) verified consistent; two defects: (1) rule 1a of evaluate_access/2 (section 6) and the section 13 PR A1 `authorization.ex` bullet do not state that rule 1a (catch-all markers) ships in A1 (section 13 A1 only lists rule 3 and says rule 1 is not in A1; the `authz_unmatched` macro is listed in A1 but its evaluation rule is not); (2) test 20 A1 variant says `authorize_target_tenant` is "called in shadow position" with a `platform_scope_shadow_deny`-style log line for the caller, contradicting section 13 A1 (`tenant_target.ex` "not yet called by handlers") and section 6 (shadow log is only emitted by `Authorize` per policy key; no other log statement is added in A1).
CODE-DESIGN-VALIDATOR: PASS (round 7, 2026-10-06): both round-6 defects verified fixed (rule 1a stated as an A1 deliverable in section 6 and the section 13 A1 authorization.ex bullet, rule 1 stays A2; test 20 A1 variant asserts legacy result only for (a)-(d), no shadow-position call and no extra log line, consistent across sections 12, 13 and the acceptance mapping); design lists no unmatched_platform_subpath_policy/0 or health_metrics_scope/0 as deliverables (not required in A1); no new inconsistencies found.
