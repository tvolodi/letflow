# Design: ISS-0706 — e2e readiness-precondition fix

**Scope: `web/`-only test-infrastructure change.** No `lib/letflow/` or
`priv/repo/migrations/` file is touched by this design. Route implementation to
`FRONTEND-DEV`, not `ELIXIR-DEV`. Nothing here touches a tenant-data path (it changes
which URL a Playwright precondition polls and tightens a test assertion) — expect
SECURITY-REVIEWER's Step 2c to record "out of scope."

## 0. Root cause recap (not re-diagnosed here, per task instructions)

`lib/letflow/router.ex`'s own moduledoc (lines 51-55) documents that R-Co's readiness
endpoint (`GET /health/ready`) was deliberately never ported — it needs S6 observability
probes that don't exist yet. Only `GET /health` (liveness, `{"status":"ok"}`, no DB/auth)
is mounted. 11 e2e spec files poll `/health/ready` as a precondition and throw if it
isn't `.ok()`, so every test in every one of those files fails before reaching its real
assertions, always. `web/src/api/health.ts` had the identical bug in application code
and was fixed in ISS-0532 by pointing at the real `GET /health` instead — this design
mirrors that resolution for the test suite.

## 1. Correction to the issue record's file list (verify-before-build, not a silent fix)

`docs/issues/ISS-0706.yaml`'s `affected_files` lists
`web/tests/e2e/sh05-06.shell.e2e.spec.ts` as one of the 11. Reading it shows this is
stale: the file's own header comment already says *"Updated: ISS-0532
(WF03-ISS0532-20260908) — the banner's probe was moved from the non-existent `GET
/health/ready` to the real `GET /health` liveness endpoint... These tests now stub
`/health`."* The file contains zero references to `assertServiceReadiness` or
`/health/ready` and does not call a readiness precondition at all — it stubs `/health`
via `page.route()`. **This file needs no change.** Per
`docs/anti-patterns.md`'s "Inheriting a claim from a record instead of re-deriving it
from the source," this is flagged explicitly rather than silently dropped or (worse)
silently "fixed" with a no-op edit. TEST-DESIGNER/CODE-DESIGN-VALIDATOR: the real scope
is **10 files**, not 11.

The remaining 10, confirmed by direct read, genuinely contain the bug:

| File | Shape of its readiness check |
|---|---|
| `env04.e2e.spec.ts` | Plain two-part (backend + Keycloak discovery) |
| `f5-admin-observability.e2e.spec.ts` | Plain two-part |
| `f6-webhooks.e2e.spec.ts` | Plain two-part |
| `tenants.e2e.spec.ts` | Plain two-part |
| `f5-admin-groups-tokens.e2e.spec.ts` | Plain two-part |
| `f5-admin-users.e2e.spec.ts` | Plain two-part |
| `f6-dlq.e2e.spec.ts` | Plain two-part |
| `tenant-dashboard.e2e.spec.ts` | Plain two-part, **plus** the TC-TD-UI-01-04 `if (swiftResp.ok())` defect |
| `iss-0063-oidc-redirect-loop.e2e.spec.ts` | Variant: env-var checks + backend + inline Keycloak discovery |
| `uat-tenant-url.e2e.spec.ts` | Variant: two separate functions, backend-only + a genuine IdP `/health/ready` probe |

"Plain two-part" is byte-identical in structure across all 8 rows so labeled, confirmed
by direct read of each: `GET {API_BASE_URL}/health/ready` → throw if `!ok()`, then
`GET {BPM_IDP_BASE_URL}/realms/bpm-default/.well-known/openid-configuration` → throw if
`!ok()`. Only the thrown error-message wording differs between files.

## 2. Direction chosen: (b), extending the existing `helpers.ts` convention — with reasoning

`web/tests/e2e/helpers.ts` already is this codebase's established location for
cross-cutting e2e primitives shared across the suite: `getKeycloakToken`,
`loginWithToken`, `BPM_IDP_BASE_URL`, `BPM_IDP_CLIENT_ID`. All 10 in-scope files already
import at least one of those from `./helpers`. Extending it rather than inventing a new
file matches "wherever fits this codebase's existing convention," per the task's framing
of option (b).

Rejected: option (a), redirect each of the 10 files' own local copy of the URL in place.
This mirrors ISS-0532's specific edit, but ISS-0532 was a single call site
(`web/src/api/health.ts`); here the same bug is already duplicated 10 times, and the
issue record itself asks to weigh "so this doesn't recur an 12th time." Patching 10
near-identical local functions in place leaves the copy-paste risk exactly as it was —
an 11th spec file added later (there is already a documented history in this project,
per `docs/anti-patterns.md`, of the same class of duplication recurring after being
flagged once) would still hand-roll its own `/health/ready` call unless it happens to
notice and copy one of the 10 fixed versions. Extracting one shared, exported function
removes that recurrence path structurally: a new spec file imports `helpers.ts` for
login anyway, so the readiness check becomes "the same import block, one more name" set
instead of a fresh copy-paste target.

**Why the shared function is scoped to backend-liveness + Keycloak-discovery jointly for
the 8 "plain" files, but only backend-liveness for the other 2:** the Keycloak
`.well-known/openid-configuration` check is not the bug ISS-0706 is about — it polls a
real, currently-working endpoint. It happens to be bundled with the broken backend check
in all 8 "plain" files, and it is *also* byte-identical (same URL-construction formula,
confirmed by grep) across all 8, so folding both into one shared `assertServiceReadiness`
eliminates that latent duplication too, at no extra risk, using data already available in
`helpers.ts` (`BPM_IDP_BASE_URL`). `iss-0063-oidc-redirect-loop.e2e.spec.ts` and
`uat-tenant-url.e2e.spec.ts` are shaped too differently to fold in (see §4) — they get
the narrower, backend-only primitive instead and keep their own extra local logic
untouched.

## 3. `web/tests/e2e/helpers.ts` — additions

Two new exported async functions, appended after the existing `loginWithToken`. No
existing export's signature changes.

```
assertBackendHealthy(request: APIRequestContext, apiBaseUrl: string): Promise<void>
```
- Input: an active Playwright `APIRequestContext`, and the caller's own resolved backend
  base URL (each spec file keeps its own `API_BASE_URL`/`apiBaseUrl` constant and its own
  fallback-default logic — those differ slightly between files today, e.g.
  `iss-0063-oidc-redirect-loop.e2e.spec.ts` defaults to `''` and requires the env var,
  others default to `http://127.0.0.1:8080`; this design does not touch or unify that,
  it is a separate, pre-existing minor inconsistency, out of scope for ISS-0706 — see
  Open Questions).
