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
┌───────────────────┐
│  STEP 3: REGISTER │ ← ORCH
│  register_task    │
│  in letflow-queue  │
└────────┬──────────┘
         │
         ▼
[OUTPUT: requirement(s) registered in letflow-queue and ready for WF-02, status
 stays "pending" in docs/requirements.yaml — WF-01 only confirms it's
 well-formed, it does not change the pending/in_progress/done/blocked status
 field]
```

**ISS-0221 (2026-08-22):** this Overview previously ended at Step 2's PASS with no
registration step, and the Output section repeated that — but `TASK_QUEUE.md` makes
`register_task` the thing that turns a validated requirement into claimable work
(`get_next_task` is the only sanctioned way to pick work once the queue is reachable,
and `impl_order` has no other source). A requirement that passed Step 2 but was never
registered is well-formed, validated, and *permanently unclaimable* — no error, it
simply never appears in `get_next_task`. Observed live 2026-08-22: `docs/requirements.yaml`
held 35 such requirements while `get_next_task` returned `no_eligible_task`. Step 3 below
closes that gap.

WF-01 skips the git wrapper (Step 00/Final) — it only writes to `docs/`, per
`core-directives.md`'s File Placement Rules and the same exception R-Co uses. Step 3's
`register_task` call is itself a `docs/requirements.yaml` edit (writing back
`impl_order`), so it stays inside that same exception.

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

## Step 3 — Register in letflow-queue

**Agent:** `ORCH` (only ORCH calls `register_task` — see `TASK_QUEUE.md`'s "who calls
what" division; REQ-ANALYST/REQ-VALIDATOR never call the queue themselves).

```
1. For each requirement Step 2 just PASSed, call register_task per
   docs/agents/protocols/TASK_QUEUE.md's "register_task" section:

     register_task(title, description, acceptance_criteria, depends_on, stage,
       task_type: "requirement")

2. The response's impl_order is the requirement's queue-claim sequence number and
   its set_lock/release_lock id -- write it back into the requirement's
   docs/requirements.yaml entry (an `impl_order:` field or comment, matching this
   repo's existing convention -- see other REQ-NNN entries for the exact form).
   Never guess or derive impl_order any other way; register_task is its only source.
3. If letflow-queue is unreachable (checked both $QUEUE_AUTH_TOKEN and .env, per
   TASK_QUEUE.md's "Before concluding the token is unavailable" check): state that
   explicitly rather than silently leaving the requirement unregistered forever --
   this step is not optional, only its timing can slip when the queue itself is down.
4. Complete the handoff (or report directly for a small ORCH-direct request): status
   PASS, artifacts_out: ["docs/requirements.yaml"], next_action: "Ready for WF-02
   (queue-mediated selection via get_next_task)".
```

### Acceptance criteria for this step
- [ ] Every requirement that passed Step 2 was actually registered — not just drafted
      and validated
- [ ] `impl_order` in `docs/requirements.yaml` matches the queue's response for that
      requirement, not a guess
- [ ] If the queue was unreachable, that is stated explicitly rather than silently
      skipped

## Output

A `pending` requirement in `docs/requirements.yaml` that REQ-VALIDATOR has confirmed is
well-formed, testable, and consistent, AND that ORCH has registered in `letflow-queue`
via Step 3 (its `impl_order` written back) — genuinely ready for WF-02 to pick up via
`get_next_task`, not merely well-formed on disk. WF-01 does not flip `status`; it stays
`pending` until WF-02 actually starts work (see WF-02 Step 00).
