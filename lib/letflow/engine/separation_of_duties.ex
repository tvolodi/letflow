defmodule Letflow.Engine.SeparationOfDuties do
  @moduledoc """
  Rule A of REQ-459 / REQ-463: the HUMAN_TASK node attribute `distinct_from`
  (a list of node ids) and the refusal of a completion -- or an early claim --
  by the user who most recently completed any of those nodes in the SAME
  instance.

  Design: `lib/letflow/design/req459-required-outputs-and-distinct-person.md`
  sections 2.2 (step 4b), 6 and 8.

  ## Entry points

    * `check/5` -- called by the engine's `:completion_guards` step inside the
      open completion transaction, after BOTH row locks (task, then instance
      projection). The authority.
    * `check_for_claim/3` -- called by `Letflow.Tasks.claim_task/3` after the
      eligibility refusals, immediately before the write. Early feedback only:
      TOTAL and fail-open (any failure to obtain the graph or run the query is
      logged with one warning naming only the task id and a failure tag, and
      returns `:ok`; completion re-checks under the locks).

  ## Semantics

    * Identity is the USER ID (`actor_id`), never a role. No role is exempt.
    * Per named node the most recent COMPLETED `tasks` row of this instance
      wins (rework loops); `CANCELLED` and `PENDING` rows are never completions.
    * A named node that has not completed imposes no constraint; parallel
      branches compare with whatever completions exist when the check runs.
    * Default off: a node without a non-empty `distinct_from`, or an
      `actor_id` that is not a binary, returns `:ok` with ZERO queries.
    * The blocking node ids reach only the audit record, never a response.
  """

  import Ecto.Query

  require Logger

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.Graph.Node
  alias Letflow.Definitions.InstanceDefinitionSnapshot
  alias Letflow.Engine
  alias Letflow.Engine.Task
  alias Letflow.Repo

  @doc """
  The completion-time check. `:ok`, or `{:error, {:separation_of_duties,
  blocking_node_ids}}` with the sorted ids of the named nodes whose most recent
  completer is `actor_id`. At most one query; none when the rule is off.
  """
  @spec check(
          repo :: module(),
          graph :: Graph.t(),
          task :: Task.t(),
          actor_id :: Ecto.UUID.t() | String.t() | nil,
          prefix :: String.t()
        ) :: :ok | {:error, {:separation_of_duties, blocking_node_ids :: [String.t()]}}
  def check(repo, graph, task, actor_id, prefix),
    do: run_check(repo, graph, task, actor_id, prefix, [])

  @doc """
  The claim-time check: loads the instance snapshot graph itself, then applies
  the same comparison as `check/5`. Total -- never raises, fails open.
  """
  @spec check_for_claim(
          task :: Task.t(),
          actor_id :: Ecto.UUID.t() | String.t() | nil,
          prefix :: String.t()
        ) :: :ok | {:error, :separation_of_duties}
  def check_for_claim(%Task{} = task, actor_id, prefix) do
    # Every statement of the claim check (the snapshot read AND the completions
    # query) runs under `savepoint_opts/0`, so a DB error is rolled back to its
    # own savepoint and cannot poison claim_task/3's enclosing transaction.
    with {:ok, snapshot} <- load_snapshot(task, prefix),
         {:ok, graph} <- Engine.build_graph(snapshot.graph) do
      case run_check(Repo, graph, task, actor_id, prefix, savepoint_opts()) do
        :ok -> :ok
        {:error, {:separation_of_duties, _ids}} -> {:error, :separation_of_duties}
      end
    else
      {:error, reason} ->
        warn_fail_open(task, failure_tag(reason))
        :ok
    end
  rescue
    _exception ->
      warn_fail_open(task, :raised)
      :ok
  catch
    _kind, _value ->
      warn_fail_open(task, :caught)
      :ok
  end

  def check_for_claim(_task, _actor_id, _prefix), do: :ok

  # The snapshot read of the claim path, inlined here (rather than through
  # `SnapshotStore.get_by_instance_id/2`, which takes no per-query options) so
  # it can carry the savepoint. `task.instance_id` is a UUID taken from a task
  # row, so the store's id cast guard is not needed.
  defp load_snapshot(%Task{instance_id: instance_id}, prefix) do
    case Repo.get(InstanceDefinitionSnapshot, instance_id, [prefix: prefix] ++ savepoint_opts()) do
      nil -> {:error, :snapshot_not_found}
      %InstanceDefinitionSnapshot{} = snapshot -> {:ok, snapshot}
    end
  end

  # `mode: :savepoint` is only valid inside a transaction (claim_task/3's
  # Multi); called bare, it would itself error and fail open spuriously, so it
  # is requested only when a transaction is open.
  defp savepoint_opts, do: if(Repo.in_transaction?(), do: [mode: :savepoint], else: [])

  defp run_check(repo, graph, %Task{} = task, actor_id, prefix, query_opts) do
    named = distinct_from(find_node(graph, task.node_id))

    with true <- named != [] and is_binary(actor_id),
         {:ok, actor} <- Ecto.UUID.cast(actor_id) do
      case blocking_nodes(repo, task.instance_id, named, actor, prefix, query_opts) do
        [] -> :ok
        blocking -> {:error, {:separation_of_duties, blocking}}
      end
    else
      _ -> :ok
    end
  end

  # The single read: the most recent COMPLETED row per named node of this
  # instance (DISTINCT ON node_id, newest first), via idx_task_instance.
  @spec blocking_nodes(
          repo :: module(),
          instance_id :: Ecto.UUID.t(),
          named_node_ids :: [String.t()],
          actor_id :: String.t(),
          prefix :: String.t(),
          query_opts :: keyword()
        ) :: [String.t()]
  defp blocking_nodes(repo, instance_id, named, actor_id, prefix, query_opts) do
    query =
      from(t in Task,
        where: t.instance_id == ^instance_id and t.status == :completed and t.node_id in ^named,
        distinct: [asc: t.node_id],
        order_by: [desc: t.completed_at, desc: t.inserted_at, desc: t.id],
        select: {t.node_id, t.completed_by}
      )

    query
    |> repo.all([prefix: prefix] ++ query_opts)
    |> Enum.filter(fn {_node_id, completed_by} -> completed_by == actor_id end)
    |> Enum.map(fn {node_id, _completed_by} -> node_id end)
    |> Enum.sort()
  end

  @spec distinct_from(Node.t() | nil) :: [String.t()]
  defp distinct_from(%Node{attributes: %{"distinct_from" => list}}) when is_list(list) do
    list |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.uniq()
  end

  defp distinct_from(_node), do: []

  defp find_node(%Graph{nodes: nodes}, node_id), do: Enum.find(nodes, &(&1.id == node_id))

  defp failure_tag(:snapshot_not_found), do: :snapshot_not_found
  defp failure_tag({:graph_structure_invalid, _}), do: :graph_structure_invalid

  defp warn_fail_open(%Task{id: task_id}, tag) do
    Logger.warning(
      "separation_of_duties claim check failed open for task #{task_id}: #{inspect(tag)}"
    )
  end
end
