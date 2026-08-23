# Letflow.Repo.Migrations.AddSequenceNumberToProcessDefinitions
#
# REQ-125, migration 1 of 2. Implements
# lib/letflow/design/req125-definitions-delta-sync.md section 5.1 (the
# `process_definitions.sequence_number` column + its `idx_def_sequence_number`
# index) -- the MOB-3 `GET /definitions/delta` backend gap. New work; no R-Co
# source to port (design doc's own section 0/9).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY. See
# lib/letflow/design/req022-tenant-schema-provisioning.md section 4 and
# 20260816120001_create_events.exs's header for the full rationale. Registered in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both halves are mandatory.
#
# `default: 0` only sets the value for rows that exist at migration time (none --
# process_definitions has no production data yet in any environment this pipeline runs
# against) and satisfies `null: false` for the `add` statement itself. Every row
# inserted by Letflow.Definitions.create/2 from this point forward gets a real assigned
# value from `definition_sequence` (see the next migration), never the literal default
# -- design doc section 5.1.
#
# The index serves the delta query's own access path
# (`WHERE sequence_number > $1 ORDER BY sequence_number ASC`, design doc section 7):
# without it every delta call is a full sequential scan of the tenant's entire
# definition table.
defmodule Letflow.Repo.Migrations.AddSequenceNumberToProcessDefinitions do
  use Ecto.Migration

  def change do
    if prefix() do
      alter table(:process_definitions, prefix: prefix()) do
        add :sequence_number, :bigint, null: false, default: 0
      end

      create index(:process_definitions, [:sequence_number],
               name: :idx_def_sequence_number,
               prefix: prefix()
             )
    end
  end
end
