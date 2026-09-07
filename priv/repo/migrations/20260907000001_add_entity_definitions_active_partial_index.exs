# Letflow.Repo.Migrations.AddEntityDefinitionsActivePartialIndex
#
# ISS-0519 fix (C) -- see
# lib/letflow/design/iss0519-entity-definition-versioning-fix.md §5.2/§5.4
# for the full design this migration implements.
#
# PLACEMENT: `entity_definitions` is a per-tenant table (schema-per-tenant
# via `prefix()`), same as `20260906000001_create_entity_definitions.exs` --
# the `if prefix() do` guard below is MANDATORY, matching that migration's
# own guard pattern and this file's registration in
# `Letflow.TenantProvisioning`'s tenant-scoped migration manifest.
#
# WHAT THIS ADDS: a partial unique index `(tenant_id, name) WHERE status =
# 'active'`, DB-enforcing "at most one active `entity_definitions` row per
# name" -- the real invariant `Letflow.Entities.Definitions.activate_definition/4`
# only ever *intended* before this fix (design §5.1's demote-then-promote
# sequencing is what keeps this index from ever being even transiently
# violated by that function).
#
# PRE-MIGRATION DATA-INTEGRITY REMEDIATION (design §5.4, OQ-1): before
# creating the index, `up/0` first demotes every `entity_definitions` row
# EXCEPT the most-recently-activated one (per `(tenant_id, name)`) back to
# `status = 'inactive'`, so a tenant schema that already has 2+
# simultaneously-`:active` rows under one name (the exact latent-corruption
# state `activate_definition/4`'s pre-fix demote-less code path could leave
# behind, per ISS-0519's diagnosis item 4) does not make the `CREATE UNIQUE
# INDEX` below fail outright. "Most recently activated" is read from
# `artifact_activation_history` (REQ-203's own append-only source of truth
# for activation recency), joined on `(artifact_kind = 'entity',
# artifact_name = entity_definitions.name, new_version_id =
# entity_definitions.artifact_version_id)` -- falling back to
# `entity_definitions.inserted_at` for any `:active` row with no matching
# history row (should not occur under the current data model, but a
# `LEFT JOIN LATERAL` degrades gracefully to insertion-order rather than
# crashing the migration on that edge case). This remediation is a no-op
# (touches zero rows) on any tenant schema whose `entity_definitions.status`
# was never allowed to drift, which is the expected case for every tenant
# provisioned to date -- the bug this fixes is a gap on the demotion PATH,
# not a currently-populated bad state confirmed present in any real tenant
# (design §5.4).
#
# This is a genuinely irreversible data-mutating step (there is no record of
# which rows were `:active` before remediation ran, if any were), so this
# migration uses `up/0`/`down/0` rather than `change/0` -- same idiom as
# `20260819000004_drop_legacy_public_identity_tables.exs`'s own
# data-dependent cutover step. `down/0` only drops the index; it does not
# (and cannot) undo the remediation UPDATE.
#
# No SQL string below interpolates tenant- or user-controlled data (INV-7)
# -- `schema` is the already-trusted `prefix()` schema-name value Ecto
# itself resolves for this migration run (same discipline as
# `20260831000001_create_artifact_activations.exs`'s own raw `execute/2`
# calls), not caller/tenant-supplied content. `entity_kind`/`status` string
# literals below are fixed, migration-authored constants.
defmodule Letflow.Repo.Migrations.AddEntityDefinitionsActivePartialIndex do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      WITH ranked AS (
        SELECT
          ed.id,
          ROW_NUMBER() OVER (
            PARTITION BY ed.tenant_id, ed.name
            ORDER BY COALESCE(h.last_activated_at, ed.inserted_at) DESC,
                     ed.inserted_at DESC,
                     ed.id DESC
          ) AS rn
        FROM "#{schema}".entity_definitions ed
        LEFT JOIN LATERAL (
          SELECT MAX(ah.activated_at) AS last_activated_at
          FROM "#{schema}".artifact_activation_history ah
          WHERE ah.artifact_kind = 'entity'
            AND ah.artifact_name = ed.name
            AND ah.new_version_id = ed.artifact_version_id
        ) h ON TRUE
        WHERE ed.status = 'active'
      )
      UPDATE "#{schema}".entity_definitions
      SET status = 'inactive'
      WHERE id IN (SELECT id FROM ranked WHERE rn > 1)
      """)

      create unique_index(
               :entity_definitions,
               [:tenant_id, :name],
               where: "status = 'active'",
               name: :entity_definitions_tenant_name_active_idx,
               prefix: schema
             )
    end
  end

  def down do
    if prefix() do
      drop_if_exists(
        index(:entity_definitions, [:tenant_id, :name],
          name: :entity_definitions_tenant_name_active_idx,
          prefix: prefix()
        )
      )
    end
  end
end
