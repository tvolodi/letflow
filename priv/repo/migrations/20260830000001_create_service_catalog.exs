# Letflow.Repo.Migrations.CreateServiceCatalog
#
# REQ-191. Implements lib/letflow/design/req191-service-catalog-core.md
# section 1 (the `service_catalog` table). Ports R-Co
# `migrations/049_repository_service_catalog.sql` plus
# `GBL-117_svc01_service_catalog_scope.sql` (SVC-01).
#
# GLOBAL -- no prefix:, deliberately diverging from
# docs/migration/decisions/0003-ecto-schema-strategy.md Decision B (schema-
# per-tenant for business tables). Flagged here, in
# Letflow.ServiceCatalog's moduledoc, and in the design doc section 0 for
# REVIEWER sign-off.
#
# R-Co-grounded reason, structural not incidental: a scope = 'global'
# service-catalog entry is by definition referenceable by every tenant, and
# service_id is unique across all tenants regardless of scope (R-Co's SVC-01
# rule, GBL-117_svc01_service_catalog_scope.sql). Neither property can be
# expressed by a per-tenant-schema copy: a per-tenant copy could not enforce
# global service_id uniqueness across schemas without a cross-schema
# mechanism Decision B doesn't provide, and a scope = 'global' row would need
# to exist identically in every tenant's schema simultaneously, which is not
# what schema-per-tenant means. This is exactly the same shape as REQ-041's
# solution_pack_installs/solution_pack_artefact_bases/pack_update_resolutions
# (20260817083801_create_solution_pack_installs.exs's own moduledoc:
# "install records are cross-tenant infrastructure") -- this migration
# follows that already-accepted precedent rather than inventing a new one.
#
# This table therefore carries no `if prefix() do ... end` guard and is NOT
# registered in Letflow.TenantProvisioning.tenant_scoped_migrations/0.
#
# `owner_tenant_id`, when present, carries a database-level foreign key to
# tenants.id (the global Letflow.Identity.Tenant table) -- same
# `references(:tenants, type: :binary_id)` shape tenant_schemas.tenant_id and
# solution_pack_installs.tenant_id already use. No `on_delete:` given (Ecto/
# Postgres default ON DELETE NO ACTION), matching those two precedents.
#
# `service_id` is the PRIMARY KEY (a caller-supplied string, not a
# binary_id) -- this gives global uniqueness across tenants and scopes for
# free, with no separate unique index needed (design section 1).
#
# Every CHECK below is a DATABASE-level constraint (`create constraint/2`
# with `check:`, the same DSL primitive 20260817181240_create_event_retention_policies.exs
# already establishes for this codebase), not an Ecto.Changeset validation
# -- REQ-191 acceptance criteria 1/2 explicitly require DB-level enforcement,
# not changeset-level.
defmodule Letflow.Repo.Migrations.CreateServiceCatalog do
  use Ecto.Migration

  def change do
    create table(:service_catalog, primary_key: false) do
      add :service_id, :string, primary_key: true, null: false
      add :endpoint_url, :string, null: false
      add :request_schema, :text
      add :response_schema, :text
      add :required_auth, :string, null: false, default: "NONE"
      add :timeout_ms, :integer, null: false
      add :retry_policy, :text
      add :scope, :string, null: false, default: "global"
      add :owner_tenant_id, references(:tenants, type: :binary_id)

      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create constraint(:service_catalog, :chk_service_catalog_service_id_length,
             check: "char_length(service_id) <= 255"
           )

    create constraint(:service_catalog, :chk_service_catalog_endpoint_url_length,
             check: "char_length(endpoint_url) <= 2048"
           )

    create constraint(:service_catalog, :chk_service_catalog_required_auth,
             check: "required_auth IN ('NONE', 'API_KEY', 'OAUTH2', 'MUTUAL_TLS')"
           )

    create constraint(:service_catalog, :chk_service_catalog_timeout_ms,
             check: "timeout_ms BETWEEN 1 AND 3600000"
           )

    create constraint(:service_catalog, :chk_service_catalog_scope,
             check: "scope IN ('global', 'tenant')"
           )

    # Design section 1's table-level consistency CHECK: a row is valid only
    # when (scope = 'global' AND owner_tenant_id IS NULL) OR
    # (scope = 'tenant' AND owner_tenant_id IS NOT NULL) -- every other
    # combination is rejected by the database, not merely discouraged at the
    # changeset layer (REQ-191 acceptance criterion 1).
    create constraint(:service_catalog, :chk_service_catalog_scope_owner_consistency,
             check:
               "(scope = 'global' AND owner_tenant_id IS NULL) OR (scope = 'tenant' AND owner_tenant_id IS NOT NULL)"
           )

    # Backs get_for_tenant/2's `scope = 'global' OR owner_tenant_id = ?`
    # predicate's global half (design section 1).
    create index(:service_catalog, [:scope], name: :idx_service_catalog_scope)

    # Backs the tenant-owned half of the same predicate, and the
    # FK-referencing-side convention this codebase already follows.
    create index(:service_catalog, [:owner_tenant_id], name: :idx_service_catalog_owner_tenant_id)

    # Backs list_for_tenant/2's keyset pagination order (design section 3.3).
    create index(:service_catalog, [:created_at, :service_id],
             name: :idx_service_catalog_list_cursor
           )
  end
end
