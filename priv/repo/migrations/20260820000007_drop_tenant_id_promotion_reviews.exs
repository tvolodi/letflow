# Letflow.Repo.Migrations.DropTenantIdPromotionReviews
#
# Decision 0006 D2, REQ-064 -- drops `tenant_id` from `promotion_reviews` AND
# simplifies its two composite indexes, both of which currently lead with
# `tenant_id`. See lib/letflow/design/req064-drop-tenant-id.md section 2.3 for
# the exact before/after this migration implements verbatim.
#
# Index NAMES are kept identical (`uq_promotion_review_active_digest`,
# `idx_promotion_review_rollback_lookup`) -- only the column list changes (the
# leading `tenant_id` column drops out), and for both indexes the partial
# `WHERE` predicates are unchanged. Constraint matching is by index NAME, so
# `Letflow.Definitions.PromotionReview.insert_changeset/2`'s
# `unique_constraint/2` call is updated in lockstep (same commit) to match --
# see that module's own diff.
#
# Idempotency-anchor contract restated (condensed from
# 20260816200001_create_promotion_reviews.exs's own header): PRM-03's
# uniqueness guarantee -- at most one row per plan_digest may be
# pending_review/approved at a time -- is unchanged in MEANING by this
# migration, only in SHAPE. Before: at most one row per (tenant_id,
# plan_digest) pair. After: at most one row per plan_digest alone. This is not
# a widening of the guarantee -- inside one tenant's Postgres schema,
# tenant_id had at most one distinct value already (0006 §R3), so
# (tenant_id, plan_digest) and (plan_digest) alone were already equivalent
# constraints within any single schema; this migration only removes the
# now-redundant leading column from the index shape, it does not change which
# rows the constraint allows to coexist.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY.
# Registered in Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both
# halves are mandatory.
defmodule Letflow.Repo.Migrations.DropTenantIdPromotionReviews do
  use Ecto.Migration

  def change do
    if prefix() do
      drop index(:promotion_reviews, [:tenant_id, :plan_digest],
             name: :uq_promotion_review_active_digest,
             prefix: prefix()
           )

      drop index(:promotion_reviews, [:tenant_id, :status],
             name: :idx_promotion_review_rollback_lookup,
             prefix: prefix()
           )

      alter table(:promotion_reviews, prefix: prefix()) do
        remove :tenant_id, :binary_id
      end

      create unique_index(:promotion_reviews, [:plan_digest],
               name: :uq_promotion_review_active_digest,
               where: "status IN ('pending_review', 'approved')",
               prefix: prefix()
             )

      create index(:promotion_reviews, [:status],
               name: :idx_promotion_review_rollback_lookup,
               where: "status IN ('applied', 'superseded')",
               prefix: prefix()
             )
    end
  end
end
