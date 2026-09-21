# REQ-373 — service_catalog version/status lifecycle + real PinResolver.Lookup

CODE-DESIGNER design artefact. Backend-only (S6). No `web/` presentation layer — that
is an explicit follow-on FRONTEND-DEV requirement, not designed here.

Design docs only — every "Change" subsection below is **described, not written**:
`@spec`-style signatures and prose describing behavior, never a literal function body,
`case/do/end` block, or clause implementation. Per the REQ-372 rework precedent
(`handoffs/WF02-REQ372-20260921/step-01-code-designer.json`), a call-site change is
prose naming what gets called, where, and what the outcomes are — not `case ... end`
syntax.

## §0 — Re-verification (done this session, before designing)

Read in full, current source, 2026-09-21:

- `lib/letflow/service_catalog.ex` — five public functions
  (`register/1`, `get_for_tenant/2`, `list_for_tenant/2`, `update_scope/2`, `delete/1`),
  plus the additive `list_all/1` and `scope_validator_lookup/1`. **No version/status
  column exists.** `service_id` is the table's own primary key
  (`@primary_key {:service_id, :string, autogenerate: false}` in `Entry`), a
  caller-supplied string, globally unique across tenants/scopes by virtue of being the
  PK itself.
- `lib/letflow/service_catalog/entry.ex` — schema fields: `service_id` (PK),
  `endpoint_url`, `request_schema`, `response_schema`, `required_auth` (Ecto.Enum),
  `timeout_ms`, `retry_policy`, `scope` (Ecto.Enum `:global|:tenant`),
  `owner_tenant_id`, `created_at`/`updated_at` (plain `utc_datetime_usec`, not
  `timestamps/1`, stamped by the context module). Changeset-level checks are advisory
  only — the migration's DB `CHECK` constraints are authoritative.
- `lib/letflow/engine/pin_resolver.ex` — confirmed the exact contracts this design
  must honor:
  - `Lookup.catalog_lookup :: (service_id :: String.t() -> {:ok, %{resolved_id:
    String.t(), version: String.t()}} | {:error, :not_found})` — **takes the ref
    (`service_id`) alone, no requested version.** This is the single most
    load-bearing fact for §1's schema decision below: nothing downstream of `Lookup`
    ever asks for "version N of service X," only "the currently resolvable version of
    service X."
  - `Lookup.module_lookup` — same shape, for `module_ref`s. PLC-01 (module catalog)
    does not exist in this codebase and is unscoped to any stage — this design does
    not touch it; `module_lookup` stays a permanent `{:error, :not_found}` stub, per
    the moduledoc's own "SCOPE GAP" section.
  - `source` taxonomy: `:resolved | :override | :inherited | :rebound` — unchanged by
    this design; a fresh catalog-backed resolution still produces `source: :resolved`
    exactly as `default_lookup/0`'s stub would have on a lucky lookup.
  - `default_lookup/0`'s current shape: `catalog_lookup`/`module_lookup` always
    `{:error, :not_found}`; `variable_schema_lookup` always `{:ok, %{version:
    "unversioned", json_schema: nil}}` — **total, unconstrained, never fails.**
  - "No fallback, ever" (moduledoc, PIN-03 AC1/AC5) governs `pin_for/3` — a **pure**
    function over an already-obtained pin list, zero I/O, never touches any lookup or
    catalog. This is why §3's retire design can state AC4's "already-pinned instance"
    half is satisfied **by construction**, not by any code this requirement adds.
- `lib/letflow/engine.ex` — `create/2`'s exact current call site
  (`lib/letflow/engine.ex:975-984`):
  ```
  @spec pin_lookup(attrs :: map(), prefix :: String.t() | nil) :: PinResolver.Lookup.t()
  defp pin_lookup(attrs, _prefix) do
    Map.get(attrs, :pin_lookup, PinResolver.default_lookup())
  end
  ```
  `attrs[:pin_lookup]`, when caller-supplied (tests, future callers), is used
  verbatim and is **not** touched by this design — only the second argument to
  `Map.get/3` (the default a caller who supplies nothing falls back to) changes. `_prefix`
  is already ignored (unrelated to this design).
