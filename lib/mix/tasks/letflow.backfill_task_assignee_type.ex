defmodule Mix.Tasks.Letflow.BackfillTaskAssigneeType do
  @shortdoc "Repairs tasks.assignee_type for pre-ISS-0905 role-assigned task rows"

  @moduledoc """
  Repairs `tasks.assignee_type` for every row created before the ISS-0905
  fix landed (`Letflow.Engine.TaskActivation.resolve_assignee/1`) — every
  role-attributed `:HUMAN_TASK` node ever activated by this codebase
  persisted `assignee_type: nil` alongside a non-nil `assignee_ref` (the
  role name), making the task invisible to its role's members in
  `GET /tasks/inbox` and claimable by any authenticated `TASK_WORKER`
  regardless of role membership (`docs/issues/ISS-0905.yaml`). The code
  fix stops this for every task activated from here on; it has no route
  to repair rows already committed with the broken shape in any
  pre-existing environment. This task closes that gap, once, for every
  such row across every tenant.

  ## Usage

      mix letflow.backfill_task_assignee_type

  No arguments. Targets whatever `MIX_ENV`/`Letflow.Repo` config is
  active — no `LETFLOW_DEV_DB_CONFIRMED` guard, same precedent as
  `mix letflow.backfill_platform_roles`/`mix letflow.backfill_event_type_versions`,
  since this task is explicitly meant to be run against QA/staging, not
  only a dev box.

  Idempotent — safe to re-run against a database where some or all
  tenants have already been repaired; re-running converges (finds zero
  matching rows) rather than erroring or double-writing
  (`Letflow.Engine.TaskAssigneeTypeBackfill`'s own moduledoc).

  Exits non-zero if any tenant fails to backfill.
  """

  use Mix.Task

  alias Letflow.Engine.TaskAssigneeTypeBackfill

  @impl Mix.Task
  @spec run(argv :: [String.t()]) :: :ok
  def run(_args) do
    Mix.Task.run("app.start")

    case TaskAssigneeTypeBackfill.run() do
      {:ok, %{repaired: repaired, unchanged: unchanged}} ->
        total_repaired = Enum.reduce(repaired, 0, fn {_tenant_id, count}, acc -> acc + count end)

        Mix.shell().info(
          "ISS-0905 task-assignee_type backfill complete: #{total_repaired} task(s) repaired " <>
            "across #{length(repaired)} tenant(s), #{length(unchanged)} tenant(s) already correct (unchanged)"
        )

        if repaired != [] do
          Mix.shell().info(
            "Repaired tenants: " <>
              Enum.map_join(repaired, ", ", fn {tenant_id, count} -> "#{tenant_id} (#{count})" end)
          )
        end

        :ok

      {:error, {:backfill_failed, tenant_id, reason}} ->
        Mix.shell().error(
          "ISS-0905 task-assignee_type backfill failed for tenant #{tenant_id}: #{inspect(reason)}"
        )

        System.halt(1)
    end
  end
end
