# REQ-113 — `scripts/test_parallel.sh` (parallel test runner via `mix test --partitions`)

Design for a dev-pipeline shell script, not an R-Co port (see REQ-113's own
description and `docs/migration/decisions/0008-cross-cutting-tooling-stage-and-doc-
ownership.md`). No implementation code below — behavior contract, flow, and exact
parsing rules only. Precedent for shell-tooling conventions in this repo:
`scripts/timed_test.sh` (POSIX `sh`, `set -eu` with deliberate `set +e` islands
around subprocess calls whose exit code must be captured rather than aborting the
script, a documented rationale comment block at the top, `printf`-based output
rather than bash-only constructs).

## 1. Scope recap

Builds `scripts/test_parallel.sh`, per the requirement's five BUILD steps:
1. Pre-compile `MIX_ENV=test` once.
2. Launch N `MIX_TEST_PARTITION=<i> mix test --partitions N` background processes,
   N derived from `nproc`/platform equivalent or a configured default.
3. Wait for all N to finish.
4. Aggregate each partition's own reported pass/fail/failure counts into one
   combined total.
5. Exit non-zero if any partition failed, zero only if all passed.

Out of scope (REQ-114): wiring this script into any `docs/agents/workflows/*.md`
step or `TEST-RUNNER`/`RELEASE-VALIDATOR` role instructions.

## 2. Prerequisite facts this design relies on (verified against Mix's own source)

### 2.1 Partitioning requires `MIX_TEST_PARTITION`

`mix test --partitions N` requires `MIX_TEST_PARTITION` to be set to an integer in
`1..N` for the run to be partitioned at all — confirmed by reading
`lib/mix/tasks/test.ex` in the pinned Elixir 1.20.3/OTP 29 toolchain (the same
logic exists in every installed Elixir this session could inspect): `partitioned? =
is_integer(partitions) and partitions > 1`, and when `partitioned?` is true, Mix
reads `System.get_env("MIX_TEST_PARTITION")` and raises
(`"The MIX_TEST_PARTITION environment variable must be set..."`) if it is absent or
out of range. `config/test.exs` line 21 already keys the per-partition database
name off this same env var (`database:
"letflow_test#{System.get_env("MIX_TEST_PARTITION")}"`), which is the existing
mechanism this script drives — no new config needed. Partition indices are
**1-based** (`1..N`, not `0..N-1`) — this is load-bearing for the launch loop in
§4.2.

### 2.2 Mix's actual exit-code contract for `mix test` (corrected — REWORK ITERATION 1)

**This subsection replaces an incorrect assumption in the design's original
version** (RELEASE-VALIDATOR, WF02-REQ113-20260821 step 5): the original §4.6
assumed exit `1` meant "ExUnit failures" and exit `2` meant "some other/
compile-time error class" it declined to distinguish. Reading
`lib/mix/tasks/test.ex` in the actually-installed 1.20.3-otp-29 toolchain shows
this is backwards. The relevant logic (`run/1`'s `cond`, plus
`exit_status_opts/1`):

