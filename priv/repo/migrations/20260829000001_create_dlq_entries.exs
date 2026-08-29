# Letflow.Repo.Migrations.CreateDlqEntries
#
# REQ-176. Implements lib/letflow/design/req176-dlq-core.md section 1 (the
# `dlq_entries` table) -- S6's first requirement, greenfield: no prior DLQ
# code exists to extend.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY. See
# lib/letflow/design/req022-tenant-schema-provisioning.md section 4 and
# 20260818110003_create_tasks.exs's header for the full rationale (Decision B,
# docs/migration/decisions/0003-ecto-schema-strategy.md -- schema-per-tenant
# with an intra-schema `tenant_id` column retained, not itself the isolation
# boundary). Registered in Letflow.TenantProvisioning.tenant_scoped_migrations/0
# -- both halves are mandatory per that module's own established discipline.
#
# `id` is the explicit `:binary_id` primary key (no default primary-key
# generator), same idiom as 20260818110003_create_tasks.exs's own `tasks`
# table.
#
# `entry_type` is plain `:string`, NOT `Ecto.Enum` -- design doc section 1:
# the requirement text states this is extensible ("event"/"timer"/"webhook"
# today, more later), unlike `status` below.
#
# `instance_id` carries NO FK reference (design doc section 1) -- an entry
# must be able to outlive or precede the referenced `instance_projections`
# row's own lifecycle assumptions, and no acceptance criterion requires
# referential integrity here. No FK means no "index the referencing side of
# every FK" obligation either.
#
# `retry_history` is a `{:array, :map}` column (jsonb array), not an
# `embeds_many` -- design doc section 2.2: no acceptance criterion needs
# changeset-level validation on historical entries, they are appended
# mechanically by `Letflow.Dlq.retry/2`, never user-supplied.
#
# No `inserted_at`/`updated_at` pair from `timestamps/1` -- `DlqEntry`'s
# contract names `created_at` specifically (not `inserted_at`), and there is
# no `updated_at` field in the frontend type at all (design doc section 1),
# so the three datetime columns are declared explicitly with `add/3`.
#
# Indexes (design doc section 1), each scoped to the same tenant schema as
# the table:
#   - `idx_dlq_entries_list_cursor` on `(created_at, id)` -- backs
#     `Letflow.Dlq.list/2`'s keyset pagination order.
#   - `idx_dlq_entries_status` on `status` -- backs the `status` filter.
#   - `idx_dlq_entries_entry_type` on `entry_type` -- backs the `entry_type`
#     filter.
#
# No index on `tenant_id` alone -- matches 20260818110003_create_tasks.exs's
# own precedent (the Postgres schema, not this column, is the actual
# isolation boundary, and no filter in Letflow.Dlq.list/2 queries by
# `tenant_id` in isolation).
defmodule Letflow.Repo.Migrations.CreateDlqEntries do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:dlq_entries, primary_key: false, prefix: prefix()) do
        add :id, :binary_id, primary_key: true
        add :tenant_id, :binary_id, null: false

        add :entry_type, :string, null: false
        add :instance_id, :binary_id
        add :reference_id, :string
        add :reason, :string
        add :full_reason, :text
        add :error_detail, :map
        add :error_chain, {:array, :map}
        add :source_payload, :map
        add :context_json, :map
        add :retry_history, {:array, :map}, null: false, default: []
        add :retry_count, :integer, null: false, default: 0
        add :retry_limit, :integer
        add :next_retry_at, :utc_datetime
        add :status, :string, null: false, default: "pending"
        add :created_at, :utc_datetime, null: false
        add :first_failed_at, :utc_datetime
        add :last_failed_at, :utc_datetime
      end

      create index(:dlq_entries, [:created_at, :id],
               name: :idx_dlq_entries_list_cursor,
               prefix: prefix()
             )

      create index(:dlq_entries, [:status], name: :idx_dlq_entries_status, prefix: prefix())

      create index(:dlq_entries, [:entry_type],
               name: :idx_dlq_entries_entry_type,
               prefix: prefix()
             )
    end
  end
end
