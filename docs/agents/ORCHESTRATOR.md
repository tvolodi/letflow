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
- **Commit each handoff file at DISPATCH time, before spawning the receiving agent** —
  unconditional, no size threshold. `HANDOFF_PROTOCOL.md` §1.3 is the canonical statement
  (ISS-0196) and this line does not restate it.
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

**No fallback selection.** If `letflow-queue` is not deployed, unreachable, or
`$QUEUE_AUTH_TOKEN` is unavailable, ORCH MUST NOT pick a requirement itself by reading
`docs/requirements.yaml` — even in a session that believes itself single-host. Report
`no_eligible_task (queue unreachable)` and stop. See `TASK_QUEUE.md`'s Hard Rule section
for why: on 2026-08-19, two concurrent sessions both selected REQ-048 because one was
in (the then-permitted) fallback mode and couldn't see the other's in-flight claim,
producing a fully duplicated WF-02 run that had to be discovered and cancelled
afterward — see `docs/anti-patterns.md`.

When given a specific `REQ-XXX` directly by the user, look it up and route by workflow
(see §3 below), not by a single `owner` field — the fuller pipeline routes a
requirement through multiple roles in sequence, not to one owner. This is not
"fallback selection" (the human already made the choice, not ORCH), so it remains
allowed even when the queue is unreachable — but still attempt `set_lock`/
`register_task` against the queue once reachable, and state plainly that the queue
wasn't consulted for selection. (A directly-named REQ-XXX may still need `set_lock`
called against its queue task, if one exists, before starting — check `TASK_QUEUE.md`
for the recovery-path shape.)

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

**Do not copy the original claim-step instruction into a rework note.** Every first
dispatch tells the receiving agent to claim by setting `status` to `IN_PROGRESS` only,
because `HANDOFF_PROTOCOL.md` §3's table makes `started_at` and `created_at` ORCH's own
fields at that point. A rework note is not a first dispatch — the handoff is already
claimed and has a real `result` on it from the prior attempt. The rework text must say
plainly that the receiving agent flips `status` to `COMPLETED`/`FAILED` as normal on
finishing, exactly as §3's table already requires; it must never repeat "claim by setting
status to IN_PROGRESS only" verbatim, which reads as suspending that normal completion
step. (ISS-0211, `WF03-ISS0210-20260821`: reusing that boilerplate in a rework note left a
handoff's top-level `status` stuck at `IN_PROGRESS` under a correctly attested
`result.status: PASS`, caught only at the next gate and corrected by ORCH directly as a
mechanical field, not by reworking the agent again.)

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

**What this counter is scoped to — it tracks REJECTED work, and only that.** Every rule
above is conditioned on a **FAIL verdict**, i.e. a validator or gate examined the work and
rejected it. A step whose agent **died** reached no verdict at all, so it is not rework:
`rework_count` is **not** incremented when a handoff is re-stamped and redispatched under
`HANDOFF_PROTOCOL.md` §4.1(a-1). This is spelled out because it was not, and an agent
reading step 3 above ("re-route to the same originating agent, status back to `PENDING`")
in isolation could reasonably read a §4.1 redispatch as falling under it. The ruling
itself is older than the rule: `handoffs/WF02-REQ027-20260816/step-02d-reviewer.json`
decided it on 2026-08-16, on the grounds that a `max_rework` budget exists to catch a
producer repeating a mistake and an infrastructure death is not the producer's mistake.

**On PARTIAL:** log which criteria passed/failed. If the unmet criteria don't block the
next step, advance with a note. If they do, treat as FAIL.

## 6. Ad-hoc workflow construction

