# Design: REQ-019 — Tenant<->realm binding (OIDC-12/ADP-04b equivalent)

**Requirement:** REQ-019 (`docs/requirements.yaml`, stage S1)
**Owner (implementer):** ELIXIR-DEV
**This document produces:** `Letflow.Identity.Tenant`'s changeset function shapes (create
PROVENANCE (historical, not current decision authority):
+ update), the `resolveTenantByRealm`/`resolveRealmByTenant`-equivalent function
signatures, the realm-ownership guard function signature, and the exact error-shape
composition with REQ-018's already-merged `Letflow.Identity.provision_oidc_user/3`. No
implementation code — no `.ex`/`.exs` code blocks with real function bodies. Zig/SQL
snippets below are cited evidence (what `realm_tenant_binding.zig`/adp-04b actually
specify), not Elixir code to copy verbatim.

## 0. Sources read for this design

- `docs/requirements.yaml` REQ-019 (full entry, `depends_on: [REQ-015]`) — description
  and all four acceptance criteria.
- `docs/requirements.yaml` REQ-015 (full entry — `tenants` schema/migration shape),
  REQ-018 (full entry, `done` — JIT provisioning, for composition), REQ-020 (role
  registry, pending, no direct coupling to this design), REQ-021 (pipeline wiring,
  pending — explicitly names "REQ-019's tenant<->realm resolution + ownership guard"
  called before "REQ-018's JIT provisioning" in its orchestration order).