- `exit_status_opts(opts)` does `Keyword.put_new(opts, :exit_status, 2)` — the
  **default** configured exit status for "the suite had failures" is `2`, not `1`.
  This repo's `test:` alias in `mix.exs` (`["ecto.create --quiet",
  "ecto.migrate --quiet", "test"]`) never passes `--exit-status` to override this
  default, so `2` is the real, in-effect value for every partition this script
  launches.
- When `config.failure_counter > 0` (i.e. `failures > 0` in `run/1`'s `cond`), Mix
  registers `System.at_exit(fn _ -> exit({:shutdown, exit_status}) end)` — so a
  partition with any real ExUnit failures exits with the configured `exit_status`,
  i.e. **`2`** in this repo, not `1`.
- If `warnings_as_errors?` is also true **and** both `warnings?` and `failures > 0`,
  the exit code is `exit_status + 1` (`3` in this repo) instead. This repo's `test:`
  alias does not pass `--warnings-as-errors` to the `test` step (only the separate
  `letflow.check` alias's `compile --warnings-as-errors` step does, which this
  script never invokes), so this branch does not apply to partitions launched by
  `scripts/test_parallel.sh`.
- When `config.failure_counter == 0`, none of the `System.at_exit`-registering
  branches in the `cond` fire; the task falls through to `true -> :ok` and returns
  normally with no exit-code override — i.e. a clean partition's own `run/1` logic
  never asks for anything other than the OS-default `0`.
- Exit `1` is not produced anywhere in this `cond` at all. It is Mix's generic
  `Mix.raise`-driven abort code (used elsewhere in the CLI for a bad
  `--partitions` value, a missing/out-of-range `MIX_TEST_PARTITION`, a compile
  error before `test_helper.exs` even loads, etc.) — cases where the run never
  reaches `print_summary/2` and therefore has no `"Result:"`/`"Failed:"` lines in
  its log at all.

**Net correction:** in this toolchain, `2` is a partition's *normal* "I found real
ExUnit failures" exit code, not an unrelated error class — and `1` (when it occurs)
means the partition never produced a parseable summary at all (compile/config
abort), not "ExUnit failures." §4.5's aggregation and §4.6's exit contract are
rewritten below to use the parsed failure count as the authoritative success
signal precisely because relying on raw exit codes alone conflates these cases —
see §4.6's note on the one exit-`2`-with-zero-parsed-failures anomaly
RELEASE-VALIDATOR's clean run actually hit, which this source reading alone does
not fully explain.

## 3. Script inputs / overridable knobs

| Name | Kind | Default | Behavior |
|---|---|---|---|
| `TEST_PARALLEL_N` | env var | unset | If set to a positive integer, overrides partition-count derivation entirely (§4.1 step 0). Explicit configured-default escape hatch required by AC4. |
| `nproc` / platform equivalent | shell command | — | Used to derive N when `TEST_PARALLEL_N` is unset (§4.1). |
| `"$@"` (script positional args) | pass-through | none | Forwarded verbatim to every partition's `mix test` invocation (e.g. `--seed`, a path filter). Same pass-through convention as `scripts/timed_test.sh`'s `mix test "$@"`. Not required by any acceptance criterion; included only because omitting it would make the script strictly less useful than plain `mix test` for a developer who wants to filter. If this is judged out of scope, ELIXIR-DEV/REVIEWER should flag it — see Open Questions §9. |

No other configuration surface. The script takes no flag for the log directory or
DB naming — those are derived, not configurable, per §4.

## 4. Flow

### 4.1 Step 0 — derive N (maps to AC4)

Order of resolution, first match wins:
1. `TEST_PARALLEL_N` env var, if set and a positive integer — used as-is, no
   further derivation. This is the "or a configured default" branch of BUILD
   item (2).
2. `nproc` (Linux — the only platform this repo's CI/dev hosts run on per
   `docs/guides/backend_developer_guide.md`'s §1 tool list, which names no
   non-Linux target). If the `nproc` binary is not found, fall back to
   `getconf _NPROCESSORS_ONLN` (POSIX-portable, present on both Linux and macOS)
   before giving up.
3. If neither resolves (should not happen on any supported host, but the script
   must not silently divide by an empty string), hard-fail with a clear stderr
   message and exit 1 rather than defaulting to an unstated hardcoded number —
   there is no silent numeric fallback here, which is what keeps AC4's "never
   hardcoded" true in the failure path too, not just the happy path.

The resolved N is echoed to stdout once, near the top of the run
(`"test_parallel: N=<value> (source: env override|nproc|getconf)"`), so a reader of
the demonstrated run's output (AC4/AC5 evidence) can see where N came from without
reading the script.

### 4.2 Step 1 — pre-compile once (maps to AC5)

Exactly one subprocess call, before any partition is launched:
`MIX_ENV=test mix compile`. Its exit code is captured (same `set +e` /
`set -e` bracketing pattern as `scripts/timed_test.sh`'s compile phase). If
nonzero, the script prints the failure and exits with that same code
immediately — no partition process is ever launched on a failed compile. This is
the concrete mechanism that prevents the concurrent-compile race the requirement's
background section describes: every `MIX_TEST_PARTITION=<i> mix test --partitions N`
invocation launched in step 2 sees an already-current `_build/test` and performs no
compilation of its own beyond Mix's own is-anything-stale check, which — because
nothing is stale — is a no-op read, not a write, so N concurrent Mix instances
never race to write the same `_build/test` artifacts.

### 4.3 Step 2 — launch N background partitions

A temporary working directory is created via `mktemp -d` (e.g.
`/tmp/letflow_test_parallel.XXXXXX`) to hold per-partition log files — not under
`scripts/` or `test/`, so no repo-tracked output is produced by a normal run. For
each partition `i` in `1..N` (shell `for i in $(seq 1 "$N")`), the script launches
one `mix test` invocation as a background job: the `MIX_TEST_PARTITION` environment
variable is set to that partition's 1-based index `i`, the command is invoked with
the `--partitions N` and `--no-color` flags, and both its stdout and stderr are
redirected to that partition's own log file under the temporary directory (named by
partition index, e.g. `partition-<i>.log`).

- `--no-color` is explicit and required — without it, ExUnit's `CLIFormatter`
  decides on ANSI color codes based on `IO.ANSI.enabled?/0`, which is not
  guaranteed to be false just because stdout is redirected to a file in every
  shell/OS combination this script might run under. The aggregation step (§4.5)
  parses plain text; color escape codes must not be a variable it has to account
  for.
- The PID of each backgrounded process is captured into a positional array/list
  keyed by partition index (`pid_1`, `pid_2`, ... or a POSIX-`sh`-compatible
  equivalent — bash arrays are fine since `scripts/` has no stated POSIX-`sh`-only
  constraint the way `timed_test.sh`'s `#!/bin/sh` shebang implies; ELIXIR-DEV
  picks `bash` or `sh` and states which, since `$(seq ...)` plus PID-array
  bookkeeping is materially simpler in `bash`. Flagged as an open question, §9).