- Behavior: `GET {apiBaseUrl}/health`. If the response is not `.ok()`, throw an `Error`
  whose message names the actual endpoint polled and the actual status code returned,
  e.g. `` `Backend not live (${status}) at ${apiBaseUrl}/health` ``, plus one line noting
  this is a liveness check, not a full readiness probe (see the doc-comment shape below).
  Never returns a boolean; only resolves (success) or throws (failure) — same contract as
  every function it replaces.
- Output: `Promise<void>`, resolves on 2xx, rejects (throws) otherwise. No swallowed
  errors — a network failure propagates as an unhandled rejection from
  `request.fetch`/`request.get`, exactly as today's local copies already behave (none of
  the 10 wrap the fetch itself in try/catch).
- Doc-comment (required, since this function's very existence documents the semantic
  correction ISS-0706/ISS-0532 are both about): state plainly that this checks the real
  `GET /health` liveness endpoint, that a true per-subsystem readiness probe does not
  exist until S6 lands, and link `ISS-0532`/`ISS-0706`/`lib/letflow/router.ex`'s moduledoc
  the same way `web/src/api/health.ts`'s existing ISS-0532 comment does.

```
assertServiceReadiness(request: APIRequestContext, apiBaseUrl: string): Promise<void>
```
- Input/output shape: identical to `assertBackendHealthy` above.
- Behavior: calls `assertBackendHealthy(request, apiBaseUrl)` first; if that throws, the
  Keycloak check never runs and the original error propagates unchanged (fail fast on the
  first broken dependency, same order every existing "plain" file already uses: backend
  before IdP). Then performs the existing, unchanged Keycloak discovery check: `GET
  {BPM_IDP_BASE_URL}/realms/bpm-default/.well-known/openid-configuration` (using
  `helpers.ts`'s own already-exported `BPM_IDP_BASE_URL` — no new parameter needed for
  this part, since that value is already centralized). If not `.ok()`, throw an `Error`
  naming the discovery URL and status, in the same shape the 8 files already use today.
