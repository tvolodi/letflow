# Design: REQ-020 — Per-tenant role registry (TenantRoleStore/IDN-05 equivalent)

**Requirement:** REQ-020 (`docs/requirements.yaml`, stage S1)
**Owner (implementer):** ELIXIR-DEV
**This document produces:** module placement, three public function signatures
(`list_roles`, `upsert_role`, `resolve_role_in_tx`), the upsert transaction shape, the
validation design (name + group_id), the DB-schema confirmation, and the no-OIDC-coupling
invariant. No implementation code — no `.ex`/`.exs` code blocks with real function
bodies. Signatures, type shapes, and prose only.

## 0. Sources read for this design

- `docs/requirements.yaml` REQ-020 (full entry, `depends_on: [REQ-015]`) — description
  and all 5 acceptance criteria.
- `docs/guides/backend_developer_guide.md` — §2 (project structure: top-level context
  module + same-named schema subdirectory), §3.1 (naming), §3.5 (error handling —
  `{:ok,_}|{:error,_}` shape, every `@spec` states the error shape), §3.6 (SQL always
  parameterized), §5 (multi-tenancy, Decision B).
- `docs/migration/stage-1-identity.md` — S1 scope, confirms REQ-020 inherits 0002/0003
  as-is.
- `docs/migration/decisions/0003-ecto-schema-strategy.md` Decision A (Ecto-idiomatic:
  `binary_id` PK, `Ecto.Enum` for status columns) and Decision B (schema-per-tenant via
  Ecto `:prefix`/dynamic-repo, `tenant_id` retained intra-schema — not yet built, see
  below).
- `lib/letflow/identity.ex` — the existing `Letflow.Identity` context module (REQ-018/019,
  `done`/merged). Confirmed: top-level context module in `lib/letflow/`, backed by schema
  files under `lib/letflow/identity/`. Every `Repo`-touching public function lives here
  today (`provision_oidc_user/3`, `resolve_tenant_by_realm/1`, `resolve_realm_by_tenant/1`,
  `verify_realm_ownership/2`). No function in this module imports or references
  `tenant_role` or `groups`.
- `lib/letflow/identity/tenant_role.ex` — the existing `Letflow.Identity.TenantRole`
  Ecto schema (REQ-015, `done`). Confirmed fields: `name` (`:string`), `group_id`
  (`Ecto.UUID`), `timestamps(updated_at: false)` (so `inserted_at` only, no `updated_at`).
  `@primary_key {:id, :binary_id, autogenerate: true}`. No changeset function defined —
  moduledoc states explicitly "REQ-020 owns `list_roles`/`upsert_role` and their
  validation logic." Moduledoc also already states the global-unique-index-standing-in-
  for-per-tenant-schema deferral and the group_id FK rationale — both restated in §7
  below with the actual migration file as the primary citation.
- `lib/letflow/identity/group.ex` — the existing `Letflow.Identity.Group` Ecto schema
  (REQ-015, `done`). Confirmed fields: `tenant_id` (`Ecto.UUID`), `name` (`:string`),
  `timestamps()`. No changeset function defined, no requirement in the REQ-015..021 batch
  owns `groups` CRUD.
- `priv/repo/migrations/20260816000003_create_tenant_role.exs` — confirmed exact DB
  shape: `tenant_role(id binary_id PK, name string NOT NULL, group_id binary_id NOT NULL
  references(:groups, type: :binary_id), inserted_at, updated_at)` wait — actually
  `timestamps(updated_at: false)` at the schema layer but the migration itself calls
  plain `timestamps(updated_at: false)` too (confirmed: migration line 28 is
  `timestamps(updated_at: false)`, so only `inserted_at` exists at the DB level, matching
  the schema). `create unique_index(:tenant_role, [:name])` (line 31). `create
  index(:tenant_role, [:group_id])` (line 32). The `group_id` column is declared via
  `add :group_id, references(:groups, type: :binary_id), null: false` (line 26) — this
  is a real DB-level foreign key to `groups.id`, confirmed directly from the migration
  source, not inferred.
