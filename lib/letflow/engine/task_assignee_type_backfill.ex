defmodule Letflow.Engine.TaskAssigneeTypeBackfill do
  @moduledoc """
  ISS-0905: one-time-per-tenant remediation for `tasks` rows created before
  the `resolve_assignee/1` fix landed (`Letflow.Engine.TaskActivation`,
  `lib/letflow/design/iss0905-role-assignee-type-not-derived.md` §3) —
  every role-attributed `:HUMAN_TASK` node ever activated by this codebase
  persisted `assignee_type: nil` alongside a non-nil `assignee_ref` (the
  role name), making the task invisible to its role's members in
  `GET /tasks/inbox` and claimable by any authenticated `TASK_WORKER`
  regardless of role membership. The code fix stops the bug for every task
  activated from here on; it does not repair rows already committed with
  the broken shape in any pre-existing environment (design §3).

  ## Target-row criterion (design §3.1)

  Every `tasks` row where `assignee_type IS NULL AND assignee_ref IS NOT
  NULL`. This predicate exactly and only selects rows created by the
  pre-fix bug: `assignee_ref` is only ever populated from
  `attributes["role"]`, which REQ-029's PD-05 CHK-09 guarantees non-blank
  on every `:HUMAN_TASK` node, and `resolve_assignee/1`'s call inside
  `insert_attrs/4` is the only place a task's assignee fields are ever set
  at creation — no code path ever builds a task row with a non-nil
  `assignee_ref` and a nil `assignee_type` except this bug. No status
  filter is applied (covers `pending`, `completed`, `cancelled` rows
  alike) — a completed/cancelled row with this broken shape is still
  incorrect historical data, and the fix is a pure data correction with
  no behavioral side effect on a non-`pending` row.

  `run/0` iterates every tenant schema via
  `Letflow.TenantProvisioning.list_registrations/0` (the same registry
  `Letflow.Identity.RoleBackfill.run/0` and
  `Letflow.TenantProvisioning.replay_all_pending/0` both sweep). Sequential
  `Enum.reduce_while/3`, deliberately NOT `Task.async_stream/3` — REQ-045's
  "row-lock arbitration over per-unit concurrent processes" decision, the
  same rationale `Letflow.Identity.RoleBackfill`'s own moduledoc cites for
  the identical shape.

  One `Repo.update_all/3` per tenant (single SQL statement, already
  atomic — no `Ecto.Multi`/per-row transaction needed, matching
  `TaskActivation.cancel_pending_timers/5`'s own single-statement,
  status-guarded `update_all/3` idiom, reused directly rather than
  inventing a new update shape). A tenant whose schema vanished mid-sweep
  (the same ISS-0343-shaped race `replay_all_pending/0` defends against)
  is caught via `try/rescue`, mirroring `Letflow.Identity.RoleBackfill`'s
  own identical deviation-from-design-doc precedent (its moduledoc's
  "Deviation from the design doc" section) — `Repo.update_all/3` does not
  itself guard against a genuinely-missing tenant schema.

  A hard failure on one tenant halts the sweep immediately
  (`{:error, {:backfill_failed, tenant_id, reason}}`) — no rollback of
  tenants already repaired before the halt (matches `RoleBackfill`'s own
  precedent); a retried `run/0` call converges the remaining tenants,
  since a second run against an already-repaired tenant finds zero
  matching rows and reports it `:unchanged` (this backfill is naturally
  idempotent, no separate idempotency mechanism needed — INV-ISS0905-3).

  No audit-trail entry: this backfill is a one-time correction of a column
  that should always have held this value, not a new business event —
  same precedent `Letflow.Identity.RoleBackfill` sets for its own
  `groups`/`tenant_role` writes (design §3.2, flagged there as
  OQ-ISS0905-1 for CODE-DESIGN-VALIDATOR/SECURITY-REVIEWER).

  Writes only `tasks.assignee_type`, never `assignee_ref`/`status`/any
  other column, and only ever on a row that already satisfies
  `is_nil(assignee_type) and not is_nil(assignee_ref)` (INV-ISS0905-3).
  """

  import Ecto.Query

  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @doc """
  Sweeps every tenant registered in
  `Letflow.TenantProvisioning.list_registrations/0`, repairing every
  `tasks` row matching this design's target-row criterion (§3.1 above).

  Returns `{:ok, %{repaired: [{tenant_id, task_count}], unchanged:
  [tenant_id]}}` on success (both lists in `list_registrations/0`'s own
  order), or the halted `{:error, {:backfill_failed, tenant_id, reason}}`
  from the first tenant whose repair attempt failed.
  """
  @spec run() ::
          {:ok,
           %{
             repaired: [{tenant_id :: Ecto.UUID.t(), task_count :: non_neg_integer()}],
             unchanged: [tenant_id :: Ecto.UUID.t()]
           }}
          | {:error, {:backfill_failed, tenant_id :: Ecto.UUID.t(), reason :: term()}}
  def run do
    TenantProvisioning.list_registrations()
    |> Enum.reduce_while({:ok, %{repaired: [], unchanged: []}}, fn registration, {:ok, acc} ->
      process_registration(registration, acc)
    end)
    |> finalize()
  end

  @spec process_registration(Registration.t(), %{
          repaired: [{Ecto.UUID.t(), non_neg_integer()}],
          unchanged: [Ecto.UUID.t()]
        }) ::
          {:cont, {:ok, map()}} | {:halt, {:error, {:backfill_failed, Ecto.UUID.t(), term()}}}
  defp process_registration(%Registration{tenant_id: tenant_id, schema_name: schema_name}, acc) do
    {count, _updated} =
      EngineTask
      |> where([t], is_nil(t.assignee_type) and not is_nil(t.assignee_ref))
      |> Repo.update_all([set: [assignee_type: "ROLE"]], prefix: schema_name)

    {:cont, {:ok, classify(acc, tenant_id, count)}}
  rescue
    # See this module's moduledoc -- mirrors
    # Letflow.Identity.RoleBackfill's identical try/rescue for the same
    # "tenant schema vanished mid-sweep" case, which Repo.update_all/3
    # (unlike Letflow.EventStore.Registry.register_type/2) does not itself
    # guard against.
    exception ->
      {:halt, {:error, {:backfill_failed, tenant_id, {:unexpected_exception, exception}}}}
  end

  @spec classify(map(), Ecto.UUID.t(), non_neg_integer()) :: map()
  defp classify(acc, tenant_id, count) when count > 0 do
    %{acc | repaired: [{tenant_id, count} | acc.repaired]}
  end

  defp classify(acc, tenant_id, 0) do
    %{acc | unchanged: [tenant_id | acc.unchanged]}
  end

  @spec finalize({:ok, map()} | {:error, term()}) ::
          {:ok,
           %{
             repaired: [{Ecto.UUID.t(), non_neg_integer()}],
             unchanged: [Ecto.UUID.t()]
           }}
          | {:error, term()}
  defp finalize({:ok, %{repaired: repaired, unchanged: unchanged}}) do
    {:ok, %{repaired: Enum.reverse(repaired), unchanged: Enum.reverse(unchanged)}}
  end

  defp finalize({:error, _reason} = error), do: error
end
