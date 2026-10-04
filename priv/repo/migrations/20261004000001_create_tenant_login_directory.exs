# REQ-435 (design lib/letflow/design/req434-email-first-login-directory.md §1.1,
# decision 0042) -- new public-schema table, same tier as `tenants` and
# `tenant_memberships` (global; NOT tenant-scoped, no `prefix()` guard, and
# deliberately NOT added to `Letflow.TenantProvisioning.tenant_scoped_migrations/0`).
#
# A pointer table: (keyed HMAC of a normalised email, tenant_id). No password,
# role, user id, external id or profile field. Rows are insert-or-delete only,
# so there is no surrogate id and no `updated_at`; the pair IS the identity.
#
# The composite primary key's leading column serves the lookup, so no separate
# unique index is created; the `tenant_id` index exists only so the FK cascade
# on tenant deletion does not scan the table.
defmodule Letflow.Repo.Migrations.CreateTenantLoginDirectory do
  use Ecto.Migration

  def change do
    create table(:tenant_login_directory, primary_key: false) do
      add :email_key, :binary, null: false, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :inserted_at, :naive_datetime, null: false
    end

    create constraint(:tenant_login_directory, :email_key_is_32_bytes,
             check: "octet_length(email_key) = 32"
           )

    create index(:tenant_login_directory, [:tenant_id])
  end
end
