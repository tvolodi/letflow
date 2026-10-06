defmodule Letflow.Routers.PromotionPlatformEventsTwoTenantTest do
  @moduledoc """
  ISS-0999 T-10 (`lib/letflow/design/iss0999-platform-events-allowlist.md` section 6 file 4): the
  operator promotes tenant B's definition into tenant A through the real
  `Letflow.Definitions.Promotion.promote_definition/3` (review in the platform tenant P's schema),
  so the `DEFINITION_PROMOTED` event lands in A's schema carrying the operator's actor id, the
  operator's review id and B's row ids. A's admin reads `GET /promotions/platform-events`: no
  identifier of B or of the operator may appear anywhere in the raw body. `async: false`
  (VM-global platform pin; restored by the fixture's `on_exit` and explicitly at the end).
  See `test/specs/ISS-0999.md`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions.Promotion
  alias Letflow.EventStore.PlatformEvents
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.PromotionScopeFixture, as: Scope

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)

    key = Scope.unique_key("t10")
    b_def = Scope.insert_active_definition!(tenants.b, key, "1.0.0")

    %{review: review} =
      Scope.seed_review!(tenants.p, tenants.b.tenant_id, tenants.a.tenant_id, %{
        process_key: key,
        source_definition_id: b_def.id
      })

    operator_id = Ecto.UUID.generate()

    assert {:ok, result} =
             Promotion.promote_definition(operator_id, review,
               permission_checker: fn _actor, _source_tenant -> true end,
               tenant_classifier: fn _tenant_id -> :test end,
               event_appender: &PlatformEvents.append_definition_promoted/2
             )

    {:ok,
     Map.merge(tenants, %{
       tenants: tenants,
       key: key,
       b_def: b_def,
       review: review,
       operator_id: operator_id,
       result: result
     })}
  end

  defp get_events(fixture, roles) do
    Letflow.Routers.Promotions.call(
      Fixture.router_conn(:get, "/platform-events", fixture, roles, nil),
      Letflow.Routers.Promotions.init([])
    )
  end

  defp promoted_item(resp) do
    assert resp.status == 200, "answered #{resp.status}: #{resp.resp_body}"
    items = Jason.decode!(resp.resp_body)["items"]
    Enum.find(items, &(&1["event_type"] == "DEFINITION_PROMOTED"))
  end

  defp refute_ids(body, ids) do
    for id <- ids do
      refute body =~ id, "body leaked #{id}"
      refute body =~ String.upcase(id), "body leaked #{String.upcase(id)}"
    end
  end

  test "non_operator_reader_sees_no_identifier_of_b_or_the_operator", ctx do
    leaked = [
      ctx.b.tenant_id,
      ctx.p.tenant_id,
      ctx.operator_id,
      ctx.review.id,
      ctx.review.requested_by,
      ctx.b_def.id,
      ctx.b.tenant.slug
    ]

    # TENANT_ADMIN held in A while the pin is P: a non-operator tenant administrator
    # (REQ-447 PR 2: a PLATFORM_ADMIN of A holds nothing, asserted 403 after the loop)
    for roles <- [["TENANT_ADMIN"]] do
      resp = get_events(ctx.a, roles)
      item = promoted_item(resp)
      assert item, "no DEFINITION_PROMOTED item for #{inspect(roles)}"

      refute_ids(resp.resp_body, leaked)
      refute Map.has_key?(item, "actor_id")

      assert item["payload"] |> Map.keys() |> Enum.sort() ==
               ["process_key", "target_definition_id", "target_tenant_id"]

      assert item["payload"]["target_tenant_id"] == ctx.a.tenant_id
      assert item["payload"]["target_definition_id"] == ctx.result.target_definition_id
      assert item["payload"]["process_key"] == ctx.key
    end

    legacy = get_events(ctx.a, ["PLATFORM_ADMIN"])
    assert legacy.status == 403, "legacy A PLATFORM_ADMIN answered #{legacy.status}"
    refute_ids(legacy.resp_body, leaked)
  end

  test "b_as_reader_sees_nothing_of_a_or_p", ctx do
    resp = get_events(ctx.b, ["TENANT_ADMIN"])
    assert resp.status == 200, resp.resp_body

    items = Jason.decode!(resp.resp_body)["items"]
    assert Enum.all?(items, &(&1["event_type"] != "DEFINITION_PROMOTED"))

    refute_ids(resp.resp_body, [
      ctx.a.tenant_id,
      ctx.p.tenant_id,
      ctx.operator_id,
      ctx.review.id,
      ctx.result.target_definition_id
    ])
  end

  test "operator_sees_the_full_payload_and_actor", ctx do
    # An operator's read uses the operator's OWN schema; making A the platform tenant for the
    # read is the only way to obtain the operator view of A's schema.
    Fixture.pin!(ctx.a.tenant_id)
    resp = get_events(ctx.a, ["PLATFORM_ADMIN"])
    Fixture.pin!(ctx.p.tenant_id)

    item = promoted_item(resp)
    assert item["actor_id"] == ctx.operator_id

    assert item["payload"] == %{
             "review_id" => ctx.review.id,
             "source_tenant_id" => ctx.b.tenant_id,
             "target_tenant_id" => ctx.a.tenant_id,
             "source_definition_id" => ctx.b_def.id,
             "target_definition_id" => ctx.result.target_definition_id,
             "process_key" => ctx.key
           }
  end
end
