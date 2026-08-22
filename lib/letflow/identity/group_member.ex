defmodule Letflow.Identity.GroupMember do
  @moduledoc """
  Ecto schema for the `group_members` join table (REQ-074, design §8a) —
  backs `Letflow.Identity.add_group_member/3`, `list_group_members/3`, and
  `remove_group_member/3`.

  No surrogate `:id` primary key (design OQ-7, ELIXIR-DEV's call): this is a
  pure join table and every caller above operates on `(group_id, user_id)`,
  never a bare `GroupMember` id — the composite unique index on
  `[:group_id, :user_id]` (see the migration) is this table's real identity,
  so a synthetic key would add a column nothing reads. `timestamps(updated_at:
  false)` carries `inserted_at`-as-`added_at` semantics — no update path
  exists for a membership row.

  See `lib/letflow/design/req074-identity-group-routes.md` §8a for the full
  design this module implements.
  """

  use Ecto.Schema

  @primary_key false
  schema "group_members" do
    belongs_to(:group, Letflow.Identity.Group, type: :binary_id, primary_key: true)
    belongs_to(:user, Letflow.Identity.User, type: :binary_id, primary_key: true)

    timestamps(updated_at: false)
  end

  @type t :: %__MODULE__{}
end
