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
  "max_rework": 3,
  "not_agent_attested": {
    "reconstructed_by": "<AGENT_ID, normally ORCH>",
    "reconstructed_at": "<ISO8601-UTC, from the clock at reconstruction time>",
    "reason": "<what happened to the acting agent, and why it could not report>",
    "fields_written": ["status", "completed_at", "result"],
    "evidence": ["<command run> -> <what it established>", "..."],
    "not_verifiable_after_the_fact": ["<what the probes could not settle>", "..."]
  }
}
```

**`not_agent_attested` is the one OPTIONAL field in the block above; every other field is
always present.** It appears ONLY on a handoff *reconstructed* under §4.1(a-2). A
§4.1(a-1) **redispatch does NOT carry it** — the replacement agent did the work it
reports, so its `result` is a genuine first-hand attestation and nothing was
reconstructed. Read "recovered under §4.1" as (a-2) only; stamping this field onto a
redispatched agent's own report asserts the opposite of the truth. Its ABSENCE carries
meaning, date-scoped: see §4.1(b) for exactly what absence asserts and from when, and
§4.1 for who may write the field.

It is shown inside the block rather than as a `//` comment on purpose. **The block above
is valid, machine-parseable JSON and must stay that way** — the placeholders are all
inside double-quoted strings, so `json.loads` on the fence's contents succeeds, which is
what lets a linter (see the Enforcement note) load this schema instead of re-implementing
it. JSON has no comments; anything explanatory about a field goes in prose here, never
inside the fence.

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

| Field | Who writes it | When | Exception |
|---|---|---|---|
| `created_at` | ORCH | at handoff creation | — |
| `started_at` | **ORCH only** | immediately before dispatch | — |
| `completed_at` | the receiving agent | when it completes the handoff | §4.1 |
| `status` | the receiving agent, from `PENDING`→`IN_PROGRESS` (§1) →`COMPLETED`/`FAILED` (§4). ORCH sets the initial `PENDING`, and sets `ESCALATED`/`CANCELLED` per `ORCHESTRATOR.md` §5 | on claiming and on completing | §4.1 |
| `result` | **the receiving agent, and only the receiving agent** — it is that agent's own attested first-hand report of what it did | when it completes the handoff | §4.1 |
| `task` (including `description` and `acceptance_criteria`) | **ORCH only** — it is the dispatch itself, and the receiving agent **never** modifies it | at handoff creation | — |

**Why the `status` and `result` rows exist, given they look like they are stating the obvious.** They
were added 2026-08-21 (ISS-0117) because they were *not* written down, and the omission
cost more than the rule would have. Until then this table bound only the three timestamp
fields, so "a handoff's `result` is the acting agent's own attested report" — the single
assumption the entire producer/validator gate model rests on — existed nowhere as a rule.
An unwritten rule has no exception clause, so each run that hit a bookkeeping case the
table did not cover improvised its own repair, in a non-schema top-level key invented on
the spot. **Re-derived 2026-08-21** by `json.load`-ing every file under `handoffs/` other
than `registry.json` (550 files, 0 unparseable), subtracting §2's own 17 schema keys, **and
then keeping only the keys that record an out-of-band repair or correction — in practice
the `orch_*`-prefixed ones.** That last filter is not optional: the subtraction alone
returns **26** occurrences in **13** files, because it also catches a `next_action`
misplaced at top level in six files, one stray `gate_history`, and 15 keys across the two
`step-00-git-setup` files that sit on a foreign flat schema. Those are separate faults, not
ad-hoc repair markers, and an agent who re-derives without the filter gets 26 and concludes
this table is wrong.

| Key name | Run | `completed_at` | Shape | Position |
|---|---|---|---|---|
| `orch_timestamp_correction` | `WF02-REQ023-20260816` | 2026-08-16T18:49:40Z | string | 18th/18 |
| `orch_restart_note` | `WF02-REQ027-20260816` | 2026-08-16T21:35:39Z | string | 18th/18 |
| `orch_timestamp_correction` | `WF02-REQ037-20260817` | 2026-08-17T19:45:30Z | string | 11th/18 |
| `orch_reconstruction` | `WF03-ISS0109-20260821` | 2026-08-21T03:29:36Z | object | 18th/18 |

