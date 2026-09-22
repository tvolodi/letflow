# Design — ISS-0778: no seeding path for REQ-378's DB-backed platform-role sync

CODE-DESIGNER design for MAJOR `docs/issues/ISS-0778.yaml` (GH-1697, Q-777).

## 0. Root cause, re-derived from source (not re-argued from the issue alone)

REQ-378's live-role mechanism (`lib/letflow/design/req378-oidc-live-revocation-check.md`
§1-§2.2) makes `group_members ⋈ tenant_role` the **sole** source of a user's effective
platform roles:

- `Letflow.Identity.list_effective_role_names/2` reads only `tenant_role` rows with
  `kind == :platform_role` (ISS-0774), joined through `group_members`.
- `Letflow.Identity.sync_role_claims_from_token/3` — the one-time, marker-gated
  (`users.role_claims_synced_at`) JIT sync — writes a `group_members` row for a claimed
  role name **only if a `tenant_role` row already exists binding that name to a group**
  (`resolve_group_ids_for_role_names/2`, `lib/letflow/identity.ex:824-837`: `where: t.name
  in ^role_names and t.kind == :platform_role`). A claimed role name with no matching
  `tenant_role` row resolves to **nothing** — not an error, just silently zero grants
  (with a `Logger.warning/1`, `identity.ex:743-749`).

