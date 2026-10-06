# Design: ISS-0999 (Q-981 / GH #2266) - per-event-type payload allowlist on GET /promotions/platform-events

Owner: ELIXIR-DEV. Severity MAJOR (INV-10, INV-2). Size S3. Depends on REQ-446 (Q-963), merged at 66c012ef.
Design only: signatures, tables and rules; no implementation code.

## 1. Problem (read of the code at 66c012ef)

`GET /promotions/platform-events` is tenant scope (`:PromotionsRead`, 0046 correction note). It reads only the caller's own schema, but a
`DEFINITION_PROMOTED` event written at target tenant T by an operator promotion carries foreign data in T's schema:

* payload `source_definition_id`: row id in the SOURCE tenant's schema (`definitions/promotion.ex:517-525`);
* payload `review_id`: the operator's review id in the platform tenant's schema;
* envelope `actor_id`: the operator user id in the platform tenant (`event_store/platform_events.ex` adapter copies `actor_id` to the row).

REQ-446 shaping (`routers/promotions.ex:941-1014`: `platform_event_map/2`, `shape_tenant_ids/2`, `tenant_id_key?/1`) is a DENY-by-pattern walk: it drops
string keys ending in `tenant_id` unless the value is the caller's own id. It is wrong by construction for INV-10 ("no other tenant's data or identifiers"):
any other key name (`tenant_ids`, `tenantId`, `source_tenant`, a future producer's key) passes. Fix: invert to an ALLOWLIST per event type (INV-2: field
selection before serialisation, hand-built map).

## 2. What the producers write (the allowlist's source of truth)

Payload = `event_attrs` minus `:event_type` and `:actor_id`, JSON-encoded (`PlatformEvents` adapters, `platform_events.ex:60-175`). Registry schemas
(`tenant_provisioning.ex:1047-1117`) agree.

| Event type | Payload keys written | Envelope `actor_id` |
|---|---|---|
| `DEFINITION_PROMOTED` (v2) | `review_id` (nullable), `source_tenant_id`, `target_tenant_id`, `source_definition_id`, `target_definition_id`, `process_key` | the promoting user (operator for an operator promotion; may be a user of the caller's own tenant for an ENV-03 own-tenant promotion) |
| `DEFINITION_VERSION_ROLLED_BACK` | `process_key`, `from_version`, `to_version` | the rolling-back user |
| `PROMOTION_ASSERTION_TEARDOWN_FAILED` | `run_id`, `sandbox_id`, `tenant_id`, `error` (free text, from `describe_release_failure/1`, unbounded term-to-string) | constant `EventStore.platform_actor_id()` sentinel `00000000-...-0002` |

An oversized payload is stored as `{"$ref": ...}` and the list read does not resolve it (`event_store.ex:716-722`), so it reaches the router as a map with
an unknown key.

## 3. Decisions

### 3.1 Allowlist per event type (non-operator view)

Each key is classed PLAIN (kept when its value is a scalar) or OWN-TENANT (kept only when the value is a binary equal, case-insensitively, to the caller's
own tenant id). Anything not listed is omitted. A kept value must be a scalar (binary, number, boolean or null): a map or list under an allowlisted key is
omitted (fail closed; no recursion, so no nested-key leak, and this replaces the recursive walk for events).

| Event type | PLAIN keys kept | OWN-TENANT keys kept | Omitted for a non-operator (everything else, notably) |
|---|---|---|---|
| `DEFINITION_PROMOTED` | `target_definition_id`, `process_key` | `source_tenant_id`, `target_tenant_id` | `source_definition_id`, `review_id`, any unknown key |
| `DEFINITION_VERSION_ROLLED_BACK` | `process_key`, `from_version`, `to_version` | none | any unknown key |
| `PROMOTION_ASSERTION_TEARDOWN_FAILED` | `run_id`, `sandbox_id` | `tenant_id` | `error` (decision 3.5), any unknown key |

Rationale for the two omissions the issue names: `source_definition_id` is a row id of a tenant the caller may not own; the schema cannot tell whether it is
the caller's own row (an own-tenant promotion) or foreign, and the simplest fail-closed rule is "omit always" (the id is useless to the caller either way:
the source row is not addressable from the tenant). `review_id` likewise: it lives in the promoting tenant's schema; for the caller's own reviews
`GET /promotions` and `GET /promotions/:id/context` already expose them.

