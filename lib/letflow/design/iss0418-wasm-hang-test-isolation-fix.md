# ISS-0418 — Per-test subprocess isolation for the `:wasm_hang` CI flake

**Issue:** ISS-0418 (MAJOR, eleven-plus recurrences; the 2026-09-05 partial fix
— `Letflow.Engine.Wasm.InvocationLease` — did not close it; post-fix CI shows
the same ~50% failure rate as the pre-fix baseline, per `orch_note_20260905`
and `recurrence_2026_09_05` in `docs/issues/ISS-0418.yaml`).
**Diagnosis this design is built from:** `handoffs/WF03-ISS0418-20260907/step-01-issue-fixer-diagnosis.json`
(ISSUE-FIXER, 2026-09-07) — treated as verified fact, not re-derived, except
where this document independently re-confirms a specific claim against the
live repository (marked "VERIFIED LIVE" below).
**Related:** ISS-0352 (original isolation architecture this design extends
one level down), `lib/letflow/design/iss0418-wasm-concurrency-cap.md` (the
prior, insufficient design — kept as historical record, not superseded in
place), `lib/letflow/engine/wasm/invocation_lease.ex` (left untouched by this
design, see §6).
**Owner (design):** CODE-DESIGNER — **Owner (implementation):** ELIXIR-DEV
**Date:** 2026-09-07

This is a design artefact — prose, tables, and `@spec`/`@type` signatures
only. No function bodies, no `.ex` code blocks containing real implementation
logic. Any fenced code block below contains either literal terminal
commands/output (verification transcripts) or a `@type`/`@spec` line — never
executable Elixir logic.

---

## 1 — Scope reframing (read first)

ISS-0418's own on-file acceptance-criteria framing (queue task 418 / GH#816)
asks for "a concurrency cap on in-flight wasmex/WASM guest invocations …
operator-configurable." That framing is **already fully implemented** —
`Letflow.Engine.Wasm.InvocationLease` (merged 2026-09-05, PR #927,
`e5d07019`) is exactly such a cap, correctly designed, and wired into all
five currently-tagged `:wasm_hang` test bodies.

