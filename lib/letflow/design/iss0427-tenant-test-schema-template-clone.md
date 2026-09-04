# ISS-0427 — Tenant test-schema provisioning: clone from a prepared template

Status: design (WF-03 Step 2). Test-only. Does not change
`Letflow.TenantProvisioning.provision_tenant_schema/1` or `replay_migrations/2`
semantics, and does not add any new function reachable from the production
tenant-onboarding call path (see §7 "Production-path reachability" — a hard
requirement of this design, stated explicitly per ISSUE-FIXER's diagnosis §4
and the dispatch's scope-discipline instruction).

Supersedes nothing; implements ISS-0427 (MAJOR). Builds on, does not absorb,
ISS-0423 (parallelism/pool scope — untouched here).

## 0. Inputs this design treats as load-bearing facts, not re-derived

From `handoffs/WF03-ISS0427-20260904/step-01-issue-fixer-diagnosis.json`,
independently spot-verified below (see §0.1) rather than merely inherited,
per `docs/anti-patterns.md`'s "Inheriting a claim from a record instead of
re-deriving it from the source":

- Manifest is 53 tenant-scoped migrations today
  (`TenantProvisioning.tenant_scoped_migrations/0`), producing 39 tables in a
  fully-replayed schema (`@expected_tenant_tables` in
  `test/support/tenant_fixture.ex` currently lists a slightly different count
  under active development — ELIXIR-DEV must re-read it fresh, not trust a
  number baked into this doc; see §3's parity check, which reads it live
  rather than hardcoding a count).
- This session's own measurement (ISSUE-FIXER, compile-isolated,
  in-connection): replay avg 877.21ms, clone (bare `LIKE ... INCLUDING ALL`,
  no FK/sequence fix-up) avg 354.2ms. Ratio 2.5x. The filed 4.9x/2259ms
  figures do not reproduce today and are superseded by this session's
  numbers per the handoff's own MINOR issue note.
- `LIKE (...) INCLUDING ALL` copies: columns (name/type/nullability), CHECK
  constraints, PRIMARY KEY constraints, all indexes (verified count-equal:
  105/105 on the real schema), DEFAULT expressions (copied as literal SQL,
  not re-targeted).
- `LIKE (...) INCLUDING ALL` does NOT copy: FOREIGN KEY constraints (real
  schema: 22 template / 0 clone, confirmed). Does NOT create any sequence
  object in the destination schema (0 new `pg_sequences` rows), and any
  copied DEFAULT that references a sequence via `nextval(...)` keeps
  pointing at the SOURCE (template) schema's sequence object — the "sequence
  trap".
- `event_type_registry` seeding: `replay_migrations/2` seeds platform event
  type rows via `maybe_seed_platform_event_types/2` when
  `migration_source` is the default manifest. This is **table data**, not
  schema structure — `LIKE ... INCLUDING ALL` never populates it regardless
  of remedy chosen. The template build MUST populate it once (by going
  through the real `replay_migrations/2`, which already does this), and the
  clone step MUST copy those rows from template to clone as data.

### 0.1 New findings from this design pass's own re-verification (psql probes)

Run against throwaway schemas `probe_tpl`/`probe_clone` in `letflow_dev`
(container `letflow-2-postgres-1`, port 5472), modeling the real schema's FK
+ owned-sequence-default shape found by ISSUE-FIXER. Both probe schemas were
dropped (`DROP SCHEMA ... CASCADE`) before this document was written — no
residue.

1. **`pg_get_constraintdef(oid)` on a re-added FK constraint still qualifies
   the referenced table with the TEMPLATE schema's name**, not the clone's.
   Naively doing `'ALTER TABLE ' || conname || ' ' ||
   pg_get_constraintdef(oid)` reproduces the FK constraint object but points
   every one of them at the template's own tables — the opposite of
   independence, and in fact worse than the current FK-less clone, because it
   would look correct while creating live cross-schema foreign-key coupling
   (an `UPDATE`/`DELETE` on a template row could then be blocked by a clone's
   FK, and the template could never safely be dropped once any clone exists).
   **Verified fix:** textually replace the template schema's qualifier with
   the clone schema's qualifier in the constraint definition string before
   executing it (`replace(pg_get_constraintdef(oid), tpl_schema || '.', clone_schema || '.')`).
   Confirmed correct end-to-end: after the substitution, the clone's FK
   enforces against its OWN parent table (an insert referenceing a
   nonexistent clone-local parent row was rejected with a real FK violation)
   and the template remains untouched.
2. **`LIKE ... INCLUDING ALL` renames indexes to Postgres's
   auto-generated default names**, which do not match the template's actual
   index names. Verified directly: a template index named
   `events_parent_idx` became `events_parent_id_idx` in the clone; a partial
   unique index named `events_partial_idx` became `events_parent_id_idx1`.
   Counts matched (4/4) and structural definitions matched **after
   normalizing away the schema qualifier**, but names did not. **This means
   the parity check (§3) must never compare index or constraint identity by
   name** — only by structural definition (columns, predicate, uniqueness,
   access method) with the schema qualifier normalized out. A name-based
   comparison would either false-fail (flagging a correct clone) or, worse,
   false-pass a genuinely different index shape that happened to reuse an
   auto-generated name. This is the same class of hazard
   `docs/anti-patterns.md`'s NAMEDATALEN entry describes (Ecto's own
   default-naming collisions) — same root cause (Postgres deriving a name
   from column list), different trigger.
3. **`pg_get_serial_sequence(schema.table, column)` is the correct, robust
   primitive to detect which columns are sequence-backed** in a template
   table — simpler and more reliable than parsing `column_default` text or
   walking `pg_depend` (a `pg_depend` query for the sequence's owning-column
   dependency, `deptype = 'a'`, returned **zero rows** in this probe despite
   `ALTER SEQUENCE ... OWNED BY` having been issued — `pg_depend` deptype
   semantics for sequence ownership did not behave as naively expected on
   this Postgres version; `pg_get_serial_sequence/2` did not have this
   problem and is what the design below uses. This is a design-time
   correction to ISSUE-FIXER's diagnosis, which suggested "a fixed
   enumerable list, e.g. via pg_depend" — recorded as a MINOR conflict per
   core-directives.md's "Never resolve a conflict silently.").
4. End-to-end functional verification: after applying the FK-substitution
   fix and creating a clone-local sequence + repointing the column DEFAULT +
   `ALTER SEQUENCE ... OWNED BY`, an insert into the clone's dependent table
   advanced ONLY the clone's own sequence (template's `last_value` stayed at
   its pre-insert value), and an FK-violating insert into the clone was
   correctly rejected. Both hazards ISSUE-FIXER found are confirmed fixable
   by the mechanism this design specifies.

### 0.2 Rework 1 — systematic catalog walk (CODE-DESIGN-VALIDATOR gate, rework 1 of 3)

CODE-DESIGN-VALIDATOR's Step 2b gate FAILED the first draft on two findings,
both independently re-verified below before being folded into §3.2 as new/
corrected dimensions #3 (contype enumeration) and #9 (reloptions): (1) §3.2
dimension #3's contype grouping asserted `{c, f, p, u}` was "the full set
Postgres defines," which is false — `x` (exclusion) and `t` (constraint
trigger) also exist; (2) table-level storage parameters (`pg_class.reloptions`)
were silently absent from the parity check, unlike triggers/comments/
collations/privileges, which were each explicitly ruled out with a reason —
an asymmetry, not a considered omission.

Rather than patch only those two and stop, this rework re-ran the same
question the gate itself used — "what else could a degraded clone differ in
that this check wouldn't see?" — systematically against the real Postgres
catalogs, not from memory, per the rework instruction. Method: built two
throwaway schemas (`probe_tpl`/`probe_clone`) in `letflow_dev`, this time
deliberately provisioning EVERY catalog-visible table/column/constraint
property this design's reasoning could plausibly miss (an exclusion
constraint, a `WITH (fillfactor=..., autovacuum_...)` storage option, a
per-column `SET STATISTICS`, a `GENERATED ... STORED` column, a `CREATE
STATISTICS` extended-statistics object, a real `CREATE CONSTRAINT TRIGGER`,
table/column comments), cloned via the same `LIKE ... INCLUDING ALL` the
design mechanism uses, and queried `pg_class`, `pg_constraint`,
`pg_attribute`, `pg_trigger`, `pg_statistic_ext`, and
`information_schema.columns` on both sides side by side. Both probe schemas
(plus a second, minimal pair used to isolate the exclusion-constraint
finding from extension noise) were dropped (`DROP SCHEMA ... CASCADE`)
before this rework was written — verified via `\dn` afterward, only
`public` remains.

Findings, numbered for cross-reference from §3.2:

1. **Exclusion constraints (`contype='x'`) ARE copied by `LIKE ...
   INCLUDING ALL`** — confirmed on both the full probe and a second, minimal
   isolation probe (a bare table with only an `EXCLUDE USING gist (...)`
   constraint): the clone carries an identical `x`-type constraint with the
   identical definition text and even the identical (un-renamed) name. This
   is the CORRECT, expected behavior — exclusion constraints are
   index-backed, and `INCLUDING INDEXES`/`INCLUDING CONSTRAINTS` (both part
   of `INCLUDING ALL`) carry them along the same mechanism that carries
   unique indexes. The validator's finding that dimension #3's contype
   enumeration was incomplete is correct and is fixed (§3.2 dimension #3
   now lists all six); the mechanism (§2.3) needs no new step for exclusion
   constraints specifically, since none is missing from the clone — the gap
   was only that the CHECK never looked.
2. **Table-level `reloptions` are NOT copied** — reproduces the validator's
   own finding exactly: a template table `WITH (fillfactor=70,
   autovacuum_vacuum_scale_factor=0.05)` clones to a table with empty/NULL
   `reloptions`. Confirmed via direct `pg_class.reloptions` comparison.
   Folded into §3.2 as new dimension #9.
