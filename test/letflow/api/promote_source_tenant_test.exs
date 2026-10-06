defmodule Letflow.Api.PromoteSourceTenantTest do
  @moduledoc """
  ISS-0993 / ISS-0994 design section 12 item 20, NAMED TEST `promote_route_source_tenant_equals_own`,
  A2 ENFORCING variant (spec `test/specs/ISS-0993-A2.md`): row 34,
  `POST /tenants/:test_tenant_id/promote/:process_key`.

  A non-operator may name only its OWN tenant as the promotion source; the platform operator may
  name any tenant (OQ-2). The denial is decided by `Letflow.Api.TenantTarget.authorize_target_tenant/2`
  BEFORE any lookup, so the source tenant's existence is not observable and its schema is never
  queried. Cases (every `Repo` query issued by the request is captured with the
  `[:letflow, :repo, :query]` telemetry event, filtered to the calling process):

    * (a) A's `PLATFORM_ADMIN` naming A's own id (also upper-cased) passes authorization: the
      domain logic runs (queries against A's schema are observed, and the outcome is the domain
      one, not the zero-detail authorization 404);
    * (b) A naming B (an EXISTING tenant) and A naming a random unused UUID answer the SAME 404:
      identical status, body bytes and content-type header, never 403, never 200; neither request
      issues a single query that touches B (schema name or tenant id), the two requests issue the
      same number of queries, and B's data is unchanged;
    * (c) a malformed id, B's slug, an over-long string: the same 404 bytes and the same
      no-query-against-B assertion;
    * (d) the platform operator (P `PLATFORM_ADMIN`) naming B proceeds (201, B's schema is
      queried: this is also the control that proves the query capture is not vacuous).

  Other roles get 403 whatever source they name; with no platform tenant configured nobody is the
  operator, so the would-be operator is held to the own-tenant rule too.

  INV-10 check, enforced from the merge of Q-960 PR A. `async: false` (VM-global pin and query
  telemetry).
  """

  use Letflow.DataCase, async: false

  import Plug.Conn, only: [get_resp_header: 2]

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  @process_key "iss0993-promote-src"

  defp promote(fixture, source_id, roles, process_key \\ "no-such-process") do
    Letflow.Routers.Tenants.call(
      Fixture.router_conn(
        :post,
        "/#{URI.encode(source_id, &URI.char_unreserved?/1)}/promote/#{process_key}",
        fixture,
        roles,
        nil
      ),
      Letflow.Routers.Tenants.init([])
    )
  end

  defp promote_captured(fixture, source_id, roles, process_key \\ "no-such-process") do
    Fixture.capture_repo_queries(fn -> promote(fixture, source_id, roles, process_key) end)
  end

  defp insert_active_definition!(fixture, name) do
    definition =
      %ProcessDefinition{}
      |> ProcessDefinition.create_changeset(%{
        name: name,
        version: "1.0.0",
        graph: %{
          "nodes" => [
            %{"id" => "start", "node_type" => "START"},
            %{"id" => "end", "node_type" => "END"}
          ],
          "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
        },
        created_by: Ecto.UUID.generate()
      })
      |> Repo.insert!(prefix: fixture.schema_name)

    assert {:ok, %{num_rows: 1}} =
             Repo.query(
               ~s(UPDATE "#{fixture.schema_name}"."process_definitions" SET status = 'active' ) <>
                 "WHERE id = $1 AND status = 'draft'",
               [Ecto.UUID.dump!(definition.id)]
             )

    definition
  end

  defp definition_rows(fixture) do
    ProcessDefinition
    |> Repo.all(prefix: fixture.schema_name)
    |> Enum.map(&{&1.id, &1.name, &1.version, &1.status})
    |> Enum.sort()
  end

  defp content_type(resp), do: get_resp_header(resp, "content-type")

  defp touching(queries, fixture), do: Enum.filter(queries, &Fixture.touches_tenant?(&1, fixture))

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  describe "(a) the caller's own id" do
    test "passes authorization: the domain logic runs against the caller's own schema", ctx do
      insert_active_definition!(ctx.a, @process_key)

      for source <- [ctx.a.tenant_id, String.upcase(ctx.a.tenant_id)] do
        {resp, queries} = promote_captured(ctx.a, source, ["PLATFORM_ADMIN"], @process_key)

        # source == target == A: the domain rejects re-promoting an existing version (409), which
        # is NOT the authorization 404: the request got past TenantTarget.
        assert resp.status == 409, "#{source}: #{resp.status}"
        assert touching(queries, ctx.a) != [], "#{source}: A's schema must have been read"
      end
    end

    test "an own-id request for a process key nobody defines is the domain 404, after reading A",
         ctx do
      {resp, queries} = promote_captured(ctx.a, ctx.a.tenant_id, ["PLATFORM_ADMIN"])

      assert resp.status == 404
      assert touching(queries, ctx.a) != []
    end
  end

  describe "(b) another existing tenant versus a random unused UUID" do
    test "the same 404 bytes, and neither request touches B", ctx do
      insert_active_definition!(ctx.b, @process_key)
      b_before = definition_rows(ctx.b)

      {foreign, foreign_queries} =
        promote_captured(ctx.a, ctx.b.tenant_id, ["PLATFORM_ADMIN"], @process_key)

      {random, random_queries} =
        promote_captured(ctx.a, Ecto.UUID.generate(), ["PLATFORM_ADMIN"], @process_key)

      for resp <- [foreign, random] do
        assert resp.status == 404
        refute resp.status in [200, 201, 403]
      end

      assert foreign.resp_body == random.resp_body
      assert content_type(foreign) == content_type(random)
      assert [ctype] = content_type(foreign)
      assert ctype =~ "application/problem+json"

      assert touching(foreign_queries, ctx.b) == [],
             "the denied request queried B: #{inspect(touching(foreign_queries, ctx.b))}"

      assert touching(random_queries, ctx.b) == []

      # no source-tenant lookup of any kind: the denied path issues the same queries whichever
      # id was named, and none of them is about the named tenant
      assert length(foreign_queries) == length(random_queries)
      assert definition_rows(ctx.b) == b_before
    end

    test "the response body names neither tenant", ctx do
      resp = promote(ctx.a, ctx.b.tenant_id, ["PLATFORM_ADMIN"])

      refute resp.resp_body =~ ctx.b.tenant_id
      refute resp.resp_body =~ ctx.b.tenant.slug
      refute resp.resp_body =~ ctx.a.tenant_id
    end
  end

  describe "(c) malformed source ids" do
    test "a non-UUID, a slug and an over-long string are the same 404 with no query against B",
         ctx do
      {reference, reference_queries} =
        promote_captured(ctx.a, ctx.b.tenant_id, ["PLATFORM_ADMIN"], @process_key)

      for {label, source} <- [
            {"not a uuid", "not-a-uuid"},
            {"B's slug", ctx.b.tenant.slug},
            {"A's slug", ctx.a.tenant.slug},
            {"over-long", String.duplicate("x", 300)},
            {"uuid with a suffix", ctx.b.tenant_id <> "x"}
          ] do
        {resp, queries} = promote_captured(ctx.a, source, ["PLATFORM_ADMIN"], @process_key)

        assert resp.status == 404, "#{label}: #{resp.status}"
        assert resp.resp_body == reference.resp_body, label
        assert content_type(resp) == content_type(reference), label
        assert touching(queries, ctx.b) == [], label
        assert length(queries) == length(reference_queries), label
      end
    end
  end

  describe "(d) the platform operator" do
    test "naming B proceeds: B's active definition is promoted into P", ctx do
      insert_active_definition!(ctx.b, @process_key)
      b_before = definition_rows(ctx.b)

      {resp, queries} = promote_captured(ctx.p, ctx.b.tenant_id, ["PLATFORM_ADMIN"], @process_key)

      assert resp.status == 201
      assert %{"status" => "active"} = Jason.decode!(resp.resp_body)

      # control: the capture sees a request that really reads B, so the zero in (b)/(c) is real
      assert touching(queries, ctx.b) != []

      assert [{_, @process_key, "1.0.0", :active}] = definition_rows(ctx.p)
      assert definition_rows(ctx.b) == b_before
    end

    test "naming its own tenant is also allowed", ctx do
      {resp, queries} = promote_captured(ctx.p, ctx.p.tenant_id, ["PLATFORM_ADMIN"])

      assert resp.status == 404
      assert touching(queries, ctx.p) != []
    end
  end

  describe "other callers" do
    test "pin unset: the would-be operator is held to the own-tenant rule", ctx do
      Fixture.unpin!()

      {resp, queries} = promote_captured(ctx.p, ctx.b.tenant_id, ["PLATFORM_ADMIN"])

      assert resp.status == 404
      assert touching(queries, ctx.b) == []

      {own, own_queries} = promote_captured(ctx.p, ctx.p.tenant_id, ["PLATFORM_ADMIN"])
      assert own.status == 404
      assert touching(own_queries, ctx.p) != []
    end

    test "other roles are denied 403 whatever source they name", ctx do
      for roles <- [["PROCESS_DESIGNER"], ["TASK_WORKER"], []],
          fixture <- [ctx.a, ctx.p],
          source <- [fixture.tenant_id, ctx.b.tenant_id] do
        assert promote(fixture, source, roles).status == 403
      end
    end
  end

  test "the route declares :PromotionsManage (tenant scope), not an unclassified key" do
    assert {"POST", "/:test_tenant_id/promote/:process_key", :PromotionsManage} in Letflow.Routers.Tenants.__authz_routes__()

    assert Letflow.Api.Authorization.permission_scope(:PromotionsManage) == :tenant
  end
end
