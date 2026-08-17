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
end
