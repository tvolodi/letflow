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

  require Logger

  @type crash_reason ::
          {:verifier_crashed, %{kind: :error | :exit | :throw, classification: module() | atom()}}

  @doc """
  Builds an unauthenticated `Oidcc.ClientContext` from the supervised
  `Oidcc.ProviderConfiguration.Worker` registered under `provider_name`, then
  calls `Oidcc.Token.validate_jwt/3` with the configured `signing_algs`
  allowlist. Every `Oidcc.ClientContext.from_configuration_worker/4` and
  `Oidcc.Token.validate_jwt/3` error collapses to `{:error, reason}`.
  Never raises or exits: a malformed/invalid `raw_token` — including one
  that is not base64url/JWT-shaped at all (e.g. garbage input, or an
  Authorization header value that is not a JWT, such as a caller
  accidentally sending a whole token-endpoint JSON response instead of its
  `access_token` field) — is caught at this function's own boundary and
  returned as `{:error, {:verifier_crashed, %{kind: ..., classification: ...}}}`,
  the same as any other verification failure (unresolvable provider config,
  expired token, bad signature, wrong algorithm).
  """
  @impl Letflow.Oidc.TokenVerifier
  @spec verify_bearer_token(raw_token :: String.t(), provider_name :: atom()) ::
          {:ok, claims :: %{optional(String.t()) => term()}}
          | {:error, term()}
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
  rescue
    exception ->
      classification = exception.__struct__

      Logger.warning(
        "Letflow.Oidc.TokenVerifier.Oidcc crashed verifying a bearer token kind=error classification=#{classification}"
      )

      {:error, {:verifier_crashed, %{kind: :error, classification: classification}}}
  catch
    kind, reason ->
      classification =
        cond do
          is_atom(reason) -> reason
          kind == :exit -> :non_atom_exit_reason
          kind == :throw -> :non_atom_throw_reason
        end

      Logger.warning(
        "Letflow.Oidc.TokenVerifier.Oidcc crashed verifying a bearer token kind=#{kind} classification=#{classification}"
      )

      {:error, {:verifier_crashed, %{kind: kind, classification: classification}}}
  end
end
