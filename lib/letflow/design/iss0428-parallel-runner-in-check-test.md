# ISS-0428 — Adopt `scripts/test_parallel.sh` inside `mix letflow.check.test`

**Issue:** ISS-0428 (queue task 428, GH#832)
**Stage:** S6 (tooling/pipeline-throughput, not application code)
**Owner (implementation):** ELIXIR-DEV
**Pipeline:** WF-03 (issue resolving) — CODE-DESIGNER → CODE-DESIGN-VALIDATOR →
ELIXIR-DEV → SECURITY-REVIEWER (n/a, no tenant-data path touched, but the workflow's
own gate list is followed) → REVIEWER → TEST-DESIGNER → TEST-DESIGN-VALIDATOR →
TEST-RUNNER → RELEASE-VALIDATOR → DOC-UPDATER
**Date:** 2026-09-04

This design touches only `lib/mix/tasks/letflow.check.test.ex` (rewrite of its internal
mechanics) and, if the selection mechanism below needs one, a small addition to
`mix.exs`'s existing `letflow.check` alias comment block. **It does NOT touch
`.github/workflows/ci.yml`** — see §3's reasoning for why a CI file edit is unnecessary,
matching the precedent `adoption_notes.test_parallel_adoption_point` in ISS-0423
already recorded (REQ-136: CI runs exactly one `mix letflow.check` step; changing what
that step does, internally, changes CI behavior with no workflow edit).

---

## 0. Facts this design is built on (independently measured this session, superseding ISS-0428's own filed figures)

Measured on this host, same commit, both runs to completion, after clearing stale
template-clone state and orphaned `erl.exe` processes (ISS-0427's template-clone work
already landed, which is why these numbers differ from the issue's own 1805s/616s
baseline — that baseline predates ISS-0427):

| Run | Wall clock | Result |
|---|---|---|
| Serial (`mix test`) | 1466s | 3211/3217 (6 failures, all `Letflow.ServiceCatalogTest` — the ISS-0409/ISS-0414-documented cross-test-isolation-flaky file, not attributable to serial mode itself) |
| `TEST_PARALLEL_N=2` | 774s | 3214/3214 clean |
| `TEST_PARALLEL_N=16` (default, this host) | ~300s | 3213/3213 clean |

**N=2 is CI's actual parallelism** (`ubuntu-latest` = 2 vCPU) and measures **1.89x,
clean** — no crashes, no `too_many_connections`, partitions balanced at 765s/690s. This
directly contradicts ISS-0428's own filed pessimism (`ci_gives_almost_nothing` in
ISS-0423, and ISS-0428's own body: "the 2.9x measured at N=16 does NOT transfer" and
warned adoption might trade "a slow-but-green gate for a fast-but-flaky one"). The
connection-exhaustion failure mode ISS-0219/ISS-0222 documented needs N well above what
a 2-vCPU host's budget forces (per decision 0009's own clamp arithmetic, a low N gets a
*generous* per-partition pool, not a starved one) — it does not arise at N=2.

**This measurement is the load-bearing fact that changes every downstream design
decision below.** ISS-0428's own suggested shape (selectable runner, CI stays on plain
`mix test` "until measured") was written *before* N=2 was actually measured clean. It
now is. Design decisions in §3 follow from this directly.

---

## 1. The ISS-0069 gate — re-pointing at per-partition logs (THE central risk)

### 1.1 The hazard, restated precisely

`Mix.Tasks.Letflow.Check.Test.run/1` today (`lib/mix/tasks/letflow.check.test.ex:76-104`)
does two things in one pass over one subprocess's captured output:

1. Treats nonzero exit from `mix test` as a real test failure → `Mix.raise`.
2. Greps the **captured combined stdout+stderr** of that single subprocess for the fixed
   substring `"default values for the optional arguments"` (ISS-0069 Part 2) →
   `Mix.raise` even if exit was 0.

`scripts/test_parallel.sh` runs N *separate* `mix test --partitions N` subprocesses,
each redirected to its own log file (`$tmp_dir/partition-$i.log`), and prints only
**aggregated pass/fail counts** to its own stdout — never the constituent partitions'
raw text. If `run/1` is changed to shell out to `test_parallel.sh` and grep *its*
stdout for the substring, the check becomes unreliable to the point of uselessness —
it would catch a warning only by accident, and miss every warning emitted during the
partition runs themselves.

