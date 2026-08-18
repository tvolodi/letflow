# Letflow.Repo.Migrations.DropTenantIdPromotionAssertionRuns
#
# Decision 0006 D2, REQ-064 -- drops `tenant_id` from `promotion_assertion_runs`
# AND simplifies its idempotency unique index, which currently leads with
# `tenant_id`. See lib/letflow/design/req064-drop-tenant-id.md section 2.3 for
# the exact before/after this migration implements verbatim.
#
# Index NAME is kept identical (`uq_promotion_assertion_runs_idempotency`) --
# only the column list changes. `idx_promotion_assertion_runs_review` (on
# `review_id` alone) and `chk_promotion_assertion_run_status` are both
# untouched -- neither references `tenant_id`.
#
# Idempotency-anchor contract restated (condensed from this table's own
# original migration header and from
# `Letflow.Definitions.claim_or_fetch_assertion_run/5`'s real call site,
# `lib/letflow/definitions.ex`): this table's idempotency-anchor contract --
# one row per idempotency key, checked via `Repo.insert(changeset,
# on_conflict: :nothing, conflict_target: [...])` -- is unchanged in MEANING
# by this migration, only in SHAPE. Before: at most one row per
# `(tenant_id, idempotency_key)` pair, checked via `conflict_target:
# [:tenant_id, :idempotency_key]`. After: at most one row per
# `idempotency_key` alone, checked via `conflict_target: [:idempotency_key]`.
# This is not a widening of the uniqueness guarantee -- inside one tenant's
# Postgres schema, `tenant_id` had at most one distinct value already (0006
# §R3, restated from the `events_archive`/`process_definitions` migration
# headers this table's own header already cites), so `(tenant_id,
# idempotency_key)` and `(idempotency_key)` alone were already equivalent
# constraints within any single schema -- this migration only removes the
# now-redundant leading column from the index/conflict-target shape, it does
# not change which rows the constraint allows to coexist.
#
# `Repo.get_by(PromotionAssertionRun, [idempotency_key: idempotency_key],
# prefix: prefix)` in `fetch_existing_assertion_run/2`
# (`lib/letflow/definitions.ex`) is a plain WHERE, not an index/conflict-target
# reference -- it compiles and runs correctly against the schema struct with
# `tenant_id` removed, independent of this migration's own index change; see
# that function's own diff.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY.
# Registered in Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both
# halves are mandatory. Sorts after
# 20260820000007_drop_tenant_id_promotion_reviews.exs, matching the FK
# ordering the original create migrations established
# (promotion_assertion_runs.review_id FKs onto promotion_reviews.id).
defmodule Letflow.Repo.Migrations.DropTenantIdPromotionAssertionRuns do
  use Ecto.Migration

  def change do
    if prefix() do
      drop index(:promotion_assertion_runs, [:tenant_id, :idempotency_key],
             name: :uq_promotion_assertion_runs_idempotency,
             prefix: prefix()
           )

      alter table(:promotion_assertion_runs, prefix: prefix()) do
        remove :tenant_id, :binary_id
      end

      create unique_index(:promotion_assertion_runs, [:idempotency_key],
               name: :uq_promotion_assertion_runs_idempotency,
               prefix: prefix()
             )
    end
  end
end
