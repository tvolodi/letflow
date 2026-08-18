# Letflow.Repo.Migrations.CreateTokens
#
# REQ-043, migration 2 of 3. Implements
# lib/letflow/design/req043-instance-engine-schema.md sections 3.2-3.3 (the
# `tokens` table). Ported from R-Co migrations/005_instances.sql:9-31, with
# deliberate divergences documented below and in the design doc.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY. See
# lib/letflow/design/req022-tenant-schema-provisioning.md section 4 and
# 20260816120001_create_events.exs's header for the full rationale. Registered in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both halves are
# mandatory. MUST SORT BEFORE 20260818110003_create_tasks.exs -- that migration
# carries a foreign key onto this table's `id` column (design §4.2).
#
# WHY THIS TABLE EXISTS AT ALL (design §3.1, resolved: BUILD, not dropped, not
# silently kept): R-Co's own engine.md computes split/join purely from the
# in-memory Token{node_id, branch_id} struct, persisted as a flat JSONB array on
# instance_projections.current_nodes -- read in isolation that would suggest a
# separate tokens table is redundant. It is not, for three independently
# sufficient reasons: (1) tasks.token_id (this run's own item (b)) is a mandatory
# NOT NULL FK column -- a JSONB array element cannot be an FK target, so some
# real, addressable row must exist regardless of anything EE-02/EE-06/EE-07 need;
# (2) R-Co's own physical schema (005_instances.sql:9-31) independently reaches
# the identical conclusion, for the identical FK reason; (3) REQ-051's join
# counters and REQ-062's sub-process wait tracking both need a durable, queryable,
# lockable per-token record a flat JSONB array cannot provide (partial indexes
# cannot target an array element). instance_projections.current_nodes remains the
# engine's authoritative fast-read summary of active token positions -- this
# table is the identity/lifecycle side table tasks and future sub-process
# tracking need. See Letflow.Engine.Token's moduledoc for the same statement
# restated in substance (design §5.3 point 1).
#
# `status` is plain :string at the migration layer (Ecto.Enum mapping lives at
# the schema layer, Letflow.Engine.Token) -- bare atom-list form, LOWERCASE dump
# (:active/:waiting/:completed/:cancelled), matching R-Co's own lowercase
# 'active'|'waiting'|'completed'|'cancelled' (005_instances.sql:16-17) directly.
# Deliberately NOT harmonized with tasks.status's uppercase convention -- R-Co
# itself uses different casing for the two tables in the same source file,
# confirmed by direct read, not silently unified (design §3.2, INV-EE43-4).
#
# `node_id` (R-Co calls this `current_node`; renamed here to match EE-02's
# in-memory Token.node_id field name and this run's own task text, design §3.2).
# `branch_id` matches EE-02's Token.branch_id exactly.
#
# `waiting_child_instance_id` (renamed from R-Co's `child_instance_id`,
# 005:25) -- REQ-062/SPC-01's parent-token wait marker, named explicitly in this
# run's task text; the name is self-documenting about *why* the field is set (a
# token parked waiting on a sub-process child), design §3.2.
#
# `data JSONB DEFAULT '{}'` (R-Co's generic per-token scratch field, 005:27) is
# DELIBERATELY NOT PORTED -- no acceptance criterion or named future requirement
# has stated a need for it. If REQ-051/062 need it, that is a small additive
# ALTER TABLE at that point, not a gap (design §3.2).
#
# `cancelled_at` is added even though R-Co's own `tokens` table lacks one,
# because R-Co's `tokens.status` enum already includes 'cancelled' with no
# timestamp to match it -- the same completed_at/cancelled_at pairing every other
# lifecycle table in this schema carries is extended here for consistency, not
# left asymmetric (design §3.2).
#
# `on_delete: :restrict` ON BOTH FKS (instance_id, parent_token_id), DELIBERATELY
# DIVERGING from R-Co's `instance_id` CASCADE (005_instances.sql:12;
# parent_token_id carries no explicit action in R-Co at all). Same reasoning
# `20260816120004_create_event_payload_store.exs`'s header already established
# for this codebase: no requirement anywhere in Letflow builds a delete path for
# instance_projections rows, so cascading deletes through tokens are presently
# unreachable in practice -- :restrict is the defensively safer default that
# fails loudly if a future requirement ever does add instance deletion, rather
# than silently deleting a tenant's token history (design §3.3).
#
# `idx_token_instance` and `idx_token_parent` exist because Postgres does not
# automatically index the REFERENCING side of a foreign key
# (20260816193002_create_instance_definition_snapshots.exs's own stated
# reasoning). `idx_token_parent` is partial (WHERE parent_token_id IS NOT NULL),
# matching idx_proj_parent's identical shape in 005_instances.sql:99-101, since
# most tokens are root-branch tokens with no parent.
#
# R-Co's idx_token_active/idx_token_waiting (005:36-43) are DELIBERATELY NOT
# BUILT HERE -- both are query-optimization indexes for join/cancellation logic
# this requirement does not implement (REQ-051's own job); adding them now, ahead
# of the real query shapes REQ-051 will issue, risks guessing wrong on the
# predicate/column order. Flagged for REQ-051's own CODE-DESIGNER (design §3.3,
# §9 OQ-4), not silently dropped.
defmodule Letflow.Repo.Migrations.CreateTokens do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:tokens, primary_key: false, prefix: prefix()) do
        add :id, :binary_id, primary_key: true
        add :tenant_id, :binary_id, null: false

        add :instance_id,
            references(:instance_projections,
              column: :instance_id,
              type: :binary_id,
              on_delete: :restrict
            ),
            null: false

        add :node_id, :string, null: false
        add :branch_id, :string, null: false
        add :status, :string, null: false, default: "active"

        add :parent_token_id,
            references(:tokens, column: :id, type: :binary_id, on_delete: :restrict)

        add :gateway_id, :string
        add :waiting_child_instance_id, :binary_id
        add :completed_at, :utc_datetime_usec
        add :cancelled_at, :utc_datetime_usec

        timestamps(type: :utc_datetime_usec)
      end

      create index(:tokens, [:instance_id], name: :idx_token_instance, prefix: prefix())

      create index(:tokens, [:parent_token_id],
               name: :idx_token_parent,
               where: "parent_token_id IS NOT NULL",
               prefix: prefix()
             )
    end
  end
end
