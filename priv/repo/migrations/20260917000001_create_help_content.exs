# Letflow.Repo.Migrations.CreateHelpContent
#
# REQ-364, implementing the schema `lib/letflow/design/req363-help-content-data-model.md`
# §1 already designed and CODE-DESIGN-VALIDATOR-approved (REQ-363). This migration builds
# only the tenant-scoped `help_content` table (§1) — `platform_help_content` (§3) is
# explicitly out of REQ-364's own acceptance criteria (which name only the tenant-scoped
# `Letflow.Help` context module) and is left for REQ-365, whose own write path needs it to
# exist and is the natural place to add it alongside that path.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, matching
# 20260816193001_create_process_definitions.exs's own header. Registered in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both halves are mandatory: a
# guarded-but-unregistered migration is inert forever, a registered-but-unguarded one
# corrupts `public` on every plain `mix ecto.migrate` run.
#
# `status` stored lowercase via the bare Ecto.Enum atom-list form (`:draft`/`:live`),
# matching `process_definitions.status`'s own documented convention -- no DB-level CHECK
# constraint, the write path (Letflow.Help.HelpContent changesets) is the single source of
# truth for the allowed-value set, exactly as design §1.2 states.
#
# NO DB-level `DEFAULT NOW()` on created_at/updated_at, no `DEFAULT gen_random_uuid()` on
# `id` -- Ecto.Schema autogeneration handles both, matching every other Letflow table.
#
# NO foreign keys: `process_definition_id` and `created_by` are bare UUIDs, no
# `references/2` -- same convention as `process_definitions.created_by` (design §0):
# cross-table FK enforcement within one tenant schema is not this codebase's existing
# convention for this shape, and `created_by` references `users`, which lives outside this
# tenant's own migration-managed table set. Application-level: `Letflow.Help`'s write path
# validates `process_definition_id` against a real `process_definitions` row before
# insert/update (design §1.1 row 3).
defmodule Letflow.Repo.Migrations.CreateHelpContent do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:help_content, primary_key: false, prefix: prefix()) do
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

      # design §1.2 idx_help_content_screen -- primary lookup pattern ("help content for
      # this screen").
      create index(:help_content, [:screen_id], name: :idx_help_content_screen, prefix: prefix())

      # design §1.2 idx_help_content_process_definition -- partial index, mirroring
      # process_definitions.idx_def_stage's partial-index-on-nullable-column convention.
      create index(:help_content, [:process_definition_id],
               name: :idx_help_content_process_definition,
               where: "process_definition_id IS NOT NULL",
               prefix: prefix()
             )

      # design §1.2 idx_help_content_status -- serves "list only `live` content" queries.
      create index(:help_content, [:status], name: :idx_help_content_status, prefix: prefix())
    end
  end
end
