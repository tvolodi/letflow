# Letflow.Repo.Migrations.CreateRepositoryArtifacts
#
# REQ-202 (REPO-01/02/03/04) -- see
# lib/letflow/design/req202-artifact-repository.md for the full design this
# migration implements (§1 placement, §2 schema, §5 immutability).
#
# PLACEMENT (AC10): both `repository_artifacts` and `artifact_versions` are
# created PER-TENANT (schema-per-tenant via `prefix()`), NOT global. Reason,
# condensed from design §1: `repository_artifacts.content_hash` is this
# store's dedup mechanism (primary key = content_hash), and cross-tenant
# content dedup is only possible if the table is global -- but no acceptance
# criterion of REQ-202 requires cross-tenant deduplication, and
# 0003-ecto-schema-strategy.md Decision B's own rationale is a
# blast-radius-containment argument ("a bug that forgets a tenant_id/schema
# predicate fails loudly instead of silently leaking rows across tenants"),
# not a storage-efficiency one -- a global content-addressed store built so
# two tenants' bytes can share one physical row is exactly the isolation
# model Decision B exists to avoid. No REVIEWER sign-off flag is raised: this
# follows Decision B rather than diverging from it. See the design doc's §1
# for the full reasoning this comment condenses.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY,
# matching req195/req027's guard pattern, and this file's registration in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0 (both halves are
# mandatory -- see that module's own manifest comment).
#
# R-CO MIGRATION-058-VS-045 SHAPE CONFLICT (AC11): R-Co's migration
# 058_repo_artifacts_tenant_activation.sql re-creates `repository_artifacts`
# with a COMPLETELY DIFFERENT shape from migration 045
# (`version_id` as primary key rather than `content_hash`, `content_hash`
# typed TEXT rather than BYTEA, an inline `content_json` column, no
# byte_size/content_type columns), both guarded by `CREATE TABLE IF NOT
# EXISTS` -- a real R-Co defect, not a design choice, since which shape a
# given R-Co database ends up with then depends on migration-application
# order and prior database state. Letflow ships exactly ONE shape: migration
# 045's, the one `src/repository/artifacts.zig` actually codes against. This
# statement is also carried in `Letflow.Repository.Artifact`'s moduledoc
# (AC11's own moduledoc-level requirement, distinct from this migration-file
# comment, which is AC10's).
#
# IMMUTABILITY (design §5) -- enforced in the DATABASE, not by Ecto
# changeset validation, same mechanism req195's audit_entries migration
# uses: a BEFORE UPDATE (and, for repository_artifacts only, BEFORE DELETE)
# trigger raising a fixed exception, installed inside this same
# tenant-schema-guarded migration so every tenant schema gets its own copy
# of each trigger function (no shared `public`-schema function, per Decision
# 0003-B's physical-isolation model). `repository_artifacts` rejects both
# UPDATE and DELETE (content-addressed store, never legitimately mutated or
# removed once written -- design §5.1). `artifact_versions` rejects UPDATE
# only; DELETE is governed by `parent_version_id`'s self-FK
# (`on_delete: :nilify_all`) instead of a blanket trigger, since this
# requirement's own context API never exposes a delete path for either table
# and a future retention-policy purge job (out of this requirement's scope)
# is expected to delete individual version rows without being blocked
# (design §5.2).
#
# No SQL string below interpolates tenant- or user-controlled data (INV-7)
# -- every statement is a fixed, migration-authored literal, scoped only by
# the already-trusted `prefix()` schema-name value Ecto itself resolves for
# this migration run.
defmodule Letflow.Repo.Migrations.CreateRepositoryArtifacts do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      create table(:repository_artifacts, primary_key: false, prefix: schema) do
        # SHA-256 of the canonical content (32 raw bytes), computed by
        # Letflow.Repository.Canonicaliser -- not Postgres-generated. Being
        # the primary key of a per-tenant table is what makes
        # byte-identical content within one tenant's schema exactly one row
        # (REPO-01's dedup), by construction.
        add :content_hash, :binary, primary_key: true
        add :tenant_id, :binary_id, null: false
        add :content_type, :string, null: false
        add :byte_size, :bigint, null: false

        timestamps(updated_at: false)
      end

      create table(:artifact_versions, primary_key: false, prefix: schema) do
        add :version_id, :binary_id, primary_key: true
        add :tenant_id, :binary_id, null: false
        add :artifact_id, :binary_id, null: false
        add :artifact_kind, :string, null: false
        add :artifact_name, :string, size: 255, null: false
        add :version_number, :bigint, null: false

        add :content_hash,
            references(:repository_artifacts,
              column: :content_hash,
              type: :binary,
              on_delete: :restrict,
              prefix: schema
            ),
            null: false

        add :parent_version_id,
            references(:artifact_versions,
              column: :version_id,
              type: :binary_id,
              on_delete: :nilify_all,
              prefix: schema
            )

        add :created_by, :binary_id, null: false
        add :description, :text

        timestamps(updated_at: false)
      end

      # Explicit, short, distinct names for both indexes below: Ecto's
      # default index-naming derives a name from the column list alone and
      # strips `desc:` annotations when doing so, so the unique_index/3 and
      # index/3 calls that follow would otherwise both generate the SAME
      # 66-byte name (`artifact_versions_artifact_kind_artifact_name_version_number_index`)
      # -- which both collides between the two indexes AND exceeds
      # Postgres's 63-byte NAMEDATALEN limit (silently truncated), the
      # latter also breaking `Letflow.Repository.ArtifactVersion.changeset/2`'s
      # `unique_constraint/3` name match (design §4.4's concurrency-retry
      # contract). Both names below are given explicitly and kept well
      # under 63 bytes so neither problem can recur.
      create unique_index(
               :artifact_versions,
               [:artifact_kind, :artifact_name, :version_number],
               name: :artifact_versions_kind_name_number_idx,
               prefix: schema
             )

      create index(
               :artifact_versions,
               [:artifact_kind, :artifact_name, desc: :version_number],
               name: :artifact_versions_kind_name_number_desc_idx,
               prefix: schema
             )

      create index(:artifact_versions, [:content_hash], prefix: schema)

      execute(
        """
        CREATE OR REPLACE FUNCTION "#{schema}".repository_artifacts_immutable() RETURNS trigger AS $$
        BEGIN
          RAISE EXCEPTION 'repository_artifacts is immutable';
        END;
        $$ LANGUAGE plpgsql
        """,
        """
        DROP FUNCTION IF EXISTS "#{schema}".repository_artifacts_immutable()
        """
      )

      execute(
        """
        CREATE TRIGGER repository_artifacts_no_update
          BEFORE UPDATE ON "#{schema}".repository_artifacts
          FOR EACH ROW EXECUTE FUNCTION "#{schema}".repository_artifacts_immutable()
        """,
        """
        DROP TRIGGER IF EXISTS repository_artifacts_no_update ON "#{schema}".repository_artifacts
        """
      )

      execute(
        """
        CREATE TRIGGER repository_artifacts_no_delete
          BEFORE DELETE ON "#{schema}".repository_artifacts
          FOR EACH ROW EXECUTE FUNCTION "#{schema}".repository_artifacts_immutable()
        """,
        """
        DROP TRIGGER IF EXISTS repository_artifacts_no_delete ON "#{schema}".repository_artifacts
        """
      )

      execute(
        """
        CREATE OR REPLACE FUNCTION "#{schema}".artifact_versions_immutable() RETURNS trigger AS $$
        BEGIN
          RAISE EXCEPTION 'artifact_versions is immutable';
        END;
        $$ LANGUAGE plpgsql
        """,
        """
        DROP FUNCTION IF EXISTS "#{schema}".artifact_versions_immutable()
        """
      )

      execute(
        """
        CREATE TRIGGER artifact_versions_no_update
          BEFORE UPDATE ON "#{schema}".artifact_versions
          FOR EACH ROW EXECUTE FUNCTION "#{schema}".artifact_versions_immutable()
        """,
        """
        DROP TRIGGER IF EXISTS artifact_versions_no_update ON "#{schema}".artifact_versions
        """
      )
    end
  end
end
