defmodule Letflow.Identity.TenantRoleTest do
  @moduledoc """
  Direct-insert / schema-constraint tests for `Letflow.Identity.TenantRole`. See
  `test/specs/REQ-063.md` for why this file's fixtures changed — REQ-063
  (`lib/letflow/design/req063-identity-tables-schema-per-tenant.md`) moved
  `tenant_role` (and its `groups` FK target) out of `public` into each tenant's own
  provisioned Postgres schema. See `test/letflow/identity/user_test.exs`'s own
  moduledoc for the full reasoning behind the `SET search_path` fixture mechanism
  this file mirrors.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Identity.{Group, Tenant, TenantRole}
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  defp unique_slug, do: "req063-trole-#{System.unique_integer([:positive, :monotonic])}"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{slug: unique_slug(), display_name: "REQ-063 TenantRole Test"},
        :disabled
      )
      |> Repo.insert!()

    on_exit(fn ->
      case TenantProvisioning.schema_name_for_tenant(tenant.id) do
        {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)

    assert {:ok, %Registration{schema_name: schema_name}} =
             TenantProvisioning.provision_tenant_schema(tenant.id)

    assert {:ok, _applied_versions} = TenantProvisioning.replay_migrations(tenant.id)

    Repo.query!(~s(SET search_path TO "#{schema_name}", public))

    %{tenant: tenant, schema_name: schema_name}
  end

  # No changeset function exists yet on `TenantRole` (design §3.4 — REQ-020
  # owns list_roles/upsert_role) — insert the struct directly.
  defp insert_group!(%{tenant: tenant}) do
    {:ok, group} =
      Repo.insert(%Group{tenant_id: tenant.id, name: "Group #{Ecto.UUID.generate()}"})

    group
  end

  defp unique_role_name, do: "role-#{Ecto.UUID.generate()}"

  test "a tenant_role with a group_id that matches no groups row raises a constraint error",
       _ctx do
    # tenant_role.group_id is the one FK that DOES exist in this batch
    # (identity-schema.md §2.4), unlike users/groups.tenant_id's deliberate
    # omission. A freshly-generated UUID here matches no real groups row by
    # construction, so this must be rejected at the DB level -- inside this
    # tenant's own schema, the FK now resolves against that schema's own groups
    # table (REQ-063 §2.2), not public.groups.
    orphan_group_id = Ecto.UUID.generate()

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert(%TenantRole{name: unique_role_name(), group_id: orphan_group_id})
    end
  end

  test "a tenant_role with a group_id that matches a real groups row succeeds", ctx do
    group = insert_group!(ctx)

    assert {:ok, %TenantRole{group_id: group_id}} =
             Repo.insert(%TenantRole{name: unique_role_name(), group_id: group.id})

    assert group_id == group.id
  end

  test "two tenant_roles with the same name IN THE SAME tenant schema: the second raises a constraint error",
       ctx do
    group = insert_group!(ctx)
    name = unique_role_name()

    assert {:ok, _} = Repo.insert(%TenantRole{name: name, group_id: group.id})

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert(%TenantRole{name: name, group_id: group.id})
    end
  end
end
