defmodule Letflow.Identity.TenantRole do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Ecto schema for the `tenant_role` table. Shaped to match R-Co
  `src/identity/role_registry.zig`'s `TenantRoleStore` (`list_roles`,
  `upsert_role`), which REQ-020 implements against this schema.

  `group_id` carries a database-level foreign key to `groups.id` — unlike
  `Letflow.Identity.User.tenant_id`/`Letflow.Identity.Group.tenant_id`'s
  deliberate omission of a `tenants.id` FK elsewhere in this batch.
  `tenant_role` and `groups` are both per-tenant-owned tables that will
  live in the same tenant schema together once schema-per-tenant
  provisioning lands, so this FK stays valid across that future change and
  never needs to be dropped (see the `CreateTenantRole` migration's header
  comment for the full reasoning).

  `name` uniqueness is enforced today as a plain global unique index,
  standing in for "unique per tenant schema" under the single-default-schema
  deferral (see `lib/letflow/design/identity-schema.md` section 1).

  `changeset/2` (below) is owned by REQ-020 (`Letflow.Identity.RoleRegistry`) — it is a
  thin, defensive structural layer only (`cast`/`validate_required`/`unique_constraint`/
  `foreign_key_constraint`). The detailed name-format rule (codepoint-count,
  control-character exclusion) and the `group_id` UUID-format/existence checks are
  enforced by `RoleRegistry.upsert_role/2` itself, before this changeset is ever built —
  see `lib/letflow/design/req020-role-registry.md` §3.2.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "tenant_role" do
    field(:name, :string)
    field(:group_id, Ecto.UUID)

    timestamps(updated_at: false)
  end

  @type t :: %__MODULE__{}

  @doc """
  Defensive structural changeset for insert/upsert. Casts and requires `name`/
  `group_id`, and declares `unique_constraint(:name)` /
  `foreign_key_constraint(:group_id)` as typed fallbacks for the DB-level constraints
  REQ-015's migration already enforces (`unique_index(:tenant_role, [:name])`,
  `references(:groups, ...)`) — not a re-implementation of `RoleRegistry.upsert_role/2`'s
  own pre-DB-round-trip name-format/UUID-format validation.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(tenant_role, attrs) do
    tenant_role
    |> cast(attrs, [:name, :group_id])
    |> validate_required([:name, :group_id])
    |> unique_constraint(:name)
    |> foreign_key_constraint(:group_id)
  end
end
