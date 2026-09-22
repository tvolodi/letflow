# Letflow.Repo.Migrations.CreateEventHistoryRetirements
#
# REQ-377 -- see lib/letflow/design/req377-history-retirement-screen.md §2.2
# for the full design this migration implements.
#
# PLACEMENT: GLOBAL, not tenant-scoped -- same convention as
# platform_migration_rollouts/platform_migration_rollout_outcomes (REQ-374):
# these track a platform-wide operation, not per-tenant business data, so
# they are deliberately NOT registered in
# Letflow.TenantProvisioning's @tenant_scoped_migration_manifest and NOT
# added to test/support/tenant_fixture.ex's @expected_tenant_tables oracle.
#
# No SQL below interpolates tenant- or user-controlled data (INV-7) -- plain
# Ecto migration DSL only.
#
# DEVIATION FROM THE APPROVED DESIGN (§2.2/OQ1), flagged here explicitly for
# REVIEWER's Step 2c/2d attention, not silently patched around. The design's
# own OQ1 asked ELIXIR-DEV to "confirm the actual S1 identity table name
# (users vs. something else) before writing the migration" -- done: `users`
# is the right table NAME, but per decision 0006 D1/D2
# (docs/migration/decisions/0006-identity-tables-schema-per-tenant.md),
# `users` is a TENANT-SCOPED table (one physical `users` relation per tenant
# Postgres schema, no `tenant_id` column, no single global `users` relation
# to reference at all -- confirmed against every other `references(:users,
# ...)` migration in this codebase, e.g.
# 20260823000001_create_api_tokens_tenant_scoped.exs, all of which sit
# inside an `if prefix() do` tenant-scoped guard this migration cannot use,
# since event_history_retirements is a deliberately GLOBAL table (§0/§2.2 --
# it tracks one platform-wide operation, not per-tenant data). A global
# table's column cannot carry a `references/2` FK to a per-tenant-schema
# table -- Postgres has no cross-schema-instance FK target here (the
# authenticated actor's OWN tenant schema is one of potentially many
# `users` relations, and which one is not even knowable from this table's
# own columns). `requested_by` is therefore stored as a plain `:binary_id`
# column with NO `references/2` -- an attribution value only (the
# authenticated actor's id, `conn.assigns.auth_context.user_id`), same
# posture the design's own §5 INV-7 note already establishes ("used only as
# a stored attribution value, never interpolated into SQL text"), never a
# referential-integrity-enforced FK. `Letflow.Platform.MigrationRollout`
# (REQ-374), this migration's own structural precedent, sidesteps this
# exact issue by carrying no actor-attribution column at all; this design
# asks for one, so this is the correct resolution given that ask.
defmodule Letflow.Repo.Migrations.CreateEventHistoryRetirements do
  use Ecto.Migration

  def change do
    create table(:event_history_retirements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :year, :integer, null: false
      add :month, :integer, null: false
      add :status, :string, size: 32, null: false, default: "running"
      add :requested_by, :binary_id, null: false
      add :started_at, :naive_datetime, null: false
      add :completed_at, :naive_datetime
    end

    create index(:event_history_retirements, [:status])

    create table(:event_history_retirement_outcomes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :retirement_id,
          references(:event_history_retirements, type: :binary_id, on_delete: :delete_all),
          null: false

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :nothing), null: false
      add :status, :string, size: 32, null: false, default: "pending"
      add :retired_partition, :string
      add :protected_rows_relocated, :integer
      add :resumed_from, :string
      add :reason, :string
      add :completed_at, :naive_datetime
    end

    create index(:event_history_retirement_outcomes, [:retirement_id])
  end
end
