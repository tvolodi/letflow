# ISS-0623 design — emit `CREATE INDEX` for `Definition.t()`'s `:indexes`

GitHub #1308 / letflow-queue task 623. Fix for the root cause ISSUE-FIXER
diagnosed (see the ORCH-supplied ISSUE-FIXER handoff for this branch — not
reproduced verbatim in this doc; the citations below are this design's own
re-verification of that handoff's claims against the current tree) and
re-verified against the current tree while writing this design (2026-09-13,
branch `issue/ISS-0623-20260913`, based on `main` at `d2b61548`):

- `Letflow.Entities.Definition.DDL.generate_table_ddl/3`
  (`lib/letflow/entities/definition/ddl.ex:140-153`) never reads
  `definition.indexes` and never emits `CREATE INDEX`. Confirmed: the
  function's own `with` chain only touches `promoted_columns/1`,
  `structural_columns/0`, `unique_constraint_clauses/1`, and
  `enum_check_constraints/2`. `build_create_table_sql/4`
  (`ddl.ex:508-520`) only assembles `PRIMARY KEY`, `UNIQUE ("record_id")`,
  enum `CHECK`s, and `unique_constraint_lines` — no index text anywhere.
- `Letflow.Entities.Definition.Validator` (Rule 4,
  `validator.ex:326-360`, `index_field_coverage_violations/1`) fully
  validates `:indexes` (each field must exist in `:fields` and be
  `queried: true`) and Rule 2 (`duplicate_name_violations/1`,
  `validator.ex:286-293`) checks name-uniqueness *within* one document's own
  `:indexes` list. `@max_indexes 32` (`validator.ex:63`) caps cardinality.
  Nothing in this module rejects an `:indexes` entry whose `:fields` include
  a `:localized_text`-typed field — a gap this design's §5 addresses
  defensively at the DDL layer, not by changing the Validator (see §5 for
  why).
- `Letflow.Entities.Definition.t()`'s `:indexes` field
  (`lib/letflow/entities/definition.ex:28,69-73`) is persisted verbatim
  through both ingestion paths (`Letflow.Routers.Entities`,
  `Letflow.Definitions.SolutionPack`) — confirmed no transform/strip step
  touches it.
- The one caller of `generate_table_ddl/3` is
  `Letflow.TenantProvisioning.create_and_populate_entity_table/3`
  (`tenant_provisioning.ex:1417-1440`), itself called only from
  `ensure_entity_table/2` (`tenant_provisioning.ex:1386-1396`), itself
  called only from `do_run_column_promotion/2`
  (`tenant_provisioning.ex:1293-1322`), itself called only from
  `run_column_promotion/1` (`tenant_provisioning.ex:1280-1291`). This whole
  chain runs inside **one** `Repo.transaction/1`, with a per-schema
  `pg_advisory_xact_lock` taken first (`run_column_promotion/1`,
  lines 1283-1287). §2 below depends on this fact.
- `run_constraint_activation/1` (`tenant_provisioning.ex:1943-1999`) is the
  named prior art for a *retrofit* path (`constraint_def` → unique index,
  added after a table already exists) — confirmed to exist; nothing
  equivalent exists for `index_def`. See §6.
- Decision `0023-entity-storage-hybrid.md` (line 127): *"nothing creates a
  Postgres index from [`indexes`]"* — names this exact gap as pre-existing
  and unresolved by that record; line 264-265 states only `constraint_def`
  activation ("a Postgres unique index is created from it") as a decided
  consequence. This design is the first to resolve the `indexes` half.
- `docs/anti-patterns.md`'s Ecto-index-naming entry (line 2087) confirms
  index names are schema-scoped and collisions/oversized names are
  invisible to a plain migration replay — informs §4's reasoning, though
  that entry is about `Ecto.Migration`'s naming defaults, a different
  mechanism from this module's author-declared names.

No implementation code below. Signatures, return-value shapes, and the
concrete mechanism only, per this project's CODE-DESIGNER contract.

## 1. Emission shape — new sibling function, `generate_table_ddl/3` unchanged

**Decision: do not change `generate_table_ddl/3`'s return contract.** Add a
new public function to `Letflow.Entities.Definition.DDL`:

```
@type index_ddl_error ::
        DDL.ddl_error()
        | {:unsupported_index_field_type,
           index_name: String.t(), field: String.t(), type: Definition.field_type()}

@spec index_create_statements(
        definition :: Definition.t(),
        table_name :: String.t()
      ) :: {:ok, [String.t()]} | {:error, index_ddl_error()}
```

Returns one complete, standalone `CREATE INDEX "<name>" ON "<table_name>"
(<fields>)` (or `CREATE UNIQUE INDEX` when `index_def.unique` is true)
statement per entry in `definition.indexes`, in `definition.indexes`'s
declared order, over **unqualified** `table_name` (same convention
`generate_table_ddl/3` already uses — schema-qualification is the caller's
job, §2). Empty list (`{:ok, []}`) when `definition.indexes` is absent or
`[]`.

**Why a new function instead of widening `generate_table_ddl/3`'s return
value (e.g. to a map or 3-tuple):**

- `CREATE INDEX` cannot be inlined into the `CREATE TABLE (...)` column/
  constraint list the way `UNIQUE (...)`/`CHECK (...)` can (Postgres syntax
  requires a separate statement), and `Repo.query!/1` cannot execute two
  statements joined by `;` in one call (Postgrex's extended/prepared-
  statement protocol accepts exactly one command per query — confirmed by
  this module's own existing single-statement-per-`Repo.query!` calls
  throughout `tenant_provisioning.ex`). So the caller needs the CREATE TABLE
  text and the CREATE INDEX texts as **separate strings it executes in
  separate calls**, in order, regardless of what shape carries them.
- Given that, widening `generate_table_ddl/3`'s own return value (to
  `{:ok, {create_table_sql, index_sqls}}` or `{:ok, %{create_table: ..,
  create_indexes: ..}}`) would silently break every one of the **16**
  existing `DDL.generate_table_ddl(...)` call sites in
  `test/letflow/entities/definition/ddl_test.exs` that do `assert {:ok,
  sql} = DDL.generate_table_ddl(...)` then assert against `sql` (across
  **31** `sql =~ "..."` content assertions in that file) — `sql` would stop
  being a bare string, and every such assertion would need rewriting for a
  change that is, at its core, additive (a new DDL statement kind), not a
  change to what `generate_table_ddl/3` already correctly does for `CREATE
  TABLE`.
