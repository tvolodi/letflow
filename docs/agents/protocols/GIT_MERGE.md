# GIT_MERGE Protocol

**Function:** `fn:git-merge`
**Read by:** `ELIXIR-DEV`, `FRONTEND-DEV`
**Used in:** WF-02 Step Final, WF-03 Step Final, WF-04 direct-routed fix Step Final

## Purpose

Rebases the feature branch onto current `main`, opens a PR, merges it, and cleans up —
unconditionally, with no human review step, because every pipeline gate (build, tests,
security review, release validation) has already passed before this step runs. Per
`docs/migration/decisions/0004-humanless-pipeline.md`, this is by design: there is no
human in the loop to wait for, and the merge itself is pre-authorized once all upstream
gates are green.

## Precondition

CI must exist and be green for this protocol's step 7-8 (PR checks) to mean anything.
**As of this writing, Letflow has no `.github/workflows/` CI configured yet** — that is
S0's REQ-013 (`mix letflow.check` / equivalent gate), still `pending`. Until REQ-013
lands and a CI workflow exists:
- Steps 1-6 and 9-11 below still apply (rebase, commit, push, local cleanup).
- Steps 7-8 (PR + merge) still apply, but `gh pr merge` will have no CI check to wait
  on — proceed with the merge once ELIXIR-DEV/FRONTEND-DEV's own local
  `mix format --check-formatted && mix compile --warnings-as-errors && mix test` (or
  whatever REQ-013 settles on) has been run and reported green in this run's own
  handoffs. Once REQ-013 lands, insert "wait for GitHub Actions check to report success
  on the PR" between steps 7 and 8, mirroring R-Co's pattern.

## Procedure

```
1. Verify current branch:
   git branch --show-current
   Must equal feature/<run-id>. If not: STOP; report FAIL to ORCH.

2. Stage any remaining uncommitted files (test specs, reports, changelogs, handoffs
   written by downstream agents since the implementing agent's own commit):
   git add -A
   If `git status` shows a clean tree, skip to step 4.

3. Commit remaining artifacts:
   git commit -m "feat(<run-id>): finalize artifacts — test specs, reports, status

   Requirements: <comma-separated requirement IDs>
   Handoff: <run-id>"

   For WF-03 fix branches use prefix "fix" instead of "feat".

4. Sync with remote:
   git fetch origin main

5. Rebase onto origin/main:
   git rebase origin/main

   ── CONFLICT HANDLING ──────────────────────────────────────────────
   a. Count conflicted files:
      git diff --name-only --diff-filter=U | wc -l

      If count > 5 OR any conflicted file is under lib/letflow/process_instance.ex,
      lib/letflow/instance_supervisor.ex, or priv/repo/migrations/:
        git rebase --abort
        → complete-handoff(status: FAIL,
            issues: [{severity: BLOCKER,
                      description: "merge conflict too complex for inline resolution: <files>"}],
            next_action: "ORCH escalates to CODE-DESIGNER for conflict resolution")
        STOP

   b. For each conflicted file (≤5 files, not in the excluded paths above):
      - Read HEAD version and incoming version
      - Apply the correct resolution (preserve valid changes from both sides)
      - git add <file>

   c. git rebase --continue

   d. Verify the build still passes:
      mix compile --warnings-as-errors
      If FAIL: fix compile errors, git add <file>, git rebase --continue
      mix test
      If FAIL:
        → complete-handoff(status: FAIL,
            issues: [{severity: BLOCKER, description: "build/tests failed after rebase"}])
        ORCH routes to ISSUE-FIXER; after PASS, return to step 5
   ────────────────────────────────────────────────────────────────────

6. Push branch to remote:
   git push origin feature/<run-id>

7. Create PR:
   gh pr create \
     --title "feat: <one-line summary> [<run-id>]" \
     --body "## Summary
<last-agent result.summary>

## Requirements
<comma-separated requirement IDs>

## Validation
- mix compile --warnings-as-errors: PASS
- mix test: PASS
- SECURITY-REVIEWER: PASS | out of scope
- RELEASE-VALIDATOR: PASS

## Handoffs
handoffs/<run-id>/" \
     --base main \
     --head feature/<run-id>

   For WF-03 branches use --title "fix: <one-line summary> [<run-id>]"

   If `gh` is unavailable (no auth, no network): record
   git_evidence.pr_create_error, skip to step 9 with the branch left pushed but
   unmerged, and set result.status = PARTIAL — ORCH must not treat this as
   silent success. Note it explicitly for the next session to pick up.

8. Merge PR immediately (all gates already passed; see Precondition above for what
   "all gates" means before REQ-013 lands):
   gh pr merge --squash --delete-branch

9. Local cleanup — return to main (MANDATORY):
   git checkout main
   git pull --ff-only origin main
   git branch -d feature/<run-id>

   Verify:
   git branch --show-current   # must output: main
   git log --oneline -1        # must show the squash-merge commit from step 8
   git status                  # must show a clean working tree

   If any check fails: report as FAIL with details.

10. → complete-handoff(status: PASS,
      artifacts_out: ["branch: feature/<run-id> (squash-merged into main, branch deleted)"],
      next_action: "ORCH marks run COMPLETED and releases owned_modules lock")
```

## Acceptance criteria

- [ ] `gh pr merge` exited 0 (or PARTIAL was correctly reported if `gh` unavailable)
- [ ] `git branch --show-current` is `main`
- [ ] `git pull --ff-only` on main after merge exited 0
- [ ] `git log --oneline -1` shows the squash-merge commit
- [ ] `git status` shows a clean working tree

## Conflict escalation

When this step FAILs due to a complex conflict (>5 files or the excluded paths), ORCH
routes to CODE-DESIGNER to produce the correct merged content for each conflicting
file, then ELIXIR-DEV/FRONTEND-DEV applies it and re-attempts from step 5.
`rework_count` applies; `max_rework = 3` before ESCALATED.
