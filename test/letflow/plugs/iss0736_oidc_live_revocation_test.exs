defmodule Letflow.Plugs.Iss0736OidcLiveRevocationTest do
  @moduledoc """
  Regression test for ISS-0736 / REQ-378 AC1 (`lib/letflow/design/req378-oidc-live-revocation-check.md`):
  a `tenant_admin` revoking a signed-in `business_user`'s role/group membership
  takes effect on that user's very next request, with **no** sleep, no token
  refresh, no re-authentication — the identical bearer JWT is reused across the
  before/after requests. See `test/specs/ISS-0736.md` for the full rationale and
  the fail-then-pass proof.

  Follows `test/letflow/api_token_auth_pipeline_test.exs`'s established
  full-pipeline dispatch convention (`Letflow.Router.call/2`, not
  `AuthPipeline.call/2` in isolation) so the request actually exercises the real
  `AuthPipeline -> Authorize -> Letflow.Routers.Identity` chain AC1/AC3 depend
  on, and `test/letflow/plugs/auth_pipeline_test.exs`'s established
  `Letflow.Oidc.TokenVerifierDouble` sentinel-token + real-provisioned-tenant-
  schema fixture pattern (REQ-063's schema-per-tenant shape) for the OIDC half.

  Uses `Letflow.Identity.add_group_member/3` / `Letflow.Identity.remove_group_member/3`
  directly — the exact same `Letflow.Identity` functions the corrected `web/`
  GUI path (design §4.1) now calls — to grant then revoke the role, per the
  handoff's explicit instruction.

  `async: false` for the whole module: `insert_bpm_default_tenant!/0` (ported
  from `auth_pipeline_test.exs`) switches `Ecto.Adapters.SQL.Sandbox` to global
  `:auto` mode and provisions a real tenant schema, same reasoning as every
  other `async: false` module in this suite that does so.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Plug.Test
  import Plug.Conn

  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TenantRole
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  defp unique_slug(prefix) do
    Letflow.TenantSlugFixture.unique_slug(prefix)
  end

  # Ported verbatim (naming/shape) from
  # test/letflow/plugs/auth_pipeline_test.exs's insert_tenant!/1 +
  # insert_bpm_default_tenant!/0 -- see that file's moduledoc for the full
  # reasoning on why :auto mode must be entered before the tenant row itself
  # is inserted.
  defp insert_tenant!(attrs) do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    tenant =
      %Tenant{}
      |> Tenant.create_changeset(attrs, :enabled)
      |> Repo.insert!()

    on_exit(fn ->
      case TenantProvisioning.schema_name_for_tenant(tenant.id) do
        {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)

    assert {:ok, %Registration{schema_name: _schema_name}} =
             TenantProvisioning.provision_tenant_schema(tenant.id)

    assert {:ok, _applied_versions} = TenantProvisioning.replay_migrations(tenant.id)

    tenant
  end

  defp insert_bpm_default_tenant! do
    # "bpm-default" is the one realm Letflow.Oidc.TokenVerifierDouble's fixed
    # sentinel token always claims (config/test.exs wires this double in for
    # the whole test env). REQ-370's seed migration permanently binds exactly
    # one tenant to idp_realm_id "bpm-default" -- temporarily displaced here
    # (restored via on_exit/1) so this test can own a fresh, exclusively-owned
    # tenant under that same realm. See Letflow.Support.BpmDefaultRealmDisplacement.
    Letflow.Support.BpmDefaultRealmDisplacement.displace!()

    insert_tenant!(%{
      slug: unique_slug("bpm-default-tenant"),
      display_name: "ISS-0736 Live Revocation Test Tenant",
      idp_realm_id: "bpm-default"
    })
  end

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp oidc_request(method, path) do
    conn(method, path)
    |> put_req_header("authorization", "Bearer valid-test-token")
  end

  defp grant_platform_admin!(user_id, schema_name) do
    {:ok, group} =
      Identity.create_group(%{"name" => "iss0736-admins-#{Ecto.UUID.generate()}"},
        prefix: schema_name
      )

    {:ok, _role} =
      %TenantRole{}
      |> TenantRole.changeset(%{name: "PLATFORM_ADMIN", group_id: group.id})
      |> Repo.insert(prefix: schema_name)

    {:ok, %{member: _member, created: true}} =
      Identity.add_group_member(group.id, user_id, prefix: schema_name)

    group
  end

  describe "REQ-378 AC1: role revocation takes effect on the user's very next request, same JWT, no sleep/refresh" do
    test "an OIDC session with PLATFORM_ADMIN succeeds on a PLATFORM_ADMIN-only route; revoking group membership (no re-auth) makes the identical bearer token fail 403 on the very next identical request" do
      tenant = insert_bpm_default_tenant!()
      {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant.id)

      # First call: no role granted yet, but its only purpose here is to JIT-
      # provision the OIDC user (same external identity every call, fixed by
      # the sentinel token's claims) so its user_id is known before the role
      # is granted. Status/result of this call is not asserted -- it is setup,
      # not part of the AC1 proof.
      setup_conn = oidc_request(:get, "/api/v1/identity/tokens") |> dispatch()
      user_id = setup_conn.assigns.auth_context.user_id
      assert is_binary(user_id)

      group = grant_platform_admin!(user_id, schema_name)

      # Same bearer token, same route: now succeeds, proving the live role
      # query (not the JWT's own claims) is what authenticate_oidc/2 hands to
      # evaluate_access/2.
      granted_conn = oidc_request(:get, "/api/v1/identity/tokens") |> dispatch()
      assert granted_conn.status == 200
      assert granted_conn.assigns.auth_context.user_id == user_id
      assert "PLATFORM_ADMIN" in granted_conn.assigns.auth_context.roles

      # The tenant_admin action under test: revoke the membership via the
      # exact same Identity function the corrected web/ GUI path now calls
      # (Identity.remove_group_member/3). No token re-mint, no sleep, no
      # process restart, no cache-clear call between this and the next
      # request below.
      assert :ok = Identity.remove_group_member(group.id, user_id, prefix: schema_name)

      # Immediately retry with the SAME still-valid JWT ("Bearer
      # valid-test-token" -- unchanged, not re-minted). This is the AC1 proof:
      # the very next request after revocation, with no sleep and no token
      # refresh, is denied.
      revoked_conn = oidc_request(:get, "/api/v1/identity/tokens") |> dispatch()
      assert revoked_conn.status == 403
    end

    test "deactivating the account (users.status) also takes effect on the very next request, same JWT" do
      tenant = insert_bpm_default_tenant!()
      {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant.id)

      setup_conn = oidc_request(:get, "/api/v1/identity/tokens") |> dispatch()
      user_id = setup_conn.assigns.auth_context.user_id

      group = grant_platform_admin!(user_id, schema_name)

      granted_conn = oidc_request(:get, "/api/v1/identity/tokens") |> dispatch()
      assert granted_conn.status == 200

      # tenant_admin deactivates the account -- the same status-update write
      # PATCH /users/:id -> Identity.update_user_profile/3 (design §4's
      # table) performs on the same field; called directly here at the
      # Identity level per the handoff's instruction to reuse "the same
      # Identity functions the GUI fix now calls".
      assert {:ok, _user} = Identity.update_user_status(user_id, :inactive, prefix: schema_name)

      deactivated_conn = oidc_request(:get, "/api/v1/identity/tokens") |> dispatch()
      assert deactivated_conn.status == 403

      # group membership left untouched -- proves the deactivation short-
      # circuit itself (not merely an empty role list) is what denies here.
      _ = group
    end
  end
end
