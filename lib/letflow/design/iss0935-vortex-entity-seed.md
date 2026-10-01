# Design: ISS-0935 — Vortex `production_batch` entity-type + sample data seed

Status: draft, for CODE-DESIGN-VALIDATOR
Issue: `docs/issues/ISS-0935.yaml` (queue_ref `Q-918`; local filename authority is
`ISS-0935.yaml` per that file's own comment — the queue `issue_ref`/`ISS-0918` label
collides with an unrelated local file, same documented-collision pattern ISS-0897
and ISS-0893 already recorded; not re-litigated here).
Discovered by: UAT-RUNNER, `test/uat-reports/uat-2026-10-01-ISS0912-NARRATIVE.yaml`
(defect D6; `vortex/entity-list-filter-and-page` scenario BLOCKED,
`PRECONDITION_NOT_MET`).
Scenario this design must make runnable (API leg only — see Out of scope):
`test/fixtures/uat/scenarios/vortex/entity-list-filter-and-page.yaml`.
Related mechanism this design reuses, does not re-invent:
`lib/letflow/design/req394-per-entity-type-authorization.md` (REQ-394, implemented
and merged — `Letflow.Entities.TypeAccess`, `entity_type_restrictions` +
`user_entity_type_grants`), and REQ-231's `Letflow.Entities.Query.FieldGrants`
(`entity_field_restrictions` + `user_entity_grants`, field-level, already implemented).

ISSUE-FIXER's diagnosis (trusted, not re-derived here): this is a real content/code
gap. No entity-type schema or seed mechanism for any Vortex entity exists anywhere in
the repo today. `scripts/seed_vortex_definition.sh` seeds only two `ProcessDefinition`s
and contains zero entity-related logic. No sibling script
(`seed_meridian_definition.sh`, `seed_swiftroute_definition.sh`) has ever seeded an
entity type. Re-pointing the scenario at BilimBaga's `tag` entity (the only entity
type that exists in the repo today, `priv/modules/exam/entity_definitions/tag.json`)
is not a reasonable alternative — wrong tenant, wrong domain, and would require
rewriting the scenario's entire business premise (quality-manager-vs-cost-approver
batch quarantine investigation), which is explicitly out of scope per the issue text.

## 0. What exists today (read in full before this design)

- **Entity-definition document shape:** `Letflow.Entities.Definition` (REQ-225) —
  `t()` has `name`, `display_name`, optional `description`, required `fields`
  (list of `field_def()`), optional `indexes`, `foreign_keys`, `constraints`.
  `field_def()`: `name`, `type` (one of `:string | :integer | :decimal | :boolean |
  :date | :datetime | :enum | :json | :localized_text`), optional `required`,
  `queried` (boolean — this is the one flag that governs BOTH filter-allowlisting
  and sort-allowlisting, confirmed by reading
  `lib/letflow/entities/query/allowlist.ex` and `compiler.ex`: a field absent from
  the type's `queried: true` set is rejected by `Allowlist.resolve/2` with
  `{:error, {:field_not_allowed, field_name}}`, which names the exact field, not a
  generic "bad filter" message), `enum_values`, `decimal_precision`,
  `decimal_scale`, `default`, `locales`, `search_strategy` (`:plain | :fulltext`).
  No `min`/`max`/`check` attribute exists (confirmed in
  `priv/modules/exam/entity_definitions/README-constraints.md`) — out of scope for
  this fix, not needed by any acceptance criterion below.
- **Constraint shape:** `constraint_def()` accepts only `type: :unique` — no
  cross-field CHECK equivalent. Not needed here (no uniqueness/cross-field rule is
  part of this scenario).
- **Structural template:** `priv/modules/exam/entity_definitions/tag.json` (flat
  `{name, display_name, description, fields: [...], constraints: [...]}`, no array
  wrapper) is the shape this design's two new definition JSON documents follow.
  BilimBaga's richer siblings (`session.json`, `exam.json`) confirm `:date`/
  `:datetime` fields are declared exactly like any other field (`name`, `type`,
  `queried`), with no special date-sort attribute — sortability is just
  `queried: true` on a `:date`/`:datetime` field, same mechanism as filtering.
- **Field-level restriction (REQ-231, already implemented):**
  `Letflow.Entities.Query.FieldGrants` — tenant tables `entity_field_restrictions`
  (one row per restricted `(entity_type, field_name)`, default-deny-once-listed)
  and `user_entity_grants` (per-`(user_id, entity_type, field_name)` override that
  restores visibility for one user). Redaction replaces the field's value with a
  sentinel in the returned row; the field key itself is retained, never omitted.
  This is **per-user**, not per-role — there is no role-keyed grant table anywhere
  in this subsystem. "Restricted to the `cost_approver` role" is therefore modeled
  as: one `entity_field_restrictions` row for the cost field, plus one
  `user_entity_grants` row per individual user who plays the `cost_approver`
  persona in this scenario (`actor-vortex-anna`) — not a row for
  `actor-vortex-karl` (`quality_manager`). This is exactly the same translation
  req394's own design doc already had to make for "role" in its own worked
  reasoning (§1.1 of that doc), restated here for this scenario's two actors.
