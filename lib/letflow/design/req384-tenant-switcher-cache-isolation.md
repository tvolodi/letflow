# REQ-384 — In-app tenant switcher with tenant-keyed query-cache isolation

Status: design (pre-implementation). Owner: FRONTEND-DEV (per requirements.yaml),
but see §0 — this design has a real, load-bearing `lib/letflow/` component too.
queue task 744, GH-1632, stage S8. Filed from
`test/uat-reports/gui-review-2026-09-20-tenant-switch-cache-isolation.md` (EO-001),
`test/fixtures/uat/scenarios/platform/tenant-switch-cache-isolation.yaml` (PW-15).

---

## §0 — Scoping conclusion: BOTH backend and frontend work required

**This is not a frontend-only requirement.** REQ-384's own acceptance criterion 1
flags this explicitly ("no such multi-membership concept exists in
`Letflow.Identity` today ... confirm and document"). Having read
`lib/letflow/identity.ex`, `lib/letflow/identity/user.ex`,
`lib/letflow/identity/tenant.ex`, `lib/letflow/plugs/auth_pipeline.ex`, and
`docs/migration/decisions/0006-identity-tables-schema-per-tenant.md`, the gap is
real, structural, and cannot be worked around client-side:

1. **`users` rows are physically scoped to one Postgres schema per tenant**
   (Decision 0006 D1/D2 — REQ-063/064, shipped). There is no table anywhere that
   holds a "global account" a human might use across two tenants; a user in
   tenant A's schema and a user in tenant B's schema are two structurally
   unrelated rows, even for the same human, with no FK or join path between them.
2. **A JWT identifies exactly one tenant**, via a 1:1, immutable, DB-enforced
   binding: `tenants.idp_realm_id` is unique (`tenants_idp_realm_id_partial_index`),
   a `Tenant` has exactly one realm column (not a collection), and
   `Tenant.update_changeset/2` structurally cannot change it
   (`lib/letflow/identity/tenant.ex` moduledoc, "`idp_realm_id` is immutable after
   creation"). `AuthPipeline`'s 5-step OIDC chain (`lib/letflow/plugs/auth_pipeline.ex`)
   resolves tenant from the token's `iss` claim's realm and never considers a
   second tenant for the same request.
3. **Therefore "an account with membership in >1 tenant" has zero existing
   backend representation** — not a missing join row on an existing membership
   table (there is no membership table at all), and not a client-side gap
   masking real backend capability. `Letflow.Identity`'s six tenant-administration
   functions (§"Tenant administration (REQ-075)") manage `tenants` rows
   themselves, never a user↔tenant edge.

**Conclusion:** this design has two parts, both load-bearing for the acceptance
criteria: **Part A (backend, `lib/letflow/`)** adds the minimal membership
concept and a read endpoint the switcher needs; **Part B (frontend, `web/`)**
adds the switcher UI, the multi-realm silent-auth mechanism, and the tenant-keyed
cache-isolation layer. Building B without A leaves AC1 permanently unbuildable
(the requirement's own filer already reached this conclusion — see the
requirement's own description); building A without B ships a backend concept
nothing ever uses.

**Relationship to Decision 0006 — corrected: this DOES reach 0006 §3.3's
foreclosure, and is resolved by a narrow amendment, not by argument that it
misses it.** An earlier draft of this section argued Part A was merely
D3-shaped (a structurally-global public-schema table, same tier as
`tenant_schemas`) and therefore did not reopen 0006. That argument addressed
*where the table lives*, not *what capability the lookup delivers*, and does
not survive a direct re-read of 0006 §3.3, which forecloses, by name, *"a
future 'find my account by email across all tenants' login flow."*
`GET /api/v1/me/memberships` (§2.2) — a cross-tenant lookup keyed on
normalized email, not on the request's own realm — is a literal instance of
exactly that, regardless of which schema `tenant_memberships` lives in.

This is resolved, not glossed over: see
`docs/migration/decisions/0038-tenant-membership-lookup-amendment.md`, a new
decision record that amends 0006 §3.3/§7 item 3 with a narrow, four-condition
exception (non-self-service lookup derived only from the caller's own
already-authenticated identity; admin-granted linking only, never JIT/
automatic; no shared `users` row — every tenant still gets its own per-tenant
row, satisfying §3.3's own "without a per-tenant row" qualifier; realm→tenant
request resolution (0006 R5) is untouched). REQ-384's Part A design (§1-§2
below) is written to satisfy all four conditions structurally, not as a
policy promise layered on top. 0038 is itself pending REVIEWER and
SECURITY-REVIEWER sign-off, same as this design — it does not silently
resolve itself, it is filed for that gate to adjudicate. §9 and §10 OQ-1
below cross-reference it; do not re-litigate the "does this reopen 0006"
question independently of 0038 — read 0038 for the full argument.

---

## Part A — Backend (`lib/letflow/`)

### §1. Data model

#### §1.1 New table: `tenant_memberships` (public schema, global — same tier as `tenants`)

Migration: `priv/repo/migrations/<ts>_create_tenant_memberships.exs`.

| column | type | notes |
|---|---|---|
| `id` | `:binary_id`, PK, autogenerate | |
| `subject_key` | `:string`, not null | Stable cross-tenant identity key. **Chosen value: lower-cased, trimmed email** (see OQ-1 below for why this is a flagged, not silently-assumed, choice). |
| `tenant_id` | `:binary_id`, not null, `references(:tenants, type: :binary_id)` | Real FK, D3-shaped (not a schema-boundary echo — this table is not schema-isolated). |
| `display_label` | `:string`, nullable | Optional admin-supplied label shown in the switcher if set (e.g. "Acme — Ops"), falls back to the tenant's own `display_name` when nil. |
| `inserted_at` / `updated_at` | timestamps | |

Indexes: `unique_index(:tenant_memberships, [:subject_key, :tenant_id])` (idempotent
membership, mirrors `group_members`' own `[:group_id, :user_id]` unique-pair
convention), `index(:tenant_memberships, [:subject_key])` (the switcher's own
lookup path, §1.3).

This table is **admin-managed, not self-service and not OIDC-derived**. Nothing
in the JIT-provisioning or claim-mapping pipeline writes it. A `PLATFORM_ADMIN`
grants cross-tenant membership explicitly, the same trust tier REQ-075's six
tenant-administration functions already use (`Letflow.Routers.Tenants`, gated
by role check only, no tenant scoping — see `lib/letflow/identity.ex`'s own
"Tenant administration" section header comment for why that's the existing,
accepted shape for platform-wide administrative tables).

#### §1.2 New Ecto schema: `Letflow.Identity.TenantMembership`

```
@type t :: %TenantMembership{
  id: Ecto.UUID.t(),
  subject_key: String.t(),
  tenant_id: Ecto.UUID.t(),
  display_label: String.t() | nil,
  inserted_at: DateTime.t(),
  updated_at: DateTime.t()
}
```

Changeset: `create_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()` — casts
`[:subject_key, :tenant_id, :display_label]`, `validate_required([:subject_key,
:tenant_id])`, `validate_change(:subject_key, &normalize_and_validate_email/2)`
(lower-cases/trims and rejects non-email-shaped values — reuses the same "shape
check, not full RFC validation" discipline `Tenant.settings_changeset/2`
already applies to `locales`), `unique_constraint([:subject_key, :tenant_id])`.

No `update_changeset/2` — a membership is granted or revoked, never edited in
place (mirrors `add_group_member/3`/`remove_group_member/3`'s own
insert-or-delete-only shape, not update).

### §2. `Letflow.Identity` additions

#### §2.1 `list_memberships_for_subject/1`

```
@spec list_memberships_for_subject(subject_key :: String.t()) ::
        {:ok, [%{tenant: Tenant.t(), display_label: String.t() | nil}]}
```

Public-schema query (no `opts`/`:prefix` — same tier as `list_tenants/1`),
joins `TenantMembership` to `Tenant` on `tenant_id`, filtered by the
normalized `subject_key`, ordered by `Tenant.display_name` ascending. Returns
`{:ok, []}` (never an error tuple) when the subject has no memberships beyond
their own home tenant — see §2.2 for why the caller, not this function, decides
whether the home tenant is included.

#### §2.2 `Letflow.Routers.Identity` addition: `GET /api/v1/me/memberships`

New authenticated route (any authenticated user, no extra role gate — a user
reading their own membership list is not a privileged operation). Handler
shape:

1. Resolve the caller's own `email` from `conn.assigns[:auth_context]`'s
   `user_id` via `Letflow.Identity.get_user/2` (already-scoped read, existing
   function) inside the **current request's own tenant schema** (`opts[:prefix]`
   from `Letflow.Api.Context.scoped_repo_opts/1`, same convention every other
   handler on this router already uses).
2. Normalize that email the same way `TenantMembership.create_changeset/2`
   does (shared private helper — same normalization on write and read is load-
   bearing, not a style nicety: a mismatch would silently hide/duplicate
   memberships).
3. Call `list_memberships_for_subject/1`.
4. Response body: `{"memberships": [{"tenant_id": ..., "tenant_slug": ...,
   "tenant_display_name": ..., "display_label": ...}, ...]}` — **always
   includes the caller's own current tenant as one entry** (prepended by the
   handler, not stored as a membership row — a user is always a "member" of
   the tenant whose JWT authenticated this request, without needing an
   explicit `tenant_memberships` row for their own home tenant). This is what
   lets the frontend decide "is this a multi-membership user" (AC1's gating
   condition) with one call: `memberships.length > 1`.
