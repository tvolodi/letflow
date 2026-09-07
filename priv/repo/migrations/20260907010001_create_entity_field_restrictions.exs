# Letflow.Repo.Migrations.CreateEntityFieldRestrictions
#
# REQ-231 (ISS-0438 entity-subsystem port, slice 6b) -- see
# lib/letflow/design/req231-entity-query-cursor-field-grants.md §3.2 for the
# full design this migration implements.
#
# PLACEMENT: per-tenant (schema-per-tenant via `prefix()`), matching
# `entity_definitions`/`entity_record_latest`'s own placement -- this table
# is pure-tenant-schema data with no cross-tenant registry counterpart to
# reconcile against (design §3.2).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY,
# matching req226/req228's guard pattern, and this file's registration in
# `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest` (both
# halves are mandatory -- see that module's own manifest comment).
#
# No SQL string below interpolates tenant- or user-controlled data (INV-7)
# -- every statement is a fixed, migration-authored literal, scoped only by
# the already-trusted `prefix()` schema-name value Ecto itself resolves for
# this migration run.
#
# One row per `(entity_type, field_name)` pair that is, by default, hidden
# from every user unless that user holds a matching `user_entity_grants`
# row (design §3.2). No FK to `entity_definitions` -- a restriction can be
# declared before an entity type's active definition version exists, the
# same "queries by string name, not by definition row" convention
# `Letflow.Entities.Query.Allowlist.load/2` already uses.
defmodule Letflow.Repo.Migrations.CreateEntityFieldRestrictions do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      create table(:entity_field_restrictions, primary_key: false, prefix: schema) do
        add :id, :binary_id, primary_key: true
        add :entity_type, :string, size: 255, null: false
        add :field_name, :string, size: 255, null: false

        timestamps(type: :utc_datetime_usec)
      end

      # Design §3.2: a field is either restricted or not, never restricted
      # "twice" -- one row per (entity_type, field_name) pair.
      create unique_index(
               :entity_field_restrictions,
               [:entity_type, :field_name],
               name: :entity_field_restrictions_entity_type_field_name_idx,
               prefix: schema
             )
    end
  end
end
