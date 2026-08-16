# Letflow.Repo.Migrations.CreateProcessDefinitions
#
# REQ-027, migration 1 of 2. Implements
# lib/letflow/design/req027-definition-core-schema.md section 3.1 (the
# `process_definitions` table). Ported from R-Co migrations/004_definitions.sql:8-39,
# plus the `stage` column and its partial index from
# migrations/014_definition_stage.sql:3-4 (PD-07), plus `tenant_id` from
# 028_adp02_tenant_scope_persistence.sql:15-16.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY. See
# lib/letflow/design/req022-tenant-schema-provisioning.md section 4 and
# 20260816120001_create_events.exs's header for the full rationale. Registered in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both halves are mandatory:
# a guarded-but-unregistered migration is inert forever, a registered-but-unguarded one
# corrupts `public` on every plain `mix ecto.migrate` run.
#
# SCOPE NOTE (REQ-027, requirements.yaml's "note explicitly in both moduledocs"
# instruction, stated in full in Letflow.Definitions.ProcessDefinition's moduledoc):
# this requirement builds SCHEMA ONLY. Graph/node/edge structural validation is
# REQ-028 (merged, lib/letflow/definitions/graph.ex) and REQ-029; the CRUD operations
# (create/1, get_by_id/1, get_active_by_name/1, list/1, activate/1, deprecate/1,
# archive/1) are REQ-030. Do not read this migration as the definition store landing
# early.
#
# `status` IS STORED LOWERCASE -- deliberately diverging from R-Co, which stores
# 'DRAFT'/'ACTIVE'/'DEPRECATED'/'ARCHIVED' (004:15-16, 004:36). REQ-027 acceptance
# criterion 2 mandates the predicate literal `WHERE status = 'active'`, and the schema
# module's Ecto.Enum uses the bare atom-list form, which dumps `:active` as the
# lowercase "active" (deps/ecto/lib/ecto/enum.ex:81-83). The dumped value and this
# index predicate MUST be the same literal: if they ever disagree,
# `uq_active_definition` silently matches zero rows and PD-03's single-active-per-name
# invariant is unenforced with no error anywhere (design INV-DEF-3, section 10 C-3).
# Note this differs from 20260816120003_create_instance_projections.exs, which is
# uppercase on both sides -- self-consistency is the property that matters, not case.
#
# NO DB-LEVEL `DEFAULT NOW()` on created_at/updated_at, unlike R-Co (004:25-26).
# timestamps/1 adds no DB default (deps/ecto_sql/lib/ecto/migration.ex:1366-1376);
# values come from Ecto.Schema's autogeneration at insert time, matching every other
# Letflow table. Likewise no `DEFAULT gen_random_uuid()` on `id` (004:9) and no
# `DEFAULT bpm_effective_tenant_id()` on `tenant_id` (028_adp02:16, 33) -- Letflow has
# no reserved default-tenant UUID at all, so REQ-030's create/1 must supply tenant_id
# explicitly (design OQ-1).
#
# INDEXES DELIBERATELY NOT CREATED HERE, each for a stated reason (design section
# 3.1.2):
#   * idx_def_name on (name) (004:38) -- redundant. uq_definition_version is a btree on
#     (name, version) whose leading column is `name`, usable for any name-only predicate.
#   * idx_def_fts, the GIN index over to_tsvector(name || description) (004:42-44) --
#     not ported on R-Co's OWN authority: PD-10's design section says "A new SQL
#     migration is NOT needed for PD-10" (definition.md:3008-3022), and PD-10's actual
#     query is `name ILIKE $2 OR description ILIKE $2` (definition.md:2862-2864), which
#     cannot use a to_tsvector GIN index at all. Letflow's REQ-042 confirms it adds no
#     new index. See design OQ-8: reviving it is a two-part change (index + query).
#   * uq_definition_tenant_version, uq_active_definition_tenant,
#     idx_def_tenant_name_status, idx_def_tenant_created (028_adp02:45-56) -- under
#     Decision B the Postgres schema IS the tenant boundary, so tenant_id has at most
#     one distinct value per schema and a leading-tenant_id index degenerates to its
#     non-tenant counterpart at strictly higher write cost. No enforcement is lost.
#
# NO CHECK constraint on `graph` -- the 8 PD-02 structural checks live in
# Letflow.Definitions.Graph.validate_graph/1 as a pure function, and R-Co's Key
# invariant 1 puts enforcement on the write path (definition.md:471). A DB-level CHECK
# would be a second source of truth with a different error shape and could not express
# CHK-01..CHK-08 anyway.
#
# NO foreign keys: `created_by` -> users.id and `tenant_id` -> tenants.id are both bare
# UUIDs, matching R-Co (004:24) and this codebase's existing convention -- `users` and
# `tenants` live in the public/default schema while this table lives in a tenant schema.
defmodule Letflow.Repo.Migrations.CreateProcessDefinitions do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:process_definitions, primary_key: false, prefix: prefix()) do
        add :id, :binary_id, primary_key: true
        add :tenant_id, :binary_id, null: false
        add :name, :string, null: false
        add :version, :string, null: false
        add :description, :text
        add :status, :string, null: false, default: "draft"
        add :stage, :string
        add :graph, :map, null: false, default: %{"nodes" => [], "edges" => []}
        add :created_by, :binary_id, null: false
        add :archived_at, :utc_datetime_usec

        timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
      end

      # REQ-027 AC 2, first half. R-Co declares this as a table constraint
      # (`CONSTRAINT uq_definition_version UNIQUE (name, version)`, 004:30); Ecto emits
      # CREATE UNIQUE INDEX instead. Uniqueness enforcement is identical, the index name
      # is what Ecto.Changeset.unique_constraint/3 maps the 23505 error by, and a unique
      # index is a valid arbiter for REQ-030's `ON CONFLICT (name, version)`.
      create unique_index(:process_definitions, [:name, :version],
               name: :uq_definition_version,
               prefix: prefix()
             )

      # REQ-027 AC 2, second half. PD-03's single-active-per-name invariant, carried at
      # the migration layer independently of REQ-030's activate/1 logic (004:34-36).
      # The predicate string is emitted verbatim after " WHERE "
      # (deps/ecto_sql/lib/ecto/adapters/postgres/connection.ex:1344), and
      # unique_index/3 is literally index/3 with [unique: true] prepended
      # (deps/ecto_sql/lib/ecto/migration.ex:1048-1052), so :where/:name/:prefix are all
      # available on a partial UNIQUE index. Lowercase 'active' -- see this file's
      # header.
      create unique_index(:process_definitions, [:name],
               name: :uq_active_definition,
               where: "status = 'active'",
               prefix: prefix()
             )

      # REQ-027 AC 3. Ported verbatim from 014_definition_stage.sql:4. PD-07's own
      # rationale: "Partial index WHERE stage IS NOT NULL avoids indexing null entries
      # and keeps the index compact" (definition.md:1484-1485).
      create index(:process_definitions, [:stage],
               name: :idx_def_stage,
               where: "stage IS NOT NULL",
               prefix: prefix()
             )

      # 004:39. Serves REQ-030's list/1 `?status=` filter (definition.md:1447). Beyond
      # REQ-027's three enumerated indexes but R-Co-sourced, not invented here.
      create index(:process_definitions, [:status], name: :idx_def_status, prefix: prefix())
    end
  end
end
