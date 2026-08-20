# Letflow.Repo.Migrations.CreateVariableSchemas
#
# REQ-109. Implements lib/letflow/design/req109-variable-schemas.md §2 (the
# `variable_schemas` table). Ported column for column from R-Co
# migrations/012_event_retention.sql:32-49, the table R-Co's own
# `mergeVariables` (src/engine/instance.zig:2318) reads to validate output
# variables per key. Closes ISS-0063 / GH#212 together with
# Letflow.Engine.VariableSchema and the `merge_output_variables` call site in
# lib/letflow/engine.ex.
#
# NOT `tasks.form_schema` AND NOT `form_schema_registry` -- three distinct
# things in R-Co carry the word "schema" and a prior investigation conflated
# them (ISS-0063's superseded_scoping_note). `tasks.form_schema` is a UI form
# RENDERING payload R-Co never validates submitted output against;
# `form_schema_registry` (R-Co migrations/047_repository_form_schemas.sql,
# REPO-05) is a field-level search index over form artifacts. This table is
# the only one of the three that feeds validation. See
# Letflow.Engine.VariableSchema's moduledoc for the full disambiguation.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY. See
# lib/letflow/design/req022-tenant-schema-provisioning.md section 4 and
# 20260816120001_create_events.exs's header for the full rationale. Registered
# in Letflow.TenantProvisioning's @tenant_scoped_migration_manifest -- both
# halves are mandatory (design §2.3). R-Co's own DDL comment agrees that this
# table is per-tenant ("ISS-0641 / GH-637: PER_TENANT ... FKs to tenant-schema
# process_definitions(id)", 012:27-30), as does
# R-Co src/definition/sandbox_pool.zig:126, which clones `variable_schemas`
# per tenant schema.
#
# MUST SORT AFTER 20260816193001_create_process_definitions.exs -- this
# migration carries a foreign key onto that table's `id` column.
#
# NO `tenant_id` COLUMN (Decision 0006 D2, design §2.1) -- same as every other
# business table added since D2 shipped (events, tokens, tasks,
# instance_definition_snapshots, instance_state_snapshots). The per-tenant
# Postgres schema (`prefix:`) is the sole isolation boundary.
#
# `on_delete: :restrict`, DELIBERATELY DIVERGING from R-Co's ON DELETE CASCADE
# (design §2.2). The reason, stated here rather than either side being copied
# silently: no delete path for `process_definitions` exists anywhere in
# Letflow yet, so `:restrict` fails loudly instead of silently discarding
# tenant data that nothing intended to discard -- the identical reason
# 20260818110002_create_tokens.exs and 20260818110003_create_tasks.exs state
# for their own FKs. When a definition-delete path is eventually built,
# revisiting this choice is that requirement's job, and it should find this
# paragraph.
#
# `created_at` is a literal column, NOT `timestamps()` -- R-Co's column is
# `created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()` and there is no
# `updated_at`; a `variable_schemas` row is written at definition
# registration and never updated in place. Same choice
# 20260816120001_create_events.exs made for the identical R-Co column name.
# The default is `(now() AT TIME ZONE 'utc')` rather than a bare `NOW()`,
# matching that migration's own mitigation against an implicit
# local-timezone cast.
#
# `json_schema` is `:map` (jsonb) -- Letflow's established jsonb spelling
# (instance_projections.variables, tasks.form_schema). Nothing here validates
# that the stored document is a well-formed JSON Schema; that is a
# registration-time concern belonging to REQ-078/REQ-082 (design §11.3, OQ-3),
# and Letflow.Engine.VariableSchema's read path defends against a non-map
# stored value at read time (design §6.3).
#
# `description` is ported for fidelity with R-Co and has no reader in Letflow
# today (design §11.5, OQ-5) -- it does not feed the rejection message.
#
# Indexes: `uq_variable_schema_definition_key` ports R-Co's
# `UNIQUE (definition_id, variable_key)`; `idx_vs_definition` ports R-Co's
# index of the same name and exists because Postgres does not automatically
# index the REFERENCING side of a foreign key (same reasoning as every prior
# FK-bearing migration in this schema). Index names are per-schema in
# Postgres, so R-Co's name can be reused verbatim without cross-tenant
# collision.
defmodule Letflow.Repo.Migrations.CreateVariableSchemas do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:variable_schemas, primary_key: false, prefix: prefix()) do
        add :id, :binary_id, primary_key: true

        add :definition_id,
            references(:process_definitions,
              column: :id,
              type: :binary_id,
              on_delete: :restrict
            ),
            null: false

        add :variable_key, :string, null: false
        add :json_schema, :map, null: false
        add :description, :text

        add :created_at, :utc_datetime_usec,
          null: false,
          default: fragment("(now() AT TIME ZONE 'utc')")
      end

      create unique_index(:variable_schemas, [:definition_id, :variable_key],
               name: :uq_variable_schema_definition_key,
               prefix: prefix()
             )

      create index(:variable_schemas, [:definition_id],
               name: :idx_vs_definition,
               prefix: prefix()
             )
    end
  end
end
