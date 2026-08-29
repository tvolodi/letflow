defmodule Letflow.Engine.TaskActivation do
  @moduledoc """
  Task-activation persistence (EE-03) — turns REQ-044's pure transition
  output into committed `tasks` rows. See
  `lib/letflow/design/req047-task-activation-persistence.md` for the full
  design this module implements; this moduledoc restates the points that
  design's §2 requires to be stated here verbatim in substance.

  ## "The signal itself is the guard" (INV-EE47-1)

  This module never inspects a `Letflow.Definitions.Graph.Node.t().node_type`
  to decide whether to create a task row. The presence of a
  `Letflow.Engine.Token.t()` in the *diff* between an `InstanceState`'s
  `pending_task_nodes` before and after one `transition/3`-driven activation
  is the only signal this module acts on, because `Letflow.Engine.Transition`'s
  own dispatch (REQ-044 §6.3) is the single place any entry is ever added to
  `pending_task_nodes`, and it only runs for a `:HUMAN_TASK` node.

  ## No assignment resolution here

  This module builds no node-type re-validation, no group-membership check,
  and no assignment-resolution logic of its own (§4.3 of the design) —
  assignment resolution is explicitly deferred to runtime, not an
  activation-time concern.

  ## Callers

  `Letflow.Engine.persist/8` is `append_multi/6`'s only caller (§5 of the
  design). REQ-048 (EE-04, task completion,
  `lib/letflow/design/req048-task-completion.md` §9) does **not** reuse
  `append_multi/6` unmodified — its own Multi never produces the
  `:token_record`-keyed step `append_multi/6` requires (its tokens are
  pre-existing rows being advanced/reconciled, never freshly inserted).
  `Letflow.Engine.complete_task/3` instead calls
  `append_multi_from_existing_records/6`, a second public function this
  module exposes, which reuses `newly_pending_tokens/2` and `insert_attrs/4`
  genuinely unchanged but skips the FK-zip step entirely.

  ## Zero `Repo` calls of its own (INV-EE47-7)

  Every write this module drives happens inside the *caller's* already-open
  `Ecto.Multi`/transaction — matching the pattern `Letflow.EventStore.append/2`
  and `Letflow.Definitions.SnapshotStore.create/3` already establish.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.Definitions.Graph
  alias Letflow.Engine.InstanceState
  alias Letflow.Engine.Task
  alias Letflow.Engine.Token
  alias Letflow.Engine.TokenRecord

  @doc """
  Builds a `token.token_id => TokenRecord.id` lookup map from two same-order
  lists (`new_instance_state.tokens` and M2's own inserted `TokenRecord.t()`
  list), resolving `tasks.token_id`'s FK target (design §3).
  """
  @spec token_id_to_record_id([Token.t()], [TokenRecord.t()]) ::
          %{optional(String.t()) => Ecto.UUID.t()}
  def token_id_to_record_id(tokens, records) do
    tokens
    |> Enum.zip(records)
    |> Map.new(fn {%Token{token_id: token_id}, %TokenRecord{id: record_id}} ->
      {token_id, record_id}
    end)
  end

  @doc """
  Returns every `Token.t()` in `new_pending_task_nodes` whose `{token_id,
  node_id}` pair is not present in `previous_pending_task_nodes` — a
  set-difference keyed on the `{token_id, node_id}` pair (design §5.1),
  resolving REQ-044's own open question (§12.3) of how "already
  materialized" is tracked: this function diffs against the
  `pending_task_nodes` value that was current immediately before the
  `transition/3` call that produced the new state, rather than anything
  being removed from `pending_task_nodes` itself.

  ## Keyed on the pair, not `token_id` alone (ISS-0057 fix)

  REQ-047's original diff (`token_id` equality only) is correct for its own
  caller, `append_multi/6` (`create/2`'s own `previous_pending_task_nodes`
  argument is always `[]`, so no existing `token_id` can ever mask a new
  entry there). It is **not** correct for REQ-048's own caller,
  `append_multi_from_existing_records/6`: a token that continues directly
  from one `:HUMAN_TASK` to another keeps the *same* `token_id`
  (`Transition.advance_token/3` updates `node_id` in place) — diffing by
  `token_id` alone made that token's genuinely-new pending entry (at the
  next node) look "already accounted for" purely because a *stale* entry
  for the same `token_id` (at the now-completed node) was present in
  "previous," so no `tasks` row was ever inserted for the next node (a
  stranded instance — see `docs/issues/ISS-0057.yaml`). Diffing by the
  `{token_id, node_id}` pair instead means a token's stale previous
  position no longer masks its new one, while still correctly excluding
  any token whose position is genuinely unchanged across this hop-chain.
  """
  @spec newly_pending_tokens([Token.t()], [Token.t()]) :: [Token.t()]
  def newly_pending_tokens(previous_pending_task_nodes, new_pending_task_nodes) do
    previous_positions = MapSet.new(previous_pending_task_nodes, &{&1.token_id, &1.node_id})

    Enum.filter(new_pending_task_nodes, fn %Token{token_id: token_id, node_id: node_id} ->
      not MapSet.member?(previous_positions, {token_id, node_id})
    end)
  end

  @doc """
  Resolves `assignee_type`/`assignee_ref` from `node.attributes`, with zero
  group/role-membership resolution (design §4.3, INV-EE47-4). `assignee_ref`
  is `node.attributes["role"]` (guaranteed present and non-empty on a
  structurally valid `:HUMAN_TASK` node by REQ-029's PD-05 CHK-09).
  `assignee_type` is `node.attributes["assignee_type"]` if present, `nil`
  otherwise — no default is invented for an absent key (OQ-1).
  """
  @spec resolve_assignee(node :: Graph.Node.t()) ::
          {assignee_type :: String.t() | nil, assignee_ref :: String.t() | nil}
  def resolve_assignee(%Graph.Node{attributes: attributes}) do
    attributes = attributes || %{}
    {Map.get(attributes, "assignee_type"), Map.get(attributes, "role")}
  end

  @doc """
  Builds the six-key attrs map for `Letflow.Engine.Task.insert_changeset/2`
  (design §4.5). `node_name` falls back to `node.id` when `node.label` is
  `nil` (design §4.2, OQ-2) — `tasks.node_name` is `null: false` but
  `Graph.Node.t().label` is nullable. `status` is never included: the
  schema's own `default: :pending` and `insert_changeset/2`'s own exclusion
  of `:status` from its cast list already make every inserted row `PENDING`
  by construction (INV-EE47-2).
  """
  @spec insert_attrs(
          instance_id :: Ecto.UUID.t(),
          token_record_id :: Ecto.UUID.t(),
          token :: Token.t(),
          node :: Graph.Node.t()
        ) :: map()
  def insert_attrs(instance_id, token_record_id, %Token{} = token, %Graph.Node{} = node) do
    {assignee_type, assignee_ref} = resolve_assignee(node)
    node_name = node.label || node.id

    %{
      instance_id: instance_id,
      token_id: token_record_id,
      node_id: token.node_id,
      node_name: node_name,
      assignee_type: assignee_type,
      assignee_ref: assignee_ref
    }
  end

  @doc """
  Appends one `Multi.run(:task_records, ...)` step to `multi`, inserting one
  `Letflow.Engine.Task` row per newly-pending `Token.t()` (design §5.2). Does
  not open a transaction itself — the caller already has one open. Reads
  `changes.token_record` (the `Ecto.Multi` key `Letflow.Engine.persist/7`'s
  own existing `:token_record` step is registered under) to resolve each
  token's `TokenRecord.id` FK target.
  """
  @spec append_multi(
          multi :: Ecto.Multi.t(),
          instance_id :: Ecto.UUID.t(),
          graph :: Graph.t(),
          previous_pending_task_nodes :: [Token.t()],
          new_instance_state :: InstanceState.t(),
          prefix :: String.t()
        ) :: Ecto.Multi.t()
  def append_multi(
        %Multi{} = multi,
        instance_id,
        %Graph{} = graph,
        previous_pending_task_nodes,
        %InstanceState{} = new_instance_state,
        prefix
      ) do
    Multi.run(multi, :task_records, fn repo, changes ->
      newly_pending =
        newly_pending_tokens(previous_pending_task_nodes, new_instance_state.pending_task_nodes)

      case newly_pending do
        [] ->
          {:ok, []}

        _ ->
          token_records = Map.fetch!(changes, :token_record)

          id_map =
            token_id_to_record_id(new_instance_state.tokens, token_records)

          insert_newly_pending(repo, newly_pending, id_map, graph, instance_id, prefix)
      end
    end)
  end

  defp insert_newly_pending(repo, newly_pending, id_map, graph, instance_id, prefix) do
    newly_pending
    |> Enum.reduce_while({:ok, []}, fn %Token{} = token, {:ok, acc} ->
      with %Graph.Node{} = node <- find_node(graph.nodes, token.node_id) || :unknown_node,
           {:ok, token_record_id} <- fetch_token_record_id(id_map, token.token_id),
           attrs <- insert_attrs(instance_id, token_record_id, token, node),
           {:ok, task} <- do_insert(repo, attrs, prefix) do
        {:cont, {:ok, [task | acc]}}
      else
        :unknown_node ->
          {:halt, {:error, {:unknown_node_id, token.node_id}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, tasks} -> {:ok, Enum.reverse(tasks)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Appends one `Multi.run({:task_records, instance_id}, ...)` step to `multi`,
  inserting one `Letflow.Engine.Task` row per newly-pending `Token.t()` —
  REQ-048's own variant of `append_multi/6` (EE-04,
  `lib/letflow/design/req048-task-completion.md` §9), for a caller whose
  tokens are **pre-existing** `tokens` rows being advanced/reconciled rather
  than freshly inserted the way `Letflow.Engine.persist/8`'s own
  `:token_record` step produces. Reads nothing from `changes` — every
  `Token.t()` this function is ever asked to materialize a `tasks` row for
  already carries, as its own `token_id`, the stringified `id` of an
  existing `TokenRecord` row (the caller's own reconstruction invariant), so
  no `:token_record`-keyed Multi step or positional FK zip is needed here,
  unlike `append_multi/6`. `append_multi/6` itself is left completely
  unmodified by this addition — `Letflow.Engine.create/2`'s own call site is
  unaffected.

  The step key is namespaced by `instance_id` (design doc §10.1) — this
  function can be called more than once on the *same* outer `Multi` within
  one transaction (once for the completing task's own instance, once per
  sub-process completion-cascade level for that level's ancestor instance),
  and a fixed `:task_records` atom key would collide across those calls via
  `Ecto.Multi.merge/2`'s own static duplicate-key check. `append_multi/6` is
  deliberately left on the fixed atom key: it has exactly one call site per
  `Multi`, so no collision is possible there.
  """
  @spec append_multi_from_existing_records(
          multi :: Ecto.Multi.t(),
          instance_id :: Ecto.UUID.t(),
          graph :: Graph.t(),
          previous_pending_task_nodes :: [Token.t()],
          new_instance_state :: InstanceState.t(),
          prefix :: String.t()
        ) :: Ecto.Multi.t()
  def append_multi_from_existing_records(
        %Multi{} = multi,
        instance_id,
        %Graph{} = graph,
        previous_pending_task_nodes,
        %InstanceState{} = new_instance_state,
        prefix
      ) do
    Multi.run(multi, {:task_records, instance_id}, fn repo, _changes ->
      newly_pending =
        newly_pending_tokens(previous_pending_task_nodes, new_instance_state.pending_task_nodes)

      case newly_pending do
        [] ->
          {:ok, []}

        _ ->
          insert_newly_pending_from_existing_records(
            repo,
            newly_pending,
            graph,
            instance_id,
            prefix
          )
      end
    end)
  end

  defp insert_newly_pending_from_existing_records(repo, newly_pending, graph, instance_id, prefix) do
    newly_pending
    |> Enum.reduce_while({:ok, []}, fn %Token{} = token, {:ok, acc} ->
      with {:ok, token_record_id} <- cast_token_record_id(token.token_id),
           %Graph.Node{} = node <- find_node(graph.nodes, token.node_id) || :unknown_node,
           attrs <- insert_attrs(instance_id, token_record_id, token, node),
           {:ok, task} <- do_insert(repo, attrs, prefix) do
        {:cont, {:ok, [task | acc]}}
      else
        :unknown_node ->
          {:halt, {:error, {:unknown_node_id, token.node_id}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, tasks} -> {:ok, Enum.reverse(tasks)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Defense-in-depth check on top of the caller's own token_id-is-a-real-
  # TokenRecord-id reconstruction invariant (req048 design §9 point 4a): a
  # token whose token_id is not UUID-shaped here (e.g. a derived split-branch
  # id like "<parent>/0") means that invariant was violated upstream.
  defp cast_token_record_id(token_id) do
    case Ecto.UUID.cast(token_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid_token_record_id, token_id}}
    end
  end

  defp fetch_token_record_id(id_map, token_id) do
    case Map.fetch(id_map, token_id) do
      {:ok, record_id} -> {:ok, record_id}
      :error -> {:error, {:missing_token_record, token_id}}
    end
  end

  defp do_insert(repo, attrs, prefix) do
    %Task{}
    |> Task.insert_changeset(attrs)
    |> repo.insert(prefix: prefix)
    |> case do
      {:ok, %Task{} = task} -> {:ok, task}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
  end

  # Same non-bang Enum.find/2-shaped lookup Letflow.Engine.Transition's own
  # private find_node/2 already uses (design §5.2 step 3).
  @spec find_node([Graph.Node.t()], String.t()) :: Graph.Node.t() | nil
  defp find_node(nodes, node_id), do: Enum.find(nodes, &(&1.id == node_id))

  @doc """
  REQ-187's SCH-03 timer-cancellation implementation (design doc §5.1) —
  replaces the former `cancel_pending_timers/2` no-op. A single,
  status-guarded `UPDATE ... WHERE status = 'pending'` statement, run on the
  caller-supplied `repo`/`prefix` (never `Letflow.Repo` directly — every
  write this module drives happens inside the caller's already-open
  `Ecto.Multi`/transaction, matching this module's own "Zero `Repo` calls of
  its own" moduledoc invariant literally: `repo` here is the caller's own
  transaction-scoped repo).

  Postgres re-evaluates the `WHERE` predicate against each row's current
  committed state as it acquires that row's lock, so a row a concurrent
  `Letflow.Scheduler.fire_timer/2` has already flipped to `"fired"` (and
  committed) is simply not touched by this statement — no separate
  `SELECT ... FOR UPDATE` pass, no extra lock beyond the one `update_all/3`
  itself takes (design doc §5.1, SCH-03).

  Two known call sites, two `cancel_reason` values: `"instance_completed"`
  (from `Letflow.Engine`'s `finalize_instance_projection/5`) and
  `"instance_cancelled"` (from `Letflow.Engine.cancel_instance/3`'s own
  `run_cancel_instance/5`).
  """
  @spec cancel_pending_timers(
          repo :: Ecto.Repo.t(),
          instance_id :: Ecto.UUID.t(),
          cancelled_at :: DateTime.t(),
          cancel_reason :: String.t(),
          prefix :: String.t()
        ) :: {:ok, non_neg_integer()}
  def cancel_pending_timers(repo, instance_id, cancelled_at, cancel_reason, prefix) do
    {count, _updated} =
      Letflow.Scheduler.Timer
      |> where([t], t.instance_id == ^instance_id and t.status == "pending")
      |> repo.update_all(
        [set: [status: "cancelled", cancelled_at: cancelled_at, cancel_reason: cancel_reason]],
        prefix: prefix
      )

    {:ok, count}
  end
end
