# ISS-0404 — WF-03 Step 4 verification report (TEST-DESIGNER)

**Run:** WF03-ISS0404-20260902
**Fix commit:** `803e5514` — "fix: delete SHA-pinned transition.ex-untouched test from
scheduler_req188_test.exs [WF03-ISS0404-20260902]"
**Design authority:** `lib/letflow/design/iss0404-req188-transition-test-fix.md`
**Precedent:** `lib/letflow/design/iss0378-poller-ac7-test-fix.md` (ISS-0378) — identical
defect class, resolved the same way (deletion, no replacement).

## 0. Why literal fail-then-pass does not apply here

WF-03 Step 4's normal rule ("shown to fail against the pre-fix code and pass against the
fix") presumes a new/changed assertion that pre-fix code violates and post-fix code
satisfies. This fix adds no assertion at all — it is a pure deletion. There is nothing to
run red-then-green:

- The deleted test (`describe "transition.ex is untouched by REQ-188"`, pre-fix lines
  430-497) asserted `git diff --stat` was empty over the fixed historical commit range
  `746a3ac0..77637268`. That property — "REQ-188's own PR didn't touch `transition.ex`"
  — was permanently true or false the moment REQ-188 merged (commit `77637268`). It is a
  **one-time historical fact**, already discharged, not an evergreen property a future
  commit could violate. Running it pre-fix does not fail — it currently passes, and always
  will, until the SHAs become unreachable (shallow clone / history rewrite), which is a
  **future risk**, not a reproducible-today bug. There is no way to make it fail today
  without literally destroying repo history, which is out of the question.
- This is also NOT the "code under test does not exist" case WF-03 Step 4 carves out
  (which requires mutation testing instead). That exception applies when a fix *adds*
  new logic and the pre-fix failure would be `UndefinedFunctionError` for everything —
  trivially satisfiable, proving nothing about discrimination. Here nothing was added;
  no module, function, or behavior is new. Mutating `lib/letflow/engine/transition.ex`
  would not probe anything this fix touches — the fix touches only test/spec/doc files,
  and `transition.ex` itself is explicitly confirmed untouched (design doc §1, §7).
- The correct proof obligation for a deletion-only fix, mirroring how ISS-0378 satisfied
  the analogous situation for `poller_test.exs`, is: (a) confirm structurally that the
  specific fragility class is now absent project-wide, and (b) confirm the surrounding
  suite is still green post-deletion, with no orphaned reference or lost coverage of a
  real acceptance criterion. Both are performed below with real command output.

## 1. Fragility confirmed gone — project-wide structural grep

The defect class (`docs/anti-patterns.md`'s "A test scoped to one specific historical
commit SHA breaks the moment that commit is squash-merged away") is: an **executable**
test asserting on `git diff`/`git show`/`git cat-file` output scoped to a **fixed
historical SHA or SHA-range**.

**Step 1 — the exact SHAs from this issue, project-wide:**

```
$ grep -rn "746a3ac0\|77637268" --include=*.exs test/
(no matches)
```

Zero matches anywhere in any `.exs` file. The ISS-0404 instance is fully gone.

**Step 2 — broader sweep for any executable git-shelling test naming any SHA (7-40 hex
chars) as an argument to `diff`/`show`/`cat-file`:**

```
$ grep -rn 'System\.cmd("git"' --include=*.exs test/ | grep -v -- '--verify\|rev-parse\|rev-list'
test/letflow/engine/wasm/host_api_write_test.exs:747:        System.cmd("git", [
test/letflow/engine/wasm/plugin_handler_test.exs:54:        System.cmd("git", [
```

These two are the **only** executable git-diff-shelling test calls left in the whole
`.exs` suite. Both were inspected directly (`host_api_write_test.exs:734-757`,
`plugin_handler_test.exs:38-64`) and neither is the ISS-0404/ISS-0378 defect class: both
resolve `base_ref` at run time from `["origin/main", "main"]` via `git rev-parse
--verify` and diff `"#{base_ref}...HEAD"` — a **live, moving ref**, not a fixed
historical SHA/SHA-range. (This live-ref shape is itself a related-but-distinct
fragility already discussed in the anti-patterns entry and in ISS-0398's own fix to
*this same file* — see `test/specs/REQ-188.md` line 85's UPDATE note: a live ref against
current HEAD is actually the *opposite* problem, "permanently unsatisfiable for any
later legitimate change" — but it is not the SHA-pinned class ISS-0404 targets, and
touching `host_api_write_test.exs`/`plugin_handler_test.exs` is out of scope: the design
doc's owned module is `test/letflow/scheduler_req188_test.exs` only.) **New finding,
reported rather than silently expanded into this run's scope:** these two are candidates
for a future issue if the live-ref shape is judged to need the same structural-check
treatment; not filed as a new issue by this agent per this run's role (TEST-DESIGNER
does not call the issue queue) — flagging here for ORCH/ISSUE-FIXER visibility, since
"No Issue Left Local-Only" applies to a discovered defect even when out of this run's
scope.

**Step 3 — remaining hits are markdown/yaml, not executable code:**

All other project-wide matches for `git show`/`git diff` with a SHA argument
(`test/specs/ISS-*.md`, `test/specs/REQ-*.md`, `test/reports/*.yaml`) are prose inside
Markdown/YAML investigation notes and historical, append-only run reports — not `.exs`
files ExUnit executes. They document commands that were run once, by hand, during a past
diagnosis; they carry no pass/fail behavior today and are not test code. Two `.exs`
*comments* (`test/support/tenant_slug_test.exs:165`,
`plugin_handler_ac7_cross_platform_regression_test.exs:96`) reference a `git show
<sha>:<path>` command in prose for provenance — also not executable assertions.

**Step 4 — `lib/` sweep (production/tooling code, for completeness):**

```
$ grep -rn 'System\.cmd("git"' --include=*.ex lib/
lib/mix/tasks/letflow.lint_handoffs.ex:224:    case System.cmd("git", ["merge-base", "--is-ancestor", sha, floor], ...)
lib/mix/tasks/letflow.lint_handoffs.ex:642:    case System.cmd("git", ["show", "-s", "--format=%cI", @artifacts_out_rule_commit], ...)
```

Both are `letflow.lint_handoffs`' own infrastructure (ancestor-checking a handoff's
`commit_sha_list` against a floor commit; reading one fixed rule-commit's timestamp for
staleness comparison) — not test assertions and not the "diff must be empty" shape this
defect class describes. Out of scope, noted for completeness only.

