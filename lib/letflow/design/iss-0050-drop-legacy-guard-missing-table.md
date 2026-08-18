# Design: ISS-0050 — DropLegacyPublicIdentityTables guard must tolerate a missing groups/users/tenant_role table

**Issue:** ISS-0050 (stage S3), diagnosed by ISSUE-FIXER in
`handoffs/WF03-ISS0050-20260818/step-01-issue-fixer.json`.
**Owner (implementer):** ELIXIR-DEV
**File to modify:** `priv/repo/migrations/20260819000004_drop_legacy_public_identity_tables.exs`
(the guard's `DO $$ ... END $$;` block only — no other file).

**Change class: this is a migration-file (SQL/plpgsql-in-Elixir) change, not a
schema/module design.** No Ecto schema, no `@spec`, no `lib/letflow/*.ex` module is
touched by this fix. `ELIXIR-DEV` should not introduce any Ecto schema changes to
implement this — the entire fix lives inside the existing `execute("""DO $$ ... $$;""")`
string in the migration file named above.

**Explicitly not in scope of this design:** ISS-0048 (orphaned schema accumulation) is
not fixed here and stays open as its own issue. This design only makes the guard
tolerate a tenant_schemas row whose physical schema is missing one of the three legacy
tables — regardless of whether that row exists because of a leaked test fixture
(ISS-0048's symptom) or a legitimate tenant genuinely mid-provisioning in a real
deployment (ISSUE-FIXER's diagnosis, §"WHAT A FIX NEEDS TO CHANGE" item 1).

---

## 0. Root cause recap (from step-01-issue-fixer.json, read in full)

Inside the `FOR v_tenant IN SELECT tenant_id, schema_name FROM public.tenant_schemas
LOOP`, each iteration runs three `EXECUTE format('... FROM %I.groups ...', ...)` (and
`%I.users`, `%I.tenant_role`) queries. Postgres must resolve `%I.<table>` to a real
relation at parse time for the dynamically-built statement, **regardless of whether the
row-matching WHERE clause would match zero rows**. So any `tenant_schemas` row whose
physical schema lacks one of these three tables (e.g. `provision_tenant_schema/1` ran
but `replay_migrations/2` has not yet, or hasn't finished) makes the guard raise
`42P01 undefined_table` uncaught, instead of being treated as "copy not complete for
this tenant."

## 1. Mechanism: `to_regclass(...) IS NULL` existence check before each dynamic EXECUTE

Per acceptance criterion 2, the exact mechanism is `to_regclass(format('%I.<table>',
v_tenant.schema_name)) IS NULL` — `to_regclass` is the same builtin the guard's own
top-of-block idempotency check already uses (`to_regclass('public.users') IS NULL`,
line 78 of the current file), so this is a like-for-like extension of a pattern already
established in this exact block, not a new mechanism. `to_regclass` resolves a
schema-qualified relation name to its OID (or `NULL` if it doesn't exist) **without**
requiring the relation to exist and without erroring — it is safe to call on a
non-existent relation, unlike referencing `%I.<table>` inside a query body that
Postgres must plan.

Each of the guard's three per-table checks (`groups`, `users`, `tenant_role`) gets a
new guard clause of this shape, placed immediately before that table's existing
`EXECUTE format('SELECT count(*) FROM ... %I.<table> ...', ...)`:

```
IF to_regclass(format('%I.<table>', v_tenant.schema_name)) IS NULL THEN
  v_all_copied := FALSE;
  RAISE NOTICE 'DropLegacyPublicIdentityTables: tenant % schema % is missing table % -- treating copy as incomplete for this tenant.',
    v_tenant.tenant_id, v_tenant.schema_name, '<table>';
  CONTINUE;  -- or: structure as ELSE around the existing EXECUTE, see §2
END IF;

-- existing EXECUTE format('SELECT count(*) FROM public.<table> ... %I.<table> ...', ...) INTO v_missing_count;
-- existing IF v_missing_count > 0 THEN ... END IF;
```

`<table>` is `groups`, `users`, or `tenant_role` respectively — three separate
occurrences of this pattern, one per existing per-table block, using the exact same
`v_tenant.schema_name` value already in scope from the `FOR` loop (no new variable
needed to hold the identifier check's own target — `format('%I.<table>',
v_tenant.schema_name)` is evaluated fresh in each guard clause, mirroring how the
existing `EXECUTE format(...)` calls already build the identifier inline).

## 2. Precise structure per table block (pseudocode, not verbatim-runnable SQL per role scope)

For **each** of the three existing per-table blocks inside the `FOR v_tenant` loop
(groups, users, tenant_role), wrap the existing `EXECUTE format(...) INTO
v_missing_count` + its `IF v_missing_count > 0 THEN ... END IF` in an `IF/ELSE` keyed on
the new existence check, rather than using `CONTINUE` (plpgsql's `CONTINUE` inside a
plain `FOR ... LOOP` is legal but skips the *remaining* per-table checks for that same
tenant iteration too, which would under-report — a tenant missing only `groups` should
still have its `users`/`tenant_role` checked and reported independently if those also
have issues). Structure as:

```
-- groups block
IF to_regclass(format('%I.groups', v_tenant.schema_name)) IS NULL THEN
  v_all_copied := FALSE;
  RAISE NOTICE 'DropLegacyPublicIdentityTables: tenant % schema %.groups does not exist -- treating copy as incomplete for this tenant.',
    v_tenant.tenant_id, v_tenant.schema_name;
ELSE
  EXECUTE format(
    'SELECT count(*) FROM public.groups g WHERE g.tenant_id = %L
       AND NOT EXISTS (SELECT 1 FROM %I.groups tg WHERE tg.id = g.id)',
    v_tenant.tenant_id, v_tenant.schema_name
  ) INTO v_missing_count;

  IF v_missing_count > 0 THEN
    v_all_copied := FALSE;
    RAISE NOTICE 'DropLegacyPublicIdentityTables: tenant % missing % groups row(s) in schema %.',
      v_tenant.tenant_id, v_missing_count, v_tenant.schema_name;
  END IF;
END IF;

-- users block: identical shape, substituting %I.users / public.users / u / tu
IF to_regclass(format('%I.users', v_tenant.schema_name)) IS NULL THEN
  v_all_copied := FALSE;
  RAISE NOTICE 'DropLegacyPublicIdentityTables: tenant % schema %.users does not exist -- treating copy as incomplete for this tenant.',
    v_tenant.tenant_id, v_tenant.schema_name;
ELSE
  EXECUTE format(
    'SELECT count(*) FROM public.users u WHERE u.tenant_id = %L
       AND NOT EXISTS (SELECT 1 FROM %I.users tu WHERE tu.id = u.id)',
    v_tenant.tenant_id, v_tenant.schema_name
  ) INTO v_missing_count;

  IF v_missing_count > 0 THEN
    v_all_copied := FALSE;
    RAISE NOTICE 'DropLegacyPublicIdentityTables: tenant % missing % users row(s) in schema %.',
      v_tenant.tenant_id, v_missing_count, v_tenant.schema_name;
  END IF;
END IF;

-- tenant_role block: identical shape, substituting %I.tenant_role / the
-- public.tenant_role JOIN public.groups query already present
IF to_regclass(format('%I.tenant_role', v_tenant.schema_name)) IS NULL THEN
  v_all_copied := FALSE;
  RAISE NOTICE 'DropLegacyPublicIdentityTables: tenant % schema %.tenant_role does not exist -- treating copy as incomplete for this tenant.',
    v_tenant.tenant_id, v_tenant.schema_name;
ELSE
  EXECUTE format(
    'SELECT count(*) FROM public.tenant_role tr
       JOIN public.groups g ON tr.group_id = g.id
       WHERE g.tenant_id = %L
       AND NOT EXISTS (SELECT 1 FROM %I.tenant_role ttr WHERE ttr.id = tr.id)',
    v_tenant.tenant_id, v_tenant.schema_name
  ) INTO v_missing_count;

  IF v_missing_count > 0 THEN
    v_all_copied := FALSE;
    RAISE NOTICE 'DropLegacyPublicIdentityTables: tenant % missing % tenant_role row(s) in schema %.',
      v_tenant.tenant_id, v_missing_count, v_tenant.schema_name;
  END IF;
END IF;
```

All three blocks stay inside the same `FOR v_tenant IN SELECT tenant_id, schema_name
FROM public.tenant_schemas LOOP` — no change to the loop's own source query, no new
loop, no new DECLARE'd variable beyond what already exists (`v_all_copied`,
`v_tenant`, `v_missing_count` are all reused as-is; the `to_regclass(...) IS NULL`
checks are plain boolean expressions evaluated inline in the `IF`, needing no
intermediate variable).

## 3. Why this preserves the already-covered case (criterion 3)

When `to_regclass(...)` finds the table (the common case — a fully-provisioned,
fully-migrated tenant), the `ELSE` branch runs and is **byte-for-byte identical** to
the current unconditional `EXECUTE format(...) INTO v_missing_count` + `IF
v_missing_count > 0 THEN ... END IF` block already in the file today (see the
migration file's current lines 88–98, 101–111, 115–127, quoted verbatim inside the
`ELSE` branches above). Nothing about the row-missing-by-id detection, its
`v_all_copied := FALSE` side effect, or its `RAISE NOTICE` wording changes for that
case. The new `IF to_regclass(...) IS NULL` branch is purely additive — it only fires
when the *table itself* doesn't exist, a state the existing code had no branch for at
all (it would have crashed before reaching any branch).

## 4. Why this preserves idempotency (criterion 4)

The top-of-block idempotency short-circuit (current lines 78–83: `IF
to_regclass('public.users') IS NULL AND to_regclass('public.groups') IS NULL AND
to_regclass('public.tenant_role') IS NULL THEN RAISE NOTICE ... RETURN; END IF;`) is
**unchanged** by this design — it still runs first, still checks the three *public*
(unqualified, i.e. `public.*`) tables' existence, not any tenant schema's copies, and
still returns immediately on a successful-prior-drop re-run before the `FOR v_tenant`
loop (and therefore before any of the new per-tenant `to_regclass(format('%I.<table>',
...))` checks) is ever reached. The fix described in §1–§2 only touches code *inside*
that loop, strictly after this early-return has already been evaluated.

## 5. Skip-on-doubt philosophy preserved (criterion 1)

A missing table is folded into the exact same `v_all_copied := FALSE` / "skip the DROP
for all three tables" path the guard already uses for a missing-row case (current lines
130–133: `IF NOT v_all_copied THEN RAISE NOTICE ... RETURN; END IF;`), unchanged. No new
skip path, no new terminal state — a missing table is simply one more reason
`v_all_copied` can end up `FALSE`, exactly matching acceptance criterion 1's "treated as
'copy not complete for this tenant' ... skip the DROP, RAISE NOTICE identifying the
tenant/missing table" requirement. The `RAISE NOTICE` text in each new `IF` branch names
both `v_tenant.tenant_id`, `v_tenant.schema_name`, and the specific missing table
(literal `'groups'`/`'users'`/`'tenant_role'` per block, not a variable — there is no
need to parameterize the table name across the three blocks since each block is already
table-specific in the existing code), satisfying "identifying the tenant/missing table"
precisely.

## 6. Comment-block update (part of this same file, not a separate artifact)

The migration file's module-level comment (current lines 20–46, "GUARD MECHANISM")
documents the per-row existence-check design decision but does not yet mention that the
check must also tolerate a missing table. `ELIXIR-DEV` should add a short paragraph
there (not designed verbatim here, since it is prose, not logic) noting: this guard
treats a `tenant_schemas` row whose schema is missing `groups`/`users`/`tenant_role` as
"copy not verifiable, skip the drop" rather than crashing, citing ISS-0050, so a future
reader of this file understands why the `to_regclass(format('%I.<table>', ...)) IS
NULL` checks exist alongside the per-row `NOT EXISTS` checks.

## 7. Operational step outside this design's own file (flagged, not designed here)

ISSUE-FIXER's diagnosis (`step-01-issue-fixer.json` result.summary, item 3) identifies
a currently-leaked `tenant_schemas` row (`tenant_id
77f0469f-83ef-4adc-8ee1-4e5a8848e65c`, schema `tenant_77f0469f83ef4adc8ee14e5a8848e65c`)
in the shared `letflow_test` database on this host that must be purged (`DROP SCHEMA` +
`DELETE FROM tenant_schemas`) for `identity_migration_test.exs`'s guard tests to pass
cleanly against this host's current DB state, independent of whether this code fix is
correct — this fix makes the guard **tolerate** that row (no more crash) rather than
requiring its removal, but ELIXIR-DEV/TEST-RUNNER should still verify against a
database state consistent with the test's own expectations (the guard skipping the DROP
because that row is present is a *different*, and correct, outcome than the row not
existing at all — TEST-RUNNER should confirm which of the two the test suite's existing
assertions expect, not designed further here since it is a test/DB-state concern, not a
guard-logic concern).

## 8. Open questions

None — the mechanism, its exact placement, and its interaction with both existing
guard invariants (idempotency short-circuit, skip-on-doubt philosophy) are fully
specified above. Table/column/index shapes are unaffected (no schema change of any
kind is part of this fix).
