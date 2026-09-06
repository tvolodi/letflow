# REQ-184 design: webhook delivery-attempts route (GET .../deliveries)

Status: draft for CODE-DESIGN-VALIDATOR review.
Owner requirement: REQ-184 (`docs/requirements.yaml`, queue task 357, GH#702), stage S6.
Depends on: REQ-183 (`Letflow.Webhooks.deliver/3` + `Letflow.Webhooks.Delivery` schema,
shipped), REQ-181 (`Letflow.Webhooks` context, shipped), REQ-069 (authorization matrix,
shipped), REQ-072 (INV-5 cross-tenant-404 mechanism).

This is the route-layer half of the REQ-180 split (REQ-182 was the subscription-CRUD
route half; REQ-183 was the dispatch-core half). Mirrors REQ-176/REQ-178's
core/route split and, more directly, REQ-182's own route-layer idiom in
`lib/letflow/routers/webhooks.ex`.

## 0. Contract source (mandatory disclosure, AC6)

PROVENANCE (historical, not current decision authority):
R-Co's `webhooks.zig` was **not inspected** while drafting this design — R-Co lives
at a Windows path (`c:\Users\tvolo\dev\ai-dala\R-Co\`) unreachable from this drafting
sandbox, verified absent (per REQ-182 and REQ-183's own precedent), not assumed
covered. The binding contract instead is the already-shipped SPA consumer:
`web/src/api/dlq.ts`'s `webhooksApi.getDeliveries/2` (calling
`GET /api/v1/webhooks/subscriptions/:id/deliveries` with an optional `{limit}` query
param and parsing the response through `parseDeliveryAttemptsResponse/1`), and
`web/src/types/api.ts`'s `WebhookDeliveryAttempt`/`WebhookDeliveryAttemptListResponse`
types. Read directly (this design's own verification, not inherited from REQ-182's or
REQ-183's text):

- `web/src/types/api.ts:352-368` — `WebhookDeliveryAttemptStatus = 'SUCCESS' | 'FAILED'`;
  `WebhookDeliveryAttempt` has exactly nine fields: `delivery_id`, `subscription_id`,
  `event_type`, `status`, `http_status_code` (`number | null`), `attempted_at`
  (`string`), `attempt_count` (`number`), `max_attempts` (`number`), `last_error`
  (`string | null | undefined`); `WebhookDeliveryAttemptListResponse = { items:
  WebhookDeliveryAttempt[] }`.
- `web/src/api/dlq.ts:14-64` — `parseDeliveryAttempt/1` throws
  `WebhookDeliveryLogContractMismatch` unless every field is present with the exact
  type above (`http_status_code` must be `null` or a number — never omitted;
  `last_error` may be `null` or absent but never any other shape).
- `web/src/api/dlq.ts:97-100` — `getDeliveries(subscriptionId, params?: {limit?:
  number})` issues `GET /api/v1/webhooks/subscriptions/:id/deliveries` with `params`
  passed through as query params verbatim (so `limit`, when present, arrives as the
  string query param `?limit=<n>`).
- `web/src/components/webhooks/WebhookSubscriptionDetailPanel.tsx:44` — the one real
  caller invokes `webhooksApi.getDeliveries(subscriptionId, { limit: 20 })` — always
  supplies `limit` in practice, but the route must still behave sensibly if a future
  or test caller omits it (§4).

This route module's own moduledoc must restate the R-Co-not-inspected /
SPA-contract-is-binding disclosure verbatim (AC6, §5 below) — this design document
alone does not satisfy that acceptance criterion.

## 1. Backing query — new context function required

`Letflow.Webhooks` (REQ-181/183, `lib/letflow/webhooks.ex`) exposes `create/2`,
`deliver/3`, `list/1`, `update/3`, `delete/2`, and a private `get/2` — **no existing
function lists `webhook_delivery_attempts` rows.** `Letflow.Webhooks.Delivery`
(`lib/letflow/webhooks/delivery.ex`) is a plain `Ecto.Schema` with only
`insert_changeset/2` — no query helpers at all. Confirmed by reading both files in
full: **a new context function must be added.**

It belongs on `Letflow.Webhooks`, not a new module — same module that already owns
`Letflow.Webhooks.Subscription`'s existence/tenant-scope check (`get/2`), and the
one that REQ-183 already put `Delivery`-table writes behind (`deliver/3`). A
`Letflow.Webhooks.Deliveries` submodule would duplicate the not-found/tenant-scope
logic `get/2` already implements privately.

### 1.1 New function: `Letflow.Webhooks.list_delivery_attempts/3`

Signature (type shape only): takes `subscription_id :: String.t()`,
`limit :: pos_integer()`, and the module's existing `opts()` type
(`[prefix: String.t()]`); returns one of `{:ok, [Delivery.t()]}`,
`{:error, :invalid_id}`, or `{:error, :not_found}`.

Behavior:

- `opts` is the same `opts :: [prefix: String.t()]` type every other function in this
  module already takes (REQ-181's INV-1 discipline) — no new opts shape.
- Step 1: validate + scope-check the subscription exists, by calling the module's
  existing private `get(subscription_id, opts)` helper (`lib/letflow/webhooks.ex:612-627`)
  — **reused verbatim, not reimplemented.** This is what makes the cross-tenant-404
  behavior (§3) automatic and consistent with REQ-182's PATCH/DELETE routes: `get/2`
  already returns `{:error, :invalid_id}` for a malformed UUID (no DB round-trip) and
  `{:error, :not_found}` for both "row absent everywhere" and "row exists only in
  another tenant's schema" — both cases are, at the `Repo` level with `prefix: prefix`
  scoping, identical: the row simply is not visible.
- Step 2, only on `{:ok, _subscription}`: query `Letflow.Webhooks.Delivery` filtered by
  `subscription_id == ^subscription_id`, ordered per §4's ordering decision, `limit:
  limit`, executed with `Repo.all(query, prefix: prefix)` — the same tenant-scoping
  idiom `list/1` already uses (no `WHERE tenant_id = ...` filter needed or added; the
  Postgres schema itself is the isolation boundary, Decision B).
- Returns `{:ok, [Delivery.t()]}` (possibly `[]` — a real, existing-in-this-tenant
  subscription with zero delivery attempts is not an error, per AC4's "regardless of
  whether that subscription has delivery attempts" phrasing, which implies the
  *positive* case — zero attempts, real subscription — must also succeed, distinctly
  from the cross-tenant case which must 404 even with delivery attempts present).
- The `subscription` fetched in step 1 is discarded — the route needs it only to
  prove existence/tenant-scope, not to render any subscription fields into this
  response (the response is delivery-attempt rows only, per AC1).

No change to `Letflow.Webhooks.Delivery`, its `insert_changeset/2`, or the
`webhook_delivery_attempts` migration — the existing `idx_webhook_delivery_attempts_subscription`
index (migration `20260830010001_create_webhook_delivery_attempts.exs`) already backs
the `subscription_id == ^subscription_id` filter this query needs; no new index
required.

## 2. Route table

| Method | Path (mounted) | Local `Plug.Router` pattern | Policy key | Calls |
|---|---|---|---|---|
| GET | `/api/v1/webhooks/subscriptions/:id/deliveries` | `"/subscriptions/:id/deliveries"` | `:WebhookSubscriptionsManage` | `Letflow.Webhooks.list_delivery_attempts/3` |

Added to the **existing** `Letflow.Routers.Webhooks` module
(`lib/letflow/routers/webhooks.ex`, REQ-182) as a fifth `authz_get` clause, sitting
alongside the four REQ-182 routes already there — not a new router module, not a new
`forward` mount (the `/webhooks` mount and `/subscriptions` sub-path already exist).
The clause declares the `authz_get` route pattern `"/subscriptions/:id/deliveries"`
with policy key `:WebhookSubscriptionsManage` (same key as the other four routes,
§3), and its body dispatches to one new private handler, `handle_deliveries/2`,
passing the connection and `conn.params["id"]` — the identical shape
`handle_update/2`/`handle_delete/2` already use for their own `:id` path param
(`lib/letflow/routers/webhooks.ex:80-86`).

Route ordering: this pattern is more specific than the existing
`"/subscriptions/:id"` PATCH/DELETE patterns (different HTTP verbs, so `Plug.Router`
dispatch does not actually contend on method+pattern — no ordering hazard to note
beyond placing this clause anywhere among the other four `authz_*` clauses, before
the catch-all `match _`).

## 3. Authorization — already fully wired, no `authorization.ex` change needed

Read `lib/letflow/api/authorization.ex` in full for this route's mapping:

- `endpoint_policy_key("GET", "/webhooks/subscriptions/:id/deliveries")` **already
  exists** (`authorization.ex:293-294`), mapping to `:WebhookSubscriptionsManage` —
  the same policy key REQ-182's four routes use. This clause was evidently added
  ahead of the REQ-180 split and is already shipped; **do not add a duplicate
  clause** — ELIXIR-DEV should confirm it compiles (no duplicate function clause
  error) and move on.
- `required_permission(:WebhookSubscriptionsManage)` **already maps to**
  `:WebhooksManage` (`authorization.ex:425`) — unchanged, no new mapping needed.
- Per the real `role_allows?/2` matrix (`authorization.ex:455-486`): only
  `PLATFORM_ADMIN` (catch-all, not shown above but established elsewhere in the same
  module) and `PROCESS_OPERATOR` (`authorization.ex:466-480`, explicit
  `:WebhooksManage` grant) hold this permission. `PROCESS_DESIGNER`
  (`authorization.ex:455-464`), `TASK_WORKER` (`authorization.ex:482-483`), and
  `AGENT_RUNNER` (`authorization.ex:485`, unconditional `false`) do not — such a
  caller receives `403` via `Letflow.Api.AuthorizedRouter`'s existing
  `authz_get` machinery, before `handle_deliveries/2` ever runs (AC3).

**Net authorization scope for this requirement: zero changes to
`lib/letflow/api/authorization.ex`.** This design's job is to confirm (not assume)
that the wiring is real and correct, which the citations above do.

### 3.1 Cross-tenant-404 (AC4/AC5, INV-5) — exact mechanism to mirror

No new mechanism — inherited verbatim from `Letflow.Routers.Webhooks`'s own
established pattern (`lib/letflow/routers/webhooks.ex:37-50`, REQ-182's PATCH/DELETE
handlers) and, one layer down, from `Letflow.Webhooks.update/3`/`delete/2`'s own
REQ-181-approved not-found handling:

1. The route's only tenant input is `conn.assigns.scoped_opts`, itself derived
   solely from `conn.assigns.auth_context.tenant_id` by `Letflow.Plugs.Authorize`
   before this router's code ever runs (schema-per-tenant, Decision B) — the route
   handler never reads or trusts any tenant identifier from the request path/body.
2. `list_delivery_attempts/3` (§1.1) calls `get/2` first, which does
   `Repo.get(Subscription, id, prefix: prefix)` — a subscription id that exists only
   in a different tenant's Postgres schema is, at the `Repo` level, indistinguishable
   from an id that does not exist anywhere; both resolve to `nil` from `Repo.get/3`
   and thus `{:error, :not_found}` from `get/2`.
3. The route handler maps `{:error, :not_found}` **and** `{:error, :invalid_id}** to
   `Response.not_found/1` — exactly the two-clause fold `handle_update/2` and
   `handle_delete/2` already perform (`lib/letflow/routers/webhooks.ex:140-144,
   165-169`), for the identical stated reason: subscription ids are
   cross-tenant-probeable UUIDs reachable from the route path, so a malformed UUID
   must not leak a `400` (which would distinguish "malformed" from "well-formed but
   absent/foreign") — both collapse to the same `404`.
4. This holds **regardless of delivery-attempt rows existing** (AC4's explicit
   phrasing) because step 2's existence check runs and fails *before* step 1's
   query in §1.1 ever executes — a foreign tenant's subscription id never reaches
   the `webhook_delivery_attempts` query at all, so whether that other tenant has
   delivery-attempt rows is irrelevant; the 404 is decided purely on subscription
   visibility.

No `403` branch exists for this case — a caller who legitimately holds
`WebhooksManage` but names a foreign-tenant subscription id must get `404`, never
`403` (AC4 states this explicitly); the design above produces exactly that because
authorization (§3) and tenant-scoped existence (this section) are two independent
checks — passing the first never implies anything about the second.

## 4. `limit` param semantics (AC2)

- Query param name: `limit`, read from `conn.params["limit"]` (Plug's query-string
  parsing already makes `?limit=5` arrive as a string `"5"` in `conn.params`, same as
  every other integer-ish query param in this codebase — no new parsing idiom).
- **Required integer parsing + default:** if `conn.params["limit"]` is absent, `nil`,
  or fails `Integer.parse/1` to a positive integer, the route defaults to **`20`**
  (Letflow's own choice, not ported from R-Co per §0 — chosen to match the one real
  SPA caller's own literal `{ limit: 20 }`, so an omitted param behaves identically to
  the SPA's actual current usage). A non-positive or non-numeric supplied value (e.g.
  `?limit=0`, `?limit=-1`, `?limit=abc`) also falls back to this same default of `20`
  rather than erroring — no acceptance criterion requires a `400` for a malformed
  `limit`, and `webhooksApi.getDeliveries`'s only real caller never sends one.
- **Enforcement:** `list_delivery_attempts/3`'s query (§1.1) applies
  `Ecto.Query.limit/2` with the resolved integer directly in the Ecto query (a
  database-level `LIMIT`, not an in-Elixir `Enum.take/2` after fetching everything) —
  this is what makes "more attempts than limit returns exactly limit items" (AC2)
  hold under an arbitrarily large real row count, not just in a small test fixture.
- **Ordering decision (explicit, since no acceptance criterion states one, but a
  limit test needs one to assert deterministically which rows survive the cutoff):**
  order descending by `attempted_at` first, then descending by `attempt_count` as the
  tie-breaker — most-recent-attempt-first. Rationale: `attempted_at` is a `:utc_datetime` column (second precision, not
  microsecond), so two attempts within the same wall-clock second are possible
  (distinct `deliver/3` calls created a few hundred ms apart in a fast test) and
  `attempted_at` alone would not be a total order; `attempt_count` breaks that tie
  deterministically because it is a small positive integer, always populated per
  `Delivery.insert_changeset/2`'s `validate_required/2` list. `id` (a `binary_id`,
  UUIDv4) is **not** used as a tie-breaker — UUIDv4 has no chronological ordering
  property, so sorting by it would be arbitrary, not deterministic-by-recency.
  ELIXIR-DEV must implement exactly this two-key ordering, not `attempted_at` alone.

## 5. Response shape (AC1) and moduledoc requirement (AC6)

### 5.1 Handler + response shape

Two new private functions on `Letflow.Routers.Webhooks`:

- `handle_deliveries(conn, id)` — resolves `limit` from `conn.params["limit"]` via a
  private `resolve_limit/1` helper (§4's default/parse rule), then calls
  `Webhooks.list_delivery_attempts(id, limit, conn.assigns.scoped_opts)` and branches
  on its three possible return shapes (§1.1): `{:ok, deliveries}` renders
  `Response.ok(conn, %{"items" => <deliveries mapped through delivery_json/1>})`;
  `{:error, :not_found}` and `{:error, :invalid_id}` both render
  `Response.not_found(conn)` — the same two-clause fold `handle_update/2` and
  `handle_delete/2` already perform (§3.1 step 3).
- `resolve_limit(raw_param)` — implements §4's parse/default/fallback rule; returns a
  plain positive integer, never a query-composition value itself (the composition
  stays inside `Letflow.Webhooks`, §7).

### 5.2 `delivery_json/1` — hand-built allowlist (INV-2), exactly 9 fields

Same "hand-built allowlist over the Ecto struct, never a raw `Jason.Encoder`
derivation" idiom `subscription_json/1` already establishes
(`lib/letflow/routers/webhooks.ex:204-218`) — necessary here too, since
`Letflow.Webhooks.Delivery` carries `tenant_id` (never to be emitted, INV-2) and
`__meta__`/`id` (the row's own primary key — not one of the nine contracted fields;
§0 confirms `WebhookDeliveryAttempt` has no `id` field, only `delivery_id`, a
different value the schema also stores as a distinct column). Field-by-field mapping,
matching §0's read of `web/src/types/api.ts:354-364` exactly:

| JSON key | Source (`Delivery.t()` field) | Type/encoding |
|---|---|---|
| `delivery_id` | `delivery_id` | `Ecto.UUID.t()` string, as-is |
| `subscription_id` | `subscription_id` | `Ecto.UUID.t()` string, as-is |
| `event_type` | `event_type` | string, as-is |
| `status` | `status` | `Atom.to_string/1` (`:SUCCESS`/`:FAILED` → `"SUCCESS"`/`"FAILED"`) — same idiom `subscription_json/1` uses for its own `status` field |
| `http_status_code` | `http_status_code` | integer or `nil`, as-is (never coerced to `0`) |
| `attempted_at` | `attempted_at` | `DateTime.to_iso8601/1` — same `iso8601/1` private helper `subscription_json/1` already defines (`lib/letflow/routers/webhooks.ex:220-221`), reused, not reimplemented, since `attempted_at` is never `nil` for a persisted row (`validate_required/2` in `Delivery.insert_changeset/2`) |
| `attempt_count` | `attempt_count` | integer, as-is |
| `max_attempts` | `max_attempts` | integer, as-is |
| `last_error` | `last_error` | string or `nil`, as-is |

No pagination fields (no `next_cursor`, no `total`) — the body is an
exactly-one-key map `%{"items" => [...]}`, matching `webhooksApi.getDeliveries`'s own
`WebhookDeliveryAttemptListResponse` shape (§0) and the same non-paginated
`%{"items" => [...]}` convention `handle_list/1` already uses for subscriptions.

### 5.3 Moduledoc requirement (AC6) — exact language ELIXIR-DEV must add

`Letflow.Routers.Webhooks`'s moduledoc already contains the required disclosure from
REQ-182 (`lib/letflow/routers/webhooks.ex:13-19`, quoted in §0 above). Since this
route is added to that **same** module (§2), AC6 is satisfied by the *existing*
moduledoc text as long as it is not narrowed or removed — ELIXIR-DEV must:

1. Leave the existing "## Contract source" section (lines 13-19) intact verbatim.
2. Extend its route-list sentence (currently: "so the full paths under `/api/v1` are
   `GET .../subscriptions`, `POST .../subscriptions`, `PATCH .../subscriptions/:id`,
   and `DELETE .../subscriptions/:id`") to also name
   `GET /api/v1/webhooks/subscriptions/:id/deliveries`, so the moduledoc's route
   inventory stays accurate for the fifth route.
3. Add one new subsection (e.g. "## Delivery attempts (REQ-184)") documenting: this
   route's `web/src/api/dlq.ts`/`web/src/types/api.ts` binding-contract fields (§0,
   restated briefly, not just cross-referenced, so the moduledoc is self-sufficient
   per this project's existing per-module documentation depth), that
   `Letflow.Webhooks.list_delivery_attempts/3` is new (§1.1), and the `limit`
   default/ordering decision (§4) — since neither is stated anywhere in
   `docs/requirements.yaml`'s REQ-184 text and a future reader must not have to
   re-derive them from the route body.

If CODE-DESIGN-VALIDATOR or REVIEWER judges that a *new* explicit "R-Co not
inspected" sentence is required per-route rather than per-module, the existing
moduledoc-level disclosure already covers every route in this module including the
one added here — no per-route restatement is a stricter reading than REQ-182's own
already-accepted AC6 discharge for four routes sharing one moduledoc.

## 6. Scope confirmation — route/controller layer only

No change to:
- `Letflow.Webhooks.deliver/3` or any of its private helpers (`attempt_loop/7`,
  `handle_attempt_outcome/10`, `record_delivery_failure/2`, `dispatch_http/3`, etc.) —
  REQ-183's dispatch core is untouched.
- `Letflow.Webhooks.Delivery`'s schema, `insert_changeset/2`, or the
  `webhook_delivery_attempts` migration — no new column, no new index (the existing
  `idx_webhook_delivery_attempts_subscription` index already backs §1.1's query).
- `Letflow.Webhooks.Subscription` or its changesets.
- `lib/letflow/api/authorization.ex` (§3 — already fully wired).

In scope, restated: one new `Letflow.Webhooks.list_delivery_attempts/3` function
(§1.1, a genuinely new *read-only* query — permitted per REQ-184's own "unless a
genuinely new read-only query function is needed" carve-out), one new `authz_get`
route clause + two private handler functions (`handle_deliveries/2`,
`delivery_json/1`) in the existing `Letflow.Routers.Webhooks` module, and moduledoc
prose extension (§5.3). No new file.

## 7. INV-RT-1 — no direct `Repo`/`Ecto.Query` calls from the router

`lib/letflow/routers/webhooks.ex` today has no `import Ecto.Query` and no `alias
Letflow.Repo` — every existing handler calls into `Letflow.Webhooks` exclusively.
This design's new `handle_deliveries/2` (§5.1) preserves that boundary: it calls
`Webhooks.list_delivery_attempts/3` and nothing else DB-related. All `Ecto.Query`
construction (the `where subscription_id`, `order_by`, `limit` composition, §1.1)
lives inside `lib/letflow/webhooks.ex`, which already `import Ecto.Query` and
`alias Letflow.Repo` (`lib/letflow/webhooks.ex:74-81`) — no new alias/import needed
there either. No INV-RT-1 (context-module boundary) violation risk.

## 8. Acceptance-criteria coverage map

| AC | Covered by |
|---|---|
| AC1 (response shape, 9 fields) | §5.2 field table |
| AC2 (limit honored, exact-limit test) | §4 (DB-level `Ecto.Query.limit/2`, explicit ordering) |
| AC3 (403 without `WebhooksManage`) | §3 (existing `endpoint_policy_key`/`required_permission`/`role_allows?` wiring) |
| AC4 (cross-tenant real id → 404 regardless of attempts) | §3.1 |
| AC5 (non-existent id → 404) | §3.1 step 2/3 (`{:error, :not_found}` from `get/2`, same fold as cross-tenant) |
| AC6 (moduledoc R-Co-not-inspected/SPA-contract disclosure) | §5.3 |

## 9. Open questions for REVIEWER

- **OQ-1:** §4's default `limit` of `20` and the "malformed limit silently falls back
  to default rather than `400`" choice are both this design's own decisions, not
  stated by any acceptance criterion or by R-Co (unreachable, §0). If REVIEWER
  prefers a `400` on a non-numeric `limit`, that changes §5.1's `resolve_limit/1`
  contract — flagged rather than silently guessed.
- **OQ-2:** §4's `[desc: attempted_at, desc: attempt_count]` ordering is likewise this
  design's own choice for determinism, not stated by any acceptance criterion. Any
  test fixture asserting "which rows survive a limit cutoff" must construct rows with
  distinct `attempted_at`/`attempt_count` values consistent with this ordering, not
  rely on insertion order.
