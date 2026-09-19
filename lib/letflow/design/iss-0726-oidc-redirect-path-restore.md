# ISS-0726 — Design: restore the pre-redirect path across the OIDC hard-navigation round trip

**Files to change:** `web/src/auth/oidcRedirectArgs.ts`, `web/src/auth/ProtectedRoute.tsx`,
`web/src/auth/AuthProvider.tsx`, `web/src/pages/OidcCallbackPage.tsx`
**New file:** `web/src/auth/safeRestorePath.ts` (+ `web/src/auth/__tests__/safeRestorePath.test.ts`,
Vitest, written by TEST-DESIGNER per Step 3 — not by this design)
**Route to:** FRONTEND-DEV (all changes are in `web/`; no `lib/letflow/` or migration
touched). Requires SECURITY-REVIEWER sign-off before REVIEWER — this is an
open-redirect-shaped surface (state round-trips through Keycloak).
**Related:** `docs/issues/ISS-0726.yaml`, `docs/migration/decisions/0002-oidc-integration-decision.md`,
`lib/letflow/design/iss-0712-real-oidc-redirect-login-helper.md` (precedent for a
`web/`-only, non-Elixir design in this same directory), `iss0718-candidate-exam-list-route.md`
(the `/exam` route this bug blocks access to)

Diagnosis is pre-confirmed by ISSUE-FIXER (see the handoff and `docs/issues/ISS-0726.yaml`)
— root cause not re-derived here, only the fix shape. Root cause independently
re-verified against current `main` (fetched at `e0b3fdc7`) while writing this design:
`ProtectedRoute.tsx:13-20`, `oidcRedirectArgs.ts:11-18`, `AuthProvider.tsx:13-17`,
`OidcCallbackPage.tsx:72` all match ISSUE-FIXER's line numbers and described shape
exactly as summarized in the task.

Mechanism confirmed directly against the resolved `oidc-client-ts` package in
`web/node_modules/oidc-client-ts/dist/types/oidc-client-ts.d.ts` (not assumed from
memory): `ExtraSigninRequestArgs` (used by `UserManager.signinRedirect`) includes a
`state?: unknown` field (`oidc-client-ts.d.ts:243`); `UserManager`'s default
`stateStore` (when `settings.stateStore` is not supplied, which this codebase does not
supply — only `userStore` is overridden, see `OidcManager.ts:29`) is
`new WebStorageStateStore({ store: window.localStorage })`
(`dist/esm/oidc-client-ts.js:1073-1074`), so the pending-signin `SigninState` (holding
this `state` value, among PKCE/nonce data) survives the full-page navigation away to
Keycloak and back — `localStorage`, not the in-memory `userStore` used for tokens, is
what already carries the round trip today. `User.state: unknown`
(`oidc-client-ts.d.ts:1509`, "custom state data set during the initial signin request")
is populated from that same value after `signinRedirectCallback()` resolves
(`dist/esm/oidc-client-ts.js:1975`, `stateStore.get(response.state)`). This closes
ISSUE-FIXER's approach as mechanically correct, not merely plausible.

---

## 1. New shared module: `safeRestorePath.ts`

### 1.1 Why a new file, not inlined in `oidcRedirectArgs.ts` or `OidcCallbackPage.tsx`

The validation function is used on the **restore side** (`OidcCallbackPage.tsx`) only,
but is designed as an independently testable pure function in its own file so
TEST-DESIGNER can write a focused Vitest unit suite against it (per the task's two-tier
test strategy) without pulling in `oidc-client-ts` mocking. `web/src/auth/` is the
existing home for auth-adjacent pure utilities (`tenantConfig.ts`, `tokenUtils.ts`) —
same placement precedent.

### 1.2 Signature

```
export function isSafeRestorePath(value: unknown): value is string
```

A type-guard, not a boolean-returning validator with a separate cast — this lets the
one call site (§3) use the return directly as a type-narrowing condition without an
`as string` afterward.

### 1.3 Validation rule (explicit, not left to the builder's judgment)

`value` is a safe restore path if and only if **all** of the following hold:

1. `typeof value === 'string'`.
2. `value.length > 0` and `value.length <= 2048` (defends against a pathologically long
   `state` value being echoed into a `navigate()` call for no functional reason; 2048
   matches common practical URL-length ceilings, not a spec requirement — chosen only
   as a sane upper bound, no acceptance criterion depends on the exact number).
