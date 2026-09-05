defmodule Letflow.Identity.Group do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Ecto schema for the `groups` table. This is a minimal table added by
  REQ-015 itself — Letflow had no prior `groups` migration to port
  directly. Shape precedent is R-Co `src/design/adp-04-user-tenant-binding.md`'s
  `Group` struct (`group_id`, `tenant_id`, `name`, `created_at_us`), scoped
  down to exactly what `tenant_role.group_id`'s FK target and REQ-020's
  (`src/identity/role_registry.zig`'s `upsertRole`) group-existence check
  need. Full group-membership modeling (adp-04's `GroupMembership`,
  group-task claim authorization) is explicitly out of scope here.

  `tenant_id` was carried on this table, with no database-level foreign key
  to `tenants.id`, until Decision 0006 D2 dropped it for the same reason it
  was dropped from `users` — the per-tenant Postgres schema already
  identifies the owning tenant. See
  `docs/migration/decisions/0006-identity-tables-schema-per-tenant.md`.

  `create_changeset/2` (below) is REQ-074's addition — the first changeset
  function defined on this schema, backing `Letflow.Identity.create_group/2`
  and the `POST /groups` route. See
  `lib/letflow/design/req074-identity-group-routes.md` §8 gap 1.

  `display_name`/`description` (below) are also REQ-074 additions (design
  §8b) — nullable columns with no prior requirement's changeset touching
  them.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "groups" do
    field(:name, :string)
    field(:display_name, :string)
    field(:description, :string)

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc """
  PROVENANCE (historical, not current decision authority):
  Builds the insert changeset for `Letflow.Identity.create_group/2` (design
  §8 gap 1). `display_name` defaults to `name` when omitted or an empty
  string, so a group without a distinct display name still shows something
  meaningful in a listing (`identity.zig:361-371`).
  `description` is normalized to `nil` when an empty string is supplied
  (matches `identity.zig:373-380`) — both normalizations happen here, not in
  the router, per the design's own note that this default is applied by
  `create_group/2` itself.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = group, attrs) do
    name = Map.get(attrs, "name")

    attrs_with_defaults =
      attrs
      |> put_default_display_name(name)
      |> nil_if_empty("description")

    group
    |> cast(attrs_with_defaults, [:name, :display_name, :description])
    |> validate_required([:name, :display_name])
    |> unique_constraint(:name)
  end

  defp put_default_display_name(attrs, name) do
    case Map.get(attrs, "display_name") do
      dn when dn in [nil, ""] -> Map.put(attrs, "display_name", name)
      _dn -> attrs
    end
  end

  defp nil_if_empty(attrs, key) do
    case Map.get(attrs, key) do
      "" -> Map.put(attrs, key, nil)
      _other -> attrs
    end
  end
end