### 4.4 Step 3 — wait for all N to finish

`wait "$pid_i"` for each partition in index order, capturing each one's exit code
into `exit_i`. Using `wait` per-PID (not a bare `wait` with no argument) is
required so each partition's own exit code is individually recoverable — a bare
`wait` only reports whether *any* backgrounded job is still running, not each
one's status.

### 4.5 Step 4 — aggregate (maps to AC1, AC2)

For each partition's log file, extract the final ExUnit summary by pattern, not by
assuming a fixed line number (log files may contain `IO.puts` output from other
sources, e.g. `Letflow.TenantSchemaReaper.sweep_orphans()` in
`test/test_helper.exs`, ahead of the real summary).

**Exact shape parsed — corrected (REWORK ITERATION 1).** The design's original
version cited a single `"<N> tests, <M> failures"`-style line that this pinned
Elixir 1.20.3/OTP 29 toolchain's actually-installed `cli_formatter.ex` does not
produce (confirmed both by reading `print_summary/2`,
`format_passed_breakdown/3`, and `format_type_counts/1` directly, and by real
captured output from RELEASE-VALIDATOR's two live runs). The real summary is
**two separate lines**, not one:

1. A "passed" line, **always present**, of the form:
   - `Result: <passed> passed` — when every test in the run passed (no `/total`
     split at all), e.g. `Result: 1274 passed`, `Result: 115 passed`.
   - `Result: <passed>/<total> passed` — when at least one test failed, e.g.
     `Result: 13/14 passed`.
   - `Result: 0 tests` — degenerate empty-run edge case (should not occur for a
     real partition of this suite; if seen, treat as `0` passed/`0` total and flag
     the WARNING in the cross-check below rather than crashing).
   - Followed, **only when the run had more than one distinct test type** (e.g.
     both `property` and `test` cases ran in that partition), by a parenthesized
     per-type breakdown: `" (<n> <type>, <n> <type>, ...)"`, sorted alphabetically
     by type name. Each entry is `"<total> <type>"` when everything passed (e.g.
     `(5 properties, 1269 tests)`) or `"<passed>/<total> <type>"` when something in
     that run failed (e.g. `(2/5 properties, 115/117 tests)`). **When only one
     type ran in that partition, this parenthetical is omitted entirely** — this
     is the case that produces a bare `Result: 115 passed` with nothing after it,
     which the original design's regex (which required a `"failures?"` substring
     unconditionally) could never match, silently parsing every partition as
     `0 tests, 0 failures` regardless of what actually ran.
   - The passed line may additionally carry trailing `", N invalid"`,
     `", N skipped"`, `", N excluded"` clauses after the breakdown (unchanged from
     before) — still not needed for this script's counts.
