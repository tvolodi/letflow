# REQ-447 PR 2 test spec: PLATFORM_ADMIN exists only in the platform tenant (legacy honouring removed)

Design: `lib/letflow/design/req447-tenant-admin-role.md` sections 2.2, 3.4, 3.5, 11 "PR 2". Conventions: `test/specs/REQ-447-PR1.md`.

**RUN STATUS (2026-10-07).** Audit batches 1-9 over all 85 files that mention PLATFORM_ADMIN are green (run by the coordinator, partition 3).
Re-run for this update: `platform_admin_outside_platform_test.exs` 25 passed; `authorization_test.exs` 120 passed (incl. the new 0696b9eb test).
Mutation (below) was MEASURED against the 5 PR 2 files (272 tests, baseline all green). `mix letflow.check.test` (full suite plus the
ISS-0069 grep) was NOT run by TEST-DESIGNER here; no test helper with a default argument was added in this update.
The code under test did not exist before PR 2's lib commits, so mutation (not a pre-fix failure) is the evidence.

## New file

`test/letflow/api/platform_admin_outside_platform_test.exs` (real Postgres, `async: false`, platform tenant pinned on a third tenant P).

| Criterion (AC4 and design 3.4 / 3.5) | Test(s) | Why it exists |
|---|---|---|
| `upsert_role` rejects PLATFORM_ADMIN outside the platform tenant, exact tag | "is rejected in an ordinary tenant with the exact tag, writing nothing" (tenants A and B, no row afterwards) | The write-side rule itself |
| rejection precedes any Repo call | "is rejected before any Repo call" (random group id still yields the tag; `capture_repo_queries` is empty) | Design says "before any `Repo` call"; a rule placed after the group lookup would answer `:group_not_found` |
| fail closed with no pin | "fails closed in the would-be platform tenant when NO pin is configured" (upsert and `create_token`) | decision 0046 D2 |
| platform tenant unchanged; other built-ins unaffected | "is accepted in the platform tenant (control) ..." (PLATFORM_ADMIN ok in P; TENANT_ADMIN, PROCESS_DESIGNER, TASK_WORKER ok in A) | Proves the rule is narrow, not a blanket reject |
| `POST /roles` PLATFORM_ADMIN over HTTP | 403 with the fixed body for TENANT_ADMIN and TENANT_ADMIN+PLATFORM_ADMIN callers, both kinds, and a lone legacy PLATFORM_ADMIN caller; no row written. Control: the platform operator gets 200 in P | H1 answers first; the 422 arm of `routers/identity.ex` is defence in depth and is NOT reachable over HTTP, so it has no HTTP test (residual R2) |
| `POST /tokens` PLATFORM_ADMIN is 403 (router) | ordinary tenant, TENANT_ADMIN caller, two role lists, token count unchanged; control: operator in P gets 201 | Router check unchanged from PR 1 |
| `create_token/3` direct call `{:error, :invalid_role_set}` | A and B, two role lists, token count unchanged; platform prefix succeeds; ordinary tenant TENANT_ADMIN succeeds; unpinned P is rejected | Design 3.4 asks for a direct-call unit test, not an HTTP test |
| stored binding plus membership confers nothing | a RAW legacy binding and membership in A: `list_effective_role_names` still returns it (stored rows are untouched), but 5 platform routes, 6 tenant routes (including a PATCH) and an unmatched path are all 403 | "403 on a platform route AND no catch-all on tenant routes" |
| controls | TENANT_ADMIN GETs are 200; PLATFORM_ADMIN+TENANT_ADMIN keeps only TENANT_ADMIN (200 tenant, 403 platform); the platform operator gets 200 on `/tenants` and 404 (pass-through) on an unmatched Identity path; TENANT_ADMIN gets 403 on that path in both tenants | Proves the 403s are caused by the drop and not by a broken route |
| API token row carrying PLATFORM_ADMIN (simulates a pre-rule `create_token` call) | full `Letflow.Router`, raw token row: `auth_context.roles == []`; `/tenants`, `/identity/users`, unmatched path all 403; mixed lists keep TASK_WORKER / TENANT_ADMIN only; platform tenant token keeps its role (200) | Exercises `AuthPipeline.attach_auth_context` plus `Authorize` end to end |
| claim sync | with a legacy binding present: a lone claim resolves no group (marker stays nil, no role); PLATFORM_ADMIN+TENANT_ADMIN grants only TENANT_ADMIN; control: platform schema honours it | Without the strip, the legacy binding would resolve the group, so only the new rule explains the result |
| hand-assigned PLATFORM_ADMIN + TASK_WORKER inbox | `GET /tasks/inbox` and `GET /tasks` in A: another user's task is absent; control in P: both tasks visible | `routers/tasks.ex:256` re-parses raw roles; this is the only test that fails if that one line loses `effective_roles` |
| `:UnmatchedRoute` needs the platform flag | `evaluate_access` with PLATFORM_ADMIN and flag false/default is `Deny403`, true is `Allow` (plus the HTTP 404 pass-through control above) | LOW-3 |
| entities.ex OQ-10 | full pipeline `POST /entities/records/no_such_widget/export` with `unredacted: true`: platform operator and an ordinary TENANT_ADMIN are not refused with the "independently-granted" 403; an ordinary tenant's raw PLATFORM_ADMIN token is 403 | If the platform flag were not passed, the operator would lose unredacted export |
| C6 deletion | `function_exported?` false; setting the old config key to true changes nothing; grep contract over `lib/**/*.ex` and `config/**/*.exs` for the name | Design 3.5 asks for exactly this |

