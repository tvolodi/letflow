# Design: ISS-0279 — Issue-closure evidence gate + audit tool

**Run:** WF03-ISS0279-20260822 · **Step:** 2 (CODE-DESIGNER) · **Source diagnosis:**
`handoffs/WF03-ISS0279-20260822/step-01-issue-fixer.json` (`result.summary`)

## 0. Problem recap (from ISSUE-FIXER's diagnosis)

Two missing mechanical enforcement points:

- (a) `docs/agents/workflows/WF-03_issue_resolving.md` Step 5 already tells `ISSUE-FIXER`
  to run `gh issue close <n> --comment "..."`, but this is prose only — nothing checks,
  after the fact, that a closed GitHub issue actually carries evidence.
  `docs/agents/protocols/ISSUE_QUEUE.md` has no close procedure at all (it only covers
  filing).
- (b) No periodic/mechanical audit re-scans already-closed issues. GH#324 and GH#326
  were both closed 2026-08-20 with zero comment and no linked/merged PR, and were caught
  only by a manual reconciliation run (`WF03-ISS0278-20260822`), by chance.

This design covers both surfaces: (1) hardened doc prose making evidence-on-close a
**hard** requirement, and (2) `mix letflow.audit_issue_closures`, a new `Mix.Task`
modeled structurally on `lib/mix/tasks/letflow.lint_handoffs.ex`.

---

## 1. Doc prose changes

### 1.1 `docs/agents/workflows/WF-03_issue_resolving.md` — Step 5

Replace the current step-2 bullet (lines 168–179 today) with wording that states the
requirement as a hard rule rather than an instruction to follow:

> 2. **Evidence-on-close is a HARD requirement, not agent discretion.** If `github_issue`
>    is set and `gh` is reachable: `gh issue close <n> --comment "<...>"`. **A GitHub
>    issue close is only valid if it carries EITHER (i) a `--comment` citing the
>    resolving evidence, OR (ii) a genuinely linked/merged PR with a `Closes`/`Fixes`
>    reference in its own GitHub timeline (`closedByPullRequestsReferences` non-empty).**
>    Closing without either is not a smaller version of this step done correctly — it is
>    this step **not done**, full stop, exactly as if `docs/issues/ISS-NNNN.yaml` had
>    been left at `status: open`. `mix letflow.audit_issue_closures` (§2 below) is the
>    mechanical check that catches a violation of this rule after the fact — this step's
>    own prose compliance is necessary but not sufficient; the audit tool is what makes
>    it durable.
>
>    The comment BRANCHES ON THE STATUS — it is published to an external audience, so it
>    must claim only what the run actually did:
>      resolved     -> "Fixed in <run-id>. See docs/issues/ISS-NNNN.yaml and the
>                       regression test at <test file path>."
>      instrumented -> "Investigated in <run-id>; verified work shipped but the root
>                       cause is NOT removed. See docs/issues/ISS-NNNN.yaml and the
>                       successor issue <ISS-NNNN>."
>      no_defect    -> "Investigated and measured in <run-id>; no defect found and
>                       nothing was changed. No fix was made and there is no
>                       regression test. See docs/issues/ISS-NNNN.yaml and the
>                       diagnosis handoff at <handoff path>."
>    Never claim a fix or cite a regression test on a non-`resolved` close. **Never close
>    a GitHub issue with no `--comment` at all in the belief that a "self-evident" fix
>    needs no explanation** — GH#324/GH#326 (`ISS-0279`'s own filing evidence) are the
>    concrete cost of that shortcut: a closure with no comment and no linked PR cannot
>    even be checked against its own stated reasoning, because it has none.

This is a drop-in replacement for the existing point 2 under "Step 5 — Close the issue";
point 1 (the `docs/issues/ISS-NNNN.yaml` status write) and point 3 (`PASS`,
`next_action`) are unchanged. Also add one sentence immediately after the existing
`## Step 5` output paragraph (after "not just marked done on an agent's say-so."):

> A GitHub-side close that skips both evidence forms is a Step 5 failure even when the
> local `docs/issues/ISS-NNNN.yaml` write is otherwise correct — the two halves of this
> step are both mandatory, not the yaml write alone.

### 1.2 `docs/agents/protocols/ISSUE_QUEUE.md`

This file currently documents filing only. Add a new top-level section immediately
after "## Issue status vocabulary" (before "## Picking up a queued issue later"),
titled `## Closing an issue's GitHub mirror — evidence is mandatory`:

