defmodule Letflow.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # REQ-190 (design req190-secrets-core.md §6.2): redacts every log
    # event's metadata map via Letflow.Secrets.Redaction.redact_map/1
    # before it reaches any handler. Registered first, ahead of every
    # other child, so nothing below this line can log an unredacted
    # secret-shaped value before the filter is active. Idempotent-safe:
    # :logger.add_primary_filter/2 raises on a duplicate filter id, which
    # would only happen on a second Letflow.Application.start/2 call in
    # the same node -- not expected in normal operation (a release/test run
    # starts the application exactly once per node).
    :logger.add_primary_filter(
      :letflow_secrets_redaction,
      {&Letflow.Secrets.LogFilter.filter/2, %{}}
    )

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
        # REQ-194 (design req194-prometheus-metrics.md §5): the ETS-backed metrics
        # collector behind GET /metrics. A leaf, independently-startable component
        # with no startup-order dependents (nothing needs to look it up during its
        # own init/1) -- placed directly after the generic Elixir Registry above,
        # mirroring the Wasm.ModuleVersionRegistry placement precedent below ("order
        # between these two is not load-bearing").
        Letflow.Metrics.Registry,
        # REQ-216 (design req216-admission-control-core.md §4): the global +
        # per-tenant admission-control counting semaphore. NO ordering
        # dependency in either direction -- see Letflow.Admission's own
        # moduledoc ("Supervision-tree placement") for the full reasoning.
        # Placed here as a readability choice, grouped with the other
        # leaf/independently-startable infrastructure children (Registry,
        # Letflow.Metrics.Registry) above, not a correctness requirement.
        {Letflow.Admission, []},
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
        {Letflow.Engine.Wasm.ModuleVersionRegistry,
         name: Letflow.Engine.Wasm.ModuleVersionRegistry},
        {Task.Supervisor, name: Letflow.Engine.Wasm.ModuleVersionRegistryTaskSupervisor},
        # ISS-0429 (design lib/letflow/design/iss0429-async-alert-hook-delivery.md §1):
        # dedicated Task.Supervisor isolating alert-hook delivery's HTTP POST +
        # retry/backoff loop (Letflow.Obs.Alerts.deliver_with_retry/4, dispatched from
        # fire_hooks/4) off Letflow.Scheduler.Poller's own process. Deliberately its own
        # supervisor, not a reuse of any of the six above: alert-hook delivery is
        # I/O-bound HTTP dispatch to tenant-operator-configured external endpoints, an
        # independent concern from sandbox provisioning, plugin/Lua/Wasm execution --
        # mirroring Wasm.ModuleRegistryTaskSupervisor's own "independent concern"
        # reasoning above. MUST precede `scheduler_children()` below: the Poller's
        # own first :tick runs with ZERO delay (`Process.send_after(self(), :tick, 0)`
        # in poller.ex's init/1) and, from that very first tick, can dispatch to this
        # supervisor via fire_hooks/4 -- if this supervisor were registered after
        # scheduler_children(), that first tick could reach
        # Task.Supervisor.start_child/2 before this name is registered, the same
        # ordering hazard SandboxPool.TaskSupervisor's own comment above documents for
        # its analogous case. No ordering dependency relative to the six
        # Task.Supervisors above (unlike the SandboxPool/SandboxPool.TaskSupervisor
        # pair), matching ModuleVersionRegistry/ModuleVersionRegistryTaskSupervisor's
        # own "order between these two is not load-bearing" note.
        {Task.Supervisor, name: Letflow.Obs.Alerts.TaskSupervisor}
      ] ++ scheduler_children() ++ http_child()

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
  # REQ-186 (design req186-scheduler-core.md §3.3): the scheduler's supervised
  # GenServer ticker. Gated the same way http_child/0 gates Bandit below
  # (ISS-0015's own precedent) -- config/test.exs sets start_scheduler: false,
  # a deliberate, flagged addition beyond what the design doc itself specifies:
  # the Poller's own first tick runs with ZERO delay and queries
  # Letflow.Repo from a process no test process is an ancestor of, which
  # under Ecto.Adapters.SQL.Sandbox's default :manual mode raises
  # DBConnection.OwnershipError on every tick, repeatedly, until this
  # supervisor's restart intensity is exceeded and the whole application
  # (including Letflow.Repo) shuts down -- verified live via a full `mix
  # test` run before this gate was added. No acceptance criterion requires
  # the Poller to run automatically inside the test suite; Letflow.Scheduler's
  # own tests call `poll_and_fire/1` directly, and any test of the Poller
  # GenServer itself starts its own instance explicitly (mirroring
  # http_child/0's own "exercised directly, not through the supervised
  # child" precedent for Bandit/Plug.Test). No ordering dependency on any
  # Task.Supervisor above (unlike SandboxPool's own ordering constraint).
  # No new Task.Supervisor -- design §0's opening decision (transaction/
  # rescue boundary only).
  defp scheduler_children do
    if Application.get_env(:letflow, :start_scheduler, true) do
      [{Letflow.Scheduler.Poller, []}]
    else
      []
    end
  end

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
