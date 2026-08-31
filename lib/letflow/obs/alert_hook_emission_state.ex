defmodule Letflow.Obs.AlertHookEmissionState do
  @moduledoc """
  Ecto schema for the per-tenant `alert_hook_emission_state` table. See
  `lib/letflow/design/req201-alerting-hooks.md` §3.3. Ordinary
  `Ecto.Schema`, no process.

  Composite primary key: `(hook_id, trigger_key)`. `updated_at` is managed
  explicitly; no `timestamps/1` macro.
  """

  use Ecto.Schema

  @primary_key false
  schema "alert_hook_emission_state" do
    field(:hook_id, :string, primary_key: true)
    field(:trigger_key, :string, primary_key: true)
    field(:last_emitted_key, :string)
    field(:updated_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          hook_id: String.t(),
          trigger_key: String.t(),
          last_emitted_key: String.t(),
          updated_at: DateTime.t()
        }
end
