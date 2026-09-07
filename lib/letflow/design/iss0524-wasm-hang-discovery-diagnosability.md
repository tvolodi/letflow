# ISS-0524 — wasm_hang discovery: diagnosability + bounded retry

## 0. Context and scope

ISSUE-FIXER's diagnosis (`handoffs/WF03-ISS0524-20260907/step-01-issue-fixer-diagnosis.json`)
found ISS-0524's claimed regression NOT reproducible: all five real `@tag :wasm_hang`
sites are intact, `mix test --only wasm_hang --dry-run` correctly discovers all five
live, and `Mix.Tasks.Letflow.Check.TestTest` passes consistently across five repeated
runs with distinct seeds. `discover_wasm_hang_tests/0`'s parsing logic and
`install_wasm_hang_aware_fake_mix/1`'s fixture are both judged correct and are **not**
touched by this design. The most likely root cause of the original observation is a
one-off transient/environmental flake (e.g. a resource-constrained host truncating the
discovery subprocess's compile step), not a code defect.

This design implements ISSUE-FIXER's two scoped recommendations against
`lib/mix/tasks/letflow.check.test.ex`:

1. Include the raw captured discovery output in the `Mix.raise` message that fires
   when the "Tests that would be executed:" block is empty/absent, so a future
   recurrence is diagnosable from the terminal/CI log alone, without a live repro.
2. Add one bounded, single retry of the discovery dry-run subprocess when the first
   attempt's parsed block is empty, to rule out one-shot compile-race flakiness —
   without weakening the module's "never silently proceed with zero" policy: a
   persistently-empty block after the retry still hard-fails.

### Out of scope (must not change)

- `try_acquire`-style admission/isolation logic — unrelated to this issue.
- Any real `@tag :wasm_hang` test site (`plugin_handler_test.exs`,
  `call_timeout_test.exs`, `host_api_write_test.exs`).
- `extract_test_list_block/1`'s bounded-window filter logic and
  `parse_wasm_hang_location!/1` — both already correct per live verification.
- `install_wasm_hang_aware_fake_mix/1`'s fixture shape (its dispatch-on-argv-shape
  fake for `--dry-run` / `<file>:<line>` / fallback) — correct as-is.
- The zero-tolerance policy itself: an empty discovery block must still terminate the
  task via `Mix.raise`, never proceed with an empty test list, no matter how many
  attempts are made.
- `run_single_wasm_hang_test/1`, `run_wasm_hang_tests/0`'s overall failure/substring
  reporting, and everything in `run_main_suite/0`/`run_lua_wallclock_race_tests/0` and
  the main-suite log-parsing helpers — none of this is touched.

## 1. Retry decision: include one bounded retry (yes)

**Decision: add exactly one retry**, gated solely on "first attempt's parsed test-list
block is empty," with no retry on a second empty result.

Reasoning:

- ISSUE-FIXER's own diagnosis already documents, via the existing DEVIATION comment
  above `extract_test_list_block/1` in the current code, that ExUnit's
  non-deterministic compiler-warning emission interleaves with discovery output
  "seemingly regardless of compile-manifest cache state" — i.e. this subprocess's
  output shape is independently already known to have run-to-run variance under
  compile-related conditions. A single retry directly targets exactly that class of
  one-shot compile/manifest race (e.g. a stale or half-written `.beam`/manifest file
  on the first invocation that a second, fresh invocation would not hit) at near-zero
  cost: discovery is a dry-run, it does not execute any test, so a second invocation
  is cheap (no wasm worker threads, no isolated per-test subprocesses) and safe to
  repeat.
- It costs nothing to the zero-tolerance discipline: the retry only ever *delays* a
  hard failure by one subprocess invocation, it never converts a real failure into a
  pass. A discovery run that is genuinely broken (not merely flaky) will still be
  empty on the second attempt and the task still hard-fails, per the existing "never
  silently proceed with zero" policy, which the moduledoc's ISS-0418 section documents
  and which this design does not touch.
- It is bounded to exactly one retry (not a loop, not exponential backoff) so the
  worst-case added latency is one extra `mix test --only wasm_hang --dry-run`
  invocation — acceptable inside `mix letflow.check`'s existing sequential test stage,
  and avoids masking a persistently broken discovery behind a longer retry loop that
  would make a real regression slower to surface.
- Given ISSUE-FIXER explicitly could not confirm the transient-flake mechanism (no
  surviving raw output from the original observation), the retry is a hedge that costs
  one subprocess run and gains a data point (whether the second attempt differs from
  the first) that would be captured in the improved failure message if both attempts
  end up empty — see §3.

## 2. Data shape changes

### 2.1 New type: `wasm_hang_discovery_attempt`

A new type capturing one discovery subprocess attempt's raw result, so both the
retry logic and the improved error message can refer to it uniformly:

