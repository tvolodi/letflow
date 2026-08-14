defmodule Letflow.Repo.Migrations.CreateTransitionEvents do
  use Ecto.Migration

  def change do
    create table(:transition_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :instance_id, :string, null: false
      add :from_state, :string, null: false
      add :to_state, :string, null: false
      add :action, :string, null: false

      timestamps(updated_at: false)
    end

    create index(:transition_events, [:instance_id])
  end
end
