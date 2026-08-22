# Design: ISS-0273 — pin `@h6_floor_commit`, remove the BOOTSTRAP fallback

**Run:** `WF03-ISS0273-20260822` · Step 2 (CODE-DESIGNER) ·
**Author:** CODE-DESIGNER · **Status:** proposed — awaiting CODE-DESIGN-VALIDATOR

**Scope statement (read this first):** this is a **narrow, scoped fix** — pin
`@h6_floor_commit` to a real value and delete the now-dead bootstrap branch it made
necessary. It is **not** a redesign of the H6 commit-boundary mechanism itself.
Everything in `lib/letflow/design/iss0262-h6-floor-commit-addendum.md` §0, §1, §2.1,
§2.2, §2.4, §3, §4, §6, §7 (the algorithm, the floor-choice rationale, the
`@grandfathered` H6 deletion, the moduledoc bullet, the test-fixture guidance) stays
exactly as-is and is **unchanged by this document**. This document supersedes only:
that addendum's §2.3 (the "operational step at Step Final" instructions, which
described a *future*, not-yet-executed pinning step) and the "BOOTSTRAP" branch of
`resolve_h6_floor_commit/0` plus its surrounding comment block, both of which existed
only because §2.3's step had not yet run. No implementation code appears below —
literal values, one function signature, and exact prose edits only.

---

## 1. Relationship to ISS-0262 and why this is a recurrence, not a new mechanism

