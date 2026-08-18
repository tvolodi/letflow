defmodule Letflow.Repo.Migrations.DropTransitionEvents do
  use Ecto.Migration

  def change do
    drop table(:transition_events)
  end
end
