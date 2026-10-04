# Design: ISS-0941 — stricter sweep for orphaned "Tenant Template Build (throwaway)" rows

**Issue:** `docs/issues/ISS-0941.yaml`
**Owner (implementer):** ELIXIR-DEV
**Branch:** `fix/ISS-0941-orphan-tenant-row-reaper`

**Change class:** one new public function + moduledoc addendum on the existing
test-support module `test/support/tenant_schema_reaper.ex`, two new lines (plus
comment) in `test/test_helper.exs`, and one new test file. **Zero production
(`lib/letflow/`) files change.** No Ecto schema/migration change, no new supervised
process, no change to `test/support/tenant_template.ex`'s own build logic.

---

## 0. Sources read in full for this design

- `docs/issues/ISS-0941.yaml` (full) — root cause: two `tenant_schemas`/`tenants` row
  pairs, both `display_name: "Tenant Template Build (throwaway)"`, survived an earlier
  interrupted session on the shared `letflow-postgres-1` dev container, pointing at
  schemas that no longer existed in `information_schema.schemata`. `sweep_orphans/2`
  detects this exact row shape (logs "malformed schema_name") but never deletes it.
  Deleting the two rows directly fixed all 35 non-ISS-0937/938/919 failures across
  `ServiceCatalogTest`, `RoleBackfillTest`, `TaskAssigneeTypeBackfillTest`,
  `ApiPipelineIntegrationTest`, `PlatformMigrationsTest`, `ServiceCatalogReaperTest`,
  `MigrationReplayBootTest`.
- `docs/issues/ISS-0414.yaml` (full) — the precedent this design follows in shape
  (a second independent sweep function added to the same module, same two
  `test/test_helper.exs` boundary call sites, same `concurrent_invocation_present?/2`
  reuse) and `lib/letflow/design/iss0414-service-catalog-safety-net.md` (full) — read
  for its exact section structure and for §2.1's point that an age-threshold is needed
  only when a row can legitimately be held open mid-build, which this design's own §2.1
  below re-derives for the throwaway-build case specifically (closer to `tenant_schemas`
  than to `service_catalog`).
- `test/support/tenant_schema_reaper.ex` (full, 341 lines) — `sweep_orphans/2`'s exact
  current logic: queries `tenant_schemas` rows with `provisioned_at` older than
  `min_age_seconds` (default 300s), and for each row whose `schema_name` matches
  `@schema_name_format` (`^tenant_[0-9a-f]{32}$`) calls `reclaim_row/2` (`DROP SCHEMA ...
  CASCADE` + delete both bookkeeping rows); a row whose `schema_name` does **not** match
  that regex is logged at `:warning` ("malformed schema_name") and left untouched —
  `skipped_invalid_format` counts it, nothing more. The staging name
  `generate_staging_schema_name/0` produces (`"tenant_template_build_" <> 32 hex chars`,
  confirmed in `test/support/tenant_template.ex`) never matches `@schema_name_format`
  (it has an extra literal segment in the middle), so it falls into this skip branch
  **unconditionally by shape**, independent of whether the backing Postgres schema
  genuinely still exists — this is the actual mechanism behind the issue's "detects but
  never deletes" observation, not an explicit in-progress-build check on this module's
  part. Also confirmed: `concurrent_invocation_present?/2`, `current_application_name/1`,
  `group_tag_of/1` are private, same-module, directly reusable (ISS-0414 already
  established this pattern; this design reuses it a second time).
