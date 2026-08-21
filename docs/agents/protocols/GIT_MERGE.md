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

**What "reported green" means here.** This suite carries a standing set of pre-existing
failures (13-15 at the time of writing) and has for days, so "green" read as "zero
failures" would make this precondition unsatisfiable and is *not* what it means. **Green
means: no failure attributable to this branch.** Attribution is made structurally, per
`core-directives.md`'s "Failure Attribution Is Structural, Never By Count-Matching" —
read it there; it is not restated here. **Do not attribute by comparing counts with a
previous run.** A failure you have structurally cleared is filed and forwarded per
`ISSUE_QUEUE.md` and does not block this precondition; a failure you cannot clear does.

## Procedure

```
1. Verify current branch:
   git branch --show-current
   Must equal feature/<run-id>. If not: STOP; report FAIL to ORCH.

2. Stage any remaining uncommitted files (test specs, reports, changelogs, handoffs
   written by downstream agents since the implementing agent's own commit) by
   explicit filename — never `git add -A` (updated 2026-08-17, ISS-0023/GH#81:
   unsafe in a shared/worktree checkout, and contradicts this project's own
   established practice of staging by filename in every handoff commit):
   git status   # see what changed
   git add <file1> <file2> ...
   If `git status` shows a clean tree, skip to step 4.

   Same shared-checkout reason, second case: if another ORCH-role session is live in
   this same checkout, `git status` here may show ITS files and `git log` its commits —
   stage by explicit filename only (already required above) and push only your own
   commits; see `ORCHESTRATOR.md` §7.1.

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

      ⚠️ `git checkout --ours`/`--theirs` is INVERTED during `git rebase`
      compared to `git merge` (added 2026-08-17, ISS-0039/GH#121 — this
      inversion caused a real silent overwrite of a resolved issue record on
      `main`, discovered only because a later run independently re-read the
      file instead of trusting the resolving run's own log). During `git
      rebase`, `--ours` = the commit you're rebasing ONTO (main), `--theirs` =
      your own commit being replayed — the opposite of `git merge`'s meaning.
      Don't use either flag from merge-trained habit during a rebase conflict;
      read the actual `<<<<<<<`/`=======`/`>>>>>>>` content (or `git show
      :2:<path>` / `git show :3:<path>`) and hand-resolve instead. After
      resolving, independently re-read the resulting file's content before
      writing a log/status entry claiming what was kept — see
      `docs/anti-patterns.md`'s matching entry for the full incident.

      SEMANTIC conflicts (added 2026-08-17, ISS-0023/GH#81): a textual conflict
      marker means git couldn't merge two overlapping edits automatically. A
      semantic conflict is different in kind and easy to miss — both sides may
      have rewritten the SAME function in incompatible ways with no textual
      overlap at all (e.g. two concurrent requirements each changing the same
      function's return shape). Recognize it by asking, for every function
      changed on either side of the conflict: did the OTHER side also touch this
      function's body or contract, even without a textual marker there?

      If yes, neither "take ours" nor "take theirs" is presumptively correct —
      each may encode a real fix or a real feature the other side lacks. Resolve
      by composing both intents into one correct implementation (not by picking
      a side), then PROVE the composition mechanically rather than by inspection:
        - Diff already-shipped `@spec`s against origin/main after resolution —
          `git diff origin/main -- <file> | grep '@spec'` — a byte-level change
          to a signature that was NOT the point of either side's work is a signal
          the composition dropped or altered something unintended.
        - Exercise the merged result under the specific condition that would
          expose a wrong resolution (not just `mix test` against the ordinary
          suite) — e.g. a cold `mix run --no-start` VM with no Repo/DB started,
          if the conflict concerns code a warm test VM's already-loaded modules
          would silently paper over. Pick the condition from what's actually
          different about the two sides' changes, not a generic smoke test.
      Worked example this guidance is drawn from: REQ-023 and REQ-024 (merged
      concurrently from a different worktree) both rewrote
      `Letflow.TenantProvisioning.tenant_scoped_migrations/0` — REQ-024 with a
      bare `{version, module}` list, REQ-023 with a `{version, module, filename}`
      manifest fixing a module-loading defect. Taking either side alone would
      have silently dropped the other's migration from the registry or
      reintroduced the loading defect; the correct resolution composed both into
      one manifest, verified by diffing `@spec`s and by dumping the manifest from
      a cold `mix run --no-start` VM (exactly where the dropped/defective form
      would have raised).

   c. git rebase --continue

   d. Verify the build still passes:
      mix compile --warnings-as-errors
      If FAIL: fix compile errors, git add <file>, git rebase --continue
      mix test

      ⚠️ This suite carries a standing set of pre-existing failures — a non-zero
      failure count here is NOT by itself a FAIL. Before reporting FAIL, ATTRIBUTE
      EACH failure structurally, per `core-directives.md`'s "Failure Attribution Is
      Structural, Never By Count-Matching" (canonical home; not restated here).
      "Green" at this step means NO FAILURE ATTRIBUTABLE TO THIS BRANCH, not zero
      failures. Do NOT attribute by comparing counts with a previous run — that
      method is what this rule forbids. A failure you have structurally cleared is
      filed and forwarded per `ISSUE_QUEUE.md` and does NOT block this step; a
      failure you cannot clear is unattributed, and unattributed blocks.

      If FAIL (i.e. at least one failure is attributable to this branch, or is
      unattributed):
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

## Worktree variant

Added 2026-08-17 (ISS-0023/GH#81). **Applies whenever this checkout is a secondary
`git worktree` sharing one `.git` with a primary checkout that holds local `main`** —
`git worktree list` shows more than one entry. Steps 8-9 behave differently here.

**Step 8** (`gh pr merge --squash --delete-branch`) partially fails *by design* in
this setup: the GitHub-side merge succeeds via the API, then `gh`'s local side
effect of switching this checkout to `main` errors (`fatal: 'main' is already used
by worktree at ...`) — and because that step errors, `--delete-branch` never runs
either. **Reading only the error output, an agent would reasonably conclude the
merge failed when it had actually already succeeded — verify before treating this
as FAIL:**

```
gh pr view <n> --json state,mergedAt
```

If this shows `"state":"MERGED"`, the merge landed — ignore the local checkout
error and continue. Then delete both refs explicitly, since `--delete-branch` never
ran:

```
gh api -X DELETE repos/{owner}/{repo}/git/refs/heads/feature/<run-id>   # remote
git branch -d feature/<run-id>                                          # local, once off it
```

**Step 9** (`git checkout main`) fails outright here for the same reason step 8's
local side effect does — git refuses to check out a branch already checked out in
the primary worktree. Replace step 9 with:

```
9w. git fetch origin main --prune
    git checkout --detach origin/main
```

Detached HEAD at the fetched remote tip — never checks out local `main`. The
"Acceptance criteria" section above doesn't transfer literally to this variant: `git branch
--show-current` outputs empty (not `main`) under a detached HEAD by design, and
`git status` reports "HEAD detached at ..." rather than being on a named branch.
Verify instead with:

```
git rev-parse HEAD                # must equal:
git rev-parse origin/main          # (i.e. HEAD is exactly at the fetched merge commit)
git log --oneline -1               # must show the squash-merge commit from step 8
git status                         # must show a clean working tree (detached HEAD is expected, not a failure)
```

## Conflict escalation

When this step FAILs due to a complex conflict (>5 files or the excluded paths), ORCH
routes to CODE-DESIGNER to produce the correct merged content for each conflicting
file, then ELIXIR-DEV/FRONTEND-DEV applies it and re-attempts from step 5.
`rework_count` applies; `max_rework = 3` before ESCALATED.
