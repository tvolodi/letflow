defmodule Letflow.Oidc.TokenVerifier do
  @moduledoc """
  Behaviour for verifying an already-issued OIDC bearer token presented on an
  incoming API request. `Letflow.Plugs.AuthPipeline` calls the configured
  implementation (`Application.get_env(:letflow, :oidc)[:token_verifier]`)
  through this one indirection point, rather than calling
  `Oidcc.Token.validate_jwt/3` directly or branching on `Mix.env()` inline.

  Two implementations exist:

    * `Letflow.Oidc.TokenVerifier.Oidcc` — the real adapter, backed by
      `Oidcc.Token.validate_jwt/3` (configured in `config/dev.exs`/
      `config/prod.exs`).
    * a test-only double, configured in `config/test.exs`, standing in for a
      real Keycloak-issued token when no realm/client is provisioned against a
      reachable issuer in this environment.

  See `lib/letflow/design/req021-auth-plug-pipeline.md` §3.2 for the full
  reasoning behind this seam.
  """

  @doc """
  Verifies `raw_token` against the OIDC provider registered under
  `provider_name` (the same atom `Letflow.Application` passed to
  `Oidcc.ProviderConfiguration.Worker` at startup). Returns the verified
  claims map on success.
  """
  @callback verify_bearer_token(raw_token :: String.t(), provider_name :: atom()) ::
              {:ok, claims :: %{optional(String.t()) => term()}} | {:error, term()}
end
