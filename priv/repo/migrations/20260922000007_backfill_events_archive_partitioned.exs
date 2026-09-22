# Letflow.Repo.Migrations.BackfillEventsArchivePartitioned
#
# REQ-376, migration 6b of 6 (design doc section 2.1 item 6). Copies every
# existing `events_archive` row into `events_archive_p` (routed by Postgres
# into the matching dedicated-historical-month or default partition migration
# 6a already created). No sequence to re-seed here (`events_archive.global_seq`
# carries no default -- values are always copied, never generated, matching
# the source table exactly).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY.
# Registered in Letflow.TenantProvisioning.tenant_scoped_migrations/0 --
# both halves are mandatory.
#
# `up/0`/`down/0`: a data-copy step, not a DDL command Ecto can auto-reverse.
defmodule Letflow.Repo.Migrations.BackfillEventsArchivePartitioned do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      INSERT INTO "#{schema}".events_archive_p
        (event_id, created_at, instance_id, event_type, payload, actor_id,
         sequence_number, idempotency_key, metadata, global_seq, archived_at)
      SELECT event_id, created_at, instance_id, event_type, payload, actor_id,
             sequence_number, idempotency_key, metadata, global_seq, archived_at
      FROM "#{schema}".events_archive
      ORDER BY created_at
      """)
    end
  end

  def down do
    if prefix() do
      schema = prefix()
      execute(~s{TRUNCATE "#{schema}".events_archive_p})
    end
  end
end
