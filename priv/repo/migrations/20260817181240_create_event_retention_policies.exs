# Letflow.Repo.Migrations.CreateEventRetentionPolicies
#
# REQ-026. Implements lib/letflow/design/req026-event-read-archive-platform-sentinels.md
# §8 (the `event_retention_policies` table) -- resolves REQ-023 §9 OQ-1
# ("event_retention_policies has no owning requirement"), per ISS-0013/GH#69.
# Columns match R-Co's 003_event_archive.sql shape: id (uuid pk), event_type
# (unique), policy (default "keep_forever"), keep_days, keep_count,
# created_at, updated_at.
#
# GLOBAL -- no `if prefix() do` guard, matching
# 20260816090045_create_tenant_schemas.exs's and
# 20260817083801_create_solution_pack_installs.exs's structural shape
# exactly. NOT registered in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- that manifest is
# PER_TENANT-only; a GLOBAL migration runs unconditionally on a plain
# `mix ecto.migrate`, needing no replay-per-tenant mechanism. Design doc §6
# states the full classification rationale, including its own
# explicitly-flagged tension (§11 OQ-2) against the per-tenant
# `event_type_registry` -- a retention policy keyed only by `event_type`
# applies uniformly across every tenant's own independently-registered type
# of that name, with no guarantee those are the same kind of event.
#
# `policy` is plain :string plus a CHECK constraint (chk_retention_policy),
# not a native Postgres ENUM type -- matches R-Co's own plain-text-column-
# plus-CHECK shape and every other enum-shaped column already in this
# codebase (process_definitions.status, instance_projections.status).
#
# chk_keep_days / chk_keep_count (design doc §8.2 -- requirements.yaml names
# the three constraints by name, not by literal predicate; this is this
# design's own interpretation of their evident intent): a `policy = 'X'` row
# must have its own companion column set and positive, and every *other*
# policy value's row must have that same companion column NULL.
#
# `created_at`/`updated_at`, not Ecto's default `inserted_at`/`updated_at` --
# requirements.yaml:1147-1150 names these columns literally (R-Co's own
# names on 003_event_archive.sql's retention table), matching the same
# literal-column-name-preservation idiom process_definitions/
# instance_projections already established.
defmodule Letflow.Repo.Migrations.CreateEventRetentionPolicies do
  use Ecto.Migration

  def change do
    create table(:event_retention_policies, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :event_type, :string, null: false
      add :policy, :string, null: false, default: "keep_forever"
      add :keep_days, :integer
      add :keep_count, :integer

      timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
    end

    create unique_index(:event_retention_policies, [:event_type],
             name: :uq_retention_policy_event_type
           )

    create constraint(:event_retention_policies, :chk_retention_policy,
             check: "policy IN ('keep_forever', 'keep_days', 'keep_count')"
           )

    create constraint(:event_retention_policies, :chk_keep_days,
             check:
               "(policy = 'keep_days' AND keep_days IS NOT NULL AND keep_days > 0) OR (policy <> 'keep_days' AND keep_days IS NULL)"
           )

    create constraint(:event_retention_policies, :chk_keep_count,
             check:
               "(policy = 'keep_count' AND keep_count IS NOT NULL AND keep_count > 0) OR (policy <> 'keep_count' AND keep_count IS NULL)"
           )
  end
end