- `priv/repo/migrations/20260816000002_create_groups.exs` — confirmed: `groups(id
  binary_id PK, tenant_id binary_id NOT NULL, name string NOT NULL, inserted_at,
  updated_at)`, `create index(:groups, [:tenant_id])`. No unique constraint on `name` or
  `(tenant_id, name)` — group-name uniqueness is explicitly left undecided by REQ-015
  (per `lib/letflow/design/identity-schema.md` §2.3's open question, flagged there for
  REQ-020 to decide "when it implements `upsert_role`'s group-existence check" — resolved
  in §4.2 below: this design does NOT add a uniqueness rule for `groups.name`, since
  REQ-020's own acceptance criteria only require a group **existence** check, not a
  group-name-uniqueness rule, and inventing one here would be scope creep onto a table
  this requirement doesn't own).
- `lib/letflow/design/identity-schema.md` §2.4, §3.4 — REQ-015's own design doc for
  `tenant_role`/`groups`, confirming the same FK/index facts as the migration file
  itself and the "REQ-020 owns list_roles/upsert_role" ownership statement.
PROVENANCE (historical, not current decision authority):
- `C:\Users\tvolo\dev\ai-dala\R-Co\src\identity\role_registry.zig` (full file) —
  `TenantRoleStore.listRoles`, `TenantRoleStore.upsertRole`, `resolveRoleInTx`,
  `isValidRoleName`, `isValidUuidHex`, `TenantRoleError` error set (`GroupNotFound`,
  `RoleNameInvalid`, `GroupIdInvalid`, `PoolExhausted`, `PersistenceFailed`,
  `OutOfMemory`).
PROVENANCE (historical, not current decision authority):
- `C:\Users\tvolo\dev\ai-dala\R-Co\src\design\idn05-role-registry.md` — full file, read
  closely per task instruction: §3 "Public interface — TenantRoleStore" (exact SQL for
  all three functions, the upsert's BEGIN/existence-check/INSERT-ON-CONFLICT/COMMIT
  sequence, `resolveRoleInTx`'s "any DB error → return null" rule) and §10 "Security
  invariants" (no SQL interpolation; tenant isolation via schema — explicitly N/A here,
  see §5 below; authorization enforced before store calls — out of REQ-020's scope, an
  S4 API-layer concern; role resolution is read-only and non-fatal). Also read §1
  (schema — confirms R-Co's `REFERENCES groups(id) ON DELETE RESTRICT`, matching what
  Letflow's migration actually has), §9 "Dependencies" ("Must NOT depend on:
  `src/engine/transition.zig`... any module that performs HTTP calls" — the R-Co-side
  statement of the same no-coupling invariant task point 5 asks this design to restate
  for Letflow's OIDC pipeline), §11 "Open questions" (OQ-3's role-name-constraint
  recommendation, already reflected in REQ-020's own description text).
- `docs/agents/instructions/security-invariants.md` — INV-7 (no SQL string
  interpolation), INV-8 (no unhandled crashes) assessed explicitly in §9 below.
- Confirmed by reading `lib/letflow/oidc/*.ex` (4 files: `claim_mapping.ex`,
  `claim_mapping_config.ex`, `identity_context.ex`, `jit_provisioning_config.ex`) and
  `lib/letflow/identity.ex` in full: no existing module anywhere in `lib/letflow/`
  references `tenant_role` or `Group`, and no existing `Letflow.Oidc.*` module or
  `Letflow.Identity.provision_oidc_user/3` is referenced by anything this design adds —
  grounds §5's coupling-boundary statement in an actual negative-search result, not an
  assumption.

## 1. Module placement — DECISION: new `Letflow.Identity.RoleRegistry` module

**Decision: REQ-020's three functions (`list_roles`, `upsert_role`,
`resolve_role_in_tx`) live in a new top-level context module,
`lib/letflow/identity/role_registry.ex` → `Letflow.Identity.RoleRegistry` — NOT added to
the existing `Letflow.Identity` context module.**

Reasoning:

PROVENANCE (historical, not current decision authority):
1. **REQ-020's own description text names the target explicitly**: "Port
   `src/identity/role_registry.zig`'s `TenantRoleStore` (`list_roles`, `upsert_role`) and
   `resolveRoleInTx` as **`Letflow.Identity.RoleRegistry` functions**." This is not
   ambiguous phrasing to interpret — it is a literal module name. The routing prompt for
   this design task defaults to this name "unless you find a strong reason not to," and
   no such reason surfaced during this design's research.
PROVENANCE (historical, not current decision authority):
2. **R-Co's own source structure supports a standalone module.** `role_registry.zig` is
   a standalone file (not folded into `registry.zig`, R-Co's general identity-table
   module) with its own top-of-file doc comment declaring it as the whole implementation
   of IDN-05: `TenantRoleStore` + `resolveRoleInTx`. `idn05-role-registry.md` §9
   ("Dependencies") explicitly separates it from `src/engine/instance.zig`,
   `src/engine/transition.zig`, and any OIDC-adjacent module — R-Co treats this as an
   independently-scoped concern, not a sub-concern of general identity/registry
   handling. Mirroring that file-level separation in Letflow (a new module rather than
   folding into `Letflow.Identity`) keeps the same boundary R-Co itself draws.
3. **Coupling-boundary clarity (task point 5, restated in §5 below).** REQ-020's
   description explicitly requires confirming this module has no call-site coupling to
   the OIDC/claim-mapping pipeline. `Letflow.Identity` (the existing module) is exactly
   where that pipeline's functions already live (`provision_oidc_user/3`,
   `resolve_tenant_by_realm/1`, `resolve_realm_by_tenant/1`, `verify_realm_ownership/2`
   — all OIDC-pipeline-adjacent, all added by REQ-018/019). Adding `RoleRegistry`'s
   functions into that same module would put a "must never be coupled to OIDC" concern
   in the same namespace as the OIDC pipeline itself — nothing would prevent a future
   editor from casually reaching for `IdentityContext` or `JitProvisioningConfig` since
   they're already imported at the top of the same file for sibling functions. A
   separate module makes the absence of that coupling structural (there is no
   `alias Letflow.Oidc.*` anywhere in the new file to begin with) rather than a
   convention someone has to remember inside a shared file that already imports OIDC
   types for unrelated functions.
4. **This does not violate the project's established "top-level context module + schema
   subdirectory" pattern** (`backend_developer_guide.md` §2, `lib/letflow/identity.ex`'s
   own moduledoc: "Matches this project's established `Letflow.RowApproval`-style
   pattern: a top-level context module in `lib/letflow/`, backed by schema files in a
   same-named subdirectory"). `Letflow.Identity.RoleRegistry` is itself a "top-level"
   context module for its own narrower concern (the role registry), living at
   `lib/letflow/identity/role_registry.ex` alongside the schema files
   (`tenant_role.ex`, `group.ex`) it operates on — this is structurally the same shape
   as `Letflow.Identity` living at `lib/letflow/identity.ex` next to
   `lib/letflow/identity/tenant.ex`/`user.ex`. The `Letflow.Identity.` namespace prefix
   groups it under the identity domain (correct — REQ-020 is S1/identity work) without
   merging its call surface into the OIDC-adjacent module.

**File-level summary:**

| File | Module | New functions |
|---|---|---|
| `lib/letflow/identity/role_registry.ex` | `Letflow.Identity.RoleRegistry` | `list_roles/0`, `upsert_role/2`, `resolve_role_in_tx/1` |

No changes to `lib/letflow/identity.ex`, `lib/letflow/identity/tenant_role.ex`, or
`lib/letflow/identity/group.ex` (schema field lists are already correct and final per
REQ-015; this design adds no changeset to either schema — see §4 for why validation is
done without a changeset).

## 2. `list_roles/0` — no argument (answers task point "does this take a tenant param")

```
@spec list_roles() :: [TenantRole.t()]
```

PROVENANCE (historical, not current decision authority):
**Decision: zero arguments.** Returns all rows from `tenant_role`, sorted by `name` ASC.
Returns `[]` (not an error) when the table is empty — matches
`role_registry.zig`'s `listRoles` doc comment exactly ("Returns an empty slice (not an
error) when the table is empty") and REQ-020's first acceptance criterion verbatim.

