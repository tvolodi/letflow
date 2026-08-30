defmodule Letflow.Webhooks.Delivery do
  @moduledoc """
  Ecto schema for the `webhook_delivery_attempts` table. See
  `lib/letflow/design/req183-webhook-delivery-dispatch.md` §2. Ordinary
  `Ecto.Schema`, no process — same plain-CRUD-table shape as
  `Letflow.Webhooks.Subscription`/`Letflow.Dlq.Entry`.

  Every row is written once and never updated — `Letflow.Webhooks.deliver/3`
  always inserts a new row, never updates an existing one.

  ## `delivery_id` — a column, not the primary key (design §1.1)

  A "delivery" is modeled as a group of attempt rows sharing one
  `delivery_id`, generated fresh by `deliver/3` at the start of a call. There
  is no separate `webhook_deliveries` header table — no acceptance criterion
  or requirement-text field list names one.

  ## `status` — closed `Ecto.Enum`, uppercase (design §2.3)

  Stored as the two literal uppercase strings `"SUCCESS"`/`"FAILED"` —
  matching `WebhookDeliveryAttemptStatus` in `web/src/types/api.ts` exactly.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "webhook_delivery_attempts" do
    field(:tenant_id, Ecto.UUID)
    field(:delivery_id, Ecto.UUID)
    field(:subscription_id, Ecto.UUID)
    field(:event_type, :string)

    field(:status, Ecto.Enum, values: [:SUCCESS, :FAILED])

    field(:http_status_code, :integer)
    field(:attempted_at, :utc_datetime)
    field(:attempt_count, :integer)
    field(:max_attempts, :integer)
    field(:last_error, :string)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          tenant_id: Ecto.UUID.t(),
          delivery_id: Ecto.UUID.t(),
          subscription_id: Ecto.UUID.t(),
          event_type: String.t(),
          status: :SUCCESS | :FAILED,
          http_status_code: non_neg_integer() | nil,
          attempted_at: DateTime.t(),
          attempt_count: pos_integer(),
          max_attempts: pos_integer(),
          last_error: String.t() | nil
        }

  @doc """
  Structural changeset for `Letflow.Webhooks.deliver/3`. Casts
  `:tenant_id, :delivery_id, :subscription_id, :event_type, :status,
  :http_status_code, :attempted_at, :attempt_count, :max_attempts,
  :last_error` — every field is supplied at insert time by `deliver/3`; there
  is no partial-update caller. `validate_required/2` on everything except
  `:http_status_code` and `:last_error` (both legitimately `nil` — no
  response received, or no error to report on `:SUCCESS`, design §1/§2.2).
  """
  @spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def insert_changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :tenant_id,
      :delivery_id,
      :subscription_id,
      :event_type,
      :status,
      :http_status_code,
      :attempted_at,
      :attempt_count,
      :max_attempts,
      :last_error
    ])
    |> validate_required([
      :tenant_id,
      :delivery_id,
      :subscription_id,
      :event_type,
      :status,
      :attempted_at,
      :attempt_count,
      :max_attempts
    ])
  end
end
