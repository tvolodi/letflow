defmodule Letflow.Routers.PromotionApproveRejectStoredIdsTest do
  @moduledoc """
  ISS-1026 (Q-1008 / GH #2305): `POST /promotions/:id/approve` and `POST /promotions/:id/reject`
  re-check the review's STORED `source_tenant_id` / `target_tenant_id` against the caller before
  any state change, exactly as apply and run-assertions already do. A non-operator holder of
  `:PromotionsManage` (here `TENANT_ADMIN` of tenant A, the platform pin being on P) who names a
  review whose stored plan has a foreign side gets the SAME 404 as for a nonexistent review, the
  row is left untouched, and the self-approval and digest gates never run for it. The operator
  (PLATFORM_ADMIN of the pinned P) is unchanged. REQ-447 PR 2: an ordinary tenant's
  administrator is `TENANT_ADMIN` (its `PLATFORM_ADMIN` would hold nothing).
  See `test/specs/ISS-1026.md`.

  Reviews are seeded through the real `PromotionReviewStore.insert_review/2`
  (`Scope.seed_review!/4`); legacy shapes use the `overwrite_plan!/3` raw-JSON recipe. Requests are
  built with a FIXED caller user id (`post/5`) because `Fixture.router_conn/5` mints a fresh user
  id per call, which could never reproduce the requester == caller self-approval case.
  `async: false` (VM-global platform pin, restored by the fixture's `on_exit`).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Plug.Conn, only: [assign: 3]

  alias Letflow.Definitions.PromotionReview
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.PromotionScopeFixture, as: Scope

  @wrong_digest String.duplicate("0", 64)

  setup do
    # a = the non-operator caller's tenant, b = a foreign tenant, p = the pinned platform tenant
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, Map.put(tenants, :caller, Ecto.UUID.generate())}
  end

  # --- helpers -----------------------------------------------------------------------------

  # The platform tenant's own administrator is PLATFORM_ADMIN (the operator); every other tenant's
  # (and the would-be platform tenant once the pin is cleared) is TENANT_ADMIN.
  defp admin_roles(fixture) do
    if Letflow.PlatformTenant.platform_tenant?(fixture.tenant_id),
      do: ["PLATFORM_ADMIN"],
      else: ["TENANT_ADMIN"]
  end

  defp post(fixture, review_id, action, body, user_id) do
    roles = admin_roles(fixture)
    conn = Fixture.router_conn(:post, "/#{review_id}/#{action}", fixture, roles, body)
    ac = %{conn.assigns.auth_context | user_id: user_id}

    Letflow.Routers.Promotions.call(
      assign(conn, :auth_context, ac),
      Letflow.Routers.Promotions.init([])
    )
  end

  defp approve(fixture, review_id, digest, user_id),
    do: post(fixture, review_id, "approve", %{"plan_digest" => digest}, user_id)

  defp reject(fixture, review_id, user_id), do: post(fixture, review_id, "reject", %{}, user_id)

  defp row!(fixture, review_id),
    do: Repo.get!(PromotionReview, review_id, prefix: fixture.schema_name)

  defp overwrite_plan!(fixture, review_id, json_text) do
    query = from(r in PromotionReview, where: r.id == ^review_id)

    assert {1, _} =
             Repo.update_all(query, [set: [serialised_plan: json_text]],
               prefix: fixture.schema_name
             )

    :ok
  end

  defp set_requester!(fixture, review_id, user_id) do
    query = from(r in PromotionReview, where: r.id == ^review_id)

    assert {1, _} =
             Repo.update_all(query, [set: [requested_by: user_id]], prefix: fixture.schema_name)

    :ok
  end

  # The bytes the caller sees for a nonexistent review: the baseline every foreign-named review
  # must reproduce.
  defp baseline(ctx, action) do
    id = Ecto.UUID.generate()

    resp =
      case action do
        :approve -> approve(ctx.a, id, @wrong_digest, ctx.caller)
        :reject -> reject(ctx.a, id, ctx.caller)
      end

    assert resp.status == 404
    Scope.observable(resp)
  end

  # Approve and reject `review` as the non-operator caller with `digest`; both answer the
  # nonexistent-review baseline and neither touches the row.
  defp assert_denied_and_untouched!(ctx, fixture, review, digest, label) do
    before = row!(fixture, review.id)

    approved = approve(fixture, review.id, digest, ctx.caller)
    assert Scope.observable(approved) == baseline(ctx, :approve), "approve: #{label}"

    rejected = reject(fixture, review.id, ctx.caller)
    assert Scope.observable(rejected) == baseline(ctx, :reject), "reject: #{label}"

    assert row!(fixture, review.id) == before, "row changed: #{label}"
    assert before.status == :pending_review, label
    :ok
  end

  # --- the AC: foreign-named reviews in the caller's OWN schema ----------------------------

  describe "non-operator PromotionsManage holder, foreign-named stored plan" do
    test "approve_and_reject_answer_the_nonexistent_404_and_leave_the_row_unchanged", ctx do
      a = ctx.a.tenant_id
      b = ctx.b.tenant_id
      c = ctx.p.tenant_id

      # (a) one foreign side (B source, A target) and the mirror (A, B); (b) both sides foreign
      for {source, target, label} <- [
            {b, a, "foreign source, own target"},
            {a, b, "own source, foreign target"},
            {b, c, "both foreign"}
          ] do
        %{review: review, digest: digest} = Scope.seed_review!(ctx.a, source, target)
        assert_denied_and_untouched!(ctx, ctx.a, review, digest, label)
      end

      # (c) the nonexistent id is the baseline itself; approve and reject agree byte for byte
      assert baseline(ctx, :approve) == baseline(ctx, :reject)
    end

    test "the_404_is_byte_identical_across_foreign_shapes_and_actions", ctx do
      a = ctx.a.tenant_id
      b = ctx.b.tenant_id
      c = ctx.p.tenant_id

      %{review: r1, digest: d1} = Scope.seed_review!(ctx.a, b, a)
      %{review: r2, digest: d2} = Scope.seed_review!(ctx.a, b, c)
      none = Ecto.UUID.generate()

      observed =
        [
          approve(ctx.a, r1.id, d1, ctx.caller),
          approve(ctx.a, r2.id, d2, ctx.caller),
          approve(ctx.a, none, d1, ctx.caller),
          reject(ctx.a, r1.id, ctx.caller),
          reject(ctx.a, r2.id, ctx.caller),
          reject(ctx.a, none, ctx.caller)
        ]
        |> Enum.map(&Scope.observable/1)

      assert [{404, body, headers}] = Enum.uniq(observed)
      assert {"content-type", ct} = List.keyfind(headers, "content-type", 0)
      assert ct =~ "json"
      refute body =~ "pending_review"
    end

    test "the_status_cannot_be_learned_from_a_foreign_named_review", ctx do
      %{review: review, digest: digest} =
        Scope.seed_review!(ctx.a, ctx.b.tenant_id, ctx.a.tenant_id)

      # an already-decided foreign-named review answers the same 404 too (an own one would 422)
      query = from(r in PromotionReview, where: r.id == ^review.id)

      assert {1, _} =
               Repo.update_all(query, [set: [status: :rejected]], prefix: ctx.a.schema_name)

      before = row!(ctx.a, review.id)

      assert Scope.observable(approve(ctx.a, review.id, digest, ctx.caller)) ==
               baseline(ctx, :approve)

      assert Scope.observable(reject(ctx.a, review.id, ctx.caller)) == baseline(ctx, :reject)
      assert row!(ctx.a, review.id) == before
    end

    test "the_digest_and_self_approval_gates_never_run_for_a_foreign_named_review", ctx do
      a = ctx.a.tenant_id
      b = ctx.b.tenant_id

      # WRONG digest: an own review answers 409; the foreign-named one must answer the 404
      %{review: own_review} = Scope.seed_review!(ctx.a, a, a)
      own_wrong = approve(ctx.a, own_review.id, @wrong_digest, ctx.caller)
      assert own_wrong.status == 409

      %{review: foreign} = Scope.seed_review!(ctx.a, b, a)
      before = row!(ctx.a, foreign.id)
      wrong = approve(ctx.a, foreign.id, @wrong_digest, ctx.caller)
      assert wrong.status == 404
      assert Scope.observable(wrong) == baseline(ctx, :approve)
      assert row!(ctx.a, foreign.id) == before

      # requester == caller: an own review answers 403; the foreign-named one must answer 404
      %{review: own_self, digest: own_self_digest} = Scope.seed_review!(ctx.a, a, a)
      :ok = set_requester!(ctx.a, own_self.id, ctx.caller)
      assert approve(ctx.a, own_self.id, own_self_digest, ctx.caller).status == 403

      %{review: foreign_self, digest: foreign_self_digest} = Scope.seed_review!(ctx.a, b, a)
      :ok = set_requester!(ctx.a, foreign_self.id, ctx.caller)
      before_self = row!(ctx.a, foreign_self.id)
      self_resp = approve(ctx.a, foreign_self.id, foreign_self_digest, ctx.caller)
      assert self_resp.status == 404
      assert Scope.observable(self_resp) == baseline(ctx, :approve)
      assert row!(ctx.a, foreign_self.id) == before_self
    end
  end

  # --- controls: the check must not be vacuous ---------------------------------------------

  describe "controls" do
    test "an_own_tenant_review_is_approved_and_rejected_normally_by_a_distinct_user", ctx do
      a = ctx.a.tenant_id

      %{review: to_approve, digest: digest} = Scope.seed_review!(ctx.a, a, a)
      approved = approve(ctx.a, to_approve.id, digest, ctx.caller)
      assert approved.status == 200

      assert Jason.decode!(approved.resp_body) == %{
               "review_id" => to_approve.id,
               "status" => "approved"
             }

      assert row!(ctx.a, to_approve.id).status == :approved

      %{review: to_reject} = Scope.seed_review!(ctx.a, a, a)
      rejected = reject(ctx.a, to_reject.id, ctx.caller)
      assert rejected.status == 200

      assert Jason.decode!(rejected.resp_body) == %{
               "review_id" => to_reject.id,
               "status" => "rejected"
             }

      assert row!(ctx.a, to_reject.id).status == :rejected
    end

    test "the_operator_approves_and_rejects_a_foreign_named_review_in_its_own_schema", ctx do
      a = ctx.a.tenant_id
      b = ctx.b.tenant_id

      # pin is on P and the caller is P's PLATFORM_ADMIN: the operator; the review names B and A
      %{review: to_approve, digest: digest} = Scope.seed_review!(ctx.p, b, a)
      approved = approve(ctx.p, to_approve.id, digest, ctx.caller)
      assert approved.status == 200
      assert Jason.decode!(approved.resp_body)["status"] == "approved"
      assert row!(ctx.p, to_approve.id).status == :approved

      # the other foreign shape: neither side is P
      %{review: to_reject} = Scope.seed_review!(ctx.p, b, a)
      rejected = reject(ctx.p, to_reject.id, ctx.caller)
      assert rejected.status == 200
      assert Jason.decode!(rejected.resp_body)["status"] == "rejected"
      assert row!(ctx.p, to_reject.id).status == :rejected
    end

    test "with_the_pin_cleared_the_same_p_caller_is_a_non_operator_and_gets_the_404", ctx do
      %{review: review, digest: digest} =
        Scope.seed_review!(ctx.p, ctx.b.tenant_id, ctx.a.tenant_id)

      Fixture.unpin!()
      before = row!(ctx.p, review.id)

      assert Scope.observable(approve(ctx.p, review.id, digest, ctx.caller)) ==
               baseline(ctx, :approve)

      assert Scope.observable(reject(ctx.p, review.id, ctx.caller)) == baseline(ctx, :reject)
      assert row!(ctx.p, review.id) == before
    end
  end

  # --- legacy and malformed stored plans ---------------------------------------------------

  describe "legacy plans" do
    test "malformed_or_incomplete_stored_plans_fail_closed_for_a_non_operator", ctx do
      a = ctx.a.tenant_id
      b = ctx.b.tenant_id
      own = Jason.encode!(a)

      cases = [
        {"non-map: number", "7"},
        {"non-map: list", ~s(["#{a}"])},
        {"non-map: null", "null"},
        {"non-map: string", ~s("#{a}")},
        {"not JSON", "not json at all"},
        {"both ids missing", ~s({"process_key":"p"})},
        {"source missing", ~s({"target_tenant_id":#{own}})},
        {"target missing", ~s({"source_tenant_id":#{own}})},
        {"odd keys only", ~s({"tenantId":#{own}})},
        {"source number", ~s({"source_tenant_id":7,"target_tenant_id":#{own}})},
        {"target list", ~s({"source_tenant_id":#{own},"target_tenant_id":["#{a}"]})},
        {"source object", ~s({"source_tenant_id":{"id":"#{a}"},"target_tenant_id":#{own}})},
        {"source null", ~s({"source_tenant_id":null,"target_tenant_id":#{own}})},
        {"target true", ~s({"source_tenant_id":#{own},"target_tenant_id":true})},
        {"target empty", ~s({"source_tenant_id":#{own},"target_tenant_id":""})},
        {"foreign source", ~s({"source_tenant_id":"#{b}","target_tenant_id":#{own}})}
      ]

      for {label, json} <- cases do
        %{review: review, digest: digest} = Scope.seed_review!(ctx.a, a, a)
        :ok = overwrite_plan!(ctx.a, review.id, json)
        assert_denied_and_untouched!(ctx, ctx.a, review, digest, label)
      end

      # positive control with the same recipe: both ids own, raw JSON, the stored digest column is
      # untouched by the overwrite -> approved and rejected normally
      %{review: ok_approve, digest: digest} = Scope.seed_review!(ctx.a, a, a)

      :ok =
        overwrite_plan!(
          ctx.a,
          ok_approve.id,
          ~s({"source_tenant_id":#{own},"target_tenant_id":#{own}})
        )

      assert approve(ctx.a, ok_approve.id, digest, ctx.caller).status == 200

      %{review: ok_reject} = Scope.seed_review!(ctx.a, a, a)

      :ok =
        overwrite_plan!(
          ctx.a,
          ok_reject.id,
          ~s({"source_tenant_id":#{own},"target_tenant_id":#{own}})
        )

      assert reject(ctx.a, ok_reject.id, ctx.caller).status == 200
    end
  end
end
