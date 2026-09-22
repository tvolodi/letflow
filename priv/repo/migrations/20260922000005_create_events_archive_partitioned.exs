# Letflow.Repo.Migrations.CreateEventsArchivePartitioned
#
# REQ-376, migration 5 of 6 (numbering per
# lib/letflow/design/req376-partition-event-retirement.md section 2.1 item 5;
# items 6a-6c below cover the design's "migration 6" trio). Identical shape
# to migration 1 (20260922000001_create_events_partitioned.exs), for
# `events_archive`: same column list (events_archive's current columns minus
# tenant_id, plus archived_at), PARTITION BY RANGE (created_at), three
# indexes preserved on the parent (no unique index, matching the current
# table exactly).
#
# `global_seq` here stays plain `bigint` with NO default (matching the
# current table) -- values are always copied, never generated.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY.
# Registered in Letflow.TenantProvisioning.tenant_scoped_migrations/0 --
# both halves are mandatory.
defmodule Letflow.Repo.Migrations.CreateEventsArchivePartitioned do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      CREATE TABLE "#{schema}".events_archive_p (
        event_id uuid NOT NULL,
        created_at timestamp NOT NULL,
        instance_id uuid NOT NULL,
        event_type varchar NOT NULL,
        payload jsonb NOT NULL DEFAULT '{}',
        actor_id uuid NOT NULL,
        sequence_number bigint NOT NULL,
        idempotency_key varchar NOT NULL,
        metadata jsonb NOT NULL DEFAULT '{}',
        global_seq bigint NOT NULL,
        archived_at timestamp NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
        PRIMARY KEY (event_id, created_at)
      ) PARTITION BY RANGE (created_at)
      """)

      # `_p`-suffixed for the same reason as migration 1's uq_event_sequence_p
      # (index names are schema-unique in Postgres, not table-unique, and the
      # current unpartitioned events_archive table already owns these three
      # names) -- migration 8 (swap_events_archive_partitioned) renames the
      # old table's indexes out of the way first, then renames these into
      # their permanent, unsuffixed names.
      execute(
        ~s{CREATE INDEX idx_archive_instance_p ON "#{schema}".events_archive_p (instance_id, sequence_number)}
      )

      execute(~s{CREATE INDEX idx_archive_type_p ON "#{schema}".events_archive_p (event_type)})
      execute(~s{CREATE INDEX idx_archive_time_p ON "#{schema}".events_archive_p (created_at)})
    end
  end

  def down do
    if prefix() do
      schema = prefix()
      execute(~s{DROP TABLE IF EXISTS "#{schema}".events_archive_p})
    end
  end
end
