import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.

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
