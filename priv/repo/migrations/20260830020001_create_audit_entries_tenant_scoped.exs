# Letflow.Repo.Migrations.CreateAuditEntriesTenantScoped
#
# REQ-195 (OBS-03, XC-02) -- see lib/letflow/design/req195-audit-entry-storage.md
# for the full design this migration implements (§1 schema, §2 immutability).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY,
# matching lib/letflow/design/req022-tenant-schema-provisioning.md section 4's
# guard pattern, and this file's registration in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0 (both halves are
# mandatory -- see that module's own manifest comment). `audit_entries` lives
# in each tenant's own Postgres schema, per Decision 0003-B.
#
# DECISION 1 (design §1.2) -- `resource_id` is `:string` (PG `text`), NOT
# `:uuid`/`binary_id`. Every resource type this requirement covers today
# (process_definitions.id, tasks.id, users.id, groups.id, api_tokens.id, and
# the engine-side instance id) is itself a UUID, but R-Co declared this same
# column `UUID` and later had to widen it to `TEXT` in some schemas but not
# others -- a leftover `::uuid` cast on an un-widened path made every filtered
# `/audit` call fail in production once a non-UUID resource type appeared
# (src/obs/audit.zig L123-127). A UUID's canonical string form round-trips
# through `:string` with zero information loss and no query-shape cost, and
# declaring `:string` now forecloses that exact failure class permanently, at
# zero cost today, for any future resource type with a non-UUID natural key.
# `resource_type` is likewise plain `:string`, not a closed `Ecto.Enum` --
# both columns are deliberately kept open for resource kinds this requirement
# doesn't yet cover (design §1.1/§1.2).
#
# IMMUTABILITY (design §2) -- enforced in the DATABASE, not by Ecto changeset
# validation: a BEFORE UPDATE and a BEFORE DELETE trigger, both raising a
# fixed exception ("audit_entries is immutable" -- same message text R-Co
# uses), installed inside this same tenant-schema-guarded migration so every
# tenant schema gets its own copy of the trigger function (no shared
# `public`-schema trigger function to reference across schemas, per Decision
# 0003-B's physical-isolation model). This is the one place in this migration
# that uses raw SQL via `execute/1` inside the `Ecto.Migration` DSL -- the
# escape hatch Decision 0003-A names for "anything the DSL can't express
# directly." No SQL string here interpolates tenant- or user-controlled data
# (INV-7) -- every statement is a fixed, migration-authored literal, scoped
# only by the already-trusted `prefix()` schema-name value Ecto itself
# resolves for this migration run.
defmodule Letflow.Repo.Migrations.CreateAuditEntriesTenantScoped do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:audit_entries, primary_key: false, prefix: prefix()) do
        add :id, :binary_id, primary_key: true
        add :tenant_id, :binary_id, null: false
        add :actor_id, :binary_id
        add :action, :string, null: false
        add :resource_type, :string, null: false
        # :string (PG text), not :uuid -- Decision 1 above.
        add :resource_id, :string, null: false
        add :timestamp, :utc_datetime_usec, null: false
        add :before_state, :map
        add :after_state, :map
        add :trace_id, :string
        add :chain_hash, :string, null: false
        add :prev_chain_hash, :string

        timestamps(updated_at: false)
      end

      create index(:audit_entries, [desc: :timestamp, desc: :id], prefix: prefix())

      create index(:audit_entries, [:actor_id, desc: :timestamp, desc: :id], prefix: prefix())

      create index(:audit_entries, [:resource_type, :resource_id, desc: :timestamp, desc: :id],
               prefix: prefix()
             )

      schema = prefix()

      execute(
        """
        CREATE OR REPLACE FUNCTION "#{schema}".audit_entries_immutable() RETURNS trigger AS $$
        BEGIN
          RAISE EXCEPTION 'audit_entries is immutable';
        END;
        $$ LANGUAGE plpgsql
        """,
        """
        DROP FUNCTION IF EXISTS "#{schema}".audit_entries_immutable()
        """
      )

      execute(
        """
        CREATE TRIGGER audit_entries_no_update
          BEFORE UPDATE ON "#{schema}".audit_entries
          FOR EACH ROW EXECUTE FUNCTION "#{schema}".audit_entries_immutable()
        """,
        """
        DROP TRIGGER IF EXISTS audit_entries_no_update ON "#{schema}".audit_entries
        """
      )

      execute(
        """
        CREATE TRIGGER audit_entries_no_delete
          BEFORE DELETE ON "#{schema}".audit_entries
          FOR EACH ROW EXECUTE FUNCTION "#{schema}".audit_entries_immutable()
        """,
        """
        DROP TRIGGER IF EXISTS audit_entries_no_delete ON "#{schema}".audit_entries
        """
      )
    end
  end
end