**Why zero arguments, given R-Co's version also takes none but for a different
reason.** R-Co's `listRoles(self, allocator)` takes no tenant parameter because tenant
isolation is provided entirely by the Postgres `search_path` set once per request by the
schema-per-tenant middleware (`idn05-role-registry.md` §1: "Tenant isolation is provided
by the per-tenant schema (SPT architecture) ... no `tenant_id` column is needed"; §10
invariant 2: "The schema search path must be set ... before any query executes"). Under
that model, every query implicitly runs against exactly one tenant's physical table copy
— there is nothing to pass.

Letflow has **not** built that mechanism yet. Per `lib/letflow/design/identity-schema.md`
§1 (REQ-015's own design decision, restated in `tenant_role.ex`'s moduledoc line 17: "under
the single-default-schema deferral"): all four identity tables target Ecto's single
default (`public`) schema today; `:prefix`/dynamic-repo multi-schema provisioning is
explicit deferred follow-up work, not yet built. `tenant_role.name`'s uniqueness is
enforced as a **global** unique index standing in for "unique per tenant schema" under
that deferral (confirmed directly from the migration file, §7 below).

Given that, `list_roles/0` genuinely has no tenant to scope by yet — under the current
single-default-schema state, the entire `tenant_role` table **is** "the" role registry
(there is only one schema, hence conceptually one tenant's worth of role bindings, even
though no `tenant_id` column exists on this table to make that scoping explicit or
enforced). Adding a `tenant_id`/prefix parameter now would mean either (a) accepting a
parameter that has no code path to actually use (Ecto's `:prefix` plumbing isn't wired
up anywhere in this codebase yet — confirmed by search, §0), which is dead-parameter
scope creep, or (b) silently reintroducing a `tenant_id`-column-based scoping model on
this one table when Decision B's target model is schema-based, contradicting REQ-015's
own established shape for this exact table. Neither is correct. **`list_roles/0` takes
no argument, matching R-Co's own arity even though the underlying reason differs (schema
search path there, single-default-schema deferral here) — both reasons converge on "no
parameter needed for this table today."**

This is also flagged explicitly as an open question in §10, since it's the one place
this design's decision is contingent on a deferred mechanism landing later, not a
permanent architectural conclusion.

**Query:** unparameterized `SELECT` against `Letflow.Identity.TenantRole`, ordered by
`name` ascending — via `Ecto.Query`'s `from/2` + `order_by/3` composition (or
`Repo.all(from t in TenantRole, order_by: t.name)`), never `Repo.query/3` raw SQL (INV-7,
§9).

**Error cases:** none. This function cannot fail under normal operation — an empty table
is a success case (`[]`), not an error. A genuine DB/connection-level failure (pool
exhaustion, connection drop) is not caught and converted; it propagates as a raised
exception, matching this project's established precedent for simple `Repo.all`/`Repo.get`
reads elsewhere in `Letflow.Identity` (`resolve_tenant_by_realm/1`'s design explicitly
makes the same choice — see `req019-tenant-realm-binding.md` §5.1 and its own OQ-4).

## 3. `upsert_role/2`

```
@spec upsert_role(name :: String.t(), group_id :: Ecto.UUID.t() | String.t()) ::
        {:ok, TenantRole.t()} | {:error, upsert_error()}

@type upsert_error ::
        :invalid_role_name
        | :invalid_group_id
        | :group_not_found
        | Ecto.Changeset.t()
        | term()
```

Named error atoms, one per failure mode (task point 2's explicit instruction — no bare
"returns an error"):

| Failure mode | Returned value | R-Co equivalent |
|---|---|---|
| `name` fails format validation (empty, > 128 codepoints, or contains an ASCII control character) | `{:error, :invalid_role_name}` | `TenantRoleError.RoleNameInvalid` |
| `group_id` is not a syntactically valid UUID string | `{:error, :invalid_group_id}` | `TenantRoleError.GroupIdInvalid` |
| `group_id` is syntactically valid but no row exists in `groups` with that id | `{:error, :group_not_found}` | `TenantRoleError.GroupNotFound` |
| DB-level constraint violation surfaced as a changeset error (defensive — see §3.2) | `{:error, %Ecto.Changeset{}}` | (no direct R-Co equivalent — R-Co's raw-SQL upsert has no changeset layer; this is Letflow's own INV-8 safety net) |

