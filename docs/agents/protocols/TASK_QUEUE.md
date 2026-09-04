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

**As of 2026-08-19, fallback selection is forbidden.** If `letflow-queue` is
unreachable (network down, not yet deployed, or `$QUEUE_AUTH_TOKEN` unavailable) —
**including a session that believes itself to be single-host** — ORCH MUST NOT fall
back to reading `docs/requirements.yaml` to pick unscoped work on its own initiative.
A session cannot reliably know it is the only host running Letflow agents, and
"single-host, no multi-host risk" was exactly the reasoning that failed on 2026-08-19:
two concurrent runs both selected REQ-048 because one of them was in fallback mode and
couldn't see the other's in-flight claim, producing a fully duplicated WF-02 run that
had to be discovered and cancelled after the fact (see `docs/anti-patterns.md`).

When the queue is unreachable, ORCH reports `no_eligible_task (queue unreachable)` and
stops — it does not silently, or even explicitly, degrade to file-order selection. This
does not block work that is *not* agent-selected: a specific `REQ-XXX` named directly by
the user, or another human-originated instruction, is not "agent discretion over
selection" and may still proceed without the queue for *selection* purposes — but see
"A human names a specific issue" below: skipping selection is not the same as skipping
the queue's claim/release entirely, and doing so leaves a real duplicate-work window
open to any other host running `get_next_task` against the same still-open item.

### Reachability checks must not have side effects

**Test reachability with `GET /health`** (no auth required, touches nothing) —
**never** with `get_next_task` used as a probe. `get_next_task` is not read-only: it
atomically claims and locks whatever it returns, and its GitHub-import step can also
mutate queue state (importing not-yet-tracked open issues as new tasks) even when the
claim itself is later released. A `get_next_task` call made "just to check the service
is up" with a disposable `agent_id` (e.g. `"probe"`) still produces a real lock on a
real task that a concurrent host could have been about to claim — release it
immediately if this happens by mistake, the same as any other hand-back (2026-08-20,
ISS-0086/GH#303's own resolution run — this happened for real, see
`docs/anti-patterns.md`).

### A human names a specific issue/GH-issue-number directly