- **Type-level restriction (REQ-394, already implemented):**
  `Letflow.Entities.TypeAccess` — tenant tables `entity_type_restrictions` (one row
  per restricted `entity_type`) and `user_entity_type_grants` (per-`(user_id,
  entity_type)` override). A restricted type with no grant for a given user is
  indistinguishable, for that user, from a genuinely empty type on both
  `POST /entities/query` (collapsed to `200 {"items": [], "next_cursor": null}`)
  and the three single-definition `GET` routes (collapsed to the existing `404`).
  This is exactly EO-004's mechanism — reused verbatim, no new authorization
  surface invented.
- **Routes used by the seed script:** `POST /entities/definitions` (create,
  `:EntitiesDefinitionsWrite`) then `POST /entities/definitions/:name/activate`
  (activate) — same two-step DRAFT→ACTIVE lifecycle
  `seed_vortex_definition.sh` already uses for `ProcessDefinition`s, confirmed by
  reading `lib/letflow/routers/entities.ex` lines ~244-253.
  `POST /entities/records/:entity_type/import` (`:EntitiesRecordsImport`) is the
  bulk record-creation route — confirmed capped at 200 records per call
  (`handle_import_records/2`'s own documented check ordering: the 200-record cap,
  then schema-version gate, then path/body `entity_type` match, each before any
  `create_record/2` call). This design's sample-record count (§3) stays under that
  cap in a single import call; if a later record count needs more, the seed script
  chunks into multiple `import` calls of ≤200 each — noted as a forward-compatible
  detail, not required at today's count. A fourth route, `POST
  /entities/restrictions/import`, is new as of this design (§1.3) — no existing
  route covers the four restriction tables, confirmed by grepping every handler
  in this router for references to `entity_field_restrictions`/
  `user_entity_grants`/`entity_type_restrictions`/`user_entity_type_grants`
  outside `FieldGrants`/`TypeAccess`'s own read-side loaders.
- **Pagination defaults:** `Letflow.Api.Pagination` — `@default_page_size 50`,
  `@max_page_size 200`, `@min_page_size 1`. The scenario's precondition ("enough
  quarantined Nordmetall batches to exceed one page") is satisfied by exceeding 50
  (the default page size the scenario's steps use — no explicit `page_size` is
  passed in steps 1/2/6), not 200 (the max, which is what step 4 pushes past for
  EO-005 — already-implemented behavior, not something this design needs to add).
- **Seed-script convention:** `scripts/seed_vortex_definition.sh` +
  `scripts/lib/seed_service_task_base.sh` — `set -euo pipefail`; required
  `QA_AUTH_TOKEN`; default `QA_URL=https://qa.bizdala.com`; per-unit idempotency via
  a pre-check GET, skip-if-already-current, `curl -sf` with explicit `ERROR:` exit
  on failure, final human-readable summary block. No existing script seeds
  entity types or records — this design's script extension is new content
  following that same shape, not a diverging convention.

## 1. New entity-type definition: `production_batch` (Vortex tenant)

File: `test/fixtures/qa/vortex_production_batch_entity_definition.json` (same
directory/naming convention as the two existing `vortex_*_process_definition.json`
fixtures the existing seed script already reads from).

**`name`:** `production_batch`. **`display_name`:** `Production Batch`.
**`description`:** states this is seed content for ISS-0935 / the
`entity-list-filter-and-page` UAT scenario, names the acceptance criteria it backs
(EO-001 through EO-005), and names this design doc — matching
`tag.json`'s own convention of a provenance/rationale description rather than a
bare label.

### 1.1 Field list

| field | type | `queried` | `required` | purpose |
|---|---|---|---|---|
| `batch_ref` | `:string` | `true` | `true` | the batch's own business identifier (e.g. `B-2026-0147`); not strictly required by any EO but necessary for the scenario's own "batches on each page" evidence (screenshots must name a batch) and for the sample-record set (§3) to have a human-legible key. |
| `supplier` | `:string` | `true` | `true` | step 1's `supplier: Nordmetall` filter target. Plain `:string`, not `:enum` — the scenario's own preconditions describe "several suppliers" as free text, and an open supplier list is the more realistic domain shape (new suppliers are onboarded without a schema migration). |
| `status` | `:enum` | `true` | `true` | step 1's `status: quarantined` filter target. `enum_values`: `["pending_review", "quarantined", "released", "rejected"]` — `quarantined` is the value the scenario exercises; the other three exist so the sample set (§3) can include non-quarantined batches that step 1's filter must correctly exclude (part of EO-001's "nothing else" requirement — a filter that happens to return everything because there's nothing to exclude would not actually prove the filter works). |
| `deviation_raised_at` | `:date` | `true` | `false` | step 2's sort target ("the date the deviation was raised, oldest first"). `:date`, not `:datetime` — the scenario only ever speaks of a date, and `README-constraints.md`'s own recorded UTC-truncation caveat for `:datetime` is avoided entirely by not needing time-of-day precision here. `required: false` because a batch with no deviation yet (e.g. `pending_review`) may have no raised-at date — the sample set's non-quarantined rows exercise this. |
| `cost_figure` | `:decimal` | `false` | `false` | the cost-approver-only figure (EO-002). `decimal_precision: 12`, `decimal_scale: 2`. `queried: false` deliberately — this field is not part of the scenario's filter/sort story at all, and leaving it query-ineligible is an extra (not load-bearing) layer on top of the real access-control mechanism, which is the field-grant restriction below (§1.2), not `queried`. **Do not rely on `queried: false` alone for EO-002** — a field that is merely non-queryable is still returned in `field_values` for every record a caller can see; the actual "Karl never sees it, not even redacted-but-present" guarantee comes from the `entity_field_restrictions` row (§1.2), which replaces the value with `FieldGrants`'s sentinel rather than ever exposing the figure. |
| `internal_notes` | `:string` | `false` | `false` | **this is EO-003's field** — "a detail Vortex records on each batch but has never made searchable." `queried: false` is the entire mechanism: `Allowlist.resolve/2` rejects any filter clause naming `internal_notes` with `{:error, {:field_not_allowed, "internal_notes"}}`, which `Letflow.Routers.Entities`'s query-error rendering surfaces as a problem-document naming the field by name — satisfying EO-003's "names the specific detail" requirement directly, with no new code. |

