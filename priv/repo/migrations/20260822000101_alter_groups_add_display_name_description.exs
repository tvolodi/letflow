# Letflow.Repo.Migrations.AlterGroupsAddDisplayNameDescription
#
# REQ-074 (design §8b) -- adds the two columns `Identity.create_group/2` and
# `group_map/1` need (`display_name`, `description`), plus a unique index on
# `name` (needed for `create_group/2`'s `duplicate_group_name` mapping -- none
# exists on this table today, per `group.ex`'s own moduledoc: "No changeset
# function is defined here").
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY,
# matching every other tenant-scoped migration's convention (e.g.
# 20260819000001_create_groups_tenant_scoped.exs). A plain `mix ecto.migrate`
# (no :prefix) no-ops on this file; only a
# Letflow.TenantProvisioning.replay_migrations/2 run (real tenant schema name)
# takes the real branch. Registered in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both halves are
# mandatory.
#
# Additive and reversible: Ecto.Migration's default `alter table` add +
# `create unique_index` down-migrate cleanly via `change/0`'s automatic
# reversal.
#
# See lib/letflow/design/req074-identity-group-routes.md section 8b.
defmodule Letflow.Repo.Migrations.AlterGroupsAddDisplayNameDescription do
  use Ecto.Migration

  def change do
    if prefix() do
      alter table(:groups, prefix: prefix()) do
        add :display_name, :string
        add :description, :string
      end

      create unique_index(:groups, [:name], prefix: prefix())
    end
  end
end
