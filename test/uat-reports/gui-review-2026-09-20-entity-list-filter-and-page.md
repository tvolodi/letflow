# GUI review: entity-list-filter-and-page (PW-10)

Date: 2026-09-20
Reviewer: ORCH
Scenario: `test/fixtures/uat/scenarios/vortex/entity-list-filter-and-page.yaml`
Severity class: high (field-level permission leakage over the wire, record-type
existence-indistinguishability) -- both flagged security-relevant per this pass's own
instructions.

## Path taken

Path 2: verified against current source (backend and frontend) that this scenario's
GUI-level steps cannot be executed today, for three independent reasons found by
reading, not assuming from the scenario's own stale NOTE (ISS-0526). No browser session
was driven against `qa.bizdala.com`, because there is no screen anywhere in `web/src/`
that exposes the controls (filter builder, sort direction, page-size input) this
scenario's steps need, for any tenant, and Vortex itself has no entity-definition
solution pack for a "batch" record to exist in the first place. This mirrors the
`attachment-cross-tenant-probe` finding earlier in this sweep: a real, carefully-built
backend mechanism with no reachable GUI surface.

Per this sweep's process ("if it genuinely doesn't exist: file it as a properly-sized
requirement, record BLOCKED in a review report, move on"), that is what follows below.
No code was changed. This is a docs-only branch (two new requirements plus this report).

## What was checked, and what each check showed

### 1. Backend entity-query engine (REQ-230/231/300/308/309/310/311, all `status: done`)

Read in full: `lib/letflow/entities/query/allowlist.ex`, `compiler.ex`, `cursor.ex`,
`field_grants.ex`, and `lib/letflow/routers/entities.ex`'s `POST /entities/query` route
end to end (`handle_query/1` -> `run_query/4` -> `build_query_request/1` ->
`Compiler.compile/2` -> `Allowlist.load/2` -> `Cursor.paginate/5` -> `redact/4`).

**Good news -- this is real, careful, and already unit-tested:**

- **EO-001 (correct filter/sort/no-dupes-no-gaps across pages):** `Allowlist.load/2`
  builds a per-entity-type, per-tenant field allowlist; `Compiler.compile/2` compiles
  filter/sort clauses into a parameterised `Ecto.Query`; `Cursor.paginate/5` implements a
  proper row-wise keyset cursor generalized to an arbitrary sort-clause list, with an
  implicit `record_id` tiebreaker appended to every query so a stable order is guaranteed
  even for a caller-supplied sort with ties. The mechanism is sound.
- **EO-002 (Karl never receives cost figures, not just a hidden-on-screen value):**
  `Letflow.Entities.Query.FieldGrants.redact_field_values/2` replaces (not merely masks)
  a restricted field's value with the atom sentinel `:__field_redacted__` before the page
  is ever serialised by `Response.ok/2`. `test/letflow/entities/query_cursor_field_grants_test.exs`
  (lines 468/502) asserts the sentinel is what a restricted caller's read actually
  contains. This is the correct mechanism for "absent from what he is shown, not merely
  blanked out" -- the real value never reaches `Jason.encode!/1` at all.
- **EO-003 (named rejection for a non-searchable field):** `Allowlist.resolve_field/2`
  returns `{:error, {:field_not_allowed, field_name}}` for any field absent from the
  loaded allowlist, which `render_query_error/2` (`lib/letflow/routers/entities.ex`
  ~line 2252) maps to a 422 naming the specific field. This is layer 2 of the module's
  own documented three-layer SQL-injection defence, doubling as the exact named-rejection
  EO-003 wants.
- **EO-005 (named refusal for an over-limit page size, no silent truncation):**
  `Pagination.validate_page_size/1`'s `{:error, :page_size_too_large}` is checked as the
  FIRST step of `Cursor.paginate/5`, before any query executes, and mapped to a 400 by
  `render_query_error/2`. No partial page is ever returned in its place.

None of this is a gap. If Vortex had a queryable "batch" entity type and a screen that
could reach this route with real filter/sort/page-size inputs, EO-001/002/003/005 would
very likely all PASS on the first try -- this module was clearly built and reviewed with
exactly these concerns in mind (see its own extensive moduledoc rework-history comments).

### 2. Frontend GUI surface -- the actual gap

Read `web/src/pages/entities/EntityCrudPage.tsx` (the only entity-list screen anywhere in
`web/src/`) and `web/src/components/ui/DataTable.tsx` in full.

- **No filter UI at all.** The only filter this screen ever sends is a compile-time
  constant, `EXCLUDE_DELETED_FILTERS = [{field: "deleted", op: "eq", value: false}]`.
  There is no control anywhere a user could use to add "status = quarantined AND
  supplier = Nordmetall" (step 1), let alone attempt a filter on a field that was never
  made searchable (step 3/EO-003).
- **No server-side sort.** `DataTable`'s `sortable`/`sortValue` props drive
  `@tanstack/react-table`'s `getSortedRowModel()` -- confirmed by reading
  `DataTable.tsx` lines 32-140 -- which sorts only the rows already fetched for the
  CURRENT page, client-side, in the browser. `EntityCrudPage.tsx`'s own
  `recordsQuery` query key/fn (lines 127-130) never includes a `sort` field in the
  `POST /entities/query` body. "Sort oldest-first, then page through every page in that
  order" (step 2/EO-001) is not achievable through this screen: each page's rows would
  be independently re-sorted in memory with no guaranteed relationship to the adjacent
  page's server-side order (which is itself undefined, since no `sort` is ever sent).
- **No page-size control.** `PAGE_SIZE = 25` (line 54) is a source constant. Nothing on
  this screen could trigger EO-005's refusal path.
