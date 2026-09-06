# REQ-137 — Per-tenant realm provisioning: design and sized implementation plan

**Requirement:** REQ-137 (`docs/requirements.yaml`, `owner: CODE-DESIGNER`)
**Kind of artefact:** design + sized implementation plan. No implementation code.
**Builds on:** `lib/letflow/design/req135-keycloak-provider-port-boundary.md` (the
PORT/DROP table for R-Co's `src/identity/provider/`) — cited by path throughout, not
re-derived.

---

## 0. Sources read for this design

- `lib/letflow/design/req135-keycloak-provider-port-boundary.md` (full) — the PORT/DROP
  table, §5's Elixir `@behaviour`-pair decision, §4's ~1,200-line estimate for the *full*
  13-admin-operation surface.
- `lib/letflow/design/req128-keycloak-dev-stack.md` (full, incl. both post-validation
  correction notes) — confirms the dev-stack realm is a single static, pre-imported realm
  (`bpm-default`), not a dynamically-provisioned one; confirms `Oidcc.Token.validate_jwt/3`
  requires an audience mapper (ISS-0275) — noted for the realm-import JSON shape a
  programmatically-created realm's client will also need, though this design does not
  build a realm-import-JSON path (Admin REST API create, not import).
- `lib/letflow/design/req019-tenant-realm-binding.md` (full) — `Tenant.idp_realm_id`'s
  exact semantics: immutable after creation (structurally omitted from
  `update_changeset/2`), no rotation function exists or is planned, conditionally
  required at creation only when `oidc_mode == :enabled`, default tenant pinned to
  `"bpm-default"`. This is the load-bearing constraint this design's §3 chicken-and-egg
  resolution depends on.
- `lib/letflow/design/req063-identity-tables-schema-per-tenant.md` §5b — the
  `opts :: [prefix: String.t()]` convention this design does *not* need (realm
  provisioning has no tenant-schema `:prefix` concept — Keycloak realms are not Postgres
  schemas), cited only to confirm this design correctly does *not* import that pattern.
- `lib/letflow/tenant_provisioning.ex` (full, incl. moduledoc) — confirmed
  `provision_tenant_schema/1`/`replay_migrations/2` remain "two separate, composable
  primitives — neither calls the other" (REQ-022 §3.2's invariant), confirmed the
  ISS-0230 finding ("a compensating rollback is deliberately not the answer... trading a
  recoverable partial state for an unrecoverable orphan"), confirmed
  `Registration.migrations_applied_at IS NULL` as the shipped half-provisioning detection
  predicate.
- `lib/letflow/tenant_onboarding.ex` (full) — **REQ-076 has already shipped**
  (`docs/requirements.yaml` REQ-076: `status: done` — the requirement text handed to this
  design step calling it "still pending" predates that merge; this design uses the real,
  shipped module, not a speculative one). `Letflow.TenantOnboarding.provision_and_migrate/1`
  is the *existing* explicit orchestration layer REQ-076 built specifically to sequence
  `TenantProvisioning`'s two primitives (its own moduledoc: "this module is the
  caller-side orchestration that invariant always expected to exist"). Confirmed
  idempotent, confirmed no compensating rollback, confirmed it flips `tenant.status`
  `:migrating -> :active` on success.
- `lib/letflow/routers/onboarding.ex` (full) — confirmed `handle_create/1`'s real
  `create_attrs` (`slug`, `display_name`, `status: "migrating"` — **no `idp_realm_id`, no
  `oidc_mode`**) and confirmed `Identity.create_tenant/1` hard-codes `oidc_mode: :disabled`
  (`lib/letflow/identity.ex:599`) — i.e., **onboarded tenants today never get an
  `idp_realm_id`**. This is the concrete gap §3 below closes.
- `docs/migration/decisions/` — grepped for "no implicit chaining"; the only source is
  `lib/letflow/design/req022-tenant-schema-provisioning.md`'s own §3.2 (not a numbered
  `decisions/NNNN-*.md` file), read in full there. Its 2026-08-22 addendum (ISS-0230) is
  the direct precedent this design's §5 partial-failure reasoning extends.
- `lib/letflow/identity.ex` (`create_tenant/1`, `create_onboarding/1` — read directly,
  lines 596-612 and surrounding).
PROVENANCE (historical, not current decision authority):
- R-Co `src/api/routes/onboarding.zig` — grepped for `realm_guard`/`RealmExists`/
  `checkRealmExists`; confirmed the pattern this design's §5 idempotent-creation guard
  ports the *intent* of (query Keycloak for realm existence before creating, not a local
  flag) without porting `onboarding.zig`'s saga/compensating-delete machinery itself
  (REQ-076 §8.5 already declined that saga shape for the whole onboarding flow; this
  design stays consistent with that declination rather than reintroducing it for one
  sub-step).

---

## 1. Scope

PROVENANCE (historical, not current decision authority):
This design covers **realm creation only** — the Keycloak Admin REST API operation that
creates an empty realm for a tenant and the guard/retry semantics around it. It does
**not** design user provisioning, client provisioning, role/federation/audit-event
provisioning, or protocol-mapper management inside a realm — those are five of
REQ-135's PORT-verdict rows (`interface.zig`, `types.zig`, `provider.zig`) that remain
unbuilt after this design's implementation plan (§8) ships; REQ-135 §4's ~1,200-line
estimate covers the *full* 13-operation admin surface, and this design deliberately scopes
its own implementation plan down to the realm-only subset (§8's totals are smaller than
1,200 for exactly this reason, stated there, not silently).

---

## 2. Happy path — how a realm gets created for a tenant

### 2.1 Where the realm name comes from (closes a real gap, not assumed away)

`Tenant.idp_realm_id` (REQ-019, §0) is **immutable after creation** and has **no rotation
function** — `update_changeset/2` structurally omits it, and REQ-019's design explicitly
declined to add one. Realm creation therefore cannot follow a "create the tenant row,
then create the realm, then write the realm name back onto the row" sequence — there is
no code path that can perform that write-back today, and REQ-019 deliberately decided not
to build one.

**Decision: the realm name is decided and committed to `tenant.idp_realm_id` at
tenant-creation time, before any Keycloak call — realm creation is then a call that
*matches* an already-committed value, never one that produces a new value to be written
back.** Concretely, `idp_realm_id` is set to the tenant's own `slug` — the same convention
REQ-019 §4 already established for the default tenant (`slug == idp_realm_id ==
"bpm-default"`), generalized to every tenant rather than special-cased to one. This needs
one small, explicit change to the **existing, shipped** onboarding create path (named as
its own implementation-plan entry, §8 item 4 — not built by this design):
`Letflow.Routers.Onboarding.handle_create/1`'s `create_attrs` gains
`"idp_realm_id" => slug`, and its call to tenant creation must pass `oidc_mode: :enabled`
instead of today's hard-coded `:disabled` (`Letflow.Identity.create_tenant/1`,
`identity.ex:599`, currently has no parameter to vary this — also part of §8 item 4).

