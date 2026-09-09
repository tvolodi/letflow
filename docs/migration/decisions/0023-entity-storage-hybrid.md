# 0023 — Entity storage: per-entity-type tables with a hybrid column/blob shape

Status: decided (2026-09-09, user-directed), with one named open question —
the DDL-execution procedure — that blocks implementation, not the decision.
Owner: `ORCH` (supersedes part of REQ-228's shipped storage design).

## Question

`REQ-225`–`REQ-231` shipped the entity subsystem with a single shared
current-state table per tenant: `entity_record_latest`, holding
`(entity_type, record_id, field_values :: jsonb, deleted, entity_def_version,
last_event_global_seq)`, with one unique index on `(entity_type, record_id)`
and no index on `field_values`.

That design is correct for what it was scoped to — low-volume configuration
data, a handful of rows per entity type. Decision 0022 then made it the
storage layer for a *vertical*: BilimBaga's question banks, exam sessions,
per-question answers and assignments, which are high-volume operational data
in the same table.

Two consequences follow, and both were measured against `lib/` before this
record was written:

1. **Every filter on a definition-declared field is an unindexed sequential
   scan.** `Letflow.Entities.Query.Compiler` compiles a `:json_field` filter
   to `?->>?` text extraction plus a cast
   (`@string_fragment`/`@integer_fragment`/…). With no GIN index and no
   generated columns, filtering questions by difficulty or status scans every
   entity record of every type in the tenant.
2. **There is no relational structure to join on.** The compiler contains no
   `join`/`preload`; `fk_def.references_entity` is validated for shape and
   self-reference in `Letflow.Entities.Definition.Validator` only, with no
   write-time or database-level referential enforcement.

So: what is the storage model for entity records?

## Decision

**Per-entity-type physical tables, each with a hybrid column/blob shape.**

Each entity type gets its own table in the tenant schema. Each such table
carries:

- the structural columns every entity record has (`record_id`, `deleted`,
  `entity_def_version`, `last_event_global_seq`, timestamps);
- **one real, typed, indexed column per *promoted* attribute** (see the
  promotion rule below);
- **`field_values :: jsonb`** holding every attribute that has not been
  promoted.

The two halves are orthogonal and are decided separately: *hybrid* is about
column-vs-blob within a table; *per-entity-type* is about how many tables.
This record adopts both, and the reasoning below keeps them separate because
they are defensible on different grounds.

### The promotion rule

An attribute becomes a real column when **either** trigger fires:

1. **It is a foreign key** — the attribute appears as some `fk_def`'s `field`
   in the entity definition.
2. **It is declared `queried: true`** — the definition already marks it as a
   field the query DSL may filter or sort on.

Everything else stays in `field_values`.

Both triggers read data the definition **already declares**. `Definition.t()`
has carried `foreign_keys` and `queried` since `REQ-225`, and
`fk_field_coverage_violations/1` already enforces that every `fk_def.field`
names a real field. Nothing new is authored to drive promotion; the migration
step reads what is already there.

### Promotion is additive and one-way

- **Adding a column is the only migration shape.** New attribute in the blob:
  no DDL at all. Blob attribute becomes an FK or `queried: true`: add a
  nullable column, backfill, index.
- **Demotion is forbidden.** A promoted column is never dropped, and a
  narrowing type change is never applied in place. This is the property that
  makes definition evolution safe in a pipeline with no human gate.
- **The event log is the backstop.** `Letflow.Entities.Record.Projector`'s
  `rebuild_projection/2` can re-derive every current-state row from the event
  log. A promotion backfill is therefore replayable rather than a one-shot
  data movement — the single most important safety property of this design,
  and the reason the event-sourced projector earns its cost.

### The entity-vs-blob test

One question decides whether something is its own entity type or a key inside
its parent's blob:

> **Does anything need to query, join, or field-redact it independently?**

Yes → its own entity type. No → blob.

"Field-redact" is load-bearing and is not a stylistic third option:
`Letflow.Entities.Query.FieldGrants` (REQ-231) redacts at *field* granularity
on a record. A value that must be hidden from one viewer and shown to another
must be a field on a record, because there is no mechanism that redacts inside
a blob.

Applied to BilimBaga's own schema, this test decides the cases that prompted
it:

| BilimBaga table | Verdict | Why |
|---|---|---|
| `answer_options` | **entity** | `is_correct` drives grading and must be redacted from a candidate — `FieldGrants` operates on fields, not blob keys |
| `question_translations` | **blob** | queried only *through* its question, never fetched independently, and follows the question's lifecycle exactly |
| `answer_translations` | **blob** | same, through its option |
| `question_tags` | **entity** (a join) | see below |

### Many-to-many is not a special case

A join table is an ordinary entity type whose promoted columns happen to be
two foreign keys. `question_tags` is an entity with `fields: [question_id,
tag_id]`, two `fk_def`s, both promoted by trigger 1, and a `constraint_def`
of `type: :unique, fields: [question_id, tag_id]` for pair uniqueness.

Two things follow that are worth stating because they are free here and are
not free in a rigid ORM:

- **A join carrying its own attributes needs no new concept.** `sort_order`,
  `assigned_at`, `weight` live in the join entity's own `field_values`. The
  "association object" problem does not arise.
- **`constraint_def` becomes load-bearing and must be activated.** It is
  declared in `Definition.t()` (`type: :unique` its only value) and validated
  for field coverage today, but **nothing creates a Postgres index from it**.
  Under this decision it is what makes a join row unique, so activating it is
  part of this work, not a later nicety.

An earlier draft of this analysis treated m2m as an open question needing an
array column with a GIN index. That was wrong and is recorded here so it is
not re-proposed: an array of references is unindexed without GIN, has nowhere
to put join attributes, and is invisible to `FieldGrants`.

### Localized entity content is blob, and is not an i18n gap

Entity-content localization (a question's stem in kk/ru/en) is **data
following the entity's lifecycle** — created, updated and deleted with its
parent. It is a different thing from UI localization (button labels, error
messages), which is `REQ-285`/react-intl, client-side, and never touches
entities. Stage 10's gap 11 originally conflated the two.

By the entity-vs-blob test, localized content is blob, keyed by locale:

```json
{ "stem": { "kk": "…", "ru": "…", "en": "…" },
  "explanation": { "kk": "…", "ru": "…" } }
```

One row per question, one write per lifecycle event, no join on the hot read
path. BilimBaga's Go schema used a child table (`question_translations`)
because a fixed relational schema had no blob option; this model does.

**Searching localized content does not require an entity.** A `queried: true`
localized field promotes under trigger 2 to one generated column per supported
locale (`stem_kk`, `stem_ru`, `stem_en`), extracted from the blob and indexed
— `tsvector` where real full-text search is wanted. Same promotion machinery,
different trigger.

## Reasoning

**1. The hybrid shape is what the definition schema was already describing.**
`Definition.t()` carries `fields`, `indexes`, `foreign_keys` and
`constraints`. Nothing in the shipped implementation creates an index, a
foreign key or a constraint from any of them — the shape describes a
relational table that was never built. This decision builds it, rather than
inventing a parallel concept.

**2. Additive-only evolution is the property worth protecting.** Adding an
attribute is a blob write with no DDL; only promotion migrates, and only ever
by adding. `entity_def_version` is already stamped on every row, so
mixed-version rows stay interpretable. This is what keeps a definition change
cheap in a pipeline that merges without a human gate.

**3. Per-entity-type tables buy database-enforced referential integrity, and
the shared table cannot have it at any price.** This is not a preference; it
is a property of the shared-table shape, and it is worth spelling out because
it is the least obvious part of this record.

Under the shared table, every record of every type is a row in
`entity_record_latest`. Promote `question_tags`' FKs to columns and a join row
holds `question_id = Q1`. To have Postgres enforce that `Q1` is a real
question, the constraint would be:

```sql
FOREIGN KEY (question_id) REFERENCES entity_record_latest (record_id)
```

Two things break. First, `record_id` is **not unique** — the table's only
unique index is `(entity_type, record_id)`, deliberately, so each type has its
own id space; a `REFERENCES` target must be unique, so the constraint cannot
be created at all. Second, referencing the full key instead —
`FOREIGN KEY (entity_type, question_id) REFERENCES (entity_type, record_id)` —
still cannot type-check, because `entity_type` on the join row is the literal
`"question_tags"`, not `"question"`. The statement that needs making is
*"`question_id` must match a row whose `entity_type = 'question'`"* — a
constant on the target side, which SQL foreign keys cannot express. There is
no `REFERENCES entity_record_latest(record_id) WHERE entity_type = 'question'`.

So the shared table permits only an application-level check inside
`upsert_record_latest/3`, whose guarantee holds exactly as long as every
writer goes through that funnel. Per-entity-type tables get real `REFERENCES`,
real cascades, `NOT NULL`, and `CHECK` — enforced against a bulk importer, a
repair script or a migration that bypasses the funnel. For
`SECURITY-REVIEWER`, "Postgres enforces it" is checkable in a way "every code
path remembers to check" is not.

**4. Table count is not the cost it is under human maintenance.** The standard
objection to table-per-entity-type — schema sprawl — is a *human* cost:
holding the schema in your head, hand-writing migrations, keeping mappings in
sync. Here the DDL is a pure function of `Definition.t()`, generated and
maintained by agents, with the definition as the single source of truth. Table
count becomes output volume rather than a complexity metric. This record
explicitly rejects the traditional sizing of that objection; `0004`'s
humanless-pipeline premise is why this project is entitled to.

**5. What this costs, stated rather than discovered later.** Two real prices:

- **Definition changes that promote become DDL against live data, per
  tenant.** Under schema-per-tenant, N tenants × M entity types is the table
  count, and a promotion fans out across every tenant schema.
  `Letflow.TenantProvisioning`'s template-copy provisioning gets materially
  heavier. Adding a nullable column is trivial; the procedure that runs it
  everywhere, safely, without a human gate, is not — which is exactly the open
  question below.
- **A migration path off the shipped shape.** `entity_record_latest` exists
  and REQ-228/229/230/231 are built against it. This is a supersession, in
  0003's sense, not a greenfield choice.

## Open question — answered by 0024

**How a promotion's DDL is executed, per tenant, in a humanless pipeline.**

**Answered.** See
[`0024-entity-promotion-ddl-execution.md`](0024-entity-promotion-ddl-execution.md)
(REQ-295, 2026-09-09), pending its own `SECURITY-REVIEWER` and `REVIEWER`
gates recorded in that record's own sections. It resolves all four
sub-questions originally listed here — the DDL-execution mechanism
(`Letflow.TenantProvisioning`, extended), per-tenant partial-failure
semantics (a new `entity_column_promotions` table), backfill (a replay
through `rebuild_projection/2`, gated by dual-write), and rollback
(allowlist exclusion plus a corrective promotion, never a drop/narrow) — and
states a recommendation on `entity_record_latest`'s retirement. **No
implementation requirement may be filed against this record until 0024's own
gates pass.**

## Consequences

- **Supersedes REQ-228's storage design**, not its command surface.
  `create_record/2`, `update_record/2` and `delete_record/2` keep their
  contracts; `upsert_record_latest/3`'s two clauses write promoted columns
  alongside `field_values`. `Letflow.Entities.Records`' inner/outer validation
  split, idempotency handling and event append are unchanged.
- **`Letflow.Entities.Query.Allowlist.typed_columns/0` becomes
  per-entity-type.** Today it is a fixed 7-entry table of structural columns.
  Its documented shadowing precedence rule — a typed column always wins over a
  same-named JSONB key — was written for exactly this promotion case and needs
  no change.
- **`Letflow.Entities.Query.Compiler` needs no change to its filter
  compilation.** It already emits indexed `field(r, ^col)` comparisons for
  `:typed_column` and JSONB casts for `:json_field`. It does need joins added
  (S10 gap 10), which this decision makes expressible for the first time.
- **`constraint_def` is activated** — a Postgres unique index is created from
  it.
- **S10's gap 10 and its storage decision collapse into one piece of work.**
  Relations are a consequence of this record, not a separate gap.
- **S10's gap 11 shrinks and is re-scoped** to a localized-text field type,
  blob-stored and generated-column-indexed when `queried: true`. It is not a
  relations problem and not an i18n-layer problem.
- **`docs/anti-patterns.md`** gains the array-of-references shape as a
  rejected approach for m2m, with this record's reasoning.

## What this record does not decide

- **The DDL-execution procedure** — the open question above.
- **Whether `entity_record_latest` is migrated or retired.** Whether existing
  rows move into per-type tables, and whether the shared table is dropped or
  left in place, is the migration path's own design question. No deployment is
  known to hold entity records today.
- **Nothing about the engine, tenancy, definitions or promotion layers.** 0001
  (Plug/Bandit), 0003 (schema-per-tenant, Ecto-idiomatic migrations), 0006,
  0014 and 0022 all stand unchanged. This record changes one subsystem's
  storage shape and nothing above it.

## REVIEWER sign-off

(None yet — this record is a precondition, filed before any implementation
requirement exists. The open question above must be answered and gated before
one can be.)