- **This screen is BilimBaga-only by construction.** `web/src/config/bilimbagaEntities.ts`
  lists exactly ten entity types, all BilimBaga's; the route (`/admin/bilimbaga/:entityType`,
  `BilimBagaEntityRoute.tsx`) 404s for anything else. There is no Vortex-facing or
  generic entity-browse route anywhere.

### 3. Vortex tenant data -- the scenario's premise doesn't exist yet either

`priv/packs/` contains exactly one solution pack, `bilimbaga`. Grepped exhaustively for
`batch` under `priv/packs/`: zero hits. Vortex exists in this codebase only as a
BPM-process simulation/UAT fixture company (`test/fixtures/simulation/vortex/`,
`test/fixtures/uat/scenarios/vortex/`) -- its other scenarios
(`supplier-quality-deviation-critical/false-positive`) run through the workflow engine's
process-instance mechanism, not the entity-definition/CRUD subsystem this scenario
exercises. There is no "production batch" entity type provisioned for Vortex, or for any
tenant, to hold Nordmetall's quarantined batches. This is a separate, independent gap
from the frontend one above (the frontend gap blocks EVERY tenant equally; this one is
Vortex-specific data provisioning) -- filed as an out-of-scope note in REQ-393 rather
than a requirement of its own, since whether Vortex ever gets entity-backed batch
records is a product decision, not a bug.

### 4. EO-004's authorization premise -- does not exist as a mechanism at all (security finding)

Grepped `lib/letflow/` exhaustively for any per-entity-type authorization concept
(`entity_type` combined with `permission`/`access`/`grant`/`role`): the only hit is
`Letflow.Routers.Entities` itself, gated by exactly one permission, `:EntitiesQuery`
(REQ-309) -- coarse, route-level, all-or-nothing across every entity type a tenant has.
`FieldGrants` (checked above) redacts individual FIELDS within a record a caller can
already read; it has no concept of denying an entire entity TYPE to specific users while
another type stays visible to them. **A caller who holds `:EntitiesQuery` at all can
query every entity type that exists in their tenant; a caller who lacks it cannot query
any -- there is no middle state.** So "Karl can see quarantined-batch queries (steps
1/2) but not this other record type" describes a permission granularity this codebase
does not have.

Separately, and worth flagging on its own: `Compiler.compile/2`'s
`{:error, :entity_type_not_found}` (a type absent from the tenant's definitions
entirely) maps to a plain 404 (`render_query_error/2`, INV-5's "not-found and
cross-tenant are the same bytes" discipline) -- which is HTTP-status-distinguishable
from a genuinely-empty, EXISTING type's `200 {"items": [], "next_cursor": null}`. So
even the weaker "does this entity type exist at all" question is answerable today by
status code alone, for anyone who already holds `:EntitiesQuery`. This compounds the
missing per-type authorization gap: building EO-004 correctly means closing both -- the
denial for an unauthorized-but-real type, and the 404-vs-200-empty status-code oracle for
a genuinely nonexistent one -- on the SAME response shape.

Treated as security-severity per this pass's instructions and routed via a filed
requirement (REQ-394) that explicitly requires SECURITY-REVIEWER sign-off before any
implementation merges, rather than attempting a same-session fix -- this is new
authorization surface (a new access-control primitive, not a copy of an existing one),
not a small patch, and building it carelessly risks the exact kind of subtle
distinguishability bug this sweep already found elsewhere (ISS-0736/ISS-0737).

## Disposition

BLOCKED -- on three independent axes (no frontend filter/sort/page-size controls
anywhere, no Vortex entity data, no per-entity-type authorization mechanism), sitting on
top of a correctly-built and unit-tested backend query/redaction engine for the four
mechanisms (EO-001/002/003/005) that engine actually owns. Filed as two requirements,
following this sweep's own precedent of splitting frontend and backend/security scope
when they are independently buildable:

- **REQ-393** (FRONTEND-DEV) -- a generic, tenant-agnostic entity-list browse screen
  with a real filter builder, server-driven sort control, and page-size control, wired
  to the already-built `POST /entities/query` engine; writes and passes the permanent
  Playwright spec at this scenario's own `pipeline_test` path
  (`web/tests/e2e/pipelines/entity-list-query.pipeline.e2e.spec.ts`). Depends on
  REQ-230/231/300/311 (all done) and REQ-343 (done, the component it likely extends).
- **REQ-394** (ELIXIR-DEV, security-relevant -- SECURITY-REVIEWER sign-off required
  before merge) -- a new per-`(user, entity_type)` authorization layer making a denied
  entity type's `POST /entities/query` AND `GET /entities/definitions/active/:name`
  responses byte-identical to a genuinely-empty/genuinely-nonexistent type's, closing
  both the missing-granularity gap and the 404-vs-200-empty status-code oracle in one
  design. Depends on REQ-230/231/300/309/311 (all done).

Both requirements state explicitly, in their own "OUT OF SCOPE" sections, that they do
not duplicate each other's work and that REQ-393's stale-NOTE removal waits on BOTH
landing, since EO-004 needs REQ-394's mechanism, not just REQ-393's screen.

No SECURITY-REVIEWER referral was needed for *this* pass, since no code changed --
REQ-394's own acceptance criteria requires SECURITY-REVIEWER sign-off before its own
future implementation merges.

## Spec status

No permanent Playwright spec was written -- the feature it would exercise (a real
filter/sort/page-size-capable entity-list screen, for any tenant) does not exist yet.
The path is named in REQ-393's own acceptance criteria
(`web/tests/e2e/pipelines/entity-list-query.pipeline.e2e.spec.ts`), to be authored there
once REQ-393 ships. The scenario's own stale NOTE (ISS-0526-class forward reference) was
left in place, since the feature it warns about is still not real.
