import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.

# REQ-190 (docs/migration/decisions/0016-secrets-storage-backend.md §B,
# lib/letflow/design/req190-secrets-core.md §2): the envelope-encryption
# master key for Letflow.Secrets. Read here (NOT nested inside the
# `if config_env() == :prod do` block below) because 0016 §B requires
# startup to fail in EVERY environment, including CI/test — this repo's
# test setup (config/test.exs / test/test_helper.exs) must inject a real
# (test-only) 64-hex-char value; this block must never be weakened to make
# tests pass.
#
# Validation, in order (0016 §B, exact):
#   1. absent (nil) -> raise
#   2. not exactly 64 lowercase-hex characters -> raise
#   3. Base.decode16(value, case: :lower) must yield exactly 32 bytes
#      (implied by check 2, asserted explicitly per "no speculation")
#   4. the decoded 32 bytes must not be all-zeros or all-0xFF (rejected by
#      literal byte comparison, not the hex string, so it cannot be
#      bypassed by re-encoding) -> raise
#
# No default value of any kind exists anywhere in this file, in
# .env.example, or in any other committed config — absence is always a
# boot-time failure, never a silent fallback.
secrets_master_key_hex = System.get_env("LETFLOW_SECRETS_MASTER_KEY")

secrets_master_key_hex ||
  raise """
  environment variable LETFLOW_SECRETS_MASTER_KEY is missing.
  Required in every environment (including test/CI) -- Letflow.Secrets
  (REQ-190) never falls back to a default master key.
  Generate one with: openssl rand -hex 32
  """

unless byte_size(secrets_master_key_hex) == 64 and
         String.match?(secrets_master_key_hex, ~r/^[0-9a-f]{64}$/) do
  raise """
  environment variable LETFLOW_SECRETS_MASTER_KEY is malformed: it must be
  exactly 64 lowercase hexadecimal characters (32 bytes, hex-encoded).
  Generate one with: openssl rand -hex 32
  """
end

secrets_master_key =
  case Base.decode16(secrets_master_key_hex, case: :lower) do
    {:ok, <<_::binary-size(32)>> = decoded} ->
      decoded

    _ ->
      raise """
      environment variable LETFLOW_SECRETS_MASTER_KEY did not decode to
      exactly 32 bytes despite passing the 64-hex-character format check.
      This should be unreachable -- treat it as a real defect, not a config
      typo, if it fires.
      """
  end

if secrets_master_key == <<0::256>> or secrets_master_key == <<0xFF::256>> do
  raise """
  environment variable LETFLOW_SECRETS_MASTER_KEY is a trivially-guessable
  value (all-zeros or all-0xFF). This is exactly the hardcoded-key failure
  mode docs/migration/decisions/0016-secrets-storage-backend.md exists to
  close off -- generate a real random key with: openssl rand -hex 32
  """
end

config :letflow, :secrets_master_key, secrets_master_key

# REQ-193: structured log level. Defaults to :info when LOG_LEVEL is absent in dev/prod,
# :debug in test (so capture_log([level: :debug]) can capture debug messages -- runtime.exs
# runs after all compile-time config and would otherwise override the default :debug level
# that ExUnit.CaptureLog relies on).
# Unrecognised values are fatal at startup (mirrors the LETFLOW_SECRETS_MASTER_KEY
# "boot-time failure via raise" pattern).
log_level_atom =
  case System.get_env("LOG_LEVEL", if(config_env() == :test, do: "debug", else: "info")) do
    "debug" ->
      :debug

    "info" ->
      :info

    "warn" ->
      :warning

    "warning" ->
      :warning

    "error" ->
      :error

    invalid ->
      raise "Invalid LOG_LEVEL=#{inspect(invalid)}. Must be one of: debug, info, warn, warning, error."
  end

config :logger, level: log_level_atom

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://letflow:PASSWORD@db/letflow_prod
      """

  config :letflow, Letflow.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  # ISS-0015 (GH#71): the port was previously hardcoded in
  # lib/letflow/application.ex, despite config/prod.exs's own comment
  # already stating runtime-dependent values (DB connection, port) belong
  # here. Fixed alongside the port-collision fix for config/test.exs.
  config :letflow, http_port: String.to_integer(System.get_env("PORT") || "4000")

  # REQ-118: allowed CORS origins for the browser-origin SPA. Fail-closed —
  # an unset or empty CORS_ALLOWED_ORIGINS yields [] (no cross-origin caller
  # trusted), never a silent fallback to Letflow.Plugs.Cors's dev/test
  # default (`localhost:5173`/`127.0.0.1:4173`), which would be a security
  # hole in a real deployment. Comma-separated exact origins, e.g.
  # "https://app.example.com,https://staging.example.com".
  config :letflow,
         :cors_allowed_origins,
         (System.get_env("CORS_ALLOWED_ORIGINS") || "") |> String.split(",", trim: true)

  # :oidc keycloak_base_url/client_id: runtime-configurable (not baked into
  # the release image at compile time) so each deployed environment can
  # point at its own Keycloak host without a rebuild —
  # signing_algs/token_verifier stay in config/prod.exs since those don't
  # vary per environment. `Config` merges keys within :oidc across files
  # (config/prod.exs then this file), so this only adds/overrides
  # :keycloak_base_url and :client_id, it doesn't replace the whole keyword
  # list.
  #
  # REQ-370 (design req370-multi-issuer-oidc-verification.md §6):
  # :oidc, :issuer is retired as the trust source -- the tenants table is
  # now the sole source of issuer trust (Letflow.Oidc.ProviderRegistry
  # resolves each realm's own issuer as "#{keycloak_base_url}/realms/#{realm}").
  # OIDC_ISSUER is kept ONLY as a one-deprecation-cycle legacy-derivation
  # fallback for keycloak_base_url, so an already-deployed environment that
  # has only ever set OIDC_ISSUER continues to resolve its bpm-default realm
  # correctly without an immediate operator action. It is never consulted to
  # decide whether a non-default realm is trusted.
  #
  # derive_base_url_from_legacy_issuer/1 below is a small pure helper (a
  # local anonymous function, not a module function -- this file is a plain
  # script, not a module) that strips a trailing "/realms/<anything>" suffix
  # off a full legacy OIDC_ISSUER URL, yielding the shared Keycloak host.
  derive_base_url_from_legacy_issuer = fn
    nil ->
      nil

    issuer when is_binary(issuer) ->
      case Regex.run(~r{\A(.*?)/realms/[^/]+\z}, issuer) do
        [_full, base_url] -> base_url
        nil -> nil
      end
  end

  config :letflow, :oidc,
    keycloak_base_url:
      System.get_env("OIDC_KEYCLOAK_BASE_URL") ||
        derive_base_url_from_legacy_issuer.(System.get_env("OIDC_ISSUER")) ||
        "https://placeholder-keycloak.invalid",
    client_id: System.get_env("OIDC_CLIENT_ID") || "letflow-placeholder-client"
end