5. Field selection is server-side only (INV-2): `tenant_id`/`slug`/
   `display_name`/`display_label` only — never `idp_realm_id` or any OIDC
   config from this endpoint. The realm/authority the frontend needs to
   silently authenticate against a target tenant is resolved through the
   **existing** `GET /api/tenant-config?slug=` bootstrap route (REQ-078/281,
   `Letflow.Routers.TenantConfig`, already unauthenticated-safe and already
   what `fetchTenantConfig()` calls) — reused, not duplicated, and it already
   returns exactly `oidc_authority`/`client_id`/`branding`, nothing more
   sensitive.

No new write route in this requirement's scope — granting/revoking a
membership (admin-managed, §1.1) is **out of scope for REQ-384's acceptance
criteria** (none of AC1-5 asks for an admin UI to manage memberships) and is
flagged as OQ-2 below rather than silently built or silently left with no way
to ever populate the table outside a manual `Repo.insert!` — REQ-384 ships the
schema, the read path, and (per OQ-2) an explicit follow-up requirement for the
write/admin path, not a silent gap.

#### §2.3 What does NOT change

`Letflow.Plugs.AuthPipeline`'s five-step OIDC chain, `verify_realm_ownership/2`,
`provision_oidc_user/4`, and every existing per-request tenant-resolution
mechanism are **unchanged by this requirement**. A request authenticated with
tenant B's JWT resolves tenant B exactly as it does today, independent of
whether the same browser tab also holds a live tenant-A session. This is
deliberate — see §4.1 for why per-request JWT scoping is *sufficient* at the
request layer and the entire rest of this design exists only because the
**client cache**, not any backend request path, is the new risk surface (this
is the AC4 answer, stated here and repeated in §4.1 for where a reviewer
skimming for it will look first).

