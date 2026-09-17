# 0035 — Frontend login is fully delegated to Keycloak's hosted UI

Status: decided (2026-09-17, `REVIEWER`, ISS-0701). Owner: `DOC-UPDATER` (this record and
the doc corrections it authorizes).

## Question

ISS-0701 (queue task 701, GH#1475), discovered during REQ-360's platform-login-routing UAT
work: `web/src/auth/ProtectedRoute.tsx` never renders any in-app login form. On
`!isAuthenticated` it fires a `useEffect` that calls
`getOidcManager().then(m => m.signinRedirect(buildRedirectArgs()))` — a full-page,
off-origin navigation straight to Keycloak's own hosted login page — and renders only a
`data-testid="auth-loading"` "Redirecting to login…" placeholder while that is pending.
`AuthProvider.tsx`'s session-expired handler does the identical redirect-only thing.
ISSUE-FIXER's diagnosis confirmed exhaustively that no in-app login surface exists
anywhere in `web/src`: no `LoginPage`/`LoginForm` component, no `/login` route in
`web/src/router.tsx`.

This contradicted two still-on-the-books MUST-priority items in
`docs/frontend/frontend-requirements.md`:

- **SH-01**: "The application SHALL present a login screen with a token input field when
  no valid session exists."
- **OIDC-F-01**: "The login screen SHALL display a 'Sign in with Keycloak' button
  alongside the existing token input... The developer token paste field is preserved
  unchanged."

Neither is implemented, and no decision record picked a side: `0002-oidc-integration.md`
covers only the backend token-verification library choice and says nothing about
frontend login UI. REQ-133 (S4, done) treated the redirect-only `ProtectedRoute` as an
inherited, pre-existing fact without revisiting whether it satisfies SH-01/OIDC-F-01 —
the gap was carried forward silently across the S4/S8 migration rather than decided. The
question this record settles: is an in-app login screen still wanted (build it), or is
Keycloak-hosted-only login in fact the intended architecture (correct the stale specs
instead)?

## Decision

**Keycloak-hosted-only login is the correct, working, intended production architecture.**
The SPA delegates login entirely to Keycloak's own hosted UI via a full-page redirect
(`ProtectedRoute.tsx`'s `signinRedirect`). No in-app token-paste login screen exists, and
none is planned. SH-01 and OIDC-F-01 are superseded by this record, not built out.

## Reasoning

**1. REQ-133 already tells us where the token-paste affordance went.** REQ-133's own
text states it supersedes REQ-106 ("Point `web/` at the running Letflow API using the
dev bootstrap token"), which was cancelled with the MVP-1 milestone. That is exactly the
decision point where the token-paste affordance should have been struck from
SH-01/OIDC-F-01 — instead the docs just went stale while REQ-133 shipped OIDC
(`ProtectedRoute.tsx` + Keycloak redirect) as the sole, real login path. This record
closes that gap explicitly rather than continuing to carry it as an unremarked
spec/implementation drift.

**2. The scaffolding for an in-app form is dead code, not dropped functionality.**
`AuthContext.login(token)` / `AuthProvider`'s `login` callback still exist in
`web/src/auth/AuthProvider.tsx`, but `grep -rn "\.login(" web/src` shows zero production
call sites — only `vi.fn()` mocks in unit tests — and no `/login` route exists in
`web/src/router.tsx` to reach it from. This is scaffolding that was never wired up, not a
feature that was silently removed after shipping. (Removing the dead `login()` scaffold
itself is a known, minor, non-blocking cleanup opportunity — left for a future pass, not
part of this decision.)

**3. The redirect flow is real, tested, working production behavior.** It is
E2E-proven by REQ-133 (S4, done, "End-to-end login — SPA through Keycloak to an
authorized API call") and UAT-proven by REQ-360 (S7, done) — whose own scenario,
`test/fixtures/uat/scenarios/platform/platform-login-routing-by-role.yaml`, already
correctly documents and asserts the real behavior: on the unauthenticated branch, a
redirect to the Keycloak-hosted login UI, not an in-app form. That scenario was written
to describe actual observed behavior per its own acceptance criteria (REQ-360's
"describe reality, don't paper over it" instruction), and it is the artifact this record
brings the written spec into agreement with, rather than the other way around.

**4. No functional gap for end users.** SH-01's stated purpose — "present a login screen
... on success, the user's role set is decoded ... and the workspace is rendered" — is
fully met by the Keycloak-hosted redirect flow; users reach an authenticated workspace
either way. The only thing genuinely absent is a developer-convenience affordance for
environments without Keycloak reachable, and that need is already served by
`tryRestoreE2eSession()` (`web/src/auth/AuthProvider.tsx`), not by an in-app token-paste
form.

## Consequences

- `docs/frontend/frontend-requirements.md`'s SH-01 and OIDC-F-01 rows, and
  `docs/frontend/requirements/SH-01.md`'s front matter, are marked `superseded` by this
  record (`0035`), pointing back here. Stage F1.5's "the existing login screen"/"the
  developer token paste field is preserved unchanged" framing is now historical, not
  live spec.
- REQ-360's own Why-section framing ("if unauthenticated they see the login form with
  its actual field set") is corrected in `docs/requirements.yaml` to reflect that the
  Keycloak-hosted redirect is the decided, intended target architecture — matching what
  its own UAT scenario already tests.
- ISS-0701 is closed as resolved (path: doc-correction) on the strength of this record;
  no application code changes were required or made.
- `AuthContext.login(token)`/`AuthProvider`'s dead `login()` scaffold remains in place as
  optional future cleanup — explicitly out of scope for this record and for ISS-0701's
  fix.