**It does not fix the flake, and this is not a new finding — it is already
proven on ISS-0418's own file.** `orch_note_20260905` and
`recurrence_2026_09_05` both record post-fix CI runs failing at materially
the same ~50% rate as the pre-fix baseline (3-in-6). ISSUE-FIXER's diagnosis
(step-01 handoff) explains why, mechanically: every `:wasm_hang` test is
`async: false`, and `run_wasm_hang_tests/0` (this task's own code, §2 below)
runs all of them sequentially inside **one shared, long-lived subprocess**.
Nothing is ever concurrent in that run — the cap gates *simultaneous*
admission, and simultaneity never occurs here, so the cap is never
contended. The real mechanism is **cumulative leak accumulation**: each
`:wasm_hang` test permanently wedges one native `wasmex` Tokio worker thread
in that one shared subprocess (§3), and by the last test or two, a
small-CPU-count CI runner's pool is already exhausted from the tests that
ran earlier in the *same* subprocess.

**This design does not touch the concurrency cap.** It targets the actual
mechanism: restructuring `lib/mix/tasks/letflow.check.test.ex`'s
`run_wasm_hang_tests/0` so each `:wasm_hang` test gets its own fresh,
short-lived subprocess — a fresh BEAM node, and therefore a fresh, unleaked
native thread pool — instead of sharing one subprocess (and one
accumulating pool) with its siblings.

### 1.1 — Recommended AC correction (an explicit output of this design)

ISS-0418's `acceptance_criteria`/description text should be corrected the
same way REQ-226's AC4 text was corrected earlier in this project: **append,
do not silently rewrite.** Concretely, DOC-UPDATER should:

1. Leave the existing "operator-configurable concurrency cap" criterion in
   place but annotate it, in a new dated block (matching this issue's own
   established append-only convention — `orch_note_20260905`,
   `partial_fix_20260905`, etc.), as: **"SATISFIED, 2026-09-05
   (`InvocationLease`), for its own stated purpose (bounding simultaneous
   production burst blast-radius, `Letflow.Engine.Wasm.InvocationLease`) —
   but NOT SUFFICIENT to close this issue's CI-flake symptom, confirmed by
   this issue's own post-fix CI evidence. Do not re-open or re-tune
   `InvocationLease` to chase the flake — see the 2026-09-07 diagnosis and
   this design doc."**
2. Add a **new, second acceptance criterion** that is what this design and
   its follow-on implementation actually close:

   > **AC-NEW: Each `:wasm_hang`-tagged test in `test/letflow/engine/wasm/`
   > runs in its own dedicated, freshly-booted `mix test <file>:<line>`
   > subprocess inside `mix letflow.check.test`'s `run_wasm_hang_tests/0` —
   > never sharing one subprocess (and therefore one accumulating native
   > thread pool) with another `:wasm_hang` test. Verified by N consecutive
   > clean local runs of the restructured harness (§8) with zero
   > wasm_hang-class failures.**

3. Retitle is optional but recommended for future readers: the issue's
   `title` field currently reads "…implement OQ-5 operator-configurable cap
   on concurrent WASM invocations (root fix for ISS-0352 recurrence
   class)" — append a note that the root fix for the recurrence class turned
   out to be test-harness process isolation, not the cap, without deleting
   the original title (append-only, matching every other correction in this
   issue's own history).

This design proceeds on the assumption ORCH/DOC-UPDATER will apply
correction (1)-(3) once this design clears CODE-DESIGN-VALIDATOR; it is
named here as a required output, not left implicit.

---

## 2 — Current state of `run_wasm_hang_tests/0` (verified by direct read)

Read in full: `lib/mix/tasks/letflow.check.test.ex` (417 lines, this
session). Current shape, exactly as it stands today:

- `run/1` calls three subprocess-launching private functions in sequence:
  `run_main_suite/0`, `run_wasm_hang_tests/0`, `run_lua_wallclock_race_tests/0`.
- `run_wasm_hang_tests/0` (lines 323-347) does exactly this, and nothing
  else:
  1. `stream_and_capture("mix", ["test", "--only", "wasm_hang"])` — **one**
     subprocess, covering every `:wasm_hang`-tagged test across every file.
  2. If `hang_exit_code != 0` → `Mix.raise/1` with a generic "real test
     failure/error" message (no per-test detail beyond whatever `mix test`'s
     own streamed stdout already showed live).
  3. If the ISS-0069 warning substring appears anywhere in the captured
     output → `Mix.raise/1` with the offending lines.
  4. Otherwise → `Mix.shell().info/1` a single "OK" line.
- `stream_and_capture/2` (lines 392-404) is a **generic, already-reusable**
  helper: it takes `(cmd, args)`, opens an OS-level `Port`, streams
  stdout+stderr live while also capturing the full text, and returns
  `{captured_text, exit_status}`. It has no dependency on `:wasm_hang`
  specifics and is reused as-is by this design (§4) — not modified.
- `collect/2` (lines 406-415) is `stream_and_capture/2`'s own receive-loop,
  also reused unmodified.
- The module's exit-code contract (moduledoc, lines 83-98) currently states:
  "Exits `1` if the runner (or either isolated subprocess) reports real
  failures" — "either isolated subprocess" (singular per tag class) must be
  updated to describe N per-test subprocesses for `:wasm_hang` specifically
  (§7).

**Nothing about `run_lua_wallclock_race_tests/0` or `run_main_suite/0`
changes in this design.** `:lua_wallclock_race` tests are a *contention*
problem (ISS-0426, `iss426-wallclock-test-contention.md` §2.3), not a
*cumulative-leak* problem — they don't leak anything, so they have no
analogous need for per-test process isolation, and restructuring them is out
of scope here.

---

## 3 — The mechanism, and why per-test (not per-file) isolation is required

Recap of ISSUE-FIXER's diagnosis, load-bearing for the design in §4-§5:

- `wasmex`'s native Tokio worker pool is sized to
  `available_parallelism()` at NIF-load time (once per OS process) and never
  regrows. A hung guest call permanently occupies one pool slot for the rest
  of that OS process's life — confirmed unrecoverable within a BEAM node's
  lifetime (REQ-170 design doc §1.4, live-verified up to a 90s window).
- On the real CI runner (`ubuntu-latest`, confirmed N=4 vCPU by a real CI log
  line quoted in the prior design doc), the pool is roughly that size or
  smaller.
- **Current state, verified live this session** (§2): 5 `:wasm_hang`-tagged
  test bodies across 3 files, one shared subprocess. Per-test dispatch count,
  reconfirmed by direct read of all three files (not assumed from the prior
  design doc's now-stale line numbers):

| File:line (current) | AC / description | Live hang dispatches in this test body | Distinct native Stores leaked |
|---|---|---|---|
| `test/letflow/engine/wasm/call_timeout_test.exs:79` | AC2, wasmex's interrupt-and-keep-Store claim | 2 (both against the **same** `pid`/Store — the second call proves the Store stays wedged, it does not open a new one) | 1 |
| `test/letflow/engine/wasm/host_api_write_test.exs:461` | REQ-170 wall-clock timeout abandons a staged write | 1 | 1 |
| `test/letflow/engine/wasm/plugin_handler_test.exs:155` | AC5, outer timeout surfaces as `{:error, reason}` | 1 | 1 |
| `test/letflow/engine/wasm/plugin_handler_test.exs:392` | AC3, outer bound independent of inner `timeout_ms` | 1 | 1 |
| `test/letflow/engine/wasm/plugin_handler_test.exs:485` | AC4 (+ merged former AC1), shorter `timeout_ms` binds sooner | 2 (two independent `PluginInterface.invoke/2` calls, different `timeout_ms`, each opens its own fresh Store) | 2 |

Total: 5 tagged test bodies, 7 live dispatch calls, **6 permanently-leaked
Stores** in one shared subprocess today (matches ISSUE-FIXER's diagnosis
count exactly — the file:line numbers in the diagnosis's own prose are
slightly stale relative to this session's live read, but the leak-count
arithmetic is identical: 1 + 1 + 4, here itemized as 1+1+1+1+2).

**Why per-file splitting is not enough:** `plugin_handler_test.exs` alone
carries 3 of the 5 tagged tests and 4 of the 6 leaks. A subprocess isolated
at file granularity would still accumulate 4 leaks in one shared process —
on a 4-slot pool, still exhaustible by the last test in that file. Isolation
must be at the granularity of the **individual test body** (which, per the
next section, is also the finest granularity `mix test` can address).

---

## 4 — Per-test isolation design

### 4.1 — CLI composition: verified live, not assumed

The task explicitly requires verifying whether `mix test <file>:<line>
--only wasm_hang` is a real, working combination, since Mix's own line-number
targeting could plausibly override tag filtering rather than compose with
it. **Verified live this session, on this repository, with `mix test
--dry-run` (which parses filters and lists matched tests without executing
them):**

```
$ mix test test/letflow/engine/wasm/plugin_handler_test.exs:155 --only wasm_hang --dry-run
Running ExUnit with seed: 986321, max_cases: 16
Excluding tags: [:test]
Including tags: [location: {"test/letflow/engine/wasm/plugin_handler_test.exs", 155}]

Tests that would be executed:
test/letflow/engine/wasm/plugin_handler_test.exs:155
```

```
$ mix test test/letflow/engine/wasm/plugin_handler_test.exs --only wasm_hang --dry-run
Running ExUnit with seed: 454740, max_cases: 16
Excluding tags: [:test, :keycloak, :lua_wallclock_race]
Including tags: [:wasm_hang]

Tests that would be executed:
test/letflow/engine/wasm/plugin_handler_test.exs:392
test/letflow/engine/wasm/plugin_handler_test.exs:155
test/letflow/engine/wasm/plugin_handler_test.exs:485
```

**Finding, stated precisely: `--only <tag>` and `<file>:<line>` do NOT
compose.** Per Elixir's own `mix help test` documentation (also confirmed
live), `<file>:<line>` is pure syntactic sugar for `--exclude test --include
line:N` (shown above as `location: {...}`), and this substitution **entirely
replaces** whatever `--include`/`--only` filters were also given on the same
command line — the "Including tags" line shows only the location filter,
never `wasm_hang`, in the first transcript. Crucially, this also means
`<file>:<line>` on its own **already bypasses** `test/test_helper.exs`'s
default `exclude: [:keycloak, :wasm_hang, :lua_wallclock_race]` (the printed
"Excluding tags" is just `[:test]`, not the full default list) — a test
addressed by exact file:line runs regardless of its own tags being
excluded-by-default elsewhere.

**Design consequence:** the per-test subprocess command is
`mix test <file>:<line>` **alone** — no `--only wasm_hang` suffix. Adding it
would be harmless in the sense that it changes nothing (it is silently
discarded, as demonstrated above), but it would misleadingly suggest to a
future reader that it does something. The implementer should not add it, and
should carry a one-line comment at the call site (citing this design doc
section) explaining why it is intentionally absent, so nobody "fixes" the
omission later.

### 4.2 — Enumeration: discover tests dynamically, do not hardcode file:line pairs

**Rejected alternative: statically grep test sources for `@tag :wasm_hang`
followed by the next `test "..." do` line, deriving line numbers by hand
or via a project-local regex.** Rejected because it re-implements, fragilely
and redundantly, exactly the tag-resolution logic ExUnit itself already
performs correctly (including edge cases this design doc need not reason
about itself, e.g. a `@tag :wasm_hang` applied to a whole `describe` block
rather than one `test`, or multiple `@tag` lines with blank lines between
them) — the same "sometimes catching, sometimes not" fragility this module's
own moduledoc already rejects for the ISS-0069 substring check (§1's
rationale there generalizes here).

**Chosen approach: ask ExUnit itself, via a `--dry-run` discovery
subprocess, which tests `:wasm_hang` currently resolves to**, then launch one
real subprocess per discovered `{file, line}` pair.

```
@type wasm_hang_location :: {file :: Path.t(), line :: pos_integer()}

@spec discover_wasm_hang_tests() :: [wasm_hang_location()]
```

Behavior (prose):

1. Run `mix test --only wasm_hang --dry-run` via the existing
   `stream_and_capture/2` helper (reused unmodified, §2) — **verified live
   this session** that this correctly lists every currently-tagged test
   (both dry-run transcripts above confirm the full 3-test list for one
   file; the same command with no file argument lists all 5 across all 3
   files).
2. Locate the `"Tests that would be executed:"` line in the captured output;
   take the block of lines immediately following it, up to the next blank
   line or a line that does not match the `file:line` shape (this bounds the
   parse to exactly the test-list block, the same "scope the regex narrowly,
   don't trust the whole stream" discipline `find_partition_log_dir/1`
   already uses for the ISS-0069 substring check, §2).
3. Parse each such line into a `{file, line}` pair via a
   `~r/^(test\/\S+\.exs):(\d+)$/` -shaped regex (mirrors
   `index_partition_logs/1`'s own existing regex-based line-number
   extraction, §2 — same idiom, new pattern).
4. Sort the resulting list (by file, then line) for deterministic subprocess
   launch order across runs — dry-run's own listing order is not guaranteed
   stable across seeds, and stable ordering makes CI logs easier to compare
   run-to-run.
5. If the discovery subprocess exits nonzero, or the `"Tests that would be
   executed:"` line is absent, or the parsed list is empty (all three are
   the same category of "the discovery mechanism itself is broken" failure
   `find_partition_log_dir/1`'s own `:not_found` handling already
   establishes the precedent for, §2) → **hard-fail via `Mix.raise/1`**,
   never silently proceed with zero tests and report a false "OK." This
   mirrors the existing module's own stated discipline exactly (moduledoc:
   "this task hard-fails … rather than silently passing").

