# ISS-0467 — Direct push to main bypasses branch protection: fix design

Status: designed (2026-09-05). Owner (design): CODE-DESIGNER. Owner (apply): whichever
agent implements this design (repo-administration/doc edits, not `lib/letflow/` code —
this design step does not itself edit `GIT_MERGE.md`/`ORCHESTRATOR.md`; see Forbidden in
`.claude/agents/code-designer.md`).

This is a docs/protocol design, not an Elixir module design: there is no `@spec`, no
schema, no gen_statem shape. The "interface" this document specifies is the exact
verbatim text to add to two files, and the reasoning for choosing that fix over the
alternative named in ISS-0467's acceptance criteria.

## 1. Option chosen: **Option 2** — documented prohibition in GIT_MERGE.md

**Not Option 1** (configuring GitHub's `restrictions` push-allowlist). This directly
follows ISSUE-FIXER's live-verified diagnosis in
`handoffs/WF03-ISS0467-20260904/step-01-issue-fixer.json` (`result.summary`), which I
reviewed and did not find a way to distinguish push classes that the diagnosis missed —
engaging with it point by point:

- **Live-confirmed facts, not re-derived:** `restrictions` is currently absent from
  `gh api repos/tvolodi/letflow/branches/main/protection`'s response (unset, matching
  0018's own `restrictions: null` configuration). The pushing/merging identity is
  `tvolodi` for every `git push`, every `gh pr merge`, and every `gh api` call this
  pipeline makes — one credential set, `admin: true` on the repo.
- **Why `restrictions` cannot do the job here:** GitHub's `restrictions` field gates
  *who* may push to a protected branch (a user/team/app allowlist). It has no concept of
  *why* a push is happening or *what state* the branch's required checks are in — unlike
  `required_status_checks`, which 0018 already established gates on check state
  independent of identity. Since every legitimate direct-action push (ORCHESTRATOR.md
  §10 sizing-rule exception, before this design's own correction — see §3 below) and
  every illegitimate/accidental bypass push both originate from the same `tvolodi`
  identity, an allowlist naming `tvolodi` is satisfied by both identically. It cannot
  discriminate the two cases GitHub's UI markets it for distinguishing.
- **I looked for, and did not find, a viable distinguishing mechanism** the diagnosis
  didn't consider (a deploy key, a machine/bot GitHub account, a fine-grained PAT scoped
  differently from the interactive `gh auth` session): none of these exist in this
  project's current auth setup (confirmed by ISSUE-FIXER's `gh auth status` /
  `gh api user` / `gh api repos/.../permissions` output — one human-linked account,
  admin, used for everything). Introducing one now would be a separate, larger piece of
  infrastructure (provisioning a second credential, deciding which pipeline actions use
  which identity, keeping both authenticated on every host that runs this pipeline) that
  ISS-0467 does not ask for and that 0018 itself declined for exactly this reason
  ("restricting who can push would have no effect here... would only add a maintenance
  surface" — 0018 §(a)). Manufacturing a second identity purely to make `restrictions`
  non-degenerate is out of scope for this fix and not justified by the issue's severity
  (MINOR).
- **Therefore:** configuring `restrictions` would add a maintenance surface (an
  allowlist naming the one identity that already has unrestricted access) with zero
  actual discrimination between push classes — it would not reject the exact scenario
  ISS-0467 reports (a same-identity direct push bypassing red/pending checks). Option 2
  — removing the alternate path entirely by prohibiting it in documentation, backed by
  no other path existing in this pipeline's normal operation — is the only one of the
  two named options that actually closes the gap. This is also the exact resolution
  0018's own "Follow-up, not re-opening this decision" section already anticipated as
  one of its two named candidates.

## 2. GIT_MERGE.md — exact verbatim new text

**Location:** insert as a new subsection immediately after the existing "## Precondition"
section (after the paragraph ending "...they also gate the actual merge call itself, not
only the meaning of 'green' the agent chooses to trust." and before the "**What 'reported
green' means here.**" paragraph — i.e. as its own paragraph, still inside `## Precondition`,
directly following the 0018 cross-reference sentence). Rationale for placing it in
Precondition rather than only in Step 6/8: the prohibition is a precondition on *how* this
whole protocol may be invoked, not a step inside it — an agent must know before step 1 that
there is no bare-push shortcut, not discover it only at step 6.

Verbatim text to add:

> **No direct push to `main`, ever — not even a one-line doc fix (added
> 2026-09-05, ISS-0467/0018 follow-up).** `main`'s required-status-checks branch
> protection (0018) genuinely gates every merge made through this protocol's own
> step 8 — but it does **not** gate a bare `git push origin main`. GitHub's
> `restrictions` setting (branch protection's separate "restrict who can push"
> control) cannot close that gap on this project: every push and every merge this
> pipeline makes authenticates as the same single admin identity, so an allowlist
> naming that identity would accept the exact bypass it would need to reject
> (live-confirmed, ISS-0467). The only closure available is removing the
> alternate path itself: **every change to `main`, with no exception for size,
> triviality, or file count — including a single-line correction to this very
> file — goes through this protocol's full branch-and-PR procedure (steps 1-9
> below), never a direct `git push origin main`.** This applies even when
> `ORCHESTRATOR.md` §10's sizing rule licenses skipping the producer/validator
> agent chain for a qualifying edit — §10 licenses skipping *review*, not
> skipping *this protocol*; see `ORCHESTRATOR.md` §10's own clarifying sentence
> (added by this same fix) for the canonical statement of that boundary. An
> agent that finds itself about to run `git push origin main` for any reason has
> misread this protocol; stop, create a branch, and proceed from step 1 instead.

