# Letflow.Repo.Migrations.CreateGroupsTenantScoped
#
# Decision 0006 (docs/migration/decisions/0006-identity-tables-schema-per-tenant.md)
# D1's per-tenant copy of `groups`, replacing the legacy public `groups` table.
# The legacy public table is dropped separately -- see
# 20260819000004_drop_legacy_public_identity_tables.exs -- NOT by this migration.
#
# `tenant_id` is RETAINED on this per-tenant copy. Dropping it is Decision 0006 D2,
# reserved for REQ-064 -- not this migration's job. Column/index shape is carried
# forward unchanged from 20260816000002_create_groups.exs.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, matching
# lib/letflow/design/req022-tenant-schema-provisioning.md section 4's guard pattern
# exactly (same shape as 20260818110003_create_tasks.exs). A plain `mix ecto.migrate`
# (no :prefix) no-ops on this file; only a
# Letflow.TenantProvisioning.replay_migrations/2 run (real tenant schema name) takes
# the real branch. Registered in Letflow.TenantProvisioning.tenant_scoped_migrations/0
# -- both halves are mandatory.
#
# See lib/letflow/design/req063-identity-tables-schema-per-tenant.md section 2.1.
defmodule Letflow.Repo.Migrations.CreateGroupsTenantScoped do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:groups, primary_key: false, prefix: prefix()) do
        add :id, :binary_id, primary_key: true
        add :tenant_id, :binary_id, null: false
        add :name, :string, null: false

        timestamps()
      end

      create index(:groups, [:tenant_id], prefix: prefix())
    end
  end
end
