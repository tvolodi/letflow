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

  ## Disclosed limitation: only `:HUMAN_TASK`/`:END` first nodes succeed today

  `create/2` calls `Letflow.Engine.Transition.transition/3` twice (AC7):
  once to advance the root token off `:START`, and once more — driven by
  `Transition`'s own "single hop per call" contract (its moduledoc) — to
  actually dispatch whatever node the token lands on. Gateway/service-task
  dispatch is not yet shipped (REQ-050/051/056/057 are not dependencies of
  this requirement), so `create/2` fails with
  `{:error, {:activation_failed, {:gateway_not_yet_implemented, ...}}}` (or
  `:node_type_not_yet_implemented`) — writing nothing — for any definition
  whose first node past `:START` is anything other than `:HUMAN_TASK` or
  `:END`. This is a disclosed, temporary capability gap (design doc §9
  OQ-1a), not a defect this module attempts to work around.

  ## `tenant_id` is validated, never persisted

  `attrs` never accepts a `:tenant_id` (or `"tenant_id"`) key.
  `opts[:prefix]` is resolved via
  `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` purely to prove it
  names a well-formed tenant schema before any I/O — the derived value is
  not stored anywhere by this module, since none of
  `instance_projections`/`tokens`/`tasks` carries a `tenant_id` column
  (Decision 0006 D2).
  """

  alias Ecto.Multi
  alias Letflow.Definitions
  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.SnapshotStore
  alias Letflow.Engine.InstanceState
  alias Letflow.Engine.Token
  alias Letflow.Engine.TokenRecord
  alias Letflow.Engine.Transition
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
         {:ok, new_instance_state} <- activate(instance_id, definition, initial_variables) do
      persist(
        instance_id,
        definition,
        initial_variables,
        correlation_key,
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

      case Transition.transition(graph, instance_state, {:advance_token, token_id}) do
        {:ok, off_start_state, _pending_events} ->
          dispatch_landing_node(graph, off_start_state, token_id)

        {:error, reason} ->
          {:error, {:activation_failed, reason}}
      end
    end
  end

  # Transition/3's own "single hop per call" contract (its moduledoc) means the
  # call above only moves the root token off :START onto the target of its
  # first outgoing edge -- it never itself dispatches that target node's own
  # behavior. A second, caller-driven transition/3 call against the same
  # token_id is required to actually dispatch whatever node the token landed
  # on: for :HUMAN_TASK this is a harmless no-op hop that appends the token to
  # pending_task_nodes (dispatch_human_task/3); for :END it is what actually
  # removes the token and flips status to :completed (dispatch_end/3); for a
  # gateway/unimplemented node type it is what surfaces
  # :gateway_not_yet_implemented / :node_type_not_yet_implemented, matching
  # design doc §9 OQ-1a's disclosed "only :HUMAN_TASK/:END first nodes
  # succeed" boundary -- a single hop alone left both :END and gateway first
  # nodes silently mishandled (:END never completing; a gateway silently
  # accepted as an ordinary token position).
  defp dispatch_landing_node(graph, off_start_state, token_id) do
    case Transition.transition(graph, off_start_state, {:advance_token, token_id}) do
      {:ok, new_instance_state, _pending_events} -> {:ok, new_instance_state}
      {:error, reason} -> {:error, {:activation_failed, reason}}
    end
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
      finalize_instance_projection(repo, projection, new_instance_state.status, prefix)
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

  # M2 -- insert the root tokens row, post-landing-dispatch node_id, branch_id
  # == instance_id (req043 §3.2's root-branch convention). Must run after M1
  # (tokens.instance_id's FK target must already exist in the same
  # transaction). An empty token list means the root token already reached
  # :END and was removed by dispatch_end/3 (design doc §9 OQ-1a's :END
  # success case) -- no tokens row at all for this instance, matching the
  # test's own explicit assertion that a same-call :END completion leaves
  # zero rows in `tokens`, not one stranded at "end".
  defp insert_token_records(_repo, _instance_id, [], _prefix), do: {:ok, []}

  defp insert_token_records(repo, instance_id, [%Token{} = token], prefix) do
    case insert_token_record(repo, instance_id, token, prefix) do
      {:ok, record} -> {:ok, [record]}
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
  defp finalize_instance_projection(_repo, %InstanceProjection{} = projection, :active, _prefix) do
    {:ok, projection}
  end

  defp finalize_instance_projection(repo, %InstanceProjection{} = projection, :completed, prefix) do
    attrs = %{status: :completed, completed_at: DateTime.utc_now()}

    projection
    |> InstanceProjection.update_changeset(attrs)
    |> repo.update(prefix: prefix)
    |> case do
      {:ok, %InstanceProjection{} = updated} -> {:ok, updated}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
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
end