> ## Closing an issue's GitHub mirror — evidence is mandatory
>
> `WF-03_issue_resolving.md` Step 5 owns the close procedure itself; this section states
> the rule that procedure implements, so a reader who lands here first (e.g. via a
> cross-reference from a filing) doesn't have to guess whether it's optional.
>
> **A `gh issue close` on any issue this protocol tracks — and any local status flip to
> a terminal value (`resolved` / `instrumented` / `no_defect`) — MUST carry either:**
>
> 1. a `--comment` on the GitHub issue citing the resolving evidence (the run-id, the
>    `docs/issues/ISS-NNNN.yaml` record, and — for `resolved` only — the regression test
>    path), or
> 2. a genuinely linked/merged PR with a `Closes`/`Fixes` reference recorded in the
>    issue's own GitHub timeline (visible as a non-empty
>    `closedByPullRequestsReferences` in `gh issue view --json`).
>
> A closure carrying neither is **undocumented, not merely under-documented** — it
> cannot be checked against its own reasoning after the fact, because it states none.
> This is not a hypothetical: GH#324 and GH#326 were both closed 2026-08-20 this way,
> and the gap went undetected until an unrelated reconciliation audit
> (`WF03-ISS0278-20260822`) caught it by chance (see `docs/issues/ISS-0279.yaml` — filed
> from that finding).
>
> `mix letflow.audit_issue_closures` (`lib/mix/tasks/letflow.audit_issue_closures.ex`)
> mechanically re-checks every closed, `github_issue`-linked entry in `docs/issues/` for
> this rule. It is a **standalone, on-demand tool** — see its own `@moduledoc` for why it
> is not wired into `mix letflow.check` — run it periodically (e.g. as part of a
> reconciliation pass) rather than relying on Step 5's prose compliance alone.

---

## 2. `mix letflow.audit_issue_closures`

### 2.1 Resolved design questions (both were explicitly left open by ISSUE-FIXER)

**Q1 — does this tool assume live GitHub network access, and if so how is that
documented?**

**Resolved as (a): the tool requires the `gh` CLI plus live network access to
`github.com`, and is documented plainly as a LOCAL/ON-DEMAND-ONLY check — never silently
assumed to run in a sandboxed/offline agent environment.**