## Fixes to the six known failing files (changed assertions)

Every legacy-honouring assertion became a legacy-REMOVED assertion; none was deleted.

* `test/letflow/api/authorization_test.exs`: NEW (lib 0696b9eb): "TASK_WORKER + PLATFORM_ADMIN outside the platform tenant is row-filtered exactly like TASK_WORKER alone" (hand-built `[:TASK_WORKER, :PLATFORM_ADMIN]`, `platform_tenant?` false and default: `AllowWithRowFilter`, `{:own_user_and_groups, id}`, equal to the TASK_WORKER-only decision, never `:all`; the platform-tenant `Allow`/`:all` case is the pre-existing "TASK_WORKER + PLATFORM_ADMIN gets plain Allow" test). Also: every `evaluate_access` grid (REQ-309, 315, 317, 318, 401 loops) evaluates the `PLATFORM_ADMIN` row with `platform_tenant?: true`, every other role with false (previously false for all, relying on C6); "Allow is returned" (`:AuditRead`), "TASK_WORKER + PLATFORM_ADMIN gets plain Allow", the two REQ-318 AC5 PLATFORM_ADMIN tests now use `platform_tenant?: true`. NEW: a PLATFORM_ADMIN context with `platform_tenant?: false` is `Deny403` on `:AuditRead`.
* `test/letflow/api_token_auth_pipeline_test.exs`: all tokens `PLATFORM_ADMIN` -> `TENANT_ADMIN` (ordinary tenant); `auth_context.roles == ["TENANT_ADMIN"]`.
* `test/letflow/api/platform_scope_authorization_test.exs`: (1) "tenant scope follows the role matrix ... in and out of the platform tenant": PLATFORM_ADMIN was allowed for flag true and false; now allowed for true and REFUTED for false, with a TENANT_ADMIN allow for both; (2) the C6 switch test is replaced by "the C6 switch is gone, and a non-platform PLATFORM_ADMIN confers NOTHING": no function, the old config key set to true changes nothing, every `permissions/0` atom is denied to a lone PLATFORM_ADMIN with flag false and still granted with flag true, other roles keep their grants; (3) `evaluate_access` tenant keys: PLATFORM_ADMIN `Allow` only with flag true, `Deny403` with false; (4) `:UnmatchedRoute`: Allow for a PLATFORM_ADMIN of any tenant -> Allow only with flag true, `Deny403` with false.
* `test/letflow/modules/bilimbaga_solution_e2e_test.exs`: the installer is TENANT_ADMIN; the "404 for every role" loop excludes `:PLATFORM_ADMIN` (not mintable in an ordinary tenant; TENANT_ADMIN stays covered).
* `test/letflow/api/platform_marker_not_writable_test.exs`: (d) `PATCH /tenant/settings` is sent as TENANT_ADMIN (200, nothing stored) and NEW the same as A's PLATFORM_ADMIN is 403; (c) follow-up adds a TENANT_ADMIN 403 on `/tenants`.
* `test/letflow/api/authorization_tenant_admin_test.exs`: the "legacy compatibility (C6 ON)" test is replaced by "legacy honouring REMOVED": function gone; a non-platform PLATFORM_ADMIN context is `Deny403` on three tenant keys (were `Allow`), three platform keys and `:Unknown`; `effective_roles/2` truth table (drops unless exactly `true`, non-list is `[]`, TENANT_ADMIN untouched).

