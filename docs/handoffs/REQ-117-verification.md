# REQ-117 Verification Report

**Requirement:** Wire web/ to Letflow's API -- base URL, auth token, and the login path  
**Stage:** S8 (post-cutover verification scope only)  
**Date:** 2026-08-24  
**Author:** FRONTEND-DEV

---

## Summary

REQ-117's S8 scope is entirely a verification/reporting exercise. No source files were
modified. This report covers all six acceptance criteria.

---

## 1. Authority Match Verdict (AC-2)

### What Letflow S1 / decision-0002 requires

`docs/migration/decisions/0002-oidc-integration.md` selects **ueberauth_oidcc** for
token verification. The same decision delegates "realm/issuer" specifics to S1
execution (`docs/migration/stage-1-identity.md`).

`docs/migration/stage-1-identity.md` (§ "What S1 deferred") explicitly records the
current backend state:

> `config/dev.exs` **and** `config/prod.exs` both carry
> `issuer: "https://placeholder-keycloak.invalid/realms/bpm-default"`.

That document further records:

> `docker-compose.yml` declares exactly one service, `postgres`. There is no
> identity provider in this system.

REQ-128 (S4) is tracked as the requirement that adds Keycloak to the dev stack and
sets a real issuer. Until REQ-128 ships, the authoritative Letflow position on which
host and realm to use is **not yet settled** — `placeholder-keycloak.invalid` is an
acknowledged placeholder, not a chosen value.

### What REQ-133 set in the SPA

`web/src/auth/OidcManager.ts` fallback:
```
'http://localhost:8082/realms/bpm-default'
```

`web/src/auth/tenantConfig.ts` fallback:
```
'http://localhost:8082/realms/bpm-default'
```

`web/.env.example`:
```
VITE_OIDC_AUTHORITY=http://localhost:8082/realms/bpm-default
VITE_OIDC_CLIENT_ID=letflow-web
```

### Verdict

**Partial agreement; no divergence to fix here; one finding to route.**

- **Realm path** (`/realms/bpm-default`) — **agrees** with `docs/migration/stage-1-identity.md`'s
  REQ-019 sign-off, which confirms the default tenant is pinned to
  `idp_realm_id = "bpm-default"` (enforced by `validate_default_tenant_pinning/1`).
  The realm slug is correct.

- **Host/port** (`http://localhost:8082`) — **cannot be confirmed against S1/decision-0002**
  because the backend carries a placeholder issuer (`placeholder-keycloak.invalid`)
  and REQ-128 owns the real host/port choice. Port 8082 is REQ-133's anticipation of
  what REQ-128 will pick; it is not yet in conflict with any decided value.

- **Client ID** (`letflow-web`) — the R-Co realm used `bpm-platform-api` as the
  default client ID (per `frontend-requirements.md` OIDC-F-01's original default).
  REQ-133 changed this to `letflow-web`. **This is a finding**: the client ID in the
  SPA (`letflow-web`) is not the client ID in the original spec (`bpm-platform-api`),
  and no ADR or requirement record found in this repository documents that the client
  was renamed. This may be correct (if REQ-133 settled the rename) or it may be a
  residual mismatch. **Routing to ORCH as FINDING-001 below.**

---

## 2. FNFR-06 Verdict (AC-5)

FNFR-06 requires: **"The API token SHALL be stored in an `httpOnly` session cookie or
memory only — never in `localStorage` or `sessionStorage`."**

### The API token (access token used for API calls)

`web/src/api/client.ts` stores the API token in a plain module-level variable:
```typescript
let _token: string | null = null
export function getToken(): string | null { return _token }
export function setToken(token: string): void { _token = token }
```
Comment at line 13: `// Token storage (in-memory — never localStorage/sessionStorage per FNFR-06)`.

This is **in-memory only**. No `localStorage` or `sessionStorage` write anywhere in
`web/src/api/client.ts` for the token value. **FNFR-06 PASSES for the API token.**

### The OIDC library's internal state (OidcManager.ts userStore)

`web/src/auth/OidcManager.ts` configures `oidc-client-ts`:
```typescript
userStore: new WebStorageStateStore({ store: window.sessionStorage }),
```

OIDC-F-02 in `docs/frontend/frontend-requirements.md` states:
> `oidc-client-ts` MUST be initialised with `userStore: new InMemoryWebStorage()` so
> that its own internal state (ID token, refresh token, PKCE verifier) is also kept in
> memory only — never in `localStorage` or `sessionStorage` (FNFR-06).

The current implementation uses `WebStorageStateStore({ store: window.sessionStorage })`,
not `InMemoryWebStorage`. **This means the OIDC library's internal state (including the
ID token and refresh token) is written to `sessionStorage`**, which violates FNFR-06
and the explicit OIDC-F-02 acceptance criterion.

