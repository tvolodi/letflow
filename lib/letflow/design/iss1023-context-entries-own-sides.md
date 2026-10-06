# Design: ISS-1023 (Q-1005 / GH #2297) - `entries` of the /context `serialised_plan` only for plans whose both sides are the caller's own tenant

Owner: ELIXIR-DEV. Severity MAJOR (INV-10). Size S3. Depends on ISS-1021 (Q-1003 / GH #2291), merged at 3204c418.
Design only: signatures, rules and test recipes; no implementation code.

## 1. Problem (read of the code at 3204c418)

`GET /promotions/:id/context` (tenant scope, `authz_get "/:id/context", :PromotionsRead`, `lib/letflow/routers/promotions.ex:232`) returns a decoded
`serialised_plan` through `shape_plan/2` (`promotions.ex:1077-1121`). After ISS-1021 the top-level keys are an allowlist, but the last step
(`promotions.ex:1112-1118`) copies `entries` as stored whenever it is a list.

`entries` is the plan's definition diff: `build_entries` (`definitions/promotion_plan.ex:199-243`) fills it from BOTH the source graph and the target graph
(nodes, edges, variable schemas, `service_id` bindings of SERVICE_TASK nodes, `module_ref` of SUB_PROCESS nodes), each entry carrying `before` and `after`
graph JSON. The plan is built by `compute_promotion_plan/5` (`promotion_plan.ex:152-161`) with `source_tenant_id` and `target_tenant_id` as the first two keys.

Where the plan is stored: `PromotionReviewStore.insert_review/2` writes into the schema named by the caller's scoped opts. A non-operator can only submit a
promotion naming its own tenant (`tenants_authorized?/2`, `promotions.ex:303,314`, `TenantTarget.authorize_target_tenant/2`), so its review lives in its own schema
and both sides are own. The platform operator may name any tenants (0046 D3, cross-tenant promotion is operator-only), so an operator-created review for B (source) and
C (target) is stored in the PLATFORM tenant P's schema, and `entries` there holds B's and C's definition content. Legacy rows (written before the gate existed) can
name foreign tenants in an ordinary tenant's schema. The route reads only the caller's own schema (`PromotionReviewStore.get_review(raw_id, scoped_opts)`,
`promotions.ex:525-528`), so the reader is whoever holds `:PromotionsRead` in P's schema (or in the legacy row's schema) and is not an operator (`tenant_view/1`,
`promotions.ex:1034-1044`).

INV-10 (`docs/agents/instructions/security-invariants.md:387-393`): a tenant-scope read carries no other tenant's data or identifiers. Not worse than before ISS-1021
(the old walk also skipped `entries`); it is the standing TRACKED exception R1 of ISS-1021 (design section 3.3 and 8, 0046 closure section of ISS-1021,
`test/specs/ISS-1021.md` R1), recorded as such by SECURITY-REVIEWER on Q-1003. This design closes it.

## 2. AC5: who actually holds `:PromotionsRead` and which roles can read P's reviews (established from code)

Read of `lib/letflow/api/authorization.ex` at 3204c418:

| Fact | Evidence |
|---|---|
| The role set is closed at six atoms: `PLATFORM_ADMIN`, `PROCESS_DESIGNER`, `PROCESS_OPERATOR`, `TASK_WORKER`, `AGENT_RUNNER`, `CANDIDATE` | `@roles`, `authorization.ex:376-383`; `role_from_string/1` `:597-603` maps exactly those six names, every other string (including `TENANT_ADMIN`, `TENANT_AUDITOR`) to `nil`, and `roles_from_strings/1` (`:567-576`) drops it |
| `:PromotionsRead` is a core permission, tenant scope | `@permissions` `authorization.ex:424`; `@permission_scope` `:436-442` (only `:TenantsManage`, `:PlatformServicesManage` are platform) |
| Only `PLATFORM_ADMIN` holds it, through the unconditional catch-all | `core_role_allows?(:PLATFORM_ADMIN, _permission), do: true` `authorization.ex:1301` |
| `PROCESS_DESIGNER` does not | explicit list `authorization.ex:1303-1339`: no `:PromotionsRead` |
| `PROCESS_OPERATOR` does not | explicit list `authorization.ex:1341-1379`: no `:PromotionsRead` |
| `TASK_WORKER` does not | explicit list `authorization.ex:1381-1405`: no `:PromotionsRead` |
| `AGENT_RUNNER` does not | `:HelpRead` and `:MembershipsRead` only, `authorization.ex:1413-1418` |
| `CANDIDATE` does not | uniformly `false`, `authorization.ex:1427` |
| No module grants it through the Catalog fallback | `role_allows?/2` `authorization.ex:1294-1296` falls back to `Letflow.Modules.Catalog.role_grants/1`; the only registered module with grants is Exam, `CANDIDATE` and six `ExamSession*`/`ExamCertificateIssue` atoms (`lib/letflow/modules/exam/exam.ex:54-63`); the Catalog rejects module atoms that collide with a core permission (moduledoc, `authorization.ex:1273-1278`) |
| `TENANT_ADMIN` and `TENANT_AUDITOR` with `PromotionsRead` `yes` exist ONLY as planned columns | `docs/roles.md:74,110` (matrix, "planned permissions"); no occurrence in `lib/**/*.ex` outside design `.md` files; REQ-447 (`docs/requirements.yaml`, entry titled "Add the TENANT_ADMIN role ...") is `status: pending` |