2. A "failed" line, present **only when `failures > 0` for that partition** — on a
   fully clean partition this line does not exist at all, anywhere in the log,
   which is precisely why the original regex's mandatory `"failures?"` substring
   requirement produced a false `0`/`0`/`0` reading unconditionally rather than
   only when genuinely appropriate. Shape: `Failed: <n> <type>[, <n> <type>...]`,
   e.g. `Failed: 1 test`, `Failed: 2 properties, 1 test`.

**Parsing rule:**
- Locate the passed line: the last line in the log matching
  `^Result: ` (grep -E `^Result: `, take the last match — defensive against
  incidental earlier output, same rationale as before).
  - If it matches `^Result: ([0-9]+)/([0-9]+) passed`, `passed_i` = group 1,
    `total_i` = group 2.
  - Else if it matches `^Result: ([0-9]+) passed`, `passed_i` = `total_i` =
    group 1.
  - Else (the `"Result: 0 tests"` edge case) `passed_i` = `total_i` = `0`.
  - If the line contains a parenthesized breakdown, extract each `"<count(/total)?>
    <type>"` entry (types expected in this repo: `propert(y|ies)`, `tests?`) to
    populate `properties_i`/`tests_i` individually, using each entry's own total
    (the number after `/` if present, else the bare count).
  - If **no** parenthesized breakdown is present, exactly one type ran in that
    partition. This design attributes it to `tests_i = total_i`, `properties_i =
    0` — the far more common case (a partition with a nonzero test count and zero
    properties), documented as an explicit assumption rather than silently
    guessed: see §9 OQ-2b. A partition that ran *only* property-based tests and
    zero plain tests would be mis-attributed by this rule; flagged, not expected
    given this suite's real ratio (5 properties vs. 1269 plain tests baseline —
    every partition should contain plain tests too).
- Locate the failed line, if any: the last line matching `^Failed: ` (grep -E).
  If absent, `failures_i = 0`. If present, sum every `(\d+)` that immediately
  precedes a `propert(y|ies)|tests?` token on that line to get `failures_i` (e.g.
  `Failed: 2 properties, 1 test` → `failures_i = 3`).
- Sanity check per partition: `passed_i + failures_i` should equal `total_i`; a
  mismatch feeds the cross-check below rather than being silently accepted.

