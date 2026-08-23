defmodule Letflow.Integration.KeycloakAuthPipelineTest do
  @moduledoc """
  REQ-134 — real-Keycloak integration path for `Letflow.Plugs.AuthPipeline`.

  Implements `lib/letflow/design/req134-real-keycloak-token-integration.md` §6-§7
  exactly. Excluded from every default `mix test`/`scripts/test_parallel.sh` invocation
  via `test/test_helper.exs`'s `ExUnit.start(exclude: [:keycloak])` — this module carries
  `@moduletag :keycloak`, module-level (every test in this file needs a real, running
  Keycloak; there is no partial-skip case).

  ## Running this suite deliberately

      mix test --include keycloak test/letflow/integration/keycloak_auth_pipeline_test.exs

  Requires `docker compose up -d keycloak` (and the app's Postgres) to be running first —
  see the `setup_all` reachability check below for the exact probe and message a
  developer gets if it is not.

  ## Deviation from design §3.1's literal `{:skip, message}` mechanism (recorded, not
  silent)

  Design §3.1 specifies `setup_all` returning `{:skip, message}` to mark every test in
  this module "skipped" rather than "failed" when Keycloak is unreachable. Measured
  directly against this repo's installed toolchain (Elixir 1.20.3 / ex_unit 1.20.3,
  `elixir --version`): `ExUnit`'s `setup_all` callback does **not** accept `{:skip, _}`
  as a return value in this version — it raises `RuntimeError: expected ExUnit setup_all
  callback ... to return the atom :ok, a keyword, or a map, got {:skip, ...} instead`,
  which is a strictly *more* obscure failure than a plain, targeted message would be (it
  buries the real "Keycloak not ready" text inside an ExUnit-internal complaint about an
  invalid return shape). `ExUnit`'s dynamic-skip tag mechanism
  (`ExUnit.Filters.eval/4`'s `{:skipped, message}`) is evaluated from each test's
  compile-time `tags` map during `prepare_tests/4`, strictly *before* any `setup_all`/
  `setup` callback runs — so a runtime-computed skip reason cannot flow into it either.

  This module therefore raises a plain `RuntimeError` carrying the exact intended message
  text from `setup_all` when the reachability probe fails. `mix test`'s summary reports
  this as a failure (`ExUnit.Case, all tests have been invalidated`), not literally
  "skipped" — but the message itself is exactly AC5's two required components (what's
  down, what to do about it), and is the first and only thing a developer sees, rather
  than being buried under an unrelated obscure error. Reported to ORCH as a MINOR
  design/implementation discrepancy (same shape as `Letflow.TenantFixture`'s own
  documented `@type` deviation).

  ## Why `async: false` (required, not a style choice)

  `setup/0` below temporarily overrides `Application.get_env(:letflow, :oidc)`'s
  `:token_verifier` key for the whole module's test process — process-global mutable
  state. Running this module concurrently with any other test that also calls
  `AuthPipeline` (e.g. `test/letflow/plugs/auth_pipeline_test.exs`, which runs
  `async: true` against `Letflow.Oidc.TokenVerifierDouble`) would be a real race. The
  override is installed and restored (`on_exit/1`) within this module's own `setup`, so
  no other file ever observes the real-verifier config — but this module itself must not
  run concurrently with anything else that could observe the intermediate state.
  """

  use ExUnit.Case, async: false

  @moduletag :keycloak

  import Ecto.Query, only: [where: 3]
  import Plug.Test
  import Plug.Conn

  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Plugs.AuthPipeline
  alias Letflow.Repo
  alias Letflow.Support.KeycloakTestClient
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @client_id "letflow-web"
  @realm "bpm-default"

  # ---------------------------------------------------------------------------------
  # setup_all -- design §3.1's single reachability probe. See the moduledoc's "Deviation
  # from design §3.1" section for why this raises a plain RuntimeError with the intended
  # skip message text, rather than returning {:skip, message} (unsupported by this
  # installed ExUnit version's setup_all callback).
  # ---------------------------------------------------------------------------------

  setup_all do
    {keycloak_port, _bindings} =
      Code.eval_file(Path.expand("../../../config/keycloak_port.exs", __DIR__))

    discovery_url =
      "http://localhost:#{keycloak_port}/realms/#{@realm}/.well-known/openid-configuration"

    token_url = "http://localhost:#{keycloak_port}/realms/#{@realm}/protocol/openid-connect/token"

    unless KeycloakTestClient.discovery_reachable?(discovery_url) do
      raise "Keycloak not ready at #{discovery_url}. Ensure docker-compose services are " <>
              "running (docker compose up -d keycloak) before executing these tests."
    end

    %{tenant_id: tenant_id, schema_name: schema_name} = ensure_bpm_default_tenant!()

    {:ok, token_url: token_url, tenant_id: tenant_id, schema_name: schema_name}
  end

  # ---------------------------------------------------------------------------------
  # setup -- design §7.1: real-verifier override, installed/restored per test run of
  # this module (not per-test necessary, but on_exit is registered per-test so it
  # unwinds even if an individual test fails).
  # ---------------------------------------------------------------------------------

  setup do
    original_config = Application.fetch_env!(:letflow, :oidc)

    real_verifier_config =
      Keyword.put(original_config, :token_verifier, Letflow.Oidc.TokenVerifier.Oidcc)

    Application.put_env(:letflow, :oidc, real_verifier_config)

    on_exit(fn ->
      Application.put_env(:letflow, :oidc, original_config)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------------
  # Fixture: the bpm-default tenant row (design §5) -- get-or-create, no teardown.
  # ---------------------------------------------------------------------------------

  defp ensure_bpm_default_tenant! do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    tenant =
      case Repo.get_by(Tenant, slug: @realm) do
        %Tenant{} = existing ->
          existing

        nil ->
          %Tenant{}
          |> Tenant.create_changeset(
            %{
              slug: @realm,
              display_name: "Letflow Default Tenant",
              idp_realm_id: @realm
            },
            :enabled
          )
          |> Repo.insert!()
          |> provision_and_replay!()
      end

    TenantFixture.assert_schema_complete!(tenant.id)

    {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant.id)

    %{tenant_id: tenant.id, schema_name: schema_name}
  end

  defp provision_and_replay!(tenant) do
    {:ok, %Registration{}} = TenantProvisioning.provision_tenant_schema(tenant.id)
    {:ok, _applied_versions} = TenantProvisioning.replay_migrations(tenant.id)
    tenant
  end

  # ---------------------------------------------------------------------------------
  # Shared conn-building contract (design §7.4's "the conn-building contract").
  # ---------------------------------------------------------------------------------

  defp call_pipeline_with_token(raw_token) do
    :post
    |> conn("/whatever")
    |> put_req_header("authorization", "Bearer " <> raw_token)
    |> AuthPipeline.call(AuthPipeline.init([]))
  end

  # Design §7.4's jwt_subject/1: decodes the JWT payload segment and reads "sub".
  defp jwt_subject(raw_token) do
    [_header, payload, _signature] = String.split(raw_token, ".")

    payload
    |> Base.url_decode64!(padding: false)
    |> Jason.decode!()
    |> Map.fetch!("sub")
  end

  defp user_count_for_subject(schema_name, subject) do
    User
    |> where([u], u.external_realm == @realm and u.external_id == ^subject)
    |> Repo.aggregate(:count, :id, prefix: schema_name)
  end

  # AC3 fixture reset (rework 2 -- see the AC3 describe block's comment for the full
  # root-cause explanation). Deletes ONLY the row matching this exact
  # (external_realm, external_id) pair, scoped with `prefix: schema_name` to the
  # bpm-default tenant's own physical schema -- the identical scope
  # `user_count_for_subject/2` already queries with, so "what this deletes" and "what
  # the count above/below it observes" can never disagree. Schema-per-tenant (REQ-063)
  # means this can never touch another tenant's data even in principle: there is no
  # `tenant_id` column to get wrong, and Postgres has no cross-schema query here at all.
  # This row is a fixture identity this test itself owns the lifecycle of (JIT-created
  # from a fixed seeded Keycloak credential), not real application data.
  defp reset_subject_row!(schema_name, subject) do
    User
    |> where([u], u.external_realm == @realm and u.external_id == ^subject)
    |> Repo.delete_all(prefix: schema_name)

    :ok
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- genuine token drives the full pipeline end to end.
  # ---------------------------------------------------------------------------------

  describe "acceptance criterion 1 — genuine token drives AuthPipeline end to end" do
    test "a real admin-user token authenticates and attaches the expected auth_context",
         %{token_url: token_url, tenant_id: tenant_id} do
      assert {:ok, raw_token} =
               KeycloakTestClient.direct_access_token(token_url, "admin-user", "admin-pass",
                 client_id: @client_id
               )

      conn = call_pipeline_with_token(raw_token)

      refute conn.halted

      assert %{tenant_id: ^tenant_id, user_id: user_id, roles: roles} =
               conn.assigns[:auth_context]

      assert is_binary(user_id)
      assert "PLATFORM_ADMIN" in roles
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- tampered signature is rejected by the REAL verifier, not the double.
  # ---------------------------------------------------------------------------------

  describe "acceptance criterion 2 — tampered signature is rejected by the real verifier" do
    test "a token with a tampered signature is rejected with 401 unauthorized",
         %{token_url: token_url} do
      assert {:ok, raw_token} =
               KeycloakTestClient.direct_access_token(token_url, "admin-user", "admin-pass",
                 client_id: @client_id
               )

      tampered_token = KeycloakTestClient.tamper_signature(raw_token)
      assert tampered_token != raw_token

      conn = call_pipeline_with_token(tampered_token)

      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => "unauthorized"}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- JIT provisioning creates then reuses a real user row, across two calls.
  # ---------------------------------------------------------------------------------

  describe "acceptance criterion 3 — JIT provisioning creates then reuses a real user row" do
    test "first call provisions a user row, second call reuses it",
         %{token_url: token_url, schema_name: schema_name} do
      assert {:ok, raw_token} =
               KeycloakTestClient.direct_access_token(
                 token_url,
                 "designer-user",
                 "designer-pass",
                 client_id: @client_id
               )

      subject = jwt_subject(raw_token)

      # Rework 2 -- root cause of the previous baseline-diff fix's own failure: the
      # bpm-default tenant/schema (design §5) is permanent and never torn down, and
      # designer-user's JWT `sub` is a FIXED identity (the same seeded Keycloak user,
      # every mint) -- so on any invocation after the first, this row already exists,
      # `provision_oidc_user/4` correctly reuses it (that IS JIT provisioning working),
      # and a bare "count_before -> count_before+1" comparison silently stops being true
      # from the second call onward within THIS run too, because there is no third call
      # to observe a further increment against. A count-based assertion is only
      # meaningful when "before" is a genuine, invocation-independent zero -- so this
      # test resets that exact row first, making the 0 -> 1 -> 1 sequence below true on
      # every invocation, not just a database's first-ever one.
      reset_subject_row!(schema_name, subject)

      assert user_count_for_subject(schema_name, subject) == 0

      conn1 = call_pipeline_with_token(raw_token)
      refute conn1.halted
      user_id_1 = conn1.assigns[:auth_context][:user_id]

      assert user_count_for_subject(schema_name, subject) == 1

      conn2 = call_pipeline_with_token(raw_token)
      refute conn2.halted
      user_id_2 = conn2.assigns[:auth_context][:user_id]

      assert user_id_1 == user_id_2
      assert user_count_for_subject(schema_name, subject) == 1
    end
  end
end
