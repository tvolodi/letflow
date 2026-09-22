# Letflow.Repo.Migrations.SwapEventsPartitioned
#
# REQ-376, migration 4 of 6. Implements
# lib/letflow/design/req376-partition-event-retirement.md section 2.1 item 4.
#
# Atomically renames the old, unpartitioned `events` aside (kept as a
# rollback safety net, not dropped -- OQ2, design doc section 7) and
# `events_p` (now populated, migration 3) into `events`' place. Both renames
# run inside the same migration, which Ecto already wraps in one transaction
# (the default; this migration does not disable_ddl_transaction).
#
# Also renames the two `global_seq` sequences to swap places, for the same
# reason: the CURRENT `events` table's `bigserial` column owns a
# Postgres-auto-named sequence called `events_global_seq_seq`; migration 1
# deliberately named the new table's equivalent sequence
# `events_p_global_seq_seq` to avoid colliding with it while both tables
# coexisted (see migration 1's own comment). Renaming a table does NOT rename
# its owned sequence, so without this step the OLD (now-aside) table would
# keep squatting on the `events_global_seq_seq` name forever. Order matters:
# the old sequence is renamed out of the way FIRST, freeing the name, before
# the new sequence claims it.
#
# OQ2 (design doc section 7): the renamed-aside original table
# (`events_pre_partition_20260922`) is never dropped by any migration in this
# set -- left as a deliberate rollback safety net with no stated expiry. A
# follow-up requirement or explicit ops decision should set a soak period and
# a cleanup migration; not decided here.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY.
# Registered in Letflow.TenantProvisioning.tenant_scoped_migrations/0 --
# both halves are mandatory.
defmodule Letflow.Repo.Migrations.SwapEventsPartitioned do
  use Ecto.Migration

  # Four index names collide the exact same way the sequence name does
  # (Postgres index names are schema-unique, not table-unique, and renaming
  # a TABLE never renames its indexes): uq_event_sequence, idx_events_global_seq,
  # idx_events_instance_time, idx_events_type. Same fix, same order -- rename
  # the old table's indexes out of the way first, freeing the names, before
  # the new (`_p`-suffixed, migration 1) indexes claim them.
  @index_renames [
    {"uq_event_sequence", "uq_event_sequence_p"},
    {"idx_events_global_seq", "idx_events_global_seq_p"},
    {"idx_events_instance_time", "idx_events_instance_time_p"},
    {"idx_events_type", "idx_events_type_p"}
  ]

  def up do
    if prefix() do
      schema = prefix()
      execute(~s{ALTER TABLE "#{schema}".events RENAME TO events_pre_partition_20260922})

      execute(
        ~s{ALTER SEQUENCE "#{schema}".events_global_seq_seq RENAME TO events_pre_partition_20260922_global_seq_seq}
      )

      Enum.each(@index_renames, fn {old_name, _new_name} ->
        execute(
          ~s{ALTER INDEX "#{schema}"."#{old_name}" RENAME TO "#{old_name}_pre_partition_20260922"}
        )
      end)

      execute(~s{ALTER TABLE "#{schema}".events_p RENAME TO events})

      execute(
        ~s{ALTER SEQUENCE "#{schema}".events_p_global_seq_seq RENAME TO events_global_seq_seq}
      )

      Enum.each(@index_renames, fn {old_name, suffixed_name} ->
        execute(~s{ALTER INDEX "#{schema}"."#{suffixed_name}" RENAME TO "#{old_name}"})
      end)
    end
  end

  def down do
    if prefix() do
      schema = prefix()

      Enum.each(@index_renames, fn {old_name, suffixed_name} ->
        execute(~s{ALTER INDEX "#{schema}"."#{old_name}" RENAME TO "#{suffixed_name}"})
      end)

      execute(
        ~s{ALTER SEQUENCE "#{schema}".events_global_seq_seq RENAME TO events_p_global_seq_seq}
      )

      execute(~s{ALTER TABLE "#{schema}".events RENAME TO events_p})

      Enum.each(@index_renames, fn {old_name, _suffixed_name} ->
        execute(
          ~s{ALTER INDEX "#{schema}"."#{old_name}_pre_partition_20260922" RENAME TO "#{old_name}"}
        )
      end)

      execute(
        ~s{ALTER SEQUENCE "#{schema}".events_pre_partition_20260922_global_seq_seq RENAME TO events_global_seq_seq}
      )

      execute(~s{ALTER TABLE "#{schema}".events_pre_partition_20260922 RENAME TO events})
    end
  end
end
