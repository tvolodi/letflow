# Letflow.Repo.Migrations.CreateEntityRecordAttachments
#
# REQ-316 -- see lib/letflow/design/req313-entity-record-attachments.md §1 for
# the full design this migration implements.
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`), matching
# `instance_attachments`'s own placement (REQ-211,
# 20260901000002_create_instance_attachments.exs) -- an entity-record
# attachment is ordinary tenant business data, never shared or looked up
# cross-tenant (design §1).
#
# `content_hash` is a FK to `repository_artifacts.content_hash`
# (`on_delete: :restrict`), same shape as `instance_attachments`'s own FK --
# this table reuses the SAME shared content-addressed byte store, not a
# second one (design §2's dedup statement).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY,
# matching req211/req297's guard pattern, and this file's registration in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0 (both halves are
# mandatory -- see that module's own manifest comment).
#
# Composite FK: Ecto's `references/2` helper only emits single-column FKs, so
# the `(entity_type, record_id)` -> `entity_record_latest(entity_type,
# record_id)` FK is added via a literal `execute/1` statement. The only
# interpolated value, `schema`, is `prefix()` itself -- an Ecto
# migration-resolved, non-caller-controlled value, never tenant/user-supplied
# content (INV-7 unaffected, matching
# 20260907000001_add_entity_definitions_active_partial_index.exs's own
# precedent for this exact pattern).
#
# DEFERRABLE INITIALLY DEFERRED is load-bearing, NOT stylistic -- design §1
# traces in full why: Letflow.Entities.Record.Projector.write_snapshots/3
# (the promotion backfill path) deletes every entity_record_latest row for an
# entity_type and reinserts all of them inside ONE Repo.transaction/1. A plain
# (immediate) FK would raise on that delete_all the instant any
# entity_record_attachments row exists for the entity type being rebuilt.
# Deferring the check to transaction commit lets the reinsert complete first,
# and design §1 traces four properties of write_snapshots/3 (single
# transaction, complete-snapshot-list-only invocation, deleted rows persisted
# not omitted, mid-loop failure never reaching commit) that guarantee the full
# key set is always restored before commit -- do not simplify this to a plain
# FK.
defmodule Letflow.Repo.Migrations.CreateEntityRecordAttachments do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      create table(:entity_record_attachments, primary_key: false, prefix: schema) do
        add :id, :binary_id, primary_key: true
        add :tenant_id, :binary_id, null: false
        add :entity_type, :string, null: false
        add :record_id, :binary_id, null: false

        add :content_hash,
            references(:repository_artifacts,
              column: :content_hash,
              type: :binary,
              on_delete: :restrict,
              prefix: schema
            ),
            null: false

        add :file_name, :string, size: 255, null: false
        add :content_type, :string, null: false
        add :byte_size, :bigint, null: false
        add :uploaded_by, :binary_id, null: false
        add :description, :text
        add :scan_status, :string, null: false, default: "pending"

        timestamps(updated_at: false, inserted_at: :created_at, type: :utc_datetime_usec)
      end

      # design §1 -- the primary access pattern (list/2 filtered by
      # entity_type + record_id), newest-first. Explicit `name:` per the
      # NAMEDATALEN-collision hazard other migrations in this manifest already
      # document -- well under Postgres's 63-byte limit.
      create index(
               :entity_record_attachments,
               [:entity_type, :record_id, desc: :created_at],
               name: :entity_record_attachments_type_record_created_at_idx,
               prefix: schema
             )

      # design §1 -- resolving which attachments reference a given content
      # row, matching instance_attachments's own second index.
      create index(:entity_record_attachments, [:content_hash], prefix: schema)

      # Composite FK -- see this file's header comment for the full
      # DEFERRABLE INITIALLY DEFERRED rationale (design §1). Backed by
      # entity_record_latest's own composite unique index
      # (entity_record_latest_entity_type_record_id_idx, created by
      # 20260906010001_create_entity_record_latest.exs) -- Postgres permits a
      # FK to target any column set covered by a unique index, not only a
      # primary key.
      # execute/2 (not execute/1) so this whole migration stays reversible
      # under `change/0` -- `mix ecto.rollback` runs the down statement
      # explicitly rather than failing with "the execute/1 command is
      # currently not reversible". Dropping the table (also reversed by this
      # same `change/0`, in the correct reverse order) would drop this
      # constraint anyway, but stating an explicit down keeps this step
      # independently reversible regardless of ordering.
      execute(
        """
        ALTER TABLE #{schema}.entity_record_attachments
          ADD CONSTRAINT entity_record_attachments_record_fkey
          FOREIGN KEY (entity_type, record_id)
          REFERENCES #{schema}.entity_record_latest (entity_type, record_id)
          DEFERRABLE INITIALLY DEFERRED
        """,
        """
        ALTER TABLE #{schema}.entity_record_attachments
          DROP CONSTRAINT entity_record_attachments_record_fkey
        """
      )
    end
  end
end
