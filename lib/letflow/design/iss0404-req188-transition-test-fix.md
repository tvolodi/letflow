# ISS-0404 — remove `scheduler_req188_test.exs`'s SHA-pinned "transition.ex untouched by REQ-188" test

**Run:** WF03-ISS0404-20260902
**Owned module (only one):** `test/letflow/scheduler_req188_test.exs`
**Precedent:** `lib/letflow/design/iss0378-poller-ac7-test-fix.md` (ISS-0378) — identical
defect class, same resolution shape. This design mirrors its section structure.
**Out of scope:** `lib/letflow/engine/transition.ex` (production code, untouched by this
fix, confirmed clean below) — no other test file is touched.

## 0. Inputs read in full

- `test/letflow/scheduler_req188_test.exs` — all 497 lines (full file, not excerpted)
- `lib/letflow/engine/transition.ex` — lines 1-140 (moduledoc in full, including the
  "Purity (AC1)" section at lines 28-52, and the `alias` block at lines 77-83)
- `test/specs/REQ-188.md` — all 108 lines (full file)
- `docs/issues/ISS-0404.yaml` — full entry
- `docs/anti-patterns.md`'s "A test scoped to one specific historical commit SHA breaks
  the moment that commit is squash-merged away" entry (lines 1764-1810), including its
  existing Recurrence paragraph (lines 1792-1809)
- `lib/letflow/design/iss0378-poller-ac7-test-fix.md` (the direct precedent, used as the
  structural template for this document)
- ISSUE-FIXER's diagnosis, as relayed in this run's handoff (Step 1 of WF-03), and
  independently checked against the files above rather than trusted as-is (see §1)
- `grep -rn "req_188_base|req_188_merge|746a3ac0|77637268" .` (repo-wide) — confirms the
  only files referencing REQ-188's own commit-range SHAs or the test's local variable
  names are: the test file itself, `test/specs/REQ-188.md`, `docs/issues/ISS-0404.yaml`,
  and historical/append-only records (`handoffs/registry.json`,
  `handoffs/orchestrator.log`, `docs/status/requirement_status.v7.yaml`,
  `test/reports/report-20260830-WF02-REQ190-20260830.yaml`, ISS-0378/ISS-0398 handoffs
  and issue records) — none of which are code paths affected by deleting the test.
- `grep -n "Scheduler" lib/letflow/engine/transition.ex` — confirms exactly one match,
  line 129, inside the moduledoc's prose (not an `alias` or a call)

## 1. Decision: DELETE, do not narrow

**Agreed with ISSUE-FIXER's recommendation: delete outright.** Sanity-checked against
the actual current files (not taken on trust) as follows:

