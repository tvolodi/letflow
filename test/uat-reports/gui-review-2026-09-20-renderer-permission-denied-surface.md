# GUI review — renderer-permission-denied-surface (PW-13)

Date: 2026-09-20
Reviewer: ORCH
Scenario: `test/fixtures/uat/scenarios/platform/renderer-permission-denied-surface.yaml`
Sweep position: 9th of ~15 scenarios in today's GUI-review sweep.

## Path taken

**Path 2 — feature does not exist as a real, enforcing capability. Filed and
stopped before driving any browser session.** Per this sweep's standing
instruction ("check whether this feature exists before assuming anything"),
the scenario's step 2 action — "tenant_admin removes the operations
manager's access to the shipment administration area... via gui" — was
checked against actual `lib/letflow/` and `web/src/` source before touching
`https://qa.bizdala.com`. It has no real backing today (see Finding 2
below). No live UAT run, no screenshots were taken, and no browser session
was opened, because the one action step 2–3 of the scenario depends on
cannot currently produce a different, meaningful result than "nothing
changed."

## What was verified real and correct (no defect)

**The renderer state-machine contract (REQ-362) is genuinely built and
correct:**

- `web/src/components/ui/QueryStateBoundary.tsx` maps an API response's
  HTTP status to one of six renderer states via
  `web/src/utils/classifyError.ts`. Both `401` and `403` map to the
  identical `'permission-denied'` state — a caller cannot distinguish
  "not authenticated" from "authenticated but not authorized" by watching
  the screen. This directly satisfies **EO-002**'s "same message whether
  he arrives through the application's own navigation or by typing the
  address directly" — since Letflow's SPA has no server-rendered
  alternate path, a direct URL entry and an in-app link both mount the
  same React route and hit the same API call.
- `'permission-denied'` renders `web/src/components/ui/PermissionDenied.tsx`
  — read in full, line by line: five lines, one fixed sentence ("You do not
  have access to this area. Contact your tenant administrator."), and one
  role-conditional link (`/exam` for a CANDIDATE, `/tasks` otherwise). No
  prop threads any resource content, count, ID, or internal name into this
  component. This satisfies **EO-001** (no leaked fragment/count/reference/
  internal wording) and **EO-005** (a working way back to the user's own
  task list) at the component level.
- `'loading'` renders `SkeletonLayout` with a fixed column layout supplied
  by the calling page before data resolves — satisfies **EO-004**'s
  placeholder-shape requirement, independent of this scenario's own gap.
- **EO-003** (never information + refusal together) holds structurally:
  `QueryStateBoundary`'s `switch` on `RendererState` is exhaustive
  (TypeScript `never`-checked at the `default` branch) and renders exactly
  one of the six states — there is no code path that renders `children`
  (real content) alongside `PermissionDenied` or any other non-`'success'`
  state.

None of this needed live UAT execution to confirm — it is fully
determined by reading the three files above, and no ambiguity remained
after reading `PermissionDenied.tsx` and `QueryStateBoundary.tsx` in full.

## Finding: the scenario's core action has no real backing (BLOCKER)

Traced whether "a tenant_admin revokes a signed-in business_user's access,
via GUI, with real effect" is buildable in the current codebase:

1. `Letflow.Plugs.AuthPipeline.authenticate_oidc/2` (the path every human
   actor in these scenarios uses — Keycloak login) populates
   `conn.assigns[:auth_context][:roles]` **exclusively** from
   `Letflow.Oidc.ClaimMapping.map_verified_claims/3`'s
   `resolve_roles(claims, config.roles_claim_paths)` — i.e. straight from
   the bearer JWT's own claims, re-extracted fresh every request.
2. `Letflow.Api.Authorization.evaluate_access/2` — the sole authorization
   decision point for every `/api/v1` route — takes exactly that
   claims-derived role list as its input. Nothing else feeds it.
3. `Letflow.Identity.RoleRegistry` (backing `web/src/pages/admin/UsersPage.tsx`
   / `GroupsPage.tsx`'s role/group management UI) states directly in its
   own moduledoc: *"This module has no coupling to the OIDC/claim-mapping
   pipeline."* Confirmed independently: `Letflow.Identity.provision_oidc_user/4`'s
   `attach_auth_context` call uses `identity_context.roles` (JWT-derived),
   never the DB user row's own stored role assignment.
4. `POST /users/:id/status` (REQ-073's account-deactivation endpoint) is
   likewise never consulted per-request by `AuthPipeline` — nothing reads
   `user.status` on the OIDC branch after the one-time JIT-provisioning
   check at login.

**Net conclusion:** for the normal (OIDC) login path, Letflow's own
tenant-admin GUI for managing users, roles, groups, and account status has
**zero live enforcement effect**. A tenant admin who deactivates or
role-downgrades a user through this GUI would reasonably believe access
was cut off — it was not, and never will be, regardless of how long the
user stays signed in, because `evaluate_access/2` never reads what that
GUI wrote. The only thing that actually governs an OIDC session's
permissions is the external Keycloak realm's role/group claims, and
Letflow's own `web/` app has no screen for editing those.

This is exactly the failure mode EO-001's own `on_fail.business_impact`
describes ("revoking somebody's access would stop being a reliable
control") — found one level below where EO-001 itself could even be
exercised, since there is no real "revoke" action to trigger it with.

Filed as:
- `docs/issues/ISS-0736.yaml` (BLOCKER) — the finding, with full trace.
- `docs/requirements.yaml` `REQ-378` (owner ELIXIR-DEV, stage S4) — the fix
  contract. Flagged explicitly for **SECURITY-REVIEWER** sign-off before
  merge, not just REVIEWER, since this closes a real authorization gap.

A secondary, smaller staleness note was folded into REQ-378's description
rather than filed separately: `web/src/auth/AuthProvider.tsx`'s
`accessTokenExpiring` handler updates the in-memory bearer token on silent
renew but never re-decodes `session.roles` from the renewed token — latent
today only because no client-side code currently gates navigation on
`session.roles` (`ProtectedRoute.tsx` checks only `isAuthenticated`), but
worth fixing alongside REQ-378 so a future role-gated nav feature doesn't
inherit stale client state.

## What was NOT done, and why

- No live sign-in as `actor-swiftroute-alice` / `actor-swiftroute-marco`
  against `qa.bizdala.com`, no revoke action, no screenshots. Steps 2–4 of
  the scenario depend on an admin action that cannot currently produce a
  real change in access, so driving it would only demonstrate the same
  gap already conclusively established by reading source — not add
  evidence, per this sweep's "verify before assuming" instruction.
- `web/tests/e2e/pipelines/renderer-states.pipeline.e2e.spec.ts` was **not**
  authored. Writing a regression spec for a flow that cannot yet exhibit
  real revocation would either be vacuous (asserting only the
  already-verified-correct renderer contract, which has no scenario of its
  own to anchor it) or misleading (implying the full scenario passes). It
  should be authored once REQ-378 lands, driving a real revoke action.
- The scenario's stale NOTE (ISS-0527, about this same pipeline_test file
  not existing) was **left in place** — it is still accurate: the file
  still does not exist, and the reason has shifted from "never authored"
  to "blocked on REQ-378," which is the same practical state UAT-RUNNER
  needs to keep treating as BLOCKED/UNBUILT_FEATURE.

## Verdict

BLOCKED. Renderer contract (REQ-362) verified correct — no defect there.
Root gap is a backend authorization wiring defect, not a frontend gap:
filed as ISS-0736 / REQ-378, SECURITY-REVIEWER flagged. No spec authored,
no NOTE removed, no code changed this run beyond the two documentation
filings.
