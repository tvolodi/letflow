# ISS-0229 fix design: guard-backup table is a referential blind spot, and its self-heal is partial

**Run:** WF03-ISS0229-20260822 (WF-03 Step 2)
**Author role:** CODE-DESIGNER
**Scope of change:** `test/letflow/identity_migration_test.exs` only (its private helpers and
one new `describe` block for the regression test). No production module, no migration, no
`test/support/tenant_schema_reaper.ex`, none of the ~40 per-test teardowns.

---

## 0. Decisions at a glance

| # | Question | Decision |
|---|---|---|
| 1 | Give `iss060_tenant_schemas_guard_backup` an FK on `tenant_id` → `tenants(id)`? | **Yes.** |
| 2 | `ON DELETE` action? | **None — plain `NO ACTION`**, byte-for-byte the same referential semantics `tenant_schemas_tenant_id_fkey` already has. |
| 3 | How do already-existing databases converge (given `CREATE TABLE IF NOT EXISTS`)? | Inline `CONSTRAINT ... FOREIGN KEY` in the `CREATE TABLE IF NOT EXISTS` (covers fresh DBs) **plus** a new `ensure_backup_table_fk!/0` running a `pg_constraint`-guarded `DO $$ ... ALTER TABLE ... ADD CONSTRAINT ... $$` (covers existing DBs). Called **after** the self-heal, never before — see §3.3, this ordering is load-bearing. |
| 4 | Does the FK make an otherwise-passing teardown raise? | **Yes, in exactly the collision case that today corrupts silently — and only that case.** Analysed in §2.4. Ruled **acceptable**; the approach is kept. |
| 5 | Make the self-heal total? | **Yes.** New `restore_or_discard_backup_rows!/0`: restore rows whose parent tenant still exists, **discard** rows whose parent is gone, logging each discard. |
| 6 | Only `restore_orphaned_guard_backup_rows!/0`, as the task's item 2 words it? | **No — both call sites.** `with_only_this_tenant_visible!/2`'s `after` block runs the *identical* CTE and has the *identical* FK exposure. Fixing only the `setup` path leaves the same 23503 reachable mid-test. Justified in §4.2; this is the one deliberate widening of the task's literal wording, and it stays inside the named file. |
| 7 | Does this heal the existing orphan `75163622-…` with no human/agent `DELETE`? | **Yes.** Traced statement-by-statement in §6. |

Nothing below is left "TBD". §8 lists the residual risks that are *characterised and accepted*,
not open questions; §9 lists the one genuine open question, which is not load-bearing for
implementation.

---

## 1. Facts re-derived from the live database (not inherited from the handoff)

Per `core-directives.md` ("a handoff's factual premises are checkable"), every schema claim the
diagnosis rests on was re-queried in this run against `letflow_test` in
`letflow-2-postgres-1`. All confirmed:

- `public.iss060_tenant_schemas_guard_backup` — columns `id uuid NOT NULL`, `tenant_id uuid NOT
  NULL`, `schema_name text NOT NULL`, `migrations_applied_at timestamp`, `provisioned_at
  timestamp NOT NULL`. **Indexes: `iss060_tenant_schemas_guard_backup_pkey PRIMARY KEY (id)` and
  nothing else. Foreign-key constraints: none.** The blind spot is real.
- `public.tenant_schemas` — same five columns (`schema_name varchar(255)`, timestamps
  `timestamp(0)`), `PRIMARY KEY (id)`, **UNIQUE `tenant_schemas_schema_name_index`**, **UNIQUE
  `tenant_schemas_tenant_id_index`**, and `tenant_schemas_tenant_id_fkey FOREIGN KEY (tenant_id)
  REFERENCES tenants(id)` with **no `ON DELETE` action**.
- `public.tenants` — `tenants_pkey PRIMARY KEY (id)`; referenced by four FKs
  (`pack_update_resolutions`, `solution_pack_artefact_bases`, `solution_pack_installs`,
  `tenant_schemas`), all of them plain `NO ACTION`. The new constraint will be the fifth, and
  matching their action keeps `tenants` uniform.
- The orphan: exactly one row in the backup table — `id
  75163622-df56-481e-977d-9efd35d659fb`, `tenant_id a45c5245-e1e7-4542-b74b-9c605a9fc386`,
  `schema_name tenant_a45c5245e1e74542b74b9c605a9fc386`. `SELECT count(*) FROM public.tenants`
  → `0`. Its parent is genuinely absent.
- Server is **PostgreSQL 16.13**; `current_user` is `letflow` and it **owns** the backup table,
  so `ALTER TABLE ... ADD CONSTRAINT` is permitted with no privilege change.

Current code line anchors in `test/letflow/identity_migration_test.exs` (893 lines total):
`ensure_backup_table!/0` at **247**, `restore_orphaned_guard_backup_rows!/0` at **267** (its
`Repo.checkout` at 280, its restore CTE at 285), `with_only_this_tenant_visible!/2` at **309**
(its `Repo.checkout` at 322, move-out CTE at 330, move-back CTE at 345), `setup do` at **373**.

**Nothing found contradicts ISSUE-FIXER's diagnosis.** Three things were found that *extend* it
and that the implementation must account for — see §4.2 (the second, unnamed 23503 site), §2.4
(the exposure is *every* other tenant, not one), and §5.1 (the regression test cannot seed an
orphan by a plain `INSERT` once the FK exists).

---

## 2. Defect A — closing the referential blind spot

### 2.1 The invariant being restored

`tenant_schemas.tenant_id → tenants.id` exists so that **a tenant cannot be deleted while a
registry row still points at it**. `with_only_this_tenant_visible!/2` moves other tenants' rows
into a table that carries no such constraint, so for the duration of its critical section the
invariant is *suspended for every tenant but one*. The fix is not to add error handling around
the consequence; it is to make the row carry its protection with it while it is parked.

### 2.2 The constraint

Name (explicit, so the idempotence guard in §2.3 can match on it):

```
iss060_tenant_schemas_guard_backup_tenant_id_fkey
  FOREIGN KEY (tenant_id) REFERENCES public.tenants (id)
```

**No `ON DELETE` clause — `NO ACTION`.** Ruling, with the alternatives ruled out rather than
ignored:

- **`NO ACTION` (chosen).** Identical semantics to `tenant_schemas_tenant_id_fkey`. This is the
  whole point: a row must be equally protected whether it is currently *visible* in
  `tenant_schemas` or *parked* in the backup table. Any divergence between the two states is
  precisely the bug.
- **`ON DELETE CASCADE` — rejected.** It never raises, which is superficially attractive, but it
  re-creates the blind spot one level down: `DELETE FROM tenants` would succeed, silently
  vaporising the parked registry row, and the snapshot holder's move-back would restore nothing
  while reporting success. That is "papering over," which the task explicitly rules out, and it
  is strictly worse than today only in being harder to notice.
- **`ON DELETE SET NULL` — impossible.** `tenant_id` is `NOT NULL`.
- **`ON DELETE RESTRICT` — rejected.** Raises like `NO ACTION` but checks immediately and cannot
  be deferred, so it is strictly less flexible for no benefit, and it would differ from
  `tenant_schemas`'s own constraint. Uniformity with the table being mirrored wins.
- **`DEFERRABLE INITIALLY DEFERRED` — rejected, and note *why*, since it looks like a way to
  dodge §2.4's behaviour change.** It would not dodge anything: the ~40 teardowns run under
  autocommit (`Sandbox.mode(:auto)` plus bare `Repo.delete_all/1`), so each statement's implicit
  transaction commits immediately and a deferred check fires at that same commit. Same raise,
  same place.

### 2.3 Converging existing databases (the `CREATE TABLE IF NOT EXISTS` problem)

`ensure_backup_table!/0` uses `CREATE TABLE IF NOT EXISTS`, so on every developer and CI database
where the table already exists the `CREATE` is a no-op and the table would **never** gain the
constraint. Two complementary mechanisms, both idempotent:

**(a) Fresh databases — inline in the `CREATE`.** `ensure_backup_table!/0`'s DDL becomes:

```sql
CREATE TABLE IF NOT EXISTS public.iss060_tenant_schemas_guard_backup (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL,
  schema_name text NOT NULL,
  migrations_applied_at timestamp,
  provisioned_at timestamp NOT NULL,
  CONSTRAINT iss060_tenant_schemas_guard_backup_tenant_id_fkey
    FOREIGN KEY (tenant_id) REFERENCES public.tenants (id)
);
```

Column list, order and types are **unchanged** — this is still the exact structural mirror of
`tenant_schemas` that `iss060-migration-guard-test-race-fix.md` §3 requires, so the `SELECT *`
restore stays valid. A named table constraint adds no column.

**(b) Existing databases — a guarded `ALTER`.** New helper `ensure_backup_table_fk!/0` issues one
statement:

```sql
DO $$
DECLARE
  v_rel regclass := to_regclass('public.iss060_tenant_schemas_guard_backup');
BEGIN
  IF v_rel IS NOT NULL AND NOT EXISTS (
       SELECT 1
       FROM pg_constraint
       WHERE conrelid = v_rel
         AND conname  = 'iss060_tenant_schemas_guard_backup_tenant_id_fkey'
     ) THEN
    ALTER TABLE public.iss060_tenant_schemas_guard_backup
      ADD CONSTRAINT iss060_tenant_schemas_guard_backup_tenant_id_fkey
      FOREIGN KEY (tenant_id) REFERENCES public.tenants (id);
  END IF;
END
$$;
```

Properties this shape is chosen for, each stated so the implementer does not "simplify" one away:

- **Re-running is a genuine no-op.** The `pg_constraint` pre-check means the second and every
  later call executes no DDL at all — it does not merely swallow a `42710 duplicate_object`
  after the fact. This matters because `ALTER TABLE ... ADD CONSTRAINT ... FOREIGN KEY` takes
  `ACCESS EXCLUSIVE` on the backup table **and `SHARE ROW EXCLUSIVE` on `public.tenants`**, and
  the latter conflicts with the `ROW EXCLUSIVE` every concurrent `INSERT`/`UPDATE`/`DELETE` on
  `tenants` holds. Unguarded, this would briefly block *every* concurrent invocation's tenant
  writes on *every* test in this file. Guarded, it is a genuinely one-time cost per database, on
  a table with single-digit rows.
- **`to_regclass` rather than `'…'::regclass`** so the block is inert (not an error) if the
  table somehow does not exist yet.
- **`ADD CONSTRAINT`, not `ADD CONSTRAINT ... NOT VALID`.** `NOT VALID` would skip the validating
  scan of existing rows, which sounds safer but leaves the constraint permanently unvalidated
  unless a second `VALIDATE CONSTRAINT` is issued, and it does **not** reduce the lock taken on
  `tenants`. The validating scan is over a table that holds at most a handful of rows. §3.3's
  ordering makes the scan trivially pass.
- **Not atomic against a *concurrent identical* `ALTER`** (check-then-act). Acceptable and
  bounded: every caller of this helper first holds the `@guard_lock_key` advisory lock (ISS-0111,
  §3.1), and no code outside this one test module touches this table at all.

### 2.4 Behaviour change in other test files — the explicit analysis

This is the part that could make the approach unsafe, so it is analysed rather than asserted.

**The exposure is wider than one tenant.** The move-out is `WHERE tenant_id <> $1`, so during a
critical section **every other live tenant's** registry row is parked. Any concurrent
invocation's teardown of any provisioned tenant is in scope, not just one unlucky tenant.

**What changes, exactly.** The ~40 teardowns are uniformly:

```
DROP SCHEMA IF EXISTS "<schema_name>" CASCADE           -- Repo.query!/1
DELETE FROM tenant_schemas WHERE tenant_id = <id>       -- Repo.delete_all(Registration …)
DELETE FROM tenants        WHERE id        = <id>       -- Repo.delete_all(Tenant …)
```

- **Backup table empty (the overwhelmingly normal state):** the FK has nothing to match, and the
  three statements behave exactly as today. **No change.**
- **This tenant's row parked, i.e. a concurrent invocation is mid-critical-section:** today the
  second statement matches 0 rows and the third *silently destroys the tenant*, orphaning the
  parked row forever. With the FK, the third statement raises `23503` and the tenant survives.
  **This is the behaviour change, and it occurs in exactly the situation that is already a
  corruption today.**

