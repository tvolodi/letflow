PROVENANCE (historical, not current decision authority):
# Design: REQ-081 — Definition routes 1/2, read path (`definitions.zig`'s `handleGetById`/`handleList`/`handleGetActiveByName`/`handleSearch`/`handleExport`)

**Requirement:** REQ-081 (`docs/requirements.yaml:4573-4609`, stage S4, `depends_on: [REQ-072]`)
**Owner (implementer):** ELIXIR-DEV
**This document produces:** public function signatures (`@spec`-style), Ecto query
shapes (fragment/keyset structure, not literal SQL text), route table, HTTP
error-mapping table, cursor payload formats, invariants, open questions. **No
implementation code** — no function bodies, no `.ex` files.

---

## 0. Sources read for this design

- `docs/requirements.yaml:4573-4609` — REQ-081's full entry (title, description, all 6
  acceptance criteria, `depends_on: [REQ-072]`).
- `docs/guides/backend_developer_guide.md` — naming, error-shape, SQL-parameterization
  (`Ecto.Query`/`fragment/1` bound `^value`), multi-tenancy (`:prefix`) conventions.
- `docs/agents/instructions/security-invariants.md` — INV-1 (tenant isolation via
  `:prefix`, live), INV-2 (server-side field allowlisting, now live as of this
  requirement — S4 has started), INV-5 (not-found/forbidden indistinguishability, now
  live as of this requirement), INV-7 (no raw-SQL interpolation), INV-8 (typed results).
- `docs/anti-patterns.md` — no directly-applicable entry found.
- `lib/letflow/instances.ex` (354 lines, read in full) — REQ-080's structural template:
  a context module with `get_by_id/2`/`list/2`/`history/2`/`timeline/2`, each building
  its own `Ecto.Query`, `Letflow.Api.Pagination`'s codec functions for cursor
  encode/decode, a private `filter_by_*`/`split_*_page` helper pair per list-shaped
  function.
- `lib/letflow/api/pagination.ex` (332 lines, read in full) — pure opaque-cursor codec;
  no DB knowledge; `Cursor.t()` has exactly one field (`inner`), structurally enforcing
  INV-1/INV-5 (a decoded cursor has no slot that could widen tenant scope).
- `lib/letflow/routers/instances.ex` (read in full) — REQ-080's router shape:
  `with_authorized_scope/4` wrapping every handler, `Letflow.Api.Context.scoped_repo_opts/1`
  for the mounted tenant prefix, `Letflow.Api.Authorization.endpoint_policy_key/2` +
  `evaluate_access/2` for the permission gate, explicit field-allowlist response maps
  (never `Jason.Encoder` over the raw Ecto struct).
- `lib/letflow/routers/definitions.ex` (read in full, current state) — REQ-078's
  `/definitions/:id/validate` route; explicitly documents that the rest of this
  module's surface (including every route this design adds) is "reserved for REQ-081
  and REQ-082, which co-own this file."
- `lib/letflow/definitions.ex` (2337 lines) — read the full public API plus every
  private helper `search/2` uses (`where_search_match/2`, `select_with_rank/3`,
  `order_by_rank/3`, `@rank_case_sql`, `check_query_not_empty/1`,
  `check_query_not_too_long/1`) and every helper `list/2` uses (`where_name/2`,
  `where_status/2`, `where_stage/2`, `where_after_created/2`, `effective_limit/1`).
  Confirmed `get_by_id/2` (line 427) and `get_active_by_name/2` (line ~440) already
  exist (REQ-030) and already collapse cross-tenant/nonexistent into one code path —
  see §5 "Reused as-is."
- `lib/letflow/definitions/export_import.ex` (read in full) — `Letflow.Definitions.ExportImport.export/2`
  (REQ-034) already exists: fetches via `Definitions.get_by_id/2` and returns an
  `ExportDocument.t()`. This requirement's `handleExport` is a thin router wrapper over
  it — see §5.
- `lib/letflow/identity.ex` — read `list_users/2`'s cursor helpers
  (`build_next_cursor/1`, `decode_users_cursor/1`) in full. This is the **more mature**
  two-field cursor idiom (mint-time-based expiry in the first payload slot, the real
  sort key in the other two, via `Pagination.build_raw_cursor_timestamp_key/4`) —
  documented in `identity.ex` as a deliberate field-slot repurposing over
  `build_raw_cursor_timestamp_key/4`'s literal parameter names, because a domain
  timestamp (e.g. `inserted_at`) is unsafe to put in the expiry-checked slot: a row
  inserted more than 24h ago would make every cursor built from it appear
  already-expired at mint time. `list_paginated/2` and `search_paginated/3` below
  reuse this idiom, not `Letflow.Instances.list/2`'s older one (which puts the domain
  timestamp `started_at_us` directly in the expiry-checked slot — a divergence not
  revisited here since fixing it is out of REQ-081's scope).
PROVENANCE (historical, not current decision authority):
- R-Co `src/api/routes/definitions.zig` (read `handleGetById`, `handleList`,
  `handleGetActiveByName`, `handleSearch`, `handleExport`, and their three serializers
  `serializeDefinition`/`serializeListResponse`/`serializeSearchResults`/
  `serializeExportDocument`, in full) and `src/main.zig` (route-registration section,
  confirming exact paths: `GET /api/v1/definitions/:id`, `GET /api/v1/definitions`,
  `GET /api/v1/definitions/active/:name`, `GET /api/v1/definitions/search`, and
  `GET /api/v1/definitions/:id/export`, the last found in `handleExport`'s own doc
  comment since it is registered alongside the write routes REQ-082 will document).

