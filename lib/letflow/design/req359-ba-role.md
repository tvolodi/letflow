# REQ-359 — Design: BA (Business Analyst) agent role, generic per tenant-vertical/

# solution-pack, dual authoring+sign-off

Stage S7. Owner: `CODE-DESIGNER`. Status: design only — no `.claude/agents/*.md` file,
no `docs/agents/AGENT_SYSTEM.md` edit, no scenario file, no persona data file is written
by this document. All of those are Step 2a's job, following this design.

This is not an Elixir-module design — REQ-359 produces agent-role/process artefacts, not
`lib/letflow/` code. Per the handoff's own framing, "module interfaces/@specs" below map
to: role-file structure, persona-data schema, sign-off-artefact schema, `AGENT_SYSTEM.md`
diff, decision-0004 addendum text, and the concrete BilimBaga persona+scenario+execution
plan.

---

## 0. Premises re-verified against the tree (2026-09-16)

- REQ-358 (done) added `scope:` and `branches:`/`when:` to
  `docs/agents/uat-scenario-schema.md` and `.claude/agents/uat-runner.md`'s environment
  target (`base_url`/`credential_source`). Both are prerequisites this design uses as-is.
- `test/uat-reports/uat-2026-09-16-WF02-REQ358-20260916.yaml` (read in full) proves a live,
  reachable QA target exists today: `base_url: https://qa.bizdala.com`,
  `credential_source: ai-dala-infra/scripts/qa-login.sh`, readiness-checked HTTP 200,
  real Keycloak realm `bpm-default` at `https://auth.qa.bizdala.com`. This is the
  environment target §5 below uses for AC5's real execution — not a placeholder.
- `docs/agents/AGENT_SYSTEM.md` §3/§3.1/§6 (read in full) — current roster table, capability
  matrix, and artifact-locations table, reproduced/diffed in §4 below.
- `docs/migration/decisions/0004-humanless-pipeline.md` (read in full) — its "What is
  explicitly NOT reproduced" section is the deferral this requirement actions. Its own
  convention for later changes is a dated `## Addendum (YYYY-MM-DD, ...)` section appended
  at the end (confirmed precedent: decisions 0001, 0003, 0009, 0013, 0033 all use this
  exact heading shape) — never edited into the original "Decision"/"Reasoning" prose.
- R-Co's `docs/agents/BO_SWIFTROUTE.md` (read in full) — structural precedent for §§1-6:
  Purpose, Persona, Domain vocabulary, Inputs, Outputs, Authority boundaries, Execution
  workflow, Scenario authoring, Risk profile, "must never do." R-Co closed its roster at
  three files (`BO-SWIFTROUTE.md`, `BO-VORTEX.md`, `BO-MERIDIAN.md`) because it represented
  exactly three fictional companies. Letflow's roster is open (any solution pack a real
  tenant installs), so §1 below designs **one** canonical role file parameterized by
  vertical, not N per-vertical prose files — see §1.4 for why, and the two rejected
  alternatives.
- R-Co's `docs/agents/UAT_RUNNER.md` `contains_technical_leak()` concept (read via grep,
  `docs/agents/uat-scenario-schema-v1.1-addendum.md` §4 lines quoted in the handoff) is a
  regex-based reject-list (stack traces, Playwright selectors, `file.ext:LINE`, SQL,
  function-definition syntax) run over scenario-authoring text. §3 adapts the same rubric
  to the BA sign-off artefact's prose fields.
- `docs/migration/decisions/0022-bilimbaga-vertical.md` and
  `docs/migration/stage-10-bilimbaga-vertical.md` (read in full/excerpted) confirm
  BilimBaga is Letflow's first real, substantially-built vertical: P0–P5 done, candidate
  exam-taking UI (`web/src/pages/exam/ExamSessionPage.tsx`,
  `ExamSessionResultPage.tsx`) live, and `ISS-0674` (the by-id result-score gap) is
  **resolved** as of 2026-09-14 — `GET /exam-sessions/:id` now returns `score_pct`/`passed`
  for a submitted/scoreable session. This makes "candidate takes a timed exam and sees an
  accurate auto-graded result" a real, currently-working path to write §5's scenario
  against, not a scenario that would hit a known-broken feature.
