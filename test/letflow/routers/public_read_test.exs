defmodule Letflow.Routers.PublicReadTest do
  @moduledoc """
  Router/plug-chain-level tests for REQ-352's `/api/public/:kind/:handle`
  mount (`test/specs/REQ-352.md`). Full `Letflow.Router` end to end via
  `Plug.Test`, matching `test/letflow/router_test.exs`'s own convention (a
  real HTTP-shaped conn through `Letflow.Router.call/2`, not a bare call
  into `Letflow.Routers.PublicRead` directly, so AC-1's "never enters
  `Letflow.Plugs.AuthPipeline`" claim is proven against the actual mount
  point, not assumed).

  `async: false` -- required because `PublicReadFixtureSupport.provision_tenant!/0`
  calls `Letflow.TenantFixture.provisioned_tenant!/1` with `template: :replay`,
  which switches `Letflow.Repo` to Sandbox `:auto` mode for real schema
  creation, the same requirement stated (and empirically confirmed, not
  merely asserted) by every other `template: :replay` call site in this
  suite (`test/letflow/tenant_provisioning/backfill_test.exs`,
  `test/support/tenant_fixture_dispatch_test.exs`).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.PublicReadFixtureSupport

  @opts Letflow.Router.init([])

  defp call(conn), do: Letflow.Router.call(conn, @opts)

  defp get_public(path) do
    conn(:get, path) |> call()
  end

  describe "AC-1: an unauthenticated request reaches the public router, not AuthPipeline" do
    test "a valid, unauthenticated GET succeeds with 200 -- proving it never asked for auth" do
      %{tenant_id: tenant_id, schema_name: schema} = PublicReadFixtureSupport.provision_tenant!()
      resource = PublicReadFixtureSupport.insert_resource!(schema, %{publishable: true})
      plaintext = PublicReadFixtureSupport.issue_handle!(tenant_id, resource.id)

      conn = get_public("/api/public/#{PublicReadFixtureSupport.kind()}/#{plaintext}")

      # No Authorization header was ever set on this conn -- if this route
      # entered Letflow.Plugs.AuthPipeline (which has no public-path bypass,
      # per Letflow.Routers.PublicRead's own moduledoc), it would 401, not 200.
      assert conn.status == 200
      refute conn.status == 401
      refute conn.status == 403
    end
  end

  describe "AC-4/AC-5: the ten refusal cases are byte-identical to each other, never 401/403" do
    setup do
      %{tenant_id: tenant_id, schema_name: schema} = PublicReadFixtureSupport.provision_tenant!()

      live_resource = PublicReadFixtureSupport.insert_resource!(schema, %{publishable: true})

      unpublishable_resource =
        PublicReadFixtureSupport.insert_resource!(schema, %{publishable: false})

      deleted_resource = PublicReadFixtureSupport.insert_resource!(schema, %{publishable: true})

      revoked_handle = PublicReadFixtureSupport.issue_handle!(tenant_id, live_resource.id)
      PublicReadFixtureSupport.revoke_handle!(revoked_handle)

      expired_handle =
        PublicReadFixtureSupport.issue_handle!(
          tenant_id,
          live_resource.id,
          PublicReadFixtureSupport.kind(),
          expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        )

      mismatched_handle = PublicReadFixtureSupport.issue_handle!(tenant_id, live_resource.id)

      unpublishable_handle =
        PublicReadFixtureSupport.issue_handle!(tenant_id, unpublishable_resource.id)

      deleted_handle = PublicReadFixtureSupport.issue_handle!(tenant_id, deleted_resource.id)
      Letflow.Repo.delete!(deleted_resource, prefix: schema)

      valid_handle_for_method_case =
        PublicReadFixtureSupport.issue_handle!(tenant_id, live_resource.id)

      deactivated_tenant = PublicReadFixtureSupport.provision_tenant!()

      deactivated_resource =
        PublicReadFixtureSupport.insert_resource!(deactivated_tenant.schema_name, %{
          publishable: true
        })

      deactivated_handle =
        PublicReadFixtureSupport.issue_handle!(
          deactivated_tenant.tenant_id,
          deactivated_resource.id
        )

      deactivated_tenant.tenant
      |> Letflow.Identity.Tenant.status_changeset(%{status: :inactive})
      |> Letflow.Repo.update!()

      %{
        revoked_handle: revoked_handle,
        expired_handle: expired_handle,
        mismatched_handle: mismatched_handle,
        unpublishable_handle: unpublishable_handle,
        deleted_handle: deleted_handle,
        valid_handle_for_method_case: valid_handle_for_method_case,
        deactivated_handle: deactivated_handle
      }
    end

    test "all ten refusal cases produce byte-identical 404 bodies and never 401/403", ctx do
      kind = PublicReadFixtureSupport.kind()

      cases = [
        {"malformed handle", get_public("/api/public/#{kind}/not-a-valid-handle!!")},
        {"unknown handle",
         get_public("/api/public/#{kind}/#{PublicReadFixtureSupport.unknown_handle()}")},
        {"revoked", get_public("/api/public/#{kind}/#{ctx.revoked_handle}")},
        {"expired", get_public("/api/public/#{kind}/#{ctx.expired_handle}")},
        {"kind-mismatched",
         get_public(
           "/api/public/#{PublicReadFixtureSupport.mismatched_kind()}/#{ctx.mismatched_handle}"
         )},
        {"resource deleted", get_public("/api/public/#{kind}/#{ctx.deleted_handle}")},
        {"resource unpublishable", get_public("/api/public/#{kind}/#{ctx.unpublishable_handle}")},
        {"unregistered kind",
         get_public(
           "/api/public/not-a-registered-kind/#{PublicReadFixtureSupport.unknown_handle()}"
         )},
        {"wrong method",
         conn(:post, "/api/public/#{kind}/#{ctx.valid_handle_for_method_case}") |> call()},
        {"deactivated tenant", get_public("/api/public/#{kind}/#{ctx.deactivated_handle}")}
      ]

      for {name, conn} <- cases do
        refute conn.status == 401, "case #{inspect(name)} returned 401"
        refute conn.status == 403, "case #{inspect(name)} returned 403"
        assert conn.status == 404, "case #{inspect(name)} expected 404, got #{conn.status}"
      end

      bodies = Enum.map(cases, fn {_name, conn} -> conn.resp_body end)
      distinct = Enum.uniq(bodies)

      assert length(distinct) == 1,
             "expected all ten refusal cases to produce a byte-identical body; got " <>
               "#{length(distinct)} distinct bodies across cases: " <>
               inspect(Enum.zip(Enum.map(cases, &elem(&1, 0)), bodies))
    end
  end

  describe "AC-9: response headers on a successful resolution" do
    test "Cache-Control, Referrer-Policy and X-Robots-Tag are all present" do
      %{tenant_id: tenant_id, schema_name: schema} = PublicReadFixtureSupport.provision_tenant!()
      resource = PublicReadFixtureSupport.insert_resource!(schema, %{publishable: true})
      plaintext = PublicReadFixtureSupport.issue_handle!(tenant_id, resource.id)

      conn = get_public("/api/public/#{PublicReadFixtureSupport.kind()}/#{plaintext}")

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
      assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
    end
  end

  describe "AC-10: kind-registry dispatch" do
    test "dispatches to the registered test-only fixture kind" do
      %{tenant_id: tenant_id, schema_name: schema} = PublicReadFixtureSupport.provision_tenant!()
      resource = PublicReadFixtureSupport.insert_resource!(schema, %{publishable: true})
      plaintext = PublicReadFixtureSupport.issue_handle!(tenant_id, resource.id)

      conn = get_public("/api/public/#{PublicReadFixtureSupport.kind()}/#{plaintext}")

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["kind"] == PublicReadFixtureSupport.kind()
      assert body["data"] == %{"label" => "fixture"}
    end

    test "404s an unregistered kind" do
      conn =
        get_public(
          "/api/public/not-a-registered-kind/#{PublicReadFixtureSupport.unknown_handle()}"
        )

      assert conn.status == 404
    end
  end
end
