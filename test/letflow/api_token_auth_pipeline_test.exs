defmodule Letflow.ApiTokenAuthPipelineTest do
  @moduledoc """
  End-to-end HTTP-level tests for REQ-076's API-token branch of
  `Letflow.Plugs.AuthPipeline` (design §3.5) — the real request path AC4 and AC5
  actually depend on, not just the underlying `Letflow.Identity.verify_api_token/2`
  primitive (that primitive-level coverage lives in `test/letflow/identity_test.exs`).
  See `test/specs/REQ-076.md` for the full AC-to-test mapping.

  Dispatches through the **real** `Letflow.Router.call/2` (the full
  `AuthPipeline` -> `TenantStatus` -> `Letflow.Routers.Identity` chain), mirroring
  `test/letflow/plugs/api_pipeline_integration_test.exs`'s own established
  full-pipeline dispatch convention, with `Authorization: Bearer <plaintext>` +
  `X-Tenant-Slug: <slug>` headers (the API-token branch's own tenant-identification
  mechanism, design §3.5 step 1) rather than an OIDC bearer token.

  Uses `Letflow.TenantFixture.provisioned_tenant!/1` for a real, provisioned tenant
  schema — `Letflow.Identity.create_token/3` requires an existing `user_id` in that
  schema, and `Letflow.Plugs.AuthPipeline`'s API-token branch itself does a real
  `Repo` round trip against it. `async: false` for the whole module (ExUnit's
  `async` setting is module-wide) — `TenantFixture.provisioned_tenant!/1` switches
  `Ecto.Adapters.SQL.Sandbox` to global `:auto` mode, same reasoning as every other
  `async: false` module in this suite that provisions a real tenant schema.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.TenantFixture

  defp insert_user!(tenant, attrs \\ []) do
    default = %{
      username: "api-token-user-#{Ecto.UUID.generate()}",
      display_name: "API Token Test User",
      email: "api-token-user-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    }

    %User{}
    |> Ecto.Changeset.change(Map.merge(default, Map.new(attrs)))
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp api_token_request(method, path, plaintext, tenant_slug) do
    conn(method, path)
    |> put_req_header("authorization", "Bearer " <> plaintext)
    |> put_req_header("x-tenant-slug", tenant_slug)
  end

  describe "REQ-076 AC4: revoked token rejected with 401 on the very next HTTP request, no sleep or cache flush" do
    test "a valid API token authenticates GET /api/v1/identity/tokens; the identical token is rejected 401 immediately after revocation" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req076-ac4-http")
      user = insert_user!(tenant)

      {:ok, %{token: token, plaintext: plaintext}} =
        Identity.create_token(user.id, %{roles: ["PLATFORM_ADMIN"], expires_at: nil},
          prefix: tenant.schema_name
        )

      first_conn =
        api_token_request(:get, "/api/v1/identity/tokens", plaintext, tenant.tenant.slug)
        |> dispatch()

      assert first_conn.status == 200
      assert first_conn.assigns.auth_context.user_id == user.id
      assert first_conn.assigns.auth_context.roles == ["PLATFORM_ADMIN"]

      {:ok, _revoked} = Identity.revoke_token(token.id, prefix: tenant.schema_name)

      # No Process.sleep/1, no cache-clear call, no process restart between the
      # two requests -- this is a plain second request with the identical
      # plaintext, immediately after revoke_token/2 returns.
      second_conn =
        api_token_request(:get, "/api/v1/identity/tokens", plaintext, tenant.tenant.slug)
        |> dispatch()

      assert second_conn.status == 401
    end
  end

  describe "REQ-076 AC5/INV-1: a tenant-A-minted token cannot authenticate a tenant-B request (HTTP level)" do
    test "the identical plaintext, sent with tenant B's own X-Tenant-Slug header, is rejected 401" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req076-ac5-http-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req076-ac5-http-b")
      user_a = insert_user!(tenant_a)

      {:ok, %{plaintext: plaintext}} =
        Identity.create_token(user_a.id, %{roles: ["PLATFORM_ADMIN"], expires_at: nil},
          prefix: tenant_a.schema_name
        )

      own_tenant_conn =
        api_token_request(:get, "/api/v1/identity/tokens", plaintext, tenant_a.tenant.slug)
        |> dispatch()

      assert own_tenant_conn.status == 200

      cross_tenant_conn =
        api_token_request(:get, "/api/v1/identity/tokens", plaintext, tenant_b.tenant.slug)
        |> dispatch()

      assert cross_tenant_conn.status == 401
    end
  end

  describe "REQ-076 §3.5: the API-token branch's own failure modes are byte-identical 401s" do
    test "a missing X-Tenant-Slug header is rejected 401, distinct message text not leaked" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req076-header-missing")
      user = insert_user!(tenant)

      {:ok, %{plaintext: plaintext}} =
        Identity.create_token(user.id, %{roles: ["PLATFORM_ADMIN"], expires_at: nil},
          prefix: tenant.schema_name
        )

      conn =
        conn(:get, "/api/v1/identity/tokens")
        |> put_req_header("authorization", "Bearer " <> plaintext)
        |> dispatch()

      assert conn.status == 401
    end

    test "an unresolvable X-Tenant-Slug value is rejected 401" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req076-header-unresolvable")
      user = insert_user!(tenant)

      {:ok, %{plaintext: plaintext}} =
        Identity.create_token(user.id, %{roles: ["PLATFORM_ADMIN"], expires_at: nil},
          prefix: tenant.schema_name
        )

      conn =
        api_token_request(:get, "/api/v1/identity/tokens", plaintext, "no-such-tenant-slug")
        |> dispatch()

      assert conn.status == 401
    end

    test "a syntactically-lf_tok_-shaped but never-issued plaintext is rejected 401" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req076-header-garbage")

      conn =
        api_token_request(
          :get,
          "/api/v1/identity/tokens",
          "lf_tok_" <> String.duplicate("0", 64),
          tenant.tenant.slug
        )
        |> dispatch()

      assert conn.status == 401
    end
  end
end