Conclusion for AC5 (recorded, verified from code, not from the issue's assumption):

1. TODAY no NON-ADMIN user of any tenant, the platform tenant included, holds `:PromotionsRead`. The only holder is a user whose token carries the role string
   `PLATFORM_ADMIN`.
2. In the platform tenant P with the pin set to P, a `PLATFORM_ADMIN` is the operator (`PlatformTenant.scope_facts/2`, `platform_tenant.ex:110-119`:
   platform tenant AND `:PLATFORM_ADMIN` parsed) and sees the plan unchanged. So with a correctly pinned platform, the only role that can read P's reviews is the
   operator itself; every other role in P gets 403 (`promotion_scope_test.exs`, "every other role gets 403").
3. The exposure is therefore LATENT for P, and reachable today in three ways: (a) the pin unset or pointing elsewhere: P's `PLATFORM_ADMIN` is then a non-operator
   (`tenant_view/1`; already pinned as behaviour by ISS-1021 T-11 `pin_unset_would_be_operator_is_shaped_like_everyone_else`); (b) legacy rows naming foreign tenants in
   an ordinary tenant's schema, read by that tenant's `PLATFORM_ADMIN` (today ordinary tenant admins carry the role string `PLATFORM_ADMIN`, REQ-447 migrates them);
   (c) as soon as REQ-447/REQ-448 grant `PromotionsRead` to `TENANT_ADMIN` and `TENANT_AUDITOR` (docs/roles.md matrix), a `TENANT_ADMIN` or `TENANT_AUDITOR` of P is a
   non-operator holder reading P's operator-created reviews. This design makes that grant safe to ship; it is a prerequisite of that grant (OQ-6).
4. The issue's wording "any non-operator caller who holds :PromotionsRead in P's schema" is correct as a rule; its "not verified whether non-admin platform-tenant
   users hold it" is answered: they do not, yet. The fix is still required (3a, 3b, 3c) and is NOT a deferral of the check.

The two-tenant test (section 6) therefore uses, as the P-held reader, the only role that holds the permission today: `PLATFORM_ADMIN` of P with the pin NOT on P
(`Fixture.unpin!/0`). A second test pins the AC5 role finding (every other core role in P is 403, and the unknown strings `TENANT_ADMIN`/`TENANT_AUDITOR` resolve to
no role and are 403), so the day REQ-447 changes the matrix this test fails and a person re-evaluates this design.

## 3. Decisions

### 3.1 The rule (non-operator only)

`entries` in the response `serialised_plan` of a NON-operator is:

* the stored list, UNCHANGED, when `serialised_plan` is a map AND `entries` is a list AND for EVERY key in the new gate list `entries_gate`
  (`source_tenant_id`, `target_tenant_id`) the stored value passes the existing `own_tenant_value?/2` test (a binary equal, case-insensitively, to the caller's own
  tenant id; `promotions.ex:1123-1126`, unchanged);
* `[]` in every other case.

"Every other case" is exact and fails closed: a gate key that is missing, `null`, a non-binary (number, list, map, boolean), a binary that is not the caller's own
(foreign id, empty string, id with surrounding whitespace, a different uuid), or the caller having no resolvable own tenant id (`{:tenant, nil}`, an unreachable branch
through the route, see ISS-1021 OQ-5). Case difference alone does NOT fail the gate (same rule as the tenant-id keys). `entries` not a list, absent, and a non-map plan
keep the ISS-1021 results (`[]` / `%{"entries" => []}`).

The gate is evaluated on the STORED values, independently of whether the tenant-id keys themselves are shown. (They are shown only when own, so a response that
carries `entries` non-empty always also shows both own tenant ids; the converse is false.)

### 3.2 `[]` versus an unreadable review: `[]`

Decision: return `[]`. Justification:

* The ISS-1021 contract is that a non-operator always gets a map with `entries` as a list (design 3.4, invariant I-2); the SPA reads
  `serialised_plan.entries` and declares `{ entries: PlanEntry[] }` (`web/src/api/promotions.ts:116,161`, `PromotionReviewStateMachine.tsx:247-270`). `[]` keeps that type;
  a 404 would add an error state the SPA does not handle and would turn a read of an existing review of the caller's own schema into "not found", contradicting
  the INV-5 rule that a 404 means "not in your schema" (`promotions.ex` moduledoc, `get_review` in own schema).
* The reader's own record still shows what is safe to show (status, `process_key`, own ids). Hiding the whole review would also hide the review from a P
  reviewer who legitimately sees the list (`GET /promotions`, own schema) and its `def_id`.
* What the reader can still do with such a review (corrected after SECURITY-REVIEWER; an earlier draft wrongly said approve and reject use the stored-id helper): `apply`
  (`promotions.ex:645`) and `run-assertions` (`:779`) call `stored_tenants_authorized?/3` (`:669`) and answer the zero-detail 404 for a foreign-named stored review
  (`promotion_scope_test.exs` header, lines 14-18). `handle_approve` (`:572-592`) and `handle_reject` (`:609-626`) do NOT call it: a non-operator holding `:PromotionsManage` can
  approve or reject a foreign-named review that sits in its OWN schema and learns only the status. That change touches only the caller's own schema, so it adds no cross-tenant
  exposure; but it also means the empty diff is not free: an approver could approve a review whose diff they can no longer see. This is accepted here because the approval is of a record
  in the reader's own schema, `apply` stays blocked, and withholding the diff is the INV-10 requirement. Gating approve/reject by stored ids is a separate, optional hardening, not done
  here and not a condition of this fix (R10, OQ-9; ORCH decides whether to track it).
* Not leaking by shape: the plan builder rejects an empty plan with `{:error, :empty_plan}` (`promotion_plan.ex:149-150`), so a stored `entries` is never `[]` for a real
  review; a non-operator can therefore tell "withheld" from "no changes". That is accepted: it reveals only that the review names another tenant, which the omitted
  tenant ids already imply (ISS-1021 3.1). No marker key is added (allowlist and nine-key envelope invariants stay).

### 3.3 All-or-nothing, not per entry or per side

ISS-1021's candidate (ii), "the same rule per entry side", is rejected. An entry is a diff of the target graph (`before`) against the source graph (`after`); an
entry of change_kind `modified` holds both sides, and `variable_schema`, `service_binding` and `module_ref` entries mix both. There is no per-entry owner. A plan
with one foreign side therefore yields `[]` entirely. (Candidate (i) is the rule of 3.1.)

### 3.4 Missing or non-binary tenant id in the stored plan: fail closed, `entries: []`

Covered by 3.1: the gate demands a binary own id under BOTH keys, so a legacy plan lacking one or both keys, with `null`, a number, a list or an object there, or a
foreign id, gets `[]`. `Map.get(plan, key)` returning `nil` for a missing key is rejected by `own_tenant_value?/2`'s second clause (false for non-binary). Operator view:
unchanged for every shape (including these).

### 3.5 The ISS-1021 foreign-side definition id rule stays, unchanged

`source_definition_id` / `target_definition_id` OWN-SIDE gating (ISS-1021 3.1, OQ-1 ratified) is orthogonal: it decides per side whether a row id is shown; the new
gate decides whether the whole diff is shown. Example: source own, target foreign: `source_tenant_id` and `source_definition_id` shown, `target_tenant_id` and
`target_definition_id` omitted, `entries` `[]`. No change to `@plan_allowlist`'s `plain`, `own_tenant`, `own_side` values, to `process_key` / `base_version`
(residual R4, see section 8 R8), to `requested_by` (R5), to `plan_digest` (R6) or to the envelope's nine keys.

### 3.6 Operator view unchanged

`shape_plan(plan, :operator)` still returns the decoded plan unchanged (`promotions.ex:1078`); `tenant_view/1` stays the authority (recomputed from
`auth_context`; pin unset or a caller outside P is a non-operator). Operator `entries` equals the stored `entries`.

### 3.7 What an own-tenant review still shows

When both stored ids equal the caller's own tenant id, `entries` is returned as stored, nothing descended, nothing stripped (ISS-1021 3.3 minus its exception). This is
the SPA's review content. Tenant-authored free-form content inside the caller's OWN graphs is the caller's own data, so it is not a cross-tenant disclosure (residual
R1b, accepted, section 8).

