# ISS-0060: race fix for `DropLegacyPublicIdentityTables migration guard` test

## 1. Scope

Only one test needs isolation: `test/letflow/identity_migration_test.exs`'s
`"once the copy is completed for every registered tenant, the guard PROCEEDS
and drops all three public tables"` (currently ~line 367). The other three
tests in the same describe block (`skip-on-uncopied-row`, the ISS-0050
missing-table regression, and the idempotent-rerun test) all assert SKIP or a
SKIP-adjacent outcome — an extra, concurrently-incomplete tenant elsewhere in
`public.tenant_schemas` can only ever add *another* reason to skip, never
flip a correct SKIP into a false PROCEED. They are unaffected by this race
and are out of scope for this fix.

The migration itself (`priv/repo/migrations/20260819000004_...exs`) and
`lib/letflow/tenant_provisioning.ex` are **not modified** — this is a
test-only fix, matching ISSUE-FIXER's diagnosis that the global per-tenant
scan is correct production behavior.

## 2. Why the alternatives considered don't work (decision, not left open)

- **`SELECT ... FOR UPDATE` / explicit row lock on other tenants' rows** —
  rejected. Postgres plain `SELECT` (which is exactly what the guard's `FOR
  v_tenant IN SELECT tenant_id, schema_name FROM public.tenant_schemas LOOP`
  is) never blocks on row locks under MVCC. Locking other tenants' rows
  would not change what the guard's plain read sees. This is a non-solution
  for a visibility race, not just a weaker one.
- **`pg_temp` / session-local view shadowing `tenant_schemas`** — rejected.
  The migration's query is schema-qualified (`public.tenant_schemas`, not
  bare `tenant_schemas`). `search_path`/`pg_temp` shadowing only intercepts
  *unqualified* identifiers, and editing the shipped migration to make it
  unqualified is out of scope (would change production code for a test's
  benefit and weaken the migration's own explicitness). Rejected without
  touching the migration file.
- **Temporarily `ALTER TABLE public.tenant_schemas RENAME TO ...` and swap in
  a filtered copy under the original name** — considered and rejected as
  strictly worse than the chosen approach: it creates a window where
  `public.tenant_schemas` does not exist *at all* under its expected name.
  A crash inside that window leaves the table permanently misnamed for every
  other test/process in the suite (not just this one), a worse and harder to
  diagnose failure mode than some rows being transiently absent.
- **Global/named advisory lock, taken by this test AND cooperatively by
  `TenantProvisioning.provision_tenant_schema/1` and its deprovision path** —
  the only alternative that would actually work, but rejected as
  disproportionate for a MINOR test-hygiene issue: it requires modifying
  shared production code (`lib/letflow/tenant_provisioning.ex`) purely to
  satisfy one test's assertion window, and it would serialize *every*
  concurrently-running test's tenant provisioning/deprovisioning against
  this one test's lock hold, not just against each other — a strictly larger
  blast radius and suite-runtime cost than the chosen approach, which touches
  no production module and narrows its exposure to one test's own
  sub-millisecond window.

**Decision:** snapshot-and-restore of *other* tenants' `tenant_schemas` rows,
scoped as tightly as SQL allows (single atomic data-modifying CTEs, not
separate round trips), plus a self-healing check on every subsequent run of
this test file's `setup` block. Justification for crash-safety is in §5.

## 3. New DB object: crash-durable backup table

A dedicated backup table, created once (idempotent `CREATE TABLE IF NOT
EXISTS`) by the new helper described in §4, never dropped by `on_exit/1`
(it must survive a crash to do its job):

Confirmed column set (read directly from
`priv/repo/migrations/20260816090045_create_tenant_schemas.exs` lines 28-37,
not inferred from the Ecto schema): `id, tenant_id, schema_name,
migrations_applied_at`, plus `timestamps(inserted_at: :provisioned_at,
updated_at: false)` — i.e. exactly 5 columns, no `updated_at`.

```
public.iss060_tenant_schemas_guard_backup
  id                     uuid PRIMARY KEY   -- copied verbatim from tenant_schemas.id
  tenant_id              uuid NOT NULL
  schema_name            text NOT NULL
  migrations_applied_at  timestamp
  provisioned_at         timestamp NOT NULL -- timestamps(inserted_at: :provisioned_at,
                                             -- updated_at: false); no updated_at column
                                             -- exists on tenant_schemas, so none is
                                             -- added here.
```

Column set mirrors every column `SELECT * FROM public.tenant_schemas` would
return, so the restore INSERT can be a bare `SELECT *` with no column-name
drift risk if the schema changes later. No `backed_up_at`/run-id bookkeeping
column — not needed: the table's mere non-emptiness at the start of any
later test run *is* the crash signal (see §5's self-heal), and keeping the
schema an exact structural mirror of `tenant_schemas` is what makes the
restore INSERT trivial and correct.

## 4. New test helper: `defp with_only_this_tenant_visible!/2`

Added to `test/letflow/identity_migration_test.exs`'s private helpers
alongside `provisioned_tenant!/0` etc.

```
defp with_only_this_tenant_visible!(tenant_id, fun)
  input:  tenant_id :: Ecto.UUID.t()  -- the tenant this test just finished
                                        copying; the only row that must
                                        remain visible in public.tenant_schemas
                                        for the duration of `fun`
          fun       :: (-> result)     -- the guarded work: the
                                        Ecto.Migrator.run/4 call plus this
                                        test's three-table drop assertions
  output: result                       -- fun's own return value, passed
                                        through unchanged
  raises: re-raises whatever `fun` raises, after the restore step below has
          already run (try/after semantics — restore is not skipped on
          assertion failure)
```

Sequence of operations inside `with_only_this_tenant_visible!/2`:

1. `ensure_backup_table!/0` (new private helper) — `CREATE TABLE IF NOT
   EXISTS public.iss060_tenant_schemas_guard_backup (...)` per §3. Cheap,
   idempotent, safe to call every test.
2. **Move-out, single atomic statement** (one `Repo.query!/2` call, one
   round trip, no branching between snapshot and delete so there is no
   Elixir-side window at all):
   ```
   WITH moved AS (
     DELETE FROM public.tenant_schemas
     WHERE tenant_id <> $1
     RETURNING *
   )
   INSERT INTO public.iss060_tenant_schemas_guard_backup
   SELECT * FROM moved
   ```
   A data-modifying CTE is one Postgres statement; Postgres gives every
   statement an implicit transaction even without an explicit `BEGIN`, so the
   delete and the insert-into-backup commit together or not at all — no
   partial-move state is reachable.
3. `result = fun.()` — runs the guarded `Ecto.Migrator.run/4` call and this
   test's own assertions. `public.tenant_schemas` now contains at most one
   row (this test's `tenant_id`), so the guard's `FOR v_tenant IN ...` loop
   can only see a tenant this test itself fully copied — no other
   concurrently-provisioning tenant can force a false SKIP, and (per §2's
   first bullet already ruling out lock-based visibility control) this is
   the only mechanism that actually changes what the guard's plain `SELECT`
   observes.
4. **Move-back, single atomic statement**, in an Elixir `after` block so it
   runs whether step 3 succeeded or raised (ExUnit assertion failures raise):
   ```
   WITH restored AS (
     DELETE FROM public.iss060_tenant_schemas_guard_backup
     RETURNING *
   )
   INSERT INTO public.tenant_schemas
   SELECT * FROM restored
   ON CONFLICT (id) DO NOTHING
   ```
   `ON CONFLICT (id) DO NOTHING` makes this restore idempotent — safe to run
   twice (e.g. once here, once again defensively) without erroring on a
   duplicate key.
5. Return/re-raise `result` per the try/after contract above.

Call site inside the `"...guard PROCEEDS..."` test: wrap the existing
`ensure_drop_migration_loaded!(); version = ...; Ecto.Migrator.run/4;
for table <- [...] do ... end` block in
`with_only_this_tenant_visible!(tenant.id, fn -> ... end)` — no change to
the assertions themselves, only to what surrounds them.

## 5. Crash-safety argument (the load-bearing part of this design)

- **No partial-move state is reachable.** Both the move-out and move-back
  are single atomic SQL statements (§4 steps 2 and 4), not two Elixir-side
  round trips with logic in between. A statement-level crash (BEAM killed
  mid-`Repo.query!/2`) means that statement's transaction never committed —
  Postgres itself guarantees the DELETE and INSERT-into-backup rolled back
  together, so `public.tenant_schemas` is unchanged in that case. The only
  crash window that can leave `tenant_schemas` short of other tenants' rows
  is *between* step 2 committing and step 4 committing — and during that
  window the missing rows are, by construction, sitting intact in
  `public.iss060_tenant_schemas_guard_backup`. Nothing is ever deleted
  without first being durably copied in the same statement.
- **Self-heal on next opportunity, mirroring ISS-0048's reaper pattern.**
  The existing module-level `setup do ... end` block (currently:
  `Sandbox.mode(:auto)` + `recreate_legacy_public_tables!()`) gains one more
  step: `restore_orphaned_guard_backup_rows!/0` — if
  `public.iss060_tenant_schemas_guard_backup` is non-empty when any test in
  this file starts, that non-emptiness *is* the signal that a prior run
  crashed between steps 2 and 4, and this helper runs exactly step 4's CTE
  before the test proceeds. This bounds the orphan window to "until this
  test file next runs" (next CI run, next `mix test` invocation) rather than
  the unbounded, growing-until-noticed orphan class ISS-0048 was written to
  avoid — same shape of fix (detect-and-heal-on-next-run), applied to a
  much smaller/local resource (a handful of rows in one table) rather than a
  live schema, so no new supervised process or periodic reaper is needed.
- **Residual, explicitly accepted risk:** a *different* concurrently-running
  test whose own tenant row is moved out during this test's step-2-to-step-4
  window would transiently not see its own `tenant_schemas` row (e.g. a
  `Repo.get_by(Registration, tenant_id: ...)` call landing in that exact
  window). This window is now bounded to one guarded `Ecto.Migrator.run/4`
  call plus three follow-up `to_regclass` queries (milliseconds), versus the
  status quo's unbounded exposure across the entire suite run — a large
  reduction, not a full elimination. See Open Questions below; closing this
  residual risk fully requires the cooperative-lock approach §2 rejected as
  disproportionate for this issue's severity.

## 6. Open questions (not silently resolved)

1. **Residual cross-test visibility gap (§5's last bullet).** Left
   unresolved by this design: acceptable for a MINOR issue given the window
   is now sub-second, but flagged in case a future TEST-RUNNER run surfaces
   *this* as a new, much rarer flake — the next fix would be the cooperative
   global-lock approach §2 rejected here, not a fresh root-cause
   investigation.
2. **Unique index on `tenant_schemas.tenant_id`/`schema_name`** (per
   `Registration.changeset/2`'s `unique_constraint/2` calls): the move-back
   INSERT's `ON CONFLICT (id) DO NOTHING` targets the primary key only. If a
   partially-healed state ever left one backup row and a live
   re-provisioned row for the same `tenant_id` (not expected under this
   design's operation, since `provision_tenant_schema/1` is idempotent and
   only this test's own `tenant_id` is ever left live during the window),
   the restore INSERT would raise a unique-violation instead of silently
   corrupting data — treated here as an acceptable loud-failure edge case
   rather than something this design adds extra handling for.
