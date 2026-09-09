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

**Status: PASS** (2026-09-09, `SECURITY-REVIEWER`, REQ-302).

**Scope note.** This is a design-time review — no `lib/` code or
`priv/repo/migrations/*.exs` exists yet implementing this record (REQ-298
builds it later). The diff under review (`git diff main...HEAD`) touches
only this decision record and a `docs/requirements.yaml` status line, no
migration or schema module. By the literal scope test, INV-1 is therefore
NOT-APPLICABLE to *this diff*. This review nonetheless assesses the
record's proposed `ON DELETE` semantics on their merits, per REQ-302's own
initiative-invocation of this gate, because REQ-298 is stated to implement
this record's DDL choice verbatim — the correctness of the choice matters
now, even though no code exists yet to run INV-1's mechanical checks
against.

**INV-1 (tenant data isolation) — assessed on the design's merits, not
mechanically checkable (no code yet).** No cross-tenant FK reference is
proposed anywhere in this record. Every promoted-FK-column table is a
per-entity-type table living inside its own tenant's schema (per `0023`);
the record's own CASCADE-rejection reasoning explicitly frames the blast
radius as "every other entity-type table across the tenant schema" —
singular, intra-tenant. Nothing in either sub-question's decision or
reasoning proposes, or leaves open, a `REFERENCES` constraint that crosses
a tenant schema boundary. No INV-1 violation exists in this design.

**Checklist verification:**

1. **Central claim confirmed by direct read.** `Letflow.Entities.Records.delete_record/2`
   (`records.ex:199-219`) never issues a SQL `DELETE`. It resolves the
   existing row via `fetch_existing_record/3`, and — when not already
   `deleted` — runs the shared `run_command/2` pipeline
   (`records.ex:225-242`), which appends an `ENTITY_RECORD_DELETED` event
   and calls `upsert_record_latest/3`. That function's `:update`/`:delete`
   clause (`records.ex:289-298`) does
   `ctx.existing_record |> Latest.update_changeset(%{..., deleted: kind == :delete, ...}) |> repo.update(prefix: ctx.prefix)`
   — a genuine `UPDATE ... SET deleted = true, ...`, never a `DELETE FROM`.
   The referenced row stays physically present. The record's claim that
   `ON DELETE` is inert on the application's own delete path is accurate,
   read from source, not asserted.

2. **RESTRICT's failure mode is genuine Postgres behavior and is stated
   explicitly, not just asserted.** For a `REFERENCES ... ON DELETE
   RESTRICT` constraint, Postgres refuses the referencing-row-holding
   hard `DELETE` outright, raising `foreign_key_violation` (SQLSTATE
   23503) synchronously at the statement that attempted it — this is
   standard, well-defined Postgres FK-action semantics, correctly
   characterized. The record states this consequence explicitly rather
   than only asserting safety: "makes the database refuse a hard `DELETE`
   against any referenced row for as long as a referencing row exists,"
   and cites the established in-codebase idiom framing this exact
   behavior as "fails loudly rather than [failing] unreachable in
   practice" / "fails loudly instead of silently losing tenant data." An
   out-of-band hard `DELETE` against a referenced row produces a loud,
   auditable database error (an exception the caller must handle), not
   silent data loss — this is the correct, safer failure mode for the
   stated threat model.

3. **NO ACTION's rejection is explicit, not hand-waved, and correctly
   reasoned.** The record names NO ACTION as "close but not chosen,"
   correctly identifies its only semantic difference from RESTRICT
   (deferrability to end-of-statement/end-of-transaction, relevant only
   for cyclic or intra-statement FK graphs), and states plainly that
   "nothing in `0023`'s promoted-column shape creates such a cycle" (a
   join entity has two FKs to two *different* tables, not a self-cycle) —
   so deferred checking buys nothing here, and RESTRICT's immediate
   failure is preferred as "the stronger and simpler guarantee." This
   directly satisfies REQ-302's stated concern: the record does not
   silently let NO ACTION's semantics apply by omission (Ecto/Postgres
   default), it explicitly names and rejects that option with reasoning
   tied to this schema's actual FK topology.