**Four** occurrences, in **four** files, in **four** runs, under **three** names, at
**two** key positions, in **two** shapes. Two of the four were written because the acting
agent stopped existing (`WF02-REQ027`, an infrastructure session limit; `WF03-ISS0109`,
an API error); the other two correct a timestamp, which is an adjacent case this table
also failed to cover. §4.1 is the exception clause those runs were missing.

*The table records the key names **as improvised**. The last row's `orch_reconstruction`
has since been renamed to `not_agent_attested` under §4.1(b)'s single authorised backfill
(2026-08-21, `WF03-ISS0117-20260821`); the other three files are untouched and stay that
way, per §4.1(b)'s no-backfill rule.*

**And the `completed_at` exception pointer is not decorative.** The best-executed repair
so far still violated this table silently:
`handoffs/WF03-ISS0109-20260821/step-final-git-merge.json` carries
`completed_at: "2026-08-21T03:29:36Z"`, byte-identical to its own
`reconstructed_at` (in the key then named `orch_reconstruction`) — i.e. ORCH's clock read, written into a field
this table assigns to "the receiving agent" — and the marker object it added did not
declare that it had done so. The rule was already in force; nothing flagged the breach,
because the marker had no required field obliging the writer to enumerate what it wrote.
That is why §4.1's `fields_written` is mandatory.

**And the `task` row has no exception, because that field was damaged the same way — one
row further along.** A receiving agent that believes its `task` block is wrong, stale or
impossible says so in `result.issues` (per §1.1) and leaves the block alone; ORCH is the
only role that can re-dispatch. During `WF03-ISS0117-20260821` a completing agent replaced
ORCH's **6,290**-character dispatched `task.description` with a **156**-character pointer to
"the PENDING copy of this handoff" — a copy that does not exist, since it is the same file.
Because the file was untracked until that same commit, the dispatched text existed in no git
object and survived only in ORCH's own context, from which it was restored verbatim. The
step's verdict and evidence were unaffected; what was nearly lost was the record of what had
been asked.

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

## 4.1 When the acting agent stopped existing

**This section is the exception to §4 and to §3's `completed_at`/`status`/`result` rows,
and it is the only one.** §4 assumes the agent that did the work is still alive to report
it. Agents in this pipeline die: on an API error mid-response, on an infrastructure
session limit, on a host power outage. **Four such deaths — each of a *dispatched agent
holding an open handoff*, which is this section's class — are on record, in four runs**,
between 2026-08-16 and 2026-08-21, essentially the whole recorded life of the pipeline, and
they drew only **three** different treatments:

| Run | How it died | What was done |
|---|---|---|
| `WF02-REQ027-20260816` | infrastructure session limit, mid-work | redispatched to a fresh REVIEWER |
| `WF02-REQ038-20260817` | connection error, mid-work, zero commits | redispatched to a fresh CODE-DESIGN-VALIDATOR |
| `WF02-REQ043-20260818` | host power outage, mid-rebase | nothing — still `PENDING` on disk today (ISS-0192) |
| `WF03-ISS0109-20260821` | API error, after the merge had landed | ORCH reconstructed the `result` |

Four incidents, three different treatments, one of which was no treatment at all. That
is a recurring class handled ad hoc, so it gets a rule rather than a convention.
Re-derived 2026-08-21 from `handoffs/registry.json`, `handoffs/orchestrator.log` and the
handoff files themselves.

**A boundary fact about this table that a re-derivation will hit.** `WF02-REQ038`'s death is
recorded *only* in `registry.json`'s run note: the dispatch committed nothing, so it left no
handoff file and no `orchestrator.log` line of its own, and a sweep of the handoff files
alone cannot see it.

