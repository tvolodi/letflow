# REQ-191 — Service catalog core

Design for the `service_catalog` table and its backing context module,
`Letflow.ServiceCatalog`. Core only, no routes — REQ-192 adds the HTTP
surface. Ports R-Co `migrations/049_repository_service_catalog.sql` plus
`GBL-117_svc01_service_catalog_scope.sql` (SVC-01), and supplies the real
implementation seam three already-shipped modules (SVC-03's
`ServiceScopeValidator`, PIN-01's `PinResolver`, and `SolutionPack`'s
`service_catalog_entries` handling) already anticipate but cannot yet use.

**Scope boundary, restated from the requirement:** schema/migration, a
context module (`register/2`, `get_for_tenant/2`, `list_for_tenant/2`,
`update_scope/2`, `delete/2`), the two referential guards, a `Lookup`
implementation for `Letflow.Definitions.ServiceScopeValidator`, and an
explicit resolution of `SolutionPack`'s `service_catalog_entries` hard-fail.
No route, no controller (REQ-192). No `service_scope_validator.ex` change —
its algorithm and injectable-`Lookup` shape are frozen; this design supplies
an implementation of that shape only. No `pin_resolver.ex` change — PIN-01
AC1's `catalog_entry` resolution stays on its own injectable `Lookup`; wiring
a real one there is not this requirement's scope (the requirement text names
this explicitly under "NOT IN THIS REQUIREMENT"). No PLC-01/process-module
catalog (greenfield, unscoped to any stage).

## 0. Divergence from decision 0003 Decision B — flagged for REVIEWER sign-off

**REVIEWER sign-off:** ✅ **RECORDED, 2026-08-30, WF02-REQ191-20260830 Step
2d.**

> **REVIEWER SIGN-OFF: AGREE — `service_catalog` as a GLOBAL table is
> structurally justified, not merely precedent-matched.** The reasoning
> below stands on its own even independent of the `solution_pack_installs`
> citation: a `scope = :global` row is, by definition, one entity that must
> be visible identically from every tenant's query path simultaneously.
> Schema-per-tenant (Decision B) has no primitive for "one row, many
> schemas" short of either (a) replicating the row into every tenant schema
> and inventing a synchronization mechanism Decision B does not provide, or
> (b) a cross-schema query fan-out on every read — both strictly worse than
> one global table for a registry that is read far more often than written.
> The second half of the argument — `service_id` globally unique across
> *all* tenants and *both* scopes — is even less avoidable behind Decision
> B: a per-tenant unique index can only ever enforce uniqueness within its
> own schema, so global uniqueness would require either a second global
> table just to hold the uniqueness constraint (strictly more machinery
> than what this design proposes) or an application-level distributed lock
> with no natural home in this codebase. I checked the `solution_pack_installs`
> precedent this design cites and found the analogy imperfect but
> immaterial: that table stores one row per (tenant, pack) and is global for
> operational-infrastructure reasons, not because any single row must be
> visible from multiple tenants at once — a narrower situation than
> `service_catalog`'s. The design's citation slightly overstates "exactly
> the same shape," but `service_catalog` does not need that precedent to
> carry its own weight; it has an independent, sufficient structural
> argument, which is the stronger of the two anyway. On consequences: yes,
> a global table is a different security/scaling surface than
> schema-per-tenant — every function loses the "isolation by construction"
> `:prefix` gives every other S6 context module, and `get_for_tenant/2`'s
> visibility rule becomes the *entire* tenant-isolation mechanism for this
> data instead of a belt-and-suspenders check on top of physical
> separation. I read `get_for_tenant/2`/`list_for_tenant/2` and confirm
> both apply that rule correctly and identically (same visibility
> predicate, same `{:error, :not_found}` non-disclosure convention for a
> real-but-invisible row) — SECURITY-REVIEWER's INV-1 pass already verified
> this from the security angle; I confirm it holds up as the *sole*
> mechanism now, which is precisely why it matters that it's correct. This
> is a real, load-bearing architectural decision (not a rubber stamp), and
> I agree with it as stated.
>
> — REVIEWER, WF02-REQ191-20260830 Step 2d, 2026-08-30