- **`transition.ex` makes no call into Scheduler/Timer/Poller.** The `alias` block
  (lines 77-83) lists only `Graph`, `Graph.Node`, `Expr`, `InstanceState`, `JoinCounter`,
  `Token`, `VariableMerge` — no `Scheduler`, no `Timer`, no `Poller`. The sole match for
  `Scheduler` in the whole file is line 129, inside the `pending_event` typedoc, and its
  own sentence makes the referent explicit: *"`dispatch_timer_arrival/3` leaves the token
  in place and returns this instead of resolving `duration_iso8601`/reading a clock
  itself; **the impure caller** re-resolves `node_id` against its own `Graph.t()` to
  compute `fire_at` and calls `Letflow.Scheduler.create/2`."* That caller is
  `Letflow.Engine.prepare_timer_arms/4` (confirmed at `lib/letflow/engine.ex:701` per
  ISSUE-FIXER's diagnosis) — a different module, documented here only because
  `transition.ex` hands that module the pending-event tuple it acts on. This confirms
  diagnosis point 1 exactly: it is prose describing a caller, not a call.
- **`transition.ex` DOES legitimately, permanently carry `:TIMER`-related content**, and
  this is not something REQ-188 introduced or scope creep to worry about: the "Purity
  (AC1)" section itself (lines 38-43) names `{:timer_armed, ...}`/`dispatch_timer_arrival/3`
  as REQ-187's own addition and explains why it adds no `Repo`/clock call; `pending_event`
  (line 139) and `transition_event` (line 112) both carry `:timer_fired`/`:timer_armed`
  variants permanently. This matches diagnosis point 2 — confirmed directly against the
  moduledoc text, not merely asserted.
- **The narrow property the deleted test checks (transition.ex untouched by REQ-188's
  own commit range) is redundant with a broader, already-existing, evergreen property.**
  `transition.ex`'s own moduledoc "Purity (AC1)" section (lines 28-52) already asserts,
  and gives a `grep`-verifiable command for, "no `Repo`/`Logger`/clock/`File`/network call
  anywhere in `transition/3`'s call graph" — `Letflow.Scheduler.create/2` is itself
  `Repo`-backed, so any hypothetical future call into it from `transition.ex` would
  already violate Purity (AC1) and be caught by that section's own grep command, which
  every future PR can and should re-run against **current** source — no git history
  needed. This confirms diagnosis point 3.
- **The property the deleted test actually protects is a one-time historical fact, not
  an evergreen one.** "REQ-188's own PR didn't touch `transition.ex`" was permanently and
  immutably true (or false) the moment REQ-188 merged (commit `77637268`, per the test's
  own UPDATE comment at lines 436-455) — there is nothing left to check going forward.
  This is the same distinction ISS-0378 drew between its own deleted test (a one-time
  per-PR fact, already discharged) and the sibling GenServer-count test it kept (an
  evergreen, continuously-worth-checking property). Confirms diagnosis point 4.
- **No acceptance criterion maps to this test.** `test/specs/REQ-188.md`'s own
  acceptance-criterion table (read in full, §0) enumerates rows `1a, 1b, 2, 3, 4,
  moduledoc, transition.ex untouched, 5, 6, 7, 9, 10` — the `transition.ex untouched` row
  (line 85) carries no AC number at all, unlike every numbered row. Cross-checked against
  `docs/requirements.yaml`'s REQ-188 entry (consulted, not fully read, per Load Scoped
  Context — the acceptance-criteria list it names has no "transition.ex unmodified"
  clause; the requirement's ACs are the recurring-timer/retention behaviors ACs 1-10
  already covered by the row list) — same "no documented coverage to preserve" situation
  ISS-0378 found. Confirms diagnosis point 5.

**Conclusion: delete, do not write a narrower/structural replacement.** A narrower
git-diff variant (e.g. re-pinning to a different ref, or checking a sub-region) would
still leave a test whose pass/fail depends on git history rather than shipped source —
the exact shape `docs/anti-patterns.md`'s entry already says to avoid, and the same
reasoning ISS-0378 §1 applied to its own, structurally identical case.

## 2. Replacement structural assertion: NONE proposed

No replacement test is added. Reasoning:

- The only genuinely evergreen property in the deleted test's vicinity — "`transition.ex`
  never gains a DB/clock/network dependency" — is **already** asserted, permanently, by
  the moduledoc's own "Purity (AC1)" section and its `grep`-checkable command (§1 above).
  Adding a second, test-code version of the same check would be pure duplication, not a
  new property.
