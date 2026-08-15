defmodule Letflow.RowApproval.Approval do
  @moduledoc """
  Plain Ecto schema backing `Letflow.RowApproval` — a single row in the
  `approvals` table is one instance of the two-approver sign-off
  workflow, tracked entirely as columns rather than as a supervised
  process. See `Letflow.RowApproval` for the context functions and the
  moduledoc there for why this module exists alongside
  `Letflow.ParallelApproval`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "approvals" do
    field(:finance_approved_at, :utc_datetime)
    field(:ops_approved_at, :utc_datetime)
    field(:status, :string, default: "pending")

    timestamps()
  end
end
