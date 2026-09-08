# Design: ISS-0531 — `resolveTenantSlug/1` mis-resolves the pinned default tenant

- **Issue:** ISS-0531 (related: ISS-0296, ISS-0529)
- **Requirements:** REQ-133 (frontend OIDC/tenant realm routing), REQ-019 (default-tenant
  pinning invariant)
- **Files touched by this design:** `web/src/auth/tokenUtils.ts` (implementation),
  `web/src/auth/__tests__/tokenUtils.test.ts` (tests)
- **Owner for implementation:** FRONTEND-DEV
- **Source diagnosis:** `handoffs/WF03-ISS0531-20260908/step-01-issue-fixer-diagnosis.json`
  (ISSUE-FIXER, option (a) selected)

## 1. Problem statement

`resolveTenantSlug/1` in `web/src/auth/tokenUtils.ts` (current lines 26–42) derives a
tenant slug from the JWT's `iss` claim by extracting the Keycloak realm segment and
unconditionally stripping a `bpm-` prefix:

```ts
return realm.startsWith('bpm-') ? realm.slice(4) : realm
```

This is correct for every *ordinary* tenant — `docs/frontend/frontend-requirements.md:205`
documents the convention `realm = "bpm-" + slug` (e.g. slug `acme1` ⇄ realm `bpm-acme1`,
tenant-config example: `GET /api/tenant-config?host=acme1.localhost` → `oidc_authority`
ending `/realms/bpm-acme1`).

It is wrong for exactly one realm: the seeded default tenant. `lib/letflow/identity/tenant.ex`
defines `@default_tenant_slug "bpm-default"` (line 73) and `validate_default_tenant_pinning/1`
(lines 147–159) enforces, as a changeset invariant, that when `slug == "bpm-default"`,
`idp_realm_id` must equal `"bpm-default"` **exactly** — not `"bpm-" <> "bpm-default"` and not
some other derived value. In other words, for this one tenant, `slug == realm` verbatim; the
`"bpm-" + slug` convention does not apply to it because its slug already happens to start
with `bpm-`.

Feeding realm `bpm-default` through the ordinary stripping rule yields slug `default`
(`"bpm-default".slice(4)`), which does not match any real tenant's `slug` column
(`bpm-default` is the actual value in `tenants.slug` for the seeded row per `tenant.ex`).
`AuthProvider.tsx`'s `login/1` (lines 93–103) then calls `tenantsApi.getBySlug('default')`,
which 404s; the `catch` swallows the error and `tenantDisplayName` stays `null`, surfacing as
"Unknown workspace" in the UI for every user authenticating against the default realm.

## 2. Corrected contract for `resolveTenantSlug/1`

**Signature (unchanged):**

```ts
export function resolveTenantSlug(payload: JwtPayload): string | null
```

**Behavior (revised):**

1. If `payload.tenant_id` is present, return it unchanged (unchanged — highest-priority
   branch, not affected by this fix).
2. Otherwise, if `payload.iss` is present and parses as a URL whose path contains a
   `realms/<realm>` segment, extract `<realm>` as before. Then:
   - **If `<realm>` is exactly the literal string `"bpm-default"`, return it verbatim —
     do not strip anything.** This is the pinned default-tenant case.
   - **Otherwise, if `<realm>` starts with the prefix `"bpm-"`, strip the 4-character
     prefix and return the remainder** (existing behavior, unchanged, now reached only
     for non-default realms).
   - **Otherwise** (realm present but doesn't start with `bpm-` at all — an already-bare
     slug, or a malformed/unexpected realm name), return the realm unchanged, exactly as
     today's `else` branch does. This path is not touched by this fix.
3. If `iss` is absent, malformed, or has no `realms/<realm>` segment, return `null`
   (unchanged).

Decision table for the realm-to-slug mapping (replaces the current unconditional strip
at today's lines 26–42; the two unchanged branches — `tenant_id` present, and no
`realms/<realm>` segment found — are omitted from this table since they are untouched):

| Extracted `<realm>` value | Returned slug |
|---|---|
| Exactly `"bpm-default"` | `"bpm-default"` (returned verbatim, unstripped) |
| Starts with `"bpm-"` but is not exactly `"bpm-default"` | `<realm>` with the leading 4-character `"bpm-"` prefix removed |
| Does not start with `"bpm-"` | `<realm>` unchanged |

The exact-match check against the literal reserved value must be evaluated before the
prefix-strip check, since `"bpm-default"` would otherwise also satisfy "starts with
`bpm-`".

The `tenant_id`-claim branch (step 1) and the URL-parsing/`try`/`catch` structure (the
outer shape of the function) are unchanged — only the realm-to-slug mapping inside the
`realmsIdx !== -1` branch changes.

