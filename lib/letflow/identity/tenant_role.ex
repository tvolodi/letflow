defmodule Letflow.Identity.TenantRole do
  @moduledoc """
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

  No changeset function is defined here — REQ-020 owns `list_roles/upsert_role`
  and their validation logic.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "tenant_role" do
    field(:name, :string)
    field(:group_id, Ecto.UUID)

    timestamps(updated_at: false)
  end
end
