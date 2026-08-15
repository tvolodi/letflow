defmodule Letflow.Identity.TenantRoleTest do
  use Letflow.DataCase, async: true

  alias Letflow.Identity.{Group, TenantRole}

  # No changeset function exists yet on `TenantRole` (design §3.4 — REQ-020
  # owns list_roles/upsert_role) — insert the struct directly.
  defp insert_group! do
    {:ok, group} =
      Repo.insert(%Group{tenant_id: Ecto.UUID.generate(), name: "Group #{Ecto.UUID.generate()}"})

    group
  end

  defp unique_role_name, do: "role-#{Ecto.UUID.generate()}"

  test "a tenant_role with a group_id that matches no groups row raises a constraint error" do
    # tenant_role.group_id is the one FK that DOES exist in this batch
    # (identity-schema.md §2.4), unlike users/groups.tenant_id's deliberate
    # omission. A freshly-generated UUID here matches no real groups row by
    # construction, so this must be rejected at the DB level.
    orphan_group_id = Ecto.UUID.generate()

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert(%TenantRole{name: unique_role_name(), group_id: orphan_group_id})
    end
  end

  test "a tenant_role with a group_id that matches a real groups row succeeds" do
    group = insert_group!()

    assert {:ok, %TenantRole{group_id: group_id}} =
             Repo.insert(%TenantRole{name: unique_role_name(), group_id: group.id})

    assert group_id == group.id
  end

  test "two tenant_roles with the same name: the second raises a constraint error" do
    group = insert_group!()
    name = unique_role_name()

    assert {:ok, _} = Repo.insert(%TenantRole{name: name, group_id: group.id})

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert(%TenantRole{name: name, group_id: group.id})
    end
  end
end
