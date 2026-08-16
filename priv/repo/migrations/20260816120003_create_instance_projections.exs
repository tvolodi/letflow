# Letflow.Repo.Migrations.CreateInstanceProjections
#
# REQ-023, migration 3 of 6. Implements lib/letflow/design/req023-event-store-schema.md
# section 3.3 (the `instance_projections` table). Ported from R-Co
# migrations/001_event_store.sql:81-104, plus tenant_id from
# 028_adp02_tenant_scope_persistence.sql:18-19.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY. See
# lib/letflow/design/req022-tenant-schema-provisioning.md section 4 and
# 20260816120001_create_events.exs's header for the full rationale. Registered in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both halves are mandatory.
#
# SCOPE NOTE (REQ-023 acceptance criterion 5, stated in full in
# Letflow.EventStore.InstanceProjection's moduledoc): this table's *schema* is
# event-store scope -- event_store.md's "DB tables / columns per operation" section
# shows Store.append() reading and writing it directly for the ES-01 active-instance
# guard and the DB-03 last_event_seq update. Its *meaningful population at instance
# start* is EE-01/S3 territory (src/engine/, not built yet). Do not read this migration
# as instance-engine work landing early.
#
# COLUMNS DELIBERATELY NOT CREATED HERE -- R-Co's 001 also carries `definition_id`,
# `correlation_key`, `current_nodes`, `variables`, `error_detail`, `completed_at` and
# `cancelled_at` (001:83-93), plus the `uq_instance_correlation` and
# `idx_proj_definition` indexes that depend on them (001:98-107). All of those are
# written by the instance engine, which REQ-023 explicitly does not build. Named here
# so S3/EE-01 knows precisely what its own ALTER TABLE migration must add (design
# section 3.3, OQ-7).
#
# `status` is stored as R-Co's uppercase strings (001:85-86:
# ACTIVE | COMPLETED | CANCELLED | ERROR) and surfaced as Elixir atoms by Ecto.Enum's
# keyword-mapping form in the schema module -- the 0003 Decision A "TEXT column with
# comment-documented allowed values becomes an Ecto.Enum" swap. ERROR is included even
# though REQ-023 only requires ACTIVE/CANCELLED/COMPLETED, because R-Co defines it and
# omitting it would force an enum migration the first time S3 needs it.
defmodule Letflow.Repo.Migrations.CreateInstanceProjections do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:instance_projections, primary_key: false, prefix: prefix()) do
        add :instance_id, :binary_id, primary_key: true
        add :tenant_id, :binary_id, null: false
        add :status, :string, null: false, default: "ACTIVE"
        add :last_event_seq, :bigint, null: false, default: 0

        timestamps(inserted_at: :started_at, type: :utc_datetime_usec)
      end

      create index(:instance_projections, [:status],
               name: :idx_proj_status,
               where: "status = 'ACTIVE'",
               prefix: prefix()
             )
    end
  end
end
