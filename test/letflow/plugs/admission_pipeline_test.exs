defmodule Letflow.Plugs.AdmissionPipelineTest do
  @moduledoc """
  End-to-end HTTP-level tests for REQ-217 (admission control wired into
  `Letflow.Plugs.ApiPipeline`), dispatched through the REAL `Letflow.Router.call/2`
  chain — `Plug.Parsers` -> `Letflow.Plugs.Admission` (global) ->
  `:assign_trace_id` -> `Letflow.Plugs.AuthPipeline` -> `Letflow.Plugs.Admission`
  (tenant) -> `Letflow.Plugs.TenantStatus` -> `:match`/`:dispatch`.

  See `docs/requirements.yaml`'s REQ-217 entry for the full acceptance-criteria
  text this file maps to (cited per-`describe` block below).

  Mirrors `test/letflow/api_token_auth_pipeline_test.exs`'s established
  `Letflow.TenantFixture.provisioned_tenant!/1` + `Letflow.Identity.create_token/3`
  API-token pattern for real, DB-backed multi-tenant HTTP requests (the API-token
  branch, not the OIDC branch, is used throughout because it lets each test mint
  a token for an arbitrary REAL tenant/role, rather than being pinned to
  `Letflow.Oidc.TokenVerifierDouble`'s one fixed realm/role).

  **`async: false`** for the whole module — most tests here restart the real,
  application-supervised `Letflow.Admission` singleton with an artificially
  tiny cap via `Letflow.AdmissionTestHelpers.restart_admission!/1`, and/or
  directly exhaust a specific tenant's share against it — see that helper's own
  moduledoc for why this is safe only from an `async: false` test (ExUnit runs
  every `async: true` module to completion before any `async: false` module
  starts, and `async: false` modules run one at a time).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Admission
  alias Letflow.AdmissionTestHelpers
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.TenantFixture

  defp insert_user!(tenant, attrs \\ []) do
    default = %{
      username: "admission-user-#{Ecto.UUID.generate()}",
      display_name: "Admission Pipeline Test User",
      email: "admission-user-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    }

    %User{}
    |> Ecto.Changeset.change(Map.merge(default, Map.new(attrs)))
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp api_token_request(method, path, plaintext, tenant_slug) do
    conn(method, path)
    |> put_req_header("authorization", "Bearer " <> plaintext)
    |> put_req_header("x-tenant-slug", tenant_slug)
  end

  defp platform_admin_token!(tenant) do
    user = insert_user!(tenant)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["PLATFORM_ADMIN"], expires_at: nil},
        prefix: tenant.schema_name
      )

    {user, plaintext}
  end

  describe "AC1: global cap exhausted -> every /api/v1/* request 503, Plug.Parsers never runs" do
    test "a request that would otherwise pass auth is rejected 503 with Retry-After, before Plug.Parsers" do
      AdmissionTestHelpers.restart_admission!(pool_size: 1, reserved_headroom: 0)
      # cap == 1, consumed -- every request must be rejected by the global gate.
      {:ok, held_ref} = Admission.try_acquire(:global)
      on_exit(fn -> Admission.release(held_ref) end)

      conn =
        conn(:post, "/api/v1/identity/anything", Jason.encode!(%{}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer valid-test-token")
        |> dispatch()

      assert conn.status == 503
      assert get_resp_header(conn, "retry-after") == ["1"]
      decoded = Jason.decode!(conn.resp_body)
      assert decoded["status"] == 503
      assert String.ends_with?(decoded["type"], "/problems/service-unavailable")
    end

    test "an oversized body (over Plug.Parsers's own 2 MB limit) still returns 503, not 413" do
      AdmissionTestHelpers.restart_admission!(pool_size: 1, reserved_headroom: 0)
      {:ok, held_ref} = Admission.try_acquire(:global)
      on_exit(fn -> Admission.release(held_ref) end)

      # Comfortably over api_pipeline.ex's own `length: 2_097_152` root cap --
      # if Plug.Parsers ran at all against this body, it would raise
      # Plug.Parsers.RequestTooLargeError (413), never reach the point where
      # 503 could be produced.
      oversized_body = Jason.encode!(%{"a" => String.duplicate("x", 2_200_000)})

      conn =
        conn(:post, "/api/v1/identity/anything", oversized_body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer valid-test-token")
        |> dispatch()

      assert conn.status == 503
      refute conn.status == 413
    end
  end

  describe "AC2: per-tenant cap exhausted for one tenant does not affect a different tenant" do
    test "tenant A gets 503 while tenant B (same global cap) succeeds, both requests in this test" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req217-ac2-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req217-ac2-b")

      {_user_a, plaintext_a} = platform_admin_token!(tenant_a)
      {_user_b, plaintext_b} = platform_admin_token!(tenant_b)

      # Track tenant B first (one attempt, released immediately) so both
      # tenants are counted in the fair-share divisor before tenant A's own
      # share is computed -- mirrors test/letflow/admission_test.exs's own
      # AC2 setup precedent for the exact same reason.
      {:ok, b_probe_ref} = Admission.try_acquire({:tenant, tenant_b.schema_name})
      :ok = Admission.release(b_probe_ref)

      # Exhaust tenant A's own fair share directly against the real singleton
      # (never released -- held for the duration of this test).
      a_refs =
        Stream.repeatedly(fn -> Admission.try_acquire({:tenant, tenant_a.schema_name}) end)
        |> Enum.take_while(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, ref} -> ref end)

      assert a_refs != []
      assert {:error, :capacity} = Admission.try_acquire({:tenant, tenant_a.schema_name})

      on_exit(fn -> Enum.each(a_refs, &Admission.release/1) end)

      conn_a =
        api_token_request(:get, "/api/v1/identity/anything", plaintext_a, tenant_a.tenant.slug)
        |> dispatch()

      assert conn_a.status == 503
      assert get_resp_header(conn_a, "retry-after") == ["1"]

      conn_b =
        api_token_request(:get, "/api/v1/identity/anything", plaintext_b, tenant_b.tenant.slug)
        |> dispatch()

      # PLATFORM_ADMIN reaches Letflow.Routers.Identity's own catch-all (404),
      # per Letflow.Api.Authorization's :Unknown-branch PLATFORM_ADMIN
      # allowance -- any non-503 status here proves tenant B's own request
      # passed BOTH admission gates.
      refute conn_b.status == 503
      assert conn_b.status == 404
    end
  end

  describe "AC3: a successfully admitted request that completes normally releases both refs exactly once" do
    test "cap of 1 concurrent request: two sequential requests both succeed -- the first releases before the second is admitted" do
      AdmissionTestHelpers.restart_admission!(pool_size: 3, reserved_headroom: 1)
      # global_cap == 2. Each single HTTP request acquires from the GLOBAL
      # pool TWICE (once at the global gate, once again as the global half of
      # the tenant gate's own atomic {:tenant, _} acquisition, per
      # Letflow.Admission's own moduledoc "Atomicity algorithm") -- so
      # global_cap == 2 is the smallest value that admits even ONE full
      # request end to end; it is still exactly "cap of 1 concurrent
      # request" in the sense AC3 means (a second, CONCURRENT request would
      # be rejected; a second SEQUENTIAL one, after the first's before_send
      # has released both its refs, succeeds -- which is what this test
      # actually exercises). With exactly one tenant ever tracked, that
      # tenant's own per-tenant cap is max(div(2,1),1) == 2, at least as
      # large as the global cap, so it never independently constrains this.
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req217-ac3")
      {_user, plaintext} = platform_admin_token!(tenant)

      conn1 =
        api_token_request(:get, "/api/v1/identity/anything", plaintext, tenant.tenant.slug)
        |> dispatch()

      refute conn1.status == 503
      assert conn1.status == 404

      conn2 =
        api_token_request(:get, "/api/v1/identity/anything", plaintext, tenant.tenant.slug)
        |> dispatch()

      refute conn2.status == 503
      assert conn2.status == 404
    end
  end

  describe "AC4 (Mechanism A): a raise inside the matched route handler still releases both refs" do
    test "a malformed :id inside Letflow.Routers.Identity's GET /users/:id raises Plug.Conn.WrapperError; a subsequent request still succeeds" do
      # global_cap == 2 -- see AC3's test above for why a single request needs
      # at least 2 (one unit per admission gate, both drawing on the same
      # global counter for the SAME request).
      AdmissionTestHelpers.restart_admission!(pool_size: 3, reserved_headroom: 1)
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req217-ac4-mecha")
      {user, plaintext} = platform_admin_token!(tenant)

      crashing_conn =
        api_token_request(
          :get,
          "/api/v1/identity/users/not-a-uuid",
          plaintext,
          tenant.tenant.slug
        )

      # Repo.get(User, "not-a-uuid", ...) inside Letflow.Routers.Identity's own
      # handle_get/3 (matched route handler, i.e. AFTER :match/:dispatch)
      # raises Ecto.Query.CastError. Plug.Router's own dispatch/2 wraps that in
      # Plug.Conn.WrapperError (design doc §0), which Letflow.Plugs.ApiPipeline's
      # `use Plug.ErrorHandler` catches via its `rescue e in Plug.Conn.WrapperError`
      # clause (e.conn IS the fully-downstream conn here, carrying both
      # admission-ref assigns) before Plug.ErrorHandler's own generated call/2
      # unconditionally re-raises.
      assert_raise Plug.Conn.WrapperError, fn -> dispatch(crashing_conn) end

      # Both admission refs must have been released by handle_errors/2 (via
      # Letflow.Plugs.Admission.release_pending_refs/0) for this to succeed --
      # global_cap is exactly 2 (the smallest value one request's own two
      # acquisitions can fit under, see the setup comment above), so a leaked
      # ref from the crashed request would make this next request 503
      # instead (only 1 spare global unit would remain, not the 2 a fresh
      # request needs).
      follow_up_conn =
        api_token_request(
          :get,
          "/api/v1/identity/users/#{user.id}",
          plaintext,
          tenant.tenant.slug
        )
        |> dispatch()

      assert follow_up_conn.status == 200
    end
  end

  describe "AC6: chain order (read lib/letflow/plugs/api_pipeline.ex directly)" do
    test "the global admission plug is first (before Plug.Parsers); the tenant admission plug is after AuthPipeline and before TenantStatus" do
      source = File.read!(Path.join([File.cwd!(), "lib", "letflow", "plugs", "api_pipeline.ex"]))

      global_admission_idx =
        :binary.match(source, "plug(Letflow.Plugs.Admission, pool: :global)") |> elem(0)

      parsers_idx = :binary.match(source, "plug(Plug.Parsers,") |> elem(0)
      auth_pipeline_idx = :binary.match(source, "plug(Letflow.Plugs.AuthPipeline)") |> elem(0)

      tenant_admission_idx =
        :binary.match(source, "plug(Letflow.Plugs.Admission, pool: :tenant)") |> elem(0)

      tenant_status_idx = :binary.match(source, "plug(Letflow.Plugs.TenantStatus)") |> elem(0)

      assert global_admission_idx < parsers_idx
      assert parsers_idx < auth_pipeline_idx
      assert auth_pipeline_idx < tenant_admission_idx
      assert tenant_admission_idx < tenant_status_idx
    end
  end
end
