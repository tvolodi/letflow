# REQ-297 design — entity column-promotion executor

Companion to `docs/migration/decisions/0024-entity-promotion-ddl-execution.md`
(the decision) and `lib/letflow/design/req295-entity-promotion-ddl-execution.md`
(REQ-295's companion design, which specified the function contracts below but
built none of them — no `lib/letflow/entities/`, `lib/letflow/tenant_provisioning*`
file was touched by REQ-295). REQ-296 then built `Letflow.Entities.Definition.DDL`,
a pure DDL-text generator with no I/O. **This requirement is the first to
actually implement `Letflow.TenantProvisioning.ColumnPromotion` and the nine
functions REQ-295 §2 specified, and the first to run DDL against a real
tenant schema.** No implementation code below — signatures, shapes, and the
concrete mechanism only.

## 0. What is re-derived from source, verbatim, before anything else

**REQ-295's exact atomicity model** (0024 §2, quoted): "A promotion is
**not** atomic across tenants... A promotion is instead a batch of
independent per-tenant attempts, each succeeding or failing on its own,"
tracked in the new `entity_column_promotions` table, one row per
`(tenant_id, entity_type, attribute)`, with a `status` enum including
`ddl_failed` and a `last_error` field. Repair is "a retry of the same DDL
step for that one `(tenant_id, entity_type, attribute)` row, not a
whole-batch re-run."

**REQ-295's exact backfill mechanism** (0024 §3, quoted): "Backfill runs as
a replay through `Letflow.Entities.Record.Projector.rebuild_projection/2`
... scoped with `entity_type: <the promoted type>` per its own `opts`
argument, `prefix:` the tenant's schema) — not as one inline
`UPDATE ... SET`." And on what a not-yet-backfilled record's read sees:
"What a concurrent read sees for a record not yet backfilled: the JSONB
value, via dual-write — never a partial column, and never a blocked read,"
enforced by `column_promotion_dual_write?/3` returning `true` for
`ddl_applied`/`backfilling`/`backfilled` and `false` before `ddl_applied`
and from `active` onward (design doc §2).

**REQ-295's exact function list** (design doc §2, re-confirmed against the
current file, post the two SECURITY-REVIEWER/REVIEWER re-check rounds that
fixed all mutating functions to a single `promotion_id` parameter — no
function anywhere retains a caller-supplied `tenant_id` alongside
`promotion_id`): `register_column_promotion/4`, `run_column_promotion/1`,
`run_column_promotion_for_all_tenants/1`, `retry_failed_column_promotion/1`,
`backfill_column_promotion/1`, `activate_column_promotion/1`,
`suspend_column_promotion/2`, `column_promotion_query_eligible?/3`,
`column_promotion_dual_write?/3`. This design implements every one of these
signatures **unchanged** — REQ-297 does not renegotiate REQ-295's
already-gated contract, only builds it.

**Re-verified against current code (not assumed):**
- `Letflow.TenantProvisioning.list_registrations/0` exists today exactly as
  named, `@spec list_registrations() :: [Registration.t()]`, a plain
  `Repo.all(Registration)` (`lib/letflow/tenant_provisioning.ex` line 226).
- `Letflow.TenantProvisioning.Registration.t()` has `tenant_id`,
  `schema_name`, `migrations_applied_at` (no `belongs_to`), validated by
  `@schema_name_format ~r/^tenant_[0-9a-f]{32}$/` (`registration.ex` lines
  24-31, 43).
- `Letflow.Entities.Definition.DDL.generate_table_ddl/2`,
  `structural_columns/0`, `promoted_columns/1`, `field_type_to_pg_type/1`,
  `promotion_trigger/2`, `valid_identifier?/1` all exist with the signatures
  quoted in §2/§3 below (`lib/letflow/entities/definition/ddl.ex`). Its own
  moduledoc states explicitly: "Deciding the physical `table_name` from an
  `entity_type`, executing the returned SQL against a real schema, and
  wiring promoted columns into any write path are all REQ-297/298's job,
  not this module's." This requirement is that job, for the promotion path.
- `Letflow.Entities.Record.Projector.rebuild_projection/2` exists today
  (`lib/letflow/entities/record/projector.ex` line 179) with
  `@type rebuild_opts :: [prefix: String.t(), entity_type: String.t() | nil]`
  and, critically, **its current implementation writes only to
  `entity_record_latest`** (via `Latest.insert_changeset/2`,
  `write_snapshots/3` lines 253-271) — it does **not** touch any
  per-entity-type physical table today, because no per-entity-type table has
  ever been created or written to by any shipped code. §5 below extends this
  function's `opts` (additively, no existing caller's behavior changes) so
  it can also do that, since 0024 names it as the backfill mechanism and no
  other code path exists that could.