PROVENANCE (historical, not current decision authority):
**Validation order (task point 2's explicit instruction), exactly matching
`upsertRole`'s own order in `role_registry.zig` line 121-122 and
`idn05-role-registry.md` §3a's numbered algorithm:**

1. Validate `name` format first (§4.1). Invalid → return immediately, `{:error,
   :invalid_role_name}`. No DB round-trip attempted.
2. Validate `group_id` is a syntactically well-formed UUID (§4.2). Invalid → return
   immediately, `{:error, :invalid_group_id}`. No DB round-trip attempted. (R-Co
   validates both name and `group_id` format before acquiring a connection at all —
   `upsertRole`'s two `if` checks, lines 121-122, both run before `self.pool.acquire()`
   on line 124. This design preserves that ordering: both format checks happen before
   any `Repo`/transaction call.)
3. Group existence check (§3.1 step a) — inside the transaction, `Repo.get(Group,
   group_id)`. Not found → `Repo.rollback(:group_not_found)`, surfaces as `{:error,
   :group_not_found}`.
4. Transactional insert-or-update (§3.1 step b).

### 3.1 Transaction shape (answers task point 3)

PROVENANCE (historical, not current decision authority):
**Decision: `Repo.transaction/1` wrapping a two-step callback — (a) a `Repo.get(Group,
group_id)` existence check that rolls back with `:group_not_found` if nil, then (b) an
`Repo.insert/2` with an `on_conflict:`/`conflict_target:` upsert clause returning the
row.** This is the Ecto-idiomatic equivalent of R-Co's explicit
BEGIN/existence-check/INSERT-ON-CONFLICT/COMMIT sequence
(`role_registry.zig` lines 131-179; `idn05-role-registry.md` §3a steps 3-5, §6's data-flow
diagram).

Prose shape of the transaction callback (no code — describing the two ordered steps
`Repo.transaction/1`'s function argument performs):

PROVENANCE (historical, not current decision authority):
- **Step a — existence check.** `Repo.get(Letflow.Identity.Group, group_id)`. Ecto's
  `Repo.get/2` does not raise for a missing row — it returns `nil` (this is the "never
  raise" mechanism for this step, restated in §4.3). If `nil`: call `Repo.rollback(reason)`
  with `reason = :group_not_found`. `Repo.transaction/1`'s outer return becomes
  `{:error, :group_not_found}` automatically — this is `Repo.rollback/1`'s documented
  behavior (the value passed to `rollback/1` becomes the `{:error, value}` the caller of
  `Repo.transaction/1` receives), matching R-Co's own rollback-on-not-found step exactly
  (`role_registry.zig` lines 142-145: `if (exists_row == null) { conn.rollback() ...
  return TenantRoleError.GroupNotFound; }`).
PROVENANCE (historical, not current decision authority):
- **Step b — upsert.** If step a found a group, proceed to `Repo.insert/2` on a
  `%TenantRole{}` struct (or an `Ecto.Changeset` built from one — see §3.2 for why this
  design uses a changeset here despite REQ-015's `tenant_role.ex` defining none) with:
  - `conflict_target: :name` — the exact column REQ-015's migration declares a unique
    index on (`create unique_index(:tenant_role, [:name])`, confirmed directly from
    `20260816000003_create_tenant_role.exs` line 31; no `where:` clause on that index, so
    `conflict_target: :name` needs no partial-index qualifier, unlike e.g.
    `users`'s partial `(external_realm, external_id)` index elsewhere in this batch).
  - `on_conflict: [set: [group_id: group_id]]` — updates only `group_id` on conflict,
    matching `role_registry.zig`'s `ON CONFLICT (name) DO UPDATE SET group_id =
    EXCLUDED.group_id` exactly (line 153). Does not touch `inserted_at` on conflict
    (there is no `updated_at` column on this table per REQ-015's schema — `timestamps(updated_at:
    false)` — so there is nothing else to set even if desired).
  - `returning: true` — so the function can return the actual persisted row (id,
    `inserted_at` included) rather than the pre-insert struct, matching R-Co's `RETURNING
    id, name, group_id, created_at` clause (line 154-155).
  - Result: `{:ok, %TenantRole{}}` (with `id` set — either the newly generated one on
    insert, or, per this project's own established caveat about `binary_id` +
    `on_conflict` + `returning: true` not distinguishing insert-vs-update-suppression in
    the returned struct's field values, see the note below — either way `{:ok, row}` is
    the correct outer shape for this function, unlike REQ-018's `provision_oidc_user/3`
    which specifically needs to know insert-vs-fetch and therefore needs the extra
    `Repo.get/2` re-check `lib/letflow/identity.ex` already performs for that reason).
    `Repo.transaction/1`'s outer return becomes `{:ok, %TenantRole{}}`.

**Note — does `upsert_role/2` need the same insert-vs-update disambiguation dance
`provision_oidc_user/3` needs?** No. `provision_oidc_user/3` needs to know
`created: true/false` because that's part of its own documented return contract
(REQ-018's acceptance criteria explicitly test for it). REQ-020's acceptance criteria do
not ask `upsert_role/2` to report whether it created vs. updated — "upsert_role/2 called
twice with the same name and a different group_id updates the existing binding rather
than creating a duplicate row" only requires that no duplicate row exists after the
second call, which `on_conflict: [set: [group_id: group_id]]` + `conflict_target: :name`
already guarantees structurally (a second row with the same `name` cannot be inserted;
Postgres either updates the existing row or errors, and the `on_conflict` clause makes it
update). This design therefore does **not** replicate `provision_oidc_user/3`'s
`Repo.get/2`-after-insert re-check pattern — it is unnecessary complexity for a function
whose contract doesn't need to distinguish the two cases. This is stated explicitly so
ELIXIR-DEV doesn't assume the two functions must follow identical shapes just because
both are upserts in the same context.

### 3.2 Why a changeset, given `tenant_role.ex` defines none

REQ-015's `Letflow.Identity.TenantRole` moduledoc states "No changeset function is
defined here — REQ-020 owns `list_roles/upsert_role` and their validation logic" — this
design **adds** a changeset function to `Letflow.Identity.TenantRole` (not to
`RoleRegistry` itself) as part of fulfilling that ownership, for exactly one reason:
`Repo.insert/2`'s `on_conflict:`/`conflict_target:` options work identically whether
passed a bare struct or a changeset, but a changeset gives `upsert_role/2` a clean place
to declare `unique_constraint(:name)` so that a genuinely concurrent conflict Postgres's
own `ON CONFLICT` clause doesn't fully absorb (there isn't one here in the normal case —
`ON CONFLICT ... DO UPDATE` is exactly what avoids a raised constraint violation in the
first place) still has a defensive, typed fallback rather than an unhandled
`Ecto.ConstraintError` if some other, unanticipated constraint fires. This mirrors this
project's established pattern from REQ-018/019 (`identity.ex`'s `User.jit_changeset/2`,
`tenant.ex`'s `create_changeset/3`) of declaring `unique_constraint/2` defensively for
every DB-level unique index a changeset's fields could reach, even when the primary
enforcement mechanism (here, `on_conflict:`) is expected to handle the common case.

**Function added to the schema module (task's own convention: changesets live on the
schema module, per REQ-018/019's established placement precedent —
`req019-tenant-realm-binding.md` §1's explicit citation of this precedent):**

```
# Letflow.Identity.TenantRole
@spec changeset(tenant_role :: %TenantRole{}, attrs :: map()) :: Ecto.Changeset.t()
```

- `cast/3` fields: `:name`, `:group_id`.
- `validate_required/2`: both fields (defensive — `upsert_role/2`'s own pre-validation
  in §4 is the primary gate; the changeset-level `validate_required` is a second,
  cheap layer in case a future caller reaches this changeset directly, bypassing
  `upsert_role/2`'s own checks — consistent with this project's general preference for
  changesets not silently trusting that all callers went through the "correct" entry
  point).
- `unique_constraint(:name)` — surfaces REQ-015's `unique_index(:tenant_role, [:name])`
  violation as a changeset error defensively (§3.2's reasoning above).
- **No `validate_length`/format validation duplicated at the changeset level.** The
  detailed name-format rule (§4.1: codepoint count, control-character exclusion) is
  enforced by `upsert_role/2` itself *before* the changeset/transaction is ever reached
  (§3's validation-order list, steps 1-2) — duplicating the same rule inside the
  changeset would be redundant and risks the two checks drifting apart over time. The
  changeset's `validate_required/2` is a structural safety net (a `nil`/missing field),
  not a re-implementation of the codepoint-count/control-character rule.

## 4. Validation logic design (answers task point 4)

### 4.1 Name validation

PROVENANCE (historical, not current decision authority):
**Rule (ported from `isValidRoleName`, `role_registry.zig` lines 224-237, and
`idn05-role-registry.md` §3a step 1 / OQ-3):** `name` must be (a) non-empty, (b) at most
128 Unicode codepoints, (c) contain no ASCII control characters (`0x00`-`0x1F` or
`0x7F`).

**Design for the check (prose, not code):**

- **Non-empty:** `name != ""` (or `String.length(name) > 0` — either check is
  equivalent for this purpose; a plain string-equality/emptiness check is preferred as
  the cheaper first check since it doesn't require walking the string).
- **Codepoint count, ≤ 128:** `String.length/1` is Elixir's codepoint-aware length
  function (it counts Unicode grapheme-independent codepoints, not bytes) — this is the
  direct equivalent of R-Co's manual UTF-8 codepoint-counting loop (`isValidRoleName`'s
  `cp_count` walk, lines 226-235, which manually decodes UTF-8 byte-width to count
  codepoints one at a time because Zig has no built-in codepoint-aware length function
  for byte slices). `String.length(name) <= 128` is the direct, idiomatic Elixir
  equivalent — no manual byte-walking needed.
- **No ASCII control characters:** the check must reject any codepoint in `0x00..0x1F`
  or exactly `0x7F`, matching `isValidRoleName`'s `if (c <= 0x1F or c == 0x7F) return
  false` (line 230) applied per-byte in R-Co's implementation. In Elixir, the equivalent
  is a codepoint-level scan — either (a) a regex against the full codepoint range
  (`~r/[\x00-\x1F\x7F]/u`, matched with `String.match?/2`, negated), or (b) an explicit
  walk via `String.to_charlist/1` (or `String.codepoints/1`) checking each codepoint
  against the same two ranges (`cp <= 0x1F or cp == 0x7F`). **This design recommends the
  regex form** (`String.match?(name, ~r/[\x00-\x1F\x7F]/u)` → reject if `true`) as the
  more idiomatic, more obviously-correct-at-a-glance Elixir form for a fixed
  codepoint-range membership test, over a manual `Enum.any?` walk — but either is
  acceptable; this is not a load-bearing design choice (both produce identical
  accept/reject results for every input), so it is left to ELIXIR-DEV's implementation
  judgment rather than mandated as a single form. **Order of checks does not matter for
  correctness** (all three are independent predicates on the same string), but checking
  non-empty first is the cheapest short-circuit.
- **Combined result:** `{:error, :invalid_role_name}` if any of the three checks fails;
  otherwise proceed.

### 4.2 `group_id` validation — pre-DB-round-trip UUID format check

PROVENANCE (historical, not current decision authority):
**Rule (ported from `isValidUuidHex`, `role_registry.zig` lines 240-251, and
`idn05-role-registry.md` §3a step 2):** `group_id` must be validated as a syntactically
well-formed UUID string **before** any DB query touches it — R-Co's own algorithm
(`isValidUuidHex`) is a pure string-shape check (36 characters, hyphens at positions
8/13/18/23, hex digits elsewhere) that runs entirely in-memory, with zero DB
involvement, before `upsertRole` ever acquires a connection.

**Design decision: `Ecto.UUID.cast/1` is the Elixir-idiomatic equivalent of this
pre-validation step.** `Ecto.UUID.cast/1` returns `{:ok, normalized_uuid_string}` for a
syntactically valid UUID string (any of the standard textual forms) and `:error` for
anything else — including a value that clearly isn't a UUID (wrong length, non-hex
characters, wrong hyphen placement) — without touching the database. This is functionally
the same shape as `isValidUuidHex`'s boolean return, and Ecto's own implementation is
already the project's established UUID-handling primitive (used throughout
`Letflow.Identity.Tenant.id`/`Letflow.Identity.User.id`'s `binary_id` type mapping).
`upsert_role/2` calls `Ecto.UUID.cast(group_id)` as its second pre-validation step (after
name validation, §3's ordering): `:error` → `{:error, :invalid_group_id}`, no DB
round-trip attempted, matching R-Co's `GroupIdInvalid` short-circuit exactly. `{:ok,
normalized}` → proceed to the transaction (§3.1) using the normalized form.

**Why this matters for "never raise" (task's explicit framing).** Without this
pre-validation step, a malformed `group_id` string passed directly into a query that
expects a UUID-typed parameter (e.g. `Repo.get(Group, group_id)` where `Group`'s primary
key is `:binary_id`) would raise `Ecto.Query.CastError` (or an equivalent
`ArgumentError`/ `Ecto.CastError` depending on the exact call path) rather than returning
a clean `{:error, _}` tuple — Ecto's binary_id/UUID casting is not itself
exception-tolerant when handed a non-UUID-shaped string in a context expecting a
already-cast value. `Ecto.UUID.cast/1` is the specific function in Ecto's own API that
*is* exception-tolerant by design (`:error`, never a raise, for a malformed string) —
using it as the explicit gate before any query touches `group_id` is what makes
`upsert_role/2`'s "no unhandled raise on external input" property hold, matching this
project's already-established general principle (`Letflow.Identity`'s existing functions
— see `backend_developer_guide.md` §3.5, `security-invariants.md` INV-8).

### 4.3 `resolve_role_in_tx/1` — "never raise" mechanism, stated explicitly (answers
task point 2's resolve_role_in_tx sub-instruction)

`resolve_role_in_tx/1` (§6 below) achieves "never raises, swallows all failures into
`nil`" through two distinct mechanisms, one per class of failure:

1. **Unknown/unbound name → `nil` via a query primitive that itself never raises for
   "no row found."** `Repo.get_by(TenantRole, name: name)` (or the `Ecto.Multi`/
   transaction-callback equivalent, §6) returns `nil` when no row matches — this is
   `Repo.get_by/2`'s own documented, non-exceptional behavior for zero results; no
   `rescue` is needed for this case because there is nothing to rescue from.
PROVENANCE (historical, not current decision authority):
2. **Any DB error (genuinely malformed query, connection blip, or anything else that
   *could* raise) → `nil` via an explicit `rescue`.** Unlike `list_roles/0` and
   `upsert_role/2` (§2, §3), which both leave a genuine connection-level failure
   unhandled/propagating (matching this project's established precedent — see §2's own
   note and `req019-tenant-realm-binding.md`'s OQ-4), `resolve_role_in_tx/1` is
   different: REQ-020's acceptance criterion #4 explicitly requires it to "return nil on
   any lookup failure (unknown name, table/connection issue) rather than raising" — a
   stronger, function-specific requirement matching `role_registry.zig`'s own doc
   comment ("Errors are treated as 'unbound' so the task activation transaction never
   fails due to role lookup issues") and `idn05-role-registry.md` §3c's explicit
   algorithm ("Any DB error → return `null` ... Do NOT propagate the error"). This design
   therefore wraps the query call in an explicit `try/rescue` (catching the general
   exception classes Ecto/Postgrex can raise for a query-level failure —
   `Ecto.QueryError`, `DBConnection.ConnectionError`, or the catch-all `rescue _ ->
   nil`) specifically for this one function, where every other function in this design
   (and in `Letflow.Identity`'s existing functions) deliberately does not. **This is the
   one place in this design that intentionally diverges from the project's general
   "don't paper over a raised connection error" posture** — justified because
   `resolve_role_in_tx/1`'s entire reason for existing (per its R-Co source) is to be
   the fail-safe fallback inside a larger transition transaction (S3's future
   `applyTransition`) that must not itself fail due to a role-lookup problem; swallowing
   is the *documented, correct* behavior here, not a shortcut.

## 5. `resolve_role_in_tx` — full signature (answers task point 2 continued)

```
@spec resolve_role_in_tx(repo_or_multi :: Ecto.Repo.t() | Ecto.Multi.t(), name :: String.t()) ::
        Ecto.UUID.t() | nil
```

PROVENANCE (historical, not current decision authority):
**Decision on the "existing transaction" parameter shape:** R-Co's `resolveRoleInTx`
takes a raw `*db.Conn` — the caller's already-open connection/transaction handle — and
explicitly does *not* acquire a new connection (`role_registry.zig` line 201-202: "does
NOT acquire a new connection — uses the caller's already-open `conn`"). Ecto's closest
idiomatic equivalent to "run this query using the caller's already-open transaction" is
**not** a raw connection handle passed as a value — Ecto's `Repo` functions are already
transaction-aware by ambient process/connection state once called from *inside* a
`Repo.transaction/1` callback (any `Repo.get`/`Repo.get_by`/`Repo.all` call issued from
code running inside that callback automatically participates in the same transaction,
without needing to thread a connection value through explicitly).

**This design specifies: `resolve_role_in_tx`'s parameter list carries no explicit
connection/transaction argument at all** — not a raw connection struct, not an
`Ecto.Multi.t()`, not even `Letflow.Repo` itself threaded as a value. The function is
designed to be *called from inside* an existing `Repo.transaction/1` callback (the
future S3 `applyTransition`'s transaction) — the "inside an existing transaction"
property comes from *where the function is invoked from* (within another function's
`Repo.transaction/1` callback), not from a value threaded into this function's own
arguments. Concretely: `resolve_role_in_tx/1`'s body issues
`Repo.get_by(TenantRole, name: name)` (wrapped in the `rescue`, §4.3) exactly the way
`resolve_tenant_by_realm/1`/`resolve_realm_by_tenant/1` already do elsewhere in this
codebase — when the *caller* (a future S3 function) invokes `resolve_role_in_tx/1` from
inside its own `Repo.transaction/1` callback, Ecto/Postgrex automatically executes this
function's `Repo.get_by/2` call against that same open transaction/connection, with no
special parameter needed to make that happen. **The `repo_or_multi` parameter in the
`@spec` above is therefore simplified to no explicit "connection" argument at all** —
restated as the final, simpler signature:

```
@spec resolve_role_in_tx(name :: String.t()) :: Ecto.UUID.t() | nil
```

**Why this is correct despite looking like it drops the "inside an existing transaction"
requirement:** this is a property of *how the function is used* (called from within a
`Repo.transaction/1` callback elsewhere) rather than something that needs to appear as
an extra function argument — Ecto's connection/transaction context is ambient to the
calling process, not an explicit value the caller must construct and pass down (unlike
R-Co's Zig code, where `*db.Conn` genuinely is an explicit value because Zig has no
implicit per-process transaction context). This is stated as a deliberate design
decision, not an oversight — flagged again in §10 as an item for REVIEWER to confirm,
since it is the one place this design most visibly diverges from a literal
argument-for-argument port of the R-Co signature.

**Behavior:**
- `name` matches exactly one row in `tenant_role` → returns that row's `group_id` (an
  `Ecto.UUID.t()`, i.e. the standard string-form UUID Ecto surfaces for a `binary_id`/
  `Ecto.UUID`-typed field — matching R-Co's own `?Uuid` return, adapted to Letflow's
  string-UUID convention rather than R-Co's raw `[16]u8` binary form, since Letflow has
  no equivalent raw-binary UUID type in ordinary use elsewhere in this codebase).
- No matching row → `nil`.
- Any DB error during the lookup → `nil` (§4.3's `rescue`).
- **Never** returns `{:error, _}`, never raises. This is a hard behavioral contract, not
  a soft preference — REQ-020's acceptance criterion #4 is explicit.

## 6. Coupling boundary (answers task point 5)

**Design invariant, stated explicitly:** `Letflow.Identity.RoleRegistry` has **no
call-site coupling to the OIDC/claim-mapping pipeline** (`Letflow.Oidc.*` modules —
`ClaimMapping`, `ClaimMappingConfig`, `IdentityContext`, `JitProvisioningConfig` — and
`Letflow.Identity.provision_oidc_user/3`, `resolve_tenant_by_realm/1`,
`resolve_realm_by_tenant/1`, `verify_realm_ownership/2`).

**Concrete, checkable form of this invariant:**
- No `alias Letflow.Oidc.*` or `import Letflow.Oidc.*` anywhere in
  `lib/letflow/identity/role_registry.ex`.
- No function in this design (`list_roles/0`, `upsert_role/2`, `resolve_role_in_tx/1`)
  takes an `IdentityContext.t()`, `JitProvisioningConfig.t()`, `ClaimMappingConfig.t()`,
  or `Letflow.Identity.Tenant.t()`/`Letflow.Identity.User.t()` argument, or returns one.
  Every function's inputs/outputs in this design are limited to: a role `name` string, a
  `group_id` UUID string, and `TenantRole`/`Group` structs.
- No function in `Letflow.Identity.RoleRegistry` calls into `Letflow.Identity` (the
  OIDC-pipeline-adjacent context module) or vice versa. The two modules are siblings
  under the `Letflow.Identity.` namespace, not callers of each other.

**One-line justification (task's own required form):** this module is a
standalone, workflow-engine-facing registry consumed by the future S3 `applyTransition`
(role name → group UUID resolution at task activation, per `idn05-role-registry.md` §4)
— it has nothing to do with verifying who a user is (OIDC/token verification, REQ-016/
017/018/019's concern) and everything to do with resolving what a role name means once a
user's identity and tenant are already established elsewhere in the pipeline; the two
concerns are orthogonal by construction, matching R-Co's own explicit dependency
exclusion in `idn05-role-registry.md` §9 ("Must NOT depend on: ... any module that
performs HTTP calls" — Letflow's equivalent boundary is "any `Letflow.Oidc.*` module or
`Letflow.Identity`'s OIDC-pipeline functions").

## 7. `@moduledoc` requirement (answers task point 6)

**Explicit acceptance-criterion requirement, not merely good practice** (REQ-020's fifth
acceptance criterion): `Letflow.Identity.RoleRegistry`'s `@moduledoc` must:

PROVENANCE (historical, not current decision authority):
1. Cite `src/identity/role_registry.zig` as the ported source (and, per this project's
   established citation style elsewhere in this batch, may also cite
   `src/design/idn05-role-registry.md` as the design doc `role_registry.zig` itself
   points to — not required by REQ-020's literal wording, which names only the `.zig`
   file, but consistent with how `lib/letflow/identity.ex`'s own moduledoc cites both the
   `.zig` source and the corresponding adp-0x design doc for its own ported functions).
2. Explicitly state the no-OIDC-coupling invariant from §5 above — in prose, not merely
   by omission. E.g., a sentence stating this module has no dependency on
   `Letflow.Oidc.*` or `Letflow.Identity`'s OIDC-pipeline functions, and is a
   standalone workflow-engine-facing registry, not part of token verification. This
   must be a stated sentence in the moduledoc text, not left to be inferred from the
   absence of an `alias` line.

## 8. DB schema (answers task point 7) — no new migration needed, confirmed

**No new migration.** REQ-015 already created `tenant_role` and `groups` with the shape
this design needs. Confirmed directly from the actual migration files (not inferred from
the schema modules' moduledocs alone):

- **`priv/repo/migrations/20260816000003_create_tenant_role.exs`** (read in full, §0):
  - `create unique_index(:tenant_role, [:name])` — line 31. **`tenant_role.name` DOES
    have a unique index**, confirmed directly — this is the exact index `upsert_role/2`'s
    `conflict_target: :name` (§3.1) targets.
  - `add :group_id, references(:groups, type: :binary_id), null: false` — line 26.
    **`tenant_role.group_id` DOES have a DB-level foreign key to `groups.id`.** This
    matches R-Co's own design (`idn05-role-registry.md` §1: `group_id UUID NOT NULL
    REFERENCES groups(id) ON DELETE RESTRICT`) and matches `tenant_role.ex`'s own
    moduledoc claim (lines 8-9: "`group_id` carries a database-level foreign key to
    `groups.id` — unlike ... `tenant_id`'s deliberate omission"). **This is confirmed
    true, not merely asserted** — read directly from the migration source, not taken on
    the schema moduledoc's word alone.
  - Practical consequence for reachability: since a real DB-level FK exists, a
    dangling `group_id` reference is *also* rejected at the DB layer (an `INSERT`
    referencing a nonexistent `groups.id` would raise a foreign-key-violation error) —
    but `upsert_role/2`'s own explicit pre-check (§3.1 step a, `Repo.get(Group,
    group_id)` inside the transaction, returning the clean `{:error,
    :group_not_found}` tuple via `Repo.rollback/1`) is what actually makes this
    reachable as a **typed, non-raising** error path (INV-8) — without that pre-check,
    a caller passing a nonexistent-but-well-formed `group_id` would hit the FK
    constraint at INSERT time and get an unhandled `Ecto.ConstraintError` instead of a
    clean `{:error, :group_not_found}` tuple. Both mechanisms exist in this design: the
    DB-level FK is defense-in-depth (guarantees no dangling reference can persist even
    if the application-level check were ever bypassed or raced), and the explicit
    pre-check is what makes the failure observable as a typed error rather than a raised
    exception. This is exactly the distinction task point 7 asks this design to state
    plainly.
- **`priv/repo/migrations/20260816000002_create_groups.exs`** (read in full, §0):
  `create index(:groups, [:tenant_id])` — a plain (non-unique) index, no unique
  constraint on `groups.name` or `(tenant_id, name)`. Confirms §0's note: this design
  does not add group-name uniqueness, since REQ-020 needs only existence-checking, and
  the migration provides no such constraint to surface anyway.

No migration file is added or modified by this design.

## 9. Security invariants — explicit assessment (INV-7, INV-8)

**INV-7 (no SQL string interpolation) — APPLIES, satisfied by construction.** Every
query this design specifies goes through `Ecto.Repo`'s parameterized API (`Repo.all/2`
via `Ecto.Query`, `Repo.get/2`, `Repo.get_by/2`, `Repo.insert/2` with `on_conflict:`) —
no `Repo.query/3` raw SQL anywhere in this design. `name` and `group_id` (both
externally-supplied values) are passed as plain Elixir term arguments to Ecto's
parameterized functions, never string-interpolated into a query.

**INV-8 (no unhandled crashes) — APPLIES, satisfied with the same residual-risk framing
this project has already established for sibling functions (REQ-018/019's own OQ-4
precedent), plus one function-specific strengthening.** `upsert_role/2` returns typed
`{:ok, _} | {:error, atom}` tuples for every *expected* failure mode (invalid name,
invalid group_id format, group not found) — pre-validated *before* any DB round-trip
(§3, §4), so a malformed `group_id` string never reaches a context where Ecto's own UUID
casting could raise (§4.2's explicit reasoning). `resolve_role_in_tx/1` goes further,
per its own acceptance criterion (§4.3): it wraps its query in an explicit `rescue` so
that even a genuine DB/connection-level failure — not just an expected "not found" case —
resolves to `nil` rather than propagating. `list_roles/0` and the non-pre-validation
paths of `upsert_role/2` do **not** add this same blanket rescue for a genuine
connection-level failure (pool exhaustion, connection drop) — consistent with this
project's established precedent (`req019-tenant-realm-binding.md` §8 OQ-4) of leaving
that one specific residual risk open rather than silently deciding a new policy in this
design. Stated explicitly here so SECURITY-REVIEWER evaluates this design's functions
under the same consistent policy already applied to `Letflow.Identity`'s existing
functions, with `resolve_role_in_tx/1` named as the one deliberate, requirement-driven
exception.

## 10. Acceptance-criteria traceability (answers task point 8)

PROVENANCE (historical, not current decision authority):
| REQ-020 acceptance criterion | Concrete design element |
|---|---|
| "list_roles/1 returns [] (not an error) against an empty tenant_role table, and returns all rows sorted by name when populated" | §2: `list_roles/0` (this design's arity decision, explained in full in §2), unparameterized `SELECT ... ORDER BY name ASC`, `[]` on empty table by construction (no rows → empty list, not an error) |
| "upsert_role/2 with a non-existent group_id returns an error tuple rather than inserting a dangling reference" | §3.1 step a: `Repo.get(Group, group_id)` inside the transaction, `Repo.rollback(:group_not_found)` on `nil` → `{:error, :group_not_found}`; §8's confirmation that the DB-level FK also defends this at the constraint layer, with the pre-check being what makes it a typed, non-raising error |
| "upsert_role/2 called twice with the same name and a different group_id updates the existing binding rather than creating a duplicate row" | §3.1 step b: `conflict_target: :name` + `on_conflict: [set: [group_id: group_id]]` against REQ-015's `unique_index(:tenant_role, [:name])` (confirmed in §8) — structurally prevents a duplicate `name` row, updates `group_id` in place |
| "resolve_role_in_tx/2 (or equivalent inside-an-existing-transaction call) returns nil on any lookup failure (unknown name, table/connection issue) rather than raising" | §5 (final signature `resolve_role_in_tx/1`, arity justified), §4.3 (the two-mechanism "never raise" design: `Repo.get_by/2`'s natural `nil`-on-no-match plus an explicit `rescue` for genuine DB errors) |
| "@moduledoc cites src/identity/role_registry.zig and states explicitly that this module has no coupling to the OIDC token-verification pipeline" | §7 (explicit moduledoc content requirements), §5/§6 (the coupling-boundary invariant the moduledoc must state in prose) |

## 11. Open questions (answers task point 9)

1. **OQ-1 — `list_roles/0`'s zero-argument shape is contingent on the still-deferred
   multi-schema provisioning mechanism.** §2 recommends zero arguments as the correct
   choice *today*, matching the current single-default-schema state every table in this
   batch shares — but this is explicitly not a permanent architectural conclusion. Once
   `identity-schema.md` §1's flagged follow-up (a `tenant_schemas` registry + Ecto
   `:prefix` provisioning) actually lands, `list_roles/0`'s contract will need to change
   (either to `list_roles/1` taking a tenant-scoping value, or to rely on ambient
   `:prefix` context the same way `resolve_role_in_tx/1` relies on ambient transaction
   context, §5) — this design does not attempt to predict which shape that future change
   will take, since REQ-020's own acceptance criteria only require correctness against
   today's single-schema state. Flagged so ELIXIR-DEV/REVIEWER don't read the
   zero-argument choice as more permanent than it is.
2. **OQ-2 — `resolve_role_in_tx/1`'s "ambient transaction" design (§5) is the one place
   this design most visibly diverges from a literal argument-for-argument port of
   R-Co's `resolveRoleInTx(conn, name)` signature.** This design's reasoning (Ecto's
   transaction context is ambient to the calling process, not a value threaded through
   function arguments, unlike Zig's explicit `*db.Conn`) is believed correct given how
   every other `Repo`-calling function in this codebase already works, but is flagged
   explicitly for REVIEWER to confirm before ELIXIR-DEV implements it — if REVIEWER
   disagrees, the alternative (accepting an explicit connection/transaction-context
   argument) is a small, contained change to §5 alone and does not ripple into §2-§4.
3. **OQ-3 — regex vs. explicit codepoint-walk for the control-character check (§4.1).**
   Left to ELIXIR-DEV's implementation judgment as explicitly non-load-bearing (both
   forms produce identical results) — not a genuinely undecided design question, restated
   here only for completeness since §4.1 already names it as a deliberate "either is
   fine" choice rather than a single mandated form.
4. **OQ-4 — should `upsert_role/2`'s changeset (§3.2) also declare
   `foreign_key_constraint(:group_id)` defensively, alongside `unique_constraint(:name)`?**
   Not decided here. Given the DB-level FK confirmed in §8, a defensive
   `foreign_key_constraint/2` declaration would let a race-condition group-deletion
   between this function's own existence pre-check (§3.1 step a) and its INSERT (step b)
   surface as a typed changeset error rather than an unhandled `Ecto.ConstraintError` —
   a narrow, low-probability race (something else deletes the referenced group in the
   gap between this function's own check and its write), but one this design's current
   shape does not fully close. Recommended: ELIXIR-DEV should add
   `foreign_key_constraint(:group_id)` to the changeset in §3.2 as a low-cost defensive
   addition (matching this project's general "declare a defensive constraint for every
   DB-level constraint a changeset's fields could reach" practice, §3.2's own citation of
   that pattern) — but this is not mandated as a hard requirement by REQ-020's acceptance
   criteria, so it is named here as a recommendation rather than folded silently into
   §3.2 as if it were already decided.