Decision `0003-ecto-schema-strategy.md` Decision B makes schema-per-tenant
(Ecto `:prefix`-scoped tables, `tenant_id` retained intra-schema) the general
rule for business tables. `service_catalog` deliberately does **not** follow
that rule — it is a single table in the default/public schema, with no
`:prefix` option on its migration and no registration in
`Letflow.TenantProvisioning.tenant_scoped_migrations/0`.

**R-Co-grounded reason, structural not incidental:** a `scope = 'global'`
service-catalog entry is by definition referenceable by every tenant, and
`service_id` is unique across all tenants regardless of scope (R-Co's SVC-01
rule, `GBL-117_svc01_service_catalog_scope.sql`). Neither property can be
expressed by a per-tenant-schema copy: a per-tenant copy could not enforce
global `service_id` uniqueness across schemas without a cross-schema
mechanism Decision B doesn't provide, and a `scope = 'global'` row would need
to exist identically in every tenant's schema simultaneously, which is not
what schema-per-tenant means. This is exactly the same shape as REQ-041's
`solution_pack_installs`/`solution_pack_artefact_bases`/
`pack_update_resolutions` (`priv/repo/migrations/20260817083801_create_solution_pack_installs.exs`'s
own moduledoc: "install records are cross-tenant infrastructure") — this
design follows that already-accepted precedent rather than inventing a new
one. Both the migration file's header comment and
`Letflow.ServiceCatalog`'s moduledoc must state this reasoning verbatim (not
merely "global, see REQ-191") and flag it as a deliberate, reasoned
divergence from 0003 Decision B for REVIEWER sign-off — same wording
discipline as the `solution_pack_installs` migration's own header.

`owner_tenant_id`, when present, still carries a database-level foreign key
to `tenants.id` (the global `Letflow.Identity.Tenant` table) — same
`references(:tenants, type: :binary_id)` shape `tenant_schemas.tenant_id`
and `solution_pack_installs.tenant_id` already use. No `on_delete:` given
(Ecto/Postgres default `ON DELETE NO ACTION`), matching those two
precedents.

## 1. Migration — `service_catalog`

Global migration (`priv/repo/migrations/<timestamp>_create_service_catalog.exs`),
no `if prefix() do ... end` guard, not listed in
`tenant_scoped_migrations/0` — mirrors
`20260817083801_create_solution_pack_installs.exs` exactly. Header comment
states the §0 divergence reasoning.

Column list, transcribed verbatim from the requirement text (R-Co
`049_repository_service_catalog.sql` + `GBL-117`):

| Column | Type | Null | Default | Constraint |
|---|---|---|---|---|
| `service_id` | `:string` | not null | — | **primary key** (`primary_key: true` on the `add`, table declared `primary_key: false`); `CHECK (char_length(service_id) <= 255)`; globally unique across all tenants and both scopes by virtue of being the PK — no separate unique index needed |
| `endpoint_url` | `:string` | not null | — | `CHECK (char_length(endpoint_url) <= 2048)` |
| `request_schema` | `:text` | nullable | — | JSON text, uninterpreted by this module (mirrors `SolutionPack.packed_variable_schema.schema_content`'s "wire format is a JSON string" convention) |
| `response_schema` | `:text` | nullable | — | JSON text, same convention |
| `required_auth` | `:string` | not null | `"NONE"` | `CHECK (required_auth IN ('NONE', 'API_KEY', 'OAUTH2', 'MUTUAL_TLS'))` |
| `timeout_ms` | `:integer` | not null | — | `CHECK (timeout_ms BETWEEN 1 AND 3600000)` |
| `retry_policy` | `:text` | nullable | — | JSON text, uninterpreted by this module |
| `scope` | `:string` | not null | `"global"` | `CHECK (scope IN ('global', 'tenant'))` |
| `owner_tenant_id` | `:binary_id` | nullable | — | FK to `tenants.id` (§0); nullable only |
| `inserted_at` / `updated_at` | `:utc_datetime_usec` | not null | — | via `timestamps/1`, matching `solution_pack_installs`'s own `type: :utc_datetime_usec` choice — column names `created_at`/`updated_at` are the requirement text's own naming, so declare explicitly as `add :created_at, ...` / `add :updated_at, ...` with a hand-rolled trigger-free "set on write" discipline at the context-module layer (`register/2` stamps both, `update_scope/2` stamps `updated_at` only), rather than `timestamps/1`'s default `inserted_at`/`updated_at` names — the wire contract (`web/src/types/api.ts`'s `ServiceRecord.created_at`/`updated_at`) fixes these names, same reasoning `req176-dlq-core.md` §1 used for its own `created_at` column |

