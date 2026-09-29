# Design: ISS-0896 — E2E master-admin Keycloak credentials

- **Issue:** ISS-0896
- **Workflow:** WF-03 (issue fix), run WF03-ISS0896-20260929
- **Author:** CODE-DESIGNER
- **Scope:** `web/tests/e2e/helpers.ts`, `web/tests/e2e/env04.e2e.spec.ts`,
  `web/tests/e2e/pipelines/attachment-cross-tenant.pipeline.e2e.spec.ts`,
  `web/tests/e2e/pipelines/shipment-attach-delivery-note.pipeline.e2e.spec.ts`,
  `web/tests/e2e/pipelines/tenant-cache.pipeline.e2e.spec.ts`
- **Language:** TypeScript (Playwright e2e test code). Signatures/type shapes only —
  no function bodies. This is not `lib/letflow/` Elixir; the design-doc discipline
  (per WF-02 CODE-DESIGNER) is applied to this TS test-code fix by the same rigor,
  per this run's handoff.

## 1. Root cause (from ISSUE-FIXER, step-01)

5 call sites across 4 files POST to Keycloak's **master realm** token endpoint using
a hardcoded literal form body:

```
{ client_id: 'admin-cli', username: 'admin', password: 'admin', grant_type: 'password' }
```

No environment-variable override path exists for these 5 sites, unlike every other
credential in these same 4 files, which already goes through the existing
`resolveCredential(envVarName, localDevFallback)` helper (`web/tests/e2e/helpers.ts:34-39`).

## 2. Decision: new env vars, reusing the existing helper (no new mechanism)

Two new env-var names, resolved via the existing `resolveCredential` helper,
`admin`/`admin` as the local-dev fallback (preserves current behavior when unset):

- `KC_ADMIN_USER` → local-dev fallback `'admin'`
- `KC_ADMIN_PASSWORD` → local-dev fallback `'admin'`

Naming follows the `KC_*` family already implied by the issue text and is distinct
from the existing `UAT_QA_ADMIN_PASSWORD` (tenant-realm) and `BPM_IDP_CLIENT_ID`/
`BPM_IDP_BASE_URL` (URL/client-id) vars already in `helpers.ts`, since this is a
different principal (Keycloak's built-in master-realm bootstrap admin, not a
tenant-realm user). `client_id: 'admin-cli'` itself is Keycloak's fixed built-in
client id for master-realm admin CLI access — it is not tenant- or environment-
specific and is **not** made env-overridable (only `username`/`password` vary
per environment).

No new credential-resolution mechanism is introduced. `resolveCredential` is reused
exactly as already established by the tenant-realm call sites in these same 4 files.

## 3. Decision: consolidate the two duplicated `getMasterAdminToken` helpers

**Consolidate into one shared export in `helpers.ts`.** Reasoning:

- `attachment-cross-tenant.pipeline.e2e.spec.ts`'s `getMasterAdminToken` (lines
  150-159) and `shipment-attach-delivery-note.pipeline.e2e.spec.ts`'s
  `getMasterAdminToken` (lines 110-119) are byte-for-byte identical in body shape
  (same signature, same URL construction, same form body, same error-throw shape)
  and each file's own comment already cites the other as its copy source — this is
  documented copy-paste, not independent design intent that a consolidation could
  break.
- Both take only `request: APIRequestContext` and return `Promise<string>` — no
  file-local state, no call-site-specific parameters. Moving the body to
  `helpers.ts` changes nothing observable at either call site beyond the import.
  This is the "consolidation risks touching unrelated call sites" case the
  handoff flags as the reason to leave things independent — that risk does **not**
  apply here, since the function is already fully self-contained.
- `helpers.ts` already exports the exact building blocks this function needs
  (`BPM_IDP_BASE_URL`, and after this fix, `resolveCredential('KC_ADMIN_USER', ...)`
  / `resolveCredential('KC_ADMIN_PASSWORD', ...)`), so the consolidated helper adds
  no new dependency direction (pipeline specs already depend on `helpers.ts`).

Net effect: one new shared export in `helpers.ts`; both local
`getMasterAdminToken` function declarations are deleted from the two pipeline spec
files and replaced by an import of the shared one.

## 4. Decision: route the 3 inline call sites through the same shared helper

The handoff asks whether `env04.e2e.spec.ts`'s 2 inline sites and
`tenant-cache.pipeline.e2e.spec.ts`'s 1 inline site should also go through the
shared helper (since we are consolidating) or just get their literals swapped
in place.