- `test/support/tenant_template.ex` (full, ~550 lines) — confirms the throwaway row's
  full lifecycle, `build_template!/0`/`do_build_template!/1`:
  1. `CREATE SCHEMA "<staging>"` (staging name fresh per attempt, random 32-hex suffix).
  2. `insert_throwaway_tenant_and_registration!/1` inserts the `tenants` row
     (`display_name: "Tenant Template Build (throwaway)"`) and its `tenant_schemas`
     row — **always after** step 1 commits, never before. A `tenant_schemas` row
     matching this display name therefore can never legitimately exist before its
     target schema does; by construction, a schema can only go from existing to absent
     after this row is created, never the reverse.
  3. `TenantProvisioning.replay_migrations/2`. If this raises, `do_build_template!/1`'s
     exception propagates to `build_template!/0`'s own `rescue`, which runs
     `DROP SCHEMA IF EXISTS "<staging>" CASCADE` and **re-raises — it does not delete
     the `tenants`/`tenant_schemas` rows created in step 2.** This is the exact
     mechanism that produces ISS-0941's observed shape: a throwaway row survives with
     its schema already dropped, the moment any exception occurs between step 2 and
     the step-5 rename below (not only on a hard process kill).
  4. Self-check against the staging schema.
  5. `delete_throwaway_tenant_and_registration!/1` — deletes both bookkeeping rows,
     only on the success path, before the rename.
  6. `ALTER SCHEMA "<staging>" RENAME TO "tenant_template"` — the atomic commit point.
  Net: on the **success** path, the throwaway row never outlives its schema and is
  always deleted before this function returns. On any **failure** path after step 2,
  the row survives with its schema already gone. There is no code path in this file
  that produces a throwaway row pointing at a schema that does not exist *yet* (i.e.
  "about to be created") — only "already created, now dropped." This matters directly
  for §2.1 below.
- `test/test_helper.exs` (full, 92 lines) — confirms the two existing boundary call
  sites (`Letflow.TenantSchemaReaper.sweep_orphans()` before `ExUnit.start(...)`, and
  inside the existing `ExUnit.after_suite(fn _stats -> ... end)` callback alongside
  `sweep_service_catalog_orphans/1`), and that `ensure_template!/0` (which can start a
  *fresh* `build_template!/0` run) is invoked **after** both the pre-`ExUnit.start()`
  sweep calls, in the same file, same invocation. This ordering means: whichever sweep
  this design adds, if placed at the existing pre-`ExUnit.start()` call site, always
  runs strictly before this invocation's own template build starts — it can never
  observe its own invocation's in-progress build, only a prior invocation's leftover
  state (its own or another's).
- `test/support/tenant_schema_reaper_test.exs` (moduledoc + fixture helpers) — confirms
  the established test shape for this module: `Letflow.DataCase, async: false`, real
  (non-sandboxed) Postgres commits, hand-inserted `tenants`/`tenant_schemas` rows, a
  real `CREATE SCHEMA`/`DROP SCHEMA` where a test needs one. New coverage for this
  design follows the same shape.

---

## 1. Scope boundary

**In scope:** a second, stricter sweep that reclaims a `tenant_schemas` row (and its
parent `tenants` row) when **both** of the following hold:
1. the parent `tenants` row's `display_name` is exactly `"Tenant Template Build
   (throwaway)"` (the literal `test/support/tenant_template.ex` inserts — §0), and
2. a direct, live query against `information_schema.schemata` confirms the row's
   `schema_name` does **not** exist, and the row is old enough (§2.1) not to still be
   a plausible in-progress build.

**Explicitly out of scope, not silently dropped:**

| Not built here | Why | Tracked |
|---|---|---|
| Deleting a throwaway row whose schema is confirmed **present** (old, stuck mid-build with the staging schema never renamed/cleaned — e.g. a hard process kill between `tenant_template.ex` steps 2 and 5, where the schema is never dropped at all) | ISS-0941's own `suggested_fix` scopes this strictly to the absence case ("deletes ... ONLY when the schema is confirmed absent"); dropping a schema that still physically exists is a materially different, higher-blast-radius action (an actual `DROP SCHEMA ... CASCADE`, not just two row deletes) that deserves its own design/decision, not a drive-by addition here | §8 OQ-1 |
| Widening `sweep_orphans/2`'s own `@schema_name_format` regex to also match the staging-build name shape | Would make `sweep_orphans/2` reclaim throwaway rows under its own `min_age_seconds`/reclaim-row path, which calls `DROP SCHEMA IF EXISTS ... CASCADE` unconditionally (no existence check first) — i.e. it would widen `sweep_orphans/2`'s blast radius to a table it wasn't scoped for, and still wouldn't add the `display_name` scoping ISS-0941 explicitly asks for. A new, separately-scoped function is strictly safer | §2.2 |
| Any change to `test/support/tenant_template.ex`'s own build/rescue logic (e.g. making the rescue branch also delete the bookkeeping rows) | Would reduce how often this reaper finds anything to do, but does not retire the need for it — a hard process kill (no Elixir exception, no rescue clause ever runs) produces the identical orphaned-row shape and only a suite-boundary sweep can ever observe that case. Also a behavior change to a module this design was not asked to touch | §8 OQ-2 |
| A `min_age_seconds`-equivalent parameter tuned to a value other than reusing `sweep_orphans/2`'s existing `@default_min_age_seconds` (300s) | Considered in §2.1 and rejected in favor of reuse — no evidence motivates a different number | §2.1 |

---

## 2. Fix mechanism selected: a third public function on `Letflow.TenantSchemaReaper`

### 2.1 Why an age threshold is still included, even though §0's trace shows it may not be strictly load-bearing today

`test/support/tenant_template.ex`'s own step ordering (§0) means a `tenant_schemas` row
matching the throwaway `display_name` is only ever created **after** its target schema
already exists — under the *current* code, "row exists, schema confirmed absent" can
only be reached via a failure path that already dropped the schema (the `build_template!/0`
rescue) or some other explicit drop, never via "about to be created, not yet
committed." Strictly by that trace, the schema-absence check alone would already be
race-free against the one legitimate in-progress-build shape this module's code
produces today.

An age threshold is included anyway, reusing `sweep_orphans/2`'s own
`@default_min_age_seconds` (300s) as this function's own default, for the same reason
`iss064-orphaned-tenant-schemas-fix.md`'s original design took the conservative branch
over a narrower proof: `tenant_template.ex`'s step ordering is an implementation detail
of a different module that this design does not own and is not asked to touch (§1) — a
future rework of that file (e.g. reordering the row insert ahead of `CREATE SCHEMA` for
some unrelated reason, or introducing a retry loop that re-inserts the row before
re-attempting the schema create) could silently reintroduce exactly the race this
reaper must never misfire on, without anyone revisiting this file. A real
`build_template!/0` run (schema create + migration replay + self-check) completes in
low single-digit seconds in every observed run (§0); 300s is generously far above that,
so the threshold costs nothing in practical reclaim latency while remaining a real
guard against a future change to the one file this design deliberately does not modify.
This mirrors ISS-0414 §2.1's own reasoning in the opposite direction (that design
explicitly omits an age threshold because no legitimate `service_catalog` row is ever
held open past an instant); here, a throwaway row *is* held open for the whole build's
duration, which is exactly `sweep_orphans/2`'s own precondition for needing one.