- Unlike ISS-0378 (where the deleted test's informal target — "no second ticker" — had a
  genuine surviving sibling test with different content), the `describe "transition.ex is
  untouched by REQ-188"` block here has **no sibling test** inside it — it is the sole
  test in that `describe` block (lines 435-496 contain exactly one `test`). There is
  nothing to point to as "already covers it" within the file itself; the covering
  property lives in `transition.ex`'s own moduledoc, one file over, which is where it
  belongs (the module's own purity contract, not a test asserting git history).
  Encoding "check the moduledoc's grep command still returns zero matches" as an
  executable test would require either (a) shelling out to run that exact grep from
  within a test — which reintroduces a git/filesystem-scan-shaped assertion for a
  property the moduledoc already states declaratively and which `mix xref`/compile-time
  purity is a better fit for than a runtime test — or (b) parsing the moduledoc text
  itself, which is fragile in the opposite direction (breaks on doc rewording, not on git
  history). Neither is warranted here: this fix's owned module is
  `test/letflow/scheduler_req188_test.exs` only, and inventing a new structural test for
  a property that already has a clear, permanent, human/grep-checkable home is scope
  beyond what ISS-0404 asks for.
- If a future requirement wants "`transition.ex` has no Scheduler/Timer/Poller
  dependency" as its own standalone, automatically-enforced acceptance criterion (e.g. a
  `mix xref` compile-time check, or a CI step running the moduledoc's own grep command),
  that is a new decision for whoever owns that future requirement — not silently resolved
  here. Recorded as an open note in §8, not treated as blocking.

**Confirms:** no replacement test is added, so nothing added by this fix depends on git
or commit history in any form.

## 3. Exact edit to `test/letflow/scheduler_req188_test.exs`

All line numbers below are current as of the file read in §0 (497 lines total, confirmed
via `wc -l` on this branch immediately before writing this design).

### 3a. Delete the header comment, blank line, and `describe` block

Delete lines **430-497** in full:

- Lines 430-433: the four-line `# ---...` / `# transition.ex was untouched BY REQ-188
  ITSELF ...` / `# pinned to REQ-188's own commit range -- see UPDATE below` / `#
  ---...` header comment block.
- Line 434: the blank line separating the header comment from the `describe` line.
- Lines 435-496: `describe "transition.ex is untouched by REQ-188" do` through its
  closing `end` — the dated UPDATE comment (lines 436-469) and the sole test
  `"lib/letflow/engine/transition.ex had zero diff across REQ-188's own commit range
  (746a3ac0..77637268)"` (lines 470-495) in full, plus the `describe` block's closing
  `end` (line 496).
- Line 497 is the **module's own** closing `end` — this line is **not** deleted; it
  becomes the new last line of the file once lines 430-496 are removed (immediately
  following what is currently line 428's `end` and line 429's blank line, i.e. the close
  of the `"moduledoc names the REQ-188 deferral statements"` describe block).

### 3b. Resulting shape of the file's tail

After 3a, the file's last `describe` block is the pre-existing, unmodified `describe
"moduledoc names the REQ-188 deferral statements"` block (currently lines 410-428),
followed directly by the module's closing `end`. No other `describe`/`test` in the file
is touched — AC1a, AC1b, AC2, AC3, AC4, and the moduledoc-deferral tests (lines 1-428,
i.e. everything before line 430) are entirely unaffected by this edit.

File shrinks from 497 lines to approximately 429 lines (497 − 68 deleted lines [430-497
inclusive] + 1 retained line [the module's closing `end`, relocated to the new final
line] = 430; implementer should let the file settle naturally — e.g. via `mix format` —
rather than matching this arithmetic precisely, same caveat ISS-0378 §3d gave).

**No other part of `test/letflow/scheduler_req188_test.exs` changes.** In particular:
the moduledoc (lines 1-33) is untouched even though it currently references this test's
existence obliquely ("plus the moduledoc-deferral-statement and
`transition.ex`-untouched-by-REQ-188's-own-commit-range structural checks (see the dated
UPDATE comment on that describe block...)" at lines 4-7) — see §7 for why this is
flagged as in-scope-to-fix, not silently left stale.

**Correction needed in the moduledoc (in-scope, small):** lines 4-7 of the moduledoc
still describe the about-to-be-deleted test ("plus the moduledoc-deferral-statement and
`transition.ex`-untouched-by-REQ-188's-own-commit-range structural checks (see the dated
UPDATE comment on that describe block: this guard is pinned to REQ-188's own historical
commit range, not a live check against the current branch)"). Once the test is deleted,
this sentence describes something that no longer exists in the file and its own
parenthetical directs the reader to a describe block that is gone. The implementer
should remove the `transition.ex`-untouched clause from this sentence, leaving the
moduledoc's true remaining scope: `"plus the moduledoc-deferral-statement structural
checks"` (or equivalent phrasing — not a rigid character-for-character requirement, same
latitude iss0378 §3c gave its own title-text edit). This is a same-file edit within the
one owned module, not a scope violation.

