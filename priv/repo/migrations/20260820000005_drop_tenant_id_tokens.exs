# Letflow.Repo.Migrations.DropTenantIdTokens
#
# Decision 0006 D2, REQ-064 -- drops `tenant_id` from `tokens`. See
# lib/letflow/design/req064-drop-tenant-id.md sections 0, 1-2. The Ecto schema
# module for this table is Letflow.Engine.TokenRecord (lib/letflow/engine/token_record.ex),
# NOT Letflow.Engine.Token (REQ-044's separate, zero-Ecto-dependency in-memory
# struct) -- see the design doc §0's module-ownership verification. Neither
# `idx_token_instance` (on instance_id alone) nor `idx_token_parent` (on
# parent_token_id alone) references `tenant_id`, so this is a pure column drop
# with no index-shape consequence.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY.
# Registered in Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both
# halves are mandatory.
defmodule Letflow.Repo.Migrations.DropTenantIdTokens do
  use Ecto.Migration

  def change do
    if prefix() do
      alter table(:tokens, prefix: prefix()) do
        remove :tenant_id, :binary_id
      end
    end
  end
end