---

## 1. Scope boundary

Five read handlers, all `GET`, all delegate into `Letflow.Definitions`/
`Letflow.Definitions.ExportImport` (both already shipped) or two **new** functions
added to `Letflow.Definitions` in this requirement (`list_paginated/2`,
`search_paginated/3`). No migration, no new Ecto schema, no new table. REQ-082 (write
path) is out of scope — this file does not touch `handleCreate`/`Put`/`Patch`/`Delete`/
`Activate`/`Deprecate`/`Archive`/`Import`, and does not modify
`Letflow.Routers.Definitions`'s existing `POST /:id/validate` route or its `match _`
catch-all placement rules (only inserts new routes above it, per the ordering
constraint in §4).

| R-Co handler | Method/path | Delegates to |
|---|---|---|
| `handleGetById` | `GET /definitions/:id` | `Letflow.Definitions.get_by_id/2` (existing) |
| `handleList` | `GET /definitions` | **new** `Letflow.Definitions.list_paginated/2` |
| `handleGetActiveByName` | `GET /definitions/active/:name` | `Letflow.Definitions.get_active_by_name/2` (existing) |
| `handleSearch` | `GET /definitions/search` | **new** `Letflow.Definitions.search_paginated/3` |
| `handleExport` | `GET /definitions/:id/export` | `Letflow.Definitions.ExportImport.export/2` (existing) |

## 2. Where the two new functions live, and why (the search-cursor design problem)

**Decision: extend `Letflow.Definitions` itself with `list_paginated/2` and
`search_paginated/3` — do not create a separate `Letflow.Definitions.Routes` context
module.**

**Reasoning.** `search/2`'s ranking is a *computed* value: `@rank_case_sql`
(`definitions.ex` line ~1338), a module attribute holding a fixed SQL `CASE` string
literal, spliced into `fragment/1` calls in `where_search_match/2`'s sibling
`select_with_rank/3` and `order_by_rank/3`. `definitions.ex`'s own comment on
`@rank_case_sql` states *why* this must be a module attribute, not a function call:

> "A module attribute is inlined as a literal at compile time before Ecto's
> `fragment/1` macro-expansion SQL-injection guard runs, so `fragment(@rank_case_sql,
> ...)` compiles cleanly here, unlike `fragment(^helper_fun(), ...)` which Ecto's guard
> rejects even when the helper always returns the same fixed string."

This is a **hard compile-time constraint**, not a style preference: `fragment/1`'s
first argument must be a literal string known at macro-expansion time. A module
attribute is inlined per-*compiling-module* — `Letflow.Definitions.Routes.search_paginated/3`
could not reference `Letflow.Definitions`'s `@rank_case_sql` and pass it to its own
`fragment/1` call; Ecto's guard would reject it exactly as the comment describes for
`fragment(^helper_fun(), ...)`. The two options REQ-081's brief named are therefore not
actually equally available:

- **(a) "expose the private rank-building helpers as `@doc false` public functions"**
  does not solve the problem — `select_with_rank/3`/`order_by_rank/3` becoming public
  doesn't help a *different module's* `fragment/1` call, because the literal string
  still has to be re-declared as **that module's own** attribute for the macro to
  accept it. Exposing the helpers as public functions is fine for the SELECT/ORDER BY
  pieces (a public function *can* be called normally, just not passed as the dynamic
  first arg of `fragment/1`), but the underlying SQL-literal-sharing problem remains.
- **(b) "duplicate verbatim with a comment citing the single source of truth"** would
  work, but leaves two independently-editable copies of the ranking SQL with only a
  comment (not the compiler) preventing drift — exactly the risk `@rank_case_sql`'s own
  comment exists to close for `select_with_rank/3` vs. `order_by_rank/3` inside the
  *same* module.

**Chosen resolution: put `search_paginated/3` inside `Letflow.Definitions` itself.**
Then it references `@rank_case_sql` the same way `select_with_rank/3`/`order_by_rank/3`
already do — one compile-time literal, one module, zero duplication, enforced by the
compiler rather than a comment. `list_paginated/2` has no such constraint (it orders by
a real column, `created_at`), but is placed alongside it for the same reason
`list/2`/`search/2` already live together: one context module per resource, matching
REQ-030/042's own precedent, and because `list_paginated/2` reuses `list/2`'s existing
private `where_name/2`/`where_status/2`/`where_stage/2` filter helpers verbatim (same
module, no re-export needed).

Both new functions are `@doc false`-free, ordinary public functions — this is not a
route-layer module, so no `Plug.Conn` dependency, matching every existing function in
this module.

## 3. New `Letflow.Definitions` functions

### 3.1 `list_paginated/2`

```
@type list_paginated_filters :: %{
        optional(:name) => String.t() | nil,
        optional(:status) => status() | nil,
        optional(:stage) => String.t() | nil,
        optional(:cursor) => String.t() | nil,
        optional(:page_size) => pos_integer()
      }

@type paginated_result :: %{items: [ProcessDefinition.t()], next_cursor: String.t() | nil}

@spec list_paginated(filters :: list_paginated_filters(), opts :: opts()) ::
        {:ok, paginated_result()}
        | {:error, :invalid_cursor | :wrong_endpoint | :expired}
        | common_error()
```

