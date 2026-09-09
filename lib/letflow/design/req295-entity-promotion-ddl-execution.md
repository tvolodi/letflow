# REQ-295 design — entity column-promotion DDL execution

Companion design doc to
`docs/migration/decisions/0024-entity-promotion-ddl-execution.md`. That
record makes the decision and states the reasoning; this doc gives
ELIXIR-DEV (REQ-296 onward) a concrete interface to build against. No
implementation code — signatures and shapes only.

Nothing here is implemented by REQ-295. It is filed so a later requirement
does not have to re-derive the mechanism from the decision record's prose.

## 1. New Ecto schema: `Letflow.TenantProvisioning.ColumnPromotion`

Lives at `lib/letflow/tenant_provisioning/column_promotion.ex`, sibling to
the existing `Registration` module, same conventions (plain `binary_id`
primary key, no association on `tenant_id`, a `changeset/2` doing casting +
structural validation only).

Backing table: `entity_column_promotions`, global/`public` schema (not
tenant-scoped — this is platform bookkeeping about tenants, the same trust
tier as `tenant_schemas`).

Field list:

| Field | Type | Notes |
|---|---|---|
| `id` | `binary_id`, autogenerate | PK |
| `tenant_id` | `Ecto.UUID` | FK to `tenants.id`, no `belongs_to` (matches `Registration`'s own convention) |
| `entity_type` | `:string` | entity definition's type name |
| `attribute` | `:string` | the promoted field's name in the definition |
| `column_name` | `:string` | physical column name, defaults to `attribute`, may diverge for a corrective re-promotion under a new name (0024 §"rollback") |
| `status` | `:string` (application-level enum) | one of `"pending"`, `"ddl_applied"`, `"backfilling"`, `"backfilled"`, `"active"`, `"ddl_failed"`, `"suspended"` — see the state diagram below |
| `query_eligible` | `:boolean`, default `false` | independent of `status`; the single flag `Allowlist` (REQ-299) must consult |
| `last_error` | `:string`, nullable | populated on `ddl_failed`, cleared on retry |
| `attempted_at` | `:naive_datetime`, nullable | last DDL attempt timestamp |
| `ddl_applied_at` | `:naive_datetime`, nullable | |
| `backfilled_at` | `:naive_datetime`, nullable | |
| `activated_at` | `:naive_datetime`, nullable | |
| `inserted_at`, `updated_at` | timestamps | standard |

Indexes: unique on `(tenant_id, entity_type, attribute)`; non-unique on
`(entity_type, attribute, status)` for the fan-out queries in §2.

Type shape:

- `t()` — struct with the fields above, `status` typed as the closed
  string-enum listed, everything else per the table.
- `changeset(t(), map()) :: Ecto.Changeset.t()` — casts all fields above
  except timestamps; requires `tenant_id`, `entity_type`, `attribute`,
  `column_name`, `status`; validates `status` is one of the seven listed
  values; unique-constraint on `(tenant_id, entity_type, attribute)`;
  foreign-key-constraint on `tenant_id`.

### State diagram (informational, not code)

```
pending --(DDL succeeds)--> ddl_applied --(replay starts)--> backfilling
   |                             |                                |
   (DDL fails)                   |                        (replay completes,
   v                             |                         verification passes)
ddl_failed --(retry)---------> ddl_applied                        v
                                                              backfilled
                                                                   |
                                                      (cutover verification passes)
                                                                   v
                                                                active <-----.
                                                                   |         |
                                                      (defect found,         |
                                                    query_eligible := false) |
                                                                   v         |
                                                              suspended      |
                                                                   |         |
                                                    (corrective backfill,    |
                                                     re-verify) -------------'
```

`suspended` is not a `status` transition away from `active` in the table
above — it is recorded as `query_eligible := false` while `status` stays
`"active"` (0024 §4: this is deliberate, so the row's history of having
reached `active` at least once is not lost). "Suspended" in the diagram
names that combined state (`status = "active"`, `query_eligible = false`)
for readability, not a distinct stored string.

## 2. New functions on `Letflow.TenantProvisioning`

Added to the existing module (`lib/letflow/tenant_provisioning.ex`), not a
new module — per 0024 §1's reasoning. All return the module's established
`{:ok, _} | {:error, _}` shape.

- `register_column_promotion(entity_type :: String.t(), attribute :: String.t(), column_spec :: map(), tenant_ids :: [Ecto.UUID.t()] | :all) :: {:ok, [ColumnPromotion.t()]} | {:error, term()}`
  Creates one `pending` `ColumnPromotion` row per tenant (`:all` resolves
  against every current `Registration` row at call time). `column_spec`
  carries whatever the DDL needs to build the `ADD COLUMN` statement (type,
  nullability — always nullable per 0023's additive-only rule, default
  value if any). Does not run any DDL itself.

- `run_column_promotion(tenant_id :: Ecto.UUID.t(), promotion_id :: Ecto.UUID.t()) :: {:ok, ColumnPromotion.t()} | {:error, :tenant_not_provisioned | :promotion_not_found | {:ddl_failed, Exception.t()}}`
  Single-tenant, single-promotion. Resolves `schema_name` the same way
  `replay_migrations/2` does (`Repo.get_by(Registration, tenant_id: ...)`),
  takes the same per-schema advisory lock `provision_tenant_schema/1`
  already takes, executes one `ALTER TABLE ... ADD COLUMN` against that
  schema, and transitions the `ColumnPromotion` row `pending -> ddl_applied`
  or `pending -> ddl_failed` (recording `last_error`). This is the one
  function that actually issues DDL.

- `run_column_promotion_for_all_tenants(promotion_ref :: {entity_type :: String.t(), attribute :: String.t()}) :: %{ok: [ColumnPromotion.t()], failed: [ColumnPromotion.t()]}`
  Fan-out wrapper: loads every `pending` `ColumnPromotion` row for
  `promotion_ref`, calls `run_column_promotion/2` for each, and does **not**
  abort on the first failure (0024 §2 — per-tenant, not atomic). Returns
  both lists so a caller can act on partial success without re-querying.

- `retry_failed_column_promotion(tenant_id :: Ecto.UUID.t(), promotion_id :: Ecto.UUID.t()) :: {:ok, ColumnPromotion.t()} | {:error, term()}`
  Re-attempts `run_column_promotion/2` for a row currently `ddl_failed`,
  clearing `last_error` on success. No new promotion row is created.

- `backfill_column_promotion(tenant_id :: Ecto.UUID.t(), promotion_id :: Ecto.UUID.t()) :: {:ok, ColumnPromotion.t()} | {:error, term()}`
  Requires the row to be `ddl_applied` or `backfilling`. Transitions to
  `backfilling`, calls
  `Letflow.Entities.Record.Projector.rebuild_projection/2` scoped to this
  tenant's `prefix` and this `entity_type`, then runs the verification
  check (row-count parity between non-null values in the new column and
  live records of that type) before transitioning to `backfilled`. On
  verification failure, the row stays `backfilling` and the function
  returns `{:error, {:backfill_incomplete, details}}` rather than
  advancing — a caller may call this function again to retry, since replay
  is idempotent.

- `activate_column_promotion(tenant_id :: Ecto.UUID.t(), promotion_id :: Ecto.UUID.t()) :: {:ok, ColumnPromotion.t()} | {:error, :not_backfilled | term()}`
  Requires `status == "backfilled"`. Sets `status: "active"`,
  `query_eligible: true`, `activated_at: now`. This is the single write
  `Allowlist` (REQ-299) depends on to start reporting the attribute as a
  `:typed_column` entry for this tenant.

- `suspend_column_promotion(tenant_id :: Ecto.UUID.t(), promotion_id :: Ecto.UUID.t(), reason :: String.t()) :: {:ok, ColumnPromotion.t()} | {:error, term()}`
  Requires `status == "active"`. Sets `query_eligible: false` only —
  `status` is left `"active"` (0024 §4's rollback path). Never issues DDL,
  never touches the column, never touches `field_values`.

- `column_promotion_query_eligible?(tenant_id :: Ecto.UUID.t(), entity_type :: String.t(), attribute :: String.t()) :: boolean()`
  The read-side accessor `Letflow.Entities.Query.Allowlist`'s per-tenant,
  per-entity-type `typed_columns` builder (REQ-299) must call before
  including a promoted attribute as a `:typed_column` entry. Returns
  `false` for any `(tenant_id, entity_type, attribute)` with no
  `ColumnPromotion` row at all (an attribute that has never been promoted
  for this tenant), so callers do not need a separate existence check.

- `column_promotion_dual_write?(tenant_id :: Ecto.UUID.t(), entity_type :: String.t(), attribute :: String.t()) :: boolean()`
  The read-side accessor `Letflow.Entities.Records`'/`Projector`'s write
  path must call before deciding whether to also write `attribute`'s value
  into `field_values`. `true` while `status` is `"ddl_applied"`,
  `"backfilling"`, or `"backfilled"`; `false` once `"active"` (0024 §3's
  dual-write window) and `false` before `"ddl_applied"` (column does not
  exist yet, nothing to dual-write into).

## 3. Integration points this design fixes for other requirements (not built here)

- **`Letflow.Entities.Record.Projector`'s `upsert_record_latest/3`-successor
  write path** (0023's Consequences section already names this as the
  write-time hook for promoted columns) must call
  `column_promotion_dual_write?/3` per promoted attribute on every write,
  per 0024 §3. This is REQ-296 (or whichever requirement implements
  0024)'s work, not REQ-295's.
- **`Letflow.Entities.Query.Allowlist`'s per-entity-type `typed_columns`
  builder (REQ-299)** must call `column_promotion_query_eligible?/3` per
  candidate promoted attribute before including it as `:typed_column`,
  per 0024 §3–4. This is an added precondition on REQ-299's own design, not
  a redesign of it.
- **`Letflow.Entities.Query.Compiler`** needs no change — it already
  dispatches purely on whatever `Allowlist` hands it (`:typed_column` vs
  `:json_field`), so gating happens entirely in `Allowlist`, not in the
  compiler.

## 4. What this design does not fix

- The exact DDL statement builder (mapping a `Definition.field_type()` to a
  Postgres column type for `column_spec`) — a small, mechanical piece left
  to REQ-296's own implementation.
- The exact row-count-parity verification query used in
  `backfill_column_promotion/2` — left to REQ-296, within the contract that
  it must be a real check, not a no-op, before `backfilled` is reached.
- Batching/chunking for very large entity types under
  `rebuild_projection/2` — 0024's "Cost accepted, not hidden" paragraph
  applies; left to REQ-296.
- Any HTTP/admin surface for triggering a promotion — out of scope for this
  design entirely; nothing here assumes one exists yet.
