# Letflow.Repo.Migrations.CreatePlatformMigrationRollouts
#
# REQ-374 -- see lib/letflow/design/req374-tenant-migration-fanout-runner.md
# §3 for the full design this migration implements.
#
# PLACEMENT: GLOBAL, not tenant-scoped, same convention as
# entity_column_promotions (REQ-297) and tenant_schemas (REQ-022) -- no
# `if prefix() do` guard here, these two tables are deliberately NOT
# registered in Letflow.TenantProvisioning's @tenant_scoped_migration_manifest
# and NOT added to test/support/tenant_fixture.ex's @expected_tenant_tables
# oracle (per docs/anti-patterns.md's entry on that oracle, which explicitly
# does not apply to a global table like this one).
#
# No SQL string below interpolates tenant- or user-controlled data (INV-7) --
# plain Ecto migration DSL only.
defmodule Letflow.Repo.Migrations.CreatePlatformMigrationRollouts do
  use Ecto.Migration

  def change do
    create table(:platform_migration_rollouts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :entity_type, :string, size: 255, null: false
      add :attribute, :string, size: 255, null: false
      add :column_spec, :map, null: false
      add :status, :string, size: 32, null: false, default: "running"
      add :started_at, :naive_datetime, null: false
      add :completed_at, :naive_datetime
    end

    create unique_index(
             :platform_migration_rollouts,
             [:entity_type, :attribute],
             name: :platform_migration_rollouts_entity_type_attribute_idx
           )

    create table(:platform_migration_rollout_outcomes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :rollout_id,
          references(:platform_migration_rollouts, type: :binary_id, on_delete: :nothing),
          null: false

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :nothing), null: false

      add :column_promotion_id,
          references(:entity_column_promotions, type: :binary_id, on_delete: :nothing),
          null: false

      add :status, :string, size: 32, null: false, default: "pending"
      add :completed_at, :naive_datetime
      add :reason, :string
    end

    create unique_index(
             :platform_migration_rollout_outcomes,
             [:rollout_id, :tenant_id],
             name: :platform_migration_rollout_outcomes_rollout_id_tenant_id_idx
           )

    create index(:platform_migration_rollout_outcomes, [:rollout_id])
  end
end
