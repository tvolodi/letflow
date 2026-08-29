defmodule Letflow.Routers.WebhooksTest do
  @moduledoc """
  Tests for `Letflow.Routers.Webhooks` (REQ-182) -- the route/controller
  layer atop REQ-181's `Letflow.Webhooks` context module. See
  `test/specs/REQ-182.md` for the full acceptance-criterion -> test-case
  mapping and rationale. Design authority:
  `lib/letflow/design/req182-webhooks-routes.md`.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1, matching
  `test/letflow/routers/dlq_test.exs`'s own established idiom for this
  class of router test (itself mirroring `tasks_test.exs`): direct
  `Letflow.Routers.Webhooks.call/2` dispatch, `conn.assigns[:auth_context]`
  set directly (bypassing `AuthPipeline`), `Letflow.TenantFixture.provisioned_tenant!/1`
  for real tenant schemas, and the same cross-tenant-identical-404 idiom.
  `async: false` for the same reason every other tenant-fixture-using test
  file in this codebase sets it (real schema creation/teardown against one
  shared Postgres instance).

  Dispatch paths are `/subscriptions` and `/subscriptions/:id` -- the
  router's own local `Plug.Router` match patterns (design §2): this router
  is mounted at `/webhooks` by `Letflow.Plugs.ApiPipeline`, but dispatching
  directly at the module (as this file does, matching `dlq_test.exs`'s own
  precedent) means the mount prefix is never part of the path passed to
  `call/2`.

  This file does not modify, and does not duplicate the coverage of,
  `test/letflow/webhooks_test.exs` (REQ-181) -- that file exercises
  `Letflow.Webhooks` directly with no HTTP layer; this file exercises only
  the new router/response-shaping code added by REQ-182.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.TenantFixture

  @opts Letflow.Routers.Webhooks.init([])

  # ── Shared test dispatch helper (matches dlq_test.exs's build_conn/4 shape) ──

  defp build_conn(method, path, tenant, fields) do
    roles = Keyword.get(fields, :roles, [])
    user_id = Keyword.get(fields, :user_id, Ecto.UUID.generate())

    conn(method, path)
    |> assign(:auth_context, %{
      user_id: user_id,
      tenant_id: tenant.tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "fixed-test-trace-id")
  end

  defp json_conn(method, path, tenant, fields, body) do
    build_conn(method, path, tenant, fields)
    |> put_req_header("content-type", "application/json")
    |> Map.put(:body_params, body)
  end

  defp dispatch(conn), do: Letflow.Routers.Webhooks.call(conn, @opts)

  # ── Fixture helpers ──────────────────────────────────────────────────────

  defp provisioned_tenant(slug_prefix) do
    TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-182 Webhooks Router Test Tenant"
    )
  end

  defp create_subscription(tenant, roles, body \\ %{"target_url" => "https://example.com/hook"}) do
    conn =
      json_conn(:post, "/subscriptions", tenant, [roles: roles], body)
      |> dispatch()

    {conn, Jason.decode!(conn.resp_body)}
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC1 -- POST returns hmac_secret_once exactly once; GET/list never do
  # ══════════════════════════════════════════════════════════════════════

  describe "AC1: hmac_secret_once appears once on create, never on read" do
    test "POST /subscriptions with no secret supplied returns 2xx with hmac_secret_once carrying the plaintext" do
      tenant = provisioned_tenant("req182-secret-create")

      {conn, body} = create_subscription(tenant, ["PLATFORM_ADMIN"])

      assert conn.status == 201
      assert is_binary(body["hmac_secret_once"])
      assert body["hmac_secret_once"] != ""
      refute Map.has_key?(body, "secret_hash")
    end

    test "a subsequent GET list of the same subscription never includes hmac_secret_once or a raw secret" do
      tenant = provisioned_tenant("req182-secret-list")

      {_conn, created} = create_subscription(tenant, ["PLATFORM_ADMIN"])

      list_conn = build_conn(:get, "/subscriptions", tenant, roles: ["PLATFORM_ADMIN"]) |> dispatch()
      list_body = Jason.decode!(list_conn.resp_body)

      assert [item] = list_body["items"]
      assert item["id"] == created["id"]
      refute Map.has_key?(item, "hmac_secret_once")
      refute Map.has_key?(item, "secret_hash")
      refute Map.has_key?(item, "secret")

      # The full response body, serialized, never contains the plaintext secret.
      refute list_conn.resp_body =~ created["hmac_secret_once"]
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC2 -- PATCH via status/is_active both reconcile to PAUSED and read back
  # ══════════════════════════════════════════════════════════════════════

  describe "AC2: PATCH accepts status or is_active, both reading back as PAUSED" do
    test "PATCH {status: \"PAUSED\"} reads back as PAUSED via GET and list" do
      tenant = provisioned_tenant("req182-patch-status")
      {_conn, created} = create_subscription(tenant, ["PLATFORM_ADMIN"])

      patch_conn =
        json_conn(:patch, "/subscriptions/#{created["id"]}", tenant, [roles: ["PLATFORM_ADMIN"]], %{
          "status" => "PAUSED"
        })
        |> dispatch()

      assert patch_conn.status == 200
      patched = Jason.decode!(patch_conn.resp_body)
      assert patched["status"] == "PAUSED"

      list_conn = build_conn(:get, "/subscriptions", tenant, roles: ["PLATFORM_ADMIN"]) |> dispatch()
      list_body = Jason.decode!(list_conn.resp_body)
      assert [item] = list_body["items"]
      assert item["status"] == "PAUSED"
    end

    test "PATCH {is_active: false} reads back as PAUSED via GET and list" do
      tenant = provisioned_tenant("req182-patch-is-active")
      {_conn, created} = create_subscription(tenant, ["PLATFORM_ADMIN"])

      patch_conn =
        json_conn(:patch, "/subscriptions/#{created["id"]}", tenant, [roles: ["PLATFORM_ADMIN"]], %{
          "is_active" => false
        })
        |> dispatch()

      assert patch_conn.status == 200
      patched = Jason.decode!(patch_conn.resp_body)
      assert patched["status"] == "PAUSED"

      list_conn = build_conn(:get, "/subscriptions", tenant, roles: ["PLATFORM_ADMIN"]) |> dispatch()
      list_body = Jason.decode!(list_conn.resp_body)
      assert [item] = list_body["items"]
      assert item["status"] == "PAUSED"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC3 -- every route requires WebhooksManage: 403 without it; cross-tenant
  # real id -> 404, never 403
  # ══════════════════════════════════════════════════════════════════════

  describe "AC3: every subscription route requires WebhooksManage" do
    test "GET /subscriptions -> 403 for a caller with no role holding WebhooksManage" do
      tenant = provisioned_tenant("req182-403-list")

      conn = build_conn(:get, "/subscriptions", tenant, roles: ["TASK_WORKER"]) |> dispatch()

      assert conn.status == 403
    end

    test "POST /subscriptions -> 403 for a caller with no role holding WebhooksManage" do
      tenant = provisioned_tenant("req182-403-create")

      conn =
        json_conn(:post, "/subscriptions", tenant, [roles: ["TASK_WORKER"]], %{
          "target_url" => "https://example.com/hook"
        })
        |> dispatch()

      assert conn.status == 403
    end

    test "PATCH /subscriptions/:id -> 403 for a caller with no role holding WebhooksManage" do
      tenant = provisioned_tenant("req182-403-update")
      {_conn, created} = create_subscription(tenant, ["PLATFORM_ADMIN"])

      conn =
        json_conn(:patch, "/subscriptions/#{created["id"]}", tenant, [roles: ["TASK_WORKER"]], %{
          "status" => "PAUSED"
        })
        |> dispatch()

      assert conn.status == 403

      # No state change on 403.
      list_conn = build_conn(:get, "/subscriptions", tenant, roles: ["PLATFORM_ADMIN"]) |> dispatch()
      [item] = Jason.decode!(list_conn.resp_body)["items"]
      assert item["status"] == "ACTIVE"
    end

    test "DELETE /subscriptions/:id -> 403 for a caller with no role holding WebhooksManage" do
      tenant = provisioned_tenant("req182-403-delete")
      {_conn, created} = create_subscription(tenant, ["PLATFORM_ADMIN"])

      conn =
        build_conn(:delete, "/subscriptions/#{created["id"]}", tenant, roles: ["TASK_WORKER"])
        |> dispatch()

      assert conn.status == 403

      # Still present afterward.
      list_conn = build_conn(:get, "/subscriptions", tenant, roles: ["PLATFORM_ADMIN"]) |> dispatch()
      assert length(Jason.decode!(list_conn.resp_body)["items"]) == 1
    end

    test "a caller from a different tenant naming a real subscription id gets 404, never 403" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req182-cross-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req182-cross-b")

      {_conn, created_in_b} = create_subscription(tenant_b, ["PLATFORM_ADMIN"])

      patch_conn =
        json_conn(:patch, "/subscriptions/#{created_in_b["id"]}", tenant_a, [roles: ["PLATFORM_ADMIN"]], %{
          "status" => "PAUSED"
        })
        |> dispatch()

      delete_conn =
        build_conn(:delete, "/subscriptions/#{created_in_b["id"]}", tenant_a, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert patch_conn.status == 404
      assert delete_conn.status == 404

      # Cross-tenant-404 identical to a genuinely-absent id (INV-5).
      never_existed_conn =
        json_conn(:patch, "/subscriptions/#{Ecto.UUID.generate()}", tenant_a, [roles: ["PLATFORM_ADMIN"]], %{
          "status" => "PAUSED"
        })
        |> dispatch()

      assert never_existed_conn.status == 404
      assert never_existed_conn.resp_body == patch_conn.resp_body

      # Tenant B's row is untouched.
      list_b_conn = build_conn(:get, "/subscriptions", tenant_b, roles: ["PLATFORM_ADMIN"]) |> dispatch()
      [item_b] = Jason.decode!(list_b_conn.resp_body)["items"]
      assert item_b["status"] == "ACTIVE"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC4 -- GET /subscriptions list shape
  # ══════════════════════════════════════════════════════════════════════

  describe "AC4: GET /subscriptions returns {items: [...]} with the consumer-shaped fields" do
    test "each item has target_url/event_types/status/created_at present" do
      tenant = provisioned_tenant("req182-shape")

      {_conn, _created} =
        create_subscription(tenant, ["PLATFORM_ADMIN"], %{
          "target_url" => "https://example.com/hook",
          "event_types" => ["instance.completed"]
        })

      list_conn = build_conn(:get, "/subscriptions", tenant, roles: ["PLATFORM_ADMIN"]) |> dispatch()

      assert list_conn.status == 200
      body = Jason.decode!(list_conn.resp_body)

      assert Map.keys(body) == ["items"]
      assert [item] = body["items"]

      assert item["target_url"] == "https://example.com/hook"
      assert item["event_types"] == ["instance.completed"]
      assert item["status"] == "ACTIVE"
      assert is_binary(item["created_at"])
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC5 -- DELETE removes the subscription; a second DELETE returns 404
  # ══════════════════════════════════════════════════════════════════════

  describe "AC5: DELETE removes the subscription; second DELETE is 404, not a duplicate success" do
    test "DELETE removes the subscription such that a subsequent list excludes it" do
      tenant = provisioned_tenant("req182-delete")
      {_conn, created} = create_subscription(tenant, ["PLATFORM_ADMIN"])

      delete_conn =
        build_conn(:delete, "/subscriptions/#{created["id"]}", tenant, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert delete_conn.status == 204

      list_conn = build_conn(:get, "/subscriptions", tenant, roles: ["PLATFORM_ADMIN"]) |> dispatch()
      assert Jason.decode!(list_conn.resp_body)["items"] == []
    end

    test "a second DELETE of the same id returns 404, not a duplicate success" do
      tenant = provisioned_tenant("req182-delete-twice")
      {_conn, created} = create_subscription(tenant, ["PLATFORM_ADMIN"])

      first_delete =
        build_conn(:delete, "/subscriptions/#{created["id"]}", tenant, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      second_delete =
        build_conn(:delete, "/subscriptions/#{created["id"]}", tenant, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert first_delete.status == 204
      assert second_delete.status == 404
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC (moduledoc) -- R-Co webhooks.zig non-inspection is documented
  # ══════════════════════════════════════════════════════════════════════

  describe "moduledoc states R-Co's webhooks.zig was not inspected and names the real binding contract" do
    test "moduledoc mentions webhooks.zig, 'not inspected', and the web/ contract files" do
      {:docs_v1, _anno, _lang, _fmt, %{"en" => moduledoc}, _meta, _} =
        Code.fetch_docs(Letflow.Routers.Webhooks)

      assert moduledoc =~ "webhooks.zig"
      assert moduledoc =~ "not inspected"
      assert moduledoc =~ "web/src/api/dlq.ts"
      assert moduledoc =~ "web/src/types/api.ts"
    end
  end
end
