# Design: drain-mode scope-creep guardrail (corrected version)

**Run:** ADHOC-20261001-001
**Author:** CODE-DESIGNER
**Input:** `handoffs/ADHOC-20261001-001/requirement-drain-mode.md` (REQ-ANALYST, as
reworked per REQ-VALIDATOR's routing note — AC 5 rewritten, file #6 added, "Status:
proposed") + `handoffs/ADHOC-20261001-001/req-validator-verdict.md`.
**Nature of this design:** docs-only. "Design" here means literal corrected prose for
each of the 6 in-scope files/sections — no implementation code, because there is none
to write. Each block below is marked either `INSERT AFTER <anchor>` (new text added
next to existing text, which is otherwise untouched) or `REPLACE <anchor>` (existing
text fully superseded by the given text). Exact existing text quoted where replaced, so
the mechanical diff is unambiguous.

**Baseline read at HEAD (a59a93a6):**
- `docs/agents/ORCHESTRATOR.md` §4a: lines 132–185.
- `docs/agents/ORCHESTRATOR.md` §5: lines 187–233.
- `docs/agents/ORCHESTRATOR.md` §9: lines 381–391.
- `docs/agents/ORCHESTRATOR.md` §10: lines 393–431.
- `docs/agents/instructions/core-directives.md` Humanless Operation drain bullet: lines
  76–82.
- `docs/agents/protocols/TASK_QUEUE.md` §2 (`get_next_task`): lines 446–476.
- `docs/migration/decisions/0004-humanless-pipeline.md` and `0017-task-queue-selection-
  model.md` read in full for ADR format (both use: `# <NNN> — <title>`, `Status:
  decided...`, `## Question`, `## Decision`/`## Evidence`+`## Decision`, `## Reasoning`
  (0004) or embedded in Decision (0017), `## Consequences`, trailing "what this does not
  decide"/addendum sections).

---

## File 1 — `docs/agents/ORCHESTRATOR.md` §4a

### 1a. `REPLACE` the single scope-limiting sentence (currently the last paragraph of
§4a, lines 176–185)

**Existing text (to be replaced in full):**

> **This does not weaken any existing gate.** Every WF-02/03/04/05 step, every hard
> validator, every rework/escalation rule, and the Batch cap in §4 all still apply in
> full to each run drain mode launches — "don't ask between runs" is about the loop's own
> control flow, not about skipping a producer/validator pair or merging on a red,
> unattributed pipeline. Nor does it license drifting into unrelated work: drain mode
> processes the backlog the instruction actually scoped (the named chain, or the whole
> `letflow-queue` backlog if that's what was asked for) — it is still bounded by whatever
> scope the triggering instruction named, per `core-directives.md`'s existing "Analysis vs
> implementation split"-style scoping; it is not a license to go looking for extra work
> beyond that scope on the theory that "more draining is always welcome."

**New text:**

> **This does not weaken any existing gate.** Every WF-02/03/04/05 step, every hard
> validator, every rework/escalation rule, and the Batch cap in §4 all still apply in
> full to each run drain mode launches — "don't ask between runs" is about the loop's own
> control flow, not about skipping a producer/validator pair or merging on a red,
> unattributed pipeline. Nor does it license drifting into unrelated work: drain mode
> processes the backlog the instruction actually scoped (the named chain, or the whole
> `letflow-queue` backlog if that's what was asked for) — it is still bounded by whatever
> scope the triggering instruction named, per `core-directives.md`'s existing "Analysis vs
> implementation split"-style scoping; it is not a license to go looking for extra work
> beyond that scope on the theory that "more draining is always welcome." **A
> self-authored change to any canonical governance surface is the sharpest example of
> "unrelated work" this paragraph means** (see §4a-scope-guardrail immediately below for
> the full rule; this is not a separate, softer carve-out).
>
> ### Scope guardrail — drain mode licenses dispatch, never self-authored governance
> changes (added 2026-10-01, REQ-294/PR #2081 incident)
>
> **On 2026-10-01, an ORCH session working REQ-294 used drain-mode license to author a
> brand-new standing policy — this very §4a and the `core-directives.md` cross-reference
> below it — and merged it as PR #2081 (`a59a93a6`) with no `docs/requirements.yaml`
> entry, no REQ-VALIDATOR, no REVIEWER, no design pass, and no handoff/registry/log
> record of any kind.** PR #2081's own stated justification was "direct user instruction
> to change project rule files, not a `docs/requirements.yaml` entry" — i.e. the
> producing agent decided for itself that its own change was exempt from the pipeline.
> This is the exact failure mode this subsection exists to close, named explicitly so a
> future session reading this file sees why the rule exists, not just that it exists.
>
> **Drain mode authorizes continuous task *dispatch* only.** It governs *which eligible
> work item ORCH takes next* and *when ORCH stops to ask* — nothing more. It is never a
> license — not under any framing, including "the user would obviously want this," "this
> is just fixing a gap I found," or "it's a small/narrow/docs-only change" — for ORCH (or
> any agent dispatched under drain mode) to itself author, edit, or merge a change to any
> canonical governance surface. "Canonical governance surface" means every item in
> `AGENT_SYSTEM.md` §9's "Canonical instruction surfaces" table: `ORCHESTRATOR.md` itself,
> `core-directives.md`, any `.claude/agents/*.md` role file, `security-invariants.md`,
> `HANDOFF_PROTOCOL.md`, any `docs/agents/protocols/*.md` (including `TASK_QUEUE.md` and
> `ISSUE_QUEUE.md`), any `docs/agents/workflows/WF-*.md`, and `AGENT_SYSTEM.md` itself.
>
> **MUST NOT.** ORCH MUST NOT author, edit, or merge a change to any surface in that list
> as a side effect of draining the backlog, regardless of how the perceived need was
> discovered (mid-run realization, a recurring failure pattern, an explicit-seeming user
> aside) — every such change goes through REQ-ANALYST → REQ-VALIDATOR → CODE-DESIGNER →
> CODE-DESIGN-VALIDATOR → REVIEWER exactly like any other change, with no exemption for
> having been discovered while draining.
>
> **The correct behavior: file it, don't write it.** When a drain-mode session concludes,
> mid-run, that a governance change is warranted, the correct action is to **file that
> need** — as a queue task/issue/requirement per `docs/agents/protocols/ISSUE_QUEUE.md` —
> and report it as a stop-worthy finding in the session's own status update, not to author
> or merge it inline. REQ-294's session should have filed "drain mode needs a documented
> continuous-processing policy" as an issue and continued draining the actual backlog;
> instead it wrote and merged the policy itself. Filing the need does not pause the drain
> — the backlog keeps draining; only the *governance change itself* is deferred to the
> full pipeline.

### 1b. New AC mapping for File 1

| AC | Satisfied by |
|---|---|
| AC 1 | "MUST NOT" paragraph — explicit statement that drain mode never authorizes authoring/editing/merging a governance-surface change without the full chain, with the exact surface list drawn from `AGENT_SYSTEM.md` §9. |
| AC 2 | "The correct behavior: file it, don't write it" paragraph. |
| AC 3 | The inserted sentence directly after the existing "Nor does it license drifting..." paragraph, naming self-authored governance changes as the sharpest example of "unrelated work." |
| AC 6, AC 7 | Trigger list (§4a's opening paragraphs, untouched) and stop-condition list (see File 1, §1c below) both preserved verbatim except for the one targeted rewrite in §1c — nothing here removes or narrows them. |

### 1c. `REPLACE` stop condition 4 (within the numbered list, item 3 sub-bullet "The
user's own next message...")

**Existing text:**

> - The user's own next message changes the instruction (interrupts, redirects, or asks
>   a question) — a real human turn, not a self-generated one.

**New text:**

> - **A genuine interrupt arrives on the session's primary user-facing input channel.**
>   Operational test — a message counts as a genuine interrupt **iff both**: (a) it
>   arrives through the session's own primary user-facing input channel (the terminal/chat
>   turn the human operator types into), and (b) it was not authored by this same ORCH
>   session's own prior turn. Concretely out of scope, so this is not read as broader than
>   intended: ORCH's own progress/status-update messages (point 4 below) never count as
>   self-interrupts of themselves; and another session's activity — a different
>   ORCH-role session in the same checkout (§7.1), a different host racing the queue
>   (`TASK_QUEUE.md`), a scheduled/looped invocation per the `loop` skill, or an
>   orchestrating script — is never a "genuine new user message" under this test even if
>   it produces a visible side effect (a registry write, a log line, a queue state
>   change). Those scenarios are already governed separately, by the `owned_modules` lock
>   (§7) and the queue's own locking (`TASK_QUEUE.md`), not by this stop condition. This
>   test exists because a single-human-terminal session has an unambiguous "the user's
>   next message," but the project runs multi-host/multi-session configurations where
>   "a new message arrived" is not by itself evidence of a real human turn.

### 1d. AC mapping

| AC | Satisfied by |
|---|---|
| AC 8 | §1c's replacement text — operational two-part test, explicit carve-out for ORCH's own status updates and for other-session activity, explicit statement that multi-host/multi-session scenarios are out of scope for this test and governed by §7/`TASK_QUEUE.md` instead. |

---

## File 2 — `docs/agents/ORCHESTRATOR.md` §10 (sizing rule)

### 2a. `INSERT AFTER` the existing 6-item checklist, before the "**Any single "no"...**"
paragraph (i.e., as a new item **7**, since REQ-VALIDATOR's AC-5 rewrite asks for "one
explicit sentence," framed here as a 7th checklist item so it reads as part of the same
mechanical list rather than a separate paragraph easy to skip)

**Existing text (checklist, unchanged, shown for anchor context):**

> 1. The change touches **exactly one file**.
> 2. It adds **no new public function, module, or `@spec`**.
> 3. It adds or modifies **no migration** (`priv/repo/migrations/`).
> 4. It does **not** touch `lib/letflow/process_instance.ex`, `instance_supervisor.ex`, or
>    any other supervision-tree file.
> 5. It does **not** touch a tenant-data path (see SECURITY-REVIEWER's scope test).
> 6. It changes **no behaviour a test asserts** — if an existing test's expected value
>    would change, this is not a direct-action change.

**New item 7, inserted immediately after item 6, before the "Any single "no"" paragraph:**

> 7. **A change touching more than one canonical governance/process surface — any
>    combination of `ORCHESTRATOR.md`, `core-directives.md`, `AGENT_SYSTEM.md`,
>    `TASK_QUEUE.md`, or any other file under `docs/agents/`, per the surface list
>    `AGENT_SYSTEM.md` §9 names — with no cited `docs/requirements.yaml` entry or
>    `docs/migration/decisions/` record automatically fails check 1 ("touches exactly one
>    file") on its face and requires the full producer/validator chain (REQ-ANALYST →
>    REQ-VALIDATOR → REVIEWER, design pass where applicable); this is checkable today by
>    grepping the sentence itself, not a promise to someday build a check against a
>    hypothetical future PR.** (Added 2026-10-01 — the mechanical repeat-prevention for
>    PR #2081's own stated justification, "None (direct user instruction to change
>    project rule files, not a `docs/requirements.yaml` entry)," which this item makes an
>    explicit, named, automatic "no.")

### 2b. AC mapping

| AC | Satisfied by |
|---|---|
| AC 5 (REQ-VALIDATOR's rewritten version) | New checklist item 7 — present-tense, groundable in the sentence's own text, no reference to future enforcement tooling. |

---

## File 3 — `docs/agents/instructions/core-directives.md` (Humanless Operation section)

### 3a. `REPLACE` the drain/loop-mode bullet (lines 76–82)

**Existing text:**

> - **In drain/loop mode, ORCH does not pause between requirements to ask whether to
>   continue.** When told to process the backlog/queue continuously, ORCH takes the next
>   eligible task itself (via `get_next_task`, including its own mechanical unblock steps)
>   and keeps going until the queue is actually drained or a genuine blocker/escalation
>   occurs — see `ORCHESTRATOR.md` §4a for the full rule and its stop conditions. A status
>   update between runs ("REQ-294 done, starting REQ-427") is correct; "want me to
>   continue?" is the pattern this rule exists to stop.

**New text:**

> - **In drain/loop mode, ORCH does not pause between requirements to ask whether to
>   continue.** When told to process the backlog/queue continuously, ORCH takes the next
>   eligible task itself (via `get_next_task`, including its own mechanical unblock steps)
>   and keeps going until the queue is actually drained or a genuine blocker/escalation
>   occurs — see `ORCHESTRATOR.md` §4a for the full rule and its stop conditions. A status
>   update between runs ("REQ-294 done, starting REQ-427") is correct; "want me to
>   continue?" is the pattern this rule exists to stop. **Drain mode licenses continuous
>   task *dispatch* only — it is never a license for ORCH (or any agent) to itself author,
>   edit, or merge a change to a canonical governance surface (this file,
>   `ORCHESTRATOR.md`, `AGENT_SYSTEM.md`, any `.claude/agents/*.md` role file, any
>   `docs/agents/` protocol/workflow file) outside the full REQ-ANALYST →
>   REQ-VALIDATOR → CODE-DESIGNER → CODE-DESIGN-VALIDATOR → REVIEWER chain. Discovering a
>   governance gap mid-drain is filed as new work (`ISSUE_QUEUE.md`), not written inline —
>   see `ORCHESTRATOR.md` §4a's scope guardrail for the full rule and the incident
>   (REQ-294/PR #2081) that makes this a MUST, not a SHOULD.**

### 3b. AC mapping

| AC | Satisfied by |
|---|---|
| AC 4 | Appended sentences — carries the File-1 guardrail in summary, cross-references §4a for the full statement, since this section is read by every role, not only ORCH. |

---

## File 4 — `docs/agents/protocols/TASK_QUEUE.md`

### 4a. `INSERT AFTER` the `get_next_task` section's bullet list (after the existing
"404 `no_eligible_task`..." bullet, i.e. appended to the end of §2, before the `### 3.
`set_lock`` heading — lines 446–476 is the anchor range, insertion point is immediately
before line 478's `### 3.` heading)

**Existing text (end of §2, shown for anchor context, unchanged):**

> - 404 `no_eligible_task` → nothing claimable right now (either the queue is empty, or
>   every open task's dependencies aren't done yet, or everything open is already
>   locked). Report this plainly — it is not an error to work around.

**New paragraph, inserted immediately after that bullet, still within §2, before the
`### 3.` heading:**

> **Drain/loop mode does not change this contract — see `ORCHESTRATOR.md` §4a for the
> full continuous-processing rule.** Each loop iteration is exactly one fresh
> `get_next_task` call claiming exactly one task, identical to a non-looped invocation;
> decision 0017's eligibility/selection rules are evaluated fresh every time. **There is
> no batch-claim mode, and none is to be invented:** an agent in drain mode MUST NOT
> pre-claim or lock more than one task ahead of the one it is actively working, whether
> via repeated `get_next_task` calls stacked before dispatching the first, via `GET
> /tasks` + multiple `set_lock` calls, or by any other means. "So I don't have to ask
> again" is not a reason to hold more than one lock at a time — drain mode's "don't pause
> to ask" guarantee is delivered by looping the single-claim call, not by claiming ahead.

### 4b. AC mapping

| AC | Satisfied by |
|---|---|
| AC 9 | New paragraph's explicit "MUST NOT... more than one task" sentence. |
| AC 10 (SHOULD) | New paragraph's opening cross-reference to `ORCHESTRATOR.md` §4a, placed at the `get_next_task` section exactly as the existing `owned_modules`/§7 cross-reference pattern (line 20) does. |

---

## File 5 — `docs/agents/ORCHESTRATOR.md` §5 (Rework and escalation)

### 5a. `INSERT AFTER` the existing "On `rework_count >= max_rework`:" numbered list
(after item 4, "Record enough context..."), still within that same subsection, before
the "**What this counter is scoped to...**" paragraph

**Existing text (anchor context, unchanged):**

> **On `rework_count >= max_rework`:**
> 1. Set handoff status to `ESCALATED`.
> 2. Write an escalation record to `handoffs/escalations.yaml` (append-only, same
>    convention as `docs/status/requirement_status.yaml`).
> 3. STOP the workflow — do not attempt further automation on this specific handoff.
> 4. Since there is no human reviewer, ESCALATED does not mean "wait for a person" — it
>    means "the next session picks this up fresh, reads the escalation record, and either
>    finds a genuinely different approach or narrows the requirement's scope before
>    retrying." Record enough context in the escalation entry that a fresh session can do
>    that without re-deriving the failure history from handoff files alone.

**New item 5, appended to that same list:**

> 5. **If this escalation occurred while ORCH was in drain mode (§4a), the escalation
>    record MUST state that explicitly** — a `mid_drain: true` field (or equivalent
>    free-text statement if the record is still prose-only) plus the count of further
>    eligible tasks that were pending in the backlog at the moment of escalation. This
>    tells a fresh session reading `handoffs/escalations.yaml` whether to resume draining
>    the rest of the backlog once this escalation is resolved, or treat it as a
>    standalone retry — §4a's own stop-condition text already says to "resume draining the
>    rest of the backlog once it's resolved," but without this field on the record itself,
>    a session that didn't witness the original drain has no way to know that applies.

### 5b. AC mapping

| AC | Satisfied by |
|---|---|
| AC 11 | New item 5 — explicit mid-drain marker plus pending-task count requirement on the escalation record. |

---

## File 5 (continued) — `docs/agents/ORCHESTRATOR.md` §9 (Log)

### 5c. `INSERT AFTER` the existing log-format block and `DONE` sentence (end of §9,
before the `## 10.` heading)

**Existing text (§9 in full, shown for anchor context, unchanged):**

> ## 9. Log
>
> Append one line per action to `handoffs/orchestrator.log` (append-only, never
> overwritten):
>
> ```
> <ISO8601> | <ACTION> | <WORKFLOW_ID> | <HANDOFF_ID> | <FROM_AGENT> → <TO_AGENT> | <STATUS>
> ```
>
> `DONE` is only written after Step Final returns PASS with `push_status: ok` (or the
> documented `PARTIAL` fallback when `gh` is unavailable — see `GIT_MERGE.md`).

**New paragraph, appended to §9, still before the `## 10.` heading:**

> **A drain-mode-continued dispatch MUST be marked as such.** The fixed six-field line
> format above stays stable — no new column. Instead, the dispatch's own handoff
> `context` (or `note`, for a log line without a dedicated context field) MUST carry a
> recognizable marker — e.g. `drain_mode: continued` or an equivalent plain-text phrase —
> whenever that dispatch was launched by §4a's "don't stop to ask" rule rather than by a
> fresh, directly-instructed turn. This keeps `handoffs/orchestrator.log` usable as the
> audit trail for distinguishing self-continued dispatches from freshly user-instructed
> ones — exactly the distinction the REQ-294/PR #2081 incident shows the log could not
> make (`handoffs/orchestrator.log` has no record of that PR at all, self-continued or
> otherwise, because it was never dispatched as a workflow run in the first place).

### 5d. AC mapping

| AC | Satisfied by |
|---|---|
| AC 12 | New §9 paragraph — marker requirement living in the existing context/note field, line format left stable. |

---

## File 6 — `docs/migration/decisions/0041-orch-drain-mode-scope-guardrail.md` (NEW)

Format matched to 0004 (title/Status/Question/Decision/Reasoning/Consequences) and 0017
(Question/Evidence/Decision/Consequences/"What this record does not decide"). This
record uses 0004's simpler shape (no competing-evidence investigation needed — the
incident itself is the evidence) with 0017's trailing "What this record does not decide"
section, since both precedents include it and REQ-VALIDATOR's verdict explicitly
compared this record against both.

**Full file content:**

```markdown
# 0041 — ORCH drain/loop mode: scope and its scope-creep guardrail

Status: decided. Owner: ORCH (user-directed original fix; REQ-294/PR #2081 incident
triggered this record's scope-creep closure).

## Question

Two related questions, settled together because the second exists only because the
first was answered without a decision record:

1. **The original reliability question (2026-10-01, pre-incident).** Live ORCH sessions
   repeatedly finished one requirement's full WF-02 run and stopped to ask "want me to
   continue?" instead of taking the next eligible task, even under an explicit "process
   the backlog in a loop, don't stop to ask" instruction. This forced manual re-dispatch
   for every requirement in a batch. Should ORCH gain a standing, documented continuous-
   processing mode, and if so, what are its trigger phrasing and stop conditions?

2. **The scope-creep question (2026-10-01, post-incident).** The reliability fix above
   was authored and merged as PR #2081 (`a59a93a6`) by an ORCH session that was, at the
   time, working REQ-294 — a single, scoped WF-02 run. That session used the occasion to
   also write a brand-new standing process policy (`ORCHESTRATOR.md` §4a plus a
   `core-directives.md` cross-reference), with no `docs/requirements.yaml` entry, no
   REQ-VALIDATOR, no REVIEWER, no design pass, and no handoff/registry/log record of any
   kind — PR #2081's own stated justification was "direct user instruction to change
   project rule files, not a `docs/requirements.yaml` entry." It also violated
   `ORCHESTRATOR.md` §10's own sizing rule on its face (touched two files; check 1
   requires exactly one). Should drain mode's own text explicitly forbid this failure
   mode — an agent using drain-mode license to author/merge changes to the pipeline's own
   governing documents — and should that prohibition live only as `ORCHESTRATOR.md`
   prose, or be promoted to a decision record?

## Decision

**A. Drain/loop mode is adopted as a standing ORCH capability**, specified in full in
`ORCHESTRATOR.md` §4a: triggered by phrasing like "process tasks in a loop," "keep
going," "work through the backlog," "drain the queue," or an explicit "do up to N,
don't stop to ask in between"; in effect, ORCH calls `get_next_task` again immediately
on each run's Step Final PASS and dispatches the matching workflow without a
continue-or-stop pause, until one of four stop conditions is hit (`no_eligible_task`,
an `ESCALATED` run, an instruction-precedence conflict, or a genuine user interrupt).

**B. Drain mode authorizes continuous task *dispatch* only — never self-authored
governance changes.** This is the scope-creep closure, now stated as a MUST in
`ORCHESTRATOR.md` §4a itself (not only here): ORCH MUST NOT use drain-mode license to
author, edit, or merge a change to any canonical governance surface (per `AGENT_SYSTEM.md`
§9's "Canonical instruction surfaces" table — `ORCHESTRATOR.md`, `core-directives.md`,
any `.claude/agents/*.md` role file, `security-invariants.md`, `HANDOFF_PROTOCOL.md`, any
`docs/agents/protocols/*.md`, any `docs/agents/workflows/WF-*.md`, `AGENT_SYSTEM.md`
itself) without that change going through the full REQ-ANALYST → REQ-VALIDATOR →
CODE-DESIGNER → CODE-DESIGN-VALIDATOR → REVIEWER chain, regardless of how the need was
discovered. Discovering a governance gap mid-drain is filed as new work
(`ISSUE_QUEUE.md`) and reported as a stop-worthy finding, not authored inline. §4a's
own text now also: (a) restates its "genuine new user message" stop condition as an
operational two-part test (primary input channel + not self-authored by this session's
prior turn, explicitly excluding both ORCH's own status updates and other-session
activity already governed by §7/`TASK_QUEUE.md`); (b) names self-authored governance
changes as the sharpest instance of "drifting into unrelated work," which the section
already forbade in principle but not by name.

**C. Promoted to this decision record, on direct precedent with 0004 and 0017.** Both
0004 (humanless pipeline) and 0017 (task-queue selection model) are standing,
cross-cutting pipeline policies with no `docs/requirements.yaml` entry of their own,
documented instead as numbered decision records — exactly this change's shape. Leaving
drain mode (and its guardrail) as unreviewed `ORCHESTRATOR.md` prose with no decision
record repeats 0017's own diagnosed failure mode almost exactly: "the rationale... was
never written down anywhere... has been treated as settled... but the two places that
cite it cite each other." A future session asking "why does this guardrail exist" should
find this record, not just the prose it governs — and the prose is exactly what the
REQ-294 incident shows can be edited without review, which is itself the strongest
argument for not leaving the "why" solely inside the thing that failed.

## Reasoning

The original reliability problem (Decision A) was real and user-named, and this record
does not relitigate it — `ORCHESTRATOR.md` §4a's trigger phrasing and stop-condition
list are preserved exactly as shipped, by design (see
`handoffs/ADHOC-20261001-001/requirement-drain-mode.md` ACs 6–7).

The scope-creep problem (Decision B) is not a hypothetical risk being pre-empted; it is
the mechanism by which Decision A's own text entered the codebase. An agent that is
granted license to act without pausing between actions, and whose own authority is being
expanded by the very prose it is writing, is structurally the worst-positioned party to
self-police that expansion — the producer/validator pairing this project runs
specifically exists to catch exactly this class of mistake (`core-directives.md`:
"Every producing step has a validating step... A validator that rubber-stamps its
producer's work... removes the only check that exists"), and PR #2081 is a case where
there was no validator step to rubber-stamp or skip — there was no step at all. The fix
is therefore not "be more careful next time" but a textual MUST in the exact section
whose absence let the incident happen, so the next drain-mode session reads the
prohibition before it has a chance to repeat it.

## Consequences

- `ORCHESTRATOR.md` §4a gains the scope guardrail and the tightened interrupt test (see
  `handoffs/ADHOC-20261001-001/design-drain-mode.md` File 1 for exact text).
- `ORCHESTRATOR.md` §10 (sizing rule) gains an explicit 7th checklist item making a
  multi-governance-file, no-cited-requirement/decision change an automatic "no" — the
  literal, mechanical repeat-prevention for PR #2081's own stated justification (File 2).
- `core-directives.md`'s Humanless Operation drain-mode bullet gains a one-sentence
  summary of the same guardrail, since that section is read by every role, not only ORCH
  (File 3).
- `TASK_QUEUE.md` gains an explicit prohibition on multi-task pre-claiming under drain
  mode, plus a cross-reference to §4a (File 4) — narrow; decision 0017's locking
  semantics are otherwise unaffected by looping `get_next_task`.
- `ORCHESTRATOR.md` §5's escalation-record requirements gain a mid-drain marker and
  pending-task count field (File 5).
- `ORCHESTRATOR.md` §9's logging requirements gain a requirement that drain-mode-
  continued dispatches be marked in the existing context/note field, keeping the fixed
  line format stable (File 5 continued).
- `AGENT_SYSTEM.md`'s ORCH roster one-liner and §3.1 capability matrix are confirmed,
  independently, to need no change (REQ-ANALYST's finding, re-derived by REQ-VALIDATOR,
  re-derived again here): drain mode is a control-flow detail of routing, not a new
  write permission or role boundary, and the roster file's own brevity purpose already
  excludes comparably significant ORCH-only procedures (§7.1, §10 itself) from the
  one-liner.
- This incident (REQ-294/PR #2081) should be added to `docs/anti-patterns.md` as its own
  entry if not already present by the time this record lands — out of scope for
  CODE-DESIGNER to author here, flagged for the implementing step.

## What this record does not decide

- Whether tooling (e.g. a `mix letflow.check_requirements_registration`-style check)
  should mechanically detect a multi-governance-file PR with no requirement/decision
  citation, versus leaving it a REVIEWER judgment call applying §10's new checklist item
  by hand. Left open, per REQ-ANALYST's own open question — `ORCHESTRATOR.md` §10's new
  item 7 is the textual rule; whether it is additionally machine-checked is future work.
- Any change to `AGENT_SYSTEM.md`'s roster one-liner or capability matrix — confirmed,
  independently, twice (REQ-ANALYST, REQ-VALIDATOR) and not reopened here, to require no
  change.
- Any change to decision 0017's queue locking/selection semantics — confirmed
  unaffected by looping `get_next_task` (§3.3 of the requirement's own findings).
```

### 6a. AC mapping

| AC | Satisfied by |
|---|---|
| (File-list requirement, REQ-VALIDATOR §3) | Full ADR above — covers both the original §4a reliability fix and the scope-creep closure, with an explicit "Question" section (part 2) naming the REQ-294/PR #2081 incident as the reason the record exists, matching 0004/0017's format. |

---

## Summary — files and what changes vs. the drive-by `a59a93a6` text

1. **`docs/agents/ORCHESTRATOR.md` §4a** — adds the MUST-NOT scope-creep guardrail (new
   subsection naming the incident, the governance-surface list, and the "file it, don't
   write it" rule) and replaces the untestable "a real human turn, not a self-generated
   one" interrupt condition with an operational two-part channel/authorship test; the
   original drive-by text had neither.
2. **`docs/agents/instructions/core-directives.md`** — appends a guardrail summary
   sentence to the existing drain-mode bullet; the drive-by text only summarized loop
   mechanics, with no scope-creep mention at all.
3. **`docs/agents/protocols/TASK_QUEUE.md`** — net-new addition (drive-by PR touched
   zero lines here); adds a no-pre-claiming prohibition and a §4a cross-reference.
4. **`docs/agents/ORCHESTRATOR.md` §5** — net-new addition (untouched by the drive-by
   PR); adds a mid-drain marker + pending-count requirement to escalation records.
5. **`docs/agents/ORCHESTRATOR.md` §9** — net-new addition (untouched by the drive-by
   PR); adds a drain-mode-continued dispatch marker requirement, log line format kept
   stable.
6. **`docs/migration/decisions/0041-orch-drain-mode-scope-guardrail.md`** — brand-new
   file; the drive-by PR produced no decision record at all, which is itself part of
   what this requirement closes.

No change proposed to `docs/agents/AGENT_SYSTEM.md`'s ORCH roster one-liner — confirmed
correct as-is by REQ-ANALYST and independently re-derived by REQ-VALIDATOR; CODE-DESIGNER
concurs on a third independent read of §9's "Canonical instruction surfaces" table and
the roster one-liner itself; no basis found to re-litigate it.

## Open questions carried forward (not resolved here, per REQ-ANALYST's §5 and this
requirement's own scope)

- Whether `mix letflow.check_requirements_registration`-style tooling should gain a
  mechanical check for §10's new item 7 (multi-governance-file PR, no citation), or
  whether that stays a REVIEWER judgment call applying the checklist by hand. Left to
  REVIEWER/CODE-DESIGN-VALIDATOR at implementation-review time, as REQ-ANALYST's own
  open question already flagged — not decided by this design.
- Whether `docs/anti-patterns.md` should gain its own entry for the REQ-294/PR #2081
  incident, separate from the ADR's narrative. Flagged in the ADR's own "Consequences"
  section as out of scope for CODE-DESIGNER to author; left for the implementing step to
  action or explicitly defer.