## 4. Interfaces (private unless noted, `lib/letflow/routers/promotions.ex`; arities may be adjusted by ELIXIR-DEV)

* `@plan_allowlist` gains ONE key, `entries_gate`: `[String.t()]`, literal `["source_tenant_id", "target_tenant_id"]`. The other four keys (`plain`, `own_tenant`,
  `own_side`, `entries`) are unchanged. The `# -- Response allowlist (INV-2) --` comment (lines 1046-1053) is rewritten: `entries` is kept only when it is a list AND
  every `entries_gate` tenant id is the caller's own (this design, INV-10); otherwise `[]`.
* `plan_allowlist() :: %{plain: [String.t()], own_tenant: [String.t()], own_side: %{String.t() => String.t()}, entries: String.t(), entries_gate: [String.t()]}`
  (public, `@doc false`, test seam; existing function, `@spec` widened by one key).
* `entries_visible?(plan :: map(), own :: String.t() | nil) :: boolean()`: NEW private predicate; true iff every key of `entries_gate` is present in `plan` and its
  value satisfies `own_tenant_value?/2`. Pure, no database access, no logging.
* `shape_plan(plan :: term(), view :: tenant_view()) :: term()`: existing name, arity and clauses; the non-operator map clause's last step (the entries step) returns
  the stored list when it is a list AND `entries_visible?/2` is true, else `[]`. Always a new hand-built map. `shape_plan(plan, :operator)` and the non-map clause
  unchanged.
* `review_context_map/2`: unchanged (nine keys, still decodes with `Jason.decode!/1`).
* Moduledoc sentence at `promotions.ex:82-88` ("`entries` as stored (`[]` when absent or not a list)") is rewritten to: `entries` as stored only when both stored
  tenant ids are the caller's own, `[]` otherwise (ISS-1023); the rest of the sentence unchanged.

Invariants (additions to ISS-1021 I-1..I-7; none removed): (I-8) for a non-operator, `entries` is non-empty only if both stored `source_tenant_id` and
`target_tenant_id` equal the caller's own tenant id case-insensitively; (I-9) a non-operator response whose `entries` is non-empty also contains both own tenant ids
(the gate and the shown ids use the same test); (I-10) `entries_gate` is a subset of `own_tenant`; (I-11) no other key, status code or envelope key changes; no
database access, nothing logged with ids.

## 5. Acceptance-criteria map

