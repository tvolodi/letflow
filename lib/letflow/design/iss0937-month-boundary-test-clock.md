# ISS-0937 fix design: make the retention and tenant-template-parity tests independent of the real UTC month

Run: WF03-ISS0937-20261001. Author: CODE-DESIGNER. Input: ISSUE-FIXER diagnosis
(`handoffs/WF03-ISS0937-20261001/step-01-issue-fixer-diagnose.json`, `result.summary`).
Scope: tests and test support only. `lib/` and `priv/repo/migrations/` are unchanged.

## 0. Diagnosis verified against the worktree

The diagnosis holds. Nothing in the code contradicts it, so the fix stays test-only.

| Claim | Verified at |
|---|---|
| Production rule: `eligible?(y, m)` is `Date.utc_today() >= first_day_of_next_month(y, m) + min_partition_age_days()` | `lib/letflow/event_store/partition_maintenance.ex:360-364` (`month_bounds/2` returns the next month start; `Date.add(.., min_partition_age_days())`; `Date.compare(today, cutoff) != :lt`) |
| Cause A fixture: last calendar month, with `min_partition_age_days` overridden to 1 | `partition_maintenance_test.exs:237` (`eligible_past_month`), `:195-198` (`current_month`); `retention_operations_test.exs:143`, `:122-125`; `routers/event_retention_test.exs:71-74` |
| Cause A arithmetic | For M = last month, the cutoff is the 2nd of the current month. Today >= cutoff is false only when today is the 1st. This is not October-specific: every 1st of every month fails. |
| Cause B | `test/support/tenant_template.ex:1207-1222` (`check_table_set/2`) filters `req376_partition_management_table?/1` only out of `missing`. `extra` is unfiltered. |
| Date dependence of the partition tables | Migration `20260922000002_create_events_p_initial_partitions.exs` creates `events_yYYYYmMM` from the date at RUN time. A template built in month N and a reference replayed in month N+1 hold different dynamic partition tables. |
| Fingerprint carries no date | `migration_fingerprint_comment/0` is an md5 of the sorted migration version list only. A stale-month template therefore stays `:current` in a reused test DB. |
| Predicate already exists | `test/support/tenant_fixture.ex:408-421`: `req376_partition_management_table?/1` = fixed list (`events_default`, `events_archive_default`, two `*_pre_partition_20260922`) OR regex `^events(_archive)?_y\d{4}m(0[1-9]\|1[0-2])$`. |

Two corrections to the handoff's `owned_modules`:

1. `test/support/tenant_template_test.exs` already exists and is run (the existing parity tests live at `:93` and `:108`). The parity regression tests are therefore ADDED to it. The file is not new.
2. To filter only the dynamic month tables (see section 2) a public dynamic-only predicate is needed. It goes in `test/support/tenant_fixture.ex`, which the handoff did not list. It is added to `owned_modules`.

## 1. Shared pure helper (cause A)

### 1.1 Module and signature

- File: `test/support/partition_clock.ex` (new). It is compiled under `elixirc_paths(:test)` with the other `test/support/` modules. It is not referenced from `lib/`.
- Module: `Letflow.Test.PartitionClock`. It is a plain module with no process and no I/O. It never calls `Date.utc_today/0` itself.
- Public function:
  - `eligible_past_month(today :: Date.t(), min_partition_age_days :: pos_integer()) :: {year :: integer(), month :: 1..12}`
  - `@spec eligible_past_month(Date.t(), pos_integer()) :: {integer(), 1..12}`
- Optional public helper, exposed so the three test files can drop their three copies of the same arithmetic:
  - `@spec shift_months({integer(), 1..12}, integer()) :: {integer(), 1..12}`
  - Same arithmetic as the existing private copies: `total = year*12 + (month-1) + offset`, then `{div(total, 12), rem(total, 12) + 1}`.
  - This dedup is optional. Each test file's `shift_months/2` is also used for non-eligibility offsets (`+1`, `+3..5`). The implementer may leave the local copies alone. It must not change their behavior either way.

### 1.2 Exact offset rule and why

Eligibility of month M is: `first_of_next(M) + N <= today`, where N is `min_partition_age_days`.

Define `d = today - N days`. For a first-of-month date F, `F <= d` holds iff `month(F) <= month(d)`. Setting `first_of_next(M) = first_of_month(month(d))` gives the latest eligible month:

> `M = shift_months(month_of(Date.add(today, -N)), -1)`

Properties:

