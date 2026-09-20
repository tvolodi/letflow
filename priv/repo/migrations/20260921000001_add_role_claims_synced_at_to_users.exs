# Letflow.Repo.Migrations.AddRoleClaimsSyncedAtToUsers
#
# REQ-378 / ISS-0736, REWORK 2 -- see
# lib/letflow/design/req378-oidc-live-revocation-check.md §2.2.1/§7 for the
# full design this migration implements.
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`), matching `users`
# itself (Decision 0006 D1) -- this migration only adds one column to that
# existing tenant-scoped table.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY,
# and this file's registration in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0 (both halves are
# mandatory -- see that module's own manifest comment).
#
# `null: true`, no default, no backfill statement -- every existing row
# (every OIDC user provisioned before this fix ships, and every
# internal/non-OIDC user) lands NULL for free, which is exactly the correct
# "not yet synced" meaning for all of them (design §2.2.1). The one-time sync
# mechanism itself (Letflow.Identity.sync_role_claims_from_token/3) is what
# populates this column and stamps it -- never this migration.
#
# No SQL below interpolates tenant- or user-controlled data (INV-7) -- plain
# Ecto migration DSL only.
defmodule Letflow.Repo.Migrations.AddRoleClaimsSyncedAtToUsers do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      alter table(:users, prefix: schema) do
        add :role_claims_synced_at, :utc_datetime_usec, null: true
      end
    end
  end
end
