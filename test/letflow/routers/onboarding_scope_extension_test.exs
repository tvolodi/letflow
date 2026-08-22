defmodule Letflow.Routers.OnboardingScopeExtensionTest do
  @moduledoc """
  Tests for REQ-076's AC10 SCOPE EXTENSION (run `WF02-REQ076-20260822`, ISS-0230): the
  `:migrating` tenant-status decision across onboarding. See `test/specs/REQ-076.md`'s
  AC10 section for the full rationale, and
  `lib/letflow/design/req076-identity-tokens-roles-onboarding.md` §12 for the design.

  Named as its own file, separate from `test/letflow/routers/onboarding_test.exs`
  (AC7/AC8), because these tests dispatch against `Letflow.Routers.Identity`'s `/tokens`
  routes, not `Letflow.Routers.Onboarding` itself -- AC10 is about the `:migrating`
  status's effect on *any* tenant-scoped route via `Letflow.Plugs.TenantStatus`, and
  `/identity/tokens` is used here only because it is a route that both accepts a write
  (POST) and a read (GET), giving both directions AC10 requires in one already-existing,
  already-tested route pair.

  Dispatches through the real `Letflow.Router.call/2` (`AuthPipeline` -> `TenantStatus`
  -> `Letflow.Routers.Identity`), matching `onboarding_test.exs`'s own established
  full-pipeline dispatch convention -- required here because AC10's claim is specifically
  about `Letflow.Plugs.TenantStatus`, a plug mounted in that pipeline, not something a
  direct `Letflow.Routers.Identity.call/2` dispatch (bypassing the pipeline, as
  `test/letflow/routers/identity_test.exs` does) would ever exercise.

  Uses `Letflow.TenantFixture.provisioned_tenant!/1` (an already-fully-migrated tenant)
  administratively flipped to `:migrating` via `Tenant.status_changeset/2`, per design
  §12.2's own argument: the truly-empty-schema `:migrating` state cannot carry a real,
  `AuthPipeline`-accepted credential at all (both authentication mechanisms query a
  tenant-schema table that does not exist until migration completes), so it cannot be the
  subject of an authenticated HTTP test in the first place. `async: false`, same reasoning
  as every other module in this suite that provisions a real tenant schema.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.TenantFixture

  defp insert_user!(tenant, attrs \\ []) do
    default = %{
      username: "ac10-caller-#{Ecto.UUID.generate()}",
      display_name: "AC10 Test Caller",
      email: "ac10-caller-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    }

    %User{}
    |> Ecto.Changeset.change(Map.merge(default, Map.new(attrs)))
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  # Mints a real, fully-provisioned tenant + PLATFORM_ADMIN caller with a real API
  # token, then flips that tenant's status to :migrating administratively --
  # Tenant.status_changeset/2's own existing writer, not a new REQ-076-specific status
  # mechanism (design §12.1: this extension adds no second status rule).
  defp migrating_caller! do
    fixture = TenantFixture.provisioned_tenant!(slug_prefix: "req076-ac10")
    tenant = fixture.tenant
    user = insert_user!(fixture)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["PLATFORM_ADMIN"], expires_at: nil},
        prefix: fixture.schema_name
      )

    {:ok, migrating_tenant} =
      tenant
      |> Tenant.status_changeset(%{status: :migrating})
      |> Repo.update()

    assert migrating_tenant.status == :migrating

    {plaintext, tenant.slug}
  end

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp authed_request(method, path, plaintext, tenant_slug, body \\ nil) do
    conn =
      if body do
        conn(method, path, Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
      else
        conn(method, path)
      end

    conn
    |> put_req_header("authorization", "Bearer " <> plaintext)
    |> put_req_header("x-tenant-slug", tenant_slug)
  end

  describe "REQ-076 AC10: write (POST) against a :migrating tenant is rejected 503 by the existing TenantStatus write-pause (ISS-0230)" do
    test "POST /api/v1/identity/tokens against a :migrating tenant with a real, valid token returns 503 tenant_migrating" do
      {plaintext, tenant_slug} = migrating_caller!()

      conn =
        authed_request(:post, "/api/v1/identity/tokens", plaintext, tenant_slug, %{
          "user_id" => Ecto.UUID.generate(),
          "roles" => ["TASK_WORKER"]
        })
        |> dispatch()

      assert conn.status == 503
      assert Jason.decode!(conn.resp_body)["error"] == "tenant_migrating"
    end
  end

  describe "REQ-076 AC10: read (GET) against a :migrating tenant passes through unchanged (ISS-0230)" do
    test "GET /api/v1/identity/tokens against the same :migrating tenant with the same token returns 200 and serves existing data" do
      {plaintext, tenant_slug} = migrating_caller!()

      conn =
        authed_request(:get, "/api/v1/identity/tokens", plaintext, tenant_slug)
        |> dispatch()

      assert conn.status == 200
      assert %{"items" => items} = Jason.decode!(conn.resp_body)
      assert is_list(items)
    end
  end
end
