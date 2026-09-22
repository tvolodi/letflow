defmodule Letflow.Definitions.SolutionPackArtefactBase do
  @moduledoc """
  Ecto schema for the `solution_pack_artefact_bases` table. See
  `lib/letflow/design/req041-pack-update-diff-schema.md` §3.2 and §5.2.

  ## Scope — this requirement builds schema only

  See `Letflow.Definitions.SolutionPackInstall`'s moduledoc's scope note — the
  same "schema plus read-only diff computation only" boundary applies here.

  ## GLOBAL, not tenant-scoped

  See `Letflow.Definitions.SolutionPackInstall`'s moduledoc for the full
  GLOBAL-vs-PER_TENANT discussion and open question (REQ-041 acceptance
  criterion 5) — not duplicated here.

  ## No `belongs_to` — plain `tenant_id` field, unlike `SolutionPackInstall`

  This table's `tenant_id` carries the same real DB-level foreign key to
  `tenants.id` as `SolutionPackInstall`'s, so a `belongs_to(:tenant, ...)`
  association would be equally valid here — but this module deliberately omits
  it: this table is always looked up by its composite
  `(tenant_id, pack_id, artefact_type, artefact_id)` key
  (`Letflow.Definitions.compute_pack_update_plan/5`'s base lookup), never
  traversed via a `Tenant` struct, so an unused association would be
  scope-padding, not a functional need (design §5.2, §9 OQ-8 — a stylistic
  asymmetry with `SolutionPackInstall`, flagged as deliberate, not an
  oversight).

  ## No foreign key to `solution_pack_installs`

  Deliberate — see the owning migration
  (`priv/repo/migrations/20260817083802_create_solution_pack_artefact_bases.exs`)
  and design §3.2.1: a mandatory FK would make the "no install record exists"
  conflict case (REQ-041 acceptance criterion 2) un-representable.

  ## `base_content` is canonical-JSON text, caller's responsibility

  This column's value MUST already be canonical-JSON text (sorted keys, no
  insignificant whitespace) by the time it is written — this requirement does
  not itself provide the canonicalization step. See
  `Letflow.Definitions.classify_artefact/3`'s moduledoc-level note and design
  §5.4/OQ-1.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "solution_pack_artefact_bases" do
    field(:tenant_id, Ecto.UUID)
    field(:pack_id, :string)
    field(:artefact_type, :string)
    field(:artefact_id, :string)
    field(:base_version, :string)
    field(:base_content, :string)
    field(:captured_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc """
  Structural changeset for creating or wholesale-replacing an artefact base
  snapshot row. Does no I/O.

  Named `upsert_changeset/2`, not `insert_changeset/2`, because it is reused
  by two distinct call sites with two distinct write semantics (REQ-379
  design §4):

    * **Install-time capture**
      (`Letflow.Definitions.SolutionPack.capture_artefact_bases/4`, REQ-379):
      insert-if-absent — the caller passes this changeset to `Repo.insert/2`
      with `on_conflict: :nothing, conflict_target: [:tenant_id, :pack_id,
      :artefact_type, :artefact_id]`, so a base snapshot, once captured, is
      never overwritten by a later call for the same key. This is
      deliberate: the base is "what the pack delivered at the moment it
      first became this artefact's reference point," and must not move just
      because the same content was installed again — a tenant may have since
      locally adapted the artefact.
    * **A future update-application call site** (REQ-380, not built yet):
      would legitimately want wholesale replace — `Repo.insert/2` with an
      `on_conflict: :replace_all`-style option (or equivalent) — so that
      after an update is applied and a conflict resolved, the base advances
      to the new content.

  This changeset itself is identical either way (structural cast/validate
  only); only the caller's chosen `Repo.insert/2` options differ per call
  site.
  """
  @spec upsert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def upsert_changeset(base, attrs) do
    base
    |> cast(attrs, [
      :tenant_id,
      :pack_id,
      :artefact_type,
      :artefact_id,
      :base_version,
      :base_content,
      :captured_at
    ])
    |> validate_required([
      :tenant_id,
      :pack_id,
      :artefact_type,
      :artefact_id,
      :base_version,
      :base_content,
      :captured_at
    ])
    |> validate_length(:artefact_type, max: 255)
    |> validate_length(:artefact_id, max: 255)
    |> unique_constraint([:tenant_id, :pack_id, :artefact_type, :artefact_id],
      name: :uq_solution_pack_artefact_base
    )
  end
end
