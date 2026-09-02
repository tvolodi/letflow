# ISS-0413 — `plugin_handler_test.exs`'s AC6 live-ref `git diff` test

**Run:** WF03-ISS0413-20260902
**Owned module (only one):** `test/letflow/engine/wasm/plugin_handler_test.exs`
**Sibling fix (already applied, out of scope here):** `test/letflow/engine/wasm/host_api_write_test.exs`
— deleted directly by ISSUE-FIXER because a structural sibling test already existed.
**Precedents:** `lib/letflow/design/iss0378-poller-ac7-test-fix.md` (ISS-0378),
`lib/letflow/design/iss0404-req188-transition-test-fix.md` / `iss0404-regression-verification.md`
(ISS-0404) — identical defect class, both resolved by deletion with no replacement.

## 0. Inputs read in full

- `handoffs/WF03-ISS0413-20260902/step-01-issue-fixer-diagnosis.json` (this run's task brief)
- `docs/anti-patterns.md`: "A test embeds `git diff main...HEAD` directly, assuming a local
  `main` branch always exists" and "A test scoped to one specific historical commit SHA breaks
  the moment that commit is squash-merged away" (including its ISS-0378/ISS-0404 recurrence notes)
- `lib/letflow/design/iss0378-poller-ac7-test-fix.md` (full)
- `lib/letflow/design/iss0404-regression-verification.md` (full)
- `test/letflow/engine/wasm/plugin_handler_test.exs`, lines 1-100 (moduledoc, the AC6 block at
  lines 38-65, and enough of the surrounding file to confirm the AC6 `describe` block's only
  member is the git-diff test)
- `test/specs/REQ-165.md`, the full mutation-testing section (lines 130-175) — **read directly,
  not taken on ISSUE-FIXER's characterization of it** (see §1 below; this is the load-bearing
  correction that drives this design's decision)
- `lib/letflow/design/req165-wasmex-process-boundary.md` — confirmed it does **not** itself
  contain the mutation-testing table; that table lives in `test/specs/REQ-165.md` (the
  handoff's citation of the design doc for this table was imprecise, but the finding underneath
  is real and traced to its actual source below)

## 1. Correcting the load-bearing evidence before deciding

ISSUE-FIXER's handoff frames the decision as turning on this claim: mutation #3 (an edit to
`plugin_interface.ex`'s `handle_yield_result/4` timeout message) was "load-bearing" for the AC6
git-diff test because "a colliding assertion (T3/AC5's error-message check) did NOT catch it on
its own."

Re-reading `test/specs/REQ-165.md` lines 151-171 directly (the actual mutation-testing table,
not a paraphrase of it) shows the opposite:

- Row 3 of the mutation table: mutation #3 (`handle_yield_result/4`'s timeout message changed
  from `"did not respond within #{timeout_ms}ms"` to `"timed out after #{timeout_ms}
  milliseconds"`) — **"Caught by existing suite? Yes — AC5's test asserts `reason =~ "did not
  respond within 100ms"` and failed immediately with a clear diff."** Action taken: **"No test
  change needed."** T3 (the AC5 hang/timeout test, already in the suite) caught mutation #3 on
  its own, independent of T6 (the AC6 git-diff test).
- Row 6 of the AC-coverage table (line 171) — the row ISSUE-FIXER's handoff summarized as "T6
  caught mutation #3" — actually says: "mutation #3 temporarily touched this exact file; T6
  *would have* failed had the mutation not been reverted before commit." That is not a second,
  independent catch of a gap T3 left open. It is the trivially-true observation that *any*
  content-diff of a file that was just edited shows a diff — it holds for T6 exactly as it would
  hold for a plain `File.read!/1` byte-comparison, a checksum, or nothing at all, since T3 already
  caught the mutation before it could ever reach a commit. T6 supplied no discriminating power
  that T3 did not already supply.

