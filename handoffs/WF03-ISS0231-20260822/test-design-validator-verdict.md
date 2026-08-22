# TEST-DESIGN-VALIDATOR verdict — WF03-ISS0231-20260822, WF-03 Step 4

**Verdict: PASS.**
**Agent:** TEST-DESIGN-VALIDATOR. **Completed:** 2026-08-22T03:44:23Z.
**Worktree:** `C:\Users\tvolo\dev\ai-dala\letflow-2\.claude\worktrees\agent-aeee28f086c5abfec`,
branch `fix/WF03-ISS0231-20260822`.

**Artefacts gated:**
`test/mix/tasks/letflow_check_requirements_registration_test.exs` (29 tests, two modules),
`test/specs/ISS-0231.md`, against
`lib/mix/tasks/letflow.check_requirements_registration.ex` and
`lib/letflow/design/iss0231-requirement-registration-drift-detection.md` (read in full,
§11 taken as governing).

No blocker, MAJOR or MINOR finding. Three INFO notes are recorded at the end; none
gates.

---

## 1. Independent mutation runs — MY measurements

WF-03's "when the pre-fix failure is 'the code under test does not exist'" clause governs
this run: the fix *adds* a module, so the pre-fix failure of every test is
`UndefinedFunctionError` and proves nothing about discrimination. I therefore applied
mutants to the shipped logic myself and ran the suite myself. **Nothing below is copied
from TEST-DESIGNER's `scratch/iss0231_mutants.txt` or from the spec's table** — every
number is from a run I executed in this worktree.

Before relying on `scratch/iss0231_mutate.py` I read it in full and, for each mutant
applied, inspected the resulting `git diff lib/` to confirm the edit was the one the
mutant claims to be. Two further mutants (`MR4`, `MR6`) I wrote by hand, without the
harness, to close R4 and R6 — the two rules the harness has no mutant for.

**Baseline, measured before any mutation:**

    $ mix test test/mix/tasks/letflow_check_requirements_registration_test.exs
    Finished in 0.8 seconds (0.8s async, 0.02s sync)
    Result: 29 passed

| mutant | source | MY measured result | tests that went red (mine) | TEST-DESIGNER reported | agree? |
|---|---|---|---|---|---|
| **M1** field-form-only classifier | harness | **19/29** | F-DEFERRED-BASIC, F-DEFERRED-GREEN, F-NOVEL-FORM, F-NONINT-VALUE, F-BARE-MARKER, F-ANCHOR, F-BLOCK-NOTE, F-STAGES-SECTION, F-ROSTER-AGREEMENT, T-TASK-PRINTS-ON-GREEN — **10, zero `T-LIVE-*`** | 19/29, same 10 | ✅ exact |
| **M2** fallback → `:registered` | harness | **26/29** | F-NOVEL-FORM, F-NONINT-VALUE, F-ANCHOR | 26/29, same 3 | ✅ exact |
| **M3** R5 deleted entirely | harness | **28/29** | F-EMPTY-SECTION | 28/29, same | ✅ exact |
| **M4** R1 demoted to advisory | harness | **26/29** | F-NEITHER-EXIT, F-NOVEL-FORM-ADJACENT-TOKEN, T-TASK-RAISES | 26/29, same 3 | ✅ exact |
| **M5** `:deferred` → hard-fail | harness | **24/29** | F-DEFERRED-GREEN, F-BLOCK-NOTE, F-STAGES-SECTION, F-ROSTER-AGREEMENT, T-TASK-PRINTS-ON-GREEN | 24/29, same 5 | ✅ exact |
| **M6** ≥4-space rule dropped | harness | **26/29** | F-BLOCK-NOTE, T-LIVE-GREEN, T-LIVE-INVARIANTS | 26/29, same 3 | ✅ exact |
| **M7** R3 removed | harness | **28/29** | F-BARE-MARKER | 28/29, same | ✅ exact |
| **M8a** marker regex unanchored only | harness | **28/29** | F-ANCHOR | 28/29, same | ✅ exact |
| **MR4** R4 dropped from the violation set | **hand-written by me** | **28/29** | F-DUP-ID | (no such mutant existed) | new |
| **MR6** R6 violation retagged so R6 no longer fires | **hand-written by me** | **28/29** | F-NO-REQUIREMENTS-KEY | (no such mutant existed) | new |

