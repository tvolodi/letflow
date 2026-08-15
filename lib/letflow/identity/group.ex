defmodule Letflow.Identity.Group do
  @moduledoc """
  Ecto schema for the `groups` table. This is a minimal table added by
  REQ-015 itself — Letflow had no prior `groups` migration to port
  directly. Shape precedent is R-Co `src/design/adp-04-user-tenant-binding.md`'s
  `Group` struct (`group_id`, `tenant_id`, `name`, `created_at_us`), scoped
  down to exactly what `tenant_role.group_id`'s FK target and REQ-020's
  (`src/identity/role_registry.zig`'s `upsertRole`) group-existence check
  need. Full group-membership modeling (adp-04's `GroupMembership`,
  group-task claim authorization) is explicitly out of scope here.

  `tenant_id` carries no database-level foreign key to `tenants.id`, same
  rationale as `Letflow.Identity.User.tenant_id` (see the `CreateGroups`
  migration's header comment).

  No changeset function is defined here — no requirement in this batch
  (REQ-015 through REQ-021) owns `groups` CRUD; a future requirement owns
  group management proper.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "groups" do
    field(:tenant_id, Ecto.UUID)
    field(:name, :string)

    timestamps()
  end
end