- This is a pure move, not a rewrite of behavior: every one of the 8 "plain" call sites
  gets the same two checks in the same order with the same failure semantics they have
  today, except the first check now hits a URL that can actually return 2xx.

## 4. Per-file changes

**8 "plain" files** (`env04.e2e.spec.ts`, `f5-admin-observability.e2e.spec.ts`,
`f6-webhooks.e2e.spec.ts`, `tenants.e2e.spec.ts`, `f5-admin-groups-tokens.e2e.spec.ts`,
`f5-admin-users.e2e.spec.ts`, `f6-dlq.e2e.spec.ts`, `tenant-dashboard.e2e.spec.ts`):
1. Add `assertServiceReadiness` to each file's existing `import { ... } from './helpers'`
   line (all 8 already have one).
2. Delete the file's own local `async function assertServiceReadiness(...) { ... }`
   definition in full (both the backend-check block and the Keycloak-discovery block —
   the shared function now does both).
3. Delete the file's own now-unused local `KEYCLOAK_DISCOVERY_URL` constant, if the
   deleted function was its only reader (confirmed true for all 8 by grep — each file's
   only use of that constant is inside the function just removed).
4. Every existing call site (`await assertServiceReadiness(request)`) becomes `await
   assertServiceReadiness(request, API_BASE_URL)` — passing the file's own existing
   `API_BASE_URL` constant, unchanged in how it's derived. Call-site count per file is
   unchanged (e.g. `env04.e2e.spec.ts` keeps its 3 call sites, `tenant-dashboard.e2e.spec.ts`
   keeps its 8).
5. No other line in any of these 8 files changes as part of this design, **except**
   `tenant-dashboard.e2e.spec.ts`'s TC-TD-UI-01-04 body — see §5.

**`iss-0063-oidc-redirect-loop.e2e.spec.ts`:**
1. Add `assertBackendHealthy` to its existing `import { ... } from './helpers'` line.
2. Inside `ensurePrerequisites`, replace only the backend-check block (currently `const
   backendHealth = await request.get(...); if (!backendHealth.ok()) { throw ... }`) with
   `await assertBackendHealthy(request, apiBaseUrl)`. Its own `requireEnv` calls (env-var
   presence checks) and its own inline Keycloak discovery check stay exactly as they are
   — neither is the ISS-0706 bug, and folding the Keycloak-discovery half into the shared
   helper here would require this file to stop naming its own `KEYCLOAK_DISCOVERY_URL`
   constant it already uses for a second, unrelated purpose (the assertion at what is
   currently line 46-48) — not a clean fit, left alone.

**`uat-tenant-url.e2e.spec.ts`:**
1. Add `assertBackendHealthy` to its existing `import { ... } from './helpers'` line.
2. Replace the body of its local `requireBackendReady` (currently `GET
   {apiBaseUrl}/health/ready`) with a call to `assertBackendHealthy(request, apiBaseUrl)`
   — same fix, same reasoning, applied to a function whose only job is the Letflow
   backend check.