- Reuses `where_name/2`, `where_status/2`, `where_stage/2` (existing private helpers,
  unchanged) — **not** `where_after_created/2`, which is superseded by cursor
  pagination here (see §7 OQ-1 — `list/2`'s own `after_created` filter stays as-is for
  its existing non-HTTP callers, this function does not touch or deprecate it).
- Order: `order_by([d], desc: d.created_at, desc: d.id)` — the same
  `(timestamp, id)` compound tiebreak `Letflow.Instances.list/2` and
  `Letflow.Identity.list_users/2` both already use; `created_at` is `utc_datetime_usec`
  so a genuine tie is possible under concurrent inserts, and the `id` tiebreak makes
  the keyset total.
- `page_size` validated by the **router**, not this function (matching
  `Letflow.Instances.list/2`'s split of responsibility: `Letflow.Api.Pagination.parse_page_size_param/1`
  + `validate_page_size/1` run in the router before calling this function; this
  function receives an already-validated `page_size` and does
  `limit(^(page_size + 1))` internally exactly like `Instances.list/2`, fetching one
  extra row to detect a next page).
- Cursor format and decode/split helpers: §3.3.

### 3.2 `search_paginated/3`

```
@type search_paginated_opts :: [prefix: String.t()]

@spec search_paginated(query :: String.t(), params :: %{
        optional(:cursor) => String.t() | nil,
        optional(:page_size) => pos_integer()
      }, opts :: search_paginated_opts()) ::
        {:ok, paginated_result()}
        | search_error()
        | {:error, :invalid_cursor | :wrong_endpoint | :expired}
```