### §3. Backend acceptance-criterion mapping

| AC | Backend element |
|---|---|
| AC1 (membership concept + in-app control, no full-page re-auth) | `tenant_memberships` table + `GET /me/memberships` supplies the "which tenants can I act as" data the switcher renders; the "no full-page re-auth" half is entirely a frontend mechanism (§5.2) — backend does nothing to enable or block it either way. |
| AC5 (SECURITY-REVIEWER sign-off) | New public-schema table + new authenticated read route touching cross-tenant metadata (tenant slugs/names, not business data) is itself a new data-access path per INV-6 — SECURITY-REVIEWER must assess INV-1 (does this leak business data — no, tenant metadata only), INV-2 (field selection — §2.2 point 5), INV-6 (this table itself). |

---

## Part B — Frontend (`web/`)

### §4. Why per-request JWT scoping is insufficient (AC4)

**Required statement, per AC4.** Today's isolation mechanism — a request-scoped
JWT whose `iss` claim resolves exactly one tenant, checked fresh on every
request by `AuthPipeline` — is sufficient for every *request* but says nothing
about a *client-side cache entry that outlives the JWT that populated it*.
`TC-ENV04-09` (`web/src/pages/instances/__tests__/InstanceBoardPage.tenant-isolation.test.tsx`)
is the existing, explicit statement of today's model: it asserts `useInstances`
is called **without** a `tenant_id` filter and that isolation is enforced
"backend-enforced only... never filtering or keying by tenant client-side."
That assertion is correct **today** only because of an unstated, structural
precondition: a tenant change is *always* currently accompanied by a full page
reload (`signinRedirect`/`signoutRedirect`, per §0.2's UAT-review trace),
which destroys `main.tsx`'s `QueryClient` instance and therefore the entire
cache, by construction. There is no code path today where two different
tenants' data can occupy the cache at the same time.

**REQ-384 removes that precondition** — its entire point is an in-app switch
with no page reload, which means, for the first time, a single `QueryClient`
instance is live across two tenants' worth of requests. Under the *current*
(un-namespaced) key shape, `queryKeys.instances.list({})` for tenant A and
`queryKeys.instances.list({})` for tenant B are **the identical array**
(`['instances', 'list', {}]`) — React Query would treat them as one cache
entry, and tenant B's screen would synchronously render tenant A's
already-cached rows (or vice versa) before any network round-trip, a leak the
backend's per-request JWT check never gets a chance to prevent because no
request was made. This is exactly EO-001's BLOCKER-severity finding.

**This requirement must not silently break `TC-ENV04-09`'s own precedent.**
That test's assertion — `useInstances` receives no `tenant_id` prop, isolation
is not client-filtered — stays **true** after this requirement lands: §6.2
below tenant-scopes the *query key*, not the *filter payload* sent to the API.
`useInstances(filters)`'s own call sites, its argument shape, and the backend
request it issues are all unchanged; only the React Query cache key that
result is stored under changes shape. `TC-ENV04-09` itself needs no edit —
restated as a fixed regression-precedent test that must still pass unmodified
(TEST-DESIGNER's job to confirm literally, not this design's to assert
untested).

### §5. Multi-realm session model

#### §5.1 Current single-session model (`web/src/auth/`)

`AuthProvider.tsx` holds one `UserSession | null` in state, sourced from one
lazily-memoized `getOidcManager()` singleton (`OidcManager.ts`'s
`_resolvedManager`, built once from `fetchTenantConfig(hostname)`). Changing
tenant today means `logout()` → `signoutRedirect()` (full navigation) → fresh
page load → `login()` against a newly-resolved manager. This model is
retained **unchanged** for a user's *first* sign-in and for a user with
exactly one membership (the majority case — no switcher renders, §6.1).

#### §5.2 New: per-tenant OIDC manager registry

New module `web/src/auth/tenantOidcRegistry.ts`. Responsibility: hold at most
one live `UserManager` instance per *tenant the switcher has resolved this
session*, keyed by tenant slug — not a single mutable singleton like today's
`_resolvedManager`.

```
type TenantOidcRegistry = Map<string /* tenant slug */, UserManager>

function getOrCreateManagerForTenant(slug: string): Promise<UserManager>
  // 1. Return the cached UserManager if the registry already holds one for `slug`.
  // 2. Otherwise: fetch that slug's TenantConfig via a NEW function,
  //    fetchTenantConfigForSlug(slug: string): Promise<TenantConfig>, and a NEW,
  //    genuinely per-slug-keyed cache -- explicitly NOT web/src/auth/tenantConfig.ts's
  //    existing fetchTenantConfig()/_cachedConfig. That existing function's
  //    _cachedConfig (tenantConfig.ts:27,53-66) is a SINGLE module-level value
  //    ("if (_cachedConfig) return _cachedConfig") that ignores its `hostname`
  //    argument once populated -- it was written for, and is only correct under,
  //    the single-live-tenant-per-tab precondition §4 describes (destroyed and
  //    rebuilt fresh on every full-page reload). Reusing it naively for the
  //    registry -- e.g. calling fetchTenantConfig() a second time for tenant B and
  //    expecting a fresh fetch -- would silently return tenant A's already-cached
  //    config for tenant B's slug, since _cachedConfig has no key at all: exactly
  //    the class of bug this whole design exists to prevent, relocated from the
  //    query cache into the auth layer, and MUST NOT happen.
  //    fetchTenantConfigForSlug(slug) therefore: (a) calls the SAME backend
  //    endpoint fetchTenantConfig() calls, GET /api/tenant-config, but always with
  //    an explicit { realm: slug } param -- never hostname/sessionStorage-derived
  //    -- and (b) stores its result in tenantOidcRegistry.ts's OWN
  //    Map<string, TenantConfig> (a sibling map to the UserManager one above, or a
  //    single map holding { config, manager } per slug -- implementer's choice,
  //    but it MUST be keyed by slug, never a single mutable variable). It does
  //    NOT read or write tenantConfig.ts's `_cachedConfig` in either direction.
  // 3. Build UserManagerSettings the same way buildOidcSettings() does today, from
  //    the per-slug config fetched in step 2, construct and cache a new
  //    UserManager under `slug` in the registry's own Map, return it.

function attemptSilentSwitch(targetSlug: string): Promise<
  { outcome: 'silent_ok'; user: OidcUser } |
  { outcome: 'interaction_required' } |
  { outcome: 'error'; reason: unknown }
>
  // Calls getOrCreateManagerForTenant(targetSlug), then that manager's own
  // signinSilent() (oidc-client-ts, iframe-based, no top-level navigation —
  // this is the concrete mechanism satisfying AC1's "without a full-page OIDC
  // re-authentication"). Classifies oidc-client-ts's own thrown error shape:
  // an `ErrorResponse` with error === 'login_required' | 'interaction_required'
  // (the upstream IdP/broker has no active session for this realm — see OQ-3)
  // maps to 'interaction_required'; anything else maps to 'error'.
```

**Fallback when silent switch is not possible (OQ-3):** if
`attemptSilentSwitch` returns `'interaction_required'`, the switcher UI
(§6.1) shows an explicit, user-initiated "Sign in to `<tenant>`" affordance
that performs a deliberate `signinRedirect()` against that tenant's manager —
still not the *automatic*, silent-loss-of-context re-authentication AC1's
wording rules out (nothing navigates without the user choosing to), but a real
navigation nonetheless. This fallback's acceptability is OQ-3, not resolved
silently — see Open Questions.

#### §5.3 `UserSession` / `AuthContext` changes

`UserSession` (`web/src/types/api.ts`) gains no new required fields — a
successful switch produces the *same shape* of session object `login()`
already builds (token/display_name/roles/tenant_slug/tenant_id/...), just
sourced from `attemptSilentSwitch`'s returned OIDC user instead of the
authorization-code-flow callback. `AuthContextValue` (`AuthContext.tsx`) gains
one new function:

```
switchTenant: (targetSlug: string) => Promise<'ok' | 'interaction_required' | 'error'>
```

Implemented in `AuthProvider.tsx`, responsibilities in order (this ordering is
the mechanism behind AC3, detailed in §7):

1. Call `attemptSilentSwitch(targetSlug)`.
2. On `'silent_ok'`: **before** calling `setSessionState` with the new
   session, synchronously clear tenant-A's cache subtree (§7.1) — the cache
   clear must complete before any component can re-render against the new
   `session.tenant_id`, or a placeholder-vs-stale-row race reopens.
3. `setToken(newToken)` (existing `api/client.ts` function, unchanged),
   `setSessionState(newSession)`.
4. Return the outcome to the caller (the switcher UI), which handles
   `'interaction_required'`/`'error'` per §5.2/§6.1.

### §6. Switcher UI

#### §6.1 New component: `web/src/auth/TenantSwitcher.tsx`

Rendered inside `AppShell.tsx` (which today, per the UAT report, has no
tenant-name display at all — this requirement adds both the display and the
control in one place, not two separate patches). Responsibility breakdown:

- **Data**: a new hook `useMemberships()` (`web/src/hooks/useMemberships.ts`),
  a thin `useQuery` wrapper over `GET /api/v1/me/memberships` (§2.2), query
  key `queryKeys.me.memberships()` (new group, §6.2 — deliberately **not**
  tenant-prefixed like every other group, since its whole purpose is to list
  tenants *other than* the active one; seeing a stale entry across a switch is
  not a cross-tenant *business-data* leak in the sense AC2/AC3 guard against,
  it is a list of tenant names/slugs the user is already authorized to see
  regardless of which one is active — flagged explicitly, not silently
  exempted, see §6.2's own note).
- **Render gate**: renders nothing (no control at all) when
  `memberships.length <= 1` — satisfies AC1's "a user whose account holds
  membership in more than one tenant sees..." implying a single-membership
  user sees no such control.
- **Interaction**: a dropdown/menu of the other memberships' `display_label ??
  tenant_display_name`. Selecting one calls `useAuth().switchTenant(slug)`
  (§5.3) and renders a transition state (§7.2) for its duration; on
  `'interaction_required'`, renders the explicit sign-in affordance from
  §5.2's fallback; on `'error'`, a plain-language retry message, current
  tenant's session left untouched (a failed switch must not leave the user
  logged into neither tenant — `switchTenant`'s cache-clear step 2 only runs
  after a *successful* `attemptSilentSwitch`, so an error/interaction-required
  outcome never touches tenant-A's cache or session at all).

### §7. Cache isolation and switch-transition guarantee (AC2, AC3)

#### §7.1 Tenant-prefixed query keys

`web/src/api/queryKeys.ts`'s structure changes from static per-group key
builders to **tenant-parameterized** ones. Every group whose data is
tenant-scoped business data gets the active tenant id as the **first** key
segment (React Query matches/invalidates by key-array prefix, so the tenant
id must lead, not trail, for a single `removeQueries` call to address exactly
one tenant's whole subtree):

```
// Before: queryKeys.instances.list(filters) => ['instances', 'list', filters]
// After:  queryKeys.instances.list(tenantId, filters) => ['tenant', tenantId, 'instances', 'list', filters]
```

Groups reclassified as **tenant-scoped** (gain the `['tenant', tenantId, ...]`
prefix — at minimum the three AC2 names, extended to every group backed by a
per-tenant-schema or per-tenant-filtered table): `instances`, `definitions`,
`tasks`, `promotions`, `admin.audit`, `admin.groups`, `admin.groupMembers`,
`admin.users`, `admin.userDetail`, `admin.roles`, `admin.tokens`,
`admin.services`, `dlq`, `webhooks`, `entities`, `modules`, `help`, `exam`,
`platformMigrations`, `solutionPackUpdate`, `eventRetention`. Reasoning: every
one of these reads data from a per-tenant-schema table (`:prefix`-scoped on
the backend, INV-1) or a per-tenant-filtered admin view — the exact class of
data EO-001 is about. `promotions` (`queryKeys.promotions.context(reviewId)`,
consumed by `usePromotionContext`/`useApprovePromotion`/`useRejectPromotion`
in `web/src/hooks/usePromotions.ts`) belongs in this list, not the exempt
list below: it is backed by `lib/letflow/definitions/promotion_review_store.ex`,
whose moduledoc states `opts[:prefix]` is mandatory on every function
(`Keyword.fetch!/2`'d, no default) — `promotion_reviews` is one of Decision
0006 D2's eight schema-isolated business tables, so an un-prefixed
`promotions` query key has exactly the same cross-tenant collision shape as
`instances`/`tasks`/`definitions` under an in-app switch.

Groups that stay **tenant-independent** (no prefix change): `admin.tenants`/
`admin.tenantDetail` (the public-schema `tenants` list itself — platform-wide,
`PLATFORM_ADMIN`-gated, not a "this tenant's business data" concept),
`onboarding` (pre-authentication), `admin.health`/`admin.metrics`
(`queryKeys.admin.health()`/`.metrics()`) — **deliberately excluded, stated
explicitly rather than left as a silent omission**: these back pure
infrastructure-liveness/Prometheus-exposition endpoints (process up/down,
scrape counters) with no tenant dimension in their response shape at all —
there is no "tenant A's health" vs "tenant B's health" for a cache entry to
conflate, so tenant-prefixing them would add a partition key to data that
carries none — and the new `me.memberships` (§6.1's note — deliberately
exempt, since it is the list a user consults *in order to* switch, not data
scoped to whichever tenant happens to be active).

#### §7.2 `useTenantScopedQueryKeys()` — closing the "forgot to pass tenantId" hole

Requiring every one of ~20 call sites to remember to thread `tenantId` into
every `queryKeys.*` call is exactly the kind of thing one call site forgets.
New hook, `web/src/api/useTenantScopedQueryKeys.ts`:

```
function useTenantScopedQueryKeys(): typeof queryKeys
  // Reads the active tenant id from useAuth().session.tenant_id (throws if
  // session is null -- this hook is only ever called from authenticated
  // screens, same precondition every data hook already has via ProtectedRoute).
  // Returns an object with the SAME shape/call signature every existing call
  // site already uses (queryKeys.instances.list(filters), no tenantId
  // parameter at the call site) by partially applying the active tenant id
  // inside each builder function -- the tenant-scoping becomes structurally
  // unavoidable (there is no code path to build a tenant-scoped key without
  // going through this hook and therefore without a resolved active tenant),
  // rather than a convention every hook author must remember.
```

Every existing data hook (`useInstances`, `useTasks`, `useDefinitions`, the
admin hooks, etc.) switches its internal `queryKeys.foo.bar(...)` call to
`useTenantScopedQueryKeys().foo.bar(...)` — a mechanical, per-hook change
(ELIXIR-DEV/FRONTEND-DEV implementation detail, not itself part of this
design beyond stating the mechanism and which hooks are in scope, §"AC
mapping" below).

#### §7.3 Switch-transition sequencing (AC3 — no stale row, not even mid-transition)

Three coordinated mechanisms, all required together — any one alone is
insufficient:

1. **Remove, not invalidate, on switch.** `AuthProvider.switchTenant`'s step 2
   (§5.3) calls `queryClient.cancelQueries()` (abort in-flight tenant-A
   fetches so a slow response can't land after the switch and repopulate a
   tenant-A-keyed entry) then `queryClient.removeQueries({ queryKey: ['tenant',
   oldTenantId] })` — a single call removes the entire prefix-matched subtree
   for the outgoing tenant, per §7.1's key shape. `removeQueries` (delete),
   not `invalidateQueries` (mark stale, keep serving synchronously while
   refetching) is the required choice: `invalidateQueries` alone would still
   let a component synchronously render tenant A's last-known rows for one
   frame while the background refetch is in flight — exactly the "stale row
   in a placeholder frame" EO-001/AC3 forbids.
2. **Remount, not re-render, the authenticated shell.** The top-level
   authenticated route tree (wherever `AppShell`/`ProtectedRoute`'s children
   are mounted, e.g. in `web/src/App.tsx` or the router's own root element)
   is given `key={session?.tenant_id ?? 'anonymous'}`. React's own semantics
   for a changed `key` are a full unmount-then-remount of that subtree — this
   is a structural guarantee, not a cache-hygiene one: any component holding
   tenant-A-derived local state (a `useState` initialized from tenant-A props,
   a derived `useMemo`, an uncontrolled form) cannot carry that state across
   the switch, because the component instance itself does not survive the
   switch. This directly targets AC3's "no stale row... at any point," since
   §7.1/§7.3.1 alone cover the *query cache* but not component-local state a
   screen might have derived from an earlier tenant-A response.
3. **A dedicated transition placeholder, not the outgoing screen.** Between
   step 1's cache-clear and the remount settling on real data, the app shows
   a dedicated `TenantSwitchTransitionScreen` (a loading/placeholder state,
   not a route change to some default screen that might itself have stale
   cache) — driven by `switchTenant`'s own in-flight promise, not a
   heuristic like "isFetching". This is what AC3 explicitly calls out as
   needing to be "a placeholder, not tenant A's last-rendered rows."

### §8. Frontend acceptance-criterion mapping

| AC | Frontend element(s) |
|---|---|
| AC1 | `TenantSwitcher.tsx` (§6.1) render-gated on `useMemberships()`; `switchTenant`/`attemptSilentSwitch` (§5.2-5.3) for the no-full-page-reauth mechanism. |
| AC2 | Tenant-prefixed `queryKeys` (§7.1) + `useTenantScopedQueryKeys()` (§7.2) applied to `instances`/`tasks`/`definitions` (named explicitly in the AC) and every other tenant-scoped group. Test: a harness that renders with tenant A active, populates cache, switches to tenant B, asserts tenant A's keyed entries are gone (not merely stale) and a tenant-B-keyed fetch was issued — TEST-DESIGNER's job, this design specifies the mechanism the test exercises. |
| AC3 | §7.3's three mechanisms together (remove-not-invalidate, shell remount via `key`, dedicated transition screen). |
| AC4 | §4 (this design doc's own explicit statement — the acceptance criterion is about the design doc's content, satisfied by §4 existing and citing `TC-ENV04-09` by name, which it does). |
| AC5 | Flagged in this doc's header and §0/§3 — SECURITY-REVIEWER must review both the new `GET /me/memberships` backend path (INV-1/INV-2/INV-6) and the frontend cache-isolation mechanism (a client-side isolation layer is new territory for this codebase's SECURITY-REVIEWER checklist — no existing invariant in `security-invariants.md` names client-cache isolation explicitly; flagged as OQ-4). |

---

## §9. Invariants this design must not violate

- **INV-1 (tenant data isolation)** — unaffected at the request layer (§2.3);
  extended, not replaced, at the client-cache layer by §7.
- **INV-2 (server-side field authorisation)** — `GET /me/memberships`'s
  response fields are server-selected (§2.2 point 5); the frontend never
  receives `idp_realm_id` or OIDC secrets through this path.
- **`TC-ENV04-09`'s precedent** — stays true unmodified after this lands (§4,
  last paragraph): `useInstances`/`useTasks`/`useDefinitions` still receive no
  `tenant_id` filter argument; only the *query key* the result is stored
  under changes.
- **Decision 0006** — Part A's `GET /me/memberships` lookup does reach
  0006 §3.3's foreclosure (a cross-tenant, email-keyed lookup); this is
  resolved by a narrow, four-condition amendment,
  `docs/migration/decisions/0038-tenant-membership-lookup-amendment.md`, not
  by an argument that Part A misses the foreclosure (§0). 0038 is pending
  REVIEWER/SECURITY-REVIEWER sign-off alongside this design.

---

## §10. Open questions (explicitly unresolved — not silently decided)

**OQ-1 — `subject_key` = normalized email is a real, named limitation.**
Two humans who happen to share an email string across two tenants' separate
`users` rows (a shared service mailbox, a typo, an unrelated coincidence)
would be treated as the same switchable identity if a `PLATFORM_ADMIN` ever
granted a membership keyed on that email. Mitigated by membership being
admin-granted (not self-service, not automatic) — an admin choosing to link
tenant A and tenant B by email is an explicit, auditable act, not a passive
default. No stronger cross-tenant identity key exists in this codebase today
(OIDC `sub` is per-realm and not guaranteed stable/comparable across two
tenants' potentially-different realms/IdPs). REVIEWER should confirm this
tradeoff is acceptable for REQ-384's scope or require a stronger key (e.g. a
platform-issued opaque account id, which would be new scope beyond this
requirement).

**OQ-2 — no admin UI/route to create or revoke a `tenant_memberships` row.**
This design ships the table, the read path, and the switcher, but the only
way to populate the table is a direct `Repo.insert!` (or a future
requirement's admin route). Flagged rather than silently built (an admin
CRUD surface was not asked for by any of REQ-384's five acceptance criteria)
or silently left unaddressed. Recommend a follow-up requirement,
`PLATFORM_ADMIN`-gated, mirroring `add_group_member/3`'s existing shape.

**OQ-3 — silent cross-realm auth depends on infra this design doesn't
control.** `attemptSilentSwitch`'s `signinSilent()` mechanism (§5.2) only
succeeds without user interaction if the target realm's Keycloak/IdP already
has an active browser session reachable from the silent iframe — true if
tenant realms are federated to a shared upstream IdP with a shared SSO
session, **not necessarily true** for two independently-configured realms
with no federation between them (Keycloak realms do not share SSO cookies by
default). This design's §5.2 fallback (explicit "sign in to switch" on
`interaction_required`) is what keeps AC1 satisfiable regardless of which
infra state holds, but whether that fallback is acceptable UX/product
behavior, or whether realm federation must be a deployment prerequisite for
this feature, is not resolved here — flagged for REVIEWER and, if federation
is required, a separate ops/infra decision record.

**OQ-4 — `security-invariants.md` has no invariant naming client-side cache
isolation.** INV-1 through INV-9 (INV-9, tenant-controlled outbound URL
validation, REQ-204, already shipped — `security-invariants.md` line 264)
are all about server-side/request-layer enforcement, secret handling, or
outbound-request validation; none names "a client-side cache that can hold
more than one tenant's data in the same browser tab" as a boundary. This
requirement's AC5 treats this as security-relevant regardless, and this
design agrees (§4's whole argument is why), but recommends SECURITY-REVIEWER
consider whether a new **INV-10** belongs in that file once this pattern
exists, rather than this one requirement being the only place the reasoning
lives.
