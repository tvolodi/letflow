defmodule Letflow.Routers.PromotionScopeLegacyTest do
  @moduledoc """
  ISS-0993 / ISS-0994 design section 12 items 7 and 8, A1 variants (spec
  `test/specs/ISS-0993-A1.md`): the twelve routes that used to be declared without a policy key
  (rows 23-34 of design 7.2) now carry explicit TENANT-scope keys; in A1 no handler checks a
  caller-supplied tenant id yet, so the LEGACY behaviour is asserted.

  Item 7 (A1 variant):

    * every one of the twelve routes: an `PLATFORM_ADMIN` of an ordinary tenant, of the platform
      tenant, and with the pin unset reaches the handler (not 403) and trips NO shadow line (the
      keys are tenant scope: legacy and real decisions agree); every other role is denied 403;
    * legacy cross-tenant behaviour: a plan or submit naming another EXISTING tenant as source is
      not rejected for ownership (it reaches the domain logic: 422 empty plan). A2 replaces this
      with the byte-identical 404 of design section 8; the two assertions below flip there.

  Item 8 (`GET /promotions/platform-events`): events seeded in another tenant's schema are never
  returned to the caller; the caller sees only its own sentinel events (own-schema read).

  Not asserted: the legacy outcome for a never-provisioned (random) tenant id, which today
  raises inside the handler (undefined table) instead of answering; A2 turns that into the 404.

  INV-10 check, enforced from the merge of Q-960 PR A. `async: false` (VM-global pin, shared log).
  """

  use Letflow.DataCase, async: false

  alias Letflow.EventStore
  alias Letflow.EventStore.Registry
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  @unused_uuid "00000000-0000-4000-8000-000000000002"

  # {router, method, concrete local path, body, policy key}   (rows 23-34)
  @rows [
    {Letflow.Routers.Promotions, :post, "/", %{}, :PromotionsManage},
    {Letflow.Routers.Promotions, :post, "/plan", %{}, :PromotionsManage},
    {Letflow.Routers.Promotions, :get, "/platform-events", nil, :PromotionsRead},
    {Letflow.Routers.Promotions, :get, "/" <> @unused_uuid, nil, :PromotionsRead},
    {Letflow.Routers.Promotions, :get, "/" <> @unused_uuid <> "/context", nil, :PromotionsRead},
    {Letflow.Routers.Promotions, :post, "/" <> @unused_uuid <> "/approve", %{},
     :PromotionsManage},
    {Letflow.Routers.Promotions, :post, "/" <> @unused_uuid <> "/reject", %{}, :PromotionsManage},
    {Letflow.Routers.Promotions, :post, "/" <> @unused_uuid <> "/apply", %{}, :PromotionsManage},
    {Letflow.Routers.Promotions, :post, "/" <> @unused_uuid <> "/run-assertions", %{},
     :PromotionsManage},
    {Letflow.Routers.Promotions, :get, "/", nil, :PromotionsRead},
    {Letflow.Routers.Definitions, :post, "/no-such-process/rollback", %{}, :DefinitionsRollback},
    {Letflow.Routers.Tenants, :post, "/{SOURCE}/promote/no-such-process", nil, :PromotionsManage}
  ]

  defp dispatch(router, conn), do: router.call(conn, router.init([]))

  # `{SOURCE}` is replaced by an existing, provisioned tenant id (another tenant's schema must
  # exist for the legacy handler to run; a never-provisioned id raises there).
  defp request({router, method, path, body, _key}, fixture, roles, source_id) do
    path = String.replace(path, "{SOURCE}", source_id)
    dispatch(router, Fixture.router_conn(method, path, fixture, roles, body))
  end

  defp plan_body(source, target) do
    %{
      "source_tenant_id" => source,
      "target_tenant_id" => target,
      "process_key" => "no-such-process",
      "base_version" => "1"
    }
  end

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  describe "item 7 A1: rows 23-34" do
    test "there are twelve rows and each declares its expected key" do
      assert length(@rows) == 12

      for {router, method, _path, _body, key} <- @rows do
        verb = method |> Atom.to_string() |> String.upcase()
        keys = for {^verb, _pattern, k} <- router.__authz_routes__(), do: k
        assert key in keys, "#{inspect(router)} #{verb} declares none of #{inspect(key)}"
      end
    end

    test "a PLATFORM_ADMIN (ordinary tenant, platform tenant, pin unset) reaches the handler and trips no shadow line",
         ctx do
      for {label, fixture, pin?} <- [
            {"ordinary tenant", ctx.a, true},
            {"platform tenant", ctx.p, true},
            {"pin unset", ctx.p, false}
          ],
          row <- @rows do
        if pin?, do: Fixture.pin!(ctx.p.tenant_id), else: Fixture.unpin!()

        {resp, log} =
          ExUnit.CaptureLog.with_log([level: :warning], fn ->
            request(row, fixture, ["PLATFORM_ADMIN"], ctx.b.tenant_id)
          end)

        refute resp.status == 403, "#{label}: #{elem(row, 1)} #{elem(row, 2)}"
        assert Fixture.shadow_lines(log) == [], "#{label}: #{elem(row, 1)} #{elem(row, 2)}"
      end
    end

    test "every other role is denied 403 on every row", ctx do
      for row <- @rows,
          roles <- [["PROCESS_DESIGNER"], ["PROCESS_OPERATOR"], ["TASK_WORKER"], []],
          fixture <- [ctx.a, ctx.p] do
        resp = request(row, fixture, roles, ctx.b.tenant_id)
        assert resp.status == 403, "#{inspect(roles)} #{elem(row, 1)} #{elem(row, 2)}"
      end
    end

    test "legacy: a plan or submit naming another existing tenant as source is not rejected for ownership",
         ctx do
      for path <- ["/plan", "/"] do
        resp =
          dispatch(
            Letflow.Routers.Promotions,
            Fixture.router_conn(
              :post,
              path,
              ctx.a,
              ["PLATFORM_ADMIN"],
              plan_body(ctx.b.tenant_id, ctx.a.tenant_id)
            )
          )

        assert resp.status == 422
        assert Jason.decode!(resp.resp_body)["title"] == "Empty Promotion Plan"
      end
    end

    test "legacy: the promote route with another existing tenant as source reaches the domain logic (404, source definition missing)",
         ctx do
      resp =
        dispatch(
          Letflow.Routers.Tenants,
          Fixture.router_conn(
            :post,
            "/#{ctx.b.tenant_id}/promote/no-such-process",
            ctx.a,
            ["PLATFORM_ADMIN"],
            nil
          )
        )

      assert resp.status == 404
      assert Jason.decode!(resp.resp_body)["title"] == "Not Found"
    end
  end

  describe "item 8 A1: GET /promotions/platform-events" do
    defp register_event_type!(tenant_id) do
      name = "ISS0993_EVT_" <> to_string(System.unique_integer([:positive, :monotonic]))

      assert {:ok, _} =
               Registry.register_type(
                 %{
                   "name" => name,
                   "schema_version" => 1,
                   "json_schema" => %{"type" => "object"},
                   "description" => "platform scope test fixture"
                 },
                 tenant_id
               )

      name
    end

    defp seed_platform_event!(fixture) do
      attrs = %{
        instance_id: EventStore.platform_instance_id(),
        event_type: register_event_type!(fixture.tenant_id),
        payload: Jason.encode!(%{}),
        actor_id: Ecto.UUID.generate(),
        idempotency_key: "iss0993-" <> to_string(System.unique_integer([:positive, :monotonic]))
      }

      assert {:ok, %{event: event}} =
               EventStore.append_platform_event(attrs, prefix: fixture.schema_name)

      event
    end

    defp event_ids(fixture, roles) do
      resp =
        dispatch(
          Letflow.Routers.Promotions,
          Fixture.router_conn(:get, "/platform-events", fixture, roles, nil)
        )

      assert resp.status == 200
      Jason.decode!(resp.resp_body)["items"] |> Enum.map(& &1["event_id"])
    end

    test "events seeded in another tenant's schema are never returned; the caller sees its own",
         ctx do
      event_a = seed_platform_event!(ctx.a)
      event_b = seed_platform_event!(ctx.b)

      ids_a = event_ids(ctx.a, ["PLATFORM_ADMIN"])
      assert event_a.event_id in ids_a
      refute event_b.event_id in ids_a

      ids_b = event_ids(ctx.b, ["PLATFORM_ADMIN"])
      assert event_b.event_id in ids_b
      refute event_a.event_id in ids_b
    end

    test "the platform tenant's PLATFORM_ADMIN reads only the platform tenant's own schema",
         ctx do
      event_p = seed_platform_event!(ctx.p)
      event_a = seed_platform_event!(ctx.a)

      ids = event_ids(ctx.p, ["PLATFORM_ADMIN"])
      assert event_p.event_id in ids
      refute event_a.event_id in ids
    end

    test "a role without the read permission gets 403 and no event data", ctx do
      event_a = seed_platform_event!(ctx.a)

      resp =
        dispatch(
          Letflow.Routers.Promotions,
          Fixture.router_conn(:get, "/platform-events", ctx.a, ["TASK_WORKER"], nil)
        )

      assert resp.status == 403
      refute resp.resp_body =~ event_a.event_id
    end
  end
end
