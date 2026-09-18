# ISS-0712 — Design: real-OIDC-redirect login helper for the PLATFORM_ADMIN e2e case

**Files to change:** `web/tests/e2e/helpers.ts` (new export + credential-resolution
change), `web/tests/e2e/pipelines/platform-login-routing-by-role.pipeline.e2e.spec.ts`
(PLATFORM_ADMIN case only)
**Route to:** FRONTEND-DEV (test-suite TypeScript, no `lib/letflow/` or migration
change)
**Related:** REQ-369 (introduced the role-conditional redirect this fix lets the suite
actually exercise), ISS-0711 (`related`), `docs/issues/ISS-0712.yaml`

This is not an Elixir-module design — like `iss-0702`/`iss-0706`/`iss-0709`'s test-
suite fixes, ISS-0712 produces changes to `web/tests/e2e/` only. "Module
interfaces/@specs" below map to: the new helper's exact TypeScript function signature,
the credential-resolution function's signature, and the one spec-file test body's
call-site shape.

Diagnosis is pre-confirmed by ISSUE-FIXER (see `docs/issues/ISS-0712.yaml` and the
task handoff) — this design does not re-derive root cause, only the fix shape.

---

## 1. New helper: `loginViaRealOidcRedirect`

### 1.1 Location

`web/tests/e2e/helpers.ts`, as a new named export alongside `loginWithToken` (not a
replacement — `loginWithToken` keeps serving the other two cases in
`platform-login-routing-by-role.pipeline.e2e.spec.ts`, unchanged, and every other spec
file that imports it).

### 1.2 Signature

```
export async function loginViaRealOidcRedirect(
  page: Page,
  username: string,
  password: string,
  expectedUrl: string,
): Promise<void>
```

- `page`: the Playwright `Page`, same as `loginWithToken`'s first parameter — no new
  fixture wiring needed.
- `username`, `password`: plain strings, passed by the caller already resolved (this
  helper does not itself read `process.env` — that resolution is §2's separate
  concern, kept out of this helper so it stays a pure "drive the redirect" function
  with no credential-sourcing responsibility of its own).
- `expectedUrl`: the exact post-callback path the caller expects to land on (e.g.
  `'/platform-dashboard'`), passed in rather than hardcoded, so this helper stays
  reusable for a future non-PLATFORM_ADMIN real-redirect case without editing the
  helper itself. **Not optional** — a real-redirect login always has *some* specific
  destination in mind for its case; forcing the caller to state it here keeps the
  wait bounded and the failure message specific (see §1.3 step 5).
- Returns `Promise<void>`, same convention as `loginWithToken`. Throws (does not
  return `false`/swallow) on any step failing — matching `getKeycloakToken`'s and
  `assertBackendHealthy`'s existing throw-not-swallow convention in this same file.

### 1.3 Behavior (ordered steps; shape only, no implementation code)

1. Navigate `page` to the app's root (`'/'`) with **no** prior `addInitScript`
   session injection and no pre-existing token/cookie — this is the entire point of
   the fix: nothing about the session exists yet when the app's own auth guard first
   runs.