**Route all 3 through the same shared `getMasterAdminToken` helper**, for
consistency with the decision in §3 — once a shared helper exists specifically for
"get a master-realm admin token," every call site that does exactly that should use
it rather than mixing a shared helper (2 sites) with hand-rolled
`resolveCredential` calls (3 sites) for the identical operation. All 5 call sites
have the identical purpose (obtain a master-realm admin token to perform a
follow-up admin-API call) and the identical request shape — there is no call site
whose surrounding context needs a different credential-resolution path.

This means:
- `env04.e2e.spec.ts:578-581` (inside `onboardTestTenantFixture`) — replace the
  inline `request.post(keycloakMasterUrl, ...)` block with a call to the imported
  `getMasterAdminToken(request)`. The now-unused local `keycloakMasterUrl`
  variable (line 471) is removed if nothing else in the function references it
  after this change (confirmed: only this call site used it).
- `env04.e2e.spec.ts:642-647` (inside `cleanupOnboardedTestTenantFixture`) —
  replace the inline `request.post(...)` block with a call to the imported
  `getMasterAdminToken(request)`.
- `tenant-cache.pipeline.e2e.spec.ts:197-203` (inside the `pl.onCleanup` callback)
  — replace the inline `request.post(...)` block with a call to the imported
  `getMasterAdminToken(request)`.

## 5. `helpers.ts` changes

### 5.1 New/changed exports

```ts
// New env-var-backed constants are NOT pre-computed at module load (mirrors the
// existing resolveCredential call-site pattern used for UAT_QA_ADMIN_PASSWORD —
// resolved fresh at call time inside the function body, not hoisted to a module
// constant). No new top-level export needed for the username/password
// themselves; they are read inside the new function below.

/**
 * Obtain a JWT access token from Keycloak's MASTER realm via the built-in
 * admin-cli client (password grant). Distinct from `getKeycloakToken`, which
 * authenticates against the `bpm-default`/tenant realm as an application user.
 *
 * Username/password resolve via `resolveCredential`:
 *   - `KC_ADMIN_USER`     (fallback: 'admin')
 *   - `KC_ADMIN_PASSWORD` (fallback: 'admin')
 *
 * Throws (does not return a boolean/undefined) when the token request does not
 * return 2xx, matching the two call sites' existing throw-on-failure shape.
 */
export async function getMasterAdminToken(
  request: APIRequestContext,
): Promise<string>
```

Placement: alongside `getKeycloakToken` (after it, before `decodeJwtPayload`),
since both are "obtain a Keycloak token" helpers and the moduledoc-equivalent
top-of-file comment already documents the token-injection login technique this
sits next to.

### 5.2 Behavior shape (not implementation)

- Builds the master-realm token URL from the already-exported `BPM_IDP_BASE_URL`
  (same `${BPM_IDP_BASE_URL}/realms/master/protocol/openid-connect/token` shape
  every one of the 5 existing call sites already uses — no URL change).
- Form body: `client_id: 'admin-cli'` (fixed, see §2), `username:
  resolveCredential('KC_ADMIN_USER', 'admin')`, `password:
  resolveCredential('KC_ADMIN_PASSWORD', 'admin')`, `grant_type: 'password'`.
- On non-2xx response: throws an `Error` (matching the two existing
  `getMasterAdminToken` copies' throw shape — includes status and response body
  in the message). This is a **behavior-preserving tightening** for the 3 sites
  that previously only `console.warn`ed and returned `undefined`/best-effort
  (env04's two sites, tenant-cache's site) — see §6 open question below; it is
  flagged, not silently decided.

## 6. Call-site-by-call-site fix table (all 5, explicit)