## 4. Test isolation — confirmed no other dependency

Read the **whole file** (`test/letflow/scheduler_req188_test.exs`, all 497 lines, in
§0), not just the block being deleted, to check for any dependency on it:

- **No shared helper defined inside the deleted block.** The block defines no `defp`,
  no module attribute, no fixture — it contains exactly one `test` and its
  documentation comments. All of this file's shared helpers
  (`provisioned_tenant/1`, `unique_name/1`, `graph_gateway_loop/1`, `active_definition!/1`,
  `start_looping_instance!/1`, `live_token_id!/2`, `past_fire_at/1`,
  `arm_recurring_timer!/4`, `recurring_timer_count/2`, `recurring_timers_other_than/3`)
  are defined once, at the top of the file (lines 50-189), entirely outside and before
  the deleted block, and are used only by the AC1/AC1b/AC2/AC3/AC4 tests above it — none
  of them is called from, or calls into, the deleted block.
- **Local variables `req_188_base`/`req_188_merge` are scoped to the deleted test's own
  function body** (lines 471-472) — not module attributes, not accessible outside that
  `test do...end`. The repo-wide grep in §0 confirms these names appear nowhere else in
  `lib/` or `test/`.
- **No shared state.** The deleted test only shells out to `git cat-file -e` and `git
  diff --stat`, asserting on captured process output — it writes nothing to the
  database, sets no application-env value, and defines no data any other test reads.
  `use Letflow.DataCase, async: false` (line 35) wraps each test in its own sandbox
  transaction, so no cross-test state leak channel exists regardless.
- **Ordering.** No `seed: 0` or manual ordering markers appear in this file; ExUnit does
  not guarantee describe-block order here, and no other test in the file references
  anything the deleted block would have produced.

**Conclusion: the deleted block can be removed with no impact on any other test in this
file**, matching ISS-0378 §4's isolation-check rigor and result.

## 5. `test/specs/REQ-188.md` update

**Exact row to remove:** the table row at line 85 of `test/specs/REQ-188.md` (the
`Acceptance criterion → test case map` table), which currently reads:

```
| transition.ex untouched | `lib/letflow/engine/transition.ex` unmodified by this requirement | `scheduler_req188_test.exs` "transition.ex had zero diff across REQ-188's own commit range" | `git diff --stat` scoped to REQ-188's own historical commit range (`746a3ac0..77637268`) shows zero diff. UPDATE (WF03-ISS0398-20260901, REVIEWER, 2026-09-01): originally checked `git diff --stat` against a live, defensively-resolved base ref (`origin/main`/`main`) vs. current `HEAD`, which made the assertion permanently unsatisfiable for any later legitimate change to `transition.ex` — rescoped to REQ-188's own fixed commit range so it proves what it always meant to prove (REQ-188 itself never touched `transition.ex`) without gating unrelated future work. See the test file's own dated UPDATE comment for the full rationale. |
```

**Action: delete this row entirely** (not edit its content) — the corresponding test no
longer exists after §3, so a spec-to-test map row pointing at it would be a dangling
reference. This mirrors that the row carries no AC number (unlike every other row in the
table, confirmed in §1), so removing it drops no numbered acceptance criterion from the
map.

**Also update, in the same file, for consistency (small, same-file, in-scope):**

