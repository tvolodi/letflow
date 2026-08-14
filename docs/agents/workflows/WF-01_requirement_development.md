# WF-01 — Requirement Development & Validation

**Trigger:** new feature request, or a migration stage needs its next batch of
requirements expanded into `docs/requirements.yaml`.
**Owner:** `ORCH`

## Overview

```
[INPUT: feature request, or "expand stage S<N>"]
        │
        ▼
┌───────────────────┐
│  STEP 1: DRAFT    │ ← REQ-ANALYST
│  Write requirement(s)
│  into docs/requirements.yaml
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│  STEP 2: VALIDATE │ ← REQ-VALIDATOR ⛔ HARD GATE
│  Check quality     │
└────────┬──────────┘
         │
    PASS?├─── NO ──► REWORK → back to STEP 1 (max 3)
         │
        YES
         │
         ▼
[OUTPUT: requirement(s) ready for WF-02, status stays "pending" in
 docs/requirements.yaml — WF-01 only confirms it's well-formed, it does not
 change the pending/in_progress/done/blocked status field]
```

WF-01 skips the git wrapper (Step 00/Final) — it only writes to `docs/`, per
`core-directives.md`'s File Placement Rules and the same exception R-Co uses.

## Step 1 — Draft requirements

**Agent:** `REQ-ANALYST`

```
1. Read docs/requirements.yaml in full (existing schema: id/title/owner/status/stage/
   description/acceptance_criteria/depends_on — do not invent a new schema).
2. Read docs/migration/README.md and the relevant docs/migration/stage-N-*.md for the
   stage this requirement belongs to.
3. Read docs/anti-patterns.md.
4. For a new requirement:
   a. Assign the next REQ-NNN id (check the highest existing REQ number across the
      whole file, not just the current stage's block).
   b. Write it with: title, owner (the role expected to implement it — usually
      ELIXIR-DEV or FRONTEND-DEV), status: pending, stage, description (specific,
      cites real file paths where relevant, same style as existing entries), at least
      2 concrete/verifiable acceptance_criteria, depends_on (existing REQ ids whose
      completion this needs).
   c. Size it to one agent turn — if it doesn't fit, split it into multiple
      requirements with depends_on chaining them, don't write one oversized entry.
5. Append to docs/requirements.yaml (append, do not reorder or rewrite existing
   entries — same append-only spirit as docs/status/requirement_status.yaml).
6. Complete the handoff (or, if acting without formal handoff machinery for a small
   ORCH-direct request, report directly): status PASS, artifacts_out:
   ["docs/requirements.yaml"], next_action: "Route to REQ-VALIDATOR".
```

### Acceptance criteria for this step
- [ ] Every new requirement has id, title, owner, status, stage, description, ≥2
      acceptance criteria, depends_on
- [ ] No orphaned `depends_on` references (every cited REQ id exists)
- [ ] Stage assignment matches the dependency order in `docs/migration/README.md`
- [ ] No contradiction with an existing `done` requirement or a `docs/migration/decisions/*.md` record

## Step 2 — Validate requirements ⛔ HARD GATE

**Agent:** `REQ-VALIDATOR`

```
1. Read the new/changed requirement(s) plus docs/requirements.yaml in full for context.
2. For each, check:
   a. TESTABILITY — can a test be written that definitively passes or fails? Vague
      words ("appropriately", "as needed", "reasonably") → FAIL.
   b. CONSISTENCY — does it conflict with any `done` requirement or a
      docs/migration/decisions/*.md record? Read the decisions directory.
   c. DEPENDS_ON CORRECTNESS — are the cited dependencies actually the right ones (not
      just non-orphaned, but genuinely required before this can start)?
   d. STAGE FIT — is this requirement scoped to the stage it claims? (e.g. no identity
      work under an S0 stage tag)
   e. SIZE — does this look like one agent turn, or does it smuggle in multiple
      unrelated deliverables that should be split?
3. If ANY check fails: FAIL, list issues by requirement id and check letter.
4. If all pass: PASS.
5. Complete the handoff: next_action PASS → "requirement ready for WF-02" |
   FAIL → "Rework REQ-ANALYST".
```

### Acceptance criteria for this step
- [ ] Every check a-e above was actually run against the new requirement text, not
      assumed
- [ ] Any FAIL cites the specific requirement id and which check failed

## Rework loop

Same as `docs/agents/ORCHESTRATOR.md` §5: on FAIL, ORCH increments `rework_count`,
appends the issues to REQ-ANALYST's next task description, re-routes. Max 3 before
escalation.

## Output

A `pending` requirement in `docs/requirements.yaml` that REQ-VALIDATOR has confirmed is
well-formed, testable, and consistent — ready for WF-02 to pick up. WF-01 does not flip
`status`; it stays `pending` until WF-02 actually starts work (see WF-02 Step 00).
