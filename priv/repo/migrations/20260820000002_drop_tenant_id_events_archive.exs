# Letflow.Repo.Migrations.DropTenantIdEventsArchive
#
# Decision 0006 D2, REQ-064 -- drops `tenant_id` from `events_archive`. See
# lib/letflow/design/req064-drop-tenant-id.md sections 1-2. Same rationale as
# 20260820000001_drop_tenant_id_events.exs: this table has lived inside a
# per-tenant Postgres schema since its own original migration
# (20260816120005_create_events_archive.exs), whose own header already notes
# R-Co's tenant-prefixed indexes were never ported (0003 Decision B) -- no index
# here references `tenant_id`, so this is a pure column drop.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY.
# Registered in Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both
# halves are mandatory.
defmodule Letflow.Repo.Migrations.DropTenantIdEventsArchive do
  use Ecto.Migration

  def change do
    if prefix() do
      alter table(:events_archive, prefix: prefix()) do
        remove :tenant_id, :binary_id
      end
    end
  end
end
