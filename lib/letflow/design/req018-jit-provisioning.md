# Design: REQ-018 — JIT user provisioning (createOrGetJitOidcUser equivalent)

PROVENANCE (historical, not current decision authority):
**Requirement:** REQ-018 (`docs/requirements.yaml`, stage S1)
**Owner (implementer):** ELIXIR-DEV
**This document produces:** the `Letflow.Oidc.JitProvisioningConfig` struct shape, the
new `Letflow.Identity` context module's function signatures, the exact upsert algorithm
(select-first / INSERT ... ON CONFLICT ... DO NOTHING / re-select-on-conflict), the
changeset field-population rules for every NOT NULL `users` column, and the error shape.
No implementation code — no `.ex`/`.exs` code blocks with real function bodies. Zig/SQL
snippets below are cited evidence (what `jit_provisioning.zig`/`registry.zig` actually
do), not Elixir code to copy verbatim.

## 0. Sources read for this design

- `docs/requirements.yaml` REQ-018 (full entry, `depends_on: [REQ-015, REQ-017]`) —
  description and all four acceptance criteria.
- `docs/requirements.yaml` REQ-015 (full entry — `users` schema/migration shape) and
  REQ-017 (full entry — `Letflow.Oidc.IdentityContext` struct shape) — the two
  dependencies this design integrates against.
- `docs/requirements.yaml` REQ-019, REQ-020, REQ-021 (read for forward context — REQ-018
  must not silently build what those requirements own: tenant/realm resolution,
  role-binding persistence, pipeline wiring).
- `docs/agents/workflows/WF-02_requirement_implementation.md` Step 1 — this design's own
  procedure and acceptance criteria.
- `docs/guides/backend_developer_guide.md` — §3.1 (naming), §3.5 (error handling —
  `{:ok, result} | {:error, reason}`, `@spec` states error shape explicitly), §3.6 (SQL
  always parameterized), §3.7 (migrations), §5 (multi-tenancy — Decision B), §6
  (OIDC/identity — `ueberauth_oidcc` partial adoption).
- `docs/migration/stage-1-identity.md` — S1 scope, inherits 0002/0003.
- `docs/migration/decisions/0002-oidc-integration.md` — explicitly names JIT
  provisioning as "not covered [by any library], custom code required," and cites the
  exact upsert shape (`(tenant_id, external_realm, external_id)`,
  `INSERT ... ON CONFLICT ... DO NOTHING RETURNING ...` with re-select fallback,
  `password_hash = '__OIDC_ONLY__'`, `auth_source = 'oidc'`, per-realm JIT config,
  hard-fail-closed semantics) as the exact behavior this design must reproduce.
- `docs/migration/decisions/0003-ecto-schema-strategy.md` — Decision A (Ecto-idiomatic),
  Decision B (schema-per-tenant, `tenant_id` retained intra-schema, deferred
  provisioning mechanism — REQ-015 targets the single default schema, so this design
  does too; no `prefix:` option anywhere below).
- `lib/letflow/identity/user.ex`, `lib/letflow/identity/tenant.ex` — the Ecto schema
  modules this design writes changeset/context functions against. `user.ex`'s
  moduledoc already states explicitly: "No changeset function is defined here — REQ-018
  ... and REQ-019 ... own the actual changeset functions." Confirmed no changeset exists
  yet on `Letflow.Identity.User` — this design adds the first one.
- `priv/repo/migrations/20260816000004_create_users.exs` — the exact columns/constraints/
  indexes already in place. In particular: `username`/`display_name`/`email`/
  `password_hash`/`tenant_id` are all `null: false` with **no column default** in the
  migration (the `status`/`auth_source` string columns do have DB defaults, but
  `Ecto.Enum`'s Elixir-side `default:` on the schema module covers those already, so this
  design's insert path only needs to explicitly supply the five columns with neither a DB
  default nor an Ecto-schema default: `tenant_id`, `username`, `display_name`, `email`,
  `password_hash`). The partial unique index is named
  `users_external_identity_partial_index` on `(external_realm, external_id) WHERE
  external_id IS NOT NULL` — this is the exact `ON CONFLICT` target this design's upsert
  must match (§3).
- `lib/letflow/oidc/identity_context.ex` — REQ-017's struct. Fields:
  `external_user_id`, `tenant_id`, `realm`, `roles`, `email`, `preferred_username`,
  `display_name`. **Field-name note carried forward explicitly, per this task's
  instruction:** the struct field is `realm` (not `external_realm`) and
  `external_user_id` (not `external_id`) — this design's context module reads FROM
  these two struct field names and writes TO the `users` table's `external_realm`/
  `external_id` columns respectively. No struct field literally named `external_realm`
  or `external_id` exists to read from.
- `lib/letflow/oidc/claim_mapping_config.ex` — existing pattern for a config-sourced,
  per-realm struct with a `for_realm/1` lookup using `Application.fetch_env!/2`, and a
  pure `default/1`-style fallback. `Letflow.Oidc.JitProvisioningConfig` (§1 below)
  follows this exact shape/convention.
