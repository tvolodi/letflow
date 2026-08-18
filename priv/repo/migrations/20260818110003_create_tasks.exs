# Letflow.Repo.Migrations.CreateTasks
#
# REQ-043, migration 3 of 3. Implements
# lib/letflow/design/req043-instance-engine-schema.md sections 4.1-4.2 (the
# `tasks` table). Ported from R-Co migrations/005_instances.sql:49-77, verified
# against src/design/engine.md's EE-03 section 1a (engine.md:1116-1144), which
# agrees exactly.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY. See
# lib/letflow/design/req022-tenant-schema-provisioning.md section 4 and
# 20260816120001_create_events.exs's header for the full rationale. Registered in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both halves are
# mandatory. MUST SORT AFTER 20260818110002_create_tokens.exs -- this migration
# carries a foreign key onto that table's `id` column.
#
# SCOPE BOUNDARY (design §1, §4.3 -- restated here and, verbatim in substance, in
# Letflow.Engine.Task's own moduledoc): this migration and its companion schema
# module build ONLY the table EE-03 (task activation) and EE-04 (task
# completion) write into. R-Co's own src/tasks/store.zig (1202 lines) additionally
# builds a standalone task query/list/filter surface (TaskStore.list/6-equivalent:
# instance_id/status/assignee_ref filters, pagination) -- that surface is NOT
# ported here. It belongs to S4's tasks routes or its own later requirement, per
# docs/migration/stage-3-instance-engine.md's explicit scope boundary.
#
# `status` is an Ecto.Enum at the schema layer (Letflow.Engine.Task), stored here
# as plain :string, `null: false`, defaulting to the literal string "PENDING" --
# UPPERCASE, matching R-Co's own stored strings exactly (design §4.1,
# mandated literally by this run's acceptance criteria text). Deliberately NOT
# harmonized with tokens.status's lowercase convention -- see
# 20260818110002_create_tokens.exs's header and design INV-EE43-4.
#
# `assignee_type` is open free text (USER|GROUP|ROLE per EE-03 §1a's own column
# comment) -- no Ecto.Enum, no closed-set validation named by any acceptance
# criterion (design §4.1).
#
# `completed_by` carries NO FK -- no users/identity table reference named by
# REQ-043; matches R-Co's own bare UUID with no REFERENCES (005:71).
#
# `on_delete: :restrict` on BOTH FKs (instance_id, token_id), deliberately
# diverging from R-Co's CASCADE, for the identical reason
# 20260818110002_create_tokens.exs's header states: no delete path exists for
# instance_projections anywhere in Letflow yet, so :restrict fails loudly instead
# of silently losing tenant data (design §4.2, INV-EE43-6).
#
# `idx_task_instance` and `idx_task_token` exist because Postgres does not
# automatically index the REFERENCING side of a foreign key (same reasoning as
# every prior FK-bearing migration in this schema). R-Co's
# idx_task_pending/idx_task_status (005:83-88) are DELIBERATELY NOT BUILT HERE --
# both are query-optimization indexes for the task inbox/list surface this
# requirement explicitly excludes (design §4.2, "belongs with S4's tasks routes
# or its own later requirement").
defmodule Letflow.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:tasks, primary_key: false, prefix: prefix()) do
        add :id, :binary_id, primary_key: true
        add :tenant_id, :binary_id, null: false

        add :instance_id,
            references(:instance_projections,
              column: :instance_id,
              type: :binary_id,
              on_delete: :restrict
            ),
            null: false

        add :token_id,
            references(:tokens, column: :id, type: :binary_id, on_delete: :restrict),
            null: false

        add :node_id, :string, null: false
        add :node_name, :string, null: false
        add :status, :string, null: false, default: "PENDING"
        add :assignee_type, :string
        add :assignee_ref, :string
        add :form_schema, :map
        add :output_variables, :map
        add :completed_by, :binary_id
        add :completed_at, :utc_datetime_usec
        add :cancelled_at, :utc_datetime_usec

        timestamps(type: :utc_datetime_usec)
      end

      create index(:tasks, [:instance_id], name: :idx_task_instance, prefix: prefix())
      create index(:tasks, [:token_id], name: :idx_task_token, prefix: prefix())
    end
  end
end
