# WF-04 — Full Test Run

**Trigger:** pre-stage-gate check (before `ORCHESTRATOR.md` §8 clears Stage N+1), or a
scheduled/requested full-suite validation.
**Owner:** `ORCH`

## Overview

```
[INPUT: "validate stage S<N>" or "run the full suite"]
        │
        ▼
┌──────────────────────────┐
│  STEP 00: GIT SETUP      │ ← only if this run is expected to produce fixes; a
│  (conditional)           │   pure read-only validation pass with no fixes needed
└──────────┬───────────────┘   skips the git wrapper entirely (docs-only exception,
           │                   extended here: no-code-change validation is exempt too)
           ▼
┌───────────────────────┐
│  STEP 1: FULL SUITE   │ ← TEST-RUNNER
│  mix test, whole repo │
└──────────┬─────────────┘
           ▼
┌───────────────────────┐
│  STEP 2: RELEASE      │ ← RELEASE-VALIDATOR
│  VALIDATION           │   Independently re-checks every "done" requirement in the
│                        │   stage against its acceptance criteria — not a re-run of
│                        │   Step 1's report, a fresh check against the code.
└──────────┬─────────────┘
           ▼
      Any BLOCKER/MAJOR found?
      ├─ NO  → PASS. RELEASE-VALIDATOR writes docs/status/<stage>-release-<date>.yaml
      │        recording the clean result. ORCH may now clear the stage gate.
      └─ YES → Each finding is either:
               (a) this run's own responsibility to fix (a genuine regression) →
                   route to the owning agent, fix, re-run from Step 1 (this becomes,
                   in effect, a WF-03 loop nested inside this run — cap at max_rework
                   the same as any other rework)
               (b) filed and forwarded per ISSUE_QUEUE.md if it's pre-existing and
                   unrelated to the stage gate itself (rare for a full-suite run, but
                   possible if it surfaces something outside the stage under test)
```

## Step 1 — Full suite

**Agent:** `TEST-RUNNER`

```
1. mix test — the entire suite, not scoped to any one requirement.
2. If a Docker fallback is needed (no local toolchain), use the documented procedure
   in docs/anti-patterns.md.
3. Write test/reports/report-<date>-WF04.yaml with full actual output — pass/fail
   counts, any StreamData property test seeds used, wall-clock duration.
4. Complete the handoff: PASS/FAIL, artifacts_out: ["test/reports/..."].
```

## Step 2 — Release validation

**Agent:** `RELEASE-VALIDATOR`

```
1. Read docs/requirements.yaml for every requirement tagged with the stage under
   validation.
2. For each requirement with status: done, independently re-check its
   acceptance_criteria against the actual current code/tests — not against what the
   requirement's own history in docs/status/requirement_status.yaml claims happened.
   This is the check that catches a "done" that was never actually true.
3. Confirm docs/migration/stage-N-*.md has a REVIEWER sign-off section for this stage.
4. Confirm no docs/migration/decisions/ record was silently contradicted by shipped
   code (cross-check REVIEWER's own gate at WF-02 Step 2d didn't get skipped for
   anything in scope).
5. Write docs/status/<stage>-release-<date>.yaml: which requirements were checked,
   which passed independent re-verification, any findings.
6. Complete the handoff: PASS/FAIL, next_action per the overview above.
```

## Output

A dated `docs/status/<stage>-release-<date>.yaml` record that either clears the stage
gate or names exactly what's blocking it — independently re-derived, not copied from
earlier steps' self-reports.
