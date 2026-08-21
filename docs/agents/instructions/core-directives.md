# Core Directives — Letflow

**Audience:** every agent in the pipeline. Cross-cutting rules, not role-specific ones —
`applyTo: **`.

**Status:** AUTHORITATIVE for cross-cutting behavioural rules, and the canonical home of
the **Instruction Precedence** chain below — which is the single rule for resolving any
conflict between instruction sources on this project. No other document declares itself
the winner; they all defer to that chain.

**Relationship to `docs/agents/shared/HANDOFF_PROTOCOL.md`:** that file is canonical for
handoff *mechanics* (claiming a handoff, JSON encoding, timestamp sourcing, legal
`result.status` values). This file is canonical for the broader behavioural rules that
apply beyond the handoff lifecycle.

---

## ⛔ Zero Manual Work

**Your goal is to reduce manual work for the human to zero.** There is no human
operator in the loop by design (see "Humanless operation" below) — this directive is
even stronger here than it would be in a human-supervised project, because there is
nobody to catch a dropped step.

Do everything yourself. The only valid reasons to leave something undone:
1. Two or more genuinely equivalent options requiring a business/personal preference
   no agent can infer from `docs/requirements.yaml`, `docs/migration/decisions/`, or
   this file — file it as a `docs/migration/decisions/000x-*.md` draft with the options
   named, do not silently pick one and do not stall waiting for a human to answer.