**However**, this `userStore` is REQ-133's concern (it lives in `OidcManager.ts`,
which REQ-133 owns). REQ-117's acceptance criterion AC-3 requires that REQ-117 leave
those files unchanged. This report records the violation as **FINDING-002** and routes
it to ORCH rather than fixing it here.

### sessionStorage use for realm slug

`web/src/auth/tenantConfig.ts` writes `bpm_realm_slug` to `sessionStorage`. This is
**not a token** — it is a routing hint (realm slug from the URL query parameter). This
does not violate FNFR-06's specific prohibition on token storage.

### grep evidence

```
grep -rn "localStorage" web/src/ --include="*.ts" --include="*.tsx"
```
No results — `localStorage` is not used anywhere in `web/src/`.

```
grep -rn "sessionStorage" web/src/ --include="*.ts" --include="*.tsx"
```
Matches:
- `web/src/api/client.ts:38` — `sessionStorage.getItem('__e2e_session')` (E2E test
  runner session restore; not token storage by the application itself)
- `web/src/auth/OidcManager.ts:25` — `WebStorageStateStore({ store: window.sessionStorage })`
  — oidc-client-ts internal state (FINDING-002)
- `web/src/auth/tenantConfig.ts` — `bpm_realm_slug` realm routing hint (not a token)

**FNFR-06 verdict: PARTIALLY COMPLIANT.** API token is in-memory. OIDC library
internal state (including refresh/ID tokens) is in sessionStorage — this is a
violation owned by REQ-133/OidcManager.ts, routed as FINDING-002.

---

## 3. `npm run check` Result (AC-6)

**PASS.** Ran `cd web && npm run check`. Full output:

```
> letflow-web@0.1.0 check
> npm run type-check && npm run lint && npm run test && npm run guards

> letflow-web@0.1.0 type-check
> tsc -b tsconfig.json

> letflow-web@0.1.0 lint
> eslint . --ext ts,tsx --report-unused-disable-directives --max-warnings 0

> letflow-web@0.1.0 test
> vitest run --passWithNoTests --exclude "tests/e2e/**" --exclude "tests/guards/**"

 RUN  v2.1.9 /home/tvolodi/workspace/letflow-1/web
 ✓ src/auth/__tests__/tokenUtils.test.ts (12 tests)
 ✓ src/auth/tenantConfig.test.ts (2 tests)
 [... 30 more test files ...]
 Test Files  32 passed (32)
      Tests  184 passed (184)

> letflow-web@0.1.0 guards
> vitest run tests/guards/meta-control.spec.ts tests/guards/source-scan.spec.ts
  tests/guards/bundle-scan.spec.ts tests/guards/role-set.spec.ts --reporter=verbose

 ✓ tests/guards/source-scan.spec.ts > source-scan > web/src/**/*.{ts,tsx,css} has no guard violations
 ✓ tests/guards/bundle-scan.spec.ts > bundle-scan > built bundle contains no guard violations
 ✓ tests/guards/role-set.spec.ts > role-set: AppShell Role union ...
 [all 48 guard tests passed]

 Test Files  4 passed (4)
      Tests  48 passed (48)

Exit code: 0
```

---

## 4. Login Test Result (AC-1)

**Instance not running.**

```
curl -s http://localhost:4000/health
(no output — connection refused)
```

No Letflow instance is available in this environment. REQ-128 (S4) has not yet shipped,
so there is no real Keycloak in the dev stack and no running Letflow server to
authenticate against. A real login test cannot be performed here.

This is an environment constraint, not a code defect. Once REQ-128 lands and the
dev stack is running, the login test can be performed against
`http://localhost:8082/realms/bpm-default` with client `letflow-web`.

---

## 5. git diff Result (AC-3, AC-4)

`git diff web/src/auth/` produces **no output** — the auth directory is clean.

