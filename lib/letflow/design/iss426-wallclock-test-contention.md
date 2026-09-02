# ISS-0426 — Lua wall-clock test contention flake — fix design

**Status:** design, awaiting CODE-DESIGN-VALIDATOR.
**Scope:** test-infrastructure only —
`test/letflow/engine/lua/executor_test.exs`, `test/test_helper.exs`, and (minimal,
additive) `lib/mix/tasks/letflow.check.test.ex`.
**Explicitly out of scope:** `lib/letflow/engine/lua/executor.ex` (no production code
change), `config/config.exs:17` (production `lua_wallclock_timeout_ms` untouched),
`config/test.exs:187` (left as-is — see §2.3 for why touching it would not even fix
the filed failure), and every file `lib/letflow/engine/wasm` / the three WF03-ISS0418
wasm test files own (read-only per this run's scope boundary).

## 1. Inputs (do not re-diagnose — restated and independently re-verified)

ISSUE-FIXER's Step 1 diagnosis (`handoffs/WF03-ISS0426-20260902/step-01-issue-fixer-diagnosis.json`)
is the evidence base. Its factual claims were spot-checked against the actual source
(HANDOFF_PROTOCOL §1.1) rather than inherited blind — see §1.1–§1.3 below for what
was verified, what was found to need refinement, and what was found to disagree.

### 1.1 Root cause — verified, unchanged

`Executor.execute_with_manifest/3`'s `nil`-heap-words path (`lib/letflow/engine/lua/executor.ex:367-373`):

```
task = Task.Supervisor.async_nolink(Letflow.Engine.Lua.TaskSupervisor, fn -> run_script(...) end)
task |> Task.yield(timeout_ms) |> handle_yield_result(task, timeout_ms)
```

`handle_yield_result(nil, task, timeout_ms)` (executor.ex:592) fires when `Task.yield/2`
receives no reply within `timeout_ms` milliseconds of **wall-clock** time — a measure of
whether the calling process was scheduled to observe a reply in time, not of how long the
child task's own Lua evaluation took. Under `scripts/test_parallel.sh TEST_PARALLEL_N=6`
on a 16-core host, six BEAM nodes oversubscribe the host's schedulers roughly 6x; a
microsecond-scale task can sit unscheduled long enough to exceed even a 5000ms budget.
Confirmed by reading `executor.ex` directly, matching the handoff's mechanism statement.

### 1.2 Two-group split — verified, and REFINED (this design's own finding)

ISSUE-FIXER enumerated ~10 "generous timeout wrapping tiny work" tests starting at
executor_test.exs:452 and ~9 "tight timeout, race is the property" tests. Re-reading the
whole file end to end (every `execute_with_manifest(...timeout_ms: ...)` call site, not
just the ones the diagnosis's own enumeration started from) found the split is real and
usable, but incomplete in two ways CODE-DESIGN-VALIDATOR should know were checked:

**(a) Five more Group-1-shaped call sites the diagnosis's enumeration omitted**, all in
the `describe "instruction budget (REQ-154)"` block (lines 253-321), all
`timeout_ms: 5_000` wrapping a workload that is expected to hit `:budget_exceeded` (a
loop capped at 500-1000 instructions) — the identical "5000ms is scaffolding, any
timeout outcome is a wrong-branch failure" shape as AC7. These matter to this design
because a tag that covers only ISSUE-FIXER's original ~10 would still leave these five
racing under contention, undetected by this design if left out. Included in Group 1
below (§2.1's full table).

**(b) Two tests are internally MIXED — not cleanly Group 1 or Group 2.** Lines 656 and
887 (near-duplicate `describe` blocks, same test name "AC-3/AC5: ...
pattern-distinguishable from ...") each make **three** `execute_with_manifest` calls in
one test body:

```
budget_result  = execute_with_manifest(..., timeout_ms: 5_000, ...)   # Group-1-shaped
timeout_result = execute_with_manifest(..., timeout_ms: 200,   ...)   # Group-2-shaped — the racing one
memory_result  = execute_with_manifest(..., timeout_ms: 5_000, ...)   # Group-1-shaped
```

`@tag` in ExUnit applies at the whole-test granularity — there is no way to tag only
`timeout_result`'s call within an already-tagged test. This design's per-group treatment
(§2.1 restructure for Group 1, §2.2 tag-isolate for Group 2) cannot be applied as "tag
the whole test" for these two without either (i) losing Group 2 coverage for their
`timeout_result` arm if the whole test is restructured away from racing, or (ii) needlessly
moving their Group-1-shaped `budget_result`/`memory_result` arms into the isolated
low-concurrency partition where they don't need to be. §2.4 gives these two tests their
own, narrower treatment: restructure only the two Group-1-shaped calls' assertions,
`@tag` the test itself into the isolated partition anyway (since it still contains one
genuinely racing call), accepting the minor inefficiency of one Group-1 assertion also
running in the low-concurrency partition over the alternative of splitting the test into
two (which the "AC-3/AC5 pattern-distinguishable from ALL arms in one classify" property
being asserted structurally requires — the three results are deliberately produced and
classified together in the same test, so splitting would break what AC-3/AC5 actually
proves. See §2.4.)

**(c) A stale comment adjacent to the tests this design touches.**
executor_test.exs:320 reads *"config/test.exs sets a short :lua_wallclock_timeout_ms
(200ms)"* — the actual value at config/test.exs:187 is `5000`, not `200` (confirmed by
direct read; matches ISSUE-FIXER's own correctly-cited `5000`, so this is a pre-existing
drift in the test file's own comment, not a disagreement with the diagnosis). Not a
functional defect — no test reads this value via the 2-arity fallback path currently
exercised in this file — but it sits inside the very `describe` block this design edits,
so ELIXIR-DEV should correct "200ms" to "5000ms" as a one-line drive-by fix while already
touching this block. Flagged here rather than silently left, per this project's
documentation-honesty norm (mirrors iss0260-ac1-timing-flake.md §5's precedent of
recording a required doc correction rather than leaving it for someone else to notice).

### 1.3 WASM-side enumeration claim — verified, matches

Re-read `test/letflow/engine/wasm/call_timeout_test.exs`,
`test/letflow/engine/wasm/plugin_handler_test.exs`,
`test/letflow/engine/wasm/host_api_write_test.exs` (read-only, per scope boundary) and
`test/test_helper.exs`. Confirmed: every wall-clock-sensitive test in those three files
already carries `@tag :wasm_hang` + `@tag timeout: 180_000`, and `test/test_helper.exs:33`
already excludes `:wasm_hang` from the default run (`ExUnit.start(exclude: [:keycloak,
:wasm_hang])`). ISSUE-FIXER's claim that option (a) (tag + isolate) is **already shipped**
for the WASM side is correct — this design's job is to extend the same *shape* to the
LUA side's Group 2, under a distinct tag name, not to touch the WASM files or their
existing tag.

### 1.4 Why option (b) (raise the budget) is rejected, restated

`config/test.exs:187`'s own inline comment trail documents this exact mechanism already
defeating two prior raises (200ms → 1500ms → 5000ms, each time re-exceeded under
real parallel load). Also — independently confirmed by this design's own read of
executor_test.exs — **`config/test.exs:187` is dead code for every Group 1 test**: every
Group 1 call site (AC7 included) uses the 3-arity `execute_with_manifest/3` with its own
pinned `timeout_ms:` literal, which never falls through to
`Application.fetch_env!(:letflow, :lua_wallclock_timeout_ms)` (that read only happens
inside the 2-arity `execute_with_manifest/2` wrapper, executor.ex:307-312, which no test
in this file calls in its failing/at-risk paths). So "raise config/test.exs:187" would be
two things at once: (i) a bet against a mechanism with a documented 2-for-2 track record
of not holding, and (ii) not even reach the code path that produced the filed failure.
Rejected as this design's approach, consistent with ISSUE-FIXER's own recommendation and
ISS-0426's own filing judgement.

## 2. The fix, precisely

Two different treatments, one per group, matching the two groups' different exposure
(mirrors ISSUE-FIXER's option assessment in shape; this design adopts option (c)
restructure for Group 1 and option (a) tag-isolate for Group 2, per the task
description's own framing of what's available to adopt/refine/reject).

### 2.1 GROUP 1 — restructure so no assertion depends on which of two racing outcomes wins

**Full list (15 call sites across 10 tests, corrected/completed per §1.2(a)):**

| Test (line, current) | Workload | Current `timeout_ms` | Asserted outcome |
|---|---|---|---|
| REQ-154 AC-1 "smaller budget halts sooner" (253) | `for i=1,5000 do end` x2 | 5_000 x2 | `budget_exceeded` / `:ok` |
| REQ-154 AC-2 "while true...budget_exceeded" (273) | `while true do end` | 5_000 | `budget_exceeded` |
| REQ-154 AC-3 "budget_exceeded is structured" (283) | `while true do end` | 5_000 | `budget_exceeded` |
| REQ-154 AC-4 "pcall-caught budget exhaustion" (299) | pcall-wrapped loop | 5_000 | `:ok` |
| REQ-155 "AC-4 regression guard: budget_exceeded unaffected by generous timeout" (448) | `@infinite_loop`, budget 500 | 5_000 | `budget_exceeded` |
| REQ-156 AC-1 "smaller max_heap_words halts sooner" (605) | allocating script x2 | 5_000 x2 | `memory_limit_exceeded` / `:ok` |
| REQ-156 AC-2 "1GB alloc under 16MB limit" (644) | gigabyte-allocating script | 5_000 | `memory_limit_exceeded` |
| REQ-162 AC1 "uncaught runtime error produces SCRIPT_ERROR" (812) | `1 // 0` | 5_000 | `script_error` |
| REQ-162 AC4 "1 // 0 raises..." (861) | `1 // 0` x2 | 5_000 x2 | `script_error` / `:ok` |
| REQ-162 **AC7 "stack trace frames contain no '/' or 'Elixir.'" (983) — THE FILED FAILURE** | `local function f()...1//0...end` | 5_000 | `script_error` |
| REQ-162 "regression guard §7: real uncaught VM opcode error..." (1052) | `1 // 0` | 5_000 | `script_error` |

(The two mixed tests at 656/887 are handled separately in §2.4, not in this table — only
their non-racing `budget_result`/`memory_result` calls belong to this group's treatment.)

**The restructure:** for every call site in this table, the outcome under test
(`budget_exceeded`, `memory_limit_exceeded`, `script_error`, or `:ok`) is fully determined
by the workload alone — none of them is asserting anything about wall-clock time. The
`timeout_ms: 5_000` argument exists only as "clearly enough time for this workload," which
is exactly the condition ISS-0426's own filing calls out as removable rather than
re-tuned. Two changes, applied together:

1. **Replace the wall-clock race with a budget-only or logic-only path wherever the
   `Task.yield`/wall-clock mechanism is not needed to observe the asserted outcome.**
   Concretely: introduce one new, `nil`-heap-words-equivalent call path (or reuse an
   existing seam if one already exists — see Open Question OQ-1) that runs `run_script/3`
   **synchronously in the calling test process**, with no `Task.Supervisor.async_nolink` +
   `Task.yield(timeout_ms)` race at all — no wall clock is read, so there is no timeout
   value to blow through regardless of host contention. This is structurally, not
   statistically, immune: the failing branch (`handle_yield_result(nil, ...)`) is
   unreachable from this path by construction, because the path never calls
   `Task.yield/2`.

   This requires a design-level decision about *where* the synchronous seam lives — see
   §2.1.1 (two design options weighed) and Open Question OQ-1 (left for
   CODE-DESIGN-VALIDATOR / ELIXIR-DEV since it is the one place this design does not fully
   pin down a single answer).

2. **For call sites where introducing a synchronous seam is undesirable or not needed**
   (i.e., any Group-1 site not worth the seam's cost — see §2.1.1), fall back to keeping
   the 3-arity call exactly as today but tag the *test* into Group 2's isolated,
   low-concurrency partition (§2.2) instead of restructuring it. This is the safety valve:
   every Group-1 test gets EITHER "no race at all" (preferred, structurally verifiable) OR
   "isolated from contention" (fallback, same treatment as Group 2) — never left racing in
   the default `async: true` file under contention with no mitigation.

#### 2.1.1 Where the synchronous seam lives — two options weighed

**Option 2.1.1-A (recommended): a new, `@doc false` test-only 2-arity-shaped helper on
`Executor` itself**, e.g. conceptually `Executor.run_script_sync/3` (naming left to
ELIXIR-DEV; not prescribing an implementation, per this step's own constraint) that calls
the existing private `run_script/3` directly with no `Task`/`Task.yield` wrapper at all —
i.e., exactly the function body `run_script/3` already is, exposed for tests the same way
`build_script_error/3` (used at executor_test.exs:816, :848) is already exposed as a
`@doc false` public seam for tests that need to bypass the full `execute_with_manifest`
pipeline. This is directly precedented in this same file: `build_script_error/3` already
demonstrates this project's own established pattern for "a test needs to exercise an
inner function directly, bypassing the wall-clock/task-supervision wrapper that isn't the
thing under test." No new pattern introduced.

  - **Production impact: none.** `execute_with_manifest/2,3` (the public,
    `@behaviour`-required API) are untouched byte-for-byte — this is a new, additive,
    `@doc false` function alongside them, called only from tests. Satisfies HARD
    CONSTRAINT 1 (AC4) trivially, the same way `build_script_error/3`'s existing test-only
    seam already does.
  - **Coverage impact: still real production-code coverage.** `run_script/3` is the exact
    function `execute_with_manifest/3`'s task body already calls (executor.ex:369) — the
    only thing removed is the `Task.Supervisor.async_nolink` + `Task.yield` wrapper
    around it, which none of these tests were asserting on anyway (per this table's own
    "asserted outcome" column — none of them mentions `wallclock_timeout` or an in-flight
    task).

**Option 2.1.1-B (rejected as the primary mechanism): keep the 3-arity call, just raise
each site's own `timeout_ms:` literal.** This is option (b) applied per-call-site instead
of via config — rejected for the same reason §1.4 rejects it globally: it moves the
threshold without removing the sensitivity, and per §1.2(a)'s corrected count, is now 11
literals to re-tune (was already going to be ~10 per the diagnosis), each requiring its
own "how high is high enough" judgement call with no evidence-based ceiling (unlike
iss0260-ac1-timing-flake.md's §3.1, which had two real measured data points to derive a
number from — this design has zero data points for a Group-1-safe ceiling, because
ISSUE-FIXER's own reproduction attempts never caught the failure to measure how much
headroom would have sufficed). Not adopted.

**Decision: 2.1.1-A**, applied to every table row in §2.1 where a same-process
synchronous call is straightforward (all of them — none of these workloads needs the
`Task`-based isolation for its own outcome; heap-limited or instruction-limited runaways
still terminate on their own via `:max_instructions`/`max_heap_words`, which do not
require the wall-clock wrapper to enforce).

**What does NOT change in this table's tests:** the workload scripts, the
`max_instructions`/`max_heap_words` values, and every non-timing assertion — untouched.
Only the call site swaps from "async task + wall-clock race" to "synchronous call," and
the (now-meaningless) `timeout_ms: 5_000` argument is dropped from call sites that no
longer take it (the new seam has no timeout parameter to pass — see Open Question OQ-1 on
its exact arity/signature).

### 2.2 GROUP 2 — tag + isolate, mirroring the `:wasm_hang` precedent exactly

**Full list (11 tests, unchanged from a structural read of the file, confirms
ISSUE-FIXER's ~9 count plus the two AC-5-named tests at 463/744 the diagnosis's own
enumeration already implicitly covered under its "TIGHT" heading — restated here for
completeness):**

| Test (line) | Timeout(s) | Property genuinely under test |
|---|---|---|
| REQ-155 AC-1 "shorter configured timeout terminates sooner" (330) | 100 vs 600 | numeric elapsed-time comparison |
| REQ-155 AC-2 "timeout still fires when script traps its own budget error" (389) | 300 | race outcome (`wallclock_timeout` must win) |
| REQ-155 AC-3 "task process dead after timeout" (407) | 150 | post-kill supervisor state |
| REQ-155 AC-4 "wallclock_timeout doesn't match other shapes" (431) | 100 | race outcome |
| REQ-155 AC-5 "running script is child of TaskSupervisor while in flight" (463) | 300 | in-flight task state + eventual timeout |
| REQ-156 "nil max_heap_words leaves REQ-155 path unchanged" (744) | 300 | in-flight task state + eventual timeout |
| REQ-156 "memory-limited hang terminated by caller's own timeout" (788) | 250 | race outcome (caller-kill branch, not heap-kill) |
| REQ-162 AC-5/T "shorter wall-clock timeout terminates sooner" (1065) | 50 vs 200 | numeric elapsed-time comparison |
| REQ-162 AC-6 "timeout still kills after script traps its own budget exhaustion" (1092) | 100 | race outcome |
| (656) "AC-3 pattern-distinguishable" — mixed, see §2.4 | 200 (its racing arm) | race outcome, one arm of three |
| (887) "AC5 pattern-distinguishable" — mixed, see §2.4 | 200 (its racing arm) | race outcome, one arm of three |

**The tag:** a new ExUnit tag, `@tag :lua_wallclock_race`, applied at each test's own
`test "..." do` line (not `@moduletag` — unlike the WASM side, this file's remaining ~37
tests are NOT wall-clock-sensitive and must keep running in the default `async: true`
partition; a module-wide tag would over-exclude). A separate tag name from `:wasm_hang`
is deliberate — per ISSUE-FIXER's own diagnosis (§0.5 registry lookup, "SAME FAMILY, NOT
SAME ROOT CAUSE"), the LUA side has no shared native thread pool and no permanently-leaking
resource; conflating the two tags would imply a shared remediation mechanism (a
short-lived isolated subprocess to let a *leak* die with the process) that does not apply
here — the LUA tests don't leak anything, they just need to not race for scheduler time.
Reusing `:wasm_hang`'s name for a mechanistically distinct reason would also make a future
reader's job harder (grep for `:wasm_hang` would then mix "hangs forever, leaks a Tokio
thread" with "usually finishes in milliseconds but the timing window is tight").

### 2.3 Wiring the tag — `test/test_helper.exs` and `mix letflow.check.test` (HARD CONSTRAINT 2, ISS-0426 AC5)

Mirrors the `:wasm_hang` shape exactly, per the task description's own instruction to
mirror rather than invent:

**`test/test_helper.exs`:** add `:lua_wallclock_race` to the existing `exclude:` list —

```
ExUnit.start(exclude: [:keycloak, :wasm_hang, :lua_wallclock_race])
```

— with a comment block modeled on the existing `:wasm_hang` comment (ISS-0426 section),
stating: what the tag marks (LUA-side tests whose assertion depends on which of two
racing wall-clock outcomes wins, REQ-155/162/156), why they're excluded by default (BEAM
scheduler contention under `scripts/test_parallel.sh` N-way partitioning can make
`Task.yield(timeout_ms)` observe scheduler unavailability rather than Lua execution time,
ISS-0426), and the deliberate-inclusion command for a plain local run: `mix test --include
lua_wallclock_race test/letflow/engine/lua/executor_test.exs`.

This satisfies HARD CONSTRAINT 3 (ISS-0426 AC3, "must still pass serially under plain
`mix test`") the same way the existing `:wasm_hang` exclusion already does for the WASM
side: `mix test` with no flags never runs an excluded-tagged test at all, so its outcome
(flaky or not) cannot affect a plain `mix test`'s pass/fail — it is not "trading serial
correctness for parallel safety," it is removing the *contended-partition* case from a
context (a plain single-node `mix test`) where the tag's own low-concurrency guarantee is
irrelevant. Group 2 tests still run — every time — just not in the same `async: true`
file alongside 37+ other concurrently-scheduled tests within that one node, and not
inside a 6-way-partitioned outer run.

**`lib/mix/tasks/letflow.check.test.ex` — CONTESTED FILE, minimal additive change only.**
Per the task's own instruction: this file is owned by the concurrently-running
WF03-ISS0418-20260902 (OQ-5 WASM concurrency cap). This design's required change is
strictly additive — a new, independent subprocess invocation placed alongside
`run_wasm_hang_tests/0`, not a restructure of it:

- After the existing `run_wasm_hang_tests()` call (or before it — order between the two
  isolated runs is immaterial, since neither depends on the other's state; keeping
  `run_wasm_hang_tests()` first and appending the new one preserves the smallest possible
  diff against ISS-0418's own in-flight edits to this file), add one new private function,
  e.g. `run_lua_wallclock_race_tests/0`, whose body is `run_wasm_hang_tests/0`'s own
  shape verbatim with three substitutions: the tag name (`--only lua_wallclock_race`
  instead of `--only wasm_hang`), the log/error message text (naming ISS-0426 instead of
  ISS-0352 and this design instead of that one), and nothing else — same
  `stream_and_capture/2` helper reused unchanged (already generic over `cmd`/`args`, takes
  no wasm-specific parameter), same substring-warning check reused unchanged, same
  exit-code contract (both isolated subprocess runs must exit 0 for the task to pass).
- The task's top-level `run/1` gains exactly one more call in its final `cond` branch's
  success path — `run_wasm_hang_tests()` becomes (conceptually)
  `run_wasm_hang_tests(); run_lua_wallclock_race_tests()`, or equivalent sequencing that
  runs both isolated subprocesses and fails loudly if either exits nonzero. No existing
  line in `run_wasm_hang_tests/0`, `stream_and_capture/2`, or `collect/2` is modified.

**Merge-sequencing risk (flagged explicitly, per this run's own instruction):** both this
run and WF03-ISS0418-20260902 touch `lib/mix/tasks/letflow.check.test.ex`. This design's
own diff to that file is a small, additive, bottom-of-file change (one new private
function + one new call site in `run/1`'s success branch) chosen specifically to minimize
textual overlap with ISS-0418's own likely edits (which, per that issue's own scope —
OQ-5 concurrency cap — most plausibly touch `run_wasm_hang_tests/0`'s own invocation
or the WASM test process's concurrency, not add an unrelated third subprocess). A textual
merge conflict is still possible if ISS-0418 also appends near the end of the file;
ORCH should sequence whichever of the two PRs merges second to rebase against the first
rather than resolving blind, and REVIEWER on the second-merged PR should specifically
confirm `mix letflow.check.test`'s three-subprocess contract (default run, `--only
wasm_hang`, `--only lua_wallclock_race`) still holds post-merge. This is a coordination
risk for ORCH to sequence, not a defect in this design.

### 2.4 The two mixed tests (656, 887) — narrower treatment

Neither pure Group 1 nor pure Group 2 (see §1.2(b)). Treatment:

1. **`@tag :lua_wallclock_race`** applied to the whole test (both 656 and 887), same as
   §2.2/§2.3 — because each test does contain one genuinely racing call
   (`timeout_result`, `timeout_ms: 200`) whose outcome (`wallclock_timeout` winning the
   race) is asserted as one of the three arms of the "all N arms classify distinctly"
   property. This is the property AC-3/AC5 exist to prove — per HARD CONSTRAINT 4, this
   arm's race is not removed.
2. **The test's other two calls (`budget_result`, `memory_result`, both `timeout_ms:
   5_000`) are left as literal 3-arity calls, NOT converted to the §2.1.1-A synchronous
   seam**, even though they are Group-1-shaped in isolation. Reason: converting only two
   of a three-call test to a different call shape than the third, inside one test body,
   adds a real readability/maintenance cost (a future reader sees two different call
   patterns side by side for no reason visible from the test alone) for a benefit that
   doesn't materialize here — the whole test is already isolated into the low-concurrency
   `:lua_wallclock_race` partition by (1) above, so `budget_result`/`memory_result`'s
   `timeout_ms: 5_000` calls are no longer contending with 37+ other `async: true` tests
   or with 5 other partitions either; they inherit Group 2's contention mitigation "for
   free" once the whole test is tagged. Explicitly not extending §2.1's restructure here
   is a deliberate scope-minimization choice, not an oversight — flagged so
   CODE-DESIGN-VALIDATOR can confirm the reasoning rather than read it as an inconsistency
   with §2.1's table.
3. No change to the test's own assertions, workloads, or the `classify`/`Enum.uniq`
   structure — HARD CONSTRAINT 4 fully satisfied for both tests, nothing about what they
   prove changes.

## 3. How this satisfies the four hard constraints

1. **(AC4) Production wall-clock kill semantics unchanged.** `config/config.exs:17` is
   not referenced anywhere in this design. `execute_with_manifest/2,3`'s existing bodies,
   `handle_yield_result/3`, and every other function in `lib/letflow/engine/lua/executor.ex`
   that is not the one new `@doc false` test-only seam (§2.1.1-A) are byte-for-byte
   unchanged. The new seam is additive, calls the same already-existing private
   `run_script/3` the production path already calls, and is never invoked from any
   non-test code path.
2. **(AC5) Tagging wired the same way `:wasm_hang` already is.** §2.3 adds
   `:lua_wallclock_race` to `test/test_helper.exs`'s existing `exclude:` list (same list,
   same mechanism) and adds one new isolated `--only lua_wallclock_race` subprocess to
   `mix letflow.check.test`, structurally mirroring `run_wasm_hang_tests/0` line for line
   (same helper functions reused, same exit-code contract). Plain `mix test` and CI (via
   `mix letflow.check.test`) both stay correct: the former excludes Group 2 by default (as
   documented, with the same override escape hatch `:wasm_hang` already offers), the
   latter still runs every test, just Group 2 tests run isolated rather than under
   `async: true` contention.
3. **(AC3) Suite still passes serially under plain `mix test`.** Group 1 tests no longer
   race at all (structurally can't fail on a timeout, since no timeout is read) — pass
   serially exactly as before, faster if anything (no `Task.yield` wait). Group 2 tests
   are excluded from a plain `mix test` by the tag (identical mechanism to `:wasm_hang`,
   which already coexists with "suite passes serially" today) — their own serial
   correctness is unaffected by this design, since nothing about their internal logic
   changes, only their execution context (isolated subprocess instead of `async: true`
   file) when they DO run, which is strictly less contended than before, not more.
4. **(Group 2 must still prove timeout behavior).** §2.2's table lists every Group 2 test
   with the specific property it proves; none of their assertions, workloads, or timeout
   values change — only their execution isolation. §2.4 explicitly preserves this for the
   two mixed tests' racing arm. No test in Group 2 becomes unable to fail: a real
   regression to the wall-clock kill (e.g., the kill silently stops firing, or a shorter
   timeout stops terminating measurably sooner) still produces the same wrong assertion
   outcome it would today — this design only removes an unrelated, unwanted flake source
   (BEAM scheduler contention from thirty-plus concurrently-scheduled siblings), not the
   thing the test is measuring.

## 4. Structural vs. statistical verifiability (this run's own stated preference)

Per the task's own framing — a fix "whose correctness is structurally evident" is
strongly preferred here because ISSUE-FIXER could not reproduce the filed flake even
under 24-way OS-level contention plus 48 concentrated AC7-only runs, making "run it many
times and see if it still flakes" an expensive, weak validation strategy. This design is
structural for the group that matters most (Group 1, including the filed AC7 failure):

- **Group 1 (§2.1): structurally verifiable, not statistically.** After the restructure,
  the eleven Group-1 call sites (§2.1's table) never call `Task.yield/2` and never read a
  `timeout_ms` value at all — the `handle_yield_result(nil, ...)` branch that produced the
  filed failure is unreachable from these call sites **by construction**, not merely
  unlikely to fire. A validator can confirm this by reading the diff: (a) each listed call
  site now calls the new synchronous seam instead of `execute_with_manifest/3`, (b) the
  new seam's own implementation (once ELIXIR-DEV writes it) contains no `Task`/`Task.yield`
  call — a static, one-time source read, not a repeated run. This is the "failure branch
  removed / made unreachable" shape this run's task description asks for explicitly.
- **Group 2 (§2.2/§2.3): still statistical in principle** (these tests still race a real
  wall-clock timeout — that's the point), **but the contention source is removed, not
  just reduced.** Isolating them into their own single-test-file `mix test --only
  lua_wallclock_race` subprocess means their only remaining contention is the same
  low/no-contention environment `:wasm_hang`'s own isolated subprocess already runs in
  today — no `async: true` sibling tests in the same BEAM node, no sibling
  `scripts/test_parallel.sh` partitions (the isolated subprocess is one, single-node `mix
  test` invocation, not something `scripts/test_parallel.sh` itself further partitions —
  confirm this by reading how `run_wasm_hang_tests/0` invokes `mix test`, no partition
  flag). A validator does not need to reproduce a 6-way-partitioned flake to confirm this
  half: confirm structurally that (a) the tag is applied to exactly the eleven tests
  listed in §2.2/§2.4, (b) `test_helper.exs` excludes it by default, (c)
  `letflow.check.test`'s new subprocess runs `--only lua_wallclock_race` in isolation —
  all three are one-time source/diff reads, not repeated-run observations.
- **What would still require a repeated-run check, and why this design doesn't lean on
  it:** whether Group 2's own tight budgets (e.g., AC-1's `timeout_ms: 100` at line 335)
  could themselves still occasionally flake even fully isolated, on a sufficiently loaded
  host (their own single-process contention, unrelated to ISS-0426's specific 6-way
  cross-partition mechanism). This design does not claim to eliminate that residual risk
  for Group 2 — it was never in scope (HARD CONSTRAINT 4 requires keeping the race, not
  removing all contention-sensitivity from it) — and ISS-0426's own AC6 (two repeated
  end-to-end runs) is the appropriate check for that residual, narrower risk, not for the
  Group 1 fix this design is structurally confident in.

**How TEST-RUNNER/RELEASE-VALIDATOR can confirm this design's fix works, concretely:**

1. **Structural check (no flake reproduction needed):** `git diff` shows every §2.1 call
   site now uses the synchronous seam, and the seam's own body (grep for `Task.yield`
   or `Task.Supervisor.async_nolink` inside it) contains neither. This alone confirms
   Group 1 (including the exact filed line, AC7) cannot reproduce ISS-0426's specific
   failure mode again, independent of host load.
2. **`mix test` (plain, serial):** must still pass 100% (HARD CONSTRAINT 3) — this was
   already true before the fix and remains a simple regression check, not new evidence
   about contention.
3. **`mix letflow.check.test`:** all three subprocesses (default, `--only wasm_hang`,
   `--only lua_wallclock_race`) exit 0 — confirms the wiring (HARD CONSTRAINT 2) is live
   and Group 2 still passes in its isolated context.
4. **`scripts/test_parallel.sh TEST_PARALLEL_N=6`, run twice (ISS-0426 AC6's own
   requirement):** this remains the appropriate END-TO-END confirmation that the *overall*
   symptom (an unexpected failure anywhere in a 6-way run) is gone — but per point 1
   above, a validator does not need this to already trust the Group 1 fix; it is
   confirmatory, not load-bearing, for the specific filed defect. If this run happens to
   still show any failure, it would necessarily be in a Group 2 test (Group 1 is
   structurally excluded from this failure mode) or a genuinely new/unrelated issue.

## 5. Acceptance-criteria coverage

| ISS-0426 acceptance criterion | design element addressing it |
|---|---|
| AC1 — enumeration of wall-clock-sensitive tests (lua + wasm) | §1.2 (corrected/completed lua enumeration), §1.3 (wasm, verified against diagnosis) |
| AC2 (implicit — root cause documented) | §1.1 |
| AC3 — suite still passes serially under plain `mix test` | §3 point 3 |
| AC4 — production wall-clock kill semantics unchanged | §3 point 1 |
| AC5 — tagging wired into test_helper.exs and mix letflow.check.test like `:wasm_hang` | §2.3, §3 point 2 |
| AC6 — fix shown to work across ≥2 repeated end-to-end runs | §4 (structural check is primary evidence; §4's point 4 gives the confirmatory `scripts/test_parallel.sh` run TEST-RUNNER should still perform per AC6's literal text) |
| Group 2 tests must still genuinely prove timeout behavior | §2.2's table (per-test property named), §3 point 4, §2.4 for the two mixed tests |

## 6. What does NOT change

- `lib/letflow/engine/lua/executor.ex`'s public API (`execute_with_manifest/2,3`,
  `@behaviour Letflow.Engine.LuaScriptAudit.Executor`) — unchanged.
- `config/config.exs:17`, `config/test.exs:187` — both untouched (§1.4 explains why
  touching the latter would not even fix the filed failure).
- Every WASM-side file (`lib/letflow/engine/wasm/**`, the three wasm test files) —
  read-only per scope boundary, zero edits.
- `run_wasm_hang_tests/0`, `stream_and_capture/2`, `collect/2` inside
  `lib/mix/tasks/letflow.check.test.ex` — unchanged; only a new sibling function plus one
  new call site in `run/1`'s success branch are added.
- Every non-Group-1/Group-2 test in `executor_test.exs` (~35 tests: AC1 behaviour checks,
  REQ-158 manifest-hash tests, REQ-156 static/moduledoc-assertion tests, etc.) — none of
  these call `execute_with_manifest` with a wall-clock-racing shape; untouched.
- The workload scripts, budget/heap-limit values, and non-timing assertions of every
  Group 1 and Group 2 test — only the call mechanism (Group 1) or execution isolation
  (Group 2) changes, never what is asserted.

## 7. Open questions (not silently resolved)

- **OQ-1 — exact signature/name of the new synchronous test seam (§2.1.1-A).** This
  design specifies its *behavior* (calls the existing private `run_script/3` directly, no
  `Task`/`Task.yield`, `@doc false`, test-only) and *precedent* (mirrors
  `build_script_error/3`'s existing seam pattern) but leaves the exact function name,
  arity, and argument shape (e.g. whether it takes `(script_ref, registered_hash, opts)`
  matching `execute_with_manifest/3`'s own shape minus `:timeout_ms`, or a narrower
  `(manifest, script_source, budget)` matching `run_script/3`'s own current private
  signature directly) to ELIXIR-DEV. Reason for leaving it open: both shapes satisfy every
  constraint in this design equally, and pinning one down would be guessing at an
  ergonomics question (how much of `execute_with_manifest/3`'s existing
  normalize-script-ref/manifest-hash-wrapping logic the eleven Group 1 call sites still
  want) that isn't answerable from the diagnosis alone. Whichever shape ELIXIR-DEV picks,
  it must satisfy: (a) no `Task`/`Task.yield` in its call chain, (b) reuses
  `run_script/3` rather than duplicating its body, (c) `@doc false`, matching
  `build_script_error/3`'s existing precedent for a test-only seam in this exact module.
- **OQ-2 — whether `max_heap_words`-limited Group 1 sites (REQ-156 AC-1/AC-2, lines
  605/644) can use the same synchronous seam, or need a heap-limited variant.** Those two
  tests currently pass `max_heap_words:` a real integer, which today routes through
  `run_with_heap_limit/5` (the `:erlang.spawn_opt/2` + `max_heap_size` path), not
  `run_script/3` directly — a materially different function than the `nil`-heap-words
  seam OQ-1 describes. This design's intent for those two sites is the same structural
  goal (no wall-clock race), but the concrete mechanism may need to be "call
  `run_with_heap_limit/5` synchronously without its own `after timeout_ms ->` clause
  racing" rather than reusing OQ-1's exact seam verbatim — left for ELIXIR-DEV to resolve
  during implementation, flagged explicitly rather than silently assumed identical to the
  `nil`-heap-words case.
- **OQ-3 — tag name conflicts.** `:lua_wallclock_race` was checked against
  `test/test_helper.exs` and `test/letflow/engine/wasm/*_test.exs`'s existing tags
  (`:keycloak`, `:wasm_hang`) and does not collide. Not checked against every `@tag` in
  the full test suite (out of this design's read scope) — CODE-DESIGN-VALIDATOR or
  ELIXIR-DEV should `grep -rn "lua_wallclock_race" test/` once before landing to confirm
  no pre-existing use.
