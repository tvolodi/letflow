# Letflow.Repo.Migrations.AddServiceCatalogVersioning
#
# REQ-373. Implements lib/letflow/design/req373-service-catalog-version-lifecycle.md
# section 4 -- adds a version identity + ACTIVE/RETIRED status to
# `service_catalog` (representing the single CURRENT version) and a new
# sibling archive table, `service_catalog_versions`, holding every version a
# `publish`/`retire` supersedes.
#
# GLOBAL -- no `prefix:`, not registered in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0. This migration
# alters an already-global table (`service_catalog`, 20260830000001) and adds
# a new sibling table for it -- it inherits that table's own global-ness
# (design section 0/1), not a fresh decision.
#
# Column defaults handle every PRE-EXISTING service_catalog row's
# version/version_id/status for free at ALTER TABLE time. `published_at`
# cannot get a single fixed-value default (it must mirror each row's own
# `created_at`), so it is added nullable, backfilled via a raw `UPDATE`, then
# constrained NOT NULL -- the "nullable add, backfill, then constrain" shape
# this codebase already uses wherever a new not-null column needs a per-row
# (not constant) backfilled value (design section 4).
#
# `up/0`/`down/0` (not a bare `change/0`) because the backfill `UPDATE` and
# the `ALTER COLUMN ... SET NOT NULL` it enables are not DDL commands Ecto
# can auto-reverse -- mirrors 20260921000002_add_kind_to_tenant_role.exs's
# own up/down shape for the identical reason (a data-mutating step alongside
# DDL). `flush/0` after the `alter table` block, before the raw `UPDATE`,
# for the same reason that migration's own comment documents: Ecto queues
# DDL and only sends it at a flush point, so a same-connection raw SQL
# statement issued before an explicit `flush/0` would run against a
# connection that has not yet seen the `ADD COLUMN`.
defmodule Letflow.Repo.Migrations.AddServiceCatalogVersioning do
  use Ecto.Migration

  def up do
    alter table(:service_catalog) do
      add :version, :string, null: false, default: "1"
      add :version_id, :binary_id, null: false, default: fragment("gen_random_uuid()")
      add :status, :string, null: false, default: "ACTIVE"
      add :published_at, :utc_datetime_usec
      add :retired_at, :utc_datetime_usec
    end

    flush()

    execute("UPDATE service_catalog SET published_at = created_at WHERE published_at IS NULL")

    alter table(:service_catalog) do
      modify :published_at, :utc_datetime_usec, null: false
    end

    create constraint(:service_catalog, :chk_service_catalog_status,
             check: "status IN ('ACTIVE', 'RETIRED')"
           )

    # No chk_service_catalog_version_length CHECK constraint: `version` is
    # `:string` (Ecto's default `varchar(255)`), so Postgres's own column
    # type already enforces `char_length(version) <= 255` -- a CHECK
    # constraint re-stating that bound is dead code the type-level limit
    # would always satisfy first (TEST-DESIGNER finding, REQ-373 rework).
    # Removed rather than widening the column: no requirement or design
    # note calls for `version` to hold more than 255 chars (design §9 OQ-4
    # only says "opaque string"), so there is nothing to make the constraint
    # reachable *for*.

    # Append-only archive of every version a publish/retire supersedes
    # (design section 1/3.1). `version_id` is the PK -- copied verbatim from
    # the `service_catalog` row's own `version_id` at the moment it's
    # archived, never regenerated (design section 4).
    create table(:service_catalog_versions, primary_key: false) do
      add :version_id, :binary_id, primary_key: true, null: false
      add :service_id, :string, null: false
      add :version, :string, null: false
      add :endpoint_url, :string, null: false
      add :request_schema, :text
      add :response_schema, :text
      add :required_auth, :string, null: false
      add :timeout_ms, :integer, null: false
      add :retry_policy, :text
      add :published_at, :utc_datetime_usec, null: false
      add :retired_at, :utc_datetime_usec, null: false
    end

    # Deliberate: no FK from service_catalog_versions.service_id to
    # service_catalog.service_id -- see the design doc section 4 / section 9
    # OQ-1 (avoids giving delete/1 a new, out-of-scope FK-violation failure
    # mode). The unique index below is both the archive table's own
    # duplicate-version guard and, per leftmost-prefix B-tree behavior,
    # already serves any future `WHERE service_id = ?`-only query -- no
    # separate single-column service_id index is added.
    create unique_index(:service_catalog_versions, [:service_id, :version],
             name: :idx_service_catalog_versions_service_id_version
           )
  end

  def down do
    drop table(:service_catalog_versions)

    drop constraint(:service_catalog, :chk_service_catalog_status)

    alter table(:service_catalog) do
      remove :retired_at
      remove :published_at
      remove :status
      remove :version_id
      remove :version
    end
  end
end
