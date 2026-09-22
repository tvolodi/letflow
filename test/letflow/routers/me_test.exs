defmodule Letflow.Routers.MeTest do
  @moduledoc """
  Light route-behavior coverage for `Letflow.Routers.Me`'s
  `GET /me/memberships` handler (REQ-384 Part A). ELIXIR-DEV inline coverage
  only -- full TEST-DESIGNER coverage is a later pipeline step. Mirrors
  `test/letflow/routers/help_test.exs`'s dispatch mechanism: direct
  `Letflow.Routers.Me.call/2` invocation with `conn.assigns.auth_context` set
  by hand, running the router's own real `:match` -> `Letflow.Plugs.Authorize`
  -> `:dispatch` chain (so `conn.assigns.scoped_opts` is computed for real,
  not stubbed).

  `async: false`: tenant provisioning/migration replay needs
  `Sandbox.mode(Letflow.Repo, :auto)` (`TenantFixture.provisioned_tenant!/1`'s
  own requirement).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TenantMembership
  alias Letflow.Repo
  alias Letflow.TenantFixture

  @opts Letflow.Routers.Me.init([])

  defp build_conn(user_id, tenant_id, roles) do
    conn(:get, "/memberships")
    |> assign(:auth_context, %{user_id: user_id, tenant_id: tenant_id, roles: roles})
    |> assign(:trace_id, "req384-me-router-test-trace-id")
  end

  defp dispatch(conn), do: Letflow.Routers.Me.call(conn, @opts)

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp insert_tenant!(slug) do
    %Tenant{}
    |> Tenant.create_changeset(%{slug: slug, display_name: String.capitalize(slug)}, :disabled)
    |> Repo.insert!()
  end

  describe "GET /memberships" do
    test "200 includes the caller's own home tenant, even with zero tenant_memberships rows" do
      suffix = System.unique_integer([:positive])

      %{tenant_id: tenant_id, schema_name: schema_name, tenant: tenant} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req384-me-home-#{suffix}")

      assert {:ok, user} =
               Identity.create_user(
                 %{
                   "username" => "req384-user-#{suffix}",
                   "display_name" => "REQ-384 User",
                   "email" => "req384-user-#{suffix}@example.com"
                 },
                 prefix: schema_name
               )

      conn =
        build_conn(user.id, tenant_id, ["PROCESS_OPERATOR"])
        |> dispatch()

      assert conn.status == 200
      assert %{"memberships" => [entry]} = json(conn)
      assert entry["tenant_id"] == tenant.id
      assert entry["tenant_slug"] == tenant.slug
      assert entry["tenant_display_name"] == tenant.display_name
      assert entry["display_label"] == nil
    end

    test "200 includes admin-granted memberships alongside the home tenant" do
      suffix = System.unique_integer([:positive])

      %{tenant_id: tenant_id, schema_name: schema_name, tenant: tenant} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req384-me-multi-#{suffix}")

      email = "req384-multi-#{suffix}@example.com"

      assert {:ok, user} =
               Identity.create_user(
                 %{
                   "username" => "req384-multi-user-#{suffix}",
                   "display_name" => "Multi",
                   "email" => email
                 },
                 prefix: schema_name
               )

      other_tenant = insert_tenant!("req384-me-other-#{suffix}")

      %TenantMembership{}
      |> TenantMembership.create_changeset(%{
        subject_key: email,
        tenant_id: other_tenant.id,
        display_label: "Other Co"
      })
      |> Repo.insert!()

      conn =
        build_conn(user.id, tenant_id, ["PROCESS_OPERATOR"])
        |> dispatch()

      assert conn.status == 200
      assert %{"memberships" => memberships} = json(conn)
      assert length(memberships) == 2

      tenant_ids = Enum.map(memberships, & &1["tenant_id"])
      assert tenant.id in tenant_ids
      assert other_tenant.id in tenant_ids

      other_entry = Enum.find(memberships, &(&1["tenant_id"] == other_tenant.id))
      assert other_entry["display_label"] == "Other Co"
    end

    test "CANDIDATE is denied (ISS-0646 closed permission set, see Letflow.Api.Authorization moduledoc)" do
      suffix = System.unique_integer([:positive])

      %{tenant_id: tenant_id} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req384-me-candidate-#{suffix}")

      conn =
        build_conn(Ecto.UUID.generate(), tenant_id, ["CANDIDATE"])
        |> dispatch()

      assert conn.status == 403
    end
  end
end