## Audit sweep (part C): converted files

Pattern: a non-platform tenant's PLATFORM_ADMIN used as the ordinary admin becomes TENANT_ADMIN; legacy rows are inserted RAW; the platform operator (pinned tenant) is untouched. Security-relevant changes are listed (an allow turned into a deny, or a new deny).

* Shared support: `test/support/platform_tenant_fixture.ex` (`mint_token!` inserts a raw legacy token when roles contain PLATFORM_ADMIN and the fixture is not the pinned platform tenant at call time), `test/support/tenant_admin_migration_fixture.ex` (`legacy!/2` raw binding).
* `identity_test.exs` (routers; 58 identities, describe renamed), `identity_test.exs` (top level; 6 token mints, new `:invalid_role_set` test), `webhooks_test`, `dlq_test`, `req212_attachments_routes_test`, `req386_attachment_links_routes_test`, `req317_record_attachments_routes_test`, `req388_attachment_access_denial_audit_test`, `req078_supporting_routes_test`, `req196_audit_route_test`, `identity_login_directory_test`, `solution_packs_update_test`, `solution_packs_module_owned_pack_test`, `role_binding_install_test`, `exam_sessions_test`, `runner_test`, `runner_template_and_outcomes_test`, `tasks_test`, `entities_test`, `entities_aggregate_test`, `entities_export_test`, `tenant_settings_test`, `tenant_settings_scope_test`, `onboarding_scope_extension_test`, `iss0736_oidc_live_revocation_test`, `authz_deny_log_test`, `platform_scope_facts_test`, `me_test`, `modules_test`, `api_pipeline_integration_test` (comment), `admission_pipeline_test`, `req442_tenants_mode_test`, `req442_mode_exposure_test`: role swap, same expected statuses, except:
  * `entities_test`, `tasks_test` (old-404 expectations fixed): an unmatched path under the mount is now 403 for a tenant admin (was the 404 pass-through for the legacy PLATFORM_ADMIN); the platform operator (pinned tenant) keeps 404 (`tasks_test` router unmatched-path test uses the pinned operator for the 404 catch-all).
  * `admission_pipeline_test`: unmatched path 404 -> 403 (5 assertions; still proves "not 503"); a TENANT_ADMIN gets 403 on an unmatched path.
  * `modules_test`, `me_test`: PLATFORM_ADMIN is out of the minting loops; `me_test` adds PLATFORM_ADMIN 403 on `GET /modules`.
  * `tenant_settings_scope_test`, `tenant_settings_test`: NEW deny: an ordinary tenant's PLATFORM_ADMIN `PATCH /tenant/settings` is 403, row unchanged.
