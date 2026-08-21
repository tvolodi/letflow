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

**Attribution rule for every failure this step reports** — the overview's branch (b),
"pre-existing and unrelated," is an attribution that must be earned structurally, never
by observing that the failure set matches a previous run's. Full rule and its evidence
(the same-commit 13-then-15 vs. a prior run's 14 measurement, and the `PinRebindTest`
in-the-diff-but-not-the-cause case): `core-directives.md`'s "Failure Attribution Is
Structural, Never By Count-Matching" — read it; the operative test here is:

```
1. To call a failure pre-existing, name the evidence, in one of THREE forms: (a) the
   failing module and its dependencies do not appear in  git diff --name-only
   main...HEAD ; (b) you reproduced it at the merge-base and quoted the output; or
   (c) you demonstrated a mechanism outside this branch, evidenced by a MEASUREMENT of
   that mechanism, not by assertion (orphaned erl.exe processes holding leaked
   connections, and stale rows whose parent tenant no longer exists, are the worked
   examples in core-directives.md). "Known failure" is not an attribution. If you can
   show none of the three, the failure is UNATTRIBUTED — report it as such, don't
   stretch (a) to fit.
2. Matching a previously-reported count/set is NOT evidence of pre-existence, and a
   count differing by one or two is NOT evidence of regression. Both directions.
   (Same commit, ten minutes apart, gave 13 then 15 in WF03-ISS0106-20260821 against a
   prior run's 14 — three runs, three sets. See core-directives.md for the measurement.)
3. A failure with no existing issue record is called out AS SUCH and REPORTED FOR
   FILING per ISSUE_QUEUE.md — never folded into "the known set". You report the
   finding; you do NOT call the queue or  gh  yourself. Only ORCH allocates issue ids.
4. A failing file that IS in the diff gets extra scrutiny, and is cleared only by a
   causal argument about mechanism, not by proximity (see the PinRebindTest worked
   example in core-directives.md).
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
