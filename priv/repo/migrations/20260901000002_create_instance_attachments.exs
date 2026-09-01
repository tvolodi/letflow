# Letflow.Repo.Migrations.CreateInstanceAttachments
#
# REQ-211 -- see lib/letflow/design/req211-instance-attachments-core.md §1/§2
# for the full design this migration implements.
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`), NOT global,
# matching Decision B (`docs/migration/decisions/0003-ecto-schema-strategy.md`)
# -- an attachment is ordinary tenant business data (a document a tenant's
# user attached to that tenant's own workflow instance), the same placement
# `dlq_entries` (REQ-176) and `webhook_subscriptions` (REQ-181) already use.
# Unlike `repository_artifacts` (REQ-202), whose per-tenant-vs-global question
# was genuinely debated because it is a content-addressed dedup store, no such
# question applies here: `instance_attachments` rows are never shared or
# looked up across tenants under any circumstance (design §1.1).
#
# `content_hash` is a FK to `repository_artifacts.content_hash`
# (`on_delete: :restrict`), same shape as `artifact_versions`'s own FK in the
# REQ-202 migration -- this table reuses REQ-202's byte store rather than
# duplicating content storage, and does NOT modify `repository_artifacts`'s
# own schema (that is this requirement's separate §2A addendum migration,
# 20260901000001_add_content_to_repository_artifacts.exs).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY,
# matching req195/req027/req202's guard pattern, and this file's registration
# in Letflow.TenantProvisioning.tenant_scoped_migrations/0 (both halves are
# mandatory -- see that module's own manifest comment).
#
# No SQL below interpolates tenant- or user-controlled data (INV-7) -- every
# statement is Ecto migration DSL, scoped only by the already-trusted
# `prefix()` schema-name value Ecto itself resolves for this migration run. No
# raw `execute/2` SQL is needed -- this table has no DB-level immutability
# trigger (design §1.4): it is ordinary tenant business data with a normal
# delete path (`delete/2`), not a content-addressed store.
defmodule Letflow.Repo.Migrations.CreateInstanceAttachments do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      create table(:instance_attachments, primary_key: false, prefix: schema) do
        add :id, :binary_id, primary_key: true
        add :tenant_id, :binary_id, null: false
        add :instance_id, :binary_id, null: false

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

        timestamps(updated_at: false, inserted_at: :created_at, type: :utc_datetime_usec)
      end

      # design §1.3 index 1 -- the primary access pattern (list/2 filtered by
      # instance_id), newest-first. Explicit `name:` per the same
      # NAMEDATALEN-collision hazard req202's migration comment documents --
      # checked below to be well under Postgres's 63-byte limit.
      create index(
               :instance_attachments,
               [:instance_id, desc: :created_at],
               name: :instance_attachments_instance_id_created_at_idx,
               prefix: schema
             )

      # design §1.3 index 2 -- resolving which attachments reference a given
      # content row (delete/2's AC7 demonstration query).
      create index(:instance_attachments, [:content_hash], prefix: schema)
    end
  end
end