**Conclusion: the ISS-0404 defect instance is confirmed gone, and it is the only
SHA-pinned-diff instance of this class left anywhere in the executable test suite.**
Zero remaining instances of the *targeted* defect class (fixed-SHA git-diff assertion)
project-wide, matching the issue's own success condition.

## 2. Nothing regressed — green suite, no orphaned reference, no lost AC coverage

**Targeted file, post-fix:**

```
$ mix test test/letflow/scheduler_req188_test.exs
...
Finished in 6.5 seconds (0.00s async, 6.5s sync)
Result: 7 passed
```

7 passed, 0 failures — matches the fix commit's own quoted result exactly.

**Surrounding suite (scheduler + transition + timer-wiring, the modules this file and
its deleted test were about):**

```
$ mix test test/letflow/scheduler_req188_test.exs test/letflow/scheduler_test.exs \
    test/letflow/scheduler/poller_test.exs test/letflow/engine/transition_test.exs \
    test/letflow/engine/timer_wiring_test.exs
...
Finished in 41.5 seconds (0.6s async, 40.9s sync)
Result: 77 passed (1 property, 76 tests)
```

77 passed, 0 failures across all five files, including the property test in
`transition_test.exs` (matches `test/letflow/process_instance_test.exs`-style coverage
per the test developer guide) and ISS-0378's own already-fixed `poller_test.exs`.

**Compile:**

```
$ mix compile --warnings-as-errors
(clean, no output — exit 0)
```

**No orphaned reference:**
- `test/letflow/scheduler_req188_test.exs`'s moduledoc (lines 1-30) was re-read in full:
  it now says "plus the moduledoc-deferral-statement structural checks" with no mention
  of the deleted `transition.ex`-untouched test — matches design §3b's correction.
- `test/specs/REQ-188.md` was grepped for "transition.ex untouched" /
  "transition.ex-untouched" — zero matches. The dangling table row (former line 85) and
  the header clause (former lines 10-11) are both gone.
- Repo-wide grep for `req_188_base`/`req_188_merge` (the deleted test's local variable
  names) and for the two SHAs — zero matches anywhere. No dangling reference survives.

**No lost AC coverage — checked directly against `docs/requirements.yaml`'s REQ-188
entry, not merely cited from REVIEWER's prior finding:**

```
$ awk '/^  - id: REQ-188$/,/^  - id: REQ-189$/' docs/requirements.yaml
```

REQ-188's `acceptance_criteria` list (10 entries, SCH-07 recurring re-arm + periodic
retention behaviors — timer re-arming, `fired_count`/`repeat_total` bookkeeping,
retention-runner scheduling, moduledoc-deferral statements) contains no clause
referencing `transition.ex` being unmodified. The deleted test's own row in
`test/specs/REQ-188.md` (pre-fix) carried no AC number, unlike every other row in that
file's coverage table (confirmed directly in the design doc's §1 and independently
re-confirmed here by reading the pre-fix table via `git show 803e5514^:test/specs/REQ-188.md`
— the `transition.ex untouched` row is the only unnumbered row in the table). Deleting it
drops zero acceptance-criterion coverage.

**File isolation — no other test depends on the deleted block:** repo-wide grep confirms
the deleted block's only local names (`req_188_base`, `req_188_merge`) appear nowhere
else, and the surviving `describe "moduledoc names the REQ-188 deferral statements"`
block (now the file's last block, lines 407-425) is unmodified and has no dependency on
the deleted block or its helper functions (none were shared — the deleted block defined
no `defp`/module attribute, per design doc §4).

## 3. Working tree

No mutation, no worktree, no checkout was made to the working tree for this
verification — the pre-fix file content needed for cross-checking was read via `git show
803e5514^:<path>` (a read-only object-store lookup) and via `awk`, never via `git
checkout`. Confirmed clean:

```
$ git status --porcelain
(empty)
$ git branch --show-current
feature/WF03-ISS0404-20260902
```

## 4. Deliverable summary

- No new `test/` file added — matches the validated design's §2 conclusion (no
  replacement test warranted; the one real evergreen property already lives in
  `transition.ex`'s own moduledoc "Purity (AC1)" section).
- This report is the WF-03 Step 4 proof-of-fix artifact for a deletion-only regression
  fix, per the reasoning in §0 above.
- One new, out-of-scope finding surfaced during the project-wide sweep (§1, Step 2): two
  live-symbolic-ref `git diff --stat` tests
  (`test/letflow/engine/wasm/host_api_write_test.exs:735`,
  `test/letflow/engine/wasm/plugin_handler_test.exs:39`) are a related-but-distinct
  fragility (moving ref vs. fixed SHA) — not touched here, flagged for ORCH per "No
  Issue Left Local-Only" if judged worth its own issue.

**Handoff verdict: PASS — route to TEST-DESIGN-VALIDATOR.**
