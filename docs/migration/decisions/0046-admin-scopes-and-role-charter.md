# 0046 -- Admin scopes and the role charter: platform scope vs tenant scope, eight built-in roles, PLATFORM_ADMIN only in the platform tenant

Status: RATIFIED by the user (repo owner) on 2026-10-05, after the role-system audit
AUDIT-ROLES-20261005 (ISS-0994). Decisions D1..D10 below are settled; this record writes them
down and does not re-decide them.

Date: 2026-10-05. Drafted by `CODE-DESIGNER` (REQ-445, queue task Q-962, GH#2233). Owner: `ORCH`.

Supersedes / amends, by reference only: it supersedes the role COUNT of
`0013-authorization-role-set.md` and its CANDIDATE addendum (the set of six becomes eight)
and nothing else in 0013. Where this record narrows or replaces a passage of another record,
the "Consistency" section names the passage and the decision. This record never edits 0013 or any
other existing record.

Reader's guide / citation. Decisions in this record are cited as "0046 D<n>" (for example
"0046 D4"). The role charter in plain language is `docs/roles.md`; its matrix is the machine-
readable form of D3-D6 and is the TARGET state after REQ-446, REQ-447 and REQ-448. Implementing
work: the platform-tenant mechanics are ISS-0993 (queue Q-960; ISS-0994 is its duplicate record,
and ISS-0993 cross-references this record by D-number and keeps only implementation notes);
named permissions are REQ-446; TENANT_ADMIN and the migration are REQ-447; TENANT_AUDITOR and the
parity test are REQ-448.

## Context

Verified in the audit. There are six built-in roles (`Letflow.Api.Authorization.roles/0`).
`PLATFORM_ADMIN` is seeded in every tenant and is allowed everything
(`lib/letflow/api/authorization.ex`, `core_role_allows?(:PLATFORM_ADMIN, _permission)`), so a
customer's own administrator holds platform-operator powers (ISS-0994, proven). No tenant-admin
role exists, yet docs and UAT scenarios speak of one. Decision 0013 settles which role NAMES exist,
not what each role is responsible for. Decision 0044 already uses the words "platform operator"
and "tenant admin" consistently with this model.

