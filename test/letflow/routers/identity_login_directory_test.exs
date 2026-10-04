defmodule Letflow.Routers.IdentityLoginDirectoryTest do
  @moduledoc """
  REQ-435 -- the HTTP layer of the login-directory writers: `POST /users`,
  `PATCH /users/:id` and `POST /users/:id/status` maintain
  `tenant_login_directory` in the same transaction, with the tenant id taken
  from the authenticated `auth_context` and never from the request. Dispatch
  mechanism as in `test/letflow/routers/identity_test.exs` (REQ-073 design §6b).
  See `test/specs/REQ-435.md`.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Identity.User
  alias Letflow.Test.LoginDirectoryFixture, as: Fx

  @opts Letflow.Routers.Identity.init([])

  defp dispatch(method, path, tenant, body) do
    conn(method, path)
    |> Map.put(:body_params, body || %{})
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant.tenant_id,
      roles: ["PLATFORM_ADMIN"]
    })
    |> assign(:trace_id, "fixed-test-trace-id")
    |> Letflow.Routers.Identity.call(@opts)
  end

  defp post_user(tenant, email, extra \\ %{}) do
    body =
      Map.merge(
        %{
          "username" => "u#{System.unique_integer([:positive])}",
          "display_name" => "Router Person",
          "email" => email
        },
        extra
      )

    dispatch(:post, "/users", tenant, body)
  end

  defp keys(tenant), do: tenant.tenant_id |> Fx.entries() |> Enum.map(& &1.email_key)

  describe "POST /users" do
    test "'Alice@Example.com ' produces exactly one entry for (normalised key, tenant A)" do
      a = Fx.tenant!()
      b = Fx.tenant!()

      conn = post_user(a, "Alice@Example.com ")

      assert conn.status == 201
      assert %{"id" => id} = Jason.decode!(conn.resp_body)
      assert Repo.get!(User, id, prefix: a.schema_name)
      assert keys(a) == [Fx.key!("alice@example.com")]
      assert Fx.entries(b.tenant_id) == []
    end

    test "a forced audit-append failure leaves neither the user nor the entry (same transaction)" do
      a = Fx.tenant!()
      Repo.query!(~s(DROP TABLE "#{a.schema_name}".audit_entries))

      conn = post_user(a, "atomic@example.test")

      assert conn.status == 500
      assert Fx.user_count(a.schema_name) == 0
      assert Fx.entries(a.tenant_id) == []
    end

    test "a directory failure is a 500 and leaves neither user nor entry" do
      a = Fx.tenant!()
      Fx.swap_keys!(:unset, nil)

      conn = post_user(a, "dirfail@example.test")

      assert conn.status == 500
      refute conn.resp_body =~ "dirfail"
      assert Fx.user_count(a.schema_name) == 0
      assert Fx.entries(a.tenant_id) == []
    end

    test "tenant_id source: a body tenant_id and a query tenant_id naming tenant B change nothing" do
      a = Fx.tenant!()
      b = Fx.tenant!()

      conn =
        dispatch(:post, "/users?tenant_id=#{b.tenant_id}", a, %{
          "username" => "u#{System.unique_integer([:positive])}",
          "display_name" => "Spoof",
          "email" => "spoof@example.test",
          "tenant_id" => b.tenant_id
        })

      assert conn.status == 201
      assert Fx.entries(b.tenant_id) == []
      assert Fx.user_count(b.schema_name) == 0
      assert keys(a) == [Fx.key!("spoof@example.test")]
    end

    test "the same email created in tenant A and tenant B yields one entry in each" do
      a = Fx.tenant!()
      b = Fx.tenant!()

      assert post_user(a, "shared@example.test").status == 201
      assert post_user(b, "shared@example.test").status == 201

      assert keys(a) == [Fx.key!("shared@example.test")]
      assert keys(b) == [Fx.key!("shared@example.test")]
    end

    test "a duplicate username (409) leaves only the first entry" do
      a = Fx.tenant!()
      assert post_user(a, "first@example.test", %{"username" => "samename"}).status == 201
      assert post_user(a, "second@example.test", %{"username" => "samename"}).status == 409

      assert keys(a) == [Fx.key!("first@example.test")]
    end
  end

  describe "PATCH /users/:id and POST /users/:id/status" do
    test "profile email change moves the entry; status inactive removes it; tenant comes from auth_context" do
      a = Fx.tenant!()
      b = Fx.tenant!()

      %{"id" => id} =
        a |> post_user("start@example.test") |> Map.fetch!(:resp_body) |> Jason.decode!()

      conn =
        dispatch(:patch, "/users/#{id}", a, %{
          "email" => "moved@example.test",
          "tenant_id" => b.tenant_id
        })

      assert conn.status == 200
      assert keys(a) == [Fx.key!("moved@example.test")]
      assert Fx.entries(b.tenant_id) == []

      conn =
        dispatch(:post, "/users/#{id}/status", a, %{
          "status" => "inactive",
          "tenant_id" => b.tenant_id
        })

      assert conn.status == 200
      assert Fx.entries(a.tenant_id) == []
      assert Fx.entries(b.tenant_id) == []
    end

    test "a user id from tenant A addressed with tenant B's auth_context is 404 and changes no entry" do
      a = Fx.tenant!()
      b = Fx.tenant!()

      %{"id" => id} =
        a |> post_user("owner@example.test") |> Map.fetch!(:resp_body) |> Jason.decode!()

      assert dispatch(:post, "/users/#{id}/status", b, %{"status" => "inactive"}).status == 404
      assert dispatch(:patch, "/users/#{id}", b, %{"email" => "x@example.test"}).status == 404

      assert keys(a) == [Fx.key!("owner@example.test")]
      assert Fx.entries(b.tenant_id) == []
    end

    test "status change with a forced audit failure leaves entry and status unchanged (500)" do
      a = Fx.tenant!()

      %{"id" => id} =
        a |> post_user("keep@example.test") |> Map.fetch!(:resp_body) |> Jason.decode!()

      Repo.query!(~s(DROP TABLE "#{a.schema_name}".audit_entries))

      assert dispatch(:post, "/users/#{id}/status", a, %{"status" => "inactive"}).status == 500

      assert Repo.get!(User, id, prefix: a.schema_name).status == :active
      assert keys(a) == [Fx.key!("keep@example.test")]
    end
  end
end
