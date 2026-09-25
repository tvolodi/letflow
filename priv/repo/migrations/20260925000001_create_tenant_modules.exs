# Letflow.Repo.Migrations.CreateTenantModules
#
# REQ-402 -- see
# lib/letflow/design/req402-tenant-modules-install-context.md §1.2 for the
# full design this migration implements.
#
# PLACEMENT: per-tenant -- the module install ledger for a tenant lives in
# that tenant's own schema, per 0039 D5.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY,
# and this file's registration in `Letflow.TenantProvisioning`'s
# `@tenant_scoped_migration_manifest` (both halves are mandatory).
#
# No SQL string below interpolates tenant- or user-controlled data (INV-7).
#
# One row per installed platform module (`Letflow.Modules.Installs.install/3`,
# REQ-402) -- `module_id` is unique per tenant schema; `version` is the
# manifest's version at install time; `settings` defaults to `{}` (settings
# writes are REQ-414's job, out of scope here).
defmodule Letflow.Repo.Migrations.CreateTenantModules do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      create table(:tenant_modules, primary_key: false, prefix: schema) do
        add :id, :binary_id, primary_key: true
        add :module_id, :string, size: 255, null: false
        add :version, :string, size: 255, null: false
        add :installed_at, :utc_datetime_usec, null: false
        add :settings, :map, null: false, default: %{}
      end

      create unique_index(
               :tenant_modules,
               [:module_id],
               name: :tenant_modules_module_id_idx,
               prefix: schema
             )
    end
  end
end
