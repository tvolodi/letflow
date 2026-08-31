# Letflow.Repo.Migrations.CreateEffectCompletions
#
# REQ-199. Implements lib/letflow/design/req199-ordering.md §5.1 -- the
# `effect_completions` table for the correlated effect re-entry ordering
# subsystem (ORD-01/02/03/04).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY.
# See lib/letflow/design/req022-tenant-schema-provisioning.md section 4 and
# 20260829000001_create_dlq_entries.exs's header for the full rationale
# (Decision B, docs/migration/decisions/0003-ecto-schema-strategy.md --
# schema-per-tenant). Registered in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0.
#
# `completion_id` is the UUID primary key (binary_id, not the default).
# `sequence_no` is bigint, not integer -- matching the design doc §3 which
# specifies bigint for sequence numbers.
#
# `status` stores uppercase strings ('PENDING','APPLIED','DEAD') matching
# the design doc §3 and mapped to atoms by Ecto.Enum in the schema.
#
# `created_at` is added explicitly (not via timestamps/1) because there is no
# `updated_at` column on this table -- `applied_at` is a separate nullable
# column updated by the apply step, not Ecto's auto-timestamp.
#
# execute/1 statements below are used for: partial index (not expressible via
# Ecto DSL's create_index/2), CHECK constraints (not expressible via
# add_constraint/3 in this Ecto version).
defmodule Letflow.Repo.Migrations.CreateEffectCompletions do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:effect_completions, primary_key: false, prefix: prefix()) do
        add :completion_id, :binary_id, primary_key: true
        add :tenant_id, :binary_id, null: false
        add :correlation_id, :string, null: false
        add :sequence_no, :bigint, null: false
        add :status, :string, null: false, default: "PENDING"
        add :payload, :map, null: false, default: %{}
        add :received_at, :utc_datetime_usec
        add :applied_at, :utc_datetime_usec
        add :created_at, :utc_datetime_usec, null: false
      end

      create unique_index(:effect_completions, [:correlation_id, :sequence_no],
               prefix: prefix()
             )

      schema = prefix()

      execute(
        "CREATE INDEX effect_completions_pending_idx ON \"#{schema}\".effect_completions (correlation_id, sequence_no) WHERE status = 'PENDING'",
        "DROP INDEX IF EXISTS \"#{schema}\".effect_completions_pending_idx"
      )

      execute(
        "ALTER TABLE \"#{schema}\".effect_completions ADD CONSTRAINT effect_completions_status_check CHECK (status IN ('PENDING','APPLIED','DEAD'))",
        "ALTER TABLE \"#{schema}\".effect_completions DROP CONSTRAINT IF EXISTS effect_completions_status_check"
      )

      execute(
        "ALTER TABLE \"#{schema}\".effect_completions ADD CONSTRAINT effect_completions_seq_nonneg CHECK (sequence_no >= 0)",
        "ALTER TABLE \"#{schema}\".effect_completions DROP CONSTRAINT IF EXISTS effect_completions_seq_nonneg"
      )
    end
  end
end