**Collision rate is unchanged; only the outcome changes.** The FK introduces no new window, no
new contention, and no new statement. It converts a silent, permanent, mis-attributed corruption
into a loud, transient, correctly-located failure. Concretely, the two outcomes:

| | Today (no FK) | With the FK |
|---|---|---|
| Concurrent teardown | succeeds, destroys the tenant | raises `23503` in `on_exit`, one test fails |
| Snapshot holder's move-back | raises `23503`, rows stranded | succeeds (parent still exists) |
| `identity_migration_test.exs` | **all 10 tests fail, every run, forever** | unaffected |
| Manual intervention needed | yes (this run) | no |
| Failure names the culprit | no — surfaces days later in an unrelated file | yes — at the moment and site of the conflict |

**Residue left by a raising teardown, traced (this is what decides "acceptable").** `DROP SCHEMA
… CASCADE` has already run; the `Registration` delete matched 0; the `Tenant` delete raises. End
state: tenant row present, registry row parked, physical schema gone. The snapshot holder then
restores the registry row successfully — the parent still exists precisely because the FK blocked
its deletion. The final state is a `tenant_schemas` row whose physical schema is missing, which
is **exactly the input `test/support/tenant_schema_reaper.ex` exists to reclaim**: its
`sweep_orphans/2` drives off `tenant_schemas` rows and `reclaim_row/2` (lines 228-231) does
`DROP SCHEMA IF EXISTS` → `DELETE FROM tenant_schemas` → `DELETE FROM tenants`, in that order,
which the FK permits (the backup table is empty by then). So the residue is *self-reclaiming by
an already-shipped mechanism*, and it is visible to that mechanism — unlike today's residue,
which by construction is invisible to it. `reclaim_row/2` additionally `rescue`s and logs per row
rather than aborting the sweep, so even an unexpected raise there degrades gracefully.

**Can the FK block the reaper itself? Practically unreachable and self-limiting — not impossible
by construction.** An earlier draft of this section argued impossibility, and that argument was
wrong; it is corrected here rather than quietly dropped, because this is the safety section and it
must not assert more than it can support.

