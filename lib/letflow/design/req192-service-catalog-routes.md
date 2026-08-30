# REQ-192 — `Letflow.Routers.Services` / `Letflow.Routers.AdminServices` design

Route/controller layer atop REQ-191's `Letflow.ServiceCatalog` context module
and REQ-069's `Letflow.Api.Authorization` matrix (SVC-04). This design covers
**only** two new router modules and their mount points — no change to
`Letflow.ServiceCatalog`, `Letflow.ServiceCatalog.Entry`, the
`service_catalog` migration, or `lib/letflow/api/authorization.ex`, per this
requirement's own "NOT IN THIS REQUIREMENT" note. No file under `web/` is
touched; `web/src/api/services.ts` and `web/src/types/api.ts` are read-only
inputs.

## §0 — Contract sources (moduledoc-mandated statement)

Both new router moduledocs MUST state, verbatim in substance:

> R-Co's `src/api/routes/services.zig` (417 lines) has five handlers —
> `handleListServices` (L27), `handleAdminListServices` (L62),
> `handleAdminRegisterService` (L93), `handleAdminUpdateService` (L175),
> `handleAdminDeleteService` (L233) — matching the five routes below
> one-for-one. The binding contract actually consulted while drafting this
> route layer is the already-shipped SPA consumer, `web/src/api/services.ts`'s
> `servicesApi` object and `web/src/types/api.ts`'s `ServiceRecord`/
> `RegisterServiceBody`/`UpdateServiceScopeBody` types, and the two agree —
> R-Co's route shape is corroborating evidence, not itself re-verified line by
> line against a live R-Co checkout.

## §1 — Two router modules, one per mount prefix (not one router, two mounts)

`Letflow.Api.AuthorizedRouter`'s `authz_get`/`authz_post`/`authz_patch`/
`authz_delete` macros attach a **compile-time literal** policy key as
route-match `:private` metadata (`lib/letflow/api/authorized_router.ex`
L91-127) — the policy key enforced at runtime never depends on the router's
mount prefix. But `test/letflow/api/authorization_enforcement_test.exs`
cross-checks each router's own `__authz_routes__/0` against
`Letflow.Api.Authorization.endpoint_policy_key/2` by computing
`@mount_prefix[router] <> local_path` (test file L61-73, L77-87) — a strict
one-router-to-one-mount-prefix table with no existing precedent for a single
router module mounted twice at two different prefixes. `GET /services` and
the four `/admin/services...` routes need two different full external paths
(`"/services"` vs `"/admin/services"` and its children) to match the already-
shipped `endpoint_policy_key/2` clauses (`authorization.ex` L308-313): `GET
"/services"` → `:ServicesRead`; `GET "/admin/services"` → `:AdminServicesRead`;
and any of `POST`/`PATCH`/`DELETE` on a path starting with `"/admin/services"`
→ `:AdminServicesManage` (a prefix-match clause covering
`/admin/services/:service_id` too).

So this design specifies **two** router modules, matching the existing
1-router-per-mount-prefix shape exactly (`dlq.ex`/`webhooks.ex`'s own
precedent), rather than inventing a dual-mount exception:

* `lib/letflow/routers/services.ex`, `defmodule Letflow.Routers.Services` —
  one route, `GET /`.
* `lib/letflow/routers/admin_services.ex`, `defmodule Letflow.Routers.AdminServices`
  — four routes, `GET /`, `POST /`, `PATCH /:service_id`, `DELETE /:service_id`.

Both `use Letflow.Api.AuthorizedRouter` (gives `plug(:match)` →
`plug(Letflow.Plugs.Authorize)` → `plug(:dispatch)` for free, same idiom as
`Letflow.Routers.Dlq`).

## §2 — Mount points (`lib/letflow/plugs/api_pipeline.ex`)

Two new `forward` declarations, added to the same list that already forwards
`"/dlq"` and `"/webhooks"`: one forwarding the `"/services"` prefix to
`Letflow.Routers.Services`, one forwarding the `"/admin/services"` prefix to
`Letflow.Routers.AdminServices` — same `forward(prefix, to: module)` idiom
every existing entry in that list already uses.