- Always eligible for every `today` and every N >= 1. The cutoff of M is `first_of_month(month(d)) + N`. That is <= today by construction, since `first_of_month(month(d)) <= d = today - N`.
- Maximal. M+1 is NOT eligible, because `first_of_next(M+1)` is past `d`. The test in section 3.1 asserts this so the offset is not silently over-conservative.
- Worked examples with N = 1:
  - today = 2026-10-01: d = 09-30, M = 2026-08. The old rule gave 2026-09, which was ineligible. This is the bug.
  - today = 2026-10-02: d = 10-01, M = 2026-09.
  - today = 2026-10-31: d = 10-30, M = 2026-09.
  - today = 2027-01-01: d = 2026-12-31, M = 2026-11.
  - Leap day 2028-03-01: d = 02-29, M = 2028-01.
- Why "last month" was wrong: it assumed `today - 1 day` is still in the current month. That is false exactly when today is the 1st.

Safe direction on midnight crossing. The test reads `today` at fixture time. Production reads `Date.utc_today()` later, inside `retire_month`. If midnight passes between the two reads, production's today is later, so eligibility only becomes more true. No race in the unsafe direction.

### 1.3 Call-site changes (all three files)

Each file keeps a local zero-arity `eligible_past_month` wrapper, so existing call sites such as `eligible_past_month()` are untouched. The wrapper body becomes a delegation to `PartitionClock.eligible_past_month/2`, passing `Date.utc_today()` and the integer value used in that file's `with_event_retention_override([min_partition_age_days: 1], ...)`. Use a module attribute such as `@override_age_days 1`, so the override and the helper argument cannot diverge.

| File | Change |
|---|---|
| `test/letflow/event_store/partition_maintenance_test.exs` | `eligible_past_month` (`:237`) delegates. `current_month` and `shift_months` stay: they are used for non-eligibility offsets and for "current month is NOT eligible" at `:893`. Add `alias Letflow.Test.PartitionClock`. |
| `test/letflow/event_store/retention_operations_test.exs` | `eligible_past_month` (`:143`) delegates. `shift_months(eligible_past_month(), -3)` at `:217` stays valid, since an older month is also eligible. |
| `test/letflow/routers/event_retention_test.exs` | `eligible_past_month` (`:71-74`) delegates. |

## 2. `check_table_set/2` change (cause B)

### 2.1 What is filtered

Ignore the DYNAMIC calendar-month partition tables on BOTH sides, before computing `missing` and `extra`. Dynamic means the regex `^events(_archive)?_y\d{4}m(0[1-9]|1[0-2])$`.

Mechanics (pseudocode only):

- `ref_tables` and `cand_tables` are each rejected through a new dynamic-only predicate.
- `missing = ref \ cand`. The existing reject through the full `req376_partition_management_table?/1` stays, because a `:clone` candidate legitimately lacks the fixed tables as well.
- `extra = cand \ ref`, over the already-filtered sets.

Why dynamic-only and not the full predicate on both sides. The four fixed tables (`events_default`, `events_archive_default`, and the two `*_pre_partition_20260922`) are NOT date-dependent. Both sides of use site 1 (template vs an independent `replay_migrations/2` reference) have them. Filtering them from both sides would silently remove real drift detection (a missing or extra fixed table). The existing `missing`-side filter stays as is, for the `:clone` candidate case.

New predicate, in `test/support/tenant_fixture.ex`:

- `@spec req376_dynamic_partition_table?(String.t()) :: boolean()`
- True iff the name matches the existing `@req376_dynamic_partition_table_pattern`.
- `req376_partition_management_table?/1` is re-expressed as `name in fixed list or req376_dynamic_partition_table?(name)`. This keeps ONE regex, with no copy in `tenant_template.ex`, so the oracle cannot drift.
- Behavior of the existing predicate is unchanged. `tenant_fixture_test.exs:423` still exercises it.

### 2.2 What must still fail

A non-partition extra table still raises. For example a candidate table `widgets_extra`, or even `events_extra`, does not match the regex, so it stays in `extra` and produces `table set: extra=["widgets_extra"]`. Names that match only partly (`events_y2026m13`, `events_y26m09`, `eventsx_y2026m09`) are not filtered. Section 3.2 asserts this.

### 2.3 Comment correction

The block comment above `check_table_set/2` (`tenant_template.ex:1195-1207`) says that pre-filtering `ref_tables` would make the candidate's real copies look like false "extra" tables. That is wrong when the same filter is applied to BOTH sides. Applying it to both removes the table from both sets, so there is no false extra. Rewrite the comment to say:

- The `missing` side is filtered with the full predicate, for the `:clone` case.
- The dynamic month tables are filtered from both sides, because their names depend on the date the migration ran.
- The fixed tables are deliberately kept in the comparison.

### 2.4 Fingerprint (decision: do NOT change it)

Recommendation: leave `migration_fingerprint_comment/0` as is, with no month stamp. Reasons:

1. After 2.1, a stale-month template cannot cause a parity failure. Dim #1 is the only dimension that saw the dynamic tables as a difference. Dims 2-13 already reject them at `:1371`, `:1447`, `:1466`.
2. Adding the UTC month to the fingerprint would drop and rebuild the template (a full ~53-migration replay) once per month in every reused test DB. That is a cost, and the CI template is rebuilt per run anyway.
3. A date in the fingerprint would add a new wall-clock dependency to the test infrastructure. That is the class of defect this fix removes.

## 3. Fail-first regression tests

### 3.1 Eligibility oracle

- File: `test/support/partition_clock_test.exs` (new; `test/support/` tests are already run, as `tenant_template_test.exs` shows).
- `use ExUnit.Case, async: true`. Pure, no DB, no `Date.utc_today/0`.
- A private test oracle `eligible?(m, today, n)` reimplements the production rule independently (DIRECTIVE T-4): `Date.compare(today, Date.add(first_day_of_next_month(m), n)) != :lt`.
- Tests:
  1. `"eligible_past_month/2 is eligible for every day of 2024-01-01..2027-12-31 and every N in [1, 2, 7, 31, 400]"`. Iterates `today` over all 1461 days (48 months, includes leap day 2024-02-29 and 2028-style boundaries, every 1st and 2nd). For each pair, asserts the oracle says eligible.
  2. `"eligible_past_month/2 is the latest eligible month (the next month is not eligible)"`. Same iteration. Asserts the oracle says `shift_months(M, +1)` is NOT eligible, so the offset is not over-conservative.
  3. `"regression: legacy derivation (last calendar month, N=1) is ineligible on the 1st of every month"`. Iterates `today` over 2026-01-01..2027-12-31 (24 months). Asserts the oracle says the legacy month `shift_months(month_of(today), -1)` is ineligible exactly when `today.day == 1`, and eligible when `today.day >= 2`. This pins the original bug and proves the oracle is sensitive to it.
  4. `"explicit boundary dates"`. Table of the fixed worked examples from 1.2 (2026-10-01 to 2026-08, 2026-10-02 to 2026-09, 2026-10-31 to 2026-09, 2027-01-01 to 2026-11, 2028-03-01 to 2028-01) with exact `{year, month}` expected values.
  5. `"retention test files do not use the legacy last-month derivation"`. Source scan. For the three test files in 1.3, `File.read!` each and assert:
     - it contains `PartitionClock.eligible_past_month(`;
     - it contains none of `shift_months(current_month(), -1)` and `shift_months({today.year, today.month}, -1)`.
- Fail-first. On pre-fix code, `Letflow.Test.PartitionClock` does not exist, so tests 1, 2 and 4 fail. Test 5 fails because the three files contain the legacy derivation. Test 3 documents the bug in pure date arithmetic. Every one of them yields the same result regardless of the real date.

### 3.2 Parity unit test with two hand-built schemas

- File: `test/support/tenant_template_test.exs` (EXISTING; add a new `describe "ISS-0937 -- dynamic month partition tables are ignored on both sides of the table-set dimension"`).
- Uses the file's existing `setup` (Sandbox `:auto`) and `Letflow.DataCase`. Each test builds two throwaway schemas through `Repo.query!` with unique names (for example `"iss0937_ref_<System.unique_integer([:positive])>"` and `"iss0937_cand_<...>"`), each holding hand-created plain tables. It calls the PUBLIC `TenantTemplate.assert_clone_parity!(ref, cand, dimensions: [1])`. Dimensions are restricted to #1, so other differences cannot interfere. Both schemas are dropped `CASCADE` in an `after` / `on_exit`. Names are fixed literals (`events_y2026m09`, `events_y2026m10`); no wall-clock is read. `tables_in/1` lists BASE TABLEs from `information_schema`, so plain tables are enough.
- Tests:
  1. `"stale dynamic partition on the candidate side is not reported as extra"`. ref = `{shared_t, events_y2026m10, events_y2026m11}`; cand = `{shared_t, events_y2026m09, events_y2026m10}`. Asserts `:ok`. Pre-fix this raises `extra=["events_y2026m09"]`, independent of the date.
  2. `"dynamic partition only on the reference side is not reported as missing"`. The mirror image; asserts `:ok`.
  3. `"events_archive dynamic partitions are ignored on both sides"`. `events_archive_y2026m09` on the candidate and `events_archive_y2026m10` on the reference; asserts `:ok`.
  4. `"a non-partition extra table still raises"`. cand has `widgets_extra`; asserts `ExUnit.AssertionError` whose message contains `table set: extra=["widgets_extra"]`.
  5. `"names that are not valid month partitions are not ignored"`. cand has `events_y2026m13`; asserts a raise that mentions `events_y2026m13`. (A second run with `events_y26m09` can be a loop inside this test.)
  6. `"a fixed partition-management table missing from the candidate is still reported when both sides are replay-built (use site 1 semantics)"`. Documents that `events_default` is not filtered from the `extra` side: cand has `events_default`, ref does not; asserts a raise. This pins the "dynamic-only" decision from 2.1. Note that the missing-side filter still hides `events_default` on the ref side, by existing design; assert only the extra direction.
