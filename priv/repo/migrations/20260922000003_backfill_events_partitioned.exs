# Letflow.Repo.Migrations.BackfillEventsPartitioned
#
# REQ-376, migration 3 of 6. Implements
# lib/letflow/design/req376-partition-event-retirement.md section 2.1 item 3.
#
# Copies every existing `events` row into `events_p` (routed by Postgres into
# the matching monthly/default partition migration 2 already created), then
# re-seeds `events_p_global_seq_seq` (migration 1's name for this sequence,
# pre-rename -- see migration 4) past the copied high-water mark (copied rows
# carry their original `global_seq` values verbatim; the sequence itself must
# be advanced manually since `INSERT ... SELECT` bypasses the column
# default).
#
# OQ1 (design doc section 7): single-transaction `INSERT ... SELECT` --
# flagged, not resolved, as to whether this is acceptable at production data
# volumes or needs a batched/online approach. Not measured as part of this
# implementation; revisit if real tenant row counts turn out large enough to
# make one long-held lock during this migration a problem.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY.
# Registered in Letflow.TenantProvisioning.tenant_scoped_migrations/0 --
# both halves are mandatory.
#
# `up/0`/`down/0`: a data-copy step, not a DDL command Ecto can auto-reverse.
defmodule Letflow.Repo.Migrations.BackfillEventsPartitioned do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      INSERT INTO "#{schema}".events_p
        (event_id, created_at, instance_id, event_type, payload, actor_id,
         sequence_number, idempotency_key, metadata, global_seq)
      SELECT event_id, created_at, instance_id, event_type, payload, actor_id,
             sequence_number, idempotency_key, metadata, global_seq
      FROM "#{schema}".events
      ORDER BY created_at
      """)

      # 3-arg setval/3 (not the 2-arg form): setval's 2-arg form requires its
      # value to be >= 1 (confirmed empirically: 22003 numeric_value_out_of_range
      # on an empty events table, where COALESCE(max(global_seq), 0) is 0).
      # The 3-arg is_called form correctly handles the empty-table case: value
      # defaults to 1 with is_called = false (so the NEXT nextval() call
      # returns 1, matching a fresh, never-used sequence's real starting
      # behavior), while a populated table gets the real max with is_called =
      # true (so the next nextval() call returns max+1, unchanged from the
      # 2-arg form's intended behavior for that case).
      execute("""
      SELECT setval(
        '"#{schema}".events_p_global_seq_seq',
        COALESCE((SELECT max(global_seq) FROM "#{schema}".events_p), 1),
        COALESCE((SELECT max(global_seq) FROM "#{schema}".events_p), 0) > 0
      )
      """)
    end
  end

  def down do
    if prefix() do
      schema = prefix()
      execute(~s{TRUNCATE "#{schema}".events_p})
    end
  end
end