* Security-relevant allow -> deny or new deny: `platform_scope_routes_test` (A's legacy PLATFORM_ADMIN token on `/promotions`: 200 -> 403; `/tenants` TENANT_ADMIN 403 added), `identity_roles_guard_test` (A's PLATFORM_ADMIN `POST /roles` of the 6 built-in names x 2 kinds: 200 -> 403, no role row changes), `authorize_test` (PLATFORM_ADMIN outside the platform tenant 403 and no `scoped_opts`), `req446_cross_tenant_denial_test` (A's PLATFORM_ADMIN caller line replaced by a test asserting 403 on all 10 identifier rows plus the two GETs, B untouched), `promotion_platform_events_two_tenant_test` (A's PLATFORM_ADMIN 403 and no leaked ids), `promotion_platform_events_shaping_test` ("pin unset would-be operator" PLATFORM_ADMIN: shaped 200 -> 403, TENANT_ADMIN gets the shaped payload), `promotion_scope_test` ("reaches the handler" split: TENANT_ADMIN and the platform operator not 403; NEW PLATFORM_ADMIN of an ordinary tenant or with the pin unset is 403 on all 12 rows; the "no platform tenant configured" test adds a PLATFORM_ADMIN 403), `promotion_context_entries_scope_test` / `promotion_context_allowlist_test` / `promotion_context_shaping_test` / `promotion_approve_reject_stored_ids_test` (reader vs operator identities), `promote_source_tenant_test` (unpin test split; NEW PLATFORM_ADMIN 403 in ordinary tenant and with no pin), `platform_prefix_uniform_403_test` (`:UnmatchedRoute` test: PLATFORM_ADMIN 404 in A -> 403, 404 only in P), `platform_tenant_status_test` and `tenant_target_test` (TENANT_ADMIN rows added; legacy row asserts no platform scope), `tenant_modules_test`, `tenant_modules_settings_test`, `tenant_solutions_test` (PLATFORM_ADMIN no longer exempt in the AC4 403 loops), `platform_escalation_guard_test` (D10: an ordinary-tenant legacy admin's `POST /tokens` for a TENANT_ADMIN token: 201 -> 403, token count unchanged; TENANT_ADMIN control added), `platform_admin_role_binding_test` (TENANT_ADMIN added to 403 matrices), `admin_services_test` and `promotions_test` and `role_registry_test` (new 403/`upsert_role` rejection tests), `role_backfill_test` (legacy PLATFORM_ADMIN binding raw insert), `platform_scope_not_conferred_test` (10(b): claim is now IGNORED in A, a legacy stored membership is a separate test, platform tenant control; 10(d): `upsert_role` returns the tag, binding inserted raw, settings edit by TENANT_ADMIN).

## Not converted or not verified (for the later run)

1. `test/letflow/integration/keycloak_auth_pipeline_test.exs:241` `assert "PLATFORM_ADMIN" in roles`: excluded by default (needs live Keycloak and the real `bpm-default` tenant); `bpm-default` is not the pinned platform tenant, so this will fail. Suggested: use the realm user `tenant-admin-user` and assert TENANT_ADMIN (needs the binding seeded in that schema) or pin `bpm-default`.
2. Not read line by line: the later describes of `identity/tenant_admin_migration_test.exs` (its fixture was fixed; its `bind!` calls with `:process_routing_role` PLATFORM_ADMIN are unguarded).
3. Assumptions to confirm by running: `TENANT_ADMIN` reaches the handler of `POST /tenants/:id/promote/:key` (`promotion_scope_test` row 12, `req446` B-side control expecting 409); `:MyModulesRead` for TENANT_ADMIN in `me_test`; `platform_scope_routes_test` legacy-token 403 (not 401); the `authorization_test` "16 failures" count could not be reconciled by reading (7 sites found and fixed); any further test failing for another reason is unknown.
4. Other callers of `Fixture.mint_token!(non-platform, ["PLATFORM_ADMIN"])` now get a raw token (stored legacy shape) and so exercise the drop; any test expecting success from such a token needs conversion.

## Residuals and risks

* R1 (RESOLVED by lib 0696b9eb) `evaluate_access/2` now deletes PLATFORM_ADMIN before both the grant and the task scope; covered by the new `authorization_test` test, mutant M9.
* R2 the router's 422 arm for `:platform_admin_outside_platform_tenant` and the 422 `roles_invalid` for tokens are unreachable over HTTP by design; covered at unit level only.
* R3 `lib/letflow/api/authorized_router.ex` docstring for `:ordinary` still says "PLATFORM_ADMIN reaches the 404" without the platform-tenant qualifier (stale doc, not edited).

## Measured mutants (one lib line each, 5 files: platform_admin_outside_platform, authorization, authorization_tenant_admin, platform_scope_authorization, routers/tasks; 272 tests, baseline 272 passed)

Each mutant was applied, the 5 files run, and the file restored by SHA-256 checksum (verified `True` each time; `git status lib` clean afterwards).

| # | Mutant (file) | Result | Killed by |
|---|---|---|---|
| M1 | inbox uses `roles_from_strings` instead of `effective_roles` (`routers/tasks.ex`; also the "effective_roles removed in tasks.ex" mutant) | 271/272, KILLED | AC4 hand-assigned PLATFORM_ADMIN + TASK_WORKER inbox test |
| M2 | `platform_tenant?:` dropped from the AccessContext (`routers/entities.ex`) | 271/272, KILLED | OQ-10 unredacted-export test |
| M3 | claim-sync strip removed, `if true` (`identity.ex`) | 270/272, KILLED (2) | claim sync: lone claim resolves no group; PLATFORM_ADMIN+TENANT_ADMIN grants only TENANT_ADMIN |
| M4 | `upsert_role` rejection removed (`role_registry.ex`) | 269/272, KILLED (3) | rejection with exact tag; rejected before any Repo call; fails closed with no pin |
| M5 | `create_token` rejection removed (`identity.ex`) | 270/272, KILLED (2) | direct-call `:invalid_role_set`; no-pin fail closed |
| M6 | `:UnmatchedRoute` platform gate removed (`authorization.ex`) | 270/272, KILLED (2) | `platform_scope_authorization_test` UnmatchedRoute test; AC4 `:UnmatchedRoute` needs the flag |
| M7 | PLATFORM_ADMIN drop removed in `attach_auth_context` only (`plugs/auth_pipeline.ex`) | 270/272, KILLED (2) | raw-token `auth_context.roles == []`; only the PLATFORM_ADMIN entry dropped |
| M8 | `Authorize` plug uses `roles_from_strings` (`plugs/authorize.ex`) | 272/272, SURVIVED | EQUIVALENT, see below |
| M9 | 0696b9eb task-scope change reverted: `is_task_worker_only?(ctx.roles)` (`authorization.ex`) | 271/272, KILLED | new `authorization_test` row-filter test |
| M10 | 0696b9eb grant change reverted: `has_permission_in_scope?(ctx.roles, ...)` (`authorization.ex`) | 272/272, SURVIVED | EQUIVALENT, see below |
| M11 | `effective_roles/2` never drops (`authorization.ex`) | 270/272, KILLED (2) | `effective_roles/2` truth table; inbox test |

Survivors (both equivalent, not killable through observable behaviour):

* M10: `has_permission_in_scope?/3` itself already deletes PLATFORM_ADMIN for tenant-scope permissions unless the flag is `true`, and requires the flag for platform-scope ones, so passing the raw or the filtered roles yields the same grant for every permission. The 0696b9eb grant-side change is redundant by design (the task-scope side, M9, is the load-bearing half).
* M8: after `attach_auth_context` (M7) and with `evaluate_access/2` now dropping PLATFORM_ADMIN itself (M9/M10 analysis), the `Authorize` plug's own `effective_roles/2` call is a third, redundant layer: for every policy key the decision is identical, and the deny log does not record roles. It is defence in depth, kept per design 3.5; no test can distinguish it.

## Behaviour changes for the PR body

1. An unmatched path under a mount (`:UnmatchedRoute`) for a legacy tenant PLATFORM_ADMIN: 404 pass-through becomes 403 (the platform operator keeps the 404; `admission_pipeline_test`, `entities_test`, `tasks_test`, `platform_prefix_uniform_403_test`).
2. A legacy PLATFORM_ADMIN token, OIDC claim or stored binding/membership in an ordinary tenant confers nothing (dropped at `attach_auth_context`, again at `Authorize` and `evaluate_access/2`; claim sync strips the claim; stored rows are untouched).
3. `POST /tokens/roles` PLATFORM_ADMIN in an ordinary tenant is 403 (router check first; the 422 arms are unreachable over HTTP).
4. `Identity.create_token/3` called directly with PLATFORM_ADMIN and a non-platform prefix (or no pin) returns `{:error, :invalid_role_set}`.
5. `RoleRegistry.upsert_role/4` of PLATFORM_ADMIN outside the platform tenant returns `{:error, :platform_admin_outside_platform_tenant}`, before any Repo call.
6. `evaluate_access/2` row-filters a hand-built `[:TASK_WORKER, :PLATFORM_ADMIN]` context outside the platform tenant exactly like TASK_WORKER alone (no `task_scope: :all`).
7. The C6 own-tenant switch is deleted; ordinary-tenant admins are TENANT_ADMIN; `PATCH /tenant/settings`, `POST /roles`, promotions etc. now 403 for a non-platform PLATFORM_ADMIN (full list in the audit sweep above).
