# Design: ISS-0702 — UAT-RUNNER `pipeline_test:` gap fix (GH-1476, queue Q-702)

**Owning agents for implementation:** FRONTEND-DEV (items 1–2, all under `web/` +
one fixture YAML) and a docs-only edit to `.claude/agents/uat-runner.md` (item 3,
not `lib/letflow/` or `priv/repo/migrations/` — **route this requirement to
FRONTEND-DEV, not ELIXIR-DEV**; the agent-doc edit is small enough FRONTEND-DEV
can carry it in the same change set rather than splitting a separate hand-off).

No Elixir/backend code, no migration, no `lib/letflow/` change of any kind.

## 0. Problem recap (do not re-diagnose — already closed by ISSUE-FIXER)

Two consecutive UAT-RUNNER sessions (REQ-358, REQ-360) reported BLOCKED on every
`gui_screen` scenario branch because they searched ToolSearch for an interactive
browser-automation MCP tool, found none, and concluded no browser automation is
possible in this pipeline at all. That conclusion is wrong: `pipeline_test:` specs
are meant to be driven via Bash (`npx playwright test <path>`), and a working,
proven Playwright setup already exists (Chromium installed, real Keycloak login
already exercised in `web/tests/e2e/uat-alice-login.e2e.spec.ts` and
`web/tests/e2e/req133-ac2-ac5.e2e.spec.ts`). The real, narrow gap for this
scenario: `test/fixtures/uat/scenarios/platform/platform-login-routing-by-role.yaml`
has no `pipeline_test:` key, so even a correctly-informed UAT-RUNNER would have
had nothing to invoke. This design closes that one gap and de-ambiguates the
agent doc so the category error doesn't recur on other scenarios in this class.

## 1. New Playwright spec

**Path:** `web/tests/e2e/pipelines/platform-login-routing-by-role.pipeline.e2e.spec.ts`

### 1.1 Module-level setup

