# Letflow.Repo.Migrations.DropTenantIdProcessDefinitions
#
# Decision 0006 D2, REQ-064 -- drops `tenant_id` from `process_definitions`. See
# lib/letflow/design/req064-drop-tenant-id.md sections 1-2. This table's own
# original migration (20260816193001_create_process_definitions.exs) already
# documents its tenant-prefixed `uq_definition_tenant_version`-family indexes as
# deliberately never built (per 0003 Decision B) -- the shipped
# `uq_definition_version`/`uq_active_definition` indexes are `tenant_id`-free, so
# this is a pure column drop with no index-shape consequence.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY.
# Registered in Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both
# halves are mandatory.
defmodule Letflow.Repo.Migrations.DropTenantIdProcessDefinitions do
  use Ecto.Migration

  def change do
    if prefix() do
      alter table(:process_definitions, prefix: prefix()) do
        remove :tenant_id, :binary_id
      end
    end
  end
end
