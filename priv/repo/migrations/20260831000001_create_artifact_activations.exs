# Letflow.Repo.Migrations.CreateArtifactActivations
#
# REQ-203 (REPO-08/09/10) -- see
# lib/letflow/design/req203-artifact-activation.md for the full design this
# migration implements (§1 placement, §2 schema, §2.4 rationale enforcement,
# §5 append-only judgment call).
#
# PLACEMENT (design §1): all three tables (`artifact_activations`,
# `artifact_activation_history`, `artifact_activation_groups`) are created
# PER-TENANT (schema-per-tenant via `prefix()`), matching REQ-202's own
# placement for `repository_artifacts`/`artifact_versions`. No REVIEWER
# sign-off flag is raised -- this is the default (Decision 0003-B), not a
# divergence from it.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY,
# matching req195/req202's guard pattern, and this file's registration in
# `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest` (both
# halves are mandatory -- see that module's own manifest comment).
#
# EXPLICIT INDEX/CONSTRAINT NAMES: every index and constraint below is given
# an explicit, short, distinct name from the start -- REQ-202's own migration
# hit two real Postgres bugs from omitting this (an Ecto default index-name
# collision from a `desc:` annotation, and a truncated/mismatched unique
# constraint name past Postgres's 63-byte NAMEDATALEN limit). Not repeating
# either class of bug here.
#
# IMMUTABILITY (design §5): deliberately NO DB-level trigger on
# `artifact_activation_history`/`artifact_activation_groups` -- both are
# append-only by construction (no update/delete path exposed by
# `Letflow.Repository.Activation`'s context API), not by DB enforcement. No
# acceptance criterion of REQ-203 asks for DB-level UPDATE/DELETE rejection
# on either table (contrast REQ-202/req195, whose acceptance criteria used
# exactly that framing). `artifact_activations` itself DOES have a real
# update path (activating a new version for an already-activated triple
# updates the existing row in place) -- see design §2.1.
#
# No SQL string below interpolates tenant- or user-controlled data (INV-7)
# -- every statement is a fixed, migration-authored literal, scoped only by
# the already-trusted `prefix()` schema-name value Ecto itself resolves for
# this migration run.
defmodule Letflow.Repo.Migrations.CreateArtifactActivations do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      create table(:artifact_activations, primary_key: false, prefix: schema) do
        add :activation_id, :binary_id, primary_key: true
        add :tenant_id, :binary_id, null: false
        add :artifact_kind, :string, null: false
        add :artifact_name, :string, size: 255, null: false

        add :active_version_id,
            references(:artifact_versions,
              column: :version_id,
              type: :binary_id,
              on_delete: :restrict,
              prefix: schema,
              name: :artifact_activations_active_version_id_fkey
            ),
            null: false

        add :activated_at, :utc_datetime_usec, null: false
        add :activator_user_id, :binary_id, null: false

        timestamps(type: :utc_datetime_usec)
      end

      # REPO-09's real, DB-level enforcement of "exactly one active version
      # per artifact per tenant" (AC4) -- explicit short name, not Ecto's
      # default-derived one.
      create unique_index(
               :artifact_activations,
               [:tenant_id, :artifact_kind, :artifact_name],
               name: :artifact_activations_tenant_kind_name_idx,
               prefix: schema
             )

      create index(
               :artifact_activations,
               [:active_version_id],
               name: :artifact_activations_active_version_id_idx,
               prefix: schema
             )

      create table(:artifact_activation_groups, primary_key: false, prefix: schema) do
        add :group_id, :binary_id, primary_key: true
        add :tenant_id, :binary_id, null: false
        add :activated_at, :utc_datetime_usec, null: false
        add :activator_user_id, :binary_id, null: false
        add :rationale, :text, null: false

        timestamps(type: :utc_datetime_usec, updated_at: false)
      end

      execute(
        "ALTER TABLE \"#{schema}\".artifact_activation_groups " <>
          "ADD CONSTRAINT artifact_activation_groups_rationale_check " <>
          "CHECK (rationale <> '')",
        "ALTER TABLE \"#{schema}\".artifact_activation_groups " <>
          "DROP CONSTRAINT artifact_activation_groups_rationale_check"
      )

      create table(:artifact_activation_history, primary_key: false, prefix: schema) do
        add :history_id, :binary_id, primary_key: true
        add :tenant_id, :binary_id, null: false
        add :artifact_kind, :string, null: false
        add :artifact_name, :string, size: 255, null: false

        add :previous_version_id,
            references(:artifact_versions,
              column: :version_id,
              type: :binary_id,
              on_delete: :restrict,
              prefix: schema,
              name: :artifact_activation_history_previous_version_id_fkey
            )

        add :new_version_id,
            references(:artifact_versions,
              column: :version_id,
              type: :binary_id,
              on_delete: :restrict,
              prefix: schema,
              name: :artifact_activation_history_new_version_id_fkey
            ),
            null: false

        add :new_version_number, :bigint, null: false
        add :activator_user_id, :binary_id, null: false
        add :activated_at, :utc_datetime_usec, null: false
        add :rationale, :text, null: false

        add :group_id,
            references(:artifact_activation_groups,
              column: :group_id,
              type: :binary_id,
              on_delete: :restrict,
              prefix: schema,
              name: :artifact_activation_history_group_id_fkey
            )

        timestamps(type: :utc_datetime_usec, updated_at: false)
      end

      execute(
        "ALTER TABLE \"#{schema}\".artifact_activation_history " <>
          "ADD CONSTRAINT artifact_activation_history_rationale_check " <>
          "CHECK (rationale <> '')",
        "ALTER TABLE \"#{schema}\".artifact_activation_history " <>
          "DROP CONSTRAINT artifact_activation_history_rationale_check"
      )

      # Per-artifact chronological history (AC7) -- design §2.2 index 1.
      create index(
               :artifact_activation_history,
               [
                 :tenant_id,
                 :artifact_kind,
                 :artifact_name,
                 desc: :activated_at,
                 desc: :history_id
               ],
               name: :artifact_activation_history_artifact_idx,
               prefix: schema
             )

      # Tenant-wide chronological listing (AC7) -- design §2.2 index 2.
      create index(
               :artifact_activation_history,
               [desc: :activated_at, desc: :history_id],
               name: :artifact_activation_history_tenant_idx,
               prefix: schema
             )

      create index(
               :artifact_activation_history,
               [:group_id],
               name: :artifact_activation_history_group_id_idx,
               prefix: schema
             )
    end
  end
end