- `wasm_hang_discovery_attempt :: %{output: String.t(), parsed: [String.t()]}`
  - `output` — the full raw captured stdout+stderr of one
    `mix test --only wasm_hang --dry-run` invocation (`stream_and_capture/2`'s first
    return value, unmodified).
  - `parsed` — the result of running `extract_test_list_block/1` against `output`
    (a list of raw `"test/path.exs:N"` lines, empty when the block was empty/absent).

This type does not change `extract_test_list_block/1`'s own signature (still takes
and returns exactly what it does today — a list of raw test-list lines from one
output string). It exists purely to let `discover_wasm_hang_tests/0` carry both
attempts' raw output forward to the failure-message builder without re-running
discovery a third time.

## 3. Function-level design

### 3.1 `discover_wasm_hang_tests/0` — revised behavior

Signature is unchanged: `@spec discover_wasm_hang_tests() :: [wasm_hang_location()]`
(still returns the sorted list of `{file, line}` locations, or never returns because
it hard-fails via `Mix.raise`).

Revised internal shape (behavior, not code):

1. Run the discovery subprocess exactly as today (`stream_and_capture/2` with
   `["test", "--only", "wasm_hang", "--dry-run"]`), producing the first
   `wasm_hang_discovery_attempt`.
2. If its `parsed` list is non-empty: proceed exactly as today — map each line
   through `parse_wasm_hang_location!/1` and sort. No retry occurs on a successful
   first attempt; this is the common case and must not incur any added latency or
   extra subprocess invocation.
3. If its `parsed` list is empty: log one informational line via `Mix.shell().info/1`
   noting that the first discovery attempt found an empty test-list block and a
   single retry is being attempted (so a reader watching CI output live sees the
   retry happening, not silence followed by an unexplained delay), then run the
   discovery subprocess a second time, producing a second
   `wasm_hang_discovery_attempt`.
4. If the second attempt's `parsed` list is non-empty: proceed with it exactly as the
   success path in step 2 (map + sort), but additionally emit one informational line
   noting the first attempt was empty and the retry succeeded — this is a signal
   worth surfacing even on the "OK" path, since a recurring need for the retry across
   multiple `mix letflow.check` runs would itself be evidence of a real (not
   one-off) flake worth escalating as its own issue, even though this task does not
   itself track recurrence across runs.
5. If the second attempt's `parsed` list is ALSO empty: hard-fail via `Mix.raise`,
   per §3.2 below. This is the only hard-failure path for discovery; the "never
   silently proceed with zero" policy is preserved exactly — the task still never
   returns/proceeds with an empty locations list under any circumstance.

Invariant preserved: `discover_wasm_hang_tests/0` either returns a non-empty
`[wasm_hang_location()]` list, or does not return at all (raises). It never returns
`[]`. This invariant is unchanged from today's implementation and must be preserved
by any test added against this design.

### 3.2 Revised `Mix.raise` message (both attempts empty)

The hard-fail message must be extended to include the raw captured output, not just
the current fixed prose. Content requirements for the message:

- Keep the existing framing prose unchanged in substance ("exited 0 but its 'Tests
  that would be executed:' block was empty or absent... cannot tell whether that
  means zero tests now exist or discovery itself is broken... hard failure rather
  than silently passing"), so existing understanding of *why* this fails is not
  lost.
- State explicitly that a retry was attempted and also came back empty (so a reader
  knows this is not a false report of only one attempt) — e.g. naming both "first
  attempt" and "retry attempt" explicitly in the message text.
- Append the raw captured output of the **retry attempt** (the second,
  most-recent discovery subprocess run), truncated to its **last 40 lines**. Include
  a leading marker line (e.g. distinguishing "last 40 lines of retry attempt's raw
  output" from the full-output case) so a reader knows truncation occurred when the
  captured output exceeds 40 lines, and print it verbatim (no re-parsing) below the
  prose.
  - Rationale for "last N lines" rather than the full output or the first attempt's
    output: `mix test --dry-run`'s captured stream includes the full compile step,
    which can run to hundreds of lines of compiler/deprecation-warning noise on a
    cold or partially-invalidated build cache (the exact class of noise
    `extract_test_list_block/1`'s own DEVIATION comment already documents as
    interleaving with the test-list block). The diagnostically useful region is the
    tail of the stream — where the "Tests that would be executed:" header, any
    entries, and the terminator line would appear if discovery had produced them —
    not the early compile-warning noise. Dumping the full output risks burying the
    diagnostic region in unrelated noise and bloating CI logs on every future
    recurrence; the tail keeps the message bounded and focused. N = 40 is chosen as
    comfortably larger than a real discovery block's typical size (5 real
    `:wasm_hang` locations today, one line each, plus a handful of header/terminator
    lines) while still being small enough to read directly in a terminal or CI log
    without scrolling through unrelated content.
  - If the retry attempt's raw output is empty (zero bytes/lines captured — a
    distinct, more severe failure than "block empty," e.g. the subprocess produced
    no output at all), state that explicitly instead of printing an empty block, so
    a reader isn't left staring at a blank section wondering if the message is
    truncated incorrectly.