3. **Per-column statistics target (`attstattarget`) is NOT copied** — a
   column explicitly set to `STATISTICS 500` in the template clones to
   `attstattarget = -1` (Postgres's "use the system default" sentinel) in
   the clone. A gap of the same shape and severity class as `reloptions`
   (#2 above), found by this rework's own systematic pass, not by the
   validator. Folded into §3.2 as new dimension #10.
4. **Extended statistics objects (`pg_statistic_ext`, created via `CREATE
   STATISTICS`) ARE copied**, with an auto-renamed identifier — the same
   renaming behavior already documented for indexes (§0.1 finding 2):
   `events_stat` on the template became `events3_parent_id_total_stored_stat`
   on a `LIKE`-cloned sibling table in the probe. Correctly copied by the
   mechanism; the gap (same shape as finding 1) was that the parity check
   never looked. Folded into §3.2 as new dimension #11, with the same
   name-independent structural-comparison treatment already used for indexes.
5. **Row security, partitioning, tablespace, ownership all confirmed
   not-applicable under this codebase's current migrations** — `pg_class`
   queried directly for `relrowsecurity`, `relforcerowsecurity`, `relkind`,
   `relispartition`, `reltablespace`, `relowner` on both template and clone;
   all identical and all at their "nothing special" defaults, consistent
   with a `grep` across every migration finding no `ENABLE ROW LEVEL
   SECURITY`, no `PARTITION BY`, no `TABLESPACE`. Folded into §3.2 as new
   dimension #12, an explicit rule-out rather than a silent one — matching
   the rigor of the existing triggers/comments/collations/privileges
   rule-outs the validator asked this design to extend, not abandon.
6. **Generated columns (`attgenerated = 's'`, `GENERATED ALWAYS ... STORED`)
   behave correctly under `LIKE ... INCLUDING ALL`** — the clone's
   generated column carries the identical `attgenerated` flag and
   (confirmed separately, not shown above for brevity) the identical
   generation expression via `pg_get_expr` on `pg_attrdef`. Already covered
   by dimension #2's column comparison (generation expression is a form of
   column default in Postgres's own catalog representation) — no new
   dimension needed; recorded here so the walk shows this case was
   considered, not skipped.
7. **Constraint triggers (`contype='t'`) are real and are NOT copied** —
   see §3.2 dimension #3's own REWORK NOTE for the full finding and the
   correction it makes to this design's own prior (wrong) claim about how
   constraint triggers are created.

This pass covered `pg_class`, `pg_constraint`, `pg_attribute`, `pg_trigger`,
`pg_statistic_ext`, and `information_schema.columns` — the six catalogs
judged most likely to carry a table-shape property `LIKE ... INCLUDING ALL`
could plausibly mishandle. **This judgement turned out to be incomplete —
see §0.3 for two further gaps CODE-DESIGN-VALIDATOR's rework-2 gate found,
both by extending this same method to catalogs/views this pass did not
reach, and both traced to the same root cause: `information_schema.columns`,
the one column-type source this pass used, structurally cannot see a
domain/enum/collation's true schema, because the SQL-standard view
normalizes exactly that detail away.** `pg_policy` (row security policies)
was checked implicitly via `relrowsecurity` being false everywhere (a false
`relrowsecurity` means no policy can be in effect regardless of `pg_policy`
contents, so no separate `pg_policy` query was needed once finding 5
established RLS is off everywhere). Sequences and their ownership (§0.1
findings 3-4, dimension #5) and indexes (§0.1 finding 2, dimension #4) were
already covered by the original draft and re-confirmed still correct by the
validator, not re-probed in this rework.

### 0.3 Rework 2 — `information_schema` vs `pg_catalog`, and the column-type/collation-schema gap (CODE-DESIGN-VALIDATOR gate, rework 2 of 3)

The rework-1 re-gate FAILED on one MAJOR and two MINORs. This section
addresses all three, plus the re-examination the coordinator specifically
asked for: whether `information_schema.*` (a SQL-standard abstraction that
deliberately normalizes away Postgres-specific detail) misled §0.2's own
method anywhere else, not just at the one spot the validator found.

**THE MAJOR, independently re-verified.** A column typed as a custom
Postgres `DOMAIN` or `ENUM` clones with its true type still schema-qualified
to the TEMPLATE, not the clone. Reproduced exactly: built
`probe_tpl.positive_int` (a `DOMAIN ... AS integer CHECK (VALUE > 0)`) and
`probe_tpl.color_enum` (a plain `ENUM`), used both as column types on a
template table, cloned via `LIKE ... INCLUDING ALL`. `pg_attribute` +
`pg_type` ground truth showed the clone's `amount`/`color` columns have true
type `probe_tpl.positive_int`/`probe_tpl.color_enum` — IDENTICAL type
objects to the template's own, not clone-local copies — confirmed further by
`pg_depend` (`deptype = 'n'`, a normal, real dependency) showing
`probe_clone.parents.amount` depends directly on `probe_tpl.positive_int`.
Tearing the probes down demonstrated the consequence directly: dropping
`probe_clone` first, then `probe_tpl`, produced the expected cascade
(`DROP SCHEMA probe_tpl CASCADE` reporting "drop cascades to type
probe_tpl.positive_int / probe_tpl.color_enum" as those types' own drop,
harmless in the correct teardown order) — but dropping `probe_tpl` FIRST
(the order the validator used to demonstrate the hazard) cascades into and
destroys the CLONE's own columns, exactly the sequence-trap/FK-qualifier
hazard class this design already treats as first-tier, now confirmed for
column types too.

**THE ROOT CAUSE, examined as asked rather than just patched around.**
§0.2's own instrument — `information_schema.columns`, the only column-type
source that pass used — is not merely a spot where this rework happened to
look in the wrong place; it is SQL-standard-specified to resolve a
domain-typed column's `data_type`/`udt_name` down to the domain's BASE type.
Verified directly this rework: `information_schema.columns` reported
`amount` as `data_type=integer, udt_schema=pg_catalog` on BOTH template and
clone, identically — masking the true, template-qualified `pg_attribute`
type underneath. This is the same shape of blind spot as the rework-1
BLOCKER (an instrument structurally incapable of showing the property being
asked about), not a new category of mistake.

**What the re-examination of every OTHER `information_schema` use in this
design turned up** (per the coordinator's explicit ask — walked each one
against its `pg_catalog` ground truth rather than declaring the method safe
by assumption):

- `information_schema.tables` (dimension #1, table-name set). NOT a gap.
  A table's own identity IS its own schema+name pair — there is no
  "points at another object" indirection for a table the way there is for a
  column's type, default, or collation, so there is nothing for this view to
  normalize away that would matter here. Re-confirmed by comparing directly
  against `pg_class`/`pg_namespace`: identical, no hidden field.
- `information_schema.columns.collation_name` (dimension #6, Collations).
  **A SECOND REAL GAP, found by this same re-examination, same shape as the
  MAJOR above.** Built a genuinely custom, non-default collation
  (`CREATE COLLATION probe_tpl.custom_ci (...)`), used it on a template
  column, cloned via `LIKE ... INCLUDING ALL`. `information_schema.columns`
  DOES carry a `collation_schema` field (distinct from the bare
  `collation_name` this design's dimension #6 actually compares) that
  correctly reports `probe_tpl` on the CLONE side too — proving the clone's
  column collation is the template's own object, not a clone-local one,
  exactly like the DOMAIN/ENUM case. Confirmed independently via
  `pg_attribute.attcollation` → `pg_collation.collnamespace`: `probe_tpl` on
  both sides. **Dimension #6 as originally specified only compares
  `collation_name` (the bare string, e.g. `"custom_ci"`), never
  `collation_schema` — so an identically-named collation object living in
  the wrong schema would sail past it identically to how the DOMAIN gap
  sailed past the column-type comparison.** Fixed in dimension #6 below.
  Confirmed dormant: `grep -rl "CREATE COLLATION" priv/repo/migrations/*.exs`
  — zero hits; every column in the real tenant schema uses Postgres's
  built-in default collation, which needs no schema qualifier and has no
  "wrong schema" failure mode to begin with (there is no per-database
  DOMAIN/ENUM/COLLATION-style redirection possible for `pg_catalog`-owned
  built-in types/collations, since `pg_catalog` is not per-schema and cannot
  be shadowed by `search_path` the way a custom type's bare name could be —
  this is why ordinary column comparisons never showed a false positive in
  any of this design's probes across three rounds).
- `information_schema.role_table_grants` (item 8's Privileges rule-out).
  NOT a gap. Verified `pg_class.relacl` directly on both template and clone:
  empty on both sides (no explicit ACL exists on either — the grants
  `role_table_grants` reports are implicit owner privileges, identical by
  construction since one Postgres role owns every schema this codebase
  creates). Unlike the DOMAIN/collation cases, there is no schema-qualified
  object a grant could point "at the wrong one of" — a privilege is a
  property of the (role, relation) pair itself, not a reference to a shared
  object another schema could still own. The existing rule-out's reasoning
  holds exactly as stated.

**Nowhere else in this design relies on an `information_schema` view for a
property that could reference a shared, schema-qualified object living
outside the table/column being described** — table set, generic column
scalar comparisons (name/nullable/ordinal), and privileges each confirmed
above to have no such indirection. Every OTHER dimension in this design
(#3 constraints, #4 indexes, #5 sequences, #9 reloptions, #10 attstattarget,
#11 pg_statistic_ext) was already built directly against `pg_catalog`
(`pg_constraint`, `pg_indexes`/`pg_index`, `pg_get_serial_sequence`,
`pg_class.reloptions`, `pg_attribute.attstattarget`,
`pg_statistic_ext`/`pg_get_statisticsobjdef`), never through an
`information_schema` intermediary, so none of those was at risk of this
specific failure mode — the risk was narrowly confined to the two
`information_schema.columns` fields (base column type resolution, bare
collation name) this rework corrects.

**THE FIX — column type and collation schema, added to §3.2 as new
dimension #13** (see §3.2 for the exact specification). **What the CLONE
MECHANISM (§2.3) must do about it, stated plainly per the coordinator's
ask:** nothing, today — no `CREATE DOMAIN`/`CREATE TYPE`/`CREATE COLLATION`
exists anywhere in `priv/repo/migrations/` (grepped, zero hits for either),
so there is no clone-local type or collation object for the mechanism to
create, and the current absence of a recreation step is correct, not an
oversight, for exactly the same reason OQ-2 (triggers) and OQ-5
(reloptions/attstattarget) currently need no mechanism step. This slots into
that established pattern as **OQ-6** (§9) rather than requiring new
mechanism machinery today: if a future migration introduces a custom
domain, enum, or collation, dimension #13 will catch the resulting
clone/template coupling immediately and loudly (§5's no-silent-fallback
stance), and the mechanism would then need a new step — creating a
clone-local `CREATE DOMAIN`/`CREATE TYPE`/`CREATE COLLATION` in the clone's
own schema (built from the template's definition, e.g.
`pg_get_constraintdef`-style catalog introspection for domain constraints,
or `\dT+`-equivalent enum label enumeration) and repointing the column to
it — symmetric in shape to §2.3 step 4's FK re-add and step 5's sequence
recreation, but not designed in full here since nothing exists today to
design a concrete recreation step against.

**THE FIRST MINOR — index comments.** Verified directly: `COMMENT ON INDEX
...` on a template index does not survive `LIKE ... INCLUDING ALL`
(`obj_description` on the clone's corresponding index is `NULL` where the
template's is populated) — dimension #8's comments sub-bullet is scoped, by
its own text, to table/column comments only, so this was never a
false-exhaustiveness claim, but it was an uncovered gap. Confirmed dormant
this rework (the validator's own gate had left this unconfirmed):
`grep -rl "COMMENT ON" priv/repo/migrations/*.exs` — zero hits of ANY kind
(table, column, index, or constraint) anywhere in the real migration set.
Decision: RULE OUT WITH A STATED REASON, added to dimension #8's own
sub-bullet list below, rather than added as an active check — comments are
purely cosmetic (no query result, constraint enforcement, or planner
behavior depends on a comment's text, unlike every other property this
design actively checks), and the confirmed-zero dormancy means this is a
considered omission of the same shape as the RLS/partitioning/tablespace
rule-out (dimension #12), not a silent one.

**THE SECOND MINOR — missing `## 1.` header.** Fixed: the rework-1 edit's
new §0.2 content had been inserted in a way that orphaned the pre-existing
"Scope and non-goals" text with no header of its own. Restored `## 1. Scope
and non-goals` above that content; §11's "§1 non-goals" cross-reference now
resolves again. Purely mechanical — verified no content was lost, only the
header line was missing (confirmed by reading the orphaned text in place
before restoring the header, rather than reconstructing it from memory).

## 1. Scope and non-goals

**In scope:** how `test/support/tenant_fixture.ex`'s `provisioned_tenant!/1`
materializes a tenant schema for tests, backed by a template-clone fast path
instead of always calling `TenantProvisioning.replay_migrations/2` directly.

**Out of scope, explicitly:**
- `TenantProvisioning.provision_tenant_schema/1` and `replay_migrations/2`
  themselves — unchanged, in both signature and behavior, and remain the
  ONLY path real tenant onboarding calls. See §7.
- `Letflow.SandboxPool` — not modified by this design. §6 states the
  (optional, future) relationship; ISS-0423 owns that decision.
- Parallel test running / `async: true` adoption — ISS-0423's scope, not
  absorbed here.
- Any change to the 53-entry `@tenant_scoped_migration_manifest` itself.

## 2. New module: `Letflow.Test.TenantTemplate`

Test-only. Lives at `test/support/tenant_template.ex`, compiled under
`elixirc_paths(:test)` (same placement class as `Letflow.TenantFixture`, not
`lib/letflow/`). **Not** referenced from `lib/`, **not** added to
`lib/letflow/application.ex`'s supervision tree, **not** a GenServer — a
plain module, matching `TenantFixture`'s and `TenantSchemaReaper`'s
established shape for `test/support/`.

Reused verbatim from `Letflow.TenantProvisioning` rather than reimplemented:
`schema_name_for_tenant/1` (for deriving the physical schema name of the
template's own backing "tenant"), `tenant_scoped_migrations/0` (for the
manifest-version parity check in §3 and for building the template itself via
the real, unmodified `replay_migrations/2`).

### 2.1 Public API

```
@type template_state :: :not_built | :built | :stale

@spec ensure_template!() :: :ok
# Idempotent. Builds the template schema exactly once per test run (see
# §4.2 for "once" scoped to what — a BEAM VM / MIX_TEST_PARTITION database,
# not the whole multi-partition suite). Safe to call from many tests
# concurrently within one partition — see §4.3's concurrency guard. Raises
# (ExUnit.AssertionError-shaped, matching TenantFixture's own
# report_and_raise/3 convention) if the template cannot be built or fails
# its own post-build parity self-check (§3). Never silently falls back —
# see §5.

@spec template_schema_name() :: String.t()
# Pure, no I/O. The fixed physical schema name the template lives under in
# whichever database this BEAM VM/partition is connected to. NOT derived
# from schema_name_for_tenant/1's UUID-hex encoding (the template is not a
# real tenant and must never collide with, or be mistakable for, one) — see
# §2.2 for the literal name and why.

@spec clone_tenant_schema!(source_tenant_id :: Ecto.UUID.t()) ::
        {:ok, schema_name :: String.t()}
      | {:error, {:clone_failed, term()}}
# Preconditions: ensure_template!/0 has already been called successfully in
# this process's lifetime (TenantFixture calls it, see §4.1 — this function
# itself does NOT call ensure_template!/0, so a caller bypassing
# TenantFixture must do so explicitly; this is deliberate, not an oversight
# — see the "no implicit chaining" precedent TenantProvisioning's own
# moduledoc already establishes between provision_tenant_schema/1 and
# replay_migrations/2). Derives the destination schema name from
# source_tenant_id via TenantProvisioning.schema_name_for_tenant/1 (the
# SAME derivation TenantFixture already uses — this function does not
# invent a second naming scheme). Performs the full clone sequence: §2.3
# steps 1-6. Returns {:error, {:clone_failed, reason}} on any failure
# instead of raising, so TenantFixture's own existing report_and_raise/3
# call sites (matching its current provision!/1 and replay!/1 shape) can
# wrap it uniformly — see §4.1's exact call-site diff shape (structure
# only, no code).

@spec template_ready?() :: boolean()
# Pure predicate, no I/O beyond a fast local check (an Agent/persistent_term
# read, not a DB round trip — see §4.2's storage note). Lets a caller
# (namely TenantFixture, if it wants to log or branch) ask without forcing
# a build. Does not by itself guarantee the template is *fresh* — only that
# a prior ensure_template!/0 call in this process completed successfully.
```

### 2.2 Template schema naming

Fixed literal name: `"tenant_template"`. Deliberately NOT of the shape
`"tenant_" <> <32 hex>` that `schema_name_for_tenant/1` produces for real
tenants — this is a hard invariant: `tenant_id_for_schema_name/1` (the
reverse mapping other modules use, e.g.
`Letflow.EventStore.Registry.resolve_schema_name/1`'s call sites,
`Letflow.ServiceCatalog`'s cross-schema referential guard via
`list_registrations/0`) MUST NEVER be asked to resolve `"tenant_template"` as
if it were a real tenant, and must never succeed if it is. Verified by
inspection: `tenant_id_for_schema_name/1` pattern-matches `"tenant_" <> hex`
where `hex` must satisfy `~r/^[0-9a-f]{32}$/` — `"template"` (8 ASCII
letters, none of them all-lowercase-hex-only by construction since it
contains `t`, `m`, `p`, `l`, `a`, `e`, none of which are `0-9a-f`... wait,
`a` and `e` ARE valid hex digits, but `t`, `m`, `p`, `l` are not) fails that
regex and is NOT 32 characters long regardless, so
`tenant_id_for_schema_name("tenant_template")` already returns
`{:error, :invalid_schema_name}` today, with zero code change — confirmed by
reading the function, not run (no DB access needed for a pure-function
argument check). This is stated explicitly as a design invariant so
ELIXIR-DEV does not need to re-derive it and so REVIEWER can check it
mechanically: **the template schema name must never be a value
`schema_name_for_tenant/1` could have produced for a real UUID, and must
never round-trip through `tenant_id_for_schema_name/1` successfully.**

The template has NO corresponding `Letflow.TenantProvisioning.Registration`
row, NO corresponding `Letflow.Identity.Tenant` row. It is built by raw
`CREATE SCHEMA "tenant_template"` DDL plus a direct
`Ecto.Migrator.run(Repo, tenant_scoped_migrations(), :up, all: true, prefix: "tenant_template", log: false)`
call (the same primitive `TenantProvisioning.replay_migrations/2` and
`SandboxPool.provision_sandbox/2` both already use directly against
`Repo`), NOT through `provision_tenant_schema/1` (which would require a real
`Tenant`/`Registration` row it has no reason to carry) or
`replay_migrations/2` (which requires a pre-existing `Registration` row,
per its own `{:error, :tenant_not_provisioned}` guard). This keeps the
template's own build path structurally incapable of being mistaken for
"just another provisioned tenant" — no registry row exists to list it, no
`tenant_id` exists to derive it from.

**Event-type seeding for the template.** Because the template is not built
via `replay_migrations/2`, it does NOT automatically get
`maybe_seed_platform_event_types/2`'s 13 rows. The template build (§2.3 step
2) explicitly calls the same seeding logic
(`TenantProvisioning`'s private `@platform_event_type_seed_attrs` list is
private — see Open Question OQ-1 below for how this is exposed) so the
template's `event_type_registry` table is populated exactly as a real
`replay_migrations/2`-provisioned schema's would be, and every clone
inherits those rows as ordinary table data (§2.3 step 6).

### 2.3 The clone mechanism, step by step

`ensure_template!/0` (build once per process/database):

1. `CREATE SCHEMA IF NOT EXISTS "tenant_template"`.
2. `Ecto.Migrator.run(Repo, TenantProvisioning.tenant_scoped_migrations(), :up, all: true, prefix: "tenant_template", log: false)`,
   then seed the 13 platform event types into `"tenant_template".event_type_registry`
   (see OQ-1) — mirrors exactly what `replay_migrations/2` does for a real
   tenant, applied to the template schema instead.
3. Self-check: assert the template's own table set matches
   `TenantFixture.expected_tenant_tables/0` (reusing that existing oracle,
   not inventing a second one) and that `tenant_scoped_migrations/0`'s
   version list matches `"tenant_template".schema_migrations` exactly
   (reusing the exact query shape `TenantFixture`'s own `applied_versions_in/1`
   already uses). Raise immediately, do not proceed to serving clones, if
   either check fails — a broken template must never silently serve broken
   clones (this is what ISSUE-FIXER's diagnosis (ii) flagged as "must design
   one" for staleness detection; this self-check is that mechanism, run at
   build time rather than trusted).
4. Mark built (persist a `:built` marker — see §4.2 for exactly where).

`clone_tenant_schema!(source_tenant_id)` (per test, the fast path):

1. Derive `clone_schema` via `TenantProvisioning.schema_name_for_tenant(source_tenant_id)`.
2. `CREATE SCHEMA "<clone_schema>"` (no `IF NOT EXISTS` — a collision here
   means a caller reused a `tenant_id` that already has a live schema, which
   is a caller bug, not something to paper over).
3. For every table name in `TenantFixture.expected_tenant_tables/0` (walked
   in a stable, deterministic order — table-name lexical order — so DDL
   order is reproducible across runs, not because Postgres requires it for
   `LIKE`):
   `CREATE TABLE "<clone_schema>"."<table>" (LIKE "tenant_template"."<table>" INCLUDING ALL)`.
4. **Foreign-key re-add.** Query `pg_constraint` (joined to `pg_class` for
   the owning table name) for every `contype = 'f'` constraint in the
   `tenant_template` namespace. For each, build the `ALTER TABLE
   "<clone_schema>"."<table>" ADD CONSTRAINT "<conname>" <def>` statement
   from `pg_get_constraintdef(oid)`, with the template schema's own
   qualifier (`"tenant_template".`) textually replaced by the clone schema's
   qualifier throughout the definition string — per §0.1 finding 1, this
   substitution is NOT optional; skipping it reproduces the FK constraint
   object but points it at the template's own tables.
5. **Sequence re-creation.** For every table×column pair in the template
   whose `pg_get_serial_sequence("tenant_template"."<table>", "<column>")`
   returns non-null (per §0.1 finding 3 — the robust primitive, not
   `pg_depend` walking): create a new sequence
   `"<clone_schema>"."<original_sequence_local_name>"` (same local sequence
   name as the template's, re-qualified to the clone schema — so a
   subsequent human reading the clone schema sees a familiarly-named
   sequence, not a synthesized one), `ALTER TABLE
   "<clone_schema>"."<table>" ALTER COLUMN "<column>" SET DEFAULT
   nextval('"<clone_schema>"."<seq>"')`, then
   `ALTER SEQUENCE "<clone_schema>"."<seq>" OWNED BY
   "<clone_schema>"."<table>"."<column>"`. The new sequence starts at its
   default (1) — tests must not depend on a specific starting sequence
   value carried over from the template (an explicit invariant; see §8
   INV-3).
6. **Seed-data copy.** `INSERT INTO "<clone_schema>".event_type_registry
   SELECT * FROM "tenant_template".event_type_registry` — the one table
   whose *data*, not just structure, must be present for the clone to
   behave like a `replay_migrations/2`-provisioned schema (per §0's
   `maybe_seed_platform_event_types/2` finding). No other table's data is
   copied — every other tenant-scoped table starts empty in both the
   migration-replay path and the clone path, so this is not a special case
   invented for cloning, it is preserving what replay already does.
7. `INSERT INTO "<clone_schema>".schema_migrations SELECT * FROM
   "tenant_template".schema_migrations` — so a clone's `schema_migrations`
   table reports the same applied-version set a real replay would have
   recorded. This matters because `assert_schema_complete!/2`'s check #3
   (§ existing code, `versions_missing`) queries exactly this table; without
   this copy, a clone would look under-migrated to that existing oracle even
   though it is not.
8. Insert the caller's `Registration` row exactly as
   `provision_tenant_schema/1` would have (a plain `Repo.insert!/1` on
   `TenantProvisioning.Registration`, not a call to
   `provision_tenant_schema/1` itself — because that function issues its own
   `CREATE SCHEMA IF NOT EXISTS`, which is redundant with step 2 above and
   would mean two different code paths both believe they "provisioned" the
   schema; §7 states explicitly why this does not touch the production
   function). `migrations_applied_at` is set to the current time, matching
   what `replay_migrations/2`'s own `mark_migrations_applied/1` does.

Every identifier interpolated into raw SQL above (`clone_schema`, `table`,
`column`, `conname`, `seq`) is either a compile-time-known table/column name
from `expected_tenant_tables/0` (a fixed, hand-maintained list, not
caller/attacker input) or the output of
`TenantProvisioning.schema_name_for_tenant/1` (constrained to
`tenant_[0-9a-f]{32}` by construction, the same invariant
`provision_tenant_schema/1` itself already relies on) or a name read back
from Postgres's own catalog (`pg_constraint`/`pg_get_serial_sequence`,
which by definition can only contain names Postgres itself already accepted
as valid identifiers when the template was built by this codebase's own
migrations) — never a value threaded through from an external/test-supplied
string. No new identifier-injection surface is introduced beyond what
`provision_tenant_schema/1` already accepts as safe today.

## 3. The parity check (the crux, per the dispatch)

### 3.1 What "parity" means here, precisely

A cloned schema and a migration-built schema must be indistinguishable to
any Postgres catalog query a test or the application code could issue. The
check below is catalog-level, symmetric (checks both directions — nothing
extra in either schema, not just nothing missing), and structural rather
than name-based per §0.1 finding 2.

### 3.2 New test-only function: `Letflow.Test.TenantTemplate.assert_clone_parity!/2`

```
@spec assert_clone_parity!(
        reference_schema :: String.t(),
        candidate_schema :: String.t()
      ) :: :ok
# Raises ExUnit.AssertionError (same shape/marker convention as
# TenantFixture.report_and_raise/3) with a full diff report on ANY mismatch.
# reference_schema is normally "tenant_template" itself (comparing a fresh
# clone against the template it was cloned from) OR a genuinely
# migration-built schema (comparing the template's own build against an
# independent replay_migrations/2 run) — both call shapes are needed, see
# §3.4's two use sites.
```

Comparison dimensions, each normalized to strip the schema-name qualifier
before comparing (so `"tenant_template".parent` and `"tenant_abc123...".parent`
compare equal on structure) — thirteen dimensions, this is the full
enumerated list the dispatch asked for, not "and anything else." (Grown from
eight to twelve in rework 1, per §0.2's systematic catalog walk — dimensions
#9-#12 were new there, #3 and item 8's triggers sub-bullet were corrected,
not just supplemented, per §0.2 findings 1 and 7. Grown from twelve to
thirteen in rework 2, per §0.3 — dimension #13 is new, item 8's comments and
collations sub-bullets were corrected/extended, per §0.3's findings.)

1. **Table set** — `information_schema.tables` table names, set-equal, both
   directions. (Reuses `TenantFixture`'s existing table-enumeration query
   shape.)
2. **Columns** — per table: name, data type, `is_nullable`,
   `column_default` (schema-qualifier-normalized — a
   `nextval('"<schema>"."x_seq"')` default must match after substituting
   each side's own schema name), ordinal position. Source:
   `information_schema.columns`.
3. **Constraint kinds and definitions** — `pg_constraint` grouped by
   `contype` over the **full six-member set Postgres actually defines**:
   `c` check, `f` foreign key, `p` primary key, `u` unique, `x` exclusion,
   `t` constraint trigger (see the REWORK NOTE below — a prior draft of this
   design asserted `{c, f, p, u}` was the full set, which was factually
   wrong on two counts, caught by CODE-DESIGN-VALIDATOR and independently
   re-verified here). Count-equal per kind, AND `pg_get_constraintdef(oid)`
   textually equal per constraint **after** schema-qualifier normalization
   on both sides — catches both "FK missing entirely" (§0 hazard 1) and "FK
   present but pointing at the wrong schema" (§0.1 finding 1, the fix's own
   failure mode if implemented wrong). Compared as a **multiset of
   normalized definitions per table**, not by `conname` (per §0.1 finding 2
   — Postgres's own default-generated FK names are not guaranteed to match
   across independently-created objects even when this design does preserve
   the template's `conname` verbatim for FKs — belt and suspenders).

   **`x` (exclusion constraints).** Verified directly (see §0.2 finding 1):
   `LIKE ... INCLUDING ALL` DOES copy exclusion constraints — they are
   index-backed (implemented via the same GiST/GIN index machinery `INCLUDING
   INDEXES` already carries along, same as unique indexes), unlike FK
   constraints, which are purely relational and never copied. So the clone
   MECHANISM (§2.3) needs no new step for exclusion constraints — but until
   this rework, the PARITY CHECK never inspected `contype='x'` at all, so a
   future migration introducing one, and a future regression in Postgres's
   own `LIKE` behavior or in this mechanism's assumptions about it, could
   both go undetected. Included in the grouped-count-and-definition
   comparison above now; no separate step needed since the general
   `pg_get_constraintdef`-based comparison already handles arbitrary
   constraint definition text, exclusion constraints included.

   **`t` (constraint triggers).** REWORK NOTE, stated plainly per this
   role's own instruction not to bury a correction: an earlier draft of this
   design (§3.2 item 8, the triggers sub-bullet) asserted "Postgres
   constraint triggers aren't created via plain `CREATE TRIGGER`" as the
   reason to treat `t` as not-really-a-`CREATE TRIGGER`-shaped concern. That
   was WRONG, and it was wrong even though the eventual conclusion (no
   constraint trigger exists in this codebase's migrations today) still
   holds. Verified directly this rework: `CREATE CONSTRAINT TRIGGER ...`
   (the standard SQL syntax for a deferrable, per-row trigger tied to a
   constraint) does produce a `pg_constraint` row with `contype = 't'`, and
   `LIKE ... INCLUDING ALL` does NOT copy it (confirmed: a `LIKE`-cloned
   table sibling to the one carrying the constraint trigger has zero
   `pg_trigger` rows) — triggers, constraint or plain, are the documented
   `INCLUDING ALL` exception (§3.2 item 8's triggers sub-bullet already
   states this correctly for plain triggers; it now applies identically to
   constraint triggers, for the same reason and via the same mechanism).
   `grep`-verified again this rework: no migration under `priv/repo/migrations/`
   contains `CREATE TRIGGER` or `CREATE CONSTRAINT TRIGGER` in any `execute/1`
   call. So: `contype = 't'` is folded into the same count-equal-to-zero
   assertion §3.2 item 8 already makes for triggers generally (not a new,
   separate check) — it is genuinely the same property (a trigger-backed
   constraint is still a trigger, absent from every current migration, not
   copied by `LIKE`), correctly ruled in-scope-but-currently-zero rather than
   silently omitted.
4. **Indexes** — `pg_indexes.indexdef`, schema-qualifier-normalized, compared
   as a **multiset of normalized definitions per table**, explicitly NOT by
   `indexname` (§0.1 finding 2 — verified empirically that `LIKE INCLUDING
   ALL` renames indexes). This single-handedly covers unique indexes,
   partial/predicate indexes (the `WHERE` clause is part of `indexdef`), and
   expression indexes (the expression text is part of `indexdef`) — no
   separate check needed for those three, they fall out of comparing the
   full `indexdef` string.
5. **Sequences reachable from a column default** — for every column with a
   non-null default in the reference schema, compare
   `pg_get_serial_sequence(schema.table, column) IS NOT NULL` on both sides
   (both must agree on which columns are sequence-backed), and separately
   assert the candidate's sequence actually lives IN the candidate schema
   (`pg_get_serial_sequence` returns a schema-qualified name — assert its
   schema-qualifier equals `candidate_schema`, never `reference_schema` or
   any other schema). This is the direct, mechanical test for the "sequence
   trap" — a clone whose default still points at the template fails this
   check immediately and loudly, rather than silently coupling tenants.
6. **NOT NULL / identity** — folded into #2 (`is_nullable` is part of the
   column comparison). A separate `pg_attribute.attidentity` check is
   included explicitly (`<> ''` on either side must match) because
   ISSUE-FIXER's diagnosis confirmed the real schema uses a **standalone
   sequence + DEFAULT**, not `GENERATED ... AS IDENTITY`, on the one
   sequence-backed column found — so this check exists to catch a *future*
   migration that introduces a real identity column, which `LIKE INCLUDING
   ALL` handles differently in principle (identity columns are documented by
   Postgres as copied by `INCLUDING IDENTITY`, itself included in
   `INCLUDING ALL` — but the *new sequence object* an identity column owns
   is, per Postgres's own docs, created fresh per table and is NOT
   template-linked the way a manual `nextval()` default is). This design
   does not currently need to special-case identity columns (none exist in
   the real schema per ISSUE-FIXER's direct check), but the parity check
   asserting `attidentity` equality means a future migration that adds one
   is caught by this same test rather than silently passing an incomplete
   check.
7. **Row counts for seeded tables** — `event_type_registry` row count
   compared exactly (not just "table exists") between template and clone,
   since §2.3 step 6 is a data copy, not a structural one, and the general
   structural checks above (1-6) do not look at row contents.
   `schema_migrations` row count and version SET (not just count) compared
   exactly, for the same reason as step 7 of §2.3.
8. **Privileges, comments, triggers, collations — explicitly checked and
   found not-applicable, not skipped by omission** (the dispatch's own
   instruction: enumerate and say how each is verified, not hand-wave):
   - *Triggers, including constraint triggers*: `pg_trigger` queried for both
     schemas (this single query covers plain triggers AND constraint
     triggers — a constraint trigger is still a `pg_trigger` row, additionally
     represented by a `contype='t'` `pg_constraint` row per dimension #3
     above); the real tenant schema has zero triggers of either kind today
     (grepped `priv/repo/migrations/` for `CREATE TRIGGER` and
     `CREATE CONSTRAINT TRIGGER` inside any `execute/1` call — no hits, both
     re-verified this rework), so this check asserts
     **count-equal-to-zero on both sides**, not skipped — if a future
     migration adds either kind, `LIKE INCLUDING ALL` does NOT copy it
     (Postgres documents `INCLUDING ALL` as covering
     comments/constraints/defaults/identity/indexes/statistics/storage —
     triggers are a **documented exception**, verified directly this rework
     for both plain and constraint triggers, not merely untested here), so
     this check would then need a real trigger-recreation step symmetric to
     §2.3 step 4's FK handling — flagged as Open Question OQ-2 below rather
     than silently assumed safe forever.
   - *Comments — table/column* (`obj_description`/`col_description`): no
     migration in this codebase issues `COMMENT ON` of any kind (grepped,
     no hits, re-confirmed rework 2), and `INCLUDING ALL`'s
     `INCLUDING COMMENTS` component would copy table/column comments if
     present — the parity check compares comment text (schema-normalized)
     per table/column as a cheap symmetric check; expected to be
     `NULL`/`NULL` on both sides today, which the check still asserts equal
     (not skipped) so a future migration adding a table/column comment is
     covered for free.
   - *Comments — indexes and constraints* (added rework 2, per
     CODE-DESIGN-VALIDATOR's MINOR finding): `COMMENT ON INDEX`/
     `COMMENT ON CONSTRAINT` are a DIFFERENT case from table/column
     comments — verified directly this rework that `LIKE ... INCLUDING ALL`
     does NOT carry an index's own comment to its clone (`obj_description`
     on the clone's corresponding index came back `NULL` where the
     template's showed real text), while a constraint's comment DOES survive
     (checked as a control, verified identical on both sides). Explicitly
     OUT of this check's active scope, ruled out rather than silently
     omitted: confirmed fully dormant this rework (`grep -rl "COMMENT ON"
     priv/repo/migrations/*.exs` — zero hits of any kind, table/column/
     index/constraint alike, across every migration), and comments are
     purely cosmetic — no query result, constraint enforcement, or planner
     behavior depends on a comment's text, unlike every other property this
     design actively checks. If a future migration adds `COMMENT ON INDEX`,
     this is a currently-known, currently-accepted gap (not silently
     reintroduced) rather than a promise to catch it.
   - *Collations — bare name only, see dimension #13 for the schema this
     bullet alone does NOT cover*: `information_schema.columns.collation_name`
     compared per column as part of check #2 (folded in, not a separate
     pass). **CORRECTED rework 2** — the previous claim here ("Postgres
     copies column collation under plain `LIKE` already ... so this is
     expected-equal by construction") was true only for Postgres's own
     built-in, `pg_catalog`-owned default collation, and was WRONG as a
     general claim: verified directly this rework that a column using a
     CUSTOM (non-default) collation clones with its true collation object
     still schema-qualified to the TEMPLATE, identically to the DOMAIN/ENUM
     column-type finding below — `collation_name` alone (a bare string) does
     not reveal this, because the name itself is identical on both sides;
     only `collation_schema` (a separate `information_schema.columns` field
     this bullet never compared) shows the true, template-pointing
     namespace. This bullet's comparison of bare `collation_name` remains in
     the check (still meaningful — it would catch a wrong DEFAULT
     collation), but is no longer claimed sufficient on its own; dimension
     #13 is what actually closes this gap.
   - *Privileges* (`information_schema.role_table_grants` / `has_table_privilege`):
     explicitly OUT of this check's scope, with a stated reason rather than
     a silent omission — `CREATE SCHEMA`/`CREATE TABLE` in this codebase's
     test database always run as the single configured `letflow` Postgres
     role (`config/test.exs`'s `Repo` config — no per-tenant Postgres ROLE
     is ever created; tenant isolation is enforced at the application layer
     via `:prefix`, not via Postgres GRANT/REVOKE), so there is no
     privilege state that could differ between a migration-built schema and
     a cloned one — both are created by the same DDL-issuing role and
     inherit that role's ownership. Documented here so a future reader does
     not wonder whether this was overlooked.

9. **Table-level storage parameters (`pg_class.reloptions`)** — REWORK
   ADDITION, per CODE-DESIGN-VALIDATOR's MAJOR finding, independently
   re-verified this rework (§0.2 finding 2): `fillfactor`,
   `autovacuum_vacuum_scale_factor`, and every other `WITH (...)` table
   storage option are visible in `pg_class.reloptions` and are **silently
   NOT copied** by `LIKE ... INCLUDING ALL` — confirmed directly: a template
   table created `WITH (fillfactor=70, autovacuum_vacuum_scale_factor=0.05)`
   clones to a table whose `reloptions` is `NULL`/empty. This is a real
   dimension `INCLUDING STORAGE` does NOT cover the way its name might
   suggest — Postgres's own docs describe `INCLUDING STORAGE` as copying
   per-column `SET STORAGE` (`attstorage`: `plain`/`external`/`extended`/
   `main`), a column-level attribute, not table-level `reloptions` at all;
   these are two different "storage" concepts sharing a confusingly similar
   name, and this design's prior draft conflated them by omission. New
   check: `pg_class.reloptions` (an array) compared for set-equality per
   table between reference and candidate, no schema-qualifier normalization
   needed (reloptions values like `fillfactor=70` never embed a schema
   name). **Currently expected empty on both sides** — grepped
   `priv/repo/migrations/` for `:options` (the Ecto migration DSL's
   `create table(..., options: ...)` mechanism for `WITH (...)`) and for a
   raw `execute("... WITH (..."` — no hits in any tenant-scoped migration —
   so this is, today, a count-equal-to-zero-options assertion, same shape as
   triggers/comments, not evidence of current divergence. If a future
   migration adds table storage options, this check catches a clone that
   silently drops them, which the mechanism (§2.3) would then need a new
   step for (`ALTER TABLE ... SET (...)` after the `LIKE`, sourced from the
   template's own `reloptions`) — flagged as Open Question OQ-5 below,
   parallel to OQ-2's triggers gap, rather than designed against a
   currently-nonexistent case.

10. **Per-column statistics target (`pg_attribute.attstattarget`)** —
    REWORK ADDITION, found during this rework's own systematic catalog walk
    (§0.2 finding 3), not flagged by the validator but the same class of
    gap: `ALTER TABLE ... ALTER COLUMN ... SET STATISTICS <n>` overrides the
    planner's sampling depth for that column, stored in
    `pg_attribute.attstattarget`. Verified directly: a template column set
    to `STATISTICS 500` clones to `-1` (the "use the default" sentinel) —
    `LIKE ... INCLUDING ALL` does NOT copy this, confirmed empirically
    (Postgres's own `INCLUDING ALL` documentation does not list statistics
    targets among what it copies, consistent with what was observed). New
    check: `attstattarget` compared per column between reference and
    candidate. Currently expected `-1`/`-1` (default/default) on both sides
    — grepped `priv/repo/migrations/` for `SET STATISTICS` — no hits in any
    tenant-scoped migration, so today this is a defaults-match-by-construction
    assertion, not a currently-open gap; a future migration tuning a
    column's statistics target would be caught rather than silently dropped
    by a clone.

11. **Extended statistics objects (`pg_statistic_ext`, `CREATE STATISTICS`)**
    — REWORK ADDITION, found during this rework's own systematic catalog
    walk (§0.2 finding 4): the OPPOSITE direction of gap from #9/#10 above —
    verified directly that `LIKE ... INCLUDING ALL` DOES copy an extended
    statistics object (`CREATE STATISTICS ... (dependencies) ON a, b FROM t`)
    to the clone, with a renamed identifier (same auto-naming behavior
    already documented for indexes in §0.1 finding 2 / dimension #4 above —
    `events_stat` became `events3_parent_id_total_stored_stat` in the probe).
    Since none currently exist (grepped `priv/repo/migrations/` for
    `CREATE STATISTICS` and for Ecto's migration-DSL equivalent if any — no
    hits), this is a count-equal-to-zero rule-out today, listed explicitly
    rather than omitted, consistent with how indexes' own renaming is
    already handled: if a future migration adds one, the parity check would
    need to compare `pg_statistic_ext` definitions structurally (via
    `pg_get_statisticsobjdef(oid)`, schema-qualifier-normalized, compared as
    a per-table multiset — the identical shape already used for indexes and
    constraints) rather than by name, for the same reason indexes must not
    be compared by name.

12. **Row-level security, partitioning, tablespace, table persistence,
    ownership — checked and found not-applicable, not omitted.** Verified
    directly (§0.2 finding 5): `pg_class.relrowsecurity`/
    `relforcerowsecurity` are `false`/`false` on every tenant-scoped table
    today (no migration issues `ENABLE ROW LEVEL SECURITY` — grepped, no
    hits); `relkind` is `r` (ordinary table, never `p` partitioned) and
    `relispartition` is `false` on every table (no migration issues
    `PARTITION BY` — grepped, no hits); `reltablespace` is `0` (default
    tablespace) on both template and clone tables alike, since neither this
    design nor any existing migration ever issues `TABLESPACE`; `relowner`
    is the single configured `letflow` role on both sides, for the same
    reason privileges are ruled out above. None of these differ between a
    migration-built schema and a cloned one under this codebase's current
    migration set, and none of the four is plausibly test-relevant given
    that current set — not included as an active check, listed here so a
    reader can see they were considered rather than missed.

13. **Column type and collation NAMESPACE — not just name/rendering** —
    REWORK 2 ADDITION, the fix for CODE-DESIGN-VALIDATOR's MAJOR finding and
    the collation-schema gap §0.3 found alongside it while re-examining the
    same method. For every column, in addition to dimension #2's
    name/data-type/nullable/default comparison: resolve the column's TRUE
    type via `pg_attribute.atttypid` joined through `pg_type` to
    `pg_type.typnamespace::regnamespace`, and its TRUE collation (when
    non-default, i.e. `pg_attribute.attcollation <> 0`) via
    `pg_attribute.attcollation` joined through `pg_collation` to
    `pg_collation.collnamespace::regnamespace`. Assert, per column: (a) if
    the type/collation is a Postgres built-in (`typnamespace`/`collnamespace`
    resolves to `pg_catalog`), both sides must show `pg_catalog` — this
    covers the overwhelming majority of columns today, is expected-equal by
    construction, and is asserted rather than assumed, matching this
    design's established pattern; (b) if the type/collation is
    **schema-qualified to anything other than `pg_catalog`**, its namespace
    on the CANDIDATE side must equal the candidate's OWN schema, never the
    reference schema's — the direct, mechanical test for the DOMAIN/ENUM/
    custom-collation coupling this section exists to close, symmetric in
    shape to dimension #5's sequence-namespace assertion (`pg_get_serial_sequence`'s
    result must live in the candidate's own schema, never the reference's).
    `format_type(atttypid, atttypmod)` (schema-qualifier-normalized, per
    §3.3's general technique) is used for the human-readable diff message on
    failure, but the actual pass/fail assertion is the structural
    `typnamespace`/`collnamespace` comparison above, not string matching on
    `format_type`'s rendered output — the same "structural, not name/string
    based" discipline dimension #4 (indexes) already established, applied
    here to a different catalog. **Currently a defaults-only assertion**:
    grepped `priv/repo/migrations/` for `CREATE TYPE`, `CREATE DOMAIN`, and
    `CREATE COLLATION` — zero hits for all three, confirmed rework 2 — so
    every column in the real tenant schema today resolves to a
    `pg_catalog`-owned built-in type and the default (`pg_catalog`-owned)
    collation, meaning branch (a) is what actually fires today and branch
    (b) is exercised only by this design's own probes, not by the real
    schema. Same "live check, currently-default operands" soundness class
    the validator already accepted for dimensions #9-#11 — not a
    theoretical check that does nothing, a real one whose current inputs
    happen to be at their default. See OQ-6 (§9) for what the CLONE MECHANISM
    (§2.3) does NOT yet do about a future non-default case, and why that is
    the correct current state rather than a gap.

### 3.3 Comparison mechanics (structural, not name-based)

Every dimension above that compares strings containing a schema name (FK
defs, index defs, sequence defaults, comment text) normalizes by replacing
the reference schema's own name with a placeholder token and the candidate
schema's own name with the same placeholder, before string-equality — the
exact technique verified in §0.1 (`replace(text, schema || '.', '')`, applied
symmetrically to both sides being compared, not just the write path). This
is what makes the check schema-name-agnostic and therefore reusable for
BOTH of §3.4's two use sites without parameterizing on which side is the
"real" one.

### 3.4 Where this check actually runs (turning it into a real, runnable test)

Two concrete, runnable uses — this is the artefact TEST-DESIGNER turns into
test code:

1. **Template self-parity, at template build time** (`ensure_template!/0`
   step 3, §2.3). Builds a SECOND schema via the real, unmodified
   `replay_migrations/2` production path (a genuine migration-built
   reference), then calls
   `assert_clone_parity!("tenant_template", <that reference schema>)`
   restricted to dimensions #1-6 and #8-#13 (NOT #7, since a fresh
   `replay_migrations/2` call and the template's own build both seed
   `event_type_registry` identically by construction, but row-for-row
   `event_type_registry` equality is still a meaningful assertion and IS
   included). This is the check that would have caught ISSUE-FIXER's two
   found hazards if they had gone unfixed — a template built without the FK
   re-add step, or one whose event-type seed step was forgotten, fails this
   check at build time, before any test ever consumes a clone from it. Runs
   ONCE per template build (§4.2), not once per clone — its cost is
   amortized across every test in the run.
2. **Clone-vs-template parity, exercised by a dedicated test file**
   (`test/support/tenant_template_test.exs`, TEST-DESIGNER's artefact) that
   clones a throwaway tenant and calls
   `assert_clone_parity!("tenant_template", <clone's own schema_name>)`
   across ALL thirteen dimensions #1-13. This is the test that stays green build after
   build and is what "constraint parity must be ASSERTED, not assumed" (the
   issue's own words) cashes out to as an actual, permanent, always-run
   regression test — not a one-time manual check this design doc merely
   describes.

Both use the SAME `assert_clone_parity!/2` function — one artefact, two call
sites, per the dispatch's ask for "a concrete, runnable comparison ... that
TEST-DESIGNER can turn into a real test," not a bespoke one-off script.

## 4. Where the template lives, when it is built, lifecycle

### 4.1 `TenantFixture.provisioned_tenant!/1` integration

`provisioned_tenant!/1`'s existing five-step sequence (moduledoc: Sandbox
mode, Tenant insert, on_exit registration, `provision_tenant_schema/1`,
`replay_migrations/1`, `assert_schema_complete!/2`) gains a **branch at
steps 4-5**: instead of always calling
`TenantProvisioning.provision_tenant_schema/1` then
`TenantProvisioning.replay_migrations/1`, it calls
`Letflow.Test.TenantTemplate.ensure_template!/0` (idempotent, cheap after
the first call — see §4.2) followed by
`Letflow.Test.TenantTemplate.clone_tenant_schema!(tenant.id)`. Step 6
(`assert_schema_complete!/2`) is UNCHANGED and still runs — it is the
existing, independent completeness oracle, and running it against a cloned
schema too is a second, free layer of assurance on top of §3's dedicated
parity check (belt and suspenders, matching this codebase's established
style of "neither of the last two subsumes the other," per
`assert_schema_complete!/2`'s own docstring).

`opts` gains one new key: `template: :clone | :replay` (default `:clone`).
`:replay` preserves EXACTLY today's behavior (calls
`provision_tenant_schema/1` + `replay_migrations/1` directly, no template
involved) — kept as an explicit escape hatch for any test that has a
concrete reason to want a real, freshly-migrated-from-scratch schema (e.g. a
test specifically about migration replay behavior itself, or a test that
intentionally passes a non-default `migration_source`, which the clone path
cannot serve at all — see §5's fallback discussion for why this is an
explicit opt-out, not a silent one). No existing call site's behavior
changes unless it is edited to pass `template: :replay` or relies on
default — **default changes from "always replay" to "clone by default,"
which IS a behavior change worth flagging explicitly**: see §8 INV-2 and the
Open Question OQ-3 below on whether this default flip needs a documented
migration note for the 49 existing call sites.

### 4.2 "Once" — scoped per BEAM VM / per test database, not per suite

Per Step 00's own finding, `scripts/test_parallel.sh` runs up to N partitions
in **separate BEAM VMs against separate Postgres databases**
(`letflow_test<N>`, one physical database per `MIX_TEST_PARTITION` value,
confirmed via `config/test.exs:65`). A template schema lives inside ONE
database, so **"once" means once per BEAM VM's lifetime, i.e. once per
partition's `letflow_test<N>` database**, not once globally across a
parallel run. `ensure_template!/0`'s idempotency marker (§2.1) is therefore
process-local state — a `persistent_term` or a module-level `Agent` started
lazily by `ensure_template!/0` itself (test-only, so no
`application.ex` supervision-tree entry is needed or wanted, matching
`TenantFixture`'s own "not a supervised process" stance) — NOT a
cross-VM/cross-database coordination mechanism, because none is needed: each
partition's database is already isolated by `test_parallel.sh`'s own design,
so each BEAM VM independently builds its own `"tenant_template"` schema in
its own database, exactly once, the first time any test in that partition
calls `provisioned_tenant!/1`.

Within one partition, MULTIPLE tests may call `provisioned_tenant!/1`
concurrently only if they are `async: true` — and per ISS-0423's own
finding, `Sandbox.mode(Letflow.Repo, :auto)` (which `provisioned_tenant!/1`
calls unconditionally, unchanged by this design) already defeats `async:
true` globally for the whole Repo the moment any test using this fixture
runs. So under TODAY's actual behavior, calls to `ensure_template!/0` are
already serialized by that same global sandbox mode — no NEW concurrency
hazard is introduced by this design that didn't already exist. **This
design does not fix ISS-0423's `Sandbox.mode(:auto)` problem and does not
assume it will be fixed** — see §4.3 for what happens if a future change
does make these calls genuinely concurrent.

### 4.3 Concurrency guard (forward-looking, not currently load-bearing)

`ensure_template!/0`'s build sequence (§2.3) is wrapped in the SAME
`pg_advisory_xact_lock` pattern `provision_tenant_schema/1` already uses for
its own idempotent-concurrent-call safety (`SELECT
pg_advisory_xact_lock(hashtext($1))` keyed on the literal string
`"tenant_template"` rather than a per-tenant schema name) — cheap to add,
matches an established in-codebase idiom exactly, and makes this design safe
even if ISS-0423 later changes `Sandbox.mode` behavior in a way that makes
concurrent `ensure_template!/0` calls within one partition possible. Without
it, two concurrent first-callers could both see `:not_built` and both
attempt `CREATE SCHEMA "tenant_template"` — the second would hit a real
Postgres error (no `IF NOT EXISTS` deliberately, per §2.3 step 1's own
"IF NOT EXISTS" being used ONLY there specifically because concurrent
first-build IS a real, if currently-rare, race) rather than corrupting
state, but the advisory lock avoids the wasted work and the error entirely.

## 5. Fallback and failure behavior

**No silent fallback to migration replay.** If `ensure_template!/0` fails at
any step — `CREATE SCHEMA` fails, migration replay into the template fails,
or the template's own self-check (§2.3 step 3, or a first-build run of
§3.4's self-parity check) fails — it raises, the same way
`TenantFixture.report_and_raise/3` already raises today for a provisioning
failure. **This is a deliberate choice, not a default carried over by
inertia**: per the dispatch's own framing, "silent fallback to migration
replay would hide breakage" — a template that silently degrades to per-test
replay would make every subsequent clone attempt in that partition either
also fail (loud, fine) or, worse, succeed against a DIFFERENT template state
than what the self-check validated, reintroducing exactly the kind of
unverified-parity risk this whole design exists to close. A hard failure
here fails the FIRST test in a partition that needs a tenant loudly, with a
clear cause, rather than letting the whole partition's tenant-dependent
tests either mysteriously slow back down to replay cost or silently run
against divergent schemas.

**`clone_tenant_schema!/1` failing for one test does not retry against
replay either**, for the same reason — it returns `{:error,
{:clone_failed, reason}}`, and `TenantFixture`'s call site raises via its
existing `report_and_raise/3`, exactly as a `provision_tenant_schema/1` or
`replay_migrations/1` failure already does today. A test author who hits
this and needs to unblock immediately has the explicit `template: :replay`
escape hatch (§4.1) available per-call — that is the sanctioned "fallback,"
and it is opt-in per test, never automatic.

**What "stale template" means and how it is caught, not just described.**
ISSUE-FIXER's diagnosis flagged "a stale template that only has 40 of 53
migrations applied would silently under-provision every clone" as a risk
with no existing detection mechanism. §2.3 step 3's self-check (versions
present in `"tenant_template".schema_migrations` vs
`tenant_scoped_migrations/0`'s current manifest) IS that mechanism, and it
runs at template-build time — every partition's BEAM VM re-builds its OWN
template fresh at the start of that partition's run (§4.2: "once" is scoped
per-VM, and a VM starts with a fresh/freshly-migrated `letflow_test<N>`
database per the existing `mix ecto.reset`-equivalent flow this repo already
uses between runs), so "stale" in the sense of "built against an old
manifest, never rebuilt" cannot persist ACROSS runs by construction — there
is no on-disk/persistent template artifact this design introduces that
could outlive a single test-run's database lifetime. The template is exactly
as fresh as the manifest was when that partition's BEAM VM started.

## 6. Interaction with `Letflow.SandboxPool`

Confirmed complementary, not competing, per ISSUE-FIXER's diagnosis (v):
`SandboxPool.provision_sandbox/2` (sandbox_pool.ex:943) already builds its
pooled schemas via `CREATE SCHEMA` + `Ecto.Migrator.run/4` against
`TenantProvisioning.tenant_scoped_migrations()` directly — the exact same
primitive this design's `ensure_template!/0` step 2 uses. **This design does
not modify `sandbox_pool.ex`.** A future, separate change COULD have
`SandboxPool.provision_sandbox/2` call
`Letflow.Test.TenantTemplate.clone_tenant_schema!/1` internally instead of
running `Ecto.Migrator.run/4` itself, which would let the pool's own
provisioning inherit this design's speedup — but that is optional future
work, explicitly not required by this issue's scope, and not designed here
(no signature or behavior of any `sandbox_pool.ex` function is specified by
this document). Flagged as Open Question OQ-4 below rather than silently
assumed.

## 7. Production-path reachability (explicit, per the dispatch's requirement)

**None of the functions this design adds are reachable from production
tenant onboarding.** `Letflow.Test.TenantTemplate` lives entirely under
`test/support/`, compiled only under `elixirc_paths(:test)` (an existing
`mix.exs` config this design relies on, does not change). It is called only
from `test/support/tenant_fixture.ex` (also test-only) and from
TEST-DESIGNER's new test file (`test/support/tenant_template_test.exs`).
`Letflow.TenantProvisioning.provision_tenant_schema/1` and
`replay_migrations/2` — the two functions real tenant onboarding calls — are
not modified: no new clause, no new default argument, no new branch inside
either function. This design's ONLY dependency in the `lib -> test`
direction is read-only, pre-existing public API
(`schema_name_for_tenant/1`, `tenant_scoped_migrations/0`) that already has
other test-only callers today (`TenantFixture` itself, `SandboxPool`'s own
test-adjacent-but-actually-lib-resident status is a pre-existing fact this
design does not change). **If SECURITY-REVIEWER's gate scope needs a single
sentence: this change touches zero files under `lib/letflow/` and zero
production call paths; its entire diff surface is `test/support/`.**

One nuance worth flagging rather than glossing: `maybe_seed_platform_event_types/2`
and `@platform_event_type_seed_attrs` are currently PRIVATE
(`defp`) inside `lib/letflow/tenant_provisioning.ex` (a production module).
§2.3 step 2 needs that seed list to populate the template. See OQ-1 — this
is the one place this design's mechanism brushes up against
`lib/letflow/tenant_provisioning.ex`'s own surface, and it is called out
explicitly rather than silently assumed resolvable.

## 8. Invariants

- **INV-1 (schema-name discrimination).** `"tenant_template"` is never
  producible by `schema_name_for_tenant/1` and never accepted by
  `tenant_id_for_schema_name/1` — verified in §2.2, must remain true if
  either function's regex ever changes (a REVIEWER-checkable regression, not
  just a one-time fact).
- **INV-2 (default behavior change is explicit, not silent).**
  `provisioned_tenant!/1`'s default flips from always-replay to
  clone-by-default. This IS a behavior change to 49 existing test call
  sites' provisioning mechanism (though not to their observable schema
  shape, which §3's parity check exists to guarantee) — recorded here so
  REVIEWER and TEST-DESIGNER both see it named, not discovered as a diff
  surprise.
- **INV-3 (no cross-test sequence-value coupling).** A clone's sequence(s)
  always start at their type default (1), never inherit the template's
  current `last_value`. No test may assert a specific absolute sequence
  value carried over from a prior clone or from the template.
- **INV-4 (template is never a real tenant).** No `Registration` row, no
  `Tenant` row, ever exists for the template. `list_registrations/0` (used
  by `Letflow.ServiceCatalog`'s cross-schema referential guard) must never
  enumerate `"tenant_template"` as a tenant schema — true by construction
  since that function only reads `Registration` rows and none is ever
  inserted for the template. **Consequence, stated explicitly (added this
  rework, per gate feedback):** `Letflow.TenantSchemaReaper.sweep_orphans/2`
  (`test/support/tenant_schema_reaper.ex`, the module responsible for
  sweeping orphaned tenant schemas at suite boundaries) selects its
  candidates via `SELECT id, tenant_id, schema_name FROM tenant_schemas
  WHERE provisioned_at < $1` — verified by reading the function directly —
  i.e. it drops only schemas named by rows in the SAME `tenant_schemas`
  table `Registration`/`list_registrations/0` reads, never by walking
  Postgres's own `pg_namespace` catalog for schema names directly. Since
  INV-4 guarantees no `tenant_schemas` row is ever inserted for
  `"tenant_template"`, the reaper's query can never return it as a
  candidate — the reaper is STRUCTURALLY incapable of ever selecting the
  template schema for a drop, with no special-casing, denylist, or name
  check required anywhere in the reaper's own logic. The safety comes for
  free from INV-4 holding, not from any reaper-side awareness of the
  template's existence. This is worth stating plainly rather than leaving
  implicit, since a future reader auditing "what stops the reaper from
  eating the template mid-run" would otherwise have to re-derive it from
  INV-4 and the reaper's own query shape independently.
- **INV-5 (parity is asserted every run, not just at template build).**
  `assert_clone_parity!/2`'s clone-vs-template use site (§3.4 item 2) is a
  permanent test, not a one-time manual verification — it runs every time
  the suite runs, catching a future regression in the clone mechanism
  itself (e.g. someone editing §2.3's FK/sequence steps and breaking them)
  the same way any other regression test would.
- **INV-6 (production path is untouched).** Zero diff to
  `provision_tenant_schema/1`'s or `replay_migrations/2`'s own function
  bodies. See §7.

## 9. Open questions (not silently resolved)

- **OQ-1.** `@platform_event_type_seed_attrs` and the seeding logic in
  `maybe_seed_platform_event_types/2` are private to
  `lib/letflow/tenant_provisioning.ex`. The template build (§2.3 step 2)
  needs equivalent seeding. Two options, neither chosen here:
  (a) make `TenantProvisioning` expose a minimal public function
  (e.g. `seed_platform_event_types(tenant_id)` taking an already-provisioned
  schema's owning tenant_id, or restructured to accept a schema_name
  directly) that the test module calls — a small, explicit, test-serving
  addition to a production module's public surface (same shape as the
  already-precedented `list_registrations/0` addition for REQ-191, per that
  function's own docstring); or (b) have the test module build its OWN
  synthetic "tenant" (a real, throwaway `Tenant` + `Registration` row) and
  call the real, unmodified `replay_migrations/2` to build the template,
  discarding the `Tenant`/`Registration` rows afterward but keeping the
  schema — sidesteps touching `lib/letflow/tenant_provisioning.ex` at all,
  at the cost of the template no longer being distinguishable from "just
  another tenant" at the DB level during its own brief construction window
  (mitigated by never registering the resulting `"tenant_template"` name
  as reachable via `tenant_id_for_schema_name/1`, per INV-1, but the
  `Registration` row would transiently exist for a different, throwaway
  schema name during the build, then get deleted). ELIXIR-DEV/REVIEWER must
  pick one before implementation — (b) keeps §7's "zero lib/ diff" claim
  literally true; (a) is architecturally cleaner but requires a
  SECURITY-REVIEWER-visible (if trivial) addition to a tenant-data-path
  module's public surface. This design does not decide between them.
- **OQ-2.** §3.2 item 8 notes triggers are a documented exception to
  `INCLUDING ALL` and are currently absent from every tenant-scoped
  migration. If a future migration adds a trigger, this design's clone
  mechanism (§2.3) does NOT yet recreate triggers — the parity check would
  catch the resulting drift (loudly, per §5's no-silent-fallback stance),
  but the clone mechanism itself would need a new step symmetric to FK
  re-add. Not designed here since no trigger exists today to design against
  concretely; flagged so it is not forgotten when one is added.
- **OQ-3.** Whether flipping `provisioned_tenant!/1`'s default (INV-2)
  warrants a `docs/migration/decisions/` record of its own, given this
  project's convention of recording decisions that affect established
  patterns across 49 call sites — CODE-DESIGNER's own judgement is that
  this is test-infrastructure-internal and does not rise to that bar (no
  production behavior, no cross-stage architectural commitment), but it is
  named here rather than silently assumed, per this role's own forbidden-
  list about not silently resolving open questions.
- **OQ-4.** Whether `SandboxPool` should be migrated to build its pooled
  schemas via `clone_tenant_schema!/1` instead of its own direct
  `Ecto.Migrator.run/4` call (§6) — explicitly NOT decided here, left to a
  future issue/requirement if the win is judged worth it once this design's
  real-world speedup is measured (§10).
- **OQ-5 (added rework 1).** §3.2 dimensions #9 (`reloptions`) and #10
  (`attstattarget`) are currently zero-vs-zero rule-outs (no tenant-scoped
  migration sets either today), so §2.3's clone mechanism has no
  corresponding recreation step. If a future migration introduces a table
  storage option or a per-column statistics-target override, the parity
  check (§3.2) will catch the resulting clone/template divergence
  immediately and loudly (per §5's no-silent-fallback stance) — but the
  clone mechanism itself would then need two new steps symmetric to §2.3
  step 4's FK handling: `ALTER TABLE ... SET (<reloptions from template>)`
  and `ALTER TABLE ... ALTER COLUMN ... SET STATISTICS <n>` sourced from the
  template's own `pg_attribute.attstattarget`. Not designed here since
  nothing exists today to design a concrete recreation step against — same
  posture as OQ-2's triggers gap, and named explicitly for the same reason.
- **OQ-6 (added rework 2).** §3.2 dimension #13 (column type/collation
  namespace) is, like OQ-5's dimensions, currently a defaults-only
  assertion: no `CREATE TYPE`/`CREATE DOMAIN`/`CREATE COLLATION` exists in
  any tenant-scoped migration today (grepped, zero hits for all three), so
  §2.3's clone mechanism has no corresponding recreation step. If a future
  migration introduces a custom domain, enum, or collation, dimension #13
  will catch the resulting clone/template type-object coupling immediately
  and loudly (§5's no-silent-fallback stance — and per §0.3, this is a more
  severe failure mode than OQ-5's if left uncaught: dropping the template
  schema can cascade into and destroy a clone's own columns, not merely
  leave a stale/coupled default value as the sequence trap did before it was
  fixed). The mechanism would then need a new step symmetric to §2.3 step
  4's FK re-add and step 5's sequence recreation: create a clone-local
  `DOMAIN`/`TYPE`/`COLLATION` object (built from the template's own
  definition — e.g. `pg_get_constraintdef`-style introspection of a domain's
  CHECK constraints, or enumerating an enum's labels via `pg_enum`, or the
  collation's `pg_collation` provider/locale/deterministic settings) in the
  clone's own schema, then repoint the affected column(s) to it before or
  as part of the `LIKE` step. Not designed here since nothing exists today
  to design a concrete recreation step against — same posture as OQ-2 and
  OQ-5, and named explicitly for the same reason, per §0.3's own statement
  of what the clone mechanism does (nothing, correctly) about this today.

## 10. Expected speedup — stated honestly

**What is known:** on this dev host, this session, compile-isolated,
in-connection measurement: bare `LIKE ... INCLUDING ALL` clone (no FK/
sequence fix-up) is 2.5x faster than full migration replay (354.2ms vs
877.21ms average, 5 vs 8 runs respectively). This design's FULL clone
mechanism (§2.3) adds FK re-add (22 constraints on the real schema — cheap,
individual `ALTER TABLE ADD CONSTRAINT` statements) and sequence
recreation (1 sequence on the real schema today) on top of the bare
354.2ms figure — the added DDL is small in both statement count and
individual cost relative to the 53-migration replay it replaces, so the
2.5x ratio is expected to hold approximately, not to collapse back toward
1x, but this design does NOT have a fresh measurement of the FULL
mechanism (bare clone + FK-readd + sequence-fix + data-copy, all together)
on this host — that measurement is TEST-RUNNER's/RELEASE-VALIDATOR's job
once implemented, not asserted here as already known.

**What is explicitly NOT known and not promised:**
- The CI number. Per ISS-0432's own caveat (already appended to ISS-0427),
  ~92% of this host's measured round-trip cost is Docker Desktop
  host↔container network overhead, not Postgres or BEAM compute. On CI
  (`ubuntu-latest`, no Docker Desktop layer) or a co-located production-like
  host, the ABSOLUTE savings could be far smaller in wall-clock terms even
  if the RATIO (fewer round trips = fewer chances to pay the per-call tax)
  holds directionally. ISSUE-FIXER's own extrapolation put a co-located
  replay at roughly 70-100ms — if that holds, the clone path's absolute
  savings on CI could be single-digit-to-low-tens of milliseconds per
  provisioning, not the ~500ms this host shows. This design does not
  promise a CI number nobody has measured.
- The suite-wide wall-clock share. ISSUE-FIXER could not confirm the filed
  755-provisioning count directly (no full-suite log with raw teardown
  lines existed at diagnosis time); it derived a static upper bound of ~919
  tests in fixture-calling files. This design does not restate 755 or 919
  as confirmed — TEST-RUNNER's Step 4 regression run, which must run the
  real suite regardless, is the natural point to obtain a fresh, real count
  and a fresh, real before/after wall-clock comparison. **Sizing the
  ultimate win at "roughly 2.5x on this host's provisioning cost, applied
  to however many provisionings the real suite performs, with the
  understanding that the absolute number will look smaller on CI" is the
  honest claim this design makes — not a specific promised percentage
  reduction in total suite wall-clock.**

## 11. Acceptance-criteria mapping

(Restated from ISS-0427's description, since the issue itself does not
enumerate a formal `acceptance_criteria` list the way a `REQ-NNN` would —
mapping the issue's own stated requirements to concrete design elements, per
this role's "no TBD" obligation.)

| Issue requirement | Design element |
|---|---|
| Clone from a prepared template instead of replaying 53 migrations per schema | §2.3 `clone_tenant_schema!/1`, backed by `ensure_template!/0` |
| FK constraints must be re-added, not silently dropped | §2.3 step 4, verified §0.1 finding 1 |
| Constraint parity must be ASSERTED, not assumed | §3 `assert_clone_parity!/2`, wired to two real runnable use sites in §3.4 |
| Test-only; production path untouched, or flagged for SECURITY-REVIEWER if not | §7 — zero `lib/letflow/` diff, explicitly stated; OQ-1's option (a) is the one path that would touch `lib/`, flagged, not chosen |
| Complementary to, not absorbing, ISS-0423 | §1 non-goals, §4.2's explicit non-fix of `Sandbox.mode`, §6 |
| Complementary to, not competing with, SandboxPool | §6 |
| Sequence/DEFAULT cross-schema coupling (the second hazard ISSUE-FIXER found, not in the original issue text) | §2.3 step 5, verified §0.1 findings 3-4, checked by §3.2 item 5 |