No `indexes`, `foreign_keys`, or `constraints` entries — nothing in the scenario
needs a uniqueness rule or a cross-entity reference, and inventing one would be
unrequested surface.

### 1.2 Field-level restriction rows (cost-approver-only `cost_figure`)

Not part of the entity-definition JSON itself — these are two tenant-schema table
rows the seed script inserts after the definition is created, same table pair
REQ-231 already ships. **Mechanism decided below in §1.3** (resolves what was
OQ-1 in the FAILed draft): a new admin HTTP route, not a direct-DB-write path.

- One `entity_field_restrictions` row: `entity_type = "production_batch"`,
  `field_name = "cost_figure"`. This makes `cost_figure` invisible (sentinel-valued)
  to every user in the tenant by default.
- One `user_entity_grants` row: `(user_id = <actor-vortex-anna's user id>,
  entity_type = "production_batch", field_name = "cost_figure")`. This is the
  override that restores `cost_figure` for Anna (the scenario's `cost_approver`)
  only. No grant row is created for `actor-vortex-karl` — his `quality_manager`
  persona stays on the default-deny side, which is exactly EO-002's requirement.

### 1.3 Write-path decision: new admin HTTP route (not a direct-DB-credential path)

**This is a genuine new-authorization-surface decision, made explicitly here, not
deferred to ELIXIR-DEV.** Both options were weighed against how the existing
`scripts/seed_*.sh` family actually authenticates, re-read for this revision:

- **What the family already does, confirmed by re-reading
  `scripts/seed_swiftroute_persona_actors.sh` in full:** every script in this
  family — including ones that write rows far more sensitive than a seed
  fixture (role groups, `tenant_role` bindings, group memberships) — operates
  as an ordinary authenticated HTTP actor holding a `QA_AUTH_TOKEN` bearer
  token, scoped by whatever permissions that token's underlying user has been
  granted. `seed_swiftroute_persona_actors.sh`'s own header states its
  requirement plainly: *"QA_AUTH_TOKEN: Bearer token for a PLATFORM_ADMIN user
  in the swiftroute tenant. Must grant GroupsManage + RolesManage +
  UsersManage."* There is **no second credential tier** anywhere in this
  family — no script connects to Postgres directly, no script reads a DB
  connection string/password, and no script holds any credential other than an
  HTTP bearer token. The trust model the whole family already assumes is: "a
  human operator supplies a bearer token for a sufficiently-privileged platform
  user; the script never touches infrastructure below the HTTP API."
- **Therefore (a), a new admin HTTP route, is the only option consistent with
  that existing trust model** — it extends the same bearer-token-with-elevated-
  permissions pattern `seed_swiftroute_persona_actors.sh` already uses for
  `GroupsManage`/`RolesManage`/`UsersManage`, rather than inventing a wholly new
  credential class.
- **(b), a direct-DB-credential path, is ruled out, not left open.** It would
  introduce a brand-new credential type (`QA_DB_URL`/a Postgres connection
  string or password) that is categorically more dangerous than
  `QA_AUTH_TOKEN`: a bearer token is scoped to one user's existing permission
  grants, is revocable via Keycloak/identity without a deploy, and is rejected
  by every one of this codebase's existing authorization/row-scoping
  invariants (tenant-prefix isolation included) the same way any other HTTP
  call is. A raw Postgres credential bypasses the tenant-schema-prefix
  isolation mechanism entirely (nothing stops a script holding it from writing
  into the wrong tenant's schema by typo) and bypasses `Letflow.Api.Authorization`
  altogether — there is no row-level audit trail of "which actor inserted this
  restriction row" the way an HTTP-route audit log would have. No existing
  script needs this credential type today, and introducing it for a seed
  fixture is a disproportionate, precedent-setting trust-boundary expansion
  for what REQ-231/REQ-394 themselves call "a future write-path requirement."
- **Third option considered and ruled out:** no existing bulk-import mechanism
  already covers restriction rows. `POST /entities/records/:entity_type/import`
  (REQ-320) is scoped to *entity records* (rows in the entity's own data
  table) — its request/response shape, its 200-row cap, and
  `handle_import_records/2`'s validation ordering all assume a `field_values`
  payload against an active `Definition`, not a restriction-table row. There is
  no generic "admin bulk entity restriction import" concept anywhere in the
  repo (confirmed: no other handler references `entity_field_restrictions`,
  `user_entity_grants`, `entity_type_restrictions`, or `user_entity_type_grants`
  outside `FieldGrants`/`TypeAccess`'s own read-side loaders and
  `Letflow.Modules.Exam.on_install/2`'s in-process install transaction, which
  is unreachable from an external script). No existing admin route is an
  analog this design can reuse as-is; a new route is required either way.

**Decision: a new admin HTTP route, specified below, is this design's write
path for all four restriction tables.**

#### New route: `POST /entities/restrictions/import`

- **Router:** `lib/letflow/routers/entities.ex` — same router as
  `FieldGrants`/`TypeAccess`'s own consumers (`run_query/4`,
  `render_get_definition/3`) and the existing restriction-table read-side
  loaders; this keeps all four restriction tables' only write path colocated
  with their only read path, rather than splitting the resource across two
  router modules. Declared alongside the other record/definition write routes
  (§"Definition write routes"/"Record command routes" sections of that file),
  using the same `authz_post` macro every other route in this file uses.
- **Permission:** a new route-level permission, `:EntitiesRestrictionsManage`,
  added to `Letflow.Api.Authorization`'s `@permissions` list (currently ending
  `:ModulesManage, :MyModulesRead` — this is appended as entry thirty-five,
  with a doc-comment addition to `core_permissions/0`'s moduledoc listing it
  under a new "REQ/ISS-0935" line, matching that moduledoc's existing
  one-line-per-grant convention). **Justification for minting a new permission
  rather than reusing `:EntitiesDefinitionsWrite`:** authoring a restriction
  row is a materially different capability from authoring a definition's
  schema — a caller who can create/activate entity-type definitions has no
  inherent need to also be able to hide an entity type or a field from other
  users tenant-wide, and REQ-394/REQ-231's own "no write path exists yet"
  framing treated this as its own future capability, not a sub-case of
  `EntitiesDefinitionsWrite`. Reusing an existing permission here would
  silently widen what every current `EntitiesDefinitionsWrite`-holder can do,
  which this design does not do without an explicit decision — this is that
  decision, made in favor of a new, narrowly-scoped permission.
