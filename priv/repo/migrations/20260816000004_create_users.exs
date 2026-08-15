# Letflow.Repo.Migrations.CreateUsers
#
# Ported from R-Co src/design/adp-04-user-tenant-binding.md ("Data model and
# migration/backfill semantics", "Index and constraint guidance") and
# src/design/adp-04a-external-identity-linkage-user.md ("Data model and
# migration/backfill semantics", "Unique index semantics", "Key invariants").
#
# tenant_id has NO database-level foreign-key reference to tenants.id. This is
# deliberate: docs/migration/decisions/0003-ecto-schema-strategy.md Decision B's
# target model is schema-per-tenant (deferred as a follow-up mechanism, see
# lib/letflow/design/identity-schema.md section 1) under which cross-schema FKs
# don't apply the same way same-schema FKs do. tenant scoping is enforced at the
# service/repository boundary (per adp-04's own repository contract), not via a SQL
# FK, so nothing needs reworking when tenant tables eventually move behind
# per-tenant schema prefixes.
#
# The (external_realm, external_id) unique index is PARTIAL (WHERE external_id IS
# NOT NULL), per REQ-015's own acceptance criterion and matching the NULL-safe form
# adp-04a's "Unique index semantics" section recommends. This is not needed to avoid
# NULL-collisions -- Postgres unique indexes already treat each NULL as distinct, so
# a plain index would not falsely collide internal users (external_id = NULL). The
# partial predicate instead scopes the index to exactly the rows adp-04a's
# repository contract queries by (non-null external_id), avoiding an index entry for
# every row that will never be looked up by this key.
#
# NO DB CHECK constraint enforces auth_source-vs-external-fields consistency
# (adp-04a's rule 2). This is an application-level (changeset) invariant --
# implemented in REQ-018/REQ-019, not this migration.
defmodule Letflow.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
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

    create unique_index(:users, [:username])

    create unique_index(:users, [:external_realm, :external_id],
             where: "external_id IS NOT NULL",
             name: :users_external_identity_partial_index
           )

    create index(:users, [:tenant_id, :status, :inserted_at])
  end
end
