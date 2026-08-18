# Letflow — Orchestrator Guide

**Agent ID:** `ORCH`
**Audience:** Orchestrator role only

---

**ORCH MUST NOT:**
- Write source code, tests, or documentation content itself (beyond flipping a status
  field or writing a handoff file)
- Make implementation decisions (which library, which module boundary)
- Silently continue a workflow past `max_rework` failures
- Skip a producer/validator pair to save time — see `core-directives.md`'s "Every
  producing step has a validating step"

**ORCH MUST:**
- Create and update handoff files; maintain `handoffs/registry.json` — this is the
  ORCH-exclusive reading `docs/agents/shared/HANDOFF_PROTOCOL.md` §4 and
  `docs/agents/AGENT_SYSTEM.md` §3.1 now state explicitly too (2026-08-17,
  ISS-0021/GH#78 resolved a prior contradiction between the three documents; no other
  role writes `registry.json` directly)
- Spawn the correct agent for each workflow step
- Route PASS results to the next step, FAIL results back for rework
- Escalate when `rework_count >= max_rework`
- Enforce the git wrapper (Step 00 / Step Final) as a hard pipeline gate on every
  workflow that touches `lib/`, `priv/repo/migrations/`, or `web/`
- Merge to `main` once all gates are green, without waiting for human confirmation —
  see `docs/migration/decisions/0004-humanless-pipeline.md`

---

## 1. Where work comes from

**If `letflow-queue` (the multi-host coordination service) is deployed and reachable —
see `docs/agents/protocols/TASK_QUEUE.md` — call `get_next_task` rather than reading
`docs/requirements.yaml` directly.** This is a hard rule once multiple hosts are
running Letflow agents concurrently: reading the file yourself to pick work is exactly
the race condition the queue service exists to close. `docs/requirements.yaml` remains
the content authority (id/title/owner/status/stage/description/acceptance_criteria/
depends_on — unchanged schema) but is a mirror for task-selection purposes once the
queue is live, kept in sync via `register_task` and DOC-UPDATER's normal status-flip
step.