Eight harness mutants re-measured, every count and every red set identical to what was
reported. Two mutants of my own construction, both detected by exactly one test each.

### 1.1 M1 — both halves confirmed, including the load-bearing half

The diff M1 actually produces (verified before running):

```diff
     field = Regex.run(@field_form_re, line)
-    marker = Regex.run(@marker_form_re, line)
+    _marker = nil
     cond do
       field != nil -> %{base | state: :registered, impl_order: ...}
-      marker != nil -> %{base | state: :deferred, rationale: ...}
-      true -> %{base | detail: "...matches neither recognised shape..."}
+      true -> %{base | state: :registered}
     end
```

That is a faithful field-form-only classifier — any attributed `impl_order` line becomes
`:registered` — i.e. ISS-0221's bug verbatim.

- **Count: CONFIRMED.** 19/29, ten red.
- **"Zero `T-LIVE-*` red": CONFIRMED — this is the load-bearing half.** All four
  `T-LIVE-*` tests (T-LIVE-GREEN, T-TOTALITY-LIVE, T-LIVE-INVARIANTS,
  T-ROSTER-LIVE-AGREEMENT) stayed green under M1. Nine of the ten detectors are hermetic
  `F-*` fixtures; the tenth, `T-TASK-PRINTS-ON-GREEN`, is task-level over a **temp-directory
  fixture corpus**, not the live file. So no test touching the real
  `docs/requirements.yaml` detects the bug this fix exists to prevent.
- **Root cause of that, independently verified.** I ran the shipped task against the real
  corpus: `115 entries = 115 registered + 0 deferred + 0 neither + 0 unclassified`, and
  `grep -c UNREGISTERED docs/requirements.yaml` returns **1** — a single 2-space-indented
  block-note line at 5554, which the ≥4-space attribution rule correctly attributes to no
  entry. With zero deferred entries there is nothing for M1 to misclassify. The claim that
  the hermetic group is the whole test is not rhetoric; it is measurably true on this
  branch.

---

## 2. Gate checks

### 2.1 Every rule R1–R6 has a test that actually discriminates it

Each row is backed by a mutant I applied and ran, not by inspection:

| rule | discriminating test | proof (my run) |
|---|---|---|
| R1 (`:neither` hard-fails) | F-NEITHER-EXIT, T-TASK-RAISES, F-NOVEL-FORM-ADJACENT-TOKEN | M4 → 26/29, those three red |
| R2 (`:unclassified` hard-fails) | F-NOVEL-FORM, F-NONINT-VALUE | M2 → 26/29, both red |
| R3 (deferral carries a rationale) | F-BARE-MARKER | M7 → 28/29, red |
| R4 (ids unique) | **F-DUP-ID** | **MR4 (my own) → 28/29, red** |
| R5 (`entry_count > 0`) | F-EMPTY-SECTION | M3 → 28/29, red |
| R6 (`requirements:` key present) | **F-NO-REQUIREMENTS-KEY** | **MR6 (my own) → 28/29, red** |

**R4 specifically** (the rule §7.4 had no test for at all): I removed
`duplicate_id_violations/1` from `collect_violations/3` by hand. `F-DUP-ID` went red and
nothing else did. It is a real, isolated discriminator for R4, not a test that merely
mentions it.

`F-TOTALITY` and `T-TOTALITY-LIVE` detect no mutant — and the spec says so explicitly,
citing §11.4's reasoning that `sum(counts) ≡ length(entries) ≡ entry_count` holds
identically by construction. Kept as invariant assertions with no coverage claim attached.
That is honest bookkeeping, not a hole.

### 2.2 No skipped or tagged-out coverage

