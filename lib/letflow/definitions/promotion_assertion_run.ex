defmodule Letflow.Definitions.PromotionAssertionRun do
  @moduledoc """
  Ecto schema for the `promotion_assertion_runs` table. See
  `lib/letflow/design/req040-promotion-assertion-rerun.md` §4.

  PROVENANCE (historical, not current decision authority):
  Ported from R-Co's `src/definition/assertion_rerun.zig` (PRM-06/07) — one row per
  `(review_id, plan_digest)` idempotency key, recording the outcome of replaying a
  `Letflow.Definitions.PromotionArtifact.t()`'s assertions against an ephemeral
  REQ-039 sandbox. This module owns only the passive schema and its two structural
  changesets; the actual claim → replay → teardown → record orchestration is
  `Letflow.Definitions.apply_promotion_assertion_rerun/6`, not this module.

  ## `status` is a 4-value `Ecto.Enum`, backed by a migration-level CHECK constraint

  `:running` (the insert-time default, never re-cast) → one of `:passed`, `:failed`,
  `:teardown_failed` on the single final `UPDATE` `update_changeset/2` builds. Bare
  lowercase atoms, matching `ProcessDefinition.status`'s own dump-lowercase
  convention, consistent with the migration's lowercase `CHECK` predicate — see the
  migration file's own header for why this table carries a CHECK (a deliberate,
  flagged divergence from `promotion_reviews`' Ecto.Enum-only convention).

  ## Two changesets, not one — mirroring `PromotionReview`'s own split

  `insert_changeset/2` casts only the three columns present at idempotency-claim time
  (`review_id`, `idempotency_key`, `plan_digest` — `tenant_id` was a fourth column here
  until Decision 0006 D2 dropped it, see the migration file's own header); `status`,
  `assertions_*`, `failing_assertion_ids`, `sandbox_id`, `teardown_error` and
  `completed_at` are never castable there — a freshly-inserted row always starts at
  its column defaults. `update_changeset/2` is the only place any of those fields is
  ever written, exactly once per call that reaches that step (design §7.6, INV-AR-9).

  ## No `belongs_to :review`

  `review_id` is a bare `field(:review_id, Ecto.UUID)`, not a `belongs_to`, even
  though a real DB foreign key exists — matching
  `Letflow.Definitions.InstanceDefinitionSnapshot`'s own deliberate choice: a
  `belongs_to` would invite `Repo.preload/2` across this row → `PromotionReview`,
  coupling this module is not designed to need.

  ## No `@schema_prefix`

  This table lives in many Postgres schemas — one per tenant — so every read and
  write must pass `prefix: schema_name` explicitly at call time rather than relying
  on a compile-time prefix.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "promotion_assertion_runs" do
    field(:review_id, Ecto.UUID)
    field(:idempotency_key, :string)
    field(:plan_digest, :string)

    field(:status, Ecto.Enum,
      values: [:running, :passed, :failed, :teardown_failed],
      default: :running
    )

    field(:sandbox_id, Ecto.UUID)
    field(:assertions_total, :integer, default: 0)
    field(:assertions_passed, :integer, default: 0)
    field(:assertions_failed, :integer, default: 0)
    field(:failing_assertion_ids, {:array, :string}, default: [])
    field(:teardown_error, :string)

    # Assigned by the column's own DB default (`(now() AT TIME ZONE 'utc')`), never
    # by a changeset -- mirrors InstanceDefinitionSnapshot.snapshotted_at's own
    # read_after_writes: true convention.
    field(:started_at, :utc_datetime_usec, read_after_writes: true)
    field(:completed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
  @type status :: :running | :passed | :failed | :teardown_failed

  @doc """
  Structural changeset for the idempotency-anchor insert (design §7.1 step 1). Does
  no I/O.

  `status`/`sandbox_id`/`assertions_total`/`assertions_passed`/`assertions_failed`/
  `failing_assertion_ids`/`teardown_error`/`completed_at` are deliberately NOT
  castable here — a freshly-inserted row always starts at its column defaults
  (`status: :running`, every count `0`, `failing_assertion_ids: []`, everything
  else `nil`). Every subsequent value is written only by `update_changeset/2`'s
  single final `UPDATE` (design §7.6).
  """
  @spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def insert_changeset(run, attrs) do
    run
    |> cast(attrs, [:review_id, :idempotency_key, :plan_digest])
    |> validate_required([:review_id, :idempotency_key, :plan_digest])
    |> validate_length(:plan_digest, is: 64)
    |> validate_format(:plan_digest, ~r/^[0-9a-f]{64}\z/)
    # Turns a duplicate idempotency_key insert into {:error, changeset} rather
    # than a raised Ecto.ConstraintError -- design §7.1's own "attempt an
    # insert with on_conflict: :nothing" idiom relies on this constraint name
    # to disambiguate a genuine validation failure from a suppressed conflict.
    # Scoped to idempotency_key alone (not (tenant_id, idempotency_key)) since
    # Decision 0006 D2 dropped tenant_id from this table -- the per-tenant
    # Postgres schema already provides that scoping.
    |> unique_constraint(:idempotency_key,
      name: :uq_promotion_assertion_runs_idempotency
    )
    # Turns a dangling review_id into {:error, changeset} rather than a raised
    # error, which is what lets apply_promotion_assertion_rerun/6 return
    # {:error, :review_not_found}. The constraint name is Ecto's own default for
    # this table/column pair.
    |> foreign_key_constraint(:review_id, name: :promotion_assertion_runs_review_id_fkey)
  end

  @doc """
  Structural changeset for the single final `UPDATE` (design §7.6) that records this
  run's outcome — exactly one per call that reaches that step (INV-AR-9). Does no
  I/O.
  """
  @spec update_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def update_changeset(run, attrs) do
    run
    |> cast(attrs, [
      :status,
      :sandbox_id,
      :assertions_total,
      :assertions_passed,
      :assertions_failed,
      :failing_assertion_ids,
      :teardown_error,
      :completed_at
    ])
    |> validate_required([
      :status,
      :assertions_total,
      :assertions_passed,
      :assertions_failed,
      :failing_assertion_ids,
      :completed_at
    ])
  end
end
