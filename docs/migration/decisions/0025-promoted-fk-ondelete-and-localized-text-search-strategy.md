# 0025 — Promoted-FK-column ON DELETE policy, and localized-text plain-text-vs-tsvector strategy

Status: decided (2026-09-09, `CODE-DESIGNER`, REQ-302), pending its own
`SECURITY-REVIEWER` and `REVIEWER` gates (sections below, not yet filled in).
Owner: `ORCH`. Answers two independent column-semantics questions raised
while filing implementation requirements against
`0023-entity-storage-hybrid.md` — REQ-298's ON DELETE question and REQ-301's
localized-text column-strategy question — that do not compose with each
other or with `0024-entity-promotion-ddl-execution.md`'s four
DDL-execution sub-questions (REQ-295).

## Question

`0023-entity-storage-hybrid.md` decided that a promoted foreign-key
attribute becomes a real, indexed column with a real Postgres `REFERENCES`
constraint (§3, "Per-entity-type tables get real `REFERENCES`, real
cascades, `NOT NULL`, and `CHECK`"), but never named the `ON DELETE` clause
itself. Separately, it named `tsvector` as an option "where real full-text
search is wanted" for the generated-column mechanism a `queried: true`
localized-text field promotes to (§"Localized entity content is blob, and
is not an i18n gap"), without saying whether that option is mandatory,
forbidden, or a per-field choice.

Both questions were originally bundled into REQ-298 and REQ-301
respectively — the implementation requirements that would have had to
invent an answer mid-build, with no design review of the choice. Two
REQ-VALIDATOR rework rounds established that these two questions (a) must
be answered before REQ-298/REQ-301 can implement anything, and (b) are
independent of each other and of `0024`'s four DDL-execution sub-questions,
so they belong in their own record rather than folded into `0024`. This
record is that answer.

**Sub-question 1.** What `ON DELETE` clause does a promoted FK column's
`REFERENCES` constraint carry — `RESTRICT`, `SET NULL`, `CASCADE`, or `NO
ACTION`?

**Sub-question 2.** Does REQ-301's localized-text generated-column
mechanism implement plain-text generated columns only, `tsvector`
full-text columns only, or a per-field, definition-level choice between
the two?

## Decision

### Sub-question 1 — `ON DELETE RESTRICT`

Every promoted-FK-column `REFERENCES` constraint uses **`ON DELETE
RESTRICT`** (Ecto: `on_delete: :restrict`).

### Sub-question 2 — per-field, definition-level choice, plain-text by default

REQ-301's generated-column mechanism supports **both** plain-text and
`tsvector` generated columns, selected **per localized-text field, by a new
definition-level attribute**, not a single global mechanism and not a
choice REQ-301 makes internally at build time.

Concretely: a localized-text field's definition gains an attribute (name
`search_strategy` for cross-reference by any design artefact built against
this record) whose value is one of two named atoms:

- **`:plain`** (the default when the attribute is absent) — the field
  promotes to one plain generated text column per supported locale
  (`stem_kk`, `stem_ru`, `stem_en`, following `0023`'s own naming example),
  extracted from the `field_values` blob, indexed with a conventional
  B-tree/text index.
- **`:fulltext`** — the field promotes to one `tsvector` generated column
  per supported locale instead, indexed with GIN, for ranked/stemmed
  full-text search.

A field that does not declare `search_strategy` gets `:plain`. Nothing
about `0023`'s promotion *trigger* (`queried: true`) changes — this
attribute only selects which of the two column shapes trigger 2 produces
for a localized-text field; a non-localized `queried: true` field is
unaffected and continues to promote exactly as `0023` already describes.

## Reasoning

### Sub-question 1

**The soft-delete semantics, read from source.**
`Letflow.Entities.Records.delete_record/2` (`lib/letflow/entities/records.ex:199-219`)
never issues a SQL `DELETE` against a record's row. It resolves the
existing `entity_record_latest`-equivalent row (`fetch_existing_record/3`),
and if it is not already `deleted`, runs the same `run_command/2` pipeline
`create_record/2`/`update_record/2` use (`records.ex:225-242`), which
appends an `ENTITY_RECORD_DELETED` event and then calls
`upsert_record_latest/3`. That function's `:delete` clause
(`records.ex:289-298`) sets `deleted: kind == :delete` on an **update** to
the existing row — it is an `UPDATE ... SET deleted = true`, not a `DELETE
FROM`. The row referenced by any promoted FK stays physically present,
indefinitely, exactly as before the soft delete. `ensure_not_deleted/2`
(`records.ex:388`) is what later call sites use to treat a `deleted: true`
row as gone at the application layer; the database never sees it that way.

**Consequence: the `ON DELETE` clause is inert on the application's own
delete path, by construction.** Since `delete_record/2` never emits a SQL
`DELETE`, none of `RESTRICT`/`SET NULL`/`CASCADE`/`NO ACTION` is ever
invoked by ordinary application traffic. The clause only matters for a
genuine, out-of-band SQL `DELETE` against a referenced entity row —
a manual repair script, a bulk purge, a tenant-deprovisioning routine, or a
mistake — which is exactly the scenario `0023` §3 says per-entity-type
tables exist to make Postgres-enforceable rather than
application-code-enforceable.

**Why `RESTRICT` and not the other three, given that:**

- **`CASCADE` is excluded outright.** It would let a genuine hard `DELETE`
  against a referenced row silently remove every referencing row in every
  other entity-type table across the tenant schema. That is real,
  irreversible tenant data loss triggered by a single out-of-band
  statement, with no soft-delete recourse (the referencing rows are gone,
  not marked `deleted: true`) and no `entity_events` replay path back to
  them once removed synchronously by the FK action rather than through
  `Records.delete_record/2`'s own event-append pipeline. This is precisely
  the failure mode `0023` §3 identifies the shared-table design as unable
  to prevent and per-entity-type tables as able to; picking `CASCADE` here
  would throw that property away.
- **`SET NULL` is excluded.** It requires the FK column to be nullable.
  Trigger 1's promoted FK columns model a real relational reference
  (`fk_def.field`) that the entity definition already validates for
  presence (`0023`, "Both triggers read data the definition already
  declares"); most such references are required, not optional, and making
  every promoted FK column nullable purely to accommodate an
  out-of-band-delete edge case would be a load-bearing schema change driven
  by the wrong scenario. `SET NULL` also silently detaches a referencing
  row from its parent with no audit trail beyond the column going blank —
  exactly the "hard to audit after the fact" failure `SECURITY-REVIEWER`'s
  stated interest names.
- **`NO ACTION` (Postgres/Ecto default when `on_delete:` is omitted) is
  close but not chosen.** It differs from `RESTRICT` only in that it can be
  deferred to end-of-statement/end-of-transaction inside a multi-statement
  operation, which matters for cyclic or intra-statement FK graphs. Nothing
  in `0023`'s promoted-column shape creates such a cycle (a join entity
  like `question_tags` has two FKs to two *different* tables, not a cycle
  through itself), so the deferrable behavior buys nothing here and
  `RESTRICT`'s immediate, non-deferrable failure is the stronger and
  simpler guarantee — it surfaces an accidental out-of-band delete at the
  statement that caused it, not potentially later in the same transaction.
- **`RESTRICT` fits both the soft-delete premise and existing project
  idiom.** It makes the database refuse a hard `DELETE` against any
  referenced row for as long as a referencing row exists anywhere,
  independent of `deleted`'s value — reconciled with soft delete exactly
  because soft delete never attempts that `DELETE` in the first place, so
  `RESTRICT` never fires against ordinary traffic and only ever fires
  against the scenario it exists to catch.

**This matches, rather than diverges from, established precedent already in
this codebase**, found by grep across `lib/letflow/design/*.md` before this
record was written:

- `lib/letflow/design/req043-instance-engine-schema.md` (`tasks.token_id`,
  `tokens.parent_token_id`/`instance_id`): `on_delete: :restrict`,
  "deliberately diverging from R-Co's `ON DELETE CASCADE`... `:restrict` is
  the defensively safer default that fails loudly rather than
  unreachable in practice," because "no delete path exists for
  `instance_projections` anywhere in Letflow yet."
- `lib/letflow/design/req054-instance-state-snapshots.md`: same `:restrict`
  choice on `instance_id`, citing the identical migration-header reasoning
  verbatim ("`:restrict` fails loudly instead of silently losing tenant
  data").
- `lib/letflow/design/req211-instance-attachments-core.md`
  (`instance_attachments.content_hash` → `repository_artifacts.content_hash`):
  `on_delete: :restrict`, explicitly reasoned as "unreachable defense-in-depth"
  given the referenced table has no delete path at all — the same shape as
  this record's own reasoning that `RESTRICT` is inert on the ordinary path
  and exists for the out-of-band case.

No table in this codebase uses `on_delete: :delete_all` (Ecto's `CASCADE`)
against a row that has any soft-delete or audit-trail semantics. `RESTRICT`
is the established, repeated idiom for exactly this shape of FK; this
record adopts it rather than inventing a new one.

### Sub-question 2

**Why plain-text is the default, not tsvector.** This project already has
one full-text-search feature — `Letflow.Definitions.search/2` (REQ-042,
`lib/letflow/definitions.ex:79-88`) — and it is explicit that this was a
deliberate choice, not an oversight: "adds zero new indexes (no
`idx_def_name`, no GIN/`tsvector` index)," ranking via `ILIKE` alone, ported
from the predecessor system's `store.zig` specifically because "search
lives inside the existing store — no new Zig source file or SQL migration
is required." That is the only full-text-search precedent this codebase
carries, and it lands on the simple option. Grepping the rest of `lib/` for
`tsvector`/`to_tsvector`/`fulltext` before writing this record found no
other hit — there is no place in Letflow today that pays `tsvector`'s cost
(a GIN index per column, `tsvector` maintenance on every write, a
language/dictionary configuration decision per locale). Defaulting
localized-text promotion to plain generated columns keeps this consistent
with that precedent and with the general complexity-budget stance recorded
in `docs/anti-patterns.md` (favor the mechanism that is already proven
before reaching for a more complex one).

**Why plain-text alone does not suffice for every field, so `tsvector` is
kept as an explicit opt-in rather than excluded.** `0023` itself names the
case `tsvector` exists for: "where real full-text search is wanted" —
ranked relevance across stemmed word forms in a specific language, the
kind of search BilimBaga's own motivating use case (searching a
kk/ru/en-localized question bank by content, not just filtering by an exact
value) plausibly needs for at least the field carrying a question's `stem`.
A plain generated text column, matched with `ILIKE '%...%'` the way
`Definitions.search/2` does, cannot rank results, cannot match "ran" against
"running," and forces a leading wildcard that defeats a plain B-tree index
under real query volume. Excluding `tsvector` outright would leave no
mechanism to build a genuinely good search experience against localized
entity content — a plausible, named need, not a hypothetical one — so a
concrete, working option must exist for the field that needs it.

**Why the choice is per-field and definition-level, not a single global
policy.** The two options are not interchangeable defaults for the same
data — most localized-text fields (a short label, a `explanation` aside) do
not need ranked search and would only pay `tsvector`'s per-locale GIN-index
and write-time-maintenance cost for nothing; the one or two fields a
definition author actually wants full-text search on should not be
constrained by whatever default was chosen for every other field in the
system. This mirrors `0023`'s own promotion-trigger design, which is
already definition-declared and per-field (`queried: true` is set per
field, not globally) — a per-field `search_strategy` attribute is the same
shape of mechanism applied to a narrower question, not a new pattern.

## Consequences

- **REQ-298** implements `ON DELETE RESTRICT` (Ecto `on_delete: :restrict`)
  on every promoted-FK-column `REFERENCES` constraint the DDL generator
  emits. It does not choose between options — this record already has.
- **REQ-301** implements both plain-text and `tsvector` generated-column
  shapes for localized-text promotion, selected by a per-field
  `search_strategy` attribute (`:plain` default, `:fulltext` opt-in) read
  from the entity definition, and must validate that attribute's presence
  the same way `0023`'s `foreign_keys`/`queried` triggers are already
  validated for field-coverage today.
- **This record is independent of
  [`0024-entity-promotion-ddl-execution.md`](0024-entity-promotion-ddl-execution.md)
  (REQ-295), with no ordering dependency in either direction.** `0024`
  answers *how* a promotion's DDL is executed per tenant — the mechanism,
  partial-failure semantics, backfill strategy, and rollback story for
  applying whatever DDL text is generated. This record answers *what that
  DDL text says* for two specific column shapes — the `ON DELETE` clause on
  a promoted FK's `REFERENCES`, and whether a localized-text column is
  plain or `tsvector` — properties of the DDL text itself, not of the
  execution mechanism that applies it. Neither record's decision
  constrains or is derived from the other's; REQ-296's DDL generator
  (built against `0024`'s lineage) is the single place both answers are
  consumed, but the answers themselves do not compose with `0024`'s four
  DDL-execution sub-questions. `0024`'s own "Consequences" section is not
  amended by this record — `0024` never claimed these two column-semantics
  questions as part of its own scope.
- **No change to `0023-entity-storage-hybrid.md`.** Its "Open question"
  section names only the DDL-execution question `0024` answers; this record
  does not touch that file (confirmed via `git diff`, see completion
  report).
- **`docs/anti-patterns.md`** is not amended by this record — no rejected
  approach was tried and discarded here; both sub-answers are the accepted
  mechanism on the first pass.

## What this record does not decide

- **How a promotion's DDL — including the `ON DELETE` clause and the
  generated-column shape this record names — is executed per tenant, its
  partial-failure semantics, backfill strategy, or rollback story.** That
  is `0024`'s scope entirely; this record does not reopen or restate it.
- **The entity-storage shape, the promotion rule, additive-only/demotion-
  forbidden, or the entity-vs-blob test.** `0023` decided all of these;
  unchanged here.
- **The concrete field name, type representation, or validation function
  signature for `search_strategy`, beyond naming it and its two legal
  values.** REQ-301's own design is where that attribute's exact shape
  inside `Definition.t()`'s field schema is specified in full, consistent
  with this record's decision.
- **Which specific fields in any concrete entity definition (BilimBaga's or
  otherwise) should set `search_strategy: :fulltext`.** That is a
  per-definition authoring choice this record makes possible, not one it
  makes on any definition's behalf.
- **Anything about the engine, tenancy, or non-entity-storage subsystems.**
  Unchanged.

## SECURITY-REVIEWER sign-off

(Pending. Stated interest per REQ-302: the `ON DELETE` choice's
cross-tenant/data-loss implications specifically — whether the chosen
clause either orphans referencing rows or risks cascading data loss across
a tenant-isolated table in a way that would be hard to audit after the
fact.)

## REVIEWER sign-off

(Pending. Stated interest per REQ-302: idiom consistency — whether the
chosen `ON DELETE` behavior and localized-text column strategy fit the
soft-delete and full-text-search idioms already established elsewhere in
the codebase.)
