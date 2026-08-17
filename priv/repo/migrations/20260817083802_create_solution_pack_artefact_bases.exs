# Letflow.Repo.Migrations.CreateSolutionPackArtefactBases
#
# REQ-041. Implements lib/letflow/design/req041-pack-update-diff-schema.md
# section 3.2 (the `solution_pack_artefact_bases` table) and its one unique
# index. One row per (tenant_id, pack_id, artefact_type, artefact_id) -- the
# base (installed-at-Vb) content snapshot for one artefact within one
# tenant's install of one pack; the `base` side of the three-way diff
# Letflow.Definitions.compute_pack_update_plan/5 computes.
#
# GLOBAL -- no prefix:, see REQ-041. Same classification and reasoning as
# 20260817083801_create_solution_pack_installs.exs's header -- not repeated
# here in full; see that file and Letflow.Definitions.SolutionPackInstall's
# moduledoc.
#
# tenant_id DOES carry a database-level foreign-key reference to tenants.id
# (no explicit on_delete:), same shape/reasoning as
# solution_pack_installs.tenant_id. Present here (not just derivable via a
# join) so a base lookup by compute_pack_update_plan/5 is a direct
# single-table indexed query.
#
# Deliberately NO foreign key to solution_pack_installs -- design section
# 3.2.1. REQ-041 acceptance criterion 2 requires that an artefact with no
# matching solution_pack_artefact_bases row classify as `:conflict`, including
# the case where NO solution_pack_installs row exists at all for the
# (tenant_id, pack_id) pair. A mandatory FK to solution_pack_installs.id would
# make that exact scenario un-representable (no base/resolution row could ever
# exist without a parent install row), so this table is keyed directly by the
# natural key (tenant_id, pack_id, ...) instead, keeping it independently
# insertable via fixture rows without first constructing a
# solution_pack_installs row.
#
# base_content is :text, not jsonb -- canonical-JSON byte-stability (sorted
# keys, no insignificant whitespace) is exactly what jsonb's storage-time
# re-normalization would silently undermine (design section 3.2, section 5.2).
# Caller contract: this column's value MUST already be canonical-JSON text by
# the time it is written -- this requirement does not itself provide the
# canonicalization step (design section 5.4, OQ-1).
defmodule Letflow.Repo.Migrations.CreateSolutionPackArtefactBases do
  use Ecto.Migration

  def change do
    create table(:solution_pack_artefact_bases, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id), null: false
      add :pack_id, :string, null: false
      add :artefact_type, :string, null: false
      add :artefact_id, :string, null: false
      add :base_version, :string, null: false
      add :base_content, :text, null: false
      add :captured_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # REQ-041 design section 3.2: exactly one current base per artefact per
    # tenant+pack -- this is the lookup key compute_pack_update_plan/5 queries
    # by, and it is also the row whose *absence* AC2 requires be classified
    # `:conflict`.
    create unique_index(
             :solution_pack_artefact_bases,
             [:tenant_id, :pack_id, :artefact_type, :artefact_id],
             name: :uq_solution_pack_artefact_base
           )
  end
end