**PRECISION CORRECTION (CODE-DESIGN-VALIDATOR gate, MAJOR).** An earlier draft of this
section claimed the aggregate stdout "finds nothing, forever." That is factually wrong
and the correction matters, because a rationale that overstates its case invites a
future reader to dismiss the whole concern. `scripts/test_parallel.sh` line 99 runs
`MIX_ENV=test mix compile` **unredirected** as its Step 1, so a compile-time warning
emitted by that single pre-compile *does* reach the wrapper's stdout — the validator
verified this directly, observing the injected warning appear there exactly once.

What is genuinely true, and is what this design actually relies on: warnings emitted
**during the N partition runs** go only to the per-partition logs, and Mix's
compile-manifest behaviour means a warning may be re-emitted per partition build while
appearing in the aggregate at most once, or not at all. So grepping the aggregate is
not a *guaranteed* vacuous pass — it is an unreliable one, which is worse in a
different way: it would sometimes catch a warning and sometimes not, making a silent
regression look like a flake. The algorithm below never reads the aggregate for this
purpose, so its correctness does not depend on which of these two framings is right. This is exactly the failure class `docs/anti-patterns.md` already documents
repeatedly for ISS-0069 recurrences, and the same shape ISS-0427's own parity check
shipped blind to once already (named explicitly in the dispatch as the precedent to not
repeat).

### 1.2 Design: read N per-partition logs, not the wrapper's aggregate stdout

`run_main_suite/0` (replacing today's first branch of `run/1`) must:

1. Invoke the parallel runner as a subprocess **the same way `stream_and_capture/2`
   invokes `mix test` today** (`Port.open({:spawn_executable, ...})`, streaming live +
   capturing), passing it `scripts/test_parallel.sh` as the executable. Streaming its
   own stdout is still useful for a human/agent watching the run live, but **that
   captured stream is no longer what the substring check reads.**
   - **ORDERING RULE (CODE-DESIGN-VALIDATOR gate, MINOR).** When BOTH the wrapper
     exits non-zero AND the partition-log-dir line is absent, report the WRAPPER'S
     NON-ZERO EXIT first. This is not cosmetic: the common real case is a `mix compile`
     failure inside `test_parallel.sh`, which exits at its Step 1 before ever printing
     the log-dir line (verified by the gate). Reporting "partition logs line missing"
     there would send an agent hunting a nonexistent log-parsing bug instead of reading
     the compile error that actually happened. Both orderings fail safely — this rule is
     about which message an agent sees first, and in a humanless pipeline that is the
     difference between a two-minute fix and a wasted run.

2. Parse the runner's own stdout (still captured, per step 1) for the line
   `test_parallel: partition logs in <dir>` — this exact line already exists in
   `scripts/test_parallel.sh` (unconditionally printed, never behind a flag, confirmed
   by reading the script) and is the only mechanism available to discover `<dir>`,
   since it is a fresh `mktemp -d` path generated at runtime and cannot be predicted or
   fixed in advance.
   - **Error shape if this line is absent or unparseable:** treat as a hard failure of
     the check itself (`Mix.raise` with a message naming the missing line), never a
     silent "nothing to check" pass-through. A future edit to `test_parallel.sh` that
     removes or rewords this line must break `check.test` loudly, not silently stop
     gating — this is the same "prefer exit-code / structural gates over string-parsed
     ones, and if a new gate is string-based make it fail loud on parse failure" posture
     `core-directives.md`'s "Never Satisfy a Gate by Editing What It Measures" implies.
3. Enumerate every `partition-<i>.log` file directly under that directory (glob
   `partition-*.log`, not a hardcoded count — the check must not need to know N in
   advance; it discovers however many partition logs actually exist).
   - **Error shape if zero partition logs are found:** hard failure, same reasoning as
     above — a directory with no partition logs means the runner never actually ran
     partitions, and treating that as "nothing to check, pass" would be exactly the
     vacuous-gate hazard this section exists to prevent.
4. Read and concatenate the full text of every discovered partition log (not just
   grep-per-file-and-OR the booleans — concatenating first and running one substring
   search keeps the "offending lines" reporting logic below identical in shape to
   today's single-stream version, minimizing the diff's conceptual surface).
5. Apply the **exact same two checks `run/1` applies today**, now against the
   concatenated multi-partition text: nonzero exit code from the wrapper itself (real
   test failure, already surfaced via `test_parallel.sh`'s own exit-code contract —
   see §4 below for why that contract is trustworthy) → `Mix.raise`; substring present
   anywhere in the concatenated text → `Mix.raise`, printing the offending line(s)
   **prefixed with which partition log they came from** (a new requirement, not in
   today's single-stream version, needed because "offending lines" without partition
   attribution would be a usability regression under §4's failure-parity concern —
   trivial to add: track `{partition_index, line}` pairs while concatenating rather
   than discarding the association).
6. **Do not delete the partition-log temp directory.** `scripts/test_parallel.sh`
   itself never deletes it (confirmed by reading the script in full — no `rm -rf
   "$tmp_dir"` anywhere), and `run_main_suite/0` must not either; §4 below depends on
   this directory surviving past the check for failure-detail retrieval. Print its path
   in `check.test`'s own final summary line regardless of pass/fail, not only on
   failure — see §4.

### 1.3 Proof the re-pointed check still catches a real occurrence (the issue demands this explicitly)

Design-level specification for what ELIXIR-DEV/TEST-DESIGNER must produce as evidence,
not merely assert:

- **A scratch (never-committed) probe**, run once during implementation and once during
  TEST-RUNNER's independent re-verification (per "Every producing step has a validating
  step" — the producer's own claim that the gate still catches ISS-0069 is not evidence
  on its own): temporarily add a `defp` helper with an unused optional default argument
  to any existing test-support file already compiled under `elixirc_paths(:test)` (e.g.
  a throwaway helper in `test/support/`), matching the exact shape ISS-0069's own
  historical occurrences take (`docs/anti-patterns.md`'s "A test helper's default
  argument goes dead..." entry — every call site passes the optional arg explicitly, so
  the default is provably unused). Run the re-pointed `mix letflow.check.test` against
  that state: it MUST fail, and the failure message MUST name the offending line(s) and
  (per §1.2 step 5) the partition log they came from. Then revert the scratch change and
  confirm a clean run passes. **Both runs' real output must be quoted** in the
  implementation/verification handoff — "should still catch it" is forbidden per
  `core-directives.md`'s No Speculation.
