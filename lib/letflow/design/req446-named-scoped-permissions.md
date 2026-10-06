# REQ-446 / Q-963 / GH #2234 -- Named, scoped permissions for the formerly `:Unknown` routes (audit and remainder)

Status: DESIGN (CODE-DESIGNER), awaiting CODE-DESIGN-VALIDATOR, SECURITY-REVIEWER (mandatory: tenant-data path), REVIEWER.
Branch: `feat/REQ-446-named-permissions`, cut from `origin/main` dc005b51 (ISS-0993 A1 342c5095 and A2 ccbf994e merged).
Governing documents: `docs/requirements.yaml` REQ-446 (line 33688, AMENDED 2026-10-06), `docs/migration/decisions/0046-admin-scopes-and-role-charter.md` (D2, D3),
`lib/letflow/design/iss0993-platform-scope-separation.md` (sections 5-9, 11, 22), `test/specs/ISS-0993-A2.md`.
Method: every row below was established by reading the merged code and tests on this branch. No test was run for this design (design step); the
implementation PR runs the full gate set (AC7).

Wording rule: signatures, names and citations only. No implementation code.

## 0. Verdict (read this first)

**REQ-446 now needs ONE small `lib/` change** (revised after the CODE-DESIGN-VALIDATOR round and the letflow-9a ruling, sections 4a and 4b): response
shaping in `lib/letflow/routers/promotions.ex` on BOTH `GET /promotions/platform-events` (4a: render path and hand-built event map) and `GET /promotions/:id/context` (4b: `review_context_map/1`), a few lines each over one shared private walk, so
that a caller who is not a platform-tenant operator never receives a tenant id other than its own. Everything else is unchanged from the audit:
ISS-0993 A1+A2 shipped the three permissions, their keys, the scope table, the router macros, the ownership checks, the checker and the moduledocs.
The other remaining work is tests (a cross-tenant denial table with fully specified bodies and control statuses, a grid addition, a response-shaping
test group, a hardening demonstration), stale-comment clean-up in tests, the documentation CORRECTION (0046 appended note and `docs/roles.md`), and
the status flip. No migration, no new permission, no new route, no `web/` change. SECURITY-REVIEWER gates the `lib/` change (INV-2, INV-10).

Surprises recorded for the reviewer (details in section 7):

1. The requirement says "thirteen routes"; the merged routers declare **twelve** formerly-`:Unknown` routes (10 in `promotions.ex`, 1 in `definitions.ex`,
   1 in `tenants.ex`). The thirteenth in the ISS-0993 count is `PATCH /tenant/settings`, which was a re-key from `:TenantsManage`, never `:Unknown`.
2. 0046 D3 / `docs/roles.md:67` expect a separate platform-scope permission for `GET /promotions/platform-events`; the merged code folds it into
   tenant-scope `:PromotionsRead` (own-schema read). RULED (letflow-9a): it stays tenant scope; the 0046 D3 table row is CORRECTED by an appended note
   and `docs/roles.md` is updated (section 4, D-1 RESOLVED). Condition attached to the ruling: the response is shaped so that no foreign tenant id is
   returned to a non-operator (sections 4a and 4b, the `lib/` change: platform-events and `GET /promotions/:id/context`).
3. `Letflow.PlatformTenant.cross_tenant_promotion_operator_only?/0` (platform_tenant.ex:47-49) is documented as "flip to restore the legacy allow-all
   pairing", but it is consumed only by `PromotionAccess.checker_for/1` (promotion_access.ex:29); `TenantTarget` (tenant_target.ex:31-39) never reads
   it, so flipping it does not restore anything at the route level. Dead-ish switch, not exploitable.
4. `approve` and `reject` do not re-check the stored source/target tenant ids of a review (only `apply` and `run-assertions` do, promotions.ex:650-664).
   They perform a state transition on a review row in the caller's own schema and read no other tenant's data; recorded as a residual (section 7).
5. G2 in `platform_scope_inventory_test.exs` and the older `authorization_enforcement_test.exs` already satisfy build item 4, but `:Unknown` as an
   explicit literal key is never demonstrated to be caught (only the plain-macro form is). One small test-only addition closes it (section 5, T-4).

## 1. Audit of the five BUILDS items

| # | Item | Status | Evidence (file:line, all on this branch) | Missing |
|---|---|---|---|---|
| 1 | New core permissions `:PromotionsRead`, `:PromotionsManage`, `:DefinitionsRollback`; read/write split kept; `endpoint_policy_key/2` and `required_permission/1` clauses; routes on `authz_*` macros | DONE | Types `authorization.ex:311-313` and `:367-369`; list `authorization.ex:424-426`; `endpoint_policy_key/2` clauses `authorization.ex:803-828` (10 promotion pairs, rollback, promote); `required_permission/1` identity clauses `authorization.ex:1162-1164`; routers: `routers/promotions.ex:195-241` (10 `authz_*` routes: `:PromotionsManage` x6, `:PromotionsRead` x4), `routers/definitions.ex:330` (`:DefinitionsRollback`), `routers/tenants.ex:222` (`:PromotionsManage`). Names kept as proposed. | nothing |
| 2a | Scope: all three TENANT scope | DONE | Scope table `authorization.ex:434-442` (only `:TenantsManage` and `:PlatformServicesManage` are platform; the three new atoms are tenant). Pinned by `test/letflow/api/platform_scope_authorization_test.exs:80-91` and `:292-317`, `platform_scope_inventory_test.exs:375-398` (G2 c), `:460-501` (G3). | nothing |
| 2b | Source-tenant ownership of the promote route proven or added | DONE (added by A2) | `routers/tenants.ex:451` calls `TenantTarget.authorize_target_tenant/2` BEFORE `do_promote` (`tenants.ex:456-471`); helper `api/tenant_target.ex:31-39` (rule 1 operator, rule 2 case-insensitive equality with `auth_context.tenant_id` at `:43-51`, else `{:error, :not_found}` mapped to `Response.not_found/1` at `tenants.ex:452`); target is `auth_context.tenant_id` (`tenants.ex:458`); checker `definitions/promotion_access.ex:24-32`. Tests: `test/letflow/api/promote_source_tenant_test.exs:102-189` (a)-(d), `promotion_scope_test.exs:269-302`. | nothing |
| 2c | `GET /promotions/platform-events`: other tenants' rows? | DONE as tenant scope (no other tenant's rows) | Handler `routers/promotions.ex:846-873` takes `prefix` only from `conn.assigns.scoped_opts` (`:850`, `:856`); `EventStore.list_platform_events/1` `event_store.ex:1110-1123` queries the sentinel instance with `Repo.all(prefix: prefix)`. `scoped_opts` is built from `auth_context.tenant_id` in `plugs/authorize.ex:103-132`. Tests: `promotion_scope_test.exs:574-596`, `routers/promotions_test.exs:156`. | The 0046 D3 / roles.md:67 text that says "platform scope, own permission" is contradicted by the code: RULED, CORRECTION note and roles.md edit (D-1, section 4 and 6). The payload names other tenants by id: closed by the response shaping of section 4a (the one `lib/` change, sections 4a and 4b) and its tests T-7 and T-8 (T-8 for the sibling `/context` route). |
| 3 | Grants: PLATFORM_ADMIN only through the catch-all; no other role gains the three | DONE | `platform_scope_authorization_test.exs:126-137` (every non-`PLATFORM_ADMIN` role refused the five new permissions by `role_allows?/2`), `:239-249` (`evaluate_access/2` grid: all five other roles `:Deny403`, in and out of the platform tenant). | nothing |
| 4 | No route under `ApiPipeline` resolves to `:Unknown` except a router's own `match _`; test enumerates compiled routes and fails on a route without a key | DONE with one hardening gap | G0 compile-time: `authorized_router.ex:67-96` removes the plain verb macros; test `platform_scope_inventory_test.exs:101-174` (seven plain verbs fail to compile). G1 source scan with a literal bad snippet: `:180-317` (snippet `:239-266`). G2 compiled-route table: `:323-430`, (a) `:351-361` refutes `:Unknown` on every `__authz_routes__/0` entry across all discovered routers; mounts parsed from `api_pipeline.ex` (`:53-71`). Per-router declared-vs-`endpoint_policy_key/2`: `authorization_enforcement_test.exs:179-219`; module routes `:237-263`. Runtime default `:Unknown` is denied for everyone: `authorize.ex:118-120`, `authorization.ex:1057-1062`, `plugs/authorize_test.exs:130`. | An explicit `authz_get "/x", :Unknown` compiles (macro accepts any term, `authorized_router.ex:108-126`) and is caught only by G2 (a), whose predicate is inline and never demonstrated against a bad fixture. Test T-4 (section 5). |
| 5 | Moduledocs that describe the `:Unknown` decision; core permission count in `authorization_test.exs` | DONE for lib/; stale test comments remain | `routers/promotions.ex:61-79` and `:142-152`, `routers/tenants.ex:70-93`, `routers/definitions.ex:20-23` rewritten; `authorization.ex:449-473` states "forty" (no hardcoded count in the test: `authorization_test.exs:35-76` literal list of 40, `:78-80`, `:391-430` spells the live count and finds it in the `@doc`); `docs/guides/backend_developer_guide.md:186-203`. | Stale prose in tests (section 5, T-6): `authorization_enforcement_test.exs:25-36` and `:85-93`; `platform_scope_authorization_test.exs:12-13`; `authorization_test.exs:33-34` ("34th/last entry"); `plugs/api_pipeline_integration_test.exs:105-106`; `plugs/admission_pipeline_test.exs:157-159`. |

