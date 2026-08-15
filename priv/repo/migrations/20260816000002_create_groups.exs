# Letflow.Repo.Migrations.CreateGroups
#
# Minimal groups table added per REQ-015's own description (no pre-existing groups
# table in Letflow) -- shape precedent is R-Co src/design/adp-04-user-tenant-binding.md's
# Group struct (group_id, tenant_id, name, created_at_us), scoped down to exactly
# what REQ-015 (tenant_role.group_id's FK target) and REQ-020 (role_registry.zig's
# upsertRole group-existence check) need. Full group-membership modeling
# (adp-04's GroupMembership, group-task claim authorization) is explicitly out of
# scope for this migration.
#
# tenant_id has NO database-level foreign-key reference to tenants.id, same
# rationale as users.tenant_id -- see the users migration's header comment and
# lib/letflow/design/identity-schema.md section 1/2.2.
defmodule Letflow.Repo.Migrations.CreateGroups do
  use Ecto.Migration

  def change do
    create table(:groups, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, :binary_id, null: false
      add :name, :string, null: false

      timestamps()
    end

    create index(:groups, [:tenant_id])
  end
end
