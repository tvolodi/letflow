defmodule Letflow.Plugs.Iss0778PlatformRoleSeedingE2eTest do
  @moduledoc """
  ISS-0778 T4 (`lib/letflow/design/iss-0778-platform-role-seeding.md` §5) — the direct,
  executable proof of the issue's own stated acceptance criterion
  (`docs/issues/ISS-0778.yaml`): a real HTTP `POST /api/v1/onboarding` provisions a
  tenant, then a real OIDC token (via the test double) claiming `PLATFORM_ADMIN`
  successfully authenticates AND reaches a PLATFORM_ADMIN-gated endpoint, with ZERO
  manual `Letflow.Identity`/`Letflow.Identity.RoleRegistry` bootstrap calls in this
  test itself — exactly the step UAT-RUNNER had to do by hand during REQ-375's UAT
  run. Includes a negative control: a non-privileged role's token still correctly
  403s on the same gated endpoint, for the same tenant.

  See `test/letflow/tenant_onboarding_test.exs`'s "ISS-0778 T3" describe block for
  the provisioning-orchestration-level proof this test builds on (role seeding runs
  as part of real provisioning), and `test/letflow/identity_test.exs`'s "ISS-0778 T2"
  describe block for the unit-level sync proof. This file is the outermost,
  full-stack layer: real `Letflow.Router.call/2` dispatch, the real
  `Letflow.TenantOnboarding.provision_and_migrate/1` side effect (triggered by a real
  `POST /api/v1/onboarding`), and real OIDC JIT provisioning +
  `Letflow.Identity.sync_role_claims_from_token/3` (triggered by a real bearer
  token) — no step in this test calls `Letflow.Identity.add_group_member/3`,
  `Letflow.Identity.RoleRegistry.upsert_role/4`, or any other manual bootstrap
  function directly.

  ## Fixture mechanics for a freshly-onboarded tenant's OIDC realm (design §6 open question, resolved here)

  `POST /api/v1/onboarding`'s own `@create_schema`
  (`lib/letflow/routers/onboarding.ex`) accepts no `idp_realm_id` field at all, and
  `Letflow.Identity.Tenant`'s own moduledoc documents `idp_realm_id` as immutable
  after creation (structurally absent from `update_changeset/2`'s cast list) — so
  there is no *supported*, non-onboarding path to bind a freshly-onboarded tenant to
  a specific OIDC realm through this codebase's public API at all (confirmed by
  direct source read, not assumed).

  This test resolves that gap the same way
  `test/letflow/plugs/iss0736_oidc_live_revocation_test.exs` already resolves an
  adjacent one: `Letflow.Support.BpmDefaultRealmDisplacement.displace!/0` takes
  exclusive, test-owned control of the one realm (`"bpm-default"`) this suite's OIDC
  test doubles already recognize, and this test then binds the freshly-onboarded
  tenant to that realm directly via `Repo.update_all/2` — a raw, changeset-bypassing
  write, the only way to set `idp_realm_id` post-creation at all, given the
  immutability above. This stands in for the out-of-band IdP-realm-configuration step
  a real deployment's operator performs once a new tenant is provisioned (explicitly
  out of this codebase's scope, design §1/§4: "The IdP-side configuration that
  decides which real human ends up with a token... remains entirely out of this
  codebase's scope"). This bypass is realm/IdP-configuration plumbing — it sets up
  WHICH tenant a token's `iss` claim resolves to, the same kind of test-only wiring
  `Letflow.Support.BpmDefaultRealmDisplacement` itself already performs — not a
  `Letflow.Identity`/`Letflow.Identity.RoleRegistry` role-bootstrap call. Every
  platform-role GRANT this test observes is produced entirely by the real
  onboarding-provisioning path (T3's mechanism) plus the real, unmodified OIDC
  JIT-sync path (T2's mechanism).

  `async: false` for the whole module: displaces the shared `"bpm-default"` realm
  binding and provisions real, committed Postgres tenants outside any sandboxed
  transaction, same reasoning as every other `async: false` module in this suite
  that does so.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias Letflow.Identity
  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Oidc.Iss0778PlatformAdminTokenVerifierDouble
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  defp insert_user!(tenant, attrs \\ []) do
    default = %{
      username: "iss0778-e2e-caller-#{Ecto.UUID.generate()}",
      display_name: "ISS-0778 E2E Test Caller",
      email: "iss0778-e2e-caller-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    }

    %User{}
    |> Ecto.Changeset.change(Map.merge(default, Map.new(attrs)))
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  # Mints a real API token for a fresh tenant/user pair holding exactly `roles` --
  # everything a caller needs to authenticate through the real AuthPipeline API-token
  # branch to place the initial POST /onboarding call. Ported from
  # test/letflow/routers/onboarding_test.exs's own mint_caller!/2.
  defp mint_caller!(slug_prefix, roles) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)
    user = insert_user!(tenant)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil},
        prefix: tenant.schema_name
      )

    {plaintext, tenant.tenant.slug}
  end

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  # No default `body \\ nil` here (ISS-0069): this file's only call site (below,
  # the POST /onboarding request) always supplies a body, so a default would be
  # dead code -- unlike test/letflow/routers/onboarding_test.exs's own
  # authed_request/5, which this was ported from and which DOES have GET-with-no-
  # body call sites elsewhere in that file.
  defp authed_request(method, path, plaintext, tenant_slug, body) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> plaintext)
    |> put_req_header("x-tenant-slug", tenant_slug)
  end

  defp oidc_request(method, path, bearer_token) do
    conn(method, path)
    |> put_req_header("authorization", "Bearer " <> bearer_token)
  end

  defp unique_hostname(prefix), do: "#{prefix}-#{Ecto.UUID.generate()}.example.com"
  defp unique_onboarding_slug(prefix), do: Letflow.TenantSlugFixture.unique_slug(prefix)

  # Full teardown for a tenant created via a real POST /onboarding, mirroring
  # test/letflow/routers/onboarding_test.exs's cleanup_onboarded_tenant!/1 exactly
  # (FK dependency order: onboarding_registry -> tenant_schemas -> tenants).
  defp cleanup_onboarded_tenant!(tenant_id) do
    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      case TenantProvisioning.schema_name_for_tenant(tenant_id) do
        {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(o in OnboardingRecord, where: o.tenant_id == ^tenant_id))
      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
    end)
  end

  # Binds a freshly-onboarded tenant to the "bpm-default" realm directly, bypassing
  # Tenant.update_changeset/2's structural idp_realm_id immutability -- see this
  # file's own moduledoc "Fixture mechanics" section for why this bypass is the only
  # available mechanism, and why it is realm/IdP-configuration plumbing, not a
  # Letflow.Identity/RoleRegistry role-bootstrap call.
  defp bind_tenant_to_bpm_default_realm!(tenant_id) do
    {count, nil} =
      Repo.update_all(from(t in Tenant, where: t.id == ^tenant_id),
        set: [idp_realm_id: "bpm-default"]
      )

    assert count == 1
  end

  # Scoped Application-config swap, same mechanism
  # test/letflow/plugs/iss0736_oidc_live_revocation_test.exs's own
  # use_role_claim_token_verifier!/0 already establishes -- registers an on_exit/1
  # restore as a safety net, but ALSO returns the original config so this test can
  # restore it explicitly mid-test (this test needs BOTH doubles active at different
  # points of the SAME test, for the positive case and the negative control).
  defp use_platform_admin_token_verifier! do
    original_oidc_config = Application.fetch_env!(:letflow, :oidc)

    Application.put_env(
      :letflow,
      :oidc,
      Keyword.put(original_oidc_config, :token_verifier, Iss0778PlatformAdminTokenVerifierDouble)
    )

    on_exit(fn -> Application.put_env(:letflow, :oidc, original_oidc_config) end)

    original_oidc_config
  end

  describe "ISS-0778 T4 (design §5): freshly-onboarded tenant, PLATFORM_ADMIN OIDC token, zero manual bootstrap" do
    test "POST /onboarding provisions a tenant; a PLATFORM_ADMIN-claiming OIDC token reaches a PLATFORM_ADMIN-gated route; a non-privileged token still 403s on the same tenant" do
      Letflow.Support.BpmDefaultRealmDisplacement.displace!()

      # ── Step 1 (design §5.1): real, PLATFORM_ADMIN-authenticated
      # POST /api/v1/onboarding ──────────────────────────────────────────────
      {admin_plaintext, admin_slug} = mint_caller!("iss0778-e2e-caller", ["PLATFORM_ADMIN"])

      slug = unique_onboarding_slug("iss0778-e2e-new")
      hostname = unique_hostname("iss0778-e2e")

      create_conn =
        authed_request(:post, "/api/v1/onboarding", admin_plaintext, admin_slug, %{
          "slug" => slug,
          "display_name" => "ISS-0778 T4 New Tenant",
          "hostname" => hostname
        })
        |> dispatch()

      assert create_conn.status == 201
      resp = Jason.decode!(create_conn.resp_body)
      new_tenant_id = resp["tenant_id"]
      assert is_binary(new_tenant_id)

      cleanup_onboarded_tenant!(new_tenant_id)

      # provision_and_migrate/1 (T3's mechanism, exercised for real by the request
      # above) already seeded all six platform roles as part of handling THIS
      # request, and flipped the tenant to :active -- confirmed structurally here
      # (status), and confirmed FUNCTIONALLY below by the OIDC request actually
      # succeeding. No Letflow.Identity/RoleRegistry call appears anywhere in this
      # test, per the issue's own "zero manual bootstrap" acceptance criterion.
      assert %Tenant{status: :active} = Repo.get(Tenant, new_tenant_id)

      # Bind this freshly-onboarded tenant to the one realm the test doubles
      # recognize -- see this file's own moduledoc "Fixture mechanics" section.
      bind_tenant_to_bpm_default_realm!(new_tenant_id)

      # ── Step 2/3 (design §5.2/§5.3): a PLATFORM_ADMIN-claiming OIDC token
      # reaches a PLATFORM_ADMIN-gated route (GET /api/v1/tenants, :TenantsManage
      # per lib/letflow/api/authorization.ex's endpoint_policy_key/2) ───────────
      original_oidc_config = use_platform_admin_token_verifier!()

      admin_conn =
        oidc_request(:get, "/api/v1/tenants", "iss0778-platform-admin-token")
        |> dispatch()

      assert admin_conn.status == 200
      assert "PLATFORM_ADMIN" in admin_conn.assigns.auth_context.roles
      assert admin_conn.assigns.auth_context.tenant_id == new_tenant_id

      # ── Step 4 (design §5.4): explicit negative control -- restore the default
      # double (claims ["VIEWER"], which is not one of
      # Letflow.Api.Authorization.roles/0's six seeded literals) and hit the SAME
      # gated route on the SAME tenant. Proves the step-3 pass is because the
      # claimed role genuinely resolved through the seeded binding, not because
      # this route is unguarded for this tenant. ────────────────────────────────
      Application.put_env(:letflow, :oidc, original_oidc_config)

      viewer_conn =
        oidc_request(:get, "/api/v1/tenants", "valid-test-token")
        |> dispatch()

      assert viewer_conn.status == 403
      assert viewer_conn.assigns.auth_context.tenant_id == new_tenant_id

      # NOT ["VIEWER"] -- Letflow.Plugs.AuthPipeline's OIDC branch attaches the
      # LIVE, DB-derived role set (Letflow.Identity.list_effective_role_names/2),
      # never the JWT's own claimed roles directly (REQ-378 §1-§2's live-role-query
      # design, unchanged by this issue). "VIEWER" is not one of
      # Letflow.Api.Authorization.roles/0's six seeded literals, so
      # sync_role_claims_from_token/3 resolves it to zero group_ids and grants
      # nothing -- this caller is authenticated but holds no live platform role at
      # all, which is exactly why :TenantsManage denies it.
      assert viewer_conn.assigns.auth_context.roles == []
    end
  end
end
