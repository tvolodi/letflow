defmodule Letflow.Definitions.Graph do
  @moduledoc """
  Graph structural validator — the pure, no-I/O validation core of a process
  definition's `graph` (`{"nodes": [...], "edges": [...]}` shape). Ported from
  `src/definition/graph.zig`'s `validateGraph()` (R-Co,
  `C:\\Users\\tvolo\\dev\\ai-dala\\R-Co\\src\\definition\\graph.zig`, lines ~191-384)
  per `src/design/definition.md`'s "Named validation checks (PD-02)" table and
  `lib/letflow/design/req028-graph-structural-validator.md` (the gate-approved
  design this module implements).

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
  """

  @type node_type ::
          :START
          | :END
          | :HUMAN_TASK
          | :SERVICE_TASK
          | :EXCLUSIVE_GATEWAY
          | :PARALLEL_GATEWAY
          | :TIMER

  defmodule Node do
    @moduledoc """
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
end
