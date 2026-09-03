# Letflow.Repo.Migrations.CreateServiceTaskDispatches
#
# REQ-214. Implements lib/letflow/design/service_task_dispatcher.md section 3
# (the `service_task_dispatches` table) -- the schema half of the
# SERVICE_TASK dispatch-orchestration core. See
# Letflow.Engine.ServiceTaskDispatcher /
# Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch /
# Letflow.Engine.ServiceTaskDispatcher.Poller for the runtime this table
# backs; this migration builds schema only.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY
# (Decision 0003 Decision B: schema-per-tenant is the isolation boundary,
# `tenant_id` is retained as an intra-schema column, not itself the
# boundary). Mirrors 20260829020001_create_timers.exs's own header/shape
# exactly -- identical discipline, direct structural precedent (design §0,
# §3). Registered in Letflow.TenantProvisioning.@tenant_scoped_migration_manifest
# -- both halves are mandatory: a guarded-but-unregistered migration is
# inert forever, a registered-but-unguarded one corrupts `public` on a plain
# `mix ecto.migrate` run.
#
# `id`/`instance_id`/`token_id` carry no FK (design §3.1) -- same rationale
# as `timers`: a dispatch row may need to outlive assumptions about the
# referenced row's own lifecycle, and no acceptance criterion requires
# referential integrity here. Unlike `timers.token_id`, `token_id` here is
# NOT NULL -- every SERVICE_TASK dispatch is always token-scoped (design
# §3.1).
#
# `status` is plain :string, NOT Ecto.Enum (design §3.1) -- mirrors
# `timers.status`'s own "DB CHECK-backed, no application-layer enum
# duplication" precedent.
#
# `next_attempt_at`/`created_at`/`dispatched_at` are all `:utc_datetime_usec`
# (design §3.1) -- `next_attempt_at` is the poller's own hot sort key
# (idx_service_task_dispatches_pending_next_attempt_at below), so
# microsecond precision avoids two dispatches created in the same
# wall-clock second racing ambiguously in `ORDER BY next_attempt_at`.
#
# Two DB-level CHECK constraints, `create constraint/3` (same idiom as
# `chk_timers_status`/`chk_timers_recurrence_shape` -- Ecto's `constraint/3`
# builder generates both the forward `ADD CONSTRAINT` and the reverse `DROP
# CONSTRAINT` for a plain `change/0`, no separate `up/0`/`down/0` split
# needed):
#
#   * `chk_service_task_dispatches_status` (design §3.1, §3.3) -- `status`
#     admits exactly `pending`/`advanced`/`given_up`. Three values, not
#     `timers`' four -- no `cancelled` value exists in this table's own
#     domain (design §3.1: a row belonging to a cancelled/completed instance
#     is skipped at claim time, its `status` stays `pending` forever rather
#     than being flipped to a terminal `cancelled` value).
#   * `chk_service_task_dispatches_attempt_index` (design §3.3) -- defensive:
#     `attempt_index >= 0`, mirroring `ServiceTask.attempt_index()`'s own
#     `non_neg_integer()` type -- the DB should not silently accept what the
#     type forbids.
#
# `idx_service_task_dispatches_pending_next_attempt_at` -- partial index on
# `(next_attempt_at)` WHERE `status = 'pending'` (design §3.2) -- the
# poller's one hot query (Letflow.Engine.ServiceTaskDispatcher.claim_due_dispatch_ids/2).
# Mirrors `idx_timers_pending_fire_at` exactly. No index on `tenant_id`
# alone (the Postgres schema, not this column, is the actual isolation
# boundary). No index on `instance_id` -- no query in this design's own
# scope filters by it directly (design §3.2).
#
# No `inserted_at`/`updated_at` pair from `timestamps/1` -- same rationale
# as `timers`: this table's contract names specific, narrow timestamp
# columns (`next_attempt_at`/`dispatched_at`/`created_at`), not a generic
# last-modified column nothing in the acceptance criteria requires.
defmodule Letflow.Repo.Migrations.CreateServiceTaskDispatches do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:service_task_dispatches, primary_key: false, prefix: prefix()) do
        add :id, :binary_id, primary_key: true
        add :tenant_id, :binary_id, null: false

        add :instance_id, :binary_id, null: false
        add :token_id, :binary_id, null: false

        add :node_id, :string, null: false
        add :config_snapshot, :map, null: false

        add :attempt_index, :integer, null: false, default: 0
        add :next_attempt_at, :utc_datetime_usec, null: false

        add :status, :string, null: false, default: "pending"
        add :last_failure_kind, :string
        add :dispatched_at, :utc_datetime_usec

        add :created_at, :utc_datetime_usec, null: false
      end

      create index(:service_task_dispatches, [:next_attempt_at],
               name: :idx_service_task_dispatches_pending_next_attempt_at,
               where: "status = 'pending'",
               prefix: prefix()
             )

      create constraint(:service_task_dispatches, :chk_service_task_dispatches_status,
               check: "status IN ('pending', 'advanced', 'given_up')",
               prefix: prefix()
             )

      create constraint(
               :service_task_dispatches,
               :chk_service_task_dispatches_attempt_index,
               check: "attempt_index >= 0",
               prefix: prefix()
             )
    end
  end
end