**Consequence:** by the time any realm-provisioning code runs, `tenant.idp_realm_id` is
already a committed, non-nil, immutable value. Realm creation's job is narrow: "does a
Keycloak realm named `tenant.idp_realm_id` exist — if not, create it." This is what makes
the operation naturally idempotent (§2.3) and is the mechanism that ports the *intent* of
R-Co's `realm_guard` (a live existence check before creating) without R-Co's saga
machinery.

### 2.2 What Letflow already has to build on (cites REQ-135 by path, not re-derived)

PROVENANCE (historical, not current decision authority):
Per `lib/letflow/design/req135-keycloak-provider-port-boundary.md` §5: the target shape is
an Elixir `@behaviour` + implementation-module pair, matching the already-shipped
`Letflow.Oidc.TokenVerifier` precedent — not R-Co's `interface.zig` vtable-of-fn-pointers
shape. Per that same design's §2 table, `config.zig` (row 1, PORT), `provider.zig` (row 2,
PORT — this design uses only its realm-admin-operation subset, §8), `urls.zig` (row 3,
PORT), and `interface.zig`/`types.zig` (rows 8/14, PORT) are the R-Co files this design's
implementation plan (§8) ports from. `adapters/stub/provider.zig` (row 4, DROP) and
`bootstrap.zig` (row 5, DROP) are **not** ported, per REQ-135's own reasoning (REQ-128
already gives the test suite a real Keycloak instance; config is compile-time
`Application` config, not runtime env-var bootstrap).

### 2.3 The realm-creation primitive itself

New context module `Letflow.Identity.RealmProvisioning` (sibling to
`Letflow.TenantProvisioning`, same "top-level context module in `lib/letflow/`" placement
convention):

```
@spec create_tenant_realm(tenant_id :: Ecto.UUID.t()) ::
        {:ok, :created | :already_exists}
        | {:error, :tenant_not_found}
        | {:error, :missing_realm_binding}
        | {:error, {:provider_error, term()}}
```

Behavior, in order:

1. `Repo.get(Tenant, tenant_id)` → `nil` → `{:error, :tenant_not_found}`.
2. `tenant.idp_realm_id` is `nil` → `{:error, :missing_realm_binding}`. This is the
   explicit, non-silent signal for "this tenant was created with `oidc_mode: :disabled`
   (or predates this requirement) — there is nothing for this function to create a realm
   *named*." Callers that know a tenant is OIDC-disabled should not call this function at
   all (§4); a caller that does call it anyway gets a typed error, never a crash or a
   realm named `nil`/`""`.