3. **`requireIdpReady` is explicitly NOT changed.** It polls `{idpBaseUrl}/health/ready`
   against `BPM_IDP_BASE_URL` — i.e. Keycloak's own readiness endpoint, not Letflow's.
   Keycloak (run with `KC_HEALTH_ENABLED=true`, which this project's IdP container uses)
   exposes a real `/health/ready`. This is a different service with a different, working
   contract; ISS-0706's root cause (Letflow's router never mounting `/health/ready`) does
   not apply to it. Touching this line would be scope creep beyond what the issue
   diagnosed. Flagging this explicitly so ELIXIR-DEV/FRONTEND-DEV doesn't pattern-match
   "every `/health/ready` string in these 10 files" and redirect this one too.

## 5. TC-TD-UI-01-04's `if (swiftResp.ok())` silent-noop fix

Current shape (`tenant-dashboard.e2e.spec.ts`, inside `TC-TD-UI-01-04`): the test fetches
the `swiftroute` tenant record, then only runs the cross-tenant-leakage assertion inside a
conditional guarding on that fetch having succeeded; the unconditional assertions about the
logged-in tenant's own tiles run either way. If `swiftroute` isn't provisioned, the leakage
assertion is skipped entirely and the test still reports PASS — proving nothing about
cross-tenant isolation, exactly the defect ISS-0706 names.

