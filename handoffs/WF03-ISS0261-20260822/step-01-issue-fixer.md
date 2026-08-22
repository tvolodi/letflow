# WF-03 Step 0.5/1 — ISSUE-FIXER

Run: `WF03-ISS0261-20260822`
Agent: `ISSUE-FIXER`
Queue task: 261, GitHub issue: 509

---

## Step 0.5 — registry lookup

Searched `docs/issues/*.yaml` for a resolved entry matching "mutation test" /
"mutate" symptoms. No prior entry builds or promotes a mutation-testing tool;
`ISS-0258.yaml` is the origin of this follow-up (its `resolution_note` records
the throwaway `tdv_mutate.py` and the recommendation to promote it), not a
prior fix of the same issue. Not a recurrence.

## Step 1 — diagnosis (root cause, not just "no tool exists")

Reconstructed the deleted `tdv_mutate.py`'s interface and guarantees from
`handoffs/WF03-ISS0258-20260822/step-04b-test-design-validator.md` section 7
(quoted invocation: `python tdv_mutate.py mix.exs '<old>' '<new>'`,
`MUTATE-OK <file>` on success, refuses to write unless the target string
occurs exactly once). Confirmed via `git log --all --grep ISS-0258` and
`git log --all --diff-filter=A --name-only | grep tdv_mutate` that the file
was never committed to any tree — it lived only in the throwaway worktree for
that run, so its logic is recoverable only from the handoff prose, not from
`git show` on any commit.

Root cause (see `docs/issues/ISS-0261.yaml` description for full text): the
gap is a MISSING ARTEFACT, not a logic defect in the deleted script. Every
WF-03 run whose fix adds a module must reconstruct or skip the same
single-occurrence-substitution machinery, with no shared, documented calling
convention — real toil, and it invites the exact failure the original script
existed to make loud (a mutant that never landed producing a false
KILLED/SURVIVED reading).

Design decisions made directly (this run built the fix itself rather than
routing through CODE-DESIGNER/ELIXIR-DEV — a scripts/-only, non-application,
non-tenant-data change, judged small/scoped enough per the parent's explicit
instruction to keep this a small tooling change; still routed through
REVIEWER per that same instruction):

- **Language: Python, stdlib only.** Kept over a mix task or shell script.
  A mix task can't run against code the mutation is expected to break (the
  unmutated project must compile first to even load the task). A shell
  one-liner (`sed -i`) can't portably enforce "exactly one occurrence" and
  this repo's dev hosts are Windows, where `sed -i` quoting is a documented
  hazard (`docs/anti-patterns.md`).
- **Mutant taxonomy**: single-occurrence substitution — operator swap,
  comparison flip, constant perturbation, deletion — matching the MS/MV
  numbering style `WF03-ISS0258-20260822` itself used and the "mutants must
  target the specific traps the fix exists to handle" rule in
  `docs/agents/workflows/WF-03_issue_resolving.md`.
- **Interface**: `python scripts/mutate.py <file> <old> <new> --
  <test-command...>`. Generalises the original by also running the test
  command and always reverting (try/finally, byte-identical verified)
  instead of leaving both to the calling agent's own shell commands.

Next action: route to REVIEWER for idiom/placement sanity (SECURITY-REVIEWER
explicitly out of scope — no tenant-data path). See
`docs/issues/ISS-0261.yaml` `resolution_note` for the full build record and
real demonstration output.