- The two existing real-replay tests at `:93` and `:108` are unchanged. They now pass on any date.

## 4. Comment corrections

| File and place | Correction |
|---|---|
| `partition_maintenance_test.exs:234-237` | "always eligible ... regardless of which day" is wrong for last month. Replace with a pointer to `PartitionClock.eligible_past_month/2` and its rule: the latest month M with `first_of_next(M) + N <= today`. |
| `partition_maintenance_test.exs:51` (moduledoc) | "`today >= last_day(month) + min_partition_age_days`" is inexact. The production rule is `today >= first_day_of_next_month + min_partition_age_days` (equivalently `last_day + 1 + N`). Fix the formula. |
| `retention_operations_test.exs` and `event_retention_test.exs`, near the helper | Add a one-line comment pointing to `PartitionClock` and noting that last month is NOT eligible on the 1st. |
| `tenant_template.ex:1195-1207` | See 2.3. |
| `tenant_template.ex` `check_table_set/2` neighbor comment about "the migration runs at RUN time" | Add a sentence explaining that the dynamic partition names are date-dependent, which is why they are ignored on both sides. |
| `PartitionClock` moduledoc (new) | States the rule, the derivation of 1.2, and that the module is pure with the clock injected by the caller. |

## 5. Audit of other clock-sensitive sites

Grep scope: `shift_months`, `current_month`, `Date.utc_today`, `events_y`, `eligible_past_month`, and `DateTime.utc_now` / `NaiveDateTime.utc_now` combined with partition or retention, across `test/`.

| Site | Verdict |
|---|---|
| `partition_maintenance_test.exs:237` `eligible_past_month` | CHANGE (section 1). |
| `retention_operations_test.exs:143` `eligible_past_month` | CHANGE. |
| `event_retention_test.exs:71-74` `eligible_past_month` | CHANGE. |
| `partition_maintenance_test.exs:430-436` (`ensure_future_partitions` expects `current_month` +3..+5) | OK. It compares to the same `Date.utc_today()` that production uses for the future window, and it creates nothing past-dated. The residual risk is a midnight crossing at a month boundary inside one test run, which is inherent and not part of this issue. |
| `partition_maintenance_test.exs:493, :782` (`mid_month_timestamp(cy, cm)` for the current month) | OK. These use the current month for a "live data" row; no eligibility is involved. They are clock-relative on purpose. |
| `partition_maintenance_test.exs:893-899` (current month ineligible under the real 400-day default) | OK. 400 days is far from the boundary on any date; this test passed on 2026-10-01. |
| `partition_maintenance_test.exs:904` (`year + 50` partition_not_found) | OK. Not date-edge sensitive. |
| `partition_maintenance_test.exs:832` (`far_future_ts` = now + 3650 days) | OK. A far-future offset has no boundary. |
| `retention_operations_test.exs:237, 279` (`DateTime.utc_now()` seeded events) | OK. They seed `keep_forever` and policy rows with the current time and do not rely on eligibility (title: "unaffected by min_partition_age_days"). |
| `retention_operations_test.exs:217-218`, `:306`, `:346`, `:407` | Covered by the single-helper change; each consumes `eligible_past_month()`. |
| `event_store_test.exs:861` (`ten_days_ago`), `scheduler/poller_test.exs` and others using `DateTime.add(DateTime.utc_now(), -N days)` | OK. They are relative offsets with no partition or month-boundary dependence. A grep for `events_y` and partition APIs finds no other consumer. |
| `test/letflow/support/tenant_fixture_test.exs:411-423` | OK. It filters through `req376_partition_management_table?/1`, which is unchanged in behavior. |
| `test/letflow/event_store/migrations_test.exs`, `schemas_test.exs`, `definitions/*migrations_test.exs` | OK. They use fixed literals, with comments that forbid wall-clock use. |
| Other `test/` hits for `DateTime.utc_now()` / `NaiveDateTime.utc_now()` | Not partition- or retention-related; no month-boundary derivation. Confirmed none need change. |

