# TASK_QUEUE Protocol — multi-host coordination

**Service:** `letflow-queue` — a small standalone Elixir/Phoenix + SQLite service,
deployed independently of Letflow itself (own repo: `tvolodi/letflow-queue`). Deployed
and live at `https://queue-test.ai-dala.com` (test only — see "Deployment status"
below). A prod deployment at `queue.ai-dala.com` is not yet planned; every example in
this file uses the live test URL.

**Read by:** `ORCH` (all four functions), every other agent (read-only via `ORCH`'s
dispatch — see "Who calls what" below).

---

## Why this exists

Once Letflow development runs across multiple hosts simultaneously, a single
git-checkout's `docs/requirements.yaml` and local `handoffs/registry.json` stop being a
reliable shared source of truth — two hosts could both read `status: pending` on the
same requirement before either has pushed a claim, and both start work on it. The
`owned_modules` lock in `docs/agents/ORCHESTRATOR.md` §7 only coordinates runs that
share one host's registry; it does nothing across hosts.

`letflow-queue` is the fix: **one shared, authoritative queue**, reachable by every
host, that atomically hands out the next claimable work item and prevents two hosts
from claiming the same one. Per the project's own operating principle
(`docs/migration/decisions/0004-humanless-pipeline.md`), no agent gets direct
discretion over which task to pick or whether to lock it — that decision is made by the
service, not by an agent reading a file and choosing.

Removing GitHub Issues as a control path also removed the one place a human could
casually see queue state (open/claimed/done) without querying the service directly —
`letflow-queue` closes that gap itself, as a function of the app, by mirroring tasks to
GitHub Issues for **visibility only** (see "GitHub Issues visibility" below), rather
than reintroducing Issues as something an agent reads to decide what to do.

---

## Hard rule: agents do not read `docs/requirements.yaml` to pick work

**This is a change from the single-host framing in earlier sections of this doc set.**
Once `letflow-queue` is live for a given run:

- No agent may read `docs/requirements.yaml` and decide "I'll work on REQ-N" on its own
  initiative. Task selection happens through `get_next_task` only.
- No agent may hand-edit a task's status/lock state to route around the queue.
- `docs/requirements.yaml` becomes a **read-only mirror** for human/agent
  reference and cross-linking (e.g. citing `stage`, prior context) — not the
  dispatch mechanism. It is kept in sync by ORCH via `register_task` (see below),
  not edited freely by any producing agent.
- This rule binds **every agent**, not just ORCH — see
  `docs/agents/instructions/core-directives.md`'s updated Zero Manual Work /
  Humanless Operation sections.

If `letflow-queue` is unreachable (network down, not yet deployed, single-host session
with no multi-host risk), ORCH may fall back to the pre-queue single-host behavior
(read `docs/requirements.yaml` directly, same as before) — but must say so explicitly
in its report, per `core-directives.md`'s No Speculation rule, rather than silently
switching modes.

