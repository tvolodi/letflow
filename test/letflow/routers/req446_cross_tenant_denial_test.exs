defmodule Letflow.Routers.Req446CrossTenantDenialTest do
  @moduledoc """
  REQ-446 T-1 / AC8 / AC9 (`lib/letflow/design/req446-named-scoped-permissions.md` section 5):
  ONE table-driven test naming each of the twelve formerly-`:Unknown` routes, as a
  `PLATFORM_ADMIN` of the NON-platform tenant A (pin on the platform tenant P) carrying
  identifiers that belong to tenant B. See `test/specs/REQ-446.md`.

  Per route (rows 1-10, the identifier rows): the request carrying B's identifier and the same
  request carrying an identifier that exists nowhere both answer 404 with byte-identical
  observable bytes (status, body, every header but `x-request-id`); neither body names B, B's
  slug, B's review id or B's process keys; no query of the A calls touches B's schema; a
  before/after snapshot of A, B and P (definitions, reviews with row version, assertion-run
  count) is identical. The CONTROL, run only after the snapshot comparison, is the same request by
  a `PLATFORM_ADMIN` of B with B's own identifier and must answer the stated status, which proves
  the identifier and body are valid and A's 404 is the authorization denial and not a malformed
  request.

  Rows 11 and 12 (the two list reads) use the baseline form: A's response before and after B's
  rows are written is byte-identical and names nothing of B, and the control shows B's own admin
  does see B's row.

  `@callers` has one line today (A's `PLATFORM_ADMIN`); REQ-447 adds a `TENANT_ADMIN` of A as one
  more line. `async: false` (VM-global platform pin and query telemetry).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Routers.Definitions, as: DefinitionsRouter
  alias Letflow.Routers.Promotions, as: PromotionsRouter
  alias Letflow.Routers.Tenants, as: TenantsRouter
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.PromotionScopeFixture, as: Scope

  # Roles of the caller that is an admin of tenant A. The pin stays on the platform tenant.
  @callers [["PLATFORM_ADMIN"]]

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  defp call(router, method, path, fixture, roles, body) do
    router.call(
      Fixture.router_conn(method, path, fixture, roles, body),
      router.init([])
    )
  end

  # Fresh rows per entry (controls change state): `K` active 1.0.0 in B only; `K2` active 2.0.0
  # with 1.0.0 in its history, in B only; `R_B`, a pending review in B's schema naming B on both
  # sides, requested by a random user.
  defp seed_b!(ctx) do
    key = Scope.unique_key("req446-k")
    Scope.insert_active_definition!(ctx.b, key, "1.0.0")
    key2 = Scope.unique_key("req446-k2")
    Scope.two_version_history!(ctx.b, key2)

    %{review: review, digest: digest} =
      Scope.seed_review!(ctx.b, ctx.b.tenant_id, ctx.b.tenant_id)

    %{k: key, k2: key2, review_id: review.id, digest: digest}
  end

  # The twelve rows 1-10 + the two list baselines are rows 11-12 (handled separately).
  # `path`/`body` are functions of the one identifier that differs between the foreign and the
  # nowhere request; `control` is B's own admin with B's own identifier.
  defp identifier_rows(ctx, s) do
    a = ctx.a.tenant_id
    b = ctx.b.tenant_id
    nowhere = fn -> Ecto.UUID.generate() end
    digest_body = %{"plan_digest" => s.digest}

    [
      %{
        name: "POST /promotions",
        router: PromotionsRouter,
        method: :post,
        path: fn _id -> "/" end,
        body: fn id ->
          %{
            "source_tenant_id" => id,
            "target_tenant_id" => a,
            "process_key" => s.k,
            "base_version" => "1.0.0"
          }
        end,
        foreign: b,
        nowhere: nowhere.(),
        control: %{
          path: "/",
          body: %{
            "source_tenant_id" => b,
            "target_tenant_id" => b,
            "process_key" => s.k,
            "base_version" => "1.0.0"
          },
          status: 422,
          check: &assert(&1 =~ "Empty Promotion Plan")
        }
      },
      %{
        name: "POST /promotions/plan",
        router: PromotionsRouter,
        method: :post,
        path: fn _id -> "/plan" end,
        body: fn id ->
          %{"source_tenant_id" => a, "target_tenant_id" => id, "process_key" => s.k}
        end,
        foreign: b,
        nowhere: nowhere.(),
        control: %{
          path: "/plan",
          body: %{"source_tenant_id" => b, "target_tenant_id" => b, "process_key" => s.k},
          status: 422,
          check: &assert(&1 =~ "Empty Promotion Plan")
        }
      },
      %{
        name: "GET /promotions/:id",
        router: PromotionsRouter,
        method: :get,
        path: fn id -> "/#{id}" end,
        body: fn _id -> nil end,
        foreign: s.review_id,
        nowhere: nowhere.(),
        control: %{
          path: "/#{s.review_id}",
          body: nil,
          status: 200,
          check: &assert(Jason.decode!(&1) == %{"assertion_run" => nil})
        }
      },
      %{
        name: "GET /promotions/:id/context",
        router: PromotionsRouter,
        method: :get,
        path: fn id -> "/#{id}/context" end,
        body: fn _id -> nil end,
        foreign: s.review_id,
        nowhere: nowhere.(),
        control: %{
          path: "/#{s.review_id}/context",
          body: nil,
          status: 200,
          check: &assert(Jason.decode!(&1)["review_id"] == s.review_id)
        }
      },
      %{
        name: "POST /promotions/:id/approve",
        router: PromotionsRouter,
        method: :post,
        path: fn id -> "/#{id}/approve" end,
        body: fn _id -> digest_body end,
        foreign: s.review_id,
        nowhere: nowhere.(),
        control: %{
          path: "/#{s.review_id}/approve",
          body: digest_body,
          status: 200,
          check:
            &assert(Jason.decode!(&1) == %{"review_id" => s.review_id, "status" => "approved"})
        }
      },
      %{
        name: "POST /promotions/:id/reject",
        router: PromotionsRouter,
        method: :post,
        path: fn id -> "/#{id}/reject" end,
        body: fn _id -> %{} end,
        foreign: s.review_id,
        nowhere: nowhere.(),
        control: %{
          path: "/#{s.review_id}/reject",
          body: %{},
          status: 200,
          check:
            &assert(Jason.decode!(&1) == %{"review_id" => s.review_id, "status" => "rejected"})
        }
      },
      %{
        name: "POST /promotions/:id/apply",
        router: PromotionsRouter,
        method: :post,
        path: fn id -> "/#{id}/apply" end,
        body: fn _id -> digest_body end,
        foreign: s.review_id,
        nowhere: nowhere.(),
        control: %{
          path: "/#{s.review_id}/apply",
          body: digest_body,
          status: 409,
          check: &assert(&1 =~ "review is not in a state that permits this transition")
        }
      },
      %{
        name: "POST /promotions/:review_id/run-assertions",
        router: PromotionsRouter,
        method: :post,
        path: fn id -> "/#{id}/run-assertions" end,
        body: fn _id -> %{"plan_digest" => s.digest, "artifact" => Scope.artifact()} end,
        foreign: s.review_id,
        nowhere: nowhere.(),
        control: %{
          path: "/#{s.review_id}/run-assertions",
          body: %{"plan_digest" => s.digest, "artifact" => Scope.artifact()},
          status: 200,
          check: fn body ->
            decoded = Jason.decode!(body)

            assert decoded |> Map.keys() |> Enum.sort() ==
                     Enum.sort([
                       "run_id",
                       "status",
                       "assertions_passed",
                       "assertions_failed",
                       "failing_assertion_ids",
                       "sandbox_id"
                     ])

            assert decoded["assertions_failed"] == 0
          end
        }
      },
      %{
        name: "POST /definitions/:process_key/rollback",
        router: DefinitionsRouter,
        method: :post,
        path: fn key -> "/#{key}/rollback" end,
        body: fn _key -> %{"target_version" => "1.0.0"} end,
        foreign: s.k2,
        nowhere: Scope.unique_key("req446-nowhere"),
        control: %{
          path: "/#{s.k2}/rollback",
          body: %{"target_version" => "1.0.0"},
          status: 200,
          check: fn body ->
            decoded = Jason.decode!(body)
            assert decoded["version"] == "1.0.0"
            assert decoded["rolled_back_from_version"] == "2.0.0"
          end
        }
      },
      %{
        name: "POST /tenants/:test_tenant_id/promote/:process_key",
        router: TenantsRouter,
        method: :post,
        path: fn id -> "/#{id}/promote/#{s.k}" end,
        body: fn _id -> nil end,
        foreign: b,
        nowhere: nowhere.(),
        control: %{
          path: "/#{b}/promote/#{s.k}",
          body: nil,
          status: 409,
          check: &assert(&1 =~ "version")
        }
      }
    ]
  end

  defp assert_names_nothing_of_b(body, ctx, s, label) do
    for {what, needle} <- [
          {"B's tenant id", ctx.b.tenant_id},
          {"B's slug", ctx.b.tenant.slug},
          {"B's review id", s.review_id},
          {"B's process key", s.k2}
        ] do
      refute body =~ needle, "#{label}: the 404 body names #{what}"
    end
  end

  test "every re-keyed route: A's admin with B's identifiers gets the nowhere 404 and B is untouched",
       ctx do
    for roles <- @callers do
      for i <- 0..9, do: identifier_row!(ctx, roles, i)
      list_reviews_row!(ctx, roles)
      list_events_row!(ctx, roles)
    end
  end

  defp identifier_row!(ctx, roles, i) do
    s = seed_b!(ctx)
    row = Enum.at(identifier_rows(ctx, s), i)
    label = "#{inspect(roles)} #{row.name}"

    before = Scope.snapshot([ctx.a, ctx.b, ctx.p])

    {{foreign, nowhere}, queries} =
      Fixture.capture_repo_queries(fn ->
        {
          call(
            row.router,
            row.method,
            row.path.(row.foreign),
            ctx.a,
            roles,
            row.body.(row.foreign)
          ),
          call(
            row.router,
            row.method,
            row.path.(row.nowhere),
            ctx.a,
            roles,
            row.body.(row.nowhere)
          )
        }
      end)

    assert foreign.status == 404,
           "#{label}: foreign answered #{foreign.status} #{foreign.resp_body}"

    assert nowhere.status == 404, "#{label}: nowhere answered #{nowhere.status}"
    assert Scope.observable(foreign) == Scope.observable(nowhere), "#{label}: bytes differ"
    assert_names_nothing_of_b(foreign.resp_body, ctx, s, label)

    assert Enum.filter(queries, &Fixture.touches_tenant?(&1, ctx.b)) == [],
           "#{label}: the denied request queried B"

    assert Scope.snapshot([ctx.a, ctx.b, ctx.p]) == before, "#{label}: a row changed"

    # CONTROL (after the snapshot comparison): B's own admin, B's own identifier.
    control = row.control

    resp =
      call(row.router, row.method, control.path, ctx.b, ["PLATFORM_ADMIN"], control.body)

    assert resp.status == control.status,
           "#{label}: control answered #{resp.status} (expected #{control.status}): #{resp.resp_body}"

    control.check.(resp.resp_body)
  end

  # Row 11, GET /promotions (baseline form).
  defp list_reviews_row!(ctx, roles) do
    own = Scope.seed_review!(ctx.a, ctx.a.tenant_id, ctx.a.tenant_id)

    first = call(PromotionsRouter, :get, "/", ctx.a, roles, nil)
    assert first.status == 200
    assert first.resp_body =~ own.review.id

    %{review: b_review} = Scope.seed_review!(ctx.b, ctx.b.tenant_id, ctx.b.tenant_id)
    before = Scope.snapshot([ctx.a, ctx.b, ctx.p])

    second = call(PromotionsRouter, :get, "/", ctx.a, roles, nil)

    assert second.status == 200
    assert Scope.observable(second) == Scope.observable(first)
    refute second.resp_body =~ b_review.id
    refute second.resp_body =~ ctx.b.tenant_id
    assert Scope.snapshot([ctx.a, ctx.b, ctx.p]) == before

    control = call(PromotionsRouter, :get, "/", ctx.b, ["PLATFORM_ADMIN"], nil)
    assert control.status == 200
    assert control.resp_body =~ b_review.id
  end

  # Row 12, GET /promotions/platform-events (baseline form).
  defp list_events_row!(ctx, roles) do
    {_type, own_id} =
      Scope.append_fixture_event!(ctx.a, %{"tenant_id" => ctx.a.tenant_id, "note" => "a"})

    first = call(PromotionsRouter, :get, "/platform-events", ctx.a, roles, nil)
    assert first.status == 200
    assert first.resp_body =~ own_id

    {_type, b_event_id} =
      Scope.append_fixture_event!(ctx.b, %{"tenant_id" => ctx.b.tenant_id, "note" => "b"})

    before = Scope.snapshot([ctx.a, ctx.b, ctx.p])

    second = call(PromotionsRouter, :get, "/platform-events", ctx.a, roles, nil)

    assert second.status == 200
    assert Scope.observable(second) == Scope.observable(first)
    refute second.resp_body =~ b_event_id
    refute second.resp_body =~ ctx.b.tenant_id
    assert Scope.snapshot([ctx.a, ctx.b, ctx.p]) == before

    control = call(PromotionsRouter, :get, "/platform-events", ctx.b, ["PLATFORM_ADMIN"], nil)
    assert control.status == 200
    assert control.resp_body =~ b_event_id
  end
end
