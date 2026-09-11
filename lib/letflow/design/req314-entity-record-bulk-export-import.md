# REQ-314 — Bulk export/import of entity records (S10 gap 12)

Status: design only. No `lib/` implementation, no route mounted, no migration, no
test. This document specifies the export-document format, the export-selection
mechanism, the import write path and batch-failure semantics, the route shape,
the permission vocabulary, the tenant-scoping/security posture, and the
size/resource limits that a future ELIXIR-DEV requirement builds from — mirroring
`lib/letflow/design/req308-entity-http-surface.md`'s and
`lib/letflow/design/req312-query-aggregation.md`'s rigor and section shape, and
extending REQ-311's now-landed HTTP surface (`Letflow.Routers.Entities`) rather
than replacing it.

Per decision 0022 rule 1: this document uses no domain-vertical vocabulary.
"entity type", "record", "field", "filter", "join", "export", "import", "batch"
are this subsystem's own generic nouns (already used, or directly analogous to
nouns already used, by the modules this document fronts), not any one
vertical's objects. §8 below is this document's own textual self-check of that
claim.

## 0. Premises re-verified before designing

**`Letflow.Definitions.ExportImport` moves definitions, not records — confirmed
by full read (`lib/letflow/definitions/export_import.ex`, 200 lines).**
`export/2` (lines 98-113) serializes exactly one `process_definitions` row,
fetched via `Letflow.Definitions.get_by_id/2`, into an `ExportDocument` struct
(lines 36-64). `import/3` (lines 131-149) takes an `ExportDocument` and calls
`Letflow.Definitions.create/2` — **always** a brand-new draft; `document.id` is
"carried only for informational/audit purposes and is never read when building
the `create/2` call" (moduledoc, lines 12-14). Its own "No independent
validation" section (lines 16-21), quoted verbatim:

> This module intentionally implements zero structural/attribute/edge-condition
> checks of its own. A document that would be rejected by `create/2` if its
> graph were submitted directly is rejected by `import/3` identically — there
> is no parallel, potentially-diverging validation path here.

Its schema-version gate (`@export_schema_version "bpm/definition/v1"`, line 34)
is checked first in `import/3`, "before touching tenant resolution, graph
validation, or the database" (moduledoc lines 23-29) — a mismatch returns
`{:error, {:unknown_schema_version, actual}}` and stops, never conflated with a
generic `create/2` validation failure. This is the direct structural precedent
this document reuses: its own document, its own schema-version constant, its
own version-gate-before-anything-else ordering, and its own
no-independent-validation posture toward whatever real write function it calls.

**`Letflow.Entities.Definitions` and `Letflow.Entities.Records` name no
bulk/batch record-level export or import operation — confirmed by full read of
both moduledocs.** `Letflow.Entities.Definitions`' moduledoc (`lib/letflow/entities/definitions.ex`
lines 1-46) documents `create_definition/2`, `list_definitions/2`,
`activate_definition/4` — no export/import member. `Letflow.Entities.Records`'
moduledoc (`lib/letflow/entities/records.ex` lines 1-90) documents exactly three
public commands, stated in its own opening line: "`create_record/2`,
`update_record/2`, `delete_record/2`" — no read function ("Record reads are
exclusively `POST /entities/query`", `lib/letflow/routers/entities.ex`
moduledoc), no export, no import, no batch variant of any of the three. There is
no bulk record-level export/import mechanism today, singular- or batch-record.

**`Letflow.Entities.Records.create_record/2` is the real current write path for
a new record — verified name/arity by reading `lib/letflow/entities/records.ex`
in full (lines 108-140).** Its `@spec`, quoted verbatim:

```
@spec create_record(create_attrs(), prefix :: String.t()) ::
        {:ok, command_result()} | command_error()
```

```
@type create_attrs :: %{
        required(:entity_type) => String.t(),
        required(:field_values) => Validator.field_values(),
        required(:actor_id) => Ecto.UUID.t(),
        required(:idempotency_key) => String.t()
      }

@type command_result :: %{record: Latest.t(), is_duplicate: boolean()}
```

Its own doc (lines 108-121) states the step order: resolve the entity type's
current active definition (`{:error, {:definition_not_found, entity_type}}`
otherwise), run REQ-227's inner field-value check (non-empty violations return
`{:error, {:record_payload_invalid, violations}}` with zero events appended,
before any `Ecto.Multi`/transaction exists), mint a fresh `record_id`
(`Ecto.UUID.generate()` — **never** caller-supplied), resolve-or-create the
synthetic per-type instance, append exactly one event and upsert
`entity_record_latest` in one transaction. `update_record/2` and
`delete_record/2` both require an *already-existing* `record_id` and are
therefore not import's mechanism (§3 below states why import uses
`create_record/2` exclusively, never the other two).

**`POST /entities/query`'s route internals — the natural export-selection
mechanism, confirmed by full read of `lib/letflow/routers/entities.ex`.** The
route table's own `query` row (moduledoc lines 20-31, quoted in full at §4
below) states the pipeline: `Letflow.Entities.Query.Compiler.compile/2` then
`Letflow.Entities.Query.Allowlist.load/2` then
`Letflow.Entities.Query.Cursor.paginate/5` then a
`Letflow.Entities.Query.FieldGrants` redaction step. `Types.query_request/0`
(`lib/letflow/entities/query/types.ex` lines 102-107), quoted verbatim:

```
@type query_request :: %{
        required(:entity_type) => String.t(),
        optional(:filters) => [filter_clause()],
        optional(:sort) => [sort_clause()],
        optional(:join) => [join_clause()]
      }
```

**`lib/letflow/routers/definitions.ex`'s route table — the direct
export/import route-table precedent, quoted verbatim (moduledoc lines 14-30):**

```
| Handler | Method/path                       | Delegate                                              | Permission | Response |
|---|---|---|---|---|
| export  | `GET /definitions/:id/export`     | `Letflow.Definitions.ExportImport.export/2`             | `DefinitionsRead`  | 200 / 404 |
| import  | `POST /definitions/import`        | `Letflow.Definitions.ExportImport.import_with_variable_schemas/4` | `DefinitionsWrite` (REQ-082 divergence — see below) | 201 / 422 |
```

Its own "REQ-082 divergence" section (moduledoc, quoted): the four
write/lifecycle routes (deprecate/archive/delete/import) each got their **own**
`endpoint_policy_key` clause (e.g. `:DefinitionsImport`), mapped by
`required_permission/1` back onto the single coarse `:DefinitionsWrite` grant —
"no clause, not permission-gated" was the alternative rejected because REQ-082's
own AC7 required a 403-without-`DefinitionsWrite` test per route. This is a
**policy-key-level** divergence (one atom per route, for per-route testability),
not a **grant-level** divergence (all four still gate on the same underlying
`DefinitionsWrite` permission) — §5 below states which shape this document
picks for entity-record import.

**`lib/letflow/api/authorization.ex`'s current `Entities*` vocabulary, quoted
grep:**

