# Letflow.Repo.Migrations.CreateTenantRoleTenantScoped
#
# Decision 0006 D1's per-tenant copy of `tenant_role`, replacing the legacy public
# `tenant_role` table. The legacy public table is dropped separately -- see
# 20260819000004_drop_legacy_public_identity_tables.exs -- NOT by this migration.
#
# unique_index(:tenant_role, [:name]) becomes unique-per-tenant-schema automatically
# once this table is per-schema -- no index redesign, carried forward byte-identical
# from 20260816000003_create_tenant_role.exs, per Decision 0006 section R4 and that
# migration's own header comment's anticipation of this exact move.
#
# `group_id`'s `references(:groups, type: :binary_id)` FK resolves against the
# per-tenant `groups` table inside the SAME schema -- this migration MUST run with
# the same `prefix:` as 20260819000001_create_groups_tenant_scoped.exs (guaranteed by
# Letflow.TenantProvisioning.tenant_scoped_migrations/0's manifest ordering, section
# 3 of the design doc: groups before tenant_role in the same replay_migrations/2
# run). An unqualified `references(:groups, ...)` resolves within the current
# `:prefix`'d create table block, matching how REQ-043's tokens/tasks migrations
# already reference sibling tables inside the same tenant schema.
#
# No `tenant_id` column -- `tenant_role` never had one; nothing changes here.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, matching
# lib/letflow/design/req022-tenant-schema-provisioning.md section 4's guard pattern.
# MUST SORT AFTER 20260819000001_create_groups_tenant_scoped.exs -- this migration
# carries a foreign key onto that table's `id` column. Registered in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both halves are mandatory.
#
# See lib/letflow/design/req063-identity-tables-schema-per-tenant.md section 2.2.
defmodule Letflow.Repo.Migrations.CreateTenantRoleTenantScoped do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:tenant_role, primary_key: false, prefix: prefix()) do
        add :id, :binary_id, primary_key: true
        add :name, :string, null: false
        add :group_id, references(:groups, type: :binary_id), null: false

        timestamps(updated_at: false)
      end

      create unique_index(:tenant_role, [:name], prefix: prefix())
      create index(:tenant_role, [:group_id], prefix: prefix())
    end
  end
end
