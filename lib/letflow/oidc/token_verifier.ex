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

  ## REQ-370 — multi-issuer verification (arity 2 → 1)

  `provider_name` is no longer a caller-supplied argument. Under multi-issuer
  verification (`lib/letflow/design/req370-multi-issuer-oidc-verification.md`
  §3), *which* provider to verify a token against is something only the
  verifier itself can determine — by peeking the token's own claimed issuer
  and resolving it against the `tenants` table (the sole source of issuer
  trust, see `Letflow.Oidc.ProviderRegistry`) — so it can no longer be passed
  in by `Letflow.Plugs.AuthPipeline`.
  """

  @typedoc "Verified claims map returned on successful verification."
  @type claims :: %{optional(String.t()) => term()}

  @typedoc """
  Error union returned by `verify_bearer_token/1`. `:untrusted_issuer` is new
  under REQ-370 — the claimed realm resolved to no tenant row (or no longer
  resolves to one). It is deliberately collapsed by
  `Letflow.Plugs.AuthPipeline.handle_auth_error/2`'s existing generic-401
  catch-all, identically to every other verify failure — no new
  HTTP-distinguishable oracle is introduced.
  """
  @type verify_error ::
          :malformed_token
          | :untrusted_issuer
          | {:verifier_crashed,
             %{kind: :error | :exit | :throw, classification: module() | atom()}}
          | term()

  @doc """
  Verifies `raw_token`, resolving which OIDC provider to trust from the
  token's own (unverified) claimed issuer against the `tenants` table —
  never a caller-supplied provider. Returns the verified claims map on
  success.
  """
  @callback verify_bearer_token(raw_token :: String.t()) ::
              {:ok, claims()} | {:error, verify_error()}
end
