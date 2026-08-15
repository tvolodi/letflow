defmodule Letflow.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    oidc_config = Application.fetch_env!(:letflow, :oidc)

    children = [
      Letflow.Repo,
      {Oidcc.ProviderConfiguration.Worker,
       %{
         issuer: Keyword.fetch!(oidc_config, :issuer),
         name: Keyword.fetch!(oidc_config, :provider_name),
         backoff_type: :random
       }},
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