Imports:
- `import { test, expect } from '@playwright/test'`
- `import { getKeycloakToken, loginWithToken } from '../helpers'` — use the
  `helpers.ts` two-arg overload (`username, password`, always `bpm-default`
  realm), **not** `pipeline.ts`'s three-arg realm-taking overload — every
  credential this spec needs (`admin-user`, `worker-user`) lives in
  `bpm-default`, confirmed by `web/tests/e2e/req133-ac2-ac5.e2e.spec.ts:64`
  (the `bpm-default` realm discovery check) and `:98`/`:122` (the
  `admin-user`/`worker-user` credentials passed to `getKeycloakToken`). Do
  not import `pipeline.ts`'s `getKeycloakToken`/`loginWithToken` for this
  spec — that module's versions exist for the tenant-realm case
  (`uat-alice-login.e2e.spec.ts`'s `'swiftroute'` realm), which does not
  apply here.
- `import { BPM_IDP_BASE_URL } from '../helpers'` — imported for parity with
  every other spec's reachability precheck (§1.2), even though this spec's own
  assertions don't call it directly beyond that check.

Constants:
```
const APP_BASE_URL = process.env.E2E_BASE_URL ?? 'http://127.0.0.1:4173'
```
(mirrors `web/playwright.config.ts`'s own `baseURL` default exactly — needed
to compute the app's own origin for the off-origin assertion in branch 3,
§1.5).

### 1.2 Reachability precheck (one `test.beforeAll`, shared by all three branches)

Mirror `admin-user-lifecycle.pipeline.e2e.spec.ts`'s precheck pattern:
- `GET ${BPM_IDP_BASE_URL}/realms/bpm-default/.well-known/openid-configuration`
  must be `.ok()` — else throw `Keycloak not reachable: <status>`.
- No backend `/health/ready` precheck is required here (this scenario never
  calls the Letflow API directly; login/routing is entirely IdP + SPA), but
  including it anyway (`process.env.BPM_TEST_URL ?? 'http://127.0.0.1:8080'`,
  `/health/ready`) is acceptable and matches other pipeline specs' convention
  — FRONTEND-DEV's call, not load-bearing either way.

### 1.3 Structure: three `test()` blocks inside one `test.describe`, not a
`createPipeline()` chain

Unlike `admin-user-lifecycle` (a genuine multi-step chain where step N's
output feeds step N+1), this scenario's three branches are **mutually
exclusive alternatives of the same login flow**, not sequential steps — the
scenario YAML itself expresses them as three independent `branches:`, each
with its own single step and its own EO-001. Model that directly as three
independent Playwright `test()` cases in one `test.describe('Pipeline:
platform-login-routing-by-role', ...)` block, each self-contained (own
`page`/`request` fixture, own login, own assertions). Do **not** force this
into `createPipeline()`'s forward-state-accumulation shape — there is no
state to carry between branches, and threading fake state through it would
misrepresent the scenario's real branching structure to future readers of
the file. `pl.step()`/`createPipeline` stays reserved for genuine chains like
`admin-user-lifecycle`.

### 1.4 Branch 1 — `platform_admin_lands_on_workspace_root`

**Test name:** `'EO-001: PLATFORM_ADMIN lands on workspace root with admin nav'`

**Setup:** acquire a token for `admin-user`/`admin-pass` via `getKeycloakToken`,
inject it via `loginWithToken`.

**Assertions to make, and why:**
- URL lands on workspace root `/` — this is EO-001's core routing claim.
- The four PLATFORM_ADMIN-only nav entries are visible, by link name: `Users`,
  `Tenants`, `Health`, `Metrics` (source of truth for which entries are
  admin-gated: `web/src/components/layout/AppShell.tsx`'s `NAV_ITEMS` table,
  lines 25–33 as read for this design — re-check against the file at
  implementation time in case entries changed) — proves the admin nav is
  present.
- The nav entries PLATFORM_ADMIN shares with tenant-scoped roles are *also*
  visible, by link name: `Instances`, `My Tasks` — proves "same workspace
  root" (not a distinct admin-only screen), distinguishing this branch from
  one that merely shows *an* admin page.
- Capture a full-page screenshot as supplementary evidence (see path
  convention below and §1.7 for why no pixel-baseline comparison is made on
  it).

**Screenshot path convention:** reuse `web/tests/e2e/pipeline.ts`'s `shot()`
naming scheme (`tests/screenshots/pipelines/<name>-<step>.png`) by hand since
this spec does not use `createPipeline()` — a literal path string is fine,
FRONTEND-DEV may instead import and call `shot(page, 'platform-login-routing-by-role', 'admin')`
from `../pipeline` if preferred; either satisfies the "primary screenshot
evidence" requirement from ISS-0702's own description. This screenshot is
supplementary evidence attached to the PASS/FAIL already decided by the
assertions above — see §1.7 for why this scenario does NOT use REQ-362's
two-phase pixel-baseline mechanism.

### 1.5 Branch 2 — `tenant_scoped_role_lands_on_workspace_root`

The scenario's `when.op: in` lists three tenant-scoped roles
(`PROCESS_DESIGNER`, `PROCESS_OPERATOR`, `TASK_WORKER`) disjunctively — one
representative role suffices to cover the branch (same convention already
established by `req133-ac2-ac5.e2e.spec.ts`'s AC2, which tests exactly this
class of assertion with the same seeded account). Use `worker-user` /
`worker-pass` (`TASK_WORKER`, `bpm-default` realm) — already proven live in
`req133-ac2-ac5.e2e.spec.ts:67` (`performOidcLogin` call) and `:122`
(`getKeycloakToken` call).

**Test name:** `'EO-001: tenant-scoped role (TASK_WORKER) lands on workspace root with narrower nav'`

**Setup:** acquire a token for `worker-user`/`worker-pass` via
`getKeycloakToken`, inject it via `loginWithToken`.

**Assertions to make, and why:**
- URL lands on workspace root `/` — same core routing claim as branch 1,
  confirming tenant-scoped roles land on the *same* root, not a different
  route.
- `My Tasks` nav entry is visible — the entry a `TASK_WORKER` needs.
- The six PLATFORM_ADMIN-only entries are *not* visible, by link name:
  `Users`, `Tenants`, `Register Tenant`, `Audit`, `Health`, `Metrics` — proves
  the nav is narrower than branch 1's, per EO-001's "narrower nav" wording.
  (Nav-label/role source of truth: `web/src/components/layout/AppShell.tsx`
  lines 20–47 — re-check against that file at implementation time in case nav
  entries changed since this design was written.)
- Capture a full-page screenshot as supplementary evidence, same convention
  as §1.4.

### 1.6 Branch 3 — `unauthenticated_redirects_to_external_login`

EO-001's own detail text is concrete and unambiguous — no REVIEWER escalation
needed: "the app briefly shows the `data-testid=\"auth-loading\"`
... placeholder, then the browser is redirected off-origin to the configured
OIDC authority's own hosted login page." Two assertable facts, both
deterministic.

**Test name:** `'EO-001: unauthenticated visitor sees auth-loading then redirects off-origin to Keycloak'`

**Setup:** no `loginWithToken`/`getKeycloakToken` call in this branch —
deliberately no session is injected, matching the scenario's own precondition
("no token, no cookie"). Navigate to the app root.

**Assertions to make, and why:**
- The `auth-loading` testid (`web/src/auth/ProtectedRoute.tsx:26`) becomes
  visible, within a bounded wait — covers "briefly shows... the placeholder."
  It may already be gone by the time the wait resolves on a fast redirect;
  treat a resolved wait as pass, a hard timeout as fail (do not swallow the
  timeout the way `loginWithToken`'s own best-effort waits do — this IS the
  assertion here, not a soft check).
- The browser's URL origin changes away from the app's own origin
  (`APP_BASE_URL`'s origin, per §1.1) within a bounded wait, and the final
  URL's origin is confirmed not equal to the app origin — covers "redirected
  off-origin to the configured OIDC authority" (Keycloak runs on a different
  host:port; see `BPM_IDP_BASE_URL`).
- Capture a full-page screenshot as supplementary evidence, same convention
  as §1.4.

### 1.7 Why this spec does NOT use REQ-362's two-phase pixel-baseline mechanism

`verification.method: gui_screen` in the scenario YAML triggers
`uat-runner.md`'s two-phase baseline procedure (`visual-baseline.ts`) in the
*general* case, where "correct" is a subjective judgment call about how a
screen looks (used today only by
`req362-visual-regression.e2e.spec.ts`'s self-check). This scenario's three
EO-001s are different in kind: each one's "expected outcome" is a concrete,
mechanically-checkable fact already stated in the scenario's own `detail`
text (an exact route, a specific nav item's visibility, a specific
`data-testid`, an origin change) — not "does this screen look right." Coding
these as hard Playwright `expect()` assertions (§1.4–1.6, same style already
proven in `req133-ac2-ac5.e2e.spec.ts`) gives UAT-RUNNER a real, deterministic
PASS/FAIL without asking it to perform subjective pixel-level judgment on
data that isn't a look-and-feel question. The `page.screenshot()` calls in
each branch still satisfy ISS-0702's "primary screenshot evidence" language —
they are attached evidence for a fact already decided by assertion, exactly
as `req133-ac2-ac5.e2e.spec.ts` and `uat-alice-login.e2e.spec.ts` already do
today (screenshot + concrete assertion/log side by side, no pixel diffing).
Do not additionally route these three EOs through `acceptBaseline`/
`baselineExists`/`toHaveScreenshot` — that machinery stays reserved for
scenarios where "looks right" genuinely has no cheaper mechanical proxy.

If REVIEWER disagrees with this framing on review, that is a legitimate
place to push back — flagging it here explicitly rather than silently
deciding it's obviously right, since it is a judgment call about how
`gui_screen` verification should generally be discharged, made once here for
FRONTEND-DEV to implement, not re-litigated per scenario.

## 2. `pipeline_test:` key in the scenario fixture

**File:** `test/fixtures/uat/scenarios/platform/platform-login-routing-by-role.yaml`

Add a **top-level** `pipeline_test:` key (same document level as `id:`,
`scope:`, `branches:` — confirmed convention from
`test/fixtures/uat/scenarios/platform/template-update-conflict-resolution.yaml:28`
and `.../attachment-cross-tenant-probe.yaml:27`, both top-level, not nested
under `branches:` or `expected_outcomes:`):

```yaml
pipeline_test: web/tests/e2e/pipelines/platform-login-routing-by-role.pipeline.e2e.spec.ts
```

Place it immediately after the `cleanup:` block (end of file) or immediately
after the `description:` block near the top — either position matches
existing precedent (the two reference files above both place it right after
their narrative `description:`, before `actors:`); FRONTEND-DEV's choice,
not load-bearing. **Do not** add an `ISS-0527`-style "NOTE: this spec file
does not exist" comment the way the 28 aspirational scenarios do — this
spec genuinely exists once item 1 lands, so no disclaimer is needed or
correct here.

## 3. `.claude/agents/uat-runner.md` — de-ambiguate the `pipeline_test:` paragraph

**Current text** (the paragraph ending "...Read each narrative field as an
instruction to *you*: perform the `action` for real (real HTTP call, or real
GUI interaction via `pipeline_test:` once wired in)..." — approx. lines
44–52 in the file as currently read):

> Read each narrative field as an instruction to *you*: perform the `action`
> for real (real HTTP call, or real GUI interaction via `pipeline_test:` once
> wired in), then check the state described in each
> `expected_outcomes[].detail`/`.evidence` against the real running instance,
> same discipline as your "no mocks, no absence-of-error as pass" rule above.
> A `pipeline_test:` key names a Playwright spec to drive for GUI-only
> scenarios; if that file does not exist or carries a `NOTE (ISS-0526)`
> comment marking it unresolved, record the scenario BLOCKED/UNBUILT_FEATURE
> on its frontend leg rather than skipping it silently or inventing a
> substitute API-only path.

**Root cause of the misread (per ISSUE-FIXER):** "real GUI interaction via
`pipeline_test:` once wired in" and "A `pipeline_test:` key names a
Playwright spec to drive" together read as passive/ambiguous about *how* the
spec gets driven — imprecise enough that two consecutive sessions concluded
"the browser-automation tool this needs doesn't exist" (a category error:
they searched ToolSearch for an interactive MCP browser-control tool, found
none, and stopped) rather than "invoke this file via Bash." Nothing in the
current text tells the reader the driving mechanism is a shell command they
already have.

**Required edit — replace the two sentences above with:**

> Read each narrative field as an instruction to *you*: perform the `action`
> for real. For a `gui:` step, that means real GUI interaction — driven by
> running the scenario's own `pipeline_test:` Playwright spec, if it has one,
> via Bash: `npx playwright test <pipeline_test path>` (run from `web/`, or
> `--config=web/playwright.config.ts` from the repo root). **This is a Bash
> invocation of an existing, already-installed Playwright spec file — not an
> interactive browser-control tool.** Do not search ToolSearch for a
> browser/MCP tool to drive `gui_screen` verification; none exists in this
> pipeline and none is needed — `npx playwright test` runs a real Chromium
> browser headlessly and reports pass/fail plus screenshots on disk, which is
> the entire mechanism. Then check the state described in each
> `expected_outcomes[].detail`/`.evidence` against the real running instance
> — read the spec's console output and the screenshots it wrote under
> `web/tests/screenshots/pipelines/` (or wherever the spec documents saving
> them) — same discipline as your "no mocks, no absence-of-error as pass"
> rule above.
>
> A `pipeline_test:` key at the scenario's top level names the Playwright
> spec (relative to the repo root, e.g.
> `web/tests/e2e/pipelines/<name>.pipeline.e2e.spec.ts`) to drive for
> GUI-only scenarios this way. If the scenario has no `pipeline_test:` key at
> all, or the named file does not exist, or it carries a `NOTE (ISS-0526)` /
> `NOTE (ISS-0527)` comment marking it an unresolved aspirational
> forward-reference, record the scenario BLOCKED/UNBUILT_FEATURE on its
> frontend leg rather than skipping it silently or inventing a substitute
> API-only path — that is a real, correctly-reported gap (see
> `docs/issues/ISS-0527.yaml`'s backlog of 27 such files), not something to
> route around by searching for a different tool.

This is a doc-only diff to `.claude/agents/uat-runner.md`; no other section
of that file needs to change for this fix (the two-phase `gui_screen`/REQ-362
section further down already correctly describes baseline mechanics and does
not carry the same ambiguity).

## 4. Acceptance-criteria mapping

| Scope item | Design element |
|---|---|
| Spec covers all 3 branches | §1.4 (PLATFORM_ADMIN), §1.5 (tenant-scoped/TASK_WORKER), §1.6 (unauthenticated) |
| Reuse `getKeycloakToken`/`loginWithToken`/`BPM_IDP_BASE_URL` | §1.1 — pinned to `helpers.ts`'s two-arg overload, with the specific reason `pipeline.ts`'s realm-taking overload is wrong here |
| Reuse REQ-362 `visual-baseline.ts` helpers where applicable | §1.7 — explicit reasoned decision NOT to use them for this scenario's EOs, with the mechanism (`page.screenshot()`) that still satisfies the screenshot-evidence requirement |
| Unauthenticated branch asserts `page.url()` leaves app origin (EO-001) | §1.6 |
| `pipeline_test:` key added, correct format/location | §2 |
| `.claude/agents/uat-runner.md` says Bash/`npx playwright test`, not an interactive tool search | §3 |
| Out of scope: ISS-0527's 27 other files | Not touched — §2 explicitly scopes this edit to one file only |
| Out of scope: ISS-0703 (PLATFORM_ADMIN HTTP 500) | Not referenced anywhere in this design; this design's branch 1 assumes login/routing succeeds, independent of that separate regression |

## 5. Open questions / flags for REVIEWER

1. **§1.7's framing decision** (hard assertions instead of REQ-362's
   pixel-baseline two-phase flow for this scenario's `gui_screen` EOs) is a
   real judgment call about how `gui_screen` verification should generally
   be discharged when the expected outcome is a mechanically-checkable fact
   rather than a subjective "looks right" — flagged explicitly, not
   silently decided, per this task's own instructions. Recommend REVIEWER
   either confirm this framing (in which case it's worth a one-line note
   added to `uat-runner.md`'s two-phase section clarifying it's not
   mandatory for every `gui_screen` EO) or override it before FRONTEND-DEV
   implements.
2. Screenshot output directory convention (§1.4, `tests/screenshots/pipelines/`)
   is inferred from `pipeline.ts`'s `shot()` helper's `SCREENSHOTS_DIR`
   constant, not from an existing precedent for a non-`createPipeline()`
   spec — low-risk, FRONTEND-DEV may adjust the literal path without a
   design revision if a different convention is already in flight elsewhere.
