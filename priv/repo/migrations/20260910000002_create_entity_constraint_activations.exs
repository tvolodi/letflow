# Letflow.Repo.Migrations.CreateEntityConstraintActivations
#
# REQ-298 -- see lib/letflow/design/req298-constraint-fk-activation.md §4.2
# for the full design this migration implements (field list mirrors
# entity_column_promotions -- see that table's own migration,
# 20260909000001_create_entity_column_promotions.exs).
#
# PLACEMENT: GLOBAL, not tenant-scoped. `entity_constraint_activations` is
# platform bookkeeping about tenants, the same trust tier as
# `entity_column_promotions` and `tenant_schemas` -- there is no
# `if prefix() do` guard here, this file is deliberately NOT registered in
# Letflow.TenantProvisioning's @tenant_scoped_migration_manifest, and it is
# NOT added to test/support/tenant_fixture.ex's @expected_tenant_tables
# oracle (per docs/anti-patterns.md's "A new tenant-scoped migration's
# tables must be added to @expected_tenant_tables" entry, which explicitly
# does not apply to a global table like this one).
#
# No SQL string below interpolates tenant- or user-controlled data (INV-7)
# -- plain Ecto migration DSL only.
defmodule Letflow.Repo.Migrations.CreateEntityConstraintActivations do
  use Ecto.Migration

  def change do
    create table(:entity_constraint_activations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :nothing), null: false
      add :entity_type, :string, size: 255, null: false
      add :constraint_name, :string, size: 255, null: false
      add :fields, {:array, :string}, null: false

      add :status, :string, size: 32, null: false
      add :last_error, :text
      add :attempted_at, :naive_datetime
      add :ddl_applied_at, :naive_datetime

      timestamps()
    end

    create unique_index(
             :entity_constraint_activations,
             [:tenant_id, :entity_type, :constraint_name],
             name: :entity_constraint_activations_tenant_entity_name_idx
           )
  end
end