- This probe is exactly the "construct the condition the property is actually about"
  discipline `core-directives.md`'s "Re-derive under the conditions the property is
  actually about" section requires — a green re-pointed check on ordinary,
  warning-free code proves nothing about whether the substring search still works; only
  a deliberately-injected occurrence does.
- **Open question, explicitly not resolved here:** whether this probe becomes a
  permanent regression test (e.g. under `test/letflow/mix_tasks/` or similar) or stays a
  one-off scratch verification. Left to TEST-DESIGNER's judgement per the same pattern
  as `iss0446-throwaway-supervisor-teardown-race-fix.md`'s own precedent (WF03-ISS0446).
  Arguments either way: a permanent test would need to invoke a Mix task from inside
  ExUnit and parse its raised message, which is unusual for this codebase (no existing
  precedent found by grep for `Mix.Task.run("letflow.check.test"` anywhere under
  `test/`) — TEST-DESIGNER should decide whether that unusual shape is worth building or
  whether the scratch-probe-plus-quoted-output discipline above is sufficient
  going forward.

---

## 2. The two isolated subprocess runs (`--only wasm_hang`, `--only lua_wallclock_race`)

### Decision: leave both serial, unchanged in shape, run exactly as today — after the (now-parallel) main suite

**Argument.** Both exist *because of* contention sensitivity, not despite it:

- `run_wasm_hang_tests/0` (ISS-0352): these tests deliberately, permanently leak one
  slot of `wasmex`'s shared, node-global native worker pool per test. The moduledoc is
  explicit that running them in the *same* process as other WASM NIF tests starved
  unrelated tests once the pool was exhausted (PR #691/#692, 18 cascading
  `ExUnit.TimeoutError`s). Running them under `test_parallel.sh`'s N-way partition
  scheme would multiply this hazard by N — N concurrent BEAMs each independently
  leaking into the same node-global pool (if `wasmex`'s NIF pool is process-local, N
  concurrent partitions might not even share the hazard consistently; if it isn't, this
  gets strictly worse). Nothing about ISS-0428's own scope asks for this to be
  revisited, and doing so would need its own measurement this design has no evidence
  for.
