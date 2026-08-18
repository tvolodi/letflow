defmodule Letflow.Engine.Task do
  @moduledoc """
  Ecto schema for the `tasks` table. See
  `lib/letflow/design/req043-instance-engine-schema.md` §4.

  ## Scope — schema only, `src/tasks/store.zig`'s query surface NOT ported here

  This module is the Ecto schema for the `tasks` table only — the table
  `EE-03` (`src/engine/instance.zig`'s task-activation path) and `EE-04` (task
  completion) write into. R-Co's own `src/tasks/store.zig` (1202 lines)
  additionally builds a standalone task query/list/filter surface
  (`TaskStore.list/6`-equivalent: `instance_id`/`status`/`assignee_ref`
  filters, pagination) — **that surface is not ported by this module or by
  REQ-043 at all.** It belongs to S4's tasks routes or its own later
  requirement, per `docs/migration/stage-3-instance-engine.md`'s explicit scope
  boundary. Do not read this schema module as `TaskStore`'s functional
  equivalent — it is schema only, with no query/list/filter functions of its
  own.

  REQ-043 builds only the migration
  (`priv/repo/migrations/20260818110003_create_tasks.exs`) and this schema
  module — no context-module write path (`create/N`, `complete/N`) exists yet;
  those are REQ-045/051's job.

  ## `status` dumps uppercase (design §4.3 point 3, INV-EE43-4)

  `status`'s `Ecto.Enum` dumps **uppercase** (`"PENDING"`/`"COMPLETED"`/
  `"CANCELLED"`), matching R-Co's own stored strings exactly — unlike
  `Letflow.Engine.TokenRecord.status`, which dumps lowercase. Both moduledocs state
  this so neither reader "fixes" the two tables into matching casings.

  ## No `@schema_prefix`

  Like every other multi-tenant table in this schema, `tasks` lives in many
  Postgres schemas — one per tenant — so every read and write must pass
  `prefix: schema_name` explicitly at call time rather than relying on a
  compile-time prefix.

  ## `tenant_id` is never caller-supplied (design §6)

  Neither changeset below is reachable from any built context-module function
  yet, but the contract every future caller must follow is fixed here: the
  value cast into `tenant_id` must always be
  `Letflow.TenantProvisioning.tenant_id_for_schema_name/1`'s result, derived
  from the `:prefix` the write targets — never a value taken from external
  caller input. See `Letflow.EventStore.append/2` and
  `Letflow.Definitions.create/2` for the established shape of that contract.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "tasks" do
    field(:tenant_id, Ecto.UUID)
    field(:instance_id, Ecto.UUID)
    field(:token_id, Ecto.UUID)
    field(:node_id, :string)
    field(:node_name, :string)

    field(:status, Ecto.Enum,
      values: [pending: "PENDING", completed: "COMPLETED", cancelled: "CANCELLED"],
      default: :pending
    )

    field(:assignee_type, :string)
    field(:assignee_ref, :string)
    field(:form_schema, :map)
    field(:output_variables, :map)
    field(:completed_by, Ecto.UUID)
    field(:completed_at, :utc_datetime_usec)
    field(:cancelled_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
  @type status :: :pending | :completed | :cancelled

  @doc """
  Structural changeset for creating a task row at activation time. Does no I/O.
  """
  @spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def insert_changeset(task, attrs) do
    task
    |> cast(attrs, [
      :tenant_id,
      :instance_id,
      :token_id,
      :node_id,
      :node_name,
      :assignee_type,
      :assignee_ref,
      :form_schema
    ])
    |> validate_required([:tenant_id, :instance_id, :token_id, :node_id, :node_name])
  end

  @doc """
  Structural changeset for completing (or cancelling) an existing task row.
  `instance_id`, `token_id`, `node_id`, `node_name` and `tenant_id` are
  structurally not castable here — a task never changes which
  instance/token/node/tenant it belongs to.
  """
  @spec complete_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def complete_changeset(task, attrs) do
    task
    |> cast(attrs, [:status, :output_variables, :completed_by, :completed_at, :cancelled_at])
    |> validate_required([:status])
  end
end
