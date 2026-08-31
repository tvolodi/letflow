defmodule Letflow.Dlq.Entry do
  @moduledoc """
  Ecto schema for the `dlq_entries` table. See
  `lib/letflow/design/req176-dlq-core.md` §2. Ordinary `Ecto.Schema`, no
  process, no `gen_statem` — matches this codebase's plain-CRUD-table
  precedent (e.g. `Letflow.Engine.Task`).

  ## `status` — closed `Ecto.Enum`, lowercase (design §2.1)

  Unlike `entry_type` (a plain `:string`, extensible), `status` is a closed
  `Ecto.Enum` over exactly `DlqStatus`'s four values — `:pending`,
  `:retrying`, `:resolved`, `:discarded` — stored **lowercase**, deliberately
  distinct from `Letflow.Engine.Task.status`'s uppercase convention. This is
  a different table with its own contract (`web/src/types/api.ts`'s
  `DlqStatus`), not a re-use of the engine's own enum casing.

  ## `retry_history` — plain `{:array, :map}`, not `embeds_many` (design §2.2)

  Each element is a plain map shaped exactly like `DlqRetryAttempt`
  (`attempt_no`/`attempted_at`/`outcome`/`error_message`). No acceptance
  criterion needs changeset-level validation on historical entries — they
  are appended mechanically by `Letflow.Dlq.retry/2`, never user-supplied —
  so this field stays a directly-appendable list, not an embedded schema.

  ## No `@schema_prefix`

  Like every other tenant-scoped table in this schema, `dlq_entries` lives in
  many Postgres schemas — one per tenant — so every read and write must pass
  `prefix: schema_name` explicitly at call time.

  ## `created_at`, not `timestamps/1` (design §1)

  `DlqEntry`'s contract names `created_at` specifically (not `inserted_at`),
  and there is no `updated_at` field in the frontend type at all, so this
  schema declares its three datetime fields explicitly rather than reaching
  for the `timestamps/1` macro that would produce mismatched names.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "dlq_entries" do
    field(:tenant_id, Ecto.UUID)
    field(:entry_type, :string)
    field(:instance_id, Ecto.UUID)
    field(:reference_id, :string)
    field(:reason, :string)
    field(:full_reason, :string)
    field(:error_detail, :map)
    field(:error_chain, {:array, :map})
    field(:source_payload, :map)
    field(:context_json, :map)
    field(:retry_history, {:array, :map}, default: [])
    field(:retry_count, :integer, default: 0)
    field(:retry_limit, :integer)
    field(:next_retry_at, :utc_datetime)

    field(:status, Ecto.Enum,
      values: [:pending, :retrying, :resolved, :discarded],
      default: :pending
    )

    field(:created_at, :utc_datetime)
    field(:first_failed_at, :utc_datetime)
    field(:last_failed_at, :utc_datetime)
  end

  @type retry_attempt :: %{
          required(:attempt_no) => pos_integer(),
          required(:attempted_at) => String.t(),
          required(:outcome) => String.t(),
          optional(:error_message) => String.t() | nil
        }

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          tenant_id: Ecto.UUID.t(),
          entry_type: String.t(),
          instance_id: Ecto.UUID.t() | nil,
          reference_id: String.t() | nil,
          reason: String.t() | nil,
          full_reason: String.t() | nil,
          error_detail: map() | nil,
          error_chain: [map()] | nil,
          source_payload: map() | nil,
          context_json: map() | nil,
          retry_history: [retry_attempt()],
          retry_count: non_neg_integer(),
          retry_limit: pos_integer() | nil,
          next_retry_at: DateTime.t() | nil,
          status: :pending | :retrying | :resolved | :discarded,
          created_at: DateTime.t(),
          first_failed_at: DateTime.t() | nil,
          last_failed_at: DateTime.t() | nil
        }

  @doc """
  Structural changeset for `Letflow.Dlq.enqueue/2`. `status`, `retry_count`,
  and `retry_history` are excluded from `cast/3` and rely on their
  `Ecto.Schema` struct defaults (`:pending`, `0`, `[]`) — `enqueue/2` never
  needs to set them via a cast-reachable path because the schema itself
  supplies the value. `tenant_id` and `created_at` are likewise excluded
  from `cast/3` and are instead set via two explicit `put_change/3` calls
  below, reading both keys out of the `attrs` map this function receives —
  because neither key is in `cast/3`'s field list, a caller-supplied
  `attrs` map containing keys with those two names still reaches the
  changeset (via `put_change/3`'s own read of `attrs`); the guarantee this
  adds is that `status`/`retry_count`/`retry_history` can no longer be
  influenced by `cast/3` regardless of what `attrs` contains, and that the
  changeset's structure now matches what this docstring says. See
  `Letflow.Dlq.enqueue/2` and design §3.1
  (`lib/letflow/design/req176-dlq-core.md`).
  """
  @spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def insert_changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :entry_type,
      :instance_id,
      :reference_id,
      :reason,
      :full_reason,
      :error_detail,
      :error_chain,
      :source_payload,
      :context_json,
      :retry_limit,
      :first_failed_at,
      :last_failed_at
    ])
    |> put_change(:tenant_id, Map.get(attrs, :tenant_id))
    |> put_change(:created_at, Map.get(attrs, :created_at))
    |> validate_required([:tenant_id, :entry_type, :status, :retry_count, :created_at])
  end

  @doc """
  Structural changeset for `Letflow.Dlq.retry/2`'s successful branch — writes
  `status`, `retry_count`, and `retry_history` only.
  """
  @spec retry_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def retry_changeset(entry, attrs) do
    entry
    |> cast(attrs, [:status, :retry_count, :retry_history])
    |> validate_required([:status, :retry_count, :retry_history])
  end

  @doc """
  Structural changeset for `Letflow.Dlq.discard/2`'s successful branch —
  writes `status` only.
  """
  @spec discard_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def discard_changeset(entry, attrs) do
    entry
    |> cast(attrs, [:status])
    |> validate_required([:status])
  end
end
