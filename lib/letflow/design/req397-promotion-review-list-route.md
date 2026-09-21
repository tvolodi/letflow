PROVENANCE (historical, not current decision authority):
# Design: REQ-397 — `GET /api/v1/promotions` list route (review-queue discovery)

**Requirement:** REQ-397 (`docs/requirements.yaml`, search `id: REQ-397`, stage S6,
`depends_on: [REQ-035, REQ-077]`)
**Owner (implementer):** ELIXIR-DEV
**This document produces:** the new route's exact path/method/ordering, a new
`Letflow.Definitions.PromotionReviewStore.list_reviews/2` `@spec` + query shape
(fragment/keyset structure, not literal SQL), the pagination shape decision (with
justification), filter-validation logic + its 4xx error shape, the response
allowlist map, authorization wiring, and full test-coverage design mapped to each
acceptance criterion. **No implementation code** — no function bodies, no `.ex`
files.

---

## 0. Sources read for this design

- `docs/requirements.yaml` REQ-397 entry in full (title, description, all 8
  acceptance criteria, `depends_on: [REQ-035, REQ-077]`) and the REQ-398 entry
  immediately after it (frontend consumer, confirms this route's query-param/
  envelope shape is the only contract REQ-398 depends on).
- `lib/letflow/routers/promotions.ex` (906 lines, read in full) — REQ-077's router.
  R1–R8 + R11 (`platform-events`, ISS-0733 GAP B) exist; no list route. Confirmed the
  moduledoc's five load-bearing conventions this design must not diverge from without
  saying so: the `:Unknown`/PLATFORM_ADMIN-only authorization decision (§"The
  `:Unknown` authorization decision"), the allowlist-response-map rule (§"The
  allowlist statement"), the `iso8601/1` private helper (handles both `%DateTime{}`
  and `%NaiveDateTime{}`, but `PromotionReview.inserted_at` is always `%DateTime{}`
  per its own `timestamps(type: :utc_datetime_usec)`), R11's cursor-pagination
  pattern (`@platform_events_cursor_prefix "PE:"`, `Pagination.decode_cursor/4` +
  `Pagination.parse_int_from_cursor/3`/`find_nth_colon/2`), and the route-ordering
  discipline (a literal-segment route is declared ahead of any wildcard route it
  could collide with — irrelevant here since `GET /` cannot collide with `GET /:id`,
  a plain `/` never matches a non-empty `:id` segment, but the design below still
  follows the codebase's placement convention, see §4).
- `lib/letflow/definitions/promotion_review_store.ex` (469 lines, read in full) —
  existing `get_review/2` (single-row) and the five transition functions
  (`insert_review/2`, `approve_review/4`, `reject_review/3`, `mark_review_applied/2`,
  `mark_review_failed/2`, `supersede_review/3`). No list/filter function exists.
  Every function does `Keyword.fetch!(opts, :prefix)` — no default — this design's
  new function follows the same rule.
- `lib/letflow/definitions/promotion_review.ex` (schema, read the field list) —
  `id` (`:binary_id`), `plan_digest`, `def_type` (`:string`, default `"process"`, no
  enum/CHECK — open-ended per the schema's own Open Question 1), `def_id`
  (`:string`, holds `plan.process_key`, NOT a UUID/FK), `serialised_plan`, `status`
  (`Ecto.Enum`, `[:pending_review, :approved, :rejected, :applied, :failed,
  :superseded]`), `requested_by` (`Ecto.UUID`), `approved_by`, `approved_at`,
  `superseded_by`, `row_version`, `timestamps(type: :utc_datetime_usec)`
  (`inserted_at`/`updated_at`). No `tenant_id` column (Decision 0006 D2 / REQ-064 —
  the per-tenant Postgres schema is the isolation boundary).
- `lib/letflow/definitions.ex` — read `list_paginated/2` (lines ~647–671) and its
  private helpers in full: `where_status/2` (line 1950), `filter_by_definitions_list_cursor/2`
  (1972), `decode_definitions_list_cursor/1` (1979), `decode_definitions_list_seek/1`
  (1998), `split_definitions_list_page/2` (2005), `build_definitions_list_next_cursor/1`
  (2012). This is **the existing list-endpoint convention** this design's pagination
  decision reuses (see §2) — found per REQ-397's own instruction to check
  `definitions.ex`/`instances.ex` before inventing a new shape.
- `lib/letflow/routers/definitions.ex` — read the `GET /definitions` handler (lines
  ~410–470: `handle_list/1`, `render_list_result/2`) and its route declaration
  (`authz_get "/", :DefinitionsRead` — declared *last* among this module's GET
  routes, after `/active/:name`, `/search`, `/delta`, `/:id/export`, `/:id`, since a
  plain `/` cannot be captured by any `:id`-shaped wildcard regardless of
  declaration order — this design's `get "/"` placement in `promotions.ex` follows
  the same convention, see §4).
- `lib/letflow/routers/instances.ex` — read `handle_list/2`/`render_page_result/3`
  (same cursor-pagination shape as `definitions.ex`, confirming this is a
  codebase-wide convention, not a one-off).
- `lib/letflow/routers/tasks.ex` — read `handle_list/2` and `parse_status_param/1`
  (lines 508–512, the `"status must be one of PENDING, COMPLETED, CANCELLED"` 4xx
  precedent this design's `status`-rejection wording follows) and
  `parse_instance_id_param/1`/`non_empty/1` (the "empty string param == absent
  filter" idiom this design's `def_id`/`def_type` filters reuse).
- `lib/letflow/api/pagination.ex` (402 lines, read in full) — `Cursor.t()` (one
  field, `inner`, structurally enforcing INV-1/INV-5: no decoded cursor field can
  widen or redirect tenant scope), `Page.t()`, `parse_page_size_param/1`,
  `validate_page_size/1` (default 50, min 1, max 200), `encode_cursor/1`,
  `decode_cursor/4` (base64url decode → prefix check → expiry check, using the
  first payload slot after the prefix as a *mint-time* timestamp, never a domain
  timestamp — see `build_raw_cursor_timestamp_key/4`), `parse_int_from_cursor/3`,
  `find_nth_colon/2`.
- `lib/letflow/api/error.ex` — `Error.cursor_expired/0` (410, RFC 9457 problem
  document), reused unchanged (see §5).
- `test/letflow/routers/promotions_test.exs` (R11's test file, read in full) — the
  real-HTTP dispatch convention this design's test plan reuses: dispatches directly
  against `Letflow.Routers.Promotions.call/2` with `conn.assigns.auth_context` set by
  hand, `Letflow.Plugs.Authorize` still runs for real and resolves
  `conn.assigns.scoped_opts`, `Letflow.TenantFixture.provisioned_tenant!/1` for real
  tenant schemas, `Letflow.DataCase, async: false`.
- `test/letflow/definitions/promotion_review_store_test.exs` — read
  `insert_review_fixture!/3` (line 162) and confirmed every non-`pending_review`
  status in a test fixture is reached by calling the *real* transition function
  (`approve_review/4`, `reject_review/3`, `mark_review_applied/2`,
  `mark_review_failed/2`, `supersede_review/3`) on a previously-inserted row — no
  test anywhere in this file constructs a `%PromotionReview{status: ...}` by hand or
  via a raw `Repo.insert`. This design's test plan (§7) follows the same rule.
- `docs/agents/instructions/security-invariants.md` — INV-1 (tenant isolation via
  `:prefix`, live), INV-5 (cross-tenant/nonexistent indistinguishability — already
  the router's own §"INV-5" note; this route's filters must not create a new
  distinguishing side channel, see §5), INV-8 (typed, non-raising results on
  caller-controlled input).
- `docs/anti-patterns.md` — no directly-applicable entry found for this change.

---

## 1. Scope boundary

One new route, `GET /promotions` (mounted as `GET /api/v1/promotions`), delegating
to one new context function, `Letflow.Definitions.PromotionReviewStore.list_reviews/2`.
No migration, no new Ecto schema, no change to R1–R8/R11's existing behavior, no
change to `:Unknown` authorization semantics. Explicitly OUT OF SCOPE (per REQ-397's
own text, restated here so ELIXIR-DEV doesn't second-guess it): the frontend list
page (REQ-398), durably recording a submit-time conflict refusal that never created a
`promotion_reviews` row, and `ConflictRejectionAlert.tsx`.

## 2. Pagination shape decision (REQ-397 AC7)

**Decision: cursor-based pagination, reusing `Letflow.Api.Pagination`'s existing
opaque-cursor codec exactly as `Definitions.list_paginated/2` and R11's
`handle_platform_events/1` already do — not a new shape.**

**Convention found:** every list endpoint checked (`GET /definitions`,
`GET /instances`, `GET /instances/:id/attachments`, `GET /promotions/platform-events`)
uses the same query-param pair and response envelope:

  * Request: `page_size` (optional; `Pagination.parse_page_size_param/1` +
    `validate_page_size/1` — absent → 50, `1..200` accepted, `0` or `>200` → 4xx,
    non-numeric → 4xx) and `cursor` (optional opaque string; absent/empty → first
    page).
  * Response: `{"items": [...], "next_cursor": <string-or-null>}` — no `count`/
    `total_count` key anywhere in this codebase's existing list envelopes (confirmed
    by reading every `render_list_result`/`render_page_result`/`render_platform_events`
    body cited in §0 — each hand-builds exactly this two-key map, never serializes
    `Pagination.Page.t()`'s `count` field even though that struct has one).
  * A next page exists iff the query fetched `page_size + 1` rows; the extra row is
    dropped and its predecessor's sort key is what the next cursor encodes
    (`split_definitions_list_page/2`'s pattern, reused verbatim — see §3.3).

This design adopts that convention unchanged: **`page_size`/`cursor` query params,
`{"items": [...], "next_cursor": ...}` envelope.** No new shape is introduced, so
there is nothing here to flag for REVIEWER on the "new convention" branch of REQ-397's
own instruction — the convention search in §0 found a live, three-times-repeated
precedent, not an absence.

**Why cursor, not offset/limit, restated for this requirement specifically:** an
offset-based page is unstable under concurrent writes to `promotion_reviews` (a row
inserted or transitioned between two page fetches shifts every subsequent offset —
exactly the review-queue-under-active-use scenario this requirement exists to serve,
per ISS-0734's "a reviewer can discover reviews without an out-of-band reviewId"
framing). Keyset/cursor pagination has no such instability: a page boundary is a real
row's sort key, not a positional count.

## 3. `Letflow.Definitions.PromotionReviewStore.list_reviews/2` (new)

### 3.1 Signature

```
@type status :: PromotionReview.status()
# = :pending_review | :approved | :rejected | :applied | :failed | :superseded

@type list_reviews_filters :: %{
        optional(:status) => [status()] | nil,
        optional(:def_id) => String.t() | nil,
        optional(:def_type) => String.t() | nil,
        optional(:cursor) => String.t() | nil,
        required(:page_size) => pos_integer()
      }

@type list_reviews_result :: %{items: [PromotionReview.t()], next_cursor: String.t() | nil}

@type list_reviews_error :: :invalid_cursor | :wrong_endpoint | :expired | :invalid_schema_name

@spec list_reviews(filters :: list_reviews_filters(), opts :: [prefix: String.t()]) ::
        {:ok, list_reviews_result()} | {:error, list_reviews_error()}
```

Placed in `PromotionReviewStore` (not a new module) — this table already has exactly
one context module owning every read and write against it (`get_review/2` plus the
five transitions); splitting a `list_reviews/2` read into a second module would
duplicate the `opts[:prefix]`-mandatory discipline the existing moduledoc states once
for the whole file, for no offsetting benefit (unlike REQ-081's `search_paginated/3`
split rationale in `definitions.ex`, which existed only because `@rank_case_sql`'s
`fragment/1` compile-time-literal constraint forced same-module placement — no
analogous constraint exists here, so the "same module as every other reader of this
table" default applies instead).

### 3.2 Prefix-validity guard (mirrors `list_paginated/2`, diverges from `get_review/2`)

`list_reviews/2` opens with `{:ok, _} <- TenantProvisioning.tenant_id_for_schema_name(prefix)`
before building any query — the same guard `Definitions.list_paginated/2` uses and
`insert_review/2` already uses in this very module (`TenantProvisioning` is already
aliased here). `get_review/2` does not have this guard because a single-row
`Repo.get/3` against a bogus prefix simply returns `nil` (no PK exists to find,
whatever schema `prefix` names); a *list* query with no `WHERE id = ...` clause
against a schema whose `promotion_reviews` table doesn't exist would instead raise a
raw `Postgrex.Error` (`undefined_table`), surfacing as an uncaught 500 with no typed
error atom for the router to map — the same reasoning `list_paginated/2`'s own call
site documents. In ordinary operation `opts[:prefix]` always comes from
`conn.assigns.scoped_opts`, itself resolved by `Letflow.Plugs.Authorize` from a real
authenticated session, so this guard is defensive-depth, not a live path any real
caller is expected to hit — same status as `list_paginated/2`'s identical guard.

`{:error, :invalid_schema_name}` is not explicitly branched on by the router (see
§5) — it falls into the same `{:error, _other}` catch-all every other unmapped error
in this router already falls into (`Response.internal_error/1`), matching
`Routers.Definitions`'s own `render_list_result/2` precedent (`{:error,
_common_error} -> Response.internal_error(conn)`).

### 3.3 Query shape

```
prefix = Keyword.fetch!(opts, :prefix)
page_size = Map.fetch!(filters, :page_size)

with {:ok, _} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
     {:ok, cursor_seek} <- decode_promotion_reviews_list_cursor(Map.get(filters, :cursor)) do
  query =
    PromotionReview
    |> where_review_status(Map.get(filters, :status))
    |> where_def_id(Map.get(filters, :def_id))
    |> where_def_type(Map.get(filters, :def_type))
    |> filter_by_promotion_reviews_list_cursor(cursor_seek)
    |> order_by([r], desc: r.inserted_at, desc: r.id)
    |> limit(^(page_size + 1))

  rows = Repo.all(query, prefix: prefix)
  {page, next_cursor} = split_promotion_reviews_list_page(rows, page_size)
  {:ok, %{items: page, next_cursor: next_cursor}}
end
```

Private helpers, each a direct sibling of `definitions.ex`'s same-named-pattern
helpers (§0), fragment/shape only — no literal SQL, no function bodies:

  * `where_review_status(query, nil)` → `query` unchanged.
    `where_review_status(query, statuses)` when `statuses` is a non-empty list of
    atoms → `where([r], r.status in ^statuses)`. (Filters by **one or more**
    statuses per AC3/description item 3 — see §4 for how the router turns a
    caller-supplied comma-separated string into this list, and why comma-separated
    rather than repeated `status=` params.)
  * `where_def_id(query, nil)` → unchanged. `where_def_id(query, def_id)` when
    `def_id` is a non-empty string → `where([r], r.def_id == ^def_id)`. Exact-match,
    `def_id` is not a UUID (it holds `plan.process_key`, a string) — no `Ecto.UUID.cast/1`
    step, unlike path-parameter review-id handling elsewhere in this router.
  * `where_def_type(query, nil)` → unchanged. `where_def_type(query, def_type)` when
    `def_type` is a non-empty string → `where([r], r.def_type == ^def_type)`.
    Exact-match, no enum validation — `def_type` is deliberately open-ended per the
    schema's own Open Question 1 (§0), so an unrecognized `def_type` value is simply
    "no rows match," never rejected the way an unrecognized `status` value is (§4).
  * `decode_promotion_reviews_list_cursor(nil)` → `{:ok, nil}`.
    `decode_promotion_reviews_list_cursor(raw)` when `raw` is a binary → delegates to
    `Pagination.decode_cursor(raw, @promotion_reviews_list_cursor_prefix,
    byte_size(@promotion_reviews_list_cursor_prefix))`, mapping `{:ok, %Pagination.Cursor{}}`
    through a `decode_promotion_reviews_list_seek/1` step and passing `{:error,
    :wrong_endpoint}`/`{:error, :expired}` through unchanged, collapsing
    `:invalid_base64`/any other decode failure to `{:error, :invalid_cursor}` — the
    exact three-way collapse `decode_definitions_list_cursor/1` already performs.
  * `@promotion_reviews_list_cursor_prefix "PR:"` — a new, distinct cursor-endpoint
    prefix. Does not collide with `"PE:"` (this same router's R11 platform-events
    cursor) or `"DL:"` (`Definitions.list_paginated/2`'s cursor,
    `decode_definitions_list_cursor/1`'s own comment) or `"A:"`/`"T:"`/`"U:"` (Audit/
    Tenants/Identity, per R11's own comment citing them) — `decode_cursor/4`'s prefix
    check (`check_prefix/2`) is what makes a cursor minted by one endpoint rejected
    by every other endpoint's decode call (`{:error, :wrong_endpoint}`).
  * The decoded cursor payload layout is `"PR:<mint_time_us>:<id>:<inserted_at_us>"`
    — same field-slot idiom as `"DL:<mint_time_us>:<id>:<created_at_us>"`
    (§0's "more mature" idiom note): the first slot after the prefix is always the
    *mint-time* timestamp `decode_cursor/4`'s own expiry check reads, never the
    domain `inserted_at` value itself (putting a domain timestamp there would make a
    cursor built from an old-but-still-`pending_review` row appear already-expired
    at mint time — same defect `identity.ex`'s moduledoc already documents avoiding).
    `decode_promotion_reviews_list_seek/1` parses this exactly as
    `decode_definitions_list_seek/1` does: split on `:`, `parts: 3`, discard the
    mint-time segment, return `{id_str, String.to_integer(inserted_at_us_str)}`.
  * `filter_by_promotion_reviews_list_cursor(query, nil)` → unchanged.
    `filter_by_promotion_reviews_list_cursor(query, {id, inserted_at_us})` →
    `ts = DateTime.from_unix!(inserted_at_us, :microsecond)`, then
    `where([r], {r.inserted_at, r.id} < {^ts, ^id})` — a strict tuple-less-than over
    the same `(inserted_at, id)` DESC ordering the outer query sorts by, matching
    `filter_by_definitions_list_cursor/2`'s pattern exactly (this is what makes
    "next page continues strictly after the last row already returned" correct
    under DESC ordering with a determinstic `id` tiebreak — AC1's "most-recent
    first ... ties broken by id for determinism" requirement).
  * `split_promotion_reviews_list_page(rows, page_size)` when `length(rows) >
    page_size` → drop the trailing probe row, build `next_cursor` from the *last
    row of the kept page* via `build_promotion_reviews_list_next_cursor/1`.
    `split_promotion_reviews_list_page(rows, _page_size)` otherwise → `{rows, nil}`.
  * `build_promotion_reviews_list_next_cursor(%PromotionReview{id: id, inserted_at:
    inserted_at})` → `mint_time_us = System.system_time(:microsecond)`,
    `inserted_at_us = DateTime.to_unix(inserted_at, :microsecond)`, then
    `Pagination.build_raw_cursor_timestamp_key(@promotion_reviews_list_cursor_prefix,
    mint_time_us, id, inserted_at_us) |> Pagination.encode_cursor()`.

### 3.4 Ordering (AC1)

`order_by([r], desc: r.inserted_at, desc: r.id)` — most-recent-first, `id` DESC as
the deterministic tiebreak for two rows with an identical `inserted_at` (the same
compound tiebreak `Letflow.Instances.list/2`/`Letflow.Identity.list_users/2`/
`Definitions.list_paginated/2` all already use, per `definitions.ex`'s own comment
cited in §0).

## 4. Route: `GET /promotions` (mounted `GET /api/v1/promotions`)

### 4.1 Declaration and placement

```
get "/" do
  handle_list_reviews(conn)
end
```

Declared using the plain `get` macro (no `:policy_key`) — same `:Unknown`-gated
mechanism every other route in this module already uses (see §5). Placed **after**
`post "/:review_id/run-assertions"` and **before** `match _` — i.e., last among this
module's route declarations, mirroring `Routers.Definitions`'s own `authz_get "/"`
placement (last, after every `:id`/literal-segment GET route, §0). This placement is
purely stylistic/consistency-driven, not a correctness requirement: `GET /` cannot be
captured by `GET /:id`, `GET /:id/context`, or `GET /platform-events` regardless of
declaration order, since none of those patterns matches an empty path segment — Plug
Router dispatch is exact-literal-vs-wildcard, not first-match-wins across differently
shaped patterns here. Stated explicitly so ELIXIR-DEV doesn't need to re-derive this
ordering-safety argument from scratch.

### 4.2 Handler

```
defp handle_list_reviews(conn) do
  conn = fetch_query_params(conn)
  query = conn.query_params
  opts = conn.assigns.scoped_opts

  with {:ok, statuses} <- parse_status_filter_param(Map.get(query, "status")),
       {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
       {:ok, page_size} <- Pagination.validate_page_size(raw_page_size) do
    filters = %{
      status: statuses,
      def_id: non_empty(Map.get(query, "def_id")),
      def_type: non_empty(Map.get(query, "def_type")),
      cursor: Map.get(query, "cursor"),
      page_size: page_size
    }

    render_list_reviews(conn, PromotionReviewStore.list_reviews(filters, opts))
  else
    {:error, :invalid_status} ->
      Response.bad_request(
        conn,
        "status must be one or more of: pending_review, approved, rejected, applied, failed, superseded"
      )

    {:error, :invalid_page_size} ->
      Response.bad_request(conn, "invalid page_size")

    {:error, :page_size_too_large} ->
      Response.bad_request(conn, "page_size out of range")
  end
end
```

`non_empty/1` is the same private helper `handle_run_assertions`'s sibling routes
already use elsewhere in this codebase's routers (`tasks.ex`'s own `non_empty/1`,
§0) — `nil`/`""` → `nil` (no filter), any other binary passed through unchanged. This
module does not currently define `non_empty/1`; this design adds one private copy to
`promotions.ex` (three-line pattern-match function, not shared code — every router
file that needs it already defines its own copy rather than importing a shared
helper, matching this codebase's existing per-file duplication of that one idiom).

### 4.3 `status` filter parsing — accepts one or more values (AC3, description item 3)

**Decision: a single `status` query parameter holding a comma-separated list**
(e.g. `?status=rejected` or `?status=rejected,failed`), not repeated `status=`
params and not `status[]=` bracket-array syntax.

**Why, stated explicitly since this is a genuinely new sub-shape not found verbatim
elsewhere (flagged for REVIEWER per REQ-397's own instruction, same posture as
REQ-386's precedent):** Plug's default query-string decoder
(`Plug.Conn.Query.decode/1`, what `fetch_query_params/1` uses) treats two repeated
non-bracket keys (`status=a&status=b`) as sequential `Map.put/3` calls into the same
top-level map — the second occurrence silently overwrites the first, never producing
a list. Only bracket syntax (`status[]=a&status[]=b`) yields a list under Plug's
decoder, and no route in this codebase (checked `definitions.ex`, `instances.ex`,
`tasks.ex`, `promotions.ex` R11) uses bracket-array query params anywhere — adopting
it here for this one filter would be a second, inconsistent new convention in the
same requirement. A single comma-separated value needs no decoder change, composes
identically with `curl`/every HTTP client's plain query-string building, and every
filter value here is a closed six-member enum with no legal comma in any member, so
there is no ambiguity between "the delimiter" and "a value."

```
defp parse_status_filter_param(nil), do: {:ok, nil}
defp parse_status_filter_param(""), do: {:ok, nil}

defp parse_status_filter_param(raw) when is_binary(raw) do
  raw
  |> String.split(",")
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
  |> parse_status_values([])
end

defp parse_status_values([], []), do: {:ok, nil}
defp parse_status_values([], acc), do: {:ok, Enum.reverse(acc)}

defp parse_status_values([raw | rest], acc) do
  case status_atom(raw) do
    {:ok, atom} -> parse_status_values(rest, [atom | acc])
    :error -> {:error, :invalid_status}
  end
end

defp status_atom("pending_review"), do: {:ok, :pending_review}
defp status_atom("approved"), do: {:ok, :approved}
defp status_atom("rejected"), do: {:ok, :rejected}
defp status_atom("applied"), do: {:ok, :applied}
defp status_atom("failed"), do: {:ok, :failed}
defp status_atom("superseded"), do: {:ok, :superseded}
defp status_atom(_other), do: :error
```

The **first** unrecognized token in the comma-separated list short-circuits the whole
filter to `{:error, :invalid_status}` (via `parse_status_values/2`'s non-tail-recursive
`:error` propagation) — a request with one valid and one invalid status value is
rejected outright, never silently reduced to "just the valid one," matching AC4's "an
unrecognised status value is rejected... not silently ignored." An all-empty/only-
commas input (`?status=` or `?status=,,`) reduces to `nil` (no filter) rather than an
error — consistent with `def_id`/`def_type`'s "empty string == absent filter" idiom
and with `tasks.ex`'s own `parse_instance_id_param(nil)`/`non_empty("")` precedent of
treating an empty param as "not supplied," not as "supplied but invalid."

### 4.4 Response rendering (AC1, AC5)

```
defp render_list_reviews(conn, {:ok, %{items: items, next_cursor: next_cursor}}) do
  Response.ok(conn, %{
    "items" => Enum.map(items, &promotion_review_list_item_map/1),
    "next_cursor" => next_cursor
  })
end

defp render_list_reviews(conn, {:error, :invalid_cursor}),
  do: Response.bad_request(conn, "invalid cursor")

defp render_list_reviews(conn, {:error, :wrong_endpoint}),
  do: Response.bad_request(conn, "cursor is not valid for this endpoint")

defp render_list_reviews(conn, {:error, :expired}),
  do: Response.send_problem(conn, Error.cursor_expired())

defp render_list_reviews(conn, {:error, _other}), do: Response.internal_error(conn)
```

This exactly mirrors `Routers.Definitions`'s `render_list_result/2` (§0) — same four
named branches plus the same catch-all, so `{:error, :invalid_schema_name}` (§3.2)
falls into the unmapped `{:error, _other}` branch, same as `Definitions.list_paginated/2`'s
own unmapped-error handling.

### 4.5 Response item shape (AC5, description item 5)

```
@spec promotion_review_list_item_map(PromotionReview.t()) :: map()
defp promotion_review_list_item_map(review) do
  %{
    "id" => review.id,
    "status" => Atom.to_string(review.status),
    "def_type" => review.def_type,
    "def_id" => review.def_id,
    "requested_by" => review.requested_by,
    "inserted_at" => iso8601(review.inserted_at),
    "updated_at" => iso8601(review.updated_at)
  }
end
```

Exactly the 7 keys REQ-397's description item 5 names, in the same order, reusing
this module's own `iso8601/1` private helper unchanged (already correct for
`%DateTime{}}`, which is what `PromotionReview.inserted_at`/`updated_at` always are —
see §0). `"id"` (not `"review_id"`) — deliberately different from `review_context_map/1`'s
own `"review_id"` key (R4, §0): this is a list-row identifier a caller uses to
navigate to the existing detail route (`GET /promotions/:id`, R3/R4), and REQ-397's
own acceptance-criteria wording names the field `id`, not `review_id`. Never a raw
struct/`Jason.Encoder` derivation, never `Map.from_struct/1` — same allowlist
discipline this module's moduledoc states for every other response map (§0's "The
allowlist statement").

**Deliberately excluded:** `plan_digest`, `serialised_plan`, `approved_by`,
`approved_at`, `superseded_by`, `row_version`. None is named in REQ-397's acceptance
criteria or its description item 5's field list; a reviewer who needs any of them
already has `GET /promotions/:id/context` (R4) one click away via this row's own
`id`. `plan_digest` in particular is excluded for the same reason R3's
`assertion_run_map/1` already excludes it (§0, R3's own comment): a list response is
a broader-audience read than a single-review detail fetch, and handing out the exact
token needed to approve/apply a review to every row in a bulk listing is a strictly
worse exposure than R3's already-documented reasoning against it on one row.

## 5. Authorization (AC1, AC6, description item 4)

**No new policy key, no new permission.** `get "/"` uses the plain `get` macro —
identical mechanism to every other route in this file (§0's "The `:Unknown`
authorization decision"): `Letflow.Plugs.Authorize` evaluates it as `endpoint ==
:Unknown`, `Allow` only for `PLATFORM_ADMIN`, `Deny403` for every other role
including no-roles-at-all. This is the same class of restriction R-Co's
`main.zig:1571` already hardcodes for the whole promotions surface, per this file's
own moduledoc — nothing here widens it. `conn.assigns.scoped_opts` (the `[prefix:
...]` this route passes to `PromotionReviewStore.list_reviews/2`) is resolved by
`Letflow.Plugs.Authorize` from `conn.assigns.auth_context` before this router's
`:dispatch` ever runs — same mechanism every other route in this file already relies
on (§0's "The allowlist statement" closing paragraph). Because `promotion_reviews`
carries no `tenant_id` column, the per-tenant schema `scoped_opts[:prefix]` names
*is* the isolation boundary (§0/§3.3) — there is no second, unscoped query anywhere
in `list_reviews/2` that could leak another tenant's rows, satisfying INV-1. Unlike
R3/R4/R5/R6/R7's single-row INV-5 concern (a cross-tenant *id* must be
indistinguishable from a nonexistent one), a list route has no analogous id-guessing
oracle to defend against — a caller supplying a `def_id`/`status` filter that matches
zero rows in their own schema simply gets `{"items": [], "next_cursor": nil}`, the
same shape as "matches zero rows because none exist yet," not a distinguishable
error.

**SECURITY-REVIEWER sign-off is REQUIRED before this route merges** — this is a
tenant-data-scoped read/list route, the same class REQ-394 required sign-off for
(per REQ-397's own AC8). ELIXIR-DEV must route this change through
SECURITY-REVIEWER before REVIEWER/TEST-DESIGNER, not merge on REVIEWER sign-off
alone.

## 6. Module wiring

`Letflow.Routers.Promotions` already aliases `Letflow.Api.Pagination` and
`Letflow.Definitions.PromotionReviewStore` (both used by R11/R3 respectively) — no
new alias needed. `PromotionReviewStore` already aliases `Letflow.TenantProvisioning`
(used by `insert_review/2`) — no new alias needed there either. `list_reviews/2`
needs `import Ecto.Query`'s `where/3`/`order_by/3`/`limit/2`, already imported at the
top of `promotion_review_store.ex`.

## 7. Test coverage design, mapped to REQ-397's 8 acceptance criteria

All tests live in `test/letflow/routers/promotions_test.exs` (extend the existing
file — new `describe "GET /promotions"` block) for the router-level/real-HTTP
criteria, and `test/letflow/definitions/promotion_review_store_test.exs` (extend,
new `describe "list_reviews/2"` block) for the context-function-level criteria that
don't need real-HTTP dispatch (e.g. cursor-boundary/keyset-correctness edge cases).
Both files already use `Letflow.DataCase, async: false` + `Letflow.TenantFixture` for
real provisioned-tenant Postgres schemas (§0) — reuse that setup, do not add mocks.

Fixture discipline (mirrors `promotion_review_store_test.exs`'s own rule, §0): every
non-`pending_review` row a test needs is reached by calling the **real** transition
function (`approve_review/4`, `reject_review/3`, `mark_review_applied/2`,
`mark_review_failed/2`, `supersede_review/3`) on a row created via
`insert_review_fixture!/3` (or an equivalent router-level `PromotionReviewStore.insert_review/2`
call for the router-test file) — never a hand-built `%PromotionReview{status: ...}`
struct or a raw `Repo.insert/2` bypassing `insert_changeset/2`'s "status is always
`:pending_review` on insert" rule (§0).

| # | AC | Test | File | Design notes |
|---|---|---|---|---|
| 1 | "an authenticated, PLATFORM_ADMIN-only `GET /api/v1/promotions` returns a paginated list of the caller's own tenant's `promotion_reviews` rows, most-recent first" | Real-HTTP dispatch (`Letflow.Routers.Promotions.call/2`, PLATFORM_ADMIN role) against a tenant with 3+ seeded rows inserted at distinct times; assert `response["items"]` is present, non-`Jason.Encoder`-shaped (exact key set from §4.5), and ordered by `inserted_at` DESC (assert the returned `id` sequence, not just length) | `promotions_test.exs` | Seed via `PromotionReviewStore.insert_review/2` three times with a real `PromotionDigest`-derived digest each (matching `insert_review_fixture!/3`'s own discipline); assert order via the returned `id`s, not by re-querying |
| 2 | "a caller from a different tenant's session sees only their own tenant's rows" | Provision two tenants (`TenantFixture.provisioned_tenant!/1` twice), seed distinct rows in each, dispatch as each tenant's PLATFORM_ADMIN caller (`auth_context.tenant_id` set to that tenant), assert tenant A's response `items` never contains any of tenant B's row ids and vice versa | `promotions_test.exs` | Mirrors R11's own cross-tenant test pattern in this same file (`build_conn/2`'s `tenant_fixture` param) |
| 3 | "filtering by a single status value ... returns only rows in that status" | Seed rows across 3+ distinct statuses (e.g. `pending_review`, `approved`, `rejected` — reached via real transitions per the fixture-discipline note above), dispatch `GET /promotions?status=rejected`, assert the response's row-id set exactly equals the seeded `rejected` row(s), no more, no fewer | `promotions_test.exs` | Also add a `status=approved,rejected` multi-value case in the same describe block, asserting the row set is the union — this is the one case AC3 doesn't literally require but description item 3 ("one or more") does; without it the multi-value path in §4.3 is unexercised |
| 4 | "an unrecognised status filter value is rejected with a 4xx response naming the allowed status values in plain language" | Dispatch `GET /promotions?status=bogus_value`, assert `400`, and assert the response body's message contains the literal substring `"pending_review"` (or asserts on the full string from §4.2's `Response.bad_request/2` call) — i.e. assert the *content* names the allowed set, not just the status code. Add a second case: `status=rejected,bogus_value` (one valid, one invalid) also 400, proving the whole filter is rejected, not silently reduced to the valid subset | `promotions_test.exs` | Matches `tasks.ex`'s own `"status must be one of PENDING..."` assertion style, adjusted for this route's lowercase enum values |
| 5 | "filtering by `def_id` returns only that definition's own reviews" | Seed rows across 2+ distinct `def_id` values (varying `process_key` across the `PromotionPlan` fixtures used to build each `insert_review/2` call, since `def_id` is stamped from `plan.process_key`), dispatch `GET /promotions?def_id=<value>`, assert the response's row-id set exactly equals that `def_id`'s seeded rows | `promotions_test.exs` | `def_id` is a plain string equality filter (§3.3) — no UUID-cast edge case to cover, unlike path-parameter review-id handling elsewhere in this router |
| 6 | "a caller without PLATFORM_ADMIN role receives the same `Deny403` this module's other routes already return" | Dispatch `GET /promotions` with `roles: []` (or a non-`PLATFORM_ADMIN` role) via `build_conn/2`'s existing `roles` override, assert `403` with the same body shape one of this file's existing R11 403 tests already asserts (byte-for-byte same problem-document shape — no new assertion helper needed, reuse the existing one) | `promotions_test.exs` | No new authorization code exists to exercise (§5) — this test proves the plain `get` macro placement didn't accidentally pick up a different/missing plug ordering, not new logic |
| — | Pagination correctness (not a named AC, but load-bearing for AC1's "paginated") | Seed `page_size + 1` rows (e.g. `page_size: 2`, 3 rows), dispatch first page, assert `next_cursor` is non-nil and `items` has exactly 2 entries; dispatch again with that `cursor`, assert the 3rd row is returned and `next_cursor` is `nil`; dispatch with a garbage `cursor` string, assert `400` "invalid cursor"; dispatch with a well-formed-but-wrong-endpoint cursor (e.g. one minted by `GET /promotions/platform-events`'s `"PE:"` prefix), assert `400` "cursor is not valid for this endpoint" | `promotions_test.exs` | Exercises §3.3's `"PR:"` prefix isolation directly — mint a `"PE:"` cursor via the existing R11 helpers already in this test file and feed it to the new route |
| — | `list_reviews/2` keyset/ordering edge cases (context-level, doesn't need real HTTP) | Two rows with the identical `inserted_at` (construct via two `insert_review/2` calls in the same test, asserting the DB-assigned `inserted_at` values collide or accepting near-collision is enough since the `id` DESC tiebreak is what's under test) — assert page-boundary determinism (no row skipped or duplicated across two consecutive page fetches) | `promotion_review_store_test.exs` | Confirms AC1's "ties broken by id for determinism" at the function level, independent of HTTP-layer concerns |
| 7 | "the design doc states and justifies the chosen pagination shape ... citing any existing list-endpoint convention found ... or stating explicitly that none was found" | N/A — satisfied by this document, §2 | — | §2 cites `Definitions.list_paginated/2`, `Instances.list/2`, and R11's own `handle_platform_events/1` as the found convention |
| 8 | "`mix compile --warnings-as-errors` and `mix test` both pass ... SECURITY-REVIEWER sign-off is required before merge" | N/A — ELIXIR-DEV/TEST-RUNNER responsibility at implementation time; SECURITY-REVIEWER gate stated explicitly in §5 | — | — |

## 8. Invariants this design preserves (restated, not new)

  * **INV-1 (tenant isolation).** Every row this route can ever return comes from one
    `Repo.all(query, prefix: prefix)` call scoped to `conn.assigns.scoped_opts`'s
    prefix — no second, unscoped query anywhere in `list_reviews/2` (§5).
  * **INV-5 (no cross-tenant/nonexistent distinguishability oracle).** Not directly
    applicable to a list route the way it is to R3–R7's single-id lookups (§5), but
    preserved by construction: an empty result set is the same shape regardless of
    *why* it's empty (wrong tenant, no matching filter, or genuinely zero rows).
  * **INV-8 (typed, non-raising results on caller-controlled input).** Every
    caller-controlled input (`status`, `page_size`, `cursor`, `def_id`, `def_type`)
    is validated before it reaches a query — `parse_status_filter_param/1` and
    `Pagination.parse_page_size_param/1`/`validate_page_size/1` never raise on
    malformed input, matching `Pagination`'s own moduledoc INV-8 statement.
  * **The allowlist statement (§0).** `promotion_review_list_item_map/1` is a
    hand-built 7-key map, never a struct/`Jason.Encoder` derivation (§4.5).
  * **The `:Unknown`-authorization decision (§0/§5).** No new policy key, no new
    permission, no widened access.

## 9. Open questions (do not silently resolve — ELIXIR-DEV/REVIEWER to weigh in)

  1. **§4.3's comma-separated `status` filter is a genuinely new sub-shape.**
     Flagged for REVIEWER explicitly (not silently adopted) — an alternative
     (`status[]=a&status[]=b` bracket-array syntax, or accepting the *first*
     `status=` occurrence only and requiring repeated calls for multi-status
     filtering) was available and rejected for the reasons in §4.3, but this is the
     first place in this codebase a list endpoint accepts more than one value for
     one filter key, so it is worth a second look rather than treated as
     settled by this document alone.
  2. **No `def_type` enum validation, unlike `status`.** This is deliberate (§3.3,
     mirroring the schema's own Open Question 1 — `def_type` is intentionally
     open-ended), but it does mean a typo'd `def_type` value (e.g. `"proccess"`)
     silently returns zero rows rather than a 4xx the way a typo'd `status` value
     does. Not resolved differently here because inventing a closed `def_type` enum
     is out of this requirement's scope and would contradict the schema's own stated
     open question.
  3. **`page_size` default/max reuse `Pagination`'s codebase-wide constants (50/200)**
     rather than a promotions-specific value — REQ-397 does not ask for anything
     different, and diverging without a stated reason would be a silent
     inconsistency with every other list endpoint. Flagged only so a future reader
     understands this was a considered default-reuse, not an oversight.
