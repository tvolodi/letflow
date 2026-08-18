# Letflow.Repo.Migrations.CreatePromotionAssertionRuns
#
# REQ-040. Implements lib/letflow/design/req040-promotion-assertion-rerun.md §4 (the
# `promotion_assertion_runs` table) -- ports R-Co's `src/definition/assertion_rerun.zig`
# (PRM-06/07, `src/design/prm-batch1-promotion-assertion-rerun.md` "1.
# promotion_assertion_runs table schema") per this table's own idempotent
# assertion-rerun contract. See `Letflow.Definitions.PromotionAssertionRun`'s moduledoc
# and `Letflow.Definitions.apply_promotion_assertion_rerun/6` for the full picture; this
# migration builds schema only.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY. See
# lib/letflow/design/req022-tenant-schema-provisioning.md section 4 and
# 20260816200001_create_promotion_reviews.exs's header for the full rationale.
# Registered in Letflow.TenantProvisioning.@tenant_scoped_migration_manifest -- both
# halves are mandatory: a guarded-but-unregistered migration is inert forever, a
# registered-but-unguarded one corrupts `public` on every plain `mix ecto.migrate` run.
#
# MUST SORT AFTER 20260816200001_create_promotion_reviews.exs -- it carries a real FK to
# `promotion_reviews` (both tables live in the same per-tenant schema, unlike `tenant_id`
# below, which cannot be a real FK -- `tenants`/`users` live in the public schema).
#
# `status` is plain :string plus a CHECK constraint (chk_promotion_assertion_run_status),
# a deliberate, flagged divergence from `promotion_reviews`' own migration (which relies
# on Ecto.Enum-only validation, no CHECK) -- design §4 justifies this: prm-batch1's own
# schema explicitly specifies a CHECK for THIS table, and this column directly feeds a
# downstream promotion-gate decision (assertions_failed == 0, NOT status == 'passed' --
# see the schema module's moduledoc) where a malformed value is a correctness risk, not
# just a display concern. Matches `event_retention_policies`' own plain-text-plus-CHECK
# shape (20260817181240_create_event_retention_policies.exs).
#
# `failing_assertion_ids` is a native Postgres TEXT[] ({:array, :string}), not JSONB --
# design §4: a flat, homogeneous string list has no need for JSONB's generality, and
# {:array, :string} enables e.g. `WHERE 'x' = ANY(failing_assertion_ids)` natively. A
# deliberate divergence from prm-batch1's own JSONB choice (made for Zig's own driver
# constraints, not a Postgres requirement).
#
# `started_at`'s default uses the same `(now() AT TIME ZONE 'utc')` fragment
# 20260816193002_create_instance_definition_snapshots.exs and REQ-023's migrations
# already adopted -- the same implicit-local-timezone-cast mitigation, not `NOW()`
# verbatim.
#
# `review_id`'s FK carries `on_delete: :nothing` (Postgres default NO ACTION), matching
# `instance_definition_snapshots.definition_id`'s own precedent -- no established need
# for ON DELETE CASCADE here.
defmodule Letflow.Repo.Migrations.CreatePromotionAssertionRuns do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:promotion_assertion_runs, primary_key: false, prefix: prefix()) do
        add :id, :binary_id, primary_key: true
        add :tenant_id, :binary_id, null: false

        add :review_id,
            references(:promotion_reviews,
              column: :id,
              type: :binary_id,
              on_delete: :nothing
            ),
            null: false

        add :idempotency_key, :string, null: false
        add :plan_digest, :string, null: false
        add :status, :string, null: false, default: "running"
        add :sandbox_id, :binary_id
        add :assertions_total, :integer, null: false, default: 0
        add :assertions_passed, :integer, null: false, default: 0
        add :assertions_failed, :integer, null: false, default: 0
        add :failing_assertion_ids, {:array, :string}, null: false, default: []
        add :teardown_error, :text

        add :started_at, :utc_datetime_usec,
          null: false,
          default: fragment("(now() AT TIME ZONE 'utc')")

        add :completed_at, :utc_datetime_usec

        timestamps(type: :utc_datetime_usec)
      end

      # design §4, §7.1 -- AC1's idempotency anchor: at most one row per
      # (tenant_id, idempotency_key), enforced via `Repo.insert(..., on_conflict:
      # :nothing, conflict_target: [:tenant_id, :idempotency_key])`.
      create unique_index(:promotion_assertion_runs, [:tenant_id, :idempotency_key],
               name: :uq_promotion_assertion_runs_idempotency,
               prefix: prefix()
             )

      # Reverse-FK-lookup index, matching idx_snap_definition's own precedent --
      # Postgres does not auto-index the referencing side of a foreign key.
      create index(:promotion_assertion_runs, [:review_id],
               name: :idx_promotion_assertion_runs_review,
               prefix: prefix()
             )

      create constraint(:promotion_assertion_runs, :chk_promotion_assertion_run_status,
               check: "status IN ('running', 'passed', 'failed', 'teardown_failed')",
               prefix: prefix()
             )
    end
  end
end
