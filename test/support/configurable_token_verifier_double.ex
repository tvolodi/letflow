defmodule Letflow.Oidc.ConfigurableTokenVerifierDouble do
  @moduledoc """
  Test-only `Letflow.Oidc.TokenVerifier` implementation, sibling to
  `Letflow.Oidc.TokenVerifierDouble` (which ELIXIR-DEV wrote and which
  `config/test.exs` wires in as the default `:token_verifier` for every other
  test in the suite — this module is deliberately NOT the config-wired
  default, so it does not affect any other test file).

  `Letflow.Oidc.TokenVerifierDouble` only recognizes one fixed sentinel raw
  token (`"valid-test-token"`), mapped to one fixed claims map (realm
  `bpm-default`, subject `test-subject-001`). That is sufficient for AC1's
  happy path and AC2's missing/malformed-header path, but REQ-021's AC4
  ("a request whose token's realm does not match the resolved tenant's bound
  realm is rejected") needs a token whose claimed realm differs from
  whatever `AuthPipeline` resolves a tenant by — `Letflow.Plugs.AuthPipeline`
  resolves the tenant via `Letflow.Identity.resolve_tenant_by_realm/1` using
  the SAME realm string it later re-checks in
  `Letflow.Identity.verify_realm_ownership/2` (§4.4 of the design doc), so
  under real DB state the two can only disagree if a tenant is looked up
  under one realm value while actually bound to a different one — see
  `test/specs/REQ-021.md`'s "AC4 test strategy" section for the full
  reasoning and why this double (rather than mutating global
  `Application.put_env/3` state, unsafe under `async: true`) is the chosen
  mechanism.

  Deliberately **stateless and global-config-free**: every claim this double
  returns is derived directly from the raw token string itself (no
  `Application.put_env/3`, no `Agent`/`GenServer`/process dictionary), so
  concurrently-running `async: true` tests using different token strings
  never interfere with each other the way mutating shared application config
  would.

  Recognized raw-token formats (`raw_token` is never a real JWT — this is a
  test double, free to define its own fixture-token grammar):

    * `"valid-test-token"` — same fixed claims shape as
      `Letflow.Oidc.TokenVerifierDouble`'s sentinel (realm `bpm-default`,
      subject `test-subject-001`), reproduced here so a test using this
      double doesn't also need to import the other one.
    * `"realm-token:" <> realm` — `{:ok, claims}` with `claims["iss"]` set to
      `https://placeholder-keycloak.invalid/realms/<realm>` and a fixed
      subject, letting a test parameterize exactly which realm the token
      claims without touching any global/shared state.
    * `"realm-token:" <> realm <> ":sub=" <> subject` — same as above, with
      an explicit, test-chosen `sub` claim instead of the fixed default (used
      by the JIT-provisioning-under-the-resolved-tenant assertions, so each
      test's provisioned user is independently identifiable).
    * `"no-sub-token:" <> realm` — `{:ok, claims}` with the given realm but
      NO `sub` claim at all, exercising `AuthPipeline`'s
      `map_claims/2` -> `{:error, :sub_claim_missing}` branch.
    * any other value — `{:error, :invalid_test_token}`, matching
      `TokenVerifierDouble`'s behavior for the same case.
  """

  @behaviour Letflow.Oidc.TokenVerifier

  @valid_token "valid-test-token"
  @issuer_prefix "https://placeholder-keycloak.invalid/realms/"

  @impl Letflow.Oidc.TokenVerifier
  def verify_bearer_token(@valid_token, _provider_name) do
    {:ok,
     %{
       "iss" => @issuer_prefix <> "bpm-default",
       "sub" => "test-subject-001",
       "email" => "test-user@example.com",
       "preferred_username" => "test-user",
       "name" => "Test User",
       "realm_access" => %{"roles" => ["VIEWER"]}
     }}
  end

  def verify_bearer_token("no-sub-token:" <> realm, _provider_name) when byte_size(realm) > 0 do
    {:ok,
     %{
       "iss" => @issuer_prefix <> realm,
       "email" => "no-sub@example.com",
       "preferred_username" => "no-sub-user",
       "name" => "No Sub User",
       "realm_access" => %{"roles" => []}
     }}
  end

  def verify_bearer_token("realm-token:" <> rest, _provider_name) do
    case String.split(rest, ":sub=", parts: 2) do
      [realm, subject] when byte_size(realm) > 0 and byte_size(subject) > 0 ->
        {:ok, claims_for(realm, subject)}

      [realm] when byte_size(realm) > 0 ->
        {:ok, claims_for(realm, "realm-token-subject")}

      _other ->
        {:error, :invalid_test_token}
    end
  end

  def verify_bearer_token(_other_token, _provider_name), do: {:error, :invalid_test_token}

  defp claims_for(realm, subject) do
    %{
      "iss" => @issuer_prefix <> realm,
      "sub" => subject,
      "email" => "#{subject}@example.com",
      "preferred_username" => subject,
      "name" => "Test User #{subject}",
      "realm_access" => %{"roles" => ["VIEWER"]}
    }
  end
end
