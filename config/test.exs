import Config

config :letflow, Letflow.Repo,
  username: "letflow",
  password: "letflow",
  database: "letflow_test#{System.get_env("MIX_TEST_PARTITION")}",
  hostname: "localhost",
  port: 5462,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2