**The membership test — apply this, not the class name.** An incident is in this section's class when **both** clauses hold, and out when **either**
fails:

1. **A dispatch had been issued** — evidenced by a handoff file addressed to the agent, or by
   an `orchestrator.log` `DISPATCH` line naming it.
2. **The dispatched agent had begun work** — evidenced by an artefact or record *about that
   agent*: a handoff file it wrote or stamped, a commit it authored, an `orchestrator.log`
   line reporting its own progress or verdict, or an explicit statement in `registry.json`
   that it died **mid-work** (or after completing its side effects). ORCH's own `DISPATCH`
   line is evidence of clause 1 and **never** of clause 2.

Clause 2 is the one that does the work, and it is deliberately satisfiable by prose: as
`WF02-REQ038` proves, an agent can die mid-work having produced no file and no commit, so a
test that demanded a file-shaped artefact would exclude a row already in the table. What
clause 2 rejects is a dispatch that was *issued and never taken up* — nothing was left for a
second party to complete, which is the whole subject of §4.1. ORCH's own session dying
*between* dispatches fails both clauses.

**Decide by the test, never by the treatment.** Two incidents can draw the identical
redispatch response and still fall on opposite sides, because redispatch is also what an
unstarted dispatch gets. Re-verified 2026-08-21, all four rows above satisfy clause 2:
`WF02-REQ027` (`registry.json` `/runs/9/step_2d_infra_restart`: "terminated mid-work by an
infrastructure session limit"), `WF02-REQ038` (`/runs/29/note`: "connection error mid-work"),
`WF02-REQ043` (`/runs/34/note`: "Interrupted by a host power outage mid-rebase"),
`WF03-ISS0109` (`/runs/57/note`: "died on an API error AFTER the merge landed").

**Known exclusions — a record of what has been checked, NOT an exhaustive set.** Sweeping
`registry.json`'s prose fields and `orchestrator.log` on their own terms (2026-08-21) placed
two abnormal terminations from the same window outside the class. They are recorded so the
next re-derivation need not re-litigate them. **This is not a claim that no third exists**;
anything newly surfaced is to be tested against the two clauses above rather than checked
against this list.

- **`WF02-REQ025-20260817`** (`orchestrator.log:297`) — the session that died was ORCH's own,
  *between* dispatches, holding no agent handoff. **Fails clause 1.** ORCH resumed the same
  run and finished the work in place, so no `result` was ever left for a second party to
  complete.
- **`WF02-REQ019-20260816`** — **out of class**, and the reasoning is recorded in full because
  this is the case that reads in-class on treatment and out-of-class on the test. Clause 1
  **holds**: `orchestrator.log:49` carries `ORCH -> TEST-RUNNER | Step 4 test run dispatched`,
  and `registry.json` `/runs/2/note` reads "This run was interrupted mid-pipeline when the
  host process exited after Step 4 dispatch, then resumed in a later session from Step 4
  onward". Clause 2 **fails**: nothing records that TEST-RUNNER began. The only artefact is
  ORCH's own — `orchestrator.log:50` (the `RESUME` line) reads "Committed and pushed the
  orphaned Step 4 dispatch log line (commit `2682e06`)", and `2682e06`'s subject is "commit
  orchestrator.log Step 4 dispatch entry from interrupted run", i.e. ORCH committing its own
  dispatch line, not the agent working. `handoffs/WF02-REQ019-20260816/` holds exactly one
  `step04-test-run.json` and it is the **re**-dispatch (`created_at 2026-08-16T05:10:19Z`,
  after the interruption), whose task text states the prior session "was interrupted before
  Step 4 could run". What died was the host process holding ORCH's session — the same shape
  as `WF02-REQ025`. It was then redispatched to a fresh TEST-RUNNER, the identical treatment
  two rows of the table record, which is exactly why treatment cannot decide membership.

Both exclusions fail the test, so **neither is a fifth row and the four-row table above stands
unchanged.**

**This set and §3's four ad-hoc keys are two different sets that happen to be the same
size, and must not be conflated:** two of those four keys correct a timestamp rather than
record a death, and two of these four deaths (`WF02-REQ038`, `WF02-REQ043`) wrote no key at
all.

### (a) Who may complete it — and it is never "nobody"

The answer splits on **whether the step's own side effects finished**, which §4.1(c)
below decides by probe rather than by reading the handoff.

**Case (a-1) — side effects INCOMPLETE: REDISPATCH.** ORCH re-stamps the handoff to
`PENDING` with a fresh clock read and dispatches a **fresh instance of the same role**,
which then does the remaining work and writes its own attested `result` normally. No
`not_agent_attested` marker is written, because nothing was reconstructed — the
replacement agent genuinely did the work it reports.

> **`rework_count` is NOT incremented.** `ORCHESTRATOR.md` §5's counter tracks
> **rejected** work, and nothing was rejected: no verdict was reached, let alone a
> failing one. Spending a `max_rework` budget — which exists to catch a producer
> repeating a mistake — on an infrastructure death would exhaust it against a fault the
> producer had no part in.
>
> This is not a new ruling; it is one that has been sitting in a single handoff file
> instead of in this protocol since 2026-08-16. `handoffs/WF02-REQ027-20260816/step-02d-reviewer.json`'s
> `orch_restart_note` records the first REVIEWER dispatch terminating on a session limit
> mid-work, states "rework_count deliberately NOT incremented" for exactly the reason
> above, and notes that because the dead agent's handoff "was left IN_PROGRESS with a
> null result and was never committed, no partial verdict entered the audit trail." That
> last point is the reason redispatch is clean: a dead agent that reached no verdict
> leaves nothing to contradict.

**Case (a-2) — side effects COMPLETE and irreversible: ORCH reconstructs, under (b).**
When the merge has landed and the branch is gone, redispatch is not merely wasteful, it
is impossible — there is no work left for a fresh agent to do, and its report would be
re-derivation from git exactly as ORCH's would be, but carrying the additional false
implication that the acting agent reported it. So **ORCH, and only ORCH, completes the
handoff**, marked per (b). ORCH-only here follows the same ownership logic as §4's
registry rule: the reconstruction is a run-level act of bookkeeping, and splitting it
across roles is how ISS-0021's who-owns-what contradiction happened.

**Exactly three fields are ORCH's to write here — the same three §3's table sends to this
section, and no others:**

1. **`status`** — to `COMPLETED` or `FAILED`, per §4 step 1.
2. **`completed_at`** — a **fresh clock read taken at reconstruction time**, per §3. Never
   an estimate of when the dead agent would have finished, and never back-dated to the
   side effect's own timestamp; the honest value is when the repair happened.
3. **`result`** — the reconstructed block itself.

**All three MUST appear in (b)'s `fields_written`.** Writing `result` alone and leaving
`status` at `PENDING` with `completed_at` null is not a partial repair — it reproduces
exactly the defect the next paragraph rejects by measurement. `started_at` is **not** on
this list and is not rewritten: ORCH already stamped it at dispatch and it is still true.

**Why "leave it `IN_PROGRESS`/`PENDING` forever and file a separate incident record" is
rejected — by measurement, not by preference.** That option has been executed, and its
cost is on disk: `handoffs/WF02-REQ043-20260818/step-final-git-merge.json` has read
`status: PENDING` with `completed_at: null` and a null `result` since 2026-08-18, for a
run that squash-merged to `main` as `e25822a` via PR #174. The audit trail is not merely
incomplete there — it actively asserts something false, and the truth survives only
inside a prose note in `registry.json`. An audit trail that lies is worse than one that
says "this was reconstructed, here is by whom and from what."

*That specific file is filed as ISS-0192 and is deliberately not repaired by this
amendment; this section is what governs its later repair.*

**ISS-0192's second file is NOT in this section's class, and must not be repaired under
it.** `handoffs/WF02-REQ062-20260819/step-03-test-designer.json` also reads
`status: "PENDING"`, but ISS-0192 itself says why that is a different fault: TEST-DESIGNER
performed §4's steps 2 and 3 and skipped step 1. Measured 2026-08-21, the file carries
`completed_at: "2026-08-19T05:25:43Z"` and a full `result` with `status: "PASS"` — the
acting agent's own attested report. It is a plain §4 step-1 omission needing a `status`
correction only. Applying (a-2) to it would stamp `not_agent_attested` onto a result that
**was** agent-attested, asserting the precise falsehood the field exists to prevent. A
null `result` is what puts a handoff in this section's class; a bare `PENDING` is not.

### (b) The mandatory marking: `not_agent_attested`

A handoff completed under (a-2) **MUST** carry a top-level field named exactly
`not_agent_attested`, an object with **the six REQUIRED members below, and at most the one
OPTIONAL member `backfill_note`**. Not a convention, not a sentence in `result.summary`, not
a key name chosen at the time of writing.

| Member | Contents |
|---|---|
| `reconstructed_by` | the `AGENT_ID` that wrote the block — normally `ORCH` |
| `reconstructed_at` | clock-read UTC timestamp, per §3 |
| `reason` | what happened to the acting agent and why it could not report |
| `fields_written` | **the explicit list of fields this writer authored**, e.g. `["status","completed_at","result"]` |
| `evidence` | the commands run and what each one established — one entry per command |
| `not_verifiable_after_the_fact` | an explicit list of what the probes could not settle. Never an empty implication; if genuinely nothing, say `[]` deliberately |
| `backfill_note` **(OPTIONAL — the only one)** | present **only** on a file amended under this subsection's single named exception below: what was renamed or added, by which run, and the attestation that no factual assertion changed. Admissible on no other file |

**The member set is CLOSED at those seven, and `backfill_note` is the only optional one.** A
member that is neither required nor `backfill_note` is a defect, not an extension — that is
the point of enumerating them, and it is what lets ISS-0191's linter reject a misspelled or
junk key. Two alternatives were considered and rejected when the ISS-0109 backfill first
exposed the gap: reading "six" as a required *minimum* was rejected because it converts a
closed enumeration into an open one and costs the linter exactly that ability; folding the
content into `reason` was rejected because `reason` states why the **result** is unattested
while `backfill_note` states why the **marker** was applied retroactively, and merging them
collapses the reconstruction-versus-measurement distinction inside the one file whose whole
purpose is preserving it.

**And the exception that admits `backfill_note` is SPENT.** It authorised one named file
(below) and no other, so **no further handoff can acquire this member** — a second file
carrying it would be a marker retro-fitted under an authorisation that no longer exists,
which is precisely what the no-backfill rule forbids.

**It is OPTIONAL-BY-ABSENCE — and the absence is date-scoped, because it has to be.** It
appears only on a handoff reconstructed under (a-2). **Every handoff file predating this
rule remains valid unchanged**, and **no backfill is required or wanted** — a marker
retro-fitted to a file nobody can now attest to would itself be an unattested claim.
(Stated without a headcount deliberately: that number grows every run, so any figure
written here is wrong by the next one.)

**What absence asserts, and from when — scoped to the landing COMMIT, not to its day.** On
a handoff created **at or after commit `131aba9`** (committed 2026-08-21T12:13:08+05:00 =
`07:13:08Z`), the commit this rule landed in, absence of `not_agent_attested` asserts that
the `result` is the acting agent's own report — precisely the assertion §3's `result` row
makes into a rule. On a handoff created **before** that commit, absence asserts **nothing**:
those files were never audited against a rule that did not exist, so absence there means
only "the rule did not exist yet."

**Day granularity would be false, and measurably so, which is why the boundary is a
commit.** Measured 2026-08-21: 46 handoff files carry a `created_at` on 2026-08-21, and **42
of them predate `131aba9`** — including
`handoffs/WF03-ISS0109-20260821/step-final-git-merge.json` (`created_at`
`2026-08-21T03:24:18Z`), the repository's single genuine (a-2) reconstruction and the one
file this subsection singles out below. A same-day boundary would therefore have asserted,
of that exact file, that its `result` was the acting agent's own report: the precise
falsehood this field exists to prevent. The backfill below closes that one file; the other
41 are closed only by scoping the boundary correctly.

**One backfill was authorised — exactly one, and it has now been performed.**
`handoffs/WF03-ISS0109-20260821/step-final-git-merge.json` is the single genuine (a-2)
reconstruction in the repository, and it carried `orch_reconstruction`. Before the rename,
`grep -rl not_agent_attested handoffs/` returned only files that *discuss* the field and not
that one — so without this exception, the command offered below as the field's whole
justification would have enumerated **zero** of the one reconstruction that exists, and done
so permanently. The rename to `not_agent_attested` (with `commands_run` → `evidence`, and
`fields_written: ["status","completed_at","result"]` added, which §3 establishes ORCH did
write and did not declare) landed 2026-08-21 in run `WF03-ISS0117-20260821`, and the file
records it in a `backfill_note` member. It was a **key rename over evidence already present
in the file and already ORCH's own** — verified by diffing the file's parsed structure before
and after, which shows zero changed values on common paths and nothing lost — and **not** a
claim retro-fitted to a file nobody can attest to, which is what the no-backfill rule rightly
forbids in general. **No further backfill is authorised by this exception**; it named one
file and is spent.

**Why a required field rather than a convention — the measurement, not the argument.**
The convention — *annotating an out-of-band bookkeeping repair in a top-level key invented
on the spot, for a case §3's table did not cover, of which reconstruction is one member* —
was tried, without anyone deciding to try it. **Not all four instances below are deaths**
(§3's table splits them: two are deaths, two are timestamp corrections); what makes them one
family is the improvised naming, and that is what this measurement is about. §3's table above
is the measurement, re-derived 2026-08-21 over every file under `handoffs/`: **four** occurrences,
in **four** files, in **four** runs, under **three** key names, at **two** key positions
(18th/last in three files, 11th/mid-file in one), in **two** shapes.

The shape figure is the one that settles it, and the ordering matters. Sorted by
`completed_at`: **three string-shaped uses inside 25 hours** (2026-08-16T18:49:40Z,
2026-08-16T21:35:39Z, 2026-08-17T19:45:30Z), and then, **three days later**, an object
(2026-08-21T03:29:36Z). So the shape held long enough for two later writers to reproduce
it, and was then silently replaced by a fourth who had no way to know the other three
existed. That is not a convention converging on a form; it is four agents each solving the
same problem alone, and the fourth one's improvement — a structured object with an
evidence list, which is strictly the best of the four — is invisible to every writer
before it and to any reader who greps for the wrong name.

**And a written rule is necessary but NOT sufficient — say so rather than pretend
otherwise.** §2's `status` enum *is* written down, and — re-derived 2026-08-21 by the same
scan as §3's table — **15** handoff files on `main` violate it: **13** carry `"PASS"`, a
`result.status` value, in the handoff's own `status` field, and **2** have no top-level
`status` key at all and sit on a foreign flat schema. Writing
this down will not by itself produce compliance. What a *named field* buys over prose is
that the violation is **greppable**: `grep -rl not_agent_attested handoffs/` enumerates
every reconstructed handoff in one command, and a linter can assert over the field's
shape. Prose in a summary is findable by nobody and checkable by nothing — and the
proof is `handoffs/WF03-ISS0109-20260821/step-final-git-merge.json`, whose repair was
otherwise exemplary: after it, **nothing in `status`, `completed_at`, `result.status` or
`result.artifacts_out` distinguishes that file from a normal completion.** Only free-text
prose and a non-schema key do. A weak model that omits the prose leaves a reconstruction
indistinguishable from a measurement, which defeats the audit trail entirely.

`fields_written` is the member not to drop. That same exemplary repair reconstructed
`completed_at` without declaring it (see §3), so the one field whose ownership the
protocol *had* already assigned was the one silently taken.

### (c) Died MID-action vs died AFTER acting — decide by probe, never by judgement

These need materially different paths — (a-1) and (a-2) above — and **the two are
indistinguishable from the handoff file itself.** This is the hard part, and the evidence
says so directly:

- `WF02-REQ043-20260818` — host power outage **mid-rebase**, branch left mid-rebase
  (corroborated by ISS-0046, whose `discovered_in_run` names this run and this step).
- `WF03-ISS0109-20260821` — API error **after** the merge had already landed.

**The predicate is evaluated at REPAIR time, not at death time**, and that is why the same
run can appear on both sides of this section. `WF02-REQ043-20260818` died *mid*-rebase, so
at the moment of death it was case (a-1) — which is why it appears in the bullet above as
the mid-action exemplar. Its side effects have since completed (`e25822a`, verified
2026-08-21 as an ancestor of `main`), so a repair attempted *today* evaluates the
predicate to satisfied and is case (a-2) — which is why (a-2) cites it too. Both citations
are correct and they are not in tension: "is there work left for a fresh agent to do" is a
question about now, never about then. Evaluate the probes when you repair, and classify
from what they return.

**On disk these two presented identically: a handoff with a null `result`.** They needed
opposite treatments. So the discrimination is a **MANDATORY PROBE OF THE STEP'S DECLARED
SIDE EFFECTS**. It is never a judgement call, and it is never read off the handoff's own
contents — the handoff records only what the agent *intended* to do, and an agent that
died mid-action intended everything.

**Worked example — the probe set for a git step**, lifted verbatim from
`WF03-ISS0109-20260821`'s own `not_agent_attested.evidence` (written as
`orch_reconstruction.commands_run`, renamed by the backfill above), which is where this
was first done properly:

```bash
ls .git/rebase-merge .git/rebase-apply          # a mid-rebase leaves these behind;
                                                # their ABSENCE is the most direct
                                                # mid-action discriminator there is
git status --short && git branch --show-current # clean tree? which branch?
git fetch origin
git rev-list --left-right --count origin/main...HEAD   # 0 0 => HEAD is exactly origin/main
git ls-remote --heads origin <branch>           # empty => remote branch deleted (cleanup ran)
gh pr view <n> --json state,mergedAt,mergeCommit # MERGED + a mergeCommit sha => it landed
```

**Generalised, for step types that are not git steps:** every step type declares an
**idempotent completion predicate** over its own side effects — the files it was to
write, the rows it was to insert, the artefacts it was to produce — and the
mid-vs-after classification is the **output of evaluating that predicate**, not an input
to it. All side effects satisfied ⇒ case (a-2). Any side effect unsatisfied ⇒ case (a-1).

Two constraints, both stated because omitting either is how this goes wrong:

1. **INDETERMINATE FALLS TO REDISPATCH (a-1).** Not to reconstruction, and not to a
   judgement call about which is more likely. The asymmetry is what decides it:
   redispatching an already-complete idempotent step costs one agent turn and changes
   nothing, while attesting to an incomplete one puts a **false PASS into the audit
   trail** — the one failure this whole section exists to prevent, and the one nothing
   downstream can detect.
2. **What the probes cannot settle goes into `not_verifiable_after_the_fact`, never
   omitted.** `WF03-ISS0109-20260821` did this correctly — it listed the two questions
   git cannot answer after the fact (whether the rebase hit any conflict, since a clean
   rebase leaves no trace; and whether `git stash` was used) — and it is the single
   practice from that incident most worth making mandatory, because **silence about an
   unverifiable thing reads as verification.** A reader cannot tell an unasked question
   from an answered one.

### (d) Record it at the run level too

A recovered handoff is also a fact about the *run*, and a reader scanning
`handoffs/registry.json` must be able to tell a clean run from a recovered one without
opening every step file. See `ORCHESTRATOR.md` §7.2 for the `recovered` /
`recovery_note` fields and for which of the two registry mechanisms (amend in place vs.
append a `-resume` entry) applies when.

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