## 3. Why hardcode the literal `"bpm-default"` rather than a pattern rule

Two candidate approaches were weighed:

**(A) Hardcode the literal reserved realm name `"bpm-default"`.** Selected.

- It mirrors `tenant.ex`'s own approach exactly: `@default_tenant_slug "bpm-default"` is
  itself a hardcoded module attribute, not derived from a pattern. The frontend fix is
  structurally the same kind of special case the backend already encodes, just
  duplicated client-side.
- It is unambiguous and cannot misfire: there is exactly one reserved value to match,
  and matching it by exact string equality cannot accidentally over-generalize to some
  other realm.

**(B) A pattern-based rule that avoids hardcoding** (e.g., "if stripping the prefix
would produce a slug that itself starts with `bpm-`, don't strip" — i.e., treat
`bpm-bpm-*`-shaped strips as a signal to not double-apply). This was considered and
rejected:

- It happens to work for `bpm-default` only by the coincidence that `default` doesn't
  start with `bpm-` (so this heuristic wouldn't even fire — it solves a different,
  hypothetical problem, not this one). There is no pattern-based rule that
  distinguishes "realm `bpm-default` should map to slug `bpm-default`" from "realm
  `bpm-acme1` should map to slug `acme1`" using only the string's shape — the two cases
  are shaped identically (`bpm-` + alphanumeric suffix). The only fact that
  distinguishes them is the pinning invariant itself, which is not recoverable from the
  string alone.
- Any rule general enough to catch `bpm-default` without a literal comparison would
  necessarily also need to explain why it doesn't fire for a hypothetical future tenant
  literally named `default` (slug `default`, realm `bpm-default` under the *ordinary*
  convention) — but per `tenant.ex`, no such tenant can ever exist: `bpm-default` is
  permanently reserved as the one pinned slug, and the ordinary `"bpm-" + slug`
  convention could never legitimately produce realm `bpm-default` for a different
  tenant's slug `default`, because a tenant literally slugged `default` isn't the
  seeded row and would collide with the pinning invariant's reserved value at the
  database level (`tenants.slug` unique constraint would prevent a second `bpm-default`
  row; a tenant slugged plain `default` would produce realm `bpm-default` too under the
  ordinary rule, which is exactly the ambiguity — but this scenario requires a
  *different* tenant with slug `default`, and REQ-019 don't currently forbid a tenant
  slugged `default`; this is flagged in §5 as an open question, not silently resolved).
- No pattern rule is materially simpler or more robust than an exact-string comparison
  against the one documented reserved value. Hardcoding is simplest and matches the
  backend's own style.

## 4. Frontend-only hardcode vs. backend-signaled field — tradeoff

Considered: instead of hardcoding `"bpm-default"` client-side, have the backend send an
explicit signal (e.g., a `tenant_id` claim minted into the JWT itself, or exposing slug
resolution via an API field) so the frontend never needs realm-string knowledge at all.

**Recommendation: frontend-only hardcoded fix, per ISSUE-FIXER's scope constraint** —
explicitly noting the tradeoff rather than silently accepting it:

- ISSUE-FIXER's diagnosis already evaluated and rejected the "mint a `tenant_id` JWT
  claim" route (option (b)) as infeasible within this issue's scope: it requires a new
  Keycloak protocol mapper per realm, and `contract-gaps.md:51-70` already documents an
  existing, unresolved out-of-band mapper-drift gap from a *previous* manual mapper
  addition — adding another per-realm mapper repeats that same unresolved provisioning
  problem rather than fixing it. This is a multi-file, multi-role, backend+Keycloak lift,
  not a targeted bug fix.
- The `tenant_id` claim branch already exists in `resolveTenantSlug/1` (step 1, checked
  first) as the intended long-term path — this design does not remove or discourage it.
  Once REQ-133/OIDC-F work eventually mints that claim for every realm (including
  `bpm-default`), the hardcoded fallback in step 2 becomes dead code for tenants that
  have the claim, and only continues to matter for realms/tokens without it. This design
  does not implement that broader change; it only fixes the immediate fallback bug.
- **Known tradeoff, stated explicitly:** hardcoding `"bpm-default"` in `tokenUtils.ts`
  creates a duplicated literal that must be kept in sync with `tenant.ex`'s
  `@default_tenant_slug "bpm-default"`. If a future change ever altered the pinned
  default realm value on the backend (itself flagged as a decision-record-level change,
  not a casual edit — see `tenant.ex`'s moduledoc and REQ-019's design doc), this
  frontend literal would silently go stale and reintroduce the same bug via drift rather
  than a first-time bug. This is accepted as the smallest correct fix for this issue's
  scope, per ISSUE-FIXER's own constraint against a bigger backend lift; it is not
  silently ignored — it is called out here so TEST-DESIGNER/REVIEWER can decide whether
  a follow-up requirement (e.g., a shared constant sourced from the tenant-config
  endpoint, or a comment linking the two files) is warranted. This design does not
  invent such a follow-up itself.