**The actual gap:** no code path anywhere in this codebase ever creates a `tenant_role`
row binding `"PLATFORM_ADMIN"` (or any of `Letflow.Api.Authorization.roles/0`'s other
five literals) to a group, for any tenant. So for a freshly-provisioned tenant, *even a
correctly-configured IdP claiming `"PLATFORM_ADMIN"` in a user's token* cannot produce a
working grant — `resolve_group_ids_for_role_names/2` finds zero `tenant_role` rows to
match against, `sync_role_claims_from_token/3` writes zero `group_members` rows (but
still — per ISS-0773's fix — leaves `role_claims_synced_at` unset so the sync retries
next request; it never succeeds because the `tenant_role` row it needs never appears),
and `list_effective_role_names/2` returns `[]` forever. This is a **provisioning-data
gap**, not a code-path gap in the sync mechanism itself: the sync logic (§1-§2.2 of
REQ-378's design) is correct and needs no change; what is missing is the one-time,
per-tenant act of creating the `groups`/`tenant_role` rows the sync mechanism reads.

This matches exactly what UAT-RUNNER had to manually do (per the issue): bootstrap
`tenant_role`/`group_members` rows directly via `Letflow.Identity`/
`Letflow.Identity.RoleRegistry` calls — i.e., manually perform the missing seeding step
this design now makes automatic.

## 1. The mechanical question this design must answer first: does onboarding know the
## admin user's identity at provisioning time?

**No — confirmed by direct source read, not assumed.** `lib/letflow/routers/onboarding.ex`
(REQ-076)'s own moduledoc, "What is deliberately NOT ported" section, states verbatim:
*"Keycloak realm/client provisioning, **initial-admin-user creation**, ... are all absent
here — none has an acceptance criterion in this requirement."* `handle_create/1`'s
`@create_schema` (lines 136-161) accepts exactly `slug`/`display_name`/`hostname` — no
user, email, or subject identifier field of any kind. The tenant's actual admin user is
established later, out-of-band, via OIDC JIT provisioning
(`Letflow.Identity.provision_oidc_user/4` → `upsert_by_external_identity/4`) the first
time *someone* authenticates against that tenant's realm with a token the tenant's IdP
configuration (itself entirely outside this codebase — Keycloak realm/client/role-mapping
setup) has been configured to claim `"PLATFORM_ADMIN"` for.

**Consequence for candidate (a) as literally worded in the issue** ("provision a default
PLATFORM_ADMIN group + **grant for the tenant's first admin user** at onboarding time"):
the "grant for the [specific] user" half is **mechanically impossible** at onboarding
time — there is no user row to grant to yet, and inventing one (e.g., a synthetic
placeholder user) would fabricate a `users` row for a person who has never authenticated,
which is not this platform's provisioning model anywhere else (every existing user row
originates from either `Identity.create_user/2`, an explicit admin action, or OIDC JIT
provisioning — never a system-synthesized placeholder).

**What onboarding *can* and must do instead:** provision the `groups`/`tenant_role`
**bindings** (the "which group does the platform recognize `PLATFORM_ADMIN` as" half),
without needing to know who will eventually hold that role. This is exactly what
`sync_role_claims_from_token/3` is built to consume automatically, once it exists — the
first user whose IdP-issued token claims `"PLATFORM_ADMIN"` (an IdP-side configuration
decision, out of this design's scope, same as every other IdP-role-mapping decision on
this platform) gets bound to that group on their very first JIT-provisioned login,
through the existing REQ-378 mechanism, with **zero manual DB bootstrap**. This reframing
is the core of this design's chosen mechanism (§2).

## 2. The decision: seed the group→role bindings for all six platform roles at tenant-
## provisioning time (mechanism (a), narrowed to what is mechanically possible)

**Mechanism, one sentence:** `Letflow.TenantOnboarding.provision_and_migrate/1` — already
the single orchestration point both the onboarding-creation path and the recovery path
(`recover_provisioning/1`) funnel through — gains one new, idempotent step, run once
migrations have replayed successfully: for each of `Letflow.Api.Authorization.roles/0`'s
six literal role names, get-or-create a `groups` row named after that literal, then
`RoleRegistry.upsert_role/4` to bind it as `kind: :platform_role`. This is data seeding
against tables that already exist (`groups`, `tenant_role` — both REQ-015/REQ-020,
unaffected by ISS-0774's `kind` column beyond needing to pass it) — **no new migration,
no new column, no schema change of any kind.**

### 2.1 Why all six platform roles, not just `PLATFORM_ADMIN`

The issue's `fix_direction` names only `PLATFORM_ADMIN` as the motivating example (it's
the one UAT-RUNNER hit), but the root cause (§0) is identical for all six literals in
`Authorization.roles/0` — `PROCESS_DESIGNER`, `PROCESS_OPERATOR`, `TASK_WORKER`,
`AGENT_RUNNER`, `CANDIDATE` are exactly as unreachable via the JIT sync path as
`PLATFORM_ADMIN` is, for the same reason, on every fresh tenant today. Seeding only
`PLATFORM_ADMIN` would close today's discovered symptom while leaving the identical latent
gap for the other five, guaranteeing a near-identical ISS-0778-shaped issue gets filed
again the first time an operator needs to onboard a `TASK_WORKER`-only tenant. Seeding all
six is the same amount of new code (one loop over an existing, already-authoritative list,
`Authorization.roles/0`) and closes the whole class of gap, not one instance of it.

### 2.2 Why `Letflow.TenantOnboarding.provision_and_migrate/1`, not `Letflow.TenantProvisioning`

`Letflow.TenantProvisioning`'s own moduledoc states `provision_tenant_schema/1` and
`replay_migrations/2` are "two separate, composable primitives — neither calls the
other" (the "No implicit chaining invariant", §3.2 of its own design doc) and that
`Letflow.TenantOnboarding` (REQ-076) is deliberately the caller-side module that
sequences them. Role-group seeding is exactly this same kind of onboarding-orchestration
concern — it must run *after* `replay_migrations/2` succeeds (the `groups`/`tenant_role`
tables do not exist until migrations replay) and is not itself a schema-provisioning
primitive. Adding it to `TenantProvisioning` would violate the same invariant REQ-076 was
built to respect; `TenantOnboarding.provision_and_migrate/1` is the one place in this
codebase already responsible for "what must happen, in order, for a freshly-provisioned
tenant to be actually usable" — role-group seeding belongs there by the same reasoning
that put migration-replay-then-activate there.

### 2.3 Why `Letflow.Identity.RoleRegistry`, not `Letflow.Identity`, owns the new seeding function

`RoleRegistry` already owns both `groups` (via its `Group`/`Ecto.Schema` alias) and
`tenant_role` (`upsert_role/4`) and already composes them (`do_upsert_role/4` looks up the
`Group` before binding). A group-then-role-binding seed function is a natural extension of
that existing responsibility, not a new one. This does **not** conflict with `RoleRegistry`'s
documented "no coupling to the OIDC/claim-mapping pipeline" invariant (its moduledoc,
`role_registry.ex:11-17`) — that invariant is specifically about not being called *from* or
calling *into* the OIDC token-verification pipeline; provisioning-time group/role seeding
has no OIDC involvement at all (it runs from `TenantOnboarding`, triggered by tenant
creation, with no token, claim, or `IdentityContext` anywhere in its call chain). Contrast
with `list_effective_role_names/2`/`sync_role_claims_from_token/3`, which *do* sit on the
OIDC path and were deliberately placed in `Letflow.Identity` instead, for exactly that
reason (REQ-378 design §2) — this new function is the opposite case and belongs on the
opposite side of that same line.

### 2.4 Idempotency requirement

`provision_and_migrate/1` is called from two places that must both remain safe to
re-invoke: the normal onboarding-creation path (called once, but a caller could retry a
failed request) and `recover_provisioning/1` (AC9 — explicitly designed to be re-run
against a tenant that may have partially succeeded before). The new seeding step must
therefore be idempotent under re-invocation against a tenant whose `groups`/`tenant_role`
rows may already exist from a prior partial or full run:

- Group creation: **get-or-create by name**, not a bare insert — a second call for the
  same tenant must not error on `groups.name`'s unique index (confirmed:
  `unique_index(:groups, [:name], prefix: prefix())`,
  `priv/repo/migrations/20260822000101_alter_groups_add_display_name_description.exs:33`).
