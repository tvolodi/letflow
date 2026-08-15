# Letflow.Repo.Migrations.CreateTenants
#
# Ported from R-Co src/design/adp-04b-tenant-realm-binding.md ("Data model and
# migration/backfill semantics", "Key invariants" 1-2).
#
# Schema-per-tenant provisioning (Ecto :prefix/dynamic-repo, per
# docs/migration/decisions/0003-ecto-schema-strategy.md Decision B) is NOT built in
# this migration. This table (and users/groups/tenant_role in their sibling
# migrations) targets Ecto's single default schema. tenant_id is retained as an
# intra-schema column on users per Decision B regardless. Multi-schema provisioning
# is deferred as explicit follow-up work — see lib/letflow/design/identity-schema.md
# section 1 for the full reasoning and the recommended follow-up requirement.
#
# idp_realm_id's unique index is PARTIAL (WHERE idp_realm_id IS NOT NULL) per
# REQ-015, resolving adp-04b's own Open Question OQ-2 explicitly in favor of
# partial (adp-04b leaves this open; Letflow does not).
#
# No DB CHECK constraint enforces "idp_realm_id required for non-default tenants
# in OIDC-enabled mode" (adp-04b's Forward Constraints) -- that rule is conditional
# on runtime OIDC-mode config, which a migration-time CHECK constraint cannot see.
# It is an application-level (changeset) invariant, enforced in REQ-019.
defmodule Letflow.Repo.Migrations.CreateTenants do
  use Ecto.Migration

  def change do
    create table(:tenants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :slug, :string, null: false
      add :display_name, :string, null: false
      add :status, :string, null: false, default: "active"
      add :idp_realm_id, :string

      timestamps()
    end

    create unique_index(:tenants, [:slug])

    create unique_index(:tenants, [:idp_realm_id],
             where: "idp_realm_id IS NOT NULL",
             name: :tenants_idp_realm_id_partial_index
           )
  end
end