This makes the harness **self-updating**: adding, removing, or renaming a
`:wasm_hang` test in any of the three files (or a fourth, future file) is
picked up automatically on the next `mix letflow.check.test` run, with no
edit to `letflow.check.test.ex` required — matching this module's own
existing "no hardcoded partition count" precedent for the main-suite
discovery logic (§2, `partition_logs/1`).

### 4.3 — Per-test subprocess execution and aggregation

```
@type wasm_hang_test_result :: %{
  location: wasm_hang_location(),
  output: String.t(),
  exit_code: non_neg_integer()
}

@spec run_single_wasm_hang_test(wasm_hang_location()) :: wasm_hang_test_result()

@spec run_wasm_hang_tests() :: :ok | no_return()
```

`run_wasm_hang_tests/0` (replacing today's body, §2) becomes, in prose:

1. `locations = discover_wasm_hang_tests()` (§4.2; raises internally on a
   broken discovery run, per its own contract — `run_wasm_hang_tests/0`
   does not need its own separate empty-list check).
2. For each `{file, line}` in `locations`, in the sorted order from §4.2,
   call `run_single_wasm_hang_test/1`: build the command as
   `mix test "#{file}:#{line}"` (§4.1 — no `--only` suffix), run it via the
   existing `stream_and_capture/2` helper (fresh OS process = fresh BEAM
   node = fresh, unleaked native pool, automatically, by construction — no
   new mechanism is needed to get this property, it is what "a new OS
   subprocess" already means), and record `{location, output, exit_code}`.
   Each subprocess's live stdout/stderr is still streamed as it runs
   (`stream_and_capture/2`'s existing behavior, unchanged) so a CI viewer
   watching the log sees per-test progress in real time, same visibility
   as today's single-subprocess run had for the suite as a whole.
3. After all `N` subprocesses complete, partition the `N` results into those
   whose `exit_code` is nonzero ("failing") and the rest.
4. If `failing != []`: print the full captured output of every failing
   result (mirrors `report_partition_failures/1`'s existing pattern, §2 —
   same "show the real failure text, don't make the reader dig for it"
   principle, reused for a new data shape), then `Mix.raise/1` with a
   summary line naming exactly which `{file, line}` locations failed and
   the count (e.g. `"2/5 isolated wasm_hang tests failed:
   test/.../call_timeout_test.exs:79, test/.../host_api_write_test.exs:461"`)
   — a strict improvement over today's single generic "exited N" message,
   since the caller now knows exactly which test(s) failed without needing
   to scroll the streamed log.
5. If `failing == []`: apply the existing ISS-0069 substring check (§2's
   `check_substring_across_logs/1`-equivalent logic — same target substring,
   applied across the concatenation of all N outputs instead of one) and
   `Mix.raise/1` on a hit, exactly mirroring today's substring-check
   behavior and message shape, just sourced from N outputs instead of one.
6. Otherwise, `Mix.shell().info/1` a single "OK" line stating `N/N isolated
   wasm_hang tests passed, each in its own subprocess" — direct analog of
   today's "OK -- isolated :wasm_hang run also passed clean," updated to
   name the new per-test shape so a reader of the log understands what
   actually ran.

**Exit-code contract update (§2's moduledoc, §7 of this design):** "exits 1
if … either isolated subprocess reports real failures" becomes "exits 1 if …
the discovery subprocess fails, or any of the N per-test `:wasm_hang`
subprocesses reports a real failure, or the target substring appears in any
of their outputs." The `:lua_wallclock_race` subprocess's own contract
clause is unchanged.

---

## 5 — The irreducible pair: `plugin_handler_test.exs:485` (AC4)

The diagnosis calls out one test body — the AC4 test, currently at
`plugin_handler_test.exs:485` (§3's table) — as containing **two** sequential
live hang dispatches inside **one** `test do ... end` block, and states this
pair must not be split into two separate tests/subprocesses.

**This design does not need any special-case code to honor that.** Isolation
granularity in §4 is "one `mix test <file>:<line>` subprocess per
ExUnit-resolved test," and `<file>:<line>` addressing is inherently
test-body-atomic — there is no CLI mechanism to run "half of" a single
`test do ... end` block in its own subprocess without first splitting the
test's *source code* into two separate `test` blocks. Since this design is
explicitly test-harness-only (§6) and does not touch test bodies, the pair
stays together automatically, by construction, for as long as it remains one
`test` block in the source.

**What must be recorded, and where, so a future refactor doesn't undo this
by splitting the test body itself:** the existing design doc
(`iss0418-wasm-concurrency-cap.md` §6.3.1 item 1/3) already documents why
this specific pair's two dispatches cannot be pulled apart without breaking
AC4's own ordering assertion (the test needs both the 300ms and 7,000ms
results in scope together to assert the shorter one bound sooner) — that
reasoning is not repeated here, only cross-referenced. **This design adds one
new requirement for whoever implements it:** add a one-line comment
immediately above `@tag :wasm_hang` at `plugin_handler_test.exs:483`
(alongside the existing ISS-0418 comments already there) stating that this
test body's two dispatches are a documented irreducible pair (citing this
design doc §5 and the prior design doc §6.3.1) and must not be split into
two `test` blocks to "parallelize" or "further isolate" it — splitting it
would not reduce the isolated-subprocess leak count in any way that matters
(each dispatch already gets counted as leaking one Store regardless, per
§3's table) and would only add a second, unnecessary `mix test` boot for no
benefit, since both dispatches already land in one already-isolated
subprocess under this design. This is the correct place to record the
exception — in the test file's own comments, next to the code it constrains
— rather than only in a design doc a future editor of that file may never
open.

---

## 6 — Confirmed out of scope: `InvocationLease` is untouched

Per ISSUE-FIXER's diagnosis recommendation (items 1 and 7) and re-confirmed
by this design's own read of `lib/letflow/engine/wasm/invocation_lease.ex`:

- **No change to its cap formula, config key, or semantics.** Its default
  (`max(div(System.schedulers_online(), 2), 1)`) and config surface
  (`Application.get_env(:letflow, :invocation_lease, [])[:cap]`) are correct
  for its own actual purpose (bounding simultaneous burst blast-radius
  against genuine concurrent multi-tenant production traffic, once the
  still-open OQ-C dispatch-integration work lands) and are not re-tuned here
  — no cap value can fix a problem (cumulative sequential leakage) that
  never exceeds the cap in the first place (diagnosis's own framing,
  restated).
- **The existing `try_acquire/0`/`release/1` wiring already present in all
  five `:wasm_hang` test bodies (added by the 2026-09-05 partial fix) is
  left in place, unmodified, by this design.** It remains correct and
  harmless under per-test isolation: with one test per subprocess, its own
  `try_acquire/0` always succeeds trivially (nothing else is ever
  contending for a lease in that process), so it neither helps nor hurts
  this design's fix — removing it would be an unrelated, unnecessary cleanup
  this design does not perform, since ORCH's own governing instruction in the
  prior design doc (§6.0) was explicit that wiring additive to already-passing
  code is acceptable and should not be churned without reason.
- **No production call site gains a lease.** `PluginHandler.run_guest/3`
  and `PluginInterface.invoke/2,3` remain untouched, exactly as before —
  this design is entirely confined to
  `lib/mix/tasks/letflow.check.test.ex`, a test-harness file, never a
  production runtime module.

---

## 7 — Cost/tradeoff, stated explicitly with a real measurement

**Measured live this session** (this dev host, 8 logical CPUs, warm
`mix compile` cache — i.e. the realistic per-subprocess-boot cost once CI's
own initial compile has already happened for the run):

```
$ time mix test test/letflow/engine/wasm/plugin_handler_test.exs:155 --dry-run
real    0m1.715s
```

**Overhead added by this design:** today's `run_wasm_hang_tests/0` spawns
**1** subprocess. This design's replacement spawns **1 discovery subprocess
+ N per-test subprocesses** (currently N=5, so 6 total). Each subprocess
pays roughly the same ~1.5-2s fixed boot cost measured above (BEAM start +
compile-manifest check + tenant-provisioning-check DB round-trips already
visible in the transcript), on top of whatever the test's own real work
takes (each `:wasm_hang` test's happy-path duration is small — under a few
seconds — since these tests are specifically designed so their *own* outer
bound fires quickly; a genuine multi-minute hang is the failure case this
design exists to stop from cascading into siblings, not the normal case).
**Net added wall-clock, worst case: roughly 5 extra subprocess boots ×
~2s ≈ 10s** added to `mix letflow.check.test`'s total run time on a
CI-class host, likely less on CI's own typically-faster cold-boot-avoided
path once warmed.

**This is an acceptable tradeoff, stated explicitly rather than left
implicit, given the actual cost on the other side of the ledger:** the flake
this design targets has recurred **eleven-plus times** (ISS-0418's own
running tally) as of this design's writing, each recurrence costing either a
60-180s `ExUnit.TimeoutError` wait plus a full CI rerun (minutes of CI/agent
wall-clock, per run), or — per this issue's own repeatedly-documented
pattern — an agent judging the flake "probably unrelated" and merging past a
red gate, which is exactly the reflex ISS-0441 warns trains agents into. A
~10-second fixed addition to every green run, in exchange for closing a
~50%-of-runs flake that currently costs multiple CI reruns per week, is a
clear net win and is not treated as free in this design.

---

## 8 — Verification: what "fixed" means once the AC is corrected

Per §1.1's new acceptance criterion, "fixed" is verified as:

1. **Primary gate (fast, reproducible, no CI-flake-of-its-own risk):**
   RELEASE-VALIDATOR (or TEST-RUNNER, per whichever role executes this)
   runs the restructured `mix letflow.check.test` **N consecutive times
   locally** (N=20 is recommended — large enough to make a return to the
   ~50% pre-fix rate implausible by chance if the fix genuinely holds, small
   enough to run in well under the cost of a single one of today's
   recurring CI reruns given §7's ~10s-per-run overhead) and confirms **0
   failures classifiable as the `:wasm_hang` mechanism** across all 20 runs.
   A single unrelated flake in an unrelated stage (main suite or
   `:lua_wallclock_race`) during this local loop does not invalidate the
   result — only a `:wasm_hang`-class failure does.
2. **Secondary corroboration (matches this issue's own established
   evidence-gathering convention — `orch_note_20260905` et al.):** ORCH
   continues observing real CI runs on unrelated PRs after this fix merges,
   the same passive-observation convention already used four times in this
   issue's history, and appends a dated note to `ISS-0418.yaml` if the
   `:wasm_hang` stage is observed to fail even once post-fix (which, given
   this design's own reasoning in §0/§5.4 of the prior design doc — the
   native leak is still real and permanent, only now contained to a
   single-test subprocess instead of a five-test one — would itself be
   informative: a post-fix failure would now have to be a *single* test's
   own subprocess exhausting an implausibly small (1-2 slot) pool by itself,
   a qualitatively different and much narrower risk than today's
   cross-test accumulation, worth its own fresh diagnosis if observed rather
   than assumed impossible).
3. **What does NOT settle it:** a single clean CI run, given this exact
   issue's own history of ~50%-rate flakes that pass more often than they
   fail in any small sample. Step 1's N=20 local loop exists specifically
   to avoid repeating that measurement mistake.

---

## 9 — Open questions (explicitly not resolved here)

- **OQ-1:** Should the discovery subprocess's `--dry-run` invocation also be
  reused to hard-fail loudly if a *new* file introduces a `:wasm_hang` tag
  with an unexpectedly large dispatch count (e.g. a future test author adds
  a 5-dispatch test body without realizing the isolation contract)? This
  design does not add such a check — §4.2's discovery only extracts
  `{file, line}` pairs, not per-test dispatch counts, and doing the latter
  would require either static analysis of test bodies (rejected, §4.2) or
  runtime instrumentation of `Wasmex.start_link/1` call counts (out of
  scope for a mix task). Left as a real open question, not silently
  resolved either way — whoever implements this should not assume either
  answer without checking with CODE-DESIGN-VALIDATOR/REVIEWER.
- **OQ-2:** N=20 in §8 is this design's recommendation, not a hard
  requirement from ISSUE-FIXER's diagnosis or ISS-0418.yaml. ELIXIR-DEV/
  RELEASE-VALIDATOR may choose a different N with justification; this design
  does not treat the exact number as load-bearing, only the principle that a
  single run is insufficient evidence for this specific issue's own
  documented history.
