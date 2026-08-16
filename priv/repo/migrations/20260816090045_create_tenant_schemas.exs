# Letflow.Repo.Migrations.CreateTenantSchemas
#
# Builds the tenant_schemas registry REQ-022 adds, resolving the deferral
# lib/letflow/design/identity-schema.md section 1 flagged as follow-up work.
# Ported from R-Co migrations/060_schema_per_tenant_bootstrap.sql's
# public.tenant_schemas table shape (behavior ported, not the raw SQL).
#
# This table is structurally global, like tenants -- it must be queryable before
# any tenant's own schema context is known, so it lives in the public/default
# schema like every other migration in this batch (no prefix: option here).
#
# tenant_id DOES carry a database-level foreign-key reference to tenants.id,
# unlike users.tenant_id/groups.tenant_id's deliberate omission of one (see
# identity-schema.md section 2.2) -- tenant_schemas and tenants are both
# structurally-global siblings that are never candidates for moving behind a
# tenant's own schema prefix, so this FK never needs to be dropped later, the
# same reasoning identity-schema.md section 2.4 already applies to
# tenant_role.group_id -> groups.id.
#
# OPEN QUESTION (see lib/letflow/design/req022-tenant-schema-provisioning.md
# section 7, not resolved here): REQ-015's users/groups/tenant_role tables
# currently live in the public default schema. This requirement does not
# retrofit those three tables to live under each tenant's own schema.
defmodule Letflow.Repo.Migrations.CreateTenantSchemas do
  use Ecto.Migration

  def change do
    create table(:tenant_schemas, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id), null: false
      add :schema_name, :string, null: false
      add :migrations_applied_at, :naive_datetime

      timestamps(inserted_at: :provisioned_at, updated_at: false)
    end

    create unique_index(:tenant_schemas, [:tenant_id])
    create unique_index(:tenant_schemas, [:schema_name])
  end
end
