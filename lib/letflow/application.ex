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
           backoff_type: :random,
           # REQ-128: dev/test's local Keycloak serves discovery over plain
           # HTTP (docker-compose.yml's keycloak service, no TLS termination
           # in front of it). oidcc's discovery parser otherwise rejects a
           # non-https userinfo_endpoint outright
           # (oidcc_provider_configuration.erl's AllowUnsafeHttp quirk,
           # default false) and the worker never reaches a ready state.
           # Opt-in only, off by default: config/dev.exs and config/test.exs
           # set :allow_unsafe_http true; config/prod.exs does not set it at
           # all, so a real deployed issuer is still held to the safe
           # default.
           provider_configuration_opts: %{
             quirks: %{allow_unsafe_http: Keyword.get(oidc_config, :allow_unsafe_http, false)}
           }
         }},
        {Registry, keys: :unique, name: Letflow.Registry},
        Letflow.InstanceSupervisor,
        # ISS-0224: every SandboxPool DB operation runs under this supervisor via
        # Task.Supervisor.async_nolink/3. It MUST precede {Letflow.SandboxPool, []} --
        # Supervisor starts children in list order, so registering it after its
        # dependant would leave a window in which a claim/2 makes async_nolink exit
        # :noproc inside a pool callback and kill the pool.
        {Task.Supervisor, name: Letflow.SandboxPool.TaskSupervisor},
        {Letflow.SandboxPool, []},
        {Task.Supervisor, name: Letflow.Engine.PluginTaskSupervisor},
        {Letflow.Engine.PluginRegistry, plugin_registrations_from_config()},
        # REQ-155: dedicated Task.Supervisor for host-enforced wall-clock kill of Lua
        # script execution (LUA-10 layer 2). Deliberately separate from
        # PluginTaskSupervisor above -- see Letflow.Engine.Lua.Executor's moduledoc
        # for why sharing it would conflate two independently-reasoned-about
        # subsystems. No other child depends on start order here.
        {Task.Supervisor, name: Letflow.Engine.Lua.TaskSupervisor},
        # REQ-166: dedicated Task.Supervisor for ModuleRegistry.register/1's
        # stage-2 real instantiation attempt (design
        # req166-wasm-module-abi-validation.md §2.2/§1.5) -- an unresolved-import
        # crash inside Wasmex.start_link/1 delivers a linked :EXIT signal to a
        # non-trapping caller, so it must run inside a Task.Supervisor-owned
        # async_nolink/2 task, never inline. Deliberately its own supervisor, not
        # a reuse of PluginTaskSupervisor or Lua.TaskSupervisor -- module
        # registration (once per upload, off any workflow-execution hot path) is
        # an independent concern from both, per §2.2's reasoning (mirroring
        # req155-lua-wallclock-kill.md §4.4's own precedent). No other child
        # depends on start order here.
        {Task.Supervisor, name: Letflow.Engine.Wasm.ModuleRegistryTaskSupervisor},
        # REQ-167: dedicated Task.Supervisor for CapabilityGate.start_instance/2's
        # real, manifest-gated instantiation attempt (design
        # req167-wasm-import-whitelist.md §0/§2.2's identical reasoning) -- the
        # same unresolved-import crash-propagation hazard ModuleRegistryTaskSupervisor
        # exists for, but deliberately its own supervisor rather than a reuse of
        # ModuleRegistryTaskSupervisor: module registration (REQ-166) and
        # capability-gated instantiation (REQ-167) are orthogonal concerns with
        # different inputs and different callers, per req166 §2.2's own precedent.
        # No other child depends on start order here.
        {Task.Supervisor, name: Letflow.Engine.Wasm.CapabilityGateTaskSupervisor},
        # REQ-173: the hot-reload version registry (design
        # req173-wasm-module-hot-reload.md §7) and its dedicated
        # Task.Supervisor, for invoke/4's own outer async_nolink task plus
        # the nested instantiation-attempt task it spawns internally.
        # Registration order between these two specific children is not
        # load-bearing (unlike the SandboxPool/SandboxPool.TaskSupervisor
        # pair above) -- see the design doc §7's own note.
        {Letflow.Engine.Wasm.ModuleVersionRegistry, name: Letflow.Engine.Wasm.ModuleVersionRegistry},
        {Task.Supervisor, name: Letflow.Engine.Wasm.ModuleVersionRegistryTaskSupervisor}
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