- Do not include the first attempt's raw output in the message body (keeping the
  message bounded to one attempt's tail plus the informational retry-occurred
  framing); the informational `Mix.shell().info/1` line from step 3 above already
  surfaced live during the run (and is visible in CI's own captured stdout for the
  task) that a first attempt occurred and was empty, so this is not fully lost, only
  not duplicated inside the `Mix.raise` message itself.

### 3.3 New private helper: last-N-lines extraction

A new small helper is needed to take one attempt's raw `output` string and return its
last 40 lines as a single string suitable for embedding in the `Mix.raise` message
(with a truncation-indicator prefix line when the full output has more than 40
lines, and the full output verbatim with no indicator when it has 40 lines or fewer).

- `@spec last_output_lines(String.t(), pos_integer()) :: String.t()`
- Input: the raw captured output string, and the line count `N` (called with `40` at
  the one call site in §3.2; take `N` as a parameter rather than hardcoding 40 inside
  the helper, so the retry-message call site's choice of 40 stays visible and testable
  independently of the helper's own logic).
- Output: a single string, newline-joined, containing at most the last `N` lines of
  the input, prefixed with an explicit truncation marker line when truncation
  occurred (i.e. when the input had more than `N` lines), and with no such marker
  when it did not.
- This helper does not interpret or parse the content — pure tail-taking on the
  already-split-by-newline structure `extract_test_list_block/1` also uses
  internally, so it is consistent with existing conventions in this module for
  treating captured subprocess output as a plain line-oriented string.

## 4. Failure-shape / error-shape summary

| Path | Outcome | Message contains |
|---|---|---|
| First discovery attempt's block non-empty | `discover_wasm_hang_tests/0` returns immediately (no retry, no message) | n/a |
| First empty, retry's block non-empty | Returns after retry; informational lines only (no raise) | n/a (info via `Mix.shell().info/1`, not `Mix.raise`) |
| First empty, retry also empty | `Mix.raise` (task terminates) | Existing framing prose + explicit "first and retry both empty" statement + last-40-lines (or full, if ≤40) of retry's raw output, with truncation marker when applicable, or an explicit "retry produced no output at all" statement when the retry's raw output was itself empty |

No other error path in this module (`run_wasm_hang_tests/0`'s failing-test path,
`parse_wasm_hang_location!/1`'s parse-failure path, the main-suite paths, the
lua_wallclock_race path) is altered by this design.

## 5. Test design (for TEST-DESIGNER)

Target file: `test/mix/tasks/letflow_check_test_test.exs`, using the existing
`install_wasm_hang_aware_fake_mix/1`-style fixture pattern (an args-dispatching fake
`mix`/`mix.bat` script written under `fake_bin_dir`, matching on substrings in the
invocation's argv, per the existing fixture's `case "$*" in ... esac` /
`findstr` dispatch shape).

Two new fixture variants are needed (both new named fixtures alongside the existing
`install_wasm_hang_aware_fake_mix/1`, not edits to it, since that fixture's own
"always discovers 1 fake test on first --dry-run call" behavior must remain
available and unchanged for the existing passing-path test at line ~386):

1. **`install_wasm_hang_retry_succeeds_fake_mix/1`** — an args-aware fake whose
   `--dry-run` branch dispatches on invocation *count*, not just argv shape: first
   `--dry-run` call in the fake's lifetime returns an empty/no test-list block (e.g.
   only "All tests have been excluded." / "Finished in ..." lines, no "Tests that
   would be executed:" header at all, or the header immediately followed by the
   terminator with nothing between), while the second `--dry-run` call returns the
   same successful block `install_wasm_hang_aware_fake_mix/1` already returns
   (header + one `test/fake_wasm_hang_test.exs:1` line + terminator). Distinguishing
   "first" from "second" call needs a piece of state outside the fake script's own
   process (since each invocation is a fresh subprocess) — e.g. the fake script
   creates a marker file under the shared `fake_bin_dir`/`fixture_root` on its first
   `--dry-run` invocation and checks for that marker's presence to decide which
   branch to take on a later call. Non-`--dry-run` argv (the per-test
   `fake_wasm_hang_test` call and the `lua_wallclock_race` call) behaves exactly as
   `install_wasm_hang_aware_fake_mix/1`'s fake already does.

