# TEST-RUNNER report — WF-02 Step 4 — REQ-195

run_id: WF02-REQ195-20260830
branch: feature/WF02-REQ195-20260830
agent: TEST-RUNNER
date_utc: 2026-08-30

## Environment

- Toolchain: asdf-managed Elixir 1.20.3 / Erlang/OTP 29, not on PATH by default in this
  shell — `source ~/.asdf/asdf.sh` required (same shell-init quirk noted in prior runs'
  reports, not a repo issue).
- `mix deps.get`: succeeded, network reachable this run (some dependency security
  advisories printed — pre-existing, unrelated to this branch).
- Postgres: `letflow-1-postgres-1` (port 5463, per this workspace's untracked `.env`
  `LETFLOW_DB_PORT=5463`) and `letflow-1-keycloak-1`, both already `Up`/healthy;
  confirmed/restarted via `sudo docker compose up -d` (this user's own docker socket is
  permission-denied; passwordless sudo available).
- `rustc`/`cargo`: absent from PATH in this sandbox (confirmed by the CheckToolchainTest
  failure below, same class documented in prior REQ-181/REQ-177/REQ-178 runs).

## Command run

`scripts/test_parallel.sh` (N=8 partitions, derived from `nproc`), run in the foreground,
blocked on until completion — not backgrounded, not polled via Monitor.

## Result — real, quoted combined output

```
test_parallel: N=8 (source: nproc)
partition 1: 309 tests, 3 properties, 3 failures, exit 2
partition 2: 416 tests, 2 properties, 0 failures, exit 0
partition 3: 446 tests, 0 properties, 1 failures, exit 2
partition 4: 403 tests, 0 properties, 0 failures, exit 0
partition 5: 393 tests, 0 properties, 0 failures, exit 0
partition 6: 342 tests, 0 properties, 0 failures, exit 0
partition 7: 222 tests, 1 property, 0 failures, exit 0
partition 8: 265 tests, 0 properties, 2 failures, exit 2
---
combined: 2796 tests, 6 properties, 6 failures (2796/2802 passed)
```

Full partition logs retained at (session-local) `/tmp/letflow_test_parallel.Ef2pD6/partition-{1..8}.log`.

## Diff scope (confirmed before attributing any failure)

`git diff main...HEAD --stat` — this branch touches:
`lib/letflow/audit.ex`, `lib/letflow/audit/entry.ex`, `lib/letflow/definitions.ex`,
`lib/letflow/engine.ex`, `lib/letflow/engine/task_activation.ex`, `lib/letflow/identity.ex`,
`lib/letflow/tasks.ex`, `lib/letflow/tenant_provisioning.ex`,
`priv/repo/migrations/20260830020001_create_audit_entries_tenant_scoped.exs`,
`test/letflow/audit_test.exs`, `test/letflow/audit_capture_test.exs`,
`test/letflow/audit_dispositions_test.exs`, plus design/handoff/doc/status files. No
change to `test/support/tenant_fixture.ex` or `test/letflow/support/tenant_fixture_test.exs`.

## Per-failure diagnosis (structural attribution, not count-matching)

### 1–3. `Letflow.TenantSchemaReaperTest` (partition 1) — PRE-EXISTING FLAKE, not this branch

- `sweep_orphans/2 concurrent-invocation liveness guard (ISS-0110) ...` — `assert reclaimed >= 1` got `0`
- `sweep_orphans/2 schema_name format guard ...` — `assert skipped >= 1` got `0`
- `sweep_orphans/2 reclaims an old, well-formed orphaned row ...` — `assert reclaimed >= 1` got `0`

All three log the module's own diagnostic line verbatim: `TenantSchemaReaper.sweep_orphans/2:
deferring this sweep entirely -- another mix test invocation ... is currently connected to
this database ... (ISS-0110). Retrying on the next boundary sweep.` This is the documented
ISS-0110 connection-contention flake (8-way parallel `mix test` partitions share one Postgres
instance; another partition's live connection makes this partition's reaper defer its sweep,
so the assertion that a sweep reclaimed/skipped a row legitimately sees 0). `test/support/tenant_schema_reaper_test.exs`
is not in this branch's diff. Attribution: route 1 (file not touched) + route 3 (measured
mechanism — the module's own log line names the exact contention condition). Not a
regression from this branch.

### 4. `Mix.Tasks.Letflow.CheckToolchainTest` — rust pin tests ×2 (partition 8) — PRE-EXISTING ENVIRONMENTAL GAP, not this branch

```
** (ErlangError) Erlang error: :enoent
    (elixir 1.20.3) lib/system.ex:1141: System.cmd("rustc", ["--version"], [stderr_to_stdout: true])
    test/mix/tasks/letflow_check_toolchain_test.exs:69: ...running_rust_raw/0