| Acceptance criterion | Design element | Test |
|---|---|---|
| Non-operator: `entries` as stored only when BOTH ids are own (case-insensitive, same `own_tenant_value?/2`), else `[]` (decided: `[]`, 3.2) | 3.1, 3.2, 3.3, 4 (`entries_gate`, `entries_visible?/2`, `shape_plan/2`), I-8 | T-13 `foreign_reviews_entries_are_empty_for_a_non_operator_reader_in_p`, `one_foreign_side_is_enough_to_withhold_entries`, `own_ids_case_insensitive_keep_entries`; T-8 `context_omits_foreign_tenant_ids_for_non_operator` (updated) |
| Operator sees everything unchanged | 3.6, I-7 | T-13 `operator_reads_the_same_foreign_review_with_entries_unchanged`, existing T-8 `context_unchanged_for_operator`, T-11 `operator_sees_all_unchanged` |
| Two-tenant test: operator-created review B to C in P's schema; a P-held `:PromotionsRead` role sees `entries == []` and no graph content of B or C anywhere in the raw body; own-tenant reviews still show entries | section 6 file 3 (recipe) | T-13 `foreign_reviews_entries_are_empty_for_a_non_operator_reader_in_p`, `own_tenant_reviews_still_show_entries` |
| Legacy rows (missing/non-binary/foreign ids) fail closed | 3.4 | T-13 `legacy_plans_with_missing_or_non_binary_tenant_ids_fail_closed` |
| T-8/T-11 of ISS-1021 updated | section 6 files 2 and 3b | T-8 (one assertion flips), T-11 (comment and one added assertion) |
| AC5 recorded: do non-admin platform-tenant users hold `:PromotionsRead` | section 2 (file:line), pinned by a test | T-13 `non_admin_core_roles_in_the_platform_tenant_are_denied_promotions_read` |
| SECURITY-REVIEWER verdict recorded | workflow step, recorded in the PR and `docs/issues/ISS-1023.yaml` | not a code element |

## 6. Files to change

1. `lib/letflow/routers/promotions.ex` (the only `lib/` file): per section 4. No other `lib/` file. No migration. No SPA change: the SPA reads `serialised_plan.entries`
   and re-serialises the object for display; `[]` is already a valid value (ISS-1021 section 7, which also found no other reader of the shaped plan).
