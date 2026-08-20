# Letflow.Repo.Migrations.CreatePackUpdateResolutions
#
# REQ-041. Implements lib/letflow/design/req041-pack-update-diff-schema.md
# section 3.3 (the `pack_update_resolutions` table) and its one unique index.
# One row per (tenant_id, pack_id, target_version, artefact_type,
# artefact_id) -- a human/system decision resolving one conflicting artefact
# for one specific update attempt (identified by the incoming version being
# resolved against, `target_version`). Scoped per-attempt, not permanent: a
# later update to a different incoming version is a new conflict-preflight,
# not automatically pre-resolved by an earlier decision (design section 3.3,
# OQ-5).
#
# GLOBAL -- no prefix:, see REQ-041. Same classification and reasoning as
# 20260817083801_create_solution_pack_installs.exs's header -- not repeated
# here in full; see that file and Letflow.Definitions.SolutionPackInstall's
# moduledoc.
#
# tenant_id DOES carry a database-level foreign-key reference to tenants.id
# (no explicit on_delete:), same shape/reasoning as
# solution_pack_installs.tenant_id.
#
# Deliberately NO foreign key to solution_pack_installs or to
# solution_pack_artefact_bases -- design section 3.3.1, same reasoning as
# solution_pack_artefact_bases' own omission (section 3.2.1): a resolution's
# (artefact_type, artefact_id) may be the exact "no matching base row" case
# AC2 requires classify as `:conflict`, so a resolution must be insertable
# for that artefact regardless of whether an install or base row exists.
#
# No foreign key on resolved_by to users.id either (design section 3.3, OQ-7)
# -- REQ-041 names no requirement that this column be validated referentially
# against a real users.id, and adding one is unrequested scope. A pure
# judgment call, flagged for REVIEWER to override if a real FK is preferred.
#
# resolved_content is nullable :text, only meaningful when
# resolution == :merged (the merged/overridden content, same canonical-JSON
# -text contract as solution_pack_artefact_bases.base_content). Not
# CHECK-constrained to enforce the nullability-vs-resolution correlation --
# same "structural checks are an application/changeset concern" precedent
#
# resolution's Ecto.Enum atom names (:keep_local/:take_incoming/:merged, app
# layer only -- this column is a plain :string, no DB-level enum/CHECK) match
# R-Co's own ResolutionKind exactly (pack_update.zig:25-29), verified GH#324
# / ISS-0096, 2026-08-20. Originally :keep_theirs/:take_incoming/:custom
# (design section 9 OQ-6); renamed in the Ecto schema only, no schema-level
# change needed here since the column was always a plain string.
# req027/req035 already establish.
defmodule Letflow.Repo.Migrations.CreatePackUpdateResolutions do
  use Ecto.Migration

  def change do
    create table(:pack_update_resolutions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id), null: false
      add :pack_id, :string, null: false
      add :target_version, :string, null: false
      add :artefact_type, :string, null: false
      add :artefact_id, :string, null: false
      add :resolution, :string, null: false
      add :resolved_content, :text
      add :resolved_by, :binary_id, null: false
      add :resolved_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # REQ-041 design section 3.3: exactly one resolution per conflicting
    # artefact per update attempt -- this is the lookup key
    # compute_pack_update_plan/5's has_unresolved_conflicts computation
    # (AC4) queries by.
    create unique_index(
             :pack_update_resolutions,
             [:tenant_id, :pack_id, :target_version, :artefact_type, :artefact_id],
             name: :uq_pack_update_resolution
           )
  end
end
