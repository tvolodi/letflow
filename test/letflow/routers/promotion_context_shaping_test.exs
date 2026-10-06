defmodule Letflow.Routers.PromotionContextShapingTest do
  @moduledoc """
  REQ-446 T-8 (`lib/letflow/design/req446-named-scoped-permissions.md` sections 1c / 4b / 5):
  INV-10 response shaping on `GET /promotions/:id/context`. For a caller that is not a
  platform-tenant operator, the decoded `serialised_plan` omits every key ending in `tenant_id`
  whose value is not the caller's own tenant id, at any depth, EXCEPT that the walk does not
  descend into the top-level `entries` list. An operator sees the plan unchanged. See
  `test/specs/REQ-446.md`.

  The reviews are inserted straight into the schema under test through the real
  `PromotionReviewStore.insert_review/2` (a "legacy" row: the submit handler no longer lets an
  ordinary tenant admin create one naming a foreign tenant). `async: false` (platform pin).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions.PromotionAssertionRun
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.PromotionScopeFixture, as: Scope

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  defp get(fixture, path) do
    Letflow.Routers.Promotions.call(
      Fixture.router_conn(:get, path, fixture, ["PLATFORM_ADMIN"], nil),
      Letflow.Routers.Promotions.init([])
    )
  end

  defp context(fixture, review_id), do: get(fixture, "/#{review_id}/context")

  defp entry_with_tenant_ids(tenant_id) do
    %{
      type: :graph_node,
      id: "n1-#{System.unique_integer([:positive, :monotonic])}",
      change_kind: :added,
      after: %{"id" => "n1", "node_type" => "START", "tenant_id" => tenant_id},
      before: nil,
      tenant_id: tenant_id
    }
  end

  describe "non-operator callers" do
    test "context_omits_foreign_tenant_ids_for_non_operator", ctx do
      %{review: review, plan: plan} =
        Scope.seed_review!(ctx.a, ctx.b.tenant_id, ctx.a.tenant_id, %{
          base_version: "1.0.0",
          target_definition_id: Ecto.UUID.generate()
        })

      resp = context(ctx.a, review.id)
      assert resp.status == 200

      refute resp.resp_body =~ ctx.b.tenant_id

      body = Jason.decode!(resp.resp_body)
      shaped = body["serialised_plan"]

      assert shaped["target_tenant_id"] == ctx.a.tenant_id
      assert Map.has_key?(shaped, "source_tenant_id") == false

      # everything that is not a foreign tenant id equals the stored value
      assert shaped["source_definition_id"] == plan.source_definition_id
      assert shaped["target_definition_id"] == plan.target_definition_id
      assert shaped["process_key"] == plan.process_key
      assert shaped["base_version"] == "1.0.0"
      assert shaped["entries"] == plan.entries |> Jason.encode!() |> Jason.decode!()
      assert body["requested_by"] == review.requested_by
    end

    test "context_nested_tenant_ids_walked_but_entries_not_descended", ctx do
      %{review: review} =
        Scope.seed_review!(ctx.a, ctx.a.tenant_id, ctx.a.tenant_id, %{
          meta: %{
            origin_tenant_id: ctx.b.tenant_id,
            rows: [[%{tenant_id: ctx.b.tenant_id}, %{tenant_id: ctx.a.tenant_id, k: 1}]],
            n: 3
          },
          entries: [entry_with_tenant_ids(ctx.b.tenant_id)]
        })

      body = ctx.a |> context(review.id) |> Map.fetch!(:resp_body) |> Jason.decode!()
      plan = body["serialised_plan"]

      # outside `entries`: walked at depth, own id kept, scalars untouched
      assert plan["meta"] == %{
               "rows" => [[%{}, %{"tenant_id" => ctx.a.tenant_id, "k" => 1}]],
               "n" => 3
             }

      # inside `entries`: left exactly as stored (known, accepted residual: not descended)
      [entry] = plan["entries"]
      assert entry["tenant_id"] == ctx.b.tenant_id
      assert entry["after"]["tenant_id"] == ctx.b.tenant_id

      # both ids at the top level of the plan are the caller's own and survive
      assert plan["source_tenant_id"] == ctx.a.tenant_id
      assert plan["target_tenant_id"] == ctx.a.tenant_id
    end

    test "context_other_keys_and_status_unchanged", ctx do
      %{review: review} = Scope.seed_review!(ctx.a, ctx.b.tenant_id, ctx.a.tenant_id)

      body = ctx.a |> context(review.id) |> Map.fetch!(:resp_body) |> Jason.decode!()

      assert body |> Map.keys() |> Enum.sort() ==
               Enum.sort([
                 "review_id",
                 "plan_digest",
                 "serialised_plan",
                 "status",
                 "requested_by",
                 "def_type",
                 "def_id",
                 "created_at",
                 "row_version"
               ])

      assert body["review_id"] == review.id
      assert body["plan_digest"] == review.plan_digest
      assert body["status"] == "pending_review"
      assert body["requested_by"] == review.requested_by
      assert body["def_id"] == review.def_id
      assert body["row_version"] == review.row_version

      # GET /promotions/:id is untouched by the shaping: its seven-key run map
      Repo.insert!(
        %PromotionAssertionRun{
          review_id: review.id,
          idempotency_key: "req446-#{System.unique_integer([:positive, :monotonic])}",
          plan_digest: review.plan_digest,
          status: :passed,
          assertions_total: 1,
          assertions_passed: 1,
          assertions_failed: 0,
          completed_at: DateTime.utc_now()
        },
        prefix: ctx.a.schema_name
      )

      run_resp = get(ctx.a, "/#{review.id}")
      assert run_resp.status == 200
      run = Jason.decode!(run_resp.resp_body)["assertion_run"]

      assert run |> Map.keys() |> Enum.sort() ==
               Enum.sort([
                 "run_id",
                 "status",
                 "sandbox_id",
                 "teardown_error",
                 "assertions_passed",
                 "assertions_failed",
                 "failing_assertion_ids"
               ])

      assert run["status"] == "passed"
    end
  end

  describe "operator" do
    test "context_unchanged_for_operator", ctx do
      %{review: review, plan: plan} =
        Scope.seed_review!(ctx.p, ctx.b.tenant_id, ctx.a.tenant_id, %{
          meta: %{origin_tenant_id: ctx.b.tenant_id}
        })

      resp = context(ctx.p, review.id)
      assert resp.status == 200
      assert resp.resp_body =~ ctx.b.tenant_id
      assert resp.resp_body =~ ctx.a.tenant_id

      body = Jason.decode!(resp.resp_body)

      # equal to the unshaped (stored) plan
      assert body["serialised_plan"] == plan |> Jason.encode!() |> Jason.decode!()
    end
  end
end
