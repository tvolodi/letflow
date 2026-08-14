defmodule Letflow.Repo.Migrations.CreateApprovals do
  use Ecto.Migration

  def change do
    create table(:approvals, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :finance_approved_at, :utc_datetime
      add :ops_approved_at, :utc_datetime
      add :status, :string, null: false, default: "pending"

      timestamps()
    end
  end
end
