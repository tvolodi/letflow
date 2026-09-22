# Letflow.Repo.Migrations.CreateEventsPInitialPartitions
#
# REQ-376, migration 2 of 6. Implements
# lib/letflow/design/req376-partition-event-retirement.md section 2.1 item 2.
#
# Computes the partition window at migration-run time from the tenant
# schema's own existing `events` table (min/max created_at), then creates one
# monthly partition per calendar month in [min_month, max(now, max_month) +
# months_ahead], plus exactly one DEFAULT partition (`events_default`) as a
# catch-all for any `created_at` this window didn't anticipate.
#
# `up/0`/`down/0` (not `change/0`): the set of partitions created is
# data-dependent (computed from `events`' current row range), not a fixed DDL
# Ecto can auto-reverse -- mirrors 20260921000002_add_kind_to_tenant_role.exs's
# own up/down shape for the same reason (a data-driven step alongside DDL).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY.
# Registered in Letflow.TenantProvisioning.tenant_scoped_migrations/0 --
# both halves are mandatory.
defmodule Letflow.Repo.Migrations.CreateEventsPInitialPartitions do
  use Ecto.Migration

  # Same default as Letflow.EventStore.PartitionMaintenance.months_ahead_default/0
  # -- this migration's one-time window uses the same lookahead the ongoing
  # sweep maintains afterward, so there is no gap between "what this
  # migration created" and "what the sweep expects to already exist" on its
  # very first run.
  @months_ahead 2

  def up do
    if prefix() do
      schema = prefix()

      %Postgrex.Result{rows: rows} =
        repo().query!(~s{SELECT min(created_at), max(created_at) FROM "#{schema}".events})

      [[min_created_at, max_created_at]] = rows

      today = Date.utc_today()
      current_month = {today.year, today.month}

      data_min_month =
        case min_created_at do
          nil -> current_month
          %NaiveDateTime{} = ts -> {ts.year, ts.month}
        end

      data_max_month =
        case max_created_at do
          nil -> current_month
          %NaiveDateTime{} = ts -> {ts.year, ts.month}
        end

      lookahead_month = shift_months(current_month, @months_ahead)

      target_max_month = latest_month([data_max_month, lookahead_month])

      months_window(data_min_month, target_max_month)
      |> Enum.each(fn {year, month} -> create_month_partition!(schema, year, month) end)

      execute(
        ~s{CREATE TABLE "#{schema}".events_default PARTITION OF "#{schema}".events_p DEFAULT}
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
          WHERE n.nspname = $1 AND p.relname = 'events_p'
          """,
          [schema]
        )

      Enum.each(rows, fn [child_name] ->
        execute(~s{DROP TABLE IF EXISTS "#{schema}"."#{child_name}"})
      end)
    end
  end

  # Inclusive [from_month, to_month] range, expressed as a plain integer
  # index range (year*12 + (month-1)) so it is monotonic and unambiguous
  # regardless of how far apart the two months are.
  defp months_window(from_month, to_month) do
    month_index(from_month)..month_index(to_month)
    |> Enum.map(&month_from_index/1)
  end

  defp month_index({year, month}), do: year * 12 + (month - 1)
  defp month_from_index(idx), do: {div(idx, 12), rem(idx, 12) + 1}

  defp latest_month(months), do: Enum.max_by(months, &month_index/1)

  defp shift_months({year, month}, offset) do
    total = year * 12 + (month - 1) + offset
    {div(total, 12), rem(total, 12) + 1}
  end

  defp create_month_partition!(schema, year, month) do
    partition_name = "events_y#{year}m#{pad2(month)}"
    {from_bound, to_bound} = month_bounds(year, month)

    execute(
      ~s{CREATE TABLE "#{schema}"."#{partition_name}" PARTITION OF "#{schema}".events_p FOR VALUES FROM ('#{from_bound}') TO ('#{to_bound}')}
    )
  end

  defp month_bounds(year, month) do
    from = "#{year}-#{pad2(month)}-01"
    {next_year, next_month} = shift_months({year, month}, 1)
    to = "#{next_year}-#{pad2(next_month)}-01"
    {from, to}
  end

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
