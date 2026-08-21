# Shared Protocol — Handoff Lifecycle

**Audience:** every agent in Letflow's pipeline.
**Status:** Canonical for handoff *mechanics*. Conflicts with any other document are
resolved by the **Instruction Precedence** chain in
`docs/agents/instructions/core-directives.md` — not by this file claiming to win —
and reported in your handoff `result.issues` at MINOR severity so the drift gets fixed
at the source.

This file exists so the handoff lifecycle is stated exactly once. See
`docs/agents/instructions/core-directives.md` for the broader behavioural rules this
protocol operates inside of (Zero Manual Work, Humanless Operation, Unblock-Everything).

---

## 1. Claim your handoff

At session start, find the handoff addressed to you:

```
handoffs/<RUN-ID>/step-*.json  where  to_agent == "<YOUR_AGENT_ID>"  and  status == "PENDING"
```

```bash
grep -rl '"to_agent": "<YOUR_AGENT_ID>"' handoffs/ | xargs grep -l '"status": "PENDING"' 2>/dev/null
```

Then:
1. Read the file, plus every artefact listed in `context.artifacts_in`.
2. Set `status` to `IN_PROGRESS`.
3. **Do NOT set `started_at` yourself.** ORCH stamps it immediately before dispatching
   you. If you write it, it will read later than your own dispatch time — a corruption
   R-Co's own history shows happens easily if agents "helpfully" fill in every field.

If no PENDING handoff exists for you and none was named directly by the caller: report
that and stop. Do not invent work — check `docs/requirements.yaml` for the next
`pending` requirement instead, per `docs/agents/ORCHESTRATOR.md`.

## 1.1 A handoff's factual premises are checkable, and may be wrong

`core-directives.md`'s **Instruction Precedence** puts your handoff's `task` block at
rank 1. That makes it the highest authority on **what to do**. It says nothing about the
handoff's **factual claims**, and agents have read it as covering both. It does not: a
handoff is a record written by another agent, and `docs/anti-patterns.md`'s "Inheriting
a claim from a record instead of re-deriving it from the source" applies to it exactly
as it applies to any other record.

**The rule.** When a handoff makes a *checkable factual claim* your work depends on — a
file exists, a path follows a convention, a conflict cannot occur, a count is N — verify
it before building on it. **A verified disagreement outranks the handoff:** report it in
`result.issues`, act on what you measured, and state plainly what you did and why.

**This is not licence to disregard the handoff's instructions.** Instruction Precedence
still governs those, and a **safety/gate rule is never overridable** by anything,
including your own measurement. The distinction is between what you are told to **do**
and what you are told **is true**. Silently complying with a false premise and silently
ignoring a correct instruction are both failures.

**Evidence — twice in one run (WF03-ISS0106-20260821) an ORCH handoff asserted a false
premise, and the receiving agent was right to check rather than comply:**

1. Step 4's handoff named the new test file with a **dotted** filename. TEST-DESIGNER
   found the repo's existing mix-task test is **underscored**, deviated, and *reported
   the deviation* instead of silently complying. ORCH verified and confirmed the handoff
   was wrong.
2. Step Final's handoff asserted that an add/add conflict on the renumbered issue files
   **could not occur**, and that if it did it meant a third concurrent session and must
   be escalated. ELIXIR-DEV checked instead of obeying and showed the reasoning was
   false: a rebase replays commits individually, so the intermediate commit that
   *created* those files collides regardless of a later commit renumbering them. It
   confirmed provenance on both sides before proceeding.

---

## 2. Handoff file schema

