defmodule Letflow.Identity.GroupTest do
  @moduledoc """
  Direct-insert / schema-constraint test for `Letflow.Identity.Group`. See
  `test/specs/REQ-063.md` for why this file's fixture changed — REQ-063
  (`lib/letflow/design/req063-identity-tables-schema-per-tenant.md`) moved `groups`
  out of `public` into each tenant's own provisioned Postgres schema. See
  `test/letflow/identity/user_test.exs`'s own moduledoc for the full reasoning
  behind the `SET search_path` fixture mechanism this file mirrors (a bare
  `Repo.insert(%Group{...})` has no single call site to thread `prefix:` through).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Identity.Group
  alias Letflow.Identity.Tenant
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  defp unique_slug, do: "req063-group-#{System.unique_integer([:positive, :monotonic])}"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{slug: unique_slug(), display_name: "REQ-063 Group Test"},
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

  # No changeset function exists yet on `Group` (design §3.3 — no requirement
  # in the REQ-015..021 batch owns groups CRUD) — insert the struct directly.
  test "a group can reference a tenant_id with no matching tenants row (no DB-level FK enforced)",
       %{tenant: tenant} do
    # Same deliberate omission as users.tenant_id (identity-schema.md §2.3):
    # groups.tenant_id carries no DB-level FK to tenants.id. This UUID
    # matches no real tenants row by construction; if a future migration
    # accidentally added references(:tenants) here, this insert would start
    # raising and this test would catch it. Deliberately NOT tenant.id itself
    # (which DOES exist) — a fresh, unrelated UUID.
    orphan_tenant_id = Ecto.UUID.generate()
    refute orphan_tenant_id == tenant.id

    assert {:ok, %Group{tenant_id: ^orphan_tenant_id}} =
             Repo.insert(%Group{
               tenant_id: orphan_tenant_id,
               name: "Group #{Ecto.UUID.generate()}"
             })
  end
end