Selection is exempt from the Hard Rule (above), but **locking is not** — the task still
needs to be claimed before work starts and released when done, or nothing stops a second
host's own `get_next_task` from independently claiming the same still-open item mid-run.
Bounded procedure (full detail and rationale in `ISSUE_QUEUE.md`'s "Picking up a queued
issue later" section — this is the summary):

1. Known `queue_task_id` (recorded in the issue's yaml)? → `set_lock` it directly.
2. Not known? → exactly **one** real `get_next_task` call, real `agent_id`. Matches by
   `github_issue_number` → proceed locked, backfill `queue_task_id`. Doesn't match →
   `release_lock` it back to `open` (no `status`) immediately, report the mismatch, do
   not chase further down the stack.
3. On completion: `release_lock(status: "done")` whatever was actually locked in 1/2. If
   2 never found a match, state that plainly — the queue's mirror stays out of sync for
   that item, bounded risk once its GitHub issue is closed (closed issues are never
   re-imported, see the "GitHub Issues visibility" section's `get_next_task` bullet
   below), but still a real gap worth noting.

**Legacy note — recovering from a *pre-2026-08-19* fallback session.** Before this rule
existed, a requirement completed in fallback mode still had a real, already-registered
queue task sitting `open`/unlocked if it was registered before the fallback session
(check its `impl_order:` comment in `docs/requirements.yaml` — that's the queue task
id). This reconciliation path is retained only to clean up state from before the rule
changed — it is not a currently sanctioned way to work around the queue. Do
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
hand). Record the reconciliation in the current run-history volume (find it via
`docs/status/requirement_status.index.yaml`) as an entry with **`req: SCOPE-CHANGE`** and
a normal `event:` value (usually `done`), naming the reconciliation in `note:`. Note the
field: `SCOPE-CHANGE` is a **`req`** value, never an `event` value. An earlier version of
this line said "as a `SCOPE-CHANGE` event" and produced three malformed entries, now
recorded as known anomalies in the index.

---

## The four functions

All calls are HTTP requests to the deployed `letflow-queue` instance, bearer-token
authenticated (`Authorization: Bearer $QUEUE_AUTH_TOKEN`, token supplied via
environment — never hardcoded, same convention as REQ-103's dev bootstrap token). This
env var name must match `letflow-queue`'s own `QUEUE_AUTH_TOKEN` exactly (see its
`README.md`'s "Auth" section and `deploy/.env.example`) — an earlier draft of this doc
called it `LETFLOW_QUEUE_TOKEN`, which doesn't match anything the service reads.

**Before concluding the token is unavailable, check both places it may live:**
1. `$QUEUE_AUTH_TOKEN` in the current shell environment.
2. A `QUEUE_AUTH_TOKEN=` line in a `.env` file at the repo root (`./.env`, gitignored,
   not tracked — `grep QUEUE_AUTH_TOKEN .env` if present).

**Both are legitimate sources — check `.env` before treating the queue as unreachable.**
On this workstation's checkout, `.env` carries a working `QUEUE_AUTH_TOKEN` (confirmed
2026-08-19 by a live `get_next_task` call succeeding with it), placed there deliberately
as a sanctioned local-dev convenience (confirmed with the project owner 2026-08-19) —
not a leak: `.env` has never been tracked in git (`.gitignore` covers both the exact
name and `.env.*`), and the token string does not appear anywhere in git history. Skip
this check only if you've confirmed `.env` genuinely doesn't exist or has no such line —
missing that check on 2026-08-19 caused an unnecessary trip into (the now-forbidden)
fallback mode when the queue was in fact reachable the whole time.

Only if **neither** source yields a token is this the genuine unreachable case covered
by the Hard Rule above (report blocked, do not select). Never guess or invent a
substitute value, and never hand-edit `.env` to add a token you don't already have from
one of these two sources.

The secrets-inventory claim below — that the real value is "deliberately not stored on
any developer workstation" per `ai-dala-infra`'s `landscape/secrets-inventory.md`
(entry `letflow-queue-test:QUEUE_AUTH_TOKEN`), living only in
`/opt/apps/letflow-queue-test/.env` on the service host — is now known to be **stale for
this workstation specifically**: a local `.env` copy is sanctioned here as a dev
convenience. Treat the secrets-inventory doc itself as the thing needing an update (out
of scope for this repo) rather than re-deriving policy from this contradiction each
session.

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

**`depends_on` takes integer queue task ids, not `REQ-` strings** (established
empirically 2026-08-23, during S5's REQ-148..REQ-175 registration). Every example in
this file happens to show `depends_on: []`, which left the element type unstated. Posting
`"depends_on": ["REQ-058"]` is rejected with `422` / `{"error":"depends_on: is
invalid"}`; `"depends_on": [103]` succeeds. So a batch registration has to resolve each
`docs/requirements.yaml` `depends_on` entry to the queue id of the already-registered
task — its `impl_order`/`id` — which in practice means **registering in dependency
order** and keeping a `REQ-xxx → task id` map as you go. A requirement whose dependency
is not yet registered cannot be registered either; that is a real ordering constraint,
not an incidental one. The failure is loud (422, nothing created), so a wrong format
cannot silently produce a task with a missing dependency edge.

**Cloudflare fronts this service, and it filters by user-agent.** A `POST` from Python's
default `urllib` user-agent returns `403` with Cloudflare `error code: 1010` — *not* a
`letflow-queue` auth failure, and not something a valid `$QUEUE_AUTH_TOKEN` fixes. The
same request via `curl` (or any client sending a normal UA) succeeds. If you get a `403`
whose body is Cloudflare HTML or a bare `error code: NNNN` rather than the service's own
`{"error": ...}` JSON, suspect the client, not the token. `GET /health` succeeding while
a `POST` 403s is the giveaway.

**Optional request field `github_issue_number`** (added 2026-08-21, `letflow-queue` PR #4,
deployed and verified live): when supplied, the service **adopts** that existing GitHub
issue instead of creating a second one. A number already linked to another task is
rejected — `github_issue_number: has already been taken` — rather than re-pointed at the
new task, so adoption can never silently steal another task's issue. Use it only for an
issue that genuinely was filed on GitHub first (a human opened it, or the queue was
unreachable when the finding was made); the default path remains "let `register_task`
create the issue", and `ISSUE_QUEUE.md` step 2a's "do NOT also call `gh issue create`
separately" is unchanged.

`task_type` is **required** — `"requirement"` for planned WF-01 output, `"issue"` for
an `ISSUE_QUEUE.md`-sourced incidental discovery. It drives `get_next_task`'s claim
priority (below); there is no reliable way for the service to infer it after the fact,
so ORCH must state it explicitly on every `register_task` call.

Returns the created task including its `impl_order` (the implementation sequence
number — this is what get_next_task sorts by within a `task_type`, and doubles as the
task `id` used by `set_lock`/`release_lock`).

**Response field `issue_ref`** (added 2026-08-21, same PR #4): `"ISS-"` plus the
zero-padded task id for `task_type: "issue"` — task 187 → `"ISS-0187"` — and `null` for
`task_type: "requirement"`. **This is the issue's id**: `ISSUE_QUEUE.md` no longer derives
issue numbers by scanning `docs/issues/`, because a scan cannot reserve a number and that
convention collided eight times. The queue's `id` is an autoincrement primary key, so it
is allocated atomically across every host. For issue-type tasks the service additionally
rewrites the task title to carry `issue_ref` as a prefix, stripping and replacing any
`ISS-NNNN:` token the caller supplied; only a **leading** token is replaced, so an `ISS-`
reference appearing elsewhere in a title is a genuine cross-reference and survives
verbatim. (Verified live 2026-08-21: a title deliberately prefixed `ISS-0120:` came back
as id 187, `issue_ref` `"ISS-0187"`, title rewritten to `"ISS-0187: ..."`,
`github_issue_number` 375.)

Record it back into the source record so a
human/agent reading the file can cross-reference which queue task it maps to:
- `task_type: "requirement"` → the requirement's entry in `docs/requirements.yaml` (a
  new `impl_order:` field, or a comment — see the migration note below).
- `task_type: "issue"` → **the response's `issue_ref` is the record's filename**:
  `docs/issues/<issue_ref>.yaml`, e.g. `docs/issues/ISS-0187.yaml`, with `id:` inside
  matching it. Its `queue_task_id:` field (added 2026-08-20, `ISSUE_QUEUE.md`'s matching
  update) carries the same integer — `ISS-0187` ↔ task `187`. That equality is what makes
  a later WF-03 run able to `set_lock` the exact task directly, derivable from the
  filename alone, instead of gambling on `get_next_task`'s claim order (see "A human names
  a specific issue" below).

**A new issue discovered mid-run still gets a number** — this is the literal
requirement from the design brief. `register_task` is the only source of `impl_order`
values; nothing else assigns them. This applies uniformly whether the new work came
from WF-01 (a planned requirement, `task_type: "requirement"`) or `ISSUE_QUEUE.md` (an
incidental discovery, `task_type: "issue"`) — both funnel through the same
`register_task` call, tagged accordingly.

**An unregistered requirement carries no `impl_order` at all — never a guessed one.**
`impl_order`/`id` on the deployed service are the same integer, so a locally-derived
placeholder (file-max+1, or any other invented number) doubles as a working
`/tasks/<id>/...` URL that addresses whatever unrelated task actually holds that id on
the shared queue. This is not a hypothetical: REQ-109/110/111/112 shipped with
file-max+1 values commented `# letflow-queue task id`, and acting on one of them
(believing it was REQ-109's task) transitioned an unrelated open task to `done` and
closed the wrong GitHub issue (ISS-0092/GH#314). If a requirement has not yet been
through `register_task`, record the deferral as a comment line
`# impl_order: UNREGISTERED -- <rationale>` at the entry's own field indentation, rather
than filling it with a placeholder that reads as a real id. The marker and a non-empty
rationale after `UNREGISTERED` are **mandatory**: bare absence of any `impl_order` line is
an error condition, not a second legal form, and
`mix letflow.check_requirements_registration` fails on it (R1) — a deferral nobody
recorded a reason for is indistinguishable from an oversight, which is the condition
ISS-0221 was filed about.

**A deferral also goes stale, and staleness is now gated (ISS-0258).** Recording a reason
is necessary but not sufficient: a rationale that was true when written stays green
forever unless something re-checks it against the world, which is the ISS-0221 failure
mode one layer up. `mix letflow.check_deferral_staleness` supplies the missing invariant.

- **The rule.** A deferral is **stale** once its stage becomes active. A stage is
  *active* iff at least one requirement assigned to it — excluding the deferred entry
  itself — has `status` `done`, `in_progress`, or `blocked`. `pending` and `cancelled`
  confer no activity (abandonment is not activity), and a stage with no requirements is
  inactive. A stale deferral **fails the run**, naming the `REQ-NNN`, its stage, and the
  sibling ids whose status made the stage active. A deferral pending a not-yet-active
  stage stays green and is merely reported — the visible-debt principle is unchanged;
  only its never-expiring half is.
- **A deferred entry must carry a `stage:`.** Without one, its staleness is undecidable,
  and an undecidable deferral is a violation rather than the benefit of the doubt.
- **Scoping a deferral to a sibling requirement instead of a whole stage** uses a
  recognised prefix inside the same rationale — no new field:

      # impl_order: UNREGISTERED -- blocked-by: REQ-042 -- waiting on the token kernel

  The prefix must be **anchored at the start of the rationale**, the named id must exist
  in `docs/requirements.yaml`, it may not be the entry's own id, free-text rationale after
  it is still required, and `blocked-by:` references may not form a cycle. The scope
  **expires on its own**: once `REQ-042` is `done` or `cancelled`, the deferral is stale
  again. It is a machine-checkable assertion, not an exemption — there is no exception
  list, no grandfathering, and no allowlist of any kind.

**As of the `issue_ref` change this warning has a second reason:** for
`task_type: "issue"`, a guessed id is also a guessed *filename*. Inventing a number now
produces a `docs/issues/ISS-NNNN.yaml` that can collide with another host's record on the
exact path — the failure class documented twice in `docs/anti-patterns.md` — *and* a
`/tasks/<id>/...` URL addressing an unrelated task. Only `register_task`'s response
supplies either.

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

### 3. `set_lock` — lock a task you already know the id of

**Who calls this:** `ORCH` only. Two legitimate uses:
- **Recovery** — re-claiming a task this same host already held before a crash/restart,
  using the same `agent_id`.
- **Targeted claim of a known-id task named directly by a human** — see "A human names a
  specific issue" below. **This is not merely a recovery mechanism at the API level**:
  per `letflow-queue`'s own `README.md`, the service accepts any `agent_id` on an
  unlocked task, not only one that previously held it — "Unlocked, or already locked by
  the same `agent_id` → `200`... Locked by a *different* `agent_id` → `409 Conflict`."
  This corrects an earlier draft of this doc, which undersold `set_lock` as
  recovery-only and left no documented way to target-claim a specific already-known task
  id outside the `get_next_task` priority order (2026-08-20, ISS-0086/GH#303's own
  resolution run).

```bash
curl -X POST https://queue-test.ai-dala.com/tasks/42/lock \
  -H "Authorization: Bearer $QUEUE_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"agent_id": "'"$HOSTNAME"'-orch"}'
```

409 Conflict means another host currently holds it — do not force past this without
using `release_lock`'s `force` override deliberately and with a stated reason (see
below).

**This only works if the id is already known.** There is no lookup-by-`github_issue_number`
or lookup-by-title endpoint (the service is deliberately four operations, per its own
README's "Design" section) — the id has to come from a prior `register_task` response
(now recorded as `queue_task_id` in `docs/issues/ISS-NNNN.yaml` or as `impl_order` in
`docs/requirements.yaml`, per `ISSUE_QUEUE.md`'s 2026-08-20 update) or from having seen
it in a prior `get_next_task`/`set_lock` response. An issue with no recorded id and no
prior sighting cannot be target-claimed at all — see "A human names a specific issue"
below for the bounded fallback.

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

**`status: "done"` means the issue/requirement is resolved, not that the run merely
finished cleanly.** This distinction matters because `status: "done"` best-effort
closes the linked GitHub Issue (see "GitHub Issues visibility" below) — closing it is a
claim that the underlying defect is fixed or the requirement is delivered, read by
every future run and by the human skimming closed-issue state. A WF-03 run that
completes its Step Final PASS gate by producing a *diagnosis*, a *triage/re-scoping*, or
an *attempted-and-reverted fix with recorded evidence* has finished cleanly as a run,
but has NOT resolved the issue — release it WITHOUT a `status` (leaving it `open`,
per the hand-back path below) so the GitHub mirror stays open too. Confusing "the run
finished" with "the issue is resolved" caused three issues (#360/#366/#367, ISS-0108/
ISS-0112/ISS-0113) to be auto-closed by a `status: "done"` release out from under a
closing comment that itself said "left open, not fixed" — see ISS-0277's resolution
for the full account. Before calling `release_lock(status: "done")`, confirm the
run's own final report describes a shipped fix or delivered requirement, not an
investigation, partial finding, or reverted attempt.

**`status: "blocked"` means the run reached a genuine, stable terminal stop that is NOT
a resolution — use it for a WF-03 Step 5 outcome recorded as `instrumented` or
`no_defect` (see `docs/agents/protocols/ISSUE_QUEUE.md`'s "Issue status vocabulary").**
Both of those statuses assert the run investigated the issue to completion and reached a
real, evidence-backed verdict, but neither asserts the underlying defect was fixed —
`instrumented` ships verified diagnostic work with the root cause still open (and a
required `superseded_by:` pointer); `no_defect` establishes there was no root cause to
remove. Releasing either outcome with `status: "done"` is wrong for the same reason bare
no-status release is wrong for a hand-back: it either falsely claims resolution
(`"done"`'s documented meaning, above) or leaves the task `open` and immediately
re-claimable by the very next `get_next_task` call — for `task_type: "issue"` tasks
specifically, `get_next_task`'s LIFO issue-priority claim order (see function 2, above)
means an `open`, already-fully-investigated issue-type task is re-claimed ahead of every
other open task, producing a re-selection loop for any automated session that doesn't
special-case it (this is exactly what happened live, 2026-09-04, to queue task
458/ISS-0458 — see that record's own account).

`status: "blocked"` avoids both failure modes: it excludes the task from every future
`get_next_task` eligibility check (the claim query filters `WHERE t.status = 'open'`
only — a `blocked` row can never match), so there is no re-selection loop, and it does
NOT best-effort-close the task's linked GitHub Issue (only a release whose resulting
status is literally `"done"` triggers that; `"blocked"` is a pure passthrough) —
appropriate, since an `instrumented`/`no_defect` outcome typically still wants the
GitHub issue's own Step 5 close-with-comment procedure to run on its own terms (see
`WF-03_issue_resolving.md` Step 5), not the queue's best-effort side-closure.

**What `status: "blocked"` does NOT assert:** despite the English word's ordinary sense
("stuck, waiting on something, needs action" — the same sense this doc itself uses at
"report blocked, do not select," above), a queue task released with `status: "blocked"`
under this convention is NOT necessarily stuck or actionable. It means "terminally
stopped, not resolved" — a deliberately reused existing enum value, not a new state
invented for this meaning. Do not read `status: "blocked"` in queue task listings as
"this needs attention" without also checking the linked `docs/issues/ISS-NNNN.yaml`
record's own `status:` field (`instrumented` or `no_defect`) for what it actually means;
the queue's bare three-value status field cannot distinguish a genuinely-stuck-and-
actionable task from a genuinely-terminal one on its own today.

```bash
# Releasing an instrumented/no_defect WF-03 outcome:
curl -X POST https://queue-test.ai-dala.com/tasks/42/release \
  -H "Authorization: Bearer $QUEUE_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"agent_id": "'"$HOSTNAME"'-orch", "status": "blocked"}'
```

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
- **Fallback selection is forbidden as of 2026-08-19** (see the Hard Rule section
  above) — even a single-host or deliberately-disconnected session must not read
  `docs/requirements.yaml` to pick unscoped work; the queue's unreachability is a
  blocked state to report, not a mode to switch into. Reading the file for *content*
  once a task id is already known (citing a REQ's description, acceptance criteria,
  `depends_on` for cross-linking) is unaffected — this rule is about selection only.

---

## Deployment status

`letflow-queue` is deployed and live at `https://queue-test.ai-dala.com` (`ai-dala-infra`'s
`T-0107`/`T-0108`, both `done` as of 2026-08-15). The S0/MVP-1 backlog (REQ-010..014,
REQ-101..108) is registered — see `docs/status/requirement_status.yaml`'s (volume 1,
closed) entries with `req: SCOPE-CHANGE` for the full REQ-ID ↔ queue-task-id mapping.
A prod deployment (`queue.ai-dala.com`) is not yet planned — test only, per T-0107's notes.

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
