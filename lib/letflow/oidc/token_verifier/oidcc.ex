defmodule Letflow.Oidc.TokenVerifier.Oidcc do
  @moduledoc """
  Real `Letflow.Oidc.TokenVerifier` implementation, backed directly by
  `Oidcc.Token.validate_jwt/3` — not `Ueberauth.Strategy.Oidcc` (that module
  only implements the browser-redirect authorization-code flow; there is no
  request-scoped "verify this already-issued bearer token" entry point in it).
  `Oidcc.Token.validate_jwt/3` is `oidcc`'s own documented answer to exactly
  this use case (its own doc comment: "Get Jwt from Authorization header").

  Builds an unauthenticated `Oidcc.ClientContext` (`client_secret:
  :unauthenticated`) — this plug is a resource server that only verifies
  tokens, it never performs a token exchange, so no client secret is needed
  or held. `client_id` is read from `config :letflow, :oidc`.

  See `lib/letflow/design/req021-auth-plug-pipeline.md` §3.1.
  """

  @behaviour Letflow.Oidc.TokenVerifier

  @doc """
  Builds an unauthenticated `Oidcc.ClientContext` from the supervised
  `Oidcc.ProviderConfiguration.Worker` registered under `provider_name`, then
  calls `Oidcc.Token.validate_jwt/3` with the configured `signing_algs`
  allowlist. Every `Oidcc.ClientContext.from_configuration_worker/4` and
  `Oidcc.Token.validate_jwt/3` error collapses to `{:error, reason}` — never
  raises on a realistic failure path (unresolvable provider config, expired
  token, bad signature, wrong algorithm).
  """
  @impl Letflow.Oidc.TokenVerifier
  def verify_bearer_token(raw_token, provider_name) when is_binary(raw_token) do
    oidc_config = Application.fetch_env!(:letflow, :oidc)
    client_id = Keyword.fetch!(oidc_config, :client_id)
    signing_algs = Keyword.fetch!(oidc_config, :signing_algs)

    with {:ok, client_context} <-
           Oidcc.ClientContext.from_configuration_worker(
             provider_name,
             client_id,
             :unauthenticated
           ),
         {:ok, claims} <-
           Oidcc.Token.validate_jwt(raw_token, client_context, %{signing_algs: signing_algs}) do
      {:ok, claims}
    end
  end
end