2. Wait for the app's own `ProtectedRoute`/`AuthProvider` guard to redirect the
   browser off-origin to Keycloak's hosted login page. Detection mechanism: wait for
   `page.url()`'s origin to differ from the app's own origin (same technique already
   proven live in this same spec file's unauthenticated-redirect case — see
   `platform-login-routing-by-role.pipeline.e2e.spec.ts` lines 213-215,
   `page.waitForURL((url) => url.origin !== appOrigin, ...)`), bounded by an explicit
   timeout (reuse that case's `20_000`ms).
3. On Keycloak's hosted login page, fill `#username` with the `username` parameter
   and `#password` with the `password` parameter (Keycloak's own default login-form
   field ids — these are Keycloak's markup, not app markup, so no `data-testid`
   lookup is available or appropriate here), then submit the form (Keycloak's login
   button, typically `#kc-login` — ELIXIR-DEV/FRONTEND-DEV should confirm the exact
   submit-control selector against the resolved Keycloak version actually running in
   this repo's dev/CI stack before finalizing, same "verify against the real
   resolved dependency" discipline `iss-0709`'s design used for earmark_parser; this
   design does not assume a specific Keycloak version's markup without that check).
4. Wait for the browser to navigate back through the app's own `/auth/callback`
   route (`page.waitForURL` matching a path prefix of `/auth/callback`, OR simply
   proceed to step 5's wait on `expectedUrl` directly — either is acceptable, but if
   an intermediate `/auth/callback` wait is included it must not assert on that
   URL's content, since `OidcCallbackPage.tsx` renders only a transient "Completing
   sign-in..." status (`data-testid="oidc-callback-status"`) before its `navigate()`
   fires).
5. Wait for `page` to reach `expectedUrl` (`await page.waitForURL(expectedUrl, ...)` /
   equivalent to the existing `expect(page).toHaveURL(...)` pattern the spec already
   uses after `loginWithToken`) — this is what proves `OidcCallbackPage.tsx`'s line-72
   role-conditional `navigate()` actually ran and chose the expected destination, for
   real. Use a bounded timeout (15_000ms, matching `loginWithToken`'s existing
   `waitForSelector` timeout convention in this file).
6. No return value beyond resolving; the caller's own `expect(page).toHaveURL(...)`
   and testid assertions (already present in the spec, unchanged) remain the actual
   proof — this helper's own step-5 wait exists only to make sure the navigation has
   settled before the caller's assertions run, not to duplicate them.

### 1.4 What this helper must NOT do (explicit non-goals, to keep ELIXIR-DEV/
FRONTEND-DEV from over-building)

- Must not call `getKeycloakToken`, decode a JWT, or touch `sessionStorage`/
  `addInitScript` at all — those are exactly the session-injection mechanics this fix
  replaces for this one case.
- Must not itself branch on role or hardcode `/platform-dashboard` — that stays the
  caller's concern via `expectedUrl` (§1.2).
- Must not read `process.env` for credentials — the caller resolves credentials
  (§2) and passes plain strings in.

---

## 2. Env-var credential resolution

### 2.1 New helper: `resolveCredential`

Location: `web/tests/e2e/helpers.ts`, private (not exported) unless TEST-DESIGNER/
FRONTEND-DEV finds a second call site that needs it directly — the two current call
sites (`getKeycloakToken`'s own default-argument resolution, and the new
`loginViaRealOidcRedirect` caller in the spec file) can both go through it without an
export if `getKeycloakToken` calls it internally (see §2.2).

Signature:

```
function resolveCredential(envVarName: string, localDevFallback: string): string
```

- `envVarName`: the exact `process.env` key to check, e.g. `'UAT_QA_ADMIN_PASSWORD'`.
- `localDevFallback`: the existing literal default, e.g. `'admin-pass'`.
- Returns: `process.env[envVarName]` when that env var is **set and non-empty**
  (trim + non-empty check, mirroring `normalizeIdpBaseUrl`'s existing
  `value.length == 0` guard style in this same file); otherwise returns
  `localDevFallback` unchanged. No throw — an unset env var is the expected local-dev
  case, not an error.

### 2.2 Call-site changes

- `getKeycloakToken`'s existing `password = 'admin-pass'` default-parameter value is
  replaced by a call to `resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass')`
  evaluated at call time (default-parameter expressions in TypeScript/JS are
  evaluated per-call, so this is a direct drop-in — no signature change, no new
  parameter). Same treatment for the worker path: wherever `'worker-pass'` is passed
  (currently the *caller's* explicit second argument in the spec file's
  tenant-scoped case, not a `getKeycloakToken` default) should likewise resolve
  through `resolveCredential('UAT_QA_WORKER_PASSWORD', 'worker-pass')` at that call
  site — see §2.3 for exactly which line.
- `loginViaRealOidcRedirect`'s caller (the PLATFORM_ADMIN spec case, §3) resolves the
  admin password the same way before passing it in: it does not read `process.env`
  itself, matching §1.4's non-goal.
- `getKeycloakToken`'s `username` parameter is **not** part of this env-var path —
  ISS-0712's fix_direction only names the two password env vars
  (`UAT_QA_ADMIN_PASSWORD`/`UAT_QA_WORKER_PASSWORD`); usernames (`'admin-user'`/
  `'worker-user'`) stay literal. Flagged here explicitly so FRONTEND-DEV doesn't
  over-scope this into a full credential-object redesign.

### 2.3 Exact resolution shape at each of the three password sites

**Decision:** `resolveCredential` is exported from `helpers.ts` (drop the "private"
framing in §2.1 — make it `export function resolveCredential(...)`), so every call
site resolves its own env var explicitly and identically. `getKeycloakToken`'s own
signature is unchanged in shape (still 3 params, same defaults semantics) — only its
`password` default's *value expression* changes. `getKeycloakToken` gains no `role`
discriminant; each caller states which env var it needs.

| Site | Current | New |
|---|---|---|
| `getKeycloakToken`'s own `password` default parameter | `password = 'admin-pass'` | `password = resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass')` |
| Spec file's tenant-scoped case (worker login) | `getKeycloakToken(request, 'worker-user', 'worker-pass')` | `getKeycloakToken(request, 'worker-user', resolveCredential('UAT_QA_WORKER_PASSWORD', 'worker-pass'))` — passed explicitly as the 3rd argument; `getKeycloakToken`'s own default only ever resolves the *admin* var, so this call site cannot rely on omitting the argument |
| New `loginViaRealOidcRedirect` caller in PLATFORM_ADMIN spec case | n/a (new) | caller passes `resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass')` explicitly as the `password` argument (§3) |

---

## 3. Spec file change: PLATFORM_ADMIN case only

`platform-login-routing-by-role.pipeline.e2e.spec.ts`'s test at line 70
(`'EO-001: PLATFORM_ADMIN lands on the distinct platform dashboard'`):