| # | File:line (pre-fix) | Current shape | Fix |
|---|---|---|---|
| 1 | `env04.e2e.spec.ts:578-580` | inline `request.post(keycloakMasterUrl, ...)` with literal body | replace with `await getMasterAdminToken(request)`; remove now-dead `keycloakMasterUrl` local (line 471) and the surrounding `if (!masterTokenResp.ok())` / `console.warn` / `return undefined` guard, since the shared helper throws instead of returning a failure sentinel — see open question in §7 |
| 2 | `env04.e2e.spec.ts:642-647` | inline `request.post(...)` with literal body, wrapped in a `try { } catch { /* best-effort */ }` at the call-site level | replace with `await getMasterAdminToken(request)`; the outer `try/catch` in `cleanupOnboardedTestTenantFixture` already swallows a thrown error, so this site's best-effort semantics are preserved even though the helper now throws instead of the local `if (masterTokenResp.ok())` check silently no-op'ing |
| 3 | `attachment-cross-tenant.pipeline.e2e.spec.ts:150-159` | local `async function getMasterAdminToken(request)` definition, literal body | **delete** this local function entirely; add `getMasterAdminToken` to the existing `import { assertServiceReadiness, resolveCredential, BPM_IDP_BASE_URL } from '../helpers'` (line 114) — `resolveCredential` may then become an unused import at this file's other call sites only if it has no other use; confirmed it is still used at line 468, so it stays imported |
| 4 | `shipment-attach-delivery-note.pipeline.e2e.spec.ts:110-119` | local `async function getMasterAdminToken(request)` definition, literal body | **delete** this local function entirely; add `getMasterAdminToken` to the existing `import { assertServiceReadiness, resolveCredential, BPM_IDP_BASE_URL } from '../helpers'` (line 60); `resolveCredential` stays imported (still used at line 322) |
| 5 | `tenant-cache.pipeline.e2e.spec.ts:197-203` | inline `request.post(...)` with literal body inside `pl.onCleanup`, wrapped in `try { } catch { /* best-effort cleanup only */ }` | replace with `await getMasterAdminToken(request)`; add `getMasterAdminToken` to the existing `import { assertServiceReadiness, resolveCredential, BPM_IDP_BASE_URL } from '../helpers'` (line 127); the enclosing `try/catch` already present at this call site preserves best-effort semantics |

## 7. Open question (flagged, not silently resolved)

Sites #1 (`env04.e2e.spec.ts:578-586`) and its `if (!masterTokenResp.ok()) { ...
return undefined }` guard currently degrade gracefully (the whole fixture setup
returns `undefined` and the test that depends on it is expected to handle a
missing fixture). The shared helper throws on failure instead of returning a
sentinel. Site #1 is **not** wrapped in a `try/catch` at its call site today (only
sites #2 and #5 are). Consolidating site #1 onto the throwing helper therefore
changes its failure mode from "fixture setup returns `undefined`, caller handles
it" to "the test itself throws/fails."

This design does not silently resolve this: ELIXIR-DEV/FRONTEND-DEV implementing
this fix must either (a) wrap the `getMasterAdminToken(request)` call at site #1
in the same local `try { } catch { return undefined }` shape the surrounding
function already uses for its other failure branches (preferred — preserves
existing fixture-degrades-gracefully behavior with minimal diff), or (b) leave it
throwing and confirm (by reading the call site that consumes
`onboardTestTenantFixture`'s return value) that an uncaught throw here is
acceptable test-failure behavior. Recommendation: (a), for consistency with every
other failure branch already in `onboardTestTenantFixture`, but this is
explicitly left as a decision for the implementing agent to confirm against the
full function body (not shown here per the no-implementation-code rule of this
design doc), not a guess to bake into the design silently.

## 8. Summary of file-level diffs (shape only)

- `web/tests/e2e/helpers.ts`: **add** `export async function
  getMasterAdminToken(request: APIRequestContext): Promise<string>`. No changes
  to any existing export's signature.
- `web/tests/e2e/env04.e2e.spec.ts`: **add** `getMasterAdminToken` to the
  existing import from `./helpers` (line 33); **replace** call sites #1 and #2
  per §6; **remove** the now-unused `keycloakMasterUrl` local (line 471), guarded
  by the open question in §7 for site #1's error handling.
- `web/tests/e2e/pipelines/attachment-cross-tenant.pipeline.e2e.spec.ts`:
  **delete** local `getMasterAdminToken` (lines 150-159); **add**
  `getMasterAdminToken` to the existing import from `../helpers` (line 114).
- `web/tests/e2e/pipelines/shipment-attach-delivery-note.pipeline.e2e.spec.ts`:
  **delete** local `getMasterAdminToken` (lines 110-119); **add**
  `getMasterAdminToken` to the existing import from `../helpers` (line 60).
- `web/tests/e2e/pipelines/tenant-cache.pipeline.e2e.spec.ts`: **replace** call
  site #5 per §6; **add** `getMasterAdminToken` to the existing import from
  `../helpers` (line 127).

No changes to any file's exported test names, fixtures' public shape, or any
non-master-realm credential path (tenant-realm `resolveCredential`/
`getKeycloakToken` usage is untouched).

## 9. Acceptance-criteria mapping

- "every one of the 5 call sites has an explicit, named fix" → §6 table, rows 1-5.
- "states and justifies whether the two duplicated `getMasterAdminToken`-shaped
  helpers are consolidated or independently fixed" → §3.
- "no new credential-resolution mechanism invented" → §2 (reuses
  `resolveCredential` verbatim).
- "no implementation code" → §5.1/§5.2 give the new export's signature and a
  prose behavior description only; no function body is written anywhere in this
  document.
