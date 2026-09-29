# ISS-0879: narrow the `tenant_template_build_*` visibility window + scope the two `retire_oldest_eligible_month/1` happy-path assertions

Fixes the flake diagnosed in ISSUE-FIXER's Step 1 handoff (verbatim root-cause
text reproduced in this run's WF-03 Step 2 task message; not re-derived here).
This design decides and specifies the fix built on top of that diagnosis —
it does not re-investigate root cause.

## 0. Scope

Test-support and test-assertion only. No change to
`lib/letflow/event_store/retention_operations.ex` (its
`provisioned_tenant_schemas/0` stays genuinely platform-wide, per REQ-377's
documented admin-operation semantics — moduledoc lines 42-51, unchanged by
this design) and no change to `lib/letflow/tenant_provisioning.ex`'s public
`replay_migrations/2` contract or its `mark_migrations_applied/1` behavior
(every one of `replay_migrations/2`'s ~35 other call sites across `lib/` and
`test/`, enumerated in §5, keeps depending on "success always stamps
`migrations_applied_at`" exactly as today). The only file this design asks
ELIXIR-DEV to change in `lib/`is none. Two files change:

1. `test/support/tenant_template.ex` — narrows the visibility window (§2).
2. `test/letflow/event_store/retention_operations_test.exs` — scopes the two
   happy-path assertions to each test's own fixtures (§3).

## 1. Root cause recap (condensed from ISSUE-FIXER's diagnosis)

`retire_oldest_eligible_month/1`'s fanout reads `provisioned_tenant_schemas/0`
(`retention_operations.ex:327-333`) — genuinely platform-wide by design,
`where: not is_nil(r.migrations_applied_at)`. `do_build_template!/1`
(`tenant_template.ex:410-458`) provisions a throwaway
`tenant_template_build_<hex>` schema, calls
`TenantProvisioning.replay_migrations/2` (`tenant_provisioning.ex:372-399`),
which — as its own committed side effect, `mark_migrations_applied/1`,
`tenant_provisioning.ex:797-802` — sets that throwaway row's
`migrations_applied_at` to a real, committed, cross-process-visible
timestamp. Only *after* `template_self_check!/1` runs (`tenant_template.ex`
step 3, line 437) does `delete_throwaway_tenant_and_registration!/1` (step 4,
line 442) delete the row. Between those two points, the throwaway row
satisfies `provisioned_tenant_schemas/0`'s predicate. If a *different*
`scripts/test_parallel.sh` partition calls `retire_oldest_eligible_month/1`
during that window, the throwaway schema leaks into that partition's own
`schemas` list. `PartitionMaintenance.retire_month/3` then rejects
`tenant_template_build_<hex>` (fails `tenant_id_for_schema_name/1`'s
`"tenant_" <> 32-hex` shape check, INV-1) → `{:error, :invalid_schema_name}`
→ an outcome row `status: "failed", reason: "invalid_schema_name"` for a
schema the observing test never created — exactly the symptom in both
failing tests.

`assert_template_parity_against_independent_reference!/1`
(`tenant_template.ex:639-668`, reached from `template_self_check!/1` only
when `LETFLOW_TEMPLATE_REFCHECK=1`, and directly from
`test/support/tenant_template_test.exs`) has the **identical** shape: its own
`reference_tenant_id`/`reference_schema` throwaway row goes through the same
`replay_migrations/2` call (line 648) and is deleted only in its `after`
block (line 663), after `assert_clone_parity!/2` has run. Same window, same
mechanism, same fix needed — this design covers both call sites, not just
`do_build_template!/1`.

## 2. Fixture-side fix: null the throwaway row's `migrations_applied_at` immediately after `replay_migrations/2` succeeds, before any other work

### 2.1 Why this, not routing around `replay_migrations/2`

The task brief asked me to assess whether the throwaway row can skip the
normal `mark_migrations_applied/1` path entirely (e.g. call
`Ecto.Migrator.run/4` directly). Rejected:

- `mark_migrations_applied/1` is a **private** function of
  `Letflow.TenantProvisioning` (`tenant_provisioning.ex:797`), reachable only
  through `replay_migrations/2`'s own body. There is no public seam that runs
  migrations without it. Bypassing it means either (a) making it public /
  adding a new public "replay without stamping" function to
  `TenantProvisioning` — production-code surface growth to a module whose
  public contract is intentionally minimal (§0's constraint), or (b) calling
  `Ecto.Migrator.run/4` directly from `tenant_template.ex`, duplicating
  `replay_migrations/2`'s own logic (default-manifest resolution inside its
  own `try`, the `{:ok, _} | {:error, _}` normalization, the
  `maybe_seed_platform_event_types/2` / `maybe_seed_entity_event_types/2`
  calls that follow the migrator run and are needed for the template to have
  correct seed data — see `tenant_provisioning.ex:391-393`). Both options are
  strictly worse than accepting the stamp and clearing it immediately: (a)
  grows a production module's public surface for a test-only need, (b)
  forks a maintained code path into test-support, guaranteed to drift.
- `do_build_template!/1`'s own moduledoc (`tenant_template.ex:16-21`,
  "Production path untouched") already states the design intent that this
  module calls `TenantProvisioning`'s *existing, unmodified* functions —
  reusing `replay_migrations/2` as-is and neutralizing its one
  test-inconvenient side effect after the fact is consistent with that
  intent; forking it is not.