## 2. Audit of the ten acceptance criteria

| AC | Criterion (short) | Status | Evidence | Missing |
|---|---|---|---|---|
| 1 | table-driven `endpoint_policy_key/2` for every (method,path) pair, none `:Unknown` | DONE | `platform_scope_authorization_test.exs:292-317` (13 pairs: the 12 plus `PATCH /tenant/settings`; each asserts the exact non-`:Unknown` key and tenant scope of its permission); also `req077_promotion_pipeline_test.exs:1160-1181`, `platform_scope_inventory_test.exs:406-429`. | nothing |
| 2 | PLATFORM_ADMIN of the platform tenant gets the same status codes as before; no assertion weakened or deleted | DONE (verify at gate) | `promotion_scope_test.exs:166-180` (reaches handler, not 403, for A admin, P admin, pin unset on all 12 rows); `git diff 342c5095^ HEAD -- test/letflow/routers/req077_promotion_pipeline_test.exs`: the only deleted assertions are the three `:Unknown` pins that A2 flipped (`:Unknown` is now denied for everyone). | Run the full suite in the PR and quote it; no new work. |
| 3 | PROCESS_DESIGNER, PROCESS_OPERATOR, TASK_WORKER, CANDIDATE, AGENT_RUNNER get 403 on all routes | PARTIAL | Pure level covers all five: `platform_scope_authorization_test.exs:239-249`. Router level covers only three roles plus no role: `promotion_scope_test.exs:182-189` (roles list at `:184`). | HTTP/router-level 403 for `CANDIDATE` and `AGENT_RUNNER` on all 12 rows. Test T-2. |
| 4 | design states with file:line whether the promote route proves source ownership; two-tenant test, unrelated source yields 404 byte-identical to nonexistent | DONE (code and test); statement is in section 4 | See item 2b. `promote_source_tenant_test.exs:125-189`: other existing tenant versus random UUID, same status/body/content-type, no query touches B; malformed ids; operator control. | nothing (section 4 is the required statement) |
| 5 | a test fails when a route under `ApiPipeline` is declared without a policy key, demonstrated once | DONE for the plain-macro form; demonstration missing for the explicit-`:Unknown` form | Item 4 above. | Test T-4. |
| 6 | every new permission has a scope in the scope table; scope-completeness test passes | DONE (verify at gate) | `authorization.ex:434-442`; `platform_scope_authorization_test.exs:80-91`; `platform_scope_inventory_test.exs:375-398`. | Gate run only. |
| 7 | `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix test`, `mix letflow.check_boundaries` with real output; SECURITY-REVIEWER verdict | MISSING (process) | Not run in the design step. | Run all four on the implementation branch and quote; SECURITY-REVIEWER verdict recorded in the run report. |
| 8 | cross-tenant denial, admin of A with B's identifiers on every re-keyed route, byte-identical to a nowhere identifier, no row of B changes, one table-driven test naming each route | PARTIAL | Covered, but spread over several files and not as one named table: body ids on `POST /promotions` and `/plan` (foreign source, foreign target, both, nonexistent): `promotion_scope_test.exs:193-251` (full observable bytes, no B query, no review written); promote route: `promotion_scope_test.exs:269-302`, `promote_source_tenant_test.exs:125-189`; stored foreign ids on apply and run-assertions: `promotion_scope_test.exs:305-413`; B's review id on context, approve, reject, apply: `req077_promotion_pipeline_test.exs:917-998` (compares decoded bodies minus trace, not raw bytes; no "B row unchanged" assertion; caller is B-scoped fixture, not an admin of A with B's id). | (a) `GET /promotions/:id` (R3) with B's review id: no test. (b) `POST /promotions/:review_id/run-assertions` with B's review id as the path id (as opposed to a stored foreign tenant id): no test. (c) `POST /definitions/:process_key/rollback` with a process key that exists only in B: no test anywhere (`rollback_test.exs` and `req077_promotion_pipeline_test.exs:689-` only cover own tenant). (d) the two GET list routes with rows present in B inside the same table. (e) one table that names every re-keyed route and compares raw bytes plus a before/after snapshot of B. Test T-1. |
| 9 | list routes return no row of another tenant, or are platform scope; design states which, per route, with file:line | DONE in code and tests; statement in section 4 | `GET /promotions`: `routers/promotions.ex:941-958` -> `PromotionReviewStore.list_reviews(filters, opts)` with `scoped_opts`; test `routers/promotions_test.exs:449-471` (A and B rows never cross). `GET /promotions/platform-events`: item 2c; tests `promotion_scope_test.exs:574-596`, `promotions_test.exs:156`. | Same two routes folded into the T-1 table (rows 11, 12). Platform-events foreign-id shaping: sections 4a and 4b, tests T-7 and T-8. D-1 documentation correction: section 6a. |
| 10 | every tenant-scope promotion permission justified by file:line own-tenant proof of the SCOPE RULE | DONE in code; the justification is section 4 of this design | Section 4. | nothing beyond this document |

## 3. Counts and the "13" discrepancy

Routes the requirement lists: `promotions.ex` 10 + `definitions.ex` 1 + `tenants.ex` 1 = **12** (`promotions.ex:195-241`, `definitions.ex:330`,
`tenants.ex:222`). `iss0993-platform-scope-separation.md` section 7.2 says the same ("12 + 1 = 13", the 13th being the `/tenant/settings` re-key).
All requirement text that says thirteen means these 12 plus `PATCH /tenant/settings`. Tests for AC1 already use 13 pairs; tests for AC3 and AC8 use the 12
`:Unknown`-origin routes (`PATCH /tenant/settings` is covered by `tenant_settings_scope_test.exs`). The implementation PR description states the 12/13
reading once; the requirement entry is not edited by this PR (DOC-UPDATER flips status only).

## 4. SCOPE RULE decision per permission (the design statement required by AC4, AC9, AC10)

The rule (amended REQ-446): a promotion permission is tenant scope only for a route where the code proves, before any read of another tenant's data,
that every tenant the request names is the caller's own database-resolved tenant (non-operator callers: named tenant id equals `auth_context.tenant_id`,
otherwise the zero-detail 404 of a nonexistent id). `auth_context.tenant_id` is resolved from the verified realm or the token's own schema in
`AuthPipeline` (iss0993 design section 10, fact 1), never from the request. No pairing of a test tenant with a production tenant exists in the data
model and this entry does not invent one.

