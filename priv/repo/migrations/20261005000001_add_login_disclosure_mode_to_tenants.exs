# REQ-442 (design lib/letflow/design/req442-per-tenant-login-disclosure-mode.md §1,
# decision 0043 D-A) -- per-tenant login disclosure mode on the PUBLIC `tenants`
# table. NULL means "use the deployment-wide mode". Deliberately NOT stored in the
# tenant `settings` blob (a tenant admin must not set or read it) and NOT added to
# `Letflow.TenantProvisioning.tenant_scoped_migrations/0`. No default, no index
# (only read in a `limit 50` select list), no data change.
defmodule Letflow.Repo.Migrations.AddLoginDisclosureModeToTenants do
  use Ecto.Migration

  def up do
    alter table(:tenants) do
      add :login_disclosure_mode, :string
    end

    create constraint(:tenants, :tenants_login_disclosure_mode_check,
             check: "login_disclosure_mode IN ('uniform_plus_email', 'redirect_single')"
           )
  end

  def down do
    drop constraint(:tenants, :tenants_login_disclosure_mode_check)

    alter table(:tenants) do
      remove :login_disclosure_mode
    end
  end
end
