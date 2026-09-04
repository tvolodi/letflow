defmodule Letflow.Supervisor.InfrastructureTest do
  @moduledoc """
  REQ-219 (design `req219-supervision-layering.md` §8) AC1/AC3: confirms
  `Letflow.Application`'s own top-level children list is exactly the 3 new
  supervisor modules (none of the original 20 leaf children remain direct
  children of `Letflow.Supervisor`), and that
  `Letflow.Supervisor.Infrastructure` owns the 17 expected children, in
  order, including the ISS-0224 SandboxPool.TaskSupervisor-before-SandboxPool
  ordering.

  ISS-0451 (design `iss0451-poller-crash-budget-isolation.md` §3.4) added a
  4th top-level child, `Letflow.Supervisor.PollersBreaker`, listed after
  `Letflow.Supervisor.Pollers` and before `Letflow.Supervisor.Http` -- the
  top-level children-count assertion below is updated to match; nothing
  else in this module changes, since `PollersBreaker` does not touch
  `Letflow.Supervisor.Infrastructure`'s own 17-child list or ordering.

  Read-only against the already-running, application-supervised singletons
  -- no restart, no config mutation, safe to run `async: true`.

  `Supervisor.which_children/1` returns children in REVERSE start order
  (OTP's own documented/observed behavior -- each child is prepended to
  the supervisor's internal list as it starts), so every ordering
  assertion below reverses the raw result back to child-spec/startup
  order before comparing.
  """

  use ExUnit.Case, async: true

  test "Letflow.Supervisor has exactly 4 top-level children: Infrastructure, Pollers, PollersBreaker, Http" do
    children = Supervisor.which_children(Letflow.Supervisor)

    ids =
      children
      |> Enum.map(fn {id, _pid, _type, _modules} -> id end)
      |> Enum.reverse()

    assert ids == [
             Letflow.Supervisor.Infrastructure,
             Letflow.Supervisor.Pollers,
             Letflow.Supervisor.PollersBreaker,
             Letflow.Supervisor.Http
           ]

    # AC1: none of the original 20 leaf children remain DIRECT children of
    # Letflow.Supervisor -- they are now two levels down.
    refute Letflow.Repo in ids
    refute Letflow.Registry in ids
    refute Letflow.InstanceSupervisor in ids
    refute Letflow.Scheduler.Poller in ids
  end

  test "Letflow.Supervisor.Infrastructure owns the 17 expected children, in order" do
    children = Supervisor.which_children(Letflow.Supervisor.Infrastructure)

    ids =
      children
      |> Enum.map(fn {id, _pid, _type, _modules} -> id end)
      |> Enum.reverse()

    assert ids == [
             Letflow.Repo,
             Ecto.Migrator,
             Oidcc.ProviderConfiguration.Worker,
             Letflow.Registry,
             Letflow.Metrics.Registry,
             Letflow.Admission,
             Letflow.InstanceSupervisor,
             Letflow.SandboxPool.TaskSupervisor,
             Letflow.SandboxPool,
             Letflow.Engine.PluginTaskSupervisor,
             Letflow.Engine.PluginRegistry,
             Letflow.Engine.Lua.TaskSupervisor,
             Letflow.Engine.Wasm.ModuleRegistryTaskSupervisor,
             Letflow.Engine.Wasm.CapabilityGateTaskSupervisor,
             Letflow.Engine.Wasm.ModuleVersionRegistry,
             Letflow.Engine.Wasm.ModuleVersionRegistryTaskSupervisor,
             Letflow.Obs.Alerts.TaskSupervisor
           ]

    assert length(ids) == 17
  end

  test "ISS-0224: SandboxPool.TaskSupervisor precedes SandboxPool" do
    ids =
      Letflow.Supervisor.Infrastructure
      |> Supervisor.which_children()
      |> Enum.map(fn {id, _pid, _type, _modules} -> id end)
      |> Enum.reverse()

    task_supervisor_index = Enum.find_index(ids, &(&1 == Letflow.SandboxPool.TaskSupervisor))
    sandbox_pool_index = Enum.find_index(ids, &(&1 == Letflow.SandboxPool))

    assert task_supervisor_index < sandbox_pool_index
  end

  test "ISS-0429: Obs.Alerts.TaskSupervisor is the last child of Infrastructure" do
    ids =
      Letflow.Supervisor.Infrastructure
      |> Supervisor.which_children()
      |> Enum.map(fn {id, _pid, _type, _modules} -> id end)
      |> Enum.reverse()

    assert List.last(ids) == Letflow.Obs.Alerts.TaskSupervisor
  end
end