3. Otherwise: `provider_admin_impl().realm_exists?(tenant.idp_realm_id)` (configured
   `@behaviour` implementation, §2.4 below — resolved once via `Application.get_env`, same
   idiom `Letflow.Oidc.TokenVerifier`'s own configured-implementation call site uses).
   - `{:ok, true}` → `{:ok, :already_exists}`. **This is the realm-existence guard** — the
     one mechanism this design ports from R-Co's `realm_guard` intent (§0): a live check
     against Keycloak itself, not a local flag, run on *every* call, so a retry after any
     failure (this function's own, or a sibling step's) always re-derives the true current
     state rather than trusting a stale local record.
   - `{:ok, false}` → `provider_admin_impl().create_realm(tenant.idp_realm_id)` →
     `:ok` → `{:ok, :created}`; `{:error, reason}` → `{:error, {:provider_error, reason}}`.
   - `{:error, reason}` (the existence check itself failed — e.g. Keycloak unreachable) →
     `{:error, {:provider_error, reason}}`. This function does **not** fall through to
     attempting `create_realm/1` when the existence check itself errors — attempting a
     blind create after a failed existence check risks a spurious "realm already exists"
     provider error masking the real (connectivity) failure; the caller sees the true
     underlying error and can retry the whole call, which re-runs the existence check
     first again.

**This single function is the idempotent primitive** — calling it twice for the same
`tenant_id` is not an error, matching `provision_tenant_schema/1`'s own documented
idempotency (§0) exactly: the second call's existence check finds the realm already there
and returns `{:ok, :already_exists}` without attempting a duplicate create.

### 2.4 `Letflow.Identity.ProviderAdmin` — the `@behaviour` (REQ-135 §5's shape, realm-scoped)

```
@callback create_realm(realm_name :: String.t()) :: :ok | {:error, term()}
@callback realm_exists?(realm_name :: String.t()) :: {:ok, boolean()} | {:error, term()}
@callback delete_realm(realm_name :: String.t()) :: :ok | {:error, term()}
```

`delete_realm/1` is declared on the behaviour (so a real implementation exists and is
testable) but is **never called by any automatic code path this design specifies** — see
§5's decision not to use compensating deletes. It exists for operator/console/test use
only (e.g., tearing down a test-created realm), matching this design's "no compensating
rollback" policy while still providing the primitive a human might need. Only these three
callbacks are declared — the other ~10 admin operations REQ-135 §2 catalogs (user/client/
federation/audit-event provisioning) are **not** declared here; a future requirement
extending this behaviour with them is out of REQ-137's scope (§1).

Configured implementation resolved via `Application.get_env(:letflow, :identity)[:provider_admin]`
(new config key, sibling to the existing `:oidc` key's `token_verifier` entry — same
resolution idiom, not a new pattern).

### 2.5 `Letflow.Identity.ProviderAdmin.Keycloak` — the real implementation

PROVENANCE (historical, not current decision authority):
Backed by the Keycloak Admin REST API (`config.zig`/`provider.zig`/`urls.zig`'s ported
subset, §8). Internally: admin-token acquisition/caching (client-credentials or
admin-password grant against Keycloak's own `master` realm — mirrors `config.zig`'s admin
credential fields, REQ-135 §2 row 1) plus three HTTP calls
(`POST /admin/realms`, `GET /admin/realms/:name`, `DELETE /admin/realms/:name`) via `Req`
(already a Letflow dependency, per REQ-135 §4's own reasoning for why `provider.zig`
shrinks in translation). No new design surface beyond the `@behaviour` callback shapes
above — HTTP request/response mapping is implementation detail for ELIXIR-DEV, not
specified further here (matches this project's design-doc convention of not writing
implementation code).

### 2.6 Test double

`Letflow.Identity.ProviderAdmin.Double` (or equivalently named), following
`test/support/token_verifier_double.ex`'s already-established shape exactly (REQ-135 §5
names this precedent directly) — an in-memory `Agent`/ETS-backed fake implementing the
three callbacks, configured in `config/test.exs`. Not designed further here; TEST-DESIGNER's
Step 3 concern.

---

## 3. Composition with `TenantProvisioning`/`TenantOnboarding`/REQ-076 — naming which
   component calls which, no implicit chaining

**The three primitives that exist after this design's implementation plan ships:**

