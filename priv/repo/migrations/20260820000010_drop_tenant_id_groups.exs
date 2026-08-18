# Letflow.Repo.Migrations.DropTenantIdGroups
#
# Decision 0006 D2, REQ-064 -- drops `tenant_id` from the per-tenant `groups`
# table (created by 20260819000001_create_groups_tenant_scoped.exs, REQ-063
# D1). See lib/letflow/design/req064-drop-tenant-id.md section 2.2 point 10
# and Decision 0006 §5's own text: "`groups` likewise (its only index is
# `index(:groups, [:tenant_id])`, which D2 simply drops)".
#
# ALSO drops `index(:groups, [:tenant_id])` -- this table's ONLY index -- with
# NO replacement. The column carried no other value; 0006 states this
# explicitly.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY.
# Registered in Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both
# halves are mandatory.
defmodule Letflow.Repo.Migrations.DropTenantIdGroups do
  use Ecto.Migration

  def change do
    if prefix() do
      drop_if_exists index(:groups, [:tenant_id], prefix: prefix())

      alter table(:groups, prefix: prefix()) do
        remove :tenant_id, :binary_id
      end
    end
  end
end
