# Letflow.Repo.Migrations.CreateApiTokensTenantScoped
#
# SECURITY-SENSITIVE -- api_tokens.token_hash is the ONLY on-disk representation of
# an issued token. The plaintext value returned once at issuance (see
# Letflow.Identity.create_token/3) is NEVER written to any column on this table, or
# to any other table in this codebase. See
# lib/letflow/design/req076-identity-tokens-roles-onboarding.md section 2 for the
# full rationale this header condenses (INV-4).
#
# TENANT-SCOPED, not global -- lives in each tenant's own Postgres schema, alongside
# users/groups/tenant_role (Decision 0006). api_tokens.user_id references users.id, a
# same-schema FK (both tables live in the tenant's schema together).
#
# `roles` is a plain Postgres text array (`{:array, :string}`), not `jsonb` -- a
# deliberate Ecto-idiomatic simplification over R-Co's `roles_json` column; no
# acceptance criterion needs JSON-specific querying (design doc section 2).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, matching
# lib/letflow/design/req022-tenant-schema-provisioning.md section 4's guard pattern.
# Registered in Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both halves
# are mandatory (see that module's own manifest comment).
defmodule Letflow.Repo.Migrations.CreateApiTokensTenantScoped do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:api_tokens, primary_key: false, prefix: prefix()) do
        add :id, :binary_id, primary_key: true
        add :user_id, references(:users, type: :binary_id), null: false
        add :name, :string, null: false
        add :token_hash, :string, null: false
        add :roles, {:array, :string}, null: false
        add :expires_at, :utc_datetime
        add :revoked_at, :utc_datetime
        add :last_used_at, :utc_datetime

        timestamps(updated_at: false)
      end

      create unique_index(:api_tokens, [:token_hash], prefix: prefix())
      create index(:api_tokens, [:user_id], prefix: prefix())
    end
  end
end