**Second, smaller addition — Step 6's heading.** Step 6 currently reads `Push branch to
remote: git push origin feature/<run-id>`. No textual change is needed there — the step
already names the feature branch, never `main`, so it does not itself invite the bypass.
The fix belongs entirely in the Precondition addition above, which is the section an
agent reads before deciding whether this protocol's ceremony is warranted at all (the
exact decision point ISS-0467's real incident shows failing).

## 3. ORCHESTRATOR.md §10 reconciliation — explicit statement

**My reading: §10 already does not authorize a bare push to `main`, on the text as
written — the direct-push behavior in 0018's "A real gap found live" section was a
deviation from §10, not a licensed reading of it. A correction is still needed, because
the ambiguity that made the deviation possible is real, even though §10's text does not
resolve in the bypass's favor.**

Textual evidence for the reading:

- §10's own heading and opening sentence scope the exception precisely: "when ORCH may
  act directly, **without spawning the producer/validator chain**" — the thing being
  skipped is named explicitly, and it is the *agent chain* (REQ-VALIDATOR,
  CODE-DESIGN-VALIDATOR, SECURITY-REVIEWER, TEST-DESIGN-VALIDATOR, etc.), not the git
  workflow.
- AGENT_SYSTEM.md §4 (also read per this task) states the same exception in
  near-identical words and is even more explicit about what's skipped: "ORCH may act
  directly, **without spawning a subagent or writing a handoff file**" — again, the
  agent/handoff machinery, not `git push` vs. PR.
- Neither section's six-item checklist (one file, no new public API, no migration, no
  supervision file, no tenant-data path, no test-behavior change) mentions git mechanics
  at all — it is entirely about the *content* of the change qualifying for reduced
  *review*, saying nothing about which git command commits it.
- 0018's own "A real gap found live" section reaches the identical conclusion
  independently, calling the direct push "already, separately, against this project's
  own established discipline (`GIT_MERGE.md`/`ORCHESTRATOR.md` §7.1 prohibit
  force-pushing `main`, and the whole pipeline's git-setup/git-merge wrapper model
  assumes a PR, never a bare push) — this gap is only reachable by an agent already
  deviating from the documented workflow, as this record's own author did here." 0018
  does not treat its own incident as a correct application of §10; it treats it as a
  deviation from standing practice.

**Conclusion: §10 as currently written does not say "ORCH may git push straight to
main"; it says "ORCH may skip the producer/validator chain."** The bypass observed live
was the acting agent conflating "skip the review chain" with "skip the branch+PR
mechanics," which the text does not actually license — but nothing in §10 or
AGENT_SYSTEM.md §4 says so *explicitly* either; both are silent on git mechanics rather
than stating the boundary. That silence is exactly what let the deviation happen in
practice (0018's incident is direct proof an agent read it that way, whatever the
"correct" reading is), so per the task instruction ("state whichever correction is
actually needed... never leave the ambiguity unaddressed") this design specifies
option (a): **add an explicit sentence to §10 closing the silence, not leave it to be
inferred from omission.**

### ORCHESTRATOR.md §10 — exact verbatim new text

**Location:** append as a new paragraph at the end of section "## 10. Sizing rule — when
ORCH may act directly" (after the existing closing paragraph ending "...When a check is
ambiguous, it is a 'no.'").

Verbatim text to add:

> **This exception governs review, not git mechanics (clarified 2026-09-05,
> ISS-0467).** Qualifying under all six checks above licenses skipping the
> producer/validator agent chain and the handoff-file machinery for this change
> — it does not license skipping `GIT_SETUP.md`/`GIT_MERGE.md`'s branch-and-PR
> procedure. A direct-action change still gets its own branch, still opens a PR,
> and still merges through `gh pr merge` (or `--admin` per 0018's documented
> override path) exactly like any other change — never a bare `git push origin
> main`. This was previously left to be inferred from this section's silence on
> git mechanics, and in practice an agent inferred the opposite (0018's "A real
> gap found live" section, ISS-0467) — this paragraph closes that specific
> silence; see `GIT_MERGE.md`'s own Precondition section for the corresponding
> prohibition.

This is a one-file (well, two-file — see below), no-new-public-API, no-migration,
no-supervision-file, no-tenant-data, no-test-behavior-change documentation correction:
by §10's own six-item checklist, it would itself qualify for direct action *if it were
one file*. It is two files (`GIT_MERGE.md` and `ORCHESTRATOR.md`), so per check 1 the
combined change does not qualify — it must go through the normal WF-03 workflow, which
this design step is itself already part of. (This has no bearing on the design; it is
a note for whichever agent applies it, so the same discipline this design documents is
followed in applying it.)

## 4. Decision-record placement: amend 0018 in place — no new decisions/ record needed

**Reasoning**, weighing 0018's own framing:

- 0018's "Follow-up, not re-opening this decision" section (in "A real gap found live")
  explicitly named both options ISS-0467 was filed to resolve as the anticipated next
  step of *this same* decision, not a separate one: "file a new issue recommending
  GitHub's... `restrictions`... be revisited, or that `GIT_MERGE.md` add an explicit
  line prohibiting direct pushes to `main`... closing the gap by removing the alternate
  path entirely." ISS-0467 is that anticipated issue, already filed and now designed.
  Resolving it is *completing* 0018's own follow-up, not opening new ground 0018 didn't
  already scope.
- 0018's "What this record does not decide" section lists three explicit exclusions
  (other-branch protection, a future third required check, automating the override
  judgement) — none of them is "whether a direct push to `main` should be prohibited."
  That question was inside 0018's scope from the start (0018's own Question section (a)
  addresses `restrictions` directly: "No push/merge `restrictions`... restricting who
  can push would have no effect here... would only add a maintenance surface" — the
  exact reasoning ISSUE-FIXER's live diagnosis and this design both reconfirm with fresh
  evidence). This fix is not deciding something 0018 deferred; it is finishing something
  0018 started and flagged as incomplete.
- A new decision record is warranted when a change makes a *new, independent*
  design call outside an existing record's scope (per this project's own pattern: 0018
  itself is a new record because ISS-0441 raised a design question 0004 hadn't scoped).
  This fix makes no new call of that kind — the two options were already named and
  reasoned about in 0018's own text; this design step is choosing between them using
  fresh live evidence, which is squarely "amend in place" territory, not "new decision."

**Action:** append a short dated subsection to 0018 titled `## ISS-0467 resolution:
direct-push prohibition (2026-09-05)` after the existing "A real gap found live"
section (before "## What this record does not decide"), recording: the option chosen
(2, prohibition — not `restrictions`), a one-paragraph summary of the reasoning in §1
above, and a pointer to the two textual changes in §2/§3 of this design plus this design
file's path. This mirrors 0018's own established discipline of recording follow-up
resolutions inline rather than fragmenting one branch-protection posture across multiple
files. (Writing this subsection is implementation, not design — left to the applying
agent, per the same Forbidden boundary noted in this document's header.)

## 5. AC3 — no regression to `gh pr merge` / `--admin` override path

**Explicit statement: nothing changes about that path.** This design touches only:

1. `GIT_MERGE.md`'s Precondition section (a new paragraph prohibiting bare pushes) —
   Step 8's three-path merge procedure (plain merge / wait-on-pending / `--admin`
   override with attribution) is untouched, verbatim, no edit proposed anywhere in this
   design to that step's text.
2. `ORCHESTRATOR.md` §10 (a new closing paragraph clarifying scope) — the six-item
   qualifying checklist itself is untouched; the new paragraph adds a statement about
   *which procedure* a qualifying change still goes through, without altering what
   qualifies or how review is skipped.
3. `docs/migration/decisions/0018-branch-protection-posture.md` (a new dated subsection
   appended after "A real gap found live") — 0018's Decision section ((a)-(d)), its
   Configuration-to-apply commands, and its existing Verification log are all untouched
   verbatim.

No change is proposed to `required_status_checks`, `enforce_admins`, or any branch
protection API configuration — this design does not call `gh api --method PUT
.../protection` at all (that is precisely the point: Option 1, which would have touched
that configuration, was rejected in §1). The `--admin` override path, its attribution
precondition, and its live-verified rejection/acceptance behavior (0018's Verification
log, PRs #887 and #895) are all orthogonal to a prohibition that only ever fires on a
`git push origin main` invocation — `gh pr merge --squash --delete-branch [--admin]`
is a different code path entirely and is never touched by anything in this design.

## 6. AC2 — not applicable (Option 1 not chosen)

ISS-0467's AC2 ("if restrictions are added, live-verify them... a real attempted direct
push to main that is genuinely rejected, with the real quoted rejection output") is
conditional on choosing Option 1. Since §1 above chooses Option 2, no `gh api`
configuration call is being added, so there is nothing to live-verify by attempting a
rejected push — a documentation prohibition is not a mechanically-enforced gate; its
"verification" is textual review (CODE-DESIGN-VALIDATOR, then REVIEWER, confirming the
new paragraphs are unambiguous and correctly placed), not a `gh api`/`git push` call.
This is stated explicitly per the acceptance-criteria mapping in §7, not left silent.

## 7. Acceptance criteria mapping (ISS-0467.yaml, verbatim criteria)

1. *"Either configure `restrictions`... or add an explicit line to GIT_MERGE.md...
   decide and record which, and why"* → §1 (decision: Option 2) + §2 (exact text) + §4
   (record placement: amend 0018).
2. *"If restrictions are added, live-verify them..."* → §6 (not applicable; Option 1 not
   chosen, reasoned explicitly, not silently skipped).
3. *"No regression to the existing `gh pr merge` / `--admin` override path"* → §5
   (explicit: nothing changes, enumerated by exactly which three files/sections are
   touched and which are not).

Task-level acceptance criteria (handoff `task.acceptance_criteria`):

- Design artefact naming the exact option with reasoning tied to the diagnosis → §1.
- Exact verbatim new text for GIT_MERGE.md → §2.
- ORCHESTRATOR.md §10 reconciliation, either a correction or an explicit no-change
  statement → §3 (correction designed, with textual evidence for why one is needed
  despite my own reading already favoring the non-bypass interpretation).
- Option 1's `gh api`/`gh ruleset` command and live-verification procedure → §6 (not
  applicable, reasoned).
- AC3 explicitly addressed → §5.
- New decisions/ record vs. amend-in-place, with reasoning → §4.
- No implementation code, no `.ex`/`.exs` bodies → this entire document is prose plus
  quoted Markdown paragraphs to be inserted into existing `.md` files; no code block
  contains executable Elixir, and no `gh`/shell command is being introduced (§6 explains
  why none is needed).
- Every ISS-0467.yaml acceptance criterion mapped to a concrete design element → this
  section.

## Open questions

None. The diagnosis, the two named options, and the §10 ambiguity are all fully resolved
by the reasoning above; nothing here is deferred as TBD.
