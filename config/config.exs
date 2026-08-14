import Config

config :letflow, ecto_repos: [Letflow.Repo]

import_config "#{config_env()}.exs"
