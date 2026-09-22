# Letflow.Repo.Migrations.SwapEventsArchivePartitioned
#
# REQ-376, migration 6c of 6 (design doc section 2.1 item 6). Atomically
# renames the old, unpartitioned `events_archive` aside (kept as a rollback
# safety net, not dropped -- OQ2, mirroring migration 4's identical rationale
# for `events`) and `events_archive_p` (now populated, migration 6b) into
# `events_archive`'s place.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY.
# Registered in Letflow.TenantProvisioning.tenant_scoped_migrations/0 --
# both halves are mandatory.
defmodule Letflow.Repo.Migrations.SwapEventsArchivePartitioned do
  use Ecto.Migration

  # Three index names collide the same way migration 4's four do (Postgres
  # index names are schema-unique, not table-unique, and renaming a TABLE
  # never renames its indexes): idx_archive_instance, idx_archive_type,
  # idx_archive_time.
  @index_renames [
    {"idx_archive_instance", "idx_archive_instance_p"},
    {"idx_archive_type", "idx_archive_type_p"},
    {"idx_archive_time", "idx_archive_time_p"}
  ]

  def up do
    if prefix() do
      schema = prefix()

      execute(
        ~s{ALTER TABLE "#{schema}".events_archive RENAME TO events_archive_pre_partition_20260922}
      )

      Enum.each(@index_renames, fn {old_name, _new_name} ->
        execute(
          ~s{ALTER INDEX "#{schema}"."#{old_name}" RENAME TO "#{old_name}_pre_partition_20260922"}
        )
      end)

      execute(~s{ALTER TABLE "#{schema}".events_archive_p RENAME TO events_archive})

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

      execute(~s{ALTER TABLE "#{schema}".events_archive RENAME TO events_archive_p})

      Enum.each(@index_renames, fn {old_name, _suffixed_name} ->
        execute(
          ~s{ALTER INDEX "#{schema}"."#{old_name}_pre_partition_20260922" RENAME TO "#{old_name}"}
        )
      end)

      execute(
        ~s{ALTER TABLE "#{schema}".events_archive_pre_partition_20260922 RENAME TO events_archive}
      )
    end
  end
end
