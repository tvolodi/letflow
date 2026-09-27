# ISS-0829 — `migration_rollout_test.exs` EO-004/EO-005 test-isolation fix

Status: design (test-only fix, no production-code change)
Author: CODE-DESIGNER
Input: `handoffs/WF03-ISS0829-20260927/step-01-issue-fixer-diagnosis.json` (ISSUE-FIXER's
confirmed root cause), `test/letflow/platform/migration_rollout_test.exs` EO-004
(lines 334-393) and EO-005 (lines 399-437), the adjacent "queryable outcome record" test
(lines 288-327, ISS-0716 precedent), `lib/letflow/platform/migration_rollout.ex`
(`apply_to_existing_rollout/2` lines 218-256, `active_company_tenant_ids/0` lines 423-432,
`recompute_rollout_completion/1` lines 438-452), and
`lib/letflow/design/req374-tenant-migration-fanout-runner.md` §9 OQ-1.

## 1. Confirmed root cause (recap, not re-derived)

`apply_to_existing_rollout/2` recomputes `active_company_tenant_ids/0` — **every** tenant
with `status == :active` and a `Registration` row, in the **whole shared per-partition
database**, not scoped to any caller-known tenant set — on every repeat call
(`start_rollout/3`'s second call, and `resume_rollout/1`). Any tenant that becomes
active/provisioned in that window (from a concurrently-running, unrelated `async: true`
test file provisioning tenants in the same partition DB, per `scripts/test_parallel.sh`
full-suite load) gets swept into the rollout: a brand-new `Outcome` row is registered and
driven to a terminal status for it (`register_and_seed_outcome/5`,
`apply_outstanding/1`). This is the intentional, explicitly-flagged design in
`req374-tenant-migration-fanout-runner.md` §9 OQ-1 — not a defect to fix in
`migration_rollout.ex`.

EO-004 and EO-005 both assert against the rollout's/outcome table's state **as if no
tenant other than the ones the test itself created can ever appear** in the rollout's
scope. That assumption is false under real parallel-suite load. The adjacent "queryable
outcome record" test (lines 288-327) already defends against exactly this hazard class
(cites ISS-0716) by using `length(result.outcomes) >= 2` (not `==`) and per-tenant
filtering via `outcome_for/2` instead of a global/exact assertion. EO-004/EO-005 must
follow the same pattern.

**Confirmed: no change to `lib/letflow/platform/migration_rollout.ex` is required.**
`active_company_tenant_ids/0`'s global scope, `apply_to_existing_rollout/2`'s sweep-in
behavior, and `recompute_rollout_completion/1`'s "only ever sets `completed_at` once,
never un-sets it" guard (line 446: `if outstanding_count == 0 and
is_nil(rollout.completed_at)`) are all working as designed. The fix is entirely inside
`test/letflow/platform/migration_rollout_test.exs`.

## 2. EO-004 — exact fragile assertions and replacements

Location: `describe "EO-004 ..."` (lines 334-393), test body lines 356-391.

### 2.1 Fragile assertion

Lines 390-391:

```
assert resumed_result.rollout.completed_at != nil
assert resumed_result.rollout.status == "completed"
```

`resumed_result.rollout.status`/`completed_at` reflect `recompute_rollout_completion/1`'s
global check: "every `Outcome` row for this `rollout_id`, across **every** tenant ever
swept into it, is `"succeeded"`." This test only controls two tenants' outcomes (`good`,
`poisoned`). If an unrelated tenant is swept into this same `rollout_id` during the
`resume_rollout/1` call (the confirmed race window) and that tenant's own outcome does
not resolve to `"succeeded"` in this call (e.g. its real DDL fails, or — per
`apply_outstanding/1`'s design — it briefly sits at a non-`"succeeded"` terminal or
retry-pending state), `outstanding_count` in `recompute_rollout_completion/1` stays > 0
and the rollout is correctly, but from this test's perspective unexpectedly, **not**
marked `"completed"`. Because `recompute_rollout_completion/1` only ever sets
`completed_at` once and never clears it, this failure mode also cannot self-correct
within the same test run.

Lines 358-380 (the `good`/`poisoned` `outcome_for/2`-scoped assertions, and the row
reload at 384-387) are already tenant-scoped and correct as written — no change needed
there.

### 2.2 Tenant-scoped replacement

Do not assert the rollout's global completion status as a hardcoded literal. Instead,
derive the *expected* completion status from the same data the production code itself
uses to decide it — i.e. assert the **invariant** ("the rollout's stored status
correctly reflects its own outcome set") rather than a value that silently assumes a
closed, two-tenant universe:

1. After `resume_rollout/1` returns, independently query every `Outcome` row for
   `first_result.rollout.id` (e.g. `Repo.all(from o in Outcome, where: o.rollout_id ==
   ^first_result.rollout.id)`, or via `MigrationRollout.rollout_status/1` — either is
   acceptable; prefer whichever the file already imports/uses elsewhere for
   consistency).
2. Compute `all_outcomes_succeeded? = Enum.all?(outcomes, &(&1.status == "succeeded"))`
   over that full set (this deliberately includes any swept-in tenant's outcome — the
   point is to match production's own completion rule, not to filter it away).
3. Replace lines 390-391 with:
   - If `all_outcomes_succeeded?` is true: assert
     `resumed_result.rollout.status == "completed"` and
     `resumed_result.rollout.completed_at != nil` (this is expected to be true in the
     overwhelming majority of runs — `good`/`poisoned` are this test's own tenants and
     are proven succeeded by lines 358-372; any swept-in tenant is realistically to also
     resolve to `"succeeded"` since it goes through the same real `apply_outstanding/1`
     path).
   - If `all_outcomes_succeeded?` is false (the race actually fired — a swept-in
     tenant's own outcome did not resolve to `"succeeded"` in this call): assert
     `resumed_result.rollout.status == "running"` (the only other value in
     `Rollout`'s `@statuses`, `rollout.ex:39`) and `resumed_result.rollout.completed_at
     == nil`.

Either branch is a real, non-vacuous assertion on production behavior (the rollout's
status always matches its own outcome set); neither branch depends on how many tenants
happen to exist platform-wide. This keeps EO-004's actual claim — "the corrected
company's re-drive is real, and the already-succeeded company is untouched" — fully
intact (that part of the test is unchanged) while removing the assumption that `good`
and `poisoned` are the *only* tenants that can ever be in scope.

## 3. EO-005 — exact fragile assertions and replacements

Location: `describe "EO-005 ..."` (lines 399-437), test body lines 401-436.

### 3.1 Fragile assertion — first call's blanket success check

Line 410:

```
assert Enum.all?(first_result.outcomes, &(&1.status == "succeeded"))
```

Global over every outcome the first `start_rollout/3` call produced, which includes any
tenant that was concurrently activated during that call's own `active_company_tenant_ids/0`
scan — not just `good_a`/`good_b`. A leaked tenant whose outcome does not succeed breaks
this line even though it has nothing to do with EO-005's own claim.

**Replacement:** scope to the two tenants this test created, following the
`outcome_for/2` precedent already used elsewhere in this file:

```
assert outcome_for(first_result, good_a.tenant_id).status == "succeeded"
assert outcome_for(first_result, good_b.tenant_id).status == "succeeded"
```

### 3.2 Fragile assertion — global row-count "zero writes" claim

Lines 412-413 (captured before the second call) and 434-435 (compared after):

```
rollout_count_before = Repo.aggregate(Rollout, :count, :id)
outcome_count_before = Repo.aggregate(Outcome, :count, :id)
...
assert Repo.aggregate(Rollout, :count, :id) == rollout_count_before
assert Repo.aggregate(Outcome, :count, :id) == outcome_count_before
```

Both aggregates are **unscoped across the entire shared table**, not limited to this
test's own rollout. `Outcome`'s count is the exact mechanism ISSUE-FIXER traced: a tenant
swept into `first_result.rollout.id` during the second `start_rollout/3` call inserts a
brand-new `Outcome` row (`register_and_seed_outcome/5`), changing the global count even
though nothing about *this test's own* rows changed. (`Rollout`'s global count is not
currently known to move under this same race — no other module writes `Rollout` rows —
but asserting a platform-wide count where a rollout-scoped one is available is the same
class of unnecessarily fragile assertion the acceptance criteria ask to remove, and
leaves a latent trap for the next concurrently-written test file that also touches
`Rollout`.)

**Replacement — make both checks self-sufficient and rollout/tenant-scoped:**

1. Replace the `Rollout` global-count check with a direct reload-and-compare of the one
   `Rollout` row this test owns (matches design §8's "direct equality on the loaded
   struct" instruction, already used for `good_row_after` in EO-004 at lines 384-387):

   ```
   rollout_row_before = Repo.get!(Rollout, first_result.rollout.id)
   ...
   assert Repo.get!(Rollout, first_result.rollout.id) == rollout_row_before
   ```

   (This is strictly stronger than the removed global count for THIS rollout, and has
   zero dependency on how many `Rollout` rows exist elsewhere.)

2. Replace the `Outcome` global-count check with a count scoped to the two tenants this
   test created (not just `rollout_id`, since a swept-in tenant would still share this
   test's `rollout_id` — the scoping that actually excludes it is by `tenant_id`):

   ```
   scoped_outcomes_query =
     from o in Outcome,
       where:
         o.rollout_id == ^first_result.rollout.id and
           o.tenant_id in ^[good_a.tenant_id, good_b.tenant_id]

   outcome_count_before = Repo.aggregate(scoped_outcomes_query, :count, :id)  # expect 2
   ...
   assert Repo.aggregate(scoped_outcomes_query, :count, :id) == outcome_count_before
   ```

   Because the query filters to an explicit, small `tenant_id` list this test itself
   created, `==` remains a safe, exact comparison (unlike an unscoped `==` over the whole
   table) — it still proves "no row of mine was added, removed, or duplicated," it just
   no longer makes a claim about tenants this test doesn't control.

### 3.3 Fragile assertion — global already-current check

Line 423:

```
assert Enum.all?(second_result.outcomes, & &1.already_current)
```

`second_result.outcomes` includes any tenant newly swept in during the second call; that
tenant's outcome is, by construction, a **freshly registered** row (not already-current —
`already_current_tenant_ids` in `apply_to_existing_rollout/2`, line 224-228, is computed
from outcomes that existed *before* the sweep). A swept-in tenant therefore always breaks
this line, independent of anything EO-005 itself is testing.

**Replacement:** scope to `good_a`/`good_b`:

```
assert outcome_for(second_result, good_a.tenant_id).already_current
assert outcome_for(second_result, good_b.tenant_id).already_current
```

### 3.4 Assertions already correct — no change

- Lines 415-417 (`completed_at_a_before`, `completed_at_b_before`,
  `rollout_completed_at_before`): already tenant/rollout-scoped via `outcome_for/2` and
  the single `first_result.rollout`.
- Lines 426-427 (`outcome_for(second_result, ...).completed_at ==` before-value):
  already tenant-scoped.
- Line 430 (`second_result.rollout.completed_at == rollout_completed_at_before`): safe as
  written — `recompute_rollout_completion/1` never un-sets `completed_at` once set
  (line 446's `is_nil(rollout.completed_at)` guard), so this equality holds regardless of
  any later sweep-in, without needing further scoping.

## 4. Summary of file-level changes (for TEST-DESIGNER / ELIXIR-DEV — design only, not applied here)

| Location | Current (fragile) | Replacement |
|---|---|---|
| EO-004 L390-391 | Hardcoded `status == "completed"` / `completed_at != nil` | Derive expected status/`completed_at` from an independent query of all outcomes for `rollout_id`; assert the invariant, not a fixed literal |
| EO-005 L410 | `Enum.all?(first_result.outcomes, ...)` (global) | `outcome_for(first_result, good_a.tenant_id)` / `good_b.tenant_id`, scoped |
| EO-005 L412/434 | `Repo.aggregate(Rollout, :count, :id)` (global) | Reload-and-compare the single `Repo.get!(Rollout, rollout_id)` row (struct equality) |
| EO-005 L413/435 | `Repo.aggregate(Outcome, :count, :id)` (global) | `Repo.aggregate/2` scoped to `rollout_id` AND `tenant_id in [good_a, good_b]` |
| EO-005 L423 | `Enum.all?(second_result.outcomes, & &1.already_current)` (global) | `outcome_for(second_result, good_a.tenant_id).already_current` / `good_b.tenant_id`, scoped |

No other lines in either `describe` block need to change. No line in
`lib/letflow/platform/migration_rollout.ex` needs to change.

## 5. Verification plan

Since the race is a narrow, non-deterministic timing window (confirmed by
ISSUE-FIXER's own 3-iteration mixed-load reproduction attempt: 328/328/328 passed, 0
failures — consistent with the mechanism, not proof of its absence), a fix cannot be
"proven" by a single green run. Verification should combine a structural argument with
repeated real-load attempts:

1. **Structural argument (primary evidence).** Every replacement in §2-§3 removes the
   dependency on "no other tenant exists/becomes active" by construction — each
   assertion is re-derived to hold regardless of how many extra tenants
   `active_company_tenant_ids/0` legitimately discovers. This is checkable by re-reading
   the diff against this design without needing to catch a live race: for each replaced
   assertion, confirm no remaining branch reads or compares a value with global
   (all-tenant or all-rollout) scope from `first_result`/`second_result`/`resumed_result`
   except the two invariant-derived branches in §2.2, which are intentionally scope-free by
   design (they assert a rule, not a value).
2. **Repeated real-load re-run (empirical confirmation).** Re-run
   `scripts/test_parallel.sh -N 4` (the same command that produced ISS-0829's original
   failure) at least 3 times after the fix lands, and separately re-run
   ISSUE-FIXER's own repro harness (this test file run concurrently, unpartitioned, with
   the same 9 `TenantFixture`-heavy sibling files for >= 3 iterations with randomized
   seeds) at least once more. Neither run is expected to newly fail EO-004/EO-005 for the
   reason diagnosed here; TEST-RUNNER should report all iterations' pass/fail counts (not
   just "green"), per this project's no-speculation rule.
3. **Regression check.** Confirm EO-001/EO-002/EO-003 and the "queryable outcome record"
   test (lines 215-327) — none of which this design touches — still pass unchanged, to
   confirm no scope creep into working assertions.

## 6. Open questions

None. This design fully resolves ISS-0829's diagnosed defect within the acceptance
criteria's stated scope (EO-004/EO-005 only); it does not attempt to close
`req374-tenant-migration-fanout-runner.md` §9 OQ-1 itself, which remains a legitimate,
already-flagged open product question about `active_company_tenant_ids/0`'s scope in
general platform operation, unrelated to test isolation.
