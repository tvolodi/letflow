# TEST-RUNNER report — WF-03 ISS-0378 Step 5

**Run ID:** WF03-ISS0378-20260830
**Branch:** feature/WF03-ISS0378-20260830 (HEAD ed9ed813 at run start)
**Date (UTC):** 2026-08-30T07:20:00Z

## Diff scope confirmed

`git diff main...HEAD --stat` shows this branch touches only:
`docs/anti-patterns.md`, `docs/status/requirement_status.index.yaml`,
`docs/status/requirement_status.v7.yaml`, `handoffs/WF03-ISS0378-20260830/*`,
`handoffs/registry.json`, `lib/letflow/design/iss0378-poller-ac7-test-fix.md`,
and `test/letflow/scheduler/poller_test.exs` (27 lines). No runtime code
under `lib/letflow/` (other than the design doc) is touched.

## Full suite — `scripts/test_parallel.sh` (N=8)

Ran as a blocking foreground call (process watched to exit via a plain
`while kill -0 <pid>; do sleep 5; done` loop in the same Bash call —
not backgrounded, not polled via Monitor, not left for a cross-turn
notification).

```
partition 1: 353 tests, 3 properties, 0 failures, exit 0
partition 2: 390 tests, 0 properties, 0 failures, exit 0
partition 3: 288 tests, 2 properties, 0 failures, exit 0
partition 4: 303 tests, 1 property, 0 failures, exit 0
partition 5: 359 tests, 0 properties, 0 failures, exit 0
partition 6: 245 tests, 0 properties, 0 failures, exit 0
partition 7: 325 tests, 0 properties, 2 failures, exit 2
partition 8: 361 tests, 0 properties, 0 failures, exit 0
---
combined: 2624 tests, 6 properties, 2 failures (2628/2630 passed)
```

## The 2 failures — diagnosed, not assumed

Both are in `test/mix/tasks/letflow_check_toolchain_test.exs`
(`Mix.Tasks.Letflow.CheckToolchainTest`), "test rust pin (REQ-165)":

```
1) test rust pin (REQ-165) a mismatched rust pin reports a MISMATCH row naming expected and running
   ** (ErlangError) Erlang error: :enoent
   System.cmd("rustc", ["--version"], stderr_to_stdout: true)

2) test rust pin (REQ-165) a matching rust pin reports OK with no mismatch
   ** (ErlangError) Erlang error: :enoent
   System.cmd("rustc", ["--version"], stderr_to_stdout: true)
```

Confirmed directly (not inferred from the error alone): `which rustc` exits
1 in this environment — no rustc binary on PATH at all. The test file's own
comments state the baseline assumption explicitly ("expected `rustc` to be
on PATH while running this suite", lines 276/291). This is the documented
rustc-absent CheckToolchainTest baseline flake class named in this run's own
dispatch instructions — an environment gap, not a code regression, and has
nothing to do with `test/letflow/scheduler/poller_test.exs` or any file this
branch's diff touches.

**Verdict: pre-existing environment flake, excluded from this branch's
regression scope.**

## Targeted run — the files this issue actually changed

```
$ mix test test/letflow/scheduler/poller_test.exs test/letflow/scheduler_test.exs
Result: 23 passed
Finished in 15.4 seconds (0.00s async, 15.4s sync)
```

0 failures.

## Compile check

```
$ MIX_ENV=test mix compile --warnings-as-errors
(clean, exit 0, no warnings)
```

## Conclusion

- Combined full suite: **2628/2630 passed**, 2 failures, both the documented
  rustc-absent `CheckToolchainTest` baseline flake, confirmed via
  `which rustc` and the tests' own `:enoent` traces — unrelated to this
  branch's diff.
- Targeted `poller_test.exs` + `scheduler_test.exs`: **23/23 passed**.
- `mix compile --warnings-as-errors`: clean.
- No real regression found. Routing forward to ISSUE-FIXER for WF-03's
  closing step (Step 5: set `docs/issues/ISS-0378.yaml` status, close
  GH#734 with an evidence comment, release the queue lock).

Full machine-readable report: `test/reports/report-2026-08-30-WF03-ISS0378-20260830.yaml`