where `paginated_result()`'s `items` are `search_result()` maps (`%{definition:
ProcessDefinition.t(), rank: float()}`), the same shape `search/2` already returns —
`search_paginated/3` is `search/2`'s cursor sibling, not a different result shape.

- `query` validated identically to `search/2`: `check_query_not_empty/1` then
  `check_query_not_too_long/1` (both existing private functions, reused verbatim, run
  **before** any cursor decode or DB query — same order `search/2` already uses). This
  is the single validation path both `search/2` and `search_paginated/3` share; the
  route only maps the resulting `{:error, :query_empty}`/`{:error, :query_too_long}` to
  HTTP (§4.4), it never re-derives the check.
- Query composition: `where_search_match/2` (existing, unchanged) → `select_with_rank/3`
  (existing, unchanged) → **new** `filter_by_search_cursor/4` (keyset WHERE, below) →
  **new** `order_by_rank_paginated/3` (same `order_by_rank/3` shape plus the `d.id`
  tiebreak) → `limit(^(page_size + 1))`.
- **Keyset WHERE clause.** Reuses `@rank_case_sql` a third time (alongside
  `select_with_rank/3`'s and `order_by_rank/3`'s existing uses) via a private
  `filter_by_search_cursor/4`, expressed as (Ecto `dynamic/2`, not literal SQL text):

  ```
  rank DESC, created_at DESC, id DESC  ⇒  next page is every row where:
    rank_expr < cursor_rank
    OR (rank_expr == cursor_rank AND created_at < cursor_created_at)
    OR (rank_expr == cursor_rank AND created_at == cursor_created_at AND id < cursor_id)
  ```

  where `rank_expr` is `fragment(@rank_case_sql, d.name, ^search_query, d.name,
  ^pattern)` (the exact same fragment call `select_with_rank/3`/`order_by_rank/3` make,
  same two bound values `search_query`/`pattern` — never re-derived independently, so
  the WHERE, SELECT and ORDER BY can never disagree about a row's rank, extending the
  existing `where_search_match/2` comment's "can never disagree about what counts as a
  match" guarantee to "can never disagree about a row's rank" too). `cursor_rank` is
  bound as a `float()` (`1.0`/`2.0`/`3.0`, decoded from the cursor payload's integer
  encoding — see §3.3) compared against the fragment's `::float8`-cast result, so the
  comparison is float-to-float, never `Decimal.t()`-to-float (same cast-type concern
  `@rank_case_sql`'s own comment raises for `select_with_rank/3`).
- `nil` cursor (first page): `filter_by_search_cursor/4` is a no-op passthrough
  (`query` returned unchanged), same idiom every existing `filter_by_*_cursor/2`
  function in `Letflow.Instances`/`Letflow.Identity` already uses for `nil`.
- Filters: `query` only (no `name`/`status`/`stage` filters — R-Co's own
  `SearchQueryParams` carries none either, matching parity).

### 3.3 Cursor payload format (both functions)

Both follow the `Letflow.Identity.list_users/2` idiom (§0): the **first** payload slot
after the prefix is always the mint-time timestamp (`System.system_time(:microsecond)`,
what `decode_cursor/4`'s expiry check reads), never a domain value — domain sort-key
fields go in the remaining slots, read only by this module's own decode helper, never
by `Letflow.Api.Pagination` itself (which stays ignorant of their meaning, per its own
moduledoc's "cursor.inner is a fully opaque byte string" invariant).

**`list_paginated/2`** — prefix `"DL:"`, built via
`Pagination.build_raw_cursor_timestamp_key("DL:", mint_time_us, id, created_at_us)`,
payload shape `"DL:<mint_time_us>:<id>:<created_at_us>"`. Decode: split on `:` into 3
parts (`parts: 3` after stripping the prefix, discard the mint-time part), parse
`id`/`created_at_us`.

**`search_paginated/3`** — prefix `"DS:"`. `build_raw_cursor_timestamp_key/4`'s `key`
slot must carry **two** domain values (`rank_int`, `id`) since only two non-expiry
slots exist for three domain values (`rank`, `created_at`, `id`). Encode:
`rank_int` is `trunc(rank)` — always exactly `1`, `2`, or `3` per `@rank_case_sql`'s
three `WHEN`/`ELSE` branches, never any other value, so no precision is lost by
storing it as an integer rather than the `float()` the in-process `search_result()`
type carries. Built as:

```
Pagination.build_raw_cursor_timestamp_key(
  "DS:", mint_time_us, "#{rank_int}|#{id}", created_at_us
)
```

payload shape `"DS:<mint_time_us>:<rank_int>|<id>:<created_at_us>"`. Decode: split on
`:` into 3 parts after stripping the prefix (discard the mint-time part), split the
middle part on `|` into `rank_int_str`/`id_str`, parse all three; `cursor_rank` passed
to `filter_by_search_cursor/4` is `rank_int * 1.0`.

Both cursors are minted from the **last row of the current page** (`List.last(page)`),
identical to every existing `split_*_page/2` helper's shape (`Letflow.Instances`,
`Letflow.Identity`) — a `filter_by_*_cursor` + `split_*_page` private helper pair per
function, per this requirement's own instructed structural template.

## 4. Router — `lib/letflow/routers/definitions.ex`

PROVENANCE (historical, not current decision authority):
Adds five `GET` routes to the existing module (which currently owns only
`POST /:id/validate`). **Route-ordering constraint**, same hazard class as
`Letflow.Routers.Instances`'s `/:id/history` note and R-Co's own `handleSearch` doc
comment ("register this route BEFORE `/api/v1/definitions/:id` … so `search` is not
consumed as a `:id` path parameter"): `/active/:name`, `/search`, and `/:id/export`
must all be declared **above** `/:id` in `Plug.Router`'s first-match-wins order, and
`/:id/export` specifically must precede a bare `/:id` (R-Co's own registration order
places `/active/:name`, `/search`, `/import` before `/:id` at `main.zig`'s dispatch
site — mirrored here).

Declaration order (top to bottom, each dispatching to its own private handler):
`GET /active/:name` → `handle_get_active_by_name/2`; `GET /search` → `handle_search/1`;
`GET /:id/export` → `handle_export/2`; `GET /:id` → `handle_get_by_id/2`; `GET /` →
`handle_list/1`. The three specific-suffix/prefix routes must all precede the bare
`GET /:id`, and `GET /:id` must precede `GET /` only in the trivial sense that
`Plug.Router` matches the request path structurally (a bare `/` never matches
`/:id`'s pattern regardless of order) — listed in this order purely for readability,
matching `Letflow.Routers.Instances`'s own route-block ordering convention.

placed above the existing `post "/:id/validate"` route (order between `GET` and `POST`
routes on different verbs doesn't interact with `Plug.Router` matching, but keeping the
five new routes grouped together above the pre-existing route keeps the file's route
block readable, matching `Letflow.Routers.Instances`'s own grouping-by-requirement
comments).

### 4.1 Auth/tenant-scope wiring — reuse `Letflow.Routers.Instances`'s exact idiom

Every one of the five handlers is wrapped in a `with_authorized_scope/4` helper,
**copied structurally from `Letflow.Routers.Instances`** (same private-function shape,
not a shared/imported one — `Letflow.Routers.Instances`'s own comment marks it "a
temporary direct call, pending REQ-131," meaning every router currently duplicates it
rather than sharing a common module; REQ-131 is the eventual consolidation point, not
this requirement's to build):

**Shape** (private, arity 4 — `conn`, HTTP `method` string, `path_template` string, a
1-arity-in-`conn`/3-arity continuation `fun`): resolves `opts` via `scoped_repo_opts/1`;
on failure, 500 (`Response.internal_error/1`) — this is an ordering-guarantee failure,
not a caller error, since the scope-resolution plug is expected to have already run.
On success, resolves `actor_id` from `conn.assigns.auth_context.user_id`; on failure,
500. Builds an `Authorization.AccessContext{user_id: actor_id, roles:
Authorization.roles_from_strings(conn.assigns.auth_context.roles)}` and calls
`Authorization.evaluate_access(ctx, Authorization.endpoint_policy_key(method,
path_template))`. `decision.kind == :Deny403` → `Response.forbidden(conn,
"insufficient permissions")` (this is where AC6's 403 comes from, for all five
endpoints, uniformly). Any other `decision.kind` (`:Allow`/`:AllowWithRowFilter`) →
invokes `fun.(conn, opts, actor_id)`, the handler's own body. No `Repo` call of any
kind may precede this whole chain resolving — same ordering guarantee
`Letflow.Routers.Instances`/`Letflow.Routers.Definitions`'s existing moduledoc already
states for their own handlers.

`scoped_repo_opts(conn)` calls `Letflow.Api.Context.scoped_repo_opts/1` — the exact
function `Letflow.Routers.Instances` and `Letflow.Routers.Definitions`'s own existing
`/:id/validate` handler already call — **never a route-local tenant derivation** (per
REQ-081's description: "a handler must never re-derive the tenant itself"). No `Repo`
call in any of the five new handlers happens before this resolves (ordering guarantee,
matching the existing moduledoc's "Ordering guarantee" section).

### 4.2 Permission — `DefinitionsRead` on all five, reusing the existing mapping

`Letflow.Api.Authorization.endpoint_policy_key/2` (`lib/letflow/api/authorization.ex`,
line 193) **already has** a clause resolving `"GET"` on path in
`["/definitions", "/definitions/:id"]` to `:DefinitionsRead` — covering
`handle_get_by_id`/`handle_list`. This requirement adds three more `"GET"` clauses to
the same function, one per remaining path (`"/definitions/active/:name"`,
`"/definitions/search"`, `"/definitions/:id/export"`), each also resolving to
`:DefinitionsRead` (already-defined: `required_permission(:DefinitionsRead)`, line
~343) — no new permission atom, no new clause body shape, just three more literal-path
match arms returning the same atom the existing clause already returns, placed
immediately after the existing `/definitions`/`/definitions/:id` clause. No new
permission atom is introduced — `:DefinitionsRead` already exists in
`@type permission`/`@type endpoint_policy_key` and `required_permission/1`; this
requirement only widens which path templates map to it. `path_template` passed by each
handler to `with_authorized_scope/4` is the **literal string matching one of these
clauses exactly** (`"/definitions/:id/export"`, not `"/definitions/#{id}/export"`) —
same convention `Letflow.Routers.Instances` already follows for its own
`"/instances/:id/history"`, etc.

### 4.3 Handler → context-function → response mapping

| Handler | Calls | 200 body | Error mapping |
|---|---|---|---|
| `handle_get_by_id` | `Definitions.get_by_id(id, opts)` | `definition_map/1` (single) | `{:error, :not_found}` → 404 |
| `handle_list` | `Definitions.list_paginated(filters, opts)` | `%{"items" => [...], "next_cursor" => ...}` | see §4.4 |
| `handle_get_active_by_name` | `Definitions.get_active_by_name(name, opts)` | `definition_map/1` (single) | `{:error, :not_found}` → 404 |
| `handle_search` | `Definitions.search_paginated(query, params, opts)` | `%{"items" => [%{"definition" => ..., "rank" => ...}], "next_cursor" => ...}` | see §4.4 |
| `handle_export` | `ExportImport.export(id, opts)` | `export_document_map/1` | `{:error, :not_found}` → 404 |

`id`/`name` are never cast to `Ecto.UUID` at the router for `get_active_by_name` (it
takes a plain string, not a UUID — matches `get_active_by_name/2`'s existing `@spec`).
`handle_get_by_id`/`handle_export` cast `:id` the same way `Letflow.Routers.Instances`
casts `instance_id` (`Ecto.UUID.cast/1`) — **except** `Letflow.Definitions.get_by_id/2`
(existing, REQ-030) already internally maps a cast failure to `{:error, :not_found}`
(its own `cast_uuid/1` private helper, line ~1266-1271) rather than a distinct
`:invalid_id` atom the way `Letflow.Instances.get_by_id/2` does. **This requirement
does not change that** (REQ-030's function is out of scope to modify) — so, unlike
`Letflow.Routers.Instances`, `handle_get_by_id`/`handle_export` do **not** pre-cast
`:id` themselves; they pass the raw path segment straight to `get_by_id/2`/`export/2`
and let the existing internal cast-to-`:not_found` collapse happen there. Net effect: a
malformed UUID gets the same 404 a genuinely-absent-but-well-formed UUID gets — a
**stronger** form of INV-5 indistinguishability than R-Co's own 422-vs-404 split (see
§7 OQ-2 — flagged, not silently decided, since it is a real behavior divergence from
R-Co worth a reader noticing).

### 4.4 `handle_search`'s HTTP-layer contract — the requirement's stated trap

This is REQ-081's explicitly named trap: `search/2`/`search_paginated/3` return
`{:error, :query_empty}`/`{:error, :query_too_long}` for a validation failure, and an
**empty list inside `{:ok, ...}`** for "ran fine, matched nothing." The router must
never conflate these:

**Shape:** `handle_search/1`, wrapped in `with_authorized_scope(conn, "GET",
"/definitions/search", fn conn, opts, _actor_id -> ... end)` per §4.1. Inside: fetch
query params; validate `page_size` the same two-step way `Letflow.Routers.Instances.handle_list/1`
already does (`Pagination.parse_page_size_param/1` → `validate_page_size/1`) — a
failure here short-circuits to `Response.bad_request/2` (`"invalid page_size"` /
`"page_size out of range"`) before `q` is even read, since a malformed `page_size` is
unrelated to `q`'s own validity and must not be masked by a `q`-shaped error. On
success, reads `q` from the query string — **absent `q=` is treated as `""`**, not as
some third distinct case, since `Definitions.search_paginated/3`'s `check_query_not_empty/1`
already treats `""` as `{:error, :query_empty}` and an absent param has no meaningfully
different HTTP-layer contract than one sent empty. Calls
`Definitions.search_paginated(q, %{cursor: query["cursor"], page_size: page_size}, opts)`
and dispatches its result through a private `render_search_result/2` with one clause
per outcome, tabulated below plus in §4.4's continuation.

`render_search_result/2`'s five clauses (each a thin one-liner delegating to a
`Letflow.Api.Response` function, no branching logic inside any single clause):
`{:ok, %{items: items, next_cursor: next_cursor}}` → `Response.ok/2` with `"items"`
mapped through `search_result_map/1` (§6) and `"next_cursor"` passed through unchanged
(`nil` on the last page); `{:error, :query_empty}` → `Response.bad_request(conn, "q
must not be empty")`; `{:error, :query_too_long}` → `Response.bad_request(conn, "q
must not exceed 512 bytes")`; `{:error, :invalid_cursor}` → `Response.bad_request(conn,
"invalid cursor")`; `{:error, :wrong_endpoint}` → `Response.bad_request(conn, "cursor
is not valid for this endpoint")`; `{:error, :expired}` → `Response.bad_request(conn,
"cursor has expired")`.

**The trap, stated explicitly:** `query_empty`/`query_too_long` are validation
failures, mapped to a 400-class problem document — **never** routed through the
`{:ok, ...}` clause's empty-array path, and **never** mapped to 404. A genuinely-valid
query with zero matches goes through the `{:ok, %{items: [], next_cursor: nil}}`
clause — HTTP 200, empty array, same status/body shape as any other empty page. These
are three distinct code paths in `render_search_result/2`'s clause list, not one
collapsed case.

Three explicit mappings, exactly matching REQ-081's AC2/AC3:

| Case | `Definitions.search_paginated/3` returns | HTTP |
|---|---|---|
| `q` absent or `""` | `{:error, :query_empty}` | **400** (`Response.bad_request/2`) |
| `q` present, > 512 bytes | `{:error, :query_too_long}` | **400** |
| `q` present, valid, zero matches | `{:ok, %{items: [], next_cursor: nil}}` | **200**, `"items": []` |

**400, not 422** — a deliberate divergence from R-Co's own `handleSearch` (which
returns 422 for both `query_empty`/`query_too_long`). REQ-081's own acceptance
criteria state "a 400-class problem document" verbatim for both cases (AC2); this
requirement's own text is the authority for the HTTP status here, the same way
`Letflow.Routers.Definitions`'s existing moduledoc already documents one deliberate
status/body divergence from R-Co ("Letflow emits `\"valid\"` and omits
`compiler_version`") without treating literal parity as an obligation where the
requirement itself states otherwise. `Response.bad_request/2` sends 400; `unprocessable/2`
would send 422 — this design picks the former to match the AC text exactly, not
approximately.

