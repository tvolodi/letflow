defmodule Letflow.Repo do
  use Ecto.Repo,
    otp_app: :letflow,
    adapter: Ecto.Adapters.Postgres
end
