# Design: ISS-1032 (Q-1014 / GH #2317) and ISS-1033 (Q-1015 / GH #2318) - role-bound group delete is a clean 409; identity route ids are cast before any guard or fetch

Owner: ELIXIR-DEV. Severity LOW (INV-5 / INV-2 / INV-4 style). Size S3, ONE PR. Both are REQ-447 PR 1 SECURITY-REVIEWER residuals; REQ-447 is done (PR 2 merged, ff944312).
Design only: signatures, rules and test recipes; no implementation code. Read of the code at origin/main ff944312.

## 1. Findings (what the code does today, with file:line)

Files: `lib/letflow/routers/identity.ex` (R), `lib/letflow/identity.ex` (I), `lib/letflow/identity/role_registry.ex`.

### 1.1 ISS-1032

* `DELETE /groups/:id` -> `handle_delete_group/3` (R:517-524) -> `with_platform_admin_group_guard/4` (R:552-558) -> `Identity.delete_group/2` (I:670-684).
* `delete_group/2` is ONE statement: `DELETE FROM groups WHERE id = ^id AND NOT EXISTS (member)` through `Repo.delete_all`. Zero rows -> `{:error, :not_found_or_has_members}` (404). It knows nothing of `tenant_role`.
* `tenant_role.group_id` is `references(:groups, type: :binary_id)`, no `on_delete` (migration `20260819000002_create_tenant_role_tenant_scoped.exs:38`), so Postgres NO ACTION: deleting a memberless group that any `tenant_role` row points to raises `Postgrex.Error` (`code: :foreign_key_violation`, constraint = Ecto's default `tenant_role_group_id_fkey`). Nothing rescues it, so the router returns 500 (the guard test at `platform_escalation_guard_test.exs:433` and `:590` even asserts the raise, "reported as a defect").
* The binding is `kind` `:platform_role` or `:process_routing_role` (`tenant_role` has both; `RoleRegistry.upsert_role/4`). The FK does not care about kind.
* The identity router and `Identity` audit only SUCCESSFUL writes (`Audit.append_multi` in create_user, update_user_*, create_group, create_token, revoke_token). `delete_group` writes NO audit even on success. No refusal anywhere in `routers/identity.ex` is audited (`grep -i audit routers/identity.ex` = 0 hits).
* Existing 409 precedent: `Response.conflict(conn, "group name already exists")` (R:500) -> `Error.conflict/1` (`api/error.ex:233`), type `.../conflict`, title "Conflict", status 409, `detail` chosen by the handler, `trace_id` from the conn. Existing 404 is `Response.not_found/1` (no detail argument, INV-5).

### 1.2 ISS-1033 - where each guard runs relative to the id cast and the fetch

Measured fact (test file header, `platform_escalation_guard_test.exs:457-464`): `Ecto.UUID.cast/1` accepts canonical, upper-case, mixed-case and the raw 16-byte binary (any 16-byte binary), but `Repo.get(Schema, raw16)` and `where: id == ^raw16` raise `Ecto.Query.CastError`. A non-UUID string raises the same. The CastError reaches the router unrescued = HTTP 500.

| Route | Guard | Order today (file:line) | Defect |
|---|---|---|---|
| `PATCH /users/:id` | `with_platform_admin_member_guard` (R:574) | `get_user` R:391 -> guard R:396 -> `do_patch` R:402 | Order already correct (fetch before guard; ISS-1033 as described is already true here). But `get_user` -> `Repo.get(User, id)` (I:334) raises on raw/malformed ids BEFORE the guard: 500 for everyone. |
| `POST /users/:id/status` | same | `get_user` R:433 -> guard R:438 -> `do_status_update` R:444 | Same. |
| `DELETE /groups/:id` | `with_platform_admin_group_guard` (R:552) | guard R:518 (casts, fail-closed false on `:error`, R:563-571) -> `delete_group` R:519 | Malformed/raw id for a non-guard-triggering request raises at I:676 (500). Bound group -> FK 500 (1.1). |
| `POST /groups/:id/members` | group guard | guard R:596 -> body validation R:602 -> `add_group_member` R:615 | `Repo.get(Group, group_id)` I:620 and `Repo.get(User, user_id)` I:625 raise (500) for malformed group id or malformed body `user_id`. The response echoes the request's spelling of both ids (`member_result_map`, R:618). |
| `DELETE /groups/:id/members/:user_id` | group guard | guard R:694 -> `remove_group_member` R:695 | `Repo.get(Group, ..)` I:766 and `m.user_id == ^user_id` I:771 raise (500) on malformed/raw ids. |
| `GET /groups/:id/members` (no guard) | - | `list_group_members` R:655 | `Repo.get(Group, ..)` I:720 raises (500). |
| `GET /users/:id` (no guard) | - | `get_user` R:357 | raises (500). |
| `DELETE /tokens/:id` | inline `token_carries_platform_admin?` (R:781) | guard R:781 (casts itself and fetches the token, false when unknown or uncastable, I:1552-1561) -> `revoke_token` R:784 | `Repo.get(ApiToken, token_id)` I:1578 raises (500) on raw/malformed id. Unknown well-formed id: guard false -> revoke -> 404 (correct bytes). |
| `POST /tokens` (body `user_id`) | role-NAME guard R:719 | guard -> validation -> `create_token` -> `Repo.get(User, user_id)` I:1406 | malformed body `user_id` raises (500). |
| `POST /roles` (body `group_id`) | H1/H2 NAME guards R:823-830 | guards -> `RoleRegistry.upsert_role` casts via `Ecto.UUID.cast/1` (role_registry.ex:113) | No 500: malformed -> 422 `invalid_group_id`, unknown -> 404 `group_not_found`. |

Conclusion for ISS-1033: the ordering the issue fears (guard before `get_user`) does NOT occur in the user routes today. What is missing is (a) the id-validity step in front of every fetch and guard (500 on malformed/raw ids, which also lets an attacker distinguish "castable" from "not castable" by status), and (b) tests pinning "guard-triggering request for a nonexistent id gives the plain unknown-id 404 bytes, nothing written".

## 2. Decisions

### D1. Status for a role-bound group: 409 Conflict, not 422 (ISS-1032)

409: the request is well-formed and authorised; it conflicts with the current state of the resource (in use by a role binding). 422 means "the request body failed validation" in this codebase (`Response.unprocessable` is used for field validation and `invalid_group_id`-type input errors). The duplicate-group-name case already uses 409 for a state conflict. Body: `Response.conflict(conn, "group is bound to a role")`, i.e. the standard problem document `{type: .../conflict, title: "Conflict", status: 409, detail: "group is bound to a role", trace_id}`. The detail is a fixed literal: no group id, role name, kind, constraint name, table name or Postgres text. It does not say WHICH role (a caller must not learn the binding's name from a delete).

### D2. How the bound case is detected: map the FK violation, no pre-check (ISS-1032)

`Identity.delete_group/2` keeps its single guarded `DELETE ... WHERE NOT EXISTS (member)` statement and wraps it so that a `Postgrex.Error` with `postgres.code == :foreign_key_violation` and `postgres.constraint == "tenant_role_group_id_fkey"` is returned as `{:error, :bound_to_role}`. Reasons: (1) the FK is the only authority that is race-safe: a check-then-delete pre-check can lose to a concurrent `upsert_role` binding the group between the check and the delete, and the FK would raise anyway, so a pre-check alone is insufficient and "both" only adds a second code path; (2) it leaves REQ-074 AC5 exactly as is: a group WITH members (bound or not) is still the unified `:not_found_or_has_members` 404 because the `NOT EXISTS` clause stops the statement before the FK is touched (`identity_test.exs:935`, "deleting a group with existing members returns the same 404 as a nonexistent group"). Only a MEMBERLESS bound group reaches the FK. Any other `Postgrex.Error` (and any other constraint name) is re-raised unchanged; a `group_members_*` FK violation from a concurrent member insert may also be mapped to `:not_found_or_has_members` (same answer the statement would have given a moment later) - ELIXIR-DEV decides if worth the line; the test in 4.1 (T-12) pins the constraint names against the real schema either way.
`delete_group` runs in no transaction of its own, so the failed statement aborts nothing. Precondition recorded in the `@doc`: do not call it inside a caller's open transaction (none does; the Ecto sandbox in tests uses a savepoint per statement, as the existing test at `:590` already relies on).

Any role binding counts, any `kind` (`:platform_role` and `:process_routing_role`): the FK is kind-blind and so is the rule.

### D3. Guard order on `DELETE /groups/:id` stays: platform guard first (ISS-1032)

A non-platform caller on the PLATFORM_ADMIN-bound group gets the fixed 403 `insufficient permissions` before delete is attempted (so never the 409, which would confirm "this group is bound"). The platform operator on the same group gets 409 (was 500). A non-platform caller on any OTHER bound group (for example the TENANT_ADMIN-bound group or a process-routing-bound group) gets 409.

### D4. No audit on refusal (ISS-1032)

The issue says audit the refusal "if the identity router audits other refusals". It does not (1.1), and `delete_group` is not audited even on success. Adding an audit entry to a refusal path would create the first refusal audit in the router and the first audited delete, which is a policy change beyond a LOW fix. Decision: no audit on the 409; recorded as residual R3.

### D5. Shared id cast, run FIRST, returning the canonical text (ISS-1033)

Order for EVERY identity route that takes an id:
authorise (the existing `authz_*` permission gate, unchanged) -> id validity/cast (`:error` -> `Response.not_found(conn)`) -> tenant-scoped fetch (404 if missing) -> guards -> body validation -> mutation.

New public function in `Letflow.Identity`: `cast_id(term()) :: {:ok, canonical_uuid_text :: String.t()} | :error`. It is a thin, documented wrapper over `Ecto.UUID.cast/1` (the SAME function the guards use, INV-10: guard and downstream lookup must decide on the same value) and it returns the CANONICAL lower-case hyphenated text. Every later step in the handler (guard, fetch, mutation, response echo) uses the canonical value, never the request spelling. Router private helper `with_cast_id(conn, raw_id, fun)` (or equivalent, ELIXIR-DEV's naming): on `:error` answers `Response.not_found(conn)` (byte-identical to an unknown id, INV-5), else calls `fun` with the canonical id.

Why accept-and-canonicalise instead of rejecting raw-byte and upper-case spellings: the PR 1 security tests require a non-platform caller to get 403 for EVERY cast-accepted spelling of the REAL platform group id (raw 16 bytes, upper-case, mixed-case, percent-encoded). If a strict cast rejected raw bytes with 404 first, the raw-byte spelling of the real bound group would answer 404 instead of 403 and those tests (and the guarantee behind them) would break. Canonicalising first makes guard and mutation operate on one value, which structurally closes the spelling gap (a string compare can never be wrong). Consequence, intended and tested: a raw-byte or upper-case spelling of a REAL unguarded id now resolves exactly as the canonical spelling does (was 500 for raw bytes); for an UNKNOWN id every spelling is the one zero-detail 404. Any 16-byte string is a valid raw spelling (it maps to the UUID with those bytes); that gives no access beyond what the canonical id has and the guard already assumes it.

Per route family (this is the decision requested):

| Family | Id source | Cast result `:error` | After a good cast |
|---|---|---|---|
| Groups: `DELETE /groups/:id`, `GET`/`POST /groups/:id/members`, `DELETE /groups/:id/members/:user_id` (group id) | path | 404 (same bytes as unknown group) | platform group guard on the canonical id (unchanged semantics), then the handler; unknown well-formed group -> existing 404 |
| Group members, user id: `DELETE .../members/:user_id` | path | 404 | existing idempotent behaviour unchanged: an unknown well-formed user id on an existing group is still 204 (the intent "not a member" is satisfied; REQ-074 test `identity_test.exs:877`). A malformed user id is 404 (not a resource at all). The cast runs BEFORE the group guard, like every cast. |
| Group members, user id: `POST .../members` body `user_id`/`user_ids[0]` | body | 404, same bytes as the unknown-user 404 (`:user_not_found`) | cast runs inside the add path, after the group guard and body validation (so "403 wins over 422" is unchanged); group id is cast first |
| Users: `GET`/`PATCH /users/:id`, `POST /users/:id/status` | path | 404 | existing order `get_user` -> guard -> mutation is kept (it is already the required order); `get_user` and the member guard receive the canonical id; no guard code or audit/directory write runs for a nonexistent user |
| Tokens: `DELETE /tokens/:id` | path | 404 | `token_carries_platform_admin?` then `revoke_token`, both on the canonical id; unknown token -> guard false -> existing 404 |
| Tokens: `POST /tokens` body `user_id` | body | 404 `user_not_found` bytes | role-name guard (403) stays before everything (see D6) |
| Roles: `POST /roles` body `group_id` | body | UNCHANGED: 422 `invalid_group_id` (already castable-checked in `RoleRegistry.upsert_role/4`, no 500); unknown group 404 | NAME guards H1/H2 unchanged |

`PATCH /groups/:id` does not exist in this router; nothing to do.

### D6. Which guards are "target-independent" and stay first (ISS-1033)

The `POST /tokens` PLATFORM_ADMIN-name guard and the `POST /roles` H1/H2 name guards decide from the request's role NAME and the caller's recomputed scope only; they never look at the target user or group. Their 403 is the same for existing, nonexistent and malformed target ids, so they reveal nothing about existence and do not run "on a nonexistent user" in any meaningful sense (no read, no write). They stay first. A test pins that the 403 is byte-identical across target ids. (If REVIEWER wants literal fetch-before-guard here too, it changes PR 1's "403 wins over 422" contract; flagged as OQ-2.)

### D7. Existence oracle on the guarded routes: acceptable, reasoned

* Group routes: the guard is a comparison of the (canonical) request id with the PLATFORM_ADMIN binding id; no fetch precedes it. A non-platform caller therefore sees 403 only for that one id and 404/other for everything else. The platform group id is already returned by `GET /roles` (`group_id` of every binding; `role_map`, R:959) and `GET /groups` lists every group id for the same callers, so no new information; the bound group necessarily exists (FK), so "403" never means "exists but you may not see it" for an unknown id. No fetch-before-guard is added on the group routes (it would add a query and change 422-vs-404 for unknown groups with bad bodies for no confidentiality gain).
* Token route: the guard answers 403 only for an existing token that carries PLATFORM_ADMIN, 404 for unknown. The caller holds `:TokensManage` and `GET /tokens` lists every token id with roles in the tenant, so nothing is disclosed. Cross-tenant ids never match (tenant-scoped prefix), so a foreign token id is the plain 404.
* User routes: fetch precedes the guard, so a nonexistent (or other-tenant) user id never reaches a guard: 404. The 403 for an existing platform-operator user is reachable only after the tenant-scoped fetch succeeded, and `GET /users` lists those users for the same callers.

## 3. Files to change (ELIXIR-DEV)

1. `lib/letflow/identity.ex`
   * ADD `@spec cast_id(term()) :: {:ok, String.t()} | :error` with `@doc` (accepts what `Ecto.UUID.cast/1` accepts, returns canonical text, same function as the router guards, INV-10).
   * CHANGE `delete_group/2` (I:668-684): spec becomes `:ok | {:error, :not_found_or_has_members} | {:error, :bound_to_role}`; map the single named FK violation (D2); update the `@doc` (bound -> `:bound_to_role`, kind-blind; members -> unchanged unified atom; no-open-transaction precondition).
   * No other domain function changes behaviour (they all receive canonical ids from the router). Optional defence in depth, NOT in this PR: make `get_user`, `add_group_member`, `remove_group_member`, `list_group_members`, `revoke_token`, `create_token` total for uncastable ids (OQ-3).
2. `lib/letflow/routers/identity.ex`
   * ADD the private `with_cast_id` helper; wrap `handle_get` (R:356), `handle_patch` (R:390), `handle_status_update` (R:432), `handle_delete_group` (R:517), `handle_add_member` (R:595; also cast body `user_id` in `do_add_member` -> 404), `handle_list_group_members` (R:648), `handle_remove_member` (R:693; cast BOTH ids), `handle_revoke_token` (R:778), `do_create_token` (R:727; cast `user_id` -> 404). Guards and domain calls take the canonical ids. `member_result_map` therefore echoes canonical ids.
   * `handle_delete_group`: add the `{:error, :bound_to_role} -> Response.conflict(conn, "group is bound to a role")` clause next to the unchanged 404 clause.
   * Guards and `platform_admin_group?/2` keep their code (their `Ecto.UUID.cast` calls now see an already-canonical id; leave them: defence in depth, fail closed).
   * Update the moduledoc route list (R:22-33) with the 409 and the id-first order.
3. Tests (section 4): new `test/letflow/api/identity_id_hardening_test.exs`; edit `test/letflow/api/platform_escalation_guard_test.exs` and `test/letflow/routers/identity_test.exs`.
4. Docs: `docs/issues/ISS-1032.yaml`, `docs/issues/ISS-1033.yaml` (section 5). No migration, no schema change, no new dependency, no new route, no change to `docs/roles.md`. `docs/frontend/requirements/ADM-UI-05.md` / `web/` may later surface the 409; not in this PR (R4).

No 0046 note: neither change touches a decision (no permission, scope, role or binding semantics move; 0046 D3 binding condition is not involved, unlike ISS-1026). The design file and the two issue files are the record. (Decision; ORCH may overrule, OQ-4.)

## 4. Tests (exact names)

### 4.1 New file `test/letflow/api/identity_id_hardening_test.exs`, module `Letflow.Api.IdentityIdHardeningTest`

`use Letflow.DataCase, async: false` (platform pin is VM-global); same fixture as `PlatformEscalationGuardTest` (`Fixture.three_tenants!/0`, `Fixture.pin!`, `Fixture.router_conn/5`, callers `["TENANT_ADMIN"]` of P and `["PLATFORM_ADMIN"]` operator of P; direct dispatch into `Letflow.Routers.Identity`). Two tenants are not needed (the cast/fetch is tenant-prefix scoped and already covered by REQ-074 cross-tenant tests). Reference-404 helper: the 404 body of the same caller requesting a plain unknown canonical uuid on the same route (the fixture's `trace_id` is a fixed assign, so byte comparison is exact). Spelling helper: the file reuses the escalation test's table (canonical, upper-case, mixed-case, raw 16 bytes upper/lower pct, fully pct-encoded) via a small copy or a shared support function (ELIXIR-DEV: extract to `test/support/` only if it avoids duplicating more than ~15 lines). Malformed set: `"not-a-uuid"`, `"%20" <> uuid`, `uuid <> "%20"`, hyphenless, truncated to 35 chars, doubled, 17 raw bytes, empty-looking `"x"`.

describe "ISS-1032: DELETE /groups/:id on a role-bound group"
* T-01 "operator on the PLATFORM_ADMIN-bound group (memberless): 409 with the fixed problem body, group and binding intact"
* T-02 "TENANT_ADMIN on a group bound to a platform_role other than PLATFORM_ADMIN: 409"
* T-03 "TENANT_ADMIN on a group bound to a process_routing_role: 409 (any kind counts)"
* T-04 "the 409 body is exactly status 409, type ending /conflict, title Conflict, detail 'group is bound to a role', and contains no group id, role name, kind, 'tenant_role', 'fkey', 'Postgrex' or stack text" (assert the decoded body's keys are the standard problem keys and refute each forbidden substring)
* T-05 "TENANT_ADMIN of P on the PLATFORM_ADMIN-bound group still gets the fixed 403 (never 409) for all six id spellings, group intact" (platform guard first, D3)
* T-06 "an unbound empty group: 204 and the row is gone (unchanged)"
* T-07 "an unbound group with a member: the same 404 bytes as a nonexistent group, row survives (unchanged, REQ-074 AC5)"
* T-08 "a bound group WITH a member: the same unified 404 as a nonexistent group, nothing deleted (the NOT EXISTS clause stops before the FK; documents D2)"
* T-09 "a group whose binding was moved to another group deletes (204)"
* T-10 "a refused delete writes no audit row and changes no groups, group_members or tenant_role row" (row counts before/after incl. the audit table of the tenant)
* T-11 "Identity.delete_group/2 returns {:error, :bound_to_role} for a memberless bound group and does not raise"
* T-12 "the FK constraint name the mapping depends on is real: a raw delete of a bound group raises Postgrex.Error with code :foreign_key_violation and constraint 'tenant_role_group_id_fkey'" (guards against a rename silently turning the 409 back into a 500)

describe "ISS-1033: id cast helper"
* T-13 "Identity.cast_id/1 returns the canonical lower-case text for canonical, upper-case, mixed-case and raw 16-byte input"
* T-14 "Identity.cast_id/1 returns :error for malformed strings, a 17-byte binary, nil, an integer and a map"

describe "ISS-1033: users (PATCH /users/:id, POST /users/:id/status, GET /users/:id)"
* T-15 "PATCH: a nonexistent id answers the plain unknown-id 404 bytes for every spelling and every malformed variant, for the TENANT_ADMIN of P and for the operator"
* T-16 "STATUS: same as T-15"
* T-17 "GET /users/:id: raw-byte and malformed ids answer the same 404 (was 500)"
* T-18 "PATCH and STATUS on a nonexistent id write nothing: no user row, no audit row, no login-directory change"
* T-19 "guards unchanged for an existing operator user: every spelling of the real id (incl. both raw-byte forms) is the fixed 403 for the TENANT_ADMIN, state unchanged; the operator control reaches 200 for EVERY spelling" (replaces the CastError-tolerant escalation tests, see 4.2)
* T-20 "an existing ordinary member is still 2xx for the TENANT_ADMIN for every spelling" (guard not over-broad)

describe "ISS-1033: groups and group members"
* T-21 "DELETE /groups/:id: nonexistent and malformed ids answer the plain unknown-group 404 bytes for every variant, TENANT_ADMIN and operator"
* T-22 "POST /groups/:id/members: nonexistent and malformed group ids answer the unknown-group 404 bytes (valid body)"
* T-23 "POST /groups/:id/members: a malformed, raw-byte-unknown or nonexistent body user_id answers the same 404 bytes as an unknown user; nothing inserted"
* T-24 "DELETE /groups/:id/members/:user_id: nonexistent and malformed GROUP ids answer the unknown-group 404 bytes"
* T-25 "DELETE /groups/:id/members/:user_id: a malformed user id on a real group is 404; an unknown well-formed user id is still 204 (idempotent, unchanged)"
* T-26 "DELETE /groups/:id/members/:user_id on the PLATFORM_ADMIN-bound group by the TENANT_ADMIN: 403 for every spelling of the group id and of the user id (cast succeeds, guard runs), member kept; a malformed user id is 404 (cast before guard)"
* T-27 "GET /groups/:id/members: nonexistent and malformed group ids answer the unknown-group 404 bytes"
* T-28 "the guard-triggering caller (TENANT_ADMIN of P) gets 404 for an UNKNOWN group id and 403 for the real PLATFORM_ADMIN-bound group id on add, remove and delete (D7); the bound group id is present in the GET /roles listing of the same caller" (pins the acceptable oracle)
* T-29 "POST /groups/:id/members with an upper-case group id and user id answers with the canonical ids in the response body"
* T-30 "raw-byte and upper-case spellings of a REAL unguarded group resolve like the canonical spelling: add 201, list 200, remove 204, delete 204" (intended behaviour change)

describe "ISS-1033: tokens and roles"
* T-31 "DELETE /tokens/:id: nonexistent and malformed ids answer the plain unknown-token 404 bytes for the TENANT_ADMIN of P (guard-triggering caller) and the operator; no token row changed, no audit row"
* T-32 "DELETE /tokens/:id: every spelling of a REAL PLATFORM_ADMIN token is 403 for the TENANT_ADMIN, unrevoked; the operator control revokes it for EVERY spelling (200)"
* T-33 "POST /tokens: a malformed or nonexistent user_id answers the unknown-user 404 bytes; a PLATFORM_ADMIN-role request by the TENANT_ADMIN is the SAME 403 for an existing, a nonexistent and a malformed user_id (target-independent guard, D6)"
* T-34 "POST /roles: the PLATFORM_ADMIN-name and built-in-name 403s are identical for an existing, an unknown and a malformed group_id; for an ordinary name a malformed group_id is still 422 invalid_group_id and an unknown one 404 (unchanged)"

### 4.2 Edits to existing tests (expectations that follow from the change, none weakened)

`test/letflow/api/platform_escalation_guard_test.exs`
* `:430-434` (CONTROL operator deletes): the expected `{:raised, Postgrex.Error ...}` becomes a 409 response with the fixed body (group still exists).
* `:583-609` ("DELETE GROUP: every spelling ..."): the operator control now expects 409 for every spelling (no `:raised` clause, no `:cast_error` outcome); all six spellings must resolve.
* `@resolving` (`:466-471`) gains the two raw-byte labels; `operator_outcome/3` and `assert_resolving_spellings_reached/1` lose the `:cast_error` tolerance (a CastError is now a failure); `assert_not_a_write/2` (`:703-708`) loses the `%Ecto.Query.CastError{}` clause; `try_call/5`'s raise-unwrapping may stay for reporting.
* `:611-636` (non-castable spellings): `{:raised, CastError}` is no longer allowed; the answer must be 404 for the admin.
* The user/token/group raw-byte tests (`:639-753`) then pass with the stricter helpers: this is T-19/T-32's safety net; keep them and keep T-19/T-32 as the focused assertions, or fold them (ELIXIR-DEV's call; test count must not drop).

`test/letflow/routers/identity_test.exs`: no edit expected (`:766` empty-group 204 and `:935` has-members 404 stay as they are); add nothing there, new coverage lives in the new file.

## 5. Issue files (DOC-UPDATER / ELIXIR-DEV with the PR)

Follow the `ISS-1031.yaml` shape (fields id, title, discovered_by, discovered_in_run, discovered_at, severity LOW, priority P4, failure_class defect, owner ELIXIR-DEV, description, fix_direction, acceptance_criteria, affected_files, queue_ref, github_ref, status resolved, resolved_in_run, resolved_at, resolution, regression_test).

* `docs/issues/ISS-1032.yaml`: `queue_ref: Q-1014  # the queue allocated issue_ref ISS-1014, which collides with an existing local file (ISS-1014 is an unrelated issue); local filename ISS-1032 (next free on origin/main)`; `github_ref: GH-2317`; `status: resolved`. Acceptance criteria copied from GH #2317. `regression_test: test/letflow/api/identity_id_hardening_test.exs`. Resolution: memberless role-bound group delete answers 409 `group is bound to a role` (stable body, any role kind, FK violation mapped in `Identity.delete_group/2`), platform guard first, unbound and has-members behaviour unchanged, no refusal audit (router audits no refusals).
* `docs/issues/ISS-1033.yaml`: `queue_ref: Q-1015  # the queue allocated issue_ref ISS-1015, which collides with an existing local file (ISS-1015 is an unrelated issue); local filename ISS-1033`; `github_ref: GH-2318`; `status: resolved`. Resolution: every identity route that takes an id casts it first (`Identity.cast_id/1`), a malformed or unknown id is the one zero-detail 404, guards and fetches use the canonical id; user routes already fetched before guarding (verified, R:391/433) and are now pinned by tests; target-independent name guards documented.
* ORCH verifies that the next free local numbers are still 1032 and 1033 on origin/main at PR time (the ISS-1036 file records that 1032-1035 were free when 1036 was assigned).

## 6. Invariants and acceptance mapping

| Criterion | Element |
|---|---|
| 1032-AC1 bound delete is a clean 4xx with a stable body, never 500, group not deleted | D1, D2; `delete_group/2` `:bound_to_role`; router clause; T-01..T-04, T-11, T-12 |
| 1032-AC2 unbound delete as before | T-06, T-07, T-08, T-09 |
| 1032-AC3 tests for bound and unbound; no internal detail (INV-2/INV-4); SECURITY-REVIEWER verdict | T-01..T-12; T-04 is the no-detail assertion; verdict is a pipeline gate |
| 1032 audit-on-refusal "if the router audits others" | D4 (it does not), T-10 |
| 1033-AC1 in every guarded id route the (tenant-scoped) fetch/cast precedes guards; nonexistent -> zero-detail 404 | section 1.2 table, D5, D6, section 3 router list; T-15, T-16, T-21, T-22, T-24, T-31, T-33 |
| 1033-AC2 per guarded route: guard-triggering request for a nonexistent id = same 404 bytes as a plain unknown id, no audit/side effect | T-15, T-16, T-18, T-21, T-22, T-24, T-28, T-31 |
| 1033-AC3 guards behave as before for existing users; SECURITY-REVIEWER verdict | T-19, T-20, T-26, T-32, edits in 4.2 |
| INV-5 (cross-tenant and unknown are the same bytes) | tenant-prefixed fetch unchanged; malformed = unknown bytes |
| INV-10 (guard and downstream lookup decide on the same value) | D5 canonical id passed to guard, fetch, mutation and echo |
| INV-4 (no internal detail) | fixed `detail` literals; cast failure carries no text |

## 7. Open questions (none block ELIXIR-DEV; each has a stated default)

* OQ-1. Raw-byte and upper-case spellings of a REAL unguarded id now RESOLVE (D5) instead of 500. Default: accept and canonicalise (required to keep the PR 1 403-for-every-spelling guarantee). The alternative (strict reject, 404) is only possible if the group/user/token guards keep a lenient pre-cast ahead of a strict one, which is more code and more ways to diverge. REVIEWER / SECURITY-REVIEWER to confirm.
* OQ-2. `POST /tokens` and `POST /roles` name guards stay before any target fetch (D6, target-independent, so no oracle). Default: leave. Changing it would make a nonexistent user/group 404 beat the 403, altering PR 1's "403 wins" tests.
* OQ-3. Make the domain functions total for uncastable ids (defence in depth for non-router callers: mix tasks, other modules). Default: NOT in this PR (a router-level cast covers every HTTP path; the domain callers outside the router pass ids they generated).
* OQ-4. A dated 0046 note. Default: none (no decision changes). ORCH may add one.
* OQ-5. Bound group WITH members stays the unified 404 (D2, T-08), so the operator deleting the memberless-vs-populated platform group sees 409 vs 404. Default: keep (REQ-074 AC5 intent). A "bound -> 409 regardless of members" pre-check is a small follow-up if REVIEWER prefers it.

## 8. Residuals (tracked in the issue files, no new queue entry proposed unless ORCH wants one)

* R1. Domain functions still raise on uncastable ids when called outside the router (OQ-3).
* R2. 422-vs-404 for `POST /groups/:id/members` with an unknown well-formed group and an invalid body stays 422 (guard, then validation, then lookup); not an oracle between unknown and bound groups beyond D7.
* R3. Role-bound group refusals and group deletes are not audited (D4); a policy decision for a future audit-coverage requirement.
* R4. `web/` does not yet render the new 409 for group delete (generic error handling applies); FRONTEND-DEV may add a message under `ADM-UI-05`.
* R5. A bound group with members answers the pre-existing unified 404 (OQ-5).
