# REQ-447 PR 1 test spec, PART A: TENANT_ADMIN role, grant rule, seeding, realm file, status gate, task scope

Design: `lib/letflow/design/req447-tenant-admin-role.md` (sections 2.3, 3.1, 3.2, 3.3, 3.7, 3.9, 3.10, 3.11, 11) and
`lib/letflow/design/req447-infra-realm-mapping.md`. Q-964 / GH #2235.

Scope of this spec: PART A only (AC1, AC2, AC3, AC6, AC7 and the "seven roles" updates of BUILDS item 7). PART B (migration module,
`mix letflow.migrate_tenant_admins`, AC5) and PART C (H2 built-in name guard on `POST /roles`, the 3.6b platform-escalation guards,
`POST /tokens` router check) are NOT covered here and come later. AC4 (rejecting `PLATFORM_ADMIN` outside the platform tenant) is PR 2.

New files:

* `test/letflow/api/authorization_tenant_admin_test.exs` (14 tests, pure, `async: true`)
* `test/letflow/routers/tenant_admin_routes_test.exs` (15 tests, real Postgres, `async: false`)
* `test/letflow/identity/tenant_admin_seeding_test.exs` (14 tests, real Postgres, `async: false`)

Edited (expectations that follow from PR 1, none weakened): `test/letflow/api/authorization_test.exs`,
`platform_admin_role_binding_test.exs`, `platform_scope_authorization_test.exs`, `platform_scope_not_conferred_test.exs`,
`identity/role_backfill_test.exs`, `identity_test.exs`, `role_registry_test.exs`, `tenant_onboarding_test.exs`,
`plugs/iss0778_platform_role_seeding_e2e_test.exs` (+ `test/support/iss0778_platform_admin_token_verifier_double.ex`),
`plugs/tenant_status_test.exs`, `routers/tasks_test.exs`, `routers/req446_cross_tenant_denial_test.exs`,
`routers/promotion_context_entries_scope_test.exs`, `routers/tenant_modules_test.exs`, `tenant_modules_settings_test.exs`,
`tenant_solutions_test.exs`. NOT edited: `authorization_role_realm_test.exs` (passes unmodified, AC7).

## Criterion to test mapping

