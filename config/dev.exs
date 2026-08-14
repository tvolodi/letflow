import Config

# Deliberately on port 5462, not 5432 — R-Co's own docker-compose stack
# already uses 5432 (dev) and 5433 (test), so Letflow gets its own
# ports and can run alongside R-Co without colliding. (Previously
# 5434, moved after that port turned out to already be in use.)
config :letflow, Letflow.Repo,
  username: "letflow",
  password: "letflow",
  database: "letflow_dev",
  hostname: "localhost",
  port: 5462,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10
