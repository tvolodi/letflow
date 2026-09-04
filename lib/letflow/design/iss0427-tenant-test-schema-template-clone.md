# ISS-0427 — Tenant test-schema provisioning: clone from a prepared template

Status: design (WF-03 Step 2, rework 4 — WF03-ISS0427-20260904/step-06,
fixing two post-merge/near-merge defects: index/constraint NAME parity
§0.6 and `build_template!/0` crash-safety §0.7). Test-only. Does not change
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
   constraint triggers are created. **REWORK 3 UPDATE: this finding's own
   dormancy claim generalized too far** — confirming no CONSTRAINT trigger
   exists does not mean no trigger of any kind exists. See §0.4: five real,
   plain (non-constraint) triggers exist today and were missed by every
   pass up to and including this one, caught only when ELIXIR-DEV queried a
   real built template directly during implementation.

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

### 0.4 Rework 3 — the trigger-dormancy premise was false, live security-relevant surface, plus two mechanism corrections and a full dormancy re-audit

ELIXIR-DEV reached Step 3 (implementation), built the mechanism per this
design, and — while running the parity check against a real, freshly-built
template — found `pg_trigger` returned 5, not 0, directly contradicting this
design's own repeated, re-verified claim that no tenant-scoped migration
creates a trigger. This is the most severe finding of any rework so far:
unlike the DOMAIN/ENUM/collation gap (rework 2, dormant, zero current
migrations), this is LIVE, CURRENT surface, and the property it protects
(audit-log and artifact-repository immutability) is a security guarantee,
not a structural nicety. Had this shipped uncorrected, dimension #8 as
originally specified (count-equal-to-zero) would have PASSED every clone
while silently omitting all five triggers — the exact silent-degradation
failure mode ISS-0427 exists to prevent, now demonstrated as a real defect
this design would have shipped, not merely a hypothetical this design failed
to anticipate.

**The five real triggers, backing three real functions, confirmed by
reading the migration source directly:**

| Migration | Function (schema-qualified at apply time) | Trigger | Event |
|---|---|---|---|
| `20260830020001_create_audit_entries_tenant_scoped.exs` | `audit_entries_immutable()` | `audit_entries_no_update` | BEFORE UPDATE ON `audit_entries` |
| `20260830020001_create_audit_entries_tenant_scoped.exs` | `audit_entries_immutable()` | `audit_entries_no_delete` | BEFORE DELETE ON `audit_entries` |
| `20260830030001_create_repository_artifacts.exs` | `repository_artifacts_immutable()` | `repository_artifacts_no_update` | BEFORE UPDATE ON `repository_artifacts` |
| `20260830030001_create_repository_artifacts.exs` | `repository_artifacts_immutable()` | `repository_artifacts_no_delete` | BEFORE DELETE ON `repository_artifacts` |
| `20260830030001_create_repository_artifacts.exs` | `artifact_versions_immutable()` | `artifact_versions_no_update` | BEFORE UPDATE ON `artifact_versions` |