| Primitive | Module | Touches |
|---|---|---|
| Schema creation | `Letflow.TenantProvisioning.provision_tenant_schema/1` | Postgres |
| Migration replay | `Letflow.TenantProvisioning.replay_migrations/2` | Postgres |
| Realm creation | `Letflow.Identity.RealmProvisioning.create_tenant_realm/1` | Keycloak |

**REQ-022 §3.2's invariant (already binding on the first two) extends unchanged to the
third: none of these three functions calls any of the other two.**
`Letflow.TenantProvisioning` is not modified by this design and gains no awareness of
Keycloak. `Letflow.Identity.RealmProvisioning` is not modified to call
`TenantProvisioning`, and vice versa. This is a direct, deliberate extension of the
existing invariant to the new primitive — not a new invariant this design invents.

**The explicit sequencer is `Letflow.TenantOnboarding`, already REQ-076's designated
orchestration layer, not a new module.** `Letflow.TenantOnboarding.provision_and_migrate/1`
already exists and already explicitly sequences the first two primitives (§0). This
design's implementation plan (§8 item 3) extends that **same** function with one more
explicit step:

```
@spec provision_and_migrate(tenant_id :: Ecto.UUID.t()) ::
        {:ok, Registration.t()}
        | {:error, :tenant_not_found}
        | {:error, :missing_realm_binding}
        | {:error, {:provisioning_failed, term()}}
        | {:error, {:migration_failed, Exception.t()}}
        | {:error, {:realm_provisioning_failed, term()}}
def provision_and_migrate(tenant_id) do
  with {:ok, _registration} <- provision(tenant_id),
       {:ok, _applied_versions} <- TenantProvisioning.replay_migrations(tenant_id),
       {:ok, _realm_result} <- create_realm_if_bound(tenant_id) do
    activate_tenant(tenant_id)
    {:ok, Repo.get_by(Registration, tenant_id: tenant_id)}
  end
end
```

(`@spec`/shape only — no bodies beyond what's already shown above the `with`, which is
existing, shipped code being extended, not new implementation.) `create_realm_if_bound/1`
is a small new private wrapper: if `tenant.idp_realm_id` is `nil` (an OIDC-disabled
tenant, §2.3 point 2), it returns `{:ok, :skipped}` — realm creation is silently a no-op
for a tenant that was never bound to a realm, not an error — otherwise it calls
`RealmProvisioning.create_tenant_realm/1` and maps `{:error, {:provider_error, reason}}`
to `{:error, {:realm_provisioning_failed, reason}}` (a distinct top-level error tag from
`:provisioning_failed`/`:migration_failed`, so a caller inspecting the error can tell
which of the three steps failed).