### 2.2 Why a new function on the existing module, not folded into `sweep_orphans/2`

`sweep_orphans/2`'s reclaim path (`reclaim_row/2`) unconditionally runs
`DROP SCHEMA IF EXISTS ... CASCADE` before deleting the bookkeeping rows — correct for
its own rows (whose `schema_name` matches the real-tenant format and is trusted to be
safe to drop if old enough) but wrong here for two independent reasons: (a) this
function's whole premise is that the schema is confirmed **absent** already — issuing
`DROP SCHEMA IF EXISTS` against a name already confirmed absent is harmless but
pointless, and masks the distinction this design's own test coverage needs to prove
(§4); (b) `sweep_orphans/2` has no `display_name` scoping at all — it reclaims by
`schema_name` shape alone, and extending it to also accept the throwaway name shape
would, per §1, widen what it unconditionally drops. A third function,
`sweep_template_build_orphans/2`, is added instead — same module (reusing the private
`concurrent_invocation_present?/2`/`current_application_name/1`/`group_tag_of/1`
helpers verbatim, same rationale ISS-0414 §2.2 already established for why that reuse
is a same-module call, not a new cross-module dependency), its own moduledoc section
(mirroring the existing "ISS-0110"/"ISS-0217"/"ISS-0414" section style), own test file.

### 2.3 Public contract

```
@spec sweep_template_build_orphans(repo :: module(), min_age_seconds :: non_neg_integer()) ::
        {:ok, %{deleted: non_neg_integer(), skipped_schema_present: non_neg_integer()}}
        | {:deferred, :concurrent_invocation}
```

- `repo` defaults to `Letflow.Repo`; `min_age_seconds` defaults to reusing the existing
  `@default_min_age_seconds` module attribute (300) — not a new, second magic number.
- `:deleted` — count of rows that matched the throwaway `display_name`, were older than
  `min_age_seconds`, and whose `schema_name` was confirmed absent from
  `information_schema.schemata` at sweep time; both their `tenant_schemas` row and
  their parent `tenants` row were deleted.
