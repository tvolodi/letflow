defmodule Letflow.Oidc.Iss0736RoleClaimTokenVerifierDouble do
  @moduledoc """
  Test-only `Letflow.Oidc.TokenVerifier` implementation, sibling to
  `Letflow.Oidc.TokenVerifierDouble` and
  `Letflow.Oidc.ConfigurableTokenVerifierDouble` (neither of which this module
  replaces or mutates — `config/test.exs` keeps wiring
  `Letflow.Oidc.TokenVerifierDouble` in as the suite-wide default; this double
  is only ever activated locally, per-test, via a scoped
  `Application.put_env/3` swap with an `on_exit/1` restore, same mechanism
  `test/letflow/plugs/auth_pipeline_configurable_verifier_test.exs` already
  uses for the identical reason).

  Both existing doubles hardcode `realm_access.roles` to `["VIEWER"]` on every
  claims map they return, which is fine for their own tests (neither depends
  on the claimed role name matching a real, closed-set `Letflow.Api.Authorization.role()`)
  but is unusable for
  `test/letflow/plugs/iss0736_oidc_live_revocation_test.exs`'s REQ-378 §2.2
  one-time-sync coverage: proving `Letflow.Identity.sync_role_claims_from_token/3`
  seeds `group_members` from a JWT's claimed role AND that the resulting role
  actually grants access downstream needs a claim naming a role
  `Letflow.Api.Authorization.role_allows?/2` recognizes (`"VIEWER"` is not one
  of the six — see `lib/letflow/design/req378-oidc-live-revocation-check.md`
  §2.3). This double claims `"PROCESS_OPERATOR"` instead, so a test can bind a
  `tenant_role` row of that same name to a group *before* the user's first
  login and observe the sync actually unlock a `PROCESS_OPERATOR`-gated route.

  Recognizes one fixed sentinel raw token, deliberately distinct from both
  other doubles' `"valid-test-token"` so a stray `Bearer` header from a copied
  helper can never accidentally cross-activate this claims shape under the
  wrong double:

    * `"iss0736-role-claim-token"` → `{:ok, claims}`, realm `bpm-default`
      (matches `Letflow.Support.BpmDefaultRealmDisplacement`'s fixed realm,
      same as both sibling doubles), fixed subject
      `"iss0736-role-claim-subject"` (one subject only — this double is not
      parameterized by token suffix; a test needing more than one identity
      under this claims shape should mint more than one tenant, not rely on
      this double to vary the subject), claiming exactly one role:
      `"PROCESS_OPERATOR"`.
    * any other value → `{:error, :invalid_test_token}`, matching both
      sibling doubles' behavior for the same case.
  """

  @behaviour Letflow.Oidc.TokenVerifier

  @valid_token "iss0736-role-claim-token"

  @valid_claims %{
    "iss" => "https://placeholder-keycloak.invalid/realms/bpm-default",
    "sub" => "iss0736-role-claim-subject",
    "email" => "iss0736-role-claim-subject@example.com",
    "preferred_username" => "iss0736-role-claim-subject",
    "name" => "ISS-0736 Role Claim Test User",
    "realm_access" => %{"roles" => ["PROCESS_OPERATOR"]}
  }

  @impl Letflow.Oidc.TokenVerifier
  def verify_bearer_token(@valid_token), do: {:ok, @valid_claims}
  def verify_bearer_token(_other_token), do: {:error, :invalid_test_token}
end
