# Design: ISS-0707 — e2e readiness-precondition fix (ISS-0706 follow-up)

**Scope: `web/`-only test-infrastructure change.** No `lib/letflow/` or
`priv/repo/migrations/` file is touched. Route implementation to `FRONTEND-DEV`, not
`ELIXIR-DEV`. Nothing here touches a tenant-data path (it changes which URL a Playwright
precondition polls) — expect SECURITY-REVIEWER's Step 2c to record "out of scope," same
disposition as ISS-0706.

## 0. Root cause (not re-diagnosed here, per task instructions)

Identical to ISS-0706: `lib/letflow/router.ex`'s moduledoc (lines 51-55) documents that
`GET /health/ready` is deliberately never mounted (needs S6 observability probes that
don't exist yet). Only `GET /health` (liveness) is mounted. ISS-0706 already fixed 10
files by extracting `assertBackendHealthy`/`assertServiceReadiness` into
`web/tests/e2e/helpers.ts`, pointed at the real `GET /health`. Those two functions exist
on `main` today, unchanged by this design (verified by direct read — see below). This
design applies the same, already-proven mechanism to the 9 files ISS-0706's grep missed.

## 1. Verify-before-build: confirmed shape of all 9 files (direct read)

All 9 files were read in full. Every one polls `${API_BASE_URL}/health/ready` then
`${BPM_IDP_BASE_URL}/realms/bpm-default/.well-known/openid-configuration` as a hard-fail
precondition — the same "plain two-part" shape ISS-0706 fixed in 8 of its 10 files. None
of the 9 matches the two ISS-0706 *exception* shapes (`iss-0063-oidc-redirect-loop`'s
env-var-gated variant, or `uat-tenant-url`'s genuine-external-IdP-readiness variant) — no
exception handling is needed here, unlike ISS-0706.

**Import-path finding (the variation the task asked to check for):** all 9 files already
import `BPM_IDP_BASE_URL` directly from `'../helpers'` (confirmed by grep — a plain
`import { BPM_IDP_BASE_URL } from '../helpers'` line in every file). 8 of the 9 *also*
import `getKeycloakToken`, `loginWithToken`, `navigateSpa`, etc. from a **different**
module, `web/tests/e2e/pipeline.ts` (`'../pipeline'`), which re-implements its own
`getKeycloakToken`/`loginWithToken` independent of `helpers.ts`'s versions and does not
itself export or re-export any readiness/health helper. This does not change the fix
mechanism: `assertBackendHealthy`/`assertServiceReadiness` are added to each file's
existing `from '../helpers'` import line (the one already present in all 9), never to
the `'../pipeline'` import line. `pipeline.ts` itself is not touched by this design.

Two shapes found across the 9, both reducible to the same helper call:

| Shape | Files | Call form |
|---|---|---|
| Local function, named `assertServicesReady` (plural "Services") | `onb-ui-01/02/03/04.e2e.spec.ts`, `admin/services.e2e.spec.ts` | Function defined once per file, called from 1+ test bodies |
| Inline in the test body, no wrapping function | `pipelines/onboarding-wizard.pipeline.e2e.spec.ts`, `pipelines/sim-admin-processes.pipeline.e2e.spec.ts`, `pipelines/admin-user-lifecycle.pipeline.e2e.spec.ts`, `pipelines/sim-company-onboarding.pipeline.e2e.spec.ts` | Two `await request.fetch(...)` + `if (!ok) throw` blocks directly in the `test(...)` callback, one call site each |

A further, genuine behavioral split within both shapes (relevant to §4's "no
speculative behavior change" scope note):

| Network-failure handling | Files |
|---|---|
| Swallows a network failure into a clean thrown "not ready" error: `await request.fetch(url).catch(() => null)` then `if (!resp?.ok())` | `onb-ui-01/02/03/04.e2e.spec.ts`, `pipelines/onboarding-wizard.pipeline.e2e.spec.ts` |
| No catch — a network failure propagates as-is (unhandled rejection), only a non-2xx response is turned into the custom thrown error | `admin/services.e2e.spec.ts`, `pipelines/sim-admin-processes.pipeline.e2e.spec.ts`, `pipelines/admin-user-lifecycle.pipeline.e2e.spec.ts`, `pipelines/sim-company-onboarding.pipeline.e2e.spec.ts` |

`helpers.ts`'s existing `assertBackendHealthy`/`assertServiceReadiness` (unchanged by
this design) use the **no-catch** form — see §5, Open Question 1, for the one genuine
behavior delta this introduces for the 5 "swallows network failure" files.

`KEYCLOAK_DISCOVERY`/`KEYCLOAK_DISCOVERY_URL` constant check: in every one of the 9
files, grep confirms the constant's only reader is the readiness block being removed —
safe to delete in all 9, same as ISS-0706's 8 "plain" files.

## 2. Fix mechanism (already built, not re-designed here)

Reuse `web/tests/e2e/helpers.ts`'s existing exports, unchanged:

```
assertBackendHealthy(request: APIRequestContext, apiBaseUrl: string): Promise<void>
assertServiceReadiness(request: APIRequestContext, apiBaseUrl: string): Promise<void>
```

All 9 files perform both the backend check and the Keycloak-discovery check (no
backend-only case among these 9, unlike ISS-0706's `iss-0063`/`uat-tenant-url`) — every
one of the 9 gets `assertServiceReadiness`, none gets the narrower
`assertBackendHealthy` alone.

## 3. Per-file changes

**Function-wrapped shape (5 files: `onb-ui-01.e2e.spec.ts`, `onb-ui-02.e2e.spec.ts`,
`onb-ui-03.e2e.spec.ts`, `onb-ui-04.e2e.spec.ts`, `admin/services.e2e.spec.ts`):**

1. Add `assertServiceReadiness` to the file's existing `import { ... } from '../helpers'`
   line (each already imports `BPM_IDP_BASE_URL` from there).
2. Delete the file's own local `async function assertServicesReady(...) { ... }`
   definition in full (both the backend-check block and the Keycloak-discovery block).
3. Delete the file's own now-unused local `KEYCLOAK_DISCOVERY`
   (`admin/services.e2e.spec.ts`: `KEYCLOAK_DISCOVERY_URL`) constant — confirmed the
   deleted function was its only reader in all 5 files.
4. Every existing call site — `await assertServicesReady(request)` — becomes `await
   assertServiceReadiness(request, API_BASE_URL)`, passing the file's own existing
   `API_BASE_URL` constant unchanged in how it's derived. Call-site count per file is
   unchanged: `onb-ui-01.e2e.spec.ts` keeps its 2, `onb-ui-02.e2e.spec.ts` keeps its 5,
   `onb-ui-03.e2e.spec.ts` keeps its 2, `onb-ui-04.e2e.spec.ts` keeps its 3,
   `admin/services.e2e.spec.ts` keeps its 1.
5. No other line in any of these 5 files changes as part of this design.

Note the local function name (`assertServicesReady`, plural "Services") differs from
`helpers.ts`'s exported name (`assertServiceReadiness`, singular "Service" +
"Readiness") — every call site's spelling changes accordingly; this is a rename at each
call site, not just an argument-list change. Flagging so FRONTEND-DEV doesn't do a
find-replace assuming the names already match.

**Inline shape (4 files: `pipelines/onboarding-wizard.pipeline.e2e.spec.ts`,
`pipelines/sim-admin-processes.pipeline.e2e.spec.ts`,
`pipelines/admin-user-lifecycle.pipeline.e2e.spec.ts`,
`pipelines/sim-company-onboarding.pipeline.e2e.spec.ts`):**

1. Add `assertServiceReadiness` to the file's existing `import { ... } from '../helpers'`
   line.
2. Replace the inline two-block precondition (the `const backendResp = await
   request.fetch(...)` / `if (!...) throw ...` pair followed by the matching Keycloak
   block, both directly inside the `test(...)` callback under the `// ── Pre-checks
   ──`/`// Pre-check:` comment) with a single `await assertServiceReadiness(request,
   API_BASE_URL)` statement in the same position in the callback body. One call site per
   file, unchanged in count and position (each of these 4 files only checks readiness
   once, at the start of its single `test(...)` body, before the pipeline's `step`
   sequence begins).
3. Delete the file's own now-unused local `KEYCLOAK_DISCOVERY`
   (`admin-user-lifecycle.pipeline.e2e.spec.ts`: `KEYCLOAK_DISCOVERY_URL`) constant —
   confirmed its only reader was the deleted block in all 4 files.
4. No other line in any of these 4 files changes as part of this design — the pipeline
   machinery (`createPipeline`, `pl.step`, `pl.onCleanup`, etc., all from `'../pipeline'`)
   is untouched.

## 4. Non-goals / explicit scope boundary (no new design decision introduced)

- The behavioral difference already noted in §1 (5 files silently swallow a network
  failure via `.catch(() => null)`; `helpers.ts`'s functions do not) is an existing,
  intentional-per-ISS-0706-precedent property of the shared helper, not a new decision
  made by this design — ISS-0706 already established that its extracted functions don't
  wrap the fetch in try/catch, matching the majority (non-swallowing) shape among that
  issue's 10 files. This design just applies that same, already-decided helper to a
  second batch of files, some of which change behavior slightly as a result — see Open
  Question 1 below, flagged rather than silently absorbed.
- `pipeline.ts` is not touched, not extended, and does not gain a readiness helper of its
  own — the fix goes through `helpers.ts` exclusively, per §1's import-path finding.
- No change to `web/src/api/health.ts` (already fixed under ISS-0532) or
  `lib/letflow/router.ex` (deliberate non-porting decision stands, per its own
  moduledoc).
- `web/tests/e2e/pipelines/platform-login-routing-by-role.pipeline.e2e.spec.ts` is
  explicitly out of scope, per the task's own framing (its `/health/ready` poll only
  `console.warn`s on failure, non-blocking, already documents ISS-0706 by name as a known
  gap) — no change to that file.
- No unification of the `API_BASE_URL` default-value logic across files (same
  pre-existing, out-of-scope inconsistency ISS-0706 §7.3 already flagged and left
  untouched; still present, unaffected by this design).

## 5. Open questions

1. **Network-failure-swallowing behavior change for 5 files.** `onb-ui-01/02/03/04` and
   `pipelines/onboarding-wizard.pipeline.e2e.spec.ts` currently catch a network-level
   failure (e.g. connection refused) and turn it into their own clean "Backend not ready"
   error message. After this fix, the same network failure instead propagates as
   whatever raw error `request.fetch`/`APIRequestContext` throws natively (since
   `helpers.ts`'s `assertBackendHealthy`/`assertServiceReadiness` don't catch), same as
   already happens today for the other 4 (and ISS-0706's non-catching files). This is the
   same tradeoff ISS-0706 already made for the majority of its own files, applied here to
   a batch where it happens to flip existing behavior for 5 of 9 rather than 0. The
   resulting error is less polished (no custom "Ensure docker-compose services are
   running" hint on a raw connection failure specifically) but still fails the test
   with a diagnosable cause, and remains structurally identical to the already-accepted
   ISS-0706 pattern. Flagging rather than silently deciding: if REVIEWER wants
   `assertBackendHealthy`/`assertServiceReadiness` in `helpers.ts` itself to catch and
   re-wrap network failures (a change to already-shipped ISS-0706 code, not something
   this design's own file changes need), that's a larger change than this design's
   9-file scope and should be raised as its own follow-up rather than folded in here.
2. **`assertServicesReady` → `assertServiceReadiness` rename at call sites (5 files).**
   Purely mechanical (see §3) but worth confirming FRONTEND-DEV treats it as a rename,
   not an oversight — the two names differ only in "Services"/"Service" and the
   trailing "Readiness"/"Ready", easy to typo back to the old local name by habit.

## 6. Acceptance-criteria mapping

| Acceptance criterion (ISS-0707) | Design element |
|---|---|
| All 9 named files stop polling the never-mounted `/health/ready` as a precondition | §3: every file's readiness check now calls `assertServiceReadiness`, which polls `GET /health` |
| Fix reuses ISS-0706's already-proven `helpers.ts` mechanism, no new mechanism invented | §2: no new function added to `helpers.ts`; both functions already exist on `main`, unchanged |
| Duplication eliminated per-file (function-wrapped and inline forms alike) so a further copy-paste can't recur under a 3rd occurrence | §3: each file's local function/inline block deleted in full, replaced by the shared import |
| `platform-login-routing-by-role.pipeline.e2e.spec.ts` correctly excluded | §4: explicit non-change, reasoning restated |
| Import-path variation (`pipeline.ts` vs `helpers.ts`) investigated and resolved | §1: confirmed all 9 already import `BPM_IDP_BASE_URL` from `'../helpers'`; fix extends that same line in all 9, `pipeline.ts` untouched |

## 7. Non-goals (explicit, so REWORK doesn't ask for these)

- No change to `web/tests/e2e/helpers.ts` — both functions already exist, already
  reviewed under ISS-0706, reused verbatim.
- No change to `web/tests/e2e/pipeline.ts`.
- No change to `lib/letflow/router.ex` or `web/src/api/health.ts`.
- No change to `platform-login-routing-by-role.pipeline.e2e.spec.ts`.
- No attempt to make `npm run test:e2e` runnable in CI as part of this fix (same
  out-of-scope note as ISS-0706 — separate concern, `REQ-122`).
- No unification of `API_BASE_URL` default-value logic across files.
- No change to `helpers.ts`'s network-failure (non-catching) behavior — see §5, Open
  Question 1.