- `test/uat-reports/` already exists and is the correct home for the sign-off artefact
  (AC2's own suggested path, `test/uat-reports/ba-signoff-<vertical>-<run_id>.yaml`,
  fits the existing `test/uat-reports/` artifact-location row in `AGENT_SYSTEM.md` §6 —
  **no new top-level directory is needed**, confirmed by reading that table first, per the
  acceptance criterion's own instruction).

---

## 1. The canonical BA role file

### 1.1 Location and naming

`.claude/agents/ba-analyst.md` — one file, matching the existing `.claude/agents/*.md`
flat-file convention (sibling to `uat-runner.md`, `issue-fixer.md`). Not
`ba-<vertical>.md` per vertical (see §1.4).

### 1.2 `AGENT_ID` convention

Not a single fixed string. A BA persona's `AGENT_ID` is **`BA-<VERTICAL-SLUG>`**, where
`<VERTICAL-SLUG>` is the uppercased `scope:` value from `docs/agents/uat-scenario-schema.md`
(e.g. `BA-BILIMBAGA` for `scope: bilimbaga`). Every dispatch to a BA persona states this
full `AGENT_ID` explicitly in the handoff, the same way every other agent's identity is
stated — `ba-analyst.md`'s own "Identity" section states this convention rather than a
literal `AGENT_ID:` value, since the file is not itself one persona.

This mirrors the existing precedent of `UAT-RUNNER` being one role file parameterized at
dispatch time by `base_url`/`credential_source` (REQ-358) rather than one file per target
environment — the same mechanism, applied to "which vertical" instead of "which
environment."

### 1.3 Persona-data registry (the actual per-vertical artefact)

A new small per-vertical **data** file, not a new prose role file:

```
docs/agents/ba-personas/<vertical-slug>.yaml
```

Schema (all fields required unless marked optional):

| Field | Type | Purpose |
|---|---|---|
| `vertical` | string | The `scope:` value this persona answers for (e.g. `bilimbaga`) |
| `solution_pack` | string | The `Letflow.Definitions.SolutionPack` identifier this vertical corresponds to (e.g. `bilimbaga`, per REQ-041/078) |
| `persona_name` | string | Fictional individual name, R-Co-style (e.g. "Ainur Zhaksybekova") |
| `persona_title` | string | Business role/title (e.g. "Head of Learning & Assessment") |
| `supporting_persona` | string, optional | A second persona for a sub-domain within the vertical, R-Co's Alice/Marco split precedent (optional — most verticals need only one) |
| `domain_vocabulary` | list of `{business_term, maps_to}` | Business-language ↔ Letflow-mechanism mapping table, R-Co §2 precedent |
| `risk_profile` | list of `{trigger, severity}` | What breaks this persona's day and at what severity (BLOCKER/MAJOR/MINOR), R-Co §8 precedent |
| `authority_boundaries.decides` | list of strings | What this persona rules on within its vertical |
| `authority_boundaries.does_not_decide` | list of strings | Explicitly out of scope (platform-level issues, other verticals, technical implementation, NFR) — always includes the three boilerplate exclusions below (§1.5) |
| `created_at` | ISO-8601 date | When this persona was first instantiated |
| `reused_for` | list of strings, optional | Other `scope:` values this persona has been reused for as "a close match" (§1.4's reuse path) |

### 1.4 How a new vertical gets a BA persona (AC1's explicit statement)

Stated verbatim (in substance) in `ba-analyst.md`'s "What you do" section:

1. When a scenario needs authoring or sign-off for a `scope:` value with no existing
   `docs/agents/ba-personas/<vertical-slug>.yaml` file, the dispatching agent (ORCH, or
   REQ-ANALYST during scenario planning) first checks whether an **existing** persona is
   "a close match" — same or closely related business domain (e.g. a second
   assessment/certification vertical would likely reuse the BilimBaga persona rather than
   invent a new one). This is a judgement call recorded in the dispatch, not mechanically
   checked.
2. If no close match exists: create a new `docs/agents/ba-personas/<vertical-slug>.yaml`
   file (§1.3's schema) — a small, one-time, data-only artefact. This is NOT a new
   `.claude/agents/*.md` file; the canonical `ba-analyst.md` file is reused unchanged.
3. If an existing persona is reused for a new vertical, append the new vertical's slug to
   that persona file's `reused_for` list rather than duplicating the persona data.
4. The BA persona is then invoked as `AGENT_ID: BA-<VERTICAL-SLUG>`, reading its own
   `docs/agents/ba-personas/<vertical-slug>.yaml` (or the reused file, resolved via
   `reused_for`) at the start of every session, exactly as any other agent reads its
   mandatory-reading list.

**Rejected alternative A** — one `.claude/agents/ba-<vertical>.md` prose file per vertical
(R-Co's literal pattern). Rejected because it re-closes the roster at "however many files
exist," contradicting the requirement's explicit "open set of real tenants" framing, and
because `.claude/agents/*.md` is documented in `AGENT_SYSTEM.md` §6 as "canonical,
hand-maintained" — an ever-growing set of near-identical per-vertical prose files is
exactly the weak-model-unfriendly duplication `core-directives.md`'s sizing principles
warn against (the same content — dual authoring+sign-off procedure, language rule — would
be copy-pasted into every file and drift over time).

**Rejected alternative B** — no persona-data file at all, persona details supplied
ad hoc in each dispatch's handoff `context`. Rejected because a persona's voice/domain
vocabulary/risk profile needs to stay **consistent across runs** (the same way R-Co's
Alice Bauer always reasons the same way) — re-deriving it fresh each dispatch risks
drift and contradicts REQ-359's "an existing one is reused if the vertical is a close
match" framing, which presupposes the persona persists as an artefact, not a one-off.

### 1.5 Role-file section outline (structural convention, per `uat-runner.md`/`issue-fixer.md`)

```
---
name: Letflow BA Analyst (BA-<VERTICAL>)
description: <one line — dual role, tenant-vertical business perspective>
---

## Identity
  AGENT_ID convention: BA-<VERTICAL-SLUG> (see uat-scenario-schema.md's `scope:` field)

## Mandatory reading at session start
  - docs/agents/instructions/core-directives.md
  - docs/agents/ba-personas/<vertical-slug>.yaml (this run's own persona data)
  - docs/agents/uat-scenario-schema.md (scope:/branches: shape)
  - .claude/agents/uat-runner.md (the scenarios this role authors are read by UAT-RUNNER)
  - the vertical's own solution-pack/process definitions (e.g. for bilimbaga:
    priv/packs/bilimbaga/**, docs/migration/stage-10-bilimbaga-vertical.md)

## What you do
  - AUTHORING: write UAT scenario files under
    test/fixtures/uat/scenarios/<vertical-slug>/*.yaml, conforming to
    docs/agents/uat-scenario-schema.md, in the vertical's own domain vocabulary per the
    persona-data file's domain_vocabulary table — never technical/implementation
    language (§3's language rule applies to authored scenarios' prose fields the same
    way it applies to sign-off prose).
  - SIGN-OFF: after UAT-RUNNER executes a run's scenarios for this vertical's scope,
    read test/uat-reports/uat-<date>-<run_id>.yaml filtered to this scope, and write
    test/uat-reports/ba-signoff-<vertical-slug>-<run_id>.yaml (§2 schema).
  - §1.4's new-vertical/reuse procedure.

## Forbidden
  - No technical language in either authored scenarios or sign-off prose (§3).
  - Does not decide platform-level cross-tenant issues, other verticals' business
    questions, technical implementation, or NFR compliance (persona file's
    authority_boundaries.does_not_decide, always including these three).
  - Does not talk to another BA persona directly to resolve a cross-vertical
    disagreement — routes to REQ-361's PRODUCT-OWNER-equivalent role once it exists
    (not yet — REQ-361 is a separate, still-pending requirement); until then, an
    unresolved cross-vertical disagreement is reported to ORCH.
  - Does not execute UAT-RUNNER itself (dual role is author+sign-off, not
    author+execute — UAT-RUNNER remains the sole executor of real HTTP/GUI actions).
```

---

## 2. Sign-off artefact (AC2)

### 2.1 Location/naming

`test/uat-reports/ba-signoff-<vertical-slug>-<run_id>.yaml` — reuses the existing
`test/uat-reports/` location (`AGENT_SYSTEM.md` §6 row, owner `UAT-RUNNER` today; §4 below
adds `BA-<VERTICAL>` as a second writer of files under this same directory with a
distinguishing `ba-signoff-` prefix, the same way `uat-` already prefixes UAT-RUNNER's own
files — no new top-level directory).

### 2.2 Schema

```yaml
report_id: ba-signoff-<vertical-slug>-<run_id>
run_id: <run_id>
vertical: <vertical-slug>              # e.g. bilimbaga
solution_pack: <solution-pack-id>      # e.g. bilimbaga
generated_at: <ISO-8601>
persona: <persona_name> (<persona_title>)   # from the persona-data file
source_uat_report: test/uat-reports/uat-<date>-<run_id>.yaml   # the report read

scenarios_reviewed: <n>
domain_verdict: PASS | FAIL | PARTIAL

scenario_verdicts:
  - scenario_id: <id>
    title: "<title>"
    persona_verdict: PASS | FAIL | PARTIAL
    business_note: >
      <1-2 sentences, business-readable prose — see §3>
    issues: []

domain_issues:
  - id: BA-<VERTICAL-SLUG>-<nnn>
    severity: BLOCKER | MAJOR | MINOR
    business_description: >
      <plain-language description — see §3>
    affected_scenario: <scenario_id>
    suggested_action: route_to_wf03 | route_to_req_analyst | none

overall_note: >
  <1-3 sentences — persona's summary statement on release readiness for this vertical>
```

Direct structural port of R-Co's `bo-signoff-<company>-<run_id>.yaml` (§6/§3 of
`BO_SWIFTROUTE.md`), with `company_id`→`vertical`/`solution_pack` (Letflow has no fixed
company roster) and `affected_process` dropped (R-Co's field named a specific
`proc-<company>-<name>` process definition; Letflow's generic-engine process identifiers
are not guaranteed to be as stable a business-facing handle, so `affected_scenario` alone
is kept — an open question below if a future vertical needs the process reference back).

---

## 3. Language rule (AC3)

Adapted rubric (same substance as `contains_technical_leak()`, applied to this artefact's
`business_note`/`business_description`/`overall_note` fields): reject stack traces,
`file.ext:LINE` references, test IDs (`REQ-NNN`/`ISS-NNNN`/`test_*` function names), SQL,
HTTP method+path strings, and Elixir/TypeScript syntax markers (`def `, `=>`, `fn ->`).
Mechanical enforcement is **optional/future** (a `mix letflow.check_ba_signoff_language`
task mirroring `check_uat_scenario_schema`'s structure would be a natural follow-up, but
is not required by this requirement's acceptance criteria — flagged as an open question
in §6, not silently built here).

**Correct example** (adapted to BilimBaga, not copied from R-Co's banking/logistics):

> "The candidate completed their timed certification exam and received an accurate score
> immediately after submitting — this matches how we expect a proctored exam to behave
> for our monthly compliance certifications."

**Forbidden example** (what must never appear in a sign-off artefact):

> "POST /api/v1/exam-sessions/{id}/submit returned 200; session_test.exs:142's
> `test_auto_grade/1` passed; `score_pct` was read from `exam_sessions.score_pct` via
> `session_view/1`."

---

## 4. `AGENT_SYSTEM.md` diff (AC4)

### 4.1 §3 roster table — new row (inserted after the `UAT-RUNNER` row)

```
| `BA-<VERTICAL>` | Business Analyst (per tenant-vertical/solution-pack) | Authors UAT scenarios in tenant-vertical domain language and signs off on UAT-RUNNER's execution results for its scope, per `.claude/agents/ba-analyst.md` — one canonical role file, parameterized by vertical via `docs/agents/ba-personas/<vertical>.yaml`, not a closed per-company roster | `test/fixtures/uat/scenarios/<vertical>/`, `test/uat-reports/` (`ba-signoff-` prefix), `docs/agents/ba-personas/` (new-persona/reuse bookkeeping), `handoffs/` |
```

Also update the "Deliberately not reproduced yet" note directly below the table (§3, the
paragraph naming `BO-SWIFTROUTE`/`BO-VORTEX`/`BO-MERIDIAN`/`PRODUCT-OWNER`): narrow it to
state that the BO-* equivalent (this row) is now actioned by REQ-359, and only
`PRODUCT-OWNER`'s equivalent (REQ-361, still pending) remains deferred.

### 4.2 §3.1 capability matrix — new row

```
| `BA-<VERTICAL>` | ✓ | ✓ (scenario files, ba-signoff files, persona-data files) | ✗ | ✗ |
```

(Read: yes. Writes: yes, to the three locations named in §4.1. No terminal commands — it
never executes UAT-RUNNER itself, per §1.5's Forbidden section. No subagents.)

### 4.3 §6 artifact-locations table — new row

```
| BA persona data | `docs/agents/ba-personas/` | `ORCH`/`REQ-ANALYST` (creation), `BA-<VERTICAL>` (own reads) | `.yaml` |
```

This is the one genuinely **new location** this requirement introduces (checked against
the existing table first, per AC2's own instruction) — everything else (`ba-signoff-`
files, scenario files) reuses existing rows (`test/uat-reports/`,
`test/fixtures/uat/scenarios/<company>/` — the existing row's `<company>` is read as
`<vertical>` going forward, same directory pattern, no row change needed there beyond a
note).

### 4.4 §6's existing `test/fixtures/uat/scenarios/<company>/*.yaml` row

No schema change (REQ-358 already covers `scope:`), but add a one-line note that
`<company>` and `<vertical>` are the same directory-naming axis (the existing 3
legacy-company directories are grandfathered per REQ-358's own default-derivation rule;
new directories are named by vertical/solution-pack slug, e.g. `bilimbaga`).

---

## 5. Real BilimBaga BA persona + real scenario + real execution (AC5)

Full procedure, in order, for whichever agent executes Step 2a:

1. Create `docs/agents/ba-personas/bilimbaga.yaml` (§1.3 schema) — a first, concrete
   persona:
   - `vertical: bilimbaga`, `solution_pack: bilimbaga`
   - `persona_name`: a fictional name (R-Co style, e.g. "Ainur Zhaksybekova")
   - `persona_title`: "Head of Learning & Assessment"
   - `domain_vocabulary`: at minimum — "exam session" → `Letflow.Exam.Session`
     record/`exam_sessions` table; "auto-graded score" → `session_view/1`'s
     `score_pct`/`passed` fields (per ISS-0674's now-resolved fix); "timed exam" →
     the session's `expires_at`/countdown-reanchoring behaviour
     (`ExamSessionPage.tsx`); "certification exam" → an exam definition installed via
     the `bilimbaga` solution pack.
   - `risk_profile`: e.g. "candidate cannot see their score after submitting" → BLOCKER;
     "countdown timer drifts from server time" → MAJOR; "result wording is unclear" →
     MINOR.
   - `authority_boundaries.decides`: exam-taking flow correctness, scoring/grading
     accuracy as observed by the candidate, timed-session behaviour.
     `does_not_decide`: platform-level tenant provisioning, other verticals, technical
     implementation, NFR/latency — the three boilerplate exclusions plus BilimBaga's
     own certificate-issuance scope (explicitly out — P3's second half is not yet built,
     per `stage-10-bilimbaga-vertical.md`).
2. Invoke `AGENT_ID: BA-BILIMBAGA`, reading `ba-analyst.md` + `bilimbaga.yaml` +
   `docs/agents/uat-scenario-schema.md` + `docs/migration/stage-10-bilimbaga-vertical.md`.
3. Author ONE real scenario file:
   `test/fixtures/uat/scenarios/bilimbaga/candidate-timed-exam-autograde.yaml` —
   `scope: bilimbaga`, no `company_id:` (BilimBaga is a real vertical, not a legacy R-Co
   company — §0's default-derivation rule 3 does not apply since `scope:` is written
   explicitly). A flat `steps:`/`expected_outcomes:` scenario (branching is available per
   REQ-358 but not required for this particular scenario — nothing here is
   role-conditional) covering: candidate signs in, starts a timed exam session, answers
   and submits before the timer expires, is shown their auto-graded score on submission
   — written in BilimBaga's own domain vocabulary (§5.1's table), no selectors/route
   paths/function names in `action`/`description`/`verification.detail` fields (§3's
   rule, adapted the same way to authored scenarios, not just sign-offs).
4. ORCH dispatches WF-05 against the real QA target already proven live in §0
   (`base_url: https://qa.bizdala.com`, `credential_source:
   ai-dala-infra/scripts/qa-login.sh`) — **open question**: whether QA already has a
   BilimBaga tenant + a seeded candidate account + at least one installed exam definition
   ready to exercise this scenario against, or whether that seeding is itself missing
   work. This design does not assume either way (§6, OQ-3).
5. UAT-RUNNER executes the scenario for real (real HTTP/GUI against QA), writes
   `test/uat-reports/uat-<date>-<run_id>.yaml`.
6. `BA-BILIMBAGA` reads that report, writes
   `test/uat-reports/ba-signoff-bilimbaga-<run_id>.yaml` (§2 schema), with the actual
   observed verdict quoted in this requirement's close-out (`docs/requirements.yaml`
   status flip / `requirement_status` event) — not asserted.

**Routing note (not this design's call, flagged for ORCH):** REQ-359's `docs/
requirements.yaml` entry names `owner: REQ-ANALYST`, but WF-02 Step 2a's literal text is
"ELIXIR-DEV: lib/ + migrations." This requirement produces zero `lib/`/`priv/repo/
migrations/` changes — every artefact above is a `.md`/`.yaml` file. Recommend: whichever
agent ORCH assigns Step 2a to (ELIXIR-DEV, by WF-02's default backend-implementer role,
since this branch's Step 00 was already run under that convention) executes §5's
procedure directly rather than writing application code, and Step 3 (TEST-DESIGNER)'s
scope test correctly finds **no application-executable surface** (same category as a
decision-record-only requirement) and routes straight to RELEASE-VALIDATOR per WF-02
Step 3's own documented "docs-only" branch — RELEASE-VALIDATOR verifies AC5 by reading
the actual scenario file, sign-off artefact, and quoted UAT-RUNNER report directly.

---

## 6. Open questions (not silently resolved)

- **OQ-1:** Should `docs/agents/ba-personas/*.yaml` files require a validating gate
  (analogous to `CODE-DESIGN-VALIDATOR`/`TEST-DESIGN-VALIDATOR`) before a new persona is
  considered canonical, or is REVIEWER's ordinary Step 2d idiom-review pass sufficient?
  This design assumes the latter (no new hard gate invented) since AC1-4 name no such
  gate, but flags it for REVIEWER to confirm rather than silently deciding it.
- **OQ-2:** §3's language-rule mechanical enforcement
  (`mix letflow.check_ba_signoff_language`) is designed as optional/future, not built by
  this requirement. If TEST-DESIGNER/REVIEWER judges the acceptance criterion ("states a
  language rule... with a correct and forbidden example") to require enforcement, not just
  documentation, that is a scope expansion beyond what AC3's literal text asks for — flag
  before building it, don't assume it's included.
- **OQ-3 (blocking for AC5's real execution):** whether QA (`https://qa.bizdala.com`)
  currently has a BilimBaga tenant provisioned with an installed exam definition and a
  seeded candidate account reachable via `ai-dala-infra/scripts/qa-login.sh` (or an
  equivalent seeding mechanism). REQ-358's QA UAT report only exercised platform-scope
  login-routing with `admin-user`/`operator-user` — it does not confirm a BilimBaga
  candidate identity exists on QA. Step 2a must verify this before dispatching WF-05, not
  assume it; if no such tenant/candidate exists on QA, that is itself a gap to file
  (ISSUE_QUEUE.md) rather than a reason to fabricate a passing result or silently swap in
  a simulated/local target (both forbidden by `test_developer_guide.md`'s Directive T-2
  and `.claude/agents/uat-runner.md`'s own "Forbidden" section).
- **OQ-4:** R-Co's BO-* role has an explicit "Stage 12 projection" section (a persona
  becomes a real tenant actor once the runtime-mode capability exists). This design omits
  an equivalent section since decision 0004 scopes the current roster to "how Letflow
  itself is built," not runtime-mode — flagging that this projection section, if wanted,
  would need its own decision-record basis, not be added here by default.

---

## 7. Acceptance-criteria coverage map

| AC | Design element |
|---|---|
| 1 | §1.1–§1.4 (one canonical file, `BA-<VERTICAL-SLUG>` convention, explicit new-vertical/reuse procedure) |
| 2 | §1.5 "What you do" (dual role stated explicitly), §2 (sign-off schema/location, reuses `test/uat-reports/`, checked against `AGENT_SYSTEM.md` §6 first) |
| 3 | §3 (language rule, correct + forbidden BilimBaga-domain examples) |
| 4 | §4 (roster row, capability-matrix row, artifact-locations new row + note; decision-0004 addendum text below) |
| 5 | §5 (concrete BilimBaga persona instantiation, real scenario, real QA dispatch procedure) |

---

## 8. Decision-0004 addendum text (for Step 2a to append, append-only, per that file's own convention)

```markdown
## Addendum (2026-09-16, REQ-359) — BO-*-equivalent deferral actioned

The "What is explicitly NOT reproduced from R-Co" section above deferred the
BO-SWIFTROUTE/BO-VORTEX/BO-MERIDIAN business-owner-persona layer until Letflow had a real
tenant-business scenario corpus (S7) to validate against. REQ-358 confirmed both
preconditions fired (S7 done; 29-scenario corpus exists) and REQ-359 actions the
deferral: a generic `BA-<VERTICAL>` role (`.claude/agents/ba-analyst.md`, parameterized
by `docs/agents/ba-personas/<vertical>.yaml`) replaces the closed three-persona pattern,
keyed on Letflow's open tenant-vertical/solution-pack set instead of R-Co's three
fictional companies — see `lib/letflow/design/req359-ba-role.md` for the full design and
`docs/agents/AGENT_SYSTEM.md` §3/§3.1/§6 for the resulting roster/capability/artifact-
location entries. This addendum does not revise the original "Decision"/"Reasoning"
sections above, which remain correct as stated for the period before S7's precondition
held. The `PRODUCT-OWNER`-equivalent half of the original deferral remains open,
tracked as REQ-361.
```
