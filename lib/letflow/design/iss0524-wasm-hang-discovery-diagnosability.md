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

**Empirical grounding (superseding the prior revision's flat-tail approach).** Live
runs of `mix test --only wasm_hang --dry-run` against this repository, taken while
redesigning this section, measured the header-to-terminator span directly: the
`Tests that would be executed:` header and the `All tests have been excluded.`
terminator, with total captured output 283–287 lines across repeated runs. The
region between them is 232 lines every time observed, not "a handful of lines" —
and inspecting that region's content confirms it is dominated by ExUnit's
compiler-deprecation-warning noise for *unrelated* test files interleaved directly
between the header and the real entries, the exact class of noise
`extract_test_list_block/1`'s own DEVIATION comment already documents (§1 cites the
same comment to justify the retry). A flat last-40-lines tail — the prior revision
of this section — reliably captures the terminator and the (possibly empty) entries
but **cuts off the header itself**, which sits far above line 40 from the end. That
silently destroys exactly the distinction this design exists to restore: a reader
of the raised message cannot tell "the header never appeared at all" (dry-run itself
broken — more severe) from "the header appeared but the block between it and the
terminator was empty" (the case this design actually targets) when the header is
truncated out of view with no indication that anything was cut before it.

This revision replaces the flat tail with an explicit **search for the header
string**, so the message's claims about what it captured are always true rather
than assumed:

- Keep the existing framing prose unchanged in substance ("exited 0 but its 'Tests
  that would be executed:' block was empty or absent... cannot tell whether that
  means zero tests now exist or discovery itself is broken... hard failure rather
  than silently passing"), so existing understanding of *why* this fails is not
  lost.
- State explicitly that a retry was attempted and also came back empty (so a reader
  knows this is not a false report of only one attempt) — e.g. naming both "first
  attempt" and "retry attempt" explicitly in the message text.
- Search the **retry attempt's** raw output for the literal header line
  `"Tests that would be executed:"` (the same literal-line match
  `extract_test_list_block/1` already performs via its `drop_while`, so this search
  is consistent with, not a reinterpretation of, the module's existing header
  recognition). Two cases:

  1. **Header not found anywhere in the retry attempt's raw output.** State this
     explicitly and distinctly from the "block empty" framing above — e.g. "the
     retry attempt's raw output contains no 'Tests that would be executed:' header
     at all; this is a more severe signal than an empty block, since the dry-run
     subprocess's own discovery output format itself may be broken (crashed
     early, produced no output, or its output shape has changed), not merely
     resolving to zero tests." Then append a fallback excerpt: the retry attempt's
     **last 40 lines** (same tail-taking helper as before, see §3.3), so a reader
     still has *some* concrete evidence to look at even though there is no
     header to anchor a more targeted excerpt to. Prefix this fallback excerpt
     with a marker line making clear it is a generic tail, not a header-anchored
     window (since in this branch there is, by definition, no header to anchor
     to).
  2. **Header found.** Append the captured window starting at the header line and
     continuing for up to `@wasm_hang_discovery_window_lines` (300) lines, stopping
     early if the terminator line (`"All tests have been excluded."` or a line
     starting with `"Finished in"` — the same two terminator forms
     `extract_test_list_block/1` already recognizes) is reached first. Precede the
     window with a marker line stating "header found; showing captured window from
     the header" and, distinctly:
     - if the terminator was reached before the 300-line bound: no further
       qualification needed — the window is the complete header-to-terminator
       block, verbatim, including whatever real entries or warning noise fall
       inside it (today, empirically, 232 lines; the bound is chosen with margin
       above the observed value, see §3.3 for the rationale on the specific
       number and its limits);
     - if the 300-line bound was reached WITHOUT finding the terminator: state
       that explicitly too — e.g. "captured window ended after 300 lines without
       reaching a terminator line; this excerpt may not include the full block" —
       so a reader is never left assuming completeness the message cannot back up.
  - If the retry attempt's raw output is empty (zero bytes/lines captured at
    all — a distinct, more severe failure than either case above, e.g. the
    subprocess produced no output whatsoever), state that explicitly instead of
    running the header search or printing an empty section, so a reader isn't left
    staring at a blank section wondering if the message is truncated incorrectly.
- Do not include the first attempt's raw output in the message body (keeping the
  message bounded to one attempt's excerpt plus the informational retry-occurred
  framing); the informational `Mix.shell().info/1` line from step 3 above already
  surfaced live during the run (and is visible in CI's own captured stdout for the
  task) that a first attempt occurred and was empty, so this is not fully lost, only
  not duplicated inside the `Mix.raise` message itself.

### 3.3 New private helpers: header-anchored window, and last-N-lines fallback

Two small helpers are needed, replacing the single flat-tail helper from the prior
revision of this design:

- `@spec find_discovery_window(String.t(), pos_integer()) :: {:header_found, window :: String.t(), terminator_reached? :: boolean()} | :header_not_found`
  - Input: the raw captured output string (same convention as
    `extract_test_list_block/1` — newline-delimited), and the window bound
    `@wasm_hang_discovery_window_lines` (called with `300` at the one call site in
    §3.2; taken as a parameter, not hardcoded inside the helper, so the call site's
    choice of bound stays visible and independently testable, same convention as
    the prior revision's `N` parameter for its tail helper).
  - Behavior: locate the first line exactly equal to `"Tests that would be
    executed:"` (mirroring `extract_test_list_block/1`'s own header match, so this
    helper's notion of "the header" never diverges from the parsing logic's). If no
    such line exists anywhere in the output, return `:header_not_found`. If found,
    collect the header line plus up to the bound's worth of following lines,
    stopping early (without consuming the bound) at the first line that is either
    exactly `"All tests have been excluded."` or starts with `"Finished in"` (the
    same two terminator forms `extract_test_list_block/1` recognizes) — include
    that terminator line itself in the returned window. Join the collected lines
    with newlines into `window`. `terminator_reached?` is `true` when a terminator
    line was found before the bound was exhausted, `false` when the bound was
    reached first (i.e. the window was cut off without ever seeing where the block
    ends) — this flag is what lets §3.2 state explicitly, rather than silently
    imply, whether the excerpt is structurally complete.
  - This helper does not interpret or parse individual entry lines — it is
    line-oriented boundary-finding only (find header, find terminator or bound,
    slice between), the same "already-split-by-newline structure" convention
    `extract_test_list_block/1` uses, just without that function's additional
    per-line regex filtering (this helper's job is to show the raw window for a
    human to read, not to extract structured entries for the program to consume).
- `@spec last_output_lines(String.t(), pos_integer()) :: String.t()`
  - Retained from the prior revision, used only for the `:header_not_found`
    fallback excerpt in §3.2 (called with `40`, since without a header to anchor
    to there is no principled "from X for Y lines" window — a generic tail is the
    only available fallback context in that branch).
  - Input: the raw captured output string, and the line count `N`.
  - Output: a single string, newline-joined, containing at most the last `N` lines
    of the input, prefixed with an explicit truncation marker line when truncation
    occurred (i.e. when the input had more than `N` lines), and with no such marker
    when it did not. Unchanged in behavior from the prior revision.

## 4. Failure-shape / error-shape summary

| Path | Outcome | Message contains |
|---|---|---|
| First discovery attempt's block non-empty | `discover_wasm_hang_tests/0` returns immediately (no retry, no message) | n/a |
| First empty, retry's block non-empty | Returns after retry; informational lines only (no raise) | n/a (info via `Mix.shell().info/1`, not `Mix.raise`) |
| First empty, retry also empty | `Mix.raise` (task terminates) | Existing framing prose + explicit "first and retry both empty" statement, then one of: (a) header-anchored window (header through terminator or through the 300-line bound, with an explicit "bound reached, terminator not confirmed" note if the bound was hit first) when the retry's raw output contains the header, (b) an explicit "no header found at all — dry-run itself may be broken" statement plus a last-40-lines fallback tail when the header is entirely absent, or (c) an explicit "retry produced no output at all" statement when the retry's raw output was itself empty |

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
   returns output that **includes the `"Tests that would be executed:"` header
   followed immediately by a terminator line with no real entries in between**
   (an empty block, not an absent header — this fixture models "header present,
   block empty," the case this design's header-anchored window targets), but with
   **distinguishable raw output** between the two calls (e.g. embed a literal
   counter or distinct marker string such as "attempt=1"/"attempt=2" between the
   header and the terminator in each response, using the same marker-file-based
   call-counting mechanism as fixture 1), so an assertion can confirm the message
   embeds the *second* (retry) attempt's output specifically, not the first's, and
   that the embedded content is real captured output rather than static prose.

3. **`install_wasm_hang_retry_noisy_window_fake_mix/1`** — an args-aware fake whose
   `--dry-run` branch, on every invocation, returns the header followed by a large
   block of numbered filler lines simulating unrelated compiler-warning noise (the
   real shape measured live against this repository, see §3.2), then a terminator.
   Needs two response variants, both reusable for a single fixture parameterized by
   filler-line count (or two small fixture functions, ELIXIR-DEV's choice): (i) filler
   comfortably under the 300-line bound (e.g. 250 lines, in the range actually
   observed live), so the terminator is reached within the bound, and (ii) filler
   comfortably over the bound (e.g. 400 lines) with NO terminator string anywhere in
   the filler, so the bound is exhausted first. No retry-count state is needed here
   (both `--dry-run` calls, first and retry, can return the same oversized response) —
   this fixture exists purely to exercise §3.3's window-vs-bound behavior, not the
   retry-count logic already covered by fixtures 1 and 2.

4. **`install_wasm_hang_no_header_fake_mix/1`** — an args-aware fake whose
   `--dry-run` branch, on every invocation, returns non-empty output that contains
   no `"Tests that would be executed:"` line at all (e.g. output resembling a crashed
   or reshaped dry-run subprocess — arbitrary distinguishable text, deliberately not
   matching the header string), modeling "dry-run itself may be broken" rather than
   "block empty." No retry-count state needed (both calls can return the same
   header-absent response), since this fixture exists to exercise §3.2's
   `:header_not_found` branch specifically, independent of the retry-count logic.

Test cases to add (as new tests in the existing
`describe "mix letflow.check.test's two new hard-failure paths..."` block, or a new
adjacent `describe` block scoped to this design, whichever the existing file's
grouping convention favors when TEST-DESIGNER reads it — this design does not mandate
which):

- **(a) Improved message includes real captured output on legitimate hard-failure,
  header present.** Using fixture 2 (`install_wasm_hang_retry_still_fails_fake_mix/1`,
  whose response includes the `"Tests that would be executed:"` header followed by
  an empty/no-entries block and a terminator, per its definition above): run
  `Mix.Tasks.Letflow.Check.Test.run/1`, assert it raises `Mix.Error`, and assert the
  raised message contains the retry attempt's distinguishing marker text (e.g.
  "attempt=2") placed inside the fake's header-to-terminator region — proving the
  message embeds real captured subprocess output via the header-anchored window,
  not just static prose. Also assert the message does NOT contain the first
  attempt's distinguishing marker ("attempt=1"), per §3.2's decision to embed only
  the retry attempt's output. Also assert the message still contains the
  pre-existing framing substring (e.g. "cannot tell whether") to confirm the
  existing prose was preserved, not replaced. Also assert the message contains the
  literal header string `"Tests that would be executed:"` itself, not just content
  from inside the window — this is the specific defect this revision fixes (the
  prior flat-tail design could embed post-header content while cutting the header
  out).
- **(a2) Header-anchored window covers real noisy output, including the header.**
  Using fixture 3's under-bound variant
  (`install_wasm_hang_retry_noisy_window_fake_mix/1`, ~250 filler lines then a
  terminator, modeled on the real observed shape — header line, then over 200 lines
  of filler simulating compiler-warning noise with no real test entries mixed in,
  then a terminator line, all within the 300-line bound), assert the raised message
  contains both the literal header string and the literal terminator string, and
  contains no "bound reached without a terminator" caveat — proving the window is
  anchored to the header (not a fixed tail) and reaches the terminator when it
  exists within the bound, mirroring the real 232-line header-to-terminator span
  measured live against this repository while designing this section (see §3.2).
- **(a3) Bound reached before terminator is stated explicitly, not silently
  truncated.** Using fixture 3's over-bound variant (~400 filler lines, no
  terminator anywhere in that span), assert the raised message contains the literal
  header string, contains the explicit "bound reached... terminator not
  confirmed"-style caveat text from §3.2, and does NOT falsely claim completeness.
- **(a4) Header entirely absent is reported as a distinct, more severe signal.**
  Using fixture 4 (`install_wasm_hang_no_header_fake_mix/1`), assert the raised
  message contains an explicit "no header found... dry-run itself may be broken"
  style statement (distinct wording from the "block empty" framing used when the
  header IS present), and contains the last-40-lines fallback tail of that fake
  response (per §3.3's `last_output_lines/2` reuse) rather than silently omitting any
  excerpt.
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
  empty" `Mix.raise` message is left to ELIXIR-DEV's implementation discretion, as
  long as it satisfies §3.2's content requirements (framing prose preserved,
  explicit statement that both attempts were empty, and one of: the header-anchored
  window with its terminator-reached/bound-reached distinction, the
  header-not-found statement plus fallback tail, or the retry-output-empty
  statement). This design intentionally does not fix a literal string, consistent
  with existing messages in this module already carrying task-specific detail
  (partition names, file:line pairs) assembled at raise time rather than being fully
  static.
- Where exactly the "first attempt was empty, retrying" and "retry succeeded after
  first was empty" informational lines are emitted from (i.e., whether via
  `Mix.shell().info/1` consistent with `run_wasm_hang_tests/0`'s own success-path
  logging, or another mechanism) is left to ELIXIR-DEV, but must be visible in
  captured stdout so test (b) above can assert on it.
- Whether `@wasm_hang_discovery_window_lines` (300) and the fallback tail's `N`
  (40) should be module attributes (e.g. alongside the existing
  `@wasm_hang_test_list_regex` module attribute) rather than literal arguments at
  their one call sites each is left to ELIXIR-DEV's discretion; either satisfies
  this design as long as the values used are 300 and 40 respectively and are easy
  to find/change later.
- The 300-line window bound is grounded in live measurement taken while designing
  this section (232-line header-to-terminator span, ~285-line total output, see
  §3.2), with margin added above the observed value, not a value with a
  first-principles derivation. Like the prior revision's N=40 tail, it could in
  principle be invalidated by future growth in the test suite's compile-warning
  volume — the difference from the prior revision is that this design no longer
  depends on the bound always being large enough to silently succeed: when the
  bound is insufficient, §3.2's `terminator_reached? = false` branch makes that
  explicit in the message rather than silently truncating without indication. If a
  future recurrence's message shows the "bound reached, terminator not confirmed"
  caveat routinely, that is itself the signal that 300 should be raised — left as a
  note for whoever revisits this, not resolved further here.