- **Replace** lines 71-72 —
  ```
  const token = await getKeycloakToken(request, 'admin-user', 'admin-pass')
  await loginWithToken(page, token)
  ```
  — with a call shaped as:
  ```
  await loginViaRealOidcRedirect(
    page,
    'admin-user',
    resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass'),
    '/platform-dashboard',
  )
  ```
  (exact literal shape; ELIXIR-DEV/FRONTEND-DEV writes the real code, this is the
  call-site design, not implementation).
- The `request` fixture parameter on this specific `test(...)` callback becomes
  unused for this case once `getKeycloakToken` is no longer called here — Playwright
  fixture destructuring for this one test should drop `request` from
  `async ({ page, request }) => {` to `async ({ page }) => {` (or keep it if a lint
  rule elsewhere in this repo requires listing all fixtures; FRONTEND-DEV's call,
  flagged so it isn't missed as dead code).
- Everything from line 74 onward (the `expect(page).toHaveURL('/platform-dashboard')`
  through the `shot(page, 'admin')` call) is **unchanged** — those assertions are
  exactly what now runs against a page that arrived via the real callback path
  instead of an injected session, which is the entire fix.
- **Import change:** line 38's
  `import { getKeycloakToken, loginWithToken, BPM_IDP_BASE_URL } from '../helpers'`
  gains `loginViaRealOidcRedirect` and `resolveCredential`; `getKeycloakToken` stays
  imported (still used by the tenant-scoped case) and `loginWithToken` stays imported
  (still used by the tenant-scoped case).
- The other two `test(...)` cases in this file (tenant-scoped root-landing at line
  99, unauthenticated-redirect at line 177) are **unchanged** in their login
  mechanism per the task's explicit scope — only the tenant-scoped case's password
  argument changes per §2.3's table (env-var resolution), never its use of
  `getKeycloakToken`/`loginWithToken`.

---

## 4. Open questions (explicitly flagged, not silently resolved)

1. **Keycloak submit-control selector (§1.3 step 3).** This design names `#kc-login`
   as Keycloak's typical default login-button id but does not confirm it against the
   actual Keycloak version/theme this repo's dev/CI stack runs (see
   `docs/migration/decisions/` for whichever decision record pins the Keycloak
   version, and `web/tests/e2e/helpers.ts`'s own `BPM_IDP_BASE_URL` config for where
   it's reached). FRONTEND-DEV must confirm the real selector by inspecting the
   actual rendered login page (or reusing the "throwaway, uncommitted spec that drove
   the real hosted login form" ISSUE-FIXER already ran live per ISS-0712's
   description) before finalizing.
2. **`/auth/callback` intermediate-wait inclusion (§1.3 step 4).** Left as either/or
   — an explicit wait on `/auth/callback` before the final `expectedUrl` wait adds a
   diagnostic checkpoint (a hang here vs. a hang after would point at different root
   causes) but is not required for correctness since step 5's wait alone already
   proves the redirect completed. FRONTEND-DEV's choice; not a correctness-affecting
   decision.
3. **CI credential provisioning for `UAT_QA_ADMIN_PASSWORD`/`UAT_QA_WORKER_PASSWORD`.**
   This design only specifies how `helpers.ts` *reads* these env vars, not how CI/CD
   secrets provisioning supplies them for a non-local run — that is CD/infra scope
   (see `docs/issues/ISS-0690`-adjacent CD-secrets work already in this run's recent
   commit history) and explicitly out of scope for this design.
4. **`getKeycloakToken`'s unused `token` variable in the PLATFORM_ADMIN case after
   this change.** Confirmed not an issue: `getKeycloakToken` is simply no longer
   called in that test body at all (§3), so there is no orphaned `token` variable —
   noted here only to make explicit that this was checked, not overlooked.

---

## 5. Acceptance-criteria mapping

| Requirement (from ISS-0712's `fix_direction`, confirmed diagnosis) | Design element |
|---|---|
| PLATFORM_ADMIN case gets its own real-redirect-based login, not shared `loginWithToken` | §1 new `loginViaRealOidcRedirect` export; §3 spec call-site replacement |
| Navigate with no session, let the app's own guard redirect off-origin to Keycloak | §1.3 steps 1-2 |
| Fill Keycloak's own `#username`/`#password`, submit | §1.3 step 3 |
| Wait for the return through `/auth/callback` so `OidcCallbackPage.tsx`'s useEffect actually executes | §1.3 steps 4-5 |
| Other two cases (tenant-scoped, unauthenticated) keep existing login mechanism unchanged | §3 last bullet — explicit scope boundary |
| `helpers.ts` env-var credential path (`UAT_QA_ADMIN_PASSWORD`/`UAT_QA_WORKER_PASSWORD`), falling back to local-dev literals | §2 `resolveCredential`; §2.3 table + resolution |
| Unambiguous enough that ELIXIR-DEV/FRONTEND-DEV needs no further judgment calls | §2.3's explicit final-shape resolution (ambiguity worked through in-document, not left to the builder); §4 open questions list what genuinely remains open vs. what's decided |
