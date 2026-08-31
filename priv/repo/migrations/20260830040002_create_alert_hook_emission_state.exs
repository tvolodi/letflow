# Letflow.Repo.Migrations.CreateAlertHookEmissionState
#
# REQ-201. Implements lib/letflow/design/req201-alerting-hooks.md
# section 3.3 -- the `alert_hook_emission_state` table used for
# per-hook per-trigger deduplication across the Poller's own retry logic.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY.
# See 20260830020001_create_alert_trigger_state.exs header for the full
# placement rationale (PER-TENANT, not global; Decision B confirmed).
# Registered in Letflow.TenantProvisioning.tenant_scoped_migrations/0.
#
# COMPOSITE PRIMARY KEY: (hook_id, trigger_key) -- no surrogate `id` column.
# `create table(..., primary_key: false)` + individual `primary_key: true`
# add calls, following Letflow's established pattern for tables with
# non-surrogate PKs (see 20260830020001_create_alert_trigger_state.exs).
#
# `last_emitted_key` identifies the last event/subject that caused this hook
# to fire for this trigger, enabling deduplication. `updated_at` is managed
# explicitly on every upsert. No `timestamps/1` macro, no `inserted_at`.
defmodule Letflow.Repo.Migrations.CreateAlertHookEmissionState do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:alert_hook_emission_state, primary_key: false, prefix: prefix()) do
        add :hook_id, :string, primary_key: true, null: false
        add :trigger_key, :string, primary_key: true, null: false
        add :last_emitted_key, :string, null: false
        add :updated_at, :utc_datetime_usec, null: false
      end
    end
  end
end
