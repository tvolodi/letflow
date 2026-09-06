# REQ-178 — `Letflow.Routers.Dlq` design

Route/controller layer atop REQ-176's `Letflow.Dlq` context module and REQ-069's
`Letflow.Api.Authorization` matrix. This design covers **only** the new router
module (`lib/letflow/routers/dlq.ex`) and its mount point — no change to
`Letflow.Dlq`, `Letflow.Dlq.Entry`, or the `dlq_entries` migration, per this
requirement's own "NOT IN THIS REQUIREMENT" note.

## §0 — Contract source (moduledoc-mandated statement, AC5)

`Letflow.Routers.Dlq`'s moduledoc MUST state, verbatim in substance:

> PROVENANCE (historical, not current decision authority):
> R-Co's `dlq.zig` (337 lines, catalogued in
> `docs/migration/stage-4-api-surface.md`'s fronting-subsystem table) was **not
> inspected** while drafting this route layer — R-Co is at a Windows path
> unreachable from this sandbox, verified absent, not assumed covered. The
> binding contract instead is the already-shipped SPA consumer:
> `web/src/api/dlq.ts`'s `dlqApi` object and `web/src/types/api.ts`'s
> `DlqEntry`/`CursorPage<T>` types. A future reader must not assume R-Co
> route-shape parity was verified here — it was not.

This is a documentation requirement, not a code behavior — call it out as its
own moduledoc section (`## Contract source`), matching `Letflow.Routers.Audit`'s
own moduledoc's use of a named section for a similar disclosure.

## §1 — Module shape and mount

`lib/letflow/routers/dlq.ex`, `defmodule Letflow.Routers.Dlq`, `use
Letflow.Api.AuthorizedRouter` (same idiom as `Letflow.Routers.Audit`,
`Letflow.Routers.Tasks`) — gives `plug(:match)` → `plug(Letflow.Plugs.Authorize)`
→ `plug(:dispatch)` for free, and the `authz_get`/`authz_post` macros.

Mounted in `Letflow.Plugs.ApiPipeline`, alongside the other sub-routers: one
new `forward` declaration pointing the `"/dlq"` path prefix at
`Letflow.Routers.Dlq`, added to the same list that already forwards `"/audit"`
to `Letflow.Routers.Audit` and `"/tasks"` to `Letflow.Routers.Tasks`
(`lib/letflow/plugs/api_pipeline.ex`). This is the one line of that file this
requirement touches; the router module itself is entirely new.

Full paths under `/api/v1`: `GET /api/v1/dlq`, `GET /api/v1/dlq/:id`,
`POST /api/v1/dlq/:id/retry`, `POST /api/v1/dlq/:id/discard` — matching
`web/src/api/dlq.ts`'s `dlqApi` calls exactly.

## §2 — Route declarations and policy key (AC3)

`Letflow.Api.Authorization.endpoint_policy_key/2` already has a clause
matching any method in `GET`/`POST` against a path beginning with `/dlq`,
resolving it to the `:DlqReadRetryDiscard` policy key; that same module's
`required_permission/1` already has a clause mapping `:DlqReadRetryDiscard` to
the `:DlqOperate` permission (both clauses committed under REQ-069, unchanged
by this requirement — see `lib/letflow/api/authorization.ex`). So the one
existing `:endpoint_policy_key` atom, `:DlqReadRetryDiscard`, is the
literal every route below declares via `authz_get`/`authz_post` — no new
`endpoint_policy_key`/`required_permission` clause needed, no new permission
atom invented. `:DlqOperate` already exists in `Letflow.Api.Authorization`'s
`@permissions` list (REQ-069) and is what this requirement makes reachable for
the first time.

Route table:

