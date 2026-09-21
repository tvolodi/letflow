defmodule Letflow.Routers.PromotionsTest do
  @moduledoc """
  Tests for `Letflow.Routers.Promotions`'s R11 route, `GET /promotions/platform-events`
  (ISS-0733 GAP B, `lib/letflow/design/iss0733-promotion-audit-and-platform-events-read.md`
  §2). Brand-new code (did not exist pre-fix at all) -- per
  `docs/agents/workflows/WF-03_issue_resolving.md`'s "non-existence" section, a
  fail-first run against `main` would only prove `404`/route-not-found, which proves
  nothing about correctness, so coverage here is corroborated by mutation testing
  (see the WF-03 handoff's `result.summary` for the mutant runs/counts) rather than by
  a fail-then-pass proof against `main`.

  Dispatch strategy mirrors `req077_promotion_pipeline_test.exs` exactly: dispatches
  directly against `Letflow.Routers.Promotions.call/2` with `conn.assigns.auth_context`
  set by hand. `Letflow.Plugs.Authorize` is still a real, live plug in this router's
  pipeline (mounted by `use Letflow.Api.AuthorizedRouter`) and runs for every request --
  it resolves `conn.assigns.scoped_opts` from `conn.assigns.auth_context` itself, so no
  test below sets `scoped_opts` directly.

  Uses `Letflow.DataCase` (real Postgres, per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1) and `Letflow.TenantFixture` for
  real provisioned tenant schemas. `async: false` -- tenant provisioning/migration
  replay needs `Sandbox.mode(Letflow.Repo, :auto)`, same reasoning as every other
  tenant-provisioning test file in this codebase. Self-contained: provisions its own
  tenants, does not share fixtures with any other test file (DIRECTIVE T-4).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Api.Pagination
  alias Letflow.EventStore
  alias Letflow.EventStore.Registry
  alias Letflow.TenantFixture

  @promotions_opts Letflow.Routers.Promotions.init([])

  # ── Shared dispatch helpers (mirrors req077_promotion_pipeline_test.exs) ───────

  defp build_conn(tenant_fixture, fields) do
    roles = Keyword.get(fields, :roles, ["PLATFORM_ADMIN"])
    query_string = Keyword.get(fields, :query_string, "")

    path =
      if query_string == "", do: "/platform-events", else: "/platform-events?" <> query_string

    tenant_id = if tenant_fixture, do: tenant_fixture.tenant_id, else: Ecto.UUID.generate()

    conn(:get, path)
    |> assign(:auth_context, %{
      user_id: Keyword.get(fields, :user_id, Ecto.UUID.generate()),
      tenant_id: tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "iss0733-gapb-test-trace-id")
  end

  defp get_platform_events(tenant, fields \\ []) do
    build_conn(tenant, fields)
    |> Letflow.Routers.Promotions.call(@promotions_opts)
  end

  defp provisioned_tenant(slug_prefix) do
    TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "ISS-0733 GAP B #{slug_prefix} tenant"
    )
  end

  defp unique_type_name(prefix \\ "ISS0733_EVT") do
    prefix <> "_" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp register_event_type!(tenant_id) do
    name = unique_type_name()

    assert {:ok, _event_type} =
             Registry.register_type(
               %{
                 "name" => name,
                 "schema_version" => 1,
                 "json_schema" => %{"type" => "object"},
                 "description" => "ISS-0733 GAP B test fixture"
               },
               tenant_id
             )

    name
  end

  defp seed_platform_event!(schema_name, event_type, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          instance_id: EventStore.platform_instance_id(),
          event_type: event_type,
          payload: Jason.encode!(%{}),
          actor_id: Ecto.UUID.generate(),
          idempotency_key:
            "iss0733-gapb-" <> to_string(System.unique_integer([:positive, :monotonic]))
        },
        overrides
      )

    assert {:ok, %{event: event}} =
             EventStore.append_platform_event(attrs, prefix: schema_name)

    event
  end

  # ---------------------------------------------------------------------------
  # authz -- :Unknown gate (design §2.4, router moduledoc's own "The :Unknown
  # authorization decision"): PLATFORM_ADMIN only, Deny403 for everyone else,
  # including a caller with no roles at all.
  # ---------------------------------------------------------------------------

  describe "authz -- PLATFORM_ADMIN only (design §2.4)" do
    test "PLATFORM_ADMIN gets 200" do
      tenant = provisioned_tenant("req11-authz-allow")
      resp = get_platform_events(tenant, roles: ["PLATFORM_ADMIN"])
      assert resp.status == 200
    end

    test "a non-PLATFORM_ADMIN role (e.g. TASK_WORKER) gets 403, no event data leaks" do
      tenant = provisioned_tenant("req11-authz-deny")
      type_name = register_event_type!(tenant.tenant_id)
      event = seed_platform_event!(tenant.schema_name, type_name)

      resp = get_platform_events(tenant, roles: ["TASK_WORKER"])

      assert resp.status == 403
      body = Jason.decode!(resp.resp_body)
      assert body["status"] == 403
      refute Map.has_key?(body, "items")
      refute resp.resp_body =~ event.event_id
    end

    test "a caller with no roles at all gets 403" do
      tenant = provisioned_tenant("req11-authz-noroles")
      resp = get_platform_events(tenant, roles: [])
      assert resp.status == 403
    end
  end

  # ---------------------------------------------------------------------------
  # tenant scoping -- design §2.4: conn.assigns.scoped_opts's :prefix, derived
  # solely from the caller's own auth_context.tenant_id (mirrors GET /audit's
  # INV-1 boundary). A caller scoped to tenant A never sees tenant B's own
  # platform-sentinel event stream.
  # ---------------------------------------------------------------------------

  describe "tenant scoping (design §2.4)" do
    test "a caller scoped to tenant A does not see tenant B's platform events" do
      tenant_a = provisioned_tenant("req11-scope-a")
      tenant_b = provisioned_tenant("req11-scope-b")

      type_a = register_event_type!(tenant_a.tenant_id)
      type_b = register_event_type!(tenant_b.tenant_id)

      event_a = seed_platform_event!(tenant_a.schema_name, type_a)
      event_b = seed_platform_event!(tenant_b.schema_name, type_b)

      resp = get_platform_events(tenant_a)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      event_ids = Enum.map(body["items"], & &1["event_id"])

      assert event_a.event_id in event_ids
      refute event_b.event_id in event_ids
    end
  end

  # ---------------------------------------------------------------------------
  # response shape (design §2.6) -- hand-built allowlist, exactly the 6 item
  # keys and the 2 envelope keys named in the design.
  # ---------------------------------------------------------------------------

  describe "response shape (design §2.6)" do
    test "envelope has exactly items/next_cursor; item has exactly the 6 named keys" do
      tenant = provisioned_tenant("req11-shape")
      type_name = register_event_type!(tenant.tenant_id)
      actor_id = Ecto.UUID.generate()
      event = seed_platform_event!(tenant.schema_name, type_name, %{actor_id: actor_id})

      resp = get_platform_events(tenant)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      assert Map.keys(body) |> Enum.sort() == Enum.sort(["items", "next_cursor"])
      refute Map.has_key?(body, "count")
      assert [item] = body["items"]

      assert Map.keys(item) |> Enum.sort() ==
               Enum.sort([
                 "event_id",
                 "event_type",
                 "actor_id",
                 "timestamp",
                 "sequence_num",
                 "payload"
               ])

      assert item["event_id"] == event.event_id
      assert item["event_type"] == type_name
      assert item["actor_id"] == actor_id
      assert item["sequence_num"] == 1
      assert item["payload"] == %{}
      assert is_binary(item["timestamp"])
    end
  end

  # ---------------------------------------------------------------------------
  # event_type filter (design §2.5/§2.6) -- narrows only, never widens.
  # ---------------------------------------------------------------------------

  describe "event_type filter" do
    test "filtering to one event_type returns only that type's events" do
      tenant = provisioned_tenant("req11-eventtype")
      type_a = register_event_type!(tenant.tenant_id)
      type_b = register_event_type!(tenant.tenant_id)

      event_a = seed_platform_event!(tenant.schema_name, type_a)
      _event_b = seed_platform_event!(tenant.schema_name, type_b)

      resp = get_platform_events(tenant, query_string: "event_type=#{type_a}")

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert [item] = body["items"]
      assert item["event_id"] == event_a.event_id
    end

    test "omitting event_type returns events of every type" do
      tenant = provisioned_tenant("req11-eventtype-all")
      type_a = register_event_type!(tenant.tenant_id)
      type_b = register_event_type!(tenant.tenant_id)

      seed_platform_event!(tenant.schema_name, type_a)
      seed_platform_event!(tenant.schema_name, type_b)

      resp = get_platform_events(tenant)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert length(body["items"]) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # pagination -- cursor round-trip, exact boundary, invalid cursor 400.
  # ---------------------------------------------------------------------------

  describe "pagination" do
    test "a page_size smaller than the row count returns a non-nil next_cursor; the next page continues with no overlap" do
      tenant = provisioned_tenant("req11-page-cursor")
      type_name = register_event_type!(tenant.tenant_id)

      events = for _ <- 1..3, do: seed_platform_event!(tenant.schema_name, type_name)

      resp1 = get_platform_events(tenant, query_string: "page_size=2")
      assert resp1.status == 200
      body1 = Jason.decode!(resp1.resp_body)
      assert length(body1["items"]) == 2
      assert is_binary(body1["next_cursor"])

      resp2 =
        get_platform_events(tenant,
          query_string: "page_size=2&cursor=#{URI.encode_www_form(body1["next_cursor"])}"
        )

      assert resp2.status == 200
      body2 = Jason.decode!(resp2.resp_body)
      assert length(body2["items"]) == 1
      assert body2["next_cursor"] == nil

      page1_ids = Enum.map(body1["items"], & &1["event_id"])
      page2_ids = Enum.map(body2["items"], & &1["event_id"])
      assert MapSet.disjoint?(MapSet.new(page1_ids), MapSet.new(page2_ids))
      assert Enum.sort(page1_ids ++ page2_ids) == Enum.sort(Enum.map(events, & &1.event_id))
    end

    test "exactly page_size rows yields next_cursor: nil, not a false has_more" do
      tenant = provisioned_tenant("req11-page-boundary")
      type_name = register_event_type!(tenant.tenant_id)

      for _ <- 1..2, do: seed_platform_event!(tenant.schema_name, type_name)

      resp = get_platform_events(tenant, query_string: "page_size=2")

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert length(body["items"]) == 2
      assert body["next_cursor"] == nil
    end

    test "an invalid (garbage) cursor is rejected with 400" do
      tenant = provisioned_tenant("req11-page-badcursor")
      resp = get_platform_events(tenant, query_string: "cursor=not-a-valid-cursor")
      assert resp.status == 400
    end

    test "a cursor minted with a different endpoint's prefix (e.g. audit's \"A:\") is rejected with 400" do
      tenant = provisioned_tenant("req11-page-wrongendpoint")

      wrong_endpoint_cursor =
        Pagination.build_raw_cursor("A:", System.system_time(:microsecond), "some-key")
        |> Pagination.encode_cursor()

      resp =
        get_platform_events(tenant,
          query_string: "cursor=#{URI.encode_www_form(wrong_endpoint_cursor)}"
        )

      assert resp.status == 400
    end

    test "an empty platform-events stream returns items: [], next_cursor: nil" do
      tenant = provisioned_tenant("req11-page-empty")
      resp = get_platform_events(tenant)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["items"] == []
      assert body["next_cursor"] == nil
    end
  end
end