| Criterion | Test(s) | Why it exists |
|---|---|---|
| AC1 `roles/0` seven atoms | `AuthorizationTenantAdminTest` "roles/0 returns seven atoms ending in TENANT_ADMIN, the six pre-existing roles first and unchanged"; `authorization_test.exs` "roles/0 returns exactly ... plus REQ-447's TENANT_ADMIN"; `platform_admin_role_binding_test.exs` seven literals | Order is part of the contract (seeding order, docs/roles.md order) |
| AC1 `role_allows?(:TENANT_ADMIN, p)` iff `permission_scope(p) == :tenant`, for every p in `permissions/0` | "role_allows?(:TENANT_ADMIN, p) is true exactly when permission_scope(p) is :tenant, for every p in permissions/0"; "the rule is not vacuous: exactly the two platform atoms are refused" (literal `[:TenantsManage, :PlatformServicesManage]`, so a drift of the scope table fails too); "TENANT_ADMIN holds the tenant-administration permissions the REQ names" | The first test derives from `permission_scope/1`; the literal tests pin the answer so the rule cannot be wrong in the same way as the table |
| AC1 Catalog permissions | "Catalog (module) permissions are granted to TENANT_ADMIN ... independent of any manifest role_grants" (every `Catalog.permissions/0` atom, `:FixtureRead` named, fixture manifest does not list TENANT_ADMIN); `authorization_test.exs` REQ-401 AC2 `:FixtureRead` row; REQ-318 AC6 three export/import atoms | A rule that only covered core atoms would silently drop every module permission |
| AC1 `:Unknown` and Unmatched markers denied | "evaluate_access/2 for TENANT_ADMIN": `:Unknown`, `:UnmatchedRoute`, `:UnmatchedPlatformPath` each with `platform_tenant?` true and false; "never allowed a platform-scope permission" (`has_permission_in_scope?` and `evaluate_access` on the platform keys); "tenant-scope key is allowed with unfiltered task scope" | Fail-closed behaviour of the new role; positive control |
| Parsing | "roles_from_strings/1 parses TENANT_ADMIN exactly; tenant_admin, Tenant_Admin and padded forms parse to nothing"; `builtin_role_name?/1` true and `platform_admin_name?/1` false for the name | Exact, case-sensitive match like every other role string |
| Legacy compatibility (C6 ON) | "a PLATFORM_ADMIN of a non-platform tenant still holds tenant-scope powers and no platform-scope permission"; `platform_scope_not_conferred_test.exs` 10(b) (now binds the legacy `PLATFORM_ADMIN` binding explicitly because seeding no longer does) | PR 1 stops minting legacy roles but still honours existing ones |
| Grids (REQ-309/315/317/318/401) | TENANT_ADMIN row added to every `@pre_*_allowed` map and loop list (all permissions minus `:TenantsManage`), pair counts 7 x N, new-permission grids 7 roles; `:ModulesManage` granted to PLATFORM_ADMIN and TENANT_ADMIN only; `platform_scope_authorization_test.exs` new-permission holders (`:PlatformServicesManage` literal platform scope) | Not weakened: the TENANT_ADMIN column is asserted, not skipped |
| AC2 2xx: users, groups, roles, tokens, audit, `PATCH /tenant/settings`, `POST /tenant/modules`, `POST /tenant/solutions`, promotions list and review reads, definition rollback | `TenantAdminRoutesTest` "AC2: a TENANT_ADMIN of an ordinary tenant is allowed (2xx), router by router" (one test per route family, status and a body fact asserted); plus `tenant_modules_test.exs`, `tenant_solutions_test.exs`, `tenant_modules_settings_test.exs` "REQ-447 TENANT_ADMIN" tests next to their role-gate tests | Ordinary tenant A (pin on a third tenant P): no platform scope involved |
| AC2 same decisions through the full pipeline | "the same decisions through the FULL Letflow.Router pipeline with a real API token" (token minted for TENANT_ADMIN; tenant routes 200; `/tenants`, `/onboarding`, `/platform-migrations`, `/event-retention`, `/admin/services` and an unmatched path 403); platform tenant's own TENANT_ADMIN token: tenant route 200, platform prefixes 403 | Proves role-string parsing and the authorize plug agree end to end, not only a hand-assigned context |
| AC2 403 on every platform route | "all 21 routes answer 403 (ordinary and platform tenant TENANT_ADMIN), no row changes" (21 routes enumerated from each router's `__authz_routes__/0` and `permission_scope/1`, count pinned at 21, five prefixes asserted; tenants and `service_catalog` snapshot unchanged) | Table-driven so a new platform route is covered automatically; the snapshot proves a denied request wrote nothing |
| AC2 unmatched path | "unmatched paths are 403, not 404, for a TENANT_ADMIN" (all five platform routers plus Identity and Audit) | `:UnmatchedRoute` is the PLATFORM_ADMIN-only catch-all |
| REQ-446 cross-tenant denial for TENANT_ADMIN | `req446_cross_tenant_denial_test.exs` `@callers` gains `["TENANT_ADMIN"]` (the moduledoc reserved this line for REQ-447); `promotion_context_entries_scope_test.exs` AC5 tripwire moved: platform tenant's TENANT_ADMIN reads a foreign review 200 with `entries == []` and no marker, pinned and unpinned, operator control sees everything | D3's binding condition: TENANT_ADMIN holds `:PromotionsRead` but is not an operator |
| AC3 new ordinary tenant: TENANT_ADMIN binding, no PLATFORM_ADMIN | `TenantAdminSeedingTest` "an ordinary tenant (a different tenant is pinned) gets a TENANT_ADMIN group and binding and NO PLATFORM_ADMIN group or binding" (real `TenantOnboarding.provision_and_migrate/1`); `tenant_onboarding_test.exs` six rows | Role rows and group rows both asserted, and the binding's group is named TENANT_ADMIN |
| AC3 platform tenant has both | "the pinned platform tenant gets BOTH ... (all seven)" | The operator tenant keeps its operator role |
| AC3 pin unset | "with NO pin configured, no tenant is seeded PLATFORM_ADMIN" | Fail closed (decision 0046 D2: no pin, no platform tenant) |
| Idempotency | "re-seeding is idempotent" (same ids, no extra rows, ordinary 6 / platform 7) | Needed by `recover_provisioning/1` and the backfill |
| `seedable_role_names/1`, `platform_prefix?/1` | "pin unset", "pin set" (exact roles/0 order), upper-case pin, and a list of malformed or non-binary prefixes (public, empty, `tenant_`, wrong hex, upper-case hex, trailing char, SQL-injection string, nil, atom, integer, map, list) with the pin set, all fail closed | Pure functions on a security path; any non-match must mean "ordinary tenant" |
| Collision guard | `:process_routing_role` named TENANT_ADMIN: seed returns `{:error, {:role_name_taken_by_routing_role, "TENANT_ADMIN"}}`, groups and bindings unchanged (id, kind, group_id), nothing else seeded; `provision_and_migrate/1` returns `role_seeding_failed` and the tenant stays `:migrating`; a `:platform_role` TENANT_ADMIN binding is not a collision | Before any write, so no silent kind overwrite |
| Backfill (3.9) | `role_backfill_test.exs` REQ-447 describe: pre-REQ-447 six-role tenant is `:seeded`, legacy PLATFORM_ADMIN binding kept; empty ordinary tenant gets six incl. TENANT_ADMIN and no PLATFORM_ADMIN; pinned platform tenant gets seven; exactly-seedable tenants are `:unchanged` | Backfill no longer hard-codes six |
| AC6 inactive tenant | `tenant_status_test.exs` "REQ-447 AC6": every method 403 with the fixed body; TENANT_ADMIN with other roles still halted; platform tenant's own TENANT_ADMIN not exempt (its PLATFORM_ADMIN is: control); active tenant passes | Test only (design F7: no code change) |
| Task-worker exclusion | `tasks_test.exs` "REQ-447: a TENANT_ADMIN + TASK_WORKER caller sees the whole tenant queue" (`GET /tasks` and `GET /tasks/inbox`, another user's task visible; TASK_WORKER alone filtered, same data and paths); unit: `is_task_worker_only?/1` and `evaluate_access(:TasksList)` | Observable behaviour, not just the predicate |
| AC7 realm file | `TenantAdminSeedingTest` "AC7": realm role present (seventh), `tenant-admin-user` has exactly `["TENANT_ADMIN"]`, `admin-user` still `["PLATFORM_ADMIN"]`, no other user holds it; the string appears at exactly two JSON paths (role definition and that user); no `defaultRoles`, `defaultRole`, `defaultGroups`, `groups`, no composite role. `authorization_role_realm_test.exs` passes unmodified | The role must exist in the realm but must not be handed out by default |
| ISS-0778 end to end | `iss0778_platform_role_seeding_e2e_test.exs` rewritten for the new reality: onboarding seeds TENANT_ADMIN and no PLATFORM_ADMIN; a TENANT_ADMIN OIDC token reaches `GET /identity/users`; a PLATFORM_ADMIN claim resolves to no roles (403); a non-privileged token 403 | The old proof (a PLATFORM_ADMIN claim reaches `/tenants` in a fresh tenant) is no longer true by design; the pinned-platform-tenant version of it is the seeding test above |

## Fail-first and mutation checks

The code under test did not exist before the REQ-447 commits, so a pre-fix failure proves nothing; mutation is the evidence. One `lib/` line
per mutant, applied by script with a SHA-256 of the file recorded before and verified after the `finally` restore (`git status lib` clean).
Run set for every mutant: the three new files plus `tenant_status_test`, `tasks_test`, `authorization_test`, `role_registry_test`,
`role_backfill_test`, `tenant_onboarding_test`, `platform_scope_authorization_test` (339 tests, 339 passed unmutated).

| Mutant | File and line changed | Result (failed / 339) | Killed by |
|---|---|---|---|
| M1 TENANT_ADMIN also granted a platform permission | `authorization.ex`: `permission_scope(permission) == :tenant or permission == :TenantsManage` | 7 | grant-rule iff test, "not vacuous" test, REQ-309/315/317/318/401 regression grids (TENANT_ADMIN row) |
| M2 grant rule drops Catalog permissions | `authorization.ex`: `permission in core_permissions() and permission_scope(permission) == :tenant` | 4 | grant-rule iff test, "not vacuous", "Catalog permissions are granted", REQ-401 `:FixtureRead` |
| M3 PLATFORM_ADMIN seeded in every tenant | `role_registry.ex`: `if true or PlatformTenant.platform_prefix?(prefix)` | 13 | seeding tests (ordinary, pin unset, idempotency, malformed prefix), onboarding tests, backfill tests, role_registry seeding tests |
| M4 TenantStatus exempts TENANT_ADMIN | `tenant_status.ex`: `platform_scope?` or TENANT_ADMIN present | 3 | the three AC6 halting tests |
| M5 task-worker exclusion dropped | `authorization.ex`: remove `not has_role?(roles, :TENANT_ADMIN)` | 3 | `is_task_worker_only?` unit test, `:TasksList` decision test, `tasks_test` GET /tasks and /tasks/inbox test |

Each mutant was measured in its own run; all five were reverted and the checksum re-verified (`a8284ca7843a` authorization.ex, `552d4543cc0a`
role_registry.ex, `b4e75ae4b90b` tenant_status.ex, prefixes of SHA-256).

## Counts (partition 3, `MIX_ENV=test MIX_TEST_PARTITION=3`, sequential runs)

* All 18 touched test files in one run, plus `authorization_role_realm_test`, `routers/identity_test`, `me_test`, `onboarding_test`: 526 passed, 0 failed.
* Promotion tripwire follow-up: with `promotion_platform_events_two_tenant_test`, `promotion_context_shaping_test`, `promotion_platform_events_shaping_test`, `req442_tenants_mode_test` the run was 50 of 51 before the AC5 tripwire in `promotion_context_entries_scope_test` was moved to the allowed side (the one failure was that tripwire, by design); that file then passes 9 of 9.
* `mix format --check-formatted` on every touched file: clean.

## KNOWN residuals

* `mix letflow.check.test` (the full parallel suite) was NOT run: the host is low on memory and the instruction was touched files only. The dead-default-argument
  class (ISS-0069) was checked on the touched files only: every touched file was force-compiled by its own `mix test` run, 0 occurrences of
  "default values for the optional arguments"; the new files declare no default arguments. The whole-suite run belongs to TEST-RUNNER.
* Pre-existing warning `function unique_slug/0 is unused` in `role_registry_test.exs:115` (not introduced here, not touched).
* Some existing tests were edited by a count or enumeration only; where the old assertion proved a property that no longer holds by design (a fresh ordinary
  tenant has a PLATFORM_ADMIN binding) it was re-expressed (explicit legacy binding in `platform_scope_not_conferred_test`; TENANT_ADMIN token in the ISS-0778 e2e).
* Not covered by Part A: migration module and mix task (AC5), `POST /roles` built-in-name guard (H2), platform-escalation guards (3.6b) and the
  `POST /tokens` router check, the realm-side infra contract beyond `bpm-default.json`. AC4 and the PR 2 removal tests are PR 2.
* `test/specs` and test names: ExUnit atom limit (255 characters) was hit three times while renaming; names were shortened rather than the descriptions dropped.