- `run_lua_wallclock_race_tests/0` (ISS-0426): tag-isolated specifically because they
  need to run **without racing 30+ concurrently-scheduled siblings for wall-clock
  timing** (moduledoc, quoting `iss426-wallclock-test-contention.md` §2.3 directly).
  ISS-0423's own `discovered_side_effect` already recorded that 6-way parallel running
  is exactly what *surfaced* this flake in the first place. Putting these tests inside
  a parallel partition (or running this isolated subprocess itself in parallel with
  something else) reintroduces the precise contention ISS-0426 was filed to remove.

**Both subprocess runs stay exactly as today**: single-process `mix test --only
wasm_hang` / `mix test --only lua_wallclock_race`, run sequentially, after the main
suite's check passes — no `test_parallel.sh` involvement, no `run_in_parallel` flag, no
change to `run_wasm_hang_tests/0` or `run_lua_wallclock_race_tests/0` beyond what falls
out mechanically from any shared helper refactor (see §5). These two subprocesses are
already small (a handful of tagged tests each, not the full suite) — the entire
performance motivation for adopting `test_parallel.sh` (a ~25-30 minute serial gate)
does not apply to them, so there is no gain to weigh against the contention risk.

**If a future issue wants to reconsider this:** it needs its own measurement of
whether `wasmex`'s worker pool is genuinely node-global-shared across separate OS
processes (this design does not know this; a plausible open question but out of
ISS-0428's scope) and its own timing measurement of the wasm_hang/lua_wallclock_race
subprocess costs. Not resolved here — flagged as future scope, not silently decided.

---

## 3. Selection mechanism — switch wholesale, no fallback flag

### Decision, stated plainly: `run_main_suite/0` always uses `scripts/test_parallel.sh`. No env var, no host-detection branch, no "falls back to plain `mix test`" path in the normal case.

**Why this reverses ISS-0428's own suggested shape.** The issue suggested a
selectable runner specifically because CI's N=2 gain was *unproven* and plausibly
negative — "a decided 'local only, CI unchanged' is a perfectly good outcome," written
before anyone had actually run N=2 to completion. §0 above closes that gap: N=2 is now
**measured**, not assumed, at 1.89x and clean, on the actual constraint CI runs under
(2 vCPU). The two things ISS-0428 was hedging against — CI gains being unproven, and
N=2 specifically risking the connection-exhaustion/flake failure modes ISS-0219/
ISS-0222/ISS-0426 documented — are both now empirically closed in the direction of
"safe." Keeping a selector flag after the uncertainty it existed to hedge against is
gone would be complexity with no remaining justification — this project's own
`docs/anti-patterns.md` and `core-directives.md` posture favors the simplest gate that
actually gates; two code paths through `check.test`'s main-suite step (parallel here,
serial there) is two things that can independently drift, and CI is the one path that
matters most and would get the least exercise of the "other" branch.