```json
{
  "handoff_id": "<uuid-v4>",
  "run_id": "<run-id>",
  "workflow_id": "<WF-01|WF-02|WF-03|WF-04|WF-05|ADHOC-nnn>",
  "step": "01",
  "from_agent": "<AGENT_ID>",
  "to_agent": "<AGENT_ID>",
  "file": "handoffs/<run_id>/step-01-agent.json",
  "created_at": "<ISO8601-UTC>",
  "started_at": "<ISO8601-UTC or null>",
  "completed_at": "<ISO8601-UTC or null>",
  "status": "PENDING|IN_PROGRESS|COMPLETED|FAILED|ESCALATED|CANCELLED",
  "priority": "HIGH|NORMAL|LOW",
  "context": {
    "stage": "<S0-S8 or null>",
    "requirement_ids": ["<REQ-ID>", "..."],
    "requirement_text": {
      "<REQ-ID>": "<the requirement's full `description` text, copied verbatim from docs/requirements.yaml>"
    },
    "related_handoff_ids": ["<uuid>", "..."],
    "artifacts_in": ["<relative/path>", "..."],
    "owned_modules": ["lib/letflow/...", "..."]
  },
  "task": {
    "description": "<clear, actionable task for the receiving agent>",
    "acceptance_criteria": ["<measurable criterion>", "..."]
  },
  "result": {
    "status": "PASS|FAIL|PARTIAL|BLOCKED|SKIPPED",
    "summary": "<one paragraph>",
    "artifacts_out": ["<relative/path>", "..."],
    "issues": [
      {"severity": "BLOCKER|MAJOR|MINOR", "description": "<description>", "affected_requirement": "<REQ-ID or null>"}
    ],
    "git_evidence": {
      "branch_name": "<feature/<run_id> or null>",
      "commit_sha_list": ["<sha>"],
      "remote_branch": "<origin/branch or null>",
      "push_status": "ok|failed|skipped",
      "pr_url": "<url or null>",
      "pr_create_error": "<error string or null>"
    },
    "next_action": "<suggested next step for ORCH>"
  },
  "rework_count": 0,
  "max_rework": 3
}
```

**`context.requirement_text` — written by ORCH, read by everyone else.** ORCH copies each
in-scope requirement's full `description` verbatim from `docs/requirements.yaml` into this
map when it creates the handoff. Receiving agents read the requirement *here*, not by
opening the 61k-token `docs/requirements.yaml` — see `core-directives.md`'s "Load Scoped
Context, Not Whole Files." Listing `"docs/requirements.yaml"` in `artifacts_in` is not a
substitute: it tells the receiving agent to read the whole file, which is the exact cost
this field exists to remove. If a handoff reaches you with `requirement_ids` set but
`requirement_text` missing, that is a malformed handoff — read the named entries with a
targeted `awk`/`Select-String` range (never a full read) and report it as a MINOR issue.

**Legal `result.status` values — no others:**

| Value | Meaning |
|---|---|
| `PASS` | Work complete, acceptance criteria met |
| `FAIL` | Work attempted, acceptance criteria not met |
| `PARTIAL` | Some criteria met; remainder blocked and listed in `issues` |
| `BLOCKED` | Could not start or continue; blocker named in `issues` |
| `SKIPPED` | Step not applicable to this run (state why in `summary`) |

### Worked examples — what a finished `result` block looks like

Match these shapes. They are the format contract for every role; the differences between
them are the point.

<example name="validator-fail">
A FAIL names every failed check, by acceptance criterion, with the specific gap — never
a general impression. This is what "route back with the specific gaps named" means:

```json
"result": {
  "status": "FAIL",
  "summary": "3 of 6 acceptance criteria unmet in lib/letflow/design/req039-sandbox-pool.md. AC2 (blocking quota wait) has no design element: the doc names claim/1 but never states what happens when all slots are in use. AC4's error shape is 'returns an error' — not a tagged tuple, so ELIXIR-DEV would have to invent it. Section 6 contains a 14-line Elixir function body (claim/1), which this gate fails on sight per WF-02 Step 1b check 2e.",
  "artifacts_out": [],
  "issues": [
    {"severity": "BLOCKER", "description": "AC2: no design element covers the all-slots-in-use path. Design must state the blocking mechanism and the wait-window timeout value.", "affected_requirement": "REQ-039"},
    {"severity": "BLOCKER", "description": "AC4: error shape unspecified. State the exact tagged tuple, e.g. {:error, :invalid_table_name}.", "affected_requirement": "REQ-039"},
    {"severity": "BLOCKER", "description": "Section 6 lines 88-101 contain an implementation body, not a signature. Design artefacts carry signatures and type shapes only.", "affected_requirement": "REQ-039"}
  ],
  "next_action": "Rework CODE-DESIGNER — 3 BLOCKERs above, rework iteration 1 of 3"
}
```
</example>