Per ISSUE-FIXER's diagnosis (`handoffs/WF03-ISS0273-20260822/step-01-issue-fixer.json`
`result.summary`): `@h6_floor_commit` (line 133) is still the literal `"BOOTSTRAP"`
today — the addendum's §2.3 operational follow-up ("whoever runs the next Step Final
attempt MUST edit this literal to the freshly-fetched `origin/main` tip sha") was never
executed when commit `184d846` merged ISS-0262 onto `main`. This document is that
follow-up, done properly: a fixed sha chosen and justified below (not "whatever
`origin/main` happens to be right now"), landed as an ordinary code change on this
branch, with the dynamic-resolution machinery removed rather than left dormant.

---

## 2. RULING: the exact sha to pin `@h6_floor_commit` to

```
@h6_floor_commit "c4a8e39729e253397d4f1aa34155a74522930252"
```

Full 40-character sha: `c4a8e39729e253397d4f1aa34155a74522930252`. This is `184d846`'s
**immediate parent** — the commit on `main` immediately before ISS-0262's H6 check was
merged (`184d846cd8838ea2bd9a6d3b54cda36ca0e280b0`, "fix: lint_handoffs detects
non-JSON handoff files via new H6 check [WF03-ISS0262-20260822] (#525)").

### 2.1 Verified independently (not copied from the diagnosis)

Ran directly on this branch, redone here rather than trusted from ISSUE-FIXER's report:

```
$ git show -s --format="%H %P" 184d846
184d846cd8838ea2bd9a6d3b54cda36ca0e280b0 c4a8e39729e253397d4f1aa34155a74522930252
```

Confirms `c4a8e397...` is `184d846`'s sole parent, and gives the full 40-char form.

### 2.2 Why the parent, not `184d846` itself — the `ancestor_or_equal?` reflexivity check

`test/fixtures/lint_handoffs/h6/step-01-fixture-non-json.md` (the fixture
`F-H6-FIRES-NEW`, `F-H6-CONTENT-NEVER-READ`, and `T-NEW-AFTER-FLOOR-HARD-FAILS` all
exercise via the *production* call path, i.e. no explicit `floor` argument — they go
through `h6_floor_commit/0`) was first added to git history **in `184d846` itself**:

```
$ git log --follow --diff-filter=A --format=%H --reverse -- \
    test/fixtures/lint_handoffs/h6/step-01-fixture-non-json.md
184d846c...
```

`pre_floor_file?/2`'s Step B calls `ancestor_or_equal?/2`
(`lint_handoffs.ex:252-258`), which runs `git merge-base --is-ancestor <sha> <floor>`.
Git's `--is-ancestor` is **reflexive**: a commit is its own ancestor, exit code `0`.
Verified directly, not assumed:

```
$ git merge-base --is-ancestor 184d846 184d846; echo $?
0
```

So **if `@h6_floor_commit` were pinned to `184d846` itself**, the fixture's
`first_add_sha` (`184d846`) would equal `floor` (`184d846`), `ancestor_or_equal?` would
return `true`, and `pre_floor_file?` would classify the fixture as
**pre-floor/grandfathered** — the opposite of what `F-H6-FIRES-NEW`,
`F-H6-CONTENT-NEVER-READ`, and `T-NEW-AFTER-FLOOR-HARD-FAILS` all assert
(`result.hard_new` non-empty, `result.hard_grandfathered == []`). Pinning to `184d846`
would make those three tests fail for a *different* reason than they fail today —
still wrong, just wrong in the other direction.

Pinning to the **parent**, `c4a8e397`, avoids this because the fixture's
`first_add_sha` (`184d846`) is a strict *descendant* of `c4a8e397`, not an ancestor of
it and not equal to it. Verified directly:

```
$ git merge-base --is-ancestor 184d846 c4a8e397; echo $?
1
$ git merge-base --is-ancestor c4a8e397 184d846; echo $?
0
```

`--is-ancestor 184d846 c4a8e397` exits `1` (not an ancestor) → `ancestor_or_equal?`
returns `false` → `pre_floor_file?` returns `false` → the fixture lands in
`result.hard_new`, exactly as those three tests require. The second command
(`c4a8e397` **is** an ancestor of `184d846`, exit `0`) simply confirms the parent
relationship the opposite direction, consistent with §2.1's `git show %P` output.

This also correctly keeps everything H6 was written to grandfather — the 10 real
`WF03-ISS0258-20260822` files ISSUE-FIXER checked individually — on the pre-floor side,
since their first-add commits predate `184d846`'s parent (they were committed to `main`
well before ISS-0262's branch existed). No new verification of that claim is needed
here beyond ISSUE-FIXER's per-file check; it does not depend on which of `184d846` or
its parent is chosen (both postdate all 10 files), only the fixture's classification
does.

---

## 3. RULING: `resolve_h6_floor_commit/0` and the BOOTSTRAP sentinel — REMOVED

Per this task's scope statement and the ISS-0273 dispatch's explicit framing ("a
narrow, scoped fix (pin the value + remove the now-dead bootstrap branch)"): the
runtime `git merge-base HEAD origin/main` fallback path is **deleted entirely**, not
kept dormant.

### 3.1 Justification

`resolve_h6_floor_commit/0` (`lint_handoffs.ex:197-212`) exists for exactly one
reason: to give `h6_floor_commit/0` a real, git-resolvable value on every run **while**
`@h6_floor_commit` was still the `"BOOTSTRAP"` sentinel (i.e., before the pinning step
this document performs had ever happened). Once `@h6_floor_commit` is unconditionally a
real, fixed 40-char sha (§2), the `if @h6_floor_commit != "BOOTSTRAP"` branch in
`resolve_h6_floor_commit/0` is permanently true — the `else` branch (the two
`System.cmd` calls) becomes dead code with no reachable caller, forever, not just for
this run. Keeping unreachable code "as a fallback" would misdescribe the mechanism to a
future reader exactly the way the addendum's §3 already reasoned about dead
`@grandfathered` entries: dead data left in place reads as a second, live mechanism
still co-governing the floor, when it is not. There is also no stated future scenario
in either design doc where `@h6_floor_commit` would legitimately revert to an unset
placeholder — H6 has exactly one floor for its whole remaining lifetime (§2.1/§2.2 of
the original addendum: the floor never needs to move again once chosen, because
everything after it is correctly judged "new" forever). A hypothetical future need to
re-bootstrap H6's floor (e.g. a from-scratch reimplementation) is not a scenario either
existing design document anticipates or this task's acceptance criteria call for
designing against; if it arises, it is a new design decision for that future work, not
a reason to carry dead code now.

### 3.2 Resulting shape of `h6_floor_commit/0` (signature/spec only, no body)

```
@spec h6_floor_commit() :: String.t()
```

Simplified to return `@h6_floor_commit` directly — no `Process.get/put` memoization
(nothing left to memoize: reading a module attribute has no cost worth caching), no
call to `resolve_h6_floor_commit/0` (deleted), no `System.cmd` calls anywhere in this
function. The return type tightens from `String.t() | nil` to `String.t()` because the
pinned literal is always a real, non-nil, fixed value — there is no longer any runtime
path that can produce `nil` here. (`pre_floor_file?/2`'s own `floor :: String.t() | nil`
parameter type is untouched — it stays nilable because `T-PRE-FLOOR-NIL-FLOOR-FAILS-SAFE`
legitimately exercises `pre_floor_file?/2` directly with an explicit `nil`, independent
of `h6_floor_commit/0`; that fail-safe path is a property of `pre_floor_file?/2` itself,
not of the now-deleted bootstrap mechanism, and stays exactly as specified in
`iss0262-h6-floor-commit-addendum.md` §1.4/§6.)

`resolve_h6_floor_commit/0` itself (`lint_handoffs.ex:197-212`) is **deleted**, function
and all — not deprecated, not left unused. Nothing else calls it once `h6_floor_commit/0`
no longer does.

---

## 4. Exact comment/moduledoc locations to update

Four locations carry stale "not-yet-resolved bootstrap state" prose. Each is named
exactly, with the disposition:

1. **`lint_handoffs.ex:115-133`** — the comment block immediately above
   `@h6_floor_commit`, specifically the paragraph starting `# 2026-08-22, ISS-0262 H6
   floor-commit addendum (rework_count 2): this literal is a BOOTSTRAP placeholder
   only...` (lines 122-132). This entire paragraph describes a state that is now
   historical (the bootstrap phase completed once this fix lands) and must be replaced.
   Replacement text (prose, not a literal instruction to future readers — this is
   describing what *is*, not what *must happen*):

   > 2026-08-22, ISS-0273: pinned to `c4a8e397...930252` — the parent of `184d846`, the
   > commit that merged the H6 check onto `main` — per
   > `lib/letflow/design/iss0273-h6-floor-commit-pin.md`. This value never needs to move
   > again: everything H6 was written to grandfather predates it, and everything
   > introduced from `184d846` onward (including H6's own fixture) correctly lands on
   > the "new, must pass or hard-fail honestly" side. The BOOTSTRAP runtime-resolution
   > fallback this constant previously required has been removed —
   > `h6_floor_commit/0` now returns this literal directly.

   The lines immediately above this paragraph (the original, still-accurate mechanism
   description at `lint_handoffs.ex:115-121`, "The commit boundary before which a
   non-JSON handoff-shaped file (H6) is automatically exempt...") are **unchanged** —
   only the dated BOOTSTRAP paragraph is replaced.

2. **`lint_handoffs.ex:184-195`**, the `h6_floor_commit/0` function and its `@spec` —
   updated per §3.2 above (spec narrows to `String.t()`, body simplified to a direct
   return, no comment changes needed beyond what the code itself now shows since this
   function was never separately documented above its `@spec`).

3. **`lint_handoffs.ex:197-212`**, `resolve_h6_floor_commit/0` — the whole function
   **deleted**, not edited. No comment is "updated" here because nothing about it
   remains to carry stale prose.

4. **`lib/letflow/design/iss0262-h6-floor-commit-addendum.md` §2.3** ("The operational
   step this requires at Step Final") — this section describes a step that has now been
   performed by this fix rather than deferred to a future Step Final attempt. Add one
   line at the top of §2.3 (do not delete or rewrite the section's body — it remains an
   accurate historical record of the mechanism that was supposed to run and didn't):

   > **Superseded 2026-08-22 (ISS-0273):** this operational step was never executed
   > after `184d846` merged (the floor stayed at the `"BOOTSTRAP"` sentinel, re-deriving
   > dynamically on every run — see `iss0273-h6-floor-commit-pin.md`). This fix performs
   > the pin directly as an ordinary code change instead of as a deferred Step Final
   > action; §2.3 below is kept as the historical record of the mechanism that was
   > intended but skipped, not as a live instruction for any future attempt.

   The moduledoc's H6 bullet (`lint_handoffs.ex:38-45`) and the surrounding "no
   wildcard grandfathering, H6 is the exception" paragraph (`:52-55`) both already
   describe the commit-boundary mechanism itself, not its bootstrap state — **no edit
   needed** there; they remain accurate unchanged.

---

## 5. Test guidance: what the 3 currently-failing assertions need, and whether existing fixtures suffice

**Existing fixtures suffice. No new throwaway fixture is needed.** All three failing
tests (`T-NEW-AFTER-FLOOR-HARD-FAILS`, `F-H6-CONTENT-NEVER-READ`, `F-H6-FIRES-NEW`) call
`LintHandoffs.lint_file/2` with **no explicit `floor` argument**, i.e. they exercise the
real, production `h6_floor_commit/0` path — this was always the intent (per the
existing test file's own `T-NEW-AFTER-FLOOR-HARD-FAILS` comment, "proves the criterion
using `lint_file/2`'s real production call path"). §2.2 above already establishes, by
direct git verification, that once `@h6_floor_commit` is pinned to `c4a8e397...930252`:

- `test/fixtures/lint_handoffs/h6/step-01-fixture-non-json.md`'s first-add commit
  (`184d846`) is **not** an ancestor of `c4a8e397` → `pre_floor_file?` returns `false`
  → `lint_file/2` puts the fixture's violation in `result.hard_new`, not
  `result.hard_grandfathered`.

That is exactly what all three currently-failing assertions require:

- `F-H6-FIRES-NEW` (`:106-125`): `assert [violation] = result.hard_new`,
  `violation.grandfathered == false`, `result.hard_grandfathered == []` — all satisfied.
- `F-H6-CONTENT-NEVER-READ` (`:127-135`): `assert [%{rule: "H6"}] = result.hard_new` —
  satisfied (same call, same result shape).
- `T-NEW-AFTER-FLOOR-HARD-FAILS` (`:297-...`): asserts the identical production-path
  outcome — satisfied for the same reason.

**No assertion text changes and no new fixture construction are required for these
three tests** — they were written correctly against the intended final mechanism; they
fail today purely because `@h6_floor_commit` was never pinned. Pinning it to the value
in §2 makes them pass as already written.

**What must be double-checked, not changed, as a side effect of this fix (regression
guard, not new coverage):**

- `F-GRANDFATHERED-NOT-NEW` (`:246-259`, the 10 real `WF03-ISS0258-20260822` files) —
  unaffected by the choice of `184d846` vs. its parent (both postdate all 10 files, per
  ISSUE-FIXER's individual verification); still expected to pass unchanged.
- `T-PRE-FLOOR-TRUE`, `T-PRE-FLOOR-FALSE`, `T-PRE-FLOOR-NIL-FLOOR-FAILS-SAFE`,
  `T-PRE-FLOOR-UNTRACKED-PATH-FALSE` (`:268-295`) — all four call `pre_floor_file?/2`
  directly with their own explicit `floor` arguments (`HEAD`, the repo's root commit, or
  `nil`), never through `h6_floor_commit/0` — entirely independent of `@h6_floor_commit`'s
  value. Unaffected by this fix; expected to keep passing unchanged.

No test file changes are in scope for this fix beyond what ELIXIR-DEV's implementation
naturally requires (i.e., none — the test file itself does not need editing; only
`lib/mix/tasks/letflow.lint_handoffs.ex` does).

---

## 6. Files touched by this fix

| File | Change |
|---|---|
| `lib/mix/tasks/letflow.lint_handoffs.ex` | `@h6_floor_commit` literal changed from `"BOOTSTRAP"` to `"c4a8e39729e253397d4f1aa34155a74522930252"` (§2); its comment block's BOOTSTRAP paragraph replaced (§4 item 1); `h6_floor_commit/0` simplified, `@spec` narrowed to `String.t()` (§3.2, §4 item 2); `resolve_h6_floor_commit/0` deleted entirely (§3.2, §4 item 3) |
| `lib/letflow/design/iss0262-h6-floor-commit-addendum.md` | One superseded-note line added at the top of §2.3 (§4 item 4) — no other edits |
| `test/mix/tasks/letflow.lint_handoffs_test.exs` | **No changes required** (§5) — existing assertions pass once the floor is pinned |

**Not touched:** `@grandfathered`, `grandfathered?/2`, `ancestor_or_equal?/2`,
`compute_pre_floor_file?/2`, `pre_floor_file?/2`'s public signature, the moduledoc H6
bullet, H1-H5's mechanisms, `docs/agents/protocols/GIT_MERGE.md`. This fix is scoped
exactly to §2-§4 above and nothing else in the H6 mechanism.

---

## 7. Acceptance-criteria traceability

| Acceptance criterion | Answered in |
|---|---|
| Exact 40-char sha, verified reasoning (not copied) | §2, §2.1 (`git show -s --format="%H %P" 184d846`), §2.2 (`git merge-base --is-ancestor` checks run directly, including the reflexivity check that rules out `184d846` itself) |
| Disposition of `resolve_h6_floor_commit/0` and BOOTSTRAP sentinel | §3 — removed entirely, with justification (§3.1) and resulting signature (§3.2) |
| Exact comment/moduledoc locations needing updates | §4 — four locations named with line numbers and exact replacement text |
| Guidance for the 3 failing tests: fixtures suffice or new fixture needed | §5 — existing fixtures suffice; no test file changes required at all |
| No `.ex` implementation bodies | This document contains one module-attribute literal, one `@spec` line, verified `git` command transcripts, and prose replacement text for comments — no compilable function bodies |
| Narrow, scoped fix, not a mechanism redesign | Scope statement at the top of this document, and §6's "not touched" list |
