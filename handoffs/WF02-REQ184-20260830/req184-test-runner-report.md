# REQ-184 — TEST-RUNNER report (WF-02 Step 4)

Run date: 2026-08-30
Branch: feature/WF02-REQ184-20260830
Command: `scripts/test_parallel.sh` (N=8, derived from nproc), preceded by `source ~/.asdf/asdf.sh`
DB: postgres containers already running (letflow-1-postgres-1, letflow-1-keycloak-1), LETFLOW_DB_PORT=5463 from repo `.env`. Did not run `docker compose up -d` myself (no docker socket permission for this user outside sudo) since containers were already up and healthy under sudo-managed docker.

## Combined result (all 8 partitions)

```
partition 1: 355 tests, 1 property, 0 failures, exit 0
partition 2: 390 tests, 2 properties, 0 failures, exit 0
partition 3: 392 tests, 2 properties, 0 failures, exit 0
partition 4: 251 tests, 1 property, 0 failures, exit 0
partition 5: 387 tests, 0 properties, 0 failures, exit 0
partition 6: 283 tests, 0 properties, 0 failures, exit 0
partition 7: 294 tests, 0 properties, 0 failures, exit 0
partition 8: 383 tests, 0 properties, 2 failures, exit 2
---
combined: 2735 tests, 6 properties, 2 failures (2739/2741 passed)
```

## Failure diagnosis

Both failures are in partition 8:

```
1) test rust pin (REQ-165) a mismatched rust pin reports a MISMATCH row naming expected and running (Mix.Tasks.Letflow.CheckToolchainTest)
   test/mix/tasks/letflow_check_toolchain_test.exs:289
   ** (ErlangError) Erlang error: :enoent
   System.cmd("rustc", ["--version"], [stderr_to_stdout: true])

2) test rust pin (REQ-165) a matching rust pin reports OK with no mismatch (Mix.Tasks.Letflow.CheckToolchainTest)
   test/mix/tasks/letflow_check_toolchain_test.exs:274
   ** (ErlangError) Erlang error: :enoent
   System.cmd("rustc", ["--version"], [stderr_to_stdout: true])
```

Root cause: `rustc` is genuinely absent from PATH in this execution environment (`which rustc` -> exit 1, confirmed both with and without `source ~/.asdf/asdf.sh`). `Mix.Tasks.Letflow.CheckToolchainTest` shells out to `rustc --version` and gets `:enoent` when the binary doesn't exist at all, which is distinct from a version mismatch the task is designed to detect. This matches the documented "rustc-absent CheckToolchainTest baseline" flake class called out in this run's task brief and is an environment limitation, not application behavior.

**Not caused by this branch.** `git diff main...HEAD --stat` shows this branch touches only:
- `lib/letflow/routers/webhooks.ex`, `lib/letflow/webhooks.ex` (REQ-184 implementation)
- `test/letflow/routers/webhooks_test.exs`, `test/letflow/webhooks_test.exs`, `test/specs/REQ-184.md` (REQ-184 tests)
- `lib/letflow/design/req184-webhook-deliveries-route.md` and various handoff/status docs

No file under `test/mix/tasks/letflow_check_toolchain_test.exs` or any Rust-toolchain-related file is touched by this diff. The failure is a pre-existing environment condition (no `rustc` binary present) unrelated to REQ-184's changes.

## Conclusion

2739/2741 tests passed. The 2 failures are the documented rustc-absent CheckToolchainTest environment baseline, confirmed unrelated to this branch's diff. No real regression found. Routing to RELEASE-VALIDATOR.