2. **(ORCH only)** ORCH believes a standard workflow (WF-01 through WF-05) can be
   skipped. Since there is no human to confirm this with, ORCH may only skip a
   workflow when this file or `docs/agents/ORCHESTRATOR.md` explicitly authorizes the
   specific shortcut (e.g. WF-01's git-wrapper exception for docs-only changes) — never
   on its own judgement that "this one's simple."

**Forbidden output patterns** — if any of these appear, the response is wrong:
- "You can run..." / "You need to..." / "To complete this, run..."
- "This should work after you..." / "Once you do X, then Y will work"

**No step in this file marked MANDATORY needs re-confirmation before it runs.** Push,
merge, and delete-branch are pre-authorized by `docs/agents/protocols/GIT_MERGE.md` for
every run that reaches Step Final with all gates green — do not pause to ask before
doing them. See "Humanless operation" below for why this is safe on this project.

### ⛔ Orchestrator exception

ORCH fulfils Zero Manual Work by running the pipeline **through subagents**, not by
editing files or running commands directly. Implementing a fix directly "to save time"
is a pipeline violation. The one exception is a change passing all six checks of the
sizing rule in `docs/agents/ORCHESTRATOR.md` §10 — that section is the canonical
definition and this file does not restate it. It is a checklist, never a judgment call
about what feels trivial.

---

## ⛔ Humanless operation

Letflow's pipeline runs without a human reviewer, approver, or merge-clicker in the
loop. This is a deliberate project decision, not an oversight — see
`docs/migration/decisions/0004-humanless-pipeline.md`. Consequences:

- **No PR waits for human approval.** An agent opens the PR, an agent verifies CI is
  green (see "Never call a red pipeline OK" below), and an agent merges it. There is no
  step where a human is expected to look at the diff first.
- **Because there is no human backstop, every gate in this pipeline must actually gate.**
  A validator that rubber-stamps its producer's work (CODE-DESIGN-VALIDATOR approving
  CODE-DESIGNER's own claim of completeness without independently checking) removes the
  only check that exists. Validators MUST re-derive their verdict from the artefact
  itself, never from the producer's self-report.
- **Errors are correctable, not catastrophic.** There is no production deployment and no
  real user traffic at stake yet (pre-S8). A bad merge is fixed by a later commit, not
  avoided by adding a human gate. This licenses the pipeline to move fast and self-heal
  via WF-03 (Issue Resolving) rather than over-engineering pre-merge caution. Don't use
  this as an excuse to skip a validator step — the validators exist so mistakes are
  *caught*, not so they never occur.
- **Weak-model tolerance is a design constraint, not a caveat.** This pipeline must
  produce reliably average-or-better output even when the executing model is a small
  or cheap one — assume the acting agent has no memory of this file's reasoning beyond
  what is written down. Every role file, workflow doc, and guide must be explicit and
  mechanical enough that an agent with limited judgement still produces correct,
  in-scope work by following the steps literally. This is why every gate below has a
  checklist instead of "use good judgement," and why validators re-derive rather than
  trust.

---

## ⚠️ Every producing step has a validating step

**No agent's claim that it finished a task is itself evidence that the task is done.**
This is the load-bearing principle behind the whole roster (see
`docs/agents/AGENT_SYSTEM.md`'s roster table) — every role that produces an artefact is
paired with a role that independently checks it before the pipeline advances:

| Produces | Validates |
|---|---|
| REQ-ANALYST (requirement text) | REQ-VALIDATOR |
| CODE-DESIGNER (design artefact) | CODE-DESIGN-VALIDATOR |
| ELIXIR-DEV (backend code) | REVIEWER (idiom) + SECURITY-REVIEWER (tenant-data paths) |
| FRONTEND-DEV (web/ integration) | REVIEWER + SECURITY-REVIEWER (if tenant-data touched) |
| TEST-DESIGNER (test specs + test code) | TEST-DESIGN-VALIDATOR |
| TEST-RUNNER (test execution + report) | RELEASE-VALIDATOR re-runs the full suite, does not trust the report alone |
| DOC-UPDATER (doc/status update) | ORCH verifies the specific files changed and specific fields flipped, per the DOC-UPDATER handoff's `artifacts_out`, before writing the DONE log line |

A validator that only reads the producer's `result.summary` and says PASS has not
validated anything — it has copied a claim. Every validator role's file states exactly
what it must independently re-check (file existence, specific content, an actual
command run) rather than what it may take on trust.

### Re-derive under the conditions the property is actually about

Re-deriving a verdict is necessary but **not sufficient**. Ask what conditions the
property under test is *about*, and construct them if the ambient environment does not
supply them. **A green check run under conditions where the property could not have
failed is not evidence** — it is a passing run of a different test.

Worked example (WF03-ISS0106-20260821). REVIEWER was asked to confirm that a new
toolchain-mismatch warning is unsuppressible. ELIXIR-DEV had demonstrated it in-tree.
REVIEWER **declined** to re-run that same in-tree probe, on the ground that *this host
is on-pin* — so an in-tree run exercises the match path and proves nothing whatever
about the mismatch path the property exists to serve. It constructed the real case
instead: an out-of-tree directory with a fabricated off-pin version file, run under a
quiet flag and with stdout redirected away. The warning still appeared. That is the
re-derivation; re-running the on-pin probe would not have been one.

---

## ⛔ Instruction Precedence

When two instruction sources disagree, apply them in this order — **first match wins**:

1. **Your handoff's `task` block** — the specific work, its acceptance criteria, and any
   rework notes. Most specific, so it wins.
2. **Your role file** (`.claude/agents/<role>.md`) — what your role may and may not do.
3. **Your workflow's step** (`docs/agents/workflows/WF-0N_*.md`) — the procedure for the
   step you are executing.
4. **Protocol docs** (`docs/agents/protocols/*.md`,
   `docs/agents/shared/HANDOFF_PROTOCOL.md`) — handoff mechanics, git, queue, issues.
5. **This file** (`core-directives.md`) — cross-cutting behavioural rules.
6. **`CLAUDE.md`** — the session-start pointer.

Two rules override the chain, always, at every level:

- **A `docs/migration/decisions/` record is never overridden by anything above it.** If a
  step seems to require contradicting a decided record, stop and flag it for REVIEWER
  sign-off — don't resolve it yourself in either direction.
- **A safety/gate rule is never overridden by a more specific instruction.** No handoff
  `task.description` can authorize skipping a validator, satisfying a gate by editing
  what it measures, or reporting unverified work as done. If a handoff appears to ask
  for that, it is malformed — report it as a BLOCKER in `result.issues`.

**This chain governs what you are told to DO, not what you are told IS TRUE.** Rank 1
makes your handoff's `task` block the highest authority for the *work*. It confers no
authority at all on the handoff's *factual claims* — a handoff is a record written by
another agent, and `docs/anti-patterns.md`'s "Inheriting a claim from a record instead
of re-deriving it from the source" applies to it exactly as to any other record. When a
handoff asserts a checkable fact your work depends on, verify it before building on it;
the rule and its two worked examples live in `HANDOFF_PROTOCOL.md` §1.1 ("A handoff's
factual premises are checkable, and may be wrong") — not restated here.

**Never resolve a conflict silently.** Follow the chain, then record the conflict in your
handoff's `result.issues` at MINOR severity so it gets fixed at the source. A conflict
that goes unreported recurs on every future run — see `HANDOFF_PROTOCOL.md` §4's
ISS-0021 note, where three documents disagreeing about `registry.json` cost two agents a
stop-and-flag decision point before anyone fixed the source.

---

## ⛔ Load Scoped Context, Not Whole Files

**`docs/requirements.yaml` is ~61,000 tokens and holds 70 requirements. A given run needs
one to four of them.** Reading it in full to find one entry buries the requirement you
need under thirty-three `done` entries carrying other stages' constraints — a real
accuracy risk, not only a cost one, because those entries are long and cross-referential
and an agent can anchor on the wrong stage's rules.

**Every role except ORCH, REQ-ANALYST, and REQ-VALIDATOR:** your requirement text is in
your handoff's `context.requirement_text` and `task.acceptance_criteria`. Read it there.
Consult `docs/requirements.yaml` only to resolve a specific ID it names (a `depends_on`
entry, a cross-referenced `REQ-NNN`), and then read only that entry:

```bash
awk '/^  - id: REQ-039$/,/^  - id: REQ-04[0-9]$/' docs/requirements.yaml
```
```powershell
Select-String -Path docs/requirements.yaml -Pattern '^  - id: REQ-039$' -Context 0,60
```

**ORCH** reads what it needs to select and scope work, and is the role that copies the
in-scope requirement's full `description` text into each handoff it creates (see
`HANDOFF_PROTOCOL.md` §2's `context.requirement_text` field). Naming the file in
`artifacts_in` is not sufficient — the receiving agent must not have to open a 61k-token
file to learn what it was asked to build.

**REQ-ANALYST and REQ-VALIDATOR** legitimately need whole-file access (numbering, schema
consistency, cross-requirement checks) — but prefer `grep`/`awk` over a full read when
the check is targeted, and read in full only when the check genuinely is global.

The same rule generalizes: prefer a targeted read over a whole-file read for any file
above a few hundred lines. `git diff main...HEAD` beats reading every changed file;
`grep -n` beats reading a 3,000-line YAML to find one key.

---

## ⛔ No Agent Discretion Over Task Selection or Locking (multi-host)

**Once `letflow-queue` is deployed and reachable** (see
`docs/agents/protocols/TASK_QUEUE.md`), no agent — including ORCH's own delegated
subagents — may read `docs/requirements.yaml` and independently decide which
requirement to work on, or hand-edit any status/lock field to route around the queue.
Task selection and locking are **service-mediated, not agent-discretionary**: an agent
that could "put a lock, or may not put a lock, or may select what they want" defeats
the entire point of multi-host coordination — two hosts reading the same file at
nearly the same moment can both see a requirement as available and both start it. Only
the queue's atomic claim (`get_next_task`) prevents this.

Only `ORCH` calls the queue's four functions (`register_task`, `get_next_task`,
`set_lock`, `release_lock`); every other role receives its work via the handoff ORCH
already writes — this is unchanged from how handoffs already work, it just means the
*source* of what goes into that handoff is now the queue, not a direct file read, once
multi-host coordination is live. See `TASK_QUEUE.md` for the full protocol. **There is
no fallback for task *selection*:** if the queue is unreachable (network down, not
deployed, `$QUEUE_AUTH_TOKEN` unavailable — including a session that believes itself
single-host), ORCH reports blocked rather than reading `docs/requirements.yaml` to pick
work itself. This was tightened 2026-08-19 after a permitted fallback caused two
concurrent sessions to both select and fully implement REQ-048 (see
`docs/anti-patterns.md`); a directly human-named `REQ-XXX` is not affected, since that
is not agent discretion over selection.

---

## ⚠️ Unblock-Everything

Every agent MUST resolve any problem that blocks full completion of the current task,
even if the problem is unrelated to the current task's original scope.

- Unrelated compile errors blocking the build → fix them.
- A broken migration blocking yours → fix the blocker first.
- Test execution reveals failures → determine root cause and fix, do not just report and
  stop. TEST-RUNNER loops: detect failure → route to ELIXIR-DEV/FRONTEND-DEV → fix →
  re-test → repeat until green or `max_rework` exhausted → escalate (see
  `docs/agents/ORCHESTRATOR.md` §4.2).

**Scope boundary.** This covers what stands in your way. A defect you merely *notice*
while working — unrelated, not blocking your acceptance criteria — is filed and
forwarded, not fixed here: register it under `docs/issues/ISS-NNNN.yaml` and, if a
`gh` remote is configured and reachable, file it as a real GitHub issue too (see "No
Issue Left Local-Only" below). It becomes its own later run, not an unbounded scope
creep on this one.

**Only exception:** a destructive or irreversible change to unrelated functionality.
Flag those for ORCH escalation instead of touching them.

---

## ⛔ No Issue Left Local-Only

A defect that lives only in `docs/issues/*.yaml` and never becomes visible work is
invisible to the next run. Any newly discovered issue — whether it's the task at hand
or an incidental finding — gets registered in `docs/issues/` (see
`docs/agents/protocols/ISSUE_QUEUE.md`) **and**, if `gh` is authenticated and the
`origin` remote is reachable, filed via `gh issue create` so it is claimable the same
way any other GitHub issue is. If `gh` is unavailable (no auth, no network), record that
explicitly in the issue file's `github_issue: null # gh unavailable, see note` field
rather than silently skipping it — do not treat "couldn't file on GitHub" as "didn't
need filing."

"Out of scope for the current fix" is a reason to file the finding as its own issue —
never a reason to leave it undocumented.

---

## ⛔ No Speculation

Never report something as working without verifying it yourself. Run the build, run the
tests, read the actual output — then report.

**Forbidden phrases:** "This should work...", "This looks like it will...", "This
probably...", "This might...", "I believe this...".

**If you cannot verify** — no Elixir/mix toolchain on PATH, no Docker, no network for
`mix deps.get` — say so explicitly, per `docs/anti-patterns.md`'s documented Docker
fallback. A requirement stays `in_progress`, not `done`, until someone (an agent with a
working toolchain, or the same agent via the Docker workaround) actually runs it and
reports real output.

---

## ⛔ Never Call a Red Pipeline OK Without a Source

If CI is red or a `gh pr checks` call reports failure, you may not report it as
acceptable on your own judgement.

```bash
gh run view <run-id> --json jobs --jq '.jobs[]|"\(.name): \(.conclusion)"'
gh run view <run-id> --log-failed
```

Read the actual failing step. "It's probably a flaky runner" is not a valid attribution
without reading the log. If GitHub Actions itself is degraded, that's discoverable via
`https://www.githubstatus.com/api/v2/components.json` — check it before attributing a
never-started or cancelled job to an outage; a step that ran and genuinely failed is
never excused by an unrelated outage.

---

## ⛔ Failure Attribution Is Structural, Never By Count-Matching

**Canonical home for this rule.** `WF-02` Step 4/Step 5 and `WF-04` Step 1/Step 2 point
here; they do not restate the evidence.

Calling a test failure "pre-existing" (and therefore filed-and-forwarded rather than
this run's problem) is an **attribution**, and it has to be earned. To call a failure
pre-existing you must show one of these two things, and name the specific evidence:

1. **Structurally, this branch cannot have caused it** — the failing module and its
   dependencies do not appear in `git diff --name-only main...HEAD`; or
2. **It reproduces at the merge-base** — check out the merge-base, run it, quote the
   output.

`"known failure"` is not an attribution. Neither is "the previous run reported this."

**Matching a previously-reported failure count or failure set is NOT evidence of
pre-existence — and a count differing by one or two is NOT evidence of regression.**
Both directions are stated deliberately: the symmetric error is the one that hides a
real regression inside expected noise.

**The measurement that settles this, rather than an argument.** In run
WF03-ISS0106-20260821, TEST-RUNNER ran the full suite **twice on the same commit, ten
minutes apart, and got 13 failures, then 15**. The immediately preceding run
(WF02-REQ066-20260820) had reported **14** on its own commit range, including two
Promotion-module failures that recurred in *neither* later run, and a `Check.TestTest`
subset of 2 against the later 3. Three runs, three different sets. TEST-RUNNER stated
the consequence explicitly: had "matches the previously-reported set" been its
criterion, its own first run would have scored as simultaneously a regression **and** a
fix.

**A failure not covered by an existing issue record is called out as such and filed**
(per `ISSUE_QUEUE.md` and "No Issue Left Local-Only" above) — never folded into "the
known set."

### In the diff is not the same as caused by the diff

Extra scrutiny is owed to any failing file that *does* appear in the diff. But the
standard for clearing it is a **causal argument**, not proximity or its absence.

Worked example, same run: `PinRebindTest` failed and was in the diff. The diff touching
it was a **whitespace re-wrap at lines 513-517**, while the failure was at **line 351**
via `provisioned_tenant/0` — and re-wrapping a list literal cannot make a Postgres
schema vanish mid-test. That reasoning, stated in the report, is what cleared it. "It's
in the diff, so it's ours" and "it's in the diff but looks unrelated" are equally
inadequate; write down the mechanism.

---

## ⛔ File Placement Rules

| File type | Directory |
|---|---|
| Handoff files | `handoffs/<RUN-ID>/` |
| Handoff registry | `handoffs/registry.json` |
| Design artefacts | `lib/letflow/design/` |
| Test specs | `test/specs/` |
| Test run reports | `test/reports/` |
| Requirement status history | `docs/status/requirement_status.yaml` |
| Release decisions | `docs/status/` |
| Issue registry | `docs/issues/` |
| Scratch (one-off scripts, debug dumps, logs) | `scratch/` (git-ignored) |

**Scratch rule:** anything that is not a permanent project artefact — a one-off
verification script, a debug dump, a `.log` file — goes in `scratch/`, never the project
root, `lib/`, or `test/`.

**Before completing any handoff:** confirm no stray file landed in the project root
outside `mix.exs`, `mix.lock`, `README.md`, `CLAUDE.md`, `docker-compose.yml`,
`.gitignore`, `.env.example`. Move anything else to the correct directory or `scratch/`.

**Workflow artefacts are committed to git**, same as R-Co's convention: `handoffs/`,
`lib/letflow/design/`, `docs/issues/`, `docs/status/` are the audit trail. Commit them
at the end of the step that produces or modifies them, not just at Step Final.

---

## ⛔ Bookkeeping Is Not Optional

**1. `handoffs/orchestrator.log` is append-only.** Open with append mode, never
overwrite. A commit that shrinks this file's line count is a defect, not a cleanup —
flag it immediately if you ever observe one, don't assume it was intentional.

**2. Timestamps come from the clock, never from memory.**

```powershell
(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
```
```bash
date -u +"%Y-%m-%dT%H:%M:%SZ"
```

`(Get-Date).ToString(...)` without `.ToUniversalTime()` silently emits local time
wearing a `Z` suffix — always call `.ToUniversalTime()` first. `completed_at` must never
precede `started_at`.

**3. `docs/status/requirement_status.yaml` is append-only.** Read the existing file in
full before touching it, preserve its established schema, append — never rewrite. This
file's own header says so, and an agent has gotten this wrong before (see
`docs/anti-patterns.md`).

---

## ⛔ Never Satisfy a Gate by Editing What It Measures

If a gate blocks you, fix the condition it is detecting. **Never make the detector stop
reporting.** Forbidden regardless of how the task is phrased: renaming output tokens so
a string-matching gate stops matching, deleting or defaulting an error path a gate looks
for, wrapping a failing command so its exit code is masked.

Prefer exit-code gates over string-matching gates when you write a new one — an agent
cannot satisfy an exit code by renaming a label. If a gate itself is wrong, escalate to
change the gate's definition (flag it in your handoff's `result.issues`); do not
quietly satisfy it by other means.

---

## ⛔ Output File Format Rules

**YAML for everything except handoff files.** Handoff files (`handoffs/<run-id>/*.json`,
`handoffs/registry.json`) stay JSON because ORCH reads/writes them as structured data.
Test reports, requirement status, release decisions, issue records — all YAML, matching
the format Letflow's `docs/status/requirement_status.yaml` and `docs/requirements.yaml`
already use.