3. `value.startsWith('/')` — must be root-relative.
4. `!value.startsWith('//')` — a leading `//` is browser-parsed as a
   protocol-relative URL (`//evil.example.com/...` navigates off-origin); this is the
   single most important check, since `react-router`'s `navigate()` and a bare
   `window.location`-style value both honor it.
5. `!/^\/\s*\\/.test(value)` is insufficient alone — instead, reject any value
   containing a backslash (`value.includes('\\')`) — some browsers normalize
   `/\evil.com` as `//evil.com` during navigation; excluding backslash entirely closes
   that class regardless of position.
6. `!/[a-zA-Z][a-zA-Z0-9+.-]*:/.test(value)` — reject any embedded URL scheme
   (`javascript:`, `data:`, `https:`, etc.) appearing anywhere in the string, not just
   at the start — defends against a value like `/x@evil.com` being irrelevant (no colon,
   so not a scheme) versus `/redirect?to=javascript:alert(1)` which does contain one and
   must be rejected even though it starts with `/`. This check governs the *raw* string,
   before any router matching, so a scheme hidden in a query string is still caught.
7. The path portion (everything before the first `?` or `#`, or the whole string if
   neither is present) matches `^\/[A-Za-z0-9\-_/]*$` after stripping a trailing
   `/exam/:examId/session`-style dynamic segment is **not** special-cased — this is a
   plain character-class check on the literal path text as-authored, not a router-aware
   match. Concretely: `/exam`, `/exam/abc-123/session`, `/exam/sessions/xyz/result` all
   pass; `/exam/<script>` fails (contains `<`/`>`); `/exam?x=<script>` passes the path
   check (query is checked separately, item 8) since `<script>` never reaches the path
   portion in this example — but see item 8 for why the query string is bounded too.
8. If a `?` is present, the query-string portion (from `?` to the first `#`, or to the
   end) matches `^[A-Za-z0-9\-_.~%!$&'()*+,;=:@/?]*$` — the RFC 3986 `pchar`/`query`
   safe set plus `?` (a second literal `?` is legal inside a query string) — rejecting
   `<`, `>`, `"`, backtick, and raw whitespace, which is what an injected-markup or
   header-splitting payload would need.
9. If a `#` is present, the fragment portion (from `#` to the end) matches the same
   character class as item 8.

**Decision: regex-only, not a route-table match (resolves ISSUE-FIXER's open
question).** `router.tsx` has no exported list of valid paths — routes are declared
inline as JSX children of `createBrowserRouter([...])` (`web/src/router.tsx:44-90`),
several with dynamic `:id`-shaped segments (`definitions/:id`, `instances/:id`,
`exam/:examId/session`, `admin/users/:userId`, …). Building and maintaining a second,
parallel "known route" list purely for this validator would drift from `router.tsx`
the moment a route is added or renamed there and not here — the exact duplication
hazard `docs/anti-patterns.md`'s existing entries warn against elsewhere in this
codebase. A strict character-class + scheme/protocol-relative rejection (items 1-9)
gives the actual security property needed (no off-origin navigation, no injected
markup/URL) without that maintenance coupling. A path that passes this validator but
names a route that does not exist (e.g. a stale bookmark to a since-removed page) is
not a security concern — `react-router`'s existing "no matching route" handling (or a
future 404 route) governs that outcome exactly as it would for a normal deep link
typed directly into the address bar, which is explicitly the same trust level this bug
is about restoring.

### 1.4 Non-goals

- Does **not** URL-decode `value` before checking — Keycloak returns `state` verbatim
  as stored (an opaque round-tripped value, not URL-transport-encoded at this layer),
  and `navigate()` from `react-router-dom` does not itself decode a path argument
  either, so decode-then-check would validate a different string than the one actually
  navigated to. If a future caller needs a decoded variant, that is a new, separate
  function — not a hidden behavior of this one.
- Does **not** attempt to canonicalize (`..` collapsing, trailing-slash normalization)
  — item 7's character class already excludes `.` sequences from being meaningful
  (`-`, `_`, `/`, alnum only in the path portion — no `.` at all in the path-portion
  class, so `/../etc` is rejected outright as containing a disallowed character, not
  parsed and canonicalized).

---

## 2. Capture side: `buildRedirectArgs()` dedup + `state` capture

