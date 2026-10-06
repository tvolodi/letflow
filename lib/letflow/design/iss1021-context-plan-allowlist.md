# Design: ISS-1021 (Q-1003 / GH #2291) - allowlist of `serialised_plan` keys on GET /promotions/:id/context

Owner: ELIXIR-DEV. Severity MEDIUM (INV-10, INV-2). Size S3. Depends on ISS-0999 (Q-981 / GH #2266), merged at 1177a315.
Design only: signatures, key tables and rules; no implementation code.

## 1. Problem (read of the code at 1177a315)

`GET /promotions/:id/context` (tenant scope `:PromotionsRead`) returns the decoded `serialised_plan` through `shape_plan/2` (`lib/letflow/routers/promotions.ex:1071-1079`),
which calls the key-suffix DENY walk `shape_tenant_ids/2` (`:1050-1067`) over every top-level key except `entries`. The walk drops only keys whose name ends in
`tenant_id` and whose value is not the caller's own id. A foreign tenant id under any other key name (`tenantId`, `tenant_ids`, `source_tenant`, a future
producer's key) passes. Same defect class ISS-0999 closed for platform-events. Two more gaps found while reading:

* a decoded plan that is not a map (a JSON list, string, number or `null`) passes through `shape_plan/2` clause 3 completely unshaped;
* `source_definition_id` and `target_definition_id` are row ids in the source / target tenant's schema. For a review naming a foreign tenant (a legacy row, or an
  operator review read by a non-operator reader of the platform schema, REQ-446 OQ-9) they are foreign identifiers (INV-10).

Fix: invert to an ALLOWLIST over the top-level keys of the decoded plan (INV-2: field selection before serialisation, hand-built map).

## 2. What the plan builder emits (the allowlist's source of truth)

The only producer of a stored plan is `PromotionReviewStore.insert_review/2` (`definitions/promotion_review_store.ex:398`): `Jason.encode!(plan)` where `plan`
is `PromotionPlan.t()` (verified against its digest first). `PromotionPlan.compute_promotion_plan/5` (`definitions/promotion_plan.ex:152-161`) builds exactly seven
keys, and `@type t` (`:51-59`) lists the same seven. After `Jason.decode!` they are string keys:

| Top-level key | Value (decoded) | What it identifies |
|---|---|---|
| `source_tenant_id` | string (tenant UUID) | a tenant id: source side |
| `target_tenant_id` | string (tenant UUID) | a tenant id: target side |
| `process_key` | string | the definition name (tenant-authored text) |
| `source_definition_id` | string UUID or `null` | row id in the SOURCE tenant's `process_definitions` |
| `target_definition_id` | string UUID or `null` | row id in the TARGET tenant's `process_definitions` |
| `base_version` | string or `null` | target's active version (tenant-authored text) |
| `entries` | list of `{type, id, change_kind, before, after}` maps | before/after definition graph JSON |

No other key is emitted. The digest (`PromotionDigest.compute_plan_digest/1`) is over the same plan, so a producer cannot add a key without going through the
digest module. `Promotion.promote_definition/3` (`promotion.ex:161`) reads the stored plan itself; it never goes through the router shaping, so shaping the
response cannot affect promotion.

## 3. Decisions

### 3.1 Allowlist for a non-operator (key classes)

For `{:tenant, own}` the response `serialised_plan` is a NEW map built from exactly the keys below. Every other top-level key is omitted (never copied).

| Class | Keys | Kept when |
|---|---|---|
| PLAIN | `process_key`, `base_version` | value is a scalar (binary, number, boolean, null); otherwise omitted |
| OWN-TENANT | `source_tenant_id`, `target_tenant_id` | value is a binary equal, case-insensitively, to `own` (`own_tenant_value?/2`, existing); otherwise omitted. Returned as stored (case preserved) |
| OWN-SIDE | `source_definition_id` (gated by `source_tenant_id`), `target_definition_id` (gated by `target_tenant_id`) | the definition id is a scalar AND the gating tenant-id key of the same plan passes the OWN-TENANT test; otherwise omitted |
| ENTRIES | `entries` | present and a list: kept exactly as stored (see 3.3); otherwise replaced by `[]` (3.4) |

