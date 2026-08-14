defmodule Letflow.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Letflow.Repo,
      {Registry, keys: :unique, name: Letflow.Registry},
      Letflow.InstanceSupervisor,
      Letflow.ApprovalSupervisor,
      {Bandit, plug: Letflow.Router, port: 4000}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Letflow.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
