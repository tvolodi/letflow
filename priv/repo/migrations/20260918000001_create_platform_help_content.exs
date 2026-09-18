# Letflow.Repo.Migrations.CreatePlatformHelpContent
#
# REQ-365, implementing `lib/letflow/design/req365-platform-help-authoring.md` §1
# (already CODE-DESIGN-VALIDATOR-approved) -- the platform-scope counterpart to
# REQ-364's tenant-scoped `help_content` table
# (20260917000001_create_help_content.exs). REQ-363 §3 already decided WHERE
# platform-scope help content lives: a separate table, `platform_help_content`, in
# the `public`/default Postgres schema -- this migration builds exactly that.
#
# NOT TENANT-SCOPED -- no `if prefix() do` guard anywhere in this migration, no
# `prefix:` option on the table or any index, and this migration is NOT registered
# in `Letflow.TenantProvisioning.tenant_scoped_migrations/0`. This table has exactly
# one physical copy, created once by a plain `mix ecto.migrate` against the
# default/public schema -- the same shape `20260816000001_create_tenants.exs` /
# `20260816000004_create_users.exs` already use (design §0/§1.3). Registering this
# migration in `tenant_scoped_migrations/0` would be a bug: it would replay `CREATE
# TABLE platform_help_content` once per tenant schema, which is precisely the
# platform/tenant conflation req363 §3 forbids.
#
# Column shape is `help_content`'s (req363 §1.1) verbatim, identical field list,
# different table -- no cross-referencing between the two tables (design §1.1).
# `process_definition_id` stays nullable/present for shape-parity even though the
# write path (`Letflow.Help.Platform`) rejects ever setting it today (design §3.3,
# req363 OQ-2 unresolved) -- so a future OQ-2 resolution needs no migration.
#
# `status` stored lowercase via the bare Ecto.Enum atom-list form (`:draft`/`:live`),
# same convention as `help_content.status` -- no DB-level CHECK constraint, the write
# path is the single source of truth for the allowed-value set.
#
# NO DB-level `DEFAULT NOW()` on created_at/updated_at, no `DEFAULT
# gen_random_uuid()` on `id` -- Ecto.Schema autogeneration handles both, matching
# every other Letflow table.
#
# NO foreign keys: `created_by` is a bare UUID, no `references/2` -- same
# no-FK convention `help_content.created_by`/`process_definitions.created_by`
# already use (design §1.3's "no genuine tenant-schema-crossing FK story here"
# reasoning applies a fortiori: this table is not even tenant-scoped).
defmodule Letflow.Repo.Migrations.CreatePlatformHelpContent do
  use Ecto.Migration

  def change do
    create table(:platform_help_content, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :screen_id, :string, null: false
      add :process_definition_id, :binary_id
      add :title, :string, null: false
      add :body, :text, null: false
      add :status, :string, null: false, default: "draft"
      add :confirmed_at, :utc_datetime_usec
      add :confirmed_for_definition_version, :string
      add :media, {:array, :map}, null: false, default: []
      add :created_by, :binary_id, null: false

      timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
    end

    # design §1.2 idx_platform_help_content_screen -- primary lookup pattern
    # ("platform help content for this screen").
    create index(:platform_help_content, [:screen_id], name: :idx_platform_help_content_screen)

    # design §1.2 idx_platform_help_content_process_definition -- partial index,
    # kept for shape-parity with help_content's equivalent index even though it is
    # inert today (design §3.3: no row will ever have a non-null value here until
    # req363 OQ-2 is resolved).
    create index(:platform_help_content, [:process_definition_id],
             name: :idx_platform_help_content_process_definition,
             where: "process_definition_id IS NOT NULL"
           )

    # design §1.2 idx_platform_help_content_status -- serves "list only `live`
    # content" queries.
    create index(:platform_help_content, [:status], name: :idx_platform_help_content_status)
  end
end