- Role binding: `RoleRegistry.upsert_role/4` is already idempotent (upsert-on-`name`-
  conflict, confirmed by direct read, `role_registry.ex`'s `insert_or_update_role/4`) — a
  second call with the same `(name, kind, group_id)` is a no-op write of the same values.

### 2.5 Rejected alternative (b) — a separate, explicit `mix letflow.seed`-invoked step

Rejected as the *sole* mechanism, for one direct reason: `mix letflow.seed` only ever
seeds the one `bpm-default` dev/test tenant (its own `@shortdoc`: "Provisions the default
bpm-default tenant against a fresh dev database"). Any tenant created via `POST
/api/v1/onboarding` (self-service) or `POST /api/v1/tenants` (platform-admin-created) in a
real deployment never runs through `mix letflow.seed` at all — a mix-task-only fix would
leave the exact gap this issue reports open for every tenant created through either HTTP
path, which is the actual failure mode UAT-RUNNER hit (a tenant provisioned through the
onboarding flow, not through the dev seed task). `mix letflow.seed` is still touched by
this design (§4) — but as a *consumer* of the now-seeding-inclusive orchestration
function, not as the mechanism itself.

### 2.6 Rejected alternative (c) — a lazy/on-demand seed, triggered by the first failed
### `sync_role_claims_from_token/3` resolution

Considered: have `resolve_group_ids_for_role_names/2` (or a wrapper around
`sync_role_claims_from_token/3`) auto-create the missing `groups`/`tenant_role` row the
first time a claimed role name resolves to zero group ids, binding it to a
freshly-created group on the spot. Rejected: this would mean the *first* OIDC login for
*any* claimed role string — including a typo'd or IdP-misconfigured claim value — silently
mints a new, permanent platform-role binding, which is a strictly worse version of the
"silent privilege widening" concern ISS-0774 §1.2 already rejected a structurally similar
idea for (there, extending `role_from_string/1`'s implicit grants; here, auto-vivifying
`tenant_role` rows from unvalidated claim content). It would also make "what platform
roles exist for tenant X" a function of *login history* rather than an explicit,
inspectable provisioning decision — undesirable for the same audit/predictability reasons
`RoleRegistry.upsert_role/4`'s existing `:name_not_a_recognized_platform_role` rejection
(ISS-0774 §2.3) already established: this codebase prefers loud, explicit, provisioning-
time role management over implicit, request-time role creation.

## 3. Exact shapes

### 3.1 `Letflow.Identity.RoleRegistry` — new public function

```
@spec seed_default_platform_role_groups(opts :: [prefix: String.t()]) ::
        {:ok, [TenantRole.t()]} | {:error, term()}
```

Behavior: for each `name` in `Enum.map(Letflow.Api.Authorization.roles(), &Atom.to_string/1)`
(the same six-literal source `upsert_role/4`'s own `platform_role_names/0` already derives
from — no new literal list invented, this function reuses that existing private helper's
source of truth), in a fixed, deterministic order (`Authorization.roles/0`'s own declared
order):

1. Get-or-create a `Group` named `name` (new private helper, §3.2) — `display_name`
   defaults to `name` via `Group.create_changeset/2`'s existing default-fill behavior
   (unchanged, reused as-is), `description` left `nil`.
2. `upsert_role(name, :platform_role, group.id, opts)` — the existing, unmodified
   `RoleRegistry.upsert_role/4`.
3. Collect each resulting `{:ok, %TenantRole{}}` into the returned list, in the same
   order as `Authorization.roles/0`.

On the first `{:error, _}` from either step (group creation or role upsert), the whole
function returns that error immediately — **no partial-success return value**; a caller
that gets `{:ok, roles}` back is guaranteed all six bindings exist, or gets an
`{:error, _}` and knows none of this call's own writes should be trusted as complete (the
individual writes it already made are not rolled back — see §3.3 for why this is
intentionally left non-transactional, matching this module's and `TenantOnboarding`'s
existing no-compensating-rollback precedent).

### 3.2 `Letflow.Identity.RoleRegistry` — new private helper

```
@spec get_or_create_group_by_name(name :: String.t(), opts :: [prefix: String.t()]) ::
        {:ok, Group.t()} | {:error, Ecto.Changeset.t()}
```

Shape: `Repo.get_by(Group, name: name, prefix: prefix)` first; if `nil`, insert via
`Group.create_changeset(%Group{}, %{"name" => name})` with `on_conflict: :nothing,
conflict_target: :name, returning: true` (the same on-conflict shape `insert_or_update_role/4`
already uses for `tenant_role`, and the same "look up, and fall back to a fetch on a raced
conflict" shape `Letflow.TenantProvisioning.insert_or_fetch_registration/2` already
establishes for `tenant_schemas` — no new idiom introduced). If the `on_conflict: :nothing`
insert returns a `nil`-primary-key result (a concurrent caller won the race), re-fetch by
`name` via `Repo.get_by/3` — mirroring the identical "insert raced, fetch the winner's row"
fallback `insert_or_fetch_registration/2` already implements for exactly this class of
race. Named `get_or_create_*` rather than this module's existing `insert_or_fetch_*`
convention (`insert_or_fetch_registration`, `insert_or_fetch_group_member`) deliberately —
those two *always* attempt the insert first (the common case is "doesn't exist yet"); this
helper's common case *post-first-provisioning-call* is "already exists" (idempotent
re-invocation, §2.4), so it checks first — a naming distinction that documents the
different common-case shape, not a functional difference worth flagging further.

### 3.3 `Letflow.TenantOnboarding.provision_and_migrate/1` — new step, new error tag

```
@spec provision_and_migrate(tenant_id :: Ecto.UUID.t()) ::
        {:ok, Registration.t()}
        | {:error, :tenant_not_found}
        | {:error, {:provisioning_failed, term()}}
        | {:error, {:migration_failed, Exception.t()}}
        | {:error, {:role_seeding_failed, term()}}
```

New third step in the existing `with` chain, after `replay_migrations/2` succeeds and
**before** `activate_tenant/1` runs:

```
with {:ok, registration} <- provision(tenant_id),
     {:ok, _applied_versions} <- TenantProvisioning.replay_migrations(tenant_id),
     {:ok, _tenant_roles} <- seed_platform_roles(registration.schema_name) do
  activate_tenant(tenant_id)
  {:ok, Repo.get_by(Registration, tenant_id: tenant_id)}
end
```

`seed_platform_roles/1` (new private, wraps `RoleRegistry.seed_default_platform_role_groups/1`,
converting its `{:error, reason}` to `{:error, {:role_seeding_failed, reason}}`, matching
this module's existing tagged-error convention for `provision/1`'s own wrapping of
`provision_tenant_schema/1`'s raw error).

**Deliberate ordering choice — seeding runs before activation, and a seeding failure
blocks activation.** Unlike `activate_tenant/1`'s own status-flip (which is explicitly
allowed to fail silently per the existing code's comment — "a failure here is a
status-flip-only failure, not a provisioning failure"), a role-seeding failure **must**
propagate as a hard `{:error, _}` from `provision_and_migrate/1` and **must** leave the
tenant at `:migrating`, not `:active`. Letting a tenant reach `:active` with its role
bindings unseeded would reproduce this exact issue under a different trigger (a role-seed
DB error instead of "nobody ever wrote the seeding code") — `:active` should mean "this
tenant is actually ready," and after this design, "ready" includes "an IdP-claimed
`PLATFORM_ADMIN` token can actually reach a grant," not just "the schema exists and is
migrated." A tenant left at `:migrating` by a seeding failure is recoverable the same way
any other partial-provisioning failure already is — `recover_provisioning/1` re-invokes
the identical `with` chain, and §2.4's idempotency guarantee means re-running seeding
against a tenant whose migrations already succeeded (and whose seeding may have partially
written some of the six bindings before failing) converges correctly on retry.

### 3.4 Consumers unified onto `TenantOnboarding.provision_and_migrate/1` (closing the gap
### everywhere it exists, not only on the path UAT-RUNNER happened to hit)

Two other call sites sequence `TenantProvisioning.provision_tenant_schema/1` +
`replay_migrations/2` **directly**, bypassing `TenantOnboarding` entirely — confirmed by
direct grep, both pre-date this design and both silently reproduce the identical seeding
gap for tenants created through them:

- `Mix.Tasks.Letflow.Seed.provision_and_replay/2` (`lib/mix/tasks/letflow.seed.ex:71-94`)
  — seeds the `bpm-default` dev tenant, used by `WF-05`/local dev bring-up.
- `Letflow.Routers.Tenants.provision_and_respond/2` (`lib/letflow/routers/tenants.ex:254-261`)
  — the platform-admin `POST /api/v1/tenants` route (REQ-075), structurally distinct from
  `POST /api/v1/onboarding` (REQ-076) but creating tenants through the identical
  provision-then-migrate sequence.

**Both are changed by this design to call `Letflow.TenantOnboarding.provision_and_migrate/1`
in place of their own direct two-call sequence.** This is not new scope invented by this
design — `lib/letflow/routers/onboarding.ex`'s own moduledoc already states the platform's
intent as "one tenant-provisioning path, not two" (AC8), a claim that was only ever true
for the onboarding-creation and recovery paths, not for these other two pre-existing
call sites; unifying them here makes that claim actually true platform-wide and is the
only way this fix closes the gap for *every* tenant-creation path, not just the one the
issue's discovery run happened to exercise. Neither call site's own external behavior
changes beyond this: `provision_and_respond/2` gains the same `{:error,
{:role_seeding_failed, _}}` tuple into its existing catch-all
`_provisioning_or_replay_error -> Response.internal_error(conn)` clause (already generic,
no new clause needed); `Mix.Tasks.Letflow.Seed`'s `provision_and_replay/2` gains one new
`Mix.raise/1` branch for the new error tag, matching its existing two-branch shape.
`Letflow.Routers.Tenants.provision_and_respond/2` also stops setting no status at all
today (tenant creation there uses `Identity.create_tenant/1`'s default `:active` status,
unlike onboarding's explicit `"status" => "migrating"`) — **this design does not change
that**: `activate_tenant/1` inside `provision_and_migrate/1` is a no-op for an
already-`:active` tenant (§ of `TenantOnboarding`'s own existing moduledoc, "idempotent:
if the tenant is already `:active`... the update is a no-op"), so routing this call site
through `provision_and_migrate/1` changes its role-seeding behavior only, not its
tenant-status semantics.

## 4. What is explicitly NOT changed

- `Letflow.Identity.list_effective_role_names/2`, `sync_role_claims_from_token/3`,
  `resolve_group_ids_for_role_names/2` — all unchanged. The sync mechanism itself was
  already correct (§0); this design supplies the missing data it reads, nothing more.
- `Letflow.Identity.RoleRegistry.upsert_role/4` — unchanged, reused as-is by the new
  seeding function.
- No migration. No new table, column, or index.
- `Letflow.Plugs.AuthPipeline` — unchanged; this design touches provisioning-time data
  seeding only, not the request-time auth pipeline REQ-378 already built.
- The IdP-side configuration that decides *which real human* ends up with a token
  claiming `"PLATFORM_ADMIN"` for a given tenant remains entirely out of this codebase's
  scope, as it already was before this design (§1) — this design makes that claim
  *effective* once made, not the mechanism that decides who gets it.

## 5. Regression-test design (issue's stated AC: "a freshly-provisioned tenant's
## intended admin user can authenticate and reach a PLATFORM_ADMIN-gated endpoint
## without manual DB bootstrap")

Four tests, at increasing levels of integration — mirroring REQ-378's own multi-level
test design (unit → context → end-to-end), so a failure at any level localizes the
regression precisely rather than only proving the outermost behavior:

**T1 — `RoleRegistry.seed_default_platform_role_groups/2` seeds exactly six bindings,
correctly `kind`-tagged, and is idempotent.** Against a freshly-migrated tenant schema
(reuse `test/letflow/tenant_provisioning_test.exs`'s or
`test/letflow/tenant_onboarding_test.exs`'s existing `insert_tenant!`/real-Postgres-schema
fixture helpers, not new ones): call `seed_default_platform_role_groups(prefix: schema)` →
`{:ok, roles}` with `length(roles) == 6`, every `role.kind == :platform_role`, and
`Enum.map(roles, & &1.name) == Enum.map(Letflow.Api.Authorization.roles(), &Atom.to_string/1)`.
Call it a **second time** against the same schema → `{:ok, roles2}` with the identical six
`group_id`s (proves get-or-create-by-name + `upsert_role/4`'s existing idempotency compose
correctly, §2.4) — no duplicate `groups` rows (`Repo.aggregate(Group, :count, prefix:
schema) == 6` after both calls).

**T2 — `sync_role_claims_from_token/3` now succeeds end-to-end once seeding has run,
proving §0's root cause is actually closed, not just that rows exist.** Against the same
seeded schema: build a `User.t()` with `role_claims_synced_at: nil` and an
`IdentityContext.t()` with `roles: ["PLATFORM_ADMIN"]`, call
`sync_role_claims_from_token(user, identity_context, prefix: schema)` directly (unit level,
no HTTP) → returned user has `role_claims_synced_at != nil`, and
`list_effective_role_names(user.id, prefix: schema) == ["PLATFORM_ADMIN"]`. Without T1's
seeding having run first (a sibling assertion, or a separate "before seeding" test case
against an unseeded schema), the identical call must still return `role_claims_synced_at
== nil` and `list_effective_role_names/2 == []` — the explicit before/after contrast that
proves this design is what closes the gap, not a coincidental pass.

**T3 — `TenantOnboarding.provision_and_migrate/1` seeds roles as part of the real
provisioning sequence, no manual `Identity`/`RoleRegistry` call by the test.** Extends
`test/letflow/tenant_onboarding_test.exs`'s existing real-Postgres, sandbox-`:auto`-mode
describe block (same file, same fixture precedent — no new test infrastructure): insert a
tenant, call `provision_and_migrate(tenant.id)` → `{:ok, registration}`, then query
`tenant_role`/`groups` directly (`Repo.all(from t in TenantRole, prefix: registration.schema_name)`)
→ six rows, `kind: :platform_role`, names matching `Authorization.roles/0` — proving the
onboarding orchestration itself performs the seeding, not merely that the seeding function
works in isolation (T1).

**T4 (end-to-end, directly proves the issue's own stated AC) — a freshly-onboarded
tenant's admin user authenticates via OIDC and reaches a `PLATFORM_ADMIN`-gated route,
with zero manual `Letflow.Identity`/`Letflow.Identity.RoleRegistry` bootstrap calls in the
test itself.** New test (`test/letflow/routers/onboarding_test.exs` or a new
`test/letflow/plugs/auth_pipeline_iss0778_test.exs`, colocated with whichever existing file
already owns full-router OIDC-flow fixtures):

1. `POST /api/v1/onboarding` (real router call, `Letflow.Routers.Onboarding.handle_create/1`,
   PLATFORM_ADMIN-authenticated per that route's own existing gate — reuse whatever
   fixture already authenticates a platform-admin caller for this router's other tests) with
   a fresh `slug`/`display_name`/`hostname`, and an `idp_realm_id` this test controls
   (either via a dedicated fixture realm, or REQ-076's realm-binding mechanism — whichever
   `test/letflow/routers/onboarding_test.exs`'s existing fixtures already establish for a
   non-`bpm-default` tenant) → `201`.
2. `Letflow.Oidc.TokenVerifierDouble` gains one new, additive sentinel token (e.g.
   `"valid-test-token-platform-admin"`) whose claims carry `realm_access.roles:
   ["PLATFORM_ADMIN"]` and an `iss` matching step 1's tenant realm — additive only,
   the existing `"valid-test-token"` sentinel and its `["VIEWER"]` claims (relied on by
   REQ-378's own three pre-existing tests, `req378-oidc-live-revocation-check.md` §2.3)
   are **unchanged**.
3. `GET /api/v1/tenants` (or any other route gated on `:TenantsManage`/PLATFORM_ADMIN) with
   `Authorization: Bearer valid-test-token-platform-admin` → `200` (not `403`) — the JIT
   OIDC pipeline provisions the user, `sync_role_claims_from_token/3` fires on that first
   request (marker was `nil`), resolves `"PLATFORM_ADMIN"` against the row T3 proves step 1
   already seeded, and the request succeeds.
4. Explicit negative control, same tenant: the **existing** `"valid-test-token"` sentinel
   (claims `["VIEWER"]`, which matches none of the six seeded platform-role bindings) against
   the same PLATFORM_ADMIN-gated route → `403` — proves T4's step 3 pass is because the
   claimed role genuinely resolved through the seeded binding, not because the route is
   unguarded for this tenant.

No step in T4 calls `Letflow.Identity.add_group_member/3`, `RoleRegistry.upsert_role/4`, or
any other manual bootstrap function directly — every grant the test observes is produced
by the real onboarding-provisioning path (T3's mechanism) plus the real, unmodified OIDC
JIT-sync path (T2's mechanism), exercised together exactly as a real deployment would
exercise them. This is the direct, executable proof of the issue's own stated acceptance
criterion.

## 6. Open questions (explicit, not silently resolved)

- **Fixture mechanics for T4's non-`bpm-default` tenant realm.** This design assumes
  `test/letflow/routers/onboarding_test.exs` (or a sibling file) already has, or can
  straightforwardly extend, a way to onboard a tenant with an `idp_realm_id` other than
  the hardcoded `"bpm-default"` `TokenVerifierDouble` claims map uses today, and to mint a
  second `TokenVerifierDouble` sentinel scoped to that realm. If no such fixture path
  exists yet, TEST-DESIGNER must add the minimal `TokenVerifierDouble` extension (a second
  claims map keyed on a second sentinel token string, additive — see §5 T4 step 2) —
  flagged here rather than assumed away, since this design's own read of
  `test/support/token_verifier_double.ex` found only the single, `bpm-default`-realm,
  `["VIEWER"]`-claiming sentinel that exists today.
- **Should `seed_default_platform_role_groups/1`'s six default groups be renameable/
  deletable by a tenant admin afterward, same as any other `groups` row?** Yes, by
  construction — nothing in this design marks the seeded rows as special, protected, or
  non-deletable (no new column, no flag). This means a tenant admin *could* delete or
  rename the seeded `"PLATFORM_ADMIN"` group after onboarding, which would reopen this
  exact gap for that one tenant by an administrative action rather than a provisioning
  omission. This is flagged, not solved, here: no acceptance criterion in this issue asks
  for a non-deletable seed group, and inventing "protected system groups" as a new concept
  is out of this design's own scope — REVIEWER/SECURITY-REVIEWER should confirm this is
  an acceptable residual (the tenant admin who could delete it is, by definition, already a
  `PLATFORM_ADMIN`-capable actor for that tenant, so this is a self-inflicted foot-gun, not
  a privilege-escalation path).
- **`Letflow.Routers.Tenants.provision_and_respond/2`'s unification (§3.4) is broader than
  the issue's own `affected_files` list** (which names only
  `lib/letflow/tenant_provisioning.ex`, `lib/letflow/identity.ex`,
  `lib/letflow/identity/role_registry.ex`, `priv/repo/seeds.exs`). Flagged explicitly for
  CODE-DESIGN-VALIDATOR/REVIEWER: this design includes it because leaving that call site
  unrouted would leave the identical bug reachable via `POST /api/v1/tenants`, which no
  reading of "close this gap" should accept as still-open scope creep to defer — but since
  it touches a file the issue didn't name, it is called out here rather than silently
  bundled in.
