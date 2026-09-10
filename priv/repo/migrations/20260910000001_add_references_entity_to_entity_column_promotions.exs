# Letflow.Repo.Migrations.AddReferencesEntityToEntityColumnPromotions
#
# REQ-298 -- see lib/letflow/design/req298-constraint-fk-activation.md §3.2
# for the full design this migration implements.
#
# PLACEMENT: GLOBAL, not tenant-scoped -- same placement as
# 20260909000001_create_entity_column_promotions.exs, whose table this
# migration alters. Not registered in
# Letflow.TenantProvisioning's @tenant_scoped_migration_manifest, and not
# added to test/support/tenant_fixture.ex's @expected_tenant_tables oracle.
#
# Nullable, additive-only ALTER TABLE -- no data migration needed (every
# existing row is a non-FK promotion, correctly represented as NULL here).
#
# No SQL string below interpolates tenant- or user-controlled data (INV-7)
# -- plain Ecto migration DSL only.
defmodule Letflow.Repo.Migrations.AddReferencesEntityToEntityColumnPromotions do
  use Ecto.Migration

  def change do
    alter table(:entity_column_promotions) do
      add :references_entity, :string, size: 255
    end
  end
end