Why OWN-SIDE (the one place this design goes beyond the issue text, flagged OQ-1): a definition row id is in the schema of the tenant it belongs to. It is
safe exactly when that tenant is the caller's own, and the plan states which tenant that is. For an own-tenant promotion review (the normal case) the caller
still sees both ids as today; for a review naming a foreign tenant the foreign side's id is omitted. This is stateless, needs no database access and fails
closed when the tenant-id key is missing, non-binary or foreign. It is consistent with ISS-0999 3.1, which omitted `source_definition_id` from events for the
same reason. A `null` definition id is kept only when its gating tenant id is own (omitting a `null` loses nothing; keeping it for a foreign side would
reveal "no such definition" for that tenant, so omit).

`requested_by` and the other envelope keys: see 3.5.

### 3.2 Unknown top-level keys, odd key names

Anything not in 3.1 never reaches a non-operator: `tenantId`, `tenant_ids`, `source_tenant`, `x_tenant_id`, `meta`, `origin_tenant_id`, a future key. No
suffix matching, no recursion outside `entries`. An allowlisted key holding a map or list (other than `entries`) is omitted (the scalar rule).

### 3.3 `entries`: kept as stored, nothing descended (standing TRACKED exception R1)

`entries` is the plan's `before`/`after` definition graph JSON, tenant-authored free-form content. It is copied as the decoded list, unmodified: no key is
dropped inside, no walk (the old behaviour also did not descend). Reasons: (a) it is the content the reviewer exists to see (the SPA reads
`serialised_plan.entries`, `web/src/api/promotions.ts:116,161`); (b) the plan builder injects no tenant-id key into it; (c) it is not scanned or reshaped by the old walk either, so this change is no worse than before. CORRECTION (SECURITY-REVIEWER, ISS-1021 review): an earlier
draft justified `entries` as "the caller's own tenant data". That is FALSE for one case. `build_entries` (`promotion_plan.ex:199-243`) fills `entries` from BOTH
the source and the target graphs, plus variable schemas, service bindings and module refs. An operator-created review naming foreign tenants B and C is stored in
the PLATFORM tenant's schema (`insert_review/2` uses the caller's `opts`; a non-operator can only name its own tenant, through the `tenants_authorized?` gate,
`promotions.ex:303,314`). A non-operator reader holding `:PromotionsRead` in that schema (and a reader of a legacy row) therefore receives B's and C's definition
graph content: other tenants' business data and any ids a tenant author typed into a node. That conflicts with INV-10 ("no other tenant's data or
identifiers"). It stays residual R1, now recorded as a standing TRACKED exception with the follow-up issue `Q-1005 / GH #2297 / ISS-1023` (placeholder in this design only;
the real id replaces it before merge). Candidate fixes recorded for that issue, NOT done here: (i) for a non-operator, return `entries` only when BOTH
`source_tenant_id` and `target_tenant_id` equal the caller's own, else `[]`; (ii) the same rule per entry side. Not verified and belonging to that issue: whether
non-admin platform-tenant users actually hold `:PromotionsRead`. T-8 already pins the as-stored behaviour as documentation.

### 3.4 Malformed and legacy plans (precise rules, non-operator only)

The decode step stays `Jason.decode!/1` (unchanged for both views). Then, for a non-operator:

| Decoded `serialised_plan` | Result |
|---|---|
| map with the seven keys | rules of 3.1 |
| map with unknown extra keys (legacy shape) | extra keys omitted; allowlisted keys by 3.1 |
| map missing allowlisted keys | only the present ones are kept; `entries` is always present in the output (`[]` when absent) |
| map whose `entries` is not a list | `entries` => `[]`; the original value is not copied |
| JSON list, string, number, boolean or `null` (not a map) | `%{"entries" => []}`; nothing from the stored value is copied |
| `{:tenant, nil}` (caller has no resolvable own tenant id) | no tenant-id key and no definition id kept; the rest by 3.1 |

`entries` is forced present so the SPA contract (`serialised_plan: { entries: PlanEntry[] }`) never sees `undefined`. Operator: the decoded term is returned
unchanged for every shape (including non-maps), as today. A `serialised_plan` column that is `nil` or not valid JSON still raises in `Jason.decode!/1`
(HTTP 500, no data in the body); this is existing behaviour for both views, the column is `validate_required` and always written by `Jason.encode!/1`, so it is
not producible through the application. Listed as OQ-3 (alternative: a safe decode returning the non-operator `%{"entries" => []}`).

