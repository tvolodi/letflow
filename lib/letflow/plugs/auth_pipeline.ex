defmodule Letflow.Plugs.AuthPipeline do
  @moduledoc """
  Letflow's first real auth plug — supersedes the never-built REQ-103
  dev-bearer-token plug (cancelled along with the rest of the MVP-1
  milestone; REQ-103 is not prior art this module extends, it never landed).

  Ports the orchestration order from R-Co's `src/api/middleware/auth.zig`
  (`authenticate/3` → `tryTenantRealmAuth` → `postAuthJitProvision`):

    1. Bearer-token extraction + verification (`Letflow.Oidc.TokenVerifier`,
       backed by REQ-016's supervised `Oidcc.ProviderConfiguration.Worker`).
    2. Tenant resolution from the token's `iss` claim's realm
       (`Letflow.Identity.resolve_tenant_by_realm/1`).
    3. Realm-ownership guard, **before** JIT provisioning
       (`Letflow.Identity.verify_realm_ownership/2`).
    4. JIT provisioning/lookup (`Letflow.Identity.provision_oidc_user/4`).
    5. Attach an auth context (`user_id`, `tenant_id`, `roles`) to
       `conn.assigns[:auth_context]` for downstream plugs.

  A request with a missing/malformed bearer token is rejected with 401
  before any DB or claim-mapping work runs (step 1's short-circuit).

  **Not mounted in front of any route today.** All 3 of `Letflow.Router`'s
  existing routes (`POST /instances`, `POST /instances/:id/actions`,
  `GET /instances/:id`) are non-tenant-scoped and have no tenant/user context
  to use even if this plug ran ahead of them — mounting it unconditionally
  would break their existing unauthenticated behavior, which is
  already-`done`, already-tested functionality outside this requirement's
  scope. This module is built, compiled, and directly tested — left
  available for S4 (the first tenant-scoped route) to add via
  `plug Letflow.Plugs.AuthPipeline` ahead of `:match` in `router.ex`.

  See `lib/letflow/design/req021-auth-plug-pipeline.md` for the full design.
  """

  @behaviour Plug

  import Plug.Conn

  alias Letflow.Identity
  alias Letflow.Oidc.ClaimMapping
  alias Letflow.Oidc.ClaimMappingConfig
  alias Letflow.Oidc.JitProvisioningConfig
  alias Letflow.TenantProvisioning

  @impl Plug
  def init(opts), do: opts

  # Every branch's failure reason is tagged with which pipeline step
  # produced it (rather than matched by the raw, callee-specific reason atom
  # in the `else` clause below) — the verifier adapter, `resolve_tenant_by_realm/1`,
  # and `provision_oidc_user/4` all use `:not_found`/similarly-generic atoms
  # for unrelated failures, so dispatching on the bare reason alone would
  # conflate them. Tagging the step is what keeps each failure mapped to the
  # correct status code (§5) regardless of which callee produced it.
  @impl Plug
  def call(conn, _opts) do
    with {:ok, raw_token} <- extract_bearer_token(conn),
         {:ok, claims} <- verify_token(raw_token),
         {:ok, realm} <- extract_realm(claims),
         {:ok, tenant} <- resolve_tenant(realm),
         :ok <- guard_realm_ownership(tenant.id, realm),
         {:ok, identity_context} <- map_claims(realm, claims),
         {:ok, provisioned} <- provision_user(identity_context, tenant.id, realm) do
      attach_auth_context(conn, tenant.id, provisioned.user.id, identity_context.roles)
    else
      {:error, {:header, _reason}} ->
        reject(conn, 401, "unauthorized", "missing or malformed Authorization header")

      {:error, {:verify, _reason}} ->
        reject(conn, 401, "unauthorized", "invalid or expired bearer token")

      {:error, {:realm, _reason}} ->
        reject(conn, 401, "unauthorized", "invalid or expired bearer token")

      {:error, {:tenant, _reason}} ->
        reject(conn, 401, "unauthorized", "invalid or expired bearer token")

      {:error, {:ownership, :realm_tenant_mismatch}} ->
        reject(conn, 401, "unauthorized", "token realm does not match tenant")

      {:error, {:ownership, :not_found}} ->
        reject(conn, 401, "unauthorized", "invalid or expired bearer token")

      {:error, {:claims, _reason}} ->
        reject(conn, 401, "unauthorized", "invalid or expired bearer token")

      {:error, {:provision, :jit_disabled}} ->
        reject(conn, 403, "forbidden", "JIT provisioning disabled for this realm")

      {:error, {:provision, _reason}} ->
        reject(conn, 500, "internal_error", "user provisioning failed")
    end
  end

  # Step 1a — RFC 6750 §2.1 case-sensitive "Bearer " prefix, matching
  # auth.zig's own check. Missing header, wrong prefix, or an empty token
  # after stripping the prefix all short-circuit here, before step 1b's
  # verifier call — no DB or claim-mapping work has run yet.
  defp extract_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) > 0 -> {:ok, token}
      _other -> {:error, {:header, :missing_or_malformed}}
    end
  end

  # Step 1b — verify via the configured Letflow.Oidc.TokenVerifier
  # implementation (real oidcc adapter or the test double, per config).
  # Every {:error, _reason} the verifier returns collapses to a single 401 —
  # this design does not distinguish malformed/expired/bad-signature at the
  # HTTP-response level (§3.1's OQ-4).
  defp verify_token(raw_token) do
    oidc_config = Application.fetch_env!(:letflow, :oidc)
    verifier = Keyword.fetch!(oidc_config, :token_verifier)
    provider_name = Keyword.fetch!(oidc_config, :provider_name)

    case verifier.verify_bearer_token(raw_token, provider_name) do
      {:ok, claims} -> {:ok, claims}
      {:error, reason} -> {:error, {:verify, reason}}
    end
  end

  # Step 2a — realm slug parsed from the `iss` claim's "/realms/" suffix
  # (matching auth.zig's own realmSlugFromIssuer/1), not a `tenant_id` claim.
  defp extract_realm(claims) do
    case Map.get(claims, "iss") do
      iss when is_binary(iss) ->
        case String.split(iss, "/realms/", parts: 2) do
          [_prefix, realm] when byte_size(realm) > 0 -> {:ok, realm}
          _other -> {:error, {:realm, :unresolvable}}
        end

      _other ->
        {:error, {:realm, :unresolvable}}
    end
  end

  # Step 2b — Letflow.Identity.resolve_tenant_by_realm/1.
  defp resolve_tenant(realm) do
    case Identity.resolve_tenant_by_realm(realm) do
      {:ok, tenant} -> {:ok, tenant}
      {:error, reason} -> {:error, {:tenant, reason}}
    end
  end

  # Step 3 — Letflow.Identity.verify_realm_ownership/2, called before any
  # JIT provisioning runs (AC4's explicit ordering guarantee).
  defp guard_realm_ownership(tenant_id, realm) do
    case Identity.verify_realm_ownership(tenant_id, realm) do
      :ok -> :ok
      {:error, reason} -> {:error, {:ownership, reason}}
    end
  end

  # Step 4a — pure claim mapping (Letflow.Oidc.ClaimMapping.map_verified_claims/3).
  defp map_claims(realm, claims) do
    config = ClaimMappingConfig.for_realm(realm)
    subject = Map.get(claims, "sub")

    case ClaimMapping.map_verified_claims(config, subject, claims) do
      {:ok, identity_context} -> {:ok, identity_context}
      {:error, reason} -> {:error, {:claims, reason}}
    end
  end

  # Step 4b — Letflow.Identity.provision_oidc_user/4. tenant_id passed here
  # is the step-2-resolved, DB-sourced value — never
  # identity_context.tenant_id (the token-claimed hint field). REQ-063 moved
  # `users` behind schema-per-tenant, so this step must first derive the
  # tenant's physical schema name (pure, no extra DB round trip --
  # TenantProvisioning.schema_name_for_tenant/1 is confirmed no-I/O) and pass
  # it through as provision_oidc_user/4's new `prefix:` opt.
  defp provision_user(identity_context, tenant_id, realm) do
    jit_config = JitProvisioningConfig.for_realm(realm)

    case TenantProvisioning.schema_name_for_tenant(tenant_id) do
      {:ok, schema_name} ->
        case Identity.provision_oidc_user(identity_context, tenant_id, jit_config,
               prefix: schema_name
             ) do
          {:ok, provisioned} -> {:ok, provisioned}
          {:error, reason} -> {:error, {:provision, reason}}
        end

      {:error, :invalid_tenant_id} ->
        {:error, {:provision, :invalid_tenant_id}}
    end
  end

  defp attach_auth_context(conn, tenant_id, user_id, roles) do
    assign(conn, :auth_context, %{user_id: user_id, tenant_id: tenant_id, roles: roles})
  end

  defp reject(conn, status, error, detail) do
    body = Jason.encode!(%{error: error, detail: detail})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end
end
