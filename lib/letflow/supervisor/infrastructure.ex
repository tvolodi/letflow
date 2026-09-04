defmodule Letflow.Supervisor.Infrastructure do
  @moduledoc """
  REQ-219 (design `req219-supervision-layering.md` §1.1): owns the 17
  infrastructure children that used to be the first 17 entries of
  `Letflow.Application`'s own flat 20-child list, in EXACTLY the same
  relative order, under `strategy: :one_for_one` with the OTP default
  restart intensity (3 restarts/5 seconds) -- unchanged, since no
  documented incident motivates loosening it here: a crash-looping infra
  child (e.g. `Letflow.Repo` itself) indicates a fault severe enough that
  taking the whole application down is still the correct behavior.

  ## Children, in order

  1. `Letflow.Repo`
  2. `Ecto.Migrator`
  3. `Oidcc.ProviderConfiguration.Worker`
  4. `Letflow.Registry` (generic `Registry`)
  5. `Letflow.Metrics.Registry`
  6. `Letflow.Admission`
  7. `Letflow.InstanceSupervisor`
  8. `Letflow.SandboxPool.TaskSupervisor`
  9. `Letflow.SandboxPool`
  10. `Letflow.Engine.PluginTaskSupervisor`
  11. `Letflow.Engine.PluginRegistry`
  12. `Letflow.Engine.Lua.TaskSupervisor`
  13. `Letflow.Engine.Wasm.ModuleRegistryTaskSupervisor`
  14. `Letflow.Engine.Wasm.CapabilityGateTaskSupervisor`
  15. `Letflow.Engine.Wasm.ModuleVersionRegistry`
  16. `Letflow.Engine.Wasm.ModuleVersionRegistryTaskSupervisor`
  17. `Letflow.Obs.Alerts.TaskSupervisor`

  ## Ordering guarantees preserved (both load-bearing, unchanged from
  `Letflow.Application`'s own prior flat list)

    * ISS-0224: child 8 (`SandboxPool.TaskSupervisor`) precedes child 9
      (`{Letflow.SandboxPool, []}`) -- unchanged relative order. Every
      `SandboxPool` DB operation runs under this `Task.Supervisor` via
      `Task.Supervisor.async_nolink/3`; registering it after its dependant
      would leave a window in which a `claim/2` call exits `:noproc` inside
      a pool callback and kills the pool.
    * ISS-0429: child 17 (`Obs.Alerts.TaskSupervisor`) is the LAST child of
      this supervisor. Its "must precede either Poller's first tick"
      guarantee is now a SUPERVISOR-BOUNDARY guarantee, not merely a
      list-position fact: `Letflow.Supervisor.Pollers` is started only
      after this entire module's own `Supervisor.start_link/3` call (from
      `Letflow.Application.start/2`) has returned `{:ok, pid}`, which
      happens only once every one of these 17 children -- including this
      last one -- has itself finished starting. No interleaving is
      possible between this supervisor's last child starting and
      `Letflow.Supervisor.Pollers`' first child starting, since an entire
      supervisor boundary sits between them.

  ## `Letflow.InstanceSupervisor` placement

  Matches its CURRENT behavior only (an empty `DynamicSupervisor`,
  REQ-045/ISS-0422 unaffected) -- this is not a claim about which layer it
  belongs in once (if ever) a future requirement gives it real children;
  left explicitly open (design doc §7/§9 Q3).

  ## Task.Supervisor sprawl review (REQ-220, closes ISS-0425 part 3)

  This supervisor owns 7 separate `Task.Supervisor`s. RECOMMENDATION: KEEP
  ALL 7 SEPARATE. None share a crash domain or a resource-contention
  profile that would make consolidation meaningfully safer or cheaper, and
  each pairing a reader might plausibly propose merging already has a
  stated, on-record reason not to (see below). Consolidated here so a
  reader does not need to hunt 7 separate scattered comments to see why
  none should merge; each one's own comment at its child-spec site above
  remains the source of truth for its individual justification.

    * `SandboxPool.TaskSupervisor` (ISS-0224) -- isolates `SandboxPool`'s
      own Ecto-sandbox-ownership `async_nolink` calls so a `claim/2`
      failure cannot exit the pool.
    * `Engine.PluginTaskSupervisor` (REQ-057) -- generic plugin-handler
      execution.
    * `Engine.Lua.TaskSupervisor` (REQ-155) -- wall-clock kill isolation
      for LUA-10 layer 2, deliberately NOT sharing `PluginTaskSupervisor`:
      a killed Lua task must not risk a concurrently running plugin task.
    * `Engine.Wasm.ModuleRegistryTaskSupervisor` (REQ-166) -- crash-isolates
      `Wasmex.start_link/1`'s unresolved-import EXIT signal during module
      registration, an upload-time-only path.
    * `Engine.Wasm.CapabilityGateTaskSupervisor` (REQ-167) -- the same
      crash-isolation need, but for capability-gated instantiation, an
      orthogonal caller/input from `ModuleRegistry` per REQ-166 design
      §2.2 -- deliberately not reusing it.
    * `Engine.Wasm.ModuleVersionRegistryTaskSupervisor` (REQ-173) -- the
      hot-reload `invoke/4` path's own outer `async_nolink` task plus its
      nested instantiation-attempt task.
    * `Obs.Alerts.TaskSupervisor` (ISS-0429) -- I/O-bound HTTP alert-hook
      delivery, unrelated to any sandbox/plugin/Lua/Wasm concern above.

  TWO CONSOLIDATION CANDIDATES CONSIDERED AND REJECTED:

    * The three Wasm `Task.Supervisor`s into one shared Wasm
      `Task.Supervisor` -- rejected. Per REQ-166 design §2.2, module
      registration, capability-gated instantiation, and hot-reload
      invocation are three genuinely orthogonal call paths, each
      independently crash-isolated on purpose: sharing one supervisor
      would mean a crash-isolated task from one path could exhaust or
      contend with tasks from an unrelated path, reintroducing the
      cross-path blast radius each was split out to avoid.
    * `Engine.PluginTaskSupervisor` and `Engine.Lua.TaskSupervisor` into
      one shared Engine `Task.Supervisor` -- rejected. REQ-155's own
      wall-clock-kill mechanism must not risk a concurrently running
      plugin task's blast radius; sharing a supervisor would couple Lua's
      kill isolation to Plugin's execution, the exact coupling REQ-155
      split them apart to prevent.

  NOT IN THIS REQUIREMENT: no Task.Supervisor removed, renamed, or merged
  as a side effect of this review -- see this section's own recommendation
  (KEEP ALL 7). All 7 remain inside this module, matching REQ-219's own
  layer assignment.
  """

  use Supervisor

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    oidc_config = Application.fetch_env!(:letflow, :oidc)

    children = [
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
      # reasoning above. MUST be the LAST child of this supervisor: the Poller's own
      # first :tick runs with ZERO delay (`Process.send_after(self(), :tick, 0)` in
      # poller.ex's init/1) and, from that very first tick, can dispatch to this
      # supervisor via fire_hooks/4 -- since Letflow.Supervisor.Pollers only starts
      # after this ENTIRE supervisor (all 17 children) has finished starting, this
      # name is guaranteed registered before any Poller's first tick can run,
      # matching the ISS-0429 guarantee restated in this module's own moduledoc.
      {Task.Supervisor, name: Letflow.Obs.Alerts.TaskSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # REQ-057 §4.4/§6.4 — the seed list `Letflow.Engine.PluginRegistry.start_link/1`
  # registers at boot, then freezes automatically. Ordinary config/*.exs (or
  # runtime.exs) data -- empty by default since no plugin handler module ships yet.
  defp plugin_registrations_from_config do
    Application.get_env(:letflow, :plugin_handlers, [])
  end

  # Migrations run automatically on boot, but only inside a compiled
  # release (deploy/Dockerfile's `bin/letflow start`) — `mix ecto.migrate`
  # already covers local dev/test via README's `mix ecto.setup` /
  # the `test` alias in mix.exs, and RELEASE_NAME is unset in both.
  defp skip_migrations?, do: System.get_env("RELEASE_NAME") == nil
end