Conclusion: exactly three eligibility sites (cause A) plus `check_table_set/2` (cause B). No other site derives "last month" or depends on partition eligibility.

## 6. Acceptance-criteria map

| Criterion | Element |
|---|---|
| Every diagnosis cause has a concrete change | A to sections 1 and 1.3. B to sections 2.1-2.4. |
| Helper signature and `@spec` given | 1.1. |
| Fail-first tests specified independent of real date | 3.1 and 3.2 (pure arithmetic and fixed-name schemas; no wall-clock). |
| All clock-sensitive sites audited | Section 5. |
| No implementation code, no `lib/` changes | This document contains signatures and pseudocode only; `lib/` is untouched except this design file. |
| `owned_modules` final | Section 7. |

## 7. Final `owned_modules`

- `test/support/partition_clock.ex` (new)
- `test/support/partition_clock_test.exs` (new)
- `test/support/tenant_template.ex` (`check_table_set/2` and comments)
- `test/support/tenant_template_test.exs` (EXISTING; add the ISS-0937 describe)
- `test/support/tenant_fixture.ex` (add `req376_dynamic_partition_table?/1`; re-express the existing predicate through it)
- `test/letflow/event_store/partition_maintenance_test.exs`
- `test/letflow/event_store/retention_operations_test.exs`
- `test/letflow/routers/event_retention_test.exs`

## 8. Open questions and limits (stated, not guessed)

1. No production clock seam. `eligible?/2` reads `Date.utc_today()` directly and is private. The three DB-backed retention test files therefore cannot be pinned to an arbitrary date. Their date-independence is established by the pure oracle in 3.1 plus the source scan in test 5. Adding a seam would change `lib/` and is out of scope.
2. The DB-backed retention tests pass on any non-1st day even before the fix. Only the pure tests in 3.1 and the parity tests in 3.2 fail fail-first on every date. This is stated so the validators do not assume otherwise.
3. A run that crosses a UTC month boundary mid-run (CI run 36793410900 did) can still, in principle, affect `ensure_future_partitions` expectations at `partition_maintenance_test.exs:430`. After this fix, template parity is immune, but the rollover-inside-a-run case is not otherwise handled and is not a goal.
4. The diagnosis could not explain why runs 36793256609 and 36793096870 failed within 1-2 minutes before rollover. This design does not address them.
5. Main's CI state on `ed40c2fa` was undecided at diagnosis time; ORCH should confirm it before merge. It does not change the design.

## 9. Proposed anti-pattern entry (text only; do not write to `docs/anti-patterns.md` from this step)

Title: `A test hard-coded "last calendar month" as always eligible for an age-gated rule, so it failed on the 1st of every month (2026-10-01, CODE-DESIGNER, ISS-0937)`

**What happened.** Tests for partition retirement overrode `min_partition_age_days` to 1 and used the previous calendar month as a fixture that is "always eligible regardless of day". Production eligibility is `today >= first_day_of_next_month + N`. For last month the cutoff is the 2nd of the current month, so the fixture was ineligible on the 1st of every month. CI went red at the 2026-09-30/2026-10-01 rollover, with `{:error, :partition_not_eligible}` in three test files. Separately, a table-set parity check filtered date-dependent `events_yYYYYmMM` partition tables only from the `missing` side, so a template built in September and a reference replayed in October disagreed.

**Why it is wrong here.** A passing run on 30 days of the month does not prove a date-derived fixture is safe; the failure appears only on specific days. The comment claiming "always eligible" was never checked against the production rule. `PartitionMaintenance.eligible?/2` reads `Date.utc_today()` directly, so nothing else would have exposed it.

**Correct alternative.** Derive time-gated fixtures from an injected `today` through one shared pure helper (`Letflow.Test.PartitionClock.eligible_past_month/2`) and prove it by iterating `today` over at least 24 months, including every 1st and 2nd, against an independently written oracle. When a comparison involves names generated from the run date, filter those names from BOTH sides symmetrically rather than from one side only.