```

`rustc`/`cargo` are genuinely absent from PATH in this sandbox — identical failure class to
the REQ-181/REQ-177/REQ-178 runs' documented rustc-absent baseline
(`docs/anti-patterns.md`'s toolchain-drift entries). `test/mix/tasks/letflow_check_toolchain_test.exs`
is not in this branch's diff. Attribution: route 1 (file not touched) + route 3 (measured —
`which rustc cargo` returns nothing). Not a regression from this branch.

### 5. `Letflow.Support.TenantFixtureTest` — C6 oracle-rot guard (partition 3) — GENUINE DEFECT IN THIS BRANCH

```
1) test C6 -- oracle-rot guard observed tables equal expected_tenant_tables/0 in both directions (Letflow.Support.TenantFixtureTest)
   test/letflow/support/tenant_fixture_test.exs:382
   a manifest migration created a table the oracle does not list: ["audit_entries"]
   code: assert observed -- expected == [],
```

This branch adds `priv/repo/migrations/20260830020001_create_audit_entries_tenant_scoped.exs`,
a tenant-scoped migration (`if prefix() do ... end` guard, per Decision 0003-B, confirmed by
reading the migration file's own header comment) creating the `audit_entries` table inside
every tenant schema. `test/support/tenant_fixture.ex`'s `@expected_tenant_tables` (lines
122–150) is the hand-maintained oracle of every table a fully-migrated tenant schema should
contain — it currently lists 26 tables and was **not** updated to add `"audit_entries"`, and
`test/letflow/support/tenant_fixture_test.exs:305`'s companion count assertion
(`assert length(TenantFixture.expected_tenant_tables()) == 26`) was not bumped to 27 either.

This is not a new failure mode: the identical class of bug (a new tenant-scoped table added
without updating this same oracle) occurred on REQ-181 (`webhook_subscriptions` missing) and
was routed back to ELIXIR-DEV in `test/reports/report-2026-08-29-WF02-REQ181-20260829.yaml` —
that report also notes REQ-176 and REQ-125 both correctly bumped this same list/count when
they added a tenant-scoped table, confirming this is an established, previously-followed
convention that this branch's implementation step missed.

Attribution: route 4 (failing test not itself in the diff, but causally connected to a file
that IS in the diff — the new migration). Reproduced standalone:
`mix test test/letflow/support/tenant_fixture_test.exs` → confirmed same single failure,
same assertion, isolated from the rest of the suite (not order-dependent).

**This is a real regression from this branch and blocks forward routing to RELEASE-VALIDATOR.**

## Skip / order-dependency check (per step-04 acceptance criteria)

`grep -rn "@tag :skip" test/letflow/audit_test.exs test/letflow/audit_capture_test.exs test/letflow/audit_dispositions_test.exs`
→ no matches, no skipped tests in the three REQ-195 test files. All three files use
`Letflow.DataCase`'s sandboxed-Ecto pattern (per-test checkout/rollback) and their own
per-test tenant/fixture setup — no shared hardcoded fixture state or inter-test ordering
dependency observed in the full-suite run (these files' tests were interleaved across
multiple partitions alongside hundreds of other tests and all passed).

## Disposition

NOT routing to RELEASE-VALIDATOR. One genuine regression (item 5 above) requires an
ELIXIR-DEV fix: add `"audit_entries"` to `test/support/tenant_fixture.ex`'s
`@expected_tenant_tables` list and bump `test/letflow/support/tenant_fixture_test.exs`'s
count assertion (line 305) from 26 to 27. Rework handoff written to
`handoffs/WF02-REQ195-20260830/step-05-elixir-dev-rework1.json`.

The 5 other failures (3× ISS-0110 TenantSchemaReaperTest, 2× CheckToolchainTest rustc-absent)
are documented pre-existing flake/environmental classes, confirmed structurally unrelated to
this branch's diff, and excluded from blocking.