PROVENANCE (historical, not current decision authority):
- R-Co source, read directly:
  - `c:\Users\tvolo\dev\ai-dala\R-Co\src\oidc\jit_provisioning.zig` (full file) — the
    orchestration layer. `JitProvisioningConfig` struct (`realm`, `enabled`,
    `default_status`, `default_roles`), `DEFAULT_JIT_CONFIG` constant
    (`enabled: true`, `default_status: .ACTIVE`, `default_roles: &.{}`), the "Key
    invariants" doc comment (idempotent upsert per `(tenant_id, external_realm,
    external_id)`; provisioning failure is a hard failure, auth pipeline MUST NOT
    proceed; JIT config is per-realm not per-tenant).
  - `c:\Users\tvolo\dev\ai-dala\R-Co\src\identity\registry.zig` lines ~806-912 —
    `selectUserByExternalIdentity` (select by `tenant_id` + `external_realm` +
    `external_id`) and `createOrGetJitOidcUser` (select-first / INSERT ... ON CONFLICT
    `(external_realm, external_id) WHERE external_id IS NOT NULL` DO NOTHING / re-select
    on conflict / `error.ExternalIdentityCollision` if the re-select also finds
    nothing). Exact INSERT column list (line 867-878): `tenant_id, email, display_name,
    password_hash, is_active, username, status, auth_source, external_realm,
    external_id` with `password_hash` bound to the literal `"__OIDC_ONLY__"` and
    `auth_source` bound to the literal `'oidc'` (not a bind parameter — hardcoded in the
    SQL text itself, see §3). **R-Co's schema has an `is_active` boolean column**
    (line 872, 882: `is_active = $5::boolean`) that Letflow's `users` table does **not**
    have (confirmed against REQ-015's migration, §0 above) — Letflow uses only `status`
    (`Ecto.Enum` `:active`/`:inactive`). This design does **not** port `is_active` — see
    §4's explicit divergence note.
- `docs/anti-patterns.md` — read in full; no entry yet directly applicable to this
  design (the two existing entries are about toolchain-availability reporting and
  status-file append discipline, not upsert/changeset design).
- `docs/agents/instructions/security-invariants.md` — INV-1 (tenant data isolation —
  APPLIES: every query in this design is scoped by `tenant_id`), INV-7 (no SQL string
  interpolation — APPLIES: this design must state its persistence mechanism precisely,
  §3), INV-8 (no unhandled crashes on realistic failure paths — APPLIES: this design's
  error shape must never let a DB failure or conflict-collision reach an unhandled raise
  on this path, §7).

## 1. `Letflow.Oidc.JitProvisioningConfig` — per-realm JIT config struct

**Placement decision: `lib/letflow/oidc/jit_provisioning_config.ex`, module
`Letflow.Oidc.JitProvisioningConfig`** — not under `lib/letflow/identity/`. Reasoning:
this struct's only consumer-facing role is "per-realm configuration resolved from
`ueberauth_oidcc`'s realm/issuer context before JIT provisioning runs," exactly
mirroring `Letflow.Oidc.ClaimMappingConfig`'s role for claim mapping — both are
config-sourced, per-realm, resolved by the OIDC-facing caller (REQ-021's future pipeline)
and passed into a `Letflow.Identity` function as an already-resolved value. Keeping it in
`Letflow.Oidc` (alongside `ClaimMappingConfig`) rather than `Letflow.Identity` matches
the existing separation this codebase already established: `Letflow.Oidc.*` holds
OIDC-protocol-facing config/data shapes; `Letflow.Identity.*` holds the tenant-owned
persistence layer (schemas, context functions) those shapes feed into. This exactly
parallels how `IdentityContext` (also `Letflow.Oidc`) is produced by the OIDC side and
consumed by `Letflow.Identity`'s JIT function (§2) — `JitProvisioningConfig` is the same
kind of "OIDC-side input to an Identity-side operation" value.

PROVENANCE (historical, not current decision authority):
Ported from `jit_provisioning.zig`'s `JitProvisioningConfig` (lines 108-126) and
`DEFAULT_JIT_CONFIG` (lines 142-147), dropping the `deinit/2` manual-memory-management
function (BEAM GC makes it structurally inapplicable, same reasoning `IdentityContext`'s
design already applied to its own `deinit/2`).

### 1.1 Struct shape

| Field | Zig source field | Elixir type | Notes |
|---|---|---|---|
| `realm` | `realm` | `String.t()` | The realm this config applies to. Same field-naming convention as `ClaimMappingConfig.realm`/`IdentityContext.realm` — always `realm`, never `external_realm`, at every struct boundary in this codebase. |
| `enabled` | `enabled` | `boolean()` | Whether JIT user creation is enabled for this realm. |
| `default_status` | `default_status` | `Letflow.Identity.User.status()` — i.e. `:active \| :inactive`, matching the schema's existing `Ecto.Enum` values (not a separate Elixir enum type; reuses `Letflow.Identity.User`'s own `status` value space rather than inventing a parallel `UserStatus` atom set the way Zig's separate `UserStatus` enum does, since Elixir's `Ecto.Enum` already gives `Letflow.Identity.User.status` a defined value set — see §4.2). | Zig's `UserStatus` is `ACTIVE`/`INACTIVE`; Elixir's `Ecto.Enum` values are lowercase atoms `:active`/`:inactive` — same two-value enum, Elixir-idiomatic casing per `backend_developer_guide.md` §3.1. |
| `default_roles` | `default_roles` | `[String.t()]` | Role slugs to assign to newly provisioned users by default. **Threading/persistence scope — see §6**: this design threads `default_roles` through the return shape only; it does NOT write any role-binding row (no schema exists for that yet — REQ-020 is pending). |

`@type t :: %__MODULE__{realm: String.t(), enabled: boolean(), default_status: :active | :inactive, default_roles: [String.t()]}`

All four fields `@enforce_keys` — a `JitProvisioningConfig` is never partially
constructed, same discipline `IdentityContext`/`ClaimMappingConfig` already establish.

### 1.2 Functions

```
@spec for_realm(realm :: String.t()) :: t()
```
Looks up `realm` in `Application.fetch_env!(:letflow, :oidc_jit_provisioning)` (new,
distinct config key — not nested under `:oidc` (REQ-016's provider-startup config) or
`:oidc_claim_mapping` (REQ-017's claim-path config), for the same separation-of-concerns
reasoning `ClaimMappingConfig`'s design already applied: each config concern gets its own
top-level key rather than conflating provider-startup / claim-mapping / JIT-provisioning
settings under one nested map). If the realm key is present in the configured map,
builds a `%JitProvisioningConfig{}` from that entry's `enabled`/`default_status`/
`default_roles` fields plus `realm: realm`; if absent, falls back to `default(realm)`.

Shape of the new config key (added to `config/dev.exs`/`config/test.exs`, mirroring
`ClaimMappingConfig`'s `config :letflow, :oidc_claim_mapping` precedent):

```
config :letflow, :oidc_jit_provisioning, %{
  "bpm-default" => %{
    enabled: true,
    default_status: :active,
    default_roles: []
  }
}
```

```
@spec default(realm :: String.t()) :: t()
```
Returns the hardcoded default mirroring Zig's `DEFAULT_JIT_CONFIG` (lines 142-147):
`enabled: true`, `default_status: :active`, `default_roles: []`, with `realm: realm`
(the argument) — same deliberate deviation from Zig's literal `.realm = ""` that
`ClaimMappingConfig.default/1` already established (OQ-1 in that design; this design
inherits the same reasoning rather than re-litigating it — flagged again in §8 as this
design's own instance of the same open question). Pure, no I/O — usable directly by
tests and by `for_realm/1`'s fallback branch.

**No DB-backed `jit_provisioning_config` table** — matches REQ-018's own scope note
("same 'no DB-backed per-realm config table required yet' scope note as REQ-017") and
Zig's own `loadJitConfig` (an I/O-performing DB-query function, lines 156-219) is
explicitly **not** ported; only the config *shape* and its `DEFAULT_JIT_CONFIG` fallback
value are.

## 2. `Letflow.Identity` — new top-level context module

**Confirmed by directory listing (§0): no `Letflow.Identity` top-level context module
exists yet.** `lib/letflow/identity/` currently holds only Ecto.Schema modules
(`user.ex`, `tenant.ex`, `group.ex`, `tenant_role.ex`) — no `lib/letflow/identity.ex`.
This design creates `lib/letflow/identity.ex`, module `Letflow.Identity`, as the first
context module for the identity domain — matching this project's established
`Letflow.RowApproval`-style pattern (a top-level context module in `lib/letflow/`,
backed by schema files in a same-named subdirectory: `lib/letflow/row_approval.ex` +
`lib/letflow/row_approval/approval.ex`). `identity-schema.md`'s own §3 already
anticipated this placement ("REQ-018's description already names the consuming context
module `Letflow.Identity`, so this placement anticipates that context module's directory
without creating it").

### 2.1 Entry point function signature

```
@type provisioning_error ::
        :jit_disabled
        | :realm_tenant_mismatch
        | :external_identity_collision
        | Ecto.Changeset.t()
        | term()

@spec provision_oidc_user(
        identity_context :: Letflow.Oidc.IdentityContext.t(),
        tenant_id :: Ecto.UUID.t(),
        jit_config :: Letflow.Oidc.JitProvisioningConfig.t()
      ) :: {:ok, %{user: Letflow.Identity.User.t(), created: boolean()}} |
           {:error, provisioning_error()}
