defmodule Letflow.Definitions.PackUpdateResolution do
  @moduledoc """
  Ecto schema for the `pack_update_resolutions` table. See
  `lib/letflow/design/req041-pack-update-diff-schema.md` §3.3.

  The design (§1) calls this out as a "changeset-only module for the third
  [table]" — §5 documents `SolutionPackInstall` (§5.1) and
  `SolutionPackArtefactBase` (§5.2) in full but does not give this module its
  own numbered subsection beyond the table spec in §3.3. This module's shape
  (field list, changeset name, association style) follows §3.3's column spec
  directly and mirrors `SolutionPackArtefactBase`'s own choices (§5.2): a plain
  `field(:tenant_id, Ecto.UUID)`, no `belongs_to`, since this table is always
  looked up by its composite `(tenant_id, pack_id, target_version,
  artefact_type, artefact_id)` unique key
  (`Letflow.Definitions.compute_pack_update_plan/5`'s `has_unresolved_conflicts`
  lookup, design §5.3), never traversed via a `Tenant` struct.

  ## Scope — this requirement builds schema only

  See `Letflow.Definitions.SolutionPackInstall`'s moduledoc's scope note. This
  table's own write path — "the actual conflict-resolution UI/API flow" that
  inserts a resolution row — is explicitly out of REQ-041's scope (design §1's
  "Not built here" table); REQ-041 only *reads* this table (via
  `Letflow.Definitions.compute_pack_update_plan/5`) to compute
  `has_unresolved_conflicts`. `insert_changeset/2` below exists as scaffolding
  for that future write path, the same way `SolutionPackInstall`'s and
  `SolutionPackArtefactBase`'s changesets exist ahead of their own future
  callers.

  ## GLOBAL, not tenant-scoped

  See `Letflow.Definitions.SolutionPackInstall`'s moduledoc for the full
  GLOBAL-vs-PER_TENANT discussion and open question (REQ-041 acceptance
  criterion 5) — not duplicated here.

  ## No foreign key to `solution_pack_installs` or `solution_pack_artefact_bases`

  Deliberate — see the owning migration
  (`priv/repo/migrations/20260817083803_create_pack_update_resolutions.exs`)
  and design §3.3.1: a resolution must be insertable for an artefact
  regardless of whether an install or base row exists for it (the same
  "no install record" conflict case REQ-041 acceptance criterion 2 requires
  stay representable).

  ## `resolved_by` carries no foreign key to `users.id`

  A deliberate design choice (§3.3, §9 OQ-7), not forced by any cross-schema
  constraint — REQ-041 names no requirement that this column be validated
  referentially. Flagged for REVIEWER to override if a real FK is preferred.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "pack_update_resolutions" do
    field(:tenant_id, Ecto.UUID)
    field(:pack_id, :string)
    field(:target_version, :string)
    field(:artefact_type, :string)
    field(:artefact_id, :string)
    field(:resolution, Ecto.Enum, values: [:keep_theirs, :take_incoming, :custom])
    field(:resolved_content, :string)
    field(:resolved_by, Ecto.UUID)
    field(:resolved_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
  @type resolution :: :keep_theirs | :take_incoming | :custom

  @doc """
  Structural changeset for inserting a new pack-update conflict resolution.
  Does no I/O. Not called anywhere within REQ-041's own scope — see moduledoc.

  `resolved_content` is only meaningful when `resolution == :custom` (nullable
  for `:keep_theirs`/`:take_incoming`, design §3.3) — this changeset does not
  add a conditional-required check for that correlation, matching
  `req027`/`req035`'s "structural checks are an application/changeset concern,
  not asserted here without a stated requirement" precedent.
  """
  @spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def insert_changeset(resolution, attrs) do
    resolution
    |> cast(attrs, [
      :tenant_id,
      :pack_id,
      :target_version,
      :artefact_type,
      :artefact_id,
      :resolution,
      :resolved_content,
      :resolved_by,
      :resolved_at
    ])
    |> validate_required([
      :tenant_id,
      :pack_id,
      :target_version,
      :artefact_type,
      :artefact_id,
      :resolution,
      :resolved_by,
      :resolved_at
    ])
    |> validate_length(:artefact_type, max: 255)
    |> validate_length(:artefact_id, max: 255)
    |> unique_constraint(
      [:tenant_id, :pack_id, :target_version, :artefact_type, :artefact_id],
      name: :uq_pack_update_resolution
    )
  end
end
