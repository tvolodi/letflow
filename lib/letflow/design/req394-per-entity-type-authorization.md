# Design: per-`(user, entity_type)` record authorization, with denial indistinguishable from a genuinely empty type (REQ-394)

**Status:** design, pending CODE-DESIGN-VALIDATOR.
**Requirement:** REQ-394 (`docs/requirements.yaml`, letflow-queue task 754, GH-1642, stage S6).
**Filed from:** the GUI-review UAT run of
`test/fixtures/uat/scenarios/vortex/entity-list-filter-and-page.yaml` (PW-10) — see
`test/uat-reports/gui-review-2026-09-20-entity-list-filter-and-page.md`, EO-004.
**Security-relevant:** yes — new tenant-data-path authorization surface. SECURITY-REVIEWER
sign-off is mandatory before merge, per `docs/agents/instructions/security-invariants.md`
(§6 below).
**Depends on:** REQ-230, REQ-231 (`lib/letflow/design/req231-entity-query-cursor-field-grants.md`),
REQ-300, REQ-309 (`lib/letflow/api/authorization.ex`), REQ-311 — all `status: done`.
**Out of scope (per requirement text):** the frontend/admin screen that would let an
administrator author these per-type grants; REQ-393's filter/sort/page-size UI work.

## 0. What exists today (read in full before this design, not assumed)

- `Letflow.Routers.Entities` (`lib/letflow/routers/entities.ex`) gates `POST
  /entities/query` behind exactly one permission, `:EntitiesQuery`
  (`authz_post "/query", :EntitiesQuery do ... end`, line 316), and gates all three
  single-definition GET routes — `/definitions/active/:name`
  (`handle_get_active_definition_by_name/2`, line 778), `/definitions/by-name/:name`
  (`handle_get_definition_by_name/2`, line 787), `/definitions/:id`
  (`handle_get_definition/2`, line 803) — behind `:EntitiesDefinitionsRead`. Both
  permissions are route-level, coarse, and all-or-nothing across every entity type in the
  tenant (`Letflow.Api.Authorization`, REQ-309). There is no third, per-`(user,
  entity_type)` dimension anywhere in the authorization vocabulary today (grepped
  exhaustively per the requirement text).
- `Letflow.Entities.Query.FieldGrants` (`lib/letflow/entities/query/field_grants.ex`,
  REQ-231) is the one existing entity-scoped access-control primitive, and it operates one
  layer *below* the one this requirement needs: it redacts individual `field_values` keys
  within a record the caller can already see (`redact_page/2`, `redact_field_values/2`). It
  has no concept of denying an entire entity *type* — its own moduledoc states plainly that
  `Letflow.Api.Authorization` doesn't fit its purpose because "there is no third parameter
  through which 'which field' could reach `evaluate_access/2`"; the same structural gap
  applies one level up, to "which entity type," which is exactly what this requirement
  closes.
- `FieldGrants`' own **grant model** — default-allow, with an explicit
  `entity_field_restrictions` row switching a field to hidden, and a `user_entity_grants`
  row restoring it for one specific user — is reused verbatim by this design at the
  type level (§1). It is proven in production against exactly the same kind of
  tenant-schema table pair this design adds, and reusing its shape rather than inventing a
  new one is deliberate: the two mechanisms answer structurally identical questions
  ("is X visible to this user") at two different granularities (field vs. type), and having
  them diverge in default-allow/deny semantics would be a real inconsistency for a future
  reader to trip over.
- `Letflow.Entities.Query.Compiler.compile/2` (`lib/letflow/entities/query/compiler.ex`)
  returns `{:error, :entity_type_not_found}` when the request's `entity_type` has no
  `entity_definitions` row in the tenant at all. `Letflow.Routers.Entities`'
  `render_query_error/2` (line 2250) maps that to `Response.not_found/1` — a plain 404,
  distinguishable by status code alone from a genuinely-empty, existing type's
  `200 {"items": [], "next_cursor": null}` (`run_query/4`, line 1599-1611).
