# Design: ISS-0064 — orphaned `tenant_schemas` rows from the direct-provisioning +
# on_exit-only test pattern (no reaper)

**Issue:** `docs/issues/ISS-0064.yaml`, diagnosed by ISSUE-FIXER (summary reproduced in
this run's handoff prompt, read in full for this design).
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF03-ISS0064-20260819`, WF-03 Step 2

**Change class:** one new test-support module + a four-line addition to
`test/test_helper.exs`. **Zero production (`lib/letflow/`) files change. Zero existing
test files change.** No Ecto schema change, no migration, no new supervised process, no
`@spec` change to any existing public function.

**REWORK NOTICE (2026-08-19, rework iteration 1):** CODE-DESIGN-VALIDATOR returned FAIL
on two items, both confirmed against actual code, not nitpicks: (A) §3.1's "never raises"
claim was inconsistent with §3.2's algorithm, which only wrapped the per-row DROP/DELETE
in `try/rescue` — the bulk `SELECT` and the two `Sandbox.mode/2` calls had no stated
error handling. (B) §2.3's concurrent-invocation safety argument covered only the
`MIX_TEST_PARTITION`-partitioned case and never addressed the actual default
(`config/test.exs` falls back to plain `letflow_test` when `MIX_TEST_PARTITION` is
unset) — in that shared-DB case, one invocation's sweep could `DROP SCHEMA ... CASCADE`
a schema a concurrently-running, unpartitioned invocation is still actively using. Both
are fixed below: §2.3 now documents that `MIX_TEST_PARTITION` is **not** mechanically
enforced anywhere in this project (confirmed by re-checking CI config and
`docs/issues/ISS-0015.yaml`, §0's new bullet) and adds a real mitigation (an
age-threshold filter, §2.3/§3.2/§4 INV-R-5) instead of relying on partitioning discipline
alone; §3.1/§3.2 now specify an outer `try/rescue/after` around the whole sweep body,
with a precise, consistent failure-mode contract. Sections touched by this rework: §0
(one new bullet), §2.3 (rewritten), §3.1 (spec + contract text), §3.2 (restructured
algorithm), §4 (new INV-R-5, INV-R-2 clarified), §5 (unchanged — still just three lines,
now calling the two-argument form with its default), §8 (one new open question, OQ-4),
§10 (two rows added). §§1, §3.3, §6, §7, §9 are unchanged by this rework.

---

## 0. Sources read in full for this design

- ISSUE-FIXER's diagnosis (this run's handoff prompt) — root cause: the
  `DropLegacyPublicIdentityTables` guard migration
  (`priv/repo/migrations/20260819000004_drop_legacy_public_identity_tables.exs`) loops
  over every row in `public.tenant_schemas` unscoped; orphaned `tenant_*` rows
  accumulate there because the direct `TenantProvisioning.provision_tenant_schema/1` +
  raw `Repo.insert` + manual `on_exit/1` cleanup pattern used by 30+ test files has no
  reaper for a test process that crashes, times out, or is killed before its `on_exit/1`
  runs — unlike `Letflow.SandboxPool`'s own pooled `sandbox_*` schemas, which ISS-0048
  already gave an owner-monitor reaper.
- `lib/letflow/sandbox_pool.ex` (full, 326 lines, current shipped state) — `claim/2`'s
  owner-monitor mechanism, `handle_info({:DOWN, ...})`'s reclaim logic, `provision_sandbox/0`
  and `drop_schema/1`'s "best-effort, swallow-its-own-failure" cleanup idiom. Read in
  full per this run's explicit instruction to reuse/extend this pattern where it fits —
  §2 below explains precisely where it fits and where it doesn't, rather than copying it
  wholesale.
- `lib/letflow/design/iss-0048-sandbox-pool-owner-crash-reclaim.md` (full) — the prior,
  analogous fix. §2.2 of that document rejected a "periodic reaper" for `SandboxPool`
  specifically because a reaper there would need to re-derive "which schemas are
  currently active" from something equivalent to `SandboxPool`'s own in-memory `active`
  map — i.e., a live-tracking problem. §2.2 below shows this project's `tenant_schemas`
  leak does **not** have that problem, which is why a reaper is the right mechanism here
  even though it was the wrong one for `SandboxPool`.
- `lib/letflow/design/iss-0050-drop-legacy-guard-missing-table.md` (full) — the guard's
  own prior fix (tolerate a missing per-tenant table); confirms the guard fix and this
  fix are deliberately independent (ISS-0050's own file: "ISS-0048 (orphaned schema
  accumulation) is not fixed here and stays open as its own issue" — ISS-0064 is that
  still-open issue, now traced to its real leak path).
- `test/letflow/identity_migration_test.exs` lines 1-160 — `provisioned_tenant!/0`'s
  exact provision/`on_exit` shape (§1.1 below), and the file's own moduledoc explaining
  why this pattern (`Sandbox.mode(Repo, :auto)` + manual `on_exit/1`) exists at all
  (`Ecto.Migrator` cannot run under the sandbox's single shared connection).
- `test/letflow/tenant_provisioning_test.exs`, `test/letflow/identity_test.exs`,
  `test/letflow/role_registry_test.exs`, `test/letflow/engine_test.exs` — grepped and
  spot-read for their own local variants of the same pattern, confirming: (a) all of
  them insert a `Tenant` row, call `TenantProvisioning.provision_tenant_schema/1`, and
  register a manual `on_exit/1` that does `DROP SCHEMA IF EXISTS ... CASCADE` +
  `DELETE FROM tenant_schemas` + `DELETE FROM tenants`; (b) `role_registry_test.exs`'s
  moduledoc (lines 52-67) independently documents the exact reason `on_exit/1`-based
  cleanup is structurally fragile in this codebase: **`ExUnit.OnExitHandler` runs every
  `on_exit/1` callback via `spawn_monitor` in a separate runner process, never the
  original test process** — that file worked this out for `Sandbox.checkin/1` (a
  different resource) but the same fact is exactly why `on_exit/1` is not a load-bearing
  safety net for *any* per-test cleanup whose registration can be skipped by a hard kill:
  `on_exit/1` only runs at all if ExUnit gets a chance to schedule it, which a `:kill`
  exit or a VM-level abort does not guarantee.
- `docs/anti-patterns.md` (full) — no directly-applicable existing entry; this design's
  own §9 proposes one (a killed/timed-out test process's manually-committed cleanup is
  not guaranteed to run — write the safety net outside the test process, not inside it).
- `docs/migration/decisions/0006-identity-tables-schema-per-tenant.md` — background for
  why `tenant_schemas`/per-tenant schemas exist at all (REQ-063); no decision recorded
  there about reaper/cleanup mechanisms, so nothing to reconcile against.
- `test/support/tenant_slug.ex` (`Letflow.TenantSlugFixture`, full) — ISS-0059's fix for
  a **different but related** symptom of this same underlying class ("a prior `mix test`
  invocation crashed or was killed before its `on_exit` cleanup ran" — its own moduledoc,
  verbatim). ISS-0059 made *new* slugs collision-proof despite existing orphans; it does
  not remove the orphans themselves. This design is the complementary fix: it removes the
  orphans, rather than working around their presence. Establishes the project's existing
  `test/support/*.ex`, `Letflow.*Fixture`-style naming/placement convention this design
  follows.
- `test/test_helper.exs` (full — one line, `ExUnit.start()`) and `mix.exs` lines 10/20-21
  (`elixirc_paths(:test) == ["lib", "test/support"]`) — confirms `test/support/*.ex` is
  compiled under `MIX_ENV=test` and that `test_helper.exs` is the correct, existing
  place to run one-time suite-level setup/teardown.
- `config/test.exs` line 17 (`database: "letflow_test#{System.get_env("MIX_TEST_PARTITION")}"`)
  — confirms per-partition DB isolation already exists (load-bearing for §2.3's
  concurrent-worktree safety argument) and that this module only ever runs against a
  test database, never production.
- `lib/letflow/tenant_provisioning.ex` (`schema_name_for_tenant/1`, `provision_tenant_schema/1`,
  `Registration` schema fields: `tenant_id`, `schema_name`, `migrations_applied_at`,
  `provisioned_at`) and `lib/letflow/tenant_provisioning/registration.ex` lines 1-50
  (the `@schema_name_format ~r/^tenant_[0-9a-f]{32}$/` changeset validation, added per
  ISS-0027/GH#85 "as defence in depth against a future second writer... ever bypassing
  that derivation"). Load-bearing for §4's defensive validation: ISSUE-FIXER's own
  diagnosis states the orphan-producing path used **"a raw `Repo.insert` into
  `tenant_schemas`"** — a raw insert bypasses `Registration.create_changeset/2`'s own
  format validation, so this design cannot assume every `tenant_schemas.schema_name`
  value it reads back is well-formed, even though every *changeset-validated* writer
  guarantees it.
- `priv/repo/migrations/20260819000004_drop_legacy_public_identity_tables.exs` (full) —
  confirms `tenant_schemas` is read by, but not written by, the guard; confirms
  `SandboxPool`'s own `sandbox_*` schemas never appear in this table (`sandbox_pool.ex`'s
  own moduledoc: "Sandbox schemas are NOT tenant schemas — they carry no
  `Letflow.TenantProvisioning.Registration` row"), so a sweep of every `tenant_schemas`
  row can never touch a live `SandboxPool` claim.
- Searched for a persistent/seed tenant meant to survive across the whole suite
  (`grep -rln "setup_all" test/ | xargs grep -l "provision_tenant_schema\|Tenant.create_changeset"`,
  and `priv/repo/seeds*`): no matches. No test file provisions a tenant intended to
  outlive its own test/module. This is load-bearing for §2's "nothing legitimate is ever
  active at suite-start or suite-end" argument (§2.1).
- **(Rework iteration 1)** Re-checked whether `MIX_TEST_PARTITION` is ever mechanically
  enforced for concurrent `mix test` invocations, rather than assuming the documented
  convention holds: `find .github -iname "*.yml" | xargs grep -l "mix test"` — no CI
  workflow file exists in this repo at all (no automated enforcement anywhere).
  `docs/issues/ISS-0015.yaml` (full, the issue that introduced the partitioned-port fix)
  states the partition discipline explicitly as an **instruction** ("the documented
  isolation instruction... is true for `mix test` and silently false for `mix run`"), not
  a guarantee any tooling checks — and confirms a real violation of it already happened
  once (two worktrees briefly colliding on port 4000 before that fix). `config/test.exs`
  line 17 (`"letflow_test#{System.get_env("MIX_TEST_PARTITION")}"`) confirms the actual
  *default* behavior when the env var is unset is to fall back to plain `letflow_test`,
  not to fail closed. Conclusion, load-bearing for the rewritten §2.3: this design cannot
  assume `MIX_TEST_PARTITION` is always set and must not rely on it as its only
  concurrent-invocation safety argument.
- **(Rework iteration 1)** `lib/letflow/tenant_provisioning.ex` line 164
  (`Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [schema_name])`) and
  `lib/letflow/tenant_provisioning/registration.ex`'s schema — confirms `Registration`
  already carries a `provisioned_at` timestamp (`timestamps(inserted_at: :provisioned_at,
  updated_at: false)`), which §2.3/§3.2's new age-threshold mitigation reads rather than
  adding a new column.

---

## 1. Scope boundary

**In scope:** close the reaper gap for the direct `TenantProvisioning.provision_tenant_schema/1`
+ manual-`on_exit/1` pattern — i.e., guarantee that a `tenant_schemas` row (and its real
Postgres schema) created by this pattern cannot survive past the `mix test` invocation
that created it, regardless of whether the owning test process's `on_exit/1` callback
ever actually ran.

**Explicitly out of scope, not silently dropped:**

| Not built here | Why | Where it's tracked |
|---|---|---|
| Routing the 30+ direct-provisioning call sites through `Letflow.SandboxPool` instead | Task instruction flags this as "likely a large blast-radius change" and, structurally, wrong fit: `SandboxPool` schemas are deliberately non-tenant (no `Registration` row, `sandbox_*` prefix) — `Letflow.Definitions.claim_sandbox_and_proceed/8`'s callers need an ephemeral scratch schema, not a real, registry-backed tenant, so this is not a drop-in substitute for the 30+ files this issue is about | This design's §2 |
| Editing any of the 30+ test files themselves | Not needed — §2's mechanism observes `tenant_schemas` from outside every test process, so it requires no per-test-file cooperation, registration call, or `on_exit/1` change. This is smaller than the "small number of call-site changes" the task asked to prefer, and is explained (not merely asserted) in §2.1-§2.2 | §2 |
| A same-`mix test`-invocation "test A crashes mid-run, test B (a later-running guard test in the same invocation) sees the orphan" scenario | The mechanism in §2 only observes `tenant_schemas` at the very start and very end of a `mix test` invocation, not continuously — a leak created and observed within the *same* invocation, before that invocation's own end-of-suite sweep runs, is not healed in time for that invocation's own later assertions. Named explicitly, not silently assumed away — see OQ-1 (§8) | §8 OQ-1 |
| `ISSUE-FIXER`'s optional defense-in-depth idea (making the guard migration/test itself tolerant of unrelated pre-existing `tenant_schemas` rows) | Named optional by the task; not required once the leak itself is closed (§2 removes the rows the guard was tripping over) — left as an explicit alternative, not designed | §8 OQ-2 |
| `Letflow.SandboxPool` itself, `lib/letflow/process_instance.ex`, `lib/letflow/instance_supervisor.ex`, `lib/letflow/application.ex`, or any other supervision-tree file | Out of this task's sizing guard. §3 confirms this design introduces **no new supervised process at all** (the mechanism is a plain function, not a GenServer), so this boundary is satisfied structurally, not just by omission — there is nothing supervision-tree-shaped to add | §3 |

---

## 2. Fix mechanism selected: a suite-boundary sweep, not a per-claim owner-monitor

### 2.1 Why `SandboxPool`'s owner-monitor pattern does not transfer here

`SandboxPool.claim/2`'s owner-monitor (ISS-0048's fix) works because `SandboxPool` has a
single in-memory point of truth (`state.active`) for "which claims are legitimately live
right now," updated in real time as claims are granted and released — a `:DOWN` for a
claim-holding pid is unambiguous evidence of a leak *at the moment it fires*, because the
pool always knows, synchronously, whether that pid still legitimately holds the claim.

The direct-provisioning pattern this issue is about has no equivalent single point of
truth while tests are running — no process anywhere currently tracks "which
`tenant_schemas` rows are mid-test right now," and building one (i.e., threading a
`track(tenant_id, schema_name)`/`untrack(tenant_id)` pair through all 30+ call sites, an
extension of `SandboxPool`'s exact mechanism) is exactly the large-blast-radius,
many-call-site change the task asked this design to avoid if a smaller option exists —
and per §2.2, one does.

### 2.2 What actually differs: at suite-start and suite-end, nothing legitimate is ever active

`SandboxPool`'s own design doc (`iss-0048-...md` §2.2 point 1) rejected a periodic reaper
for **its** problem specifically because a reaper comparing live schemas against
"currently active" needs that active-set from somewhere, and the only correct source is
the same in-memory state an owner-monitor already gets for free — so a periodic reaper
there is *strictly worse*, not an independent alternative.

That reasoning does not apply to `tenant_schemas`, because there are two points in every
`mix test` invocation where "currently active" is trivially, structurally always the
empty set — no active-tracking needed at all:

- **Before `ExUnit.start()` runs** — no test process has been spawned yet, so no
  `tenant_schemas` row can possibly be mid-test. Any row already present belongs to a
  *prior* `mix test` invocation (this VM or an earlier, killed one) that never cleaned up
  after itself.
- **After `ExUnit.after_suite/1`'s callback fires** — by ExUnit's own documented
  contract, this runs once every test process has already exited (successfully,
  by failure, or by timeout-kill) and after every `on_exit/1` ExUnit was able to schedule
  has already run. Any row still present at this point was not cleaned up by its own
  test's `on_exit/1` and, by construction, cannot become active again within this
  invocation — there is no test process left to own it.

At both instants, "is this row an orphan?" reduces to "does this row currently exist?" —
no owner-monitor, no per-claim state, no `track`/`untrack` call sites required. This is a
sharper, timing-guaranteed version of the "global teardown... sweep" option ISSUE-FIXER's
diagnosis itself named as option (c): rather than confirming each row's owning test
process is dead one row at a time, the sweep runs only at the two moments where *every*
row's owner is guaranteed dead (or never yet born), so no per-row liveness check is
needed either.

**Decision:** a suite-boundary sweep function, called once before `ExUnit.start()` and
once via `ExUnit.after_suite/1`. Zero new processes, zero new supervised children, zero
new public API on any existing module, zero test-file edits.

### 2.3 Safety of an unconditional sweep — the things that could make this wrong, addressed

- **Could a legitimate, intentionally-persistent tenant get swept?** No test file
  provisions a tenant meant to outlive its own test/module (§0's `setup_all` grep; no
  `priv/repo/seeds*`) — every existing user of this pattern already registers its own
  `on_exit/1` cleanup, meaning every existing author of this pattern already considers
  the row temporary. A sweep that removes rows nothing intends to keep is not a behavior
  change for any currently-passing test, **within a single invocation**.
- **Could this ever run against a production database?** No — both call sites
  (`test/test_helper.exs`) only ever execute under `mix test`.
- **Could two concurrent `mix test` invocations sharing the *same* database (e.g. the
  project's two-worktree setup running without `MIX_TEST_PARTITION` set on one or both
  sides) race each other's sweep against live, in-progress state? — Yes, and this is a
  real, not theoretical, gap in the original version of this design, confirmed by
  rework iteration 1.** `MIX_TEST_PARTITION` is a documented *convention*
  (`docs/anti-patterns.md`, `README.md`), not a mechanically enforced precondition — §0's
  rework-iteration bullet confirms no CI workflow exists in this repo and
  `docs/issues/ISS-0015.yaml` itself already records one real violation of this exact
  convention (a port collision between two worktrees before that issue's own fix).
  `config/test.exs` line 17's fallback to plain `letflow_test` when the env var is unset
  is the actual default, not an edge case. Under that shared-DB scenario, §2.2's core
  claim — "nothing legitimate is active at suite boundaries" — is true only *within* one
  invocation's own lifecycle, not across two concurrent, unpartitioned ones: invocation
  A's end-of-suite sweep could observe a `tenant_schemas` row invocation B provisioned
  moments earlier and is still actively using mid-test, and `DROP SCHEMA ... CASCADE` it
  out from under B — an **active destructive race**, strictly worse than the pre-existing
  inert-orphan hazard this design exists to fix (an inert orphan just sits there wasting
  a schema; a wrongly-dropped live schema corrupts a running test's results).

  **Mitigation (not merely documented — a real filter, §3.2/§4 INV-R-5):** `sweep_orphans/2`
  only reclaims a `tenant_schemas` row whose `provisioned_at` timestamp (a column
  `Registration` already carries, §0) is older than a configurable minimum age
  (`min_age_seconds`, default 300s / 5 minutes). Every legitimate use of the
  direct-provisioning pattern provisions and finishes using its tenant within a single
  test's setup/body/teardown span — seconds, not minutes (`Ecto.Migrator.run/4`'s own
  replay plus a handful of assertions) — so a row still within the age window is, with
  very high confidence, either genuinely mid-test (this invocation or a concurrent one)
  or was provisioned moments before the sweep ran and hasn't had its own `on_exit/1` fire
  yet; either way, touching it is unsafe and the filter correctly skips it. A row *past*
  the window cannot belong to a still-in-progress test under any realistic test runtime,
  regardless of which invocation created it.

  This is a bounded-delay, not a zero-delay, fix: a row genuinely orphaned by a crash
  *within this same invocation*, very close to that invocation's own end-of-suite sweep,
  will not be reclaimed until it ages past `min_age_seconds` — i.e., not necessarily by
  this invocation's own sweep, but reliably by a later invocation's start-of-suite sweep
  (§5) once enough wall-clock time has passed. This trades "immediate cleanup" for "safe
  cleanup," which is the correct trade given the alternative is an active-drop race
  against a concurrently-running test — disclosed explicitly, not silently accepted, as
  §4 INV-R-5 and §8 OQ-4.

---

## 3. New module — `Letflow.TenantSchemaReaper`

**File:** `test/support/tenant_schema_reaper.ex` (test-only — compiled under
`elixirc_paths(:test)` per `mix.exs`, same placement convention as
`test/support/tenant_slug.ex`). **Not** placed under `lib/letflow/` — it is never part of
the shipped application and must never be added to `lib/letflow/application.ex`'s
supervision tree (§1's scope boundary).

**Not a GenServer, not a supervised process of any kind** — a plain module with one
public function and small private helpers, matching §2's conclusion that no in-memory
liveness state is needed.

### 3.1 Public interface

```
@spec sweep_orphans(repo :: module(), min_age_seconds :: non_neg_integer()) ::
        {:ok, %{reclaimed: non_neg_integer(), skipped_invalid_format: non_neg_integer()}}
```

- `repo` defaults to `Letflow.Repo`, matching this project's own testability convention
  of accepting the repo as a parameter (mirrors `SandboxPool`'s own `pool` parameter
  style, `Letflow.SandboxPool.claim/2`'s `pool \\ __MODULE__`).
- `min_age_seconds` defaults to `300` (5 minutes) — the concurrent-invocation safety
  filter from §2.3. Exposed as a parameter (not hardcoded) so a test for this module
  itself (§3.2 note, TEST-DESIGNER guidance) can pass `0` to exercise the reclaim path
  without an artificial sleep, and so a future caller can tune it without a code change.
- **(Rework iteration 1 — precise failure-mode contract, replacing the prior "never
  raises" claim, which §3.2's original algorithm did not actually guarantee.)**
  `sweep_orphans/2` always returns `{:ok, %{...}}` — it never lets an exception escape to
  its caller — but it achieves this via an **outer** `try/rescue/after` around the entire
  body (§3.2 step 0), not only around the per-row cleanup. Two distinct failure classes,
  both handled, both logged distinguishably:
  - A **per-row** failure (§3.2 step 3e) — caught locally, does not affect other rows,
    silently reduces `reclaimed`'s count for that row only (no log-level distinction
    needed here beyond the row-level warning already specified in step 3a/3e).
  - An **outer** failure — the bulk `SELECT` itself raising (e.g. a transient connection
    error, or a fresh test database at suite-load-time before migrations have applied),
    or either `Ecto.Adapters.SQL.Sandbox.mode/2` call raising — caught by the outer
    `rescue`, logged via `Logger.error/1` with a message distinguishable from a normal
    empty sweep (e.g. `"TenantSchemaReaper.sweep_orphans/2 aborted: <exception>"`, not
    reused for the zero-orphans-found case), and reported back as
    `{:ok, %{reclaimed: 0, skipped_invalid_format: 0}}` — i.e., "swept nothing this
    call," indistinguishable *in its return value* from a genuinely empty sweep, but
    distinguishable in the log. This mirrors `SandboxPool.provision_sandbox/0`'s own
    "swallow its own failure, this is cleanup, not the primary error path" precedent
    (§0/§3.3), extended to cover the whole function body, not just the per-row DROP.
    **Rationale for not adding an `{:error, term()}` variant instead (the task's other
    named option):** `sweep_orphans/2`'s two call sites (§5) are `test_helper.exs`'s
    top-level script and an `ExUnit.after_suite/1` callback — neither has a caller
    positioned to meaningfully react to an `{:error, _}` return (there is no supervisor
    or retry loop above either call site), and letting the bulk `SELECT`'s exception
    propagate unrescued would abort the entire `mix test` invocation over what is,
    structurally, a best-effort cleanup pass — strictly worse than proceeding with zero
    orphans reclaimed this call and letting the next invocation's sweep retry.
  - The `after` clause (§3.2 step 4) restoring `Ecto.Adapters.SQL.Sandbox.mode(repo,
    :manual)` runs **unconditionally**, on both the success and the rescued-failure path
    — required so an outer failure (e.g. the bulk `SELECT` raising immediately after
    step 1 already switched the pool to `:auto` mode) cannot leave the sandbox pool
    stuck in `:auto` mode for every test that runs afterward.
- `reclaimed` — count of `tenant_schemas` rows this call successfully dropped the schema
  for and deleted (registration row + `tenants` row).
- `skipped_invalid_format` — count of rows whose `schema_name` failed the defensive
  format check (§3.2) and were therefore **not** touched (logged, not deleted) — see §4
  for why this must fail closed rather than attempt the DROP anyway. Rows skipped by the
  age-threshold filter (§2.3, §3.2 step 2) are **not** counted here — they are not a
  malformed-data condition, just "not yet eligible," so a separate counter would be noise
  for this function's callers (both of which only log the returned map, §5); ELIXIR-DEV
  may add a third counter if TEST-DESIGN-VALIDATOR judges it useful for assertions, but
  it is not required by this design.

No other public function. No changed `@spec` anywhere else in the codebase.

### 3.2 Algorithm (prose/pseudocode, no implementation code)

**(Rework iteration 1 — the whole body is now wrapped by an outer `try`/`rescue`/`after`,
step 0/step 4 below, per §3.1's rewritten contract. Steps 1-3 are unchanged in substance
from the original design; step 2 gains the age-threshold `WHERE` filter from §2.3.)**

0. **Outer `try` begins here.** Everything in steps 1-3 runs inside this `try`; step 4
   (the `Sandbox.mode(repo, :manual)` restore) is the `after` clause, so it runs whether
   steps 1-3 succeed or raise. If anything in steps 1-3 raises an exception that escapes
   its own local handling (i.e., anything other than the already-caught per-row failure
   in step 3e — concretely, the `Sandbox.mode(repo, :auto)` call in step 1 or the bulk
   `SELECT` in step 2 raising), the outer `rescue` catches it, logs it via
   `Logger.error/1` with a message naming this as an aborted sweep (distinguishable from
   a normal zero-orphans log line — §3.1), and the function proceeds directly to
   returning `{:ok, %{reclaimed: 0, skipped_invalid_format: 0}}` (skipping any remaining
   work in steps 1-3, but the `after` clause still fires).
1. Force `Ecto.Adapters.SQL.Sandbox.mode(repo, :auto)` — required before issuing any real
   (non-rolled-back) query from a process that never went through
   `Ecto.Adapters.SQL.Sandbox.checkout/2` (neither `test_helper.exs`'s top level nor
   `ExUnit.after_suite/1`'s callback process has checked out a sandboxed connection).
   This is the exact, already-established idiom `identity_migration_test.exs`,
   `tenant_provisioning_test.exs`, `identity_test.exs`, and `role_registry_test.exs`
   already use for real-commit work (§0) — not a new pattern.
2. `SELECT id, tenant_id, schema_name FROM tenant_schemas WHERE provisioned_at <
   (now() - <min_age_seconds> seconds)` — **(rework iteration 1: now filtered, not every
   row unconditionally)**. The age filter is §2.3's concurrent-invocation safety
   mitigation: a row provisioned more recently than `min_age_seconds` ago is left alone,
   since it may belong to a still-in-progress test in this invocation or a concurrently
   running, unpartitioned one (§2.3). §2.2's "nothing legitimate is active" argument
   still does the rest of the work for rows past that age — no legitimate row is ever
   *that* old while its owning test is still using it.
3. For each row returned by step 2, in a small helper (`reclaim_row/2`, private):
   a. Validate `schema_name` against `~r/^tenant_[0-9a-f]{32}$/` — **the same regex
      `Letflow.TenantProvisioning.Registration`'s own changeset already enforces**
      (`lib/letflow/tenant_provisioning/registration.ex`'s `@schema_name_format`, added
      per ISS-0027/GH#85). See §4 for why this check cannot be skipped here even though
      it is redundant for every changeset-validated row.
      - If it fails: increment `skipped_invalid_format`, `Logger.warning/1` naming the
        row's `id`/`tenant_id` and the offending `schema_name` value, move to the next
        row without touching the database for this row at all.
      - If it passes: continue.
   b. `DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE` — identical statement shape to
      `SandboxPool.drop_schema/1` and every existing `on_exit/1` cleanup block already in
      the test suite; safe because `schema_name` was just validated in (a).
   c. `DELETE FROM tenant_schemas WHERE id = <row id>`.
   d. `DELETE FROM tenants WHERE id = <tenant_id>` — matches every existing `on_exit/1`
      block's own final cleanup step; a no-op (0 rows affected) if the `tenants` row is
      already gone, which is fine and expected (idempotent, matches `DELETE`'s own
      semantics, no error).
   e. Steps (b)-(d) are wrapped in the row's own `try/rescue` (an **inner** rescue,
      nested inside the outer one from step 0) — a failure in one row (e.g. a concurrent
      `DROP` racing this same row, vanishingly unlikely given §2.3's age filter, or a
      transient connection error) does not abort the sweep for the remaining rows.
      A rescued row does **not** increment `reclaimed`; it is simply left for the next
      sweep to retry.
4. **`after` clause (always runs, success or outer-rescue path — see step 0):** restore
   `Ecto.Adapters.SQL.Sandbox.mode(repo, :manual)` before returning — leaves the pool in
   the mode every other test file's own `setup` already assumes at the start of its own
   first checkout (mirrors `role_registry_test.exs`'s own explicit restore-to-`:manual`
   step after its own real-commit work, cited in §0 — the same hazard, the same fix). This
   must be unconditional: if step 1 already switched the pool to `:auto` and step 2's bulk
   `SELECT` then raised, only an unconditional `after` (not a step placed after step 3 in
   the normal control-flow path) prevents the pool being left in `:auto` mode for every
   test that runs afterward.
5. Return `{:ok, %{reclaimed: <count from 3b-3d successes>, skipped_invalid_format: <count from 3a failures>}}`
   on the normal path, or `{:ok, %{reclaimed: 0, skipped_invalid_format: 0}}` on the
   outer-rescue path (step 0).

### 3.3 Why step 3's per-row `try/rescue` does not need `SandboxPool`'s owner-monitor idiom

`SandboxPool.provision_sandbox/0`'s `try/rescue` only catches *raised exceptions*, not
`exit` signals (`iss-0048-...md` §5.4 quotes this exact gap for why an owner-monitor was
still needed there). That gap does not apply here: `sweep_orphans/2` runs synchronously,
in the calling process (`test_helper.exs`'s own process, or ExUnit's own suite-callback
process), with nothing else able to concurrently kill *that* process out from under a
single row's cleanup in a way that would leave a half-swept state worse than the state
the sweep started in — a row not yet reached by the loop is simply left for the next
sweep, exactly like a row that failed its own `try/rescue`. No owner-monitor is needed
because there is no "owner" here in `SandboxPool`'s sense (a claim-holding pid) — the
sweep is not standing in for a live process's cleanup obligation, it is a batch pass over
already-abandoned rows.

---

## 4. Invariants

- **INV-R-1.** `sweep_orphans/2` never interpolates a `tenant_schemas.schema_name` value
  into raw SQL without first validating it against `^tenant_[0-9a-f]{32}$`. This is
  stricter than every existing `on_exit/1` cleanup block in the test suite today (which
  re-derive `schema_name` via `TenantProvisioning.schema_name_for_tenant(tenant.id)`,
  never reading the column back from the DB) — necessary specifically because this
  function reads back rows that may have been written via **the same raw `Repo.insert`
  path ISSUE-FIXER's diagnosis names as this issue's own leak source**, which does not go
  through `Registration.create_changeset/2` and therefore is not guaranteed to satisfy
  that changeset's own format invariant. A malformed row is skipped and logged, never
  silently coerced or force-dropped.
- **INV-R-2.** `sweep_orphans/2` is idempotent and safe to call any number of times,
  including zero orphans present (returns `{:ok, %{reclaimed: 0, skipped_invalid_format: 0}}`)
  and including being called twice in a row (second call reclaims 0, since the first call
  already removed everything it could). **(Rework iteration 1 clarification:** this
  return value is also, deliberately, what an *outer* failure returns — §3.1/§3.2 step 0
  — so callers cannot distinguish "genuinely nothing to reclaim" from "the sweep aborted"
  from the return value alone; only the log output distinguishes them. Both callers
  (§5) treat the return value the same way either way (best-effort, fire-and-forget), so
  this ambiguity is intentional and does not need resolving for this design's own
  callers — see §3.1 for the full rationale.)
- **INV-R-3.** `sweep_orphans/2` never touches a `sandbox_*`-prefixed schema or any row
  outside `public.tenant_schemas`/`public.tenants` — `SandboxPool` claims are never
  registered in `tenant_schemas` at all (§0), so there is no code path by which this
  function could observe, let alone drop, a live `SandboxPool` claim.
- **INV-R-4 (residual, disclosed, not fixed by this design).** A row created and orphaned
  *within* a single `mix test` invocation (a test crashes mid-run) is not reclaimed until
  that same invocation's own end-of-suite sweep, **and even then only if it is already
  past `min_age_seconds`** (INV-R-5) — meaning a *later-running test in the same
  invocation* that happens to be sensitive to `tenant_schemas`'s contents (today, only
  `identity_migration_test.exs`'s guard tests) could still observe it before the sweep
  runs, or before it ages past the threshold. Named explicitly as OQ-1 (§8), not silently
  assumed away — this is a narrower window than today's (which has no reclaim at all,
  ever, until a human manually cleans the DB) but not a fully closed one.
- **INV-R-5 (new, rework iteration 1 — the concurrent-invocation safety filter, §2.3).**
  `sweep_orphans/2` never reclaims a `tenant_schemas` row whose `provisioned_at` is more
  recent than `min_age_seconds` (default 300s) before the sweep runs, regardless of
  whether that row turns out to be a genuine orphan or a live, in-progress claim —
  the filter cannot distinguish the two for a *recent* row, and fails closed (skips) in
  that ambiguous case, only ever reclaiming rows old enough that "still in progress" is
  not a realistic explanation (§2.3). This is what makes an unconditional, per-row
  liveness-check-free sweep (§2.2) safe even when `MIX_TEST_PARTITION`-based isolation
  cannot be assumed (§2.3) — it is the real mitigation the rework requires, not merely a
  documentation update.
- **INV-R-6 (new, rework iteration 1 — sandbox-mode restoration is unconditional).** The
  `Ecto.Adapters.SQL.Sandbox.mode(repo, :manual)` restore (§3.2 step 4) runs on every
  code path out of `sweep_orphans/2`, including the outer-rescue path — it is structured
  as an `after` clause, not a step that only runs after steps 1-3 complete normally, so a
  bulk-`SELECT` failure can never leave the connection pool stuck in `:auto` mode for
  subsequent tests.

---

## 5. `test/test_helper.exs` — exact required shape (prose, not literal source)

Three additions to the current one-line file, in this order:

1. A call to `Letflow.TenantSchemaReaper.sweep_orphans/2` (no arguments passed — both
   `repo` and `min_age_seconds` use their defaults, `Letflow.Repo` and `300`),
   placed **before** `ExUnit.start()`. This is the start-of-suite sweep (§2.2's first
   bullet) — it must run before any test process exists, and does not depend on
   `ExUnit.start()` having run first (it is a plain function call against `Letflow.Repo`,
   which the `mix test` task has already started as part of booting the `:letflow`
   application before requiring `test_helper.exs` — the same assumption every existing
   `test/support/*.ex` module and every `DataCase`-based test file already makes).
2. `ExUnit.start()` — unchanged, existing line.
3. `ExUnit.after_suite(fn _stats -> Letflow.TenantSchemaReaper.sweep_orphans() end)` —
   also both defaults —
   registers the end-of-suite sweep (§2.2's second bullet). The `_stats` argument
   (ExUnit's own suite-result map) is intentionally unused — this design does not
   condition the sweep on the suite having passed or failed; an orphan left by a failing
   run is exactly as much a leak as one left by a passing run.

No other change to `test_helper.exs`.

---

## 6. What ELIXIR-DEV must NOT change

- Any file under `test/letflow/` (the 30+ direct-provisioning test files) — none of them
  need any edit for this fix (§1, §2).
- `lib/letflow/sandbox_pool.ex` — unchanged, not touched by this design at all.
- `lib/letflow/tenant_provisioning.ex` / `lib/letflow/tenant_provisioning/registration.ex`
  — unchanged; `Registration`'s own changeset validation is read (its regex is reused
  verbatim, §3.2 step 3a) but not modified.
- `priv/repo/migrations/20260819000004_drop_legacy_public_identity_tables.exs` — no
  change needed by this design (§1's scope table; §8 OQ-2 names the optional
  defense-in-depth alternative explicitly, left undesigned).
- `lib/letflow/application.ex`, `lib/letflow/process_instance.ex`,
  `lib/letflow/instance_supervisor.ex`, or any other supervision-tree file — this design
  introduces no supervised process (§3), so there is nothing for ELIXIR-DEV to register
  anywhere in the supervision tree. If implementation somehow seems to require touching
  any of these files, STOP and flag it back rather than proceeding — that would mean this
  design's "no new process" premise was wrong and needs rework, not a workaround.
- `test/support/tenant_slug.ex` — unrelated, unchanged.

---

## 7. Cross-module dependencies

| Dependency | Direction | Kind |
|---|---|---|
| `Letflow.Repo`, `Ecto.Adapters.SQL.Sandbox` | `Letflow.TenantSchemaReaper` → existing infra | Existing dependencies, no new ones introduced |
| `Letflow.TenantProvisioning.Registration`'s `@schema_name_format` regex | `Letflow.TenantSchemaReaper` reads/duplicates this pattern (§4 INV-R-1) | ELIXIR-DEV should reference the same literal regex value — TEST-DESIGNER should assert both stay in sync (§8 OQ-3 names this as a minor follow-up, not blocking) |
| `test/test_helper.exs` | `ExUnit.start()`/`ExUnit.after_suite/1` → `Letflow.TenantSchemaReaper.sweep_orphans/2` (both defaults) | New call sites, both inside this one file (§5) |
| `test/letflow/identity_migration_test.exs`'s guard tests | Indirect — this fix removes the orphans those tests were tripping over; no direct code dependency | Benefits from this fix without needing any edit itself |

---

## 8. Open questions (explicit, not silently resolved)

**OQ-1 — same-invocation, crash-then-later-guard-test-runs scenario (§1's scope table,
INV-R-4).** Not built here. If this ever proves to matter in practice (evidence would be
a *fresh* `mix test` invocation's own guard test failing due to a leak from *that same*
invocation, not an accumulated one from a prior run), the smaller of the two remaining
options would be a targeted per-call-site owner-monitor limited to
`identity_migration_test.exs`'s own guard-sensitive fixtures rather than all 30+ files —
not designed here since ISS-0064's own evidence (this run's `WF02-REQ052-20260819`
discovery, and ISS-0048/ISS-0050's prior recurrences) is consistently a cross-run/
cross-session accumulation pattern, not a same-run crash-then-fail pattern.

**OQ-2 — ISSUE-FIXER's optional defense-in-depth guard tolerance.** Not built here, per
the task's explicit "optional, your call" framing. Once §2's sweep is in place, the guard
migration's own test should no longer encounter unrelated orphaned `tenant_schemas` rows
in practice, which is why this design does not also change the guard. If a future
recurrence is ever traced to a *different* leak path this design does not cover, revisit
this option then rather than building it speculatively now.

**OQ-3 — regex duplication between `Registration`'s changeset and this module's own
validation (§4 INV-R-1, §7).** `Letflow.TenantSchemaReaper`'s validation regex is a
literal copy of `Registration.@schema_name_format`, not a shared reference to it (that
module attribute is private to `Registration` and this is a test-only module living in
`test/support/`, not `lib/letflow/`, so importing it directly would be an unusual
cross-tree dependency). Left as a literal duplicate with both sites cited in comments
pointing at each other, rather than introducing a shared public constant for two call
sites — reconsider only if a third caller ever needs the same pattern.

**OQ-4 (new, rework iteration 1) — is 300 seconds the right `min_age_seconds` default?**
Not empirically tuned — chosen as "comfortably longer than any single test's own
setup/body/teardown span (seconds), comfortably shorter than a human would wait before
suspecting something is stuck" (§2.3). If operational experience ever shows a legitimate
test occasionally taking longer than 5 minutes end-to-end (e.g. a slow CI runner under
load), the default would need raising — not expected given this pattern's own tests are
single migration-replay-plus-assertions spans, but named explicitly rather than assumed
correct forever. `min_age_seconds` being a parameter (§3.1), not hardcoded, is exactly
what makes this adjustable without a design change if that ever happens.

---

## 9. Anti-pattern entry proposed (for ELIXIR-DEV/ORCH to add to `docs/anti-patterns.md`)

**Working title:** "Relying on `on_exit/1` as the only safety net for real (non-sandboxed)
test-committed state." One sentence of what happened: 30+ test files across this suite
established a real Postgres schema + `tenant_schemas`/`tenants` rows outside Ecto's
sandbox (required, since `Ecto.Migrator` cannot run under the sandbox's shared
connection) and relied solely on a manually-registered `on_exit/1` callback to clean it
up — but `on_exit/1` callbacks run in a separate process ExUnit spawns only if it gets the
chance to schedule one, so a killed or hard-timed-out test process silently orphans real
DB state with no automatic reclaim, and the orphan then causes an unrelated later test
(the `DropLegacyPublicIdentityTables` guard test) to fail nondeterministically depending
on which shared test database happened to accumulate one. **Correct alternative:** for
any test pattern that commits real, non-rolled-back state, pair the `on_exit/1`
convenience cleanup with an out-of-process safety net that does not depend on the test
process surviving long enough to run its own callback — here, a suite-boundary sweep
(`Letflow.TenantSchemaReaper.sweep_orphans/2`) that observes the durable table directly
rather than trusting per-test cleanup to always fire.

---

## 10. Acceptance-criteria traceability

| Likely acceptance criterion | Concrete design element |
|---|---|
| Fix addresses the root cause (leak/reaper gap), not just the one failing test | §2 (mechanism), §3 (module), §5 (wiring) — no change to the failing test file itself |
| Small number of call-site changes, not a 30+-file rewrite | §1 scope table, §2.1-§2.2: **zero** existing test files change; only `test/test_helper.exs` (3 new lines) and one new file |
| `SandboxPool`'s existing pattern read and reused/extended where it fits, not reinvented blindly | §0 (full read), §2.1 (explicit statement of where the owner-monitor idiom does and doesn't transfer), §3.2 step 3e / §3.3 (reused "best-effort, swallow-failure" idiom), §4 INV-R-3 (confirms zero interaction with `SandboxPool`'s own state) |
| Does not touch `process_instance.ex`/`instance_supervisor.ex`/any supervision-tree file | §1 scope table, §3 ("not a GenServer, not a supervised process of any kind"), §6 (explicit "STOP and flag" instruction if this ever seems necessary) |
| Interface/@spec-level detail for any new function | §3.1 |
| State shape (if a new process/registry is involved) | §3: explicitly none — no new process, no new state, and §2.2 explains why none is needed |
| Exactly which existing call sites need to change and how | §5 (the only call sites: `test/test_helper.exs`, three lines, exact placement and order specified) |
| No implementation code | This entire document is `@spec`s, prose algorithm steps, and a pseudocode-style DROP/DELETE statement shape (§3.2) — no `.ex`/`.exs` function bodies |
| **(Rework iteration 1)** Failure-mode contract for `sweep_orphans/2` is internally consistent between the interface doc and the algorithm | §3.1 (precise contract: outer `try/rescue/after`, two failure classes, exact return value and logging for each) and §3.2 step 0/step 4 (the algorithm that actually implements that contract) — no remaining claim in §3.1 that isn't backed by a concrete step in §3.2 |
| **(Rework iteration 1)** Concurrent-invocation safety argument covers the actual default (`MIX_TEST_PARTITION` unset/shared DB), not only the partitioned case | §2.3 (rewritten: confirms no CI enforcement exists, §0's new bullet backs this with a direct repo check) and §4 INV-R-5 (the real mitigation — an age-threshold filter, not a documentation-only claim) |

---

## 11. Extension (ISS-0110, 2026-08-21) — the age-threshold filter alone is no longer sufficient

**Executed directly by ORCH (self-diagnosed/designed/reviewed — no CODE-DESIGNER/CODE-DESIGN-VALIDATOR/REVIEWER role split available in this execution context; stated here plainly per this session's established convention for that deviation).**

§4 INV-R-5's age-threshold filter (`min_age_seconds`, default 300s) was this design's whole
concurrent-invocation mitigation. Two facts falsified it after the fact, both measured, not
argued: (1) the suite now runs 564-609s, well past 300s, so a schema provisioned early in a
long run is "safely old" by this filter's own test while still genuinely in use; (2) ISS-0107
demonstrated a nested `mix test` invocation really can inherit the same
`LETFLOW_DB_PORT`/`MIX_TEST_PARTITION` as its parent and land on the identical database. The
age filter alone cannot tell "old and truly orphaned" from "old and still owned by a
long-running or nested invocation" — it was never meant to (§2.3 explicitly reasoned about
CI-enforced partitioning, not about invocation lifetime).

**The fix adds a liveness check ahead of the age filter, not a replacement for it.**
`config/test.exs` tags every Postgres connection a `mix test` invocation opens with
`application_name: "letflow_mixtest_#{System.pid()}"` — one tag per invocation's OS process,
stable for its whole lifetime, and distinct from a nested invocation's own tag (a new OS
process gets a new `System.pid()`). `sweep_orphans/2` now checks `pg_stat_activity` for any
*other* `letflow_mixtest_*` tag before running its existing age-based sweep at all. If one is
present, the entire sweep defers (not just that invocation's own rows — this module tracks no
per-row ownership, so there is no way to tell a live invocation's old row from a different,
genuinely dead invocation's old row without one) and retries on the next boundary call. If none
is present, §3.2's original algorithm runs completely unchanged.

**Why this is additive, not a redesign:** zero change to `reclaim_row/2`, the schema-name
validation, the outer `try/rescue/after` contract (§3.1), or the return shape. One new
production-adjacent config line (`config/test.exs`, test-env only) and two new private
functions in the same test-only module. No new table, no new column, no migration, no touch to
any of the ~40 test files that call `provision_tenant_schema/1` (rejected explicitly — either a
production migration for a test-only concern, or a 40-file hook, both disproportionate to the
hazard).

**What this does NOT fix:** ISS-0110's own related finding (`docs/issues/ISS-0113.yaml`) — a
separate `Sandbox.mode(:auto)`-leak hazard in the copy-pasted fixture template — is unrelated
to this reaper and was investigated/reverted separately this session, not folded in here.
