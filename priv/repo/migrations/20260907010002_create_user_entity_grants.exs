# Letflow.Repo.Migrations.CreateUserEntityGrants
#
# REQ-231 (ISS-0438 entity-subsystem port, slice 6b) -- see
# lib/letflow/design/req231-entity-query-cursor-field-grants.md §3.2 for the
# full design this migration implements.
#
# PLACEMENT: per-tenant, same convention as entity_field_restrictions above
# -- `users` is also tenant-scoped (REQ-063/REQ-064), so the `user_id` FK
# below resolves within the same per-tenant schema.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY,
# and this file's registration in `Letflow.TenantProvisioning`'s
# `@tenant_scoped_migration_manifest` (both halves are mandatory).
#
# No SQL string below interpolates tenant- or user-controlled data (INV-7).
#
# One row per `(user_id, entity_type, field_name)` triple that lifts a
# matching `entity_field_restrictions` row for exactly that one user
# (design §3.2's default-deny-with-explicit-override model).
defmodule Letflow.Repo.Migrations.CreateUserEntityGrants do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      create table(:user_entity_grants, primary_key: false, prefix: schema) do
        add :id, :binary_id, primary_key: true
        add :user_id, references(:users, type: :binary_id, on_delete: :nothing), null: false
        add :entity_type, :string, size: 255, null: false
        add :field_name, :string, size: 255, null: false

        timestamps(updated_at: false, type: :utc_datetime_usec)
      end

      # Design §3.2: a grant lifts a restriction for exactly one user on
      # exactly one (entity_type, field_name) pair -- never granted "twice".
      create unique_index(
               :user_entity_grants,
               [:user_id, :entity_type, :field_name],
               name: :user_entity_grants_user_id_entity_type_field_name_idx,
               prefix: schema
             )
    end
  end
end
