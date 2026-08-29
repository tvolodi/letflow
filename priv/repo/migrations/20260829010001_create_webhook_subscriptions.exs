# Letflow.Repo.Migrations.CreateWebhookSubscriptions
#
# REQ-181. Implements lib/letflow/design/req181-webhooks-core.md section 1
# (the `webhook_subscriptions` table) -- greenfield within S6: no prior
# webhook-subscription code exists to extend.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY. See
# lib/letflow/design/req022-tenant-schema-provisioning.md section 4 and
# 20260829000001_create_dlq_entries.exs's header for the full rationale
# (Decision B, docs/migration/decisions/0003-ecto-schema-strategy.md --
# schema-per-tenant with an intra-schema `tenant_id` column retained, not
# itself the isolation boundary). Registered in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both halves are
# mandatory per that module's own established discipline.
#
# `id` is the explicit `:binary_id` primary key (no default primary-key
# generator), same idiom as `dlq_entries`/`tasks`.
#
# `secret_hash` stores only the SHA-256 hex digest of a server-generated (or
# caller-supplied) plaintext secret -- the plaintext itself is never
# persisted anywhere (design doc section 0.1/2.2).
#
# `status` is a `:string` column (backing an `Ecto.Enum` at the schema layer)
# storing the two literal uppercase strings "ACTIVE"/"PAUSED" -- deliberately
# a DIFFERENT convention from `dlq_entries.status`'s lowercase values (design
# doc section 0.3).
#
# `event_types` is `{:array, :string}`, an open extensible set -- no closed
# vocabulary is named anywhere reachable from this requirement (design doc
# section 0.2).
#
# No `inserted_at`/`updated_at` pair from `timestamps/1` -- `created_at` is
# set explicitly by `Letflow.Webhooks.create/2`, and no acceptance criterion
# requires this module to populate an `updated_at` column (design doc
# section 1, open question 1).
#
# Indexes (design doc section 1), scoped to the same tenant schema as the
# table:
#   - `idx_webhook_subscriptions_status` on `status` -- backs a future status
#     filter, mirroring `dlq_entries`' own `idx_dlq_entries_status`
#     precedent.
#
# No index on `tenant_id` alone -- matches `dlq_entries`/`tasks`' own
# precedent (the Postgres schema, not this column, is the actual isolation
# boundary). No unique constraint on `target_url` -- the requirement does not
# state one subscription per URL.
defmodule Letflow.Repo.Migrations.CreateWebhookSubscriptions do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:webhook_subscriptions, primary_key: false, prefix: prefix()) do
        add :id, :binary_id, primary_key: true
        add :tenant_id, :binary_id, null: false

        add :target_url, :string, null: false
        add :secret_hash, :string, null: false
        add :description, :string
        add :event_types, {:array, :string}, null: false, default: []
        add :status, :string, null: false, default: "ACTIVE"
        add :consecutive_failures, :integer, null: false, default: 0
        add :last_attempt_at, :utc_datetime
        add :last_failure_at, :utc_datetime
        add :paused_at, :utc_datetime
        add :created_at, :utc_datetime, null: false
      end

      create index(:webhook_subscriptions, [:status],
               name: :idx_webhook_subscriptions_status,
               prefix: prefix()
             )
    end
  end
end