*Why the construction argument fails.* "A tenant's registry row is either in `tenant_schemas` or
parked in the backup table, never both" is true, but it is an **instantaneous** invariant, and the
reaper's decision is not instantaneous. `sweep_orphans/2` selects its entire candidate set in one
query (`test/support/tenant_schema_reaper.ex:141-144`) and then iterates; `reclaim_row/2` issues
its `DELETE FROM tenants` (line 231) potentially many rows later. A concurrent invocation's
move-out can park an already-selected row inside that window. Line 230's `DELETE FROM
tenant_schemas` then matches 0 rows and line 231 raises `23503` under the new FK. So the FK *can*
in principle block the reaper. The conclusion below survives; the reasoning is different.

*Why it is nevertheless not a concern, on two independent grounds:*

1. **The precondition is near-eliminated by the reaper's own deferral.** Reaching that window at
   all requires a second `mix test` invocation to be mid-critical-section — and `sweep_orphans/2`
   checks for exactly that first: `concurrent_invocation_present?/2` (called at line 127, defined
   at line 201) makes `sweep_orphans/2` hard-return `{:ok, %{reclaimed: 0,
   skipped_invalid_format: 0}}` at line 136, reaping nothing whenever another
   invocation is connected (ISS-0110/ISS-0217's `application_name` tag). The sweep that could
   collide is precisely the sweep that does not run. The residual is the narrow race in which the
   other invocation connects *after* that check and reaches its move-out before this sweep's loop
   reaches that row.
2. **If it happens anyway, it degrades gracefully and retries.** `reclaim_row/2` `rescue`s
   per row, logs a `Logger.warning/1` naming the id/tenant_id/schema_name, and returns `false`,
   so the remaining rows still sweep; `sweep_orphans/2` additionally `rescue`s at the outer level
   (line 167) and returns `{:ok, %{reclaimed: 0, …}}` rather than propagating. The row is left in
   place for the next boundary sweep, which — the parked row having since been restored — will
   reclaim it normally. Nothing is corrupted and nothing is lost; a single reclaim is deferred by
   one sweep.

Net: bounded improbability with a self-healing failure mode, not impossibility. No change to
`tenant_schema_reaper.ex` is required, and §4.3's scope boundary is unaffected.

**Effect on this file's own existing tests — checked, not assumed.** Two existing tests insert
into the backup table or into `tenant_schemas` directly:
`"ISS-0060: with_only_this_tenant_visible!/2 guard fix"` (racer tenant, line ~630) and
`"ISS-0060: self-heal of an interrupted guard run"` (line ~802). Both create a **real, committed
`Tenant` row first** and both already carry an `on_exit` that deletes the `tenant_schemas` row
*before* the `Tenant` row, with a comment naming the FK as the reason. Both therefore satisfy the
new constraint unchanged. **No edit to either test is required by this design.**

**Ruling: the approach is safe and is kept.** The behaviour change is confined to a collision
that is already a defect, it strictly improves the outcome of that collision, and the precondition
for the collision at all — two `mix test` invocations sharing one database — is itself an open
filed bug (ISS-0107, `Mix.Tasks.Letflow.Check.Test`'s `Port.open` inheriting `LETFLOW_DB_PORT`),
whose fix removes the exposure entirely and at which point this constraint costs nothing and
still stands as defence in depth.

---

## 3. Changed and new helpers — interfaces

All are `defp` in `Letflow.IdentityMigrationTest`. No public API anywhere changes. The module
gains `require Logger` (it has none today) immediately after its existing `import Ecto.Query`.

### 3.1 `ensure_backup_table!/0` — changed

```
@spec ensure_backup_table!() :: :ok
```
Input: none. Output: `:ok`. Raises: only on a genuine DDL failure.
Change: its `CREATE TABLE IF NOT EXISTS` DDL gains the inline named `CONSTRAINT` of §2.3(a).
Nothing else about it changes; it remains cheap and idempotent and is still safe to call on
every test. It **does not** call `ensure_backup_table_fk!/0` — see §3.3.

### 3.2 `ensure_backup_table_fk!/0` — new

```
@spec ensure_backup_table_fk!() :: :ok
```
Input: none. Output: `:ok`. Raises: `Postgrex.Error` only if the `ALTER` genuinely fails.
Behaviour: issues the single guarded `DO $$ … $$` statement of §2.3(b) via `Repo.query!/1`, then
returns `:ok`. Called from exactly one place — see §3.3.

### 3.3 `restore_orphaned_guard_backup_rows!/0` — changed

```
@spec restore_orphaned_guard_backup_rows!() :: :ok
```
Signature and call site (`setup`, line 373) unchanged. Its `Repo.checkout/2` wrapper and its
`acquire_guard_lock!/0` … `after release_guard_lock!/0` structure (ISS-0111 §3.3) are preserved
**verbatim**. Inside the `try`, the inline restore CTE is replaced by, **in this order**:

1. `restore_or_discard_backup_rows!/0` (§3.4) — heals first.
2. `ensure_backup_table_fk!/0` (§3.2) — constrains second.
3. return `:ok`.

**This ordering is load-bearing, and reversing it breaks the fix.** `ALTER TABLE … ADD
CONSTRAINT … FOREIGN KEY` validates existing rows. On the currently-poisoned `letflow_test`, an
`ALTER` attempted *before* the heal would itself raise `23503` on the orphan row — turning the
convergence step into a second, new way for `setup` to fail all 10 tests. Healing first
guarantees the table is empty (or holds only restorable rows) when the scan runs. This is also
why `ensure_backup_table_fk!/0` is **not** folded into `ensure_backup_table!/0`: that helper is
called from `with_only_this_tenant_visible!/2` and directly from an existing test, neither of
which is preceded by a heal.

Both steps run while the `@guard_lock_key` advisory lock is held, on the single connection pinned
by `Repo.checkout/2`, so a concurrent invocation of this same module can be neither mid-move-out
during the `ALTER` nor racing the `pg_constraint` pre-check.

### 3.4 `restore_or_discard_backup_rows!/0` — new (the total move-back)

```
@spec restore_or_discard_backup_rows!() :: :ok
```
Input: none. Output: `:ok`. **Never raises on an unrestorable row.**

Preconditions the caller must satisfy (both existing call sites already do): executing inside a
`Repo.checkout/2` callback, holding `@guard_lock_key`.

Behaviour, stated as steps, not code:

1. Execute `@restore_or_discard_sql` (§4.1) via `Repo.query!/1`. The result's `rows` are exactly
   the rows that were **discarded**, each `[id :: String.t(), tenant_id :: String.t(),
   schema_name :: String.t()]` (cast to text in SQL so no `Ecto.UUID.cast!/1` is needed).
2. For each such row emit **one** `Logger.warning/1` naming id, tenant_id and schema_name, e.g.
   `"ISS-0229: discarded unrestorable guard-backup row id=<id> tenant_id=<tenant_id> schema_name=<schema_name> — parent tenant no longer exists in public.tenants"`.
   `Logger.warning` (not `debug`/`info`) because a discard means data was destroyed, and no
   `capture_log` is configured project-wide (checked: neither `config/config.exs` nor
   `test/test_helper.exs` sets a logger level or `capture_log`), so it prints to the run output.
3. Return `:ok`.

**Bounded retry, exactly once, on `23503` only.** If step 1 raises a `Postgrex.Error` whose
`postgres.code` is `:foreign_key_violation`, log one `Logger.warning/1` recording the retry and
re-execute step 1 **once**, then continue at step 2 with the retry's rows. Any other exception,
and a `23503` from the retry, propagate unchanged.

Why this is correct and not a blanket rescue: the SQL is a single statement, so a failure rolled
the whole thing back and the rows are still in the backup table — the retry is a genuine,
side-effect-free redo. The only way the first attempt can raise `23503` is §8.1's snapshot race
(a tenant deleted-and-committed between this statement's snapshot and the FK trigger's own,
which is only reachable *before* the FK has converged); the retry's fresh snapshot then sees the
tenant as absent and classifies the row as a discard. Rescuing only `:foreign_key_violation`,
and only once, means a genuine defect (a typo'd column, a missing table, a lock timeout) still
fails loudly rather than being swallowed.

### 3.5 `with_only_this_tenant_visible!/2` — changed

```
@spec with_only_this_tenant_visible!(tenant_id :: Ecto.UUID.t(), fun :: (-> result)) :: result
      when result: term()