### 2.1 Dedup decision

`oidcRedirectArgs.ts`'s `buildRedirectArgs()` (exported, already imported by
`ProtectedRoute.tsx`) becomes the **single** implementation. `AuthProvider.tsx`'s
private, near-identical `buildRedirectArgs()` (lines 13-17) is **deleted**, and
`AuthProvider.tsx` imports the shared one from `./oidcRedirectArgs` instead
(`AuthProvider.tsx` already imports `getOidcManager` from a sibling `./` path, so the
import-path convention already exists in this file). This directly satisfies the task's
"dedupe the two near-duplicate `buildRedirectArgs()` implementations."

### 2.2 New signature

```
export function buildRedirectArgs(
  capturePath?: string,
): { redirect_uri: string; state?: string } | undefined
```

- New optional parameter `capturePath`, defaulting to `undefined` when omitted (backward
  compatible with any other, currently-nonexistent, call site).
- Return type gains an optional `state` field alongside the existing `redirect_uri`.
  Still returns `undefined` in exactly the same case as today (no realm slug resolvable)
  — that existing branch (`TC-OIDC-F02-02`) is unchanged in shape and behavior; see §5's
  compatibility note on why this keeps that existing test passing unmodified.

### 2.3 Behavior (ordered; shape only, no implementation code)

1. Resolve `slug` via `resolveRealmFromUrl()`, exactly as today.
2. If `slug` is falsy, return `undefined` — unchanged from today.
3. Build `redirect_uri` exactly as today (`window.location.origin + '/auth/callback?realm=' + encodeURIComponent(slug)`).
4. If `capturePath` is provided **and** `isSafeRestorePath(capturePath)` is `true`
   (§1.2), include `state: capturePath` in the returned object. This is the capture-side
   half of the safety check — validating again at capture time (not only at restore
   time in `OidcCallbackPage.tsx`) is deliberate defense in depth: `state` is round-tripped
   through Keycloak and this app's own `localStorage`-backed `stateStore` between the two
   points, and re-validating on the way back (§3) does not excuse skipping validation on
   the way in, since a future caller of `buildRedirectArgs` (not only `ProtectedRoute`)
   could pass an unsafe value in `capturePath` directly.
5. If `capturePath` is omitted, or provided but fails `isSafeRestorePath`, the returned
   object omits `state` entirely (not `state: undefined` as an explicit key — omit the
   key) — this keeps `AuthProvider.tsx`'s session-expired call site (which has no
   meaningful "path to restore," see §2.5) producing exactly the same
   `{ redirect_uri }`-shaped object it does today, byte-for-byte.

### 2.4 Call-site change: `ProtectedRoute.tsx`

