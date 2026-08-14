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

```
1. Assign the next available local ID: docs/issues/ISS-NNNN.yaml
   (check the highest existing NNNN under docs/issues/, increment)

2. Write docs/issues/ISS-NNNN.yaml:
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
   github_issue: null   # filled in step 3, or left null + noted if gh unavailable
   status: open

3. If `gh` is authenticated and origin is reachable:
   gh issue create --title "<title>" --body "<description>

   Discovered by <AGENT_ID> during <run-id>.
   Local record: docs/issues/ISS-NNNN.yaml"

   Record the returned issue number/URL back into ISS-NNNN.yaml's github_issue field.

   If gh is unavailable: set github_issue: null and add a one-line note in the yaml
   file's description explaining why (no auth / no network) — per core-directives.md's
   "No Issue Left Local-Only", this is not a silent skip.

4. Commit docs/issues/ISS-NNNN.yaml as part of the current step's normal commit.

5. Do NOT extend the current run to fix it. Do NOT launch a nested workflow. The
   current step's own PASS/FAIL verdict is unaffected by an incidentally-discovered
   issue — only issues that ARE the current step's own failure drive that step's
   rework.
```

## Picking up a queued issue later

A later WF-03 (Issue Resolving) run picks an `open` entry from `docs/issues/` the same
way ORCH picks the next `pending` requirement from `docs/requirements.yaml` — see
`docs/agents/ORCHESTRATOR.md`. On pickup, set `status: in_progress` in the issue file;
on resolution, `status: resolved` plus the resolving run-id and timestamp. Never delete
an issue file — it is the audit trail of what was found and when it was fixed, same
append/never-rewrite spirit as `docs/status/requirement_status.yaml`.