Each function is a fixed `plpgsql` body (`RAISE EXCEPTION '<table> is
immutable'`) created fresh, per-tenant-schema, inside its own migration's
`execute/1` block with the schema name interpolated at apply time (Decision
0003-B's physical-isolation model — no shared `public`-schema function to
reference across schemas). Independently re-verified against a real,
freshly-built template this rework (not inherited from ELIXIR-DEV's report):
built `probe_tpl.audit_entries` with an equivalent function/trigger pair,
confirmed `pg_get_functiondef`/`pg_get_triggerdef` both emit text literally
qualified to the source schema
(`CREATE OR REPLACE FUNCTION probe_tpl.audit_entries_immutable() ...`,
`... EXECUTE FUNCTION probe_tpl.audit_entries_immutable()`), confirmed a
`LIKE ... INCLUDING ALL` clone gets zero triggers (`pg_trigger` count 0),
then built and verified the fix end-to-end: created the function in the
clone schema via `pg_get_functiondef` with the schema qualifier textually
substituted, then the two triggers via `pg_get_triggerdef` with the same
substitution, confirmed the clone's function is a genuinely distinct object
(different OID, `pg_proc`/`pg_namespace` confirms `probe_clone` ownership),
confirmed the immutability guarantee fires against the clone
(`UPDATE ... SET val='y'` on the clone raised `ERROR: audit_entries is
immutable` from the CLONE's own function), and — checked specifically
because §0.3's DOMAIN/ENUM finding showed a superficially similar mechanism
can still leave a live coupling — confirmed the clone remains fully
functional after the TEMPLATE schema is dropped entirely (`DROP SCHEMA
probe_tpl CASCADE`, then `UPDATE` against the clone still raised the
expected exception from the clone's own function). This last check is the
one that distinguishes this fix from the DOMAIN/ENUM case: a function or
trigger created via `CREATE OR REPLACE FUNCTION`/`CREATE TRIGGER` in a
different schema is, by Postgres construction, a wholly new, independent
object with its own OID — not a shared reference the way a column's
`atttypid`/`attcollation` slot is, so once the schema-qualifier rewrite is
applied and the object is (re)created in the clone's own schema, there is
no residual coupling left to find, unlike domains/enums/collations, which
this section's step 6 does NOT attempt to fix (that remains OQ-6's deferred,
still-dormant case). All probe schemas from this check dropped clone-before-
template and confirmed gone (`SELECT nspname FROM pg_namespace WHERE
nspname LIKE 'probe%'` — 0 rows) before this document was written.

The fix — a new mechanism step (§2.3 step 6) and a corrected, non-vacuous
dimension #8 (§3.2 item 8) — is specified in full at each of those
locations; this section does not duplicate the specification, only the
verification trail.

**Point 3 — the full dormancy re-audit, per the coordinator's explicit
instruction to re-run every remaining claim, not just patch the one found
instance.** Every dormancy claim in this document was re-checked THIS
rework, by TWO independent methods where a real template made both
possible: (1) a wide, case-insensitive grep against
`priv/repo/migrations/*.exs` source (not narrowly anchored to the exact
phrasing a prior pass used — the trigger miss happened partly because
earlier greps were anchored to `execute("CREATE TRIGGER"` -style literal
patterns rather than a broad `CREATE TRIGGER` scan, per the coordinator's
own suspicion, and (1) below uses the broad form throughout), and (2) where
applicable, a direct catalog query against a real template built by
`ensure_template!/0`'s own mechanism (the same real template ELIXIR-DEV
built during implementation surfaced the trigger gap in the first place —
catalog ground truth, not migration-source inference, is what actually
caught it, so it is what this re-audit leans on wherever practical):

| Claim | How checked this rework | Result |
|---|---|---|
| Triggers (plain `CREATE TRIGGER`) | Wide grep: `grep -ril "CREATE TRIGGER\|CREATE CONSTRAINT TRIGGER" priv/repo/migrations/*.exs` (case-insensitive, no anchor to `execute("CREATE TRIGGER"` literal form) | **FALSE — 2 files, 5 triggers** (the finding this section documents). Confirmed live via a real probe template, per above. |
| Constraint triggers (`CREATE CONSTRAINT TRIGGER` specifically) | Same grep as above, filtered to the `CONSTRAINT` form | Zero hits — genuinely dormant, `contype='t'` remains a true zero-vs-zero rule-out (§3.2 dimension #3's own REWORK NOTE, unaffected by this finding). |
| Table-level storage parameters (`reloptions`/`WITH (fillfactor...)`) | Wide grep: `grep -ril "WITH (fillfactor\|WITH(fillfactor\|options:\s*\[" priv/repo/migrations/*.exs`, plus re-reading every `execute(` call in the migration tree (18 call sites total, enumerated below) for anything storage-option-shaped | Zero hits. Every `execute(` call in the tree is either a trigger/function definition (the finding above), an `ALTER TABLE ... ADD CONSTRAINT ... CHECK (...)` (already covered by dimension #3), a partial `CREATE INDEX ... WHERE ...` (already covered by dimension #4), or a one-time `DO $$ ... $$` data-migration block with no persistent structural residue (`20260819000004_drop_legacy_public_identity_tables.exs`'s legacy-table drop, `20260830000004_add_secret_ref_to_webhook_subscriptions.exs`'s secret-blanking) — none is a `reloptions`-shaped statement. Confirmed still dormant. |
| Per-column statistics target (`SET STATISTICS`) | Wide grep: `grep -ril "SET STATISTICS" priv/repo/migrations/*.exs` | Zero hits. Confirmed still dormant. |
| Extended statistics objects (`CREATE STATISTICS`) | Wide grep: `grep -ril "CREATE STATISTICS" priv/repo/migrations/*.exs` | Zero hits. Confirmed still dormant. |
| Custom types/domains (`CREATE TYPE`/`CREATE DOMAIN`) | Wide grep: `grep -ril "CREATE TYPE\|CREATE DOMAIN" priv/repo/migrations/*.exs` | Zero hits. Confirmed still dormant (OQ-6 remains correctly deferred). |
| Custom collations (`CREATE COLLATION`) | Wide grep: `grep -ril "CREATE COLLATION" priv/repo/migrations/*.exs` | Zero hits. Confirmed still dormant (OQ-6 remains correctly deferred). |
| Comments of any kind (`COMMENT ON`) | Wide grep: `grep -ril "COMMENT ON" priv/repo/migrations/*.exs` | Zero hits. Confirmed still dormant (dimension #8's table/column and index/constraint comment rule-outs both hold). |
| Row-level security (`ROW LEVEL SECURITY`) | Wide grep: `grep -ril "ROW LEVEL SECURITY" priv/repo/migrations/*.exs` | Zero hits. Confirmed still dormant (dimension #12 rule-out holds). |
| Partitioning (`PARTITION BY`) | Wide grep: `grep -ril "PARTITION BY" priv/repo/migrations/*.exs` | Zero hits. Confirmed still dormant (dimension #12 rule-out holds). |
| Tablespaces (`TABLESPACE`) | Wide grep: `grep -ril "TABLESPACE" priv/repo/migrations/*.exs` | Zero hits. Confirmed still dormant (dimension #12 rule-out holds). |

**Why the trigger claim was the one that broke, stated as a real answer, not
a shrug.** Re-reading how each prior pass phrased its own trigger check: the
original draft and rework 1 both grepped specifically for `execute("CREATE
TRIGGER"` — a pattern anchored to the literal call shape the design's own
prose assumed a trigger-creating migration would use, which happens to be
exactly the call shape the real migrations do NOT use (the real migrations
call `execute(<multi-line heredoc>, <multi-line heredoc>)`, a two-argument
`execute/2`-shaped call with the SQL as a separate heredoc argument, not a
single-line `execute("CREATE TRIGGER ...")` string the anchored pattern
would match). This is precisely the coordinator's own suspicion, confirmed:
the earlier greps were "too narrow," not "not run" — they were run, against
a pattern that could not have matched the real migrations' actual call
shape even when the offending content was already present in the tree. The
wide `CREATE TRIGGER` scan used throughout this section's re-audit (and now
specified as the standing grep form in §3.2 item 8's corrected sub-bullet)
does not have this blind spot: it matches the SQL keyword itself, regardless
of which Elixir call shape carries it.

Two further, smaller corrections from ELIXIR-DEV's same handoff, folded
into the design text at their own locations (not merely narrated here):

- **§4.3's advisory-lock pattern, as literally written, does not work** —
  `Ecto.Migrator.run/4` (called by the template build, whether via the real
  `replay_migrations/2` per OQ-1 option (b), which ELIXIR-DEV adopted, or a
  direct call per option (a)) checks out its OWN Postgres connection rather
  than participating in an ambient `Repo.transaction`'s connection, so a
  transaction-scoped `pg_advisory_xact_lock` plus `CREATE SCHEMA` issued
  inside that same transaction is invisible to the migrator, reproducibly
  (`Postgrex.Error` 3F000, "schema does not exist"). Corrected in §4.3
  below to a session-level `pg_advisory_lock`/`pg_advisory_unlock` pair, not
  wrapped in a `Repo.transaction`, matching `SandboxPool.provision_sandbox/2`'s
  own already-established sequential pattern — scoped to `ensure_template!/0`
  only; `clone_tenant_schema!/1` (which never calls `replay_migrations/2`)
  is unaffected and still uses one `Repo.transaction` exactly as §2.3
  specifies.
- **Dimension #2's raw `ordinal_position` comparison false-fails on any
  table with a dropped column** — REQ-064's ten `tenant_id`-drop migrations
  leave a permanent ordinal gap in the TEMPLATE (e.g. `instance_projections`,
  `users`) that `LIKE ... INCLUDING ALL` does not preserve in the clone
  (Postgres renumbers a `LIKE`-built table's columns to consecutive
  positions regardless of the source's own drop history) — a benign,
  expected difference dimension #2 was never meant to catch. Corrected in
  §3.2 dimension #2 below to compare each side's own RELATIVE column order
  (re-ranked 1..N) rather than the raw absolute integer.


### 0.5 CRITICAL — the qualifier-rewrite pattern must be UNQUOTED (rework 3 gate correction)

Found by CODE-DESIGN-VALIDATOR at the re-gate-3 gate and independently
re-verified by ORCH against this host's live catalog. Earlier revisions of
this document wrote the substitution pattern as the QUOTED string
`'"tenant_template".'`. **That is wrong and fails silently.**

Postgres's `pg_get_constraintdef/1`, `pg_get_functiondef/1` and
`pg_get_triggerdef/1` emit a schema qualifier UNQUOTED whenever the
identifier needs no quoting — which `tenant_template` does not. Measured
directly:

```
CREATE OR REPLACE FUNCTION tenant_template.imm()
CREATE TRIGGER a_no_upd BEFORE UPDATE ON tenant_template.a
  FOR EACH ROW EXECUTE FUNCTION tenant_template.imm()
```

A `replace/3` searching for `"tenant_template".` (with quotes) therefore
matches NOTHING, and `replace/3` returns its input unchanged on a non-match.
The rewrite becomes a silent no-op, the DDL executes successfully, and the
clone is left with FKs, triggers and functions all still pointing at the
TEMPLATE schema — reintroducing the exact live cross-schema coupling this
whole design exists to prevent, with nothing failing and nothing to see.

The implementation already does this correctly
(`test/support/tenant_template.ex`, `readd_foreign_keys!/1` and the trigger
recreation step, both using the unquoted `~s(#{@template_schema}.)`), so no
shipped code is affected. This section exists because the DESIGN TEXT was
wrong, and a future re-implementation from this document, or a REVIEWER
auditing the code against its literal words, would have been led straight
into the defect.

Defence in depth: even if a re-implementation got this wrong, parity
dimension #8 (triggers/functions) and the FK half of dimension #3 compare
qualifier-normalized definition text between clone and reference and would
fail on exactly this divergence. The rewrite is the mechanism; the parity
check is the backstop. Neither alone is the guarantee.

### 0.6 Rework 4 — index/constraint NAMES are load-bearing (ISS-0427 post-merge defect, CODE-DESIGNER dispatch WF03-ISS0427-20260904/step-06)

**The assumption this design missed, stated plainly, per the dispatch's item
4.** §0.1 finding 2 and the rework-3 gate correction (dimension #4) both
established, correctly, that a cloned index's STRUCTURE (columns, predicate,
access method, uniqueness) is what must match the template's — never its
auto-generated NAME, because `LIKE ... INCLUDING ALL` renames every index
that is not the primary key. That reasoning is still correct as far as it
goes. What this design never stated, and should have: **`Ecto.Repo`'s
`unique_constraint/3` (and `foreign_key_constraint/3`,
`check_constraint/3`) resolve a Postgres constraint-violation error back to
a changeset field by matching the VIOLATING OBJECT'S NAME against a
`:name` option supplied at the call site** (Ecto's own default is derived
from the field/table the same way Postgres's migration-time default naming
is — see `docs/anti-patterns.md`'s NAMEDATALEN entry for the same root
mechanism cited already in §0.1 finding 2, applied there only to why a
name-based PARITY check is wrong, never followed through to "and therefore
the APPLICATION depends on the name being right"). **A structurally
identical but differently-named index is invisible to Ecto's error-mapping
layer**: the unique constraint still fires (correct data), but
`Ecto.Changeset.unique_constraint/3` cannot find `users_username_idx` in its
own list of `{:unique, "users_username_index"}` markers, so instead of
returning `{:error, changeset}` with a field-level error, `Repo.insert/1`
lets the raw `Ecto.ConstraintError` propagate — which is what turned seven
of ORCH's eight remaining suite failures into 500-shaped crashes instead of
clean 409s. **"Structurally equivalent" was necessary but not sufficient —
name identity is a SEPARATE, independently-load-bearing property this
design's parity check must also assert, not a redundant restatement of
structure.** This section is that correction; §3.2 dimension #4 below is
updated to match, and §2.3 step 3 gains the mechanism step that makes the
assertion true rather than merely checked-for.

**0.6.1 Which index names `LIKE ... INCLUDING ALL` preserves, and why —
settled by direct probe, not inferred.** Built two throwaway schemas in
`letflow_dev` (`probe_tpl`/`probe_clone`, dropped before this section was
written — verified via `pg_namespace`, 0 rows) modeling `users`' real shape:
a `PRIMARY KEY`, a plain expression unique index
(`users_username_index` on `lower(username)`), a partial unique index
(`users_external_identity_partial_index`), and a named table-level `UNIQUE`
constraint (`users_username_uq`). Result, `pg_indexes`/`pg_constraint`
queried directly on both sides:

| Template name | Kind | Clone name (auto-generated) |
|---|---|---|
| `users_pkey` | Primary key | `users_pkey` (unchanged) |
| `users_username_index` | Plain unique index (expression) | `users_lower_idx` |
| `users_external_identity_partial_index` | Partial unique index | `users_external_realm_external_id_idx` |
| `users_username_uq` | Named `UNIQUE` table constraint | `users_username_key` (the CONSTRAINT's `conname` renamed identically to its backing index) |

**The primary key name is not "preserved" by any special-case logic — it is
coincidentally regenerated identically.** Postgres's own default naming
convention for a `LIKE`-copied primary key is `<table>_pkey`, and that is
also the convention `mix ecto.gen.migration`'s `primary_key: true`/`:id`
column produces at the ORIGINAL migration-build time — the two independently
arrive at the same string because both use Postgres's own unqualified
default, not because `LIKE` treats the PK specially or "knows" the source
name. **This means the fix must not "skip renaming `users_pkey`" as a
special case — it is already correct by coincidence, and the general
mechanism (§2.3 step 3, below) naturally leaves it alone because its
auto-generated clone name already equals the template's name (a no-op
rename, or simply excluded because the names already match).** Every OTHER
index — including a named `UNIQUE` table CONSTRAINT's backing index — gets
Postgres's generic `<table>_<col(s)>_key`/`_idx`/`_idx1...` auto-naming and
therefore does need the fix.

**0.6.2 Constraint-backed indexes: `ALTER INDEX ... RENAME` renames the
owning constraint too, atomically, in one statement — verified, not
assumed.** This settles the dispatch's specific concern ("a unique
CONSTRAINT's index cannot simply be renamed independently of its
constraint"). Ran `ALTER INDEX probe_clone.users_username_key RENAME TO
users_username_uq` directly against the probe above. Result: `pg_constraint`
re-queried afterward shows `conname` is now `users_username_uq` — Postgres
updates the constraint's own catalog name as a side effect of renaming its
backing index, in the same statement, with no separate `ALTER TABLE ...
RENAME CONSTRAINT` needed and no window where the two names could
disagree. Confirmed functionally end-to-end: after renaming all three
non-pkey indexes back to their template names, a duplicate-`username`
insert into the clone raised `ERROR: duplicate key value violates unique
constraint "users_username_index"` — the template's own name, verbatim,
which is exactly the string `Ecto.Changeset.unique_constraint(:username,
name: :users_username_index)` (or the equivalent default-derived name) is
written to match against. This is a **single-statement, atomic, purely
catalog-level operation** — it does not touch the index's physical B-tree
data, only `pg_class.relname`/`pg_constraint.conname`.

**0.6.3 Mechanism decision: (b), `ALTER INDEX ... RENAME`, chosen over (a)
and (c) — cost measured, not assumed.**

- **(b) chosen.** Pair each clone index to its template counterpart by
  STRUCTURE (the exact comparison dimension #4 already computes —
  schema-qualifier-normalized, own-name-stripped `indexdef`, per-table
  multiset — already proven 1:1 unambiguous in this same probe: eight
  normalized `indexdef` rows across template+clone reduced to four distinct
  values, each appearing exactly twice), then `ALTER INDEX
  "<clone_schema>"."<clone_auto_name>" RENAME TO "<template_index_name>"`
  for every pair whose names already differ (skip the pair — there will
  always be at most one, the PK — whose auto-generated clone name already
  equals the template's). Measured cost, this probe, three renames on the
  real `users`-shaped table: **1.0-9.8ms each** (`\timing`, real numbers
  quoted, not estimated) — a pure `pg_class`/`pg_constraint` catalog update,
  no index rebuild, no table scan, no lock stronger than the same
  `ACCESS EXCLUSIVE` a `CREATE TABLE (LIKE ...)` already takes on the
  brand-new clone table nothing else can see yet.
- **(a) rejected — costs ~3-30x more per index for identical structural
  result, no correctness advantage.** Measured directly, same probe
  approach: `DROP INDEX` + `CREATE UNIQUE INDEX ... (lower(username))`
  (recreating one index from the template's `indexdef` with the name
  already correct because it comes from the source text) cost **1.5ms +
  30.1ms = ~31.6ms** — the `CREATE INDEX` half physically rebuilds the
  B-tree from a full table scan, which (b) never does. On a genuinely empty,
  freshly `LIKE`-copied clone table the scan is over zero rows, so the
  absolute gap will not scale with data volume the way it would on a
  populated table — but it is still a measured 3-30x per-index cost
  multiplier for a result (b) achieves identically, for no offsetting
  benefit: (a) does not avoid the constraint/index pairing problem either
  (a `CREATE UNIQUE INDEX` recreating a constraint-backed index does not
  itself recreate the `pg_constraint` row — that still requires a following
  `ALTER TABLE ... ADD CONSTRAINT ... UNIQUE USING INDEX <name>`, an
  extra statement (b) does not need). Rejected on cost with no correctness
  upside, not on any flaw in its structural correctness.
- **(c) (no `INCLUDING INDEXES`, build every index explicitly from the
  template's catalog) rejected — reintroduces the exact per-clone
  round-trip cost this whole issue exists to eliminate.** ISS-0427's own
  measured 2.5-4.9x win comes from `LIKE ... INCLUDING ALL` doing the bulk
  index/constraint/column copy in ONE `CREATE TABLE` statement per table
  instead of N migration-replay statements. (c) would replace that single
  statement with one `CREATE INDEX`/`CREATE UNIQUE INDEX` per index (each
  costing the same ~30ms full-rebuild-from-scan measured for (a) above,
  since (c) has no `LIKE`-copied starting point to rename), for every one
  of the real schema's ~105 indexes (§0's own count) — this would not be a
  clone anymore, it would be a hand-rolled re-implementation of
  `replay_migrations/2`'s own per-object DDL issuance, at the same or worse
  per-object cost, forfeiting the entire premise of the design. Rejected
  without needing a fresh measurement beyond what (a)'s per-index cost
  already establishes as the floor for any "recreate, don't rename"
  approach.

**0.6.4 The fix, concretely — new mechanism step and parity dimension.**
Both specified in full at their own locations (§2.3 new step 3.5, inserted
between the existing step 3's `LIKE` loop and step 4's FK re-add — chosen
this position because index renaming must happen before the parity/name
check ever runs, and has no ordering dependency on FK re-add, sequence
recreation, or trigger recreation, which touch different catalog objects
entirely; §3.2 dimension #4's updated specification) — this section states
the decision and its evidence, not a duplicate of the mechanism text.

All probe schemas from this section (`probe_tpl`, `probe_clone`,
`probe_tpl2`, `probe_clone2`, `probe_tpl3`, `probe_clone3`) dropped
clone-before-template in each case and confirmed gone (`SELECT nspname FROM
pg_namespace WHERE nspname LIKE 'probe%'` — 0 rows, checked twice, once
mid-sequence and once at the end) before this document was written.

### 0.7 Rework 4 — `build_template!/0` crash-safety (ISSUE-FIXER diagnosis, step-05 handoff)

**The defect, independently re-confirmed against ISSUE-FIXER's own
diagnosis rather than merely inherited.** `build_template!/0`'s first
statement, `CREATE SCHEMA IF NOT EXISTS "tenant_template"`, runs inside
`Sandbox.unboxed_run/2` (`sandbox: false` — no surrounding transaction) and
therefore commits immediately and unconditionally. If ANY later statement
in the same build raises — migration replay fails, the throwaway
`Registration` insert hits a stale-row unique violation (the MINOR below),
anything — the schema is left behind, physically real, permanently empty
(0 tables, not even `schema_migrations`). `template_built_in_db?/0` treats
"the schema exists in `information_schema.schemata`" as sufient evidence a
build succeeded or is at least safe to self-check; it is neither. Every
subsequent `ensure_template!/0` call in that same partition database then
finds the schema, runs the self-check, correctly finds 0/39 tables, and
raises `TENANT_TEMPLATE_SELF_CHECK_FAILED` — forever, for the rest of that
BEAM VM's life, with no self-repair path.

**Mechanism decision: atomic build-then-rename-into-place, not
detect-and-repair.** Two options were on the table (per the dispatch):

- **(i) Detect-and-repair.** `template_built_in_db?/0` (or
  `ensure_template!/0` itself) catches a self-check failure, `DROP SCHEMA
  "tenant_template" CASCADE`, and retries the build once. Rejected as the
  PRIMARY mechanism (see below for why it is still specified as a defensive
  second layer): it requires the self-check failure path itself to be
  perfectly reliable and non-recursive (what if the retry also fails
  partway? what bounds the retry count?), and it does nothing about the
  window BETWEEN the empty `CREATE SCHEMA` commit and the failure — any
  OTHER process (a concurrent test in a hypothetically-non-serialized
  future, per §4.3's own forward-looking concurrency note) that calls
  `ensure_template!/0` in that window would still observe the broken
  half-state and could itself raise or begin acting on it before the
  repair runs, because there is no way to make "detect a bad prior build"
  and "the schema briefly existed in a bad state" not both be true at
  once — repair is reactive, not preventive.
- **(ii) Atomic build-then-rename-into-place — CHOSEN.** Build the ENTIRE
  template (schema, all tables, indexes, FKs, sequences, triggers, seed
  data — the complete §2.3 sequence, unchanged in every other respect) under
  a randomized STAGING schema name (e.g. `"tenant_template_build_" <>
  <random hex>`, chosen fresh per build attempt so a crashed prior attempt's
  own staging schema — itself now orphaned debris, see the reaper note
  below — can never collide with a new attempt), and only as the LAST step,
  after the self-check (§2.3 step 3, now step 3-renumbered per §0.6's
  insertion) has PASSED against the staging schema, issue `ALTER SCHEMA
  "<staging_name>" RENAME TO "tenant_template"`. Postgres's `ALTER SCHEMA
  ... RENAME` is a single catalog-level statement — it does not move or
  rebuild any table, index, or row; it changes exactly one `pg_namespace`
  row. **This means `"tenant_template"` (the literal, well-known name every
  other function in this design and `TenantFixture` already looks up)
  never exists in Postgres's catalog at all until a build has fully
  succeeded and self-checked correctly** — there is no window, however
  brief, in which a caller could observe a schema by that name in any state
  other than "complete and self-checked." A crash at any point before the
  rename leaves ONLY the randomly-named staging schema behind, never
  `"tenant_template"` itself — so `template_built_in_db?/0`'s existing
  check (schema named `"tenant_template"` exists) is never satisfied by a
  half-built attempt, and no self-check-failure/retry path is needed for
  THIS failure mode at all, because the failure mode (a same-named,
  incomplete schema) is now structurally impossible to produce, not merely
  detected after the fact.

  **Orphaned staging schemas are debris, but inert, structurally-nameable,
  and cleanable by the SAME mechanism §0's own INV-4 already relies on for
  the template itself** — a crashed staging schema is never named
  `"tenant_template"`, is never registered via a `tenant_schemas` row (the
  throwaway `Registration` insert, per §2.2/OQ-1, still targets whatever
  schema name the build is CURRENTLY using — see the naming note below),
  and therefore cannot be mistaken for a live template or a live tenant by
  ANY existing code path — it is purely inert leftover schema-namespace,
  the same shape of harmless debris a crashed `SandboxPool.provision_sandbox/2`
  call already can leave today (this design introduces no new CLASS of
  cleanup problem, only a new INSTANCE of an already-accepted one). Not
  designed as an active sweep here (no code path currently sweeps orphaned
  staging schemas by pattern-matching `pg_namespace`, and none is required
  for correctness — see OQ-7 below for why this is deliberately deferred,
  not silently dropped).

**Naming detail, resolving the OQ-1 interaction explicitly.** The staging
schema's name is what `insert_throwaway_tenant_and_registration!/1` (§0.7's
MINOR, below) and every DDL statement in the build sequence must target
UNTIL the final rename — not `"tenant_template"` itself. This is a
mechanical substitution throughout §2.3's existing step list (every
`"tenant_template"` literal in steps 1-2 and the self-check in step 3
becomes the staging name; steps in §2.3 that already read from
`"tenant_template"` as an established, already-built fact — i.e. every step
of `clone_tenant_schema!/1`, which only ever runs AFTER `ensure_template!/0`
has returned — are unaffected, since by the time `clone_tenant_schema!/1`
runs, the rename has already happened and `"tenant_template"` is the real,
final name). Stated explicitly here rather than left for ELIXIR-DEV to
infer, per this role's own "don't silently resolve" obligation.

**The MINOR — `insert_throwaway_tenant_and_registration!/1` has no
upsert.** Confirmed by direct reading of ISSUE-FIXER's diagnosis and not
re-litigated (already reproduced twice with real Postgrex output in the
step-05 handoff): the throwaway `Registration` row's `schema_name` column
is unique-indexed, and a stale leftover row from an earlier interrupted
build permanently blocks every future build attempt targeting the SAME
schema name with a `unique_violation`. **This MINOR is subsumed, not just
coincidentally fixed, by the (ii) rename-into-place mechanism above**: once
each build attempt targets a FRESH, randomized staging schema name (never
reusing `"tenant_template"` literally, and never reusing a prior attempt's
own randomized name, since a new random suffix is drawn per attempt), the
throwaway `Registration` row's `schema_name` value is also fresh per
attempt, so a stale row from a PRIOR crashed attempt (naming that prior
attempt's own now-abandoned staging schema) can never collide with a NEW
attempt's insert — the two rows have different `schema_name` values by
construction. **This does not mean "no upsert is needed" as a general
rule** — it is specifically the randomized-staging-name choice that makes
collision structurally impossible for THIS row, not a claim that
`insert_throwaway_tenant_and_registration!/1` is safe to leave without
upsert in general. Recorded as resolved via the MAJOR's own fix rather than
needing a separate independent change, per the dispatch's "also in scope"
framing — ELIXIR-DEV does not need a second, unrelated upsert patch on top
of the rename mechanism to close this MINOR.

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

`ensure_template!/0` (build once per process/database) — **REWORK 4:
restructured around §0.7's atomic build-then-rename-into-place fix. Every
`"tenant_template"` literal below that appears BEFORE step 5's rename
targets a fresh, randomized STAGING schema name instead — see §0.7's
"Naming detail" for exactly which steps this affects.**

0. Generate a fresh staging schema name,
   `"tenant_template_build_" <> <16 random hex bytes>` (e.g. via
   `:crypto.strong_rand_bytes/1` + `Base.encode16/2`, lowercased — any
   collision-resistant per-attempt token; cryptographic strength is not the
   requirement, uniqueness-per-attempt is). Call it `staging_schema` for the
   rest of this sequence.
1. `CREATE SCHEMA "<staging_schema>"` (no `IF NOT EXISTS` — a fresh random
   name colliding with an existing schema would itself indicate a bug in
   the random-name generation, not a legitimate re-attempt case the way the
   OLD literal-named step 1 needed `IF NOT EXISTS` for).
2. `Ecto.Migrator.run(Repo, TenantProvisioning.tenant_scoped_migrations(), :up, all: true, prefix: staging_schema, log: false)`,
   then seed the 13 platform event types into `"<staging_schema>".event_type_registry`
   (see OQ-1) — mirrors exactly what `replay_migrations/2` does for a real
   tenant, applied to the staging schema instead. The throwaway
   `Tenant`/`Registration` row this step's OQ-1(b) implementation inserts
   (per ELIXIR-DEV's already-adopted resolution, §11) targets
   `staging_schema`, not the literal string `"tenant_template"` — see
   §0.7's MINOR fix, which this naming choice subsumes.
3. Self-check: assert the staging schema's own table set matches
   `TenantFixture.expected_tenant_tables/0` (reusing that existing oracle,
   not inventing a second one) and that `tenant_scoped_migrations/0`'s
   version list matches `"<staging_schema>".schema_migrations` exactly
   (reusing the exact query shape `TenantFixture`'s own `applied_versions_in/1`
   already uses). Raise immediately, do not proceed to renaming into place,
   if either check fails — a broken build must never become
   `"tenant_template"` (this is what ISSUE-FIXER's diagnosis (ii) flagged
   as "must design one" for staleness detection; this self-check is that
   mechanism, run at build time rather than trusted, and §0.7 is what
   makes a FAILED self-check's own schema harmless debris instead of a
   permanently-wedged `"tenant_template"`).
4. Delete the throwaway `Tenant`/`Registration` row (mirrors the existing
   `delete_throwaway_tenant_and_registration!/1` call, targeting
   `staging_schema`'s own throwaway row) — cleanup of BOOKKEEPING rows, not
   of the schema itself, which step 5 is about to rename rather than drop.
5. **Atomic commit point.** `ALTER SCHEMA "<staging_schema>" RENAME TO
   "tenant_template"` — per §0.7, a single catalog-level statement with no
   table/index rebuild. Only after this statement succeeds does
   `"tenant_template"` exist under its well-known name; every step above
   this one operates exclusively on `staging_schema` and can fail without
   ever producing a broken `"tenant_template"`.
6. Mark built (persist a `:built` marker — see §4.2 for exactly where).

**What this restructuring does NOT change:** the migration-replay
mechanism (step 2), the self-check's own two assertions (step 3, unchanged
in substance from the prior single-schema version), the "once per BEAM
VM/database" scoping (§4.2), and the session-level advisory-lock guard
(§4.3) — the lock still wraps this WHOLE numbered sequence 0-6, unchanged,
so two concurrent first-callers still cannot both attempt a build; the lock
was never keyed on the schema's own name (it is keyed on the fixed literal
string `"tenant_template"`, §4.3), so nothing about the staging-name change
affects it.

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
3.5. **Index/constraint rename to template names — REWORK 4 ADDITION,
   mandatory, not optional (§0.6).** `LIKE ... INCLUDING ALL` renames every
   non-primary-key index (and, for a named `UNIQUE`/`EXCLUDE` table
   constraint, its backing constraint along with it) to Postgres's
   auto-generated default name, which does not match the template's own
   name — and `Ecto.Changeset.unique_constraint/3`/`foreign_key_constraint/3`
   match violations by NAME, so a structurally-correct-but-misnamed index
   causes a raw `Ecto.ConstraintError` instead of a clean changeset error
   (§0.6 is the full finding; this step is the fix). Per table (walked over
   `expected_tenant_tables/0`, same stable order as step 3):
   1. Query the template's own indexes: `SELECT indexname, indexdef FROM
      pg_indexes WHERE schemaname = 'tenant_template' AND tablename =
      '<table>'`.
   2. Query the clone's just-created indexes the same way, schemaname =
      `<clone_schema>`.
   3. Pair each clone index to its template counterpart by comparing
      `indexdef` after (a) normalizing away the schema qualifier (the exact
      technique §3.3 already specifies) and (b) stripping the index's own
      name substring from the `CREATE [UNIQUE] INDEX <name> ON ...` prefix
      (the exact rework-3 gate correction already established for dimension
      #4, reused here rather than reinvented) — this yields, per §0.6.3's
      verified probe, an unambiguous 1:1 pairing (every normalized
      definition on the template side matches exactly one on the clone
      side, confirmed empirically, not assumed).
   4. For every pair whose names differ (i.e. every pair except a
      coincidentally-already-matching primary key, per §0.6.1):
      `ALTER INDEX "<clone_schema>"."<clone_auto_name>" RENAME TO
      "<template_index_name>"`. Per §0.6.2, this single statement also
      renames the owning `pg_constraint` row when the index backs a named
      `UNIQUE`/`EXCLUDE` constraint — no separate `ALTER TABLE ... RENAME
      CONSTRAINT` is needed or issued.
   Measured cost (§0.6.3): 1.0-9.8ms per rename on the real `users`-shaped
   probe, a pure catalog-metadata operation with no index rebuild — cheap
   relative to the 2.0-2.5x win this design's overall clone mechanism
   already banks, per §10.
4. **Foreign-key re-add.** Query `pg_constraint` (joined to `pg_class` for
   the owning table name) for every `contype = 'f'` constraint in the
   `tenant_template` namespace. For each, build the `ALTER TABLE
   "<clone_schema>"."<table>" ADD CONSTRAINT "<conname>" <def>` statement
   from `pg_get_constraintdef(oid)`, with the template schema's own
   qualifier (`tenant_template.` — UNQUOTED, see the CRITICAL note below)
   textually replaced by the clone schema's
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
6. **Trigger and trigger-function re-add — REWORK 3 ADDITION, mandatory, not
   optional.** ELIXIR-DEV's rework-3 blocker found this design's own
   dormancy claim false: `priv/repo/migrations/20260830020001_create_audit_entries_tenant_scoped.exs`
   and `priv/repo/migrations/20260830030001_create_repository_artifacts.exs`
   each install real, currently-live triggers enforcing audit-log and
   artifact IMMUTABILITY — a security property, not a cosmetic one. Five
   triggers exist today: `audit_entries_no_update`, `audit_entries_no_delete`
   (both `EXECUTE FUNCTION "<schema>".audit_entries_immutable()`),
   `repository_artifacts_no_update`, `repository_artifacts_no_delete` (both
   `EXECUTE FUNCTION "<schema>".repository_artifacts_immutable()`), and
   `artifact_versions_no_update` (`EXECUTE FUNCTION
   "<schema>".artifact_versions_immutable()`) — backed by three per-schema
   `plpgsql` functions, each created fresh inside its own migration's
   `execute/1` block with the schema name interpolated at migration-apply
   time (so every tenant schema, including the template, gets its own copy
   of each function — no shared `public`-schema function exists to
   reference across schemas, per Decision 0003-B). `LIKE ... INCLUDING ALL`
   does NOT copy triggers (a documented Postgres exception, already
   established in §0.2/§0.3 for the general case; independently
   re-confirmed for these five specific triggers this rework — see §0.4).
   This is the SAME qualifier-rewrite hazard class already solved for FKs
   (§0.1 finding 1) and sequences (§0.1 findings 3-4): both
   `pg_get_functiondef(oid)` and `pg_get_triggerdef(oid)` emit text
   literally qualified to the TEMPLATE schema (`CREATE OR REPLACE FUNCTION
   tenant_template.audit_entries_immutable() ...`,
   `... EXECUTE FUNCTION tenant_template.audit_entries_immutable()`),
   verified directly this rework (§0.4) — so, exactly as with FK re-add, the
   template's own qualifier must be textually replaced with the clone's
   before executing either statement, or the clone's trigger would silently
   invoke the TEMPLATE's function object rather than a clone-local one
   (which, unlike the DOMAIN/ENUM/collation coupling §0.3 found, would not
   even survive the template being dropped — the function-call target would
   simply fail to resolve). Concretely, in order, per table (walked over
   `expected_tenant_tables/0`, same stable order as step 3):
   1. Discover this table's own triggers and their backing functions:
      `SELECT DISTINCT t.tgname, t.tgfoid::regprocedure, p.oid AS func_oid
      FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid WHERE t.tgrelid =
      '"tenant_template"."<table>"'::regclass AND NOT t.tgisinternal` — the
      `NOT tgisinternal` guard excludes Postgres-internal triggers (e.g. the
      FK-enforcement `RI_ConstraintTrigger_*` triggers §0.2 finding 7
      already documented as a DIFFERENT, unrelated `pg_trigger` population;
      those are recreated for free as a side effect of step 4's FK re-add,
      not by this step, and must not be double-counted or double-created
      here).
   2. For each DISTINCT function OID found (a function backing more than one
      trigger, as none currently do but a future migration could, must be
      created exactly once): `pg_get_functiondef(func_oid)`, with the
      template schema's qualifier textually replaced by the clone's
      (`replace(def, 'tenant_template.', '<clone_schema>.')` — UNQUOTED on
      both sides, see the CRITICAL note below; the exact
      technique already proven for FK definitions, applied to a different
      catalog function), executed as-is (`CREATE OR REPLACE FUNCTION` is
      itself the statement `pg_get_functiondef` returns, so no separate
      `CREATE`/`ALTER` split is needed).
   3. For each trigger found: `pg_get_triggerdef(oid)`, same qualifier
      substitution, executed as-is. Functions MUST be created before the
      triggers that reference them (step 2 before step 3, per table, or
      more simply: all functions across all tables before any trigger,
      since a trigger's `EXECUTE FUNCTION` clause is resolved at
      `CREATE TRIGGER` time) — sequencing this correctly is the
      implementer's responsibility, not left ambiguous: do all of step 2 for
      every table first, then all of step 3 for every table.

   Verified end-to-end this rework (§0.4): a clone built this way has its
   own, genuinely independent copy of each function (confirmed via
   `pg_proc`/`pg_namespace` — a distinct OID, not the template's), its
   triggers correctly repointed at the clone-local function (confirmed via
   `pg_get_triggerdef` on the clone showing the clone's own schema
   throughout), the immutability guarantee actually firing against the
   clone (`UPDATE`/`DELETE` against the clone's own table raises the
   expected exception), and — checked specifically because the DOMAIN/ENUM
   case (§0.3) showed a superficially similar mechanism can still leave a
   live coupling — the clone remains fully functional after the TEMPLATE
   schema is dropped entirely, unlike the domain/enum/collation hazard
   class. This is expected and explained by a real Postgres distinction, not
   asserted by analogy: a function or trigger created via `CREATE OR REPLACE
   FUNCTION`/`CREATE TRIGGER` in a different schema is, by construction, a
   wholly new, independent catalog object with its own OID — unlike a
   `DOMAIN`/`TYPE`/`COLLATION` referenced by a column's type/collation
   slot, which (absent an explicit `CREATE DOMAIN`/`CREATE TYPE`/
   `CREATE COLLATION` step of its own, which this step IS performing via
   `pg_get_functiondef`) would otherwise still point at the source object.
7. **Seed-data copy.** `INSERT INTO "<clone_schema>".event_type_registry
   SELECT * FROM "tenant_template".event_type_registry` — the one table
   whose *data*, not just structure, must be present for the clone to
   behave like a `replay_migrations/2`-provisioned schema (per §0's
   `maybe_seed_platform_event_types/2` finding). No other table's data is
   copied — every other tenant-scoped table starts empty in both the
   migration-replay path and the clone path, so this is not a special case
   invented for cloning, it is preserving what replay already does.
8. **`schema_migrations` structure, then data — REWORK 3 CORRECTION.**
   ELIXIR-DEV's rework-3 handoff found this step's prose assumed the clone's
   own `schema_migrations` table already existed when the row-copy ran; it
   does not — `expected_tenant_tables/0` deliberately excludes
   `schema_migrations` (it is the migrator's own bookkeeping, not a
   tenant-scoped application table), so step 3's per-table `LIKE` loop never
   creates it. Corrected, now two sub-steps where the design previously
   stated only the second: (a) `CREATE TABLE "<clone_schema>".schema_migrations
   (LIKE "tenant_template".schema_migrations INCLUDING ALL)` — the same
   `LIKE` mechanism used for every other table, applied explicitly to this
   one rather than left implicit; (b) `INSERT INTO
   "<clone_schema>".schema_migrations SELECT * FROM
   "tenant_template".schema_migrations` — so a clone's `schema_migrations`
   table reports the same applied-version set a real replay would have
   recorded. This matters because `assert_schema_complete!/2`'s check #3
   (§ existing code, `versions_missing`) queries exactly this table; without
   both (a) and (b), a clone would either fail outright (undefined table) or
   look under-migrated to that existing oracle even though it is not.
9. Insert the caller's `Registration` row exactly as
   `provision_tenant_schema/1` would have (a plain `Repo.insert!/1` on
   `TenantProvisioning.Registration`, not a call to
   `provision_tenant_schema/1` itself — because that function issues its own
   `CREATE SCHEMA IF NOT EXISTS`, which is redundant with step 2 above and
   would mean two different code paths both believe they "provisioned" the
   schema; §7 states explicitly why this does not touch the production
   function). `migrations_applied_at` is set to the current time, matching
   what `replay_migrations/2`'s own `mark_migrations_applied/1` does.

Every identifier interpolated into raw SQL above (`clone_schema`, `table`,
`column`, `conname`, `seq`, and — added rework 3 — the trigger/function
names and full definition text step 6 reads back via `pg_get_functiondef`/
`pg_get_triggerdef`) is either a compile-time-known table/column name from
`expected_tenant_tables/0` (a fixed, hand-maintained list, not
caller/attacker input) or the output of
`TenantProvisioning.schema_name_for_tenant/1` (constrained to
`tenant_[0-9a-f]{32}` by construction, the same invariant
`provision_tenant_schema/1` itself already relies on) or a name/definition
read back from Postgres's own catalog (`pg_constraint`/
`pg_get_serial_sequence`/`pg_get_functiondef`/`pg_get_triggerdef`, which by
definition can only contain names and DDL text Postgres itself already
accepted as valid when the template was built by this codebase's own
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
collations sub-bullets were corrected/extended, per §0.3's findings. Held at
thirteen in rework 3, but two of the thirteen were themselves CORRECTED, not
just extended — dimension #2's column-order comparison and item 8's triggers
sub-bullet both stated false premises before this rework; see §0.4 for the
full finding and the fix each now specifies. Held at thirteen in rework 4
too — no new numbered dimension was added, but dimension #4 (indexes)
gained a second, mandatory NAME-identity sub-assertion (b) alongside its
existing structural sub-assertion (a), per §0.6's post-merge finding that
structural equivalence alone is necessary but not sufficient because Ecto
matches constraint violations by name, not by shape.)

1. **Table set** — `information_schema.tables` table names, set-equal, both
   directions. (Reuses `TenantFixture`'s existing table-enumeration query
   shape.)
2. **Columns** — per table: name, data type, `is_nullable`,
   `column_default` (schema-qualifier-normalized — a
   `nextval('"<schema>"."x_seq"')` default must match after substituting
   each side's own schema name), and column ORDER. Source:
   `information_schema.columns`. **CORRECTED rework 3** (ELIXIR-DEV finding,
   confirmed against the real schema): column order must be compared as each
   side's own RELATIVE rank (re-rank both sides' `ordinal_position` values to
   a dense `1..N` sequence before comparing), never the raw absolute
   `ordinal_position` integer. REQ-064's ten `tenant_id`-drop migrations
   leave a permanent gap in the TEMPLATE's own `ordinal_position` sequence
   (e.g. `instance_projections`, `users` both have a dropped column at a
   mid-table position) that `LIKE ... INCLUDING ALL` does not reproduce in
   the clone — Postgres renumbers a `LIKE`-built table's columns to
   consecutive positions regardless of the source table's own drop history,
   confirmed directly. Comparing raw `ordinal_position` therefore false-fails
   on every such table despite every live column's relative order and every
   other property being genuinely identical; comparing relative rank is the
   correct fix, not a weakening — it still catches a real reordering, just
   not the artifact of a dropped column's now-absent slot.
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
   `grep`-verified again this rework (rework 1): no migration under
   `priv/repo/migrations/` contains `CREATE CONSTRAINT TRIGGER` specifically
   — that half of this claim still holds, re-confirmed again in rework 3
   (§0.4). **THE OTHER HALF OF THIS CLAIM WAS FALSE, found in rework 3, not
   here:** plain `CREATE TRIGGER` (without the `CONSTRAINT` keyword) DOES
   appear in `priv/repo/migrations/` — five real triggers across two
   migrations (`20260830020001`, `20260830030001`), installing real
   audit-log and artifact-repository immutability enforcement. See §0.4 for
   the full finding and §3.2 item 8's own REWORK 3 CORRECTION for the fix.
   So: `contype = 't'` (constraint triggers specifically) remains a genuine
   zero-vs-zero rule-out, confirmed dormant as stated — but `pg_trigger`
   generally (plain triggers, dimension #8) is NOT dormant, and this design
   incorrectly generalized "no constraint trigger" into "no trigger of any
   kind," which is the exact false premise ELIXIR-DEV's blocker corrected.
   The lesson, stated plainly rather than left implicit: confirming one
   narrow case (constraint triggers via the `CONSTRAINT` keyword) is not the
   same as confirming the broader category (triggers in general) — this
   design conflated the two here, across three passes and two validator
   gates, before an implementer actually querying a real built template
   caught it.
4. **Indexes** — TWO separate assertions per table, both mandatory as of
   rework 4 (§0.6) — **structure** (unchanged from rework 3) and **name**
   (NEW, rework 4). Neither subsumes the other: structure alone is exactly
   the check that shipped and did not catch ISS-0427's post-merge defect
   (a structurally-perfect, differently-named clone passed it and then
   crashed the application, per §0.6); name alone, done naively, is exactly
   what the rework-3 gate correction already proved false-fails on
   `indexdef`'s embedded name substring. Both must hold together.

   **(a) Structure** — `pg_indexes.indexdef`, schema-qualifier-normalized,
   compared as a **multiset of normalized definitions per table**,
   explicitly NOT by `indexname` at this stage (§0.1 finding 2 — verified
   empirically that `LIKE INCLUDING ALL` renames indexes). This
   single-handedly covers unique indexes, partial/predicate indexes (the
   `WHERE` clause is part of `indexdef`), and expression indexes (the
   expression text is part of `indexdef`) — no separate step needed for
   those three, they fall out of comparing the full `indexdef` string.

   **REWORK-3 GATE CORRECTION (do not skip this — it is not implied by
   "not by indexname" above).** `indexdef` text itself EMBEDS the index's
   own name (`CREATE INDEX <name> ON <schema>.<table> ...`), and — as
   currently written, prior to this dimension's own step 4.5-style
   mechanism fix — `LIKE INCLUDING ALL` auto-renames indexes. So schema-
   qualifier normalization alone is NOT sufficient for the STRUCTURE
   comparison: the object's own name substring must also be stripped out
   of each side's `indexdef` before comparing structure, or every
   auto-renamed index false-fails on (a) even when its shape is identical.
   This is unlike `pg_get_constraintdef`, which never embeds the
   constraint's name — which is why the FK half of dimension #3 needs no
   equivalent step, and why the asymmetry is easy to miss. The same
   correction applies verbatim to dimension #11 (`pg_statistic_ext`), whose
   `pg_get_statisticsobjdef` output embeds the statistics object's own
   auto-renamed name for the same reason.

   **(b) Name — NEW, rework 4, the fix for the post-merge defect §0.6
   documents.** After pairing each candidate index to its reference
   counterpart via (a)'s structural, name-stripped comparison (the pairing
   is unambiguous — §0.6.3 verified a real 1:1 correspondence, every
   normalized definition value appears exactly once per side), assert
   `indexname` is IDENTICAL between the paired reference and candidate
   indexes — not merely structurally equivalent, the literal catalog name
   string must match. **Why this does not reintroduce the rework-3
   false-fail:** the rework-3 correction is about HOW TWO INDEXES ARE
   MATCHED TO EACH OTHER for the structural comparison (never by name,
   because a template name and an auto-generated clone name legitimately
   differ before §2.3 step 3.5's rename runs) — it says nothing about
   whether, once matched by structure, their names ought to agree. Ordering
   matters and is exactly what avoids the conflict: (a) pairs first
   (structure, name-blind), THEN (b) asserts on the now-paired objects
   (name, structure-blind) — never the reverse, and never a single
   combined "name AND structure in one comparison" that would have to
   choose a matching key up front and get it wrong. Same technique already
   established for dimension #13's structural-vs-display distinction
   (assert on the structural fact, use string rendering only for the
   diagnostic message) — reused here, not invented fresh. **This is the
   check that would have caught ISS-0427's post-merge defect at build time
   or clone-test time, before any application test ever hit the raw
   `Ecto.ConstraintError`**: a clone whose index-rename mechanism (§2.3
   step 3.5) is missing, wrong, or incomplete fails THIS assertion loudly,
   rather than passing dimension #4 as it did before this rework and
   surfacing instead as an unrelated-looking `Ecto.ConstraintError` seven
   application tests away. On today's real schema this check is
   IMMEDIATELY load-bearing once §2.3 step 3.5 ships (not a
   forward-looking, currently-dormant rule-out like dimensions #9-#11/#13)
   — it exercises real, current index names (`users_username_index`,
   `users_external_identity_partial_index`, and every other named unique
   index in the 39-table schema) on every single suite run.
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
   - *Triggers, including constraint triggers* — **REWORK 3 CORRECTION, a
     false premise, not a refinement.** Every earlier version of this
     sub-bullet (original draft, rework 1, rework 2, and both
     CODE-DESIGN-VALIDATOR gates that re-verified it) stated that the real
     tenant schema has zero triggers today and specified this check as a
     bare **count-equal-to-zero assertion** on that basis. THAT PREMISE IS
     FALSE, found by ELIXIR-DEV during implementation and independently
     re-confirmed here: `priv/repo/migrations/20260830020001_create_audit_entries_tenant_scoped.exs`
     and `priv/repo/migrations/20260830030001_create_repository_artifacts.exs`
     each install real, currently-shipping triggers — five total
     (`audit_entries_no_update`, `audit_entries_no_delete`,
     `repository_artifacts_no_update`, `repository_artifacts_no_delete`,
     `artifact_versions_no_update`), backed by three per-schema `plpgsql`
     functions, enforcing audit-log and artifact-repository IMMUTABILITY —
     a security property. A literal count-equal-to-zero check would have
     **silently PASSED a clone missing all five**, since `LIKE INCLUDING
     ALL` does not copy triggers (confirmed, §0.4) — exactly the
     silent-degradation hazard this entire design exists to prevent, now a
     live defect rather than a hypothetical one. **The corrected
     specification:** `pg_trigger` queried for both schemas (`NOT
     tgisinternal`, excluding Postgres's own FK-enforcement
     `RI_ConstraintTrigger_*` rows, which are a side effect of dimension #3's
     FK check, not this dimension's concern), compared as a **per-table
     multiset of `pg_get_triggerdef(oid)` text, schema-qualifier-normalized**
     — the same structural, name-independent-where-needed discipline already
     established for indexes (dimension #4) and constraints (dimension #3):
     `pg_get_triggerdef` embeds the trigger's timing/event/function-call
     clause directly, so this single comparison catches a trigger that is
     missing entirely, one whose definition differs, AND (critically, the
     exact hazard the qualifier-rewrite mechanism step exists to prevent) one
     that is present but still calls the TEMPLATE's own function rather than
     a clone-local one — the trigger def's `EXECUTE FUNCTION` clause is part
     of the compared text and carries the function's schema qualifier
     directly. A SECOND, separate comparison covers the backing functions
     themselves: `pg_proc` (joined to `pg_namespace`) for every function
     referenced by a `NOT tgisinternal` trigger, compared as a **per-schema
     multiset of `pg_get_functiondef(oid)` text, schema-qualifier-normalized**
     — this catches a function that is missing, differs in body, OR (again,
     the exact hazard) exists in the clone's own schema but is not the one
     the clone's triggers actually invoke (a drift the trigger-def comparison
     alone would not fully distinguish from "function correctly recreated,
     trigger correctly repointed"). **Currently exercises real, non-default
     data** — unlike dimensions #9-#11/#13, which are today's zero-vs-zero
     rule-outs, this dimension's operands are 5 real triggers and 3 real
     functions on the reference side right now, so this check is
     immediately load-bearing, not merely forward-looking. Constraint
     triggers specifically (`contype='t'` in dimension #3's own enumeration)
     remain confirmed absent today (re-grepped this rework, no hits) and
     would be covered by this same `pg_trigger`/`pg_get_triggerdef`
     machinery if one were ever added — no separate handling needed, since a
     constraint trigger is still a `pg_trigger` row.
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

**CORRECTED rework 3 — the transaction-scoped form does not work, confirmed
by running it.** This section originally specified wrapping
`ensure_template!/0`'s build sequence in the same `pg_advisory_xact_lock`
pattern `provision_tenant_schema/1` uses, inside one `Repo.transaction`.
ELIXIR-DEV implemented that literally first and it failed reproducibly:
`Ecto.Migrator.run/4` (invoked by the template build, whichever OQ-1 option
is taken — ELIXIR-DEV adopted option (b), building the template via the
real, unmodified `replay_migrations/2`) checks out its OWN Postgres
connection from the pool rather than participating in the ambient
`Repo.transaction`'s connection, so `CREATE SCHEMA "tenant_template"` issued
inside that outer transaction is invisible to the migrator's own connection
— `Postgrex.Error` code `3F000` ("schema \"tenant_template\" does not
exist"), reproduced and quoted in full during implementation. This is a
correction to this design's own prior text, not an implementation detail
left to ELIXIR-DEV's discretion: **the corrected mechanism uses a
SESSION-level `pg_advisory_lock(hashtext($1))` /
`pg_advisory_unlock(hashtext($1))` pair** (keyed on the literal string
`"tenant_template"`, same key as originally specified), acquired before the
build sequence and released in an `after`/ensure block so a raised exception
still releases it, with **no surrounding `Repo.transaction`** — matching
`SandboxPool.provision_sandbox/2`'s own already-established pattern of
plain sequential `Repo.query!`/`Ecto.Migrator.run` calls with no wrapping
transaction. This is scoped to `ensure_template!/0` only:
`clone_tenant_schema!/1` never calls `replay_migrations/2` or
`Ecto.Migrator.run/4` (it only issues raw `Repo.query!` DDL, all of which
does share one ambient connection), so it is unaffected and still uses one
`Repo.transaction` exactly as §2.3 specifies — this correction does not
touch the clone path, only the template-build path.

The underlying purpose is unchanged from the original text: this guard
matches an established in-codebase idiom (session-level advisory locks are
themselves a standard idiom, and `provision_tenant_schema/1`'s own use of
the transaction-scoped variant remains the right choice THERE, since that
function's entire body — including its DDL — genuinely does run on one
connection inside one transaction; the template build's use of
`Ecto.Migrator.run/4` internally is what makes it different, not a
weakening of the underlying safety goal), and makes this design safe even
if ISS-0423 later changes `Sandbox.mode` behavior in a way that makes
concurrent `ensure_template!/0` calls within one partition possible.
Without it, two concurrent first-callers could both see `:not_built` and
both attempt `CREATE SCHEMA "tenant_template"` — the second would hit a
real Postgres error (no `IF NOT EXISTS` deliberately, per §2.3 step 1's own
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
- **INV-7 (index/constraint names are load-bearing, not cosmetic — added
  rework 4).** Every non-primary-key index and named `UNIQUE`/`EXCLUDE`
  constraint in a cloned schema must carry the SAME catalog name as its
  counterpart in the template, not merely the same structure — because
  `Ecto.Changeset.unique_constraint/3` and `foreign_key_constraint/3`
  resolve a Postgres constraint violation back to a changeset field by
  matching that name (§0.6). §2.3 step 3.5 is what makes this true; §3.2
  dimension #4(b) is what asserts it stays true on every run. A future
  change to either the clone mechanism or Ecto's own error-mapping
  convention that breaks this invariant must fail dimension #4(b) loudly,
  not surface as an unrelated-looking `Ecto.ConstraintError` in an
  application test, which is exactly how this defect was originally found
  (see §0.6's opening paragraph).
- **INV-8 (the literal name `"tenant_template"` never exists in a
  half-built state — added rework 4).** Per §0.7's atomic
  build-then-rename mechanism, no Postgres session can ever observe a
  schema named `"tenant_template"` that is not either (a) fully built and
  self-check-passed, or (b) entirely absent. A crash, exception, or
  interruption at any point in §2.3's steps 0-4 leaves behind only a
  randomly-named staging schema, never a broken `"tenant_template"` —
  `template_built_in_db?/0`'s existing "does this schema exist" check
  therefore never has to distinguish "complete" from "in progress" from
  "failed partway," because the schema's very existence under that name IS
  the completeness proof, by construction of the rename being the last
  statement in the sequence. This is the invariant that closes
  ISSUE-FIXER's MAJOR finding (step-05 handoff) — restated here as a
  standing property, not merely a one-time fix, per this project's
  convention (see INV-1, INV-4, INV-5 above) of naming what a fix
  guarantees so REVIEWER can check it mechanically rather than re-deriving
  it from the mechanism text.

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
- **OQ-2 — RESOLVED, rework 3.** This question originally asked what the
  clone mechanism should do about triggers, on the (false — see §0.4) belief
  that none existed today and the question was purely hypothetical. It no
  longer is: §2.3 step 6 now specifies trigger and trigger-function
  recreation in full (qualifier-rewrite via `pg_get_functiondef`/
  `pg_get_triggerdef`, the same technique §0.1 finding 1 already proved for
  FKs), and §3.2 item 8 specifies the corresponding non-vacuous structural
  check. Left here, marked resolved rather than deleted, so a future reader
  auditing this document's open-question history can see that this one was
  not a design choice deferred by preference — it was a false premise that
  made the question look deferrable until real implementation surfaced the
  five triggers it was actually about.
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
- **OQ-7 (added rework 4).** §0.7's atomic build-then-rename fix leaves a
  randomly-named, orphaned staging schema (`tenant_template_build_<hex>`)
  behind whenever a build attempt fails after `CREATE SCHEMA` but before
  the rename — by design, this is harmless, inert debris (never named
  `"tenant_template"`, never registered against a live `tenant_schemas`
  row that any reaper or application code path could mistake for a real
  tenant or the live template, per §0.7's own reasoning). This design does
  NOT add an active sweep for these orphaned staging schemas — no code
  path today pattern-matches `pg_namespace` for `tenant_template_build_*`
  the way `TenantSchemaReaper.sweep_orphans/2` pattern-matches
  `tenant_<32-hex>` for real tenant debris. Left undesigned deliberately: a
  test-run's database is itself ephemeral per §5's own reasoning (each
  partition's database starts fresh via the existing `mix ecto.reset`-
  equivalent flow between full test-suite invocations), so accumulated
  staging-schema debris does not outlive one CI/dev run's database
  lifetime the way a genuinely persistent artifact would — but a
  long-lived dev database that is NOT reset between many interrupted local
  `mix test` runs (exactly the shape of debris ISSUE-FIXER found and
  ORCH's own earlier probing produced, per the step-05 handoff) could
  accumulate several. Whether `TenantSchemaReaper` should gain a second,
  parallel sweep pattern for `tenant_template_build_*` schemas (symmetric
  in shape to its existing tenant-schema sweep, but keyed on schema AGE via
  `pg_namespace`/creation-time inference rather than a `tenant_schemas` row,
  since staging schemas are deliberately NEVER registered in that table)
  is not decided here — filed as an open question rather than silently
  assumed unnecessary, per this role's own forbidden-list.

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
| Test-only; production path untouched, or flagged for SECURITY-REVIEWER if not | §7 — zero `lib/letflow/` diff, explicitly stated. OQ-1 resolved (implementation, per ELIXIR-DEV's step-3 handoff) as option (b) — the template is built via a throwaway `Tenant`/`Registration` row plus the real, unmodified `replay_migrations/2`, both throwaway rows deleted afterward — keeping §7's "zero `lib/letflow/` diff" claim literally true, not merely aspirational. |
| Complementary to, not absorbing, ISS-0423 | §1 non-goals, §4.2's explicit non-fix of `Sandbox.mode`, §6 |
| Complementary to, not competing with, SandboxPool | §6 |
| Sequence/DEFAULT cross-schema coupling (the second hazard ISSUE-FIXER found, not in the original issue text) | §2.3 step 5, verified §0.1 findings 3-4, checked by §3.2 item 5 |
| Trigger/trigger-function cross-schema coupling, enforcing audit-log and artifact-repository immutability (a THIRD hazard, found in rework 3 by ELIXIR-DEV during implementation, not by any design pass) | §2.3 step 6, verified §0.4, checked non-vacuously by §3.2 item 8 (corrected) |
| Index/constraint NAME parity — a FOURTH hazard, found post-merge by ORCH's honest re-measurement + ISSUE-FIXER's rollback diagnosis, causing `Ecto.ConstraintError` instead of clean 409s on 7/8 remaining suite failures | §0.6 (finding + mechanism decision), §2.3 step 3.5 (fix), §3.2 dimension #4(b) (assertion), INV-7 |
| `build_template!/0` crash-safety — schema commits unconditionally before migrations run, permanently wedging a partition database if any later step fails | §0.7 (finding + mechanism decision), §2.3 steps 0/5 (atomic build-then-rename), INV-8 |
| `insert_throwaway_tenant_and_registration!/1` stale-row unique-violation (MINOR, ISSUE-FIXER step-05) | §0.7's MINOR fix — subsumed by the randomized staging-schema-name choice, no separate upsert change needed |