```
$ grep -n "Entities" lib/letflow/api/authorization.ex
64:  ## `Entities*` (REQ-309) — added ahead of their consuming router
...
78:  `:EntitiesRecordsRead` atom — `Letflow.Entities.Records` exposes no read
80:  `:EntitiesRecordsRead` would be dead vocabulary. See
...
111:          | :EntitiesDefinitionsRead
112:          | :EntitiesDefinitionsWrite
113:          | :EntitiesRecordsWrite
114:          | :EntitiesQuery
...
473:  def endpoint_policy_key("POST", "/entities/records/:entity_type"), do: :EntitiesRecordsWrite
...
489:  def endpoint_policy_key("POST", "/entities/query"), do: :EntitiesQuery
584:  def required_permission(:EntitiesDefinitionsRead), do: :EntitiesDefinitionsRead
585:  def required_permission(:EntitiesDefinitionsWrite), do: :EntitiesDefinitionsWrite
586:  def required_permission(:EntitiesRecordsWrite), do: :EntitiesRecordsWrite
587:  def required_permission(:EntitiesQuery), do: :EntitiesQuery
```

Four atoms exist today: `:EntitiesDefinitionsRead`, `:EntitiesDefinitionsWrite`,
`:EntitiesRecordsWrite`, `:EntitiesQuery`. **`:EntitiesRecordsRead` does not
exist** — the module's own comment (lines 78-80) states it is deliberately
absent because `Letflow.Entities.Records` exposes no read function, so minting
it today would be dead vocabulary. §5 below states this document's own new
atom(s).

**`Letflow.Entities.Query.FieldGrants`, re-read in full
(`lib/letflow/entities/query/field_grants.ex`, 209 lines).** `load_restrictions/3`
computes, per `(user_id, entity_type, prefix)`, the set of field names that user
cannot see; `redact_page/2`/`redact_joined_page/2` replace a restricted field's
*value* with the sentinel `:__field_redacted__` while the row's key stays
present, operating on **already-materialized row data** returned by the query
route. §6's INV-2 below is exactly the point this raises for export: does
export run through this same redaction, or is it a different kind of read?

## 1. The export document shape

**Own schema-version constant, independent of `ExportImport`'s
`"bpm/definition/v1"`:**

```
@export_schema_version "entities/record-export/v1"
```

**Granularity: a caller-specified/query-selected SET of records, bounded per
call by §7's size cap — never "the whole entity type's table" in one call.**
Reasoning:

- A single record is strictly a degenerate case of a selected set (a query
  selecting exactly one record_id) — not worth a separate document shape or
  route.
- "Whole entity type's table in one call" is rejected outright: it has no
  natural bound, so it cannot coexist with §7's explicit per-call cap (any
  entity type could in principle hold an unbounded number of records), and
  this is a synchronous HTTP call, not a background job (§7's own governing
  constraint). BilimBaga's reference precedent (cited in the requirement's own
  text as scale/shape context, not a constraint this document copies) uses a
  bulk *offline* import/export mechanism precisely because unbounded volume
  and HTTP-request lifetime are structurally incompatible — this document
  does not import that precedent's offline shape, but it does inherit the
  underlying reason that motivates it: no unbounded synchronous transfer.
- A whole-table export is still reachable, without a second mechanism, as a
  sequence of query-selected-set export calls the caller pages through using
  the same cursor primitive `POST /entities/query` already exposes (§2) — no
  separate "export everything" endpoint or flag is introduced.

**Export document shape:**

```
@type export_record_entry :: %{
        required(:record_id) => Ecto.UUID.t(),
        required(:field_values) => map(),
        required(:deleted) => boolean()
      }

@type export_document :: %{
        required(:record_export_schema_version) => String.t(),
        required(:entity_type) => String.t(),
        required(:exported_at) => String.t(),
        required(:records) => [export_record_entry()]
      }
```

`record_id` is carried for informational/audit purposes only, the same role
`ExportImport.ExportDocument.id` plays (§0) — §3 states import never reuses it
to address a row. `deleted` is copied verbatim from `Letflow.Entities.Record.Latest.deleted`
so a deleted record's export entry is distinguishable from a live one, matching
`Letflow.Entities.Records`' own moduledoc statement that delete is
"appends one event and marks the row `deleted: true`, `field_values` retained
unchanged" — nothing about export needs to special-case a deleted record
differently from a live one; it round-trips the same two fields either way. No
`entity_def_version` field: import always validates against the *importing*
tenant's *current* active definition (§3), the identical "current active
definition, which may differ from the definition version the record was
originally created under" non-goal `update_record/2`'s own moduledoc already
states for the analogous case — carrying the source definition version would
invite a reader to believe import reconciles across versions, which it does
not.

## 2. The export selection mechanism

