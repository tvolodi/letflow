defmodule Letflow.Routers.IdentityTest do
  @moduledoc """
  Tests for `Letflow.Routers.Identity` (REQ-073) — the five real user-CRUD
  handlers. See `lib/letflow/design/req073-identity-user-routes.md` §4/§5/§6
  for the test-case rationale this file implements directly, and §6b for the
  dispatch-mechanism rationale (direct `Letflow.Routers.Identity.call/2`
  dispatch with `conn.assigns[:auth_context]` set directly, bypassing the
  full `Letflow.Router` -> `Letflow.Plugs.ApiPipeline` -> `AuthPipeline`
  chain — neither existing OIDC token double can mint a non-`"VIEWER"`-role
  token).

  Uses `Letflow.DataCase` (real Postgres, per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1) and `Letflow.TenantFixture` for real provisioned tenant
  schemas, matching `test/letflow/api/context_test.exs`'s own established
  pattern for this class of test. `async: false` for the whole module, same
  reasoning as that file: tenant provisioning/migration replay needs
  `Sandbox.mode(Letflow.Repo, :auto)`.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Identity.User
  alias Letflow.TenantFixture

  @opts Letflow.Routers.Identity.init([])

  # ── Shared test dispatch helper (design §6b) ────────────────────────────

  defp build_conn(method, path, tenant, fields) do
    roles = Keyword.get(fields, :roles, [])
    body = Keyword.get(fields, :body, nil)

    conn = conn(method, path)

    conn =
      if body do
        %{conn | body_params: body}
        |> put_req_header("content-type", "application/json")
      else
        conn
      end

    conn
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant.tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "fixed-test-trace-id")
  end

  defp dispatch(conn), do: Letflow.Routers.Identity.call(conn, @opts)

  defp insert_user!(tenant, attrs) do
    default = %{
      username: "user-#{Ecto.UUID.generate()}",
      display_name: "A User",
      email: "user-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    }

    %User{}
    |> Ecto.Changeset.change(Map.merge(default, Map.new(attrs)))
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  # ── AC1: five basic end-to-end tests ────────────────────────────────────

  describe "AC1: basic end-to-end coverage for all five routes" do
    setup do
      %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req073-e2e")}
    end

    test "POST /users creates a user and returns 201 with the allowlisted shape", %{
      tenant: tenant
    } do
      conn =
        build_conn(:post, "/users", tenant,
          roles: ["PLATFORM_ADMIN"],
          body: %{
            "username" => "alice",
            "display_name" => "Alice Anderson",
            "email" => "alice@example.com"
          }
        )
        |> dispatch()

      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)

      assert body["username"] == "alice"
      assert body["display_name"] == "Alice Anderson"
      assert body["email"] == "alice@example.com"
      assert body["status"] == "active"
      assert body["auth_source"] == "internal"
      assert is_binary(body["id"])
      assert is_binary(body["inserted_at"])
      assert is_binary(body["updated_at"])
      refute Map.has_key?(body, "password_hash")
      refute Map.has_key?(body, "external_id")
      refute Map.has_key?(body, "external_realm")

      # AC5 — full key-set assertion (not just presence/exclusion checks):
      # a stray 9th key under any other name would be caught here.
      assert Map.keys(body) |> Enum.sort() == [
               "auth_source",
               "display_name",
               "email",
               "id",
               "inserted_at",
               "status",
               "updated_at",
               "username"
             ]

      assert Repo.get_by!(User, [username: "alice"], prefix: tenant.schema_name)
    end

    test "GET /users returns a cursor page", %{tenant: tenant} do
      insert_user!(tenant, username: "bob")

      conn =
        build_conn(:get, "/users", tenant, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert Map.has_key?(body, "items")
      assert Map.has_key?(body, "next_cursor")
      assert Map.has_key?(body, "count")
      assert body["count"] == length(body["items"])
      assert Enum.any?(body["items"], &(&1["username"] == "bob"))

      # AC5 — full key-set assertion on each item's user_map/1 shape.
      for item <- body["items"] do
        assert Map.keys(item) |> Enum.sort() == [
                 "auth_source",
                 "display_name",
                 "email",
                 "id",
                 "inserted_at",
                 "status",
                 "updated_at",
                 "username"
               ]
      end
    end

    test "GET /users/:id returns 200 with the user", %{tenant: tenant} do
      user = insert_user!(tenant, username: "carol")

      conn =
        build_conn(:get, "/users/#{user.id}", tenant, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["id"] == user.id
      assert body["username"] == "carol"

      # AC5 — full key-set assertion.
      assert Map.keys(body) |> Enum.sort() == [
               "auth_source",
               "display_name",
               "email",
               "id",
               "inserted_at",
               "status",
               "updated_at",
               "username"
             ]
    end

    test "PATCH /users/:id returns the updated user", %{tenant: tenant} do
      user = insert_user!(tenant, username: "dave", display_name: "Dave Original")

      conn =
        build_conn(:patch, "/users/#{user.id}", tenant,
          roles: ["PLATFORM_ADMIN"],
          body: %{"display_name" => "Dave Updated"}
        )
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["display_name"] == "Dave Updated"

      # AC5 — full key-set assertion.
      assert Map.keys(body) |> Enum.sort() == [
               "auth_source",
               "display_name",
               "email",
               "id",
               "inserted_at",
               "status",
               "updated_at",
               "username"
             ]

      assert Repo.get!(User, user.id, prefix: tenant.schema_name).display_name == "Dave Updated"
    end

    test "POST /users/:id/status changes persisted status", %{tenant: tenant} do
      user = insert_user!(tenant, username: "erin", status: :active)

      conn =
        build_conn(:post, "/users/#{user.id}/status", tenant,
          roles: ["PLATFORM_ADMIN"],
          body: %{"status" => "inactive"}
        )
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "inactive"

      # AC5 — full key-set assertion.
      assert Map.keys(body) |> Enum.sort() == [
               "auth_source",
               "display_name",
               "email",
               "id",
               "inserted_at",
               "status",
               "updated_at",
               "username"
             ]

      assert Repo.get!(User, user.id, prefix: tenant.schema_name).status == :inactive
    end
  end

  # ── AC2/INV-5: cross-tenant 404 is byte-identical (design §4) ───────────

  describe "AC2/INV-5: cross-tenant 404 is byte-identical to a never-existed 404" do
    setup do
      %{
        tenant_a: TenantFixture.provisioned_tenant!(slug_prefix: "req073-cross-a"),
        tenant_b: TenantFixture.provisioned_tenant!(slug_prefix: "req073-cross-b")
      }
    end

    test "GET /users/:id: a caller in tenant A probing a tenant-B-only id gets the same 404 bytes as a never-existed id",
         %{tenant_a: tenant_a, tenant_b: tenant_b} do
      tenant_b_user = insert_user!(tenant_b, username: "only-in-b")

      resp_cross_tenant =
        build_conn(:get, "/users/#{tenant_b_user.id}", tenant_a, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      resp_never_existed =
        build_conn(:get, "/users/#{Ecto.UUID.generate()}", tenant_a, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert resp_cross_tenant.status == 404
      assert resp_cross_tenant.status == resp_never_existed.status
      assert resp_cross_tenant.resp_body == resp_never_existed.resp_body
    end
  end

  # ── AC4: permission-denial, DB-unchanged (design §5) ────────────────────

  describe "AC4: permission-denial on the three write routes, database unchanged" do
    setup do
      %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req073-403")}
    end

    for {roles_label, roles} <- [
          {"no roles at all", []},
          {"a role that exists but lacks UsersGroupsRolesManage", ["TASK_WORKER"]}
        ] do
      test "POST /users -> 403 and no row inserted (#{roles_label})", %{tenant: tenant} do
        count_before = Repo.aggregate(User, :count, prefix: tenant.schema_name)

        conn =
          build_conn(:post, "/users", tenant,
            roles: unquote(roles),
            body: %{"username" => "x", "display_name" => "X", "email" => "x@example.com"}
          )
          |> dispatch()

        assert conn.status == 403
        assert Repo.aggregate(User, :count, prefix: tenant.schema_name) == count_before
      end

      test "PATCH /users/:id -> 403 and the row is byte-identical to before (#{roles_label})", %{
        tenant: tenant
      } do
        user = insert_user!(tenant, username: "patch-denied-#{unquote(roles_label)}")
        before = Repo.get!(User, user.id, prefix: tenant.schema_name)

        conn =
          build_conn(:patch, "/users/#{user.id}", tenant,
            roles: unquote(roles),
            body: %{"display_name" => "Should Not Apply"}
          )
          |> dispatch()

        assert conn.status == 403
        assert Repo.get!(User, user.id, prefix: tenant.schema_name) == before
      end

      test "POST /users/:id/status -> 403 and the row is byte-identical to before (#{roles_label})",
           %{tenant: tenant} do
        user =
          insert_user!(tenant, username: "status-denied-#{unquote(roles_label)}", status: :active)

        before = Repo.get!(User, user.id, prefix: tenant.schema_name)

        conn =
          build_conn(:post, "/users/#{user.id}/status", tenant,
            roles: unquote(roles),
            body: %{"status" => "inactive"}
          )
          |> dispatch()

        assert conn.status == 403
        assert Repo.get!(User, user.id, prefix: tenant.schema_name) == before
      end
    end
  end

  # ── AC3/INV-1: tenant-isolation on list (design §6) ─────────────────────

  describe "AC3/INV-1: listing is tenant-isolated" do
    test "listing users as tenant A returns only tenant A's users, even with similarly-named tenant B users" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req073-iso-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req073-iso-b")

      insert_user!(tenant_a, username: "alice", display_name: "Alice Anderson")
      insert_user!(tenant_b, username: "alice", display_name: "Alice Anderson")
      insert_user!(tenant_b, username: "alice2", display_name: "Alice Anderson 2")

      conn =
        build_conn(:get, "/users", tenant_a, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert length(body["items"]) == 1
      assert Enum.map(body["items"], & &1["username"]) == ["alice"]
    end
  end

  # ── Additional coverage: search/status filters, pagination, validation ──

  describe "list_users/2 filters and pagination, exercised through the router" do
    setup do
      %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req073-filters")}
    end

    test "status filter narrows results", %{tenant: tenant} do
      insert_user!(tenant, username: "active-1", status: :active)
      insert_user!(tenant, username: "inactive-1", status: :inactive)

      conn =
        build_conn(:get, "/users?status=inactive", tenant, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert Enum.map(body["items"], & &1["username"]) == ["inactive-1"]
    end

    test "an invalid status query param is rejected with 422", %{tenant: tenant} do
      conn =
        build_conn(:get, "/users?status=bogus", tenant, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert conn.status == 422
    end

    test "search filters across username/display_name/email", %{tenant: tenant} do
      insert_user!(tenant, username: "zeb", display_name: "Zeb Zoro", email: "zeb@example.com")

      insert_user!(tenant,
        username: "other",
        display_name: "Someone Else",
        email: "other@example.com"
      )

      conn =
        build_conn(:get, "/users?search=zeb", tenant, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert Enum.map(body["items"], & &1["username"]) == ["zeb"]
    end

    test "page_size limits the page and next_cursor is set when more rows exist", %{
      tenant: tenant
    } do
      for i <- 1..3, do: insert_user!(tenant, username: "page-user-#{i}")

      conn =
        build_conn(:get, "/users?page_size=2", tenant, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert length(body["items"]) == 2
      assert is_binary(body["next_cursor"])

      conn2 =
        build_conn(
          :get,
          "/users?page_size=2&cursor=#{URI.encode_www_form(body["next_cursor"])}",
          tenant,
          roles: ["PLATFORM_ADMIN"]
        )
        |> dispatch()

      assert conn2.status == 200
      body2 = Jason.decode!(conn2.resp_body)
      assert length(body2["items"]) == 1
      assert body2["next_cursor"] == nil

      returned_usernames =
        (body["items"] ++ body2["items"]) |> Enum.map(& &1["username"]) |> Enum.sort()

      assert returned_usernames == ["page-user-1", "page-user-2", "page-user-3"]
    end

    test "an invalid cursor is rejected with 400", %{tenant: tenant} do
      conn =
        build_conn(:get, "/users?cursor=not-a-valid-cursor!!!", tenant, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert conn.status == 400
    end
  end

  describe "validation failures (422) on the write routes" do
    setup do
      %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req073-validation")}
    end

    test "POST /users with a missing required field returns 422", %{tenant: tenant} do
      conn =
        build_conn(:post, "/users", tenant,
          roles: ["PLATFORM_ADMIN"],
          body: %{"display_name" => "No Username", "email" => "x@example.com"}
        )
        |> dispatch()

      assert conn.status == 422
    end

    test "POST /users/:id/status with an invalid status value returns 422", %{tenant: tenant} do
      user = insert_user!(tenant, username: "bad-status-target")

      conn =
        build_conn(:post, "/users/#{user.id}/status", tenant,
          roles: ["PLATFORM_ADMIN"],
          body: %{"status" => "not-a-real-status"}
        )
        |> dispatch()

      assert conn.status == 422
    end

    test "POST /users with a duplicate username returns 409", %{tenant: tenant} do
      insert_user!(tenant, username: "dupe")

      conn =
        build_conn(:post, "/users", tenant,
          roles: ["PLATFORM_ADMIN"],
          body: %{"username" => "dupe", "display_name" => "Dupe", "email" => "dupe@example.com"}
        )
        |> dispatch()

      assert conn.status == 409
    end
  end

  describe "GET/PATCH/status-update on a genuinely-absent id return 404" do
    setup do
      %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req073-notfound")}
    end

    test "PATCH /users/:id 404s for an absent id", %{tenant: tenant} do
      conn =
        build_conn(:patch, "/users/#{Ecto.UUID.generate()}", tenant,
          roles: ["PLATFORM_ADMIN"],
          body: %{"display_name" => "Nope"}
        )
        |> dispatch()

      assert conn.status == 404
    end

    test "POST /users/:id/status 404s for an absent id", %{tenant: tenant} do
      conn =
        build_conn(:post, "/users/#{Ecto.UUID.generate()}/status", tenant,
          roles: ["PLATFORM_ADMIN"],
          body: %{"status" => "inactive"}
        )
        |> dispatch()

      assert conn.status == 404
    end
  end
end
