# ISS-0295 — `web/tests/e2e/*.ts` hardcoded stale Keycloak port 8081 / client_id `bpm-platform-api`

Status: design for CODE-DESIGN-VALIDATOR review. No implementation code below —
signatures, import statements as literal text (not implementation logic), and
assertion rewrites specified narratively. FRONTEND-DEV implements from this.

## 0. Scope

**In scope:** `web/tests/e2e/**/*.ts` only — test helper constants, spec-file local
declarations, and stale assertions/comments referencing the old Keycloak port
(`8081`) or the old client id (`bpm-platform-api`).

**Out of scope (REQ-133's job, separately still pending):**
- `web/src/auth/OidcManager.ts`
- `web/src/auth/tenantConfig.ts` (or wherever `tenantConfig`/OIDC config resolution
  lives in `web/src`)
- `.env.example`
- Any backend/`priv/keycloak/` config — the realm already correctly declares
  `letflow-web` (`priv/keycloak/realms/bpm-default.json:21`), and
  `docker-compose.yml:46` already correctly maps `${LETFLOW_KEYCLOAK_PORT:-8082}`.
  Nothing there needs to change; this issue only fixes the **test suite's own**
  stale hardcoded values.

This design does not touch any file under `web/src/`.

## 1. Ground truth (verified against live source, not inherited from ISSUE-FIXER)

- `priv/keycloak/realms/bpm-default.json:21` — `"clientId": "letflow-web"`.
- `docker-compose.yml:46` — `- "${LETFLOW_KEYCLOAK_PORT:-8082}:8080"`, with the
  comment block at lines 35-42 explaining why 8082 (not 8081, which is R-Co's own
  stack's port) is Letflow's default.
- Confirmed via `grep -rln "8081\|bpm-platform-api" web/tests/e2e/` (33 files) and
  read individually: the file set matches ISSUE-FIXER's enumeration exactly, with
  one structural correction — `pipelines/admin-user-lifecycle/onboarding-wizard/
  sim-admin-processes/sim-company-onboarding.pipeline.e2e.spec.ts` in the original
  diagnosis text is four flat files in `web/tests/e2e/pipelines/` (dotted
  filenames, not nested directories):
  `admin-user-lifecycle.pipeline.e2e.spec.ts`,
  `onboarding-wizard.pipeline.e2e.spec.ts`,
  `sim-admin-processes.pipeline.e2e.spec.ts`,
  `sim-company-onboarding.pipeline.e2e.spec.ts` — all sit exactly one directory
  below `web/tests/e2e/`, same depth as `onboarding/` and `admin/`.

## 2. `web/tests/e2e/helpers.ts` — new exported constants

Replace the current private module-scope declarations (lines 12-25: the
`normalizeIdpBaseUrl` function, `KEYCLOAK_BASE_URL`, `KEYCLOAK_TOKEN_URL`,
`KEYCLOAK_CLIENT_ID`) with exported versions consuming spec files will import.

```
export function normalizeIdpBaseUrl(raw: string | undefined): string
  // unchanged body/behavior — only its export-ness changes (needed because
  // BPM_IDP_BASE_URL's default now resolves to port 8082, and the normalization
  // logic — localhost/127.0.0.1 canonicalization, trailing-slash strip — must stay
  // a single source of truth alongside the constant it feeds).
  // fallback literal inside changes from 'http://localhost:8081'
  //                              to   'http://localhost:8082'

export const BPM_IDP_BASE_URL: string
  // = normalizeIdpBaseUrl(process.env.BPM_IDP_BASE_URL)
  // env var name UNCHANGED (BPM_IDP_BASE_URL) — already the established escape
  // hatch used 20+ times; only its default value changes, port 8081 -> 8082.

export const BPM_IDP_CLIENT_ID: string
  // = process.env.BPM_IDP_CLIENT_ID ?? 'letflow-web'
  // NEW env var (BPM_IDP_CLIENT_ID) — no override existed before this fix.
  // default literal changes from 'bpm-platform-api' to 'letflow-web'.

const KEYCLOAK_TOKEN_URL: string
  // = `${BPM_IDP_BASE_URL}/realms/bpm-default/protocol/openid-connect/token`
  // stays module-private (unchanged — only helpers.ts's own
  // getKeycloakToken() consumes it); rebased onto the new exported
  // BPM_IDP_BASE_URL constant instead of the old private KEYCLOAK_BASE_URL.
```

`getKeycloakToken`'s body: the one call site using `KEYCLOAK_CLIENT_ID` (currently
line 36, `client_id: KEYCLOAK_CLIENT_ID`) is rebased onto `BPM_IDP_CLIENT_ID`. No
change to `getKeycloakToken`'s or `loginWithToken`'s exported signatures.

**Naming rationale:** `BPM_IDP_*` (not `KEYCLOAK_*`) matches the already-established
env var name `BPM_IDP_BASE_URL` that every spec file already reads via
`process.env.BPM_IDP_BASE_URL` — keeping the exported constant's name aligned with
the env var it wraps avoids a second, inconsistent naming scheme for the same
concept. Internal `KEYCLOAK_TOKEN_URL`/`KEYCLOAK_DISCOVERY_URL`-shaped local names in
consuming files may keep the `KEYCLOAK_` prefix for their own derived values (e.g.
`` `${BPM_IDP_BASE_URL}/realms/bpm-default/.well-known/openid-configuration` ``) —
only the base-URL and client-id constants themselves are renamed/exported.

## 3. `web/tests/e2e/pipeline.ts`

Delete its local redeclaration (current lines 27-31: the two comment lines, `const
KEYCLOAK_BASE_URL = (process.env.BPM_IDP_BASE_URL ?? 'http://localhost:8081')...`,
`const KEYCLOAK_CLIENT_ID = 'bpm-platform-api'`).

Add:
```
import { BPM_IDP_BASE_URL, BPM_IDP_CLIENT_ID } from './helpers'
```
(sibling file — `pipeline.ts` lives directly in `web/tests/e2e/`, same as
`helpers.ts`.)

Every remaining reference to the old local `KEYCLOAK_BASE_URL`/`KEYCLOAK_CLIENT_ID`
identifiers in `pipeline.ts` (line 35's template literal, line 65's `client_id:
KEYCLOAK_CLIENT_ID`) is rebased onto the imported `BPM_IDP_BASE_URL`/
`BPM_IDP_CLIENT_ID` — same identifiers used downstream, only their declaration
moves.

## 4. Direct-sibling spec files (import `./helpers`)

Files sitting directly in `web/tests/e2e/` (not a subdirectory): every file in
group C from the issue text that is NOT under `onboarding/`, `pipelines/`, or
`admin/`. For each: delete the local `const KEYCLOAK_BASE_URL = ...` /
`const KEYCLOAK_CLIENT_ID = ...` declaration(s) actually present in that file (not
every file declares both — e.g. `f4-task-inbox.e2e.spec.ts` declares only
`KEYCLOAK_CLIENT_ID`, not a base-URL constant), and add or extend the import from
`./helpers` to bring in whichever of `BPM_IDP_BASE_URL`/`BPM_IDP_CLIENT_ID` that
file actually uses. Where a file already imports something from `./helpers` (e.g.
`sh01-04.shell.e2e.spec.ts:24` already has
`import { getKeycloakToken, loginWithToken } from './helpers'`), extend that same
import statement's named-import list rather than adding a second `import ... from
'./helpers'` line.

Concrete per-file list (verified against live source):
- `env04.e2e.spec.ts` — extend existing `./helpers` import; delete local
  `KEYCLOAK_BASE_URL` (lines 39-42 area); see §6 for its inline `client_id:
  'bpm-platform-api'` literal (line 632) as a group-D-style fix.
- `f4-task-inbox.e2e.spec.ts` — extend existing `./helpers` import; delete local
  `KEYCLOAK_CLIENT_ID`.
- `f5-admin-groups-tokens.e2e.spec.ts` — extend existing `./helpers` import; delete
  local `KEYCLOAK_BASE_URL` and `KEYCLOAK_CLIENT_ID`.
- `f5-admin-observability.e2e.spec.ts` — same as above.
- `f5-admin-users.e2e.spec.ts` — same as above.
- `f6-dlq.e2e.spec.ts` — extend existing `./helpers` import; delete local
  `KEYCLOAK_BASE_URL` (no local `KEYCLOAK_CLIENT_ID` present in this file today —
  confirm at implementation time whether it needs `BPM_IDP_CLIENT_ID` too, i.e.
  whether it constructs a token request itself vs. only calling
  `getKeycloakToken`/`loginWithToken`).
- `f6-webhooks.e2e.spec.ts` — extend existing `./helpers` import; delete local
  `KEYCLOAK_BASE_URL` and `KEYCLOAK_CLIENT_ID`.
- `tenant-dashboard.e2e.spec.ts` — extend existing `./helpers` import; delete local
  `KEYCLOAK_BASE_URL`.
- `tenants.e2e.spec.ts` — same as above.
- `uat-alice-login.e2e.spec.ts` — add new `./helpers` import (none currently
  present per §-checked grep); delete local `KEYCLOAK_BASE_URL`.
- `uat-eo-003-004-v5.e2e.spec.ts` — delete local `const IDP_URL = process.env.
  BPM_IDP_BASE_URL || 'http://localhost:8081'` and either import
  `BPM_IDP_BASE_URL` from `./helpers` directly (rename call sites from `IDP_URL` to
  `BPM_IDP_BASE_URL`) or keep a local alias `const IDP_URL = BPM_IDP_BASE_URL` — a
  same-file naming preference, not load-bearing; FRONTEND-DEV's choice, but must not
  reintroduce a second hardcoded `8081` fallback.
- `uat-tenant-url.e2e.spec.ts` — delete local `const idpBaseUrl = (process.env.
  BPM_IDP_BASE_URL ?? 'http://localhost:8081')...`; import `BPM_IDP_BASE_URL` from
  `./helpers` (same rename-or-alias choice as above).
- `admin/services.e2e.spec.ts` — see §5 (subdirectory).

## 5. Subdirectory spec files (import `../helpers`)

`web/tests/e2e/admin/services.e2e.spec.ts`,
`web/tests/e2e/onboarding/onb-ui-01.e2e.spec.ts` through `onb-ui-04.e2e.spec.ts`,
and all four `web/tests/e2e/pipelines/*.pipeline.e2e.spec.ts` files (§1's
correction) sit exactly one directory below `web/tests/e2e/`, so their import path
is `../helpers`, not `./helpers`:

```
import { BPM_IDP_BASE_URL, BPM_IDP_CLIENT_ID } from '../helpers'
```
(only the constants each file actually references — most of these files declare
only `KEYCLOAK_BASE_URL`, not a client-id constant; `admin/services.e2e.spec.ts`
already has `import { getKeycloakToken, loginWithToken } from '../helpers'` at line
15 — extend that same statement.)

Delete each file's local `const KEYCLOAK_BASE_URL = ...` / `const
KEYCLOAK_DISCOVERY(_URL) = ...` — note `KEYCLOAK_DISCOVERY`/`KEYCLOAK_DISCOVERY_URL`
itself is a **derived** local constant (`` `${KEYCLOAK_BASE_URL}/realms/bpm-default/
.well-known/openid-configuration` ``), not a duplicate of anything in helpers.ts —
it stays as a local `const`, just rebased onto the imported `BPM_IDP_BASE_URL`
instead of the deleted local `KEYCLOAK_BASE_URL`.

## 6. Assertion rewrites (group D — regression-test and hardcoded-literal fixes)

### 6.1 `iss-0063-oidc-redirect-loop.e2e.spec.ts`

This file is itself a regression test guarding against a *prior* Keycloak
port-mismatch bug (tenant-config reporting a different Keycloak authority than the
one actually used for the redirect). Its invariant is **consistency between two
independently-observed authority values**, not the specific numeric port — so every
rewrite below preserves that comparison shape rather than hardcoding a new number
in its place.

- **Doc comment, line 5** (`tenant-config must return the browser-visible localhost
  authority on :8081`): reword to state the invariant without the number —
  "tenant-config must return the browser-visible localhost authority matching the
  IdP's actual configured port (see `BPM_IDP_BASE_URL` in `./helpers`)."
- **Line 18** (`const KEYCLOAK_BASE_URL = (process.env.BPM_IDP_BASE_URL ?? '').
  replace(/\/$/, '')`): delete; import `BPM_IDP_BASE_URL` from `./helpers` instead
  (this file is a direct sibling of `helpers.ts`). Note this file's own current
  fallback is `''` (empty string), not `8081` — importing the shared constant also
  fixes that latent bug (an empty-string fallback silently building a malformed
  discovery URL) as a side effect of consolidation, not as new scope.
- **Line 21** (`KEYCLOAK_DISCOVERY_URL`): stays a local derived `const`, rebased
  onto the imported `BPM_IDP_BASE_URL` (same treatment as §5).
- **Line 56** (`expect(body.oidc_authority).toContain('http://localhost:8081/
  realms/')`): rewrite to `expect(body.oidc_authority).toContain(
  \`${BPM_IDP_BASE_URL}/realms/\`)` — asserts the tenant-config response's
  authority is built from the *actual configured* IdP base URL, which is the real
  invariant (does tenant-config's reported authority match reality), not a specific
  port number.
- **Line 58** (`expect(body.client_id).toBe('bpm-platform-api')`): rewrite to
  `expect(body.client_id).toBe(BPM_IDP_CLIENT_ID)` (import `BPM_IDP_CLIENT_ID`
  alongside `BPM_IDP_BASE_URL`) — same reasoning: asserts tenant-config reports the
  actual configured client id, not a stale literal.
- **Line 98** (test name string, `'TC-ISS-0063-01: tenant-config returns the
  browser-visible localhost authority with port 8081'`): reword to drop the
  hardcoded port from the test's own name — e.g. "...with the configured IdP
  port" — since the test id (`TC-ISS-0063-01`) is what other docs/reports key off
  of, not the descriptive suffix; the descriptive text must stop asserting a
  specific number it no longer hardcodes.
- **Line 117** (`expect(authUrl).toContain('localhost:8081')`): rewrite to extract
  the actual host:port from `BPM_IDP_BASE_URL` (e.g. via `new URL(BPM_IDP_BASE_URL).
  host`) and assert `authUrl` contains that host — this is the core regression
  check (does the actual redirect URL's authority match the configured IdP's
  authority) and must keep comparing two live-derived values, not a literal
  against a live value, or the regression this test exists to catch (a
  redirect authority silently drifting from the configured one) becomes
  unreachable again the next time the port changes.

### 6.2 `oidcf-login.e2e.spec.ts:152`

`expect(url).toContain('client_id=bpm-platform-api')` → `expect(url).toContain(
\`client_id=${BPM_IDP_CLIENT_ID}\`)`. Import `BPM_IDP_CLIENT_ID` from `./helpers`
(extend this file's existing `KEYCLOAK_BASE_URL`-adjacent declarations — this file
does not currently import from `./helpers` at all per §1's grep, it declares its
own `KEYCLOAK_BASE_URL`/`KEYCLOAK_REALM_URL`/`KEYCLOAK_AUTH_PATTERN` locally; add a
fresh `import { BPM_IDP_BASE_URL, BPM_IDP_CLIENT_ID } from './helpers'` and rebase
`KEYCLOAK_BASE_URL`'s local declaration onto it the same way as §4).

### 6.3 `sh01-04.shell.e2e.spec.ts:76`

`expect(capturedUrl).toContain('client_id=bpm-platform-api')` → `expect(capturedUrl)
.toContain(\`client_id=${BPM_IDP_CLIENT_ID}\`)`. This file already imports from
`./helpers` at line 24 (`getKeycloakToken, loginWithToken`) — extend that import to
add `BPM_IDP_CLIENT_ID`.

### 6.4 `oidcf2-subdomain.e2e.spec.ts:60`

`expect(body.client_id).toBe('bpm-platform-api')` → `expect(body.client_id).toBe(
BPM_IDP_CLIENT_ID)`. Import `BPM_IDP_CLIENT_ID` from `./helpers`.

### 6.5 `env04.e2e.spec.ts:632`

`client_id: 'bpm-platform-api'` (inline in a request-body object literal, inside a
larger fixture-building block using `KEYCLOAK_BASE_URL` throughout) → `client_id:
BPM_IDP_CLIENT_ID`. Import `BPM_IDP_CLIENT_ID` alongside `BPM_IDP_BASE_URL` in this
file's existing `./helpers` import (§4).

## 7. Comment-only fixes (group E)

Update stale `http://localhost:8081/...` prose in doc comments — these are
non-executing text, so the fix is a literal string edit, not a code change:

- `f2-canvas.e2e.spec.ts:21`, `f2-canvas-shoulds.e2e.spec.ts:21`,
  `f2-definition-list.e2e.spec.ts:21`, `pdui07-export-import.e2e.spec.ts:21`,
  `pdui08-debounced-search.e2e.spec.ts:21` — all carry the identical comment line
  `*   - Keycloak: http://localhost:8081/realms/bpm-default` → change `8081` to
  `8082`.
- `rnd-ui-05.rate-limit-backpressure.e2e.spec.ts:10` — `*  http://localhost:8081/
  realms/bpm-default, BPM API http://127.0.0.1:8080,` → change `8081` to `8082`
  (leave the unrelated `8080` BPM API port reference untouched — not in scope,
  that's a different service's port, not Keycloak's).

None of these five files declare a local `KEYCLOAK_BASE_URL`/`KEYCLOAK_CLIENT_ID`
constant (confirmed by the group-C/D greps in §1 not matching them) — comment-only
edits are their complete fix.

## 8. Complete file set to be touched

1. `web/tests/e2e/helpers.ts` (§2 — new exports)
2. `web/tests/e2e/pipeline.ts` (§3)
3. `web/tests/e2e/env04.e2e.spec.ts` (§4, §6.5)
4. `web/tests/e2e/f4-task-inbox.e2e.spec.ts` (§4)
5. `web/tests/e2e/f5-admin-groups-tokens.e2e.spec.ts` (§4)
6. `web/tests/e2e/f5-admin-observability.e2e.spec.ts` (§4)
7. `web/tests/e2e/f5-admin-users.e2e.spec.ts` (§4)
8. `web/tests/e2e/f6-dlq.e2e.spec.ts` (§4)
9. `web/tests/e2e/f6-webhooks.e2e.spec.ts` (§4)
10. `web/tests/e2e/tenant-dashboard.e2e.spec.ts` (§4)
11. `web/tests/e2e/tenants.e2e.spec.ts` (§4)
12. `web/tests/e2e/uat-alice-login.e2e.spec.ts` (§4)
13. `web/tests/e2e/uat-eo-003-004-v5.e2e.spec.ts` (§4)
14. `web/tests/e2e/uat-tenant-url.e2e.spec.ts` (§4)
15. `web/tests/e2e/admin/services.e2e.spec.ts` (§5)
16. `web/tests/e2e/onboarding/onb-ui-01.e2e.spec.ts` (§5)
17. `web/tests/e2e/onboarding/onb-ui-02.e2e.spec.ts` (§5)
18. `web/tests/e2e/onboarding/onb-ui-03.e2e.spec.ts` (§5)
19. `web/tests/e2e/onboarding/onb-ui-04.e2e.spec.ts` (§5)
20. `web/tests/e2e/pipelines/admin-user-lifecycle.pipeline.e2e.spec.ts` (§5)
21. `web/tests/e2e/pipelines/onboarding-wizard.pipeline.e2e.spec.ts` (§5)
22. `web/tests/e2e/pipelines/sim-admin-processes.pipeline.e2e.spec.ts` (§5)
23. `web/tests/e2e/pipelines/sim-company-onboarding.pipeline.e2e.spec.ts` (§5)
24. `web/tests/e2e/iss-0063-oidc-redirect-loop.e2e.spec.ts` (§6.1)
25. `web/tests/e2e/oidcf-login.e2e.spec.ts` (§6.2)
26. `web/tests/e2e/sh01-04.shell.e2e.spec.ts` (§6.3)
27. `web/tests/e2e/oidcf2-subdomain.e2e.spec.ts` (§6.4)
28. `web/tests/e2e/f2-canvas.e2e.spec.ts` (§7)
29. `web/tests/e2e/f2-canvas-shoulds.e2e.spec.ts` (§7)
30. `web/tests/e2e/f2-definition-list.e2e.spec.ts` (§7)
31. `web/tests/e2e/pdui07-export-import.e2e.spec.ts` (§7)
32. `web/tests/e2e/pdui08-debounced-search.e2e.spec.ts` (§7)
33. `web/tests/e2e/rnd-ui-05.rate-limit-backpressure.e2e.spec.ts` (§7)

33 files total — matches ISSUE-FIXER's original count of 33 files carrying a match,
confirmed against live source rather than assumed.

## 9. Invariants this design preserves

- **Single source of truth.** After this fix, exactly one place (`helpers.ts`)
  declares the default Keycloak base URL and client id; every other file imports
  rather than redeclaring. A future port/client-id change touches one file.
- **Override paths remain available and are now complete.** `BPM_IDP_BASE_URL`
  (pre-existing env var, now also exported as a constant) and `BPM_IDP_CLIENT_ID`
  (new env var, no prior override existed) both remain settable from the test
  runner's environment — no test hardcodes a value that can't be overridden for a
  non-default local/CI Keycloak deployment.
- **`iss-0063-oidc-redirect-loop.e2e.spec.ts`'s regression intent is preserved, not
  weakened.** Every rewritten assertion in §6.1 still compares two independently
  observed values (tenant-config's reported authority/client_id vs. the actual
  redirect's) rather than collapsing to "assert against the new hardcoded literal,"
  which would silently reintroduce the same drift-goes-undetected failure mode the
  test exists to catch, just at a different port number.
- **No production/`web/src` code changes.** Every file in §8 is under
  `web/tests/e2e/`.

## 10. Open questions for FRONTEND-DEV / REVIEWER

1. `f6-dlq.e2e.spec.ts` has no local `KEYCLOAK_CLIENT_ID` declaration today (only
   `KEYCLOAK_BASE_URL`) — confirm at implementation time whether it needs
   `BPM_IDP_CLIENT_ID` imported too (i.e. does it build any token/auth request
   itself, or only call `getKeycloakToken`/`loginWithToken` from helpers). Not
   resolved here because it depends on reading the file's full body beyond the
   grepped declaration lines, which is implementation-time work, not a design
   decision.
2. §4's `uat-eo-003-004-v5.e2e.spec.ts` and `uat-tenant-url.e2e.spec.ts`: whether to
   rename their local `IDP_URL`/`idpBaseUrl` call sites to the imported
   `BPM_IDP_BASE_URL` directly, or keep a local `const IDP_URL = BPM_IDP_BASE_URL`
   alias to minimize the diff inside those files. Left as FRONTEND-DEV's choice —
   either satisfies the single-source-of-truth invariant (§9); only a *second
   hardcoded fallback* would violate it.
3. Whether `normalizeIdpBaseUrl`'s newly-`export`ed status should also be used
   directly by any spec file instead of always going through the pre-normalized
   `BPM_IDP_BASE_URL` constant. Not needed by any file in §8's list today — flagged
   only so FRONTEND-DEV doesn't wonder why it's exported if unused elsewhere; it's
   exported because `helpers.ts`'s own `BPM_IDP_BASE_URL` constant needs it, and
   making it available doesn't cost anything else.