Grepped the test file for `@tag`, `@moduletag`, `:skip`, `pending`, `TODO`: **zero
matches** except one occurrence of the literal string `"# TODO: impl_order -- REQ-008 was
UNREGISTERED, ask ORCH"` at line 433, which is *fixture input data* (one of F-ANCHOR's two
extension lines), not a pending marker. The spec contains no "TODO: implement test". All
29 tests execute: `26` four-space `test "` declarations in the fixture module + `3` in
`…TaskTest` = 29, matching `Result: 29 passed`.

### 2.3 Fixtures are hermetic and self-sufficient

- The fixture module is `async: true`, builds every corpus as an in-memory string via
  `doc/1`/`req/2`, touches no filesystem and no database.
- `docs/requirements.yaml` is opened by exactly two calls, both read-only and both in the
  `T-LIVE-*` `setup`: `File.exists?/1` (line 694) and `File.read!/1` (line 695). **No
  write, copy, rename or delete of the live corpus anywhere in the file.**
- Every `File.write!`/`File.mkdir_p!`/`File.rm_rf!` in `…TaskTest` targets a uniquely-named
  directory under `System.tmp_dir!()` (`System.unique_integer([:positive])`), cleaned up
  via `on_exit`.
- **Verified empirically:** `git status --porcelain docs/requirements.yaml` is empty after
  a full run, and `git status --porcelain` on the whole tree is empty after all ten mutant
  runs plus three green runs.
- No test depends on another having run first: every test constructs its own corpus, and
  the `T-LIVE-*` group derives its own report in `setup`.
- **`File.cd!/2` is safe here, and this is not merely asserted.** `…TaskTest` is
  `async: false` and ExUnit runs all sync tests *after* all async tests finish, so the
  global cwd change can never overlap a concurrent async test; `File.cd!/2` restores the
  prior directory on return. The pattern, and the reason for it (`run/1` reads the corpus
  path relative to cwd with no path seam), matches the existing precedent in
  `test/mix/tasks/letflow_check_toolchain_test.exs:24`. I ran the whole directory together
  — `mix test test/mix/tasks/` → **62 passed** — so the two cd-ing suites coexist.
- No hardcoded secrets, tokens, passwords or connection strings.

### 2.4 No pinned totals that go stale

Grepped for `111`, `115`, `90`, `21`. Every hit is in moduledoc/comment prose (lines 31,
32, 35, 47, 229, 705, 724) or is a *fixture id string* testing malformed ids (line 480:
`"REQ_115"`, `"115"`). **No assertion pins any live-corpus total.** The only numeric
assertion over the live file is `assert report.entry_count > 100` (T-TOTALITY-LIVE), a
lower bound that cannot go stale as the corpus grows, and
`T-ROSTER-LIVE-AGREEMENT` builds its expected totality string from the report's own
fields. Confirmed.

### 2.5 T-ROSTER's retirement is a genuine relocation

- **The pre-authorisation is real.** Design §11.6, OQ-5 ruling, final paragraph, verbatim:
  *"TEST-DESIGNER should still note in the test file that this test legitimately fails if
  the deferred set ever empties completely, and that such a failure means 'the deferred set
  is now empty, confirm that is intended and retire this test', not 'regression'."*
- **The triggering condition is factually met**, verified by me, not inherited: the live
  corpus classifies 0 deferred (task output above), and the only `UNREGISTERED` string left
  in the file is an unattributed 2-space block note.
- **The property was relocated, not dropped.** `F-ROSTER-AGREEMENT` holds all three
  clauses of the §11.6 revised T-ROSTER against a hermetic fixture with a deliberately
  non-empty deferred set: names ≥1 id, prints a matching non-zero `total deferred:`, and
  asserts `printed_ids == Enum.sort(deferred_ids)` plus `refute id in printed_ids` for every
  `:registered` id. The third clause — the one §11.6 called "what keeps the unpinned form
  honest" — is present and is the strongest of the three.