- `unique_constraint_clauses/1` (`ddl.ex:417-432`) is the direct precedent
  for exactly this shape: a sibling public function, independent of
  `generate_table_ddl/3`'s own return value, that both the fresh-`CREATE
  TABLE` path (folded inline, since `UNIQUE (...)` *can* be inlined) and the
  retrofit path (`run_constraint_activation/1`, issuing a separate `ALTER
  TABLE ... ADD <clause>`) call. `index_create_statements/2` is the same
  pattern, one step further: it cannot be folded inline at all, so both its
  callers (the fresh path, §2; a future retrofit path, §6, out of scope)
  call it and get back complete, standalone statements.
- Net result: **zero existing `ddl_test.exs` assertions break.**
  `generate_table_ddl/3`'s `@spec`, moduledoc, and every current test
  keep compiling and passing unchanged. TEST-DESIGNER adds a new
  `describe "index_create_statements/2"` block plus the real-Postgres
  `pg_indexes` assertion (§7) — it does not have to touch any of the
  16 existing `DDL.generate_table_ddl(...)` call sites or their 31
  `sql =~ "..."` assertions.

### Identifier validation (mirrors `unique_constraint_clause/1`'s posture)

For each `index_def`, `index_create_statements/2` validates via
`valid_identifier?/1` (already public):

- `index_def.name` → `{:error, {:invalid_identifier, field: :index_name,
  value: name}}` on failure. (`ddl_error/0`'s `field:` enum gains
  `:index_name` and `:index_field` alongside the existing `:table_name |
  :attribute | :constraint_name | :constraint_field`.)
- every entry of `index_def.fields` → `{:error, {:invalid_identifier,
  field: :index_field, value: field_name}}` on the first invalid one
  (`Enum.find`, same short-circuit style `check_constraint_field_identifiers/1`
  already uses — never silently drops a malformed index).

This validation is defence-in-depth exactly like the rest of this module's
identifier checks — the Validator's Rule 1/Rule 2 name-format checks are the
real gate; this is the same independent, non-bypassable second check
`ddl.ex`'s moduledoc already commits to for every other identifier it
splices into SQL text.

### SQL text shape

```
CREATE INDEX "<index_def.name>" ON "<table_name>" ("<field_1>", "<field_2>", ...)
```

or, when `index_def.unique == true`:

```
CREATE UNIQUE INDEX "<index_def.name>" ON "<table_name>" ("<field_1>", ...)
```

Field order is `index_def.fields`'s declared order (index column order is
semantically meaningful for a Postgres index's usefulness on range/prefix
queries — never reordered or deduplicated by this function).

## 2. Caller wiring — `create_and_populate_entity_table/3`

`create_and_populate_entity_table/3` (`tenant_provisioning.ex:1417-1440`)
gains one more `with`-chain step, after the existing `execute_create_table`
step and before the `Projector.rebuild_projection/2` call:

```
with {:ok, definition} <- Definitions.get_active_definition_by_name(entity_type, schema_name),
     document = document_from_persisted(definition),
     {:ok, fk_target_tables} <- resolve_fk_target_tables(document),
     {:ok, sql} <- DDL.generate_table_ddl(document, table_name, fk_target_tables),
     :ok <- execute_create_table(qualify_create_table_sql(sql, schema_name, table_name, fk_target_tables)),
     {:ok, index_sqls} <- DDL.index_create_statements(document, table_name),
     :ok <- execute_create_indexes(schema_name, table_name, index_sqls) do
  # ...Projector.rebuild_projection/2 unchanged...
