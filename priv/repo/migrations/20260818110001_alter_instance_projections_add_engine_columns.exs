# Letflow.Repo.Migrations.AlterInstanceProjectionsAddEngineColumns
#
# REQ-043, migration 1 of 3. Implements
# lib/letflow/design/req043-instance-engine-schema.md section 2 -- the seven
# instance-engine-owned columns REQ-023's own migration header
# (20260816120003_create_instance_projections.exs, "COLUMNS DELIBERATELY NOT
# CREATED HERE") named as S3/EE-01's job to add. Ported from R-Co
# migrations/001_event_store.sql:81-95, confirmed by direct read (design §0/§2.1).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY. See
# lib/letflow/design/req022-tenant-schema-provisioning.md section 4 and
# 20260816120001_create_events.exs's header for the full rationale. Registered in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both halves are
# mandatory. MUST SORT AFTER 20260816120003_create_instance_projections.exs -- it
# alters that table.
#
# NO FK ON `definition_id`, confirmed rather than assumed (design §2.2).
# 001_event_store.sql:83 declares `definition_id UUID NOT NULL` with no
# `REFERENCES` clause -- unlike `instance_definition_snapshots.definition_id`,
# which R-Co's 004:61 genuinely does reference. `process_definitions` already
# exists in Letflow at this migration's point in the ordering, so a real FK is
# technically possible, but this migration does not add one it wasn't asked to --
# flagged as design OQ-2 for REVIEWER, not silently "completed."
#
# `current_nodes` and `variables` are `:map` (jsonb), `null: false` with real
# DB-level defaults (`[]` / `%{}}` respectively, design §2.1's own table).
# `variables`'s `default: %{}` uses the same `add :field, :map, null: false,
# default: ...` idiom `20260816120001_create_events.exs` (`payload`/`metadata`)
# and `20260816193001_create_process_definitions.exs` (`graph`) already
# establish. `current_nodes`'s default cannot use that idiom -- confirmed
# empirically, not assumed: Ecto's migration DSL rejects a bare `[]` literal for
# a `:map`-typed column's `:default` outright (`ArgumentError: unknown default
# [] for type :map`; deps/ecto_sql's default-value validator accepts a map, a
# string/number/boolean, or a list of strings/integers, but not an empty/
# untyped list) -- so `current_nodes` uses `default: fragment("'[]'::jsonb")`
# instead, which emits the same DB-level `DEFAULT '[]'::jsonb` R-Co's own
# `001_event_store.sql:86` carries. The companion
# Letflow.EventStore.InstanceProjection schema update (design §2.3) mirrors both
# columns' intent at the schema/changeset layer so a caller who omits either
# field at insert time still satisfies `null: false` without a changeset error
# (see that module's moduledoc for `current_nodes`'s own schema-layer nuance,
# which is a second, independent default-value restriction one layer up).
#
# `error_detail`, `completed_at`, `cancelled_at` are nullable, populated only on
# the ERROR/COMPLETED/CANCELLED transitions -- never at insert time (design §2.3).
#
# NO ENUM MIGRATION -- `status`'s Ecto.Enum already carries `error: "ERROR"`
# (REQ-023's own migration header, confirmed §0/design INV-EE43-1). Nothing here
# touches the `status` column.
#
# `uq_instance_correlation` and `idx_proj_definition` are copied verbatim (name,
# columns, predicate) from 001_event_store.sql:98-107 (design INV-EE43-2). The
# existing `idx_proj_status` index (REQ-023) is untouched.
#
# MIGRATION-SAFETY PRECONDITION (design §7, flagged as OQ-6): `ADD COLUMN
# definition_id ... null: false` with no DEFAULT is only safe against a tenant
# schema whose `instance_projections` table is currently empty. This holds today
# -- no shipped requirement populates instance_projections rows yet (REQ-025's
# EventStore.append/2 only ever UPDATEs an existing row; EE-01/REQ-045 hasn't
# shipped) -- but is a real, load-bearing precondition a future maintainer must
# reverify before this migration is ever replayed against a tenant schema with
# genuine data. Not defensively guarded here (no RAISE), matching this codebase's
# established practice of documenting rather than separately guarding
# preconditions the current call graph already guarantees.
defmodule Letflow.Repo.Migrations.AlterInstanceProjectionsAddEngineColumns do
  use Ecto.Migration

  def change do
    if prefix() do
      alter table(:instance_projections, prefix: prefix()) do
        add :definition_id, :binary_id, null: false
        add :correlation_key, :string
        add :current_nodes, :map, null: false, default: fragment("'[]'::jsonb")
        add :variables, :map, null: false, default: %{}
        add :error_detail, :map
        add :completed_at, :utc_datetime_usec
        add :cancelled_at, :utc_datetime_usec
      end

      create unique_index(:instance_projections, [:definition_id, :correlation_key],
               name: :uq_instance_correlation,
               where: "correlation_key IS NOT NULL",
               prefix: prefix()
             )

      create index(:instance_projections, [:definition_id],
               name: :idx_proj_definition,
               prefix: prefix()
             )
    end
  end
end
