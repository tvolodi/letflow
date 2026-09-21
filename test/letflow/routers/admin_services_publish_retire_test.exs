defmodule Letflow.Routers.AdminServicesPublishRetireTest do
  @moduledoc """
  Router-level tests for `Letflow.Routers.AdminServices`'s two REQ-373 routes:
  `POST /:service_id/versions` (publish) and `POST /:service_id/retire`
  (retire). See `test/specs/req373-service-catalog-version-lifecycle.md`
  (AC6) for the full rationale. Design authority:
  `lib/letflow/design/req373-service-catalog-version-lifecycle.md` §7.

  **Scope, deliberately narrow, matching `admin_services_test.exs`'s own
  precedent:** this file covers only these two new routes' `:AdminServicesManage`
  permission gate (both halves — rejected without it, succeeds with it) plus
  the minimum success/error-mapping coverage needed to make the "succeeds"
  half of that gate a genuine assertion rather than a 2xx-status-code-only
  check. `GET /`, `POST /`, `PATCH /:service_id`, `DELETE /:service_id` are
  already covered by `admin_services_test.exs` (partially) and
  `service_catalog_test.exs`'s own context-module-level tests — not
  re-covered here.

  **Deviation from the WF02-REQ373-20260921 Step 3 handoff's `owned_modules`
  naming, noted explicitly (also recorded in the spec doc):** the handoff
  lists `test/letflow_web/admin_services*`. No `test/letflow_web/` directory
  exists anywhere in this codebase; every router test, including this file's
  own established precedent (`admin_services_test.exs`), lives under
  `test/letflow/routers/`. This file follows the codebase's actual,
  established convention.

  Uses `Letflow.DataCase` (real Postgres, per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1). Dispatch is direct
  `Letflow.Routers.AdminServices.call/2` with `conn.assigns[:auth_context]`
  set directly, matching `admin_services_test.exs`'s and
  `tenants_test.exs`'s own established idiom for this class of router test.

  `async: false`: `service_catalog` is a GLOBAL table with no sandboxed-
  transaction isolation, same reasoning `service_catalog_test.exs`/
  `admin_services_test.exs` each document for themselves. Every row this file
  creates is deleted in `on_exit/1`.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.ServiceCatalog
  alias Letflow.ServiceCatalog.Entry
  alias Letflow.ServiceCatalog.Version

  @opts Letflow.Routers.AdminServices.init([])

  setup do
    Sandbox.mode(Letflow.Repo, :auto)
    :ok
  end

  # ── Shared test dispatch helper (matches admin_services_test.exs's/tenants_test.exs's build_conn/4 shape) ──

  defp build_conn(method, path, fields) do
    roles = Keyword.get(fields, :roles, [])
    body = Keyword.get(fields, :body, nil)

    conn = conn(method, path)

    conn =
      if body do
        %{conn | body_params: body} |> put_req_header("content-type", "application/json")
      else
        conn
      end

    conn
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: Ecto.UUID.generate(),
      roles: roles
    })
    |> assign(:trace_id, "fixed-test-trace-id")
  end

  defp dispatch(conn), do: Letflow.Routers.AdminServices.call(conn, @opts)

  # ── Fixture helpers (mirrors service_catalog_test.exs's/admin_services_test.exs's own precedent) ──

  defp unique_service_id(prefix \\ "req373-admin-router-svc") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp cleanup_entry!(service_id) do
    Repo.delete_all(from(v in Version, where: v.service_id == ^service_id))
    Repo.delete_all(from(e in Entry, where: e.service_id == ^service_id))
  end

  defp register!(overrides \\ %{}) do
    attrs =
      %{
        service_id: unique_service_id(),
        endpoint_url: "https://example.test/svc",
        required_auth: :NONE,
        timeout_ms: 5_000,
        scope: :global
      }
      |> Map.merge(overrides)

    on_exit(fn -> cleanup_entry!(attrs.service_id) end)
    assert {:ok, entry} = ServiceCatalog.register(attrs)
    entry
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC6 -- POST /:service_id/versions (publish) permission gate
  # ══════════════════════════════════════════════════════════════════════

  describe "POST /:service_id/versions as a non-PLATFORM_ADMIN caller" do
    test "returns 403 before ever reaching publish/3 -- no new version created" do
      entry = register!()

      resp =
        build_conn(:post, "/#{entry.service_id}/versions",
          roles: ["PROCESS_DESIGNER"],
          body: %{
            "version" => "2",
            "endpoint_url" => "https://example.test/svc-v2",
            "timeout_ms" => 6000
          }
        )
        |> dispatch()

      assert resp.status == 403
      assert Jason.decode!(resp.resp_body)["detail"] == "insufficient permissions"

      # No version bump happened -- the row is untouched.
      reloaded = Repo.get(Entry, entry.service_id)
      assert reloaded.version == "1"
    end
  end

  describe "POST /:service_id/versions as PLATFORM_ADMIN" do
    test "succeeds (201), bumps the live row, and returns the published version's fields" do
      entry = register!()

      resp =
        build_conn(:post, "/#{entry.service_id}/versions",
          roles: ["PLATFORM_ADMIN"],
          body: %{
            "version" => "2",
            "endpoint_url" => "https://example.test/svc-v2",
            "timeout_ms" => 6000
          }
        )
        |> dispatch()

      assert resp.status == 201
      body = Jason.decode!(resp.resp_body)

      assert body["service_id"] == entry.service_id
      assert body["version"] == "2"
      assert body["status"] == "ACTIVE"
      assert body["endpoint_url"] == "https://example.test/svc-v2"
      assert body["version_id"] != entry.version_id

      reloaded = Repo.get(Entry, entry.service_id)
      assert reloaded.version == "2"
    end

    test "a duplicate version against the current row returns 409, naming the conflict" do
      entry = register!()

      resp =
        build_conn(:post, "/#{entry.service_id}/versions",
          roles: ["PLATFORM_ADMIN"],
          body: %{
            "version" => entry.version,
            "endpoint_url" => "https://example.test/svc-dup",
            "timeout_ms" => 6000
          }
        )
        |> dispatch()

      assert resp.status == 409
    end

    test "a nonexistent service_id returns 404" do
      resp =
        build_conn(:post, "/#{unique_service_id("req373-admin-router-missing")}/versions",
          roles: ["PLATFORM_ADMIN"],
          body: %{
            "version" => "2",
            "endpoint_url" => "https://example.test/svc-v2",
            "timeout_ms" => 6000
          }
        )
        |> dispatch()

      assert resp.status == 404
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC6 -- POST /:service_id/retire permission gate
  # ══════════════════════════════════════════════════════════════════════

  describe "POST /:service_id/retire as a non-PLATFORM_ADMIN caller" do
    test "returns 403 before ever reaching retire/1 -- the row's status is untouched" do
      entry = register!()

      resp =
        build_conn(:post, "/#{entry.service_id}/retire", roles: ["PROCESS_DESIGNER"])
        |> dispatch()

      assert resp.status == 403
      assert Jason.decode!(resp.resp_body)["detail"] == "insufficient permissions"

      reloaded = Repo.get(Entry, entry.service_id)
      assert reloaded.status == :ACTIVE
    end

    test "a caller with no roles at all is denied identically" do
      entry = register!()

      resp = build_conn(:post, "/#{entry.service_id}/retire", roles: []) |> dispatch()

      assert resp.status == 403
    end
  end

  describe "POST /:service_id/retire as PLATFORM_ADMIN" do
    test "succeeds (200) and the row transitions to RETIRED" do
      entry = register!()

      resp =
        build_conn(:post, "/#{entry.service_id}/retire", roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      assert body["service_id"] == entry.service_id
      assert body["status"] == "RETIRED"

      reloaded = Repo.get(Entry, entry.service_id)
      assert reloaded.status == :RETIRED
    end

    test "retiring an already-RETIRED row returns 409, not a silent success" do
      entry = register!()

      first_resp =
        build_conn(:post, "/#{entry.service_id}/retire", roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert first_resp.status == 200

      resp =
        build_conn(:post, "/#{entry.service_id}/retire", roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert resp.status == 409
    end

    test "a nonexistent service_id returns 404" do
      resp =
        build_conn(
          :post,
          "/#{unique_service_id("req373-admin-router-missing")}/retire",
          roles: ["PLATFORM_ADMIN"]
        )
        |> dispatch()

      assert resp.status == 404
    end
  end
end
