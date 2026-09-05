defmodule Letflow.Definitions.SolutionPackInstall do
  @moduledoc """
  Ecto schema for the `solution_pack_installs` table. See
  `lib/letflow/design/req041-pack-update-diff-schema.md` §3.1 and §5.1.

  ## Scope — this requirement builds schema only

  REQ-041 builds schema plus the read-only diff/plan computation
  (`Letflow.Definitions.compute_pack_update_plan/5`,
  `Letflow.Definitions.classify_artefact/3`). It does NOT build the real
  solution-pack export/install path that populates this table (owned by
  SOL-01/02/03, `src/solution/`, not scoped to any stage yet), does not build
  an `update_changeset/2` (no transition function moves `status`/
  `uninstalled_at` — a future requirement's job), and does not enforce
  rejecting an *apply* attempt when a computed plan's `has_unresolved_conflicts`
  is true (also a future requirement — this requirement only computes and
  exposes that flag). Do not read this module as any of those landing early.

  ## GLOBAL, not tenant-scoped — and the open question this does NOT resolve
  (REQ-041 acceptance criterion 5)

  This table, `solution_pack_artefact_bases`, and `pack_update_resolutions` are all
  GLOBAL (public/default schema, no schema-per-tenant `:prefix`) -- prm-batch1's
  explicit classification for these three specifically ("install records are
  cross-tenant infrastructure"), consistent with the TNT-01-confirmed
  classification of a public-schema routing/registry table (per
  svc-01-04-service-scope.md, cited by REQ-041 in docs/requirements.yaml:
  "service_catalog is a public-schema routing/registry table (TNT-01 confirmed)").

  OPEN QUESTION, explicitly not resolved here: neither
  docs/migration/decisions/0003-ecto-schema-strategy.md nor any other Letflow
  decision record states a GENERAL rule for when a table earns this GLOBAL
  exception versus Decision B's schema-per-tenant default for ordinary business
  tables. This module follows prm-batch1's stated classification for these three
  tables specifically -- that part is settled -- but the underlying general
  question is left open, flagged here as worth a future REVIEWER/decision-record
  follow-up rather than something each later requirement re-derives ad hoc.

  `solution_pack_artefact_bases` (`Letflow.Definitions.SolutionPackArtefactBase`)
  and `pack_update_resolutions` (changeset-only, no dedicated schema module —
  see `Letflow.Definitions.compute_pack_update_plan/5`) both cross-reference this
  moduledoc rather than duplicating the text above.

  ## `tenant_id` is a real `belongs_to`, unlike every PER_TENANT table's plain
  field

  Unlike `Letflow.Definitions.PromotionReview`/`ProcessDefinition`'s plain
  `field(:tenant_id, Ecto.UUID)` (no association — those tables live in a
  tenant's own schema, cross-schema from `tenants`), `tenant_id` here is
  declared as `belongs_to(:tenant, Letflow.Identity.Tenant, ...)` because this
  table carries a real DB-level foreign key to `tenants.id` and both tables live
  in the same public/default schema — an Ecto association is idiomatic here in
  a way it is not for a cross-schema reference (design §5.1).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "solution_pack_installs" do
    belongs_to(:tenant, Letflow.Identity.Tenant, foreign_key: :tenant_id, type: :binary_id)
    field(:pack_id, :string)
    field(:installed_version, :string)
    field(:status, Ecto.Enum, values: [:active, :uninstalled], default: :active)
    field(:installed_at, :utc_datetime_usec)
    field(:uninstalled_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
  @type status :: :active | :uninstalled

  @doc """
  Structural changeset for inserting a new solution-pack install record. Does
  no I/O.

  `status` and `uninstalled_at` are deliberately NOT castable here — a
  newly-inserted install is always `:active` (the column default); there is no
  `update_changeset/2` on this module (see moduledoc's scope note).
  """
  @spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def insert_changeset(install, attrs) do
    install
    |> cast(attrs, [:tenant_id, :pack_id, :installed_version, :installed_at])
    |> validate_required([:tenant_id, :pack_id, :installed_version, :installed_at])
    |> validate_length(:pack_id, max: 255)
    |> validate_length(:installed_version, max: 255)
    |> unique_constraint([:tenant_id, :pack_id], name: :uq_solution_pack_install_active)
  end
end