## 5. Open questions (explicitly listed, not resolved here)

- **OQ-1:** Is a tenant literally slugged `default` (as opposed to the reserved
  `bpm-default`) permitted to exist under REQ-019's current validations? If so, its
  ordinary-convention realm `bpm-default` would collide with the reserved value discussed
  in §3, and `resolveTenantSlug` could not distinguish the two by realm string alone
  (both would present realm `bpm-default`). This is a data-model question outside this
  design's scope — flagged for REVIEWER/backend, not resolved here.
- **OQ-2:** No code comment currently exists in `tokenUtils.ts` cross-referencing
  `tenant.ex`'s `@default_tenant_slug` to explain *why* `"bpm-default"` is hardcoded.
  FRONTEND-DEV should add one (see §6) so a future reader doesn't mistake it for an
  arbitrary magic string.

## 6. Implementation notes for FRONTEND-DEV (non-binding detail, not code)

- Add a code comment at the hardcoded-check site naming `tenant.ex`'s
  `@default_tenant_slug` and `validate_default_tenant_pinning/1` as the source of truth
  for why `"bpm-default"` is special, so the duplication in §4's tradeoff is at least
  discoverable by a future reader/grep, even though it isn't automatically enforced.
  This may be a plain constant (e.g. `bpm-default` used inline with a comment, or a
  named constant like `DEFAULT_TENANT_REALM`) — implementation detail left to
  FRONTEND-DEV.
- Update `resolveTenantSlug/1`'s existing JSDoc comment (lines 21–25) to document the
  default-tenant special case, so the function's documented contract matches its
  behavior.

## 7. Required test cases

Add to `web/src/auth/__tests__/tokenUtils.test.ts` (new `describe('resolveTenantSlug', ...)`
block — currently `resolveTenantSlug` is not imported/tested in this file at all; add it
to the existing import line). Follow the existing `makeTestJwt`/`JwtPayload`-shaped
fixture style already used in this file for `iss`-bearing payloads (a payload with an
`iss` field shaped as a Keycloak issuer URL, e.g.
`http://localhost:8082/realms/<realm>`).

Minimum required cases:

1. **Default-tenant realm resolves to `bpm-default` verbatim (regression test for
   ISS-0531 — the bug this design fixes):** given a JWT payload whose `iss` is
   `http://localhost:8082/realms/bpm-default` (no `tenant_id` claim), `resolveTenantSlug`
   returns `"bpm-default"`, not `"default"`.
2. **Ordinary tenant realm still strips the prefix correctly (regression test proving
   the fix doesn't break the general case):** given a JWT payload whose `iss` is
   `http://localhost:8081/realms/bpm-acme1` (no `tenant_id` claim), `resolveTenantSlug`
   returns `"acme1"`.
3. **`tenant_id` claim still takes priority over realm parsing (regression test for the
   unchanged branch):** given a payload with both `tenant_id: "explicit-slug"` and an
   `iss` realm of `bpm-default` (or any realm), `resolveTenantSlug` returns
   `"explicit-slug"`, proving step 1 of §2 is untouched by this fix.
4. **No `iss` and no `tenant_id` still returns `null`** (existing behavior, regression
   guard): given a payload with neither field, `resolveTenantSlug` returns `null`.

Test IDs should follow this file's existing `TC-<component>-<kind><NN>` convention
(e.g. `TC-SH0X-U0N` — TEST-DESIGNER/FRONTEND-DEV to assign the next free component code
consistent with this file's other blocks, since `resolveTenantSlug` has no prior test ID
allocated).

## 8. Acceptance-criteria mapping

| Acceptance criterion (from task) | Design element |
|---|---|
| `resolveTenantSlug` on realm `bpm-default` returns `bpm-default`, not `default` | §2 step 2 special case; §7 test case 1 |
| Ordinary realm `bpm-acme1` still returns `acme1` | §2 step 2 fallback branch (unchanged logic); §7 test case 2 |
| Exact mechanism for distinguishing the two cases specified | §2 (exact-match literal check before prefix-strip), §3 (rationale for literal vs. pattern) |
| Frontend-only vs. backend-signaled approach weighed against ISSUE-FIXER's scope constraint | §4 |
| Known tradeoff of hardcoding stated explicitly, not silently ignored | §4 final bullet |
