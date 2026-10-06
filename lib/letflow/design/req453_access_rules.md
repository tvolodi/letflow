# REQ-453 -- Design: access rules for BA-<VERTICAL>, UAT-RUNNER and PRODUCT-OWNER

Stage S7. Run `WF02-REQ453-20261006` (Q-970, GH#2242). Status: design only. Builder: ELIXIR-DEV
(decided; the change is instruction text only, no `.ex`/`.exs`). SECURITY-REVIEWER is not routed for
this diff: it is instruction text with no tenant-data path, and REVIEWER checks that scope. Depends on REQ-445
(`docs/roles.md`), REQ-452 (roster, `expect_refusal`, SCHEMA-7..12), both merged on this branch.

No application code. Every "Exact text" block below is prose instruction text to be pasted into a
markdown file, not code. Text in `>` blocks is the literal text to insert (leading `>` is not part
of it).

## 0. Verification greps (run on the branch worktree; every name the new text uses)

| Name used in new text | Where it exists on the branch | Result |
|---|---|---|
| `test/fixtures/uat/actors.yaml` | file, 133 lines | EXISTS. Keys: `actors:`, `unresolved:`, `platform_actor_allowed:`, `refusal_coverage_exempt: [bilimbaga, meridian, platform, swiftroute, vortex]`, `legacy_platform_admin: {}` |
| `refusal_coverage_exempt` | `test/fixtures/uat/actors.yaml`; `docs/agents/uat-scenario-schema.md:260,341-348`; `lib/mix/tasks/letflow.check_uat_scenario_schema.ex:53,108,607,835,848` | EXISTS |
| `expect_refusal` | `docs/agents/uat-scenario-schema.md:285-305`; `lib/mix/tasks/letflow.check_uat_scenario_schema.ex:55,203,481-492,564-570` | EXISTS as an optional boolean step key. NO scenario file uses `expect_refusal: true` yet (grep of `test/fixtures` found none; all 5 scopes are exempt) |
| `builtin_roles` | `test/fixtures/uat/actors.yaml` every actor entry; SCHEMA-8 | EXISTS |
| `CREDENTIALS_MISSING` | `.claude/agents/uat-runner.md:174,221`; `docs/agents/workflows/WF-05_uat_run.md:94`; `.claude/agents/product-owner.md:125` | EXISTS |
| `BLOCKED` / `ENV_NOT_READY` | `.claude/agents/uat-runner.md:172-177`; WF-05 Step 0 | EXISTS |
| `domain_issues` (plural, a list) | `.claude/agents/ba-analyst.md:144`; `.claude/agents/product-owner.md:91,218`; all 9 `test/uat-reports/ba-signoff-*.yaml` | EXISTS |
| `domain_issue` (singular, as typed in REQ-453) | nowhere as a key | DOES NOT EXIST as a field name. The design uses `domain_issues` (an entry of that list). REQ-VALIDATOR must not grep the singular as a key. See section 9 D2 |
| `suggested_action` values on the branch | `route_to_wf03` (9 uses), `route_to_req_analyst` (10), `none` (1) in existing ba-signoff files; schema lists `route_to_wf03 \| route_to_req_analyst \| none` | EXISTS. `route_to_security_review` does NOT exist anywhere yet: it is a NEW value added by this requirement (grep of docs, .claude, lib, test: zero hits) |
| `access_verdict`, `access_note` | zero hits anywhere | NEW fields added by this requirement |
| `SECURITY-REVIEWER` | `.claude/agents/security-reviewer.md` | EXISTS. Its scope test is about code diffs (tenant-data path), not run observations. It is NOT edited by REQ-453 (see section 9, D4) |
| `docs/roles.md` | file, 114 lines, 8 roles incl. TENANT_ADMIN, TENANT_AUDITOR | EXISTS |
| `docs/migration/decisions/0046-admin-scopes-and-role-charter.md` | file | EXISTS (D1 two scopes, D4 PLATFORM_ADMIN platform-only, D10 closed role set) |
| `PLATFORM_ADMIN`, `TASK_WORKER`, `TENANT_ADMIN`, `TENANT_AUDITOR`, `PROCESS_DESIGNER`, `PROCESS_OPERATOR`, `CANDIDATE`, `AGENT_RUNNER` | `docs/roles.md` | EXISTS. NOTE: `TENANT_ADMIN`/`TENANT_AUDITOR` are TARGET state (REQ-446..448 pending); `Letflow.Api.Authorization.roles/0` has six today. Text must say "least built-in role listed in `docs/roles.md`" |
| `test/uat-reports/ba-signoff-<vertical>-<run_id>.yaml`, `po-signoff-<run_id>.yaml`, `uat-<date>-<run_id>.yaml` | `test/uat-reports/` | EXISTS |
| `docs/agents/ba-personas/<vertical>.yaml`, key `authority_boundaries.does_not_decide` | `docs/agents/ba-personas/bilimbaga.yaml:63` | EXISTS. That file does NOT contain the words "cross-tenant"; only the schema table row in `ba-analyst.md:109` and the Forbidden bullet at `ba-analyst.md:198-201` do |
| `docs/agents/ORCHESTRATOR.md` section 3 decision tree WF-05 branch | `ORCHESTRATOR.md:110-118` | EXISTS |
| `seed_swiftroute_persona_actors` in `uat-runner.md` | `uat-runner.md:210` | EXISTS and is asserted by `test/letflow/scripts/seed_swiftroute_persona_actors_test.exs` TC-0761-05. The edit MUST keep that substring |

## 1. Checkers and tests that touch these files (constraints on wording)

- `mix letflow.check` alias (`mix.exs:149+`) runs: check_toolchain, check_requirements_registration,
  check_req_id_collision, check_deferral_staleness, lint_handoffs, check_async_sandbox_reachability,
  check_issue_refs, check_uat_scenario_schema, format check, compile, check_boundaries, check.test.
  NONE of them parse `.claude/agents/*.md`, WF-05, ORCHESTRATOR.md, or `ba-signoff-*.yaml`.
  `check_issue_refs` scans for issue-id formats (ISS-nnnn / queue ids) in docs: do not write a bare
  malformed ISS/Q reference in the new text. Use no ISS/Q ids at all in the new text (also keeps the
  BA language rule intact in the sign-off examples).
- `test/letflow/scripts/seed_swiftroute_persona_actors_test.exs` TC-0761-05 reads
  `.claude/agents/uat-runner.md` and asserts it contains `seed_swiftroute_persona_actors`. Do not
  remove or reword that paragraph (`uat-runner.md:197-225`).
- `test/mix/tasks/letflow_check_uat_scenario_schema_test.exs:33` mentions uat-runner.md's
  "Evaluating a `when:` branch" heading only in a comment; keep that heading unchanged.
- `check_uat_scenario_schema` (SCHEMA-7..12) validates scenarios and `actors.yaml`, not the agent
  text. The new BA rules mirror it: rule (a) = SCHEMA-7/9/10 intent, rule (b) = SCHEMA-11 intent.
  Because those rules are mechanical, the BA text says "the checker enforces X; you must also do Y".
- No checker validates the sign-off YAML schema (`access_verdict` is therefore enforced by text and
  by PRODUCT-OWNER only; no checker is built here, see section 9 D5).
- Governance-surface rule (`ORCHESTRATOR.md:218-232`, `AGENT_SYSTEM.md` section 9): `.claude/agents/*.md`,
  WF-*.md and ORCHESTRATOR.md may be edited only through the full REQ-ANALYST -> ... -> REVIEWER
  chain. REQ-453 is that chain; the builder must not be ORCH acting alone.
- `docs/agents/instructions/core-directives.md` "Load Scoped Context": the new text must not tell any
  role to read all of `docs/requirements.yaml`. It does not.
- Edit restrictions from the handoff: only ADD lines in ORCHESTRATOR.md / AGENT_SYSTEM.md /
  CLAUDE.md; do not touch WF-01..04, core-directives, protocols/, security-invariants.md,
  pull_request_template.md. AGENT_SYSTEM.md and CLAUDE.md need no edit (no new role, no new file).

Tests/checks that cover the final result: `mix letflow.check` (must pass; only the formatting/compile
gates are even indirectly relevant, none read these files), the TC-0761-05 test above, and
REQ-VALIDATOR's grep of every name in section 0. No new test is required for a text-only change.

## 2. Terms used by every file (define once, quote identically)

- ACCESS FINDING: a run observation of either (i) a person seeing data of another organisation, or
  (ii) a person doing something outside their job.
- Least role: the built-in role in `docs/roles.md` with the fewest permissions that still lets a person
  in that job perform the scenario's steps. The role names are exactly the headings of `docs/roles.md`.
- Roster: `test/fixtures/uat/actors.yaml`.

## 3. File 1: `.claude/agents/ba-analyst.md`

### 3.1 New Mandatory-reading bullets (append two bullets after the `uat-scenario-schema.md` bullet)

> - `test/fixtures/uat/actors.yaml` -- the actor roster: which login actors exist and which built-in
>   roles each holds. Read it before you author or sign off a scenario.
> - `docs/roles.md` -- the eight built-in roles, what each does and must not do.

### 3.2 New section `## Access and roles`, inserted immediately BEFORE `## Sign-off artefact`

Exact text (one rule per bullet; the four rules (a)-(d) are separate bullets under four bold run-in
headings, each its own bullet as AC1 requires):

> ## Access and roles
>
> These rules apply to authoring AND to sign-off. They use the words "actor" (a login named in a
> scenario's `actors:` map), "role" (one of the eight built-in roles in `docs/roles.md`), and
> "roster" (`test/fixtures/uat/actors.yaml`).
>
> - **(a) Use only roster actors, with the least role.**
>   - Use only actors that have an entry under `actors:` in the roster. If you need an actor that
>     is not there, do not invent an actor id and do not author or sign off that scenario. Complete
>     your handoff with `status: blocked` and a `blocked` note that names the missing actor id and
>     the scenario file; ORCH adds the actor to the roster.
>   - Give each actor the least built-in role that lets a person in that job do the scenario's
>     steps. Choose it from `docs/roles.md`. Read each role's "Does" and "Must not" lines.
>   - Never give a tenant person `PLATFORM_ADMIN`. `PLATFORM_ADMIN` is only for staff of the
>     organisation that operates Letflow, and only in `scope: platform`.
>   - Never write a role into a scenario's prose. Prose names the job ("the credit manager"), not
>     the role ("TASK_WORKER").
> - **(b) Write refusal steps.**
>   - Every set of scenarios you author for your vertical must include at least one step with
>     `expect_refusal: true` for each sensitive action your vertical has.
>   - The sensitive actions are exactly this CLOSED list: approving, paying or releasing, seeing personal
>     or commercially sensitive data, changing users. Do not add other actions to the list and do not drop any. If your vertical has
>     none of these four, say so in the scenario file's header comment.
>   - Write the refusal step's `action:` in business language, as a person trying something they
>     are not allowed to do. Correct: "The warehouse clerk tries to approve the supplier invoice."
>     Forbidden: "POST the approval as TASK_WORKER and expect 403."
>   - Pick as the actor a person whose job does not include that action.
>   - The checker (`mix letflow.check_uat_scenario_schema`, rule SCHEMA-11) only demands ONE
>     refusal step per scope. That is the minimum, not your target. Your target is one per
>     sensitive action.
> - **(c) Report, do not decide.**
>   - If a run shows any person seeing another organisation's data, or doing something outside
>     their job, write a `domain_issues` entry with `severity: BLOCKER` and
>     `suggested_action: route_to_security_review`.
>   - Describe what the person saw or did in business language. Do not say whether it is a defect,
>     a bug, or a security flaw. Do not say it is acceptable. Do not say "probably".
>   - Do this even when it is not your vertical's data, and even when the scenario passed.
>   - Correct: "The Vortex shift planner, signed in for Vortex, could open an order that belongs
>     to a different company." Forbidden: "This looks like a minor test-data quirk, not a leak."
>   - Set `access_verdict: FAIL` in the sign-off (see the Sign-off schema).
> - **(d) Never widen a role.**
>   - If a step is blocked because the actor lacks permission, record the block. Do not change
>     the actor, do not give the actor a stronger role, do not edit the roster, do not swap in a
>     different actor, and do not reword the step to make it pass.
>   - Record the block as a `domain_issues` entry with `severity: MAJOR` and
>     `suggested_action: route_to_wf03`, describing what the person could not do and why
>     their job needs it. ORCH files an issue from that entry.
>   - Correct: "The dispatcher could not release a shipment, which is part of the dispatcher's
>     daily job." Forbidden: "Changed the dispatcher to an administrator so the scenario passes."
>   - A block on a step marked `expect_refusal: true` is the expected result, not a finding.
>
> **How the access rules fill the sign-off.** Set `access_verdict` as follows, then write
> `access_note`:
>
> - `FAIL`: any access finding under rule (c), or a refusal step that UAT-RUNNER recorded as
>   succeeding.
> - `PASS`: no access finding, at least one `expect_refusal: true` step in your scope was run and
>   refused, AND none of your scope's refusal steps is BLOCKED.
> - `NOT_COVERED`: everything else. That is: no access finding and no refusal step succeeded, but
>   either no refusal step exists or was run in your scope (for example your scope is in the roster's
>   `refusal_coverage_exempt` list and has no refusal step yet), or at least one refusal step is
>   BLOCKED (mixed case: some refused and some BLOCKED is `NOT_COVERED`, never `PASS`).
> - Apply the three in this order: `FAIL` first, then `PASS`, else `NOT_COVERED`.
> - Also compare the role UAT-RUNNER observed for each actor with the roster (UAT-RUNNER reports it
>   per scenario). If they differ, set `access_verdict: FAIL` and write a `domain_issues` entry with
>   `severity: BLOCKER`, `suggested_action: route_to_security_review`, saying in business language
>   that the person held more (or different) access than their job entitles.

### 3.3 Sign-off schema changes (section `### Schema`; locate the YAML block by its content, `report_id: ba-signoff-`, not by line number)

Insert after the `domain_verdict:` line (these are schema lines inside the existing yaml fence,
documentation not executable code):

> access_verdict: PASS | FAIL | NOT_COVERED   # required; see "Access and roles"
> access_note: >                                # required; exactly ONE sentence, business language
>   <one sentence: what was checked about who may do what, and the result>

Change the `suggested_action:` line in `domain_issues` to:

> suggested_action: route_to_wf03 | route_to_req_analyst | route_to_security_review | none

Add directly below the yaml fence a rules list (one per bullet):

> - `access_verdict` is required in every sign-off. A sign-off without it is incomplete; PRODUCT-OWNER
>   treats a missing `access_verdict` as `NOT_COVERED`.
> - `access_note` is required and is exactly one sentence. It is subject to the Language rule.
> - Use `route_to_security_review` only for an access finding under "Access and roles" rule (c) or the
>   role mismatch. Use it with `severity: BLOCKER`.
> - Correct `access_note`: "The clerks were refused when they tried to approve payments, and no one
>   saw another company's records."
> - Forbidden `access_note`: "403 returned for TASK_WORKER on POST /api/v1/approvals."

### 3.4 Persona-data schema table row (current line 109), minimal amendment

Before:

> `authority_boundaries.does_not_decide` | list of strings | Always includes: platform-level cross-tenant issues, other verticals' business questions, technical implementation, NFR/latency compliance -- plus any vertical-specific exclusions

After (replace the "Always includes" list):

> Always includes: deciding whether a platform-level cross-tenant observation is a defect (you still REPORT it, see "Access and roles" rule (c)), other verticals' business questions, technical implementation, NFR/latency compliance -- plus any vertical-specific exclusions

(`docs/agents/ba-personas/bilimbaga.yaml` does not contain the old phrase; no persona file edit.)

### 3.5 Forbidden section: before and after (AC1 quote requirement)

BEFORE (current lines 198-201, verbatim):

> - Does not decide platform-level cross-tenant issues, other verticals' business
>   questions, technical implementation, or NFR compliance -- your persona file's
>   `authority_boundaries.does_not_decide` always includes these three, plus any
>   vertical-specific exclusions it states.

(The original uses a real em dash before "your persona file's"; copy the file's characters, not this ASCII form.)

AFTER (replace that bullet with these two bullets):

> - Does not decide other verticals' business questions, technical implementation, or NFR
>   compliance -- your persona file's `authority_boundaries.does_not_decide` always includes
>   these, plus any vertical-specific exclusions it states. "Does not decide" never means "does not
>   report": see the next bullet.
> - Never leaves an access finding unreported. If a run shows a person seeing another
>   organisation's data or doing something outside their job, you MUST record it as a BLOCKER
>   `domain_issues` entry with `suggested_action: route_to_security_review` (see "Access and roles"
>   rule (c)). You do not judge whether it is a defect, and you do not drop it because it is outside
>   your vertical or outside your authority.

Add two more bullets at the end of Forbidden:

> - Does not change an actor, an actor's role, or `test/fixtures/uat/actors.yaml` to make a step
>   pass (see "Access and roles" rule (d)).
> - Does not give a tenant person `PLATFORM_ADMIN` in any scenario (see rule (a)).

Also the "Sign-off artefact -> SIGN-OFF" paragraph under `## What you do` (current line 58-61) gets one
appended sentence: "The sign-off must contain `access_verdict` and `access_note`; see 'Access and roles'."

## 4. File 2: `.claude/agents/uat-runner.md`

### 4.1 New section `## Refusal steps and actor access`, inserted immediately BEFORE `## Forbidden`

> ## Refusal steps and actor access
>
> A step with `expect_refusal: true` (`docs/agents/uat-scenario-schema.md`, "Refusal step") means
> the named actor tries the action and the product is expected to refuse it.
>
> - Execute the step as the actor named on that step. Use that actor's own credential from
>   `credential_source`.
> - Attempt the action for real. Do not skip it, do not assume it would be refused, and do not read
>   the code to decide the outcome.
> - The step PASSES only if the product refuses. Refused means: the request is rejected with a
>   permission or not-found response, or the screen shows no control for the action AND opening the
>   action's page or link directly is also refused, or the screen shows a refusal message, AND you
>   queried back and confirmed that nothing was created, changed or revealed. A screen with no control
>   must not count alone (a hidden button can sit over a working server route). If the direct attempt
>   is not possible, record the step BLOCKED, not PASS.
> - The step FAILS with severity BLOCKER if the action succeeds, or if any part of the protected
>   data or effect is delivered. Do not reclassify it as MAJOR or MINOR.
> - A step that fails because of a broken environment (not a permission refusal; for example a
>   server error, a timeout, a login failure) does NOT pass. Record it BLOCKED/PRECONDITION_NOT_MET
>   or ENV_*, not PASS and not FAIL.
> - Record for the step: the actor, the action attempted, and what the actor saw (the response status
>   and message, or the screen text). Never record a token, password or secret.
> - Never substitute a stronger actor. If the named actor's account is missing, or does not hold the
>   role the roster lists, record the scenario BLOCKED/CREDENTIALS_MISSING, as for any missing
>   account. Do not use another actor's credential, an administrator's credential, or the
>   `QA_AUTH_TOKEN` to run the step. Correct: "BLOCKED/CREDENTIALS_MISSING: account for
>   actor-vortex-karl not found." Forbidden: "Ran step 4 as the platform admin because
>   karl's login was missing."
> - This no-substitution rule applies to every step, not only refusal steps. (Seed scripts that
>   need an administrator token are environment preparation done by ORCH, not a scenario step.)
>
> ### Role observed versus roster
>
> - For each actor you authenticate, observe the built-in role(s) actually held: the role claim in
>   the session or token, or the role attribute on the account (the same observation as the
>   `fact: role` rule in "Evaluating a `when:` branch").
> - Prefer the server's answer (`GET /api/v1/me/access` once REQ-449 is merged); until then use the
>   token claim and write `source: token_claim` in `actors_observed`.
> - Compare them with that actor's `builtin_roles` in `test/fixtures/uat/actors.yaml`.
> - Record the comparison per scenario in the report under `actors_observed`, one entry per actor:
>   `actor`, `roster_roles`, `observed_roles`, `match` (true or false). Actors listed under
>   `unresolved:` in the roster have no `roster_roles`: record `roster_roles: unresolved` and
>   `match: false`.
> - A mismatch is a finding, not a note. Add `access_mismatch` to the report's `observations` with the
>   actor and both role lists, and keep the scenario's own verdict as observed. Do not "fix" the
>   mismatch, do not change the account, and do not stop the run.
> - If `observed_roles` contains `PLATFORM_ADMIN` for an actor whose roster `tenant` is not `platform`,
>   state that in the observation in the first line.

### 4.2 Existing text amended (only additions)

- In `## What you do` (line 32-37) append: "For a step marked `expect_refusal: true`, follow 'Refusal steps and actor access' below."
- In `## Forbidden`, append a sentence (text addition only): "Don't run any step as a different actor than the one it names, and don't use a stronger credential to make a blocked step run."
- Keep paragraphs at lines 183-238 untouched (TC-0761-05).
- The current "Result classification" paragraph (172-177) needs no change: CREDENTIALS_MISSING is already BLOCKED-by-environment.

## 5. File 3: `.claude/agents/product-owner.md`

### 5.1 Mandatory reading: no change (ba-analyst.md is already listed and defines the fields).

### 5.2 New subsection in `## What you do`, after "### 3. MUST-coverage cross-check" and before
"### 4. Arbitration". It is numbered `### 3a. Access gate` to avoid renumbering:

> ### 3a. Access gate
>
> Read two fields from every BA sign-off in step 1: `access_verdict` and `access_note`.
>
> - If any sign-off has `access_verdict: FAIL`, `release_recommendation` MUST be `BLOCKED`.
> - If any sign-off has `access_verdict: NOT_COVERED` and its vertical is NOT in the
>   `refusal_coverage_exempt` list of `test/fixtures/uat/actors.yaml`, `release_recommendation` MUST be
>   `BLOCKED`. (Read that one key from the roster; do not read the rest of the file.)
> - If a sign-off has `access_verdict: NOT_COVERED` and its vertical IS in `refusal_coverage_exempt`,
>   do not block on it. Say in `release_rationale` that access to that vertical was not tested.
> - If a sign-off has no `access_verdict` field, treat it as `NOT_COVERED`.
> - `access_verdict: FAIL` cannot be overridden with `blocker_overrides` by you. An access BLOCKER
>   with `suggested_action: route_to_security_review` stays BLOCKED until ORCH reports that
>   SECURITY-REVIEWER has reviewed it and the issue is closed (see ORCHESTRATOR routing).
> - For each `domain_issues` entry with `suggested_action: route_to_security_review`, copy it into
>   your `issues` list with the same `suggested_action` so ORCH routes it to SECURITY-REVIEWER. Do not
>   diagnose it and do not judge whether it is a defect.
> - Platform-scope scenarios have no BA sign-off, so they have no `access_verdict`; this gate does not
>   apply to them (see step 1).
> - For platform-scope scenarios read the UAT report directly: any `expect_refusal` step recorded FAIL
>   makes `release_recommendation` BLOCKED, with the same no-override rule.

### 5.3 Schema changes (locate the YAML block by its content, `report_id: po-signoff-`, not by line number)

- Add under `ba_verdicts:` a sibling block:
  > access_verdicts:                     # one entry per BA-<VERTICAL> sign-off read
  >   <vertical-slug>: PASS | FAIL | NOT_COVERED
- Change `issues[].suggested_action` line to:
  > suggested_action: route_to_wf03 | route_to_req_analyst | route_to_uat_runner | route_to_security_review | none
- `release_recommendation` derivation list: insert as new item 3 (renumber 3->4, 4->5, 5->6):
  > 3. Any `access_verdicts[...]` == `FAIL`, or == `NOT_COVERED` for a vertical not in the roster's
  >    `refusal_coverage_exempt` list -> `BLOCKED`.

### 5.4 Forbidden: append

> - Approving a release (`release_recommendation: APPROVED`) when any BA sign-off has
>   `access_verdict: FAIL`, or `access_verdict: NOT_COVERED` for a vertical that is not in the
>   roster's `refusal_coverage_exempt` list
> - Judging whether an access finding is a defect (route it with `route_to_security_review`)

### 5.5 Language rule

`access_note` is copied into `release_rationale` only as plain-language prose. Correct: "One vertical
reported that a person could open another company's records, so the release is blocked until it is
reviewed." Forbidden: "BA-VORTEX access_verdict FAIL, route_to_security_review."

Also edit the single paragraph under `## Rework policy` (the one that begins "`max_rework: 1` --
if `PRODUCT-OWNER` blocks a release, ORCH routes to WF-03 (for BLOCKER/MAJOR issues) or WF-01 (for
requirement ambiguity routed to REQ-ANALYST), then re-runs the relevant WF-05 step."). Insert the
text " (or, for an issue with `route_to_security_review`, to SECURITY-REVIEWER)" immediately after
"WF-01 (for requirement ambiguity routed to REQ-ANALYST)" and before the comma that follows it. Change
nothing else in the paragraph. (There is no "Run-level exemption" note in product-owner.md.)

## 6. File 4: `docs/agents/workflows/WF-05_uat_run.md`, Step 4

Edit the numbered list in the Step 4 fenced block (locate it by content: the fenced block starting "1. Read every test/uat-reports/ba-signoff-") by ADDING, and you MAY modify the existing closing sentence (add-only applies to ORCHESTRATOR.md/AGENT_SYSTEM.md/CLAUDE.md only) after item 3:

> 3a. Apply the access gate: read `access_verdict` and `access_note` from every BA sign-off. The
>     recommendation is NOT `APPROVED` if any sign-off has `access_verdict: FAIL`, or
>     `access_verdict: NOT_COVERED` for a vertical that is not listed in `refusal_coverage_exempt`
>     in `test/fixtures/uat/actors.yaml`. A missing `access_verdict` counts as `NOT_COVERED`.
>     For platform-scope scenarios read the UAT report directly: any `expect_refusal` step recorded FAIL
>     makes `release_recommendation` BLOCKED, with the same no-override rule.

and extend the closing "FAIL (BLOCKED) -> route per each issue's `suggested_action`" sentence:

> (`route_to_wf03` / `route_to_req_analyst` / `route_to_uat_runner` / `route_to_security_review`); an issue
> with `route_to_security_review` is dispatched by ORCH to SECURITY-REVIEWER, never to WF-03 directly.

Also in Step 2-3 numbered list add item 3a (addition only): "3a. For a step with `expect_refusal: true`, follow `.claude/agents/uat-runner.md`'s 'Refusal steps and actor access'; record `actors_observed` per scenario."

Do not change the Overview diagram.

## 7. File 5: `docs/agents/ORCHESTRATOR.md` (ADD ONE line only)

Location: section 3 decision tree, in the `A running Letflow instance exists...` WF-05 branch is a
multi-line item; add the new line as its own sibling branch immediately BEFORE the final
`Does not match any standard workflow?` branch (line 120), so no existing line changes.

The ONLY text added to ORCHESTRATOR.md is this one physical line (decided; it uses the tree's `├─`
and `└─►` characters, with the `│` continuation prefix `│     ` of the neighbouring branches omitted
because it is one line). Insert it as a new line immediately before the line
`└─ Does not match any standard workflow?`, with exactly these characters:

> ├─ A BA sign-off or PRODUCT-OWNER issue has suggested_action route_to_security_review?  └─► Gate: WF-05 Step 4 (not APPROVED while any access_verdict is FAIL, or NOT_COVERED outside refusal_coverage_exempt); route: file per ISSUE_QUEUE.md as BLOCKER and dispatch SECURITY-REVIEWER with the entry text, never WF-03 directly.

Decided points for the builder:
- The line carries BOTH the routing (file, then dispatch SECURITY-REVIEWER) and a reference to the
  gate. The full gate wording (the access_verdict conditions, the refusal_coverage_exempt rule) lives
  ONLY in WF-05 Step 4 (section 6) and `product-owner.md` (section 5.2). ORCHESTRATOR.md carries just
  the short reference above. This satisfies AC3 "matching gate and routing lines".
- If the line before the insertion point is a `│` spacer line, keep it; do not alter any existing
  line. The insertion is add-only, as required for ORCHESTRATOR.md.
- No edit to AGENT_SYSTEM.md or CLAUDE.md.

## 8. Acceptance-criteria mapping

| AC | Element |
|---|---|
| AC1 Access and roles with rules (a)-(d), each own bullet; Forbidden before/after quoted | 3.2, 3.5 |
| AC2 `access_verdict`, `access_note` required; `route_to_security_review`; product-owner reads those exact names | 3.3, 5.2-5.3 |
| AC3 uat-runner pass/fail + no-substitution; WF-05 Step 4 and ORCHESTRATOR gate/routing | 4.1, 6, 7 |
| AC4 every name exists | section 0 (greps, with the two flagged exceptions: new fields, and `domain_issue` singular) |
| AC5 `mix letflow.check` passes with real output | section 1; run by TEST-RUNNER/builder, quote output |

## 9. Decisions (no open questions remain)

- D1: Builder = ELIXIR-DEV. The change is instruction text only.
- D2: `domain_issues` (the list) is the field; REQ-453's singular `domain_issue` means an entry of it.
- D3: Role names are taken from `docs/roles.md` (TENANT_ADMIN/TENANT_AUDITOR are target state until
  REQ-446..448); the text refers to "roles in `docs/roles.md`", not to code.
- D4: SECURITY-REVIEWER is not edited and not routed for this diff: it is instruction text with no
  tenant-data path, and REVIEWER checks that scope. The ORCHESTRATOR line only describes the runtime
  routing of a later `route_to_security_review` issue; ORCH's dispatch text states "review this observed
  access finding, not a diff".
- D5: No checker for `ba-signoff-*.yaml` / `uat-*.yaml` is built here. Enforcement is by text and by
  PRODUCT-OWNER.
- D6: `actors_observed` (keys `actor`, `roster_roles`, `observed_roles`, `match`) is accepted as the
  UAT-report key.
- D7: Rule (d) uses `severity: MAJOR`, `suggested_action: route_to_wf03`; ORCH files an issue.
- D8: Existing runs report `NOT_COVERED` for all five scopes; all are in `refusal_coverage_exempt`, so
  PRODUCT-OWNER does not block on them. The gate becomes live as scopes leave that list.
- D9: PRODUCT-OWNER reads the single key `refusal_coverage_exempt` from the roster (reading a YAML
  file is permitted; it runs no commands).
- D10: The builder locates every insertion point by matching existing content (heading text, quoted
  sentence, YAML key), NOT by line numbers. Every "current line" number in this design is orientation
  only and may be stale.
- D11: "Add-only" applies to ORCHESTRATOR.md, AGENT_SYSTEM.md and CLAUDE.md only. The WF-05 Step 4 edit
  MAY modify the existing closing sentence ("FAIL (BLOCKED) -> route per each issue's
  `suggested_action` ...") as specified in section 6.