2. `test/letflow/routers/promotion_context_shaping_test.exs` (T-8, updated; nothing else in the file changes):
   * `context_omits_foreign_tenant_ids_for_non_operator` (review in A's schema, source B, target A): the line `assert shaped["entries"] == plan.entries |> Jason.encode!() |>
     Jason.decode!()` is REPLACED by `assert shaped["entries"] == []`. All other assertions stay (`target_tenant_id`, `target_definition_id`, `process_key`, `base_version`,
     `requested_by`, `refute resp.resp_body =~ ctx.b.tenant_id`).
   * `context_unknown_top_level_keys_dropped_and_entries_not_descended` (A source, A target, B's id typed INSIDE entries): unchanged. Both sides are own, so the entries
     stay as stored, which is exactly what its inline comment says; the comment "(known, accepted residual: not descended)" is reworded to "(both sides own: kept as stored; residual R1b,
     the caller's own free-form content)". The test name stays.
   * `context_other_keys_and_status_unchanged`, `context_unchanged_for_operator`: unchanged.
   * Moduledoc: the clause "and `entries` as stored (not descended: residual R1)" becomes "and `entries` only when both plan tenant ids are the caller's own (ISS-1023), as stored
     and not descended; `[]` otherwise"; add the pointer to `test/specs/ISS-1023.md`.
3. `test/letflow/routers/promotion_context_allowlist_test.exs` (T-11): NO assertion fails against the new rule (verified by reading every case at 3204c418: the cases
   with a foreign side - `foreign_side_definition_id_omitted_own_side_kept`, `null_definition_id_omitted_for_foreign_side_kept_for_own_side`,
   `pin_unset_would_be_operator_is_shaped_like_everyone_else`, `envelope_has_nine_keys_for_both_views` - assert no value of `entries`; the cases that assert `entries` are
   A/A or have `entries: []`). Updates, all additive or comment-only:
   * `entries_kept_exactly_as_stored` (A/A): the comment "known, accepted, tracked residual R1: nothing inside `entries` is shaped" becomes "both sides own: kept exactly as stored
     (residual R1b); a foreign side is T-13"; assertions unchanged.
   * `pin_unset_would_be_operator_is_shaped_like_everyone_else` (seeded P source B... target P): ADD `assert plan["entries"] == []` (source is B, foreign), strengthening it.
   * `foreign_side_definition_id_omitted_own_side_kept`: ADD inside the loop `assert (plan["entries"] != []) == (source == a and target == a)` (the stored default entry is one
     element, so non-empty only for the A/A case; the four combinations A/A, B/A, A/B, B/B are all in the loop).
   * Moduledoc: replace "`entries` as stored" by "`entries` as stored only when both plan tenant ids are own (ISS-1023)".
   3b. This is what "T-8/T-11 are updated" (issue AC) means: T-8 one flipped assertion, T-11 two added assertions; the T-8 `meta`/entries cases do not flip (A/A).
4. `test/letflow/routers/promotion_context_entries_scope_test.exs` (T-13, NEW, module `Letflow.Routers.PromotionContextEntriesScopeTest`, `use Letflow.DataCase, async: false`,
   aliases as T-11: `Fixture` = `Letflow.Support.PlatformTenantFixture`, `Scope` = `Letflow.Support.PromotionScopeFixture`; `import Ecto.Query`, `alias Letflow.Definitions.PromotionReview`):
   * setup: `Fixture.three_tenants!/0` (`ctx.p`, `ctx.a`, `ctx.b`) and `Fixture.pin!(ctx.p.tenant_id)`. Naming: the issue's B (source) is `ctx.b`, the issue's C (target) is `ctx.a`;
     both are foreign to P. (No fourth tenant is provisioned; the review is a plain row naming two other schemas.)
   * private helpers, copied from T-11 (the repo copies per file until a third file needs them, see `PromotionScopeFixture` moduledoc): `context_resp(fixture, review_id, roles)`
     (router dispatch through `Fixture.router_conn(:get, "/#{id}/context", fixture, roles, nil)` and `Letflow.Routers.Promotions.call/2`; default roles `["PLATFORM_ADMIN"]`),
     `read_plan!/2` returning `{raw_body, serialised_plan}` after `assert resp.status == 200`, `overwrite_plan!/3` (an `Ecto.Query` update on `PromotionReview` filtered by `r.id == ^review_id`
     executed with `Repo.update_all(query, [set: [serialised_plan: json_text]], prefix: fixture.schema_name)`, asserting `{1, _}`), `seed_and_overwrite!(fixture, json_text)`
     (`Scope.seed_review!(fixture, fixture.tenant_id, fixture.tenant_id)` then `overwrite_plan!`).
   * `markers(ctx)` private helper returning the graph-content strings that must never reach the reader. Seed `entries` override (`Scope.seed_review!/4` merges overrides into the
     seven default keys and digests the result, so atoms and strings both work; the stored form is what T-11 `entries_kept_exactly_as_stored` already uses): two entries,
     `%{type: :graph_node, id: "n-iss1023-b", change_kind: :added, before: nil, after: %{"id" => "n-iss1023-b", "node_type" => "SERVICE_TASK", "service_id" => "svc-iss1023-b-secret",
     "label" => "B-ONLY-LABEL-iss1023", "tenant_id" => b_id}}` and `%{type: :service_binding, id: "n-iss1023-c", change_kind: :modified, before: %{"service_id" => "svc-iss1023-c-before"},
     after: %{"service_id" => "svc-iss1023-c-after", "owner" => c_id}}`. Raw-body refutations (every one, each searched case-sensitive and `String.upcase/1`'d where it is a uuid):
     `b_id`, `c_id`, `n-iss1023-b`, `n-iss1023-c`, `svc-iss1023-b-secret`, `svc-iss1023-c-before`, `svc-iss1023-c-after`, `B-ONLY-LABEL-iss1023`, and the two definition ids seeded through
     the `source_definition_id` and `target_definition_id` overrides (two fresh `Ecto.UUID.generate/0` values). `process_key` is NOT in the list (residual R4/R8, OQ-2): the seeded
     key is `Scope.unique_key("iss1023-key")` via override and is excluded from the marker set on purpose.
   Cases:
   * `operator_reads_the_same_foreign_review_with_entries_unchanged`: with the pin on P, seed `Scope.seed_review!(ctx.p, ctx.b.tenant_id, ctx.a.tenant_id, overrides)` (the operator-created
     review, written through the real `PromotionReviewStore.insert_review/2` with P's schema prefix, the same path the submit handler uses for the operator); read as `ctx.p` with
     `["PLATFORM_ADMIN"]` (operator, pin on P): status 200, `serialised_plan["entries"] ==` the stored entries JSON-round-tripped (`Jason.encode!/1 |> Jason.decode!/1`), and the raw body
     CONTAINS every marker (this makes the next test non-vacuous).
   * `foreign_reviews_entries_are_empty_for_a_non_operator_reader_in_p` (the AC test): seed as above; then `Fixture.unpin!()`; read as `ctx.p` with `["PLATFORM_ADMIN"]` (the one role that holds
     `:PromotionsRead` today, section 2: with no pin on P it is a non-operator, `tenant_view/1`); assert status 200, `serialised_plan["entries"] == []`, `refute raw =~` each marker from
     `markers/1`, `refute raw =~ b_id`, `refute raw =~ c_id`, and `serialised_plan` keys subset of the seven allowlisted keys (reuse the literal list of T-11). Do the same for the three plan
     tenant combos (B source / C target; C source / B target) in a loop. The reader's role is stated in the test's comment: `PLATFORM_ADMIN` of P, pin cleared; REQ-447's `TENANT_ADMIN` /
     `TENANT_AUDITOR` of P are covered by the same code path and are NOT used because the roles do not exist in `lib/` (section 2).
   * `one_foreign_side_is_enough_to_withhold_entries`: with the pin cleared, in P's schema seed (P source, B target), (B source, P target) and (P source, P target); the first two read `[]`
     with no marker in the body; the third reads the stored entries (this is the control). Markers: the entries override of the case, with `b_id` appearing as a graph value in the first two.
   * `own_tenant_reviews_still_show_entries`: both reviews seeded in A's schema and read as `ctx.a` with `["PLATFORM_ADMIN"]` (pin on P, so A's admin is a non-operator): (A source, A target)
     returns the stored entries (JSON-round-tripped equality) and `serialised_plan["source_tenant_id"] == ctx.a.tenant_id`, and the P/P review in P's schema read with the pin cleared as
     `ctx.p` returns the stored entries. Both prove the fix does not over-withhold.
   * `own_ids_case_insensitive_keep_entries`: seed (upper-cased A id, A id) in A's schema (`String.upcase(ctx.a.tenant_id)`, assert it differs first as T-11 does): entries as stored.
   * `legacy_plans_with_missing_or_non_binary_tenant_ids_fail_closed`: for each `json_text` below, `seed_and_overwrite!(ctx.a, json_text)` (a legacy row in A's own schema, read as A's
     `PLATFORM_ADMIN`, pin on P): `serialised_plan["entries"] == []` and the raw body contains no marker. `<A>` is `ctx.a.tenant_id`, `<E>` the single-entry JSON text
     `[{"type":"graph_node","id":"n-iss1023-legacy","change_kind":"added","before":null,"after":{"label":"LEGACY-MARKER-iss1023"}}]` (`refute raw =~ "LEGACY-MARKER-iss1023"`):
       * both ids missing: `{"process_key":"p","entries":<E>}`
       * source missing: `{"process_key":"p","target_tenant_id":"<A>","entries":<E>}`
       * target missing: `{"process_key":"p","source_tenant_id":"<A>","entries":<E>}`
       * source `null`: `{"source_tenant_id":null,"target_tenant_id":"<A>","entries":<E>}`
       * source a number, a list `["<A>"]`, an object `{"id":"<A>"}`, a boolean (four texts): same shape, `target_tenant_id` own
       * target same four shapes, `source_tenant_id` own
       * foreign source (`ctx.b.tenant_id`), own target; own source, foreign target; both foreign
       * whitespace and prefix variants: `" <A>"`, `"<A> "`, `""` under source with own target (fail closed: not equal after downcase)
       * odd keys only (`tenantId`, `tenant_ids`) naming A and no source/target keys: still `[]`
       and one positive control in the same test: both ids own with `<E>`: `serialised_plan["entries"]` is the decoded `<E>` (not empty), asserting the fixture text itself would be shown.
     Operator view of one of these texts (`seed_and_overwrite!(ctx.p, text)` read as `ctx.p` with the pin on P): the decoded stored plan unchanged.
   * `withheld_entries_leave_the_rest_of_the_response_unchanged`: for the B/C review read with the pin cleared: the envelope has exactly the nine keys (literal list of T-11), `status == "pending_review"`,
     `serialised_plan` has no tenant id key (both foreign), `process_key` present (R8, pinned as documentation), `entries == []`.
   * `non_admin_core_roles_in_the_platform_tenant_are_denied_promotions_read` (AC5 pin): with the pin on P, for each role in `["PROCESS_DESIGNER"]`, `["PROCESS_OPERATOR"]`, `["TASK_WORKER"]`,
     `["AGENT_RUNNER"]`, `["CANDIDATE"]`, `["TENANT_ADMIN"]`, `["TENANT_AUDITOR"]`, `[]` read the operator-created B/C review's `/context` as `ctx.p` with those roles: status 403 (the status
     `promotion_scope_test.exs` asserts for "every other role"; TEST-DESIGNER confirms the exact status and body at write time, and the test asserts the raw body contains no marker). Comment: the
     unknown role strings resolve to no role today (`role_from_string/1`, `authorization.ex:597-603`); when REQ-447 adds `TENANT_ADMIN` with `PromotionsRead`, this test's `TENANT_ADMIN` and
     `TENANT_AUDITOR` rows must be MOVED to the allowed side and re-asserted against the new rule (they then become non-operator readers and must read `entries == []`): the comment says so.
5. `test/letflow/routers/promotion_context_allowlist_drift_test.exs` (T-12, updated): `allowlist_matches_the_literal_table` ADDS the literal `@entries_gate ["source_tenant_id", "target_tenant_id"]` and
   `assert Enum.sort(allowlist.entries_gate) == @entries_gate`; ADD `entries_gate_is_the_own_tenant_pair`: `Enum.sort(allowlist.entries_gate) == Enum.sort(allowlist.own_tenant)` and
   `Enum.all?(allowlist.entries_gate, &(&1 in allowlist.own_tenant))` (a new tenant-id key added to `own_tenant` fails this until a person decides whether it must also gate `entries`).
   `allowlist_covers_exactly_the_keys_the_plan_builder_emits` and `class_sets_are_disjoint` are unchanged (`entries_gate` references keys, it is not a key class).
6. `test/specs/ISS-1023.md` (TEST-DESIGNER, NEW): criterion-to-test table (section 5); the fail-first note (against the as-stored rule T-13 `foreign_reviews_*`, `one_foreign_side_*`, `legacy_*` and the
   T-8 flipped assertion fail); a mutation table (suggested mutants, one `promotions.ex` line each: M1 gate dropped, entries always as stored; M2 only `source_tenant_id` checked; M3 only `target_tenant_id`
   checked; M4 exact-case comparison instead of `own_tenant_value?/2`; M5 a missing/non-binary id treated as own (the `nil` clause); M6 operator gated; M7 `entries` forced to `[]` always for non-operators
   (killed by the own-tenant tests); M8 gate evaluated on the SHOWN keys but `entries_gate` emptied; M9 non-list `entries` passed through); the residual list of section 8; and a section titled
   "Note on ISS-1021 residual R1 (superseded by ISS-1023)" holding the new R1 text. The existing `test/specs/ISS-1021.md` is NOT edited (historical spec; the note lives in the new file).
7. `docs/issues/ISS-1023.yaml` (NEW; fields as `docs/issues/ISS-1021.yaml`: `id: ISS-1023`, `title`, `discovered_by: SECURITY-REVIEWER (ISS-1021, Q-1003)`, `discovered_in_run:
   WF03-ISS1021-Q1003-20261006`, `discovered_at`, `severity: MAJOR`, `failure_class: defect`, `occurrence: 1`, `owner: ELIXIR-DEV`, `description` (the problem of section 1 and the fix of 3.1),
   `affected_files` (every file in this list plus `lib/letflow/design/iss1023-context-entries-own-sides.md`), `regression_test:
   test/letflow/routers/promotion_context_entries_scope_test.exs`, `follow_ups` (R1b, R8, R9, R10 approve/reject not gated by stored ids, the `own == ""` INFO, REQ-447 ordering note OQ-6), `status`, `resolved_in_run`, `resolved_at`, `resolution`).
   Required refs: `queue_ref: Q-1005` and `github_ref: GH-2297` (both match the `Q-<n>` / `GH-<n>` form of `mix letflow.check_issue_refs`, rules R1/R3), with a YAML comment above
   `queue_ref`: "The queue's own issue_ref for Q-1005 came back ISS-1005, which clashes with the local numbering: docs/issues/ISS-1005.yaml already exists and is an unrelated Vortex scenario issue
   (PROCESS-AUDITOR finding PA-VORTEX-005). The queue number was read as a local issue number by mistake. ISS-1023 is the local id, chosen because ISS-1021's follow_ups,
   test/specs/ISS-1021.md R1 and decision 0046 already cite it as the tracking id." (Same comment pattern as ISS-1021.yaml and ISS-0999.yaml.) `resolved_in_run` / `resolved_at` are
   written by the pipeline at merge time from the real run id and the clock, not guessed. SECURITY-REVIEWER and REVIEWER verdicts go in `resolution`, as in ISS-1021.yaml.
   `docs/issues/ISS-1021.yaml` is NOT edited (resolved record; its `follow_ups` already names ISS-1023).
8. `docs/migration/decisions/0046-admin-scopes-and-role-charter.md`: append-only dated section "Closure of the /context entries residual (ISS-1023 / Q-1005), <real UTC date of the merge>".
   Required, because the 0046 ISS-1021 closure section (the last section of the file) ends with "Remaining STANDING TRACKED exception R1 (INV-10), not closed here ... Tracked as Q-1005 / GH #2297 /
   ISS-1023", which becomes false when this merges. Content: no earlier text changed and no decision text changed; R1 of the ISS-1021 closure is closed for plans naming a foreign tenant; design
   `lib/letflow/design/iss1023-context-entries-own-sides.md`; the new rule in one sentence per 3.1, the `[]` decision (3.2), all-or-nothing (3.3); the AC5 finding of section 2 stated plainly
   (only `PLATFORM_ADMIN` holds `:PromotionsRead` today; TENANT_ADMIN / TENANT_AUDITOR planned, REQ-447; this fix is a precondition of that grant); what remains: R1b (own free-form content),
   R4/R8 (`process_key`, `base_version`, `def_id` of a foreign plan), R3 (`teardown_error` text on other review routes), R5 (`requested_by`), R6 (`plan_digest`), R9 (`entries == []` reveals that the
   review names another tenant, accepted), R10 (approve/reject not gated by stored ids; own schema only, apply stays blocked; optional separate hardening). The section also records: the REQ-447 ordering
   note (REQ-447 must be ordered after this fix, because any grant of `:PromotionsRead` to `TENANT_ADMIN`/`TENANT_AUDITOR` makes P's operator-created reviews readable by non-operators), and the INFO
   that `own_tenant_value?/2` accepts `own == ""` (unreachable through the route; optional hardening, not done here). It must NOT say approve/reject use the stored-id helper. Route scope and permission unchanged (tenant scope, `:PromotionsRead`).
9. Residual list update: carried by files 6, 7 and 8 (the new spec, the issue file, the 0046 section), per section 8 below. NOT edited: `lib/letflow/design/iss1021-context-plan-allowlist.md`,
   `test/specs/ISS-1021.md`, `docs/issues/ISS-1021.yaml`, the earlier 0046 sections (all historical; a note in the NEW files supersedes their R1 text). Also not changed: `docs/roles.md` (it does not
   describe the `/context` payload; the matrix rows stand), `docs/requirements.yaml` (OQ-6), `docs/frontend/`, `web/`.
10. Pre-merge check for ELIXIR-DEV: `mix letflow.check_issue_refs` passes; grep for `Q-1005 / GH #2297 / ISS-1023` finds the placeholder text of ISS-1021's records and now resolves to a real `docs/issues/ISS-1023.yaml`;
    `mix format --check-formatted` and `mix compile --warnings-as-errors`; run the four route test files (T-8, T-11, T-12, T-13) and `promotion_scope_test.exs`, `req077_promotion_pipeline_test.exs` locally
    in the CI-shaped partition before pushing (merge discipline, `core-directives.md`).

## 7. SPA and other readers

Unchanged from ISS-1021 section 7. The `/context` response is the only reader of the shaped plan. The SPA prints the whole `serialised_plan` and iterates `entries`; for a non-operator reading a review
that names a foreign tenant it now shows an empty diff. Apply and run-assertions by that reader are already 404 for a foreign-named stored review; approve and reject are NOT gated by stored ids (3.2, R10). No `web/` work; no FRONTEND-DEV task.

## 8. Residuals after this change (named for REVIEWER and SECURITY-REVIEWER)

* R1 (ISS-1021) CLOSED for plans naming a foreign tenant: a non-operator no longer receives another tenant's graph content through `entries`.
* R1b (accepted, replaces R1): when BOTH stored tenant ids are the caller's own, `entries` is returned exactly as stored and nothing inside is scanned, so any id a tenant author typed into one of the
  caller's OWN nodes is returned to that same tenant. It is the caller's own content (not a cross-tenant disclosure); the stored plan cannot hold another tenant's graph because the plan builder
  reads only the two named tenants' graphs. Pinned as documentation by T-8 `context_unknown_top_level_keys_dropped_and_entries_not_descended` and T-11 `entries_kept_exactly_as_stored`.
* R4 (unchanged, accepted) / R8 (new, accepted, OQ-2): `process_key` and `base_version` (and the envelope's `def_id`, the same string) are still returned to a non-operator for a review naming foreign tenants. They
  are the NAME and version of the definition being promoted, tenant-authored text, not graph content and not an identifier of another tenant; the review is a record in the reader's own schema and its
  `def_id` appears in `GET /promotions` too. Withholding them would change the nine-key envelope and the list route.
* R5 (unchanged): `requested_by`, a user id of the review's own schema (for an operator-created review read in P, the operator's user id).
* R6 (unchanged): `plan_digest` covers the unshaped plan; a non-operator cannot verify it from the shaped plan (already so).
* R9 (new, accepted by SECURITY-REVIEWER): a non-operator can infer from `entries == []` that the review names another tenant (a builder never stores `[]`). That is already implied by the omitted tenant ids (ISS-1021 3.1).
* R3, R7 (ISS-1021, unchanged): `teardown_error` text on other review routes; the definition-id behaviour change.
* R10 (new, accepted by SECURITY-REVIEWER, optional separate hardening): `handle_approve` (`promotions.ex:572-592`) and `handle_reject` (`:609-626`) do not check the stored tenant ids
  (`stored_tenants_authorized?/3`, called only by apply `:645` and run-assertions `:779`). A non-operator `:PromotionsManage` holder can approve or reject a foreign-named review in its own
  schema and learns only the status; no cross-tenant data or write. Not changed here; tracking is ORCH's call.
* INFO (not done here, optional hardening): `own_tenant_value?/2` returns true for `own == ""` with `value == ""`; unreachable through the route (`Authorize` rejects a tenant id that cannot be resolved,
  ISS-1021 OQ-5), so the new gate cannot be satisfied by an empty id in practice.
* Residuals to name in the PR, the 0046 section and `test/specs/ISS-1023.md`: R1b, R3, R4/R8, R5, R6, R9, R10 (and the INFO).

## 9. Open questions (none silently resolved; defaults stated)

* OQ-1: `[]` versus an unreadable (404) review. DECIDED `[]` (3.2). RATIFIED by SECURITY-REVIEWER (`[]`, not 404).
* OQ-2: whether `process_key`, `base_version` and `def_id` of a foreign-named plan should also be withheld for a non-operator (R4/R8). RATIFIED by SECURITY-REVIEWER: they stay; R8 is an accepted residual.
  Withholding would be a separate issue because it changes the nine-key envelope and `GET /promotions`.
* OQ-3: gate on the STORED values (default, 3.1) versus on the shown values; identical today because both use `own_tenant_value?/2`. RATIFIED by SECURITY-REVIEWER: the gate reads the stored plan, not the
  shown keys, so a future change to which ids are shown cannot widen `entries`.
* OQ-4: the `entries_gate` list lives in `@plan_allowlist` (default, so T-12 pins it literally) versus deriving the gate from `own_tenant` in code. Default chosen so a person must classify a new tenant-id key.
* OQ-5: the T-13 reader is `PLATFORM_ADMIN` of P with the pin cleared, the only role holding `:PromotionsRead` today (section 2). Alternative reader (pin on another tenant) gives the same `tenant_view/1` result;
  not used because `Fixture.unpin!/0` is the established idiom of T-11.
* OQ-6: ORDERING NOTE (SECURITY-REVIEWER): REQ-447 (pending) grants `PromotionsRead` to `TENANT_ADMIN` / `TENANT_AUDITOR`, and any such grant makes P's operator-created reviews readable by
  non-operators, so REQ-447 MUST be ordered after this fix. `docs/requirements.yaml` is not edited here (no `depends_on` change in this issue); ORCH records the ordering. The AC5 test
  (`non_admin_core_roles_...`) is the tripwire when the matrix changes.
* OQ-7: helper duplication (`overwrite_plan!/3`, `seed_and_overwrite!/2`) in T-11 and T-13. Default: copy (two files). If a third file needs it, lift into `Letflow.Support.PromotionScopeFixture`.
* OQ-9: gate approve/reject by the stored tenant ids (R10)? Default: not in this issue (no cross-tenant exposure, own schema only); optional separate hardening, ORCH's call to track.
* OQ-10 (INFO): reject `own == ""` in `own_tenant_value?/2`? Default: not done (unreachable through the route); optional hardening.
* OQ-8: the queue's `ISS-1005` number is not the local issue number (verified: `docs/issues/ISS-1005.yaml` exists and is an unrelated Vortex scenario issue); the YAML comment records it, the local id stays ISS-1023.
