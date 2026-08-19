defmodule Letflow.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    oidc_config = Application.fetch_env!(:letflow, :oidc)

    children =
      [
        Letflow.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:letflow, :ecto_repos), skip: skip_migrations?()},
        {Oidcc.ProviderConfiguration.Worker,
         %{
           issuer: Keyword.fetch!(oidc_config, :issuer),
           name: Keyword.fetch!(oidc_config, :provider_name),
           backoff_type: :random
         }},
        {Registry, keys: :unique, name: Letflow.Registry},
        Letflow.InstanceSupervisor,
        {Letflow.SandboxPool, []},
        {Task.Supervisor, name: Letflow.Engine.PluginTaskSupervisor},
        {Letflow.Engine.PluginRegistry, plugin_registrations_from_config()}
      ] ++ http_child()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Letflow.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # ISS-0015 (GH#71): the port was previously a hardcoded literal here, not
  # partitioned by MIX_TEST_PARTITION the way config/test.exs's database name
  # is -- two concurrent `mix test` runs (the project's two-worktree setup)
  # both tried to bind the same TCP port. Fixed by not starting Bandit at all
  # under test (config/test.exs sets start_http: false) -- no test drives the
  # router over a real socket, it's exercised via Plug.Test conns, so this
  # sidesteps the collision entirely rather than just relocating it, and
  # shaves the listener's startup cost off every test run. dev/prod keep
  # start_http: true (default) with the port read from config
  # (config/dev.exs compile-time 4000; config/runtime.exs's PORT env var for
  # prod, matching config/prod.exs's own comment that runtime-dependent
  # values belong there).
  defp http_child do
    if Application.get_env(:letflow, :start_http, true) do
      [{Bandit, plug: Letflow.Router, port: Application.fetch_env!(:letflow, :http_port)}]
    else
      []
    end
  end

  # REQ-057 §4.4/§6.4 — the seed list `Letflow.Engine.PluginRegistry.start_link/1`
  # registers at boot, then freezes automatically. Ordinary config/*.exs (or
  # runtime.exs) data, matching this module's own oidc_config/start_http
  # convention above -- empty by default since no plugin handler module ships
  # yet.
  defp plugin_registrations_from_config do
    Application.get_env(:letflow, :plugin_handlers, [])
  end

  # Migrations run automatically on boot, but only inside a compiled
  # release (deploy/Dockerfile's `bin/letflow start`) — `mix ecto.migrate`
  # already covers local dev/test via README's `mix ecto.setup` /
  # the `test` alias in mix.exs, and RELEASE_NAME is unset in both.
  defp skip_migrations?, do: System.get_env("RELEASE_NAME") == nil
end