end
```

New private helpers, same shape/conventions as the existing
`execute_create_table/1` and `qualify_create_table_sql/4`:

```
@spec qualify_index_create_sql(sql :: String.t(), schema_name :: String.t(), table_name :: String.t()) ::
        String.t()
```
Replaces the unqualified `ON "<table_name>"` substring with `ON
"<schema_name>"."<table_name>"` in one statement — same substring-replace
technique `qualify_create_table_sql/4`/`qualify_fk_references/3` already use
(the `ON "<table_name>"` substring is unique within a single `CREATE INDEX`
statement, so this is unambiguous per-statement).

```
@spec execute_create_indexes(schema_name :: String.t(), table_name :: String.t(), index_sqls :: [String.t()]) ::
        :ok | {:error, {:ddl_failed, Exception.t()}}
```
Qualifies and issues each statement via `Repo.query!/1` in declared order,
`reduce_while`-short-circuiting on the first failure — same
rescue-into-`{:ddl_failed, exception}` shape `execute_create_table/1`
already uses, so it composes into the existing `with`/`else` error handling
in `create_and_populate_entity_table/3` (and, one level up,
`do_run_column_promotion/2`'s existing `{:error, {:ddl_failed, exception}}
-> mark_ddl_failed_and_return(...)` clause) with **no new error shape**
surfacing at `run_column_promotion/1`'s own `@spec` — `{:ddl_failed,
Exception.t()}` already covers it.

`{:error, index_ddl_error()}` from `DDL.index_create_statements/2` itself
(an invalid identifier or an unsupported-field-type index, §5) flows
straight out of the `with` chain unreachable-in-practice, same posture (and
same narration) `create_and_populate_entity_table/3`'s existing comment
already gives for `generate_table_ddl/3`'s own `{:error, ddl_error()}` case
— `table_name` and every field name here already passed
`Letflow.Entities.Definition.Validator`'s identical name-format check at
definition-creation time.

### Atomicity — no new rollback logic needed, and why

`run_column_promotion/1` wraps the entire call chain in one
`Repo.transaction/1` (line 1283-1287). Postgres's `CREATE TABLE`/`CREATE
INDEX` are both transactional DDL. If `execute_create_indexes/3` fails
partway (e.g., index #3 of 5 hits a real Postgres error such as a name
collision, §4), two things hold, and both already fall out of Postgres's
own transaction semantics with **no additional code**:

1. A raised Postgres-level SQL error inside a transaction marks that
   transaction **aborted** — even though `execute_create_indexes/3` rescues
   the Elixir exception into an ordinary `{:error, {:ddl_failed, _}}`
   return value (not a re-raise, not `Repo.rollback/1`), Postgres itself
   refuses every subsequent statement on that connection
   ("current transaction is aborted") and, critically, **turns the eventual
   `COMMIT` into an implicit `ROLLBACK`** when `Repo.transaction/1`'s
   function returns normally. This is Postgres's own behavior, not
   something this design adds.
2. Consequence: a mid-way `CREATE INDEX` failure rolls back the `CREATE
   TABLE` too — the table+all-its-indexes step is all-or-nothing "for
   free," identical in spirit to `execute_create_table/1`'s own existing
   failure handling, just extended to cover the statements after it in the
   same transaction. `entity_table_exists?/2`'s check
   (`ensure_entity_table/2`, line 1390) will then correctly see "no table"
   on any retry and re-attempt `create_and_populate_entity_table/3` from
   scratch — no partial-table state to reconcile, no separate cleanup step.

State this explicitly in `create_and_populate_entity_table/3`'s own
comment (mirroring the module's existing narration style) so a future
reader does not assume a missing explicit rollback is an oversight.

## 3. Unique-index vs. unique-constraint duplication — always emit both, no de-duplication

**Decision: `index_create_statements/2` always emits every declared
`index_def` verbatim, regardless of whether an `index_def{unique: true}`'s
field list exactly matches (or overlaps with) a `constraint_def`'s field
list.** No cross-referencing between `definition.indexes` and
`definition.constraints` is added.

**Reasoning:**

- Postgres tolerates a redundant index without error or corruption — two
  unique indexes covering the same or overlapping column set both work
  correctly; the only cost is extra storage and a marginally slower write
  path (an extra index to maintain), never a correctness problem.
- `index_def` and `constraint_def` are, by this module's own existing
  design, two **independent** declarations (this is not a discovery of this
  design — `Letflow.Entities.Definition.t()` already models them as two
  separate optional lists with no shared identity, and neither
  `Letflow.Entities.Definition.Validator` nor `ddl.ex` today cross-references
  one against the other for any other reason). Inventing a field-list
  equivalence check here (deciding, e.g., whether `fields: ["a", "b"]`
  counts as "the same" as `fields: ["b", "a"]`, or whether a constraint
  covering a superset of an index's fields should suppress it) is new
  cross-cutting logic with its own set of judgment calls this bug fix does
  not need to make to unblock REQ-327 — introducing it now would be scope
  creep relative to "emit the index that was never being emitted at all."
- An author who declares both a `constraint_def{type: :unique, fields:
  [...]}` and an `index_def{unique: true, fields: [...]}` over the same
  columns did so deliberately (the constraint for the *uniqueness
  guarantee itself* — e.g. `question_tags`' pair-uniqueness in decision
  0023 — the index, separately, for a query-performance need that happens
  to want the same column order) — silently dropping one because it looks
  redundant would be second-guessing an explicit author decision the same
  way this project's "don't silently re-decide" directive already warns
  against for decision records.

If a real duplicate-declaration problem is later found in practice (e.g. an
author accidentally declaring the exact same field list twice across the
two lists), that is a Validator-level authoring-hygiene rule (a new,
numbered rule in `Letflow.Entities.Definition.Validator`, requiring its own
sign-off per REQ-225's precedent), not a DDL-emission-time suppression
decision — noted here as a candidate follow-on, not decided by this design.

## 4. Index-name collision across entity types in one tenant schema — scoped out, with a loud-failure guard as the only new mechanism

**Decision: no new pre-emptive cross-entity-type index-name-uniqueness
check is added by this design.** This is scoped out as a documented known
gap, for a dedicated follow-on requirement, for these reasons:

- Doing this *correctly* — reject a colliding name **before** a bad
  definition is even persisted, across every *other active* entity type's
  `definition.indexes` in the same tenant — needs a capability that does
  not exist today: a query, scoped by `tenant_id`, over every other active
  `entity_definitions` row's `indexes` list, from
  `Letflow.Entities.Definitions` (REQ-226's context module — the only
  module with both tenant scoping and cross-definition visibility;
  `Letflow.Entities.Definition.Validator` explicitly takes no `tenant_id`
  and performs no cross-definition lookups, per its own moduledoc, and
  `ddl.ex`'s moduledoc is equally explicit that it has "no tenant/schema
  awareness at all" — neither module is the right place, and widening
  either one's stated invariants is a decision-record-level change, not a
  bug-fix-level one).
- That query also has to answer a question this design does not need to
  answer to fix ISS-0623: does it check only *other active* definitions, or
  also definitions whose per-tenant table was already provisioned but whose
  definition was later superseded/deactivated (a live `pg_indexes` name
  that a Validator-level, `entity_definitions`-only query would not see)?
  Answering that correctly needs its own design pass.
- **Nothing in the codebase today declares two colliding index names
  across two entity types in the same tenant** — this is a risk this fix
  makes *possible to trigger* (since indexes now actually execute), not a
  reported failure in current pack content. REQ-327's five exam indexes are
  new, author-controlled content (see §6) where a reviewer/REQ-ANALYST can
  eyeball for collisions against REQ-326's five already-authored
  definitions in the interim, the same way any two sibling requirements
  landing index/constraint names today already rely on human-equivalent
  (agent) review discipline before a dedicated mechanism exists.

**What this design does add, as the one new, cheap, in-scope mechanism:**
`execute_create_indexes/3` (§2) does **not** pre-check for an existing
index of the same name before issuing `CREATE INDEX` — unlike
`run_constraint_activation/1`'s `constraint_exists?/3` idempotent-skip
check, no idempotent-skip is needed here, because (per §2's atomicity
argument) `create_and_populate_entity_table/3` only ever runs once per
`(tenant, entity_type)` — successfully creating the table means
`entity_table_exists?/2` short-circuits every future call, and a failed
attempt rolls back entirely, so there is no "already applied, skip" case to
detect, unlike `ColumnPromotion`/`ConstraintActivation` rows which are
independently retried per-tenant over time by design. If `CREATE INDEX`
collides with a name already present in that schema (from another entity
type's table, created earlier), Postgres raises `ERROR: relation "<name>"
already exists` **unmodified and unswallowed** — `execute_create_indexes/3`
rescues it into the same `{:error, {:ddl_failed, exception}}` shape every
other DDL failure in this module already uses, which `mark_ddl_failed_and_return/3`
records with the real Postgres error text in `last_error`. This satisfies
"do not silently namespace/rename the author-declared index name — fail
loud instead" without requiring the larger cross-tenant-visibility query
above. **This is the load-bearing answer to the question the ISSUE-FIXER
handoff raised: the declared name is always the real name; a collision is a
loud, attributable DDL failure, never a silent rename and never a silently
swallowed success.**

**Follow-on to file** (do not implement here): a new requirement, owned by
REQ-ANALYST/CODE-DESIGNER, adding a cross-entity-type index/constraint-name
uniqueness check to `Letflow.Entities.Definitions`' definition-create/
activate path, scoped by `tenant_id`, covering both `indexes` and
`constraints` (the same collision class exists for `constraint_def` names
today and is equally unhandled — confirmed by reading
`run_constraint_activation/1`'s own comments, which describe no such
pre-check either).

## 5. `:localized_text` fields in an `index_def` — defensive rejection at the DDL layer, not the Validator

**New finding from this design's own review** (not named by the ISSUE-FIXER
handoff, but directly load-bearing for `index_create_statements/2`'s
correctness): `Letflow.Entities.Definition.Validator` Rule 4
(`index_field_coverage_violations/1`) accepts an `index_def` naming a
`:localized_text`-typed field, as long as that field is `queried: true`
(Rule 4 has no type exclusion — unlike Rule 3, which excludes `:json`).
But a `:localized_text` field never promotes to a single column named
`field.name` — it promotes to N generated columns, one per locale
(`"#{name}_#{locale}"`, `localized_text_column_specs/1`,
`ddl.ex:329-345`). A naive `CREATE INDEX ... ("<name>")` for such a field
would reference a column that does not exist, failing at execution time
with `ERROR: column "<name>" does not exist` — the same class of
silently-broken-until-runtime defect this whole issue is about, one level
deeper.

**Decision:** `index_create_statements/2` checks, for every field named by
every `index_def`, whether that field is `:localized_text`-typed in
`definition.fields`; if so, returns `{:error, {:unsupported_index_field_type,
index_name: index_def.name, field: field_name, type: :localized_text}}`
rather than emitting SQL that references a nonexistent column. This is a
defence-in-depth guard at the DDL layer (same posture as
`valid_identifier?/1`'s own independent-of-Validator check) — it does
**not** change `Letflow.Entities.Definition.Validator`, which is a separate
module/requirement (REQ-225/REQ-301) whose rule set is not this design's to
extend without its own sign-off, per this project's "don't silently
re-decide what a decision record already settled" directive.

**Out of scope for this design:** actually making a `:localized_text`
field indexable (e.g. one index per locale-column, or a composite
expression index over all locales) is a feature, not a bug fix — flagged
here as a second candidate follow-on requirement (distinct from §4's),
since it needs its own design decision about which locale-column(s) an
index should cover and in what form.

**Confirmed not to affect REQ-327 or any currently-shipped pack content:**
`priv/packs/bilimbaga/entity_definitions/*.json` (the only currently-authored
pack content with `indexes`, confirmed by `grep` while writing this design)
declares no `:localized_text`-typed indexed field today. REQ-327's five exam
entity definitions do not exist on disk yet (REQ-327 is `status: pending`
in `docs/requirements.yaml` at the time of writing) — this guard exists so
that if REQ-327 (or any future pack content) ever declares one, it fails
loudly and immediately with a clear, attributable error, rather than
producing broken SQL text that only fails deep inside a provisioning run.

## 6. Retrofit path (`index_def` added to an already-promoted entity type) — out of scope, named follow-on

**Decision: out of scope for this design.** No `IndexActivation`
schema/`register_index_activation/3`/`run_index_activation/1` analog to
`ConstraintActivation`/`run_constraint_activation/1` is designed here.

**Reasoning:**

- The fresh-`CREATE TABLE` path alone (§1-§2) unblocks every currently
  identified need: REQ-327's five exam entity definitions are **new**
  entity types being authored for the first time via
  `priv/packs/bilimbaga/entity_definitions/` — every index they declare
  ships as part of that entity type's *initial* definition, read by
  `create_and_populate_entity_table/3` the first time any column promotion
  (or table-creation trigger) runs for that type in a given tenant, which
  is before the table exists at all. Since `definition.indexes` is read
  fresh at that moment (not gated by, or tied to, which specific attribute
  triggered the promotion that caused table creation — `create_and_populate_entity_table/3`
  already builds the table's **full current** promoted-column set
  regardless of which one attribute's promotion triggered it, per its own
  existing comment at `tenant_provisioning.ex:1398-1405`), every index
  declared on the definition at that moment is emitted, regardless of
  per-attribute promotion ordering.
- **This is stated as the fix's scope-sufficiency claim, not as an
  independently re-verified fact about REQ-327's specific content** —
  REQ-327 has `status: pending` in `docs/requirements.yaml` and its five
  entity-definition JSON files do not exist on disk as of this writing, so
  the ISSUE-FIXER handoff's claim that "REQ-327's five exam indexes are all
  declared at initial entity-type creation" could not be verified against
  actual file content; it was re-derived here as a **structural** claim
  about how *any* new entity type's indexes reach the DDL layer (there is
  today no other path by which an `index_def` enters `definition.indexes`
  than being present at the definition's own creation/authoring time — packs
  and `Letflow.Routers.Entities` both persist the document verbatim, with
  no separate "add an index to an existing definition" mutation path found
  in either), not a fact re-derived from REQ-327's own not-yet-written
  content.
- A genuine retrofit case — an index added to `definition.indexes` for an
  entity type whose per-tenant table(s) **already exist** — is real and
  will eventually need `run_index_activation/1`, but is a separately-sized
  piece of work with its own design questions this fix does not need to
  answer to unblock REQ-327: whether `CREATE INDEX CONCURRENTLY` is
  required (a non-empty existing table makes a blocking `CREATE INDEX`
  lock writes for the index-build's duration — a fresh, empty table, this
  design's only case, has no such concern), how that interacts with the
  existing per-schema `pg_advisory_xact_lock` (a `CONCURRENTLY` build
  cannot run inside the same transaction that holds the lock — Postgres
  forbids `CREATE INDEX CONCURRENTLY` inside a transaction block at all),
  and per-tenant partial-failure tracking mirroring
  `ConstraintActivation`'s shape. Each of these is exactly the kind of
  question REQ-298's own dedicated design effort answered for
  `constraint_def` retrofit — `index_def` retrofit deserves the same
  dedicated treatment, not a folded-in answer here.

**Follow-on to file:** a new requirement (parallel to REQ-298, sized
similarly) adding `IndexActivation` + `register_index_activation/3` +
`run_index_activation/1`, explicitly deciding the `CONCURRENTLY` question
above.

## 7. Secondary finding — FK constraint names never emitted (confirmed present, explicitly out of scope here)

Re-verified against `column_sql_line/2` (`ddl.ex:536-563`): the
`REFERENCES` clause built at line 553
(`base <> ~s| REFERENCES "#{target_table}"("record_id") ON DELETE RESTRICT|`)
never mentions `fk_def.name` anywhere — it is an unnamed inline column
constraint, so Postgres auto-generates its own constraint name
(`"<table>_<column>_fkey"`) rather than using the author-declared
`fk_def.name`. `fk_def.name` is validated by `Letflow.Entities.Definition.Validator`
(Rule 2, `duplicate_name_violations/1`, scope `:foreign_keys`) but never
read by `ddl.ex` for any emission purpose. **This is confirmed present and
real, but is a separate, narrower defect from ISS-0623's indexes gap — not
folded into this design or its fix.** Flagging here, as instructed, as a
candidate follow-on issue for REQ-ANALYST/ORCH to file separately (working
title: "FK constraint names are validated but never applied to the emitted
`REFERENCES` clause — Postgres's auto-generated name is used instead of the
author-declared one").

## 8. Summary of every change surface this design authorizes

| File | Change |
|---|---|
| `lib/letflow/entities/definition/ddl.ex` | New public `index_create_statements/2`; `ddl_error/0`'s `field:` enum gains `:index_name`/`:index_field`; new `index_ddl_error/0` type adding `{:unsupported_index_field_type, ...}`. `generate_table_ddl/3` itself: **no change** to its `@spec`, behavior, or existing tests. |
| `lib/letflow/tenant_provisioning.ex` | `create_and_populate_entity_table/3` gains two `with`-chain steps (`DDL.index_create_statements/2`, `execute_create_indexes/3`); two new private helpers (`execute_create_indexes/3`, `qualify_index_create_sql/3`) mirroring `execute_create_table/1`/`qualify_create_table_sql/4`'s existing shape. No change to any function's public `@spec` — `{:ddl_failed, Exception.t()}` already covers the new failure mode. |
| `docs/anti-patterns.md` | Not required by this fix, but TEST-DESIGNER/REVIEWER should consider adding an entry once the real-Postgres test (§below) is written, noting that DDL-text-only assertions would not have caught this class of bug (index text was simply absent, not malformed) — matching this doc's own existing "verified against real Postgres, not DDL text" discipline already stated for FK/REFERENCES behavior. |

## 9. Test requirement (for TEST-DESIGNER — not designed in full here, scope only)

Per the ISSUE-FIXER handoff's instruction, DDL text alone is insufficient
evidence. At minimum, TEST-DESIGNER's coverage must include:

1. Unit tests for `index_create_statements/2` (pure, `async: true`, no
   `Repo`) — exact SQL text for a plain index, a `unique: true` index,
   multi-field field order preservation, the `:invalid_identifier` cases
   (bad index name, bad field name — mirroring the existing
   `unique_constraint_clauses/1` test shapes at `ddl_test.exs:391-415`),
   and the new `:unsupported_index_field_type` case for a `:localized_text`
   field (§5).
2. A real-ephemeral-Postgres test (same shape as
   `ddl_test.exs:629+`'s existing `describe` block: create a throwaway
   schema, run the generated `CREATE TABLE` then every
   `index_create_statements/2` statement against it, `on_exit` drops the
   schema) that queries **`pg_indexes`** (`SELECT indexname, indexdef FROM
   pg_indexes WHERE schemaname = $1 AND tablename = $2`) and asserts every
   declared `index_def` produced a real, matching row — including that a
   `unique: true` index's `indexdef` contains `CREATE UNIQUE INDEX`.
3. An integration-level test exercising
   `TenantProvisioning.create_and_populate_entity_table/3` (or its nearest
   already-tested public entry point, `run_column_promotion/1`, against a
   definition whose `indexes` is non-empty) against a real provisioned
   tenant schema, asserting via `pg_indexes` (schema-qualified this time)
   that the index exists in the tenant's actual schema, not just an
   ephemeral throwaway one — this is the test that would have caught
   ISS-0623 directly, since the unit-level DDL-text tests alone did not
   (the bug was never about malformed SQL text; it was about a statement
   never being generated or executed at all).
4. A test demonstrating §4's loud-failure behavior: two entity types in the
   same tenant schema declaring an `index_def` with the same `name` — the
   second entity type's `create_and_populate_entity_table/3` call must
   return `{:error, {:ddl_failed, %Postgrex.Error{}}}` (or equivalent),
   never a silent success and never a silently renamed index — confirmed
   via `pg_indexes` still showing only the first entity type's index under
   that name.
