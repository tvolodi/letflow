defmodule Letflow.Definitions.GraphTest do
  @moduledoc """
  Unit tests for `Letflow.Definitions.Graph.validate_graph/1` (REQ-028). Pure
  module, no `Letflow.Repo`/`Ecto.Sandbox` dependency anywhere in this file —
  `async: true` is correct here, unlike the DB-touching test files elsewhere in
  this project (`test/letflow/tenant_provisioning_test.exs`,
  `test/letflow/role_registry_test.exs`) that must serialize around shared
  Postgres connections. See `test/specs/REQ-028.md` for the full test design
  rationale, the hand-worked DFS traces behind every fixture below, and AC5's
  (zero-I/O) code-inspection evidence.
  """

  use ExUnit.Case, async: true

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.Graph.{Edge, Node}

  # ---------------------------------------------------------------------
  # Fixture builders
  # ---------------------------------------------------------------------

  defp node(id, type), do: %Node{id: id, node_type: type}
  defp edge(id, source, target), do: %Edge{id: id, source: source, target: target}
  defp graph(nodes, edges), do: %Graph{nodes: nodes, edges: edges}

  # REQ-029 fixture builders -- a Node carrying `attributes`, and an Edge
  # carrying `condition`/`is_default`. Kept as separate helpers rather than
  # adding optional args to `node/2`/`edge/3` above, so every existing
  # REQ-028 test line (which never sets attributes/condition/is_default) is
  # untouched by this extension.
  defp attr_node(id, type, attributes), do: %Node{id: id, node_type: type, attributes: attributes}

  defp cond_edge(id, source, target, condition, is_default) do
    %Edge{id: id, source: source, target: target, condition: condition, is_default: is_default}
  end

  # The list of violation codes, in the exact order validate_graph/1 returned
  # them — order is deterministic (fixed check order, design doc §7.1), so
  # asserting on it (not just a Set) is a strictly stronger check.
  defp codes(%{violations: violations}), do: Enum.map(violations, & &1.code)

  # A linear chain start -> m1 -> m2 -> ... -> m<n> -> finish, every middle
  # node a HUMAN_TASK with exactly one incoming and one outgoing edge — used
  # to build an otherwise-fully-valid, acyclic graph whose only defect is its
  # node count, for the CHK-07 (node_limit_exceeded) fixture.
  defp linear_chain_graph(middle_count) do
    start = node("start", :START)
    finish = node("end", :END)
    middles = for i <- 1..middle_count, do: node("m#{i}", :HUMAN_TASK)

    chain_ids = ["start"] ++ Enum.map(1..middle_count, &"m#{&1}") ++ ["end"]

    edges =
      chain_ids
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.with_index()
      |> Enum.map(fn {[a, b], i} -> edge("e#{i}", a, b) end)

    graph([start] ++ middles ++ [finish], edges)
  end

  # Two nodes, `edge_count` identical parallel edges between them — used to
  # build an otherwise-fully-valid graph whose only defect is its edge count,
  # for the CHK-08 (edge_limit_exceeded) fixture. Duplicate edges between the
  # same pair are harmless to every other check (CHK-03/04/06 only care about
  # existence, not multiplicity — confirmed by DFS trace in the spec).
  defp many_parallel_edges_graph(edge_count) do
    nodes = [node("s", :START), node("e", :END)]
    edges = for i <- 1..edge_count, do: edge("edge#{i}", "s", "e")
    graph(nodes, edges)
  end

  # ---------------------------------------------------------------------
  # AC1 — a graph satisfying all 8 checks returns {valid: true, violations: []}
  # ---------------------------------------------------------------------

  describe "validate_graph/1 — acceptance criterion 1" do
    test "a realistic, multi-node, multi-edge, fully valid graph returns valid: true, violations: []" do
      # START -> HUMAN_TASK -> EXCLUSIVE_GATEWAY -> {SERVICE_TASK -> END,
      #                                              back to HUMAN_TASK (permitted cycle)}
      g =
        graph(
          [
            node("n1", :START),
            node("n2", :HUMAN_TASK),
            node("n3", :EXCLUSIVE_GATEWAY),
            node("n4", :SERVICE_TASK),
            node("n5", :END)
          ],
          [
            edge("e1", "n1", "n2"),
            edge("e2", "n2", "n3"),
            edge("e3", "n3", "n4"),
            edge("e4", "n3", "n2"),
            edge("e5", "n4", "n5")
          ]
        )

      assert Graph.validate_graph(g) == %{valid: true, violations: []}
    end
  end

  # ---------------------------------------------------------------------
  # AC2 — each of the 8 named checks (9 violation codes) has its own minimal
  # failing-example fixture, asserting the specific violation code.
  # ---------------------------------------------------------------------

  describe "validate_graph/1 — acceptance criterion 2: CHK-01 (start node)" do
    test "zero START nodes -> :missing_start_node, and only that code" do
      # No START anywhere; a permitted (gateway) cycle between an
      # EXCLUSIVE_GATEWAY and an END keeps every other check clean.
      g =
        graph(
          [node("gw", :EXCLUSIVE_GATEWAY), node("fin", :END)],
          [edge("e1", "gw", "fin"), edge("e2", "fin", "gw")]
        )

      result = Graph.validate_graph(g)
      assert result.valid == false
      assert codes(result) == [:missing_start_node]
    end

    test "more than one START node -> :multiple_start_nodes, and only that code" do
      g =
        graph(
          [node("s1", :START), node("s2", :START), node("fin", :END)],
          [edge("e1", "s1", "fin"), edge("e2", "s2", "fin")]
        )

      result = Graph.validate_graph(g)
      assert result.valid == false
      assert codes(result) == [:multiple_start_nodes]

      [violation] = result.violations
      assert violation.message == "Found 2 START nodes; exactly one is required"
    end
  end

  describe "validate_graph/1 — acceptance criterion 2: CHK-02 (end node)" do
    test "zero END nodes -> :missing_end_node, and only that code" do
      # START -> HUMAN_TASK <-> EXCLUSIVE_GATEWAY, cycle permitted via the
      # gateway, no END anywhere.
      g =
        graph(
          [node("s", :START), node("h", :HUMAN_TASK), node("gw", :EXCLUSIVE_GATEWAY)],
          [edge("e1", "s", "h"), edge("e2", "h", "gw"), edge("e3", "gw", "h")]
        )

      result = Graph.validate_graph(g)
      assert result.valid == false
      assert codes(result) == [:missing_end_node]
    end
  end

  describe "validate_graph/1 — acceptance criterion 2: CHK-03 (dangling edge)" do
    test "an edge whose target matches no node id -> :dangling_edge, and only that code" do
      # n1 -> n2 alone already satisfies START's/END's connectivity; the
      # second edge's dangling target is the only defect.
      g =
        graph(
          [node("n1", :START), node("n2", :END)],
          [edge("e1", "n1", "n2"), edge("e2", "n1", "ghost")]
        )

      result = Graph.validate_graph(g)
      assert result.valid == false
      assert codes(result) == [:dangling_edge]

      [violation] = result.violations

      assert violation.message ==
               "Edge 'e2' has dangling target reference: node 'ghost' does not exist"
    end
  end

  describe "validate_graph/1 — acceptance criterion 2: CHK-04 (isolated node)" do
    test "a node with zero edges -> :isolated_node, and only that code" do
      # n3 has no edges referencing it at all -- neither incoming nor
      # outgoing -- while n1/n2 satisfy START/END on their own via e1.
      g =
        graph(
          [node("n1", :START), node("n2", :END), node("n3", :HUMAN_TASK)],
          [edge("e1", "n1", "n2")]
        )

      result = Graph.validate_graph(g)
      assert result.valid == false
      assert codes(result) == [:isolated_node]

      [violation] = result.violations
      assert violation.message =~ "n3"
    end
  end

  describe "validate_graph/1 — acceptance criterion 2: CHK-05 (duplicate node id)" do
    test "a repeated node id -> :duplicate_node_id, alongside the unavoidable companion :isolated_node" do
      # Design doc §6.1/§7.2: node-id -> index resolution is first-match-wins
      # (Map.put_new/3 over an indexed fold), ported faithfully from
      # graph.zig's own nodeIndex/nodeExists linear-scan semantics. Because of
      # this, an edge naming a duplicated id ALWAYS resolves to the FIRST
      # occurrence -- the second (higher-index) occurrence can never receive
      # any incoming/outgoing edge attribution via its own (shared) id,
      # regardless of node type. Every one of the 7 node types requires at
      # least one side of connectivity (START needs outgoing, END needs
      # incoming, every other type needs both) -- so the second occurrence of
      # ANY duplicated id is therefore *always* also flagged :isolated_node.
      # This is not a fixture-construction flaw: it is a proven structural
      # consequence of the ported algorithm (confirmed by hand-tracing every
      # other possible construction in test/specs/REQ-028.md before writing
      # this test), so this test asserts the true minimal violation set for
      # CHK-05 -- exactly these two codes, not CHK-05 in isolation from
      # everything else.
      #
      # n1 ("x", START) is the first occurrence of "x" and is the only node
      # any edge actually resolves to when "x" is named. n2 ("x", END) is the
      # duplicate -- unreachable by any edge, hence isolated. n3 ("y", END)
      # exists only so edge e1 has somewhere real to point besides "x", and
      # independently satisfies CHK-02's "at least one END" (which n2 would
      # have satisfied too, since CHK-02 counts by node_type, not id).
      g =
        graph(
          [node("x", :START), node("x", :END), node("y", :END)],
          [edge("e1", "x", "y")]
        )

      result = Graph.validate_graph(g)
      assert result.valid == false
      assert codes(result) == [:duplicate_node_id, :isolated_node]

      [dup, isolated] = result.violations
      assert dup.message == "Duplicate node ID 'x'"
      assert isolated.message =~ "'x'"
    end
  end

  describe "validate_graph/1 — acceptance criterion 2: CHK-06 (cycle without gateway)" do
    test "a 2-node cycle between two non-gateway nodes -> :cycle_without_gateway, and only that code" do
      # S -> H <-> ST -> E: the H<->ST back-edge involves neither node being
      # a gateway type, so it's rejected. Every node's incoming/outgoing
      # requirement is independently satisfied so nothing else fires.
      g =
        graph(
          [
            node("s", :START),
            node("h", :HUMAN_TASK),
            node("st", :SERVICE_TASK),
            node("e", :END)
          ],
          [
            edge("e1", "s", "h"),
            edge("e2", "h", "st"),
            edge("e3", "st", "h"),
            edge("e4", "st", "e")
          ]
        )

      result = Graph.validate_graph(g)
      assert result.valid == false
      assert codes(result) == [:cycle_without_gateway]
    end
  end

  describe "validate_graph/1 — acceptance criterion 2: CHK-07 (node limit)" do
    test "501 nodes, otherwise a fully-connected acyclic chain -> :node_limit_exceeded, and only that code" do
      g = linear_chain_graph(499)
      assert length(g.nodes) == 501

      result = Graph.validate_graph(g)
      assert result.valid == false
      assert codes(result) == [:node_limit_exceeded]

      [violation] = result.violations
      assert violation.message == "Node count 501 exceeds the maximum of 500"
    end
  end

  describe "validate_graph/1 — acceptance criterion 2: CHK-08 (edge limit)" do
    test "2001 parallel edges between 2 otherwise-valid nodes -> :edge_limit_exceeded, and only that code" do
      g = many_parallel_edges_graph(2001)
      assert length(g.edges) == 2001

      result = Graph.validate_graph(g)
      assert result.valid == false
      assert codes(result) == [:edge_limit_exceeded]

      [violation] = result.violations
      assert violation.message == "Edge count 2001 exceeds the maximum of 2000"
    end
  end

  # ---------------------------------------------------------------------
  # AC3 — 3 simultaneous violations, all returned in one call (Key invariant 5)
  # ---------------------------------------------------------------------

  describe "validate_graph/1 — acceptance criterion 3" do
    test "a graph violating 3 checks at once returns all 3 violation codes, in fixed check order" do
      # No START, no END, and a 2-node non-gateway cycle -- 3 independent
      # defects that none of CHK-01/02/06 depends on another to detect
      # (design doc §7.2's independence proof).
      g =
        graph(
          [node("h1", :HUMAN_TASK), node("s1", :SERVICE_TASK)],
          [edge("e1", "h1", "s1"), edge("e2", "s1", "h1")]
        )

      result = Graph.validate_graph(g)
      assert result.valid == false

      # Exact set AND exact (deterministic, fixed-check-order) sequence --
      # strictly stronger than a bare count or an unordered set comparison.
      assert codes(result) == [:missing_start_node, :missing_end_node, :cycle_without_gateway]

      assert MapSet.new(codes(result)) ==
               MapSet.new([
                 :missing_start_node,
                 :missing_end_node,
                 :cycle_without_gateway
               ])

      assert length(result.violations) == 3
    end
  end

  # ---------------------------------------------------------------------
  # AC4 — gateway cycles permitted; self-loop on a non-gateway node rejected;
  # self-loop ON a gateway node accepted (design doc §6.4 corollary).
  # ---------------------------------------------------------------------

  describe "validate_graph/1 — acceptance criterion 4" do
    test "a cycle passing through a PARALLEL_GATEWAY node is explicitly permitted" do
      g =
        graph(
          [
            node("s", :START),
            node("h", :HUMAN_TASK),
            node("gw", :PARALLEL_GATEWAY),
            node("e", :END)
          ],
          [
            edge("e1", "s", "h"),
            edge("e2", "h", "gw"),
            edge("e3", "gw", "h"),
            edge("e4", "gw", "e")
          ]
        )

      # Fully valid -- proves the cycle is genuinely permitted, not merely
      # "didn't happen to trip some other check too."
      assert Graph.validate_graph(g) == %{valid: true, violations: []}
    end

    test "a self-loop on a non-gateway node is explicitly rejected" do
      g =
        graph(
          [node("s", :START), node("h", :HUMAN_TASK), node("e", :END)],
          [edge("e1", "s", "h"), edge("e2", "h", "h"), edge("e3", "h", "e")]
        )

      result = Graph.validate_graph(g)
      assert result.valid == false
      assert codes(result) == [:cycle_without_gateway]

      [violation] = result.violations
      assert violation.message =~ "node 'h' to node 'h'"
    end

    test "a self-loop ON an EXCLUSIVE_GATEWAY node is accepted (design doc §6.4 corollary, not a self-loop special case)" do
      # This is the genuinely subtle, non-obvious behavior the design doc
      # flags explicitly (§6.4): CHK-06 has no distinct "self-loop" rule --
      # a self-loop is just the back-edge case where u == v, so the same
      # "either endpoint is a gateway" test applies whether or not the two
      # endpoints happen to be the same node. Locking this in as a
      # regression test, not just a one-off observation.
      g =
        graph(
          [node("s", :START), node("gw", :EXCLUSIVE_GATEWAY), node("e", :END)],
          [edge("e1", "s", "gw"), edge("e2", "gw", "gw"), edge("e3", "gw", "e")]
        )

      assert Graph.validate_graph(g) == %{valid: true, violations: []}
    end
  end

  # ---------------------------------------------------------------------
  # REVIEWER Step 2d non-blocking suggestion (handoffs/WF02-REQ028-20260816/
  # step-03-test-designer.json): a node whose only edge is dangling on the
  # far end produces BOTH :dangling_edge (CHK-03) and :isolated_node (CHK-04)
  # in the same call -- locks in the traced-but-implicit interaction design
  # doc §5's CHK-04 detail describes ("a dangling edge contributes no
  # connectivity to either side").
  # ---------------------------------------------------------------------

  describe "REVIEWER suggestion: dangling-only edge also isolates its source node" do
    test "a node's sole edge dangling on its target produces both :dangling_edge and :isolated_node" do
      # n1/n3 satisfy START/END connectivity entirely via e1 (s -> fin);
      # n2's ONLY edge (e2) has a dangling target, so n2 gets neither
      # incoming nor outgoing connectivity credit at all.
      g =
        graph(
          [node("s", :START), node("h", :HUMAN_TASK), node("fin", :END)],
          [edge("e1", "s", "fin"), edge("e2", "h", "ghost")]
        )

      result = Graph.validate_graph(g)
      assert result.valid == false
      assert codes(result) == [:dangling_edge, :isolated_node]

      [dangling, isolated] = result.violations
      assert dangling.message =~ "e2"
      assert isolated.message =~ "'h'"
    end
  end

  # =====================================================================
  # REQ-029 — validate_node_attributes/1, validate_edge_conditions/1, and
  # valid_cel_syntax?/1 (PD-05/PD-06). See test/specs/REQ-029.md for the full
  # rationale and the design-doc traces behind each fixture below
  # (lib/letflow/design/req029-node-attribute-edge-condition-validators.md).
  # =====================================================================

  # ---------------------------------------------------------------------
  # validate_node_attributes/1 — AC1: HUMAN_TASK role
  # ---------------------------------------------------------------------

  describe "validate_node_attributes/1 — acceptance criterion 1: HUMAN_TASK role" do
    test "attributes: nil -> :missing_role" do
      g = graph([attr_node("h1", :HUMAN_TASK, nil)], [])
      result = Graph.validate_node_attributes(g)
      assert result.valid == false
      assert codes(result) == [:missing_role]

      [violation] = result.violations
      assert violation.message =~ "h1"
    end

    test "role absent, blank, whitespace-only, or non-string all trigger the same single code" do
      # CHK-09 detail (design doc §4.1): "there is exactly one trigger
      # condition, not a separate code per sub-case" -- this locks that in
      # rather than assuming it from the table alone.
      for attributes <- [%{}, %{"role" => ""}, %{"role" => "   "}, %{"role" => 42}] do
        g = graph([attr_node("h1", :HUMAN_TASK, attributes)], [])
        result = Graph.validate_node_attributes(g)

        assert codes(result) == [:missing_role],
               "expected :missing_role for #{inspect(attributes)}, got #{inspect(codes(result))}"
      end
    end

    test "a non-empty, non-whitespace role -> valid: true, violations: []" do
      g = graph([attr_node("h1", :HUMAN_TASK, %{"role" => "manager"})], [])
      assert Graph.validate_node_attributes(g) == %{valid: true, violations: []}
    end
  end

  # ---------------------------------------------------------------------
  # validate_node_attributes/1 — AC1: SERVICE_TASK endpoint
  # ---------------------------------------------------------------------

  describe "validate_node_attributes/1 — acceptance criterion 1: SERVICE_TASK endpoint" do
    test "attributes: nil -> :missing_endpoint (alongside the unavoidable companion :invalid_timeout, since timeout_ms is absent too)" do
      # attributes: nil means every SERVICE_TASK-applicable key is absent at
      # once -- both CHK-10 (endpoint) and CHK-11 (timeout_ms) fire, same
      # never-short-circuit shape as the graph_test.exs CHK-05 precedent
      # above. The isolated single-code case is covered by the next test,
      # which supplies a valid timeout_ms to isolate CHK-10 alone.
      g = graph([attr_node("st1", :SERVICE_TASK, nil)], [])
      result = Graph.validate_node_attributes(g)
      assert result.valid == false
      assert codes(result) == [:missing_endpoint, :invalid_timeout]

      [endpoint_violation, _timeout_violation] = result.violations
      assert endpoint_violation.message =~ "st1"
    end

    test "endpoint absent, blank, or whitespace-only -> :missing_endpoint (a valid timeout_ms alongside it does not mask this)" do
      for endpoint_attrs <- [%{}, %{"endpoint" => ""}, %{"endpoint" => "   "}] do
        attributes = Map.put(endpoint_attrs, "timeout_ms", 1000)
        g = graph([attr_node("st1", :SERVICE_TASK, attributes)], [])
        result = Graph.validate_node_attributes(g)

        assert codes(result) == [:missing_endpoint],
               "expected exactly :missing_endpoint for #{inspect(attributes)}, got #{inspect(codes(result))}"
      end
    end
  end

  # ---------------------------------------------------------------------
  # validate_node_attributes/1 — AC1: SERVICE_TASK timeout_ms
  # ---------------------------------------------------------------------

  describe "validate_node_attributes/1 — acceptance criterion 1: SERVICE_TASK timeout_ms" do
    test "timeout_ms: 0 -> :invalid_timeout (below the 1..300000 range)" do
      g =
        graph(
          [attr_node("st1", :SERVICE_TASK, %{"endpoint" => "http://svc", "timeout_ms" => 0})],
          []
        )

      result = Graph.validate_node_attributes(g)
      assert result.valid == false
      assert codes(result) == [:invalid_timeout]

      [violation] = result.violations
      assert violation.message =~ "st1"
    end

    test "timeout_ms: 300001 -> :invalid_timeout (above the 1..300000 range)" do
      g =
        graph(
          [
            attr_node("st1", :SERVICE_TASK, %{
              "endpoint" => "http://svc",
              "timeout_ms" => 300_001
            })
          ],
          []
        )

      result = Graph.validate_node_attributes(g)
      assert result.valid == false
      assert codes(result) == [:invalid_timeout]
    end

    test "timeout_ms: 1 and 300000 (the inclusive boundaries) are both valid" do
      for boundary <- [1, 300_000] do
        g =
          graph(
            [
              attr_node("st1", :SERVICE_TASK, %{
                "endpoint" => "http://svc",
                "timeout_ms" => boundary
              })
            ],
            []
          )

        assert Graph.validate_node_attributes(g) == %{valid: true, violations: []},
               "expected timeout_ms #{boundary} to be valid"
      end
    end

    test "timeout_ms missing, or a float/numeric-string instead of an integer -> :invalid_timeout (no coercion, design doc §2)" do
      # Design doc §2's value-type table pins this as a deliberate
      # no-coercion contract, not an oversight -- a naive `is_number/1`
      # guard or a `String.to_integer/1` fallback would silently accept
      # these, and this test exists specifically to catch that regression.
      for attributes <- [
            %{"endpoint" => "http://svc"},
            %{"endpoint" => "http://svc", "timeout_ms" => 1000.0},
            %{"endpoint" => "http://svc", "timeout_ms" => "1000"}
          ] do
        g = graph([attr_node("st1", :SERVICE_TASK, attributes)], [])
        result = Graph.validate_node_attributes(g)

        assert codes(result) == [:invalid_timeout],
               "expected :invalid_timeout for #{inspect(attributes)}, got #{inspect(codes(result))}"
      end
    end
  end

  # ---------------------------------------------------------------------
  # validate_node_attributes/1 — AC1: TIMER duration_iso8601
  # ---------------------------------------------------------------------

  describe "validate_node_attributes/1 — acceptance criterion 1: TIMER duration_iso8601" do
    test "attributes: nil, or a missing duration_iso8601 key -> :invalid_duration" do
      for attributes <- [nil, %{}] do
        g = graph([attr_node("t1", :TIMER, attributes)], [])
        result = Graph.validate_node_attributes(g)
        assert result.valid == false

        assert codes(result) == [:invalid_duration],
               "expected :invalid_duration for #{inspect(attributes)}"
      end
    end

    test "P0D is explicitly accepted as a zero-delay timer (design doc §4.3)" do
      g = graph([attr_node("t1", :TIMER, %{"duration_iso8601" => "P0D"})], [])
      assert Graph.validate_node_attributes(g) == %{valid: true, violations: []}
    end

    test "other well-formed durations are accepted: P1Y2M3D, PT1H30M, P1DT12H" do
      for duration <- ["P1Y2M3D", "PT1H30M", "P1DT12H"] do
        g = graph([attr_node("t1", :TIMER, %{"duration_iso8601" => duration})], [])

        assert Graph.validate_node_attributes(g) == %{valid: true, violations: []},
               "expected #{duration} to be valid"
      end
    end

    test "malformed durations are rejected: no leading P, zero tokens, empty time part, fractional (. and ,), wrong unit order, missing digits" do
      # Each string exercises a distinct branch of the scan-forward parser
      # (design doc §4.3's "Examples for TEST-DESIGNER") -- one collective
      # test rather than 7 near-duplicate ones, but every branch is
      # represented so a regression in any one of them fails this test.
      invalid_durations = [
        # missing leading "P"
        "1D",
        # "P" with nothing after it at all -- zero tokens
        "P",
        # "T" present but time_part is empty
        "PT",
        # fractional component via "."
        "P1.5D",
        # fractional component via "," (comma variant)
        "PT1,5S",
        # date units out of order (D before Y)
        "P3D2Y",
        # unit letter with no leading digits
        "PXD"
      ]

      for duration <- invalid_durations do
        g = graph([attr_node("t1", :TIMER, %{"duration_iso8601" => duration})], [])
        result = Graph.validate_node_attributes(g)

        assert codes(result) == [:invalid_duration],
               "expected #{inspect(duration)} to be invalid, got #{inspect(codes(result))}"
      end
    end
  end

  # ---------------------------------------------------------------------
  # validate_node_attributes/1 — AC1: START/END/EXCLUSIVE_GATEWAY/
  # PARALLEL_GATEWAY require nothing
  # ---------------------------------------------------------------------

  describe "validate_node_attributes/1 — acceptance criterion 1: START/END/EXCLUSIVE_GATEWAY/PARALLEL_GATEWAY require nothing" do
    test "nil, empty-map, or arbitrary-content attributes never produce a violation for these 4 types" do
      types = [:START, :END, :EXCLUSIVE_GATEWAY, :PARALLEL_GATEWAY]
      attribute_variants = [nil, %{}, %{"role" => "", "anything" => "goes"}]

      for type <- types, attributes <- attribute_variants do
        g = graph([attr_node("n1", type, attributes)], [])

        assert Graph.validate_node_attributes(g) == %{valid: true, violations: []},
               "expected #{type} with #{inspect(attributes)} to be valid"
      end
    end
  end

  # ---------------------------------------------------------------------
  # validate_node_attributes/1 — never short-circuits across checks
  # (design doc §3), and a fully-valid graph returns valid: true
  # ---------------------------------------------------------------------

  describe "validate_node_attributes/1 — never short-circuits (design doc §3)" do
    test "a SERVICE_TASK missing both endpoint and a valid timeout_ms produces both violations, in fixed check order" do
      g = graph([attr_node("st1", :SERVICE_TASK, %{})], [])
      result = Graph.validate_node_attributes(g)
      assert result.valid == false
      assert codes(result) == [:missing_endpoint, :invalid_timeout]
    end

    test "a realistic multi-node graph with one valid node per applicable type returns valid: true, violations: []" do
      g =
        graph(
          [
            attr_node("s", :START, nil),
            attr_node("h", :HUMAN_TASK, %{"role" => "reviewer"}),
            attr_node("st", :SERVICE_TASK, %{"endpoint" => "http://svc", "timeout_ms" => 5000}),
            attr_node("t", :TIMER, %{"duration_iso8601" => "PT30M"}),
            attr_node("gw", :EXCLUSIVE_GATEWAY, nil),
            attr_node("pg", :PARALLEL_GATEWAY, %{}),
            attr_node("e", :END, nil)
          ],
          []
        )

      assert Graph.validate_node_attributes(g) == %{valid: true, violations: []}
    end
  end

  # ---------------------------------------------------------------------
  # validate_node_attributes/1 — AC5: undeclared extra attributes ignored
  # ---------------------------------------------------------------------

  describe "validate_node_attributes/1 — acceptance criterion 5: undeclared extra attributes" do
    test "extra keys alongside a valid role/endpoint/timeout never cause a violation" do
      # Design doc §2: "Any other key present in the map, on any node type,
      # is never read by any check below -- this is exactly what makes
      # 'undeclared extra attributes are silently ignored' true by
      # construction, not by an explicit allow-list/ignore-list
      # mechanism." This test is the demonstration AC5 explicitly asks for.
      g =
        graph(
          [
            attr_node("h1", :HUMAN_TASK, %{
              "role" => "manager",
              "unexpected_key" => "value",
              "another" => 123
            }),
            attr_node("st1", :SERVICE_TASK, %{
              "endpoint" => "http://svc",
              "timeout_ms" => 1000,
              "retry_count" => 3,
              "nested" => %{"a" => 1}
            })
          ],
          []
        )

      assert Graph.validate_node_attributes(g) == %{valid: true, violations: []}
    end
  end

  # ---------------------------------------------------------------------
  # validate_edge_conditions/1 — AC2: default + condition co-firing rejection
  # ---------------------------------------------------------------------

  describe "validate_edge_conditions/1 — acceptance criterion 2: EXCLUSIVE_GATEWAY default edge with a condition" do
    test "is_default: true with a non-null condition is rejected -- CHK-14 and CHK-15 both fire (design doc §5.1, deliberate)" do
      g =
        graph(
          [node("gw", :EXCLUSIVE_GATEWAY), node("t", :END)],
          [cond_edge("e1", "gw", "t", "status == \"approved\"", true)]
        )

      result = Graph.validate_edge_conditions(g)
      assert result.valid == false
      # Deterministic order (fixed check order, same construction as
      # validate_graph/1) -- this is exactly REQ-029 AC2's scenario, and
      # the design doc is explicit that both codes should fire, not just
      # one code covering both facts.
      assert codes(result) == [:unexpected_edge_condition, :default_with_condition]
    end
  end

  # ---------------------------------------------------------------------
  # validate_edge_conditions/1 — AC3: two default edges on one gateway
  # ---------------------------------------------------------------------

  describe "validate_edge_conditions/1 — acceptance criterion 3: multiple default edges on one EXCLUSIVE_GATEWAY" do
    test "two edges from the same gateway both marked is_default: true -> exactly one :multiple_default_edges violation (the 2nd)" do
      g =
        graph(
          [node("gw", :EXCLUSIVE_GATEWAY), node("a", :END), node("b", :END)],
          [
            cond_edge("e1", "gw", "a", nil, true),
            cond_edge("e2", "gw", "b", nil, true)
          ]
        )

      result = Graph.validate_edge_conditions(g)
      assert result.valid == false
      assert codes(result) == [:multiple_default_edges]

      [violation] = result.violations
      assert violation.message =~ "e2"
      assert violation.message =~ "gw"
    end

    test "three default edges from the same gateway -> two violations (N occurrences -> N-1, mirrors CHK-05's convention)" do
      g =
        graph(
          [node("gw", :EXCLUSIVE_GATEWAY), node("a", :END), node("b", :END), node("c", :END)],
          [
            cond_edge("e1", "gw", "a", nil, true),
            cond_edge("e2", "gw", "b", nil, true),
            cond_edge("e3", "gw", "c", nil, true)
          ]
        )

      result = Graph.validate_edge_conditions(g)
      assert codes(result) == [:multiple_default_edges, :multiple_default_edges]
      assert length(result.violations) == 2
      assert Enum.at(result.violations, 0).message =~ "e2"
      assert Enum.at(result.violations, 1).message =~ "e3"
    end

    test "exactly one default edge among several non-default (conditioned) edges on a gateway is legal" do
      g =
        graph(
          [node("s", :START), node("gw", :EXCLUSIVE_GATEWAY), node("a", :END), node("b", :END)],
          [
            edge("e0", "s", "gw"),
            cond_edge("e1", "gw", "a", "amount > 100", false),
            cond_edge("e2", "gw", "b", nil, true)
          ]
        )

      assert Graph.validate_edge_conditions(g) == %{valid: true, violations: []}
    end
  end

  # ---------------------------------------------------------------------
  # validate_edge_conditions/1 — CHK-17 wiring: valid_cel_syntax?/1 is
  # actually consulted for edges carrying a present condition (not just
  # exercised standalone in the describe block below).
  # ---------------------------------------------------------------------

  describe "validate_edge_conditions/1 — CHK-17: invalid CEL syntax on a present condition" do
    test "a syntactically invalid condition (trailing bare operator) on a non-default gateway edge -> :invalid_cel_syntax, and only that code" do
      g =
        graph(
          [node("gw", :EXCLUSIVE_GATEWAY), node("t", :END)],
          [cond_edge("e1", "gw", "t", "amount >", false)]
        )

      result = Graph.validate_edge_conditions(g)
      assert result.valid == false
      assert codes(result) == [:invalid_cel_syntax]
    end
  end

  # ---------------------------------------------------------------------
  # valid_cel_syntax?/1 — AC4: rejects invalid, accepts valid, no evaluation
  # ---------------------------------------------------------------------

  describe "valid_cel_syntax?/1 — acceptance criterion 4" do
    test "accepts structurally well-formed expressions" do
      assert Graph.valid_cel_syntax?("status == \"approved\"") == true
      assert Graph.valid_cel_syntax?("amount > 100 && region in [\"US\", \"EU\"]") == true
    end

    test "rejects structurally invalid expressions" do
      # One example per distinct failure mode named in design doc §6, not
      # just one lone example -- an unclosed bracket, an unterminated
      # string literal, and a trailing/leading bare operator are
      # independent code paths in the algorithm (steps 2 and 4).
      assert Graph.valid_cel_syntax?("status == ") == false
      assert Graph.valid_cel_syntax?("(status == \"approved\"") == false
      assert Graph.valid_cel_syntax?("\"unterminated") == false
      assert Graph.valid_cel_syntax?("&& status") == false
      assert Graph.valid_cel_syntax?("") == false
      assert Graph.valid_cel_syntax?("   ") == false
    end

    test "performs no evaluation -- a well-formed expression referencing a variable that could never exist is still accepted" do
      # Design doc §6's own explicit demonstration case: "this function
      # never attempts to identify variable names, look up a value...
      # A nonsense-but-well-formed expression... returns true." This is
      # the exact test AC4 asks TEST-DESIGNER to write -- it proves the
      # function is purely lexical/structural, not that it understands
      # what the expression means.
      assert Graph.valid_cel_syntax?("this_variable_does_not_exist_anywhere == 42") == true
    end
  end
end
