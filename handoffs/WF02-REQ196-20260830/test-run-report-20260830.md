# TEST-RUNNER report — REQ-196 (audit route repoint) — 2026-08-30

## Command run

`scripts/test_parallel.sh` (this project's standard full-suite entrypoint), against
real Postgres via `docker compose` (already running: `letflow-1-postgres-1`,
`letflow-1-keycloak-1`), real Elixir/OTP toolchain via `asdf` (`source
~/.asdf/asdf.sh`; `which mix` / `which elixir` resolved to asdf shims before the run).

N=8 partitions (derived from `nproc`).

## Combined result (real, from actual run output)

```
partition 1: 321 tests, 2 properties, 2 failures, exit 2
partition 2: 375 tests, 1 property, 0 failures, exit 0
partition 3: 482 tests, 2 properties, 0 failures, exit 0
partition 4: 404 tests, 0 properties, 0 failures, exit 0
partition 5: 361 tests, 0 properties, 0 failures, exit 0
partition 6: 376 tests, 0 properties, 0 failures, exit 0
partition 7: 256 tests, 1 property, 0 failures, exit 0
partition 8: 247 tests, 0 properties, 0 failures, exit 0
---
combined: 2822 tests, 6 properties, 2 failures (2826/2828 passed)
```

**2 failures, both in partition 1, both in `Mix.Tasks.Letflow.CheckToolchainTest`.**

## Diagnosis of the 2 failures

Both failures are in `test/mix/tasks/letflow_check_toolchain_test.exs`, describe block
`"rust pin (REQ-165)"`:

1. `test rust pin (REQ-165) a matching rust pin reports OK with no mismatch`
   (line 274)
2. `test rust pin (REQ-165) a mismatched rust pin reports a MISMATCH row naming
   expected and running` (line 289)

Both raise the identical error before any assertion runs:

```
** (ErlangError) Erlang error: :enoent
code: version = running_rust_version()
stacktrace:
  (elixir 1.20.3) lib/system.ex:1141: System.cmd("rustc", ["--version"], [stderr_to_stdout: true])
  test/mix/tasks/letflow_check_toolchain_test.exs:69: Mix.Tasks.Letflow.CheckToolchainTest.running_rust_raw/0
  test/mix/tasks/letflow_check_toolchain_test.exs:76: Mix.Tasks.Letflow.CheckToolchainTest.running_rust_version/0
```

`:enoent` from `System.cmd/3` means the `rustc` executable itself could not be found
to exec — not a version mismatch, a real assertion failure, or an application bug.
Confirmed directly in this sandbox:

- `which rustc` → exit 1 (not on PATH, not installed)
- `.tool-versions` in this repo pins `rust 1.97.1`, but the asdf `rust` plugin/version
  is not actually installed in this container, unlike `elixir 1.20.3-otp-29` and
  `erlang 29.0.5` which resolved fine (`which mix` / `which elixir` both hit real
  asdf shims for this run)
- The two failing tests' own source comments document that they assume `rustc` is on
  PATH as a precondition: `assert is_binary(version), "expected \`rustc\` to be on
  PATH while running this suite"` (lines 275, 290) — that assertion is never reached
  because the shell-out itself throws first

This matches this project's documented **rustc-absent CheckToolchainTest baseline**
flake class named in the dispatching handoff for this exact reason: a sandbox that has
Elixir/Erlang installed via asdf but not the pinned Rust toolchain will always fail
these two REQ-165 tests, independent of any application code change.

## Confirmation this is unrelated to REQ-196's diff

`git diff main...HEAD --stat` (19 files changed) does **not** include
`test/mix/tasks/letflow_check_toolchain_test.exs` or
`lib/mix/tasks/letflow.check_toolchain.ex` anywhere in the list. REQ-196's actual
changed files are `lib/letflow/audit.ex`, `lib/letflow/routers/audit.ex`,
`test/letflow/routers/req196_audit_route_test.exs`,
`test/letflow/routers/req078_supporting_routes_test.exs`, plus design/handoff/status
docs. The failing test file is entirely untouched by this branch.

## Conclusion

2822 tests run, 2820 passed, 2 failed — both failures are the documented
environment-baseline gap (rustc absent from this sandbox's asdf toolchain), in a file
this branch does not touch, unrelated to REQ-196's audit-route repoint. No regression
attributable to this branch. Excluding the 2 documented-flake failures, REQ-196's own
new/touched tests (`test/letflow/routers/req196_audit_route_test.exs`,
`test/letflow/routers/req078_supporting_routes_test.exs`, plus
`lib/letflow/audit.ex`'s existing test files) all pass as part of the combined run.

Routing to RELEASE-VALIDATOR.