**This changes the decision materially.** The premise that deleting T6 "would lose real
discriminating power with no drop-in structural replacement" does not hold up against the
mutation-testing table's own text. The only mutation this file's suite ever ran against
`plugin_interface.ex` was already caught by an existing, permanent, content-level assertion
(T3/AC5's `reason =~ "did not respond within 100ms"`) that has nothing to do with git and will
never break for a legitimate future PR the way a live-ref `git diff` will.

## 2. Decision: DELETE, do not narrow, do not keep as documented risk

**Chosen: option (a).** Delete the `describe "AC6: plugin_interface.ex is unmodified"` block
(`test/letflow/engine/wasm/plugin_handler_test.exs` lines 38-65) outright, with no replacement
test. This is the same resolution as ISS-0378 and ISS-0404, for the same reasons, now confirmed
rather than assumed for this instance specifically:

1. **The defect class is confirmed present.** This is the "git diff `main...HEAD`" live-ref
   fragility (`docs/anti-patterns.md`) — the exact same shape the ISS-0413 diagnosis, ISS-0404's
   verification report, and ISS-0378's design doc all describe. It runs against `HEAD` on every
   future PR's CI, forever, not just the PR that introduced it. It is not currently failing only
   because `.github/workflows/ci.yml` pins `fetch-depth: 0`, which is an accident of CI
   configuration, not a property of the test itself — the anti-patterns entry's own recurrence
   note ("proving a supposedly permanent property via git diff/history is broken regardless of
   how carefully the ref is resolved") applies verbatim here: this test already carries the
   defensive `origin/main`/`main` fallback (the *other* mitigation) and is still the wrong shape,
   exactly as ISS-0378's `poller_test.exs` instance was.
2. **The property AC6 states is a one-time historical fact about REQ-165's own diff, not an
   evergreen property.** "plugin_interface.ex is unmodified *by REQ-165*" was permanently true or
   false the moment REQ-165 merged. It is not a property any future PR should be required to keep
   satisfying — exactly ISS-0404's `transition.ex`-untouched finding. Enforcing it forever via a
   live `HEAD`-diff is asserting a claim about the present against a fact that was only ever about
   one past commit range.
3. **No coverage is actually lost.** §1 shows the only real defect this test class has ever been
   shown to catch in this codebase (mutation #3, a `handle_yield_result/4` error-message change)
   was independently caught by T3 (the AC5 hang/timeout test's `reason =~ "did not respond within
   100ms"` assertion) *before* T6 was even relevant. T3 is untouched by this deletion, stays in
   the suite, and continues to catch any future accidental change to that same error message.
   There is no discriminating power specific to T6 to preserve.
4. **`plugin_interface.ex` is a live, shared behaviour contract** (every current and future
   plugin handler depends on it) that legitimate future requirements are architecturally likely
   to touch — more likely than `lib/letflow/engine/lua/`, which is deliberately frozen per
   decision 0014(4). A permanently-enforced "never touch this file again" check is a worse fit
   here than it would even be for the already-fixed `lua/` sibling; it is exactly the shape that
   forced ISS-0378's *emergency* deletion once a real, correct PR needed to touch the file the
   test guarded.
5. **Options (b) and (c) do not hold up:**
   - (b), "keep and defer" — was premised on the coverage trade-off being real (a discriminating
     test lost vs. a future breakage risk gained). §1 shows the coverage side of that trade-off
     is not real: there is nothing of value being preserved by keeping it, only downside risk
     being deferred. Deferring a real, known, eventually-certain breakage (some future PR *will*
     need to touch `plugin_interface.ex` — it is the shared contract every plugin handler
     depends on) in exchange for zero net coverage is not a favorable trade.
   - (c), "a genuine structural replacement" — was premised on needing to reproduce mutation #3's
     catch structurally (e.g., fingerprinting `handle_yield_result/4`'s message strings). That
     catch already exists, permanently, in T3 (`test/letflow/engine/wasm/plugin_handler_test.exs`,
     the `describe "AC5: a hanging guest is terminated by the outer task timeout"` block's
     `reason =~ "did not respond within 100ms"` assertion) and needs no duplication. Building a
     second, redundant content-assertion whose only job is to restate what T3 already proves
     would add maintenance surface (two places that must agree on the exact message string) for
     no additional discriminating power — the AC-coverage table's own row 6 caveat ("would have
     failed had the mutation not been reverted") is not evidence of a distinct property worth a
     dedicated structural test; it is evidence T6 was redundant with T3 all along.

## 3. Exact edit to `test/letflow/engine/wasm/plugin_handler_test.exs`

Delete the `describe "AC6: plugin_interface.ex is unmodified" do ... end` block in full — lines
38-65 as read in this run (opening `describe` line through its matching `end`, plus the blank
separator line before the next `# ---...` comment block, consistent with `mix format`'s own
blank-line conventions rather than an exact line-count match). This block's sole content is the
one `test "git diff --stat against plugin_interface.ex is empty" do ... end`; no other test in
this file, and no other file under `test/`, references anything the deleted block defines — it
introduces no local helper function, no module attribute, and no shared state (confirmed by
inspection: the block reads only `System.cmd/2`/`3` results into local variables scoped to its
own `test` body).

No change to `test/letflow/engine/wasm/plugin_handler_test.exs`'s moduledoc is required — it does
not mention AC6 or the deleted test by name (re-read in full at lines 1-13).

## 4. `docs/requirements.yaml` / coverage impact

REQ-165's AC6 ("plugin_interface.ex is unmodified by this requirement") was a claim about
REQ-165's own now-historical PR diff. That PR has been merged for multiple stages; the claim was
permanently discharged at merge time and is not re-checkable (or re-checkable-worthy) against
`HEAD` going forward. No `docs/requirements.yaml` entry needs updating — REQ-165 is already
`done`, and this change touches only a since-redundant enforcement mechanism for a fact that is
no longer in question, not the requirement's own acceptance-criteria text or status.

## 5. `docs/anti-patterns.md` update

**No new entry.** This is the same class already documented under "A test scoped to one specific
historical commit SHA breaks the moment that commit is squash-merged away" and its ISS-0378/
ISS-0404 recurrence notes — a third (now fourth, counting `host_api_write_test.exs`'s sibling,
already fixed by ISSUE-FIXER) instance of the identical shape, not a new mechanism. Recommend
whichever agent implements §3 append one more short recurrence sentence to that entry's existing
"Recurrence." paragraph, noting: ISS-0413 found and fixed the same pattern a fourth time, in
`plugin_handler_test.exs`'s AC6 test (`lib/letflow/engine/plugin_interface.ex` untouched), and
that reviewing the mutation-testing evidence ISSUE-FIXER cited as a reason to keep it (REQ-165's
own `test/specs/REQ-165.md` mutation table) showed on direct re-reading that the test's one
demonstrated catch (mutation #3) was already independently caught by a content-level assertion
(AC5's timeout-message check) — worth noting as its own small lesson: a citation of "this test
caught mutation N" should be checked against the actual table row's wording before it is used to
justify keeping a fragile test, since "would also have failed" is not the same claim as "was the
catch."

## 6. Scope confirmation

This design touches only `test/letflow/engine/wasm/plugin_handler_test.exs` (deletion, §3) and
optionally the `docs/anti-patterns.md` recurrence-note append (§5, non-blocking). It does not
touch:
- `test/letflow/engine/wasm/host_api_write_test.exs` — already fixed directly by ISSUE-FIXER in
  this same run, outside this design's scope.
- `lib/letflow/engine/plugin_interface.ex` or any other production code — no production changes.
- Any other test file, requirement, or spec.

## 7. Open questions

None load-bearing for this fix.
