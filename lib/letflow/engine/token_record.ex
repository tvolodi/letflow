defmodule Letflow.Engine.TokenRecord do
  @moduledoc """
  Ecto schema for the `tokens` table. See
  `lib/letflow/design/req043-instance-engine-schema.md` §3, §5.

  ## Naming — not `Letflow.Engine.Token` (post-hoc integration rename)

  The design doc (§5.1, OQ-5) originally named this module `Letflow.Engine.Token`
  and flagged the `Letflow.Engine` namespace choice as unconfirmed by any prior
  convention. REQ-044 (transition kernel, `req044-transition-kernel.md` §3),
  developed in parallel and merged to `main` first, independently claimed
  `Letflow.Engine.Token` for the pure in-memory `Token{node_id, branch_id,
  token_id, waiting_child_instance_id}` struct the transition function operates
  on (`lib/letflow/engine/token.ex`) — zero `Ecto`/`Letflow.Repo` dependency,
  by design, for `Letflow.Engine.Transition`'s purity contract. That struct and
  this schema module are genuinely different things (transient pure-function
  value vs. persisted lifecycle row) that cannot share one module name. This
  module is renamed `TokenRecord` at rebase/integration time so the
  already-shipped, load-bearing REQ-044 struct keeps its name unchanged; every
  other REQ-043 design decision below is unaffected by the rename.

  ## Why this table exists (design §3.1, §5.3 point 1 — resolved, not guessed)

  This table exists because `Letflow.Engine.Task.token_id` requires a real,
  FK-referenceable row (a JSONB array element inside
  `instance_projections.current_nodes` cannot serve as a foreign-key target),
  not because `current_nodes` was found insufficient for split/join computation
  on its own terms — R-Co's `src/design/engine.md` computes split/join
  purely from the in-memory `Token{node_id, branch_id}` list and states
  explicitly that no new fields are needed on that struct for EE-06/EE-07.
  `instance_projections.current_nodes` remains the engine's authoritative
  summary of active token positions; this table is the identity/lifecycle side
  table `Letflow.Engine.Task` and future sub-process tracking (REQ-062) need.

  ## Scope — this requirement builds schema only

  REQ-043 builds only this schema module and its migration
  (`priv/repo/migrations/20260818110002_create_tokens.exs`). No
  `create/N`/`advance/N`/join-counting context-module function exists yet —
  that is REQ-051 (EE-06/EE-07 split/join) and REQ-062 (SPC-01 sub-process)'s
  job. Do not read this module as split/join logic landing early.

  ## No `@schema_prefix`

  Like every other multi-tenant table in this schema, `tokens` lives in many
  Postgres schemas — one per tenant — so every read and write must pass
  `prefix: schema_name` explicitly at call time rather than relying on a
  compile-time prefix.

  ## `status` dumps lowercase (design §3.2, INV-EE43-4)

  `status` is stored lowercase (`"active"`/`"waiting"`/`"completed"`/
  `"cancelled"`), a fixed convention per design §3.2/INV-EE43-4 — not one
  free to be "corrected" later, since this codebase already has a
  same-shaped table using the opposite casing. This is
  the opposite convention from `Letflow.Engine.Task.status`, which dumps
  uppercase — R-Co itself uses different casing for the two tables in the same
  source file (`migrations/005_instances.sql`), confirmed by direct read, so
  this is not harmonized into a shared casing.

  ## No `tenant_id` column (Decision 0006 D2)

  This table lived inside a per-tenant Postgres schema from the start
  (Decision 0003 Dimension B) — the schema boundary alone already made any
  `tenant_id` column here fully redundant. Decision 0006 D2
  (`docs/migration/decisions/0006-identity-tables-schema-per-tenant.md`)
  removes it. Do not re-add a `tenant_id` field to this schema without first
  re-reading that record.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "tokens" do
    field(:instance_id, Ecto.UUID)
    field(:node_id, :string)
    field(:branch_id, :string)

    field(:status, Ecto.Enum,
      values: [:active, :waiting, :completed, :cancelled],
      default: :active
    )

    field(:parent_token_id, Ecto.UUID)
    field(:gateway_id, :string)
    field(:waiting_child_instance_id, Ecto.UUID)
    field(:completed_at, :utc_datetime_usec)
    field(:cancelled_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
  @type status :: :active | :waiting | :completed | :cancelled

  @doc """
  Structural changeset for creating a token row. Does no I/O.

  `branch_id` is NOT in `validate_required/2` (ISS-0408 fix,
  `priv/repo/migrations/20260902000001_make_tokens_branch_id_nullable.exs`):
  `Letflow.Engine.Token.branch_id`'s own pure type has always been
  `String.t() | nil` (REQ-044 §3), and REQ-051's `fire_join/5` construction
  deliberately sets `branch_id: nil` on the token produced by a
  PARALLEL_GATEWAY join firing (`req051-parallel-gateway-split-join.md`,
  the `fire_join/5` section) -- a documented, on-record decision, not an
  oversight. Every other token this changeset is used for still supplies a
  non-nil `branch_id` (the root token's own instance_id-as-branch_id
  convention, or a split-derived token's own derived id) -- this only
  widens what the schema *accepts*, it does not change what any existing
  caller *sends*.
  """
  @spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def insert_changeset(token, attrs) do
    token
    |> cast(attrs, [
      :instance_id,
      :node_id,
      :branch_id,
      :status,
      :parent_token_id,
      :gateway_id
    ])
    |> validate_required([:instance_id, :node_id])
  end

  @doc """
  Structural changeset for advancing an existing token row. `instance_id`,
  `branch_id`, `parent_token_id` and `gateway_id` are structurally not
  castable here — a token's owning instance, branch identity, and split
  lineage never change after creation.
  """
  @spec advance_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def advance_changeset(token, attrs) do
    token
    |> cast(attrs, [:node_id, :status, :waiting_child_instance_id, :completed_at, :cancelled_at])
    |> validate_required([:node_id, :status])
  end
end
