defmodule Letflow.Oidc.TokenVerifierDouble do
  @moduledoc """
  Test-only `Letflow.Oidc.TokenVerifier` implementation, standing in for
  `Oidcc.Token.validate_jwt/3`'s result. Configured as `config :letflow,
  :oidc`'s `:token_verifier` in `config/test.exs`.

  This project's `:oidc` config points at a `.invalid` placeholder issuer
  (see `config/dev.exs`), and the locally reachable `r-co-keycloak-1`
  container belongs to a sibling repo with no confirmed Letflow-specific
  realm/client — so REQ-021's AC1 ("valid OIDC bearer token, or a test double
  ... if a real Keycloak issuer isn't reachable") is satisfied via this
  double rather than a live IdP call. See
  `lib/letflow/design/req021-auth-plug-pipeline.md` §3.2.

  Recognizes two fixed sentinel raw-token strings so tests (and this design's
  own self-verification) can exercise both the success and failure paths
  without a real JWT:

    * `"valid-test-token"` → `{:ok, claims}`, a fixed claims map shaped like
      a real Keycloak access token for realm `"bpm-default"` (`iss` ends in
      `/realms/bpm-default`, matching `AuthPipeline`'s `iss`-URL-suffix realm
      extraction).
    * any other value → `{:error, :invalid_test_token}`.
  """

  @behaviour Letflow.Oidc.TokenVerifier

  @valid_token "valid-test-token"

  @valid_claims %{
    "iss" => "https://placeholder-keycloak.invalid/realms/bpm-default",
    "sub" => "test-subject-001",
    "email" => "test-user@example.com",
    "preferred_username" => "test-user",
    "name" => "Test User",
    "realm_access" => %{"roles" => ["VIEWER"]}
  }

  @doc """
  Returns `{:ok, claims}` for the fixed sentinel token `"valid-test-token"`,
  `{:error, :invalid_test_token}` for anything else (including malformed or
  empty strings — this double is only ever reached after
  `Letflow.Plugs.AuthPipeline`'s own empty/malformed-header short-circuit, so
  it does not need to special-case those itself).
  """
  @impl Letflow.Oidc.TokenVerifier
  def verify_bearer_token(@valid_token, _provider_name), do: {:ok, @valid_claims}
  def verify_bearer_token(_other_token, _provider_name), do: {:error, :invalid_test_token}
end
