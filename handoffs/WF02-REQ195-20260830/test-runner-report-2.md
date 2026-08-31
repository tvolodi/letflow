# TEST-RUNNER report — rework-1 recheck (WF02-REQ195-20260830)

**Date:** 2026-08-30
**Branch:** feature/WF02-REQ195-20260830
**Preceding handoff:** handoffs/WF02-REQ195-20260830/step-05-test-runner.json (ELIXIR-DEV's rework-1 fix, marked REWORK_APPLIED_READY_FOR_TEST_RUN)

## What this recheck verifies

TEST-RUNNER's prior run (step-04-test-runner.json) found a real regression: the
`audit_entries` tenant-scoped table added by this branch's
`priv/repo/migrations/20260830020001_create_audit_entries_tenant_scoped.exs` was not
reflected in `test/support/tenant_fixture.ex`'s hand-maintained
`@expected_tenant_tables` oracle, so `test/letflow/support/tenant_fixture_test.exs`'s
C6 oracle-rot guard was stale in both the fixture and its companion count assertion
(same bug class as REQ-181's `webhook_subscriptions` gap). ELIXIR-DEV applied a narrow
fix (rework-1) touching only those two test-support files. This report is the
independent full-suite re-verification of that fix.

## Diff scope confirmed

`git diff main...HEAD --stat` (35 files changed) shows only
`test/support/tenant_fixture.ex` (+1 line) and
`test/letflow/support/tenant_fixture_test.exs` (+/-6 lines) changed among test-support
files as a result of the rework — no other test file, and no application code under
`lib/letflow/`, changed as a side effect of the rework-1 fix (the rest of the diff is
this branch's pre-existing REQ-195 audit-entry-storage work: `lib/letflow/audit.ex`,
`lib/letflow/audit/entry.ex`, the migration, and their own new test files
`test/letflow/audit_test.exs`, `audit_capture_test.exs`, `audit_dispositions_test.exs`).

## Full suite run

Environment: Postgres/Keycloak containers were already up
(`letflow-1-postgres-1`, `letflow-1-keycloak-1`; `docker compose up -d` confirmed
running state, no action needed beyond that check). `LETFLOW_DB_PORT=5463` per this
checkout's untracked `.env`. Elixir/mix on PATH via asdf shims.

Ran (blocking, foreground, full run, no backgrounding):

```
source ~/.asdf/asdf.sh
./scripts/test_parallel.sh
```

N=8 partitions (derived from nproc).

```
partition 1: 309 tests, 3 properties, 1 failures, exit 2
partition 2: 416 tests, 2 properties, 0 failures, exit 0
partition 3: 446 tests, 0 properties, 0 failures, exit 0
partition 4: 403 tests, 0 properties, 0 failures, exit 0
partition 5: 393 tests, 0 properties, 0 failures, exit 0
partition 6: 342 tests, 0 properties, 0 failures, exit 0
partition 7: 222 tests, 1 property, 0 failures, exit 0
partition 8: 265 tests, 0 properties, 2 failures, exit 2
---
combined: 2796 tests, 6 properties, 3 failures (2799/2802 passed)
```

**Combined result: 2799/2802 passed, 3 failures.**

## Failure-by-failure diagnosis (Failure Attribution Is Structural, Never By Count-Matching)

### 1. `Letflow.Engine.Lua.ExecutorTest` — "configurable memory limit (REQ-156) AC-1" (partition 1)

```
test configurable memory limit (REQ-156) AC-1: a smaller configured max_heap_words
halts sooner than a larger one on the same allocating script
test/letflow/engine/lua/executor_test.exs:605
the smaller max_heap_words limit (3959.24ms) must halt the allocating script sooner
than the larger limit's full run (465.727ms)
```

Matches the documented REQ-156 Lua wall-clock timing flake class named in this task's
brief: an assertion comparing two measured wall-clock durations across separate
process runs, sensitive to host scheduling noise under parallel load (this run had 8
concurrent partitions competing for CPU). Not caused by, or related to, this branch's
audit-entry or tenant-fixture changes — this test file is untouched by the diff.

### 2 and 3. `Mix.Tasks.Letflow.CheckToolchainTest` — "rust pin (REQ-165)" x2 (partition 8)

```
** (ErlangError) Erlang error: :enoent
    (elixir 1.20.3) lib/system.ex:1141: System.cmd("rustc", ["--version"], ...)
    test/mix/tasks/letflow_check_toolchain_test.exs:69: ...running_rust_raw/0
```

Matches the documented rustc-absent `CheckToolchainTest` baseline flake class named in
this task's brief: this host has no `rustc` binary on PATH, so both tests that shell
out to `rustc --version` fail with `:enoent` regardless of any application change.
Not caused by, or related to, this branch — this test file is untouched by the diff.

**No other failures occurred.** None of the two previously-flagged ISS-0110
`TenantSchemaReaperTest` connection-contention flake or DB pool-exhaustion classes
appeared in this run.

## C6 oracle-rot guard — direct confirmation

`Letflow.Support.TenantFixtureTest` ran inside partition 3, which finished with
**446 passed, 0 failures** (`Result: 446 passed` at the end of that partition's log,
no failure block). The C6 test itself was observed executing and tearing down cleanly:

```
test_module=Letflow.Support.TenantFixtureTest
test_name=:"test C6 -- oracle-rot guard observed tables equal expected_tenant_tables/0 in both directions"
```

with no corresponding failure entry anywhere in partition 3's log. This confirms
ELIXIR-DEV's rework-1 fix (adding `"audit_entries"` to
`test/support/tenant_fixture.ex`'s `@expected_tenant_tables` and bumping
`test/letflow/support/tenant_fixture_test.exs`'s count assertion to 27) resolved the
regression TEST-RUNNER found in the prior pass. No new regression was introduced.

## Conclusion

Combined: **2799/2802 passed**, 3 failures, all three independently diagnosed against
documented recurring flake classes (REQ-156 Lua wall-clock timing x1, rustc-absent
CheckToolchainTest x2) and confirmed unrelated to this branch's diff. The C6
oracle-rot guard passes. No new regression. Routing forward to RELEASE-VALIDATOR per
WF-02 Step 4→5.
