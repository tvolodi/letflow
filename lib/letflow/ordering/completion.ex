defmodule Letflow.Ordering.Completion do
  @moduledoc """
  Ecto schema for the `effect_completions` table (REQ-199, ORD-01).

  One row per effect-completion event received for a given correlation. The
  `status` lifecycle: `PENDING` → `APPLIED` (applied in sequence order by
  `Letflow.Ordering.Consumer`) or `DEAD` (swept by `Letflow.Ordering.Sweeper`
  when its predecessor never arrives within `gap_timeout_seconds`).

  `sequence_no` is the caller-assigned position within a correlation; the
  consumer only applies a row when its `sequence_no` equals the cursor's
  `applied_seq + 1` (strict in-order guarantee, ORD-01).

  `tenant_id` is retained intra-schema per decision 0003 Decision B — never
  accepted from caller attrs, always derived from `opts[:prefix]` by the
  context module.
  """

  use Ecto.Schema

  @primary_key {:completion_id, :binary_id, autogenerate: true}
  schema "effect_completions" do
    field :tenant_id, :binary_id
    field :correlation_id, :string
    field :sequence_no, :integer
    field :status, Ecto.Enum, values: [pending: "PENDING", applied: "APPLIED", dead: "DEAD"], default: :pending
    field :payload, :map, default: %{}
    field :received_at, :utc_datetime_usec
    field :applied_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false, inserted_at: :created_at)
  end
end