### 3.2 Unknown event type: payload `{}`, event kept

For an `event_type` with no allowlist entry (a future producer, or a type registered by a customer through the platform-event append path) a non-operator
receives the event envelope with `"payload" => {}`. The event is NOT omitted. Justification: (a) omission would make pages shorter than `page_size` or
empty while `next_cursor` is non-null, and make the `event_type` filter silently disagree with the operator's view (pagination and filter behaviour must
stay identical for both views, REQ-446 4a); (b) the envelope fields kept (`event_id`, `event_type`, `timestamp`, `sequence_num`) carry no cross-tenant
data (the type name is platform-defined, ids are of the caller's own schema rows); (c) `{}` is also the fail-closed result for a non-map payload and for the
`$ref` oversized form.

### 3.3 Own tenant id: keep it (REQ-446 behaviour retained)

`source_tenant_id`, `target_tenant_id` (`DEFINITION_PROMOTED`) and `tenant_id` (teardown) stay allowlisted OWN-TENANT keys. The caller's own id is not a
foreign identifier (INV-10), is useful (tells a tenant admin "this promotion landed in my tenant", and distinguishes an own-tenant promotion where both
ids equal the caller's), and keeping it preserves the existing T-7 assertions (`own_tenant_id_is_retained`, `e3`, `e4`, `e4b` including the upper-case
id returned as stored). When the value is foreign, the key is omitted (not hashed, not placeholdered), as today.

### 3.4 `actor_id` rule: omit the key for every non-operator

Chosen: for a non-operator the envelope key `actor_id` is removed from the item (key absent, not null, not sentinel). Operator: unchanged. Why this and not
"keep when it is a user of the caller's own tenant": a user id is an opaque UUID with no tenant marker; deciding "own tenant's user" needs one users-table
lookup per distinct actor per page (new data-access path, INV-6 proof burden, extra DB round-trips, a possible timing signal) and a wrong lookup fails
open. Omit-always is a constant-time, stateless, fail-closed rule. Cost, stated: a tenant admin no longer sees who rolled back or promoted via this route;
the audit log route (`Routers.Audit`, `AuditRead`) remains the actor-attributing surface for own-tenant actions. The teardown sentinel actor carries no
information, so omitting it loses nothing.

Response key set for a non-operator item: `event_id`, `event_type`, `timestamp`, `sequence_num`, `payload` (five keys). Operator item: the existing six.
Top-level body keys `items`, `next_cursor` unchanged.

### 3.5 Teardown `error` omitted for non-operators

`error` is free text built from an arbitrary release-failure term; nothing bounds what it names (sandbox host, tenant schema, foreign ids). An allowlist
that keeps a free-text field defeats its own purpose, so it is omitted. This goes one key beyond the three the issue lists; it is flagged as OQ-1 for
SECURITY-REVIEWER (alternative: keep it and carry the REQ-446 OQ-7 residual).

### 3.6 Operator view and pin behaviour unchanged

`tenant_view/1` stays the authority (`PlatformTenant.scope_facts_for/1`, recomputed, stored flag never read). Operator: payload and `actor_id` passed
through byte-identical. Pin unset or caller outside the platform tenant: treated as non-operator (existing test `pin_unset_would_be_operator_...`).

### 3.7 `GET /promotions/:id/context` (4b) does NOT change

The issue scopes only platform-events. `review_context_map/2` and `shape_plan/2` keep the key-suffix walk over `serialised_plan` and keep
`shape_tenant_ids/2` for that route. Reasons: the serialised plan is one fixed structure built by `promotion_plan.ex`, tenant-authored `entries` content is
deliberately not descended (REQ-446 OQ-9), and an allowlist there is a separate scope (a plan has no event types). `shape_tenant_ids/2`,
`shape_plan/2`, `tenant_id_key?/1` and `own_tenant_value?/2` therefore remain. Residual named for REVIEWER: the `/context` key-suffix limitation (REQ-446
OQ-8) stays open for that route only; if SECURITY-REVIEWER wants it closed, a follow-up issue is filed (not part of this change).

### 3.8 What the SPA reads

Grep over `web/src` (ts/tsx, excluding node_modules), `apps/`, `docs/frontend/`, `docs/mobile/` for `platform-events` and `platform_events`: no match. `web/src/api/promotions.ts`
has no events call; `PromotionReviewPage` and the promotions components use the review routes only. The SPA reads NO platform-events payload field, so the
Promotion Reviews page cannot break. No FRONTEND-DEV work; no `web/` change.

## 4. Interfaces (private, in `lib/letflow/routers/promotions.ex`; arities may be adjusted by ELIXIR-DEV)

* module attribute `@platform_event_allowlist :: %{event_type :: String.t() => %{plain: [String.t()], own_tenant: [String.t()]}}` holding the table of 3.1
  (a literal, with a `# -- Response allowlist (INV-2) --` comment citing this design and INV-10);
* `platform_event_allowlist() :: %{String.t() => %{plain: [String.t()], own_tenant: [String.t()]}}`: public, `@doc false`, returns that attribute; used only by
  the drift test T-9 (file 5 in section 6);
* `shape_platform_event_payload(payload :: term(), event_type :: String.t(), view :: tenant_view()) :: term()`: operator returns `payload` unchanged;
  `{:tenant, own}` returns a hand-built map of exactly the allowlisted keys that pass 3.1's value rules, `%{}` for an unknown type or a non-map payload;
* `platform_event_map(item :: EventStore.platform_event_item(), view :: tenant_view()) :: map()`: operator item has six keys; non-operator item has the
  five keys of 3.4 and the payload from the function above;
* `own_tenant_value?/2` (existing) is reused for OWN-TENANT keys; `tenant_id_key?/1` stays only for `shape_tenant_ids/2` (used by `/context`).

Invariants: (I-1) a non-operator payload key set is a subset of the table for that event type; (I-2) a non-operator body never contains `actor_id`,
`source_definition_id`, `review_id`, `error`; (I-3) no non-operator body contains any tenant id other than the caller's own; (I-4) item order, count,
`next_cursor` and the `event_type` filter are identical for operator and non-operator; (I-5) no database access added; (I-6) nothing is logged with ids.

## 5. Acceptance-criteria map

| Acceptance criterion | Design element | Test |
|---|---|---|
| allowlist per event type for the three types; unknown key never reaches a non-operator | 3.1, 3.2, 4 (`@platform_event_allowlist`, `shape_platform_event_payload/3`), I-1 | T-7 updated, T-9 |
| non-operator: `source_definition_id`, `review_id`, foreign `actor_id` omitted; operator sees all | 3.1, 3.4, 3.6, I-2 | T-7 updated, T-10 |
| two-tenant test (operator promotes B into A; A's admin reads; no identifier of B or of the operator in the body; operator sees all; tenant_ids/tenantId key-suffix case) | T-10, T-7 new cases | T-10, T-7 |
| existing T-7 tests pass or are updated | section 6 file 2 (expectation changes listed) | T-7 |
| SECURITY-REVIEWER verdict recorded | section 7 (workflow step, not a code element) | recorded in the PR and the issue file |

## 6. Files to change

1. `lib/letflow/routers/promotions.ex`: allowlist attribute, `shape_platform_event_payload/3`, `platform_event_map/2` (drop `actor_id` for non-operator), keep
   the `/context` helpers; update the moduledoc R11 and Authorization sentences REQ-446 added (platform-events is an allowlist, `/context` still suffix
   shaped). The only `lib/` file.
2. `test/letflow/routers/promotion_platform_events_shaping_test.exs` (T-7). `seed!/2` and the nine seeded events e1..e8 (e4b included) are kept; the
   hand-written `shaped` expectations and the assertions below change. Every existing assertion, by test:

   * `seed!/2` expectations (`expected.(...)` list): e1 `shaped` = stored minus `source_tenant_id`, `source_definition_id`, `review_id` (keys left:
     `target_tenant_id` = A, `target_definition_id`, `process_key`); e2 = stored minus `tenant_id` and `error` (keys left: `run_id`, `sandbox_id`); e3 =
     stored minus `source_definition_id`, `review_id` (both tenant ids = A kept, plus `target_definition_id`, `process_key`); e4 and e4b = stored minus `error`
     (`tenant_id` kept as stored, upper-case for e4b); e5 = stored unchanged; e6, e7, e8 = `%{}` (the fixture type is not allowlisted, so unknown).
   * `non_operator_never_receives_a_foreign_tenant_id`: the two `refute resp.resp_body =~` lines stay; the per-key assertions for e1 (`source_tenant_id`
     absent, `target_tenant_id` = A), e2 (`tenant_id` absent), e3 (both = A), e4 and e4b (`tenant_id` as stored) REMAIN VALID, unchanged. The e6 assertions
     (`detail` has no `origin_tenant_id`; `detail["items"]` equals the two-element list) are REPLACED by one assertion: `items[e6.id]["payload"] == %{}`.
     The e7 assertion (`== %{"keep" => "x"}`) is REPLACED by `items[e7.id]["payload"] == %{}`.
   * `own_tenant_id_is_retained`: the top-level loop over stored keys whose value is A's id stays valid and unchanged (it then covers e1 target, e3 both,
     e4, e4b; e6/e7/e8 have no top-level own-id key). The trailing "id nested in a list element" assertion on e6 is REMOVED (there is no nested walk for
     events any more; the `{}` outcome of e6 is already asserted in the previous test).
   * `other_payload_fields_and_envelope_unchanged`: compare the envelopes with `actor_id` removed from the raw side:
     `Map.delete(s, "payload") == r |> Map.delete("payload") |> Map.delete("actor_id")`; add `refute Map.has_key?(s, "actor_id")` and
     `assert Map.has_key?(r, "actor_id")` (the unshaped read still has it); the non-operator key-set assertion becomes
     `["event_id", "event_type", "payload", "sequence_num", "timestamp"]` (five); the raw payload equality (`== e.stored`), the shaped equality
     (`== e.shaped`, with the new expectations) and the top-level body key set (`items`, `next_cursor`) stay.
   * `pin_unset_would_be_operator_is_shaped_like_everyone_else`: unchanged code (uses `e.shaped`); add `refute resp.resp_body =~ "actor_id"`.
   * `list_inside_list_is_walked`: REWRITTEN (one outcome, not removed) and renamed `unknown_type_payload_is_empty_even_with_nested_own_tenant_id`.
     Body: seed, read as A with `["PLATFORM_ADMIN"]` (pin on P), take e8; assert `items[e8.id]["event_type"] == e8.type` and
     `items[e8.id]["payload"] == %{}` (e8's stored payload holds A's own id in a nested list; the allowlist does not descend, so even the own id is
     dropped).
   * `other_roles_still_forbidden_and_see_no_event_data`: unchanged.
   * `operator_sees_every_tenant_id` (reads P's own schema with P pinned; this IS the operator read for T-7): the payload equality `== e.stored` stays; add
     an assertion that every item has a binary `actor_id` (the operator keeps it).
   * `pagination_is_unaffected`: unchanged (it asserts ids, cursors, counts and the `event_type` filter result [e1, e3]; the whole file was read, it has no
     `actor_id` or payload assertion).
3. New cases in T-7 (same file, `describe "allowlist"`):
   * `unlisted_tenant_keys_never_reach_a_non_operator`: write a `DEFINITION_PROMOTED` event through `PlatformEvents.append_definition_promoted/2` with the
     required keys plus extra atom keys `tenant_ids: [B_id]`, `tenantId: B_id`, `source_tenant: B_id`, `x_tenant_id: B_id` (the adapter encodes the whole
     attrs map minus `event_type` and `actor_id`, and the registry schema has no `additionalProperties: false`, so the append succeeds; the case first
     asserts `{:ok, _}`). Assert the response payload key set equals exactly the allowlisted DEFINITION_PROMOTED keys that were written (none of the four
     extra keys) and the body contains no B id in either case. Fallback if the registry rejects extra keys: append through
     `EventStore.append_platform_event/2` directly with the encoded payload, as `Scope.append_fixture_event!/2` does; the response assertion is unchanged.
   * `unknown_event_type_payload_is_empty_and_event_kept`: e6 read as A: the item exists and `payload == %{}`; the ids and count equal the unshaped read
     (A pinned as platform for that read, P re-pinned afterwards) and `next_cursor` matches under `page_size=2`.
   * `value_under_allowlisted_key_must_be_scalar`: a `DEFINITION_PROMOTED` event with `process_key` set to a map containing B's id; assert `process_key`
     is absent from the response payload and the body has no B id.
   * `non_operator_item_has_no_actor_id`: for every item of the seeded read, `Map.has_key?(item, "actor_id") == false`.
4. New file `test/letflow/routers/promotion_platform_events_two_tenant_test.exs`, T-10 (module `Letflow.Routers.PromotionPlatformEventsTwoTenantTest`,
   `use Letflow.DataCase, async: false`, aliases as in T-7 plus `Letflow.Definitions.Promotion`). The real path is `Promotion.promote_definition/3`, NOT
   `POST /tenants/:id/promote/:process_key` (that route is own-tenant and reviewless: `review_id` nil, actor the caller, target the caller's tenant, so it
   cannot write an event with an operator review id and operator actor into A's schema). Existing tests calling `promote_definition/3` the same way:
   `test/letflow/definitions/promotion_test.exs:180,255,303`.

   Setup: `tenants = Fixture.three_tenants!()` (P platform candidate, A target, B source); `Fixture.pin!(tenants.p.tenant_id)` (P is the platform tenant
   for the whole test except the explicit re-pin in pass 2). Build the promotion:
   * `key = Scope.unique_key("t10")`;
   * `b_def = Scope.insert_active_definition!(tenants.b, key, "1.0.0")` (active row in B's schema, the source);
   * `%{review: review} = Scope.seed_review!(tenants.p, tenants.b.tenant_id, tenants.a.tenant_id, %{process_key: key, source_definition_id: b_def.id})`
     (`test/support/promotion_scope_fixture.ex:106`; inserts the review into P's schema through `PromotionReviewStore.insert_review/2`; source B, target A;
     `base_version` stays nil and A has no row for `key`, so there is no conflict);
   * `operator_id = Ecto.UUID.generate()`;
   * `{:ok, result} = Promotion.promote_definition(operator_id, review, opts)` with `opts`: `permission_checker: fn _actor, _source_tenant -> true end`,
     `tenant_classifier: fn _tenant_id -> :test end`, `event_appender: &PlatformEvents.append_definition_promoted/2` (the real adapter, so the event lands
     in A's schema as in production: `promote_definition/3` calls it with `(event_attrs, target_prefix)`, `target_prefix` = A's schema;
     `lib/letflow/definitions/promotion.ex:153-159`). `permission_checker` and `event_appender` are required (`Keyword.fetch!`); `tenant_classifier` is
     passed only to avoid depending on the default classifier.
   * Captured for the assertions: `operator_id`, `review.id`, `review.requested_by` (the requester id the fixture generated), `b_def.id`,
     `tenants.b.tenant_id`, `tenants.p.tenant_id`, `result.target_definition_id`.

   Pass 1, non-operator (pin on P): A's admin reads `GET /platform-events` with `get_events(tenants.a, ["TENANT_ADMIN"])`, and again with
   `["PLATFORM_ADMIN"]` held in A (still non-operator because the pin is P). Assert status 200 and the `DEFINITION_PROMOTED` item exists; the RAW body
   contains none of: B's tenant id (both cases), P's tenant id (both cases), `operator_id`, `review.id`, `review.requested_by`, `b_def.id`; the item has no
   `actor_id` key; the payload key set equals exactly `["process_key", "target_definition_id", "target_tenant_id"]` with `target_tenant_id` = A's id,
   `target_definition_id` = `result.target_definition_id`, `process_key` = `key`.
   Pass 1b, B as reader (pin on P): `get_events(tenants.b, ["TENANT_ADMIN"])` returns 200 with no item for this event and a body containing none of A's
   or P's ids, `operator_id`, `review.id`.
   Pass 2, operator sees all: `Fixture.pin!(tenants.a.tenant_id)` (the single re-pin; the same technique as T-7's unshaped read: an operator's read always
   uses the operator's OWN schema as prefix, so an operator view of A's schema is obtained by making A the platform tenant for the read; no other way
   exists). Read `get_events(tenants.a, ["PLATFORM_ADMIN"])` and assert the same event item has `actor_id == operator_id` and the payload equals the full
   stored payload: `review_id == review.id`, `source_tenant_id == tenants.b.tenant_id`, `target_tenant_id == tenants.a.tenant_id`,
   `source_definition_id == b_def.id`, `target_definition_id == result.target_definition_id`, `process_key == key`. Then `Fixture.pin!(tenants.p.tenant_id)`
   restores the pin as the last step (the fixture's `on_exit` restores the original config in any case).
5. New file `test/letflow/routers/promotion_platform_events_allowlist_drift_test.exs` (T-9, module
   `Letflow.Routers.PromotionPlatformEventsAllowlistDriftTest`, `use Letflow.DataCase, async: false`). ONE approach: a public `@doc false` accessor
   `Letflow.Routers.Promotions.platform_event_allowlist/0 :: %{String.t() => %{plain: [String.t()], own_tenant: [String.t()]}}` returning the module attribute
   of section 4 (the only production-code test seam; no private-attribute access, no HTTP-level matrix). The test provisions tenants with
   `Letflow.Support.PlatformTenantFixture.three_tenants!()` and uses `tenants.a.tenant_id` as the fixture tenant; for each type it calls
   `Letflow.EventStore.Registry.get_type(event_type, tenant_id)` (argument order: event type name first, then tenant id) and takes the property names
   from `{:ok, %EventType{json_schema: schema}}` as the keys of `schema["properties"]`. Exact expected sets, written literally in the test (not derived
   from the allowlist):

   | Event type | registry properties | kept plain | kept own-tenant | omitted for a non-operator |
   |---|---|---|---|---|
   | `DEFINITION_PROMOTED` | `review_id`, `source_tenant_id`, `target_tenant_id`, `source_definition_id`, `target_definition_id`, `process_key` | `target_definition_id`, `process_key` | `source_tenant_id`, `target_tenant_id` | `review_id`, `source_definition_id` |
   | `DEFINITION_VERSION_ROLLED_BACK` | `process_key`, `from_version`, `to_version` | `process_key`, `from_version`, `to_version` | none | none |
   | `PROMOTION_ASSERTION_TEARDOWN_FAILED` | `run_id`, `sandbox_id`, `tenant_id`, `error` | `run_id`, `sandbox_id` | `tenant_id` | `error` |

   Assertions: (a) the sorted keys of `platform_event_allowlist()` equal the three type names; (b) per type, `plain` equals the table's kept-plain set and
   `own_tenant` the own-tenant set (sorted lists); (c) per type, the registry properties equal the union of the three table columns (kept plain, kept
   own-tenant, omitted) and those three sets are pairwise disjoint, so a new or renamed registry key fails the test until a person decides it.
6. `docs/issues/ISS-0999.yaml` (new; ISS-0999 is the local number, unused). Fields as in ISS-0998: `id: ISS-0999`, `title`, `discovered_by: SECURITY-REVIEWER
   (REQ-446, Q-963)`, `severity: MAJOR`, `failure_class: defect`, `occurrence: 1`, `owner: ELIXIR-DEV`, `description`, `affected_files`, `regression_test`
   (T-10), `queue_ref: Q-981` with a YAML comment that the queue's own issue_ref for this item is ISS-0981 which is not the local number (ISS-0981 is a
   different local issue; ISS-0999 was chosen because REQ-446's test spec already cites it), `github_ref: GH-2266`, `status: resolved` set when merged
   (open until then), `resolved_in_run`, `resolved_at`, `resolution`. Verify with `ls docs/issues` that `ISS-0981.yaml` is indeed a different issue before
   writing the comment.
7. `test/specs/REQ-446.md`, KNOWN residuals section (lines 110-118): do NOT rewrite; append a dated line below it ("closed by ISS-0999 / Q-981 for
   platform-events; `/context` unchanged") only if the spec file is not append-only-locked; otherwise leave and rely on the issue file. (OQ-4.)

No other file: no migration, no schema change, no event-registry change, no `web/`, no `docs/requirements.yaml`.

## 7. Documents

* `docs/migration/decisions/0046-admin-scopes-and-role-charter.md`: the existing REQ-446 correction section has a "Residual ... tracked as an exception:
  Q-981 / GH #2266 / ISS-0999" paragraph and must NOT be edited. A note is needed only because that paragraph would otherwise read as still open.
  Recommended: append a new short section at the end of the file, "Closure of the platform-events payload residual (ISS-0999), dated <UTC date of merge>",
  stating: platform-events is shaped by a per-event-type allowlist, `source_definition_id`, `review_id`, `actor_id` and teardown `error` are omitted for a
  non-operator, own tenant id retained, `/context` unchanged; no decision text changed. DOC-UPDATER writes it after merge (append after the REVIEWER and
  SECURITY-REVIEWER sign-off sections, same pattern as the 2026-10-06 correction).
* `docs/roles.md`: line 66-67 only says the route is tenant scope under `PromotionsRead`; the payload description is not restated there. No change
  (the Matrix is parsed by the REQ-448 parity test; do not touch it). Re-check by grep for `platform-events` in docs/roles.md at build time.
* `lib/letflow/design/req446-named-scoped-permissions.md`: historical, not edited (its 4a stays as the REQ-446 record; this design supersedes 4a for
  platform-events only, stated here).

## 8. SECURITY-REVIEWER and gates

Tenant-data-path response shaping: SECURITY-REVIEWER (INV-2, INV-5 unaffected - no lookup added, INV-10 central), then REVIEWER, TEST-DESIGNER,
TEST-RUNNER, RELEASE-VALIDATOR per WF-02/WF-03. The verdict is recorded in the PR and in the issue file `resolution`. No INV-5 impact: the route has no
id lookup. No INV-6 impact: no new data-access path.

## 9. Open questions (none block the build; defaults stated)

* OQ-1: omit teardown `error` (default, 3.5) or keep it with the free-text residual. Default: omit. SECURITY-REVIEWER to confirm.
* OQ-2: unknown event type returns payload `{}` with the event kept (default, 3.2) versus omitting the event. Default: `{}`.
* OQ-3: `process_key` and `from_version`/`to_version` are tenant-authored strings kept as PLAIN; a tenant-authored value can contain any text, including an
  identifier, but it is the caller's own definition name in the caller's own schema. Accepted residual, as REQ-446 OQ-6/OQ-7.
* OQ-4: whether `test/specs/REQ-446.md` accepts an appended note (3.7 and file 7).
* OQ-5: `/context` (4b) keeps the key-suffix walk (3.7). Default: unchanged, out of the issue's scope; a follow-up is filed only if SECURITY-REVIEWER asks.
* OQ-6: dropping `actor_id` for non-operators is a response-shape change for non-operator tenant admins; no SPA/mobile consumer exists (3.8); API docs
  (`docs/` OpenAPI or route table, if any lists the platform-events response) need a one-line update by DOC-UPDATER; ELIXIR-DEV greps `docs/` for
  `platform-events` to find it.