```

Takes REQ-017's `IdentityContext` struct, a `tenant_id` (already resolved by the
caller — REQ-019/021's territory, not this function's — see §2.2), and the resolved
`JitProvisioningConfig` (already looked up via `JitProvisioningConfig.for_realm/1` or
constructed directly by a test — same "caller resolves config, passes the resolved
struct in" convention `ClaimMapping.map_verified_claims/3` already established, so this
function's own call graph doesn't need to read `Application` config itself).

**Why `tenant_id` is a separate argument, not read off `identity_context.tenant_id`:**
`IdentityContext.tenant_id` (per REQ-017's design) is the token-claimed tenant hint,
*not* the resolved, authoritative tenant — REQ-017's own design doc states this
explicitly ("that reconciliation is REQ-019/021's territory, not this design's"). REQ-019
(tenant<->realm binding, pending) is what resolves and validates the authoritative
`tenant_id` before this function is ever called. This design's `provision_oidc_user/3`
trusts its `tenant_id` argument as already-validated — it does not re-derive or
cross-check it against `identity_context.tenant_id` itself (that check, if any, belongs
to REQ-019's realm-ownership guard, called earlier in REQ-021's pipeline order per
REQ-018/019's own descriptions). Stated explicitly here so ELIXIR-DEV doesn't invent a
second tenant-resolution step inside this function.

PROVENANCE (historical, not current decision authority):
### 2.2 Orchestration steps (matching `jit_provisioning.zig`'s orchestration + `registry.zig`'s upsert, composed)

PROVENANCE (historical, not current decision authority):
1. **JIT-disabled check.** If `jit_config.enabled == false`, return
   `{:error, :jit_disabled}` immediately — no DB access at all. This ports
   `JitProvisioningError.JitDisabled` (registry/jit_provisioning's error set,
   §0) as a precondition this design's orchestration function checks before calling the
   upsert, since neither `jit_provisioning.zig`'s `processProvisionResult` nor
   `registry.zig`'s `createOrGetJitOidcUser` itself contains the `enabled` check inline
   in the excerpted source — the caller (R-Co's auth middleware, per
   `jit_provisioning.zig`'s own module doc: "The caller (auth middleware) handles
   loading JIT config, calling identity_service.createOrGetJitOidcUser(), and error
   mapping") is documented as responsible for it. This design's `provision_oidc_user/3`
   plays both roles (orchestrator + upsert caller) in one Elixir function, so it owns
   this check directly rather than pushing it to REQ-021's future pipeline caller —
   flagged as an open question in §8 in case REVIEWER prefers the check to live in
   REQ-021's pipeline instead.
2. **Upsert.** Call the private upsert algorithm (§3) with `tenant_id`,
   `identity_context.realm` (-> `external_realm` column),
   `identity_context.external_user_id` (-> `external_id` column), and the
   field-population values from §4/§5. Returns
   `{:ok, %Letflow.Identity.User{}, created :: boolean()}` or
   `{:error, :external_identity_collision}` or `{:error, %Ecto.Changeset{}}` (changeset
   invalid — e.g. a future validation failure) or a DB-error tuple.
3. **Assemble return value.** On upsert success:
   `{:ok, %{user: user, created: created}}` — matching REQ-018's exact required return
   shape. `default_roles` from `jit_config` is **not** written to any table at this step
   (§6) — it is available to the caller via `jit_config` itself (the caller already has
   it, since the caller passed it in), so this design does not thread it a second time
   through the return map. **Open question flagged in §8**: should `default_roles` also
   appear in the return map for convenience? Not added here since REQ-018's own
   acceptance criteria don't require it and the caller already holds the value.
PROVENANCE (historical, not current decision authority):
4. **Audit event emission — explicitly NOT ported in this requirement.**
   `jit_provisioning.zig`'s `processProvisionResult` emits an audit entry
   (`emitJitProvisionAuditEvent`, INSERT into `audit_entries`) when `created == true`.
   Letflow has no `audit_entries` table yet (not part of REQ-015's schema, not part of
   any `done` requirement) — this design does **not** invent one. Audit emission is
   explicitly out of REQ-018's scope (REQ-018's description and acceptance criteria make
   no mention of an audit trail) and is named here as a deferred/follow-up item, not
   silently dropped — see §8.
PROVENANCE (historical, not current decision authority):
5. **Attribute synchronization — explicitly NOT ported.**
   `jit_provisioning.zig`'s `syncAttributesFromIdentityContext` (OIDC-10 equivalent,
   lines 343-402) is a separate, later requirement's territory (not REQ-018, not listed
   in REQ-018's acceptance criteria, and depends on a `user_roles`/`roles` schema that
   doesn't exist yet either — see §6). This design's `provision_oidc_user/3` only
   performs the create-or-get upsert; it never updates an already-existing user's
   `display_name`/`email`/`status` on a repeat call. Confirmed against REQ-018's own
   acceptance criteria: "calling the provisioning function twice ... returns the same
   user_id both times" — no mention of attribute reconciliation, consistent with
   treating sync as out of scope.

## 3. The upsert algorithm — exact mechanism

**Mechanism decision: `Repo.insert/2` with `on_conflict: :nothing` and an explicit
`conflict_target:` naming the migration's partial index, wrapped by a preceding
`Repo.get_by/2`-equivalent select and a re-select fallback — NOT a raw
`Repo.query/3` string, and NOT `Ecto.Multi`.**

### 3.1 Why `Repo.insert/2` + `on_conflict:`/`conflict_target:`, not raw SQL

PROVENANCE (historical, not current decision authority):
Ecto's `Repo.insert/2` accepts `on_conflict: :nothing` together with
`conflict_target: {:unsafe_fragment, "..."}` or a column-list/index-name form,
translating directly to Postgres's `INSERT ... ON CONFLICT (...) [WHERE ...] DO NOTHING`
— the exact SQL shape `registry.zig`'s `createOrGetJitOidcUser` hand-writes (§0, lines
865-881). Since REQ-015's migration already created the target index as a **named**
partial index (`users_external_identity_partial_index`, on `(external_realm,
external_id) WHERE external_id IS NOT NULL`), the `conflict_target:` option can name that
index directly (`conflict_target: {:constraint, :users_external_identity_partial_index}`
or the equivalent `:unsafe_fragment` form naming the same column/predicate pair — exact
Ecto option ELIXIR-DEV should verify against the installed Ecto/Postgrex version's
documented support for partial-index conflict targets, since Ecto's `conflict_target:`
support for a *named* partial unique index specifically (vs. a plain column list) has
version-dependent nuances — flagged in §8). This keeps every value that reaches SQL
going through Ecto's own parameterization (changeset-built `Repo.insert/2` call, no
`<>`/`"#{}"` string-building of tenant/user-controlled data anywhere) — satisfying INV-7
by construction rather than by manual parameter-binding discipline the way a raw
`Repo.query/3` approach would require. This design explicitly rules out the raw
`Repo.query/3` alternative REQ-018's description itself calls out as needing
justification if chosen — it is not chosen, so no interpolation-safety argument is
needed for that path, but is stated here for CODE-DESIGN-VALIDATOR's confirmation per
REQ-018's own instruction to "state explicitly whether this is implemented via
Ecto.Multi, Repo.insert with on_conflict:/conflict_target: options, or a raw
parameterized Repo.query."

### 3.2 Why not `Ecto.Multi`

PROVENANCE (historical, not current decision authority):
`Ecto.Multi` composes multiple dependent `Repo` operations into one transaction with
named steps — useful when several distinct writes must succeed or fail together. This
upsert is a single logical operation (one conditional insert, with a select-before and
a possible select-after, none of which are separate *writes* that need transactional
composition with each other) — `Ecto.Multi` would add a transaction-and-named-steps
machinery this operation doesn't need. The two selects (before and after the insert
attempt) are read-only and do not need to be inside the same transaction as the insert
for correctness (registry.zig's own C implementation doesn't wrap them in an explicit
transaction either — the `ON CONFLICT ... DO NOTHING` clause is itself the
concurrency-safety mechanism, not an application-level transaction wrapping three
statements). Not using `Ecto.Multi` here is a deliberate simplicity choice, not an
oversight — flagged for REVIEWER's idiom check per this project's general preference for
matching the shape of the actual problem (`backend_developer_guide.md` §3.2's parallel
reasoning for `:gen_statem` vs. plain Ecto applies by the same spirit: don't reach for
heavier machinery when a simpler primitive already fits).

PROVENANCE (historical, not current decision authority):
### 3.3 Algorithm steps (exact, matching `registry.zig` lines 843-912)

```
PROVENANCE (historical, not current decision authority):
1. SELECT-FIRST:
   existing = Repo.get_by(Letflow.Identity.User,
                tenant_id: tenant_id,
                external_realm: identity_context.realm,
                external_id: identity_context.external_user_id)
   -- exact WHERE-clause parity with registry.zig's selectUserByExternalIdentity
      (tenant_id = $1 AND external_realm = $2 AND external_id = $3 LIMIT 1)

   IF existing != nil:
     RETURN {:ok, existing, created: false}