- The three definition-read routes' getters (`Letflow.Entities.Definitions`,
  `get_active_definition_by_name/2`, `get_definition_by_name/2`, `get_definition/2`) already
  return `{:error, :not_found}` for a genuinely nonexistent `name`/`id`, rendered as a plain
  404 by `render_get_definition/2` (line 813-817) — this part of INV-5's "not-found and
  cross-tenant are the same bytes" discipline is already in place for definitions reads and
  is **not** changed by this design; §3 below extends it, not replaces it.
- `Letflow.Entities.EntityDefinition` (`lib/letflow/entities/entity_definition.ex`) has a
  `:name` field — this is the same string every route/table in this subsystem calls
  `entity_type` (`Compiler.compile/2`'s `request.entity_type`, `FieldGrants`'
  `entity_type` argument, etc.). `definition.name` is what this design's checks key on
  when a definitions-read route only has a fetched `%EntityDefinition{}` in hand, not a
  caller-supplied `entity_type` string.
- `test/support/tenant_fixture.ex`'s tenant-schema table truncation list already includes
  `entity_field_restrictions`/`user_entity_grants` (lines 137, 164) — the two new tables
  this design adds (§1.2) must be added to that same list (implementation surface, §5).

## 1. New authorization layer: `Letflow.Entities.TypeAccess`

New module, `lib/letflow/entities/type_access.ex` — sibling to
`Letflow.Entities.Definitions`/`Letflow.Entities.Records`, not nested under `query/`,
since (unlike `FieldGrants`) it is consumed by both the query path (§2) and the
definitions-read path (§3), not the query engine alone.

### 1.1 Grant model — default-allow, explicit restriction, per-user override (mirrors FieldGrants §3.2)

