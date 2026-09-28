defmodule Letflow.Api.AuthorizationAc9Test do
  @moduledoc """
  REQ-069 acceptance criterion 9: "the module reads roles from the assign key
  Letflow.Plugs.AuthPipeline actually sets, confirmed by a test that runs the
  real plug and then the authorization check rather than by hand-constructing
  an assigns map."

  Needs `Letflow.Oidc.ConfigurableTokenVerifierDouble` wired in (not the
  fixed-sentinel `Letflow.Oidc.TokenVerifierDouble` `config/test.exs` wires by
  default) so each test can use its OWN unique realm rather than the shared
  `"bpm-default"` seed tenant — deliberately avoiding that shared realm,
  since concurrent inserts against it are the exact live flaky-test class this
  session investigated as ISS-0108 (a `tenants_idp_realm_id_partial_index`
  collision under concurrent `async: true` test processes). A unique realm per
  test sidesteps that class entirely rather than reproducing it here.

  **Deliberately `async: false`, mirroring
  `test/letflow/plugs/auth_pipeline_configurable_verifier_test.exs`'s own
  documented reasoning**: swapping `config :letflow, :oidc`'s `:token_verifier`
  is global, process-shared `Application` env (an ETS table), so it is only
  safe when no other test can observe the swapped value concurrently.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Api.Authorization
  alias Letflow.Api.Authorization.AccessContext
  alias Letflow.Oidc.ConfigurableTokenVerifierDouble
  alias Letflow.Plugs.AuthPipeline
  alias Letflow.TenantFixture

  import Plug.Test
  import Plug.Conn

  setup do
    original_oidc_config = Application.fetch_env!(:letflow, :oidc)

    Application.put_env(
      :letflow,
      :oidc,
      Keyword.put(original_oidc_config, :token_verifier, ConfigurableTokenVerifierDouble)
    )

    on_exit(fn -> Application.put_env(:letflow, :oidc, original_oidc_config) end)

    :ok
  end

  defp unique_realm(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  # Provisioned via Letflow.TenantFixture (ISS-0112 / GH#366) — replaces the former
  # hand-rolled Sandbox :auto mode + Tenant.create_changeset/3 +
  # provision_tenant_schema/1 + replay_migrations/1 + on_exit/1 teardown sequence,
  # which TenantFixture.provisioned_tenant!/1 already reproduces statement for
  # statement. `oidc_mode: :enabled` matches this file's original `:enabled` third
  # changeset argument.
  defp insert_tenant_for_realm!(realm) do
    %{tenant: tenant} =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "tenant",
        display_name: "AC9 Test Tenant",
        oidc_mode: :enabled,
        idp_realm_id: realm
      )

    tenant
  end

  test "the real AuthPipeline's assigns[:auth_context][:roles] flows through roles_from_strings/1 and evaluate_access/2 correctly" do
    realm = unique_realm("ac9")
    insert_tenant_for_realm!(realm)

    conn =
      conn(:post, "/whatever")
      |> put_req_header("authorization", "Bearer realm-token:#{realm}")

    conn = AuthPipeline.call(conn, AuthPipeline.init([]))

    refute conn.halted
    assert %{roles: raw_roles, user_id: user_id} = conn.assigns[:auth_context]

    # ConfigurableTokenVerifierDouble's realm-token claims carry "VIEWER" — not one
    # of the five real Role names, so this end-to-end path proves both (a) the real
    # assign is read here (not a hand-built map, per this AC's own requirement) and
    # (b) an unrecognized live role string safely converts to [] and denies, per
    # §0.2/AC6, using data that genuinely came from the real plug.
    real_roles = Authorization.roles_from_strings(raw_roles)
    assert real_roles == []

    ctx = %AccessContext{user_id: user_id, roles: real_roles}
    decision = Authorization.evaluate_access(ctx, :DefinitionsRead)
    assert decision.kind == :Deny403
  end
end