2. INSERT-WITH-CONFLICT-HANDLING:
   changeset = build insert changeset (§4/§5 field population)
   result = Repo.insert(changeset,
              on_conflict: :nothing,
              conflict_target: <the users_external_identity_partial_index target>,
              returning: true)

   -- Repo.insert/2 with on_conflict: :nothing and returning: true yields:
   --   {:ok, %User{id: ...}} when the row-was-actually-inserted (Ecto sets the
   --      struct's fields from the RETURNING clause)
   --   {:ok, %User{id: nil, ...}} -- Ecto/Postgrex-version-dependent signal for
   --      "conflict occurred, nothing inserted, nothing returned" -- ELIXIR-DEV
   --      must verify the exact signal shape (id nil vs. a specific Postgrex
   --      no-rows-returned indicator) against the installed Ecto version and
   --      state which was found, since this is the one place Ecto's on_conflict:
   --      API historically has version-dependent surprises (flagged in §8)
   --   {:error, changeset} -- validation failure BEFORE the insert is even
   --      attempted (e.g. a required field missing at the changeset level)

   IF insert genuinely returned a newly-created row (not a conflict-signal):
     RETURN {:ok, new_user, created: true}

PROVENANCE (historical, not current decision authority):
3. RE-SELECT ON CONFLICT (insert signaled "no row returned" -- conflict happened):
   existing_after_conflict = Repo.get_by(Letflow.Identity.User,
                                tenant_id: tenant_id,
                                external_realm: identity_context.realm,
                                external_id: identity_context.external_user_id)
   -- exact parity with registry.zig lines 907-909

   IF existing_after_conflict != nil:
     RETURN {:ok, existing_after_conflict, created: false}

PROVENANCE (historical, not current decision authority):
4. COLLISION FALLBACK (should not happen under normal operation, but must be handled):
   RETURN {:error, :external_identity_collision}
   -- exact parity with registry.zig line 911: `return error.ExternalIdentityCollision`
```

PROVENANCE (historical, not current decision authority):
This is the full state machine REQ-018's third acceptance criterion asks for
("a simulated concurrent-insert race ... is handled by the re-select fallback without
raising an unhandled exception"). Step 4 is the deliberately-unreachable-in-normal-
operation branch registry.zig itself documents as needing handling (its own
`error.ExternalIdentityCollision` fallback) — this design carries that same defensive
branch forward rather than assuming it can never fire.

**Explicit non-goal:** this design does **not** use a naive "insert, catch
`Ecto.ConstraintError`" pattern — REQ-018's description explicitly forbids this
("do not use a naive 'insert, catch unique-constraint error' pattern instead, since that
changes the concurrency semantics"). The `on_conflict: :nothing` + re-select sequence
above is the only algorithm this design specifies.

## 4. Changeset field population — every NOT NULL `users` column with no default

Per REQ-015's migration (§0), five columns are `null: false` with **no** column-level
default that would let them go unsupplied on insert: `tenant_id`, `username`,
`display_name`, `email`, `password_hash`. (`status` and `auth_source` have DB-level
string defaults *and* `Ecto.Enum` schema-level defaults, so they're covered even if not
explicitly set — but this design sets both explicitly anyway per §5, since JIT-created
rows have a specific required value for `auth_source` that differs from the schema
default.)

### 4.1 Values available from `IdentityContext` (REQ-017's defaulting already applied)

| `IdentityContext` field | Nullability per REQ-017's design | Value semantics |
|---|---|---|
| `preferred_username` | **Never `nil`** — REQ-017's own defaulting rule: missing/wrong-type claim defaults to the `subject` value (i.e. `external_user_id`) | Always a usable string |
| `display_name` | **CAN be `nil`** — REQ-017's defaulting rule: missing/wrong-type claim -> `nil` | May require a fallback (see §4.3) |
| `email` | Never `nil` — REQ-017 defaults missing/wrong-type to `""` | Always a string, possibly empty |
| `external_user_id` | Never `nil` — the one field whose absence is REQ-017's own hard error case (`:sub_claim_missing`), so by the time `provision_oidc_user/3` is called this is guaranteed non-nil/non-empty | Always a usable string |
| `realm` | Never `nil` — always supplied by the caller's resolved `ClaimMappingConfig.realm`, never claim-derived | Always a usable string |

### 4.2 Column-by-column mapping

PROVENANCE (historical, not current decision authority):
| `users` column | Source | Notes |
|---|---|---|
| `tenant_id` | `tenant_id` function argument (§2.1) | Not read from `identity_context.tenant_id` — see §2.1's explicit reasoning. |
| `external_realm` | `identity_context.realm` | Struct field `realm` -> DB column `external_realm` (the field-name divergence REQ-018's description explicitly warns about — confirmed handled correctly here). |
| `external_id` | `identity_context.external_user_id` | Struct field `external_user_id` -> DB column `external_id` (same divergence pattern). |
| `username` | `identity_context.preferred_username` | See §4.4 for the cross-tenant global-uniqueness tension — **flagged as open question, not silently resolved.** |
| `display_name` | `identity_context.display_name`, falling back to `identity_context.preferred_username` when `nil` | See §4.3 — R-Co's own sync logic (this same `jit_provisioning.zig` file, line 359: `claims_display_name = identity_ctx.display_name orelse identity_ctx.preferred_username`) already establishes this exact fallback, cited directly. |
| `email` | `identity_context.email` | Direct copy — REQ-017 already guarantees non-nil (defaults to `""`). `users.email` is `null: false` but Postgres/Ecto has no problem storing an empty string in a `null: false` `:string` column — `""` is not `NULL`. No further fallback needed. |
| `password_hash` | Fixed literal `"__OIDC_ONLY__"` | §5 — set unconditionally, never read from `IdentityContext` (which has no password-related field at all). |
| `status` | `jit_config.default_status` | Not from `IdentityContext` (which has no status field) — from the resolved `JitProvisioningConfig` argument (§1), matching `jit_provisioning.zig`'s own `input.status` sourcing (registry.zig line 859, where `input.status` is itself populated by the orchestrator from `JitProvisioningConfig.default_status` — not shown in the registry.zig excerpt itself, but `jit_provisioning.zig`'s module doc names "default status" as one of the orchestrator's three per-realm JIT config responsibilities). |
| `auth_source` | Fixed literal `:oidc` | §5 — set unconditionally. |

### 4.3 `display_name` fallback — resolved, cited

PROVENANCE (historical, not current decision authority):
**Decision: when `identity_context.display_name` is `nil`, `display_name` is set to
`identity_context.preferred_username`.** This is not invented for this design — it is
directly cited from `jit_provisioning.zig`'s own `syncAttributesFromIdentityContext`
function (line 359, §0): `const claims_display_name = identity_ctx.display_name orelse
identity_ctx.preferred_username;`. Although that specific line lives in the sync
function (OIDC-10, explicitly out of REQ-018's scope per §2.2 point 5), the fallback
*rule* it encodes ("when display_name is absent, fall back to preferred_username") is
the same rule this design applies to the JIT-creation path, since both paths face the
identical constraint: `users.display_name` is `null: false` with no default, and
`IdentityContext.display_name` can be `nil`. This design treats the fallback rule as
portable across both use sites (create-path here, sync-path deferred) since R-Co's own
codebase already establishes it as the project's answer to "what does a nil display_name
become," not something this design guesses independently.

### 4.4 `username` — the cross-tenant collision tension (OPEN QUESTION, not silently resolved)

**The tension, stated precisely:** `identity_context.preferred_username` is the obvious
and only reasonable source value for `users.username` (no other candidate value exists
on `IdentityContext` or in `JitProvisioningConfig` that represents a human-readable
handle). But REQ-015's migration created `unique_index(:users, [:username])` as a
**plain global unique index** — not tenant-scoped (`(tenant_id, username)`) — per
REQ-015's own design doc citing adp-04's Open Question 1 resolution ("Current design
preserves existing global uniqueness for strict backward compatibility"). This means:
**two different tenants' users, both authenticating via OIDC with the same
`preferred_username` claim value (e.g. both have a Keycloak user named `"jdoe"` in their
respective, independent realms), will collide on Letflow's global `username` uniqueness
constraint** — the second tenant's JIT provisioning attempt fails with a unique-
constraint violation on `username`, even though `(tenant_id, external_realm,
external_id)` is different for the two rows and the `ON CONFLICT` target
(`external_realm, external_id`) never fires for this case at all. This is a distinct
failure mode from the race this design's §3 algorithm handles — it is not a conflict
on the `ON CONFLICT` target, so Ecto's `on_conflict: :nothing` does **not** catch it;
`Repo.insert/2` returns `{:error, changeset}` with a `username`-uniqueness constraint
error (assuming the changeset declares `unique_constraint(:username, ...)` so it surfaces
as a changeset error rather than a raised `Ecto.ConstraintError` — INV-8 relevance:
without that changeset-level `unique_constraint/2` declaration, this failure mode would
raise unhandled, which this design explicitly must not allow, so the changeset MUST
declare `unique_constraint(:username)` even though the primary conflict-handling
mechanism is the `ON CONFLICT` target on the other index).

**This design does not resolve the tension by picking a mangling scheme (e.g.
tenant-prefixing the stored username).** Three real options exist and none is free of
consequence:
PROVENANCE (historical, not current decision authority):
- (a) Leave `username` = `preferred_username` verbatim and accept that a second
  tenant's same-named OIDC user fails JIT provisioning with a changeset error (a hard
  failure — consistent with jit_provisioning.zig's Key Invariant 2, "the auth pipeline
  MUST NOT proceed," so this failure mode is at least *safe*, just not
  *available* to the colliding user).
  This is what this design's §4.2 table currently specifies (verbatim
  `preferred_username`), because it requires no invented mangling scheme and is the
  literal reading of REQ-018's own description, which names `preferred_username` as
  "the obvious choice" without instructing a disambiguation transform.
- (b) Change `users.username`'s unique index to be tenant-scoped
  (`(tenant_id, username)`) instead of global — this would resolve the tension
  structurally, but is a schema change to a table REQ-015 already shipped as `done`,
  outside this design's file scope (REQ-015's migration is not something REQ-018 is
  authorized to alter), and would need its own REQ-ANALYST-drafted follow-up requirement
  plus REVIEWER sign-off on revisiting a `done` requirement's schema.
PROVENANCE (historical, not current decision authority):
- (c) Mangle the stored `username` to guarantee uniqueness (e.g.
  `"#{realm}:#{preferred_username}"` or append a short tenant/external-id suffix) —
  not chosen here because REQ-018's description doesn't ask for it, and R-Co's
  `registry.zig` (read directly — the R-Co tree at `c:\Users\tvolo\dev\ai-dala\R-Co`
  is reachable) does not do this either: `input.username` is passed through verbatim,
  not mangled — R-Co apparently has the identical latent global-uniqueness exposure,
  unremarked in the source. Inventing a mangling scheme unilaterally in this design
  would be exactly the kind of
  silent guess REQ-018's own instructions forbid.

**This design picks option (a)** (verbatim `preferred_username`, accept the collision
failure mode as a real but narrow edge case) **as the resolved default for
implementation, while explicitly surfacing this as unresolved policy** for
CODE-DESIGN-VALIDATOR/REVIEWER to weigh in on — option (a) is chosen because it requires
no schema change outside this requirement's authority and matches R-Co's own observed
(if seemingly unremarked) behavior, not because the tension is considered fully closed.
**Open question OQ-3 in §8** asks explicitly whether REVIEWER wants a follow-up
requirement filed for option (b), and whether TEST-DESIGNER should add a test case
demonstrating the option-(a) collision failure mode explicitly (two different tenants,
same `preferred_username`, second JIT provisioning call returns
`{:error, %Ecto.Changeset{}}` with a `username` error) so this known limitation is at
least documented in the test suite rather than silently undiscovered.

## 5. Fixed literals — `password_hash` and `auth_source`

Set **unconditionally** on every insert this function performs (never conditionally, never
read from any input):

PROVENANCE (historical, not current decision authority):
- `password_hash: "__OIDC_ONLY__"` — the exact literal `registry.zig` line 887 uses.
  Never validated as a real hash, never used for authentication (OIDC users authenticate
  via bearer token, not this field) — its only purpose is satisfying `users.password_hash`'s
  `null: false` constraint with an unambiguous sentinel marking "this row has no usable
  local password."
PROVENANCE (historical, not current decision authority):
- `auth_source: :oidc` — the `Ecto.Enum` atom value corresponding to the DB string
  `'oidc'` `registry.zig` line 875 hardcodes directly into the SQL text (not a bind
  parameter in Zig's version either — R-Co's own implementation treats this as a fixed
  literal, matching this design's choice to do the same in the changeset rather than
  accept it as a caller-supplied value).

Both belong in the insert changeset as changeset-level fixed `put_change/3`-equivalent
values, not columns the changeset's caller can override via `cast/3` — no caller of
`provision_oidc_user/3` can cause a JIT-created row to end up with a different
`password_hash` or `auth_source` value. This is a design invariant (§7's invariant list),
not merely an implementation detail.

## 6. `default_roles` — role-binding persistence is explicitly DEFERRED, not built here

**Resolved decision: REQ-018 does NOT write any role-binding row.** Reasoning:

1. REQ-020 (per-tenant role registry, `tenant_role`/`groups` tables) is `pending`, not
   `done` — REQ-018's own `depends_on` is `[REQ-015, REQ-017]` only, not REQ-020.
PROVENANCE (historical, not current decision authority):
2. REQ-015's schema (the only identity schema that exists as of this design) has no
   users<->roles join table at all. `tenant_role` (REQ-015) maps `name -> group_id`, a
   role-name-to-group binding — it is not a per-user role assignment table, and has no
   foreign key or column referencing `users.id`. R-Co's own `registry.zig`/
   `jit_provisioning.zig` reference a `user_roles`/`roles` schema (visible in
   `jit_provisioning.zig`'s `reconcileOidcRoles`, §0 — `INSERT INTO user_roles (user_id,
   role_id, role_source) ...` joining a `roles` table) that has **no Letflow-side
   equivalent in any `done` requirement's schema**.
PROVENANCE (historical, not current decision authority):
3. REQ-018's description explicitly frames `default_roles` as part of
   `JitProvisioningConfig`'s *shape* ("Per-realm JIT config ... default_roles falling
   back to VIEWER ... matching jit_provisioning.zig's JitProvisioningConfig shape") —
   it does not say REQ-018 must *persist* role bindings, and no REQ-018 acceptance
   criterion mentions a role, group, or binding row being created.
4. Per this task's explicit instruction: "Do not invent a users<->roles join table
   that isn't part of any done requirement's schema — if one is needed, name it as an
   explicit open question / follow-up, don't silently build it." This design follows
   that instruction directly.

**What this design does instead:** `default_roles` (with its "empty falls back to
`[\"VIEWER\"]`" rule, §6.1 below) is captured on the `JitProvisioningConfig` struct
(§1) and is available to any caller that already holds the resolved config value (the
same value passed into `provision_oidc_user/3`). `provision_oidc_user/3` itself reads
`jit_config.default_status` (§4.2) but does **not** read or act on
`jit_config.default_roles` at all in this design — no role-binding write happens on
this path.

**Follow-up work this creates (named explicitly, not silently assumed by a later
requirement):** REQ-020 (per-tenant role registry, already `pending` in
`docs/requirements.yaml`) and/or a new REQ-02x are the natural owners of: (a) a
`user_roles`-equivalent join table (or a decision that role assignment in Letflow's
target model works differently from R-Co's `user_roles` shape entirely — not decided
here), and (b) the actual "assign `default_roles` to a newly JIT-provisioned user" logic,
which would need to call into whatever REQ-020/REQ-02x builds. This design does not
propose the join table's shape — that's REQ-020/REQ-02x's design work, not this one's.

### 6.1 `default_roles` empty -> `["VIEWER"]` fallback — where this rule lives

REQ-018's description states: "default_roles falling back to VIEWER when empty." Per
§6's deferral decision, since no role-binding write happens on this path, this
fallback rule is specified as a property of **reading** `JitProvisioningConfig`, not of
`provision_oidc_user/3`'s behavior:

```
@spec default_roles(config :: Letflow.Oidc.JitProvisioningConfig.t()) :: [String.t()]
```

PROVENANCE (historical, not current decision authority):
A small accessor on `Letflow.Oidc.JitProvisioningConfig` (or equivalently, a plain
`if config.default_roles == [], do: ["VIEWER"], else: config.default_roles` at any call
site) that returns `["VIEWER"]` when `config.default_roles` is `[]`, otherwise
`config.default_roles` unchanged — mirroring `jit_provisioning.zig`'s own comment on the
`default_roles` field ("If empty, the user gets no platform roles and defaults to
VIEWER"). Whether this lives as a named function on `JitProvisioningConfig` or is
inlined at whatever future call site persists role bindings is left to that future
requirement's design (ELIXIR-DEV/CODE-DESIGNER for REQ-020/REQ-02x) — this design
specifies the *rule* (empty -> `["VIEWER"]`) since REQ-018's own acceptance-criteria
text names it, but does not mandate exactly which module owns the accessor function
since no code in this requirement's scope actually calls it.

## 7. Error handling — hard-failure semantics (Key Invariant 2)

PROVENANCE (historical, not current decision authority):
Per `jit_provisioning.zig`'s own "Key invariants" §2 ("Provisioning failure is a hard
failure — the auth pipeline MUST NOT proceed") and REQ-018's description ("Provisioning
failure must be a hard failure ... return {:error, reason}, never swallow"):

- `provision_oidc_user/3` **always** returns `{:ok, %{user: _, created: _}}` or
  `{:error, reason}` — never raises on a realistic failure path (JIT-disabled, DB
  connection failure, changeset validation failure including the §4.4 username
  collision, or the `:external_identity_collision` fallback), satisfying INV-8.
- No caller of this function may pattern-match only the `{:ok, _}` branch — REQ-021's
  future pipeline wiring (not this requirement's scope) is the eventual caller
  responsible for treating any `{:error, _}` return as "auth pipeline MUST NOT proceed"
  (fail the request, do not attach an auth context) — this design states the contract
  `provision_oidc_user/3` must uphold on its side (never silently swallow, always
  surface `{:error, reason}`) but does not itself implement REQ-021's pipeline-level
  enforcement of that contract, since REQ-021 is a separate pending requirement.
PROVENANCE (historical, not current decision authority):
- **Full enumerated `provisioning_error()` type** (§2.1's `@type`):
  - `:jit_disabled` — §2.2 step 1.
  - `:realm_tenant_mismatch` — **named for shape-parity with `jit_provisioning.zig`'s
    `JitProvisioningError` set (§0) but NOT produced by any code path in this design.**
    Realm-vs-tenant ownership verification is REQ-019's realm-ownership guard (per
    REQ-018's own description: REQ-019 "port[s] adp-04a's realm-ownership guard ... as a
    function REQ-021's pipeline wiring will call before invoking REQ-018's JIT
    provisioning"). Since REQ-019 runs *before* `provision_oidc_user/3` in REQ-021's
    intended pipeline order, `provision_oidc_user/3` itself never independently checks
    realm/tenant ownership and therefore never returns this atom. Included in the type
    for documentation/forward-compatibility only — flagged explicitly in §8 as
    dead-in-this-requirement, not a silently unstated gap.
  - `:external_identity_collision` — §3.3 step 4.
  - `%Ecto.Changeset{}` — validation failure (includes §4.4's username-collision
    failure mode, and any other changeset-level validation this design's changeset
    declares — e.g. `validate_required/2` on the five NOT NULL columns as a
    belt-and-suspenders check even though the migration already enforces `null: false`
    at the DB level).
  - `term()` — catch-all for a raw DB/connection-level failure surfaced by `Repo.insert/2`
    or `Repo.get_by/2` that isn't a changeset (e.g. `Ecto.QueryError`,
    `DBConnection.ConnectionError` bubbling through `Repo` as an exception rather than a
    typed return — **this is itself a residual INV-8 risk this design flags rather than
    silently assumes away**: `Repo.get_by/2` and `Repo.insert/2` do not universally wrap
    every possible failure as `{:error, _}`; a genuine connection-pool exhaustion, for
    instance, raises `DBConnection.ConnectionError` rather than returning a tuple. This
    design does not add a `try/rescue` around the `Repo` calls to convert such raises
    into `{:error, _}` tuples — doing so would mean deciding a broad exception-handling
    policy this requirement's scope doesn't ask for, and R-Co's own `PoolExhausted`
    error-set members (registry.zig, §0) suggest a real, named failure mode Letflow's
    port has not yet decided how to surface uniformly. **Flagged as open question OQ-4
    in §8** rather than silently choosing "let it crash" or "wrap everything," since
    both are legitimate answers a reviewer should confirm rather than this design
    picking alone.

## 8. Open questions (explicit, not silently resolved)

1. **OQ-1 — `JitProvisioningConfig.default/1`'s `realm` argument vs. Zig's literal
   `""` default (§1.2).** Same deviation `ClaimMappingConfig.default/1` already made
   (its own OQ-1) — this design makes the identical choice for consistency but flags it
   again since it's a fresh instance of the same judgment call, not automatically
   inherited from the earlier sign-off.
PROVENANCE (historical, not current decision authority):
2. **OQ-2 — where does the `enabled == false` short-circuit check belong: inside
   `provision_oidc_user/3` (this design's current choice, §2.2 step 1) or in REQ-021's
   future pipeline caller?** `jit_provisioning.zig`'s own module doc assigns "loading
   JIT config... and error mapping" to the caller (auth middleware), which could be read
   as implying the `enabled` check itself is also the caller's job, not
   `createOrGetJitOidcUser`'s (the Zig upsert function itself has no `enabled` parameter
   or check at all — it's not shown branching on it anywhere in the excerpted source).
   This design chose to fold the check into `provision_oidc_user/3` for cohesion (one
   function call, one place that "provisioning is disabled" is enforced, rather than
   requiring every future caller to remember to check `jit_config.enabled` before
   calling), but flags this as a judgment call REVIEWER should confirm rather than a
   forced port decision.
3. **OQ-3 — the `username` global-uniqueness cross-tenant collision tension (§4.4).**
   This design resolves it as "accept the narrow collision-failure edge case for now
   (option (a)), do not mangle the username, do not change REQ-015's already-`done`
   schema" — but explicitly asks CODE-DESIGN-VALIDATOR/REVIEWER whether (i) this is
   acceptable as REQ-018's shipped behavior, (ii) a follow-up requirement should be
   filed now to make `username`'s uniqueness tenant-scoped, and (iii) TEST-DESIGNER
   should add an explicit test demonstrating the collision failure mode (two tenants,
   same `preferred_username`, second call returns a changeset error) so the limitation
   is documented in the test suite rather than silently unexercised.
4. **OQ-4 — DB/connection-level exceptions that aren't changeset errors (§7).** This
   design does not wrap `Repo.get_by/2`/`Repo.insert/2` calls in `try/rescue` to convert
   raised exceptions (e.g. `DBConnection.ConnectionError` on pool exhaustion) into
   `{:error, _}` tuples — left as a genuine open question on whether INV-8's "no
   unhandled crashes on realistic failure paths" requires that conversion here, or
   whether letting such an exception propagate (and, eventually, crash the calling
   process under its own supervision) is the intended OTP-idiomatic answer for this
   particular call path. Not resolved by this design; flagged for REVIEWER.
5. **OQ-5 — exact `conflict_target:` Ecto option form for a named partial unique index
   (§3.1).** This design specifies the *intent* (`ON CONFLICT` targeting
   `users_external_identity_partial_index`) but flags that Ecto's `conflict_target:`
   API support for referencing a partial unique index **by name** (vs. by column list,
   which does not by itself disambiguate between a plain and partial index sharing the
   same column list, if both existed) has version-dependent shape. ELIXIR-DEV must
   verify the exact syntax against the project's installed `ecto_sql`/`postgrex`
   versions and confirm in the implementation handoff which form was used and that it
   compiles to the correct partial `WHERE external_id IS NOT NULL` predicate — this
   design does not pre-guess the exact option tuple/keyword shape.
6. **OQ-6 — role-binding follow-up requirement (§6).** Not filed as a formal
   `docs/issues/` or `docs/requirements.yaml` entry by this design step (design
   artefacts don't file requirements) — named here explicitly so REQ-ANALYST/ORCH knows
   REQ-020 (or a new REQ-02x) needs to own: a `user_roles`-equivalent schema, and the
   logic to actually persist `default_roles`/`["VIEWER"]` fallback bindings for a
   newly-JIT-provisioned user.
7. **OQ-7 — audit event emission (§2.2 step 4).** Not built in this requirement
   (no `audit_entries` table exists in any `done` requirement's schema). Named as
   follow-up work, likely alongside whatever stage introduces the audit/observability
   surface (R-Co's OBS-03) — not filed formally here, flagged for REQ-ANALYST's
   awareness.

## 9. Testing notes (for TEST-DESIGNER)

REQ-018's acceptance criteria require demonstrating idempotency (criterion 1) and a
simulated concurrent-insert race (criterion 3). Concrete guidance:

- **Idempotency (criterion 1) — directly testable in this environment.** Call
  `Letflow.Identity.provision_oidc_user/3` twice with the same
  `(tenant_id, identity_context.realm, identity_context.external_user_id)` triple
  against a real (or Docker-provisioned) test Postgres. Assert: both calls return the
  same `user.id`; first call's `created` is `true`; second call's `created` is `false`.
  This exercises §3.3 steps 1-2 (second call hits the select-first branch, never reaches
  the insert attempt) — a straightforward sequential ExUnit test, no concurrency
  primitives needed.
- **Concurrent-insert race (criterion 3) — needs genuine concurrency to exercise the
  re-select-on-conflict branch (§3.3 steps 3-4) for real, rather than by inspection
  alone.** A real test of this path requires two concurrent processes/connections both
  reaching the `INSERT ... ON CONFLICT` statement for the *same*
  `(tenant_id, external_realm, external_id)` triple *before either commits* — i.e. two
  database transactions racing, not just two sequential Elixir function calls (which
  would deterministically hit select-first/insert on the first call and select-first/
  found-existing on the second, never touching the conflict branch at all, since Ecto's
  default connection usage is not concurrent within one test process by default).
  Concretely, this needs: two `Task.async/1`-spawned processes, each opening its own
  `Ecto.Repo` checkout (`Repo.checkout/2` or the Sandbox's `:shared`/`:manual` mode
  configured for concurrent access — ExUnit's default `Ecto.Adapters.SQL.Sandbox`
  `:manual` mode with `Sandbox.allow/3` between the test process and each spawned task),
  both calling `provision_oidc_user/3` with identical identity/tenant arguments, with a
  synchronization point (e.g. both tasks paused on a message-receive right after their
  own select-first-returns-nil step, then released simultaneously) forcing both to reach
  the `INSERT ... ON CONFLICT` statement concurrently. This is buildable in this
  environment (Postgres supports genuine concurrent transactions; `Ecto.Adapters.SQL.Sandbox`
  supports multi-process test access), but is meaningfully more elaborate than a
  standard ExUnit test and TEST-DESIGNER should budget for it explicitly rather than
  assuming a simple two-sequential-calls test satisfies criterion 3 (it does not — it
  only exercises the idempotency path, criterion 1, not the actual race).
- **What can only be verified by code-path inspection, not a runnable test:** that the
  `ON CONFLICT` clause's `conflict_target` genuinely matches
  `users_external_identity_partial_index`'s exact column/predicate pair (this is a
  compile-time/migration-time property, not something a passing test row-count alone
  proves — a test could pass "by accident" if, say, `conflict_target:` were pointed at
  the wrong index but happened not to conflict during the test's specific scenario).
  TEST-DESIGNER/REVIEWER should cross-check the actual SQL Ecto generates (e.g. via
  `Ecto.Adapters.SQL.to_sql/3` or a captured query log) against the migration's index
  definition as a supplementary, non-negotiable check alongside the behavioral tests
  above.
- **§4.4's username-collision edge case** — see OQ-3 (§8): recommend TEST-DESIGNER add
  an explicit test for it (two different tenants, same `preferred_username`, second
  provisioning call returns `{:error, %Ecto.Changeset{}}`) regardless of how OQ-3 is
  ultimately resolved, since even if a later requirement fixes the underlying tension,
  today's actual shipped behavior should be pinned by a test.

## 10. Cross-module dependencies

- `Letflow.Identity.provision_oidc_user/3` (this design, §2) depends on:
  - `Letflow.Identity.User` (REQ-015, `done`) — the schema this design adds the first
    changeset function to (§4/§5). This design does not redefine the schema's fields —
    it adds a changeset function alongside the existing schema module (either directly
    in `user.ex` or in the new `lib/letflow/identity.ex` context module — **placement
    choice**: this design recommends the changeset function live in
    `lib/letflow/identity.ex` as a private helper of `provision_oidc_user/3`, or as a
    `Letflow.Identity.User.jit_changeset/2` public function on the schema module itself,
    whichever ELIXIR-DEV finds more consistent with `Letflow.RowApproval.Approval`'s
    existing precedent (checked: `row_approval/approval.ex`'s changeset lives on the
    schema module itself, not the context module) — **this design defers the exact
    placement to ELIXIR-DEV, matching the established `Approval` precedent as the
    default unless a specific reason argues otherwise; not treated as an open question
    since the existing codebase precedent already answers it**).
  - `Letflow.Oidc.IdentityContext` (REQ-017, `done`) — input struct, §0/§4.1.
  - `Letflow.Oidc.JitProvisioningConfig` (this design, §1) — input struct.
  - `Letflow.Repo` — `Repo.get_by/2` (or `Repo.one/2` with an explicit query, either
    satisfies §3.3 step 1/3) and `Repo.insert/2`.
- `Letflow.Oidc.JitProvisioningConfig.for_realm/1` (this design, §1.2) depends on
  `Application.fetch_env!(:letflow, :oidc_jit_provisioning)` — a new config key, added
  to `config/dev.exs`/`config/test.exs`, distinct from REQ-016's `:oidc` and REQ-017's
  `:oidc_claim_mapping` keys.
- **Not depended on by this design:** REQ-019 (tenant<->realm binding), REQ-020 (role
  registry), REQ-021 (pipeline wiring) — all `pending`. This design's
  `provision_oidc_user/3` is callable standalone (e.g. from a test or an `iex` session)
  without any of REQ-019/020/021 existing, per REQ-018's own acceptance criteria
  ("demonstrated with an actual test or iex session").

## 11. Acceptance-criteria traceability

PROVENANCE (historical, not current decision authority):
| REQ-018 acceptance criterion | Concrete design element |
|---|---|
| "calling the provisioning function twice with the same (tenant_id, external_realm, external_id) returns the same user_id both times, with created: true only on the first call — demonstrated with an actual test or iex session, not just described" | §3.3's algorithm (select-first short-circuits the second call); §9's testing guidance for the idempotency test |
| "the inserted row has password_hash set to the fixed OIDC-only marker and auth_source: :oidc" | §5, set unconditionally as fixed changeset values |
| "a simulated concurrent-insert race (two calls racing before either commits) is handled by the re-select fallback without raising an unhandled exception — either demonstrated or the code path is inspected and cited explicitly if concurrency can't be simulated in this environment" | §3.3 steps 3-4 (re-select + collision fallback, never a raw raise); §9's concrete guidance on building a genuine concurrency test in this environment, plus the inspection-only fallback framing if TEST-DESIGNER judges it infeasible |
| "@moduledoc cites src/oidc/jit_provisioning.zig and src/identity/registry.zig's createOrGetJitOidcUser as the ported source" | Instruction to ELIXIR-DEV in §12 below |

Additionally, every element REQ-018's own task instructions (points 1-8 in the routing
prompt) asked this design to resolve is addressed: (1) `JitProvisioningConfig` — §1;
(2) `Letflow.Identity` entry point signature — §2.1; (3) exact upsert algorithm, with
mechanism stated explicitly (`Repo.insert` + `on_conflict:`/`conflict_target:`, not raw
`Repo.query`, not `Ecto.Multi`) — §3; (4) NOT NULL column handling including the
username-collision tension and display_name fallback — §4; (5) fixed literals — §5;
(6) role-binding deferral — §6; (7) hard-failure error shape — §7; (8) concurrency
testing notes — §9.

## 12. Instructions to ELIXIR-DEV (non-code, procedural)

- New files: `lib/letflow/oidc/jit_provisioning_config.ex`
  (`Letflow.Oidc.JitProvisioningConfig`, §1), `lib/letflow/identity.ex`
  (`Letflow.Identity`, §2, first top-level identity context module).
- Modified file: `lib/letflow/identity/user.ex` gains a changeset function (exact
  placement per §10's note — schema-module-local, matching `Approval`'s precedent,
  unless ELIXIR-DEV has a specific reason to place it in the context module instead,
  stated explicitly in the handoff either way).
PROVENANCE (historical, not current decision authority):
- `@moduledoc` on `Letflow.Identity` cites `src/oidc/jit_provisioning.zig` AND
  `src/identity/registry.zig`'s `createOrGetJitOidcUser` explicitly (both — acceptance
  criterion 4 names both files).
PROVENANCE (historical, not current decision authority):
- `@moduledoc` on `Letflow.Oidc.JitProvisioningConfig` cites `src/oidc/jit_provisioning.zig`'s
  `JitProvisioningConfig` struct and `DEFAULT_JIT_CONFIG` constant, and states explicitly
  (matching `ClaimMappingConfig`'s precedent) that no DB-backed per-realm config table is
  built.
- Add `config :letflow, :oidc_jit_provisioning, %{...}` to both `config/dev.exs` and
  `config/test.exs` per §1.2 (test needs at least a `"bpm-default"` entry, or can rely on
  `default/1`'s fallback — ELIXIR-DEV's choice, state which in the handoff).
- No new migration — REQ-015's `users` table (specifically its
  `users_external_identity_partial_index`) already has the exact index this design's
  `ON CONFLICT` target needs; confirmed explicitly in §0/§3.1, not assumed. Confirm
  `mix ecto.migrate` is a no-op for this requirement's own changes (nothing new to
  apply) in the implementation handoff.
- Self-review per `backend_developer_guide.md` §4, plus:
  - Confirm `conflict_target:` genuinely compiles to the partial-index predicate (§8's
    OQ-5) — state the exact Ecto option form used.
  - Confirm the changeset declares `unique_constraint(:username)` so §4.4's collision
    failure mode surfaces as `{:error, changeset}`, not an unhandled raise (INV-8).
  - Confirm `password_hash`/`auth_source` are not accepted via `cast/3` from any
    caller-supplied param map — they must be changeset-internal fixed values (§5).
  - State explicitly in the handoff which of OQ-2 (enabled-check placement) and OQ-4
    (DB-exception wrapping) were left as designed (no code change needed to "resolve"
    them — they're already decided/flagged in this design) vs. anything ELIXIR-DEV found
    that changes this design's assumptions during implementation.
