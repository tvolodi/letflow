# Letflow.Repo.Migrations.CreatePromotionReviews
#
# REQ-035. Implements
# lib/letflow/design/req035-promotion-reviews-schema.md section 3 (the
# `promotion_reviews` table) and section 3.2 (its two indexes). This table is
# PRM-04's approval-gate row for a pending/applied definition promotion — see
# Letflow.Definitions.PromotionReview's moduledoc for the full picture; this
# migration builds schema only (design section 1's scope boundary).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY. See
# lib/letflow/design/req022-tenant-schema-provisioning.md section 4 and
# 20260816193001_create_process_definitions.exs's header for the full rationale.
# Registered in Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both
# halves are mandatory: a guarded-but-unregistered migration is inert forever, a
# registered-but-unguarded one corrupts `public` on every plain `mix ecto.migrate`
# run.
#
# PER_TENANT classification is NOT independently confirmed against an explicit
# R-Co source the way `events`/`events_archive`'s classification is confirmed
# against 1147_par01_events_partitioning.sql's own comment (cited in
# docs/migration/decisions/0003-ecto-schema-strategy.md). This migration is built
# PER_TENANT because REQ-035 acceptance criterion 1 mandates it -- design section 2
# and section 9 OQ-2 flag this explicitly for REVIEWER re-confirmation rather than
# treating it as settled fact.
#
# `status` is an Ecto.Enum over exactly 6 bare-atom values (:pending_review,
# :approved, :rejected, :applied, :failed, :superseded), which dump lowercase via
# to_string/1 (deps/ecto/lib/ecto/enum.ex:81-83) -- already lowercase snake_case,
# so unlike process_definitions.status there is no case-mismatch risk between the
# dumped value and either index predicate below (design section 3, `status` row).
#
# `plan_digest`'s 64-char lowercase-hex shape and `def_type`'s open-ended-text
# choice are both enforced/left open at the changeset layer, not here -- see
# Letflow.Definitions.PromotionReview.insert_changeset/2 and design section 3's
# `plan_digest`/`def_type` rows for the full rationale (no CHECK constraint on
# either column).
#
# `row_version` defaults to 1 and is NOT wired through Ecto.Schema.optimistic_lock/
# 2,3 -- it is a plain integer column, manually read and compared by REQ-037's raw
# `UPDATE ... WHERE row_version = $expected` transitions. See the schema module's
# moduledoc (design section 7.1) for the full contract.
#
# NO foreign keys: `tenant_id`, `requested_by`, `approved_by` and `superseded_by`
# are all bare UUIDs -- `users`/`tenants` live in the public/default schema while
# this table lives in a tenant schema (matching every other tenant-scoped table's
# actor-column convention in this codebase), and `superseded_by`'s exact target row
# is not specified by REQ-035's own text (design section 3.1, section 9 OQ-3), so no
# self-referential FK is added on a guessed target.
defmodule Letflow.Repo.Migrations.CreatePromotionReviews do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:promotion_reviews, primary_key: false, prefix: prefix()) do
        add :id, :binary_id, primary_key: true
        add :tenant_id, :binary_id, null: false
        add :plan_digest, :string, null: false
        add :def_type, :string, null: false, default: "process"
        add :def_id, :string, null: false
        add :serialised_plan, :text, null: false
        add :status, :string, null: false, default: "pending_review"
        add :requested_by, :binary_id, null: false
        add :approved_by, :binary_id
        add :approved_at, :utc_datetime_usec
        add :superseded_by, :binary_id
        add :row_version, :integer, null: false, default: 1

        timestamps(type: :utc_datetime_usec)
      end

      # REQ-035 acceptance criterion 2. PRM-03's idempotency anchor: at most one row
      # with the same (tenant_id, plan_digest) may be pending_review or approved at
      # a time. unique_index/3 is index/3 with [unique: true] prepended
      # (deps/ecto_sql/lib/ecto/migration.ex:1048-1052), so :where/:name/:prefix are
      # all available on a partial UNIQUE index; the predicate string is emitted
      # verbatim after " WHERE "
      # (deps/ecto_sql/lib/ecto/adapters/postgres/connection.ex:1344).
      create unique_index(:promotion_reviews, [:tenant_id, :plan_digest],
               name: :uq_promotion_review_active_digest,
               where: "status IN ('pending_review', 'approved')",
               prefix: prefix()
             )

      # Named in REQ-035's own description (not itself a numbered acceptance
      # criterion): serves PRM-08 rollback's superseded-lookup queries. Future
      # consumer: REQ-038's rollback_definition_version/4. Built here because
      # REQ-035 is this table's only migration-owning requirement.
      create index(:promotion_reviews, [:tenant_id, :status],
               name: :idx_promotion_review_rollback_lookup,
               where: "status IN ('applied', 'superseded')",
               prefix: prefix()
             )
    end
  end
end
