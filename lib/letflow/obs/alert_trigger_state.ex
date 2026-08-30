defmodule Letflow.Obs.AlertTriggerState do
  @moduledoc """
  Ecto schema for the per-tenant `alert_trigger_state` table. See
  `lib/letflow/design/req201-alerting-hooks.md` §3.2. Ordinary
  `Ecto.Schema`, no process — matches every other tenant-scoped table in
  this codebase.

  `trigger_key` is the string primary key (no surrogate `id`). `updated_at`
  is managed explicitly by upsert callers; there is no `timestamps/1` macro.
  Every tenant schema has its own copy of this table (per-tenant placement —
  see migration header for rationale).
  """

  use Ecto.Schema

  @primary_key {:trigger_key, :string, autogenerate: false}
  schema "alert_trigger_state" do
    field(:is_armed, :boolean, default: true)
    field(:last_sample_value, :integer, default: 0)
    field(:last_fired_at, :utc_datetime_usec)
    field(:last_correlation_id, :string)
    field(:updated_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          trigger_key: String.t(),
          is_armed: boolean(),
          last_sample_value: non_neg_integer(),
          last_fired_at: DateTime.t() | nil,
          last_correlation_id: String.t() | nil,
          updated_at: DateTime.t()
        }
end
