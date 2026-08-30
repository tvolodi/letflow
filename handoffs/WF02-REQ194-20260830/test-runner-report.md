# TEST-RUNNER report — REQ-194 (WF02-REQ194-20260830, Step 4)

## Environment

- Postgres already running (docker container `letflow-1-postgres-1`, healthy, port 5463 per this checkout's untracked `.env` `LETFLOW_DB_PORT=5463`). Did not run `docker compose up -d` myself since the container was already up and this checkout was not told it shares another checkout's container; no action needed.
- Toolchain via `source ~/.asdf/asdf.sh`; `mix`/`elixir` resolved from asdf shims.
- Ran `scripts/test_parallel.sh` in the foreground, blocking, to completion (no backgrounding, no Monitor).

## Combined result

```
test_parallel: N=8 (source: nproc)
partition 1: 457 tests, 0 properties, 0 failures, exit 0
partition 2: 383 tests, 0 properties, 0 failures, exit 0
partition 3: 378 tests, 0 properties, 0 failures, exit 0
partition 4: 203 tests, 1 property, 0 failures, exit 0
partition 5: 284 tests, 0 properties, 2 failures, exit 2
partition 6: 260 tests, 3 properties, 3 failures, exit 2
partition 7: 408 tests, 2 properties, 0 failures, exit 0
partition 8: 398 tests, 0 properties, 0 failures, exit 0
---
combined: 2771 tests, 6 properties, 5 failures (2772/2777 passed)
```

**2772/2777 passed, 5 failures.** All 5 diagnosed below as pre-existing documented flake classes, none touching any file in this branch's diff.

## Branch diff scope (`git diff main...HEAD --stat`)

Touches: `lib/letflow/application.ex`, `lib/letflow/engine.ex`, `lib/letflow/event_store.ex`,
`lib/letflow/metrics/exposition.ex`, `lib/letflow/metrics/registry.ex`,
`lib/letflow/plugs/api_pipeline.ex`, `lib/letflow/plugs/http_metrics.ex`, `lib/letflow/router.ex`,
`lib/letflow/routers/metrics_exposition.ex` (new, replaces deleted `lib/letflow/routers/metrics.ex`),
`lib/letflow/scheduler/poller.ex`, `mix.exs`, plus the corresponding new/updated test files
under `test/letflow/metrics/`, `test/letflow/plugs/`, `test/letflow/routers/`,
`test/letflow/api/authorization_enforcement_test.exs`. None of the 5 failing tests below live in
any of these files or exercise any of these modules.

## Failure diagnosis

### 1–2. `Mix.Tasks.Letflow.CheckToolchainTest` (partition 5) — rustc-absent baseline flake

```
1) test rust pin (REQ-165) a matching rust pin reports OK with no mismatch (Mix.Tasks.Letflow.CheckToolchainTest)
   test/mix/tasks/letflow_check_toolchain_test.exs:274
   ** (ErlangError) Erlang error: :enoent
   stacktrace:
     (elixir 1.20.3) lib/system.ex:1141: System.cmd("rustc", ["--version"], [stderr_to_stdout: true])

2) test rust pin (REQ-165) a mismatched rust pin reports a MISMATCH row naming expected and running (Mix.Tasks.Letflow.CheckToolchainTest)
   test/mix/tasks/letflow_check_toolchain_test.exs:289
   ** (ErlangError) Erlang error: :enoent
```

`which rustc` in this sandbox exits 1 (not on PATH). The test file itself documents the
assumption at `test/mix/tasks/letflow_check_toolchain_test.exs:276`: `assert is_binary(version),
"expected \`rustc\` to be on PATH while running this suite"`. This is the documented
rustc-absent `CheckToolchainTest` baseline flake class named in the task brief — an environment
gap, not a code regression, and unrelated to REQ-194's diff (this test file is untouched by the
branch).

### 3–5. `Letflow.TenantSchemaReaperTest` (partition 6) — ISS-0110 connection-contention flake

```
1) test sweep_orphans/2 concurrent-invocation liveness guard (ISS-0110) spares an old row while
   another invocation's connection is open, reclaims it once that connection closes
   ** (DBConnection.ConnectionError) [] connection not available and request was dropped from
   queue after 4000ms.
   [preceded in the log by:]
   15:55:09.614 [error] Postgrex.Protocol ... failed to connect: ** (Postgrex.Error) FATAL 53300
   (too_many_connections) sorry, too many clients already

2) test sweep_orphans/2 reclaims an old, well-formed orphaned row drops the real schema and
   deletes both rows
   Assertion with >= failed
   code:  assert reclaimed >= 1
   left:  0
   right: 1

3) test sweep_orphans/2 schema_name format guard skips an old row with a malformed schema_name
   instead of attempting a drop
   Assertion with >= failed
   code:  assert skipped >= 1
   left:  0
   right: 1
```

The partition's own log shows the module self-diagnosing this exact condition at the moment of
failure: `TenantSchemaReaper.sweep_orphans/2: deferring this sweep entirely -- another mix test
invocation (application_name != "letflow_mixtest_...") is currently connected to this database,
... (ISS-0110). Retrying on the next boundary sweep.` This is preceded by a genuine
`too_many_connections` Postgrex error — DB connection-pool exhaustion under this run's N=8
parallel-partition load, the other documented flake class named in the task brief. Both are
named explicitly in `test/support/tenant_schema_reaper_test.exs`'s own `describe
"sweep_orphans/2 concurrent-invocation liveness guard (ISS-0110)"` block (line 272) as a known
cross-invocation contention scenario this test module is inherently sensitive to under parallel
load. `test/support/tenant_schema_reaper_test.exs` is untouched by this branch's diff.

No `:wasm_hang` or REQ-156 Lua wall-clock flake occurred in this run.

## Static checks

- `mix compile --warnings-as-errors`: clean, no output, exit 0.
- `mix format --check-formatted`: clean, no output, exit 0.

## Conclusion

All 5 failures are pre-existing, documented, environment-dependent flake classes (rustc absent
from this sandbox's PATH; DB connection-pool exhaustion / ISS-0110 cross-invocation contention
under N=8 parallel partitions) — neither touches any file this branch's diff modifies. REQ-194's
own metrics test files (`test/letflow/metrics/registry_test.exs`,
`test/letflow/metrics/exposition_test.exs`, `test/letflow/plugs/http_metrics_test.exs`,
`test/letflow/routers/metrics_exposition_test.exs`,
`test/letflow/api/authorization_enforcement_test.exs`,
`test/letflow/routers/req078_supporting_routes_test.exs`) all passed in this full run (confirmed
via grep of the module names across all 8 partition logs: they land in partitions 3 and 8, both
exit 0, zero failures). `mix compile --warnings-as-errors` and `mix format
--check-formatted` both pass with real output quoted above, satisfying REQ-194's AC10. Routing
forward to RELEASE-VALIDATOR.
