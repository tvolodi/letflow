# Letflow.Repo.Migrations.CreateAlertTriggerState
#
# REQ-201. Implements lib/letflow/design/req201-alerting-hooks.md
# section 3.2 -- the `alert_trigger_state` table that makes alert firing
# EDGE-TRIGGERED (fires once on crossing, not on every above-threshold
# sample).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY.
# See lib/letflow/design/req022-tenant-schema-provisioning.md section 4 and
# 20260829000001_create_dlq_entries.exs's header for the full rationale
# (Decision B, docs/migration/decisions/0003-ecto-schema-strategy.md --
# schema-per-tenant). Registered in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- mandatory per that
# module's own established discipline.
#
# PLACEMENT DECISION (PER-TENANT, not global): R-Co places these tables in
# public schema (migrations/022_obs06_alerting_state.sql header: "scope:
# public ... global-registry table") because its thresholds are platform-wide.
# Letflow's monitored subjects are structurally different: dlq_entries is
# per-tenant (Decision B), instance_projections is per-tenant, and
# webhook_subscriptions is per-tenant. A global placement would diverge from
# 0003 Decision B without a grounded reason -- per-tenant is correct. The one
# global figure (scheduler_lag_ms) is passed through the per-tenant detection
# loop without difficulty (design §3.1).
#
# `trigger_key` is the PRIMARY KEY (string, no `id` column). No `timestamps/1`
# macro -- `updated_at` is managed explicitly on every upsert; no `inserted_at`
# because this table is write-once-per-key at first crossing and then
# continually updated in place. Lookups are always by `trigger_key` so no
# additional indexes beyond the primary key are needed.
defmodule Letflow.Repo.Migrations.CreateAlertTriggerState do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:alert_trigger_state, primary_key: false, prefix: prefix()) do
        add :trigger_key, :string, primary_key: true, null: false
        add :is_armed, :boolean, null: false, default: true
        add :last_sample_value, :bigint, null: false, default: 0
        add :last_fired_at, :utc_datetime_usec, null: true
        add :last_correlation_id, :string, null: true
        add :updated_at, :utc_datetime_usec, null: false
      end
    end
  end
end