**Reuses `Letflow.Entities.Query.Types.query_request/0` (`filters`/`sort`/`join`)
via the same internal pipeline `POST /entities/query` already uses — no new
selection language.** Justification, mirroring REQ-312 §0/§1's identical reuse
argument for its own `group_by`/aggregate targets: inventing a second
filter/sort/join grammar for export-selection would duplicate
`Letflow.Entities.Query.Allowlist`'s closed-column-resolution and
`Letflow.Entities.Query.Compiler`'s injection-safe query-building logic for no
new expressive power — every selection an export caller could plausibly want
("this entity type's records where X", "sorted by Y", "joined to Z for
selection purposes") is already exactly what `query_request()` expresses today.

**Mechanism:** the export handler accepts an optional `query_request()`-shaped
body (`filters`/`sort`/`join`, `entity_type` supplied by the route's own path
segment rather than duplicated in the body — see §4), plus one additional,
export-specific optional field this document adds, `unredacted :: boolean()`
(default `false`) — or an absent/empty body meaning "no filter, natural order,
redacted." The handler internally calls the identical `Allowlist.load/2` →
`Compiler.compile/2` → `Cursor.paginate/5` sequence `handle_query/1` already
calls, capped at §7's per-call limit instead of the caller-chosen `page_size`
the plain query route accepts (a caller cannot request a larger export page
than §7 permits). Everything through `Cursor.paginate/5` is the exact same
call sequence `POST /entities/query` already uses, unmodified. What happens
next is §6 INV-2's own two-tier mechanism, summarized here and specified in
full there: `unredacted` absent/`false` (the default) applies
`FieldGrants.load_restrictions/3` + `redact_field_values/2` over each selected
record's `field_values`, identically to how `POST /entities/query` already
redacts a page; `unredacted: true` additionally requires the caller to hold a
second, independently-revocable permission
(`:EntitiesRecordsExportUnredacted`, §5) checked in-handler before the
redaction step is skipped — absent that second grant, a request carrying
`unredacted: true` is rejected `403` outright rather than silently served
redacted (§6 states why a silent fallback to the default mode is the wrong
failure mode).

## 3. The import write path and validation

**Import goes through `Letflow.Entities.Records.create_record/2` — verified
name/arity, quoted at §0 — with NO independent/parallel validation, matching
`ExportImport`'s own precedent quoted in full at §0.** For each
`export_record_entry()` in the import document's `records` list, the handler
builds a `create_attrs()` map:

```
%{
  entity_type: <document.entity_type, matched against the route's own :entity_type path segment>,
  field_values: entry.field_values,
  actor_id: <conn.assigns.auth_context.user_id>,
  idempotency_key: <deterministically derived from (entity_type, entry.record_id) — see below>
}
```

and calls `create_record/2` unchanged. **A deleted export entry
(`entry.deleted == true`) is imported as a live `create_record/2` call
identically to a non-deleted one** — this document does not attempt to
reproduce "already deleted" state via a create-then-delete pair, since that
would require a second write path call per entry with no atomicity between the
two (§3's own atomicity discussion below); a future requirement could add that
if reproducing exact deletion history through import is ever required. This is
an explicit, named scope cut, not a silent omission.

**Never reuses `document`'s `record_id` to address an update.** `create_record/2`
always mints its own fresh `record_id` via `Ecto.UUID.generate()` (§0) — the
imported record's id has zero dependency on whether `entry.record_id` collides
with an existing row, the identical "imported row's id is always freshly
assigned... zero dependency on collision" guarantee `ExportImport.import/3`'s
own moduledoc states (INV-EI-1, §0). This is why import calls
`create_record/2` exclusively and never `update_record/2`/`delete_record/2`:
both of those require an *existing* `record_id` the importing tenant may not
have (and, per INV-1 below, must never be told to trust from the document
anyway).

**Idempotency key derivation — deterministic, not caller-supplied.**
`create_record/2` requires `idempotency_key` (§0's `create_attrs()`). Since the
import document is untrusted input (§6 INV-1), this document does not read an
idempotency key from `entry` at all — the handler derives one deterministically
from `(import_request_id, entry.record_id)` where `import_request_id` is a
fresh UUID minted once per `POST .../import` call (`Ecto.UUID.generate()`, the
handler's own responsibility, never from the document). This makes re-POSTing
the exact same HTTP request idempotent (matching `create_record/2`'s own AC3
duplicate-key contract, §0) while giving two entries that happen to share an
`entry.record_id` value across two separate import calls no special
relationship — each import call is its own idempotency namespace, consistent
with `record_id` being informational-only per above.

**No independent validation — `create_record/2`'s own two-stage check (inner
field-value validation, then the outer event-envelope validation inside
`EventStore.append_multi/3`) runs exactly as it would for a single
`POST /entities/records/:entity_type` call.** This document adds no schema
check, no type check, no constraint check of its own ahead of `create_record/2`
— the same "a document that would be rejected by `create_record/2` if
submitted directly is rejected by import identically" posture `ExportImport`'s
own quoted moduledoc text states (§0), transplanted from the definition-export
domain to this one.

**Per-batch failure semantics: per-record partial success with a per-record
result list — not whole-batch atomicity.** Justification against
`create_record/2`'s actual transactional shape (§0): `create_record/2` commits
its own `Ecto.Multi` via its own internal `Repo.transaction/1` call, once, per
invocation — it is not designed to be composed as one step inside a
*caller-supplied* outer `Multi` spanning many records (its public contract is
`create_attrs(), prefix -> {:ok, command_result()} | command_error()`, not an
`Ecto.Multi.t()`-returning step a caller folds into their own transaction).
Wrapping N independent `create_record/2` calls in one outer
`Repo.transaction/1` at the import-handler level would require either (a)
reimplementing `create_record/2`'s internals to accept an externally-supplied
`Multi` — a change to the real write path this document's own "no bypass" rule
forbids, or (b) nesting `Repo.transaction/1` calls, which Ecto does not support
as true nested atomicity. Given `create_record/2` cannot be composed
atomically across records without modifying it, the design commits to the
option consistent with using it unmodified: each entry is imported
independently, and the response carries a per-entry result:

```
@type import_entry_result ::
        {:ok, %{record_id: Ecto.UUID.t(), source_record_id: Ecto.UUID.t()}}
        | {:error, source_record_id :: Ecto.UUID.t(), reason :: Records.command_error()}

@type import_response :: %{
        required(:results) => [import_entry_result()]
      }
```

`source_record_id` is `entry.record_id` from the document (informational, per
above); the freshly-minted id is returned alongside it in the success case so
the caller can reconcile which imported row corresponds to which document
entry. A batch with some failing entries still returns `200`/`207`-shaped
success at the HTTP layer (§4 states the exact status) carrying both outcomes
— the per-entry `reason` is `create_record/2`'s own `command_error()` union
unchanged, not a new error vocabulary.

## 4. Route shape

New sibling routes on the entity type's own record path, mirroring
`ExportImport`'s own `.../:id/export` / `.../import` naming and
`lib/letflow/routers/entities.ex`'s established Handler/Method-path/Delegate/
Permission/Response table form:

| Handler | Method/path | Delegate | Permission | Response |
|---|---|---|---|---|
| export_records | `POST /entities/records/:entity_type/export` | this document's export handler → `Allowlist.load/2` → `Compiler.compile/2` → `Cursor.paginate/5` → `FieldGrants.load_restrictions/3` + `redact_field_values/2` by default, skipped only when the request's `unredacted: true` and the caller separately holds `:EntitiesRecordsExportUnredacted` (§5/§6 INV-2, two-tier) | `EntitiesRecordsExport` (route-level, mandatory); `EntitiesRecordsExportUnredacted` (checked in-handler, only when `unredacted: true` is requested) | 200 / 400 / 403 / 404 / 422 |
| import_records | `POST /entities/records/:entity_type/import` | this document's import handler → `Letflow.Entities.Records.create_record/2` per entry | `EntitiesRecordsImport` | 200 / 400 / 404 / 413 / 422 |

**`POST`, not `GET`, for export — same reasoning `Letflow.Routers.Entities`'
own moduledoc already gives for `POST /entities/query`.** Export's selection
body (§2) is the identical unboundedly-nested `filters`/`sort`/`join` shape
`query_request()` already is, with "no flat query-string encoding in this
codebase and no way to express it as repeated `?field=op:value` pairs without
inventing a mini-language this design declines to invent" (quoted reasoning,
`lib/letflow/routers/entities.ex` moduledoc, reused verbatim here). This is a
deliberate divergence from `ExportImport`'s own `GET /definitions/:id/export`
(which needs no body at all, since it addresses exactly one row by path `:id`)
— the two exports differ precisely because this one has a selection payload
and that one does not.

**`:entity_type` in the path, not the body, for both routes — the document's
own `entity_type` field (§1/§3) must match the path segment exactly, or the
request is rejected `422` before any `create_record`/selection call.** This
mirrors every existing `/entities/records/:entity_type/...` route already
taking `entity_type` positionally from the path (`create_record`,
`update_record`, `delete_record` in the existing table, §0), rather than
introducing the first record route where `entity_type` arrives two ways that
could disagree.

**No route reads or writes a `Repo` directly** — both handlers compose
existing context/query-module calls only (`Allowlist`/`Compiler`/`Cursor` for
export, `Records.create_record/2` per entry for import), the same "router
composes existing context/query-module calls, never executes its own SQL"
discipline `Letflow.Routers.Entities`' own moduledoc already states and REQ-312
§4 already reused.

## 5. Permission vocabulary

**Three new atoms: `:EntitiesRecordsExport` (read-classified, default/redacted
export), `:EntitiesRecordsExportUnredacted` (read-classified, the escalation
atom for full-fidelity export), and `:EntitiesRecordsImport`
(write-classified) — neither existing atom is reused.** Grep of
`lib/letflow/api/authorization.ex` (quoted at §0) confirms
today's four atoms (`:EntitiesDefinitionsRead`, `:EntitiesDefinitionsWrite`,
`:EntitiesRecordsWrite`, `:EntitiesQuery`) and confirms
`:EntitiesRecordsRead` does **not** exist, by the module's own comment: dead
vocabulary while `Letflow.Entities.Records` has no read function. That
reasoning does not carry over unchanged to export, because export **is** a
real read of record data, exercised in bulk against a query-shaped selection
rather than one paginated interactive request — minting `:EntitiesRecordsRead`
for it would still be misleading, since that name reads as an alias for
`:EntitiesQuery` itself rather than naming a distinct, independently-revocable
bulk-extraction capability with its own route, document format, and size cap
(§§1-4). Naming it `:EntitiesRecordsExport` keeps the atom's name honest about
which capability holding it grants, the same "keep the atom name honest about
the capability, don't reuse one whose name implies a different capability"
discipline REQ-312 §3 already applied when it declined to extend
`:EntitiesQuery` to cover aggregation. **By default, `:EntitiesRecordsExport`
grants exactly `:EntitiesQuery`'s own disclosure strength, not more** — §6
INV-2's rework specifies that plain `:EntitiesRecordsExport` runs export
through the identical `FieldGrants.load_restrictions/3` + `redact_field_values/2`
redaction `POST /entities/query` already applies, so this atom's default grant
never discloses a field to a caller that `:EntitiesQuery` would already have
redacted for that same caller. It is still its own atom, not a reuse of
`:EntitiesQuery`, because it gates a structurally different operation (a bulk,
document-shaped extraction against §7's own size cap, through this
requirement's own route) that a future role-matrix pass should be able to
revoke independently of interactive query access, the same
independent-revocability reasoning this section already applies to
`:EntitiesRecordsImport` below.

**`:EntitiesRecordsExportUnredacted` — a second, strictly stronger,
independently-revocable atom gating the one capability this document
originally proposed as `:EntitiesRecordsExport`'s only mode: full-fidelity,
unredacted, whole-`field_values` export bypassing `FieldGrants` entirely.**
This is the entity-record-export analogue of the
`:EntitiesRecordsImport`-over-`:EntitiesRecordsWrite` two-tier shape this
section already uses below for import, applied to the one place
SECURITY-REVIEWER's review found it was needed most and had not yet been
applied: a caller holding only base `:EntitiesRecordsExport` gets the
`FieldGrants`-respecting default (identical disclosure strength to
`:EntitiesQuery`, previous paragraph); a caller additionally holding
`:EntitiesRecordsExportUnredacted` and setting `unredacted: true` on the
request (§2/§4) gets every field of every selected record, unredacted,
regardless of that caller's own `FieldGrants` restriction set. This is
deliberately the **strongest, most exceptional atom this document
introduces** — holding it grants system-wide bypass, for the named entity
type, of every per-user field restriction any tenant admin has configured via
`entity_field_restrictions`/`user_entity_grants` (§6 INV-2's own confirmation,
re-derived from SECURITY-REVIEWER's finding, that no existing capability in
this codebase lets one identity override that mechanism for other users'
existing data). Its independent revocability is the entire point: a tenant
can grant ordinary bulk-export access (`:EntitiesRecordsExport`) to a broader
set of roles while keeping `:EntitiesRecordsExportUnredacted` reserved for a
narrow, explicitly-provisioned break-glass/administrative set — the two
grants are never coupled, and holding one never implies the other (§6 INV-2
states the mechanical proof of this via `required_permission/1`'s flat
mapping). §6 INV-2 gives this atom's full security reasoning, including the
compromised/over-provisioned-service-account scenario and the operational
recommendation for who should hold it.

`:EntitiesRecordsImport`, not a reuse of `:EntitiesRecordsWrite`: this is the
entity-record analogue of `ExportImport`'s own `DefinitionsImport` divergence
(§0, quoted) — but this document picks the **grant-level** divergence
`DefinitionsImport` did *not* make, not just the policy-key-level one.
`DefinitionsImport` is a distinct `endpoint_policy_key` clause purely for
REQ-082 AC7's per-route 403 testability, while `required_permission/1` still
maps it back onto the same underlying `:DefinitionsWrite` grant (§0) — holding
`DefinitionsWrite` was already sufficient to import a definition, no
additional grant needed. Entity-record import is different in kind, not just
in test-granularity, from a single `create_record/2` call: it is a
bulk-authoring operation whose failure mode (§3's partial-success semantics)
and blast radius (§7's per-call record cap, still potentially hundreds of
records created in one authenticated action) both exceed what "can author one
record via the UI/API" (`:EntitiesRecordsWrite`) was ever evaluated against.
A role trusted to create records one at a time through the ordinary write path
is not automatically trusted to bulk-create hundreds via a document whose
contents were not independently validated beyond `create_record/2`'s own
checks (§3) — the same "materially riskier capability gets its own
independently-revocable grant" reasoning REQ-312 §3 used for
`:EntitiesAggregate` over `:EntitiesQuery`. `:EntitiesRecordsImport` is
therefore a genuinely separate grant, not merely a separate policy key mapped
back to `:EntitiesRecordsWrite`.

**Role-matrix mapping — a judgment call, flagged for REVIEWER, not silently
decided (same discipline REQ-308 §3 and REQ-312 §3 both use for their own role
tables) — with one of the three atoms flagged as categorically more
exceptional than the other two, not left at the same weight.** This document
does **not** propose that every role holding `:EntitiesRecordsWrite` also
receive `:EntitiesRecordsImport` by default (unlike REQ-312's own
`:EntitiesAggregate` default, which did propagate from `:EntitiesQuery` — see
§6 INV-2 for why export/import's disclosure/authoring strength is treated as
categorically different from aggregation's). All three new atoms are proposed
as narrowly-granted-by-default: a future REVIEWER/role-matrix pass should
decide which roles (at minimum, a `PLATFORM_ADMIN`-equivalent catch-all)
receive `:EntitiesRecordsExport`/`:EntitiesRecordsImport`, rather than this
document foreclosing that mapping. **`:EntitiesRecordsExportUnredacted` is not
an ordinary entry in that same judgment call** — unlike the other two atoms,
this document does not merely leave its grant narrow-by-default and defer the
rest to REVIEWER; it states outright that this atom's disclosure strength
(system-wide bypass of every per-user `FieldGrants` restriction on the named
entity type, §6 INV-2) makes it qualitatively different from every other atom
this subsystem defines, including `:EntitiesRecordsExport`/`:EntitiesRecordsImport`
themselves, and recommends it be provisioned only to a break-glass or
platform-administrative role, never bundled into an ordinary tenant role's
default grant set regardless of how much that role is otherwise trusted with
`:EntitiesRecordsExport`/`:EntitiesRecordsWrite`/`:EntitiesRecordsImport` — a
compromised or over-provisioned service account holding the other two atoms
still cannot read another user's `FieldGrants`-restricted data; one holding
`:EntitiesRecordsExportUnredacted` can, in bulk, for every record of the named
entity type, in one call. §6 INV-2 restates this recommendation as part of
its own mechanism, not deferred to a future document.

## 6. Tenant scoping and the security boundary (INV-1, INV-2, INV-5, INV-7)

Per `docs/agents/instructions/security-invariants.md`. This is a tenant-data
path; SECURITY-REVIEWER is a hard gate on it (§9 below is where that verdict is
recorded — reserved, not fabricated by this document).

**INV-1 (tenant data isolation).** `prefix` is sourced exclusively from
`conn.assigns.scoped_opts` (`Letflow.Api.Context.scoped_repo_opts/1`'s output),
the same and only source every other route in `Letflow.Routers.Entities`
already uses (§0's citation of that module's own INV-1 section). Neither
`export_document()` nor the import request body carries a `tenant_id`, schema
name, or any cross-tenant record reference (§1/§3's shapes: `entity_type`,
`exported_at`, `records[].{record_id, field_values, deleted}` only — no tenant
field anywhere). `record_id` inside an import entry is explicitly never used to
address an existing row (§3) — it cannot function as a cross-tenant record
reference even in principle, since `create_record/2` never looks it up, only
mints a fresh one. The export selection body (§2) is a plain
`query_request()`, whose own existing INV-1 guarantee (`compile/2` derives
every table/column reference from `prefix` alone, §0's citation of REQ-312 §4)
is unmodified and unbypassed — this document adds no second scoping mechanism
and no route-local `Repo.*` call on either route.

**INV-2, the hard one — reworked after SECURITY-REVIEWER's first-pass FAIL.
This document's original position was that export should always bypass
`FieldGrants` entirely, authorized solely by holding `:EntitiesRecordsExport`.
SECURITY-REVIEWER correctly rejected that: it verified directly against
`field_grants.ex` that no existing capability in this codebase lets one
identity read every field of arbitrary records regardless of `FieldGrants`,
named this design as the first one that would, and rejected the
`:EntitiesRecordsWrite` analogy this document used to justify it as a category
error — writing values a caller supplies is a different risk shape from
reading *other users'* existing restricted values in bulk, since the two
mechanisms (the coarse route-level atom and `FieldGrants`' own per-user
override layer) would otherwise never interact at all for export, silently
overriding whatever a tenant configured for that caller under `:EntitiesQuery`.
This section adopts SECURITY-REVIEWER's option (a): a two-tier atom scheme,
mirroring the `:EntitiesRecordsImport`-over-`:EntitiesRecordsWrite` divergence
this document already uses (§5) for the one place that reasoning had not yet
been applied.**

*The round-trip-corruption problem this document already identified is real
and still stands — it is the reason a "just always redact" default is wrong,
not a reason to keep unredacted-only.* A `FieldGrants`-redacted export
returned to import through `create_record/2` (§3, no independent validation)
would write the literal sentinel `:__field_redacted__` back as a real,
permanent field value — worse than not exporting the field at all. This
document does not solve that by keeping export unconditionally unredacted (the
rejected position); it solves it by making the unredacted mode an explicit,
separately-authorized opt-in, and by stating plainly, here, that the
`FieldGrants`-respecting default mode is **not intended for backup/reimport
use whenever the exporting caller has any restricted field for that entity
type** — a caller who needs a faithful, reimportable backup needs
`:EntitiesRecordsExportUnredacted` (below), not the default mode. This is a
documentation/operational-guidance safeguard on the default mode, in addition
to the two-tier permission split, not a claim that the default mode is safe to
reimport universally.

*The mechanism: two modes, two atoms, checked at two different points.*

  1. **Default (`unredacted` absent or `false`, §2): `FieldGrants`-respecting
     export.** Route-level `:EntitiesRecordsExport` is checked by the router's
     `authz_post` macro exactly like every other route in this module (§0's
     citation of the existing route table) — this is the only check for the
     default mode. The handler then calls
     `FieldGrants.load_restrictions(user_id, entity_type, prefix)` (the
     identical call `POST /entities/query`'s own handler already makes,
     §0/§6's earlier citation of `field_grants.ex`) once per export call, and
     applies `redact_field_values/2` over each selected record's
     `field_values` before building the response — **the exact same
     redaction primitive and the exact same disclosure strength
     `:EntitiesQuery` already gives that caller**, merely reached via a bulk,
     document-shaped route instead of a paginated interactive one. A caller
     redacted from a field under `:EntitiesQuery` sees that same field
     redacted (sentinel-substituted, key retained) under default-mode export
     — the two mechanisms are no longer non-interacting for this mode; export
     now composes with `FieldGrants` instead of bypassing it.

  2. **Escalated (`unredacted: true`, §2): full-fidelity export, gated by a
     second, in-handler permission check.** After the route-level
     `:EntitiesRecordsExport` check already passed (a caller who lacks even
     the base atom never reaches the handler at all), the handler — seeing
     `unredacted: true` in the request body — calls
     `Letflow.Api.Authorization.evaluate_access/2` a second time, manually,
     against the atom `:EntitiesRecordsExportUnredacted` directly (that
     function's own `@spec`, quoted at §0, takes an `endpoint_policy_key()`
     atom positionally — nothing requires the atom passed to it to be one
     `endpoint_policy_key/2` would itself resolve from this route's
     method/path; a handler is free to check a second, request-shape-derived
     permission the same way `evaluate_access/2` already checks a
     route-derived one). If that second check fails, the request is rejected
     `403` **immediately, before the export selection query is even
     compiled** — the same "reject before doing any work the caller isn't
     authorized for" ordering `compile_aggregate/2`'s own INV-2 mechanism uses
     (REQ-312 §4) — and, critically, **the request is never silently served
     redacted instead**: a caller who explicitly asked for unredacted data and
     lacks the grant learns unambiguously that a different credential is
     needed, rather than receiving a redacted response they might mistake for
     a complete one. If the second check succeeds, `FieldGrants` is skipped
     entirely for that call — full `field_values`, unredacted, exactly this
     document's original mechanism, now reachable only via the stronger atom.

*Why this closes the gap SECURITY-REVIEWER found.* Two users can both hold
`:EntitiesRecordsExport` and see different redaction outcomes for the same
entity type under default-mode export, exactly as they already can under
`:EntitiesQuery` today — the "second, orthogonal, per-user layer" property
SECURITY-REVIEWER confirmed `FieldGrants` has is preserved, not silently
overridden, for every caller who does not also hold
`:EntitiesRecordsExportUnredacted`. The bypass capability still exists (§1's
faithful-backup use case still needs it), but it is no longer reachable by
merely holding the base export atom — it requires a second, independently
revocable, deliberately exceptional grant (§5), addressing the
compromised/over-provisioned-service-account scenario directly: a
service account provisioned with ordinary `:EntitiesRecordsExport` (e.g. for a
reporting integration) discloses nothing beyond what that same account could
already see via `:EntitiesQuery`, even if compromised or over-provisioned
relative to its intended use — only an account additionally, deliberately
granted `:EntitiesRecordsExportUnredacted` can disclose `FieldGrants`-restricted
data in bulk, and §5 states plainly that grant should be reserved for a
break-glass/administrative role, never bundled into an ordinary service
account's default permission set.

*Could a caller with only `POST /entities/query` access (`:EntitiesQuery`)
reach export and get MORE data than a query would give them? No — checked
explicitly, for both modes.* `:EntitiesQuery`, `:EntitiesRecordsExport`, and
`:EntitiesRecordsExportUnredacted` are three independent atoms;
`required_permission/1`'s existing shape (§0's grep — a flat `atom -> atom`
mapping, no atom implies another) gives no path from holding one to being
treated as holding another. A caller holding only `:EntitiesQuery` gets a 403
from the route-level `authz_post` check before the export handler runs at all
— identical to before this rework. A caller holding base
`:EntitiesRecordsExport` but not `:EntitiesRecordsExportUnredacted` reaches the
handler but is capped at exactly `:EntitiesQuery`'s own disclosure strength
(default mode, above) and is refused `403` if they request `unredacted: true`
— such a caller can never see more than `:EntitiesQuery` already shows them,
closing exactly what this check exists to confirm.

**INV-5 (not-found and cross-tenant are the same bytes).** A nonexistent or
cross-tenant `:entity_type` on export produces the identical
`{:error, :entity_type_not_found}` → 404 the plain query route already
produces (§0's citation of `Letflow.Entities.Query.Allowlist.load/2`,
unmodified, called identically here). On import, a document naming an
`entity_type` with no active definition in the importing tenant produces the
identical `{:error, {:definition_not_found, entity_type}}` → 404
`create_record/2` already produces for a single-record write (§0) — no new
error shape, no cross-tenant-specific pre-check anywhere in either handler
(the same "no handler adds a cross-tenant existence pre-check" discipline
`Letflow.Routers.Entities`' own INV-5 section already states, reused verbatim).

**INV-7 (no user-supplied string reaches SQL outside the existing
allowlist/parameterization).** Export's selection filters (§2) pass through
the identical `Allowlist.resolve_field/2` → `Compiler.compile/2` sequence
every other filter/sort/join field in this subsystem already passes through
(§0) — this document introduces no new query-building code and no new
fragment-construction primitive; it reuses `Compiler.compile/2`/`Cursor.paginate/5`
verbatim, unmodified, for the selection half of export. Import never builds a
query at all — every write goes through `create_record/2`'s existing
`Ecto.Multi`/`Ecto.Changeset`-based insert path (§0's citation of
`upsert_record_latest/3`'s `Latest.insert_changeset/2` and
`repo.insert(prefix: ctx.prefix)`), the same parameterized-insert mechanism
every existing `POST /entities/records/:entity_type` call already uses — this
document adds no raw SQL and no string-built query anywhere.

## 7. Size/resource limits

**Export: capped at `Letflow.Api.Pagination.max_page_size/0` (200) records per
call — the same, already-reviewed ceiling `Cursor.paginate/5` already enforces
for the plain query route, not a new number this document invents.** A
selection matching more than 200 records returns exactly the first 200 (by the
selection's own `sort`, or insertion order if unsorted) plus the same
`next_cursor` mechanism `POST /entities/query` already returns — a caller
needing a whole entity type's records issues a sequence of export calls,
paging via that cursor exactly as a caller of the plain query route already
must for a large result set (§1's own reasoning for choosing query-selected-set
granularity over whole-table-in-one-call). No new pagination mechanism is
introduced; this document reuses `Cursor`'s existing one unmodified.

**Import: capped at 200 records per call (matching the export cap, so a single
export page always fits in a single import call) — past the cap, the whole
request is rejected before any `create_record/2` call is made, HTTP 413
(Payload Too Large).** Rejecting the *whole* batch past the cap (rather than
silently truncating to the first 200) is deliberate: truncation would silently
drop records with no signal to the caller, which is a strictly worse failure
mode than an explicit, immediate 413 naming the actual count submitted vs. the
cap. This check runs first, before entity-type/definition resolution or any
individual entry's validation — the same "cheapest, most structural check
first" ordering `ExportImport.import/3`'s own schema-version gate already uses
(§0: version check "before touching tenant resolution, graph validation, or
the database"). A caller with more than 200 records to import issues a
sequence of import calls, each within the cap — consistent with export's own
same-sized page, so a mechanical "export a page, import that page" loop never
needs to split or merge pages across the two operations.

## 8. Rule 1 self-check — quoted grep, run last against the file as it actually stands

Quoting a grep for reserved single-vertical terms necessarily makes the
quoted command line itself match, since the command's own pattern text
contains every one of those terms — that self-match is inherent to quoting
the check verbatim, not evidence of a leak (the same trivial self-reference
REQ-312 §8 notes for its own quoted command line). To keep this section from
manufacturing any *additional*, avoidable self-matches, this paragraph and
the one following the code block deliberately do not restate any of the
pattern's own reserved terms — they only describe, structurally, what the
command finds. Plain `-inE` is used rather than `-inoE`: with `-o`, a single
line matching several alternatives prints once per alternative, which would
turn one matching line into many printed rows, an artifact of the flag rather
than a real count of matching lines; `-inE` prints each matching line at most
once regardless of how many alternatives it satisfies, which is what "how
many lines contain a reserved term" actually means here.

One alternative in the pattern is wrapped in a word-boundary anchor rather
than left as a bare substring: a plain, unanchored form of that one four-letter
farming term matches inside an unrelated, longer English past-participle this
document uses elsewhere ("de-" + that term + "-d", describing a fallback
response quality, nothing agricultural) purely as a substring collision — not
a vocabulary leak, but a check ought not to have to explain that collision
away every time it is re-run, so the pattern itself is tightened here instead.
No other alternative in the pattern needed the same tightening for this file's
current text (verified by comparing a run with and without the anchor: the
anchored run drops exactly the one collision line and no others).

The command was run last, against this file exactly as it stands — including
both `SECURITY-REVIEWER Verdict` sections now appended below §10, which are
that reviewer's own text, not this document's, and outside this document's
ability to edit — and reported four matching lines:

```
$ grep -inE "exam|candidate|question|certificate|score|\bgrade\b|test-taker|invigilat|patient|invoice|shipment|policyholder|claimant" \
    lib/letflow/design/req314-entity-record-bulk-export-import.md
```

The first matching line is the command's own pattern text, quoted directly
above — the unavoidable self-reference already explained, and also the one
line where the farming term appears unanchored (inside the pattern string
itself, where it must be spelled out literally for the check to test for it)
without being a false alarm, since a pattern's own listing of its targets is
not a use of any of them. The other three matching lines all sit inside the
first appended `SECURITY-REVIEWER Verdict` section (not the second, later
"Final Verdict" section, which the anchor confirms is now clean of every
alternative including the former farming-term collision), each using the
generic English noun this pattern flags in its ordinary sense — naming a
design point under discussion ("this design's own §6 ... is answered",
"different ... , and this one's answer", "not to this exact ... for export")
— not the vertical noun this rule targets; none names a domain object, and
each reads, in context, as "the point/topic at issue," the same generic usage
this document's own §0 originally used at the sentence introducing the INV-2
topic before it was reworded away during an earlier gate pass. No line in
§§0-7, 9-10, or this section's own explanatory prose — this document's own
text — contains a match; that prose was written, and re-checked against a
fresh run of the exact command above, specifically to confirm it stays that
way through each edit. Excluding the command's own unavoidable self-quotation
and the appended reviewer section's generic, non-vertical usage of one common
English word, this document names no domain-vertical object anywhere. Every
noun this document uses to describe the mechanism
(`entity_type`, `record`, `record_id`, `field_values`, `filter`, `sort`,
`join`, `export`, `import`, `batch`, `deleted`) is either a name an
already-shipped, already-reviewed generic module in this codebase uses for
itself (`Letflow.Entities.*`, `Letflow.Definitions.ExportImport`), or a direct,
domain-neutral extension of one (`export_document`, `export_record_entry`,
`import_entry_result`) coined by this document for a vocabulary that, by
definition (§0), does not exist anywhere in this codebase yet. The only
numeric/bookkeeping tokens repeated are "S10 gap 12" / "REQ-314" (stage and
requirement bookkeeping) and "REQ-082"/"REQ-308"/"REQ-311"/"REQ-312" (citations
of sibling requirements' own already-reviewed design text), neither of which is
vertical vocabulary. This requirement's own title/description/acceptance-criteria
text in `docs/requirements.yaml` was authored by REQ-ANALYST, not this
document, and is outside this document's ability to edit — but a manual read
of that entry (performed before writing this document, §0's citations of its
exact text) found the same zero-hits property already holds there.

## 9. Does this warrant a `docs/migration/decisions/` record?

**No — the design artefact alone suffices**, for the same reasoning REQ-308 §10
and REQ-312 §7 both give for their own, structurally identical route-table/
permission-vocabulary/security-boundary choices: the route shape (§4), the
three new permission atoms including the two-tier export split (§5), the
default-redacted/escalated-unredacted export mechanism (§6 INV-2), and the
size caps (§7) are all ordinary extensions of this subsystem's own existing
design conventions (REQ-230/231/300/308/311/312), not
a cross-cutting architectural decision load-bearing for unrelated future work.
A future requirement could, in principle, later add whole-table export,
`update_record`/`delete_record` replay through import, or a background-job
variant for larger batches, without contradicting anything this document
settles — it would simply be extending this document's own scope, the same
non-foreclosing relationship REQ-308 §10 and REQ-312 §7 both describe for their
own documents.

## 10. For SECURITY-REVIEWER

This design's own tenant-scoping position is §6 in full — INV-1, INV-2 (the
two-tier default-redacted/escalated-unredacted export mechanism reworked after
this document's first SECURITY-REVIEWER pass, the reasoning for why base
`:EntitiesRecordsExport` never discloses more than `:EntitiesQuery` already
would, why `:EntitiesRecordsExportUnredacted` is gated as a second,
independently-revocable, explicitly-exceptional grant, and the explicit check
of whether `:EntitiesQuery`-only or base-`:EntitiesRecordsExport`-only access
could reach unredacted data), INV-5, and INV-7 are each addressed by name with
a concrete mechanism, not an assurance.
**SECURITY-REVIEWER's recorded verdict is a hard-gate precondition for this
design to proceed to CODE-DESIGN-VALIDATOR sign-off**, per this requirement's
own acceptance criteria — this document does not fabricate one. ORCH should
route this design to SECURITY-REVIEWER next; that agent's verdict should be
appended below this line, addressing INV-1, INV-2, INV-5, and INV-7 by name,
exactly as REQ-308's own §11 and REQ-312's own §9 verdicts do.

## SECURITY-REVIEWER Verdict

**Overall: FAIL — BLOCKING on INV-2.** INV-1, INV-5, and INV-7 pass. INV-2's
mechanism is real and clearly specified, but its safety argument does not
survive scrutiny as written, and the document considers no alternative to
"export always bypasses `FieldGrants` entirely." This is not a demand to
mirror REQ-312's outcome for its own sake — the two designs raise genuinely
different questions, and this one's answer is currently insufficient on its
own terms.

**INV-1 (tenant data isolation) — PASS.** Verified against
`lib/letflow/api/context.ex` directly (not just the design's citation):
`scoped_repo_opts/1` takes only `conn` and reads exactly
`conn.assigns[:auth_context][:tenant_id]` — no parameter slot for a
caller-supplied tenant/prefix hint exists in that module at all (context.ex
lines 59-66). Neither `export_document()` (§1) nor the import request body
(§3) carries a tenant/schema field, and `record_id` is confirmed
informational-only, never used to address an existing row on import (§3) —
so it cannot be used as a cross-tenant reference even in principle. The
export selection body is an unmodified `query_request()`, whose own
`Compiler`/`Allowlist` scoping is unchanged. No new scoping mechanism, no
route-local `Repo.*` call. Mechanism is concrete and correctly cited.

**INV-2 (does the operation stay inside its authorized tenant/data
boundary) — FAIL, blocking.** The mechanism (skip `FieldGrants`, gate on a
new atom) is concretely specified, and the round-trip-corruption argument
for *why redaction-on-export is unsafe* (§6, the sentinel-write-back point)
is correct and well-reasoned — that part of INV-2 is not in dispute. The
failure is in the second half: the claim that holding `:EntitiesRecordsExport`
alone is a *sufficient* authorization for full, unredacted, cross-user field
disclosure.

1. **Confirmed via direct read of `field_grants.ex` (not just the design's
   citation): no existing path in this codebase lets one identity read every
   field of arbitrary records regardless of `FieldGrants`.** `FieldGrants`
   is a *second, orthogonal, per-user* access-control layer
   (`entity_field_restrictions` + `user_entity_grants`, default-deny) that
   sits **on top of** the coarse route-level `:EntitiesQuery` permission —
   two users can both hold `:EntitiesQuery` and see different redaction sets
   for the same entity type. This design is the first capability in the
   codebase that lets holding one coarse atom disclose data regardless of
   what that second layer says for that specific caller. The design's own
   §6 question ("does today's system have any path...") is answered
   correctly by the design as "no" implicitly, but the document does not
   draw the conclusion that follows: this is not an extension of an existing
   pattern, it is a **new maximum-disclosure primitive**, and it deserves
   scrutiny proportional to that, not scrutiny calibrated to "just another
   atom in the vocabulary."

2. **The `:EntitiesRecordsWrite` analogy (§6, "the same 'granting the atom
   IS the authorization' shape... already uses for writes") does not hold,
   because writing and reading-other-users'-existing-values are different
   risk shapes.** A caller with `:EntitiesRecordsWrite` sets field values
   they themselves supply on `create_record/2` — they are never shown an
   *existing* restricted value belonging to a record someone else created.
   Concretely: if tenant admin configures `entity_field_restrictions` +
   `user_entity_grants` so that user U cannot see entity type T's `field_values["salary"]`
   via `POST /entities/query` (U holds `:EntitiesQuery` but is redacted for
   that field), granting U `:EntitiesRecordsWrite` changes nothing about
   U's visibility into other records' existing `salary` values — U can only
   set values on records U authors. Granting U `:EntitiesRecordsExport` as
   designed, however, gives U every existing record's real `salary` value
   for every record of type T, in bulk, in one call — silently overriding
   the exact per-user restriction the tenant configured `FieldGrants` to
   enforce, with no interaction between the two mechanisms at all. The
   two atoms are not "the same shape applied to reads instead of writes";
   `:EntitiesRecordsExport` uniquely combines "coarse, all-or-nothing gate"
   with "discloses other users' data the fine-grained gate was built to
   hide," which `:EntitiesRecordsWrite` never does.

3. **The compromised/over-provisioned-service-account scenario named in my
   task is not discussed anywhere in §5 or §6.** §5's role-matrix section
   flags that default role assignment is a REVIEWER judgment call, but says
   nothing about the atom's exceptional severity relative to every other
   atom in the vocabulary (`:EntitiesQuery`, `:EntitiesRecordsWrite`,
   `:EntitiesRecordsImport` are all treated as ordinary narrowly-granted
   atoms in that section's prose) — there is no comment, warning, or
   distinguishing weight anywhere in the design that would prompt a future
   role-matrix author, or REVIEWER, to treat "grant `:EntitiesRecordsExport`"
   as materially different in kind from any other permission grant, even
   though §6 itself establishes that it is.

4. **No alternative is discussed and rejected.** The document considers
   exactly one option — "always full, unredacted access, gated solely by
   the new atom" — and defends it against the round-trip-corruption problem,
   but never considers or rejects, with reasoning, a design that would
   preserve both properties: e.g. (a) export respects `FieldGrants` by
   default and requires a **second, stronger** atom
   (`:EntitiesRecordsExportUnredacted` or similar) to bypass it — the
   two-atom shape `:EntitiesRecordsImport` itself uses relative to
   `:EntitiesRecordsWrite` (§5's own "materially riskier capability gets its
   own independently-revocable grant" reasoning, which the document applies
   to import but not to this exact question for export); or (b) export
   defaults to redacted output with the sentinel value stripped (field
   *omitted* rather than sentinel-substituted, avoiding the round-trip
   corruption §6 identifies) unless `:EntitiesRecordsExport` is held, in
   which case full values are returned. Either would address the
   round-trip-corruption problem without also being the first capability in
   the codebase to let one grant silently override every other user's
   configured field restriction. The document's own §5 discipline
   ("materially riskier capability gets its own independently-revocable
   grant") is the right instinct — it just was not applied to the one place
   it matters most.

**Required before this can PASS:** either (a) add a second, distinctly-named,
independently-revocable permission atom that gates the *unredacted* variant
of export, with `FieldGrants`-respecting export as the default under plain
`:EntitiesRecordsExport` (mirroring the `:EntitiesRecordsImport`-over-
`:EntitiesRecordsWrite` two-tier shape §5 already uses), or (b) if the
document still concludes single-tier unredacted-only export is correct,
replace the `:EntitiesRecordsWrite` analogy with an explicit, named
discussion of the FieldGrants-bypass property above, an explicit rejection
of the two-tier alternative with real reasoning (not just omission), and a
concrete role-matrix/documentation safeguard (not deferred silently to
REVIEWER) marking this atom as exceptional. Route back to CODE-DESIGNER.

**INV-5 (not-found and cross-tenant are the same bytes) — PASS.** Verified
against `lib/letflow/routers/entities.ex`: `{:error, :entity_type_not_found}`
(line 1185) and `{:error, {:definition_not_found, _}}` /
`{:error, {:record_not_found, _}}` (lines 852-856) already fold to
`Response.not_found/1` uniformly for every existing route; the design reuses
these unmodified for both export (entity-type resolution) and import
(definition resolution), adding no new error shape and no cross-tenant
existence pre-check in either handler. The per-record partial-success result
list (§3) also does not introduce a new information leak: each entry's error
is `create_record/2`'s own existing `command_error()` union (validation
failure or `definition_not_found`), the same errors a single-record
`POST /entities/records/:entity_type` call already exposes — nothing about
batching reveals whether a *specific* `record_id` exists elsewhere, since
import never looks up an existing record by id (§3).

**INV-7 (no user-supplied string reaches SQL outside existing
allowlist/parameterization) — PASS.** Export's selection path reuses
`Allowlist.resolve_field/2` → `Compiler.compile/2` → `Cursor.paginate/5`
verbatim (confirmed no new query-building code is introduced in §2/§4).
Import performs no querying at all — every write goes through
`create_record/2`'s existing `Ecto.Changeset`/parameterized-insert path.
No raw SQL, no new string-built query anywhere in the design.

— SECURITY-REVIEWER

## SECURITY-REVIEWER Final Verdict (re-check after §5/§6 rework)

**Overall: PASS.** The rework genuinely closes the gap identified above, not
merely restates it with new names. Re-verified directly against code, not
just the design's citations: `Letflow.Entities.Query.FieldGrants.redact_field_values/2`
is a real, existing, public function (`field_grants.ex:112-113`) — the same
primitive `redact_page/2`/`redact_joined_page/2` already build on — so
applying it directly to each selected record's `field_values` in the default
export mode is an unmodified reuse, not a new redaction mechanism invented
for this document. `Letflow.Api.Authorization.evaluate_access/2` is a pure
two-argument function (`AccessContext.t()`, `endpoint_policy_key()` atom)
with no dependency on route resolution (confirmed earlier in this review,
`authorization.ex:499-524`) — a handler is free to call it a second time
against a request-body-derived atom, exactly as §6 now describes; nothing
about its implementation forces the atom passed in to be the one
`endpoint_policy_key/2` would itself resolve for that route.

1. **Does the default mode really disclose no more than `:EntitiesQuery`
   would? Yes.** Default-mode export calls the identical
   `FieldGrants.load_restrictions/3` → `redact_field_values/2` sequence
   `POST /entities/query`'s handler already calls, over the same
   `(user_id, entity_type, prefix)` key. Two callers who see different
   redaction sets under `:EntitiesQuery` see the identical difference under
   default-mode `:EntitiesRecordsExport` — the per-user layer is composed
   with, not bypassed by, this mode. This is the core fix: export no longer
   uniquely combines "coarse gate" with "bypasses the fine-grained layer."

2. **Does the fail-closed 403 on the unredacted path actually prevent a
   base-only caller from reaching unredacted data? Yes.** The second
   `evaluate_access/2` check against `:EntitiesRecordsExportUnredacted` runs
   before the export selection query is even compiled (§6, mirroring
   `compile_aggregate/2`'s reject-before-work ordering), and its failure
   path is `403`, never a silent fallback to redacted output. A caller
   holding only base `:EntitiesRecordsExport` and requesting
   `unredacted: true` gets an explicit refusal, not degraded-but-served
   data — so there is no request shape through which holding the base atom
   alone reaches unredacted values. `required_permission/1`'s flat
   atom→atom mapping (re-confirmed, §0's grep) still gives no atom the
   power to imply another, so `:EntitiesQuery`-only and
   base-`:EntitiesRecordsExport`-only callers are both correctly confined.

3. **Is the "exceptional atom" guidance concrete, not just restated?
   Yes.** §5 states a specific operational rule — reserve
   `:EntitiesRecordsExportUnredacted` for break-glass/administrative roles,
   never bundle it into an ordinary service account's default grant set,
   "regardless of how much that role is otherwise trusted with"
   the other two atoms — and gives the concrete reason (bulk,
   cross-user, all-record disclosure vs. the other atoms' bounded blast
   radius). This is a real, actionable constraint for the future
   role-matrix pass (distinguishing this atom from the two left as ordinary
   narrow-by-default judgment calls), not a vague restatement that the atom
   is "dangerous."

4. **INV-1, INV-5, INV-7 — unaffected, still PASS.** §6's INV-1/INV-5/INV-7
   prose is unchanged from the version I already verified line-by-line
   above (prefix sourced solely from `scoped_repo_opts/1`, not-found folding
   reused unmodified, no new query-building code). The rework touched only
   INV-2's mechanism (§2, §4's route table, §5, §6's INV-2 subsection) and
   the consistency passes in §8/§9/§10; nothing in the added `unredacted`
   field or the second permission check introduces a new tenant-scoping
   path, a new not-found shape, or any new string reaching SQL — the second
   `evaluate_access/2` call is a pure in-memory permission check, not a
   query.

No further blocking findings. Design is cleared to proceed to
CODE-DESIGN-VALIDATOR / REVIEWER on its security substance.

— SECURITY-REVIEWER