- `:skipped_schema_present` — count of rows that matched the `display_name` and age
  filter but whose `schema_name` was confirmed **present** — left untouched (§1's
  explicit out-of-scope case), logged at `:warning` per row (naming the row id and
  schema name) so this case is visible in suite output rather than silent, distinct
  from `sweep_orphans/2`'s own `skipped_invalid_format` counter (a different module,
  different meaning — this one specifically means "throwaway-named, old enough, but its
  schema still physically exists").
- A row matching the `display_name` filter but **younger** than `min_age_seconds` is
  not counted in either bucket — it is excluded entirely at the query stage (via the
  same `provisioned_at < cutoff` predicate `sweep_orphans/2` already uses), the same way
  `sweep_orphans/2` never counts a too-young real-tenant row in `skipped_invalid_format`
  either. This keeps the two counters meaning exactly "old enough and schema present"
  vs. "old enough, schema absent, reclaimed" — a young row is simply not this sweep's
  concern yet, not a third kind of skip.

### 2.4 Algorithm

1. `Sandbox.mode(repo, :auto)` — identical reason to the other two functions: this runs
   at a point (pre-`ExUnit.start()`, or inside `after_suite/1`) where no test process
   exists.
2. `own_tag = current_application_name(repo)`; if
   `concurrent_invocation_present?(repo, own_tag)` is true, log an info-level deferral
   message (same tone as the other two functions', naming
   `sweep_template_build_orphans/2` explicitly) and return
   `{:deferred, :concurrent_invocation}` **without reading or touching the tables at
   all** — same "defer entirely, never partially guess" posture as the other two
   sweeps, for the identical reason: a concurrently-connected sibling invocation could
   be mid-way through its own `build_template!/0` run right now, and this function has
   no per-row ownership tracking any more than `sweep_orphans/2` does.
3. Otherwise, compute `cutoff` from `min_age_seconds` (same formula as `sweep_orphans/2`:
   `NaiveDateTime.utc_now() |> NaiveDateTime.add(-min_age_seconds, :second)`), and select
   every `tenant_schemas` row joined to its parent `tenants` row where the `tenants`
   row's `display_name` is exactly `"Tenant Template Build (throwaway)"` and the
   `tenant_schemas` row's `provisioned_at` is older than `cutoff`. Project `tenant_schemas.id`,
   `tenant_schemas.tenant_id`, `tenant_schemas.schema_name` per candidate row (same
   three fields `sweep_orphans/2`'s own query already projects, for the same per-row
   log-identification purpose).
