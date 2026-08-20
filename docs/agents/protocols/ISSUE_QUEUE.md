# ISSUE_QUEUE Protocol

**Function:** `fn:enqueue-issue`
**Read by:** every agent
**Used in:** any step that discovers a defect outside its own current scope

## Purpose

A run does one job and does it completely: git-setup once, the run's own steps,
git-merge once. A defect discovered *incidentally* — not the thing the run was
dispatched to fix — is filed and forwarded to become its own later run, rather than
silently expanding the current run's scope or being dropped.

This is distinct from `core-directives.md`'s Unblock-Everything directive: that covers
defects that block *this run's own* acceptance criteria (fix them now, in this run).
This protocol covers defects that are merely adjacent — noticed, not blocking.

## Procedure

**Updated 2026-08-20 (ISS-0086/GH#303's own resolution run).** Steps 2-3 previously
had the discovering agent call `gh issue create` directly, with no `letflow-queue`
registration anywhere in this protocol. That was written before `letflow-queue`
existed and was never reconciled with `TASK_QUEUE.md` once it landed — the result was
that every issue filed this way (including ISS-0086 itself) entered the queue only
*opportunistically*, as a side effect of some later `get_next_task` call's GitHub-import
step, if at all. A WF-03 run resolving such an issue had no reliable way to find or lock
its queue task, meaning nothing actually prevented a second host from independently
claiming the same open GitHub issue and duplicating the fix — see
`docs/anti-patterns.md`'s matching entry. Steps 2-3 below now route through
`register_task` instead, per `TASK_QUEUE.md`'s "who calls what" division (only `ORCH`
calls the queue — the discovering agent reports the finding, it does not call `gh` or
the queue itself).

```
1. Assign the next available local ID: docs/issues/ISS-NNNN.yaml
   (check the highest existing NNNN under docs/issues/, increment)

2. The discovering agent reports the finding to ORCH (title, description, severity,
   affected_files) — it does not call `gh` or letflow-queue itself. ORCH then:

   a. If letflow-queue is reachable ($QUEUE_AUTH_TOKEN via shell env or ./.env — see
      TASK_QUEUE.md's "Before concluding the token is unavailable" check; verify
      reachability with `GET /health`, never with `get_next_task` — see TASK_QUEUE.md's
      Reachability checks note):

      register_task(title, description, acceptance_criteria: ["See linked GitHub
        issue for full description"], task_type: "issue")

      This best-effort creates the mirrored GitHub Issue itself (per TASK_QUEUE.md's
      "GitHub Issues visibility" section's `register_task` bullet) — do NOT also call
      `gh issue create` separately, that would double-post. Record the response's `id`
      (queue task id) and `github_issue_number` into ISS-NNNN.yaml's `queue_task_id`
      and `github_issue` fields respectively.

   b. If letflow-queue is unreachable (genuinely, both token locations checked): fall
      back to `gh issue create --title "<title>" --body "<description>

      Discovered by <AGENT_ID> during <run-id>.
      Local record: docs/issues/ISS-NNNN.yaml"` directly, per core-directives.md's "No
      Issue Left Local-Only" — this is not a silent skip. Set `queue_task_id: null` with
      a one-line note explaining why (queue unreachable at filing time — flagged for
      reconciliation once it's back), so a later WF-03 run knows to attempt
      registration before relying on `queue_task_id` being absent-by-design.

      If `gh` is ALSO unavailable: set both fields null, note why in the yaml file's
      description.

3. Write docs/issues/ISS-NNNN.yaml:
   id: ISS-NNNN
   title: <one-line summary>
   discovered_by: <AGENT_ID>
   discovered_in_run: <run-id>
   discovered_at: <UTC timestamp from the clock>
   severity: BLOCKER | MAJOR | MINOR
   description: >
     <what's wrong, where, and why it matters>
   affected_files:
     - <path>
   queue_task_id: null   # filled from register_task's response per step 2a, or noted per 2b
   github_issue: null    # filled from the same response (or gh issue create's output per 2b)
   status: open

4. Commit docs/issues/ISS-NNNN.yaml as part of the current step's normal commit.

5. Do NOT extend the current run to fix it. Do NOT launch a nested workflow. The
   current step's own PASS/FAIL verdict is unaffected by an incidentally-discovered
   issue — only issues that ARE the current step's own failure drive that step's
   rework.
```

## Picking up a queued issue later

As of `letflow-queue` going live, task **selection** happens through `get_next_task`
only — see `TASK_QUEUE.md`'s Hard Rule. This section now covers the two remaining
cases: a queue-selected pickup, and a human naming a specific `ISS-NNNN`/GitHub issue
directly (which bypasses selection but not locking).

**Queue-selected pickup (the normal case):** `get_next_task` returns the task; its `id`
is the `queue_task_id` — cross-reference against `docs/issues/*.yaml` by
`github_issue_number` to find the matching local record (or, for a task that predates
this field, by title). Set `status: in_progress` in the issue file and backfill
`queue_task_id` if it was previously null. On resolution, `status: resolved` plus the
resolving run-id and timestamp, then `release_lock(status: "done")`.

**A human names a specific issue/GH-issue-number directly:** this is not "agent
discretion over selection" (see `TASK_QUEUE.md`'s Hard Rule exception) and may proceed
without `get_next_task` choosing it — but the task must still be locked before work
starts and released when done, or nothing stops a second host's own `get_next_task`
call from independently claiming the same still-open item. Concretely:

1. If the issue's `docs/issues/ISS-NNNN.yaml` already records a `queue_task_id`: call
   `set_lock` directly on that id. (It works on any currently-unlocked task you already
   know the id of, not only a task this same agent held before — see
   `TASK_QUEUE.md`'s `set_lock` section.)
2. If `queue_task_id` is null or the issue predates this field (filed under the
   pre-2026-08-20 version of this protocol, see "Updated" note above): make **exactly
   one** real `get_next_task` call (the run's real `agent_id` — never a disposable
   "probe" id). If the returned task's `github_issue_number` matches, proceed locked and
   backfill `queue_task_id` into the yaml immediately, closing this gap for next time. If
   it doesn't match, `release_lock` it back to `open` (no `status`) immediately, state
   the mismatch plainly, and do not chase further down the priority stack — repeated
   claim/release thrashes a shared service other hosts depend on. (What you got back
   instead is itself real, current information — a different open task exists at higher
   priority — surface it, don't just discard it.)
3. On completion, `release_lock(status: "done")` the task actually locked in step 1/2.
   If step 2 never found a match, note explicitly that the queue's mirror stayed out of
   sync for this item; this is bounded (not indefinite) risk once the GitHub issue is
   closed, since `get_next_task`'s import only pulls **open** issues — see
   `TASK_QUEUE.md`'s "GitHub Issues visibility" section's `get_next_task` bullet.

Never delete an issue file — it is the audit trail of what was found and when it was
fixed, same append/never-rewrite spirit as `docs/status/requirement_status.yaml`.
