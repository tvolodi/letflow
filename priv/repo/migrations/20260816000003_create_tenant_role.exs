# Letflow.Repo.Migrations.CreateTenantRole
#
# Ported from REQ-015's own description, shaped to match
# src/identity/role_registry.zig's TenantRoleStore (list_roles, upsert_role),
# which REQ-020 implements against this table.
#
# name's uniqueness is enforced as a plain global unique index for now, standing
# in for "unique per tenant schema" under the single-default-schema deferral (see
# lib/letflow/design/identity-schema.md section 1). Once per-tenant schema
# provisioning lands, each tenant schema carries its own physical copy of this
# table and this same index, which then means unique-per-tenant-schema
# automatically -- no index rework needed at that point.
#
# group_id DOES carry a database-level foreign-key reference to groups.id, unlike
# users.tenant_id/groups.tenant_id's deliberate omission of a tenants.id FK --
# tenant_role and groups are both per-tenant-owned tables that will live in the
# same tenant schema together once schema-per-tenant provisioning lands, so this
# FK stays valid across that future change and never needs to be dropped.
defmodule Letflow.Repo.Migrations.CreateTenantRole do
  use Ecto.Migration

  def change do
    create table(:tenant_role, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :group_id, references(:groups, type: :binary_id), null: false

      timestamps(updated_at: false)
    end

    create unique_index(:tenant_role, [:name])
    create index(:tenant_role, [:group_id])
  end
end
