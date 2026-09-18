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

  ## REQ-370 — multi-issuer routing (`lib/letflow/design/req370-multi-issuer-oidc-verification.md` §5)

  `provider_name` is no longer caller-supplied. This adapter now:

    1. Peeks the token's *unverified* `iss` claim (`JOSE.JWT.peek_payload/1` —
       already-vendored via `oidcc`'s own transitive `:jose` dependency, no
       signature check performed).
    2. Parses the realm out of that unverified `iss`.
    3. Resolves which provider to trust via
       `Letflow.Oidc.ProviderRegistry.ensure_started/1` — this is the trust
       gate (fresh `tenants` table lookup, never a caller-supplied value).
    4. Verifies the signature against THAT specific provider's JWKS via
       `Oidcc.Token.validate_jwt/3`, which independently re-checks `iss`
       against its own configured issuer — so a routing bug still fails
       closed, not open.

  No new trust is placed in the unverified peek beyond "which JWKS to try."
  """

  @behaviour Letflow.Oidc.TokenVerifier

  require Logger

  alias Letflow.Oidc.ProviderRegistry

  @type crash_reason ::
          {:verifier_crashed, %{kind: :error | :exit | :throw, classification: module() | atom()}}

  @doc """
  Peeks `raw_token`'s unverified `iss` claim to select which realm's
  provider to route to (`Letflow.Oidc.ProviderRegistry.ensure_started/1`,
  the fresh trust gate), then verifies the signature against that specific
  provider's JWKS via `Oidcc.Token.validate_jwt/3` with the configured
  `signing_algs` allowlist.

  Never raises or exits: a malformed/invalid `raw_token` — including one
  that is not base64url/JWT-shaped at all (e.g. garbage input, or an
  Authorization header value that is not a JWT, such as a caller
  accidentally sending a whole token-endpoint JSON response instead of its
  `access_token` field) — is caught at this function's own boundary and
  returned as `{:error, {:verifier_crashed, %{kind: ..., classification: ...}}}`,
  the same as any other verification failure (unresolvable provider config,
  expired token, bad signature, wrong algorithm, untrusted issuer).
  """
  @impl Letflow.Oidc.TokenVerifier
  @spec verify_bearer_token(raw_token :: String.t()) ::
          {:ok, claims :: %{optional(String.t()) => term()}}
          | {:error, Letflow.Oidc.TokenVerifier.verify_error()}
  def verify_bearer_token(raw_token) when is_binary(raw_token) do
    with {:ok, realm} <- peek_realm(raw_token),
         {:ok, provider_ref} <- resolve_provider(realm) do
      verify_signature(raw_token, provider_ref)
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

  # Step 1-2: unverified peek + realm parse. A malformed/missing "iss", or
  # an "iss" with no "/realms/<realm>" suffix, is :malformed_token — distinct
  # from "not JWT-shaped at all", which stays a crash-boundary case (OQ-4,
  # design §5/§8) for consistency with the existing crash-handling policy.
  defp peek_realm(raw_token) do
    %JOSE.JWT{fields: payload} = JOSE.JWT.peek_payload(raw_token)

    case Map.get(payload, "iss") do
      iss when is_binary(iss) ->
        case String.split(iss, "/realms/", parts: 2) do
          [_prefix, realm] when byte_size(realm) > 0 -> {:ok, realm}
          _other -> {:error, :malformed_token}
        end

      _other ->
        {:error, :malformed_token}
    end
  end

  # Step 3: the trust gate. :unknown_realm (no tenant row bound to this
  # realm) becomes the callback contract's dedicated :untrusted_issuer atom.
  # Any other ensure_started/1 error (a genuine JWKS-fetch/discovery failure
  # for a realm that IS trusted) propagates as-is.
  defp resolve_provider(realm) do
    case ProviderRegistry.ensure_started(realm) do
      {:ok, provider_ref} -> {:ok, provider_ref}
      {:error, :unknown_realm} -> {:error, :untrusted_issuer}
      {:error, reason} -> {:error, reason}
    end
  end

  # Step 4: exactly as before this design, except provider_ref is the
  # routed-to via-tuple rather than a static config-read atom.
  #
  # BUGFIX (discovered by TEST-DESIGNER writing REQ-370's AC2/AC3/AC5 tests against a
  # real oidcc-backed provider, not a double -- see test/specs/REQ-370.md "Production
  # defect found and fixed during test design"): `Oidcc.ClientContext.from_configuration_worker/3,4`'s
  # own non-pid clause (`deps/oidcc/src/oidcc_client_context.erl`) resolves ProviderName
  # via plain Erlang `erlang:whereis/1`, which only accepts a registered ATOM name and
  # raises `ArgumentError` for anything else -- including the `{:via, Registry, _}` tuple
  # `Letflow.Oidc.ProviderRegistry.via_name/1` returns. The design doc's §4.2 confirmed
  # only that `{:via, Registry, _}` is accepted by `start_link/1` (true), not that
  # `from_configuration_worker/3,4` can subsequently look such a name back up (false) --
  # every existing test exercised only the test-double `TokenVerifier` implementations,
  # never this real adapter's post-REQ-370 path, so this was never caught until now.
  # `GenServer.whereis/1` (Elixir's own wrapper, NOT the raw Erlang BIF) DOES resolve a
  # `{:via, Registry, _}` name to a pid directly -- resolving to a pid here, once, before
  # calling into `oidcc`'s own API, sidesteps the gap without changing
  # `ProviderRegistry`'s naming/supervision shape (§4.2) at all: `from_configuration_worker/3`'s
  # `is_pid(ProviderName)` clause handles a genuine pid identically regardless of how it
  # was registered.
  defp verify_signature(raw_token, provider_ref) do
    oidc_config = Application.fetch_env!(:letflow, :oidc)
    client_id = Keyword.fetch!(oidc_config, :client_id)
    signing_algs = Keyword.fetch!(oidc_config, :signing_algs)

    with pid when is_pid(pid) <- GenServer.whereis(provider_ref) || {:error, :provider_not_ready},
         {:ok, client_context} <-
           Oidcc.ClientContext.from_configuration_worker(
             pid,
             client_id,
             :unauthenticated
           ),
         {:ok, claims} <-
           Oidcc.Token.validate_jwt(raw_token, client_context, %{signing_algs: signing_algs}) do
      {:ok, claims}
    end
  end
end
