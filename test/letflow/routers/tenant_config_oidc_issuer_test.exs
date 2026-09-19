defmodule Letflow.Routers.TenantConfigOidcIssuerTest do
  @moduledoc """
  Regression tests for ISS-0719
  (`lib/letflow/design/iss-0719-tenant-config-oidc-issuer-fix.md` §4) —
  `oidc_issuer_base/0` in `lib/letflow/routers/tenant_config.ex` now reads
  `Application.get_env(:letflow, :oidc, [])[:keycloak_base_url]` instead of the
  retired `:issuer` key (REQ-370 removed `:issuer` from every config file).

  **Deliberately `async: false`, in its own module, separate from
  `Letflow.Routers.TenantConfigTest`.** Every test here mutates the global
  `config :letflow, :oidc` application env via `Application.put_env/3` to
  exercise `oidc_issuer_base/0`'s live lookup -- `Application` config is
  process-shared VM state, so overriding it is only safe when no other
  (`async: true`) test can observe the swapped value concurrently. Mirrors
  `test/letflow/plugs/auth_pipeline_configurable_verifier_test.exs`'s own
  `setup`/`on_exit` pattern for the same `:oidc` key.

  Uses `Letflow.DataCase` (real Postgres) only because `Letflow.Router.call/2`
  is dispatched through the real HTTP path, same as
  `Letflow.Routers.TenantConfigTest` -- this endpoint touches no per-tenant
  schema, so plain `Letflow.DataCase` is sufficient.
  """

  use Letflow.DataCase, async: false

  import Plug.Test

  @router_opts Letflow.Router.init([])

  defp call(conn), do: Letflow.Router.call(conn, @router_opts)

  defp get_config do
    conn = conn(:get, "/api/tenant-config")
    conn = call(conn)
    {conn, Jason.decode!(conn.resp_body)}
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Fail-then-pass regression proof: oidc_authority must reflect the LIVE
  # compiled :keycloak_base_url, not just a value coincidentally matching
  # @default_idp_base_url. Pre-fix, `oidc_issuer_base/0` read the retired
  # `:issuer` key -- always nil -- so `idp_base_url/0` fell all the way through
  # to the hardcoded "http://localhost:8082" default regardless of what
  # `:keycloak_base_url` was configured to. This test sets
  # `:keycloak_base_url` to a value that is NOT "http://localhost:8082" (the
  # local default every other test in this suite happens to coincide with),
  # so it can only pass if the code path genuinely reads the live
  # `:keycloak_base_url` value.
  # ═══════════════════════════════════════════════════════════════════════════

  describe "oidc_issuer_base/0 reads the live :keycloak_base_url (ISS-0719 fail-then-pass proof)" do
    setup do
      original_oidc_config = Application.fetch_env!(:letflow, :oidc)

      on_exit(fn -> Application.put_env(:letflow, :oidc, original_oidc_config) end)

      %{original_oidc_config: original_oidc_config}
    end

    test "a distinctive keycloak_base_url (not the local default) is reflected in oidc_authority",
         %{original_oidc_config: original_oidc_config} do
      distinctive_base_url = "https://auth.qa.bizdala.com"
      refute distinctive_base_url == "http://localhost:8082"

      Application.put_env(
        :letflow,
        :oidc,
        Keyword.put(original_oidc_config, :keycloak_base_url, distinctive_base_url)
      )

      {conn, body} = get_config()

      assert conn.status == 200
      assert body["oidc_authority"] == distinctive_base_url <> "/realms/bpm-default"
      refute body["oidc_authority"] =~ "localhost:8082"
    end

    test "an unset/nil keycloak_base_url falls back gracefully through the || chain, no crash",
         %{original_oidc_config: original_oidc_config} do
      Application.put_env(
        :letflow,
        :oidc,
        Keyword.put(original_oidc_config, :keycloak_base_url, nil)
      )

      {conn, body} = get_config()

      assert conn.status == 200
      assert body["oidc_authority"] == "http://localhost:8082/realms/bpm-default"
    end

    test "the retired :issuer key is truly ignored, even when still present alongside a nil keycloak_base_url",
         %{original_oidc_config: original_oidc_config} do
      Application.put_env(
        :letflow,
        :oidc,
        original_oidc_config
        |> Keyword.put(:issuer, "http://some-other-host/realms/x")
        |> Keyword.put(:keycloak_base_url, nil)
      )

      {conn, body} = get_config()

      assert conn.status == 200
      refute body["oidc_authority"] =~ "some-other-host"
      assert body["oidc_authority"] == "http://localhost:8082/realms/bpm-default"
    end
  end
end
