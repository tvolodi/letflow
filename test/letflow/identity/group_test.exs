defmodule Letflow.Identity.GroupTest do
  use Letflow.DataCase, async: true

  alias Letflow.Identity.Group

  # No changeset function exists yet on `Group` (design §3.3 — no requirement
  # in the REQ-015..021 batch owns groups CRUD) — insert the struct directly.
  test "a group can reference a tenant_id with no matching tenants row (no DB-level FK enforced)" do
    # Same deliberate omission as users.tenant_id (identity-schema.md §2.3):
    # groups.tenant_id carries no DB-level FK to tenants.id. This UUID
    # matches no real tenants row by construction; if a future migration
    # accidentally added references(:tenants) here, this insert would start
    # raising and this test would catch it.
    orphan_tenant_id = Ecto.UUID.generate()

    assert {:ok, %Group{tenant_id: ^orphan_tenant_id}} =
             Repo.insert(%Group{
               tenant_id: orphan_tenant_id,
               name: "Group #{Ecto.UUID.generate()}"
             })
  end
end