When no standard workflow applies: identify the end state, list the agents whose
capabilities reach it (per `AGENT_SYSTEM.md`'s roster), order by dependency, assign
`ADHOC-<YYYYMMDD>-<NNN>`, document inline in the first handoff's `context` field.
Ad-hoc is never a way to bypass a standard workflow that already matches the trigger.

**Authoring the `task` block — ad-hoc or standard.** ORCH writes every dispatch under
`HANDOFF_PROTOCOL.md` §2's structure rule ("What goes in `task.description`, and what goes
in `artifacts_in`"). That section is canonical and this line does not restate it.

**Stamping `started_at` — yours, at dispatch, and never delegated to the spawn prompt.**
`HANDOFF_PROTOCOL.md` §1.2 is the canonical procedure (three mechanical steps, plus what
the field means and the ISS-0204 measurement behind it). It is canonical and this line does
not restate it — read it before writing your next dispatch, because the defect it was
written against is a spawn prompt that asks the receiving agent for this field.

## 7. Parallel-run coordination — `owned_modules` lock

At Step 00 dispatch, record `owned_modules` (the `lib/`/`priv/`/`web/` paths this run
will write) in the handoff's `context.owned_modules`. Before dispatching Step 00, check
the registry: no other active run may share `owned_modules` with this new run. If
overlap: defer this run (log `DEFER_RUN`), dispatch once the conflicting run reaches
Step Final PASS. After Step Final PASS, release the lock and check the deferred queue.

### 7.1 Two ORCH-role sessions in the SAME checkout

The `owned_modules` lock above coordinates runs that *share* one registry, and
`HANDOFF_PROTOCOL.md` §4's ORCH-only registry rule was written against
"multi-worktree/multi-host." Both assume the concurrent writers are an ORCH and its own
subagents, or separate checkouts. **Neither covers two ORCH-role sessions running in the
same working tree** — and that is not hypothetical. During `ADHOC-20260821-001`, session
`WF01-TESTPARALLEL-20260821` was live in this same working tree and (a) wrote
`handoffs/registry.json` between that session's read and its write — which surfaced only
because the edit tooling rejected the stale read — and (b) committed on top of that
session's commit and pushed both.

**The ORCH-only rule does not by itself make the write safe. It removes the *subagents*
from the race; it does not remove another ORCH-role session.** So:

- **Re-read `handoffs/registry.json` immediately before writing it, every time.** Append
  after whatever entry is now last. Never overwrite, reorder, or re-serialise another
  session's entry, and re-validate that the file still parses afterwards.
- **The same applies to `handoffs/orchestrator.log`:** append, and never assume the tail
  you last read is still the tail.
- **On push, when another session has unpushed commits on the same branch, push only
  your own:** `git push origin <your-sha>:main`, rather than publishing work that
  session may not consider ready. **If that push is rejected as non-fast-forward,
  re-check before doing anything else** — it may simply mean the other session already
  pushed and your commit is already on the remote, which is exactly what happened in the
  incident above and needed no action at all. **Do not force.**

  This "do not force" governs ONLY this case — ORCH pushing its own registry/log commits
  to `main` from a checkout another ORCH-role session may also be writing. It is a
  different rule from a run republishing its OWN rebased feature branch, which is
  authorized, scoped, and stated in full at `GIT_MERGE.md` step 6 (added 2026-08-21,
  ISS-0210/GH#402) — read it there rather than inferring either rule from the other.

### 7.2 Run-entry fields — `last_known_step`, and recording a recovered run

#### `last_known_step` — what it is

Carried on nearly every run entry in `handoffs/registry.json` and, until 2026-08-21
(ISS-0117), **defined nowhere under `docs/`**. (An exact count was stated here and was
wrong — re-derived 2026-08-21, `grep -c '"last_known_step"' handoffs/registry.json`
returned 62 at the commit that wrote "64". The count grows with every run, so no fixed
figure written into this file stays true; the point the sentence makes does not need one.) It is written here because ISS-0117 asked whether to extend it,
and a field with no written specification cannot be extended — only guessed at, which is
how it accumulated unbounded prose in the first place.

**Definition.** `last_known_step` is ORCH's running answer to *"if this session died right
now, where would the next session pick up?"* — the furthest step of the run whose outcome
ORCH has actually observed, its verdict, and any steps recorded SKIPPED with why. ORCH
updates it as the run advances. It is a **position marker**, not a run history.

**What belongs in it:** the step id and its verdict (`Step 03 COMPLETED PASS`), steps
recorded SKIPPED and the one-clause reason, and the commit sha the step landed on.
**What does not:** narrative about what the run decided or why (that is `note`), and —
from 2026-08-21 — anything about a run being interrupted or recovered, which now has its
own fields below.

#### `recovered` and `recovery_note`

When a run required recovery under `HANDOFF_PROTOCOL.md` §4.1, its registry entry carries
two **discrete** fields alongside the existing ones:

- **`recovered`** — boolean, `true`. Absent or `false` on a clean run.
- **`recovery_note`** — string, naming (i) the affected step **file path**, and (ii)
  which §4.1(a) branch was applied: `(a-1) redispatch` or `(a-2) ORCH reconstruction`.

**Why discrete fields rather than a clause folded into `last_known_step`, which is where
this would naturally have gone.** `WF02-REQ043-20260818`'s interruption *is* already
recorded — as a clause buried inside a ~1,000-character prose `note` — and that run's
`last_known_step` reads as a normal completion. The consequence is measured, not
hypothesised: a scan for this class found that run's **stale `PENDING` handoff** and did
**not** find its interruption, because prose is greppable by nobody. Folding a recovery
marker into a free-text field repeats exactly the failure `HANDOFF_PROTOCOL.md` §4.1(b)
rejects at the handoff level. `grep -l '"recovered": true' handoffs/registry.json` must be
sufficient.

#### Which mechanism: amend the entry, or append a `-resume` entry

Both apply; they are not alternatives, and ISS-0033 settled the second one already.

- **Same-session recovery** (this ORCH session dispatched the step, observed the death,
  and recovered it) — **amend the run's existing entry**, adding `recovered`/`recovery_note`.
  The run never ended; nothing about the entry has been superseded.
- **Later-session recovery** (a subsequent session picks up an interrupted run) —
  **leave the original entry untouched and append a separate entry with a `-resume`
  run_id suffix**, carrying `recovered`/`recovery_note`. This is ISS-0033's established
  precedent, not a new rule: that issue was filed because `WF03-ISS0030-20260817` read
  `BLOCKED` forever, and was resolved as a **false positive** — a second entry,
  `WF03-ISS0030-20260817-resume`, `status: COMPLETED`, had been appended by commit
  `0a34f79`, and the original staying `BLOCKED` was ruled "deliberate, correct
  append-only history (the run really was blocked at that point in time, on that specific
  attempt)."

**Neither mechanism weakens the append-only rule, and this section does not license an
exception to it.** `HANDOFF_PROTOCOL.md` §5 and `core-directives.md`'s "Bookkeeping Is
Not Optional" still hold: adding a field to an entry is not rewriting history, but
**re-serialising, reordering, or overwriting another session's entry still is**, and
§7.1's re-read-`registry.json`-immediately-before-writing rule applies to this write
exactly as to any other. If the entry to be amended is not the last one, or another
session has written since your read, re-read and re-derive before touching it.

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

> **This exception governs review, not git mechanics (clarified 2026-09-05,
> ISS-0467).** Qualifying under all six checks above licenses skipping the
> producer/validator agent chain and the handoff-file machinery for this change
> — it does not license skipping `GIT_SETUP.md`/`GIT_MERGE.md`'s branch-and-PR
> procedure. A direct-action change still gets its own branch, still opens a PR,
> and still merges through `gh pr merge` (or `--admin` per 0018's documented
> override path) exactly like any other change — never a bare `git push origin
> main`. This was previously left to be inferred from this section's silence on
> git mechanics, and in practice an agent inferred the opposite (0018's "A real
> gap found live" section, ISS-0467) — this paragraph closes that specific
> silence; see `GIT_MERGE.md`'s own Precondition section for the corresponding
> prohibition.
