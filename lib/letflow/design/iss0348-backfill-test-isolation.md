# Design: ISS-0348 — `backfill_test.exs` assertion isolation from cross-test DB pollution

## Scope and constraints (explicit)

- **Touches only** `test/letflow/tenant_provisioning/backfill_test.exs`.
- **Does not touch** `lib/letflow/tenant_provisioning/backfill.ex`. `Backfill.run/1`'s
  unscoped `Repo.all(Registration)` whole-table scan is correct, intentional production
  behavior for a fleet-wide backfill tool — it is not the defect and this design does not
  propose changing its signature, its aggregate `{updated, skipped}` return shape, or
  adding any tenant-scoping parameter to it.
- **Does not touch** `test/support/tenant_fixture.ex`, `test/support/data_case.ex`, or
  any `Ecto.Adapters.SQL.Sandbox.mode/2` call anywhere. ISS-0113's investigation_note
  (read in full) already attempted a fix in that shape — a global `:auto` → `:manual`
  restore inside the shared fixture — and reverted it after it broke 12 tests across 3
  distinct mechanisms (double-checkout collisions in `identity_test.exs`, concurrent-lock
  tests in `engine/reconstruction_test.exs` that need real `:auto`-mode concurrent
  connection access, and `promotion_assertion_rerun_test.exs`'s second-mid-test
  provisioning that needs `Ecto.Migrator`'s `:auto` requirement). This design does not
  re-propose that shape, in any of `backfill_test.exs`'s own helpers or elsewhere.
- This design constraint is **satisfied**: every change below is a pure test-assertion
  edit inside `backfill_test.exs`. No production file, no shared fixture file, and no
  Sandbox call is modified.

## Root cause recap (from ISSUE-FIXER's diagnosis, not re-derived here)

`Backfill.run/1` returns one **global aggregate** `{updated, skipped}` tally over every
`Registration` row in the database at call time. Each of the 4 failing tests asserts an
**exact** value for that global tally (e.g. `{updated: 1, skipped: 0}`), which is only
correct if the test's own tenant is the *only* `Registration` row in the table. Under
full serial `mix test`, a leaked `Sandbox` `:auto` mode (ISS-0113, out of scope here) can
let earlier tests' `Registration` rows survive as real committed rows, so the aggregate
Backfill sees includes those extra rows too — inflating `updated` and/or `skipped` by
however many stray rows exist, in an order/seed-dependent way this design cannot predict
or eliminate.

**Key correctness property this design relies on** (from reading `Backfill.run/1`
line-by-line): the `Enum.reduce_while/3` loop visits every `Registration` row exactly
once and increments **either** `updated` **or** `skipped` for it (or halts the whole run
on an unexpected error — not applicable to any of these 4 tests' fixtures). This means
extra, leaked rows can only ever **add** to one or both counters — they can never
subtract from, or invert, the outcome for the specific tenant(s) a test itself
provisioned. That monotonicity is what makes a lower-bound assertion both correct and
resilient: it cannot pass by accident when the test's own tenant's outcome is wrong, and
it cannot fail because of rows the test didn't create.

## General assertion-shape change (applies to all 4 tests)

Replace each `assert {:ok, %{updated: <exact-int>, skipped: <exact-int>}} =
Backfill.run(v2_attrs())` with a two-step shape:

1. **Bind, don't match literals**: `assert {:ok, %{updated: updated, skipped: skipped}} =
   Backfill.run(v2_attrs())` — matches only the result *shape* (`:ok` tuple with a map
   carrying both integer keys), never the values.
2. **Assert a lower bound** on whichever counter(s) the test's own tenant(s) are known to
   contribute to, derived from that test's own setup (never derived by counting rows
   in the DB, and never by filtering `Backfill.run/1`'s input): `assert updated >= N` /
   `assert skipped >= M`, where `N`/`M` is the exact contribution of *this test's own*
   tenant(s) — 0 or 1 for each of the 4 tests below, since each provisions exactly 1 or 2
   tenants of its own.

Each test already carries (or, per test 4 below, should carry) an independent,
tenant_id-scoped verification of the *actual* regression behavior — `Registry.get_type/2`
queried against that test's own `tenant_id`, which only ever reads that one tenant's row
in `event_type_registry`, never a global count. That per-tenant check is what proves
ISS-0332/ISS-0343's real regression coverage; the bound check on the aggregate tally is a
secondary sanity check that the tenant was actually visited and landed in the expected
bucket, not a replacement for it. This preserves the acceptance criterion that the fix
must not weaken BackfillTest's real regression coverage — the per-tenant assertions are
unchanged or strengthened, only the global-count assertions are loosened to bounds.

No new query against `Registration`/`event_type_registry` needs to filter by "rows this
test created" — the existing `Registry.get_type("DEFINITION_PROMOTED", tenant_id)` calls
already are that scoping mechanism (they read one tenant's schema-prefixed row), so nothing
new needs to be introduced there. Only the aggregate-count assertions change shape.

## Per-test changes

### Test 1 — "regression: ISS-0332 -- backfill updates pre-existing tenant to schema_version 2" (AC1, line 135)

- Own tenants: 1 (`tenant_id`, downgraded to v1 at line 130).
- Expected own contribution: this tenant is v1 pre-run and `v2_attrs()` is a strictly
  higher `schema_version` for a `Registration` row whose type does not yet have a v2
  entry for this tenant's schema → `Registry.register_type/2` returns `{:ok, _}` for it →
  contributes `updated: +1`.
- Change line 135 from
  `assert {:ok, %{updated: 1, skipped: 0}} = Backfill.run(v2_attrs())`
  to: bind `{:ok, %{updated: updated, skipped: _skipped}}`, then `assert updated >= 1`.
  No lower bound is meaningful for `skipped` here (this test creates no tenant expected
  to be skipped), so `skipped` is bound but not asserted on.
- The pre-run assertion at lines 132-134 (`schema_version: 1`) and post-run assertion at
  lines 138-139 (`schema_version: 2`), both scoped to this test's own `tenant_id`, are
  unchanged — they remain the authoritative proof this specific tenant was updated.

### Test 2 — "regression: ISS-0343 -- a tenant whose schema vanished mid-sweep is skipped, not a crash of the whole run" (line 272)

- Own tenants: 2 — `healthy_tenant_id` (downgraded to v1, schema intact) and
  `vanished_tenant_id` (schema dropped, `Registration` row intact, via
  `tenant_with_vanished_schema!/1`).
- Expected own contribution: `healthy_tenant_id` → `{:ok, _}` from
  `Registry.register_type/2` → `updated: +1`. `vanished_tenant_id` → its physical schema
  is gone, so `Registry.register_type/2` returns `{:error, :tenant_schema_missing}` →
  `skipped: +1` (per `Backfill.run/1` lines 43-50).
- Change line 272 from
  `assert {:ok, %{updated: 1, skipped: 1}} = Backfill.run(v2_attrs())`
  to: bind `{:ok, %{updated: updated, skipped: skipped}}`, then `assert updated >= 1` and
  `assert skipped >= 1`.
- The existing post-run check at lines 276-277 (`healthy_tenant_id` now `schema_version:
  2`, scoped to that tenant) stays unchanged and remains the authoritative proof the
  healthy tenant was updated despite the other tenant's vanished schema.
- The existing check at line 282 (`vanished_tenant_id`'s `Registration` row still exists)
  proves the row survived the run, but does not by itself prove that row was routed to
  `:skipped` rather than triggering a halt — the test's own docstring purpose (the whole
  run doesn't crash) is already proven by reaching an `{:ok, _}` result at all plus the
  healthy tenant's update. To make the "this specific tenant was skipped, not merely
  ignored" claim resilient and tenant_id-scoped rather than depending on the global
  `skipped` counter alone, add one direct, side-effect-free confirmation: `assert
  {:error, :tenant_schema_missing} = Registry.register_type(v2_attrs(),
  vanished_tenant_id)` called again, standalone, after `Backfill.run/1` — this calls the
  exact same function `Backfill.run/1` calls internally for that tenant, is idempotent
  (the physical schema is still gone, so it errors before any write), and is scoped
  purely to `vanished_tenant_id`. Place this directly after the `skipped >= 1` bound
  assertion, before the existing line 282 check.

### Test 3 — "regression: ISS-0332 -- higher existing schema_version is skipped (schema_version_not_monotonic)" (line 210)

- Own tenants: 1 (`tenant_id`, event type replaced with a v3 row at lines 195-204).
- Expected own contribution: `Registry.register_type/2` enforces monotonicity; v2 attrs
  against an existing v3 row → `{:error, :schema_version_not_monotonic}` → `skipped: +1`.
- Change line 210 from
  `assert {:ok, %{updated: 0, skipped: 1}} = Backfill.run(v2_attrs())`
  to: bind `{:ok, %{updated: _updated, skipped: skipped}}`, then `assert skipped >= 1`.
  No lower bound asserted on `updated` (this test creates no tenant expected to be
  updated).
- The pre-run assertion at lines 206-207 (`schema_version: 3`) and post-run assertion at
  lines 213-214 (`schema_version: 3`, unchanged), both scoped to this test's own
  `tenant_id`, are unchanged and remain the authoritative proof this tenant was skipped
  rather than downgraded or errored.

### Test 4 — "regression: ISS-0332 -- idempotent: already-v2 tenant is skipped, not errored" (AC3, line 176)

- Own tenants: 1 (`tenant_id`, already at v2 via `provisioned_tenant!/1`'s own seeding —
  no downgrade performed by this test).
- Expected own contribution: `v2_attrs()` against an existing, identical v2 row →
  `{:error, :duplicate_event_type_version}` → `skipped: +1`.
- Change line 176 from
  `assert {:ok, %{updated: 0, skipped: 1}} = Backfill.run(v2_attrs())`
  to: bind `{:ok, %{updated: _updated, skipped: skipped}}`, then `assert skipped >= 1`.
  No lower bound asserted on `updated`.
- The pre-run assertion at lines 173-174 (`schema_version: 2`) and post-run assertion at
  lines 179-180 (`schema_version: 2`, unchanged), both scoped to this test's own
  `tenant_id`, are unchanged and remain the authoritative proof this tenant's version was
  never touched (i.e. genuinely skipped, not a no-op update that happened to land on the
  same version).

## Why this does not weaken regression coverage

- ISS-0332's three behaviors under test (backfill applies to a stale tenant; is
  idempotent on an already-current tenant; respects monotonicity against a
  higher-than-target version) are each proven by a `Registry.get_type/2` call scoped to
  that test's own `tenant_id` before and after `Backfill.run/1` — unchanged by this
  design.
- ISS-0343's behavior under test (a vanished-schema tenant doesn't halt the whole sweep)
  is proven by the healthy tenant's own post-run `schema_version: 2` check (unchanged)
  plus the new standalone `Registry.register_type/2` call scoped to the vanished tenant —
  strengthened, not weakened, relative to today's global-count-only proof of "was
  skipped."
- What is removed is only the assumption that no other row exists in `Registration` at
  call time — an assumption `Backfill.run/1`'s real, documented, unscoped-by-design
  contract never makes and callers must not make either.

## Open questions

- None. The 4 failing assertions and their replacement shapes are fully enumerated above;
  no additional call sites in `backfill_test.exs` assert exact global `Backfill.run/1`
  counts (verified by reading the full file — only these 4 tests call `Backfill.run/1`
  at all; test 2/AC2 already uses `{:ok, _}` and needs no change).
