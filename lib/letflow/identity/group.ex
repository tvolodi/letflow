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

  `tenant_id` was carried on this table, with no database-level foreign key
  to `tenants.id`, until Decision 0006 D2 dropped it for the same reason it
  was dropped from `users` — the per-tenant Postgres schema already
  identifies the owning tenant. See
  `docs/migration/decisions/0006-identity-tables-schema-per-tenant.md`.

  No changeset function is defined here — no requirement in this batch
  (REQ-015 through REQ-021) owns `groups` CRUD; a future requirement owns
  group management proper.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "groups" do
    field(:name, :string)

    timestamps()
  end
end
