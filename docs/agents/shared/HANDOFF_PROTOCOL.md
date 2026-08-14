# Shared Protocol — Handoff Lifecycle

**Audience:** every agent in Letflow's pipeline.
**Status:** AUTHORITATIVE. Where an agent-specific file disagrees with this document on
handoff mechanics, this document wins — report the discrepancy in your handoff
`result.issues` with severity MINOR so it gets fixed at the source.

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

**Legal `result.status` values — no others:**

| Value | Meaning |
|---|---|
| `PASS` | Work complete, acceptance criteria met |
| `FAIL` | Work attempted, acceptance criteria not met |
| `PARTIAL` | Some criteria met; remainder blocked and listed in `issues` |
| `BLOCKED` | Could not start or continue; blocker named in `issues` |
| `SKIPPED` | Step not applicable to this run (state why in `summary`) |

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
4. Update the matching entry's status in handoffs/registry.json
5. Commit handoffs/, and any other files this step produced, to git
   (see core-directives.md's "File Placement Rules" — workflow artefacts are
   committed, not left staged)
```

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