**What "wholesale" means concretely.** `run_main_suite/0` invokes
`scripts/test_parallel.sh` unconditionally, every time `mix letflow.check.test` runs —
local developer loop, CI, everywhere `mix letflow.check` is invoked (which per REQ-136's
own design note is CI's *only* backend-gate step). No `mix.exs`/`ci.yml` edit is needed
for CI to pick this up, confirming ISS-0423's own `test_parallel_adoption_point` note.

**N-derivation is untouched.** `test_parallel.sh` already derives N from
`TEST_PARALLEL_N` (override) → `nproc` → `getconf` → hard-fail, per its own Step 0 (this
design does not add a new default, per decision 0009's own precedent of "never a
hardcoded fallback number"). On CI's `ubuntu-latest`, that resolves to N=2 automatically
— no CI-side env var needed. On a developer's local host, whatever `nproc`/`getconf`
reports (or an explicit override).

### 3.1 The genuinely different hazard this decision must still answer: hosts where the parallel runner cannot run at all

The issue asks explicitly what happens on a host with no bash, no `nproc`, or on
Windows without a POSIX shell — since this project runs on both Windows and Linux
hosts. This is **not** the same axis as "is N=2 safe" (§0 already answers that); it's
"does `scripts/test_parallel.sh` execute at all here."

**Verified for this design:**
- This session's own host is Windows (`MINGW64_NT-10.0-26200`, Git Bash/MSYS), and
  `scripts/test_parallel.sh` **is** the runner already used successfully all session —
  `which bash` resolves to `/usr/bin/bash`, `nproc`/standard POSIX utilities are present
  under Git Bash. So "Windows" alone is not the disqualifying condition; "Windows
  without Git Bash/WSL/any POSIX shell on PATH" is the actual edge case, and this
  project's own `docs/guides/backend_developer_guide.md` already requires a working
  toolchain including Docker/Elixir setup — Git Bash (or WSL) is a reasonable assumed
  baseline for a dev host that also runs `mix`, `docker compose`, etc. successfully
  (the whole `mix letflow.check.test` task itself, unmodified, already assumes a
  POSIX-ish `Port.open({:spawn_executable, ...})` executable-resolution path via
  `System.find_executable/1`, which works for `bash`-invoked scripts the same way it
  works for `mix`).
- `.github/workflows/ci.yml`'s `runs-on: ubuntu-latest` — bash is always present,
  `nproc` is always present (coreutils). No hazard on CI.

**Design requirement for `run_main_suite/0`: fail loud, not silently degrade, if the
runner cannot be found or cannot execute.** Specifically:
- Resolve the executable via `System.find_executable("bash")` (matching
  `stream_and_capture/2`'s existing `System.find_executable(cmd) || raise` pattern) and
  invoke `scripts/test_parallel.sh` as a bash script argument (`bash
  scripts/test_parallel.sh`), not as a directly-executable file — this sidesteps needing
  the script's executable bit to survive a Windows checkout (a known cross-platform
  hazard already documented in the script's own ISS-0377 comment block about
  Windows/NTFS hardlink behavior) and matches how a developer would invoke it manually
  per the script's own header comment (`scripts/test_parallel.sh [args]`, implicitly
  assuming a shell already interprets the shebang — explicit `bash` avoids relying on
  that).
- If `System.find_executable("bash")` returns `nil`: `Mix.raise` immediately with a
  clear message ("mix letflow.check.test: no bash found on PATH — scripts/test_parallel.sh
  requires bash; see docs/guides/backend_developer_guide.md for setup"), not a silent
  fallback to plain `mix test`. This is deliberate, matching §3's "no fallback path"
  decision: a host that cannot run the parallel runner is a genuinely broken dev
  environment for this project going forward (same posture as `mix`/`docker`
  themselves being required, not optional, per the backend guide), not a degraded-mode
  case to quietly route around. A silent fallback would reintroduce exactly the
  "selectable, falls back invisibly" complexity §3 just argued against, and would mean
  a broken host's gate result is not comparable to every other host's.
- **This is a considered position, not an oversight — flagged explicitly as an open
  design choice for CODE-DESIGN-VALIDATOR/REVIEWER to contest if they disagree**: an
  alternative would be a soft fallback with a loud warning instead of a hard failure.
  Rejected here because "the gate silently ran a different, less-tested code path" is
  itself the kind of quiet behavior change `core-directives.md` warns against, and
  because no host in this project's actual current fleet (this dev workstation via Git
  Bash, CI's `ubuntu-latest`) lacks bash — the case being designed for is hypothetical,
  not observed, so failing loud costs nothing today and surfaces a real gap immediately
  if a genuinely bash-less host is ever added.

### 3.2 `TEST_PARALLEL_N` on CI — explicitly not set

No new CI env var. `scripts/test_parallel.sh`'s own `nproc` derivation naturally yields
N=2 on `ubuntu-latest`. If a future CI runner changes vCPU count, N adapts automatically
— this is the existing, already-decided behavior of the script (decision 0009), not
something this design introduces.

---

## 4. Failure-mode parity — an agent must be able to find which test failed and why

### 4.1 The regression risk, stated precisely

Serial `mix test` failing today gives `check.test` one subprocess's combined
stdout+stderr, already fully captured and streamed live — an agent reading the terminal
transcript sees the actual `ExUnit` failure output (file, line, assertion diff) in
place. `scripts/test_parallel.sh`'s own stdout, by contrast, only ever prints
per-partition summary lines (`partition <i>: <t> tests, ... exit <ex>`) and an
aggregated total — the actual failure detail lives in `$tmp_dir/partition-<i>.log`,
and `$tmp_dir` is a `mktemp -d` path a CI runner discards at job end unless something
explicitly surfaces it (an artifact upload, a printed `cat`, etc.).

### 4.2 Design requirement: `run_main_suite/0` prints full partition-log content on failure, not just the path

When the parallel runner's own aggregated exit signals failure (`any_failed` in the
script's own terms — see script §"Step 5: exit-code contract"), `run_main_suite/0`
must, before raising:

1. Re-use the same partition-log directory already located for §1.2's substring check
   (one discovery, two consumers — no second `mktemp`/re-run).
2. For every partition log whose content contains a `Failed:` line (per the script's
   own documented ExUnit summary shape — grep for `^Failed: `), print that partition's
   **full log content** to stdout (already streamed live via the same `Port`-based
   streaming `stream_and_capture/2` uses, so an agent watching the run live sees the
   real per-test failure detail exactly as they would under serial `mix test`, not
   merely a count).
3. Only for partitions with **no** `Failed:` line but a nonzero/missing `Result:` line
   (a partition that crashed before completing — the script's own §Step 4 "WARNING
   partition N has no Result: line" case), print that partition's full log too — a
   silent crash is at least as important to surface as a normal test failure, and is
   exactly the ISS-0219/ISS-0222 class of failure this design's own §0 measurement
   found does *not* occur at N=2, but must still be diagnosable if it ever recurs on a
   different host.
4. `Mix.raise`'s own message names the partition-log directory path explicitly (not
   only in a stray earlier log line) so the message string itself is the durable
   record — `Mix.raise` messages are what an agent/CI reader actually sees as the
   final, bolded failure output, and are more likely to be the only thing quoted back
   into a report than earlier streamed lines.
5. **This design does not add a CI artifact-upload step** (that would touch
   `.github/workflows/ci.yml`, out of scope per this document's own header) — the
   printed-to-stdout content in step 2/3 above is the design's answer to "CI discards
   the tmp dir," since CI already captures the full job log (GitHub Actions retains
   step output regardless of the underlying tmp directory's lifetime), and
   `core-directives.md`'s "Never call a red pipeline OK without a source" already
   directs an agent investigating a red CI run to read `gh run view --log-failed`,
   which will now contain the real per-test failure detail printed by step 2/3, not
   only aggregate counts. If CI-side artifact upload (preserving the raw log files
   themselves, not just their printed content) is later judged valuable, that is a new,
   separate scoped change to `.github/workflows/ci.yml` — flagged here as a candidate
   follow-up, not decided.

### 4.3 Net effect on the parity question

Post-change: a failing `check.test` run's terminal output (local or CI) shows, in
order: per-partition summary lines (from the script itself, streamed), the aggregated
total (from the script), then this task's own printed full content of every failing/
crashed partition's log, then the `Mix.raise` message naming the log directory. This is
strictly more detail than serial `mix test` provided (which showed one ordering of all
failures interleaved; parallel shows them grouped by partition, arguably easier to read
per-file) — not a downgrade, once this design's own printing step is implemented. **This
is a real design requirement, not a nice-to-have** — omitting it would leave exactly the
usability regression the issue's dispatch flagged as a real risk in a humanless
pipeline.

---

## 5. Boundary with ISS-0423 — explicitly not absorbed

ISS-0423 covers a **different, complementary** lever: making the suite's own tests
genuinely `async: true`-capable (currently defeated globally by
`Letflow.TenantFixture.provisioned_tenant!/1` calling `Sandbox.mode(Letflow.Repo,
:auto)`, a global per-repo setting — see ISS-0423's `measured_causes.async_is_defeated_
globally`, tied to ISS-0113). That is a change to `test/support/tenant_fixture.ex` and
`Letflow.DataCase`/`Letflow.SandboxPool` usage patterns — i.e., how many CPU-bound tests
can run *concurrently within a single BEAM/partition* — and is explicitly out of scope
here.

**This design's scope is strictly**: which subprocess `mix letflow.check.test` shells
out to for the main suite (N OS-process partitions via `test_parallel.sh`, unchanged
internals), and how that task's own gates (ISS-0069 substring check, failure-detail
reporting) adapt to a multi-log output shape instead of one. It does not touch
`test/support/`, `config/test.exs`'s pool-size formula (already correctly handled by
`test_parallel.sh` + decision 0009's `TEST_POOL_SIZE` export, unmodified by this
design), or any `async:` declaration on any test module. If ISS-0423's async work lands
later, it composes with this design without further change here — a partition that
gains internal async concurrency just finishes its own `mix test --partitions N`
invocation faster; `test_parallel.sh`'s own per-partition log shape, and everything
§1/§4 build on it, is unaffected either way.

---

## 6. Public interface — signatures only, no implementation code

`lib/mix/tasks/letflow.check.test.ex`, restructured (names indicative — ELIXIR-DEV may
rename during implementation as long as behavior matches; nothing below is a code
block):

- `run/1` — same `@impl Mix.Task` entry point, same arg-ignoring contract as today.
  Calls `run_main_suite/0`, and on success proceeds to the two existing subprocess
  helpers unchanged (§2).
- `run_main_suite/0` — **new**, replaces today's inline first branch of `run/1`.
  Returns `:ok` or raises via `Mix.raise` (matching every other helper's existing
  contract — no function here returns an `{:error, _}` tuple anywhere in this module
  today, and this design does not introduce one). Responsibilities: resolve `bash`
  executable (§3.1), invoke `scripts/test_parallel.sh` via the existing
  `stream_and_capture/2` shape, parse the `partition logs in <dir>` line (§1.2 step 2),
  discover partition logs (§1.2 step 3), run the ISS-0069 substring check across their
  concatenated content with per-partition attribution (§1.2 steps 4-5), and on the
  runner's own reported failure, print full per-partition failure detail before raising
  (§4.2).
- `find_partition_log_dir/1` — **new**, input: the captured stdout text from the
  `test_parallel.sh` subprocess (`String.t()`); output: `{:ok, Path.t()} | :not_found`.
  Never raises itself — `run_main_suite/0` is the one that turns `:not_found` into a
  `Mix.raise`, matching this module's existing pattern of helpers being pure/returning
  and `run/1`-adjacent functions doing the raising.
- `partition_logs/1` — **new**, input: a directory path (`Path.t()`); output: a sorted
  list of `Path.t()` matching `partition-*.log` directly under it (empty list is a
  legal return — `run_main_suite/0`, not this function, decides that's an error case,
  per the same separation-of-concerns as `find_partition_log_dir/1`).
- `check_substring_across_logs/1` — **new**, input: a list of `{partition_index ::
  pos_integer(), log_path :: Path.t()}` (or equivalent — exact shape left to
  ELIXIR-DEV, this is a design-level contract not a literal type spec); output: `:ok |
  {:offending, [{pos_integer(), String.t()}]}` — the list being `{partition_index,
  matching_line}` pairs, consumed by `run_main_suite/0` to build the same
  attributed-`Mix.raise` message §1.2 step 5 describes.
- `report_partition_failures/1` — **new**, input: the same partition-log list; prints
  (via `Mix.shell().info`/`IO.puts`, matching this module's existing style) full content
  of every partition whose log shows a real `Failed:` line or a missing `Result:` line
  (§4.2 steps 2-3). Returns `:ok` — side-effecting print helper, not a value-producing
  one, matching this module's existing `run_wasm_hang_tests/0`/`run_lua_wallclock_race_
  tests/0` style (both are `:ok`-returning side-effecting helpers today).
- `stream_and_capture/2`, `collect/2` — **unchanged**, reused for the `bash
  scripts/test_parallel.sh` invocation exactly as they are reused today for `mix test`
  and the two `--only` subprocess calls.
- `run_wasm_hang_tests/0`, `run_lua_wallclock_race_tests/0` — **unchanged in
  contract and internals** (§2's decision). If ELIXIR-DEV extracts a shared
  "raise on substring, print offending lines" helper to avoid duplicating that logic
  three ways (main suite, wasm_hang, lua_wallclock_race) that is a legitimate,
  encouraged refactor — not specified further here since it changes no observable
  behavior of either existing helper.

**Module attribute:** `@target_substring` — unchanged value, unchanged meaning.

**No new Ecto schema, no new DB table/column/index, no new gen_statem, no HTTP route.**
This is pure Mix-task/tooling design; the "Ecto schema field lists" / "state/data shape"
sections of the design-doc template do not apply and are omitted rather than filled
with placeholder text.

---

## 7. Invariants this design must preserve

1. **Exit-code contract unchanged in kind**: `mix letflow.check.test` exits 0 only if
   the (now-parallel) main suite genuinely passed with no ISS-0069 substring anywhere,
   and both isolated subprocess runs (§2, unchanged) also pass clean. Exits nonzero
   otherwise. No caller of `mix letflow.check.test` (the `letflow.check` alias in
   `mix.exs`, CI) needs to change, because this contract is preserved byte-for-byte at
   the process-exit-code level.
2. **The ISS-0069 gate must never silently stop gating** — §1's entire design exists to
   guarantee this; §1.3's probe is the proof obligation.
3. **No new hardcoded partition count anywhere** — `test_parallel.sh`'s own N-derivation
   (§3) is untouched and remains the sole source of N, matching decision 0009 and
   `req113-parallel-test-runner.md`'s AC4.
4. **`test_parallel.sh` itself is not modified by this design** — every requirement
   above is satisfied by changes to `letflow.check.test.ex`'s own consumption of the
   script's existing, unmodified output contract (the `partition logs in <dir>` line,
   the per-partition log file naming scheme, the aggregated exit code). If a future
   implementer finds this contract insufficient, that is grounds to flag a rework of
   this design, not to quietly extend the script.
5. **The two isolated subprocess runs remain serial and unaffected** (§2).

---

## 8. Open questions (not silently resolved)

1. **Whether the ISS-0069 probe (§1.3) becomes a permanent regression test.** Left to
   TEST-DESIGNER, per §1.3's own note.
2. **Whether `wasmex`'s native worker pool is genuinely OS-process-scoped or something
   broader**, which would matter if a future issue ever wants to reconsider running
   `--only wasm_hang` under any form of parallelism. Not investigated here — §2's
   decision to leave it serial does not depend on knowing the answer, but a future
   change that *does* want to parallelize it would need to establish this first.
3. **Whether CI should additionally upload the partition-log directory as a build
   artifact** (§4.2 step 5's flagged follow-up) — this design's position is that
   printing full failure content to the already-retained CI job log is sufficient, but
   an artifact upload would preserve the *exact* raw logs (including passing
   partitions' logs, useful for diagnosing e.g. timing/flake patterns after the fact)
   at zero risk beyond a `.github/workflows/ci.yml` edit. Left as a candidate
   follow-up issue, not designed further here, since it is out of this document's
   declared scope (no `ci.yml` changes).
4. **Whether `bash` resolution (§3.1) should also try a Windows-native fallback** (e.g.
   WSL invocation) if plain `bash` isn't found on `PATH`. Not designed here — the
   observed fleet (this workstation's Git Bash, CI's `ubuntu-latest`) doesn't need it,
   and inventing a fallback for an unobserved host shape risks exactly the kind of
   untested-path complexity §3.1 already argued against for the "soft fallback"
   alternative.

---

## 9. Acceptance-criteria coverage map

| ISS-0428 concern | Where addressed |
|---|---|
| Adoption gap itself (wire `test_parallel.sh` into `mix letflow.check`) | §3 (wholesale switch inside `check.test`, no `mix.exs`/`ci.yml` edit needed per REQ-136 precedent) |
| ISS-0069 gate must not silently stop gating | §1 (re-pointed to per-partition logs) + §1.3 (proof-of-catch obligation) |
| Two other subprocess runs (wasm_hang, lua_wallclock_race) | §2 (stay serial, argued explicitly) |
| Selection mechanism (selectable vs. wholesale) | §3 (wholesale, reversing the issue's own hedge, justified by §0's new measurement) + §3.1 (loud-fail, no silent fallback, for a hypothetical bash-less host) |
| Failure-mode parity (which test failed and why, without a discarded tmp dir) | §4 |
| Boundary with ISS-0423 | §5 |