4. **CASCADE is excluded outright, permanently, not just "not chosen" by
   default.** The record's own language: "`CASCADE` is excluded
   outright," with an explicit failure-mode trace — a hard `DELETE`
   against a referenced row would "silently remove every referencing row
   in every other entity-type table across the tenant schema," calling
   this "real, irreversible tenant data loss triggered by a single
   out-of-band statement, with no soft-delete recourse ... and no
   `entity_events` replay path." No residual CASCADE-like path (nor
   `SET NULL`'s silent-detach path, also explicitly rejected on
   audit-trail grounds) is left open anywhere in the Decision or
   Consequences sections. REQ-298 is instructed to implement `on_delete:
   :restrict` "verbatim" with no runtime choice point that could resolve
   to CASCADE.

5. **No cross-tenant FK proposed** — see INV-1 assessment above.

6. **Design-time scope, stated explicitly.** This review is against a
   decision record only; no code exists to compile, migrate, or run.
   Verification here is a source-level trace of the *current*
   `delete_record/2` implementation (checklist item 1) plus a reasoning
   audit of the record's own text (items 2-5) — not an executed test.
   REQ-298's actual migration and DDL generator will need their own
   SECURITY-REVIEWER pass when they land, to confirm the implementation
   matches this record's decision (in particular, that `on_delete:
   :restrict` is what the DDL generator actually emits, and that no
   promoted-FK migration is left with Ecto's implicit NO-ACTION default
   by omission).

**Verdict: PASS.** The `ON DELETE RESTRICT` choice is sound, its
failure-mode consequence (a loud, auditable Postgres constraint violation
on out-of-band hard `DELETE`, never silent) is stated explicitly rather
than merely asserted, the NO-ACTION alternative is explicitly considered
and correctly rejected for this schema's non-cyclic FK topology, CASCADE
is permanently and explicitly foreclosed, and no cross-tenant FK or other
INV-1 risk is introduced by this design.

## REVIEWER sign-off

**Status: PASS** (2026-09-09, `REVIEWER`, REQ-302).

**Scope note.** Same as SECURITY-REVIEWER's: this is a design-time review
of a decision record, `git diff --stat main...HEAD` shows only this file
and a `docs/requirements.yaml` status line — no `lib/letflow/entities/`,
no `lib/letflow/tenant_provisioning*`, no `priv/repo/migrations/` diff.
Review is against the record's proposed mechanisms' idiom fit, not
against code.

**1. `ON DELETE RESTRICT` fit — sound, independent of precedent framing.**
The exclusion reasoning for `CASCADE` (irreversible cross-table tenant
data loss with no `entity_events` replay path) and `SET NULL` (forces
nullability onto columns that model required references, silent
audit-trail-defeating detachment) and `NO ACTION` (deferrability buys
nothing against this schema's non-cyclic FK topology) each stand on their
own technical merits, independent of any precedent count.

**2. Precedent claim is real but overstated as stated — flagged, not
disqualifying.** I independently grepped `on_delete:` across
`lib/letflow/design/*.md` and `priv/repo/migrations/*.exs`. The three
citations (req043, req054, req211) are accurate quotes of real, matching
`:restrict` precedent using the same "fails loudly instead of silently
losing tenant data" reasoning. But the picture is more mixed than "the
established, repeated idiom for exactly this shape of FK" suggests:
`priv/repo/migrations/20260822000102_create_group_members_tenant_scoped.exs`
uses `on_delete: :nothing` on `user_id` for the *identical* "no delete
path exists anywhere in this codebase yet" shape — and its own header
comment (ISS-0225) flags this as untested territory rather than a
considered `:restrict` vs `:nothing` choice, i.e. an acknowledged,
open inconsistency in the codebase's own idiom, not a reconciled one.
The record should have surfaced this counter-example and either
distinguished it or noted the open inconsistency, rather than presenting
the three same-reasoning citations as if `:restrict` were uncontested for
this exact shape. The other `on_delete: :nothing` sites I found
(`instance_definition_snapshots.definition_id`,
`promotion_assertion_runs.review_id`) are genuinely distinguishable —
those reference rows that *are* actively deleted in practice (a
definition, a review), where `:nothing`/`:restrict`-would-block was the
live design question, unlike this record's "no delete path exists at
all yet" premise — so they are not counter-examples to the same shape.
Net: the citation is accurate but incomplete, and the "established,
repeated idiom" framing oversells uniformity that doesn't fully exist.
This does not change the verdict — per sub-question 1's own reasoning
(point 1 above), `RESTRICT` is the correct choice on its technical
merits regardless of how uniform the existing codebase actually is, and
the record's own reasoning doesn't rest on a headcount of precedent. Filed
as an idiom-fit observation the record's author (or a later reader
reconciling `group_members`) should know about, not a defect that
invalidates the decision.

**3. Full-text-search idiom fit — confirmed accurate, no missed
precedent.** `lib/letflow/definitions.ex:79-88` is exactly the `search/2`
moduledoc section cited, and its text ("adds zero new indexes (no
`idx_def_name`, no GIN/`tsvector` index)") is accurately characterized as
the sole existing full-text-search precedent, landing on the simple
option. `grep -rn "tsvector\|GIN" lib/ --include="*.ex"` returns only that
same moduledoc line — no other `tsvector`/GIN precedent anywhere in
`lib/` that this record should have reconciled against instead. The
record correctly treats `tsvector` as new territory for this codebase.

**4. Internal consistency — no accidental coupling found.** Sub-question
1 (`ON DELETE`) and sub-question 2 (`search_strategy` plain/`tsvector`)
are decided, reasoned, and consequenced entirely independently in the
record's text — neither the `RESTRICT` choice nor its reasoning
references localized-text columns, and neither the `:plain`/`:fulltext`
choice nor its reasoning references FK delete behavior. The
`Consequences` section states the independence explicitly and correctly
(REQ-298 and REQ-301 each consume one answer, with no cross-reference
between them). Matches the requirement's own "no compositional
relationship" framing.

**5. Decision-record consistency — confirmed, nothing re-decided.**
`git diff main...HEAD -- docs/migration/decisions/0023-entity-storage-hybrid.md`
and the equivalent for `0024` are both empty — neither prior record is
touched. `0025`'s "What this record does not decide" section correctly
disclaims re-opening `0023`'s promotion rule, additive-only/no-demotion
rule, and entity-vs-blob test, and correctly disclaims `0024`'s
DDL-execution mechanism, partial-failure semantics, backfill, and
rollback story. The two new decisions here (the `ON DELETE` clause,
and the plain-vs-`tsvector` per-field choice) are genuinely the two
questions `0023` left open (named explicitly in `0023`'s own text per
this record's Question section) and nothing more.

**6. Format — matches established shape.** Section order (Question,
Decision, Reasoning, Consequences, What this record does not decide,
SECURITY-REVIEWER sign-off, REVIEWER sign-off) matches `0023`/`0024`'s
own shape.

**7/8. `0024` untouched, scope clean.** `git diff main...HEAD -- docs/migration/decisions/0024-entity-promotion-ddl-execution.md`
is empty. `git diff --stat main...HEAD` shows only this record and a
`docs/requirements.yaml` status line — no `lib/letflow/entities/`, no
`lib/letflow/tenant_provisioning.ex`/`tenant_provisioning/`, no
`priv/repo/migrations/` diff.

**Verdict: PASS.** Both sub-decisions fit their respective established
idioms on independent technical merits. One precedent-citation gap noted
above (item 2) — the record's "established, repeated idiom" framing for
`ON DELETE RESTRICT` overlooks `group_members`'s `on_delete: :nothing`
counter-example of the identical "no delete path yet" shape (itself an
acknowledged open inconsistency, ISS-0225, not something this record
introduced) — but it does not change the correctness of the `RESTRICT`
choice, which is independently justified. No scope creep, no re-decided
question, no accidental coupling between the two sub-questions.
