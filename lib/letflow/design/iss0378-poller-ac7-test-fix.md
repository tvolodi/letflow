# ISS-0378 — remove `poller_test.exs`'s undocumented, mislabeled "application.ex zero-diff" test

**Run:** WF03-ISS0378-20260830
**Owned module (only one):** `test/letflow/scheduler/poller_test.exs`
**Out of scope:** `test/letflow/scheduler_req188_test.exs:432-452` — identical pattern,
different file/requirement. ORCH must file this as its own issue per "No Issue Left
Local-Only"; it is not touched by this design or its implementation.

## 0. Inputs read in full

- `test/letflow/scheduler/poller_test.exs` (all 368 lines, module doc + lines 300-368
  read closely)
- `handoffs/WF03-ISS0378-20260830/issue-fixer-diagnosis.md`
- `test/specs/REQ-186.md` (AC7, AC8, AC9 write-ups)
- `docs/requirements.yaml` REQ-186 entry (10 ACs — none map to an "application.ex
  untouched" property)
- `lib/letflow/application.ex` lines 85-140 (`scheduler_children/0` and its comment)
- `docs/anti-patterns.md`'s two relevant entries: "A test embeds `git diff main...HEAD`
  directly..." and "A test scoped to one specific historical commit SHA breaks..."
- `grep -rn resolve_base_ref! test/` — confirms exactly one definition (line 329) and
  one call site (line 341), both inside the test being removed

## 1. Decision: DELETE, do not narrow

**Agreed with ISSUE-FIXER's recommendation: delete outright.** No narrower git-diff
variant is proposed, and none should be written. Rationale:

- The test maps to **no acceptance criterion**. `docs/requirements.yaml`'s REQ-186 entry
  has 10 ACs; `test/specs/REQ-186.md`'s coverage checklist enumerates AC1–AC9 (the real
  AC7 is the max-fire-retries → `failed` → one `dlq_entries` row property, covered in
  `test/letflow/scheduler_test.exs`; the real AC9 is "no route/controller file added",
  also covered there, correctly, via a structural `File.exists?`/`Path.wildcard` check
  per that spec's own explicit anti-pattern-avoidance note). There is no documented
  coverage to preserve by narrowing instead of deleting.
- The property it informally gestured at — "REQ-186 didn't need a second ticker /
  didn't need to touch the supervision tree" — is already fully covered by the sibling
  test in the same `describe` block (the GenServer-count check, kept as-is per §3
  below).
- Narrowing the `git diff` scope (e.g. to a sub-region of the file, or to a specific
  line range) would still leave a test whose pass/fail depends on git history relative
  to a moving ref (`origin/main`/`main` resolved at run time) rather than on the shipped
  artifact's current state — the exact shape `docs/anti-patterns.md`'s squash-merge
  entry already says to avoid. Narrowing does not fix the defect class; only deleting
  (or replacing with a true structural check) does.

## 2. Replacement structural assertion: NONE proposed

No replacement test is added. Reasoning:

- The only structurally provable, real, existing, introspectable target for "the
  Poller is wired into the supervision tree" is `Letflow.Application.scheduler_children/0`
  (`lib/letflow/application.ex:138`) — but it is a **private** (`defp`) function. Calling
  it from a test would require either (a) making it public, which is an `application.ex`
  production-code change outside this issue's scope (owned module is
  `test/letflow/scheduler/poller_test.exs` only, per the handoff's `owned_modules`), or
  (b) reaching into it via `:erlang.apply/3` or similar private-function-poking, which
  this codebase does not do elsewhere and is not warranted for a test-only bugfix.
- The property is not orphaned by skipping a replacement: the surviving sibling test
  (§3) already proves, structurally and permanently, "exactly one GenServer module
  exists under `lib/letflow/scheduler/` and it is `Poller`" — that is the actual
  substance of "no second ticker was added," which is the only part of the deleted
  test's stated intent that maps to anything REQ-186 actually required. Whether
  `Letflow.Application` itself correctly starts that one GenServer is exercised
  indirectly by every other test in this file (they call `Poller.handle_info/2`
  directly, per the module doc's own stated rationale for why the supervised child is
  never started under `mix test`) and is not a documented AC on its own.
- If a future requirement wants "the supervision tree includes the Poller" as an
  explicit, standalone acceptance criterion, that requires (i) a REQ/AC entry stating it,
  and (ii) `scheduler_children/0` (or an equivalent) becoming a public, introspectable
  function — both out of scope for this test-only fix. Not designing that here; noting
  it as an open question for whoever owns that future requirement, not silently
  resolving it.

**Confirms:** no replacement test is added, so there is nothing that depends on git or
history in any form — the requirement "does not use git/history" is satisfied trivially
by proposing no replacement.

## 3. Exact edit to `test/letflow/scheduler/poller_test.exs`

All line numbers below are current as of the file read in §0 (368 lines total).

### 3a. Delete the `resolve_base_ref!/0` helper

Delete lines 329-337 in full — the private `resolve_base_ref!/0` function definition
(opening `defp resolve_base_ref! do` at line 329, closing `end` at line 337). Its body
resolves a base ref by trying `"origin/main"` then `"main"` via `System.cmd("git",
["rev-parse", "--verify", ref], ...)`, asserting one of them verifies, and returning it.

**Confirmed safe to delete:** `grep -n resolve_base_ref! test/letflow/scheduler/poller_test.exs`
returns exactly two lines — the `defp` at 329 and the sole call site at 341, which is
inside the test being deleted in 3b. No other test in this file, and no other file under
`test/`, references `resolve_base_ref!` (project-wide grep confirms zero other matches).
Deleting it introduces no dangling reference.

### 3b. Delete the zero-diff test

Delete the test block at lines 340-353 (the `test "lib/letflow/application.ex has zero
diff against the base branch" do ... end`), i.e. everything between the `describe` line
and the sibling test that follows it.

### 3c. Correct the `describe` block title

The `describe` block opening at line 339 currently carries the title text (verbatim,
for identification purposes only — not to be reproduced as code): `AC7: retention runs
on Poller's own process -- no second ticker, application.ex untouched`.

This claims AC7 — the real AC7 (max-fire-retries → `failed` → one `dlq_entries` row) is
unrelated and already covered in `test/letflow/scheduler_test.exs`; this `describe`
block's content is not listed under any AC in `test/specs/REQ-186.md`'s coverage
checklist. Replace the title string with wording that describes what the surviving test
actually checks and claims no AC number. Recommended replacement title text: `no second
ticker -- lib/letflow/scheduler/ has exactly one GenServer module`.

Any equivalent phrasing that (a) does not say "AC7" or any other AC number, and (b)
accurately describes the sole surviving test's content, satisfies this requirement —
the recommended text above is not a rigid requirement to match character-for-character.

### 3d. Resulting shape of the block (for implementer orientation, not literal diff)

After 3a-3c, the file's tail becomes: the existing `describe` block containing only the
one surviving test —

- `test "lib/letflow/scheduler/ contains exactly one GenServer module (Poller) -- no
  second ticker"` — **unchanged**, body untouched (lines 355-366 in the pre-edit file,
  unaffected by 3a/3b since it is textually after both deleted spans and has no
  dependency on `resolve_base_ref!` or on the deleted test's execution).

No other part of the file changes. File shrinks from 368 lines to approximately 341
lines (368 − 9 helper lines − 14 deleted-test lines − 1 blank separator line, plus the
one-line title edit being a same-line replacement, not a net line change — implementer
should let `mix format` settle exact blank-line counts around the edit rather than
matching this arithmetic precisely).

## 4. Test isolation — confirmed no other dependency

Read the full file (`test/letflow/scheduler/poller_test.exs`, all 368 lines) to check
for any dependency on the deleted test or helper:

- **`resolve_base_ref!/0`**: exactly one call site (line 341, inside the deleted test).
  No other test, `setup`, or helper in this file calls it.
- **Deleted test's side effects**: the deleted test only shells out to `git diff
  --stat` and asserts on the captured string — it does not write to the database, does
  not modify module/application state, does not set any process dictionary or
  application-env value, and defines no data any other test reads. `use
  Letflow.DataCase, async: false` wraps each test in its own sandbox transaction
  (per the module doc, shared-mode `Ecto.Adapters.SQL.Sandbox`), so no cross-test state
  leak channel exists here regardless.
- **Ordering**: ExUnit does not guarantee describe-block or test order within a file by
  default in this project's config (no `seed: 0`/manual ordering markers observed in
  this file), and no other test in the file references anything defined by or produced
  by the deleted `describe` block's tests.

Conclusion: the deleted test and helper can be removed with no impact on any other test
in this file.

## 5. `docs/anti-patterns.md` update

**No new entry.** This is not a new defect class — it is the same shape already
documented under "A test scoped to one specific historical commit SHA breaks the moment
that commit is squash-merged away" (the `dlq_test.exs` AC6 incident), just instantiated
via a moving symbolic ref (`origin/main`/`main` resolved at run time) rather than a
pinned SHA. The existing entry's own mitigation text already prescribes exactly the fix
applied here ("prove it structurally instead... the same way this project already
proves 'no route was added' for other requirements").

**Recommended action for whichever agent implements this fix:** append a short
"recurrence" paragraph to that existing entry (following the pattern already used
elsewhere in this file for `## ... Recurrence.` notes, e.g. under the `mix format`
entry), noting:

- 3rd-ish instance of this class, ISS-0378, `poller_test.exs`'s "application.ex zero
  diff" test, tripped by REQ-190's legitimate, independently-reviewed
  `:logger`-primary-filter addition to `application.ex`.
- Distinguish from the SHA-pinned original: this instance used the *defensively
  resolved* `origin/main`/`main` ref (the exact mitigation from the *other* related
  entry, "A test embeds `git diff main...HEAD` directly...") — proving that defensive
  ref-resolution alone does not fix the underlying "proves a permanent property via
  git diff/history" defect; it only fixes the narrower "hardcoded ref name" defect.
  Both mitigations are needed for different failure modes, and neither substitutes for
  "use a structural check instead" when the property itself is meant to be permanent.
- Note the identical, still-open recurrence at
  `test/letflow/scheduler_req188_test.exs:432-452` (out of scope for this fix, flagged
  by ISSUE-FIXER for ORCH to file separately) as a live instance of the same class not
  yet fixed as of this writing.

This is a documentation edit only (a markdown paragraph append), not code — whichever
agent (ELIXIR-DEV/TEST-DESIGNER, whoever WF-03 routes the actual edit to) implements
§3 should also make this append in the same change, since it is small and directly
traceable to this fix.

## 6. Scope confirmation

This design touches **only** `test/letflow/scheduler/poller_test.exs` (plus the
`docs/anti-patterns.md` recurrence-note append in §5). It does **not** touch:

- `test/letflow/scheduler_req188_test.exs` — identical pattern for
  `lib/letflow/engine/transition.ex`, explicitly out of scope per the handoff's task
  description. ORCH should file this as a separate issue.
- `lib/letflow/application.ex` — no production code changes; `scheduler_children/0`
  stays private (§2).
- Any other test file, requirement, or spec.

## 7. Open questions

None load-bearing for this fix. One forward-looking note (not an open question blocking
this fix, just not silently resolved): if a future requirement wants "the Poller is
present in the live supervision tree" proven as its own acceptance criterion, that will
require exporting `scheduler_children/0` (or an equivalent) — not something to decide
here.
