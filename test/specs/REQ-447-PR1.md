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

---

# PART B: migration (`TenantAdminMigration.run/1`, `verify/0`), `mix letflow.migrate_tenant_admins`, `ApiToken.roles_rewrite_changeset/2` (AC5)

Design: `lib/letflow/design/req447-tenant-admin-role.md` section 3.8 and `lib/letflow/design/req447-infra-realm-mapping.md` section 8 (runbook).
Part A above is unchanged. PART C (H2, 3.6b guards, `POST /tokens`) is still not covered.

New files:

* `test/letflow/identity/tenant_admin_migration_test.exs` (36 tests, real Postgres, `async: false`)
* `test/mix/tasks/letflow.migrate_tenant_admins_test.exs` (9 tests: 4 in-process, 5 in a child `mix` process, `async: false`)
* `test/support/tenant_admin_migration_fixture.ex` (shared fixtures: legacy-state tenants, pinned operator tenant, row snapshot, registration isolation)

## Fixture facts that shape the tests

* `TenantFixture.provisioned_tenant!/1` switches the sandbox to `:auto`, so fixture data is COMMITTED and removed by the fixture teardown.
  Consequence 1: a child `mix` process sees the test's tenants, so the exit-status paths are tested end to end through the real task.
  Consequence 2: the sweep covers every committed registration. The shared test DB holds a leftover throwaway template-build registration
  (`tenant_template_build_...`) that always fails the sweep (`failed=1`), which would make every task run exit 1 (and `System.halt` the VM in
  process). `operator_tenant!/0` therefore deletes the other registrations after the first fixture call and restores them in `on_exit`
  (verified present again afterwards). The sandbox cannot do this, because its transaction is discarded by the `:auto` switch.
* The Mix task halts on a refusal or a failed tenant, which would kill the test VM. Those paths run in a child process
  (`System.cmd(mix, ["letflow.migrate_tenant_admins" | args], env: MIX_ENV, MIX_TEST_PARTITION, LETFLOW_PLATFORM_TENANT_ID)`); the pin is the
  child's environment variable exactly as in production. Non-halting paths run in process through `Mix.Shell.Process`.

## Criterion to test mapping

