# Letflow.Repo.Migrations.CreateOnboardingRegistry
#
# Structurally global, like `tenants` and `tenant_schemas` -- a hostname -> tenant
# resolution must be queryable before any tenant's own schema context is known, per
# lib/letflow/design/req076-identity-tokens-roles-onboarding.md section 8.1 (which
# extends REQ-022 section 2's own reasoning for tenant_schemas directly). No prefix:
# option here -- this is NOT a tenant-scoped migration, and it is deliberately absent
# from Letflow.TenantProvisioning.tenant_scoped_migrations/0's manifest.
#
# `id` IS the onboarding_id the requirement text and R-Co both use -- no separate
# column. `tenant_id` carries a database-level FK to tenants.id (same reasoning as
# tenant_schemas.tenant_id -- both are structurally-global siblings, never candidates
# for moving behind a tenant's own schema prefix). This design's onboarding flow is
# fully synchronous (design doc section 8.2), so the row is only ever inserted once
# the tenant already exists -- there is no NULL-until-completion window and no
# :pending state to represent, unlike R-Co's saga-backed table.
defmodule Letflow.Repo.Migrations.CreateOnboardingRegistry do
  use Ecto.Migration

  def change do
    create table(:onboarding_registry, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id), null: false
      add :slug, :string, null: false
      add :hostname, :string, null: false

      timestamps(updated_at: false)
    end

    create unique_index(:onboarding_registry, [:hostname])
    create index(:onboarding_registry, [:tenant_id])
  end
end