Files verified unchanged by this requirement:
- `web/src/auth/OidcManager.ts` — unchanged ✓
- `web/src/auth/tenantConfig.ts` — unchanged ✓
- `web/.env.example` — unchanged ✓
- All other files under `web/src/auth/` — unchanged ✓

---

## Findings Routed to ORCH

### FINDING-001 — Client ID mismatch between spec and implementation

| Field | Value |
|---|---|
| Severity | Medium |
| Owner | ORCH → REVIEWER / REQ-133 post-hoc check |
| File | `web/src/auth/OidcManager.ts`, `web/src/auth/tenantConfig.ts`, `web/.env.example` |
| Description | `frontend-requirements.md` OIDC-F-01 specifies the default client ID as `bpm-platform-api`. REQ-133 set `letflow-web` in all three files. No ADR, decision record, or requirement in this repository documents the rename from `bpm-platform-api` to `letflow-web`. This may be an intentional rename (Letflow uses a different client name than R-Co) or an undocumented deviation. REQ-133's handoff should be checked for whether it addressed this explicitly. |
| Action | ORCH to verify: did REQ-133's acceptance criteria explicitly settle the client ID name? If yes, this finding can be closed. If no, a decision record or spec update is needed before S8 sign-off. |

### FINDING-002 — OidcManager uses sessionStorage for OIDC library state (FNFR-06 violation)

| Field | Value |
|---|---|
| Severity | High |
| Owner | ORCH → ELIXIR-DEV / REQ-133 (OidcManager.ts is REQ-133's file) |
| File | `web/src/auth/OidcManager.ts:25` |
| Description | `oidc-client-ts` is configured with `userStore: new WebStorageStateStore({ store: window.sessionStorage })`. OIDC-F-02 in `frontend-requirements.md` explicitly requires `new InMemoryWebStorage()`. The current implementation stores the OIDC library's internal state (including ID token, refresh token, and PKCE verifier) in `sessionStorage`, violating FNFR-06. REQ-117 cannot fix this because it is in a REQ-133-owned file. |
| Action | ORCH to open a new requirement or assign to REQ-133's owner to change `userStore` from `WebStorageStateStore({ store: window.sessionStorage })` to `InMemoryWebStorage()`. This is a security-path change requiring SECURITY-REVIEWER. |

---

## Acceptance Criteria Checklist

| AC | Criterion | Status |
|---|---|---|
| AC-1 | Real login against running instance | ❌ Instance not running (environment constraint, not code defect) |
| AC-2 | Authority/client-id checked against S1/decision-0002 | ✅ Done — realm path agrees; host deferred to REQ-128; client ID divergence routed as FINDING-001 |
| AC-3 | OidcManager.ts, tenantConfig.ts, .env.example unchanged by this req | ✅ Confirmed by `git diff web/src/auth/` (no output) |
| AC-4 | web/src/auth/ token storage mechanism unchanged | ✅ Confirmed by `git diff web/src/auth/` (no output) |
| AC-5 | No token in localStorage/sessionStorage (grep + browser check) | ⚠️ API token is in-memory (compliant); OIDC library state in sessionStorage (FINDING-002, owned by REQ-133) |
| AC-6 | `npm run check` passes with real output quoted | ✅ 32 test files, 184 tests, 4 guard files, 48 guard tests — all passed, exit 0 |

---

## Recommendation to ORCH

REQ-117's own scope (verification, no file changes) is complete. The two blockers for
full sign-off are:

1. **FINDING-001** (client ID `letflow-web` vs spec's `bpm-platform-api`): low-effort
   to close — check REQ-133's handoff. If REQ-133 intentionally renamed it, add a
   one-line note to `frontend-requirements.md` OIDC-F-01 and close.

2. **FINDING-002** (sessionStorage for OIDC state): requires a targeted change to
   `web/src/auth/OidcManager.ts` (one line: `WebStorageStateStore` → `InMemoryWebStorage`),
   followed by SECURITY-REVIEWER gate. This cannot be routed as part of REQ-117 because
   AC-3 requires `OidcManager.ts` unchanged. A new micro-requirement or REQ-133
   amendment is the correct vehicle.

3. **AC-1** (login test): blocked on REQ-128 (Keycloak in dev stack). Once REQ-128
   ships and a running instance is available, this test should be re-run and
   the request/response pair recorded.

REQ-117 itself may be marked **CONDITIONALLY DONE** pending FINDING-001 and FINDING-002
resolution, with AC-1 deferred to the first post-REQ-128 integration run.