<example name="validator-pass">
A PASS states what was independently re-derived and how. "Looks good" is not a PASS;
naming the artefact you opened and the check you ran is:

```json
"result": {
  "status": "PASS",
  "summary": "Read lib/letflow/design/req039-sandbox-pool.md directly (not CODE-DESIGNER's summary). All 6 acceptance criteria map to concrete design elements: AC1→claim/1 signature §3.1, AC2→blocking wait §3.2 with 5000ms window, AC3→release/1 + information_schema verification §3.3, AC4→{:error, :invalid_table_name} §4.1, AC5→TRUNCATE-before-insert §4.2, AC6→verbatim moduledoc text §10. No TBD/deferral language (grepped). No .ex bodies present — §6 carries @spec-style signatures only. Cross-module deps listed §7 (Letflow.TenantProvisioning, Ecto.Migrator).",
  "artifacts_out": [],
  "issues": [],
  "next_action": "Route to ELIXIR-DEV (Step 2a)"
}
```
</example>

<example name="security-reviewer-scoped">
SECURITY-REVIEWER records a verdict per invariant, INV-1..INV-8, with APPLIES or
NOT-APPLICABLE stated for each — an unlisted invariant reads as an unrun check:

```json
"result": {
  "status": "PASS",
  "summary": "Scope test: in scope — diff adds priv/repo/migrations/20260818120000_create_tasks.exs. Verdicts against git diff main...HEAD: INV-1 APPLIES (tenant-scoped table) → PASS, tasks table created with prefix: from Ecto.Migration opts, no GLOBAL exception claimed, matches REQ-022 :prefix mechanism. INV-4 APPLIES (config touched) → PASS, no literal secret added; DB URL still read from System.get_env/1. INV-7 APPLIES → PASS, no string interpolation of tenant/user input into SQL; the one interpolated value (schema_name) is validated against ^sandbox_[0-9a-f]{32}$ before use. INV-8 APPLIES → PASS, no unresolved {:ok,_}= on an external-I/O path. INV-2, INV-3, INV-5, INV-6 NOT-APPLICABLE (S4/S5 surface, no API route or response-shaping code in this diff).",
  "artifacts_out": [],
  "issues": [],
  "next_action": "Route to REVIEWER (Step 2d)"
}
```
</example>

<example name="partial">
PARTIAL is for genuinely met-plus-blocked, never for "mostly passed." Say which criteria
landed and what specifically blocks the rest:

```json
"result": {
  "status": "PARTIAL",
  "summary": "5 of 6 acceptance criteria verified by mix test (42 tests, 0 failures — full output in test/reports/report-20260818-WF02-REQ039.yaml). AC3 could not be verified: it asserts the schema no longer appears in information_schema.schemata after release/1, and the sandboxed Ecto connection cannot observe DDL committed by another connection. Not a code defect — a test-harness limitation. Filed as ISS-0031 with a proposed fix (run this one assertion via a checked-out non-sandboxed connection).",
  "artifacts_out": ["test/reports/report-20260818-WF02-REQ039.yaml", "docs/issues/ISS-0031.yaml"],
  "issues": [
    {"severity": "MAJOR", "description": "AC3 unverifiable under the sandboxed test connection; needs a non-sandboxed connection for the information_schema assertion. See ISS-0031.", "affected_requirement": "REQ-039"}
  ],
  "next_action": "ORCH decision: AC3 blocks 'done' for REQ-039 — route to TEST-DESIGNER for the connection fix, do not advance to Step 5"
}
```
</example>

---

## 3. Timestamps come from the clock, never from memory

```powershell
(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
```
```bash
date -u +"%Y-%m-%dT%H:%M:%SZ"
```

