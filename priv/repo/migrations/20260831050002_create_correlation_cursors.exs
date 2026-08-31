# Letflow.Repo.Migrations.CreateCorrelationCursors
#
# REQ-199. Implements lib/letflow/design/req199-ordering.md §5.2 -- the
# `correlation_cursors` table. Tracks the highest sequence number
# successfully applied per correlation (ORD-01 cursor).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY.
# Registered in Letflow.TenantProvisioning.tenant_scoped_migrations/0.
#
# `correlation_id` is the string primary key (not a UUID) -- matches R-Co's
# own primary key shape for this table (design doc §4 note).
#
# `applied_seq` starts at 0 (no completions applied yet). The CHECK constraint
# enforces non-negativity -- a cursor must never go backward.
#
# timestamps/1 macro is used here (both created_at and updated_at) with the
# codebase-standard `inserted_at: :created_at` rename (matches
# process_definition.ex and retention_policy.ex precedent).
defmodule Letflow.Repo.Migrations.CreateCorrelationCursors do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:correlation_cursors, primary_key: false, prefix: prefix()) do
        add :correlation_id, :string, primary_key: true, null: false
        add :tenant_id, :binary_id, null: false
        add :applied_seq, :bigint, null: false, default: 0

        timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
      end

      schema = prefix()

      execute(
        "ALTER TABLE \"#{schema}\".correlation_cursors ADD CONSTRAINT correlation_cursors_applied_seq_check CHECK (applied_seq >= 0)",
        "ALTER TABLE \"#{schema}\".correlation_cursors DROP CONSTRAINT IF EXISTS correlation_cursors_applied_seq_check"
      )
    end
  end
end