**A requirement completed in fallback mode still has a real, already-registered queue
task sitting `open`/unlocked** if it was registered before the fallback session (check
its `impl_order:` comment in `docs/requirements.yaml` — that's the queue task id). Do
not leave the queue silently out of sync indefinitely: once `$QUEUE_AUTH_TOKEN` becomes
available again (a later session, a different host, a human supplying it), reconcile
by claiming and releasing each affected task —

```bash
# Claiming and immediately releasing (rather than a hypothetical direct-status-write
# endpoint) because letflow-queue deliberately exposes no generic update operation —
# see its README's "Design" section, exactly four endpoints, on purpose.
curl "https://queue-test.ai-dala.com/tasks/next?agent_id=orch-reconcile" \
  -H "Authorization: Bearer $QUEUE_AUTH_TOKEN"
# confirm the returned id matches the REQ's impl_order before releasing
curl -X POST "https://queue-test.ai-dala.com/tasks/<id>/release" \
  -H "Authorization: Bearer $QUEUE_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"agent_id": "orch-reconcile", "status": "done"}'
```

— one task at a time, lowest `impl_order` first, same as normal `get_next_task`
sequencing (this doubles as a live confirmation of *which* task id each REQ actually
mapped to, since `get_next_task` always returns the true lowest-open one — don't assume
`impl_order:`'s comment is correct without this check). This also re-closes each task's
linked GitHub Issue via `release_lock`'s sync (harmless no-op if already closed by
hand). Record the reconciliation in `docs/status/requirement_status.yaml` as a
`SCOPE-CHANGE` event, same as any other manual queue bookkeeping.

---

## The four functions

All calls are HTTP requests to the deployed `letflow-queue` instance, bearer-token
authenticated (`Authorization: Bearer $QUEUE_AUTH_TOKEN`, token supplied via
environment — never hardcoded, same convention as REQ-103's dev bootstrap token). This
env var name must match `letflow-queue`'s own `QUEUE_AUTH_TOKEN` exactly (see its
`README.md`'s "Auth" section and `deploy/.env.example`) — an earlier draft of this doc
called it `LETFLOW_QUEUE_TOKEN`, which doesn't match anything the service reads.

If `$QUEUE_AUTH_TOKEN` isn't set in the current environment, that's the fallback
trigger below, not something to guess or invent a substitute value for. The real value
is deliberately not stored on any developer workstation, per `ai-dala-infra`'s
secrets-inventory policy — it lives only in `/opt/apps/letflow-queue-test/.env` on the
host running the service (`landscape/secrets-inventory.md` in `ai-dala-infra`, entry
`letflow-queue-test:QUEUE_AUTH_TOKEN`). Retrieving it requires host access ORCH does
not have by default in a normal Letflow session — do not attempt to derive, guess, or
hardcode a token; fall back exactly as documented below instead.

### 1. `register_task` — create a new claimable work item

**Who calls this:** `ORCH` only. Two triggers:
- WF-01 (Requirement Development) reaching its end: once REQ-VALIDATOR passes a new
  requirement, ORCH registers it in the queue (in addition to it already existing in
  `docs/requirements.yaml` — the queue is authoritative for *claiming*, the yaml file
  stays authoritative for full requirement *content* per the schema it already has).
- Any agent discovering new work mid-run (an incidental issue via
  `docs/agents/protocols/ISSUE_QUEUE.md`, a REQ-014-style follow-on) reports it to
  ORCH, which registers it — an individual agent never calls `register_task` directly.

```bash
curl -X POST https://queue-test.ai-dala.com/tasks \
  -H "Authorization: Bearer $QUEUE_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "REQ-011: OIDC/Keycloak integration decision",
    "description": "<full requirement description, or a pointer to it>",
    "acceptance_criteria": ["...", "..."],
    "depends_on": [],
    "stage": "S0",
    "task_type": "requirement"
  }'
```

`task_type` is **required** — `"requirement"` for planned WF-01 output, `"issue"` for
an `ISSUE_QUEUE.md`-sourced incidental discovery. It drives `get_next_task`'s claim
priority (below); there is no reliable way for the service to infer it after the fact,
so ORCH must state it explicitly on every `register_task` call.

Returns the created task including its `impl_order` (the implementation sequence
number — this is what get_next_task sorts by within a `task_type`). Record the returned
`impl_order` back into the requirement's entry in `docs/requirements.yaml` (a new
`impl_order:` field, or a comment — see the migration note below) so a human/agent
reading the file can cross-reference which queue task a REQ-ID maps to.

**A new issue discovered mid-run still gets a number** — this is the literal
requirement from the design brief. `register_task` is the only source of `impl_order`
values; nothing else assigns them. This applies uniformly whether the new work came
from WF-01 (a planned requirement, `task_type: "requirement"`) or `ISSUE_QUEUE.md` (an
incidental discovery, `task_type: "issue"`) — both funnel through the same
`register_task` call, tagged accordingly.

### 2. `get_next_task` — claim the next eligible task

**Who calls this:** `ORCH` only, when asked for unscoped work ("what's next," "keep
going") or before dispatching a workflow. This replaces the old "pick the first
`pending` requirement whose `depends_on` are all `done`, in file order" instruction —
the service now does that filtering, atomically, across every host.

```bash
curl -X GET "https://queue-test.ai-dala.com/tasks/next?agent_id=$HOSTNAME-orch" \
  -H "Authorization: Bearer $QUEUE_AUTH_TOKEN"
```

Claim priority is **two-tier**, by `task_type`:
1. If any eligible (`open`, unlocked, `depends_on` satisfied) `task_type: "issue"` task
   exists, the **newest** one (highest `impl_order`) is claimed — issues jump the line,
   most recently discovered first.
2. Only once no eligible issue remains does it fall through to `task_type:
   "requirement"`, claimed in the original **lowest-`impl_order`** (oldest-first) order.

In other words: drain issues LIFO before touching the requirement backlog, then work
the requirement backlog FIFO exactly as before this priority split existed.

- `agent_id` should be stable per host (e.g. hostname or a configured identifier) so a
  lock is attributable and `set_lock`/`release_lock`'s re-lock-by-same-agent semantics
  work as intended across a host's own restarts.
- 200 with the task body → claimed, locked to this `agent_id`. Proceed to route it
  through the matching workflow (WF-02/03/04/05, per
  `docs/agents/ORCHESTRATOR.md` §3).
- 404 `no_eligible_task` → nothing claimable right now (either the queue is empty, or
  every open task's dependencies aren't done yet, or everything open is already
  locked). Report this plainly — it is not an error to work around.

### 3. `set_lock` — re-acquire a lock (recovery path)

**Who calls this:** `ORCH` only, and only for recovery — re-claiming a task this same
host already held before a crash/restart, using the same `agent_id`.

```bash
curl -X POST https://queue-test.ai-dala.com/tasks/42/lock \
  -H "Authorization: Bearer $QUEUE_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"agent_id": "'"$HOSTNAME"'-orch"}'
```

409 Conflict means another host currently holds it — do not force past this without
using `release_lock`'s `force` override deliberately and with a stated reason (see
below).

### 4. `release_lock` — release a claim, optionally transitioning status

**Who calls this:** `ORCH` only, at two points:
- **Normal completion:** after a workflow's Step Final (git-merge) returns PASS, release
  the lock with `status: "done"`.
- **Recovery/override (the "two last functions are for you, if something will go
  wrong" case from the design brief):** if a task is stuck locked by a dead/unreachable
  host (e.g. a run that crashed mid-work and never released), ORCH may release it with
  `force: true` — but only after confirming, as best it can, that the original run is
  genuinely dead (no active handoff, no recent activity) rather than just slow. State
  the reasoning in the handoff/log entry when using `force`.

```bash
curl -X POST https://queue-test.ai-dala.com/tasks/42/release \
  -H "Authorization: Bearer $QUEUE_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"agent_id": "'"$HOSTNAME"'-orch", "status": "done"}'
```

```bash
# Force-release a task stuck locked by a dead host:
curl -X POST https://queue-test.ai-dala.com/tasks/42/release \
  -H "Authorization: Bearer $QUEUE_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"force": true}'
```

A task released without a `status` stays `open` and immediately becomes claimable
again by any host (used for a genuine hand-back, e.g. `PARTIAL` result that needs a
different approach — see `docs/agents/ORCHESTRATOR.md` §5's rework rules; rework still
happens within the same locked task/run in the common case, this release path is only
for a full hand-back to the pool).

---

## Who calls what — division of responsibility

| Role | Calls `letflow-queue` directly? |
|---|---|
| `ORCH` | Yes — all four functions, per the triggers above |
| Every other role (`ELIXIR-DEV`, `REVIEWER`, `TEST-RUNNER`, etc.) | **No.** They receive the task's content via the handoff ORCH writes (same as today — the handoff schema in `docs/agents/shared/HANDOFF_PROTOCOL.md` already carries `context.requirement_ids` and `task.description`). Producing/validating agents never call the queue API and never read `docs/requirements.yaml` to pick their own next task. |

This mirrors the design brief's framing directly: "AI agents manipulate files on their
discretion" is exactly the failure mode being closed. Only ORCH — the one role with no
implementation authority of its own (`docs/agents/AGENT_SYSTEM.md` §3: "Never writes
application code itself") — touches the queue.

---

## `docs/requirements.yaml`'s role going forward

Unchanged in schema (`id`/`title`/`owner`/`status`/`stage`/`description`/
`acceptance_criteria`/`depends_on`) but changed in authority: it is now a **mirror**,
kept in sync by ORCH/DOC-UPDATER, not a file any agent reads to decide what to do next.
Concretely:

- `register_task`'s response `impl_order` gets written back into the matching
  requirement's entry (new field, or a note — DOC-UPDATER's job, same append-discipline
  as everything else in `core-directives.md`).
- The requirement's `status` field is still flipped `pending → in_progress → done` by
  DOC-UPDATER as before (Step 6) — this reflects reality for humans reading the repo,
  but the queue's own `status` field (`open`/`done`/`blocked`) is the one that actually
  gates `get_next_task`.
- Single-host sessions (no `letflow-queue` deployed, or deliberately working
  disconnected) may continue reading `docs/requirements.yaml` directly exactly as
  before — this protocol only binds once multi-host coordination is actually in play.
  See the fallback note above.

---

## Deployment status

`letflow-queue` is deployed and live at `https://queue-test.ai-dala.com` (`ai-dala-infra`'s
`T-0107`/`T-0108`, both `done` as of 2026-08-15). The S0/MVP-1 backlog (REQ-010..014,
REQ-101..108) is registered — see `docs/status/requirement_status.yaml`'s
`SCOPE-CHANGE` entry for the full REQ-ID ↔ queue-task-id mapping. A prod deployment
(`queue.ai-dala.com`) is not yet planned — test only, per T-0107's notes.

The `task_type` field and its two-tier `get_next_task` claim priority (issue-vs-
requirement, above) shipped 2026-08-17 (`letflow-queue` PR #1) and are live on
`queue-test.ai-dala.com`; every pre-existing row was backfilled by that migration
(`stage IS NOT NULL` → `"requirement"`, else `"issue"`).

## GitHub Issues visibility (not a control path)

`letflow-queue` mirrors tasks to GitHub Issues on `tvolodi/letflow` for human visibility
— **this is display-only, not a second control mechanism.** The "no agent discretion"
rule above still holds in full: an agent must never read or act on a GitHub Issue to
select or lock work.

- `register_task` best-effort creates a GitHub Issue (title = task title, body =
  description + acceptance criteria) and stores the returned issue number on the task.
  If GitHub is unreachable or `GITHUB_TOKEN`/`GITHUB_REPO` isn't configured on the
  service, task registration still succeeds — this never blocks the core function.
- `get_next_task` best-effort pulls open GitHub Issues first and imports any not yet
  tracked (by issue number) as new tasks, before running its claim query — so an issue
  opened directly on GitHub becomes claimable without anyone calling `register_task`
  by hand. Imported tasks get `depends_on: []` (GitHub issues have no queue-native way
  to express a dependency yet — a known limitation, not solved here), a generic
  single-item `acceptance_criteria` pointing at the issue body (no markdown parsing),
  and `task_type: "issue"` (a raw GitHub Issue is always incidental — it jumps ahead of
  the requirement backlog per `get_next_task`'s priority above).
- `release_lock` with `status: "done"` best-effort closes the linked GitHub Issue.

**As of this writing, nothing files issues directly against `tvolodi/letflow` for
`letflow-queue` to pull in** — the import direction exists and is tested, but the
project intentionally isn't using it yet ("let it appear when the system is more or
less ready," per the design conversation). Treat it as available, not yet exercised.

See `letflow-queue`'s own `README.md` for the exact request/response shapes.