**Aggregation (AC2's "actually sums... rather than only checking the process
exited"):**
- `total_properties = sum(properties_i for i in 1..N)`
- `total_tests = sum(tests_i for i in 1..N)` (this repo's own report convention
  in `test/reports/*.yaml` treats "tests" as inclusive of properties in some
  summaries and exclusive in others — see §9 OQ-2; this script reports both the
  per-type breakdown and a grand total so the ambiguity is visible rather than
  silently resolved one way)
- `total_failures = sum(failures_i for i in 1..N)`
- `total_passed = total_properties + total_tests - total_failures`

**Cross-check (defense in depth, still part of AC2's "aggregation actually sums"
requirement, not merely trusting exit codes) — corrected per §2.2's exit-code
finding.** Per §2.2, this toolchain's real exit contract is: `0` = clean
(`failure_counter == 0` and no other abort), the configured `exit_status`
(**`2`** in this repo, since `test:` never overrides it) = ExUnit failures present,
and any other code (in practice `1`, `Mix.raise`-class) = an abort that never
reached `print_summary/2` at all (no `Result:` line in the log). For each
partition:
- `exit_i == 0` and `failures_i == 0` → consistent clean pass, no warning.
- `exit_i == 2` and `failures_i > 0` → consistent failure, no warning.
- No `Result:` line found in the log at all (regardless of `exit_i`, though this
  case is expected to pair with `exit_i == 1`) → treated as failed unconditionally
  — this is a compile/config/crash abort, not something the parsed-count fields
  can speak to.
- `exit_i == 2` and `failures_i == 0` (a `Result:` line **was** found, cleanly, with
  no `Failed:` line) → this is the anomaly RELEASE-VALIDATOR's clean run actually
  hit on a genuinely-passing partition; per §2.2's source reading, `run/1`'s `cond`
  only reaches the `exit_status`-tagged `System.at_exit` path via `failures > 0`,
  so this combination is not explained by `lib/mix/tasks/test.ex` alone. Rather
  than silently declare it universally safe, the script prints an explicit
  `"test_parallel: WARNING partition <i> exit 2 but 0 parsed failures (see design
  §2.2/§9 OQ-5)"` line (visible, not swallowed) but does **not** count the
  partition as failed — `failures_i`, parsed directly from ExUnit's own summary
  output, is treated as the authoritative success signal for §4.6's exit contract
  precisely because it is immune to whatever produced this exit-code artifact,
  and AC3's intent ("exits non-zero on any partition **failure**") is about actual
  test failures, not an unexplained-but-0-failure exit class. See §9 OQ-5 for the
  follow-up instrumentation this still warrants.
- Any other `exit_i`/`failures_i` combination not covered above → prints the same
  style of `"test_parallel: WARNING partition <i> exit code / parsed count
  mismatch"` line and **is** counted as failed for §4.6 (unchanged conservative
  default from the original design for genuinely-unrecognized cases).

**Output shape** (printed to stdout after all partitions finish, this is the
artifact AC1/AC2's demonstration runs quote):

```
partition 1: 315 tests, 0 properties, 0 failures, exit 0
partition 2: 381 tests, 1 property, 0 failures, exit 0
partition 3: 262 tests, 0 properties, 0 failures, exit 0
partition 4: 263 tests, 4 properties, 4 failures, exit 2
---
combined: 1221 tests, 5 properties, 4 failures (1222/1226 passed)
```

(Illustrative numbers only — not asserted values; the real demonstration run
produces real ones per §5. Partition 4's `exit 2` here is deliberate, not a typo:
per §2.2, `2` is this toolchain's real "had ExUnit failures" exit code, not `1`.)

### 4.6 Step 5 — exit-code contract (maps to AC3) — corrected (REWORK ITERATION 1)

**Success signal is `failures_i` (§4.5's parsed count), not raw `exit_i`.** The
original design collapsed `exit_i` values directly into the script's own exit
code; RELEASE-VALIDATOR's real run demonstrated that is not reliable on this
toolchain (§2.2/§4.5's cross-check: a genuinely 0-failure partition can exit `2`
for a reason source reading alone did not fully explain). The corrected contract:

- If every partition's `failures_i == 0` **and** every partition has a `Result:`
  line in its log (no unconditional-failure abort case per §4.5's cross-check):
  the script exits `0`, regardless of any individual `exit_i` value (including
  the exit-`2`-with-zero-failures anomaly, which is logged as a WARNING per §4.5
  but does not flip this to non-zero).
- If any partition's `failures_i > 0`, OR any partition has no `Result:` line at
  all (compile/config/crash abort), OR the §4.5 cross-check's "any other
  combination" catch-all fires for any partition: the script exits `1`.
- As before, the script does not attempt to reproduce `mix test`'s own full
  exit-code granularity (`0`/`1`/`2`/`3` per §2.2) in its own exit code — it
  collapses everything to `0` (all-clear, by parsed failure count) vs. `1`
  (something needs attention), which is what AC3 asks for ("exits non-zero when
  at least one partition fails ... exits zero when all partitions pass") and does
  not overspecify beyond it. What changed from the original design is *which
  signal* feeds that collapse — parsed failure count, not raw exit code.

## 5. Evidence plan for the two demonstration runs (AC1, AC3)

Both are ELIXIR-DEV/TEST-RUNNER build-time actions (running the finished script),
not something this design doc performs — this section specifies exactly what must
be captured so the acceptance criteria are checkable from the run transcript
without rerunning anything.

**AC1 (same combined totals, partitioned vs single-process):**
1. On the same commit, run plain `mix test` once (single-process baseline) and
   capture its final `"Result: ..."` (and `"Failed: ..."`, if present) lines
   verbatim, per §2.2/§4.5's corrected real format.
2. Run `scripts/test_parallel.sh` and capture its `combined:` line (§4.5's output
   shape) verbatim.
3. Quote both verbatim lines side by side in the run's report
   (`test/reports/report-<date>-WF02-REQ113-20260821.yaml`, following this repo's
   existing report schema — see `test/reports/report-20260820-WF02-REQ066-
   20260820.yaml` for the shape) and confirm `total_tests + total_properties` and
   `total_failures` match between the two runs. A mismatch is not automatically a
   script bug — the two runs execute against different database instances
   (`letflow_test` vs `letflow_test1..N`) and the known-flaky ISS-0048/0050/0060/
   0062/0064 class may produce a different failure count between any two runs of
   this suite regardless of partitioning (per REQ-113's own text, this class is
   explicitly not something this requirement's acceptance criteria may assert is
   fixed). The report must say which case occurred, not silently assume match.

**AC3 (exit-code contract, clean vs deliberately-failing):**
1. Clean run: run `scripts/test_parallel.sh` against the unmodified suite, quote
   the real exit code (`echo $?`) and the tail of its stdout (the per-partition
   lines + combined line). Expect exit `0`.
2. Deliberately-failing run: introduce exactly one failing test (e.g. a temporary
   `assert 1 == 2` added to any existing test file — reverted immediately after
   this demonstration, never committed), rerun the script, quote the real exit
   code and output tail again. Expect the **script's own** exit code `1` (per
   §4.6's collapsed contract); the **modified partition's own** raw `exit_i` is
   expected to be `2` per §2.2 (this toolchain's real ExUnit-failure exit code),
   not `1` — the per-partition breakdown must show that partition's `failures`
   count as `1` (or the file's partition-assignment-dependent count), not just a
   nonzero script exit — this is what ties AC3's evidence to AC2's aggregation
   rather than treating them as independent claims.

## 6. DB / migration impact

None. No new Ecto schema, no migration, no new table/column. The script only
orchestrates existing `mix test` invocations against the per-partition database
naming `config/test.exs` already implements (`letflow_test#{MIX_TEST_PARTITION}`).
Each partition's `letflow_test<i>` Postgres database is created/migrated by the
existing `mix test` alias chain (`ecto.create --quiet`, `ecto.migrate --quiet`,
`test` — see `lib/mix/tasks/letflow.check.test.ex`'s moduledoc, which documents
this alias resolution) exactly as it already is for the current single-process
`MIX_TEST_PARTITION`-suffixed run; this script does not special-case database
provisioning.

## 7. Cross-module dependencies

- `config/test.exs` line 21 (`database:
  "letflow_test#{System.get_env("MIX_TEST_PARTITION")}"`) — read-only dependency,
  unchanged by this requirement.
- `test/test_helper.exs`'s `Letflow.TenantSchemaReaper.sweep_orphans()` calls (both
  pre- and post-suite) — each partition process runs its own copy of
  `test_helper.exs`, so each partition independently sweeps orphaned tenant
  schemas in its own `letflow_test<i>` database. No cross-partition interaction;
  flagged only so ELIXIR-DEV doesn't need to re-derive this from scratch.
- `lib/mix/tasks/letflow.check.test.ex` — a sibling tool, not a dependency. Not
  reused or modified by this script (it wraps a single non-partitioned `mix test`
  and gates on a specific warning substring, an orthogonal concern). No shared
  code between the two; noted here only to head off a reviewer wondering why they
  don't share a helper.

## 8. Invariants

- The script must never launch a partition process before the single pre-compile
  step (§4.2) has exited `0`.
- The script must never hardcode a partition count anywhere in its body (AC4) —
  every numeric literal that could be mistaken for a hardcoded N must trace to
  either the `TEST_PARALLEL_N` override or the `nproc`/`getconf` derivation.
- The script's own exit code must be a pure function of the N partitions' parsed
  `failures_i` counts (§4.5/§4.6, corrected in REWORK ITERATION 1 — not raw
  `exit_i` alone, per §2.2's finding that a genuinely 0-failure partition can
  legitimately or anomalously exit `2` on this toolchain) — it must never exit `0`
  while any partition's log shows `failures_i > 0`, and it must never exit `0`
  while any partition's log has no parseable `Result:` line at all.
- The script does not delete or truncate any `letflow_test<i>` database itself
  (that remains the existing `ecto.create`/`ecto.migrate` alias's job, run
  per-partition-process as today).

## 9. Open questions (not silently resolved)

- **OQ-1 — `bash` vs POSIX `sh`.** `scripts/timed_test.sh` uses `#!/bin/sh` and
  stays POSIX-portable. This script needs PID-indexed bookkeeping across N
  background jobs and (for the `--no-color`/log-parsing convenience) arithmetic
  and array-like structures that are materially easier in `bash` than POSIX `sh`.
  Recommend `#!/usr/bin/env bash` for this script specifically (a deviation from
  `timed_test.sh`'s precedent, not a silent inconsistency) since `bash` is present
  on every host this repo's guide names (`docs/guides/backend_developer_guide.md`
  §1 lists Docker/Elixir/Postgres, implicitly a Linux dev host with `bash`
  available). ELIXIR-DEV should confirm this choice explicitly in the
  implementation's own header comment (mirroring `timed_test.sh`'s rationale-
  comment convention) rather than picking silently.
- **OQ-2 — "tests" total inclusive or exclusive of "properties" in the combined
  report line.** This repo's own historical TEST-RUNNER reports are inconsistent
  on this point (`"Result: 1216/1230 passed (5/5 properties, 1211/1225 tests)"` —
  here 1230 = 1225 tests + 5 properties, i.e. the headline total is the sum, but
  some older reports write a bare `"325 passed"` with no breakdown at all). This
  design's §4.5 reports both the per-type breakdown and an explicit grand total
  rather than picking one convention, so ELIXIR-DEV does not need to guess which
  historical convention to match — but if TEST-RUNNER/RELEASE-VALIDATOR (a later,
  out-of-scope-here concern per REQ-114) later need one canonical single number,
  that convention should be decided when REQ-114 wires this script into their
  workflow steps, not here.
- **OQ-3 — pass-through args (`"$@"`).** See §3's table entry. Not required by any
  acceptance criterion; flagged so REVIEWER can confirm it's in-scope-enough to
  keep (it costs one line: `"$@"` appended to the per-partition `mix test`
  command) or should be dropped for strict minimality.
- **OQ-4 — log file retention.** §4.3 puts per-partition logs in a `mktemp -d`
  temp directory, which is transient by design. If a later requirement wants a
  persisted `test/reports/`-style artifact, that's a REQ-114-or-later concern
  (ties into OQ-2) — not built here, since REQ-113's acceptance criteria only ask
  for a demonstrated run's output to be quoted, not for a permanent artifact file.
- **OQ-2b — single-type parenthetical omission attributed to `tests_i`.** New in
  REWORK ITERATION 1, see §4.5: when a partition's `Result:` line has no
  parenthesized breakdown (i.e. only one test type ran in that partition), this
  design attributes the whole count to `tests_i` and sets `properties_i = 0`,
  since that is overwhelmingly the likely case given this suite's real ratio
  (5 properties vs. 1269 plain tests at baseline). A partition that happened to
  run properties-only with zero plain tests would be mis-attributed by this rule.
  Not expected in practice with the current partition counts and test
  distribution, but ELIXIR-DEV/TEST-RUNNER should note it if a future partition
  count or suite change makes it possible.
- **OQ-5 — the exit-`2`-with-zero-parsed-failures anomaly is still not root-caused.**
  New in REWORK ITERATION 1. RELEASE-VALIDATOR's clean run hit a partition that
  genuinely had `failures_i == 0` (verified by direct grep of its raw log) yet
  exited `2`. §2.2's source reading of `lib/mix/tasks/test.ex` shows the
  `exit_status`-tagged `System.at_exit` path is only reachable when
  `config.failure_counter > 0` — so this specific combination is not explained by
  that file alone. §4.5's cross-check makes the design robust to it either way
  (treats it as non-fatal, since `failures_i` is the authoritative signal), so
  this does not block REQ-113, but the true root cause (a stale `System.at_exit`
  hook from a prior invocation in the same OS process? something in
  `ExUnit.after_suite`'s `Letflow.TenantSchemaReaper.sweep_orphans()` call
  interacting with the exit path? a `wait "$pid_i"`/`$?` capture-ordering bug in
  the script itself rather than in Mix?) is still open. Recommend ELIXIR-DEV add
  an `echo "exit=$?"` immediately after each partition's own `mix test`
  invocation, written into that same partition's log file, on the first real
  build — so if this recurs, the next investigation has an in-log data point
  instead of needing to re-derive from scratch.

## 10. Acceptance-criteria-to-design-element map

1. **AC1** (same combined totals as baseline, demonstrated) → §5 "AC1" procedure +
   §4.5's `combined:` output line as the exact artifact quoted, parsed per §4.5's
   corrected `Result:`/`Failed:` grammar (REWORK ITERATION 1).
2. **AC2** (aggregation actually sums per-partition parsed counts) → §4.5's full
   parsing/summing/cross-check specification, with the exact ExUnit output shapes
   sourced from reading the installed `cli_formatter.ex`'s `print_summary/2`,
   `format_passed_breakdown/3`, and `format_type_counts/1` (corrected citation,
   REWORK ITERATION 1 — the original version cited a shape this toolchain does
   not produce).
3. **AC3** (non-zero exit on any partition failure; zero on all-pass, both
   demonstrated) → §4.6 exit-code contract (corrected to use parsed `failures_i`
   as the authoritative signal, not raw `exit_i`, per §2.2's exit-code
   investigation, REWORK ITERATION 1) + §5 "AC3" procedure (deliberately
   introduce and revert one failing test).
4. **AC4** (N derived from `nproc`/platform equivalent or configured default,
   never hardcoded) → §4.1 (three-step resolution order, explicit no-silent-
   fallback failure mode) + §8's invariant restating it.
5. **AC5** (pre-compile `MIX_ENV=test` exactly once before any partition) → §4.2,
   plus §4.1's ordering (compile is step 1, launch is step 2, never reordered) and
   §8's invariant.
6. **AC6** (lives under `scripts/`, not `lib/`/`test/`) → §1 states the path
   (`scripts/test_parallel.sh`) directly, matching the `scripts/timed_test.sh`
   precedent cited throughout this document.