### 2.2 The chosen fix

Immediately after each of the two `TenantProvisioning.replay_migrations/2`
call sites that target a throwaway row — `do_build_template!/1`'s call at
`tenant_template.ex:425` and
`assert_template_parity_against_independent_reference!/1`'s call at
`tenant_template.ex:648` — on the `{:ok, _applied_versions}` success branch,
before any other statement in that branch (i.e. before
`template_self_check!/1` in the first case, before `assert_clone_parity!/2`
in the second), add one call to a new private helper,
`clear_migrations_applied_flag!/1`, taking the throwaway `tenant_id` (the
same value already in scope at both call sites —
`throwaway_tenant_id`/`reference_tenant_id` respectively) and returning `:ok`.
Its body issues a single `Repo.update_all/2` against the `Registration`
schema, scoped `where: r.tenant_id == ^tenant_id`, setting
`migrations_applied_at: nil` — the exact mirror image of
`mark_migrations_applied/1`'s own `Repo.update_all(set: [migrations_applied_at:
now])` (`tenant_provisioning.ex:800-801`), just nulling instead of stamping.
Runs on the same pinned connection (`Repo.checkout/2`'s connection A,
re-entrant per `ensure_template!/0`'s own comment at
`tenant_template.ex:139-149`) as every other statement in the build, so it
needs no additional connection-boundary handling beyond what already exists.

This is a same-shape, same-cost change at both sites: one extra
`Repo.update_all/2` round trip, placed as the very next statement after
`replay_migrations/2` returns success, before any other I/O in that branch.

### 2.3 Why this closes the window to a negligible one, not merely shrinks it

Precisely stated, not overclaimed: this does **not** make the window zero.
`mark_migrations_applied/1`'s own `Repo.update_all/2` (inside
`replay_migrations/2`, not under this design's control — §0's "no
production-code change" boundary) commits as its own separate statement,
autocommitted (no explicit `Repo.transaction/1` wraps
`replay_migrations/2`'s body). A window of one Elixir-to-Postgres round trip
still exists between that commit and this design's own null-out commit,
during which a concurrent partition's `provisioned_tenant_schemas/0` read
could observe the row as `migrations_applied_at`-set. What this design does
achieve, precisely: it shrinks the window from "however long
`template_self_check!/1` (or, worse, `assert_clone_parity!/2`'s own
13-dimension structural diff) takes to run — up to and including, when
`LETFLOW_TEMPLATE_REFCHECK=1`, a **second full 53-migration replay plus a
parity diff**, per `template_self_check!/1`'s own cost-placement comment at
`tenant_template.ex:582-593` — down to one synchronous `Repo.update_all/2`
round trip, immediately following `replay_migrations/2`'s own return." That
is a reduction of multiple orders of magnitude (single-digit milliseconds vs.
a duration `tenant_template.ex`'s own comments describe as expensive enough
to gate behind an opt-in env var), which is the "reduce to an acceptably
negligible window" branch the task brief asked me to weigh against a full
close — a full close is not achievable without a production-code change to
`replay_migrations/2` itself (out of scope, §0), and this narrows the
remaining window to the same order of magnitude as any other single-statement
race this codebase already accepts as negligible (e.g. the advisory-lock
acquire/release round trip `ensure_template!/0` itself already performs
uncontested per ISS-0515).

This is why §3's test-side scoping fix is still needed as a second,
independent layer, not a redundant belt-and-braces addition: §2 narrows the
window; it does not prove no leak can ever occur. §3 makes the two tests
correct regardless of whether a leak occurs, by construction.

### 2.4 What does NOT change in `tenant_template.ex`

- `delete_throwaway_tenant_and_registration!/1` — unchanged, unmoved,
  still the step-4 deletion (`tenant_template.ex:442`) and still the `after`
  cleanup at line 663. `clear_migrations_applied_flag!/1` is a narrowing
  addition, not a replacement — the row is still fully deleted afterward.
  Belt-and-braces: even if the null-out itself somehow failed to reduce
  visibility for a reason not anticipated here, deletion still removes the
  row entirely by the time `build_template!/0` (or the reference build)
  returns.
- `template_self_check!/1`'s own logic — unchanged. It does not read
  `Registration.migrations_applied_at` at all (§1's own diagnosis point:
  it queries the schema's own tables/`schema_migrations` directly via
  `tables_in/1`/`applied_versions_in/1`), so nulling the flag before it runs
  changes nothing about what it checks or how it checks it.
- `insert_throwaway_tenant_and_registration!/1` — unchanged. It still
  inserts the row via `Repo.insert_all/3` with no `migrations_applied_at`
  key at all (so the row starts `nil`, per `Registration`'s own schema
  default), exactly as today; `replay_migrations/2` is still what sets it to
  non-nil, and this design's new call is what un-sets it again.
- INV-8 (atomic build-then-rename) — untouched. `clear_migrations_applied_flag!/1`
  touches only the `Registration` table, never the staging schema itself;
  it has no interaction with the rename-into-place commit point at line 447.

## 3. Test-assertion-side fix: scope `result.outcomes` to each test's own fixtures before asserting

Both tests in `test/letflow/event_store/retention_operations_test.exs`'s
`"retire_oldest_eligible_month/1 -- happy path"` describe block
(lines 302-366) currently assert directly against `result.outcomes` —
correct only under the unstated assumption that the platform-wide fanout
produces outcomes for exactly this test's own fixtures, which §1/§2 show is
not guaranteed (leak risk, narrowed but not eliminated) and was never
actually guaranteed even before ISS-0879 (any other test's genuinely
provisioned, not-yet-cleaned-up tenant schema from a concurrent partition
could equally populate `result.outcomes` — the diagnosis's own closing note).
`outcome_map/2` (`retention_operations.ex:512-522`) already includes
`schema_name` on every outcome, sourced from a `LEFT JOIN` against
`Registration` keyed on `tenant_id` (`retention_operations.ex:486-495`) — no
change needed there; it is exactly the field both tests already destructure
from their own `provisioned_tenant()` calls.

### 3.1 Test 1 — `retention_operations_test.exs:303` ("inserts a running row immediately...")

Change: scope the outcomes list to the one schema this test itself
provisioned, by `schema_name`, before the `assert [outcome] = ...` line
(current line 332). Concretely: after `result = wait_until_status(...)`
(line 328) and before line 332, filter `result.outcomes` down to only the
entries whose `schema_name` equals this test's own `schema_name` (already
bound at line 305 from `provisioned_tenant()`'s return), and assert the
single-element-list shape against that filtered list instead of against
`result.outcomes` directly. No other line in this test changes — the
assertions that follow (`outcome.status == :succeeded`,
`outcome.retired_partition == ...`, `outcome.protected_rows_relocated`) stay
exactly as they are, now operating on the correctly-scoped `outcome`.

### 3.2 Test 2 — `retention_operations_test.exs:339` ("a schema with no eligible month...")

Change: this test already provisions and names both of its own fixtures —
`eligible_schema` (line 341) and `bare_schema` (line 342). Scope the
`statuses` computation (current lines 358-361) to only outcomes whose
`schema_name` is one of these two, before mapping to `.status` and sorting.
Concretely: filter `result.outcomes` to entries whose `schema_name` is
`eligible_schema` or `bare_schema`, *then* `Enum.map(&1.status)` and
`Enum.sort/1` as today. The three assertions that follow
(`:succeeded in statuses`, `:skipped in statuses`, `refute :failed in
statuses`) are unchanged in form — they now evaluate against the
correctly-scoped two-element list instead of the platform-wide list, so a
leaked or otherwise-concurrent `:failed` outcome for a schema neither
fixture created can no longer fail this test. `refute is_nil(bare_schema)`
(line 363) is untouched — it is unrelated to the fanout-scoping issue (a
dead assertion pre-existing this fix, not this design's concern to remove or
keep; left exactly as-is since removing it is not part of this issue's
scope).

### 3.3 Why filtering by `schema_name`, not `tenant_id`

Either field works (§2 confirms `outcome_map/2` carries both). `schema_name`
is chosen because both tests already destructure and hold it in a local
variable for their own other purposes (constructing partitions, logging),
so the scoping filter introduces no new fixture-capture code — it reuses
bindings the tests already have. `tenant_id` would need a new
`%{tenant_id: ...}` destructure at each `provisioned_tenant()` call site
that does not otherwise need it. Either is correct; `schema_name` is the
lower-diff choice.

### 3.4 What does NOT change in the test file

- `provisioned_tenant/0` (the local fixture helper, lines 77-83) —
  unchanged. It already returns `tenant_fixture()`'s full map
  (`%{tenant_id:, schema_name:, tenant:}`, `test/support/tenant_fixture.ex:68-72}`);
  no new field needs to be added anywhere for this fix.
  `%{schema_name: schema_name} = provisioned_tenant()`-style destructuring
  at each call site is untouched — `schema_name` is already being captured
  today, at every one of this describe block's own call sites.
- `wait_until_status/2`, `create_events_month_partition!/3`,
  `with_event_retention_override/2`, `cleanup_retirement_rows_on_exit!/1` —
  unchanged; none of this fix touches how a retirement is driven or how
  cleanup registers, only how the finished result is filtered before
  assertion.
- Every other describe block in this file (`retention_summary/0`,
  `retire_oldest_eligible_month/1 -- error path`, `retirement_status/1`) —
  unchanged; ISS-0879's failing tests are exactly and only the two named in
  §3.1/§3.2.

## 4. Other callers of the touched test-support functions — checked, none broken

`test/support/tenant_template.ex` is shared test infrastructure (per the
task brief's own instruction to verify this explicitly). Checked directly,
not assumed:

- **Public API surface touched:** none. `clear_migrations_applied_flag!/1`
  (§2.2) is a new **private** function (`defp`), called only from the two
  existing call sites inside this same module (`do_build_template!/1`,
  `assert_template_parity_against_independent_reference!/1`). It adds no new
  function to this module's public contract
  (`ensure_template!/0`, `template_ready?/0`, `template_schema_name/0`,
  `clone_tenant_schema!/1`, `assert_clone_parity!/3`,
  `assert_template_parity_against_independent_reference!/0`) — every
  existing caller of those five public functions across the suite
  (`test/support/tenant_fixture.ex:356` via `provision_schema!(:clone, ...)`,
  every test calling `TenantFixture.provisioned_tenant!/1` with
  `template: :replay` or `:clone`, and
  `test/support/tenant_template_test.exs`'s direct exercises of
  `ensure_template!/0`/`assert_template_parity_against_independent_reference!/0`)
  sees no signature change and no new required call of their own.
- **Behavioral change visible to any caller:** none beyond the (already
  narrowed, §2.3) visibility window itself. `ensure_template!/0`'s return
  value (`:ok`), `clone_tenant_schema!/1`'s return shape
  (`{:ok, schema_name} | {:error, {:clone_failed, reason}}`), and
  `assert_clone_parity!/3`'s raise-on-mismatch contract are all untouched.
  A caller that already treats `"tenant_template"`'s post-build state as
  opaque (every caller does — none of them queries `Registration` rows for
  the *template's own* throwaway tenant_id, which is deleted before
  `ensure_template!/0` ever returns to any caller, unchanged by this design)
  observes no difference.
- **`grep -rn "tenant_template" test/` beyond `tenant_template.ex` itself**
  confirms the only other direct consumers are
  `test/support/tenant_template_test.exs` (exercises the build/self-check/
  parity machinery directly — see next point) and
  `test/support/tenant_fixture.ex` (calls only the public
  `ensure_template!/0`/`clone_tenant_schema!/1` surface, per
  `tenant_fixture.ex:356` and its own `provision_schema!/2` dispatch) — no
  other file reaches into this module's private functions or its throwaway-row
  mechanics.
- **`test/support/tenant_template_test.exs` specifically** — this is the
  file most likely to be affected, since it exercises
  `ensure_template!/0`'s build machinery and
  `assert_template_parity_against_independent_reference!/0` most directly
  (per that file's own `async: false` discipline, noted in ISS-0515's design
  §7). It asserts on the *outcome* of a build (schema exists, table set
  correct, parity check passes/fails as expected) and, where it forces a
  rebuild, on `template_db_state/0`'s three-state result — never on the
  throwaway row's own `migrations_applied_at` value or on
  `provisioned_tenant_schemas/0`'s output. Confirmed by reading that file
  end to end: no assertion there depends on the throwaway row's visibility
  window at all, so narrowing that window changes nothing it checks.

## 5. `replay_migrations/2`'s ~35 other call sites — confirmed unaffected

Re-stated from §0: `replay_migrations/2` itself is not modified by this
design (§2.2's new call is a separate, subsequent statement in
`tenant_template.ex`, not an edit to `tenant_provisioning.ex`). Every one of
the call sites `grep -rn "replay_migrations(" lib/ test/` finds — roughly 35
across `lib/letflow/tenant_onboarding.ex`, `test/letflow/**`,
`test/support/tenant_fixture.ex:463`, and
`test/support/public_read_fixture_support.ex:128`, none of which are
throwaway-row build/refcheck call sites this design touches — keeps getting
exactly the same `{:ok, applied_versions} | {:error, _}` return and exactly
the same `migrations_applied_at`-gets-stamped side effect it gets today. This
design adds a *new*, separate statement after two specific call sites
(inside `tenant_template.ex` only); it does not alter
`replay_migrations/2`'s own body, so no other call site's behavior can be
affected by construction.

## 6. Verification ELIXIR-DEV must perform before considering this done

1. **Structural confirmation.** `git diff` shows: (a) one new private
   function in `tenant_template.ex` (§2.2), called from exactly the two
   sites named in §2.2, each call inserted as the first statement of the
   `{:ok, _}` branch immediately following the relevant
   `TenantProvisioning.replay_migrations/2` call; (b) the two test bodies in
   `retention_operations_test.exs` filter `result.outcomes` by `schema_name`
   before the assertions named in §3.1/§3.2, with no other line in either
   test changed.
2. **Regression check on the two named tests, isolated.**
   `mix test test/letflow/event_store/retention_operations_test.exs` passes
   serially (this alone does not prove the fix — the flake is
   contention-dependent, same as ISS-0873 — but must pass as a baseline).
3. **`test/support/tenant_template_test.exs` unaffected.**
   `mix test test/support/tenant_template_test.exs` passes with no behavior
   change (§4's "none observed" claim re-verified by running it, not just
   reading it).
4. **Full parallel-suite re-run, the load-bearing check.**
   `scripts/test_parallel.sh` (or `mix letflow.check.test`) at least twice
   consecutively, at the same partition count the original ISS-0879 filing
   used (N=16), watching specifically for either failing test's exact
   pre-fix symptom (extra `tenant_template_build_*` / `invalid_schema_name`
   entries in `retire_oldest_eligible_month/1`'s outcomes). Per §2.3, a
   clean run does not by itself prove the window is fully closed (it isn't,
   by design) — it demonstrates the combination of the narrowed window (§2)
   and the scoped assertions (§3) is sufficient in practice, which is the
   actual bar ISS-0873's own precedent set for this class of fix.
5. **Confirm no other test in the suite reads `result.outcomes` (or the
   equivalent unscoped platform-wide read) from
   `retire_oldest_eligible_month/1`/`retirement_status/1` without its own
   scoping** — a quick `grep -n "result.outcomes\|\.outcomes" test/letflow/event_store/retention_operations_test.exs`
   confirms whether any other test in this file has the same latent gap
   this design didn't scope (the `error path` and `retirement_status/1`
   describe blocks were not in ISS-0879's filed symptom list and are out of
   this design's stated scope, §0 — but ELIXIR-DEV should report, not
   silently fix, anything found there beyond what §3 already covers, per
   this pipeline's own scope-creep discipline).

## 7. Open questions

None outstanding for this fix's own scope, one forward-looking note recorded
per the task brief's instruction not to silently resolve something bigger:

- **Not this design's scope, flagged for REQ-ANALYST/REVIEWER if judged
  worth pursuing separately:** `lib/letflow/scheduler/poller.ex:469` and
  `lib/letflow/engine/service_task_dispatcher/poller.ex:83` both use the
  identical `where: not is_nil(r.migrations_applied_at)` predicate against
  `Registration` that `provisioned_tenant_schemas/0` uses. Neither poller is
  exercised by ISS-0879's filed symptom, and this design does not assess
  whether either one has an analogous test-only leak-window exposure under
  `scripts/test_parallel.sh` — that would need its own diagnosis, not an
  assumption transferred from this fix. Recorded here only so a future
  reader does not assume this design already ruled it out.
- The residual, non-zero window described in §2.3 (one `Repo.update_all/2`
  round trip between `mark_migrations_applied/1`'s own commit and this
  design's null-out commit) is explicitly not eliminated. If a future,
  much-higher-partition-count run ever reproduces a leak through that
  residual window specifically (distinguishable from today's failure mode
  only by being far rarer, given the order-of-magnitude narrowing in §2.3),
  §3's test-side scoping is what keeps the affected tests correct regardless
  — no further fixture-side work is implied unless a genuinely different
  symptom (not this one) shows up.
