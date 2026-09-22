# Letflow.Repo.Migrations.CreateEventsArchivePInitialPartitions
#
# REQ-376, migration 6a of 6 (design doc section 2.1 item 6). Creates ONE
# dedicated month partition on `events_archive_p` for every calendar month
# that already has historical rows in `events_archive` at migration time --
# NOT a forward-looking window like migration 2 does for `events`. Design
# section 3.2 (revised): no ongoing sweep pre-creates a dedicated
# `events_archive` month partition ahead of retirement -- `retire_month/3`'s
# own ATTACH step (Letflow.EventStore.PartitionMaintenance) is what creates
# each month's dedicated `events_archive` partition, exactly once, at the
# moment that month retires. Also creates exactly one DEFAULT partition
# (`events_archive_default`) -- the destination `archive/1`'s ordinary
# row-level moves land in for any month that has not yet been whole-month
# retired.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY.
# Registered in Letflow.TenantProvisioning.tenant_scoped_migrations/0 --
# both halves are mandatory.
#
# `up/0`/`down/0`: data-dependent partition set, not a fixed DDL Ecto can
# auto-reverse.
defmodule Letflow.Repo.Migrations.CreateEventsArchivePInitialPartitions do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      %Postgrex.Result{rows: rows} =
        repo().query!("""
        SELECT DISTINCT date_trunc('month', created_at)::date
        FROM "#{schema}".events_archive
        ORDER BY 1
        """)

      Enum.each(rows, fn [month_start] ->
        create_month_partition!(schema, month_start.year, month_start.month)
      end)

      execute(
        ~s{CREATE TABLE "#{schema}".events_archive_default PARTITION OF "#{schema}".events_archive_p DEFAULT}
      )
    end
  end

  def down do
    if prefix() do
      schema = prefix()

      %Postgrex.Result{rows: rows} =
        repo().query!(
          """
          SELECT c.relname
          FROM pg_inherits i
          JOIN pg_class c ON c.oid = i.inhrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
          JOIN pg_class p ON p.oid = i.inhparent
          WHERE n.nspname = $1 AND p.relname = 'events_archive_p'
          """,
          [schema]
        )

      Enum.each(rows, fn [child_name] ->
        execute(~s{DROP TABLE IF EXISTS "#{schema}"."#{child_name}"})
      end)
    end
  end

  # NOTE naming divergence from events_p's own initial-partitions migration:
  # these are BRAND NEW dedicated events_archive partitions for historical
  # months that predate this requirement (never an events-side partition),
  # so they use the "events_archive_y..." convention (design doc section
  # 2.2), NOT "events_y..." -- that latter name is reserved for a physical
  # partition table that started life attached to `events` and is later
  # DETACHed/ATTACHed onto `events_archive` by retire_month/3 without ever
  # being renamed (same OID, same name, throughout). Using "events_y..."
  # here would collide with that name the first time a not-yet-existing
  # month later goes through retire_month/3.
  defp create_month_partition!(schema, year, month) do
    partition_name = "events_archive_y#{year}m#{pad2(month)}"
    {from_bound, to_bound} = month_bounds(year, month)

    execute(
      ~s{CREATE TABLE "#{schema}"."#{partition_name}" PARTITION OF "#{schema}".events_archive_p FOR VALUES FROM ('#{from_bound}') TO ('#{to_bound}')}
    )
  end

  defp month_bounds(year, month) do
    from = "#{year}-#{pad2(month)}-01"
    {next_year, next_month} = shift_months({year, month}, 1)
    to = "#{next_year}-#{pad2(next_month)}-01"
    {from, to}
  end

  defp shift_months({year, month}, offset) do
    total = year * 12 + (month - 1) + offset
    {div(total, 12), rem(total, 12) + 1}
  end

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
