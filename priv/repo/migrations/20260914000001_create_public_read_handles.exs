# Letflow.Repo.Migrations.CreatePublicReadHandles
#
# REQ-352 (design lib/letflow/design/req352-unauthenticated-read-platform.md
# §3, per pattern lib/letflow/design/req323-unauthenticated-read-pattern.md
# and decision docs/migration/decisions/0028-unauthenticated-read-boundary.md).
#
# GLOBAL TABLE, NOT TENANT-SCOPED -- same convention as `tenants`
# (priv/repo/migrations/20260816000001_create_tenants.exs): no `prefix:`
# option anywhere in this table's definition, and this migration is
# deliberately EXCLUDED from Letflow.TenantProvisioning's
# @tenant_scoped_migration_manifest / tenant_scoped_migrations/0 list (it is
# simply never added to that manifest -- there is no separate opt-out flag).
# This table IS the lookup that decides which tenant schema a request
# resolves into, so it cannot itself live inside one -- exactly the same
# reasoning `tenants` itself is excluded for.
#
# Lands together with its first writer, Letflow.PublicRead.issue_handle/4
# (lib/letflow/public_read.ex), in this same diff -- per decision 0028's
# standing prohibition ("public_read_handles must land with its first
# writer, not ahead of one") and the REQ-056 "table with no producer"
# failure mode it names.
defmodule Letflow.Repo.Migrations.CreatePublicReadHandles do
  use Ecto.Migration

  def change do
    create table(:public_read_handles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :handle_hash, :string, null: false
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :resource_id, :binary_id, null: false
      add :expires_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      timestamps()
    end

    create unique_index(:public_read_handles, [:handle_hash])
    create index(:public_read_handles, [:tenant_id])
    create index(:public_read_handles, [:kind, :resource_id])
  end
end