| Route | Macro | Policy key | Handler |
|---|---|---|---|
| `GET /` | `authz_get "/", :DlqReadRetryDiscard` | `:DlqReadRetryDiscard` | `handle_list/1` |
| `GET /:id` | `authz_get "/:id", :DlqReadRetryDiscard` | `:DlqReadRetryDiscard` | `handle_get/1` |
| `POST /:id/retry` | `authz_post "/:id/retry", :DlqReadRetryDiscard` | `:DlqReadRetryDiscard` | `handle_retry/1` |
| `POST /:id/discard` | `authz_post "/:id/discard", :DlqReadRetryDiscard` | `:DlqReadRetryDiscard` | `handle_discard/1` |
| `match _` | plain `match` (no policy key, falls to `:Unknown`) | n/a | `Response.not_found/1` |

Each handler reads `conn.params["id"]` and `conn.assigns.scoped_opts` (the
`[prefix: schema]` keyword list `Letflow.Plugs.Authorize` assigns on `:Allow`)
— same access pattern as `Letflow.Routers.Tasks`'s `authz_get "/:id", ...`
route. No handler reads `conn.assigns.access_decision`; `:DlqReadRetryDiscard`
never produces `:AllowWithRowFilter` (that only exists for `:TasksList`), so
every allowed caller gets the plain `:all`-scope decision.

### Who actually holds `DlqOperate` (verified against the real matrix, not assumed)

From `Letflow.Api.Authorization.role_allows?/2` (already shipped, REQ-069),
`:DlqOperate` is granted to:

* `:PLATFORM_ADMIN` — via the catch-all `role_allows?(:PLATFORM_ADMIN, _), do:
  true` clause.
* `:PROCESS_OPERATOR` — `:DlqOperate` is explicitly listed in that role's
  permission list.

`:PROCESS_DESIGNER`, `:TASK_WORKER`, `:AGENT_RUNNER` do **not** hold it (none
of their three `role_allows?/2` clauses lists `:DlqOperate`). This matches
`web/src/pages/dlq/DlqPage.tsx`'s client-side `OPERATE_ROLES` constant
(`PROCESS_OPERATOR`, `PLATFORM_ADMIN`) — confirmed identical to the real
server-side matrix, not merely assumed from the UI. No design action follows
from this beyond using the existing `:DlqReadRetryDiscard`/`:DlqOperate` pair
as-is; this section exists so CODE-DESIGN-VALIDATOR and a later reader can see
the verification happened rather than being asserted.

## §3 — `GET /api/v1/dlq` (list) — AC1, AC2

### Query-param → `Letflow.Dlq.list/2` mapping

`handle_list/1` fetches query params (`fetch_query_params/1`, matching
`Letflow.Routers.Audit`/`Letflow.Routers.Tasks`'s own `handle_list/2`
preamble), then builds `Letflow.Dlq.list_params()`:

| HTTP query param | `list_params()` key | Parse/validate step |
|---|---|---|
| `status` | `:status` | passed through as-is (`nil` if absent/empty); `Letflow.Dlq.list/2` itself casts it via `Ecto.Enum.cast_value/3` and returns `{:error, :invalid_filter}` on an unrecognised value — the route does not re-validate it |
| `source_type` | `:entry_type` | **renamed** at the route boundary — `dlqApi.list`'s `source_type` param maps onto `Letflow.Dlq.Entry`'s `entry_type` column/`list_params()`'s `:entry_type` key; this is the one field-name translation this route performs, called out explicitly so it is never mistaken for a bug |
| `search` | `:search` | passed through as-is (`nil` if absent/empty) |
| `instance_id` | `:instance_id` | passed through as-is (`nil` if absent/empty); `Letflow.Dlq.list/2` casts it via `Ecto.UUID.cast/1`, returns `{:error, :invalid_filter}` on a malformed UUID |
| `cursor` | `:cursor` | passed through as the raw opaque string (`nil` if absent/empty) — `Letflow.Dlq.list/2` owns cursor decoding via its own `"D:"`-prefixed `Letflow.Api.Pagination` call, so this route does **not** decode it itself (unlike `Letflow.Routers.Audit`, which decodes inline because `EventStore.read_global/1` wants an already-decoded `global_seq`; `Letflow.Dlq.list/2`'s own contract takes the raw cursor string) |
| `page_size` | `:page_size` | `Letflow.Api.Pagination.parse_page_size_param/1` then `.validate_page_size/1` — same two-step idiom `Letflow.Routers.Audit`/`Letflow.Routers.Tasks` already use; the resulting integer becomes `list_params()`'s required `:page_size` key |

`handle_list/1`'s control flow, in order:

1. Fetch query params, then parse `page_size` via
   `Pagination.parse_page_size_param/1` followed by `.validate_page_size/1`
   (same two calls in sequence `Letflow.Routers.Tasks` already uses). A
   `{:error, :invalid_page_size}` outcome short-circuits straight to
   `Response.bad_request/2` with detail `"invalid page_size"`; a
   `{:error, :page_size_too_large}` outcome short-circuits to
   `Response.bad_request/2` with detail `"page_size out of range"` — this
   second mapping is confirmed against `Letflow.Routers.Tasks`'s own two call
   sites for this same tuple (`lib/letflow/routers/tasks.ex:177-178` and
   `:226-227`, both `Response.bad_request/2`, not a 422), so this router
   follows that existing precedent rather than diverging to 422.
2. On success, assemble the six-key `list_params()` map from the table above
   (§3's mapping) and call `Letflow.Dlq.list/2` with it plus
   `conn.assigns.scoped_opts`.
3. On `{:ok, %{items: items, next_cursor: next_cursor}}`, respond
   `Response.ok/2` with the list body (below).
4. On `{:error, :invalid_filter}` (an unrecognised `status` value or a
   malformed `instance_id` UUID, both raised inside `Letflow.Dlq.list/2`
   itself), respond `Response.unprocessable/2` with detail
   `"invalid filter"`.
5. On any of `Letflow.Dlq.list/2`'s three cursor-decode error atoms
   (`:invalid_cursor`, `:wrong_endpoint`, `:expired`), respond
   `Response.bad_request/2` with detail `"invalid cursor"` — one collapsed
   branch, matching `Letflow.Routers.Audit`'s own collapse of the same three
   outcomes to a single 400.

`non_empty/1` is the same `nil`/`""` → `nil` helper `Letflow.Routers.Audit`
already defines privately; this router defines its own private copy, matching
that module's own precedent of a private per-router copy rather than a shared
helper module (no such shared module exists in this codebase today).

### Response body shape (AC1)

The list body is an exactly-two-key map: `"items"`, the list's rows each run
through the `DlqEntry` serialization function described below, and
`"next_cursor"`, `Letflow.Dlq.list/2`'s own `next_cursor` value passed through
unchanged (a string, or `null` when there is no further page). No other
top-level key — no `"count"`/`"has_more"` key (unlike `Letflow.Routers.Audit`'s
three-key body) — matching `CursorPage<T>`'s TypeScript shape used by
`dlqApi.list`'s return type: `{items: [DlqEntry], next_cursor}`.
(`CursorPage<T>` itself also declares a `has_more: boolean` field in
`web/src/types/api.ts`, but `dlqApi.list`'s actual usage and this
requirement's own acceptance criterion 1 name only `{items, next_cursor}` as
the exact shape to match — see §7 OQ-1 for this not being silently resolved
as "obviously add has_more too.")

### `DlqEntry` JSON serialization (AC1)

`dlq_entry_json/1 :: Letflow.Dlq.Entry.t() -> map()` — a **hand-built
allowlist**, matching `Letflow.Routers.Audit`'s own `audit_item/1` precedent
(never a raw `Jason.Encoder` derivation over the Ecto struct, which would leak
`__meta__`/`tenant_id`). Field-for-field against `web/src/types/api.ts`'s
`DlqEntry`:

| JSON key | Source | Type on the wire |
|---|---|---|
| `"id"` | `entry.id` | string (UUID) |
| `"entry_type"` | `entry.entry_type` | string |
| `"instance_id"` | `entry.instance_id` | string \| null |
| `"reference_id"` | `entry.reference_id` | string \| null |
| `"reason"` | `entry.reason` | string \| null |
| `"full_reason"` | `entry.full_reason` | string \| null |
| `"error_detail"` | `entry.error_detail` | object \| null |
| `"error_chain"` | `entry.error_chain` | array \| null |
| `"source_payload"` | `entry.source_payload` | object \| null |
| `"context_json"` | `entry.context_json` | object \| null |
| `"retry_history"` | `entry.retry_history` | array of `{attempt_no, attempted_at, outcome, error_message}` — already stored in exactly this shape by `Letflow.Dlq.retry/2`, passed through unchanged |
| `"retry_count"` | `entry.retry_count` | integer |
| `"retry_limit"` | `entry.retry_limit` | integer \| null |
| `"next_retry_at"` | `iso8601(entry.next_retry_at)` | string \| null |
| `"status"` | `Atom.to_string(entry.status)` | string, one of `"pending"`/`"retrying"`/`"resolved"`/`"discarded"` |
| `"created_at"` | `iso8601(entry.created_at)` | string |
| `"first_failed_at"` | `iso8601(entry.first_failed_at)` | string \| null |
| `"last_failed_at"` | `iso8601(entry.last_failed_at)` | string \| null |

`iso8601/1` is the same `%DateTime{} -> DateTime.to_iso8601/1`, `nil -> nil`
private helper `Letflow.Routers.Audit` already defines — this router defines
its own private copy (no shared helper module exists for it in this codebase,
same note as `non_empty/1` above).

This allowlist covers every field this requirement's AC1 names as a minimum
(`id`, `entry_type`, `instance_id`, `reason`, `full_reason`, `retry_count`,
`status`, `created_at`) plus every remaining `Letflow.Dlq.Entry` column, so a
future consumer reading a wider slice of `DlqEntry` than AC1's minimum still
gets real data rather than a silently-dropped field. `DlqEntry`'s TS type also
declares `item_type`, `original_payload`, `processor_metadata`, and
`max_retries` as optional fields with no corresponding `Letflow.Dlq.Entry`
column — these are **not emitted** (no schema-backed source), left as an open
question rather than fabricated (§7 OQ-2).

## §4 — `GET /api/v1/dlq/:id` (get) — AC1

`handle_get/1` calls `Letflow.Dlq.get/2` with `conn.params["id"]` and
`conn.assigns.scoped_opts`. On `{:ok, entry}`, responds `Response.ok/2` with
the entry's serialized JSON form (§3). On either `{:error, :not_found}` or
`{:error, :invalid_id}`, responds `Response.not_found/1` — both outcomes map
to the identical call, no distinguishing detail.

`:invalid_id` folds into the same `Response.not_found/1` call as `:not_found`
— a malformed UUID and a genuinely-absent id are indistinguishable to the
caller, both a plain 404 with no body-shape difference. (`Letflow.Routers.
Tasks`'s own `handle_get_by_id`-equivalent instead maps `:invalid_id` to `400`
in one spot — see `tasks.ex:277-278` — but that is for a route with no
cross-tenant-id-guessing concern this sharp; DLQ ids are UUIDs a cross-tenant
prober could enumerate, so this design deliberately keeps `:invalid_id` and
:not_found indistinguishable here, same principle as INV-5. Flagged as a
considered divergence, not an oversight — see §7 OQ-3 if CODE-DESIGN-VALIDATOR
judges `Letflow.Routers.Tasks`'s precedent should be followed literally
instead.)

## §5 — Cross-tenant-404 mechanism (AC3, INV-5)

No new mechanism — this route inherits `Letflow.Dlq.get/2`'s existing,
gate-approved (REQ-176) behavior verbatim: `Repo.get(Entry, id, prefix:
prefix)` scoped to `opts[:prefix]` (derived solely from
`conn.assigns.auth_context.tenant_id` via `Letflow.Plugs.Authorize` →
`Letflow.Api.Context.scoped_repo_opts/1`, never from any request-supplied
value) returns `nil` for a row that exists only in a **different** tenant's
Postgres schema, identical to a row that does not exist anywhere — both
resolve to `{:error, :not_found}` inside `Letflow.Dlq.get/2` (and,
identically, inside `retry/2`/`discard/2`'s own `fetch_and_lock_entry/3`
private helper). This router's only job is to map that one `{:error,
:not_found}` tuple to `Response.not_found/1` — the exact same call for both
cases, so the response bytes are identical by construction (matching
`Letflow.Api.Response.not_found/1`'s own "no detail argument" design, INV-5).

This is why AC3's "different-tenant caller naming a real id belonging to
tenant A receives 404, never 403" holds structurally: the row is never even
found within tenant B's schema-scoped query, so
`Letflow.Api.Authorization.evaluate_access/2` is never in a position to see it
at all — the 403 path only exists for "no role holds `DlqOperate`," a decision
made **before** any `Repo` call, off `conn.assigns.auth_context.roles` alone
(§2's route declaration ordering: `Letflow.Plugs.Authorize` runs before
`:dispatch`, so a `:Deny403` halts the conn before `handle_retry`/
`handle_discard`/`handle_get` ever runs a query).

## §6 — `POST /api/v1/dlq/:id/retry` and `.../discard` — AC3, AC4

Both handlers share one result-mapping shape; only the `Letflow.Dlq` function
called differs. `handle_retry/1` calls `Letflow.Dlq.retry/2`;
`handle_discard/1` calls `Letflow.Dlq.discard/2` — both with
`conn.params["id"]` and `conn.assigns.scoped_opts`, and both mapping their
four possible return shapes identically:

* `{:ok, entry}` — `Response.ok/2` with the entry's serialized JSON form (§3).
* `{:error, :not_found}` — `Response.not_found/1`.
* `{:error, :invalid_id}` — `Response.not_found/1` (same call as above, §4's
  reasoning).
* `{:error, {:invalid_state, _current_status}}` — `Response.conflict/2` with a
  fixed detail string (e.g. "dlq entry is already terminal"), never
  interpolating the entry's actual current status into the response.

* **403** — `Letflow.Plugs.Authorize`'s own `:Deny403` branch, entirely before
  either handler runs; not this router's own code path at all (§2, §5).
* **404** — non-existent id, cross-tenant id (§5), or a malformed UUID, all
  three folding to the same `Response.not_found/1` call, no detail.
* **409** — `Letflow.Dlq.retry/2`/`discard/2`'s `{:error, {:invalid_state,
  status}}` (returned exactly when the entry's current `status` is
  `:resolved` or `:discarded`, per that module's own design §3.4/§3.5) maps to
  `Response.conflict/2`, a distinct status and distinct RFC 9457 problem-type
  from `Response.internal_error/1`'s 500 — never falls through to a generic
  500. The `_current` status value is deliberately not interpolated into the
  detail string (matching `Response.internal_error/1`'s/`Response.not_found/1`
  's "no caller-supplied or internal detail leaks" discipline elsewhere in
  this module — a fixed, generic detail string is used instead).

No third clause is needed for "a genuine `Ecto.Changeset` validation error"
the way `Letflow.Routers.Tasks`'s `handle_complete_result/2` has one —
`Letflow.Dlq.retry/2`/`discard/2`'s own `@spec`s enumerate exactly
`{:ok, Entry.t()}`, `{:error, :invalid_id}`, `{:error, :not_found}`, and
`{:error, {:invalid_state, ...}}` as their only four return shapes (no
`Ecto.Changeset.t()` in that union), so this router's `case` is already
exhaustive over the real contract — adding a changeset-shaped clause here
would be dead code. If a future change to `Letflow.Dlq` widens that union,
`mix compile --warnings-as-errors`' pattern-coverage warning (or, absent that,
a `CaseClauseError` surfaced by TEST-RUNNER) is the backstop, not a
speculative catch-all added now.

## §7 — Open questions (not silently resolved)

1. **Whether `list_body/2` should also emit a `has_more` key.**
   `CursorPage<T>`'s TS type declares `has_more: boolean` alongside `items`/
   `next_cursor`, but `dlqApi.list`'s binding usage and this requirement's own
   AC1 name only `{items, next_cursor}` as the shape to match exactly. This
   design deliberately emits only those two keys. If TEST-DESIGNER/
   CODE-DESIGN-VALIDATOR determine the frontend actually reads `has_more` off
   this specific response (not just the shared TS interface), that is a scope
   change requiring an amendment, not a silent addition.
2. **`item_type`/`original_payload`/`processor_metadata`/`max_retries`.**
   Optional `DlqEntry` fields with no corresponding `Letflow.Dlq.Entry`
   column (§3). Not emitted by this design. If a future requirement adds
   those columns, this route's allowlist needs a follow-up edit — flagged
   here so that gap isn't rediscovered from scratch.
3. **`:invalid_id` on `GET /:id`/retry/discard: 404 vs. 400.** This design
   picks 404 (folded with `:not_found`) for the cross-tenant-probing reason
   given in §4, diverging from `Letflow.Routers.Tasks`'s own `:invalid_id` ->
   400 precedent for a *different* route family. CODE-DESIGN-VALIDATOR should
   confirm this divergence is acceptable given AC3's explicit "never 403, and
   never distinguishable" framing, or direct ELIXIR-DEV to match `tasks.ex`'s
   400 instead if that reading is preferred — not silently decided by
   ELIXIR-DEV at implementation time either way.

## §8 — Cross-module dependencies

* `Letflow.Dlq` (REQ-176) — `list/2`, `get/2`, `retry/2`, `discard/2`. No
  other function from this module is called.
* `Letflow.Api.Authorization` (REQ-069) — indirectly, via
  `Letflow.Plugs.Authorize`'s existing `:DlqReadRetryDiscard` ->
  `:DlqOperate` mapping. No direct call from this router.
* `Letflow.Api.AuthorizedRouter` (REQ-131) — `use`d for the `authz_get`/
  `authz_post` macros and the mandatory `Letflow.Plugs.Authorize` plug.
* `Letflow.Api.Pagination` — `parse_page_size_param/1`, `validate_page_size/1`
  only (cursor decoding stays inside `Letflow.Dlq.list/2`, §3).
* `Letflow.Api.Response` — every response helper (`ok/2`, `not_found/1`,
  `conflict/2`, `bad_request/2`, `unprocessable/2`).
* `Letflow.Plugs.ApiPipeline` — the one new `forward("/dlq", ...)` line (§1).

## §9 — Invariants carried forward

* **INV-1** (tenant scoping) — the only tenant input to every handler is
  `conn.assigns.scoped_opts`, itself derived solely from
  `conn.assigns.auth_context.tenant_id` by `Letflow.Plugs.Authorize`, before
  this router's code ever runs. No query param, path param, or body field
  in this route family can select another tenant's data (§5).
* **INV-2/INV-4** (no detail leakage) — `Response.not_found/1` and
  `Response.internal_error/1`'s no-argument contracts are used as-is; no
  handler in this design constructs a bespoke error body carrying an
  Ecto/Postgrex error, a stacktrace, or the entry's own current status text.
* **INV-5** (cross-tenant 404-never-403) — structural, per §5.
* **No tenant/user input is interpolated into raw SQL** — this router issues
  no `Ecto.Query`/`fragment` calls of its own at all; every DB access is
  inside `Letflow.Dlq`, unchanged by this requirement.