- **Request body:** a JSON object with up to four arrays, each optional
  (absent array = "insert nothing for this table" — not an error):
  `field_restrictions` (list of `%{entity_type: String.t(), field_name: String.t()}`),
  `field_grants` (list of `%{user_id: String.t(), entity_type: String.t(), field_name: String.t()}`),
  `type_restrictions` (list of `%{entity_type: String.t()}`),
  `type_grants` (list of `%{user_id: String.t(), entity_type: String.t()}`).
  Every row is an upsert against that table's existing unique index
  (`entity_field_restrictions`/`entity_type_restrictions` on the restricted
  name; `user_entity_grants`/`user_entity_type_grants` on the
  `(user_id, entity_type[, field_name])` tuple), via
  `Repo.insert_all(..., on_conflict: :nothing)` per table — matching §4.2's
  already-sound idempotency convention, carried forward unchanged, just moved
  behind this route instead of a hypothetical direct DB call.
- **Response:** `200 {"inserted": %{"field_restrictions" => n, "field_grants" => n,
  "type_restrictions" => n, "type_grants" => n}}` — counts of rows actually
  inserted per table (an `ON CONFLICT DO NOTHING` row that matched an existing
  row is not counted, so a second identical call reports all-zero counts,
  giving the seed script's final summary block a true idempotency signal, not
  just "200 OK" either way). `422` for a row naming a `user_id` that does not
  resolve to a user in the tenant, or an `entity_type`/`field_name` that is not
  a non-empty string (no existence check against `entity_definitions` is
  performed — same "not an existence oracle" posture `TypeAccess`'s own
  moduledoc already states for its read side, consistent rather than
  divergent). `403` for a caller lacking `:EntitiesRestrictionsManage`.
- **Handler module:** a new `Letflow.Entities.Restrictions` context module
  (sibling of `Letflow.Entities.TypeAccess`, under `lib/letflow/entities/`, not
  nested under `query/` — same placement reasoning `TypeAccess`'s own
  moduledoc already gives: this writes rows consumed by both the query path
  and the definitions-read path, not the query engine alone) exposing one
  function, `import_restrictions/2` (`attrs :: map(), prefix :: String.t()`),
  doing the four `insert_all` calls and returning the per-table counts. This
  is the one new context module this design adds; `FieldGrants`/`TypeAccess`
  themselves stay read-only and unmodified, per REQ-231/REQ-394's own stated
  "future write-path requirement" framing — this design is that future
  requirement's write side, scoped narrowly to bulk-import for seed/fixture
  use, not a full CRUD/listing API for these tables (no `GET`/`DELETE` route is
  added — not needed by any acceptance criterion below, and REQ-394's own
  OQ-3/REQ-231's own OQ-3 remain correctly the place a fuller admin-authoring
  API would eventually be designed).

## 2. Second entity type Karl has zero grant on (EO-004)

File: `test/fixtures/qa/vortex_shipment_manifest_entity_definition.json`.

**`name`:** `shipment_manifest`. **`display_name`:** `Shipment Manifest`. Chosen
because it is a plausible, distinct Vortex record type (outbound shipment
paperwork) that a quality manager has no operational reason to touch, making the
restriction's business rationale self-evident rather than arbitrary.

### 2.1 Field list

