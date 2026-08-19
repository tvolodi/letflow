# Letflow.Repo.Migrations.CreateInstanceStateSnapshots
#
# REQ-054. Implements
# lib/letflow/design/req054-instance-state-snapshots.md section 3 (the
# `instance_state_snapshots` table). Ports `snapshot_writer.zig` (R-Co's
# ISS-601, design artefact `src/design/iss601_state_snapshots.md`).
#
# NOT THE SAME TABLE AS `instance_definition_snapshots`
# (20260816193002_create_instance_definition_snapshots.exs, REQ-027/033) --
# that table holds the immutable PD-08 definition graph bound to an instance
# at start (one row per instance, write-once). This table holds periodic
# EXECUTION STATE snapshots (InstanceState.t()) -- zero or more rows per
# instance, accumulating over the instance's life. See
# Letflow.Engine.SnapshotWriter's moduledoc for the same distinction restated
# in substance (design doc section 1).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY. See
# lib/letflow/design/req022-tenant-schema-provisioning.md section 4 and
# 20260816120001_create_events.exs's header for the full rationale. Registered
# in Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both halves are
# mandatory (design doc section 3, "Registration").
#
# MUST SORT AFTER 20260818110003_create_tasks.exs -- this migration carries a
# foreign key onto instance_projections (already required by that migration's
# own presence in the manifest, no direct ordering dependency on tasks itself,
# but sorted after it here to keep this stage's engine-schema migrations
# grouped together in version order).
#
# NO `tenant_id` COLUMN (Decision 0006 D2, design doc INV-ISS-4) -- same as
# every other business table added since D2 shipped (events, tokens, tasks,
# instance_definition_snapshots). The per-tenant Postgres schema (`prefix:`)
# is the sole isolation boundary.
#
# `id` is a bare `:binary_id` primary key, NOT a bare `instance_id` PK like
# `instance_definition_snapshots` -- this table is one-to-many per instance,
# not one-to-one (design doc section 3, `id` row).
#
# `on_delete: :restrict` on the `instance_id` FK, matching `tasks`/`tokens`'s
# own choice and stated reason (`20260818110003_create_tasks.exs`'s header:
# "no delete path exists for instance_projections anywhere in Letflow yet, so
# :restrict fails loudly instead of silently losing tenant data"). Same
# reasoning applies verbatim here (design doc section 3, `instance_id` row).
#
# `state` is a plain `:map` (jsonb) column -- design doc section 2.2's
# `snapshot_state()` shape (status, tokens, variables, pending_task_nodes,
# join_counters), a JSON *object*, not the array-typed `current_nodes` special
# case `InstanceProjection` needed its own `JSONArray` type for.
#
# `taken_at`'s default is `(now() AT TIME ZONE 'utc')` rather than a bare
# `NOW()`, matching `instance_definition_snapshots.snapshotted_at`'s and
# REQ-023's own mitigation against an implicit local-timezone cast. No
# `updated_at` -- a snapshot row is write-once, never updated in place (design
# doc section 3, `taken_at` row).
#
# Indexes: `idx_iss_instance` (bare `instance_id`) is mandatory because
# Postgres does not auto-index the referencing side of a FK (same reasoning as
# every prior FK-bearing migration in this schema). `idx_iss_instance_seq`
# (`instance_id`, `sequence_number`) is the query this table exists to serve:
# "give me the latest snapshot for this instance" is
# `... WHERE instance_id = ^id ORDER BY sequence_number DESC LIMIT 1`, and
# this composite index makes that an index-only scan rather than a filter +
# sort. Deliberately NOT declared `unique` -- design doc section 3 "Indexes":
# no resolved cadence mechanism in this design justifies assuming two
# snapshots can never share a `sequence_number` for an instance; a future
# requirement that resolves the cadence-counter question (design doc section
# 6) more strictly could add that constraint then.
defmodule Letflow.Repo.Migrations.CreateInstanceStateSnapshots do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:instance_state_snapshots, primary_key: false, prefix: prefix()) do
        add :id, :binary_id, primary_key: true

        add :instance_id,
            references(:instance_projections,
              column: :instance_id,
              type: :binary_id,
              on_delete: :restrict
            ),
            null: false

        add :sequence_number, :integer, null: false
        add :state, :map, null: false

        add :taken_at, :utc_datetime_usec,
          null: false,
          default: fragment("(now() AT TIME ZONE 'utc')")
      end

      create index(:instance_state_snapshots, [:instance_id],
               name: :idx_iss_instance,
               prefix: prefix()
             )

      create index(:instance_state_snapshots, [:instance_id, :sequence_number],
               name: :idx_iss_instance_seq,
               prefix: prefix()
             )
    end
  end
end