**This IS explicit sequencing, not implicit chaining**, for the same reason
`TenantOnboarding`'s own moduledoc already gives for its first two steps: the invariant
REQ-022 §3.2 protects is "the *primitive* modules (`TenantProvisioning`,
`RealmProvisioning`) never call each other" — it has never meant "no module anywhere may
call more than one primitive." `TenantOnboarding` is precisely the caller REQ-022 §3.2's
own text says the invariant "hands to" ("a future requirement owns the onboarding
orchestration that sequences them — not invented here"); this design's extension is that
same authorized orchestration role, extended to a third primitive, not a violation of it.

**Order chosen: realm creation last (after schema+migrations, before the status flip).**
Not required for correctness — the three primitives have no data dependency on each other
(Postgres schema creation needs nothing from Keycloak; Keycloak realm creation needs
nothing from Postgres beyond the already-committed `idp_realm_id` value, §2.1). Chosen
because it keeps `activate_tenant/1`'s `:active` flip (§ REQ-076 §12.1) as the true final
signal that *everything* — schema, migrations, and realm — is ready, matching AC10's
already-shipped moduledoc language ("`:migrating` from the moment the tenant row is
inserted until `provision_and_migrate/1`'s own last step flips it to `:active`") without
needing to touch that language's meaning.

---

## 4. What REQ-076 may call vs. what it must not absorb

**REQ-076 (`Letflow.Routers.Onboarding`, `Letflow.TenantOnboarding`) may call:**

- `Letflow.TenantOnboarding.provision_and_migrate/1` — **unchanged call site.**
  `Letflow.Routers.Onboarding.provision_and_bind/4` already calls this function today
  (§0); after §3's extension ships, the identical call site transitively creates the
  realm too, with **zero code change required in the router**. This is the concrete,
  mechanical payoff of putting the new step inside `TenantOnboarding` rather than beside
  it.
- `Letflow.TenantOnboarding.recover_provisioning/1` — likewise unchanged; after §3's
  extension, a recovery call also converges the realm side (§5's retry semantics), not
  only the Postgres side, with no change to REQ-076's own AC9 recovery-test shape (§8 item
  3 notes the one new assertion this adds to that existing test).
- The one *new* piece of information the router's `handle_create/1` must supply, per
  §2.1: `"idp_realm_id" => slug` in `create_attrs`, and `oidc_mode: :enabled` at the
  `Identity.create_tenant/1` call site. This is a small, explicit, named edit to REQ-076's
  own shipped code (§8 item 4) — not new orchestration logic, just supplying one more
  field to an existing call.

**REQ-076 must NOT:**

- Call `Letflow.Identity.RealmProvisioning` or `Letflow.Identity.ProviderAdmin` directly
  from the router or from any new REQ-076-owned module. Doing so would create the exact
  "two paths, not one" shape REQ-076's own moduledoc already refused for tenant/schema
  provisioning (AC8: "there is one tenant-provisioning path on this platform, not two") —
  extended here to mean there is one place (`TenantOnboarding.provision_and_migrate/1`)
  that ever sequences all three primitives, not two places that each sequence a subset.
- Implement any Keycloak HTTP logic, admin-token handling, or realm-existence polling
  itself. That is `Letflow.Identity.ProviderAdmin.Keycloak`'s and
  `Letflow.Identity.RealmProvisioning`'s job entirely (§2.3-§2.5) — REQ-076-owned code
  only ever sees the three-tuple error shapes `provision_and_migrate/1` already returns.
- Build any new retry/scheduling machinery for realm creation specifically. §5's retry
  story reuses the **same** entry point (`recover_provisioning/1`) REQ-076 already built
  for AC9 — no second recovery mechanism.

---

## 5. Partial-failure path — both directions, compensating action, retry behavior

**Governing decision, stated up front and justified, not silently applied:** neither
direction below performs a compensating delete. This deliberately extends, rather than
diverges from, the standing decision already on record for the Postgres pair
(`Letflow.TenantProvisioning`'s moduledoc, §0: "A compensating rollback is deliberately
not the answer and must not be added... trading a recoverable partial state for an
unrecoverable orphan," REVIEWER's own ISS-0230 finding). The realm-creation primitive is
made idempotent-by-construction instead (§2.3's existence guard) so that **retrying the
same `provision_and_migrate/1` call is always safe, regardless of which of the three
steps failed last time or in which order** — this is the direct generalization of the
Postgres-pair policy to a third primitive, kept symmetric on purpose: an asymmetric
policy (rollback on one side, converge-by-retry on the other) would be a harder-to-reason
-about system for no correctness benefit, since both directions below are demonstrably
safe to leave alone (reasoning per-direction below).

### 5.1 Direction A: realm created, then schema provisioning (or migration replay) fails

**State after failure:** a Keycloak realm named `tenant.idp_realm_id` exists (per §3's
step order, this direction happens if `create_realm_if_bound/1` is somehow reached before
`replay_migrations/2`'s own failure is caught by an *earlier* retry's differently-ordered
history, or — more directly — if a retry of an already-partially-succeeded
`provision_and_migrate/1` call hits a *new*, later failure the second time around).
Postgres may be in any of the states `Letflow.TenantProvisioning`'s own moduledoc already
documents for its two-primitive pair (`tenants` row present; `tenant_schemas` row present
or absent; `migrations_applied_at` `NULL` or set) — this design does not change that
documented set of Postgres-side states at all.

**Compensating action: none.** Reasoning: the realm just created is provably safe to
leave in place. No caller can have authenticated against it yet — `Letflow.Plugs.AuthPipeline`'s
OIDC branch requires a live query against the tenant's own `users` table (§0,
`req076-...md` §12.2's own argument, restated here for the realm side: that argument
already establishes no credential can exist for a tenant whose Postgres schema isn't
fully migrated, which is exactly the state this direction is in) — so the realm has zero
externally-observable side effects beyond its own existence. Deleting it would buy
nothing (no risk it mitigates) and would reintroduce exactly the "delete now, race a
concurrent retry that's mid-flight" hazard REVIEWER's ISS-0230 finding already flagged
for the Postgres side.

**Retry:** re-invoking `provision_and_migrate/1` (directly, or via `recover_provisioning/1`)
with the same `tenant_id`. Step 1 (`provision_tenant_schema/1`) and step 2
(`replay_migrations/2`) are already-documented-idempotent (§0); step 3
(`create_realm_if_bound/1` → `RealmProvisioning.create_tenant_realm/1`) re-runs its
existence check (§2.3), finds the realm already present, and returns `{:ok, :already_exists}`
without attempting a duplicate create — **this is the realm-existence guard doing exactly
the job R-Co's `realm_guard` does on replay** (§0), just implemented as a live per-call
Keycloak query rather than a local flag/registry column.

### 5.2 Direction B: schema provisioned (and migrated), then realm creation fails

**State after failure:** Postgres schema fully migrated (`migrations_applied_at` set), no
Keycloak realm named `tenant.idp_realm_id` exists yet. `tenant.status` remains
`:migrating` (`activate_tenant/1`, §3's `with` chain, never runs — it is strictly after
the realm-creation step).

**Compensating action: none**, for the same reason direction A's compensating-action
analysis gives in reverse: the standing ISS-0230 decision already forbids rolling back
the Postgres side on *any* later failure (this design does not re-litigate that decision,
per this project's core-directives instruction not to silently re-decide a settled
invariant) — this direction is simply the case where the "later failure" happens to be
the realm step instead of the migration step, and the same non-rollback policy applies to
the same Postgres-side state regardless of which step downstream of it failed.

**Retry:** re-invoking `provision_and_migrate/1`. Steps 1 and 2 are no-ops (already
converged — `provision_tenant_schema/1`'s second-call idempotency and
`Ecto.Migrator.run/4`'s own "zero pending migrations" idempotency, both already
documented, §0). Step 3 retries `RealmProvisioning.create_tenant_realm/1` for real this
time — its existence check finds no realm (first attempt never got far enough to create
one, or partially failed inside `create_realm/1` itself, in which case the existence
check still correctly reports "not found" and a clean create is attempted again) — and on
success, `activate_tenant/1` finally runs, flipping `:migrating -> :active` for the first
time. **This is the tenant remaining visibly `:migrating` (write-paused, per REQ-076
AC10's already-shipped `Letflow.Plugs.TenantStatus` gate, §0) for exactly as long as the
realm side has not yet converged** — a direct, correct extension of AC10's existing
"`:migrating` means not-yet-fully-provisioned" semantics to the third primitive, requiring
no change to `TenantStatus` itself (matching AC10's own "must not be a second status rule
conflicting with TenantStatus" constraint, §0).

### 5.3 What a genuinely permanent (non-transient) realm-creation failure looks like

Both directions above assume the retried operation eventually succeeds. If
`create_realm/1` fails for a persistent reason (e.g. a realm-name collision with a realm
Keycloak already has for an unrelated reason, or a permissions misconfiguration on the
admin credentials), `RealmProvisioning.create_tenant_realm/1` returns
`{:error, {:provider_error, reason}}` on every retry, and the tenant remains `:migrating`
indefinitely — this design does not add alerting/paging for that state (out of scope, no
acceptance criterion requires it); it is the same "stuck half-provisioned tenant needs a
human to look at the error" situation `TenantProvisioning`'s own moduledoc already accepts
for a persistently-failing migration (§0's `{:error, {:migration_failed, exception}}`
branch, "a genuine, persistent failure... surfaces through; this function does not
swallow a real migration failure into a false success" — direction B's realm-side
equivalent behaves identically).

---

## 6. DB schema changes: none

**No new table, column, or migration.** The realm-existence guard (§2.3, §5) is a live
Keycloak query on every call, not a locally-cached flag — Keycloak itself is the
authoritative registry of "does this realm exist," the same way `Ecto.Migrator`'s own
`schema_migrations` table (inside each tenant schema) is already the authoritative record
of "have these migrations run," with no Letflow-side duplicate of that state either.
`tenant.idp_realm_id` (REQ-019/REQ-015, already shipped) is the only column this design
touches, and only by *using* its already-existing, already-nullable, already-immutable
shape (§2.1) — no `ALTER TABLE`, no new constraint. This is a deliberate difference from
`tenant_schemas`/`Registration` (which needed a local table because Postgres has no
single "did schema-X get created" column queryable from `public`): a Keycloak Admin REST
`GET /admin/realms/:name` call is already exactly that single source of truth for realms,
so duplicating it locally would be new, unrequested machinery, not a required
architectural parallel.

---

## 7. Open questions (explicit, not silently resolved)

1. **OQ-1 — should the extra Keycloak round trip on every `provision_and_migrate/1`
   retry (the existence-check guard, §2.3) be rate-limited or backed by a short-lived
   local cache for a tenant known to be persistently failing (§5.3)?** Not decided here —
   no acceptance criterion requires it, and `provision_tenant_schema/1`'s own precedent
   (§0) already accepts a similar unconditional-recheck cost on every idempotent call
   without caching. Left for REVIEWER/ELIXIR-DEV if retry volume against a broken realm
   ever becomes a real operational concern.
2. **OQ-2 — the realm-name-equals-slug convention (§2.1) is this design's choice, not
   cited from any R-Co source or existing decision record.** R-Co's own realm-naming
   scheme was not confirmed against any read source during this design (out of scope —
   R-Co's `bpm-default`/dynamic-tenant realm-naming convention was not located in the
   sources read, §0). Slug was chosen because it is the one field REQ-019 already treats
   as a stable, human-assigned, globally-unique, create-time-only identifier — exactly
   the properties a realm name needs — and because it generalizes the existing
   `"bpm-default"` pinned-default-tenant precedent (REQ-019 §4) rather than inventing a
   second convention. A future implementer or REVIEWER could reasonably pick a different
   deterministic function of `tenant_id` instead (mirroring
   `TenantProvisioning.schema_name_for_tenant/1`'s own `"tenant_" <> hex` shape) — not
   foreclosed by this design, just not the default recommended here, since a
   human-readable realm name (matching R-Co's own human-readable realm-name convention
   for its static realms, `req128`'s `bpm-default`/`letflow-default`, §0) is more
   operator-legible in the Keycloak admin console than an opaque hex string.
3. **OQ-3 — should `RealmProvisioning.create_tenant_realm/1` also apply any realm-content
   convention (five-role set, protocol mappers) at creation time, matching REQ-128's
   static `bpm-default` realm's shape (§0), or ship as a bare empty realm first?** Not
   decided here — REQ-137's own scope (§1) is realm *creation*, not realm *content*; a
   bare `POST /admin/realms` call with no role/client/mapper setup is the minimal
   interpretation of "create a realm" and is what §8's sizing assumes. Populating a
   freshly-created dynamic realm with the same five-role/client/mapper shape REQ-128 gives
   the static dev-stack realm is real, necessary future work (an OIDC login against a
   realm-with-no-client cannot succeed) but is not sized into this design's implementation
   plan — flagged as a required follow-up, not silently assumed to be included in "realm
   creation."
4. **OQ-4 — no decision is made here about deleting a realm when a tenant itself is later
   deactivated/deleted** (no such tenant-deletion capability exists anywhere in this
   codebase today, confirmed by absence — `Letflow.Identity.Tenant.status` has no
   `:deleted` value, only `:active`/`:migrating`/`:inactive`). Out of scope; the
   `delete_realm/1` callback (§2.4) exists on the behaviour for whenever that capability
   is designed, not used by any path this design specifies.

---

## 8. Sized implementation plan

Numbered, one entry per follow-on requirement. Every entry is realm-operation-scoped
only (§1) — the ~10 non-realm admin operations REQ-135 §2 catalogs remain future,
unsized-here work.

1. **`Letflow.Identity.ProviderAdmin` behaviour + `Letflow.Identity.ProviderAdmin.Config`
   + test double.**
   - Expected size: **150** lines.
   PROVENANCE (historical, not current decision authority):
   - Ports/adds: R-Co `src/identity/provider/interface.zig` (PORT, REQ-135 §2 row 8 —
     realm-only subset: 3 callbacks, not the full ~13), `src/identity/provider/adapters/keycloak/config.zig`
     (PORT, row 1 — admin base URL/realm/credentials/timeouts). New Letflow modules:
     `lib/letflow/identity/provider_admin.ex` (behaviour), `lib/letflow/identity/provider_admin/config.ex`,
     `test/support/provider_admin_double.ex` (mirrors `token_verifier_double.ex`).
   - Sized to one agent turn: yes — a `@behaviour` declaration, a config struct sourced
     from `Application.get_env` (an already-established pattern, REQ-016), and a test
     double following an existing, shipped template are each small, mechanical,
     low-design-risk pieces of work, matching this codebase's other single-turn
     `@behaviour`-pair requirements (e.g. the original `Letflow.Oidc.TokenVerifier` work).

2. **`Letflow.Identity.ProviderAdmin.Keycloak` — the real Admin REST API client for the
   three realm callbacks.**
   - Expected size: **300** lines.
   PROVENANCE (historical, not current decision authority):
   - Ports: R-Co `src/identity/provider/adapters/keycloak/provider.zig` (PORT, row 2 —
     realm-only subset: admin-token acquisition/caching plus the 3 realm HTTP calls, not
     the ~10 other admin operations that file also contains), `src/identity/provider/adapters/keycloak/urls.zig`
     (PORT, row 3 — realm URL builders only). New Letflow module:
     `lib/letflow/identity/provider_admin/keycloak.ex`.
   - Sized to one agent turn: yes — three HTTP operations plus one shared admin-token-caching
     concern, using `Req`+`Jason` (already dependencies), is comparable in shape/size to
     other single-requirement HTTP-client work already shipped in this codebase (e.g.
     `Letflow.Oidc.TokenVerifier.Oidcc`'s own scope).

3. **`Letflow.Identity.RealmProvisioning` (the idempotent primitive, §2.3) +
   `Letflow.TenantOnboarding.provision_and_migrate/1` extension (§3) + the one new AC9
   recovery-test assertion (§5.1's retry behavior).**
   - Expected size: **180** lines.
   PROVENANCE (historical, not current decision authority):
   - Adds/changes: new Letflow module `lib/letflow/identity/realm_provisioning.ex`
     (`create_tenant_realm/1`, ~60 lines); changes to existing, shipped
     `lib/letflow/tenant_onboarding.ex` (`provision_and_migrate/1`'s `with` chain gains
     one clause plus the small `create_realm_if_bound/1` private helper, ~40 lines
     including moduledoc updates per §3); test additions extending the already-shipped
     AC9 recovery test (`test/letflow/tenant_onboarding_test.exs` or equivalent, ~80
     lines: a realm-creation-failure-then-recovery case mirroring §5.1/§5.2's two
     directions). No R-Co file ported for this item — it is Letflow's own composition
     layer, with no 1:1 R-Co source (R-Co's `onboarding.zig` sequences its steps inline in
     a saga, which REQ-076 §8.5 already declined to port wholesale).
   - Sized to one agent turn: yes — one new ~60-line context module plus a small,
     well-specified extension to one existing function (this design's §3 already gives
     the exact `with`-chain shape) is comparable in scope to other single-turn "extend an
     existing orchestration function with one more step" requirements already shipped in
     this codebase (e.g. REQ-076's own AC9/AC10 SCOPE EXTENSION additions to this same
     module).

4. **`Letflow.Routers.Onboarding.handle_create/1` + `Letflow.Identity.create_tenant/1`
   wiring for `idp_realm_id`/`oidc_mode` (§2.1, §4).**
   - Expected size: **50** lines.
   - Changes: existing, shipped `lib/letflow/routers/onboarding.ex` (`create_attrs` gains
     `"idp_realm_id" => slug`, ~5 lines) and existing, shipped `lib/letflow/identity.ex`
     (`create_tenant/1` gains an `oidc_mode` parameter or a second arity, replacing its
     hard-coded `:disabled`, ~15 lines including the `@spec` change); tests exercising the
     new field end-to-end through `POST /onboarding` (~30 lines). No R-Co file ported —
     this is a two-line-conceptually, explicitly-named wiring fix to already-shipped
     Letflow code, not a port.
   - Sized to one agent turn: yes — this is the smallest of the four entries by design;
     bundling it separately (rather than folding it into item 3) keeps the "add a realm
     name to onboarding's tenant-creation call" concern isolated from the "add a
     realm-creation step to the orchestration sequence" concern, so a REVIEWER/TEST-DESIGNER
     pass on one does not have to re-review the other's unrelated diff.

**Total across all four entries: 680 lines** — materially smaller than REQ-135 §4's
~1,200-line estimate for the *full* 13-admin-operation surface, because this plan
deliberately ships only the realm-creation subset (§1); the remaining ~520 lines'
worth of REQ-135's estimate (user/client/federation/role/audit-event provisioning) is
future work this design does not size.

---

## 9. Acceptance-criteria traceability

| # | Criterion | Concrete design element |
|---|---|---|
| 1 | Design artefact under `lib/letflow/design/`, builds on REQ-135's PORT/DROP table, cites by path | This file; §0 and §2.2 cite `lib/letflow/design/req135-keycloak-provider-port-boundary.md` by path throughout, never re-deriving its table |
| 2 | Partial-failure path both directions, each with named compensating action + retry behavior | §5.1 (realm-then-schema-fails: no compensating action, justified; retry via existence guard) and §5.2 (schema-then-realm-fails: no compensating action, justified; retry re-attempts realm creation only) |
| 3 | Composition with TenantProvisioning without violating REQ-022's no-implicit-chaining invariant, naming which component calls which | §3 — table of three primitives, invariant restated and extended, `TenantOnboarding.provision_and_migrate/1` named as the explicit sequencer with its exact extended `with`-chain shape |
| 4 | Sized implementation plan: numbered, each with line count + named files/modules + one-agent-turn statement | §8 — four entries, each with all three elements |
| 5 | Relationship to REQ-076 stated — what it calls, what it must not absorb | §4 |
| 6 | No implementation code | Every code-shaped block in this file is a `@spec`/`@callback`/`with`-chain-shape signature, not a function body with real logic — the one `with` block in §3 reproduces only already-shipped code's existing shape plus a one-line new clause, to specify the extension precisely, not to hand ELIXIR-DEV a body to paste |

Additionally: §6 states the DB-schema-changes-if-any requirement explicitly (none, with
reasoning) per this task's own acceptance bar; §7 lists four open questions rather than
resolving any of them silently.
