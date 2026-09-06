# Letflow.Repo.Migrations.CreateEntityRecordLatest
#
# REQ-228 (ISS-0438 entity-subsystem port, slice 4) -- see
# lib/letflow/design/req228-entity-event-registration-commands.md §6.1 for
# the full design this migration implements.
#
# PLACEMENT: `entity_record_latest` is created PER-TENANT (schema-per-tenant
# via `prefix()`), matching REQ-226's `entity_definitions` own placement --
# 0003-ecto-schema-strategy.md Decision B's blast-radius-containment
# rationale applies identically here.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY,
# matching req226's guard pattern, and this file's registration in
# `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest` (both
# halves are mandatory -- see that module's own manifest comment).
#
# No SQL string below interpolates tenant- or user-controlled data (INV-7)
# -- every statement is a fixed, migration-authored literal, scoped only by
# the already-trusted `prefix()` schema-name value Ecto itself resolves for
# this migration run.
defmodule Letflow.Repo.Migrations.CreateEntityRecordLatest do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      create table(:entity_record_latest, primary_key: false, prefix: schema) do
        add :id, :binary_id, primary_key: true
        add :entity_type, :string, size: 255, null: false
        add :record_id, :binary_id, null: false
        add :field_values, :map, null: false, default: %{}
        add :deleted, :boolean, null: false, default: false
        add :entity_def_version, :binary
        add :last_event_global_seq, :bigint, null: false

        timestamps(type: :utc_datetime_usec)
      end

      # Design §6.1: exactly one current-state row per (entity_type, record_id)
      # pair -- the Multi.insert/3-vs-Multi.update/3 branch point
      # create_record/2 vs. update_record/2/delete_record/2 key off.
      create unique_index(
               :entity_record_latest,
               [:entity_type, :record_id],
               name: :entity_record_latest_entity_type_record_id_idx,
               prefix: schema
             )
    end
  end
end