Full paths under `/api/v1`: `GET /api/v1/services`, `GET /api/v1/admin/services`,
`POST /api/v1/admin/services`, `PATCH /api/v1/admin/services/:service_id`,
`DELETE /api/v1/admin/services/:service_id` — matching `web/src/api/services.ts`'s
`servicesApi` calls exactly. This is the one line-pair of that file this
requirement touches; both router modules are entirely new.

**Required companion test-fixture change (not itself an acceptance
criterion, but load-bearing for `mix test` to pass, AC10):**
`test/letflow/api/authorization_enforcement_test.exs`'s `@all_routers` list
and `@mount_prefix` map (L55-87) must gain two new entries:
`Letflow.Routers.Services => "/services"` and
`Letflow.Routers.AdminServices => "/admin/services"`. This is a test-fixture
addition, not new production logic — named here so ELIXIR-DEV doesn't
discover the enforcement test failing on an unmapped router as a surprise.

## §3 — Route table and policy keys

| Method | Local path | Policy key | Full path | Permission (existing `required_permission/1`) |
|---|---|---|---|---|
| GET | `/` (Services) | `:ServicesRead` | `/services` | `:DefinitionsRead` — every role except `:AGENT_RUNNER` |
| GET | `/` (AdminServices) | `:AdminServicesRead` | `/admin/services` | `:UsersGroupsRolesManage` — `:PLATFORM_ADMIN` only |
| POST | `/` (AdminServices) | `:AdminServicesManage` | `/admin/services` | `:UsersGroupsRolesManage` — `:PLATFORM_ADMIN` only |
| PATCH | `/:service_id` (AdminServices) | `:AdminServicesManage` | `/admin/services/:service_id` | `:UsersGroupsRolesManage` — `:PLATFORM_ADMIN` only |
| DELETE | `/:service_id` (AdminServices) | `:AdminServicesManage` | `/admin/services/:service_id` | `:UsersGroupsRolesManage` — `:PLATFORM_ADMIN` only |

No new `endpoint_policy_key/2` or `required_permission/1` clause, no new
permission atom, no new role clause in `role_allows?/2` — all five clauses
already exist (verified against `authorization.ex` L308-313, L428-430,
L451-484). Per `role_allows?/2`'s existing matrix, `:PROCESS_DESIGNER`,
`:PROCESS_OPERATOR`, and `:TASK_WORKER` all hold `:DefinitionsRead` (so AC1's
"any authenticated caller" holds for `GET /services`); none of the four
non-`PLATFORM_ADMIN` roles holds `:UsersGroupsRolesManage`, so AC2's "a caller
holding only `:ServicesRead` receives 403 [on `/admin/services`]" and AC4's
three 403 tests follow directly from the existing matrix with no new wiring.

