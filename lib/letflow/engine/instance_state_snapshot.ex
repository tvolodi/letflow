defmodule Letflow.Engine.InstanceStateSnapshot do
  @moduledoc """
  Ecto schema for the `instance_state_snapshots` table. See
  `lib/letflow/design/req054-instance-state-snapshots.md` §3.

  ## Not the same table as `instance_definition_snapshots` (REQ-027/033)

  `instance_state_snapshots` (this module, REQ-054) is **not**
  `instance_definition_snapshots` (`Letflow.Definitions.SnapshotStore`,
  REQ-027/033) — the two names are one word apart and a name collision here
  would be a silent data-model error:

  * `instance_definition_snapshots` holds the immutable PD-08 **definition
    graph** bound to an instance at start — exactly one row per instance,
    write-once, bare `instance_id` primary key.
  * `instance_state_snapshots` (this table) holds periodic **execution
    state** (`Letflow.Engine.InstanceState.t()`) — zero or more rows per
    instance, accumulating over the instance's life. Individual rows are
    never updated in place; the table's row set grows.

  ## No `tenant_id` column (Decision 0006 D2)

  Like every other business table added since D2 shipped (`events`,
  `tokens`, `tasks`, `instance_definition_snapshots`), this table lives
  inside a per-tenant Postgres schema — the schema boundary alone is the
  isolation boundary. Every read and write must pass `prefix: schema_name`
  explicitly at call time; there is no compile-time `@schema_prefix`.

  ## No public changeset

  This table has no update path and no caller-supplied, user-facing
  attributes (the only writer is `Letflow.Engine.SnapshotWriter`, an
  internal engine module, never an API-facing form) — see design doc §4.1.
  Rows are inserted via a plain struct, not a changeset.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "instance_state_snapshots" do
    field(:instance_id, Ecto.UUID)
    field(:sequence_number, :integer)
    field(:state, :map)
    field(:taken_at, :utc_datetime_usec, read_after_writes: true)
  end

  @type t :: %__MODULE__{}
end
