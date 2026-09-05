defmodule Letflow.Definitions.PromotionReview do
  @moduledoc """
  Ecto schema for the `promotion_reviews` table. See
  `lib/letflow/design/req035-promotion-reviews-schema.md` §3 and §5.1.

  ## Scope — this requirement builds schema only

  REQ-035 builds schema only. The state-machine transition functions
  (`insert_review/1`, `approve_review/4`, `reject_review/2`,
  `mark_review_applied/1`, `mark_review_failed/1`, `supersede_review/2`) and
  `promote_definition/N` are REQ-037. The plan/conflict/digest computation this
  table's rows are built from (`compute_promotion_plan/5`, `compute_plan_digest/1`,
  `verify_digest/2`) is REQ-036. Rollback (`rollback_definition_version/4`, which
  reads this table for its superseded-lookup) is REQ-038. Do not read this module
  as any of those landing early.

  ## `row_version` is an optimistic-locking column, not a plain audit counter
  (REQ-035 acceptance criterion 3)

  `row_version` is an optimistic-locking column, not a plain audit counter. It
  starts at 1 on insert and is incremented only as part of a state-transition
  UPDATE issued elsewhere (REQ-037), of the shape
  `UPDATE promotion_reviews SET ..., row_version = row_version + 1
   WHERE id = $1 AND status = $2 AND row_version = $3`.
  Zero rows affected by that statement means the transition lost a concurrency
  race (someone else changed this row first) and must be surfaced as the
  invalid-transition error, not retried or ignored. This module deliberately
  does not use `Ecto.Schema.optimistic_lock/2,3` — that macro is
  `Repo.update/2`-oriented and raises `Ecto.StaleEntryError`, whereas every
  transition here is a raw `Ecto.Query`/`Repo.update_all` guarded update that
  needs a rows-affected count, not a raised exception. There is no
  `update_changeset/2` on this module for the same reason.

  ## Open questions (REQ-035 acceptance criterion 4)

  Two things this schema deliberately does NOT resolve, stated here as open
  questions rather than silent decisions:

  1. `def_type` (default "process") carries no enum and no CHECK constraint —
     it is open-ended text, extensible without a schema migration, per prm-04's
     own Open Question 1 (as cited by this table's owning requirement,
     REQ-035, in docs/requirements.yaml -- this module has no direct access to
     the source document, src/design/prm-04-promotion-review-state-machine.md,
     which lives outside this repository). Whether a CHECK constraint restricting
     the value set should be added once the set of legal def_types is known
     is left open.

  2. This table's PER_TENANT-vs-GLOBAL classification is NOT independently
     confirmed against an explicit source the way `events`/`events_archive`'s
     classification is confirmed against 1147_par01_events_partitioning.sql's
     own comment (cited in docs/migration/decisions/0003-ecto-schema-strategy.md).
     The migration builds this table schema-per-tenant (via REQ-022's :prefix
     mechanism) because REQ-035's acceptance criteria mandate it, consistent
     with Decision B's general rule for business tables -- but neither 0003
     nor any design doc states this table's classification explicitly the way
     0003 does for events. REVIEWER should re-confirm this classification is
     correct rather than treat its presence here as settled fact.

  ## No `@schema_prefix`

  This table lives in many Postgres schemas — one per tenant — so every read
  and write must pass `prefix: schema_name` explicitly at call time rather than
  relying on a compile-time prefix. `schema_name` comes from a
  `Letflow.TenantProvisioning.Registration` row.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "promotion_reviews" do
    field(:plan_digest, :string)
    field(:def_type, :string, default: "process")
    field(:def_id, :string)
    field(:serialised_plan, :string)

    field(:status, Ecto.Enum,
      values: [:pending_review, :approved, :rejected, :applied, :failed, :superseded],
      default: :pending_review
    )

    field(:requested_by, Ecto.UUID)
    field(:approved_by, Ecto.UUID)
    field(:approved_at, :utc_datetime_usec)
    field(:superseded_by, Ecto.UUID)
    field(:row_version, :integer, default: 1)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
  @type status :: :pending_review | :approved | :rejected | :applied | :failed | :superseded

  @doc """
  Structural changeset for inserting a new promotion review. Does no I/O.

  `status`, `approved_by`, `approved_at`, `superseded_by` and `row_version` are
  deliberately NOT castable here — a newly-inserted review is always
  `:pending_review` (the column default), and every subsequent value is set
  only by REQ-037's guarded `UPDATE` statements, never by a changeset. There is
  no `update_changeset/2` on this module — see this module's moduledoc.
  """
  @spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def insert_changeset(review, attrs) do
    review
    |> cast(attrs, [:plan_digest, :def_type, :def_id, :serialised_plan, :requested_by])
    |> validate_required([:plan_digest, :def_id, :serialised_plan, :requested_by])
    |> validate_length(:plan_digest, is: 64)
    |> validate_format(:plan_digest, ~r/^[0-9a-f]{64}\z/)
    |> validate_length(:def_id, max: 255)
    |> unique_constraint(:plan_digest, name: :uq_promotion_review_active_digest)
  end
end
