# Letflow.Repo.Migrations.AddGeneratedAsToEntityColumnPromotions
#
# REQ-301 -- see lib/letflow/design/req301-localized-text-field-type.md §4.1
# for the full design this migration implements.
#
# PLACEMENT: GLOBAL, not tenant-scoped -- matches
# 20260909000001_create_entity_column_promotions.exs's own placement
# (`entity_column_promotions` is platform bookkeeping about tenants, not
# per-tenant-schema application data). No `if prefix() do` guard, not
# registered in Letflow.TenantProvisioning's @tenant_scoped_migration_manifest,
# and not added to test/support/tenant_fixture.ex's @expected_tenant_tables
# oracle, for the identical reason that migration's own header states.
#
# Additive-only: one new nullable column, no default, no backfill of
# existing rows required (every pre-existing row is an ordinary,
# non-generated promotion and correctly reads `generated_as: nil`).
#
# No SQL string below interpolates tenant- or user-controlled data (INV-7)
# -- plain Ecto migration DSL only.
defmodule Letflow.Repo.Migrations.AddGeneratedAsToEntityColumnPromotions do
  use Ecto.Migration

  def change do
    alter table(:entity_column_promotions) do
      add :generated_as, :text
    end
  end
end
