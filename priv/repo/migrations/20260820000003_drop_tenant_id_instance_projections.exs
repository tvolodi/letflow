# Letflow.Repo.Migrations.DropTenantIdInstanceProjections
#
# Decision 0006 D2, REQ-064 -- drops `tenant_id` from `instance_projections`. See
# lib/letflow/design/req064-drop-tenant-id.md sections 1-2. Same rationale as the
# other two event-store migrations in this batch: `idx_proj_definition` is on
# `definition_id` alone, `uq_instance_correlation` is on `(definition_id,
# correlation_key)`, the `status` index is bare -- none references `tenant_id`,
# so this is a pure column drop with no index-shape consequence.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY.
# Registered in Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both
# halves are mandatory.
defmodule Letflow.Repo.Migrations.DropTenantIdInstanceProjections do
  use Ecto.Migration

  def change do
    if prefix() do
      alter table(:instance_projections, prefix: prefix()) do
        remove :tenant_id, :binary_id
      end
    end
  end
end
