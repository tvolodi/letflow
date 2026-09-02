# Design: ISS-0414 — suite-wide safety net against leftover `service_catalog` rows

**Issue:** `docs/issues/ISS-0414.yaml`, discovered by ISSUE-FIXER during
`WF03-ISS0410-20260902`'s diagnosis of ISS-0409/ISS-0410 (both closed `no_defect`).
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF03-ISS0414-20260902`, WF-03 Step 1

**Change class:** one new public function + moduledoc addendum on an existing
test-support module (`test/support/tenant_schema_reaper.ex`), a two-line addition to
`test/test_helper.exs`, and one new test file exercising the new function directly.
**Zero production (`lib/letflow/`) files change.** No Ecto schema/migration change, no
new supervised process, no change to `Letflow.ServiceCatalog`'s public API or to any
existing test file (including the ISS-0409 hardening already merged in
`test/letflow/service_catalog_test.exs`, which this design leaves untouched).

---

## 0. Sources read in full for this design

- `docs/issues/ISS-0414.yaml`, `docs/issues/ISS-0409.yaml`, `docs/issues/ISS-0410.yaml`
  (all full) — the root cause this design mitigates: two genuinely stale, one-day-old
  `service_catalog` rows (`scope: global`) orphaned by an interrupted `mix test`
  invocation that never reached its `on_exit/1` teardown, discovered directly in the
  live `letflow_test` database. `service_catalog` is confirmed (moduledoc,
  `lib/letflow/service_catalog.ex`) to be this codebase's **only** table with no
  per-tenant-schema `DROP SCHEMA ... CASCADE` fallback, so `on_exit/1` — which ExUnit
  skips entirely on a killed/timed-out test process — is this table's *only* current
  cleanup mechanism. ISS-0410's own `no_defect_evidence` explicitly scopes ISS-0414 as
  "the residual risk... a follow-up issue is filed separately for": no future
  interrupted run can be proven not to leave new orphans behind.
- `test/letflow/service_catalog_test.exs` full moduledoc and the "REQ-192 list_all/1
  pagination correctness" `describe` block (`ISS-0409`'s hardening: setup-time
  `Repo.delete_all(Entry)` establishing an explicit empty-table precondition, plus
  `on_exit/1` cleanup via the file's own `cleanup_entry!/1` helper) — confirmed this is
  a **scoped, single-file** instance of exactly ISS-0414's ask, not a suite-wide
  mechanism; it protects this one `describe` block's own exact-count assertion, nothing
  else that might assume the table's contents.
- `test/test_helper.exs` (full, 26 lines) — the project's existing pre-suite/post-suite
  hook point: `Letflow.TenantSchemaReaper.sweep_orphans()` runs once before
  `ExUnit.start()` and once via `ExUnit.after_suite/1`. This **is** the established
  "pre-suite check/cleanup" convention ISS-0414's option 1 asks whether exists — it
  does, so this design reuses it rather than inventing a second, parallel hook (a
  second `ExUnit.after_suite/1` call composes fine; Elixir raises no error registering
  more than one, but a *second, independent mechanism* solving the same "suite boundary
  hygiene" problem for a sibling table would be an unforced duplication of exactly the
  reasoning below, not an independent design choice).
- `test/support/tenant_schema_reaper.ex` (full, 244 lines) and
  `lib/letflow/design/iss064-orphaned-tenant-schemas-fix.md` (full) — the load-bearing
  precedent. Its moduledoc's own §"ISS-0110" and §"ISS-0217" sections establish two
  facts this design depends on directly:
  1. **The suite-boundary argument.** "Before `ExUnit.start()` runs" and "after every
     test in this invocation has finished" (`ExUnit.after_suite/1`) are the two points
     in *any* `mix test` invocation where "currently active, legitimately, for this
     invocation" is structurally always the empty set — no per-row ownership tracking
     needed, unlike a live reaper (e.g. `Letflow.SandboxPool`'s owner-monitor) would
     need. `service_catalog` has an even simpler version of this argument than
     `tenant_schemas` — see §2.1.
  2. **The concurrent-invocation hazard is real and already solved once.** Two
     `mix test` invocations can share one physical Postgres server even when
     `MIX_TEST_PARTITION`-based per-partition databases (`config/test.exs`:
     `database: "letflow_test#{System.get_env("MIX_TEST_PARTITION")}"`) keep their
     *table data* isolated from each other, because `pg_stat_activity` (what the
     existing concurrency guard queries) is server-wide, not database-scoped. Two
     independent full-suite invocations that both omit `MIX_TEST_PARTITION` (e.g. two
     git worktrees, or a manually-run `mix test` alongside `scripts/test_parallel.sh`)
     land on the **same** default `letflow_test` database and hence the **same**
     `service_catalog` table — this is precisely the shape ISS-0110 fixed for
     `tenant_schemas`, and it applies unchanged to `service_catalog`, since both tables
     live in that same default/public schema database. `scripts/test_parallel.sh`'s
     own N sibling partitions are a *false*-positive variant of this same check
     (ISS-0217): they are visible to each other in `pg_stat_activity` (server-wide) even
     though each partition's `service_catalog` rows already live in a *different*
     database (`letflow_test1`, `letflow_test2`, ...) and can never collide on data —
     but without the existing `TEST_PARALLEL_GROUP`-tag exclusion, a sweep would defer
     on every `test_parallel.sh` run, unconditionally, defeating its own purpose.
     `config/test.exs`'s `parameters: [application_name: "letflow_mixtest_#{System.pid()}" <>
     ..."_grp#{group}"...]` tag and `tenant_schema_reaper.ex`'s private
     `concurrent_invocation_present?/2` / `current_application_name/1` /
     `group_tag_of/1` functions already implement exactly the check this design needs,
     verbatim — see §2.2 for why this design reuses them by extending the same module
     rather than duplicating this logic in a new one.
  3. Its own `try/rescue/after` failure-mode contract (never raises to the caller;
     `Sandbox.mode(repo, :auto)` before, `Sandbox.mode(repo, :manual)` in an `after`
     block; an outer failure logs and reports the same shape as an empty sweep) — this
     design's new function follows the identical contract, since the same reasons
     (a suite-boundary hook whose own failure must not abort the whole suite) apply
     unchanged.
- `lib/letflow/service_catalog.ex` (full moduledoc + all five public functions) —
  confirms `service_catalog` is written **only** through `register/1` (an
  `Ecto.Changeset`-validated insert) and read/updated/deleted through
  `get_for_tenant/2`, `list_for_tenant/2`, `list_all/1`, `update_scope/2`, `delete/1`;
  no raw/bypassing insert path exists anywhere in `lib/letflow/`.
- `grep -rln "setup_all" test/ | xargs grep -l "ServiceCatalog\|service_catalog"` and
  `grep -rl "ServiceCatalog" test/` (both run for this design) — **zero** matches for
  `setup_all`; every one of the three test files that touch `Letflow.ServiceCatalog`
  (`service_catalog_test.exs`, `admin_services_test.exs`,
  `definitions/service_scope_validator_test.exs`) creates and (per each file's own
  `on_exit/1`) tears down its own rows per-test, never per-module or per-suite. No test
  fixture anywhere is designed to outlive its own test.
- `grep -rn "service_catalog\|ServiceCatalog" lib/mix/tasks/letflow.seed.ex priv/repo/seeds.exs`
  — **zero** matches. `service_catalog` is never seeded by any Mix task or seed script.
  Its only non-test writers are `Letflow.ServiceCatalog.register/1` calls made through
  `Letflow.Routers.AdminServices`'s `POST /admin/services` route (a real `PLATFORM_ADMIN`
  HTTP call against a real database) — i.e., in `dev`/`prod`, real operator-registered
  services are expected, persistent, legitimate rows. **This design's mechanism must
  never run against `dev`/`prod`** — see §2.3 for why the chosen placement already
  guarantees that structurally, not just by convention.
- `lib/mix/tasks/letflow.check.test.ex` (full, 163 lines) — confirms this task's own
  contract is a thin wrapper that shells out to plain `mix test` (which itself already
  loads `test/test_helper.exs`) plus a separate warnings-substring gate; it has no
  independent pre/post-suite hook mechanism of its own to extend, and adding one here
  would (a) run this sweep only under `mix letflow.check.test`'s own invocation, never
  under a developer's plain `mix test` or `scripts/test_parallel.sh`, defeating the
  point, and (b) duplicate `test_helper.exs`'s already-suite-wide reach. Confirms
  `test/test_helper.exs` (ISS-0414's option 1), not this Mix task (option 2), is the
  correct placement — see §2.3.
- `scripts/test_parallel.sh` (full) — confirms each of its N partitions is an
  independent `mix test --partitions N` process that loads `test/test_helper.exs`
  itself (nothing special about how the helper is invoked under partitioning); the
  per-partition-database isolation this script relies on (`MIX_TEST_PARTITION`) is
  exactly what §0 point 2 above already accounts for via the existing
  `TEST_PARALLEL_GROUP` tag exclusion.
- `docs/guides/test_developer_guide.md` — grepped for `on_exit`/`global`/
  `service_catalog`/`hygiene`/`orphan`: **zero** matches. No existing documented
  directive covers this table's hygiene; §6 below adds one, following the same
  guide-update discipline `iss064-orphaned-tenant-schemas-fix.md` itself established.
- `docs/anti-patterns.md` — grepped for `on_exit`/`orphan`/`reaper`: matches are the
  existing `TenantSchemaReaper`-adjacent entries (e.g. "A self-heal wired into `setup`
  that is not total over the states it can encounter") but none is specific to a
  *second* global table needing the same treatment; no existing entry directly
  constrains this design.

---

## 1. Scope boundary

**In scope:** guarantee that a `service_catalog` row left behind by any interrupted or
crashed `mix test` invocation cannot silently persist into and corrupt a *later*
`mix test` invocation's assumptions about the table's contents — for every invocation
shape this project actually uses (plain `mix test`, `mix test <path>`,
`scripts/test_parallel.sh`, `mix letflow.check.test`), without weakening or duplicating
the ISS-0409 per-file hardening already shipped.

**Explicitly out of scope, not silently dropped:**

| Not built here | Why | Where it's tracked |
|---|---|---|
| A same-invocation, mid-run guard (e.g. re-checking emptiness before every `describe` block that assumes an empty table) | Suite-boundary sweeps (§2) cannot heal a leak created and observed *within* the same invocation, before that invocation's own end-of-suite sweep runs — same structural limitation `iss064-...md`'s own OQ-1 already names for `tenant_schemas`. ISS-0409's per-file `setup`-time `Repo.delete_all(Entry)` hardening is this codebase's answer to that narrower problem for the one file that needs an exact-count assertion; this design does not ask every other `service_catalog`-touching file to add the same per-file guard, since none of the others make exact-count/exact-membership assertions fragile to a stray row (confirmed by re-reading `admin_services_test.exs` and `service_scope_validator_test.exs`'s own assertions — both check "my own row is/isn't in the result" or "my own row has field X", never "the result has exactly N rows") | §8 OQ-1 |
| A tenant/scope filter added to `list_all/1` or `list_for_tenant/2` | Already investigated and explicitly rejected by ISSUE-FIXER in ISS-0410's `no_defect_evidence` — `list_all/1`'s unfiltered behavior is deliberate, REQ-192-specified, REVIEWER-signed-off; not this design's to re-litigate | ISS-0410.yaml |
| Renaming `Letflow.TenantSchemaReaper` to a more generic name (e.g. `Letflow.SuiteHygieneReaper`) now that it covers two unrelated tables | Considered (§2.2) and rejected for this change: renaming touches the module's own test file (`tenant_schema_reaper_test.exs`), every doc reference to the literal name (`test/test_helper.exs`'s own inline comments, this project's own `docs/issues/ISS-0064.yaml`/`ISS-0110`/`ISS-0217` historical record, which name the module verbatim), for a purely cosmetic gain — the module's *moduledoc* already documents each table's reaper as its own clearly-labeled section (see §2.2), which is sufficient. Left as an explicit, named alternative, not a silent omission | §8 OQ-2 |
| A `mix letflow.check.test`-level gate (ISS-0414's option 2) | Investigated in §0 and rejected — `test/test_helper.exs` already reaches every invocation shape this project uses; a `check.test`-only gate would reach strictly fewer of them | §2.3 |
| Any change to `Letflow.ServiceCatalog`, `Letflow.ServiceCatalog.Entry`, or the `service_catalog` migration | Out of this design's problem — the exposure is purely test-invocation-boundary hygiene, not a production code defect | (n/a — no production file listed in §7) |

---

## 2. Fix mechanism selected: extend `Letflow.TenantSchemaReaper` with a second, independent sweep function

### 2.1 Why the suite-boundary argument transfers cleanly, and is actually simpler here

`iss064-...md` §2.2's argument for `tenant_schemas` ("before `ExUnit.start()` and after
`ExUnit.after_suite/1`, nothing legitimate is ever active, for THIS invocation") applies
to `service_catalog` with one simplification: `tenant_schemas` rows are *held for a
test's entire duration* (a schema is provisioned once and used throughout), so ISS-0064
also needed an age threshold (`min_age_seconds`) as a second line of defense against
sweeping something a concurrently-connected invocation is still using mid-test, at the
moment a sibling invocation's own pre-suite sweep runs. `service_catalog` rows carry no
such long-held-for-a-whole-test-duration semantics on their own — every test that
creates one deletes it in the same test's `on_exit/1`, so there is no scenario where a
*legitimately in-progress* row needs a grace-period buffer against a same-second sweep
the way an in-progress tenant schema does. The concurrent-invocation check (§2.2) alone
is therefore sufficient here; no `min_age_seconds`-equivalent parameter is needed for
`service_catalog` — this is a deliberate, narrower design than `tenant_schemas`'s, not
an oversight (recorded so CODE-DESIGN-VALIDATOR doesn't mistake the omission for a gap
copied incompletely from the precedent).

Restated precisely: at the two boundary points (before `ExUnit.start()`, and
`ExUnit.after_suite/1`), *for this invocation*, the `service_catalog` table's correct
content is always exactly empty **once concurrent-invocation safety is confirmed** —
identical in shape to `tenant_schemas`'s own argument, minus the age buffer.

### 2.2 Why this is a new function on the *existing* `TenantSchemaReaper` module, not a new module

Two options were considered:

1. **New sibling module** (e.g. `test/support/service_catalog_reaper.ex`), mirroring
   `TenantSchemaReaper`'s shape exactly, including its own private copy of
   `concurrent_invocation_present?/2` / `current_application_name/1` / `group_tag_of/1`.
2. **A second public function on `Letflow.TenantSchemaReaper` itself**, reusing those
   three private helpers directly (same module, same file — no duplication at all,
   since they are already private and this is a same-module call, not a cross-module
   one).

Option 2 is chosen. `iss064-...md` itself already established, for a *different* pair
of private helpers (`@schema_name_format`), that duplicating a private constant across
two independent test-support modules is acceptable **only** when no shared owning
module exists to put it on instead (its own moduledoc: "literal duplicate, not a shared
reference... since that module attribute is private and this is a test-only module
living outside `lib/letflow/`" — i.e., duplication was the fallback, not the preferred
outcome, because the two things it was choosing between were `TenantProvisioning.Registration`
(a `lib/letflow/` production module) and a `test/support/` module, which cannot depend
on each other in that direction without inventing a shared third module). That
constraint does not apply here: both the existing concurrency-check code and this
design's new function already live in the *same* `test/support/` module, so reuse is a
same-file function call, not a new cross-module dependency — strictly less machinery
than either introducing a shared third module or duplicating the ~30-line
`pg_stat_activity` check into a second file. The module's moduledoc gains a new
top-level section (mirroring its existing "ISS-0064"/"ISS-0110"/"ISS-0217" style)
documenting this second responsibility explicitly, so a future reader sees both
reaper roles named, not one undocumented addition bolted onto a single-purpose-looking
module. The module's file name and its own regression test file
(`tenant_schema_reaper_test.exs`) are unchanged in this design — the new function gets
its own new test file (§4), not an edit folded into the existing one, keeping the two
regression suites independently attributable to their own issue numbers exactly as
`iss064-...md`'s own test file is to ISS-0064.

### 2.3 Why `test/test_helper.exs`, never `mix letflow.check.test`, and why this can never touch `dev`/`prod`

`test/test_helper.exs` is loaded once per `mix test` (or `mix test <path>`, or one
`scripts/test_parallel.sh` partition's own `mix test --partitions N`) invocation,
**always** under `MIX_ENV=test` — `mix test` itself hardcodes `MIX_ENV=test` before
loading any config, so `Letflow.Repo`'s connection (via `config/test.exs`, never
`config/dev.exs`/`config/prod.exs`) is structurally guaranteed to point at a
`letflow_test*` database, never a `dev`/`prod` one, regardless of which of the four
invocation shapes above is used. `mix letflow.check.test` (option 2) only reaches the
narrower case of being invoked *as* `mix letflow.check.test` specifically — a plain
developer `mix test` or a bare `scripts/test_parallel.sh` run (confirmed in §0: neither
shells through `letflow.check.test.ex`) would never hit that gate at all, leaving the
exact interrupted-run scenario ISS-0414 is about (a crashed ad hoc `mix test`) uncovered.
Piggybacking on the same call site the ISS-0064 precedent already uses maximizes
coverage with zero new invocation-shape-specific wiring.

### 2.4 What the new function does, precisely

New public function on `Letflow.TenantSchemaReaper`:

```
@spec sweep_service_catalog_orphans(repo :: module()) ::
        {:ok, %{deleted: non_neg_integer()}} | {:deferred, :concurrent_invocation}