**Finding, not silently fixed (per the handoff's explicit instruction):**
`required_permission/1`'s own comment above the `:AdminServicesManage`/
`:AdminServicesRead` clause reads `# platform-admin enforced in handler, per
Zig's comment` — but no handler-level `PLATFORM_ADMIN`-only check exists or is
proposed anywhere in this design; the `:UsersGroupsRolesManage` permission
mapping is what actually restricts these two policy keys to `PLATFORM_ADMIN`
alone (since only `PLATFORM_ADMIN`'s `role_allows?/2` catch-all grants it).
The stale comment implies a second, handler-side gate that was never built —
either in R-Co or here. This design does not add one (out of scope, and the
permission mapping already achieves the stated effect); flagged for
REVIEWER to decide whether the comment should be corrected in a future,
`authorization.ex`-scoped requirement.

## §4 — `GET /api/v1/services` (design §"handler: list_for_tenant")

Query params: `page_size` (optional, parsed exactly like
`Letflow.Routers.Dlq.handle_list/1`'s own two-step
`Pagination.parse_page_size_param/1` → `Pagination.validate_page_size/1`
pipeline — `{:error, :invalid_page_size}`/`{:error, :page_size_too_large}` →
`Response.bad_request/2`), `cursor` (optional, empty string folds to `nil`
via the same `non_empty/1` helper `Dlq` uses).

Tenant id comes from `conn.assigns.auth_context.tenant_id` (REQ-072,
already populated by `Letflow.Plugs.AuthPipeline` before this router runs) —
**not** `conn.assigns.scoped_opts`, since `service_catalog` is a global table
with no `[prefix: schema]` concept (`ServiceCatalog`'s own moduledoc, "No
`opts[:prefix]` on any function" section). This mirrors how every other S6
context-module call site derives its tenant/prefix argument from
`conn.assigns`, just reading a different assign for this one global-table
router.

Calls `Letflow.ServiceCatalog.list_for_tenant(params, tenant_id)` with
`params :: Letflow.ServiceCatalog.list_params()` (`%{cursor: ..., page_size:
...}`). Result mapping:

| `list_for_tenant/2` result | HTTP |
|---|---|
| `{:ok, %{items: items, next_cursor: next_cursor}}` | 200, `%{"items" => Enum.map(items, &service_record_json/1), "next_cursor" => next_cursor}` — exactly two top-level keys, matching `Letflow.Routers.Dlq`'s own documented divergence from the full `CursorPage<T>` shape (design §7 below) |
| `{:error, :invalid_cursor \| :wrong_endpoint \| :expired}` | 400, `Response.bad_request(conn, "invalid cursor")` |

`list_for_tenant/2`'s own visibility rule (global entries + this tenant's own
scoped entries) is exactly AC1's requirement — no additional filtering
needed in the router.

## §5 — `GET /api/v1/admin/services` — no backing "list all" function (finding + resolution)

**Gap, named explicitly:** `Letflow.ServiceCatalog` exposes exactly five
functions — `register/1`, `get_for_tenant/2`, `list_for_tenant/2`,
`update_scope/2`, `delete/1` — and `list_for_tenant/2` always filters by
`tenant_id` (`where: e.scope == :global or e.owner_tenant_id == ^tenant_id`).
There is no tenant-independent "list every row" function, and this
requirement's own "NOT IN THIS REQUIREMENT" note forbids adding one to
`service_catalog.ex`. AC2 ("returns entries the caller's own tenant does not
own, demonstrating it is not tenant-filtered") cannot be satisfied by calling
`list_for_tenant/2` with any `tenant_id`.

**Resolution specified here (not left as an open question, since AC2 must be
buildable):** `Letflow.Routers.AdminServices`'s `GET /` handler queries
`Letflow.ServiceCatalog.Entry` directly via `Letflow.Repo` and
`Letflow.Api.Pagination`'s public encode/decode functions
(`build_raw_cursor/3`, `encode_cursor/1`, `decode_cursor/3`) — reusing the
exact keyset shape `list_for_tenant/2` already established
(`order_by: [desc: created_at, desc: service_id]`, `limit(page_size + 1)`,
drop-the-extra-row split) but with **no** `where` clause restricting scope or
owner. This is new query logic living in the router module, not a change to
any file under the "NOT IN THIS REQUIREMENT" list — `Letflow.ServiceCatalog.Entry`
is a public schema module already `alias`ed elsewhere (e.g. inside
`Letflow.ServiceCatalog` itself), and no acceptance criterion or "NOT IN THIS
REQUIREMENT" clause forbids a router from constructing its own `Ecto.Query`
against an already-public schema.

**This is not backed by existing precedent — it is a deliberate, first-of-its-kind
exception, flagged here for REVIEWER sign-off, not something this design rests
on prior art.** Every other router in this codebase (`Letflow.Routers.Audit`
delegates to `Letflow.EventStore.read_global/1`; `Letflow.Routers.Metrics`
delegates to `Letflow.Engine.count_instances_by_status/1` and sibling
context-module functions) reaches its data exclusively through a context
module — a repo-wide `grep -rln 'Ecto.Query|Repo\.(all|one|get)'
lib/letflow/routers/` turns up no genuine direct-schema-query call anywhere in
the router layer today. This design deliberately breaks that layering
discipline for this one handler, solely because (a) this requirement's own
"NOT IN THIS REQUIREMENT" boundary forbids adding a tenant-agnostic list-all
function to `service_catalog.ex`, and (b) AC2 cannot be satisfied any other
way under that boundary. REVIEWER must independently weigh and explicitly
sign off on this exception at Step 2d — it is not to be treated as routine or
pre-approved by analogy to anything already in the codebase.

Cursor prefix: **must be different from `"SC:"`** (`ServiceCatalog`'s own
`@list_cursor_prefix`) — `Pagination.decode_cursor/3`'s whole point is
cross-endpoint cursor isolation (INV-9), so a cursor minted by `GET /services`
must be rejected (`{:error, :wrong_endpoint}` → 400) if replayed against
`GET /admin/services` and vice versa. This design assigns
`"SCA:"` ("Service Catalog Admin") as the admin-list router's own prefix
constant, module-private to `Letflow.Routers.AdminServices`.

**Named as a finding for REVIEWER (in addition to the layering exception
above):** this duplicates `list_for_tenant/2`'s keyset-pagination shape
(order/limit/split-page logic) at the router layer, which is not ideal but is
the only option that respects the "no change to REQ-191's schema or context"
scope boundary. A future, `service_catalog.ex`-scoped requirement should
consider hoisting a shared, tenant-agnostic `list_all/1` (or an
`opts[:tenant_id] :: :any | Ecto.UUID.t()` parameter on `list_for_tenant/2`)
into the context module, deleting this duplication, and retiring the
direct-schema-query exception entirely. Not resolved here — out of scope,
flagged rather than silently accepted as permanent.

Result mapping is otherwise identical to §4's table (200 with the two-key
envelope; cursor errors → 400).

## §6 — `POST /api/v1/admin/services` (register)

Request body → `Letflow.ServiceCatalog.register_attrs()` translation table
(every key not listed passes through unchanged, atom-keyed):

| `RegisterServiceBody` JSON key | `register_attrs()` key | Note |
|---|---|---|
| `service_id` | `:service_id` | direct |
| `endpoint_url` | `:endpoint_url` | direct |
| `scope` | `:scope` | direct, string `"global"`/`"tenant"` — `register_attrs()`'s own type accepts `atom() \| String.t()` |
| `owner_tenant_id` | `:owner_tenant_id` | direct, absent key → `nil`/omitted |
| **`auth_method`** | **`:required_auth`** | **name translation, not a passthrough** — see finding below |
| `timeout_ms` | `:timeout_ms` | direct |
| `request_schema` | `:request_schema` | direct |
| `response_schema` | `:response_schema` | direct |
| `max_retries` | *(dropped — no `register_attrs()` key exists)* | see §8 finding |

**`auth_method` → `:required_auth` is a deliberate translation, not a
"mapping that looks wrong."** `RegisterServiceBody`'s own field is literally
named `auth_method`, while `ServiceRecord`'s corresponding output field (and
`Entry`'s column, and `register_attrs()`'s key) is `required_auth` — this
asymmetry already exists in `web/src/api/services.ts` itself (both names are
already in the frozen wire contract this requirement must not edit), so the
router's job is exactly to bridge it, the same way every other POST handler
in this codebase translates a JSON body into a context module's expected
attrs map.

Result mapping:

| `register/1` result | HTTP |
|---|---|
| `{:ok, entry}` | 201, `service_record_json(entry)` (§7) |
| `{:error, :tenant_not_found}` | 422, `Response.unprocessable(conn, "owner_tenant_id does not name an existing tenant")` |
| `{:error, :duplicate_service_id}` | 409, `Response.conflict(conn, "service_id already registered")` — AC6. No row is modified (`register/1`'s own insert never touches an existing row on a PK conflict). |
| `{:error, %Ecto.Changeset{}}` | 422, `Response.unprocessable(conn, "validation failed")` — same convention as `identity.ex`/`tenants.ex`/`onboarding.ex` (`{:error, %Ecto.Changeset{}} -> Response.unprocessable(conn, "validation failed")`, verified at `identity.ex` L253 et al.) |

## §7 — `service_record_json/1` — response allowlist (INV-2)

Hand-built, matching `Letflow.Routers.Dlq.dlq_entry_json/1`'s own precedent
(never a raw `Jason.Encoder` derivation over `%Entry{}`, which would leak
`__meta__`). Every key `web/src/types/api.ts`'s `ServiceRecord` names, each
sourced from the identically-named `Entry` field except where noted:

| `ServiceRecord` key | Source |
|---|---|
| `service_id` | `entry.service_id` |
| `endpoint_url` | `entry.endpoint_url` |
| `request_schema` | `entry.request_schema` (may serialize as JSON `null` — see §8) |
| `response_schema` | `entry.response_schema` (may serialize as JSON `null` — see §8) |
| `required_auth` | `Atom.to_string(entry.required_auth)` |
| `timeout_ms` | `entry.timeout_ms` |
| `max_retries` | **omitted — see §8 finding, following `Letflow.Routers.Dlq`'s own precedent for a `ServiceRecord`/`DlqEntry` field with no backing column** |
| `scope` | `Atom.to_string(entry.scope)` |
| `owner_tenant_id` | `entry.owner_tenant_id` |
| `created_at` | `DateTime.to_iso8601(entry.created_at)` |
| `updated_at` | `DateTime.to_iso8601(entry.updated_at)` |

`retry_policy` (an `Entry` column with no `ServiceRecord` counterpart) is
**not** emitted — the allowlist runs field-list-first from `ServiceRecord`,
same direction `dlq_entry_json/1` runs it, so a column the wire type doesn't
name is simply never added to the map, no explicit exclusion logic needed.

## §8 — Findings: two real `ServiceRecord`/`Entry` contract gaps (not silently resolved)

Per the handoff's explicit instruction ("if a mapping looks wrong, name it as
a finding... don't silently fix it"), both gaps below are named for REVIEWER,
with a concrete, buildable interim resolution stated so this design leaves no
"TBD":

1. **`ServiceRecord.max_retries: number` has no backing column anywhere.**
   `Entry` has `retry_policy :: String.t() | nil` (a policy description, not a
   retry count), and neither `RegisterServiceBody` nor `UpdateServiceScopeBody`
   carries any field that could populate a retry-count column even if one
   existed. **Interim resolution:** `max_retries` is omitted from every
   `service_record_json/1` output (§7), following `Letflow.Routers.Dlq`'s own
   already-reviewer-accepted precedent for exactly this situation (`dlq.ex`'s
   moduledoc, "Response allowlist (INV-2)" section: "`DlqEntry`'s TS type also
   declares... optional fields with no corresponding `Letflow.Dlq.Entry`
   column — these are not emitted"). **Consequence for TEST-DESIGNER:** AC3's
   "asserted field by field" must be read as "every field this design can
   actually source" — the test asserting `service_record_json/1`'s output
   must explicitly document (in a comment, not silently) that `max_retries`
   is excluded from the field-by-field comparison, pointing at this section.
   TEST-DESIGN-VALIDATOR should not fail the suite over this specific,
   pre-flagged omission.

2. **`request_schema`/`response_schema` are non-nullable, required `string`
   in `ServiceRecord` and `RegisterServiceBody`, but nullable on `Entry` and
   optional in `register_attrs()`.** A row registered without either field
   (both are `optional()` in `register_attrs()`) serializes as JSON `null`
   for that key, which is not a valid instance of the declared TS `string`
   type. **Interim resolution:** no coercion is invented here (e.g. `""` as a
   fallback would silently misrepresent "no schema was supplied" as "an empty
   schema was supplied", which is worse). The router serializes the true
   column value, `null` included, matching how `Letflow.Routers.Dlq` already
   treats its own several nullable-but-TS-non-optional fields (e.g.
   `next_retry_at`) — a real, pre-existing pattern in this codebase, not a new
   divergence. `RegisterServiceBody`'s own required-ness is a POST-body
   validation concern for whichever caller populates it; this design does not
   add server-side "reject if empty" validation beyond what
   `insert_changeset/2` already enforces (neither field is in that
   changeset's `validate_required/2` list), since inventing new business
   validation is out of this requirement's scope.

## §9 — `PATCH /api/v1/admin/services/:service_id` (update scope)

Body → `Letflow.ServiceCatalog.update_scope_attrs()`: `{scope,
owner_tenant_id}` — a direct 1:1 field-name match with `UpdateServiceScopeBody`,
no translation needed.

Result mapping:

| `update_scope/2` result | HTTP |
|---|---|
| `{:ok, entry}` | 200, `service_record_json(entry)` |
| `{:error, :not_found}` | **404, never a scope-narrowing-specific error** — REQ-072's cross-tenant rule (AC7) also governs a `service_id` that is simply absent; `update_scope/2` itself returns the identical `{:error, :not_found}` atom for both "row does not exist" and (per §10 below) "row exists but the caller's admin path still must not disclose a tenant-scoped row belonging elsewhere" scenarios — see §10 for why no extra 404 mapping logic is needed on this admin path specifically |
| `{:error, {:referenced_by_active_definitions, conflicts}}` | 409 — AC5, second test. `conflicts :: [Letflow.ServiceCatalog.reference_conflict()]`, each `%{tenant_id: ..., definition_ids: [...]}`. Body: `Response.send_problem(conn, Letflow.Api.Error.???)` — see §11 for the exact `Error` constructor this design specifies (a new one, since none of the existing per-status constructors carries a structured `conflicts` extension list except `Error.promotion_conflict/2`, which is promotion-specific by name and type) |
| `{:error, %Ecto.Changeset{}}` | 422, `Response.unprocessable(conn, "validation failed")` |

## §10 — Cross-tenant-404 on the non-admin path (AC7, REQ-072)

AC7 says the rule applies to "a request naming a tenant-scoped service
belonging to another tenant **on the non-admin path**" — i.e. `GET
/api/v1/services` (via `get_for_tenant/2`, if a single-item GET existed) is
where SVC-01's non-disclosure rule actually applies. **This requirement's
route list has no single-item `GET /services/:service_id`** (`servicesApi`
names no such call, and R-Co's five handlers listed in §0 have none either)
— `list_for_tenant/2` is the only non-admin read, and it already only
*includes* visible rows by construction (§4), so there is no "another
tenant's row, disguised as 404 vs 403" branch to build for the list endpoint;
a row belonging to another tenant is simply absent from the page, which is
the listing-level expression of the same non-disclosure rule
`get_for_tenant/2`'s own moduledoc states for the single-item case.

**Where AC7 actually bites in this router set:** none of the five routes in
scope calls `get_for_tenant/2` at all — every admin route
(`GET/POST/PATCH/DELETE /admin/services...`) is intentionally
non-tenant-filtered (§3, §5), and the one non-admin route is the list. So
this design's concrete claim is: **AC7 is satisfied by construction on `GET
/services` (list omits the row) and does not apply to any `/admin/services`
route (those routes see every row regardless of tenant, by design, and 404
there means only "no such `service_id` exists at all").** If
TEST-DESIGN-VALIDATOR or REVIEWER judges this insufficient — e.g. expects a
literal "PATCH/DELETE a real, other-tenant-owned `service_id` via the
*non-admin* path returns 404" test — note that no non-admin write path exists
for `PATCH`/`DELETE` to test against; flagging this explicitly rather than
inventing a route not named in the requirement.

## §11 — 409 problem-details bodies (REQ-066 convention) — new `Error` constructors

`Letflow.Api.Response.conflict/2` takes only a `detail :: String.t()` — it
cannot carry a structured list of conflicting ids. The one existing
precedent for a 409 with a structured id list is
`Letflow.Api.Error.promotion_conflict/2` (`error.ex` L351-360), which builds
a `t()` with `type` set to the problems-base URI plus `"promotion-conflict"`,
`title: "Promotion Conflict"`, `status: 409`, the caller-supplied `detail`
string, and `extensions: %{"conflicts" => conflicts}` — the one field that
carries structured, non-string conflict data in an RFC 9457 body anywhere in
this codebase today.

This design specifies **two new, service-catalog-specific constructors** in
the same shape (added to `lib/letflow/api/error.ex` by ELIXIR-DEV as part of
this requirement's implementation — this is new-constructor-addition, not a
change to any existing clause, so it does not conflict with the "consume
`authorization.ex` as-is" instruction, which names a different file):

* `Error.service_referenced_by_active_definitions/1` — takes
  `definition_ids :: [String.t()]` (the delete-path shape, AC5 first test).
  `type: @problems_base <> "service-referenced-by-active-definitions"`,
  `title: "Service Referenced By Active Definitions"`, `status: 409`,
  `detail: "the service is referenced by one or more ACTIVE process
  definitions"`, `extensions: %{"definition_ids" => definition_ids}`.
* `Error.service_scope_narrowing_conflict/1` — takes
  `conflicts :: [Letflow.ServiceCatalog.reference_conflict()]` (the
  update-scope-path shape, AC5 second test, `[%{tenant_id: ..., definition_ids:
  [...]}]`). `type: @problems_base <> "service-scope-narrowing-conflict"`,
  `title: "Service Scope Narrowing Conflict"`, `status: 409`, `detail: "other
  tenants' ACTIVE process definitions still reference this service"`,
  `extensions: %{"conflicts" => Enum.map(conflicts, fn c -> %{"tenant_id" =>
  c.tenant_id, "definition_ids" => c.definition_ids} end)}` (string-keyed map,
  matching `promotion_conflict/2`'s own string-keyed `extensions` convention
  — `Error.serialise/1`'s `Jason.encode!/1` call requires JSON-safe keys
  throughout).

Both routers call these via `Response.send_problem(conn, Error.xxx(...))`,
the same pattern `promotions.ex` already uses for
`Error.promotion_conflict/2` (verified call sites, `promotions.ex` L314-319).

**Alternative considered and rejected:** reusing `Error.promotion_conflict/2`
directly with a service-flavored `detail` string. Rejected because its `type`/
`title` are hardcoded to "promotion-conflict"/"Promotion Conflict" — a caller
introspecting the RFC 9457 `type` URI to distinguish conflict categories
would misclassify a service-catalog conflict as a promotion one. Two small,
named constructors cost little and keep `type` accurate.

## §12 — `DELETE /api/v1/admin/services/:service_id`

Result mapping:

| `delete/1` result | HTTP |
|---|---|
| `:ok` | `Response.no_content(conn)` (204, empty body) — confirmed present at `lib/letflow/api/response.ex` L91 (`def no_content(conn), do: send_resp(conn, 204, "")`) |
| `{:error, :not_found}` | 404, `Response.not_found(conn)` |
| `{:error, {:referenced_by_active_definitions, definition_ids}}` | 409, `Response.send_problem(conn, Error.service_referenced_by_active_definitions(definition_ids))` — AC5, first test |

## §13 — Cross-cutting: 403 tests (AC4)

Three explicit tests, one per write route
(`POST /admin/services`, `PATCH /admin/services/:service_id`,
`DELETE /admin/services/:service_id`), each asserting 403 for a caller whose
`auth_context.roles` holds none of `:PLATFORM_ADMIN` (e.g. a
`:PROCESS_DESIGNER` caller) — `Letflow.Plugs.Authorize` produces this 403
before either router's handler code ever runs, per `:AdminServicesManage`'s
existing `required_permission/1`/`role_allows?/2` mapping (§3). No handler
code is exercised by these three tests; they are effectively plug-pipeline
tests, same shape as REQ-131's own enforcement test style.

## §14 — Explicitly out of scope (restated from the requirement text)

* No change to `Letflow.ServiceCatalog`, `Letflow.ServiceCatalog.Entry`, or
  the `service_catalog` migration.
* No change to `lib/letflow/api/authorization.ex` (all five policy-key/
  permission clauses already exist and are consumed as-is).
* No change to any file under `web/`.
* No process-module routes (`PLC-01`, out of scope per REQ-191's own "NOT IN
  THIS REQUIREMENT" note, inherited here).
* No single-item `GET /services/:service_id` route (not named by
  `servicesApi` or R-Co's five handlers — see §10).

## §15 — Open questions (OQ), left explicit rather than guessed

* **OQ-1 (§5).** Whether `GET /api/v1/admin/services`'s router-local
  duplicate-of-`list_for_tenant/2` query logic should instead become a real
  `Letflow.ServiceCatalog` function in a follow-up requirement that revisits
  the "no context-module change" scope boundary. Flagged for REVIEWER, not
  decided here.
* **OQ-2 (§8).** Whether `max_retries`'s absence from `Entry` should be
  closed by a future migration (adding a real column) or by editing
  `web/src/types/api.ts` to mark it optional/removing it — both are out of
  this requirement's scope (schema and `web/` are both frozen inputs here).
  Flagged for REVIEWER/a future requirement to pick a side.
* **OQ-3 (§12) — resolved, not actually open.** Confirmed `Response.no_content/1`
  exists (`lib/letflow/api/response.ex` L91) and is used verbatim in §12.
  Left as a numbered note only so a future reader sees it was checked rather
  than assumed.