Plus the table-level consistency `CHECK` constraint, named
`chk_service_catalog_scope_owner_consistency`, expressed with `execute/1`
(the DSL has no multi-column boolean-`CHECK` primitive, same escape hatch
Decision 0003 §Dimension A names for `to_tsvector`-shaped needs). The
boolean condition the constraint enforces, in prose: the row is valid when
either (scope is "global" and owner_tenant_id is null) or (scope is "tenant"
and owner_tenant_id is not null) — every other combination is rejected by
the database.

Every other `CHECK` above (`service_id` length, `endpoint_url` length,
`required_auth` enum, `timeout_ms` range, `scope` enum) is likewise added via
`execute/1` `ALTER TABLE ... ADD CONSTRAINT ... CHECK (...)` clauses (or the
migration DSL's own `check:` option on `add/3` if the Ecto version in
`mix.exs` supports it — confirm at implementation time; the load-bearing
requirement is that every one of these is a **database-level** `CHECK`, not
an `Ecto.Changeset` validation, per AC1/AC2's explicit "not changeset-level
validation" wording).

Indexes:

- `idx_service_catalog_scope` on `(scope)` — backs `get_for_tenant/2`'s
  `scope = 'global' OR owner_tenant_id = ?` predicate's global half.
- `idx_service_catalog_owner_tenant_id` on `(owner_tenant_id)` — backs the
  tenant-owned half of the same predicate and the FK-referencing-side
  convention this codebase already follows.
- A composite index `idx_service_catalog_list_cursor` on
  `(created_at, service_id)` — backs `list_for_tenant/2`'s keyset
  pagination order (§3.3).

No `tenant_id` column on this table at all — Decision B's "retain
`tenant_id` intra-schema" clause only applies to tables that live inside a
tenant's own schema; this table doesn't, and `owner_tenant_id` already
carries the one tenant association this table needs. Stating this
explicitly closes the otherwise-obvious question of "where did `tenant_id`
go."

## 2. Ecto schema — `Letflow.ServiceCatalog.Entry`

`lib/letflow/service_catalog/entry.ex`. Ordinary `Ecto.Schema`, no
process. `@primary_key {:service_id, :string, autogenerate: false}` — the
first schema in this codebase whose primary key is a caller-supplied string
rather than a `binary_id`; state this explicitly in the moduledoc as a
deliberate divergence from every other schema's `binary_id`-PK convention,
justified by SVC-01's own global-uniqueness rule making `service_id` the
natural key (there is no separate surrogate id anywhere in the requirement
text, R-Co's migration, or the wire contract).

Field list (mirrors the migration column-for-column):

| Field | Ecto type |
|---|---|
| `service_id` | `:string` (primary key) |
| `endpoint_url` | `:string` |
| `request_schema` | `:string` (maps `:text`) |
| `response_schema` | `:string` |
| `required_auth` | `Ecto.Enum, values: [:NONE, :API_KEY, :OAUTH2, :MUTUAL_TLS]` |
| `timeout_ms` | `:integer` |
| `retry_policy` | `:string` |
| `scope` | `Ecto.Enum, values: [:global, :tenant], default: :global` |
| `owner_tenant_id` | `Ecto.UUID` |
| `created_at` | `:utc_datetime_usec` |
| `updated_at` | `:utc_datetime_usec` |

Two changesets:

- `insert_changeset/2` — casts every field above except `created_at`/
  `updated_at` (context-module-stamped, mirrors `process_definitions.status`'s
  "never castable from caller input" discipline for the timestamp pair);
  `validate_required/2` on `service_id`, `endpoint_url`, `required_auth`,
  `timeout_ms`, `scope`; `validate_length(:service_id, max: 255)`,
  `validate_length(:endpoint_url, max: 2048)`,
  `validate_number(:timeout_ms, greater_than_or_equal_to: 1,
  less_than_or_equal_to: 3_600_000)` as **advisory, pre-flight**
  changeset-level checks (fast, friendly error before the round-trip) that
  intentionally duplicate the DB `CHECK`s rather than replace them — the DB
  constraint is the one AC1/AC2 actually test against; `unique_constraint(:service_id)`
  as the typed fallback for the PK conflict; `foreign_key_constraint(:owner_tenant_id)`;
  a changeset-level scope/owner consistency check mirroring the DB `CHECK`
  (again advisory — the DB constraint is authoritative) via
  `check_constraint(:owner_tenant_id, name: :chk_service_catalog_scope_owner_consistency)`
  as the typed fallback mapping.
- `update_scope_changeset/2` — casts only `scope`, `owner_tenant_id`;
  `validate_required(:scope)`; same consistency check-constraint fallback.

## 3. Context module — `Letflow.ServiceCatalog`

`lib/letflow/service_catalog.ex`. Plain Ecto context module, no `opts[:prefix]`
parameter on any function — unlike every other S6 context module, this one's
backing table is global, so there is no tenant schema to scope queries into.
Every function instead takes an explicit `tenant_id :: Ecto.UUID.t()` argument
(the caller resolves it the same way it resolves `opts[:prefix]` elsewhere —
from the authenticated token — but this module receives the id directly,
not a prefix, since it never touches a tenant's own schema).

### 3.1 `register/2`

Signature (described, not composed): a 2-arity function. First argument —
`attrs`, a map keyed by the schema's own field names. Second argument —
functionally, something that lets the implementation confirm a named
tenant exists (concretely, ELIXIR-DEV may resolve this via a direct
`Letflow.Identity.Tenant` lookup rather than an injected function — see the
note below). Returns one of: `{:ok, Entry.t()}`; `{:error, changeset}` for
an ordinary validation failure; `{:error, :tenant_not_found}`; or
`{:error, :duplicate_service_id}`.

(Signature note: the second argument is described functionally here; the
concrete arity/shape ELIXIR-DEV picks — e.g. `register/1` with tenant
existence checked via a direct `Letflow.Identity.Tenant` query rather than an
injected function — is an implementation-level choice this design leaves
open per §7 OQ-1, since the requirement text does not fix the exact
signature the way it fixes the schema.)

`register_attrs()` is a map keyed by the schema's own field names (§2)
minus `created_at`/`updated_at`. Steps:

1. Build `Entry.insert_changeset/2` from `attrs`.
2. When `attrs.scope == :tenant`: query `Letflow.Identity.Tenant` by
   `attrs.owner_tenant_id` (global table, no prefix needed) — a miss returns
   `{:error, :tenant_not_found}` **before any insert is attempted** (AC:
   "rejected without creating a row"). When `attrs.scope == :global`, no
   tenant lookup is performed (there is nothing to check).
3. Stamp `created_at`/`updated_at` to `DateTime.utc_now/0` (truncated to
   `:microsecond`, matching `Dlq.enqueue/2`'s own truncation convention).
4. `Repo.insert/1` (no `prefix:` option — this table lives in the default
   schema). A PK-conflict `unique_constraint(:service_id)` failure maps to
   `{:error, :duplicate_service_id}` (a typed atom, not a raw changeset, so a
   caller can pattern-match the conflict case distinctly from a validation
   failure — mirrors `Dlq`/`SolutionPack`'s own typed-error-atom convention).

This is where AC "service_id is globally unique... even when the first is
tenant-scoped" and AC "a tenant-scoped registration naming a non-existent
tenant is rejected without creating a row" are satisfied: uniqueness by the
PK itself (no separate uniqueness logic needed — the whole point of a
`service_id`-keyed PK), non-existent-tenant rejection by the pre-insert
existence check in step 2.

### 3.2 `get_for_tenant/2`

Signature: a 2-arity function taking `service_id` (string) and `tenant_id`
(UUID string), returning `{:ok, Entry.t()}` or `{:error, :not_found}` — no
other error shape.

Single query: `Repo.get(Entry, service_id)` (no prefix). Then a pure,
in-memory visibility check — never a second query, never a different query
shape depending on the outcome (this is what makes the two failure/miss
paths structurally indistinguishable, not merely coincidentally
same-shaped):

- No row at all -> `{:error, :not_found}`.
- Row with `scope: :global` -> `{:ok, entry}`, any `tenant_id`.
- Row with `scope: :tenant, owner_tenant_id: ^tenant_id` -> `{:ok, entry}`.
- Row with `scope: :tenant, owner_tenant_id: <other>` -> `{:error, :not_found}`
  — **the same atom, not a `:forbidden`/`:unauthorized` variant** — this is
  the SVC-01 non-disclosure rule the requirement's AC3 names explicitly, and
  it is enforced by returning the identical error tuple both a genuinely
  missing `service_id` and a real-but-invisible one produce, not merely by
  giving both cases similar-sounding messages.

### 3.3 `list_for_tenant/2`

Signature: a 2-arity function taking `params` (a map carrying at least
`page_size` and an optional `cursor`, same shape as `Letflow.Dlq.list/2`'s
own `list_params()`) and `tenant_id` (UUID string), returning
`{:ok, %{items: [...], next_cursor: ... | nil}}` or
`{:error, :invalid_cursor}`.

Reuses `Letflow.Dlq.list/2`'s own cursor idiom exactly:
`page_size + 1` fetch, extra row dropped, `next_cursor` built from the last
kept row when the page is full, `nil` otherwise. Query predicate:
`where: e.scope == :global or e.owner_tenant_id == ^tenant_id`, ordered
`(created_at DESC, service_id DESC)` — deliberately choosing `service_id`
(the PK) as the keyset tiebreaker column instead of a synthetic `id`, since
this table has no other unique column to break ties on. Uses the same
`Letflow.Api.Pagination` cursor-encode/decode module every other S4/S6
list function delegates to (`Dlq.list/2`'s own dependency) — no new cursor
format invented.

### 3.4 `update_scope/2`

Signature: a 2-arity function taking `service_id` (string) and `new_attrs`
(a map with keys `scope` — `:global` or `:tenant` — and `owner_tenant_id` —
a UUID string or nil). Returns one of: `{:ok, Entry.t()}`;
`{:error, :not_found}`; `{:error, {:referenced_by_active_definitions,
conflicts}}` where `conflicts` is a list of maps each carrying `tenant_id`
and `definition_ids` (a list); or `{:error, changeset}` for an ordinary
validation failure.

1. `Repo.get(Entry, service_id)` — miss -> `{:error, :not_found}`.
2. Only when **narrowing** (`entry.scope == :global and new_attrs.scope ==
   :tenant`): run the referential guard (§4) against every tenant **other
   than** `new_attrs.owner_tenant_id` (the tenant the service is being
   assigned to is allowed to already reference it — only *other* tenants'
   references are the conflict the AC describes: "narrowing... is refused,
   naming the conflicting tenant ids, when **another** tenant's ACTIVE
   definition references it"). A non-empty guard result ->
   `{:error, {:referenced_by_active_definitions, conflicts}}`, no write.
3. **Widening** (`:tenant -> :global`) skips the guard entirely and always
   proceeds — the AC states this explicitly ("widening... is always
   allowed"); a global-to-global or tenant-to-tenant no-op scope change also
   skips the guard (neither narrows visibility).
4. `Entry.update_scope_changeset/2` + `Repo.update/1`, stamping `updated_at`.

### 3.5 `delete/2`

Signature: a function taking `service_id` (string), returning `:ok`,
`{:error, :not_found}`, or `{:error, {:referenced_by_active_definitions,
definition_ids}}` where `definition_ids` is a list of definition-id strings.
(Named `delete/2` in the requirement's own title, matching every other S6
context module's `opts`-carrying arity convention even though this module
otherwise has no `opts[:prefix]` to carry — ELIXIR-DEV should confirm
whether a second argument is needed here or whether `delete/1` is more
honest given this module's global-table shape; not fixed by this design.)

1. `Repo.get(Entry, service_id)` — miss -> `{:error, :not_found}`.
2. Referential guard (§4) against **every** tenant (delete has no
   "assigned tenant" exemption the way narrowing does) — a non-empty result
   -> `{:error, {:referenced_by_active_definitions, definition_ids}}`,
   naming the referencing definition ids per the AC's "the error names the
   referencing definition ids" wording.
3. `Repo.delete/1`.

## 4. The referential guard — structural, not `LIKE`-on-serialized-JSON

**Why this design diverges from R-Co's implementation, stated explicitly per
the requirement's own instruction:** R-Co's `bpm_active_defs_for_service`
runs `WHERE graph_json LIKE '%' || service_id || '%'` against the serialized
definition-graph text. This over-matches: any occurrence of the
`service_id` substring anywhere in the JSON — inside an unrelated string
value, a label, a comment-shaped attribute — counts as a reference, even
when no `SERVICE_TASK` node actually names that service. Letflow instead
walks the graph's actual node structure and matches only a `SERVICE_TASK`
node's `service_id` attribute — the same `(node_type, attribute_key)` pairing
`Letflow.Definitions.Graph`'s own `node_type` filtering already establishes
(`graph.ex`'s `Enum.filter(&(&1.node_type == :SERVICE_TASK))` idiom, reused
here at the SQL layer instead of after full deserialization, for a
cross-schema query — see below).

**Cross-schema mechanics.** `process_definitions` is a **per-tenant-schema**
table (Decision B) — a service's ACTIVE referencing definitions can live in
*any* tenant's own schema, not just one. This guard therefore cannot run as
a single `Ecto.Query` the way every other S6 module's own-schema query does;
it must iterate every provisioned tenant schema. Mechanics:

1. Enumerate every row of `Letflow.TenantProvisioning.Registration`
   (the global `tenant_schemas` table) — each row's `schema_name` /
   `tenant_id` pair names one tenant schema to check. (No existing public
   function enumerates all registrations today — `list_all/0` or similarly
   named is a small addition this requirement makes to
   `Letflow.TenantProvisioning`, a plain `Repo.all(Registration)` with no
   new query logic; flagged here rather than silently added, since the
   requirement text names `TenantProvisioning` only as a read dependency,
   not a module this requirement is chartered to extend — REVIEWER should
   confirm this minimal addition is acceptable scope.)
2. For each tenant schema (optionally excluding one, per `update_scope/2`'s
   §3.4 step 2 exemption), run one query against that schema's own
   `process_definitions` table, `prefix: schema_name`:
   `WHERE status = 'active' AND` a structural JSON check that at least one
   element of `graph->'nodes'` has `node_type = 'SERVICE_TASK'` AND that
   element's `attributes->>'service_id' = ^service_id` — expressed via
   `fragment/1` over `jsonb_array_elements(p0.graph->'nodes') AS node` with a
   `WHERE node->>'node_type' = 'SERVICE_TASK' AND node->'attributes'->>'service_id' = ?`
   correlated subquery (`EXISTS (...)`), never a `LIKE`. Select only `id`
   (the definition id) — nothing else is needed by any caller.
3. Collect `{tenant_id, [definition_id, ...]}` per schema with at least one
   match; a schema with zero matches contributes nothing. `delete/2` flattens
   this into a single `[definition_id]` list (its AC only requires naming
   definition ids); `update_scope/2` keeps the `tenant_id` grouping (its AC
   requires naming "the conflicting tenant ids").

This satisfies the AC's own proof-of-correctness test directly: a service
whose id string appears only inside an unrelated string elsewhere in some
definition's `graph` (never as a `SERVICE_TASK` node's `service_id`
attribute) produces zero matches from this structural query, because the
`EXISTS` predicate never inspects any JSON path except
`nodes[*].node_type`/`nodes[*].attributes.service_id` — it does not scan the
serialized document as text at all.

**Performance note, stated not solved:** this iterates every tenant schema
per call. That is the honest cost of a cross-schema referential check under
Decision B's isolation model — no index or materialized view spans schema
boundaries in Postgres. Acceptable for this requirement's scope (correctness
over the LIKE-bug is the AC, not latency), flagged as §7 OQ-2 for a future
requirement if tenant count ever makes this a measured problem.

## 5. `Lookup` implementation for `ServiceScopeValidator`

`Letflow.ServiceCatalog.scope_validator_lookup/0` (or a similarly named
0-arity function returning the struct — exact name is this module's own
choice, not fixed by the requirement) builds and returns a
`Letflow.Definitions.ServiceScopeValidator.Lookup.t()` — **without any edit
to `service_scope_validator.ex`** (confirmed by `git diff` per the AC).

- `service_lookup` (arity 1, `service_id -> service_lookup_result()`):
  calls `get_for_tenant/2`-shaped resolution, but note the `Lookup`'s own
  `service_lookup_fun` type takes **only** `service_id` (no `tenant_id` —
  see `service_scope_validator.ex` `@type service_lookup_fun`) while
  `get_for_tenant/2` needs a `tenant_id` to decide visibility. Resolution:
  this lookup function is built via `build/1`-style closure capturing the
  activating `tenant_id` at construction time (the same closure pattern
  `ServiceScopeValidator.build/1` itself uses for `Definitions.activate/2`'s
  hook) — the catalog-backed `Lookup` is therefore constructed per-activation
  (`scope_validator_lookup(tenant_id)`, one argument), not once globally.
  Internally: `Repo.get(Entry, service_id)` (no prefix — global table); no
  row -> `{:error, :not_registered}`; row found -> `{:ok, %{scope: entry.scope,
  owner_tenant_id: entry.owner_tenant_id}}` — a direct field mapping, no
  visibility filtering here, because `ServiceScopeValidator`'s own branch
  table (service_scope_validator.ex lines 257-301) already performs the
  global/tenant-match/mismatch comparison against the closure-captured
  `tenant_id` on the caller side of this function; this `Lookup` only needs
  to report what is registered, not decide visibility a second time.
- `plugin_lookup` (arity 2): **out of scope.** REQ-191 builds no plugin
  registry (PluginRegistry is stage S3, per `service_scope_validator.ex`'s
  own moduledoc). This design supplies a `plugin_lookup` that always returns
  `{:error, :not_registered}` — a real, harmless stub (INV-SSV-5 already
  makes "not registered" a pass on the plugin side, so this never blocks
  activation), stated explicitly as a stand-in for stage S3's real
  `PluginRegistry`, not a silent gap.

Test-facing AC ("a definition referencing a service not visible to its
tenant is rejected at activation, and one referencing a visible service
activates") is satisfied by constructing this `Lookup` from a real
`Letflow.ServiceCatalog` row via `Definitions.activate/2`'s existing
`opts[:service_scope_validator]` hook — no change to `activate/2` itself is
implied or made; that hook already exists (REQ-030) and already accepts any
2-arity function value.

## 6. `SolutionPack`'s `service_catalog_entries` hard-fail — resolution

**Decision: retain the hard-fail, do not make it functional in this
requirement.** `SolutionPack.install/3`'s `check_unsupported_sections/1`
(`solution_pack.ex` line 512-513) keeps rejecting any pack document whose
`service_catalog_entries` array is non-empty with
`{:error, :unsupported_pack_section}`.

**Why not wire it up now, given a catalog exists as of this requirement:**
making it functional means deciding an install-time policy this requirement
does not otherwise touch — whether a packed catalog entry installs
tenant-scoped-to-the-installing-tenant only (consistent with every other
`SolutionPack.install/3` write, which is single-tenant-schema-scoped per its
own INV-1 moduledoc section) or can install a `scope: "global"` entry
cross-tenant-visible to everyone (which no other `install/3` write does, and
which raises its own authorization question — should an arbitrary tenant's
installed pack be able to mint a globally-visible service any other tenant
then depends on?). That policy question is exactly the kind REQ-192's own
route-layer authorization design (SVC-04: `:AdminServicesManage` gates
direct catalog writes) is positioned to answer, and answering it here would
mean SolutionPack silently adopting a write-authorization stance this
requirement never asked it to take.

**Owning follow-up:** REQ-192 (the route/HTTP requirement immediately
following this one in `docs/requirements.yaml`, already scoped to the
service-catalog's admin-authorization surface) is named as the natural owner
of this decision, since it is the requirement that will already be deciding
the catalog's write-authorization policy for the HTTP surface — resolving
`service_catalog_entries` at the same time avoids inventing a second,
possibly inconsistent authorization stance later. If REQ-192 declines to
take it, the next solution-pack-touching requirement after it inherits the
naming. `Letflow.Definitions.SolutionPack`'s moduledoc (the
"`service_catalog_entries` — not supported" bullet) is updated by this
requirement's implementation step to say "still not supported — a
`Letflow.ServiceCatalog` now exists (REQ-191), but which tenant-visibility
policy a packed entry should install under is an authorization decision left
to REQ-192" rather than "Letflow has no service catalog," since the old
sentence is no longer true after this requirement ships and would be
actively misleading if left unedited.

A test asserting this outcome: given a pack document with a non-empty
`service_catalog_entries` array, `install/3` still returns
`{:error, :unsupported_pack_section}` and the transaction never opens (no
`Letflow.ServiceCatalog` row is written, no `process_definitions`/
`variable_schemas` row from the same document is written either — the
existing all-or-nothing, zero-query-before-transaction behavior is
unchanged). This is the "asserted by a test covering whichever outcome was
chosen" AC, satisfied by re-confirming the existing (unchanged) behavior
under a test named for this requirement rather than assuming REQ-078's
original test coverage already covers it under REQ-191's name.

## 7. Open questions

- **OQ-1 (signature detail).** §3.1's exact `register/2` arity/shape (single
  attrs map vs. attrs + injected tenant-check function) is left to
  ELIXIR-DEV's implementation judgment — the requirement text fixes the
  *behavior* (reject before insert, reuse `Letflow.Identity.Tenant` as the
  existence source) but not the exact function signature. Whichever is
  chosen, `register/2`'s two-argument arity in the requirement's own title
  ("register/2") should be preserved unless a documented reason forces
  otherwise.
- **OQ-2 (cross-schema guard cost).** §4's per-call full-tenant-schema-scan
  cost is unaddressed by this design beyond noting it — no caching,
  indexing, or async mechanism is proposed. Flagged for whoever owns S6
  operational-load review, not resolved here.
- **OQ-3 (`TenantProvisioning` registration-enumeration addition).** §4 step 1
  proposes a small new `Letflow.TenantProvisioning` function to list every
  `Registration` row. This requirement's own scope statement does not
  mention extending `TenantProvisioning` — flagged for REVIEWER to confirm
  this minimal, read-only addition (no behavior change to any existing
  function) is acceptable rather than scope creep.
- **OQ-4 (request/response schema validation).** `request_schema`/
  `response_schema` are stored as opaque JSON text, exactly like R-Co and
  exactly like `SolutionPack.packed_variable_schema.schema_content`'s own
  wire convention. This design does not validate them as JSON Schema
  documents (no `JsonSchemaShape.check/1` call) because no acceptance
  criterion requires it — noted so a future reviewer doesn't assume
  validation exists where none was asked for.

## 8. Acceptance-criteria cross-reference

| AC (abbreviated) | Where satisfied |
|---|---|
| scope/owner DB `CHECK`, two tests | §1 table-level `CHECK`, §2 (not changeset-level — DB constraint is authoritative) |
| `required_auth`/`timeout_ms` DB `CHECK`s | §1 |
| `get_for_tenant/2` three-way visibility, indistinguishable NOT FOUND | §3.2 |
| `service_id` globally unique across tenants | §1 PK, §3.1 step 4 |
| `register/2` rejects unknown tenant, no row created | §3.1 steps 1-2 |
| `delete/2` referential guard + structural (not substring) proof test | §3.5, §4 |
| `update_scope/2` narrow-refused/widen-allowed, names conflicting tenants | §3.4, §4 |
| `ServiceScopeValidator.validate/3` unchanged, real `Lookup` | §5 |
| migration + moduledoc state GLOBAL + 0003 divergence, REVIEWER flag | §0, §1 |
| `service_catalog_entries` hard-fail explicitly resolved + test | §6 |
| no route/controller file | Confirmed by this design's own scope boundary — nothing in §1-§6 touches `lib/letflow/routers/` or any controller |
| `mix test` / `mix compile --warnings-as-errors` pass | Implementation-phase verification, not a design-time artifact |
