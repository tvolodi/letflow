defmodule Letflow.Engine do
  @moduledoc """
  Context module for EE-01 (`create/2`) — starting a new process instance.
  See `lib/letflow/design/req045-instance-start-engine-shell.md` for the full
  design this module implements; this moduledoc restates the points that
  design's §2 requires to be stated here verbatim in substance.

  ## Process-vs-row decision (AC5, AC6)

  Whether a running instance is a supervised `:gen_statem` process or a
  plain transactional context module was this stage's largest open design
  question (`docs/migration/stage-3-instance-engine.md`'s second Early
  finding). This module resolves it for EE-01's own scope only: `create/2`
  is a plain function, no process — see the design doc §1 for the full
  reasoning (every write EE-01 performs is already transactional; there is
  no multi-step conversation a caller has across several calls the way
  `submitted -> approve` in `Letflow.ProcessInstance` does; no timer, no
  backpressure, no external-plugin call). The answer may legitimately differ
  for later engine subsystems (REQ-056 service task dispatch, REQ-057 plugin
  registry), which the same finding names as the strong case for a process;
  this module does not pre-empt those requirements' own decisions.

  Concretely, for the two existing modules this decision bears on:

    * `lib/letflow/process_instance.ex` is **superseded, not extended**. Its
      hardcoded four-atom state graph becomes REQ-027 definition data,
      snapshotted per instance by REQ-033. `Letflow.ProcessInstance` itself
      is not deleted by this requirement — REQ-046 owns physically removing
      it; this requirement only stops adding to its pattern and builds the
      real replacement alongside it.
    * `lib/letflow/instance_supervisor.ex` is **generalized, not
      superseded** — but not by this requirement, since this requirement
      introduces no process for it to supervise. Its `DynamicSupervisor`
      shape is confirmed still correct in principle for whichever later S3
      requirement (REQ-056/REQ-057) does need a supervised process.
      `Letflow.Engine` does not modify `instance_supervisor.ex` at all.
    * `Letflow.Events.TransitionEvent` (and its migration) is **deliberately
      kept in place, not retired by this requirement.** REQ-023's `events`
      table is the durable event log for the new engine (this module
      appends `INSTANCE_STARTED` there); `TransitionEvent` is
      `Letflow.ProcessInstance`'s own private log with no reader or writer
      outside that module. Retiring it is REQ-046's job, bundled with
      `Letflow.ProcessInstance`'s own removal.

  ## HTTP is out of scope (AC7 / scope boundary)

  `POST /api/v1/instances` and every other HTTP route belong to S4
  (api-surface) — this module builds a context-module function only,
  returning tagged tuples, matching the boundary every other S2-S3 context
  module already established.

  ## Activation loops to a stable resting state (AC7, updated post-REQ-050/051)

  `create/2` drives `Letflow.Engine.Transition.transition/3` from a worklist
  loop (`advance_until_stable/4`), one hop per call — matching
  `Transition`'s own "single hop per call" contract (its moduledoc) —
  rather than assuming any fixed hop count. After each hop it diffs the
  token list against what it was immediately before that hop
  (`tokens_needing_dispatch/3`) to decide which token_ids still need a
  dispatch call: a token needs another hop exactly when it just arrived
  somewhere its own node's dispatch hasn't run yet (whether via a plain
  :START/gateway advance, or as one of several fresh tokens produced by a
  `:PARALLEL_GATEWAY` split or join) — never when it stayed at the same
  `node_id` (`:HUMAN_TASK`'s genuine "no automatic outgoing traversal"
  stop) or was removed outright (`:END`, or a join's `:wait` outcome). The
  loop ends the instant the worklist is empty: either no token remains
  (the instance reached `:END` and completed) or every remaining token
  sits on a genuine waiting state or a node type this engine doesn't
  dispatch yet (`:SERVICE_TASK`/`:TIMER`/`:SUB_PROCESS`, surfaced as
  `{:error, {:activation_failed, {:node_type_not_yet_implemented, ...}}}`).
  A defensive, generously-sized hop bound
  (`length(graph.nodes) * 4 + 10`) guards against ever looping forever
  should a malformed/cyclic graph somehow reach this code despite
  REQ-028's structural validators rejecting true cycles — see design doc
  §9 OQ-1a (updated) for the full history of this limitation.

  ## `tenant_id` is validated, never persisted

  `attrs` never accepts a `:tenant_id` (or `"tenant_id"`) key.
  `opts[:prefix]` is resolved via
  `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` purely to prove it
  names a well-formed tenant schema before any I/O — the derived value is
  not stored anywhere by this module, since none of
  `instance_projections`/`tokens`/`tasks` carries a `tenant_id` column
  (Decision 0006 D2).

  ## `complete_task/3` (EE-04, REQ-048) — HTTP and assignee authorization are
  ## out of scope

  `POST /api/v1/tasks/:id/complete`'s HTTP status-code mapping (404/409/422
  for `:task_not_found`/`{:task_not_pending, _}`/`:invalid_output_variables`
  respectively) is S4 (api-surface) scope — `complete_task/3` returns tagged
  tuples only, exactly as `Letflow.EventStore.append/2`'s `is_duplicate`
  boolean already left the 200-vs-201 choice to S4. Whether the calling
  `TASK_WORKER` is the task's own `assignee_ref` (HTTP 403 otherwise, per
  IDN-03's role matrix) is **not checked anywhere in this module** — that is
  the S4 auth plug's job, per REQ-021's precedent; `complete_task/3` performs
  no assignee comparison and accepts `attrs.actor_id` as already-authorized
  by the caller. See `lib/letflow/design/req048-task-completion.md` for the
  full design.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.Definitions
  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.SnapshotStore
  alias Letflow.Engine.InstanceState
  alias Letflow.Engine.Task
  alias Letflow.Engine.TaskActivation
  alias Letflow.Engine.Token
  alias Letflow.Engine.TokenRecord
  alias Letflow.Engine.Transition
  alias Letflow.Engine.VariableMerge
  alias Letflow.EventStore
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @type create_attrs :: %{
          optional(:definition_id) => Ecto.UUID.t(),
          optional(:definition_name) => String.t(),
          optional(:correlation_key) => String.t() | nil,
          required(:initial_variables) => map(),
          required(:actor_id) => Ecto.UUID.t(),
          required(:idempotency_key) => String.t()
        }

  @type opts :: [prefix: String.t()]

  @type create_error ::
          {:error, :tenant_id_not_accepted}
          | {:error, :invalid_schema_name}
          | {:error, :missing_definition_reference}
          | {:error, :both_definition_id_and_name}
          | {:error, :invalid_initial_variables}
          | {:error, :definition_not_found}
          | {:error, :definition_not_active}
          | {:error, :duplicate_correlation_key}
          | {:error, {:snapshot_failed, term()}}
          | {:error, {:graph_structure_invalid, term()}}
          | {:error, {:activation_failed, term()}}
          | {:error, {:event_append_failed, term()}}
          | {:error, Ecto.Changeset.t()}
          | {:error, term()}

  @type create_result :: %{
          instance_id: Ecto.UUID.t(),
          definition_id: Ecto.UUID.t(),
          status: :active | :completed,
          current_nodes: [String.t()],
          variables: map(),
          started_at: DateTime.t()
        }

  @doc """
  Starts a new process instance (EE-01) from an ACTIVE definition: resolves
  and validates the definition, snapshots it (`Letflow.Definitions.SnapshotStore`,
  before any event exists), advances the root token off `:START` via
  `Letflow.Engine.Transition`, and atomically inserts the
  `instance_projections` row, the root `tokens` row, and the
  `INSTANCE_STARTED` event (one `Ecto.Multi`) — see this module's moduledoc
  and the design doc for the full algorithm and error taxonomy.

  Exactly one of `attrs[:definition_id]`/`attrs[:definition_name]` must be
  given (`:definition_name` resolves via
  `Letflow.Definitions.get_active_by_name/2` — *the* single ACTIVE row for
  that name). `attrs[:initial_variables]` must be a plain map (`%{}` is
  valid); `attrs[:correlation_key]` is optional and may be `nil`.
  `attrs[:actor_id]`/`attrs[:idempotency_key]` are required — plumbed
  straight through to `Letflow.EventStore.append/2`'s own identical
  requirement.
  """
  @spec create(attrs :: create_attrs(), opts :: opts()) ::
          {:ok, create_result()} | create_error()
  def create(attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with :ok <- reject_tenant_id(attrs),
         :ok <- check_definition_reference(attrs),
         {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, initial_variables} <- fetch_initial_variables(attrs),
         {:ok, definition} <- resolve_definition(attrs, opts) do
      correlation_key = Map.get(attrs, :correlation_key)
      start_instance(definition, initial_variables, correlation_key, attrs, prefix)
    end
  end

  # ---------------------------------------------------------------------
  # Pre-transaction phase (design doc §4) -- zero DB writes attempted.
  # ---------------------------------------------------------------------

  defp reject_tenant_id(attrs) do
    if Map.has_key?(attrs, :tenant_id) or Map.has_key?(attrs, "tenant_id") do
      {:error, :tenant_id_not_accepted}
    else
      :ok
    end
  end

  defp check_definition_reference(attrs) do
    has_id = Map.has_key?(attrs, :definition_id)
    has_name = Map.has_key?(attrs, :definition_name)

    cond do
      has_id and has_name -> {:error, :both_definition_id_and_name}
      not has_id and not has_name -> {:error, :missing_definition_reference}
      true -> :ok
    end
  end

  defp fetch_initial_variables(attrs) do
    case Map.get(attrs, :initial_variables) do
      variables when is_map(variables) and not is_struct(variables) -> {:ok, variables}
      _other -> {:error, :invalid_initial_variables}
    end
  end

  defp resolve_definition(%{definition_id: definition_id}, opts) do
    definition_id
    |> Definitions.get_by_id(opts)
    |> interpret_definition_lookup()
  end

  defp resolve_definition(%{definition_name: definition_name}, opts) do
    definition_name
    |> Definitions.get_active_by_name(opts)
    |> interpret_definition_lookup()
  end

  defp interpret_definition_lookup({:ok, definition}) do
    case definition.status do
      :active -> {:ok, definition}
      _other -> {:error, :definition_not_active}
    end
  end

  defp interpret_definition_lookup({:error, :not_found}), do: {:error, :definition_not_found}
  defp interpret_definition_lookup({:error, _reason} = error), do: error

  # ---------------------------------------------------------------------
  # Snapshot phase (design doc §5) -- must precede the event append; opens
  # and commits its own transaction, deliberately not folded into the
  # Ecto.Multi below (design doc §9 OQ-4).
  # ---------------------------------------------------------------------

  defp start_instance(definition, initial_variables, correlation_key, attrs, prefix) do
    instance_id = Ecto.UUID.generate()

    with {:ok, _snapshot} <- create_snapshot(instance_id, definition, prefix),
         {:ok, graph, new_instance_state} <-
           activate(instance_id, definition, initial_variables) do
      persist(
        instance_id,
        definition,
        initial_variables,
        correlation_key,
        graph,
        new_instance_state,
        attrs,
        prefix
      )
    end
  end

  defp create_snapshot(instance_id, definition, prefix) do
    case SnapshotStore.create(instance_id, definition.id, prefix: prefix) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, :definition_not_found} -> {:error, :definition_not_found}
      {:error, reason} -> {:error, {:snapshot_failed, reason}}
    end
  end

  # ---------------------------------------------------------------------
  # Pure dispatch off :START (design doc §6 steps 8-9) -- runs entirely
  # before the Multi opens, so a dispatch failure never needs a rollback.
  # ---------------------------------------------------------------------

  defp activate(instance_id, definition, initial_variables) do
    with {:ok, graph} <- build_graph(definition.graph),
         {:ok, start_node} <- find_start_node(graph) do
      token_id = Ecto.UUID.generate()
      root_token = %Token{token_id: token_id, node_id: start_node.id, branch_id: instance_id}

      instance_state = %InstanceState{
        instance_id: instance_id,
        status: :active,
        tokens: [root_token],
        variables: initial_variables,
        pending_task_nodes: []
      }

      # Defensive-only bound (see moduledoc): REQ-028's structural validators
      # are expected to reject any true graph cycle before a definition ever
      # reaches create/2, so this is never expected to actually trigger --
      # it exists purely so a malformed graph that somehow slips past those
      # validators fails with a typed error instead of looping forever
      # (this codebase's "never raise, never hang" totality discipline,
      # transition.ex's own moduledoc). Scaled by a small multiple of the
      # node count, not just `length(graph.nodes) + 1`: a PARALLEL_GATEWAY
      # split (REQ-051) can put several tokens in flight at once, each
      # independently walking its own branch toward the matching join, so
      # the total hop budget for one activation can legitimately exceed the
      # raw node count without any cycle being involved.
      hop_limit = length(graph.nodes) * 4 + 10

      case advance_until_stable(graph, instance_state, [token_id], hop_limit) do
        {:ok, new_instance_state} -> {:ok, graph, new_instance_state}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Worklist-driven activation loop: `pending_token_ids` holds every token_id
  # still known to need a dispatch attempt at its *current* position.
  # Advances a single hop with the head of the worklist, then re-derives
  # which token_ids need dispatching next by diffing the token list before
  # and after that hop (`tokens_needing_dispatch/3`) -- this is what lets a
  # single uniform rule handle every REQ-044/050/051 dispatch clause without
  # this module hardcoding which node types "auto-advance": a token needs
  # another dispatch call exactly when it just arrived somewhere its own
  # node's dispatch hasn't run yet (a fresh `node_id`, whether reached via
  # :START/gateway advance, a PARALLEL_GATEWAY split's newly-derived
  # branches, or a join firing's newly-derived merged token) -- never when
  # it stayed put (:HUMAN_TASK's "no automatic outgoing traversal" contract,
  # or a join's :wait outcome consuming the arriving branch token without
  # producing a new one).
  defp advance_until_stable(_graph, instance_state, [], _hops_remaining) do
    {:ok, instance_state}
  end

  defp advance_until_stable(_graph, _instance_state, [token_id | _rest], hops_remaining)
       when hops_remaining <= 0 do
    {:error, {:activation_failed, {:hop_limit_exceeded, token_id}}}
  end

  defp advance_until_stable(graph, instance_state, [token_id | rest], hops_remaining) do
    previous_tokens = instance_state.tokens

    case Transition.transition(graph, instance_state, {:advance_token, token_id}) do
      {:ok, new_instance_state, _pending_events} ->
        newly_pending =
          tokens_needing_dispatch(previous_tokens, new_instance_state.tokens, token_id)

        advance_until_stable(graph, new_instance_state, rest ++ newly_pending, hops_remaining - 1)

      {:error, reason} ->
        {:error, {:activation_failed, reason}}
    end
  end

  # Diffs the token list from just before/after one dispatch call to decide
  # which token_ids still need their own dispatch attempt: any token_id that
  # didn't exist before this hop (a PARALLEL_GATEWAY split's derived
  # branches, or a join's newly-fired merged token) is always fresh and
  # needs one; the just-dispatched token_id itself needs another pass only
  # if its node_id actually changed (it moved somewhere new) -- if it's
  # gone entirely (:END removed it, or a join consumed it) or stayed at the
  # same node_id (:HUMAN_TASK's genuine stop) it does not. Every other
  # existing token is untouched by this hop and was already resolved (either
  # still correctly queued from an earlier hop, or already stable) -- this
  # function never re-adds it.
  @spec tokens_needing_dispatch([Token.t()], [Token.t()], String.t()) :: [String.t()]
  defp tokens_needing_dispatch(previous_tokens, new_tokens, dispatched_token_id) do
    previous_by_id = Map.new(previous_tokens, &{&1.token_id, &1})

    new_tokens
    |> Enum.filter(fn token ->
      case Map.fetch(previous_by_id, token.token_id) do
        :error ->
          true

        {:ok, %Token{node_id: previous_node_id}} ->
          token.token_id == dispatched_token_id and token.node_id != previous_node_id
      end
    end)
    |> Enum.map(& &1.token_id)
  end

  defp build_graph(graph_map) do
    case Graph.from_map(graph_map) do
      {:ok, graph} -> {:ok, graph}
      :error -> {:error, {:graph_structure_invalid, :invalid_graph_map}}
    end
  end

  # A structurally-valid graph (CHK-01, REQ-028) guarantees exactly one
  # START node -- defensive, never-raising fallback only, not a literal AC
  # case (design doc §6 step 8).
  defp find_start_node(%Graph{nodes: nodes}) do
    case Enum.find(nodes, &(&1.node_type == :START)) do
      nil -> {:error, {:graph_structure_invalid, :no_start_node}}
      start_node -> {:ok, start_node}
    end
  end

  # ---------------------------------------------------------------------
  # Atomic phase (design doc §6 steps 10-11) -- one Ecto.Multi: the
  # instance_projections row, the root tokens row, the INSTANCE_STARTED
  # event, all together or none at all.
  # ---------------------------------------------------------------------

  defp persist(
         instance_id,
         definition,
         initial_variables,
         correlation_key,
         graph,
         new_instance_state,
         attrs,
         prefix
       ) do
    current_node_ids = Enum.map(new_instance_state.tokens, & &1.node_id)

    Multi.new()
    |> Multi.run(:instance_projection, fn repo, _changes ->
      # M1 always inserts :active, even when the landing-node dispatch above
      # already completed the instance (design doc §9 OQ-1a's :END success
      # case): Letflow.EventStore.append/2's own active_instance_guard (its
      # M1, run as part of M3 below) requires the instance_projections row
      # to be non-terminal at INSTANCE_STARTED append time -- the same
      # ordering EventStore.append/2 already enforces for every other
      # event. M4 below flips the row to its true final status immediately
      # after the event append succeeds, still inside this same Multi.
      insert_instance_projection(
        repo,
        instance_id,
        definition,
        correlation_key,
        :active,
        current_node_ids,
        initial_variables,
        prefix
      )
    end)
    |> Multi.run(:token_record, fn repo, _changes ->
      insert_token_records(repo, instance_id, new_instance_state.tokens, prefix)
    end)
    |> TaskActivation.append_multi(
      instance_id,
      graph,
      # create/2's own call site always starts from a freshly-constructed
      # InstanceState (pending_task_nodes: []), so every entry in
      # new_instance_state.pending_task_nodes is "newly pending" by
      # construction (req047 design §5.1) -- a future EE-04 caller is
      # expected to pass that instance's own pending_task_nodes value, read
      # at the start of its own call, instead of [].
      [],
      new_instance_state,
      prefix
    )
    |> Multi.run(:event, fn _repo, _changes ->
      append_instance_started_event(
        instance_id,
        definition,
        correlation_key,
        initial_variables,
        attrs,
        prefix
      )
    end)
    |> Multi.run(:finalize, fn repo, %{instance_projection: projection} ->
      finalize_instance_projection(
        repo,
        projection,
        new_instance_state.status,
        prefix,
        instance_id
      )
    end)
    |> Repo.transaction()
    |> interpret_create_result(
      instance_id,
      definition,
      new_instance_state.status,
      current_node_ids,
      initial_variables
    )
  end

  # M1 -- insert instance_projections. A uq_instance_correlation collision
  # surfaces as an Ecto.Changeset unique-constraint error, mapped here to
  # :duplicate_correlation_key (AC4); any other changeset failure is passed
  # through raw (create_error()'s Ecto.Changeset.t() catch-all clause).
  defp insert_instance_projection(
         repo,
         instance_id,
         definition,
         correlation_key,
         status,
         current_node_ids,
         initial_variables,
         prefix
       ) do
    attrs = %{
      instance_id: instance_id,
      status: status,
      definition_id: definition.id,
      correlation_key: correlation_key,
      current_nodes: current_node_ids,
      variables: initial_variables
    }

    %InstanceProjection{}
    |> InstanceProjection.insert_changeset(attrs)
    |> repo.insert(prefix: prefix)
    |> case do
      {:ok, %InstanceProjection{} = projection} ->
        {:ok, projection}

      {:error, %Ecto.Changeset{} = changeset} ->
        if unique_violation?(changeset, :correlation_key) do
          {:error, :duplicate_correlation_key}
        else
          {:error, changeset}
        end
    end
  end

  # M2 -- insert the root/branch tokens row(s), post-landing-dispatch node_id,
  # branch_id == instance_id for the root branch (req043 §3.2's root-branch
  # convention) or the branch's own id for each PARALLEL_GATEWAY split branch.
  # Must run after M1 (tokens.instance_id's FK target must already exist in
  # the same transaction). An empty token list means the root token already
  # reached :END and was removed by dispatch_end/3 (design doc §9 OQ-1a's
  # :END success case) -- no tokens row at all for this instance, matching
  # the test's own explicit assertion that a same-call :END completion
  # leaves zero rows in `tokens`, not one stranded at "end". A
  # PARALLEL_GATEWAY split can legitimately leave two or more live tokens
  # (one per branch, each parked at its own node) -- inserted here one at a
  # time, in order, so the first failure short-circuits the rest.
  defp insert_token_records(_repo, _instance_id, [], _prefix), do: {:ok, []}

  defp insert_token_records(repo, instance_id, [%Token{} | _] = tokens, prefix) do
    Enum.reduce_while(tokens, {:ok, []}, fn %Token{} = token, {:ok, acc} ->
      case insert_token_record(repo, instance_id, token, prefix) do
        {:ok, record} -> {:cont, {:ok, [record | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_token_record(repo, instance_id, %Token{} = token, prefix) do
    attrs = %{
      instance_id: instance_id,
      node_id: token.node_id,
      branch_id: token.branch_id,
      status: :active
    }

    %TokenRecord{}
    |> TokenRecord.insert_changeset(attrs)
    |> repo.insert(prefix: prefix)
    |> case do
      {:ok, %TokenRecord{} = record} -> {:ok, record}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, {:activation_failed, changeset}}
    end
  end

  # M3 -- append the INSTANCE_STARTED event. Must run after M1:
  # EventStore.append/2's own active_instance_guard requires the
  # instance_projections row to already exist. Letflow.EventStore.append/2
  # opens its own Repo.transaction/1 internally, which Ecto runs reentrantly
  # inside this Multi's already-open transaction (same connection, no second
  # real transaction) -- see the design doc §6 step 10 for the full citation.
  #
  # actor_id/idempotency_key are read with Map.get/2, never Map.fetch!/2: a
  # caller omitting either is exactly the kind of externally-reachable input
  # this module must not raise on (INV-8) -- a missing value is passed
  # through unchanged to EventStore.append/2, which already returns the
  # typed :missing_actor_id / :missing_idempotency_key errors for it.
  defp append_instance_started_event(
         instance_id,
         definition,
         correlation_key,
         initial_variables,
         attrs,
         prefix
       ) do
    payload =
      Jason.encode!(%{
        definition_id: definition.id,
        correlation_key: correlation_key,
        initial_variables: initial_variables
      })

    event_attrs = %{
      instance_id: instance_id,
      event_type: "INSTANCE_STARTED",
      payload: payload,
      actor_id: Map.get(attrs, :actor_id),
      idempotency_key: Map.get(attrs, :idempotency_key)
    }

    case EventStore.append(event_attrs, prefix: prefix) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:event_append_failed, reason}}
    end
  end

  # M4 -- flips the instance_projections row to its true final status once
  # the INSTANCE_STARTED event (M3) has been appended while the row was
  # still :active (see M1's comment above). A no-op when the landing-node
  # dispatch left the instance :active (the common HUMAN_TASK case) --
  # avoids an unconditional extra UPDATE for the overwhelmingly common path.
  # `completed_at` is set here (not at M1) since this is the one place the
  # row's terminal status actually becomes true, matching
  # `InstanceProjection.terminal?/1`'s own :completed/:cancelled framing.
  defp finalize_instance_projection(
         _repo,
         %InstanceProjection{} = projection,
         :active,
         _prefix,
         _instance_id
       ) do
    {:ok, projection}
  end

  defp finalize_instance_projection(
         repo,
         %InstanceProjection{} = projection,
         :completed,
         prefix,
         instance_id
       ) do
    attrs = %{status: :completed, completed_at: DateTime.utc_now()}

    projection
    |> InstanceProjection.update_changeset(attrs)
    |> repo.update(prefix: prefix)
    |> case do
      {:ok, %InstanceProjection{} = updated} ->
        # req047 design §8 -- the named SCH-03 timer-cancellation hook,
        # called here (still inside this open transaction) immediately
        # after the instance_projections row's status is confirmed flipped
        # to :completed, so a future S6 implementation that performs a real
        # DB write participates in this same atomic commit/rollback.
        :ok = TaskActivation.cancel_pending_timers(instance_id, prefix)
        {:ok, updated}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  defp unique_violation?(%Ecto.Changeset{errors: errors}, field) do
    Enum.any?(errors, fn
      {^field, {_message, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  # ---------------------------------------------------------------------
  # Result assembly (design doc §6 step 11).
  # ---------------------------------------------------------------------

  defp interpret_create_result(
         {:ok, %{instance_projection: %InstanceProjection{} = projection}},
         instance_id,
         definition,
         status,
         current_node_ids,
         initial_variables
       ) do
    {:ok,
     %{
       instance_id: instance_id,
       definition_id: definition.id,
       status: status,
       current_nodes: current_node_ids,
       variables: initial_variables,
       started_at: projection.started_at
     }}
  end

  # Catch-all -- every Multi step's own callback above already maps its
  # failure to the exact error shape create_error() promises (or passes a
  # raw changeset/term() through, matching those catch-all clauses); this
  # just unwraps Ecto.Multi's {:error, failed_step, reason, changes_so_far}
  # envelope around whatever reason each step already produced.
  defp interpret_create_result(
         {:error, _failed_step, reason, _changes},
         _instance_id,
         _definition,
         _status,
         _current_node_ids,
         _initial_variables
       ) do
    {:error, reason}
  end

  # =========================================================================
  # complete_task/3 (EE-04, REQ-048) -- see
  # lib/letflow/design/req048-task-completion.md for the full design this
  # section implements.
  # =========================================================================

  @type complete_attrs :: %{
          required(:output_variables) => map(),
          required(:actor_id) => Ecto.UUID.t(),
          required(:idempotency_key) => String.t()
        }

  @type complete_opts :: [prefix: String.t()]

  @type complete_error ::
          {:error, :invalid_output_variables}
          | {:error, :invalid_task_id}
          | {:error, :invalid_schema_name}
          | {:error, :task_not_found}
          | {:error, {:task_not_pending, status :: :completed | :cancelled}}
          | {:error, :instance_not_found}
          | {:error, {:instance_not_active, status :: :completed | :cancelled | :error}}
          | {:error, :snapshot_not_found}
          | {:error, {:graph_structure_invalid, term()}}
          | {:error, {:missing_token_record, token_id :: Ecto.UUID.t()}}
          | {:error, {:transition_failed, Transition.transition_error()}}
          | {:error, {:new_token_during_resume_not_supported, token_id :: String.t()}}
          | {:error, {:task_activation_failed, term()}}
          | {:error, {:event_append_failed, term()}}
          | {:error, :missing_actor_id}
          | {:error, :missing_idempotency_key}
          | {:error, Ecto.Changeset.t()}
          | {:error, term()}

  @type complete_result :: %{
          task_id: Ecto.UUID.t(),
          instance_id: Ecto.UUID.t(),
          instance_status: :active | :completed,
          current_nodes: [String.t()],
          variables: map(),
          completed_at: DateTime.t()
        }

  @doc """
  Completes a `PENDING` `Letflow.Engine.Task` (EE-04): merges
  `attrs[:output_variables]` into the instance's live variables (REQ-049's
  `Letflow.Engine.VariableMerge.merge/3`), evaluates the completed
  `:HUMAN_TASK` node's own outgoing edges via
  `Letflow.Engine.Transition`'s new `{:complete_task, token_id}` dispatch,
  activates any newly-reached `:HUMAN_TASK` node(s)
  (`Letflow.Engine.TaskActivation.append_multi_from_existing_records/6`),
  flips the task row to `COMPLETED`, and appends exactly one
  `TASK_COMPLETED` event (REQ-025) -- all inside one `Ecto.Multi`/
  `Repo.transaction/1`. Row-level `SELECT ... FOR UPDATE` locking on the
  `tasks` row (and, for the same reason `instance_projections` writes need
  it, on the owning `instance_projections` row) serializes two concurrent
  `complete_task/3` calls on the same `task_id`: exactly one commits
  `:completed`, the other observes `{:error, {:task_not_pending,
  :completed}}`.

  `attrs[:output_variables]` must be present and a plain map (`%{}` is
  valid); `nil`, a missing key, or a non-map/struct value are all rejected
  with `{:error, :invalid_output_variables}` before any I/O is attempted.
  `attrs[:actor_id]`/`attrs[:idempotency_key]` are not independently
  pre-validated here -- they are plumbed straight through to
  `Letflow.EventStore.append/2`'s own identical requirement, matching
  `create/2`'s own `append_instance_started_event/6` pattern (design doc
  §10).

  See this module's moduledoc for the S4 (HTTP status mapping, IDN-03
  assignee authorization) scope boundary this function does not implement.
  """
  @spec complete_task(
          task_id :: Ecto.UUID.t(),
          attrs :: complete_attrs(),
          opts :: complete_opts()
        ) :: {:ok, complete_result()} | complete_error()
  def complete_task(task_id, attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with {:ok, task_id} <- cast_task_id(task_id),
         {:ok, output_variables} <- fetch_output_variables(attrs),
         {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      actor_id = Map.get(attrs, :actor_id)
      idempotency_key = Map.get(attrs, :idempotency_key)
      completed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      run_complete_task(
        task_id,
        output_variables,
        actor_id,
        idempotency_key,
        completed_at,
        prefix
      )
    end
  end

  # ---------------------------------------------------------------------
  # Pre-transaction phase (design doc §4) -- zero DB writes attempted.
  # ---------------------------------------------------------------------

  # Defensive INV-8 guard, not literally named by the design's own §3/§4
  # text: task_id flows straight into a `where t.id == ^task_id` query
  # (M1, below) -- a malformed, non-UUID-shaped value there raises
  # Ecto.Query.CastError rather than returning a typed error, the same
  # class of bug lib/letflow/event_store.ex's fetch_uuid/3 and
  # lib/letflow/definitions/snapshot_store.ex's cast_uuid/2 already guard
  # against for their own externally-reachable id arguments. Flagged for
  # REVIEWER as a deliberate addition beyond the design's literal text.
  defp cast_task_id(task_id) do
    case Ecto.UUID.cast(task_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_task_id}
    end
  end

  defp fetch_output_variables(attrs) do
    case Map.get(attrs, :output_variables) do
      variables when is_map(variables) and not is_struct(variables) -> {:ok, variables}
      _other -> {:error, :invalid_output_variables}
    end
  end

  # ---------------------------------------------------------------------
  # Atomic phase (design doc §8) -- one Ecto.Multi.
  # ---------------------------------------------------------------------

  defp run_complete_task(
         task_id,
         output_variables,
         actor_id,
         idempotency_key,
         completed_at,
         prefix
       ) do
    Multi.new()
    |> Multi.run(:task, fn repo, _changes -> fetch_and_lock_task(repo, task_id, prefix) end)
    |> Multi.run(:instance_projection, fn repo, %{task: task} ->
      fetch_and_lock_instance_projection(repo, task.instance_id, prefix)
    end)
    |> Multi.run(:snapshot_and_state, fn repo, %{task: task, instance_projection: projection} ->
      build_snapshot_and_state(repo, task, projection, prefix)
    end)
    |> Multi.run(:merge, fn _repo, %{snapshot_and_state: %{seed_instance_state: seed_state}} ->
      merge_output_variables(seed_state.variables, output_variables)
    end)
    |> Multi.run(:transition, fn _repo,
                                 %{snapshot_and_state: snapshot_and_state, merge: merge_result} ->
      dispatch_task_completion_hop_chain(snapshot_and_state, merge_result)
    end)
    |> Multi.merge(fn changes ->
      build_task_activation_and_reconciliation_multi(changes, completed_at, prefix)
    end)
    |> Multi.run(:task_complete, fn repo, %{task: task} ->
      complete_task_row(repo, task, actor_id, output_variables, completed_at, prefix)
    end)
    |> Multi.run(:event, fn _repo, changes ->
      append_task_completed_event(changes, output_variables, actor_id, idempotency_key, prefix)
    end)
    |> Multi.run(:projection, fn repo,
                                 %{instance_projection: projection, transition: final_state} ->
      reconcile_projection(repo, projection, final_state, completed_at, prefix)
    end)
    |> Repo.transaction()
    |> interpret_complete_result()
  end

  # M1 -- row-lock + fetch the tasks row (design doc §8.1, AC4). Ecto's
  # lock/2 query composition, never a hand-written SQL string (INV-7).
  defp fetch_and_lock_task(repo, task_id, prefix) do
    Task
    |> where([t], t.id == ^task_id)
    |> lock("FOR UPDATE")
    |> repo.one(prefix: prefix)
    |> case do
      nil -> {:error, :task_not_found}
      %Task{status: :pending} = task -> {:ok, task}
      %Task{status: status} -> {:error, {:task_not_pending, status}}
    end
  end

  # M2 -- row-lock + fetch the owning instance_projections row (design doc
  # §8.1). Defensive: a PENDING task's own instance is expected to already
  # be :active by construction, but this call never assumes it.
  defp fetch_and_lock_instance_projection(repo, instance_id, prefix) do
    InstanceProjection
    |> where([p], p.instance_id == ^instance_id)
    |> lock("FOR UPDATE")
    |> repo.one(prefix: prefix)
    |> case do
      nil -> {:error, :instance_not_found}
      %InstanceProjection{status: :active} = projection -> {:ok, projection}
      %InstanceProjection{status: status} -> {:error, {:instance_not_active, status}}
    end
  end

  # M3 -- scoped state reconstruction (design doc §6): the narrowest
  # InstanceState.t() sufficient for one dispatch hop-chain seeded from a
  # single completing task, built directly from the already-durable
  # tasks/tokens/instance_projections rows -- not a full REQ-053 event-log
  # replay (design doc §6, MAJOR OQ-2).
  defp build_snapshot_and_state(repo, %Task{} = task, %InstanceProjection{} = projection, prefix) do
    with {:ok, graph} <- fetch_graph(task.instance_id, prefix) do
      active_token_records = load_active_tokens(repo, task.instance_id, prefix)
      active_tokens = Enum.map(active_token_records, &to_pure_token/1)

      with {:ok, own_token} <- find_token_for_task(task, active_tokens) do
        pending_task_tokens = load_pending_task_tokens(repo, task.instance_id, prefix)
        seed_instance_state = build_instance_state(projection, active_tokens, pending_task_tokens)

        {:ok,
         %{
           graph: graph,
           seed_instance_state: seed_instance_state,
           original_active_tokens: active_token_records,
           own_token_id: own_token.token_id
         }}
      end
    end
  end

  # §6.1 -- the same immutable snapshot create/2 captured at instance-start
  # time, never a live re-read of process_definitions.
  defp fetch_graph(instance_id, prefix) do
    case SnapshotStore.get_by_instance_id(instance_id, prefix: prefix) do
      {:ok, snapshot} -> build_graph(snapshot.graph)
      {:error, :snapshot_not_found} -> {:error, :snapshot_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # §6.2 -- every live token of the instance, not just the completing task's
  # own: dispatch_end/3's "instance becomes :completed iff no token remains
  # live" check needs the instance's full live token set, or a
  # PARALLEL_GATEWAY-split instance's still-running sibling branches would
  # be wrongly invisible to this call.
  defp load_active_tokens(repo, instance_id, prefix) do
    TokenRecord
    |> where([t], t.instance_id == ^instance_id and t.status == :active)
    |> repo.all(prefix: prefix)
  end

  # token_id: to_string(record.id) -- the TokenRecord's own DB-generated
  # UUID, stringified, reused directly as this call's Token.t() id (design
  # doc §6.2's own reconstruction invariant, load-bearing for §9's
  # append_multi_from_existing_records/6 and §8.2's reconcile_token_records/5
  # below).
  defp to_pure_token(%TokenRecord{} = record) do
    %Token{
      token_id: to_string(record.id),
      node_id: record.node_id,
      branch_id: record.branch_id,
      waiting_child_instance_id: record.waiting_child_instance_id
    }
  end

  # §6.3 -- a nil result here is a genuine invariant violation (tasks.token_id
  # FK-references tokens.id; a row this call's own :task step just locked and
  # read PENDING from must have a live, :active tokens row), surfaced as a
  # typed error, never a MatchError.
  defp find_token_for_task(%Task{} = task, tokens) do
    case Enum.find(tokens, &(&1.token_id == to_string(task.token_id))) do
      nil -> {:error, {:missing_token_record, task.token_id}}
      token -> {:ok, token}
    end
  end

  # §6.4 -- every currently-PENDING task's token (including the one about to
  # be completed by this call, still PENDING at read time), reduced to a
  # minimal Token.t() carrying token_id and node_id (branch_id left unused at
  # its struct default).
  #
  # node_id is load-bearing here (ISS-0057 fix, docs/issues/ISS-0057.yaml):
  # TaskActivation.newly_pending_tokens/2 now diffs by the {token_id, node_id}
  # pair, not token_id alone -- a token continuing directly from one
  # :HUMAN_TASK to another keeps the same token_id but moves to a new
  # node_id, and the design doc's original §6.4 text (node_id left nil,
  # "unused") made that stale-token_id-only "previous" entry wrongly mask the
  # token's genuinely-new pending position at the next node, so no `tasks`
  # row was ever inserted for it. Populating the task's own real node_id here
  # (the node this PENDING task is actually sitting at) is what lets the pair
  # diff tell "still pending at the same node, already accounted for" apart
  # from "same token, but now pending somewhere new."
  defp load_pending_task_tokens(repo, instance_id, prefix) do
    Task
    |> where([t], t.instance_id == ^instance_id and t.status == :pending)
    |> repo.all(prefix: prefix)
    |> Enum.map(&%Token{token_id: to_string(&1.token_id), node_id: &1.node_id, branch_id: nil})
  end

  # §6.5 -- assembling the seed InstanceState.t(). join_counters is always
  # %{} (design doc §6.5, §11 INV-EE48-7, MAJOR OQ-3): no table persists
  # JoinCounter state across calls today.
  defp build_instance_state(
         %InstanceProjection{} = projection,
         active_tokens,
         pending_task_tokens
       ) do
    %InstanceState{
      instance_id: projection.instance_id,
      status: :active,
      tokens: active_tokens,
      variables: projection.variables,
      pending_task_nodes: pending_task_tokens,
      join_counters: %{}
    }
  end

  # M4 -- EE-09 variable merge (design doc §7), pure. variable_validations:
  # nil means the {:rejected, ...} branch is provably unreachable (§7) --
  # handled here anyway (never a non-exhaustive match / raise on this
  # call's own totality discipline).
  defp merge_output_variables(current_variables, output_variables) do
    case VariableMerge.merge(current_variables, output_variables, nil) do
      {:ok, new_variables, merge_events} ->
        {:ok, %{new_variables: new_variables, merge_events: merge_events}}

      {:rejected, _unchanged_variables, events} ->
        {:error, {:unexpected_variable_rejection, events}}
    end
  end

  # M5 -- the first {:complete_task, token_id} hop, then the existing
  # advance_until_stable/4 / tokens_needing_dispatch/3 worklist loop (reused
  # unchanged, design doc §1) for every subsequent {:advance_token, ...} hop.
  defp dispatch_task_completion_hop_chain(
         %{graph: graph, seed_instance_state: seed_state, own_token_id: own_token_id},
         %{new_variables: merged_variables}
       ) do
    state_with_merged_variables = %InstanceState{seed_state | variables: merged_variables}
    hop_limit = length(graph.nodes) * 4 + 10

    case Transition.transition(graph, state_with_merged_variables, {:complete_task, own_token_id}) do
      {:ok, new_instance_state, _pending_events} ->
        newly_pending =
          tokens_needing_dispatch(
            state_with_merged_variables.tokens,
            new_instance_state.tokens,
            own_token_id
          )

        advance_until_stable(graph, new_instance_state, newly_pending, hop_limit - 1)

      {:error, reason} ->
        {:error, {:transition_failed, reason}}
    end
  end

  # M6/M7 -- built together via Multi.merge/2 (the idiomatic Ecto mechanism
  # for appending Multi steps whose concrete arguments are only known once
  # earlier steps have run inside this same transaction): task activation for
  # any freshly-reached :HUMAN_TASK node(s) (design doc §9,
  # TaskActivation.append_multi_from_existing_records/6), then token-record
  # reconciliation (design doc §8.2). Neither of these two steps' own
  # callback bodies reads from `changes` once called -- both close over
  # already-resolved plain values, matching each function's own @spec.
  defp build_task_activation_and_reconciliation_multi(changes, completed_at, prefix) do
    %{
      task: task,
      snapshot_and_state: %{
        graph: graph,
        seed_instance_state: seed_state,
        original_active_tokens: original_active_tokens
      },
      transition: final_instance_state
    } = changes

    Multi.new()
    |> TaskActivation.append_multi_from_existing_records(
      task.instance_id,
      graph,
      seed_state.pending_task_nodes,
      final_instance_state,
      prefix
    )
    |> reconcile_token_records(original_active_tokens, final_instance_state, completed_at, prefix)
  end

  # §8.2 -- new function. Advances/completes existing tokens rows to match
  # final_instance_state's final token positions; a token_id present in
  # final_instance_state.tokens with no matching original record is a typed,
  # rolled-back failure (INV-EE48-8), never a silent mis-insert.
  defp reconcile_token_records(
         %Multi{} = multi,
         original_active_tokens,
         %InstanceState{} = final_instance_state,
         completed_at,
         prefix
       ) do
    Multi.run(multi, :token_reconciliation, fn repo, _changes ->
      do_reconcile_token_records(
        repo,
        original_active_tokens,
        final_instance_state.tokens,
        completed_at,
        prefix
      )
    end)
  end

  defp do_reconcile_token_records(repo, original_tokens, final_tokens, completed_at, prefix) do
    original_ids = MapSet.new(original_tokens, &to_string(&1.id))

    case Enum.find(final_tokens, &(not MapSet.member?(original_ids, &1.token_id))) do
      %Token{token_id: token_id} ->
        {:error, {:new_token_during_resume_not_supported, token_id}}

      nil ->
        final_by_id = Map.new(final_tokens, &{&1.token_id, &1})

        original_tokens
        |> Enum.reduce_while({:ok, []}, fn %TokenRecord{} = record, {:ok, acc} ->
          case reconcile_one_token_record(repo, record, final_by_id, completed_at, prefix) do
            {:ok, updated} -> {:cont, {:ok, [updated | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, records} -> {:ok, Enum.reverse(records)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp reconcile_one_token_record(
         repo,
         %TokenRecord{} = record,
         final_by_id,
         completed_at,
         prefix
       ) do
    case Map.fetch(final_by_id, to_string(record.id)) do
      {:ok, %Token{node_id: node_id}} when node_id != record.node_id ->
        update_token_record(repo, record, %{node_id: node_id}, prefix)

      {:ok, _unchanged} ->
        {:ok, record}

      :error ->
        update_token_record(
          repo,
          record,
          %{status: :completed, completed_at: completed_at},
          prefix
        )
    end
  end

  defp update_token_record(repo, %TokenRecord{} = record, attrs, prefix) do
    record
    |> TokenRecord.advance_changeset(attrs)
    |> repo.update(prefix: prefix)
  end

  # M8 -- flips the tasks row to COMPLETED (design doc §8, table row M8).
  # output_variables here is the caller's original, unmerged map -- the
  # task's own record of what it submitted.
  defp complete_task_row(repo, %Task{} = task, actor_id, output_variables, completed_at, prefix) do
    attrs = %{
      status: :completed,
      completed_by: actor_id,
      completed_at: completed_at,
      output_variables: output_variables
    }

    task
    |> Task.complete_changeset(attrs)
    |> repo.update(prefix: prefix)
  end

  # M9 -- appends the TASK_COMPLETED event (design doc §10, EE-04 AC1,
  # REQ-025). merge_events (VARIABLE_OVERWRITTEN outcomes) are embedded as
  # informational metadata inside this one event's payload, never appended
  # as their own separate rows (INV-EE48-5).
  defp append_task_completed_event(changes, output_variables, actor_id, idempotency_key, prefix) do
    %{task: task, merge: %{merge_events: merge_events}, transition: final_instance_state} =
      changes

    payload =
      Jason.encode!(%{
        task_id: task.id,
        node_id: task.node_id,
        output_variables: output_variables,
        merged_variable_events: encode_merge_events(merge_events),
        activated_nodes: Enum.map(final_instance_state.tokens, & &1.node_id)
      })

    event_attrs = %{
      instance_id: task.instance_id,
      event_type: "TASK_COMPLETED",
      payload: payload,
      actor_id: actor_id,
      idempotency_key: idempotency_key
    }

    case EventStore.append(event_attrs, prefix: prefix) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:event_append_failed, reason}}
    end
  end

  # merge_events tuples ({:variable_overwritten, key, old, new}) aren't
  # JSON-encodable as-is (Jason has no Encoder for tuples) -- mapped to
  # plain maps for the event payload only, never persisted as their own
  # separate rows.
  defp encode_merge_events(merge_events) do
    Enum.map(merge_events, fn {:variable_overwritten, key, old_value, new_value} ->
      %{event: "variable_overwritten", key: key, old_value: old_value, new_value: new_value}
    end)
  end

  # M10 -- projection reconciliation (design doc §8.3). last_event_seq is not
  # set here -- EventStore.append/2's own update_projection/3 (M9's own
  # nested Multi) already advances it as part of the :event step above.
  defp reconcile_projection(
         repo,
         %InstanceProjection{} = projection,
         %InstanceState{} = final_instance_state,
         completed_at,
         prefix
       ) do
    attrs = %{
      status: final_instance_state.status,
      current_nodes: Enum.map(final_instance_state.tokens, & &1.node_id),
      variables: final_instance_state.variables
    }

    attrs =
      if final_instance_state.status == :completed do
        Map.put(attrs, :completed_at, completed_at)
      else
        attrs
      end

    projection
    |> InstanceProjection.update_changeset(attrs)
    |> repo.update(prefix: prefix)
  end

  # ---------------------------------------------------------------------
  # Result assembly (design doc §8's table + §3's complete_result()).
  # ---------------------------------------------------------------------

  defp interpret_complete_result(
         {:ok,
          %{
            task: %Task{} = task,
            transition: %InstanceState{} = final_instance_state,
            task_complete: %Task{} = completed_task
          }}
       ) do
    {:ok,
     %{
       task_id: task.id,
       instance_id: task.instance_id,
       instance_status: final_instance_state.status,
       current_nodes: Enum.map(final_instance_state.tokens, & &1.node_id),
       variables: final_instance_state.variables,
       completed_at: completed_task.completed_at
     }}
  end

  # Catch-all -- every Multi step's own callback above already maps its
  # failure to the exact error shape complete_error() promises (or passes a
  # raw changeset/term() through, matching those catch-all clauses); this
  # just unwraps Ecto.Multi's {:error, failed_step, reason, changes_so_far}
  # envelope around whatever reason each step already produced.
  defp interpret_complete_result({:error, _failed_step, reason, _changes}) do
    {:error, reason}
  end
end