Dropping `.ToUniversalTime()` silently emits local time labelled `Z` — nothing in the
output string reveals the mistake, so always call it explicitly. `completed_at` must
never precede `started_at`.

| Field | Who writes it | When |
|---|---|---|
| `created_at` | ORCH | at handoff creation |
| `started_at` | **ORCH only** | immediately before dispatch |
| `completed_at` | the receiving agent | when it completes the handoff |

---

## 4. Complete the handoff

```
1. Set handoff["status"] = "COMPLETED" (or "FAILED")
2. Fill handoff["result"] per the schema above
3. Set handoff["completed_at"] to the real clock output from step 3
4. Commit handoffs/, and any other files this step produced, to git
   (see core-directives.md's "File Placement Rules" — workflow artefacts are
   committed, not left staged)
```

**Do not write to `handoffs/registry.json` yourself** (updated 2026-08-17,
ISS-0021/GH#78 — step 4 above previously instructed the completing agent to update it
directly, contradicting `ORCHESTRATOR.md`'s "ORCH MUST... maintain
`handoffs/registry.json`", and cost two agents a stop-and-flag decision point across
one run before this was fixed at the source). ORCH updates the matching entry's status
in `registry.json` on your behalf once it receives your completed handoff —
`registry.json` is a single append-only document carrying run-level lock fields
(`owned_modules`, `lock_acquired_at`/`lock_released_at`) only ORCH has the context to
set correctly, and every completing agent writing it directly would be a concurrent-write
hazard across this project's multi-worktree/multi-host setup. Your own handoff file
(steps 1-3 above) is the only file this section asks you to write.

**ORCH: that rule alone does not make your own registry write safe.** It removes the
subagents from the race, not a second ORCH-role session running in the *same* checkout —
which has happened (`ADHOC-20260821-001` / `WF01-TESTPARALLEL-20260821`). The
re-read-before-write, append-only, and single-SHA push rules for that case are in
`ORCHESTRATOR.md` §7.1 and are not restated here.

**Before marking PASS, ask: did I independently verify this, or am I trusting a claim?**
If your role is a validator (see the producer/validator table in `core-directives.md`),
re-derive your verdict from the artefact itself. Reading the producer's own
`result.summary` and echoing it back as PASS is not validation.

---

## 5. The audit trail is append-only

`handoffs/orchestrator.log` and `handoffs/registry.json` record what the pipeline did
and why. They must never shrink. Open the log in append mode; never regenerate it
wholesale. A commit that reduces either file's size is a defect to flag, not a cleanup
to perform.

---

## 6. Never satisfy a gate by editing what it measures

If a gate blocks you, fix the condition it detects. Never make the detector stop
reporting — see `core-directives.md`'s fuller statement of this rule and its rationale.

---

## 7. Workspace hygiene

- Pre-existing unrelated uncommitted changes are expected context, not a blocker.
  Continue, keep your edits scoped to your handoff's targets. Stop only for true file
  overlap on your own targets.
- Commit workflow artefacts (`handoffs/`, `lib/letflow/design/`, `docs/issues/`,
  `docs/status/`) before completing — they are the project's audit trail.
- Scratch files go in `scratch/` (git-ignored). Never in the project root or a tracked
  directory.

---

## Enforcement note

R-Co enforces this protocol mechanically via `tools/lint_handoffs.py` (schema
conformance, timestamp monotonicity, encoding, registry coverage) after a 2026-08-05
pipeline audit found unenforced bookkeeping rules were followed at 0.4-8.6% compliance
despite being written down. Letflow does not have an equivalent linter yet — this is a
known gap, not an oversight. Until one exists, every validator role and ORCH itself must
manually check handoff files for schema/timestamp violations as part of its own gate,
per its role file. Building a `mix letflow.lint_handoffs` task (or a plain script, per
the precedent in `docs/anti-patterns.md`'s Mix-task-discovery-cost finding) is worth
raising as its own requirement once the pipeline has run enough cycles to show whether
Letflow drifts the same way R-Co did.
