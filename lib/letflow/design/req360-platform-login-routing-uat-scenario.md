# REQ-360 — Design: platform-admin login-routing UAT scenario (real, permanent)

Stage S7. Owner (per `docs/requirements.yaml`): `REQ-ANALYST`. Status: design only —
no scenario YAML, no UAT-RUNNER dispatch, no `docs/issues/*.yaml` finding is written by
this document. This is not an Elixir-module design — like REQ-359, REQ-360 produces a
UAT-scenario/report artefact, not `lib/letflow/` code; "module interfaces/@specs" below
map to: the scenario file's exact field values, the WF-05 dispatch shape, the
uat-report/screenshot artefact shape, and an explicit statement of the real vs.
idealized routing-behavior gap this requirement's own description anticipated.

---

## 0. Premises re-verified against the tree (2026-09-17)

- **Path correction:** the requirement text's `letflow-3/web/src/auth/...` prefix is
  stale (a different checkout's naming convention). In this repo the real files are
  `web/src/auth/ProtectedRoute.tsx` and `web/src/auth/AuthProvider.tsx` (read in full).
  `web/src/router.tsx` and `web/src/pages/dashboard/TenantDashboardPage.tsx` were also
  read in full — the requirement text names only the two auth files, but the actual
  post-login *routing* decision lives in `router.tsx`, so it had to be read too to
  answer "is there a distinct tenant-dashboard route" for real.
- **Real behavior finding #1 — no distinct platform-admin dashboard route exists.**
  `router.tsx`'s route tree has exactly one authenticated landing surface: `path: '/'`
  (`index: true`) and `path: 'dashboard'` both render the **same** component,
  `TenantDashboardPage`, for every authenticated role with no role-based branch in the
  router, in `ProtectedRoute.tsx`, or in `AuthProvider.tsx`. `OidcCallbackPage.tsx`
  (the post-login handler) calls `navigate('/', { replace: true })` unconditionally —
  it does not read `payload.roles` to pick a destination. Role-based differences exist
  only *within* the authenticated shell: `AppShell.tsx`'s nav-item list is filtered by
  role (PLATFORM_ADMIN sees additional `/admin/*` links), and several `/admin/*` pages
  (`TenantsPage.tsx`, `RegisterTenantPage.tsx`, `EditTenantPage.tsx`,
  `OnboardingResultPage.tsx`, `OnboardingProgressPage.tsx`) self-guard by redirecting a
  non-PLATFORM_ADMIN session to `/instances`. None of these is a distinct **landing**
  page reached automatically right after login — a PLATFORM_ADMIN would have to
  navigate to `/admin/tenants` (or similar) themselves; login always lands everyone on
  `/` → `TenantDashboardPage`.
  **This is the inverse of the gap the requirement's own Why-section flagged as
  possible** ("if there is in fact no distinct tenant-dashboard route yet, only a
  single workspace root") — the tenant dashboard route (`TenantDashboardPage`, mounted
  at both `/` and `/dashboard`) does exist and is real; what does **not** exist is a
  *distinct platform-admin* post-login destination. See §2 and §5 (Findings) below —
  this is not silently papered over.
- **Real behavior finding #2 — no in-app login form exists at all.**
  `ProtectedRoute.tsx` never renders a login form. On `!isAuthenticated`, its `useEffect`
  calls `getOidcManager().then(m => m.signinRedirect(buildRedirectArgs()))` — a
  full-page redirect to Keycloak's own hosted login UI (an external origin,
  `auth.qa.bizdala.com`-shaped per `docs/agents/uat-scenario-schema.md`'s "Environment
  target" precedent report). While `redirecting` is true, the component renders only a
  `data-testid="auth-loading"` placeholder reading "Redirecting to login…" — never a
  field-set of any kind. Grepping `web/src/` for `LoginPage`/`LoginForm`/`login-form`
  returns zero matches. **The requirement's own description assumes "they see the login
  form with its actual field set"; the real behavior is a redirect to an
  externally-hosted Keycloak login page Letflow's own frontend does not render and
  cannot describe a field set for.** This is a second, and larger, real-vs-idealized gap
  than the one the requirement anticipated — see §2 branch 3 and §5.
- `docs/agents/uat-scenario-schema.md` and `.claude/agents/uat-runner.md` (both read in
  full) are REQ-358's shipped, current schema/runner docs — used directly below rather
  than REQ-358's own design doc, since the schema doc is now canonical.
  `test/fixtures/uat/scenarios/_throwaway/login-routing-example.yaml` (read in full) is
  the throwaway fixture; REQ-360 does not reuse it as permanent corpus (per the
  requirement text and per that file's own header comment) but its three-branch shape
  is the direct structural starting point, adjusted for §2's real-behavior findings.
- `lib/letflow/design/req359-ba-role.md` (read in full) is the direct routing-note
  precedent for §6 below: REQ-359 hit the identical "owner: REQ-ANALYST but WF-02 Step
  2a's literal text names ELIXIR-DEV" situation and recommended ELIXIR-DEV execute the
  artefact-authoring procedure directly rather than write application code, with Step 3
  routing straight to RELEASE-VALIDATOR per WF-02's "docs-only" branch. §6 makes the
  same recommendation here, for the same reason.
- `test/uat-reports/uat-2026-09-16-WF02-REQ358-20260916.yaml` (read in full) is the most
  recent real execution against this exact QA target and is direct evidence for a risk
  flagged in §4/§7 below: that run recorded the throwaway fixture's `via: gui` steps as
  `BLOCKED / UNBUILT_FEATURE (frontend leg only)` because **no browser-automation tool
  was available to that UAT-RUNNER session** (checked via `ToolSearch`, none found), and
  it fell back to a backend-only (JWT-role-based) verification of the branch-selection
  mechanism instead of a real GUI walkthrough. REQ-360's AC2 requires screenshots as
  primary evidence — §7's open questions flags this as a live risk to Step 4's real
  execution, not assumed away.
- `docs/agents/instructions/core-directives.md`'s "No Issue Left Local-Only" governs
  §5's findings: this design does not itself file them (CODE-DESIGNER has no queue
  access and it is not this step's job) — it states precisely what must be filed and by
  whom, per that section's procedure.

---

## 1. Target file path

```
test/fixtures/uat/scenarios/platform/platform-login-routing-by-role.yaml
```

Rationale: AC1 names `test/fixtures/uat/scenarios/platform/` (or "the location REQ-358
establishes") as the target directory — REQ-358 did not relocate the existing
`platform/` directory, so this is that location, not a new one. Filename avoids the
throwaway fixture's `-example`/`req358-validation` naming (this is the permanent,
real-corpus counterpart) and avoids colliding with any of the 20 existing
`platform/*.yaml` files (checked: no existing file matches this stem).

---

## 2. Scenario YAML shape (all fields, following the shipped schema)

Full field-by-field shape for Step 2a's authoring pass — reproduced completely here per
CODE-DESIGNER's "no acceptance criterion left unaddressed" rule, but this is the design
element illustrating the shape, not the committed artefact (Step 2a writes the real
file). Differences from the throwaway fixture are called out inline; they follow
directly from §0's two real-behavior findings, not invention.

```yaml
# Permanent corpus (REQ-360). Not the REQ-358 throwaway validation fixture --
# see test/fixtures/uat/scenarios/_throwaway/login-routing-example.yaml for
# that file's own scope note. This is the first real REQ-ANALYST-authored
# platform-scope scenario using REQ-358's branching construct as permanent
# scope.
#
# REAL-BEHAVIOR NOTE (finding filed as <ISSUE_QUEUE ref, filled in by Step 2a>):
# this scenario documents the ACTUAL observed routing behavior, which differs
# from an idealized "platform dashboard vs. tenant dashboard vs. in-app login
# form" description in two ways -- see branches 1-3 below and this
# repository's lib/letflow/design/req360-platform-login-routing-uat-scenario.md
# Section 0/5 for the full finding.
---
id: platform-login-routing-by-role
scope: platform
company_id: platform
process_id: n/a
title: Post-login landing surface by authenticated role (real QA routing behavior)
version: "1.0"
tags: [auth, routing, platform]

description: >
  A user opens the QA login URL. Real observed behavior as of 2026-09-17
  (see design doc Section 0): authenticated users of every role -- both
  PLATFORM_ADMIN and tenant-scoped roles -- land on the SAME workspace route
  (the tenant-dashboard root, "/"); there is no distinct platform-admin
  landing destination reached automatically at login (PLATFORM_ADMIN's extra
  capabilities surface only as additional navigation entries within the same
  shell, not as a different landing page). An unauthenticated visitor is
  redirected to Keycloak's own externally-hosted login page -- Letflow's own
  frontend renders no in-app login form and shows only a brief "Redirecting
  to login..." placeholder first. This scenario verifies the REAL behavior in
  both respects, not the idealized distinct-dashboards/in-app-form
  description this requirement's own Why-section originally anticipated.

actors:
  viewer: actor-any

preconditions:
  - description: The instance is reachable at the configured environment target
    check: instance_reachable

branches:
  - name: platform_admin_lands_on_workspace_root
    when:
      fact: role
      op: eq
      value: PLATFORM_ADMIN
    steps:
      - step: 1
        actor: viewer
        action: >
          Signs in as a platform administrator (PLATFORM_ADMIN role) via the
          QA environment's seeded admin credentials and reaches the post-login
          screen
        via: gui
    expected_outcomes:
      - id: EO-001
        description: >
          Platform admin lands on the shared workspace root -- NOT a
          distinct platform-admin dashboard, because none exists (see
          scenario description)
        verification:
          method: gui_screen
          detail: >
            Route is "/" (the workspace root, rendering TenantDashboardPage);
            the authenticated shell's navigation shows the PLATFORM_ADMIN-only
            entries (e.g. Users, Tenants, Health, Metrics) alongside the same
            dashboard tiles a tenant-scoped user sees
        on_fail:
          severity: BLOCKER
          business_impact: Platform admins cannot reach their workspace after login.
          suggested_action: route_to_wf03

  - name: tenant_scoped_role_lands_on_workspace_root
    when:
      fact: role
      op: in
      value: [PROCESS_DESIGNER, PROCESS_OPERATOR, TASK_WORKER]
    steps:
      - step: 1
        actor: viewer
        action: >
          Signs in as a tenant-scoped user via the QA environment's seeded
          operator credentials and reaches the post-login screen
        via: gui
    expected_outcomes:
      - id: EO-001
        description: Tenant-scoped user lands on the same workspace root
        verification:
          method: gui_screen
          detail: >
            Route is "/" (the workspace root, rendering TenantDashboardPage);
            the authenticated shell's navigation shows only this role's
            permitted entries (no PLATFORM_ADMIN-only items); dashboard tiles
            reflect this tenant's own data only
        on_fail:
          severity: BLOCKER
          business_impact: Tenant users cannot reach their workspace after login.
          suggested_action: route_to_wf03

  - name: unauthenticated_redirects_to_external_login
    when: else
    steps:
      - step: 1
        actor: viewer
        action: >
          Opens the QA login URL without any prior session (no token, no
          cookie)
        via: gui
    expected_outcomes:
      - id: EO-001
        description: >
          Visitor is redirected toward Keycloak's hosted login page --
          Letflow renders no in-app login form of its own
        verification:
          method: gui_screen
          detail: >
            Immediately after navigation, the app briefly shows the
            data-testid="auth-loading" "Redirecting to login..." placeholder,
            then the browser is redirected off-origin to the configured OIDC
            authority's own hosted login page (outside Letflow's own
            frontend -- there is no Letflow-rendered field set to describe;
            the fields shown, if any, are Keycloak's, not this
            application's)
        on_fail:
          severity: BLOCKER
          business_impact: Unauthenticated visitors cannot reach a way to sign in.
          suggested_action: route_to_wf03

cleanup:
  cancel_open_instances: false
  description: No process instance created; no cleanup required.
```

### Field-shape notes (mapping to the shipped schema doc)

- `scope: platform` + `company_id: platform` — both written explicitly (not relying on
  the default-derivation rule), matching every other file already under
  `test/fixtures/uat/scenarios/platform/`.
- `branches:`/`when:` — uses only `eq` and `in` on the one fact with a
  procedurally-defined evaluation method (`role`), plus one trailing `else`, exactly
  per `docs/agents/uat-scenario-schema.md`'s shipped rules (`SCHEMA-5`/`SCHEMA-6`
  satisfied: three uniquely-named branches, `else` last).
- `verification.method: gui_screen` on all three (not `page_state`, which the
  throwaway fixture used) — this is a deliberate choice, not copied from the
  throwaway: AC2 requires "screenshots per UAT-RUNNER's existing
  screenshot-as-primary-evidence discipline," and `.claude/agents/uat-runner.md`'s
  two-phase visual-regression procedure (REQ-362) is triggered specifically by
  `verification.method: gui_screen`, not by `page_state`. This is the concrete
  mechanism that makes "screenshots... recorded" true rather than aspirational.
- `via: gui` on every step — required for `gui_screen` verification and for the
  scenario to exercise the actual browser/OIDC redirect flow rather than a
  backend-only JWT check (the previous run's fallback — see §0's "Premises" bullet on
  ISS/BLOCKED precedent — is a degraded substitute, not the intended primary path).
- Role list for the second branch (`[PROCESS_DESIGNER, PROCESS_OPERATOR,
  TASK_WORKER]`) is drawn from the actual role vocabulary observed in
  `web/src/components/layout/AppShell.tsx`'s `Role` type union, not invented — the
  throwaway fixture's `[TENANT_ADMIN, TENANT_USER]` do not appear anywhere in the real
  frontend's role vocabulary (grepped; no match), so this design does not carry that
  mismatch forward into the permanent scenario. **Flagged as Open Question OQ-1
  (§7)** — Step 2a must independently re-verify which single seeded QA account
  (per `qa-login.sh`) actually carries one of these three roles before authoring the
  final file, since this design's own grep of `AppShell.tsx` is not itself proof a
  seeded QA user with that role exists.

---

## 3. UAT-RUNNER invocation against QA (AC2's execution mechanism)

Concrete WF-05 dispatch shape, per `.claude/agents/uat-runner.md`'s "Environment
target" section (REQ-358) and its "Two-phase visual regression" section (REQ-362,
already shipped and referenced by name in `uat-runner.md` — its `environment:` field is
required whenever a dispatch includes any `gui_screen` expected outcome, which every
branch of this scenario does):