An entity type with **no** `entity_type_restrictions` row is visible, for query and
definition-read purposes alike, to every user who holds the relevant coarse route-level
permission (`:EntitiesQuery`/`:EntitiesDefinitionsRead`) — this is what makes AC4
("an existing caller with only the coarse route-level permission and no per-type
restriction at all is completely unaffected") true by construction: a tenant that never
inserts a single `entity_type_restrictions` row observes zero behavior change from this
requirement.

A restricted entity type (a row exists in `entity_type_restrictions` naming it) is hidden
from every user **except** one holding a matching `user_entity_type_grants` row for
`(user_id, entity_type)`. Absence of that grant row is exactly that user's denial —
matching FieldGrants' own "a restricted field's absence from a given user's
`user_entity_grants` rows is exactly that user's redaction set" phrasing, one level up.

### 1.2 New tables (tenant-scoped, same placement/guard convention as `entity_field_restrictions`/`user_entity_grants`)

**`entity_type_restrictions`** — one row per restricted `entity_type`, tenant schema:

| column | type | constraints |
|---|---|---|
| `id` | `:binary_id` | primary key |
| `entity_type` | `:string, size: 255` | not null |
| `inserted_at` / `updated_at` | `:utc_datetime_usec` | `timestamps()` |

- Unique index on `entity_type` (name: `entity_type_restrictions_entity_type_idx`) — a type
  is either restricted or not, never "restricted twice."
- **No FK to `entity_definitions`** — same reasoning as `entity_field_restrictions`'s own
  migration comment: a restriction can be declared before (or after) an entity type's
  active definition version exists; this table is queried by string name, not by
  definition row, matching `Letflow.Entities.Query.Allowlist.load/2`'s own established
  convention.

**`user_entity_type_grants`** — one row per `(user_id, entity_type)` override that lifts a
matching restriction for exactly one user, tenant schema:

| column | type | constraints |
|---|---|---|
| `id` | `:binary_id` | primary key |
| `user_id` | `:binary_id` | `references(:users, on_delete: :nothing)`, not null |
| `entity_type` | `:string, size: 255` | not null |
| `inserted_at` | `:utc_datetime_usec` | `timestamps(updated_at: false)` |

- Unique index on `(user_id, entity_type)` (name:
  `user_entity_type_grants_user_id_entity_type_idx`).
- Migration files follow the existing `if prefix() do ... end` tenant-scoped guard exactly
  (`priv/repo/migrations/20260907010001_create_entity_field_restrictions.exs`/
  `..._create_user_entity_grants.exs` are the templates), and both new migrations' versions
  must be appended to `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`
  (§5) — both halves mandatory, per that module's own manifest comment. No SQL string in
  either migration interpolates tenant- or user-controlled data (INV-7) — both are fixed,
  migration-authored literals scoped only by the trusted `prefix()` value.
- **No `Ecto.Schema` module for either table** — same deliberate choice `FieldGrants` made
  for its own two tables (its moduledoc: "a future write-path requirement owns authoring
  these rows and can add schema modules then if it needs them"). This design's own scope is
  the read-side loader/checker only (§1.3); authoring rows happens the same way
  `entity_field_restrictions`/`user_entity_grants` rows are authored today — direct inserts
  from solution-pack seeding code (`lib/letflow/packs/bilimbaga.ex`,
  `lib/letflow/definitions/solution_pack.ex`) or test fixtures — until the
  out-of-scope admin-authoring requirement exists.

### 1.3 Read-side API

```
@type decision :: :allowed | :denied

@spec authorized?(user_id :: String.t(), entity_type :: String.t(), prefix :: String.t()) ::
        {:ok, decision()} | {:error, :invalid_schema_name}
```

Single public function. Validates `prefix` resolves to a real tenant the same way
`FieldGrants.load_restrictions/3` does (`TenantProvisioning.tenant_id_for_schema_name/1`),
then:

1. Looks up whether `entity_type_restrictions` has a row for `entity_type`. None → `{:ok, :allowed}`
   (default-allow, §1.1) — no second query needed.
2. A row exists → looks up whether `user_entity_type_grants` has a row for
   `(user_id, entity_type)`. Present → `{:ok, :allowed}`. Absent → `{:ok, :denied}`.

Both lookups can be expressed as the same anti-join shape `FieldGrants.load_restrictions/3`
already uses (a `left_join` from `entity_type_restrictions` to `user_entity_type_grants` on
`entity_type`+`user_id`, `where: is_nil(g.id)` for "restricted and not granted") collapsed
to a boolean via `Repo.exists?/2`, rather than the two-step description above — either
shape is acceptable to ELIXIR-DEV; this design fixes only the function's observable
`{:ok, :allowed | :denied}` contract, not its query plan.

`entity_type` here is always a caller-supplied or definition-resolved string, never
validated against `entity_definitions` by this function — `authorized?/3` answers "is this
user denied *if* this type is restricted," not "does this type exist." Existence is
resolved by the caller (§2, §3) exactly once, at the call site that already needs to know
it for its own reasons (`Compiler.compile/2`'s `entity_type_not_found`, or the definitions
getters' own `{:error, :not_found}`) — `TypeAccess` is deliberately **not** a second
existence oracle.

## 2. Query path — `POST /entities/query` (`handle_query/1` → `run_query/4`)

### 2.1 Where the check goes

`run_query/4`'s existing `with` chain (line 1599-1611) is extended by one clause, inserted
after `Compiler.compile/2` succeeds and before `Allowlist.load/2` runs:

```
with {:ok, request}  <- build_query_request(body),
     {:ok, opts}     <- build_paginate_opts(body),
     {:ok, compiled} <- Compiler.compile(request, prefix),
     {:ok, :allowed} <- TypeAccess.authorized?(user_id, request.entity_type, prefix),
     {:ok, allowlist} <- Allowlist.load(request.entity_type, prefix),
     {:ok, page}      <- Cursor.paginate(request, compiled, allowlist, opts, prefix),
     {:ok, redacted}  <- redact(page, request, user_id, prefix) do
  ...
else
  {:error, reason} -> render_query_error(conn, reason)
end
```

`{:ok, :denied}` does not match the `{:ok, :allowed}` pattern, so it falls into the `with`'s
implicit else as the bare value `{:ok, :denied}` — `render_query_error/2` gains a clause
matching that exact tuple (§2.2), distinct from its existing `{:error, _}` clauses.
`TypeAccess.authorized?/3` runs *after* `Compiler.compile/2` has already confirmed the type
exists, so it is only ever asked about a real entity type — exactly the "type exists but
this caller cannot see it" case, never a nonexistent one (§2.2 covers the nonexistent case
via `Compiler.compile/2`'s own pre-existing `entity_type_not_found` result, not via
`TypeAccess`).

**Flagged for ELIXIR-DEV:** this module's own moduledoc states
`test/letflow/entities/query_cursor_field_grants_test.exs` "extracts exactly this chain
(comments stripped) to assert its order" as four steps — inserting a fifth step here means
that test's own extraction needs updating to five steps. This is TEST-DESIGNER's job, named
here so it isn't missed, matching this file's own convention of flagging known-affected
call sites (see req391's §2.5 precedent).

### 2.2 Response — collapsing two error reasons into one shape

`render_query_error/2` gains two behavior changes, both producing the **identical**
response — `Response.ok(conn, %{"items" => [], "next_cursor" => nil})`, the same 200
envelope a genuinely-empty, authorized, zero-row query already produces
(`run_query/4`'s own success branch, `Response.ok(conn, %{"items" => Enum.map(redacted.items,
&query_item_map/1), "next_cursor" => redacted.next_cursor})` — with `redacted.items == []`
and `redacted.next_cursor == nil` for a zero-row page, `Cursor.paginate/5`'s own existing,
unchanged contract):

1. `render_query_error(conn, {:ok, :denied})` (the new `TypeAccess` denial, §2.1) →
   `Response.ok(conn, %{"items" => [], "next_cursor" => nil})`.
2. `render_query_error(conn, :entity_type_not_found)` — **existing clause, reason
   changed**. Today: `Response.not_found(conn)` (a 404). New: the same
   `Response.ok(conn, %{"items" => [], "next_cursor" => nil})` as (1). This is the AC3
   requirement made concrete — a nonexistent type and an existing-but-unauthorized type must
   be indistinguishable from each other, which is only possible if both collapse into the
   same branch as the genuinely-empty-and-authorized case, since that's the one response
   shape a caller who holds only `:EntitiesQuery` (the route-level permission, unaffected by
   this requirement) can legitimately expect to keep seeing today for a real, visible,
   zero-row type.

Both (1) and (2) are implemented as the same private helper (e.g.
`render_type_hidden(conn)`) so the two clauses cannot drift apart in body shape over time —
one function, two call sites, not two independently-maintained response-building blocks.

**This is a deliberate, named behavior change to already-shipped REQ-311 behavior:**
`:entity_type_not_found` stops being a 404 for `POST /entities/query`. Any existing test
asserting the old 404 for a nonexistent entity type on this route must be updated (not
"left unmodified") — this is expected and required by AC3, not an oversight; AC4's "full
existing test suite ... passes unmodified" is about tests *unaffected* by this requirement
(ordinary authorized-type/unrestricted-type coverage), not about this one, deliberately
changed, case. Flagged explicitly rather than left for TEST-DESIGNER to discover as an
unexplained regression.

## 3. Definitions-read paths — the three single-definition GET routes

`GET /definitions/active/:name`, `GET /definitions/by-name/:name`, `GET /definitions/:id`
each already resolve to `render_get_definition(conn, result)` (line 813-817), where
`result` is `{:ok, %EntityDefinition{}}` or `{:error, :not_found}` from the corresponding
`Letflow.Entities.Definitions` getter.

### 3.1 Where the check goes

`render_get_definition/2` gains a `user_id` argument (threaded from
`conn.assigns.auth_context.user_id`, the same source `handle_query/1` already uses) and an
additional check on its success clause only:

```
@spec render_get_definition(Plug.Conn.t(), user_id :: String.t(), result) :: Plug.Conn.t()
      when result: {:ok, EntityDefinition.t()} | {:error, :not_found | :invalid_schema_name}
```

- `{:ok, %EntityDefinition{name: name} = definition}` → call
  `TypeAccess.authorized?(user_id, name, prefix!(conn))`.
  - `{:ok, :allowed}` → unchanged: `Response.ok(conn, definition_map(definition))`.
  - `{:ok, :denied}` → renders **exactly** what the `{:error, :not_found}` clause below
    already renders: `Response.not_found(conn)`. Not a new response shape — the existing
    404 this route already produces for a genuinely nonexistent `name`/`id`.
- `{:error, :not_found}` → unchanged: `Response.not_found(conn)`.
- `{:error, _common_error}` → unchanged: `Response.internal_error(conn)`.

Each of the three call sites (`handle_get_active_definition_by_name/2`,
`handle_get_definition_by_name/2`, `handle_get_definition/2`) is updated to pass
`conn.assigns.auth_context.user_id` through to the now-4-arity `render_get_definition/3`
(the `conn` argument absorbs the arity bump the same way `run_query/4` already threads
`user_id` — no new plug/pipeline step, just one more argument at each of the three call
sites).

### 3.2 Why 404, not the query path's 200-empty shape

The two paths intentionally converge on **different** "hidden" response shapes, and this is
not an inconsistency — it is what each route's own pre-existing shape allows:

- The query route's own success shape for "nothing here" is `200` with an empty `items`
  array — that shape exists today, independent of this requirement, for a real, visible,
  zero-row type. Collapsing denial into it (§2.2) requires no new response shape at all.
- The definitions-read routes have no analogous "empty but visible" success shape — a
  single-definition GET either returns the definition or 404s; there is no "you may fetch
  this route, here is an empty object" precedent to reuse, and inventing one would be new
  surface this requirement doesn't need. The existing `{:error, :not_found}` 404 **already
  is** this subsystem's INV-5-consistent "nonexistent and hidden must look the same"
  answer, established before this requirement (§0) — this design reuses it rather than
  building a second one.

AC2's "must not be able to learn its FIELD SCHEMA either" is satisfied because the denied
branch never reaches `definition_map(definition)` — no field of the restricted definition
(including its schema) is serialized into the response at all, matching INV-2's "field
selection happens before serialisation" discipline.

### 3.3 `GET /entities/definitions` (plural, list route) — explicitly out of scope

`handle_list_definitions/1` (line 826) is **not** one of "the three definition-read
routes" this requirement's acceptance criteria name (AC2: "`GET
/entities/definitions/active/:name` (and its two sibling definition-read routes)" — three
total, matching §0's three getters). It lists every definition in the tenant regardless of
type-level restriction, unchanged by this design. This is named explicitly, not silently
assumed: a caller with `:EntitiesDefinitionsRead` and no per-type grants could still
enumerate a restricted type's `name`/`display_name` via this route even after this
requirement ships, which is a real, narrower gap than the one AC1-AC3 close for the three
single-definition routes. Flagged as an open question for SECURITY-REVIEWER (§8, OQ-1) —
this design does not extend `list_definitions/2`'s filtering, since doing so is not asked
for by any of REQ-394's six acceptance criteria and would need its own explicit page-level
redaction design (filtering *inside* a paginated cursor result is a different, cursor-aware
problem `Cursor.paginate/5` doesn't already solve for a "silently drop some rows"
semantics).

## 4. Interaction between the two coarse permissions and the new per-type layer

Stated explicitly, per the requirement text's own instruction that this not be left
implicit:

1. **The coarse route-level permissions are unchanged and still necessary.** A caller
   lacking `:EntitiesQuery` never reaches `handle_query/1`'s body at all (the `authz_post`
   macro denies with the existing 403 before any handler code runs) — same for
   `:EntitiesDefinitionsRead` and the three `authz_get` definition routes. `TypeAccess` is
   consulted only for a caller who has already cleared that gate. This is AC4's "additive,
   not a replacement" requirement made concrete: removing all `entity_type_restrictions`
   rows from a tenant returns it to exactly today's behavior, with the coarse permissions
   doing 100% of the gating, same as before this requirement.
2. **The two coarse permissions remain independent of each other**, exactly as today — this
   requirement does not make holding `:EntitiesQuery` imply `:EntitiesDefinitionsRead` or
   vice versa. What changes is that **both** routes, once past their own coarse gate, now
   consult the **same** `entity_type_restrictions`/`user_entity_type_grants` table pair,
   keyed identically (`entity_type`/`name`, same string space). This is what closes the gap
   the requirement text names explicitly: before this design, a caller could hold
   `:EntitiesDefinitionsRead` without `:EntitiesQuery` (or the reverse) and the two routes
   had no shared concept of "this specific type" to agree or disagree about. After this
   design, if a tenant restricts entity type `"invoice"` and grants user U access to it,
   that ONE grant governs U's access to `"invoice"` through **both** routes uniformly — U
   still needs the relevant coarse permission to reach either route at all, but once there,
   the per-type answer is the same fact, not two independently-configured ones.
3. **A caller can still hold one coarse permission and not the other** — that part of
   today's behavior is explicitly preserved, not resolved into "must hold both." A user
   with `:EntitiesDefinitionsRead` but not `:EntitiesQuery` can still read a
   type-authorized definition's schema but cannot query its records (403 at the route
   gate, unchanged); the reverse holds for `:EntitiesQuery` without
   `:EntitiesDefinitionsRead`. This design only adds a *third*, narrower gate common to
   both routes — it does not merge the two coarse permissions into one.

## 5. Summary of all touched/new files (implementation surface, not code)

| File | Change |
|---|---|
| `lib/letflow/entities/type_access.ex` | **New.** `Letflow.Entities.TypeAccess.authorized?/3` (§1.3). |
| `priv/repo/migrations/<ts>_create_entity_type_restrictions.exs` | **New.** Tenant-scoped, `if prefix() do` guard (§1.2). |
| `priv/repo/migrations/<ts>_create_user_entity_type_grants.exs` | **New.** Tenant-scoped, `if prefix() do` guard (§1.2). |
| `lib/letflow/tenant_provisioning.ex` | `@tenant_scoped_migration_manifest` gains both new migrations' entries (§1.2). |
| `lib/letflow/routers/entities.ex` | `run_query/4`'s `with` chain gains the `TypeAccess.authorized?/3` step (§2.1); `render_query_error/2` gains the `{:ok, :denied}` clause and changes the existing `:entity_type_not_found` clause (§2.2); `render_get_definition/2` becomes `/3` (adds `user_id`), gains the denial check on its success clause (§3.1); all three `handle_get_*` call sites updated to pass `user_id` through. |
| `test/support/tenant_fixture.ex` | Truncation-list additions: `entity_type_restrictions`, `user_entity_type_grants` (§0). |
| `test/letflow/entities/query_cursor_field_grants_test.exs` | Chain-order assertion updated from four steps to five (§2.1, flagged for TEST-DESIGNER). |
| Any existing test asserting `POST /entities/query` 404s on `:entity_type_not_found` | Updated to assert the new 200-empty shape instead (§2.2, flagged for TEST-DESIGNER). |

## 6. SECURITY-REVIEWER determination: REQUIRED

**Yes** — REQ-394 is filed explicitly as security-relevant (new tenant-data-path
authorization surface), matching this requirement's own routing instruction. Specific
points for SECURITY-REVIEWER's pass:

1. **INV-1 (tenant data isolation).** Both new tables are tenant-scoped (schema-per-tenant
   via `prefix()`, same placement as `entity_field_restrictions`/`user_entity_grants`), and
   `TypeAccess.authorized?/3` threads `prefix` the same way `FieldGrants.load_restrictions/3`
   already does — no new caller-supplied `tenant_id`/`prefix` field is introduced.
2. **INV-5-shaped guarantee, extended by this design, not yet formally in
   `security-invariants.md`'s own INV-5 text** (that section is currently written against
   cross-tenant lookups specifically, per its own "Reference: None yet" note) — this design
   asks SECURITY-REVIEWER to confirm the same "same bytes" discipline holds for
   same-tenant, per-type denial: §2.2's collapsed 200-empty response and §3.1's reuse of the
   existing 404 are both built to be byte-identical to their respective "genuinely doesn't
   apply" cases, and SECURITY-REVIEWER should verify no header (e.g. a distinct `ETag`,
   content-length quirk from key ordering, or a problem-document `detail` string that
   differs between the two 404 causes) leaks a distinguishing signal `render_query_error/2`/
   `render_get_definition/3`'s own Elixir-level branch structure doesn't already rule out.
3. **Timing side-channel — explicitly NOT resolved by this design, flagged, not silently
   accepted (§8 OQ-2).** The query path's `TypeAccess.authorized?/3` call only runs after
   `Compiler.compile/2` has already succeeded (§2.1) — so a nonexistent-type request never
   reaches `TypeAccess` at all, while an existing-but-restricted-type request does one
   additional DB round trip. The definitions-read path has the same asymmetry in reverse
   proportion (its `{:error, :not_found}` short-circuits before `TypeAccess` runs; its
   `{:ok, _}` branch always calls `TypeAccess`, denied or not, so the asymmetry there is
   "one extra query only on the exists branch," not on both a nonexistent and a
   restricted-but-existing branch as such). AC1-AC3's own wording ("byte-identical...
   status, body shape, headers") is a **response-content** guarantee, not a **constant-time**
   one, and this design meets exactly that; SECURITY-REVIEWER should make the explicit call
   on whether the residual timing signal is acceptable for this requirement's threat model
   or needs its own follow-up.
4. **INV-2 (server-side field authorization).** §3.2 confirms the denied branch never
   constructs `definition_map(definition)` — the restricted definition's fields never reach
   `Jason.encode!/1` for a denied caller, satisfying "an unauthorised field must never leave
   the server in the first place" one level up (a whole restricted *type*, not a field
   within a visible one).

## 7. Acceptance-criteria traceability

| # | Acceptance criterion (abridged) | Design section |
|---|---|---|
| 1 | Denied-type and genuinely-empty-type `POST /entities/query` responses byte-identical | §2.1 (single collapsed branch), §2.2 (shared response helper) |
| 2 | Same indistinguishability for the three single-definition GET routes | §3.1 (denial reuses the existing `:not_found` 404 render), §3.2 (why 404 is the right reused shape) |
| 3 | Nonexistent type and existing-but-unauthorized type indistinguishable, both route families | §2.2 (`:entity_type_not_found` and `{:ok, :denied}` collapse to the same query-path response), §3.1 (`{:error, :not_found}` and `{:ok, :denied}` collapse to the same definitions-path response) |
| 4 | Coarse-permission-only caller unaffected; full existing suite passes unmodified | §1.1 (default-allow grant model), §4 item 1 (coarse gate still required and unaffected when no restriction rows exist) |
| 5 | Design doc precedes implementation, CODE-DESIGN-VALIDATOR + SECURITY-REVIEWER sign-off | this document's own existence and status line; §6 (SECURITY-REVIEWER determination: REQUIRED) |
| 6 | `mix compile --warnings-as-errors` and `mix test` pass, real output quoted | Not a design-time artifact — evidence produced at STEP 2a/STEP 4 of WF-02 by ELIXIR-DEV/TEST-RUNNER against the concrete surface this design specifies (§1-§5); no design element is needed beyond making that surface compile-checkable, which every `@spec` above already is. |

## 8. Open questions (not silently resolved)

- **OQ-1 (§3.3):** `GET /entities/definitions` (the plural list route) is left unfiltered
  by this design — a caller with `:EntitiesDefinitionsRead` can still enumerate a
  restricted type's `name`/`display_name` (not its field schema) via that route. Flagged
  for SECURITY-REVIEWER: accept as a known, narrower residual gap (this requirement's six
  ACs don't name this route), or treat it as in-scope and route back to CODE-DESIGNER for a
  cursor-aware filtering design.
- **OQ-2 (§6.3):** the query-path/definitions-path timing asymmetry between an
  authorized-empty-or-restricted branch (one extra `TypeAccess` round trip) and a
  genuinely-nonexistent-type branch (zero extra round trips). This design treats AC1-AC3 as
  response-content guarantees only (their own wording), not constant-time guarantees, and
  does not add compensating-delay logic. Flagged for SECURITY-REVIEWER to confirm that
  reading or require a follow-up.
- **OQ-3 (§1.2):** no admin/API write path for `entity_type_restrictions`/
  `user_entity_type_grants` exists after this requirement ships — authoring is via direct
  insert (solution-pack seeding, test fixtures, or an ad hoc `Repo.insert_all/3` from an
  ops shell), the same posture `entity_field_restrictions`/`user_entity_grants` have had
  since REQ-231. This is explicitly named OUT OF SCOPE by the requirement text ("the
  frontend screen ... a future requirement"), restated here so it isn't mistaken for an
  oversight.