- `lib/letflow/design/identity-schema.md` §2.1 (`tenants` migration shape — columns,
  indexes, the partial `tenants_idp_realm_id_partial_index`) and §3.1
  (`Letflow.Identity.Tenant` schema — explicitly states "No changeset function is
  defined here — tenant create/update changesets ... belong to REQ-019").
- `lib/letflow/identity/tenant.ex` — confirmed: no changeset function exists yet: the
  module is `use Ecto.Schema` plus a bare `schema/2` block, no `import Ecto.Changeset`,
  no `changeset/2` (or any other changeset-named function). The moduledoc already states
  this design's ownership explicitly (line 26-28: "No changeset function is defined
  here — tenant create/update changesets ... belong to REQ-019").
- `priv/repo/migrations/20260816000001_create_tenants.exs` — confirmed exact shape:
  columns `id` (`:binary_id`, PK), `slug` (`:string`, `null: false`), `display_name`
  (`:string`, `null: false`), `status` (`:string`, `null: false`, `default: "active"`),
  `idp_realm_id` (`:string`, nullable — no `null: false`), plus `timestamps()`.
  `unique_index(:tenants, [:slug])`. `unique_index(:tenants, [:idp_realm_id], where:
  "idp_realm_id IS NOT NULL", name: :tenants_idp_realm_id_partial_index)` — this named
  partial index is REQ-015's already-built DB-level enforcement of "each idp_realm_id
  maps to at most one tenant"; this design's changeset surfaces a violation of it via
  `unique_constraint/2`, it does not re-derive the invariant at a different layer.
PROVENANCE (historical, not current decision authority):
- `lib/letflow/design/req018-jit-provisioning.md` — full file, read as both the style/
  depth template for this document and for its §7 statement that `:realm_tenant_mismatch`
  is "named for shape-parity with `jit_provisioning.zig`'s `JitProvisioningError` set but
  NOT produced by any code path in [REQ-018's] design ... flagged explicitly ... as
  dead-in-this-requirement, not a silently unstated gap" — REQ-018's design explicitly
  reserved this atom for REQ-019/021 to actually produce.
- `lib/letflow/identity.ex` — REQ-018's implementation, `done`/merged. Confirmed:
  `Letflow.Identity` already exists as the identity context module, already declares
  `@type provisioning_error :: :jit_disabled | :realm_tenant_mismatch |
  :external_identity_collision | Ecto.Changeset.t() | term()` (lines 22-27) with
  `:realm_tenant_mismatch` present but unused by any function body in that file —
  confirmed by reading the full module (only `provision_oidc_user/3` and its private
  helpers are defined; none references `:realm_tenant_mismatch`). This design's new
  functions land in this same module (§6).
- `lib/letflow/oidc/identity_context.ex` — REQ-017's `Letflow.Oidc.IdentityContext`
  struct, fields: `external_user_id`, `tenant_id`, `realm`, `roles`, `email`,
  `preferred_username`, `display_name`. `realm` is the field this design's guard
  function's second argument composes against once REQ-021 wires the pipeline (§5).
- `docs/guides/backend_developer_guide.md` §3.1 (naming — snake_case functions,
  PascalCase modules), §3.5 (error handling — every `@spec` states the error shape,
  `{:ok, _} | {:error, _}` shape, no implicit bare pattern match on I/O), §5
  (multi-tenancy — Decision B, schema-per-tenant target model, `tenant_id` retained
  intra-schema; this requirement's tables all target Ecto's single default schema per
  REQ-015 §1's deferral, so nothing here uses `prefix:`).
- `docs/agents/instructions/security-invariants.md` — INV-1 (tenant data isolation),
  INV-7 (no SQL string interpolation), INV-8 (no unhandled crashes) — all three assessed
  explicitly in §9 below, since the realm-ownership guard is itself a security control.
PROVENANCE (historical, not current decision authority):
- R-Co `src/oidc/realm_tenant_binding.zig` (full file) — `resolveTenantByRealm`,
  `resolveRealmByTenant`, their exact SQL (`SELECT ... FROM tenant WHERE idp_realm_id =
  $1 LIMIT 1`; `SELECT idp_realm_id FROM tenant WHERE id = $1::uuid LIMIT 1`), the
  module's "Key invariants" doc comment (5 invariants — one-to-one binding, default
  tenant = `bpm-default`, realm ID immutable after creation, tenant creation requires
  `idp_realm_id`, realm-to-tenant lookup is the authoritative reverse path), and its
  `RealmBindingError`/`LookupError` error sets (`DuplicateRealmBinding`,
  `RealmProvisioningFailed`, `DuplicateTenantSlug`, `NotFound`, `PoolExhausted`,
  `PersistenceFailed`, `OutOfMemory`).
- R-Co `src/design/adp-04b-tenant-realm-binding.md` (full file, 272 lines) — the
  `assertRealmOwnedByTenant` service contract ("called by ADP-04a external identity
  resolution paths before `(external_realm, external_id)` user lookup"), the Key
  invariants section (5 invariants, §2 below), the Error taxonomy
  (`RealmAlreadyBound`, `RealmOwnershipMismatch`, `RealmBindingImmutable`,
  `MissingRealmBinding`, `DefaultTenantRealmMismatch`), and the Forward constraints
  section (non-default tenant insert requires non-empty `idp_realm_id` in OIDC-enabled
  mode; non-default tenant update cannot set `idp_realm_id` to NULL/empty; default
  tenant remains pinned to `bpm-default`).
- R-Co `src/design/adp-04a-external-identity-linkage-user.md` — "Cross-tenant collision
  boundaries" section (lines 172-179), the authoritative source for this design's guard
  function: realm ownership is tenant-scoped by OIDC-12/ADP-04b; identity resolution
  requires tenant context, no global `(realm, sub)` lookup without tenant scoping;
  service contracts reject provisioning if the token's tenant context doesn't match the
  tenant bound to `external_realm`; no username/email fallback matching.
- Confirmed by search: no `priv/repo/seeds.exs` exists, and no `.ex`/`.exs` file anywhere
  in the repo references `DEFAULT_TENANT` or the literal `"bpm-default"` as a tenant
  identifier (the only 4 files matching `bpm-default` are `config/dev.exs`,
  `config/test.exs`, and two test files — `jit_provisioning_config_test.exs` and
  `claim_mapping_test.exs` — all of which use `"bpm-default"` purely as a **realm
  string** in `Letflow.Oidc.ClaimMappingConfig`/`Letflow.Oidc.JitProvisioningConfig`
  per-realm config maps, not as a tenant row or seed). This grounds §4's decision.

## 1. Placement decision (answers task point 6)

**All four new functions — `resolve_tenant_by_realm/1`, `resolve_realm_by_tenant/1`,
`verify_realm_ownership/2`, and the two changeset functions
(`create_changeset/2`/`update_changeset/2`) — are added to the existing
`Letflow.Identity` context module (`lib/letflow/identity.ex`), alongside REQ-018's
`provision_oidc_user/3`. The changesets themselves are defined on the schema module,
`Letflow.Identity.Tenant` (`lib/letflow/identity/tenant.ex`).**

Reasoning:

1. **Query/lookup functions on the context module.** `resolve_tenant_by_realm/1`,
   `resolve_realm_by_tenant/1`, and `verify_realm_ownership/2` are all
   `Letflow.Repo`-touching operations exactly like REQ-018's `provision_oidc_user/3` —
   they belong on the context module per this project's established
   `Letflow.RowApproval`/`Letflow.Identity` pattern (a top-level context module holding
   `Repo`-calling public functions, backed by schema files that hold no `Repo` calls
   themselves). `Letflow.Identity` already exists (REQ-018) specifically as this
   project's identity context module — there is no reason to create a second context
   module for the same `tenants` table REQ-018's design already treats as a sibling
   concern to `users`.
2. **Changesets on the schema module.** REQ-018's design (§10) resolved the equivalent
   placement question for `Letflow.Identity.User`'s changeset by citing
   `Letflow.RowApproval.Approval`'s existing precedent: "checked: `row_approval/
   approval.ex`'s changeset lives on the schema module itself, not the context module."
   This design follows that same established precedent for `Letflow.Identity.Tenant`:
   `create_changeset/2` and `update_changeset/2` are public functions on
   `Letflow.Identity.Tenant` (`lib/letflow/identity/tenant.ex`), and
   `Letflow.Identity`'s own functions (`resolve_tenant_by_realm/1`, etc.) call them
   rather than duplicating changeset logic inline. This is consistent, not
   case-by-case: every changeset in this codebase's identity concern lives on its
   schema module (`Tenant`, and by REQ-018's own placement choice, `User`), while every
   `Repo`-touching orchestration function lives on `Letflow.Identity`.
3. This matches REQ-018's own §10 explicit statement that placement questions of this
   exact shape are "not treated as an open question since the existing codebase
   precedent already answers it" — this design applies the same precedent rather than
   re-litigating it.

**File-level summary:**

| File | Module | New functions |
|---|---|---|
| `lib/letflow/identity/tenant.ex` | `Letflow.Identity.Tenant` | `create_changeset/2`, `update_changeset/2` |
| `lib/letflow/identity.ex` | `Letflow.Identity` | `resolve_tenant_by_realm/1`, `resolve_realm_by_tenant/1`, `verify_realm_ownership/2`, plus (recommended, not required — see §6.3) thin `create_tenant/1`/`update_tenant/2` wrappers |

No new files. No new migration — REQ-015's `tenants` table (specifically
`tenants_idp_realm_id_partial_index`) already has the exact index this design's
changeset needs to name via `unique_constraint/2` (§3).

PROVENANCE (historical, not current decision authority):
## 2. Key invariants this design enforces (source: adp-04b + realm_tenant_binding.zig)

Restated here as the design's own checklist, each mapped to where it's enforced below:

1. **One-to-one binding** — each tenant has at most one `idp_realm_id`; each
   `idp_realm_id` maps to at most one tenant. Enforced at the DB level by REQ-015's
   `tenants_idp_realm_id_partial_index` (already built); surfaced cleanly at the
   application level by this design's changeset (§3).
2. **Default tenant binding** — `idp_realm_id = "bpm-default"` for the default tenant.
   Enforced/demonstrated per §4 (no seed exists; this is a changeset-level rule plus a
   test fixture, not a migration).
3. **Realm ID immutable after creation** — no update path changes an existing tenant's
   `idp_realm_id`. Enforced structurally by `update_changeset/2`'s field list (§3.3).
4. **Tenant creation requires `idp_realm_id`** (adp-04b: conditional on OIDC-enabled
   mode for non-default tenants) — enforced by `create_changeset/2` per §3.2's exact
   conditional rule.
5. **Realm-to-tenant lookup is the authoritative reverse path** — `resolve_tenant_by_realm/1`
   is what REQ-021's future pipeline calls to resolve the authoritative tenant from a
   token's realm claim; nothing resolves tenant identity from a client-supplied
   `tenant_id` claim directly (that value, per REQ-018's design §2.1, is only ever a
   "token-claimed hint," never trusted directly).

## 3. `Letflow.Identity.Tenant` changesets (answers task points 2 and 3)

### 3.1 Why two separate changeset functions, not one shared `changeset/2`

`idp_realm_id` immutability (invariant 3, §2) is enforced by **structurally omitting
`idp_realm_id` from `update_changeset/2`'s allowed-fields list** — the approach REQ-019's
own acceptance criteria explicitly names as one of the two acceptable options ("the
changeset simply omits idp_realm_id from its allowed fields"). This is the option this
design picks (over "cast it but always reject the change with a changeset error"),
because it makes the immutability invariant structurally true rather than dependent on a
runtime check that could be forgotten or bypassed by a future editor of the update path —
there is no field in `update_changeset/2`'s `cast/3` list that could ever carry a value
into `idp_realm_id`, so no validation function is needed to reject an attempted change
that structurally cannot occur. This must be stated explicitly in `Letflow.Identity.Tenant`'s
moduledoc per REQ-019's own acceptance criterion ("whichever approach is taken, it's
stated explicitly in the moduledoc") — see §10's instruction to ELIXIR-DEV.

**No dedicated admin-only rotation function is added by this design.** Reasoning: R-Co's
own adp-04b names this as its own explicit open question (OQ-1: "Should realm-binding
immutability for non-default tenants be strict (no updates) or allow controlled rotation
via a dedicated admin operation?") — R-Co itself has not resolved this, so there is no
ported behavior to reproduce. REQ-019's acceptance criteria list four items, none of
which mention a rotation function, and the routing prompt for this design explicitly
says: "Recommend NOT building a rotation function (out of REQ-019's acceptance criteria,
adds scope) unless you find a concrete reason to." No concrete reason surfaced during
this design's research (no downstream requirement — REQ-020, REQ-021 — mentions realm
rotation). **Decision: no rotation function is built.** This is stated explicitly in the
moduledoc (§10) so the immutability path is not left ambiguously reachable through any
other route — `idp_realm_id`, once set at creation, has no code path in this batch that
can ever change it again.

### 3.2 `create_changeset/2`

```
@spec create_changeset(tenant :: %Tenant{}, attrs :: map()) :: Ecto.Changeset.t()
```

- `cast/3` fields: `:slug`, `:display_name`, `:status`, `:idp_realm_id`.
- `validate_required/2`: `:slug`, `:display_name` always required.
  `:idp_realm_id` is **conditionally** required — see the conditional rule below, not an
  unconditional `validate_required(:idp_realm_id)`.
- `validate_length/3` or equivalent on `:slug` — not specified further here (REQ-019's
  acceptance criteria don't ask for slug-format validation beyond what REQ-015's schema
  already implies); left to ELIXIR-DEV's judgment as a non-load-bearing detail, matching
  this design's role of not inventing unrequested validation rules.
- **Conditional `idp_realm_id`-required rule (adp-04b's Forward Constraints, "Non-default
  tenant insert requires non-empty idp_realm_id"):** this rule is conditional on
  *OIDC-enabled mode*, a runtime config value — exactly the same reasoning REQ-015's own
  migration design already applied to explain why this can't be a DB CHECK constraint
  (identity-schema.md §2.1: "conditional on runtime OIDC-mode config, which a
  migration-time CHECK constraint cannot see"). This design's `create_changeset/2` does
  **not** unconditionally require `idp_realm_id` for every non-default tenant — doing so
  would hardcode "OIDC is always enabled" into the changeset, contradicting adp-04b's own
  conditional framing and REQ-015's explicit deferral of this exact rule to REQ-019.
  Instead: **`create_changeset/2` accepts an explicit `oidc_mode :: :enabled |
  :disabled` argument (making the real signature `create_changeset(tenant, attrs,
  oidc_mode)`, three arguments, not two — see the note below), and validates
  `idp_realm_id` as required only when `oidc_mode == :enabled` and the row being created
  is not the default tenant (§4's marker check).** When `oidc_mode == :disabled`,
  `idp_realm_id` remains fully optional at the changeset level (nullable at the column
  level per REQ-015, and no changeset-level requirement either) — matching adp-04b's own
  "OIDC-disabled compatibility: creating tenant without idp_realm_id remains allowed
  before OIDC enablement" testability note.
  **Revised signature:**
  ```
  @spec create_changeset(tenant :: %Tenant{}, attrs :: map(), oidc_mode :: :enabled | :disabled) ::
          Ecto.Changeset.t()
  ```
  **Open question flagged (§8, OQ-1):** where does `oidc_mode` come from at the actual
  call site? No `docs/migration/decisions/` record or `done` requirement establishes a
  concrete OIDC-mode config key yet (REQ-016 configures a single realm/issuer but does
  not define a global enabled/disabled toggle). This design specifies the changeset's
  *shape* (an explicit argument, not a hidden `Application.get_env` read inside the
  changeset — changesets should stay pure/testable, matching this project's established
  preference for config resolved by the caller and passed in, e.g.
  `JitProvisioningConfig.for_realm/1`'s caller-resolves-then-passes-in convention from
  REQ-018's design §2.1) but does not invent the config key itself, since none of
  REQ-019's four acceptance criteria require a real OIDC-mode toggle to exist yet — see
  §8 for the full open question and §9's testing-notes guidance on how TEST-DESIGNER
  should supply this argument directly (`:enabled`/`:disabled` literals) rather than
  waiting on a config key that doesn't exist yet.
- `unique_constraint(:slug)` — surfaces REQ-015's `unique_index(:tenants, [:slug])`
  violation as a changeset error.
- `unique_constraint(:idp_realm_id, name: :tenants_idp_realm_id_partial_index)` —
  surfaces REQ-015's partial unique index violation as a clean `{:error, changeset}`
  rather than an unhandled `Ecto.ConstraintError` (INV-8 — this is the exact mechanism
  task point 2 asks for). This is the application-level surface of invariant 1 (§2) —
  the DB index is the actual enforcement; this `unique_constraint/2` declaration is what
  makes a violation of it observable as a typed changeset error instead of a raised
  exception.
- **Default-tenant pinning validation** (invariant 2, §2): if the row being created is
  identified as the default tenant (§4's marker), `idp_realm_id` must equal exactly
  `"bpm-default"` — a `validate_change/3` (or equivalent) checking this specific
  conditional rule. See §4 for exactly how "is this the default tenant" is determined,
  since no reserved-ID/reserved-slug mechanism currently exists in this codebase to
  answer that question structurally.

### 3.3 `update_changeset/2`

```
@spec update_changeset(tenant :: %Tenant{}, attrs :: map()) :: Ecto.Changeset.t()
```

- `cast/3` fields: `:display_name`, `:status` **only**. `:slug` and `:idp_realm_id` are
  both **structurally absent** from this list.
  - `:idp_realm_id`'s absence is invariant 3 (§2) — immutability, per §3.1's reasoning.
  - `:slug`'s absence is not asked for by REQ-019's acceptance criteria, but is
    consistent with treating a tenant's identity-defining fields (`slug`, `idp_realm_id`)
    as create-time-only — **flagged as an open question (§8, OQ-2)** since REQ-019 never
    explicitly discusses `slug` mutability either way; this design defaults to excluding
    it from the same conservative instinct that governs `idp_realm_id`, but this is a
    judgment call, not a cited requirement, so it's named explicitly rather than silently
    bundled into the `idp_realm_id` decision as if REQ-019 asked for both.
- `validate_required/2`: `:display_name` (already required at the DB level and should
  stay non-blankable via update).
- No `unique_constraint(:idp_realm_id, ...)` needed on this changeset — the column can
  never be set here, so a constraint violation on it can never occur via this path.
- `unique_constraint(:slug)` — retained defensively even though `slug` isn't in the
  `cast/3` list, in case a future edit adds it back; costs nothing to declare and
  matches this project's general precedent of declaring `unique_constraint/2` for every
  DB-level unique index a schema's changesets could plausibly hit (see REQ-018's design
  §12 instruction: "Confirm the changeset declares `unique_constraint(:username)`").
  **Not load-bearing today** since `:slug` cannot reach the changeset via `cast/3` —
  named for completeness, not a functional requirement.

## 4. Default-tenant pinning — how "the default tenant" is identified (answers task point 4)

**Confirmed by search (§0): no `priv/repo/seeds.exs` exists, and no `.ex`/`.exs` file in
this repo defines a reserved default-tenant UUID (R-Co's `DEFAULT_TENANT_ID`, the
all-zero UUID) or a reserved slug constant anywhere.** This gap is real, not an artifact
of incomplete search — REQ-015 (the schema/migration requirement) did not build a seed,
and its own acceptance criteria never mention one.

**Decision: this design adds a reserved-slug marker, `"bpm-default"`, as the "is this the
default tenant" check — NOT a reserved all-zero UUID.**

Reasoning:

1. R-Co's own `DEFAULT_TENANT_ID` (`00000000-0000-0000-0000-000000000000`) is a
   Zig-side compile-time constant checked against `tenant_id` fields typed as raw
   `[16]u8`. Letflow's `Tenant.id` is a `binary_id` **autogenerated by Ecto**
   (`@primary_key {:id, :binary_id, autogenerate: true}`, per `identity-schema.md` §3
   and the existing `tenant.ex`) — nothing in this codebase inserts a tenant row with an
   explicit, caller-chosen ID today. Porting the all-zero-UUID convention would require
   either (a) special-casing tenant creation to sometimes accept a caller-supplied ID
   (a schema/changeset change beyond this design's scope — `id` is not in either
   changeset's `cast/3` list, and should not be, since allowing a caller to choose a
   primary key is a different and larger design decision this requirement doesn't ask
   for), or (b) hardcoding the all-zero UUID as a special constant compared against an
   autogenerated field that will never actually equal it under normal `Repo.insert/2`
   usage — which would make the "is this the default tenant" check permanently false
   for any tenant actually created through this design's own `create_changeset/2` path.
   Neither option is workable without scope beyond REQ-019.
2. `slug` is the one column REQ-015's schema already establishes as a stable,
   human-assigned, globally-unique identifier (`unique_index(:tenants, [:slug])`) —
   exactly the kind of field suited to carrying a reserved, well-known value. A reserved
   slug (`"bpm-default"`, the same string as the realm ID itself, chosen for
   memorability and because R-Co's own realm ID for the default tenant is already this
   exact string) is checkable with a plain string comparison inside `Ecto.Changeset`
   validation logic, with no schema change and no special-cased ID-assignment path.
3. **Concrete rule:** `create_changeset/2`'s default-tenant pinning validation (§3.2)
   checks `get_field(changeset, :slug) == "bpm-default"` (not `id`). If true, the
   validation added there requires `idp_realm_id == "bpm-default"` exactly (invariant 2).
   If false (any other slug), the conditional-required rule (§3.2) applies instead
   (required-if-`oidc_mode == :enabled`, optional otherwise) with no additional
   "must equal a specific string" constraint.

**What "seeded with the default tenant (bpm-default)" means operationally, per REQ-019's
own acceptance criterion wording** ("tested with the seeded default tenant
(bpm-default)"): **this design does NOT add a `priv/repo/seeds.exs` file or any
migration that inserts a default tenant row.** REQ-015 (the schema requirement) did not
build a seed, and REQ-019's own scope per its description is "functions + changesets,"
not database bootstrapping. "Seeded," in the context this design operates in, means:
**TEST-DESIGNER constructs a fixture tenant row via `create_changeset/2` +
`Repo.insert/1` with `slug: "bpm-default"`, `idp_realm_id: "bpm-default"`** (and
`oidc_mode: :enabled` or `:disabled`, either satisfies the default-tenant pinning rule
since that rule is unconditional on `oidc_mode` — see §3.2), inside the test's own
setup, per-test, not a shared seeded fixture. See §11 for the exact testing guidance.

**Flagged explicitly, not silently decided (§8, OQ-3):** whether Letflow should
eventually add a real `priv/repo/seeds.exs` that inserts a genuine default tenant row
(so a running `mix run --no-halt` instance has one out of the box, matching R-Co's own
migration-time backfill behavior for the reserved tenant row) is a real question this
design does not resolve — it is out of REQ-019's stated scope (no acceptance criterion
asks for a seed file) and no other `done`/`pending` requirement claims it either. Named
as a candidate follow-up requirement, not silently built here and not silently assumed
unnecessary.

## 5. `resolve_tenant_by_realm/1` and `resolve_realm_by_tenant/1` (answers task point 1)

### 5.1 `resolve_tenant_by_realm/1`

```
@spec resolve_tenant_by_realm(idp_realm_id :: String.t()) ::
        {:ok, Tenant.t()} | {:error, :not_found}
```

PROVENANCE (historical, not current decision authority):
Queries `Letflow.Identity.Tenant` via `Repo.get_by(Tenant, idp_realm_id: idp_realm_id)`
— exact `WHERE`-clause parity with `realm_tenant_binding.zig`'s `resolveTenantByRealm`
(`SELECT ... FROM tenant WHERE idp_realm_id = $1 LIMIT 1`, §0). Returns `{:ok, tenant}`
if a row matches, `{:error, :not_found}` otherwise.

**Return-shape justification against R-Co's `NotFound`/`LookupError`:** R-Co's version
returns a Zig error union with four possible error members (`NotFound`, `PoolExhausted`,
`PersistenceFailed`, `OutOfMemory`) — three of which (`PoolExhausted`,
`PersistenceFailed`, `OutOfMemory`) are infrastructure-level failures Zig's manual
connection-pool/allocator model must represent explicitly, but which Ecto/Postgrex
represent differently: a genuine connection failure surfaces as a raised exception
(`DBConnection.ConnectionError` or similar) through `Repo.get_by/2`, not as a returned
error value — this is the same "residual INV-8 risk" REQ-018's design already flagged
and explicitly declined to wrap in `try/rescue` (its own OQ-4, §7 of that design). This
design makes the identical choice for consistency: `resolve_tenant_by_realm/1`'s typed
error is `:not_found` only (the one error condition Ecto's `Repo.get_by/2` itself
distinguishes as "found nothing" rather than "raised") — a genuine DB/connection failure
is not caught and converted, it propagates as a raised exception, matching REQ-018's own
precedent rather than introducing a different failure-handling policy for a sibling
function in the same module. This is restated as an explicit open question in §8 (OQ-4)
rather than silently assumed, mirroring REQ-018's own OQ-4 treatment.

### 5.2 `resolve_realm_by_tenant/1`

```
@spec resolve_realm_by_tenant(tenant_id :: Ecto.UUID.t()) ::
        {:ok, String.t() | nil} | {:error, :not_found}
```

PROVENANCE (historical, not current decision authority):
Queries `Letflow.Identity.Tenant` via `Repo.get(Tenant, tenant_id)` — exact parity with
`realm_tenant_binding.zig`'s `resolveRealmByTenant` (`SELECT idp_realm_id FROM tenant
WHERE id = $1::uuid LIMIT 1`, §0). If no tenant with that ID exists: `{:error,
:not_found}`. **If the tenant exists but has no bound realm (`idp_realm_id` is `nil` at
the column level): `{:ok, nil}`** — this is a deliberate divergence from
`realm_tenant_binding.zig`'s own Zig signature, which returns `![]const u8` (a realm
string or an error, no null case shown in the excerpted function body) because Zig's
version of this function is not shown handling a null `idp_realm_id` explicitly in the
row-mapping code (§0's source: `.idp_realm_id = try allocator.dupe(u8, row_data[3]
orelse return error.PersistenceFailed)` — the Zig code actually treats a null
`idp_realm_id` as `PersistenceFailed`, an error, not as a legitimate "no realm bound"
state). This design does **not** port that specific behavior, because REQ-015's own
schema explicitly allows `idp_realm_id` to be `NULL` for any non-default tenant when
OIDC is disabled (§3.2's conditional-required rule) — a tenant genuinely having no bound
realm is a normal, expected state in Letflow's model, not a persistence failure. Treating
it as `{:ok, nil}` (a successful lookup that reports "no realm bound," distinguishable
from `{:error, :not_found}`, "no such tenant") is the correct application of this
function's own contract given REQ-015's nullable column, and is exactly the return shape
§6 below needs to distinguish "tenant not found" from "tenant found but has no realm
bound" for the guard function's edge cases. **Named explicitly as a deliberate divergence
from the literal Zig behavior, not a silent choice** — flagged again in §8 (OQ-5) for
REVIEWER's awareness.

## 6. `verify_realm_ownership/2` — the realm-ownership guard (answers task point 5)

```
@spec verify_realm_ownership(tenant_id :: Ecto.UUID.t(), external_realm :: String.t()) ::
        :ok | {:error, :realm_tenant_mismatch} | {:error, :not_found}
```

This is the function that enforces adp-04a's "Cross-tenant collision boundaries" §1 and
§3 (§0): verifies that a token's claimed `external_realm` actually maps to the
already-resolved `tenant_id`, before any `(external_realm, external_id)` user lookup
(REQ-018's `provision_oidc_user/3`) proceeds.

### 6.1 Behavior — every edge case, stated exactly

1. **Tenant not found** (`tenant_id` doesn't correspond to any row in `tenants`):
   `{:error, :not_found}`. This is a distinct outcome from a realm mismatch — a caller
   reaching this function with a `tenant_id` that doesn't exist at all indicates a
   deeper pipeline bug (the caller should have already failed at the
   `resolve_tenant_by_realm/1` step, §5.1, before ever reaching this guard), but this
   function does not assume that can't happen and returns a typed error rather than
   crashing (INV-8).
2. **Tenant found, `idp_realm_id` is `nil`** (tenant exists but has no realm bound at
   all — a legitimate state per §5.2 for an OIDC-disabled non-default tenant, or any
   tenant created before OIDC was enabled for it): `{:error, :realm_tenant_mismatch}`.
   Reasoning: a tenant with no bound realm cannot, by definition, "own" any
   `external_realm` value — including matching against `nil` itself (an OIDC token
   always carries a real, non-nil realm claim per REQ-017's `IdentityContext.realm`
   typing, which is never `nil`; there is no legitimate scenario where `external_realm ==
   nil` is the value being checked). Reusing `:realm_tenant_mismatch` for this case
   (rather than inventing a third atom) keeps the guard's public error vocabulary to
   exactly the two outcomes REQ-018's design already reserved shape-parity for
   (`:not_found` is new — not reserved by REQ-018 — but `:realm_tenant_mismatch` is
   exactly the reserved atom, reused here as instructed).
3. **Realm matches** (`tenant.idp_realm_id == external_realm`): `:ok`.
4. **Realm doesn't match** (`tenant.idp_realm_id` is a non-nil string different from
   `external_realm`): `{:error, :realm_tenant_mismatch}`.

### 6.2 Trust boundary — re-queries the DB directly, does not trust a caller-supplied realm

**Decision: `verify_realm_ownership/2` re-queries the tenant's bound realm from the
database itself (via `resolve_realm_by_tenant/1`, §5.2) rather than accepting a
pre-resolved `idp_realm_id` value as a third argument.**

Reasoning, given the explicit trade-off named in this task's routing prompt:

- **Against trusting a caller-passed value** (the pattern `provision_oidc_user/3`
  itself uses for `tenant_id` — REQ-018's design §2.1 explicitly trusts its `tenant_id`
  argument as "already-resolved/authoritative," not re-derived): that precedent is
  correct for `provision_oidc_user/3` specifically because REQ-018's design states
  plainly that realm/tenant ownership verification is *this* function's job, performed
  *earlier* in the pipeline — `provision_oidc_user/3` is allowed to trust its `tenant_id`
  argument precisely because something else (this guard) is supposed to have already
  verified it. That reasoning cannot apply reflexively to the verifier itself: if
  `verify_realm_ownership/2` also trusted a caller-supplied "this is the tenant's real
  realm" value instead of reading the authoritative column, the guard would be
  verifying the caller's own claim against itself — a no-op that provides no actual
  security boundary. A security **guard** function's entire purpose is to be the one
  place that doesn't trust the caller's assertion; the caller's assertion (the token's
  `external_realm` claim) is exactly the untrusted input the guard exists to check
  *against* an independently-fetched authoritative value.
- Concretely: `verify_realm_ownership(tenant_id, external_realm)` takes the
  already-resolved `tenant_id` (trusted, per the same reasoning `provision_oidc_user/3`
  already applies — resolving *which tenant* is REQ-021's earlier pipeline step, calling
  `resolve_tenant_by_realm/1`, §5.1) and the token-claimed `external_realm` (untrusted —
  this is literally the value under test), and independently fetches
  `tenant.idp_realm_id` itself via `resolve_realm_by_tenant/1` rather than accepting it
  as a third argument from the same caller that's also supplying the value being
  checked.
- Cost: one extra DB query per guard call (the `resolve_realm_by_tenant/1` call inside
  `verify_realm_ownership/2`), on top of whatever query `resolve_tenant_by_realm/1`
  already ran earlier in the pipeline to resolve `tenant_id` in the first place. This is
  the safer default explicitly recommended by this task's routing prompt for a security
  control, and is a single indexed primary-key lookup (`Repo.get/2` on `tenants.id`) —
  not a meaningfully expensive cost for a per-request auth-pipeline check.
- **This does NOT mean `verify_realm_ownership/2` re-derives `tenant_id` from
  `external_realm` from scratch** (i.e. it does not call `resolve_tenant_by_realm/1`
  internally) — that would duplicate the earlier pipeline step entirely and defeat the
  purpose of taking an already-resolved `tenant_id` as an argument at all. It performs
  exactly one query: "what realm is this given tenant_id bound to," then compares.

### 6.3 Composition with REQ-021's future pipeline

Per this task's explicit instruction and REQ-019's own acceptance criteria: this
function must be called by REQ-021's future pipeline **before**
`Letflow.Identity.provision_oidc_user/3` runs, using an already-resolved `tenant_id`
(from `resolve_tenant_by_realm/1`, called earlier in the same pipeline) plus
`identity_context.realm` (REQ-017's struct field, §0). The intended REQ-021 pipeline
order (verify token -> resolve tenant from realm -> **guard realm ownership** -> JIT
provision/lookup user -> attach auth context), per REQ-021's own `docs/requirements.yaml`
description, is:

1. `{:ok, tenant} = Letflow.Identity.resolve_tenant_by_realm(identity_context.realm)`
2. `:ok = Letflow.Identity.verify_realm_ownership(tenant.id, identity_context.realm)`
3. `{:ok, %{user: user, created: _}} = Letflow.Identity.provision_oidc_user(identity_context, tenant.id, jit_config)`

Step 2 looks redundant with step 1 at first glance (both involve `identity_context.realm`
and the tenant just resolved from it) — this is intentional, not an oversight this design
failed to notice: step 1 resolves *which* tenant a realm belongs to (a lookup); step 2
verifies that the *specific* tenant now in hand still, authoritatively, owns that exact
realm at the moment of the check (a guard). For a single-realm-per-tenant system with no
concurrent realm-rebinding possible in this batch (immutability, invariant 3, means a
tenant's `idp_realm_id` cannot change after creation), steps 1 and 2 are logically
guaranteed to agree in the common case — but the guard exists as a defense-in-depth
control per adp-04a's own explicit boundary language ("Service contracts reject
provisioning if the incoming token tenant context does not match the tenant bound to
external_realm"), not merely as a redundant restatement of step 1's own lookup. This
composition point is stated explicitly here so REQ-021's design doesn't need to re-derive
why both calls are needed.

## 7. Error type composition with REQ-018 (answers task point 7)

**Decision: this design's new functions do NOT return errors under
`Letflow.Identity.provisioning_error()`. They introduce their own error atoms
(`:not_found`, reused `:realm_tenant_mismatch`) returned directly as plain `{:error,
atom}` tuples from their own `@spec`s, not wrapped in or unioned with
`provisioning_error()`.**

Reasoning:

- `provisioning_error()` is `provision_oidc_user/3`'s own return-type name — semantically
  scoped to "things that can go wrong during JIT provisioning," which is a narrower
  concern than "things that can go wrong resolving/verifying a tenant<->realm binding."
  `resolve_tenant_by_realm/1` and `resolve_realm_by_tenant/1` are called independently
  of provisioning (`resolve_realm_by_tenant/1`'s own R-Co precedent — "called during
  realm provisioning (OIDC-14) and during admin operations" — has nothing to do with JIT
  user provisioning at all), so tying their error type name to `provisioning_error()`
  would misname a general tenant/realm-lookup facility after one narrow caller.
- **`:realm_tenant_mismatch` is the one atom that IS explicitly shared** — reused
  verbatim from `provisioning_error()`'s existing enumeration (REQ-018's design §7
  already named this exact atom and reserved it for this design to produce), not
  renamed to something new. This is the composition point: `verify_realm_ownership/2`
  is the first and only function in this codebase that actually returns
  `{:error, :realm_tenant_mismatch}` — `provision_oidc_user/3` itself still never
  produces it (REQ-018's design confirmed this and this design does not change that;
  `provision_oidc_user/3`'s own source is unmodified by this design, per §1's "no
  existing file beyond `tenant.ex`/`identity.ex` additions"). The atom is shared
  *vocabulary*, not a shared *type alias* — a future REQ-021 pipeline function that
  wraps both this design's guard and REQ-018's provisioning call under one combined
  error type is exactly the kind of "several distinct error sources composed into one
  pipeline-level error type" decision that belongs to REQ-021's own design, not this
  one. This design does not pre-guess REQ-021's error-composition shape.
- `Letflow.Identity`'s existing `@type provisioning_error()` in `lib/letflow/identity.ex`
  is **not edited by this design** — it already contains `:realm_tenant_mismatch`
  (dead code, per REQ-018's design), and this design does not need to add anything to it
  since its own new functions define their own `@spec` return types directly rather than
  reusing that name. **Flagged explicitly, not silently decided (§8, OQ-6):** should a
  later cleanup rename `provisioning_error()` to something broader (e.g.
  `identity_error()`) once REQ-021 actually composes multiple sources under one type?
  Not decided here — out of this design's scope, named for REQ-021's design to weigh in
  on.

## 8. Open questions (explicit, not silently resolved)

1. **OQ-1 — where does `oidc_mode` (the `:enabled | :disabled` argument to
   `create_changeset/3`, §3.2) come from at the real call site?** No config key or
   decision record establishes a global OIDC-enabled/disabled toggle yet. This design
   specifies the changeset's shape (explicit argument, caller-resolved) but does not
   invent the config key itself. Whichever future requirement wires real tenant-creation
   HTTP handling (likely S4, or an admin-onboarding requirement referenced in the S1
   section header's "Onboarding's tenant-creation admin flow ... deferred past this
   batch") must resolve `oidc_mode` from real config and pass it in. TEST-DESIGNER should
   pass `:enabled`/`:disabled` literals directly in tests (§11) rather than waiting on
   this.
2. **OQ-2 — should `slug` be mutable via `update_changeset/2`?** REQ-019's acceptance
   criteria only discuss `idp_realm_id` immutability; `slug` mutability is not addressed
   by the requirement text at all. This design defaults to excluding `slug` from
   `update_changeset/2`'s `cast/3` list (treating both identity-defining fields as
   create-time-only) but flags this as a judgment call, not a cited requirement — REVIEWER
   should confirm or override.
3. **OQ-3 — should a real `priv/repo/seeds.exs` inserting an actual default-tenant row be
   built, so a running instance has one without relying on tests to construct it?** Not
   built by this design (§4) — no acceptance criterion asks for it, no `done`/`pending`
   requirement claims it. Named as a candidate follow-up requirement.
4. **OQ-4 — `resolve_tenant_by_realm/1`'s error shape covers only `:not_found`, not a
   distinct representation of pool-exhaustion/persistence-failure the way R-Co's
   `LookupError` does.** This design deliberately does not wrap `Repo.get_by/2` in
   `try/rescue` to convert a raised connection-level exception into a typed error tuple —
   matching REQ-018's own OQ-4 precedent (same unresolved question, restated here for
   this design's own functions) rather than silently picking a different policy for a
   sibling function in the same module. Left for REVIEWER to confirm project-wide.
PROVENANCE (historical, not current decision authority):
5. **OQ-5 — `resolve_realm_by_tenant/1`'s `{:ok, nil}` return for a tenant with no bound
   realm is a deliberate divergence from `realm_tenant_binding.zig`'s literal behavior**
   (which treats a null `idp_realm_id` as `PersistenceFailed`, an error). This design's
   choice is justified in §5.2 against REQ-015's schema (nullable `idp_realm_id` is a
   legitimate state), but is flagged explicitly since it is a divergence from the cited
   R-Co source, not a literal port.
6. **OQ-6 — should `Letflow.Identity.provisioning_error()` eventually be renamed/broadened
   once REQ-021 composes this design's guard errors with REQ-018's provisioning errors
   under one pipeline-level type?** Not decided here (§7) — left for REQ-021's design.

## 9. Security invariants — explicit assessment (INV-1, INV-7, INV-8)

Stated explicitly per this task's instruction, so SECURITY-REVIEWER's later gate is
straightforward rather than reconstructed from scratch.

**INV-1 (tenant data isolation) — APPLIES, satisfied.** `verify_realm_ownership/2` is
itself the mechanism by which REQ-021's future pipeline prevents a request whose token
claims one tenant's realm from being processed under a different tenant's `tenant_id` —
this is precisely a tenant-isolation control, not merely adjacent to one. Every query
this design specifies (`resolve_tenant_by_realm/1`, `resolve_realm_by_tenant/1`) reads
from the `tenants` table only, keyed by either `idp_realm_id` or the primary key `id` —
neither queries or returns any other tenant's business data, and neither accepts a
tenant-scoping parameter that could be spoofed to read cross-tenant rows (there is no
tenant-scoped *business* data involved in this design at all; `tenants` itself is the
one table with no `tenant_id` column, being the tenant boundary's own definition table).
The guard function's entire purpose (§6) is enforcing that a resolved `tenant_id` and a
token's claimed `external_realm` actually correspond, which is the specific check
adp-04a's "Cross-tenant collision boundaries" §1/§3 (§0) names as required before any
`(external_realm, external_id)` lookup (REQ-018's territory) proceeds — this design
supplies that check; REQ-021 is responsible for actually calling it in the right order
(§6.3), which is outside this design's own implementation surface but is stated
explicitly as a requirement on REQ-021's design.

**INV-7 (no SQL string interpolation) — APPLIES, satisfied by construction.** Every
query this design specifies goes through `Ecto.Repo`'s parameterized API
(`Repo.get_by/2`, `Repo.get/2`) — no `Repo.query/3` raw SQL, no string-built SQL
anywhere in this design. `idp_realm_id`, `tenant_id`, and `external_realm` values (all
tenant/token-controlled) are passed as plain Elixir term arguments to `Repo.get_by/2`'s
keyword-list form, which Ecto compiles to parameterized queries by construction — the
same reasoning REQ-018's design §3.1 already applied to its own `Repo.insert/2` usage.

**INV-8 (no unhandled crashes) — APPLIES, satisfied with one flagged residual risk
matching REQ-018's own precedent.** `resolve_tenant_by_realm/1`,
`resolve_realm_by_tenant/1`, and `verify_realm_ownership/2` all return typed
`{:ok, _} | {:error, atom}` tuples for every *expected* failure mode (not-found, no
realm bound, realm mismatch) — none of these raise. The changesets (§3) declare
`unique_constraint/2` for both unique indexes their `cast/3` fields can reach, so a
concurrent-creation collision on `slug` or `idp_realm_id` surfaces as `{:error,
changeset}`, not an unhandled `Ecto.ConstraintError` — this is the exact mechanism task
point 2 requires. The one residual risk, stated explicitly rather than silently assumed
away (matching REQ-018's own OQ-4 precedent, §8 OQ-4 above): a genuine DB
connection-level failure (pool exhaustion, connection drop) inside any `Repo` call in
this design is not caught and converted to a typed tuple — it propagates as a raised
exception. This design does not resolve that open question differently from how REQ-018
already left it open; it is restated here so SECURITY-REVIEWER evaluates both designs'
functions under one consistent policy rather than discovering two different unstated
answers to the same question.

## 10. Instructions to ELIXIR-DEV (non-code, procedural)

- Modified file: `lib/letflow/identity/tenant.ex` gains `create_changeset/3` (note: 3
  arguments per §3.2's revision, not 2 — `tenant`, `attrs`, `oidc_mode`) and
  `update_changeset/2`. Moduledoc must state explicitly (per REQ-019's own acceptance
  criterion wording): (a) that `idp_realm_id` is immutable after creation because
  `update_changeset/2` structurally omits it from `cast/3`'s field list, not because of
  a runtime rejection check; (b) that no dedicated admin-only rotation function is
  built in this requirement, and why (§3.1); (c) that `create_changeset/3` takes an
  explicit `oidc_mode` argument rather than reading OIDC-enabled state from
  `Application` config itself, and that no config key for this currently exists (§8,
  OQ-1).
PROVENANCE (historical, not current decision authority):
- Modified file: `lib/letflow/identity.ex` gains `resolve_tenant_by_realm/1`,
  `resolve_realm_by_tenant/1`, `verify_realm_ownership/2`. `@moduledoc` (already
  present from REQ-018) should gain a note citing `src/oidc/realm_tenant_binding.zig`
  and `src/design/adp-04b-tenant-realm-binding.md`/`adp-04a-external-identity-linkage-user.md`
  as this design's additional ported sources, alongside the existing REQ-018 citations —
  do not remove or restate REQ-018's own citations, append to them.
- No new migration. Confirm `mix ecto.migrate` is a no-op for this requirement's own
  changes (REQ-015's `tenants_idp_realm_id_partial_index` already exists) in the
  implementation handoff.
- Self-review per `backend_developer_guide.md` §4, plus:
  - Confirm `update_changeset/2`'s `cast/3` list genuinely does not include
    `:idp_realm_id` (grep the actual `cast(tenant, attrs, [...])` call in the diff).
  - Confirm `create_changeset/3`'s conditional `idp_realm_id`-required validation only
    fires when `oidc_mode == :enabled` and the tenant is not the default
    (`slug == "bpm-default"`) — not an unconditional `validate_required(:idp_realm_id)`.
  - Confirm `unique_constraint(:idp_realm_id, name: :tenants_idp_realm_id_partial_index)`
    genuinely names REQ-015's actual index (grep the migration file's index name and
    confirm it matches character-for-character).
  - Confirm `verify_realm_ownership/2` calls `resolve_realm_by_tenant/1` internally
    (re-queries) rather than accepting a pre-resolved realm as a third argument (§6.2).
  - State explicitly in the handoff whether `Letflow.Identity`'s existing
    `provisioning_error()` type was left unmodified (§7 says it should be).

## 11. Testing notes for TEST-DESIGNER

- **Default-tenant fixture construction (§4).** Do not write or rely on a
  `priv/repo/seeds.exs` file — none exists and this design does not add one. Per test
  (or per test module's `setup`), construct the fixture directly:
  `Letflow.Identity.Tenant.create_changeset(%Tenant{}, %{slug: "bpm-default",
  display_name: "Default Tenant", idp_realm_id: "bpm-default"}, :enabled) |>
  Repo.insert()` (or `:disabled` — the default-tenant pinning rule in §3.2 applies
  either way, since it's unconditional on `oidc_mode`). Use a unique, test-scoped value
  only if multiple tests in the same run need distinct default-tenant rows in the same
  database — but note `slug: "bpm-default"` is itself meant to be the one reserved
  value, so most tests should treat "the default tenant" as a single fixture built once
  per test's own isolated transaction (ExUnit's `Ecto.Adapters.SQL.Sandbox` gives each
  test its own transaction/rollback, so a hardcoded `"bpm-default"` slug across multiple
  tests does not collide as long as each test runs in its own sandboxed transaction —
  confirm this project's existing test setup already does this, matching REQ-018's own
  test precedent).
- **Immutability enforcement.** Build a tenant via `create_changeset/3` with a real
  `idp_realm_id`, persist it, then call `update_changeset/2` with an attrs map
  containing an `idp_realm_id` key set to a *different* value. Assert: the resulting
  changeset's `idp_realm_id` change is not present at all (`Ecto.Changeset.get_change/2`
  returns `nil`, not an error — because the field was never cast in the first place, so
  there is nothing to reject; this is a different observable outcome than "changeset has
  an error on :idp_realm_id," and the test should assert the correct one: no change
  captured, not a validation error). After `Repo.update/1`, assert the persisted row's
  `idp_realm_id` is unchanged from its original value.
- **One-to-one collision rejection.** Two tenants, sequential (not necessarily
  concurrent — REQ-019's acceptance criterion says "attempting to bind a second tenant
  to an already-bound idp_realm_id is rejected," which does not require a genuine race
  the way REQ-018's criterion 3 explicitly did): create tenant A with `idp_realm_id:
  "realm-x"`, persist successfully. Attempt to create tenant B with the same
  `idp_realm_id: "realm-x"` via `create_changeset/3` + `Repo.insert/1`. Assert:
  `{:error, changeset}` with an error on `:idp_realm_id` (via the
  `unique_constraint(:idp_realm_id, name: :tenants_idp_realm_id_partial_index)`
  declaration, §3.2) — not a raised `Ecto.ConstraintError` (INV-8). If TEST-DESIGNER
  additionally wants to demonstrate the genuine-race case (two concurrent
  `Repo.insert/1` calls hitting the partial index simultaneously), the same
  `Task.async/1` + `Ecto.Adapters.SQL.Sandbox` multi-process technique REQ-018's design
  §9 already details for its own concurrency test applies here structurally identically
  — not repeated in full here, cite that section's technique directly.
- **Realm-ownership guard — every branch (§6.1).** Four separate test cases:
  1. *Match*: tenant with `idp_realm_id: "realm-x"`, call
     `verify_realm_ownership(tenant.id, "realm-x")`, assert `:ok`.
  2. *Mismatch*: same tenant, call `verify_realm_ownership(tenant.id, "realm-y")`,
     assert `{:error, :realm_tenant_mismatch}`.
  3. *Tenant not found*: call `verify_realm_ownership(Ecto.UUID.generate(), "realm-x")`
     with a UUID that matches no row, assert `{:error, :not_found}`.
  4. *Tenant with nil idp_realm_id*: create a tenant with `idp_realm_id: nil` (a
     non-default tenant, `oidc_mode: :disabled` at creation so the conditional-required
     rule doesn't block it, §3.2), call `verify_realm_ownership(tenant.id, "realm-x")`,
     assert `{:error, :realm_tenant_mismatch}` (§6.1 case 2 — not `:not_found`, since
     the tenant does exist; not `:ok`, since a nil-realm tenant cannot own any realm).
- **`resolve_tenant_by_realm/1`/`resolve_realm_by_tenant/1` — basic coverage.** Both
  functions tested directly against the default-tenant fixture (satisfies REQ-019's
  first acceptance criterion's "tested with the seeded default tenant" wording) plus a
  not-found case each (`resolve_tenant_by_realm("nonexistent-realm")` ->
  `{:error, :not_found}`; `resolve_realm_by_tenant(Ecto.UUID.generate())` ->
  `{:error, :not_found}`), plus `resolve_realm_by_tenant/1`'s `{:ok, nil}` case for a
  tenant with no bound realm (§5.2's deliberate divergence — this is exactly the kind of
  behavior a test should pin, per this project's general practice of testing documented
  divergences from the ported source explicitly).

## 12. Acceptance-criteria traceability

| REQ-019 acceptance criterion | Concrete design element |
|---|---|
| "resolveTenantByRealm(idp_realm_id) and resolveRealmByTenant(tenant_id) both work against REQ-015's tenants table, tested with the seeded default tenant (bpm-default)" | §5.1/§5.2, exact `@spec`s and query mechanism against `Letflow.Identity.Tenant`; §4 for what "seeded" means operationally (test-constructed fixture, no real seed file); §11's testing guidance names the default-tenant fixture explicitly as the required test subject |
| "attempting to bind a second tenant to an already-bound idp_realm_id is rejected (unique index or explicit changeset validation), not silently overwritten" | §3.2's `unique_constraint(:idp_realm_id, name: :tenants_idp_realm_id_partial_index)`, surfacing REQ-015's already-built partial unique index as a clean `{:error, changeset}`; §11's collision-rejection testing guidance |
| "attempting to change an existing tenant's idp_realm_id via the normal update changeset is rejected or the changeset simply omits idp_realm_id from its allowed fields — whichever approach is taken, it's stated explicitly in the moduledoc" | §3.1/§3.3: `update_changeset/2` structurally omits `:idp_realm_id` from its `cast/3` field list (the "omits from allowed fields" option, chosen explicitly over a runtime-rejection check); §10 instructs ELIXIR-DEV to state this explicitly in the moduledoc |
| "a realm-ownership guard function exists that rejects a (tenant_id, external_realm) pair where external_realm is not the realm bound to tenant_id" | §6, `verify_realm_ownership/2`'s full `@spec` and all four edge-case behaviors (match/mismatch/not-found/nil-realm), §6.2's re-query trust-boundary decision, §6.3's REQ-021 composition order |

Additionally, every element this task's routing prompt asked this design to resolve is
addressed: (1) `resolveTenantByRealm`/`resolveRealmByTenant` signatures — §5; (2)
one-to-one invariant enforcement mechanism — §3.2, §9 (INV-8 assessment); (3)
`idp_realm_id` immutability approach, rotation-function decision — §3.1, §3.3; (4)
default-tenant pinning mechanism given no seed exists — §4; (5) realm-ownership guard
exact behavior and trust-boundary decision — §6; (6) function placement — §1; (7) error
type composition with REQ-018 — §7.