### 3.5 Envelope keys unchanged

`review_context_map/2` keeps its nine keys (`review_id`, `plan_digest`, `serialised_plan`, `status`, `requested_by`, `def_type`, `def_id`, `created_at`,
`row_version`) for both views; only the `serialised_plan` value is built differently. `requested_by` (a user id of the review's own schema) is deliberately NOT
changed: the issue scopes only `serialised_plan`, ISS-0999 3.4 omitted `actor_id` on a different route for a different reason (events are written by
operators into the tenant's schema), and removing it from the nine-key envelope would break the AC "the nine-key envelope is unchanged" and the existing
`context_other_keys_and_status_unchanged` test. Residual R5 (section 8) records that it is a user id that, for an operator-created review read from the platform
schema, may belong to the operator. `plan_digest` is a hash of the UNshaped plan; a non-operator cannot recompute it from the shaped plan (already true today
because `source_tenant_id` is dropped); the SPA does not recompute (`digest_verified: true` default, `web/src/api/promotions.ts`). `def_id` is the
`process_key` (`insert_review/2` sets `def_id: plan.process_key`), same data as the plan's `process_key`.

### 3.6 Operator view unchanged

`tenant_view/1` stays the authority (`PlatformTenant.scope_facts_for/1`, recomputed; the stored flag is never read; pin unset or a caller outside the platform
tenant is a non-operator). Operator: `serialised_plan` is the decoded plan, byte-equal to the stored plan (existing `context_unchanged_for_operator`).

### 3.7 Dead code: `shape_tenant_ids/2` and `tenant_id_key?/1` are deleted

Grep over `lib/` and `test/` (all `.ex`/`.exs`) at 1177a315: `shape_tenant_ids/2` is called only from `shape_plan/2` (and its own recursion, `:1059,1065`);
`tenant_id_key?/1` only from `shape_tenant_ids/2` (`:1056`). ISS-0999 already removed the events call site (`report-2026-10-06-WF03-ISS0999.yaml` records it).
After this change neither has a caller, and no test references them (the T-7/T-8/T-9/T-10 files call the router, not the helpers; they are `defp`). They are DELETED
(the suffix rule has no remaining use; keeping a deny-walk invites a future caller to reuse the wrong tool). ELIXIR-DEV must re-run the grep before deleting
and keep them if a caller has appeared. Stay: `own_tenant_value?/2` (used by the events allowlist and the new plan allowlist), `scalar?/1`, `tenant_view/1`,
`@typep tenant_view`. The comment block above `shape_tenant_ids` ("INV-10 response shaping (REQ-446)") is rewritten to describe `tenant_view/1` and
`own_tenant_value?/2` only.

## 4. Interfaces (private, in `lib/letflow/routers/promotions.ex`; arities may be adjusted by ELIXIR-DEV)

* module attribute `@plan_allowlist :: %{plain: [String.t()], own_tenant: [String.t()], own_side: %{String.t() => String.t()}, entries: String.t()}` holding the
  table of 3.1 (literal: plain `["process_key", "base_version"]`, own_tenant `["source_tenant_id", "target_tenant_id"]`, own_side
  `%{"source_definition_id" => "source_tenant_id", "target_definition_id" => "target_tenant_id"}`, entries `"entries"`), with a
  `# -- Response allowlist (INV-2) --` comment citing this design and INV-10;
* `plan_allowlist() :: %{plain: [String.t()], own_tenant: [String.t()], own_side: %{String.t() => String.t()}, entries: String.t()}`: public, `@doc false`, returns
  that attribute; used only by the drift test (T-12), same pattern as `platform_event_allowlist/0`;
* `shape_plan(plan :: term(), view :: tenant_view()) :: term()` (existing name and arity, new body): `:operator` returns `plan` unchanged; `{:tenant, own}` returns
  a hand-built map per 3.1 and 3.4 (always a map for a non-operator, never the input value);
* `review_context_map(review, view) :: map()`: unchanged signature and key set; still calls `shape_plan/2` on `Jason.decode!(review.serialised_plan)`.

Invariants: (I-1) a non-operator `serialised_plan` key set is a subset of the seven allowlisted keys; (I-2) it is always a map containing `entries` as a list;
(I-3) it contains no tenant id other than the caller's own, and no definition id whose side's tenant is not the caller's own; (I-4) `entries` is the stored value,
unmodified, when it is a list; (I-5) the envelope has exactly the nine keys for both views; (I-6) no database access added, nothing logged with ids; (I-7) the
operator result equals the decoded stored plan.

## 5. Acceptance-criteria map

| Acceptance criterion | Design element | Test |
|---|---|---|
| non-operator `serialised_plan` built from an allowlist of top-level keys, `entries` as stored; unknown top-level key never reaches a non-operator | 3.1, 3.2, 3.3, 4 (`@plan_allowlist`, `shape_plan/2`), I-1, I-4 | T-8 updated, T-11, T-12 |
| `source_tenant_id`/`target_tenant_id` kept only when equal to own (case-insensitive), as today | 3.1 OWN-TENANT, `own_tenant_value?/2` | T-8 (existing), T-11 `own_tenant_ids_kept_case_insensitively` |
| odd key names `tenantId`, `tenant_ids`, `source_tenant`, `x_tenant_id` carrying B's id: none reaches A's admin; operator sees all unchanged; nine-key envelope unchanged | 3.2, 3.5, 3.6, I-1, I-5, I-7 | T-11 `odd_tenant_keys_never_reach_a_non_operator`, T-8 envelope and operator tests |
| existing T-8 tests updated | section 6 file 2 | T-8 |
| SECURITY-REVIEWER verdict recorded | workflow step, recorded in the PR and `docs/issues/ISS-1021.yaml` | not a code element |

## 6. Files to change

1. `lib/letflow/routers/promotions.ex` (the only `lib/` file): add `@plan_allowlist` and `plan_allowlist/0`; rewrite `shape_plan/2`; delete `shape_tenant_ids/2`
   and `tenant_id_key?/1`; rewrite the comment block above them; update the moduledoc sentence at `:82-85` ("The R4 `serialised_plan` is still shaped by the
   key-suffix rule ...") to say the plan is an allowlist (R4 `serialised_plan` keys: `process_key`, `base_version`, own tenant ids, own-side definition ids,
   `entries` as stored; operators see it unchanged) and drop the "(R4 does not descend into `entries`)" clause. Update the `review_context_map/2` `PROVENANCE`
   comment only if it mentions the walk (it does not).
2. `test/letflow/routers/promotion_context_shaping_test.exs` (T-8, updated). Every existing assertion:
   * `context_omits_foreign_tenant_ids_for_non_operator` (review A target, B source): stays valid unchanged EXCEPT `shaped["source_definition_id"] ==
     plan.source_definition_id` (source is B, foreign): REPLACED by `Map.has_key?(shaped, "source_definition_id") == false`. The seed override sets
     `target_definition_id` to a UUID and the target is A (own), so `shaped["target_definition_id"] == plan.target_definition_id` stays.
     `process_key`, `base_version`, `entries` and `requested_by` assertions stay. The `refute resp.resp_body =~ ctx.b.tenant_id` line stays (it now also covers
     B's source definition id only indirectly; T-11 asserts it directly).
   * `context_nested_tenant_ids_walked_but_entries_not_descended`: REWRITTEN and renamed `context_unknown_top_level_keys_dropped_and_entries_not_descended`.
     The `meta` expectation (walked at depth, own id kept) is REPLACED by `Map.has_key?(plan, "meta") == false`. The `entries` assertions (entry
     `tenant_id` and `after.tenant_id` equal B's id, as stored: residual R1) STAY unchanged. The two own-id top-level assertions stay.
   * `context_other_keys_and_status_unchanged`: unchanged (nine-key envelope, run map seven keys).
   * `context_unchanged_for_operator`: unchanged (the `meta.origin_tenant_id` override still round-trips for the operator; the equality assertion with the
     stored plan is the proof).
   * Moduledoc rewritten: ISS-1021 allowlist instead of key-suffix; keep the pointer to `test/specs/REQ-446.md` and add `test/specs/ISS-1021.md`.
3. `test/letflow/routers/promotion_context_allowlist_test.exs` (T-11, new, `Letflow.Routers.PromotionContextAllowlistTest`, `async: false`, same setup as T-8:
   `Fixture.three_tenants!/0`, `Fixture.pin!/1`, reviews seeded through `Scope.seed_review!/4`). Cases:
   * `odd_tenant_keys_never_reach_a_non_operator`: plan overrides at top level `tenantId`, `tenant_ids` (list), `source_tenant`, `x_tenant_id`, each B's id (two
     variants: one run with all four together); A's admin reads: status 200, raw body does not contain B's tenant id (both cases), none of the four keys in
     `serialised_plan`, keys of `serialised_plan` is a subset of the seven allowlisted.
   * `unknown_top_level_key_omitted`: `plan_extra: "x"` (a benign scalar) absent, proving omission is by allowlist not by content.
   * `entries_kept_exactly_as_stored`: entries carrying `tenant_id` of B inside `before`/`after`/entry level equal the stored entries (R1 pinned).
   * `own_tenant_ids_kept_case_insensitively`: stored plan holds A's id upper-cased as `source_tenant_id`; kept, returned as stored.
   * `foreign_side_definition_id_omitted_own_side_kept`: source B / target A: `source_definition_id` absent, `target_definition_id` kept; source A / target A: both
     kept; source A / target B: `target_definition_id` absent, `source_definition_id` kept; source B / target B (neither own): both absent and both tenant ids absent.
   * `non_scalar_under_plain_key_omitted`: `process_key` or `base_version` overridden with a map: key absent.
   * ONE seeding recipe for every malformed or legacy plan (cases `non_map_plan_fails_closed`, `legacy_plan_missing_keys`, `entries_not_a_list_replaced_by_empty_list`,
     and the missing-`entries` case). `Scope.seed_review!/4` only merges overrides into the seven default keys and `PromotionReviewStore.insert_review/2` reads
     `plan.process_key` and verifies the digest, so a plan lacking `process_key`/`entries` or a non-map plan cannot be inserted. Recipe, a private test helper
     `overwrite_plan!(fixture, review_id, json_text)`: (1) seed a NORMAL review with `Scope.seed_review!(fixture, source_id, target_id)` (default overrides);
     (2) overwrite its column with an `Ecto.Query` update on schema `Letflow.Definitions.PromotionReview` filtered by `r.id == ^review.id`, executed with
     `Repo.update_all(query, [set: [serialised_plan: json_text]], prefix: fixture.schema_name)` (the column is a `:string`, `promotion_review.ex:75`; the text is
     written verbatim, no re-encoding; `row_version`, digest and the other columns stay as seeded); (3) assert `{1, _} = result`; (4) read `/#{review.id}/context`.
     The review is read from the schema it was seeded in, because the route reads only the caller's own schema: non-operator cases seed in and read as
     `ctx.a` (A's admin); the operator-side assertion of the same shape seeds in and reads as `ctx.p` (pin = P). The exact `json_text` per shape (a literal
     `String.t()` written by the test; `<B>` is `ctx.b.tenant_id`):
       * JSON string: `"\"x\""` (the 3-character text `"x"`); expected non-operator `serialised_plan` `%{"entries" => []}`, operator `"x"`.
       * JSON array: `"[1,2]"`; non-operator `%{"entries" => []}`, operator `[1, 2]`.
       * JSON number: `"7"`; non-operator `%{"entries" => []}`, operator `7`.
       * `null`-as-plan: the 4-character text `"null"` (JSON null, NOT SQL NULL; SQL NULL is the OQ-3 raise and is not tested); non-operator `%{"entries" => []}`,
         operator `nil`.
       * object without `entries`: `"{\"process_key\":\"legacy-key\",\"tenant_ids\":[\"<B>\"]}"`; non-operator `%{"process_key" => "legacy-key", "entries" => []}`
         (B's id absent from the raw body), operator the decoded object unchanged.
       * object with only `entries` plus a legacy key: `"{\"entries\":[],\"legacy_tenant\":\"<B>\"}"`; non-operator `%{"entries" => []}`; operator unchanged.
       * `entries` not a list: `"{\"process_key\":\"p\",\"entries\":\"not-a-list\"}"`, and the same with `\"entries\":{\"a\":1}` and `\"entries\":null`; non-operator
         `%{"process_key" => "p", "entries" => []}` for each.
   * `non_map_plan_fails_closed`: the four non-map shapes above (string, array, number, `null`), one assertion block per shape, non-operator and operator.
   * `legacy_plan_missing_keys`: the two object shapes above (without `entries`; only `entries` plus a legacy key).
   * `entries_not_a_list_replaced_by_empty_list`: the three `entries` shapes above. It does NOT use a `seed_review!/4` override: `seed_review!` would run
     `PromotionDigest.compute_plan_digest/1` over a plan with a non-list `entries`, and that function is typed for `%{entries: [map()]}`; whether its
     `canonicalize/1` accepts a bare string/map/nil there is unverified, so the one recipe above is used instead.
   * `nil_tenant_context_never_reaches_the_handler` (replaces the former nil-own-tenant case): build the request with
     `Fixture.router_conn(:get, "/#{review.id}/context", ctx.a, ["PLATFORM_ADMIN"], nil)` and then `Plug.Conn.assign(conn, :auth_context, %{user_id: <uuid>,
     tenant_id: nil, roles: ["PLATFORM_ADMIN"]})` (`Fixture.router_conn/5` -> `auth_context/2` always sets a binary tenant id, so the override is the only way to get nil).
     Read of the code: `Letflow.Plugs.Authorize.call/2` (`plugs/authorize.ex:101-106`) calls `Context.scoped_repo_opts/1`, which returns
     `{:error, :missing_auth_context}` for a nil `tenant_id` (`api/context.ex:232-237`); the plug answers `Response.internal_error` and halts BEFORE the handler
     runs. Assertion: dispatch through `Letflow.Routers.Promotions.call/2` as T-8 does, `resp.status == 500`, and the raw body contains no `serialised_plan` key and none of
     B's or A's ids. Consequence for the design: the `{:tenant, nil}` branch of 3.1/3.4 is DEFENCE IN DEPTH and is UNREACHABLE through the route (a
     tenant id that is nil or not resolvable to a schema never gets past `Authorize`). That branch is therefore UNTESTED at route level by T-11, for that reason
     only, and the single test above pins the reason (if it ever returned 200, the shaping branch would become reachable and this design must be revisited).
     No `@doc false` seam is added for it: it would exist only to test a branch the route cannot reach; the clause it exercises (`own_tenant_value?/2` with a
     non-binary `own` returns false, which is the existing, unchanged second clause) is already covered by every "foreign id omitted" case through the first clause's
     failure path, and an extra public function in a router module for one unreachable branch is not justified. Note for REVIEWER: this is a stated, reasoned
     gap, not a deferral.
   * `operator_sees_all_unchanged`: odd keys plus B's and A's ids plus `meta`: operator body equals the decoded stored plan; contains B's id.
   * `envelope_has_nine_keys_for_both_views`.
   * `pin_unset_would_be_operator_is_shaped_like_everyone_else`: with the pin cleared, the platform tenant's admin gets the non-operator shaping (parity with
     ISS-0999's test of that name).
4. `test/letflow/routers/promotion_context_allowlist_drift_test.exs` (T-12, new, `Letflow.Routers.PromotionContextAllowlistDriftTest`, `async: false`; modelled
   on ISS-0999 T-9). The expected sets are written LITERALLY in the test (not derived from the allowlist):
   * `allowlist_matches_the_literal_table`: `Promotions.plan_allowlist()` equals the 3.1 table: `plain` and
     `own_tenant` lists compared after `Enum.sort/1`; `entries` compared as the literal string `"entries"`; `own_side` (a map) compared by `==` against the
     literal map `%{"source_definition_id" => "source_tenant_id", "target_definition_id" => "target_tenant_id"}` (map equality is order-free, no sorting).
   * `allowlist_covers_exactly_the_keys_the_plan_builder_emits`: seed an active definition in tenant A via `Scope.insert_active_definition!/3`, call
     `PromotionPlan.compute_promotion_plan/5` (A as source, B as target, `permission_checker: fn _, _ -> true end`), assert `{:ok, plan}` and that
     `plan |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()` equals the union of the plain, own-tenant, own-side keys and `entries`
     (all seven emitted even when the value is `nil`). A new or renamed key in `PromotionPlan.t()` fails this test until a person classifies it.
   * `own_side_gates_are_emitted_tenant_id_keys`: every value in `own_side` is a member of `own_tenant`.
   * `class_sets_are_disjoint`.
5. `test/specs/ISS-1021.md` (TEST-DESIGNER): criterion-to-test table (section 5), the fail-first note (T-8 rewritten tests and T-11 odd-key test fail against the
   suffix walk), a mutation table (suggested mutants, one `promotions.ex` line each: M1 restore `shape_tenant_ids` walk for non-operators; M2 own-side rule
   dropped (definition ids always kept); M3 own-tenant rule dropped (any scalar under tenant-id keys); M4 `meta`/unknown key copied; M5 `entries` descended and
   stripped; M6 non-map plan passed through; M7 operator shaped; M8 `requested_by` removed from the envelope; M9 `entries`
   forced-present rule dropped), and the residual list of section 8.
6. `docs/issues/ISS-1021.yaml` (new; fields as `docs/issues/ISS-0999.yaml`: `id`, `title`, `discovered_by: SECURITY-REVIEWER (ISS-0999, Q-981)`,
   `severity: MEDIUM`, `failure_class: defect`, `owner: ELIXIR-DEV`, `description`, `affected_files`, `regression_test`, `follow_ups`, `status`, `resolution`).
   Required refs: `queue_ref: Q-1003` and `github_ref: GH-2291`, with a YAML comment above `queue_ref`: the queue's own `issue_ref` for Q-1003 came back
   `ISS-1003`, which is not the local number (no `docs/issues/ISS-1003.yaml` exists at 1177a315; the queue number Q-1003 was read as a local issue number by
   mistake); ISS-1021 was
   chosen because ISS-0999's `follow_ups` and `test/specs/ISS-0999.md` R2 already cite it as the tracking id. (Same comment pattern as ISS-0999.yaml, which
   explains the ISS-0981 clash.) `regression_test: test/letflow/routers/promotion_context_allowlist_test.exs`. `follow_ups` names R1 with the corrected reason of 3.3 and the new issue id (the design's `Q-1005 / GH #2297 / ISS-1023` placeholder is replaced by the real id in this file, in
   `test/specs/ISS-1021.md` and in the 0046 section before merge; ELIXIR-DEV greps for `Q-1005 / GH #2297 / ISS-1023` as a pre-merge check).
7. `docs/migration/decisions/0046-admin-scopes-and-role-charter.md`: decision: YES, one append-only dated section, because the 0046 closure section of 2026-10-06
   ends with "Remaining tracked item: `GET /promotions/:id/context` keeps the key-suffix rule ... tracked as Q-1003 / GH #2291 / ISS-1021", which becomes false
   once this merges; leaving it would make the decision record say a residual is open that is closed. Title: "Closure of the /context plan residual (ISS-1021 /
   Q-1003), 2026-10-06" (use the real UTC date of the merge). Content: no earlier text changed, no decision text changed; REQ-446 residual R2 (key-suffix rule on
   `/context`, REQ-446 OQ-8/OQ-9 for the plan) is closed for `GET /promotions/:id/context`; design `lib/letflow/design/iss1021-context-plan-allowlist.md`;
   it supersedes section 4b of the REQ-446 design for that route; list what a non-operator sees (3.1); `entries` as stored (R1, named with the CORRECTED reason of 3.3: for a review naming foreign tenants held in the platform schema, `entries`
   carries those tenants' definition content; tracked by `Q-1005 / GH #2297 / ISS-1023`, an INV-10 exception, not closed here) and `requested_by` unchanged (R5, accepted) remain. Scope and permission of the route unchanged (tenant scope, `:PromotionsRead`).
8. `docs/issues/ISS-0999.yaml` `follow_ups` entry: NOT edited (resolved issue record; closure is recorded in ISS-1021.yaml and 0046). No change to
   `docs/requirements.yaml`, `docs/roles.md`, `docs/frontend/`, `web/` (no SPA field is read by name other than `entries`, see 3.3; no FRONTEND-DEV work).
9. `lib/letflow/design/iss0999-platform-events-allowlist.md` and `lib/letflow/design/req446-named-scoped-permissions.md`: NOT edited (historical design
   records; section 3.7 of the former and 4b of the latter are superseded by this file, stated in the 0046 section above).

## 7. SPA and other readers

Grep over `web/src`, `apps/`, `docs/frontend/`, `docs/mobile/` for `serialised_plan`, `source_definition_id`, `base_version`: the SPA's `getContext` reads
`raw.serialised_plan.entries` and re-serialises the whole object for display (`PromotionReviewStateMachine.tsx:247-270` prints the string); `base_version`
appears only in comments. No SPA code reads `source_definition_id`, `target_definition_id`, `process_key` or any tenant id from this response, so no
`web/` change. `entries` always present (3.4) keeps the declared `{ entries: PlanEntry[] }` type true. The context response is the only reader of the
shaped plan (the approve/apply handlers use the stored plan, `promotions.ex:667`).

## 8. Residuals after this change (named for REVIEWER and SECURITY-REVIEWER)

* R1 (standing TRACKED exception, INV-10; follow-up `Q-1005 / GH #2297 / ISS-1023`, placeholder to be replaced by the real issue id before merge): `entries` graph JSON is
  copied as stored. It is NOT "the caller's own tenant data" in every case: for an operator-created review naming foreign tenants B and C, held in the platform
  tenant's schema, `entries` holds B's and C's definition graph (source and target graphs, variable schemas, service bindings, module refs: `build_entries`,
  `promotion_plan.ex:199-243`), readable by a non-operator holding `:PromotionsRead` there, and by readers of legacy rows. Free-form tenant-authored content,
  including any id a tenant author typed into a node, is not scanned. No worse than before this change (the old walk skipped `entries` too), so it does not
  fail ISS-1021. Candidate fixes for the follow-up: return `entries` to a non-operator only when both tenant ids are own, else `[]`; whether non-admin
  platform-tenant users hold `:PromotionsRead` is unverified and belongs to the follow-up.
* R2 (CLOSED by this change): the key-suffix limitation on `/context`.
* R3 (unchanged, other routes): `teardown_error` text on the review routes.
* R4 (accepted): `process_key` and `base_version` are tenant-authored strings kept as plain scalars; a tenant author could place any text in them.
* R5 (accepted by SECURITY-REVIEWER): `requested_by` (the envelope's user id) is unchanged. It is a platform-tenant user id read by a platform-tenant user (the
  review lives in the reader's own schema), not another tenant's identifier.
* R6 (accepted by SECURITY-REVIEWER): `plan_digest` is returned for every caller and covers the unshaped plan; it reveals nothing readable, but a non-operator cannot verify it from
  the shaped plan (already so today).
* R7 (behaviour change, intended): a non-operator reader loses `source_definition_id` / `target_definition_id` when the gating tenant is foreign, and any
  unknown top-level key of legacy plans.

## 9. Open questions (none silently resolved; defaults stated)

* OQ-1: OWN-SIDE definition-id rule (3.1) versus keeping both definition ids as plain scalars (the issue text and T-8 as they stand). RATIFIED by SECURITY-REVIEWER: OWN-SIDE (INV-10
  consistency with ISS-0999 3.1). Closed; the plain-scalar alternative is not taken.
* OQ-2: `entries` forced to `[]` when absent or not a list, versus omitting the key. Default: forced `[]` (SPA contract). Reviewer may prefer omission.
* OQ-3: invalid JSON or `nil` in the `serialised_plan` column keeps raising (HTTP 500) for both views (3.4). Default: unchanged; alternative: a non-raising
  decode returning `%{"entries" => []}` for non-operators only.
* OQ-4: `requested_by` left in the envelope (3.5, R5). Accepted by SECURITY-REVIEWER (R5): unchanged, because the AC fixes the nine-key envelope; omitting or nulling it would be a separate
  issue.
* OQ-5 (resolved in this design, kept for traceability): the nil-own-tenant branch is unreachable through the route (`Authorize` answers 500 first); it is
  declared untested by T-11 for that reason and pinned by `nil_tenant_context_never_reaches_the_handler`; no test seam added (section 6, file 3).
* OQ-6: the queue's `ISS-1003` number is not a local issue (verified: no such file); the YAML comment records the clash, the local id stays ISS-1021.