- `Letflow.Entities.Records.create_record/2`, `update_record/2`,
  `delete_record/2` (`lib/letflow/entities/records.ex`) are the only live
  write path for entity records today, and write only to `entity_record_latest`
  via the private `upsert_record_latest/3` (lines 277-298), run as one
  `Multi.run(:upsert_record_latest, ...)` step inside `run_command/2`'s
  transaction (line 225-242) — the exact function 0024's Consequences
  section names as gaining "a dual-write branch." §4 below adds the branch.
- No pre-existing REQ-297 design artefact and no `column_promotion.ex` file
  exist yet (`ls lib/letflow/design/`, `ls lib/letflow/tenant_provisioning/`
  checked at design time: only `backfill.ex` and `registration.ex` are
  there).

## 1. The one load-bearing gap 0023/0024/req295 leave unnamed, made explicit here

**No decision record names who creates a per-entity-type physical table, or
who first populates it for an entity type's pre-existing records.** 0023
decided the storage *shape*; 0024 decided promotion *DDL execution*
(`ALTER TABLE ... ADD COLUMN`, explicitly not `CREATE TABLE` — 0024 §1: "The
new functions instead build and execute one `ALTER TABLE ... ADD COLUMN`
statement per promotion"); REQ-296 generates `CREATE TABLE` text but never
calls it and disclaims deciding `table_name` policy; REQ-295's design doc §4
lists "the exact DDL statement builder... a small, mechanical piece left to
REQ-296's own implementation" and REQ-296 in turn named table-naming policy
"explicitly left to REQ-297/the provisioning path." Table *lifecycle*
(create-if-absent, first population) is named nowhere as anyone's job. S10's
own gap table calls the wider "entity records" HTTP/lifecycle surface
"unowned... to file" (stage-10 doc, gap 10's row, referenced by REQ-300's
scope fence as "S10 gap 1, a separate unfiled requirement").

Per core-directives' "don't silently resolve an open question by guessing,"
this design does not invent a full entity-table-lifecycle requirement here.
Instead it makes the minimum, additive call needed for this requirement's
own acceptance criteria (an `ALTER TABLE ADD COLUMN` that actually lands on
a real table, a backfill that actually populates it, live writes that keep
it in sync during the promotion window) without expanding into constraint
activation (REQ-298), query-layer switch-over (REQ-299/300), or an HTTP
surface (unfiled): **the promotion executor owns creating a tenant's
per-entity-type table on first use (via REQ-296's `generate_table_ddl/2`,
using the current `Definition.t()`, so the table is created already
carrying every field currently promoted — not just the one attribute
triggering this particular promotion), and owns keeping that table's row
set in lockstep with `entity_record_latest` for exactly the window a
promotion is in flight.** Once no promotion for that entity type is
in-flight for a tenant (no `ColumnPromotion` row for that
`(tenant, entity_type)` in any of `pending..backfilled`), the table sits
inert, written only the next time a new promotion starts — this requirement
does not make the per-entity-type table the *primary* write target
outside a promotion window; REQ-299 (query-side switch-over) and any
future work decide when reads/writes stop depending on `entity_record_latest`
at all. **This is a design decision made here, beyond 0024/req295's literal
text, flagged explicitly for CODE-DESIGN-VALIDATOR/SECURITY-REVIEWER/REVIEWER
to confirm rather than discover unstated mid-build.**

## 2. New Ecto schema: `Letflow.TenantProvisioning.ColumnPromotion`

Exactly as specified in `req295-entity-promotion-ddl-execution.md` §1,
implemented verbatim:

- File: `lib/letflow/tenant_provisioning/column_promotion.ex`, sibling to
  `registration.ex`, same conventions (`@primary_key {:id, :binary_id,
  autogenerate: true}`, no `belongs_to` on `tenant_id`).
- New migration creates `entity_column_promotions` in the global/`public`
  schema (not tenant-scoped — not added to
  `tenant_scoped_migrations/0`'s manifest, and not added to
  `test/support/tenant_fixture.ex`'s `@expected_tenant_tables` oracle, since
  that oracle is for per-tenant-schema tables only — confirm this at
  implementation time per `docs/anti-patterns.md`'s "A new tenant-scoped
  migration's tables must be added to `@expected_tenant_tables`" entry,
  which does **not** apply here precisely because this table is global).
- Field list (identical to req295 §1's table): `id :: binary_id`,
  `tenant_id :: Ecto.UUID`, `entity_type :: String.t()`,
  `attribute :: String.t()`, `column_name :: String.t()`,
  `status :: String.t()` (one of `"pending" | "ddl_applied" | "backfilling"
  | "backfilled" | "active" | "ddl_failed" | "suspended"`),
  `query_eligible :: boolean()` (default `false`), `last_error :: String.t()
  | nil`, `attempted_at | ddl_applied_at | backfilled_at | activated_at ::
  NaiveDateTime.t() | nil`, `inserted_at`/`updated_at` timestamps.
- Indexes: unique `(tenant_id, entity_type, attribute)`; non-unique
  `(entity_type, attribute, status)`.
- `@type t :: %__MODULE__{}`.
- `@spec changeset(t(), map()) :: Ecto.Changeset.t()` — casts all fields
  above except timestamps; `validate_required([:tenant_id, :entity_type,
  :attribute, :column_name, :status])`; `validate_inclusion(:status, [seven
  values])`; `unique_constraint(:tenant_id, name: two-field index name)` for
  `(tenant_id, entity_type, attribute)`; `foreign_key_constraint(:tenant_id)`.

## 3. Table-naming policy (new, resolves REQ-296's named deferral)

New pure function, added to `Letflow.TenantProvisioning`:

```
@spec table_name_for_entity_type(entity_type :: String.t()) ::
        {:ok, table_name :: String.t()} | {:error, :invalid_entity_type}
```

Derivation: `"entity_" <> entity_type`, mirroring `schema_name_for_tenant/1`'s
own `"tenant_" <> hex` shape (one prefix, one validated body). Returns
`{:error, :invalid_entity_type}` unless `entity_type` already matches
`Letflow.Entities.Definition.Validator`'s own name-format rule — checked
here via `Letflow.Entities.Definition.DDL.valid_identifier?/1` (the same
public, independent regex `DDL` already exposes for exactly this reuse,
`~r/^[a-z][a-z0-9_]{0,63}$/`), not by importing the Validator's private
regex. This is the only place a physical per-entity-type table name is ever
derived; every function below that needs `table_name` calls this one
function rather than re-deriving the `"entity_" <>` prefix inline —
`docs/anti-patterns.md`'s "documented equality that silently stopped being
true" entry is exactly the failure shape a second inline derivation would
risk.

**Table existence is checked, never assumed.** Every function below that
issues DDL against a per-entity-type table first checks for its existence
via a parameterized `information_schema.tables` query
(`table_schema = $1 AND table_name = $2`, both bound as query parameters,
never interpolated) scoped to the tenant's `schema_name`. Absent —
create it (see §6). Present — proceed directly to the column-level
operation (see §7).

## 4. New functions on `Letflow.TenantProvisioning`

All nine signatures from req295 §2, unchanged, plus the two new
table-lifecycle helpers this design adds (§3, §6). Every mutating function
returns the module's established `{:ok, _} | {:error, _}` shape.

```
@spec register_column_promotion(
        entity_type :: String.t(),
        attribute :: String.t(),
        column_spec :: %{pg_type: String.t(), nullable: true},
        tenant_ids :: [Ecto.UUID.t()] | :all
      ) :: {:ok, [ColumnPromotion.t()]} | {:error, term()}
```
Creates one `pending` `ColumnPromotion` row per tenant (`:all` resolves via
`list_registrations/0` at call time, per this requirement's own tenant-
enumeration integration point below). `column_spec.pg_type` is supplied by
the caller from `Letflow.Entities.Definition.DDL.field_type_to_pg_type/1`
applied to the promoted `field_def()` — this function does not re-derive
the type mapping; it trusts the caller (the future entity-definition-edit
path, not built here) to have already called `DDL.field_type_to_pg_type/1`.
`nullable` is always `true`, per 0023's additive-only rule — this function
does not accept a caller override. Issues no DDL.

```
@spec run_column_promotion(promotion_id :: Ecto.UUID.t()) ::
        {:ok, ColumnPromotion.t()}
        | {:error,
           :promotion_not_found
           | :tenant_not_provisioned
           | {:column_type_conflict, existing_pg_type :: String.t(), requested_pg_type :: String.t()}
           | {:ddl_failed, Exception.t()}}
```
The one function that issues DDL. Steps, exactly as req295 §2 specifies plus
this requirement's own additive-only check (§7) and table-lifecycle step
(§6):

1. Load `ColumnPromotion` by `promotion_id` (`:promotion_not_found` if
   absent). Every subsequent value (`tenant_id`, `entity_type`, `attribute`,
   `column_name`) is read off this one row — no second, independently
   supplied identifier anywhere in this function, matching the fix
   SECURITY-REVIEWER's re-check already confirmed for req295 §2's text.
2. Resolve `schema_name` via `Repo.get_by(Registration, tenant_id:
   promotion.tenant_id)` (`:tenant_not_provisioned` if absent) — same path
   `replay_migrations/2` already uses.
3. Take the same per-schema `pg_advisory_xact_lock(hashtext($1))`
   `provision_tenant_schema/1` already takes, scoped to `schema_name`, for
   the duration of steps 4-6 (serializes concurrent promotions against the
   same tenant schema; two different tenants' promotions never contend).
4. `table_name_for_entity_type(promotion.entity_type)` →
   `{:error, :invalid_entity_type}` is not in this function's own `@spec`
   because `entity_type`/`column_name` were already validated as safe
   identifiers at `register_column_promotion/4` time (same defence-in-depth
   posture `DDL` itself takes — re-checked here anyway via
   `DDL.valid_identifier?/1` before any interpolation, raising an
   `ArgumentError` rather than silently proceeding if a stored row somehow
   holds an unsafe value, since that would mean a write path bypassed
   `register_column_promotion/4` entirely).
5. Table-lifecycle check (§6): create the per-entity-type table if absent,
   using the tenant's **current** `entity_type` `Definition.t()`.
6. Additive-only check (§7): query `information_schema.columns` for
   `(table_schema = schema_name, table_name, column_name = promotion.column_name)`.
   - Not found → proceed to step 7.
   - Found, existing type matches `column_spec`'s requested pg_type
     (compared via a small, explicit Postgres-type-name equivalence table —
     e.g. `"text"` ≡ `data_type = "text"`, `"bigint"` ≡ `data_type =
     "bigint"`, `"numeric(p,s)"` ≡ `numeric_precision`/`numeric_scale`
     matching — not a raw string compare against `data_type` alone, since
     Postgres reports `numeric` precision/scale in separate columns) →
     treat as an idempotent retry of a previously-successful `ALTER TABLE`
     (e.g., a retry after a partial failure at a later step): skip the
     `ALTER TABLE`, proceed straight to transitioning `ddl_applied`.
   - Found, type differs → **reject.** Set `status: "ddl_failed"`,
     `last_error: "column type conflict: existing <X>, requested <Y>"`,
     `attempted_at: now`. Return
     `{:error, {:column_type_conflict, existing, requested}}`. No DDL is
     issued. This is the additive-only enforcement mechanism the
     acceptance criteria requires — a concrete, real-Postgres-state check,
     not a heuristic on the definition alone (a definition-level check
     could not see a same-named column left behind by an entirely
     different, unrelated promotion history).
7. Execute `ALTER TABLE "<schema_name>"."<table_name>" ADD COLUMN
   "<column_name>" <pg_type>` (always nullable, per 0023 — no `NOT NULL`
   clause ever appears here). `table_name`, `column_name` both re-validated
   via `DDL.valid_identifier?/1` immediately before interpolation (defence
   in depth matching `DDL`'s own posture); `pg_type` is never
   caller-free-text — it only ever comes from
   `DDL.field_type_to_pg_type/1`'s own fixed output set, checked against
   that same closed set here before use.
8. On success: `status: "ddl_applied"`, `ddl_applied_at: now`,
   `last_error: nil`. On a raised DDL exception: `status: "ddl_failed"`,
   `last_error: Exception.message/1`, `attempted_at: now`, return
   `{:error, {:ddl_failed, exception}}` — this tenant's row moves to
   `ddl_failed`; no other tenant's row is touched (per-tenant, no shared
   transaction across tenants).

```
@spec run_column_promotion_for_all_tenants(
        promotion_ref :: {entity_type :: String.t(), attribute :: String.t()}
      ) :: %{ok: [ColumnPromotion.t()], failed: [ColumnPromotion.t()]}
```
Loads every `pending` row for `promotion_ref`, calls `run_column_promotion/1`
per row, does not abort on first failure (0024 §2). Returns both lists.

```
@spec retry_failed_column_promotion(promotion_id :: Ecto.UUID.t()) ::
        {:ok, ColumnPromotion.t()} | {:error, :promotion_not_found | term()}
```
Loads by `promotion_id`, requires `status == "ddl_failed"`
(`{:error, :not_ddl_failed}` otherwise — a new, small error atom this design
adds since req295 §2's text names the precondition but not its own failure
atom), re-invokes `run_column_promotion/1` for the same row, clearing
`last_error` on success. Idempotent to call repeatedly.

```
@spec backfill_column_promotion(promotion_id :: Ecto.UUID.t()) ::
        {:ok, ColumnPromotion.t()}
        | {:error, :promotion_not_found | :not_ddl_applied | {:backfill_incomplete, map()} | term()}
```
Loads by `promotion_id`; requires `status in ["ddl_applied", "backfilling"]`
(`{:error, :not_ddl_applied}` otherwise). Transitions to `"backfilling"`
(if not already), then:

1. Calls `Letflow.Entities.Record.Projector.rebuild_projection/2` with
   `prefix: schema_name, entity_type: promotion.entity_type` (the exact
   two-key `opts` shape already public today — no third opt needed for
   *this* call, since §5 below makes the per-entity-type-table write an
   unconditional part of `rebuild_projection/2`'s own behavior whenever
   that table exists, not something the caller has to ask for per
   promotion).
2. On `{:ok, %{records_rebuilt: n}}`: runs the verification check —
   `SELECT count(*) FROM "<table_name>" WHERE deleted = false` compared
   against `SELECT count(*) FROM entity_record_latest WHERE entity_type =
   $1 AND deleted = false` for this tenant (row-count parity, per 0024 §3's
   named check; the exact query left flexible by req295 §4, fixed here as
   this comparison). Parity → `status: "backfilled"`, `backfilled_at: now`.
   Mismatch → row **stays** `"backfilling"`,
   returns `{:error, {:backfill_incomplete, %{expected: _, actual: _}}}` —
   caller may call again (replay via `rebuild_projection/2` is idempotent,
   a full delete+reinsert per entity type each time).
3. On `rebuild_projection/2` returning an error tuple: row stays
   `"backfilling"`, that error is returned unchanged (wrapped in this
   function's own `{:error, _}`).

```
@spec activate_column_promotion(promotion_id :: Ecto.UUID.t()) ::
        {:ok, ColumnPromotion.t()} | {:error, :promotion_not_found | :not_backfilled}
```
Loads by `promotion_id`; requires `status == "backfilled"`. Sets
`status: "active"`, `query_eligible: true`, `activated_at: now`. Issues no
DDL, touches no table.

```
@spec suspend_column_promotion(promotion_id :: Ecto.UUID.t(), reason :: String.t()) ::
        {:ok, ColumnPromotion.t()} | {:error, :promotion_not_found | :not_active}
```
Loads by `promotion_id`; requires `status == "active"`. Sets
`query_eligible: false` only — `status` stays `"active"` (0024 §4:
deliberate, preserves "reached active at least once"). `reason` is stored
in `last_error` (repurposed as a free-text note field for this transition
only — flagged here rather than silently overloading the field's name
without comment) or a new `suspend_reason :: String.t() | nil` column if
ELIXIR-DEV/REVIEWER prefer a dedicated field; **left as an explicit open
question below** rather than silently picked, since req295 §1's field list
does not name a reason-storage field at all.

```
@spec column_promotion_query_eligible?(
        tenant_id :: Ecto.UUID.t(), entity_type :: String.t(), attribute :: String.t()
      ) :: boolean()
```
`Repo.get_by(ColumnPromotion, tenant_id: tenant_id, entity_type: entity_type,
attribute: attribute)` → `query_eligible` field, or `false` if no row
exists. Read-only, no lock.

```
@spec column_promotion_dual_write?(
        tenant_id :: Ecto.UUID.t(), entity_type :: String.t(), attribute :: String.t()
      ) :: boolean()
```
Same lookup; `true` iff `status in ["ddl_applied", "backfilling",
"backfilled"]`; `false` for no row, `"pending"`, `"ddl_failed"`, or
`"active"`.

## 5. Tenant enumeration

`register_column_promotion/4`'s `:all` case, and any future admin surface,
enumerate provisioned tenants via `Letflow.TenantProvisioning.list_registrations/0`
(already public, `Repo.all(Registration)`) — reused as-is, per the
requirement's own instruction not to invent a second enumeration mechanism.
`run_column_promotion_for_all_tenants/1` does **not** call
`list_registrations/0` itself — it fans out over already-created
`ColumnPromotion` rows (one per tenant, created at `register_column_promotion/4`
time), which is the correct scope: a promotion already knows which tenants
it targets from its own rows, and a tenant provisioned *after*
`register_column_promotion/4` ran is simply not part of that promotion
batch (a new promotion, or a follow-up `register_column_promotion/4` call
for that one tenant, covers it — not silently swept in by re-querying
`list_registrations/0` mid-fan-out).

## 6. Table-lifecycle step (new, resolves §1's gap for this requirement's own needs)

```
@spec ensure_entity_table(schema_name :: String.t(), entity_type :: String.t()) ::
        :ok | {:error, {:ddl_failed, Exception.t()}} | {:error, term()}
```
Private to `Letflow.TenantProvisioning` (not part of req295 §2's public
list — an internal step `run_column_promotion/1` calls, per §1's decision).
Checks `information_schema.tables` (parameterized, §3). If present: `:ok`,
no-op. If absent:

1. Loads the entity type's current active `Definition.t()` for this tenant
   (via whatever REQ-226/230 context module already resolves an active
   definition by `entity_type` + `prefix` — the same lookup
   `Letflow.Entities.Records.fetch_active_definition/2` already performs;
   reused, not re-derived).
2. Calls `Letflow.Entities.Definition.DDL.generate_table_ddl(definition,
   table_name)` — the **full** `CREATE TABLE`, carrying every field
   currently `queried: true` or FK-referenced in the current definition,
   not just the one attribute this particular promotion targets (so a
   brand-new table starts already consistent with whatever else has been
   promoted for this entity type by the time this promotion runs).
3. Executes the returned SQL via `Repo.query!/3` under the same
   `pg_advisory_xact_lock` already held by the caller (§4 step 3) — one
   `CREATE TABLE`, not wrapped in `IF NOT EXISTS` (the existence check in
   step 0 above is the sole guard; a raw `CREATE TABLE IF NOT EXISTS` would
   silently succeed against a table with a *different* column set created
   by some other path, which this design does not want to paper over).
4. On success, immediately calls `Letflow.Entities.Record.Projector.rebuild_projection/2`
   for `(prefix: schema_name, entity_type: entity_type)` to populate the
   freshly-created table with every existing record's current projected
   state (§5's extension makes this call populate the per-entity-type
   table, not just `entity_record_latest`) — this is the "first population"
   named in §1, folded into table creation rather than left as a second,
   separately-triggered step, since an empty freshly-created table with
   existing un-migrated records would otherwise silently under-count in the
   very next `backfill_column_promotion/1` verification check.

Returns `{:error, {:ddl_failed, exception}}` on a `CREATE TABLE` failure
(propagates to `run_column_promotion/1`'s own `ddl_failed` transition, same
as an `ALTER TABLE` failure) or whatever `rebuild_projection/2` itself
returns on its own failure path.

## 7. Additive-only enforcement — concrete mechanism (summary of §4 step 6)

Two independent lines of defence, both real-Postgres-state checks, neither a
heuristic on the definition alone:

1. **No DROP/narrowing ALTER anywhere in the executor's code.** Grep-able:
   the only DDL verbs this module ever constructs are `CREATE TABLE` (§6,
   full column set, never re-run against an existing table) and
   `ALTER TABLE ... ADD COLUMN` (§4 step 7, never `DROP COLUMN`, never
   `ALTER COLUMN ... TYPE`). This is a static property of the code, checked
   at PR time via `git diff | grep -iE 'DROP COLUMN|ALTER COLUMN.*TYPE'`
   returning zero hits (AC5).
2. **Type-conflict rejection at DDL time** (§4 step 6): before any
   `ALTER TABLE ADD COLUMN`, `information_schema.columns` is queried for the
   exact `(table_schema, table_name, column_name)` triple; a pre-existing
   column with a conflicting type is rejected with
   `{:error, {:column_type_conflict, existing, requested}}` and the
   promotion row moves to `ddl_failed` — never silently coerced (no
   `USING` cast is ever constructed), never silently ignored (the caller
   gets a distinguishable error tuple, not `{:ok, _}`).

## 8. Dual-write wiring into the live write path

`Letflow.Entities.Records`'s private `upsert_record_latest/3`
(`lib/letflow/entities/records.ex` lines 277-298) is the exact function
0024's Consequences section names ("an amendment to `upsert_record_latest/3`'s
existing two clauses, not a new clause shape"). This design adds one new
`Multi.run/3` step, `:dual_write_promoted_columns`, appended immediately
after the existing `:upsert_record_latest` step in `run_command/2`'s pipeline
(`lib/letflow/entities/records.ex` line 225-242) — covering **all three**
callers (`create_record/2`, `update_record/2`, `delete_record/2`, since all
three funnel through the one shared `run_command/2`; per
`docs/anti-patterns.md`'s "established template-substitution mechanism
applied to two of three sibling paths, not all three," this must not be
added to only `create_record/2`/`update_record/2` and skipped for
`delete_record/2`, since a deleted record's promoted-column row must still
carry `deleted: true` in the per-entity-type table too).

```
@spec dual_write_promoted_columns(repo :: Ecto.Repo.t(), changes :: map(), ctx :: map()) ::
        {:ok, :skipped | :written} | {:error, term()}
```
Private to `Letflow.Entities.Records`. Behavior:

1. `column_promotion_dual_write?(tenant_id, ctx.entity_type, _any_attribute)`
   is checked per-attribute, not once — this function calls
   `Letflow.TenantProvisioning.list registrations of promotions in flight
   for (tenant_id, entity_type)` (a small new read helper,
   `column_promotions_in_flight/2 :: (tenant_id, entity_type) -> [ColumnPromotion.t()]`,
   filtering `status in ["ddl_applied", "backfilling", "backfilled"]`) —
   **not** `column_promotion_query_eligible?/3`/`column_promotion_dual_write?/3`
   called once per possible attribute name, since the live write path does
   not otherwise know which attributes might be mid-promotion.
2. If the list is empty: `{:ok, :skipped}` — no table touched, no query
   issued beyond the one lookup (a tenant/entity type with no promotion
   ever in flight pays one extra indexed read per write, nothing more).
3. If non-empty: the per-entity-type table is guaranteed to exist already
   (a `ColumnPromotion` row past `pending` implies `ensure_entity_table/2`
   already ran for it, §6 step 4) — issues one `INSERT ... ON CONFLICT
   (record_id) DO UPDATE` against the per-entity-type table, populating
   every column named by an in-flight `ColumnPromotion` row from
   `ctx.field_values` (cast via §9's shared helper) **plus** the structural
   columns (`id`, `record_id`, `field_values`, `deleted`,
   `entity_def_version`, `last_event_global_seq`, timestamps) from `ctx` —
   the same field set `upsert_record_latest/3` itself already writes to
   `entity_record_latest`, so the two rows never carry different structural
   metadata. `field_values` is written into the per-entity-type table's own
   `field_values` **jsonb** column unconditionally (0024 §3 step 1: "the
   blob key is not dropped the moment the column exists; that only happens
   at active"), independent of any single attribute's own dual-write flag.
4. Never touches `entity_record_latest` — that table's write already
   happened in the preceding `:upsert_record_latest` step; this step is
   additive only.

## 9. Backfill's write side — extending `rebuild_projection/2`

`Letflow.Entities.Record.Projector.rebuild_projection/2`'s public `@spec` is
**unchanged** (`rebuild_opts :: [prefix: String.t(), entity_type: String.t()
| nil]`) — no new opt is added, so every existing caller (if any exist
beyond this requirement) is unaffected. What changes is `write_snapshots/3`'s
internal behavior (currently: delete-all + reinsert into `Latest` only, per
`lib/letflow/entities/record/projector.ex` lines 253-271):

**New private step, `maybe_write_entity_table_snapshots/3`, called from
`write_snapshots/3` immediately after its existing `Latest` delete+reinsert,
inside the same `Repo.transaction/1`:**

1. `table_name_for_entity_type(entity_type)` → check existence
   (`information_schema.tables`, same query as §3). Table absent → no-op
   (a rebuild for an entity type with no per-entity-type table yet — the
   ordinary case for every entity type that has never had a column
   promoted — does nothing extra, preserving today's behavior exactly).
2. Table present → for every `snapshot` already computed for `Latest`
   (same `snapshots` list, no second event-log read), issues one
   `DELETE FROM "<table_name>"` + per-snapshot `INSERT`, mirroring
   `write_snapshots/3`'s own existing delete-all-then-reinsert-per-entity-type
   pattern for `Latest` — writing structural columns plus every column
   `DDL.promoted_columns/1` reports for the entity type's **current**
   definition (cast per §9's shared helper), not only the one attribute the
   in-progress promotion targets — so a rebuild started for promotion N
   also correctly repopulates any promotion 1..N-1 columns that already
   reached `active` for this tenant (their dual-write may have stopped, but
   a full-history replay must still get them right).
3. Row-count parity between this insert and the `Latest` reinsert is
   guaranteed by construction (same `snapshots` list drives both writes in
   the same transaction) — `backfill_column_promotion/1`'s own verification
   query (§4) is a defence-in-depth re-check against a second, independent
   query path, not the only place this is enforced.

## 10. Shared value-casting helper (used by §8 and §9 alike)

```
@spec cast_promoted_value(raw_value :: term(), pg_type :: String.t()) :: term()
```
Private, lives on `Letflow.TenantProvisioning` (or a small shared module
alongside `ColumnPromotion` if ELIXIR-DEV finds that cleaner — not
prescribed here) since both the live dual-write path (§8) and the backfill
write path (§9) need the identical mapping from a `field_values["attr"]`
JSON-decoded value to the Ecto/Postgres-bound value for `pg_type`. Mirrors
`DDL.field_type_to_pg_type/1`'s own closed dispatch (`"text"` → pass through
as a binary; `"bigint"` → integer; `"numeric(...)"`/`"numeric"` → `Decimal.t()`;
`"boolean"` → boolean passthrough; `"date"` → `Date.t()`; `"timestamp(6)
without time zone"` → `NaiveDateTime.t()`) — one shared cast table, not two
independently hand-maintained copies (the exact drift `docs/anti-patterns.md`
warns about generally, and REQ-299's own acceptance criteria warns about
specifically for the *enumeration* half of this same promoted-column
concept).

## 11. Moduledoc citation requirement (AC6)

`Letflow.TenantProvisioning.ColumnPromotion`'s and the extended
`Letflow.TenantProvisioning`'s moduledocs must each state, in their own
words: this module implements all four of 0024's sub-answers — (1) the
mechanism (`Letflow.TenantProvisioning`, extended, not a second module,
`ALTER TABLE`/`CREATE TABLE` issued directly); (2) partial-failure
(per-tenant, `entity_column_promotions`, no cross-tenant atomicity); (3)
backfill (replay through `rebuild_projection/2`, dual-write during the
window); (4) rollback (`suspend_column_promotion/2`, allowlist-exclusion,
never a drop/narrow) — and cite both
`docs/migration/decisions/0024-entity-promotion-ddl-execution.md` and
`lib/letflow/design/req295-entity-promotion-ddl-execution.md` by path.

## 12. Test-coverage plan (maps every AC to a concrete test)

| AC | Test |
|---|---|
| AC1 (DDL applied to every tenant) | Provision ≥2 tenant schemas via the real `provision_tenant_schema/1` + `replay_migrations/2`; seed an entity `Definition.t()` fixture with one `queried: true` field for both; call `register_column_promotion/4` with `:all`, then `run_column_promotion/1` for each resulting row; query `information_schema.columns` directly (raw `Repo.query!/3`, not the executor's own return value) against both schemas, assert the column exists in both. |
| AC2 (per-tenant partial failure) | Two tenants; manually pre-create a same-named column with a *conflicting* type on tenant B's table before calling `run_column_promotion/1` for both rows; assert tenant A's row reaches `ddl_applied` and its column exists, tenant B's row is `ddl_failed` with `last_error` set and no column-type change occurred on B. |
| AC3 (backfill mechanism + not-yet-backfilled read) | Create ≥2 pre-existing records via `create_record/2` before promotion starts; register + run the promotion (`ddl_applied`); assert (via a test-injected trace, e.g. `:telemetry` or a `Mox`-free call-count on a small seam, or simplest: asserting `records_rebuilt` in `backfill_column_promotion/1`'s success tuple matches the pre-existing record count, which is only possible if `rebuild_projection/2` actually ran) that `rebuild_projection/2` was invoked; assert that *before* `backfill_column_promotion/1` runs, a direct read of `entity_record_latest`'s `field_values` for those records already has the correct value (dual-write's `field_values` side, present from the moment the record was written, unaffected by promotion state) while the per-entity-type table's new column is still `NULL` for those pre-existing rows — the concrete "not-yet-backfilled" read-behavior assertion. |
| AC4 (type-conflict rejection) | Pre-create a column via one promotion reaching `active`; register a second promotion for the same `column_name` with a different `pg_type`; call `run_column_promotion/1`; assert `{:error, {:column_type_conflict, _, _}}`, row is `ddl_failed`, and `information_schema.columns` still reports the original type (not coerced). |
| AC5 (no drop/narrow) | `git diff main...HEAD -- lib/letflow/tenant_provisioning.ex lib/letflow/tenant_provisioning/column_promotion.ex lib/letflow/entities/records.ex lib/letflow/entities/record/projector.ex \| grep -iE 'DROP COLUMN\|ALTER COLUMN.*TYPE'` — zero hits, quoted in the completion report. |
| AC6 (moduledoc citation) | A test asserting (via `Code.fetch_docs/1` or a simple `File.read!/1` + substring check on the two moduledocs) that both cite `0024-entity-promotion-ddl-execution.md` and `req295-entity-promotion-ddl-execution.md` by path, and name all four sub-answers by number or by the same words used in §11 above. |
| AC7 (`mix letflow.check`) | Run at PR time, real output quoted. |

Additional tests this design implies beyond the seven ACs, needed to prove
§6/§8/§9's own extensions are correct (not separately acceptance-criteria'd,
but load-bearing for AC1/AC3 to be meaningful): a table-does-not-exist-yet
test asserting `ensure_entity_table/2` creates it with the full current
promoted-column set (not just the one attribute being promoted this time);
a live-write-during-backfill test asserting a record created *while*
`status == "backfilling"` lands correctly in the per-entity-type table via
`dual_write_promoted_columns/3`, not just pre-existing records via replay;
a suspend-then-reactivate test exercising `suspend_column_promotion/2`
followed by a corrective `backfill_column_promotion/1` re-run (0024 §4's
repeatable `active -> backfilling -> backfilled -> active` cycle).

## 13. Open questions (explicit, not silently resolved)

- **`suspend_column_promotion/2`'s `reason` storage field** (§4): reusing
  `last_error` vs. a new dedicated column — req295 §1's field list names
  neither explicitly for this purpose. Left for ELIXIR-DEV/REVIEWER to pick,
  flagged rather than silently defaulted.
- **§1/§6's table-lifecycle ownership is this design's own extrapolation**,
  not literal text in 0023/0024/req295 — flagged in full in §1, repeated
  here so it is not missed: if SECURITY-REVIEWER or REVIEWER judge that
  table creation/first-population belongs to a separate, not-yet-filed
  requirement instead of folding into the promotion executor, this section
  of the design (§6, and the corresponding parts of §8/§9) needs to be
  re-scoped, not the rest of the design.
- **`ensure_entity_table/2`'s reuse of `fetch_active_definition/2`**
  (§6 step 1) assumes that private function in `Letflow.Entities.Records`
  is reusable from `Letflow.TenantProvisioning` (a cross-module call from
  tenant-provisioning into the entities context, a new dependency direction
  not previously present in either module) — ELIXIR-DEV should confirm at
  implementation time whether that function needs to move/become public,
  or whether `Letflow.TenantProvisioning` should instead take the
  `Definition.t()` as a parameter from whatever future caller triggers
  `register_column_promotion/4` in the first place (that caller already
  has the definition in hand, since it is the one editing it).
- **What triggers `register_column_promotion/4` at all** (an entity
  definition being edited to add `queried: true` or an `fk_def`) is
  explicitly out of scope for this requirement and this design — req295 §4
  and this requirement's own description both leave "any HTTP/admin surface
  for triggering a promotion" to a later, unfiled requirement.
