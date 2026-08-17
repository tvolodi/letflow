# GIT_SETUP Protocol

**Function:** `fn:git-setup`
**Read by:** `ELIXIR-DEV`, `FRONTEND-DEV`
**Used in:** WF-02 Step 00, WF-03 Step 00, WF-04 direct-routed fix Step 00

## Purpose

Creates the feature branch before any file changes are made, and pushes it immediately
as the coordination signal to any other agent/host that might pick up overlapping work.

## Branch naming convention

```
feature/<run-id>
```

Examples: `feature/WF02-REQ015-20260816`, `feature/WF03-ISS0001-fix-20260816`.

One branch per run-id. ORCH ensures no two concurrent runs share `owned_modules` (see
`docs/agents/ORCHESTRATOR.md` §Parallel-run coordination).

## Procedure

```
1. git checkout main

2. git pull --ff-only origin main
   If FAIL (non-fast-forward): STOP.
   → complete-handoff(status: FAIL, issues: [{severity: BLOCKER,
       description: "local main has diverged from origin — needs resolution before
       any run can branch from it"}])
   Do not proceed until resolved. ORCH escalates — this blocks every future run, not
   just this one, so it is never routed as ordinary rework.

3. Branch name = feature/<run-id> (supplied by ORCH in context.branch_name)

4. If the branch already exists from a prior aborted run:
   git branch -D feature/<run-id>

5. git checkout -b feature/<run-id>

6. Verify: git branch --show-current  →  must equal feature/<run-id>

7. Push immediately (coordination signal):
   git push -u origin feature/<run-id>

8. → complete-handoff(status: PASS,
     artifacts_out: ["branch: feature/<run-id>"],
     next_action: "ORCH routes to next step per active workflow")
```

## Acceptance criteria

- [ ] `git pull --ff-only` exited 0
- [ ] `git branch --show-current` outputs `feature/<run-id>`
- [ ] `git push -u origin feature/<run-id>` exited 0

## Worktree variant

Added 2026-08-17 (ISS-0023/GH#81). **Applies whenever this checkout is a secondary
`git worktree` sharing one `.git` with a primary checkout that holds local `main`** —
check with `git worktree list` before starting: more than one entry means this
applies. Steps 1-2 above are structurally impossible from a secondary worktree: `git
checkout main` fails outright (git refuses to check out a branch already checked out
in another worktree — forcing past it would corrupt the concurrently running primary
session).

Replace steps 1-2 with:

```
1w. git fetch origin main

2w. git checkout -b feature/<run-id> origin/main
    (branches directly from the freshly fetched remote ref — never checks out local
    main at any point, so there is nothing to conflict with the primary checkout)
```

Steps 3-8 are unchanged (they operate on the new feature branch, not on `main`).
