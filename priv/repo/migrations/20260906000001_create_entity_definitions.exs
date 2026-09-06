# Letflow.Repo.Migrations.CreateEntityDefinitions
#
# REQ-226 (ISS-0438 entity-subsystem port, slice 2) -- see
# lib/letflow/design/req226-entity-definitions-persistence-crud.md for the
# full design this migration implements (§1 placement/schema/constraints).
#
# PLACEMENT: `entity_definitions` is created PER-TENANT (schema-per-tenant
# via `prefix()`), matching REQ-202's `repository_artifacts`/`artifact_versions`
# and REQ-203's `artifact_activations`/`artifact_activation_history` own
# placement. 0003-ecto-schema-strategy.md Decision B's blast-radius-containment
# rationale applies identically here -- not a shared `public`-schema table.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY,
# matching req202/req203's guard pattern, and this file's registration in
# `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest` (both
# halves are mandatory -- see that module's own manifest comment).
#
# IMMUTABILITY (design §1.4): deliberately NO DB-level trigger here, unlike
# `repository_artifacts`/`artifact_versions` -- REQ-226's own scope never
# exposes an update/delete path for this table (only `create_definition/2`,
# three read functions, and `activate_definition/4`'s own `status` write via
# a plain `Repo.update`), so there is nothing to structurally forbid yet.
# Left as an explicit open question (design §6 OQ-2) for a future requirement
# to decide.
#
# No SQL string below interpolates tenant- or user-controlled data (INV-7)
# -- every statement is a fixed, migration-authored literal, scoped only by
# the already-trusted `prefix()` schema-name value Ecto itself resolves for
# this migration run.
defmodule Letflow.Repo.Migrations.CreateEntityDefinitions do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      create table(:entity_definitions, primary_key: false, prefix: schema) do
        add :id, :binary_id, primary_key: true
        add :tenant_id, :binary_id, null: false
        add :name, :string, size: 255, null: false
        add :display_name, :string, size: 255, null: false
        add :definition_json, :map, null: false
        add :content_hash, :binary, null: false
        add :logical_shape_version, :binary, null: false

        add :artifact_version_id,
            references(:artifact_versions,
              column: :version_id,
              type: :binary_id,
              on_delete: :restrict,
              prefix: schema
            ),
            null: false

        add :status, :string, null: false

        timestamps(type: :utc_datetime_usec, updated_at: false)
      end

      # REQ-226's own text, verbatim: (tenant_id, name, logical_shape_version)
      # uniquely identifies one entity_definitions row. Named explicitly,
      # well under Postgres's 63-byte NAMEDATALEN, matching
      # 20260830030001_create_repository_artifacts.exs's own explicit-naming
      # rationale (default-name collision/truncation risk).
      create unique_index(
               :entity_definitions,
               [:tenant_id, :name, :logical_shape_version],
               name: :entity_definitions_tenant_name_shape_idx,
               prefix: schema
             )

      # Supports listDefinitions/2's cursor query (design §3.3) -- newest
      # first by (inserted_at, id), matching artifact_versions_kind_name_number_desc_idx's
      # role for list_versions/4.
      create index(
               :entity_definitions,
               [:tenant_id, desc: :inserted_at, desc: :id],
               name: :entity_definitions_tenant_inserted_id_idx,
               prefix: schema
             )

      # Observability/debugging parity with artifact_versions' own
      # content_hash index -- not used by any CRUD function's WHERE clause on
      # the production path (design §1.3).
      create index(
               :entity_definitions,
               [:content_hash],
               name: :entity_definitions_content_hash_idx,
               prefix: schema
             )
    end
  end
end
