defmodule Letflow.Definitions.Graph do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Graph structural validator — the pure, no-I/O validation core of a process
  definition's `graph` (`{"nodes": [...], "edges": [...]}` shape). Ported from
  `src/definition/graph.zig`'s `validateGraph()` (R-Co,
  `C:\\Users\\tvolo\\dev\\ai-dala\\R-Co\\src\\definition\\graph.zig`, lines ~191-384)
  per `src/design/definition.md`'s "Named validation checks (PD-02)" table and
  `lib/letflow/design/req028-graph-structural-validator.md` (the gate-approved
  design this module implements).

  PROVENANCE (historical, not current decision authority):
  `Letflow.Definitions.Graph` *is* the graph struct being validated
  (`%Letflow.Definitions.Graph{nodes: [...], edges: [...]}`, mirroring
  `graph.zig`'s `DefinitionGraph`) and also hosts `validate_graph/1` plus the 8
  named checks — see the design doc §1 for why the struct and the validator
  share one module name. `Node`, `Edge`, and `Violation` are nested modules in
  this same file (design doc §1): they have no meaning or reuse outside graph
  validation.

  ## Purity (AC5)

  This module and everything in its call graph depend on Elixir/Erlang stdlib
  only (`Enum`, `Map`, `MapSet`, `Kernel`) — no `Letflow.Repo`, no
  `Ecto.Changeset`, no `Logger.*`, no clock read, no HTTP/file call, no
  process-mailbox call. `validate_graph/1` cannot fail in the usual
  `:ok | {:error, _}` sense: a structurally-invalid input graph is a
  legitimate output value (`%{valid: false, violations: [...]}`), not a
  function failure — see design doc §4 for why this diverges from
  `backend_developer_guide.md` §3.5's usual convention.

  ## The 8 named checks (CHK-01..CHK-08, 9 violation codes)

  All 8 checks run unconditionally against the same, unmodified input graph
  and their results are concatenated in a fixed order — no check
  short-circuits on, or depends on, another's outcome (Key invariant 5). See
  design doc §5 for the exact trigger/message table, §6 for the DFS-based
  cycle check (CHK-06), and §7 for the never-short-circuit / check-independence
  proof.

  ## Node-attribute and edge-condition checks (CHK-09..CHK-17, CHK-19, REQ-029, ISS-0056)

  `validate_node_attributes/1` (PD-05) and `validate_edge_conditions/1`
  (PD-06) are separate public functions, not folded into `validate_graph/1`
  — see `lib/letflow/design/req029-node-attribute-edge-condition-validators.md`
  §1 for the full rationale. **Ordering contract, enforced entirely by the
  caller, not by this module:** both functions assume — but do not verify —
  that `validate_graph/1` has already been called and returned
  `valid: true` on the same graph value. Neither function calls
  `validate_graph/1` internally or checks structural validity as a
  precondition; calling either out of order, or against a structurally
  invalid graph, will not crash but may produce misleading or redundant
  violations. Enforcing the actual "run PD-05/PD-06 only after
  `validate_graph/1` succeeds" ordering is the caller's job (intended to be
  `Letflow.Definitions.create/1`, REQ-030, once it exists).

  ## SUB_PROCESS interface check (CHK-18, REQ-032)

  CHK-18 (`check_sub_process_interface/1`, REQ-032) delegates to
  `Letflow.Definitions.SubProcessInterface` for the SUB_PROCESS node type's
  optional `interface` attribute — see that module's moduledoc for the full
  SPC-02 contract and the explicit SPC-01-out-of-scope statement.
  """

  @type node_type ::
          :START
          | :END
          | :HUMAN_TASK
          | :SERVICE_TASK
          | :EXCLUSIVE_GATEWAY
          | :PARALLEL_GATEWAY
          | :TIMER
          | :SUB_PROCESS

  defmodule Node do
    @moduledoc """
    PROVENANCE (historical, not current decision authority):
    A single node in a `Letflow.Definitions.Graph` (ports `graph.zig`'s
    `GraphNode`). Plain struct, not an `Ecto.Schema` — see design doc §2.1.
    """

    @enforce_keys [:id, :node_type]
    defstruct [:id, :node_type, label: nil, attributes: nil]

    @type t :: %__MODULE__{
            id: String.t(),
            node_type: Letflow.Definitions.Graph.node_type(),
            label: String.t() | nil,
            attributes: map() | nil
          }
  end

  defmodule Edge do
    @moduledoc """
    PROVENANCE (historical, not current decision authority):
    A single directed edge in a `Letflow.Definitions.Graph` (ports
    `graph.zig`'s `GraphEdge`). Plain struct, not an `Ecto.Schema` — see design
    doc §2.2. `condition`/`is_default` are carried on the struct but not read
    by any of REQ-028's 8 checks — consumed starting at REQ-029.
    """

    @enforce_keys [:id, :source, :target]
    defstruct [:id, :source, :target, condition: nil, is_default: false]

    @type t :: %__MODULE__{
            id: String.t(),
            source: String.t(),
            target: String.t(),
            condition: String.t() | nil,
            is_default: boolean()
          }
  end

  defmodule Violation do
    @moduledoc """
    PROVENANCE (historical, not current decision authority):
    One structural-validation failure returned by `validate_graph/1` (ports
    `graph.zig`'s `Violation`). `code` is a lowercase `snake_case` atom rather
    than `graph.zig`'s SCREAMING_SNAKE_CASE string — see design doc §2.3 for
    the rationale.
    """

    @enforce_keys [:code, :message]
    defstruct [:code, :message]

    @type code ::
            :missing_start_node
            | :multiple_start_nodes
            | :missing_end_node
            | :dangling_edge
            | :isolated_node
            | :duplicate_node_id
            | :cycle_without_gateway
            | :node_limit_exceeded
            | :edge_limit_exceeded
            | :missing_role
            | :missing_endpoint
            | :invalid_timeout
            | :invalid_duration
            | :missing_edge_condition
            | :unexpected_edge_condition
            | :default_with_condition
            | :multiple_default_edges
            | :invalid_cel_syntax
            | :sub_process_interface_not_object
            | :sub_process_interface_inputs_not_array
            | :sub_process_interface_outputs_not_array
            | :sub_process_interface_entry_invalid
            | :sub_process_interface_schema_invalid
            | :sub_process_interface_duplicate_name
            | :human_task_no_fallback_edge

    @type t :: %__MODULE__{
            code: code(),
            message: String.t()
          }
  end

  # The two NodeType variants CHK-06's gateway exemption tests membership
  # against (design doc §3).
  @gateway_types MapSet.new([:EXCLUSIVE_GATEWAY, :PARALLEL_GATEWAY])

  @max_nodes 500
  @max_edges 2000

  defstruct nodes: [], edges: []

  @type t :: %__MODULE__{
          nodes: [Node.t()],
          edges: [Edge.t()]
        }

  @type result :: %{valid: boolean(), violations: [Violation.t()]}

  @doc """
  Converts a plain map (`%{"nodes" => [...], "edges" => [...]}` — a process
  definition's stored `graph` column, or an instance snapshot's captured
  `graph`) into a `%Graph{}` struct. Moved here, as a public function, from
  `Letflow.Definitions`'s own private `graph_struct_from_map/1`
  (`lib/letflow/design/req045-instance-start-engine-shell.md` §8) so
  `Letflow.Engine.create/2` (REQ-045) can perform the identical conversion
  without reaching across a module boundary into a private function — one
  authoritative implementation, not a second private duplicate.
  `Letflow.Definitions.create/2` and `activate/2` are refactored to call this
  function instead of their own former private copy; behavior is unchanged.

  An unrecognized `"node_type"` string maps to `:unknown_node_type` rather
  than failing outright — this function's own structural validator
  (`validate_graph/1`) is what actually rejects a node of that type, not
  this conversion step. A missing/malformed `"nodes"`/`"edges"` list, or a
  node/edge missing a required string field (`"id"`, and `"node_type"` for a
  node or `"source"`/`"target"` for an edge), is `:error`.
  """
  @spec from_map(graph_map :: map()) :: {:ok, t()} | :error
  def from_map(graph_map) when is_map(graph_map) and not is_struct(graph_map) do
    with {:ok, nodes_raw} <- fetch_graph_list(graph_map, "nodes"),
         {:ok, edges_raw} <- fetch_graph_list(graph_map, "edges"),
         {:ok, nodes} <- build_graph_nodes(nodes_raw),
         {:ok, edges} <- build_graph_edges(edges_raw) do
      {:ok, %__MODULE__{nodes: nodes, edges: edges}}
    else
      _ -> :error
    end
  end

  def from_map(_not_a_map), do: :error

  @node_type_map %{
    "START" => :START,
    "END" => :END,
    "HUMAN_TASK" => :HUMAN_TASK,
    "SERVICE_TASK" => :SERVICE_TASK,
    "EXCLUSIVE_GATEWAY" => :EXCLUSIVE_GATEWAY,
    "PARALLEL_GATEWAY" => :PARALLEL_GATEWAY,
    "TIMER" => :TIMER,
    "SUB_PROCESS" => :SUB_PROCESS
  }

  defp fetch_graph_list(map, key) do
    case Map.get(map, key) do
      list when is_list(list) -> {:ok, list}
      _ -> :error
    end
  end

  defp build_graph_nodes(nodes_raw) do
    nodes_raw
    |> Enum.reduce_while({:ok, []}, fn node, {:ok, acc} ->
      case build_graph_node(node) do
        {:ok, built} -> {:cont, {:ok, [built | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> finish_graph_build()
  end

  defp build_graph_node(%{} = node) when not is_struct(node) do
    with id when is_binary(id) <- Map.get(node, "id"),
         node_type_str when is_binary(node_type_str) <- Map.get(node, "node_type") do
      {:ok,
       %Node{
         id: id,
         node_type: Map.get(@node_type_map, node_type_str, :unknown_node_type),
         label: Map.get(node, "label"),
         attributes: Map.get(node, "attributes")
       }}
    else
      _ -> :error
    end
  end

  defp build_graph_node(_not_a_map), do: :error

  defp build_graph_edges(edges_raw) do
    edges_raw
    |> Enum.reduce_while({:ok, []}, fn edge, {:ok, acc} ->
      case build_graph_edge(edge) do
        {:ok, built} -> {:cont, {:ok, [built | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> finish_graph_build()
  end

  defp build_graph_edge(%{} = edge) when not is_struct(edge) do
    with id when is_binary(id) <- Map.get(edge, "id"),
         source when is_binary(source) <- Map.get(edge, "source"),
         target when is_binary(target) <- Map.get(edge, "target") do
      {:ok,
       %Edge{
         id: id,
         source: source,
         target: target,
         condition: Map.get(edge, "condition"),
         is_default: Map.get(edge, "is_default", false)
       }}
    else
      _ -> :error
    end
  end

  defp build_graph_edge(_not_a_map), do: :error

  defp finish_graph_build({:ok, reversed_acc}), do: {:ok, Enum.reverse(reversed_acc)}
  defp finish_graph_build(:error), do: :error

  @doc """
  Runs all 8 named structural checks (CHK-01..CHK-08) against `graph` and
  returns every violation found — never short-circuits on the first failure
  (Key invariant 5; design doc §7.1). `result.valid == (result.violations == [])`
  holds by construction.
  """
  @spec validate_graph(t()) :: result()
  def validate_graph(%__MODULE__{} = graph) do
    violations =
      [
        &check_node_limit/1,
        &check_edge_limit/1,
        &check_duplicate_node_ids/1,
        &check_start_node/1,
        &check_end_node/1,
        &check_dangling_edges/1,
        &check_isolated_nodes/1,
        &check_cycles/1
      ]
      |> Enum.flat_map(& &1.(graph))

    %{valid: violations == [], violations: violations}
  end

  @doc """
  Runs the 4 per-node-type attribute checks (CHK-09..CHK-12, PD-05) plus
  CHK-18 (`check_sub_process_interface/1`, REQ-032 — SUB_PROCESS's optional
  `interface` attribute, delegated to `Letflow.Definitions.SubProcessInterface`)
  against every node in `graph` and returns every violation found — never
  short-circuits, same unconditional-concatenation construction as
  `validate_graph/1`. Does not call `validate_graph/1` and does not verify
  structural validity as a precondition — see the moduledoc's "Ordering
  contract" note.
  """
  @spec validate_node_attributes(t()) :: result()
  def validate_node_attributes(%__MODULE__{} = graph) do
    violations =
      [
        &check_human_task_role/1,
        &check_service_task_endpoint/1,
        &check_service_task_timeout/1,
        &check_timer_duration/1,
        &check_sub_process_interface/1
      ]
      |> Enum.flat_map(& &1.(graph))

    %{valid: violations == [], violations: violations}
  end

  @doc """
  Runs the 6 edge-condition/CEL checks (CHK-13..17 and CHK-19, PD-06) against
  every edge in `graph` and returns every violation found — never
  short-circuits, same unconditional-concatenation construction as
  `validate_graph/1`. Does not call `validate_graph/1` and does not verify
  structural validity as a precondition — see the moduledoc's "Ordering
  contract" note. Total and defensive: an edge whose `source` doesn't resolve
  to any node (a dangling edge) is treated as not sourced from an
  `EXCLUSIVE_GATEWAY` or a `HUMAN_TASK` rather than raising (design doc
  §5.2, `iss-0056-human-task-fallback-edge-validation.md` §3.1).
  """
  @spec validate_edge_conditions(t()) :: result()
  def validate_edge_conditions(%__MODULE__{} = graph) do
    violations =
      [
        &check_gateway_condition_presence/1,
        &check_unpermitted_edge_condition/1,
        &check_default_condition_conflict/1,
        &check_single_default_edge/1,
        &check_cel_syntax/1,
        &check_human_task_fallback_edge/1
      ]
      |> Enum.flat_map(& &1.(graph))

    %{valid: violations == [], violations: violations}
  end

  @doc """
  Minimal *structural* CEL syntax check (design doc §6) — balanced brackets,
  balanced/terminated string literals, and no bare leading/trailing
  operator. Performs no evaluation: it never resolves variable names or
  determines what the expression would evaluate to, only whether it is
  lexically well-formed.
  """
  @spec valid_cel_syntax?(String.t()) :: boolean()
  def valid_cel_syntax?(condition) when is_binary(condition) do
    trimmed = String.trim(condition)

    cond do
      trimmed == "" -> false
      not cel_brackets_and_strings_balanced?(trimmed) -> false
      cel_starts_or_ends_with_bare_operator?(trimmed) -> false
      true -> true
    end
  end

  # CHK-07: node count must not exceed @max_nodes.
  @spec check_node_limit(t()) :: [Violation.t()]
  defp check_node_limit(%__MODULE__{nodes: nodes}) do
    count = length(nodes)

    if count > @max_nodes do
      [
        %Violation{
          code: :node_limit_exceeded,
          message: "Node count #{count} exceeds the maximum of #{@max_nodes}"
        }
      ]
    else
      []
    end
  end

  # CHK-08: edge count must not exceed @max_edges.
  @spec check_edge_limit(t()) :: [Violation.t()]
  defp check_edge_limit(%__MODULE__{edges: edges}) do
    count = length(edges)

    if count > @max_edges do
      [
        %Violation{
          code: :edge_limit_exceeded,
          message: "Edge count #{count} exceeds the maximum of #{@max_edges}"
        }
      ]
    else
      []
    end
  end

  # CHK-05: a node id equal to an earlier (lower-index) node's id is a
  # duplicate. Reported once per repeated occurrence, not once per distinct
  # id (design doc §5's CHK-05 detail).
  @spec check_duplicate_node_ids(t()) :: [Violation.t()]
  defp check_duplicate_node_ids(%__MODULE__{nodes: nodes}) do
    nodes
    |> Enum.with_index()
    |> Enum.flat_map(fn {node, index} ->
      earlier = Enum.take(nodes, index)

      if Enum.any?(earlier, &(&1.id == node.id)) do
        [%Violation{code: :duplicate_node_id, message: "Duplicate node ID '#{node.id}'"}]
      else
        []
      end
    end)
  end

  # CHK-01: exactly one START node is required.
  @spec check_start_node(t()) :: [Violation.t()]
  defp check_start_node(%__MODULE__{nodes: nodes}) do
    count = Enum.count(nodes, &(&1.node_type == :START))

    cond do
      count == 0 ->
        [
          %Violation{
            code: :missing_start_node,
            message: "No START node found in the definition graph"
          }
        ]

      count > 1 ->
        [
          %Violation{
            code: :multiple_start_nodes,
            message: "Found #{count} START nodes; exactly one is required"
          }
        ]

      true ->
        []
    end
  end

  # CHK-02: at least one END node is required.
  @spec check_end_node(t()) :: [Violation.t()]
  defp check_end_node(%__MODULE__{nodes: nodes}) do
    if Enum.any?(nodes, &(&1.node_type == :END)) do
      []
    else
      [%Violation{code: :missing_end_node, message: "No END node found in the definition graph"}]
    end
  end

  # CHK-03: an edge whose source or target references a nonexistent node id.
  # Both endpoints of one edge are checked independently — a doubly-dangling
  # edge produces two violations, not one (design doc §5's CHK-03 detail).
  @spec check_dangling_edges(t()) :: [Violation.t()]
  defp check_dangling_edges(%__MODULE__{nodes: nodes, edges: edges}) do
    node_ids = MapSet.new(nodes, & &1.id)

    Enum.flat_map(edges, fn edge ->
      source_violation =
        if MapSet.member?(node_ids, edge.source) do
          []
        else
          [
            %Violation{
              code: :dangling_edge,
              message:
                "Edge '#{edge.id}' has dangling source reference: node '#{edge.source}' does not exist"
            }
          ]
        end

      target_violation =
        if MapSet.member?(node_ids, edge.target) do
          []
        else
          [
            %Violation{
              code: :dangling_edge,
              message:
                "Edge '#{edge.id}' has dangling target reference: node '#{edge.target}' does not exist"
            }
          ]
        end

      source_violation ++ target_violation
    end)
  end

  # CHK-04: a node with insufficient incoming/outgoing edges for its type.
  # START only needs an outgoing edge, END only needs an incoming edge, every
  # other type needs both (design doc §5's CHK-04 detail). Connectivity is
  # computed only from edges whose source AND target both resolve to a real
  # node id via `build_node_index/1`'s first-occurrence-wins lookup — a
  # dangling edge (CHK-03's concern) contributes no connectivity to either
  # side.
  @spec check_isolated_nodes(t()) :: [Violation.t()]
  defp check_isolated_nodes(%__MODULE__{nodes: nodes, edges: edges}) do
    node_index = build_node_index(nodes)

    {outgoing, incoming} =
      Enum.reduce(edges, {MapSet.new(), MapSet.new()}, fn edge, {outgoing, incoming} ->
        with {:ok, source_idx} <- Map.fetch(node_index, edge.source),
             {:ok, target_idx} <- Map.fetch(node_index, edge.target) do
          {MapSet.put(outgoing, source_idx), MapSet.put(incoming, target_idx)}
        else
          :error -> {outgoing, incoming}
        end
      end)

    nodes
    |> Enum.with_index()
    |> Enum.flat_map(fn {node, index} ->
      has_outgoing = MapSet.member?(outgoing, index)
      has_incoming = MapSet.member?(incoming, index)

      isolated? =
        case node.node_type do
          :START -> not has_outgoing
          :END -> not has_incoming
          _other -> not has_outgoing or not has_incoming
        end

      if isolated? do
        [
          %Violation{
            code: :isolated_node,
            message:
              "Node '#{node.id}' is isolated (insufficient incoming or outgoing edges for its type)"
          }
        ]
      else
        []
      end
    end)
  end

  # CHK-06: DFS-based cycle detection. A cycle is permitted iff at least one
  # endpoint of the closing back-edge is a gateway node; otherwise it's a
  # violation. Every node index is visited (not just those reachable from
  # START), so a cycle in a disconnected island is still caught (design doc
  # §6.2).
  @spec check_cycles(t()) :: [Violation.t()]
  defp check_cycles(%__MODULE__{nodes: nodes, edges: edges}) do
    node_index = build_node_index(nodes)
    adjacency = build_adjacency(edges, node_index)
    gateway_set = build_gateway_set(nodes)

    last_index = length(nodes) - 1

    {_visited, violations} =
      Enum.reduce(0..last_index//1, {MapSet.new(), []}, fn i, {visited, violations} ->
        if MapSet.member?(visited, i) do
          {visited, violations}
        else
          {new_visited, new_violations} =
            dfs_visit(i, adjacency, gateway_set, nodes, visited, MapSet.new())

          {new_visited, violations ++ new_violations}
        end
      end)

    violations
  end

  # PROVENANCE (historical, not current decision authority):
  # id -> first-occurrence 0-based index. On a repeated id, the first
  # occurrence wins and later occurrences are silently ignored here (matching
  # `graph.zig`'s `nodeIndex`'s linear-scan-returns-first-match behavior;
  # design doc §6.1 point 1). CHK-05 independently and unconditionally flags
  # the duplicate id itself, so this is never the only signal a caller sees.
  @spec build_node_index([Node.t()]) :: %{String.t() => non_neg_integer()}
  defp build_node_index(nodes) do
    nodes
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {node, index}, acc -> Map.put_new(acc, node.id, index) end)
  end

  # node index -> list of successor node indices, in edge-declaration order.
  # An edge where either endpoint fails to resolve via `node_index` (a
  # dangling edge) is excluded — it contributes no adjacency (design doc
  # §6.1 point 2). A self-loop (`source == target`) resolves to `u -> u` and
  # is included, not special-cased.
  @spec build_adjacency([Edge.t()], %{String.t() => non_neg_integer()}) ::
          %{non_neg_integer() => [non_neg_integer()]}
  defp build_adjacency(edges, node_index) do
    edges
    |> Enum.reduce(%{}, fn edge, acc ->
      with {:ok, source_idx} <- Map.fetch(node_index, edge.source),
           {:ok, target_idx} <- Map.fetch(node_index, edge.target) do
        Map.update(acc, source_idx, [target_idx], &[target_idx | &1])
      else
        :error -> acc
      end
    end)
    |> Map.new(fn {idx, targets} -> {idx, Enum.reverse(targets)} end)
  end

  # Every node's own list-position index whose node_type is a gateway type
  # (design doc §6.1 point 3) -- built from raw list position, not
  # `node_index`, since CHK-06's outer driver visits every position
  # 0..(length(nodes) - 1) directly (§6.2).
  @spec build_gateway_set([Node.t()]) :: MapSet.t(non_neg_integer())
  defp build_gateway_set(nodes) do
    nodes
    |> Enum.with_index()
    |> Enum.filter(fn {node, _index} -> node.node_type in @gateway_types end)
    |> Enum.map(fn {_node, index} -> index end)
    |> MapSet.new()
  end

  # One DFS call rooted at `u`. Returns `{visited, violations}` — `on_stack`
  # never propagates back to the caller: by the time this call returns, every
  # one of `u`'s outgoing edges has been processed and `u`'s presence on the
  # current root-to-leaf path is logically over (design doc §6.3 point 3).
  @spec dfs_visit(
          non_neg_integer(),
          %{non_neg_integer() => [non_neg_integer()]},
          MapSet.t(non_neg_integer()),
          [Node.t()],
          MapSet.t(non_neg_integer()),
          MapSet.t(non_neg_integer())
        ) :: {MapSet.t(non_neg_integer()), [Violation.t()]}
  defp dfs_visit(u, adjacency, gateway_set, nodes, visited, on_stack) do
    visited = MapSet.put(visited, u)
    on_stack = MapSet.put(on_stack, u)
    successors = Map.get(adjacency, u, [])

    Enum.reduce(successors, {visited, []}, fn v, {visited, violations} ->
      cond do
        MapSet.member?(on_stack, v) ->
          # Back-edge: v is an ancestor of u on the current path (or v == u,
          # the self-loop case). Permitted iff either endpoint is a gateway
          # node (design doc §6.3 step 2, §6.4).
          if MapSet.member?(gateway_set, u) or MapSet.member?(gateway_set, v) do
            {visited, violations}
          else
            u_id = Enum.at(nodes, u).id
            v_id = Enum.at(nodes, v).id

            violation = %Violation{
              code: :cycle_without_gateway,
              message:
                "Cycle detected: edge from node '#{u_id}' to node '#{v_id}' creates a cycle not passing through a gateway node"
            }

            {visited, violations ++ [violation]}
          end

        MapSet.member?(visited, v) ->
          # Cross/forward edge -- v already fully explored via another path,
          # not an ancestor relationship. Not a cycle.
          {visited, violations}

        true ->
          {new_visited, new_violations} =
            dfs_visit(v, adjacency, gateway_set, nodes, visited, on_stack)

          {new_visited, violations ++ new_violations}
      end
    end)
  end

  # --- CHK-09..CHK-12: per-node-type attribute checks (PD-05, REQ-029) ------

  # CHK-09: a HUMAN_TASK node must carry a non-empty (after trim) "role"
  # string attribute (design doc §4, §4.1).
  @spec check_human_task_role(t()) :: [Violation.t()]
  defp check_human_task_role(%__MODULE__{nodes: nodes}) do
    nodes
    |> Enum.filter(&(&1.node_type == :HUMAN_TASK))
    |> Enum.filter(&blank_or_missing_string?(&1.attributes, "role"))
    |> Enum.map(fn node ->
      %Violation{
        code: :missing_role,
        message: "Node '#{node.id}' (HUMAN_TASK) is missing a non-empty 'role' attribute"
      }
    end)
  end

  # CHK-10: a SERVICE_TASK node must carry a non-empty (after trim)
  # "endpoint" string attribute, UNLESS a non-empty (after trim) "service_id"
  # attribute is present instead -- mirrors
  # Letflow.Engine.ServiceTask.parse_config_from_node_attributes/1's own
  # {nil, nil} -> :missing_url_and_service_id condition (design doc §4, §4.1;
  # ISS-0104/GH#334).
  @spec check_service_task_endpoint(t()) :: [Violation.t()]
  defp check_service_task_endpoint(%__MODULE__{nodes: nodes}) do
    nodes
    |> Enum.filter(&(&1.node_type == :SERVICE_TASK))
    |> Enum.filter(&blank_or_missing_string?(&1.attributes, "endpoint"))
    |> Enum.filter(&blank_or_missing_string?(&1.attributes, "service_id"))
    |> Enum.map(fn node ->
      %Violation{
        code: :missing_endpoint,
        message:
          "Node '#{node.id}' (SERVICE_TASK) is missing a non-empty 'endpoint' attribute " <>
            "(and no non-empty 'service_id' attribute is present as an alternative)"
      }
    end)
  end

  # CHK-11: a SERVICE_TASK node's "timeout_ms" attribute must be an integer
  # (no numeric-string/float coercion, design doc §2's pinned value-type
  # table) in the inclusive range 1..300_000 (design doc §4.2).
  @spec check_service_task_timeout(t()) :: [Violation.t()]
  defp check_service_task_timeout(%__MODULE__{nodes: nodes}) do
    nodes
    |> Enum.filter(&(&1.node_type == :SERVICE_TASK))
    |> Enum.filter(&invalid_timeout?(&1.attributes))
    |> Enum.map(fn node ->
      value = attribute_value(node.attributes, "timeout_ms")

      %Violation{
        code: :invalid_timeout,
        message:
          "Node '#{node.id}' (SERVICE_TASK) has an invalid 'timeout_ms' attribute " <>
            "(#{inspect(value)}); must be an integer in 1..300000"
      }
    end)
  end

  # CHK-12: a TIMER node's "duration_iso8601" attribute must be a string
  # accepted by the ISO-8601 duration scan-forward parser (design doc §4.3).
  @spec check_timer_duration(t()) :: [Violation.t()]
  defp check_timer_duration(%__MODULE__{nodes: nodes}) do
    nodes
    |> Enum.filter(&(&1.node_type == :TIMER))
    |> Enum.filter(&invalid_duration?(&1.attributes))
    |> Enum.map(fn node ->
      value = attribute_value(node.attributes, "duration_iso8601")

      %Violation{
        code: :invalid_duration,
        message:
          "Node '#{node.id}' (TIMER) has an invalid 'duration_iso8601' attribute (#{inspect(value)})"
      }
    end)
  end

  # CHK-18: a SUB_PROCESS node's optional "interface" attribute, if present,
  # must be a well-formed interface contract (inputs/outputs entry lists,
  # each entry a well-formed {name, json_schema, required} tuple with a
  # well-formed json_schema) -- delegated entirely to
  # `Letflow.Definitions.SubProcessInterface.validate_node_interface/2`
  # (REQ-032 design doc §4). One check function producing up to 6 distinct
  # codes, not 6 separate one-code-per-check functions -- a deliberate
  # divergence from CHK-09..17's "one check, one code" convention, since the
  # 6 codes form a dependency chain within a single parse (design doc §4).
  # No-op on a node of any other type.
  @spec check_sub_process_interface(t()) :: [Violation.t()]
  defp check_sub_process_interface(%__MODULE__{nodes: nodes}) do
    nodes
    |> Enum.filter(&(&1.node_type == :SUB_PROCESS))
    |> Enum.flat_map(fn node ->
      Letflow.Definitions.SubProcessInterface.validate_node_interface(node.id, node.attributes)
    end)
  end

  # `attributes` is documented as `map() | nil` with string keys (design doc
  # §2) -- the `is_map/1` guard is a defensive belt-and-suspenders check so
  # these helpers stay total (never raise) even if a caller ever hands in
  # something else, rather than relying solely on the documented contract.
  @spec blank_or_missing_string?(map() | nil, String.t()) :: boolean()
  defp blank_or_missing_string?(attributes, key) when is_map(attributes) do
    case Map.get(attributes, key) do
      value when is_binary(value) -> String.trim(value) == ""
      _other -> true
    end
  end

  defp blank_or_missing_string?(_attributes, _key), do: true

  @spec invalid_timeout?(map() | nil) :: boolean()
  defp invalid_timeout?(attributes) when is_map(attributes) do
    case Map.get(attributes, "timeout_ms") do
      value when is_integer(value) -> value < 1 or value > 300_000
      _other -> true
    end
  end

  defp invalid_timeout?(_attributes), do: true

  @spec invalid_duration?(map() | nil) :: boolean()
  defp invalid_duration?(attributes) when is_map(attributes) do
    case Map.get(attributes, "duration_iso8601") do
      value when is_binary(value) -> not valid_iso8601_duration?(value)
      _other -> true
    end
  end

  defp invalid_duration?(_attributes), do: true

  @spec attribute_value(map() | nil, String.t()) :: term()
  defp attribute_value(attributes, key) when is_map(attributes), do: Map.get(attributes, key)
  defp attribute_value(_attributes, _key), do: nil

  # --- ISO-8601 duration scan-forward parser (design doc §4.3) --------------

  @duration_date_units ["Y", "M", "W", "D"]
  @duration_time_units ["H", "M", "S"]

  # A duration string is valid iff: it contains no fractional ('.'/',')
  # character anywhere; it starts with literal 'P'; the remainder splits on
  # the first 'T' (if any) into a date_part and, only if 'T' was present, a
  # non-empty time_part; date_part scans as zero-or-more ordered
  # <digits><unit> tokens from Y,M,W,D with no leftover characters;
  # time_part (if 'T' was present) scans the same way against H,M,S and must
  # contain at least one token; if no 'T' was present, date_part itself must
  # contain at least one token. `P0D` is explicitly valid (design doc §4.3).
  @spec valid_iso8601_duration?(String.t()) :: boolean()
  defp valid_iso8601_duration?(str) do
    cond do
      String.contains?(str, ".") or String.contains?(str, ",") ->
        false

      not String.starts_with?(str, "P") ->
        false

      true ->
        str
        |> String.slice(1, String.length(str) - 1)
        |> valid_duration_remainder?()
    end
  end

  @spec valid_duration_remainder?(String.t()) :: boolean()
  defp valid_duration_remainder?(remainder) do
    case String.split(remainder, "T", parts: 2) do
      [date_part] ->
        case scan_duration_tokens(date_part, @duration_date_units) do
          :error -> false
          count -> count > 0
        end

      [date_part, time_part] ->
        time_part != "" and valid_duration_date_and_time?(date_part, time_part)
    end
  end

  @spec valid_duration_date_and_time?(String.t(), String.t()) :: boolean()
  defp valid_duration_date_and_time?(date_part, time_part) do
    date_ok? =
      case scan_duration_tokens(date_part, @duration_date_units) do
        :error -> false
        _count -> true
      end

    time_ok? =
      case scan_duration_tokens(time_part, @duration_time_units) do
        :error -> false
        count -> count > 0
      end

    date_ok? and time_ok?
  end

  # --- REQ-187 design doc §2 -- parse_iso8601_duration/1 --------------------

  # Fixed-length calendar approximation (flagged assumption, REQ-187 design
  # doc §2): no real calendar-month/leap-year arithmetic -- Y=365d,
  # M(date part)=30d, W=7d, D=1d, H=3600s, M(time part)=60s, S=1s. Blast
  # radius of getting this wrong is contained entirely to this one function
  # (its @spec and every call site stay identical either way).
  @duration_date_unit_seconds %{
    "Y" => 365 * 86_400,
    "M" => 30 * 86_400,
    "W" => 7 * 86_400,
    "D" => 86_400
  }
  @duration_time_unit_seconds %{"H" => 3600, "M" => 60, "S" => 1}

  @doc """
  Converts a valid ISO-8601 duration string (as already validated by
  `valid_iso8601_duration?/1`'s own grammar, CHK-12) into a total number of
  seconds, using the fixed-length calendar convention documented above.
  Pure -- no clock, no I/O. Returns `:error` for any string
  `valid_iso8601_duration?/1` itself would reject (defensive-only: CHK-12
  already rejects an invalid `duration_iso8601` at definition-approval time,
  so a `:TIMER` node reaching this function with one should be
  unreachable). Only ever called by `Letflow.Engine` (the impure caller),
  never by `Letflow.Engine.Transition` (design doc §2).
  """
  @spec parse_iso8601_duration(String.t()) :: {:ok, seconds :: non_neg_integer()} | :error
  def parse_iso8601_duration(str) when is_binary(str) do
    if valid_iso8601_duration?(str) do
      remainder = String.slice(str, 1, String.length(str) - 1)

      case String.split(remainder, "T", parts: 2) do
        [date_part] ->
          date_part
          |> scan_duration_seconds(@duration_date_units, @duration_date_unit_seconds)
          |> wrap_seconds()

        [date_part, time_part] ->
          with {:ok, date_seconds} <-
                 date_part
                 |> scan_duration_seconds(@duration_date_units, @duration_date_unit_seconds)
                 |> wrap_seconds(),
               {:ok, time_seconds} <-
                 time_part
                 |> scan_duration_seconds(@duration_time_units, @duration_time_unit_seconds)
                 |> wrap_seconds() do
            {:ok, date_seconds + time_seconds}
          end
      end
    else
      :error
    end
  end

  def parse_iso8601_duration(_str), do: :error

  @spec wrap_seconds(non_neg_integer() | :error) :: {:ok, non_neg_integer()} | :error
  defp wrap_seconds(:error), do: :error
  defp wrap_seconds(seconds) when is_integer(seconds), do: {:ok, seconds}

  # Same scan-forward shape as scan_duration_tokens/3 below, accumulating
  # seconds (via unit_seconds) instead of a bare token count -- kept as a
  # parallel pass over the same already-validated grammar rather than
  # threading a second accumulator through scan_duration_tokens/3 itself,
  # so that function's own @spec (a bare token count for validation) stays
  # unchanged for its one existing caller, valid_duration_remainder?/1.
  @spec scan_duration_seconds(String.t(), [String.t()], %{String.t() => non_neg_integer()}) ::
          non_neg_integer() | :error
  defp scan_duration_seconds(str, remaining_units, unit_seconds),
    do: scan_duration_seconds(str, remaining_units, unit_seconds, 0)

  @spec scan_duration_seconds(
          String.t(),
          [String.t()],
          %{String.t() => non_neg_integer()},
          non_neg_integer()
        ) :: non_neg_integer() | :error
  defp scan_duration_seconds("", _remaining_units, _unit_seconds, acc), do: acc

  defp scan_duration_seconds(str, remaining_units, unit_seconds, acc) do
    case Regex.run(~r/^([0-9]+)([A-Za-z])/, str) do
      [match, digits, unit] ->
        case Enum.split_while(remaining_units, &(&1 != unit)) do
          {_before, [^unit | rest_units]} ->
            rest_str =
              String.slice(str, String.length(match), String.length(str) - String.length(match))

            seconds = String.to_integer(digits) * Map.fetch!(unit_seconds, unit)
            scan_duration_seconds(rest_str, rest_units, unit_seconds, acc + seconds)

          {_before, []} ->
            :error
        end

      nil ->
        :error
    end
  end

  # Scans `str` left to right for zero or more <digits><unit> tokens against
  # `remaining_units` (an ordered list of single-character unit strings, e.g.
  # `["Y", "M", "W", "D"]`), where units present must appear in that relative
  # order with no repeats and any not present are simply skipped (they're
  # optional). Returns the number of tokens matched once `str` is fully
  # consumed, or `:error` if `str` contains any leftover/unrecognized
  # characters, an out-of-order unit, or a repeated unit.
  @spec scan_duration_tokens(String.t(), [String.t()]) :: non_neg_integer() | :error
  defp scan_duration_tokens(str, remaining_units),
    do: scan_duration_tokens(str, remaining_units, 0)

  @spec scan_duration_tokens(String.t(), [String.t()], non_neg_integer()) ::
          non_neg_integer() | :error
  defp scan_duration_tokens("", _remaining_units, count), do: count

  defp scan_duration_tokens(str, remaining_units, count) do
    case Regex.run(~r/^([0-9]+)([A-Za-z])/, str) do
      [match, _digits, unit] ->
        case Enum.split_while(remaining_units, &(&1 != unit)) do
          {_before, [^unit | rest_units]} ->
            rest_str =
              String.slice(str, String.length(match), String.length(str) - String.length(match))

            scan_duration_tokens(rest_str, rest_units, count + 1)

          {_before, []} ->
            :error
        end

      nil ->
        :error
    end
  end

  # --- CHK-13..CHK-17: edge-condition/CEL checks (PD-06, REQ-029) -----------

  # CHK-13: a non-default outgoing edge from an EXCLUSIVE_GATEWAY must have a
  # non-empty (after trim) condition (design doc §5.1).
  @spec check_gateway_condition_presence(t()) :: [Violation.t()]
  defp check_gateway_condition_presence(%__MODULE__{nodes: nodes, edges: edges}) do
    node_index = build_node_index(nodes)

    edges
    |> Enum.filter(fn edge ->
      exclusive_gateway_source?(nodes, node_index, edge) and edge.is_default != true and
        blank_condition?(edge.condition)
    end)
    |> Enum.map(fn edge ->
      %Violation{
        code: :missing_edge_condition,
        message:
          "Edge '#{edge.id}' is a non-default outgoing edge from an EXCLUSIVE_GATEWAY and requires a non-empty condition"
      }
    end)
  end

  # CHK-14: every edge whose source is neither a non-default EXCLUSIVE_GATEWAY
  # outgoing edge nor a HUMAN_TASK outgoing edge must have a null condition
  # (design doc §5.1, `iss-0056-human-task-fallback-edge-validation.md` §3.2).
  # Renamed from `check_non_gateway_condition_absence/1` -- that name became
  # misleading once a HUMAN_TASK (non-gateway) source is also permitted to
  # carry a condition.
  @spec check_unpermitted_edge_condition(t()) :: [Violation.t()]
  defp check_unpermitted_edge_condition(%__MODULE__{nodes: nodes, edges: edges}) do
    node_index = build_node_index(nodes)

    edges
    |> Enum.filter(fn edge ->
      not ((exclusive_gateway_source?(nodes, node_index, edge) and edge.is_default != true) or
             human_task_source?(nodes, node_index, edge)) and edge.condition != nil
    end)
    |> Enum.map(fn edge ->
      %Violation{
        code: :unexpected_edge_condition,
        message:
          "Edge '#{edge.id}' is not a non-default EXCLUSIVE_GATEWAY outgoing edge or a " <>
            "HUMAN_TASK outgoing edge and must not have a condition"
      }
    end)
  end

  # CHK-15: is_default and a non-null condition must never coexist, on any
  # edge regardless of source node type -- deliberately unscoped, checked
  # independently of (and able to co-fire with) CHK-14 (design doc §5.1).
  @spec check_default_condition_conflict(t()) :: [Violation.t()]
  defp check_default_condition_conflict(%__MODULE__{edges: edges}) do
    edges
    |> Enum.filter(&(&1.is_default == true and &1.condition != nil))
    |> Enum.map(fn edge ->
      %Violation{
        code: :default_with_condition,
        message: "Edge '#{edge.id}' is marked is_default but also has a non-null condition"
      }
    end)
  end

  # CHK-16: at most one default outgoing edge per EXCLUSIVE_GATEWAY source
  # node -- the first default edge in declaration order is legal, every
  # subsequent one from the same gateway is a violation (mirrors CHK-05's "N
  # occurrences -> N-1 violations" convention, design doc §5.3).
  @spec check_single_default_edge(t()) :: [Violation.t()]
  defp check_single_default_edge(%__MODULE__{nodes: nodes, edges: edges}) do
    node_index = build_node_index(nodes)

    edges
    |> Enum.filter(&exclusive_gateway_source?(nodes, node_index, &1))
    |> Enum.group_by(&Map.fetch!(node_index, &1.source))
    |> Enum.flat_map(fn {gateway_idx, gateway_edges} ->
      gateway_edges
      |> Enum.filter(&(&1.is_default == true))
      |> Enum.drop(1)
      |> Enum.map(fn edge ->
        gateway_id = Enum.at(nodes, gateway_idx).id

        %Violation{
          code: :multiple_default_edges,
          message:
            "Edge '#{edge.id}' is an additional default edge from EXCLUSIVE_GATEWAY node " <>
              "'#{gateway_id}'; only one default edge is permitted per gateway"
        }
      end)
    end)
  end

  # CHK-17: every edge with a present (non-nil, non-blank) condition must be
  # syntactically valid CEL, checked unconditionally regardless of whether
  # the edge was "allowed" to have a condition at all (design doc §5.1).
  @spec check_cel_syntax(t()) :: [Violation.t()]
  defp check_cel_syntax(%__MODULE__{edges: edges}) do
    edges
    |> Enum.filter(fn edge ->
      not blank_condition?(edge.condition) and not valid_cel_syntax?(edge.condition)
    end)
    |> Enum.map(fn edge ->
      %Violation{
        code: :invalid_cel_syntax,
        message:
          "Edge '#{edge.id}' has a condition that is not syntactically valid CEL: #{inspect(edge.condition)}"
      }
    end)
  end

  # CHK-19: a HUMAN_TASK node with at least one "really conditioned" outgoing
  # edge must also have at least one fallback-candidate outgoing edge to
  # resolve to if every condition evaluates false -- one violation per
  # offending node, not per edge (`iss-0056-human-task-fallback-edge-validation.md`
  # §4.2). Iterates `graph.nodes` filtered to HUMAN_TASK, matching CHK-09's
  # own node-filtering idiom -- not grouped by resolved source index the way
  # CHK-16 groups gateway edges, since this check's unit of concern is one
  # violation per node, not per edge.
  @spec check_human_task_fallback_edge(t()) :: [Violation.t()]
  defp check_human_task_fallback_edge(%__MODULE__{nodes: nodes, edges: edges}) do
    nodes
    |> Enum.filter(&(&1.node_type == :HUMAN_TASK))
    |> Enum.filter(fn node ->
      outgoing = Enum.filter(edges, &(&1.source == node.id))

      Enum.any?(outgoing, &human_task_edge_really_conditioned?/1) and
        not Enum.any?(outgoing, &human_task_edge_fallback_candidate?/1)
    end)
    |> Enum.map(fn node ->
      %Violation{
        code: :human_task_no_fallback_edge,
        message:
          "HUMAN_TASK node '#{node.id}' has at least one really-conditioned outgoing edge " <>
            "but no fallback edge (is_default: true, or a blank/nil condition) to resolve " <>
            "to if every condition evaluates false"
      }
    end)
  end

  # Mirrors `Letflow.Engine.Transition`'s `really_conditioned?/1` predicate
  # literally (copied by value, not imported/aliased/called cross-module --
  # design doc §4.1) so `graph.ex` and `transition.ex` share the same
  # "really conditioned" definition without a cross-module dependency. Does
  # NOT trim whitespace -- deliberately different from `blank_condition?/1`,
  # a disclosed, unreconciled inconsistency (design doc §4.1's open question).
  @spec human_task_edge_really_conditioned?(Edge.t()) :: boolean()
  defp human_task_edge_really_conditioned?(edge) do
    edge.is_default != true and is_binary(edge.condition) and edge.condition != ""
  end

  # The logical complement of `human_task_edge_really_conditioned?/1`, stated
  # separately (not as `not human_task_edge_really_conditioned?/1`) for
  # readability at the CHK-19 call site (design doc §4.1).
  @spec human_task_edge_fallback_candidate?(Edge.t()) :: boolean()
  defp human_task_edge_fallback_candidate?(edge) do
    edge.is_default == true or is_nil(edge.condition) or edge.condition == ""
  end

  @spec blank_condition?(String.t() | nil) :: boolean()
  defp blank_condition?(nil), do: true
  defp blank_condition?(condition) when is_binary(condition), do: String.trim(condition) == ""
  defp blank_condition?(_condition), do: true

  # Resolves `edge.source` via `node_index` (§5.2) and reports whether the
  # resolved node is an EXCLUSIVE_GATEWAY. An unresolvable (dangling) source
  # is defensively treated as "not a gateway" rather than raising -- CHK-03
  # (validate_graph/1) is the function responsible for reporting the dangling
  # reference itself.
  @spec exclusive_gateway_source?(
          [Node.t()],
          %{String.t() => non_neg_integer()},
          Edge.t()
        ) :: boolean()
  defp exclusive_gateway_source?(nodes, node_index, edge) do
    case Map.fetch(node_index, edge.source) do
      {:ok, idx} -> Enum.at(nodes, idx).node_type == :EXCLUSIVE_GATEWAY
      :error -> false
    end
  end

  # Resolves `edge.source` via `node_index` (§5.2) and reports whether the
  # resolved node is a HUMAN_TASK. An unresolvable (dangling) source is
  # defensively treated as "not a HUMAN_TASK" rather than raising -- same
  # convention as `exclusive_gateway_source?/3`; kept as a separate helper
  # rather than a generalization of it so CHK-13/16's existing call sites are
  # untouched by this change (`iss-0056-human-task-fallback-edge-validation.md`
  # §3.1).
  @spec human_task_source?(
          [Node.t()],
          %{String.t() => non_neg_integer()},
          Edge.t()
        ) :: boolean()
  defp human_task_source?(nodes, node_index, edge) do
    case Map.fetch(node_index, edge.source) do
      {:ok, idx} -> Enum.at(nodes, idx).node_type == :HUMAN_TASK
      :error -> false
    end
  end

  # --- valid_cel_syntax?/1 helpers (design doc §6) ---------------------------

  @cel_matching_open %{")" => "(", "]" => "[", "}" => "{"}
  @cel_open_brackets MapSet.new(["(", "[", "{"])
  @cel_close_brackets MapSet.new([")", "]", "}"])
  @cel_quote_chars MapSet.new(["'", "\""])
  @cel_bare_operators MapSet.new([
                        "&&",
                        "||",
                        "==",
                        "!=",
                        "<=",
                        ">=",
                        "<",
                        ">",
                        "+",
                        "-",
                        "*",
                        "/",
                        "."
                      ])

  # Scans `str` (already trimmed) left to right tracking a bracket stack and
  # whether the scan is currently inside a string literal (honoring a `\`
  # escape so `\"` inside a `"`-delimited literal does not close it, design
  # doc §6 step 2). Returns `true` iff every bracket is matched/closed and no
  # string literal is left unterminated at the end of the scan.
  @spec cel_brackets_and_strings_balanced?(String.t()) :: boolean()
  defp cel_brackets_and_strings_balanced?(str) do
    str
    |> String.graphemes()
    |> Enum.reduce_while({[], nil, false}, &cel_scan_char/2)
    |> case do
      {[], nil, false} -> true
      _other -> false
    end
  end

  # Inside a string literal, the char immediately after an unescaped `\` is
  # consumed literally and never closes the literal or is itself treated as
  # a new escape.
  defp cel_scan_char(_ch, {stack, quote, true}) when not is_nil(quote) do
    {:cont, {stack, quote, false}}
  end

  # Inside a string literal (not currently escaped): `\` starts an escape,
  # the matching quote char closes the literal, anything else is literal
  # text -- bracket characters are not pushed/popped/matched while inside a
  # string literal.
  defp cel_scan_char(ch, {stack, quote, false}) when not is_nil(quote) do
    cond do
      ch == "\\" -> {:cont, {stack, quote, true}}
      ch == quote -> {:cont, {stack, nil, false}}
      true -> {:cont, {stack, quote, false}}
    end
  end

  # Outside a string literal: a quote char opens one; an open bracket
  # pushes; a close bracket must match the top of the stack (halting with
  # `:error` on a mismatch or an empty stack); anything else is ordinary
  # text.
  defp cel_scan_char(ch, {stack, nil, false}) do
    cond do
      MapSet.member?(@cel_quote_chars, ch) ->
        {:cont, {stack, ch, false}}

      MapSet.member?(@cel_open_brackets, ch) ->
        {:cont, {[ch | stack], nil, false}}

      MapSet.member?(@cel_close_brackets, ch) ->
        case stack do
          [top | tail] ->
            if @cel_matching_open[ch] == top do
              {:cont, {tail, nil, false}}
            else
              {:halt, :error}
            end

          [] ->
            {:halt, :error}
        end

      true ->
        {:cont, {stack, nil, false}}
    end
  end

  # `str`'s first or last whitespace-/bracket-delimited token is one of the
  # fixed bare operator spellings that requires an operand on the (missing)
  # other side (design doc §6 step 4).
  @spec cel_starts_or_ends_with_bare_operator?(String.t()) :: boolean()
  defp cel_starts_or_ends_with_bare_operator?(str) do
    case cel_tokens(str) do
      [] ->
        false

      tokens ->
        MapSet.member?(@cel_bare_operators, List.first(tokens)) or
          MapSet.member?(@cel_bare_operators, List.last(tokens))
    end
  end

  @spec cel_tokens(String.t()) :: [String.t()]
  defp cel_tokens(str) do
    Regex.split(~r/[\s\(\)\[\]\{\}]+/, str, trim: true)
  end
end