Security rationale. A role that can create and deactivate tenants, run platform migrations and
retire event partitions must not be obtainable by a customer. The rule is INV-10 (landing via
letflow-3's rules PR; "platform authority bound to the platform tenant"): platform authority is
bound to the platform tenant, and a platform-scope permission is never honoured for a caller of
any other tenant. This record does not edit `security-invariants.md`.

## Decisions

### D1. Two scopes

PLATFORM scope = the organisation operating Letflow; it acts on the tenant registry and on things
shared by all tenants. TENANT scope = one customer organisation; it acts only inside its own
tenant.

### D2. The platform tenant

The PLATFORM TENANT is the operator's own tenant: exactly one. It is CONFIG-PINNED: identified by
server-side configuration, never by any column or API a tenant can write. It FAILS CLOSED: if the
configuration is missing or invalid, no tenant is the platform tenant, so every platform-scope
permission is denied for every caller. The operator role is the EXISTING `PLATFORM_ADMIN` role,
honoured ONLY in the platform tenant; there is NO `PLATFORM_OPERATOR` role. A platform-scope
permission is honoured only for a caller of the platform tenant (INV-10, landing via letflow-3's
rules PR). The implementing fix for these mechanics is ISS-0993 (Q-960); TENANT_ADMIN
(REQ-447) is not part of that fix.

### D3. Every core permission has exactly one scope

The scope table below lists every atom of `Authorization.core_permissions/0` plus the permissions
REQ-446 names (marked planned). Platform scope: `:TenantsManage` and whatever REQ-446 classifies as
platform. Everything else, and every module (`Letflow.Modules.Catalog`) permission, is tenant scope.
Rule, not a list: every Catalog permission is tenant scope.

### D4. PLATFORM_ADMIN

`PLATFORM_ADMIN` keeps its name and its allow-everything rule but exists only in the platform
tenant: it is not seeded, not issuable and not honoured in any other tenant. It has no power inside
a customer tenant and no access to a customer's business data.

### D5. TENANT_ADMIN (new)

Every tenant-scope permission, core and module, in its own tenant; never a platform-scope
permission; no exemption from the deactivated-tenant gate. It is the tenant's owner role: users,
groups, role bindings, API tokens, settings and branding, module and solution install, audit log.

### D6. TENANT_AUDITOR (new)

Read-only inside its own tenant. The exact permission list is REQ-448's and is copied into the
table and into `docs/roles.md`.

### D7. Unchanged roles

`PROCESS_DESIGNER`, `PROCESS_OPERATOR`, `TASK_WORKER`, `CANDIDATE` and `AGENT_RUNNER` are unchanged.

### D8. Migration of existing admins

Existing non-platform-tenant `PLATFORM_ADMIN` members and API tokens are migrated to `TENANT_ADMIN`
(REQ-447).

### D9. Deferred, NOT built

Deferred until a customer asks: a read-only platform support role and a delegated user-manager
role. Break-glass (supervised platform access into a customer tenant) is deferred with them; no
such access exists.

### D10. The role set stays closed

The role set stays closed (0013, 0039 D4): a module cannot create a role.

## Permission scope table (D3)

Caption. The code-derived rows were produced by RUNNING the code in the worktree
(`mix run --no-start -e 'IO.inspect(Letflow.Api.Authorization.core_permissions(), limit: :infinity)'`),
which returned 35 atoms; this was not read from documentation. Every atom has exactly one scope.
The CODE-DESIGN-VALIDATOR re-derives the list the same way.

| Permission | Scope | Reason |
|---|---|---|
| `:DefinitionsWrite` | tenant | create/change process definitions of the caller's tenant |
| `:DefinitionsRead` | tenant | read the caller's tenant definitions |
| `:InstancesStart` | tenant | start instances in the caller's tenant |
| `:InstancesCancel` | tenant | cancel instances in the caller's tenant |
| `:InstancesRead` | tenant | read the caller's tenant instances |
| `:TasksRead` | tenant | read the caller's tenant tasks |
| `:TasksComplete` | tenant | complete a task of the caller's tenant |
| `:TasksAssign` | tenant | assign tasks inside the caller's tenant |
| `:UsersGroupsRolesManage` | tenant | users and groups of one tenant |
| `:TokensManage` | tenant | API tokens of one tenant |
| `:AuditRead` | tenant | the tenant's own audit chain |
| `:DlqOperate` | tenant | the tenant's own dead-letter queue |
| `:MetricsRead` | tenant | the tenant's own metrics |
| `:WebhooksManage` | tenant | the tenant's own webhooks |
| `:TenantsManage` | platform | tenant registry, onboarding, platform migrations, event retention, cross-tenant operations |
| `:RolesManage` | tenant | custom role bindings of one tenant |
| `:AttachmentsManage` | tenant | attachments of the caller's tenant |
| `:AttachmentsRead` | tenant | attachments of the caller's tenant |
| `:InstancesAdvanceTimer` | tenant | timer control inside the caller's tenant |
| `:EntitiesDefinitionsRead` | tenant | the tenant's entity definitions |
| `:EntitiesDefinitionsWrite` | tenant | the tenant's entity definitions |
| `:EntitiesRecordsWrite` | tenant | the tenant's entity records |
| `:EntitiesQuery` | tenant | query the tenant's entity records |
| `:EntitiesAggregate` | tenant | aggregate the tenant's entity records |
| `:EntitiesRecordsExport` | tenant | redacted export of the tenant's records |
| `:EntitiesRecordsExportUnredacted` | tenant | unredacted export of the tenant's records |
| `:EntitiesRecordsImport` | tenant | import into the tenant's records |
| `:EntitiesAttachmentsManage` | tenant | entity attachments of the tenant |
| `:EntitiesAttachmentsRead` | tenant | entity attachments of the tenant |
| `:PublicReadHandlesIssue` | tenant | issue public read handles for the tenant's data |
| `:HelpRead` | tenant | read help content (no tenant data crosses) |
| `:MembershipsRead` | tenant | the caller's own memberships |
| `:ModulesManage` | tenant | install modules and solutions in the caller's own tenant (see Conflicts flagged, C1) |
| `:MyModulesRead` | tenant | list the caller's own tenant's installed modules |
| `:EntitiesRestrictionsManage` | tenant | field-level restrictions of the tenant |

Planned rows. NOT derived from code: they do not exist until REQ-446 / ISS-0993 land. Scope is
fixed here; names marked "proposed" may be adjusted by REQ-446 but must keep the read/write split.

| Permission (planned) | Scope | Reason |
|---|---|---|
| `:PromotionsRead` (proposed, REQ-446) | tenant | the GET promotion routes; subject to REQ-446 proving the caller's tenant owns the source test tenant |
| `:PromotionsManage` (proposed, REQ-446) | tenant | create, plan, approve, reject, apply, run-assertions and cross-tenant promote of the caller's own test/production pairing |
| `:DefinitionsRollback` (proposed, REQ-446) | tenant | roll back a definition of the caller's tenant |
| to be named by REQ-446 | platform if `GET /promotions/platform-events` returns other tenants' rows, otherwise it joins `:PromotionsRead` | REQ-446 investigates |
| `:TenantSettingsManage` (name proposed, REQ-446 / ISS-0993 split) | tenant | `PATCH /tenant/settings` is split off `:TenantsManage` so a tenant can edit its own settings |

## Open risks and questions

All three questions are NOT ratified; each is recorded with its stated default.

1. Last-admin protection. Removing the last `TENANT_ADMIN` member, or deactivating that user, locks
   a tenant out. OPEN RISK. Default: nothing is built by this series; the risk is recorded here.
2. Break-glass. Whether a platform operator ever needs supervised access into a customer tenant.
   DEFERRED with D9. Default: no such access exists.
3. Realm role names in existing tenant realms. A tenant realm that still issues the claim
   `PLATFORM_ADMIN` to its admins will resolve to no role after REQ-447. Default: no alias; the
   tenant realm must issue `TENANT_ADMIN`. REQ-447 handles the data.

## Consistency with existing decision records

Passages quoted from the files as they stand in this worktree.

### 0013 (role set)

> "**Upward. The five-role matrix in `Letflow.Api.Authorization` is the contract. Every realm Letflow authenticates against must define all five roles, including `PROCESS_OPERATOR`.**"

SUPERSEDED as to the count by D5 and D6 via the addendum below; the principle (the matrix in
`Authorization` is the contract, realms must define every role) stays and now covers eight.

> "Read this addendum, not the body above it, for the current role count"

The addendum's "sixth role" count is SUPERSEDED by D5 and D6 (eight roles). This record is now
the place to read for the current count.

> "`POST /users` — `UsersGroupsRolesManage`, `PLATFORM_ADMIN`-only via the catch-all clause — and `POST /tokens` — `TokensManage`, `PLATFORM_ADMIN`-only"

Historical statement of fact at 2026-09-14. SUPERSEDED for the grant by D5 (TENANT_ADMIN holds
both in its own tenant) and D4.

> "The seeded operator account holds `PROCESS_OPERATOR`, **not** `PLATFORM_ADMIN`."

CONSISTENT (D7 leaves `PROCESS_OPERATOR` unchanged).

### 0029 (SolutionPack scope; role seeding out of the pack)

> "the SAME `:PROCESS_DESIGNER` actor who can install a pack already holds `:RolesManage` directly"

CONSISTENT (D7: `PROCESS_DESIGNER` unchanged). TENANT_ADMIN seeding (REQ-447) is done by tenant
provisioning and backfill, not by the pack, so 0029's title rule "role seeding both stay OUT of the
pack" is unaffected.

### 0038 (tenant membership lookup)

> "The `tenant_memberships` row that makes two per-tenant accounts cross-referenceable is created only by explicit `PLATFORM_ADMIN` action"

CONSISTENT with D1/D4: linking tenants is platform-scope work performed by the operator. At the
time of writing no HTTP write route for memberships exists (`/me/memberships` is read-only under
`:MembershipsRead`); any future write route must be platform scope (`:TenantsManage` or a new
platform permission).

### 0039 (platform / module / solution layering)

> "A new core permission `:ModulesManage`, granted to `PLATFORM_ADMIN` only (same pattern as `:TenantsManage`), gates module install, solution install (D6) and module-settings writes (D7)."

SUPERSEDED by D3 (`:ModulesManage` is tenant scope; "same pattern as `:TenantsManage`" no longer
holds) and D5 (TENANT_ADMIN holds module and solution install). See C1.

> "`PLATFORM_ADMIN`'s existing catch-all is unchanged."

AMENDED by D4: the clause and name stay, but it is honoured only in the platform tenant.

> "A module cannot create a role and cannot grant a core permission."

CONSISTENT with D10.

> "the platform role `CANDIDATE` is exam-specific ... recorded as an open item in the stage file"

CONSISTENT (D7: `CANDIDATE` unchanged; the open item is untouched).

### 0044 (hybrid identity model)

> "**Tenant-admin autonomy.** Full inside the realm if the platform operator hands a realm admin to the tenant, none by default; Letflow itself exposes no realm administration."

CONSISTENT: platform operator = platform scope (D1/D2); tenant admin = TENANT_ADMIN (D5), which does
not administer realms.

> "Post-login: the memberships switcher lists both only if a `PLATFORM_ADMIN` linked them (0038)."

CONSISTENT (see 0038 above).

> "Default: the platform operator ... with `PLATFORM_ADMIN` humans and a break-glass admin; tenant admins have no Keycloak admin rights."

CONSISTENT with D2/D5; the Keycloak break-glass admin is an infrastructure account, not a Letflow
role, and is separate from the deferred item in D9.

### Related records checked

- 0002 (OIDC integration): its only role passage is the custom role registry being uncoupled from
  `src/oidc/`; CONSISTENT (unchanged).
- 0006 (identity tables, schema per tenant): "cross-tenant admin/reporting queries against a
  superuser connection" is a quotation of 0003 about a database connection, not a role; CONSISTENT.
- 0035 (frontend login delegated to Keycloak): "the user's role set is decoded" is SH-01's text;
  CONSISTENT (the SPA still reads roles from the token; eight names instead of six).
- 0042 (email-first login): memberships are "admin-linked switch targets created only by
  `PLATFORM_ADMIN` action"; CONSISTENT (platform scope).
- 0043 (email-first login BA decisions): `tenants.login_disclosure_mode` is "Writable only by
  `PLATFORM_ADMIN`; never present in any tenant-admin-readable or pre-auth response"; CONSISTENT and
  reinforced: it is written through `PATCH /tenants/:slug` under platform-scope `:TenantsManage`,
  and the `:TenantsManage` split of `PATCH /tenant/settings` must keep that attribute out of the
  tenant-writable route.

### Conflicts flagged for REVIEWER

- C1. 0039 D4 states `:ModulesManage` is "PLATFORM_ADMIN only (same pattern as `:TenantsManage`)".
  The ratified model (D3 "everything else is tenant scope", D5 "module and solution install" for
  TENANT_ADMIN) makes `:ModulesManage` tenant scope, granted to TENANT_ADMIN. This is a deliberate
  supersession of that sentence by 0046 D3/D5, not an accident; REVIEWER to confirm, and to decide
  whether 0039 needs a pointer line (a new commit, since this record never edits it).
- C2. 0013's addendum describes `POST /users` and `POST /tokens` as `PLATFORM_ADMIN`-only. After
  REQ-447 TENANT_ADMIN holds them in its own tenant. Historical text only; flagged so a reader of
  0013 is not misled (read 0046 first for the current grants).
- C3. 0039's "`PLATFORM_ADMIN` catch-all ... still covers module permissions" (review note R2)
  becomes true only in the platform tenant (D4); inside a customer tenant module permissions are
  covered by `TENANT_ADMIN` (D5) and by module `role_grants` (D10).

## REVIEWER sign-off

pending

## SECURITY-REVIEWER sign-off

pending