- **F-ROSTER-AGREEMENT is red under M1: CONFIRMED by my own run** (failure #2 of 10).
- The surviving live half, `T-ROSTER-LIVE-AGREEMENT`, states the same agreement
  conditionally on the deferred count and is true of any corpus. It is correctly *not*
  claimed as a detector for anything.

### 2.6 TEST-DESIGNER's four self-reported findings — each honestly characterised

**(a) M8a initially undetected; F-ANCHOR extended. The extension is a real discriminator,
not tautological.** I applied M8a and read the actual failure:

```
  1) test ... F-ANCHOR -- `impl_order: 5  # was UNREGISTERED until Tuesday` is :registered (M8)
     test/mix/tasks/letflow_check_requirements_registration_test.exs:400
     "# impl_order was UNREGISTERED before Tuesday" is not a marker-form line; an
     unanchored marker pattern would absorb it into :deferred (design section 4.4)
     stacktrace: ...test.exs:437 ... ...test.exs:431: (test)
```

The failure is at lines 431–437 — the *extension*, not the original body. It is not
tautological because it pins a state that genuinely differs between shipped and mutant
code and that carries an independent consequence: shipped → `:unclassified` → **R2
hard-fail**; unanchored → `:deferred` → **green pass**. That is exactly the absorption
class ISS-0231 is about, with the buckets reversed. TEST-DESIGNER's accompanying admission
— that the design's own stated reason for anchoring (`impl_order: 5  # was UNREGISTERED
until Tuesday`) does *not* discriminate M8a, because the `cond` tries the field form first
— is correct and I confirmed it: under M8a that first half of F-ANCHOR passed; only the
extension failed. Reporting a design argument as half-wrong rather than quietly patching
around it is the honest characterisation.

**(b) `classify_entry([])` raises `FunctionClauseError`, characterised not fixed.** Honest.
I verified unreachability from the source rather than taking it on trust:
`split_entries/1`'s `reduce` starts a new sub-list only on a line matching `@entry_start_re`
and otherwise prepends to an existing one, so every list it emits is headed by the `- id:`
line and none is empty. `F-CLASSIFY-EMPTY` pins the behaviour, and the test file's own
`classify/1` helper carries a `refute lines == []` guard so no fixture can produce one.
The `apply/3` indirection is justified in the test (a literal `[]` is a compile-time type
error under `--warnings-as-errors`, which `mix letflow.check` runs) — that is a real
constraint, not an evasion. Characterisation is the right call for genuinely dead input;
this is not a defect dressed up.

**(c) `impl_order_hint: 7` classifies `:neither`, not `:unclassified` as §7.4 predicted.**
Honest, and verified mechanically: the trigger is `@token_re ~r/\bimpl_order\b/`; in
`impl_order_hint` the `_` is a word character so `\b` cannot match after `impl_order`, and
in `impl-order` the `-` breaks the token on the other side. Neither string carries the bare
token, so neither line is attributed and the entry is `:neither`. Crucially this is a
*bucket* difference with no safety loss — `:neither` hard-fails under R1 exactly as
`:unclassified` hard-fails under R2 — and the test proves that rather than asserting it:
`F-NOVEL-FORM-ADJACENT-TOKEN` asserts `[_] = violations_for(report, "R1")` and
`violations_for(report, "R2") == []`, and **it went red under my M4 run** (R1 demoted),
which shows it is a live R1 discriminator, not a decorative state-pin. TEST-DESIGNER also
rebuilt F-NOVEL-FORM from forms that *do* carry the bare token rather than leaving the
original inputs in place, so no coverage was lost in the correction.

**(d) A fixture's own prose can trip the classifier.** Honest and self-consistent: the
`neither_entry/1` helper carries an inline note (lines 196–198) explaining that its
`title:` deliberately avoids the token. This is the module's designed §3(d) behaviour and
the same hazard §6.5 records for the moduledoc; recording that it reaches fixture prose too
is useful, not a cover for a defect.

### 2.7 Format and suite

    $ mix format --check-formatted
    (no output, exit 0)

    $ mix test test/mix/tasks/letflow_check_requirements_registration_test.exs
    Finished in 0.5 seconds (0.5s async, 0.00s sync)
    Result: 29 passed

    $ mix test test/mix/tasks/
    Finished in 1.2 seconds (0.8s async, 0.4s sync)
    Result: 62 passed

    $ mix letflow.check_requirements_registration
    ========================================================================
    mix letflow.check_requirements_registration -- docs/requirements.yaml
    ========================================================================
    DEFERRED (visible debt -- always reported, never gates): none
    ------------------------------------------------------------------------
    115 entries = 115 registered + 0 deferred + 0 neither + 0 unclassified
    ========================================================================

Alias wiring confirmed at `mix.exs:65-66` — `letflow.check_requirements_registration`
immediately after `letflow.check_toolchain`, i.e. position 2, as §11.6's OQ-2 ruling
requires.

### 2.8 Mutant cleanup — proved, not asserted

Every mutant was applied in-tree and reverted with
`git checkout -- lib/mix/tasks/letflow.check_requirements_registration.ex`. After the final
revert:

    $ git status --porcelain lib/ test/
    (empty)
    $ git status --porcelain
    (empty)
    $ mix test test/mix/tasks/letflow_check_requirements_registration_test.exs
    Result: 29 passed

`lib/` is at its committed state and the suite re-runs green. No mutant survives in the
tree.

---

## 3. Findings

**Blocker: none. MAJOR: none. MINOR: none.**

### INFO-1 — `scratch/iss0231_mutants.txt` is an incomplete record of the spec's table

The scratch log carries populated result blocks for M1, M8a, M8b, M9 and M10 only; the
blocks for **M2, M2b, M3, M4, M5, M6 and M7 are empty**, while `test/specs/ISS-0231.md`
states specific counts for all of them. Had I relied on that artefact, seven of twelve rows
of the mutation table would have appeared unevidenced. I re-measured six of the seven
myself (M2, M3, M4, M5, M6, M7) and **every count and red set matches the spec exactly**,
so the spec is accurate and the log is merely truncated. `scratch/` is git-ignored and is
not a project artefact, so nothing needs correcting in the tree — recorded only so a future
reader does not mistake the empty blocks for missing work.

### INFO-2 — two mutants I did not re-measure

M2b and M8b (harness) and M9/M10 were not re-run by me; my mandate required M1 plus two
more and I ran eight. M2b is the mirror of M2 (fallback → `:deferred` rather than
`:registered`) and M8b is M8a plus a `cond` reordering; both are strictly adjacent to
mutants I did measure and both are reported at counts consistent with those. M9 and M10 are
the two whose scratch-log evidence *is* present. No gate rests on the unmeasured rows.

### INFO-3 — divergences from the design are declared, not silent

Two §7.4 specs were changed (F-NOVEL-FORM's inputs, F-ANCHOR's scope), one was retired
under an explicit §11.6 pre-authorisation (T-ROSTER), and four were added beyond §7.4
(F-DEFERRED-GREEN, F-DUP-ID, F-CRLF, T-TASK-R6-MISSING-FILE). I checked each §7.4 inventory
row against the test file: every one is present or accounted for above. Each divergence is
recorded in both the spec and the test file's moduledoc with its reason. Nothing was
dropped silently.

---

## 4. Conclusion

The mandatory WF-03 obligation is discharged: I applied ten mutants — eight from the
harness after inspecting what it edits, two written by hand — ran the suite for each, and
every number above is my own measurement. M1's reported 19/29 is confirmed, and the
load-bearing claim that **no `T-LIVE-*` test detects M1** is confirmed and independently
explained by the live corpus holding zero deferred entries. Every rule R1–R6, including the
two the harness had no mutant for, has a test that goes red when the rule is removed. No
skipped coverage, no stale pins, hermetic and self-sufficient fixtures, a clean live corpus
across every run, and a clean `lib/` at the end.

**PASS.** Step 4 may advance.