A minimal, realistic shape — this type's own fields are never exercised by the
scenario (step 5 only checks that the list looks empty, never that specific fields
exist), so a small field list is correct, not under-specified:

| field | type | `queried` | `required` |
|---|---|---|---|
| `manifest_ref` | `:string` | `true` | `true` |
| `destination` | `:string` | `true` | `true` |
| `shipped_at` | `:date` | `true` | `false` |

### 2.2 Type-level restriction rows (EO-004)

- One `entity_type_restrictions` row: `entity_type = "shipment_manifest"`. This
  hides the type from every user by default, for both `POST /entities/query` (200
  empty-page response, byte-identical to a genuinely empty type) and the
  single-definition `GET` routes (404, byte-identical to a genuinely nonexistent
  type) — `Letflow.Entities.TypeAccess`'s existing, already-shipped behavior.
- **No `user_entity_type_grants` row for `actor-vortex-karl`** — this is the
  entire mechanism; his absence from that table for this `entity_type` is his
  denial (REQ-394 §1.1's "absence of that grant row is exactly that user's
  denial").
- No grant row for Anna either, deliberately — EO-004 only requires that Karl's
  view be indistinguishable from empty; nothing in the scenario asks whether Anna
  (or anyone) can see `shipment_manifest`, so this design does not manufacture an
  unrequested differential for her. If a later requirement wants to demonstrate
  that *someone* can see it (to contrast with Karl), that is a new, separate
  scenario addition, not something this fix should smuggle in.
- At least a few `shipment_manifest` sample records should still be created (§3.3)
  — this is deliberate: it is what makes EO-004 a real redaction check (a
  restricted type whose denial is observable against *known-to-exist* data)
  rather than a vacuous one (a type nobody seeded would look identical whether
  or not `TypeAccess` was working at all).
- **OQ-2 resolved: no third entity type is added.** EO-004's "compared
  directly against a genuinely empty record type" comparison point is already
  fully supplied by `production_batch` itself, filtered to a supplier with no
  matches (e.g. `supplier: "Orkney Metals"`, a value never used by any seeded
  record, §3.1) — this is a genuinely empty *query result* on a type that
  genuinely has records, which is exactly the shape `POST /entities/query`
  already collapses an existence-denied type to (`200 {"items": [],
  "next_cursor": null}`, §0's "Type-level restriction" note). A third,
  always-empty, unrestricted entity type would add zero additional
  distinguishing power: it would produce byte-identical `{"items": [],
  "next_cursor": null}` output to both (a) `shipment_manifest` as Karl
  (denied) and (b) `production_batch` filtered to a nonexistent supplier
  (genuinely empty) — the very fact these three cases are indistinguishable
  at the API-response level is the mechanism itself (§0), not a gap a fourth
  entity type would close. UAT-RUNNER's EO-004 verification step therefore
  compares Karl's `shipment_manifest` query response against a
  `production_batch` no-match-supplier query response (both actors), rather
  than against a dedicated empty type. No new fixture is required for this.

## 3. Sample record set

Created via one (or more, chunked at ≤200 per the import cap, §0) call to
`POST /entities/records/production_batch/import` and one to
`POST /entities/records/shipment_manifest/import`, payload file(s) under
`test/fixtures/qa/` alongside the two definition fixtures.

### 3.1 `production_batch` records

- **60 records with `supplier: "Nordmetall"` and `status: "quarantined"`** —
  comfortably exceeds the 50-row default page size (§0), so step 2's "page forward
  through every page to the end" exercises at least two full pages plus a partial
  third, giving EO-001's "no batch appears twice or is missing" real paging
  behavior to verify (a count of exactly 51 would technically exceed one page but
  leaves no margin for an off-by-one in either the fixture or a future page-size
  default change; 60 is deliberately comfortable). Each row's `deviation_raised_at`
  is a distinct date (spread across a plausible few-month range) so step 2's
  oldest-first sort has a real, checkable total order — no two rows share a date.
  Each row's `batch_ref` is unique and sequential (e.g. `B-NM-001`..`B-NM-060`) so
  UAT-RUNNER's "batches seen across every page" evidence can name exact expected
  refs in order.
- **A second supplier's quarantined batches** — e.g. 8 records with
  `supplier: "Baltic Alloys"`, `status: "quarantined"` — so step 1's filter must
  actually exclude same-status, different-supplier rows (not just same-supplier,
  different-status ones) to be a real test of the filter's `supplier` clause, not
  only its `status` clause.
- **A handful of Nordmetall batches in OTHER statuses** — e.g. 5 records each of
  `pending_review`, `released`, `rejected`, all `supplier: "Nordmetall"` — so
  step 1's filter must also exclude same-supplier, different-status rows. These
  rows may omit `deviation_raised_at` (field is optional) for the non-quarantined
  ones where that is realistic (e.g. `released`/`rejected` batches that were never
  flagged).
- Every record, quarantined-Nordmetall or not, carries a `cost_figure` value and
  may carry `internal_notes` text — both present in the underlying data for every
  row is what makes EO-002/EO-003 meaningful (if `cost_figure` were only populated
  on the rows Karl's scenario touches, "Karl never sees it" would be a weaker,
  accidentally-true-anyway claim rather than a real redaction check).
- Total `production_batch` sample count: 60 + 8 + 15 = 83 records — one
  `import` call (under the 200-row cap).

### 3.2 `shipment_manifest` records

A small number (e.g. 10) of realistic rows — count doesn't matter for EO-004
(Karl must see zero regardless of how many exist), but a non-trivial sample set
makes the restriction's effect legible to anyone inspecting QA data directly
(a restricted type with zero underlying rows would look identical to one nobody
ever bothered seeding, which is a weaker demonstration of the access-control
mechanism actually working).

### 3.3 Seed-side idempotency for records

Unlike `ProcessDefinition`s (versioned, replace-if-older), records have no
natural version to compare. This design's seed-script extension (§4) uses the
same `idempotency_key` mechanism `handle_create_record/2`'s command_attrs already
support (confirmed in `lib/letflow/routers/entities.ex`'s
`handle_create_record/2`) — each sample record's fixture entry carries a stable,
deterministic `idempotency_key` (e.g. derived from `batch_ref`/`manifest_ref`), so
re-running the seed script against an already-seeded QA instance does not create
duplicate rows. **Flagged for ELIXIR-DEV**: confirm `POST
/entities/records/:entity_type/import`'s bulk path honors per-item
`idempotency_key` the same way the single-record `POST /entities/records/:entity_type`
route does (read `handle_import_records/2` in full) — if the bulk import path does
not thread `idempotency_key` through to `Records.create_record/2` per item, the
seed script must instead do its own pre-check (e.g. a `POST /entities/query`
against `batch_ref`/`manifest_ref` before importing) to stay idempotent, matching
the existing scripts' "skip if already present" convention.

## 4. Seed-script extension

New script: `scripts/seed_vortex_entities.sh` (sibling to
`seed_vortex_definition.sh`, not folded into it — a different resource type
`POST /entities/definitions` + `POST /entities/records/.../import` vs. the existing
script's `POST /definitions` + `.../activate`, and ISS-0897's own design precedent
treats each resource family as its own script rather than widening one script's
scope). Same preamble conventions as `seed_vortex_definition.sh`: `set -euo
pipefail`, `QA_URL` default, required `QA_AUTH_TOKEN` (must carry
`:EntitiesDefinitionsWrite` (covers both create and activate),
`:EntitiesRecordsImport`, and `:EntitiesRestrictionsManage` (§1.3) in the
vortex tenant — stated explicitly in the script's own header comment, same
style `seed_swiftroute_persona_actors.sh` documents its own
GroupsManage+RolesManage+UsersManage requirement), sourced `scripts/lib/`
helpers where they apply.

### 4.1 Definition-seeding function (per entity type)

Mirrors `seed_definition()`'s shape in `seed_vortex_definition.sh`, adapted to the
entity-definitions resource:

1. `GET /entities/definitions/by-name/:name` (or `/active/:name`) — if a
   definition with this `name` already exists, the script skips unconditionally;
   it never attempts to update. **OQ-4 resolved: "exists → skip, never update"
   is this design's rule, not a placeholder pending an update path.**
   `Letflow.Entities.Definition.t()` has no `version` field (§0) and no route in
   `lib/letflow/routers/entities.ex` supports replacing an existing ACTIVE
   definition's field list in place (the only definition write routes are
   `POST /definitions` (create) and `POST /definitions/:name/activate` —
   confirmed by re-reading the full route list in §0; there is no `PUT`/`PATCH`
   on `/definitions/:id` or `:name`). This design does not ask ELIXIR-DEV to go
   looking for an update path that the route list already shows does not exist,
   and it does not ask for one to be built — no acceptance criterion below
   needs updating an existing `production_batch`/`shipment_manifest` definition
   in place. The consequence this rule accepts, stated explicitly rather than
   left implicit: if a later change needs a different field list for either
   type, that is a deliberately-named new entity type (e.g.
   `production_batch_v2`) or a manual one-off migration, never a silent
   re-run of this script — exactly the same posture `ProcessDefinition`
   seeding already has for a changed definition (§0's "bump before re-seeding,
   never delete" convention, §4.1 item 3), just without the version-bump step
   since entity definitions have no version number to bump.
2. Missing → `POST /entities/definitions` with the fixture JSON body, then
   `POST /entities/definitions/:name/activate` (mirroring the existing script's
   create-then-activate two-step). Echo the created definition's name and a
   browse-able reference, same final-summary convention.
3. A `409` on create means the (tenant, name) pair already exists in some
   non-active state — same "bump before re-seeding, never delete" rule the
   existing script states for `ProcessDefinition`s, restated here for entity
   definitions. Any failure exits the whole script (`set -euo pipefail`, same as
   today).

Called twice: once for `production_batch`, once for `shipment_manifest`.

### 4.2 Field-restriction-row seeding (§1.2, §2.2, §1.3)

Uses the new `POST /entities/restrictions/import` route (§1.3) — a plain `curl`
call like every other step in this script family, not a special case:

1. Resolves `actor-vortex-anna`'s and `actor-vortex-karl`'s `user_id`s via the
   same `lookup_user_id()`-shaped helper `seed_swiftroute_persona_actors.sh`
   already defines (`GET /api/v1/identity/users?search=<username>`, abort with
   a clear `ERROR:` if empty) — reused directly, not reinvented, since this
   script's `QA_AUTH_TOKEN` must already carry enough identity-read permission
   for this lookup (stated in the script's own header, same as every other
   script in this family states its required permission set).
2. One `POST /entities/restrictions/import` call with all four rows in a
   single request body: `field_restrictions: [{entity_type: "production_batch",
   field_name: "cost_figure"}]`, `field_grants: [{user_id: <anna's id>,
   entity_type: "production_batch", field_name: "cost_figure"}]`,
   `type_restrictions: [{entity_type: "shipment_manifest"}]`, `type_grants: []`
   (no row for Karl — his denial is the absence, §2.2). `QA_AUTH_TOKEN` must
   additionally carry `:EntitiesRestrictionsManage` for this call to succeed —
   stated in the script's own header comment alongside its other three
   required permissions (§4's preamble).
3. Idempotent by construction: the route's own `on_conflict: :nothing` upsert
   (§1.3) makes a second run of this step report `{"inserted": {...all
   zeros...}}` rather than erroring or duplicating — matching this script
   family's existing idempotency convention, now enforced server-side instead
   of client-side.

### 4.3 Record-import function

1. Reads the fixture record-array file for the entity type (chunks into ≤200-row
   `POST .../import` calls if the count ever exceeds that cap — not needed at
   today's 83/10 counts, §3, but stated so a future fixture growth doesn't
   silently break the cap).
2. Per §3.3, either relies on the import route's own `idempotency_key` handling or
   does its own pre-check query — whichever §3.3's flagged check resolves to.
3. Same `curl -sf` / explicit `ERROR:` / `set -euo pipefail` failure convention as
   every other function in this script family.

### 4.4 Script invocation order

Definitions first (both types, §4.1), then the restriction rows (§4.2) — a
restriction row naming an entity type that doesn't exist yet would be meaningless
— then records (§4.3), matching the dependency order a reader would expect
(schema before rows, access rules attached to a schema that already exists).

## 5. Out of scope (explicitly, not silently)

- **ISS-0526** (the separate, already-tracked `pipeline_test`/Playwright-spec gap:
  `web/tests/e2e/pipelines/entity-list-query.pipeline.e2e.spec.ts` does not exist
  and the scenario's own `pipeline_test` field is a forward-reference nobody has
  authored). This design closes the API-leg precondition gap (D6) only. The
  scenario remains BLOCKED on its frontend/GUI leg (`UNBUILT_FEATURE`) until
  FRONTEND-DEV authors that spec against this design's seeded data — a necessary
  follow-on this design does not fold in, per the task's explicit instruction.
- **Running this script against live QA.** No credentials are available from this
  design/build sandbox (same documented posture as ISS-0897/ISS-0886/ISS-0892's
  own designs) — running `scripts/seed_vortex_entities.sh` against
  `https://qa.bizdala.com` is a documented operational follow-up for whichever
  agent/operator holds `QA_AUTH_TOKEN`, not something this fix executes itself.
- **D1-D3, D5** from the same UAT report (service-task `request_build_error`, role
  groups not seeded for human tasks, the Regulatory Compliance Review SLA path,
  the claim-vs-complete role-enforcement asymmetry) — unrelated defects on
  unrelated scenarios/tenants, each already its own issue thread.
- **`GET /entities/definitions` (plural) filtering** — REQ-394's own §3.3/OQ-1
  already names this as a known, narrower, explicitly-out-of-scope residual gap
  for the mechanism this design reuses; not reopened here.
- **A full admin CRUD/listing API for the four restriction tables** — this
  design adds exactly one narrowly-scoped bulk-import write route (§1.3,
  `POST /entities/restrictions/import`) because the seed script genuinely
  needs a write path and none existed; it does not add `GET`/`DELETE`/per-row
  update routes, a listing UI, or any authoring workflow beyond bulk-import.
  REQ-231's OQ-3 and REQ-394's OQ-3 remain the place a fuller admin-authoring
  API (list existing restrictions, revoke one, etc.) would eventually be
  designed — this design's new route is this fix's minimum, not that.

## 6. Acceptance criteria

1. `test/fixtures/qa/vortex_production_batch_entity_definition.json` exists,
   validates against `Letflow.Entities.Definition.Validator` (compiles/activates
   without error when POSTed), and its field list contains `supplier`, `status`
   (with `quarantined` in `enum_values`), `deviation_raised_at` (`queried: true`,
   a date-typed field), `cost_figure`, and `internal_notes` (`queried: false`).
2. `test/fixtures/qa/vortex_shipment_manifest_entity_definition.json` exists and
   validates the same way, as a second, distinct entity type.
3. A sample-record fixture exists for `production_batch` with at least 51 (this
   design specifies 60) records simultaneously matching `supplier: "Nordmetall"`
   AND `status: "quarantined"`, each with a distinct `deviation_raised_at`, plus
   records for at least one other supplier and at least one other status for the
   same supplier (Nordmetall) — satisfying EO-001's "exactly the matching
   batches, nothing else" as a real (non-vacuous) filter test.
4. A sample-record fixture exists for `shipment_manifest` with at least one
   record.
5. `scripts/seed_vortex_entities.sh` exists, follows the existing
   `seed_vortex_definition.sh`/`seed_service_task_base.sh` conventions (`set -euo
   pipefail`, required `QA_AUTH_TOKEN`, default `QA_URL`, idempotent per-unit
   create/skip, explicit `ERROR:`-prefixed failures, human-readable summary), and
   seeds, in order: both entity-type definitions (§4.1), the four
   field-/type-level restriction rows via `POST /entities/restrictions/import`
   (§4.2), then both record sets (§4.3).
6. `POST /entities/restrictions/import` (§1.3) exists in
   `lib/letflow/routers/entities.ex`, gated by a new `:EntitiesRestrictionsManage`
   permission added to `Letflow.Api.Authorization.core_permissions/0`, backed by
   a new `Letflow.Entities.Restrictions.import_restrictions/2` context function
   that upserts (`on_conflict: :nothing`) into all four tables named in its
   request body and returns per-table inserted-row counts; a caller without
   `:EntitiesRestrictionsManage` receives `403`.
7. After a successful run against a real QA instance (not executed by this design,
   §5): `GET /entities/definitions` lists `production_batch` and
   `shipment_manifest` for a vortex admin; `POST /entities/query` with
   `entity_type: production_batch`, `status: quarantined`, `supplier: Nordmetall`
   as `actor-vortex-karl` returns ≥60 items across pages with no `cost_figure`
   value ever present as a real number (sentinel/redacted only) and no
   `internal_notes` filter clause accepted; the same query as `actor-vortex-anna`
   returns the real `cost_figure` values; `POST /entities/query` with
   `entity_type: shipment_manifest` as Karl returns `{"items": [], "next_cursor":
   null}`, byte-identical in shape to a genuinely empty/nonexistent type query.
   (This criterion is RELEASE-VALIDATOR/UAT-RUNNER's to verify once credentials
   are available — listed here so the design's intent is checkable, not as
   something CODE-DESIGN-VALIDATOR itself runs.)
8. Design precedes implementation; CODE-DESIGN-VALIDATOR sign-off recorded before
   ELIXIR-DEV/any script-authoring work proceeds.

## 7. SECURITY-REVIEWER determination

**HARD GATE — required, not optional, not a judgment call.** This revision
(per CODE-DESIGN-VALIDATOR's FAIL) adds a genuinely new authorization surface:
a new backend route (`POST /entities/restrictions/import`, §1.3), a new
permission (`:EntitiesRestrictionsManage`), and a new write path into four
tenant-schema tables that have never had an external write path before. That
is exactly the category of change `docs/agents/instructions/security-invariants.md`
gates on (new route + new permission + a tenant-data write path), independent
of how narrowly scoped the route's purpose is. Specifically in scope for
SECURITY-REVIEWER:

- Whether `:EntitiesRestrictionsManage` is correctly a *distinct* permission
  from `:EntitiesDefinitionsWrite`/`:EntitiesRecordsImport` rather than an
  unjustified widening of either (§1.3's own reasoning, re-checked
  independently).
- Whether the route's `422`/tenant-scoping behavior correctly rejects a
  `user_id` outside the calling tenant (no cross-tenant grant-row injection via
  a crafted `user_id`), consistent with every other tenant-schema-prefixed
  write route in this router.
- Whether an upsert-only (`on_conflict: :nothing`), no-`GET`/no-`DELETE` route
  is an acceptable minimum surface for this capability, or whether omitting a
  revoke path creates its own gap (e.g. a restriction row inserted by mistake
  having no route-level way to remove it) — flagged for SECURITY-REVIEWER's own
  judgment, not pre-decided here.
- Whether a route that can hide an entire entity type or redact a field
  tenant-wide should itself be more restrictively gated than a single
  permission flag (e.g. requiring the `PLATFORM_ADMIN`-equivalent role
  `seed_swiftroute_persona_actors.sh` already requires for its own
  elevated-permission actions, not just "any token holding this one
  permission").

Both already-implemented read-side mechanisms (`FieldGrants`/`TypeAccess`)
remain unmodified by this design and keep their prior sign-off; this gate is
specifically on the new write route and permission, not a re-review of
either read-side mechanism.

## 8. Open questions

- **OQ-1 — RESOLVED (§1.3):** the write-path mechanism for the four restriction
  tables is a new admin HTTP route, `POST /entities/restrictions/import`, gated
  by a new `:EntitiesRestrictionsManage` permission. Not deferred to
  ELIXIR-DEV; chosen and justified in §1.3 against the existing
  `scripts/seed_*` family's trust model (bearer-token-only, no direct-DB-credential
  precedent anywhere in the family).
- **OQ-2 — RESOLVED (§2.2):** no third, always-empty entity type is added.
  `production_batch` filtered to a nonexistent supplier already supplies EO-004's
  "genuinely empty" comparison point — a third type would produce a
  byte-identical response and add no distinguishing power.
- **OQ-3 (§3.3) — still open:** whether `POST /entities/records/:entity_type/import`
  honors per-item `idempotency_key` the way the single-record create route does;
  if not, the seed script needs its own pre-check-query idempotency guard
  instead. This is a narrow, bounded implementation question (not a new
  authorization surface) and is correctly ELIXIR-DEV's to confirm against
  `handle_import_records/2`'s current body before writing §4.3.
- **OQ-4 — RESOLVED (§4.1):** entity definitions have no in-place update path
  (no `PUT`/`PATCH` route exists on `/definitions/:id` or `:name`) and this
  design does not add one. The seed script's rule is "exists by name → skip
  unconditionally, never update"; a future field-list change requires a new,
  differently-named entity type or a manual migration, not a silent re-run.
