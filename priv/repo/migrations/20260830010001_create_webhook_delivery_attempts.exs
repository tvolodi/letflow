# Letflow.Repo.Migrations.CreateWebhookDeliveryAttempts
#
# REQ-183. Implements lib/letflow/design/req183-webhook-delivery-dispatch.md
# section 1 (the `webhook_delivery_attempts` table) -- the dispatch-core half
# of the REQ-180 split (REQ-184 is the route-layer half, out of scope here).
# Does NOT touch `webhook_subscriptions` at all -- the `secret_ref`/
# `secret_key_id`/`secret_hash`-blanking migration is REQ-190's own
# (20260830000004_add_secret_ref_to_webhook_subscriptions.exs).
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
# generator), same idiom as every other tenant-scoped table in this codebase.
#
# `delivery_id` is a plain column, not the primary key -- a "delivery" is
# modeled as a group of attempt rows sharing one `delivery_id` (design doc
# section 1.1); there is no separate `webhook_deliveries` header table.
#
# `subscription_id` carries NO DB-level `references/2` FK constraint --
# matches `dlq_entries.instance_id`'s own "no FK reference" precedent: an
# attempt row must be able to outlive a deleted subscription (REQ-181's
# `delete/2` is a hard delete).
#
# `status` is a `:string` column (backing an `Ecto.Enum` at the schema layer)
# storing the two literal uppercase strings "SUCCESS"/"FAILED" -- matching
# `webhook_subscriptions.status`'s own uppercase convention (this is the
# sibling table in the same webhook feature), not `dlq_entries`' lowercase
# convention (design doc section 1).
#
# `attempted_at` is an explicit `:utc_datetime` column, not `timestamps/1` --
# an attempt row is immutable once written, matching `dlq_entries`' own
# explicit-column precedent.
#
# Indexes (design doc section 1), scoped to the same tenant schema as the
# table:
#   - `idx_webhook_delivery_attempts_delivery` on `(delivery_id,
#     attempt_count)` -- backs REQ-184's future "attempts for one delivery, in
#     order" query and this design's own exhaustion check.
#   - `idx_webhook_delivery_attempts_subscription` on `subscription_id` --
#     backs REQ-184's future "deliveries for this subscription" query.
#
# No index on `tenant_id` alone -- matches every sibling table's precedent
# (the Postgres schema is the isolation boundary).
defmodule Letflow.Repo.Migrations.CreateWebhookDeliveryAttempts do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:webhook_delivery_attempts, primary_key: false, prefix: prefix()) do
        add :id, :binary_id, primary_key: true
        add :tenant_id, :binary_id, null: false

        add :delivery_id, :binary_id, null: false
        add :subscription_id, :binary_id, null: false
        add :event_type, :string, null: false
        add :status, :string, null: false
        add :http_status_code, :integer
        add :attempted_at, :utc_datetime, null: false
        add :attempt_count, :integer, null: false
        add :max_attempts, :integer, null: false
        add :last_error, :text
      end

      create index(:webhook_delivery_attempts, [:delivery_id, :attempt_count],
               name: :idx_webhook_delivery_attempts_delivery,
               prefix: prefix()
             )

      create index(:webhook_delivery_attempts, [:subscription_id],
               name: :idx_webhook_delivery_attempts_subscription,
               prefix: prefix()
             )
    end
  end
end
