defmodule Letflow.Events.TransitionEvent do
  @moduledoc """
  Append-only log of every state transition every instance has made.
  This is the piece that mirrors R-Co's Postgres migrations discipline
  and is what actually gets exercised on every gen_statem transition —
  the honest test of "how does Ecto + Postgres feel in practice."
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "transition_events" do
    field :instance_id, :string
    field :from_state, :string
    field :to_state, :string
    field :action, :string

    timestamps(updated_at: false)
  end
end