`handle_list` mirrors `Letflow.Routers.Instances.handle_list/1`'s existing
`page_size`/`cursor` parsing exactly (`Pagination.parse_page_size_param/1` →
`validate_page_size/1` → `{:error, :invalid_page_size}`/`{:error,
:page_size_too_large}` → `Response.bad_request/2`), plus `{:error, :invalid_cursor}`/
`{:error, :wrong_endpoint}`/`{:error, :expired}` → `Response.bad_request/2`, same as
`handle_search`'s cursor-error branches above (both list and search share one cursor
error → HTTP mapping, since both ultimately decode through
`Letflow.Api.Pagination.decode_cursor/4`).

## 5. Reused as-is (no change)

- `Letflow.Definitions.get_by_id/2` (REQ-030) — cross-tenant and nonexistent both
  resolve to `{:error, :not_found}` through the same `Repo.get(ProcessDefinition, uuid,
  prefix: prefix)` call (prefix-scoped lookup — a cross-tenant id is simply absent from
  the caller's schema). This is INV-5's structural mechanism already in place; this
  requirement's router adds no cross-tenant branch of its own.
- `Letflow.Definitions.get_active_by_name/2` (REQ-030) — same prefix-scoping
  mechanism, same INV-5 guarantee: a name whose only ACTIVE row lives in another
  tenant's schema is invisible to `Repo.all(..., prefix: prefix)`, so it 404s
  identically to a name with no ACTIVE row at all.
- `Letflow.Definitions.ExportImport.export/2` (REQ-034) — delegates its own read
  entirely to `Definitions.get_by_id/2` (its own moduledoc: "both its `{:error,
  :not_found}` and `common_error()` shapes propagate unchanged; this function invents
  no new error atom of its own"), so `handle_export`'s cross-tenant/nonexistent
  equivalence is inherited transitively, not independently re-implemented.
- `search/2` (REQ-042) — completely untouched; `search_paginated/3` is an **addition**
  next to it (§2), not a modification, and `search/2`'s existing `limit`/`offset`
  callers (if any exist elsewhere in the codebase — none found in this read) keep
  working unchanged.
- `list/2` (REQ-030) — completely untouched, for the same reason.

## 6. Response shapes (field allowlists — INV-2)

**`definition_map/1`** (used by `handle_get_by_id`, `handle_get_active_by_name`, and
as `list_paginated`'s per-item shape), an explicit allowlist matching R-Co's
`serializeDefinition` field set exactly — every field a direct pass-through from the
`ProcessDefinition.t()` struct except where noted:

| JSON key | Source | Note |
|---|---|---|
| `id` | `definition.id` | |
| `name` | `definition.name` | |
| `version` | `definition.version` | |
| `description` | `definition.description` | nullable, passed through as-is |
| `status` | `definition.status` | uppercased string (`:active` → `"ACTIVE"`) |
| `graph` | `definition.graph` | |
| `created_by` | `definition.created_by` | |
| `created_at` | `definition.created_at` | ISO 8601 |
| `updated_at` | `definition.updated_at` | ISO 8601 |
| `archived_at` | `definition.archived_at` | ISO 8601 or `null` |
| `stage` | `definition.stage` | nullable, passed through as-is |

Exactly eleven keys — no wider Ecto struct field (e.g. `__meta__`) ever reaches
`Jason.encode!/1`. `status` is stored lowercase (`ProcessDefinition`'s own moduledoc, INV-DEF-3) but
serialised uppercase, matching R-Co's `statusToStr`/`DRAFT`/`ACTIVE`/`DEPRECATED`/
`ARCHIVED` wire values and `Letflow.Routers.Instances`'s own `status_string/1`
uppercasing idiom for `InstanceProjection.status`.

**`search_result_map/1`** (used by `handle_search`'s `items`) — two keys: `"definition"`
(the same `definition_map/1` allowlist above, applied to `result.definition`) and
`"rank"` (`result.rank`, the raw `float()`), matching R-Co's `serializeSearchResults`'s `{"definition": ..., "rank": ...}` per-item
shape exactly.

**`export_document_map/1`** (used by `handle_export`) — the **full `ExportDocument`
record**, not a wider "full `ProcessDefinition` record": R-Co's own `serializeExportDocument`
(and Letflow's already-shipped `ExportImport.ExportDocument.t()`) carry exactly
`bpm_export_schema_version`, `id`, `name`, `version`, `description`, `graph`,
`exported_at` — notably **no `status`, `created_by`, `updated_at`, `archived_at`, or
`stage`** (an export is a portable definition-graph document, not a full audit record;
this is R-Co's own design, not a Letflow narrowing). Seven keys, each a direct
pass-through of `ExportDocument.t()`'s own field of the same name (`bpm_export_schema_version`,
`id`, `name`, `version`, `description`, `graph`, `exported_at`) — no computed or
renamed fields, since `ExportDocument.t()`'s field set already matches the wire shape
exactly (REQ-034 built it that way). `exported_at` is already an ISO 8601 string on `ExportDocument.t()` (built via
`DateTime.utc_now() |> DateTime.to_iso8601()` inside `export/2`) — no further
conversion needed at the router.

**`handle_list`/`handle_search` envelope** — matches `Letflow.Routers.Instances`'s
existing `render_page_result/3` envelope shape: `%{"items" => [...], "next_cursor" =>
next_cursor}` (`next_cursor` is `nil`, serialised as JSON `null`, on the last page).

## 7. Invariants

- **INV-1 (tenant isolation).** Every one of the five handlers' first `Repo`-touching
  call receives `opts` built exclusively from `Letflow.Api.Context.scoped_repo_opts/1`
  — no handler constructs its own `prefix`. `list_paginated/2`/`search_paginated/3`
  take `opts` the same way every other function in this module already does
  (`Keyword.get(opts, :prefix)`), passed to every `Repo.all/2` call.
- **INV-2 (server-side field allowlisting).** §6's three response-map functions are
  the only place a `ProcessDefinition`/`ExportDocument` struct is turned into wire
  JSON; none of the five handlers calls `Jason.Encoder` on a raw struct or passes one
  to `Response.ok/2` directly.
- **INV-5 (not-found/forbidden indistinguishability).** §5 — inherited structurally
  from `get_by_id/2`/`get_active_by_name/2`/`export/2`, which are prefix-scoped reads
  with no branch capable of distinguishing "belongs to another tenant" from "never
  existed." `search_paginated/3` achieves the search-specific form of the same
  guarantee by construction: a query matching only tenant B's rows produces zero rows
  from a `Repo.all(..., prefix: tenant_a_prefix)` call, the same `{:ok, %{items: [],
  next_cursor: nil}}` shape as any other no-match query — there is no code path that
  could reveal "matched something, just not yours."
- **INV-7 (no SQL string interpolation).** Every filter/keyset predicate uses bound
  `^value`s inside `Ecto.Query`/`fragment/1`, never string-built SQL — the `%query%`
  pattern is composed into the bound `^pattern` value exactly as `where_search_match/2`
  already does, never spliced into fragment text.
- **INV-8 (typed results).** Every new function returns `{:ok, _} | {:error, _}`; the
  router's `with`/`case` chains handle every documented error atom explicitly — no
  bare pattern match on a fallible call.

## 8. Open questions

- **OQ-1.** `list/2`'s existing `after_created` filter is not exposed through
  `list_paginated/2` (superseded by real cursor pagination — see §3.1). If a caller of
  `list/2` directly (not through HTTP) still needs `after_created`, that caller is
  unaffected since `list/2` itself is untouched. Not resolved here because no such
  caller was found in this read of the codebase; flagged in case REVIEWER knows of one.
- **OQ-2.** `handle_get_by_id`/`handle_export` inherit `get_by_id/2`'s existing
  malformed-UUID-collapses-to-`:not_found` behavior (§4.3), diverging from R-Co's
  422-for-malformed-id/404-for-absent split. This is a **stronger** INV-5 guarantee,
  not a weaker one, but it is a real behavior divergence from R-Co worth a deliberate
  sign-off rather than an unnoticed side effect of reusing an existing function. Not
  resolved here — flagged for REVIEWER; the alternative (pre-casting `:id` in the
  router and returning 422 on cast failure, matching `Letflow.Routers.Instances`'s
  idiom) is available if REVIEWER prefers literal R-Co parity over the stronger
  guarantee, at the cost of `handle_get_by_id`/`handle_export` no longer sharing
  `get_by_id/2`'s single collapse path for this one case.
- **OQ-3.** `search_paginated/3`'s and `list_paginated/2`'s default `page_size` — this
  design assumes the same `Letflow.Api.Pagination.default_page_size/0` (50) /
  `max_page_size/0` (200) every other S4 list endpoint uses, **not** R-Co's own
  `search`-specific default of 20/max 100 (`SearchQueryParams`'s doc comment). R-Co's
  20/100 was a `limit`/`offset`-era, non-cursor-pagination-module constant;
  REQ-067/`Letflow.Api.Pagination` is the single page-size authority for every
  cursor-paginated S4 endpoint, and this design does not carve out a
  per-endpoint exception. Flagged as a deliberate parity divergence, not a
  silently-guessed default.

---

## 9. REVIEWER decisions (WF02-REQ081, 2026-08-23)

Reviewed commit `2c36165`. Idiom/OTP-quality pass only — SECURITY-REVIEWER already
passed INV-1/5/7, permission enforcement, cursor-forgery resistance, and export scope.

**OQ-2 — malformed UUID collapses to 404, not R-Co's 422.** Decision: **accept the
divergence, no change requested.** `handle_get_by_id`/`handle_export` correctly do not
pre-cast `:id`; they let `Definitions.get_by_id/2`'s existing `cast_uuid/1` collapse
both "malformed" and "well-formed but absent/cross-tenant" into one `{:error,
:not_found}` path. This is a strictly *stronger* form of INV-5 (not-found/forbidden
indistinguishability now also covers not-found/malformed), it costs nothing (no new
code path, no modification to REQ-030's `get_by_id/2`), and matching R-Co's 422 would
require either widening REQ-030's function (out of this requirement's scope) or
duplicating a UUID pre-cast that `Letflow.Routers.Instances` only has because
`Letflow.Instances.get_by_id/2` itself distinguishes the two cases (a different
existing idiom, not one this requirement should retrofit onto `Definitions.get_by_id/2`
as a side effect). Literal R-Co parity is not an obligation where it would weaken an
invariant for no behavioral gain.

**OQ-3 — page_size default 50/max 200, not R-Co's search-specific 20/100.** Decision:
**accept, no change requested.** No `docs/migration/decisions/` record fixes a
search-specific page-size constant, so this isn't overriding a settled decision — it's
a straightforward application of `Letflow.Api.Pagination`'s existing single-authority
default (REQ-067) to a fifth cursor-paginated endpoint, consistent with every other S4
list/search-shaped endpoint. Introducing a per-endpoint page-size exception here would
itself be the scope-creep move (a second page-size policy with no requirement asking
for one); keeping one authority is the idiomatic choice.

**Fix applied directly (mechanical, in scope for REVIEWER):**
`lib/letflow/routers/definitions.ex`'s `render_search_result/2` mapped `{:error,
:expired}` to a plain `Response.bad_request(conn, "cursor has expired")`, while the
sibling `render_list_result/2` (same file, same error atom, same cursor-decode path)
correctly used `Response.send_problem(conn, Error.cursor_expired())` — matching
`Letflow.Routers.Instances`'s established idiom of giving cursor-expiry its own
problem-document `type`, not a generic bad-request one. This was an internal
inconsistency (two different wire-level `type` values for the identical error
condition, within one router module) traceable to following §4.4's prose literally for
`handle_search` while `handle_list` instead followed `Letflow.Routers.Instances`'s
actual code. Fixed `render_search_result/2`'s `:expired` clause to match
`render_list_result/2` and the established idiom. `mix compile --warnings-as-errors`
and `mix format --check-formatted` both clean after the fix.

**Idiom/structure:** `list_paginated/2`'s keyset WHERE (`filter_by_definitions_list_cursor/2`,
`{d.created_at, d.id} < {^ts, ^id}`) is a faithful mirror of `Letflow.Instances.list/2`'s
`filter_by_list_cursor/2` — same tuple-comparison shape, same DESC/DESC `order_by`,
same `limit(^(page_size + 1))` + `split_*_page/2` overfetch pattern. `page_size` as a
required `Map.fetch!/2` key (diverging from the design doc's own `optional(:page_size)`
type) is explicitly noted in both a code comment (`lib/letflow/definitions.ex`, directly
above `@type list_paginated_filters`) and the commit message — not silently left for a
future reader to discover as a mismatch against the design doc. `@rank_case_sql` is
referenced verbatim at all four call sites (`select_with_rank/3`, `order_by_rank/3`,
`filter_by_search_cursor/4` ×3 fragment calls, `order_by_rank_paginated/3`) — genuine
reuse of one module attribute, no duplicated SQL text. Router/context module naming,
error-tuple shapes (`{:error, :not_found}`, `{:error, :invalid_cursor}`, etc.),
moduledoc structure, and the `with_authorized_scope/4` shape all match
`Letflow.Instances`/`Letflow.Routers.Instances`'s REQ-080 precedent closely enough that
a reader moving between the two sibling modules would find no unexplained convention
gap.

**Scope:** commit `2c36165` touches exactly `lib/letflow/api/authorization.ex`,
`lib/letflow/definitions.ex`, `lib/letflow/routers/definitions.ex`, and this design
doc — no changes to `Letflow.Instances`, `Letflow.Routers.Instances`, or any other
REQ-080 code; no handler beyond the five specified; no refactor beyond what REQ-081
needed.

**Result: PASS-WITH-FIXES.** Ready for TEST-DESIGNER.