4. For each candidate row, issue a direct, live query against
   `information_schema.schemata` for that exact `schema_name` (a targeted
   `WHERE schema_name = $1` lookup, not a re-use of the regex check — the regex check is
   what already lets this exact row shape slip through `sweep_orphans/2` unreclaimed
   (§0); this function's whole reason to exist is to ask Postgres directly instead):
   - **Absent** → delete the `tenant_schemas` row, then delete the `tenants` row (same
     two-statement order `reclaim_row/2` already uses, minus the `DROP SCHEMA` — there
     is nothing to drop, by definition of this branch), incrementing `:deleted`. Each
     row's own deletion is independently wrapped (same per-row try/rescue shape as
     `reclaim_row/2`) so one row's failure never aborts the rest of the sweep for
     remaining candidates — a failed row is simply left for the next boundary sweep to
     retry, logged at `:warning`.
   - **Present** → log at `:warning` (row id, tenant id, schema name — same detail level
     as `sweep_orphans/2`'s "malformed schema_name" line) and increment
     `:skipped_schema_present`; no row is touched.
5. Return `{:ok, %{deleted: d, skipped_schema_present: s}}`.
6. `after` block: `Sandbox.mode(repo, :manual)`, identical to the other two functions,
   run regardless of which branch above executed.

### 2.5 Failure-mode contract (parity with the other two functions)

An outer `rescue` around the whole body: any exception (the candidate-row `SELECT`, the
per-row `information_schema.schemata` lookup, either row's own `DELETE`, either
`Sandbox.mode/2` call, or `current_application_name/1`'s own query) that is **not**
already caught by the per-row try/rescue in step 4's absent branch is caught here,
logged at `:error` with the full formatted exception, and reported back as
`{:ok, %{deleted: 0, skipped_schema_present: 0}}` — never raises to
`test_helper.exs`, identical reasoning to the other two functions: a boundary hook's own
failure must never abort the suite that is about to run its real tests.

---

## 3. `test/test_helper.exs` — exact call-site placement

Reuses the same two boundary points as the other two functions, as a third, separate
statement at each (not folded into a shared wrapper — same reasoning ISS-0414 §3 already
gives: each sweep's own failure-mode contract stays visible at its own call site):

- **Before `ExUnit.start(...)`:** a new line,
  `Letflow.TenantSchemaReaper.sweep_template_build_orphans(Letflow.Repo)`, placed
  immediately after the existing `sweep_orphans()` and
  `sweep_service_catalog_orphans(Letflow.Repo)` calls — i.e. still strictly before
  `ensure_template!/0`'s own call further down this same file (§0's ordering point:
  this guarantees the new sweep can never observe *this* invocation's own in-progress
  build, only a prior invocation's leftover state).
- **Inside the existing `ExUnit.after_suite(fn _stats -> ... end)` callback:** a second
  new line, immediately after that callback's existing two sweep calls.
- A short comment block above the new lines (matching this file's existing
  ISS-0352/REQ-134/ISS-0414 comment style) names ISS-0941 and points at this design doc
  and at `Letflow.TenantSchemaReaper`'s own moduledoc, rather than duplicating the
  rationale inline.

---

## 4. New test file: `test/support/template_build_reaper_test.exs`

Mirrors `tenant_schema_reaper_test.exs`'s established shape (`Letflow.DataCase,
async: false`, real non-sandboxed Postgres commits, hand-inserted `tenants`/
`tenant_schemas` rows, real `CREATE SCHEMA`/`DROP SCHEMA` where a case needs one) —
test-case shapes, not test code:

- **(a) Confirmed-orphaned row IS deleted.** Insert a `tenants` row with
  `display_name: "Tenant Template Build (throwaway)"` and a `tenant_schemas` row
  pointing at a schema name that is never created (or created then dropped) in this
  test's own setup, with `provisioned_at` backdated well past `min_age_seconds` (e.g.
  `min_age_seconds - 600` before now, using the same backdating technique
  `tenant_schema_reaper_test.exs` already uses for its own age-threshold cases). Call
  `sweep_template_build_orphans/2` with a short `min_age_seconds` for test speed.
  Assert `{:ok, %{deleted: 1, skipped_schema_present: 0}}`, and assert both the
  `tenant_schemas` row and the `tenants` row are gone from the database afterward
  (`Repo.get/2` returns `nil` for both).
- **(b) Young row is NOT deleted even though its schema is absent.** Same fixture shape
  as (a), but with `provisioned_at` set to "now" (well inside `min_age_seconds`).
  Assert `{:ok, %{deleted: 0, skipped_schema_present: 0}}` (the row is excluded at the
  query stage, §2.3), and assert both rows still exist afterward. This is the direct
  regression proof for the grace-window protection §2.1 designs in, independent of
  whether today's `tenant_template.ex` code path can currently produce this exact
  shape — the test proves the *reaper's own* behavior under it, which is what matters
  if that code path's ordering ever changes.
- **(b2) Old row whose schema is still PRESENT is NOT deleted.** Insert the same
  throwaway-named row shape as (a) but with a real `CREATE SCHEMA` left in place for its
  `schema_name` (simulating a build stuck mid-way, before the step-5 rename, with the
  schema never dropped — §1's explicit out-of-scope case), `provisioned_at` backdated
  past `min_age_seconds`. Assert `{:ok, %{deleted: 0, skipped_schema_present: 1}}`, both
  rows still exist, and the schema itself still exists (confirming this function never
  issues a `DROP SCHEMA` of its own). Test's own `on_exit/1` drops the leftover schema
  and rows for cleanliness, same convention the existing reaper test file already
  follows for schemas it creates by hand.
- **(c) A real (non-throwaway) tenant row is never touched, regardless of schema
  state.** Insert an ordinary `tenants` row with a normal `display_name` (e.g.
  `"Acme Corp"`, not matching the throwaway literal) and a `tenant_schemas` row whose
  `schema_name` does not exist (simulating an already-dropped real-tenant schema),
  `provisioned_at` backdated past `min_age_seconds`. Assert
  `{:ok, %{deleted: 0, skipped_schema_present: 0}}` and both rows still present
  afterward — the `display_name` filter excludes this row at the query stage entirely,
  it is never evaluated against the `information_schema.schemata` check at all. This is
  the test that most directly guards against ISS-0941's fix accidentally widening scope
  beyond throwaway-build rows.
- **(d) Concurrent invocation present → deferred, no-op.** Same shape as `tenant_schema_reaper_test.exs`'s
  own ISS-0110 coverage (a second real connection opened by the test itself, tagged with
  a distinct `letflow_mixtest_*` `application_name`, no matching `TEST_PARALLEL_GROUP`):
  with a confirmed-orphaned row present (shape (a)'s fixture), assert
  `{:deferred, :concurrent_invocation}` and that the row is still present afterward —
  the deferral must be a true no-op.
- **(e) Same-`TEST_PARALLEL_GROUP` sibling connection present → sweep proceeds.** Mirrors
  that same file's ISS-0217 coverage, adapted to this function: with a confirmed-orphaned
  row present, a sibling-tagged connection does not trigger deferral — assert
  `{:ok, %{deleted: 1, skipped_schema_present: 0}}`.
- **(f) Outer failure is injected → `{:ok, %{deleted: 0, skipped_schema_present: 0}}`,
  never raises.** Same technique `tenant_schema_reaper_test.exs` uses (or an equivalent
  consistent with §2.5) to force the outer `rescue` branch.

This design does not prescribe the exact backdating/connection-simulation helper
functions — TEST-DESIGNER should follow `tenant_schema_reaper_test.exs`'s own existing
helpers (`insert_tenant!/1` and its sibling fixtures) for consistency, extended with a
`display_name` parameter where that file's current helper hardcodes one.

---

## 5. `docs/anti-patterns.md` — one new entry

Add an entry: "A conservative skip-and-warn branch (logged, never acted on) in a
suite-boundary reaper can look like complete coverage of a failure shape while actually
only ever warning about it — `tenant_schema_reaper.ex`'s original 'malformed
schema_name' branch detected exactly ISS-0941's row shape from day one but had no path
that ever deleted it, because the branch's purpose was format validation, not
existence confirmation. A warning that never resolves on its own across repeated
invocations is a sign the branch needs a second, more decisive check (here: a direct
`information_schema.schemata` lookup plus a narrower identity filter), not just a louder
log message." This generalizes past this one module, which is why it is worth recording
rather than folding into this design doc alone.

---

## 6. Files touched (summary)

| File | Change |
|---|---|
| `test/support/tenant_schema_reaper.ex` | New public function `sweep_template_build_orphans/2` (§2.3/§2.4/§2.5); new moduledoc section ("ISS-0941") |
| `test/test_helper.exs` | Two new lines at the existing two boundary points, plus a short attributing comment (§3) |
| `test/support/template_build_reaper_test.exs` | New file, coverage per §4 |
| `docs/anti-patterns.md` | One new entry (§5) |

No `lib/letflow/` file changes. No migration. No change to `test/support/tenant_template.ex`.

---

## 7. Open questions

- **OQ-1:** An old throwaway row whose schema is confirmed **present** (stuck mid-build,
  never renamed/cleaned — §1, §4 case (b2)) is left untouched by this design. If this
  shape is later observed to accumulate in practice (leftover staging schemas consuming
  space on the shared dev container), it would need its own design — likely reusing this
  function's same `display_name` + age filter but issuing a real `DROP SCHEMA ...
  CASCADE` for the present case too — not pre-decided here, since ISS-0941's own evidence
  only showed the absent case actually occurring.
- **OQ-2:** Whether `test/support/tenant_template.ex`'s own `build_template!/0` rescue
  branch should also delete the bookkeeping rows it currently leaves behind (which would
  reduce, but not eliminate — a hard process kill still bypasses it — how often this
  reaper finds anything to reclaim). Out of scope for this design (§1); left for
  REVIEWER/a future issue to weigh in on if considered worth doing independently.
- **OQ-3:** Whether `Letflow.TenantSchemaReaper` should eventually be renamed now that it
  carries three independent per-table/per-shape responsibilities (same question
  ISS-0414's own design left open as its OQ-2). Not decided here, for the same reasons.