| Criterion | Test(s) | Why it exists |
|---|---|---|
| AC5 two PLATFORM_ADMIN members + tokens end in TENANT_ADMIN, no PLATFORM_ADMIN binding | "two PLATFORM_ADMIN members and tokens end as TENANT_ADMIN members..." (2 users, 5 tokens: PA only, PA+PROCESS_DESIGNER+TENANT_ADMIN, PROCESS_DESIGNER+PA, a revoked PA token, a bystander token) | Exact report keys and counts; members in the TENANT_ADMIN group; binding kind; legacy group and members KEPT; every token column except `roles` unchanged (hash, name, user, expiry, revoked_at, last_used_at, inserted_at); order kept and de-duplication; bystander untouched |
| AC5 token plaintext keeps working | same test, and the `roles_rewrite_changeset/2` test: `changes == %{roles: [...]}` and the updated row equals the original except `roles` | The narrow changeset is the reason the plaintext token survives |
| AC5 second run changes nothing | "a second run changes nothing": whole report `migrated == [] and failed == [] and unchanged == [a]`, full row snapshot equal, one `role_binding.removed` entry in total; a member added AFTER the first run to the inert legacy group is not promoted | Idempotency, and the "copy is gated on the binding" rule |
| AC5 platform tenant untouched | snapshot of P equal after the run, P in no report list; `platform_tenant_binding_ensured` reports false then true and the migration never creates the binding | Decision 0046 D2: the operator tenant is never swept |
| Existing TENANT_ADMIN binding | "an existing TENANT_ADMIN binding keeps its group": the copy targets the custom-named group, only the missing member is copied (one `group_member.copied` entry) | Design step 2 note |
| Empty tenant | binding created with zero members, `tenant_admin_member_count_after == 0` (lockout surfaced as 0) | Design step 6 |
| Per-tenant transaction, sweep continues | routing role named TENANT_ADMIN gives `failed` with `:role_name_taken_by_routing_role`, keys exactly `[:reason, :schema_name, :tenant_id]`, rows unchanged, the next tenant converted (the failing tenant is created first so it is processed first); routing role named PLATFORM_ADMIN gives `:platform_admin_name_is_routing_role`, untouched; a failure AFTER earlier writes (audit lock table dropped, so the binding and the copy are already written when it raises) rolls the tenant back entirely and the next tenant still converts | The first two fail before any write; the third proves the transaction really spans the writes |
| Preconditions refuse with the exact tag and ZERO writes | pin unset, non-UUID pin, unregistered UUID, wrong slug, missing slug, missing realm, realm mismatch, no options (first tag is the slug), pinned tenant with no binding / a binding with no members / members in an unbound group named PLATFORM_ADMIN, pinned tenant with no realm; each compares a full row snapshot (groups, members, roles, tokens, audit) before and after | The safety net of the whole requirement |
| Wrong-but-registered pin cannot strip the operator | pin on ordinary tenant A (it has members); the operator's slug, A's slug with the operator's realm, and A's slug alone are each refused (`slug_mismatch`, `realm_mismatch`, `realm_required`) | M2 of the design |
| Dry run | no write statement in the captured query telemetry (no INSERT/UPDATE/DELETE/SAVEPOINT/BEGIN/ROLLBACK/DDL) with and without slug/realm, row snapshots unchanged; never refuses (`would_refuse` tags in a fixed order, including all three at once); counts equal a real run's on identical data for three tenants (new binding with 2 members and 2 tokens, existing binding with one overlapping member, already converted); `preconditions` map exact; failed tenants listed in a dry run; only an exact `dry_run: true` is a dry run (`"true"`, `1`, `:yes`, `nil`, `"dry"` are real runs and refuse without options, and `"true"` with options really writes) | One mechanism, same numbers, no surprise writes |
| Audit entries | `group_member.copied` after_state is exactly `%{"user_id" => id}`; `role_binding.removed` before_state exactly `%{"name" => "PLATFORM_ADMIN"}`; `token.roles_migrated` before/after exactly `%{"roles" => [...]}`; actor nil; no email, username, display name or token hash in any entry or in the report; no entry in the platform tenant | INV-2 / INV-4 |
| Exceptions become `:unexpected_error`, nothing printed | `run/1` (real and dry) with the pinned tenant's `tenant_role` table gone returns `{:error, {:precondition_failed, :unexpected_error}}`, stdout empty; `verify/0` with a tenant's table gone returns `{:error, :unexpected_error}`; this module's log lines name only `Postgrex.Error` (not the table, not "does not exist") | The rpc wrapper must not print Postgrex text |
| `verify/0` | exact top-level and per-tenant keys; exact values for the platform tenant and an ordinary tenant before and after a run (`platform_admin_group_member_count` is 0 afterwards: the legacy group is unbound, so it is not counted); no user attribute or token hash in the term; `pin_configured: false` when unset | Runbook steps B and G read these fields |
| Mix task flags and output | in process: `--dry-run` prints the exact first line (`pinned slug=... operators=1 members_to_copy=2 tokens_to_rewrite=1 would_refuse=`), `SUMMARY`, one tenant line; `would_refuse=<tag>` for unset pin, wrong slug, wrong realm, no halt; a real run with `--platform-tenant=X --expected-realm-id Y` (both `=` and space forms) prints exact lines and a second run prints `migrated=0 unchanged=1`; output carries no email, username, display name, user id, token hash, `Postgrex`, `Ecto` or a map | Output contract of 3.8 |
| Mix task exit status | child process: `--dry-runn`, `--bogus=1`, `--dry-run extra`, `extra` give `REFUSED invalid_option`, exit 1, no SUMMARY; seven refusals (`not_configured`, `not_registered`, `slug_required`, `slug_mismatch`, `realm_required`, `realm_mismatch`, a wrong-but-registered pin) and `has_no_operator` give `REFUSED <tag>`, exit 1, rows unchanged; `--dry-run` with only `would_refuse` exits 0 (and, unpinned, both tenants count as ordinary); `--dry-run` with a failed tenant exits 1 and prints `tenant <id>: FAILED reason=<atom>`; a real run converts, exits 0, DB state verified, second run `migrated=0 unchanged=2`, then with a failing tenant exits 1 while the other stays unchanged | The task's halts cannot be tested in process |
| Runbook expressions (infra file section 8) | the fenced blocks of steps A, B, D, E, F, G are extracted from the infra markdown at test time and evaluated with `Code.eval_string` (E and F with `"bpm-default-slug"` and `expected_realm_id: "bpm-default"` replaced by the fixture's slug and realm): A prints `true` twice; B, D, E, F, G print `SUMMARY` and no `ERROR`; D's first line names slug, realm, `operators=1`, `would_refuse=[]`; D writes nothing; F reports `migrated=0 unchanged=1 failed=0`; G shows `pa_binding=false ta_binding=true ta_members=2 tokens_pa=0` for the converted tenant and `platform=true pa_binding=true` for the operator; a wrong slug in E prints `ERROR precondition platform_tenant_slug_mismatch` and writes nothing | Proves the documented commands are valid against the code (the runbook is otherwise untested by design). They run on the test node, so the rpc transport itself (`bin/letflow rpc`) is not exercised |

## Mutation checks

The code under test did not exist before the REQ-447 commits, so mutation is the evidence. One logical edit per mutant (M4 is two lines: the source of the
copy and the guard clause that short-circuits it), applied by script with the file's SHA-256 recorded before and verified after a `finally` restore
(`git status` shows no change under `lib/`). Run set per mutant: both new test files (45 tests, 45 passed unmutated). Partition 3, sequential.

| Mutant | Change | Failed / 45 | Killed by |
|---|---|---|---|
| M1 | dry run writes: `if dry?` forced to `if false` in `process_tenant` | 9 | "writes nothing" (write statements and snapshot), "counts equal a real run", "never refuses", runbook, 4 in-process task tests, subprocess dry-run |
| M2 | slug mismatch no longer refused | 6 | "wrong slug", "a wrong-but-registered pin", dry "never refuses", runbook (wrong slug), in-process and subprocess task refusals |
| M3 | realm mismatch no longer refused | 6 | "expected_realm_id mismatch", "pinned tenant with no realm", "a wrong-but-registered pin", dry "never refuses", task tests |
| M4 | copy not gated on the PLATFORM_ADMIN binding (members of any group named PLATFORM_ADMIN are copied) | 4 | "a second run changes nothing ... member added later is NOT promoted" (the targeted kill), "counts equal a real run", "nothing to convert" (the mutant crashes on a group-less tenant, an artefact), subprocess |
| M5a | token rewrite drops the other roles | 2 | the AC5 main test and the audit test |
| M5b | `roles_rewrite_changeset` also clears `revoked_at` (`api_token.ex`) | 1 | the AC5 main test (revoked token column compare) |
| M6 | idempotency broken: the legacy binding is not deleted | 7 | AC5 main, "a second run changes nothing", "per-tenant ... sweep continues", `verify/0` values, runbook, in-process and subprocess task tests |
| M7 | platform tenant not skipped by the sweep | 10 | AC5 main (platform snapshot), "second run", `platform_tenant_binding_ensured`, "counts equal", audit test, runbook, task tests |
| M8 | `has_no_operator` check removed | 5 | the three operator-less preconditions, dry "never refuses", subprocess refusals |
| M9 | any truthy `dry_run` is a dry run | 1 | "only an exact dry_run: true is a dry run" |
| M10 | `would_refuse` dropped from a dry run | 3 | dry "never refuses", in-process and subprocess dry-run tests |

All mutants reverted; checksum prefixes verified identical after each (`tenant_admin_migration.ex` `9e4c95f374ce`, `api_token.ex` `56a8471a5b56`).

## Counts and checks (partition 3, sequential)

* `tenant_admin_migration_test.exs` 36 passed, `letflow.migrate_tenant_admins_test.exs` 9 passed, together 45 passed after a `--force` recompile
  (0 occurrences of "default values for the optional arguments"; the new files declare no default arguments; the two unused-alias warnings found on the
  forced compile were removed and the pair re-run: 45 passed, no warning).
* `mix format --check-formatted` on the three new files: clean.

## KNOWN residuals

* `mix letflow.check.test` (the whole parallel suite) was not run: the host is low on memory and the instruction was touched files only. The ISS-0069 class was
  checked on the touched files by a forced recompile. The full-suite run belongs to TEST-RUNNER.
* The real-run-with-a-failed-tenant exit 1 and the dry-run-with-a-failed-tenant exit 1 share one line of the task; both are exercised through a child process.
* The test database holds a committed leftover registration (`tenant_template_build_d5137dcab200abf9d4c757debf5175bb`, provisioned 2026-09-27) that fails any
  sweep. The tests are isolated from it (see above) but a human may want to clean it; it also means `mix letflow.migrate_tenant_admins` itself would exit 1 on that
  database.
* The pair takes about 100 s because the child processes boot the application five times.

# REQ-447 PR 1, PART C: H2 built-in role-name guard and the 3.6b platform-escalation guards (design sections 3.6, 3.6b, 11)

Scope: the guards in `lib/letflow/routers/identity.ex`. Caller under test for 3.6b: a `TENANT_ADMIN` of the PLATFORM tenant (pin on P), who holds
`:TokensManage`, `:GroupsManage`, `:UsersManage` but has no platform scope. Positive control for every refusal: the operator (`PLATFORM_ADMIN` of P).

New files (`async: false`, real Postgres, direct dispatch into `Letflow.Routers.Identity`):

* `test/letflow/api/platform_escalation_guard_test.exs` (30 tests)
* `test/letflow/routers/identity_roles_guard_test.exs` (8 tests; the design's "H2" cases, in a new file rather than `identity_test.exs`)

Existing tests: NO expectation had to change. `platform_admin_role_binding_test.exs` (12), `routers/identity_test.exs` (69; its POST /tokens cases issue
`TASK_WORKER` tokens, only the CALLER holds PLATFORM_ADMIN), `api_token_auth_pipeline_test`, `plugs/iss0736_oidc_live_revocation_test`,
`routers/onboarding_scope_extension_test`, `scripts/persona_actor_seed_missing_account_test` were run unmodified against the lib commits and pass.

## Criterion to test mapping

| Design item | Test(s) | Why it exists |
|---|---|---|
| F1 (i) mint PLATFORM_ADMIN token | "POST /tokens": exact, lower, mixed case, padded, among other roles (9 role lists) all fixed 403 and no token row; 403 wins over a 422 bad `expires_at` (with a control that a non-PLATFORM_ADMIN role gets the 422); byte-identical refusal body; control: operator 201; control: TENANT_ADMIN still mints TENANT_ADMIN / ordinary tokens; `Identity.create_token/3` direct call unchanged | Guard order and body, not over-broad |
| D10 legacy PLATFORM_ADMIN of an ordinary tenant | "D10: legacy tenant PLATFORM_ADMIN": 403 for a PLATFORM_ADMIN token, 201 for a TENANT_ADMIN token | Intended behaviour change, with the tenant-scope control |
| F1 (ii) group members and group | "the PLATFORM_ADMIN-bound group": add self/other (also `user_ids` form), remove an operator, delete the group (with members and empty) all 403, memberships/binding unchanged; guard found by BINDING not name (a group merely named PLATFORM_ADMIN is not protected); controls: operator add/remove, TENANT_ADMIN on an ordinary group | By-binding protected set |
| RAW-BYTE negative tests (SECURITY BLOCKER) | "RAW-BYTE: group id spellings" (add member, remove member, delete group; 6 spellings each: canonical, upper-case, mixed-case, raw 16 bytes `%XX` and `%xx`, canonical text fully percent-encoded), "RAW-BYTE: user id spellings" (PATCH, status), "RAW-BYTE: token id spellings" (DELETE); plus a non-cast spelling test | The guard compares after `Ecto.UUID.cast/1`; a string compare passes the raw/upper-case spellings |
| Non-vacuity of the raw-byte denials | each spelling is also sent by the operator: the test requires that canonical, upper-case, mixed-case and percent-encoded-text spellings REALLY reach the real row (state change asserted) | A denial is only meaningful if the same request would otherwise work |
| F1 users | "PATCH /users/:id and POST /users/:id/status": operator target 403 (state unchanged), control 200; ordinary member 2xx; guard follows the binding (moves away when the binding moves) | |
| M1 revoke token | "DELETE /tokens/:id": PLATFORM_ADMIN token 403 and unrevoked, operator 200; ordinary token 2xx, unknown id 404 | |
| H1 on POST /roles | "POST /roles for the PLATFORM_ADMIN name": both kinds, name variants as platform-tenant TENANT_ADMIN: 403, rows unchanged; operator rebinds | |
| `:none` reliance | "reliance": no binding in A (all group/user routes open to a TENANT_ADMIN), P with pin and no binding (open, H1 still blocks minting), pin unset (even the would-be operator refused: fails closed) | Documents the stated reliance |
| H2 PROCESS_DESIGNER | `identity_roles_guard_test`: all seven built-in names x both kinds x 4 spellings x tenants A and P: 403, rows unchanged (with pre-existing bindings so an overwrite would show), no role named in the body; the TENANT_ADMIN name with `process_routing_role` kind refused before `upsert_role` (platform_role binding keeps kind and group); control proves the kind overwrite is real for a holder of the permission; ordinary routing roles (incl. `TENANT_ADMINS`, `TASK_WORKER_2`) still 2xx | |
| H2 who may | TENANT_ADMIN of A and P: six names 2xx, PLATFORM_ADMIN (4 spellings, 2 kinds) 403; legacy tenant PLATFORM_ADMIN same; operator binds both; TASK_WORKER refused by the permission gate | |

## Facts measured while writing (Ecto 3.14.1)

* `Ecto.UUID.cast/1` accepts the raw 16-byte binary, but `Repo.get/3` and `where: id == ^raw16` raise `Ecto.Query.CastError`. So the raw-byte spelling never
  resolves a real group/user/token downstream (a request past a broken guard would raise, not write). The tests therefore assert (a) the TENANT_ADMIN always gets the
  fixed 403 for every spelling (a string-compare guard would let the raw spellings through to the handler, which raises: the mutant is killed), and (b) the operator
  control for the text spellings reaches the real row.
* `DELETE /groups/:id` of a group bound to a role is refused by Postgres (`tenant_role_group_id_fkey`), even for the operator: a pre-existing unhandled 500 (see defects).
  The control asserts that foreign-key error, which proves the real row was addressed.
* User routes call `Identity.get_user/2` BEFORE the guard, so a raw-byte user id raises `CastError` instead of 403 (nothing is written).

## Mutation checks (one `lib/letflow/routers/identity.ex` line each; SHA-256 recorded and re-verified after every `finally` restore, `git status lib` clean; partition 3)

Run set per mutant: both new files + `platform_admin_role_binding_test` (50 tests, 50 passed unmutated).

| Mutant | Result (failed / 50) | Killed by |
|---|---|---|
| M1 `requested == bound` back to string compare `group_id == bound_id` | 3 | RAW-BYTE add member, remove member, delete group |
| M2 POST /tokens guard removed | 6 | POST /tokens (variants, 403-wins-over-422, byte-identical body), D10, two `:none`/pin-unset tests |
| M3 DELETE /tokens/:id guard removed | 2 | token spellings, DELETE /tokens/:id |
| M4 POST /users/:id/status guard removed | 2 | users test, RAW-BYTE user ids |
| M5 H2 removed | 2 | PROCESS_DESIGNER all-names, kind-overwrite |
| M6 H2 only for `platform_role` kind | 2 | same two (the `process_routing_role` half) |
| M7 PATCH /users/:id guard removed | 3 | users test, RAW-BYTE user ids, binding-follows test |
| M8 add-member guard removed | 4 | add-self, binding-by-name, RAW-BYTE add, pin-unset |
| M9 remove-member guard removed | 2 | remove operator, RAW-BYTE remove |
| M10 delete-group guard removed | 2 | delete group, RAW-BYTE delete |
| M11 group guard loses the platform-scope exemption (operator refused too) | 4 | operator controls and RAW-BYTE tests |

All 11 killed. Not measured: mutating `Identity.platform_admin_member?/2`, `Identity.token_carries_platform_admin?/2` and `RoleRegistry.platform_admin_group_id/1` internals (only router-level lines were mutated).

## Counts and residuals

Partition 3, sequential: `platform_escalation_guard_test` 30 passed, `identity_roles_guard_test` 8 passed (38 with `--force`, 0 occurrences of "default values for the optional arguments",
0 warnings), `platform_admin_role_binding_test` 12, `identity_test` 69. `mix format --check-formatted` clean. `mix letflow.check.test` (full suite) NOT run: low memory host, touched files only; the forced recompile of both new files is the ISS-0069 check.