```
context:
  environment_target:
    base_url: "https://qa.bizdala.com"          # same live target REQ-358/REQ-359 used
    credential_source: "ai-dala-infra/scripts/qa-login.sh"   # POSIX; qa-login.ps1 is the
                                                               # Windows-host equivalent
                                                               # invocation of the same
                                                               # seeded-credential source
    environment: "qa"                            # stable slug for visual-baseline keying
                                                   # (REQ-362) -- NOT parsed from base_url
scenario_files:
  - test/fixtures/uat/scenarios/platform/platform-login-routing-by-role.yaml
```

Execution procedure (restating `.claude/agents/uat-runner.md`'s existing, shipped
"Evaluating a `when:` branch" section against this specific file — no new runner
behavior is designed here, REQ-358 already built the mechanism this scenario exercises
for real):

1. UAT-RUNNER independently re-confirms `base_url` is reachable (its own HTTP check,
   not trusted from the dispatch), same discipline as the REQ-358/REQ-359 reports.
2. For branch 1: obtain a PLATFORM_ADMIN-role credential via `credential_source`
   (`qa-login.sh <platform-admin-account>` or `qa-login.ps1` on a Windows-driving host),
   drive the real login flow in a real browser session (GUI, not an API-only JWT
   substitute — see §2's field-note on why `via: gui`/`gui_screen` matter), and observe
   the landed route + rendered navigation per EO-001's `detail`.
3. For branch 2: the same, with a credential carrying one of
   `[PROCESS_DESIGNER, PROCESS_OPERATOR, TASK_WORKER]` (§7 OQ-1 — confirm which seeded
   account actually carries one of these before running).
4. For branch 3 (`when: else`): open the URL with **no** prior session (a fresh/
   incognito browser context, or an explicitly cleared token) and observe the redirect
   behavior per EO-001's `detail`.
5. Only the first matching branch per authenticated state is run, per the shipped
   "run only the first matching branch" rule — this scenario's three branches
   correspond to three separate UAT-RUNNER passes (one authenticated context each), not
   three branches evaluated within a single session.
6. If, at execution time, no browser-automation tool is available to the UAT-RUNNER
   session (the exact situation `uat-2026-09-16-WF02-REQ358-20260916.yaml` already
   recorded for the throwaway fixture's `via: gui` steps), UAT-RUNNER records the
   affected branch(es) `BLOCKED / UNBUILT_FEATURE (frontend leg only)` per its existing,
   documented convention for this exact case — it does **not** silently substitute a
   backend-only check and call it equivalent to a `gui_screen` verification, since that
   would silently fail to produce the screenshot evidence AC2 requires. See §7 OQ-2.

---

## 4. Screenshots + uat-reports artefact — concrete shape (AC2)

- **UAT report file:** `test/uat-reports/uat-<date>-<run-id>.yaml`, per
  `.claude/agents/uat-runner.md`'s "What you do" section (unchanged convention) — e.g.
  `test/uat-reports/uat-2026-09-17-WF02-REQ360-20260917.yaml` if the run completes the
  same day. Follows the same top-level shape already used by
  `uat-2026-09-16-WF02-REQ358-20260916.yaml` (`run_id`, `date`, `agent`, `scope`,
  `environment_target`, one section per scenario/branch with `verdict`, `evidence`).
- **Screenshots:** captured per `gui_screen`'s two-phase procedure
  (`lib/letflow/design/req362-visual-regression-testing.md` §5-6, already shipped and
  referenced by `.claude/agents/uat-runner.md`). Concretely, for each of this
  scenario's three branches' `EO-001`:
  - Baseline path: `test/fixtures/uat/visual-baselines/platform/
    platform-login-routing-by-role/1-EO-001.qa.png` for branch 1's step, similarly for
    branches 2/3 (path shape:
    `test/fixtures/uat/visual-baselines/<company_id>/<scenario_id>/<step>-<eo_id>.
    <environment>.png`, per the shipped convention — `<company_id>` here is `platform`,
    `<environment>` is `qa` per §3's dispatch).
  - First real run (no baseline exists yet): UAT-RUNNER judges the screenshot correct
    per today's discipline and calls `acceptBaseline()` to persist it — this run
    **creates** the three baselines under `test/fixtures/uat/visual-baselines/platform/
    platform-login-routing-by-role/`.
  - The UAT report's evidence for each branch names the screenshot path actually
    captured/compared, exactly as `uat-runner.md`'s "primary evidence" discipline
    requires — not merely asserted PASS/FAIL text.
- **Close-out quoting (AC2):** this requirement's `docs/requirements.yaml` status-flip
  entry and the `docs/status/requirement_status.index.yaml` "done" event must quote the
  actual verdict lines from the real `test/uat-reports/uat-<date>-<run-id>.yaml` file
  Step 4/5 produces — not a paraphrase, per `core-directives.md`'s "No Speculation."

---

## 5. Findings to file (AC3) — stated explicitly, not resolved here

Two distinct real-vs-idealized mismatches were found (§0). Per AC3 and
`core-directives.md`'s "No Issue Left Local-Only," **both** must become queued findings
during Step 2a — this design states what each finding must say; it does not file them
(CODE-DESIGNER has no queue access, and filing is a later step's job per
`docs/agents/protocols/ISSUE_QUEUE.md`):

- **Finding A — no distinct platform-admin post-login landing route exists.**
  Title (suggested): "No distinct platform-admin dashboard route — PLATFORM_ADMIN and
  tenant-scoped roles land on the same `/` (TenantDashboardPage) after login."
  Severity: suggested MINOR-to-MAJOR (not a defect in the sense of broken behavior —
  the shared landing page renders correctly for every role — but a real gap against
  this requirement's own Why-section framing, and a UX/IA question: should
  PLATFORM_ADMIN eventually land on an operator-facing summary instead of the
  tenant-shaped dashboard). Affected files: `web/src/router.tsx`,
  `web/src/pages/OidcCallbackPage.tsx`.
- **Finding B — no in-app login form exists; unauthenticated visitors are redirected
  off-origin to Keycloak's hosted login page.** Title (suggested): "Login is fully
  delegated to Keycloak's hosted UI — no in-app login form/field-set exists to test
  against, contradicting the assumed 'login form with its actual field set.'" Severity:
  suggested MINOR (this may well be the intended architecture — OIDC redirect is a
  legitimate, common pattern — but it is a documentation/expectation gap, since the
  requirement's own framing assumed an in-app form). Affected files:
  `web/src/auth/ProtectedRoute.tsx`.

Both findings are the *documented real behavior* in §2's scenario `description` and
per-branch `expected_outcomes` — the scenario is authored to test what actually exists,
per AC3's explicit instruction not to silently rewrite it to match the idealized
description.

---

## 6. Which agent executes Step 2a

**Recommendation: `ELIXIR-DEV`**, matching REQ-359's precedent
(`lib/letflow/design/req359-ba-role.md` §5's "Routing note") exactly, for the same
reason: `docs/requirements.yaml`'s REQ-360 entry names `owner: REQ-ANALYST`, but this
run's Step 00 (git setup) was already performed under WF-02's default
backend-implementer convention, and REQ-360's real implementation surface is
artefact-only (one `.yaml` scenario file under `test/fixtures/uat/scenarios/platform/`
— zero `lib/`, zero `priv/repo/migrations/`, zero `web/` component changes). Step 2a's
agent must produce, concretely:

1. The scenario file at §1's path, with §2's exact shape (adjusted for §7 OQ-1's
   QA-account re-verification).
2. Confirmation the file passes `mix letflow.check_uat_scenario_schema` (already
   shipped by REQ-358) — quote the actual per-file `OK` line, not an assertion.
3. Dispatch (via ORCH/WF-05) UAT-RUNNER against the real QA target per §3, and obtain
   the real `test/uat-reports/uat-<date>-<run-id>.yaml` + screenshot baselines per §4.
4. Report Finding A and Finding B (§5) to ORCH for `register_task`/GitHub-issue mirroring
   per `docs/agents/protocols/ISSUE_QUEUE.md` — do not skip this even if UAT-RUNNER's
   execution is otherwise fully green, since AC3 requires the finding regardless of
   pass/fail outcome (the mismatch is structural, not a test failure).

**Test Design (Step 3) routing note**, also mirroring REQ-359 exactly: this
requirement has no application-executable surface for TEST-DESIGNER/TEST-RUNNER in the
`mix test` sense (no new Elixir module, no new component test) — it should route
straight to RELEASE-VALIDATOR per WF-02 Step 3's documented "docs-only" branch, with
RELEASE-VALIDATOR independently re-verifying AC1-3 by reading the actual scenario file,
the actual `mix letflow.check_uat_scenario_schema` output, the actual uat-report file,
the actual screenshot/baseline files, and confirming Findings A/B were actually filed
(queue + mirrored GitHub issue) — not by trusting Step 2a's own summary.

---

## 7. Open questions (not silently resolved)

- **OQ-1 (blocking for real execution) — which seeded QA account carries a
  tenant-scoped role.** §2's second branch lists `[PROCESS_DESIGNER, PROCESS_OPERATOR,
  TASK_WORKER]`, drawn from `AppShell.tsx`'s `Role` type, but this design did not
  independently confirm which of `qa-login.sh`'s seeded accounts (the REQ-358 report
  only exercised `admin-user` (PLATFORM_ADMIN) and `operator-user` (PROCESS_OPERATOR))
  actually carries one of these roles on the **current** QA seed — `operator-user`
  (PROCESS_OPERATOR) is the one already confirmed live by REQ-358's report, so Step 2a
  should default to reusing that exact account for branch 2 rather than assuming a
  PROCESS_DESIGNER/TASK_WORKER account exists, unless it independently confirms one
  does.
- **OQ-2 (blocking for AC2's "screenshots" requirement) — browser-automation tool
  availability at execution time.** `test/uat-reports/uat-2026-09-16-WF02-REQ358-20260916.yaml`
  recorded the throwaway fixture's identical `via: gui` steps as
  `BLOCKED / UNBUILT_FEATURE (frontend leg only)` because no browser-automation tool was
  available to that UAT-RUNNER session. If the same is true when this requirement's
  Step 4 runs, AC2's "screenshots... recorded" cannot be satisfied for real, and the
  correct response (per `.claude/agents/uat-runner.md`'s own existing convention,
  restated in §3 item 6 above) is an honest BLOCKED verdict quoting that fact — never a
  backend-only substitute silently presented as equivalent evidence. This design does
  not resolve whether a browser-automation tool will be available at execution time;
  it is a real environmental risk to flag, not a question CODE-DESIGNER can answer from
  the tree.
- **OQ-3 — whether Finding A (§5) should instead be read as "working as intended."**
  It is possible the product decision is that PLATFORM_ADMIN deliberately lands on the
  same workspace shell as any other role (simpler IA, admin capabilities surfaced via
  nav only) and no separate platform dashboard was ever meant to exist. This design
  does not resolve that product question — it only states the observed fact and files
  it as a finding per AC3's literal instruction ("document the real behaviour and file
  a finding... rather than the scenario being silently rewritten"), leaving the
  business-decision half to whoever triages the finding.
- **OQ-4 — `qa-login.ps1` invocation shape.** The requirement text and REQ-358's design
  both name `qa-login.sh`/`qa-login.ps1` as a pair without fully specifying the
  Windows-host (`qa-login.ps1`) invocation's exact argument shape; REQ-358's own OQ-4
  already flagged the general `ai-dala-infra/`-is-outside-this-repo caveat for
  `credential_source` resolution. This design inherits that same open question rather
  than re-resolving it — whichever host actually executes Step 4's UAT-RUNNER dispatch
  should confirm the concrete invocation against the real script, not guess.

---

## 8. Acceptance-criteria coverage map

| AC | Design element |
|---|---|
| 1 | §1 (exact path), §2 (full scenario YAML shape, `scope: platform`, `branches:`/`when:` covering all three named branches) |
| 2 | §3 (concrete WF-05/UAT-RUNNER dispatch against real QA, `environment_target`), §4 (screenshot/baseline mechanism via `gui_screen`, uat-report path/shape, close-out quoting requirement) |
| 3 | §0 (both real-behavior findings independently re-verified against the actual tree), §2 (scenario documents the real behavior, not the idealized one), §5 (exactly what each finding must say, filed per ISSUE_QUEUE.md by Step 2a) |
