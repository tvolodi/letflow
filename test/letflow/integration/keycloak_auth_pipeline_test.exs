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
  import ExUnit.CaptureLog
  import Plug.Test
  import Plug.Conn

  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Oidc.TokenVerifier.Oidcc
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
      # Partial match on "error" only, mirroring test/letflow/plugs/auth_pipeline_test.exs:196
      # -- AuthPipeline.reject/4 (lib/letflow/plugs/auth_pipeline.ex, pre-existing and
      # unrelated to this suite) always includes a "detail" key alongside "error"; AC2
      # cares that the response is the standard unauthorized shape, not the exact key set.
      assert %{"error" => "unauthorized"} = Jason.decode!(conn.resp_body)
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

  # ---------------------------------------------------------------------------------
  # ISS-0703 regression -- lib/letflow/design/iss0703-oidc-verifier-exception-handling.md
  # section 7. A non-JWT-shaped raw_token must never crash the REAL
  # Letflow.Oidc.TokenVerifier.Oidcc adapter (confirmed live: CaseClauseError deep in
  # jose_base64url.decode!/2, reached via Oidcc.Token.validate_jwt/3), and must never
  # reach Bandit as a raw 500 through the full AuthPipeline. Deliberately NOT using
  # Letflow.Oidc.TokenVerifierDouble (test/letflow/plugs/auth_pipeline_test.exs's
  # string-equality stub never touches real oidcc/jose parsing and cannot exercise this
  # defect at all -- see the design doc's section 7 preamble) -- this file's `setup`
  # above already swaps in the real Oidcc adapter for every test in this module.
  #
  # Two raw_token fixtures, matching the design doc's required breadth:
  #   1. the literal shape that triggered the live incident -- a whole Keycloak
  #      token-endpoint JSON response pasted in as the bearer value instead of just its
  #      "access_token" field (a caller bug, but one the verifier must survive, not
  #      crash on)
  #   2. plain non-base64url garbage, for breadth beyond the one confirmed live shape
  # ---------------------------------------------------------------------------------

  describe "ISS-0703 regression — malformed raw_token never crashes the real adapter" do
    @json_blob_fixture ~s({"access_token":"eyJhbGciOiJSUzI1NiJ9.not-a-real-jwt.sig","expires_in":300,"token_type":"Bearer"})
    # Deliberately dot-segmented (superficially JWT-shaped, three "." separated parts)
    # but every segment is plain non-base64url garbage -- verified empirically
    # (scratch probe against this branch's post-fix code) to reach the same
    # jose_base64url.decode!/2 CaseClauseError crash chain as @json_blob_fixture.
    # A plain undotted garbage string (e.g. "not-base64url-at-all") does NOT reach
    # that call chain -- oidcc's own earlier shape check rejects it with a normal
    # {:error, :no_matching_key}, without ever entering this module's rescue/catch
    # boundary -- so it would not be a fail-first fixture for this regression at all.
    @garbage_fixture "not-base64url.not-base64url.not-base64url"

    # Fixed, hand-picked substrings (each >= 4 chars) drawn from each fixture above --
    # the design doc's "representative substrings" non-leakage check. Chosen to include
    # both the fixture's most distinctive alphanumeric run and adjacent punctuation, so
    # a leak of either the token's raw bytes or an `inspect/1`-quoted rendering of them
    # would still be caught.
    @json_blob_substrings [
      "access_token",
      "eyJhbGciOiJSUzI1NiJ9",
      "not-a-real-jwt",
      "token_type"
    ]
    @garbage_substrings ["not-base64url"]

    # AC1 (unit-level): calls Letflow.Oidc.TokenVerifier.Oidcc.verify_bearer_token/2
    # DIRECTLY -- the real adapter, not through AuthPipeline -- against a real
    # provider_name (config :letflow, :oidc's own Letflow.Oidc.DefaultProvider, which
    # this module's setup_all above has already proven reachable via the discovery
    # probe). This is the fail-first case: on pre-fix oidcc.ex, this call raises
    # CaseClauseError and crashes the test process instead of returning a tuple.
    test "verify_bearer_token/2 returns {:error, {:verifier_crashed, ...}} instead of raising, for a JSON-blob raw_token (the confirmed live trigger shape)" do
      assert_verifier_crashed_cleanly(@json_blob_fixture, @json_blob_substrings)
    end

    test "verify_bearer_token/2 returns {:error, {:verifier_crashed, ...}} instead of raising, for plain non-base64url garbage" do
      assert_verifier_crashed_cleanly(@garbage_fixture, @garbage_substrings)
    end

    # AC2 (integration-level): same two fixtures, but through the FULL pipeline
    # (Letflow.Plugs.AuthPipeline.call/2, this file's own call_pipeline_with_token/1
    # helper, matching this file's existing conn-building convention) -- proving the
    # crash no longer escapes as a raw HTTP 500 with an empty body, but collapses to the
    # pipeline's documented single-401 shape (auth_pipeline.ex:156-157), exactly like
    # any other verification failure.
    test "AuthPipeline.call/2 rejects a JSON-blob bearer token with a clean 401, not a 500 crash" do
      assert_pipeline_rejects_cleanly(@json_blob_fixture)
    end

    test "AuthPipeline.call/2 rejects a plain-garbage bearer token with a clean 401, not a 500 crash" do
      assert_pipeline_rejects_cleanly(@garbage_fixture)
    end

    # ---- shared assertion helpers for this describe block -----------------------

    defp assert_verifier_crashed_cleanly(raw_token, leak_substrings) do
      oidc_config = Application.fetch_env!(:letflow, :oidc)
      provider_name = Keyword.fetch!(oidc_config, :provider_name)

      log =
        capture_log(fn ->
          result = Oidcc.verify_bearer_token(raw_token, provider_name)
          send(self(), {:verify_result, result})
        end)

      assert_received {:verify_result, result}

      assert {:error, {:verifier_crashed, %{kind: :error, classification: classification}}} =
               result

      assert is_atom(classification)

      classification_string = to_string(classification)

      # Explicit non-leakage assertion (SECURITY-REVIEWER BLOCKER, design §3a): neither
      # the returned classification nor the captured Logger.warning/1 output may contain
      # any substring of the raw_token fixture that triggered the crash.
      for substring <- leak_substrings do
        refute String.contains?(classification_string, substring),
               "classification #{inspect(classification_string)} leaked raw_token substring #{inspect(substring)}"

        refute String.contains?(log, substring),
               "captured log leaked raw_token substring #{inspect(substring)}: #{log}"
      end
    end

    defp assert_pipeline_rejects_cleanly(raw_token) do
      conn = call_pipeline_with_token(raw_token)

      assert conn.halted
      assert conn.status == 401
      assert get_resp_header(conn, "content-type") |> Enum.at(0) =~ "application/json"

      assert %{"error" => "unauthorized", "detail" => "invalid or expired bearer token"} =
               Jason.decode!(conn.resp_body)
    end
  end
end