- `lib/letflow_web/router.ex` / `lib/letflow/routers/admin_services.ex` — REQ-192's
  already-shipped admin surface: `AdminServices` is mounted at `/admin/services` by
  `Letflow.Plugs.ApiPipeline` (full paths under `/api/v1`), with
  `authz_post "/"`, `authz_patch "/:service_id"`, `authz_delete "/:service_id"` each
  declared `:AdminServicesManage`. `Letflow.Api.Authorization.endpoint_policy_key/2`
  already maps **any** `POST`/`PATCH`/`DELETE` on a path starting with
  `"/admin/services"` to `:AdminServicesManage`, and `required_permission/1` maps that
  to `:UsersGroupsRolesManage` (`PLATFORM_ADMIN`-only). **No new permission atom, no
  `authorization.ex` change** — §7's two new routes are covered by this existing
  prefix-match clause automatically.
- `docs/migration/decisions/` — grepped for prior versioned-entity schema precedent.
  No decision record dictates composite-key-vs-status+sibling-table for a versioned
  catalog; `0023-entity-storage-hybrid.md` establishes `entity_def_version` as a
  per-row stamped version tag (a different shape — every data row carries the
  definition version it was created under, not "N versions of one entity coexist as
  distinct rows") — not directly applicable, cited for completeness, not contradicted.

## §1 — THE SCHEMA DECISION

**Decision: in-place `version`/`version_id`/`status` columns on `service_catalog`
(representing the single CURRENT version) + a new sibling table
`service_catalog_versions` archiving every version a `publish` or `retire` supersedes.**
Not composite-key-versioned-table.

**Reasoning (must land in `Letflow.ServiceCatalog`'s moduledoc verbatim in
substance):**

1. **The consuming contract itself never asks for a specific version.**
   `Lookup.catalog_lookup/1` takes `service_id` alone — "give me the currently
   resolvable version of X," never "give me version N of X." Making `service_id`
   part of a composite primary key buys nothing at the one call site this whole
   requirement exists to wire up: under either schema shape, resolving a fresh
   reference means "find the row for this `service_id` whose status is ACTIVE" —
   an identical lookup shape. Composite-key only pays for itself if some caller
   needs to address a *specific* historical version directly by key, and no caller
   in this codebase does (or will, per the SCOPE FENCE — the read side of version
   history is an unbuilt future admin feature, not this requirement).
2. **Blast radius on `service_id`-as-sole-key is severe and needless.** `service_id`
   is used as a bare `String.t()` identifier in every existing caller and in code
   this requirement does not own: `Letflow.ServiceCatalog`'s own five functions
   (`Repo.get(Entry, service_id)` in `get_for_tenant/2`, `update_scope/2`,
   `delete/1`; the unique-PK constraint in `register/1`), `scope_validator_lookup/1`
   (`Repo.get(Entry, service_id)`), the `§4` referential guard (matches a
   `SERVICE_TASK` node's `service_id` attribute — a **version-less** reference at
   the graph layer, since `Letflow.Definitions.Graph`/`PromotionPlan` have no notion
   of "which version of this service" at all), and `web/src/api/services.ts`'s wire
   contract (`ServiceRecord.service_id`). Composite-keying `service_catalog` would
   force every one of those to gain a version parameter it structurally cannot
   supply (a `SERVICE_TASK` node's `attributes.service_id` names a service, not a
   service+version pair) — REQ-373's SCOPE FENCE forbids touching the graph layer,
   so this path is a non-starter, not merely more work.
3. **Every existing public function keeps its exact current signature, arity, and
   error contract**, satisfying WF-02 Step 1's "every current caller must keep
   working" requirement with zero named call sites needing update:
   `register/1`, `get_for_tenant/2`, `list_for_tenant/2`, `update_scope/2`,
   `delete/1`, `list_all/1`, `scope_validator_lookup/1` are all **untouched** by
   this design except `register/1`'s own insert body gaining four additional
   stamped fields on the struct it builds (see §2 — not a signature or
   `register_attrs()` shape change; a new service always starts life at version
   `"1"`/`ACTIVE`, exactly as `created_at`/`updated_at` are already stamped rather
   than caller-supplied).
4. **Existing-row migration is a pure additive backfill, not a reshape.** Four new
   nullable-then-backfilled columns on an existing table (DB-level `default:` values
   for the `ALTER`, see §4) — no primary key change, no data copy, no FK rewrite
   anywhere pointing at `service_catalog.service_id`.

**How existing rows migrate:** every pre-existing `service_catalog` row receives,
via DB-level column defaults on the same migration that adds the columns (no
separate data-migration script needed): `version = "1"`, `version_id =
gen_random_uuid()`, `status = "ACTIVE"`, `published_at = created_at` (backfilled via
an `execute/1` `UPDATE ... SET published_at = created_at` immediately after the
`ALTER`, since a column default can't reference another column), `retired_at = NULL`.
See §4 for the exact migration.

## §2 — What "version" vs. "identity" means, per field

`service_catalog`'s columns split into two groups, a distinction stated explicitly so
ELIXIR-DEV doesn't conflate them:

- **Identity/visibility fields — unversioned, untouched by publish/retire:**
  `service_id` (PK), `scope`, `owner_tenant_id`. These describe *who this service is*
  and *who may see it* — set by `register/1`, changed only by `update_scope/2`
  (unchanged by this design).
- **Version-specific technical fields — replaced wholesale by `publish/3`, frozen in
  place by `retire/1`:** `endpoint_url`, `request_schema`, `response_schema`,
  `required_auth`, `timeout_ms`, `retry_policy` — plus the four new lifecycle
  columns `version`, `version_id`, `status`, `published_at`, `retired_at`.

`get_for_tenant/2`/`list_for_tenant/2`/`list_all/1` return the `Entry` struct exactly
as today, now additionally carrying the five new fields riding along — no filtering
by `status` is added to any of these three (not asked for by any acceptance
criterion; an admin/tenant caller listing services still sees a RETIRED entry, same
as it already sees any other row — scoping to ACTIVE-only is explicitly **not** part
of this design, flagged as an open question in §9 OQ-2).

## §3 — New context-module functions

Both live in `Letflow.ServiceCatalog` (same module, same "plain context module, no
process" shape every existing function there already follows — no new module for
these two).

### §3.1 `publish/3`

`@typedoc "Version-specific technical fields only — never service_id/scope/owner_tenant_id."`
`@type publish_attrs :: %{required(:endpoint_url) => String.t(), optional(:request_schema) => String.t() | nil, optional(:response_schema) => String.t() | nil, optional(:required_auth) => atom() | String.t(), required(:timeout_ms) => integer(), optional(:retry_policy) => String.t() | nil}`

`@spec publish(service_id :: String.t(), version :: String.t(), publish_attrs()) :: {:ok, Entry.t()} | {:error, :not_found} | {:error, :duplicate_version} | {:error, Ecto.Changeset.t()}`

**Behavior (described, not written).** Runs inside one `Repo.transaction/1`:

1. Fetch the current row by `service_id` (`Repo.get(Entry, service_id)`). Not found
   → rollback `{:error, :not_found}`.
2. Reject `version == current_row.version` **and** any `version` already present in
   `service_catalog_versions` for this `service_id` (a fresh `Repo.exists?/1` query
   against the new table, keyed by the `(service_id, version)` unique index §4
   defines) → rollback `{:error, :duplicate_version}`. Version strings are opaque —
   no numeric-ordering assumption, matching `override_entry.version :: String.t()`'s
   own opaque-string treatment in `pin_resolver.ex`.
3. Insert into `service_catalog_versions` a full snapshot of the **current** row's
   version-specific fields (`version_id`, `version`, `endpoint_url`,
   `request_schema`, `response_schema`, `required_auth`, `timeout_ms`,
   `retry_policy`, `published_at`), stamping `retired_at = now` on the archive row —
   this runs **unconditionally**, regardless of whether the current row's `status`
   was already `ACTIVE` or `RETIRED` (a publish following a bare retire archives the
   retired row exactly as a publish following an active one archives that one; same
   code path, no status branch needed).
4. Update the `service_catalog` row in place via `Entry.publish_changeset/2` (new
   changeset function, §3.3): `version_id` = a freshly generated `Ecto.UUID.generate/0`,
   `version` = the caller-supplied `version`, `status = :ACTIVE`,
   `published_at = now`, `retired_at = nil`, plus the version-specific fields from
   `attrs`. `updated_at = now`, same stamping discipline `update_scope/2` already
   follows.
5. Commit; return `{:ok, updated_entry}`.

**Explicit invariant (must land verbatim in substance in the shipped moduledoc, so
ELIXIR-DEV never accidentally couples this to pin mutation):** `publish/3` touches
**only** `service_catalog` and `service_catalog_versions` rows. It performs **zero**
writes to `Letflow.EventStore`, zero reads/writes of any `INSTANCE_STARTED` or
`INSTANCE_PINS_REBOUND` event payload, and zero calls into
`Letflow.Engine`/`Letflow.Engine.PinResolver`. A pin is frozen into an
`INSTANCE_STARTED` event's payload at case-start time and is **never re-read live**
(`pin_resolver.ex`'s own "No fallback, ever" section) — `publish/3` cannot disturb an
already-recorded pin because there is no code path connecting the two subsystems at
all, not because `publish/3` takes special care to avoid one.

### §3.2 `retire/1`

`@spec retire(service_id :: String.t()) :: {:ok, Entry.t()} | {:error, :not_found} | {:error, :already_retired}`

**Behavior (described, not written).** Since this schema keeps exactly one live
(current) version per `service_id` at a time (§1), `retire/1` always targets *the*
row — no separate version argument is needed or accepted.

1. Fetch the row by `service_id`. Not found → `{:error, :not_found}`.
2. `status == :RETIRED` already → `{:error, :already_retired}` (an explicit error,
   not a silent idempotent `:ok` — matches this codebase's existing "no silent
   no-op" discipline, e.g. `pin_resolver.ex`'s `check_no_stray_overrides/2`).
3. Otherwise: update the row in place via `Entry.retire_changeset/1` (new changeset
   function, §3.3) — `status = :RETIRED`, `retired_at = now`, `updated_at = now`.
   **No `service_catalog_versions` insert here** — retiring without a following
   publish leaves the row's full technical data in place on `service_catalog`
   itself (still fetchable by `get_for_tenant/2`/`list_all/1`, just `status:
   :RETIRED`); the row only gets archived into the sibling table later, if and when
   a subsequent `publish/3` supersedes it (§3.1 step 3).
4. Return `{:ok, updated_entry}`.

**Explicit AC4 decision — retire FAILS OUTRIGHT, never falls through:** a fresh
`resolve/4` call against a `service_id` with no `ACTIVE` row (because its only row
was just retired and nothing has published since) gets `{:error, :not_found}` from
`catalog_lookup/1` (§5), which `resolve/4` already turns into
`{:error, {:unresolved_catalog_ref, ref}}` — the **existing** error variant, no new
one added. **Reasoning:** this schema enforces "at most one ACTIVE row per
`service_id`" as a structural invariant (there is only ever one live row at all —
§1); there is no second, older-but-still-ACTIVE row to "fall through to" by
definition, so "fall through" is not merely undesired here, it's not a coherent
option the schema can even express. Silently reactivating the most-recently-archived
version instead would also contradict `pin_resolver.ex`'s own "No fallback, ever"
philosophy (stated there for `pin_for/3`, but the same anti-surprise reasoning
applies): an admin who explicitly retired a service intended it to stop resolving,
full stop, until a human explicitly republishes.

**Why `pin_for/3` reads against an already-pinned instance are entirely unaffected
by retire — name exactly why (per the task's explicit ask):** `pin_for/3` takes
`pins :: [pinned_version()] | [effective_pin()]` — a list **already obtained** from
an `INSTANCE_STARTED` event payload (directly, or via
`reconstruct_effective_pins/2`'s replay-time fold) — and performs a pure
`Enum.find/2` over that in-memory list. It accepts no `Lookup.t()`, calls no
`Letflow.ServiceCatalog` function, and issues no `Repo` query of any kind. `retire/1`
changes rows in `service_catalog`/`service_catalog_versions`; `pin_for/3` never reads
either table, at any point, for any instance, retired-version or not. The two
functions are connected by zero shared code — this is the same "by construction, not
by care taken" argument as §3.1's publish invariant.

### §3.3 `Entry` — new schema field + two new changeset functions

**`status`'s Ecto representation (stated explicitly, to close the exact gap the
rework note on this design named):** `field(:status, Ecto.Enum, values: [:ACTIVE,
:RETIRED], default: :ACTIVE)` — plain `Ecto.Enum`, no `values:` remapping, mirroring
`required_auth`'s own uppercase-atom convention (§0: `:NONE, :API_KEY, :OAUTH2,
:MUTUAL_TLS`) rather than `scope`'s lowercase-atom one, since the migration's DB
`CHECK` constraint (§4) is `status IN ('ACTIVE', 'RETIRED')` and `Ecto.Enum` without an
explicit mapping serializes an atom to the DB verbatim by casing — `:ACTIVE` reads and
writes the string `"ACTIVE"` directly, no translation layer. Elixir-side code
therefore pattern-matches and constructs `:ACTIVE`/`:RETIRED` (uppercase) everywhere
in this design, never `:active`/`:retired` — every reference below and in §5 uses this
single casing.

`@spec publish_changeset(t(), map()) :: Ecto.Changeset.t()`
`@spec retire_changeset(t()) :: Ecto.Changeset.t()`

`publish_changeset/2` casts `[:version_id, :version, :status, :published_at,
:retired_at, :endpoint_url, :request_schema, :response_schema, :required_auth,
:timeout_ms, :retry_policy, :updated_at]`, `validate_required/2` on
`[:version_id, :version, :status, :published_at, :endpoint_url, :required_auth,
:timeout_ms]`, plus the same `validate_length/3`/`validate_number/3` pairs
`insert_changeset/2` already applies to `endpoint_url`/`timeout_ms`, and a
`unique_constraint/3` naming the new `idx_service_catalog_versions_service_id_version`
index (defensive — the application-level check in §3.1 step 2 is the primary guard,
this is the DB-level backstop, same "changeset checks are advisory, DB constraint is
authoritative" discipline the moduledoc already states for `insert_changeset/2`).

`retire_changeset/1` casts `[:status, :retired_at, :updated_at]`,
`validate_required/2` on all three.

## §4 — Migration

New file, `priv/repo/migrations/<timestamp>_add_service_catalog_versioning.exs`
(ELIXIR-DEV's call on exact timestamp; must sort after
`20260830000001_create_service_catalog.exs`). Same global-table treatment as the
base table (no `prefix:`, not registered in
`Letflow.TenantProvisioning.tenant_scoped_migrations/0` — this migration alters an
already-global table, so it inherits that table's own global-ness, not a fresh
decision).

**On `service_catalog` — four new columns via `alter table/2`, `execute/1` for the
data-dependent backfill:**

| Column | Type | Null | Default | Constraint |
|---|---|---|---|---|
| `version` | `:string` | not null | `"1"` | `CHECK (char_length(version) <= 255)` |
| `version_id` | `:binary_id` | not null | `fragment("gen_random_uuid()")` | none beyond not-null — this is the per-version identity `PinLookup.catalog_lookup/1` (§5) returns as `resolved_id` |
| `status` | `:string` | not null | `"ACTIVE"` | `CHECK (status IN ('ACTIVE', 'RETIRED'))` |
| `published_at` | `:utc_datetime_usec` | not null (added nullable, backfilled, then set not null) | — | no DB-level default — see backfill below |
| `retired_at` | `:utc_datetime_usec` | nullable | — | `NULL` while `status = 'ACTIVE'`; set on retire |

Column defaults handle every **pre-existing** row's `version`/`version_id`/`status`
for free at `ALTER TABLE` time. `published_at` cannot get a single fixed-value
default (it must mirror each row's own `created_at`), so the migration adds it
nullable, then runs one `execute/1` statement —
`UPDATE service_catalog SET published_at = created_at WHERE published_at IS NULL`
— followed by a second `execute/1` `ALTER TABLE service_catalog ALTER COLUMN
published_at SET NOT NULL`, the same two-step "nullable add, backfill, then
constrain" shape this codebase already uses wherever a new not-null column needs a
per-row (not constant) backfilled value.

Two new DB-level `CHECK` constraints via `create constraint/2` (same idiom the base
migration already uses for `chk_service_catalog_scope`/`chk_service_catalog_required_auth`
etc.): `chk_service_catalog_status` (`status IN ('ACTIVE', 'RETIRED')`) and
`chk_service_catalog_version_length` (`char_length(version) <= 255`).

**New table `service_catalog_versions`** (append-only archive of every version a
`publish`/subsequent-`publish` supersedes — see §1/§3.1), `primary_key: false`
(the PK is the caller-agnostic `version_id`, not an autogenerated surrogate):

| Column | Type | Null | Notes |
|---|---|---|---|
| `version_id` | `:binary_id` | not null | **primary key** — copied verbatim from the `service_catalog` row's own `version_id` at the moment it's archived, never regenerated |
| `service_id` | `:string` | not null | no FK — see below |
| `version` | `:string` | not null | opaque string, §9 OQ-4 |
| `endpoint_url` | `:string` | not null | snapshot of the row at archive time |
| `request_schema` | `:text` | nullable | snapshot |
| `response_schema` | `:text` | nullable | snapshot |
| `required_auth` | `:string` | not null | snapshot |
| `timeout_ms` | `:integer` | not null | snapshot |
| `retry_policy` | `:text` | nullable | snapshot |
| `published_at` | `:utc_datetime_usec` | not null | when this version became current (copied from the live row) |
| `retired_at` | `:utc_datetime_usec` | not null | when it was superseded/archived — always set, since a row lands here only once superseded |

Indexes: a single **unique** index, `idx_service_catalog_versions_service_id_version`,
on `(service_id, version)` — the DB-level backstop for `publish/3` step 2's
duplicate-version check and `publish_changeset/2`'s `unique_constraint/3` (§3.3).
No separate single-column `service_id` index is added: this composite index's
leading column already serves a `WHERE service_id = ?`-only query (standard B-tree
leftmost-prefix behavior), and no acceptance criterion or planned read path needs an
index shape that index can't already answer.

**Deliberate: no FK constraint from `service_catalog_versions.service_id` to
`service_catalog.service_id`.** `delete/1` (unchanged by this design, §1 point 3)
has an existing, tested error contract
(`{:error, {:referenced_by_active_definitions, ids}}` / `{:error, :not_found}` / `:ok`)
that this requirement must not silently alter. Adding a blocking FK would give
`Repo.delete/1` a **new**, previously-nonexistent failure mode (an FK violation on
any `service_id` with archived history) that `delete/1`'s current
`rescue Ecto.StaleEntryError` clause does not anticipate and this design is not
authorized to change (`delete/1` is not in REQ-373's scope). Leaving the column as a
plain indexed string accepts orphaned archive rows after a delete as data that
outlives its live entry — the same tolerance this codebase already has for a
`pinned_version.resolved_id` continuing to name a `service_id` that may no longer
resolve to anything (pins never re-verify against the catalog either, per
`pin_resolver.ex`). Flagged explicitly rather than silently decided — see §9 OQ-1.

## §5 — The real `PinResolver.Lookup` implementation

New module (this requirement's own naming call): `Letflow.ServiceCatalog.PinLookup`,
file `lib/letflow/service_catalog/pin_lookup.ex`. Not folded into `service_catalog.ex`
itself (unlike `scope_validator_lookup/1`) because this Lookup's shape needs to
compose with `PinResolver.default_lookup/0`'s existing `variable_schema_lookup`
rather than reimplement it (see below) — a distinct enough shape from
`scope_validator_lookup/1`'s single-field `service_lookup` to warrant its own file.

The shipped `@moduledoc` must state, verbatim in substance: this is the first real
(non-default) `Letflow.Engine.PinResolver.Lookup` implementation; it backs
`catalog_entry` resolution only — `module_lookup` stays a permanent `{:error,
:not_found}` stub, because PLC-01 does not exist in this codebase and is unscoped to
any stage (citing `pin_resolver.ex`'s own SCOPE GAP section by name, not silently
expanded).

`@spec build() :: Letflow.Engine.PinResolver.Lookup.t()`

**Behavior (described, not written).** `build/0` constructs a
`PinResolver.Lookup.t()` whose `module_lookup` and `variable_schema_lookup` fields
are taken **verbatim from `PinResolver.default_lookup/0`'s own result** (a struct
update expression reusing that call's two unrelated fields, not a re-declared copy —
guarantees byte-identical `module_lookup`/`variable_schema_lookup` behavior with zero
risk of drift between the two implementations) and whose `catalog_lookup` field is
replaced with this module's own `&catalog_lookup/1`. `build/0` performs no `Repo`
call itself — it only constructs closures; all I/O happens when `resolve/4` later
invokes the closure.

`@spec catalog_lookup(service_id :: String.t()) :: {:ok, %{resolved_id: String.t(), version: String.t()}} | {:error, :not_found}`

**Behavior (described, not written).** `Repo.get(Letflow.ServiceCatalog.Entry,
service_id)`:

- no row → `{:error, :not_found}` (identical to `default_lookup/0`'s permanent stub
  answer for an unregistered `service_id` — no behavior change for a definition that
  references a `service_id` nobody ever registered).
- row with `status: :ACTIVE` → `{:ok, %{resolved_id: version_id, version: version}}`
  (the row's own `version_id`/`version` columns).
- row with `status: :RETIRED` → `{:error, :not_found}` — the AC4 "fails outright"
  decision from §3.2, implemented at the one place `resolve/4` actually calls into.

No other function is added to this module — `module_lookup`/`variable_schema_lookup`
need no catalog-backed implementation in this requirement's scope.

## §6 — `Engine.create/2` wiring

**Call-site change (described, not written), exactly `lib/letflow/engine.ex`'s
existing `pin_lookup/2` private function, same name/arity/`@spec`:**

`@spec pin_lookup(attrs :: map(), prefix :: String.t() | nil) :: PinResolver.Lookup.t()`

Only the second argument to the function body's `Map.get/3` call changes: where it
currently reads `PinResolver.default_lookup()`, it instead reads
`Letflow.ServiceCatalog.PinLookup.build()`. `attrs[:pin_lookup]`, when a caller
supplies one, is still returned verbatim and untouched — this is purely a change to
what a caller who supplies **nothing** falls back to. `_prefix` remains ignored
(pre-existing, unrelated to this design).

**Preserving `variable_schema_lookup`/`module_lookup` behavior unchanged (explicit,
per the task's own ask):** because §5's `PinLookup.build/0` copies
`module_lookup`/`variable_schema_lookup` directly from `PinResolver.default_lookup/0`
rather than reimplementing either, every existing test/caller path that resolves a
`variable_schema` pin or hits the permanent `module_lookup` stub observes **exactly**
today's behavior after this wiring change — only a `catalog_entry` (`SERVICE_TASK`
`service_id`) reference's resolution outcome can differ (from an unconditional
`{:unresolved_catalog_ref, ref}` today, to a real `:resolved`/`:not_found` outcome
depending on the catalog's actual state).

**A new instance's own service-task pin resolution is otherwise unaffected in
shape:** `resolve/4`'s call site in `Engine.create/2`
(`lib/letflow/engine.ex:525-528`) is untouched — same four arguments, same position
in the `with` chain, same downstream `validate_initial_variables/2` /
`apply_inheritance/2` steps. This design changes only what `pin_lookup/2` constructs,
never how `create/2` calls it.

## §7 — Routes

Two new routes on the already-shipped `Letflow.Routers.AdminServices` (REQ-192),
same file, same `use Letflow.Api.AuthorizedRouter` router, gated by the
**already-shipped** `:AdminServicesManage` policy key — no new permission atom, no
`lib/letflow/api/authorization.ex` change (§0 confirmed the existing
`endpoint_policy_key/2` prefix-match clause already covers any new
`POST`/`PATCH`/`DELETE` path under `/admin/services`).

Two new route declarations, same `authz_post/3` macro the router already uses for
`POST "/"`: `authz_post "/:service_id/versions", :AdminServicesManage` dispatching to
a new `handle_publish/2` (given `conn` and `conn.params["service_id"]`), and
`authz_post "/:service_id/retire", :AdminServicesManage` dispatching to a new
`handle_retire/2` (same two arguments) — no macro/router-DSL change, purely two more
declarations following the four already there.

Full paths: `POST /api/v1/admin/services/:service_id/versions` (publish),
`POST /api/v1/admin/services/:service_id/retire` (retire) — `POST`, not `PATCH`,
for both: neither is a partial update of the existing resource's own fields (the
existing `PATCH /:service_id` already owns `scope`/`owner_tenant_id` updates); each
is an action that creates a new fact (a new version; a status transition), matching
this codebase's existing `POST .../activate`-style action-route convention
elsewhere (e.g. `Letflow.Routers.*` promotion/activation endpoints — none of which
this design needs to cite further since the convention is simply "an action that
isn't a field patch is POST").

**Handler behavior (described, not written):**

- `handle_publish/2`: parses a JSON body for `version` (required top-level string)
  plus the `publish_attrs()` fields (`endpoint_url`, `request_schema`,
  `response_schema`, `auth_method` → `required_auth` — same translation
  `handle_register/1` already performs — `timeout_ms`, `retry_policy`), calls
  `ServiceCatalog.publish/3` (`service_id`, `version`, `attrs`), maps
  `{:ok, entry}` → `201` + `service_record_json/1`-shaped body (extended with the
  five new fields — an `ELIXIR-DEV`-level JSON-shape decision, not fixed here since
  no `web/` consumer exists yet to freeze a wire contract against, unlike
  `handle_register/1`'s existing fields), `{:error, :not_found}` → `404`,
  `{:error, :duplicate_version}` → `409` (`Response.conflict/2`, same shape
  `handle_register/1` already uses for `:duplicate_service_id`), `{:error,
  %Ecto.Changeset{}}` → `422`.
- `handle_retire/2`: no request body. Calls `ServiceCatalog.retire/1`, maps
  `{:ok, entry}` → `200` + the same JSON shape, `{:error, :not_found}` → `404`,
  `{:error, :already_retired}` → `409` (`Response.conflict/2`).

## §8 — Acceptance-criteria mapping

| # | Acceptance criterion | Design element |
|---|---|---|
| 1 | version identity + ACTIVE/RETIRED status, schema choice stated with reasoning, migration + schema test | §1 (decision + reasoning), §4 (migration: `version`/`version_id`/`status`/`published_at`/`retired_at` columns + CHECK constraints + `service_catalog_versions` table) |
| 2 | publish doesn't alter an already-resolved pin; re-derive unchanged | §3.1 "Explicit invariant" paragraph — publish touches only `service_catalog`/`service_catalog_versions`, zero event-store I/O; pins are frozen at case-start and never re-read (cited from `pin_resolver.ex`) |
| 3 | new case after publish resolves the newly published version via real Lookup | §5 `catalog_lookup/1` (ACTIVE row → `:resolved`), §6 wiring makes `resolve/4` use it |
| 4 | retire prevents new resolution (fails or falls through, stated explicitly); already-pinned instance still resolves via `pin_for/3` with no error | §3.2 "Explicit AC4 decision" (fails outright, via existing `:unresolved_catalog_ref`) + "Why `pin_for/3` reads... are entirely unaffected" paragraph (structural: `pin_for/3` never queries the catalog) |
| 5 | `Engine.create/2`'s `pin_lookup/2` wired to real catalog-backed Lookup for `catalog_entry`; integration test confirms `:resolved` pin | §6 (exact call-site change) |
| 6 | publish/retire gated by existing `:AdminServicesManage`, not a new permission | §7 (both routes declared `:AdminServicesManage`; §0 confirms the existing prefix-match `endpoint_policy_key/2` clause covers them with zero `authorization.ex` change) |
| 7 | PLC-01/module_ref versioning stays explicitly out of scope, citing pin_resolver.ex's own SCOPE GAP language | §5 module `@moduledoc` (verbatim citation instruction), §0 bullet 2, this table's own row |
| 8 | `mix letflow.check` passes, real output quoted | ELIXIR-DEV's Step 2a responsibility — not a design element; noted here only so no AC is left unmapped |

## §9 — Open questions (not silently resolved)

- **OQ-1 (§4):** no FK from `service_catalog_versions.service_id` to
  `service_catalog.service_id`, to avoid silently changing `delete/1`'s existing,
  out-of-scope error contract. If REVIEWER judges orphaned archive rows after a
  delete are unacceptable, the alternative is an `ON DELETE CASCADE` FK — but that
  would need `delete/1`'s own moduledoc/tests touched to document the new
  cascading-delete behavior, which this requirement's `owned_modules` does list
  (`lib/letflow/service_catalog.ex`) but whose ACs do not ask for. Left to REVIEWER
  to decide rather than silently picked.
- **OQ-2 (§2):** `get_for_tenant/2`/`list_for_tenant/2`/`list_all/1` are left
  entirely unfiltered by `status` — a RETIRED entry remains just as visible to a
  listing/detail caller as an ACTIVE one. No acceptance criterion asks for
  status-based filtering on these read paths, but a future admin UI may want to
  distinguish "show retired services" as an explicit toggle rather than always
  showing everything. Not decided here — flagged for the eventual FRONTEND-DEV
  follow-on (or a future backend requirement) to raise if it matters.
- **OQ-3 (§7):** the publish/retire response JSON's exact key set for the five new
  fields (`version`, `version_id`, `status`, `published_at`, `retired_at`) is left to
  ELIXIR-DEV rather than fixed here, since no `web/src/api/services.ts` wire
  contract exists yet for these two new endpoints (unlike every existing field on
  `service_record_json/1`, which is frozen by that file today). ELIXIR-DEV should
  follow the same snake_case/ISO-8601-timestamp convention `service_record_json/1`
  already uses for consistency, but the exact key names for `version_id` (e.g.
  `"version_id"` vs. `"resolved_id"`) are not fixed by this design.
- **OQ-4 (§3.1):** whether a caller-supplied `version` string must follow any format
  (numeric, semver, free text) is left unconstrained, matching
  `pinned_version.version :: String.t()`'s own opaque-string treatment throughout
  `pin_resolver.ex` — no ordering/comparison is ever performed on it by this design
  or by `PinResolver`. If a future requirement wants "publish version N+1 must be
  numerically greater than N," that is a new constraint, not implied by anything
  here.
