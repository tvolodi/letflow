defmodule Letflow.Definitions.DefinitionSequence do
  @moduledoc """
  Ecto schema for the `definition_sequence` table — the per-tenant-schema
  sequence-lock row `GET /definitions/delta` (REQ-125, MOB-3) reads its
  cursor watermark from. See
  `lib/letflow/design/req125-definitions-delta-sync.md` §5.2/§5.3.

  Structurally identical to `Letflow.EventStore.InstanceSequence`
  (§5.2 of the design doc), except keyed on `tenant_id` rather than
  `instance_id`: **one row per tenant schema**, not per instance and not per
  definition, shared across every `process_definitions` row in that schema
  — the delta endpoint's ordering guarantee (AC1) is over the whole
  tenant's definition set, not any one definition's own history.

  ## No `update_changeset/2`, deliberately (mirrors INV-EV-4)

  The increment is performed as a single atomic statement under a row lock
  (`SELECT ... FOR UPDATE`, then increment), inside the same transaction as
  the `process_definitions` row mutation it sequences — see
  `Letflow.Definitions.assign_definition_sequence/2`. A changeset-mediated
  read-modify-write would reintroduce exactly the lost-update race that
  protocol exists to prevent, so `insert_changeset/2` (first-write-for-this-
  tenant row creation) is the only changeset here.

  ## No `@schema_prefix` (mirrors INV-EV-8)

  Like every tenant-scoped schema module, this table lives in many Postgres
  schemas — one per tenant — so every read and write must pass
  `prefix: schema_name` explicitly at call time rather than relying on a
  compile-time prefix.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:tenant_id, :binary_id, autogenerate: false}
  schema "definition_sequence" do
    field(:next_seq, :integer, default: 1)
  end

  @type t :: %__MODULE__{}

  @doc """
  Structural changeset for creating a tenant's definition-sequence row on its
  first `create`/`activate`/`deprecate`/`archive` write. Does no I/O. There
  is deliberately no update counterpart — see this module's moduledoc.
  """
  @spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def insert_changeset(definition_sequence, attrs) do
    definition_sequence
    |> cast(attrs, [:tenant_id, :next_seq])
    |> validate_required([:tenant_id])
    |> validate_number(:next_seq, greater_than: 0)
  end
end
