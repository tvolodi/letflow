# Letflow.Repo.Migrations.CreateInstanceDefinitionSnapshots
#
# REQ-027, migration 2 of 2. Implements
# lib/letflow/design/req027-definition-core-schema.md section 3.2 (the
# `instance_definition_snapshots` table). Ported from R-Co
# migrations/004_definitions.sql:59-69 per src/design/definition.md's PD-08 section.
#
# MUST SORT AFTER 20260816193001_create_process_definitions.exs -- it carries a foreign
# key to `process_definitions`.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY. See
# lib/letflow/design/req022-tenant-schema-provisioning.md section 4 and
# 20260816120001_create_events.exs's header for the full rationale. Registered in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both halves are mandatory.
#
# THE FOREIGN KEY CARRIES NO `ON DELETE` CLAUSE AT ALL -- REQ-027 acceptance criterion
# 4, and the whole point of this table. `on_delete: :nothing` is the %Reference{}
# struct default (deps/ecto_sql/lib/ecto/migration.ex:514) and falls through
# `reference_on_delete/1`'s catch-all `reference_on_delete(_), do: []`
# (deps/ecto_sql/lib/ecto/adapters/postgres/connection.ex:1918), so the emitted DDL
# omits ON DELETE entirely -- Postgres's default NO ACTION, byte-identical to R-Co's
# original 004:61 as R-Co's own later migration confirms ("declared `definition_id UUID
# NOT NULL REFERENCES process_definitions(id)` with the default NO ACTION referential
# action", 1106_iss0125_instance_definition_snapshots_cascade.sql:4-6). It is written
# explicitly rather than omitted because AC 4 is precisely about the absence being
# DELIBERATE: an omitted option reads as an oversight, a written `:nothing` reads as a
# decision.
#
# R-Co ITSELF LATER REPLACED THIS FK WITH AN `ON DELETE CASCADE` VARIANT in
# migrations/1106_iss0125_instance_definition_snapshots_cascade.sql:78-88, for a
# test-harness cleanup-ordering reason its own header states ("bespoke per-test cleanup
# helpers that swallowed SQL errors", 1106:8-12) -- and that migration directly
# contradicts PD-08's design text (definition.md:2051-2059). Letflow follows PD-08 and
# does NOT port 1106. Recorded here because a future agent cross-checking Letflow
# against R-Co's LIVE schema will find a cascade there and could "fix" Letflow into
# data loss. See design section 10 C-1.
#
# `type: :binary_id` on references/2 is MANDATORY, not stylistic: %Reference{}'s
# default type is `:bigserial` (migration.ex:513), which the adapter renders as
# `bigint` (connection.ex:1902) and which would fail against a uuid primary key.
# `column: :id` is the struct default (migration.ex:512) but is written explicitly,
# matching 20260816120004_create_event_payload_store.exs:68. The call takes NO :prefix
# option -- a %Reference{} with none falls back to the referencing table's own prefix
# (connection.ex:1872), so the FK resolves to "<tenant_schema>"."process_definitions"
# automatically. The resulting constraint name is Ecto's default
# `"#{table.name}_#{column}_fkey"` (connection.ex:1895-1896) =
# instance_definition_snapshots_definition_id_fkey, byte-identical to R-Co's
# (1106:80, 85).
#
# WHY `:nothing` AND NOT REQ-023's `:restrict` (a deliberate divergence from the
# sibling design, design section 3.2.3): REQ-023 chose :restrict for
# event_payload_store as a CORRECTION to R-Co's CASCADE. No correction is needed here
# -- R-Co's original, design-doc-endorsed shape for THIS FK is already NO ACTION, which
# is already the behaviour PD-08 wants. NO ACTION and RESTRICT both reject a DELETE of
# a referenced parent row; they differ only in deferrability, and nothing in REQ-027,
# REQ-030 or REQ-033 asks for a deferred check.
#
# NO FOREIGN KEY ON `instance_id`, deliberately (design section 3.2.4 / 10 C-7).
# definition.md:362 calls it "FK to process_instances.id", which is wrong twice over:
# 004:60 declares a bare `UUID PRIMARY KEY` with no REFERENCES clause, and no
# `process_instances` table exists in R-Co at all (verified by search across all 146
# migrations/*.sql). Beyond the missing table, an FK here would be actively wrong:
# PD-08's EE-01 contract requires SnapshotStore.create() to run BEFORE the
# InstanceStarted event is appended (definition.md:2069-2081), so a snapshot row can
# legitimately precede any instance row.
#
# NO `timestamps/1` AND NO `tenant_id`, both deliberate. REQ-027: "No
# updated_at/timestamps() beyond snapshotted_at -- the table is write-once per PD-08";
# an updated_at on a write-once table would be actively misleading, and R-Co has none
# either (004:59-66). `tenant_id` is omitted because adp-02's own table mapping lists
# process_definitions, instance_projections, tasks, tokens, audit_entries and audit_log
# -- not this table -- and 028_adp02:15-31 correspondingly adds the column to those six
# and not to this one; snapshot.zig:155-184's real INSERT writes no tenant column.
#
# `graph` has NO DEFAULT here, unlike process_definitions.graph (004:64 is a bare
# `JSONB NOT NULL`). Deliberate: a snapshot is always a copy of a real definition's
# graph, so an empty-graph default would mask a capture bug.
#
# `snapshotted_at`'s default is `(now() AT TIME ZONE 'utc')` rather than R-Co's bare
# `NOW()` (004:65) so an implicit timestamptz -> timestamp cast can never pick up the
# session's local time zone -- the identical mitigation REQ-023 applied. R-Co's INSERT
# omits the column and reads it back via RETURNING (definition.md:1995-2006); the
# schema module does the same via `read_after_writes: true`.
defmodule Letflow.Repo.Migrations.CreateInstanceDefinitionSnapshots do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:instance_definition_snapshots, primary_key: false, prefix: prefix()) do
        add :instance_id, :binary_id, primary_key: true

        add :definition_id,
            references(:process_definitions,
              column: :id,
              type: :binary_id,
              on_delete: :nothing
            ),
            null: false

        add :definition_name, :string, null: false
        add :definition_ver, :string, null: false
        add :graph, :map, null: false

        add :snapshotted_at, :utc_datetime_usec,
          null: false,
          default: fragment("(now() AT TIME ZONE 'utc')")
      end

      # 004:68-69, verbatim. Load-bearing, not decorative: Postgres does not
      # automatically index the REFERENCING side of a foreign key, so without this every
      # DELETE FROM process_definitions must sequentially scan this table to evaluate the
      # FK's NO ACTION check. REQ-033 AC 4 exercises exactly that delete path.
      create index(:instance_definition_snapshots, [:definition_id],
               name: :idx_snap_definition,
               prefix: prefix()
             )
    end
  end
end
