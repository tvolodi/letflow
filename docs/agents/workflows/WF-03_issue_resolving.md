# WF-03 — Issue Resolving

**Trigger:** a queued `docs/issues/ISS-NNNN.yaml` entry (`status: open`), a test
regression, or a self-discovered/user-reported defect in existing behavior.
**Owner:** `ORCH`

WF-03 vs. WF-02: if the expected behavior is already specified (in
`docs/requirements.yaml` or an existing test), this is WF-03. If the feature itself
isn't specified yet, that's a new requirement — WF-01 then WF-02.

## Overview

```
[INPUT: ISS-NNNN or a described defect]
        │
        ▼
┌──────────────────────────┐
│  STEP 00: GIT SETUP      │ ← ELIXIR-DEV/FRONTEND-DEV, docs/agents/protocols/GIT_SETUP.md
└──────────┬───────────────┘
           │ PASS
           ▼
┌───────────────────────┐
│  STEP 0.5: REGISTRY   │ ← ISSUE-FIXER
│  LOOKUP               │   Has this exact issue been seen/fixed before? Check
│                        │   docs/issues/ for a resolved entry with matching symptoms.
└──────────┬─────────────┘
           ▼
┌───────────────────────┐
│  STEP 1: DIAGNOSE     │ ← ISSUE-FIXER
│  Root cause, not      │   Does NOT implement the fix — produces a diagnosis for
│  symptom              │   CODE-DESIGNER to design a fix from.
└──────────┬─────────────┘
           ▼
┌───────────────────────┐
│  STEP 2: FIX DESIGN   │ ← CODE-DESIGNER → CODE-DESIGN-VALIDATOR ⛔ (same as WF-02 1/1b)
└──────────┬─────────────┘
           ▼
┌───────────────────────┐
│  STEP 3: IMPLEMENT    │ ← ELIXIR-DEV / FRONTEND-DEV (same procedure as WF-02 2a/2b)
│  → SECURITY-REVIEWER  │   → REVIEWER (same as WF-02 2c/2d)
│  → REVIEWER           │
└──────────┬─────────────┘
           ▼
┌───────────────────────┐
│  STEP 4: REGRESSION   │ ← TEST-DESIGNER writes a test that reproduces the bug and
│  TEST                 │   FAILS against pre-fix code, then PASSES post-fix — this is
│                        │   the fail-first proof the fix actually fixes something.
│                        │   → TEST-DESIGN-VALIDATOR → TEST-RUNNER (same as WF-02 3/3b/4)
└──────────┬─────────────┘
           ▼
┌───────────────────────┐
│  STEP 5: CLOSE ISSUE  │ ← ISSUE-FIXER sets docs/issues/ISS-NNNN.yaml status: resolved,
│                        │   resolving run-id, real UTC timestamp. If a GitHub issue
│                        │   exists (github_issue field), close it: gh issue close <n>
│                        │   --comment "Fixed in <run-id>, see docs/issues/ISS-NNNN.yaml"
└──────────┬─────────────┘
           ▼
┌──────────────────────────┐
│  STEP FINAL: GIT MERGE   │ ← same agent as Step 00
└──────────┬───────────────┘
           ▼
[OUTPUT: ISS-NNNN resolved; fix merged to main with a regression test]
```

## Step 0.5 — Registry lookup

**Agent:** `ISSUE-FIXER`

```
1. Read docs/issues/*.yaml for entries with status: resolved whose description
   mentions similar symptoms/files.
2. If a clear match exists: cite it in this handoff's context, and check whether the
   same root cause has recurred (a fix that didn't actually fix the underlying issue —
   R-Co's own history shows this class of recurrence happens, see
   docs/agents/instructions/security-invariants.md's INV-1 reference for a concrete
   example of exactly this in that project). If it's recurring, flag severity as at
   least MAJOR regardless of the original severity.
3. Complete the handoff: summary notes whether a prior match was found.
```

## Step 1 — Diagnose

**Agent:** `ISSUE-FIXER`

```
1. Reproduce the issue directly — run the failing scenario, read actual output. Do not
   diagnose from the bug report's prose alone (No Speculation).
2. Trace to root cause: which function, which invariant broke, why the existing tests
   didn't catch it (if any existed).
3. Write the diagnosis into the handoff's result.summary: root cause (not just
   symptom), affected files, and what a fix needs to change.
4. Do NOT implement the fix. Complete the handoff: next_action: "Route to
   CODE-DESIGNER for fix design".
```

## Steps 2-4

Follow the same procedures as WF-02's Step 1/1b (design), 2a-2d (implement + gates),
3/3b/4 (test), with one addition: **Step 4's test must be shown to fail against the
pre-fix code and pass against the post-fix code** — TEST-DESIGNER states this
explicitly in the test spec (checked out the pre-fix commit, ran the new test, confirms
it failed; then confirms it passes on the fix branch). A test that only ever ran
against already-fixed code proves nothing about whether it actually covers the bug.

## Step 5 — Close the issue

**Agent:** `ISSUE-FIXER`

```
1. docs/issues/ISS-NNNN.yaml: status: resolved, resolved_in_run: <run-id>,
   resolved_at: <real UTC timestamp>.
2. If github_issue is set and gh is reachable: gh issue close <n> --comment
   "Fixed in <run-id>. See docs/issues/ISS-NNNN.yaml and the regression test at
   <test file path>."
3. Complete the handoff: PASS, next_action: "Route to Step Final".
```

**ORCH, immediately on this step's PASS** (same turn, before writing the `RUN_DONE` log
line): if this issue has a real `letflow-queue` task (registered via `register_task`,
`task_type: "issue"`), call `release_lock` with `status: "done"` against that task id —
see `docs/agents/protocols/TASK_QUEUE.md`. Same rule as WF-02 Step Final: a resolved
issue that stays `open`/locked in the queue is a stale entry from the moment this step
passes, not something to clean up in a later reconciliation pass. If the queue is
unreachable (checked both `$QUEUE_AUTH_TOKEN` and `.env`), state that explicitly in the
`RUN_DONE` line and flag the task id for next-session reconciliation.

## Output

The issue's root cause is fixed, proven by a fail-then-pass regression test, merged to
`main`, and the issue record closed with a real resolution timestamp — not just marked
done on an agent's say-so.