- Line 10-11 (the file's own header, "Test files:" line) currently reads: `` `test/letflow/scheduler_req188_test.exs` (Part 1 — SCH-07 recurring re-arm, ACs 1–4, plus the moduledoc-deferral and transition.ex-untouched checks), ``. Remove the `and transition.ex-untouched` clause, leaving: `` `test/letflow/scheduler_req188_test.exs` (Part 1 — SCH-07 recurring re-arm, ACs 1–4, plus the moduledoc-deferral checks), ``. Exact wording not rigid — any equivalent phrasing that drops the now-false claim satisfies this.

No other line in `test/specs/REQ-188.md` references this test or row (the "Mutation
testing" section, lines 92-108, lists five mutations against `scheduler.ex`/`poller.ex`
only — none relate to `transition.ex` or the deleted test).

## 6. `docs/anti-patterns.md` update

**Target:** the existing entry "A test scoped to one specific historical commit SHA
breaks the moment that commit is squash-merged away" (starts at line 1764), specifically
its **Recurrence** paragraph (lines 1792-1809), which currently ends:

```
...An identical, still-open instance of this same
pattern remains at `test/letflow/scheduler_req188_test.exs:432-452` as of this writing --
out of scope for ISS-0378, flagged for a separate issue.
```

**Action: append** (do not edit or remove the existing text) a new sentence immediately
after that ending, within the same Recurrence paragraph (or as a new sentence
immediately following it — either placement satisfies this, as long as it reads as a
continuation of the same Recurrence discussion rather than a new top-level entry).
Recommended exact text to append:

```
ISS-0404 resolved that flagged instance by deletion, the same pattern as ISS-0378's own
resolution: `scheduler_req188_test.exs`'s "transition.ex is untouched by REQ-188" test
(a `git diff --stat 746a3ac0..77637268` check, i.e. a historical-commit-range variant of
this same defect class rather than a moving-symbolic-ref one) was removed outright, with
no replacement test, because the property it checked was (a) a one-time historical fact
already permanently discharged the moment REQ-188 merged, not an evergreen property, and
(b) to the extent any evergreen property was really intended ("transition.ex never gains
a DB/clock/network dependency"), that broader property is already covered permanently by
`transition.ex`'s own moduledoc "Purity (AC1)" section and its grep-checkable command --
see `lib/letflow/design/iss0404-req188-transition-test-fix.md`.
```

This keeps the append scoped to the one existing entry the issue itself pointed at
(`docs/issues/ISS-0404.yaml`'s own `source:` field names this exact
paragraph), rather than creating a new, separate anti-patterns entry for what is already
documented as the same recurring class.

## 7. Scope confirmation

This design touches, and instructs the implementer to touch, **only**:

- `test/letflow/scheduler_req188_test.exs` — delete lines 430-497 per §3a, and correct
  the moduledoc's lines 4-7 per §3b's "Correction needed" note (same file, same owned
  module — not a separate file).
- `test/specs/REQ-188.md` — delete the table row at line 85, and adjust the "Test files:"
  header line (10-11) per §5.
- `docs/anti-patterns.md` — append to the existing Recurrence paragraph per §6.

It explicitly does **NOT** touch:

- `lib/letflow/engine/transition.ex` — confirmed clean in §1: no alias, no call, no
  content added by REQ-188 or requiring removal. Zero production-code changes.
- `lib/letflow/scheduler.ex`, `lib/letflow/scheduler/timer.ex`,
  `lib/letflow/scheduler/poller.ex` — not implicated by this issue at all.
- `test/letflow/scheduler/poller_test.exs` — ISS-0378's own file, already resolved; not
  reopened here.
- Any other test file, requirement, design doc, or spec.

## 8. Open questions

None load-bearing for this fix — mirrors ISS-0378's own precedent (§7 there also found
none blocking). One forward-looking note, not an open question blocking this fix, stated
explicitly rather than silently resolved:

- If a future requirement wants "`transition.ex` has no Scheduler/Timer/Poller
  dependency" enforced automatically (rather than relying on a human/agent re-running the
  moduledoc's grep command by hand, or on `mix xref` catching a genuinely bad `alias`),
  that would need either a CI step running the moduledoc's own documented grep command,
  or a `mix xref`-based compile-time check. Not designed here — out of scope for this
  test-deletion fix, and not something ISS-0404 asked for.
