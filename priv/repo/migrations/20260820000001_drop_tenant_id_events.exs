# Letflow.Repo.Migrations.DropTenantIdEvents
#
# Decision 0006 (docs/migration/decisions/0006-identity-tables-schema-per-tenant.md)
# D2, REQ-064 -- drops `tenant_id` from `events`. See
# lib/letflow/design/req064-drop-tenant-id.md sections 1-2 for the full rationale:
# `events` has lived inside a per-tenant Postgres schema since Decision 0003
# Dimension B, so `tenant_id` was always a redundant column here, never the sole
# scoping mechanism -- the schema boundary (`prefix:`) already identifies the
# tenant on every read/write. No index on this table references `tenant_id` (none
# exists that does), so this is a pure column drop with no index-shape
# consequence.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY,
# matching every migration this requirement's own tables were originally created
# by (20260816120001_create_events.exs). A plain `mix ecto.migrate` (no :prefix)
# no-ops on this file; only a Letflow.TenantProvisioning.replay_migrations/2 run
# (real tenant schema name) takes the real branch. Registered in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both halves are
# mandatory.
#
# `remove(:tenant_id, :binary_id)` (not bare `remove(:tenant_id)`) -- the
# three-argument form Ecto's own change/0 auto-reversal needs to infer the
# rollback column type, matching every `add :tenant_id, :binary_id` this
# column was originally created with across every migration in this schema.
defmodule Letflow.Repo.Migrations.DropTenantIdEvents do
  use Ecto.Migration

  def change do
    if prefix() do
      alter table(:events, prefix: prefix()) do
        remove :tenant_id, :binary_id
      end
    end
  end
end