2. **`install_wasm_hang_retry_still_fails_fake_mix/1`** — an args-aware fake whose
   `--dry-run` branch unconditionally (every invocation, first and second alike)
   returns an empty/no test-list block, but with **distinguishable raw output**
   between the two calls (e.g. embed a literal counter or distinct marker string
   such as "attempt=1"/"attempt=2" in each response's otherwise-empty output, using
   the same marker-file-based call-counting mechanism as fixture 1), so an assertion
   can confirm the message embeds the *second* (retry) attempt's output specifically,
   not the first's.

Test cases to add (as new tests in the existing
`describe "mix letflow.check.test's two new hard-failure paths..."` block, or a new
adjacent `describe` block scoped to this design, whichever the existing file's
grouping convention favors when TEST-DESIGNER reads it — this design does not mandate
which):

- **(a) Improved message includes real captured output on legitimate hard-failure.**
  Using fixture 2 (`install_wasm_hang_retry_still_fails_fake_mix/1`): run
  `Mix.Tasks.Letflow.Check.Test.run/1`, assert it raises `Mix.Error`, and assert the
  raised message contains the retry attempt's distinguishing marker text (e.g.
  "attempt=2") — proving the message embeds real captured subprocess output, not
  just static prose. Also assert the message does NOT contain the first attempt's
  distinguishing marker ("attempt=1"), per §3.2's decision to embed only the retry
  attempt's output. Also assert the message still contains the pre-existing framing
  substring (e.g. "cannot tell whether") to confirm the existing prose was preserved,
  not replaced.
- **(a2) Truncation behavior.** Using a variant of fixture 2 whose fake `--dry-run`
  response has more than 40 lines of otherwise-irrelevant output (e.g. padded with
  numbered filler lines) with a distinguishing marker only in the last few lines,
  assert the raised message contains that marker (proving the tail, not the head, is
  what's embedded) and contains an explicit truncation-indicator string, while a
  fixture whose response has fewer than 40 lines produces a message with no
  truncation-indicator string.
- **(b) Retry actually retries once and succeeds.** Using fixture 1
  (`install_wasm_hang_retry_succeeds_fake_mix/1`): run
  `Mix.Tasks.Letflow.Check.Test.run/1` end to end, assert it returns `:ok` (no
  raise) exactly as the existing passing-path test at line ~386 does, and assert the
  captured stdout (`ExUnit.CaptureIO`) contains an informational line marking that
  the first attempt was empty and a retry occurred (per §3.1 step 4's info line) —
  proving the retry path was actually exercised, not that discovery merely happened
  to succeed on a first call.
- **(b2) Retry retries exactly once, then still hard-fails.** Using fixture 2
  (`install_wasm_hang_retry_still_fails_fake_mix/1`, already covering the "both
  attempts empty" case for (a)): additionally assert, via the fake's own marker-file
  mechanism or an invocation-count side channel the fixture exposes to the test
  (e.g. the fake script appends one line to a counter file per `--dry-run` call,
  which the test reads after the run), that `--dry-run` was invoked **exactly
  twice** — proving the retry is bounded to one retry (not zero, not looping
  indefinitely) even though the outcome is a hard failure either way.
- **(c) No-retry-needed path is unaffected.** The existing passing-path test using
  `install_wasm_hang_aware_fake_mix/1` (line ~386, "passes (no raise) when the
  wrapper exits 0...") must continue to pass unmodified — this design does not
  change that fixture or that test, and TEST-DESIGNER/ELIXIR-DEV should confirm it
  still passes as a regression check for the "successful first attempt takes zero
  retries" path (§3.1 step 2).

## 6. Open questions

- Exact wording of the retry-occurred informational line and the "both attempts
  empty, here is the retry's tail output" `Mix.raise` message is left to
  ELIXIR-DEV's implementation discretion, as long as it satisfies §3.2's content
  requirements (framing prose preserved, explicit statement that both attempts were
  empty, retry attempt's last-40-lines embedded verbatim with truncation marker when
  applicable). This design intentionally does not fix a literal string, consistent
  with existing messages in this module already carrying task-specific detail
  (partition names, file:line pairs) assembled at raise time rather than being fully
  static.
- Where exactly the "first attempt was empty, retrying" and "retry succeeded after
  first was empty" informational lines are emitted from (i.e., whether via
  `Mix.shell().info/1` consistent with `run_wasm_hang_tests/0`'s own success-path
  logging, or another mechanism) is left to ELIXIR-DEV, but must be visible in
  captured stdout so test (b) above can assert on it.
- Whether N=40 should instead be a module attribute (e.g.
  `@wasm_hang_discovery_failure_tail_lines 40`) alongside the existing
  `@wasm_hang_test_list_regex` module attribute, rather than a literal argument at
  the one call site, is left to ELIXIR-DEV's discretion; either satisfies this
  design as long as the value used is 40 and is easy to find/change later.
