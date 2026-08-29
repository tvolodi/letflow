# Letflow.Repo.Migrations.CreateTimers
#
# REQ-186 (SCH-01/02/05/06). Implements
# lib/letflow/design/req186-scheduler-core.md section 1 (the `timers`
# table) -- the schema half of the scheduler-firing architecture decided in
# lib/letflow/design/req185-scheduler-firing-architecture.md. See
# Letflow.Scheduler / Letflow.Scheduler.Timer / Letflow.Scheduler.Poller for
# the runtime this table backs; this migration builds schema only.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY
# (Decision 0003 Decision B: schema-per-tenant is the isolation boundary,
# `tenant_id` is retained as an intra-schema column, not itself the
# boundary). See 20260829000001_create_dlq_entries.exs's own header for the
# full rationale -- identical discipline, same table shape family
# (dlq_entries/tasks/timers). Registered in
# Letflow.TenantProvisioning.@tenant_scoped_migration_manifest -- both
# halves are mandatory: a guarded-but-unregistered migration is inert
# forever, a registered-but-unguarded one corrupts `public` on a plain
# `mix ecto.migrate` run.
#
# `id`/`instance_id`/`token_id` carry no FK (design §1.1) -- same rationale
# as `dlq_entries.instance_id`: a timer row may need to outlive assumptions
# about the referenced row's own lifecycle, and no acceptance criterion
# requires referential integrity here.
#
# `timer_type` is plain :string, NOT Ecto.Enum (design §1.1) -- mirrors
# `dlq_entries.entry_type`'s own "extensible, no DB enum" precedent;
# application-layer `validate_inclusion/3` in `Letflow.Scheduler.Timer`'s
# own `arm_changeset/2` is the only guard on this column.
#
# `fire_at`/`fired_at`/`cancelled_at`/`failed_at`/`created_at` are all
# `:utc_datetime_usec` (design §1.1) -- `fire_at` is the poller's own hot
# sort key (idx_timers_pending_fire_at below), so microsecond precision
# avoids two timers created in the same wall-clock second racing
# ambiguously in `ORDER BY fire_at`.
#
# Two DB-level CHECK constraints, `create constraint/3` (the same idiom
# 20260818090001_create_promotion_assertion_runs.exs's own
# `chk_promotion_assertion_run_status` already establishes -- Ecto's
# `constraint/3` builder generates both the forward `ADD CONSTRAINT` and the
# reverse `DROP CONSTRAINT` for a plain `change/0`, no separate `up/0`/
# `down/0` split needed):
#
#   * `chk_timers_status` (design §1.3, acceptance criterion 2) -- `status`
#     admits exactly `pending`/`fired`/`cancelled`/`failed`. Letflow ships
#     the corrected 4-value domain from day one; R-Co's own narrower
#     historical domain is not replayed as an intermediate step.
#   * `chk_timers_recurrence_shape` (design §1.4, acceptance criterion 3) --
#     the recurrence quartet (`repeat_expression`/`repeat_interval_us`/
#     `repeat_total`/`fired_count`) is all-or-nothing, `repeat_total` alone
#     may stay NULL (an unbounded series) while the other three are
#     required together, and when `repeat_total` is present
#     `fired_count <= repeat_total`.
#
# `idx_timers_pending_fire_at` -- partial index on `(fire_at)` WHERE
# `status = 'pending'` (design §1.2) -- the poller's one hot query
# (Letflow.Scheduler.claim_due_timer_ids/2). Ported unmodified from R-Co.
# No index on `tenant_id` alone (the Postgres schema, not this column, is
# the actual isolation boundary -- same rationale as `dlq_entries`). No
# index on `instance_id` -- no query in this design's own scope filters by
# it (REQ-187's future cancellation wiring may need one; not added
# speculatively here).
#
# No `inserted_at`/`updated_at` pair from `timestamps/1` -- same rationale
# as `dlq_entries`: this table's contract names specific, narrow timestamp
# columns (`fired_at`/`cancelled_at`/`failed_at`/`created_at`), not a
# generic last-modified column nothing in the acceptance criteria requires.
defmodule Letflow.Repo.Migrations.CreateTimers do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:timers, primary_key: false, prefix: prefix()) do
        add :id, :binary_id, primary_key: true
        add :tenant_id, :binary_id, null: false

        add :instance_id, :binary_id, null: false
        add :token_id, :binary_id

        add :timer_type, :string, null: false
        add :node_id, :string, null: false
        add :fire_at, :utc_datetime_usec, null: false

        add :status, :string, null: false, default: "pending"
        add :fired_at, :utc_datetime_usec
        add :cancelled_at, :utc_datetime_usec
        add :failed_at, :utc_datetime_usec
        add :cancel_reason, :text

        add :fire_error_count, :integer, null: false, default: 0

        add :repeat_expression, :string
        add :repeat_interval_us, :bigint
        add :repeat_total, :integer
        add :fired_count, :integer

        add :created_at, :utc_datetime_usec, null: false
      end

      create index(:timers, [:fire_at],
               name: :idx_timers_pending_fire_at,
               where: "status = 'pending'",
               prefix: prefix()
             )

      create constraint(:timers, :chk_timers_status,
               check: "status IN ('pending', 'fired', 'cancelled', 'failed')",
               prefix: prefix()
             )

      create constraint(:timers, :chk_timers_recurrence_shape,
               check: """
               (repeat_expression IS NULL AND repeat_interval_us IS NULL
                  AND repeat_total IS NULL AND fired_count IS NULL)
               OR
               (repeat_expression IS NOT NULL AND repeat_interval_us IS NOT NULL
                  AND fired_count IS NOT NULL AND fired_count >= 0
                  AND (repeat_total IS NULL OR (repeat_total >= 1 AND fired_count <= repeat_total)))
               """,
               prefix: prefix()
             )
    end
  end
end
