# Letflow.Repo.Migrations.CreateUsersTenantScoped
#
# SECURITY-SENSITIVE -- this is the artefact SECURITY-REVIEWER re-derives its
# verdict against, not the design doc. See
# lib/letflow/design/req063-identity-tables-schema-per-tenant.md section 2.3 for
# the full rationale this header condenses.
#
# 1. Decision 0006 D1's per-tenant copy of `users`, replacing the legacy public
#    `users` table. The legacy public table is dropped separately -- see
#    20260819000004_drop_legacy_public_identity_tables.exs -- NOT by this migration.
#
# 2. `tenant_id` is RETAINED on this per-tenant copy -- D2/REQ-064's job to drop it,
#    not this migration's.
#
# 3. `unique_index(:users, [:username])` -- carried forward unchanged, in shape.
#    Its MEANING changes from global-unique to per-tenant-unique purely as a
#    consequence of the table now living inside a per-tenant schema -- no index
#    definition edit needed to produce that effect. Decision 0006 section 3.1: this
#    is a deliberate, adopted change (globally-unique usernames across tenants was a
#    multi-tenancy defect), not an incidental side effect to gloss over.
#
# 4. `unique_index(:users, [:external_realm, :external_id], where: "external_id IS
#    NOT NULL", name: :users_external_identity_partial_index)` -- carried forward
#    unchanged, in shape, same per-tenant reinterpretation as (3). Decision 0006
#    section 3.2: the prior GLOBAL one-OIDC-identity-per-user guarantee is not lost,
#    it is relocated to `tenants_idp_realm_id_partial_index` (a realm binds to
#    exactly one tenant, immutably -- enforced on `tenants`, a public-schema table
#    Decision 0006 D3 keeps).
#
# 5. DIVERGENCE CLOSED -- stated explicitly so it is never mistaken for a new
#    weakening: docs/migration/decisions/0003-ecto-schema-strategy.md line 132 and
#    lib/letflow/identity.ex's JIT upsert path both describe the upsert key as
#    (tenant_id, external_realm, external_id), but the SHIPPED index -- both in the
#    prior public migration and unchanged here -- is (external_realm, external_id)
#    without tenant_id. Before this move, the database was STRICTER than the
#    documented contract (a real gap, not a weakening). This migration's move closes
#    that gap: tenant_id's role in that key is now taken over by the schema boundary
#    itself -- two rows with the same (external_realm, external_id) cannot coexist
#    WITHIN one tenant's schema (the index still enforces that), and cannot coexist
#    ACROSS tenant schemas either, by the section 3.2 argument in point 4 above. The
#    index is not changed by this migration; only its enforcement domain (now one
#    schema instead of the whole database) changes, which is exactly what makes the
#    documented and shipped keys agree for the first time.
#
# 6. No DB CHECK constraint for auth_source-vs-external-fields consistency --
#    unchanged, still an application-level (changeset) invariant.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, matching
# lib/letflow/design/req022-tenant-schema-provisioning.md section 4's guard pattern.
# Registered in Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both halves
# are mandatory. No FK dependency on groups/tenant_role and nothing depends on it, so
# it may sort anywhere relative to them within REQ-063's own three entries; placed
# last for narrative grouping only (least-simple table last), matching the design
# doc's own stated non-requirement here.
#
# See lib/letflow/design/req063-identity-tables-schema-per-tenant.md section 2.3.
defmodule Letflow.Repo.Migrations.CreateUsersTenantScoped do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:users, primary_key: false, prefix: prefix()) do
        add :id, :binary_id, primary_key: true
        add :tenant_id, :binary_id, null: false
        add :username, :string, null: false
        add :display_name, :string, null: false
        add :email, :string, null: false
        add :password_hash, :string, null: false
        add :status, :string, null: false, default: "active"
        add :auth_source, :string, null: false, default: "internal"
        add :external_id, :string
        add :external_realm, :string

        timestamps()
      end

      create unique_index(:users, [:username], prefix: prefix())

      create unique_index(:users, [:external_realm, :external_id],
               where: "external_id IS NOT NULL",
               name: :users_external_identity_partial_index,
               prefix: prefix()
             )

      create index(:users, [:tenant_id, :status, :inserted_at], prefix: prefix())
    end
  end
end