`ProtectedRoute.tsx:17`'s call-site argument changes (exact literal shape; not
implementation — see §3.1's same convention note):
```
buildRedirectArgs()  →  buildRedirectArgs(window.location.pathname + window.location.search)
```
This is the capture: `window.location.pathname + window.location.search` is read at the
exact moment `ProtectedRoute` decides to redirect (inside the existing `useEffect`,
before `signinRedirect` navigates away) — i.e. the hard-navigation entry path itself
(`/exam` in ISS-0726's reproduction), including any query string a deep link might carry.
`window.location.hash` is deliberately **not** included — a hash fragment is never sent
to the server and any in-app hash-routing this SPA might add later is out of scope for
this fix; omitting it is a conscious choice, not an oversight, and does not affect
ISS-0726's reproduction (`/exam` carries no hash).

### 2.5 Call-site change: `AuthProvider.tsx`'s session-expired handler

`AuthProvider.tsx:47`'s
```
void m.signinRedirect(buildRedirectArgs())
```
stays a **zero-argument** call: `buildRedirectArgs()` (no `capturePath`). Rationale,
stated explicitly since the task calls out "both need the identical fix" for the
*dedup*, not necessarily for *capture behavior*: a session-expiry redirect fires from
the API client's `auth:session-expired` event, which can occur mid-interaction on any
page — capturing `window.location.pathname` here is legitimate and arguably desirable
future work, but is **out of scope** for ISS-0726, whose reproduction and acceptance
criteria are specifically about the hard-navigation entry case in `ProtectedRoute`, not
the session-expiry case. Extending capture to session-expiry is a natural follow-up;
flagging it here (§6 open item) rather than silently bundling it keeps this fix's blast
radius matched to what UAT actually reproduced. If FRONTEND-DEV/REVIEWER judges this
too conservative, `AuthProvider.tsx` can pass `window.location.pathname + window.location.search`
here too with no design change needed beyond this note being resolved — the function
signature in §2.2 already supports it either way.

---

## 3. Restore side: `OidcCallbackPage.tsx`

### 3.1 Change to the post-login `navigate()` call

Current (`OidcCallbackPage.tsx:72`):
```
navigate(payload.roles.includes('PLATFORM_ADMIN') ? '/platform-dashboard' : '/', { replace: true })
```

New (three-tier resolution, in this exact priority order — this is the call-site
*design*, stating the exact decision shape so no judgment call is left open, per
`iss-0712-real-oidc-redirect-login-helper.md`'s same "exact literal shape, not
implementation" convention in this directory; FRONTEND-DEV writes the real code):
```
restoredPath = isSafeRestorePath(user.state) ? user.state : null
destination  = restoredPath present ? restoredPath
                                     : (PLATFORM_ADMIN in roles ? '/platform-dashboard' : '/')
navigate(destination, { replace: true })
```

Priority, stated explicitly:
1. **A validated restored path wins whenever present** — including for a
   `PLATFORM_ADMIN` user. This matches the task's instruction ("prefer the restored
   `user.state` path over the role-based fallback; keep `PLATFORM_ADMIN` →
   `/platform-dashboard` only when no captured path exists"). A `PLATFORM_ADMIN` user
   who hard-navigated to a specific deep link (once such a link exists for that role)
   lands there, not on the dashboard — same principle ISS-0726 exists to fix for every
   role, applied without a role-based carve-out.
2. Falling back to the existing role-conditional branch **only** when `user.state` is
   absent (the `AuthProvider.tsx` session-expired path, per §2.5, and any fresh login
   initiated from `/` where `ProtectedRoute` captured `'/' + ''` — see §3.2) or fails
   `isSafeRestorePath` (defense against a malformed/tampered `state` value — see the
   task's threat framing: `state` is attacker-reachable in principle even though this
   app's own client code is the only current writer).
3. `user.state` is typed `unknown` by `oidc-client-ts` (§0's mechanism note) —
   `isSafeRestorePath` (§1.2) is the type guard that narrows it to `string` before use,
   so no unchecked cast is needed at this call site.

### 3.2 The `/` self-capture case does not create a redundant redirect

If a user is already on `/` and unauthenticated, `ProtectedRoute` captures
`window.location.pathname + window.location.search` = `'/'` (plus empty search).
`isSafeRestorePath('/')` returns `true` (passes all of §1.3's checks — a single `/`
satisfies items 1-9 trivially). So `restoredPath` resolves to `'/'` and the
non-`PLATFORM_ADMIN` fallback branch would have produced `'/'` anyway — behaviorally
identical, not a regression, just no longer "falling through" to the role branch for
that specific case. **The one behavior change from this**: a `PLATFORM_ADMIN` user who
hard-navigates to `/` directly (not via a stale session) now also lands on `/`, not
`/platform-dashboard` — because `restoredPath` is present. This is called out
explicitly as a deliberate consequence of §3.1's priority order (item 1: "a validated
restored path wins whenever present, including for PLATFORM_ADMIN"), not an
accidental one — see §5 for why `OidcCallbackPage.test.tsx`'s existing PLATFORM_ADMIN
assertion is unaffected by this (that test never sets `user.state`).

### 3.3 Import addition

`OidcCallbackPage.tsx` gains one new import:
```
import { isSafeRestorePath } from '@/auth/safeRestorePath'
```

---

## 4. Data/type shapes touched (summary)

| Item | Shape |
|---|---|
| `buildRedirectArgs` param | `capturePath?: string` (new, optional) |
| `buildRedirectArgs` return | `{ redirect_uri: string; state?: string } \| undefined` (was `{ redirect_uri: string } \| undefined`) |
| `isSafeRestorePath` | `(value: unknown) => value is string` (new, pure, no I/O) |
| `user.state` (from `oidc-client-ts`, unmodified) | `unknown` — narrowed at the one call site in `OidcCallbackPage.tsx` via `isSafeRestorePath` |
| No new Ecto schema, migration, or DB column — this is entirely client-side, round-tripped through Keycloak's existing `state` OAuth parameter and `oidc-client-ts`'s existing `localStorage`-backed `stateStore`, per §0's mechanism note. No new persistent storage is introduced. | n/a |

---

## 5. Existing tests that must keep passing unchanged (re-verified by reading both files, not assumed)

**`web/src/auth/buildRedirectArgs.test.ts`** (read in full). All three cases
(`TC-OIDC-F02-01/02/03`) call `buildRedirectArgs()` with **zero arguments**. Per §2.2,
`capturePath` is optional and defaults to behaving exactly as today when omitted: case
01/03 assert only `result.redirect_uri`'s exact value (never inspect `result.state`,
and `state` is correctly absent since no `capturePath` was passed) — still true
verbatim. Case 02 asserts `result` is `undefined` when no realm slug resolves — that
branch (§2.3 step 2) is untouched. **No edit needed to this file's test bodies**; only
its own module under test changes, additively. TEST-DESIGNER should add new cases
alongside these (see §6.1) rather than modify the existing three.

**`web/src/pages/__tests__/OidcCallbackPage.test.tsx`** (read in full). Both existing
cases (`TC-REQ369-05` PLATFORM_ADMIN, `TC-REQ369-06` PROCESS_OPERATOR) mock
`signinRedirectCallback` to resolve `{ access_token: token }` — **no `state` key at
all**, so `user.state` is `undefined` in both. `isSafeRestorePath(undefined)` is
`false` (fails check 1's `typeof value === 'string'`), so `restoredPath` is `null` in
both existing tests, and §3.1's fallback (item 2) applies exactly as before — both
existing assertions (`navigate` called with `/platform-dashboard` vs `/`) are
unaffected. **No edit needed to this file's existing two test bodies.** TEST-DESIGNER
adds new cases for the restored-path branch (§6.1) alongside them.

---

## 6. Test strategy (two-tier, per the task's explicit instruction)

### 6.1 Vitest unit tests (fast, gates capture/restore logic in isolation)

New: `web/src/auth/__tests__/safeRestorePath.test.ts` — table-driven cases proving
§1.3's rule set directly: `/exam` → true; `/exam/abc-123/session` → true;
`/exam?x=1` → true; `''` → false; `'exam'` (no leading slash) → false; `'//evil.com'`
→ false; `'/\\evil.com'` → false; `'https://evil.com'` → false (fails item 3, no
leading `/` after the scheme is present at all, and independently fails item 6);
`'/x?to=javascript:alert(1)'` → false (item 6); `'/<script>'` → false (item 7);
non-string inputs (`undefined`, `null`, `42`, `{}`) → false (item 1). This is the unit
layer that "gates capture/restore logic in isolation," per the task.

Extend `web/src/auth/buildRedirectArgs.test.ts` (new cases, existing three untouched
per §5): `buildRedirectArgs('/exam')` with a resolvable slug → `result.state === '/exam'`;
`buildRedirectArgs('//evil.com')` with a resolvable slug → `result.state` is `undefined`
(key absent) even though `redirect_uri` is still present — proving the capture-side
validation of §2.3 step 4 actually rejects an unsafe value rather than passing it
through.

Extend `web/src/pages/__tests__/OidcCallbackPage.test.tsx` (new cases, existing two
untouched per §5): mock `signinRedirectCallback` to resolve
`{ access_token: token, state: '/exam' }` with a `PROCESS_OPERATOR`-roled token →
assert `navigate` called with `('/exam', { replace: true })`; same but
`PLATFORM_ADMIN`-roled token with `state: '/exam'` → assert `navigate` called with
`('/exam', { replace: true })`, **not** `/platform-dashboard` (proves §3.1 item 1's
priority explicitly, not just implicitly); a case with `state: '//evil.com'` (or
another §1.3-failing value) and a `PROCESS_OPERATOR` token → assert `navigate` called
with `('/', { replace: true })` (the fallback fires, the unsafe value is never
navigated to) — this is the open-redirect regression test SECURITY-REVIEWER will look
for.

### 6.2 Playwright e2e test (gates CI's own real Keycloak)

New file `web/tests/e2e/iss-0726-oidc-deep-link-restore.e2e.spec.ts`, modeled
**exactly** on `web/tests/e2e/iss-0063-oidc-redirect-loop.e2e.spec.ts`'s real-Keycloak
pattern (same `ensurePrerequisites`/`assertBackendHealthy`/`BPM_IDP_BASE_URL` helpers
from `./helpers`, same `completeBrowserLogin`-shaped flow, same
`page.getByTestId('oidc-callback-status')` intermediate wait) but:
- starts with `await page.goto('/exam')` instead of `await page.goto('/')` — this is
  the one load-bearing difference; everything else about the login-completion
  mechanics stays the same shape as ISS-0063's `TC-ISS-0063-02`.
- after `completeBrowserLogin(...)`, asserts `await page.waitForURL('/exam', { timeout: 20_000 })`
  (not `'/'`) — this is the assertion that proves the fix end-to-end against a real
  Keycloak round trip, which is exactly what the Vitest layer in §6.1 cannot prove
  (Vitest mocks `signinRedirectCallback` entirely; it never exercises the real
  `state`/`localStorage`/Keycloak-redirect mechanics §0 described).
- reuses `assertAuthenticatedWorkspace`-equivalent assertions adapted for `/exam`
  (e.g. an exam-list-page testid, if `iss0718-candidate-exam-list-route.md`'s design
  names one — FRONTEND-DEV confirms the exact testid against `ExamListPage.tsx` as
  implemented; not re-derived here since this design does not touch
  `ExamListPage.tsx`).

### 6.3 What neither layer proves — UAT follow-up named explicitly, not silently implied as covered

**Explicitly stated, per the task's instruction not to leave this implied:** neither
the Vitest unit suite (§6.1, mocks `oidc-client-ts` and Keycloak entirely) nor the
Playwright e2e suite (§6.2, runs against a CI-local Keycloak container with no
production-like proxy/CDN layer in front of it) can prove this fix against the actual
`qa.bizdala.com` deployment ISS-0726 was discovered on. `qa.bizdala.com` sits behind
infrastructure (reverse proxy, TLS termination, possibly a CDN) that a CI Keycloak
container does not replicate, and ISS-0726's own reproduction happened specifically
against that live host. **A UAT-RUNNER live re-check against `qa.bizdala.com` (hard
navigation to `/exam`, confirm it lands on `/exam` and renders `ExamListPage`) remains
a necessary follow-up after this fix merges and deploys** — not something either test
layer substitutes for. This should be tracked as the follow-up verification step for
this fix's release, not silently assumed covered by CI going green.

---

## 7. Acceptance-criteria mapping

| Acceptance criterion (from ISS-0726 / task) | Design element |
|---|---|
| Hard nav to `/exam` (or any protected deep link) restores the originally-requested path after the OIDC round trip | §2.4 capture at `ProtectedRoute`; §3.1 restore priority in `OidcCallbackPage.tsx` |
| Capture via `oidc-client-ts`'s `state` option (not a separate `sessionStorage` key) | §0 mechanism confirmation; §2.2-2.3 |
| Dedupe the two near-duplicate `buildRedirectArgs()` | §2.1 |
| `OidcCallbackPage.tsx` prefers restored path over role-based fallback; `PLATFORM_ADMIN` → `/platform-dashboard` only when no captured path | §3.1 priority order, explicit |
| Restored path validated as safe before navigating (same-origin, real relative path, not open-redirect-shaped) — validation rule made explicit, not left to the builder | §1.3 (9 explicit checks) + §1.3's stated decision (regex, not route-table, with reasoning) |
| Two-tier test strategy: Vitest (fast, isolated) + Playwright e2e (modeled on ISS-0063, starts at `/exam`, asserts final URL `/exam`) | §6.1, §6.2 |
| Neither test layer proves the fix against the actual `qa.bizdala.com` deployment; UAT-RUNNER live re-check named as a necessary follow-up | §6.3 |
| Existing `OidcCallbackPage.test.tsx` and `buildRedirectArgs.test.ts` keep passing unmodified | §5 (re-verified by reading both files) |

---

## 8. Open questions

None left unresolved. Every judgment call ISSUE-FIXER flagged (state vs. sessionStorage
mechanism, dedup approach, restore priority, exact validation rule, route-table vs.
regex, session-expiry capture scope, UAT follow-up framing) is decided above with
stated reasoning. The one deliberately-scoped-out item is §2.5's session-expiry capture
extension — not an open question but an explicit scope boundary, with the reasoning for
staying out of scope stated in place.