```
Signature, return contract and exception semantics **unchanged** (returns `fun.()`'s value;
re-raises whatever `fun.()` raises *after* cleanup). The `Repo.checkout/2` wrapper, the
`acquire_guard_lock!/0` … `after release_guard_lock!/0` pairing, the `ensure_backup_table!/0`
call and the move-out CTE (line 330) are all **unchanged**.

**The one change:** the inner `after` block's inline move-back CTE (line 345) is replaced by a
call to `restore_or_discard_backup_rows!/0`. Rationale in §4.2.

---

## 4. The exact SQL

### 4.1 `@restore_or_discard_sql` — the total move-back

Replaces the CTE currently duplicated at lines 285 and 345. Defined once as a module attribute so
the two call sites cannot drift.

```sql
WITH taken AS (
  DELETE FROM public.iss060_tenant_schemas_guard_backup
  RETURNING *
),
restorable AS MATERIALIZED (
  SELECT t.*
  FROM taken t
  WHERE EXISTS (SELECT 1 FROM public.tenants tn WHERE tn.id = t.tenant_id)
),
restored AS (
  INSERT INTO public.tenant_schemas
  SELECT * FROM restorable
  ON CONFLICT (id) DO NOTHING
  RETURNING id
)
SELECT t.id::text, t.tenant_id::text, t.schema_name
FROM taken t
WHERE t.id NOT IN (SELECT id FROM restorable)
```

**Verified, not assumed:** this exact statement was run through `EXPLAIN` (planning only — no
execution, no mutation) against `letflow_test` on the live PG 16.13 server during this design.
It plans cleanly, and the plan confirms the intended structure: `CTE taken` → `Delete on
iss060_tenant_schemas_guard_backup`; `CTE restorable` → `Hash Join` against `tenants`; `CTE
restored` → `Insert on tenant_schemas / Conflict Resolution: NOTHING / Conflict Arbiter Indexes:
tenant_schemas_pkey`; outer `CTE Scan on taken t` with `Filter: (NOT (hashed SubPlan 4))` reading
`restorable` a second time. The `pg_constraint` guard predicate of §2.3(b) was likewise executed
read-only and returns `false` today (constraint absent), and `tenant_schemas_tenant_id_fkey` was
confirmed to have `contype = 'f'`, `confdeltype = 'a'` — the value §5.2 assertion 6 requires the
new constraint to match.

Every clause justified, so none is "tidied away":

- **`taken` empties the backup table unconditionally**, exactly as the current CTE's `restored`
  step does. Restorable and unrestorable rows leave the table by the same `DELETE`; what differs
  is only whether they are re-inserted. This is what makes the helper *total*: after it runs, the
  backup table is empty in every case, so the poisoned state cannot persist.
- **`restorable` filters by parent existence** with `EXISTS`, the direct expression of "the row is
  restorable iff its parent tenant is still there." `AS MATERIALIZED` is specified (PG 12+;
  server is 16.13, confirmed §1) because the CTE is referenced twice and materialising it removes
  any question of the two references disagreeing. This is belt-and-braces: `taken` is a
  data-modifying CTE and is therefore already materialised, and all CTE sub-statements share one
  snapshot, so both references would agree regardless.
- **`restored` keeps `INSERT … SELECT * FROM restorable`** — no explicit column list. This
  deliberately preserves `iss060-migration-guard-test-race-fix.md` §3's column-drift-safety
  property (the backup table is an exact structural mirror of `tenant_schemas`, so `SELECT *` can
  never mis-map). The classification is expressed as a *filter*, not as an added column, precisely
  so this stays true.
- **`ON CONFLICT (id) DO NOTHING` is retained unchanged** — it handles the duplicate-primary-key
  case ISS-0060 §6 already reasoned about, which is orthogonal to the FK case being added here.
- **`restored` is never referenced by the outer query, and that is fine.** PostgreSQL executes
  data-modifying `WITH` sub-statements "exactly once, and always to completion, independently of
  whether the primary query reads any of their output." The `RETURNING id` exists only to make
  the sub-statement well-formed and readable.
- **The final `SELECT` returns exactly the discarded rows** — `taken` minus `restorable`. `NOT
  IN` is safe here because `restorable.id` is the primary key and can never be `NULL`. `::text`
  casts spare the caller any `Ecto.UUID.cast!/1` handling.
- **Atomicity is preserved.** Still one statement, hence one implicit transaction: the delete,
  the restore and the discard commit together or not at all.
  `iss060-migration-guard-test-race-fix.md` §5's crash-safety argument therefore carries over
  verbatim — there is still no reachable partial-move state.

### 4.2 Why the same helper must replace *both* CTE sites (widening the task's item 2)

The task's item 2 names only `restore_orphaned_guard_backup_rows!/0`. Applying it there alone is
**not sufficient**, and this is stated here rather than resolved silently:

`with_only_this_tenant_visible!/2`'s inner `after` block (line 345) runs the *byte-identical*
CTE against the *same* table under the *same* conditions. It is in fact the **first** site to
raise in the real sequence: the concurrent teardown destroys the tenant *while the snapshot is
held*, so the very next thing that touches the row is the snapshot holder's own move-back, which
raises `23503` mid-test. That raise is what strands the row in the first place; the `setup`
failure the issue reports is the *second-order* symptom, observed on every later run. Fixing only
`setup` would leave the guard-PROCEEDS test failing with a raw `Postgrex.Error` from an `after`
block (which also masks the test's real result) and would leave rows stranded until the *next*
run healed them.

The discard rule is equally correct at this site: a row whose parent tenant no longer exists
cannot be restored into `tenant_schemas` (the FK forbids it) and describes a schema that a
teardown has already dropped. It is meaningless data. Discarding costs nothing; raising costs the
enclosing test.

This widening stays strictly inside `test/letflow/identity_migration_test.exs` and touches no
file the task placed off-limits.

### 4.3 What is explicitly NOT changed

Named so a reviewer can confirm the scope boundary was respected rather than assumed:

- `lib/letflow/tenant_provisioning.ex` — untouched.
- `priv/repo/migrations/*` — untouched. The FK is added to a **test-only** table that no
  migration creates; it does not belong in the migration set and adding it there would be a
  production schema change for a test's benefit.
- `test/support/tenant_schema_reaper.ex` — untouched. §2.4 shows it needs no change and in fact
  becomes *more* effective, since the residue the FK now produces is visible to it.
- The ~40 per-test teardowns — untouched. §2.4 rules their new raise acceptable; "fixing" them
  (e.g. deleting the backup row before the tenant) would re-open the blind spot from the other
  side.
- `with_only_this_tenant_visible!/2`'s move-out CTE, its lock discipline, its `Repo.checkout/2`
  wrapper, and its return/raise contract — all unchanged.

---

## 5. Regression-test obligation for TEST-DESIGNER

The fail-first proof here is **not** module-nonexistence, so the plain fail-then-pass rule
applies: the new test must be shown failing against the current code and passing against the
fixed code.

### 5.1 How to construct the failing state — the non-obvious part

**A plain `INSERT` of an orphan row will not work once the FK exists** — the seeding `INSERT`
would itself raise `23503`. The test must therefore reproduce the *real* pre-convergence shape:
**no constraint + an orphan row**, which is exactly what the poisoned `letflow_test` looks like
today. Sequence:

1. `ALTER TABLE public.iss060_tenant_schemas_guard_backup DROP CONSTRAINT IF EXISTS
   iss060_tenant_schemas_guard_backup_tenant_id_fkey;`
2. `INSERT` one backup row with a freshly generated `tenant_id` that is **not** present in
   `public.tenants` (assert its absence first, so the fixture proves its own premise).
3. Call `restore_orphaned_guard_backup_rows!/0` directly (the same helper `setup` calls).

Against the current code, step 3 raises `Postgrex.Error` 23503 — a real, demonstrated failure.
Against the fix it returns `:ok`.

Because the helpers are `defp`, this test **must live in
`test/letflow/identity_migration_test.exs`**, in a new `describe "ISS-0229: …"` block. It cannot
be a separate file.

#### 5.1.1 Cleanup — mandatory shape, and why the obvious one is wrong

An earlier draft of this section said the test should `on_exit` "call `ensure_backup_table_fk!/0`,
and clean up any tenant it created." **That is wrong on two counts and must not be implemented.**

- **It inverts §3.3's heal-before-constrain rule.** The test body deliberately drops the
  constraint and then parks an orphan. If the body raises before step 3 — which is *exactly* what
  the fail-first run requires be demonstrated — an `on_exit` calling `ensure_backup_table_fk!/0`
  would attempt the validating `ALTER` with the orphan still parked. It raises `23503` and leaves
  the constraint absent with the orphan present: ISS-0229's own poisoned state, re-created by
  ISS-0229's regression test.
- **It makes fail-first undemonstrable.** `ensure_backup_table_fk!/0` does not exist before the
  fix, so a test naming it does not *compile* against pre-fix helper bodies. The pre-fix failure
  would be an `undefined function` compile error — precisely the module-nonexistence shape §5
  rules out — rather than the behavioural 23503 the fail-then-pass rule demands.

**Registration order is mandated, not left to taste — it is what makes the cleanup total.** An
earlier draft of this paragraph required pre-generating *every* id "including the real `Tenant`'s
id" before any DDL/DML. **That was not implementable and is withdrawn.** `Letflow.Identity.Tenant`
declares `@primary_key {:id, :binary_id, autogenerate: true}` (`lib/letflow/identity/tenant.ex:52`)
and `create_changeset/3` casts only `[:slug, :display_name, :status, :idp_realm_id]` — `:id` is
not castable — so a pre-generated tenant id cannot be supplied through the idiom all three
tenant-creating tests in this same file already use (`%Tenant{} |> Tenant.create_changeset(…) |>
Repo.insert!()`, lines 114, 647, 816), and the tenant's id is only knowable *after* the insert.
The rule below therefore applies pre-generation **only** to ids inserted by raw SQL into the
backup table, where it genuinely is free, and handles the tenant with its own separately
registered callback instead. No Ecto internals and no departure from the file's existing idiom
are involved.

**`on_exit` is LIFO — the callbacks run in reverse registration order.** Verified against the
implementation, not assumed: `ExUnit.OnExitHandler.add/3` appends via `List.keystore/4`, and
`run/2` executes `Enum.reverse(callbacks)`. So *register cleanup in the reverse of the order you
want it to run.* Three callbacks, registered in this order:

- **(A) First, before anything else in the test body** — carries step 4 alone. Registered
  unconditionally at the very top so it runs no matter how early the body fails; being last to
  execute is exactly what makes step 4's `ALTER` see an already-emptied table.
- **(B) Immediately after the real `Tenant` insert** (which the test does first, since the
  restorable row of §5.2 assertion 5 needs a live parent) — carries steps 2 and 3. If the insert
  itself raises there is no tenant to clean, so nothing is missed by this callback not existing.
- **(C) After generating the backup-table ids, and before the `DROP CONSTRAINT` and the seeding
  `INSERT`s** — carries step 1, closing over the **full pre-generated id list**. Generate
  whichever of the following that test seeds — the orphan backup row's `id`, its deliberately
  absent `tenant_id`, the restorable row's `id` — before issuing any DDL or DML;
  `Ecto.UUID.generate/0` touches no database, so this costs nothing and makes the cleanup's
  coverage independent of how far the body got.

The failure this prevents is concrete: if step 1's ids were generated inline and its callback
registered only after seeding, a body raising part-way through seeding would leave a row step 1
does not target, step 4's validating `ALTER` would then raise 23503 inside `on_exit`, and the
constraint would be left off with an orphan parked — exactly the state §5.1.1 exists to prevent.

Reverse-registration execution is therefore **(C) → (B) → (A)**, which yields steps 1, 2, 3, 4 in
the numbered order below — backup rows removed, then the tenant's registry row and the tenant,
then heal-then-constrain last, ending with the constraint in force over an empty table.
TEST-DESIGNER must not re-derive any of this.

**Mandatory cleanup — the four steps, in the execution order the registration above produces**
(this applies to every test in the new block, including assertion 9's scenario, per §5.2):

1. `DELETE FROM public.iss060_tenant_schemas_guard_backup WHERE id = ANY($1)`, bound to the
   **full pre-generated id list** from (C) — not to whatever the body managed to insert. A
   targeted `DELETE` on the *referencing* side is never FK-checked, so this cannot raise
   regardless of what state the body left; passing ids that were never inserted is a harmless
   no-op; and it removes only what this test could have created. This step is what guarantees the
   backup table is empty before step 4, which is the precondition step 4's `ALTER` needs.
2. `DELETE FROM public.tenant_schemas WHERE tenant_id = $1` for any real tenant the test created,
   **before** deleting the tenant itself — the same ordering the two existing ISS-0060 tests
   already use, for the same FK reason.
3. `Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))`.
4. `restore_orphaned_guard_backup_rows!/0` — **never `ensure_backup_table_fk!/0` directly.** It is
   the composed heal-then-constrain entry point (§3.3), so calling it restores the constraint in
   the correct order, is a no-op on the already-clean table steps 1-3 left, and — being a helper
   that already exists pre-fix — keeps the block compilable against reverted helper bodies.

**General rule this instance of:** the new `describe` block must name, in its own source, **only
helpers that already exist before the fix** — `restore_orphaned_guard_backup_rows!/0`,
`with_only_this_tenant_visible!/2`, `ensure_backup_table!/0`. It must reach the new behaviour
*through* them and never call `ensure_backup_table_fk!/0` or `restore_or_discard_backup_rows!/0`
by name. Everything the new helpers are responsible for is observable without naming them:
constraint presence, `confdeltype` and enforcement are all checked with raw SQL (§5.2 assertions
6-7).

#### 5.1.2 The fail-first run — concretely what to execute

The regression test lives in the same file as the fix, so "check out the old file" would revert
the test too. The demonstration is therefore:

1. Keep the new `describe "ISS-0229: …"` block; revert **only** the §3 helper-body changes
   (`ensure_backup_table!/0`'s inline `CONSTRAINT`, `restore_orphaned_guard_backup_rows!/0`'s new
   two-step body, `with_only_this_tenant_visible!/2`'s `after`-block call), and remove the two
   new helpers. §5.1.1's naming rule is what makes this still compile.
2. Run `MIX_ENV=test mix test test/letflow/identity_migration_test.exs` and **quote the actual
   output**. The expected pre-fix failure is behavioural, not a compile error: assertion 1 dies
   with `** (Postgrex.Error) ERROR 23503 (foreign_key_violation) insert or update on table
   "tenant_schemas" violates foreign key constraint "tenant_schemas_tenant_id_fkey"`, raised from
   `restore_orphaned_guard_backup_rows!/0`. If instead an `undefined function` error appears, the
   test violates §5.1.1's naming rule and must be rewritten, not worked around.
3. Restore the §3 helper bodies and re-run the same command; the block passes.

**The pre-fix run leaves no residue — stated explicitly, because an earlier draft of this
paragraph claimed the opposite and was wrong.** That draft said the cleanup's step 4 also raises
pre-fix and so leaves the seeded orphan parked with no constraint. Both clauses are false *by
§5.1.1's own design*: `on_exit` runs after the body raises, and **step 1** removes the seeded
orphan by id — which is precisely what step 1 exists for, and which §5.1.1 states cannot raise
regardless of what state the body left. The backup table is therefore **empty** by the time step
4 runs, so pre-fix step 4 executes the old CTE over zero rows, inserts nothing and returns `:ok`.
Correct end state of the pre-fix run: **no orphan and no constraint** — the database's ordinary
pre-fix shape — and step 3's run then converges the constraint. Nothing is left for anyone to
hand-clean, and any reading on which step 1 does *not* remove the orphan is a misreading that
would reinstate the raising `on_exit` §5.1.1 was written to eliminate.

**Where §6's end-to-end confirmation actually comes from, then.** Not from this test — the
regression test deliberately cleans up after itself, so it cannot double as evidence that the
self-heal converges a genuinely poisoned database. That evidence comes independently, from the
**live orphan currently sitting in `letflow_test`** (`75163622-df56-481e-977d-9efd35d659fb`,
§1): the first post-fix run of this file heals and discards it via §6's exact path, with the
`Logger.warning/1` naming it in the run output. TEST-RUNNER should capture that log line as the
§6 confirmation. It is a one-shot observation — once healed, the state is gone — so it must be
recorded on the first post-fix run rather than reconstructed later, and the orphan must not be
deleted by hand before then.

### 5.2 What must be asserted

Minimum set; each line is a distinct failure mode a partial fix could pass without:

1. **No raise.** `restore_orphaned_guard_backup_rows!/0` returns `:ok` on the orphaned state.
   *(Core fail-first assertion.)*
2. **Discarded, not left.** `SELECT count(*) FROM public.iss060_tenant_schemas_guard_backup WHERE
   id = <orphan id>` is `0` afterwards.
3. **Discarded, not restored.** `SELECT count(*) FROM public.tenant_schemas WHERE tenant_id =
   <absent tenant_id>` is `0` afterwards — proves the row was dropped, not force-inserted.
4. **The discard is logged and names the row.** Wrap the call in
   `ExUnit.CaptureLog.capture_log/1` and assert the captured text contains both the orphan `id`
   and the orphan `tenant_id`. *(Guards the "visible log" requirement, which a silent `DELETE`
   would otherwise satisfy.)*
5. **Restorable rows are still restored — the anti-regression that matters most.** In the same
   run, seed a **second** backup row whose parent tenant genuinely exists (create a real
   `Tenant`), and assert it lands in `public.tenant_schemas` with its `id`, `schema_name`,
   `migrations_applied_at` and `provisioned_at` preserved. Without this, an implementation that
   simply `DELETE`s the whole backup table passes 1-4 while destroying live data. Seeding both
   rows in the *same* call also proves the classification is per-row, not per-call.
6. **The FK converges, and is the right one.** After the call, query `pg_constraint` and assert
   `iss060_tenant_schemas_guard_backup_tenant_id_fkey` exists on the backup table with
   `contype = 'f'`, `confrelid = 'public.tenants'::regclass`, and `confdeltype = 'a'` (NO
   ACTION). Asserting `confdeltype` is what stops a later "fix" from quietly switching to
   `CASCADE`, which §2.2 rejects.
7. **The FK is actually enforced.** After convergence, an `INSERT` of a backup row with an absent
   `tenant_id` raises `Postgrex.Error` with `postgres.code == :foreign_key_violation`. Proves the
   constraint is enforcing and not `NOT VALID`.
8. **Idempotence.** Calling `restore_orphaned_guard_backup_rows!/0` a second time immediately
   returns `:ok`, emits no discard log, and leaves the `pg_constraint` row count for that
   constraint name at exactly `1`.
9. **`with_only_this_tenant_visible!/2` inherits the totality (§4.2).** Assert the same
   orphan-survival property at the second call site: with the constraint dropped and an orphan
   row parked, `with_only_this_tenant_visible!/2` completes and returns `fun.()`'s value rather
   than raising from its `after` block.
   **Cleanup for this scenario must be specified, not inherited by assumption.** Unlike
   assertions 1-8, this path does **not** converge the constraint: per §3.3,
   `with_only_this_tenant_visible!/2` calls `restore_or_discard_backup_rows!/0` but **not**
   `ensure_backup_table_fk!/0`, so the scenario finishes with the constraint still dropped. Its
   cleanup must therefore use §5.1.1's three-callback registration in full — in particular step 4's
   `restore_orphaned_guard_backup_rows!/0`, which is the only thing that puts the constraint
   back, and which must run *after* steps 1-3 have emptied the backup table so the validating
   `ALTER` cannot raise. A test that asserts this property and then leaves the constraint off
   silently disarms the FK for every test that runs after it in the same database.

TEST-DESIGNER should note the file is `async: false` and its `setup` already calls
`restore_orphaned_guard_backup_rows!/0` before every test — so any state the new tests seed must
be seeded *inside the test body*, after that `setup` has run.

---

## 6. Confirmation: the existing orphan heals automatically, with no manual `DELETE`

Traced against the concrete row from §1 (`id 75163622-df56-481e-977d-9efd35d659fb`, `tenant_id
a45c5245-e1e7-4542-b74b-9c605a9fc386`, `schema_name tenant_a45c5245e1e74542b74b9c605a9fc386`),
on the very next `MIX_ENV=test mix test test/letflow/identity_migration_test.exs` after the fix
lands:

1. `setup` (line 373) → `restore_orphaned_guard_backup_rows!/0`.
2. `ensure_backup_table!/0` → `CREATE TABLE IF NOT EXISTS` → **no-op**, the table exists. The
   inline constraint in the new DDL is therefore *not* applied by this path — which is why
   §2.3(b) exists.
3. `Repo.checkout/2` + `acquire_guard_lock!/0` → acquired immediately (nothing else holds it).
4. `restore_or_discard_backup_rows!/0` runs §4.1's statement:
   - `taken` deletes the one row and returns it.
   - `restorable` evaluates `EXISTS (SELECT 1 FROM public.tenants WHERE id =
     'a45c5245-…')` → **false** (`public.tenants` is empty, confirmed §1) → `restorable` is
     empty.
   - `restored` inserts **zero** rows — so no `23503`, which is precisely the raise that fails
     all 10 tests today.
   - The outer `SELECT` returns one row: `75163622-…`, `a45c5245-…`,
     `tenant_a45c5245e1e74542b74b9c605a9fc386`.
5. One `Logger.warning/1` is emitted naming that id, tenant_id and schema_name. The run output
   records what was destroyed and why.
6. `ensure_backup_table_fk!/0` runs: the constraint is absent (confirmed §1 — the table has only
   its primary key), the table is now **empty**, so the validating scan is trivial and the
   `ALTER` succeeds. The database is converged.
7. `release_guard_lock!/0`; `setup` returns `:ok`; the test body proceeds.

`public.iss060_tenant_schemas_guard_backup` is empty, the constraint is in force, and **all 10
tests in the file are unblocked** — with no human or agent running a `DELETE`. Steps 2 and 6 are
no-ops on every subsequent run.

---

## 7. Answer to the diagnosis's framed question

**"Should ISS-0111's self-heal have covered the FK case?" — Yes, and this design records why as a
principle, not a one-off.** `restore_orphaned_guard_backup_rows!/0`'s stated purpose
(`iss060-migration-guard-test-race-fix.md` §5) is to recover rows left behind by an abnormal
exit. **A self-heal must be total over the states it can encounter, including the state in which
restoration is no longer possible** — otherwise it is not a self-heal, it is a happy-path retry
that converts a recoverable condition into a permanent one. Two aggravating specifics:

- Its `ON CONFLICT (id) DO NOTHING` addressed a *duplicate primary key*. ISS-0060 §6 open
  question 2 additionally considered a *unique-constraint* violation and knowingly accepted
  "loud failure" for it. The **foreign-key** case — the parent being gone — was never considered
  at all, in either document. The gap is an omission, not an accepted trade-off.
- The call site amplifies it. Because the helper runs from `setup`, one unrestorable row fails
  **every** test in the file, permanently, rather than degrading one. A self-heal wired into
  `setup` carries a stricter totality obligation than one called from a test body, and neither
  prior design noted that.

Recommendation for `docs/anti-patterns.md` (for ORCH to route; **not** filed by this agent, per
`core-directives.md`'s "No Issue Left Local-Only"): *a self-heal that runs in `setup` must be
total — enumerate every state the abnormal exit can leave, including states from which recovery
is impossible, and define a terminal disposition (discard, quarantine) for each. "Loud failure"
is an acceptable disposition only for a code path that is not itself a recovery path.*

---

## 8. Residual risks — characterised and accepted (not open questions)

1. **Snapshot race on the restore, pre-convergence only.** §4.1's statement classifies rows using
   its own snapshot, while the `INSERT`'s FK trigger re-checks `tenants` under a fresh snapshot.
   A tenant deleted *and committed* between those two points would make a row classified
   restorable fail with `23503`. Reachable only while the backup-table FK is absent (once present,
   that `DELETE FROM tenants` is itself blocked). Handled by §3.4's single bounded retry, whose
   second attempt sees the deletion and discards instead. Accepted.
2. **The behaviour change of §2.4** — a concurrent teardown may now raise. Analysed, ruled
   acceptable, and self-limiting once ISS-0107 is fixed. Accepted, not open.
3. **Unique-constraint violations on restore** (`tenant_schemas_tenant_id_index`,
   `tenant_schemas_schema_name_index`) remain uncovered — `ON CONFLICT (id)` targets the primary
   key only. This is ISS-0060 §6 open question 2, unchanged and **deliberately not widened here**:
   no evidence has yet been produced that it occurs, and the discard-vs-restore decision for a
   unique collision is genuinely different from the FK case (the row is *not* meaningless — a
   live row already occupies that `tenant_id`). Left exactly as it was; loud failure remains its
   disposition. If it is ever observed, it is its own issue.
4. **The `ALTER`'s momentary `SHARE ROW EXCLUSIVE` on `public.tenants`** blocks concurrent tenant
   writes for the duration of one validating scan of a table with single-digit rows, once per
   database. Accepted; §2.3's `pg_constraint` guard is what keeps it to once.

---

## 9. Open question (one, not load-bearing for implementation)

**Should the backup table also mirror `tenant_schemas`'s two UNIQUE indexes
(`tenant_id`, `schema_name`)?** The same "the parked row must carry its protection with it"
argument that motivates the FK would, taken to its conclusion, apply to them too — a parked row
and a newly-provisioned live row could hold the same `tenant_id` without either table objecting.
Not resolved here, and deliberately not implemented, for two reasons: (a) it is a strictly larger
change with its own behaviour-change analysis to do (a UNIQUE index on the backup table would
make the *move-out* able to fail, which the FK does not), and (b) it overlaps residual risk 8.3
above, whose disposition is currently "loud failure, no evidence it occurs." Flagged for ORCH to
file as a separate issue if a future run surfaces it. **ELIXIR-DEV must not implement it as part
of ISS-0229.**