| Permission | Route | Tenant named by the request | Own-tenant proof (file:line) | Scope |
|---|---|---|---|---|
| `:PromotionsManage` | `POST /promotions` | body `source_tenant_id`, `target_tenant_id` | `routers/promotions.ex:285` -> `tenants_authorized?/2` `:296-298` -> `TenantTarget.authorize_target_tenant/2` `tenant_target.ex:31-39`; denial `Response.not_found` at `promotions.ex:288`, before `PromotionPlan.compute_promotion_plan` (`:301`). Checker `PromotionAccess.checker_for/1` `promotion_access.ex:24-32` is the second line of defence. | tenant |
| `:PromotionsManage` | `POST /promotions/plan` | body ids | `promotions.ex:406`, 404 at `:418`, before `compute_promotion_plan` (`:408`) | tenant |
| `:PromotionsManage` | `POST /promotions/:id/approve`, `/reject` | none (review id only; review looked up in the caller's schema) | no tenant is named; lookup uses `scoped_opts` (`promotions.ex:559`, `:596`); a review of another tenant is absent from the caller's schema (moduledoc `promotions.ex:81-93`). No stored-id re-check: state transition on an own-schema row, no foreign data read (residual R-3). | tenant |
| `:PromotionsManage` | `POST /promotions/:id/apply` | stored `source_tenant_id`, `target_tenant_id` of the review | `promotions.ex:626` -> `stored_tenants_authorized?/3` `:650-664` (a stored foreign id gives the nonexistent-review 404 at `:640`), before `Promotion.apply_review` (`:628`) | tenant |
| `:PromotionsManage` | `POST /promotions/:review_id/run-assertions` | stored ids | `promotions.ex:760` -> `:650-664`, 404 at `:763`, before `apply_promotion_assertion_rerun` (`:781`) | tenant |
| `:PromotionsManage` | `POST /tenants/:test_tenant_id/promote/:process_key` | path `test_tenant_id` (source); target is `auth_context.tenant_id` | `tenants.ex:451` BEFORE any read (`do_promote` `:456`); equality rule at `tenant_target.ex:36,43-51`; target `tenants.ex:458`. A non-operator may name only its own id; another existing tenant, a nonexistent id, a malformed id and a slug all give the same 404. This is exactly the Q-960 scope-table row 34 rule. | tenant |
| `:PromotionsRead` | `GET /promotions` | none | `routers/promotions.ex:945`, `:958`: `PromotionReviewStore.list_reviews/2` with `scoped_opts` (own schema) | tenant |
| `:PromotionsRead` | `GET /promotions/:id`, `GET /promotions/:id/context` | none (review id) | `promotions.ex:469-471`, `:507-509`: `get_review(raw_id, scoped_opts)`; absent in the caller's schema means 404 | tenant |
| `:PromotionsRead` | `GET /promotions/platform-events` | none | `promotions.ex:850`, `:856` (prefix from `scoped_opts` only), `event_store.ex:1110-1123` (`Repo.all(prefix: prefix)` on the sentinel instance). Returns only rows of the caller's own schema. Own-schema reading stated per the requirement. The payload of a promotion event written into the caller's schema names the source/target tenant ids of that promotion; for a non-operator caller every foreign tenant id is omitted from the response (section 4a). | tenant (D-1 RESOLVED) |
| `:DefinitionsRollback` | `POST /definitions/:process_key/rollback` | none (a process key, resolved in the caller's schema) | `routers/definitions.ex:1167`, `:1176-1186` (`scoped_opts`); `lib/letflow/definitions.ex:1000-1001` (`rollback_definition_version/4`) derives `tenant_id` from the caller's own `prefix` and passes it to the checker, which is therefore `true` for the own tenant (`promotion_access.ex:28-31`); a key absent from the caller's schema is `:process_key_not_found` -> `Response.not_found` (`definitions.ex` router `:1200`) | tenant |

Conclusion: every one of the three permissions meets the SCOPE RULE on every route that uses it; none needs to be demoted to platform scope. The
per-route list statement required by AC9: `GET /promotions` returns no row of any tenant other than the caller's (own schema, `promotions.ex:945-958`);
`GET /promotions/platform-events` returns no row of any tenant other than the caller's (own schema, `event_store.ex:1110-1123`), so neither is made
platform scope.

Decision D-1 RESOLVED (ruling letflow-9a via the supervisor): option A. `GET /promotions/platform-events` stays TENANT scope under `:PromotionsRead`
(0046 D3 lines 115-119 and `docs/roles.md:65-67` expected a platform permission unless REQ-446 proves "it returns only the caller's rows"; the proof is
the own-schema read cited in the row above). The 0046 D3 scope-table row is CORRECTED, not re-decided: an append-only dated note titled as a CORRECTION
of the D3 scope table (text in section 6a), and `docs/roles.md` lines 65-71 are updated in the same change. The condition that goes with the ruling is
sections 4a and 4b.

### 4a. Response shaping on `GET /promotions/platform-events` (new scope inside REQ-446; INV-2, INV-10)

What was established first (read of the code):

* `EventStore.list_platform_events/1` returns items whose `payload` is a DECODED MAP (`event_store.ex:1062-1076` typedoc, `:1110-1130`,
  `platform_event_item/1` at `:1155-1164`), not a JSON string; the router's `platform_event_map/1` (`routers/promotions.ex:927-937`) copies it as is
  (`"payload" => item.payload`). `render_platform_events/2` is at `:875-880`, the handler at `:846-873`.
* Payloads are written as flat JSON objects by `Letflow.EventStore.PlatformEvents` (`event_store/platform_events.ex:60-141`, `:156-174`) from the
  producers' attrs. Event types and the keys that carry tenant ids:
  `DEFINITION_PROMOTED` (`definitions/promotion.ex:516-525`): `source_tenant_id`, `target_tenant_id` (plus `review_id`, `source_definition_id`,
  `target_definition_id`, `process_key`); `PROMOTION_ASSERTION_TEARDOWN_FAILED` (`definitions.ex:3172-3178`): `tenant_id` (plus `run_id`,
  `sandbox_id`, `error`); `DEFINITION_VERSION_ROLLED_BACK` (`definitions.ex:2703-2709`): none (`process_key`, `from_version`, `to_version`).
  The sentinel stream holds only these three producers' events; the shaping is by key, not by event type, so a future event type is covered.
* An oversized payload (above 4096 bytes) is stored as `{"$ref": <event id>}` in `events.payload` (`event_store.ex:716-722`) and the list read does not
  resolve it, so no tenant id can appear through a reference. Nested ids: today's payloads are flat; the rule below recurses anyway.
* `PlatformTenant.scope_facts_for/1` (`platform_tenant.ex`, used by `tenant_target.ex:35`) recomputes `platform_scope?` from `auth_context.tenant_id`
  and the DB-resolved roles; the stored flag is never read (iss0993 section 3/4).

Rule (the `lib/` change, a few lines in `routers/promotions.ex`, no new module required; a small private function in the same file):

* The walk recurses through every map and every list element at ANY nesting depth (a list inside a list included); an element that is neither a map
  nor a list passes through unchanged. The same walk is shared with section 4b.
* In `handle_platform_events/1` or `render_platform_events/2` the caller's `scope_facts_for(conn.assigns.auth_context).platform_scope?` and own
  `tenant_id` (`Map.get`, never dot access) are determined once.
* Operator (`platform_scope?` true): the payload is passed through unchanged.
* Everyone else: the payload map handed to `platform_event_map/1` is rebuilt (hand-built map, INV-2: not `Map.drop` of a struct, not a derived encoder)
  by walking it recursively through nested maps and lists of maps: an entry whose key, compared in lower case, equals `tenant_id` or ends with
  `tenant_id` is KEPT only when its value is a binary equal, case-insensitively, to the caller's own tenant id; otherwise the entry is OMITTED
  (not hashed, not truncated, not replaced by a placeholder; a non-binary value under such a key is omitted, fail closed). Every other key, and the
  event envelope (`event_id`, `event_type`, `actor_id`, `timestamp`, `sequence_num`), is unchanged.
* Pagination is untouched: the cursor is built from `next_cursor` of the context call (`event_store.ex:1126-1130`) before and independent of the
  payload; shaping happens after the page is read, so `page_size`, ordering, `next_cursor` and the `event_type` filter behave identically for operator
  and non-operator.

Signature shapes (design only): `shape_platform_event_payload(payload :: map(), own_tenant_id :: String.t() | nil, operator? :: boolean()) :: map()`
(private, pure); `platform_event_map/1` gains the shaped payload via that function (its arity may change to carry the caller facts; the response key set
stays `event_id`, `event_type`, `actor_id`, `timestamp`, `sequence_num`, `payload`). A caller with no resolvable own tenant id (`nil`) keeps no tenant id
at all.

Residuals that remain after the shaping, named so the reviewer sees them: `source_definition_id` / `target_definition_id` in `DEFINITION_PROMOTED`
payloads are definition row ids, not tenant ids, and are kept (the ruling names tenant ids); the teardown event `error` string is free text and is not
scanned. Both are unchanged by this entry and are listed as OQ-6 and OQ-7.

### 4b. The same shaping on `GET /promotions/:id/context` (default, OQ-9 option a)

Facts: reviews live in the caller's own schema (`promotions.ex:259`, `promotion_review_store.ex:392,404`), so the exposure is a non-operator reading the
platform tenant's schema (after REQ-447/448) or a legacy row. `review_context_map/1` (`promotions.ex:525-538`) returns the decoded `serialised_plan`
(`source_tenant_id`, `target_tenant_id`, definition ids, `entries`) and `requested_by`.

Rule (a few lines in the same file, the same private walk as section 4a, so no second implementation): for a caller that is not a platform-tenant
operator, the decoded `serialised_plan` map is rebuilt with every key equal to or ending with `tenant_id` kept only when its value equals the caller's own
tenant id (case-insensitive), otherwise omitted, recursing through maps and lists at any depth, EXCEPT that the walk does not descend into the `entries`
list: definition content (`before`/`after`) and entries stay as they are, as does `requested_by`. Operator: unchanged. The other eight response keys
(`review_id`, `plan_digest`, `status`, `def_type`, `def_id`, `created_at`, `row_version`, `requested_by`) are unchanged. This is doable in a few lines, so the
default stands; if SECURITY-REVIEWER picks option (b) this subsection and test T-8 are dropped and the exception is recorded in the 0046 correction note.

### 4c. Where the shaping applies, in one place

`GET /promotions/platform-events` (4a) and `GET /promotions/:id/context` (4b). `GET /promotions/:id` returns only `assertion_run_map` and needs none;
`GET /promotions` returns the seven-key list item, no tenant id (`promotions.ex:1049-1060`).

## 5. Tests to add or change (names are proposals; the only `lib/` change is sections 4a and 4b)

Common fixtures: `Letflow.Support.PlatformTenantFixture` (`test/support/platform_tenant_fixture.ex`): `three_tenants!/0` (P, A, B), `pin!/1`, `router_conn/5`,
`capture_repo_queries/1`, `touches_tenant?/2`. All new modules are `async: false` (VM-global pin and query telemetry), restore the pin in `on_exit`.

### T-1 (new file) `test/letflow/routers/req446_cross_tenant_denial_test.exs`, module `Letflow.Routers.Req446CrossTenantDenialTest`

Covers AC8 and AC9. One table, one entry per re-keyed route, each named by method and path. Callers table `@callers`: today one entry, a `PLATFORM_ADMIN` of
the non-platform tenant A (pin on P). A `TENANT_ADMIN` of A is added as one more line by REQ-447 (not in this PR; the table is written so that is a
one-line change).

Per entry the test makes two requests as the A caller and compares the full observable bytes (status, body, every header except `x-request-id`, same
`observable/1` idea as `promotion_scope_test.exs:90-93`):

* `foreign`: the request carrying an identifier that belongs to B;
* `nowhere`: the same request with an identifier that exists in no tenant.

Assertions per entry (rows 1-10, the request/identifier rows): the foreign and the nowhere request both answer 404 and their observable bytes are equal;
neither body contains B's tenant id, B's slug, B's review id or B's process key; `snapshot` (definitions with status/version, review ids with status and
row version, assertion-run count) of A, B and P is identical before and after the pair of A calls; for the entries that carry a tenant id,
`capture_repo_queries/1` shows no query touching B (`touches_tenant?/2`). Control per entry, run AFTER the snapshot comparison: the same request by a
`PLATFORM_ADMIN` of B with B's own identifier must answer exactly the status in the last column (a stated value, not "anything but 404"), which proves
the identifier and body are valid and the 404 of A's call is the authorization denial. Bodies are valid for the route and identical for the foreign
and the nowhere request except the one named identifier (apply, run-assertions and the rollback validate the body before the lookup: an invalid body
would make both requests the same 422 and prove nothing).

Seed (once per entry, fresh rows because controls change state): process key `K` active at version `1.0.0` in B only (`insert_active_definition!`);
for the rollback row a separate key `K2` created and activated in B as 1.0.0 then 2.0.0 through `Definitions.create/2` and `Definitions.activate/2`
(the pattern of `req077_promotion_pipeline_test.exs:689-725`; the raw insert helper would break the single-active index), absent from A; a review
`R_B` in B's schema, status `pending_review`, stored plan naming B as both source and target, `requested_by` a random UUID different from every
caller's user id, created through `PromotionReviewStore.insert_review/2` with B's `prefix` and a plan hand-built as in `promotions_test.exs:386-397`
(`seed_review!`, its digest from `PromotionDigest.compute_plan_digest/1`; a plan with B on both sides cannot come from `compute_promotion_plan/5` because
that returns an empty plan). `D` is `R_B`'s 64-character digest. `ART` is the artifact object of `promotion_scope_test.exs:328-350` (keys `id`,
`assertions`, `fixtures`, `rng_seed`, `non_deterministic_fields`, `candidate_definitions`). Callers: A caller = `PLATFORM_ADMIN` of A with the pin on P;
control caller = `PLATFORM_ADMIN` of B with a fresh user id.

| # | Entry (caller A) | Body (identical for foreign and nowhere except the named identifier) | Foreign identifier | Nowhere identifier | A call status | Control (B's admin, B's own identifier) and expected status |
|---|---|---|---|---|---|---|
| 1 | `POST /promotions` | `source_tenant_id`, `target_tenant_id`, `process_key` = `K`, `base_version` = `"1.0.0"` (the four fields of `@submit_schema`, `promotions.ex:247-274`); `target_tenant_id` = A's own id in both | `source_tenant_id` = B's id | `source_tenant_id` = a fresh UUID | 404 | source = target = B's id, same `K`, `"1.0.0"`: **422** `empty_promotion_plan` (the handler reaches `compute_promotion_plan/5`, identical sides give `:empty_plan`, `promotion_plan.ex:155-160`, mapped at `promotions.ex:339-344`, status 422 at `api/error.ex:371-375`) |
| 2 | `POST /promotions/plan` | `source_tenant_id` = A's own id, `target_tenant_id`, `process_key` = `K` (the three fields of `@plan_schema`, `promotions.ex:375-395`) | `target_tenant_id` = B's id | `target_tenant_id` = a fresh UUID (the nowhere variant of the plan row; source stays A's own id so only the target differs) | 404 | source = target = B's id, `K`: **422** `empty_promotion_plan` (`promotions.ex:436-441`) |
| 3 | `GET /promotions/:id` | none | `R_B`'s id | a fresh UUID | 404 | `R_B`'s id: **200**, body `{"assertion_run": null}` (`promotions.ex:468-484`: review exists, no run) |
| 4 | `GET /promotions/:id/context` | none | `R_B`'s id | a fresh UUID | 404 | **200**, body carries `"review_id"` equal to `R_B`'s id (`promotions.ex:514-538`) |
| 5 | `POST /promotions/:id/approve` | `{"plan_digest": D}` (`@digest_schema`, `promotions.ex:542-551`; same `D` in both requests) | `R_B`'s id | a fresh UUID | 404 | **200**, `{"review_id": R_B, "status": "approved"}` (the control user differs from `requested_by`, so no self-approval 403, `promotions.ex:575-581`) |
| 6 | `POST /promotions/:id/reject` | `{}` (reject's schema is empty, `promotions.ex:599`) | `R_B`'s id | a fresh UUID | 404 | **200**, `{"review_id": R_B, "status": "rejected"}` (`promotions.ex:609-610`) |
| 7 | `POST /promotions/:id/apply` | `{"plan_digest": D}` | `R_B`'s id | a fresh UUID | 404 | **409** `review is not in a state that permits this transition`: the review is `pending_review`, not approved, so `Promotion.apply_review/4` stops at `verify_approved` (`definitions/promotion.ex:607-625`, mapped at `promotions.ex:674`); the stored ids (B, B) pass the scope check for B's own admin (`promotions.ex:650-664`) |
| 8 | `POST /promotions/:review_id/run-assertions` | `{"plan_digest": D, "artifact": ART}` (`@run_assertions_schema`, `promotions.ex:735-744`) | `R_B`'s id | a fresh UUID | 404 | **200**, six-key body with `assertions_failed` 0 (same shape and sandbox pool configuration as `req077_promotion_pipeline_test.exs:652-682`; status 503 would mean the pool is not available and the control must fail loudly, not be skipped) |
| 9 | `POST /definitions/:process_key/rollback` | `{"target_version": "1.0.0"}` (`@rollback_schema`, `routers/definitions.ex:1156-1164`; `1.0.0` is the older of the two versions of `K2` that exist only in B; the nowhere request carries the same value) | path key `K2` (exists only in B) | path key that exists in no tenant | 404 (`:process_key_not_found`, `routers/definitions.ex:1200`) | `K2` as B's admin: **200**, `version` `"1.0.0"` and `rolled_back_from_version` `"2.0.0"` (`req077_promotion_pipeline_test.exs:689-740`) |
| 10 | `POST /tenants/:test_tenant_id/promote/:process_key` | none (the handler ignores the body, `tenants.ex:436-443`); path key `K` | path `test_tenant_id` = B's id | path `test_tenant_id` = a fresh UUID | 404 | `test_tenant_id` = B's own id, `K` active in B: **409** duplicate version (source = target = B, as proved by `promote_source_tenant_test.exs:102-114`, lines 109-111) |
| 11 | `GET /promotions` | none (no query string) | n/a: baseline form below | n/a | 200 | B's admin: **200**, the items include `R_B`'s id |
| 12 | `GET /promotions/platform-events` | none (no query string) | n/a: baseline form below | n/a | 200 | B's admin: **200**, the items include the event seeded in B |

Rows 11 and 12 use the baseline form: A has its own review (row 11) or its own sentinel event (row 12) seeded first; A's response is taken; B's review or
event is then seeded; A's response is taken again; the two are byte-identical (status, body, headers except `x-request-id`), neither contains any id
or tenant id of B, and the control above shows B's admin does see B's row. Row 12's own event, written by the same fixture that seeds it, carries only
A's own tenant id in its payload (any tenant id of B in the stored B event must not appear in A's response, also covered by T-7).

Helpers the file needs that already exist privately elsewhere (copy or lift to `test/support`; the PR states which): `insert_active_definition!/3`
(`promotion_scope_test.exs:95-121`), `artifact/0` (`:328-350`), `seed_platform_event!/1` (`:548-560`), `snapshot/1` (`:127-145`), `observable/1`
(`:90-93`), `seed_review!/3` (`routers/promotions_test.exs:386-397`).

### T-2 extend `test/letflow/routers/promotion_scope_test.exs`, test "every other role is denied 403 on every row" (line 182)

Add `["CANDIDATE"]` and `["AGENT_RUNNER"]` to the `roles <-` list at `:184`. Nothing is removed. This completes AC3 at router level for all five named
roles (plus the no-role case already there), over all 12 rows, for the A and P fixtures.

### T-3 no change: AC1 table already exists (`platform_scope_authorization_test.exs:292-317`)

No change. The implementation PR cites it in AC1 evidence. (Only the moduledoc lines 12-13 are updated in T-6.)

### T-4 extend `test/letflow/api/platform_scope_inventory_test.exs`, describe "G2: route table"

Refactor the inline predicate of test "(a) no route declares :Unknown ..." (`:351-361`) into one private helper returning the offending route list
(router, method, path, key) from a list of route tuples, used by the existing test unchanged in effect, and add:

* `"G2 (a) flags a fixture router that declares :Unknown as an explicit key"`: compile a throwaway router module with `Code.compile_string` (the same technique
  as `compile_router/1` at `:102-119`) that declares one `authz_get` route with key `:Unknown` and one valid route, call `__authz_routes__/0`, feed the
  tuples to the helper and assert exactly the `:Unknown` one is flagged. This is the "demonstrated once" for the explicit-key form (AC5); the plain-macro
  form is already demonstrated by G0 (`:128-133`) and G1 (`:239-266`).

### T-5 no change: scope-completeness and G3

`platform_scope_authorization_test.exs:80-91`, `platform_scope_inventory_test.exs:375-398`, `:460-501` already pass for the three permissions (AC6).

### T-6 stale prose in tests (comments and moduledocs only, no assertion touched)

| File:line | Stale statement | Replace with |
|---|---|---|
| `test/letflow/api/authorization_enforcement_test.exs:25-36` | a route declared with a plain macro "evaluates as `:Unknown` (fail-closed-EXCEPT-`PLATFORM_ADMIN`)" | plain macros no longer compile (G0), and a missing key evaluates `:Unknown`, denied for every role (`authorization.ex:1057-1062`) |
| `test/letflow/api/authorization_enforcement_test.exs:85-93` | `TenantSettings` declares `:TenantsManage` | declares `:TenantSettingsManage` (tenant scope) |
| `test/letflow/api/authorization_enforcement_test.exs:48-101` | hand list `@routers` (omits Dlq, Webhooks, PlatformMigrations, EventRetention, TenantModules, TenantSolutions, PublicReadHandles) | add one comment that the complete walk is G2 in `platform_scope_inventory_test.exs`; do not add routers here (out of scope) |
| `test/letflow/api/platform_scope_authorization_test.exs:12-13` | "the A1 behaviour of `:Unknown` ... the legacy branch is KEPT in A1 ... the two A1-variant tests below flip there" | A2 state: `:Unknown` is denied for every role (test at `:284-289`) |
| `test/letflow/api/authorization_test.exs:33-34` | "now including :MyModulesRead as its 34th/last entry" | the list is the 40 core permissions; do not state a position |
| `test/letflow/plugs/api_pipeline_integration_test.exs:105-106` | points at `authorization_enforcement_test.exs` AC5 for "the PLATFORM_ADMIN-allowed half of the same `:Unknown` branch" | `:Unknown` is denied for everyone; the allowed 404 is the `:UnmatchedRoute` marker (`authorization.ex:1073-1076`) |
| `test/letflow/plugs/admission_pipeline_test.exs:157-159` | "per ... `:Unknown`-branch PLATFORM_ADMIN allowance" | `:UnmatchedRoute` marker allowance |

### T-7 (new file) `test/letflow/routers/promotion_platform_events_shaping_test.exs`, module `Letflow.Routers.PromotionPlatformEventsShapingTest`

Covers the response shaping of section 4a. `async: false` (platform pin), `three_tenants!/0` (P, A, B), pin on P unless stated. Events are written into the
schema under test through the real producers' adapters (`EventStore.PlatformEvents.append_definition_promoted/2`,
`append_promotion_assertion_teardown_failed/2`, `append_definition_version_rolled_back/2`; the three event types must be registered for that tenant as
`register_event_type!/1` at `promotion_scope_test.exs:531-546` does, with a permissive `{"type": "object"}` schema), or through
`EventStore.append_platform_event/2` for the nested-payload cases (a registered fixture type). "The operator promotes B into A" is simulated by writing
the `DEFINITION_PROMOTED` event that `Promotion.promote_definition/3` would write into A's schema: source = B's id, target = A's id.

Seed in A's schema: E1 `DEFINITION_PROMOTED` (source B, target A); E2 `PROMOTION_ASSERTION_TEARDOWN_FAILED` (`tenant_id` B); E3 `DEFINITION_PROMOTED` (source A,
target A); E4 teardown (`tenant_id` A; a second variant with A's id upper-cased); E5 `DEFINITION_VERSION_ROLLED_BACK` (no tenant id); E6 a fixture-type event with a
nested payload (`detail.origin_tenant_id` B, `detail.items` a list of two maps holding `tenant_id` B and `tenant_id` A, plus an unrelated `note`); E7 a
fixture-type event whose payload has `"tenant_id": 5` (non-binary).

| Test name | Caller | Assertions |
|---|---|---|
| `non_operator_never_receives_a_foreign_tenant_id` | A's `PLATFORM_ADMIN`, pin on P | status 200; the RAW response body (string) contains neither B's id nor its upper-case form; E1's payload has no `source_tenant_id` and keeps `target_tenant_id` = A's id; E2's payload has no `tenant_id`; E3 keeps both ids; E4 keeps `tenant_id` (also the upper-case variant); E6's nested B ids are gone at every depth and the nested A id is kept; E7's non-binary `tenant_id` is omitted |
| `own_tenant_id_is_retained` | A's `PLATFORM_ADMIN` | every occurrence of A's id in the seeded payloads is present in the response (key by key), including the list element in E6 |
| `other_payload_fields_and_envelope_unchanged` | A's `PLATFORM_ADMIN` | for every event the response payload equals the stored payload minus exactly the omitted tenant-id keys (`review_id`, `source_definition_id`, `target_definition_id`, `process_key`, `run_id`, `sandbox_id`, `error`, `from_version`, `to_version`, `note` all unchanged); `event_id`, `event_type`, `actor_id`, `timestamp`, `sequence_num` equal the stored event; the item key set is still the six keys and the envelope still `items`/`next_cursor` |
| `operator_sees_every_tenant_id` | the platform tenant's `PLATFORM_ADMIN` reading P's own schema, which holds the same seed (source B, target P; `tenant_id` B) | both B's id and P's id appear in the response; payloads equal the stored payloads exactly |
| `pin_unset_would_be_operator_is_shaped_like_everyone_else` | P's `PLATFORM_ADMIN` with the pin removed | B's id absent from the response |
| `pagination_is_unaffected` | A's `PLATFORM_ADMIN` | with `page_size` 2 over the seed, following `next_cursor` returns every event exactly once in `sequence_num` order and the last page has `next_cursor` null; the `event_type` filter narrows exactly as before; cursor STRINGS are never compared (each embeds a mint time, `event_store.ex:1178-1180`, `System.system_time(:microsecond)`, so two reads never return the same string). Instead, for each page the test decodes the cursor with `Pagination.decode_cursor/3` and parses the inner payload, whose raw form is `PE:<mint_time_us>:<seq>:<event_id>` (`promotions.ex:904-919`), to the seek key `<seq>:<event_id>` and asserts it equals the `sequence_num` and `event_id` of that page's last item, and that the page contents (event ids, order) read as A equal the page contents read when A is pinned as the platform tenant (A then reads unshaped), proving neither paging nor the cursor depends on the shaped payload |
| `list_inside_list_is_walked` | A's `PLATFORM_ADMIN` | E8, a fixture-type event with payload `{"x": [[{"tenant_id": "<B>"}, {"tenant_id": "<A>", "k": 1}]], "y": 7}`: the response keeps `{"x": [[{}, {"tenant_id": "<A>", "k": 1}]], "y": 7}` (B's id omitted at depth, A's kept, scalars `7` and `1` unchanged) |
| `other_roles_still_forbidden_and_see_no_event_data` | `PROCESS_DESIGNER`, `TASK_WORKER`, `CANDIDATE`, `AGENT_RUNNER` | 403 and no seeded id in the body (the existing `promotion_scope_test.exs:598-609` case stays) |

### T-8 (new file) `test/letflow/routers/promotion_context_shaping_test.exs`, module `Letflow.Routers.PromotionContextShapingTest`: the same shaping on `GET /promotions/:id/context` (section 4b)

| Test name | Caller | Assertions |
|---|---|---|
| `context_omits_foreign_tenant_ids_for_non_operator` | an admin of A (pin on P) reading a review stored in A's schema by `PromotionReviewStore.insert_review/2` whose plan names B as source and A as target (a legacy row; inserted directly because the handler no longer lets A create it) | 200; the raw body does not contain B's id; `serialised_plan.target_tenant_id` = A's id is kept; `source_tenant_id` is absent; `entries` (`before`/`after`), `source_definition_id`, `target_definition_id`, `process_key`, `base_version` and `requested_by` equal the stored values |
| `context_unchanged_for_operator` | the platform tenant's `PLATFORM_ADMIN` reading a review stored in P's schema naming B and A | both ids present; body equal to the unshaped map |
| `context_nested_tenant_ids_walked_but_entries_not_descended` | admin of A | a stored plan with a nested map and a list-in-list carrying `tenant_id` B outside `entries` is shaped; the same key inside an `entries` element is left as stored |
| `context_other_keys_and_status_unchanged` | admin of A | the nine response keys are the same set as before (`routers/promotions.ex:525-538`); `GET /promotions/:id` returns its seven-key `assertion_run_map` unchanged |

Existing tests that must stay green unchanged: `promotion_scope_test.exs:574-609`, `routers/promotions_test.exs:156-212` (empty payloads, unaffected by the
shaping).

## 6. Files to add or change for the remaining work

One file under `lib/`; no migration, no `web/`, no `priv/` change.

| # | File | Change | Reason |
|---|---|---|---|
| 0 | `lib/letflow/routers/promotions.ex` | response shaping per sections 4a and 4b (same private walk), in `handle_platform_events/1` / `render_platform_events/2` (`:846-880`) and `platform_event_map/1` (`:927-937`); one private pure function of the shape given in 4a; the moduledoc R11 paragraph (`:37-43`) and the Authorization section (`:61-79`) gain two sentences stating the shaping and that the route is tenant scope | ruling letflow-9a condition, INV-2, INV-10 |
| 1 | `test/letflow/routers/req446_cross_tenant_denial_test.exs` | NEW (T-1) | AC8, AC9 |
| 1b | `test/letflow/routers/promotion_platform_events_shaping_test.exs` | NEW (T-7: `non_operator_never_receives_a_foreign_tenant_id`, `own_tenant_id_is_retained`, `other_payload_fields_and_envelope_unchanged`, `operator_sees_every_tenant_id`, `pin_unset_would_be_operator_is_shaped_like_everyone_else`, `pagination_is_unaffected`, `list_inside_list_is_walked`, `other_roles_still_forbidden_and_see_no_event_data`) | section 4a |
| 1c | `test/letflow/routers/promotion_context_shaping_test.exs` | NEW, module `Letflow.Routers.PromotionContextShapingTest` (T-8: `context_omits_foreign_tenant_ids_for_non_operator`, `context_unchanged_for_operator`, `context_nested_tenant_ids_walked_but_entries_not_descended`, `context_other_keys_and_status_unchanged`) | section 4b |
| 2 | `test/support/platform_tenant_fixture.ex` or a new `test/support/promotion_scope_fixture.ex` | OPTIONAL: lifted helpers for T-1, T-7 and T-8 | reuse |
| 3 | `test/letflow/routers/promotion_scope_test.exs` | edit line 184 role list (T-2) | AC3 |
| 4 | `test/letflow/api/platform_scope_inventory_test.exs` | helper extraction plus one test (T-4) | AC5 |
| 5-9 | the five test files of T-6 (`authorization_enforcement_test.exs`, `platform_scope_authorization_test.exs`, `authorization_test.exs`, `plugs/api_pipeline_integration_test.exs`, `plugs/admission_pipeline_test.exs`) | comment and moduledoc text only | build item 5 |
| 12 | `docs/migration/decisions/0046-admin-scopes-and-role-charter.md` | APPEND ONLY the note of section 6a at the end of the file; no existing line is edited (REQ-445 byte-identical rule: `git diff` for this file shows additions only) | D-1 ruling |
| 13 | `docs/roles.md` | lines 65-71 rewritten per section 6a; matrix rows (`PromotionsRead`, `PromotionsManage`, `DefinitionsRollback`, lines 110-112) unchanged | REQ-448's parity test reads this file |
| 14 | `docs/requirements.yaml` and the current run-history volume named by `docs/status/requirement_status.index.yaml` | status flip and one appended event with a real UTC timestamp | DOC-UPDATER, after the gates |

### 6a. Text of the two documentation changes (no implementation code)

0046 appended note. Heading: "Correction of the D3 scope table (REQ-446), dated <UTC date of the commit>". It is a CORRECTION of the D3 permission scope
table's planned row "platform-events permission, to be named by REQ-446 | platform", not an amendment of a decision. Body states, each as one short
paragraph: (1) the route: `GET /promotions/platform-events`; (2) the new classification: tenant scope, permission `:PromotionsRead`, no separate
platform-events permission exists; (3) the evidence that it returns only the caller's own rows, with file and line: `lib/letflow/routers/promotions.ex`
prefix taken from `scoped_opts` only, `lib/letflow/event_store.ex` `list_platform_events/1` `Repo.all(prefix: prefix)`, and `lib/letflow/plugs/authorize.ex`
building `scoped_opts` from `auth_context.tenant_id` (line numbers re-read at commit time); (4) the residual that the event payload names other tenants'
ids, with its reference (this design, sections 4a and 4b, OQ-6, OQ-7 and OQ-9) and its closure: foreign tenant ids are omitted from the response for every caller that is
not a platform-tenant operator; (5) one sentence that the D3 binding condition for `:PromotionsRead`, `:PromotionsManage`, `:DefinitionsRollback` and the
promote route is met by the ownership check of this design, section 4, citing `tenants.ex:451` and `tenant_target.ex:31-39`. The note repeats no
decision text and changes no decision.

`docs/roles.md` lines 65-71. Remove the clause that a permission REQ-446 classifies as platform "(promotion platform-events)" is added as `platform`;
replace it by: REQ-446 classified `GET /promotions/platform-events` as tenant scope under `PromotionsRead` (see the correction note appended to 0046);
no platform promotion permission exists. Replace the "Conditional cells" paragraph by one stating that the condition (source-tenant ownership proven) is
met and giving the citation `tenants.ex:451`, `tenant_target.ex:31-39`; the TENANT_ADMIN and TENANT_AUDITOR `yes` cells for `PromotionsRead` and
`PromotionsManage` stand.

## 7. Risks and residuals

* R-1 (platform-events payload), CLOSED by sections 4a (platform-events) and 4b (`/context`, R-2) for tenant ids: a non-operator receives only its own tenant id in any payload key ending in
  `tenant_id`, at any depth. Remaining, named: definition row ids (`source_definition_id`, `target_definition_id`) and the free-text teardown `error`
  are not tenant ids and are not shaped (OQ-6, OQ-7). A new event type that carries a foreign tenant id under a key NOT ending in `tenant_id` (for
  example `source_tenant` or an id inside a string) would not be caught; the shaping is key-based by ruling, so this is a convention a future event
  author must follow (OQ-8).
* R-2 (context content), restated on the validator's facts. Reviews are inserted into the CALLER's own schema (`handle_submit` passes `scoped_opts`,
  `promotions.ex:259`; `insert_review` takes the prefix from `opts`, `promotion_review_store.ex:392,404`; `scoped_opts` comes from
  `auth_context.tenant_id`, `plugs/authorize.ex:103-132`), so an operator-created review sits in the platform tenant P's schema, not a customer's.
  `GET /promotions/:id` returns only `assertion_run_map` (seven keys, no tenant id; `teardown_error` is free text and unscanned). `GET /promotions/:id/context`
  returns the decoded `serialised_plan` (`source_tenant_id`, `target_tenant_id`, source and target definition ids, entries with `before`/`after` content)
  and `requested_by` (`promotions.ex:525-538`, `promotion_plan.ex:155-170`). Who can read a foreign tenant id there: an admin of A reads A's schema, which
  after the ISS-0993 fix holds only A-created reviews (both ids are A's, enforced by `tenants_authorized?`, `promotions.ex:285,296-298`) except LEGACY rows
  written before the fix (`promotions.ex:646`); a NON-OPERATOR reader of P's schema (a `TENANT_ADMIN` or `TENANT_AUDITOR` of P once REQ-447/REQ-448 grant
  `PromotionsRead`) would see operator-created reviews naming customer tenants. Closed by section 4b (default); decision for SECURITY-REVIEWER in OQ-9. Residual next to OQ-9: the plan `entries` (`before`/`after` content) are not descended by the walk and not scanned; the plan builder (`promotion_plan.ex:155-170`) injects no tenant-id key into them, but definition graph content is tenant-authored free-form JSON and could carry any key or value.
* R-3 (approve/reject). No stored-id re-check on approve and reject (only apply and run-assertions re-check, `promotions.ex:650-664`). Safe because they
  mutate only a review row in the caller's own schema and no cross-tenant write occurs until apply; `promotion_review_store.ex:137-142` already
  flags the missing checker as an adjacent gap. Not widened by this entry. T-1 rows 5 and 6 prove B's review id gives the 404 and B's row does not change.
* R-4 (`cross_tenant_promotion_operator_only?/0`). Documented as restoring the legacy allow-all pairing, but `TenantTarget` ignores it. Setting it to
  false makes only the checker allow-all; the route gate still returns 404 for a foreign id. Not exploitable and unset in `config/`. Out of scope;
  a follow-up may delete it (OQ-2).
* R-5 (test fragility). T-1 depends on three provisioned schemas, query telemetry and the sandbox pool for the row 8 control; the rollback row needs two
  versions that were both active (create and activate, not the raw insert helper). T-7 and T-8 depend on registering event types per tenant.
* R-6 (validation order). apply, run-assertions and rollback validate the body before the lookup; T-1 sends the full valid body to both the foreign and
  the nowhere request (table in T-1).
* R-7 (scope drift). The amended requirement and ruling add exactly the platform-events and `/context` shaping (4a, 4b); any new permission, route or role would be scope creep.
  REQ-447 grants these permissions to `TENANT_ADMIN` and adds that caller to T-1.
* R-8 (shaping correctness). The rule must run after the page is read and must not touch the cursor; it compares in lower case (the own id may be stored
  in either case); a missing own tenant id keeps no tenant id. T-7 and T-8 cover each.

## 8. What changes under `lib/`, and the remaining alternative

Planned `lib/` change, and the only one: sections 4a and 4b, one file, `lib/letflow/routers/promotions.ex`.

* Not planned (case A): REVIEWER may want the dead `cross_tenant_promotion_operator_only?/0` switch removed (R-4): `lib/letflow/platform_tenant.ex:23-27,37-49`,
  `lib/letflow/definitions/promotion_access.ex:16-18,28-31`, `lib/letflow/api/authorization.ex:801` comment, `lib/letflow/routers/promotions.ex:72-73`,
  `lib/letflow/routers/tenants.ex:75`, tests `test/letflow/definitions/promotion_access_test.exs:132-148` and
  `test/letflow/api/platform_marker_not_writable_test.exs:305`. Recommendation: not in this entry.
* The earlier "case B" (a separate platform permission for platform-events) is withdrawn by the ruling D-1 (option A).

## 9. Acceptance mapping of this design

Every AC and every BUILDS item maps to a row of section 1 or 2 with either a citation (DONE) or a named test or file (T-1..T-8, files 0-14). No TBD.
The ruling letflow-9a (D-1 option A, 0046 CORRECTION note, `docs/roles.md`, 12 routes) and its INV-10 condition (sections 4a, 4b, tests T-7, T-8) are folded in.

Open questions (none silently resolved):

* OQ-2 whether to delete the `cross_tenant_promotion_operator_only?/0` switch (default: no, out of scope).
* OQ-4 where the shared test helpers live (T-1, T-7, T-8, file 2); TEST-DESIGNER decides and states it in the PR.
* OQ-5 the requirement text says "thirteen"; default is to leave the requirement entry unchanged (section 3); 12 routes agreed.
* OQ-6 `source_definition_id` / `target_definition_id` in `DEFINITION_PROMOTED` payloads are kept (not tenant ids). Default: kept.
* OQ-7 the teardown event's free-text `error` is not scanned for tenant ids. Default: not scanned.
* OQ-8 key-based shaping (`tenant_id` suffix) by ruling; values hiding a foreign tenant id under another key are not caught. Default: key-based only.
* OQ-9 Reader of `GET /promotions/:id/context`: a non-operator reader of the platform tenant's schema (a `TENANT_ADMIN` or `TENANT_AUDITOR` of P once
  REQ-447/448 grant `PromotionsRead`), or a reader of a legacy review row in a customer schema, sees `source_tenant_id` and `target_tenant_id` of
  operator-created reviews naming customer tenants. SECURITY-REVIEWER decides between (a) extending the shaping to `review_context_map/1` (DEFAULT in this
  design, section 4b, a few lines in the same file, plus test T-8) and (b) recording a tracked exception. Choice stated: (a). A related, unshaped residual
  is the plan `entries` (`before`/`after` definition content: the plan builder `promotion_plan.ex:155-170` injects no tenant-id key, but graph content is tenant-authored free-form JSON and is not scanned) and
  `requested_by`, a user id, which stay as they are.
* Closed by ruling: D-1 (tenant scope, option A); where the 0046 correction is written (this PR, append-only).
