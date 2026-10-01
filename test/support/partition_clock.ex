defmodule Letflow.Test.PartitionClock do
  @moduledoc """
  Pure date arithmetic for tests that need a month partition which
  `Letflow.EventStore.PartitionMaintenance` considers eligible for retirement.

  Production rule: month `M` is eligible iff
  `today >= first_day_of_next_month(M) + min_partition_age_days`.

  The latest eligible month is derived as
  `shift_months(month_of(today - N days), -1)`: with `d = today - N`, a
  first-of-month date `F` satisfies `F <= d` iff `month(F) <= month(d)`, so
  setting `first_of_next(M)` to the first of `d`'s month yields the latest `M`.
  "Last calendar month" is NOT always eligible: with `N = 1` it is ineligible
  on the 1st of every month (ISS-0937).

  The module has no process and no I/O and never reads the clock; the caller
  injects `today`.
  """

  @doc """
  The latest `{year, month}` whose partition is eligible for retirement on
  `today`, given `min_partition_age_days`.
  """
  @spec eligible_past_month(Date.t(), pos_integer()) :: {integer(), 1..12}
  def eligible_past_month(%Date{} = today, min_partition_age_days)
      when is_integer(min_partition_age_days) and min_partition_age_days >= 1 do
    d = Date.add(today, -min_partition_age_days)
    shift_months({d.year, d.month}, -1)
  end

  @doc "Shifts a `{year, month}` by `offset` months (may be negative)."
  @spec shift_months({integer(), 1..12}, integer()) :: {integer(), 1..12}
  def shift_months({year, month}, offset) do
    total = year * 12 + (month - 1) + offset
    {div(total, 12), rem(total, 12) + 1}
  end
end
