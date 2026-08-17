defmodule Letflow.EventStore.RetentionPolicy do
  @moduledoc """
  Ecto schema for the `event_retention_policies` table — consulted by
  `Letflow.EventStore.archive/1` to determine, per `event_type`,
  whether/how long events are retained before being moved to
  `events_archive`. See
  `lib/letflow/design/req026-event-read-archive-platform-sentinels.md` §6/§8
  for the full design this module implements. Resolves REQ-023 §9 OQ-1
  ("`event_retention_policies` has no owning requirement"), per
  ISS-0013/GH#69.

  ## GLOBAL, not per-tenant (design §6)

  Unlike every other event-store schema module, this table carries no
  `tenant_id` column, and every query against it passes no `:prefix` at
  all — it lives in Ecto's single default/public schema, one row per
  `event_type` platform-wide, the same reason `Letflow.Identity.Tenant`
  carries no prefix either. See the design doc §6 for the full
  classification rationale and its own explicitly-flagged tension
  (§11 OQ-2) against the per-tenant `event_type_registry`: the same
  `event_type` string can be independently registered, with independently
  different JSON schemas, by every tenant, yet a single global retention
  policy for that string applies uniformly across all of them.

  ## Append-only-ish: no update path built here (design §8.5)

  `insert_changeset/2` is the only public write surface this module adds —
  no `Letflow.EventStore.upsert_retention_policy/2`-equivalent context
  function is built by REQ-026. Callers (test seeding, ops tooling) write
  rows directly: `Repo.insert(RetentionPolicy.insert_changeset(%RetentionPolicy{}, attrs))`.
  A CRUD/management API for this table (create/update/delete a policy) is
  explicitly out of scope, owned by a later requirement.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "event_retention_policies" do
    field(:event_type, :string)

    field(:policy, Ecto.Enum,
      values: [:keep_forever, :keep_days, :keep_count],
      default: :keep_forever
    )

    field(:keep_days, :integer)
    field(:keep_count, :integer)

    timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc """
  The only changeset this module exposes — structural validation for
  creating one retention-policy row. Does no I/O.

  `keep_days`/`keep_count`'s `validate_number/3` checks are deliberately
  redundant with the migration's `chk_keep_days`/`chk_keep_count` CHECK
  constraints — the app-level check produces a typed `Ecto.Changeset` error
  for the common case, the DB constraint is the non-bypassable backstop for
  any insert path that skips this changeset. Both only run when the field
  has a value; absent is valid for either.
  """
  @spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def insert_changeset(retention_policy, attrs) do
    retention_policy
    |> cast(attrs, [:event_type, :policy, :keep_days, :keep_count])
    |> validate_required([:event_type, :policy])
    |> validate_number(:keep_days, greater_than: 0)
    |> validate_number(:keep_count, greater_than: 0)
    |> unique_constraint(:event_type, name: :uq_retention_policy_event_type)
    |> check_constraint(:policy, name: :chk_retention_policy)
    |> check_constraint(:keep_days, name: :chk_keep_days)
    |> check_constraint(:keep_count, name: :chk_keep_count)
  end
end