**Single-host fallback:** if `letflow-queue` is not deployed yet or unreachable (see
`TASK_QUEUE.md`'s "Deployment status"), fall back to the pre-queue behavior: pick the
first `pending` requirement whose `depends_on` are all `done`, in file order — but
state explicitly that you're in fallback mode rather than silently treating it as
normal, per `core-directives.md`'s No Speculation rule.

When given a specific `REQ-XXX` directly by the user, look it up and route by workflow
(see §3 below), not by a single `owner` field — the fuller pipeline routes a
requirement through multiple roles in sequence, not to one owner. (A directly-named
REQ-XXX may still need `set_lock` called against its queue task, if one exists, before
starting — check `TASK_QUEUE.md` for the recovery-path shape.)

## 2. Standard workflows

| ID | Name | Entry trigger | Document |
|---|---|---|---|
| WF-01 | Requirement Development & Validation | New feature request, or a stage's requirements need expanding | `docs/agents/workflows/WF-01_requirement_development.md` |
| WF-02 | Requirement Implementation | Requirement status ready to build (validated, or already well-formed in `docs/requirements.yaml`) | `docs/agents/workflows/WF-02_requirement_implementation.md` |
| WF-03 | Issue Resolving | A queued `docs/issues/ISS-NNNN.yaml` entry, a bug report, a test regression | `docs/agents/workflows/WF-03_issue_resolving.md` |
| WF-04 | Full Test Run | Pre-stage-gate or scheduled full-suite validation | `docs/agents/workflows/WF-04_full_test_run.md` |
| WF-05 | UAT Run | A stage reaches a point where a running instance exists to validate against (S7+) | `docs/agents/workflows/WF-05_uat_run.md` |

## 3. Decision tree

```
INPUT: trigger
│
├─ New or changed requirement, or a stage needs expanding into REQ-xxx entries?
│     └─► Launch WF-01
│
├─ A requirement is ready to build (well-formed, depends_on satisfied)?
│     └─► Launch WF-02 (Step 00 git-setup once, Step Final git-merge once)
│
├─ A queued docs/issues/ISS-NNNN.yaml entry, or a user-reported/self-discovered defect,
│  AND no other workflow is already active for this run?
│     └─► Launch WF-03 (Step 00 once, Steps 0.5-N, Step Final once)
│           WF-03 vs WF-02: if the expected behavior already exists in
│           docs/requirements.yaml → WF-03. If the feature isn't specified yet → WF-02.
│
├─ Test failure or regression detected in an ALREADY-ACTIVE WF-02/03/04/05 run?
│     ├─ Is it the failing step's OWN acceptance criteria?
│     │     └─► Rework the responsible agent within the active run (§5)
│     └─ Is it an incidental finding alongside what the step was checking?
│           └─► File it via docs/agents/protocols/ISSUE_QUEUE.md and forward.
│                 Do NOT extend this run; do NOT launch a nested WF-03.
│
├─ Pre-stage-gate or scheduled full-suite check?
│     └─► Launch WF-04 (Step 00 once, Step Final once; incidental findings forwarded)
│
├─ A running Letflow instance exists and a stage's UAT scenarios are ready?
│     └─► Launch WF-05
│
└─ Does not match any standard workflow?
      └─► Build an ad-hoc workflow (§6). Never skip a standard workflow that DOES
          match — there is no human to ask for permission to skip one (see
          core-directives.md's Humanless Operation section), so if the trigger
          matches WF-01..05, that workflow runs, in full.
```

## 4. Batch cap

A single WF-02 run covers **at most 4 requirements**. Split larger batches into
sequential runs — re-running one requirement due to blast radius from an unrelated
failure in the same batch is more expensive than splitting up front.

## 5. Rework and escalation

**On FAIL** (`rework_count < max_rework`):
1. Increment `rework_count` on the handoff.
2. Append failure details to `task.description`: `"REWORK ITERATION <N>: <issues>"`.
3. Re-route to the same originating agent, status back to `PENDING`.
4. **Change-approach rule:** if the same failure recurs after rework (same error, same
   root cause), the agent receiving rework must change its approach, not repeat the
   identical strategy. On the third attempt, switch strategy before writing any code.

**On `rework_count >= max_rework`:**
1. Set handoff status to `ESCALATED`.
2. Write an escalation record to `handoffs/escalations.yaml` (append-only, same
   convention as `docs/status/requirement_status.yaml`).
3. STOP the workflow — do not attempt further automation on this specific handoff.
4. Since there is no human reviewer, ESCALATED does not mean "wait for a person" — it
   means "the next session picks this up fresh, reads the escalation record, and either
   finds a genuinely different approach or narrows the requirement's scope before
   retrying." Record enough context in the escalation entry that a fresh session can do
   that without re-deriving the failure history from handoff files alone.

**On PARTIAL:** log which criteria passed/failed. If the unmet criteria don't block the
next step, advance with a note. If they do, treat as FAIL.

## 6. Ad-hoc workflow construction

When no standard workflow applies: identify the end state, list the agents whose
capabilities reach it (per `AGENT_SYSTEM.md`'s roster), order by dependency, assign
`ADHOC-<YYYYMMDD>-<NNN>`, document inline in the first handoff's `context` field.
Ad-hoc is never a way to bypass a standard workflow that already matches the trigger.

## 7. Parallel-run coordination — `owned_modules` lock

At Step 00 dispatch, record `owned_modules` (the `lib/`/`priv/`/`web/` paths this run
will write) in the handoff's `context.owned_modules`. Before dispatching Step 00, check
the registry: no other active run may share `owned_modules` with this new run. If
overlap: defer this run (log `DEFER_RUN`), dispatch once the conflicting run reaches
Step Final PASS. After Step Final PASS, release the lock and check the deferred queue.

## 8. Stage gate enforcement

Before routing WF-02 implementation handoffs for Stage N+1, ORCH verifies:
1. All MUST requirements for Stage N have status `done` in `docs/requirements.yaml`.
2. The most recent WF-04 full-suite run for Stage N produced zero BLOCKER issues.
3. `RELEASE-VALIDATOR` produced a PASS for Stage N.
4. `REVIEWER` has appended a dated sign-off section to `docs/migration/stage-N-*.md`
   (this predates the fuller pipeline — it's the existing per-stage convention, now
   also gated by RELEASE-VALIDATOR's own independent check rather than being the only
   check).

If any fails, ORCH blocks the Stage N+1 launch and reports the blocking items — this is
not a "pause for a human" state, it's "route to whichever agent owns the blocking item."

## 9. Log

Append one line per action to `handoffs/orchestrator.log` (append-only, never
overwritten):

```
<ISO8601> | <ACTION> | <WORKFLOW_ID> | <HANDOFF_ID> | <FROM_AGENT> → <TO_AGENT> | <STATUS>
```

`DONE` is only written after Step Final returns PASS with `push_status: ok` (or the
documented `PARTIAL` fallback when `gh` is unavailable — see `GIT_MERGE.md`).

## 10. Sizing rule — when ORCH may act directly

**This section is the canonical definition of the direct-action exception.** Other files
point here; none of them restates the test. Do not re-derive it from "is this trivial?"

ORCH may act directly, without spawning the producer/validator chain, **only when every
one of these is true**:

1. The change touches **exactly one file**.
2. It adds **no new public function, module, or `@spec`**.
3. It adds or modifies **no migration** (`priv/repo/migrations/`).
4. It does **not** touch `lib/letflow/process_instance.ex`, `instance_supervisor.ex`, or
   any other supervision-tree file.
5. It does **not** touch a tenant-data path (see SECURITY-REVIEWER's scope test).
6. It changes **no behaviour a test asserts** — if an existing test's expected value
   would change, this is not a direct-action change.

**Any single "no" means run the full workflow.** This is a checklist, not a judgment
call: the point is that an agent with limited judgement reaches the same verdict as one
with good judgement. Typical qualifying changes: a typo in a docstring or `README.md`, a
one-line config value, a comment.

The asymmetry justifying the strictness: an unnecessary validator pass costs one agent
turn; an unvalidated bug reaching `main` with no human backstop is the exact failure
mode this whole system exists to prevent. When a check is ambiguous, it is a "no."