**Fix, mirroring the pattern this same file already uses at `TC-TD-UI-03-01` (lines
~433-442) for the identical prerequisite** — invert the guard so the test hard-fails with a
clear diagnostic when the `swiftroute` fetch does not succeed, instead of silently
no-op'ing the leakage check. No new assertion logic is needed: the existing
locator/text-collection/`not.toContain` leakage-check statements that currently live inside
the `if (swiftResp.ok())` body move out from behind the conditional and simply always run,
with a new hard-fail branch (a thrown `Error`) taking over the "prerequisite missing" case
that the conditional used to swallow silently. The thrown error's message follows
`TC-TD-UI-03-01`'s own established format in the same file — `<test id> prerequisite not
satisfied: GET <path> returned <status>. Run <pipeline file>.`, naming
`TC-TD-UI-01-04`, the `/api/v1/tenants/swiftroute` path, the actual status code returned,
and the swiftroute onboarding pipeline file (`sim-company-onboarding.pipeline.e2e.spec.ts`)
as the remediation — so a future reader sees one consistent failure style for this fixture
dependency across the file, not two different ones.

Also update the test's own doc-comment (currently: *"If swiftroute is not provisioned,
the test still validates that the default tenant heading is shown... without cross-tenant
leakage in the heading region"* — describes exactly the no-op behavior being removed) to
state the new, stricter precondition plainly, same shape as `TC-TD-UI-03-01`'s own
comment ("Uses the SwiftRoute tenant if provisioned; fails with a clear message
otherwise" / "PREREQUISITE: ... must exist in the database. If not: run the tenant
onboarding pipeline first").

## 6. Acceptance-criteria mapping

| Acceptance criterion (from ISS-0706) | Design element |
|---|---|
| All 11 (in fact 10, see §1) named spec files stop polling the never-mounted `/health/ready` as their precondition | §4: every in-scope file's backend check now calls `assertBackendHealthy`/`assertServiceReadiness`, which polls `GET /health` |
| Duplication eliminated so a 12th copy-paste can't recur | §2/§3: single exported `assertServiceReadiness`/`assertBackendHealthy` in `helpers.ts`, the file every e2e spec already imports from |
| `TC-TD-UI-01-04`'s `if (swiftResp.ok())` gate made unconditional / hard-fails | §5 |
| `uat-tenant-url.e2e.spec.ts`'s IdP readiness check is not broken by this fix | §4, explicit non-change with rationale |
| `sh05-06.shell.e2e.spec.ts` (issue record's file list) | §1: verified already fixed under ISS-0532; no change needed; flagged as a stale record entry |

## 7. Open questions

1. **Function naming vs. semantics.** `assertServiceReadiness` now performs a liveness
   check against `/health` plus a Keycloak discovery check, not a true readiness check —
   the same "name says readiness, endpoint says liveness" mismatch ISS-0532 fixed in
   `web/src/api/health.ts` by keeping the misleading old name `healthReady()` with a
   corrective doc-comment, rather than renaming it. This design follows that precedent
   (keep the established name, correct via doc-comment) to minimize call-site churn across
   8 files that already reference it by this name in `beforeEach`/inline calls. If
   REVIEWER prefers a rename (e.g. `assertServiceReachable`) for clarity now that it lives
   in one shared, prominent location rather than 8 private copies, that's a defensible
   alternative — flagging rather than silently deciding, since the ISS-0532 precedent this
   design leans on made the opposite call for a reason (minimizing churn) that may or may
   not still apply once the function is centralized.
2. **Should the precondition be dropped rather than redirected?** Per the task's own
   framing: `GET /health` and the never-built `/health/ready` may carry different intended
   semantics (liveness vs. full subsystem readiness) worth preserving as a distinction,
   or may not matter for this suite's purposes. This design keeps a precondition (redirected
   to `/health`) rather than deleting it outright, because every one of the 10 files' own
   comments frame it as "fail fast with a clear diagnostic if the backend isn't up," which
   `/health` still serves adequately (liveness is a legitimate, weaker precondition than
   full readiness, and is what ISS-0532 judged sufficient for the application code's
   equivalent check). Flagging per the task's instruction rather than treating this as
   uncontestable: if REVIEWER judges that a liveness-only precondition is misleading enough
   to warrant removing it entirely (accepting that tests would then fail with whatever
   error the first real API call produces, rather than a dedicated prerequisite message),
   that's a legitimate alternative this design does not adopt.
3. **`API_BASE_URL` default-value inconsistency across files** (noted in §3) is real,
   pre-existing, and not part of ISS-0706's diagnosed bug — left untouched, flagged in
   case ORCH wants to file it as its own follow-up issue rather than silently carrying it
   forward unaddressed.
4. **The `f5-admin-observability.e2e.spec.ts` `readinessCalls` counter** (test body,
   `TC-ADM-UI-09-01`, watches `page.on('response')` for URLs containing `/health/ready`)
   is unrelated to the precondition function this design changes — it counts requests the
   *application under test* (the admin Health dashboard page) makes at runtime. Per
   ISS-0532's resolution, that page's own runtime health polling already calls `/health`,
   not `/health/ready` — meaning this counter is very likely already permanently 0,
   independent of ISS-0706, making its before/after-refresh comparison vacuous. This is a
   distinct, pre-existing defect in that one test's own assertions, not the duplicated
   precondition pattern ISS-0706 is about, and is not fixed by this design. Flagging per
   `core-directives.md`'s "Unblock-Everything" scope boundary (an incidental finding,
   not something blocking this fix) — report it to ORCH as a new finding rather than
   silently expanding this fix's scope to cover it.

## 8. Non-goals (explicit, so REWORK doesn't ask for these)

- No change to `lib/letflow/router.ex` or any backend file — the deliberate
  non-porting decision for `/health/ready` stands, unchallenged, per the router's own
  moduledoc and `core-directives.md`'s decision-record rule.
- No change to `web/src/api/health.ts` (already fixed under ISS-0532).
- No attempt to make `npm run test:e2e` runnable in CI as part of this fix — that's a
  separate, larger concern (`web/README.md` already notes this suite has never run
  against Letflow; establishing that is `REQ-122`, out of scope here).
- No unification of the `API_BASE_URL` default-value logic across files (§7.3).
- No fix to the `readinessCalls` counter in `f5-admin-observability.e2e.spec.ts` (§7.4).
