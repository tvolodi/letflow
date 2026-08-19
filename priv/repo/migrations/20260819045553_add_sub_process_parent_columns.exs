# Letflow.Repo.Migrations.AddSubProcessParentColumns
#
# REQ-062 (SPC-01 sub-process runtime half). Implements
# lib/letflow/design/req062-sub-process-runtime.md §6 -- the durable
# parent<->child link (`instance_projections.parent_instance_id`/
# `parent_token_id`) plus the partial index backing
# `Letflow.Engine.SubProcess.find_waiting_parent_token/3`'s own
# `WHERE waiting_child_instance_id == ^child_instance_id` lookup.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY,
# matching every other tenant-scoped migration in this schema (see
# 20260816120001_create_events.exs's header for the full rationale).
# Registered in Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both
# halves are mandatory.
#
# Both new columns are nullable (design §6.1): `nil` for every top-level
# (non-child) instance, which is every instance created before this
# requirement. `on_delete: :restrict` on both FKs, matching this schema's
# existing precedent (`tokens.instance_id`/`tokens.parent_token_id`,
# `20260818110002_create_tokens.exs`'s own stated reasoning) -- no requirement
# in Letflow yet deletes an `instance_projections` row.
#
# No new table (design §6.3) -- the parent<->child relationship is fully
# represented by these two columns (durable) plus
# `tokens.waiting_child_instance_id` (transient, while-running, already
# exists per REQ-043).
defmodule Letflow.Repo.Migrations.AddSubProcessParentColumns do
  use Ecto.Migration

  def change do
    if prefix() do
      alter table(:instance_projections, prefix: prefix()) do
        add :parent_instance_id,
            references(:instance_projections,
              column: :instance_id,
              type: :binary_id,
              on_delete: :restrict
            )

        add :parent_token_id,
            references(:tokens, column: :id, type: :binary_id, on_delete: :restrict)
      end

      create index(:instance_projections, [:parent_instance_id],
               name: :idx_instance_projections_parent,
               where: "parent_instance_id IS NOT NULL",
               prefix: prefix()
             )

      create index(:tokens, [:waiting_child_instance_id],
               name: :idx_token_waiting_child_instance,
               where: "waiting_child_instance_id IS NOT NULL",
               prefix: prefix()
             )
    end
  end
end