```

Algorithm (mirrors `sweep_orphans/2`'s own `try/rescue/after` contract exactly, see
§2.5 for the exact failure-mode parity):

1. `Sandbox.mode(repo, :auto)` — same reason `sweep_orphans/2` needs it: this runs
   outside any test process's own sandboxed transaction, at a point where no test
   process exists yet (pre-suite) or every test process has already exited
   (post-suite).
2. Compute `own_tag = current_application_name(repo)` and call the *existing*
   `concurrent_invocation_present?(repo, own_tag)` private helper, unchanged, reused
   verbatim (§2.2) — this is the single source of truth for "is it currently safe to
   sweep at all," shared with `sweep_orphans/2`, so the two functions' concurrency
   judgment can never disagree with each other about the same invocation.
3. If a concurrent, non-sibling invocation is present: log an info-level message (same
   tone/wording pattern as `sweep_orphans/2`'s own deferral log, naming
   `service_catalog` explicitly so the two log lines are distinguishable in combined
   output) and return `{:deferred, :concurrent_invocation}` **without touching the
   table at all** — same "defer entirely, never guess which rows are safe" posture as
   `sweep_orphans/2`, restated for this simpler (no per-row ownership, no age
   threshold) case: there is nothing here to partially trust either.
4. Otherwise, run `SELECT service_id, scope FROM service_catalog` first (never a bare
   `DELETE` with no prior read) so the log output in step 5 can name exactly what was
   removed — mirrors `sweep_orphans/2`'s own "read first, log identifying detail per
   row" idiom (its own `[id, tenant_id, schema_name]` row shape) rather than a silent
   bulk delete.
5. If the read returns zero rows: return `{:ok, %{deleted: 0}}`, no log line beyond
   normal debug-level noise (an empty table is the expected, unremarkable steady
   state — logging every clean sweep at `:warning`/`:info` would make the genuinely
   interesting case, a nonzero find, harder to spot in routine output).
6. If the read returns one or more rows: log a `:warning` naming every found
   `service_id`/`scope` pair explicitly (unlike `sweep_orphans/2`'s `:warning`, which
   is reserved for a malformed-`schema_name` skip case — here, finding ANY row at this
   boundary point is itself the anomaly worth a `:warning`, since §2.1 established the
   correct content is always empty), then `DELETE FROM service_catalog` (no `WHERE`
   clause — no age/ownership filter applies per §2.1) and return
   `{:ok, %{deleted: n}}`.
7. `after` block: `Sandbox.mode(repo, :manual)` — same as `sweep_orphans/2`, restoring
   the sandbox mode ExUnit's own test-process setup expects to find, regardless of
   which branch above was taken.

### 2.5 Failure-mode contract (parity with `sweep_orphans/2`)

An outer `rescue` around the whole body (steps 1-6): any exception (the `SELECT`/`DELETE`
itself raising, `Sandbox.mode/2` raising, `current_application_name/1`'s
`SHOW application_name` query raising) is caught, logged at `:error` with the full
formatted exception, and reported back as `{:ok, %{deleted: 0}}` — **never** raises out
to `test_helper.exs`, for the identical reason `sweep_orphans/2` doesn't: a boundary
hook whose own failure aborts the entire suite (rather than letting the suite's real
tests run and report their own real pass/fail) is strictly worse than a sweep that
silently no-ops once and lets the *next* invocation's boundary sweep retry. This also
means `test_helper.exs`'s call site does not need (and must not add) its own
`try/rescue` around this call — the contract is "never raises," full stop, same as the
existing `sweep_orphans/2` call already relies on implicitly today.

---

## 3. `test/test_helper.exs` — exact call-site placement

Two call sites, mirroring the existing `TenantSchemaReaper.sweep_orphans()` calls
exactly in kind (same file, same two boundary points) but as their own separate
statements — not folded into a shared "run both reapers" wrapper function, since (a)
that wrapper would itself be new code with no independent test coverage of its own
composition, and (b) keeping them as two plain, adjacent calls preserves each one's
own independent failure-mode contract (§2.5) visibly at the call site rather than
hiding it behind a third layer:

- **Before `ExUnit.start(...)`:** a new line,
  `Letflow.TenantSchemaReaper.sweep_service_catalog_orphans(Letflow.Repo)`, placed
  immediately after the existing `Letflow.TenantSchemaReaper.sweep_orphans()` call (same
  ordering rationale as that call's own placement: before any test process exists).
- **Inside the existing `ExUnit.after_suite(fn _stats -> ... end)` callback:** a second
  new line inside the *same* anonymous function, immediately after the existing
  `Letflow.TenantSchemaReaper.sweep_orphans()` call — not a second
  `ExUnit.after_suite/1` registration, since `ExUnit.after_suite/1` accepts one callback
  per `after_suite` call and this project's existing convention (one callback, multiple
  statements inside it) is simplest to extend in place.

`repo` is passed explicitly (`Letflow.Repo`) at both call sites even though it's the
new function's own default-able argument slot, matching this file's existing
`sweep_orphans()` call style of relying on argument defaults *only* where nothing about
the call site has an opinion — here, being explicit costs nothing and makes the
call site self-documenting about which repo is swept, an intentional style choice, not
a requirement CODE-DESIGN-VALIDATOR should read as ambiguous if ELIXIR-DEV instead
calls the zero-arg default form; either is acceptable, this design has no preference
between them.

A short comment block (mirroring the existing ISS-0352/REQ-134 comment style already in
this file) is added above the new lines, naming ISS-0414 and pointing at this design
doc and at `Letflow.TenantSchemaReaper`'s own moduledoc for the full rationale — not
duplicating that rationale inline.

---

## 4. New test file: `test/support/service_catalog_reaper_test.exs`

Mirrors `tenant_schema_reaper_test.exs`'s own structure and DIRECTIVE-T1 (`Letflow.DataCase`,
real Postgres, `async: false`, `Sandbox.mode(Letflow.Repo, :auto)` — the module under
test itself switches modes internally, same reason as the existing test file's own
moduledoc states) for exactly this new function, as its own file rather than an edit
folded into the existing one (§2.2), so TEST-DESIGNER's coverage is attributable to
ISS-0414 independently of ISS-0064's own regression file:

Required coverage (test-case shapes, not test code):

- Empty table, no concurrent invocation → `{:ok, %{deleted: 0}}`, table still empty
  after the call.
- One or more hand-inserted `service_catalog` rows present (both `scope: :global` and
  `scope: :tenant` rows, to confirm no scope-based filtering — §2.1's "no `WHERE`
  clause" is unconditional), no concurrent invocation → `{:ok, %{deleted: n}}` matching
  the row count, table verified empty afterward.
- A genuinely present *other* `letflow_mixtest_*`-tagged connection (no matching
  `TEST_PARALLEL_GROUP`), hand-inserted rows present → `{:deferred, :concurrent_invocation}`,
  and the rows are still present afterward (the deferral must be a true no-op, not a
  partial sweep) — mirrors `tenant_schema_reaper_test.exs`'s own equivalent
  ISS-0110-coverage test, adapted to a second real connection opened by the test itself
  (same technique that file already uses to simulate a sibling invocation).
- A same-`TEST_PARALLEL_GROUP`-tagged sibling connection present, hand-inserted rows
  present → sweep proceeds (not deferred), matching ISS-0217's exclusion behavior —
  mirrors that file's own equivalent test.
- An outer failure is injected (the same technique `tenant_schema_reaper_test.exs`
  already uses, if any, to force `sweep_orphans/2`'s own `rescue` branch; otherwise, a
  new equivalent technique consistent with this design's §2.5 contract) →
  `{:ok, %{deleted: 0}}`, never a raised exception out of the call.

This design does **not** prescribe the exact hand-insertion helper (e.g. a raw
`Repo.query!/insert!` against `Letflow.ServiceCatalog.Entry` vs. calling
`Letflow.ServiceCatalog.register/1` directly) — TEST-DESIGNER should follow
`service_catalog_test.exs`'s own existing `insert_tenant!/1` +
`Entry.insert_changeset/2` fixture pattern for consistency with that file, since both
now exercise the same table.

---

## 5. `docs/anti-patterns.md` — no new entry required

Considered and rejected: this design's own root-cause narrative ("`on_exit/1` is
skipped entirely on a killed/timed-out process, and a table with no schema-level
fallback has no other safety net") is already the *general* lesson
`iss064-orphaned-tenant-schemas-fix.md` §9/its own anti-patterns entry (if any) or this
project's own established convention captures for `tenant_schemas`; ISS-0414 is that
same lesson recurring on a second table, not a new lesson. §6 (guide update) is the
right place to record "this table specifically now also has a reaper," not a second
anti-patterns entry duplicating the first one's point.

---

## 6. `docs/guides/test_developer_guide.md` — one new note

Add a short note (placement: wherever this guide documents `Letflow.DataCase`/global
vs. tenant-scoped table conventions, or a new short subsection if no such section
exists — ELIXIR-DEV should locate the most natural existing section rather than this
design prescribing a line number) stating: `service_catalog` is this codebase's only
table with no tenant-schema cleanup fallback; every test file that writes to it must
still clean up its own rows in `on_exit/1` (this is *not* superseded by the new
suite-boundary reaper, which is a safety net for a *crashed* run, not a substitute for
correct per-test cleanup in a normally-completing one — restated from §2.1: the reaper
finding any row at all is itself logged as an anomaly, meaning a test relying on the
reaper instead of its own `on_exit/1` would trigger that warning on every normal run).

---

## 7. Files touched (summary)

| File | Change |
|---|---|
| `test/support/tenant_schema_reaper.ex` | New public function `sweep_service_catalog_orphans/1` (§2.4/§2.5); new moduledoc section documenting this second responsibility (§2.2) |
| `test/test_helper.exs` | Two new lines calling the new function, at the same two existing boundary points, plus a short attributing comment (§3) |
| `test/support/service_catalog_reaper_test.exs` | New file, coverage per §4 |
| `docs/guides/test_developer_guide.md` | One new note (§6) |

No `lib/letflow/` file changes. No migration.

---

## 8. Open questions

- **OQ-1:** A same-invocation, mid-run leak (created and observed before this
  invocation's own end-of-suite sweep runs) is not healed by this design — same
  structural gap `iss064-...md` names for `tenant_schemas` (its own OQ-1). If this
  recurs in practice as a *third* incident, the fix would need either (a) every
  exact-count-assuming test file adopting ISS-0409's own per-file `setup`-time
  `Repo.delete_all(Entry)` pattern proactively, or (b) some form of test ordering
  guarantee — neither designed here; left for a future issue if warranted, not
  pre-decided now.
- **OQ-2:** Whether `Letflow.TenantSchemaReaper`'s name should eventually be
  generalized (e.g. `Letflow.SuiteHygieneReaper` with per-resource sub-functions) now
  that it covers two structurally-unrelated tables. §2.2 rejects doing this rename as
  *part of* this change; left open for REVIEWER to weigh in on during implementation
  review if the two-responsibility shape reads as a code smell in practice, rather than
  this design pre-deciding a rename that touches multiple files' literal name
  references for no behavioral gain.
- **OQ-3:** This design's `service_catalog` sweep has no `min_age_seconds`-equivalent
  parameter (§2.1) — if a future, currently-unforeseen legitimate use case ever holds a
  `service_catalog` row open across a test-process boundary for longer than an
  instant (none does today, per §0's `setup_all` grep), this design's "any row found at
  a boundary is an anomaly" posture (§2.4 step 6) would need revisiting. Not designed
  for now, since no such use case exists to design against.
