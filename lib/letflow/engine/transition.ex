defmodule Letflow.Engine.Transition do
  @moduledoc """
  Pure transition kernel — ports `transition.zig`'s `transition()` (EE-02,
  `lib/letflow/design/req044-transition-kernel.md`, the gate-approved design
  this module implements). `transition/3`'s own header contract, quoted from
  `transition.zig`'s own header: **"All state is passed in; all output is
  returned. No DB, no network, no clock."**

  REQ-044 built the skeleton plus the 3 non-gateway node-type transitions
  (`:START`, `:END`, `:HUMAN_TASK`). REQ-050 (this requirement) replaces the
  `:EXCLUSIVE_GATEWAY` stub with the real declared-order, default-last,
  CEL-condition dispatch (`dispatch_exclusive_gateway/4`, EE-05,
  `lib/letflow/design/req050-exclusive-gateway-cel.md`), evaluating each
  condition via `Letflow.Engine.Expr.evaluate_condition/2`. `:PARALLEL_GATEWAY`
  (REQ-051) remains a named stub extension point (`dispatch_parallel_gateway/4`)
  that a later requirement's `ELIXIR-DEV` replaces without touching
  `dispatch_node/4`'s outer dispatch structure. `:SERVICE_TASK`, `:TIMER`,
  and `:SUB_PROCESS` (the 3 remaining variants of
  `Letflow.Definitions.Graph.node_type()`) fall through a single generic
  catch-all clause, kept total rather than raising.

  See `Letflow.Engine.InstanceState`'s moduledoc for two verbatim notes this
  design carries forward from the requirement text: the Zig `std.json.ObjectMap`
  allocator-ownership divergence, and the explicit REQ-043 dependency-ordering
  statement (this module and its two sibling files depend on REQ-028/REQ-029
  only, not on REQ-043's not-yet-built schema modules).

  ## Purity (AC1)

  `Letflow.Engine.Transition`, `Letflow.Engine.InstanceState`, and
  `Letflow.Engine.Token` depend on Elixir/Erlang stdlib only (`Enum`, `Map`,
  `Kernel`). No `alias Letflow.Repo`, no `import Ecto.Query`, no
  `Ecto.Changeset` anywhere in any of the 3 files. No `Logger.*` call. No
  clock read (`DateTime.utc_now/0`, `System.os_time/1`, `System.system_time/1`,
  or equivalent). No `File.*`/`HTTPoison`/`Req.*`/`:httpc`/process-mailbox call
  (`GenServer.call`, `send`, `receive`) anywhere in `transition/3`'s call
  graph, including every private `dispatch_*` function it calls into.

  Verification (grep/`mix xref`-checkable, matching the precedent
  `Letflow.Definitions.Graph`'s own design already established):

  ```bash
  grep -n "Repo\\.\\|Logger\\.\\|DateTime\\.\\|System\\.os_time\\|System\\.system_time\\|HTTPoison\\|Req\\.\\|File\\.\\|:rand\\.\\|:crypto\\." lib/letflow/engine/instance_state.ex lib/letflow/engine/token.ex lib/letflow/engine/transition.ex
  ```

  must return zero matches.

  ## Determinism (AC2)

  Calling `transition(definition_snapshot, instance_state, event)` twice with
  `==`-equal arguments returns `==`-equal results, both times. Every decision
  inside the dispatch is a pure function of its typed input alone: token/node
  lookups are ordinary linear scans over argument-supplied lists (no external
  state, no randomness, no `:ets`/process-mailbox read); `:START`'s "first
  outgoing edge in declaration order" is a deterministic function of
  `definition_snapshot.edges`'s own list order, itself part of the argument;
  no clock/`:rand`/`:crypto`/UUID-generation call appears anywhere in this
  module's call graph — every id (`token_id`, `instance_id`) is always
  supplied by the caller, never minted here.

  ## Single hop per call

  One `transition/3` call processes exactly one token through exactly one
  node-type dispatch and returns — it never recursively cascades a token
  through a chain of nodes within one call. A `:START` node whose outgoing
  edge leads directly into another pass-through node requires two separate
  `transition/3` calls, each driven by its own `{:advance_token, token_id}`
  event from the caller (design doc §5).
  """

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.Graph.Node
  alias Letflow.Engine.Expr
  alias Letflow.Engine.InstanceState
  alias Letflow.Engine.Token

  @typedoc """
  One event this requirement's dispatch reacts to. `{:advance_token,
  token_id}` is the only constructor REQ-044 needs: "move the token
  identified by `token_id` one step according to whatever node type it
  currently occupies." Deliberately not a closed enumeration — every later
  EE-* requirement that needs its own event shape (task completion,
  cancellation, a timer firing) adds its own tagged-tuple constructor to this
  same union (design doc §4, §12.5).
  """
  @type transition_event :: {:advance_token, token_id :: String.t()}

  @typedoc """
  The tagged union `transition.zig` declares for EE-06/EE-07 split/join
  payloads. Declared as `term()` here, a deliberate placeholder rather than a
  fabricated tagged-tuple union — its real shape lives in `engine.md`'s
  EE-06/EE-07 sections, not reconstructable in this environment (design doc
  §4, §12.5). None of this requirement's own dispatch cases ever construct a
  `pending_event()` value; every case implemented here returns
  `pending_events: []`. REQ-050/REQ-051 narrow this to a real closed union
  once they add gateway split/join payloads.
  """
  @type pending_event :: term()

  @typedoc """
  Every failure `transition/3` can return. `:unknown_event_type` and
  `:unknown_node_id` are the two explicit error paths the requirement text
  names; `:unknown_token_id` is this module's own defensive totality
  addition (a stale/nonexistent `token_id` is exactly as plausible an input
  as a stale/nonexistent `node_id`); `:gateway_not_yet_implemented` and
  `:node_type_not_yet_implemented` are the stub/catch-all extension points
  `dispatch_exclusive_gateway/4`, `dispatch_parallel_gateway/4`, and the
  generic node-type catch-all use (design doc §4, §7).
  """
  @type transition_error ::
          {:unknown_event_type, event :: term()}
          | {:unknown_token_id, token_id :: String.t()}
          | {:unknown_node_id, node_id :: String.t()}
          | {:gateway_not_yet_implemented, node_type :: atom(), node_id :: String.t()}
          | {:node_type_not_yet_implemented, node_type :: atom(), node_id :: String.t()}
          | {:no_matching_edge, node_id :: String.t(),
             evaluated_conditions :: [evaluated_condition()]}

  @typedoc """
  One entry per non-default outgoing edge of an `:EXCLUSIVE_GATEWAY` whose
  condition was actually evaluated before dispatch gave up (REQ-050 design
  doc §3). `condition` is always the edge's original CEL-syntax string
  (`Edge.t().condition`), never the translated expr-syntax string or the
  parsed AST — an operator reading a persisted error tuple sees the same
  condition text authored in the definition graph.
  """
  @type evaluated_condition :: %{
          edge_id: String.t(),
          condition: String.t(),
          result: boolean()
        }

  @doc """
  Advances one token by one hop according to `event`, resolving its current
  node against `definition_snapshot` and dispatching on that node's
  `node_type`. Never raises: an unrecognized `event` shape, an unknown
  `token_id`, or a token positioned on a `node_id` absent from
  `definition_snapshot` all return a named `{:error, transition_error()}`
  tuple instead of crashing (design doc §6, §7).
  """
  @spec transition(Graph.t(), InstanceState.t(), transition_event()) ::
          {:ok, InstanceState.t(), [pending_event()]}
          | {:error, transition_error()}
  def transition(%Graph{} = definition_snapshot, %InstanceState{} = instance_state, event) do
    case event do
      {:advance_token, token_id} ->
        case find_token(instance_state.tokens, token_id) do
          nil ->
            {:error, {:unknown_token_id, token_id}}

          token ->
            case find_node(definition_snapshot.nodes, token.node_id) do
              nil ->
                {:error, {:unknown_node_id, token.node_id}}

              node ->
                dispatch_node(definition_snapshot, instance_state, token, node)
            end
        end

      other ->
        {:error, {:unknown_event_type, other}}
    end
  end

  # Dispatches one already-resolved `token`/`node` pair to the behavior for
  # `node.node_type` -- the 5-way (+1 catch-all) table from design doc §6.
  # Every clause below is a specialization of this one @spec -- no per-clause
  # @spec is separately declared, matching graph.ex's one-@spec-per-function-
  # name convention even where the implementation has multiple pattern-
  # matched clauses.
  @spec dispatch_node(Graph.t(), InstanceState.t(), Token.t(), Node.t()) ::
          {:ok, InstanceState.t(), [pending_event()]}
          | {:error, transition_error()}
  defp dispatch_node(definition_snapshot, instance_state, token, %Node{node_type: :START} = node) do
    dispatch_start(definition_snapshot, instance_state, token, node)
  end

  defp dispatch_node(_definition_snapshot, instance_state, token, %Node{node_type: :END} = node) do
    dispatch_end(instance_state, token, node)
  end

  defp dispatch_node(
         _definition_snapshot,
         instance_state,
         token,
         %Node{node_type: :HUMAN_TASK} = node
       ) do
    dispatch_human_task(instance_state, token, node)
  end

  defp dispatch_node(
         definition_snapshot,
         instance_state,
         token,
         %Node{node_type: :EXCLUSIVE_GATEWAY} = node
       ) do
    dispatch_exclusive_gateway(definition_snapshot, instance_state, token, node)
  end

  defp dispatch_node(
         definition_snapshot,
         instance_state,
         token,
         %Node{node_type: :PARALLEL_GATEWAY} = node
       ) do
    dispatch_parallel_gateway(definition_snapshot, instance_state, token, node)
  end

  # Catch-all: :SERVICE_TASK, :TIMER, :SUB_PROCESS (the 3 remaining variants
  # of Letflow.Definitions.Graph.node_type()'s 8-variant union not part of
  # this requirement's 5-way dispatch), and any node whose node_type is not
  # one of the 8 known atoms at all. Necessary for transition/3 to be total
  # over every value Node.t().node_type can actually hold -- a partial
  # match with no catch-all clause would raise on any of these, violating
  # the purity contract's "never raise" bar (design doc §6.6).
  defp dispatch_node(_definition_snapshot, _instance_state, _token, %Node{
         node_type: node_type,
         id: node_id
       }) do
    {:error, {:node_type_not_yet_implemented, node_type, node_id}}
  end

  # --- :START (design doc §6.1) ----------------------------------------------

  # Advances the token onto the target of its first outgoing edge in
  # declaration order. A structurally-valid graph (CHK-04, REQ-028)
  # guarantees at least one outgoing edge from START; the `nil` branch below
  # is a defensive, never-raising fallback for a `definition_snapshot` that
  # violates that upstream invariant, not a literal AC3 case -- flagged here
  # per the design doc's own §7.3 precedent for defensive additions beyond
  # the literal acceptance criteria.
  defp dispatch_start(
         definition_snapshot,
         %InstanceState{} = instance_state,
         %Token{} = token,
         node
       ) do
    case Enum.find(definition_snapshot.edges, &(&1.source == node.id)) do
      nil ->
        {:error, {:unknown_node_id, node.id}}

      edge ->
        new_token = %Token{token | node_id: edge.target}
        new_tokens = replace_token(instance_state.tokens, new_token)
        {:ok, %InstanceState{instance_state | tokens: new_tokens}, []}
    end
  end

  # --- :END (design doc §6.2) -------------------------------------------------

  # Removes the affected token from `tokens`. Instance status becomes
  # `:completed` iff no token remains live afterward; otherwise unchanged
  # (other branches may still be executing, relevant once REQ-051's
  # PARALLEL_GATEWAY split can produce more than one live token).
  defp dispatch_end(%InstanceState{} = instance_state, token, _node) do
    remaining_tokens = Enum.reject(instance_state.tokens, &(&1.token_id == token.token_id))

    new_status = if remaining_tokens == [], do: :completed, else: instance_state.status

    {:ok, %InstanceState{instance_state | tokens: remaining_tokens, status: new_status}, []}
  end

  # --- :HUMAN_TASK (design doc §6.3) ------------------------------------------

  # The token's position is not changed -- a HUMAN_TASK node has no
  # automatic outgoing traversal. The same Token.t() value is appended to
  # pending_task_nodes; this is the only dispatch clause that ever appends
  # to it (the guard for REQ-047's future tasks-row materialization).
  defp dispatch_human_task(%InstanceState{} = instance_state, token, _node) do
    new_pending = instance_state.pending_task_nodes ++ [token]
    {:ok, %InstanceState{instance_state | pending_task_nodes: new_pending}, []}
  end

  # --- :EXCLUSIVE_GATEWAY (REQ-050 design doc §5, EE-05) ----------------------

  # Declared-order, default-last, first-true-wins dispatch. Relies on
  # REQ-029's CHK-13..CHK-16 invariants (design doc §6) without
  # re-validating them here: a default edge never carries a condition, at
  # most one default edge exists per gateway, and every non-default
  # outgoing edge carries a non-empty condition string.
  @spec dispatch_exclusive_gateway(Graph.t(), InstanceState.t(), Token.t(), Node.t()) ::
          {:ok, InstanceState.t(), [pending_event()]}
          | {:error,
             {:no_matching_edge, node_id :: String.t(),
              evaluated_conditions :: [evaluated_condition()]}}
  defp dispatch_exclusive_gateway(
         definition_snapshot,
         %InstanceState{} = instance_state,
         %Token{} = token,
         node
       ) do
    outgoing_edges = Enum.filter(definition_snapshot.edges, &(&1.source == node.id))
    {conditioned_edges, default_edges} = Enum.split_with(outgoing_edges, &(&1.is_default != true))
    default_edge = List.first(default_edges)

    case evaluate_conditioned_edges(conditioned_edges, instance_state.variables) do
      {:match, edge} ->
        advance_token(instance_state, token, edge.target)

      {:no_match, evaluated_conditions} ->
        case default_edge do
          nil ->
            {:error, {:no_matching_edge, node.id, evaluated_conditions}}

          edge ->
            advance_token(instance_state, token, edge.target)
        end
    end
  end

  # Walks conditioned_edges in declared order, short-circuiting on the
  # first edge whose Expr.evaluate_condition/2 call returns true. A
  # condition that raises a runtime error (translation, parse, or eval
  # error, including the unsupported-CEL-feature case) is folded into
  # `false` by Expr.evaluate_condition/2 itself -- there is no separate
  # "error" branch here, matching design doc §5.2's uniform catch-false
  # rule.
  @spec evaluate_conditioned_edges([Graph.Edge.t()], map()) ::
          {:match, Graph.Edge.t()} | {:no_match, [evaluated_condition()]}
  defp evaluate_conditioned_edges(conditioned_edges, variables) do
    evaluate_conditioned_edges(conditioned_edges, variables, [])
  end

  @spec evaluate_conditioned_edges([Graph.Edge.t()], map(), [evaluated_condition()]) ::
          {:match, Graph.Edge.t()} | {:no_match, [evaluated_condition()]}
  defp evaluate_conditioned_edges([], _variables, acc), do: {:no_match, Enum.reverse(acc)}

  defp evaluate_conditioned_edges([edge | rest], variables, acc) do
    if Expr.evaluate_condition(edge.condition, variables) do
      {:match, edge}
    else
      entry = %{edge_id: edge.id, condition: edge.condition, result: false}
      evaluate_conditioned_edges(rest, variables, [entry | acc])
    end
  end

  # Advances token onto target_node_id, preserving instance_state's other
  # fields -- same shape as dispatch_start/4's success path.
  @spec advance_token(InstanceState.t(), Token.t(), String.t()) ::
          {:ok, InstanceState.t(), [pending_event()]}
  defp advance_token(%InstanceState{} = instance_state, %Token{} = token, target_node_id) do
    new_token = %Token{token | node_id: target_node_id}
    new_tokens = replace_token(instance_state.tokens, new_token)
    {:ok, %InstanceState{instance_state | tokens: new_tokens}, []}
  end

  # --- :PARALLEL_GATEWAY stub (design doc §6.5, REQ-051's extension point) --

  # Same shape and rationale as dispatch_exclusive_gateway/4 above, for
  # REQ-051 (EE-06 split + EE-07 join) to replace instead.
  @spec dispatch_parallel_gateway(Graph.t(), InstanceState.t(), Token.t(), Node.t()) ::
          {:error, {:gateway_not_yet_implemented, :PARALLEL_GATEWAY, node_id :: String.t()}}
  defp dispatch_parallel_gateway(_definition_snapshot, _instance_state, _token, node) do
    {:error, {:gateway_not_yet_implemented, :PARALLEL_GATEWAY, node.id}}
  end

  # --- shared lookups (design doc §6, §7.2, §7.3) -----------------------------

  @spec find_token([Token.t()], String.t()) :: Token.t() | nil
  defp find_token(tokens, token_id), do: Enum.find(tokens, &(&1.token_id == token_id))

  @spec find_node([Node.t()], String.t()) :: Node.t() | nil
  defp find_node(nodes, node_id), do: Enum.find(nodes, &(&1.id == node_id))

  # Replaces the token in `tokens` whose token_id matches `new_token`'s,
  # preserving list order otherwise.
  @spec replace_token([Token.t()], Token.t()) :: [Token.t()]
  defp replace_token(tokens, %Token{token_id: token_id} = new_token) do
    Enum.map(tokens, fn
      %Token{token_id: ^token_id} -> new_token
      other -> other
    end)
  end
end