Rationale:
- Confirmed (per ISSUE-FIXER's own check, re-confirmed here): this repository has **no**
  `.github/workflows` directory. `mix letflow.check` is the substitute enforcement point
  in place of CI, per `ISS-0257`'s own resolution note.
- Every existing step already wired into `letflow.check`
  (`letflow.check_toolchain`, `letflow.check_requirements_registration`,
  `letflow.check_deferral_staleness`, `letflow.lint_handoffs`, `format
  --check-formatted`, `compile --warnings-as-errors`, `letflow.check.test`) reads only
  local state: the filesystem, `git log`/`git merge-base` history, and the compiled
  project. **None of them makes a network call.** `mix letflow.check` is therefore an
  implicit but load-bearing invariant today: it passes or fails purely from repo state,
  with no dependency on network reachability, auth tokens, or a third-party service's
  uptime. A tool that shells to `gh issue view` breaks that invariant the moment it's
  added to the same alias.
- README's own "Notes" section already documents environments where `mix deps.get` has
  no network access — i.e., a no-network agent environment is a real, expected case in
  this project, not a hypothetical.
- A `gh`-dependent check therefore MUST NOT be silently assumed to run wherever
  `letflow.check` runs. It is documented here, in its own `@moduledoc`, and in
  `ISSUE_QUEUE.md` §1.2 above, as local/on-demand only: an agent (or human) runs
  `mix letflow.audit_issue_closures` deliberately, when `gh` and network are known to be
  available, the same way `git push`/`gh pr create` are already deliberate, network-using
  actions this pipeline performs outside of `letflow.check`.
- A locally-cached JSON export (alternative (ii) from the task brief) was considered and
  rejected for the initial design: it would need its own refresh mechanism, its own
  staleness detection, and would only move the "when do we have live data" question
  one level down rather than answering it. Nothing in the current pipeline maintains such
  a cache today, and the diagnosis found no existing precedent to reuse (H6's git-history
  floor is a different mechanism — it reads local git objects, not a cache of external
  API state). Out of scope for this design; revisit only if a concrete need for offline
  operation of this specific tool emerges.

**Q2 — should this tool be wired into `letflow.check`?**

**Resolved: NO. It stays a standalone, manually/periodically invoked task
(`mix letflow.audit_issue_closures`), not part of the `letflow.check` alias.**

Rationale:
- Per Q1, `letflow.check` is currently 100% network-independent. Folding a
  network-dependent step into it unconditionally would make the alias — and therefore
  every offline `mix letflow.check` run, including in a sandboxed agent environment with
  no GitHub reachability — **spuriously fail** for a reason unrelated to the code being
  checked. That is strictly worse than the status quo: a gate that fails on a sandboxed
  machine every time trains agents to treat its failures as noise, undermining the other,
  legitimate checks bundled in the same alias.
- A "gracefully skip when `gh` is unavailable" variant was considered and rejected for
  this alias. A hard gate that silently no-ops under a common, undetectable-in-advance
  condition (no network) is not a gate — an agent running `letflow.check` in a sandbox
  would see green and have no signal that the closure-evidence check never actually ran.
  That silent-pass failure mode is arguably worse than not having the check wired in at
  all, because it manufactures false confidence rather than an honest absence.
- Unlike `letflow.lint_handoffs` (ISS-0257's precedent for wiring an existing tool into
  the gate), this tool's blast radius is **external GitHub state**, not repo files a PR
  branch might change — there is no equivalent "verify it's green against every open PR's
  new content" mitigation available, because the check's very ability to run depends on
  something outside version control.
- This does not weaken enforcement in practice: `docs/agents/workflows/WF-03_issue_resolving.md`
  Step 5's hardened prose (§1.1 above) is the forward-looking gate that stops most new
  violations from being created (an agent following Step 5 correctly never produces a
  zero-evidence close in the first place); `mix letflow.audit_issue_closures` is the
  after-the-fact, periodic backstop for the case where Step 5 wasn't followed —
  analogous to how `WF03-ISS0278-20260822`'s reconciliation audit already served this
  role manually. Making that audit a repeatable command is the improvement this issue
  asks for; making it an unconditional CI-equivalent gate is not, given the network
  dependency.
- If a future run wants to explore wiring this in conditionally (e.g. an
  `only_if_network` variant, or a separate `letflow.check.remote` alias distinct from the
  offline-safe `letflow.check`), that is a natural follow-up but is out of scope here —
  flag it as a possible future issue rather than deciding it by side effect of this
  design.

### 2.2 Module shape

`lib/mix/tasks/letflow.audit_issue_closures.ex`, `Mix.Tasks.Letflow.AuditIssueClosures`,
`use Mix.Task`. Structural template: `lib/mix/tasks/letflow.lint_handoffs.ex` (grandfather
list shape, hard/exit-code split, `@rule` divider printing, discovery-then-check-then-report
flow).

`@moduledoc` content (exact prose to write into the module):

> Implements ISS-0279: mechanically re-checks every GitHub issue this project tracks
> (via a `github_issue` field in `docs/issues/*.yaml`) that GitHub currently reports as
> `CLOSED`, and flags any such issue that carries **zero comments AND no genuinely
> linked/merged PR reference** as an undocumented closure — the pattern found in GH#324
> and GH#326 (`docs/issues/ISS-0279.yaml`), where a closure could not even be checked
> against its own reasoning because it stated none.
>
> ## This is a LOCAL/ON-DEMAND-ONLY check, not part of `mix letflow.check`
>
> This task shells out to the `gh` CLI and requires live network access to `github.com`.
> Unlike every step currently wired into `mix letflow.check` (which read only local
> filesystem/git state), this task's result depends on an external service's
> reachability and this host's `gh` authentication. **It is deliberately NOT part of the
> `letflow.check` alias** — folding a network-dependent check into an alias every agent
> runs, including inside sandboxed/offline environments with no GitHub reachability,
> would make that alias fail for reasons unrelated to the code under test. Run this task
> by hand or from a periodic reconciliation pass, not as a blocking pre-merge gate. See
> `lib/letflow/design/iss0279-issue-closure-audit.md` §2.1 for the full rationale
> (including why a graceful-skip-when-`gh`-unavailable variant was rejected rather than
> silently wired in).
>
> ## What counts as a violation
>
> A tracked issue (any `docs/issues/*.yaml` entry with a non-nil `github_issue: <n>`
> field) whose live GitHub state is `CLOSED`, where **both**:
>
>   * `comments.totalCount` (or the length of the `comments` array, depending on which
>     `gh` reports) is `0`, and
>   * `closedByPullRequestsReferences` is empty (no linked/merged PR closed it).
>
> A closure with either a comment or a linked/merged PR is compliant, regardless of
> which — matching `ISSUE_QUEUE.md`'s "Closing an issue's GitHub mirror" section and
> `WF-03_issue_resolving.md` Step 5's hardened wording.
>
> ## Checks
>
> ### Hard (exit non-zero on any un-grandfathered violation)
>
>   * **ZERO_EVIDENCE** — as defined above.
>
> A violation on an issue number not in this module's `@grandfathered` list is a **new**
> regression and fails the run. A violation on a grandfathered issue number is reported
> (the debt stays visible) but does not fail the run — each grandfathered number is
> listed individually, dated, and traced to the run that discovered it, per
> `letflow.lint_handoffs`'s own "no blanket suppression" convention (ISS-0190). This
> module contains no wildcard or pattern-based grandfathering.
>
> ## What this task deliberately does NOT check
>
> Whether a `--comment`'s or a linked PR's *content* is actually good evidence (e.g.
> whether the comment's claim is even true, or whether the linked PR's diff plausibly
> addresses the issue). That is not mechanically decidable from the GitHub API response
> this task reads; it only checks that evidence of *some* form is present at all, exactly
> as `WF-03_issue_resolving.md` Step 5's hard requirement is worded. A separately
> discovered pattern of *false* evidence (an issue closed with a self-contradicting
> comment) is `ISS-0277`/`GH#548`'s concern, not this one.
>
> ## Usage
>
>     mix letflow.audit_issue_closures
>
> Requires `gh` on `PATH`, authenticated, with network access to `github.com`. Exits
> non-zero (`Mix.raise/1`) iff (a) at least one un-grandfathered `ZERO_EVIDENCE`
> violation exists, or (b) `gh` itself could not be run for a tracked issue (missing
> binary, auth failure, network error) — a failure to complete the audit is reported
> distinctly from a completed audit finding violations, but both are non-zero, so a
> caller cannot mistake "couldn't check" for "checked, all clean." See §"Exit codes and
> report format" below for the distinction in output.

### 2.3 CLI shape

No flags for the initial design — matches `letflow.lint_handoffs`'s own zero-argument
shape (`mix letflow.lint_handoffs`). `@impl Mix.Task` `run(_args)` ignores arguments.
(An `--issue N` single-issue filter is a plausible later convenience but is not required
by ISS-0279's acceptance criteria and is left as a documented open extension, not a
present flag, so this task's initial surface matches exactly what's specified.)

### 2.4 Data flow

1. **Discovery** — `@spec tracked_issues(dir :: String.t()) :: [%{ref: String.t(), number: integer(), path: String.t()}]`.
   `Path.wildcard("docs/issues/*.yaml")`. **No YAML-parsing dependency exists in this
   project** (confirmed: `mix.exs` has no `yaml_elixir`/similar dep, and
   `lib/mix/tasks/letflow.check_requirements_registration.ex` — this codebase's own
   precedent for reading a `docs/*.yaml` file from a Mix task — does it with `File.read/1`
   plus line-oriented `Regex` matching, not a YAML library). `docs/issues/*.yaml` is a
   much simpler flat-record shape than `docs/requirements.yaml` (one `key: value` pair per
   line, no nested lists needed for the two fields this task reads), so this task follows
   the same convention at a smaller scale: read each file with `File.read!/1`, split into
   lines, and extract `id:` (the `ISS-NNNN` ref) and `github_issue:` (an integer or
   absent) with two small anchored regexes (e.g. `~r/^id:\s*(\S+)/m` and
   `~r/^github_issue:\s*(\d+)/m`), mirroring `check_requirements_registration.ex`'s own
   `@id_line_re`/`@field_form_re` style. Skip entries where `github_issue` doesn't match
   (no GitHub mirror to audit). Reject/report (not crash) a file `id:` fails to match, the
   same discovery-completeness posture `letflow.lint_handoffs` takes with H6's
   `:non_json` branch.

2. **Live fetch, one `gh` call per tracked issue** —
   `@spec fetch_issue(number :: integer()) :: {:ok, map()} | {:error, term()}`.

       gh issue view <number> --json number,state,comments,closedByPullRequestsReferences

   Decoded with `Jason.decode/1` (already a runtime dep, per `letflow.lint_handoffs`'s
   own precedent for why this must be a Mix task and not a shell script). Fields
   consulted from the decoded map:
     - `"state"` — `"CLOSED"` vs. `"OPEN"`; only `"CLOSED"` issues are checked at all.
     - `"comments"` — an array; violation candidate iff this array is empty. (If the
       installed `gh` version instead returns an object with a `totalCount`, ELIXIR-DEV
       reads whichever shape the installed `gh --version` actually emits — the design
       intent is "issue has zero comments," not a specific JSON shape; state the actual
       observed shape in the module's implementation comment.)
     - `"closedByPullRequestsReferences"` — an array; violation candidate iff this array
       is also empty (i.e., only a `CLOSED` issue with **both** empty is a violation).
   A single-issue `gh` call (rather than one batched `gh issue list --search ...`) is
   chosen because the set of tracked numbers is sparse and comes from local file
   discovery, not from a GitHub-side query — mirrors ISSUE-FIXER's own "or equivalent"
   framing in the diagnosis, and keeps each issue's fetch independently retriable/
   reportable, the same per-item posture `letflow.lint_handoffs` takes shelling `git`
   per file for H6.

3. **Per-issue classification** — `@spec classify(map()) :: :ok | :violation | :not_closed`.
   `"state" != "CLOSED"` → `:not_closed` (not audited further — an open issue has nothing
   to evidence yet). `"CLOSED"` with `comments == []` and `closedByPullRequestsReferences
   == []` → `:violation`. Anything else `:ok`.

4. **Grandfather split, report, exit** — same two-list split as `letflow.lint_handoffs`'s
   `hard_new`/`hard_grandfathered`, keyed by GitHub issue number (see §2.5).

### 2.5 Grandfather-list format (mirrors `letflow.lint_handoffs`'s own convention exactly)

    # -- Individually-named pre-existing ZERO_EVIDENCE closures. Populated by
    # ELIXIR-DEV from this task's own first real run against the corpus (see
    # lib/letflow/design/iss0279-issue-closure-audit.md §2.6 for the population
    # procedure). No wildcards, no number ranges: every entry below is one exact
    # GitHub issue number this task actually found violating, on the date measured.
    # A NEW closure hitting the same rule is NOT covered by this list and fails the
    # build -- grandfathering is per-issue, never per-rule or per-range.
    #
    # GH#324 and GH#326 are deliberately NOT here: both were reconciled with real
    # evidence by WF03-ISS0278-20260822 (see docs/issues/ISS-0096.yaml and
    # ISS-0098.yaml) before this task's first run, so they no longer violate
    # ZERO_EVIDENCE and must not be grandfathered as if they still did.
    @grandfathered [
      # {issue_number, "YYYY-MM-DD", "note"} -- one tuple per pre-existing violation.
      # Example shape only -- ELIXIR-DEV populates the real entries; see §2.6.
      # {488, "2026-08-22", "closed with no comment, no linked PR; pre-dates this tool"}
    ]

    @spec grandfathered?(pos_integer()) :: boolean()

`grandfathered?/1` takes a GitHub issue number and returns whether it appears as the
first element of any tuple in `@grandfathered` — i.e. whether this specific issue
number's `ZERO_EVIDENCE` violation is a known pre-existing one rather than a new
regression.

This is the same shape as `letflow.lint_handoffs`'s `@grandfathered` (a literal list of
tuples, each one exact, dated, and traced), adapted from `{rule, path}` to
`{issue_number, date, note}` since this task has exactly one hard rule (`ZERO_EVIDENCE`)
rather than several — a `rule` slot in each tuple would be redundant here, unlike
`letflow.lint_handoffs`, which needs it to disambiguate `H1`/`H2`/`H3` violations on the
same path.

### 2.6 How ELIXIR-DEV populates the initial grandfather list

A fresh scan is out of scope for this design step. When ELIXIR-DEV implements this
module:

1. Implement the module with `@grandfathered []` (empty).
2. Run `mix letflow.audit_issue_closures` for real against the current corpus (requires
   `gh` reachable — if it is not reachable in ELIXIR-DEV's own environment, state that
   explicitly and hand the empty-grandfather-list version to REVIEWER/TEST-RUNNER with a
   note that population is still pending network access, rather than guessing entries).
3. Every issue number the real run reports as a violation gets one dated, individually
   named `@grandfathered` entry (per §2.5's shape) — **except** GH#324 and GH#326, which
   must NOT be grandfathered: both were reconciled with real evidence by
   `WF03-ISS0278-20260822` (see `docs/issues/ISS-0096.yaml`/`ISS-0098.yaml`'s
   `resolved_in_run`/comment trail) before this tool's first run, so a correct run
   against live GitHub state should no longer report them as violations at all — if it
   *does* still report either of them, that is itself a new finding to surface (the
   GitHub-side comment/PR-reference may not have landed as expected), not something to
   paper over by grandfathering.
4. Re-run after populating; a clean, expected (zero new violations) run is the evidence
   this step is done — quote the actual `mix letflow.audit_issue_closures` output in the
   implementation handoff's `result.summary`, per this project's No Speculation rule.

### 2.7 Exit codes and report format

Mirrors `letflow.lint_handoffs`'s `@rule`-divided stdout sections and `Mix.raise/1`
exit-non-zero convention:

    ========================================================================
    NEW HARD VIOLATIONS (fail the build):
      [ZERO_EVIDENCE] GH#<n> (docs/issues/ISS-NNNN.yaml): closed with 0 comments and
        no linked/merged PR reference
    ========================================================================
    GRANDFATHERED (pre-existing, dated, do not fail the build):
      [ZERO_EVIDENCE] GH#<n> (docs/issues/ISS-NNNN.yaml, grandfathered <date>): <note>
    ========================================================================
    FETCH ERRORS (audit incomplete for these issues -- not counted as pass or fail):
      GH#<n> (docs/issues/ISS-NNNN.yaml): gh error -- <reason>
    ========================================================================
    letflow.audit_issue_closures: FAIL -- <k> new violation(s), <e> fetch error(s).
    ========================================================================

or, on a fully clean run:

    ========================================================================
    letflow.audit_issue_closures: OK -- 0 new violations across <n> tracked, closed
      GitHub issues (<g> pre-existing grandfathered).
    ========================================================================

Exit semantics (`@impl Mix.Task` `run/1`):
  - Any `FETCH ERRORS` entry (gh missing/unauthenticated/network failure) →
    `Mix.raise/1` — the audit did not complete, so it must not silently report success.
    This is the direct, designed consequence of §2.1's Q1 decision: rather than treating
    "no network" as an implicit skip, the task fails loudly and explains why, so a human
    or agent invoking it on-demand gets an unambiguous signal to fix reachability and
    re-run — never a false green.
  - Else, any un-grandfathered `ZERO_EVIDENCE` violation → `Mix.raise/1`.
  - Else → `:ok` (prints the OK summary line, matching `letflow.lint_handoffs`'s own
    "OK -- 0 new violations..." phrasing convention).

---

## 3. Cross-module dependencies

- `docs/issues/*.yaml` (read-only) — read via `File.read!/1` + line-oriented `Regex`,
  the same convention `lib/mix/tasks/letflow.check_requirements_registration.ex` already
  uses for `docs/requirements.yaml`; no YAML-parsing library exists in this project.
- `gh` CLI (external, invoked via `System.cmd/3`) — same invocation style
  `letflow.lint_handoffs` already uses for `git`.
- `Jason` — already a runtime dependency (per `letflow.lint_handoffs`'s own
  `@moduledoc` note on why this must be a compiled Mix task).
- No dependency on `letflow.check`/`mix.exs`'s `aliases/0` — deliberately not added
  there, per §2.1 Q2.
- No dependency on `letflow-queue`/`TASK_QUEUE.md` — this tool reads `docs/issues/*.yaml`
  and live GitHub state directly; it does not call the queue service.

## 4. Invariants

- I1: a `CLOSED` tracked issue with a non-empty `comments` array is never a violation,
  regardless of `closedByPullRequestsReferences`.
- I2: a `CLOSED` tracked issue with a non-empty `closedByPullRequestsReferences` is never
  a violation, regardless of `comments`.
- I3: grandfathering is per-issue-number, never per-rule, per-range, or wildcard (matches
  `letflow.lint_handoffs`'s H1–H4 convention; there is no H6-style commit-floor exception
  here because there is only one rule and no meaningful git-history analogue for external
  GitHub state).
- I4: a fetch failure for one issue never suppresses or skips checking the rest — it is
  collected and reported alongside violations, and both classes independently force a
  non-zero exit.
- I5: `mix letflow.check` remains network-independent; this task is never invoked from
  `aliases/0`.

## 5. Open questions

None outstanding for this design — both questions ISSUE-FIXER flagged as unresolved
(§2.1 Q1, Q2) are resolved above with stated rationale, per this handoff's acceptance
criteria. One deliberately-deferred (not blocking) extension is noted in §2.3: a
single-issue `--issue N` CLI filter, left for a future run if the need arises.
