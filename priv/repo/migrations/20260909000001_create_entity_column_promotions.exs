# Letflow.Repo.Migrations.CreateEntityColumnPromotions
#
# REQ-297 -- see lib/letflow/design/req297-entity-promotion-executor.md §2
# for the full design this migration implements (field list re-confirmed
# from lib/letflow/design/req295-entity-promotion-ddl-execution.md §1).
#
# PLACEMENT: GLOBAL, not tenant-scoped. `entity_column_promotions` is
# platform bookkeeping about tenants (0024 §1: "the same trust tier as
# tenant_schemas"), not per-tenant-schema application data -- there is no
# `if prefix() do` guard here, this file is deliberately NOT registered in
# Letflow.TenantProvisioning's @tenant_scoped_migration_manifest, and it is
# NOT added to test/support/tenant_fixture.ex's @expected_tenant_tables
# oracle (that oracle enumerates tables inside a freshly provisioned
# *tenant schema*; this table lives in the public/default schema instead,
# same placement as `tenant_schemas` itself -- confirmed per
# docs/anti-patterns.md's "A new tenant-scoped migration's tables must be
# added to @expected_tenant_tables" entry, which explicitly does not apply
# to a global table like this one).
#
# No SQL string below interpolates tenant- or user-controlled data (INV-7)
# -- plain Ecto migration DSL only.
defmodule Letflow.Repo.Migrations.CreateEntityColumnPromotions do
  use Ecto.Migration

  def change do
    create table(:entity_column_promotions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :nothing), null: false
      add :entity_type, :string, size: 255, null: false
      add :attribute, :string, size: 255, null: false
      add :column_name, :string, size: 255, null: false

      # See Letflow.TenantProvisioning.ColumnPromotion's moduledoc, "Two
      # fields added beyond req295 §1's literal list" -- necessary,
      # additive fields, not a deviation from the decided contract.
      add :pg_type, :string, size: 64, null: false

      add :status, :string, size: 32, null: false
      add :query_eligible, :boolean, null: false, default: false
      add :last_error, :text
      add :suspend_reason, :text
      add :attempted_at, :naive_datetime
      add :ddl_applied_at, :naive_datetime
      add :backfilled_at, :naive_datetime
      add :activated_at, :naive_datetime

      timestamps()
    end

    create unique_index(
             :entity_column_promotions,
             [:tenant_id, :entity_type, :attribute],
             name: :entity_column_promotions_tenant_id_entity_type_attribute_idx
           )

    create index(:entity_column_promotions, [:entity_type, :attribute, :status])
  end
end
