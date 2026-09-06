# REQ-182 design: webhook subscription route layer

Status: draft for CODE-DESIGN-VALIDATOR review.
Owner requirement: REQ-182 (`docs/requirements.yaml`), stage S6.
Depends on: REQ-181 (`Letflow.Webhooks` context, shipped), REQ-069 (authorization
matrix), REQ-072 (INV-5 cross-tenant-404 mechanism).

## 0. Contract source (mandatory disclosure, AC6)

PROVENANCE (historical, not current decision authority):
R-Co's `webhooks.zig` was **not inspected** while drafting this design — R-Co lives
at a Windows path (`c:\Users\tvolo\dev\ai-dala\R-Co\`) unreachable from this
drafting sandbox, verified absent, not assumed covered. The binding contract
instead is the already-shipped SPA consumer: `web/src/api/dlq.ts`'s `webhooksApi`
object (`list`, `create`, `update`, `delete`, plus the out-of-scope
`getDeliveries`) and `web/src/types/api.ts`'s `WebhookSubscription` type. The
route module's own moduledoc must restate this verbatim (AC6) — this is not
satisfied by this design document alone.

The most directly analogous already-shipped route layer is
`lib/letflow/routers/dlq.ex` (REQ-178) — same `AuthorizedRouter` idiom, same
cross-tenant-404-via-context-module-scoping pattern, same hand-built JSON
allowlist. This design reuses that module's idioms rather than inventing new
ones, restated below per element.

## 1. Scope boundary

In scope: one new router module, `lib/letflow/routers/webhooks.ex`, exposing
four routes atop REQ-181's already-shipped `Letflow.Webhooks` context module —
**no changes to that module, `Letflow.Webhooks.Subscription`, or the
`webhook_subscriptions` migration.** Also in scope: one new mount line in
`Letflow.Plugs.ApiPipeline`, and one new `Letflow.Api.Authorization.endpoint_policy_key/2`
clause (§4.4 below — a real gap this design found, not assumed).

Out of scope: delivery attempts, dispatch, HMAC signing, the
`GET /api/v1/webhooks/subscriptions/:id/deliveries` route (REQ-183/REQ-184) —
`webhooksApi.getDeliveries` is not wired by this router.

## 2. Route table

| Method | Path (mounted) | Local `Plug.Router` pattern | Policy key | Calls |
|---|---|---|---|---|
| GET | `/api/v1/webhooks/subscriptions` | `"/"` | `:WebhookSubscriptionsManage` | `Letflow.Webhooks.list/1` |
| POST | `/api/v1/webhooks/subscriptions` | `"/"` | `:WebhookSubscriptionsManage` | `Letflow.Webhooks.create/2` |
| PATCH | `/api/v1/webhooks/subscriptions/:id` | `"/:id"` | `:WebhookSubscriptionsManage` | `Letflow.Webhooks.update/3` |
| DELETE | `/api/v1/webhooks/subscriptions/:id` | `"/:id"` | `:WebhookSubscriptionsManage` | `Letflow.Webhooks.delete/2` |

Mount: `Letflow.Plugs.ApiPipeline` gains
`forward("/webhooks", to: Letflow.Routers.Webhooks)`, alongside the existing
`forward("/dlq", to: Letflow.Routers.Dlq)` line — added, no existing `forward`
line touched. The router itself declares a local sub-path `/subscriptions`
(list/create) and `/subscriptions/:id` (patch/delete) — i.e. the router's own
`Plug.Router` match patterns are `"/subscriptions"` and `"/subscriptions/:id"`,
matching `Letflow.Routers.Dlq`'s own local-pattern convention of naming the
resource under the router's mount rather than mounting one router per
resource-collection level. (Equivalently: mount at `/webhooks`, router patterns
`"/subscriptions"` / `"/subscriptions/:id"` — never mount at `/webhooks/subscriptions`
directly, since `Letflow.Api.Authorization.endpoint_policy_key/2`'s
already-shipped clauses, §4.4, are written against the full external path
`/webhooks/subscriptions...`.)

All four routes declared via `authz_get "/subscriptions", :WebhookSubscriptionsManage
do ... end`, `authz_post "/subscriptions", :WebhookSubscriptionsManage do ... end`,
`authz_patch "/subscriptions/:id", :WebhookSubscriptionsManage do ... end`,
`authz_delete "/subscriptions/:id", :WebhookSubscriptionsManage do ... end` —
the `Letflow.Api.AuthorizedRouter` macros already used by every other router
under `lib/letflow/routers/`, same shape as `Letflow.Routers.Dlq`'s own
`authz_get "/", :DlqReadRetryDiscard do ... end` line. A final `match _ do
Letflow.Api.Response.not_found(conn) end` catch-all closes the router, mirroring
`Letflow.Routers.Dlq`'s own trailing catch-all.

Each handler reads `conn.assigns.scoped_opts` (the `[prefix: schema]` keyword
list `Letflow.Plugs.Authorize` already assigns before any handler body runs)
and threads it as the `opts` argument to the matching `Letflow.Webhooks`
function — never constructing its own prefix, never reading
`conn.assigns.auth_context` directly. This is the same call shape
`Letflow.Routers.Dlq`'s `handle_get/3`/`handle_retry/3`/`handle_discard/3`
already establish for `Letflow.Dlq`.

## 3. Handler-to-context-function param mapping

### 3.1 GET `/subscriptions` -> `Letflow.Webhooks.list/1`

No query params accepted (mirrors `webhooksApi.list()` taking none, and
`Letflow.Webhooks.list/1`'s own signature taking only `opts`). Handler calls
`Letflow.Webhooks.list(conn.assigns.scoped_opts)`, which always returns `{:ok,
subscriptions}` (no error branch in `list/1`'s own `@spec`). Response body:
`%{"items" => Enum.map(subscriptions, &subscription_json/1)}` (§5 for the
allowlist) — status 200 via `Letflow.Api.Response.ok/2`.

### 3.2 POST `/subscriptions` -> `Letflow.Webhooks.create/2`

Request body (`conn.body_params`, already JSON-decoded by
`Plug.Parsers`/`Plug.Router` upstream in `Letflow.Plugs.ApiPipeline`) is
validated to be a JSON object (mirrors `Letflow.Routers.Definitions`'s own
"request body must be a JSON object" `Response.bad_request/2` branch) before
being narrowed to `Letflow.Webhooks.create_attrs()`'s three optional keys plus
the one required key:

| Body key | Maps to `create_attrs()` key | Required |
|---|---|---|
| `target_url` | `:target_url` | yes — absent/blank -> `Response.bad_request/2` before `create/2` is ever called, since `create/2`'s own `@spec` has no dedicated "missing required field" error tuple distinct from `Ecto.Changeset.t()`; a route-layer presence pre-check keeps the changeset-error branch reserved for genuine persistence-shape failures, matching `Letflow.Routers.Dlq`'s own precedent of routing param-shape problems to `bad_request` before ever calling the context module |
| `secret` | `:secret` | no |
| `description` | `:description` | no |
| `event_types` | `:event_types` | no |

Handler calls `Letflow.Webhooks.create(narrowed_attrs, conn.assigns.scoped_opts)`.

Result mapping:
- `{:ok, %{subscription: subscription, hmac_secret_once: plaintext}}` ->
  `Letflow.Api.Response.created/2` (201) with body =
  `subscription_json(subscription) |> Map.put("hmac_secret_once", plaintext)`
  — the **only** call site in this router (or anywhere reachable from it) that
  ever adds an `hmac_secret_once` key to a response body. `subscription_json/1`
  itself (§5) never emits this key from any `Subscription` struct field,
  because no such field exists on the struct (REQ-181's schema, confirmed by
  reading `lib/letflow/webhooks/subscription.ex`) — the key is spliced onto the
  create response's map deliberately, once, by this one branch, not derived
  from the struct.
- `{:error, %Ecto.Changeset.t{}}` -> `Letflow.Api.Response.unprocessable/2`
  with a fixed, non-interpolated detail string (never rendering raw changeset
  internals into the response body — same discipline `Letflow.Routers.Dlq`
  applies to its own error branches, never surfacing an `Ecto.Changeset`
  verbatim).

### 3.3 PATCH `/subscriptions/:id` -> `Letflow.Webhooks.update/3`

Request body validated as a JSON object first (same `bad_request` branch as
§3.2). The body is passed through to `Letflow.Webhooks.update/3`'s
`update_attrs()` **as-is**, narrowed only to the two keys that type accepts
(`:status`, `:is_active`) — this router does no reconciliation of its own;
`update/3`'s own `reconcile_status/1` (already shipped, REQ-181) is the single
place that logic lives, matching the requirement's explicit "no change to
REQ-181's ... context module" scope line.

Handler calls `Letflow.Webhooks.update(conn.params["id"], narrowed_attrs,
conn.assigns.scoped_opts)`.

Result mapping:

| `update/3` return | Response |
|---|---|
| `{:ok, subscription}` | `Response.ok/2` with `subscription_json(subscription)` |
| `{:error, :not_found}` | `Response.not_found/1` |
| `{:error, :invalid_id}` | `Response.not_found/1` — folds together with `:not_found`, same indistinguishability §4.3 requires for GET/DELETE; a malformed id is cross-tenant-probeable exactly like a well-formed one belonging to another tenant, so both must read identically to the caller |
| `{:error, :invalid_status}` | `Response.bad_request/2` — this is a request-shape problem (neither `status` nor `is_active` present, or the two disagree, or an out-of-enum string), not a not-found/permission concern, so it is the one `update/3` error branch that does NOT fold into 404 |
| `{:error, %Ecto.Changeset.t{}}` | `Response.unprocessable/2` with a fixed detail string |

### 3.4 DELETE `/subscriptions/:id` -> `Letflow.Webhooks.delete/2`

Handler calls `Letflow.Webhooks.delete(conn.params["id"], conn.assigns.scoped_opts)`.

| `delete/2` return | Response |
|---|---|
| `{:ok, _subscription}` | `Response.no_content/1` (204) — matches `webhooksApi.delete`'s `client.delete<void>(...)` consumer, which expects no body |
| `{:error, :not_found}` | `Response.not_found/1` |
| `{:error, :invalid_id}` | `Response.not_found/1` |

A second DELETE of the same id: the first call's `Repo.delete/2` removed the
row, so the second call's `get/2` (private helper `delete/2` composes with)
returns `{:error, :not_found}` — structurally guaranteed by `Letflow.Webhooks`
itself (§"delete/2" moduledoc: "structurally impossible to return a
'duplicate success'"), not by any extra bookkeeping this router adds. This
satisfies AC5's "second DELETE returns 404" directly.

## 4. Authorization

### 4.1 Mechanism

Every route is declared with the compile-time-literal policy key
`:WebhookSubscriptionsManage`, exactly as `Letflow.Routers.Dlq` declares every
one of its four routes with `:DlqReadRetryDiscard`. `Letflow.Plugs.Authorize`
(mounted automatically by `use Letflow.Api.AuthorizedRouter`) resolves this key
against `Letflow.Api.Authorization.evaluate_access/2` before any handler body
runs — a caller without the underlying permission gets `403` from the plug
itself, never reaching a handler, never issuing a `Repo` call.

### 4.2 Real permission mapping (verified against the shipped module, not assumed)

`lib/letflow/api/authorization.ex` already contains, pre-REQ-182:

- `required_permission(:WebhookSubscriptionsManage)` -> `:WebhooksManage`
  (already shipped — no change needed).
- `endpoint_policy_key(method, "/webhooks/subscriptions")` for
  `method in ["POST", "GET"]` -> `:WebhookSubscriptionsManage` (already
  shipped).
- `endpoint_policy_key("GET", "/webhooks/subscriptions/:id/deliveries")` ->
  `:WebhookSubscriptionsManage` (already shipped — belongs to the
  out-of-scope REQ-183/184 route, not built here).
- `endpoint_policy_key("DELETE", "/webhooks/subscriptions/:id")` ->
  `:WebhookSubscriptionsManage` (already shipped).
- `role_allows?(:PLATFORM_ADMIN, _)` -> `true` (catch-all clause, already
  shipped).
- `role_allows?(:PROCESS_OPERATOR, permission)` includes `:WebhooksManage` in
  its allowed-permission list (already shipped).
- `role_allows?(:PROCESS_DESIGNER, ...)`, `role_allows?(:TASK_WORKER, ...)`,
  `role_allows?(:AGENT_RUNNER, ...)` — none of their permission lists include
  `:WebhooksManage` (confirmed by reading every clause in the file); a caller
  holding only one of these three roles gets a `403`.

**Confirmed role set holding `WebhooksManage`: `PLATFORM_ADMIN` and
`PROCESS_OPERATOR` only** — this does NOT mirror `DlqOperate`'s role set by
coincidence, it happens to be identical (both permissions are granted to the
same two roles in the current matrix), but this design verifies it as its own
fact from `role_allows?/2`'s real clauses rather than assuming parity with DLQ.

### 4.3 Gap this design found: the PATCH clause is missing

`lib/letflow/api/authorization.ex` has **no**
`endpoint_policy_key("PATCH", "/webhooks/subscriptions/:id")` clause today.
Without one, `Letflow.Api.AuthorizationEnforcementTest` (which asserts every
`authz_*`-declared route's literal policy key matches what
`endpoint_policy_key/2` independently computes for the same
method+full-path) would fail once `Letflow.Routers.Webhooks` is added to that
test's `@routers`/`@mount_prefix` tables (§4.4 covers whether that addition is
in this requirement's scope). This design specifies the fix as part of
REQ-182's own scope, since the route it protects is this requirement's route:

Add one clause to `lib/letflow/api/authorization.ex`, alongside the three
existing `/webhooks/subscriptions...` clauses (same file, same section,
immediately following the existing `GET .../deliveries` clause per that
file's own ordering convention of grouping by URL prefix):

- `endpoint_policy_key("PATCH", "/webhooks/subscriptions/:id")` must return
  `:WebhookSubscriptionsManage` — the same atom the other three
  `/webhooks/subscriptions...` clauses already return, so `required_permission/1`'s
  existing `:WebhookSubscriptionsManage -> :WebhooksManage` clause covers it
  with no further change.

No new permission atom, no new `role_allows?/2` clause, no new
`required_permission/1` clause — only the one missing `endpoint_policy_key/2`
head for the one HTTP method this requirement newly exposes.

### 4.4 Enforcement-test registration (recommended, flagged not mandated by AC text)

`test/letflow/api/authorization_enforcement_test.exs`'s `@routers` list and
`@mount_prefix` map do not currently include `Letflow.Routers.Dlq` (an
existing, pre-REQ-182 gap this design observes but does not fix — out of
scope) nor, obviously, the not-yet-existing `Letflow.Routers.Webhooks`. No AC
in this requirement's text names this test file. This design flags, for
ELIXIR-DEV/TEST-DESIGNER's judgment, that adding `Letflow.Routers.Webhooks =>
"/webhooks"` to both tables would close the same gap for this router that
already exists for `Dlq`, and is consistent with §4.3's fix — but is not
itself gated by any stated acceptance criterion, so it is not mandated by
this design. **Open question, not silently resolved either way.**

### 4.5 Cross-tenant-404 mechanism (AC3, INV-5)

No new mechanism — inherited verbatim from `Letflow.Webhooks.update/3`'s and
`delete/2`'s own existing, REQ-181-approved behavior, exactly as
`Letflow.Routers.Dlq`'s own moduledoc describes for `Letflow.Dlq`: every
handler's only tenant input is `conn.assigns.scoped_opts`, itself derived
solely from `conn.assigns.auth_context.tenant_id` by
`Letflow.Plugs.Authorize`, before this router's code ever runs (schema-per-tenant,
Decision B). A subscription id that exists only in a different tenant's
Postgres schema is, at the `Repo` level, indistinguishable from an id that
does not exist anywhere — both resolve to `{:error, :not_found}` inside
`Letflow.Webhooks`, and this router's `case`/pattern-match handling (§3.3,
§3.4) maps that one tuple to `Response.not_found/1` for both PATCH and
DELETE, so the response bytes are identical by construction. `:invalid_id`
(malformed UUID) folds into the same `not_found` branch rather than a `400`,
matching `Letflow.Routers.Dlq`'s own deliberate divergence from
`Letflow.Routers.Tasks`'s `:invalid_id -> 400` precedent, for the identical
reason: subscription ids are cross-tenant-probeable UUIDs reachable from the
route path, so a malformed id and a genuinely-absent id must stay
indistinguishable to the caller.

This satisfies AC3's "a caller from a different tenant naming a real
subscription id belonging to tenant A receives 404, never 403" — the
permission check (§4.1) runs first and independently of tenant identity (any
tenant's `PLATFORM_ADMIN`/`PROCESS_OPERATOR` passes it), so a same-permission,
different-tenant caller reaches the handler and gets `404` from the id-scoping
step described here, never a `403`.

## 5. JSON serialization allowlist

`subscription_json/1` — a hand-built map over `Letflow.Webhooks.Subscription`
struct fields, matching `Letflow.Routers.Dlq`'s own `dlq_entry_json/1`
precedent verbatim (never a raw `Jason.Encoder` derivation over the Ecto
struct, which would leak `__meta__`/`tenant_id`/`secret_hash`):

| JSON key | Source struct field | Notes |
|---|---|---|
| `"id"` | `subscription.id` | |
| `"target_url"` | `subscription.target_url` | |
| `"description"` | `subscription.description` | |
| `"event_types"` | `subscription.event_types` | |
| `"status"` | `subscription.status` | `Atom.to_string/1` — `:ACTIVE`/`:PAUSED` -> `"ACTIVE"`/`"PAUSED"`, matching `WebhookSubscription.status`'s exact uppercase-string contract |
| `"consecutive_failures"` | `subscription.consecutive_failures` | |
| `"last_attempt_at"` | `subscription.last_attempt_at` | ISO 8601 string or `null`, same `iso8601/1` helper shape as `Letflow.Routers.Dlq`'s |
| `"last_failure_at"` | `subscription.last_failure_at` | ISO 8601 string or `null` |
| `"paused_at"` | `subscription.paused_at` | ISO 8601 string or `null` |
| `"created_at"` | `subscription.created_at` | ISO 8601 string |

**Never emitted, under any circumstance, by `subscription_json/1`:**
`secret_hash` (the schema's column — has no corresponding
`WebhookSubscription` TS field at all, and is exactly the "hashed secret"
AC1/the task description forbids), `hmac_secret_once` (not a struct field —
structurally cannot appear here; only §3.2's create-response branch ever adds
this key, and only by mutating the map `subscription_json/1` already
produced), `tenant_id`, `__meta__`.

`WebhookSubscription`'s TS type also declares `subscription_id`, `url`,
`is_active`, `max_attempts`, `updated_at` as optional fields with no
corresponding `Letflow.Webhooks.Subscription` column — these are **not
emitted** (no schema-backed source), matching `Letflow.Routers.Dlq`'s own
documented precedent of not emitting a `DlqEntry` TS field that has no real
column behind it. AC4 requires only `target_url`, `event_types`, `status`,
`created_at` to be present — all four are emitted; the remaining columns
above are additionally emitted because they exist on the schema and carry no
secret-shaped risk, matching `dlq_entry_json/1`'s own precedent of emitting
every real column rather than only the AC-named minimum.

List response body: `%{"items" => [...]}` — an exactly-one-key map, no
`next_cursor`/`has_more`, matching `webhooksApi.list()`'s actual consumer
usage (`{ items: WebhookSubscription[] }`, no pagination fields in that type)
rather than the unrelated `CursorPage<T>` shape `Letflow.Dlq`'s list uses —
`Letflow.Webhooks.list/1` itself is deliberately non-paginated (REQ-181's own
moduledoc), so there is no cursor value to surface here even if the TS type
had one.

## 6. Error-shape completeness check

Every return-tuple variant appearing in each of `Letflow.Webhooks`' real
`@spec`s (as read directly from `lib/letflow/webhooks.ex`, not assumed) is
accounted for above:

- `create/2`: `{:ok, %{subscription:, hmac_secret_once:}}` (§3.2), `{:error,
  Ecto.Changeset.t()}` (§3.2). No `:not_found`/`:invalid_id` variant exists on
  this function — none needed here.
- `list/1`: `{:ok, [Subscription.t()]}` only (§3.1) — no error branch to
  handle.
- `update/3`: `{:ok, Subscription.t()}`, `{:error, :invalid_id}`, `{:error,
  :not_found}`, `{:error, :invalid_status}`, `{:error, Ecto.Changeset.t()}` —
  all five handled in §3.3's table.
- `delete/2`: `{:ok, Subscription.t()}`, `{:error, :invalid_id}`, `{:error,
  :not_found}` — all three handled in §3.4's table.

## 7. Moduledoc requirements (AC6)

`lib/letflow/routers/webhooks.ex`'s moduledoc must state, following
`Letflow.Routers.Dlq`'s own moduledoc structure section-for-section:

1. What this module is (REQ-182, this design file's path), what it is mounted
   at, and that it is route/controller layer only atop REQ-181's
   `Letflow.Webhooks` — no schema/context change.
2. PROVENANCE (historical, not current decision authority):
   **Contract source** (§0 above, verbatim disclosure): R-Co's `webhooks.zig`
   not inspected, unreachable from the drafting environment; binding contract
   is `web/src/api/dlq.ts`'s `webhooksApi` and `web/src/types/api.ts`'s
   `WebhookSubscription`.
3. **Authorization** (§4 above): the `:WebhookSubscriptionsManage` policy key,
   the real `required_permission/1`/`role_allows?/2` mapping, the confirmed
   `PLATFORM_ADMIN`/`PROCESS_OPERATOR` role set, and the new
   `endpoint_policy_key("PATCH", ...)` clause this requirement adds.
4. **Cross-tenant-404** (§4.5 above).
5. **Response allowlist** (§5 above), including the explicit statement that
   `secret_hash` and `hmac_secret_once` are never emitted except the one
   documented create-response splice.

## 8. Open questions (explicitly unresolved, not silently decided)

1. **§4.4** — whether `Letflow.Routers.Webhooks` should also be registered in
   `test/letflow/api/authorization_enforcement_test.exs`'s `@routers`/
   `@mount_prefix` tables is left to ELIXIR-DEV/TEST-DESIGNER judgment; no
   acceptance criterion names that file, and `Letflow.Routers.Dlq` itself is
   not registered there today, so leaving `Webhooks` unregistered would be
   consistent (if not ideal) with existing precedent.
2. Whether a `target_url` scheme/format validation (e.g. rejecting a
   non-`http(s)` URL) belongs at this route layer or purely inside
   `Letflow.Webhooks.create/2`'s changeset is left unresolved — no acceptance
   criterion requires it, and `create/2`'s own shipped `insert_changeset/2`
   (read directly from `lib/letflow/webhooks/subscription.ex`) does not
   `validate_format/3` on `target_url` today. This design does not add such
   validation at the route layer either, to avoid duplicating a rule that
   does not exist in the context module it fronts.
