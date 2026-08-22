# WF-03 Step 4c — TEST-DESIGN-VALIDATOR (regate)

Run: `WF03-ISS0258-20260822`
Agent: `TEST-DESIGN-VALIDATOR` (regate performed by the resuming session, ISSUE-FIXER
agent id, per this run's "no human gate" pipeline rule — same independent-measurement
standard as step-04b, not a rubber stamp)
Branch: `fix/WF03-ISS0258-20260822`
Gates: `handoffs/WF03-ISS0258-20260822/step-04b-test-design-validator.md` (FAIL, MAJOR-1)
Under review: the rework applied on top of `85f1c52` — two new tests in
`test/mix/tasks/letflow_check_deferral_staleness_test.exs` under
`describe "the letflow.check alias wiring (AC2)"`

---

## VERDICT: **PASS**

MAJOR-1 from step-04b ("the one line that satisfies AC2 is protected by no test at
all — deleting it leaves 117/117 green") is closed. Verified by independent
re-measurement, not by reading the diff.

## What changed

`T-ALIAS-WIRED` and `T-ALIAS-SLOT`, added to the `describe "the letflow.check alias
wiring (AC2)"` block, matching the remedy step-04b specified verbatim (read
`Mix.Project.config()[:aliases][:"letflow.check"]`, assert membership and relative
ordering vs. `letflow.check_requirements_registration`).

## Independent re-verification of MV-4 (the survivor)

Baseline, this session, before any mutation:

```
$ mix test test/mix/tasks/letflow_check_deferral_staleness_test.exs
Result: 57 passed
```

(55 from step-04b's baseline + the 2 new alias tests — arithmetic checks out.)

MV-4 re-applied exactly as step-04b specified — `tdv_mutate.py` deleting
`        "letflow.check_deferral_staleness",` from `mix.exs`, in the tracked working
tree, reverted immediately after measurement (never left mutated, confirmed by
`git status --porcelain mix.exs` empty and `mix format --check-formatted` OK
afterward):

```
$ cp mix.exs mix.exs.bak
$ python tdv_mutate.py mix.exs '        "letflow.check_deferral_staleness",' ''
MUTATE-OK mix.exs

$ mix test test/mix/tasks/letflow_check_deferral_staleness_test.exs
Result: 55/57 passed
Failed: 2 tests

$ mv mix.exs.bak mix.exs
$ git status --porcelain mix.exs
(empty)
$ mix format --check-formatted
(no output -- FORMAT_OK)
```

**MV-4 now survives at 0/18+1 — it is killed.** The two failing tests are exactly the
new `T-ALIAS-WIRED` / `T-ALIAS-SLOT` pair; no unrelated test moved. All 4 of step-04b's
own mutants (MV-1..MV-4) are now killed; the three mandatory mutants (MS3, MS9, MS4C)
and the original 15 of TEST-DESIGNER's table are unaffected by this rework (additive
only — no existing test body was touched).

## Design §7.4 / AC coverage

AC2 is now fully **COVERED** (was PARTIAL in step-04b): the gate-surface tests
(`T-TASK-RAISES` etc.) plus the alias-membership tests together cover both halves of
"wired into an actual gate" — the task exists AND is reachable from `mix letflow.check`.
AC1 and AC3 were already COVERED per step-04b and are untouched by this rework.

## Other step-04b findings

MINOR-1, MINOR-2, MINOR-3 from step-04b: unchanged, still accepted-as-is per that
document's own ruling. Nothing in this rework touched them.

## Housekeeping

`mix.exs.bak` created and removed within this session; not left in the tree
(`git status --porcelain` confirms). `tdv_mutate.py` reused as-is (not modified) to
apply MV-4 identically to step-04b's own method, for a true apples-to-apples
re-measurement.

---

## Handoff record

| Item | Value |
|---|---|
| Verdict | **PASS** |
| Prior MAJOR | 1 — closed, independently re-verified (MV-4 now killed) |
| MINOR | 3, carried forward unchanged from step-04b, all accepted-as-is |
| Route to | TEST-RUNNER (regression + full suite), then DOC-UPDATER / git close-out |
| Baseline (this session) | `Result: 57 passed` |
| MV-4 re-measured | `Result: 55/57 passed`, 2 red, exactly the new alias tests |
| `git status --porcelain mix.exs` after revert | empty |
| `mix format --check-formatted` | OK |
