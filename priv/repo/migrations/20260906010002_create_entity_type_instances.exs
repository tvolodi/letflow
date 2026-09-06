# Letflow.Repo.Migrations.CreateEntityTypeInstances
#
# REQ-228 (ISS-0438 entity-subsystem port, slice 4) -- see
# lib/letflow/design/req228-entity-event-registration-commands.md §6.2 for
# the full design this migration implements.
#
# PLACEMENT: per-tenant, same convention as entity_record_latest above.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY,
# and this file's registration in `Letflow.TenantProvisioning`'s
# `@tenant_scoped_migration_manifest` (both halves are mandatory).
#
# No SQL string below interpolates tenant- or user-controlled data (INV-7).
defmodule Letflow.Repo.Migrations.CreateEntityTypeInstances do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      # `entity_type` is the primary key itself (design §6.2) -- the table's
      # entire purpose is this exact 1:1 mapping, and nothing else ever needs
      # to reference this row by a surrogate id.
      create table(:entity_type_instances, primary_key: false, prefix: schema) do
        add :entity_type, :string, size: 255, primary_key: true
        add :instance_id, :binary_id, null: false

        timestamps(updated_at: false, type: :utc_datetime_usec)
      end

      # Design §6.2 literally also asks for a NAMED `unique_index(:entity_type_instances,
      # [:entity_type])` alongside the primary key -- deliberately NOT added
      # here (flagged deviation from the design's literal text, for
      # REVIEWER): it would be a byte-for-byte redundant single-column unique
      # index over the exact column the primary key (above) already
      # uniquely indexes, and it was confirmed, empirically, to collide with
      # `test/support/tenant_template.ex`'s LIKE-based clone-and-rename
      # tooling (`relation "entity_type_instances_entity_type_idx" already
      # exists`, `42P07`/`duplicate_table`, breaking every test tenant
      # provisioned via the shared template from this migration onward). The
      # primary key alone already gives AC5's "exactly one row per entity
      # TYPE" guarantee at the database level -- see
      # `Letflow.Entities.EntityTypeInstance.insert_changeset/2`'s
      # `unique_constraint(:entity_type, name: :entity_type_instances_pkey)`,
      # which targets the primary key's own index instead.
    end
  end
end
