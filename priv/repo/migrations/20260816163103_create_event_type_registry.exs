# Letflow.Repo.Migrations.CreateEventTypeRegistry
#
# Builds the event_type_registry table REQ-024 adds -- this is the first real
# (non-CreateTenantSchemas) entry Letflow.TenantProvisioning.tenant_scoped_migrations/0
# ever carries (see lib/letflow/tenant_provisioning.ex, which this requirement's
# implementation work also edits). Ported from R-Co's
# migrations/002_event_type_registry.sql table shape (behavior ported, not the
# raw SQL) -- see lib/letflow/design/req024-event-type-registry.md section 3
# for the full column-by-column rationale.
#
# Tenant-scoped (schema-per-tenant, per REQ-022's :prefix mechanism), per
# Decision B's general rule for business tables. Follows the required guard
# pattern from lib/letflow/design/req022-tenant-schema-provisioning.md section 4
# (and test/support/req022_migration_fixture.ex's precedent for it): change/0
# branches on Ecto.Migration.prefix()'s truthiness and no-ops entirely when no
# prefix was supplied to the enclosing migrator run (a plain `mix ecto.migrate`),
# so this migration never pollutes the public schema. It only takes real effect
# when replayed against a tenant's own schema via
# Letflow.TenantProvisioning.replay_migrations/2, which passes a real :prefix.
#
# Divergences from R-Co's 002_event_type_registry.sql, stated explicitly here
# (full reasoning in the design doc section 3):
#   - schema_version has NO DB-level DEFAULT 1 -- register_type/2 requires the
#     caller to supply it explicitly; an implicit default would mask a caller
#     error rather than surface it.
#   - No separate index(:event_type_registry, [:name]) (R-Co's idx_etr_name) --
#     the unique index below already leads with :name, so it serves a
#     `WHERE name = $1` lookup directly. Same redundancy-avoidance
#     req022-tenant-schema-provisioning.md section 2 already applied to
#     tenant_schemas' indexes.
#   - No seed data -- R-Co seeds 20 built-in platform event types inline;
#     nothing yet exists that emits them (S3's instance engine), so seeding
#     here would be meaningless. Left for whichever future requirement first
#     needs a platform event type registered.
#   - timestamps() is the plain, unrenamed inserted_at/updated_at pair (this
#     codebase's established general default -- tenants/users/tenant_schemas'
#     own provisioned_at rename was a one-off for a column with distinct
#     domain meaning, not the general rule), not renamed to created_at despite
#     R-Co's literal column name.
defmodule Letflow.Repo.Migrations.CreateEventTypeRegistry do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:event_type_registry, primary_key: false, prefix: prefix()) do
        add :id, :binary_id, primary_key: true
        add :name, :string, null: false
        add :schema_version, :integer, null: false
        add :json_schema, :map, null: false, default: %{}
        add :description, :text

        timestamps()
      end

      create unique_index(:event_type_registry, [:name, :schema_version], prefix: prefix())
    end
  end
end
