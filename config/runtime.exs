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

# REQ-193: structured log level. Defaults to :info when LOG_LEVEL is absent.
# Unrecognised values are fatal at startup (mirrors the LETFLOW_SECRETS_MASTER_KEY
# "boot-time failure via raise" pattern).
log_level_atom =
  case System.get_env("LOG_LEVEL", "info") do
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
end
